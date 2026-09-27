# SHE V3 — Phase 4 Sign-Off

**Phase 4 status:** ⚠️ IMPLEMENTATION COMPLETE — hardware and human verification outstanding
**Verification date:** 2026-09-27
**Verified by:** Lead Engineer (automated)

---

## 1. Phase 4 exit criteria — verification record

Per `V3-ROADMAP.md` §6, the 4 exit criteria for Phase 4 are:

| # | Criterion (V3-ROADMAP §6) | Automated evidence | Status |
|---|---|---|---|
| 1 | Dark-mode Bento UI shipped + feels premium (internal review ≥ 8/10) | `scripts/verify-phase4.sh` — design tokens present, no forbidden indigo/blue-purple hues, Deep Navy `#0B1D37` + Bright Sky Blue `#56B4FA` present, `she_toggle`/`haptic_slider`/scenes-row widgets present, type-based device rendering | ⚠️ **Partial** |
| 2 | Energy monitoring: real-time + historical in ETB (PZEM accuracy ±1%) | Energy screen exists, uses `fl_chart`, ETB formatter with `ብር` symbol, `/energy` endpoint reachable (401) | ⚠️ **Partial** |
| 3 | Voice control works offline ("Hey Sheba, turn on the light" → relay < 1 s) | Voice screen exists, wake word `Hey Sheba`/`ሰበኣ` referenced, `voice_control.c` exists, Picovoice SDK referenced | ⚠️ **Partial** |
| 4 | Full Amharic UI (100% strings translated + reviewed by native speaker) | `app_en.arb` + `app_am.arb` both present with 125 lines, Amharic ETB symbol present, Ethiopian calendar utility with Amharic + English month names | ⚠️ **Partial** |

**`verify-phase4.sh` result: 22 PASS / 0 FAIL / 0 SKIP.**

---

## 2. What the 22 checks do and do not prove

This section exists because the distinction matters. **Every one of the 22 checks is
structural** — it proves that code, files, tokens and endpoints exist. None of them
exercises the criterion itself.

| Criterion | What IS proven | What is NOT proven |
|---|---|---|
| 1 | The design system and premium widgets are implemented and free of the forbidden hues | That the UI *feels premium* — an internal review scoring ≥ 8/10 is a human judgement and has not been recorded |
| 2 | The dashboard, charting and ETB formatting are implemented and the endpoint responds | **PZEM-004T accuracy of ±1%** — requires a real meter on real mains. Also unproven: that displayed figures match the physical load |
| 3 | The voice screen, wake-word references and firmware hooks exist | **That offline recognition actually works, and that a relay toggles in under 1 s** — requires the device, a microphone and a stopwatch |
| 4 | Both locale files exist at parity (125 lines each) and the ETB/calendar localisation is present | **That translation is complete and correct** — line-count parity is not string parity, and the roadmap explicitly requires review by a native speaker, which has not happened |

Treating 22/0 as "Phase 4 done" would be a mistake. The automated suite is a regression
guard, not an acceptance test.

---

## 3. Outstanding work before Phase 4 can be signed off

| # | Item | Blocked on |
|---|---|---|
| 1 | Internal UI review with a recorded score (≥ 8/10) | A human reviewer |
| 2 | PZEM-004T accuracy measurement against a reference meter | Hardware: ESP32 + PZEM-004T on mains |
| 3 | Voice-control latency measurement (wake word → relay, < 1 s) | Hardware: R16 board + microphone |
| 4 | Native-speaker review of the Amharic strings | A native Amharic speaker |
| 5 | Confirm `app_am.arb` covers every key in `app_en.arb` | Nobody — key-level diff, not line count |

Item 5 is the only one that is purely mechanical and could be closed without hardware.

---

## 4. Environment note

This verification was run on a rebuilt development environment (the project had moved to a
new host and had no working toolchain). The 22 checks passing here means the Phase 4
implementation survived that move intact — several unrelated scripts and launchers did not,
and were repaired first. See `docs/PHASE0-SIGNOFF.md` and the Phase 0 record for the
environment fixes; none of them touched Phase 4 code.

---

## 5. Recommendation

Phase 4 implementation may be considered **frozen** for the purpose of starting Phase 5
planning, but **Phase 4 must not be marked signed off** until items 1–4 above are closed.
The critical path (`V3-ROADMAP.md` §1) runs Phase 4 → Phase 5, and Phase 5 begins with
certification testing that requires physical hardware — which is also what unblocks items
2 and 3. Sequencing the hardware work at the start of Phase 5 closes the gap efficiently.
