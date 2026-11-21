#!/usr/bin/env bash
# End-to-end proof of the gradle-kotlin stack: real Gradle, real Cucumber-JVM, the real hooks and pre-commit.
# Builds a throwaway repo with two Gradle builds sharing build-logic, installs the gates, then walks one
# Gherkin-first cycle scenario by scenario, checks that a commit with no red run for the new scenario is
# refused, and that each quality tool fails on code planted to break it. Needs a JDK 21 (JAVA_HOME), Node 18+, and the network the first time (Gradle, Maven Central, npm).
#   scripts/e2e-gradle-kotlin.sh [work-dir]
set -uo pipefail

skill_dir=$(cd "$(dirname "$0")/.." && pwd)
templates=$skill_dir/stacks/gradle-kotlin/templates
work=${1:-$(mktemp -d)}
repo=$work/e2e-repo
passed=0
failed=0
ok() { passed=$((passed + 1)); echo "  PASS  $1"; }
bad() { failed=$((failed + 1)); echo "  FAIL  $1"; }

[ ! -e "$repo" ] || { echo "$repo exists; pass an empty work dir" >&2; exit 1; }
mkdir -p "$repo" && cd "$repo" || exit 1
git init -q && git config user.email e2e@example.com && git config user.name e2e
printf 'build/\n.gradle/\n.kotlin/\n' > .gitignore
git add .gitignore && git commit -q -m init

cp -R "$templates/build-logic" . && mkdir -p scripts && cp "$templates/gradle-builds.sh" scripts/
wrapper_from=$(cd "$skill_dir/../artie/domains/tolls" 2>/dev/null && pwd || true)
build() { # <dir> <name> <path to build-logic>
  local d=$1
  mkdir -p "$d/gradle" "$d/src/main/kotlin/demo/domain" "$d/src/test/kotlin/demo/domain" \
    "$d/src/test/kotlin/demo/bdd" "$d/src/test/resources/features"
  if [ -n "$wrapper_from" ]; then
    cp -R "$wrapper_from/gradle/wrapper" "$d/gradle/" && cp "$wrapper_from/gradlew" "$d/"
  else
    (cd "$d" && gradle wrapper -q) || { echo "need a Gradle wrapper to copy, or gradle on the PATH" >&2; exit 1; }
  fi
  printf 'pluginManagement { includeBuild("%s/build-logic") }\nrootProject.name = "%s"\n' "$3" "$2" > "$d/settings.gradle.kts"
  cat > "$d/build.gradle.kts" <<'EOF'
plugins {
    kotlin("jvm") version "2.0.21"
    id("bddgates.kotlin-quality")
    id("bddgates.bdd-log")
}
repositories { mavenCentral() }
dependencies {
    testImplementation(kotlin("test"))
    testImplementation(platform("io.cucumber:cucumber-bom:7.18.0"))
    testImplementation("io.cucumber:cucumber-java")
    testImplementation("io.cucumber:cucumber-junit-platform-engine")
    testImplementation("org.junit.platform:junit-platform-suite")
    testImplementation("com.lemonappdev:konsist:0.17.3")
}
kotlin { jvmToolchain(21) }
tasks.test { useJUnitPlatform() }
EOF
  cat > "$d/src/main/kotlin/demo/domain/Lamp.kt" <<'EOF'
package demo.domain

/** A lamp that is on or off. */
data class Lamp(val on: Boolean = false) {
    fun switched(): Lamp = copy(on = !on)
}
EOF
  cat > "$d/src/test/resources/features/lamp.feature" <<'EOF'
Feature: A lamp
  Scenario: Switching a lamp that is off turns it on
    Given a lamp that is off
    When it is switched
    Then it is on
EOF
  cat > "$d/src/test/kotlin/demo/bdd/RunCucumberTest.kt" <<'EOF'
package demo.bdd

import io.cucumber.junit.platform.engine.Constants.GLUE_PROPERTY_NAME
import io.cucumber.junit.platform.engine.Constants.PLUGIN_PROPERTY_NAME
import org.junit.platform.suite.api.ConfigurationParameter
import org.junit.platform.suite.api.IncludeEngines
import org.junit.platform.suite.api.SelectClasspathResource
import org.junit.platform.suite.api.Suite

@Suite
@IncludeEngines("cucumber")
@SelectClasspathResource("features")
@ConfigurationParameter(key = GLUE_PROPERTY_NAME, value = "demo.bdd")
@ConfigurationParameter(key = PLUGIN_PROPERTY_NAME, value = "message:build/cucumber/RunCucumberTest.ndjson")
class RunCucumberTest
EOF
  cat > "$d/src/test/kotlin/demo/bdd/LampSteps.kt" <<'EOF'
package demo.bdd

import demo.domain.Lamp
import io.cucumber.java.en.Given
import io.cucumber.java.en.Then
import io.cucumber.java.en.When
import kotlin.test.assertTrue

class LampSteps {
    private var lamp = Lamp()

    @Given("a lamp that is off")
    fun off() {
        lamp = Lamp(on = false)
    }

    @When("it is switched")
    fun switch() {
        lamp = lamp.switched()
    }

    @Then("it is on")
    fun isOn() = assertTrue(lamp.on)
}
EOF
  # java.net stands in for a framework: it is on every classpath, so a core import of it compiles and only
  # Konsist can catch it.
  sed -e 's/your.pkg.domain/demo.domain/' -e 's/listOf("org.gradle"/listOf("java.net", "org.gradle"/' \
    "$templates/ArchitectureBoundaryTest.kt" > "$d/src/test/kotlin/demo/domain/ArchitectureBoundaryTest.kt"
}
build alpha alpha ..
build nested/beta beta ../..
"$skill_dir/scripts/install.sh" gradle-kotlin "$repo" >/dev/null 2>&1 || { echo "install failed" >&2; exit 1; }
git config core.hooksPath .githooks
git add -A && git commit -q --no-verify -m "two builds, gated"
gates=$repo/.claude/bdd-gates
log=$repo/.claude/tdd-events.log
hook() { printf '{"tool_input":{"file_path":"%s/%s"}}' "$repo" "$2" | CLAUDE_PROJECT_DIR=$repo "$gates/$1"; }

echo "baseline"
scripts/gradle-builds.sh check >/dev/null 2>&1 && ok "check passes in both builds" || bad "check fails on the baseline"

echo "one Gherkin-first cycle"
feature=alpha/src/test/resources/features/lamp.feature
lamp=alpha/src/main/kotlin/demo/domain/Lamp.kt
hook gherkin-first.sh "$lamp" 2>/dev/null && bad "production write allowed before any scenario" || ok "production write blocked before any scenario"
printf '\n  Scenario: A lamp has a colour\n    Given a red lamp\n    Then it is red\n' >> "$feature"
hook log-event.sh "$feature"
hook lint.sh "$feature" 2>/dev/null && ok "the new scenario passes the feature lint" || bad "feature lint failed"
hook gherkin-first.sh "$lamp" 2>/dev/null && ok "production write allowed after the new scenario" || bad "production write still blocked"
scripts/gradle-builds.sh test >/dev/null 2>&1 && bad "the red run passed" || ok "the red run fails"
red=$(grep ' BDD_RUN FAIL module=alpha' "$log" | tail -1 | sed -n 's/.* results=\([^ ]*\).*/\1/p')
[ -n "$red" ] && [ "$(jq -r --arg k "$feature :: A lamp has a colour" '.[$k]' "$red")" = UNDEFINED ] \
  && ok "the red run recorded the new scenario as UNDEFINED, by its source path" || bad "red run results: $red"
cat > "$lamp" <<'EOF'
package demo.domain

/** A lamp that is on or off, of a colour. */
data class Lamp(val on: Boolean = false, val colour: String = "white") {
    fun switched(): Lamp = copy(on = !on)
}
EOF
hook log-event.sh "$lamp"
cat > alpha/src/test/kotlin/demo/bdd/ColourSteps.kt <<'EOF'
package demo.bdd

import demo.domain.Lamp
import io.cucumber.java.en.Given
import io.cucumber.java.en.Then
import kotlin.test.assertEquals

class ColourSteps {
    private var lamp = Lamp()

    @Given("a red lamp")
    fun red() {
        lamp = Lamp(colour = "red")
    }

    @Then("it is red")
    fun isRed() = assertEquals("red", lamp.colour)
}
EOF
scripts/gradle-builds.sh test >/dev/null 2>&1 && ok "the green run passes" || bad "the green run fails"
git add -A
.githooks/pre-commit >/dev/null 2>&1 && ok "pre-commit accepts the cycle, scenario by scenario" || bad "pre-commit refused the cycle: $(.githooks/pre-commit 2>&1 | head -5)"
git commit -q -m "a lamp has a colour" 2>/dev/null

echo "a cycle whose red run failed, but not on its own scenario"
printf '\n  Scenario: A lamp can be blue\n    Given a blue lamp\n    Then it is blue\n' >> "$feature"
hook log-event.sh "$feature"
# The steps exist already, so the new scenario passes; an old scenario is broken instead, so the run is red.
steps=alpha/src/test/kotlin/demo/bdd/LampSteps.kt
cp "$steps" "$steps.keep"
sed -i.bak 's/assertTrue(lamp.on)/assertTrue(!lamp.on)/' "$steps" && rm -f "$steps.bak"
cat >> alpha/src/test/kotlin/demo/bdd/ColourSteps.kt <<'EOF'

class BlueSteps {
    private var lamp = Lamp()

    @Given("a blue lamp")
    fun blue() {
        lamp = Lamp(colour = "blue")
    }

    @Then("it is blue")
    fun isBlue() = assertEquals("blue", lamp.colour)
}
EOF
scripts/gradle-builds.sh test >/dev/null 2>&1 && bad "the run with a broken old scenario passed" || ok "a red run, from an unchanged scenario"
mv "$steps.keep" "$steps"
printf '\n/** The colours a lamp comes in. */\nval colours = listOf("white", "red", "blue")\n' >> "$lamp"
hook log-event.sh "$lamp"
scripts/gradle-builds.sh test >/dev/null 2>&1 && ok "green again" || bad "not green again"
git add -A
out=$(.githooks/pre-commit 2>&1) && bad "pre-commit accepted a scenario never seen red" \
  || { printf '%s' "$out" | grep -q "none of the scenarios this change adds or changes was seen failing" \
    && ok "pre-commit refuses it: the new scenario was never seen red" || bad "refused for another reason: $out"; }

echo "the quality tools fail on bad code"
git reset -q --hard
domain=alpha/src/main/kotlin/demo/domain
# Each case plants one file, runs the task that should catch it, expects that task to fail naming the
# problem, and removes the file. The file is written first, not piped in: a pipe would run the case in a
# subshell and lose its count. Usage: red_case <what> <expected text> <file> <gradle task...>
red_case() {
  local what=$1 expected=$2 file=$3 out
  shift 3
  out=$(cd alpha && ./gradlew --console=plain "$@" 2>&1) && bad "$what: $* passed" \
    || { printf '%s' "$out" | grep -q "$expected" && ok "$what: $* fails, naming $expected" \
      || bad "$what: $* failed for another reason: $(printf '%s' "$out" | grep -E 'FAILED|rror|violat' | head -3)"; }
  rm -f "$file"
}
{ printf 'package demo.domain\n\n/** Counts to sixty-two, one statement at a time. */\nfun counted(): Int {\n    var total = 0\n'
  for _ in $(seq 62); do printf '    total += 1\n'; done
  printf '    return total\n}\n'; } > "$domain/Counted.kt"
red_case "a long method" LongMethod "$domain/Counted.kt" detekt
copied() { # <name>: a block well over CPD's default of 100 tokens
  printf 'package demo.domain\n\n/** A copied block. */\nfun %s(a: Int, b: Int): List<Int> {\n' "$1"
  for n in $(seq 25); do printf '    val v%s = listOf(a + %s, b - %s).map { it * a }.filter { it > b }\n' "$n" "$n" "$n"; done
  printf '    return listOf(a)\n}\n'
}
copied first > "$domain/First.kt"
copied second > "$domain/Second.kt"
red_case "a copied block" "CPD found duplicate code" "$domain/Second.kt" cpdCheck
rm -f "$domain/First.kt"
{ printf 'package demo.domain\n\n/** Code no scenario reaches. */\nobject Untested {\n'
  for n in $(seq 12); do printf '    /** Step %s. */\n    fun step%s(x: Int): Int {\n        val y = x + %s\n        return y * y\n    }\n' "$n" "$n" "$n"; done
  printf '}\n'; } > "$domain/Untested.kt"
red_case "uncovered code" "expected minimum" "$domain/Untested.kt" koverVerify
printf 'package demo.domain\n\nimport java.net.URI\n\n/** A core type that knows about the network. */\nclass Fetched(val from: URI)\n' > "$domain/Fetched.kt"
red_case "a core import of a framework type" "core files import no framework" "$domain/Fetched.kt" \
  test --tests demo.domain.ArchitectureBoundaryTest
printf 'package demo.domain\n\n/** A rule switched off in place. */\n@Suppress("MagicNumber")\nfun answer(): Int = 42\n' > "$domain/Answer.kt"
red_case "a suppressed rule" "suppresses only the rules the team allows" "$domain/Answer.kt" \
  test --tests demo.domain.ArchitectureBoundaryTest
planned=$(cd alpha && ./gradlew --console=plain check --dry-run 2>&1)
for task in :detektMain :cpdCheck :koverVerify :test; do
  printf '%s' "$planned" | grep -q "^$task " && ok "check runs $task" || bad "check does not run $task"
done
scripts/gradle-builds.sh check >/dev/null 2>&1 && ok "check passes again with the planted code gone" || bad "check fails after the planted code is gone"

echo ""
echo "$passed passed, $failed failed (repo: $repo)"
[ "$failed" -eq 0 ]
