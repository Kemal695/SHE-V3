# SHE-R24 — all 24 relays working (verified 2026-09-28)

Step-by-step record of how the R24 board was brought from "boot loop / no relays
found" to **all 24 relays live**, for anyone who has to repeat it.

---

## 1. Find the real pins — do NOT guess

`she-v3-r24-source/v3/BUILD-R24.md` §1 is the board's own hardware map:

| Block | Bus | Pins | Addresses |
|---|---|---|---|
| 3 × PCF8574 **output** (relays) | bus 0 | **SDA=15 / SCL=13** | `0x24`, `0x26`, `0x25` |
| 4 × PCF8574 **input** (DCIN/ACIN) | bus 1 | SDA=4 / SCL=5 | `0x20`–`0x23` |

They were **never** on 21/22 (the Arduino default) and **never** on 8/9 (the spec's
value). Every earlier scan failed because it probed the wrong pins.

⚠️ A blind pin sweep is a weak tool: the sweep only proves something about the
pairs you actually tried. Get the pins from the build guide or meter continuity.

---

## 2. The three flash-pin bugs (same class, three instances)

The bench board is a **classic ESP32-D0WD**. On it, **GPIO 6–11 belong to the SPI
flash** — touching them hard-resets the chip with no panic, in an endless
`TG1WDT_SYS_RESET` loop.

| # | File | Bad pins | Safe fix |
|---|---|---|---|
| 1 | `relay_driver.c` | I²C SDA/SCL = 8/9 | R24 → **15/13** |
| 2 | `feedback_monitor.c` | CD4051 mux select = 10/11/12 | classic ESP32 → 4/5/18 |
| 3 | `button_task.c` | user button on GPIO0 (BOOT strap) | `SHE_BUTTON_TASK_DISABLED` for R24 |

Each now carries a compile-time `#error` guard so it cannot regress silently.

**Branch order in `relay_driver.c` matters** — R24 is *also* `CONFIG_IDF_TARGET_ESP32`,
so the `#if defined(CONFIG_SHE_R24)` → 15/13 branch must come **first** or R24
silently inherits 21/22:

```c
#if defined(CONFIG_SHE_R24)            → 15 / 13
#elif defined(CONFIG_IDF_TARGET_ESP32) → 21 / 22
#elif CONFIG_SHE_R16||R8||R4           → 8 / 9
#elif CONFIG_SHE_DEVKIT_ESP32          → 21 / 22
#else #error
#endif
```

---

## 3. On R24, skip the CD4051 mux entirely

Per ADR-017 the R24 board does **not** use the CD4051 for contact feedback — that
comes from the bus-1 PCF8574 input expanders, and ADC1 belongs to the sensor set.
GPIO 4/5 are the input bus, so driving them as mux-select outputs fights the
expanders.

Both call sites are gated with `#if defined(CONFIG_SHE_R24)`:
- `feedback_monitor_init()` at Step 3b
- `feedback_monitor_start()` later (guarding only `init()` is not enough — the
  task is started separately)

---

## 4. Build

```bash
cd "D:/project X/she-v3/she-v3/firmware/v3"
C:/Espressif/python_env/idf5.1_py3.11_env/Scripts/python.exe ../../scripts/idf-build.py build
```

⚠️ `idf-build.py` **must** run under the IDF venv python (otherwise
`Cannot import module "click"`), and it needs the `build` argument.

Config confirmed: `CONFIG_SHE_R24=y`, `CONFIG_SHE_RELAY_COUNT=24`,
`CONFIG_IDF_TARGET="esp32"`, 8 MB / `partitions_esp32.csv`.
Result: `she-firmware.bin` 1,593,328 B, 19 % free.

---

## 5. Flash

```bash
python scripts/flash-esp32.py --port COM3 --wait 150
```

The script now has baud fallback (460800 → 115200 → **74880**), `--attempts 10`,
and `--wait` polling. The 74880 fallback is what syncs when 115200 will not.

---

## 6. Getting the board into download mode (manual)

The CH340's auto-reset is unreliable here and **BOOT is on GPIO0**, so:

> **hold BOOT → tap EN/RST once → release BOOT**

The board goes silent — that is correct, the ROM prints nothing until contacted.

If it is wedged: **unplug USB, wait ~5 s, replug**, then the sequence above.

---

## 7. ⭐ To actually RUN the firmware: reset WITHOUT BOOT

This is the step that looks like a failure but isn't. Read the reset banner:

```
rst:0x1 (POWERON_RESET),boot:0x7 (DOWNLOAD_BOOT)     ← IO0 LOW: stuck in ROM
```

- `boot:0x7` = download mode. The app is **not running**; no log will ever appear.
- `boot:0x17 (SPI_FAST_FLASH_BOOT)` = healthy normal boot.

**Any reset while BOOT/IO0 is held low lands in download mode.** To run the app:
power-cycle (or tap EN) **without touching BOOT**.

---

## 8. Result

After a plain EN reset: **all 24 relays respond** — 3/3 output expanders found on
`SDA=15 / SCL=13` at `0x24` / `0x26` / `0x25`.

Channel map: `0-7` Light 1-8 · `8-15` Socket 1-8 · `16-23` Light 9-16.

---

## Notes for next time

- **Never hand-poke DTR/RTS from pyserial** — that strands the chip. Use the
  button sequence or a power cycle.
- **Read `boot:0x..` first.** It separates "flashing broken" from "needs a plain
  reset" in one line.
- **Passive read is the reliable log capture** (open COM3 at 115200 and read) —
  don't use esptool for it; on this board its connect succeeds ~1 in 20.
- If you do connect via esptool, force `port.baudrate = 115200` before reading —
  connecting at 460800 leaves the port there and the console is 115200.
- **MQTT is TLS on 8883** (emqx-1 8883, emqx-2 8884, emqx-3 8885). Plain 1883
  is not exposed.
- **OTA is the way out of the USB pain**: `she/{mac}/ota/url` trigger,
  `ota/status` + `ota/progress` feedback, `esp_https_ota`, anti-rollback and a
  5-minute health check with auto-rollback.
