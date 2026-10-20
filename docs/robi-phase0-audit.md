# Robi — Phase 0 Audit (Voice Assistant)

**Status:** Phase 0 output. No product code changed.  
**Repo audited:** `D:\project X\she-v3\she-v3` (mobile = Flutter, backend = Spring Boot, firmware = ESP-IDF)  
**Spec:** `docs/voce command.md` (locked)  
**Date:** 2026-10-20

> Everything below was read from the repository. Items that could not be checked are marked
> **NOT VERIFIED** rather than guessed. The test phone was offline during this audit, so
> device-specific claims are open.

---

## 1. Environment

| Item | Actual |
|---|---|
| Flutter | **3.47.5** stable (`C:\ProgramData\flutter`, framework rev `6a19cca`) |
| Dart | **3.13.4** (pubspec allows `>=3.4.0 <4.0.0`) |
| App version | `3.0.0+1`, package `et.she.v3.she_mobile` |
| `compileSdk` / `minSdk` / `targetSdk` | **36 / 24 / 36** (Flutter defaults, no override in `android/app/build.gradle.kts`) |
| Android `MainActivity` | `android/app/src/main/kotlin/et/she/v3/she_mobile/MainActivity.kt` — stock Flutter, **no custom code** |
| Declared `<service>` | **none** — no foreground service, no `TileService` today |
| Speech | `speech_to_text: ^7.0.0`, `permission_handler: ^11.3.1` |
| Localization | `lib/l10n/app_am.arb` + `app_en.arb`, ~250 keys, hand-maintained (`flutter gen-l10n` cannot run in this shell) |
| Custom fonts | **none declared** — Ethiopic renders via the system font (Android's Noto Sans Ethiopic) |

---

## 2. What exists today (voice)

### 2.1 Files

| File | Role | Size |
|---|---|---|
| `lib/features/voice/voice_intent.dart` | **Pure-Dart parser** (no Flutter/plugins/network) — the command brain | 475 lines |
| `lib/features/voice/voice_service.dart` | Recognizer lifecycle, capability probe, intent → API execution | 507 lines |
| `lib/features/voice/voice_screen.dart` | Full-screen voice UI (push-to-talk) | ~540 lines |
| `lib/features/voice/voice_hold_button.dart` | Floating mic FAB used on 3 screens | ~230 lines |
| `test/voice_intent_test.dart` | **23 tests** covering Amharic + English parsing | — |

### 2.2 Entry points (all in-app only)

- Dashboard FAB (`dashboard_screen.dart:222`), Devices FAB (`devices_screen.dart:392`),
  Device-detail FAB (`device_detail_screen.dart:121`) → `VoiceHoldButton` (hold to talk).
- More → Voice → `/voice` (`voice_screen.dart`).

**No cross-app entry point exists.** No Quick Settings tile, no notification action, no
overlay, no wake word, no background service.

### 2.3 Pipeline as implemented

```
hold mic (or /voice screen)
  → permission_handler: microphone
  → SpeechToText.initialize()
  → locales() probe: is there an `am*` locale?
        yes → listen am-ET        no → fall back to `en*`, flag amharicUnsupported
  → listen(listenFor: 12s / 30s, pauseFor: 3s / 30s, partialResults: true)
  → parseVoiceIntent(transcript, devices, scenes, latinDeviceTokens, amharic)
  → VoiceService.handle() → commandQueue.sendOrQueue() | nodeService.setGroup() | sceneService.activate()
  → SnackBar / in-screen message (no TTS)
```

### 2.4 What the parser can do today

**Intents:** `turnOn`, `turnOff`, `turnAllOn`, `turnAllOff`, `activateScene`, `unknown`.

**Matching:** exact → contiguous token-run (0.8+) → substring (0.6) → group noun.
A device match ≥ 0.8 beats a group match, so "turn off Light 1" is not "all lights".
`Light 1` does not match inside `Light 12` (token-boundary check, tested).

**Amharic:** imperative verb tables (`አብር / አብሪ / አብሩ …`, `አጥፋ / አጥፊ …`), "all" words,
light/socket nouns, U+1361 word-space handling, Ethiopic punctuation stripping.

**Confidence:** a score is returned and stored on `VoiceIntent.confidence`, but
**nothing consumes it** — no threshold, no clarification, no ambiguity branch. A weak
match (0.6) executes exactly like a 1.0.

### 2.5 What is missing vs. the spec (the real gap)

| Spec requirement | Reality |
|---|---|
| Clarification state machine (§6.2) | **None.** No states, no timeouts, no re-prompt, no transaction id |
| Cancel / stop / correction / undo (§6.1) | **None** of the six control intents exist |
| Yes/no interpretation (§6.3) | **None** |
| Confidence gating (§6) | Score computed, never used |
| `AmharicTextNormalizer` (§5.3) | Only `_norm()` + `_tokens()` inside the parser; no NFC, no alias table, no tests of its own |
| Device alias repository (§12) | None — matching is against `display_name` / `device_name` at parse time |
| Safety policy / risk categories (§9) | None — every command is equally executable |
| Spoken feedback (§10) | **No TTS at all**; results are text only |
| Wake word (§7) | None |
| Cross-app activation (§8) | None |
| Shared coordinator (§4) | Partially: `VoiceService.handle()` is reusable, but it is bound to a `Ref` and lives inside the voice feature folder |

---

## 3. Hard constraints found in the real system

These change what the spec can promise. They are not opinions; each is a fact in the code.

### 3.1 Only one parameter exists: `Power` (bool)

`firmware/v3/main/device_profiles.c` declares `Power` / `esp.param.power` / `DATA_BOOL`.
`she_mqtt.c` and `input_monitor.c` only accept `Power`. There is **no brightness, no
position, no gate, no irrigation** anywhere in the firmware.

➡ Spec intents `set brightness`, `open/close/stop gate`, `start/stop irrigation` have
**no device capability behind them**. They must be marked unavailable, not "not yet wired".

### 3.2 Rooms attach to NODES, not devices

`Node.roomId` exists; `NodeDevice` has **no** room column. A node is a board
(R24 = 16 lights + 8 sockets) and its channels carry only a name (`Light 1`, `Socket 3`).

➡ "the bedroom light" can only resolve if the *board* is assigned to that room — and one
board can physically serve several rooms. Device-level room resolution does not exist.
`node_groups` (custom device groups) is the only device-granular grouping.

### 3.3 Android target is 36 (Android 16), minSdk 24

- Background microphone start is heavily restricted; a wake-word service would need a
  `microphone` foreground-service type, a visible notification, and a user-initiated start.
- No `<service>` exists today; adding one is native Kotlin work + manifest + a Flutter
  platform channel.
- A Quick Settings tile needs a `TileService` (native) that starts a short-lived capture —
  feasible, but it is new native surface area.

### 3.4 Amharic ASR is a device capability, not a code decision

`voice_service.probe()` asks the OS for locales and only uses `am-ET` if the device lists
one. On the bench phone this has historically **not** been available, so the app falls back
to English and tells the user (`amharicUnsupported`).

➡ Whether Amharic commands work end-to-end is **NOT VERIFIED** until tested with a device
that has an Amharic recognizer installed. The parser itself is Amharic-capable and unit-tested;
the recognizer is the risk.

### 3.5 Recognition may be network-backed

`SpeechListenOptions.onDevice` is deliberately left `false`, and the code documents that
claiming on-device would be false. Google's recognizer streams audio off-device in most
configurations.

➡ Any privacy claim must say "audio may leave the phone". Offline Amharic is not available.

### 3.6 Device confirmation exists and is already used

- Cloud: WS `node.state` events + `nodeDeviceParamsProvider` refetch.
- Local: firmware `GET /she/info` is a valid state oracle (reflects real relay changes).
- `CommandQueue.sendOrQueue()` already reports `queued` vs `sent`.

➡ "Report done only when verified" is achievable with existing signals — no new backend.

---

## 4. Feature-preservation matrix

Must not regress. Each row is verified-by-reading; regression would be caught by the
existing tests or by these entry points.

| Feature | Where | Risk from Robi work | Guard |
|---|---|---|---|
| Hold-to-talk FAB on 3 screens | `voice_hold_button.dart` | Medium — refactor of service API | Keep `VoiceService.startListening/stopListening` signatures until replaced |
| Push-to-talk 30 s pause override | `voice_service.dart:231` | High — a naive "3 s silence" change silently breaks holding | Keep the `pushToTalk` branch; the 2.99 s bug is documented in-code |
| Offline local-first control | `commandQueue.sendOrQueue` | High — voice must not bypass the queue | All execution goes through the queue, never a direct MQTT publish |
| Amharic fallback message | `VoiceAvailability.amharicUnsupported` | Medium | Keep the probe result surfaced in UI |
| `latinDeviceTokens=false` in Amharic mode | `voice_intent.dart` header | **Critical** — flipping this makes any English-sounding utterance fire a device command | Unit tests assert it; do not default it to true |
| "Light 1" ≠ "Light 12" | `_hasTokenRun` | High | Existing test |
| Device-name beats group | parser order | High | Existing test |
| Scene needs an activation verb | parser §2 | Medium | Existing behaviour; keep |
| 23 parser tests | `test/voice_intent_test.dart` | — | Must stay green; extend, never weaken |
| Backend auth/authorization | `SecurityConfig`, `dioProvider` interceptor | Critical | No new unauthenticated endpoints |
| MQTT payload contract | `she_mqtt.c` | Critical | Never publish from the client |

---

## 5. Acceptance items — Phase 0 status

| Item | Status | Evidence |
|---|---|---|
| Existing voice feature audited and preserved | **PASS** | §2, §4 |
| Robi/ሮቢ naming in UI | **FAIL** | No occurrence of "Robi"/"ሮቢ" anywhere in the repo |
| English + Amharic as first-class engine inputs | **PASS (parser)** / **NOT VERIFIED (ASR)** | `voice_intent.dart` tables + 23 tests; device locale support unproven |
| Unicode-safe Amharic normalization + tests | **FAIL** | Only `_norm()`; no NFC, no dedicated tests |
| Reviewed Amharic command corpus | **FAIL** | Tests use ad-hoc phrases, no corpus file, no reviewer sign-off |
| Natural phrasing tolerance | **PARTIAL** | Token-run + substring; no paraphrase table |
| Ambiguity clarified, never guessed | **FAIL** | No clarification; highest score wins silently |
| Stop/cancel/correction/undo | **FAIL** | No control intents |
| Correction invalidates stale target | **FAIL** | No transaction state |
| Explicit clarification state machine | **FAIL** | Absent |
| Yes/no handling (incl. code-switching) | **FAIL** | Absent |
| Stale affirmative cannot authorize | **FAIL** | No transaction id |
| One shared coordinator for all entry points | **PARTIAL** | `VoiceService.handle()` is shared by the 4 in-app entry points |
| Backend auth + MQTT contracts preserved | **PASS** | Unchanged; voice uses existing REST |
| High-risk actions get stronger safeguards | **FAIL** | No risk model (and no high-risk device exists yet) |
| Success reported only on real feedback | **PARTIAL** | Reports queued vs sent; does not wait for state confirmation |
| Cross-app activation | **FAIL** | No tile/notification/service |
| Wake word | **FAIL** | Absent, not evaluated |
| Lock-screen behaviour tested | **NOT VERIFIED** | Device offline |
| Privacy controls / mic indicators | **PARTIAL** | OS indicator only; no Robi opt-in, no disclosure |
| Unit + speech + device tests | **PARTIAL** | 23 parser tests; no speech/device tests |
| Build and tests pass | **NOT VERIFIED** | `flutter test` cannot run in this shell (pipe-busy); needs a PowerShell run |

---

## 6. File-change plan (smallest safe path)

### Phase 1 — Shared command engine (no native code, no new packages)

| Action | File |
|---|---|
| New | `lib/features/voice/nlu/amharic_normalizer.dart` — NFC, Ethiopic punctuation, digit mapping, no destructive transliteration |
| New | `lib/features/voice/nlu/command_nlu.dart` — intent/entity result object (spec §5.4 shape) built from the existing parser |
| New | `lib/features/voice/nlu/alias_repository.dart` — user device/group names + built-in synonyms |
| New | `lib/features/voice/nlu/safety_policy.dart` — confidence thresholds, ambiguity rules, risk category |
| New | `lib/features/voice/nlu/voice_session.dart` — the §6.2 state machine + transaction id + timeouts |
| New | `lib/features/voice/nlu/control_intents.dart` — cancel/stop/correction/reject (§6.1, §6.3) |
| Modify | `voice_intent.dart` — keep the public parser, delegate scoring to the new modules (tests must stay green) |
| Modify | `voice_service.dart` — expose `interpret()` separate from `execute()` so control intents can run before execution |
| Modify | `voice_screen.dart` — render clarification/confirmation instead of a single SnackBar |
| New tests | `test/amharic_normalizer_test.dart`, `test/voice_session_test.dart`, `test/control_intents_test.dart` |
| Corpus | `test/corpus/am_commands.yaml` — canonical + paraphrases + negatives, marked "review required" |

**Out of scope for Phase 1:** native Android, TTS, wake word.

### Phase 2 — Amharic/English quality
Corpus review with a fluent speaker; locale routing; code-switch cases; Ethiopic rendering check on device; TTS evaluation (likely **not** available for Amharic → on-screen text fallback).

### Phase 3 — Cross-app manual entry point
Native `TileService` + notification action + a short foreground capture service, all calling the same `VoiceSession`. Manifest: `FOREGROUND_SERVICE_MICROPHONE`, service declaration. This is the first native Kotlin addition.

### Phase 4 — Wake word
Evaluate an on-device detector (e.g. openWakeWord/Porcupine-class). Requires a trained model for "Hey Robi", a persistent `microphone` FGS, battery measurement, and a false-activation study. **Feasibility on targetSdk 36 is NOT VERIFIED** — do not promise it.

### Phase 5 — Lock-screen + safety verification
Real-device matrix; gate/security commands only if such hardware ever exists.

---

## 7. Open questions (need a decision before Phase 1 code)

1. **Android version of the test phone** — the device was offline during this audit. Needed to
   confirm locale support and FGS restrictions. (Model on record: TECNO LE6.)
2. **Is Amharic ASR actually available on that phone?** If not, Phase 2's "Amharic first-class"
   can only be delivered as text input + English speech, and the spec's success criterion 1
   cannot be met on that hardware. This is the single biggest product risk.
3. **Scope of "supported actions"** — given §3.1, do we accept that Robi covers only
   on/off + scenes + groups, and drop gate/irrigation/brightness from the corpus until the
   hardware exists?
4. **Does Phase 3 native work get approval?** It is the first non-Flutter code in the app.

---

## 8. Bottom line

The project has a **working, tested, in-app voice path** for on/off, group and scene
commands in English and (parser-side) Amharic, routed through the existing authenticated
API with offline queueing. What it does **not** have is everything that makes an assistant
feel trustworthy: confidence gating, clarification, cancel/correct/undo, yes/no handling,
spoken feedback, and any cross-app or wake-word activation.

Phase 1 is pure Dart and testable in this repo without touching Android or the backend.
Phases 3–4 require native Android work and cannot be promised until the target phone is
back online and tested.
