Added

- Merlin phase 1 can arm an IPv4 TCP REDIRECT on RT-BE88U kernels without the BPF syscall, cgroups, or namespaces, and it stays off until enabled on that boot.
- A Surge profile can be converted to a honk dae file, and enabled LAN TCP can then be matched and sent direct or through a chacha20-ietf-poly1305 Shadowsocks node.
- The Merlin tab is inserted after the System page URL even when its tab token is not `menu5_6_2`. Install reports `menu_anchor_not_found` and does not report `installed` when that URL is not present exactly once.
- Router scripts find conntrack and the other tools by absolute path, and the web page shows why Enable was refused.
- Enable requires config.dae. honk-core fetches the subscription itself. Disarm stops only the pid-file listener and watcher, even when conntrack delete is slow, and does not scan command lines.
- The Merlin Honk page is Simplified Chinese. Strategy groups are chosen in the Clash panel at `http://192.168.2.1:9090/ui/`.
- Enable starts upstream `honk-core` with `--redirect` on the LAN address. iptables REDIRECT covers other IPv4 TCP. UDP is not redirected, and DNS stays on dnsmasq. Private destinations, the router itself, and TCP ports 53 and 9090 are returned before REDIRECT.
- While Honk is armed, Broadcom flow cache and runner are disabled and flushed, then restored to the state recorded at arm.
- The addon archive includes a static aarch64 `honk-core` without eBPF, a pre-seeded zashboard UI, and `geoip.dat` / `geosite.dat`. Subscriptions use honk's own client, which accepts a base64 `ss://` list.
