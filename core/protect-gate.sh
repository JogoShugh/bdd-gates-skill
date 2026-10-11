#!/usr/bin/env bash
# PreToolUse (Bash|Edit|Write|MultiEdit|NotebookEdit). Keeps the TDD gate out
# of Claude's reach: Claude may not switch refactor mode on (only the author
# does, with `! scripts/refactor-mode on "why"`), and may not change what
# checks it: the gate scripts and config, the git hooks and where git finds
# them, the Claude Code settings that register these hooks, or the event log
# the checks read. Nor may Claude skip the hooks with --no-verify.
# Claude may still run the pre-commit check and the test wrapper, and read
# every one of these files. Exit 2 blocks the tool call.
set -o pipefail

input=$(cat)
tool=$(jq -r '.tool_name // empty' <<<"$input")

# Paths and words that reach the gate. Extended regular expressions.
protected='bdd-refactor|refactor-mode|tdd-events\.log|\.claude/settings|\.claude/bdd-gates|bdd-gates\.json|\.githooks|hooksPath|(^|/)\.git/|--no-verify'

block() {
  echo "Blocked: $1" >&2
  echo "The TDD gate and refactor mode are the author's. Ask them to make this change." >&2
  exit 2
}

case "$tool" in
  Bash)
    command=$(jq -r '.tool_input.command // empty' <<<"$input")
    # Running the pre-commit check or the test wrapper is allowed, as a command
    # of its own: at the start, or after &&, || or ;.
    allowed='(^|&&|\|\||;)[[:space:]]*(\./)?(\.githooks/pre-commit|\.claude/bdd-gates/bdd-run\.sh)([[:space:]]|;|&|\||$)'
    rest=$(printf '%s' "$command" | sed -E "s#$allowed#\\1 \\4#g")
    if printf '%s' "$rest" | grep -Eq -- "$protected"; then
      block "this command reaches the TDD gate or refactor mode."
    fi
    # git commit -n is --no-verify.
    if printf '%s' "$command" | grep -Eq -- 'git[^;&|]*[[:space:]]commit([[:space:]][^;&|]*)?[[:space:]]-[a-zA-Z]*n'; then
      block "git commit -n skips the hooks."
    fi
    ;;
  Edit | Write | MultiEdit | NotebookEdit)
    path=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input")
    if printf '%s' "$path" | grep -Eq -- "$protected"; then
      block "$path is part of the TDD gate or refactor mode."
    fi
    ;;
esac
exit 0
