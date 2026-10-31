//! Bind the LAN primary address and copy accepted TCP to the original destination.
//!
//! The ready file is created only after `bind` returns. `SO_ORIGINAL_DST` failure
//! closes that socket and does not open another one.

use std::io;
use std::net::{Ipv4Addr, SocketAddr};
use std::path::Path;
use std::sync::Arc;

use thiserror::Error;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Semaphore, watch};

use crate::arm::RedirectPlan;
use crate::relay::{OriginalDestination, RelayPlan, plan_relay, relay_direct};

const MAX_CONNECTIONS: usize = 256;

#[derive(Debug, Error)]
pub enum ListenError {
    #[error("listen address {0} is not an ipv4 primary address")]
    BindAddress(SocketAddr),
    #[error(transparent)]
    Io(#[from] io::Error),
}

pub struct NixOriginalDest;

impl OriginalDestination for NixOriginalDest {
    fn lookup(&self, stream: &TcpStream) -> Option<SocketAddr> {
        #[cfg(target_os = "linux")]
        {
            let addr = nix::sys::socket::getsockopt(stream, nix::sys::socket::sockopt::OriginalDst)
                .ok()?;
            let ip = Ipv4Addr::from(u32::from_be(addr.sin_addr.s_addr));
            let port = u16::from_be(addr.sin_port);
            if ip.is_unspecified() || port == 0 {
                None
            } else {
                Some(SocketAddr::from((ip, port)))
            }
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = stream;
            None
        }
    }
}

pub async fn serve<L>(
    plan: RedirectPlan,
    ready: &Path,
    lookup: L,
    mut shutdown: watch::Receiver<bool>,
) -> Result<(), ListenError>
where
    L: OriginalDestination + Send + Sync + 'static,
{
    let bind = SocketAddr::from((plan.listen_ip, plan.listen_port));
    if !bind.ip().is_ipv4() || bind.ip().is_loopback() || bind.ip().is_unspecified() {
        return Err(ListenError::BindAddress(bind));
    }
    let listener = TcpListener::bind(bind).await?;
    write_ready(ready, bind)?;
    let _ready_guard = ReadyGuard(ready.to_path_buf());
    let lookup = Arc::new(lookup);
    let excluded = plan.exclusions();
    let slots = Arc::new(Semaphore::new(MAX_CONNECTIONS));
    loop {
        tokio::select! {
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    break;
                }
            }
            accepted = listener.accept() => {
                let (stream, _) = match accepted {
                    Ok(pair) => pair,
                    Err(error) => {
                        eprintln!("honk-dataplane: accept: {error}");
                        continue;
                    }
                };
                let Ok(permit) = slots.clone().try_acquire_owned() else {
                    continue;
                };
                let lookup = Arc::clone(&lookup);
                let excluded = excluded.clone();
                tokio::spawn(async move {
                    let _permit = permit;
                    let decision = {
                        let original = lookup.lookup(&stream);
                        plan_relay(original, bind, &excluded)
                    };
                    drop(lookup);
                    if let RelayPlan::Direct(dest) = decision {
                        let peer = stream.peer_addr().unwrap_or(dest);
                        let mut stream = stream;
                        let result = if let Some(path) = crate::route::config_file() {
                            let cache = std::env::var_os("HONK_NODE_CACHE").map(std::path::PathBuf::from);
                            let selections = std::env::var_os("HONK_SELECTIONS")
                                .map(std::path::PathBuf::from)
                                .unwrap_or_else(|| path.with_file_name("select.txt"));
                            let prelude = crate::sniff::read_prelude(&mut stream).await;
                            crate::route::handle(
                                &path,
                                cache.as_deref(),
                                &selections,
                                stream,
                                dest,
                                peer,
                                prelude,
                            )
                            .await
                        } else {
                            relay_direct(stream, dest).await
                        };
                        if let Err(error) = result {
                            eprintln!("honk-dataplane: relay: {error}");
                        }
                    }
                });
            }
        }
    }
    Ok(())
}

#[cfg(test)]
fn decide(
    stream: &TcpStream,
    bind: SocketAddr,
    excluded: &crate::arm::ExclusionSet,
    lookup: &impl OriginalDestination,
) -> RelayPlan {
    plan_relay(lookup.lookup(stream), bind, excluded)
}

fn write_ready(path: &Path, bind: SocketAddr) -> io::Result<()> {
    if let Some(parent) = path.parent()
        && !parent.as_os_str().is_empty()
    {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, format!("{bind}\n"))?;
    std::fs::rename(tmp, path)
}

struct ReadyGuard(std::path::PathBuf);

impl Drop for ReadyGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

/// `0A` in `/proc/net/tcp` is TCP_LISTEN. The address is little-endian hex.
pub fn tcp_listening(proc_tcp: &str, ip: Ipv4Addr, port: u16) -> bool {
    let want = proc_addr(ip, port);
    proc_tcp.lines().any(|line| {
        let mut fields = line.split_whitespace();
        let _slot = fields.next();
        let local = fields.next();
        let _remote = fields.next();
        let state = fields.next();
        local == Some(want.as_str()) && state == Some("0A")
    })
}

fn proc_addr(ip: Ipv4Addr, port: u16) -> String {
    let octets = ip.octets();
    format!(
        "{:02X}{:02X}{:02X}{:02X}:{:04X}",
        octets[3], octets[2], octets[1], octets[0], port
    )
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    use tokio::net::TcpListener;

    use super::*;
    use crate::arm::parse_arm_facts;
    use crate::relay::OriginalDestination;

    struct Fixed(Option<SocketAddr>, Arc<AtomicUsize>);

    impl OriginalDestination for Fixed {
        fn lookup(&self, _stream: &TcpStream) -> Option<SocketAddr> {
            self.1.fetch_add(1, Ordering::SeqCst);
            self.0
        }
    }

    #[test]
    fn proc_net_tcp_listen_line_matches_the_lan_address() {
        let line = "   0: 0132A8C0:9A67 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12345 1 0000000000000000 100 0 0 10 0\n";
        assert!(tcp_listening(line, "192.168.50.1".parse().unwrap(), 39527));
        assert!(!tcp_listening(line, "192.168.50.1".parse().unwrap(), 22));
        assert!(!tcp_listening(
            "   1: 0132A8C0:9A67 0100007F:01BB 01 00000000:00000000 00:00000000 00000000     0        0 1 1 0000000000000000 20 4 30 10 -1\n",
            "192.168.50.1".parse().unwrap(),
            39527
        ));
    }

    #[tokio::test]
    async fn plain_accept_has_no_original_destination() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let client = tokio::spawn(async move {
            let _ = TcpStream::connect(addr).await.unwrap();
        });
        let (stream, _) = listener.accept().await.unwrap();
        let found = NixOriginalDest.lookup(&stream);
        let plan = parse_arm_facts(
            "\
sw_mode=1
ifname=br0
lan_ip=192.168.50.1
lan_mask=255.255.255.0
primary_ip=192.168.50.1
local_ip=192.168.50.1
",
        )
        .unwrap();
        // Without REDIRECT the kernel may report the listener address. That
        // must not become a direct connection.
        assert_eq!(
            crate::plan_relay(found, addr, &plan.exclusions()),
            crate::RelayPlan::Drop
        );
        drop(stream);
        client.await.unwrap();
    }

    #[tokio::test]
    async fn missing_original_destination_does_not_reach_a_decoy() {
        let decoy = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let hits = Arc::new(AtomicUsize::new(0));
        let plan = parse_arm_facts(
            "\
sw_mode=1
ifname=lo
lan_ip=127.8.0.1
lan_mask=255.255.0.0
primary_ip=127.8.0.1
local_ip=127.8.0.1
",
        );
        // 127.8.0.1 is loopback and must be refused before a socket exists.
        assert!(plan.is_err());

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let bind = listener.local_addr().unwrap();
        let plan = parse_arm_facts(
            "\
sw_mode=1
ifname=br0
lan_ip=192.168.50.1
lan_mask=255.255.255.0
primary_ip=192.168.50.1
local_ip=192.168.50.1
",
        )
        .unwrap();
        let excluded = plan.exclusions();
        let lookup = Fixed(None, Arc::clone(&hits));
        let client = TcpStream::connect(bind).await.unwrap();
        let (accepted, _) = listener.accept().await.unwrap();
        assert_eq!(
            decide(
                &accepted,
                "192.168.50.1:39527".parse().unwrap(),
                &excluded,
                &lookup
            ),
            crate::RelayPlan::Drop
        );
        drop(accepted);
        assert_eq!(hits.load(Ordering::SeqCst), 1);
        let accepted_decoy = tokio::time::timeout(Duration::from_millis(200), decoy.accept()).await;
        assert!(accepted_decoy.is_err());
        drop(client);
    }

    #[tokio::test]
    async fn loopback_original_destination_is_not_dialled() {
        let decoy = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let decoy_addr = decoy.local_addr().unwrap();
        let plan = parse_arm_facts(
            "\
sw_mode=1
ifname=br0
lan_ip=192.168.50.1
lan_mask=255.255.255.0
primary_ip=192.168.50.1
local_ip=192.168.50.1
",
        )
        .unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let bind = listener.local_addr().unwrap();
        let client = TcpStream::connect(bind).await.unwrap();
        let (accepted, _) = listener.accept().await.unwrap();
        let lookup = Fixed(Some(decoy_addr), Arc::new(AtomicUsize::new(0)));
        assert_eq!(
            decide(
                &accepted,
                "192.168.50.1:39527".parse().unwrap(),
                &plan.exclusions(),
                &lookup
            ),
            crate::RelayPlan::Drop
        );
        drop(accepted);
        drop(client);
        let hit = tokio::time::timeout(Duration::from_millis(150), decoy.accept()).await;
        assert!(hit.is_err());
    }
}
