#!/usr/bin/env bash
# Records one BDD run in the event log: "BDD_RUN PASS|FAIL [key=value...] [results=<file>]".
# The one writer of BDD_RUN lines, for the wrapper (bdd-run.sh) and for a stack's native hook alike.
#   record-run.sh PASS|FAIL [messages=<ndjson>] [within=<dir>] [key=value...]
# messages: Cucumber's message stream for the run (the "message" plugin). Reduced to one status per scenario
# (gherkin/features.mjs results), kept as .claude/bdd-runs/<stamp>-<n>.json, and the stream deleted, so the
# next run can never be judged by this one's. within: the build's folder, so a classpath uri finds its
# feature file. Other key=value pairs (module=, total=, reason=...) go into the line as they are.
set -o pipefail
. "$(dirname "$0")/lib.sh"

status=${1:-}
case "$status" in PASS|FAIL) ;; *) echo "usage: record-run.sh PASS|FAIL [messages=<file>] [within=<dir>] [k=v...]" >&2; exit 2 ;; esac
shift

messages=()
within=""
fields=()
for arg in "$@"; do
  case "$arg" in
    messages=*) messages+=("${arg#messages=}") ;;
    within=*) within=${arg#within=} ;;
    *) fields+=("$arg") ;;
  esac
done

root=$(bdd_root)
present=()
for m in ${messages[@]+"${messages[@]}"}; do [ -s "$m" ] && present+=("$m"); done
if [ ${#present[@]} -gt 0 ] && bdd_gherkin_ready; then
  runs=$root/.claude/bdd-runs
  mkdir -p "$runs"
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  n=1
  while [ -e "$runs/$stamp-$n.json" ]; do n=$((n + 1)); done
  out=$runs/$stamp-$n.json
  rel_within=""
  [ -n "$within" ] && rel_within=$(bdd_rel "$(cd "$within" 2>/dev/null && pwd || echo "$within")")
  if (cd "$root" && node --no-warnings "$(bdd_gherkin)/features.mjs" results ${rel_within:+--within "$rel_within"} \
    -- "${present[@]}") > "$out"; then
    fields+=("results=.claude/bdd-runs/$stamp-$n.json")
  else
    rm -f "$out"
  fi
  rm -f "${present[@]}"
fi

bdd_append "BDD_RUN $status${fields[@]+ ${fields[*]}}"
