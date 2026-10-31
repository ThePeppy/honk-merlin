#!/bin/sh
# One-shot rollback: drop the nat jump, delete listener conntrack entries,
# stop the process, unhook scripts, and remove /jffs/addons/honk.
set -eu
HONK_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$HONK_SCRIPT_DIR/honk-common.sh"
honk_uninstall
