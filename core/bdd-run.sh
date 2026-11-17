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

here=$(cd "$(dirname "$0")" && pwd)
cd "$(bdd_root)" || exit 1
# bddMessages: where the runner writes Cucumber's message stream; cleared first, so a run that
# never reaches the scenarios cannot be judged by an older stream.
messages=$(bdd_value bddMessages)
[ -n "$messages" ] && rm -f "$messages"
if [ $# -gt 0 ]; then
  bash -c "$cmd $*"
else
  bash -c "$cmd"
fi
ec=$?

status=PASS
[ $ec -eq 0 ] || status=FAIL
"$here/record-run.sh" "$status" "exit=$ec" ${messages:+"messages=$messages"}
exit $ec
