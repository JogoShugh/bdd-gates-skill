package your.pkg.domain

import com.lemonappdev.konsist.api.Konsist
import com.lemonappdev.konsist.api.verify.assertFalse
import org.junit.jupiter.api.Test

// bdd-gates: the hexagonal boundary as a failing test, not a paragraph.
// Set CORE_PACKAGE and FORBIDDEN_PREFIXES for this repo.
class ArchitectureBoundaryTest {

    private val corePackage = "..domain.."
    private val forbiddenPrefixes = listOf("org.gradle", "org.eclipse.jgit")

    @Test
    fun `core files import no framework or infrastructure types`() {
        Konsist.scopeFromProject()
            .files
            .filter { it.hasPackage(corePackage) }
            .assertFalse { file ->
                file.hasImport { import -> forbiddenPrefixes.any { import.name.startsWith(it) } }
            }
    }
}
