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
    stop:honk|restart:honk)
        honk_disarm stopped || true
        ;;
    start:honkconfirm)
        honk_confirm || true
        ;;
esac
exit 0
