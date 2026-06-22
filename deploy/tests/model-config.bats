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
LOADER="${REPO}/pr_agent/config_loader.py"
APPLY="${REPO}/patches/apply.sh"

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

@test "the asserting codemod is a no-op success against the real source tree" {
  run bash "$APPLY" "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no source rewrite required"* ]]
}

@test "the asserting codemod is idempotent (second run also succeeds)" {
  bash "$APPLY" "$REPO"
  run bash "$APPLY" "$REPO"
  [ "$status" -eq 0 ]
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
