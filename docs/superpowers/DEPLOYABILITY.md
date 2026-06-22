# PR-Agent self-hosted — deployability checklist

**Date:** 2026-06-22
**Verdict:** Implementation complete and verified to the limits possible without live cloud resources. Ready for the operator to create the GitHub App + Cloudflare bits + Hetzner box (per `docs/runbooks/`) and point it at a repo.

Spec: `docs/superpowers/specs/2026-06-21-pr-agent-deployment-design.md`. Reuse baseline: CodeVibes production branch.

## Spec coverage

| Area | Artifact(s) | Evidence |
|---|---|---|
| Webhook server (github_app) | upstream `docker/Dockerfile --target github_app`, `deploy/quadlet/pr-agent.container` | **Image builds in OrbStack**; **pod smoke: webhook boots + answers 200 on :3000** with our env config |
| DeepSeek v4-pro, env-only config | `pr-agent.container` env + secret→env mappings; WS-A | model flows `config.model`→litellm; env overrides TOML (verified); `custom_model_max_tokens` set (mandatory); no source patch — `patches/apply.sh` is a fail-loud no-op guard (model-config.bats 10/10) |
| Single stateless pod (no volume/backup) | `pragent.pod`, `pr-agent.container`, `pr-agent-cloudflared.container` | quadlet dry-run OK (19→16 units, 0 warn); integration boot asserts no mkfs/volume |
| Tunnel + Access-exempt webhook | `deploy/cloudflared/config.yml.template` (→ :3000), runbooks | quadlet.bats; cloudflare runbook documents Access-EXEMPT webhook + Access-gated broker |
| Secrets broker (shared store) | `secrets-broker/*`, `deploy/fetch-secrets.sh`, `bootstrap-secrets.sh` | worker vitest 3/3; secrets.bats 3/3; multi-line PEM path verified |
| CI sync + build | `.github/workflows/{sync,build}.yml` | actionlint clean; workflows.bats 4/4; builds `--target github_app` → ghcr |
| Deploy / rollback / prune | `deploy/deploy.sh`, deploy/prune timers | deploy.bats 4/4 (deploy/rollback/no-op/failed-smoke); ghcr REST tags; restart container services |
| cloud-init provisioning | `deploy/cloud-init.template.yaml`, `gen-cloud-init.sh` | **full integration boot on fresh OrbStack box: ALL host checks PASS**; renders <32 KiB |
| Runbooks + diagrams | `docs/runbooks/*.{md,html}` + diagrams | runbooks.bats 12/12; self-contained HTML |

## Verified in OrbStack (real Linux, rootless, mirrors Hetzner)
- `github_app` image builds (`localhost/pr-agent:test`).
- Webhook server boots, binds :3000, returns 200 with `CONFIG__MODEL=deepseek-v4-pro` + `CONFIG__CUSTOM_MODEL_MAX_TOKENS` (no crash on the unlisted model).
- Quadlet units dry-run clean.
- **cloud-init integration boot: ALL CHECKS PASS** (ufw, sshd `-T` hardening, fail2ban, user+linger, shallow `production` clone, executable scripts, units + timer, key-copy, stateless invariant).

## Not exercised (needs live cloud)
x86 CI image build (GitHub Actions); live GitHub App webhook delivery + HMAC; real Cloudflare tunnel + Access; real DeepSeek v4-pro review.

## Operator punch-list (do at/before deploy — see `docs/runbooks/`)
1. **`CONFIG__CUSTOM_MODEL_MAX_TOKENS`** — replace placeholder `128000` in `pr-agent.container` with `deepseek-v4-pro`'s real context window (MANDATORY — PR-Agent throws otherwise).
2. **GitHub App** — create it (perms + `pull_request`/`issue_comment` events), webhook `https://pr-agent.tjw.dev/api/v1/github_webhooks` + HMAC secret, private key PEM, App ID; install on target repos.
3. **Cloudflare** — Secrets Store: add the five `pr-agent-*` secrets; deploy the broker Worker (uncomment `[[secrets_store_secrets]]`, fill `store_id`, wrangler ≥4) at `pr-agent-secrets.tjw.dev` (Access service-token gated); create the tunnel, fill `TUNNEL_ID` in `deploy/config.env`; ensure `pr-agent.tjw.dev` is **Access-EXEMPT**.
4. **Hetzner** — CX22 / Ubuntu 26.04 / Falkenstein **with IPv4**; render cloud-init; paste; boot.
5. **ghcr** — after the first CI build, set the `pr-agent` package **public** (anonymous pull).
