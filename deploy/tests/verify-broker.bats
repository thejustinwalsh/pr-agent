#!/usr/bin/env bats
# verify-broker.sh: end-to-end broker check (curl + wrangler mocked).
setup() {
  TMP="$(mktemp -d)"; BIN="$TMP/bin"; mkdir -p "$BIN"
  # curl mock: the replay call carries -w (code only) and returns a status code;
  # the first call returns the JSON bundle.
  cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
if printf '%s ' "$@" | grep -q -- ' -w '; then
  echo "${CURL_REPLAY_CODE:-410}"
else
  printf '%s' "${CURL_BODY:-{\"DEEPSEEK_API_KEY\":\"d\",\"GITHUB_APP_ID\":\"1\",\"GITHUB_APP_PRIVATE_KEY\":\"k\",\"GITHUB_WEBHOOK_SECRET\":\"w\",\"TUNNEL_CRED\":\"t\"}}"
fi
EOF
  cat > "$BIN/wrangler" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$BIN/curl" "$BIN/wrangler"
  export PATH="$BIN:$PATH" WRANGLER="$BIN/wrangler"
  export CF_VARS="$TMP/no-cloud-init.vars"   # hermetic: ignore any real cloud-init.vars
  export CF_SERVICE_TOKEN_ID=tid CF_SERVICE_TOKEN_SECRET=tsec
}
teardown() { rm -rf "$TMP"; }

@test "passes: 200 + five keys present, replay returns 410" {
  run bash "$BATS_TEST_DIRNAME/../verify-broker.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "mints the OTP into REMOTE KV" {
  # capture wrangler args
  cat > "$BIN/wrangler" <<'EOF'
#!/usr/bin/env bash
echo "wrangler $*" >> "$WLOG"; exit 0
EOF
  chmod +x "$BIN/wrangler"; export WLOG="$TMP/w.log"
  run bash "$BATS_TEST_DIRNAME/../verify-broker.sh"
  [ "$status" -eq 0 ]
  grep -q 'kv key put .* --remote' "$WLOG"
}

@test "fails when a key is missing from the bundle" {
  export CURL_BODY='{"DEEPSEEK_API_KEY":"d","GITHUB_APP_ID":"1"}'
  run bash "$BATS_TEST_DIRNAME/../verify-broker.sh"
  [ "$status" -ne 0 ]
}

@test "fails when the replay is not rejected (consume-once broken)" {
  export CURL_REPLAY_CODE=200
  run bash "$BATS_TEST_DIRNAME/../verify-broker.sh"
  [ "$status" -ne 0 ]
}

@test "fails when the service token is missing" {
  unset CF_SERVICE_TOKEN_ID
  run bash "$BATS_TEST_DIRNAME/../verify-broker.sh"
  [ "$status" -ne 0 ]
}
