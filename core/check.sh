#!/usr/bin/env bash
# Stop hook. Runs the stack's full check (tests, BDD, complexity, architecture).
# Exit 2 keeps Claude working until the build is green.
set -o pipefail
. "$(dirname "$0")/lib.sh"

bdd_has_config || exit 0
cmd=$(bdd_value checkCommand)
[ -n "$cmd" ] || exit 0

out=$(cd "$(bdd_root)" && bash -c "$cmd" 2>&1)
ec=$?
if [ $ec -ne 0 ]; then
  echo "Check gate failed ($cmd, exit $ec). Last 200 lines:" >&2
  echo "$out" | tail -n 200 >&2
  exit 2
fi
exit 0
