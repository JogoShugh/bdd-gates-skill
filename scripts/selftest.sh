#!/usr/bin/env bash
# Self-test for the bdd-gates core. No mocks: every case runs the real scripts
# against a real throwaway git repo in a temp dir, for every stack in stacks/.
#   selftest.sh
set -uo pipefail

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
  [ "$count" = "2" ] && ok "re-install does not duplicate hooks" || bad "PreToolUse has $count entries after re-install"

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
done

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
