# Robi — Complete Voice Command Reference

Everything Robi understands today, in one place. Commands are **case-insensitive**
and punctuation-insensitive ("Light 1." == "light 1").

---

## 0. Before you speak — the two things that matter

### a) Wake Robi
- Say **"Hey Robi"** (also accepted: "hey roby", "hey robby", "hi robi").
- This only works when **Settings → Robi → main switch ON _and_ "Continuous 'Hey Robi'" ON**.
  The main switch alone only adds a tappable notification (it does **not** listen).
- You can also **tap the Robi notification**, or the in-app mic button, without saying "Hey Robi".

### b) Speak the SAME language the app is set to  ⚠️ most common cause of "didn't understand"
- The app **defaults to Amharic** and then asks the recognizer for **am-ET**.
- If you speak **English**, switch the app to English first:
  **Settings → Language → English**. (It is saved; the recognizer re-reads it the
  next time the voice screen opens.)
- If you speak **Amharic**, leave it on Amharic.
- Device names are **English** ("Socket 1", "Light 1"), so English is the most
  reliable way to target a single device today.

---

## 1. Turn a SINGLE device on / off

Pattern: `<verb> <device>` — the device name may be a digit or a number word.

| English | Also works |
|---|---|
| turn on socket 1 | turn on socket one / socket 1 on / socket one on |
| turn off socket 2 | turn off socket two / socket 2 off |
| turn on light 1 | turn on light one / light 1 on |
| turn off light 12 | turn off light twelve |

Verbs understood (any of these, in any position — matching is on whole words):
- **ON**: on, turn on, switch on, power on, put on, open, enable, start,
  activate, begin, resume, boot, fire up, light up
- **OFF**: off, turn off, switch off, power off, shut off, shut down, cut off,
  close, disable, stop, shut, end, pause, deactivate

Examples: "switch on socket 1" · "socket 2 off" · "power off light 2" ·
"start socket 1" · "shut down socket 1" · "fire up the living room"

### Multiple devices at once

Separators understood: `and`, `,`, `&`, `plus`, and Amharic `እና`. A bare trailing
number inherits the noun from the device before it, so "socket 1 **and 2**" means
Socket 2. Devices that do not exist are simply skipped.

| English | Amharic |
|---|---|
| turn on socket 1 and 2 | ሶኬት አንድ እና ሁለት ክፈት |
| turn on socket 1 and light 2 | ሶኬት አንድ እና መብራት ሁለት ክፈት |
| turn off socket 1, socket 2 and light 3 | ሶኬት አንድ፣ ሶኬት ሁለት እና መብራት ሶስት አጥፋ |

## 3. Ask about state (nothing changes)

Robi answers instead of acting. A question is detected **before** any verb, so the
"on" in "is socket 1 on?" is never read as a command.

| English | Amharic |
|---|---|
| is socket 1 on? | ሶኬት አንድ ክፈት ነው? |
| is light 2 off? | |
| which lights are on? | |
| whats on? | |

Answers read like "Socket 1 is on.", "All lights are off." or
"On: Socket 1, Light 2. Off: Light 3." — built from the live device state, so it
works offline too (via the board's `/she/info`). A question that is not about
power state ("what is the weather") is not swallowed — it falls through to the
normal path.

## 4. Brightness

| English | Result |
|---|---|
| dim light 1 | 30% |
| brighten light 2 | 70% |
| set light 1 to 50 percent | 50% |
| dim light 1 and light 2 | both at 30% |

A bare number is never read as a level — "dim light 1" means 30%, not 1%.

Amharic verbs (use with the Amharic noun, e.g. "ሶኬት አንድ ክፈት"):
- **ON**: አብር, አብሪ, አብሩ, አብሪው, ክፈት, ክፈቱ, አስጀምር, አብራ, ላይ አድርግ
- **OFF**: አጥፋ, አጥፊ, አጥፉ, አጥፊው, ዝጋ, ዝጉ, አቁም, አቁሚ, አጥበው

> ✅ **Amharic single-device works:** "ሶኬት አንድ ክፈት" targets Socket 1 and
> "መብራት ሁለት አጥፋ" targets Light 2. Amharic nouns (ሶኬት/መብራት/…) and numbers
> (አንድ…አስር, አስራ አንድ…አስራ ስድስት) are mapped to the English device names
> automatically.

---

## 2. Turn a whole CLASS on / off

| English | Amharic |
|---|---|
| turn on all lights / turn on the lights | ሁሉም መብራት አብር |
| turn off all lights | ሁሉም መብራት አጥፋ |
| turn on all sockets / turn on the sockets | ሁሉም ሶኬት ክፈት |
| turn off all sockets | ሁሉም ሶኬት አጥፋ |
| turn on everything | ሁሉንም አብር |
| turn off everything / turn off all | ሁሉንም አጥፋ |

Group nouns recognised:
- lights: light, lamp · Amharic መብራት, መብራቶች, ብርሃን, ብርሃኖች, ላምፕ
- sockets: socket, outlet, plug · Amharic ሶኬት, ሶኬቶች, መዘርጋት, መዘርጋቶች
- "all / every / everything" · Amharic ሁሉም, ሁሉንም, ሁሉ, ሁሉን, በሙሉ, ሙሉ

---

## 3. Scenes

Activate a scene **by name** with a scene verb:

- **"activate <scene>"**, "run <scene>", "start <scene>", "execute <scene>", "scene <scene>"
- Amharic verbs: አስኪድ, ጀምር, ስንቄ, ሲኒ

Examples (scene names are whatever you created in the app):
- "activate Movie Night"
- "run Good Morning"
- "scene Sleep"

A scene name spoken **without** an activation verb is not a command.

---

## 3b. Device groups (rooms / zones)

A group is a set of devices you created in the app (Devices → Groups). Turn the
whole group on/off **by name** — no "group" word needed:

| Say | Does |
|---|---|
| turn on the living room | every device in the "Living Room" group |
| turn off living room | … |
| turn on living room lights | the group (not every light in the home) |
| turn on bedroom | the "Bedroom" group |

- A **device name** still beats a same-named group ("turn on light 1").
- "turn on all lights" stays the whole class, not a group.

## 3c. Automations

Run or toggle an automation by name:

| Say | Does |
|---|---|
| run morning routine | executes the automation's actions now |
| trigger morning routine | same |
| start / execute morning routine | same |
| enable morning routine | turns the rule ON (so its trigger can fire) |
| disable morning routine | turns the rule OFF |
| turn on morning routine | enable |
| turn off morning routine | disable |

- A **scene** with the same name wins over an automation.
- A device or group with the same name wins too.

---

## 4. Answers while Robi is asking a question

| Intent | English | Amharic |
|---|---|---|
| **Yes** | yes, yeah, yep, yup, correct, right, ok, okay, sure, confirm, confirmed, "that's right", "do it", "go ahead" | አዎ, አዎን, እሺ, በትክክል |
| **No** | no, nope, nah, negative, "not that", "not that one" | አይ, አይደለም, አልተሳካም |
| **Cancel** | cancel, abort, quit, stop, nevermind, "never mind", "forget it", "stop listening", "cancel that" | ተወው, ተወውት, ሰርዝ, አቋርጥ, ቀረው |
| **Undo** | undo, revert, "undo that", "put it back", "turn it back" | — |
| **Correct** | "I meant the bedroom", "change it to the living room", "no, the other room", "the other one" | — |

---

## 5. Restart / barge-in

- Say **"Hey Robi" again** during a command session to abort and start over.

---

## 6. What Robi does when it is unsure

| Situation | Robi says |
|---|---|
| Two devices match ("Light 1" on two boards) | "Which one — Light 1, Light 1?" |
| Low confidence (0.55–0.80) | "Did you mean Light 1?" |
| Nothing understood | "I heard '…' but didn't understand it." |
| Very low confidence (< 0.55) | "I didn't understand that clearly. Please say it again." |
| High-impact target (gate / door / lock) | Always asks "Do you want me to do that?" |

Thresholds (in `command_safety_policy.dart`): **execute ≥ 0.80**, clarify 0.55–0.80,
reject < 0.55. A single-device match scores **0.82**, so it executes.

---

## 7. Device names on this board (SHE-R24)

- **Lights:** Light 1 … Light 16
- **Sockets:** Socket 1 … Socket 8

Plus anything you renamed in the app (the display name is what Robi matches).

---

## 7b. Your own commands (Voice Control → list icon)

Create phrases that mean whatever you want:

- **Alias:** "socket one" → turn on Socket 1
- **Macro:** "goodnight" → turn off all lights

Open **Voice Control → (list icon) "My commands"** to add one. For each command:

| Option | Effect |
|---|---|
| **Enabled** | Off pauses it without deleting. |
| **Hidden** | Not shown in the list (tap the eye icon to reveal). |
| **Locked** | Robi always asks "This command is locked. Do you want to run it?" first. |

The **lock icon** sets a PIN that hides the whole page. **"Forgot PIN? Reset"**
asks for the **account email + password** — only the account owner can clear the
PIN. Commands are stored **encrypted** on the phone (Hive + an AES key kept in
secure storage), and groups/automations are cached so they keep working offline.

---

## 8. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "didn't understand" | Recognition language ≠ what you spoke. **Settings → Language → English** if you speak English. Check mic permission. |
| "turn on socket one" turns on **all** sockets | The number wasn't matched to the device name. Say the number clearly ("socket one" / "socket 1"). |
| Nothing happens at all | Settings → Robi → main switch **and** "Continuous 'Hey Robi'" must both be ON. Check the Robi notification is present. |
| Works on screen but not locked | "Continuous 'Hey Robi'" must be ON; the foreground service must be alive (not force-stopped). |
