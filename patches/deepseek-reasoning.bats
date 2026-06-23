#!/usr/bin/env bats
# WS — DeepSeek v4-pro reasoning. The asserting build-time codemod (patches/apply.sh)
# must register the deployed model string `openai/deepseek-v4-pro` so PR-Agent actually
# drives DeepSeek's thinking mode:
#   1. MAX_TOKENS                      -> 1000000 (v4-pro = 1M input context)
#   2. SUPPORT_REASONING_EFFORT_MODELS -> so the handler SENDS reasoning_effort
#   3. NO_SUPPORT_TEMPERATURE_MODELS   -> thinking mode ignores temperature
#   4. litellm handler                 -> inject extra_body {"thinking": {"type": "enabled"}}
#      and allow reasoning_effort through litellm for the OpenAI-compatible endpoint.
# Without (2)+(4) the model never thinks; without (1) the 1M window is unknown.
# These are build-time edits to a COPY of the vendored source; the committed tree
# stays pristine (we trust upstream), so every test runs apply.sh in a temp ROOT.

REPO="${BATS_TEST_DIRNAME}/.."
ALGO="${REPO}/pr_agent/algo/__init__.py"
LITE="${REPO}/pr_agent/algo/ai_handlers/litellm_ai_handler.py"
PROC="${REPO}/pr_agent/algo/pr_processing.py"
LOADER="${REPO}/pr_agent/config_loader.py"
CONF="${REPO}/pr_agent/settings/configuration.toml"
GA="${REPO}/pr_agent/servers/github_app.py"
APPLY="${REPO}/patches/apply.sh"

# Copy every file apply.sh asserts or patches into a fresh temp ROOT so the codemod
# never mutates the committed source tree (the patch is build-time only).
_mkroot() {
  local r; r="$(mktemp -d)"
  mkdir -p "$r/pr_agent/servers" "$r/pr_agent/settings/code_suggestions" "$r/pr_agent/algo/ai_handlers"
  cp "$ALGO"   "$r/pr_agent/algo/__init__.py"
  cp "$LITE"   "$r/pr_agent/algo/ai_handlers/litellm_ai_handler.py"
  cp "$PROC"   "$r/pr_agent/algo/pr_processing.py"
  cp "$LOADER" "$r/pr_agent/config_loader.py"
  cp "$GA"     "$r/pr_agent/servers/github_app.py"
  cp "$CONF"   "$r/pr_agent/settings/configuration.toml"
  cp "${REPO}/pr_agent/settings/pr_reviewer_prompts.toml" "$r/pr_agent/settings/pr_reviewer_prompts.toml"
  cp "${REPO}/pr_agent/settings/code_suggestions/pr_code_suggestions_prompts.toml" "$r/pr_agent/settings/code_suggestions/pr_code_suggestions_prompts.toml"
  echo "$r"
}

@test "codemod registers openai/deepseek-v4-pro in MAX_TOKENS with the 1M context window" {
  root="$(_mkroot)"
  bash "$APPLY" "$root"
  init="$root/pr_agent/algo/__init__.py"
  # The entry must exist with the 1M value, inside the MAX_TOKENS dict.
  grep -Fq "'openai/deepseek-v4-pro': 1000000" "$init"
  rm -rf "$root"
}

@test "codemod adds openai/deepseek-v4-pro to SUPPORT_REASONING_EFFORT_MODELS" {
  root="$(_mkroot)"
  bash "$APPLY" "$root"
  init="$root/pr_agent/algo/__init__.py"
  # Assert the entry lands within the reasoning list (between its opening bracket and close).
  run awk '/SUPPORT_REASONING_EFFORT_MODELS = \[/{f=1} f&&/openai\/deepseek-v4-pro/{print "HIT"} /\]/{if(f)f=0}' "$init"
  rm -rf "$root"
  [[ "$output" == *"HIT"* ]]
}

@test "codemod adds openai/deepseek-v4-pro to NO_SUPPORT_TEMPERATURE_MODELS" {
  root="$(_mkroot)"
  bash "$APPLY" "$root"
  init="$root/pr_agent/algo/__init__.py"
  run awk '/NO_SUPPORT_TEMPERATURE_MODELS = \[/{f=1} f&&/openai\/deepseek-v4-pro/{print "HIT"} /\]/{if(f)f=0}' "$init"
  rm -rf "$root"
  [[ "$output" == *"HIT"* ]]
}

@test "codemod injects the DeepSeek thinking extra_body into the litellm handler" {
  root="$(_mkroot)"
  bash "$APPLY" "$root"
  lite="$root/pr_agent/algo/ai_handlers/litellm_ai_handler.py"
  grep -Fq '"thinking": {"type": "enabled"}' "$lite"
  # ...and it must be gated to deepseek models, not applied to every reasoning model.
  grep -Fq 'if "deepseek" in model' "$lite"
  rm -rf "$root"
}

@test "the patched litellm handler is still valid Python" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  root="$(_mkroot)"
  bash "$APPLY" "$root"
  run python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$root/pr_agent/algo/ai_handlers/litellm_ai_handler.py"
  status_lite=$status
  run python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$root/pr_agent/algo/__init__.py"
  status_init=$status
  rm -rf "$root"
  [ "$status_lite" -eq 0 ]
  [ "$status_init" -eq 0 ]
}

@test "the DeepSeek reasoning codemod is idempotent (second run does not double-insert)" {
  root="$(_mkroot)"
  bash "$APPLY" "$root"
  run bash "$APPLY" "$root"
  [ "$status" -eq 0 ]
  init="$root/pr_agent/algo/__init__.py"
  lite="$root/pr_agent/algo/ai_handlers/litellm_ai_handler.py"
  [ "$(grep -c "'openai/deepseek-v4-pro': 1000000" "$init")" -eq 1 ]
  [ "$(grep -c 'DeepSeek thinking-mode reasoning_effort' "$init")" -eq 1 ]
  [ "$(grep -c 'DeepSeek thinking-mode ignores temperature' "$init")" -eq 1 ]
  [ "$(grep -Fc '"thinking": {"type": "enabled"}' "$lite")" -eq 1 ]
  rm -rf "$root"
}

@test "the DeepSeek reasoning codemod fails loudly if the reasoning-list anchor drifts" {
  root="$(_mkroot)"
  init="$root/pr_agent/algo/__init__.py"
  # Simulate upstream renaming the reasoning list.
  sed 's/SUPPORT_REASONING_EFFORT_MODELS = \[/SUPPORT_REASONING_MODELS_RENAMED = [/' "$init" > "$init.tmp"
  mv "$init.tmp" "$init"
  run bash "$APPLY" "$root"
  rm -rf "$root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"re-investigate"* ]]
}

@test "the DeepSeek reasoning codemod fails loudly if the handler reasoning_effort anchor drifts" {
  root="$(_mkroot)"
  lite="$root/pr_agent/algo/ai_handlers/litellm_ai_handler.py"
  grep -v 'kwargs\["reasoning_effort"\] = reasoning_effort' "$lite" > "$lite.tmp"
  mv "$lite.tmp" "$lite"
  run bash "$APPLY" "$root"
  rm -rf "$root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"re-investigate"* ]]
}
