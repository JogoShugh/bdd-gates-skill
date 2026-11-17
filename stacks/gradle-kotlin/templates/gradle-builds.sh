#!/bin/sh
# Runs one Gradle task in every Gradle build of this repo, so a build added later is gated with no change
# to .claude/bdd-gates.json. A build is a folder with a gradlew beside its settings.gradle(.kts);
# build-logic (the convention plugins) and build output are skipped. Exits non-zero when any build fails,
# after running them all.
#   scripts/gradle-builds.sh detekt
#   scripts/gradle-builds.sh check
set -u
[ $# -gt 0 ] || { echo "usage: scripts/gradle-builds.sh <task> [args]" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
status=0
for wrapper in $(cd "$root" && find . -name gradlew -not -path '*/build/*' -not -path '*/.gradle/*' \
  -not -path '*/node_modules/*' -not -path './build-logic/*' | sort); do
  dir=$(dirname "$wrapper")
  [ -f "$root/$dir/settings.gradle.kts" ] || [ -f "$root/$dir/settings.gradle" ] || continue
  if ! (cd "$root/$dir" && ./gradlew "$@" --console=plain -q); then
    echo "gradle-builds: $* failed in ${dir#./}" >&2
    status=1
  fi
done
exit $status
