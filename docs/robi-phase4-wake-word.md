# Robi — Phase 4: Wake word ("Hey Robi") — evaluation + plan

**Status:** evaluation done, Stage 1 (native plumbing) implemented. Detection is **not verified on the device**.
**Spec:** `docs/voce command.md` §7 (wake phrase), §8 (background constraints), §14 Phase 4.

> Read this before enabling anything: **no offline engine supports the Amharic wake phrase "ሄይ ሮቢ".** Every candidate below is English-only. Amharic wake detection would need a custom-trained acoustic model, which is a research task, not a configuration change.

---

## 1. What "wake word" actually requires on Android 16 (targetSdk 36)

Four separate things, and the first is the one that kills most implementations:

1. **A foreground service with `foregroundServiceType="microphone"`**, started from a visible activity, with a persistent notification. Starting it from the background throws.
2. **`RECORD_AUDIO`** (already declared) and **`POST_NOTIFICATIONS`** (Android 13+) for the notification.
3. **A continuous `AudioRecord` loop** — 16 kHz mono 16-bit is the standard for keyword engines.
4. **An on-device detector.** No cloud ASR: the spec forbids streaming raw audio continuously.

Hard limits we must state in the UI, not hide:
- **Force-stop kills it** and it does not come back until the user opens the app again. Android gives no supported way around this.
- **Doze / manufacturer battery managers** (TECNO's is aggressive) will suspend it. It needs an exemption request.
- The microphone is **exclusive**: a call, a voice memo, or another assistant will take it and we must release it.
- Battery: continuous mic + inference is the single largest battery cost in the app.

---

## 2. Engine comparison

| Engine | Licence | "Hey Robi" possible? | Model size | Account/key needed | Notes |
|---|---|---|---|---|---|
| **Vosk** (`vosk-android`) | Apache-2.0 | **Yes** — grammar-restricted recognition (`["hey robi","[unk]"]`) | ~40 MB (small en-us) | **No** | Not a purpose-built KWS: it runs full ASR with a tiny grammar. Higher CPU than a KWS engine, but no training and no vendor account. |
| **Porcupine** (Picovoice) | Commercial, free tier | Yes — custom keyword, but must be created in their console and exported as `.ppn` | ~1 MB | **Yes** (AccessKey + console) | Best CPU/battery and the cleanest API (`PorcupineManager`). Blocked on an account and a per-keyword model. |
| **sherpa-onnx KWS** | Apache-2.0 | Yes — text keywords + BPE model | ~15 MB | No | Purpose-built KWS, efficient. More integration work (feature extraction, model files, AAR). |
| **openWakeWord** | Apache-2.0 | Only with a trained model | ~5 MB + model | No | Needs ONNX Runtime **and** a model trained on the phrase — training is a separate project. |

### Decision

**Vosk for Stage 2**, because it is the only candidate that needs **no third-party account, no key, and no model training** — the user can enable it and it works. The cost is CPU (full ASR with a 2-word grammar) and a 40 MB model.

If battery proves unacceptable on the LE6, the migration path is sherpa-onnx KWS behind the same `RobiWakeService` interface — the Dart side does not change.

**Not chosen:** Porcupine (account + console step, and a licence to reason about for a shipped product), openWakeWord (needs model training).

---

## 3. Architecture

```
Settings toggle (opt-in, default OFF)
        │  MethodChannel she/robi → start()
        ▼
RobiWakeService (foreground, type=microphone, persistent notification)
        │  AudioRecord 16 kHz mono PCM
        ▼
Vosk Recognizer, grammar ["hey robi", "[unk]"]   ← detector only
        │  on match: pause the recognizer, emit event
        ▼
EventChannel she/robi/events → "hey_robi"
        ▼
Existing VoiceSession (the SAME brain as the mic button)
```

The detector decides **nothing** about devices — it only reports "the phrase was said". Command interpretation stays in the Phase 1 engine, which is the spec's §4 requirement.

---

## 4. Staged delivery (each stage is one build)

| Stage | Content | How to verify |
|---|---|---|
| **1 (done)** | Gradle dep, manifest service + permissions, `RobiWakeService` lifecycle, MethodChannel/EventChannel, Settings toggle with privacy copy | Build, enable the toggle → notification appears, toggle survives reopening. No detection yet: the service reports `model_missing` and stops. |
| **2** | Vosk model in `assets/vosk/model` + recognizer loop | Speak "hey Robi" → the UI shows a detected event |
| **3** | Wire the event into `VoiceSession` (open the voice screen or start capture) | Say "Hey Robi" → say "turn on light 1" → light toggles |
| **4** | Battery + false-activation measurement, Doze exemption request | Numbers, not claims |

**Stage 1 deliberately ships without the 40 MB model** so the build proves the risky platform parts (FGS type, notification, permission, lifecycle) before adding a large binary. The toggle says the model is missing rather than pretending to listen.

---

## 5. What Stage 1 does NOT prove

- That Vosk detects "hey robi" reliably in a room with a TV or a game playing.
- Battery impact.
- That TECNO's battery manager lets the service survive.
- Anything about Amharic.

Those need the physical device, and I will not report them as working until measured.

---

## 6. Privacy (must be shown before enabling)

- The detector runs **on the device**; audio is not uploaded.
- Audio is analysed in memory only and **never stored**.
- The mic indicator is always visible (Android requirement) plus our own persistent notification.
- The toggle is one tap off, and turning it off releases the microphone immediately.
