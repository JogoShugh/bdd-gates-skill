#!/usr/bin/env bash
# PostToolUse (Edit|Write|MultiEdit). Records MAIN_WRITE / FEATURE_WRITE facts
# in .claude/tdd-events.log for the pre-commit ordering check. Never blocks.
set -o pipefail
. "$(dirname "$0")/lib.sh"

file_path=$(bdd_hook_file_path)
[ -n "$file_path" ] || exit 0
bdd_has_config || exit 0
bdd_load

rel=$(bdd_rel "$file_path")
if bdd_is_prod "$rel"; then
  bdd_append "MAIN_WRITE $rel"
elif bdd_is_feature "$rel"; then
  bdd_append "FEATURE_WRITE $rel"
fi
exit 0
