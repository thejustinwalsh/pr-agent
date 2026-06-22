# PR-Agent self-hosted deployment — design (deltas from CodeVibes)

**Date:** 2026-06-21
**Goal:** Run PR-Agent (GitHub-App webhook server) on a Hetzner CX22 behind Cloudflare Tunnel, reviewing PRs with DeepSeek **v4-pro**, with the full CodeVibes ops gauntlet: cloud-init provisioning, Cloudflare-brokered secrets, CI upstream-sync + image build, smoke-tested deploy with rollback, log rotation, integration tests, and runbooks.

**Reuse baseline:** the CodeVibes production branch at `/Users/tjw/Developer/codevibes`. Read its equivalent file before adapting. Most of `deploy/`, `secrets-broker/`, `.github/workflows/`, `Makefile`, `docs/runbooks/`, and the integration test port over with name changes (`codevibes` → `pr-agent`, drop the volume/backup/SPA/Caddy bits).

## Architecture (vs CodeVibes)

| Aspect | CodeVibes | PR-Agent (this) |
|---|---|---|
| App | Vite SPA + Express + SQLite | PR-Agent webhook server (Python, FastAPI/gunicorn) |
| Containers in pod | caddy + backend + cloudflared | **pr-agent + cloudflared** (no caddy/SPA) |
| State | SQLite on detachable volume | **stateless** → no volume, no backup |
| Image | 2 images we build | build **`docker/Dockerfile --target github_app`** from the fork → ghcr |
| Inbound | app behind Access | webhook **Access-EXEMPT**, HMAC-gated |
| Port | caddy:80 → backend:3001 | cloudflared → **pr-agent:3000** |
| App config | env + DB | env-only (dynaconf `SECTION__KEY`) |
| Source edits | codemod (API base, CORS) | codemod **only if** model not pinned (force `deepseek-v4-pro`) |

## Secrets (via the broker, env-injected into the container)
`DEEPSEEK_API_KEY` → `OPENAI__KEY`; GitHub App **PEM** → `GITHUB_APP__PRIVATE_KEY`; App **id** → `GITHUB_APP__APP_ID`; **webhook secret** → `GITHUB__WEBHOOK_SECRET`; **tunnel cred** → cloudflared mount. Static env (non-secret, in quadlet): `OPENAI__API_BASE=https://api.deepseek.com`, `CONFIG__MODEL=deepseek-v4-pro`, `CONFIG__CUSTOM_MODEL_MAX_TOKENS=<ctx>`, `CONFIG__FALLBACK_MODELS=["deepseek-v4-flash"]`, `GITHUB__DEPLOYMENT_TYPE=app`.

## Carry-over cloud-init/deploy lessons (non-negotiable — all bit us in CodeVibes)
`ufw allow 22/tcp` (never `--force` on allow/default); `users: [- default, …]`; sshd hardening via `write_files` drop-in `/etc/ssh/sshd_config.d/00-pragent.conf` (`PermitRootLogin prohibit-password`, `PasswordAuthentication no`); install `openssh-server`; fail2ban; scripts committed **+x** + cloud-init `chmod +x` safety net; Quadlet `ContainerName=`; `deploy.sh` restarts **container services** not the pod; ghcr tag listing via REST API (curl+jq, no skopeo); webhook smoke must pass on first boot.

## Workstreams (horde — adapt the CodeVibes equivalent + this doc)

- **A — Patch/model-forcing.** Investigate PR-Agent's model selection (`pr_agent/algo/ai_handlers/`, `config_loader`, defaults). If env (`CONFIG__MODEL`/`OPENAI__API_BASE`) reliably pins `deepseek-v4-pro` against the DeepSeek endpoint → no patch (assert via a config/unit test). If hardcoded defaults win → `patches/apply.sh` asserting codemod to force `deepseek-v4-pro` + `OPENAI.API_BASE`. Verify with bats on a fixture.
- **B — Image build.** No new Dockerfile; CI builds the fork's `docker/Dockerfile --target github_app`. Add a tiny `deploy/tests/containers.bats` asserting the target exists + (optionally) hadolint on the upstream Dockerfile is informational only (it's theirs).
- **C — Quadlet.** `deploy/config.env` (names `pr-agent-*`, `IMAGE=ghcr.io/thejustinwalsh/pr-agent`, `APP_DOMAIN=pr-agent.tjw.dev`, `TUNNEL_ID=…`). `codevibes.pod`→`pragent.pod`; one `pr-agent.container` (Image `localhost/pr-agent:current`, `ContainerName=pr-agent`, the static env above, `Secret=…,type=env,target=OPENAI__KEY` etc., no volume); `pr-agent-cloudflared.container`. cloudflared `config.yml.template` ingress `pr-agent.tjw.dev → http://localhost:3000`. quadlet.bats.
- **D — Deploy/prune.** Adapt `deploy.sh`: ghcr-API tag listing; smoke = boot candidate image, poll webhook on `:3000` (GET `/` or PR-Agent's root route — confirm a 200/known response; container must stay up); swap `localhost/pr-agent:current`; restart `pr-agent.service` + `pr-agent-cloudflared.service`; record state (state dir `/var/lib/pr-agent` or similar — no volume). Weekly image prune timer + daily deploy timer (04:00 ET). **No backup** (stateless). deploy.bats with mocked curl/jq/podman.
- **E — Secrets.** Adapt broker Worker (`secrets-broker/src/index.ts`): secrets = `DEEPSEEK_API_KEY, GITHUB_APP_PRIVATE_KEY, GITHUB_APP_ID, GITHUB_WEBHOOK_SECRET, TUNNEL_CRED`. `fetch-secrets.sh` creates podman secrets (`pr-agent-*`); map to env targets in quadlet. `bootstrap-secrets.sh` fallback. wrangler.toml + vitest (stubs in vitest config, NOT `[vars]`).
- **F — cloud-init.** Adapt `cloud-init.template.yaml`: all carry-over lessons; **drop volume mount**; clone fork `production`; install quadlet units + timers; render config; fetch secrets; deploy. `gen-cloud-init.sh` + vars.example (`<32KiB`).
- **G — CI.** `sync.yml` tracks `The-PR-Agent/pr-agent` releases → merges tag into `production` → fork release. `build.yml` on release: run `patches/apply.sh` (if any), build `docker/Dockerfile --target github_app` → `ghcr.io/thejustinwalsh/pr-agent:<tag>`+`latest` (public). actionlint.
- **H — Runbooks (self-contained HTML) + diagrams.** `github-app.html` (create GitHub App: PR/contents/issues/checks perms, webhook URL `https://pr-agent.tjw.dev/api/v1/github_webhooks` or PR-Agent's path — confirm in `github_app.py`, webhook secret, private key, install on repos), `cloudflare.html` (tunnel + **Access-exempt** webhook hostname + secrets broker + service token), `setup.html` (Hetzner + cloud-init + first webhook delivery test), `recovery.html`. Excalidraw diagrams.
- **I — Integration + deployability.** `deploy/tests/cloud-init-integration.sh` (boot OrbStack machine, assert host state incl. executable scripts, no volume); local pod smoke (webhook up on :3000); `make verify` + `verify-cloudinit`; `DEPLOYABILITY.md` mapping each requirement to artifact+test.

## Definition of done
Fresh Hetzner box from cloud-init → pr-agent + cloudflared up → tunnel registered → GitHub App webhook delivers to `pr-agent.tjw.dev` (HMAC-verified, Access-exempt) → opening a PR on an installed repo yields a DeepSeek **v4-pro** review. CI auto-syncs upstream releases and redeploys with rollback.
