//! Shadowsocks dial used after a rule selects a node.
//!
//! The full `honk-outbound` crate is not linked: its AEAD path is built on
//! BoringSSL. [`dial_honk_outbound`] follows that crate's legacy AEAD TCP
//! layout for `chacha20-ietf-poly1305` only.

pub async fn dial_honk_outbound(
    server_host: &str,
    server_port: u16,
    password: &str,
    host: &str,
    port: u16,
    stream: tokio::net::TcpStream,
    prelude: &[u8],
) -> std::io::Result<()> {
    crate::ss::relay(
        server_host,
        server_port,
        password,
        host,
        port,
        stream,
        prelude,
    )
    .await
}
