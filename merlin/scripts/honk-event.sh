#!/bin/sh
# service-event child. The hook backgrounds this script so rc is not blocked.
set -eu
HONK_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$HONK_SCRIPT_DIR/honk-common.sh"

case "${1:-}:${2:-}" in
    start:honk)
        honk_arm || true
        ;;
    restart:honk)
        honk_restart || true
        ;;
    stop:honk)
        honk_disarm stopped || true
        ;;
    start:honkrefresh)
        # kept for compatibility; reloads honk-core config via SIGHUP
        honk_refresh || true
        ;;
    start:honkconfirm)
        honk_confirm || true
        ;;
esac
exit 0
