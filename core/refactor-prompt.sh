#!/usr/bin/env bash
# UserPromptSubmit. Lets the author switch refactor mode from any Claude Code
# client, remote control included, by sending a prompt that is exactly one of:
#   refactor-mode on "why this is a refactor"
#   refactor-mode off
#   refactor-mode status
# Only a prompt the author submits reaches this hook. Claude cannot send one:
# protect-gate.sh blocks every tool call whose input names the mode, so Claude
# cannot schedule, send or relay such a prompt either. Any other prompt passes
# through untouched.
set -o pipefail

input=$(cat)
prompt=$(jq -r '.prompt // empty' <<<"$input" | sed -E '1s/^[[:space:]]+//; $s/[[:space:]]+$//')

case "$prompt" in
  'refactor-mode on '*)
    reason=${prompt#refactor-mode on }
    reason=${reason#\"}
    reason=${reason%\"}
    set -- on "$reason"
    ;;
  'refactor-mode off') set -- off ;;
  'refactor-mode status') set -- status ;;
  *) exit 0 ;;
esac

cd "${CLAUDE_PROJECT_DIR:?}" || exit 0
if out=$(scripts/refactor-mode "$@" 2>&1); then
  result="The author ran refactor-mode $1. Output: $out"
else
  result="The author's refactor-mode $1 failed. Output: $out"
fi

# The prompt goes on to Claude with the result attached, so Claude reports it
# and the author sees it in whichever client they use.
jq -n --arg ctx "$result Report this output to the author verbatim." \
  '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
exit 0
