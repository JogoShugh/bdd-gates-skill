#!/usr/bin/env bash
# PreToolUse (Bash). For wrapper-logged stacks: blocks running the raw test
# command, because a raw run leaves no BDD_RUN fact and the pre-commit check
# then cannot see the red/green sequence. No-op unless bddRawCommandRegex is set.
set -o pipefail
. "$(dirname "$0")/lib.sh"

bdd_has_config || exit 0
regex=$(bdd_value bddRawCommandRegex)
[ -n "$regex" ] || exit 0

command=$(jq -r '.tool_input.command // empty')
[ -n "$command" ] || exit 0
case "$command" in *bdd-gates/bdd-run.sh*) exit 0 ;; esac

if printf '%s\n' "$command" | grep -Eq -- "$regex"; then
  echo "Blocked: run tests through .claude/bdd-gates/bdd-run.sh [extra args] so the BDD_RUN result is logged." >&2
  exit 2
fi
exit 0
