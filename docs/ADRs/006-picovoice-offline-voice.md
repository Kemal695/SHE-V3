# ADR-006: Offline Voice Control via Picovoice SDK

**Status:** Locked
**Date:** 2024-Q4
**Decision maker:** Lead Engineer

## Context

Voice control is the "wow feature" that differentiates a premium smart-home product from a relay-with-an-app. In the Ethiopian market it is also a usability necessity: many target users (older family members, household staff) are not comfortable navigating a phone app to toggle a light, but will say "ብርሃን አጥፋ" (Amharic for "turn off the light") naturally.

Cloud voice assistants (Alexa, Google Assistant) do not work for SHE V3 because: (1) Ethiopian internet is unreliable — voice commands would fail when connectivity drops, which is exactly when users most need light control; (2) Alexa and Google Assistant do not support Amharic as of 2024-Q4; (3) cloud voice means audio leaves the home — a privacy posture that conflicts with our PDPP-compliant self-hosted positioning; (4) Alexa/Google require hardware certification and platform fees that don't fit a startup budget; (5) cloud voice adds 200–500 ms latency per command — noticeable and annoying.

On-device voice recognition needs to fit on an ESP32-S3 (512 KB SRAM, 8 MB flash) alongside the relay firmware. Picovoice's Porcupine (wake word) + Rhino (intent inference) engines are designed exactly for this: C SDK, ARM/RISC-V optimized, ~150 KB RAM footprint, works offline, supports custom wake words and Amharic via their custom-model service.

## Decision

Use the **Picovoice SDK** for offline on-device voice control on the **SHE-R16 only** (the prosumer/B2B SKU with the INMP441 I2S MEMS microphone). The pipeline is:

1. **Wake word** — Picovoice Porcupine, custom wake word "Hey Sheba" (English phonetics, recognizable across Amharic/English speakers). Trained via Picovoice Console.
2. **Intent inference** — Picovoice Rhino, with a custom context (SmartHome_Ethiopian) supporting Amharic + English intents: "turn on relay N", "turn off relay N", "turn everything off", "what's the power usage".
3. **Execution** — Rhino emits a structured intent JSON; the firmware calls the existing `node_set_param` internal API (same code path as a cloud command) to toggle the relay.
4. **Voice service** — exposed as `esp.service.voice` in the RainMaker hierarchy (V3-DEVICE-MODEL.md §3.3) with parameters `Wake Word Active`, `Last Intent`, `Last Confidence`.

Voice is **R16-only for V3**. The R4 and R8 lack the microphone hardware (V3-HARDWARE.md §3.6 — rev-e planned for 2025-Q4 adds the mic to R4/R8). Voice is also **off by default** — users opt in via the app (privacy default: no microphone capture until explicitly enabled). When enabled, the wake word is processed locally; no audio is recorded, transmitted, or stored.

**Picovoice economics:** the SDK is **free for up to 100 devices per month** (developer tier). Above 100 devices, Picovoice's commercial pricing is ~$0.50–$2.00 per device per month depending on volume and model complexity (custom Amharic context commands a premium). At our R16 volume forecast (~500 devices in year 1, ~2,000 by year 3), this works out to ~$1,000–$4,000/month at scale — a meaningful but budgetable line item. See V3-UNIT-ECONOMICS.md §6 for the full cost model. The R16 sale price ($120 vs R8's $75) is set partly to absorb this ongoing license cost.

## Alternatives Considered

### Alternative A: Cloud voice (Alexa Voice Service / Google Assistant)
- **Pros:** Best-in-class NLU; massive intent vocabulary; built-in smart-home device types; users already have Alexa/Google devices.
- **Cons:** **Alexa and Google do not support Amharic** (critical for our market); requires always-on internet (Ethiopian connectivity is unreliable); audio leaves the home (violates our privacy posture and PDPP); AVS/Google certification is months of work; per-device platform fees; Alexa SDK is C++ and heavy (~3 MB binary) — does not fit comfortably on ESP32-S3 alongside our relay firmware. **Rejected.**

### Alternative B: On-device TensorFlow Lite Micro (custom wake word + intent model)
- **Pros:** No per-device license fee; full control of the model; can be tuned for Amharic phonemes; open-source (Apache 2.0).
- **Cons:** We would need to train our own wake-word model (weeks of ML engineering, plus data collection for Amharic); TFLite Micro on ESP32-S3 is feasible for a 10–50 KB wake-word model but intent inference at Amharic/English bilingual scale is hard — Picovoice's Rhino ships pre-trained contexts and a model-customization service that would take us months to replicate; accuracy would likely be worse; ongoing maintenance (retraining, false-positive tuning) becomes our problem. **Rejected — we are a hardware/cloud company, not an ML shop.**

### Alternative C: No voice control (app + automations only)
- **Pros:** Zero license cost; zero mic hardware cost; simpler SKU matrix; no privacy surface to manage.
- **Cons:** Loses the "wow feature" that distinguishes R16 from R8 and justifies the $120 price; B2B customers (hotels, offices) specifically ask for voice; older users / non-app-comfortable users have no path to use the system without their phone; competitors who ship voice (even cloud voice) will out-position us. **Rejected for V3; remains an option for a hypothetical future "lite" SKU.**

### Alternative D: Mycroft Mark II / Open Voice OS hardware
- **Pros:** Open-source voice stack; no per-device license.
- **Cons:** Designed for a separate hub device (typically a Raspberry Pi-class machine), not an ESP32-class relay controller; would require a separate hub SKU; defeats the per-device voice integration story; OVOS's Amharic support is community-maintained and not production-grade. **Rejected.**

### Alternative E: Snips (now Sonos One)
- **Pros:** Was the leading offline voice platform; strong NLU.
- **Cons:** Sonos acquired Snips in 2019 and shut down the developer platform — no longer available as a standalone SDK. **Not available.**

## Consequences

### Positive
- Voice works offline — no internet dependency, no latency from cloud round-trips, no audio leaves the home
- Amharic + English bilingual support via custom Picovoice context — competitive moat in the Ethiopian market (no cloud assistant offers Amharic)
- Privacy-preserving: wake-word detection runs in ESP32 SRAM, no audio recorded or transmitted; user must opt in via app
- Picovoice SDK is C-native and small (~150 KB RAM, fits alongside relay firmware on ESP32-S3)
- Voice is exposed as a RainMaker service (`esp.service.voice`) — same device model, same MQTT topics, same dynamic UI as any other device capability
- Competitive differentiation vs Tuya/Sonoff/Shelly (none of which ship offline Amharic voice)

### Negative
- **Per-device license cost above 100 devices** — ~$0.50–$2.00/device/month; at 2k R16 devices that is $1k–$4k/month ongoing; bites into R16 margin
- **R16 only for V3** — R4 and R8 customers cannot buy voice even if they want it (rev-e planned for 2025-Q4)
- **Picovoice is a single-vendor dependency** — if they change pricing, deprecate the SDK, or go out of business, we have a hard migration. Mitigation: the voice surface is isolated to one firmware module behind a clean interface; TFLite Micro (Alternative B) remains a fallback if Picovoice becomes untenable
- **Wake-word accuracy in noisy environments** — Ethiopian homes with TV on, kids playing, or fans running will see false negatives. Mitigation: app lets users tune sensitivity, and the wake word "Hey Sheba" was chosen for phonetic distinctiveness
- **Microphone hardware adds ~$2 to R16 BOM** (INMP441 + I2S routing) — already in V3-HARDWARE.md §7.2 cost model
- **No support for Amharic Natural Language Understanding** — Picovoice Rhino handles fixed-vocabulary intents ("turn on relay 3"), not free-form sentences. Users cannot say "የምትሆነውን ብርሃን አጥፋ" (turn off the light that is on). Mitigation: intent vocabulary covers the 80% case

### Neutral
- Picovoice Console (where wake words and contexts are trained) is a SaaS — model files are downloaded and baked into firmware at build time; no runtime dependency on Picovoice servers
- Voice on R16 creates a small but real privacy surface (a microphone in the home) — covered honestly in V3-DPIA.md and V3-PRIVACY-COMPLIANCE.md with the "off by default" control
- The "Hey Sheba" wake word was chosen for cross-lingual phonetic distinctiveness — it works for Amharic and English speakers alike; a fully-Amharic wake word ("ሰላም ሸባ") was considered but Picovoice's custom-wake-word service works best on Latin-script phonetics
- Picovoice's intent model is fixed-vocabulary, not free-form NLU — users cannot say arbitrary sentences; the SmartHome_Ethiopian context ships with ~25 intents covering the 80% case (turn on/off relay N, status queries, all-off)
- The voice service exposed as `esp.service.voice` in the RainMaker hierarchy (ADR-011) means voice state (wake word active, last intent) is queryable from the app like any other device parameter

## References
- V3-VOICE-MATTER.md §1 (voice integration spec, wake word, intent catalog)
- V3-HARDWARE.md §3.6 (INMP441 microphone on R16) and §9 (rev-e plan to add mic to R4/R8)
- V3-DEVICE-MODEL.md §3.3 (`esp.service.voice` service definition)
- V3-UNIT-ECONOMICS.md §6 (Picovoice license cost in the unit-economics model)
- V3-PRIVACY-COMPLIANCE.md + V3-DPIA.md (microphone as a privacy surface, opt-in default)
- ADR-010 (Ethiopia-only scope — Amharic voice is a local-market feature)
- Picovoice docs: https://picovoice.ai/docs/
