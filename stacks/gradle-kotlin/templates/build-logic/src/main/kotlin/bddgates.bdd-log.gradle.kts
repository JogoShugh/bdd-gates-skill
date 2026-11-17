// bddgates.bdd-log: records every test run, failed ones included, for the pre-commit TDD-ordering check.
// Applied to every module that runs Cucumber features; nothing to set.
//   - The run is recorded by the repo's own bdd-gates (.claude/bdd-gates/record-run.sh), found by walking up
//     to .claude/bdd-gates.json, so a build nested anywhere in the repo records to the same log.
//   - PASS or FAIL comes from every JUnit XML of a class named *RunCucumberTest, summed.
//   - Each scenario's own result comes from Cucumber's message stream, which the runner writes to
//     build/cucumber/messages.ndjson (RunCucumberTest's "message:" plugin); the stream is cleared before
//     each run, so an old one never stands in for a new run.
//   - finalizedBy, not doLast: Gradle skips later actions when the test task fails, the run that matters most.
//   - A compile failure is recorded as FAIL reason=compile, which the pre-commit check does not count as red.
//   - `test --tests SomeClass` that leaves the features out is not a BDD run: nothing is recorded.
val gateRoot: File = generateSequence(rootDir) { it.parentFile }
    .firstOrNull { File(it, ".claude/bdd-gates.json").exists() } ?: rootDir
val module: String = project.path.removePrefix(":").ifEmpty { rootProject.name }
val messages: File = layout.buildDirectory.file("cucumber/messages.ndjson").get().asFile

fun record(status: String, vararg fields: String) {
    val recorder = File(gateRoot, ".claude/bdd-gates/record-run.sh")
    check(recorder.canExecute()) { "bdd-gates is not installed in $gateRoot: no ${recorder.path}" }
    val command = listOf(recorder.path, status, "module=$module", *fields) +
        if (messages.exists()) listOf("messages=${messages.path}", "within=${projectDir.path}") else emptyList()
    val process = ProcessBuilder(command).directory(gateRoot).inheritIO().start()
    check(process.waitFor() == 0) { "record-run.sh failed for $module" }
}

val logBddRun by tasks.registering {
    group = "verification"
    description = "Records the BDD run for the pre-commit TDD-ordering check, scenario by scenario."
    doLast {
        val compileFailed = listOf("compileKotlin", "compileTestKotlin")
            .mapNotNull { tasks.findByName(it) }
            .any { it.state.failure != null }
        if (compileFailed) {
            record("FAIL", "reason=compile")
            return@doLast
        }
        val test = tasks.named<Test>("test").get()
        if (!test.state.executed) return@doLast
        val results = layout.buildDirectory.dir("test-results/test").get().asFile
            .listFiles { file -> file.name.startsWith("TEST-") && file.name.endsWith("RunCucumberTest.xml") }
            .orEmpty()
        val filtered = gradle.startParameter.taskRequests.any { request -> request.args.any { it.startsWith("--tests") } }
        if (results.isEmpty() && filtered) return@doLast
        if (results.isEmpty()) {
            record("FAIL", "reason=no-results")
            return@doLast
        }
        fun total(name: String) = results.sumOf { file ->
            Regex("""$name="(\d+)"""").find(file.readText())?.groupValues?.get(1)?.toInt() ?: 0
        }
        val status = if (total("failures") == 0 && total("errors") == 0) "PASS" else "FAIL"
        record(status, "total=${total("tests")}", "failures=${total("failures")}", "errors=${total("errors")}")
    }
}

tasks.named<Test>("test") {
    doFirst { messages.delete() }
    finalizedBy(logBddRun)
}
listOf("compileKotlin", "compileTestKotlin").forEach { name ->
    tasks.matching { it.name == name }.configureEach { finalizedBy(logBddRun) }
}
