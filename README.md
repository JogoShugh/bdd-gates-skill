# bdd-gates

Deterministic Gherkin-first TDD gates for Claude Code, for any language.

Rules written in `CLAUDE.md` are advisory. A model can misread them or drift
past them late in a long session. bdd-gates turns the rules that matter into
real processes with real exit codes: Claude Code hooks, a git pre-commit
check, and your build's own complexity and architecture checks. A gate that
exits 2 cannot be reasoned past.

This folder is a Claude Code skill. Claude reads `SKILL.md` to install the
gates and to work inside them. This README is for the people who own the repo.

## What it enforces

| Gate | When it runs | What it does |
|---|---|---|
| Gherkin first | Before Claude edits or writes a file | Blocks a production-code write unless a scenario has been added, or had its steps changed, against HEAD. Comments, tags, descriptions and blank lines do not count |
| Event log | After Claude edits or writes a file | Appends `FEATURE_WRITE` / `MAIN_WRITE` to `.claude/tdd-events.log` |
| Lint | After Claude edits a lintable file | Runs the stack's complexity linter and reports violations back to Claude |
| Feature lint | After Claude edits a `.feature` file, and at commit | gplint with bdd-gates' rules: no empty or unnamed scenarios, every scenario has a `Then`, outlines have examples, and two scenarios that differ only in their values are one Scenario Outline |
| Logged test runs | Every BDD run | Appends `BDD_RUN PASS` or `BDD_RUN FAIL`, including runs that fail, with each scenario's own result |
| Raw test command | Before Claude runs a shell command | On wrapper-logged stacks, blocks a raw test command that would skip the log |
| Green to stop | When Claude tries to end its turn | Runs the full check; Claude keeps working until it passes |
| TDD ordering | `git commit`, from any tool or terminal | Rejects a commit of production code unless it adds or changes a scenario, and the log shows a feature write, then a BDD run that failed on behaviour (a compile failure does not count), before the first production write, and a passing final run |
| Scenario by scenario | `git commit`, on stacks that record each scenario | Also rejects it unless one of the scenarios it adds or changes failed before the first production write (an older scenario failing does not count), and all of them pass after the last |
| Refactor mode | `git commit`, after the author switches it on | Lets one commit change production code with no feature change, if no test or feature file changed, the suite passed before the first production write, and the last run passed after the last one |
| Gate protection | Before every Claude tool call | Blocks Claude from switching refactor mode on, changing the gate's scripts, config, git hooks, settings, event log or run results, and skipping hooks |

The event log is plain text, one fact per line, and gitignored:

```
2026-09-28T17:40:11Z FEATURE_WRITE src/test/resources/features/checkout.feature
2026-09-28T17:40:52Z BDD_RUN FAIL module=shop total=12 failures=1 errors=0 results=.claude/bdd-runs/20260928T174052Z-1.json
2026-09-28T17:41:30Z MAIN_WRITE src/main/kotlin/shop/Checkout.kt
2026-09-28T17:42:05Z BDD_RUN PASS module=shop total=12 failures=0 errors=0 results=.claude/bdd-runs/20260928T174205Z-1.json
```

### What counts as a real scenario change

The gates read the Gherkin the way Cucumber does, with its own parser
(`@cucumber/gherkin`), and compare Cucumber's *pickles*: one per Scenario,
one per Examples row of a Scenario Outline, Background steps included. A
pickle is known by its file, its scenario's name and its Examples row; it
changed when its steps changed. Adding a scenario or an Examples row, or
changing a step, is a change. A comment, a tag, a description, blank lines or
reordering is not.

Each run's `results=` file holds one status per scenario, taken from
Cucumber's message stream (its `message` plugin). That is how the pre-commit
knows which scenario was red and which is green, not just whether the run was.

## Quick start

Requirements: `bash` (3.2 or later, so stock macOS works), `git`, `jq`, and
Node 18+ with `npm`, in every stack: the Gherkin tools run on Node.

```bash
SKILL=path/to/bdd-gates

# 1. Install the language-agnostic core for your stack.
$SKILL/scripts/install.sh gradle-kotlin /path/to/repo     # or dotnet-csharp or node-typescript

# 2. Check the file patterns in /path/to/repo/.claude/bdd-gates.json.

# 3. Make the build-side changes in $SKILL/stacks/<stack>/SETUP.md
#    (BDD runner, run logging, complexity linter, architecture test).

# 4. Prove the gate: a production write is blocked, then allowed once a feature changes.
$SKILL/scripts/verify-install.sh /path/to/repo

# 5. Turn on the git hook, once per clone.
git -C /path/to/repo config core.hooksPath .githooks
```

Or ask Claude: "set up bdd-gates in this repo". The skill runs the same steps
and shows you the build changes before it makes them.

### What the installer changes in the target repo

| Path | Change |
|---|---|
| `.claude/bdd-gates/*.sh` | Core scripts, copied in and committed, so every teammate gets the same gates |
| `.claude/bdd-gates/gherkin/` | The Gherkin tools (scenario changes, run results, feature lint), with their lockfile; `npm ci` installs their `node_modules`, which stay out of git |
| `.claude/bdd-gates.json` | Per-repo config, created from the stack defaults; kept if it already exists |
| `.claude/settings.json` | Hook entries merged in; hooks the installer did not write are left alone |
| `.githooks/pre-commit` | Ordering check, and the refactor check when refactor mode is on |
| `.githooks/commit-msg` | Adds the `Refactor-Mode:` trailer in refactor mode; refuses it on any other commit |
| `.githooks/post-commit` | Switches refactor mode off after any commit |
| `scripts/refactor-mode` | The author's switch for refactor mode |
| `.gitignore` | Adds `.claude/tdd-events.log` and `.claude/bdd-runs/` |

An existing git hook or `scripts/refactor-mode` that the installer did not
write is kept, and ours goes beside it as `<name>.bdd-gates` to merge by hand.

Re-running the installer is safe. It refreshes the scripts and replaces its
own hook entries without duplicating them.

## Configuration

`.claude/bdd-gates.json` holds every language-specific value. The core
scripts are identical in every repo.

| Key | Meaning |
|---|---|
| `prodPatterns` | Production source files. Shell globs on repo-relative paths; `*` also crosses folders |
| `prodExcludePatterns` | Paths that match `prodPatterns` but are not production: tests, step definitions, generated code, build output |
| `featurePatterns` | Gherkin feature files |
| `testPatterns` | Test code and test fixtures. A refactor commit may not change these, nor feature files |
| `lintPatterns` | Files whose edit re-runs the linter |
| `lintCommand` | Fast complexity check; non-zero exit means a violation |
| `checkCommand` | Full check for the Stop gate: tests, BDD, lint, architecture |
| `bddCommand` | The raw BDD test command |
| `bddLogging` | `native`: the build logs each run itself. `wrapper`: runs go through `.claude/bdd-gates/bdd-run.sh` |
| `bddRawCommandRegex` | Wrapper stacks only: the raw test command Claude may not run directly |
| `bddMessages` | Wrapper stacks only: where the runner writes Cucumber's message stream |
| `scenarioResults` | `true` when the stack records each scenario's result: the pre-commit then judges scenario by scenario |
| `protectedFiles` | File names of the quality settings, which Claude may read and not change |

Example for a multi-module Gradle build:

```json
"prodPatterns": ["*/src/main/kotlin/*.kt"],
"featurePatterns": ["*/src/test/resources/features/*.feature"]
```

Wrong patterns do not fail loudly; the gate just never matches. Run
`verify-install.sh` after every pattern change.

## Stacks

| Stack | BDD runner | Run logging | Complexity | Architecture | Scenario by scenario |
|---|---|---|---|---|---|
| `gradle-kotlin` | Cucumber-JVM (JUnit Platform) | native, the `bddgates.bdd-log` convention plugin | Detekt with ktlint's rules, typed Detekt at Stop, Kover floor, CPD | Konsist, and no `@Suppress` but the team's list | yes |
| `dotnet-csharp` | Reqnroll (xUnit or NUnit) | wrapper, `bdd-run.sh` | Roslyn CA1502 + SonarAnalyzer | Project references + NetArchTest | not yet |
| `node-typescript` | cucumber-js | wrapper, `bdd-run.sh` | ESLint (core, SonarJS, type-aware typescript-eslint) + `tsc`, Knip, c8 | dependency-cruiser | yes |

Each stack folder holds `stack.json` (config defaults), `SETUP.md` (build
changes), and `templates/`. Thresholds are always each tool's own defaults,
never invented numbers. The one policy number is Kotlin's coverage floor,
80 %, to agree with the team.

`gradle-kotlin` puts every quality setting in one convention-plugin build,
`build-logic/`, that each Gradle build includes; `scripts/gradle-builds.sh`
runs the lint, check and test tasks in every build of the repo, so a build
added later is gated with no config change.

On wrapper stacks, run tests through the wrapper so the result is logged:

```bash
.claude/bdd-gates/bdd-run.sh
.claude/bdd-gates/bdd-run.sh --filter "FullyQualifiedName~Checkout"
```

### Adding a language

Copy `stacks/_template/` to `stacks/<name>/` and answer the five questions in
its README:

1. Which paths are production code, and which are features?
2. Does the BDD runner fail on undefined steps? It must, or a scenario never goes red.
3. How is every run logged, pass or fail?
4. Which complexity linter, at its own defaults?
5. Which tool makes the architecture boundary a failing test?

The template README lists candidate tools for TypeScript, Python, and Go.

## Day-to-day loop

1. Add a scenario, or change a scenario's steps or Examples.
2. Run the BDD suite and watch that scenario fail: an undefined step counts, a compile error does not. In a
   compiled language, run before writing new step definitions, so the run compiles.
3. Write step definitions and production code. The gate now allows it.
4. Run the suite until it passes. Fix lint findings as they appear.
5. Commit. The pre-commit check confirms the sequence, scenario by scenario.

## Refactor mode

A refactor changes the structure of production code, not its behavior. It has
no new scenario, so it cannot be seen red first. For that case, you (never
Claude) switch on refactor mode for one commit. Send one of these as a whole
prompt, from any Claude Code client, remote control included:

```
refactor-mode on "extract the pricing rules from Checkout"
refactor-mode status
refactor-mode off
```

A `UserPromptSubmit` hook (`refactor-prompt.sh`) runs `scripts/refactor-mode`
with those arguments, and Claude reports its output. Only a whole prompt in
exactly this form counts; a sentence that mentions the mode switches nothing.
In a terminal, `scripts/refactor-mode on "why"` works too.

The mode starts from a clean working tree and is bound to the current HEAD.
While it is on, Claude may write production code with no feature change, and
the pre-commit check accepts the commit only if:

- no feature file and no test file (`testPatterns`) differs from HEAD, staged,
  unstaged, or untracked;
- a BDD run passed after the mode was switched on, before the first
  production write;
- the last BDD run passed, after the last production write.

Green, change, green. The commit gets a `Refactor-Mode: <why>` trailer, so
`git log --grep Refactor-Mode` lists every refactor. The trailer is refused on
any other commit. The mode ends with the next commit, and is void if HEAD
moves first.

The state file lives in the git directory, not the working tree. A
`PreToolUse` hook (`protect-gate.sh`) runs before every tool. It blocks Claude
from running the switch, from touching the gate's scripts, config, git hooks,
Claude Code settings or event log, and from `--no-verify` or `git commit -n`.
Any other tool call whose input names the gate or the mode is blocked too
(scheduling, messaging, agents, MCP), so Claude cannot send the switch prompt
by another route. Claude may still read these files, run
`.githooks/pre-commit`, and run `bdd-run.sh`.

## Testing the skill

```bash
scripts/selftest.sh
```

No mocks. For every stack folder, the selftest installs into a real
throwaway git repo and runs the real scripts end to end. It checks blocking,
logging, the pre-commit ordering rules, refactor mode through the real git
hooks, gate protection, the lint and Stop gates, the raw command gate, the
feature lint, scenario changes, scenario-by-scenario results, and
`verify-install.sh`. New stack folders are picked up
automatically.

```bash
scripts/e2e-gradle-kotlin.sh
```

The Kotlin stack for real: two Gradle builds sharing `build-logic`, real
Cucumber-JVM, the installed hooks and pre-commit. It walks one red-green
cycle scenario by scenario, and checks that a commit is refused when its run
was red only on an older scenario. Needs a JDK 21 and the network the first
time.

## Sharing

This repository root is the skill itself (`SKILL.md` at the top), so a clone
is an install:

- **All your repos:** `git clone <this-repo-url> ~/.claude/skills/bdd-gates`
- **One repo:** clone or copy it into that repo's `.claude/skills/bdd-gates/` and commit it.
- **A team:** package it as a Claude Code plugin with this folder under `skills/`.

Update with `git pull` in the skill folder, then re-run `scripts/install.sh`
in each target repo to refresh its copy of the core scripts.

The installed gates live in each target repo's `.claude/bdd-gates/`, so a
repo keeps working even for teammates who do not have the skill.

## Known limits and tradeoffs

- **Refactors need the author.** Only you can switch on refactor mode, one
  commit at a time. Claude cannot open it for itself.
- **A prompt does not say where it came from.** If another Claude session can
  deliver a message into this session as a prompt, it could switch refactor
  mode. Claude in this session cannot, because of `protect-gate.sh`.
- **Gate protection is a pattern match.** `protect-gate.sh` matches paths and
  words in Claude's commands. It stops drift, not a determined attempt to
  hide a path, so review commits to the gate files as usual.
- **Scenarios, not files.** The scenario-by-scenario check proves a changed
  scenario was red before the code and green after. It does not prove every
  production file was driven by it. On `dotnet-csharp` it is not on yet, so
  that stack still checks run by run.
- **Outlines in disguise: exact only.** Two scenarios are flagged only when
  their steps match exactly once values are set aside. Near-duplicates are
  left to the author and to review.
- **Hollow steps pass.** A `Then` step with no assertion turns green and
  proves nothing; the gates do not look inside step definitions yet.
- **Node everywhere.** Every stack, Kotlin and .NET included, needs Node 18+
  for the Gherkin tools.
- **The commit window starts after the last commit's second.** Events
  logged in the same second as the previous commit are not counted. This
  errs toward rejecting a commit, never toward passing one.
- **The Stop gate has no escape hatch.** If the build cannot go green,
  Claude keeps working until you interrupt it.
- **Terminal runs on wrapper stacks.** A raw `dotnet test` typed by a person
  leaves no log line, so the next commit fails the ordering check until the
  suite is re-run through the wrapper.
- **Gates catch structure, not judgment.** They cannot see duplication,
  naming, or whether an abstraction is right. Pair them with regular code
  review.

## Security

Hook commands run automatically for anyone who opens the repo in Claude
Code. The installed hooks call only local scripts in `.claude/bdd-gates/`
and your own build commands. Keep it that way: never `curl | sh` or fetch
remote scripts from a hook, and review changes to `.claude/settings.json`
and `.claude/bdd-gates.json` as you would a CI pipeline change.

## Layout

```
bdd-gates/
├── SKILL.md                 instructions Claude loads
├── README.md                this file
├── core/                    language-agnostic hook scripts, git hooks, refactor-mode, hooks.json
│   └── gherkin/             features.mjs (scenario changes, run results, verdict, lint), gplint rules, lockfile
├── scripts/
│   ├── install.sh           install the core into a repo
│   ├── verify-install.sh    live block-then-allow proof in a repo
│   ├── selftest.sh          end-to-end tests against temp git repos
│   └── e2e-gradle-kotlin.sh the Kotlin stack with real Gradle and Cucumber
└── stacks/
    ├── _template/           how to add a language
    ├── gradle-kotlin/
    ├── node-typescript/
    └── dotnet-csharp/
```
