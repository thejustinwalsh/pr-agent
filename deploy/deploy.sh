#!/usr/bin/env bash
# PR-Agent deploy/rollback. Pulls a newer ghcr tag, smoke-tests the candidate,
# swaps the floating localhost/pr-agent:current tag, restarts the container
# services, and records last-known-good state.
#
# PR-Agent is STATELESS: there is no data volume and nothing to back up. The
# only state we keep is the deploy-state ledger (CURRENT/PREVIOUS tags) so that
# --rollback can retarget :current without re-querying ghcr.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/config.env"
STATE_DIR="${DEPLOY_STATE_DIR:-$DATA_MOUNT}"
STATE="$STATE_DIR/deploy-state"
mkdir -p "$STATE_DIR"

SMOKE_PORT="${DEPLOY_SMOKE_PORT:-3099}"
SMOKE_NAME="pr-agent-smoke"

log() { echo "[deploy] $*"; }

current_tag() { [ -f "$STATE" ] && (grep '^CURRENT=' "$STATE" | cut -d= -f2) || echo ""; }
previous_tag() { [ -f "$STATE" ] && (grep '^PREVIOUS=' "$STATE" | cut -d= -f2) || echo ""; }

# List remote tags via the ghcr REST API (public image, anonymous pull token).
# Uses curl+jq (already installed by cloud-init) — no skopeo dependency.
latest_remote_tag() {
  local repo token
  repo="${IMAGE#ghcr.io/}"   # e.g. thejustinwalsh/pr-agent
  token="$(curl -fsS "https://ghcr.io/token?scope=repository:${repo}:pull" | jq -r '.token')"
  curl -fsS -H "Authorization: Bearer ${token}" "https://ghcr.io/v2/${repo}/tags/list" \
    | jq -r '.tags[]?' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -n1
}

# Smoke test: boot the candidate image in a throwaway container publishing
# 127.0.0.1:$SMOKE_PORT:$WEBHOOK_PORT and poll the webhook root until the process
# answers. The webhook server is a GitHub-App receiver, not a health endpoint:
# GET / has no business meaning and may return 404/405, but ANY HTTP response
# proves the gunicorn/uvicorn worker is up and serving. So "up & serving" =
# (a) curl gets an HTTP status line back, AND (b) the container is still Up
# (a crash-on-boot exits the container, so a transient bind during teardown
# can't be mistaken for health). PR-Agent refuses to start without its GitHub
# App / OpenAI config, so we feed it dummy creds purely to clear that gate; the
# smoke never talks to GitHub or DeepSeek.
smoke_test() {
  local tag="$1" ok=1 code
  if [ "${DEPLOY_SMOKE_OVERRIDE:-}" = "pass" ]; then return 0; fi
  if [ "${DEPLOY_SMOKE_OVERRIDE:-}" = "fail" ]; then return 1; fi
  podman rm -f "$SMOKE_NAME" >/dev/null 2>&1 || true
  podman run -d --name "$SMOKE_NAME" \
    -e OPENAI__KEY=smoke-dummy \
    -e OPENAI__API_BASE="${DEEPSEEK_API_BASE}" \
    -e CONFIG__MODEL="${DEEPSEEK_MODEL}" \
    -e GITHUB__DEPLOYMENT_TYPE=app \
    -e GITHUB__WEBHOOK_SECRET=smoke-dummy \
    -e GITHUB_APP__APP_ID=000000 \
    -e GITHUB_APP__PRIVATE_KEY=smoke-dummy \
    -p "127.0.0.1:${SMOKE_PORT}:${WEBHOOK_PORT}" \
    "$IMAGE:$tag" >/dev/null
  for _ in $(seq 1 30); do
    # -o /dev/null -w '%{http_code}' returns the status code for ANY response
    # (200/404/405/...). curl exits non-zero only when nothing is listening, in
    # which case the code is "000".
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${SMOKE_PORT}/" 2>/dev/null || echo 000)"
    if [ "$code" != "000" ] && [ "$code" != "" ]; then
      # Got an HTTP status line back. Confirm the container is genuinely Up and
      # not mid-exit before declaring the candidate healthy.
      if podman ps --filter "name=${SMOKE_NAME}" --filter "status=running" \
          --format '{{.Names}}' 2>/dev/null | grep -q "^${SMOKE_NAME}$"; then
        log "smoke: webhook answered HTTP $code and container is Up"
        ok=0
        break
      fi
    fi
    sleep 1
  done
  podman logs "$SMOKE_NAME" 2>&1 | tail -5 || true
  podman rm -f "$SMOKE_NAME" >/dev/null 2>&1 || true
  return $ok
}

swap_to() { # retarget the floating :current tag + restart the container services
  local tag="$1"
  podman pull "$IMAGE:$tag"
  podman tag "$IMAGE:$tag" "localhost/pr-agent:current"
  systemctl --user daemon-reload 2>/dev/null || true
  # Restart the CONTAINER services (not the pod): under Quadlet each container is
  # its own service and pulls in the pod as a dependency. Restarting only the pod
  # service would leave the containers down. `restart` also starts them on first run.
  systemctl --user restart pr-agent.service pr-agent-cloudflared.service 2>/dev/null || true
}

record_state() { printf 'CURRENT=%s\nPREVIOUS=%s\n' "$1" "$2" > "$STATE"; }

do_rollback() {
  local prev; prev="$(previous_tag)"
  [ -n "$prev" ] || { log "no previous tag to roll back to"; exit 1; }
  log "rolling back to $prev"
  swap_to "$prev"
  record_state "$prev" ""
  log "rollback complete"
}

main() {
  if [ "${1:-}" = "--rollback" ]; then do_rollback; return; fi
  local cur new; cur="$(current_tag)"; new="$(latest_remote_tag)"
  [ -n "$new" ] || { log "no remote tags found"; exit 1; }
  if [ "$new" = "$cur" ]; then log "already on $cur; nothing to do"; return 0; fi
  log "candidate $new (current: ${cur:-none})"
  podman pull "$IMAGE:$new"
  if ! smoke_test "$new"; then
    log "SMOKE TEST FAILED for $new — keeping ${cur:-current}, not swapping"
    exit 1
  fi
  swap_to "$new"
  record_state "$new" "$cur"
  log "deployed $new"
}
main "$@"
