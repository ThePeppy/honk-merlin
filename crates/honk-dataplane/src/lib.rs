//! Kernel facts and the Merlin netfilter redirect plan.
//!
//! `honk-core` still owns the eBPF datapath. This crate does not load those
//! programs, create a network namespace, or attach a cgroup hook. Merlin calls
//! [`merlin_action`] and, in this phase, only installs [`RedirectPlan`] when
//! the kernel has the IPv4 REDIRECT target.

#![forbid(unsafe_code)]

mod apply;
mod arm;
mod conntrack;
mod facts;
mod listen;
mod outbound;
mod relay;

pub use apply::{ApplyError, Runner, SystemRunner, apply_redirect, unlink_redirect};
pub use arm::{
    ExclusionSet, LISTEN_PORT, NAT_CHAIN, PlanError, RedirectPlan, V4Net, parse_arm_facts,
};
pub use conntrack::{ConntrackDelete, ConntrackTuple, conntrack_deletes, parse_conntrack};
pub use facts::{
    KernelFacts, MerlinAction, PreferredBackend, config_flag, merlin_action, preferred_backend,
};
pub use listen::{ListenError, NixOriginalDest, serve, tcp_listening};
pub use outbound::{OutboundUnwired, dial_honk_outbound};
pub use relay::{OriginalDestination, RelayPlan, plan_relay, relay_direct};

pub const NAT_TABLE: &str = "nat";
