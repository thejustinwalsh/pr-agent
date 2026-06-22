# OTP single-use hardening for the boot-time secrets fetch

**Date:** 2026-06-22
**Status:** Approved (design); revised after adversarial security review (5-agent horde); pending implementation plan.
**Related:** [[2026-06-21-pr-agent-deployment-design]], DECISIONS-LOG `secrets-broker-consolidation`.

## Goal

Make the credential the Hetzner box uses to pull its secrets at provisioning **single-use**. After the box fetches its bundle once during cloud-init, the credential must not work again — without a freshly minted one-time password (OTP). This is replay-protection on the *fetch channel*, layered on top of the existing Cloudflare Access service-token gate.

## Security framing (honest statement of the guarantee)

This is **defense in depth**: a successful fetch requires **both** a valid Cloudflare Access service token **and** a live, unused OTP. The OTP raises the bar so a leaked service token alone cannot re-pull secrets. The consume-once property is enforced **best-effort** over Workers KV, which is eventually consistent — under concurrent requests a replay window of up to ~60s exists (see "KV vs Durable Object" below). For the actual deployment shape (a single provisioning consumer, one OTP minted just before one boot) this is not a secret-theft vector: a replay returns the *same* bundle, and any party holding the OTP already had on-box/user-data access. A Durable Object is the upgrade path to strict atomicity if the broker ever serves concurrent consumers.

## Threat model

**In scope:**
- A leaked/exfiltrated service token alone can no longer re-pull secrets — it also needs a live, unused OTP.
- A captured OTP cannot be replayed: once consumed (or after a 1h TTL) it is dead.
- A captured OTP for one namespace cannot fetch another namespace's bundle.

**Explicitly out of scope (non-goals):**
- Protecting secrets **at rest on the box**. After the fetch, the plaintext secrets live in podman secrets and the container env. A full box compromise leaks them regardless; the OTP does not change that.
- Protecting against an attacker who controls provisioning (they mint their own OTP).
- Per-secret or per-request rotation beyond provisioning. `fetch-secrets.sh` runs **once at first boot** (cloud-init `runcmd`) and on deliberate operator rotation/recovery — never per reboot, never per deploy. podman secrets persist; `deploy.sh` only swaps the image tag and restarts services.

## Why provision-time only (load-bearing fact)

`fetch-secrets.sh` is invoked in exactly one automated place: `deploy/cloud-init.template.yaml` `runcmd` at first boot. `deploy.sh` does not call it. podman secrets persist across reboots and redeploys. Therefore the OTP is a **one-shot provisioning credential**, and a strictly single-use OTP carries no per-boot bricking risk: the only re-fetches are deliberate operator actions (rotation, recovery, new machine), each of which re-runs the generator and mints a fresh OTP.

## Architecture

One new piece of state: a Cloudflare **Workers KV** namespace, `OTP_KV`, bound to the broker Worker. It holds, per outstanding OTP, a single entry:

- **key:** `sha256_hex(otp)` — the raw OTP is never stored.
- **value:** the namespace the OTP is scoped to (e.g. `pr-agent`).
- **TTL:** 3600 seconds (1h) at write time.

### Hash recipe (pinned — must match byte-for-byte on both sides)

Both sides hash the exact bytes of the lowercase-hex OTP, no whitespace, lowercase hex output:

- **Shell (mint):** `HASH="$(printf %s "$OTP" | openssl dgst -sha256 -hex | sed 's/^.*= *//')"`. `printf %s` adds no newline; `sed 's/^.*= *//'` strips the `SHA256(stdin)= ` / `SHA2-256(stdin)= ` label robustly across openssl and LibreSSL (do **not** use `awk '{print $NF}'`).
- **Worker (consume):** `const otp = header.trim();` then reject unless `/^[0-9a-f]{64}$/.test(otp)`; then `crypto.subtle.digest('SHA-256', new TextEncoder().encode(otp))` and hex-encode **lowercase** (`b.toString(16).padStart(2,'0')`, never `.toUpperCase()`).

A round-trip test (known OTP → known SHA-256 → KV → worker returns 200) guards this.

### Mint (provision time, operator's machine, inside `gen-cloud-init.sh`)

1. Validate inputs: `: "${OTP_KV_ID:?run 'wrangler kv namespace create OTP_KV' and set OTP_KV_ID}"`; `SECRETS_NS` must match `^[a-z0-9-]+$`.
2. `OTP="$(openssl rand -hex 32)"` — 256 bits, 64 hex chars.
3. `HASH` per the pinned recipe above.
4. `wrangler kv key put --namespace-id="$OTP_KV_ID" "$HASH" "$SECRETS_NS" --ttl 3600`, then **read-back verify** `wrangler kv key get --namespace-id="$OTP_KV_ID" "$HASH"` returns the namespace — else fail.
5. Inject the **raw** `OTP` into the rendered cloud-init as `SECRETS_OTP`, written to its **own** root-owned file `/etc/pr-agent/otp.env` (0600), **separate** from the long-lived `cf-service-token.env`.
6. **Fail loud, atomically:** mint runs **before** rendering; render to a tempfile and `mv` into place only after the mint + read-back + lint all pass; `trap 'rm -f "$tmp"' EXIT`. If `wrangler` is unauthenticated, `OTP_KV_ID`/`SECRETS_NS` are bad, or the put/read-back fails, exit non-zero and emit **no** cloud-init (never user-data with an unregistered OTP — that bricks the box). Suppress shell trace around the mint.
7. Print an operator notice: the OTP is valid 60 minutes; paste and boot within the window. (In practice the box runs minutes of provisioning preamble before `fetch-secrets.sh`, giving the KV write ample time to propagate.)

The provisioning flow is otherwise unchanged: generate locally, paste into Hetzner, boot.

### Consume (first boot, broker `fetch`)

`fetch-secrets.sh` sources `/etc/pr-agent/otp.env`, asserts `: "${SECRETS_OTP:?}"`, and sends — in addition to the existing `CF-Access-Client-Id/Secret` — the header `X-Secrets-OTP: $SECRETS_OTP`. It makes a **single** attempt (no `--retry`), and on success **deletes `/etc/pr-agent/otp.env`** so the raw OTP does not persist on-box.

Broker request handling, in order:
1. Path must match `/secrets/<namespace>` for a registered namespace, else **404**.
2. `Cf-Access-Jwt-Assertion` header must be present, else **401**. (Access validates the service token at the edge before the Worker runs; the Worker is reachable only via the Access-gated custom domain — see `workers_dev = false` below.)
3. Resolve the KV binding: if `env.OTP_KV == null` → **500** (fail closed, binding missing).
4. `otp = X-Secrets-OTP header, trimmed`. If absent or not `^[0-9a-f]{64}$` → **410**.
5. `OTP_KV.get(hash)` inside try/catch. If `.get` throws → **500** (fail closed). If it resolves `null` (absent/expired/consumed) → **410**.
6. If the stored value ≠ the requested namespace (strict `===`, no trimming) → **410**.
7. `await OTP_KV.delete(hash)` inside try/catch. If delete throws/rejects → **500** (never serve secrets with a live OTP). Emit a structured log line on consume (and if the key was unexpectedly already-absent, as a replay signal).
8. Return **200** + the namespace bundle, with `cache-control: no-store`.

The raw OTP is never compared directly and never logged; it is only hashed and used as a KV key, so there is no timing side channel and no plaintext OTP at rest in KV.

## Status-code rationale

- **401** only for a missing Access assertion (the edge gate should have caught it first; this is defense in depth).
- **410 Gone**, uniformly, for **every** OTP failure — missing header, malformed, absent, expired, already-consumed, namespace mismatch. Uniform 410 removes the capability oracle (no signal distinguishing "no OTP" from "bad OTP" to a caller who already passed Access).
- **404** for unknown path/namespace.
- **500** if the KV binding is missing or a KV op throws — fail closed.

## KV namespace setup (one-time)

`wrangler kv namespace create OTP_KV` → add the returned id to `secrets-broker/wrangler.toml` as a `[[kv_namespaces]]` binding (`binding = "OTP_KV"`). The Worker code calls only `.get()` and `.delete()` — **never `.put()`**; minting is exclusively the operator's `wrangler` CLI. Scope the mint API token to KV write on this namespace only (least privilege; documented in the runbook). The `gen-cloud-init.sh` mint reads the same namespace id from config (`OTP_KV_ID`, non-secret).

## Closing the workers.dev bypass

Set `workers_dev = false` in `wrangler.toml`. Without it, the Worker is also reachable at `tjw-secrets-broker.<account>.workers.dev`, which is **not** behind the `secrets.tjw.dev` Access application — an attacker could hit that route and the only gate would be the (spoofable) header-presence check. Disabling the workers.dev route makes the broker reachable solely via the Access-gated custom domain. (Full Access-JWT signature verification against the team JWKS is documented as optional future hardening; with the bypass route closed and Access enforcing at the edge, presence-check is adequate defense in depth.)

## KV vs Durable Object (resolved)

KV is retained. The mint is `wrangler kv key put` — CLI-scriptable, no admin endpoint, fitting the local-provision flow. A Durable Object would give strictly-atomic consume-once but cannot be seeded from the CLI, forcing an authenticated admin mint endpoint (new auth surface). For the single-provisioning-consumer model the KV race is not a secret-theft vector (a replay returns the same bundle). Mitigations applied: single-attempt fetch (no client retry that could self-race), `await`ed delete with fail-closed-on-error, replay-signal logging. DO is the documented upgrade path if the broker ever serves concurrent consumers.

## Files touched

- `secrets-broker/src/index.ts` — OTP enforcement + KV consume-once, namespace-scoped, fail-closed; format-validate OTP; uniform 410.
- `secrets-broker/wrangler.toml` — `[[kv_namespaces]]` `OTP_KV` binding; `workers_dev = false`.
- `secrets-broker/wrangler.test.toml` — `OTP_KV` binding for tests (miniflare provides a real in-memory KV).
- `secrets-broker/test/index.test.ts` — OTP cases (below).
- `deploy/gen-cloud-init.sh` — mint OTP (before render), `wrangler kv key put` + read-back, inject `SECRETS_OTP`; tempfile + `mv` + `trap`; guards; fail loud.
- `deploy/cloud-init.template.yaml` — `write_files` for `/etc/pr-agent/otp.env` (0600) with `SECRETS_OTP=__SECRETS_OTP__`.
- `deploy/fetch-secrets.sh` — source `otp.env`, require `SECRETS_OTP`, send `X-Secrets-OTP`, single attempt, delete `otp.env` on success.
- `deploy/config.env` + `deploy/cloud-init.vars.example` — `OTP_KV_ID` (non-secret).
- `deploy/tests/secrets.bats` — assert the OTP header is sent and `otp.env` deleted; fail if `SECRETS_OTP` unset.
- `deploy/tests/` — new test for the `gen-cloud-init.sh` mint step (mock `wrangler` + `openssl`).
- `docs/runbooks/cloudflare.md` (+ rendered html) — KV namespace setup, least-privilege token, OTP mint step.
- `docs/runbooks/recovery.md` (+ rendered html) — rotation now mints a fresh OTP before re-running `fetch-secrets.sh`; `bootstrap-secrets.sh` noted OTP-exempt.
- `docs/superpowers/DECISIONS-LOG.md` — entry.

## Testing

**Unit tier (macOS, hermetic):**
- Broker vitest: valid OTP → 200 + bundle + KV key deleted; replay (second call) → 410; missing OTP header → 410; malformed OTP (not 64-hex, whitespace, uppercase) → 410; wrong-namespace value → 410; missing Access assertion → 401; KV binding absent → 500. A **round-trip** test seeds KV with a known SHA-256 and sends the matching raw OTP, asserting 200 (proves the worker's hash matches openssl's). miniflare provides a real KV namespace, so consume-once is exercised for real (with the documented eventual-consistency caveat — miniflare is synchronous, so the race is not reproduced in-test).
- `secrets.bats`: `fetch-secrets.sh` sends `X-Secrets-OTP: <value>`, deletes `otp.env` on success, and fails when `SECRETS_OTP` is unset.
- New mint test: `gen-cloud-init.sh` (mock `wrangler` + `openssl` on `PATH`) calls `kv key put` with a 64-hex key and `--ttl 3600`, read-back verifies, injects `SECRETS_OTP`, and on mock failure exits non-zero emitting **no** output file (assert the output path does not exist).

**Integration tier (OrbStack, operator-run):** `make verify-cloudinit` — required because cloud-init changes; cannot run from macOS. The live OTP fetch needs a real broker + KV, so the integration boot asserts host state (otp.env present 0600, executable scripts, env wired) rather than a live fetch, consistent with the existing integration script's stated limitation.

## Failure modes

- **Mint fails (no wrangler auth / KV down / read-back fails):** `gen-cloud-init.sh` aborts via `trap`, no cloud-init emitted. Fix and re-run.
- **OTP expires before boot (>1h):** first fetch gets 410, the cloud-init secrets step fails loudly. Re-run the generator (fresh OTP) and re-provision. The provisioning preamble (package install, ufw, clone, render) runs for minutes before `fetch-secrets.sh`, so the KV write has ample propagation time; immediate paste is fine.
- **KV unavailable / binding missing at fetch:** broker returns 500; fetch fails closed; the box does not come up with empty secrets.
- **Rotation/recovery (existing box):** the stale `otp.env` was deleted after first boot, so re-running `fetch-secrets.sh` alone now 410s. The operator mints a fresh OTP and writes `otp.env` first — documented one-liner in `recovery.md`.
- **`bootstrap-secrets.sh` fallback:** bypasses the broker entirely, so it is OTP-exempt by design (no change).

## Rollout sequencing

The broker (enforce OTP), the consumer (send OTP), and the KV namespace must land together or provisioning breaks. Order: `wrangler kv namespace create OTP_KV` + bind + `workers_dev=false` → deploy broker with OTP enforcement → ship `gen-cloud-init.sh`/`fetch-secrets.sh`/template changes. Do not provision a new box with the new generator until the namespace exists and the broker is redeployed. A box caught mid-provision during rollout fails closed (401/410) and is simply re-provisioned.

## Residual risks (accepted / documented)

- **Raw OTP in Hetzner user-data + `/var/lib/cloud/`:** persists at the link-local metadata endpoint and on-box cache. Mitigated by: own 0600 file, deletion after first fetch, 1h TTL, and burn-on-use. Not fully eliminable (Hetzner stores user-data); documented. A pre-fetch on-box attacker is out of the threat model (fresh box, no untrusted workload runs before `fetch-secrets.sh`).
- **KV non-atomic consume:** see "KV vs Durable Object" — accepted for the single-consumer model, DO is the upgrade path.
- **KV read-quota abuse by a token-holding attacker:** requires already passing Access; low risk. Optional Cloudflare rate-limiting rule on `secrets.tjw.dev` noted, not implemented.
- **Access-JWT signature not verified (presence-only):** acceptable with `workers_dev=false` (no bypass route) + Access enforcing at the edge; JWKS verification is documented future hardening.
