//! Plain TCP ingress for iptables `nat` REDIRECT.
//!
//! The kernel rewrites the destination to the LAN address this process binds.
//! `SO_ORIGINAL_DST` is the address the client chose. There is no network
//! namespace, BPF program, cgroup hook, or `IP_TRANSPARENT` socket. UDP is
//! not accepted; DNS stays on the resolver already serving the LAN.

use std::net::{Ipv4Addr, SocketAddr};
use std::sync::OnceLock;

static BIND: OnceLock<SocketAddr> = OnceLock::new();

pub fn validate_bind(addr: SocketAddr) -> anyhow::Result<()> {
    let SocketAddr::V4(v4) = addr else {
        anyhow::bail!("--redirect needs an IPv4 address");
    };
    if v4.port() == 0 || refused_lan(*v4.ip()) {
        anyhow::bail!("--redirect needs one LAN IPv4 address and a nonzero port");
    }
    Ok(())
}

fn refused_lan(ip: Ipv4Addr) -> bool {
    ip.is_unspecified() || ip.is_loopback() || ip.is_multicast() || ip.is_broadcast()
}

/// Remember the listener address for this process. Later calls fail.
#[cfg(feature = "redirect")]
pub fn install(addr: SocketAddr) -> anyhow::Result<()> {
    validate_bind(addr)?;
    BIND.set(addr)
        .map_err(|_| anyhow::anyhow!("redirect ingress is already installed"))?;
    Ok(())
}

#[cfg(feature = "redirect")]
pub fn bind_addr() -> Option<SocketAddr> {
    BIND.get().copied()
}

#[cfg(not(feature = "redirect"))]
pub fn bind_addr() -> Option<SocketAddr> {
    None
}

pub fn active() -> bool {
    bind_addr().is_some()
}

/// A recovered destination that still names the listener was not rewritten.
pub fn accept_original(bind: SocketAddr, original: SocketAddr) -> anyhow::Result<()> {
    if original.port() == 0 || original.ip() == bind.ip() {
        anyhow::bail!("redirect refused original destination {original}");
    }
    Ok(())
}

/// `SO_ORIGINAL_DST` wins. Without a redirect listener, a missing sockopt
/// still falls back to the socket's local address (the eBPF `sk_assign` path).
/// With one, that fallback is the listener itself, so it is a hard error.
pub fn resolve_original(
    bind: Option<SocketAddr>,
    sockopt: Result<SocketAddr, anyhow::Error>,
    local: Result<SocketAddr, std::io::Error>,
) -> anyhow::Result<SocketAddr> {
    match sockopt {
        Ok(dest) => {
            if let Some(bind) = bind {
                accept_original(bind, dest)?;
            }
            Ok(dest)
        }
        Err(error) => {
            if bind.is_some() {
                anyhow::bail!("redirect original destination unavailable: {error}");
            }
            local.map_err(|local_error| {
                anyhow::anyhow!(
                    "original destination unavailable: {error} (local_addr: {local_error})"
                )
            })
        }
    }
}

pub fn relay_error_text(error: &str, dest: &str, peer: &str) -> String {
    format!("relay: {error} dest={dest} peer={peer}")
}

pub fn relay_failure(
    dest: impl std::fmt::Display,
    peer: impl std::fmt::Display,
    error: impl std::fmt::Display,
) {
    tracing::info!(
        "{}",
        relay_error_text(&error.to_string(), &dest.to_string(), &peer.to_string())
    );
}

/// Upstream we tried to dial. Built-in direct and block nodes have no host.
pub fn dial_peer(host: &str, port: u16, target: SocketAddr) -> String {
    if port == 0 || host.is_empty() {
        target.to_string()
    } else {
        format!("{host}:{port}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lan() -> SocketAddr {
        "192.168.2.1:12345".parse().unwrap()
    }

    #[test]
    fn bind_address_is_one_lan_ipv4() {
        assert!(validate_bind(lan()).is_ok());
        assert!(validate_bind("0.0.0.0:12345".parse().unwrap()).is_err());
        assert!(validate_bind("127.0.0.1:12345".parse().unwrap()).is_err());
        assert!(validate_bind("192.168.2.1:0".parse().unwrap()).is_err());
        assert!(validate_bind("[2001:db8::1]:12345".parse().unwrap()).is_err());
    }

    #[test]
    fn original_destination_must_leave_the_listener() {
        let bind = lan();
        assert!(accept_original(bind, "1.1.1.1:443".parse().unwrap()).is_ok());
        assert!(accept_original(bind, "192.168.2.1:443".parse().unwrap()).is_err());
        assert!(accept_original(bind, "9.9.9.9:0".parse().unwrap()).is_err());
    }

    #[test]
    fn missing_sockopt_does_not_become_the_listener() {
        let bind = lan();
        let missing = Err(anyhow::anyhow!("ENOENT"));
        let local = Ok(bind);
        assert!(resolve_original(Some(bind), missing, local).is_err());
    }

    #[test]
    fn ebpf_fallback_still_uses_the_local_address() {
        let local: SocketAddr = "1.1.1.1:443".parse().unwrap();
        let resolved = resolve_original(None, Err(anyhow::anyhow!("ENOENT")), Ok(local)).unwrap();
        assert_eq!(resolved, local);
    }

    #[test]
    fn relay_error_names_dest_and_peer() {
        let text = relay_error_text("Connection refused", "1.1.1.1:443", "203.0.113.10:8388");
        assert!(text.contains("dest=1.1.1.1:443"), "{text}");
        assert!(text.contains("peer=203.0.113.10:8388"), "{text}");
    }

    #[test]
    fn direct_peer_is_the_target() {
        let target: SocketAddr = "1.1.1.1:443".parse().unwrap();
        assert_eq!(dial_peer("", 0, target), "1.1.1.1:443");
        assert_eq!(dial_peer("203.0.113.10", 8388, target), "203.0.113.10:8388");
    }
}
