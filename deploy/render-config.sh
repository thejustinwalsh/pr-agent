#!/bin/sh
# render-config.sh — substitute deploy constants into the cloudflared config template.
# POSIX sh; sources config.env, fills __TUNNEL_ID__ from $TUNNEL_ID.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/config.env"
sed "s/__TUNNEL_ID__/${TUNNEL_ID}/g" \
  "$HERE/cloudflared/config.yml.template" > "$HERE/cloudflared/config.yml"
echo "rendered $HERE/cloudflared/config.yml"
