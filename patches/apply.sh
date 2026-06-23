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

# WORKSTREAM — draft PR auto-feedback.
# Upstream DOCUMENTS github_app.feedback_on_draft_pr (docs/docs/usage-guide/
# automations_and_usage.md) but never implemented it: the draft gate in
# should_process_pr_logic is hardcoded to skip every draft. Patch it to honor the
# documented setting, and add the default to configuration.toml. Idempotent;
# fail-loud if the target line drifts upstream.
GA="$ROOT/pr_agent/servers/github_app.py"
OLD='    if pull_request.get("draft", True) or pull_request.get("state") != "open":'
NEW='    if (pull_request.get("draft", True) and not get_settings().github_app.feedback_on_draft_pr) or pull_request.get("state") != "open":'
[ -f "$GA" ] || { echo "apply.sh: missing $GA (draft patch)" >&2; exit 1; }
if grep -Fq -- "$NEW" "$GA"; then
  echo "apply.sh: draft gate already honors feedback_on_draft_pr (idempotent)"
elif grep -Fq -- "$OLD" "$GA"; then
  tmp="$(mktemp)"
  awk -v old="$OLD" -v new="$NEW" '{ if ($0 == old) print new; else print }' "$GA" > "$tmp" && mv "$tmp" "$GA"
  grep -Fq -- "$NEW" "$GA" || { echo "apply.sh: draft patch failed to apply to $GA" >&2; exit 1; }
  echo "apply.sh: patched draft gate to honor github_app.feedback_on_draft_pr"
else
  echo "apply.sh: $GA: draft gate line not found -- upstream changed should_process_pr_logic; re-investigate the draft patch before shipping" >&2
  exit 1
fi

# Ensure the setting exists with a default so dynaconf resolves it (env overrides).
CFG="$ROOT/pr_agent/settings/configuration.toml"
[ -f "$CFG" ] || { echo "apply.sh: missing $CFG (draft default)" >&2; exit 1; }
if ! grep -Fq 'feedback_on_draft_pr' "$CFG"; then
  if ! grep -Eq '^handle_pr_actions = ' "$CFG"; then
    echo "apply.sh: $CFG: [github_app] handle_pr_actions anchor not found for feedback_on_draft_pr insert" >&2
    exit 1
  fi
  tmp="$(mktemp)"
  awk '1; /^handle_pr_actions = /{ print "feedback_on_draft_pr = false  # patched: enable auto tools on draft PRs (GITHUB_APP__FEEDBACK_ON_DRAFT_PR)" }' "$CFG" > "$tmp" && mv "$tmp" "$CFG"
  echo "apply.sh: added feedback_on_draft_pr default to configuration.toml"
fi

echo "apply.sh: draft auto-feedback codemod applied"

# WORKSTREAM — DeepSeek v4-pro reasoning (thinking mode).
# The deployed model string is `openai/deepseek-v4-pro` (litellm OpenAI-compatible
# prefix; see commit 45ae5592 and deploy/quadlet/pr-agent.container). Upstream only
# knows o3/o4 as reasoning models and only deepseek-reasoner as a no-temperature /
# system-folding model, so out of the box PR-Agent NEVER sends reasoning_effort for
# v4-pro and the model never enters thinking mode. DeepSeek's OpenAI-compatible API
# (https://api-docs.deepseek.com/guides/thinking_mode) requires BOTH reasoning_effort
# AND extra_body={"thinking": {"type": "enabled"}}, and ignores temperature in thinking
# mode. We register the model and inject the thinking enable. Idempotent; fail-loud on
# drift of any anchor. Build-time edits to the vendored copy; the committed tree stays
# pristine (we trust upstream).
ALGO="$ROOT/pr_agent/algo/__init__.py"
LITE="$ROOT/pr_agent/algo/ai_handlers/litellm_ai_handler.py"

# insert_after FILE ANCHOR LINE MARKER DESC
# Insert LINE immediately after the unique exact-match ANCHOR line. Idempotent via
# MARKER (skip if already present). Fail-loud if the ANCHOR has drifted upstream.
insert_after() {
  file="$1"; anchor="$2"; line="$3"; marker="$4"; desc="$5"
  [ -f "$file" ] || { echo "apply.sh: missing file $file ($desc)" >&2; return 1; }
  if grep -Fq -- "$marker" "$file"; then
    echo "apply.sh: $desc already applied (idempotent)"
    return 0
  fi
  if ! grep -Fq -- "$anchor" "$file"; then
    echo "apply.sh: $file: anchor [$anchor] not found ($desc) -- upstream drift; re-investigate the DeepSeek reasoning codemod before shipping" >&2
    return 1
  fi
  tmp="$(mktemp)"
  awk -v anchor="$anchor" -v line="$line" '{ print } $0 == anchor { print line }' "$file" > "$tmp" && mv "$tmp" "$file"
  if ! grep -Fq -- "$marker" "$file"; then
    echo "apply.sh: $file: failed to insert ($desc)" >&2
    return 1
  fi
  echo "apply.sh: $desc"
}

# 1. Register v4-pro's 1M input context window in MAX_TOKENS.
insert_after "$ALGO" \
  "MAX_TOKENS = {" \
  "    'openai/deepseek-v4-pro': 1000000,  # 1M input context (patched: DeepSeek v4-pro)" \
  "'openai/deepseek-v4-pro': 1000000" \
  "registered openai/deepseek-v4-pro = 1000000 in MAX_TOKENS"

# 2. Mark v4-pro as a reasoning model so the handler emits reasoning_effort.
insert_after "$ALGO" \
  "SUPPORT_REASONING_EFFORT_MODELS = [" \
  '    "openai/deepseek-v4-pro",  # patched: DeepSeek thinking-mode reasoning_effort' \
  "patched: DeepSeek thinking-mode reasoning_effort" \
  "registered openai/deepseek-v4-pro in SUPPORT_REASONING_EFFORT_MODELS"

# 3. Thinking mode ignores temperature -> do not send it.
insert_after "$ALGO" \
  "NO_SUPPORT_TEMPERATURE_MODELS = [" \
  '    "openai/deepseek-v4-pro",  # patched: DeepSeek thinking-mode ignores temperature' \
  "patched: DeepSeek thinking-mode ignores temperature" \
  "registered openai/deepseek-v4-pro in NO_SUPPORT_TEMPERATURE_MODELS"

# 4. Enable thinking mode on the request. Injected right after the handler sets
# reasoning_effort, inside `if model in self.support_reasoning_models:`, gated to
# deepseek so o3/o4 are untouched. extra_body carries the DeepSeek-specific thinking
# enable; allowed_openai_params lets reasoning_effort through litellm for the
# OpenAI-compatible (openai/<model>) endpoint.
HANDLER_ANCHOR='                    kwargs["reasoning_effort"] = reasoning_effort'
# Single-line, \n-delimited so awk -v expands the escapes on assignment (embedded
# real newlines are rejected by awk -v). 20-space indent keeps the block inside
# `if model in self.support_reasoning_models:`; the inner guard scopes it to deepseek.
HANDLER_BLOCK='                    # patched: DeepSeek thinking-mode. Enable reasoning via extra_body and\n                    # allow reasoning_effort through litellm for the OpenAI-compatible endpoint.\n                    if "deepseek" in model:\n                        kwargs["extra_body"] = {**kwargs.get("extra_body", {}), "thinking": {"type": "enabled"}}\n                        if "reasoning_effort" not in kwargs.get("allowed_openai_params", []):\n                            kwargs["allowed_openai_params"] = kwargs.get("allowed_openai_params", []) + ["reasoning_effort"]'
insert_after "$LITE" \
  "$HANDLER_ANCHOR" \
  "$HANDLER_BLOCK" \
  '"thinking": {"type": "enabled"}' \
  "injected DeepSeek thinking extra_body into the litellm handler"

echo "apply.sh: DeepSeek v4-pro reasoning codemod applied"

# WORKSTREAM — embedded review defaults.
# The good review defaults ship INSIDE the image so every reviewed repo inherits them
# and a repo only ever ADDS its own extra_instructions on top. Two parts:
#  (1) a generic, stack-agnostic reviewer/suggestion methodology baked into the system
#      prompt templates, inserted right BEFORE the `{%- if extra_instructions %}` block
#      so it is always present and the user's extra_instructions still append after it;
#  (2) tuning defaults written into configuration.toml — the LOWEST precedence layer, so
#      a repo's .pr_agent.toml can still override them (process env stays highest via
#      _reapply_env_overrides). Idempotent; fail-loud on drift; build-time only.
RVP="$ROOT/pr_agent/settings/pr_reviewer_prompts.toml"
CSP="$ROOT/pr_agent/settings/code_suggestions/pr_code_suggestions_prompts.toml"

# insert_before_from_file FILE ANCHOR BLOCKFILE MARKER DESC
# Insert the contents of BLOCKFILE immediately BEFORE the unique exact-match ANCHOR
# line. Idempotent via MARKER. Fail-loud if ANCHOR drifted. Reads the block from a
# file (not awk -v) so multi-line prompt text with any punctuation is safe.
insert_before_from_file() {
  file="$1"; anchor="$2"; bf="$3"; marker="$4"; desc="$5"
  [ -f "$file" ] || { echo "apply.sh: missing file $file ($desc)" >&2; return 1; }
  if grep -Fq -- "$marker" "$file"; then
    echo "apply.sh: $desc already applied (idempotent)"
    return 0
  fi
  if ! grep -Fq -- "$anchor" "$file"; then
    echo "apply.sh: $file: anchor [$anchor] not found ($desc) -- upstream drift; re-investigate the embedded-defaults codemod before shipping" >&2
    return 1
  fi
  tmp="$(mktemp)"
  awk -v anchor="$anchor" -v bf="$bf" '
    $0 == anchor { while ((getline l < bf) > 0) print l; close(bf) }
    { print }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
  if ! grep -Fq -- "$marker" "$file"; then
    echo "apply.sh: $file: failed to insert ($desc)" >&2
    return 1
  fi
  echo "apply.sh: $desc"
}

# set_default FILE SECTION KEY VALUE
# Set KEY = VALUE inside [SECTION] of a TOML file (section-aware, so duplicate keys in
# other sections are untouched). Idempotent; fail-loud if KEY is absent from SECTION.
set_default() {
  file="$1"; sec="$2"; key="$3"; val="$4"
  [ -f "$file" ] || { echo "apply.sh: missing file $file (set_default $sec.$key)" >&2; return 1; }
  if awk -v sec="$sec" -v key="$key" -v val="$val" '
       /^\[/{ insec = ($0 ~ "^\\["sec"\\]([ \t]|#|$)") }
       insec && $0 ~ "^[ \t]*"key"[ \t]*=[ \t]*"val"([ \t]|$|#)" { found=1 }
       END{ exit found?0:1 }' "$file"; then
    echo "apply.sh: [$sec] $key already = $val (idempotent)"
    return 0
  fi
  tmp="$(mktemp)"
  if awk -v sec="$sec" -v key="$key" -v val="$val" '
       /^\[/{ insec = ($0 ~ "^\\["sec"\\]([ \t]|#|$)") }
       { if (insec && $0 ~ "^[ \t]*"key"[ \t]*=") { print key" = "val"  # patched default"; done=1; next } print }
       END{ exit done?0:1 }' "$file" > "$tmp"; then
    mv "$tmp" "$file"
    echo "apply.sh: set default [$sec] $key = $val"
  else
    rm -f "$tmp"
    echo "apply.sh: $file: [$sec] $key not found -- upstream drift; re-investigate the embedded-defaults codemod before shipping" >&2
    return 1
  fi
}

# (1) Generic reviewer methodology -> baked into the system prompt before extra_instructions.
rev_block="$(mktemp)"
cat > "$rev_block" <<'EOF'
Review methodology (apply before producing the output):

Optimize for precision over volume. A small number of real, correctly located issues is worth far more than a long list of speculative ones. An empty key_issues_to_review list is a valid and good result for a clean PR; never invent issues to fill the list.

First, establish intent: from the title and description, state to yourself in one sentence what this PR is meant to do, then judge the changed lines against that intent and against the surrounding code they affect (the enclosing function, the symbols they call, and the callers they touch) rather than as isolated lines.

Then check each changed area against these categories, and raise an issue only where you find a concrete defect:
- Correctness and logic: wrong result on a realistic input, off-by-one, inverted condition, wrong default, mishandled return value.
- Security: command, SQL, path, or template injection; missing authentication or authorization; secrets or credentials exposed in code, logs, or output; unsafe deserialization; unvalidated external input.
- Concurrency and resources: race conditions, missing locks, unclosed files, sockets, or connections, leaked handles, unbounded growth.
- Error handling and edge cases: null, empty, and boundary inputs; unchecked errors; swallowed exceptions; partial-failure and rollback paths.
- API and contract compatibility: a changed signature, schema, configuration key, or wire format that breaks an existing caller.
- Tests: whether the change is covered by a test that would fail without it, and whether the dangerous edges are exercised.

Before reporting any issue, verify it: confirm the file and lines you cite contain the changed code; confirm you can name a concrete input or execution path that triggers the bad behavior, and if you cannot, you do not have a confirmed issue; confirm it is not already handled by nearby code; and confirm it is not a pure style or formatting point that a linter or formatter already enforces. Discard anything that fails these checks. Prefer reporting nothing over reporting a guess.

For each issue you do report, begin the issue_header with its severity (Critical, High, or Medium) and order the issues most severe first. Critical means data loss, a security breach, or a crash on a normal path; High means incorrect behavior on a realistic path or a broken contract; Medium means an edge-case or robustness gap. In issue_content, name the concrete triggering scenario and the specific, minimal fix. Do not raise purely cosmetic, naming, or formatting points unless they cause a real defect.


EOF
insert_before_from_file "$RVP" \
  "{%- if extra_instructions %}" \
  "$rev_block" \
  "Review methodology (apply before producing the output):" \
  "baked generic reviewer methodology into pr_reviewer_prompts.toml"
rm -f "$rev_block"

# (1b) Generic suggestion methodology -> baked into the improve prompt before extra_instructions.
sug_block="$(mktemp)"
cat > "$sug_block" <<'EOF'
Suggestion methodology (apply before producing the output):

Suggest only concrete, high-value improvements to the new code, each tied to specific changed lines. Quality over quantity: an empty code_suggestions list is a valid result. Prefer a few correct, important suggestions over many minor ones.

Offer a suggestion only when it fixes a real problem: a correctness or robustness defect (an unchecked error, an unhandled edge case, a leaked resource, a missing guard), a security weakness on a changed line (injection, an exposed secret, a missing authorization or validation check), or a missing test for a dangerous edge already in scope.

Do not suggest: renames, reordering, comments, or formatting that a linter or formatter already handles; wrapping code solely to swallow errors; refactors that change behavior without a correctness or security reason; or anything you cannot tie to a specific changed line with a concrete replacement. Do not repeat the same suggestion across multiple lines; give one per distinct issue.

For each suggestion, set existing_code to the exact lines being changed, give a minimal improved_code that applies cleanly, and keep suggestion_content specific about the problem it fixes.


EOF
insert_before_from_file "$CSP" \
  "{%- if extra_instructions %}" \
  "$sug_block" \
  "Suggestion methodology (apply before producing the output):" \
  "baked generic suggestions methodology into pr_code_suggestions_prompts.toml"
rm -f "$sug_block"

# (2) Tuning defaults in configuration.toml (lowest precedence; repos can still override).
set_default "$CFG" "config" "reasoning_effort" '"high"'        # DeepSeek thinks hard by default (inert for non-reasoning models)
set_default "$CFG" "config" "max_model_tokens" "1000000"       # use v4-pro's 1M input window; lifts the 32k clip
set_default "$CFG" "config" "patch_extra_lines_before" "8"     # more enclosing context per hunk (default 5)
set_default "$CFG" "config" "patch_extra_lines_after" "3"      # default 1
set_default "$CFG" "pr_reviewer" "num_max_findings" "6"        # widen recall beyond default 3
set_default "$CFG" "pr_reviewer" "require_can_be_split_review" "true"  # large-PR triage
set_default "$CFG" "pr_code_suggestions" "suggestions_score_threshold" "5"  # keep only medium/high suggestions (default 0 is noisy)

echo "apply.sh: embedded review-defaults codemod applied"
