plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "et.she.v3.she_mobile"
    compileSdk = flutter.compileSdkVersion
    // ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "et.she.v3.she_mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true

        // The phone is arm64. sherpa-onnx's AAR carries all four ABIs (~48 MB of
        // native code); restricting to the two ARM ones keeps ~70 MB of x86
        // libraries out of the APK. NOTE: this also means the app no longer runs
        // on an x86_64 emulator — use the device.
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")

            // Keep diagnostic logging in release builds. AGP's default *optimize*
            // rules strip Log.v/d/i via -assumenosideeffects, which erases the
            // Espressif BLE provisioning library's (and our plugin's) diagnostic
            // output — only Log.e survives. AGP refuses
            // getDefaultProguardFile("proguard-android.txt") outright ("no longer
            // supported since it includes -dontoptimize"), so we keep the optimize
            // file and try to neutralise the stripping from our own rules file.
            // NOTE: turning R8 off entirely (isMinifyEnabled = false) also works but
            // needs new Gradle transform workspaces, which the sandbox denies here.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    // sherpa-onnx's .so files are loaded with System.loadLibrary, so they must be
    // extracted at install time (legacy packaging) rather than mmapped from the
    // APK.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    // sherpa-onnx reads the KWS model through AAssetManager in BUFFER mode,
    // which needs the whole file in memory. Leaving the .onnx files compressed
    // works but makes that read slower and more fragile on a low-end device.
    androidResources {
        noCompress += "onnx"
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")

    // Robi wake word (Phase 4): sherpa-onnx keyword spotting.
    //
    // Replaces Vosk, which was a general speech-to-text model asked to transcribe
    // a coined name — measured on the LE6 it returned "huh", "yeah catfish",
    // "and i'm irish know him" and never the phrase. sherpa-onnx does not
    // transcribe: it matches the audio against a keyword model, so "HEY ROBI"
    // works even though "Robi" is not a word. See docs/robi-phase4-wake-word.md.
    //
    // The AAR is vendored in app/libs because it is not published to Maven
    // Central. Local AARs also need a flat directory repository.
    implementation(files("libs/sherpa-onnx.aar"))
}
