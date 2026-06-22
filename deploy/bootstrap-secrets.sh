#!/usr/bin/env bash
# Fallback: create podman secrets by hand if the broker is unreachable.
#
# GITHUB_APP_PRIVATE_KEY is a multi-line PEM, so it CANNOT be typed at a single-line
# prompt — pass the path to the downloaded .pem file as the first argument and we feed
# the file verbatim into `podman secret create` (newlines preserved). The quadlet maps
# it with type=env,target=GITHUB_APP__PRIVATE_KEY; podman injects the multi-line value
# into the container env intact.
#
# Usage: bootstrap-secrets.sh /path/to/github-app-private-key.pem
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/config.env"

PEM_PATH="${1:?usage: bootstrap-secrets.sh /path/to/github-app-private-key.pem}"
[ -r "$PEM_PATH" ] || { echo "PEM file not readable: $PEM_PATH" >&2; exit 1; }

prompt() { # podman-secret-name <- interactive (hidden) single-line value
  local var="$1" msg="$2" v
  read -rsp "$msg: " v; echo
  printf '%s' "$v" | podman secret rm "$var" >/dev/null 2>&1 || true
  printf '%s' "$v" | podman secret create "$var" -
}

echo "Manual secret bootstrap (fallback). Values are not echoed."
prompt "$SECRET_DEEPSEEK"  "DEEPSEEK_API_KEY"
prompt "$SECRET_GH_APP_ID" "GITHUB_APP_ID"
prompt "$SECRET_WEBHOOK"   "GITHUB_WEBHOOK_SECRET"

# Multi-line PEM: read straight from the file, never echoed, newlines preserved.
podman secret rm "$SECRET_GH_APP_KEY" >/dev/null 2>&1 || true
podman secret create "$SECRET_GH_APP_KEY" "$PEM_PATH" >/dev/null
echo "GITHUB_APP_PRIVATE_KEY loaded from $PEM_PATH"

echo "Paste tunnel credential JSON, end with Ctrl-D:"
podman secret rm "$SECRET_TUNNEL" >/dev/null 2>&1 || true
podman secret create "$SECRET_TUNNEL" -

# No ghcr login — images are public.
echo "[bootstrap] done"
