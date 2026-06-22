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
