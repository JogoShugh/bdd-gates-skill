# Stack: gradle-kotlin

Build-side changes that make the core gates meaningful, for one Gradle build or many in one repo. Everything
lives in one convention plugin build, `build-logic/`, so no build script repeats a quality setting and a build
added later is gated by applying two plugins. The reference implementation is the artie repo, where this runs
across six builds.

What it enforces, all at the tools' own defaults except the coverage floor:

| Tool | Gate | Fails on |
|---|---|---|
| Cucumber-JVM (strict) | BDD runner | an undefined or failing step |
| `bddgates.bdd-log` | run logging | nothing; records `BDD_RUN PASS/FAIL` for the pre-commit order check |
| Detekt + detekt-formatting | after every edit (`detekt`) | complexity, style, and any ktlint rule |
| Detekt with types | Stop gate (`detektMain`, `detektTest`) | the rules that need type information |
| Kover | Stop gate (`koverVerify`) | line coverage under the floor (80 %) |
| CPD (PMD) | Stop gate (`cpdCheck`) | a duplicate of 100 tokens or more in production code |
| Konsist | Stop gate (tests) | a core import of a framework type; a `@Suppress` of a rule not allowed |

## 1. The convention plugins

Copy `templates/build-logic/` to the repo root, and `templates/gradle-builds.sh` to `scripts/` (executable).

- `bddgates.kotlin-quality`: Detekt with ktlint's rules, Kover with its floor, CPD.
- `bddgates.bdd-log`: the BDD run log. Nothing to set: it finds the repo's `.claude/bdd-gates.json` by
  walking up from the build, and reads every `*RunCucumberTest` result.
- Tool versions live in `build-logic/build.gradle.kts` only.

In each build's `settings.gradle.kts`:

```kotlin
pluginManagement { includeBuild("../build-logic") }   // the path from this build to build-logic
```

In each module's `build.gradle.kts`:

```kotlin
plugins {
    kotlin("jvm") version "2.0.21"
    id("bddgates.kotlin-quality")
    id("bddgates.bdd-log")      // in the modules that run Cucumber features
}
```

Remove what the plugins now own from every build script: detekt, kover and cpd blocks and versions, and any
hand-written `logBddRun` task. A multi-module build's root may merge its modules' coverage with Kover
(`kover(project(":name"))`); that is reporting, not a gate.

Detekt 1.23 runs on Kotlin 2.0.21. Keep the builds on Kotlin 2.0.x until Detekt 2 is released.

## 2. BDD runner: Cucumber-JVM on the JUnit Platform

```kotlin
dependencies {
    testImplementation(platform("io.cucumber:cucumber-bom:<latest>"))
    testImplementation("io.cucumber:cucumber-java")
    testImplementation("io.cucumber:cucumber-junit-platform-engine")
    testImplementation("org.junit.platform:junit-platform-suite")
}
tasks.test { useJUnitPlatform() }
```

- Features under `src/test/resources/features/`.
- One `@Suite @IncludeEngines("cucumber")` class per module, named `RunCucumberTest` (any package): the log
  reads its results by that name.
- Cucumber 7+ is strict by default. Do not turn strictness off, or a new scenario can never go red.
- The runner writes Cucumber's message stream, so each run is recorded scenario by scenario (`scenarioResults`):

  ```kotlin
  @ConfigurationParameter(key = PLUGIN_PROPERTY_NAME, value = "message:build/cucumber/messages.ndjson")
  ```

  Add other plugins to the same value, comma-separated (`"pretty, message:build/cucumber/messages.ndjson"`).
  Without it, the pre-commit finds no scenario results and refuses the commit.

### Scenario by scenario

The pre-commit judges the scenarios the commit adds or changes, not the run as a whole:

- at least one of them failed (or was undefined) in a run before the first production write; a run in which
  only an older scenario failed does not count;
- every one of them passed in the runs after the last production write.

`bddgates.bdd-log` hands each run's message stream to `.claude/bdd-gates/record-run.sh`, which keeps one status
per scenario under `.claude/bdd-runs/` (git-ignored, and protected from Claude) and names it in the log line.

### The red run in Kotlin

The pre-commit check needs a run that fails on behaviour before the first production write. A compile error is
logged (`reason=compile`) but does not count. In Kotlin a step definition that names a class not yet written
does not compile, so:

1. Write the scenario and run it with no new step definitions: the undefined steps fail. That is the red run.
2. Then write the step definitions and the production code together, and run until green.

For a new module, the first red run is the feature and a bare `RunCucumberTest`, before any step definitions
or a Spring context that imports production classes.

`./gradlew test --tests SomeClass` that leaves the features out records nothing: it is not a BDD run.

## 3. Formatting: all of ktlint's rules

`detekt-formatting` runs ktlint's rules inside Detekt, so one tool and one report cover both. Most findings fix
themselves:

```bash
./gradlew detekt --auto-correct -Pformat.only=test    # test code: a normal commit
./gradlew detekt --auto-correct -Pformat.only=main    # production code: a refactor-mode commit
```

`-Pformat.only` keeps the two apart, because a refactor-mode commit may not change tests. Auto-correct writes
through Gradle, not Claude's tools, so the event log does not see those writes; that is fine inside refactor
mode, whose own check is that the suite is green before and after.

## 4. Coverage floor: Kover

`check` fails when a module's line coverage is under `minCoverage` (80) in
`bddgates.kotlin-quality.gradle.kts`. The number is a team policy, not a tool default; agree it, and keep it
the same as any coverage gate on new code elsewhere (SonarQube's default is 80 % on new code). Coverage comes
from the plain `test` task only; another `Test` task (a live or slow suite) is not run for it.

## 5. Duplication: CPD

`check` fails on a duplicate of 100 tokens or more in `src/main/kotlin`. Remove a duplicate by extracting what
the copies share. A duplicate kept on purpose (two DTOs that must stay independent, say) is wrapped in
`// CPD-OFF` and `// CPD-ON` with a comment saying why.

## 6. Architecture and suppressions: Konsist

```kotlin
testImplementation("com.lemonappdev:konsist:<latest>")
```

Copy `templates/ArchitectureBoundaryTest.kt` into each module's tests and set:

- `corePackage` and `forbiddenPrefixes`: the hexagonal boundary.
- `allowedSuppressions`: the only rules production code may `@Suppress`, each with the team's reason. Kotlin
  has no switch that ignores suppressions, so this test is it: any other suppression fails the build.

## 7. Config review

`.claude/bdd-gates.json` from this stack:

- Patterns cover a build at the root and builds in subfolders (`*/src/main/kotlin/*.kt`). `build-logic/` is
  not production code: it is protected instead.
- `lintCommand`, `checkCommand` and `bddCommand` run `scripts/gradle-builds.sh`, which finds every build with
  a `gradlew` beside its settings file. A new build is gated the moment it exists.
- `protectedFiles` holds `build-logic`, `gradle-builds.sh`, `ArchitectureBoundaryTest.kt` and Detekt's
  config and baseline: Claude can read them and cannot change them.
- `lintCommand` runs after every `.kt`/`.kts` edit, in every build. In a big repo that is slow; the plain
  `detekt` task (no type resolution) is the fast one, and the slower typed tasks run only at Stop.

## 8. Mutation testing (optional)

Pitest runs on Kotlin through `info.solidsoft.pitest`, but plain Pitest mutates the bytecode Kotlin generates
(null checks, data-class methods, coroutines) and reports many mutants no test could kill. Arcmutate's Kotlin
plugin filters them and is commercial. Treat mutation testing as a periodic review, not a gate, unless the team
buys that plugin.

## 9. Red proof

Last run 17 Nov 2026, on JDK 21, Kotlin 2.0.21, Detekt 1.23.8, Kover 0.9.1, CPD plugin 3.5 with PMD 7.29.0,
Cucumber 7.18.0 and Konsist 0.17.3, in a throwaway repo with two builds (one nested two levels down) sharing one
`build-logic`:

- `scripts/gradle-builds.sh check` passes in both builds; each logs `BDD_RUN PASS module=<name>` to the one
  repo-level log.
- Each gate fails on a deliberate break: a ktlint spacing rule (`detekt`), a duplicated function (`cpdCheck`),
  an untested object (`koverVerify`), `@Suppress("MagicNumber")` (the Konsist test), and a scenario with an
  undefined step (`test`, logged `BDD_RUN FAIL`).
- `test --tests ArchitectureBoundaryTest` logs nothing.
