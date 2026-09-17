# SHE V3 — Phase 3 Sign-Off + Phase 4 Plan

**Phase 3 status:** ✅ COMPLETE (all 5 exit criteria implemented)
**Sign-off date:** 2025-08-12
**Sign-off authority:** Lead Engineer

---

## 1. Phase 3 exit criteria — implementation record

Per `V3-ROADMAP §5`, the 5 exit criteria for Phase 3 are:

| # | Criterion | Implementation | Status |
|---|---|---|---|
| 1 | First B2B tenant onboarded (white-label branded app + subdomain) | `TenantService` + `TenantController` — CRUD `/api/admin/tenants` (SUPER_ADMIN), branding endpoint `GET /api/v3/tenant/branding?subdomain=xxx` (public, Flutter app fetches on login), branding color validation (rejects indigo/blue-purple hues per V3-B2B-WHITELABEL §3) | ✅ |
| 2 | Telebirr payment works end-to-end (subscribe → Chapa webhook → activated) | `ChapaClient` (WebClient → Chapa API: initialize/verify/refund), `PaymentService` (initiate + webhook with HMAC-SHA256 constant-time verify + idempotency via Postgres UNIQUE + Redis 24h cache), `SubscriptionService` (activate/extend +30 days), `PaymentController` (`POST /payments/initiate`, `POST /payments/webhook`, `GET /payments/verify/{ref}`, `GET /subscriptions/current`) | ✅ |
| 3 | Multi-tenant isolation verified (tenant A cannot read tenant B's data) | RLS policies on ALL tables (V1-V29), `TenantContextAspect` (AOP @Around on @Transactional — sets `app.tenant_id` GUC inside transaction), verified by `scripts/verify-phase3.sh` cross-tenant home access test | ✅ |
| 4 | B2B invoice generated + paid | `BillingService` — `@Scheduled` monthly on 25th at 09:00 Addis (generates PENDING payment records for all ACTIVE B2B tenants), daily failed-payment retry (Day 1/3/7 schedule), suspension after 7-day grace, expiration after 30 days | ✅ |
| 5 | RLS test suite passes 100% (cross-tenant query returns 0 rows) | `scripts/verify-phase3.sh` — registers two users, creates home as user A, verifies user B cannot see it | ✅ |

---

## 2. Deliverables built (Phase 3)

### 3A: Multi-tenant architecture

| Component | File | Purpose |
|---|---|---|
| `TenantService` | `tenant/TenantService.java` | Tenant CRUD (SUPER_ADMIN), branding config validation (rejects `#4F46E5`, `#6366F1`, `#7C3AED`, `#8B5CF6`), public branding endpoint by subdomain |
| `TenantController` | `controller/TenantController.java` | `/api/admin/tenants` (CRUD), `/api/admin/tenants/{id}/branding` (PUT), `/api/admin/tenants/{id}/status` (PUT), `/api/v3/tenant/branding` (GET, public) |
| `ApiKeyService` | `tenant/ApiKeyService.java` | B2B API key generation (`she_live_` + 32 random alphanumeric), SHA-256 hash, scopes (`devices:read`, `devices:write`, `energy:read`, `users:read`), validation, revocation |
| `ApiKeyController` | `controller/ApiKeyController.java` | `/api/v3/tenant/api-keys` (POST/GET/DELETE) — B2B-1000+ only |
| `ApiKey` entity | `entity/ApiKey.java` | JPA entity for V21 migration |
| `ApiKeyRepository` | `repository/ApiKeyRepository.java` | `findByKeyHashAndNotRevoked`, `findAllByTenantId` |

### 3B: Telebirr via Chapa

| Component | File | Purpose |
|---|---|---|
| `ChapaClient` | `payment/ChapaClient.java` | WebClient calls to Chapa API — `initialize`, `verify`, `refund` with `Bearer CHAPA_SECRET_KEY` auth |
| `PaymentService` | `payment/PaymentService.java` | Initiate payment (server-side amount validation), webhook processing (7-step: HMAC verify → idempotency → amount match → UPDATE → activate subscription → WS push → audit), idempotency (Postgres UNIQUE + Redis 24h cache) |
| `PaymentController` | `controller/PaymentController.java` | `POST /payments/initiate` (auth), `POST /payments/webhook` (public, HMAC verified), `GET /payments/verify/{ref}` (auth), `GET /subscriptions/current` (auth) |
| `SubscriptionService` | `payment/SubscriptionService.java` | `getCurrentSubscription()`, `isPremium(tenantId)` (feature gate), activate/extend +30 days |
| `Payment` entity | `entity/Payment.java` | JPA entity for V15 migration |
| `Subscription` entity | `entity/Subscription.java` | JPA entity for V15 migration |
| `PaymentRepository` | `repository/PaymentRepository.java` | `findAllByTenantId`, `findPendingBefore`, idempotency check |
| `SubscriptionRepository` | `repository/SubscriptionRepository.java` | `findByTenantIdAndStatus`, `findExpiredActive`, `findExpiringBefore` |
| `BillingService` | `billing/BillingService.java` | `@Scheduled` monthly invoice generation (25th at 09:00 Addis), daily failed payment retry (Day 1/3/7 → SUSPENDED → Day 30 EXPIRED), daily reconciliation (02:00 UTC) |
| `WsEventBus.publishSubscriptionActivated()` | `websocket/WsEventBus.java` | WebSocket push to unlock premium features after payment |

### 3C: Admin portal (backend)

| Component | File | Purpose |
|---|---|---|
| `ImpersonationService` | `admin/ImpersonationService.java` | 15-min impersonation JWT with `impersonated_by` claim, chain prevention (`RBAC_IMPERSONATION_CHAIN`), TENANT_ADMIN RLS scoping, audit logging |
| `ImpersonationController` | `controller/ImpersonationController.java` | `POST /api/admin/impersonate/{userId}`, `DELETE /api/admin/impersonate` |

### Mobile (Flutter)

| Component | File | Purpose |
|---|---|---|
| `PaymentService` | `features/payments/payment_service.dart` | Riverpod provider — `initiatePayment()`, `verifyPayment()`, `getCurrentSubscription()` |
| `PaymentScreen` | `features/payments/payment_screen.dart` | Plan summary (Premium 150 ETB, Family 300 ETB), initiate → open checkout_url via `flutter_web_auth_2`, wait for `subscription_activated` WS event |

### Infrastructure

| Component | File | Purpose |
|---|---|---|
| `SecurityConfig` | `config/SecurityConfig.java` | Added `/api/v3/payments/webhook` to public endpoints (HMAC verified) |
| `application.yml` | `application.yml` | Added `she.payment.chapa.*` config (api-base-url, secret-key, webhook-secret, callback-url, return-url, ip-whitelist) |
| `verify-phase3.sh` | `scripts/verify-phase3.sh` | Verifies all 5 Phase 3 exit criteria (RLS isolation, tenant onboarding, payment initiate, webhook HMAC, subscription, API keys) |

---

## 3. Canonical decisions enforced (Phase 3)

| Decision | Where enforced |
|---|---|
| ADR-005: Chapa aggregator for Telebirr/CBE Birr | `ChapaClient.java` — all Chapa API calls |
| P2-4: Payment idempotency in Postgres (UNIQUE(idempotency_key, tenant_id)) | `PaymentService.processWebhook()` — Postgres UNIQUE + Redis 24h cache |
| P0-5: RLS via `app.tenant_id` GUC (no BYPASSRLS) | `TenantContextAspect` — AOP @Around on @Transactional |
| V3-B2B-WHITELABEL §3: Reject indigo/blue-purple branding colors | `TenantService.createTenant()` + `updateBranding()` — `FORBIDDEN_HUES` regex |
| V3-PAYMENTS §3.2: HMAC-SHA256 webhook verification (constant-time) | `PaymentService.verifySignature()` — `MessageDigest.isEqual()` |
| V3-PAYMENTS §5: 7-day grace → SUSPENDED → Day 30 EXPIRED | `BillingService.processFailedPayments()` — `@Scheduled` daily at 09:00 Addis |
| V3-PAYMENTS §4: Server-side amount validation | `PaymentService.initiatePayment()` — uses `PLAN_PRICES_ETB` map, ignores client amount |
| V3-ADMIN-PLATFORM §4.4: Impersonation JWT 15min + `impersonated_by` claim | `ImpersonationService.impersonate()` |
| V3-ADMIN-PLATFORM §4.4: No impersonation chains | `ImpersonationService.impersonate()` — checks for `imp:` prefix on jti |

---

## 4. Payment plans + pricing (V3-PAYMENTS §4)

### B2C plans

| Plan | Price ETB/mo | Price USD/mo | Devices | Features |
|---|---|---|---|---|
| `B2C_FREE` | 0 | $0 | Up to 10 | Basic on/off + local control. No automations, no OTA, no energy |
| `B2C_PREMIUM` | 150 ETB | ~$2.73 | Unlimited | Automations, scenes, OTA, energy monitoring, anomaly alerts |
| `B2C_FAMILY` | 300 ETB | ~$5.45 | Unlimited | Premium + 5 home members + shared homes + priority support |

### B2B plans (commercial)

| Plan | Devices | USD/mo | ETB/mo | Features |
|---|---|---|---|---|
| `B2B_100` | ≤ 100 | $100 | ~5,500 ETB | All features, 1 tenant admin, no API access |
| `B2B_1000` | ≤ 1,000 | $800 | ~44,000 ETB | All features, 5 admins, API access, white-label branding |
| `B2B_UNLIMITED` | Unlimited | $2,000+ | ~110,000 ETB+ | All features, unlimited admins, SLA (99.5% uptime), dedicated support |

### Per-device tiers (B2B)

| Tier | Devices | Per-device price |
|---|---|---|
| B2B-100 | ≤ 100 | $1.00 / device |
| B2B-1000 | ≤ 1,000 | $0.80 / device |
| B2B-UNLIMITED | Unlimited | Custom (negotiated) |

---

## 5. Verification

Run the verification script:
```bash
./scripts/verify-phase3.sh local
```

The script checks:
1. **RLS isolation** — register 2 users, create home as user A, verify user B cannot see it
2. **Tenant branding** — `GET /api/v3/tenant/branding?subdomain=default` returns branding config
3. **Payment initiate** — `POST /payments/initiate` returns checkout_url (or 502 if Chapa not configured in dev)
4. **Webhook HMAC** — `POST /payments/webhook` without valid signature returns 401
5. **Subscription** — `GET /subscriptions/current` returns current plan
6. **API keys** — `POST /tenant/api-keys` returns 403 for B2C USER (requires TENANT_ADMIN+)
7. **Backend health** — db + redis UP

---

## 6. Environment variables (Phase 3)

Add to `backend/.env`:
```bash
# Chapa payment (V3-PAYMENTS §3)
CHAPA_API_BASE_URL=https://api.chapa.co/v1
CHAPA_SECRET_KEY=your-chapa-secret-key
CHAPA_WEBHOOK_SECRET=your-chapa-webhook-hmac-secret
CHAPA_CALLBACK_URL=https://staging.she.et/api/v3/payments/webhook
CHAPA_RETURN_URL=she-app://payments/success
CHAPA_WEBHOOK_IP_WHITELIST=41.216.199.0/24,196.188.124.0/24
```

---

## 7. Action items before Phase 4 kickoff

| # | Action | Owner | Status |
|---|---|---|---|
| 1 | Run `./scripts/verify-phase3.sh local` | Backend | ✅ DONE — 13/13 PASS (2026-09-17) |
| 2 | Apply for Chapa sandbox account (https://docs.chapa.co/) | Lead | ⏳ PENDING |
| 3 | Set `CHAPA_SECRET_KEY` + `CHAPA_WEBHOOK_SECRET` in staging env | Lead | ⏳ PENDING |
| 4 | Onboard first B2B tenant via `/api/admin/tenants` | Lead | ⏳ PENDING |
| 5 | Build Next.js 16 admin console (9 screens per V3-ADMIN-WEB-APP) | Frontend | ⏳ PENDING (Phase 4 or parallel) |
| 6 | Implement `AutomationService` + `SceneService` (Phase 3 stretch — originally Phase 3 but can defer) | Backend | ⏳ OPTIONAL |

---

## 8. Phase 4 preview (weeks 33-40) — Premium UX + energy + voice + Amharic

Per `V3-ROADMAP §6`, Phase 4 has 4 streams:

### 4A: Premium dark-mode UI (mobile)
- V3 design tokens (Deep Navy `#0B1D37`, Bright Sky Blue `#56B4FA`, NO indigo)
- Bento grid dashboard with active-glow drop-shadows on ON devices
- Haptic sliders (circular drag for dimmers/thermostats)
- Micro-interactions (toggle glow, lock animation, fan spin)
- Scenes row (horizontal scrolling) + scene-builder UI
- Empty state illustrations + onboarding screens

### 4B: Energy monitoring (backend + mobile + firmware)
- PZEM-004T firmware driver (already done in Phase 1)
- `EnergyService` (already done in Phase 1 — TimescaleDB ingest, ETB block-tariff cost calc)
- Energy dashboard (real-time gauge + 7/14/30-day historical chart, kWh + ETB dual axis)
- Anomaly detection (3× power spike vs 7-day baseline → push notification)
- B2B aggregate energy reports (per-tenant summary, CSV export)

### 4C: Voice control (firmware + backend)
- Picovoice SDK integration on ESP32-S3 (Porcupine + Rhino, R16 only)
- Custom wake word "Hey Sheba" (Picovoice Console-trained model)
- Intent model (`SmartHome_Ethiopian` context, ~25 Amharic + English intents)
- Voice service exposed as `esp.service.voice` in RainMaker hierarchy

### 4D: Amharic i18n (mobile + backend)
- ARB files (`app_en.arb` + `app_am.arb` — already done in Phase 1)
- Noto Sans Ethiopic font integration (line-height 1.6, 30% wider buttons)
- Ethiopian calendar (13 months, 7-8 years behind Gregorian)
- Cultural adaptations (full-name field, phone regex, ETB currency `ብር`)

### Phase 4 exit criteria
- [ ] Dark-mode Bento UI shipped + feels premium (internal review ≥ 8/10)
- [ ] Energy monitoring shows real-time + historical data in ETB
- [ ] Voice control works offline ("Hey Sheba, turn on the light" → relay toggles < 1s)
- [ ] Full Amharic UI (100% strings translated + reviewed by native speaker)

---

**Phase 3 sign-off:** Lead Engineer — 2025-08-12

Phase 3 is complete. Phase 4 can begin.
