# ADR-016: Digital I2C Input Expanders Alongside the CD4051/ADC Path

**Status:** Proposed
**Date:** 2026-Q3
**Decision maker:** Lead Engineer

## Context

`feedback_monitor.c` reads AC feedback through a **CD4051 8:1 analog multiplexer + ADC**
(V3-FIRMWARE §8), polling one channel at a time every 100 ms. Mux select pins are GPIO 4/5/6
(target-dependent; 4/5/18 on the DevKit build, 10/11/12 elsewhere).

The 24-relay board does not do this. It reads feedback from **digital I2C input expanders** —
4 × PCF8574, on a **second I2C bus**, separate from the output expanders. `app_main.c` in the
reference firmware reads them as bytes and applies active-low polarity per pin.

These are not variants of one another. Analog multiplexed sampling reads a *voltage* on one
channel at a time and needs settling time; a digital expander latches **all eight inputs
simultaneously** and reads them in a single transaction. Neither substitutes for the other:

- The mux path cannot report eight inputs at the same instant.
- The expander path cannot measure an analog level.

So this is an **addition**, not a replacement. `docs/LOCK-MANIFEST.md` requires a new ADR for a
change to spec'd behaviour, which is what this is.

## Decision

Add a digital input path that reuses the expander abstraction introduced in ADR-015, and keep the
CD4051/ADC path intact.

### 1. Put the bus in the chip handle

`relay_driver.c`'s chip table currently assumes a single bus. Extend each entry with its bus so
one abstraction covers both sides:

```c
typedef struct {
    uint8_t addr;      /* I2C 7-bit address */
    uint8_t bus;       /* I2C port — outputs on one, inputs on another */
    uint8_t shadow;    /* last written byte (outputs only) */
    bool    present;
} she_expander_t;
```

This is the "bus in the handle" point from ADR-015, applied. The reference firmware hardcoded
`I2C_NUM_1` for reads and `I2C_NUM_0` for writes regardless of which device was passed in, which
only worked because that board happened to split outputs and inputs across two buses. Encoding it
per chip makes the assumption explicit and survives a board that puts both on one bus.

### 2. Inputs are read whole, not per pin

A PCF8574 has no pin-select: you read the byte and mask. Reading a single input is therefore a
local operation on a cached byte, not a bus transaction. The API should reflect that:

```c
esp_err_t feedback_read_all(uint8_t chip, uint8_t *out);
bool      feedback_get(uint8_t chip, uint8_t pin);   /* from cache */
esp_err_t feedback_poll(void);                       /* refresh all input chips */
```

Polling all input chips once per cycle is cheaper than the mux path — four transactions per cycle
against eight ADC samples with settling delays — so the existing 100 ms period is comfortable.

### 3. Polarity and semantics live in one place

Active-low inputs (as the reference firmware assumes) are inverted in exactly one function, not at
every call site. As with the outputs, a `feedback_get()` that returns the *electrical* level would
push polarity back onto every caller.

### 4. Explicitly NOT changed

- **The CD4051/ADC path stays.** Whether a given board has the mux, the expanders, or both is a
  board property; both paths are compiled and selected at runtime by what answers on the bus.
- **The 100 ms poll period is unchanged.** It is already specified and the expander path is cheaper.
- **`feedback_monitor`'s published topic shape is unchanged** — same parameters, same semantics.
  Only the source of the reading differs.

## Consequences

**Positive**
- One expander abstraction covers outputs and inputs; a board with both is configuration, not code.
- Whole-byte reads remove the per-channel settling delay the mux path needs.
- Digital inputs are debounce-friendly — the level is latched, so a poll cannot catch a channel
  mid-transition the way a single ADC sample can.

**Negative / cost**
- Two feedback sources to reason about, and a board with neither must degrade gracefully.
- The bus field touches every chip-table entry, including the output path that is already working.
- Untestable without the R24 board and its real addresses — the same block as ADR-015.

**Open**
- **Whether the R24 board also carries the CD4051 mux.** Unknown. If it does not, the mux path
  becomes dead code on that SKU but must stay for the R3/R4 units that use it.
- **Input polarity is assumed active-low**, carried over from the reference firmware. It has not
  been measured on real hardware. A wrong assumption here reports every input inverted, which
  looks like a wiring fault — worth confirming with a meter before trusting it.
- The input expander addresses are unknown (same gap as ADR-015).

## Alternatives considered

**(a) Replace the mux path with the expander path.**
Rejected. The two measure different things, and existing boards have the mux.

**(b) Read inputs through `relay_driver` rather than a separate module.**
Rejected on naming, not mechanism. "Relay" is an output concept; a reader looking for input
handling will not think to open `relay_driver.c`. The shared *abstraction* is what should be
common, not the file.

**(c) Keep hardcoded bus numbers as the reference firmware does.**
Rejected. It works only by coincidence of how one board is wired, and silently breaks on a board
that wires both sides to the same bus.

## References

- `docs/v3-specs/V3-FIRMWARE.md` §8 — feedback monitoring
- `docs/LOCK-MANIFEST.md` — spec freeze; requirement for a new ADR
- ADR-015 — 32-bit relay mask and the expander abstraction this builds on
- `docs/porting-rainmaker-app-main.md` — the reference firmware analysis
