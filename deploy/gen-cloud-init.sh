#!/usr/bin/env bash
# Render cloud-init.template.yaml with per-server vars → paste-ready doc. Asserts < 32 KiB.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VARS="${1:?vars file required}"; OUT="${2:-$HERE/cloud-init.out.yaml}"
# shellcheck source=/dev/null
source "$VARS"
: "${CF_SERVICE_TOKEN_ID:?}"; : "${CF_SERVICE_TOKEN_SECRET:?}"; : "${FORK_REPO:?}"; : "${TUNNEL_ID:?}"
sed -e "s|__CF_SERVICE_TOKEN_ID__|${CF_SERVICE_TOKEN_ID}|g" \
    -e "s|__CF_SERVICE_TOKEN_SECRET__|${CF_SERVICE_TOKEN_SECRET}|g" \
    -e "s|__FORK_REPO__|${FORK_REPO}|g" \
    -e "s|__TUNNEL_ID__|${TUNNEL_ID}|g" \
    "$HERE/cloud-init.template.yaml" > "$OUT"
if grep -q "__" "$OUT"; then echo "gen-cloud-init: leftover placeholder in $OUT" >&2; exit 1; fi
SIZE="$(wc -c < "$OUT")"
if [ "$SIZE" -ge 32768 ]; then echo "gen-cloud-init: $OUT is $SIZE bytes (>=32KiB limit)" >&2; exit 1; fi
# Schema guard. cloud-init is Linux-only; on macOS (dev) it's absent — fall back to
# yamllint so the render still gets a structural sanity check either way.
if command -v cloud-init >/dev/null 2>&1; then
  cloud-init schema --config-file "$OUT"
elif command -v yamllint >/dev/null 2>&1; then
  yamllint -d relaxed "$OUT"
fi
echo "gen-cloud-init: wrote $OUT ($SIZE bytes)"
