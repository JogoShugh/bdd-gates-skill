// bddgates.bdd-log: records every test run, failed ones included, for the pre-commit TDD-ordering check.
// Applied to every module that runs Cucumber features; nothing to set.
//   - The run is recorded by the repo's own bdd-gates (.claude/bdd-gates/record-run.sh), found by walking up
//     to .claude/bdd-gates.json, so a build nested anywhere in the repo records to the same log.
//   - PASS or FAIL comes from every JUnit XML of every Test task that ran (test, or a liveTest), summed: a module
//     may run its features in several suites, or through the Cucumber engine directly.
//   - Each scenario's own result comes from Cucumber's message streams under build/cucumber/: one per Test task
//     when the Cucumber engine runs directly (this plugin sets cucumber.plugin for it), and one per suite class
//     (its own "message:build/cucumber/<Suite>.ndjson", which takes precedence). Only streams written in this
//     build count, so an old one never stands in for a new run; record-run.sh deletes them once read.
//   - finalizedBy, not doLast: Gradle skips later actions when the test task fails, the run that matters most.
//   - A compile failure is recorded as FAIL reason=compile, which the pre-commit check does not count as red.
//   - A Test task that was up to date ran nothing, and `test --tests SomeClass` that leaves the features out is
//     not a BDD run: neither is recorded.
val gateRoot: File = generateSequence(rootDir) { it.parentFile }
    .firstOrNull { File(it, ".claude/bdd-gates.json").exists() } ?: rootDir
val module: String = project.path.removePrefix(":").ifEmpty { rootProject.name }
val streams: File = layout.buildDirectory.dir("cucumber").get().asFile
val buildStarted: Long = System.currentTimeMillis()

fun ndjson(): List<File> = streams.listFiles { file -> file.name.endsWith(".ndjson") }.orEmpty()
    .filter { it.lastModified() >= buildStarted }

fun record(status: String, vararg fields: String) {
    val recorder = File(gateRoot, ".claude/bdd-gates/record-run.sh")
    check(recorder.canExecute()) { "bdd-gates is not installed in $gateRoot: no ${recorder.path}" }
    val messages = ndjson().map { "messages=${it.path}" }
    val within = if (messages.isEmpty()) emptyList() else listOf("within=${projectDir.path}")
    val command = listOf(recorder.path, status, "module=$module", *fields) + messages + within
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
        val ran = tasks.withType<Test>().filter { it.state.didWork || it.state.failure != null }
        if (ran.isEmpty()) return@doLast
        val results = ran.flatMap { test ->
            test.reports.junitXml.outputLocation.get().asFile
                .listFiles { file -> file.name.startsWith("TEST-") && file.name.endsWith(".xml") }.orEmpty().toList()
        }
        val filtered = gradle.startParameter.taskRequests.any { request -> request.args.any { it.startsWith("--tests") } }
        if (filtered && ndjson().isEmpty()) return@doLast
        if (results.isEmpty()) {
            record("FAIL", "reason=no-results")
            return@doLast
        }
        fun total(name: String) = results.sumOf { file ->
            Regex("""$name="(\d+)"""").find(file.readText())?.groupValues?.get(1)?.toInt() ?: 0
        }
        val status = if (total("failures") == 0 && total("errors") == 0) "PASS" else "FAIL"
        record(
            status,
            "task=${ran.joinToString(",") { it.name }}",
            "total=${total("tests")}",
            "failures=${total("failures")}",
            "errors=${total("errors")}",
        )
    }
}

tasks.withType<Test>().configureEach {
    // For the Cucumber engine run directly; a suite class's own plugin setting takes precedence.
    systemProperty("cucumber.plugin", "message:${File(streams, "$name.ndjson").path}")
    finalizedBy(logBddRun)
}
listOf("compileKotlin", "compileTestKotlin").forEach { name ->
    tasks.matching { it.name == name }.configureEach { finalizedBy(logBddRun) }
}
