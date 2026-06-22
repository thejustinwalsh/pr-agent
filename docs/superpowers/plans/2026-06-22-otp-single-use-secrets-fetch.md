# OTP single-use secrets-fetch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the boot-time secrets-fetch credential single-use by adding a per-provision OTP that the broker consumes once over Workers KV, layered on the existing Cloudflare Access service-token gate.

**Architecture:** `gen-cloud-init.sh` mints an OTP, registers `sha256(otp)→namespace` in a KV namespace (1h TTL), and injects the raw OTP into cloud-init (`/etc/pr-agent/otp.env`, 0600). At first boot `fetch-secrets.sh` sends it as `X-Secrets-OTP`; the broker validates format, looks up the hash in KV, verifies the namespace, deletes it (burn), and returns the bundle — failing closed on any KV error. `workers_dev = false` removes the Access-bypass route.

**Tech Stack:** Cloudflare Workers (TypeScript), Workers KV, wrangler 4, vitest + @cloudflare/vitest-pool-workers, bash, bats, cloud-init.

**Spec:** `docs/superpowers/specs/2026-06-22-otp-single-use-secrets-fetch-design.md` (read it first).

## Global Constraints

- Toolchain already pinned: `wrangler@^4`, `@cloudflare/vitest-pool-workers@^0.8`, `vitest@~3.2`. Do not downgrade.
- Hash recipe is fixed, both sides, **lowercase hex, no whitespace**: shell `printf %s "$OTP" | openssl dgst -sha256 -hex | sed 's/^.*= *//'`; worker `crypto.subtle.digest('SHA-256', TextEncoder().encode(otp))` → lowercase hex. Never `.toUpperCase()`, never `awk '{print $NF}'`.
- OTP format is exactly `^[0-9a-f]{64}$` (from `openssl rand -hex 32`).
- Status codes: missing Access assertion → **401**; any OTP failure (missing/malformed/absent/expired/used/namespace-mismatch) → **410** uniformly; unknown path/namespace → **404**; KV binding missing or any KV op throws or delete fails → **500** (fail closed). Never serve secrets with a live OTP.
- Worker calls only `OTP_KV.get()` and `.delete()` — never `.put()` (minting is CLI-only).
- Commit identity: repo config (`Justin Walsh <contact.me@thejustinwalsh.com>`). Plain commit messages, **no AI/Co-Authored-By/session trailers**.
- Branch: `production` (this repo's working branch).
- All five existing broker secrets keys are unchanged: `DEEPSEEK_API_KEY, GITHUB_APP_PRIVATE_KEY, GITHUB_APP_ID, GITHUB_WEBHOOK_SECRET, TUNNEL_CRED`.

---

## File Structure

- `secrets-broker/src/index.ts` — add OTP consume-once to the existing path-scoped broker.
- `secrets-broker/wrangler.toml` — `[[kv_namespaces]]` `OTP_KV` + `workers_dev = false`.
- `secrets-broker/wrangler.test.toml` — `[[kv_namespaces]]` `OTP_KV` so miniflare provides a local KV.
- `secrets-broker/test/index.test.ts` — OTP cases (rewrite existing happy-path tests to seed+send an OTP).
- `deploy/fetch-secrets.sh` — source `otp.env`, require + send OTP, single attempt, delete on success.
- `deploy/cloud-init.template.yaml` — `write_files` for `/etc/pr-agent/otp.env`.
- `deploy/gen-cloud-init.sh` — mint OTP (before render) + KV put/read-back + inject + atomic tempfile/`mv`/`trap` + guards.
- `deploy/cloud-init.vars.example` — `OTP_KV_ID`.
- `deploy/tests/secrets.bats` — OTP header sent, `otp.env` deleted, fail if unset.
- `deploy/tests/otp.bats` — new: `gen-cloud-init.sh` mint behavior (mock `wrangler`).
- `docs/runbooks/cloudflare.md` (+ html) — KV setup + OTP mint step + least-priv token.
- `docs/runbooks/recovery.md` (+ html) — rotation mints a fresh OTP; `bootstrap-secrets.sh` OTP-exempt.
- `docs/superpowers/DECISIONS-LOG.md` — entry.

---

## Task 1: Broker OTP consume-once

**Files:**
- Modify: `secrets-broker/src/index.ts`
- Modify: `secrets-broker/wrangler.toml`
- Modify: `secrets-broker/wrangler.test.toml`
- Test: `secrets-broker/test/index.test.ts`

**Interfaces:**
- Consumes: existing `BUNDLES` registry, `resolve()`, `SecretsBinding` (already in the file).
- Produces: the broker now requires `X-Secrets-OTP` for any `/secrets/<ns>` 200. Env gains `OTP_KV: { get(k): Promise<string|null>; delete(k): Promise<void> }`.

- [ ] **Step 1: Add the KV binding to the test config so miniflare provides a local KV**

Edit `secrets-broker/wrangler.test.toml`, append:

```toml

[[kv_namespaces]]
binding = "OTP_KV"
id = "otp-test"
```

- [ ] **Step 2: Write the failing tests** (replace the body of `secrets-broker/test/index.test.ts`)

```typescript
import { env, createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { describe, it, expect, beforeEach } from "vitest";
import worker from "../src/index";

// Canonical round-trip pair: OTP -> openssl sha256_hex(OTP).
const OTP = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const HASH = "a8ae6e6ee929abea3afcfc5258c8ccd6f85273e0d4626d26c7279f3250f77c8e";

const access = { "Cf-Access-Jwt-Assertion": "valid" };

async function call(path: string, headers?: Record<string, string>, envOverride?: unknown) {
  const req = new Request(`https://secrets.tjw.dev${path}`, headers ? { headers } : undefined);
  const ctx = createExecutionContext();
  const res = await worker.fetch(req, (envOverride ?? env) as never, ctx);
  await waitOnExecutionContext(ctx);
  return res;
}

const kv = () => (env as unknown as { OTP_KV: { put(k: string, v: string): Promise<void>; get(k: string): Promise<string | null>; delete(k: string): Promise<void> } }).OTP_KV;

beforeEach(async () => { await kv().delete(HASH); });

describe("secrets broker (path-scoped + OTP)", () => {
  it("returns the pr-agent bundle for a valid unused OTP, then burns it", async () => {
    await kv().put(HASH, "pr-agent");
    const res = await call("/secrets/pr-agent", { ...access, "X-Secrets-OTP": OTP });
    expect(res.status).toBe(200);
    const body = await res.json<Record<string, string>>();
    expect(Object.keys(body).sort()).toEqual([
      "DEEPSEEK_API_KEY", "GITHUB_APP_ID", "GITHUB_APP_PRIVATE_KEY", "GITHUB_WEBHOOK_SECRET", "TUNNEL_CRED",
    ]);
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(await kv().get(HASH)).toBeNull(); // burned
  });

  it("rejects a replay of a consumed OTP with 410", async () => {
    await kv().put(HASH, "pr-agent");
    expect((await call("/secrets/pr-agent", { ...access, "X-Secrets-OTP": OTP })).status).toBe(200);
    expect((await call("/secrets/pr-agent", { ...access, "X-Secrets-OTP": OTP })).status).toBe(410);
  });

  it("410 when the OTP header is missing", async () => {
    await kv().put(HASH, "pr-agent");
    expect((await call("/secrets/pr-agent", access)).status).toBe(410);
  });

  it("410 for a malformed OTP (uppercase or wrong length)", async () => {
    await kv().put(HASH, "pr-agent");
    expect((await call("/secrets/pr-agent", { ...access, "X-Secrets-OTP": OTP.toUpperCase() })).status).toBe(410);
    expect((await call("/secrets/pr-agent", { ...access, "X-Secrets-OTP": "abc" })).status).toBe(410);
  });

  it("410 when the OTP is scoped to a different namespace", async () => {
    await kv().put(HASH, "other-project");
    expect((await call("/secrets/pr-agent", { ...access, "X-Secrets-OTP": OTP })).status).toBe(410);
  });

  it("401 when the Access assertion is missing (before OTP)", async () => {
    expect((await call("/secrets/pr-agent", { "X-Secrets-OTP": OTP })).status).toBe(401);
  });

  it("404 on unknown namespace / bare /secrets / other paths", async () => {
    expect((await call("/secrets/codevibes", { ...access, "X-Secrets-OTP": OTP })).status).toBe(404);
    expect((await call("/secrets", access)).status).toBe(404);
    expect((await call("/", access)).status).toBe(404);
  });

  it("500 (fail closed) when the OTP_KV binding is missing", async () => {
    const broken = { ...(env as object), OTP_KV: undefined };
    expect((await call("/secrets/pr-agent", { ...access, "X-Secrets-OTP": OTP }, broken)).status).toBe(500);
  });
});
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd secrets-broker && npm test`
Expected: FAIL — the current worker has no OTP logic, so valid-OTP returns 200 *without* burning, missing-OTP returns 200 not 410, and the 500 test fails.

- [ ] **Step 4: Implement OTP enforcement** (replace `secrets-broker/src/index.ts`)

```typescript
// Shared secrets broker for secrets.tjw.dev. Sits behind Cloudflare Access
// (service-token policy) and requires a single-use OTP per fetch.
//
// Path-scoped per namespace: GET /secrets/<project> returns only that project's
// bundle. The OTP (X-Secrets-OTP header) is sha256-hashed, looked up in OTP_KV,
// verified against the namespace, and deleted (burned) before the bundle is
// returned. Any OTP failure is a uniform 410; KV errors fail closed (500).

type SecretsBinding = string | { get(): Promise<string> };

interface OtpKv {
  get(key: string): Promise<string | null>;
  delete(key: string): Promise<void>;
}

export interface Env {
  DEEPSEEK_API_KEY: SecretsBinding;
  GITHUB_APP_PRIVATE_KEY: SecretsBinding;
  GITHUB_APP_ID: SecretsBinding;
  GITHUB_WEBHOOK_SECRET: SecretsBinding;
  TUNNEL_CRED: SecretsBinding;
  OTP_KV: OtpKv;
}

const BUNDLES: Record<string, (env: Env) => Record<string, SecretsBinding>> = {
  "pr-agent": (env) => ({
    DEEPSEEK_API_KEY: env.DEEPSEEK_API_KEY,
    GITHUB_APP_PRIVATE_KEY: env.GITHUB_APP_PRIVATE_KEY,
    GITHUB_APP_ID: env.GITHUB_APP_ID,
    GITHUB_WEBHOOK_SECRET: env.GITHUB_WEBHOOK_SECRET,
    TUNNEL_CRED: env.TUNNEL_CRED,
  }),
};

async function resolve(b: SecretsBinding): Promise<string> {
  return typeof b === "string" ? b : b.get();
}

async function sha256hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

const gone = () => new Response("gone", { status: 410 });
const fail = () => new Response("error", { status: 500 });

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const m = url.pathname.match(/^\/secrets\/([a-z0-9-]+)$/);
    const namespace = m?.[1];
    const bundle = namespace ? BUNDLES[namespace] : undefined;
    if (!bundle || !namespace) return new Response("not found", { status: 404 });

    // Access injects this header once its service-token policy passes.
    if (!req.headers.get("Cf-Access-Jwt-Assertion")) {
      return new Response("unauthorized", { status: 401 });
    }

    // KV binding must exist — fail closed if misconfigured/undeployed.
    if (env.OTP_KV == null) return fail();

    const otp = (req.headers.get("X-Secrets-OTP") ?? "").trim();
    if (!/^[0-9a-f]{64}$/.test(otp)) return gone();

    const hash = await sha256hex(otp);
    let stored: string | null;
    try {
      stored = await env.OTP_KV.get(hash);
    } catch {
      return fail();
    }
    if (stored === null) {
      console.warn(`otp miss for namespace=${namespace}`); // replay/expiry signal
      return gone();
    }
    if (stored !== namespace) return gone();

    // Burn before serving; if the delete fails, do NOT serve secrets.
    try {
      await env.OTP_KV.delete(hash);
    } catch {
      return fail();
    }

    const spec = bundle(env);
    const entries = await Promise.all(
      Object.entries(spec).map(async ([k, b]) => [k, await resolve(b)] as const),
    );
    return Response.json(Object.fromEntries(entries), {
      headers: { "cache-control": "no-store" },
    });
  },
};
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd secrets-broker && npm test`
Expected: PASS — 8 tests in `test/index.test.ts`.

- [ ] **Step 6: Add the production KV binding + close the bypass route** (edit `secrets-broker/wrangler.toml`)

Under the `routes = [...]` block, add `workers_dev = false` on its own line. After the last `[[secrets_store_secrets]]` block (before the `# NOTE` comment), add:

```toml

# OTP single-use store (read+delete only from the Worker; minting is CLI-only).
# Create with: wrangler kv namespace create OTP_KV  -> paste the id here.
[[kv_namespaces]]
binding = "OTP_KV"
id = "REPLACE_WITH_OTP_KV_ID"
```

And immediately after `routes = [...]`:

```toml
workers_dev = false
```

- [ ] **Step 7: Verify lint + dry-run still parse** (the placeholder id is fine for `--dry-run`)

Run: `cd secrets-broker && npx eslint src && npx wrangler deploy --dry-run 2>&1 | grep -iE 'kv|workers.dev|binding' | head`
Expected: eslint clean; dry-run lists an `OTP_KV` KV Namespace binding and no error. (Operator replaces `REPLACE_WITH_OTP_KV_ID` with the real id before the real deploy.)

- [ ] **Step 8: Commit**

```bash
cd /Users/tjw/Developer/pr-agent
git add secrets-broker/src/index.ts secrets-broker/wrangler.toml secrets-broker/wrangler.test.toml secrets-broker/test/index.test.ts
git commit -m "secrets-broker: single-use OTP consume-once over KV

Require X-Secrets-OTP per fetch: sha256 the OTP, look it up in OTP_KV,
verify the namespace, burn it (delete) before returning the bundle.
Uniform 410 for any OTP failure; 500 fail-closed on missing binding,
KV get/delete error. workers_dev=false removes the Access-bypass route.
vitest 8/8."
```

---

## Task 2: Consumer sends + consumes the OTP

**Files:**
- Modify: `deploy/fetch-secrets.sh`
- Test: `deploy/tests/secrets.bats`

**Interfaces:**
- Consumes: `SECRETS_DOMAIN`, `SECRETS_NS` (from `config.env`), `CF_SERVICE_TOKEN_*` (env), `SECRETS_OTP` (from `/etc/pr-agent/otp.env` or env).
- Produces: an HTTPS GET to `/secrets/$SECRETS_NS` carrying `X-Secrets-OTP`; deletes `otp.env` on success.

- [ ] **Step 1: Write the failing tests** (append to `deploy/tests/secrets.bats`, before `@test "does NOT log into ghcr...`)

```bash
@test "sends the single-use OTP header to the broker" {
  export SECRETS_OTP=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  run bash "$BATS_TEST_DIRNAME/../fetch-secrets.sh"
  [ "$status" -eq 0 ]
  grep -q "X-Secrets-OTP: $SECRETS_OTP" "$TMP/calls.log"
}

@test "deletes otp.env after a successful fetch" {
  printf 'SECRETS_OTP=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n' > "$TMP/otp.env"
  export OTP_ENV="$TMP/otp.env"
  run bash "$BATS_TEST_DIRNAME/../fetch-secrets.sh"
  [ "$status" -eq 0 ]
  [ ! -f "$TMP/otp.env" ]
}

@test "fails if the OTP is missing (no silent unauth fetch)" {
  unset SECRETS_OTP
  export OTP_ENV="$TMP/nonexistent.env"
  run bash "$BATS_TEST_DIRNAME/../fetch-secrets.sh"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd /Users/tjw/Developer/pr-agent && bats deploy/tests/secrets.bats`
Expected: the three new tests FAIL (fetch-secrets does not yet send the header, read `OTP_ENV`, or require `SECRETS_OTP`).

- [ ] **Step 3: Implement** (edit `deploy/fetch-secrets.sh`)

After the existing line `: "${SECRETS_NS:?secrets namespace required}"`, insert:

```bash
# Single-use OTP: sourced from its own root-owned file (overridable for tests),
# required, sent to the broker, and deleted after a successful fetch.
OTP_ENV="${OTP_ENV:-/etc/pr-agent/otp.env}"
# shellcheck source=/dev/null
[ -r "$OTP_ENV" ] && . "$OTP_ENV"
: "${SECRETS_OTP:?SECRETS_OTP required — mint a fresh OTP (see recovery runbook)}"
```

Change the `curl` invocation to add the OTP header (single attempt, no retry):

```bash
JSON="$(curl -fsS "https://$SECRETS_DOMAIN/secrets/$SECRETS_NS" \
  -H "CF-Access-Client-Id: $CF_SERVICE_TOKEN_ID" \
  -H "CF-Access-Client-Secret: $CF_SERVICE_TOKEN_SECRET" \
  -H "X-Secrets-OTP: $SECRETS_OTP")"
```

Replace the final `echo "[fetch-secrets] podman secrets created"` line with:

```bash
# Burn the on-box copy of the single-use OTP.
rm -f "$OTP_ENV" 2>/dev/null || true
echo "[fetch-secrets] podman secrets created; OTP consumed"
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd /Users/tjw/Developer/pr-agent && bats deploy/tests/secrets.bats`
Expected: PASS — all secrets tests (existing + 3 new).

- [ ] **Step 5: Shellcheck**

Run: `make verify-shell`
Expected: no output (clean).

- [ ] **Step 6: Commit**

```bash
git add deploy/fetch-secrets.sh deploy/tests/secrets.bats
git commit -m "deploy: fetch-secrets sends + burns the single-use OTP

Source SECRETS_OTP from /etc/pr-agent/otp.env (path overridable for tests),
require it, send it as X-Secrets-OTP on a single fetch attempt, and delete
otp.env on success so the raw OTP does not persist on-box."
```

---

## Task 3: Mint the OTP in gen-cloud-init + plumb it through cloud-init

**Files:**
- Modify: `deploy/cloud-init.template.yaml`
- Modify: `deploy/gen-cloud-init.sh`
- Modify: `deploy/cloud-init.vars.example`
- Test: `deploy/tests/otp.bats` (create)

**Interfaces:**
- Consumes: `OTP_KV_ID`, `SECRETS_NS` (default `pr-agent`), existing vars, `WRANGLER` (override, default `wrangler`).
- Produces: rendered cloud-init containing `/etc/pr-agent/otp.env` with `SECRETS_OTP=<64hex>`; a KV entry `sha256(otp)→namespace` (1h TTL).

- [ ] **Step 1: Add the otp.env write_files block** (edit `deploy/cloud-init.template.yaml`)

Immediately after the `cf-service-token.env` block (after its `CF_SERVICE_TOKEN_SECRET=__CF_SERVICE_TOKEN_SECRET__` line), insert:

```yaml
  - path: /etc/pr-agent/otp.env
    permissions: '0600'
    owner: root:root
    content: |
      SECRETS_OTP=__SECRETS_OTP__
```

(The existing `chown -R pragent:pragent /etc/pr-agent` runcmd makes it readable+deletable by `pragent`, same as `cf-service-token.env`.)

- [ ] **Step 2: Add OTP_KV_ID to the example vars** (edit `deploy/cloud-init.vars.example`)

Append:

```bash
# Workers KV namespace id for single-use OTPs (wrangler kv namespace create OTP_KV).
OTP_KV_ID=
# Secrets namespace served by the broker (path /secrets/<ns>).
SECRETS_NS=pr-agent
```

- [ ] **Step 3: Write the failing tests** (create `deploy/tests/otp.bats`)

```bash
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
```

- [ ] **Step 4: Run to verify they fail**

Run: `cd /Users/tjw/Developer/pr-agent && bats deploy/tests/otp.bats`
Expected: FAIL — `gen-cloud-init.sh` does not yet mint, has no `OTP_KV_ID` guard, and does not substitute `__SECRETS_OTP__` (leftover-placeholder check would also trip).

- [ ] **Step 5: Implement the mint** (replace `deploy/gen-cloud-init.sh`)

```bash
#!/usr/bin/env bash
# Render cloud-init.template.yaml with per-server vars → paste-ready doc. Asserts < 32 KiB.
# Mints a single-use OTP, registers sha256(otp)→namespace in Workers KV (1h TTL),
# and injects the raw OTP. Fails loud (emits nothing) if minting fails.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VARS="${1:?vars file required}"; OUT="${2:-$HERE/cloud-init.out.yaml}"
# shellcheck source=/dev/null
source "$VARS"
: "${CF_SERVICE_TOKEN_ID:?}"; : "${CF_SERVICE_TOKEN_SECRET:?}"; : "${FORK_REPO:?}"; : "${TUNNEL_ID:?}"
: "${OTP_KV_ID:?run 'wrangler kv namespace create OTP_KV' and set OTP_KV_ID}"
SECRETS_NS="${SECRETS_NS:-pr-agent}"
case "$SECRETS_NS" in *[!a-z0-9-]*|"") echo "gen-cloud-init: bad SECRETS_NS '$SECRETS_NS'" >&2; exit 1;; esac
WRANGLER="${WRANGLER:-wrangler}"

# Mint BEFORE rendering: a failed mint must emit no cloud-init.
OTP="$(openssl rand -hex 32)"
HASH="$(printf %s "$OTP" | openssl dgst -sha256 -hex | sed 's/^.*= *//')"
( set +x
  "$WRANGLER" kv key put --namespace-id="$OTP_KV_ID" "$HASH" "$SECRETS_NS" --ttl 3600 >/dev/null
  got="$("$WRANGLER" kv key get --namespace-id="$OTP_KV_ID" "$HASH")"
  [ "$got" = "$SECRETS_NS" ] || { echo "gen-cloud-init: KV read-back mismatch" >&2; exit 1; }
)

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
sed -e "s|__CF_SERVICE_TOKEN_ID__|${CF_SERVICE_TOKEN_ID}|g" \
    -e "s|__CF_SERVICE_TOKEN_SECRET__|${CF_SERVICE_TOKEN_SECRET}|g" \
    -e "s|__FORK_REPO__|${FORK_REPO}|g" \
    -e "s|__TUNNEL_ID__|${TUNNEL_ID}|g" \
    -e "s|__SECRETS_OTP__|${OTP}|g" \
    "$HERE/cloud-init.template.yaml" > "$tmp"
if grep -q "__" "$tmp"; then echo "gen-cloud-init: leftover placeholder" >&2; exit 1; fi
SIZE="$(wc -c < "$tmp")"
if [ "$SIZE" -ge 32768 ]; then echo "gen-cloud-init: $SIZE bytes (>=32KiB limit)" >&2; exit 1; fi
if command -v cloud-init >/dev/null 2>&1; then
  cloud-init schema --config-file "$tmp"
elif command -v yamllint >/dev/null 2>&1; then
  yamllint -d relaxed "$tmp"
fi
mv "$tmp" "$OUT"; trap - EXIT
echo "gen-cloud-init: wrote $OUT ($SIZE bytes)"
echo "gen-cloud-init: OTP valid 60 minutes — paste into Hetzner and boot within the window."
```

- [ ] **Step 6: Run the OTP tests to verify they pass**

Run: `cd /Users/tjw/Developer/pr-agent && bats deploy/tests/otp.bats`
Expected: PASS — 3 tests.

- [ ] **Step 7: Run the existing cloud-init + shell verifiers (no regressions)**

Run: `bats deploy/tests/cloudinit.bats && make verify-shell`
Expected: cloudinit.bats green; shellcheck clean. (If a cloudinit.bats render test exists, it must now supply `OTP_KV_ID` + a mock `wrangler`; if it fails for lack of these, update that test's setup the same way as `otp.bats` and re-run.)

- [ ] **Step 8: Commit**

```bash
git add deploy/gen-cloud-init.sh deploy/cloud-init.template.yaml deploy/cloud-init.vars.example deploy/tests/otp.bats
git commit -m "deploy: gen-cloud-init mints a single-use OTP into KV + cloud-init

Mint OTP before render: wrangler kv key put sha256(otp)->namespace --ttl 3600
with read-back verify, inject raw OTP into /etc/pr-agent/otp.env (0600), and
render atomically (tempfile + mv + trap) so a failed mint emits no cloud-init.
Guards on OTP_KV_ID and SECRETS_NS. New otp.bats covers mint + fail-loud."
```

---

## Task 4: Runbooks + decision log

**Files:**
- Modify: `docs/runbooks/cloudflare.md`
- Modify: `docs/runbooks/recovery.md`
- Modify: `docs/superpowers/DECISIONS-LOG.md`
- Regenerate: `docs/runbooks/cloudflare.html`, `docs/runbooks/recovery.html`

- [ ] **Step 1: Document KV setup + OTP mint in the cloudflare runbook** (edit `docs/runbooks/cloudflare.md`)

In Part 4 (broker deploy), before "Step 13 — Deploy", add:

```markdown
**Step 12a — Create the OTP KV namespace.** The broker enforces a single-use OTP per fetch, stored in Workers KV.

\`\`\`bash
cd secrets-broker
npx wrangler kv namespace create OTP_KV   # prints an id
\`\`\`

Put the id into `wrangler.toml` (`[[kv_namespaces]]` `OTP_KV`, replacing `REPLACE_WITH_OTP_KV_ID`) and into `deploy/cloud-init.vars` as `OTP_KV_ID`. Scope the wrangler API token used for minting to **KV write on this namespace only** (least privilege) — the Worker itself only reads and deletes. `workers_dev = false` in `wrangler.toml` keeps the broker reachable solely via the Access-gated `secrets.tjw.dev`.
```

In Part 5 (verify), after Step 15, add:

```markdown
> The fetch above needs a live OTP. `gen-cloud-init.sh` mints one automatically at provision time; to test by hand, mint one and pass it:
>
> \`\`\`bash
> OTP="$(openssl rand -hex 32)"
> HASH="$(printf %s "$OTP" | openssl dgst -sha256 -hex | sed 's/^.*= *//')"
> npx wrangler kv key put --namespace-id="$OTP_KV_ID" "$HASH" pr-agent --ttl 3600
> curl -fsS https://secrets.tjw.dev/secrets/pr-agent \
>   -H "CF-Access-Client-Id: $CF_SERVICE_TOKEN_ID" \
>   -H "CF-Access-Client-Secret: $CF_SERVICE_TOKEN_SECRET" \
>   -H "X-Secrets-OTP: $OTP" | jq 'keys'
> \`\`\`
>
> A second call with the same OTP returns 410 (burned).
```

- [ ] **Step 2: Document the rotation/recovery OTP mint** (edit `docs/runbooks/recovery.md`)

Where it instructs re-running `fetch-secrets.sh`, add immediately before that command:

```markdown
**Mint a fresh OTP first.** The boot OTP is single-use and was burned (and `otp.env` deleted) at first boot, so re-running `fetch-secrets.sh` alone returns 410. Mint a new one and write it to `otp.env`:

\`\`\`bash
OTP="$(openssl rand -hex 32)"
HASH="$(printf %s "$OTP" | openssl dgst -sha256 -hex | sed 's/^.*= *//')"
npx wrangler kv key put --namespace-id="$OTP_KV_ID" "$HASH" pr-agent --ttl 3600
printf 'SECRETS_OTP=%s\n' "$OTP" | sudo tee /etc/pr-agent/otp.env >/dev/null
sudo chown pragent:pragent /etc/pr-agent/otp.env && sudo chmod 600 /etc/pr-agent/otp.env
\`\`\`

(If the broker is unreachable, use `bootstrap-secrets.sh` instead — it bypasses the broker entirely and needs no OTP.)
```

- [ ] **Step 3: Regenerate the HTML**

Run: `cd /Users/tjw/Developer/pr-agent && bash docs/runbooks/render.sh >/dev/null && git status --short docs/runbooks/*.html`
Expected: `cloudflare.html` and `recovery.html` modified.

- [ ] **Step 4: Run the runbook tests**

Run: `bats deploy/tests/runbooks.bats`
Expected: PASS (existing assertions still hold; additions are additive).

- [ ] **Step 5: Append the decision log entry** (append to `docs/superpowers/DECISIONS-LOG.md`)

```markdown

## 2026-06-22 — OTP single-use hardening for the boot-time secrets fetch
- **Context:** A leaked Access service token could re-pull secrets indefinitely. `fetch-secrets.sh` runs once at provision (cloud-init), so a single-use credential carries no per-boot bricking risk.
- **Decision:** Per-provision OTP minted by `gen-cloud-init.sh` (`wrangler kv key put sha256(otp)→namespace --ttl 3600`, read-back verified), injected to `/etc/pr-agent/otp.env` (0600), sent by `fetch-secrets.sh` as `X-Secrets-OTP` (single attempt, file deleted on success), consumed once by the broker over KV. Layered on the Access service-token gate (both required).
- **Adversarial review (5-agent horde) hardening:** pinned SHA-256 recipe both sides (lowercase, `sed` not `awk`); uniform 410 for all OTP failures; fail-closed on missing binding / KV get / delete error; OTP format `^[0-9a-f]{64}$`; own 0600 file deleted post-fetch; `workers_dev=false` to close the Access-bypass route; atomic tempfile+`mv`+`trap` mint; recovery rotation one-liner.
- **KV not Durable Object:** KV is CLI-mintable (no admin endpoint); the non-atomic consume is best-effort and not a secret-theft vector for a single provisioning consumer (a replay returns the same bundle). DO is the documented upgrade path if it ever serves concurrent consumers.
- **Evidence:** broker vitest 8/8; secrets.bats (+3); otp.bats 3/3; shellcheck clean; wrangler 4 dry-run lists the OTP_KV binding.
- **Affected:** `secrets-broker/{src/index.ts,wrangler.toml,wrangler.test.toml,test/index.test.ts}`, `deploy/{fetch-secrets.sh,gen-cloud-init.sh,cloud-init.template.yaml,cloud-init.vars.example,tests/{secrets,otp}.bats}`, `docs/runbooks/{cloudflare,recovery}.{md,html}`.
- **Operator:** create `OTP_KV` namespace + set id in `wrangler.toml` and `cloud-init.vars`; redeploy broker; then provision. Integration tier (`make verify-cloudinit`) on OrbStack after the cloud-init change.
- **Revisit:** Durable Object if multi-consumer; optional Access-JWT JWKS verification; optional CF rate-limit rule on secrets.tjw.dev.
```

- [ ] **Step 6: Commit**

```bash
git add docs/runbooks/cloudflare.md docs/runbooks/cloudflare.html docs/runbooks/recovery.md docs/runbooks/recovery.html docs/superpowers/DECISIONS-LOG.md
git commit -m "docs: OTP single-use — cloudflare KV setup + recovery rotation + decision log"
```

---

## Final verification (after all tasks)

- [ ] Run `cd secrets-broker && npm test && npx eslint src` — vitest 8/8, lint clean.
- [ ] Run `bats deploy/tests/` — full suite green (secrets, otp, runbooks, cloudinit, …).
- [ ] Run `make verify` — exit 0.
- [ ] **Operator (not automatable here):** create the `OTP_KV` namespace, set its id in `wrangler.toml` + `cloud-init.vars`, redeploy the broker, then run `make verify-cloudinit` on the OrbStack box (required integration tier for the cloud-init change).

## Self-review notes (coverage check)

- Hash recipe pinned both sides + round-trip test (Task 1 Step 2 `HASH` constant) — spec §"Hash recipe". ✓
- Uniform 410 / 401 / 404 / 500 — Task 1 Step 4 + tests — spec §"Status-code rationale". ✓
- Fail-closed: missing binding, get throw, delete throw — Task 1 Step 4 + 500 test — spec §Consume 3/5/7. ✓
- workers_dev=false — Task 1 Step 6 — spec §"Closing the workers.dev bypass". ✓
- Own otp.env, deleted post-fetch, single attempt, OTP guard — Task 2 — spec §Consume + Files. ✓
- Atomic mint, read-back, guards, fail-loud — Task 3 — spec §Mint. ✓
- Recovery rotation one-liner + bootstrap-exempt — Task 4 Step 2 — spec §"Failure modes". ✓
- Integration tier flagged operator-run — Final verification — spec §Testing. ✓
