#!/usr/bin/env bash
# Live proof that the Gherkin-first gate works in an installed repo:
#   1. a production write is BLOCKED with no feature change in flight,
#   2. the same write is ALLOWED once a feature file is touched.
# Feeds synthetic hook payloads to the installed script; writes no production
# code. Creates one probe feature file and removes it again.
#   verify-install.sh [target-repo-dir]
set -uo pipefail

target=$(cd "${1:-.}" && pwd)
gate=$target/.claude/bdd-gates/gherkin-first.sh
[ -x "$gate" ] || { echo "not installed: $gate missing" >&2; exit 1; }
export BDD_GATES_ROOT=$target
. "$target/.claude/bdd-gates/lib.sh"
bdd_load

probe_path() { printf '%s' "${1//\*/BddGatesProbe}"; }
prod=$(probe_path "${PROD_PATTERNS[0]}")
bdd_is_prod "$prod" || { echo "probe path $prod is excluded; adjust prodPatterns" >&2; exit 1; }
feature=$(probe_path "${FEATURE_PATTERNS[0]}")

payload() { printf '{"tool_input":{"file_path":"%s/%s"}}' "$target" "$1"; }
fail=0

if bdd_features_dirty; then
  echo "SKIP  block check: feature files already in flight in $target"
else
  if payload "$prod" | "$gate" 2>/dev/null; then
    echo "FAIL  write to $prod was allowed with no feature change"; fail=1
  else
    echo "PASS  write to $prod blocked (no feature change)"
  fi
fi

[ -e "$target/$feature" ] && { echo "probe $feature already exists; aborting" >&2; exit 1; }
mkdir -p "$(dirname "$target/$feature")"
trap 'rm -f "$target/$feature"' EXIT
echo "Feature: bdd-gates probe" > "$target/$feature"
if payload "$prod" | "$gate" 2>/dev/null; then
  echo "PASS  write to $prod allowed once $feature changed"
else
  echo "FAIL  write to $prod still blocked after touching $feature"; fail=1
fi
exit $fail
