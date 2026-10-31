# honk on the RT-BE88U

Phase 1 of an Asuswrt-Merlin addon. Hardware acceleration is out of scope. The eBPF datapath stays in `honk-core`. On the BE88U kernel this addon installs an IPv4 TCP REDIRECT and copies bytes to the original destination.

The Chinese operator guide is [README_merlin.md](README_merlin.md). It has the architecture diagram, the done/stub table, and the on-router steps.

Public sources used for the target, not a session on the router:

- An amtm banner on SNBForums: `ASUS RT-BE88U HW: aarch64 Kernel: 4.19.294`, firmware `3006.102.3`.
- Merlin's router Makefile: `HND_ROUTER_BE_4916` uses Linux 4.19.235 unless `ASUSWRT_BRCM_SDK_VERSION` is `WIFI7_SDK_20250506`, which selects 5.15.167.
- `config_base.6a.6813` is headed `Linux/arm64 4.19.294`. `CONFIG_BPF_SYSCALL`, cgroups, and namespaces are off. REDIRECT is built in. The TPROXY target is modular while `CONFIG_NF_TPROXY_IPV4` is off, so TPROXY is not treated as available. TUN is a module.

`python3 merlin/tools/surge2honk.py profile.conf -o config.dae` writes a dae file. See `docs/merlin-config.md` for the schema. `merlin/build.sh` produces a static `aarch64-unknown-linux-musl` `honk-core` (features `clash-api`, `mimalloc`, `rprx`, `redirect`; no `ebpf`), a pre-seeded zashboard tree, and `geoip.dat` / `geosite.dat`. Install does not intercept. Every boot clears the nat jump and does not start the listener.

Enable refuses unless `config.dae` exists, the model is RT-BE88U, `sw_mode` is 1, `conntrack -C` works, a WAN gateway is present, and the LAN interface primary address matches `lan_ipaddr`. It then runs `honk-core -c config.dae --redirect <lan-ip>:<tproxy_port>` with `DAE_LOCATION_ASSET` pointed at the addon directory. honk-core fetches subscriptions itself, with its own user agent, and accepts a base64 list of `ss://` links. The nat chain returns router addresses, the LAN prefix, TCP ports 53 and 9090, and `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, and `100.64.0.0/10` before one REDIRECT. While armed, `/bin/fc` and `/bin/runner` are disabled and flushed when they exist; disarm restores the state recorded at arm. Disarm kills only the listener and watcher pid files, then deletes conntrack entries whose reply source is the listener. UDP is not redirected. The addon install leaves dnsmasq alone.

Add this block to the existing `config.dae` (an empty secret means the LAN can call the API):

```dae
experimental {
    clash_api {
        external_controller: '192.168.2.1:9090'
        external_ui: '/jffs/addons/honk/ui'
    }
}
```

The panel is `http://192.168.2.1:9090/ui/`.

Not in this phase: redirecting UDP into honk, TUN, TPROXY, launching eBPF, IPv6, and guest bridges. `firewall-start` rejects LAN UDP/443 so QUIC falls back to the TCP redirect; other UDP is unchanged. Flow cache is suspended only while armed; nvram is not edited. This repository has no LuCI tree. `merlin/scripts/dnsmasq.postconf` is the router's current file and `honk_install` does not copy it to `/jffs/scripts`.
