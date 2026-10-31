//! honk-outbound is intentionally not linked into this binary.
//!
//! Phase 1 copies bytes to the original destination so an enable test can be
//! rolled back without depending on a proxy node. Calling this function is the
//! explicit seam a later phase replaces; the accept loop does not call it.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OutboundUnwired;

impl std::fmt::Display for OutboundUnwired {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("honk-outbound dial is not wired in phase 1")
    }
}

impl std::error::Error for OutboundUnwired {}

pub fn dial_honk_outbound() -> Result<std::net::TcpStream, OutboundUnwired> {
    Err(OutboundUnwired)
}
