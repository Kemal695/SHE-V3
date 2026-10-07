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
// TWO independent Kotlin failures hit `flutter build apk` on this box
// ---------------------------------------------------------------------------
// 1) `:gradle:compileKotlin` — the Kotlin daemon is denied write/delete access
//    under <flutterSdk>/packages/flutter_tools/gradle/build, so the
//    delete-before-recompile step always fails. The reported error ("Unable to
//    delete ... a process has files open") is misleading; the real cause is
//    java.nio.file.AccessDeniedException in the Kotlin daemon log against a path
//    where the user has full control.
//
//    This was originally blamed on WDAC. That was NOT proven (corrected
//    2026-10-02). The reproducible cause is a process-scoped write denial
//    outside the project tree — a child process cannot write into the Flutter
//    SDK even though the interactive shell can:
//        cmd /c "echo x > <flutterSdk>\packages\flutter_tools\gradle\__t__.tmp"
//        -> Access is denied.
//    Don't go chasing Event ID 3033 again without re-testing that first.
//
//    It CANNOT be fixed from this file — the Flutter Gradle plugin is an
//    *included* build and Gradle offers no API to redirect an included build's
//    output. Fix it with the junction, which moves those bytes into the project
//    tree (writable from both a sandboxed build and a normal one):
//
//        python scripts/prepare-flutter-gradle-dir.py
//
//    The junction target is `mobile/.flutter-gradle-plugin-build` — NOT under
//    `mobile/build`, which `clean` deletes (that used to leave the junction
//    dangling and break the build unrecoverably). Re-run the script any time the
//    build fails here; it is idempotent and repairs a dangling junction.
//
//    (See the build-verify skill for the full evidence chain.)
//
// 2) `:<plugin>:compileDebugKotlin` for plugins with Kotlin sources (e.g.
//    speech_to_text) — the compilation SUCCEEDS and then fails closing its
//    incremental caches:
//
//      Could not close incremental caches in
//        .../build/<plugin>/kotlin/compileDebugKotlin/cacheable/caches-jvm/...
//
//    Cause: the plugin's sources are in the pub cache on `C:`, but the cache is
//    written under this project on `D:`. Kotlin's incremental cache stores
//    *relative* paths, and no relative path exists between two drives, so it
//    throws `IllegalArgumentException: this and base files have different roots`
//    (visible in the Kotlin daemon log's suppressed chain).
//
//    Unlike (1), this one IS fixable here, and `incremental = false` is the
//    right remedy: non-incremental compilation writes no such cache.
//
// These two were previously conflated into a single wrong diagnosis. They are
// separate: fixing (1) is what unblocked `:gradle`, and only afterwards did (2)
// become visible as its own failure.
//
// Cost of (2): these plugin sources recompile each build instead of reusing a
// cache. They are small and change only when a dependency version bumps.
//
// Implementation note: applied in `gradle.projectsEvaluated`, NOT via
// `subprojects { tasks.matching { ... }.configureEach { ... } }`.
//
// The plugin subprojects (speech_to_text, firebase_core, ...) are added by
// Flutter's plugin loader and apply the Kotlin plugin *after* this root
// buildscript has been evaluated, so they overwrite anything set earlier.
// Verified by probing the live task: with an early `configureEach`, `:app` had
// `incremental=false` while `:speech_to_text` still had `true`.
// `projectsEvaluated` fires once every project has been configured, which is the
// only point where this sticks for all of them.
// ---------------------------------------------------------------------------
gradle.projectsEvaluated {
    allprojects {
        tasks.matching { it.name.startsWith("compile") && it.name.endsWith("Kotlin") }
            .configureEach {
                if (this is org.jetbrains.kotlin.gradle.tasks.KotlinCompile) {
                    incremental = false
                }
            }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
