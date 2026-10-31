#!/bin/sh
set -e
PREFIX="${HONK_PREFIX:-/jffs/addons/honk}"
CONFIG="${HONK_CONFIG:-$PREFIX/config.dae}"
OUT="$PREFIX/nodes.dae"
TMP="$PREFIX/nodes.dae.tmp"
LOG="${HONK_STATE_DIR:-/tmp}/honk-nodes-sync.log"
URL_FILE="$PREFIX/subscription.url"
SKIP_RE='剩余流量|套餐到期|官网|到期'
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }
extract_url() {
    if [ -f "$URL_FILE" ] && [ -s "$URL_FILE" ]; then sed -n '1p' "$URL_FILE"; return 0; fi
    sed -n "s/.*'\\(https:\\/\\/[^']*\\)'.*/\\1/p" "$CONFIG" 2>/dev/null | head -1
}
urldecode() { printf '%b' "$(printf '%s' "$1" | sed 's/+/ /g; s/%/\\x/g')"; }
fetch_ss_lines() {
    url="$1"; body="$PREFIX/nodes.sub.body"
    curl -fsSL -A 'curl/8.0' -o "$body" --connect-timeout 15 --max-time 45 "$url" || return 1
    if grep -q '^ss://' "$body" 2>/dev/null; then cat "$body"; return 0; fi
    tr -d '\r\n \t' <"$body" | base64 -d 2>/dev/null || tr -d '\r\n \t' <"$body" | openssl base64 -d -A 2>/dev/null
}
build_nodes() {
    echo 'node {'; n=0; seen="$PREFIX/nodes.seen.$$"; : >"$seen"
    while IFS= read -r L || [ -n "$L" ]; do
        case "$L" in ss://*) ;; *) continue ;; esac
        rest="${L#ss://}"; name=""
        case "$rest" in *\#*) name="${rest#*\#}"; rest="${rest%%\#*}"; name=$(urldecode "$name"); ;; esac
        [ -n "$name" ] || continue
        echo "$name" | grep -qE "$SKIP_RE" && continue
        key="${rest%%\?*}"
        grep -qxF "$key" "$seen" 2>/dev/null && continue
        echo "$key" >>"$seen"
        case "$name" in
            *\'*) qn=$(printf '%s' "$name" | sed 's/\\/\\\\/g; s/"/\\"/g'); printf '    "%s": '\''ss://%s'\''\n' "$qn" "$key" ;;
            *) printf "    '%s': 'ss://%s'\n" "$name" "$key" ;;
        esac
        n=$((n+1))
    done
    echo '}'; rm -f "$seen"; [ "$n" -ge 1 ] || return 2; log "built entries=$n"
}
validate_nodes() {
    file="$1"; grep -q '^node {' "$file" || return 1; grep -q 'ss://' "$file" || return 1
    grep -q '^}' "$file" || return 1; cnt=$(grep -c 'ss://' "$file" || echo 0); [ "$cnt" -ge 1 ]
}
main() {
    mkdir -p "$PREFIX"; url=$(extract_url)
    if [ -z "$url" ]; then log "no URL"; [ -s "$OUT" ] || return 1; return 0; fi
    printf '%s\n' "$url" >"$URL_FILE"; chmod 600 "$URL_FILE" 2>/dev/null || true
    if ! fetch_ss_lines "$url" >"$PREFIX/nodes.sub.list"; then log "fetch fail"; [ -s "$OUT" ] || return 1; return 0; fi
    if ! build_nodes <"$PREFIX/nodes.sub.list" >"$TMP"; then log "build fail"; rm -f "$TMP"; [ -s "$OUT" ] || return 1; return 0; fi
    if ! validate_nodes "$TMP"; then log "validate fail"; rm -f "$TMP"; [ -s "$OUT" ] || return 1; return 0; fi
    chmod 600 "$TMP"; mv -f "$TMP" "$OUT"; log "wrote $OUT"
    if [ "${1:-}" = "--reload" ]; then
        pid=$(cat /tmp/honk.pid 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then kill -HUP "$pid" 2>/dev/null && log "SIGHUP $pid" || true; fi
    fi
}
main "$@"
