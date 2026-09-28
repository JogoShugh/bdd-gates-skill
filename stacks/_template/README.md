# Adding a stack

A stack is one folder under `stacks/`: `stack.json`, `SETUP.md`, and
`templates/`. The core scripts never change per language; a stack only
supplies config values and build-side instructions. Copy this folder to
`stacks/<name>/` (no leading underscore) and answer the five questions below.
`scripts/selftest.sh` picks up the new folder automatically.

## The five questions

1. **Where do production code and features live?**
   `prodPatterns`, `prodExcludePatterns`, `featurePatterns`. Patterns are shell
   case globs on repo-relative paths, and `*` crosses folders. Exclude step
   definitions, test code, generated code, and build output.

2. **Which BDD runner, and does it fail on undefined steps?**
   The red step only proves something if a scenario with no bindings fails,
   not skips. Find the runner's strict or "missing steps = error" setting and
   make it part of SETUP.md.
   Examples: Cucumber-JVM 7+ (strict by default), Reqnroll
   (`missingOrPendingStepsOutcome: Error`), cucumber-js (`--strict`, default
   in recent versions), behave (`--strict`), pytest-bdd (missing steps error).

3. **How is every BDD run logged, pass *or* fail?**
   - `native`: the build tool runs a step after the test task even on
     failure (Gradle `finalizedBy`, Maven failsafe `verify`, an npm `posttest`
     does NOT run on failure). The step appends
     `<utc-seconds> BDD_RUN PASS|FAIL ...` to `.claude/tdd-events.log`.
   - `wrapper`: no reliable native hook exists. Use
     `.claude/bdd-gates/bdd-run.sh` as `checkCommand` and set
     `bddRawCommandRegex` so Claude cannot bypass it.

4. **Which complexity linter, at its own defaults?**
   The command must exit non-zero on a violation. Do not invent thresholds.
   Examples: Detekt, SonarAnalyzer + Roslyn, ESLint `complexity`/`max-depth`/
   `max-params`/`max-lines-per-function`, Ruff `C901`/`PLR09xx`, gocyclo/gocognit
   through golangci-lint.

5. **How is the architecture boundary a failing test?**
   Prefer structural enforcement first (separate module/project/package with
   no dependency), then a test library for the rest.
   Examples: Konsist or ArchUnit (JVM), NetArchTest or ArchUnitNET (.NET),
   dependency-cruiser (JS/TS), import-linter (Python), go-arch-lint or
   `depguard` (Go).

## SETUP.md shape

Mirror `stacks/gradle-kotlin/SETUP.md`: numbered sections for BDD runner, run
logging, complexity gate, architecture gate, config review, red proof. Each
section names the file to change and why the rule matters. Keep versions as
`<latest>`; the installing agent resolves them.
