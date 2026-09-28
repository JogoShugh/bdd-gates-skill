#!/usr/bin/env bash
# PostToolUse (Edit|Write|MultiEdit). Runs the stack's fast lint/complexity
# command after an edit to a lintable file. The edit already happened; exit 2
# only pushes the violation back to Claude so it is fixed before moving on.
set -o pipefail
. "$(dirname "$0")/lib.sh"

file_path=$(bdd_hook_file_path)
[ -n "$file_path" ] || exit 0
bdd_has_config || exit 0
bdd_load

cmd=$(bdd_value lintCommand)
[ -n "$cmd" ] || exit 0
bdd_is_lintable "$(bdd_rel "$file_path")" || exit 0

out=$(cd "$(bdd_root)" && bash -c "$cmd" 2>&1)
ec=$?
if [ $ec -ne 0 ]; then
  echo "Lint gate failed ($cmd, exit $ec):" >&2
  echo "$out" | tail -n 150 >&2
  exit 2
fi
exit 0
