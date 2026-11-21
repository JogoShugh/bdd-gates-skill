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
# A feature with a real scenario: the gates count scenarios, not files.
scenario='Feature: probe\n  Scenario: a probe\n    Given a start\n    When it acts\n    Then it ends\n'
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

# gplint reads its rules folders as globs, so under a path with glob characters it loads no rules. The
# lint must refuse and say why, not report every rule missing.
echo "lint under a path with glob characters"
globbed="$work/glob [x]/.claude"
mkdir -p "$globbed"
cp -R "$skill_dir/core/gherkin" "$globbed/gherkin"
printf "$scenario" > "$work/ok.feature"
out=$(node --no-warnings "$globbed/gherkin/features.mjs" lint -- "$work/ok.feature" 2>&1) \
  && bad "the lint passed with no rules loaded" \
  || { printf '%s' "$out" | grep -q 'glob characters' \
    && ok "the lint refuses a path with glob characters and says why" \
    || bad "the lint under a globbed path: $(printf '%s' "$out" | head -3)"; }
rm -rf "$work/glob [x]" "$work/ok.feature"

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
  printf 'Feature: probe\n  Only a description, no scenario.\n' > "$feat"
  expect_exit 2 "prod write still blocked by a feature file with no scenario" hook gherkin-first.sh "$prod"
  expect_exit 2 "feature lint fails a feature file with no scenario" hook lint.sh "$feat"
  printf 'Feature: probe\n  Scenario: no outcome\n    Given a start\n    When it acts\n    And again\n' > "$feat"
  expect_exit 2 "feature lint fails a scenario with no Then" hook lint.sh "$feat"
  printf 'Feature: probe\n  Scenario: arming\n    When action "arm" is sent\n    Then it answers 400\n\n  Scenario: launching\n    When action "launch" is sent\n    Then it answers 404\n' > "$feat"
  expect_exit 2 "feature lint fails two scenarios that differ only in values (an outline)" hook lint.sh "$feat"
  printf "$scenario" > "$feat"
  expect_exit 0 "feature lint passes a scenario with a Then" hook lint.sh "$feat"
  expect_exit 0 "prod write allowed once a feature file is untracked" hook gherkin-first.sh "$prod"
  git -C "$repo" add "$feat_rel"
  expect_exit 0 "prod write allowed once a feature file is staged" hook gherkin-first.sh "$prod"

  # Clean event log, then walk a correct red-green sequence through the real hooks.
  rm -f "$repo/.claude/tdd-events.log"
  # Run by run first; scenario by scenario further down.
  set_config '.lintCommand = "true" | .checkCommand = "true" | .bddCommand = "exit ${BDD_EXIT:-1}" | .scenarioResults = false | del(.bddMessages)'
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

  printf '%s FEATURE_WRITE %s\n%s BDD_RUN FAIL module=m reason=compile\n%s MAIN_WRITE %s\n%s BDD_RUN PASS\n' \
    2999-01-01T00:00:00Z "$feat_rel" 2999-01-01T00:00:01Z 2999-01-01T00:00:02Z "$prod_rel" 2999-01-01T00:00:03Z > "$repo/.claude/tdd-events.log"
  expect_exit 1 "pre-commit rejects a red run that only failed to compile" bash -c "cd '$repo' && .githooks/pre-commit"

  # A feature already committed, then only a comment and a tag added: not a scenario change.
  git -C "$repo" reset -q
  git -C "$repo" add "$feat_rel"
  git -C "$repo" -c core.hooksPath=/dev/null commit -q -m "feature"
  printf '# a comment\n@tagged\n' | cat - "$feat" > "$feat.tmp" && mv "$feat.tmp" "$feat"
  expect_exit 2 "prod write blocked when the feature change is only a comment and a tag" hook gherkin-first.sh "$prod"
  git -C "$repo" add "$feat_rel" "$prod_rel"
  printf '%s FEATURE_WRITE %s\n%s BDD_RUN FAIL\n%s MAIN_WRITE %s\n%s BDD_RUN PASS\n' \
    2999-01-01T00:00:00Z "$feat_rel" 2999-01-01T00:00:01Z 2999-01-01T00:00:02Z "$prod_rel" 2999-01-01T00:00:03Z > "$repo/.claude/tdd-events.log"
  expect_exit 1 "pre-commit rejects a staged feature change that changes no scenario" bash -c "cd '$repo' && .githooks/pre-commit"
  printf '\n  Scenario: another probe\n    Given a start\n    When it acts twice\n    Then it ends\n' >> "$feat"
  git -C "$repo" add "$feat_rel"
  expect_exit 0 "pre-commit accepts a staged feature change that adds a scenario" bash -c "cd '$repo' && .githooks/pre-commit"

  # The Gherkin tools crash (an old Node, a broken install): the check fails closed. With no feature file
  # staged there is nothing to lint, so only the scenario count stands between this commit and the log.
  mjs=$repo/.claude/bdd-gates/gherkin/features.mjs
  cp "$mjs" "$work/features.mjs.keep"
  echo 'throw new Error("crashed");' > "$mjs"
  git -C "$repo" reset -q -- "$feat_rel"
  expect_exit 1 "pre-commit refuses when the Gherkin tools crash" bash -c "cd '$repo' && .githooks/pre-commit"
  git -C "$repo" add "$feat_rel"
  cp "$work/features.mjs.keep" "$mjs"

  # A run that failed before the feature was written says nothing about the new Gherkin.
  printf '%s BDD_RUN FAIL\n%s FEATURE_WRITE %s\n%s MAIN_WRITE %s\n%s BDD_RUN PASS\n' \
    2999-01-01T00:00:00Z 2999-01-01T00:00:01Z "$feat_rel" 2999-01-01T00:00:02Z "$prod_rel" 2999-01-01T00:00:03Z > "$repo/.claude/tdd-events.log"
  expect_exit 1 "pre-commit rejects a red run from before the feature was written" bash -c "cd '$repo' && .githooks/pre-commit"
  # Nor does a run of steps since rewritten, with no scenario-by-scenario results to tell.
  printf '%s FEATURE_WRITE %s\n%s BDD_RUN FAIL\n%s FEATURE_WRITE %s\n%s MAIN_WRITE %s\n%s BDD_RUN PASS\n' \
    2999-01-01T00:00:00Z "$feat_rel" 2999-01-01T00:00:01Z 2999-01-01T00:00:02Z "$feat_rel" 2999-01-01T00:00:03Z "$prod_rel" \
    2999-01-01T00:00:04Z > "$repo/.claude/tdd-events.log"
  out=$(cd "$repo" && .githooks/pre-commit 2>&1) && bad "pre-commit accepted a red run from before the last feature change, run by run" \
    || { printf '%s' "$out" | grep -q "failed only before the last feature change" \
      && ok "pre-commit rejects a red run from before the last feature change, run by run, and says so" \
      || bad "red before the last feature change, refused for another reason: $(printf '%s' "$out" | head -4)"; }
  printf '%s FEATURE_WRITE %s\n%s BDD_RUN FAIL\n%s MAIN_WRITE %s\n%s BDD_RUN PASS\n' \
    2999-01-01T00:00:00Z "$feat_rel" 2999-01-01T00:00:01Z 2999-01-01T00:00:02Z "$prod_rel" 2999-01-01T00:00:03Z > "$repo/.claude/tdd-events.log"

  # The staged copy is what gets committed, so the staged copy is what the lint reads.
  cp "$feat" "$work/feature.keep"
  printf '\n  Scenario: a probe with no outcome\n    Given a start\n    When it waits\n' >> "$feat"
  git -C "$repo" add "$feat_rel"
  printf '    Then it rests\n' >> "$feat"
  out=$(cd "$repo" && .githooks/pre-commit 2>&1) && bad "pre-commit passed a staged feature that fails the lint" \
    || { printf '%s' "$out" | grep -qE "^ *- +$feat_rel\$" && ! printf '%s' "$out" | grep -qE 'tmp\.|/var/folders|bdd-staged' \
      && ok "pre-commit lints the staged feature, not the working copy, and names it by its repo path" \
      || bad "staged lint output: $(printf '%s' "$out" | head -8)"; }
  cp "$work/feature.keep" "$feat"
  git -C "$repo" add "$feat_rel"
  # With no folder for the staged copies, pre-commit refuses rather than lint nothing.
  if [ "$(id -u)" -eq 0 ]; then
    echo "  SKIP the git directory cannot be made read-only as root"
  else
    printf '\n' >> "$feat"
    git -C "$repo" add "$feat_rel"
    chmod 555 "$repo/.git"
    out=$(cd "$repo" && .githooks/pre-commit 2>&1) && bad "pre-commit passed with nowhere to copy the staged features" \
      || { printf '%s' "$out" | grep -q 'staged feature files could not be copied' \
        && ok "pre-commit refuses when the staged features cannot be copied" \
        || bad "no folder for staged copies, refused for another reason: $(printf '%s' "$out" | head -4)"; }
    chmod 755 "$repo/.git"
    cp "$work/feature.keep" "$feat"
    git -C "$repo" add "$feat_rel"
  fi

  # Several modules: the last line passing is not enough when another module's latest run failed.
  printf '%s FEATURE_WRITE %s\n%s BDD_RUN FAIL module=a\n%s MAIN_WRITE %s\n%s BDD_RUN FAIL module=a\n%s BDD_RUN PASS module=b\n' \
    2999-01-01T00:00:00Z "$feat_rel" 2999-01-01T00:00:01Z 2999-01-01T00:00:02Z "$prod_rel" \
    2999-01-01T00:00:03Z 2999-01-01T00:00:04Z > "$repo/.claude/tdd-events.log"
  expect_exit 1 "pre-commit rejects a module still red when the last line is another module's PASS" bash -c "cd '$repo' && .githooks/pre-commit"
  printf '%s BDD_RUN PASS module=a\n%s BDD_RUN PASS module=b\n' 2999-01-01T00:00:05Z 2999-01-01T00:00:06Z >> "$repo/.claude/tdd-events.log"
  expect_exit 0 "pre-commit accepts once every module's latest run passes" bash -c "cd '$repo' && .githooks/pre-commit"

  # Production code written after the last run: not seen green.
  printf '%s FEATURE_WRITE %s\n%s BDD_RUN FAIL\n%s MAIN_WRITE %s\n%s BDD_RUN PASS\n%s MAIN_WRITE %s\n' \
    2999-01-01T00:00:00Z "$feat_rel" 2999-01-01T00:00:01Z 2999-01-01T00:00:02Z "$prod_rel" \
    2999-01-01T00:00:03Z 2999-01-01T00:00:04Z "$prod_rel" > "$repo/.claude/tdd-events.log"
  expect_exit 1 "pre-commit rejects production code written after the last run" bash -c "cd '$repo' && .githooks/pre-commit"

  # A staged production file with no MAIN_WRITE: edited outside Claude's tools, its order unknown.
  printf '%s FEATURE_WRITE %s\n%s BDD_RUN FAIL\n%s BDD_RUN PASS\n' \
    2999-01-01T00:00:00Z "$feat_rel" 2999-01-01T00:00:01Z 2999-01-01T00:00:02Z > "$repo/.claude/tdd-events.log"
  expect_exit 1 "pre-commit rejects production code written outside Claude's tools" bash -c "cd '$repo' && .githooks/pre-commit"

  # Scenario by scenario. record-run reduces Cucumber's message stream to one status per scenario.
  ndjson=$repo/messages.ndjson
  {
    jq -nc --arg u "$feat_rel" '{gherkinDocument: {uri: $u, feature: {children: [{scenario: {id: "s2", name: "another probe", examples: []}}]}}}'
    jq -nc --arg u "$feat_rel" '{pickle: {id: "p2", uri: $u, name: "another probe", astNodeIds: ["s2"], steps: []}}'
    echo '{"testCase":{"id":"t2","pickleId":"p2","testSteps":[]}}'
    echo '{"testCaseStarted":{"id":"c2","testCaseId":"t2","attempt":0}}'
    echo '{"testStepFinished":{"testCaseStartedId":"c2","testStepId":"x","testStepResult":{"status":"UNDEFINED"}}}'
    echo '{"testCaseFinished":{"testCaseStartedId":"c2","willBeRetried":false}}'
  } > "$ndjson"
  cp "$ndjson" "$work/messages.ndjson.keep"
  BDD_GATES_ROOT=$repo "$repo/.claude/bdd-gates/record-run.sh" FAIL module=m "messages=$ndjson" >/dev/null 2>&1
  recorded=$(tail -1 "$repo/.claude/tdd-events.log" | sed -n 's/.* results=\([^ ]*\).*/\1/p')
  if [ -n "$recorded" ] && [ "$(jq -r --arg k "$feat_rel :: another probe" '.[$k]' "$repo/$recorded")" = UNDEFINED ] \
    && [ ! -e "$ndjson" ]; then
    ok "record-run keeps each scenario's status from the message stream, and clears the stream"
  else
    bad "record-run did not record the scenario (line: $(tail -1 "$repo/.claude/tdd-events.log"))"
  fi
  expect_exit 2 "Claude may not write the run results" tool_hook protect-gate.sh Write file_path "$repo/.claude/bdd-runs/forged.json"
  # Modules of a parallel build record at the same moment: each run keeps its own results file.
  for n in 1 2 3 4 5 6; do cp "$work/messages.ndjson.keep" "$repo/parallel-$n.ndjson"; done
  for n in 1 2 3 4 5 6; do
    BDD_GATES_ROOT=$repo "$repo/.claude/bdd-gates/record-run.sh" FAIL "module=p$n" "messages=$repo/parallel-$n.ndjson" >/dev/null 2>&1 &
  done
  wait
  # A variable named out in the caller's environment is not taken for a results file.
  echo keep > "$work/outside"
  out=$work/outside BDD_GATES_ROOT=$repo "$repo/.claude/bdd-gates/record-run.sh" PASS module=env >/dev/null 2>&1
  [ "$(cat "$work/outside")" = keep ] && ! grep ' module=env ' "$repo/.claude/tdd-events.log" | grep -q results= \
    && ok "record-run ignores an inherited out variable" || bad "record-run wrote to an inherited out: $(grep ' module=env ' "$repo/.claude/tdd-events.log")"
  distinct=$(grep ' module=p[1-6] ' "$repo/.claude/tdd-events.log" | sed -n 's/.* results=\([^ ]*\).*/\1/p' | sort -u | wc -l | tr -d ' ')
  [ "$distinct" = 6 ] && ok "six runs recorded at once keep six results files" || bad "six runs recorded at once kept $distinct results files"
  # A results folder that cannot be written: the run is still recorded, without results, and never hangs.
  cp "$work/messages.ndjson.keep" "$repo/readonly.ndjson"
  # root writes to a read-only folder anyway, so the case is only meaningful for another user.
  if [ "$(id -u)" = 0 ]; then
    echo "  SKIP  read-only results folder (running as root)"
  else
    chmod 555 "$repo/.claude/bdd-runs"
    BDD_GATES_ROOT=$repo "$repo/.claude/bdd-gates/record-run.sh" FAIL module=ro "messages=$repo/readonly.ndjson" >/dev/null 2>&1 &
    pid=$!
    for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$pid" 2>/dev/null; then
      pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null
      bad "record-run hangs when the results folder cannot be written"
    else
      grep -q ' BDD_RUN FAIL module=ro' "$repo/.claude/tdd-events.log" \
        && ok "record-run records the run when the results folder cannot be written" || bad "record-run logged no run for a read-only results folder"
      [ ! -e "$repo/readonly.ndjson" ] && ok "and still deletes the message stream" || bad "the message stream was kept"
    fi
    chmod 755 "$repo/.claude/bdd-runs"
  fi

  set_config '.scenarioResults = true'
  runs=$repo/.claude/bdd-runs
  result() { jq -n --arg k "$feat_rel :: $2" --arg s "$3" '{($k): $s}' > "$runs/$1.json"; }
  result new-red "another probe" UNDEFINED
  result old-red "a probe" FAILED
  result new-green "another probe" PASSED
  result new-failing "another probe" FAILED
  result old-green "a probe" PASSED
  sequence() { # <red results> <green results>
    printf '%s FEATURE_WRITE %s\n%s BDD_RUN FAIL results=.claude/bdd-runs/%s.json\n%s MAIN_WRITE %s\n%s BDD_RUN PASS results=.claude/bdd-runs/%s.json\n' \
      2999-01-01T00:00:00Z "$feat_rel" 2999-01-01T00:00:01Z "$1" 2999-01-01T00:00:02Z "$prod_rel" 2999-01-01T00:00:03Z "$2" \
      > "$repo/.claude/tdd-events.log"
  }
  sequence new-red new-green
  expect_exit 0 "pre-commit accepts the new scenario red before the code and green after" bash -c "cd '$repo' && .githooks/pre-commit"
  sequence old-red new-green
  expect_exit 1 "pre-commit rejects a red run in which only an unchanged scenario failed" bash -c "cd '$repo' && .githooks/pre-commit"
  sequence new-red new-failing
  expect_exit 1 "pre-commit rejects a new scenario still failing after the code" bash -c "cd '$repo' && .githooks/pre-commit"
  sequence new-red old-green
  expect_exit 1 "pre-commit rejects a new scenario that never ran after the code" bash -c "cd '$repo' && .githooks/pre-commit"
  printf '%s FEATURE_WRITE %s\n%s BDD_RUN FAIL results=.claude/bdd-runs/new-red.json\n%s FEATURE_WRITE %s\n%s MAIN_WRITE %s\n%s BDD_RUN PASS results=.claude/bdd-runs/new-green.json\n' \
    2999-01-01T00:00:00Z "$feat_rel" 2999-01-01T00:00:01Z 2999-01-01T00:00:02Z "$feat_rel" 2999-01-01T00:00:03Z "$prod_rel" \
    2999-01-01T00:00:04Z > "$repo/.claude/tdd-events.log"
  expect_exit 1 "pre-commit rejects a red run from before the last feature change" bash -c "cd '$repo' && .githooks/pre-commit"
  base=${feat_rel##*/}
  jq -n --arg k "${base#?} :: another probe" '{($k): "FAILED"}' > "$runs/suffix-red.json"
  sequence suffix-red new-green
  expect_exit 1 "pre-commit rejects a red result for a file whose name only ends the same way" bash -c "cd '$repo' && .githooks/pre-commit"
  set_config '.scenarioResults = false'

  git -C "$repo" reset -q
  git -C "$repo" add "$feat_rel"
  expect_exit 0 "pre-commit ignores commits with no production code" bash -c "cd '$repo' && .githooks/pre-commit"

  git -C "$repo" reset -q --hard
  git -C "$repo" mv "$feat_rel" "${feat_rel%.feature}Moved.feature"
  expect_exit 2 "prod write blocked when a feature file is only moved" hook gherkin-first.sh "$prod"
  git -C "$repo" reset -q --hard
  sed 's/Scenario: a probe/Scenario: a retitled probe/' "$feat" > "$feat.tmp" && mv "$feat.tmp" "$feat"
  expect_exit 2 "prod write blocked when a scenario is only retitled" hook gherkin-first.sh "$prod"
  git -C "$repo" checkout -q -- "$feat_rel"
  # Two scenarios share a name; deleting the first is a removal, not a change to the second.
  printf '\n  Scenario: twin\n    Given a first twin\n    Then it is first\n\n  Scenario: twin\n    Given a second twin\n    Then it is second\n' >> "$feat"
  git -C "$repo" add "$feat_rel" && git -C "$repo" -c core.hooksPath=/dev/null commit -q -m twins
  awk '/Scenario: twin/ && !done { skip = 3; done = 1 } skip > 0 { skip--; next } { print }' "$feat" > "$feat.tmp" && mv "$feat.tmp" "$feat"
  expect_exit 2 "prod write blocked when the first of two same-named scenarios is deleted" hook gherkin-first.sh "$prod"
  git -C "$repo" checkout -q -- "$feat_rel"
  # A scenario rewritten to the steps of one deleted in the same change is a change, not a rename.
  # The second twin goes, and "a probe" takes its steps.
  awk '/Scenario: a probe/ { print; getline; print "    Given a second twin"; getline; getline; print "    Then it is second"; next }
       /Scenario: twin/ { twins++ } twins == 2 && skip == 0 && !done { skip = 3; done = 1 } skip > 0 { skip--; next } { print }' \
    "$feat" > "$feat.tmp" && mv "$feat.tmp" "$feat"
  expect_exit 0 "prod write allowed when a scenario takes the steps of one deleted" hook gherkin-first.sh "$prod"
  git -C "$repo" checkout -q -- "$feat_rel"
  # A feature file whose name git would quote (core.quotePath) is still read and linted.
  odd=$(dirname "$feat_rel")/café.feature
  [ "$odd" = ./café.feature ] && odd=café.feature
  printf 'Feature: café\n  Scenario: an order\n    Given a café\n    When a coffee is ordered\n' > "$repo/$odd"
  git -C "$repo" add -- "$odd" "$prod_rel"
  printf '%s FEATURE_WRITE %s\n%s BDD_RUN FAIL\n%s MAIN_WRITE %s\n%s BDD_RUN PASS\n' \
    2999-01-01T00:00:00Z "$odd" 2999-01-01T00:00:01Z 2999-01-01T00:00:02Z "$prod_rel" 2999-01-01T00:00:03Z > "$repo/.claude/tdd-events.log"
  out=$(cd "$repo" && .githooks/pre-commit 2>&1)
  printf '%s' "$out" | grep -q 'has no Then step' \
    && ok "pre-commit lints a feature whose name git quotes" || bad "café.feature was not linted: $(printf '%s' "$out" | head -4)"
  git -C "$repo" reset -q -- "$odd" "$prod_rel" && rm -f "$repo/$odd"

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
  expect_exit 0 "a plan that names the pre-commit check can be submitted" tool_hook protect-gate.sh ExitPlanMode plan "run .githooks/pre-commit"
  expect_exit 2 "an MCP tool may not write the gate" tool_hook protect-gate.sh mcp__files__write_file path "$repo/.githooks/pre-commit"
  expect_exit 2 "an agent may not be sent to change the gate" tool_hook protect-gate.sh Agent prompt "set lintCommand in .claude/bdd-gates.json to true"
  expect_exit 2 "a scheduled agent may not be told to skip the hooks" tool_hook protect-gate.sh RemoteTrigger prompt "commit with --no-verify"
  expect_exit 0 "a todo that names the pre-commit check can be written" tool_hook protect-gate.sh TodoWrite content "run .githooks/pre-commit"
  expect_exit 2 "a todo may not name refactor mode" tool_hook protect-gate.sh TodoWrite content 'refactor-mode on "x"'
  quality=$(jq -r '.protectedSample // empty' "$stack_dir/stack.json")
  if [ -n "$quality" ]; then
    expect_exit 2 "Claude may not edit the quality settings ($quality)" tool_hook protect-gate.sh Edit file_path "$repo/pkg/$quality"
    expect_exit 2 "Claude may not change them from the shell" tool_hook protect-gate.sh Bash command "sed -i s/error/off/ pkg/$quality"
    expect_exit 0 "Claude may read the quality settings" tool_hook protect-gate.sh Read file_path "$repo/pkg/$quality"
    expect_exit 0 "a plan that names the quality settings can be submitted" tool_hook protect-gate.sh ExitPlanMode plan "explain $quality"
    expect_exit 0 "a file that only ends the same way is not protected" tool_hook protect-gate.sh Edit file_path "$repo/my$quality.txt"
  fi

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
  out=$(prompt_hook "$(printf 'refactor-mode on "rename"\nand tidy the tests too')")
  [ ! -f "$mode_file" ] && [ -z "$out" ] \
    && ok "a prompt of several lines switches nothing" || bad "a prompt of several lines switched the mode: $out"
  out=$(prompt_hook 'refactor-mode on')
  [ ! -f "$mode_file" ] && printf '%s' "$out" | grep -q 'failed' \
    && ok "refactor-mode on with no reason is reported as failed" || bad "no reason given, and: $out"
done

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
