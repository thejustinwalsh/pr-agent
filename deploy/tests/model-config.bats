#!/usr/bin/env bats
# WS-A: assert PR-Agent's model selection is env-overridable end-to-end, so the
# deployment env (CONFIG__MODEL / OPENAI__API_BASE / CONFIG__CUSTOM_MODEL_MAX_TOKENS)
# pins DeepSeek deepseek-v4-pro without a source rewrite. Grep-level checks on the
# upstream source plus the asserting codemod, with one empirical dynaconf-precedence
# check when dynaconf + a venv are available.

REPO="${BATS_TEST_DIRNAME}/../.."
CONF="${REPO}/pr_agent/settings/configuration.toml"
PROC="${REPO}/pr_agent/algo/pr_processing.py"
LITE="${REPO}/pr_agent/algo/ai_handlers/litellm_ai_handler.py"
ALGO_INIT="${REPO}/pr_agent/algo/__init__.py"
LOADER="${REPO}/pr_agent/config_loader.py"
APPLY="${REPO}/patches/apply.sh"

# Copy the files apply.sh asserts/patches into a fresh temp ROOT, so codemod tests
# never mutate the committed source tree (the patch is build-time only).
_mkroot() {
  local r; r="$(mktemp -d)"
  mkdir -p "$r/pr_agent/servers" "$r/pr_agent/settings/code_suggestions" "$r/pr_agent/algo/ai_handlers"
  cp "$PROC"   "$r/pr_agent/algo/pr_processing.py"
  cp "$LITE"   "$r/pr_agent/algo/ai_handlers/litellm_ai_handler.py"
  cp "$ALGO_INIT" "$r/pr_agent/algo/__init__.py"  # codemod registers the DeepSeek model here
  cp "${REPO}/pr_agent/settings/pr_reviewer_prompts.toml" "$r/pr_agent/settings/pr_reviewer_prompts.toml"  # codemod bakes the reviewer methodology here
  cp "${REPO}/pr_agent/settings/code_suggestions/pr_code_suggestions_prompts.toml" "$r/pr_agent/settings/code_suggestions/pr_code_suggestions_prompts.toml"
  cp "$LOADER" "$r/pr_agent/config_loader.py"
  cp "$REPO/pr_agent/servers/github_app.py" "$r/pr_agent/servers/github_app.py"
  cp "$CONF"   "$r/pr_agent/settings/configuration.toml"
  echo "$r"
}

@test "configuration.toml ships a [config] model default we intend to OVERRIDE (not deepseek)" {
  grep -Eq '^\s*model\s*=' "$CONF"
  # The shipped default must NOT already be deepseek-v4-pro: our pinning is the env's job,
  # and if upstream ever defaults to it this test should be revisited deliberately.
  ! grep -Eq '^\s*model\s*=\s*"deepseek-v4-pro"' "$CONF"
}

@test "configuration.toml exposes custom_model_max_tokens (required for an unlisted model)" {
  # deepseek-v4-pro is not in MAX_TOKENS, so get_max_tokens() raises unless this is >0.
  grep -Eq '^\s*custom_model_max_tokens\s*=' "$CONF"
  grep -q 'custom_model_max_tokens' "${REPO}/pr_agent/algo/utils.py"
}

@test "regular model is resolved from config.model, not a hardcoded literal" {
  grep -Fq 'model = get_settings().config.model' "$PROC"
}

@test "the resolved model is forwarded verbatim into the litellm request kwargs" {
  grep -Fq '"model": model,' "$LITE"
}

@test "api_base is resolved from openai.api_base (OPENAI__API_BASE) and forwarded to litellm" {
  grep -Fq 'litellm.api_base = get_settings().openai.api_base' "$LITE"
  grep -Fq '"api_base": self.api_base,' "$LITE"
}

@test "dynaconf is built with the env_loader so SECTION__KEY env vars override the TOML" {
  grep -Fq 'dynaconf.loaders.env_loader' "$LOADER"
}

@test "the codemod applies cleanly against a copy of the source tree" {
  root="$(_mkroot)"
  run bash "$APPLY" "$root"
  rm -rf "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no source rewrite required"* ]]           # model invariants hold (no model rewrite)
  [[ "$output" == *"draft auto-feedback codemod applied"* ]]  # draft patch applied
}

@test "the codemod patches the draft gate to honor feedback_on_draft_pr" {
  root="$(_mkroot)"
  bash "$APPLY" "$root"
  grep -Fq 'not get_settings().github_app.feedback_on_draft_pr' "$root/pr_agent/servers/github_app.py"
  grep -Eq '^feedback_on_draft_pr = false' "$root/pr_agent/settings/configuration.toml"
  rm -rf "$root"
}

@test "the codemod is idempotent (second run succeeds, no double-apply)" {
  root="$(_mkroot)"
  bash "$APPLY" "$root"
  run bash "$APPLY" "$root"
  count="$(grep -c 'feedback_on_draft_pr' "$root/pr_agent/settings/configuration.toml")"
  rm -rf "$root"
  [ "$status" -eq 0 ]
  [ "$count" -eq 1 ]
}

@test "the codemod fails loudly if the draft gate drifts" {
  root="$(_mkroot)"
  grep -v 'pull_request.get("draft"' "$root/pr_agent/servers/github_app.py" > "$root/ga.tmp"
  mv "$root/ga.tmp" "$root/pr_agent/servers/github_app.py"
  run bash "$APPLY" "$root"
  rm -rf "$root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"draft gate line not found"* ]]
}

@test "the asserting codemod fails loudly if the model-selection path drifts" {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/pr_agent/algo/ai_handlers"
  cp "$LOADER" "$tmp/pr_agent/config_loader.py"
  cp "$LITE" "$tmp/pr_agent/algo/ai_handlers/litellm_ai_handler.py"
  # Simulate upstream drift: config.model line rewritten.
  printf '%s\n' 'model = "deepseek-v4-pro"  # hardcoded by drift' \
    > "$tmp/pr_agent/algo/pr_processing.py"
  run bash "$APPLY" "$tmp"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  [[ "$output" == *"re-investigate WS-A"* ]]
}

@test "EMPIRICAL: dynaconf env vars override the TOML model default" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  venv="$(mktemp -d)"
  python3 -m venv "$venv" >/dev/null 2>&1 || { rm -rf "$venv"; skip "cannot create venv"; }
  "$venv/bin/pip" install -q dynaconf >/dev/null 2>&1 || { rm -rf "$venv"; skip "cannot install dynaconf"; }

  work="$(mktemp -d)"
  mkdir -p "$work/settings"
  cat > "$work/settings/configuration.toml" <<'TOML'
[config]
model="gpt-5.5-2026-04-23"
custom_model_max_tokens=-1
[openai]
TOML
  cat > "$work/repro.py" <<'PY'
from os.path import abspath, dirname, join
from dynaconf import Dynaconf
d = dirname(abspath(__file__))
s = Dynaconf(envvar_prefix=False, load_dotenv=False,
             settings_files=["configuration.toml"],
             core_loaders=['TOML'], loaders=['dynaconf.loaders.env_loader'],
             root_path=join(d, "settings"), merge_enabled=True)
print(s.config.model, s.get("openai.api_base"), s.config.custom_model_max_tokens)
PY

  default_out="$("$venv/bin/python" "$work/repro.py")"
  override_out="$(CONFIG__MODEL=deepseek-v4-pro \
    OPENAI__API_BASE=https://api.deepseek.com \
    CONFIG__CUSTOM_MODEL_MAX_TOKENS=128000 \
    "$venv/bin/python" "$work/repro.py")"

  rm -rf "$venv" "$work"

  [[ "$default_out" == "gpt-5.5-2026-04-23 None -1" ]]
  [[ "$override_out" == "deepseek-v4-pro https://api.deepseek.com 128000" ]]
}
