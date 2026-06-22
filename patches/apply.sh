#!/usr/bin/env bash
# Asserting codemod: PR-Agent source edits applied at build time, fail-loud on
# upstream drift. Idempotent. Fails if an asserted invariant is absent.
#
# Usage: apply.sh [REPO_ROOT]   (default: .)
#
# POSIX-safe (set -eu, no pipefail) so it runs under bash, dash (CI `sh`), and
# busybox ash (Alpine `RUN sh ...` in a Dockerfile).
#
# WORKSTREAM A — model forcing.
# Investigation verdict: NO source rewrite is required. PR-Agent never hardcodes
# the model in its call path. The model string flows untouched from settings:
#
#   get_settings().config.model
#     -> pr_agent/algo/pr_processing.py:_get_all_models (line ~347)
#     -> retry_with_fallback_models -> f(model)
#     -> LiteLLMAIHandler.chat_completion(model=...) -> litellm kwargs["model"]
#       (pr_agent/algo/ai_handlers/litellm_ai_handler.py:465)
#
# and the API base flows from settings the same way:
#
#   get_settings().openai.api_base
#     -> litellm.api_base / self.api_base
#       (litellm_ai_handler.py:150-152) -> kwargs["api_base"] (line 469)
#
# Dynaconf is built with the env_loader and merge_enabled in
# pr_agent/config_loader.py, so the deployment env vars
#   CONFIG__MODEL=deepseek-v4-pro
#   OPENAI__API_BASE=https://api.deepseek.com
#   OPENAI__KEY=<secret>
#   CONFIG__CUSTOM_MODEL_MAX_TOKENS=<ctx>
# take precedence over settings/configuration.toml end-to-end. Verified
# empirically against dynaconf and asserted at grep level in
# deploy/tests/model-config.bats.
#
# This script is therefore a NO-OP codemod today. It exists to (a) document the
# above wiring as the contract we depend on and (b) FAIL LOUDLY if a future
# upstream sync introduces a hardcoded model/api_base default in the call path,
# which would silently un-pin our DeepSeek configuration. If any assertion here
# trips, the env-override design must be re-investigated before shipping.
set -eu
ROOT="${1:-.}"

# assert_present FILE LITERAL DESC
# Fails unless LITERAL appears at least once in FILE. Used to pin the invariants
# our env-override strategy relies on, so upstream drift is caught at build time.
assert_present() {
  file="$1"; lit="$2"; desc="$3"
  [ -f "$file" ] || { echo "apply.sh: missing file $file ($desc)" >&2; return 1; }
  if ! grep -F -q -- "$lit" "$file"; then
    echo "apply.sh: $file: expected to find [$lit] ($desc) but it is absent -- upstream may have changed the model-selection path; re-investigate WS-A before shipping" >&2
    return 1
  fi
}

# The regular-path model comes from config.model (env-overridable), not a literal.
assert_present "$ROOT/pr_agent/algo/pr_processing.py" \
  "model = get_settings().config.model" \
  "regular model resolved from config.model (env-overridable)"

# The model string is forwarded verbatim into the litellm request kwargs.
assert_present "$ROOT/pr_agent/algo/ai_handlers/litellm_ai_handler.py" \
  '"model": model,' \
  "model forwarded unmodified to litellm kwargs"

# The API base is taken from openai.api_base (env-overridable via OPENAI__API_BASE).
assert_present "$ROOT/pr_agent/algo/ai_handlers/litellm_ai_handler.py" \
  "litellm.api_base = get_settings().openai.api_base" \
  "api_base resolved from openai.api_base (env-overridable)"

# api_base is forwarded into the litellm request kwargs.
assert_present "$ROOT/pr_agent/algo/ai_handlers/litellm_ai_handler.py" \
  '"api_base": self.api_base,' \
  "api_base forwarded to litellm kwargs"

# Dynaconf is constructed with the env loader so SECTION__KEY env vars take
# precedence over the TOML defaults. This is the linchpin of the no-patch design.
assert_present "$ROOT/pr_agent/config_loader.py" \
  "dynaconf.loaders.env_loader" \
  "dynaconf env_loader present (env vars override TOML)"

echo "apply.sh: model-forcing invariants hold; no source rewrite required (env pins the model)"
