# Shared helpers for the Merlin addon. Sourced, not executed.
# Busybox ash: no arrays and no bash tests. `local` is available there.

# shellcheck shell=sh disable=SC3043

HONK_PREFIX=${HONK_PREFIX:-/jffs/addons/honk}
HONK_STATE_DIR=${HONK_STATE_DIR:-/tmp}
HONK_BIN=${HONK_BIN:-$HONK_PREFIX/honk-core}
HONK_IPTABLES=${HONK_IPTABLES:-iptables}
HONK_FC=${HONK_FC:-/bin/fc}
HONK_RUNNER=${HONK_RUNNER:-/bin/runner}
HONK_CONNTRACK=${HONK_CONNTRACK:-conntrack}
HONK_PING=${HONK_PING:-ping}
HONK_IP=${HONK_IP:-ip}
HONK_NVRAM=${HONK_NVRAM:-nvram}
HONK_HELPER=${HONK_HELPER:-/usr/sbin/helper.sh}
HONK_SETTINGS=${HONK_SETTINGS:-/jffs/addons/custom_settings.txt}
HONK_SCRIPTS_DIR=${HONK_SCRIPTS_DIR:-/jffs/scripts}
HONK_WWW=${HONK_WWW:-/www}
HONK_MENU_SRC=${HONK_MENU_SRC:-/www/require/modules/menuTree.js}
HONK_MENU_TMP=${HONK_MENU_TMP:-/tmp/menuTree.js}
HONK_DEFAULT_TPROXY_PORT=12345
HONK_CHAIN=HONK_PRE
# Private destinations stay on the router. Sending them through REDIRECT made
# dip(192.168.0.0/16)->direct dial from honk, and the peer refused.
HONK_PRIVATE_CIDRS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10"
HONK_PING_LIMIT=${HONK_PING_LIMIT:-3}
HONK_WATCH_INTERVAL=${HONK_WATCH_INTERVAL:-5}
HONK_ARM_GRACE=${HONK_ARM_GRACE:-30}
HONK_SKIP_MOUNT=${HONK_SKIP_MOUNT:-0}
HONK_SKIP_WEBUI=${HONK_SKIP_WEBUI:-0}
HONK_SCRIPT_DIR=${HONK_SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}
# service-event's ash has no `command` builtin, and `[ -x name ]` does not
# search PATH. Probe these directories instead.
HONK_BIN_DIRS=${HONK_BIN_DIRS:-"/usr/sbin /usr/bin /sbin /opt/sbin /opt/bin"}

honk_resolve() {
    local name="$1"
    local dir
    case $name in
        /*)
            if [ -x "$name" ]; then
                printf '%s\n' "$name"
                return 0
            fi
            return 1
            ;;
        ''|*[!A-Za-z0-9._-]*)
            return 1
            ;;
    esac
    # shellcheck disable=SC2086
    for dir in $HONK_BIN_DIRS; do
        if [ -x "$dir/$name" ]; then
            printf '%s\n' "$dir/$name"
            return 0
        fi
    done
    return 1
}

honk_pin_bins() {
    local bin
    bin=$(honk_resolve "$HONK_CONNTRACK" || true)
    if [ -n "$bin" ]; then
        HONK_CONNTRACK=$bin
        export HONK_CONNTRACK
    fi
    bin=$(honk_resolve "$HONK_IPTABLES" || true)
    if [ -n "$bin" ]; then
        HONK_IPTABLES=$bin
    fi
    bin=$(honk_resolve "$HONK_IP" || true)
    if [ -n "$bin" ]; then
        HONK_IP=$bin
    fi
    bin=$(honk_resolve "$HONK_NVRAM" || true)
    if [ -n "$bin" ]; then
        HONK_NVRAM=$bin
    fi
    bin=$(honk_resolve "$HONK_PING" || true)
    if [ -n "$bin" ]; then
        HONK_PING=$bin
    fi
}

honk_log() {
    local logger
    logger=$(honk_resolve logger || true)
    if [ -n "$logger" ]; then
        "$logger" -t honk "$*" || true
    fi
    echo "honk: $*" >&2
}

honk_state() {
    printf '%s/%s\n' "$HONK_STATE_DIR" "$1"
}

honk_set_status() {
    local runtime="$1"
    local detail="$2"
    case $runtime in
        off|armed|confirmed|refused) ;;
        *) return 0 ;;
    esac
    case $detail in
        *[!A-Za-z0-9_.:-]*) return 0 ;;
        '') return 0 ;;
    esac
    if [ ! -f "$HONK_HELPER" ]; then
        return 0
    fi
    # shellcheck disable=SC1090
    . "$HONK_HELPER"
    am_settings_set honk_runtime "$runtime"
    am_settings_set honk_detail "$detail"
}

honk_unlink() {
    local i="0"
    while [ "$i" -lt 20 ] && "$HONK_IPTABLES" -t nat -D PREROUTING -j "$HONK_CHAIN" >/dev/null 2>&1; do
        i=$((i + 1))
    done
    "$HONK_IPTABLES" -t nat -F "$HONK_CHAIN" >/dev/null 2>&1 || true
    "$HONK_IPTABLES" -t nat -X "$HONK_CHAIN" >/dev/null 2>&1 || true
}

honk_conntrack_delete() {
    local facts primary port child i
    facts=$(honk_state honk.facts)
    if [ ! -f "$facts" ]; then
        honk_log conntrack_skipped
        return 0
    fi
    primary=$(sed -n 's/^primary_ip=//p' "$facts" | head -n 1)
    case $primary in
        ''|*[!0-9.]*) return 0 ;;
    esac
    port=$(cat "$(honk_state honk.port)" 2>/dev/null || echo "$HONK_DEFAULT_TPROXY_PORT")
    case $port in
        ''|*[!0-9]*) port=$HONK_DEFAULT_TPROXY_PORT ;;
    esac
    honk_pin_bins
    if [ ! -x "$HONK_CONNTRACK" ]; then
        honk_log conntrack_skipped
        return 0
    fi
    "$HONK_CONNTRACK" -D -p tcp --reply-src "$primary" --reply-port-src "$port" >/dev/null 2>&1 &
    child=$!
    i=0
    while [ "$i" -lt 8 ]; do
        if ! kill -0 "$child" >/dev/null 2>&1; then
            wait "$child" || honk_log conntrack_delete_failed
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    kill "$child" >/dev/null 2>&1 || true
    sleep 1
    kill -9 "$child" >/dev/null 2>&1 || true
    wait "$child" >/dev/null 2>&1 || true
    honk_log conntrack_delete_timeout
    return 0
}

honk_kill_pid() {
    local pid="$1"
    local i="0"
    [ -n "$pid" ] || return 0
    kill "$pid" >/dev/null 2>&1 || true
    while [ "$i" -lt 2 ]; do
        kill -0 "$pid" >/dev/null 2>&1 || return 0
        i=$((i + 1))
        sleep 1
    done
    kill -9 "$pid" >/dev/null 2>&1 || true
}

honk_stop_pidfile() {
    local file="$1"
    local pid
    [ -f "$file" ] || return 0
    pid=$(cat "$file" 2>/dev/null || true)
    rm -f "$file"
    honk_kill_pid "$pid"
}

# Pid files only. Scanning command lines for "honk" killed the SSH session
# that was running install.
honk_stop_listener() {
    honk_stop_pidfile "$(honk_state honk.pid)"
    honk_stop_pidfile "$(honk_state honk.watch.pid)"
    rm -f "$(honk_state honk.ready)"
}

honk_disarm() {
    local reason="${1:-disarmed}"
    honk_pin_bins
    honk_unlink
    honk_fc_restore
    honk_stop_listener
    honk_conntrack_delete
    rm -f \
        "$(honk_state honk.armed)" \
        "$(honk_state honk.confirmed)" \
        "$(honk_state honk.deadline)" \
        "$(honk_state honk.gateway)" \
        "$(honk_state honk.facts)" \
        "$(honk_state honk.port)" \
        "$(honk_state honk.pingfails)"
    honk_set_status off "$reason"
    honk_log "disarmed $reason"
}

honk_minutes() {
    local raw="5"
    if [ -f "$HONK_HELPER" ]; then
        # shellcheck disable=SC1090
        . "$HONK_HELPER"
        raw=$(am_settings_get honk_confirm_minutes || true)
    fi
    case $raw in
        ''|*[!0-9]*) raw=5 ;;
    esac
    if [ "$raw" -lt 1 ] || [ "$raw" -gt 30 ]; then
        raw=5
    fi
    echo "$raw"
}

honk_have_conntrack() {
    honk_pin_bins
    [ -x "$HONK_CONNTRACK" ] || return 1
    "$HONK_CONNTRACK" -C >/dev/null 2>&1
}

honk_gather_facts() {
    local model odm sw gw ifname lan_ip lan_mask primary facts locals
    honk_pin_bins
    model=$("$HONK_NVRAM" get productid 2>/dev/null || true)
    odm=$("$HONK_NVRAM" get odmpid 2>/dev/null || true)
    if [ "$model" != "RT-BE88U" ] && [ "$odm" != "RT-BE88U" ]; then
        honk_set_status refused need_model
        return 1
    fi
    sw=$("$HONK_NVRAM" get sw_mode 2>/dev/null || true)
    if [ "$sw" != "1" ]; then
        honk_set_status refused need_sw_mode
        return 1
    fi
    if ! honk_have_conntrack; then
        honk_set_status refused need_conntrack
        return 1
    fi
    gw=$("$HONK_NVRAM" get wan0_gateway 2>/dev/null || true)
    if [ -z "$gw" ]; then
        gw=$("$HONK_NVRAM" get wan_gateway 2>/dev/null || true)
    fi
    case $gw in
        ''|*[!0-9.]*)
            honk_set_status refused need_gateway
            return 1
            ;;
    esac
    ifname=$("$HONK_NVRAM" get lan_ifname 2>/dev/null || true)
    lan_ip=$("$HONK_NVRAM" get lan_ipaddr 2>/dev/null || true)
    lan_mask=$("$HONK_NVRAM" get lan_netmask 2>/dev/null || true)
    primary=$("$HONK_IP" -4 -o addr show dev "$ifname" 2>/dev/null | awk 'NR==1 { split($4, a, "/"); print a[1] }')
    if [ -z "$primary" ] || [ "$primary" != "$lan_ip" ]; then
        honk_set_status refused need_primary
        return 1
    fi
    facts=$(honk_state honk.facts)
    {
        printf 'sw_mode=%s\n' "$sw"
        printf 'ifname=%s\n' "$ifname"
        printf 'lan_ip=%s\n' "$lan_ip"
        printf 'lan_mask=%s\n' "$lan_mask"
        printf 'primary_ip=%s\n' "$primary"
    } >"$facts"
    "$HONK_IP" -4 -o addr show 2>/dev/null | awk '{ split($4, a, "/"); if (a[1] ~ /^[0-9.]+$/) print a[1] }' | while IFS= read -r locals; do
        [ -n "$locals" ] || continue
        printf 'local_ip=%s\n' "$locals" >>"$facts"
    done
    if ! honk_validate_facts "$facts"; then
        rm -f "$facts"
        honk_set_status refused need_facts
        return 1
    fi
    printf '%s\n' "$gw" >"$(honk_state honk.gateway)"
}

honk_wait_listen() {
    local i="0"
    while [ "$i" -lt 15 ]; do
        if honk_listening; then
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    return 1
}

honk_listening() {
    local port hex
    if [ "${HONK_ASSUME_LISTENING:-0}" = "1" ]; then
        return 0
    fi
    port=$(cat "$(honk_state honk.port)" 2>/dev/null || echo "$HONK_DEFAULT_TPROXY_PORT")
    hex=$(printf '%04X' "$port")
    [ -r /proc/net/tcp ] || return 1
    awk -v hex="$hex" '
        NR > 1 && $4 == "0A" {
            split($2, a, ":")
            if (toupper(a[2]) == hex) found = 1
        }
        END { exit found ? 0 : 1 }
    ' /proc/net/tcp
}

honk_tproxy_port() {
    local port="$HONK_DEFAULT_TPROXY_PORT" raw
    if [ -f "$HONK_PREFIX/config.dae" ]; then
        raw=$(sed -n 's/^[[:space:]]*tproxy_port:[[:space:]]*//p' "$HONK_PREFIX/config.dae" | head -n 1)
        raw=${raw%%#*}
        raw=$(printf '%s' "$raw" | tr -d " '\"")
        case $raw in
            ''|*[!0-9]*) ;;
            *)
                if [ "$raw" -ge 1 ] && [ "$raw" -le 65535 ]; then
                    port=$raw
                fi
                ;;
        esac
    fi
    printf '%s\n' "$port"
}

honk_validate_facts() {
    local facts="$1"
    awk '
        BEGIN { ok = 1 }
        /^ifname=/ {
            name = substr($0, 8)
            if (name !~ /^[A-Za-z][A-Za-z0-9._-]{0,14}$/) ok = 0
        }
        /^lan_mask=/ { mask = substr($0, 10) }
        /^primary_ip=/ { primary = substr($0, 12) }
        /^local_ip=/ { locals[substr($0, 10)] = 1 }
        END {
            if (primary == "" || !(primary in locals)) ok = 0
            n = split(mask, o, ".")
            if (n != 4) ok = 0
            bits = 0
            zero = 0
            for (i = 1; i <= 4; i++) {
                v = o[i] + 0
                if (o[i] !~ /^[0-9]+$/ || v > 255) ok = 0
                for (b = 128; b >= 1; b /= 2) {
                    if (int(v / b) % 2 == 1) {
                        if (zero) ok = 0
                        bits++
                    } else zero = 1
                }
            }
            if (bits < 8 || bits > 30) ok = 0
            split(primary, p, ".")
            if (p[1] + 0 == 0 || p[1] + 0 == 127 || p[1] + 0 >= 224) ok = 0
            exit ok ? 0 : 1
        }
    ' "$facts"
}

honk_chain_add() {
    # shellcheck disable=SC2068
    if ! "$HONK_IPTABLES" -t nat -A "$HONK_CHAIN" "$@"; then
        honk_unlink
        return 1
    fi
}

honk_apply() {
    local facts ifname primary mask prefix network cidr port
    facts=$(honk_state honk.facts)
    [ -f "$facts" ] || return 1
    ifname=$(sed -n 's/^ifname=//p' "$facts" | head -n 1)
    primary=$(sed -n 's/^primary_ip=//p' "$facts" | head -n 1)
    mask=$(sed -n 's/^lan_mask=//p' "$facts" | head -n 1)
    prefix=$(honk_prefix "$mask") || return 1
    network=$(honk_network "$primary" "$prefix") || return 1
    port=$(cat "$(honk_state honk.port)" 2>/dev/null || honk_tproxy_port)
    honk_unlink
    "$HONK_IPTABLES" -t nat -N "$HONK_CHAIN" >/dev/null 2>&1 || true
    honk_chain_add -i "$ifname" -p tcp -d "$primary" --dport 9090 -j RETURN || return 1
    honk_chain_add -i "$ifname" -p tcp --dport 53 -j RETURN || return 1
    while IFS= read -r cidr; do
        [ -n "$cidr" ] || continue
        honk_chain_add -i "$ifname" -p tcp -d "$cidr" -j RETURN || return 1
    done <<EOF
$(sed -n 's/^local_ip=//p' "$facts")
$network/$prefix
127.0.0.0/8
169.254.0.0/16
224.0.0.0/4
255.255.255.255/32
$(
# shellcheck disable=SC2086
printf '%s\n' $HONK_PRIVATE_CIDRS
)
EOF
    honk_chain_add -i "$ifname" -p tcp -j REDIRECT --to-ports "$port" || return 1
    if ! "$HONK_IPTABLES" -t nat -C PREROUTING -j "$HONK_CHAIN" >/dev/null 2>&1; then
        honk_chain_add_prerouting || return 1
    fi
}

honk_chain_add_prerouting() {
    if ! "$HONK_IPTABLES" -t nat -A PREROUTING -j "$HONK_CHAIN"; then
        honk_unlink
        return 1
    fi
}

honk_prefix() {
    awk -v mask="$1" 'BEGIN {
        n = split(mask, o, ".")
        if (n != 4) exit 1
        bits = 0
        zero = 0
        for (i = 1; i <= 4; i++) {
            v = o[i] + 0
            if (o[i] !~ /^[0-9]+$/ || v > 255) exit 1
            for (b = 128; b >= 1; b /= 2) {
                if (int(v / b) % 2 == 1) {
                    if (zero) exit 1
                    bits++
                } else zero = 1
            }
        }
        if (bits < 8 || bits > 30) exit 1
        printf "%d\n", bits
    }'
}

honk_network() {
    awk -v ip="$1" -v bits="$2" 'BEGIN {
        split(ip, o, ".")
        if (length(o) != 4) exit 1
        n = 0
        for (i = 1; i <= 4; i++) n = n * 256 + (o[i] + 0)
        shift = 32 - bits
        if (shift > 0) {
            size = 1
            for (i = 0; i < shift; i++) size *= 2
            n = int(n / size) * size
        }
        printf "%d.%d.%d.%d\n", int(n / 16777216) % 256, int(n / 65536) % 256, int(n / 256) % 256, n % 256
    }'
}

honk_accel_on() {
    "$1" status 2>/dev/null | grep -E -q 'L2 & L3 Acceleration is Enabled|Flow Cache is Enabled|is Enabled|^[[:space:]]*Enabled[[:space:]]*$'
}

honk_fc_suspend() {
    local state bin
    state=$(honk_state honk.fc)
    : >"$state"
    bin=$HONK_FC
    if [ -n "$bin" ] && [ -x "$bin" ]; then
        printf 'fc_bin=%s\n' "$bin" >>"$state"
        if honk_accel_on "$bin"; then
            echo fc=on >>"$state"
        else
            echo fc=off >>"$state"
        fi
        if "$bin" disable; then
            "$bin" flush || honk_log fc_flush_failed
        else
            honk_log fc_disable_failed
        fi
    else
        echo fc=absent >>"$state"
    fi
    bin=$HONK_RUNNER
    if [ -n "$bin" ] && [ -x "$bin" ]; then
        printf 'runner_bin=%s\n' "$bin" >>"$state"
        if honk_accel_on "$bin"; then
            echo runner=on >>"$state"
        else
            echo runner=off >>"$state"
        fi
        "$bin" disable || honk_log runner_disable_failed
    else
        echo runner=absent >>"$state"
    fi
    honk_log fc_suspended
}

honk_fc_restore() {
    local state fc_bin runner_bin
    state=$(honk_state honk.fc)
    [ -f "$state" ] || return 0
    fc_bin=$(sed -n 's/^fc_bin=//p' "$state" | head -n 1)
    runner_bin=$(sed -n 's/^runner_bin=//p' "$state" | head -n 1)
    if grep -q '^fc=on$' "$state" && [ -n "$fc_bin" ] && [ -x "$fc_bin" ]; then
        if "$fc_bin" enable; then
            "$fc_bin" flush || honk_log fc_flush_failed
        else
            honk_log fc_enable_failed
        fi
    fi
    if grep -q '^runner=on$' "$state" && [ -n "$runner_bin" ] && [ -x "$runner_bin" ]; then
        "$runner_bin" enable || honk_log runner_enable_failed
    fi
    rm -f "$state"
    honk_log fc_restored
}

honk_export_config() {
    if [ -f "$HONK_PREFIX/config.dae" ]; then
        HONK_CONFIG=$HONK_PREFIX/config.dae
        HONK_NODE_CACHE=$HONK_PREFIX/nodes.cache
        HONK_SELECTIONS=$HONK_PREFIX/select.txt
        export HONK_CONFIG HONK_NODE_CACHE HONK_SELECTIONS
    fi
}

honk_write_selections() {
    [ -f "$HONK_SETTINGS" ] || return 0
    honk_export_config
    local tmp line name value rest
    tmp=$HONK_PREFIX/select.txt.tmp
    : >"$tmp"
    while IFS= read -r line; do
        case $line in
            honk_sel_*)
                rest=${line#honk_sel_}
                name=${rest%% *}
                value=${rest#* }
                case $name in
                    *[!A-Za-z0-9_]*) continue ;;
                esac
                if [ -n "$value" ] && [ "$value" != "$rest" ]; then
                    printf '%s %s\n' "$name" "$value" >>"$tmp"
                fi
                ;;
        esac
    done <"$HONK_SETTINGS"
    mv "$tmp" "$HONK_PREFIX/select.txt"
}

honk_log_file() {
    honk_log "$*"
    mkdir -p "$HONK_STATE_DIR"
    printf '%s\n' "honk: $*" >> "$(honk_state honk.log)"
}

honk_refresh() {
    honk_export_config
    if [ ! -f "$(honk_state honk.armed)" ] || [ ! -x "$HONK_BIN" ] || [ -z "${HONK_CONFIG:-}" ]; then
        honk_log not_armed
        return 1
    fi
    "$HONK_BIN" -c "$HONK_CONFIG" reload >>"$(honk_state honk.log)" 2>&1 || return 1
    honk_log refreshed
}

honk_arm() {
    local minutes now port primary
    if [ ! -f "$HONK_PREFIX/config.dae" ]; then
        honk_log_file need_config
        honk_set_status refused need_config
        return 1
    fi
    if [ ! -x "$HONK_BIN" ]; then
        honk_log_file need_config
        honk_set_status refused need_config
        return 1
    fi
    honk_export_config
    if [ -f "$(honk_state honk.armed)" ]; then
        honk_disarm restart
    fi
    mkdir -p "$HONK_STATE_DIR"
    if ! honk_gather_facts; then
        return 1
    fi
    port=$(honk_tproxy_port)
    primary=$(sed -n 's/^primary_ip=//p' "$(honk_state honk.facts)" | head -n 1)
    printf '%s\n' "$port" >"$(honk_state honk.port)"
    DAE_LOCATION_ASSET=$HONK_PREFIX \
        "$HONK_BIN" -c "$HONK_PREFIX/config.dae" --redirect "$primary:$port" >>"$(honk_state honk.log)" 2>&1 &
    printf '%s\n' "$!" >"$(honk_state honk.pid)"
    if ! honk_wait_listen; then
        honk_disarm listener_down
        return 1
    fi
    honk_fc_suspend
    if ! honk_apply; then
        honk_disarm apply_failed
        return 1
    fi
    minutes=$(honk_minutes)
    now=$(date +%s)
    printf '%s\n' "$((now + minutes * 60))" >"$(honk_state honk.deadline)"
    printf '0\n' >"$(honk_state honk.pingfails)"
    trap '' HUP
    "$HONK_SCRIPT_DIR/honk-watch.sh" >>"$(honk_state honk.log)" 2>&1 &
    printf '%s\n' "$!" >"$(honk_state honk.watch.pid)"
    : >"$(honk_state honk.armed)"
    honk_set_status armed armed
    honk_log "armed port $port"
}

honk_confirm() {
    if [ ! -f "$(honk_state honk.armed)" ]; then
        honk_set_status off not_armed
        return 1
    fi
    : >"$(honk_state honk.confirmed)"
    honk_set_status confirmed confirmed
    honk_log confirmed
}

honk_watch_step() {
    local pid now deadline gw fails
    honk_pin_bins
    if [ ! -f "$(honk_state honk.armed)" ]; then
        return 0
    fi
    pid=$(cat "$(honk_state honk.pid)" 2>/dev/null || true)
    if [ -z "$pid" ] || ! kill -0 "$pid" >/dev/null 2>&1; then
        honk_disarm listener_down
        return 1
    fi
    if ! honk_listening; then
        honk_disarm listener_down
        return 1
    fi
    if [ ! -f "$(honk_state honk.confirmed)" ]; then
        now=$(date +%s)
        deadline=$(cat "$(honk_state honk.deadline)" 2>/dev/null || echo 0)
        if [ "$now" -ge "$deadline" ]; then
            honk_disarm confirm_timeout
            return 1
        fi
    fi
    gw=$(cat "$(honk_state honk.gateway)" 2>/dev/null || true)
    if [ -n "$gw" ] && "$HONK_PING" -c 1 -W 2 "$gw" >/dev/null 2>&1; then
        printf '0\n' >"$(honk_state honk.pingfails)"
        return 0
    fi
    fails=$(cat "$(honk_state honk.pingfails)" 2>/dev/null || echo 0)
    case $fails in
        ''|*[!0-9]*) fails=0 ;;
    esac
    fails=$((fails + 1))
    printf '%s\n' "$fails" >"$(honk_state honk.pingfails)"
    if [ "$fails" -ge "$HONK_PING_LIMIT" ]; then
        honk_disarm ping_failed
        return 1
    fi
    return 0
}

honk_watch_loop() {
    local start now
    start=$(date +%s)
    while :; do
        if [ -f "$(honk_state honk.armed)" ]; then
            honk_watch_step || exit 0
        else
            now=$(date +%s)
            if [ "$((now - start))" -ge "$HONK_ARM_GRACE" ]; then
                exit 0
            fi
        fi
        if [ "${HONK_WATCH_ONCE:-0}" = "1" ]; then
            exit 0
        fi
        sleep "$HONK_WATCH_INTERVAL"
    done
}

honk_nat_start() {
    if [ ! -f "$(honk_state honk.armed)" ]; then
        return 0
    fi
    if [ ! -f "$(honk_state honk.facts)" ] || [ ! -x "$HONK_BIN" ]; then
        honk_disarm listener_down
        return 0
    fi
    if ! honk_watch_step; then
        return 0
    fi
    if ! honk_apply; then
        honk_disarm apply_failed
    fi
}

honk_boot() {
    mkdir -p "$HONK_STATE_DIR"
    honk_disarm boot_off
    if [ "$HONK_SKIP_WEBUI" = "1" ]; then
        return 0
    fi
    honk_mount_page || honk_log webui_failed
}

honk_menu_insert() {
    local file="$1"
    local page="$2"
    local tmp count
    case $page in
        user[0-9].asp|user[0-9][0-9].asp) ;;
        *) return 1 ;;
    esac
    tmp=$file.honk-tmp
    # Match the System page by its URL. Merlin 3006.102 builds use a numeric
    # dictionary token such as <#613#> instead of <#menu5_6_2#>, and the
    # spaces around the colon are not stable. Any other occurrence count
    # leaves the menu file untouched.
    if ! awk -v honk="{url: \"$page\", tabName: \"Honk\"}," '
        function is_anchor(s, t) {
            t = s
            gsub(/[[:space:]]/, "", t)
            return index(t, "url:\"Advanced_System_Content.asp\"") > 0
        }
        BEGIN { n = 0 }
        {
            if (is_anchor($0)) {
                n++
                print
                if (n == 1) {
                    print honk
                }
                next
            }
            if (index($0, "tabName: \"Honk\"") > 0) {
                next
            }
            print
        }
        END { if (n != 1) exit 2 }
    ' "$file" >"$tmp"; then
        rm -f "$tmp"
        honk_log menu_anchor_not_found
        return 1
    fi
    if ! grep -q 'return menuTree' "$tmp"; then
        rm -f "$tmp"
        honk_log menu_anchor_not_found
        return 1
    fi
    count=$(grep -c 'tabName: "Honk"' "$tmp" || true)
    if [ "$count" != "1" ]; then
        rm -f "$tmp"
        honk_log menu_anchor_not_found
        return 1
    fi
    mv "$tmp" "$file"
}

honk_menu_remove() {
    local file="$1"
    local tmp
    [ -f "$file" ] || return 0
    tmp=$file.honk-tmp
    awk 'index($0, "tabName: \"Honk\"") == 0 { print }' "$file" >"$tmp"
    mv "$tmp" "$file"
}

honk_install_block() {
    local file="$1"
    local body="$2"
    local tmp
    mkdir -p "$(dirname "$file")"
    if [ ! -f "$file" ]; then
        printf '%s\n' '#!/bin/sh' >"$file"
        chmod 755 "$file"
    fi
    tmp=$file.honk-tmp
    awk '
        BEGIN { skip = 0 }
        $0 == "# honk-begin" { skip = 1; next }
        $0 == "# honk-end" { skip = 0; next }
        skip == 0 { print }
    ' "$file" >"$tmp"
    {
        cat "$tmp"
        printf '%s\n' '# honk-begin'
        printf '%s\n' "$body"
        printf '%s\n' '# honk-end'
    } >"$file"
    rm -f "$tmp"
    chmod 755 "$file"
}

honk_remove_block() {
    local file="$1"
    local tmp
    [ -f "$file" ] || return 0
    tmp=$file.honk-tmp
    awk '
        BEGIN { skip = 0 }
        $0 == "# honk-begin" { skip = 1; next }
        $0 == "# honk-end" { skip = 0; next }
        skip == 0 { print }
    ' "$file" >"$tmp"
    mv "$tmp" "$file"
}

honk_mount_page() {
    local src page dest marker reuse f sum_src sum_page
    src=$HONK_PREFIX/www/Tools_Honk.asp
    marker='honk-addon-page'
    [ -f "$src" ] || return 1
    [ -f "$HONK_HELPER" ] || return 1
    mkdir -p "$HONK_WWW/user"
    reuse=
    sum_src=$(md5sum <"$src")
    for f in "$HONK_WWW"/user/user*.asp; do
        [ -f "$f" ] || continue
        if ! grep -q "$marker" "$f"; then
            continue
        fi
        sum_page=$(md5sum <"$f")
        if [ "$sum_src" = "$sum_page" ] && [ -z "$reuse" ]; then
            reuse=$(basename "$f")
        else
            rm -f "$f"
        fi
    done
    if [ -n "$reuse" ]; then
        page=$reuse
    else
        # shellcheck disable=SC1090
        . "$HONK_HELPER"
        am_get_webui_page "$src"
        page=${am_webui_page:-none}
        case $page in
            user[0-9].asp|user[0-9][0-9].asp) ;;
            *)
                honk_log "webui slot unavailable"
                return 1
                ;;
        esac
        dest=$HONK_WWW/user/$page
        cp "$src" "$dest"
    fi
    if [ ! -f "$HONK_MENU_TMP" ]; then
        cp "$HONK_MENU_SRC" "$HONK_MENU_TMP"
    fi
    honk_menu_insert "$HONK_MENU_TMP" "$page" || return 1
    printf '%s\n' "$page" >"$HONK_PREFIX/page.name"
    if [ "$HONK_SKIP_MOUNT" = "1" ]; then
        return 0
    fi
    if grep -q "$HONK_MENU_SRC" /proc/mounts 2>/dev/null; then
        umount "$HONK_MENU_SRC" || return 1
    fi
    mount -o bind "$HONK_MENU_TMP" "$HONK_MENU_SRC"
}

honk_install_hooks() {
    local event boot nat firewall
    event="$HONK_SCRIPTS_DIR/service-event"
    boot="$HONK_SCRIPTS_DIR/services-start"
    nat="$HONK_SCRIPTS_DIR/nat-start"
    firewall="$HONK_SCRIPTS_DIR/firewall-start"
    honk_install_block "$event" "case \"\${1:-}:\${2:-}\" in
  start:honk|stop:honk|restart:honk|start:honkconfirm|start:honkrefresh)
    trap '' HUP
    $HONK_PREFIX/scripts/honk-event.sh \"\$1\" \"\$2\" >> $HONK_STATE_DIR/honk-event.log 2>&1 &
    ;;
esac"
    honk_install_block "$boot" "$HONK_PREFIX/scripts/honk-boot.sh"
    honk_install_block "$nat" "$HONK_PREFIX/scripts/honk-nat.sh"
    honk_install_block "$firewall" "$HONK_PREFIX/scripts/honk-firewall.sh"
}

honk_install() {
    local src support
    honk_pin_bins
    support=$("$HONK_NVRAM" get rc_support 2>/dev/null || true)
    if ! printf '%s\n' "$support" | grep -q am_addons; then
        honk_log "firmware has no am_addons"
        return 1
    fi
    src=$(cd "$(dirname "$0")/.." && pwd)
    mkdir -p "$HONK_PREFIX/scripts" "$HONK_PREFIX/www"
    if [ "$src" != "$HONK_PREFIX" ]; then
        cp -R "$src/scripts/." "$HONK_PREFIX/scripts/"
        cp -R "$src/www/." "$HONK_PREFIX/www/"
        if [ -f "$src/honk-core" ]; then
            cp "$src/honk-core" "$HONK_PREFIX/honk-core"
            chmod 755 "$HONK_PREFIX/honk-core"
        fi
        if [ -d "$src/ui" ]; then
            rm -rf "$HONK_PREFIX/ui"
            cp -R "$src/ui" "$HONK_PREFIX/ui"
        fi
        if [ -f "$src/geoip.dat" ]; then
            cp "$src/geoip.dat" "$HONK_PREFIX/geoip.dat"
        fi
        if [ -f "$src/geosite.dat" ]; then
            cp "$src/geosite.dat" "$HONK_PREFIX/geosite.dat"
        fi
    fi
    chmod 755 "$HONK_PREFIX/scripts/"*.sh
    honk_install_hooks
    honk_disarm boot_off
    if [ "$HONK_SKIP_WEBUI" != "1" ]; then
        if ! honk_mount_page; then
            return 1
        fi
        if [ "$(grep -c 'tabName: "Honk"' "$HONK_MENU_TMP" || true)" != "1" ]; then
            honk_log menu_anchor_not_found
            return 1
        fi
    fi
    honk_log installed
}

honk_settings_strip() {
    local tmp
    [ -f "$HONK_SETTINGS" ] || return 0
    tmp=$HONK_SETTINGS.honk-tmp
    grep -v -E '^honk_' "$HONK_SETTINGS" >"$tmp" || true
    mv "$tmp" "$HONK_SETTINGS"
}

honk_uninstall() {
    local other
    honk_disarm uninstalled || true
    honk_remove_block "$HONK_SCRIPTS_DIR/service-event"
    honk_remove_block "$HONK_SCRIPTS_DIR/services-start"
    honk_remove_block "$HONK_SCRIPTS_DIR/nat-start"
    honk_remove_block "$HONK_SCRIPTS_DIR/firewall-start"
    if [ -f "$HONK_MENU_TMP" ]; then
        honk_menu_remove "$HONK_MENU_TMP"
        other=$(grep -E 'url: "user[0-9]+\.asp"' "$HONK_MENU_TMP" || true)
        if [ -z "$other" ] && [ "$HONK_SKIP_MOUNT" != "1" ]; then
            if grep -q "$HONK_MENU_SRC" /proc/mounts 2>/dev/null; then
                umount "$HONK_MENU_SRC" || true
            fi
            rm -f "$HONK_MENU_TMP"
        fi
    fi
    if [ -d "$HONK_WWW/user" ]; then
        for f in "$HONK_WWW"/user/user*.asp; do
            [ -f "$f" ] || continue
            if grep -q 'honk-addon-page' "$f"; then
                rm -f "$f"
            fi
        done
    fi
    honk_settings_strip
    rm -rf "$HONK_PREFIX"
    honk_log uninstalled
}
