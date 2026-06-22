# CodeVibes deployment — verification entrypoints. We verify only files we add.
SHELL := /bin/bash
SHELLSCRIPTS := $(shell find deploy patches -name '*.sh' 2>/dev/null)

.PHONY: help test verify verify-shell verify-yaml verify-docker verify-actions verify-quadlet verify-caddy verify-worker verify-cloudinit

help: ## list targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-16s %s\n",$$1,$$2}'

test: ## run all bats + worker unit tests
	@bats $$(find deploy patches -name '*.bats')
	@if [ -d secrets-broker ]; then cd secrets-broker && npm test; fi

verify: verify-shell verify-yaml verify-docker verify-actions verify-quadlet verify-caddy verify-worker ## run every (fast) verifier

verify-cloudinit: ## INTEGRATION: boot a fresh OrbStack machine and run the real cloud-init end-to-end (~3 min). REQUIRED after cloud-init changes.
	@if command -v orb >/dev/null; then bash deploy/tests/cloud-init-integration.sh; else echo "OrbStack (orb) not available — cannot run cloud-init integration test"; fi

verify-shell: ## shellcheck our scripts
	@if [ -n "$(SHELLSCRIPTS)" ]; then shellcheck $(SHELLSCRIPTS); else echo "no shell scripts yet"; fi

verify-yaml: ## yamllint our yaml + cloud-init schema
	@find deploy .github -name '*.yml' -o -name '*.yaml' 2>/dev/null | xargs -r yamllint -d relaxed

verify-docker: ## hadolint our Dockerfiles
	@for f in codevibes-backend/Dockerfile Dockerfile.web; do [ -f $$f ] && hadolint $$f || true; done

verify-actions: ## actionlint workflows
	@if ls .github/workflows/*.yml >/dev/null 2>&1; then actionlint; else echo "no workflows yet"; fi

verify-quadlet: ## quadlet dry-run
	@if ls deploy/quadlet/*.container >/dev/null 2>&1; then \
	  QUADLET=$$(command -v quadlet || echo /usr/libexec/podman/quadlet); \
	  if [ -x "$$QUADLET" ]; then QUADLET_UNIT_DIRS=$$(pwd)/deploy/quadlet $$QUADLET -dryrun -user; \
	  else echo "quadlet not installed (run in OrbStack/Linux)"; fi; else echo "no quadlet units yet"; fi

verify-caddy: ## caddy validate
	@if [ -f Caddyfile ]; then caddy validate --config Caddyfile --adapter caddyfile; else echo "no Caddyfile yet"; fi

verify-worker: ## worker lint + dry-run deploy
	@if [ -d secrets-broker ]; then cd secrets-broker && npx eslint src && npx wrangler deploy --dry-run; else echo "no worker yet"; fi
