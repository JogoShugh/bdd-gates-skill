package your.pkg.domain

import com.lemonappdev.konsist.api.Konsist
import com.lemonappdev.konsist.api.verify.assertFalse
import org.junit.jupiter.api.Test

// bdd-gates: the hexagonal boundary as a failing test, not a paragraph, and no linter rule switched off
// in the file that breaks it. Set corePackage, forbiddenPrefixes and allowedSuppressions for this repo.
class ArchitectureBoundaryTest {

    private val corePackage = "..domain.."
    private val forbiddenPrefixes = listOf("org.gradle", "org.eclipse.jgit")

    /**
     * The only rules production code may suppress, each for a reason the team agreed. Anything else
     * suppressed fails here: change the code, or bring the rule to the team. This file is a quality
     * setting, so Claude may not edit it (protectedFiles).
     */
    private val allowedSuppressions = setOf(
        // Spring Boot's main(args) spreads its arguments once, at startup.
        "SpreadOperator",
    )

    private val suppressed = Regex("""@(?:file:)?Suppress\(([^)]*)\)""")

    @Test
    fun `core files import no framework or infrastructure types`() {
        Konsist.scopeFromProject()
            .files
            .filter { it.hasPackage(corePackage) }
            .assertFalse { file ->
                file.hasImport { import -> forbiddenPrefixes.any { import.name.startsWith(it) } }
            }
    }

    @Test
    fun `production code suppresses only the rules the team allows`() {
        Konsist.scopeFromProduction()
            .files
            .assertFalse { file ->
                suppressed.findAll(file.text)
                    .flatMap { match -> Regex(""""([^"]+)"""").findAll(match.groupValues[1]).map { it.groupValues[1] } }
                    .any { it !in allowedSuppressions }
            }
    }
}
