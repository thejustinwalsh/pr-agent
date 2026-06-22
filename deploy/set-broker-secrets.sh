#!/usr/bin/env bash
# Set all pr-agent app secrets as Cloudflare Worker secrets on the broker, in one
# shot. Run from your Mac (wrangler authenticated) AFTER `wrangler deploy` of the
# broker. Re-run any time to rotate. Worker secrets have no 1024-char Secrets Store
# cap, so the GitHub App PEM fits — and there is one uniform mechanism, no mix.
#
# Reads a gitignored vars file (default deploy/broker-secrets.vars). The three
# simple values are inline (single-quote them to survive shell sourcing); the two
# structured values are FILE PATHS, so JSON/PEM are never mangled by the shell:
#   DEEPSEEK_API_KEY='sk-...'
#   GITHUB_APP_ID=1234567
#   GITHUB_WEBHOOK_SECRET='...'
#   TUNNEL_CRED_FILE=~/.cloudflared/<TUNNEL_UUID>.json
#   GITHUB_APP_PRIVATE_KEY_FILE=/path/to/pr-agent.<date>.private-key.pem
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VARS="${1:-$HERE/broker-secrets.vars}"
BROKER_DIR="${BROKER_DIR:-$HERE/../secrets-broker}"
read -ra WRANGLER_CMD <<< "${WRANGLER:-npx wrangler}"
# shellcheck source=/dev/null
source "$VARS"
: "${DEEPSEEK_API_KEY:?}"; : "${GITHUB_APP_ID:?}"; : "${GITHUB_WEBHOOK_SECRET:?}"
: "${TUNNEL_CRED_FILE:?}"; : "${GITHUB_APP_PRIVATE_KEY_FILE:?}"
[ -r "$TUNNEL_CRED_FILE" ] || { echo "tunnel cred not readable: $TUNNEL_CRED_FILE" >&2; exit 1; }
[ -r "$GITHUB_APP_PRIVATE_KEY_FILE" ] || { echo "PEM not readable: $GITHUB_APP_PRIVATE_KEY_FILE" >&2; exit 1; }

put() { # secret-name  <- value on stdin
  ( cd "$BROKER_DIR" && "${WRANGLER_CMD[@]}" secret put "$1" >/dev/null )
}
printf '%s' "$DEEPSEEK_API_KEY"      | put DEEPSEEK_API_KEY
printf '%s' "$GITHUB_APP_ID"         | put GITHUB_APP_ID
printf '%s' "$GITHUB_WEBHOOK_SECRET" | put GITHUB_WEBHOOK_SECRET
# Tunnel cred: the raw cloudflared JSON file, sent verbatim.
put TUNNEL_CRED < "$TUNNEL_CRED_FILE"
# PEM: base64 single-line (fits the broker's JSON round-trip cleanly); the box's
# fetch-secrets.sh decodes it (openssl base64 -d -A) back to the real multi-line PEM.
openssl base64 -A -in "$GITHUB_APP_PRIVATE_KEY_FILE" | put GITHUB_APP_PRIVATE_KEY

echo "[set-broker-secrets] set 5 Worker secrets on the broker"
