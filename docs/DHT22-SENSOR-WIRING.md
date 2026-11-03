# DHT22 (AM2302) temperature/humidity sensor — wiring & flashing

**Status (2026-11-03):** firmware now decodes DHT22 *and* DHT11 (auto-detect).
The sensor is **not yet wired** — that is the remaining blocker.

---

## 1. What was actually wrong

Two separate faults, both of which produced `T=0.0C H=0.0%`:

| # | Fault | Symptom | Fix |
|---|---|---|---|
| 1 | **Nothing wired to GPIO 27.** The R24 PCB has no DHT fitted and no sensor header populated. | DHT handshake times out → `dht_valid` stays false → params stay at their `0.0` default. | Physically connect the sensor (below). |
| 2 | **The firmware only spoke DHT11.** Both this repo and the reference repo decoded with the DHT11 formula (`data[0] + data[1]/10`), which is *wrong* for a DHT22 — a DHT22 sends 16-bit values in 1/10 units. | Even once wired, a DHT22 would decode as garbage or be rejected as out-of-range. | Model-aware decode + runtime auto-detect (below). |

Fault 2 is why simply plugging the sensor in would **not** have fixed it. Both were needed.

> The `0.0` you saw was never a *reading* of zero — it was the initialised default
> of a param that was never updated, because no checksum-valid frame ever arrived.

---

## 2. Wiring

The board drives the DHT data line on **GPIO 27**, as open-drain with a pull-up
(`GPIO_MODE_INPUT_OUTPUT_OD`, `GPIO_PULLUP_ENABLE`).

### Your module

The photo shows a **DHT22 (AM2302)** on a teal 4-pin module plugged into a black
3-pin carrier. Silkscreen on the carrier: `out` and `+`. That carrier exposes:

```
  ┌──────────────┐
  │  out ────────┼────►  DHT DATA  ──►  ESP32 GPIO 27
  │  +  ─────────┼────►  VCC       ──►  ESP32 3V3
  │  -  ─────────┼────►  GND       ──►  ESP32 GND
  └──────────────┘
```

### The connections

| DHT pin | To | Note |
|---|---|---|
| **`out`** (data) | **GPIO 27** | The one pin the firmware actually reads. |
| **`+`** (VCC) | **3V3** | 3.3 V is correct — the ESP32's GPIO is 3.3 V logic. Do **not** feed 5 V into `out`. |
| **`-`** (GND) | **GND** | ⚠ **This wire was missing in the photo.** Without a ground the sensor can never answer. |

### Pull-up resistor (required)

A DHT22 needs a **4.7 kΩ – 10 kΩ** pull-up from `out` to `+`.

* Check first: many 3-pin carriers already have one fitted on the underside. If
  your carrier has it, **do not add a second**.
* The ESP32's *internal* pull-up (~45 kΩ) is **too weak** for a DHT22 — the
  timing margins are only ~26 µs vs ~70 µs, so a weak pull-up causes checksum
  failures and intermittent reads. This is a very common reason a DHT "works on
  a bench" but returns garbage in the enclosure.
* If the carrier has no pull-up, solder a **10 kΩ** resistor between `out` and `+`.

### Power supply

A DHT22 needs **3.3 V – 5 V**. Use **3.3 V** to match the ESP32's logic level.
If your carrier has an onboard AMS1117 regulator (it will look like a small
3-pin chip + a capacitor), then it expects 5 V on `+` — in that case power it
from 5 V, but **check that `out` is pulled up to 3.3 V and not 5 V** (measure
it), because 5 V on a DHT data line would damage the ESP32 GPIO. The plain
3-pin carrier in your photo has no regulator, so 3.3 V is the safe choice.

### Decoupling

Add a **100 nF** ceramic capacitor between `+` and `-`, close to the sensor.
The DHT22's heater draws short current pulses when it converts, and without
this the rail dips and the frame gets corrupted.

---

## 3. Verify it before flashing

Once wired, the serial log is the test. A working DHT22 prints a real value
**within one 30 s cycle**:

```
I (668218) she_sensors: T=24.6C H=41.2%  soil=0% (raw 4095)  CO2=0ppm ...  [DHT22 detected]
```

Failure modes to look for:

| Log line | Meaning |
|---|---|
| `T=0.0C H=0.0%` and no `[DHT22 detected]` | No frame at all → wiring or pull-up problem. |
| `DHT checksum mismatch (got 0x.., computed 0x..)` | Frames arrive but are corrupted → **pull-up too weak / missing**, or wiring too long. |
| `Frame decoded as DHT11 but DHT22 is configured` | Auto-detect rescued it — the reading is still valid. |
| `DHT out of range (T=.. H=..) — discarding` | Decoded value is nonsense → still a signal-integrity problem. |

Also note the **soil probe** will keep reporting `raw 4095` and the **MQ-135**
`R0 -1.00k` until those are fitted — they are separate sensors on GPIO 33 and
ADC1_CH4/GPIO 32, and they do not affect temperature.

---

## 4. Flash the new firmware

The DHT22-capable firmware is already built:
`firmware/v3/build/she-firmware.bin`.

Only four regions are written — **`nvs` (0x9000) and `fctry` (0x5C0000) are NOT
touched**, so your Wi-Fi provisioning and MQTT credentials survive:

| Offset | File |
|---|---|
| `0x1000` | `bootloader/bootloader.bin` |
| `0x8000` | `partition-table/partition-table.bin` |
| `0x10000` | `she-firmware.bin` ← the app |
| `0x5b0000` | `ota_data_initial.bin` |

### Steps

This board has **no working auto-reset circuit**, so it must be put into
download mode by hand:

1. **Wire the sensor first** (section 2). Flashing with the sensor
   disconnected will still show `T=0.0C` — that proves nothing about the fix.
2. Hold **BOOT**, tap **EN**, release **BOOT**. The board goes silent — that is
   correct, the ROM prints nothing until contacted.
3. Flash (from `D:\project X\SHE-V3`):

   ```bash
   C:/Espressif/python_env/idf5.1_py3.11_env/Scripts/python.exe scripts/flash-esp32.py --port COM3 --wait 180
   ```

   `--wait 180` polls for up to 3 minutes so you can do the button dance
   *after* starting the command.

4. To actually **run** the firmware, tap **EN** once **without** touching BOOT.
   Any reset while BOOT is held lands in download mode (`boot:0x7`) and the app
   will never start. A healthy boot shows `boot:0x17 (SPI_FAST_FLASH_BOOT)`.
5. Watch the log:

   ```bash
   C:/Espressif/python_env/idf5.1_py3.11_env/Scripts/python.exe scripts/_serial_now.py
   ```

---

## 5. What happens next

* The sensor task samples every **30 s** and publishes on change only
  (>0.5 °C / >1 % moves), so a steady room temperature does not spam the cloud.
* `Temperature` and `Humidity` land on the **Sensors** device
  (`esp.device.sensor`) and flow to `node_params` + the `device_telemetry`
  hypertable.
* The app's **Climate card** on the dashboard renders them, and shows `—`
  until the first valid reading arrives.
* The Sensors device is filtered out of the relay grid
  (`devices_screen.dart:156`), so it does not appear as a 25th switch.

---

## 6. Reference

| Item | Value |
|---|---|
| DHT data pin | **GPIO 27** (open-drain + pull-up) |
| Pull-up | 4.7 kΩ – 10 kΩ, `out` → `+` |
| Decoupling | 100 nF, `+` → `-` |
| Supply | 3.3 V |
| Supported parts | DHT22 / AM2302 (default), DHT11 — auto-detected per frame |
| Decode | DHT22: 16-bit 1/10 units, sign in bit15. DHT11: 8-bit integer. |
| Range check | DHT22 −40…80 °C / 0…100 %; DHT11 0…60 °C / 0…100 % |
| Sampling period | 30 s (`SHE_SENSOR_PERIOD_MS`) |
| Files | `firmware/v3/main/sensors.c`, `firmware/v3/main/sensors.h` |
