#!/usr/bin/env bats
# set-broker-secrets.sh: set all five pr-agent secrets as Cloudflare Worker
# secrets on the broker in one shot (wrangler mocked; openssl real).
setup() {
  TMP="$(mktemp -d)"; BIN="$TMP/bin"; mkdir -p "$BIN"
  # Mock wrangler: record args, and capture the piped value for `secret put <NAME>`.
  cat > "$BIN/wrangler" <<'EOF'
#!/usr/bin/env bash
echo "wrangler $*" >> "$WLOG"
if [ "$1 $2" = "secret put" ]; then cat > "$WDIR/secret-$3"; fi
exit 0
EOF
  chmod +x "$BIN/wrangler"
  export WLOG="$TMP/wrangler.log" WDIR="$TMP" WRANGLER="$BIN/wrangler" BROKER_DIR="$TMP"
  printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIfake\n-----END RSA PRIVATE KEY-----\n' > "$TMP/key.pem"
  printf '%s' '{"AccountTag":"a","TunnelID":"x","TunnelSecret":"s"}' > "$TMP/tunnel.json"
  cat > "$TMP/vars" <<EOF
DEEPSEEK_API_KEY='sk-test'
GITHUB_APP_ID=1234567
GITHUB_WEBHOOK_SECRET='whsec-test'
TUNNEL_CRED_FILE=$TMP/tunnel.json
GITHUB_APP_PRIVATE_KEY_FILE=$TMP/key.pem
EOF
}
teardown() { rm -rf "$TMP"; }

@test "sets all five broker secrets via wrangler secret put" {
  run bash "$BATS_TEST_DIRNAME/../set-broker-secrets.sh" "$TMP/vars"
  [ "$status" -eq 0 ]
  for n in DEEPSEEK_API_KEY GITHUB_APP_ID GITHUB_WEBHOOK_SECRET TUNNEL_CRED GITHUB_APP_PRIVATE_KEY; do
    grep -q "secret put $n" "$WLOG"
  done
}

@test "stores the small secrets verbatim" {
  run bash "$BATS_TEST_DIRNAME/../set-broker-secrets.sh" "$TMP/vars"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/secret-DEEPSEEK_API_KEY")" = "sk-test" ]
  [ "$(cat "$TMP/secret-GITHUB_APP_ID")" = "1234567" ]
  diff "$TMP/secret-TUNNEL_CRED" "$TMP/tunnel.json"   # JSON verbatim from file
}

@test "base64-encodes the PEM (single line) so it round-trips to the original" {
  run bash "$BATS_TEST_DIRNAME/../set-broker-secrets.sh" "$TMP/vars"
  [ "$status" -eq 0 ]
  stored="$(cat "$TMP/secret-GITHUB_APP_PRIVATE_KEY")"
  [ "$(printf '%s' "$stored" | wc -l)" -eq 0 ]                          # single line, no newline
  diff <(printf '%s' "$stored" | openssl base64 -d -A) "$TMP/key.pem"   # decodes to the PEM
}

@test "fails loudly if a required value is missing" {
  grep -v '^DEEPSEEK_API_KEY=' "$TMP/vars" > "$TMP/vars2"
  run bash "$BATS_TEST_DIRNAME/../set-broker-secrets.sh" "$TMP/vars2"
  [ "$status" -ne 0 ]
}
