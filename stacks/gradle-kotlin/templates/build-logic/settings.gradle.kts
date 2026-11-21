// bdd-gates: the convention plugins every Kotlin build in this repo applies, defined once.
// Each build includes this one in its settings.gradle.kts:
//   pluginManagement { includeBuild("<path to>/build-logic") }
// and applies, in each module's build.gradle.kts:
//   plugins { id("bddgates.kotlin-quality"); id("bddgates.bdd-log") }
rootProject.name = "build-logic"

dependencyResolutionManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}
