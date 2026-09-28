#!/usr/bin/env bash
# PreToolUse (Edit|Write|MultiEdit). Blocks a write to production code unless
# a feature file already has an in-flight change. Exit 2 blocks the tool call
# and sends stderr back to Claude.
set -o pipefail
. "$(dirname "$0")/lib.sh"

file_path=$(bdd_hook_file_path)
[ -n "$file_path" ] || exit 0
bdd_has_config || exit 0
bdd_load

rel=$(bdd_rel "$file_path")
bdd_is_prod "$rel" || exit 0
bdd_features_dirty && exit 0

cat >&2 <<EOF
Blocked: about to modify production code ($rel) with no feature file change in this changeset yet.
Write or update the Gherkin scenario first, run the BDD suite to see it fail, then implement.
Feature patterns: $(bdd_list featurePatterns | tr '\n' ' ')
EOF
exit 2
