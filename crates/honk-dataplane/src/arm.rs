//! IPv4 TCP REDIRECT plan for one LAN interface.
//!
//! PREROUTING REDIRECT rewrites the destination to the incoming interface's
//! primary address, not to 127.0.0.1. The listener therefore binds that
//! address. Router-originated traffic never enters this chain: there is no
//! OUTPUT rule and no policy route.

use std::net::Ipv4Addr;

use thiserror::Error;

pub const NAT_CHAIN: &str = "HONK_PRE";
pub const LISTEN_PORT: u16 = 39527;

const FIXED_EXCLUSIONS: &[&str] = &[
    "127.0.0.0/8",
    "169.254.0.0/16",
    "224.0.0.0/4",
    "255.255.255.255/32",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Argv {
    pub program: String,
    pub args: Vec<String>,
}

impl Argv {
    pub fn new(
        program: impl Into<String>,
        args: impl IntoIterator<Item = impl Into<String>>,
    ) -> Self {
        Self {
            program: program.into(),
            args: args.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct V4Net {
    pub network: Ipv4Addr,
    pub prefix: u8,
}

impl V4Net {
    pub fn from_ip_mask(ip: Ipv4Addr, mask: Ipv4Addr) -> Result<Self, PlanError> {
        let mask_u = u32::from(mask);
        let prefix = mask_u.leading_ones();
        if prefix == 0 || mask_u.trailing_zeros() != 32 - prefix {
            return Err(PlanError::Mask);
        }
        let prefix_u8 = u8::try_from(prefix).map_err(|_| PlanError::Mask)?;
        if !(8..=30).contains(&prefix_u8) {
            return Err(PlanError::Prefix);
        }
        let host = u32::from(ip) & !mask_u;
        let host_max = !mask_u;
        if host == 0 || host == host_max {
            return Err(PlanError::LanHost);
        }
        Ok(Self {
            network: Ipv4Addr::from(u32::from(ip) & mask_u),
            prefix: prefix_u8,
        })
    }

    pub fn contains(self, ip: Ipv4Addr) -> bool {
        let shift = 32 - u32::from(self.prefix);
        (u32::from(ip) >> shift) == (u32::from(self.network) >> shift)
    }
}

impl std::fmt::Display for V4Net {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{}/{}", self.network, self.prefix)
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum PlanError {
    #[error("operation mode is not router")]
    SwMode,
    #[error("LAN interface name is empty or unexpected")]
    Ifname,
    #[error("primary address does not match lan_ipaddr")]
    PrimaryMismatch,
    #[error("listen address is loopback, unspecified, or multicast")]
    ListenAddress,
    #[error("netmask is not contiguous")]
    Mask,
    #[error("LAN prefix is outside 8..=30")]
    Prefix,
    #[error("LAN address is the network or broadcast address")]
    LanHost,
    #[error("LAN address is outside its own prefix")]
    LanContains,
    #[error("local address list does not include the primary address")]
    LocalIps,
    #[error("unknown or empty facts line")]
    Facts,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RedirectPlan {
    pub ifname: String,
    pub listen_ip: Ipv4Addr,
    pub listen_port: u16,
    pub lan: V4Net,
    pub local_ips: Vec<Ipv4Addr>,
}

impl RedirectPlan {
    pub fn exclusions(&self) -> ExclusionSet {
        let mut nets = vec![self.lan];
        for cidr in FIXED_EXCLUSIONS {
            let (addr, prefix) = cidr.split_once('/').expect("static cidr");
            nets.push(V4Net {
                network: addr.parse().expect("static cidr address"),
                prefix: prefix.parse().expect("static cidr prefix"),
            });
        }
        ExclusionSet {
            nets,
            hosts: self.local_ips.clone(),
        }
    }

    /// Chain body only. The jump onto PREROUTING is added after every rule exists.
    pub fn chain_rules(&self, iptables: &str) -> Vec<Argv> {
        let mut rules = Vec::new();
        let mut hosts = self.local_ips.clone();
        hosts.sort();
        hosts.dedup();
        for host in hosts {
            rules.push(self.ret(iptables, &host.to_string()));
        }
        rules.push(self.ret(iptables, &self.lan.to_string()));
        for cidr in FIXED_EXCLUSIONS {
            rules.push(self.ret(iptables, cidr));
        }
        rules.push(Argv::new(
            iptables,
            [
                "-t",
                "nat",
                "-A",
                NAT_CHAIN,
                "-i",
                &self.ifname,
                "-p",
                "tcp",
                "-j",
                "REDIRECT",
                "--to-ports",
                &self.listen_port.to_string(),
            ],
        ));
        rules
    }

    fn ret(&self, iptables: &str, dest: &str) -> Argv {
        Argv::new(
            iptables,
            [
                "-t",
                "nat",
                "-A",
                NAT_CHAIN,
                "-i",
                &self.ifname,
                "-p",
                "tcp",
                "-d",
                dest,
                "-j",
                "RETURN",
            ],
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExclusionSet {
    pub nets: Vec<V4Net>,
    pub hosts: Vec<Ipv4Addr>,
}

impl ExclusionSet {
    pub fn contains(&self, ip: Ipv4Addr) -> bool {
        self.hosts.contains(&ip) || self.nets.iter().any(|net| net.contains(ip))
    }
}

pub fn parse_arm_facts(text: &str) -> Result<RedirectPlan, PlanError> {
    let mut sw_mode: Option<u32> = None;
    let mut ifname: Option<String> = None;
    let mut lan_ip: Option<Ipv4Addr> = None;
    let mut lan_mask: Option<Ipv4Addr> = None;
    let mut primary: Option<Ipv4Addr> = None;
    let mut local_ips = Vec::new();
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (key, value) = line.split_once('=').ok_or(PlanError::Facts)?;
        if value.is_empty() || value.chars().any(|ch| ch.is_whitespace()) {
            return Err(PlanError::Facts);
        }
        match key {
            "sw_mode" => sw_mode = Some(value.parse().map_err(|_| PlanError::Facts)?),
            "ifname" => ifname = Some(value.to_owned()),
            "lan_ip" => lan_ip = Some(parse_v4(value)?),
            "lan_mask" => lan_mask = Some(parse_v4(value)?),
            "primary_ip" => primary = Some(parse_v4(value)?),
            "local_ip" => local_ips.push(parse_v4(value)?),
            _ => return Err(PlanError::Facts),
        }
    }
    build_plan(
        sw_mode.ok_or(PlanError::Facts)?,
        ifname.ok_or(PlanError::Facts)?,
        lan_ip.ok_or(PlanError::Facts)?,
        lan_mask.ok_or(PlanError::Facts)?,
        primary.ok_or(PlanError::Facts)?,
        local_ips,
    )
}

fn build_plan(
    sw_mode: u32,
    ifname: String,
    lan_ip: Ipv4Addr,
    lan_mask: Ipv4Addr,
    primary: Ipv4Addr,
    mut local_ips: Vec<Ipv4Addr>,
) -> Result<RedirectPlan, PlanError> {
    if sw_mode != 1 {
        return Err(PlanError::SwMode);
    }
    if !valid_ifname(&ifname) {
        return Err(PlanError::Ifname);
    }
    if primary != lan_ip {
        return Err(PlanError::PrimaryMismatch);
    }
    if refused_listen(primary) {
        return Err(PlanError::ListenAddress);
    }
    let lan = V4Net::from_ip_mask(lan_ip, lan_mask)?;
    if !lan.contains(lan_ip) {
        return Err(PlanError::LanContains);
    }
    local_ips.sort();
    local_ips.dedup();
    if !local_ips.contains(&primary) {
        return Err(PlanError::LocalIps);
    }
    Ok(RedirectPlan {
        ifname,
        listen_ip: primary,
        listen_port: LISTEN_PORT,
        lan,
        local_ips,
    })
}

fn parse_v4(value: &str) -> Result<Ipv4Addr, PlanError> {
    value.parse().map_err(|_| PlanError::Facts)
}

fn valid_ifname(name: &str) -> bool {
    let mut chars = name.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if !first.is_ascii_alphabetic() || name.len() > 15 {
        return false;
    }
    chars.all(|ch| ch.is_ascii_alphanumeric() || ch == '.' || ch == '_' || ch == '-')
}

fn refused_listen(ip: Ipv4Addr) -> bool {
    ip.is_unspecified() || ip.is_loopback() || ip.is_multicast() || ip.is_broadcast()
}

pub fn unlink_commands(iptables: &str) -> Vec<Argv> {
    vec![
        Argv::new(iptables, ["-t", "nat", "-D", "PREROUTING", "-j", NAT_CHAIN]),
        Argv::new(iptables, ["-t", "nat", "-F", NAT_CHAIN]),
        Argv::new(iptables, ["-t", "nat", "-X", NAT_CHAIN]),
    ]
}

pub fn ensure_chain(iptables: &str) -> Argv {
    Argv::new(iptables, ["-t", "nat", "-N", NAT_CHAIN])
}

pub fn check_jump(iptables: &str) -> Argv {
    Argv::new(iptables, ["-t", "nat", "-C", "PREROUTING", "-j", NAT_CHAIN])
}

pub fn append_jump(iptables: &str) -> Argv {
    Argv::new(iptables, ["-t", "nat", "-A", "PREROUTING", "-j", NAT_CHAIN])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> RedirectPlan {
        parse_arm_facts(
            "\
sw_mode=1
ifname=br0
lan_ip=192.168.50.1
lan_mask=255.255.255.0
primary_ip=192.168.50.1
local_ip=203.0.113.8
local_ip=192.168.50.1
",
        )
        .unwrap()
    }

    fn programs(rules: &[Argv]) -> Vec<String> {
        rules.iter().map(|rule| rule.program.clone()).collect()
    }

    #[test]
    fn rules_are_tcp_on_the_lan_interface_and_redirect_is_last() {
        let plan = sample();
        let rules = plan.chain_rules("iptables");
        assert!(rules.len() > 2);
        let redirect = rules.last().unwrap();
        assert!(
            redirect
                .args
                .windows(2)
                .any(|pair| pair == ["-j", "REDIRECT"])
        );
        assert!(
            redirect
                .args
                .windows(2)
                .any(|pair| pair == ["--to-ports", "39527"])
        );
        assert!(redirect.args.windows(2).any(|pair| pair == ["-i", "br0"]));
        assert!(redirect.args.windows(2).any(|pair| pair == ["-p", "tcp"]));
        for rule in &rules[..rules.len() - 1] {
            assert!(rule.args.windows(2).any(|pair| pair == ["-j", "RETURN"]));
            assert!(rule.args.windows(2).any(|pair| pair == ["-i", "br0"]));
            assert!(rule.args.windows(2).any(|pair| pair == ["-p", "tcp"]));
            assert!(
                !rule
                    .args
                    .iter()
                    .any(|arg| arg == "REDIRECT" || arg == "OUTPUT")
            );
        }
        assert!(programs(&rules).iter().all(|program| program == "iptables"));
        let jump = append_jump("iptables");
        assert!(
            jump.args
                .windows(3)
                .any(|triple| triple == ["-A", "PREROUTING", "-j"])
        );
        assert!(!jump.args.iter().any(|arg| arg == "-I"));
        assert!(
            !unlink_commands("iptables")
                .iter()
                .any(|cmd| cmd.program != "iptables")
        );
        assert!(
            !rules
                .iter()
                .any(|cmd| cmd.args.iter().any(|arg| arg == "OUTPUT" || arg == "ip"))
        );
    }

    #[test]
    fn exclusions_cover_the_router_the_lan_and_non_unicast_ranges() {
        let plan = sample();
        let set = plan.exclusions();
        assert!(set.contains("192.168.50.1".parse().unwrap()));
        assert!(set.contains("192.168.50.40".parse().unwrap()));
        assert!(set.contains("203.0.113.8".parse().unwrap()));
        assert!(set.contains("127.0.0.1".parse().unwrap()));
        assert!(set.contains("169.254.1.1".parse().unwrap()));
        assert!(set.contains("224.0.0.1".parse().unwrap()));
        assert!(set.contains("255.255.255.255".parse().unwrap()));
        assert!(!set.contains("1.1.1.1".parse().unwrap()));
    }

    #[test]
    fn loopback_primary_and_wrong_mode_produce_no_plan() {
        let loopback = parse_arm_facts(
            "\
sw_mode=1
ifname=br0
lan_ip=127.0.0.1
lan_mask=255.0.0.0
primary_ip=127.0.0.1
local_ip=127.0.0.1
",
        );
        assert_eq!(loopback, Err(PlanError::ListenAddress));
        let ap = parse_arm_facts(
            "\
sw_mode=2
ifname=br0
lan_ip=192.168.50.1
lan_mask=255.255.255.0
primary_ip=192.168.50.1
local_ip=192.168.50.1
",
        );
        assert_eq!(ap, Err(PlanError::SwMode));
        let mismatch = parse_arm_facts(
            "\
sw_mode=1
ifname=br0
lan_ip=192.168.50.1
lan_mask=255.255.255.0
primary_ip=192.168.50.2
local_ip=192.168.50.2
",
        );
        assert_eq!(mismatch, Err(PlanError::PrimaryMismatch));
    }

    #[test]
    fn missing_field_and_injection_are_rejected() {
        assert!(parse_arm_facts("sw_mode=1\n").is_err());
        assert!(
            parse_arm_facts(
                "\
sw_mode=1
ifname=br0;rm
lan_ip=192.168.50.1
lan_mask=255.255.255.0
primary_ip=192.168.50.1
local_ip=192.168.50.1
"
            )
            .is_err()
        );
        assert!(
            parse_arm_facts(
                "\
sw_mode=1
ifname=br0
lan_ip=192.168.50.1
lan_mask=255.255.255.0
primary_ip=192.168.50.1
local_ip=192.168.50.1
listen_port=22
"
            )
            .is_err()
        );
    }
}
