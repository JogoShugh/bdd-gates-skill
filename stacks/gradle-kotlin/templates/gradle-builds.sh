#!/bin/sh
# Runs one Gradle task in every gated Gradle build of this repo, so a build added later is gated with no
# change to .claude/bdd-gates.json. A build is gated when its gradlew is tracked by git and its settings file
# includes build-logic, the convention plugins: applying them is how a build joins the gates. Other builds
# (an experiment, a vendored sample) are left alone. Exits non-zero when any build fails, after running them all.
#   scripts/gradle-builds.sh detekt
#   scripts/gradle-builds.sh check
#   scripts/gradle-builds.sh --list      the builds it would run, one per line
set -u
[ $# -gt 0 ] || { echo "usage: scripts/gradle-builds.sh <task> [args] | --list" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 2
builds=$(git ls-files -- '*gradlew' | while read -r wrapper; do
  dir=$(dirname "$wrapper")
  for settings in "$dir/settings.gradle.kts" "$dir/settings.gradle"; do
    if [ -f "$settings" ] && grep -q 'build-logic' "$settings"; then echo "$dir"; break; fi
  done
done | sort)
if [ "$1" = --list ]; then
  printf '%s\n' "$builds"
  exit 0
fi
status=0
for dir in $builds; do
  if ! (cd "$root/$dir" && ./gradlew "$@" --console=plain -q); then
    echo "gradle-builds: $* failed in $dir" >&2
    status=1
  fi
done
exit $status
