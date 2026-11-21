#!/usr/bin/env bash
# PreToolUse (Edit|Write|MultiEdit). Blocks a write to production code unless
# a feature file already has an in-flight change, or the author switched
# refactor mode on (scripts/refactor-mode). Exit 2 blocks the tool call
# and sends stderr back to Claude.
set -o pipefail
. "$(dirname "$0")/lib.sh"

file_path=$(bdd_hook_file_path)
[ -n "$file_path" ] || exit 0
bdd_has_config || exit 0
bdd_load

rel=$(bdd_rel "$file_path")
bdd_is_prod "$rel" || exit 0
# The author switched refactor mode on: pre-commit checks its own terms.
bdd_refactor_on && exit 0

if bdd_features_dirty; then
  bdd_gherkin_ready || { bdd_gherkin_missing; exit 2; }
  changes=$(bdd_feature_changes worktree) || { echo "Blocked: the feature files could not be read." >&2; exit 2; }
  [ "$(bdd_scenarios_touched "$changes")" -gt 0 ] && exit 0
  {
    echo "Blocked: about to modify production code ($rel), but the feature files add or change no scenario."
    echo "Only descriptions, comments, tags, blank lines, order, moves, renames or removals differ from HEAD."
    jq -r '.invalid[] | "Cucumber cannot parse \(.path): \(.error)"' <<<"$changes"
    echo "Add a scenario, or change a scenario's steps or Examples, run the BDD suite to see it fail, then implement."
  } >&2
  exit 2
fi

cat >&2 <<EOF
Blocked: about to modify production code ($rel) with no feature file change in this changeset yet.
Write or update the Gherkin scenario first, run the BDD suite to see it fail, then implement.
Feature patterns: $(bdd_list featurePatterns | tr '\n' ' ')
EOF
exit 2
