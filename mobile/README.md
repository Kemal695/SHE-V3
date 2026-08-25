# SHE V3 — Flutter mobile app

**Flutter 3.22+ / Dart 3.4+** mobile app for SHE V3.

## Tech stack (V3-MOBILE-APP §2)

- Flutter 3.22+ / Dart 3.4+
- Riverpod 2.x (state management)
- go_router 14+ (routing)
- Dio 5.x (HTTP + JWT interceptor)
- web_socket_channel 3.x (real-time device state)
- Hive (encrypted cache)
- flutter_secure_storage (tokens)
- flutter_blue_plus (BLE provisioning)
- fl_chart 0.68+ (energy + telemetry charts)
- firebase_messaging + flutter_local_notifications (push)

## Directory structure (V3-MOBILE-APP §3)

```
mobile/
├── lib/
│   ├── main.dart                    # Entry point
│   ├── app.dart                     # Root widget
│   ├── core/
│   │   ├── constants/api_constants.dart
│   │   ├── network/dio_client.dart  # Dio + JWT interceptor + auto-refresh
│   │   ├── network/ws_client.dart   # WebSocket (P1-4: bearer.<jwt> subprotocol)
│   │   ├── storage/secure_storage.dart
│   │   ├── theme/she_theme.dart     # Deep Navy #0B1D37 + Bright Sky Blue #56B4FA
│   │   ├── utils/validators.dart    # Ethiopian phone, email, password rules
│   │   └── widgets/
│   ├── features/
│   │   ├── auth/                    # Login, register, auth_service
│   │   ├── home/                    # Home list
│   │   ├── dashboard/               # Bento grid + DynamicDeviceWidget
│   │   ├── device_detail/           # Node detail + param write
│   │   ├── provisioning/            # BLE provisioning flow
│   │   ├── energy/                  # Energy dashboard (gauge + fl_chart)
│   │   ├── ota/                     # OTA batch management
│   │   └── settings/                # Profile, language, logout
│   ├── l10n/                        # app_en.arb + app_am.arb (Amharic first)
│   └── routing/app_router.dart
├── l10n.yaml
└── pubspec.yaml
```

## Build + run

```bash
cd mobile
flutter pub get

# Local dev (Android emulator)
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080

# Physical device
flutter run --dart-define=API_BASE_URL=http://192.168.x.x:8080

# Android release
flutter build appbundle --release \
  --dart-define=API_BASE_URL=https://she.et \
  --dart-define=WS_BASE_URL=wss://she.et \
  --obfuscate --split-debug-info=build/symbols

# iOS release
flutter build ipa --release \
  --dart-define=API_BASE_URL=https://she.et \
  --dart-define=WS_BASE_URL=wss://she.et
```

## Design tokens (V3-DESIGN-SYSTEM, ADR-009)

| Token | Value | Usage |
|---|---|---|
| Deep Navy | `#0B1D37` | Background |
| Lighter Navy | `#152946` | Surface cards (16px rounded corners) |
| Bright Sky Blue | `#56B4FA` | Accent / active glow |
| Active glow | `box-shadow: 0 0 20px rgba(86, 180, 250, 0.3)` | ON devices |
| **NO indigo/blue-purple** | — | System rule (ADR-009) |

## Canonical decisions enforced

| Decision | Where |
|---|---|
| P1-4: WebSocket auth via `Sec-WebSocket-Protocol: bearer.<jwt>` | `ws_client.dart` |
| P1-6: JWT = EdDSA (validated server-side) | `dio_client.dart` (auto-refresh on 401) |
| P0-1: BLE does NOT issue certs — cert is factory-issued | `provisioning_screen.dart` (no cert claim step) |
| P1-2: BLE Service UUID = `0000ffff-...` | `provisioning_screen.dart` (BLE scan filter) |
| P1-26: PoP = 9-digit numeric | `provisioning_screen.dart` (maxLength: 9) |
| ADR-009: dark-mode first, Bento grid, NO indigo | `she_theme.dart` |
| V3-I18N: Amharic first, Noto Sans Ethiopic | `app_am.arb`, `pubspec.yaml` fonts |
| V3-ERROR-CODES §3: Ethiopian phone `^(\+251\|0)?9\d{8}$` | `validators.dart` |

## i18n (V3-I18N)

- Default: Amharic if system locale = `am`, else English (user override in Settings)
- 100% string coverage in `app_en.arb` + `app_am.arb`
- Noto Sans Ethiopic font for Amharic, Inter for Latin
- Ethiopian phone validation: `^(\+251|0)?9\d{8}$`
- ETB currency: `1,234.56 ብር`
- Single "Full name" field (Ethiopian names are first + father's name)
