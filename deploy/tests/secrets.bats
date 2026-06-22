#!/usr/bin/env bats
setup() {
  TMP="$(mktemp -d)"; BIN="$TMP/bin"; mkdir -p "$BIN"
  cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$TMP_LOG"
echo '{"DEEPSEEK_API_KEY":"sk-deepseek","GITHUB_APP_PRIVATE_KEY":"-----BEGIN RSA PRIVATE KEY-----\nMIIabc\n-----END RSA PRIVATE KEY-----\n","GITHUB_APP_ID":"123456","GITHUB_WEBHOOK_SECRET":"whsec","TUNNEL_CRED":"{\"TunnelID\":\"x\"}"}'
EOF
  cat > "$BIN/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$TMP_LOG"; exit 0
EOF
  chmod +x "$BIN/curl" "$BIN/podman"
  export PATH="$BIN:$PATH" TMP_LOG="$TMP/calls.log"
  export CF_SERVICE_TOKEN_ID=tid CF_SERVICE_TOKEN_SECRET=tsec
}
teardown() { rm -rf "$TMP"; }

@test "creates a podman secret per app secret" {
  run bash "$BATS_TEST_DIRNAME/../fetch-secrets.sh"
  [ "$status" -eq 0 ]
  grep -q "secret create pr-agent-deepseek-key" "$TMP/calls.log"
  grep -q "secret create pr-agent-github-app-key" "$TMP/calls.log"
  grep -q "secret create pr-agent-github-app-id" "$TMP/calls.log"
  grep -q "secret create pr-agent-webhook-secret" "$TMP/calls.log"
  grep -q "secret create pr-agent-tunnel-cred" "$TMP/calls.log"
}
@test "fetches from the shared broker's path-scoped namespace endpoint" {
  run bash "$BATS_TEST_DIRNAME/../fetch-secrets.sh"
  [ "$status" -eq 0 ]
  grep -q "https://secrets.tjw.dev/secrets/pr-agent" "$TMP/calls.log"
  ! grep -q "pr-agent-secrets.tjw.dev" "$TMP/calls.log"
}
@test "presents the Access service token to the broker" {
  run bash "$BATS_TEST_DIRNAME/../fetch-secrets.sh"
  [ "$status" -eq 0 ]
  grep -q "CF-Access-Client-Id: tid" "$TMP/calls.log"
  grep -q "CF-Access-Client-Secret: tsec" "$TMP/calls.log"
}
@test "does NOT log into ghcr (images are public, anonymous pull)" {
  run bash "$BATS_TEST_DIRNAME/../fetch-secrets.sh"
  [ "$status" -eq 0 ]
  ! grep -q "login ghcr.io" "$TMP/calls.log"
}
@test "fails if the service token is missing (no silent unauth fetch)" {
  unset CF_SERVICE_TOKEN_ID
  run bash "$BATS_TEST_DIRNAME/../fetch-secrets.sh"
  [ "$status" -ne 0 ]
}
