#!/usr/bin/env bats
Q="${BATS_TEST_DIRNAME}/../quadlet"

@test "pod defines no published host ports (tunnel dials out)" {
  ! grep -Rq "PublishPort" "$Q"
}
@test "pod is named pr-agent and wanted by default.target" {
  grep -q "PodName=pr-agent" "$Q/pragent.pod"
  grep -q "WantedBy=default.target" "$Q/pragent.pod"
}
@test "pr-agent container references the floating :current image" {
  grep -q "Image=localhost/pr-agent:current" "$Q/pr-agent.container"
}
@test "pr-agent container names the container and joins the pod" {
  grep -q "ContainerName=pr-agent" "$Q/pr-agent.container"
  grep -q "Pod=pragent.pod" "$Q/pr-agent.container"
}
@test "pr-agent container is stateless (no volume)" {
  ! grep -q "Volume=" "$Q/pr-agent.container"
}
@test "pr-agent container sets the static DeepSeek/GitHub-App env" {
  grep -q "Environment=OPENAI__API_BASE=https://api.deepseek.com" "$Q/pr-agent.container"
  grep -q "Environment=CONFIG__MODEL=deepseek-v4-pro" "$Q/pr-agent.container"
  grep -q "Environment=CONFIG__CUSTOM_MODEL_MAX_TOKENS=" "$Q/pr-agent.container"
  grep -q "Environment=GITHUB__DEPLOYMENT_TYPE=app" "$Q/pr-agent.container"
}
@test "pr-agent container maps every podman secret to its env target" {
  grep -q "Secret=pr-agent-deepseek-key,type=env,target=OPENAI__KEY" "$Q/pr-agent.container"
  grep -q "Secret=pr-agent-github-app-key,type=env,target=GITHUB_APP__PRIVATE_KEY" "$Q/pr-agent.container"
  grep -q "Secret=pr-agent-github-app-id,type=env,target=GITHUB_APP__APP_ID" "$Q/pr-agent.container"
  grep -q "Secret=pr-agent-webhook-secret,type=env,target=GITHUB__WEBHOOK_SECRET" "$Q/pr-agent.container"
}
@test "cloudflared mounts the rendered config and tunnel cred, runs the tunnel" {
  C="$Q/pr-agent-cloudflared.container"
  grep -q "Volume=%h/pr-agent/deploy/cloudflared/config.yml:/etc/cloudflared/config.yml:ro,Z" "$C"
  grep -q "Secret=pr-agent-tunnel-cred,type=mount,target=/etc/cloudflared/cred.json" "$C"
  grep -q "Exec=tunnel --no-autoupdate --config /etc/cloudflared/config.yml run" "$C"
}
@test "cloudflared config template routes pr-agent.tjw.dev to :3000 with a 404 fallback" {
  T="${BATS_TEST_DIRNAME}/../cloudflared/config.yml.template"
  grep -q "hostname: pr-agent.tjw.dev" "$T"
  grep -q "service: http://localhost:3000" "$T"
  grep -q "http_status:404" "$T"
}
@test "quadlet dry-run accepts the unit set" {
  QUADLET=$(command -v quadlet || echo /usr/libexec/podman/quadlet)
  [ -x "$QUADLET" ] || skip "quadlet not installed (Linux/OrbStack only)"
  run env QUADLET_UNIT_DIRS="$Q" "$QUADLET" -dryrun -user
  [ "$status" -eq 0 ]
}
