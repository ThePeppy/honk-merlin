#!/bin/sh
set -eu
HONK_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$HONK_SCRIPT_DIR/honk-common.sh"
honk_disarm stopped
