#!/bin/sh
# Exercise the addon scripts with fake nvram, iptables, and conntrack.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
scripts=$root/merlin/scripts
work=$(mktemp -d)
# bash 3.2 runs an EXIT trap when wait reaps a signaled child, then continues.
trap 'rm -rf "$work"' ERR

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
if [ "\${1:-}" = -D ] && [ -f "$work/conntrack.hang" ]; then
    sleep 60
fi
exit 0
EOF

cat >"$work/bin/fc" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$work/fc.log"
if [ "\${1:-}" = status ]; then
    if [ -f "$work/fc.off" ]; then
        printf '%s\n' 'L2 & L3 Acceleration is Disabled'
    else
        printf '%s\n' 'L2 & L3 Acceleration is Enabled'
    fi
fi
exit 0
EOF
cat >"$work/bin/runner" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$work/runner.log"
if [ "\${1:-}" = status ]; then
    if [ -f "$work/runner.off" ]; then
        printf '%s\n' 'Runner is Disabled'
    else
        printf '%s\n' 'Runner is Enabled'
    fi
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

cat >"$work/bin/honk-core" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$binlog"
for arg in "\$@"; do
    if [ "\$arg" = --redirect ]; then
        while :; do sleep 30; done
    fi
done
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
export HONK_BIN="$work/bin/honk-core"
export HONK_ASSUME_LISTENING=1
export HONK_FC="$work/bin/fc"
export HONK_RUNNER="$work/bin/runner"
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
    rm -rf "$work"
    exit 1
}

# firewall-start may REJECT LAN QUIC. It must not install the nat redirect.
fw_code=$(grep -v '^#' "$scripts/honk-firewall.sh" || true)
printf '%s\n' "$fw_code" | grep -q -- '-p udp' || fail "firewall hook does not match udp"
printf '%s\n' "$fw_code" | grep -q -- '--dport 443' || fail "firewall hook does not reject udp/443"
printf '%s\n' "$fw_code" | grep -q REJECT || fail "firewall hook does not reject"
if printf '%s\n' "$fw_code" | grep -E -q 'NAT|REDIRECT|HONK_PRE'; then
    fail "firewall-start script changes nat"
fi

grep -q 'HONK_CHAIN=HONK_PRE' "$scripts/honk-common.sh" || fail "script chain drifted"
grep -q 'HONK_DEFAULT_TPROXY_PORT=12345' "$scripts/honk-common.sh" || fail "script port drifted"
grep -q '192.168.0.0/16' "$scripts/honk-common.sh" || fail "private range missing"
if grep -n -- '-A Surge' "$scripts"/*.sh; then
    fail "router script sends User-Agent Surge"
fi
if grep -n honk_stop_binary "$scripts"/*.sh; then
    fail "router script still scans processes"
fi

# shellcheck disable=SC1091
. "$scripts/honk-common.sh"

if grep -n 'command -v' "$scripts"/*.sh; then
    fail "router script uses command -v"
fi
if grep -n ' which ' "$scripts"/*.sh; then
    fail "router script uses which"
fi
page=$root/merlin/www/Honk.asp
grep -q 'id="honk_note"' "$page" || fail "page has no refusal note"
grep -q 'window.location.reload' "$page" || fail "page does not reload after apply"
grep -q 'conntrack 不可用' "$page" || fail "page does not explain need_conntrack"
grep -q 'Honk 代理' "$page" || fail "page title is not Chinese"
grep -q 'http://192.168.2.1:9090/ui/' "$page" || fail "page has no panel link"
grep -q '12345' "$page" || fail "page does not name the default port"
grep -q 'value="启动"' "$page" || fail "page has no start button"
grep -q 'value="重启"' "$page" || fail "page has no restart button"
grep -q 'value="关闭"' "$page" || fail "page has no stop button"
if grep -E -q 'value="(启用|确认|停用|刷新)"' "$page"; then
    fail "page still has the confirm-timer buttons"
fi
if grep -q 'Phase 1' "$page"; then
    fail "page still has the phase 1 note"
fi
if grep -q 'color:#FC0' "$page"; then
    fail "page has a custom color"
fi

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
: >"$binlog"
mkdir -p "$HONK_PREFIX"
printf '%s\n' 'routing { fallback: direct }' >"$HONK_PREFIX/config.dae"
touch "$work/conntrack.fail"
if "$scripts/honk-arm.sh"; then
    fail "arm succeeded without conntrack"
fi
rm -f "$work/conntrack.fail"
if grep -q -- '--redirect' "$binlog"; then
    fail "arm without conntrack started honk-core"
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

# YEAR20 sidebar: two menu_Split headers. The first opens General
# Settings, the second Advanced Settings. Display names vary by
# dictionary; Honk is inserted immediately before the second of
# exactly two splits, last in General, never under Advanced.
menu_index_order() {
    awk '{
        s = $0
        gsub(/[[:space:]]/, "", s)
        p = index(s, "index:\"")
        if (p == 0) next
        s = substr(s, p + 7)
        p = index(s, "\"")
        if (p == 0) next
        print substr(s, 1, p - 1)
    }' "$1"
}

cat >"$work/menu.js" <<'EOF'
define(function(){
var menuTree = {
list: [
{
menuName: "<#menu5_1_1#>",
index: "menu_Split",
tab: [
{url: "NULL", tabName: "__HIDE__"}
]
},
{
menuName: "AiMesh",
index: "menu_AiMesh",
tab: [
{url: "AiMesh.asp", tabName: "AiMesh"},
{url: "NULL", tabName: "__INHERIT__"}
]
},
{
menuName: "<#menu5#>",
index: "menu_Split",
tab: [
{url: "NULL", tabName: "__HIDE__"}
]
},
{
menuName: "<#613#>",
index: "menu_Setting",
tab: [
{url: "Advanced_OperationMode_Content.asp", tabName: "<#612#>"},
{url: "Advanced_System_Content.asp", tabName: "<#613#>"},
{url: "Advanced_FirmwareUpgrade_Content.asp", tabName: "<#614#>"},
{url: "NULL", tabName: "__INHERIT__"}
]
}
]
};
retArray.push("Advanced_System_Content.asp");
return menuTree;
});
EOF
honk_menu_insert "$work/menu.js" user3.asp || fail "menu insert"
honk_menu_insert "$work/menu.js" user3.asp || fail "menu insert twice"
[ "$(grep -c 'tabName: "Honk"' "$work/menu.js")" = 1 ] || fail "duplicate Honk tab"
[ "$(grep -c 'index: "menu_Honk"' "$work/menu.js")" = 1 ] || fail "Honk section count drifted"
grep -q 'return menuTree' "$work/menu.js" || fail "menu wrapper lost"
grep -q 'retArray.push("Advanced_System_Content.asp")' "$work/menu.js" || fail "exclude list was treated as the anchor"
[ "$(menu_index_order "$work/menu.js" | tr '\n' ' ')" = "menu_Split menu_AiMesh menu_Honk menu_Split menu_Setting " ] || fail "Honk was not placed last in General Settings"
grep -q '{url: "user3.asp", tabName: "Honk"}' "$work/menu.js" || fail "Honk tab lost the page slot"
honk_menu_remove "$work/menu.js" || fail "menu remove failed"
[ "$(grep -c 'index: "menu_Honk"' "$work/menu.js")" = 0 ] || fail "Honk section survived removal"
[ "$(grep -c 'index: "menu_Setting"' "$work/menu.js")" = 1 ] || fail "System section was damaged by removal"
[ "$(grep -c 'index: "menu_Split"' "$work/menu.js")" = 2 ] || fail "split headers were damaged by removal"
grep -q 'return menuTree' "$work/menu.js" || fail "menu wrapper lost on removal"
cat >"$work/menu-ws.js" <<'EOF'
var menuTree = {
list: [
{
   menuName   :   "<#menu5_1_1#>" ,
   index   :   "menu_Split" ,
   tab: [ { url : "NULL" , tabName: "__HIDE__" } ]
},
{
   menuName   :   "<#menu5#>" ,
   index   :   "menu_Split" ,
   tab: [ { url : "NULL" , tabName: "__HIDE__" } ]
},
{
   menuName   :   "<#613#>" ,
   index   :   "menu_Setting" ,
   tab: [ { url : "Advanced_System_Content.asp" , tabName: "<#menu5_6_2#>" } ]
}
]
};
return menuTree;
EOF
honk_menu_insert "$work/menu-ws.js" user5.asp || fail "whitespace anchor was rejected"
honk_menu_insert "$work/menu-ws.js" user5.asp || fail "whitespace re-insert was rejected"
[ "$(grep -c 'tabName: "Honk"' "$work/menu-ws.js")" = 1 ] || fail "whitespace anchor inserted the wrong number of tabs"
[ "$(menu_index_order "$work/menu-ws.js" | tr '\n' ' ')" = "menu_Split menu_Honk menu_Split menu_Setting " ] || fail "whitespace insert missed General Settings"
# An install from the older layout must clean its one-line tab while keeping
# the stock System section intact.
cat >"$work/menu-legacy.js" <<'EOF'
var menuTree = {
list: [
{
menuName: "<#menu5_1_1#>",
index: "menu_Split",
tab: [
{url: "NULL", tabName: "__HIDE__"}
]
},
{
menuName: "<#menu5#>",
index: "menu_Split",
tab: [
{url: "NULL", tabName: "__HIDE__"}
]
},
{
menuName: "<#613#>",
index: "menu_Setting",
tab: [
{url: "Advanced_System_Content.asp", tabName: "<#613#>"},
{url: "user1.asp", tabName: "Honk"},
{url: "NULL", tabName: "__INHERIT__"}
]
}
]
};
return menuTree;
EOF
honk_menu_insert "$work/menu-legacy.js" user3.asp || fail "legacy layout insert failed"
[ "$(grep -c 'tabName: "Honk"' "$work/menu-legacy.js")" = 1 ] || fail "legacy tab survived alongside the new section"
[ "$(grep -c 'url: "user1.asp"' "$work/menu-legacy.js")" = 0 ] || fail "legacy tab line survived"
[ "$(grep -c 'index: "menu_Setting"' "$work/menu-legacy.js")" = 1 ] || fail "legacy insert damaged the System section"
[ "$(menu_index_order "$work/menu-legacy.js" | tr '\n' ' ')" = "menu_Split menu_Honk menu_Split menu_Setting " ] || fail "legacy insert left Honk under Advanced"
honk_menu_remove "$work/menu-legacy.js" || fail "legacy layout remove failed"
[ "$(grep -c 'tabName: "Honk"' "$work/menu-legacy.js")" = 0 ] || fail "legacy remove left the new section"
mkdir -p "$work/www"
cat >"$work/menu-dup.js" <<'EOF'
var menuTree = {
list: [
{
menuName: "a",
index: "menu_Split",
tab: [
{url: "NULL", tabName: "__HIDE__"}
]
},
{
menuName: "b",
index: "menu_Split",
tab: [
{url: "NULL", tabName: "__HIDE__"}
]
},
{
menuName: "c",
index: "menu_Split",
tab: [
{url: "NULL", tabName: "__HIDE__"}
]
}
]
};
return menuTree;
EOF
before=$(md5sum <"$work/menu-dup.js")
if honk_menu_insert "$work/menu-dup.js" user4.asp 2>"$work/menu-dup.err"; then
    fail "duplicate anchor was accepted"
fi
after=$(md5sum <"$work/menu-dup.js")
[ "$before" = "$after" ] || fail "duplicate anchor modified the menu"
grep -q menu_anchor_not_found "$work/menu-dup.err" || fail "duplicate anchor was silent"
printf '%s\nreturn menuTree;\n' 'var menuTree = { list: [] };' >"$work/menu-missing.js"
before=$(md5sum <"$work/menu-missing.js")
if honk_menu_insert "$work/menu-missing.js" user6.asp 2>"$work/menu-missing.err"; then
    fail "missing anchor was accepted"
fi
after=$(md5sum <"$work/menu-missing.js")
[ "$before" = "$after" ] || fail "missing anchor modified the menu"
grep -q menu_anchor_not_found "$work/menu-missing.err" || fail "missing anchor was silent"
# Administration alone is the Advanced Settings group; that must not become
# the insert point on a file that lacks the YEAR20 split headers.
cat >"$work/menu-admin-only.js" <<'EOF'
var menuTree = {
list: [
{
menuName: "<#613#>",
index: "menu_Setting",
tab: [
{url: "Advanced_System_Content.asp", tabName: "<#613#>"}
]
}
]
};
return menuTree;
EOF
before=$(md5sum <"$work/menu-admin-only.js")
if honk_menu_insert "$work/menu-admin-only.js" user7.asp 2>"$work/menu-admin-only.err"; then
    fail "Administration-only menu was accepted as the General Settings anchor"
fi
after=$(md5sum <"$work/menu-admin-only.js")
[ "$before" = "$after" ] || fail "Administration-only menu was modified"
grep -q menu_anchor_not_found "$work/menu-admin-only.err" || fail "Administration-only menu was silent"

# The sidebar icon is a best-effort append to the site-wide style sheet.
printf '%s\n' 'body { background: #000; }' >"$work/www/index_style.css"
HONK_STYLE_SRC="$work/www/index_style.css" \
HONK_STYLE_TMP="$work/style-tmp.css" \
honk_mount_style || fail "style mount failed with a present source"
grep -q 'honk-icon-begin' "$work/style-tmp.css" || fail "icon rule not appended"
grep -q 'menu_Honk' "$work/style-tmp.css" || fail "icon rule lost the index class"
grep -q 'body { background: #000; }' "$work/style-tmp.css" || fail "icon mount lost the stock rules"
HONK_STYLE_SRC="$work/www/index_style.css" \
HONK_STYLE_TMP="$work/style-tmp.css" \
honk_mount_style || fail "style mount is not idempotent"
[ "$(grep -c 'honk-icon-begin' "$work/style-tmp.css")" = 1 ] || fail "icon rule duplicated"
rm -f "$work/style-tmp.css"
if HONK_STYLE_SRC="$work/www/missing.css" \
   HONK_STYLE_TMP="$work/style-tmp.css" \
   honk_mount_style 2>"$work/style-missing.err"; then
    :
else
    fail "missing style source failed the mount"
fi
grep -q icon_style_missing "$work/style-missing.err" || fail "missing style source was silent"

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
: >"$iptlog"
printf '%s\n' 'sw_mode=1' 'ifname=br0' 'lan_ip=192.168.50.1' 'lan_mask=255.255.255.0' 'primary_ip=192.168.50.1' 'local_ip=192.168.50.1' >"$work/state/honk.facts"
printf '%s\n' 12345 >"$work/state/honk.port"
"$scripts/honk-nat.sh"
grep -q -- '-j REDIRECT' "$iptlog" || fail "armed nat-start did not re-apply"
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
printf '%s\n' 'var menuTree = { list: [] };' 'return menuTree;' >"$work/menu-install-miss.js"
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
list: [
{
menuName: "<#menu5_1_1#>",
index: "menu_Split",
tab: [
{url: "NULL", tabName: "__HIDE__"}
]
},
{
menuName: "<#menu5#>",
index: "menu_Split",
tab: [
{url: "NULL", tabName: "__HIDE__"}
]
},
{
menuName: "<#613#>",
index: "menu_Setting",
tab: [
{url: "Advanced_System_Content.asp", tabName: "<#613#>"},
{url: "NULL", tabName: "__INHERIT__"}
]
}
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
    HONK_STYLE_SRC="$work/www/index_style.css" \
    HONK_STYLE_TMP="$work/install-style-tmp.css" \
    honk_install >"$work/install-ok.out" 2>"$work/install-ok.err"
grep -q 'honk: installed' "$work/install-ok.err" || fail "numeric menu token did not install"
if grep -q menu_anchor_not_found "$work/install-ok.err"; then
    fail "numeric menu token was reported missing"
fi
[ "$(grep -c 'tabName: "Honk"' "$work/menu-install-tmp.js")" = 1 ] || fail "install did not leave one Honk tab"
grep -q '{url: "user1.asp", tabName: "Honk"}' "$work/menu-install-tmp.js" || fail "Honk section lost the allocated slot"
[ "$(menu_index_order "$work/menu-install-tmp.js" | tr '\n' ' ')" = "menu_Split menu_Honk menu_Split menu_Setting " ] || fail "install placed Honk outside General Settings"
grep -q 'retArray.push("Advanced_System_Content.asp")' "$work/menu-install-tmp.js" || fail "install treated the exclude list as the anchor"
grep -q 'menu_Honk' "$work/install-style-tmp.css" || fail "install did not mount the icon rule"

# A present config is passed to honk-core. The shell does not fetch the
# subscription and does not send a Surge user agent.
mkdir -p "$HONK_PREFIX" "$work/root/usr/bin"
printf '%s\n' 'routing { fallback: direct }' >"$HONK_PREFIX/config.dae"
chmod 600 "$HONK_PREFIX/config.dae"
: >"$work/curl.log"
cat >"$work/root/usr/bin/curl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$work/curl.log"
exit 7
EOF
chmod 755 "$work/root/usr/bin/curl"
saved_dirs=$HONK_BIN_DIRS
export HONK_BIN_DIRS="$work/root/usr/bin"
: >"$binlog"
: >"$iptlog"
: >"$work/fc.log"
: >"$work/runner.log"
rm -f "$work/state/honk.log"
"$scripts/honk-arm.sh" || fail "arm with a config file failed"
grep -q -- '--redirect' "$binlog" || fail "honk-core was not started with --redirect"
grep -q -- '-c' "$binlog" || fail "honk-core was not given the config"
grep -q '192.168.50.1:' "$binlog" || fail "redirect address was not the LAN primary"
grep -q -- '-j REDIRECT' "$iptlog" || fail "REDIRECT was not installed"
grep -q -- '--to-ports 12345' "$iptlog" || fail "REDIRECT port was not 12345"
grep -q '192.168.50.0/24' "$iptlog" || fail "LAN prefix was not excluded"
grep -q -- '--dport 9090' "$iptlog" || fail "dashboard port was not excluded"
grep -q -- '--dport 53' "$iptlog" || fail "DNS TCP was not excluded"
grep -q '10.0.0.0/8' "$iptlog" || fail "10/8 was not excluded"
grep -q '172.16.0.0/12' "$iptlog" || fail "172.16/12 was not excluded"
grep -q '192.168.0.0/16' "$iptlog" || fail "192.168/16 was not excluded"
grep -q '100.64.0.0/10' "$iptlog" || fail "CGNAT was not excluded"
if grep -q ' OUTPUT ' "$iptlog"; then
    fail "an OUTPUT rule was installed"
fi
if grep -q ' -I ' "$iptlog"; then
    fail "a rule was inserted at the head"
fi
grep -q '^disable$' "$work/fc.log" || fail "flow cache was not disabled"
grep -q '^flush$' "$work/fc.log" || fail "flow cache was not flushed"
grep -q '^disable$' "$work/runner.log" || fail "runner was not disabled"
if [ -s "$work/curl.log" ]; then
    fail "the shell fetched a subscription"
fi
"$scripts/honk-disarm.sh"
grep -q '^enable$' "$work/fc.log" || fail "flow cache was not restored"
grep -q '^enable$' "$work/runner.log" || fail "runner was not restored"
export HONK_BIN_DIRS="$saved_dirs"

# Refresh signals the pid file. `honk-core reload` cannot see this process.
# A shell waiting on sleep does not run its HUP trap until that sleep exits.
: >"$work/hup.log"
python3 -c 'import signal, sys, time
path = sys.argv[1]
def on_hup(*_):
    with open(path, "a") as handle:
        handle.write("hup\n")
signal.signal(signal.SIGHUP, on_hup)
with open(path, "a") as handle:
    handle.write("ready\n")
while True:
    time.sleep(30)
' "$work/hup.log" >/dev/null 2>&1 &
huppid=$!
i=0
while [ "$i" -lt 50 ]; do
    grep -q ready "$work/hup.log" && break
    i=$((i + 1))
    sleep 0.1
done
grep -q ready "$work/hup.log" || fail "refresh target did not start"
printf '%s\n' "$huppid" >"$work/state/honk.pid"
: >"$work/state/honk.armed"
: >"$binlog"
honk_refresh || fail "refresh failed"
i=0
while [ "$i" -lt 20 ]; do
    grep -q hup "$work/hup.log" && break
    i=$((i + 1))
    sleep 0.1
done
grep -q hup "$work/hup.log" || fail "refresh did not signal the listener"
if grep -q reload "$binlog"; then
    fail "refresh invoked honk-core reload"
fi
kill "$huppid" >/dev/null 2>&1 || true
wait "$huppid" >/dev/null 2>&1 || true
rm -f "$work/state/honk.armed" "$work/state/honk.pid"

# A flow cache that was already off stays off after disarm.
: >"$work/fc.log"
: >"$work/runner.log"
touch "$work/fc.off" "$work/runner.off"
honk_fc_suspend
honk_fc_restore
if grep -q '^enable$' "$work/fc.log"; then
    fail "a disabled flow cache was enabled"
fi
if grep -q '^enable$' "$work/runner.log"; then
    fail "a disabled runner was enabled"
fi
rm -f "$work/fc.off" "$work/runner.off"

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

# Pid files are the only processes disarm may kill.
sh -c 'sleep 40' honk-dataplane >/dev/null 2>&1 &
decoy=$!
sh -c 'sleep 40' 'sh /jffs/addons/honk/scripts/install.sh' >/dev/null 2>&1 &
sshish=$!
# macOS kills unsigned copies of system binaries (SIGKILL). Keep an
# unrelated sleep in-place so this check is the same on Darwin and Linux.
sh -c 'sleep 40' exact-unrelated >/dev/null 2>&1 &
exact=$!
honk_disarm manual
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
    :
else
    fail "a process outside the pid files was killed"
fi
kill "$decoy" "$sshish" "$exact" >/dev/null 2>&1 || true
wait "$decoy" "$sshish" "$exact" >/dev/null 2>&1 || true

if [ -s "$work/command.log" ]; then
    fail "a router script invoked command"
fi
if [ -s "$work/which.log" ]; then
    fail "a router script invoked which"
fi

echo "safety: ok"
rm -rf "$work"
