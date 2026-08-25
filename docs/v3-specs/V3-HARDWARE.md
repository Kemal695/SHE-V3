# V3 — Hardware

**Status:** Locked
**Last updated:** 2025-Q1
**Owner:** Hardware Lead + Lead Engineer

---

## 1. Overview

SHE V3 ships three custom ESP32-based relay controller SKUs targeting the Ethiopian smart home market. All three share the same firmware architecture (V3-FIRMWARE.md) and cloud integration (V3-DEVICE-MODEL.md), differing only in channel count and sensor complement.

| SKU | Channels | Target | ESP32 Variant | BOM Cost | Sale Price | Margin |
|---|---|---|---|---|---|---|
| SHE-R4 | 4 | Entry (1 room) | ESP32-C3 | $18 | $55 | 67% |
| SHE-R8 | 8 | Volume (whole home) | ESP32-S3 | $24 | $75 | 68% |
| SHE-R16 | 16 | Prosumer / B2B | ESP32-S3 | $38 | $120 | 68% |

See V3-UNIT-ECONOMICS.md for full cost breakdown.

---

## 2. Block Diagram

```
                    ┌─────────────────────────────────────────┐
                    │              SHE-R8 (example)            │
                    │                                         │
   AC Mains ──────► │  ┌─────────┐   I2C    ┌──────────────┐  │ ──► Relay 1 ──► Load 1
   (220V/50Hz)      │  │ ESP32-S3 │────────►│ PCF8574 #1   │  │ ──► Relay 2 ──► Load 2
                    │  │         │         │ (8-bit GPIO)  │  │ ──► Relay 3 ──► Load 3
                    │  │  Wi-Fi  │         └──────────────┘  │ ──► Relay 4 ──► Load 4
                    │  │  BLE    │                           │ ──► Relay 5 ──► Load 5
                    │  │         │   I2C    ┌──────────────┐  │ ──► Relay 6 ──► Load 6
                    │  │  UART   │────────►│ PZEM-004T    │  │ ──► Relay 7 ──► Load 7
                    │  │  I2C    │         │ (energy)     │  │ ──► Relay 8 ──► Load 8
                    │  │  GPIO   │         └──────────────┘  │
                    │  │         │                           │
                    │  │  ADC    │◄─────── Optocoupler feedback
                    │  │  I2S    │◄─────── INMP441 mic (R16 only)
                    │  └─────────┘                           │
                    │         │                              │
                    │     USB-C                               │
                    │   (power + flash)                       │
                    └─────────────────────────────────────────┘
```

---

## 3. Component Selection

### 3.1 Microcontroller

| SKU | Chip | Why |
|---|---|---|
| SHE-R4 | **ESP32-C3-WROOM-02** | RISC-V single-core, 4MB flash, sufficient GPIO (11) for 4 relays via expander, lowest cost, supports Secure Boot v2 + Flash Encryption |
| SHE-R8 | **ESP32-S3-WROOM-1** | Dual-core Xtensa LX7, 8MB flash, more GPIO/RAM, Secure Boot v2, better Wi-Fi range, future-proof for voice (I2S mic) |
| SHE-R16 | **ESP32-S3-WROOM-1** | Same as R8; GPIO via 2x PCF8574 expanders (addresses 0x20 + 0x21) |

**Why not ESP32-WROOM-32 (classic):** The original V3 docs specified WROOM-32, but it lacks Secure Boot v2 (only v1, which is weaker) and has higher power consumption. C3/S3 are cheaper, more secure, and better supported going forward. See ADR-012.

### 3.2 Relay driver — PCF8574

- I2C GPIO expander, 8 channels per chip
- SHE-R4: 1 chip (uses 4 of 8 channels)
- SHE-R8: 1 chip (uses all 8 channels)
- SHE-R16: 2 chips (addresses 0x20 + 0x21)
- Drives optocoupler-isolated relay modules (active-low)

### 3.3 Relay modules

- **Songle SRD-05VDC-SL-C** — 5V coil, 10A @ 250VAC, SPDT
- Optocoupler isolation (PC817) between ESP32 logic and relay coil
- Active-low input (LOW = relay ON)
- Flyback diode across coil (1N4007)
- Status LED per channel

### 3.4 Energy sensor — PZEM-004T v3

- AC voltage (80-260VAC), current (0-100A with external CT), power, energy
- Modbus RTU over UART (TX/RX at 5V, level-shifted to 3.3V)
- Accuracy: ±1% voltage, ±1% current
- Reports: voltage (V), current (A), power (W), energy (kWh, cumulative), frequency (Hz), power factor
- Mounted on SHE-R8 and SHE-R16 only (SHE-R4 omits for cost)

### 3.5 Feedback circuit (optocoupler)

Each relay channel has an optocoupler (PC817) reading the actual relay contact state:
- Detects manual override (wall switch toggled while relay commanded off)
- Detects relay failure (commanded on, but contact open)
- Detects welding (commanded off, but contact closed)
- ESP32 ADC reads 8 feedback voltages via CD4051 multiplexer

### 3.6 Microphone (SHE-R16 only)

- **INMP441** — I2S MEMS microphone for Picovoice offline voice control
- Connected to ESP32-S3 I2S peripheral
- Enables "Hey Sheba" wake word + Amharic/English intents (V3-VOICE-MATTER.md §1)

### 3.7 Power supply

- **Hi-Link HLK-5M05** — 5V/1A AC-DC module, 85-265VAC input
- Feeds ESP32 (via 3.3V LDO AMS1117) + relay coils + sensors
- Total power budget: ~3W (all 8 relays active) + 1W (ESP32) + 0.5W (sensors) = 4.5W

### 3.8 USB-C connector

- For factory flashing + initial provisioning
- CP2102N USB-to-UART bridge (or CH340)
- 5V power input (alternative to AC-DC module during testing)

---

## 4. Schematic — SHE-R8 (reference)

> **Note:** Full schematics are in Altium Designer format, stored in the hardware repo at `hardware/schematics/SHE-R8-v2.schdoc`. This section documents the key sub-circuits.

### 4.1 ESP32-S3 + USB-UART

```
USB-C ──── D+ ── CP2102N ── TXD0 ── ESP32-S3 GPIO43 (U0RXD)
         ──── D- ──         ── RXD0 ── ESP32-S3 GPIO44 (U0TXD)
         ──── VBUS ──────── 5V rail (via polyfuse)
         ──── GND ───────── GND

ESP32-S3:
  GPIO0  ── BOOT button (pull-up 10k)
  GPIO45 ── STRAPPING pin (pull-down 10k for 3.3V flash)
  EN     ── RESET button (pull-up 10k + 0.1µF debounce)
```

### 4.2 PCF8574 relay driver (8 channels)

```
ESP32-S3          PCF8574 (addr 0x20)          Relay Module
─────────         ────────────────────          ────────────
GPIO8 (SDA) ──── SDA
GPIO9 (SCL) ──── SCL
                  P0 ── 1k ── PC817 anode ──► IN1 (active-low)
                  P1 ── 1k ── PC817 anode ──► IN2
                  P2 ── 1k ── PC817 anode ──► IN3
                  P3 ── 1k ── PC817 anode ──► IN4
                  P4 ── 1k ── PC817 anode ──► IN5
                  P5 ── 1k ── PC817 anode ──► IN6
                  P6 ── 1k ── PC817 anode ──► IN7
                  P7 ── 1k ── PC817 anode ──► IN8

PC817 cathode ── GND
PC817 collector ── Relay coil ── +5V
Flyback diode (1N4007) across relay coil
```

### 4.3 PZEM-004T energy sensor

```
ESP32-S3              PZEM-004T v3
─────────             ────────────
GPIO17 (U1TXD) ──── via 5V level shifter ──── RX
GPIO18 (U1RXD) ──── via 5V level shifter ──── TX
                      AC input ──── mains L (after fuse)
                      CT input ──── mains L (through CT)
                      GND ──────── GND
                      VCC ──────── 5V
```

### 4.4 Feedback circuit (per channel)

```
Relay COM contact ──── 220k ──── PC817 LED+ ──── Relay NO contact
                                  PC817 LED- ──── GND
                                  PC817 phototransistor C ──── 3.3V
                                  PC817 phototransistor E ──── 10k ──── GND
                                                                       │
                                                                       └── CD4051 input

CD4051 8:1 multiplexer:
  ESP32 ADC1_CH0 reads selected feedback voltage
  GPIO10-12 select channel (3-bit address)
  ESP32 polls all 8 channels every 500ms
```

---

## 5. PCB Design

### 5.1 Layer stackup

- 4-layer board (ENIG finish for reliability)
- Layer 1: Signal + component pads
- Layer 2: GND plane (solid, no splits under RF)
- Layer 3: Power plane (3.3V + 5V split)
- Layer 4: Signal + routing

### 5.2 Layout rules

- **Clearance:** 4mm between mains (220VAC) traces and low-voltage (3.3V/5V) — exceeds IEC 60950 requirement
- **Creepage:** 6mm between mains and low-voltage on conformal-coated board
- **Copper weight:** 1oz for signal, 2oz for relay coil current paths (2A per relay)
- **Vias:** 0.3mm drill, 0.6mm pad — minimum 4 vias per relay current path
- **Antenna keepout:** 15mm clearance around ESP32-S3 PCB antenna, no copper on any layer

### 5.3 Connectors

- **Mains input:** WAGO 2-pin screw terminal, 5.08mm pitch, 16A rated
- **Relay outputs:** WAGO 3-pin screw terminal per relay (COM + NO + NC), 5.08mm pitch
- **USB-C:** Standard SMD USB-C receptacle
- **Programming header:** 6-pin 2.54mm pitch (3V3, GND, TX, RX, EN, GPIO0) for factory jig

### 5.4 Protections

- **Fuse:** 5A fast-blow on mains L input (resettable polyfuse for development units)
- **MOV:** 275V MOV across L-N for surge protection
- **NTC:** 10D-9 inrush current limiter on mains input
- **ESD:** ESDA6V1-1U2 on USB D+/D-
- **Thermal:** 70°C thermal cutoff on relay common

---

## 6. Enclosure

### 6.1 Mechanical

- **Material:** ABS plastic, UL94 V-0 flame retardant
- **Color:** White (RAL 9003) for consumer, grey (RAL 7035) for B2B
- **Dimensions:** 120 × 80 × 40mm (SHE-R4), 150 × 100 × 50mm (SHE-R8), 200 × 130 × 60mm (SHE-R16)
- **Mounting:** DIN rail clip (optional) + wall-mount tabs
- **Cable glands:** PG9 cable glands for mains input + relay outputs (IP54 when seated)

### 6.2 Thermal

- Ventilation slots on top + bottom for natural convection
- Max internal temp at 25°C ambient, all relays active: 52°C (measured)
- Max internal temp at 40°C ambient (Ethiopian summer): 67°C — within relay rating (85°C)

### 6.3 Indicators

- **Power LED:** Green, always on when AC power present
- **Wi-Fi LED:** Blue, blinks during provisioning, solid when connected
- **Status LED per relay:** Red, on when relay is ON
- **Factory reset button:** Recessed (pinhole), hold 10s to reset Wi-Fi + MQTT config

### 6.4 Certification markings

Silkscreen on enclosure:
- CE mark + "ETL listed" (post-certification)
- FCC ID (post-certification)
- ECA type approval number (post-certification, Ethiopian Communications Authority)
- Serial number (laser-etched): `SHE-R8-2024-00142`
- QR code linking to: `https://she.et/setup/{serial}` (provisioning page)

---

## 7. Manufacturing

### 7.1 Factory partner

**Selection criteria:**
- ISO 9001 certified
- Experience with IoT/consumer electronics
- Capable of 500-5000 unit runs
- Ethiopia-adjacent for shipping cost (Shenzhen, China — 6-week sea freight to Djibouti, 2-day truck to Addis Ababa)

**Selected:** [Factory name TBD — Phase 0 deliverable, see V3-ROADMAP.md]
**Alternatives considered:**
- *Addis Ababa local assembly* — rejected: no PCB fabrication capability in Ethiopia, only assembly; 3x labor cost premium vs Shenzhen
- *Vietnam* — rejected: longer shipping to Djibouti, smaller cost advantage over Shenzhen

### 7.2 Bill of Materials (BOM) — SHE-R8

| # | Component | Part number | Qty | Unit cost | Ext cost |
|---|---|---|---|---|---|
| 1 | ESP32-S3-WROOM-1-N8 | Espressif | 1 | $4.20 | $4.20 |
| 2 | PCF8574 I2C expander | TI PCF8574PWR | 1 | $0.45 | $0.45 |
| 3 | Relay 5V 10A SPDT | Songle SRD-05VDC-SL-C | 8 | $0.55 | $4.40 |
| 4 | Optocoupler | PC817C | 16 | $0.08 | $1.28 |
| 5 | Energy sensor | PZEM-004T v3 | 1 | $3.80 | $3.80 |
| 6 | AC-DC module | Hi-Link HLK-5M05 | 1 | $1.90 | $1.90 |
| 7 | 3.3V LDO | AMS1117-3.3 | 1 | $0.12 | $0.12 |
| 8 | USB-C receptacle | U262-161N-4BVC11 | 1 | $0.35 | $0.35 |
| 9 | USB-UART bridge | CP2102N-A02-GQFN28 | 1 | $0.85 | $0.85 |
| 10 | Current transformer | SCT-013-100A | 1 | $2.10 | $2.10 |
| 11 | MOV 275V | B72220S2271K101 | 1 | $0.25 | $0.25 |
| 12 | Fuse 5A | 5x20mm fast-blow | 1 | $0.10 | $0.10 |
| 13 | Connectors | WAGO 2-pin + 3-pin | 9 | $0.40 | $3.60 |
| 14 | Capacitors (various) | — | 25 | $0.03 | $0.75 |
| 15 | Resistors (various) | — | 40 | $0.01 | $0.40 |
| 16 | Diodes (1N4007, flyback) | — | 8 | $0.04 | $0.32 |
| 17 | LEDs (PWR, WiFi, 8x status) | — | 10 | $0.06 | $0.60 |
| 18 | Switches (reset, boot) | — | 2 | $0.10 | $0.20 |
| 19 | PCB (4-layer, ENIG) | 150 × 100mm | 1 | $2.80 | $2.80 |
| 20 | Enclosure (ABS, UL94 V-0) | Custom injection-mold | 1 | $1.50 | $1.50 |
| 21 | Assembly + testing (factory) | — | 1 | $2.20 | $2.20 |
| | **TOTAL BOM** | | | | **$32.47** |
| | PCB fabrication (JLCPCB) | | | | $2.80 (included above) |
| | **Total landed cost** | | | | **$32.47** |
| | Shipping (Djibouti→Addis) | | | | $0.80 |
| | Customs duty (Ethiopia, 15%) | | | | $4.99 |
| | **Total delivered cost** | | | | **$38.26** |
| | Sale price (wholesale) | | | | **$75.00** |
| | **Gross margin** | | | | **49.0%** |

See V3-UNIT-ECONOMICS.md for full cost model including CAC, LTV, payback.

### 7.3 Production test procedure

Every unit undergoes factory QC before shipping:

1. **Visual inspection** — solder joints, component placement, silkscreen
2. **Power-on test** — USB-C power, verify 3.3V + 5V rails
3. **Wi-Fi test** — connect to factory AP, RSSI ≥ -50dBm at 1m
4. **BLE test** — discoverable, RSSI ≥ -50dBm at 1m
5. **Relay test** — cycle each relay 3x, verify click + feedback circuit reads correctly
6. **PZEM test** — apply 220VAC test load, verify voltage reading 220V ±5%
7. **Firmware flash** — production firmware + factory cert (V3-FACTORY-OPS.md)
8. **Cert verification** — verify X.509 cert installed, MQTT connect test to factory broker
9. **Provisioning QR code** — print + apply sticker with MAC + PoP
10. **Final QC** — green "PASSED" sticker, serial number etched

**Test fixture:** Custom test jig with pogo pins, powered by Raspberry Pi + relay test board. Full test cycle: 90 seconds per unit.

### 7.4 Packaging

- Anti-static bag (ESD protection)
- Foam insert (shock protection)
- Box: recycled cardboard, branded
- Contents: SHE-R8 unit, quick-start card (Amharic + English), 4x wall plugs, 2x screws
- Box dimensions: 180 × 130 × 70mm
- Carton: 20 units per carton, 4.2kg per carton

---

## 8. Certification Plan

### 8.1 CE (European Conformity)

- **Required for:** Any sales to EU (not Ethiopia, but expected by B2B customers)
- **Standards:** EN 60950-1 (safety), EN 301 489-1 (EMC), EN 300 328 (radio)
- **Lab:** TÜV SÜD (Shenzhen) — $8,000, 6 weeks
- **Status:** Pre-compliance testing at Phase 5A

### 8.2 FCC (US Federal Communications Commission)

- **Required for:** Any sales to US (future expansion)
- **Standards:** FCC Part 15B (unintentional radiator), Part 15C (intentional radiator, BLE)
- **Lab:** Element Materials Technology (Shenzhen) — $5,000, 4 weeks
- **Status:** Pre-compliance testing at Phase 5A

### 8.3 ECA (Ethiopian Communications Authority)

- **Required for:** All sales in Ethiopia (mandatory)
- **Standards:** ECA Type Approval Framework
- **Process:** Submit CE/FCC test reports + application, ECA reviews (8-12 weeks)
- **Cost:** $2,000 application + $500/yr renewal
- **Status:** Application submitted at Phase 5A

---

## 9. Hardware Revisions

| Revision | Date | Changes |
|---|---|---|
| rev-a | 2024-Q1 | Initial prototype, 4-layer, no feedback circuit |
| rev-b | 2024-Q3 | Added optocoupler feedback, PZEM-004T, USB-C |
| rev-c | 2024-Q4 | Production-ready, current revision |

Future revisions:
- **rev-d** (planned 2025-Q2): Add Matter over Thread via ESP32-H2 co-processor
- **rev-e** (planned 2025-Q4): Add Picovoice to SHE-R4/R8 (currently R16-only)

---

## 10. References

- V3-FIRMWARE.md — firmware that runs on this hardware
- V3-FACTORY-OPS.md — factory flashing + cert generation workflow
- V3-UNIT-ECONOMICS.md — full cost breakdown + margins
- ADR-002 — decision to build custom hardware
- ADR-012 — ESP32 chip selection per SKU
- ADR-013 — firmware security (Secure Boot, Flash Encryption)
- Hardware repo: `github.com/she-v3/hardware` (private, Altium + KiCad files)
