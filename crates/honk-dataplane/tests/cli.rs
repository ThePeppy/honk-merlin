use std::io::Write;
use std::process::Command;

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_honk-dataplane"))
}

#[test]
fn constants_match_the_chain_the_scripts_own() {
    let output = bin().arg("constants").output().unwrap();
    assert!(output.status.success());
    let text = String::from_utf8(output.stdout).unwrap();
    assert!(text.contains("chain=HONK_PRE\n"));
    assert!(text.contains("port=39527\n"));
    assert!(text.contains("table=nat\n"));
}

#[test]
fn plan_refuses_a_loopback_primary_without_printing_redirect() {
    let mut facts = tempfile_facts(
        "\
sw_mode=1
ifname=br0
lan_ip=127.0.0.1
lan_mask=255.0.0.0
primary_ip=127.0.0.1
local_ip=127.0.0.1
",
    );
    let output = bin()
        .arg("plan")
        .arg("--facts")
        .arg(&facts.path)
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(2));
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(!stdout.contains("REDIRECT"), "{stdout}");
    facts.keep = false;
}

#[test]
fn valid_plan_is_br0_tcp_redirect_without_output_or_ip_rule() {
    let facts = tempfile_facts(
        "\
sw_mode=1
ifname=br0
lan_ip=192.168.50.1
lan_mask=255.255.255.0
primary_ip=192.168.50.1
local_ip=192.168.50.1
local_ip=203.0.113.8
",
    );
    let output = bin()
        .arg("plan")
        .arg("--facts")
        .arg(&facts.path)
        .output()
        .unwrap();
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(stdout.lines().all(|line| line.starts_with("iptables ")));
    assert!(stdout.contains("-i br0"));
    assert!(stdout.contains("-p tcp"));
    assert!(stdout.contains("-d 192.168.50.0/24"));
    assert!(stdout.contains("-d 203.0.113.8"));
    assert!(stdout.trim_end().ends_with("--to-ports 39527"));
    assert!(!stdout.contains("OUTPUT"));
    assert!(!stdout.contains("ip rule"));
    assert!(!stdout.contains("TPROXY"));
    assert!(!stdout.contains("udp"));
    let _ = facts;
}

#[test]
fn conntrack_delete_uses_the_original_tuple_and_never_flushes() {
    let dir = std::env::temp_dir().join(format!("honk-ct-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let proc_path = dir.join("nf_conntrack");
    std::fs::write(
        &proc_path,
        "\
ipv4     2 tcp      6 119 TIME_WAIT src=10.66.0.2 dst=9.9.9.9 sport=33714 dport=443 src=10.66.0.1 dst=10.66.0.2 sport=39527 dport=33714 [ASSURED] mark=0 zone=0 use=2
ipv4     2 tcp      6 119 TIME_WAIT src=10.66.0.1 dst=10.66.0.1 sport=33664 dport=9 src=10.66.0.1 dst=10.66.0.1 sport=9 dport=33664 [ASSURED] mark=0 zone=0 use=2
",
    )
    .unwrap();
    let log = dir.join("conntrack.log");
    let fake = dir.join("conntrack");
    let mut file = std::fs::File::create(&fake).unwrap();
    writeln!(
        file,
        "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"{}\"\nexit 0\n",
        log.display()
    )
    .unwrap();
    drop(file);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(&fake).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&fake, perms).unwrap();
    }
    let output = bin()
        .arg("conntrack-delete")
        .arg("--listen-ip")
        .arg("10.66.0.1")
        .arg("--proc")
        .arg(&proc_path)
        .env("HONK_CONNTRACK", &fake)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let logged = std::fs::read_to_string(&log).unwrap();
    assert_eq!(
        logged.trim(),
        "-D -p tcp -s 10.66.0.2 -d 9.9.9.9 --sport 33714 --dport 443"
    );
    assert!(!logged.contains("-F"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn conntrack_delete_returns_when_the_tool_hangs() {
    let dir = std::env::temp_dir().join(format!("honk-ct-hang-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let proc_path = dir.join("nf_conntrack");
    std::fs::write(
        &proc_path,
        "ipv4     2 tcp      6 119 TIME_WAIT src=10.66.0.2 dst=9.9.9.9 sport=33714 dport=443 src=10.66.0.1 dst=10.66.0.2 sport=39527 dport=33714 [ASSURED] mark=0 zone=0 use=2\n",
    )
    .unwrap();
    let fake = dir.join("conntrack");
    std::fs::write(&fake, "#!/bin/sh\nexec sleep 30\n").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(&fake).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&fake, perms).unwrap();
    }
    let started = std::time::Instant::now();
    let output = bin()
        .arg("conntrack-delete")
        .arg("--listen-ip")
        .arg("10.66.0.1")
        .arg("--proc")
        .arg(&proc_path)
        .env("HONK_CONNTRACK", &fake)
        .env("HONK_CONNTRACK_DEADLINE_MS", "400")
        .output()
        .unwrap();
    assert!(started.elapsed().as_secs() < 3, "delete did not time out");
    assert!(!output.status.success());
    let err = String::from_utf8_lossy(&output.stderr);
    assert!(err.contains("timed out"), "{err}");
    let _ = std::fs::remove_dir_all(&dir);
}

struct Facts {
    path: std::path::PathBuf,
    keep: bool,
}

impl Drop for Facts {
    fn drop(&mut self) {
        if !self.keep {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

fn tempfile_facts(text: &str) -> Facts {
    let path = std::env::temp_dir().join(format!(
        "honk-facts-{}-{}.txt",
        std::process::id(),
        text.len()
    ));
    std::fs::write(&path, text).unwrap();
    Facts { path, keep: false }
}
