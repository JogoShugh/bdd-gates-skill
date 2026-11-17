plugins {
    `kotlin-dsl`
}

// The tools the convention plugins apply. Their versions live here only; a build that applies the
// plugins names none of them. detekt 1.23.x runs on Kotlin 2.0.21; keep the builds on Kotlin 2.0.x
// until detekt 2 is released.
dependencies {
    implementation("io.gitlab.arturbosch.detekt:detekt-gradle-plugin:1.23.8")
    implementation("org.jetbrains.kotlinx:kover-gradle-plugin:0.9.1")
    implementation("de.aaschmid:gradle-cpd-plugin:3.5")
}
