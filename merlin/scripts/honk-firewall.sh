#!/bin/sh
# Merlin calls firewall-start with the WAN interface in $1.
# Do not treat that name as the LAN bridge and do not change iptables NAT here.
# Block LAN QUIC (UDP/443) so Google/Chrome fall back to TCP via HONK_PRE REDIRECT.
set +e
IFNAME=$(nvram get lan_ifname 2>/dev/null)
IFNAME=${IFNAME:-br0}
iptables -C FORWARD -i "$IFNAME" -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || \
  iptables -I FORWARD 1 -i "$IFNAME" -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable
ip6tables -C FORWARD -i "$IFNAME" -p udp --dport 443 -j REJECT --reject-with icmp6-port-unreachable 2>/dev/null || \
  ip6tables -I FORWARD 1 -i "$IFNAME" -p udp --dport 443 -j REJECT --reject-with icmp6-port-unreachable
exit 0
