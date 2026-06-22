#!/usr/bin/env bash
# Render cloud-init.template.yaml with per-server vars → paste-ready doc. Asserts < 32 KiB.
# Mints a single-use OTP, registers sha256(otp)→namespace in Workers KV (1h TTL),
# and injects the raw OTP. Fails loud (emits nothing) if minting fails.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VARS="${1:?vars file required}"; OUT="${2:-$HERE/cloud-init.out.yaml}"
# shellcheck source=/dev/null
source "$VARS"
: "${CF_SERVICE_TOKEN_ID:?}"; : "${CF_SERVICE_TOKEN_SECRET:?}"; : "${FORK_REPO:?}"; : "${TUNNEL_ID:?}"
: "${OTP_KV_ID:?run 'wrangler kv namespace create OTP_KV' and set OTP_KV_ID}"
SECRETS_NS="${SECRETS_NS:-pr-agent}"
case "$SECRETS_NS" in *[!a-z0-9-]*|"") echo "gen-cloud-init: bad SECRETS_NS '$SECRETS_NS'" >&2; exit 1;; esac
WRANGLER="${WRANGLER:-wrangler}"

# Mint BEFORE rendering: a failed mint must emit no cloud-init.
OTP="$(openssl rand -hex 32)"
HASH="$(printf %s "$OTP" | openssl dgst -sha256 -hex | sed 's/^.*= *//')"
( set +x
  # --remote is REQUIRED: kv key put defaults to LOCAL storage, which the deployed
  # broker cannot read — the OTP would silently never resolve and every boot 410s.
  "$WRANGLER" kv key put --namespace-id="$OTP_KV_ID" "$HASH" "$SECRETS_NS" --ttl 3600 --remote >/dev/null
  got="$("$WRANGLER" kv key get --namespace-id="$OTP_KV_ID" "$HASH" --remote)"
  [ "$got" = "$SECRETS_NS" ] || { echo "gen-cloud-init: KV read-back mismatch" >&2; exit 1; }
)

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
sed -e "s|__CF_SERVICE_TOKEN_ID__|${CF_SERVICE_TOKEN_ID}|g" \
    -e "s|__CF_SERVICE_TOKEN_SECRET__|${CF_SERVICE_TOKEN_SECRET}|g" \
    -e "s|__FORK_REPO__|${FORK_REPO}|g" \
    -e "s|__TUNNEL_ID__|${TUNNEL_ID}|g" \
    -e "s|__SECRETS_OTP__|${OTP}|g" \
    "$HERE/cloud-init.template.yaml" > "$tmp"
if grep -q "__" "$tmp"; then echo "gen-cloud-init: leftover placeholder in render" >&2; exit 1; fi
SIZE="$(wc -c < "$tmp")"
if [ "$SIZE" -ge 32768 ]; then echo "gen-cloud-init: $SIZE bytes (>=32KiB limit)" >&2; exit 1; fi
# Schema guard. cloud-init is Linux-only; on macOS (dev) it's absent — fall back to
# yamllint so the render still gets a structural sanity check either way.
if command -v cloud-init >/dev/null 2>&1; then
  cloud-init schema --config-file "$tmp"
elif command -v yamllint >/dev/null 2>&1; then
  yamllint -d relaxed "$tmp"
fi
mv "$tmp" "$OUT"; trap - EXIT
echo "gen-cloud-init: wrote $OUT ($SIZE bytes)"
echo "gen-cloud-init: OTP valid 60 minutes — paste into Hetzner and boot within the window."
