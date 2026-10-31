#!/bin/sh
# Manual arm from SSH. The web UI reaches the same function through service-event.
set -eu
HONK_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$HONK_SCRIPT_DIR/honk-common.sh"
honk_arm
