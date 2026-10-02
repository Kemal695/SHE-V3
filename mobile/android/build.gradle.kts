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
// Kotlin / Android build failures on this WDAC-hardened box
// ---------------------------------------------------------------------------
// If `flutter build apk` fails at `:gradle:compileKotlin` with
//
//   IOException: Unable to delete directory
//     '<flutterSdk>/packages/flutter_tools/gradle/build/classes/kotlin/main'
//     Failed to delete some children. This might happen because a process has
//     files open or has its working directory set in the target directory.
//
// ignore the "files open" wording — it is a red herring. The Kotlin daemon is
// actually being refused DELETE permission there by Windows Defender Application
// Control (verified: java.nio.file.AccessDeniedException in the Kotlin daemon
// log, against a path where icacls grants full control and the user can delete
// by hand). The Flutter Gradle plugin is an *included* build that lives inside
// the SDK, and there is no supported Gradle API to redirect an included build's
// output directory — so it cannot be fixed from this file.
//
// Fix it with the junction, which relocates those bytes off the protected path:
//
//     python scripts/prepare-flutter-gradle-dir.py
//
// See the build-verify skill for the full diagnosis.
// ---------------------------------------------------------------------------

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
