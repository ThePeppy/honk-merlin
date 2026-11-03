#!/bin/sh
# firewall-start child. While the addon is armed, reject LAN UDP/443 so QUIC
# falls back to the TCP redirect. After stop or boot the reject must be gone.
# `add` and `remove` force one side; no argument syncs with the arm token.
set +e
HONK_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$HONK_SCRIPT_DIR/honk-common.sh"
honk_pin_bins
mode=${1:-sync}
if [ "$mode" = sync ]; then
    if [ -f "$(honk_state honk.armed)" ]; then
        mode=add
    else
        mode=remove
    fi
fi
ifname=$("$HONK_NVRAM" get lan_ifname 2>/dev/null)
ifname=${ifname:-br0}
# shellcheck disable=SC2086
v4="-i $ifname -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable"
# shellcheck disable=SC2086
v6="-i $ifname -p udp --dport 443 -j REJECT --reject-with icmp6-port-unreachable"
ip6=$(honk_resolve ip6tables || true)
case $mode in
    add)
        "$HONK_IPTABLES" -C FORWARD $v4 >/dev/null 2>&1 ||
            "$HONK_IPTABLES" -I FORWARD 1 $v4 >/dev/null 2>&1
        if [ -n "$ip6" ]; then
            "$ip6" -C FORWARD $v6 >/dev/null 2>&1 ||
                "$ip6" -I FORWARD 1 $v6 >/dev/null 2>&1
        fi
        ;;
    remove)
        i=0
        while [ "$i" -lt 8 ] && "$HONK_IPTABLES" -D FORWARD $v4 >/dev/null 2>&1; do
            i=$((i + 1))
        done
        if [ -n "$ip6" ]; then
            i=0
            while [ "$i" -lt 8 ] && "$ip6" -D FORWARD $v6 >/dev/null 2>&1; do
                i=$((i + 1))
            done
        fi
        ;;
esac
exit 0
