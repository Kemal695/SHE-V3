# =============================================================================
# SHE V3 — R8 / ProGuard rules (release builds)
# =============================================================================
# Keep diagnostic logging.
#
# AGP's default *optimize* proguard file carries `-assumenosideeffects` rules that
# delete every Log.v/d/i call. That silently removes the entire diagnostic output
# of the Espressif BLE provisioning library AND of flutter_esp_ble_prov, leaving
# only Log.e — so a release APK reports "Session could not be established" with
# no way to see why (which characteristic was missing, what the GATT write status
# was, whether the MTU negotiation failed, …). Debugging BLE provisioning in a
# release build is impossible without these calls, so disable optimisation.
#
# Trade-off: a slightly larger/slower APK in exchange for debuggable release
# builds. If that ever matters for shipping, drop `-dontoptimize` and instead
# narrow the rules to just the provisioning packages below.
-dontoptimize

# The Espressif provisioning library is reached by reflection / EventBus and
# must not be renamed or stripped.
-keep class com.espressif.provisioning.** { *; }
-keep class org.greenrobot.eventbus.** { *; }
-keepclassmembers class ** {
    @org.greenrobot.eventbus.Subscribe <methods>;
}
-keep enum org.greenrobot.eventbus.ThreadMode { *; }

# CRITICAL: the protobuf-javalite messages generated for the provisioning
# protocol live in the bare `espressif` package (espressif.Sec1$SessionCmd0,
# espressif.Session$SessionData, …), NOT under com.espressif.provisioning, so
# the rule above does not cover them. GeneratedMessageLite reaches into them
# reflectively. If they get renamed/stripped, Security1.getStep0Request() blows
# up while BUILDING the Sec1 handshake request — which Session.init reports as
# the opaque "Session could not be established", before any GATT write happens.
-keep class espressif.** { *; }
-keep class * extends com.google.protobuf.GeneratedMessageLite { *; }
-keepclassmembers class * extends com.google.protobuf.GeneratedMessageLite {
    <fields>;
}
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.protobuf.**

# Tink provides the X25519 key exchange used by the Sec1 handshake.
-keep class com.google.crypto.tink.** { *; }
-dontwarn com.google.crypto.tink.**

# -----------------------------------------------------------------------------
# Vosk + JNA — Robi wake word (Phase 4)
# -----------------------------------------------------------------------------
# Both reach native code reflectively, so R8 renaming or stripping them fails
# ONLY in release builds and ONLY when the detector starts — the app installs,
# launches and toggles fine, then dies the instant `Model(...)` is constructed:
#
#   java.lang.UnsatisfiedLinkError: Unable to load library 'vosk'
#   java.lang.NoClassDefFoundError: Failed resolution of: Lcom/sun/jna/Library;
#
# JNA builds its bridge from Java class metadata at runtime (it needs the real
# names of the native-method classes and their fields), and org.vosk loads
# libvosk.so through that bridge. Do not narrow these without testing a release
# APK on a device — debug builds do not run R8 and will happily lie to you.
-keep class org.vosk.** { *; }
-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.Structure { *; }
-keepclassmembers class * extends com.sun.jna.Library { *; }
-keepclassmembers class * extends com.sun.jna.PointerType { *; }
-dontwarn com.sun.jna.**
-dontwarn java.awt.**
