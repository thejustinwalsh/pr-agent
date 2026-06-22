# PR-Agent (self-hosted on Hetzner) — project working agreement

This is a fork of PR-Agent (`The-PR-Agent/pr-agent`, the active community line) deployed as a **self-hosted GitHub-App webhook server** on a Hetzner box, behind Cloudflare Tunnel, running DeepSeek **v4-pro** for PR code review. The deployment is a near-copy of the CodeVibes production setup — that battle-tested scaffold lives at `/Users/tjw/Developer/codevibes` (`deploy/`, `secrets-broker/`, `.github/workflows/`, `docs/superpowers/`) and is the reuse baseline. Authoritative design: `docs/superpowers/specs/2026-06-21-pr-agent-deployment-design.md`.

## How we work

Binding for every agent in this repo.

1. **Per task: tests → feature → verifications.** Write tests first (must fail for the right reason), implement, then run verifications (shellcheck/hadolint/actionlint/yamllint/`sshd -T`/quadlet dry-run/bats). Both green before done.
2. **Do not stop between steps or phases — loop until done.** Loop within a task until green; loop across the plan until every task is complete. The plan is agreed up front.
3. **Mid-implementation decisions get logged, not negotiated.** Append to `docs/superpowers/DECISIONS-LOG.md` (append-only). A review agent reconciles it at the end.
4. **"Complete" = deployable.** Done when a fresh Hetzner box from cloud-init comes up, the webhook registers with GitHub, and a PR triggers a DeepSeek v4-pro review. Verified end-to-end as far as possible without live cloud (OrbStack integration tier).
5. **Tests: mocks, happy path, catastrophic edges.** Mock external systems (GitHub, DeepSeek, ghcr, podman, Cloudflare). Cover happy path + dangerous edges (secret leak, failed rollback, disk fill, webhook auth bypass).

## What we add vs. trust

We add only deployment/infra files (`deploy/`, `secrets-broker/`, `.github/workflows/`, `docs/`) plus, where required, an **asserting codemod** (`patches/apply.sh`) against PR-Agent source — applied at build time, fail-loud on upstream drift. We **trust upstream PR-Agent code**; its own tests/CI gate it. We touch its source only for production necessity or to **force the DeepSeek v4-pro model** if config/env doesn't reliably pin it (a known PR-Agent quirk).

## Verification tiers (REQUIRED; same as CodeVibes)

- **Unit tier (macOS):** bats, shellcheck, yamllint, hadolint, actionlint, `caddy validate`, worker vitest. `make verify` / `make test`.
- **Container/systemd tier (OrbStack Ubuntu 26.04 machine `codevibes-test`, mirrors Hetzner):** `podman build`, `quadlet -dryrun`, rootless podman + systemd + linger, local pod smoke (webhook responds on :3000). Do NOT install Podman on macOS.
- **Integration tier (REQUIRED after any cloud-init change):** `make verify-cloudinit` boots a fresh OrbStack machine with the rendered cloud-init as real user-data and asserts host state via `sshd -T`, ufw, fail2ban, user/linger, clone, **executable scripts**, units. Lint/render does NOT catch runcmd bugs — this does.

Hard-won cloud-init lessons to carry over (all bit us in CodeVibes): `ufw` never with `--force` on `allow`/`default`; `users:` must include `- default`; sshd hardening via a `sshd_config.d/*.conf` drop-in (not sed on the main file); install `openssh-server`; scripts must be committed `+x`; Quadlet containers need `ContainerName=` and `deploy.sh` must restart the **container** services (not the pod); list ghcr tags via the REST API (no skopeo); webhook smoke must work on first boot.

## Git

- Commit per task, small. Identity/no-AI-trailer per `~/.claude/CLAUDE.md`.
- `origin` = `thejustinwalsh/pr-agent` (fork), `upstream` = `The-PR-Agent/pr-agent`. Default/working branch: `production`.
