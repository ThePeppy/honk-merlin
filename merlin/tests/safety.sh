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
    conntrack-delete)
        if [ -f "$work/conntrack.hang" ]; then
            sleep 60
        fi
        exit 0
        ;;
    subscription-url)
        if [ -f "$work/sub.url" ]; then
            cat "$work/sub.url"
        fi
        exit 0
        ;;
    summary)
        if [ -f "$work/summary.fail" ]; then
            echo "subscription produced no shadowsocks nodes" >&2
            exit 1
        fi
        printf '%s\n' 'config loaded path=config.dae mode=600 uid=0 nodes=72 groups=21 rules=6'
        exit 0
        ;;
    import-surge) exit 0 ;;
    constants)
        printf '%s\n' 'chain=HONK_PRE'
        printf '%s\n' 'table=nat'
        printf '%s\n' 'port=39527'
        ;;
esac
exit 0
EOF

cat >"$work/bin/command" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$work/command.log"
exit 1
EOF
cat >"$work/bin/which" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$work/which.log"
exit 1
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

if grep -n 'command -v' "$scripts"/*.sh; then
    fail "router script uses command -v"
fi
if grep -n ' which ' "$scripts"/*.sh; then
    fail "router script uses which"
fi
page=$root/merlin/www/Tools_Honk.asp
grep -q 'id="honk_note"' "$page" || fail "page has no refusal note"
grep -q 'window.location.reload' "$page" || fail "page does not reload after apply"
grep -q 'Conntrack is not usable' "$page" || fail "page does not explain need_conntrack"

saved_ct=$HONK_CONNTRACK
saved_dirs=$HONK_BIN_DIRS
mkdir -p "$work/root/usr/sbin" "$work/root/usr/bin" "$work/root/opt/bin"
cat >"$work/root/usr/bin/conntrack" <<'EOF'
#!/bin/sh
exit 1
EOF
cat >"$work/root/usr/sbin/conntrack" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-C" ]
EOF
cat >"$work/root/opt/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' curl-ok
EOF
chmod 755 "$work/root/usr/bin/conntrack" "$work/root/usr/sbin/conntrack" "$work/root/opt/bin/curl"
HONK_CONNTRACK=conntrack
HONK_BIN_DIRS="$work/root/usr/sbin $work/root/usr/bin $work/root/opt/bin"
honk_have_conntrack || fail "bare conntrack name was not resolved"
[ "$HONK_CONNTRACK" = "$work/root/usr/sbin/conntrack" ] || fail "conntrack was not pinned to an absolute path"
rm -f "$work/root/usr/sbin/conntrack" "$work/root/usr/bin/conntrack"
HONK_CONNTRACK=conntrack
if honk_have_conntrack; then
    fail "absent conntrack was accepted"
fi
[ "$HONK_CONNTRACK" = "conntrack" ] || fail "a missing bare name was replaced"
[ "$(honk_resolve curl)" = "$work/root/opt/bin/curl" ] || fail "curl was not resolved from the probe list"
HONK_CONNTRACK=$saved_ct
HONK_BIN_DIRS=$saved_dirs

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
{url: "Advanced_System_Content.asp", tabName: "<#613#>"},
{url: "Advanced_FirmwareUpgrade_Content.asp", tabName: "<#614#>"},
]
};
retArray.push("Advanced_System_Content.asp");
return menuTree;
EOF
honk_menu_insert "$work/menu.js" user3.asp || fail "menu insert"
honk_menu_insert "$work/menu.js" user3.asp || fail "menu insert twice"
[ "$(grep -c 'tabName: "Honk"' "$work/menu.js")" = 1 ] || fail "duplicate Honk tab"
grep -q 'return menuTree' "$work/menu.js" || fail "menu wrapper lost"
grep -q 'retArray.push("Advanced_System_Content.asp")' "$work/menu.js" || fail "exclude list was treated as the anchor"
cat >"$work/menu-ws.js" <<'EOF'
var menuTree = {
tab: [
{ url : "Advanced_System_Content.asp" , tabName: "<#menu5_6_2#>" },
]
};
return menuTree;
EOF
honk_menu_insert "$work/menu-ws.js" user5.asp || fail "whitespace anchor was rejected"
[ "$(grep -c 'tabName: "Honk"' "$work/menu-ws.js")" = 1 ] || fail "whitespace anchor inserted the wrong number of tabs"
cp "$work/menu.js" "$work/menu-dup.js"
printf '%s\n' '{url: "Advanced_System_Content.asp", tabName: "<#613#>"},' >>"$work/menu-dup.js"
before=$(md5sum <"$work/menu-dup.js")
if honk_menu_insert "$work/menu-dup.js" user4.asp 2>"$work/menu-dup.err"; then
    fail "duplicate anchor was accepted"
fi
after=$(md5sum <"$work/menu-dup.js")
[ "$before" = "$after" ] || fail "duplicate anchor modified the menu"
grep -q menu_anchor_not_found "$work/menu-dup.err" || fail "duplicate anchor was silent"
printf '%s\nreturn menuTree;\n' 'var menuTree = { tab: [] };' >"$work/menu-missing.js"
before=$(md5sum <"$work/menu-missing.js")
if honk_menu_insert "$work/menu-missing.js" user6.asp 2>"$work/menu-missing.err"; then
    fail "missing anchor was accepted"
fi
after=$(md5sum <"$work/menu-missing.js")
[ "$before" = "$after" ] || fail "missing anchor modified the menu"
grep -q menu_anchor_not_found "$work/menu-missing.err" || fail "missing anchor was silent"

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

# Install must not report success when the System page URL is absent, and
# the numeric dictionary token on 3006.102 must still produce one Honk tab.
cat >"$work/helper.sh" <<'EOF'
#!/bin/sh
am_settings_set() { :; }
am_settings_get() { :; }
am_get_webui_page() { am_webui_page=user1.asp; }
EOF
printf '%s\n' 'var menuTree = { tab: [] };' 'return menuTree;' >"$work/menu-install-miss.js"
mkdir -p "$work/www"
if HONK_SKIP_WEBUI=0 HONK_SKIP_MOUNT=1 \
    HONK_HELPER="$work/helper.sh" \
    HONK_WWW="$work/www" \
    HONK_MENU_SRC="$work/menu-install-miss.js" \
    HONK_MENU_TMP="$work/menu-install-miss-tmp.js" \
    honk_install >"$work/install-miss.out" 2>"$work/install-miss.err"
then
    fail "install succeeded without a menu anchor"
fi
grep -q menu_anchor_not_found "$work/install-miss.err" || fail "install hid a missing anchor"
if grep -q 'honk: installed' "$work/install-miss.err"; then
    fail "install reported installed without the tab"
fi
cat >"$work/menu-install.js" <<'EOF'
var menuTree = {
tab: [
{url: "Advanced_System_Content.asp", tabName: "<#613#>"},
]
};
retArray.push("Advanced_System_Content.asp");
return menuTree;
EOF
HONK_SKIP_WEBUI=0 HONK_SKIP_MOUNT=1 \
    HONK_HELPER="$work/helper.sh" \
    HONK_WWW="$work/www" \
    HONK_MENU_SRC="$work/menu-install.js" \
    HONK_MENU_TMP="$work/menu-install-tmp.js" \
    honk_install >"$work/install-ok.out" 2>"$work/install-ok.err"
grep -q 'honk: installed' "$work/install-ok.err" || fail "numeric menu token did not install"
if grep -q menu_anchor_not_found "$work/install-ok.err"; then
    fail "numeric menu token was reported missing"
fi
[ "$(grep -c 'tabName: "Honk"' "$work/menu-install-tmp.js")" = 1 ] || fail "install did not leave one Honk tab"
grep -A1 'tabName: "<#613#>"' "$work/menu-install-tmp.js" | grep -q 'tabName: "Honk"' || fail "Honk tab was not inserted after the System page"
grep -q 'retArray.push("Advanced_System_Content.asp")' "$work/menu-install-tmp.js" || fail "install treated the exclude list as the anchor"

# A present config is passed to the listener. A failed subscription fetch
# must not fall through to direct copy.
mkdir -p "$HONK_PREFIX" "$work/root/usr/bin"
printf '%s\n' 'routing { fallback: direct }' >"$HONK_PREFIX/config.dae"
chmod 600 "$HONK_PREFIX/config.dae"
printf '%s\n' 'http://127.0.0.1:9/sub' >"$work/sub.url"
cat >"$work/root/usr/bin/curl" <<'EOF'
#!/bin/sh
echo "curl: (7) Failed to connect" >&2
exit 7
EOF
chmod 755 "$work/root/usr/bin/curl"
saved_dirs=$HONK_BIN_DIRS
export HONK_BIN_DIRS="$work/root/usr/bin"
: >"$binlog"
rm -f "$work/state/honk.log"
if "$scripts/honk-arm.sh"; then
    fail "arm succeeded after a subscription failure"
fi
grep -q subscription_fetch_failed "$work/state/honk.log" || fail "fetch failure was not logged"
if grep -q '^listen' "$binlog"; then
    fail "listen started after a subscription failure"
fi
if grep -q '^apply' "$binlog"; then
    fail "apply ran after a subscription failure"
fi
rm -f "$work/sub.url"
export HONK_BIN_DIRS="$saved_dirs"
: >"$binlog"
rm -f "$work/state/honk.log"
"$scripts/honk-arm.sh" || fail "arm with a config file failed"
grep -q -- '--config' "$binlog" || fail "listen did not receive --config"
grep -q 'config loaded' "$work/state/honk.log" || fail "config summary missing"
grep -q 'nodes=72' "$work/state/honk.log" || fail "node count missing"
"$scripts/honk-disarm.sh"

# Disarm kills the listener and watcher even when conntrack delete hangs.
sleep 60 &
listener=$!
sleep 60 &
watcher=$!
printf '%s\n' "$listener" >"$work/state/honk.pid"
printf '%s\n' "$watcher" >"$work/state/honk.watch.pid"
printf '%s\n' 'primary_ip=192.168.50.1' >"$work/state/honk.facts"
touch "$work/conntrack.hang"
started=$(date +%s)
honk_disarm manual
elapsed=$(( $(date +%s) - started ))
rm -f "$work/conntrack.hang"
[ "$elapsed" -lt 15 ] || fail "disarm hung for ${elapsed}s"
if kill -0 "$listener" >/dev/null 2>&1; then
    fail "listener survived disarm"
fi
if kill -0 "$watcher" >/dev/null 2>&1; then
    fail "watcher survived disarm"
fi

# A command line that merely contains honk must survive disarm.
sh -c 'sleep 40' honk-dataplane >/dev/null 2>&1 &
decoy=$!
sh -c 'sleep 40' 'sh /jffs/addons/honk/scripts/install.sh' >/dev/null 2>&1 &
sshish=$!
cp /bin/sleep "$work/exact-bin"
"$work/exact-bin" 40 >/dev/null 2>&1 &
exact=$!
HONK_BIN="$work/exact-bin" honk_stop_binary
if kill -0 "$decoy" >/dev/null 2>&1; then
    :
else
    fail "a command line containing honk-dataplane was killed"
fi
if kill -0 "$sshish" >/dev/null 2>&1; then
    :
else
    fail "an install command line was killed"
fi
if kill -0 "$exact" >/dev/null 2>&1; then
    fail "the dataplane binary was not killed"
fi
kill "$decoy" "$sshish" >/dev/null 2>&1 || true
wait "$decoy" "$sshish" >/dev/null 2>&1 || true

if [ -s "$work/command.log" ]; then
    fail "a router script invoked command"
fi
if [ -s "$work/which.log" ]; then
    fail "a router script invoked which"
fi

echo "safety: ok"
