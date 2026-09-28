# Stack: gradle-kotlin

Build-side changes that make the core gates meaningful. Make them in the
target repo's `build.gradle.kts`. The reference implementation is
`genai-service-gradle-plugin`, where all of this runs today.

## 1. BDD runner: Cucumber-JVM on the JUnit Platform

```kotlin
dependencies {
    testImplementation(platform("io.cucumber:cucumber-bom:<latest>"))
    testImplementation("io.cucumber:cucumber-java")
    testImplementation("io.cucumber:cucumber-junit-platform-engine")
    testImplementation("org.junit.platform:junit-platform-suite")
}
tasks.test { useJUnitPlatform() }
```

- Put features under `src/test/resources/features/` (subfolders are fine).
- Add one `@Suite @IncludeEngines("cucumber")` runner class. Name it
  `RunCucumberTest` so the logging task below finds its result XML.
- Cucumber 7+ is strict by default: undefined and pending steps fail. Do not
  turn strictness off, or a new scenario can never go red.

## 2. BDD run logging (native, runs pass or fail)

Copy `templates/bdd-run-logging.gradle.kts` into `build.gradle.kts`. Set
`RESULT_XML` to the runner's result file.

Why `finalizedBy` and not `doLast`: Gradle skips later `doLast` actions when
the task's own action throws. A failed test run is exactly that case, and it
is the one that matters most. `finalizedBy` runs regardless.

## 3. Complexity gate: Detekt

```kotlin
plugins { id("io.gitlab.arturbosch.detekt") version "<latest>" }
detekt { buildUponDefaultConfig = true }
tasks.check { dependsOn(tasks.named("detekt")) }
```

Use Detekt's own default thresholds. Do not invent numbers. Greenfield repos
get no `baseline.xml`. An existing repo may need a baseline at first; say so
explicitly to the user.

## 4. Architecture gate: Konsist

```kotlin
testImplementation("com.lemonappdev:konsist:<latest>")
```

Copy `templates/ArchitectureBoundaryTest.kt` into `src/test/kotlin/...`. Set
the core package and the forbidden import prefixes for this repo.

## 5. Config review

Check `.claude/bdd-gates.json`:
- `prodPatterns`: add `src/main/java/*.java` if the repo mixes in Java.
- Multi-module build: use `*/src/main/kotlin/*.kt` and `*/src/test/resources/features/*.feature`.
- `lintCommand` runs after every `.kt`/`.kts` edit. If Detekt is slow on a big
  repo, consider `detektMain` for a single module.

## 6. Red proof

Write one scenario with no step definitions. Run `./gradlew test`. Confirm
the log line `BDD_RUN FAIL` appears in `.claude/tdd-events.log`.
