#!/bin/sh
# Install under /jffs/addons/honk and hook services-start, nat-start,
# firewall-start, and service-event. Does not intercept traffic.
set -eu
HONK_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$HONK_SCRIPT_DIR/honk-common.sh"
honk_install
