// bdd-gates: records "BDD_RUN PASS|FAIL" after every test run, including failed ones.
// Needs: import java.time.Instant and java.time.temporal.ChronoUnit at the top of the build script.

val logBddRun by tasks.registering {
    group = "verification"
    description = "Appends a BDD_RUN fact to .claude/tdd-events.log for the pre-commit TDD-ordering check."
    doLast {
        // RESULT_XML: the JUnit XML written for the Cucumber suite runner class.
        val resultFile = file("build/test-results/test/TEST-<your.package>.RunCucumberTest.xml")
        val logFile = file(".claude/tdd-events.log")
        val timestamp = Instant.now().truncatedTo(ChronoUnit.SECONDS)
        logFile.parentFile.mkdirs()
        if (!resultFile.exists()) {
            // No result file means compilation or discovery failed: still red.
            logFile.appendText("$timestamp BDD_RUN FAIL reason=no-results\n")
            return@doLast
        }
        val xml = resultFile.readText()
        fun attr(name: String) = Regex("""$name="(\d+)"""").find(xml)?.groupValues?.get(1) ?: "0"
        val status = if (attr("failures") == "0" && attr("errors") == "0") "PASS" else "FAIL"
        logFile.appendText(
            "$timestamp BDD_RUN $status total=${attr("tests")} failures=${attr("failures")} errors=${attr("errors")}\n",
        )
    }
}

tasks.test {
    finalizedBy(logBddRun)
}
