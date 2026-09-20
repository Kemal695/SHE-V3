# ADR-015: 32-bit Relay Mask and a Reusable I2C Expander Layer

**Status:** Proposed
**Date:** 2026-Q3
**Decision maker:** Lead Engineer

## Context

`relay_driver.c` (specified in V3-FIRMWARE §8 / V3-HARDWARE §4) currently drives **two** PCF8574
I2C expanders:

```c
#define PCF8574_ADDR_CHIP0    0x20     /* channels 0-7  */
#define PCF8574_ADDR_CHIP1    0x21     /* channels 8-15 */
```

and exposes a 16-bit mask:

```c
esp_err_t relay_set_all(uint16_t bitmask);
uint16_t  relay_get_all(void);
```

A real customer board has arrived that needs **24 relay outputs** — 3 × PCF8574 (16 lights +
8 sockets) — plus **4 × PCF8574 as digital feedback inputs**, spread across **two I2C buses**
(outputs on one, inputs on the other). The reference firmware for it runs on ESP RainMaker.

Three problems:

1. **`uint16_t` cannot express 24 channels.** The mask type must widen. This is a **public
   signature change** — other code calls `relay_set_all()`.
2. **A third output chip does not fit the current shape.** The driver hardcodes a
   `g_chip0_state` / `g_chip1_state` pair with an `if (channel < 8) … else …` branch. Adding a
   third chip by the same method means a third variable and a third branch. This board has
   **7 expanders in total** (3 out + 4 in); the copy-paste approach does not scale to it.
3. **The input side has no path at all.** `feedback_monitor.c` reads feedback with a
   **CD4051 8:1 analog mux + ADC** (V3-FIRMWARE §8), polled every 100 ms, one channel at a time.
   This board instead uses **digital I2C input registers**. Analog multiplexed sampling and
   digital I2C input are different sensing principles; neither substitutes for the other.

`docs/LOCK-MANIFEST.md` requires that a change to a spec'd interface be recorded as a new ADR
rather than edited in place. This is that record.

## Decision

Widen the relay mask to 32 bits, and restructure the expander handling into a reusable layer.

### 1. Widen the public mask to `uint32_t`

```c
esp_err_t relay_set_all(uint32_t bitmask);
uint32_t  relay_get_all(void);
```

32 bits covers the current 24 channels with headroom. `relay_set()` / `relay_get()` keep their
`uint8_t channel` signatures — only the aggregate mask widens, which limits the blast radius to
callers that use the whole-board mask.

### 2. Extract a reusable chip layer (one handler, N chips)

Rather than a third copy of the same logic, one unit of code owns **one** PCF8574 — its address,
its bus, its shadow register, its polarity — and `relay_driver.c` instantiates it per chip:

```
relay_set(channel, on)
   └─ chip = channel / 8          (which expander)
      pin  = channel % 8          (which pin on it)
         └─ chip_set_pin(chip, pin, on)   ← the ONLY place polarity is applied
```

Consequences:
- A fourth output chip is one more entry in a table, not another branch.
- The **input** expanders reuse the same handler for reads.
- The bus lives in the chip handle, so a two-bus board is configuration rather than special
  cases. (The reference firmware hardcoded `I2C_NUM_1` for reads and `I2C_NUM_0` for writes
  regardless of which device was passed in, which only worked because that board happened to
  split outputs and inputs across two buses.)

### 3. Add a 24-channel board profile

Channel map:

| Channels | Expander | Logical devices |
|---|---|---|
| 0–7 | OUT_1 | Light 1–8 |
| 8–15 | OUT_2 | Socket 1–8 |
| 16–23 | OUT_3 | Light 9–16 |

`Light Master`, `Socket Master` and `ALL OFF` are **intents, not channels** — they resolve to
masks over the above. Names are the cloud-facing contract (`"Light 3"`), because a person finds
a light by room and name, not by expander pin.

### 4. Explicitly NOT changed

- **Polarity stays active-low, in the driver.** The reference firmware scattered
  `state ? 0 : 1` across every call site. Ours already applies it in one place and keeps doing so.
- **Set semantics, never toggle.** The reference's `pcf8574_toggle_pin()` XORs the bit and ignores
  the requested value, so `Power: true` on an already-on light turns it **off** — invisible from
  the cloud because the app is told the requested value back. Every write here is idempotent.
- **`feedback_monitor.c`'s CD4051 path is retained.** The digital input path is added alongside
  it, not instead of it, until we know whether the new board also carries the mux.

## Consequences

**Positive**
- 24 channels supported without duplicating logic seven times over.
- Input expanders become implementable with the same primitive.
- Two-bus topologies expressible without hardcoded port numbers.
- One place to reason about polarity and one place to reason about set-vs-toggle.

**Negative / cost**
- A public signature change (`uint16_t` → `uint32_t`) touches every `relay_set_all()` caller.
- The refactor touches `relay_driver.c`, which is spec'd code — higher review burden than a
  localised patch.
- A new hardware profile needs its own `target_sku` for OTA targeting.

**Open**
- **The real I2C addresses and pin numbers are not yet supplied.** The reference project's
  `pcf8574.h` / `analoginputs.h` define `OUT1_ADD`…`ACIN2_ADD` and
  `I2C_MASTER_SDA/SCL_IO_0/1`; until those arrive the board config carries placeholders and
  **nothing may be flashed**. A wrong address writes to the wrong chip, which on a relay board
  energises the wrong circuit.
- Whether the new board also carries the CD4051 mux + ADC, or the input expanders replace it.

## Alternatives considered

**(a) Edit `relay_driver.c` in place — add `g_chip2_state` and a third branch.**
Rejected. Smallest diff, but it is the third copy of the same logic, and this board has seven
expanders. The duplication is the problem the board is exposing.

**(b) Keep `uint16_t` and expose channels 16–23 through a second function.**
Rejected. Two ways to address the same hardware invites exactly the kind of inconsistency the
reference firmware already demonstrates (its individual lights toggle while its master sets).

**(c) Port the RainMaker driver directly.**
Rejected. It carries three defects — toggle-instead-of-set, hardcoded buses, scattered polarity —
and duplicates capability `relay_driver.c` already has.

## References

- `docs/v3-specs/V3-FIRMWARE.md` §8, `V3-HARDWARE.md` §4
- `docs/LOCK-MANIFEST.md` — spec freeze and the requirement for a new ADR
- `docs/porting-rainmaker-app-main.md` — analysis of the reference firmware
- ADR-012 (ESP32 chip selection), ADR-013 (firmware security)
