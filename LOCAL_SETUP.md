# SHE-V3 — Local Setup (Windows, this machine)

Fresh clone pulled from **https://github.com/Kemal695/SHE-V3** on 2026-11-02 into:

```
D:\project X\SHE-V3
```

(Repo root = `D:\project X\SHE-V3`. All `scripts/...` paths below are relative to it.)

---

## What is already done

- ✅ **Git clone complete** — 753 files, full history. `origin/master` is at `242cd71`.
- ✅ **Mobile `local.properties` created** at `mobile/android/local.properties` with this machine's SDK paths:
  ```
  sdk.dir=C:\Users\hp\AppData\Local\Android\Sdk
  flutter.sdk=C:\ProgramData\flutter
  ```
- ✅ **Backend compiles cleanly** — `python scripts/run-maven.py -DskipTests compile`
  → `BUILD SUCCESS` (31s, classes in `backend/target/classes`).
- ✅ **Firmware toolchain fixed for ESP32-S3 ("SUK")** — the repo's `scripts/idf-build.py` only put
  the **ESP32** toolchain on `PATH`, so S3 builds died with
  `xtensa-esp32s3-elf-g++ not found`. Added the **ESP32-S2 and ESP32-S3** toolchain bins to
  `TOOL_BINS`. CMake now configures fully for ESP32-S3 (verified).

## Toolchain verification

| Tool | Path | Status |
|---|---|---|
| JDK 21 (Zulu) | `C:\Program Files\Zulu\zulu-21` | ✅ works |
| Maven 3.9.16 | `C:\tools\apache-maven-3.9.16` | ✅ works |
| Flutter | `C:\ProgramData\flutter` | ⚠️ CLI cannot run in the agent shell (see below) |
| ESP-IDF v5.1.4 | `C:\Espressif\frameworks\esp-idf-v5.1.4` | ✅ |
| IDF venv python | `C:\Espressif\python_env\idf5.1_py3.11_env\Scripts\python.exe` | ✅ works (use this for firmware) |
| adb | `C:\Users\hp\AppData\Local\Android\sdk\platform-tools\adb.exe` | ✅ works |

---

## ⚠️ Key Windows caveats (learned the hard way on this box)

1. **Flutter / Dart CLI cannot run from the agent shell.** Every Flutter command
   (`flutter pub get`, `flutter build apk`, `dart analyze`) dies with
   `CreateFile failed 231 (All pipe instances are busy)`. This is a host/session
   named-pipe condition. **Run all Flutter commands in your own PowerShell terminal,
   not through the agent.** (Gradle-built APKs do work, because Gradle doesn't go
   through the Dart pipe.)

2. **`python` in the agent shell is broken** (`PYTHONPATH` shim ⇒ `No module named
   'sysconfig'`). Use the **IDF venv python** for any helper script:
   `C:\Espressif\python_env\idf5.1_py3.11_env\Scripts\python.exe`.

3. **A Gradle build-dir junction is required to build the APK** (the Kotlin daemon
   is denied writes inside the Flutter SDK). Run, in your terminal, **after**
   `flutter pub get`:
   ```powershell
   cd D:\project X\SHE-V3\mobile
   python ..\scripts\prepare-flutter-gradle-dir.py
   ```

4. **Dead proxy:** a `http_proxy=127.0.0.1:61770` is injected into the shell and
   fakes backend outages on `localhost`. For local health checks:
   ```bash
   unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
   curl -s -m 3 -o /dev/null -w "%{http_code}\n" http://127.0.0.1:9090/actuator/health
   ```

---

## Bring each component up (run these in YOUR terminal)

### 1. Infra (Postgres + EMQX + …) — Docker
```bash
cd D:\project X\SHE-V3
python scripts/infra.py lite      # 5 services; NOT full compose (8 incl. 3 EMQX VMs)
```
Backend health is on **:9090** (startup ~50–90s). Start infra **before** the backend.

### 2. Backend (Spring Boot)
```bash
cd D:\project X\SHE-V3
python scripts/run-backend.py     # strips SERVER__* vars; reads 39 vars from backend/.env
```
Use `run-backend.py` (NOT `run-backend.sh` — the `.sh` does not strip `SERVER__*` and
binds a host-owned port). Health: `http://127.0.0.1:9090/actuator/health`.

### 3. Mobile (Flutter) — in your PowerShell
```powershell
cd D:\project X\SHE-V3\mobile
flutter pub get
python ..\scripts\prepare-flutter-gradle-dir.py   # APK build needs this
flutter build apk            # or: scripts\build\build_apk.cmd from a clean session
```
`local.properties` is already in place. If you ever move the checkout, re-run
`scripts/diagnostics/fix_plugin_paths.py`.

### 4. Firmware (ESP-IDF) — IDF venv python
```bash
cd D:\project X\SHE-V3\firmware\v3
C:\Espressif\python_env\idf5.1_py3.11_env\Scripts\python.exe ..\..\scripts\idf-build.py build
```
Do **not** bump ESP-IDF past 5.1.x. Use the IDF venv python, not the (broken) system one.

### 5. Admin web
```bash
cd D:\project X\SHE-V3\admin-web
npm install
npm run dev        # see package.json "scripts" for the exact dev/build commands
```

---

---

## Firmware SKU / Provisioning Investigation (2026-11-02)

User's concern: SKU **4 / 16 / 24** is critical for device provisioning; verify the repo
firmware actually supports them end-to-end (not just builds). Verdict: **runtime/source
support is complete and correct for all three; R24 has a build-config gap + a Kconfig doc bug.**

### Provisioning chain (verified correct for R4/R8/R16/R24)
1. SKU string read from `fctry` NVS partition → `main.c` maps `sku → relay_count`:
   R4=4, R8=8, R16=16, **R24=24** (lines 284–291).
2. `device_profiles.c::profile_build_for_sku()` builds the RainMaker node tree for each
   SKU; `profile_build_r24()` = 27 nodes (24 relays + OTA + Diagnostics + Sensors),
   named Light 1-8 / Socket 1-8 / Light 9-16.
3. `relay_driver.c` R24 expander addresses = **0x24 / 0x26 / 0x25** (NON-ascending, by design —
   matches bench-confirmed 0x24). R4/R8/R16 ladder = 0x20/0x21/0x22.
4. `ble_provisioning.c` embeds `"mac"` + `"sku"` in the QR payload, so the backend claims
   the device by **SKU + MAC**. ✅ end-to-end.

### Silicon assignment (per sdkconfig.r4/r8/r16 + relay_driver.c)
| SKU  | Silicon        | Build config present? | I2C pins (code) |
|------|----------------|-----------------------|-----------------|
| R4   | ESP32-C3       | ✅ sdkconfig.r4       | 8/9 (S3/C3 safe)|
| R8   | ESP32-S3       | ✅ sdkconfig.r8       | 8/9             |
| R16  | ESP32-S3       | ✅ sdkconfig.r16      | 8/9             |
| **R24** | **classic ESP32-D0WD** | ❌ **no sdkconfig.r24** | **15/13** (board-routed) |

⚠️ **R24 is classic ESP32, NOT ESP32-S3.** `relay_driver.c` (lines 149–162) states this
explicitly: "This is a classic ESP32-D0WD … R24 is also CONFIG_IDF_TARGET_ESP32."
`sdkconfig.defaults` defaults target to `esp32s3`, so an R24 build MUST set
`CONFIG_IDF_TARGET="esp32"` (use `partitions_esp32.csv`).

### Two concrete R24 issues to fix
1. **Missing `sdkconfig.r24`** → no documented build command exists for R24 (README only
   documents R4/R8/R16 via `-DSDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.rX;..."`).
   To build R24 you must author `sdkconfig.r24` (target esp32, `partitions_esp32.csv`,
   PSRAM decision, `CONFIG_SHE_R24=y`). The repo has `partitions_esp32.csv` but nothing
   selects it for R24.
2. **Kconfig.projbuild doc bug** — line 19 help text says
   `SHE-R24: ESP32-S3, 24 relays via 3x PCF8574 (0x20/0x21/0x22)` and line 29 label says
   `ESP32-S3`. BOTH WRONG: it's classic ESP32 with addresses **0x24/0x26/0x25**. If a
   developer trusts the help text and builds R24 for `esp32s3`, the binary won't run on the
   actual classic-ESP32 board (wrong silicon; relay_driver.c R24 branch still sets 15/13 but
   the register/flash layout is for S3 → boot failure).

### Note on "SUK = ESP32-S3"
Repo supports ESP32-S3 for **R8 and R16**. Among the 4/16/24 family the user named:
R4=C3, R16=**S3 ✅**, R24=classic ESP32. If the user's real R24 hardware is S3, that is a
mismatch with the repo and needs a decision (build R24 as S3 vs. classic ESP32).

---

## Safety net — your old checkout is preserved

Your previous checkout still exists at:
```
D:\project X\she-v3\she-v3\she-v3\
```
It held **89 local commits (unpushed) + 15 uncommitted files** (incl. the
"Robi voice assistant" work). This fresh clone does **not** contain those 89 commits
(they were never pushed to GitHub). The old folder was left **untouched**.

If you want those 89 commits back, tell me and I'll cherry-pick / merge them into this
fresh clone (or recover specific files). Otherwise it's safe to delete once you've
confirmed you don't need it.

## Other clutter (not touched)
- `D:\she-v3.zip` (1.2 GB GitHub "Download ZIP" snapshot) — not used; the clone is preferred.
- `D:\she-v3` (old, Sep 26) — superseded.
