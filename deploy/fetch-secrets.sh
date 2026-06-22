#!/usr/bin/env bash
# Fetch app secrets from the Cloudflare broker (Access service token) -> podman secrets.
# The shared broker (secrets.tjw.dev) is path-scoped per project; we read this box's
# bundle at /secrets/$SECRETS_NS. It returns JSON; each value becomes a podman secret,
# consumed by the quadlet as env/mount targets.
#
# Multi-line PEM: GITHUB_APP_PRIVATE_KEY is stored in the Secrets Store as single-line
# base64 (so it survives single-line secret fields and the broker's JSON round-trip
# unchanged). `put ... base64` decodes it with `openssl base64 -d -A` back to the raw
# multi-line PEM, then pipes those bytes into `podman secret create` verbatim. The
# quadlet maps it type=env,target=GITHUB_APP__PRIVATE_KEY; podman injects the intact
# multi-line key into the container env. (bootstrap-secrets.sh reads the raw .pem file
# directly, so its end state matches — both yield a real-newline PEM.)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/config.env"
: "${CF_SERVICE_TOKEN_ID:?service token id required}"
: "${CF_SERVICE_TOKEN_SECRET:?service token secret required}"
: "${SECRETS_NS:?secrets namespace required}"

# Single-use OTP: sourced from its own root-owned file (path overridable for tests),
# required, sent to the broker, and deleted after a successful fetch so the raw
# OTP does not persist on-box.
OTP_ENV="${OTP_ENV:-/etc/pr-agent/otp.env}"
# shellcheck source=/dev/null
[ -r "$OTP_ENV" ] && . "$OTP_ENV"
: "${SECRETS_OTP:?SECRETS_OTP required — mint a fresh OTP (see recovery runbook)}"

# Single attempt (no --retry): a retry could race the broker's consume-once delete.
JSON="$(curl -fsS "https://$SECRETS_DOMAIN/secrets/$SECRETS_NS" \
  -H "CF-Access-Client-Id: $CF_SERVICE_TOKEN_ID" \
  -H "CF-Access-Client-Secret: $CF_SERVICE_TOKEN_SECRET" \
  -H "X-Secrets-OTP: $SECRETS_OTP")"

put() { # podman-secret-name <- json key [base64]
  local secret="$1" key="$2" decode="${3:-}" val
  val="$(printf '%s' "$JSON" | jq -er ".$key")"
  # The multi-line GitHub App PEM is stored base64-encoded (single-line, so it
  # survives single-line secret fields); decode it back to the raw PEM here.
  if [ "$decode" = "base64" ]; then
    val="$(printf '%s' "$val" | openssl base64 -d -A)"
  fi
  printf '%s' "$val" | podman secret rm "$secret" >/dev/null 2>&1 || true
  printf '%s' "$val" | podman secret create "$secret" - >/dev/null
}
put "$SECRET_DEEPSEEK"   DEEPSEEK_API_KEY
put "$SECRET_GH_APP_KEY" GITHUB_APP_PRIVATE_KEY base64
put "$SECRET_GH_APP_ID"  GITHUB_APP_ID
put "$SECRET_WEBHOOK"    GITHUB_WEBHOOK_SECRET
put "$SECRET_TUNNEL"     TUNNEL_CRED

# Burn the on-box copy of the single-use OTP.
rm -f "$OTP_ENV" 2>/dev/null || true

# No ghcr login — images are public, pulled anonymously.
echo "[fetch-secrets] podman secrets created; OTP consumed"
