#!/bin/sh
# services-start: mount the page and leave interception off.
set -eu
HONK_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$HONK_SCRIPT_DIR/honk-common.sh"
honk_boot || true
exit 0
