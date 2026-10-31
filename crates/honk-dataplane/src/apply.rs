//! Install the redirect chain only after its body is complete.
//!
//! The jump is removed before the body is rebuilt and appended only after
//! every exclusion and the single REDIRECT rule succeeded. A failure leaves
//! PREROUTING without `HONK_PRE`.

use std::io;
use std::process::{Command, Stdio};

use thiserror::Error;

use crate::arm::{
    Argv, PlanError, RedirectPlan, append_jump, check_jump, ensure_chain, unlink_commands,
};

pub trait Runner {
    fn run(&self, argv: &Argv) -> Result<i32, io::Error>;
}

pub struct SystemRunner;

impl Runner for SystemRunner {
    fn run(&self, argv: &Argv) -> Result<i32, io::Error> {
        let mut command = Command::new(&argv.program);
        command.args(&argv.args);
        // -N/-D/-C/-F/-X miss when the chain or jump is not there yet.
        // iptables writes that miss to stderr; the caller already treats it
        // as the signal to create or append.
        if argv
            .args
            .iter()
            .any(|arg| matches!(arg.as_str(), "-N" | "-D" | "-C" | "-F" | "-X"))
        {
            command.stderr(Stdio::null());
        }
        let status = command.status()?;
        Ok(status.code().unwrap_or(1))
    }
}

#[derive(Debug, Error)]
pub enum ApplyError {
    #[error(transparent)]
    Plan(#[from] PlanError),
    #[error("iptables {step} exited {code}")]
    Command { step: String, code: i32 },
    #[error(transparent)]
    Io(#[from] io::Error),
}

pub fn apply_redirect(
    plan: &RedirectPlan,
    iptables: &str,
    runner: &dyn Runner,
) -> Result<(), ApplyError> {
    // Creating an existing chain fails. That is not a reason to stop.
    let _ = runner.run(&ensure_chain(iptables))?;
    unlink_jumps(iptables, runner)?;
    must(runner, &unlink_commands(iptables)[1], "flush chain")?;
    for rule in plan.chain_rules(iptables) {
        if let Err(error) = must(runner, &rule, "insert exclusion or redirect") {
            let _ = unlink_redirect(iptables, runner);
            return Err(error);
        }
    }
    let present = runner.run(&check_jump(iptables))?;
    if present != 0 {
        must(runner, &append_jump(iptables), "append prerouting jump")?;
    }
    Ok(())
}

pub fn unlink_redirect(iptables: &str, runner: &dyn Runner) -> Result<(), ApplyError> {
    unlink_jumps(iptables, runner)?;
    // Flush and delete are expected to fail when the chain is already gone.
    let _ = runner.run(&unlink_commands(iptables)[1])?;
    let _ = runner.run(&unlink_commands(iptables)[2])?;
    Ok(())
}

fn unlink_jumps(iptables: &str, runner: &dyn Runner) -> Result<(), ApplyError> {
    let delete = &unlink_commands(iptables)[0];
    for _ in 0..20 {
        let code = runner.run(delete)?;
        if code != 0 {
            break;
        }
    }
    Ok(())
}

fn must(runner: &dyn Runner, argv: &Argv, step: &str) -> Result<(), ApplyError> {
    let code = runner.run(argv)?;
    if code == 0 {
        Ok(())
    } else {
        Err(ApplyError::Command {
            step: step.to_owned(),
            code,
        })
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;

    use super::*;
    use crate::arm::parse_arm_facts;

    struct Scripted {
        log: RefCell<Vec<Vec<String>>>,
        jump: RefCell<bool>,
        fail_redirect: bool,
    }

    impl Scripted {
        fn logged(&self) -> Vec<Vec<String>> {
            self.log.borrow().clone()
        }
    }

    impl Runner for Scripted {
        fn run(&self, argv: &Argv) -> Result<i32, io::Error> {
            self.log.borrow_mut().push(argv.args.clone());
            if argv
                .args
                .windows(2)
                .any(|pair| pair == ["-D", "PREROUTING"])
            {
                if *self.jump.borrow() {
                    *self.jump.borrow_mut() = false;
                    return Ok(0);
                }
                return Ok(1);
            }
            if argv
                .args
                .windows(2)
                .any(|pair| pair == ["-C", "PREROUTING"])
            {
                return Ok(if *self.jump.borrow() { 0 } else { 1 });
            }
            if argv
                .args
                .windows(2)
                .any(|pair| pair == ["-A", "PREROUTING"])
            {
                *self.jump.borrow_mut() = true;
                return Ok(0);
            }
            if self.fail_redirect && argv.args.iter().any(|arg| arg == "REDIRECT") {
                return Ok(2);
            }
            if argv.args.windows(2).any(|pair| pair == ["-N", "HONK_PRE"]) {
                return Ok(1);
            }
            Ok(0)
        }
    }

    fn plan() -> RedirectPlan {
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
    }

    #[test]
    fn jump_is_appended_once_after_the_body() {
        let runner = Scripted {
            log: RefCell::new(Vec::new()),
            jump: RefCell::new(false),
            fail_redirect: false,
        };
        apply_redirect(&plan(), "iptables", &runner).unwrap();
        let log = runner.logged();
        let link_at = log
            .iter()
            .position(|args| args.windows(2).any(|pair| pair == ["-A", "PREROUTING"]))
            .unwrap();
        assert!(link_at + 1 == log.len());
        assert!(
            log.iter()
                .any(|args| args.windows(2).any(|pair| pair == ["-j", "REDIRECT"]))
        );
        assert!(
            !log.iter()
                .any(|args| args.iter().any(|arg| arg == "-I" || arg == "OUTPUT"))
        );
        apply_redirect(&plan(), "iptables", &runner).unwrap();
        let log = runner.logged();
        let links = log
            .iter()
            .filter(|args| {
                args.windows(2)
                    .any(|w| w[0] == "-A" && w[1] == "PREROUTING")
            })
            .count();
        assert_eq!(links, 2);
        assert!(*runner.jump.borrow());
        assert!(!log.iter().any(|args| args.iter().any(|arg| arg == "-I")));
    }

    #[test]
    fn a_failed_redirect_does_not_link_prerouting() {
        let runner = Scripted {
            log: RefCell::new(Vec::new()),
            jump: RefCell::new(false),
            fail_redirect: true,
        };
        assert!(apply_redirect(&plan(), "iptables", &runner).is_err());
        let log = runner.logged();
        assert!(
            !log.iter()
                .any(|args| args.windows(2).any(|pair| pair == ["-A", "PREROUTING"]))
        );
        assert!(!*runner.jump.borrow());
    }
}
