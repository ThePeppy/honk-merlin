#!/bin/sh
# dnsmasq.postconf child. Point LAN DNS at honk only while the addon is
# armed. A stopped addon must keep the firmware's own upstream, otherwise
# dnsmasq forwards every LAN query to a listener that is no longer running.
set -eu
CONFIG=${1:-}
[ -n "$CONFIG" ] || exit 0
HONK_STATE_DIR=${HONK_STATE_DIR:-/tmp}
armed=0
if [ -f "$HONK_STATE_DIR/honk.armed" ]; then
    armed=1
fi
if [ -f /usr/sbin/helper.sh ]; then
    . /usr/sbin/helper.sh
    pc_delete "server=127.0.0.1#5353" "$CONFIG"
    pc_delete "server=127.0.0.1#5354" "$CONFIG"
    if [ "$armed" = 1 ]; then
        # While armed the ISP upstream would bypass honk's domain lookup.
        pc_delete "servers-file=" "$CONFIG"
        pc_append "server=127.0.0.1#5354" "$CONFIG"
    fi
else
    # sed -i differs between GNU and BSD; use one awk pass instead.
    tmp=$CONFIG.honk-tmp
    awk -v armed="$armed" '
        /^server=127\.0\.0\.1#5353$/ { next }
        /^server=127\.0\.0\.1#5354$/ { next }
        armed == 1 && /^servers-file=/ { next }
        { print }
        END { if (armed == 1) print "server=127.0.0.1#5354" }
    ' "$CONFIG" >"$tmp" && mv "$tmp" "$CONFIG"
fi
