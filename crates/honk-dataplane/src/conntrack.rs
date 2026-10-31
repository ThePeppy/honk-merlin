//! Select conntrack entries created by REDIRECT and name a delete for each.
//!
//! A captured 6.12 netns entry looks like this (reply source is the listen
//! address, reply source port is the listen port):
//!
//! `src=10.66.0.2 dst=9.9.9.9 sport=33714 dport=443 src=10.66.0.1 dst=10.66.0.2 sport=39527 dport=33714`
//!
//! Deleting by that full original tuple does not flush the table. Entries whose
//! reply half is not our listener are left alone, including a connection the
//! router itself opened.

use std::net::Ipv4Addr;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConntrackTuple {
    pub src: Ipv4Addr,
    pub dst: Ipv4Addr,
    pub sport: u16,
    pub dport: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConntrackDelete {
    pub program: String,
    pub args: Vec<String>,
}

/// Original tuples whose reply half is the REDIRECT listener.
pub fn parse_conntrack(text: &str, listen_ip: Ipv4Addr, listen_port: u16) -> Vec<ConntrackTuple> {
    text.lines()
        .filter_map(|line| redirected_original(line, listen_ip, listen_port))
        .collect()
}

pub fn conntrack_deletes(program: &str, tuples: &[ConntrackTuple]) -> Vec<ConntrackDelete> {
    tuples
        .iter()
        .map(|tuple| ConntrackDelete {
            program: program.to_owned(),
            args: vec![
                "-D".to_owned(),
                "-p".to_owned(),
                "tcp".to_owned(),
                "-s".to_owned(),
                tuple.src.to_string(),
                "-d".to_owned(),
                tuple.dst.to_string(),
                "--sport".to_owned(),
                tuple.sport.to_string(),
                "--dport".to_owned(),
                tuple.dport.to_string(),
            ],
        })
        .collect()
}

fn redirected_original(
    line: &str,
    listen_ip: Ipv4Addr,
    listen_port: u16,
) -> Option<ConntrackTuple> {
    if !line.split_whitespace().any(|field| field == "tcp") {
        return None;
    }
    let mut found = Vec::new();
    let bytes = line.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if let Some(tuple) = take_tuple(line, &mut index) {
            found.push(tuple);
            if found.len() == 2 {
                break;
            }
        } else {
            break;
        }
    }
    let [original, reply] = found.try_into().ok()?;
    if reply.src == listen_ip && reply.sport == listen_port {
        Some(original)
    } else {
        None
    }
}

fn take_tuple(line: &str, index: &mut usize) -> Option<ConntrackTuple> {
    let src = take_field(line, index, "src=")?;
    let dst = take_field(line, index, "dst=")?;
    let sport = take_field(line, index, "sport=")?;
    let dport = take_field(line, index, "dport=")?;
    Some(ConntrackTuple {
        src: src.parse().ok()?,
        dst: dst.parse().ok()?,
        sport: sport.parse().ok()?,
        dport: dport.parse().ok()?,
    })
}

fn take_field<'a>(line: &'a str, index: &mut usize, key: &str) -> Option<&'a str> {
    let rest = line.get(*index..)?;
    let start = rest.find(key)? + key.len();
    let absolute = *index + start;
    let value = line[absolute..]
        .split_whitespace()
        .next()
        .filter(|value| !value.is_empty())?;
    *index = absolute + value.len();
    Some(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Captured from a netns REDIRECT of 10.66.0.2 -> 9.9.9.9:443 onto
    /// 10.66.0.1:39527, plus a router-local connection that must survive.
    const PROC: &str = "\
ipv4     2 tcp      6 119 TIME_WAIT src=10.66.0.2 dst=9.9.9.9 sport=33714 dport=443 src=10.66.0.1 dst=10.66.0.2 sport=39527 dport=33714 [ASSURED] mark=0 zone=0 use=2
ipv4     2 tcp      6 119 TIME_WAIT src=10.66.0.1 dst=10.66.0.1 sport=33664 dport=9 src=10.66.0.1 dst=10.66.0.1 sport=9 dport=33664 [ASSURED] mark=0 zone=0 use=2
ipv4     2 udp      17 20 src=10.66.0.2 dst=1.1.1.1 sport=53 dport=53 src=10.66.0.1 dst=10.66.0.2 sport=39527 dport=53
";

    #[test]
    fn only_the_redirected_tcp_original_tuple_is_deleted() {
        let listen = "10.66.0.1".parse().unwrap();
        let tuples = parse_conntrack(PROC, listen, 39527);
        assert_eq!(
            tuples,
            vec![ConntrackTuple {
                src: "10.66.0.2".parse().unwrap(),
                dst: "9.9.9.9".parse().unwrap(),
                sport: 33714,
                dport: 443,
            }]
        );
        let deletes = conntrack_deletes("conntrack", &tuples);
        assert_eq!(deletes.len(), 1);
        assert_eq!(deletes[0].program, "conntrack");
        assert!(
            deletes[0]
                .args
                .windows(2)
                .any(|pair| pair == ["--dport", "443"])
        );
        assert!(!deletes[0].args.iter().any(|arg| arg == "-F"));
    }
}
