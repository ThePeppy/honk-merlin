//! Read a kernel config the way `/proc/config.gz` prints it.
//!
//! A built-in `CONFIG_BPF=y` does not mean userspace can call the BPF syscall.
//! The published RT-BE88U config sets that symbol and still leaves
//! `CONFIG_BPF_SYSCALL`, cgroups, and namespaces unset. TPROXY is the same
//! kind of trap: `CONFIG_NETFILTER_XT_TARGET_TPROXY=m` is present while
//! `CONFIG_NF_TPROXY_IPV4` is not, so the target cannot be loaded.

/// What a capable honk-core host would run. Merlin does not launch this.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PreferredBackend {
    Ebpf,
    NetfilterRedirect,
    Unavailable,
}

/// What the phase-1 addon is allowed to install.
///
/// eBPF, TPROXY, and TUN stay visible on [`KernelFacts`] so a later image can
/// be recognised. The addon still only redirects, or it refuses.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MerlinAction {
    NetfilterRedirect,
    Refuse,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KernelFacts {
    pub bpf_syscall: bool,
    pub cgroups: bool,
    pub namespaces: bool,
    pub redirect_v4: bool,
    pub tproxy_v4: bool,
    pub tun: bool,
    pub policy_routing: bool,
}

impl KernelFacts {
    pub fn from_config(text: &str) -> Self {
        let redirect_target = config_flag(text, "CONFIG_NETFILTER_XT_TARGET_REDIRECT");
        let redirect_nat = config_flag(text, "CONFIG_IP_NF_TARGET_REDIRECT");
        let tproxy_target = config_flag(text, "CONFIG_NETFILTER_XT_TARGET_TPROXY");
        let tproxy_nat = config_flag(text, "CONFIG_NF_TPROXY_IPV4");
        Self {
            bpf_syscall: config_flag(text, "CONFIG_BPF_SYSCALL"),
            cgroups: config_flag(text, "CONFIG_CGROUPS"),
            namespaces: config_flag(text, "CONFIG_NAMESPACES"),
            redirect_v4: redirect_target || redirect_nat,
            tproxy_v4: tproxy_target && tproxy_nat,
            tun: config_flag(text, "CONFIG_TUN"),
            policy_routing: config_flag(text, "CONFIG_IP_ADVANCED_ROUTER")
                && config_flag(text, "CONFIG_IP_MULTIPLE_TABLES"),
        }
    }
}

pub fn preferred_backend(facts: &KernelFacts) -> PreferredBackend {
    if facts.bpf_syscall && facts.cgroups && facts.namespaces {
        PreferredBackend::Ebpf
    } else if facts.redirect_v4 {
        PreferredBackend::NetfilterRedirect
    } else {
        PreferredBackend::Unavailable
    }
}

pub fn merlin_action(facts: &KernelFacts) -> MerlinAction {
    if facts.redirect_v4 {
        MerlinAction::NetfilterRedirect
    } else {
        MerlinAction::Refuse
    }
}

/// `=y` and `=m` are enabled. `# CONFIG_NAME is not set` and absence are not.
/// The last matching line wins.
pub fn config_flag(text: &str, name: &str) -> bool {
    let set_prefix = format!("{name}=");
    let unset = format!("# {name} is not set");
    let mut enabled = false;
    for line in text.lines() {
        let line = line.trim();
        if line == unset {
            enabled = false;
        } else if let Some(value) = line.strip_prefix(&set_prefix) {
            enabled = value == "y" || value == "m";
        }
    }
    enabled
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Lines copied from Merlin `config_base.6a.6813` (Linux/arm64 4.19.294),
    /// the published RT-BE88U kernel config. `CONFIG_BPF=y` is included because
    /// a prefix match on `CONFIG_BPF` would mis-read the syscall flag.
    const BE88U_EXCERPT: &str = "\
# Linux/arm64 4.19.294 Kernel Configuration
CONFIG_BPF=y
# CONFIG_BPF_SYSCALL is not set
# CONFIG_CGROUPS is not set
# CONFIG_NAMESPACES is not set
CONFIG_IP_ADVANCED_ROUTER=y
CONFIG_IP_MULTIPLE_TABLES=y
CONFIG_NETFILTER_XT_TARGET_REDIRECT=y
CONFIG_NETFILTER_XT_TARGET_TPROXY=m
# CONFIG_NF_TPROXY_IPV4 is not set
# CONFIG_NF_TPROXY_IPV6 is not set
CONFIG_IP_NF_TARGET_REDIRECT=y
CONFIG_TUN=m
";

    #[test]
    fn be88u_config_selects_redirect_and_not_tproxy_or_ebpf() {
        let facts = KernelFacts::from_config(BE88U_EXCERPT);
        assert!(facts.redirect_v4);
        assert!(facts.tun);
        assert!(facts.policy_routing);
        assert!(!facts.bpf_syscall);
        assert!(!facts.cgroups);
        assert!(!facts.namespaces);
        assert!(!facts.tproxy_v4);
        assert_eq!(
            preferred_backend(&facts),
            PreferredBackend::NetfilterRedirect
        );
        assert_eq!(merlin_action(&facts), MerlinAction::NetfilterRedirect);
    }

    #[test]
    fn capable_kernel_stays_on_the_ebpf_preference_but_merlin_still_redirects() {
        let text = "\
CONFIG_BPF_SYSCALL=y
CONFIG_CGROUPS=y
CONFIG_NAMESPACES=y
CONFIG_IP_NF_TARGET_REDIRECT=y
CONFIG_NF_TPROXY_IPV4=y
CONFIG_NETFILTER_XT_TARGET_TPROXY=y
CONFIG_TUN=y
";
        let facts = KernelFacts::from_config(text);
        assert!(facts.tproxy_v4);
        assert_eq!(preferred_backend(&facts), PreferredBackend::Ebpf);
        assert_eq!(merlin_action(&facts), MerlinAction::NetfilterRedirect);
    }

    #[test]
    fn merlin_refuses_when_redirect_is_absent_even_if_ebpf_is_present() {
        let text = "\
CONFIG_BPF_SYSCALL=y
CONFIG_CGROUPS=y
CONFIG_NAMESPACES=y
# CONFIG_IP_NF_TARGET_REDIRECT is not set
# CONFIG_NETFILTER_XT_TARGET_REDIRECT is not set
";
        let facts = KernelFacts::from_config(text);
        assert_eq!(preferred_backend(&facts), PreferredBackend::Ebpf);
        assert_eq!(merlin_action(&facts), MerlinAction::Refuse);
    }

    #[test]
    fn later_line_wins() {
        let text = "\
CONFIG_TUN=y
# CONFIG_TUN is not set
";
        assert!(!config_flag(text, "CONFIG_TUN"));
    }
}
