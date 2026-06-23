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
REPO_ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
source "$HERE/config.env"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-production}"
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

swap_to() { # retarget the floating :current tag + restart the pod stack
  local tag="$1"
  podman pull "$IMAGE:$tag"
  podman tag "$IMAGE:$tag" "localhost/pr-agent:current"
  systemctl --user daemon-reload 2>/dev/null || true
  # Quadlet binds each container to pragent-pod.service with BindsTo: the container
  # stops if the pod stops, but starting the container does NOT start the pod. A swap
  # stops both containers, which stops the pod; restarting only the containers then
  # fails their pod dependency ("unit isn't active") and leaves the service DOWN. So
  # stop the containers, (re)start the pod infra, then start the containers — in order.
  # Fail-loud: no `|| true` on the start path, so a broken swap surfaces to verify_live.
  systemctl --user stop pr-agent.service pr-agent-cloudflared.service 2>/dev/null || true
  systemctl --user restart pragent-pod.service
  systemctl --user start pr-agent.service pr-agent-cloudflared.service
}

# Confirm the live pod actually came up after a swap: the unit reports active AND the
# container is running (not crash-looping). Retries because gunicorn takes a moment.
verify_live() {
  local retries="${DEPLOY_VERIFY_RETRIES:-15}" nap="${DEPLOY_VERIFY_SLEEP:-2}" _
  for _ in $(seq 1 "$retries"); do
    if [ "$(systemctl --user is-active pr-agent.service 2>/dev/null || true)" = "active" ] \
       && podman ps --filter name=pr-agent --filter status=running --format '{{.Names}}' 2>/dev/null \
          | grep -qx pr-agent; then
      return 0
    fi
    sleep "$nap"
  done
  return 1
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

# Pull the latest deploy scripts + units before deploying. cloud-init only clones
# the repo once, so without this the box runs frozen scripts. Best-effort: a
# transient git failure must NOT block an image deploy. Quadlet/service/timer units
# live as copies under ~/.config (separate from the repo), so re-sync them too;
# daemon-reload picks up unit changes on the next run.
self_refresh() {
  log "refresh: fetching $DEPLOY_BRANCH"
  if git -C "$REPO_ROOT" fetch --depth 1 origin "$DEPLOY_BRANCH" \
     && git -C "$REPO_ROOT" reset --hard FETCH_HEAD; then
    log "refresh: repo at $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
    cdir="$HOME/.config/containers/systemd"; udir="$HOME/.config/systemd/user"
    mkdir -p "$cdir" "$udir"
    cp "$REPO_ROOT"/deploy/quadlet/*.pod "$REPO_ROOT"/deploy/quadlet/*.container "$cdir"/ 2>/dev/null || true
    cp "$REPO_ROOT"/deploy/quadlet/*.timer "$REPO_ROOT"/deploy/quadlet/*.service "$udir"/ 2>/dev/null || true
    systemctl --user daemon-reload 2>/dev/null || true
  else
    log "WARNING: refresh failed; proceeding with the on-box scripts"
  fi
}

main() {
  # Self-update: refresh scripts/units, then re-exec the freshly-pulled deploy.sh
  # ONCE so the new logic runs the actual pull+deploy (the guard env prevents a loop).
  if [ -z "${DEPLOY_REFRESHED:-}" ] && [ "${DEPLOY_SKIP_REFRESH:-}" != "1" ]; then
    self_refresh
    exec env DEPLOY_REFRESHED=1 bash "$HERE/deploy.sh" "$@"
  fi
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
  # A swap that boots in smoke can still fail to come up live (pod/dependency, env,
  # disk). Gate on real liveness; if it fails, roll back so we never leave prod down.
  if ! verify_live; then
    log "POST-DEPLOY HEALTH CHECK FAILED for $new"
    if [ -n "$cur" ]; then
      log "rolling back to $cur"
      swap_to "$cur"
      verify_live || log "WARNING: rollback to $cur ALSO failed health check — manual intervention required"
      record_state "$cur" ""
    else
      log "WARNING: no previous tag to roll back to — service may be down, manual intervention required"
    fi
    exit 1
  fi
  record_state "$new" "$cur"
  log "deployed $new"
}
main "$@"
