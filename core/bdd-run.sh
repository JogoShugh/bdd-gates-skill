#!/usr/bin/env bash
# Runs the BDD suite and records "BDD_RUN PASS|FAIL" in the event log, pass or
# fail. For stacks with bddLogging "wrapper" (no native build hook that runs
# after a failed test task). Extra args are appended to bddCommand.
# Exits with the suite's own exit code.
set -o pipefail
. "$(dirname "$0")/lib.sh"

bdd_has_config || { echo "bdd-run: no $(bdd_config)" >&2; exit 1; }
cmd=$(bdd_value bddCommand)
[ -n "$cmd" ] || { echo "bdd-run: bddCommand not set in $(bdd_config)" >&2; exit 1; }

cd "$(bdd_root)" || exit 1
if [ $# -gt 0 ]; then
  bash -c "$cmd $*"
else
  bash -c "$cmd"
fi
ec=$?

if [ $ec -eq 0 ]; then
  bdd_append "BDD_RUN PASS exit=0"
else
  bdd_append "BDD_RUN FAIL exit=$ec"
fi
exit $ec
