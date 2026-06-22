# Create and Install the PR-Agent GitHub App

**Goal:** Register a **GitHub App** (not an OAuth App) that delivers `pull_request` and `issue_comment` webhooks to the self-hosted PR-Agent server at `https://pr-agent.tjw.dev/api/v1/github_webhooks`, then install it on the repositories you want reviewed. PR-Agent authenticates back to GitHub as the App (JWT signed with the App's private key) and verifies inbound webhooks with the App's HMAC webhook secret.

This produces four secret/identity values that the rest of the deployment consumes through the Cloudflare Secrets Store:

| GitHub App field | Secrets Store name | Container env target (dynaconf) |
|---|---|---|
| App **ID** (numeric) | `pr-agent-github-app-id` | `GITHUB_APP__APP_ID` |
| **Private key** (PEM) | `pr-agent-github-app-key` | `GITHUB_APP__PRIVATE_KEY` |
| **Webhook secret** (HMAC) | `pr-agent-webhook-secret` | `GITHUB__WEBHOOK_SECRET` |
| DeepSeek API key | `pr-agent-deepseek-key` | `OPENAI__KEY` |

**Prerequisites:**

- You own (or are an admin of) the GitHub account/org where the App and the target repos live.
- The fork `thejustinwalsh/pr-agent` exists on the `production` branch (see `setup.html`).
- You have decided which repositories PR-Agent should review.

**Diagram — webhook flow (PR → App → tunnel → pr-agent → DeepSeek v4-pro → review):**

![Webhook flow](diagrams/webhook-flow.svg)

> **GitHub App, not OAuth App.** CodeVibes used an OAuth App (a user logs in, the app acts *as that user*). PR-Agent is a **GitHub App**: it is its own first-class actor with its own installation-scoped token, it receives webhooks, and it posts reviews under its own bot identity. There is no human login flow here. If you find yourself on **Settings > Developer settings > OAuth Apps**, you are in the wrong place — you want **GitHub Apps**.

---

## Part 1 — Register the GitHub App

**Step 1.** Go to **GitHub Settings > Developer settings > GitHub Apps > New GitHub App** (`https://github.com/settings/apps/new`). For an org-owned App, use `https://github.com/organizations/<org>/settings/apps/new` instead.

**Step 2.** Fill in the identity fields:

```
GitHub App name:  PR-Agent (tjw)
Homepage URL:     https://pr-agent.tjw.dev
Callback URL:     (leave blank)
Setup URL:        (leave blank)
```

> **No Callback URL, no user authorization.** The Callback URL and "Request user authorization (OAuth) during installation" only apply to user-OAuth ("Login with GitHub") flows, where the app acts *as a logged-in user*. PR-Agent never does that — it authenticates as the App (JWT from the private key) and acts via installation tokens, and its server exposes no OAuth callback route (only the webhook routes). Leave the Callback URL blank and leave **"Request user authorization (OAuth) during installation" unchecked**. The only URL that matters is the Webhook URL below.

**Step 3 — Webhook.** This is the load-bearing part. Set:

```
Webhook:          ☑ Active
Webhook URL:      https://pr-agent.tjw.dev/api/v1/github_webhooks
Webhook secret:   <generate a strong secret — see below>
```

The Webhook URL path `/api/v1/github_webhooks` is the FastAPI route PR-Agent's GitHub-App server actually serves (`pr_agent/servers/github_app.py`: `@router.post("/api/v1/github_webhooks")`). Do not guess this path — it must match the route exactly or every delivery 404s.

Generate the webhook secret on your Mac and keep it:

```bash
openssl rand -hex 32
```

Paste that value into **Webhook secret**. This same value becomes the `pr-agent-webhook-secret` entry in the Secrets Store, injected into the container as `GITHUB__WEBHOOK_SECRET`. PR-Agent recomputes the HMAC-SHA256 of every delivery body with this secret and rejects any request whose `X-Hub-Signature-256` header does not match.

> **The webhook secret is the only gate on the webhook hostname.** `pr-agent.tjw.dev` is **Access-EXEMPT** — GitHub's servers cannot complete a Cloudflare Access login, so Access is bypassed for that hostname (see `cloudflare.html`). Authenticity of every inbound request therefore rests entirely on this HMAC secret. Treat it like a production credential: long, random, stored only in the Secrets Store and your password manager, never committed.

**Step 4 — Permissions.** Under **Permissions > Repository permissions**, set:

```
Pull requests:      Read & write    (post reviews, inline comments, /describe, /improve)
Contents:           Read-only       (read the diff and file contents)
Issues:             Read & write    (PR-Agent treats PR comments via the issues API; /ask, /review replies)
Metadata:           Read-only       (mandatory; auto-selected)
Commit statuses:    Read & write    (optional — lets PR-Agent post a check/status on the PR)
Checks:             Read & write    (optional — richer check-run output if you enable it)
```

Pull requests, Contents, Issues, and Metadata are the minimum PR-Agent needs to review a PR and reply. Commit statuses / Checks are optional and only needed if you want PR-Agent to surface results as a commit status or a check run rather than a comment.

**Step 5 — Subscribe to events.** Under **Subscribe to events**, tick at least:

```
☑ Pull request          (opened/reopened/synchronize → triggers a review)
☑ Issue comment         (a /review, /describe, /improve, /ask comment on a PR)
```

These two cover PR-Agent's core flows. If you intend to use PR-level review comment commands, also subscribe to **Pull request review comment** and **Pull request review**. Each event you tick must be backed by the matching permission from Step 4, or GitHub greys it out.

**Step 6 — Installation scope.** Under **Where can this app be installed?**, choose **Only on this account** unless you deliberately want others to install it. Click **Create GitHub App**.

---

## Part 2 — Capture the identity values

**Step 7 — App ID.** On the App's settings page (right after creation), note the **App ID** (a number, e.g. `1234567`). This becomes the `pr-agent-github-app-id` secret → `GITHUB_APP__APP_ID`.

**Step 8 — Private key.** Scroll to **Private keys** and click **Generate a private key**. GitHub downloads a `.pem` file (RSA, multi-line, `-----BEGIN RSA PRIVATE KEY-----` … `-----END RSA PRIVATE KEY-----`). This file is shown for download **once** — if you lose it, you generate a new one and delete the old.

This PEM becomes the `pr-agent-github-app-key` secret → `GITHUB_APP__PRIVATE_KEY`. It is **multi-line**, which matters for how it is stored and injected:

- The PEM does **not** go in the Secrets Store — a base64 RSA-2048 key (~2.2 KB) exceeds the Store's 1024-char value limit. Store it as a **Worker secret** on the broker (`cloudflare.html` Step 11a), base64-encoded so it stays single-line and JSON-safe through the broker. From `secrets-broker/`, after the Worker is deployed, pipe it in (so it never lands in your shell history or `ps`):

  ```bash
  openssl base64 -A -in pr-agent.<date>.private-key.pem | npx wrangler secret put GITHUB_APP_PRIVATE_KEY
  ```

  `fetch-secrets.sh` decodes it back to the real multi-line PEM (`openssl base64 -d -A`) before `podman secret create`, and the quadlet maps it `type=env,target=GITHUB_APP__PRIVATE_KEY`, so the container sees the intact key. (Encode → decode is lossless; verify with `openssl base64 -A -in key.pem | openssl base64 -d -A | diff - key.pem`.)
- If you are bootstrapping by hand (broker unreachable), do **not** base64-encode and do **not** paste at a prompt. Pass the downloaded file to `deploy/bootstrap-secrets.sh /path/to/pr-agent.<date>.private-key.pem`; it feeds the raw `.pem` straight into `podman secret create` so newlines survive.

> **Never commit the PEM.** It is the App's identity; anyone holding it can act as PR-Agent against every repo the App is installed on. Store it in the Secrets Store and your password manager only.

**Step 9 — Webhook secret (already have it).** The value from Step 3 is the third secret, `pr-agent-webhook-secret` → `GITHUB__WEBHOOK_SECRET`. Confirm the exact bytes match what you pasted into GitHub; a one-character drift means every delivery is rejected as a bad signature.

---

## Part 3 — Install the App on the target repositories

A GitHub App does nothing until it is **installed**. Registration created the App; installation grants it access to specific repos and starts webhook delivery.

**Step 10.** On the App's settings page, click **Install App** in the left sidebar. Choose the account/org, then select **Only select repositories** and pick the repos you want PR-Agent to review (or **All repositories** if that is your intent). Click **Install**.

You should see the App listed under the account's **Settings > Applications > Installed GitHub Apps**.

**Step 11 — Confirm webhook reachability.** Open the App's **Advanced** tab and look at **Recent Deliveries**. GitHub sends a `ping` event on installation. You should see a delivery with response **200**. If you see:

- **Couldn't connect / timeout** → the tunnel or pod is not up; see `setup.html` and `recovery.html`.
- **A 4xx other than from PR-Agent** → re-check the Webhook URL path is exactly `/api/v1/github_webhooks`.
- **A delivery that reached PR-Agent but failed signature** → the webhook secret in GitHub and in `GITHUB__WEBHOOK_SECRET` disagree; re-fetch secrets (`recovery.html`).

**Step 12 — End-to-end check.** Open a pull request on an installed repository. Within a few seconds PR-Agent should post a review comment generated by DeepSeek **v4-pro**. If it does not, redeliver the `pull_request` event from **Recent Deliveries** and watch the container logs (`journalctl --user -u pr-agent -f`) on the server.

---

## What goes where (summary)

After this runbook you hold three GitHub-issued values plus your DeepSeek key. Carry them into the Secrets Store exactly as named — the container env targets are fixed by the quadlet (`deploy/quadlet/pr-agent.container`) and `deploy/config.env`:

| You have | Store as | Becomes env |
|---|---|---|
| App ID (number) | `pr-agent-github-app-id` | `GITHUB_APP__APP_ID` |
| Private key (.pem) | `pr-agent-github-app-key` | `GITHUB_APP__PRIVATE_KEY` |
| Webhook secret (hex) | `pr-agent-webhook-secret` | `GITHUB__WEBHOOK_SECRET` |
| DeepSeek API key | `pr-agent-deepseek-key` | `OPENAI__KEY` |

Proceed to `cloudflare.html` to populate the Secrets Store, mark the webhook hostname Access-exempt, and deploy the broker.
