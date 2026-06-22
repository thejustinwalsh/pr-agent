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

## 2026-06-22 — deepseek-v4-pro context window confirmed
- **Context:** `CONFIG__CUSTOM_MODEL_MAX_TOKENS` was a placeholder (`128000`); it is mandatory (PR-Agent throws for models absent from MAX_TOKENS).
- **Decision:** User confirmed deepseek-v4-pro = **1M context length, 384K max output**. Set `CONFIG__CUSTOM_MODEL_MAX_TOKENS=1000000` (PR-Agent's max_tokens = context window; the 384K output ceiling is governed by PR-Agent's own output-budget config, not this value).
- **Affected:** `deploy/quadlet/pr-agent.container`.
- **Revisit:** none — the one mandatory operator value is now set.

## 2026-06-22 — secrets-broker consolidation: shared, path-scoped broker on secrets.tjw.dev
- **Context:** The design shipped a *second* broker Worker at `pr-agent-secrets.tjw.dev` binding the shared account Secrets Store. User direction: retire the per-project broker (and the dying CodeVibes repo); `secrets.tjw.dev` becomes the single shared broker, redeployed from THIS repo, extensible per namespace/path.
- **Decision:** `secrets-broker/` is now the canonical source of `secrets.tjw.dev`. The Worker is **path-scoped per namespace** via a `BUNDLES` registry — `GET /secrets/<project>` returns only that project's keys; a bundle never sees another namespace's secrets; bare `/secrets`, unknown namespaces, and other paths all 404; missing Access assertion → 401. Today the only namespace is `pr-agent` (5 keys). Adding a project = one `BUNDLES` entry + its `<project>-*` store bindings (distinct binding names).
- **CodeVibes:** deployment retired; no codevibes bundle shipped (would otherwise need codevibes-* bindings to keep resolving). Registry makes re-adding it trivial if that changes.
- **Consumer:** `deploy/config.env` → `SECRETS_DOMAIN=secrets.tjw.dev` + `SECRETS_NS=pr-agent`; `fetch-secrets.sh` fetches `https://$SECRETS_DOMAIN/secrets/$SECRETS_NS` (jq keys unchanged — bare `DEEPSEEK_API_KEY` etc.).
- **Toolchain:** Secrets Store bindings (`[[secrets_store_secrets]]`) are GA-only — **wrangler 3 silently drops them** (`No bindings found` → broker 500s in prod). Pinned `wrangler@^4`, `@cloudflare/vitest-pool-workers@^0.8`, `vitest@~3.2`. The v4 pool emulates a real (empty) Secrets Store that shadows string stubs, so tests load a `wrangler.test.toml` (no `secrets_store_secrets`) and stub the 5 keys in `vitest.config.ts`. `wrangler.toml` carries the live `store_id` (a82a5843…) + active bindings; route = `secrets.tjw.dev`.
- **Access:** gates the hostname, not the path — one service-token policy on `secrets.tjw.dev` covers every namespace.
- **Evidence:** worker vitest 6/6 (namespace isolation, 401, 404s); `secrets.bats` 5/5 (asserts the `/secrets/pr-agent` URL + service-token headers, rejects the dead host); `wrangler deploy --dry-run` (v4) binds all five Secrets Store secrets; eslint clean.
- **Diagrams:** `secrets-fetch`/`topology` (svg + excalidraw) updated to `secrets.tjw.dev` + `GET /secrets/pr-agent`. The `.png` exports are stale (orphans; runbooks embed the SVGs) — regenerate via excalidraw if ever needed.
- **Affected:** `secrets-broker/{src/index.ts,wrangler.toml,wrangler.test.toml,vitest.config.ts,test/index.test.ts,package.json,package-lock.json}`, `deploy/config.env`, `deploy/fetch-secrets.sh`, `deploy/tests/{secrets,runbooks}.bats`, `docs/runbooks/{cloudflare,setup}.md` (+ rendered html), `docs/runbooks/diagrams/*`, `docs/superpowers/{DEPLOYABILITY.md,specs/2026-06-21-pr-agent-deployment-design.md}`.
- **Revisit:** if CodeVibes (or another project) needs serving again, add its bundle + bindings; consider whether `secrets.tjw.dev` should move to its own infra repo rather than living under pr-agent.

## 2026-06-22 — OTP single-use hardening for the boot-time secrets fetch
- **Context:** A leaked Access service token could re-pull secrets indefinitely. `fetch-secrets.sh` runs once at provision (cloud-init) and on deliberate operator rotation — never per boot (podman secrets persist) — so a single-use credential carries no per-boot bricking risk.
- **Decision:** Per-provision OTP minted by `gen-cloud-init.sh` (`wrangler kv key put sha256(otp)→namespace --ttl 3600`, read-back verified), injected to `/etc/pr-agent/otp.env` (0600), sent by `fetch-secrets.sh` as `X-Secrets-OTP` (single attempt; file deleted on success), consumed once by the broker over Workers KV. Layered on the Access service-token gate (both required).
- **Adversarial review (5-agent Sonnet horde) hardening folded in:** pinned SHA-256 recipe both sides (lowercase, `sed 's/^.*= *//'` not `awk`); uniform 410 for all OTP failures; fail-closed (500) on missing binding / KV get / delete error; OTP format `^[0-9a-f]{64}$`; own 0600 file deleted post-fetch; `workers_dev=false` to close the `*.workers.dev` Access-bypass route; atomic tempfile+`mv`+`trap` mint; recovery rotation one-liner; `bootstrap-secrets.sh` documented OTP-exempt.
- **KV not Durable Object:** KV is CLI-mintable (no admin endpoint). The non-atomic consume is best-effort, not a secret-theft vector for a single provisioning consumer (a replay returns the same bundle). DO is the documented upgrade path if the broker ever serves concurrent consumers.
- **Evidence:** broker vitest 8/8 (round-trip hash, replay→410, malformed→410, wrong-ns→410, no-Access→401, no-binding→500); secrets.bats 8/8 (OTP header sent, otp.env deleted, fail-if-unset); otp.bats 3/3 (mint + fail-loud + guard); cloudinit.bats green (mock wrangler; corrected a pre-existing stale `--depth 1` clone assertion); runbooks.bats 13/13; shellcheck clean; wrangler 4 dry-run lists the OTP_KV binding.
- **Spec/plan:** `docs/superpowers/specs/2026-06-22-otp-single-use-secrets-fetch-design.md`, `docs/superpowers/plans/2026-06-22-otp-single-use-secrets-fetch.md`.
- **Operator (pre-deploy):** `wrangler kv namespace create OTP_KV`; set the id in `secrets-broker/wrangler.toml` and `deploy/cloud-init.vars`; redeploy the broker; then provision. Integration tier (`make verify-cloudinit`) on the OrbStack box (required after the cloud-init change; not runnable from macOS).
- **Revisit:** Durable Object if multi-consumer; optional Access-JWT JWKS verification; optional CF rate-limit rule on secrets.tjw.dev.

## 2026-06-22 — GitHub App PEM stored as single-line base64
- **Context:** The Cloudflare Secrets Store dashboard value field is single-line and collapses newlines, mangling the multi-line GitHub App private-key PEM on paste. The earlier "paste verbatim with real newlines" guidance only worked via the CLI, not the dashboard the runbook directs operators to.
- **Decision:** Store `pr-agent-github-app-key` as **single-line base64** (`openssl base64 -A -in key.pem`) — dashboard-safe and JSON-safe through the broker's pass-through. `fetch-secrets.sh` decodes just that key (`put ... base64` → `openssl base64 -d -A`) back to the raw multi-line PEM before `podman secret create`. The broker is unchanged (still a dumb pass-through; consume-once logic untouched). `bootstrap-secrets.sh` is unaffected (reads the raw `.pem` file) — both paths yield an identical real-newline PEM in the container.
- **Evidence:** secrets.bats 10/10 (base64 PEM decoded to multi-line before store; non-PEM secrets stored verbatim); shellcheck clean.
- **Affected:** `deploy/fetch-secrets.sh`, `deploy/tests/secrets.bats`, `docs/runbooks/{github-app,cloudflare}.{md,html}`.

## 2026-06-22 — GitHub App PEM is a Worker secret, not a Secrets Store secret
- **Context:** The Cloudflare Secrets Store caps a secret **value at 1024 chars**. A base64 RSA-2048 GitHub App PEM is ~2272 chars (raw PEM ~1704), so it does not fit — base64 alone (the prior fix) did not solve it.
- **Decision:** Store `GITHUB_APP_PRIVATE_KEY` as a **Worker secret** on the broker (`wrangler secret put`, ~5 KB limit), still base64-encoded. The broker reads it as a plain string binding — `resolve()` already handles `string | SecretsStoreSecret`, so **no broker code change**. The other four small secrets stay in the Secrets Store. `fetch-secrets.sh` is unchanged (still base64-decodes that key).
- **Ordering:** `wrangler secret put` requires the Worker to exist, so it runs **after** `wrangler deploy` (runbook Step 13a). The four Store secrets must exist **before** deploy (they're `secrets_store_secrets` bindings).
- **Evidence:** broker vitest 8/8 (PEM stubbed as a string binding — exactly the Worker-secret shape); wrangler 4 dry-run lists 4 Store secrets + OTP_KV, PEM absent (runtime Worker secret); secrets.bats 10/10 unchanged.
- **Affected:** `secrets-broker/{wrangler.toml,src/index.ts (comment only)}`, `docs/runbooks/{cloudflare,github-app,setup}.{md,html}`.

## 2026-06-22 — All broker secrets are Worker secrets (one uniform mechanism)
- **Supersedes** the two prior entries (base64-in-Secrets-Store; PEM-only-as-Worker-secret). Those left a split/mixed model — bad DX.
- **Context:** The Secrets Store value cap is 1024 chars; a base64 RSA-2048 GitHub App PEM is ~2.2 KB and is incompressible (random key material — gzip/xz make it *bigger*). So the PEM can never live in the Store, forcing either a mixed model or a second mechanism.
- **Decision:** Store **all five** `pr-agent` secrets as Cloudflare **Worker secrets** on the broker (no size cap, encrypted at rest, write-only), set in one shot by `deploy/set-broker-secrets.sh` (`wrangler secret put`, piped so values never hit shell history/`ps`). `wrangler.toml` declares **zero** `secrets_store_secrets` (only the `OTP_KV` binding remains). The broker reads each as a plain string — `resolve()` already handles `string | SecretsStoreSecret`, so **no broker code change**. `fetch-secrets.sh` unchanged (still base64-decodes the PEM).
- **Why this is fine for cloud-init:** the broker is a serverless Cloudflare *edge* Worker, always on — not the podman container and not something started at boot. The box's first-boot fetch is byte-identical; where the broker sources its values is invisible to it. No circular dependency.
- **DX:** fill `deploy/broker-secrets.vars` (3 inline values single-quoted; tunnel-cred + PEM as file paths so JSON/newlines aren't shell-mangled), run one script, re-runnable for rotation. No dashboard, no 1024 cap, no mixed model.
- **Ordering:** `wrangler secret put` needs the Worker deployed, so Step 13a runs after Step 13 (deploy). Worker secrets aren't declared in `wrangler.toml`, so deploy doesn't depend on them existing.
- **Evidence:** broker vitest 8/8; wrangler 4 dry-run lists only `OTP_KV` (no Store bindings); broker-secrets.bats 4/4 (5 secrets set, PEM base64 round-trips, structured values from files verbatim, fail-loud on missing value); secrets.bats 10/10; shellcheck clean.
- **Affected:** `secrets-broker/{wrangler.toml,src/index.ts}`, `deploy/{set-broker-secrets.sh,broker-secrets.vars.example,tests/broker-secrets.bats}`, `.gitignore`, `docs/runbooks/{cloudflare,github-app,setup}.{md,html}`.

## 2026-06-22 — Hands-off pipeline: sync→build dispatch + draft-PR codemod
- **sync→build:** `sync-upstream` now dispatches `build-image` via `gh workflow run` after a successful merge (sets `actions: write`, guards on `synced=true`). `workflow_dispatch` IS triggerable by `GITHUB_TOKEN`, so this closes the recursion-guard gap that left releases-created-by-token from auto-building. Result: sync merges upstream → image builds → the box's daily `pr-agent-deploy.timer` pulls it (smoke-gated). Fully hands-off.
- **Draft PRs:** upstream documents `github_app.feedback_on_draft_pr` but never wired it (the draft gate in `should_process_pr_logic` is hardcoded, even at v0.37.0). Added a build-time codemod in `patches/apply.sh` that rewrites `github_app.py:387` to honor the setting and adds the `feedback_on_draft_pr = false` default to `configuration.toml` — idempotent, fail-loud on drift. Enabled in the quadlet (`GITHUB_APP__FEEDBACK_ON_DRAFT_PR=true`). Manual `/review` on drafts already worked; this makes auto-feedback work too.
- **Evidence:** model-config.bats 12/12 (codemod applies to a copy, patches the gate, idempotent, fails loud on draft-gate drift); workflows.bats 5/5; shellcheck + actionlint clean; patched github_app.py parses as valid Python; tests never mutate the committed tree.
- **Note:** the premature `v0.37.0` tag/image (built from 0.36.1) must be cleared so the real v0.37.0 build deploys (box compares tag strings).
- **Affected:** `.github/workflows/sync.yml`, `patches/apply.sh`, `deploy/quadlet/pr-agent.container`, `deploy/tests/{model-config,workflows}.bats`.
