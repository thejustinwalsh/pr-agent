#!/usr/bin/env bash
# End-to-end broker check — no manual values. Reads SECRETS_DOMAIN / SECRETS_NS
# from config.env and CF_SERVICE_TOKEN_* from cloud-init.vars (or the env), mints
# a single-use OTP into the remote KV, fetches the bundle with the service token,
# asserts all five keys are present and non-empty, and that an immediate replay of
# the same OTP is rejected (consume-once). Run from your Mac after the broker is
# deployed, its Worker secrets are set, and the Access service-token policy exists.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BROKER_DIR="${BROKER_DIR:-$HERE/../secrets-broker}"
read -ra WRANGLER_CMD <<< "${WRANGLER:-npx wrangler}"
# shellcheck source=/dev/null
. "$HERE/config.env"                                  # SECRETS_DOMAIN, SECRETS_NS
# CF service token: from cloud-init.vars if present, else the environment.
CF_VARS="${CF_VARS:-$HERE/cloud-init.vars}"
# shellcheck source=/dev/null
[ -r "$CF_VARS" ] && . "$CF_VARS"
: "${SECRETS_DOMAIN:?}"; : "${SECRETS_NS:?}"
: "${CF_SERVICE_TOKEN_ID:?set it in deploy/cloud-init.vars or the environment}"
: "${CF_SERVICE_TOKEN_SECRET:?set it in deploy/cloud-init.vars or the environment}"

EXPECTED="DEEPSEEK_API_KEY,GITHUB_APP_ID,GITHUB_APP_PRIVATE_KEY,GITHUB_WEBHOOK_SECRET,TUNNEL_CRED"
URL="https://$SECRETS_DOMAIN/secrets/$SECRETS_NS"

# Mint a single-use OTP into the REMOTE KV (--binding reads the id from
# wrangler.toml; --remote is mandatory — kv key put defaults to local).
OTP="$(openssl rand -hex 32)"
HASH="$(printf %s "$OTP" | openssl dgst -sha256 -hex | sed 's/^.*= *//')"
( cd "$BROKER_DIR" && "${WRANGLER_CMD[@]}" kv key put --binding OTP_KV "$HASH" "$SECRETS_NS" --ttl 3600 --remote >/dev/null )

hdr=(-H "CF-Access-Client-Id: $CF_SERVICE_TOKEN_ID"
     -H "CF-Access-Client-Secret: $CF_SERVICE_TOKEN_SECRET"
     -H "X-Secrets-OTP: $OTP")

# First fetch: must be 200 with the full bundle.
if ! body="$(curl -fsS "$URL" "${hdr[@]}")"; then
  echo "[verify-broker] FAIL: fetch did not return 200." >&2
  echo "  Check: Access service-token policy on $SECRETS_DOMAIN (else 403), and" >&2
  echo "  that 'bash deploy/set-broker-secrets.sh' has run (else 500)." >&2
  exit 1
fi

keys="$(printf '%s' "$body" | jq -r 'keys | join(",")')"
if [ "$keys" != "$EXPECTED" ]; then
  echo "[verify-broker] FAIL: keys = [$keys], expected [$EXPECTED]" >&2
  exit 1
fi
for k in DEEPSEEK_API_KEY GITHUB_APP_ID GITHUB_APP_PRIVATE_KEY GITHUB_WEBHOOK_SECRET TUNNEL_CRED; do
  v="$(printf '%s' "$body" | jq -r --arg k "$k" '.[$k] // ""')"
  [ -n "$v" ] || { echo "[verify-broker] FAIL: $k is empty" >&2; exit 1; }
done
echo "[verify-broker] 200 + all 5 keys present and non-empty ✓"

# Replay the SAME OTP: must now be rejected (consume-once).
code="$(curl -s -o /dev/null -w '%{http_code}' "$URL" "${hdr[@]}")"
if [ "$code" != "410" ]; then
  echo "[verify-broker] FAIL: replay returned $code, expected 410 (consume-once broken)" >&2
  exit 1
fi
echo "[verify-broker] replay rejected with 410 (consume-once) ✓"
echo "[verify-broker] OK — broker is wired correctly"
