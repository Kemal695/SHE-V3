# ADR-002: Custom ESP32 Relay Controller with Feedback Circuit

**Status:** Locked
**Date:** 2024-Q4
**Decision maker:** Lead Engineer + Hardware Lead

## Context

SHE V3 needs relay-controller hardware that can switch 4, 8, or 16 household circuits (lights, fans, outlets), report real-time energy usage, survive Ethiopian grid conditions (220V/50Hz with frequent brownouts and surges), and run our own firmware so we can ship OTA updates, on-device scheduling, and offline voice.

Off-the-shelf smart-relay products from Tuya, Sonoff, and Shelly dominate the AliExpress market and would let us skip the 12-week hardware development cycle entirely. But they ship with their vendors' firmware, which means: (1) we cannot run our own cert-based mTLS auth — they use vendor cloud credentials; (2) we cannot ship our RainMaker-hierarchy device model — their payloads are flat `switch:1/on` style; (3) we cannot add an optocoupler feedback circuit, which we need to detect manual wall-switch overrides and relay weld failures; (4) B2B white-label tenants cannot re-brand the hardware or install their own certs; (5) we are entirely dependent on the vendor's OTA cadence and roadmap.

The hardware is also where the unit economics live. The bare BOM on a SHE-R8 is $24 (V3-HARDWARE.md §7.2) and the sale price is $75 — a 68% margin on bare BOM. That margin funds the cloud, CAC, RMA reserve, and the Picovoice voice tier on the R16. Off-the-shelf hardware would either be resold at a 10–20% retail markup (no margin to fund the cloud) or torn down and reflashed (defeating the purpose of buying off-the-shelf).

## Decision

Design and manufacture three custom ESP32-based relay controller SKUs:

- **SHE-R4** — 4-channel, ESP32-C3, $18 bare BOM, $55 sale (entry SKU)
- **SHE-R8** — 8-channel, ESP32-S3, $24 bare BOM, $75 sale (volume SKU)
- **SHE-R16** — 16-channel, ESP32-S3 + INMP441 I2S microphone for Picovoice, $38 bare BOM, $120 sale (prosumer/B2B SKU)

All three share: PCF8574 I2C GPIO expanders driving optocoupled Songle SRD-05VDC-SL-C relays; an optocoupler feedback loop reading relay COM contact state back to the ESP32 ADC via a CD4051 multiplexer (the unique differentiator — detects manual overrides and weld failures); Hi-Link HLK-5M05 AC-DC module with MOV + NTC + fuse protection; PZEM-004T v3 energy sensor on R8/R16; USB-C factory flash via CP2102N; ABS UL94 V-0 enclosure.

Manufacturing is contracted to a Shenzhen ISO 9001 partner (sea freight to Djibouti, truck to Addis). Full BOM, schematic, PCB layout, certification plan, and production test procedure are in V3-HARDWARE.md. Chip selection is decided in ADR-012; firmware security (Secure Boot v2 + Flash Encryption) in ADR-013; factory flashing in ADR-014.

## Alternatives Considered

### Alternative A: Tuya off-the-shelf smart relays (WB3S module, Tuya cloud)
- **Pros:** Zero hardware development time; mature supply chain; cheap ($8–$15/4-channel unit at retail); Tuya's "MCU SDK" lets us add custom firmware on the secondary MCU.
- **Cons:** Tuya cloud is mandatory for first-boot — we cannot ship without sending device data to Tuya's AWS-China region; violates ADR-001 (self-hosted) and PDPP; no optocoupler feedback circuit possible without redesigning the board (which is harder than starting from scratch); the WB3S module is a Tuya-locked ESP32 variant — no Secure Boot v2 under our keys; B2B tenants cannot re-brand. **Rejected.**

### Alternative B: Sonoff (ITEAD) — e.g., Sonoff 4CH Pro R3
- **Pros:** Cheap ($20 retail for 4-channel), well-documented community hacks (Tasmota/ESPHome), ESP8266/ESP32-based so theoretically reflashed.
- **Pros (cont.):** Can be bought in single-unit quantities for rapid prototyping.
- **Cons:** ESP8266 on most SKUs — no Secure Boot v2, no BLE for provisioning, limited flash; reflashing requires opening the enclosure and soldering (no factory-friendly USB-C); Sonoff's PCB layout has no isolation between mains and logic (relies on creepage only — fails our internal safety margin); no energy sensor, no feedback circuit; community firmware (Tasmota) has its own MQTT conventions that fight our RainMaker-hierarchy topic namespace (V3-MQTT-STANDARDS.md). **Rejected.**

### Alternative C: Shelly (Allterco) — e.g., Shelly Plus 4Pro
- **Pros:** Best-in-class hardware quality; ESP32-based (Shelly Plus generation); documented MQTT API; some energy monitoring; EU CE certification already done.
- **Cons:** Closed firmware — we cannot run our own cert, our own OTA, our own RainMaker-hierarchy payload; expensive ($50–$80 retail per 4-channel unit) — at our $75 R8 sale price there is zero margin; no optocoupler feedback circuit; no path to SHE-R16 (16 channels) without daisy-chaining four Shelly 4Pro units, which multiplies cost; vendor lock-in on OTA and cloud. **Rejected.**

### Alternative D: Reference design from Espressif (ESP32-S3-DevKit + off-the-shelf relay shields)
- **Pros:** Familiar to firmware team; avoids PCB design; lets us start firmware development while hardware team designs the production board.
- **Cons:** Used as the *prototype* path (rev-a, see V3-HARDWARE.md §9) — not a production option; dev-kit form factor is too large for the enclosure, has no isolation, no feedback circuit, no PZEM. **Rejected for production; adopted for prototyping only.**

## Consequences

### Positive
- 67–68% gross margin on bare BOM (V3-HARDWARE.md §1) — funds the cloud, CAC, RMA reserve, and the R16 voice tier
- Unique differentiator: optocoupler feedback circuit detects manual wall-switch overrides (common in Ethiopian homes where wall switches remain in use alongside smart relays) and relay weld failures — no off-the-shelf product does this
- Full firmware control — Secure Boot v2 under our keys, our own OTA, our own RainMaker-hierarchy payloads, our own offline voice on R16
- B2B white-label: hardware can be flashed with tenant certs, branded with tenant logo on enclosure, sold at tenant-negotiated price
- Hardware-software integration: the same team owns the firmware, the device model, and the cloud — no finger-pointing across vendor boundaries
- Hardware roadmap independence: rev-d (2025-Q2) can add ESP32-H2 for Matter-over-Thread, rev-e (2025-Q4) can add Picovoice to R4/R8 — these decisions are ours, not a vendor's

### Negative
- 12-week hardware development cycle (rev-a → rev-b → rev-c) before production-ready units
- Certification cost: CE ($8k), FCC ($5k), ECA ($2k + $500/yr) — V3-HARDWARE.md §8
- Factory partner dependency: must qualify, audit, and maintain relationship with a Shenzhen ISO 9001 partner
- Inventory risk: 500-unit first batch tied up in working capital (~$12.6k for SHE-R8) before any revenue
- Hardware is hard — first rev may have an unknown unknown (antenna detuning, ground bounce, relay coil flyback coupling into ADC) that requires a respin
- Mains-voltage product liability — a relay that fails to disconnect on command could cause property damage or fire; product liability insurance and the ECA certification path are mandatory, not optional

### Neutral
- Hardware team is currently one contractor (months 4–9) plus the Lead Engineer — that is thin for a custom ESP32 board with mains isolation; we are deliberately accepting this risk because the alternative (off-the-shelf) is a worse business outcome
- Custom hardware is a moat — competitors in Ethiopia cannot trivially copy the feedback circuit and cert pipeline; this is a feature, not a bug
- The BOM cost numbers in V3-HARDWARE.md §7.2 are accurate as of 2024-Q4 LCSC/JLCPCB pricing — component prices fluctuate, so the margin model in V3-UNIT-ECONOMICS.md should be re-validated every quarter
- The 4-layer ENIG PCB spec is conservative; we could probably ship a 2-layer HASL board for $1 less but the reliability margin would shrink — we keep the 4-layer spec for the safety margin
- Hardware revisions (rev-a → rev-b → rev-c, planned rev-d/rev-e) are a normal part of the product lifecycle; the V3 GA ships rev-c and the roadmap documents future revisions

## References
- V3-HARDWARE.md (full BOM, schematic, PCB, enclosure, manufacturing, certification)
- V3-UNIT-ECONOMICS.md §1–2 (BOM-to-landed-cost-to-margin waterfall)
- V3-FACTORY-OPS.md (factory flashing workflow on this hardware)
- V3-DEVICE-MODEL.md (the RainMaker-hierarchy device model the firmware exposes)
- ADR-001 (self-hosted cloud — the reason we need own firmware)
- ADR-012 (ESP32-C3 for R4, ESP32-S3 for R8/R16)
- ADR-013 (Secure Boot v2 + Flash Encryption on this hardware)
- ADR-014 (factory flashing of certs onto this hardware)
- V3-SUPPORT-RMA.md (warranty + RMA path for hardware failures)
- V3-GO-TO-MARKET.md (hardware distribution channels, retail + installer network)
