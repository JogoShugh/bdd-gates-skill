#!/usr/bin/env bash
# Installs the bdd-gates core into a target repo for one stack.
#   install.sh <stack> [target-repo-dir]
# Idempotent: re-running refreshes the core scripts and the hook entries, and
# keeps an existing .claude/bdd-gates.json and a customized pre-commit.
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
for f in lib.sh gherkin-first.sh log-event.sh lint.sh check.sh bdd-run.sh gate-bash.sh; do
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

# 4. Git pre-commit hook.
mkdir -p "$target/.githooks"
hook=$target/.githooks/pre-commit
if [ ! -f "$hook" ] || cmp -s "$skill_dir/core/pre-commit" "$hook" || grep -q 'bdd-gates' "$hook"; then
  cp "$skill_dir/core/pre-commit" "$hook"
  chmod +x "$hook"
  echo "pre-commit -> .githooks/pre-commit"
else
  cp "$skill_dir/core/pre-commit" "$hook.bdd-gates"
  chmod +x "$hook.bdd-gates"
  echo "WARNING: .githooks/pre-commit exists and is not ours; wrote .githooks/pre-commit.bdd-gates to merge by hand." >&2
fi

# 5. Keep the local event log out of git.
gitignore=$target/.gitignore
if ! grep -qxF '.claude/tdd-events.log' "$gitignore" 2>/dev/null; then
  echo '.claude/tdd-events.log' >> "$gitignore"
  echo "added .claude/tdd-events.log to .gitignore"
fi

cat <<EOF

Core installed for stack '$stack'. Remaining steps:
  1. Follow $skill_dir/stacks/$stack/SETUP.md (linter, architecture tests, BDD runner, run logging).
  2. Activate the git hook once:  git config core.hooksPath .githooks
  3. Prove the gate live:          $skill_dir/scripts/verify-install.sh $target
EOF
