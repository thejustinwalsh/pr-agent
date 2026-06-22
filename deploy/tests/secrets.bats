#!/usr/bin/env bats
setup() {
  TMP="$(mktemp -d)"; BIN="$TMP/bin"; mkdir -p "$BIN"
  # GITHUB_APP_PRIVATE_KEY arrives base64-encoded (single-line, dashboard-safe);
  # the value below decodes to a multi-line "-----BEGIN RSA PRIVATE KEY-----…" PEM.
  cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$TMP_LOG"
echo '{"DEEPSEEK_API_KEY":"sk-deepseek","GITHUB_APP_PRIVATE_KEY":"LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQpNSUlBQkNERUYKR0hJSktMCi0tLS0tRU5EIFJTQSBQUklWQVRFIEtFWS0tLS0tCg==","GITHUB_APP_ID":"123456","GITHUB_WEBHOOK_SECRET":"whsec","TUNNEL_CRED":"{\"TunnelID\":\"x\"}"}'
EOF
  # Capture the value piped to `podman secret create <name> -` for assertions.
  cat > "$BIN/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$TMP_LOG"
if [ "$1 $2" = "secret create" ]; then cat > "${TMP_LOG%/*}/secret-$3"; fi
exit 0
EOF
  chmod +x "$BIN/curl" "$BIN/podman"
  export PATH="$BIN:$PATH" TMP_LOG="$TMP/calls.log"
  export CF_SERVICE_TOKEN_ID=tid CF_SERVICE_TOKEN_SECRET=tsec
  # Single-use OTP supplied via env by default; OTP_ENV points nowhere so the
  # script uses the env value. Individual tests override these.
  export SECRETS_OTP=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  export OTP_ENV="$TMP/nonexistent-otp.env"
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
@test "decodes the base64 GitHub App PEM to a real multi-line key before storing" {
  run bash "$BATS_TEST_DIRNAME/../fetch-secrets.sh"
  [ "$status" -eq 0 ]
  f="$TMP/secret-pr-agent-github-app-key"
  grep -q "BEGIN RSA PRIVATE KEY" "$f"   # decoded, not base64
  [ "$(wc -l < "$f")" -ge 2 ]            # multi-line => real newlines
  ! grep -q "LS0tLS" "$f"                # not the raw base64 string
}
@test "stores non-PEM secrets verbatim (no base64 decode)" {
  run bash "$BATS_TEST_DIRNAME/../fetch-secrets.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/secret-pr-agent-deepseek-key")" = "sk-deepseek" ]
  [ "$(cat "$TMP/secret-pr-agent-github-app-id")" = "123456" ]
}
@test "sends the single-use OTP header to the broker" {
  run bash "$BATS_TEST_DIRNAME/../fetch-secrets.sh"
  [ "$status" -eq 0 ]
  grep -q "X-Secrets-OTP: $SECRETS_OTP" "$TMP/calls.log"
}
@test "deletes otp.env after a successful fetch" {
  unset SECRETS_OTP
  printf 'SECRETS_OTP=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n' > "$TMP/otp.env"
  export OTP_ENV="$TMP/otp.env"
  run bash "$BATS_TEST_DIRNAME/../fetch-secrets.sh"
  [ "$status" -eq 0 ]
  [ ! -f "$TMP/otp.env" ]
}
@test "fails if the OTP is missing (no silent unauth fetch)" {
  unset SECRETS_OTP
  run bash "$BATS_TEST_DIRNAME/../fetch-secrets.sh"
  [ "$status" -ne 0 ]
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
