// bddgates.kotlin-quality: what every Kotlin module is checked with, in one place.
//   detekt      complexity and style at detekt's own defaults, and ktlint's whole rule set (detekt-formatting).
//               `detekt` (no type information) is the fast gate run after every edit; `check` also runs
//               detektMain and detektTest, which see types and so apply more rules.
//   Kover       coverage of the plain test task; `check` fails under MIN_COVERAGE percent of lines.
//   CPD         PMD's copy-paste detector over the module's production Kotlin; `check` fails on a duplicate.
//               A duplicate kept on purpose is wrapped in // CPD-OFF and // CPD-ON, with the reason.
// Thresholds are the tools' defaults, except MIN_COVERAGE, which is a policy: set it with the team.
plugins {
    id("io.gitlab.arturbosch.detekt")
    id("org.jetbrains.kotlinx.kover")
    id("de.aaschmid.cpd")
}

val detektVersion = "1.23.8"
val pmdVersion = "7.29.0"
val minCoverage = 80

dependencies {
    "cpd"("net.sourceforge.pmd:pmd-kotlin:$pmdVersion")
    "detektPlugins"("io.gitlab.arturbosch.detekt:detekt-formatting:$detektVersion")
}

detekt {
    buildUponDefaultConfig = true
}

kover {
    reports {
        verify {
            rule {
                minBound(minCoverage)
            }
        }
    }
}

// Coverage only from the plain test task: another Test task (a live or slow suite) is not run for it.
afterEvaluate {
    kover {
        currentProject {
            instrumentation {
                disabledForTestTasks.addAll(tasks.withType<Test>().names.filter { it != "test" })
            }
        }
    }
}

cpd {
    language = "kotlin"
    toolVersion = pmdVersion
    minimumTokenCount = 100
}

tasks.named<de.aaschmid.gradle.plugins.cpd.Cpd>("cpdCheck") {
    source = fileTree("src/main/kotlin")
    reports {
        xml.required.set(true)
        text.required.set(true)
    }
}

tasks.named("check") {
    dependsOn("detektMain", "detektTest", "koverVerify")
}

// -Pformat.only=main|test narrows `detekt` to one source tree, so a formatting pass
// (./gradlew detekt --auto-correct -Pformat.only=test) fixes test code and production code in
// separate commits: a refactor-mode commit may not change tests.
providers.gradleProperty("format.only").orNull?.let { only ->
    tasks.named<io.gitlab.arturbosch.detekt.Detekt>("detekt") {
        setSource(files("src/$only/kotlin", "src/$only/java"))
    }
}
