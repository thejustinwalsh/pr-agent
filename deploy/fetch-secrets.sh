#!/usr/bin/env bash
# Fetch app secrets from the Cloudflare broker (Access service token) -> podman secrets.
# The shared broker (secrets.tjw.dev) is path-scoped per project; we read this box's
# bundle at /secrets/$SECRETS_NS. It returns JSON; each value becomes a podman secret,
# consumed by the quadlet as env/mount targets.
#
# Multi-line PEM: GITHUB_APP_PRIVATE_KEY is a multi-line PEM. It rides through the
# broker as a JSON string (newlines as \n), jq -er decodes it back to real newlines,
# and `printf '%s'` pipes those raw bytes straight into `podman secret create`, which
# stores the value verbatim. The quadlet then maps it with type=env,target=...; podman
# injects the multi-line value into the container env intact. No re-encoding anywhere.
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

put() { # podman-secret-name <- json key
  local secret="$1" key="$2" val
  val="$(printf '%s' "$JSON" | jq -er ".$key")"
  printf '%s' "$val" | podman secret rm "$secret" >/dev/null 2>&1 || true
  printf '%s' "$val" | podman secret create "$secret" - >/dev/null
}
put "$SECRET_DEEPSEEK"   DEEPSEEK_API_KEY
put "$SECRET_GH_APP_KEY" GITHUB_APP_PRIVATE_KEY
put "$SECRET_GH_APP_ID"  GITHUB_APP_ID
put "$SECRET_WEBHOOK"    GITHUB_WEBHOOK_SECRET
put "$SECRET_TUNNEL"     TUNNEL_CRED

# Burn the on-box copy of the single-use OTP.
rm -f "$OTP_ENV" 2>/dev/null || true

# No ghcr login — images are public, pulled anonymously.
echo "[fetch-secrets] podman secrets created; OTP consumed"
