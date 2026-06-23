#!/usr/bin/env bats
# WS — embedded review defaults. The good defaults must ship INSIDE the deployment
# image so any repo inherits them and a repo only ever ADDS its own extra_instructions
# on top (never restates the defaults). The asserting codemod (patches/apply.sh):
#   1. bakes a generic, stack-agnostic reviewer methodology into the system prompt
#      template, immediately BEFORE the `{%- if extra_instructions %}` block — so it
#      is always present and the user's extra_instructions still append after it.
#   2. bakes the matching suggestion methodology into the improve prompt template.
#   3. sets the tuning defaults in configuration.toml (the LOWEST precedence layer,
#      so a repo's .pr_agent.toml can still override them; process env stays highest).
# Build-time edits to a COPY; the committed tree stays pristine.

REPO="${BATS_TEST_DIRNAME}/.."
APPLY="${REPO}/patches/apply.sh"
RVP_SRC="${REPO}/pr_agent/settings/pr_reviewer_prompts.toml"
CSP_SRC="${REPO}/pr_agent/settings/code_suggestions/pr_code_suggestions_prompts.toml"
CFG_SRC="${REPO}/pr_agent/settings/configuration.toml"

_mkroot() {
  local r; r="$(mktemp -d)"
  mkdir -p "$r/pr_agent/servers" "$r/pr_agent/settings/code_suggestions" "$r/pr_agent/algo/ai_handlers"
  cp "${REPO}/pr_agent/algo/__init__.py"                      "$r/pr_agent/algo/__init__.py"
  cp "${REPO}/pr_agent/algo/ai_handlers/litellm_ai_handler.py" "$r/pr_agent/algo/ai_handlers/litellm_ai_handler.py"
  cp "${REPO}/pr_agent/algo/pr_processing.py"                 "$r/pr_agent/algo/pr_processing.py"
  cp "${REPO}/pr_agent/config_loader.py"                      "$r/pr_agent/config_loader.py"
  cp "${REPO}/pr_agent/servers/github_app.py"                 "$r/pr_agent/servers/github_app.py"
  cp "$CFG_SRC"                                               "$r/pr_agent/settings/configuration.toml"
  cp "$RVP_SRC"                                               "$r/pr_agent/settings/pr_reviewer_prompts.toml"
  cp "$CSP_SRC"                                               "$r/pr_agent/settings/code_suggestions/pr_code_suggestions_prompts.toml"
  echo "$r"
}

# The methodology must land INSIDE the system prompt and BEFORE the extra_instructions
# block — i.e. the user's per-repo instructions are layered on top of it.
@test "reviewer methodology is baked into the prompt BEFORE the extra_instructions block" {
  root="$(_mkroot)"; bash "$APPLY" "$root"
  f="$root/pr_agent/settings/pr_reviewer_prompts.toml"
  grep -Fq "Review methodology (apply before producing the output):" "$f"
  # methodology line number must precede the extra_instructions injection line
  meth="$(grep -n 'Review methodology (apply before producing the output):' "$f" | head -1 | cut -d: -f1)"
  inj="$(grep -n '{%- if extra_instructions %}' "$f" | head -1 | cut -d: -f1)"
  rm -rf "$root"
  [ "$meth" -lt "$inj" ]
}

@test "suggestion methodology is baked into the improve prompt before extra_instructions" {
  root="$(_mkroot)"; bash "$APPLY" "$root"
  f="$root/pr_agent/settings/code_suggestions/pr_code_suggestions_prompts.toml"
  grep -Fq "Suggestion methodology (apply before producing the output):" "$f"
  meth="$(grep -n 'Suggestion methodology (apply before producing the output):' "$f" | head -1 | cut -d: -f1)"
  inj="$(grep -n '{%- if extra_instructions %}' "$f" | head -1 | cut -d: -f1)"
  rm -rf "$root"
  [ "$meth" -lt "$inj" ]
}

@test "patched prompt templates are still valid TOML" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  root="$(_mkroot)"; bash "$APPLY" "$root"
  run python3 -c "import tomllib,sys; [tomllib.load(open(p,'rb')) for p in sys.argv[1:]]" \
    "$root/pr_agent/settings/pr_reviewer_prompts.toml" \
    "$root/pr_agent/settings/code_suggestions/pr_code_suggestions_prompts.toml"
  rm -rf "$root"
  [ "$status" -eq 0 ]
}

@test "tuning defaults are set in configuration.toml at the right sections" {
  root="$(_mkroot)"; bash "$APPLY" "$root"
  cfg="$root/pr_agent/settings/configuration.toml"
  run python3 - "$cfg" <<'PY'
import tomllib, sys
c = tomllib.load(open(sys.argv[1], "rb"))
assert c["config"]["reasoning_effort"] == "high", c["config"]["reasoning_effort"]
assert c["config"]["max_model_tokens"] == 1000000, c["config"]["max_model_tokens"]
assert c["config"]["patch_extra_lines_before"] == 8
assert c["config"]["patch_extra_lines_after"] == 3
assert c["pr_reviewer"]["num_max_findings"] == 6
assert c["pr_reviewer"]["require_can_be_split_review"] is True
assert c["pr_code_suggestions"]["suggestions_score_threshold"] == 5
# the section-aware patch must NOT touch the same-named key in [pr_custom_prompt]
assert c["pr_custom_prompt"]["suggestions_score_threshold"] == 0, "clobbered pr_custom_prompt"
print("ok")
PY
  rm -rf "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "embedded-defaults codemod is idempotent" {
  root="$(_mkroot)"; bash "$APPLY" "$root"
  run bash "$APPLY" "$root"
  [ "$status" -eq 0 ]
  f="$root/pr_agent/settings/pr_reviewer_prompts.toml"
  [ "$(grep -c 'Review methodology (apply before producing the output):' "$f")" -eq 1 ]
  [ "$(grep -c 'reasoning_effort = "high"' "$root/pr_agent/settings/configuration.toml")" -eq 1 ]
  rm -rf "$root"
}

@test "embedded-defaults codemod fails loudly if the prompt injection anchor drifts" {
  root="$(_mkroot)"
  f="$root/pr_agent/settings/pr_reviewer_prompts.toml"
  grep -v '{%- if extra_instructions %}' "$f" > "$f.tmp"; mv "$f.tmp" "$f"
  run bash "$APPLY" "$root"
  rm -rf "$root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"re-investigate"* ]]
}

@test "embedded-defaults codemod fails loudly if a tuning key drifts out of configuration.toml" {
  root="$(_mkroot)"
  cfg="$root/pr_agent/settings/configuration.toml"
  grep -v 'num_max_findings' "$cfg" > "$cfg.tmp"; mv "$cfg.tmp" "$cfg"
  run bash "$APPLY" "$root"
  rm -rf "$root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"re-investigate"* ]]
}
