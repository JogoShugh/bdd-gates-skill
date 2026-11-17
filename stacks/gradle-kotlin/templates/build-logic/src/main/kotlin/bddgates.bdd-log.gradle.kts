// bddgates.bdd-log: records "BDD_RUN PASS|FAIL" after every test run, failed ones included, for the
// pre-commit TDD-ordering check. Applied to every module that runs Cucumber features; nothing to set.
//   - The log is the repo's .claude/tdd-events.log, found by walking up to .claude/bdd-gates.json, so a
//     build nested anywhere in the repo logs to the same file.
//   - The result is every JUnit XML of a class named *RunCucumberTest, summed.
//   - finalizedBy, not doLast: Gradle skips later actions when the test task fails, the run that matters most.
//   - A compile failure is logged as FAIL reason=compile. The pre-commit check does not count it as the red
//     run: a scenario must fail on its behaviour, so write step definitions that compile first.
import java.time.Instant
import java.time.temporal.ChronoUnit

val gateRoot: File = generateSequence(rootDir) { it.parentFile }
    .firstOrNull { File(it, ".claude/bdd-gates.json").exists() } ?: rootDir
val module: String = project.path.removePrefix(":").ifEmpty { rootProject.name }

val logBddRun by tasks.registering {
    group = "verification"
    description = "Appends a BDD_RUN fact to .claude/tdd-events.log for the pre-commit TDD-ordering check."
    doLast {
        val logFile = File(gateRoot, ".claude/tdd-events.log")
        logFile.parentFile.mkdirs()
        val timestamp = Instant.now().truncatedTo(ChronoUnit.SECONDS)
        val compileFailed = listOf("compileKotlin", "compileTestKotlin")
            .mapNotNull { tasks.findByName(it) }
            .any { it.state.failure != null }
        if (compileFailed) {
            logFile.appendText("$timestamp BDD_RUN FAIL module=$module reason=compile\n")
            return@doLast
        }
        val test = tasks.named<Test>("test").get()
        if (!test.state.executed) return@doLast
        val results = layout.buildDirectory.dir("test-results/test").get().asFile
            .listFiles { file -> file.name.startsWith("TEST-") && file.name.endsWith("RunCucumberTest.xml") }
            .orEmpty()
        // `test --tests SomeClass` that leaves the features out is not a BDD run: nothing to record.
        val filtered = gradle.startParameter.taskRequests.any { request -> request.args.any { it.startsWith("--tests") } }
        if (results.isEmpty() && filtered) return@doLast
        if (results.isEmpty()) {
            logFile.appendText("$timestamp BDD_RUN FAIL module=$module reason=no-results\n")
            return@doLast
        }
        fun total(name: String) = results.sumOf { file ->
            Regex("""$name="(\d+)"""").find(file.readText())?.groupValues?.get(1)?.toInt() ?: 0
        }
        val status = if (total("failures") == 0 && total("errors") == 0) "PASS" else "FAIL"
        logFile.appendText(
            "$timestamp BDD_RUN $status module=$module total=${total("tests")} " +
                "failures=${total("failures")} errors=${total("errors")}\n",
        )
    }
}

tasks.named("test") { finalizedBy(logBddRun) }
listOf("compileKotlin", "compileTestKotlin").forEach { name ->
    tasks.matching { it.name == name }.configureEach { finalizedBy(logBddRun) }
}
