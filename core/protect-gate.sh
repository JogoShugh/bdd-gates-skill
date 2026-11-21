#!/usr/bin/env bash
# PreToolUse (every tool). Keeps the TDD gate out of Claude's reach: Claude
# may not switch refactor mode on (only the author does, with the prompt
# `refactor-mode on "why"`, see refactor-prompt.sh), and may not change what
# checks it: the gate scripts and config, the git hooks and where git finds
# them, the Claude Code settings that register these hooks, or the event log
# the checks read, or the stack's own quality settings (protectedFiles in the
# config: its linter, coverage and architecture rules). Nor may Claude skip the hooks with --no-verify, name the
# gate in any other tool call (agents, scheduling, messaging, MCP), so Claude
# cannot send the author's switch or a change to the gate by another route. A
# plan, a todo or a question may name the gate, but not the mode.
# Claude may still run the pre-commit check and the test wrapper, and read
# every one of these files. Exit 2 blocks the tool call.
set -o pipefail

input=$(cat)
tool=$(jq -r '.tool_name // empty' <<<"$input")

# Paths and words that reach the gate. Extended regular expressions.
protected='bdd-refactor|refactor-mode|tdd-events\.log|\.claude/bdd-runs|\.claude/settings|\.claude/bdd-gates|bdd-gates\.json|\.githooks|hooksPath|(^|/)\.git/|--no-verify'

# The stack's quality settings, by file name, wherever they sit in the repo.
config=${BDD_GATES_CONFIG:-${BDD_GATES_ROOT:-${CLAUDE_PROJECT_DIR:-.}}/.claude/bdd-gates.json}
if [ -f "$config" ]; then
  files=$(jq -r '(.protectedFiles // []) | map(gsub("\\."; "\\.")) | join("|")' "$config")
  [ -z "$files" ] || protected="$protected|(^|[^A-Za-z0-9._-])($files)([^A-Za-z0-9._-]|$)"
fi

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
  Read | Grep | Glob | LS)
    # Reading the gate is allowed.
    ;;
  mcp__*)
    # An MCP tool may write files or run commands: its whole input may not
    # name the gate or the mode.
    if jq -c '.tool_input // {}' <<<"$input" | grep -Eq -- "$protected"; then
      block "this call names the TDD gate or refactor mode."
    fi
    ;;
  ExitPlanMode | TodoWrite | AskUserQuestion)
    # A plan, a todo or a question stays in this session: it may name the gate
    # (a step that runs the pre-commit check), but not the mode.
    if jq -c '.tool_input // {}' <<<"$input" | grep -Eq -- 'bdd-refactor|refactor-mode'; then
      block "this call names refactor mode."
    fi
    ;;
  *)
    # Any other tool (agents, remote and scheduled ones included, messaging,
    # scheduling): its whole input may not name the gate or the mode. A remote
    # or scheduled agent runs where these hooks may not.
    if jq -c '.tool_input // {}' <<<"$input" | grep -Eq -- "$protected"; then
      block "this call names the TDD gate or refactor mode."
    fi
    ;;
esac
exit 0
