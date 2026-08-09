# SHE V3 — Smart Home Ethiopia (Phase 0 Foundation)

Production-ready, fully self-hosted IoT platform for the Ethiopian market.
**This repository implements Phase 0 — Foundation (weeks 1–4)** per `V3-ROADMAP.md §2`.

## Quick start

### Prerequisites

| Tool | Version | Notes |
|---|---|---|
| Docker Engine | 24+ | With Docker Compose v2 |
| JDK | 21 LTS | P1-25 |
| Maven | 3.9+ | |
| OpenSSL | 3.x | For dev cert generation |
| step CLI | latest | https://smallstep.com/docs/step-cli/ |
| Git | 2.40+ | |

### 1. Start infrastructure (Postgres + Redis + EMQX cluster + MinIO + step-ca)

```bash
cd infra
cp .env.example .env
# Edit .env if needed (defaults are fine for local dev)

# Generate the step-ca provisioner password
openssl rand -base64 24 > ca/step-ca-provisioner-password.txt

# Start the stack
docker compose up -d

# Wait for step-ca to bootstrap (first run takes ~30s)
docker logs -f she-step-ca   # until you see "step-ca bootstrap complete"
```

### 2. Generate JWT signing keypair

```bash
mkdir -p infra/ca/keys
openssl genpkey -algorithm ed25519 -out infra/ca/keys/jwt_ed25519.pem
openssl pkey -in infra/ca/keys/jwt_ed25519.pem -pubout -out infra/ca/keys/jwt_ed25519.pub

# Build the JWT_SIGNING_PUBLIC_KEYS JSON value (one-line)
PUB_PEM=$(cat infra/ca/keys/jwt_ed25519.pub)
JWT_SIGNING_PUBLIC_KEYS=$(python3 -c "
import json, sys
print(json.dumps([{'kid':'2025q1','public_key_pem': sys.stdin.read()}]))
" <<< "${PUB_PEM}"
)
echo "Set this in backend/.env:"
echo "JWT_SIGNING_PUBLIC_KEYS=${JWT_SIGNING_PUBLIC_KEYS}"
```

### 3. Configure Spring Boot backend

```bash
cd backend
cp .env.example .env
# Edit .env:
#   - JWT_SIGNING_PRIVATE_KEY_PATH=../infra/ca/keys/jwt_ed25519.pem
#   - JWT_SIGNING_PUBLIC_KEYS=<the JSON you generated above>
#   - STEP_CA_FINGERPRINT=<from infra/ca/out/root_ca_fingerprint.txt>
```

### 4. Run the backend

```bash
SPRING_PROFILES_ACTIVE=local mvn spring-boot:run
```

### 5. Verify Phase 0 exit criteria

```bash
cd ..
./scripts/verify-phase0.sh local
```

Expected output: all 5 criteria PASS with green checkmarks.

---

## Repository layout

```
she-v3/
├── .github/workflows/
│   └── ci.yml                          # Phase 0 exit criterion 4
├── backend/                            # Spring Boot MVP (Phase 0 exit criterion 3)
│   ├── src/main/java/et/she/v3/
│   │   ├── SheBackendApplication.java
│   │   ├── config/                     # SecurityConfig, SheProperties
│   │   ├── controller/                 # AuthController, UsersController
│   │   ├── service/                    # AuthService, UserService + impl/
│   │   ├── dto/                        # Request/response DTOs
│   │   ├── entity/                     # JPA entities (Tenant, User, DeviceCert)
│   │   ├── repository/                 # Spring Data JPA repositories
│   │   ├── security/                   # JwtService (EdDSA), TenantContextInterceptor, filters
│   │   ├── mqtt/                       # /internal/mqtt/auth + /acl endpoints (EMQX backend)
│   │   ├── ca/                         # step-ca client + CaController
│   │   ├── errors/                     # GlobalExceptionHandler + SheException
│   │   └── actuator/                   # Custom health indicators
│   ├── src/main/resources/
│   │   ├── application.yml             # Shared config
│   │   ├── application-{local,staging,prod}.yml
│   │   └── db/migration/               # Flyway V1+V2+V3 (canonical RLS per P0-5)
│   ├── src/test/                       # Unit + integration tests
│   ├── Dockerfile                      # Multi-stage build
│   ├── pom.xml                         # Maven (Java 21, Spring Boot 3.3.x)
│   └── .env.example
├── infra/                              # Infrastructure (Phase 0 exit criteria 1 + 2)
│   ├── docker-compose.yml              # Postgres + Redis + EMQX x3 + MinIO + step-ca + CRL nginx
│   ├── .env.example
│   ├── ca/                             # step-ca bootstrap + issue/revoke/refresh/backup scripts
│   │   ├── bootstrap-ca.sh             # Root CA (RSA 4096/20yr) + Intermediate (RSA 4096/10yr)
│   │   ├── issue-device-cert.sh        # Sign ECDSA P-256 device CSR (5yr per P0-2)
│   │   ├── revoke-device-cert.sh       # Revoke + regenerate CRL
│   │   ├── refresh-crl.sh              # Cron job (6h per P1-22)
│   │   └── backup-root-key.sh          # Encrypted offline backup
│   ├── emqx/
│   │   ├── cluster-override.conf       # Production reference config (HOCON)
│   │   └── join-cluster.sh             # Join emqx-2/3 → emqx-1
│   ├── nginx/
│   │   └── crl-server.conf             # CRL distribution point
│   └── postgres/
│       ├── conf/postgresql.conf        # TimescaleDB + pg_stat_statements
│       └── init/01-bootstrap-roles.sql # she_app + she_migrate roles (P0-5: no BYPASSRLS)
├── docs/
│   └── LOCK-MANIFEST.md                # Phase 0 exit criterion 5
├── scripts/
│   └── verify-phase0.sh                # Runs all 5 exit criteria checks
└── README.md                           # This file
```

---

## Phase 0 exit criteria — verification

| # | Criterion | How to verify | Script section |
|---|---|---|---|
| 1 | EMQX cluster running with cert-based mTLS auth | `openssl s_client -connect she.et:8883` succeeds with device cert | `verify-phase0.sh` → "Criterion 1" |
| 2 | CA operational — can issue + revoke device certs via step-ca; CRL endpoint serves | `step ca certificate` + `step ca revoke` succeed; CRL HTTP endpoint returns 200 | `verify-phase0.sh` → "Criterion 2" |
| 3 | Spring Boot MVP deployed to staging — `/actuator/health` returns UP | `curl /actuator/health` returns `{"status":"UP"}` with `db` + `redis` components | `verify-phase0.sh` → "Criterion 3" |
| 4 | CI/CD pipeline builds + deploys backend automatically on merge | `.github/workflows/ci.yml` defines build → test → docker push → deploy-staging jobs | `verify-phase0.sh` → "Criterion 4" |
| 5 | All V3 docs + ADRs locked | `docs/LOCK-MANIFEST.md` exists; 14 ADRs + 32+ V3 docs present | `verify-phase0.sh` → "Criterion 5" |

Run all checks:
```bash
./scripts/verify-phase0.sh local       # local dev
./scripts/verify-phase0.sh staging     # staging VPS
```

---

## Canonical decisions enforced in this codebase

Every line of code respects these canonical decisions from `CANONICAL-DECISIONS.md`:

| ID | Decision | Where enforced |
|---|---|---|
| P0-1 | ESP32 generates ECDSA P-256 keypair on-chip; private key never leaves device | `infra/ca/issue-device-cert.sh` (signs CSR, never sees private key) |
| P0-2 | Root CA: RSA 4096/20yr. Intermediate: RSA 4096/10yr. Device cert: ECDSA P-256/5yr | `infra/ca/bootstrap-ca.sh` |
| P0-5 | RLS bypass via `app.is_platform_admin` GUC; `she_app` has NO BYPASSRLS | `infra/postgres/init/01-bootstrap-roles.sql`, `backend/.../V1__tenants.sql`, `TenantContextInterceptor` |
| P1-6 | JWT = EdDSA (Ed25519) with `kid` header for multi-key rotation | `backend/.../security/JwtService.java` |
| P1-10 | Backend MQTT: client cert + explicit ACL — NO superuser, NO blanket bypass | `infra/emqx/cluster-override.conf`, `MqttAuthController` |
| P1-11 | EMQX auth cache TTL = 300s | `infra/docker-compose.yml` (EMQX_AUTHENTICATION__DEFAULT) |
| P1-13 | LWT payload = JSON `{"status":"offline"}` | `infra/emqx/cluster-override.conf` (rules) |
| P1-22 | CRL refresh every 6 hours | `backend/.../ca/CaController.java` `@Scheduled(cron = "0 0 */6 * * *")` |
| P1-25 | Java 21 LTS | `backend/pom.xml`, `.github/workflows/ci.yml` |
| P1-32 | EMQX authorization via HOCON `authorization { sources = [...] }` (NOT 4.x env vars) | `infra/docker-compose.yml` (EMQX_AUTHORIZATION__SOURCES JSON) |

---

## Next phase

After all 5 exit criteria pass:

- **Phase 1 (weeks 5–12)** — Device integration: BLE provisioning, self-hosted OTA, local control, energy ingest, cert-based MQTT auth (already implemented in Phase 0, just needs device firmware).
- **Phase 2 (weeks 13–24)** — Custom hardware: PCB fab, 50-unit pilot, factory partner, factory flashing workflow.
- **Phase 3 (weeks 25–32)** — B2B multi-tenant + payments: RLS policies, white-label branding, Chapa integration.

See `V3-ROADMAP.md` for the full 52-week plan.
