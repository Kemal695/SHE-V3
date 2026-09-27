# Porting `app_main.c` (ESP RainMaker) into SHE V3

Analysis of the working RainMaker firmware, and how its hardware maps onto SHE V3.

Source: `D:\app_main.c` — the user's real device, verified working on ESP RainMaker.

---

## 1. What the hardware actually is

A **24-output / 4-input smart distribution board**, driven over **two I2C buses** with
**PCF8574** 8-bit expanders. Not a simple relay board — that is the key fact.

| Expander | I2C bus | Role | Pins map to |
|---|---|---|---|
| `pcf8574_OUT_1` | bus 0 | Outputs | Light 1–8 |
| `pcf8574_OUT_2` | bus 0 | Outputs | Socket 1–8 |
| `pcf8574_OUT_3` | bus 0 | Outputs | Light 9–16 |
| `pcf8574_DCInput_1/2` | bus 1 | DC feedback | (read only) |
| `pcf8574_ACInput_1/2` | bus 1 | AC load feedback | (read only) |

So: **16 lights + 8 sockets = 24 relays**, plus 4 × 8 = 32 feedback input lines.
Two I2C buses exist because outputs and inputs are physically separated.

### Logical devices exposed to the cloud

- `Light 1` … `Light 16`
- `Socket 1` … `Socket 8`
- `Light Master`, `Socket Master`, `Master Switch`, `ALL OFF`
- (plus template leftovers: `Light`, `Fan`, `Temperature Sensor`, `Light Sensor` — demo cruft)

Each device carries bilingual attributes, e.g. `"Room/ክፍል" = "Living Room/ሳሎን"` and
`"Lighting Number/የመብራት ቁጥር" = "01"`. That is a real product decision worth preserving —
room names are how a user finds a light.

### Control flow

```
RainMaker cloud
   └─ write_cb(device, param, val)          name-based dispatch
        ├─ strstr(device_name, "Light")  → handle_light_commands()
        ├─ strstr(device_name, "Socket") → handle_socket_commands()
        └─ "Master Switch"               → all three expanders at once
             └─ pcf8574_toggle_pin() / pcf8574_toggle_all_pins()
                  └─ i2c_master_write_to_device(I2C_NUM_0, addr, ...)
```

`feedback_task` polls the AC input expanders every 20 s to observe **actual** load state,
separate from what the cloud was told.

---

## 2. Findings — things to fix, not copy

I would not port these verbatim. Three are outright defects.

### 🔴 2.1 `pcf8574_toggle_pin()` toggles instead of setting

```c
void pcf8574_toggle_pin(PCF8574_t *pcf, uint8_t pin, uint8_t value) {
    pcf->dataOut ^= (1 << pin);      // ignores `value` entirely
    pcf8574_write8(pcf, pcf->dataOut);
}
```

`handle_light_commands(name, state)` receives the requested state and then **ignores it**.
Sending `Power: true` to a light that is already on turns it **off**.

The cloud UI hides this because `write_cb` ends with
`esp_rmaker_param_update_and_report(param, val)` — it reports back the *requested* value,
not the actual pin. So the app shows "on" while the relay is off. That is a silent
state-divergence bug, and it is the single most important thing to fix in the port.

Note `handle_light_commands` uses **toggle** for individual lights, but
`Light Master` uses `toggle_all_pins(..., state ? 0 : 1)` which **sets**. So master and
individual behave differently — another symptom of the same inconsistency.

**Port fix:** implement `pcf8574_write_pin(pcf, pin, on)` as a *set*, and derive every
command from the desired state. Never toggle.

### 🔴 2.2 Outputs are active-LOW, and the polarity is implicit

```c
pcf8574_toggle_all_pins(&pcf8574_OUT_1, state ? 0 : 1);   // on → 0x00
pcf8574_write8(&pcf8574_OUT_1, DEFAULT_POWER ? 0xFF : 0x00);
```

Low = relay energised. This is correct for a typical active-low relay board, but the
inversion is scattered across call sites rather than stated once. In SHE V3 this belongs in
**one** place — the driver — so `relay_set(ch, true)` means "on" regardless of hardware
polarity.

### 🔴 2.3 `pcf8574_read8`/`write8` ignore the passed bus

```c
uint8_t pcf8574_read8 (PCF8574_t *pcf) { ... i2c_master_read_from_device (I2C_NUM_1, ...); }
void    pcf8574_write8(PCF8574_t *pcf) { ... i2c_master_write_to_device(I2C_NUM_0, ...); }
```

Both take a `PCF8574_t *` but hardcode the bus. It happens to work because this board keeps
all outputs on bus 0 and all inputs on bus 1 — but it means the driver cannot express the
topology it is given. If a second output expander ever moves to bus 1, this breaks silently.

**Port fix:** carry the bus in the handle (`pcf->i2c_port`) and use it.

### 🟡 2.4 No read-back of output state

A PCF8574's output register *can* be read, but on a relay board the read value reflects the
pin driver, not the relay contact. The firmware compensates with the separate AC-input
`feedback_task` — which is the right instinct, and worth keeping.

### 🟡 2.5 `pcf8574_init()` ignores its `dataIn`/`dataOut` arguments

```c
bool pcf8574_init(PCF8574_t *pcf, uint8_t dataIn, uint8_t dataOut, uint8_t deviceAddress) {
    pcf->dataIn = 0;        // parameters discarded
    pcf->dataOut = 0xFF;
```

Callers pass `0, 0xFF, ADD` — so the values match by luck. Dead parameters invite future
misuse.

### 🟡 2.6 `write_cb` has an unreachable `return`

```c
    } else if (strcmp(param_name, ESP_RMAKER_DEF_SPEED_NAME) == 0) {
        ESP_LOGI(...);
    return ESP_OK;                    // returns from the wrong branch
    } else {
        /* Silently ignoring invalid params */
    }
    esp_rmaker_param_update_and_report(param, val);
    return ESP_OK;
```

A `SPEED` write returns early and never reports the param. Minor, but it is the kind of
thing that makes a device look unresponsive.

### 🟡 2.7 `enable_time_sync = false`

```c
esp_rmaker_config_t rainmaker_cfg = { .enable_time_sync = false };
```

Time sync is off while the timezone service is on. For a device whose whole point is
*scheduling*, that is worth re-examining — RainMaker's schedule service needs a trustworthy
clock. In SHE V3 we already handle this explicitly (SNTP + EAT-3), which is the better
arrangement.

### 🟢 2.8 What is genuinely good and should be preserved

- **Name-based dispatch** — the cloud talks in human names (`"Light 3"`), and one lookup
  function maps name → pin. Simple and debuggable. Our port should keep names as the
  contract.
- **Separate AC feedback path** — observing real load state instead of trusting the command
  is exactly right, and is what makes the toggle bug *detectable*.
- **Bilingual room attributes** — a real usability decision.
- **Master devices** — grouping is how a human thinks ("all lights off").
- **`ALL OFF` as its own device** — safety control, deliberately separate from Master.

---

## 3. Mapping onto SHE V3

### What we already have (good news)

`relay_driver.h` already exposes a hardware-agnostic contract:

```c
esp_err_t relay_driver_init(uint8_t relay_count);
bool      relay_driver_is_direct_gpio(void);     // ← anticipates a non-GPIO backend
esp_err_t relay_set(uint8_t channel, bool on);
bool      relay_get(uint8_t channel);
esp_err_t relay_set_all(uint16_t bitmask);
uint16_t  relay_get_all(void);
esp_err_t relay_restore_state(void);
esp_err_t relay_save_state(void);
```

And `relay_driver.c` (V3-FIRMWARE §8 / V3-HARDWARE §4) **already drives PCF8574**:

```c
#define PCF8574_ADDR_CHIP0    0x20     /* channels 0-7  */
#define PCF8574_ADDR_CHIP1    0x21     /* channels 8-15 */

/* PCF8574 is active-low: bit = 0 → relay ON */
uint8_t bit = 1 << (channel % 8);
if (on) g_chip0_state &= ~bit; else g_chip0_state |= bit;
```

It already uses **set semantics** (not toggle), already handles **active-low inside the driver**,
and already keeps a **shadow** so `relay_get()` doesn't read a disabled GPIO input path. Two of the
three "fixes" this port originally proposed were therefore unnecessary — the code was already right.

### What is genuinely missing for the 24-relay board

| Gap | Detail |
|---|---|
| **Third chip** | `0x22` → channels 16-23. We have CHIP0/CHIP1 only |
| **Wider mask** | `relay_set_all(uint16_t)` caps at 16 channels. 24 needs `uint32_t` |
| **Naming + masters** | 16 lights / 8 sockets, `Light Master` / `Socket Master` / `ALL OFF` |
| **Input expanders** | ⚠️ **NOT covered** — see below |

`uint16_t → uint32_t` is a **public API change** on spec'd code, so per `docs/LOCK-MANIFEST.md`
it warrants a new ADR rather than a quiet edit.

### ⚠️ The input side is a separate gap

`feedback_monitor.c` (V3-FIRMWARE §8) reads feedback with a **CD4051 8:1 analog multiplexer + ADC**,
polled every 100 ms — one channel at a time, mux select pins on GPIO 10/11/12 (S3) or 4/5/6 (R4).

The RainMaker board instead uses **4 × PCF8574 digital input expanders** (2 × DCIN, 2 × ACIN =
32 sense lines) over I2C.

These are different sensing principles — analog multiplexed sampling versus digital I2C input
registers — and neither substitutes for the other. Supporting this board needs an **I2C
input-expander feedback source**, either as a new module alongside `feedback_monitor.c` or as a
backend inside it if the public API can stay `init(relay_count)` + `start()`.

Unverified: whether the board *also* carries the mux+ADC path, or whether the input expanders
replace it entirely.


### Where the code actually went

The plan changed once I read `relay_driver.c` properly. It already drove PCF8574 with set
semantics and polarity in the driver, so a **new chip driver was not needed** — the work was
extending the existing one. Files touched:

```
firmware/v3/main/
  relay_driver.c      EDIT — chip table (3 entries), 32-bit mask, group intents
  relay_driver.h      EDIT — widened signatures + RELAY_GROUP_* masks
  device_profiles.c   EDIT — profile_build_r24() (16 lights + 8 sockets)
  device_profiles.h   EDIT — declaration
  button_task.c       EDIT — 0xFFFF -> 0x00FFFFFFu
  main.c              EDIT — mask log width
  (no new files — the device model already had names/channels/attributes)
```

A `pcf8574.c` / `pcf8574_board.c` were written first and **deleted** once it became clear they
duplicated `relay_driver.c` and `device_profiles.h`. See the memory log for 2026-09-20.

### Channel mapping (24 relays)

| Channel | Expander | Pin | Name |
|---|---|---|---|
| 0–7 | OUT_1 | 0–7 | Light 1–8 |
| 8–15 | OUT_2 | 0–7 | Socket 1–8 |
| 16–23 | OUT_3 | 0–7 | Light 9–16 |

Masters are **not** channels — they are intents over a group, served by
`relay_apply_group()` with these masks:

| Master | Mask | Note |
|---|---|---|
| Lights | `0x00FF00FF` | **not contiguous** — sockets sit between the light banks |
| Sockets | `0x0000FF00` | |
| All | `0x00FFFFFF` | |

`relay_apply_group()` is read-modify-write precisely so "all lights off" cannot turn the
sockets off. Using `relay_set_all()` for a master would do exactly that.

### Behaviour changes vs. the original

| Original | SHE V3 port |
|---|---|
| toggle (ignores state) | **set** — idempotent |
| polarity at call sites | polarity in the driver |
| bus hardcoded | bus in the handle |
| reports requested value | reports **actual** state |
| Amharic attrs only | keep them, plus expose via profile |

---

## 4. Status

### Done and building (exit 0)

- Chip table replaces the hardcoded two-chip pair; a chip is a table entry, not a branch.
- Third expander added for channels 16–23; mask widened `uint16_t` → `uint32_t`.
- Per-chip probing, so one dead expander does not take the board down and the log names it.
- `relay_set_all()` writes every present chip unconditionally — a partial write is how
  "all off" leaves one bank energised.
- `relay_apply_group()` for master intents.
- **Latent bug fixed:** `relay_restore_state()`/`relay_save_state()` used `nvs_get_u16` /
  `nvs_set_u16`. With 24 channels the upper bank was silently truncated, so relays 17–24 would
  have come back in the wrong state after every reboot — and it would have looked like a
  hardware fault. Now `u32`.
- `profile_build_r24()`: 26 devices, sku `SHE-R24`.
- `ADR-015` written (status **Proposed**).
- **SKU → relay count mapping fixed for R24.** `main.c` listed R4/R8/R16 but not R24, so an R24
  board fell through to the `8` default and the driver refused every channel ≥ 8
  (`ESP_ERR_INVALID_ARG`). The profile existed; the channels were not enabled. This one line
  gated the entire board.
- **`group_set` command path** (`{"cmd":"group_set","group":"lights"|"sockets"|"all","on":bool}`)
  wired through firmware → backend allowlist → mobile. `relay_apply_group()` and the
  `RELAY_GROUP_*` masks were previously unreachable — nothing called them, so Light Master /
  Socket Master / ALL OFF could not be driven from the cloud. Backend unit test:
  `GroupSetCommandTest`, 7 run / 0 failures.

### Blocked — needs values only the hardware owner has

1. **The I2C addresses.** `0x20`/`0x21` came from the existing `relay_driver.c`, so they are
   probably right. **`0x22` for the third expander is a guess.** A wrong address writes to
   whatever chip *is* at that address — on a relay board, the wrong circuit.
2. **The I2C pins.** `I2C_MASTER_SDA/SCL_IO_0` (outputs) and `_1` (inputs).

Neither is in the shared `app_main.c`; they live in the project's `pcf8574.h` and
`analoginputs.h`.

### Not started

- **Input expander feedback.** `feedback_monitor.c` uses a CD4051 mux + ADC (analog,
  one channel at a time); this board uses digital I2C input registers. Different principles —
  an I2C input path has to be added, not adapted. Unverified whether the board also carries
  the mux path.
- **Room labels.** The bilingual attributes (`"Room/ክፍል" = "Living Room/ሳሎን"`) belong in the
  `attributes` field of `node_device_t`, which already supports them. Not yet populated for R24.

### Then

1. Bench-test all 24 channels — set each one, confirm the right relay clicks. With three
   expanders this is where a mapping mistake shows up, and it is cheap to check first.
2. Populate the room labels.
3. Add the I2C input feedback path.

