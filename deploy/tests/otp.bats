#!/usr/bin/env bats
# gen-cloud-init.sh OTP minting (wrangler mocked; openssl real).
setup() {
  TMP="$(mktemp -d)"; BIN="$TMP/bin"; mkdir -p "$BIN"
  cat > "$BIN/wrangler" <<'EOF'
#!/usr/bin/env bash
echo "wrangler $*" >> "$WLOG"
case "$2 $3" in
  "key put") exit "${WPUT_RC:-0}" ;;
  "key get") echo "${WGET_OUT:-pr-agent}" ;;
esac
exit 0
EOF
  chmod +x "$BIN/wrangler"
  export WLOG="$TMP/wrangler.log"
  cat > "$TMP/vars" <<EOF
CF_SERVICE_TOKEN_ID=tid
CF_SERVICE_TOKEN_SECRET=tsec
FORK_REPO=thejustinwalsh/pr-agent
TUNNEL_ID=00000000-0000-0000-0000-000000000000
OTP_KV_ID=kvid123
SECRETS_NS=pr-agent
EOF
  export WRANGLER="$BIN/wrangler"
  OUT="$TMP/out.yaml"
}
teardown() { rm -rf "$TMP"; }

@test "mints a 64-hex OTP key with 1h TTL and injects SECRETS_OTP" {
  run bash "$BATS_TEST_DIRNAME/../gen-cloud-init.sh" "$TMP/vars" "$OUT"
  [ "$status" -eq 0 ]
  grep -Eq 'wrangler kv key put .* [0-9a-f]{64} pr-agent --ttl 3600' "$WLOG"
  grep -Eq 'SECRETS_OTP=[0-9a-f]{64}' "$OUT"
  ! grep -q '__' "$OUT"
}

@test "mints to REMOTE KV (not local — the deployed broker reads remote)" {
  run bash "$BATS_TEST_DIRNAME/../gen-cloud-init.sh" "$TMP/vars" "$OUT"
  [ "$status" -eq 0 ]
  grep -q 'kv key put .* --remote' "$WLOG"   # put must target remote
  grep -q 'kv key get .* --remote' "$WLOG"   # read-back must target remote
}

@test "fails loud and emits no output when the KV put fails" {
  export WPUT_RC=1
  run bash "$BATS_TEST_DIRNAME/../gen-cloud-init.sh" "$TMP/vars" "$OUT"
  [ "$status" -ne 0 ]
  [ ! -f "$OUT" ]
}

@test "fails when OTP_KV_ID is unset" {
  grep -v '^OTP_KV_ID=' "$TMP/vars" > "$TMP/vars2"
  run bash "$BATS_TEST_DIRNAME/../gen-cloud-init.sh" "$TMP/vars2" "$OUT"
  [ "$status" -ne 0 ]
  [ ! -f "$OUT" ]
}
