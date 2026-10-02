allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// ---------------------------------------------------------------------------
// Kotlin incremental compilation cannot span drives (fixed 2026-10-02)
// ---------------------------------------------------------------------------
// The pub cache lives on C: (C:\Users\hp\AppData\Local\Pub\Cache\...) while this
// project lives on D:. Kotlin's incremental compiler stores *relative* paths in
// its cache, so it tries to relativise
//   C:\...\speech_to_text-7.5.0\android\src\main\kotlin\...\SpeechToTextPlugin.kt
// against the project root on D:. No relative path exists between two drives, so
// it throws:
//   IllegalArgumentException: this and base files have different roots
// and then fails to close the incremental caches:
//   :speech_to_text:compileDebugKotlin ... Could not close incremental caches
//
// This is a Kotlin-on-Windows limitation, not a problem with the plugin or with
// our code — it would hit any Kotlin-source plugin while the cache and the
// project sit on different drives. Opting these subprojects out of Kotlin
// incremental compilation makes them compile non-incrementally, which needs no
// cross-drive relative path.
//
// Cost: recompiling these plugin sources on each build instead of reusing the
// cache. They are small and change only when the dependency version bumps.
//
// If a future Kotlin/Gradle release fixes the underlying issue, this block can
// be deleted and the build should still work.
subprojects {
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        incremental = false
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
