//! Operator entry point for the Merlin redirect dataplane.
//!
//! stderr carries the short operational lines. This binary does not load the
//! honk-core eBPF backend.

use std::env;
use std::net::Ipv4Addr;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::{Duration, Instant};

use anyhow::Context;
use clap::{Parser, Subcommand};
use honk_config::parser::parse_dae_config;
use honk_dataplane::{
    KernelFacts, LISTEN_PORT, ListenError, MerlinAction, NAT_CHAIN, NAT_TABLE, NixOriginalDest,
    PlanError, PreferredBackend, ProxyPaths, SystemRunner, apply_redirect, conntrack_deletes,
    load_configured, merlin_action, parse_arm_facts, parse_conntrack, preferred_backend, serve,
    tcp_listening, unlink_redirect,
};
use tokio::signal::unix::{SignalKind, signal};
use tokio::sync::watch;

#[derive(Parser)]
#[command(name = "honk-dataplane")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Print the chain name and listen port the scripts must keep.
    Constants,
    /// Classify a kernel config. Does not install anything.
    Probe {
        #[arg(long)]
        config: PathBuf,
    },
    /// Print the nat chain body for a facts file. Does not install it.
    Plan {
        #[arg(long)]
        facts: PathBuf,
    },
    /// Build `HONK_PRE` and append it to nat PREROUTING.
    Apply {
        #[arg(long)]
        facts: PathBuf,
        #[arg(long, default_value = "iptables")]
        iptables: String,
    },
    /// Remove the nat jump and chain. Does not delete conntrack.
    Unlink {
        #[arg(long, default_value = "iptables")]
        iptables: String,
    },
    /// Delete conntrack entries whose reply half is the listen socket.
    ConntrackDelete {
        #[arg(long)]
        listen_ip: Ipv4Addr,
        #[arg(long)]
        proc: Option<PathBuf>,
    },
    /// Bind the primary address. With `--config`, route instead of copying.
    Listen {
        #[arg(long)]
        facts: PathBuf,
        #[arg(long)]
        ready: PathBuf,
        #[arg(long)]
        config: Option<PathBuf>,
        #[arg(long)]
        cache: Option<PathBuf>,
        #[arg(long)]
        selections: Option<PathBuf>,
    },
    /// Load a dae file and print node, group, and rule counts.
    Summary {
        #[arg(long)]
        config: PathBuf,
        #[arg(long)]
        cache: Option<PathBuf>,
        #[arg(long)]
        selections: PathBuf,
    },
    /// Exit 0 when `/proc/net/tcp` shows the listen socket.
    CheckListen {
        #[arg(long)]
        facts: PathBuf,
        #[arg(long)]
        proc: Option<PathBuf>,
    },
    /// Parse a dae file and exit 0 when honk-config accepts it.
    CheckConfig {
        #[arg(long)]
        config: PathBuf,
    },
    /// Filter a Surge node list and write the lines that remain.
    ImportSurge {
        #[arg(long)]
        input: PathBuf,
        #[arg(long, default_value = "")]
        regex: String,
        #[arg(long)]
        out: PathBuf,
    },
    /// Print the first subscription URL, or nothing when the file has none.
    SubscriptionUrl {
        #[arg(long)]
        config: PathBuf,
    },
    /// Print group `<select>` rows for the Merlin page.
    UiFragment {
        #[arg(long)]
        config: PathBuf,
        #[arg(long)]
        cache: Option<PathBuf>,
        #[arg(long)]
        selections: PathBuf,
    },
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("honk-dataplane: {error:#}");
            let code = if error.downcast_ref::<PlanError>().is_some() {
                2
            } else {
                1
            };
            ExitCode::from(code)
        }
    }
}

async fn run() -> anyhow::Result<()> {
    match Cli::parse().command {
        Command::Constants => {
            println!("chain={NAT_CHAIN}");
            println!("table={NAT_TABLE}");
            println!("port={LISTEN_PORT}");
        }
        Command::Probe { config } => {
            let text = std::fs::read_to_string(&config)
                .with_context(|| format!("read {}", config.display()))?;
            let facts = KernelFacts::from_config(&text);
            println!("preferred={}", backend_name(preferred_backend(&facts)));
            println!("merlin={}", action_name(merlin_action(&facts)));
            println!("bpf_syscall={}", yes(facts.bpf_syscall));
            println!("cgroups={}", yes(facts.cgroups));
            println!("namespaces={}", yes(facts.namespaces));
            println!("redirect_v4={}", yes(facts.redirect_v4));
            println!("tproxy_v4={}", yes(facts.tproxy_v4));
            println!("tun={}", yes(facts.tun));
        }
        Command::Plan { facts } => {
            let plan = load_plan(&facts)?;
            for rule in plan.chain_rules("iptables") {
                println!("{} {}", rule.program, rule.args.join(" "));
            }
        }
        Command::Apply { facts, iptables } => {
            let plan = load_plan(&facts)?;
            apply_redirect(&plan, &iptables, &SystemRunner)?;
        }
        Command::Unlink { iptables } => {
            unlink_redirect(&iptables, &SystemRunner)?;
        }
        Command::ConntrackDelete { listen_ip, proc } => {
            let path = proc.unwrap_or_else(conntrack_proc_path);
            let text = std::fs::read_to_string(&path)
                .with_context(|| format!("read {}", path.display()))?;
            let tuples = parse_conntrack(&text, listen_ip, LISTEN_PORT);
            let program = env::var("HONK_CONNTRACK").unwrap_or_else(|_| "conntrack".to_owned());
            let deadline = conntrack_deadline();
            delete_conntrack(&program, &tuples, deadline)?;
        }
        Command::Listen {
            facts,
            ready,
            config,
            cache,
            selections,
        } => {
            let plan = load_plan(&facts)?;
            let proxy = match config {
                Some(config) => {
                    let selections =
                        selections.unwrap_or_else(|| config.with_file_name("select.txt"));
                    let report = load_configured(&config, cache.as_deref(), &selections)?;
                    eprintln!("honk-dataplane: {}", report.log_line(&config));
                    Some(ProxyPaths {
                        config,
                        cache,
                        selections,
                    })
                }
                None => {
                    eprintln!("honk-dataplane: config absent direct-copy");
                    None
                }
            };
            let (tx, rx) = watch::channel(false);
            tokio::spawn(async move {
                if let (Ok(mut terminate), Ok(mut interrupt)) = (
                    signal(SignalKind::terminate()),
                    signal(SignalKind::interrupt()),
                ) {
                    tokio::select! {
                        _ = terminate.recv() => {}
                        _ = interrupt.recv() => {}
                    }
                    let _ = tx.send(true);
                }
            });
            serve(plan, &ready, proxy, NixOriginalDest, rx)
                .await
                .map_err(|error| match error {
                    ListenError::Io(error) => anyhow::Error::from(error),
                    other => anyhow::anyhow!(other),
                })?;
        }
        Command::CheckListen { facts, proc } => {
            let plan = load_plan(&facts)?;
            let path = proc.unwrap_or_else(|| PathBuf::from("/proc/net/tcp"));
            let text = std::fs::read_to_string(&path)
                .with_context(|| format!("read {}", path.display()))?;
            if !tcp_listening(&text, plan.listen_ip, plan.listen_port) {
                anyhow::bail!(
                    "listener is not bound to {}:{}",
                    plan.listen_ip,
                    plan.listen_port
                );
            }
        }
        Command::Summary {
            config,
            cache,
            selections,
        } => {
            let report = load_configured(&config, cache.as_deref(), &selections)?;
            println!("{}", report.log_line(&config));
        }
        Command::CheckConfig { config } => {
            let text = std::fs::read_to_string(&config)
                .with_context(|| format!("read {}", config.display()))?;
            parse_dae_config(&text)?;
            println!("ok");
        }
        Command::SubscriptionUrl { config } => {
            let text = std::fs::read_to_string(&config)
                .with_context(|| format!("read {}", config.display()))?;
            let parsed = parse_dae_config(&text)?;
            if let Some(subscription) = parsed.subscriptions.first() {
                println!("{}", subscription.url);
            }
        }
        Command::ImportSurge { input, regex, out } => {
            let text = std::fs::read_to_string(&input)
                .with_context(|| format!("read {}", input.display()))?;
            let filtered = honk_dataplane::surge_filter(&text, &regex);
            if let Some(parent) = out.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(&out, filtered)?;
        }
        Command::UiFragment {
            config,
            cache,
            selections,
        } => {
            let html = honk_dataplane::ui_rows(&config, cache.as_deref(), &selections)?;
            print!("{html}");
        }
    }
    Ok(())
}

fn load_plan(path: &std::path::Path) -> anyhow::Result<honk_dataplane::RedirectPlan> {
    let text = std::fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    parse_arm_facts(&text).map_err(anyhow::Error::from)
}

fn kill_delete(child: &mut std::process::Child) {
    let id = child.id();
    let _ = child.kill();
    #[cfg(unix)]
    {
        let _ = std::process::Command::new("/bin/kill")
            .args(["-9", &format!("-{id}")])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
    }
    let _ = child.wait();
}

fn conntrack_deadline() -> Duration {
    env::var("HONK_CONNTRACK_DEADLINE_MS")
        .ok()
        .and_then(|text| text.parse::<u64>().ok())
        .map(Duration::from_millis)
        .unwrap_or_else(|| Duration::from_secs(5))
}

fn delete_conntrack(
    program: &str,
    tuples: &[honk_dataplane::ConntrackTuple],
    deadline: Duration,
) -> anyhow::Result<()> {
    let start = Instant::now();
    for delete in conntrack_deletes(program, tuples) {
        if start.elapsed() >= deadline {
            anyhow::bail!("conntrack delete timed out");
        }
        let mut command = std::process::Command::new(&delete.program);
        command
            .args(&delete.args)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            command.process_group(0);
        }
        let mut child = command.spawn().with_context(|| format!("run {program}"))?;
        let born = Instant::now();
        let per_call = Duration::from_secs(2);
        loop {
            if let Some(status) = child.try_wait()? {
                if !status.success() {
                    eprintln!(
                        "honk-dataplane: conntrack delete exited {}",
                        status.code().unwrap_or(1)
                    );
                }
                break;
            }
            if born.elapsed() >= per_call || start.elapsed() >= deadline {
                kill_delete(&mut child);
                anyhow::bail!("conntrack delete timed out");
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }
    Ok(())
}

fn conntrack_proc_path() -> PathBuf {
    env::var("HONK_CONNTRACK_PROC")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/proc/net/nf_conntrack"))
}

fn backend_name(backend: PreferredBackend) -> &'static str {
    match backend {
        PreferredBackend::Ebpf => "ebpf",
        PreferredBackend::NetfilterRedirect => "netfilter-redirect",
        PreferredBackend::Unavailable => "unavailable",
    }
}

fn action_name(action: MerlinAction) -> &'static str {
    match action {
        MerlinAction::NetfilterRedirect => "netfilter-redirect",
        MerlinAction::Refuse => "refuse",
    }
}

fn yes(value: bool) -> &'static str {
    if value { "yes" } else { "no" }
}
