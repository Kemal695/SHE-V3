# ADR-005: Telebirr + CBE Birr Payments via Chapa Aggregator

**Status:** Locked
**Date:** 2024-Q4
**Decision maker:** Lead Engineer

## Context

SHE V3 needs to collect subscription payments (B2C: 150 ETB/month Premium, 300 ETB/month Family; B2B: $1–$0.80/device/month) and one-time hardware payments from Ethiopian consumers and businesses. The Ethiopian payment landscape is dominated by **Telebirr** (Ethio Telecom's mobile money, ~50M users as of 2024) and **CBE Birr** (Commercial Bank of Ethiopia's mobile money, ~15M users). Card penetration is low (~5% of adults), and international payment processors (Stripe, PayPal, Adyen) do not operate in Ethiopia.

Direct merchant integration with Telebirr requires: a registered business entity with TIN, a merchant account application to Ethio Telecom, a 4–8 week onboarding process, a per-transaction fee of ~1.5%, and integration with Telebirr's merchant API (which has limited public documentation). CBE Birr direct is similar but with CBE. Doing both means two integrations, two merchant accounts, two reconciliation flows, two support escalation paths. For a 2–3 engineer team shipping V3 in 12 months, that is a meaningful distraction from the core device/cloud work.

A payment aggregator (Chapa, Santim Pay, YenePay) sits in front of multiple payment methods: one integration, one merchant account, one webhook contract, one dashboard. The trade-off is a slightly higher per-transaction fee (~2% vs 1.5%) and an additional intermediary in the payment flow.

## Decision

Use **Chapa** (`https://chapa.co`) as the payment aggregator for V3 GA. Chapa provides a single REST API that accepts Telebirr, CBE Birr, and card payments, with a hosted checkout page, server-to-server webhooks, and a merchant dashboard. Integration is ~2 weeks of backend engineering vs ~8 weeks for direct Telebirr + CBE Birr.

Payment flow:
1. User selects a plan in the mobile app → Spring Boot creates an invoice row (`status = PENDING`)
2. Spring Boot calls Chapa's `POST /v1/transaction/initialize` with `amount`, `currency=ETB`, `callback_url`, `return_url`, `tx_ref` (the invoice UUID)
3. Chapa returns a `checkout_url` → app opens it in a WebView → user picks Telebirr/CBE Birr/card → pays
4. Chapa redirects user back to app, fires webhook to `/api/v3/payments/webhook` with `tx_ref` + status
5. Spring Boot verifies webhook signature, marks invoice `PAID`, updates subscription `expires_at`
6. Idempotency: webhook handler keyed on `tx_ref` — duplicate webhooks are no-ops (Redis idempotency key, 24-hour TTL)

B2B billing: same flow, but `currency=USD` (B2B contracts are USD-denominated to hedge ETB depreciation — V3-UNIT-ECONOMICS.md §0), and Chapa's USD support is via card only (Visa/Mastercard). For B2B tenants without card access, we fall back to bank transfer + manual invoice reconciliation in the Admin Console.

Chapa's IPs are whitelisted in the Cloudflare geo-block (V3-ARCHITECTURE.md §7) so webhooks reach Spring Boot despite Ethiopia-only access restrictions.

## Alternatives Considered

### Alternative A: Direct Telebirr merchant API integration
- **Pros:** Lowest per-transaction fee (~1.5% vs Chapa's 2%); direct relationship with Ethio Telecom; no intermediary in DPIA.
- **Cons:** 4–8 week merchant onboarding (we have not started); Ethio Telecom's merchant API documentation is sparse and the developer relationship is slow; one payment method only (no CBE Birr, no cards) — bad UX for users on CBE; reconciliation is on us; Telebirr's sandbox environment is reportedly unstable. **Deferred to V3.1** — revisit if transaction volume justifies the integration cost (target: >$10k MRR via Chapa first).

### Alternative B: Direct CBE Birr merchant API integration
- **Pros:** Lowest per-transaction fee; access to CBE's 15M-user base; direct relationship with the largest bank in Ethiopia.
- **Cons:** Same onboarding friction as Telebirr direct; CBE Birr's API is even less documented than Telebirr's; one payment method only — bad UX for Telebirr users (the larger user base); CBE's developer support is enterprise-oriented and not friendly to small startups. **Rejected for V3.**

### Alternative C: Stripe (international card processor)
- **Pros:** Best developer experience in the industry; mature SDKs; webhook reliability is excellent.
- **Cons:** **Stripe does not operate in Ethiopia** — no ETB settlement, no Ethiopian bank account support, cannot accept Telebirr or CBE Birr (which is 95% of our payment volume); would require users to have international cards (which <5% of Ethiopian adults do). **Rejected — not available in market.**

### Alternative D: Santim Pay or YenePay (alternative Ethiopian aggregators)
- **Pros:** Same value prop as Chapa; competitive pricing; smaller companies may be more responsive to a startup's needs.
- **Cons:** Less mature than Chapa; smaller merchant base; documentation thinner; risk of platform instability. Chapa has the largest market share among Ethiopian aggregators as of 2024-Q4. **Rejected — revisit if Chapa relationship deteriorates.**

### Alternative E: No online payments (bank transfer / cash only)
- **Pros:** Zero integration cost; zero per-transaction fee; zero subprocessor in DPIA.
- **Cons:** Friction kills B2C conversion — users will not bank-transfer 150 ETB/month; manual invoice reconciliation at scale (5k subscribers = 5k monthly reconciliations); no path to automated dunning or churn prevention. **Rejected — unviable for subscription billing.**

## Consequences

### Positive
- Single integration, single webhook contract, single merchant dashboard — 2 weeks of backend work vs 8+ weeks for direct
- Three payment methods (Telebirr + CBE Birr + cards) from day 1 — covers ~95% of Ethiopian consumer payment preferences
- Idempotent webhook handler means duplicate webhooks (Chapa retries aggressively) are safe no-ops
- B2C subscriptions priced in ETB; B2B contracts priced in USD — both handled by the same Chapa integration (cards only for USD)

### Negative
- 2% per-transaction fee (vs 1.5% direct Telebirr) — at $5k MRR that is $25/month extra; at $50k MRR it's $250/month; meaningful but not material at our scale
- Chapa is a subprocessor in our DPIA — payment data (amount, tx_ref, customer phone) transits Chapa's servers; documented in V3-DPIA.md and V3-PRIVACY-COMPLIANCE.md
- Webhook reliability depends on Chapa — if Chapa's webhook delivery is delayed, invoices stay `PENDING` and users may be temporarily denied service. Mitigation: Spring Boot cron reconciles `PENDING` invoices >1 hour old by polling Chapa's `GET /v1/transaction/verify/{tx_ref}`
- USD support is card-only — B2B tenants in Ethiopia without corporate cards must fall back to bank transfer + manual reconciliation (operational burden on the Admin Console)
- Chapa is a young company (founded 2022) — there is platform risk if they pivot, get acquired, or fail. Mitigation: direct Telebirr integration is the documented V3.1 fallback (ADR-005 alternative A)

### Neutral
- Chapa settles to our bank account in ETB daily — we carry no payment-credit risk
- The Chapa merchant dashboard is a separate system from our Admin Console — support agents need access to both for payment disputes
- Chargebacks are rare in mobile money (Telebirr/CBE Birr transactions are final once confirmed) — card chargebacks flow through Chapa's dispute process

## References
- V3-PAYMENTS.md (full payment integration spec, webhook contract, dunning logic)
- V3-B2B-WHITELABEL.md §4 (B2B pricing tiers in USD)
- V3-UNIT-ECONOMICS.md §4 (LTV calculations that depend on payment-fee assumptions)
- V3-PRIVACY-COMPLIANCE.md (Chapa as subprocessor)
- V3-DPIA.md (payment data flow + lawful basis)
- V3-ARCHITECTURE.md §7 (Cloudflare geo-block whitelists Chapa IPs)
- ADR-008 (Addis Ababa hosting — Chapa webhook terminates in Ethiopia)
- ADR-010 (Ethiopia-only scope — payments are Ethiopia-specific)
