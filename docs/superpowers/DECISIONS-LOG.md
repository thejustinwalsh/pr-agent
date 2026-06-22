# Implementation decisions log (append-only)

Decisions made *during* implementation not settled in the design spec. **Append only.** A review agent reconciles this against the spec at the end.

Format: `## YYYY-MM-DD — title` / **Context** / **Decision** / **Affected** / **Revisit**.

---

<!-- Append entries below this line. -->

## 2026-06-21 — Foundational deployment decisions (PR-Agent on Hetzner)
- **Context:** Porting the CodeVibes production deployment to a PR-Agent fork for self-hosted DeepSeek PR reviews.
- **Decisions:**
  - **Upstream/fork:** track `The-PR-Agent/pr-agent` (the gh-resolved active community line; same semver GitHub Releases as `qodo-ai/pr-agent`, v0.37.0 latest). `origin` = `thejustinwalsh/pr-agent`, branch `production`. Revisit if `qodo-ai/pr-agent` is preferred (releases are identical).
  - **Deploy mode:** GitHub-App **webhook server** — `docker/Dockerfile --target github_app` (gunicorn + uvicorn, `pr_agent.servers.github_app:app`), binds **`0.0.0.0:3000`**.
  - **Pod:** single app container (`pr-agent`) + `cloudflared`. **No SPA/Caddy.** PR-Agent is **stateless** → **no data volume, no backup timer** (drop those from the CodeVibes scaffold).
  - **Hostname:** `pr-agent.tjw.dev`, cloudflared ingress → `http://localhost:3000`.
  - **Access:** the webhook hostname is **Access-EXEMPT** (GitHub can't log in) — gated by the GitHub App **webhook HMAC secret** (PR-Agent verifies). The secrets-broker (`secrets.tjw.dev`) stays Access-gated by service token, as before.
  - **Config via env (dynaconf `SECTION__KEY`, no source file needed):** `OPENAI__KEY`=DeepSeek key, `OPENAI__API_BASE`=`https://api.deepseek.com`, `CONFIG__MODEL`=`deepseek-v4-pro`, `CONFIG__CUSTOM_MODEL_MAX_TOKENS`=<v4-pro context window>, `CONFIG__FALLBACK_MODELS`=`["deepseek-v4-flash"]`, `GITHUB__DEPLOYMENT_TYPE`=`app`, `GITHUB__WEBHOOK_SECRET`, `GITHUB_APP__PRIVATE_KEY`, `GITHUB_APP__APP_ID`.
  - **Model:** `deepseek-v4-pro` (reasoning, better reviews) per user; `deepseek-v4-flash` fallback.
  - **Model-forcing patch AUTHORIZED:** PR-Agent is reported to fall back to hardcoded model defaults and skip TOML/config in some flows. WS-A investigates the model-selection path; if env/config doesn't reliably pin the model, add an **asserting codemod** to force `deepseek-v4-pro` + `OPENAI.API_BASE`. Fail-loud on upstream drift.
  - **Secrets (via broker):** `DEEPSEEK_API_KEY`, GitHub App **private key** (PEM), GitHub App **id**, **webhook secret**, **tunnel credential**. (No JWT_SECRET / ENCRYPTION_KEY — PR-Agent doesn't use them. ENCRYPTION_KEY 64-hex lesson is moot here.)
- **Affected:** entire `deploy/`, `secrets-broker/`, `.github/workflows/`, `patches/`, `docs/`.
- **Revisit:** confirm `deepseek-v4-pro` exact model string + context window against DeepSeek's live API; confirm PR-Agent webhook health path for the smoke test.

## 2026-06-21 — WS-A: no model-forcing patch needed; custom_model_max_tokens is MANDATORY
- **Context:** Verify PR-Agent honors DeepSeek model config vs. hardcoding a default.
- **Decision:** PR-Agent resolves model from `config.model` and api_base from `openai.api_base`, forwarding both verbatim to litellm — nothing hardcodes a default in the call path. Dynaconf's `env_loader` gives `CONFIG__MODEL`/`OPENAI__API_BASE` precedence over `configuration.toml` (whose default is `gpt-5.5-2026-04-23`). Verified empirically. So **no source rewrite**; `patches/apply.sh` ships as a fail-loud **no-op asserting codemod** guarding this contract against upstream drift, with `deploy/tests/model-config.bats` (10/10).
- **LOAD-BEARING:** `deepseek-v4-pro` is not in `MAX_TOKENS`; `get_max_tokens()` raises unless `CONFIG__CUSTOM_MODEL_MAX_TOKENS > 0`. So it is **mandatory**. The placeholder `128000` MUST be replaced with v4-pro's real context window before ship (TODO in pr-agent.container).
- **Affected:** `patches/apply.sh`, `deploy/tests/model-config.bats`.
- **Revisit:** confirm deepseek-v4-pro context window (ask user — post-cutoff model).

## 2026-06-21 — WS-C: quadlet/tunnel; render-config POSIX; FALLBACK_MODELS added
- **Context:** Quadlet pod + tunnel for the single stateless container.
- **Decision:** `pragent.pod` + `pr-agent.container` (ContainerName, floating `:current`, env + secret→env mappings, no volume) + `pr-agent-cloudflared.container`; `render-config.sh` rewritten POSIX (`#!/bin/sh`, `set -eu`, `.` not `source`). Orchestrator added `CONFIG__FALLBACK_MODELS=["deepseek-v4-flash"]` (agent omitted it under the strict file list); `custom_model_max_tokens>0` covers both v4-pro and the v4-flash fallback since neither is in MAX_TOKENS.
- **Affected:** `deploy/quadlet/*`, `deploy/cloudflared/config.yml.template`, `deploy/render-config.sh`, `deploy/tests/quadlet.bats`.
- **Revisit:** v4-pro context window (shared with WS-A).

## 2026-06-22 — Build closeout (decisions-log review)
- **WS-D/E/F/G/H/I verified + committed.** Sonnet was overloaded (all 6 first-wave agents 529'd, 0 tokens); re-ran the horde on Opus successfully. No deliverable content affected.
- **node_modules leak fixed:** `git add -A` had committed `secrets-broker/node_modules` (90 MB workerd binary) since the PR-Agent Python `.gitignore` didn't cover it. Untracked + gitignored (`**/node_modules/`); cloud-init clone made shallow (`--depth 1`) so the box never pulls the historical blob. (Full history purge optional; shallow clone sidesteps it.)
- **Integration boot caught an unpushed `production` branch** — cloud-init clones from GitHub, so `production` had to be pushed to the fork. Pushed; re-boot ALL PASS.
- **Verified end-to-end in OrbStack:** image build, webhook 200 smoke, quadlet dry-run, full cloud-init integration boot. See DEPLOYABILITY.md.
- **Residual operator TODOs (in DEPLOYABILITY.md):** set v4-pro `custom_model_max_tokens`; create GitHub App; Cloudflare tunnel + Access-exempt webhook + secrets broker (store_id) + service token; Hetzner CX22 w/ IPv4; ghcr package public after first build; fill `TUNNEL_ID`.
- **No model-forcing source patch needed** (WS-A): env reliably pins the model; `patches/apply.sh` ships as a fail-loud no-op contract guard.
