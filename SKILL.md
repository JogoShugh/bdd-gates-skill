---
name: bdd-gates
description: Install, verify, and work inside deterministic Gherkin-first TDD gates for any language stack. The gates are Claude Code hooks, a git pre-commit check, and complexity plus architecture checks. Use when asked to set up BDD/TDD enforcement or quality gates in a repo, to add a new language stack (C#, TypeScript, Python, ...) to these gates, or when working in a repo that has .claude/bdd-gates.json and a hook blocked an edit.
---

# bdd-gates

Instructions are advisory. A model can drift past them. These gates are real
processes with real exit codes, so they hold even when attention slips. This
skill installs them and explains the loop they enforce. **The skill never
replaces the hooks**: if a gate blocks you, satisfy it; never edit it away.

## What gets enforced

| Gate | Mechanism | Blocks |
|---|---|---|
| Gherkin first | `PreToolUse` Edit/Write → `gherkin-first.sh` | Production write while no feature file is staged, unstaged, or untracked |
| Event log | `PostToolUse` → `log-event.sh` | Nothing; appends `FEATURE_WRITE` / `MAIN_WRITE` to `.claude/tdd-events.log` |
| Fast lint | `PostToolUse` → `lint.sh` | Reports complexity violations right after the edit (exit 2) |
| Logged BDD runs | stack-native hook, or `bdd-run.sh` wrapper + `gate-bash.sh` | Raw test command that would leave no `BDD_RUN` fact (wrapper stacks only) |
| Green to stop | `Stop` → `check.sh` | Ending the turn while tests, BDD, lint, or architecture checks fail |
| Ordering | `.githooks/pre-commit` | Commit of production code without feature write, red BDD run before the first prod write, and a green final run |
| Refactor mode | prompt `refactor-mode on "why"` → `refactor-prompt.sh`, switched on by the user only; `pre-commit`, `commit-msg`, `post-commit` | One commit of production code with no feature change, unless tests and features are unchanged and the suite is green before and after |
| Gate protection | `PreToolUse` every tool → `protect-gate.sh` | Switching refactor mode on; editing gate scripts, config, git hooks, settings, or the event log; `--no-verify`; any other tool call naming the gate or the mode |

Layout:
```
core/      language-agnostic scripts, identical for every stack
stacks/    one folder per language: stack.json (config defaults), SETUP.md, templates/
stacks/_template/  how to add a language
scripts/   install.sh, verify-install.sh, selftest.sh
```

## Install into a repo

1. Detect the stack from build files (`build.gradle.kts` → `gradle-kotlin`,
   `*.sln`/`*.csproj` → `dotnet-csharp`). If no folder under `stacks/` fits,
   go to "Add a stack" first.
2. Run `scripts/install.sh <stack> <repo>`. It copies `core/` to
   `<repo>/.claude/bdd-gates/`, writes `.claude/bdd-gates.json`, merges hooks
   into `.claude/settings.json`, installs `.githooks/pre-commit`, `commit-msg`
   and `post-commit` and `scripts/refactor-mode`, and gitignores the event
   log. Re-running is safe.
3. Check the patterns in `.claude/bdd-gates.json`, `testPatterns` included,
   against the repo's real folders. Wrong patterns make the gate silently
   useless. Once the hooks are live, `protect-gate.sh` blocks you from
   editing this file; show the user the change to make.
4. Follow `stacks/<stack>/SETUP.md` for the build side: BDD runner with strict
   undefined steps, BDD run logging, complexity linter at its own defaults,
   architecture test. These edits change the build, so show them to the user.
5. Run `scripts/verify-install.sh <repo>`. It must print two PASS lines:
   blocked with no feature change, allowed once a feature changes.
6. Tell the user to run `git config core.hooksPath .githooks` once. Do not
   change git config yourself.
7. Tell the user that hook commands run automatically for anyone who opens
   the repo in Claude Code, and to review `.claude/settings.json` like a CI change.

The installer does not touch hooks it did not write. If the repo already has
hand-written gate hooks (as `genai-service-gradle-plugin` did), it warns;
remove the old entries so gates do not run twice.

## Work loop inside a gated repo

1. Write or change the `.feature` scenario. Use Scenario Outlines and data
   tables, not repeated Given/When/Then blocks.
2. Run the BDD suite (native command, or `.claude/bdd-gates/bdd-run.sh` on
   wrapper stacks). See it **fail** for the right reason: `BDD_RUN FAIL`.
3. Write step definitions, then production code. The gate now allows it.
4. Run the suite until `BDD_RUN PASS`. Fix lint findings as they appear.
5. End the turn. The Stop gate runs the full check.

A pure refactor with no new behavior has no scenario to see red. For that,
the user switches on refactor mode for one commit, by sending the whole
prompt `refactor-mode on "why"`. You never switch it on, and never schedule,
send, or relay that prompt; `protect-gate.sh` blocks you. When the prompt
arrives, report the hook's output verbatim. Ask the user, and stop until they do. With the
mode on:

1. Run the BDD suite and see it **pass** before any production write.
2. Change production code only. No test, fixture, or feature file may differ
   from HEAD.
3. Run the suite after the last production write and see it **pass**.
4. Commit. `commit-msg` adds the `Refactor-Mode:` trailer; never write it
   yourself. The mode ends with this commit.

Never add a no-op feature change only to open the gate.

## Add a stack

Copy `stacks/_template/` to `stacks/<name>/` and answer the five questions in
its README: file patterns, strict BDD runner, pass-or-fail run logging,
complexity linter at its own defaults, architecture test. Then run
`scripts/selftest.sh`. It installs every stack into a real temp git repo and
walks the gates end to end.

## Hard-won details (keep them)

- **Log every run, especially failed ones.** Gradle skips later `doLast`
  actions when the task action throws, which happens on test failure. Use
  `finalizedBy`. Other build tools have the same trap; npm `posttest` does
  not run after a failure either. When in doubt, use the wrapper.
- **The BDD runner must fail undefined steps.** Otherwise the red step is
  "skipped", and the pre-commit check never sees a real red.
- **Order comes from log line order, not timestamps.** Events in the same
  second compare correctly. Timestamps only bound "since the last commit".
- **Compare UTC to UTC.** `git log %cI` carries a local offset; the
  pre-commit converts `%ct` to UTC first.
- **Ordering is checked per commit, not per scenario.** It catches skipped
  Gherkin. It does not prove every file was test-driven on its own.
- **Hooks run only local commands.** Never `curl | sh` or remote scripts.
- **Gates catch structure, not judgment.** Pair them with periodic
  `/code-review` for duplication, naming, and abstraction quality.
