#!/usr/bin/env bash
# Installs the bdd-gates core into a target repo for one stack.
#   install.sh <stack> [target-repo-dir]
# Idempotent: re-running refreshes the core scripts and the hook entries, and
# keeps an existing .claude/bdd-gates.json and customized git hooks.
# Stack build changes (linter, architecture tests, BDD runner) are NOT made
# here; follow stacks/<stack>/SETUP.md for those.
set -euo pipefail

skill_dir=$(cd "$(dirname "$0")/.." && pwd)
stack=${1:-}
if [ -z "$stack" ]; then
  echo "usage: install.sh <stack> [target-repo-dir]" >&2
  echo "stacks: $(ls "$skill_dir/stacks" | grep -v '^_' | tr '\n' ' ')" >&2
  exit 1
fi
target=$(cd "${2:-.}" && pwd)
stack_file=$skill_dir/stacks/$stack/stack.json
[ -f "$stack_file" ] || { echo "unknown stack: $stack (no $stack_file)" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
git -C "$target" rev-parse --git-dir >/dev/null 2>&1 || { echo "$target is not a git repo" >&2; exit 1; }

# 1. Core scripts, committed with the repo so every teammate gets the gates.
dest=$target/.claude/bdd-gates
mkdir -p "$dest"
for f in lib.sh gherkin-first.sh protect-gate.sh log-event.sh lint.sh check.sh bdd-run.sh gate-bash.sh; do
  cp "$skill_dir/core/$f" "$dest/$f"
  chmod +x "$dest/$f"
done
echo "core scripts -> .claude/bdd-gates/"

# 2. Per-repo config from the stack defaults.
config=$target/.claude/bdd-gates.json
if [ -f "$config" ]; then
  echo "kept existing .claude/bdd-gates.json"
else
  jq '.config' "$stack_file" > "$config"
  echo "wrote .claude/bdd-gates.json from stack $stack (review the patterns)"
fi

# 3. Hook entries merged into .claude/settings.json. Old bdd-gates entries are
#    replaced; unrelated hooks are left alone.
settings=$target/.claude/settings.json
[ -f "$settings" ] || echo '{}' > "$settings"
tmp=$(mktemp)
jq --slurpfile add "$skill_dir/core/hooks.json" '
  def ours: (.command // "") | contains(".claude/bdd-gates/");
  def strip: map(.hooks |= map(select(ours | not))) | map(select(.hooks | length > 0));
  .hooks = (.hooks // {})
  | reduce ($add[0] | keys[]) as $ev (.; .hooks[$ev] = (((.hooks[$ev] // []) | strip) + $add[0][$ev]))
' "$settings" > "$tmp"
mv "$tmp" "$settings"
echo "hooks merged into .claude/settings.json"

legacy=$(jq -r '[.hooks[][]?.hooks[]? | select((.command // "") | (contains("tdd-events.log") or contains("gradlew")) and (contains(".claude/bdd-gates/") | not))] | length' "$settings")
if [ "$legacy" != "0" ]; then
  echo "WARNING: $legacy older inline gate hook(s) remain in .claude/settings.json; remove them to avoid running gates twice." >&2
fi

# 4. Git hooks: the ordering check, and refactor mode's trailer and switch-off.
#    The refactor-mode switch goes to scripts/, for the author to run.
#    A file that is not ours is kept, and ours goes beside it to merge by hand.
install_ours() { # <core-file> <target-rel-path>
  local src=$skill_dir/core/$1 dst=$target/$2
  mkdir -p "$(dirname "$dst")"
  if [ ! -f "$dst" ] || cmp -s "$src" "$dst" || grep -q 'bdd-gates' "$dst"; then
    cp "$src" "$dst"
    chmod +x "$dst"
    echo "$1 -> $2"
  else
    cp "$src" "$dst.bdd-gates"
    chmod +x "$dst.bdd-gates"
    echo "WARNING: $2 exists and is not ours; wrote $2.bdd-gates to merge by hand." >&2
  fi
}
for h in pre-commit commit-msg post-commit; do
  install_ours "$h" ".githooks/$h"
done
install_ours refactor-mode scripts/refactor-mode

# 5. Keep the local event log out of git.
gitignore=$target/.gitignore
if ! grep -qxF '.claude/tdd-events.log' "$gitignore" 2>/dev/null; then
  # Without this, a file whose last line lacks a newline gets the path glued
  # onto that line (".DS_Store.claude/tdd-events.log"), and the log is not ignored.
  if [ -s "$gitignore" ] && [ -n "$(tail -c 1 "$gitignore")" ]; then
    echo >> "$gitignore"
  fi
  echo '.claude/tdd-events.log' >> "$gitignore"
  echo "added .claude/tdd-events.log to .gitignore"
fi

cat <<EOF

Core installed for stack '$stack'. Remaining steps:
  1. Follow $skill_dir/stacks/$stack/SETUP.md (linter, architecture tests, BDD runner, run logging).
  2. Activate the git hooks once: git config core.hooksPath .githooks
  3. Prove the gate live:          $skill_dir/scripts/verify-install.sh $target
  4. Refactor mode, for one commit, is yours to switch on:  ! scripts/refactor-mode on "why"
EOF
