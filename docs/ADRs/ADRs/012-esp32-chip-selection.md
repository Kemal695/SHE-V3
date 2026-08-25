# ADR-012: ESP32 Chip Selection — C3 for R4, S3 for R8/R16

**Status:** Locked
**Date:** 2024-Q4
**Decision maker:** Lead Engineer + Hardware Lead

## Context

SHE V3 ships three relay-controller SKUs (R4/R8/R16) that share firmware architecture and cloud integration but differ in channel count, sensor complement, and target customer. The choice of ESP32 variant per SKU is a load-bearing decision because it determines: (1) BOM cost (the MCU is ~15–20% of total BOM), (2) available GPIO/RAM/flash for relay expansion and future features, (3) security capabilities (Secure Boot v2, Flash Encryption — see ADR-013), (4) BLE support for provisioning, (5) Wi-Fi range and throughput, (6) future-proofing (Picovoice voice on R16 needs more RAM; Matter SDK needs Wi-Fi 4 minimum).

The original V3 docs specified **ESP32-WROOM-32** (the classic 2016-era ESP32 dual-core Xtensa module) for all three SKUs. This was the safe choice in 2020 but is now the wrong choice in 2024 for three reasons: (a) WROOM-32 supports only Secure Boot v1 (weaker, deprecated by Espressif), not Secure Boot v2 — see ADR-013; (b) it has higher power consumption than the C3/S3 variants; (c) Espressif's roadmap and SDK attention has shifted to C3/S3/C6 — WROOM-32 is in maintenance mode. The C3 (RISC-V single-core) and S3 (Xtensa LX7 dual-core) are the current-generation parts with first-class Secure Boot v2 support.

The chip-per-SKU decision must balance: cost (lowest on C3), GPIO/RAM (highest on S3), security (both support SBv2), and future features (voice, Matter, future Thread co-processor).

## Decision

Use **ESP32-C3-WROOM-02** for **SHE-R4** (entry, 4-channel SKU) and **ESP32-S3-WROOM-1** for **SHE-R8** and **SHE-R16** (volume and prosumer SKUs).

| SKU | Chip | Why |
|---|---|---|
| SHE-R4 | **ESP32-C3-WROOM-02** | RISC-V single-core, 4MB flash, 11 GPIO (sufficient for 4 relays via 1× PCF8574 expander), lowest cost (~$1.80), supports Secure Boot v2 + Flash Encryption, BLE 5.0 for provisioning. Target: entry consumer, price-sensitive. |
| SHE-R8 | **ESP32-S3-WROOM-1** | Dual-core Xtensa LX7, 8MB flash, more GPIO/RAM, Secure Boot v2, better Wi-Fi range, I2S peripheral for future Picovoice mic (rev-e), sufficient headroom for Matter SDK (V3.1). Target: volume SKU, whole-home. |
| SHE-R16 | **ESP32-S3-WROOM-1** | Same as R8; 16 relays via 2× PCF8574 expanders (I2C, doesn't need more GPIO); INMP441 I2S mic for Picovoice voice (rev-c). Target: prosumer/B2B. |

**Why C3 for R4, not S3:** The R4 is the price-sensitive entry SKU. The C3 saves ~$2.40/unit vs S3 (at 5k units/yr, that is $12k/yr in margin preserved). The C3 has sufficient GPIO (11) for 4 relays via one PCF8574 I2C expander, sufficient flash (4 MB) for the firmware + Matter SDK in V3.1, and full Secure Boot v2 support. The C3 lacks the I2S peripheral needed for the INMP441 microphone — but R4 doesn't ship a microphone (rev-e in 2025-Q4 will evaluate whether to upgrade R4 to S3 to add voice, or keep R4 as a no-voice entry SKU).

**Why S3 for R8 and R16, not C3:** The S3 has dual-core (faster OTA + telemetry in parallel with relay control), more RAM (for Matter SDK + Picovoice voice on R16), 8 MB flash (room for Matter + voice models alongside relay firmware), better Wi-Fi range (important for whole-home coverage), and I2S peripheral (for the INMP441 mic on R16). The R8 doesn't currently use voice, but it benefits from the dual-core + extra RAM for Matter-over-Wi-Fi in V3.1. Keeping the R8 and R16 on the same chip simplifies the firmware build matrix (one S3 build, one C3 build — not three different builds).

## Alternatives Considered

### Alternative A: ESP32-WROOM-32 (classic) for all SKUs (the original V3 plan)
- **Pros:** Familiar to firmware team; large community knowledge base; cheapest module (sometimes — pricing fluctuates); 18 GPIO (plenty for any SKU without expanders).
- **Cons:** **Supports only Secure Boot v1, not v2** — SBv1 is weaker (SHA-256 only, no signature verification on the bootloader itself) and deprecated by Espressif; higher power consumption (~20% more than C3 in light-sleep); Espressif's roadmap and `esp-idf` attention has shifted to C3/S3/C6 — WROOM-32 is in maintenance mode; no I2S peripheral on all variants (limits future voice); larger physical footprint. **Rejected — fails the Secure Boot v2 requirement (ADR-013).**

### Alternative B: ESP32-C3 for all SKUs (R4 + R8 + R16)
- **Pros:** Lowest BOM cost across the line; simplest firmware build matrix (one chip, one binary); single procurement line item.
- **Cons:** **Insufficient GPIO for R16 without multiple PCF8574 expanders** — C3 has 11 GPIO, R16 needs 16 relay channels + I2C + UART (PZEM) + I2S (mic) + ADC (feedback) + status LEDs. Even with 2× PCF8574 expanders (32 channels), the I2S mic requires a peripheral the C3 lacks; **no I2S peripheral on C3** — kills the Picovoice voice feature on R16, which is the R16's primary differentiator (and justifies the $120 price); less RAM (400 KB vs 512 KB on S3) — Matter SDK + voice models are tight on 400 KB; single-core means OTA download competes with relay control for CPU. **Rejected — R16 loses its differentiator.**

### Alternative C: ESP32-S2 for all SKUs
- **Pros:** Single-core Xtensa (familiar ISA), 43 GPIO (no expanders needed even for R16), Secure Boot v2 support, low power.
- **Cons:** **No BLE** — S2 is Wi-Fi-only; SHE V3 uses BLE for provisioning (V3-FIRMWARE.md §5, V3-MOBILE-APP.md §3) — without BLE we'd have to use Wi-Fi SoftAP provisioning which is clunkier UX; smaller community than C3/S3; Espressif positions S2 as a "secure Wi-Fi MCU" not a smart-home part; no I2S on all variants. **Rejected — no BLE kills provisioning UX.**

### Alternative D: ESP32-C6 for all SKUs
- **Pros:** Wi-Fi 6 + Thread + BLE 5.0 + Zigbee; future-proof for Matter-over-Thread (ADR-007 future rev-d); RISC-V single-core.
- **Cons:** C6 is a 2024-Q2 launch part — limited availability in 2024-Q4; higher unit cost than C3/S3; `esp-idf` support is newer and less battle-tested; Thread/Zigbee radios are unused on V3 (we ship Matter-over-Wi-Fi, not Matter-over-Thread — ADR-007); Thread certification adds $3.5k/variant. **Rejected for V3 — revisit in V4 for rev-d Thread research SKU (V3-HARDWARE.md §9).**

### Alternative E: ESP32-S3 for R4 as well (uniform S3 across the line)
- **Pros:** One firmware build, one procurement line, one certification variant; R4 gains I2S + more RAM for future voice (rev-e); R4 gains dual-core for cleaner OTA.
- **Cons:** ~$2.40/unit cost premium on the price-sensitive entry SKU (5k units/yr × $2.40 = $12k/yr margin loss); R4 doesn't need voice or Matter-headroom at the entry price point; BOM moves from $18 → ~$20.40, sale price stays $55 — margin compresses from 67% to 63%. **Rejected for V3 — revisit in V3.1 if R4 voice (rev-e) justifies the upgrade.**

## Consequences

### Positive
- **Cost-optimized per SKU** — C3 saves ~$2.40/R4 unit; S3 is justified on R8/R16 where the additional capabilities are used
- **Secure Boot v2 on all SKUs** — both C3 and S3 support SBv2 (the WROOM-32 of Alternative A does not), enabling the firmware security stack in ADR-013
- **BLE on all SKUs** — both C3 and S3 have BLE 5.0 for provisioning (Alternative C's S2 does not)
- **I2S on R16** — the S3's I2S peripheral enables the INMP441 microphone for Picovoice voice (ADR-006), the R16's primary differentiator
- **Two-chip matrix, not three** — C3 (R4) + S3 (R8/R16) is a manageable firmware build matrix; Alternative B (C3 for all) would have been simpler but lost R16 voice
- **Matter-ready** — both C3 and S3 support the `esp-matter` SDK for Matter-over-Wi-Fi in V3.1 (ADR-007)
- **Espressif roadmap alignment** — C3 and S3 are current-generation parts with active SDK development; WROOM-32 (Alternative A) is in maintenance

### Negative
- **Two firmware builds** — C3 (RISC-V) and S3 (Xtensa) require separate `esp-idf` build configurations; some compiler intrinsics differ; testing matrix doubles (every firmware change tested on both chips)
- **Two procurement line items** — C3-WROOM-02 and S3-WROOM-1 are separate SKUs on the JLCPCB/LCSC BOM; minimum order quantities apply to each
- **C3 has less RAM** (400 KB vs S3's 512 KB) — V3.1 Matter SDK + future voice on R4 would be tight; mitigated by deferring R4 voice to rev-e evaluation (2025-Q4)
- **C3 is single-core** — R4's OTA download competes with relay control for CPU; mitigated by lower OTA frequency on R4 (entry users update less) and graceful background download
- **No Thread/Zigbee on either chip** — V3 cannot do Matter-over-Thread without an ESP32-H2 co-processor (rev-d research SKU, V3-HARDWARE.md §9); this is consistent with ADR-007 (Matter-over-Wi-Fi only for V3.x)

### Neutral
- Both C3 and S3 are ESP-IDF v5.1+ supported — firmware code is shared ~95% between SKUs (the 5% is GPIO pin maps, I2S driver conditional on R16, PZEM driver conditional on R8/R16)
- The chip decision is reversible per-SKU at hardware revision time — rev-d (2025-Q2) and rev-e (2025-Q4) can revisit if unit economics or feature demands shift
- Espressif's module naming (`-WROOM-02`, `-WROOM-1`) refers to module variant, not chip; the underlying chips are ESP32-C3 and ESP32-S3 respectively

## References
- V3-HARDWARE.md §3.1 (chip selection per SKU, rationale vs WROOM-32)
- V3-HARDWARE.md §7.2 (BOM with ESP32-S3 line item — $4.20/unit)
- V3-FIRMWARE.md (ESP-IDF v5.1 build matrix, conditional compilation per SKU)
- V3-SECURITY-MODEL.md §5 (Secure Boot v2 + Flash Encryption on C3 and S3)
- ADR-002 (custom hardware — these chips are the MCUs)
- ADR-006 (Picovoice voice — requires S3's I2S peripheral, R16-only)
- ADR-007 (Matter-over-Wi-Fi — both C3 and S3 support `esp-matter` SDK)
- ADR-013 (firmware security — both chips support SBv2 + Flash Encryption)
- Espressif ESP32-C3 datasheet: https://www.espressif.com/sites/default/files/documentation/esp32-c3_datasheet_en.pdf
- Espressif ESP32-S3 datasheet: https://www.espressif.com/sites/default/files/documentation/esp32-s3_datasheet_en.pdf
