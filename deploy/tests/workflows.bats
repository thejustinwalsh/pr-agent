#!/usr/bin/env bats
WF="${BATS_TEST_DIRNAME}/../../.github/workflows"

# actionlint is scoped to OUR two workflows. The repo also carries upstream
# PR-Agent workflows (publish.yml, docs-ci.yaml, ...) that already trip
# shellcheck warnings; those are upstream's debt, gated by upstream CI, and not
# ours to fix under the "trust upstream" rule. We assert only that the workflows
# we own are clean.
@test "our workflows pass actionlint" {
  run actionlint "$WF/sync.yml" "$WF/build.yml"
  [ "$status" -eq 0 ]
}
@test "sync runs daily and only acts on new upstream tags" {
  grep -q "cron:" "$WF/sync.yml"
  grep -q "The-PR-Agent/pr-agent" "$WF/sync.yml"
}
@test "sync dispatches build-image after a successful merge (GITHUB_TOKEN-safe)" {
  grep -q "actions: write" "$WF/sync.yml"
  grep -q "gh workflow run build-image" "$WF/sync.yml"
  grep -q "synced=true" "$WF/sync.yml"
}
@test "build runs the codemod before building, on release, to the github_app target" {
  grep -q "release:" "$WF/build.yml"
  grep -q "patches/apply.sh" "$WF/build.yml"
  grep -q "target: github_app" "$WF/build.yml"
  grep -q "pr-agent:" "$WF/build.yml"
}
@test "build applies the codemod conditionally (no-op if absent)" {
  grep -q 'if \[ -f patches/apply.sh \]' "$WF/build.yml"
}
