# ADR-007: Matter-over-Wi-Fi per Device (no central Border Router)

**Status:** Locked
**Date:** 2024-Q4
**Decision maker:** Lead Engineer

> **Note:** This ADR supersedes and replaces the original `007-matter-border-router.md`, which proposed running a Raspberry Pi Border Router at the Addis Ababa data center. That topology was architecturally wrong — see Context §2 below. The filename has been renamed to `007-matter-over-wifi.md` to reflect the corrected decision.

## Context

Matter is the CSA (Connectivity Standards Alliance) smart-home interoperability standard that lets devices work across Apple Home, Google Home, and Amazon Alexa without per-platform integrations. For SHE V3, Matter support is strategically important: it lets a SHE device appear in the user's existing Apple Home / Google Home setup alongside their other Matter devices, which is a major B2C marketing point and reduces our app-lock-in risk.

**Why the original "Border Router at the data center" idea was wrong.** Thread is a low-power mesh networking protocol that runs over IEEE 802.15.4 at 2.4 GHz. A Thread Border Router bridges a Thread mesh to a different IP transport (typically Wi-Fi/Ethernet). Critically, the Border Router must be **physically on the same Thread mesh** as the devices — it lives in the home, not in a data center. A Border Router hosted in an Addis Ababa DC cannot reach a Thread mesh in a user's home 10 km away, because Thread has a range of ~30 m line-of-sight. The original ADR conflated "Border Router" with "cloud service" — these are not the same. Thread is a local-mesh technology; there is no such thing as a "DC-side Border Router."

Furthermore, our hardware (V3-HARDWARE.md §3.1) is ESP32-C3 (R4) and ESP32-S3 (R8/R16) — both are Wi-Fi/BLE chips, **not** Thread/802.15.4 chips. To do Matter-over-Thread we would need either an ESP32-H2 co-processor (Thread-only, no Wi-Fi) or an ESP32-C6 (Wi-Fi 6 + Thread). Adding an ESP32-H2 to every device is a BOM cost increase of ~$1.50 and a PCB redesign. Matter-over-Wi-Fi, by contrast, runs natively on the ESP32-C3/S3 we already ship — no new silicon, no new antenna, no new certification.

**Why this is deferred to V3.1, not V3 GA.** Matter SDK maturity on ESP-IDF is good but not great as of 2024-Q4; the `esp-matter` SDK is at v1.3 and has known issues with iOS 17 commissioning. CSA membership is $5k/year for a Participant tier, plus $3.5k per certified device variant (R4, R8, R16 = 3 variants = $10.5k certification). That spend is hard to justify for a 5,000-device first year; it makes sense once we cross ~25k devices and Matter becomes a meaningful B2C acquisition channel.

## Decision

Adopt **Matter-over-Wi-Fi** as the Matter topology for SHE V3. Each SHE device runs the Matter SDK natively on its ESP32 Wi-Fi chip and appears as a Matter device on the user's home Wi-Fi network. There is **no central Border Router** at the data center and **no Thread radio** on any V3 SKU.

Topology:
```
[Apple Home / Google Home / Alexa on user's phone]
                  │ Matter-over-Wi-Fi (commissioned via QR code)
                  ▼
        [Home Wi-Fi router (user-owned)]
                  │
                  ▼
        [SHE-R8 device — Matter-on-Wi-Fi + native MQTT to SHE cloud]
                  │
                  │ (also publishes to she/... MQTT topics on our EMQX broker)
                  ▼
        [SHE cloud — sees the same device via MQTT, app control still works]
```

The SHE device runs **both** the Matter stack (so Apple Home can control it) and the native MQTT-to-SHE-cloud stack (so the SHE mobile app can control it). The two control planes share the same relay-state machine in firmware — a Matter `OnOff` cluster write and a SHE MQTT `params/remote` command both call the same `relay_set(channel, state)` function. This is the standard "bridged" pattern for Matter devices that also have a proprietary cloud.

**Deferred to V3.1** (target 2025-Q3, post-GA): ship Matter support once we have (a) CSA membership, (b) one device variant certified (start with R8 — the volume SKU), (c) `esp-matter` SDK at v1.4+ with iOS commissioning fixed, (d) bandwidth in the firmware team after V3 GA stabilization.

**Thread is explicitly out of scope for V3.x** — a future rev-d hardware (planned 2025-Q2, V3-HARDWARE.md §9) adds an ESP32-H2 co-processor for Thread, but only as a research-grade SKU. Matter-over-Wi-Fi is the V3 commitment.

## Alternatives Considered

### Alternative A: Thread Border Router on Raspberry Pi at the data center (the original ADR-007)
- **Pros:** (None — this is architecturally impossible.)
- **Cons:** Thread is a local mesh with ~30 m range; a Border Router in an Addis DC cannot reach a Thread mesh in a user's home; would require every device to be Thread-enabled (new ESP32-H2 silicon on every device); would require a per-home Border Router anyway (e.g., Apple TV, HomePod, Nest Hub — none of which we control). **Rejected — topology error.**

### Alternative B: No Matter support at all
- **Pros:** Zero SDK integration work; zero CSA membership fees ($5k/yr); zero per-variant certification cost ($3.5k × 3 = $10.5k); zero ongoing Matter compliance overhead.
- **Cons:** SHE devices work only with the SHE app — users who already have Apple Home / Google Home / Alexa setups cannot integrate us; closes a major B2C acquisition channel; risks being perceived as a "closed" platform; in 2–3 years Matter will likely be table-stakes for any new smart-home device and we'd be forced to retrofit. **Rejected for V3.1; remains a defensible position for V3 GA only.**

### Alternative C: Matter-over-Thread (with ESP32-H2 on every device)
- **Pros:** Lower power than Wi-Fi (Thread devices can run for years on a coin cell — relevant for sensors, less so for always-powered relays); mesh topology extends range across the home without Wi-Fi coverage holes; Thread is the "future-proof" Matter transport.
- **Cons:** Requires ESP32-H2 co-processor on every device (~$1.50 BOM adder × 5k devices = $7.5k/yr); requires a Thread Border Router in every home (Apple TV 4K, HomePod mini, Nest Hub, Echo 4th gen — none of which Ethiopian users typically own in 2024); PCB redesign for rev-d; Thread certification adds $3.5k/variant on top of Matter certification; Thread commissioning over Wi-Fi is currently less reliable than direct Matter-over-Wi-Fi commissioning. **Rejected for V3 — revisit in V4 if Thread ecosystem matures in Ethiopia.**

### Alternative D: Hub-based Matter (a SHE-branded home hub that bridges cloud + Matter)
- **Pros:** SHE controls the hub experience; hub can host a Thread Border Router; revenue from a second SKU.
- **Cons:** Adds a hub SKU to a product line that already has 3 SKUs and a 2-3 engineer team; users resist hubs (one more thing to install, power, update); Apple/Google hubs already do this job better than a startup hub would; defeats the "matter-direct-from-device" simplicity story. **Rejected.**

## Consequences

### Positive
- No new silicon on V3 hardware — Matter runs on the ESP32-C3 (R4) and ESP32-S3 (R8/R16) we already ship
- No Border Router to operate, ship, or support — the user's existing Apple/Google/Amazon hub (if any) handles the Matter controller role
- SHE devices appear natively in Apple Home / Google Home / Alexa alongside other Matter devices — major B2C marketing point
- Dual control plane (Matter + native SHE MQTT) means users who install our app and users who use Apple Home both work — no either/or
- V3.1 timeline is realistic — Matter-over-Wi-Fi SDK integration is ~4 weeks of firmware work for a single device variant

### Negative
- **Deferred to V3.1** — V3 GA ships without Matter; early adopters must use the SHE app exclusively
- **CSA membership + certification costs** ($5k/yr + $3.5k/variant × 3 = $15.5k upfront, ongoing $5k/yr) — meaningful for a startup budget
- **Wi-Fi dependency for Matter control** — if the home Wi-Fi is down, Matter control fails (the SHE device still works via the SHE app on the same LAN, and via the SHE cloud if internet is up). Thread would survive Wi-Fi outage, but we have rejected Thread
- **Dual-stack firmware complexity** — running both Matter and our native MQTT stack adds ~500 KB to flash and one more always-on task; debugging two control planes is harder than debugging one
- **Matter SDK maturity risk** — `esp-matter` v1.3 has known iOS 17 commissioning issues; deferring to V3.1 bets that v1.4+ resolves these
- **No local control if both Wi-Fi and internet are down** — Matter-over-Wi-Fi needs the Wi-Fi router up; if the router is down, the SHE device is uncontrollable (relays stay in last state, which is safe but inconvenient)

### Neutral
- Apple Home, Google Home, and Alexa all support Matter-over-Wi-Fi commissioning via QR code — we will print a Matter commissioning QR on the enclosure (in addition to the BLE-provisioning QR for the SHE app)
- Thread remains a documented "future direction" in V3-HARDWARE.md §9 (rev-d, 2025-Q2) — this ADR does not foreclose Thread; it defers it
- Matter support will require a DPIA addendum — Apple/Google/Amazon may receive device-identifying info during Matter commissioning

## References
- V3-VOICE-MATTER.md §3 (Matter integration spec, commissioning flow, dual-stack firmware)
- V3-HARDWARE.md §9 (rev-d plan to add ESP32-H2 for future Thread research)
- V3-OVERVIEW.md §2.8 (Matter support deferred to V3.1)
- V3-ROADMAP.md (V3.1 timeline, post-GA)
- V3-DPIA.md (Matter commissioning as a subprocessor activity — Apple/Google/Amazon)
- ADR-001 (self-hosted cloud — the SHE MQTT stack that runs alongside Matter)
- ADR-002 (custom hardware — the ESP32-C3/S3 platforms Matter runs on)
- ADR-012 (chip selection — ESP32-C3/S3 are Matter-over-Wi-Fi capable)
- CSA Matter spec: https://csa-iot.org/all-solutions/matter/
- ESP-Matter SDK: https://github.com/espressif/esp-matter
