# SHE V3 Firmware — Build & Flash (ESP32-WROOM-32D)

Target board: **ESP32-WROOM-32D** (classic ESP32, Xtensa LX6 dual core),
CH340 USB-serial bridge, plus a relay module.

---

## 1. Toolchain state

ESP-IDF **v5.2.7** at `C:\Espressif`, framework `esp-idf-v5.2.7`,
python env `C:\Espressif\python_env\idf5.2_py3.11_env`.

Total build dir: `firmware/v3/build-esp32d`
Config: `sdkconfig` (+ `sdkconfig.defaults`, `sdkconfig.esp32`)
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
python scripts/run-idf.py -B build-esp32d build
```

Successful build produces, in `build-esp32d/`:

| Offset | File | Purpose |
|---|---|---|
| `0x1000` | `bootloader/bootloader.bin` | 2nd-stage bootloader |
| `0x8000` | `partition_table/partition-table.bin` | partition map |
| `0x10000` | `she-firmware.bin` | application |
| `0x5b0000` | `ota_data_initial.bin` | OTA slot selector |

Plus `she-firmware.elf` and `.map` for debugging.

Sanity check on the app image:

```
ELF magic: b'\x7fELF'
class: 32-bit | endian: LE
machine: 0x005e -> Xtensa      # correct for ESP32-WROOM-32D
```

---

## 3. Flash

```bash
python scripts/flash-esp32.py                     # COM4 @ 460800
python scripts/flash-esp32.py --port COM7 --erase # different port, full erase
python scripts/flash-esp32.py --check             # link test only
python scripts/flash-esp32.py --baud 115200       # marginal cable
```

The script reads `build-esp32d/flasher_args.json` for the exact offsets,
verifies every image exists before touching the chip, runs a `chip_id` link
test first, and only then flashes.

It passes `--flash_size detect` by default — see §5.

---

## 4. ⚠ Open hardware blocker — the board does not respond

As of this writing the firmware **builds cleanly** but **cannot be flashed**:
the serial link is dead. Evidence:

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

## 5. ⚠ Flash size: 8MB build vs possibly 4MB part

`CONFIG_ESPTOOLPY_FLASHSIZE` is **8MB** and the partition table puts `otadata`
at `0x5B0000` (~5.7 MB). That does not fit in 4 MB.

An ESP32-WROOM-32D ships as `-N4` (4 MB), `-N8` (8 MB) or `-N16` (16 MB);
the most common devkit module is **4 MB**.

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
