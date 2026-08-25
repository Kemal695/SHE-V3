# V3 — Mobile App (Flutter Premium Dark-Mode)

**Status:** Locked
**Last updated:** 2024-Q4
**Owner:** Mobile/Frontend Engineer

---

## 1. Overview

The SHE V3 mobile app is a consumer-grade IoT client for iOS + Android, built in Flutter 3.22+. Premium dark-mode Bento UI, BLE provisioning, offline-tolerant cache, energy dashboard, voice control (on SHE-R16), Telebirr payments via Chapa, and Amharic-first i18n.

**Target:** iOS 15+ and Android 8.0+ (API 26). Covers ~95% of Ethiopian smartphone market (mostly Android).

---

## 2. Tech stack

| Component | Version | Why |
|---|---|---|
| Flutter | 3.22+ | Cross-platform, hot reload, mature ecosystem |
| Dart | 3.4+ | Pattern matching, records |
| State management | Riverpod 2.x | Compile-safe, testable, no `BuildContext` dependency |
| Routing | go_router 14+ | Declarative routing, deep links |
| HTTP | Dio 5.x | Interceptors, cancellation, retry |
| WebSocket | web_socket_channel 3.x | Real-time device state updates |
| Local storage | Hive (encrypted box) | Fast NoSQL cache |
| Secure storage | flutter_secure_storage | Keychain (iOS) / EncryptedSharedPreferences (Android) for tokens |
| BLE | flutter_blue_plus | BLE provisioning + mDNS discovery |
| Charts | fl_chart 0.68+ | Energy + telemetry charts |
| Push | firebase_messaging + flutter_local_notifications | FCM (Android) + APNs (iOS) |
| Voice | Picovoice SDK | On-device wake word + intent (R16 only) |
| Payments | flutter_web_auth_2 | Chapa checkout via in-app browser |
| i18n | flutter_localizations + ARB files | Amharic + English |
| Crash reporting | Firebase Crashlytics | Production crash tracking |
| Performance | Firebase Performance Monitoring | App cold start, API latency |

---

## 3. Directory structure

```
mobile/lib/
├── main.dart
├── app.dart
├── core/
│   ├── constants/              # API URLs, storage keys, WS events
│   ├── errors/                 # AppException hierarchy
│   ├── network/                # Dio + JWT interceptor + WS client
│   ├── storage/                # Secure storage (tokens) + Hive (cache)
│   ├── theme/                  # V3 design tokens (dark-mode first, no indigo/blue-purple)
│   ├── utils/                  # Date formatters, validators, ETB formatting, Ethiopian calendar
│   └── widgets/                # SHECard, SHEToggle, haptic slider, Bento grid, dynamic device widget
├── features/
│   ├── auth/                   # Login, register, OAuth, MFA
│   ├── home/                   # Home list + detail + member management
│   ├── dashboard/              # Bento grid + scenes row + quick actions
│   ├── device_detail/          # State, telemetry, time series, energy, system service
│   ├── provisioning/           # BLE pairing flow
│   ├── automation/             # List + builder + trigger
│   ├── scene/                  # List + builder + activate
│   ├── nodegroup/              # Group management
│   ├── ota/                    # Batch list + approvals (TENANT_ADMIN+)
│   ├── energy/                 # Energy dashboard (gauge + charts + ETB cost)
│   ├── voice/                  # Voice command overlay + history (R16 only)
│   ├── payments/               # Telebirr checkout + subscription management
│   ├── notifications/          # Preferences + recent log
│   ├── settings/               # Profile, theme, language, MFA, logout
│   └── members/                # Home member management
├── l10n/                       # app_en.arb, app_am.arb
└── routing/                    # GoRouter config
```

---

## 4. Premium dark-mode Bento dashboard

Per V3-DESIGN-SYSTEM.md and ADR-009:

- **Background:** Deep Navy `#0B1D37`
- **Surface cards:** Lighter Navy `#152946` with 16 px rounded corners
- **Active device glow:** `box-shadow: 0 0 20px rgba(86, 180, 250, 0.3)` — Bright Sky Blue `#56B4FA`
- **NO indigo or blue-purple anywhere** — system rule (V3-DESIGN-SYSTEM.md §1.1)
- **Scenes row:** Horizontal scrolling at top (Good Morning / Leaving Home / Movie Night / +)
- **Bento grid:** Device cards below scenes row (2-col mobile, 3-col tablet, 4-col desktop if foldable)
- **Energy summary card:** Real-time power (W) + today's cost in ETB
- **Quick actions on long-press:** Radial menu (On / Off / Schedule / Settings)

### 4.1 Bento grid layout

```
Mobile (≤ 600px width): 2 columns
  [Scene Card 1] [Scene Card 2] [Scene Card 3] [+]  ← horizontal scroll
  [Device 1×1]   [Device 1×1]
  [Device 2×1 - Energy]
  [Device 1×1]   [Device 1×1]

Tablet (600-900px): 3 columns
  [Scene 1] [Scene 2] [Scene 3] [+]
  [1×1] [1×1] [1×1]
  [2×1 Energy Summary]
  [1×1] [1×1] [1×1]

Desktop / Foldable (≥ 900px): 4 columns
  [Scene 1] [Scene 2] [Scene 3] [Scene 4] [+]
  [1×1] [1×1] [1×1] [1×1]
  [2×2 Energy] [2×1 Camera]
  [1×1] [1×1] [1×1] [1×1]
```

---

## 5. Dynamic UI generation from node config payload

Per V3-DEVICE-MODEL.md §8, the dashboard generates device controls dynamically from the node's `config` payload (published on `she/.../config` MQTT topic at connect, retained):

```dart
class DynamicDeviceWidget extends ConsumerWidget {
  final NodeConfig config;
  final NodeDevice device;
  
  @override
  Widget build(BuildContext context, ref) {
    return switch (device.type) {
      'esp.device.switch' => SwitchDeviceCard(device: device),
      'esp.device.lightbulb' => LightbulbDeviceCard(device: device),
      'esp.device.fan' => FanDeviceCard(device: device),
      'esp.device.temp_sensor' => TempSensorCard(device: device),
      'esp.device.energy_meter' => EnergyMeterCard(device: device),
      _ => GenericDeviceCard(device: device),  // fallback: render all params as toggles/sliders
    };
  }
}

// GenericDeviceCard inspects device.params and renders:
// - bool params → SHEToggle
// - int/float params with bounds → HapticSlider
// - string params → read-only Text
// - params with time_series flag → tap to open chart
```

**Implication:** Adding a new device type in firmware (e.g., `esp.device.door_lock`) does not require an app release — the generic fallback renders it. A tailored widget (`DoorLockCard`) can ship in the next app release for a better UX.

---

## 6. BLE provisioning flow

```
User taps "+" → "Add Device":
  1. Scan QR code on device enclosure (or manual BLE scan)
     QR contains: MAC address + PoP (Proof of Possession, 9-digit numeric, factory-generated CSPRNG, scanned from QR code)
  2. Flutter app scans BLE → finds "SHE-R8-AABBCCDDEEFF" (advertised name = node_id)
  3. Connect (BLE Security Level 1, PoP = MAC + scanned PoP concatenated)
  4. App requests claim token from Spring Boot:
       POST /api/v3/nodes/claim
       Body: { "mac_address": "24:6F:28:AA:BB:CC", "pop": "..." }
       → Returns: { "claim_token": "...", "tenant_id": "..." }
  5. App sends Wi-Fi SSID + password + claim_token + tenant_id to ESP32 via BLE custom GATT service
  6. ESP32:
     a. Connects to Wi-Fi (SSID + password)
     b. Claims X.509 cert from Spring Boot via HTTPS (claim_token → step-ca issues cert)
     c. Connects to EMQX over mTLS with new cert
     d. Publishes node config (devices, services, params) on she/.../config topic
  7. WebSocket push from Spring Boot → app: "device_provisioned"
  8. Device tile appears in dashboard (no app refresh needed)
```

**Failure modes:**
- Wrong Wi-Fi password → ESP32 reports `WIFI_AUTH_FAIL` over BLE → app shows "Wi-Fi password incorrect"
- Cloud unreachable (no internet) → ESP32 retries 3×, then app shows "Couldn't reach SHE cloud. Try again."
- Claim token expired (10 min) → app re-requests new token
- BLE pairing fails → fallback to manual MAC entry

---

## 7. Offline behavior

**Online-first, offline-tolerant** — not offline-first.

- **Hive cache:** homes, devices (last known state), automations, scenes (24 h TTL, refreshed on app foreground)
- **Commands queued:** in `pending_commands` Hive box; sent when reconnect. UI shows "Queued" badge on the command.
- **Local control fallback:** mDNS → HTTPS to ESP32 LAN IP (V3-FIRMWARE.md §6 — local control). Works on same Wi-Fi even when internet is down.
- **Connectivity banner:** "You're offline. Showing cached data." (amber banner at top, dismissible)
- **Conflict resolution:** When reconnecting, if a queued command conflicts with a newer device state (e.g., user toggled ON while offline, but another family member toggled OFF via cloud), the most recent state wins — app shows "State updated by another user."

---

## 8. WebSocket events

Subscribe via `wss://she.et/ws/v3` with `Sec-WebSocket-Protocol: bearer.<JWT>` header (per V3-SECURITY-MODEL.md §1.6 and V3-API-SPECIFICATION.md §14 — NOT `?token=` query param, which leaks in logs).

| Event | Action |
|---|---|
| `node.state` | Update device tile (optimistic UI revert if server disagrees) |
| `node.telemetry` | Update telemetry charts (voltage, current, power, energy) |
| `node.presence` | Update online/offline badge |
| `automation.triggered` | Toast notification |
| `scene.activated` | Animate affected device cards (200 ms stagger) |
| `notification.received` | Show local notification + update badge |
| `ota.progress` | Update OTA progress bar |
| `energy.update` | Update real-time energy gauge |

Reconnect with exponential backoff: 1s → 2s → 4s → 8s → 16s → max 60s.

---

## 9. Energy dashboard

Per V3-ENERGY-MONITORING.md §7:

- **Real-time gauge:** Animated circular gauge showing current `power_consumption` (W) — updates via WebSocket `energy.update`
- **Today's summary:** Total kWh + cost in ETB (queried from `energy_daily` continuous aggregate)
- **Historical chart:** Bar chart (7/14/30-day view) with kWh + ETB dual axis (fl_chart)
- **Per-device breakdown:** List of devices with their consumption + cost (sorted descending)
- **Anomaly alerts:** Push notification when consumption 3× above 7-day baseline
- **Monthly projection:** "At current rate, you'll use X kWh / Y ETB this month"

**SHE-R4 note:** If user has only R4 devices, the Energy Dashboard shows empty state: "Energy monitoring is available on SHE-R8 and SHE-R16. Your SHE-R4 device does not have a power sensor."

---

## 10. Telebirr payment flow

```
Settings → Subscription → "Upgrade to Premium"
  │
  ▼
Flutter app calls: POST /api/v3/payments/initiate
  Body: { "plan": "B2C_PREMIUM", "amount_etb": 150 }
  Authorization: Bearer <JWT>
  │
  ▼
Spring Boot calls Chapa API → returns checkout URL
  │
  ▼
Flutter app opens checkout URL in in-app browser (flutter_web_auth_2)
  │
  ▼
User pays via Telebirr / CBE Birr / card (Chapa-hosted page)
  │
  ▼
Chapa redirects to callback URL + sends webhook to Spring Boot
  │
  ▼
Spring Boot verifies webhook signature → activates subscription
  │
  ▼
WebSocket push: "subscription_activated" → app unlocks premium features
```

**Plans available in-app (V3-B2B-WHITELABEL.md §4):**
- B2C Free → $0
- B2C Premium → 150 ETB/mo (~$2.73)
- B2C Family → 300 ETB/mo (~$5.45) — 5 members + shared homes + priority support

---

## 11. Amharic i18n

Per V3-I18N.md:

- **Default language:** Amharic (if system locale = `am`), else English. User can override in Settings.
- **Font:** Noto Sans Ethiopic (alongside Inter for Latin)
- **All strings** in `app_en.arb` + `app_am.arb` — 100% coverage
- **Ethiopian calendar:** 13 months, 30 days each + 5/6 epagomenal days; 7-8 years behind Gregorian
- **ETB currency formatting:** `1,234.56 ብር` (comma thousands, dot decimal, ብር symbol)
- **Phone validation:** `^(\+251|0)?9\d{8}$`
- **Name format:** "Full name" field (not first/last — Ethiopian names are first + father's name)
- **Line height:** 1.6 for Amharic (vs 1.4 for English)
- **Button width:** 30% more for Amharic text

---

## 12. White-label branding

On login screen, user enters email → app extracts domain (or system detects via subdomain if installed via tenant-specific build) → calls `GET /api/v3/tenant/branding?subdomain=xxx`:

- App name (title bar + splash)
- Logo (login + dashboard)
- Primary color (buttons, toggles, active states) — **must NOT be indigo or blue-purple** (V3-DESIGN-SYSTEM.md §1.3; form validation rejects these hues on tenant admin side)
- Login background image

B2C users (no tenant): default SHE branding (Deep Navy + Bright Sky Blue).

---

## 13. Build + release

### 13.1 Local dev

```bash
cd mobile
flutter pub get
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080  # Android emulator
# For physical device:
flutter run --dart-define=API_BASE_URL=http://192.168.x.x:8080
```

### 13.2 Production build

```bash
# Android
flutter build appbundle --release \
  --dart-define=API_BASE_URL=https://she.et \
  --dart-define=WS_BASE_URL=wss://she.et \
  --obfuscate --split-debug-info=build/symbols

# iOS
flutter build ipa --release \
  --dart-define=API_BASE_URL=https://she.et \
  --dart-define=WS_BASE_URL=wss://she.et \
  --obfuscate --split-debug-info=build/symbols
```

### 13.3 Release channel

- **Internal testing:** Firebase App Distribution (50 testers)
- **Closed beta (Phase 5C):** Google Play Console + TestFlight (100 beta users)
- **GA:** Google Play Store + Apple App Store

CI/CD: GitHub Actions builds + uploads to Firebase App Distribution on every merge to `main`. Release builds tagged `v1.x.x` go to Play Console + TestFlight for promotion.

---

## 14. References

- V3-DESIGN-SYSTEM.md — design tokens (Deep Navy + Bright Sky Blue, NO indigo/blue-purple)
- V3-DEVICE-MODEL.md §8 — dynamic UI generation
- V3-MQTT-STANDARDS.md — topic patterns (app subscribes to `she/.../params/local`)
- V3-ENERGY-MONITORING.md §7 — Energy Dashboard spec
- V3-VOICE-MATTER.md §1 — voice overlay (R16 only)
- V3-PAYMENTS.md — Telebirr + Chapa flow details
- V3-B2B-WHITELABEL.md §3 — white-label branding config
- V3-I18N.md — Amharic + Ethiopian calendar rules
- V3-SECURITY-MODEL.md §1 — JWT auth + WebSocket header
- ADR-009 — dark-mode-first decision
