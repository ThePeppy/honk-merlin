//! Decide whether a redirected socket may be copied to its original destination.
//!
//! A missing `SO_ORIGINAL_DST` is a drop. Under REDIRECT the socket's local
//! address is the listen endpoint, so using it would connect the relay to itself.
//! Proxy dialling is not a third outcome: phase 1 has no honk-outbound path.

use std::io;
use std::net::SocketAddr;
use std::time::Duration;

use tokio::io::AsyncWriteExt;
use tokio::net::TcpStream;

use crate::arm::ExclusionSet;

pub trait OriginalDestination {
    fn lookup(&self, stream: &TcpStream) -> Option<SocketAddr>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RelayPlan {
    Direct(SocketAddr),
    Drop,
}

pub fn plan_relay(
    original: Option<SocketAddr>,
    bind: SocketAddr,
    excluded: &ExclusionSet,
) -> RelayPlan {
    let Some(original) = original else {
        return RelayPlan::Drop;
    };
    let std::net::IpAddr::V4(ip) = original.ip() else {
        return RelayPlan::Drop;
    };
    if original.port() == 0 || excluded.contains(ip) || original == bind || ip.is_loopback() {
        RelayPlan::Drop
    } else {
        RelayPlan::Direct(original)
    }
}

pub async fn relay_direct(mut client: TcpStream, dest: SocketAddr) -> io::Result<()> {
    let connect = TcpStream::connect(dest);
    let mut upstream = tokio::time::timeout(Duration::from_secs(10), connect)
        .await
        .map_err(|_| {
            io::Error::new(io::ErrorKind::TimedOut, "connect to original destination")
        })??;
    let _ = client.set_nodelay(true);
    let _ = upstream.set_nodelay(true);
    match tokio::io::copy_bidirectional(&mut client, &mut upstream).await {
        Ok(_) => {
            let _ = upstream.shutdown().await;
            let _ = client.shutdown().await;
            Ok(())
        }
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use std::net::SocketAddr;
    use std::time::Duration;

    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    use super::*;
    use crate::arm::parse_arm_facts;

    fn excluded() -> ExclusionSet {
        parse_arm_facts(
            "\
sw_mode=1
ifname=br0
lan_ip=192.168.50.1
lan_mask=255.255.255.0
primary_ip=192.168.50.1
local_ip=192.168.50.1
",
        )
        .unwrap()
        .exclusions()
    }

    fn bind() -> SocketAddr {
        "192.168.50.1:39527".parse().unwrap()
    }

    #[test]
    fn missing_or_excluded_destinations_are_not_direct() {
        let excluded = excluded();
        let bind = bind();
        assert_eq!(plan_relay(None, bind, &excluded), RelayPlan::Drop);
        assert_eq!(
            plan_relay(Some("192.168.50.9:443".parse().unwrap()), bind, &excluded),
            RelayPlan::Drop
        );
        assert_eq!(
            plan_relay(Some("192.168.50.1:39527".parse().unwrap()), bind, &excluded),
            RelayPlan::Drop
        );
        assert_eq!(
            plan_relay(Some("1.1.1.1:443".parse().unwrap()), bind, &excluded),
            RelayPlan::Direct("1.1.1.1:443".parse().unwrap())
        );
    }

    #[tokio::test]
    async fn direct_relay_copies_payload_to_the_injected_destination() {
        let dest = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let dest_addr = dest.local_addr().unwrap();
        let client_side = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let client_addr = client_side.local_addr().unwrap();
        let mut client = TcpStream::connect(client_addr).await.unwrap();
        let (accepted, _) = client_side.accept().await.unwrap();
        let server = tokio::spawn(async move {
            let (mut sock, _) = dest.accept().await.unwrap();
            let mut buf = [0_u8; 4];
            sock.read_exact(&mut buf).await.unwrap();
            buf
        });
        let relayed = tokio::spawn(relay_direct(accepted, dest_addr));
        client.write_all(b"ping").await.unwrap();
        client.shutdown().await.unwrap();
        let got = tokio::time::timeout(Duration::from_secs(2), server)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(&got, b"ping");
        relayed.await.unwrap().unwrap();
    }

    #[test]
    fn classification_does_not_open_a_socket() {
        let excluded = excluded();
        let bind = bind();
        assert!(matches!(
            plan_relay(Some("1.1.1.1:443".parse().unwrap()), bind, &excluded),
            RelayPlan::Direct(_)
        ));
    }
}
