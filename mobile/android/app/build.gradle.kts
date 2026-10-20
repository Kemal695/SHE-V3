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

    // Vosk ships native .so files. AGP 8 compresses jniLibs by default, and the
    // loader then cannot mmap them at runtime — the classic
    // "UnsatisfiedLinkError: couldn't find libvosk.so" failure.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
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

    // Robi wake word (Phase 4). On-device keyword detection, Apache-2.0, no
    // account or API key. Model is downloaded at runtime — see RobiModel.kt.
    implementation("com.alphacephei:vosk-android:0.3.47")
    // vosk-android reaches its native lib through JNA; the @aar is required.
    implementation("net.java.dev.jna:jna:5.13.0@aar")
}
