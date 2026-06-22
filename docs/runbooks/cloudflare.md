# Cloudflare — Tunnel, Access-Exempt Webhook, Shared Secrets Broker

**Goal:** Wire `pr-agent.tjw.dev` on Cloudflare and add this project to the **shared** secrets broker at `secrets.tjw.dev`. The webhook hostname must be **Access-EXEMPT** (GitHub cannot log in through Access), gated instead by the GitHub App's HMAC webhook secret. The broker stays **Access-gated** by a service token and is path-scoped per project — this box reads its bundle from `secrets.tjw.dev/secrets/pr-agent`. Along the way you create the tunnel, populate the five `pr-agent-*` secrets in the single account Secrets Store, deploy the shared broker Worker (which serves the `pr-agent` namespace), and verify a full fetch.

**Prerequisites:**

- `tjw.dev` is an active Cloudflare zone with DNS managed by Cloudflare.
- You are the account owner with Zero Trust enabled (if not, enable Zero Trust and add an identity provider first).
- `github-app.html` is complete: you hold the App ID, the private-key PEM, and the webhook secret.
- Node.js and `wrangler` (**v4+**, for Secrets Store GA) are available locally (`cd secrets-broker && npm install`).
- The Cloudflare API token for wrangler has **Edit Workers** and **Secrets Store** permissions.

**Diagram — Boot-time secrets fetch path:**

![Boot-time secrets fetch](diagrams/secrets-fetch.svg)

> **One broker, many namespaces.** The broker at `secrets.tjw.dev` is shared across projects and scoped by path: `secrets.tjw.dev/secrets/pr-agent` returns only this project's five keys, and a bundle never sees another namespace's secrets. Adding a future project is a new entry in `secrets-broker/src/index.ts` plus its store bindings in `wrangler.toml` — not a new hostname.
>
> **Two postures, do not mix them up.** `pr-agent.tjw.dev` faces GitHub's webhook senders, which are anonymous machines that cannot satisfy an Access login — so it is **exempt** from Access and protected by HMAC. `secrets.tjw.dev` faces only the Hetzner box at boot, which *can* present a service token — so it stays **behind Access**. Getting these backwards is the classic footgun: an Access-gated webhook hostname silently 302s every GitHub delivery to a login page (the App's **Recent Deliveries** shows a redirect, never a 200), and an exempt secrets hostname leaks every secret to the open internet.

---

## Part 1 — Create the Cloudflare Tunnel

**Step 1.** Install `cloudflared` locally if needed and log in:

```bash
brew install cloudflared
cloudflared tunnel login
```

**Step 2.** Create the tunnel:

```bash
cloudflared tunnel create pr-agent
```

You should see:

```
Created tunnel pr-agent with id <TUNNEL_UUID>
```

Note the **Tunnel UUID** — this is `TUNNEL_ID` in `deploy/config.env`, and it also fills `__TUNNEL_ID__` in `deploy/cloudflared/config.yml.template` (rendered by `deploy/render-config.sh`). The ingress in that template points `pr-agent.tjw.dev → http://localhost:3000` (the webhook port).

**Step 3 — Tunnel credential → secret.** The credential file lands at `~/.cloudflared/<TUNNEL_UUID>.json` and looks like `{"AccountTag":"...","TunnelID":"...","TunnelSecret":"..."}`. Its **contents** become the `pr-agent-tunnel-cred` entry in the Secrets Store (Part 3). View it:

```bash
cat ~/.cloudflared/<TUNNEL_UUID>.json
```

**Step 4 — DNS route.** Point the hostname at the tunnel:

```bash
cloudflared tunnel route dns pr-agent pr-agent.tjw.dev
```

You should see `Added CNAME pr-agent.tjw.dev which will route to this tunnel`. Confirm in the DNS dashboard that `pr-agent.tjw.dev` is a proxied (orange-cloud) CNAME to `<UUID>.cfargotunnel.com`.

**Step 5 — Update `deploy/config.env`.** Replace the placeholder with the real UUID and commit to `production`:

```bash
# deploy/config.env
TUNNEL_ID=<your-TUNNEL-UUID>
```

---

## Part 2 — Access posture: exempt the webhook, gate the broker

**Step 6 — Webhook hostname is Access-EXEMPT.** You have two equivalent ways to keep `pr-agent.tjw.dev` out of Access:

- **Simplest — never create an Access application for it.** If no Access application's domain matches `pr-agent.tjw.dev`, Access does not intercept it, and the tunnel serves it directly. Just confirm no existing application's domain (or wildcard) covers `pr-agent.tjw.dev`.
- **Explicit — a Bypass policy.** If a wildcard application (e.g. `*.tjw.dev`) would otherwise catch it, add a self-hosted Access application for `pr-agent.tjw.dev` whose single policy is **Action: Bypass**, selector **Everyone**. This documents the intent and overrides the wildcard.

Either way, the security model is: **GitHub's HMAC webhook secret is the gate**, verified inside PR-Agent (`GITHUB__WEBHOOK_SECRET`). Access adds nothing here because the caller is GitHub, which cannot authenticate to Access.

**Checkpoint.** From any machine, an unauthenticated request to the webhook path should reach PR-Agent (not a Cloudflare Access login page). A bare `GET /` returns PR-Agent's own response, and a forged `POST` to `/api/v1/github_webhooks` is rejected by PR-Agent's signature check, not by Access:

```bash
curl -si https://pr-agent.tjw.dev/ | head -3
# Expect an HTTP status line from PR-Agent (200/404/405) — NOT a 302 to *.cloudflareaccess.com
```

**Step 7 — Broker host stays Access-gated.** `secrets.tjw.dev` must accept **only** the machine service token. If the shared broker's Access application already exists, skip to Step 8 and simply add the `pr-agent-server` token as an allowed selector. To create it: **Access > Applications > Add an application > Self-hosted**:

```
Application name:    Secrets Broker (secrets.tjw.dev)
Application domain:  secrets.tjw.dev
```

Create a service-auth policy:

```
Policy name:  Broker service tokens
Action:       Service Auth
Selector:     Service Token — pr-agent-server (create it in Step 8)
```

> The broker is path-scoped, but Access gates the **hostname**, not the path — one service-token policy on `secrets.tjw.dev` covers every namespace. Each box still only ever fetches its own `/secrets/<project>` path.

**Step 8 — Service token.** Navigate to **Access > Service Auth > Service Tokens > Create Service Token**:

```
Token name:  pr-agent-server
Expiration:  Non-expiring  (or a long rotation interval)
```

Click **Generate token** and copy **both** values immediately — the secret is shown only once:

```
Client ID:      <CF_SERVICE_TOKEN_ID>
Client Secret:  <CF_SERVICE_TOKEN_SECRET>
```

Store them in your password manager. They are supplied to `deploy/gen-cloud-init.sh` (via `deploy/cloud-init.vars`) as `CF_SERVICE_TOKEN_ID` / `CF_SERVICE_TOKEN_SECRET`, land in `/etc/pr-agent/cf-service-token.env` on the box, and are what `deploy/fetch-secrets.sh` presents to the broker.

**Step 9.** Return to the `secrets.tjw.dev` application and confirm the `pr-agent-server` service token is an allowed selector. Save.

---

## Part 3 — Populate the Secrets Store

> Cloudflare gives each account **one** Secrets Store (up to 100 secrets). We add our five `pr-agent-*` secrets there; the `pr-agent-` prefix keeps them in their own namespace alongside any other project's secrets. You cannot (and need not) create a second store.

**Step 10.** Navigate to **Workers & Pages > Secrets Store** and record the **Store ID** (dashboard, or `npx wrangler secrets-store store list`). It should match the `store_id` already set in `secrets-broker/wrangler.toml`.

**Step 11.** Add the five secrets (names from `deploy/config.env`):

| Secret name | Value | Source |
|---|---|---|
| `pr-agent-deepseek-key` | DeepSeek API key | DeepSeek dashboard → `OPENAI__KEY` |
| `pr-agent-github-app-key` | GitHub App private-key PEM (newlines as `\n` in the JSON string) | `github-app.html` Step 8 → `GITHUB_APP__PRIVATE_KEY` |
| `pr-agent-github-app-id` | GitHub App ID (number) | `github-app.html` Step 7 → `GITHUB_APP__APP_ID` |
| `pr-agent-webhook-secret` | Webhook HMAC secret | `github-app.html` Step 3 → `GITHUB__WEBHOOK_SECRET` |
| `pr-agent-tunnel-cred` | Tunnel credential JSON (one line) | Step 3 above → cloudflared mount |

> **The PEM is multi-line.** Stored in the Secrets Store it is a JSON string with `\n` escapes; the broker returns it as JSON, `fetch-secrets.sh` decodes it with `jq -er` back to real newlines, and `podman secret create` stores the raw bytes. There is no AES `ENCRYPTION_KEY` here — PR-Agent is stateless and keeps no database, so there is nothing to encrypt and no never-rotate key to guard. All five of these secrets are rotatable: change the value in the store, re-run `fetch-secrets.sh`, restart the container.

---

## Part 4 — Deploy the shared broker Worker

The broker source lives in this repo at `secrets-broker/`. `secrets.tjw.dev` is redeployed from here.

**Step 12.** Confirm `secrets-broker/wrangler.toml`. The `[[secrets_store_secrets]]` blocks bind the five `pr-agent-*` secrets to the Worker, all sharing the account `store_id`, and the route is the custom domain `secrets.tjw.dev`. The `pr-agent` namespace is registered in `secrets-broker/src/index.ts` (`BUNDLES["pr-agent"]`). The file deliberately carries no `[vars]` block — `[vars]` would deploy plaintext values and collide with the Secrets Store bindings; test stubs live in `vitest.config.ts`, not here.

> All five `pr-agent-*` secrets from Part 3 must exist in the store before deploy, or `wrangler deploy` fails resolving the bindings.

**Step 13.** Deploy (wrangler v4):

```bash
cd secrets-broker
npm install
npx wrangler deploy
```

**Step 14 — Confirm Access is enforced on the broker.** An unauthenticated request must be blocked:

```bash
curl -si https://secrets.tjw.dev/secrets/pr-agent | head -5
# Expect HTTP 302 (login redirect) or 403 — NOT 200. The Worker is never reached without the token.
```

---

## Part 5 — Verify a full fetch with the service token

**Step 15.** Fetch this project's namespace using your service-token credentials:

```bash
curl -fsS https://secrets.tjw.dev/secrets/pr-agent \
  -H "CF-Access-Client-Id: $CF_SERVICE_TOKEN_ID" \
  -H "CF-Access-Client-Secret: $CF_SERVICE_TOKEN_SECRET" \
  | jq 'keys'
```

You should see all five keys:

```json
[
  "DEEPSEEK_API_KEY",
  "GITHUB_APP_ID",
  "GITHUB_APP_PRIVATE_KEY",
  "GITHUB_WEBHOOK_SECRET",
  "TUNNEL_CRED"
]
```

All five present and non-empty confirms the bindings are wired. The broker serves only `/secrets/<namespace>` for a registered namespace, and only when Cloudflare Access has injected the `Cf-Access-Jwt-Assertion` header — a defense-in-depth check the Worker enforces in `src/index.ts`. A request to a different or unknown namespace returns 404 and never leaks another project's keys.

---

## Revocation — kill switch

- **Service token compromised:** **Access > Service Auth > Service Tokens**, find `pr-agent-server`, **Revoke**. Re-provision a new token and re-run `deploy/fetch-secrets.sh` on the box with the new `CF_SERVICE_TOKEN_*`.
- **Webhook secret compromised:** rotate it in the GitHub App (**github-app.html** Step 3), update `pr-agent-webhook-secret` in the store, re-run `fetch-secrets.sh`, restart the container. Because the webhook hostname is Access-exempt, this HMAC secret is the *only* thing standing between the open internet and a forged delivery — rotate it the moment you suspect exposure.
