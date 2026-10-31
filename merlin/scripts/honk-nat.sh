#!/bin/sh
# nat-start may re-add HONK_PRE only when this boot already armed it.
# Stored honk_enable is ignored. firewall-start must not do this job:
# Merlin passes the WAN interface there, and that hook is for the filter table.
set -eu
HONK_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$HONK_SCRIPT_DIR/honk-common.sh"
honk_nat_start || true
exit 0
