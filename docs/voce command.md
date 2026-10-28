# Smart Home Ethiopia (S.H.E.) — Robi Voice Assistant

**Document type:** Locked implementation specification for the local coding agent  
**Status:** APPROVED PRODUCT DIRECTION — IMPLEMENTATION MUST BEGIN WITH AUDIT  
**Assistant name:** **Robi (ሮቢ)**  
**Product:** Smart Home Ethiopia (S.H.E.)  
**Primary target:** Android phone; Flutter mobile app  
**Languages:** Amharic (`am-ET`) and English (`en`)  
**Existing platform to preserve:** Flutter app → Spring Boot backend → EMQX MQTT → ESP32 devices  
**Document rule:** This is the single source of truth for the Robi voice-assistant work. Do not silently change locked decisions. If a requirement conflicts with current code or an Android platform restriction, document the conflict and propose the smallest safe adjustment before implementation.

---

## 1. Product vision

Robi is the voice assistant inside Smart Home Ethiopia. It should let an authorized user control their home naturally in Amharic or English without having to navigate into the S.H.E. app for every command.

Primary user scenario: the user is playing a game, reading a PDF, browsing, or watching a video. They say **“Hey Robi”** and then a command. S.H.E. identifies the intended action and device, sends the action through the existing authenticated S.H.E. backend, and reports the verified result without unnecessarily interrupting the current app.

Robi must be tolerant of natural wording, word-order differences, missing filler words, and small speech-to-text errors. It must not guess recklessly, control the wrong device, or treat a low-confidence transcript as authorization.

### Success criteria

1. Users can issue supported commands in Amharic and English.
2. Natural variations of the same command map to the same intent when the device is unambiguous.
3. Voice commands use the existing device-control and authorization pathways.
4. A supported external entry point can start voice input without navigating to the S.H.E. screen.
5. True wake-word activation is investigated and implemented only through a technically and legally supported Android architecture.
6. Security-sensitive actions receive stronger safeguards than ordinary light controls.
7. Failures, ambiguity, offline state, and device confirmation are communicated honestly.

## 2. Locked product decisions

- **Assistant name:** Robi.
- **Amharic display spelling:** ሮቢ.
- **Wake phrase to evaluate:** “Hey Robi”; also test “ሄይ ሮቢ” if the selected wake-word engine supports the relevant acoustic model.
- **Languages:** Amharic and English. Mixed Amharic-English commands are a required test case; support depends on the selected speech recognizer and command parser.
- **Client:** Preserve the existing Flutter application and its state-management/navigation choices unless the audit proves a change is necessary.
- **Backend:** Preserve the existing Spring Boot authentication, authorization, device-control APIs, and command flow.
- **Messaging:** Preserve EMQX/MQTT topics, payload contracts, and ESP32 behavior unless an independently reviewed change is required.
- **No replacement rewrite:** Do not replace the backend, database, MQTT broker, provisioning, device models, or authentication as part of this task.
- **Shared command brain:** App microphone, Quick Settings, notification, and any assistant integration must call the same command interpretation and validation layer.
- **No unsupported promises:** Do not claim always-listening, lock-screen operation, offline Amharic recognition, or cross-app operation works until it is tested on the actual target Android device and documented.

“Robi” is the selected product name. It is not being asserted here as a traditional Amharic word with a particular lexical meaning.

---

## 3. Required audit before coding

Inspect the real repository and report findings before changing files. Do not assume package names, plugin versions, Android SDK versions, backend routes, MQTT topics, or current speech-recognition behavior.

Audit and record:

- Flutter/Dart versions, application structure, routing, state management, localization, and dependency versions.
- Existing voice screen, microphone capture, speech-to-text plugin, command matching logic, and all related tests.
- Android `minSdk`, `targetSdk`, compile SDK, manifest permissions, activity configuration, service declarations, notification behavior, and current background restrictions.
- Actual target phone model and Android version where available. Ask the user to supply device details only if they cannot be discovered from the project or test environment.
- Current S.H.E. login/session/token handling and the established device command endpoint or service.
- Existing room/device naming model and supported actions, including lights, dimming, irrigation, garden lighting, and gate controls where implemented.
- Current device-state feedback mechanism and how command success/failure is confirmed.
- Existing English/Amharic localization and fonts; verify Ethiopic script rendering on relevant screens.
- Whether speech recognition runs on-device, uses Android's speech service, or sends audio to a remote provider; identify network, privacy, and language limitations.

Deliver an audit summary, a file-change plan, and a feature-preservation matrix before broad implementation. Keep unrelated UI redesign and other feature work out of scope.

---

## 4. Target architecture

```text
Voice entry point
  ├─ In-app microphone
  ├─ Quick Settings tile / notification action
  ├─ Optional floating control (only if permitted and user-enabled)
  └─ Wake-word listener (“Hey Robi”) if feasible on Android
            ↓
Audio capture and wake-word detection (separate from command recognition)
            ↓
Speech-to-text with language/locale handling
            ↓
Amharic + English text normalization
            ↓
Shared natural-language command engine
  ├─ Intent classification
  ├─ Room/device/action/parameter extraction
  ├─ Alias and synonym resolution
  ├─ Confidence and ambiguity checks
  └─ Safety policy
            ↓
Authenticated S.H.E. command service
            ↓
Existing Spring Boot API and authorization checks
            ↓
Existing EMQX MQTT flow → ESP32 controller
            ↓
Device feedback / authoritative state verification
            ↓
Short visual and/or spoken response
```

Keep these responsibilities separate:

1. **Wake-word detector:** detects the activation phrase only; it does not decide which device to control.
2. **Speech recognizer (ASR/STT):** converts spoken audio into text and provides language/confidence information where available.
3. **Language engine/NLU:** interprets text and resolves intent/entities.
4. **Safety and authorization:** validates whether the user may execute the action and whether confirmation is required.
5. **Command execution:** calls the existing authenticated backend path.
6. **Feedback:** reports verified state, pending state, ambiguity, or failure.

Do not couple command interpretation exclusively to a Flutter screen. Expose it through a reusable service/module so every supported entry point uses the same rules.

---

## 5. Amharic + English language engine

### 5.1 Language support goals

Amharic is a first-class supported language, not merely translated UI labels. The command engine must handle Amharic text in Ethiopic script and English text. Mixed-language utterances should be supported where possible, for example an Amharic sentence containing an English room alias or device label.

Do not assume every speech engine supports Amharic, offline recognition, continuous recognition, or code-switching. Audit actual provider/device support and verify it with real audio. If one engine does not meet requirements, evaluate a modular ASR interface that allows a different recognizer without rewriting the NLU or device-control layer.

### 5.2 Speech recognition selection

Evaluate candidates using a test matrix rather than selecting a library based only on popularity. Record:

- Amharic (`am-ET`) recognition support and actual availability on the target phone.
- English recognition support.
- Code-switching performance.
- Online/offline behavior and what happens with poor connectivity.
- Recognition latency and accuracy in quiet rooms, television/game audio, and ordinary conversation.
- Whether audio is sent off-device, provider retention terms where known, and user-visible consent requirements.
- Compatibility with the project’s Android target SDK and background microphone restrictions.
- Cost, licensing, maintenance status, and supported deployment path.

Keep ASR behind an interface such as `SpeechRecognizerService` so the app can change providers without changing command semantics. Do not hard-code an unverified claim that Amharic works offline.

### 5.3 Amharic text normalization

Implement a testable `AmharicTextNormalizer` plus shared language-neutral cleanup. It should:

- Normalize Unicode consistently (NFC where appropriate).
- Trim leading/trailing whitespace and collapse repeated spaces.
- Remove irrelevant punctuation without deleting meaningful Ethiopic characters or changing the words.
- Handle Ethiopic punctuation and Arabic/Western digits carefully.
- Normalize known spelling/transcription variants only through an explicit, tested alias table.
- Preserve the original transcript for diagnostics while using a normalized copy for matching.
- Avoid destructive transliteration from Ethiopic script to Latin. Transliteration can be an auxiliary matching strategy only if tested; the canonical user-visible text should remain intact.
- Never apply broad character substitutions that can turn one Amharic word into another.

Amharic has meaningful distinctions that generic fuzzy matching can damage. Do not use edit distance alone as the final execution decision.

### 5.4 Intent and entity model

Use a structured internal command representation. Adapt names to the existing codebase, but preserve these concepts:

```json
{
  "language": "am-ET | en | mixed | unknown",
  "intent": "device.turn_on",
  "deviceType": "light",
  "roomId": "resolved-room-id-or-null",
  "deviceId": "resolved-device-id-or-null",
  "parameters": { "brightness": null },
  "confidence": 0.0,
  "requiresConfirmation": false,
  "clarificationReason": null
}
```

This is an illustrative schema, not a mandate to change the backend API. Map the parsed result into the current domain model and existing endpoint. Do not send arbitrary model-generated text directly to MQTT.

The engine must distinguish:

- **Intent:** turn on, turn off, set brightness, open gate, close gate, stop gate, start irrigation, stop irrigation, status query, etc., but only for actions the current system actually supports.
- **Device type:** light, gate, irrigation valve, garden light, appliance, or existing supported type.
- **Location:** room, zone, floor, or group.
- **Target:** the specific authorized device or explicit group.
- **Parameter:** brightness percentage or other supported values, with bounds validation.

Resolve aliases using the user’s actual configured device names first, then built-in synonyms. Do not invent a device when no matching device exists.

### 5.5 Natural phrasing and error tolerance

The same intent should be recognized across normal variations, such as:

- “Turn on the bedroom light.”
- “Bedroom light on.”
- “Switch the bedroom light on.”
- “Can you turn on the bedroom light?”
- The equivalent supported Amharic commands using different natural word order or polite filler words.
- Common ASR omissions or small transcription errors, when the intended device/action remains unambiguous.

Build an explicit, version-controlled alias/synonym set for actions, room labels, device labels, and common Amharic/English variants. Use intent/entity matching plus confidence scoring. Do not require exact full-sentence equality. Do not let a loose fuzzy match execute if it changes the action, room, device, or safety meaning.

### 5.6 Amharic command corpus

Create a small, editable test corpus owned by the project. For every supported action, include:

- Canonical Amharic phrase reviewed by a fluent Amharic speaker.
- At least two natural paraphrases where appropriate.
- English equivalents.
- Mixed-language examples where relevant.
- Expected intent, room/device, parameters, confidence expectation, and safety category.
- Negative examples that should not execute.

Do not present machine-generated Amharic examples as linguistically approved without review. Keep user-configured room/device names configurable rather than relying on hard-coded Ethiopian room names.

### 5.7 Example commands

Use these as test intents; have a fluent Amharic speaker review exact Amharic phrasing before treating it as canonical:

| Intent | English example | Amharic test phrase (review required) |
|---|---|---|
| Turn on light | “Turn on the bedroom light.” | “የመኝታ ቤቱን መብራት አብራ።” |
| Turn off light | “Turn off the bedroom light.” | “የመኝታ ቤቱን መብራት አጥፋ።” |
| Set brightness | “Set the living room light to 40 percent.” | Have a fluent speaker create and approve the natural equivalent. |
| Gate action | “Open the main gate.” | Have a fluent speaker create and approve the natural equivalent; stricter confirmation is mandatory. |
| Status | “Is the bedroom light on?” | Have a fluent speaker create and approve the natural equivalent. |

Do not ship unreviewed example translations as the only language grammar.

---

## 6. Confidence, clarification, and execution rules

Confidence thresholds must be configurable and calibrated from the test corpus, not chosen arbitrarily and treated as proven. Use separate confidence signals where available: ASR confidence, intent confidence, entity/device match confidence, and safety policy.

Recommended initial behavior (tune after testing):

- **High confidence + one exact authorized target + low-risk action:** execute and verify.
- **Medium confidence or one missing entity:** ask a concise clarification, such as “Which room?” or “Did you mean the bedroom light?”
- **Multiple possible targets:** never choose silently; ask the user to select.
- **Low confidence, unknown command, or contradictory entities:** do not execute; explain that Robi did not understand.
- **High-risk action:** require the configured confirmation flow regardless of linguistic confidence.

Do not automatically convert “open” into “close,” “on” into “off,” or one room into another because a fuzzy score is close. If the device/action is uncertain, clarification is the correct result.

### 6.1 Cancellation, stop, correction, and undo commands (required)

Cancellation and correction are first-class intents. They must be processed before ordinary device-command interpretation whenever a voice session, pending clarification, confirmation, or cancellable command exists. A cancellation utterance must never accidentally be interpreted as a device action.

Implement at least these control intents:

- `assistant.cancel_current`: cancel the current voice capture, clarification, or confirmation prompt.
- `command.cancel_pending`: cancel a command that has not yet been submitted to the backend.
- `command.stop_action`: request a supported stop action for an actuator that is currently moving/running (for example, stop a gate or stop irrigation), using the existing device capability and safety rules. “Stop” must be resolved from context; it must not indiscriminately stop all devices.
- `command.correct_target`: revise a previously resolved room/device after a correction such as “No, the other room.” Re-resolve the target and confirm if still ambiguous; do not execute the earlier target after a correction invalidates it.
- `command.undo_last`: attempt a compensating action for the most recent eligible, successfully confirmed action, only if the current device state and action semantics make that safe. This is not a promise of universal undo.
- `command.reject_confirmation`: treat a negative answer to a confirmation as rejection/cancellation, not as permission to execute.

English phrases to recognize contextually include “stop,” “cancel,” “never mind,” “forget it,” “no,” “no, the other room,” “not that one,” “I meant the bedroom,” “change it to the living room,” “undo,” and “undo that.” Add appropriate Amharic equivalents to the reviewed language corpus. Candidate Amharic examples for fluent-speaker review include “ተወው” (leave it/stop it, context-dependent), “ሰርዝ” (cancel/delete, context-dependent), “አይ” (no), “አይ፣ ሌላው ክፍል” (no, the other room), and “መልስ” only if a fluent reviewer confirms it naturally expresses the intended undo command. Do not assume one Amharic phrase covers every cancellation/undo context; have a fluent Amharic speaker approve the canonical phrases and add common variants.

Rules:

1. **Stop/cancel during listening:** immediately stop the current capture/session where technically possible, discard the unfinished transcript, and do not submit a device action.
2. **Cancel during clarification or confirmation:** clear the pending target/action and end the current command transaction without execution.
3. **Correction before execution:** replace only the corrected field (for example, room) while preserving the intended action if it remains unambiguous. Re-run all target, confidence, authorization, and safety checks. Never execute the stale target.
4. **Correction after execution:** explain that the action already ran. Do not pretend it was cancelled. Offer a safe new command or an eligible compensating action.
5. **Stop an active actuator:** map “stop” to the device-specific stop intent only when a supported active operation is known or clearly identified. If more than one operation could be stopped, ask which one.
6. **Undo:** keep a bounded record of the last eligible action and its result, without storing audio. Undo must be state-aware, authorized, and idempotency-safe where supported. Never claim a physical action was undone until the resulting state is verified. Do not automatically reverse gate/security actions, irrigation schedules, or other actions where reversal could be unsafe; require a fresh explicit command/confirmation or decline undo.
7. **Control intents take precedence:** “no” during a confirmation means reject; “no, the other room” during target resolution means correction; “stop” during a running gate operation may mean stop the gate. Use conversation state and entity extraction to disambiguate. If the meaning is unclear, ask a short clarification rather than guessing.

### 6.2 Clarification and confirmation state machine (required)

Implement clarification as an explicit state machine, not an informal series of prompts. Persist state only for the duration necessary to resolve the current command and use a unique session/transaction identifier so stale replies cannot affect a newer command.

Required states:

- `idle`
- `listening_for_command`
- `interpreting`
- `awaiting_room_clarification`
- `awaiting_device_clarification`
- `awaiting_action_clarification`
- `awaiting_yes_no_confirmation`
- `submitting`
- `awaiting_device_result`
- `completed`
- `cancelled`
- `timed_out`
- `failed`

Recommended initial timeout policy (configurable and verified through user testing):

- After wake-word detection, allow up to **8 seconds of silence** for the command to begin; then end the session without executing anything.
- After the recognizer detects speech, use its supported end-of-utterance signal; impose a **12-second maximum utterance window** to avoid hanging indefinitely.
- Each clarification/yes-no prompt waits **10 seconds** for a response.
- If there is no usable response, repeat the prompt **once** and wait another **10 seconds**.
- Allow no more than **2 clarification attempts per unresolved field** (initial prompt plus at most one re-prompt). After the limit, cancel the pending command and say/display that the request was cancelled because the target was not resolved.
- Limit a command transaction to **3 clarification turns total**. If it still cannot be resolved, cancel rather than loop forever.
- On timeout, wake-word session end, app/service shutdown, or explicit cancel, clear pending state and ensure no deferred action is submitted later.
- Reset the timeout only when a valid response is received; background noise or an unrecognized partial transcript must not keep a clarification open indefinitely.
- A new wake phrase starts a new transaction. It must not inherit unresolved entities or confirmations from a stale transaction.

### 6.3 English and Amharic yes/no interpretation (required)

Use a locale-aware, context-aware answer classifier for `yes`, `no`, `cancel`, and corrections. Do not rely only on a generic substring check. Normalize punctuation/spacing, preserve the original utterance, and evaluate the entire short answer in the current dialogue state.

English affirmative examples: “yes,” “yes please,” “yeah,” “yep,” “correct,” “that’s right,” “okay,” and “OK.” These are valid only when the current prompt expects confirmation; “okay” in an unrelated sentence is not automatically confirmation.

English negative/cancel examples: “no,” “nope,” “not that,” “cancel,” “stop,” and “never mind.” Distinguish a plain rejection from a correction that supplies a new target, e.g. “No, the other room.”

Amharic candidate affirmative forms for fluent-speaker review include “አዎ” and “እሺ”; candidate negative forms include “አይ” and “አይደለም”. These can vary with context and natural phrasing, so have a fluent Amharic speaker approve the supported variants and test actual speech recognition. Add code-switched examples such as an Amharic yes/no response to an English prompt and vice versa. Do not treat the presence of “አይ” anywhere in a longer utterance as an automatic rejection if the utterance actually contains a correction or a different request.

Confirmation behavior:

- For a prompt such as “Do you mean the bedroom light?”, affirmative response confirms the proposed interpretation, subject to normal authorization and safety checks.
- A negative response cancels that proposed interpretation unless it also provides a replacement target/action. If it provides a correction, update the relevant field and resolve again.
- For high-risk actions, a valid affirmative response must be tied to the exact pending action, target, and transaction ID. A stale “yes” from a previous prompt must never authorize a new action.
- If the answer is unrecognized or ambiguous, re-prompt once with a simpler bilingual/localized question, then time out and cancel.
- Show the current interpretation in the UI/notification where supported so the user can correct it without needing to remember the entire previous utterance.

### 6.4 Required dialogue examples

The following are behavior examples, not claims that all Amharic phrases are already linguistically validated:

**English — target correction**

1. User: “Turn on the bedroom light.”
2. Robi: “I found two bedrooms. Which one?”
3. User: “No, the other room.”
4. Robi: resolve the alternative only if it maps uniquely; otherwise ask for the room name. Do not execute the first target.

**Amharic — yes/no confirmation**

1. Robi asks a localized confirmation question.
2. User answers “አዎ” or “እሺ”.
3. Robi confirms only the action tied to the current pending transaction, then applies the normal safety and authorization checks.

If the user answers “አይ” or “አይደለም”, reject the proposed interpretation. If the user names another room/device in the same utterance, treat it as a correction and re-resolve.

**Cancel and undo**

- User: “Cancel.” while Robi is asking which room → clear the pending command and do not execute.
- User: “Stop.” while an identified supported gate operation is in progress → invoke the existing safe stop capability, then report the verified result.
- User: “Undo that.” after a confirmed light-on action → if the action is still eligible and the current state is known, request the compensating light-off action and verify it. If not eligible or state is unknown, explain that undo cannot be safely completed and ask what the user wants to do next.

---

## 7. Wake phrase and activation experience

### Locked name

- Display name: **Robi**
- Amharic display: **ሮቢ**
- Primary wake phrase candidate: **“Hey Robi”**
- Optional Amharic-sounding wake phrase candidate: **“ሄይ ሮቢ”**, only if supported and validated by the chosen detector.

The wake-word engine is separate from speech-to-text. Do not implement always-listening by continuously streaming raw audio to a cloud speech recognizer. Prefer a suitable on-device wake-word detector where practical, with clear privacy disclosure and a deliberate user opt-in.

A wake-word model may need training or adaptation for the chosen pronunciation, accent, microphone, and noise conditions. Do not assume a generic keyword library supports a custom phrase out of the box. Record the selected engine, licensing, model source, device compatibility, and measured results.

### Activation UX

- User explicitly enables Robi hands-free listening in settings.
- Show a clear listening/active state and explain battery/privacy implications.
- Provide a reliable way to pause/disable listening.
- Do not record or retain continuous audio unnecessarily.
- After wake detection, capture one command, stop capture, and process it.
- Use a short timeout and cancel on silence or user cancellation.
- Prevent the assistant’s own spoken response from triggering another activation loop.
- Do not let ordinary game audio or speech commonly activate the assistant; measure false activations.

---

## 8. Using Robi while another app is open

The core cross-app requirement is to issue a voice command while a game, PDF reader, browser, or video app remains in the foreground.

Implement these options in priority order, based on the Android audit:

1. **Quick Settings tile or notification action:** user taps a system entry point to start a voice session without opening/navigating through the S.H.E. screen.
2. **Persistent user-enabled wake-word listening:** investigate an on-device wake-word detector and the correct foreground-service architecture for the actual Android version/target SDK.
3. **Optional floating control:** only if technically permitted, accessible, secure, and genuinely useful; request any overlay permission transparently. Do not make it the only solution.
4. **System assistant integration:** evaluate supported Android/Google Assistant integration if it is available and appropriate for the app’s distribution path. Do not assume App Actions or third-party assistant hooks are universally available.

A Quick Settings tile is a manual activation path, not hands-free wake-word detection. Make this distinction clear in the UI and documentation.

### Background and lock-screen constraints

Android versions and target SDKs impose restrictions on starting microphone foreground services from the background. The agent must inspect the actual Android version and official requirements before implementing a service.

- Declare only required permissions and service types.
- Start microphone capture from an allowed user-visible path where required.
- Show the required foreground notification and microphone privacy indicators.
- Handle permission denial, service termination, app force-stop, battery optimization, microphone conflicts, Do Not Disturb, and reboot.
- Do not promise listening after force-stop or reboot unless a supported design has been proven.
- Do not attempt to bypass Android privacy/security restrictions.
- Test screen-locked operation separately from cross-app operation.
- If reliable always-listening is not possible on the target phone, deliver the best supported Quick Settings/notification path and document the limitation honestly.

---

## 9. Backend, MQTT, and device safety

Robi is a new command input, not a new authorization system.

- All device actions must use the existing authenticated S.H.E. command pathway.
- Enforce user permissions on the backend; Flutter checks are not sufficient.
- Never embed backend secrets, MQTT credentials, or privileged tokens in the client.
- Never let a wake-word event or transcript publish arbitrary MQTT payloads.
- Validate the resolved device ID, supported action, parameters, ownership, and current device capability before execution.
- Use the existing request/idempotency mechanism if present; do not invent a new backend contract without review.
- Keep command state distinct: `recognized`, `interpreted`, `submitted`, `acknowledged`, `confirmed`, `failed`, or `unknown` as appropriate to existing models.
- Report “done” only when the system’s established feedback confirms the result. If command delivery succeeds but the device state is not verified, say that the command was sent but confirmation is unavailable.
- Respect offline, queued, timeout, and conflict behavior already supported by S.H.E.

### Risk categories

- **Low risk:** ordinary light on/off; may execute when the target is unambiguous and confidence is high.
- **Medium risk:** brightness, irrigation, or grouped actions; validate parameters and target scope.
- **High risk:** opening/closing a main gate, unlocking, or other security-sensitive actuator; require a deliberate confirmation step or existing approved safety mechanism. Never execute these solely because a noisy transcript approximately matched.

“Turn off all lights” must resolve only to the user’s authorized light devices, not all device types. Broad group commands must make their scope clear when necessary.

---

## 10. Spoken and visual feedback

Robi should keep responses brief so it does not interrupt games or reading.

Examples:

- Success after verified state: “Bedroom light is on.” / Amharic response approved by a fluent speaker.
- Ambiguous target: “Which room’s light?”
- Low confidence: “I didn’t understand. Please repeat the command.”
- Offline: “S.H.E. is offline. I couldn’t confirm the command.”
- High-risk action: ask for confirmation before submission.

Evaluate text-to-speech separately for Amharic and English. Verify that the selected TTS engine actually supports Amharic pronunciation on the target device. If it does not, provide localized on-screen text and an accessible fallback instead of promising Amharic speech output. Avoid reading long explanations aloud.

Provide an accessible visual result via a notification or lightweight overlay where supported. Do not steal focus from the active game/PDF unnecessarily. Respect the user’s sound/voice-feedback preferences.

---

## 11. Privacy and user controls

- Hands-free listening must be opt-in and easy to turn off.
- Explain whether wake detection is on-device and whether command audio leaves the phone.
- Minimize audio capture to the activation/command window.
- Do not retain raw audio by default.
- Logs may include normalized transcript, parsed intent, confidence, result, and timestamps only where necessary; avoid secrets and unnecessary personal content.
- Allow the user to disable voice history/logging where compatible with the product’s diagnostics policy.
- Handle Android microphone permission denial without breaking manual app controls.
- Use clear microphone/listening indicators and follow OS privacy indicators.

---

## 12. Suggested code boundaries

Adapt names to the repository conventions after audit. Do not create duplicate services if equivalent modules already exist.

- `WakeWordService`: wake detector lifecycle, start/stop, detection events.
- `SpeechRecognizerService`: ASR provider interface, locale selection, partial/final transcripts, error handling.
- `AmharicTextNormalizer`: safe Ethiopic Unicode and punctuation normalization.
- `CommandNormalizer`: language-neutral normalization.
- `CommandNluService`: intent/entity extraction and confidence result.
- `DeviceAliasRepository`: configured room/device names, aliases, supported actions.
- `CommandSafetyPolicy`: ambiguity, confidence thresholds, confirmation requirements.
- `VoiceCommandCoordinator`: orchestrates capture → transcript → interpretation → validation → existing command service.
- `VoiceFeedbackService`: notification, concise visual response, supported TTS.
- `AndroidVoiceEntryPoints`: Quick Settings/notification integration and any permitted foreground service.

Keep platform-specific Android code behind a small boundary such as a Flutter platform channel or plugin. Do not put Android service lifecycle logic inside the NLU engine.

---

## 13. Testing requirements

### Unit tests

- Unicode normalization of Ethiopic text and punctuation.
- Whitespace, punctuation, and harmless filler-word handling.
- Alias/synonym resolution for Amharic and English.
- Room/device resolution, including duplicate names.
- Intent extraction and parameter bounds.
- Common speech-to-text omissions and substitutions.
- Mixed-language utterances.
- Ambiguous or unknown device, action, and room.
- Low-confidence and contradictory transcripts.
- High-risk action confirmation.
- Authorization denial and unsupported device actions.
- Feedback states when the device is offline or state confirmation is missing.
- Cancel/stop intent precedence during listening, clarification, confirmation, and active supported actuator operation.
- Corrections such as “no, the other room” must invalidate the old target and never execute it.
- Undo behavior for eligible, ineligible, stale, and unverified prior actions.
- Clarification timeout, single re-prompt, retry limits, transaction expiry, and stale reply rejection.
- English affirmative/negative variants and Amharic yes/no variants reviewed by a fluent speaker.
- Code-switched yes/no answers, correction-with-negative answers, and unrecognized confirmation responses.

### Speech evaluation

Build a labeled set of real Amharic and English recordings with consent. Include different speakers, speaking speeds, accents, microphone distances, and quiet/noisy conditions. Evaluate ASR transcript accuracy separately from command-intent accuracy. A correct intent with a different transcript may still be acceptable; a wrong device/action is not.

Report:

- Command intent accuracy.
- Exact device/room resolution accuracy.
- False acceptance rate for unsafe/wrong commands.
- False rejection rate for valid commands.
- Wake-word false activations per test duration.
- Wake-word miss rate.
- End-to-end latency.
- Battery impact during enabled listening.

Do not invent performance percentages. Establish a baseline, then set release thresholds from observed results and product risk.

### Device and Android integration tests

Test on the actual target phone and Android version:

- S.H.E. foreground.
- Another app foreground: game, PDF reader, browser, video.
- Game/video audio playing.
- Screen locked after a supported voice session is started.
- Microphone permission denied/revoked.
- Quick Settings and notification activation.
- Battery saver and manufacturer battery optimization.
- Incoming call or another app using the microphone.
- Network lost/restored; backend unavailable; MQTT/device offline.
- App process killed, force-stopped, and device rebooted.
- Spoken feedback not causing a wake loop.

Document which scenarios are supported, unsupported by Android, or not yet verified.

---

## 14. Implementation phases and required outputs

### Phase 0 — Audit and feasibility

Output: current implementation map, device/Android details, speech engine support matrix, background-microphone feasibility note, and file-change plan. No broad code changes before this output.

### Phase 1 — Shared command engine

Implement normalization, aliases, intent/entity resolution, confidence handling, clarification, and unit tests. Keep the existing in-app voice entry point working.

### Phase 2 — Amharic/English quality

Add the reviewed Amharic corpus, language/locale routing, code-switching tests, and actual speech evaluations. Verify Ethiopic UI rendering and supported TTS. Keep all translations reviewable.

### Phase 3 — Cross-app manual entry point

Implement a Quick Settings tile or notification action using the same voice coordinator. Demonstrate that the user can initiate a command without navigating into the S.H.E. screen.

### Phase 4 — Robi wake word

Evaluate and implement the selected wake-word detector only if it supports the target device and Android restrictions. Add explicit opt-in, privacy disclosure, service lifecycle, listening indicator, battery measurement, and false-activation tests. If not feasible, document the reason and retain Phase 3 as the supported alternative.

### Phase 5 — Lock-screen and safety verification

Test screen-locked behavior, security-sensitive confirmation, authorization, offline states, and actual device feedback. Do not mark the feature complete on simulator-only evidence.

### Final delivery package

- Audit and architecture summary.
- List of files changed and why.
- Implemented shared command engine and language corpus.
- Speech/wake-word provider and licensing/configuration notes.
- Android permissions/services/entry points added.
- Automated test results and actual device test matrix.
- Known limitations and reproduction steps.
- Build/test commands and results.
- No claim of completion for a feature that was not tested.

---

## 15. Definition of done

- [ ] Existing app voice feature has been audited and preserved until replacement behavior is proven.
- [ ] Robi / ሮቢ is the assistant name in relevant UI and documentation.
- [ ] English and Amharic are first-class command-engine inputs.
- [ ] Amharic text normalization is Unicode-safe and covered by tests.
- [ ] A reviewed Amharic command corpus exists for each supported action.
- [ ] Natural phrasing and small ASR mistakes are tolerated when intent and target remain unambiguous.
- [ ] Ambiguous/low-confidence commands are clarified rather than guessed.
- [ ] “Stop”, “cancel”, “no, the other room”, and “undo” are implemented as context-aware control intents.
- [ ] Corrections invalidate stale targets and re-run validation before any execution.
- [ ] Clarification/confirmation has explicit states, timeouts, retry limits, and transaction expiry.
- [ ] English and reviewed Amharic yes/no answers are handled in context, including code-switching.
- [ ] Stale affirmative responses cannot authorize a newer or different command.
- [ ] All entry points call one shared command coordinator.
- [ ] Existing Spring Boot authentication/authorization and MQTT/device contracts are preserved.
- [ ] Security-sensitive commands require stronger safeguards.
- [ ] Success is reported only according to actual backend/device feedback.
- [ ] A cross-app activation method is implemented and tested.
- [ ] Wake-word listening is either implemented with evidence or explicitly documented as not feasible on the target configuration.
- [ ] Lock-screen behavior is tested separately and its limits are documented.
- [ ] Privacy controls, microphone indicators, permission handling, and battery behavior are tested.
- [ ] Unit tests, speech evaluation results, and real-device integration results are included.
- [ ] Build and tests pass, or remaining failures are clearly reported with logs and causes.

## 16. Final instruction to the local coding agent

Treat this document as locked scope. Start with Phase 0. Do not skip the audit, do not rewrite unrelated parts of S.H.E., and do not invent APIs or Android capabilities. Preserve the current architecture and use the smallest safe changes that meet the requirements. If a requirement cannot be met on the target Android version, explain the exact platform limitation and deliver the best supported fallback. Mark each acceptance item as **PASS**, **FAIL**, or **NOT VERIFIED** with evidence.
