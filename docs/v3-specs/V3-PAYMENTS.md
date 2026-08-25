# V3 — Payments (Telebirr via Chapa)

**Status:** Locked
**Last updated:** 2024-Q4
**Owner:** Backend Engineer

---

## 0. Scope

Payment integration for B2B subscriptions and B2C premium features. Primary payment methods: Telebirr (Ethio Telecom mobile money) and CBE Birr (Commercial Bank of Ethiopia), accessed via the **Chapa payment aggregator** (single API for all methods). Bank transfer is supported for large B2B.

> **Decision (ADR-005):** Use Chapa aggregator for V3 GA — single API for Telebirr + CBE Birr + cards. Switch to direct Telebirr API in V3.1 if transaction volume justifies the integration effort.

---

## 1. Payment methods

| Method | Use case | Fee | Settlement | Chapa-supported |
|---|---|---|---|---|
| Telebirr | B2C subscriptions, small B2B | 1.5% | T+1 | Yes |
| CBE Birr | Medium B2B | 1.0% | T+2 | Yes |
| Cards (Visa/Mastercard) | International B2B, diaspora | 2.5% | T+3 | Yes |
| Bank transfer | Large B2B (NET-30) | Flat 50 ETB | T+3 | No (manual reconciliation) |
| **Chapa (aggregator)** | **All above via single API** | **2.0% blended** | **T+1** | — |

---

## 2. Pricing model

### 2.1 B2C plans (consumer)

| Plan | Price (ETB/mo) | Price (USD/mo, ~55 ETB/$) | Devices | Features |
|---|---|---|---|---|
| **B2C Free** | 0 | $0 | Up to 10 | Basic on/off control + local control. No automations, no OTA, no energy dashboard. |
| **B2C Premium** | 150 ETB | ~$2.73 | Unlimited | All features: automations, scenes, OTA, energy monitoring, anomaly alerts |
| **B2C Family** | 300 ETB | ~$5.45 | Unlimited | Premium + 5 home members + shared homes + priority support (Tier 1 → 2 → Eng escalation) |

### 2.2 B2B plans (commercial)

| Plan | Devices | Price/mo (USD) | Price/mo (ETB, ~55 ETB/$) | Features |
|---|---|---|---|---|
| **B2B-100** | ≤ 100 | $100 | ~5,500 ETB | All features, 1 tenant admin, no API access |
| **B2B-1000** | ≤ 1,000 | $800 | ~44,000 ETB | All features, 5 admins, API access, white-label branding |
| **B2B-UNLIMITED** | Unlimited | $2,000+ | ~110,000 ETB+ | All features, unlimited admins, SLA (99.5% uptime), dedicated support |

See V3-B2B-WHITELABEL.md §4 for plan-change + proration rules + lifecycle.

---

## 3. Chapa integration flow

### 3.1 Initiate payment

```
Flutter app → "Subscribe to Premium"
    │
    ▼
POST /api/v3/payments/initiate
   Authorization: Bearer <JWT>
   Body: { "plan": "B2C_PREMIUM", "amount_etb": 150, "callback_url": "https://she.et/payments/callback" }
    │
    ▼
Spring Boot:
   1. Validate plan + price (server-side — never trust client-supplied amount)
   2. INSERT INTO payments (id, tenant_id, amount_etb, plan, status='PENDING', chapa_ref=uuid)
   3. POST https://api.chapa.co/v1/transaction/initialize
        Headers: Authorization: Bearer <CHAPA_SECRET_KEY>
        Body: {
          "amount": "150.00",
          "currency": "ETB",
          "email": "user@example.et",
          "first_name": "Abebe",
          "last_name": "Bekele",
          "tx_ref": "<payment.id>",
          "callback_url": "https://she.et/payments/callback",
          "return_url": "she-app://payments/success",
          "customization": {"title": "SHE Premium", "description": "Monthly subscription"}
        }
   4. Receive checkout_url from Chapa
   5. Return checkout_url to Flutter app
    │
    ▼
Flutter app opens checkout_url in in-app browser (flutter_web_auth_2)
    │
    ▼
User pays via Telebirr / CBE Birr / card on Chapa-hosted page
```

### 3.2 Webhook (server-to-server)

Chapa sends a webhook to Spring Boot when payment is confirmed:

```
POST /api/v3/payments/webhook
   Headers: X-Chapa-Signature: <HMAC-SHA256 of body>
   Body: {
     "event": "charge.success",
     "tx_ref": "<payment.id>",
     "amount": "150.00",
     "currency": "ETB",
     "status": "success",
     "reference": "<chapa-internal-ref>"
   }
    │
    ▼
Spring Boot:
   1. Verify HMAC-SHA256 signature (constant-time compare — reject if mismatch → PAYMENT_WEBHOOK_INVALID_SIGNATURE)
   2. Idempotency check (payment.id already processed? → PAYMENT_ALREADY_PROCESSED)
   3. Verify amount matches payment record (reject if mismatch → PAYMENT_AMOUNT_INVALID)
   4. UPDATE payments SET status='SUCCESS', chapa_ref=<reference>, paid_at=NOW()
   5. INSERT INTO subscriptions (...) or extend existing subscription expires_at by 30 days
   6. WebSocket push: "subscription_activated" → app unlocks premium features
   7. Audit log: "payment.completed" event
```

### 3.3 Verify (defensive)

Even after webhook, Spring Boot calls Chapa verify API as a defensive check:

```
GET https://api.chapa.co/v1/transaction/verify/<tx_ref>
   Headers: Authorization: Bearer <CHAPA_SECRET_KEY>
   → 200 OK with { "status": "success", "amount": "150.00", ... }
```

If verify fails after webhook reported success (rare — Chapa API issue), log a SEV-2 alert but do NOT revoke the subscription (assume webhook was correct).

---

## 4. Database schema

```sql
-- V14 migration
CREATE TABLE payments (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id   UUID NOT NULL REFERENCES tenants(id),
    user_id     UUID REFERENCES users(id),    -- null for B2B (tenant-level payment)
    amount_etb  DECIMAL(10,2) NOT NULL,
    plan        VARCHAR(20) NOT NULL,         -- B2C_FREE | B2C_PREMIUM | B2C_FAMILY | B2B_100 | B2B_1000 | B2B_UNLIMITED
    status      VARCHAR(20) NOT NULL DEFAULT 'PENDING',  -- PENDING | SUCCESS | FAILED | REFUNDED
    chapa_ref   VARCHAR(100) UNIQUE,           -- Chapa's internal transaction reference
    checkout_url TEXT,
    paid_at     TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- RLS
    CONSTRAINT payments_tenant_check CHECK (tenant_id IS NOT NULL)
);
ALTER TABLE payments ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON payments
    USING (tenant_id = current_setting('app.tenant_id')::uuid);

CREATE TABLE subscriptions (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id   UUID NOT NULL REFERENCES tenants(id),
    user_id     UUID REFERENCES users(id),    -- null for B2B
    plan        VARCHAR(20) NOT NULL,
    status      VARCHAR(20) NOT NULL,         -- ACTIVE | SUSPENDED | EXPIRED | CANCELLED
    started_at  TIMESTAMPTZ NOT NULL,
    expires_at  TIMESTAMPTZ,                  -- null = perpetual (B2C Free)
    payment_id  UUID REFERENCES payments(id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON subscriptions
    USING (tenant_id = current_setting('app.tenant_id')::uuid);
```

**Retention:** `payments` retained 7 years (Ethiopian tax law). `subscriptions` retained 2 years after expiry, then archived.

---

## 5. B2B billing flow

```
Tenant signs contract (e.g., B2B-1000: 1000 devices, $800/month)
    │
    ▼
Spring Boot generates first invoice on tenant activation
    │
    ▼
Each month on the 25th: Spring Boot @Scheduled task generates invoice
   - Email to tenant admin (PDF attachment)
   - INSERT INTO payments (status='PENDING', amount_etb=44000, plan='B2B_1000')
    │
    ▼
Tenant pays via Chapa (Telebirr/CBE Birr) or bank transfer
    │
    ▼
If Chapa: webhook fires → subscription extended 30 days → audit log
If bank transfer: tenant admin uploads proof → SUPER_ADMIN marks paid via /admin/billing/invoices/{id}/mark-paid
    │
    ▼
If unpaid after 7 days grace:
   - Subscription SUSPENDED (users can't login to app)
   - Devices still work (safety — do not turn off lights; MQTT + automations continue)
   - Escalation email to tenant admin + platform admin
   - Daily reminder emails
    │
    ▼
If unpaid after 30 days: tenant TERMINATED (V3-B2B-WHITELABEL.md §7 lifecycle)
```

---

## 6. B2C freemium flow

B2C users pay via Telebirr in the mobile app (Chapa checkout, instant activation):

```
Settings → Subscription → "Upgrade to Premium" (or Family)
    │
    ▼
App calls POST /api/v3/payments/initiate (plan=B2C_PREMIUM, amount_etb=150)
    │
    ▼
Chapa checkout URL returned → app opens in-app browser
    │
    ▼
User pays via Telebirr → Chapa webhook → Spring Boot verifies → subscription activated
    │
    ▼
WebSocket push: "subscription_activated" → app unlocks premium features immediately
```

**Proration:** If user upgrades from Premium (150 ETB) to Family (300 ETB) mid-cycle, the unused Premium days are credited to the next invoice. If user downgrades, the new plan takes effect at next billing cycle (no refund for current cycle).

---

## 7. Invoice generation

Spring Boot `InvoiceService` generates PDF invoices (using Apache PDFBox):

- Header: SHE logo, tenant name, tenant address, invoice number, invoice date
- Line items: plan name, billing period (from-to), amount ETB
- Subtotal, VAT (15% Ethiopian VAT where applicable — B2B only), total
- Payment instructions: Chapa checkout URL or bank details (for bank transfer)
- Footer: "Thank you for your business" + support contact

Invoices stored in MinIO at `s3://she-invoices/{tenant_id}/{invoice_id}.pdf`. Accessible via `/admin/billing/invoices/{id}/pdf`.

---

## 8. Refund + dispute handling

| Scenario | Process | Timeline |
|---|---|---|
| Cancel within 7 days (B2C) | Full refund via Chapa API (`POST /v1/transaction/refund/<tx_ref>`) | 3-5 business days |
| Tenant overbilled (B2B) | Manual refund + credit to next month | 5-10 business days |
| Chargeback / fraud | Disable account, investigate, escalate to SUPER_ADMIN | Per case |
| Failed payment retry | 3 retries over 7 days (day 1, 3, 7), then suspend | 7 days |
| Duplicate payment | Detect via idempotency key (payment.id), auto-refund the duplicate | 1-2 business days |

---

## 9. Failed payment retry

Spring Boot `@Scheduled` task (daily at 09:00 Addis time) checks for `payments` with `status='PENDING'` and `created_at < NOW() - INTERVAL 'X days'`:

| Day | Action |
|---|---|
| 1 | Send reminder email + push notification |
| 3 | Send reminder email + in-app banner |
| 7 | Suspend subscription (users can't login); email + push notification |
| 30 | Terminate tenant (B2B) or expire subscription (B2C) |

Retry attempts:
- Day 1: Chapa auto-retry (if user saved payment method — rare in Ethiopia; most users re-auth each time)
- Day 3: Re-initiate payment (new `payments` row, new checkout URL, email to user)

---

## 10. Reconciliation

Daily at 02:00 UTC, Spring Boot `@Scheduled` task reconciles:

1. Fetch all `payments` with `status='SUCCESS'` and `paid_at` in last 24 h
2. For each, call Chapa verify API to confirm
3. If verify fails: log SEV-2 alert + audit log entry `payment.reconciliation_failed`
4. Daily reconciliation report emailed to SUPER_ADMIN

Monthly reconciliation (1st of month):
1. Sum all `payments.amount_etb` for previous month
2. Compare against Chapa settlement reports (CSV download from Chapa dashboard)
3. Investigate any discrepancies > 100 ETB

---

## 11. Security

- **Chapa secret key:** stored in Spring Boot `application-prod.properties` (loaded from environment variable `CHAPA_SECRET_KEY`), never committed to git
- **Webhook signature:** HMAC-SHA256 verified with constant-time compare (`MessageDigest.isEqual`)
- **Idempotency:** `payments.id` (UUID) used as `tx_ref` sent to Chapa; webhook dedupes on `tx_ref`

### 6.4 Payment idempotency — Postgres as source of truth (not Redis)

**Critical:** Payment idempotency keys MUST be stored in **Postgres** (via `UNIQUE(idempotency_key, tenant_id)` constraint on the `payments` table), NOT in Redis. Redis is used as a **cache layer only** (fast pre-check to avoid hitting Postgres on every duplicate webhook), but Postgres is the source of truth.

**Why not Redis-only for payment idempotency:**
- Redis persistence is configured as AOF every 1s with no `fsync` (V3-ARCHITECTURE.md §5.3) — a 1-second data-loss window is acceptable for sessions and rate-limit counters (rebuildable), but NOT for payment idempotency
- A Chapa webhook burst during a Redis failover or AOF flush window could cause a duplicate payment to be processed (idempotency key lost) → real money impact, refund workflow, customer support load
- Postgres `UNIQUE` constraint is atomic, durable, and survives crashes — the correct primitive for financial idempotency

**Flow:**
1. Chapa webhook arrives → Spring Boot extracts `tx_ref` (= `payments.id`)
2. Redis pre-check: `GET idempotency:{tx_ref}` — if hit, return cached `200 OK` (fast path, avoids Postgres load)
3. Redis miss → `INSERT INTO payments (id, idempotency_key, ...) VALUES (...)` — if `UNIQUE` violation → duplicate, return `200 OK` with existing payment
4. On successful insert → `SET idempotency:{tx_ref} = {payment_id}` with 24h TTL (cache for future duplicates)
5. Process payment, update `payments.status`

**Schema (already in V3-DATABASE-DESIGN.md `payments` table, restated here for clarity):**
```sql
ALTER TABLE payments ADD COLUMN idempotency_key VARCHAR(36);
CREATE UNIQUE INDEX payments_idempotency_unique
  ON payments (tenant_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;
```

The `WHERE idempotency_key IS NOT NULL` allows non-idempotent writes (manual admin adjustments) to have NULL.
- **Amount validation:** Server validates amount matches plan price (never trusts client-supplied amount in `/api/v3/payments/initiate`)
- **Callback URL:** HTTPS only; `return_url` uses custom app scheme (`she-app://`) for in-app browser redirect
- **PII:** Payment page is hosted by Chapa (PCI-DSS scope) — SHE never sees card numbers. Only sees `chapa_ref` + amount + status.

---

## 12. References

- V3-B2B-WHITELABEL.md §4 — full pricing model (B2C + B2B)
- V3-UNIT-ECONOMICS.md §4 — B2C + B2B LTV / CAC model + margins
- V3-SUPPORT-RMA.md §3 — support tiers for Family plan priority support
- V3-ADMIN-PLATFORM.md §4.6 — billing admin API endpoints
- V3-ERROR-CODES.md §8 — `PAYMENT_*` error codes
- V3-MOBILE-APP.md §10 — Flutter payment flow
- V3-PRIVACY-COMPLIANCE.md §4 — payment data retention (7 years per Ethiopian tax law)
- ADR-005 — Telebirr via Chapa decision
- Chapa API docs: https://docs.chapa.co/
