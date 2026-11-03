# honk on the RT-BE88U

Phase 1 of an Asuswrt-Merlin addon. Hardware acceleration is out of scope. The eBPF datapath stays in `honk-core`. On the BE88U kernel this addon installs an IPv4 TCP REDIRECT and copies bytes to the original destination.

The Chinese operator guide is [README_merlin.md](README_merlin.md). It has the architecture diagram, the done/stub table, and the on-router steps.

Public sources used for the target, not a session on the router:

- An amtm banner on SNBForums: `ASUS RT-BE88U HW: aarch64 Kernel: 4.19.294`, firmware `3006.102.3`.
- Merlin's router Makefile: `HND_ROUTER_BE_4916` uses Linux 4.19.235 unless `ASUSWRT_BRCM_SDK_VERSION` is `WIFI7_SDK_20250506`, which selects 5.15.167.
- `config_base.6a.6813` is headed `Linux/arm64 4.19.294`. `CONFIG_BPF_SYSCALL`, cgroups, and namespaces are off. REDIRECT is built in. The TPROXY target is modular while `CONFIG_NF_TPROXY_IPV4` is off, so TPROXY is not treated as available. TUN is a module.

`python3 merlin/tools/surge2honk.py profile.conf -o config.dae` writes a dae file. See `docs/merlin-config.md` for the schema. `merlin/build.sh` produces a static `aarch64-unknown-linux-musl` `honk-core` (features `native-api`, `mimalloc`, `redirect`; no `clash-api`, `rprx`, or `ebpf`), pinned doona, and `geoip.dat` / `geosite.dat` stripped to `cn` and `private`. Install does not intercept. Every boot clears the nat jump and does not start the listener.

Enable refuses unless `config.dae` exists, the model is RT-BE88U, `sw_mode` is 1, `conntrack -C` works, a WAN gateway is present, and the LAN interface primary address matches `lan_ipaddr`. It then runs `honk-core -c config.dae --redirect <lan-ip>:<tproxy_port>` with `DAE_LOCATION_ASSET` pointed at the addon directory. honk-core fetches subscriptions itself, with its own user agent, and accepts a base64 list of `ss://` links. The nat chain returns router addresses, the LAN prefix, TCP ports 53 and 9090, and `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, and `100.64.0.0/10` before one REDIRECT. While armed, `/bin/fc` and `/bin/runner` are disabled and flushed when they exist; disarm restores the state recorded at arm. Disarm kills only the listener and watcher pid files, then deletes conntrack entries whose reply source is the listener. UDP is not redirected. The addon install leaves dnsmasq alone.

Add this block to the existing `config.dae`. Put `experimental.native_api.secret` in a 0600 include such as `secrets.dae` so `config_write` can edit the main file. Do not also set `password_auth`.

```dae
experimental {
    native_api {
        enabled: true
        listen: '192.168.2.1:9090'
        allow_origins: 'http://192.168.2.1:9090'
        config_write: true
        ui: '/jffs/addons/honk/ui'
    }
}
```

The panel is `http://192.168.2.1:9090/ui/`. The binary has no Clash API; remove any `clash_api` block or the listener will not exist.

## Web UI and install

The addon adds a top-level `Honk` entry to the router sidebar (own icon, one page, no tab strip) as the last item under General Settings. It copies `/www/require/modules/menuTree.js` to `/tmp`, inserts one section immediately before the second of the two `index: "menu_Split"` headers (Advanced Settings; 3006.102 dictionary `<#581#>`, named-token trees `<#menu5#>`), and bind-mounts the copy; one icon rule is appended to a bind-mounted copy of `/www/index_style.css` the same way. Any count other than two splits leaves the stock files untouched and fails the install with `menu_anchor_not_found`.

Install from SSH with one command; re-running it upgrades in place:

```sh
cd /tmp && rm -rf honk honk.tgz && curl -fsSL -o honk.tgz https://github.com/ThePeppy/honk-merlin/releases/download/merlin/honk-be88u.tar.gz && tar zxf honk.tgz && sh honk/scripts/install.sh; rc=$?; rm -rf /tmp/honk /tmp/honk.tgz; (exit $rc)
```

Pushing a `merlin-v*` tag rebuilds and republishes that URL with `SHA256SUMS`. `sh /jffs/addons/honk/scripts/uninstall.sh` removes everything, including both mounts.

Not in this phase: redirecting UDP into honk, TUN, TPROXY, launching eBPF, IPv6, and guest bridges. `firewall-start` rejects LAN UDP/443 only while armed so QUIC falls back to the TCP redirect; after stop the reject is removed. Flow cache is suspended only while armed; nvram is not edited. This repository has no LuCI tree. `honk_install` installs a `dnsmasq.postconf` hook that points the upstream at `127.0.0.1#5354` only while armed; disarm and boot restore the firmware upstream, so a stopped addon cannot black-hole LAN DNS.
