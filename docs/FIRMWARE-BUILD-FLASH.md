# SHE V3 Firmware — Build & Flash (ESP32-WROOM-32D)

Target board: **ESP32-WROOM-32D** (classic ESP32, Xtensa LX6 dual core),
CH340 USB-serial bridge, plus a relay module.

---

## 1. Toolchain state

**ESP-IDF v5.1.4 (LTS)** — the version the project targets
(`firmware/v3/README.md` §1, `firmware/v3/CMakeLists.txt`, and the v3 specs
all pin v5.1.x). Framework `C:\Espressif\frameworks\esp-idf-v5.1.4`,
python env `C:\Espressif\python_env\idf5.1_py3.11_env`.

⚠️ `C:\Espressif` also has **v5.2.7** installed. Do not build with it: the
build dir's bootloader sub-cache was generated against 5.1.4 and cmake aborts
with `The source .../esp-idf-v5.2.7/components/bootloader/subproject/CMakeLists.txt
does not match the source .../esp-idf-v5.1.4/... used to generate cache`.
`scripts/run-idf.py` defaults to 5.1.4 for this reason; override only with
`IDF_VERSION=` **and a wiped build dir**.

Build dir: `firmware/v3/build-esp32d-clean` (clean, correctly configured)
Config chain: `sdkconfig.defaults` → `sdkconfig.esp32` → `sdkconfig.dev`
Partition table: `partitions_esp32.csv`

| Setting | Value |
|---|---|
| `CONFIG_IDF_TARGET` | `esp32` |
| Flash mode / freq | `dio` / `40m` |
| `CONFIG_ESPTOOLPY_FLASHSIZE` | **8MB** |
| Console baud | 115200 |
| `CONFIG_LOG_DEFAULT_LEVEL` | 4 (DEBUG) |

### Why `scripts/run-idf.py` exists

`idf.py` is normally launched from the ESP-IDF shell created by `export.bat`,
a `.cmd` script. On this machine `cmd //c <anything>` produces **no output at
all** and exits 0, so every `idf.py` invocation silently did nothing. The
runner sets the environment up and calls `idf.py` with the IDF python
interpreter directly.

Four separate problems had to be solved:

| Symptom | Cause | Fix in `run-idf.py` |
|---|---|---|
| `MSys/Mingw is no longer supported` | idf.py detects MSYS purely from the `MSYSTEM` env var, which Git Bash sets | pop `MSYSTEM`, `MSYSCON`, `MSYS2_ARG_CONV_EXCL` |
| `unknown platform: Windows-` | `platform.machine()` is empty because `PROCESSOR_ARCHITECTURE` is not inherited | `env.setdefault("PROCESSOR_ARCHITECTURE", "AMD64")` |
| `python_env doesn't exist` | tools live in `C:\Espressif`, not `%USERPROFILE%\.espressif` | `IDF_TOOLS_PATH = C:\Espressif` |
| `"cmake" must be available on the PATH` | see below | put **cmake 3.30.2** ahead of 3.24.0 |

### The cmake trap

`C:\Espressif\tools\cmake` contains **two** versions. The one IDF 5.2 nominally
pins (3.24.0) is **broken in this install** — it dies with `0xC0000005`
(access violation) before printing anything:

```
cmake 3.24.0/bin/cmake.exe --version  ->  rc=3221225477, no output
cmake 3.30.2/bin/cmake.exe --version  ->  rc=0, "cmake version 3.30.2"
```

`idf.py` checks the toolchain with `shutil.which("cmake")` and then *runs* it.
It found 3.24.0 first, got a crash, and reported the misleading
`"cmake" must be available on the PATH` — while immediately afterwards
printing `Executing action: all` and exiting 2 with no error text.

Fix: `TOOL_DIRS` lists `cmake\3.30.2\bin` **before** `cmake\3.24.0\bin`
(and `ninja\1.12.1` before `ninja\1.10.2`).

Note that changing the cmake version invalidates `CMakeCache.txt`, so the
next build is a **full** ~1191-target rebuild, not incremental.

---

## 2. Build

```bash
DEFAULTS="sdkconfig.defaults;sdkconfig.esp32;sdkconfig.dev"

python scripts/run-idf.py -B build-esp32d-clean -DSDKCONFIG_DEFAULTS="$DEFAULTS" set-target esp32
python scripts/run-idf.py -B build-esp32d-clean -DSDKCONFIG_DEFAULTS="$DEFAULTS" build
```

`sdkconfig` is **gitignored**, so it is regenerated from that defaults chain
every time — always pass `-DSDKCONFIG_DEFAULTS`, or the build silently
defaults to the ESP32-**S3** R8 profile in `sdkconfig.defaults`
(`CONFIG_IDF_TARGET="esp32s3"`, `CONFIG_SPIRAM=y`).

A full build is ~1191 targets and takes roughly 40 minutes.

Verified result of a correct configure:

```
CONFIG_IDF_TARGET              = "esp32"     CONFIG_IDF_TARGET_ESP32 = 1
CONFIG_ESPTOOLPY_FLASHSIZE     = "8MB"       CONFIG_ESPTOOLPY_FLASHSIZE_8MB = 1
CONFIG_LOG_DEFAULT_LEVEL       = 4 (DEBUG)
CONFIG_SPIRAM                  = (absent -> n)
CONFIG_PARTITION_TABLE_CUSTOM_FILENAME = "partitions_esp32.csv"
CONFIG_SHE_DEVKIT_ESP32        = 1
CONFIG_SHE_RELAY_COUNT         = 4
CONFIG_SHE_FIRMWARE_VERSION    = "3.0.0"
CONFIG_ESP_CONSOLE_UART_BAUDRATE = 115200
```

⚠️ Changing `sdkconfig.defaults` is **not** enough: idf.py only applies the
defaults chain when `sdkconfig` does not already exist. If you edit a
defaults file you must delete `firmware/v3/sdkconfig` (it is gitignored and
fully regenerated) and re-run `reconfigure`, or your change is silently
ignored and you will chase a build error you believe you already fixed.

Successful build produces, in `build-esp32d-clean/`:

| Offset | File | Purpose |
|---|---|---|
| `0x1000` | `bootloader/bootloader.bin` | 2nd-stage bootloader |
| `0x8000` | `partition_table/partition-table.bin` | partition map |
| `0x10000` | `she-firmware.bin` | application |
| `0x5b0000` | `ota_data_initial.bin` | OTA slot selector |

Plus `she-firmware.elf` and `.map` for debugging.

Verified result of a successful build:

```
0x1000   bootloader/bootloader.bin            26,720 B
0x8000   partition_table/partition-table.bin   3,072 B
0x10000  she-firmware.bin                  1,767,696 B
0x5b0000 ota_data_initial.bin                  8,192 B

ELF: magic b'\x7fELF' | 32-bit | machine 0x005e -> Xtensa   (correct for ESP32-WROOM-32D)

she-firmware.bin binary size 0x1af910 bytes.
Smallest app partition is 0x1e0000 bytes. 0x306f0 bytes (10%) free.
```

## 2b. Fixed defect: local control could not compile

`main/local_ctrl.c` calls `httpd_ssl_start()` — the F1 fix that gives local
control real TLS using the same device identity as MQTT mTLS — and includes
`esp_https_server.h` unconditionally. But **no sdkconfig ever enabled the
component**, and in IDF 5.1.x it only exports its include dir when it is set:

```cmake
# components/esp_https_server/CMakeLists.txt
if(CONFIG_ESP_HTTPS_SERVER_ENABLE)
    set(inc "include")
endif()
idf_component_register(... INCLUDE_DIRS ${inc} ...)
```

So the header was invisible even though `esp_https_server` was already listed
in `main/CMakeLists.txt` `REQUIRES`, and the build died near the end:

```
main/local_ctrl.c:12:10: fatal error: esp_https_server.h: No such file or directory
```

Fixed by setting `CONFIG_ESP_HTTPS_SERVER_ENABLE=y` (and `CONFIG_ESP_TLS_SERVER=y`)
in `sdkconfig.defaults`. Its Kconfig dependencies
(`ESP_TLS_USING_MBEDTLS && MBEDTLS_TLS_SERVER`) were already satisfied.

Note the DevKit path in `start_https_server()` still falls back to **plain
HTTP** when no device cert is present in `fctry` NVS
(`#ifdef CONFIG_SHE_DEVKIT_ESP32`), so bring-up works before provisioning.

---

## 3. Flash

```bash
python scripts/flash-esp32.py                     # COM4 @ 460800
python scripts/flash-esp32.py --port COM7 --erase # different port, full erase
python scripts/flash-esp32.py --check             # link test only
python scripts/flash-esp32.py --baud 115200       # marginal cable
python scripts/flash-esp32.py --build-dir D:/she-v3/firmware/v3/build-esp32d-clean
```

The script reads `flasher_args.json` from the build dir for the exact offsets,
verifies every image exists before touching the chip, runs a `chip_id` link
test first, and only then flashes.

It passes `--flash_size detect` by default — see §5.

---

## 4. Flash result — and the auto-reset caveat

**The flash succeeded.** The dead link was a cabling/reseat problem; once the
board answered, esptool identified it and wrote all four images with hash
verification:

```
Chip is ESP32-D0WD (revision v1.1)
Features: WiFi, BT, Dual Core, 240MHz, Crystal 40MHz
MAC: 10:06:1c:ae:53:28
Manufacturer: c8   Device: 4017   Detected flash size: 8MB
Wrote 1767696 bytes (1060225 compressed) at 0x00010000 in 24.4s
  (effective 578.4 kbit/s) — Hash of data verified.
```

The chip is an **ESP32-D0WD** (the silicon inside WROOM-32D) with **8 MB** of
flash — exactly what the build assumed, so no partition-table change is
needed. `partitions_esp32_4mb.csv` is therefore not required.

**The auto-reset circuit works** — it was initially misdiagnosed. The proof is
a two-way test run right after flashing:

```
esptool --before no_reset      chip_id  -> FAILS ("No serial data received")
esptool --before default_reset chip_id  -> SUCCEEDS (Chip is ESP32-D0WD)
```

`no_reset` only connects when the chip is *already* parked in the ROM download
mode. It failed, so the chip was not in download mode — esptool's reset had
put it there and the application then booted from flash. The modem-control
lines do reach EN/IO0.

**The real problem is that the serial link is intermittent.** It works, then
goes completely dead (0 bytes at every baud, sync frames sent with nothing
returned) until the cable is re-seated. That is why no boot log was captured:
the link died right after the flash. Suspect the cable or a loose USB socket.

Once the link is alive, capture the boot with esptool's own known-working
reset sequence:

```bash
"C:/Espressif/python_env/idf5.1_py3.11_env/Scripts/python.exe" \
  scripts/esp32-boot-capture.py COM4 115200 25
```

`scripts/esp32-listen.py` is a passive alternative for when you press EN by
hand. Note that opening a port **without** `dsrdtr=False, rtscts=False` will
assert the control lines and can hold the chip in reset — which looks exactly
like a dead link.

### Earlier symptom, kept for reference

When the link was fully dead, the evidence looked like this:

```
COM port enumeration:  COM4 = USB-SERIAL CH340, VID:PID 1A86:7523, status OK
                       (COM3, COM5 are stale ghost entries — not openable)

pyserial open test:    COM1..COM12 → only COM4 opens

Reset pulse @115200:   0 bytes received (both EN polarities, 115200 and 74880)
Forced download mode:  0 bytes received (both polarities)
Idle read:             0 bytes

esptool chip_id:       "No serial data received" at
                       9600 / 57600 / 115200 / 230400 / 460800

esptool --trace:       writes sync frames (c0 00 08 24 ... 55 55 55 ... c0)
                       and receives absolutely nothing back
```

Since `CONFIG_LOG_DEFAULT_LEVEL` is DEBUG, a chip running our firmware would
be chattering on boot. Total silence means the chip is either not running or
its TX never reaches the PC.

### What to do, in order

1. **Use a USB *data* cable.** This is the single most common cause. Charge-only
   cables enumerate fine (the CH340 is powered) but have no data pair.
2. **Try a different USB port** on the PC, skipping hubs.
3. **Enter download mode by hand** — many clone boards have a non-functional
   auto-reset circuit, so esptool's DTR/RTS toggling never reaches EN:
   hold **BOOT (IO0)**, tap **EN**, release BOOT, then immediately run
   `python scripts/flash-esp32.py --baud 115200 --check`.
4. **Confirm the port is the right one** with the passive listener, which
   prints anything the board emits while you press buttons:
   ```
   python scripts/esp32-listen.py COM4
   ```
   Press EN. You should see the ROM banner at 115200.
5. **Reinstall the CH340 driver** if the port appears but stays permanently
   silent.

`scripts/esp32-probe.py COM4` runs the reset-polarity matrix automatically
(it tries both EN polarities, normal boot and forced download mode).

### Reset polarity reference

The classic CH340 + transistor network on these devkits **inverts**:

| Line | State | Effect |
|---|---|---|
| DTR | `True` | EN asserted → chip held in reset |
| DTR | `False` | EN released |
| RTS | `True` | IO0 asserted → bootloader select |
| RTS | `False` | IO0 released |

Some clones wire it the other way; the probe script tries both.

---

## 5. Flash size: 8MB assumed — verify before flashing

`CONFIG_ESPTOOLPY_FLASHSIZE` is **8MB** and the partition table puts `otadata`
at `0x5B0000` (~5.7 MB). That layout does **not** fit in 4 MB.

This is deliberate: `sdkconfig.esp32` states *"The connected board has 8 MB of
flash"*, and the enlarged slots exist because the dev-profile binary
(~1.8 MB) overflows the 1.5 MB slots in `partitions.csv`. So 8 MB is the
intended configuration — but it has never been confirmed against the actual
chip, because the board has not answered yet.

An ESP32-WROOM-32D ships as `-N4` (4 MB), `-N8` (8 MB) or `-N16` (16 MB), so
a 4 MB part is still possible.

Two counter-forces:

- The app image is **1,779,632 B (~1.70 MiB)**. It does **not** fit the older
  1.5 MiB (`0x180000`) slots, which is exactly why `partitions_esp32.csv`
  uses 1.875 MiB (`0x1E0000`) slots.
- Two 1.875 MiB OTA slots need 8 MB. On a 4 MB part you can have
  factory + **one** OTA slot, e.g.

  ```
  nvs,      data, nvs,  0x9000,   0x6000,
  phy_init, data, phy,  0xF000,   0x1000,
  factory,  app,  factory, 0x10000,  0x1C0000,
  ota_0,    app,  ota_0,   0x1D0000, 0x1C0000,
  otadata,  data, ota,     0x390000, 0x2000,
  fctry,    data, nvs,     0x392000, 0x10000,
  nvs.keys, data, nvs,     0x3A2000, 0x1000,
  ```

  (ends at `0x3A3000` < `0x400000`, ~90 KB headroom per slot — tight).

**Do not guess.** Once the link works, get the real size first:

```bash
python scripts/flash-esp32.py --check     # prints detected size
# or
python -m esptool --chip esp32 --port COM4 flash_id
```

If it reports 4 MB, rebuild against a 4 MB partition table before flashing
(the linker and bootloader offsets must match the part).

---

## 6. Scripts

| Script | Purpose |
|---|---|
| `scripts/run-idf.py` | run `idf.py` (build / menuconfig / monitor) without an ESP-IDF shell |
| `scripts/flash-esp32.py` | preflight + flash with correct offsets, `--flash_size detect` |
| `scripts/esp32-probe.py` | reset-polarity matrix; shows whether the board transmits at all |
| `scripts/esp32-listen.py` | passive listener; use while pressing EN / BOOT by hand |
