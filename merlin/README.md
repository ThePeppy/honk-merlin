# honk on the RT-BE88U

Phase 1 of an Asuswrt-Merlin addon. Hardware acceleration is out of scope. The eBPF datapath stays in `honk-core`. On the BE88U kernel this addon installs an IPv4 TCP REDIRECT and copies bytes to the original destination.

The Chinese operator guide is [README_merlin.md](README_merlin.md). It has the architecture diagram, the done/stub table, and the on-router steps.

Public sources used for the target, not a session on the router:

- An amtm banner on SNBForums: `ASUS RT-BE88U HW: aarch64 Kernel: 4.19.294`, firmware `3006.102.3`.
- Merlin's router Makefile: `HND_ROUTER_BE_4916` uses Linux 4.19.235 unless `ASUSWRT_BRCM_SDK_VERSION` is `WIFI7_SDK_20250506`, which selects 5.15.167.
- `config_base.6a.6813` is headed `Linux/arm64 4.19.294`. `CONFIG_BPF_SYSCALL`, cgroups, and namespaces are off. REDIRECT is built in. The TPROXY target is modular while `CONFIG_NF_TPROXY_IPV4` is off, so TPROXY is not treated as available. TUN is a module.

`python3 merlin/tools/surge2honk.py profile.conf -o config.dae` writes a dae file. See `docs/merlin-config.md` for the schema. `merlin/build.sh` produces a static `aarch64-unknown-linux-musl` tarball. Install does not intercept. Every boot clears the nat jump. Enable refuses unless the model is RT-BE88U, `sw_mode` is 1, `conntrack -C` works, a WAN gateway is present, and the LAN interface primary address matches `lan_ipaddr`. conntrack and the other router tools are found by absolute path under `/usr/sbin`, `/usr/bin`, `/sbin`, `/opt/sbin`, and `/opt/bin`. A refusal is shown on the page after it reloads. When `config.dae` exists, Enable fetches its subscription with direct curl (`User-Agent: Surge`) and passes `--config` to the listener. The body may be Surge lines or a plain or base64 list of SIP002 `ss://` links; the log records the detected format and node count. A failed fetch does not install the nat jump. Disarm kills the listener and watcher by pid file and the dataplane executable path, before a bounded conntrack delete. honk-core's Clash API is not part of this dataplane, so port 9090 is not opened. The confirm timer, a dead listener, or repeated gateway ping failures unlink the chain, delete only the conntrack entries whose reply half is the listen socket, and stop the process. Uninstall also unlinks when the binary is missing.

Not in this phase: honk-outbound dialling, UDP, TUN, TPROXY, launching eBPF, IPv6, guest bridges, and any nvram change to Broadcom flow cache. This repository has no LuCI tree.
