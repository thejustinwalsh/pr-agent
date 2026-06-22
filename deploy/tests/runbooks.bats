#!/usr/bin/env bats
# WS-H — runbooks: self-contained HTML + required-content guards.
# Must fail before the runbooks are authored AND rendered (render.sh → *.html).
R="${BATS_TEST_DIRNAME}/../../docs/runbooks"

@test "all four runbooks render to self-contained html (inline CSS, no external assets)" {
  for f in github-app cloudflare setup recovery; do
    [ -f "$R/$f.html" ]
    grep -qi "<style" "$R/$f.html"            # inline CSS present
    # No remote stylesheets or remote-loaded images/scripts (diagrams are embedded data: URIs).
    ! grep -qiE 'src="https?://|href="https?://[^"]+\.css' "$R/$f.html"
  done
}

@test "diagrams are embedded, not externally referenced (self-contained)" {
  # pandoc --embed-resources inlines diagrams/*.svg as data: URIs; no relative src= should remain.
  for f in github-app cloudflare setup recovery; do
    ! grep -qiE 'src="diagrams/|src="\./diagrams/' "$R/$f.html"
  done
}

@test "recovery runbook covers rollback, secret re-fetch, and redeploy" {
  grep -qi "rollback" "$R/recovery.html"
  grep -qi "fetch-secrets" "$R/recovery.html"
  grep -qi "redeploy" "$R/recovery.html"
  grep -qi "deploy.sh" "$R/recovery.html"
}

@test "recovery runbook reflects the stateless model (no volume/backup restore)" {
  grep -qi "stateless" "$R/recovery.html"
  grep -qi "deploy-state" "$R/recovery.html"
}

@test "github-app runbook covers the webhook secret and the private key" {
  grep -qi "webhook secret" "$R/github-app.html"
  grep -qi "private key" "$R/github-app.html"
  grep -qi "GITHUB__WEBHOOK_SECRET" "$R/github-app.html"
  grep -qi "GITHUB_APP__PRIVATE_KEY" "$R/github-app.html"
}

@test "github-app runbook uses the real confirmed webhook route" {
  grep -q "/api/v1/github_webhooks" "$R/github-app.html"
}

@test "github-app runbook installs the App on repositories (GitHub App, not OAuth)" {
  grep -qi "Install App" "$R/github-app.html"
  grep -qi "GitHub App" "$R/github-app.html"
}

@test "the webhook hostname is documented as Access-EXEMPT (HMAC-gated)" {
  # Appears in the cloudflare runbook (posture) and the github-app runbook (security note).
  grep -qi "Access-EXEMPT" "$R/cloudflare.html"
  grep -qi "Access-EXEMPT" "$R/github-app.html"
  grep -qi "HMAC" "$R/cloudflare.html"
}

@test "cloudflare runbook keeps the secrets broker Access-gated by a service token" {
  grep -qi "pr-agent-secrets.tjw.dev" "$R/cloudflare.html"
  grep -qi "service token" "$R/cloudflare.html"
}

@test "setup runbook flags the mandatory custom_model_max_tokens for deepseek-v4-pro" {
  grep -qi "CONFIG__CUSTOM_MODEL_MAX_TOKENS" "$R/setup.html"
  grep -qi "deepseek-v4-pro" "$R/setup.html"
}

@test "render.sh exists and is self-contained-html oriented (embed-resources + standalone)" {
  [ -f "$R/render.sh" ]
  grep -q -- "--embed-resources" "$R/render.sh"
  grep -q -- "--standalone" "$R/render.sh"
}

@test "the four excalidraw diagram sources exist and are valid JSON of type excalidraw" {
  for d in topology webhook-flow secrets-fetch deploy-rollback; do
    [ -f "$R/diagrams/$d.excalidraw" ]
    run jq -e '.type == "excalidraw" and (.elements | type == "array")' "$R/diagrams/$d.excalidraw"
    [ "$status" -eq 0 ]
  done
}
