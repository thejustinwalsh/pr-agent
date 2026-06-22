#!/usr/bin/env bats
# Deploy/rollback unit tests. External systems (ghcr via curl+jq, podman,
# systemctl) are mocked; we assert the swap/record/rollback/smoke-gate logic.
setup() {
  TMP="$(mktemp -d)"; BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/state"

  # mock curl: ghcr pull-token endpoint + tags/list endpoint. The HTTP-status
  # probe form (-w '%{http_code}') is only reached when DEPLOY_SMOKE_OVERRIDE is
  # unset; the tests pin the override, so it never fires here.
  cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in
  *ghcr.io/token*) echo '{"token":"t"}'; exit 0 ;;
  *tags/list*) echo '{"tags":["v0.36.1","v0.37.0"]}'; exit 0 ;;
esac; done
exit 0
EOF

  # mock jq: minimal — extract .token and list .tags[]?
  cat > "$BIN/jq" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
case "$*" in
  *.token*) echo "t" ;;
  *.tags*) echo "v0.36.1"; echo "v0.37.0" ;;
esac
EOF

  # mock podman: log every call; succeed for everything.
  cat > "$BIN/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$TMP_LOG"
exit 0
EOF

  # mock systemctl: log calls (the user manager isn't present under bats).
  cat > "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$TMP_LOG"
exit 0
EOF

  chmod +x "$BIN/curl" "$BIN/jq" "$BIN/podman" "$BIN/systemctl"
  export PATH="$BIN:$PATH" TMP_LOG="$TMP/calls.log"
  export DEPLOY_STATE_DIR="$TMP/state" DEPLOY_SMOKE_OVERRIDE=pass
}
teardown() { rm -rf "$TMP"; }

@test "deploys newest tag, retags localhost/pr-agent:current, records state" {
  run bash "$BATS_TEST_DIRNAME/../deploy.sh"
  [ "$status" -eq 0 ]
  # newest of v0.36.1 / v0.37.0 is v0.37.0
  grep -q "podman pull ghcr.io/thejustinwalsh/pr-agent:v0.37.0" "$TMP/calls.log"
  grep -q "podman tag ghcr.io/thejustinwalsh/pr-agent:v0.37.0 localhost/pr-agent:current" "$TMP/calls.log"
  grep -q "systemctl --user restart pr-agent.service pr-agent-cloudflared.service" "$TMP/calls.log"
  grep -q "^CURRENT=v0.37.0" "$TMP/state/deploy-state"
}

@test "rollback retargets :current to the previous good tag" {
  printf 'CURRENT=v0.37.0\nPREVIOUS=v0.36.1\n' > "$TMP/state/deploy-state"
  run bash "$BATS_TEST_DIRNAME/../deploy.sh" --rollback
  [ "$status" -eq 0 ]
  grep -q "podman tag ghcr.io/thejustinwalsh/pr-agent:v0.36.1 localhost/pr-agent:current" "$TMP/calls.log"
  grep -q "^CURRENT=v0.36.1" "$TMP/state/deploy-state"
}

@test "no-op when already on the newest tag" {
  printf 'CURRENT=v0.37.0\nPREVIOUS=v0.36.1\n' > "$TMP/state/deploy-state"
  run bash "$BATS_TEST_DIRNAME/../deploy.sh"
  [ "$status" -eq 0 ]
  ! grep -q "podman tag" "$TMP/calls.log"
}

@test "failed smoke test does NOT swap :current and exits non-zero" {
  export DEPLOY_SMOKE_OVERRIDE=fail
  run bash "$BATS_TEST_DIRNAME/../deploy.sh"
  [ "$status" -ne 0 ]
  ! grep -q "podman tag .*localhost/pr-agent:current" "$TMP/calls.log"
  [ ! -f "$TMP/state/deploy-state" ]
}
