#!/bin/sh
# Exercise the addon scripts with fake nvram, iptables, and conntrack.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
scripts=$root/merlin/scripts
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

binlog=$work/bin.log
iptlog=$work/iptables.log
jump=$work/jump.count
echo 0 >"$jump"

mkdir -p "$work/bin" "$work/state" "$work/jffs/scripts" "$work/prefix/scripts" "$work/prefix/www"

cat >"$work/bin/nvram" <<'EOF'
#!/bin/sh
[ "${1:-}" = get ] || exit 1
case "${2:-}" in
    productid) printf '%s\n' RT-BE88U ;;
    odmpid) printf '\n' ;;
    sw_mode) printf '%s\n' 1 ;;
    wan0_gateway) printf '%s\n' 192.168.1.1 ;;
    wan_gateway) printf '\n' ;;
    lan_ifname) printf '%s\n' br0 ;;
    lan_ipaddr) printf '%s\n' 192.168.50.1 ;;
    lan_netmask) printf '%s\n' 255.255.255.0 ;;
    rc_support) printf '%s\n' "am_addons usb" ;;
    *) printf '\n' ;;
esac
EOF

cat >"$work/bin/ip" <<'EOF'
#!/bin/sh
if printf '%s\n' "$*" | grep -q 'dev br0'; then
    printf '%s\n' '2: br0    inet 192.168.50.1/24 brd 192.168.50.255 scope global br0'
    exit 0
fi
printf '%s\n' '2: br0    inet 192.168.50.1/24 brd 192.168.50.255 scope global br0'
printf '%s\n' '3: ppp0    inet 203.0.113.8/32 brd 203.0.113.8 scope global ppp0'
EOF

cat >"$work/bin/iptables" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$iptlog"
jump=$jump
count=\$(cat "\$jump")
if [ "\$1" = -t ] && [ "\$3" = -D ] && [ "\$4" = PREROUTING ]; then
    if [ "\$count" -gt 0 ]; then
        echo \$((count - 1)) > "\$jump"
        exit 0
    fi
    exit 1
fi
if [ "\$1" = -t ] && [ "\$3" = -C ] && [ "\$4" = PREROUTING ]; then
    [ "\$count" -gt 0 ]
    exit \$?
fi
if [ "\$1" = -t ] && [ "\$3" = -A ] && [ "\$4" = PREROUTING ]; then
    echo \$((count + 1)) > "\$jump"
    exit 0
fi
exit 0
EOF

cat >"$work/bin/conntrack" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$work/conntrack.log"
if [ "\${1:-}" = -F ]; then
    echo flush >> "$work/conntrack.log"
    exit 99
fi
if [ "\${1:-}" = -C ]; then
    if [ -f "$work/conntrack.fail" ]; then
        exit 1
    fi
    exit 0
fi
exit 0
EOF

cat >"$work/bin/ping" <<'EOF'
#!/bin/sh
if [ -f "$HONK_PING_FAIL" ]; then
    exit 1
fi
exit 0
EOF

cat >"$work/bin/honk-dataplane" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$binlog"
cmd=\${1:-}
shift || true
case "\$cmd" in
    plan) exit 0 ;;
    apply) exit 0 ;;
    check-listen) exit 0 ;;
    listen)
        ready=
        while [ \$# -gt 0 ]; do
            if [ "\$1" = --ready ]; then
                ready=\$2
                shift 2
            else
                shift
            fi
        done
        if [ -n "\$ready" ]; then
            printf '%s\n' '192.168.50.1:39527' > "\$ready"
        fi
        while :; do sleep 30; done
        ;;
    conntrack-delete) exit 0 ;;
    constants)
        printf '%s\n' 'chain=HONK_PRE'
        printf '%s\n' 'table=nat'
        printf '%s\n' 'port=39527'
        ;;
esac
exit 0
EOF

chmod 755 "$work/bin/"*

export PATH="$work/bin:$PATH"
export HONK_PREFIX="$work/prefix"
export HONK_STATE_DIR="$work/state"
export HONK_BIN="$work/bin/honk-dataplane"
export HONK_IPTABLES="$work/bin/iptables"
export HONK_CONNTRACK="$work/bin/conntrack"
export HONK_PING="$work/bin/ping"
export HONK_IP="$work/bin/ip"
export HONK_NVRAM="$work/bin/nvram"
export HONK_HELPER="$work/missing-helper"
export HONK_SETTINGS="$work/custom_settings.txt"
export HONK_SCRIPTS_DIR="$work/jffs/scripts"
export HONK_SCRIPT_DIR="$scripts"
export HONK_SKIP_WEBUI="1"
export HONK_SKIP_MOUNT="1"
export HONK_PING_FAIL=""

fail() {
    echo "safety: $*" >&2
    exit 1
}

# The firewall hook must not be able to install nat rules.
if grep -v '^#' "$scripts/honk-firewall.sh" | grep -q iptables; then
    fail "firewall-start script mentions iptables"
fi

constants=$("$HONK_BIN" constants)
printf '%s\n' "$constants" | grep -q 'chain=HONK_PRE' || fail "constants chain"
printf '%s\n' "$constants" | grep -q 'port=39527' || fail "constants port"
grep -q 'HONK_CHAIN=HONK_PRE' "$scripts/honk-common.sh" || fail "script chain drifted"
grep -q 'HONK_LISTEN_PORT=39527' "$scripts/honk-common.sh" || fail "script port drifted"

# shellcheck disable=SC1091
. "$scripts/honk-common.sh"

echo 0 >"$jump"
: >"$iptlog"
: >"$binlog"
printf '%s\n' 'honk_enable 1' >"$HONK_SETTINGS"
"$scripts/honk-nat.sh"
if [ -s "$iptlog" ] || grep -q apply "$binlog"; then
    fail "nat-start ran with stored enable and no arm token"
fi

if ! honk_gather_facts; then
    fail "gather rejected a complete BE88U facts set"
fi
grep -q '^local_ip=192.168.50.1$' "$work/state/honk.facts" || fail "primary missing from facts"
grep -q '^local_ip=203.0.113.8$' "$work/state/honk.facts" || fail "wan address missing from facts"
grep -q '^ifname=br0$' "$work/state/honk.facts" || fail "ifname missing from facts"
rm -f "$work/state/honk.facts" "$work/state/honk.gateway"

echo 0 >"$jump"
: >"$iptlog"
touch "$work/conntrack.fail"
if "$scripts/honk-arm.sh"; then
    fail "arm succeeded without conntrack"
fi
rm -f "$work/conntrack.fail"
if grep -q '^apply' "$binlog"; then
    fail "arm without conntrack called apply"
fi
if grep -q -- '-A PREROUTING' "$iptlog"; then
    fail "arm without conntrack linked PREROUTING"
fi

: >"$binlog"
: >"$iptlog"
echo 1 >"$jump"
HONK_BIN=$work/missing-bin "$scripts/honk-disarm.sh"
grep -q -- '-D PREROUTING -j HONK_PRE' "$iptlog" || fail "disarm without binary did not unlink"
[ "$(cat "$jump")" = 0 ] || fail "jump survived disarm"
if grep -q '^-F$' "$work/conntrack.log" 2>/dev/null || grep -q '^-F ' "$work/conntrack.log" 2>/dev/null; then
    fail "conntrack table was flushed"
fi

: >"$binlog"
"$scripts/honk-boot.sh"
if grep -q '^listen' "$binlog"; then
    fail "boot started the listener"
fi
[ ! -f "$work/state/honk.armed" ] || fail "boot left an arm token"

cat >"$work/menu.js" <<'EOF'
var menuTree = {
tab: [
{url: "Advanced_System_Content.asp", tabName: "<#menu5_6_2#>"},
{url: "Advanced_FirmwareUpgrade_Content.asp", tabName: "<#menu5_6_3#>"},
]
};
return menuTree;
EOF
honk_menu_insert "$work/menu.js" user3.asp || fail "menu insert"
honk_menu_insert "$work/menu.js" user3.asp || fail "menu insert twice"
[ "$(grep -c 'tabName: "Honk"' "$work/menu.js")" = 1 ] || fail "duplicate Honk tab"
grep -q 'return menuTree' "$work/menu.js" || fail "menu wrapper lost"
cp "$work/menu.js" "$work/menu-dup.js"
printf '%s\n' '{url: "Advanced_System_Content.asp", tabName: "<#menu5_6_2#>"},' >>"$work/menu-dup.js"
before=$(md5sum <"$work/menu-dup.js")
if honk_menu_insert "$work/menu-dup.js" user4.asp; then
    fail "duplicate anchor was accepted"
fi
after=$(md5sum <"$work/menu-dup.js")
[ "$before" = "$after" ] || fail "duplicate anchor modified the menu"

printf '%s\n' 'honk_runtime armed' 'other_addon 1' >"$HONK_SETTINGS"
honk_settings_strip
grep -q '^other_addon 1$' "$HONK_SETTINGS" || fail "uninstall removed a foreign setting"
if grep -q '^honk_' "$HONK_SETTINGS"; then
    fail "honk setting survived strip"
fi

# A live token re-applies from nat-start and ignores the stored enable flag.
sleep_pid=
sleep 30 &
sleep_pid=$!
printf '%s\n' "$sleep_pid" >"$work/state/honk.pid"
printf '%s\n' 'sw_mode=1' >"$work/state/honk.facts"
: >"$work/state/honk.armed"
: >"$work/state/honk.ready"
printf '%s\n' "$(($(date +%s) + 600))" >"$work/state/honk.deadline"
printf '%s\n' 0 >"$work/state/honk.pingfails"
printf '%s\n' 192.168.1.1 >"$work/state/honk.gateway"
: >"$binlog"
"$scripts/honk-nat.sh"
grep -q '^apply' "$binlog" || fail "armed nat-start did not re-apply"
kill "$sleep_pid" >/dev/null 2>&1 || true

# Confirmation suppresses only the timer. A dead listener still disarms.
sleep 30 &
dead=$!
kill "$dead" >/dev/null 2>&1 || true
wait "$dead" >/dev/null 2>&1 || true
: >"$work/state/honk.armed"
: >"$work/state/honk.confirmed"
printf '%s\n' "$dead" >"$work/state/honk.pid"
if honk_watch_step; then
    fail "watchdog kept a dead listener"
fi
[ ! -f "$work/state/honk.armed" ] || fail "dead listener left the arm token"

"$scripts/install.sh"
"$scripts/install.sh"
[ "$(grep -c '# honk-begin' "$work/jffs/scripts/service-event")" = 1 ] || fail "service-event hook duplicated"
grep -q 'start:honkconfirm' "$work/jffs/scripts/service-event" || fail "confirm event missing"
grep -q 'honk-firewall.sh' "$work/jffs/scripts/firewall-start" || fail "firewall hook missing"
grep -q 'honk-nat.sh' "$work/jffs/scripts/nat-start" || fail "nat hook missing"
grep -q 'honk-boot.sh' "$work/jffs/scripts/services-start" || fail "boot hook missing"
printf '%s\n' 'honk_runtime off' 'keep_me 1' >"$HONK_SETTINGS"
"$scripts/uninstall.sh"
[ ! -d "$work/prefix" ] || fail "prefix survived uninstall"
grep -q '^keep_me 1$' "$HONK_SETTINGS" || fail "uninstall removed a foreign setting"
if grep -q '# honk-begin' "$work/jffs/scripts/service-event"; then
    fail "service-event hook survived uninstall"
fi

echo "safety: ok"
