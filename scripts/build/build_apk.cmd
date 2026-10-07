@echo off
REM ============================================================
REM  SHE V3 - APK builder (must run OUTSIDE the sandboxed agent shell)
REM
REM  Why: named-pipe creation (CreatePipe/ERROR 231 / EBUSY) is blocked
REM  for processes spawned as descendants of the sandboxed agent shell.
REM  Gradle's :app:compileFlutterBuildDebug task invokes flutter.bat, which
REM  spawns Dart WITH PIPES -> fails. Launching from a normal interactive
REM  shell (double-click, or a user terminal) avoids the sandbox entirely.
REM
REM  Everything it needs is already cached:
REM    NDK 28.2.13676358, platforms 34/35/36, Gradle caches, Zulu JDK 21
REM ============================================================
setlocal

set "PROJ=D:/project X\she-v3\she-v3\mobile"
set "JAVA_HOME=C:/Program Files\Zulu\zulu-21"
set "ANDROID_HOME=C:/Users/hp/AppData/Local/Android/Sdk"
set "ANDROID_SDK_ROOT=%ANDROID_HOME%"
set "FLUTTER_ROOT=C:/tools/flutter"
set "PATH=%JAVA_HOME%\bin;%FLUTTER_ROOT%\bin;%ANDROID_HOME%\platform-tools;%PATH%"

REM Proxies interfere with the Gradle daemon; the deps are all cached anyway.
set "HTTP_PROXY="
set "HTTPS_PROXY="
set "http_proxy="
set "https_proxy="

cd /d "%PROJ%\android"

echo.
echo === SHE V3 APK BUILD ===
echo JAVA_HOME   = %JAVA_HOME%
echo ANDROID_HOME= %ANDROID_HOME%
echo FLUTTER_ROOT= %FLUTTER_ROOT%
echo CWD         = %CD%
echo.

call gradlew.bat :app:assembleDebug --no-daemon
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
  echo === BUILD SUCCEEDED ===
  dir /b /s "%PROJ%\build\app\outputs\flutter-apk\*.apk" 2>nul
) else (
  echo === BUILD FAILED rc=%RC% ===
)
echo.
pause
exit /b %RC%
