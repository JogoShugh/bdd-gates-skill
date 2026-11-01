#!/usr/bin/env bash
# Self-test for the bdd-gates core. No mocks: every case runs the real scripts
# against a real throwaway git repo in a temp dir, for every stack in stacks/.
#   selftest.sh
set -uo pipefail

# Inherited, these point every gate script at a real repo instead of the throwaway ones.
unset BDD_GATES_ROOT BDD_GATES_CONFIG CLAUDE_PROJECT_DIR

skill_dir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passed=0
failed=0

ok() { passed=$((passed + 1)); echo "  PASS  $1"; }
bad() { failed=$((failed + 1)); echo "  FAIL  $1"; }
expect_exit() { # <want> <label> <cmd...>
  local want=$1 label=$2
  shift 2
  "$@" >/dev/null 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then ok "$label"; else bad "$label (exit $got, want $want)"; fi
}
payload() { printf '{"tool_input":{"file_path":"%s"}}' "$1"; }
hook() { # <script> <abs-path>
  payload "$2" | CLAUDE_PROJECT_DIR=$repo "$repo/.claude/bdd-gates/$1"
}
tool_hook() { # <script> <tool> <input-key> <value>
  jq -nc --arg t "$2" --arg k "$3" --arg v "$4" '{tool_name: $t, tool_input: {($k): $v}}' \
    | CLAUDE_PROJECT_DIR=$repo "$repo/.claude/bdd-gates/$1"
}
prompt_hook() { # <prompt>
  jq -nc --arg p "$1" '{prompt: $p}' | CLAUDE_PROJECT_DIR=$repo "$repo/.claude/bdd-gates/refactor-prompt.sh"
}
bash_hook() { printf '{"tool_input":{"command":"%s"}}' "$2" | CLAUDE_PROJECT_DIR=$repo "$repo/.claude/bdd-gates/$1"; }
new_repo() {
  repo=$work/$1
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name t
  # Backdated: the pre-commit window starts strictly after the last commit's second,
  # so events logged in that same second would be left out.
  GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    git -C "$repo" commit -q --allow-empty -m init
}
probe() { printf '%s' "${1//\*/Probe}"; }
set_config() { # <jq filter>
  local tmp
  tmp=$(mktemp)
  jq "$1" "$repo/.claude/bdd-gates.json" > "$tmp" && mv "$tmp" "$repo/.claude/bdd-gates.json"
}

# A .gitignore whose last line has no newline (common from editors and
# templates) must not get the log path glued onto that line.
echo "gitignore without trailing newline"
new_repo gitignore-no-newline
printf '.DS_Store' > "$repo/.gitignore"
expect_exit 0 "install succeeds" "$skill_dir/scripts/install.sh" gradle-kotlin "$repo"
if grep -qxF '.DS_Store' "$repo/.gitignore" && grep -qxF '.claude/tdd-events.log' "$repo/.gitignore"; then
  ok "existing last line kept, log path on its own line"
else
  bad "gitignore lines merged: $(tr '\n' '|' < "$repo/.gitignore")"
fi
mkdir -p "$repo/.claude" && touch "$repo/.claude/tdd-events.log"
[ -z "$(git -C "$repo" status --porcelain -- .claude/tdd-events.log)" ] && ok "event log is ignored by git" || bad "event log shows in git status"

for stack_dir in "$skill_dir"/stacks/*/; do
  stack=$(basename "$stack_dir")
  case "$stack" in _*) continue ;; esac
  echo "stack: $stack"
  new_repo "$stack"
  expect_exit 0 "install succeeds" "$skill_dir/scripts/install.sh" "$stack" "$repo"
  expect_exit 0 "install is idempotent" "$skill_dir/scripts/install.sh" "$stack" "$repo"
  count=$(jq '.hooks.PreToolUse | length' "$repo/.claude/settings.json")
  [ "$count" = "3" ] && ok "re-install does not duplicate hooks" || bad "PreToolUse has $count entries after re-install"

  prod_rel=$(probe "$(jq -r '.prodPatterns[0]' "$repo/.claude/bdd-gates.json")")
  feat_rel=$(probe "$(jq -r '.featurePatterns[0]' "$repo/.claude/bdd-gates.json")")
  prod=$repo/$prod_rel
  feat=$repo/$feat_rel

  expect_exit 2 "prod write blocked with no feature change" hook gherkin-first.sh "$prod"
  expect_exit 0 "non-prod write allowed" hook gherkin-first.sh "$repo/README.md"
  excl=$(jq -r '.excludedSample // empty' "$stack_dir/stack.json")
  if [ -n "$excl" ]; then
    expect_exit 0 "excluded path allowed ($excl)" hook gherkin-first.sh "$repo/$excl"
  fi

  mkdir -p "$(dirname "$feat")"
  echo "Feature: probe" > "$feat"
  expect_exit 0 "prod write allowed once a feature file is untracked" hook gherkin-first.sh "$prod"
  git -C "$repo" add "$feat_rel"
  expect_exit 0 "prod write allowed once a feature file is staged" hook gherkin-first.sh "$prod"

  # Clean event log, then walk a correct red-green sequence through the real hooks.
  rm -f "$repo/.claude/tdd-events.log"
  set_config '.lintCommand = "true" | .checkCommand = "true" | .bddCommand = "exit ${BDD_EXIT:-1}"'
  hook log-event.sh "$feat" >/dev/null
  BDD_GATES_ROOT=$repo "$repo/.claude/bdd-gates/bdd-run.sh" >/dev/null 2>&1
  mkdir -p "$(dirname "$prod")"
  echo "// prod" > "$prod"
  hook log-event.sh "$prod" >/dev/null
  BDD_EXIT=0 BDD_GATES_ROOT=$repo "$repo/.claude/bdd-gates/bdd-run.sh" >/dev/null 2>&1
  events=$(awk '{print $2 (NF > 2 ? " " $3 : "")}' "$repo/.claude/tdd-events.log" | tr '\n' ',')
  [ "$events" = "FEATURE_WRITE $feat_rel,BDD_RUN FAIL,MAIN_WRITE $prod_rel,BDD_RUN PASS," ] \
    && ok "event log records the red-green sequence" || bad "event log: $events"

  git -C "$repo" add "$prod_rel"
  expect_exit 0 "pre-commit passes a Gherkin-first sequence" bash -c "cd '$repo' && .githooks/pre-commit"

  # Same staged change, but production code came before the red run.
  printf '%s MAIN_WRITE %s\n%s FEATURE_WRITE %s\n%s BDD_RUN FAIL\n%s BDD_RUN PASS\n' \
    2999-01-01T00:00:00Z "$prod_rel" 2999-01-01T00:00:00Z "$feat_rel" \
    2999-01-01T00:00:00Z 2999-01-01T00:00:00Z > "$repo/.claude/tdd-events.log"
  expect_exit 1 "pre-commit rejects prod before feature (same-second events)" bash -c "cd '$repo' && .githooks/pre-commit"

  printf '%s FEATURE_WRITE %s\n%s MAIN_WRITE %s\n%s BDD_RUN PASS\n' \
    2999-01-01T00:00:00Z "$feat_rel" 2999-01-01T00:00:01Z "$prod_rel" 2999-01-01T00:00:02Z > "$repo/.claude/tdd-events.log"
  expect_exit 1 "pre-commit rejects a sequence never seen red" bash -c "cd '$repo' && .githooks/pre-commit"

  printf '%s FEATURE_WRITE %s\n%s CUCUMBER_RUN FAIL\n%s MAIN_WRITE %s\n%s CUCUMBER_RUN PASS\n' \
    2999-01-01T00:00:00Z "$feat_rel" 2999-01-01T00:00:01Z 2999-01-01T00:00:02Z "$prod_rel" 2999-01-01T00:00:03Z > "$repo/.claude/tdd-events.log"
  expect_exit 0 "pre-commit accepts legacy CUCUMBER_RUN lines" bash -c "cd '$repo' && .githooks/pre-commit"

  git -C "$repo" reset -q
  git -C "$repo" add "$feat_rel"
  expect_exit 0 "pre-commit ignores commits with no production code" bash -c "cd '$repo' && .githooks/pre-commit"

  set_config '.lintCommand = "echo lint-broke; exit 3"'
  expect_exit 2 "lint gate reports failure on a lintable file" hook lint.sh "$prod"
  expect_exit 0 "lint gate skips non-lintable files" hook lint.sh "$repo/notes.txt"
  set_config '.checkCommand = "exit 1"'
  expect_exit 2 "stop gate blocks on a failing check" bash -c "CLAUDE_PROJECT_DIR='$repo' '$repo/.claude/bdd-gates/check.sh' </dev/null"
  set_config '.checkCommand = "true"'
  expect_exit 0 "stop gate passes on a green check" bash -c "CLAUDE_PROJECT_DIR='$repo' '$repo/.claude/bdd-gates/check.sh' </dev/null"

  raw=$(jq -r '.config.bddRawCommandRegex // empty' "$stack_dir/stack.json")
  if [ -n "$raw" ]; then
    sample=$(jq -r '.rawCommandSample' "$stack_dir/stack.json")
    expect_exit 2 "raw test command blocked ($sample)" bash_hook gate-bash.sh "$sample"
    expect_exit 0 "wrapper test command allowed" bash_hook gate-bash.sh ".claude/bdd-gates/bdd-run.sh"
  fi
  expect_exit 0 "unrelated bash command allowed" bash_hook gate-bash.sh "git status"

  expect_exit 0 "verify-install proves block then allow" bash -c "cd '$repo' && git reset -q && rm -f '$feat' && '$skill_dir/scripts/verify-install.sh' '$repo'"
  # Refactor mode, through the real git hooks (core.hooksPath) in a fresh repo
  # whose production, test and feature files are already committed.
  echo "stack: $stack (refactor mode)"
  new_repo "$stack-refactor"
  "$skill_dir/scripts/install.sh" "$stack" "$repo" >/dev/null 2>&1
  set_config '.lintCommand = "true" | .checkCommand = "true" | .bddCommand = "exit ${BDD_EXIT:-1}"'
  test_pat=$(jq -r '.testPatterns[0]' "$repo/.claude/bdd-gates.json")
  test_rel=$(probe "$test_pat")
  new_test_rel=$(printf '%s' "${test_pat//\*/NewProbe}")
  prod=$repo/$prod_rel
  for f in "$prod_rel" "$feat_rel" "$test_rel"; do
    mkdir -p "$(dirname "$repo/$f")"
    echo "// $f" > "$repo/$f"
  done
  git -C "$repo" add -A
  git -C "$repo" commit -q -m baseline
  git -C "$repo" config core.hooksPath .githooks
  mode_file=$(git -C "$repo" rev-parse --absolute-git-dir)/bdd-refactor

  rf_reset() {
    git -C "$repo" reset -q --hard
    git -C "$repo" clean -fdq
    rm -f "$mode_file"
  }
  rf_on() { (cd "$repo" && scripts/refactor-mode on "extract method") >/dev/null; }
  rf_run() { BDD_EXIT=$1 BDD_GATES_ROOT=$repo "$repo/.claude/bdd-gates/bdd-run.sh" >/dev/null 2>&1; }
  rf_write() { echo "// $RANDOM" >> "$prod"; hook log-event.sh "$prod" >/dev/null; }
  rf_commit() { git -C "$repo" add "$prod_rel" && git -C "$repo" commit -q -m "${1:-tidy}"; }

  rf_reset; rf_on; rf_run 0
  expect_exit 0 "refactor mode lets the prod write through" hook gherkin-first.sh "$prod"
  rf_write; rf_run 0
  expect_exit 0 "refactor commit passes: green, change, green" rf_commit
  git -C "$repo" log -1 --format=%B | grep -qx 'Refactor-Mode: extract method' \
    && ok "refactor commit carries the trailer" || bad "no Refactor-Mode trailer: $(git -C "$repo" log -1 --format=%B | tr '\n' '|')"
  [ ! -f "$mode_file" ] && ok "post-commit switches refactor mode off" || bad "refactor mode still on after the commit"
  rf_write; rf_run 0
  expect_exit 1 "refactor mode is not reused for a second commit" rf_commit

  rf_reset; rf_on; rf_run 0; rf_write; echo "// changed" >> "$repo/$test_rel"; rf_run 0
  expect_exit 1 "refactor refused: a test file changed" rf_commit
  rf_reset; rf_on; rf_run 0; rf_write; echo "# changed" >> "$repo/$feat_rel"; rf_run 0
  expect_exit 1 "refactor refused: a feature file changed" rf_commit
  rf_reset; rf_on; rf_run 0; rf_write
  mkdir -p "$(dirname "$repo/$new_test_rel")"; echo "// new" > "$repo/$new_test_rel"; rf_run 0
  expect_exit 1 "refactor refused: a new untracked test" rf_commit
  rf_reset; rf_on; rf_write; rf_run 0
  expect_exit 1 "refactor refused: no passing run before the first prod write" rf_commit
  rf_reset; rf_on; rf_run 0; rf_write; rf_run 0; rf_write
  expect_exit 1 "refactor refused: prod written after the last run" rf_commit
  rf_reset; rf_on; rf_run 0; rf_write; rf_run 1
  expect_exit 1 "refactor refused: the last run failed" rf_commit
  rf_reset; rf_on
  git -C "$repo" -c core.hooksPath=/dev/null commit -q --allow-empty -m "moved on"
  rf_run 0; rf_write; rf_run 0
  expect_exit 1 "refactor refused: HEAD moved since the mode was switched on" rf_commit

  rf_reset
  echo "notes" > "$repo/notes.txt"
  git -C "$repo" add notes.txt
  expect_exit 1 "forged Refactor-Mode trailer refused" git -C "$repo" commit -q -m "$(printf 'tidy\n\nRefactor-Mode: forged')"
  rf_reset
  expect_exit 2 "normal mode still blocks the prod write" hook gherkin-first.sh "$prod"
  rf_run 0; rf_write; rf_run 0
  expect_exit 1 "normal mode still refuses a prod commit with no feature" rf_commit

  expect_exit 2 "Claude may not switch refactor mode on" tool_hook protect-gate.sh Bash command 'scripts/refactor-mode on "x"'
  expect_exit 2 "Claude may not skip the hooks" tool_hook protect-gate.sh Bash command 'git commit --no-verify -m x'
  expect_exit 2 "Claude may not edit the gate scripts" tool_hook protect-gate.sh Edit file_path "$repo/.claude/bdd-gates/lib.sh"
  expect_exit 0 "Claude may run the pre-commit check" tool_hook protect-gate.sh Bash command '.githooks/pre-commit'
  expect_exit 2 "a non-Bash tool call naming the mode is blocked" tool_hook protect-gate.sh ScheduleWakeup prompt 'refactor-mode on "x"'
  expect_exit 0 "Claude may read the gate" tool_hook protect-gate.sh Read file_path "$repo/scripts/refactor-mode"

  # Switching by prompt: only a whole prompt in the exact form counts.
  rf_reset
  out=$(prompt_hook 'refactor-mode on "rename"')
  [ -f "$mode_file" ] && printf '%s' "$out" | grep -q 'Refactor mode is on' \
    && ok "whole prompt switches refactor mode on" || bad "prompt did not switch the mode on: $out"
  prompt_hook 'refactor-mode off' >/dev/null
  [ ! -f "$mode_file" ] && ok "whole prompt switches refactor mode off" || bad "prompt did not switch the mode off"
  out=$(prompt_hook 'please explain what refactor-mode on "x" does')
  [ ! -f "$mode_file" ] && [ -z "$out" ] \
    && ok "a sentence that mentions the mode switches nothing" || bad "a mention switched the mode: $out"
done

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
