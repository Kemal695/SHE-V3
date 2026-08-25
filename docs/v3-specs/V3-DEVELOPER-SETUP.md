# V3 — Developer Setup

**Status:** Locked
**Last updated:** 2024-Q4
**Owner:** Backend Engineer

---

## 0. Scope

This document gets a new engineer from `git clone` to a running V3 stack locally.

> **Correction from the original V3-DEVELOPER-SETUP.md (Proposed):** The original claimed "under 30 minutes" for the full stack. This is unrealistic — ESP-IDF alone takes 30+ minutes to install and download toolchains, plus first firmware build is 5-10 minutes. The corrected target: **under 30 minutes for Spring Boot only** (backend + Postgres + Redis + EMQX via Docker), **under 2 hours for the full stack** (backend + mobile + admin web + firmware toolchain + first device flash).

---

## 1. Prerequisites

| Software | Version | Why | Install time |
|---|---|---|---|
| JDK | 21 (LTS) | Spring Boot 3.x runtime | 5 min |
| Maven | 3.9+ | Backend build | 3 min |
| Docker Desktop | 24+ (or Docker Engine + Compose v2 on Linux) | Postgres + Redis + EMQX + MinIO containers | 10 min |
| Node.js | 20 LTS | Admin web (Next.js 16) | 5 min |
| Flutter | 3.22+ | Mobile app (Dart 3.4+) | 10 min |
| ESP-IDF | v5.1.x | Firmware build (only if testing with ESP32 hardware) | **30-45 min** (large toolchain download) |
| step-ca CLI | latest | Local CA for dev (alternative: use staging CA) | 5 min |
| Git | 2.40+ | Clone repo | (assumed) |

**Total:** ~25 min for backend-only path; ~75 min for full-stack including ESP-IDF.

---

## 2. Spring Boot only — 30-minute path

If you are a backend engineer who doesn't need mobile or firmware, this is the fastest path.

### 2.1 Clone + start infra (10 min)

```bash
git clone git@github.com:she-v3/she-v3.git
cd she-v3

# Start infra (Postgres 16 + Redis 7 + EMQX 5 + MinIO)
cd infra
cp .env.example .env
# Edit .env — set real passwords (POSTGRES_PASSWORD, REDIS_PASSWORD, EMQX_DASHBOARD_PASSWORD)
docker compose up -d

# Verify
docker compose ps  # all 4 containers should be "Up"
docker compose logs emqx | tail -5  # EMQX boot complete
```

### 2.2 Run Spring Boot (5 min)

```bash
cd ../backend
cp .env.example .env
# Edit .env — set:
#   JWT_SECRET=$(openssl rand -base64 32)
#   DB_PASSWORD=<matches infra/.env>
#   REDIS_PASSWORD=<matches infra/.env>
#   CA_STEP_URL=http://localhost:9000  # local step-ca, or use staging CA

# First run: Flyway migrations create schema
SPRING_PROFILES_ACTIVE=local mvn spring-boot:run

# Verify (separate terminal)
curl http://localhost:8080/actuator/health
# → {"status":"UP","components":{"db":{"status":"UP"},...}}

# Open Swagger UI
open http://localhost:8080/swagger-ui.html
```

### 2.3 Bootstrap SUPER_ADMIN (5 min)

```bash
# Register a user via API
curl -X POST http://localhost:8080/api/v3/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@local.test","password":"ChangeMe!123","full_name":"Local Admin"}'

# Promote to SUPER_ADMIN
docker exec she-postgres psql -U she -d she_v3 -c \
  "UPDATE users SET platform_role = 'SUPER_ADMIN' WHERE email = 'admin@local.test';"
```

### 2.4 Verify MQTT works (5 min)

```bash
# Generate a test device cert via step-ca CLI (or use the staging CA)
step ca certificate SHE-R8-AABBCC device.crt device.key \
  --san SHE-R8-AABBCC --not-after 24h

# Subscribe to a topic
mosquitto_sub -h localhost -p 8883 \
  --cert device.crt --key device.key \
  --cafile infra/ca/root-ca.crt \
  -t 'she/+/+/+/+/params/local' -v

# In another terminal, publish a test message
mosquitto_pub -h localhost -p 8883 \
  --cert device.crt --key device.key \
  --cafile infra/ca/root-ca.crt \
  -t 'she/tenant-1/home-1/room-1/SHE-R8-AABBCC/params/local' \
  -m '{"Relay 1":{"Power":true}}'
```

You should see the message appear in the subscriber window. Spring Boot's `MqttListener` will also log the ingest.

### 2.5 Run admin web (5 min, optional)

```bash
cd ../admin-web
cp .env.example .env.local
npm ci
npm run dev
# Open http://localhost:3000 → login with admin@local.test
```

**Total Spring Boot-only path: ~30 minutes.**

---

## 3. Full stack — 2-hour path

Continue from §2 (infra + Spring Boot running). Then:

### 3.1 Run Flutter mobile app (15 min)

```bash
cd ../mobile
flutter pub get
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080  # Android emulator
# For physical device: --dart-define=API_BASE_URL=http://192.168.x.x:8080
```

The mobile app should connect to your local Spring Boot, register/login, and show an empty dashboard (no devices yet).

### 3.2 Install ESP-IDF (30-45 min)

```bash
# macOS / Linux
mkdir -p ~/esp && cd ~/esp
git clone -b v5.1.2 --recursive https://github.com/espressif/esp-idf.git
cd esp-idf
./install.sh esp32c3  # for SHE-R4
./install.sh esp32s3  # for SHE-R8/R16
. ./export.sh  # source this in every new terminal

# Verify
idf.py --version
```

First-time install downloads the Xtensa + RISC-V toolchains (~1.5 GB) — this is the slowest step.

### 3.3 Build firmware (5-10 min, first build is slower)

```bash
cd ../firmware/v3
idf.py set-target esp32s3  # for SHE-R8
idf.py menuconfig  # set WiFi SSID, MQTT host, CA cert path
idf.py build

# First build: 5-10 minutes (compiles ESP-IDF + all deps)
# Subsequent builds: 30-60 seconds (incremental)
```

### 3.4 Flash a real device (10 min)

```bash
# Connect ESP32-S3 dev kit via USB-C
# Make sure it's an SHE-R8 prototype or dev kit wired to PCF8574 + relays

idf.py -p /dev/cu.usbserial-XXXX flash monitor
# Watch boot log:
#   - Wi-Fi connecting to <SSID>
#   - MQTT connecting to localhost:8883
#   - "Node config published" — device appears in mobile app dashboard
#   - "Relay 1 → Power: false" (initial state)
```

### 3.5 First-device walkthrough

1. Open Flutter app → login as the SUPER_ADMIN you bootstrapped in §2.3
2. Tap `+` (add device) → "Scan QR code" (or manual BLE scan)
3. App finds `SHE-R8-AABBCC` over BLE → connect
4. App asks for Wi-Fi SSID + password → enter your local Wi-Fi
5. App calls Spring Boot `POST /api/v3/nodes/claim` → step-ca issues X.509 cert → cert returned to app
6. App sends Wi-Fi creds + claim token + tenant_id to ESP32 via BLE
7. ESP32 connects to Wi-Fi → connects to EMQX with new cert → publishes node config
8. WebSocket push: `device_provisioned` → device tile appears in dashboard
9. Tap device tile → see 8 relay toggles → tap "Relay 1" → relay clicks ON → app shows toggle in ON state
10. Check MQTT subscriber from §2.4: should see `{"Relay 1":{"Power":true}}`

If all 10 steps succeed, your full stack is working. Welcome to SHE V3.

---

## 4. Common workflows

### 4.1 Add a new REST endpoint
1. Define DTO in `modules/{module}/dto/`
2. Add service method in `service/{Name}Service.java` + `impl/{Name}ServiceImpl.java`
3. Add controller endpoint in `controller/{Name}Controller.java`
4. Add Flyway migration if new table (file: `V29__add_thing.sql`)
5. Add test in `src/test/java/.../{Name}ServiceTest.java`
6. Update `V3-API-SPECIFICATION.md`
7. PR with code review + privacy checklist (V3-PRIVACY-COMPLIANCE.md §6)

### 4.2 Add a new device type
1. Migration: `INSERT INTO device_types (type_name, capabilities) VALUES (...)` — wait, V28 drops `device_types`. The new path: add to `node_devices` directly with `device_type = 'esp.device.X'` at provisioning.
2. Firmware profile in `firmware/v3/main/device_profiles.c`
3. Mobile UI: add widget for new type in `features/dashboard/widgets/` (uses dynamic UI generation from config payload — V3-DEVICE-MODEL.md §8)

### 4.3 Add a new admin screen
1. Add route in `admin-web/app/(admin)/{route}/page.tsx`
2. Add to the sidebar nav in `admin-web/components/Sidebar.tsx`
3. Add role check in middleware (`admin-web/middleware.ts`)
4. Update `V3-ADMIN-WEB-APP.md` §2 (table of 9 screens)
5. Add API endpoint if new backend call needed (V3-ADMIN-PLATFORM.md §3)

### 4.4 Test with a simulated device (no hardware needed)

If you don't have ESP32 hardware, use the Python simulator:

```bash
cd tools/device-simulator
pip install -r requirements.txt
python simulate_device.py \
  --mac 24:6F:28:AA:BB:CC \
  --sku SHE-R8 \
  --cert device.crt \
  --key device.key \
  --ca infra/ca/root-ca.crt \
  --mqtt-host localhost --mqtt-port 8883
```

The simulator publishes realistic telemetry (relay state, PZEM readings, RSSI) every 5 s and accepts commands. Useful for mobile app testing without hardware.

---

## 5. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `docker compose up` fails on EMQX port | Port 18083 already in use | `lsof -i :18083` → kill process; or change port in `infra/docker-compose.yml` |
| Spring Boot: `PSQLException: connection refused` | Postgres not ready yet | `docker compose logs postgres` — wait for "database system is ready to accept connections" |
| Spring Boot: `Flyway migration failed` | Schema mismatch | `docker compose down -v && docker compose up -d` (destructive — dev only) |
| MQTT: `tls: handshake failure` | Cert not signed by dev CA | Re-generate cert via `step ca certificate ...` against the dev CA at `infra/ca/` |
| Flutter: `SocketException: Connection refused` | API_BASE_URL wrong | Use `10.0.2.2:8080` for Android emulator, `localhost:8080` for iOS simulator, LAN IP for physical device |
| ESP-IDF: `idf.py: command not found` | Didn't source `export.sh` | `. ~/esp/esp-idf/export.sh` in every new terminal |
| ESP-IDF: `A fatal error occurred: Failed to connect to ESP32` | Wrong port or USB cable | Try `/dev/cu.usbserial-*` (macOS) or `/dev/ttyUSB0` (Linux); some USB-C cables are power-only |

For more, see `V3-README.md` "Known Issues" section and `#engineering-help` Slack channel.

---

## 6. Local development environment variables

```bash
# infra/.env (Docker containers)
POSTGRES_USER=she
POSTGRES_PASSWORD=ChangeMeLocal
POSTGRES_DB=she_v3
REDIS_PASSWORD=ChangeMeLocal
EMQX_DASHBOARD__DEFAULT_PASSWORD=ChangeMeLocal
EMQX_DASHBOARD__DEFAULT_USERNAME=admin
MINIO_ROOT_USER=she
MINIO_ROOT_PASSWORD=ChangeMeLocal

# backend/.env (Spring Boot)
SPRING_PROFILES_ACTIVE=local
SPRING_DATASOURCE_URL=jdbc:postgresql://localhost:5432/she_v3
SPRING_DATASOURCE_USERNAME=she
SPRING_DATASOURCE_PASSWORD=ChangeMeLocal
SPRING_DATA_REDIS_HOST=localhost
SPRING_DATA_REDIS_PASSWORD=ChangeMeLocal
JWT_SECRET=<openssl rand -base64 32>
CA_STEP_URL=http://localhost:9000
CA_STEP_PROVISIONER_PASSWORD=ChangeMeLocal
MQTT_HOST=localhost
MQTT_PORT=8883
MQTT_CA_CERT=../infra/ca/root-ca.crt
MINIO_ENDPOINT=http://localhost:9000
MINIO_ACCESS_KEY=she
MINIO_SECRET_KEY=ChangeMeLocal
OTA_SIGNING_KEY=<path to dev Ed25519 private key>

# admin-web/.env.local
NEXT_PUBLIC_API_BASE_URL=http://localhost:8080
NEXT_PUBLIC_WS_BASE_URL=ws://localhost:8080
```

**Never commit real secrets.** The `.env.example` files contain placeholder values only; the `.gitignore` excludes `.env`, `.env.local`, and `infra/ca/*.key`.

---

## 7. References

- V3-ARCHITECTURE.md — system architecture + data flows
- V3-CONFIGURATION.md §4 — step-ca setup (local CA)
- V3-FACTORY-OPS.md — factory flashing workflow (for production-like dev setup)
- V3-INTEGRATION-TEST-PLAN.md — test pyramid + how to run tests
- V3-OPS-RUNBOOK.md — production ops (similar commands, production secrets)
- V3-README.md — repo layout + known issues
