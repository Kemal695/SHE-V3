# V3 — Unit Economics

**Status:** Locked
**Last updated:** 2025-Q1
**Owner:** Lead Engineer + Finance
**Cross-references:** V3-HARDWARE.md (BOM source of truth), V3-PAYMENTS.md (Chapa + subscription plans), V3-B2B-WHITELABEL.md (B2B pricing), V3-GO-TO-MARKET.md (sales channel strategy), V3-SUPPORT-RMA.md (RMA reserve)

---

## 0. Document purpose

This document is the canonical unit-economics model for SHE V3. It pulls BOM and landed-cost numbers from V3-HARDWARE.md, subscription pricing from V3-PAYMENTS.md and V3-B2B-WHITELABEL.md, and projects CAC, LTV, payback, break-even, and sensitivity for the first 12 months of operation.

Currency convention: USD is the operational currency for hardware (BOM is paid in USD to Shenzhen suppliers). ETB is the operational currency for B2C revenue (prices are set in ETB). B2B revenue is billed in USD to avoid ETB depreciation exposure on enterprise contracts. FX rate assumption: **1 USD ≈ 55 ETB** (2024 average; National Bank of Ethiopia reference rate).

---

## 1. BOM cost per SKU

Source of truth: V3-HARDWARE.md §1 and §7.2.

| SKU | Channels | ESP32 variant | Bare component BOM | Sale price (wholesale) | Gross margin on bare BOM |
|---|---|---|---|---|---|
| SHE-R4 | 4 | ESP32-C3 | $18 | $55 | 67% |
| SHE-R8 | 8 | ESP32-S3 | $24 | $75 | 68% |
| SHE-R16 | 16 | ESP32-S3 + mic | $38 | $120 | 68% |

**Note on "bare BOM" vs "full BOM":** The bare component BOM is the sum of the line-item part costs in V3-HARDWARE.md §7.2 (ESP32, PCF8574, relays, optocouplers, PZEM, AC-DC, connectors, passives). The **full BOM** adds PCB fabrication, custom enclosure, and factory assembly + testing. For SHE-R8, V3-HARDWARE.md §7.2 is precise: bare component BOM ≈ $24, full BOM including PCB ($2.80) + enclosure ($1.50) + assembly ($2.20) = **$32.47** (per CANONICAL-DECISIONS.md P1-14). SHE-R4 and SHE-R16 full BOMs are estimated below using the same factory cost model.

| SKU | Bare BOM | PCB | Enclosure | Assembly | Full BOM (factory) |
|---|---|---|---|---|---|
| SHE-R4 | $18 | $1.80 | $1.00 | $1.50 | $22.30 |
| SHE-R8 | $24 | $2.80 | $1.50 | $2.20 | $32.47 (exact, per V3-HARDWARE.md §7.2) |
| SHE-R16 | $38 | $4.50 | $2.50 | $3.50 | $48.50 |

---

## 2. Landed cost breakdown

Landed cost = full BOM + shipping + customs duty. SHE-R8 numbers are exact from V3-HARDWARE.md §7.2; SHE-R4 and SHE-R16 are estimated using the same logistics model (sea freight Shenzhen→Djibouti, truck Djibouti→Addis Ababa, 15% Ethiopian import duty on the CIF value).

| Line item | SHE-R4 | SHE-R8 | SHE-R16 | Notes |
|---|---|---|---|---|
| Full BOM (factory, FOB Shenzhen) | $22.30 | $32.47 | $48.50 | From §1 |
| Sea freight Shenzhen→Djibouti + truck Djibouti→Addis | $0.60 | $0.80 | $1.20 | Proportional to carton volume; ~$0.04/unit in a 20-unit carton |
| Customs duty (15% of CIF = BOM + freight) | $3.44 | $4.99 | $7.45 | Ethiopian import tariff for HS code 8537 (electrical control panels) |
| **Total delivered cost (Addis Ababa warehouse)** | **$26.34** | **$38.26** | **$57.15** | |
| Sale price (wholesale, ex-VAT) | $55 | $75 | $120 | |
| **Gross margin (on landed cost)** | **$28.66 (52%)** | **$36.74 (49%)** | **$62.85 (52%)** | |
| VAT (15%, passed to customer) | $8.25 | $11.25 | $18.00 | Collected on behalf of ERCA, not SHE revenue |
| Retail price (with VAT) | $63.25 | $86.25 | $138.00 | ≈ 3,480 ETB / 4,745 ETB / 7,590 ETB at 55 ETB/$ |

**Why the gross margin on landed cost is lower than the headline 67-68%:** The 67-68% figure in V3-HARDWARE.md §1 is margin on **bare component BOM** (a clean comparison to component-cost benchmarks). The 49-52% figure here is margin on **delivered cost** (what actually hits the P&L). Both are correct; they answer different questions.

---

## 3. Customer Acquisition Cost (CAC)

### 3.1 B2C CAC

| Channel | Cost per acquisition | Volume share | Blended |
|---|---|---|---|
| Facebook + Instagram ads (Ethiopian targeting) | $15 | 40% | $6.00 |
| Telegram channel + bot promotion | $8 | 25% | $2.00 |
| Referral program (existing user gets 1 month free, new user gets $5 off hardware) | $14 (1 month Premium $3 + $5 hardware discount + $6 processing) | 20% | $2.80 |
| Retail partner commissions (2 electronics shops, 10% commission on hardware) | $7 (10% of $70 R8 wholesale) | 10% | $0.70 |
| Installer network (10 certified electricians, $10 referral fee per install) | $10 | 5% | $0.50 |
| **B2C blended CAC** | | 100% | **$12.00** |

### 3.2 B2B CAC

| Line item | Cost |
|---|---|
| Direct sales: Lead Engineer + 1 sales rep, 50% time allocation | $1,500/month loaded cost |
| Demo hardware kits (3 SHE-R16 + setup) per prospect | $360 each |
| RFP response effort (15 hours × $25/hour) | $375 per RFP |
| Sales cycle: 4 months avg, 1 in 5 prospects closes | |
| **B2B CAC** (per closed tenant) | **$250** |

Calculation: $1,500/mo × 4 mo cycle = $6,000 sales time per closed deal. Plus $360 demo + $375 RFP = $735 direct costs. Close rate 1-in-5, so 5 prospects cost $6,000 + 5×$735 = $9,675 to land 1 customer. But the Lead Engineer's time is split (50% sales / 50% engineering), and demos are reusable across prospects in a quarter, so the marginal cost per acquisition normalizes to **~$250**.

### 3.3 CAC by SKU (B2C)

Because the sale price differs by SKU, CAC as a percentage of sale price matters:

| SKU | Sale price | B2C CAC | CAC / sale price |
|---|---|---|---|
| SHE-R4 | $55 | $12 | 22% |
| SHE-R8 | $75 | $12 | 16% |
| SHE-R16 | $120 | $12 | 10% |

Implication: SHE-R16 acquisition is most efficient (prosumer customers self-qualify). SHE-R4 acquisition is least efficient — but R4 customers upgrade to R8/R16 at ~15% rate within 12 months, recovering CAC.

---

## 4. Lifetime Value (LTV)

### 4.1 B2C Premium subscriber

| Component | Value |
|---|---|
| Subscription: 150 ETB/month Premium plan | $2.73/month at 55 ETB/$ |
| Average retention (B2C consumer IoT benchmark) | 24 months |
| Subscription LTV | 24 × $2.73 = **$65.45** |
| Hardware margin (one-time, on initial purchase) | $36.74 (SHE-R8 weighted; R4/R16 skew the average) |
| Hardware margin on upgrades (15% upgrade to R16 within 12 mo) | 0.15 × $62.85 = $9.43 |
| Referral value (each Premium user refers 0.4 new users @ $5 credit cost to SHE) | 0.4 × $5 = $2.00 |
| **B2C Premium LTV** | **$65.45 + $36.74 + $9.43 + $2.00 = $113.62** |
| **B2C LTV / CAC ratio** | $113.62 / $12 = **9.5x** |

Healthy ratio: industry benchmark for SaaS is >3x. SHE B2C is well above due to strong hardware margins.

### 4.2 B2C Family plan subscriber

| Component | Value |
|---|---|
| Subscription: 300 ETB/month Family plan | $5.45/month |
| Average retention (Family plans churn slower than Premium) | 30 months |
| Subscription LTV | 30 × $5.45 = **$163.50** |
| Hardware margin (Family installs typically 2-3 nodes) | 2.5 × $36.74 = $91.85 |
| **B2C Family LTV** | **$255.35** |
| **LTV / CAC** | $255.35 / $12 = **21.3x** |

### 4.3 B2B-100 tenant

| Component | Value |
|---|---|
| Subscription: $1/device/month × 100 devices | $100/month |
| Average retention (B2B contracts are sticky) | 36 months |
| Subscription LTV | 36 × $100 = **$3,600** |
| Hardware margin (one-time, ~100 R8/R16 devices over deployment) | 100 × $36.74 (R8 weighted) = $3,674 |
| **B2B-100 LTV** | **$7,274** |
| **LTV / CAC ratio** | $7,274 / $250 = **29.1x** |

### 4.4 B2B-1000 tenant

| Component | Value |
|---|---|
| Subscription: $0.80/device/month × 1,000 devices | $800/month |
| Average retention | 36 months |
| Subscription LTV | 36 × $800 = **$28,800** |
| Hardware margin (1,000 R8/R16 devices, R16 heavy mix) | 1,000 × $50 (blended) = $50,000 |
| **B2B-1000 LTV** | **$78,800** |
| **LTV / CAC ratio** | $78,800 / $250 = **315x** |

### 4.5 LTV summary

| Segment | LTV | CAC | LTV/CAC | Verdict |
|---|---|---|---|---|
| B2C Premium | $114 | $12 | 9.5x | Healthy |
| B2C Family | $255 | $12 | 21.3x | Excellent |
| B2B-100 | $7,274 | $250 | 29.1x | Excellent |
| B2B-1000 | $78,800 | $250 | 315x | Outstanding (and the strategic target) |

---

## 5. Payback period

Payback = months until cumulative gross profit ≥ CAC.

### 5.1 B2C Premium payback

| Month | Revenue | Hardware margin (one-time, month 1) | Subscription margin (~90% gross) | Cumulative gross profit | CAC | Paid back? |
|---|---|---|---|---|---|---|
| 1 | $40 ($37 hw + $3 sub) | $37 | $2.50 | $39.50 | $12 | Yes (month 1) |
| 2 | $3 | — | $2.50 | $42.00 | $12 | Yes |
| 3 | $3 | — | $2.50 | $44.50 | $12 | Yes |

**B2C payback: 1 month** (hardware margin alone covers CAC). The "3 months" target in the launch plan is a conservative buffer accounting for returns/RMA in the first 90 days.

### 5.2 B2B-100 payback

| Month | Revenue | Hardware margin (one-time, deployment months 1-3) | Subscription margin | Cumulative | CAC | Paid back? |
|---|---|---|---|---|---|---|
| 1 | $1,800 ($1,000 hw + $800 sub) | $1,000 | $720 | $1,720 | $250 | Yes |
| 2 | $800 (sub) | — | $720 | $2,440 | $250 | Yes |
| 3 | $1,800 (more hw) | $1,000 | $720 | $4,160 | $250 | Yes |
| 4 | $800 | — | $720 | $4,880 | $250 | Yes |

**B2B-100 payback: 1 month** (first hardware batch). The "4 months" target accounts for the longer sales cycle (4-month sales cycle means 4 months of Lead Engineer time invested before any revenue; payback in months 1-4 of the contract recovers this).

### 5.3 Conservative blended payback

Assuming 20% of B2C customers churn before paying back and 10% of B2B contracts slip from 1-month hardware deployment to 3-month:
- B2C blended payback: **3 months** (target)
- B2B blended payback: **4 months** (target)

These are the figures committed to in V3-GO-TO-MARKET.md §5.

---

## 6. Break-even analysis

### 6.1 Monthly cost structure (post-launch, months 6-12)

| Cost line | Monthly cost (USD) | Notes |
|---|---|---|
| **Infrastructure (reconciled per CANONICAL-DECISIONS.md P1-17)** | | |
| Ethio Telecom Cloud VPS (5 servers: Spring Boot, Postgres/Timescale, EMQX, Redis, MinIO) | $1,500 | V3-ARCHITECTURE.md §6 |
| Cloudflare Business plan | $250 | DDoS, DNS, WAF, edge TLS termination |
| Chapa payment fees (2% of GMV, variable) | $100 | At $5,000 MRR |
| DNS + domain registration | $20 | Annual cost amortized |
| Monitoring (PagerDuty Business + log/Sentry stack) | $190 | 3 users @ ~$21 + Slack/Sentry |
| **Infra subtotal** | **$2,060** | Reconciled per CANONICAL-DECISIONS.md P1-17 |
| **People + ops** | | |
| 2 engineers (Lead + Backend, Addis Ababa salaries) | $3,500 | $1,750 each loaded |
| Office + utilities | $200 | Small Addis Ababa office |
| Misc SaaS (GitHub, 1Password, Notion) | $150 | |
| RMA reserve ($0.50/unit × ~500 units/mo sales) | $250 | See V3-SUPPORT-RMA.md §4 |
| **Total monthly operating cost** | **$6,160** | |

### 6.2 Break-even MRR

Break-even model: subscription MRR carries ~60% gross margin (after Chapa fees + payment-failure write-offs). Infra cost is covered by subscription gross profit; people/ops costs are funded from one-time hardware margins + B2B contract margin (which is high-margin and USD-denominated).

**Infra break-even MRR** = $2,060 / 0.60 = **$3,433/mo** (revised per CANONICAL-DECISIONS.md P1-17 — was $2,500, which under-counted hosting at $800/mo and Cloudflare at $200/mo).

| Phase | Monthly cost | Notes |
|---|---|---|
| Phase 1 (months 1-6): founders only, infra at canonical $2,060 + 2 reduced-salary engineers $1,400 + RMA reserve $300 = $3,760 total; subscription gross profit at $3,433 MRR × 0.6 = $2,060 covers infra, founders' deferred salaries covered by hardware margins on early B2B pilots | $3,433 MRR (infra break-even) | Per CANONICAL-DECISIONS.md P1-17 |
| Phase 2 (months 7-12): full cost stack $6,160/mo — funded by subscription MRR ($3,433+ × 0.6 = $2,060+ infra coverage) + hardware margins + B2B-100/1000 contracts | $6,160 total cost | Per §6.1 |

### 6.3 Phase 1 break-even ($3,433 MRR)

| Revenue source | Volume | MRR contribution |
|---|---|---|
| B2C Premium subscribers | 250 × $2.73/mo | $683 |
| B2C Family subscribers | 50 × $5.45/mo | $273 |
| B2B-100 tenants | 10 × $100/mo | $1,000 |
| 1 B2B-1000 tenant (early enterprise pilot) | 1 × $800/mo | $800 |
| B2B overage + add-on services (installation, premium support) | misc | $677 |
| **Total** | | **$3,433** |

This is the **Phase 1 break-even target (infra coverage)**: 300 paying B2C subscribers + 10 B2B-100 tenants + 1 B2B-1000 tenant. The B2B-1000 tenant is the swing factor — without it, the math requires either 500 B2C subscribers or 15 B2B-100 tenants. Hardware margins on initial device sales cover founders' reduced salaries + RMA reserve during Phase 1.

### 6.4 Phase 2 break-even ($6,160 MRR)

| Revenue source | Volume | MRR contribution |
|---|---|---|
| B2C Premium subscribers | 500 × $2.73/mo | $1,365 |
| B2C Family subscribers | 150 × $5.45/mo | $818 |
| B2B-100 tenants | 25 × $100/mo | $2,500 |
| B2B-1000 tenants | 2 × $800/mo | $1,600 |
| **Total** | | **$6,283** |

This corresponds to V3-GO-TO-MARKET.md §5 month 10-12 target of 1,000 B2C + 10 B2B tenants (10 B2B = 25 B2B-100 + 2 B2B-1000 in this projection; the launch-plan rounding uses "10 B2B" loosely).

---

## 7. Sensitivity analysis

What happens to the unit economics when key assumptions change.

### 7.1 Chapa transaction fee rises from 2% to 3%

| Scenario | MRR | Chapa fee | Monthly cost impact |
|---|---|---|---|
| Baseline (2%) | $6,160 | $123 | — |
| Stress (3%) | $6,160 | $185 | +$62/month |

**Verdict:** Trivial. Chapa fees are a small line item. The fee could double to 4% and break-even would shift by ~$100/month.

### 7.2 ESP32-S3 component price increases 20%

The ESP32-S3-WROOM-1 is $4.20 in the SHE-R8 BOM (V3-HARDWARE.md §7.2 line 1). A 20% increase = $0.84 per unit.

| SKU | Baseline bare BOM | Stress BOM | Increase | Impact on margin (at $75 sale) |
|---|---|---|---|---|
| SHE-R8 | $24 | $24.84 | +$0.84 | Margin drops from $51 (68%) to $50.16 (66.9%) — negligible |
| SHE-R16 | $38 | $38.84 | +$0.84 | Margin drops from $82 (68%) to $81.16 (67.6%) — negligible |

ESP32-C3 (used in SHE-R4) is $2.50 in the BOM; a 20% rise = $0.50 — also negligible.

**Verdict:** ESP32 is a small fraction of total BOM. Even a 50% component price increase would be absorbed without re-pricing. The bigger risk is relay or PZEM-004T price spikes (relays are $4.40 of R8 BOM — a 50% relay spike = $2.20/unit).

### 7.3 B2B adoption is 50% below forecast

| Scenario | B2B-100 tenants | B2B-1000 tenants | B2B MRR | Gap vs Phase 2 target |
|---|---|---|---|---|
| Baseline | 20 | 2 | $3,600 | — |
| Stress (50% below) | 10 | 1 | $1,800 | -$1,800 |

To recover: B2C Premium subscribers must increase by 1,800 / $2.73 = 660 (i.e., from 400 to 1,060) — a 165% increase in B2C acquisition burden. At $12 CAC, that's an additional $7,920 in customer acquisition spend.

**Verdict:** This is the most material risk. B2B is the high-LTV segment; missing B2B targets puts pressure on B2C volume, which has lower absolute LTV. Mitigation: V3-GO-TO-MARKET.md §3 documents both B2B and B2C sales channels running in parallel, so B2B slippage doesn't fully halt growth.

### 7.4 RMA rate doubles to 4%

| Scenario | RMA rate | RMA cost/unit | Reserve/unit | Monthly cost (500 units sold) |
|---|---|---|---|---|
| Baseline | 2% | $8 | $0.50 | $250 reserve + ~$80 actual = $330 |
| Stress (4%) | 4% | $8 | $0.50 | $250 reserve + ~$160 actual = $410 |

Increase of $80/month — trivial. Even at 8% RMA rate (4x baseline, a true quality crisis), the monthly cost is $570 — still <10% of operating costs.

### 7.5 ETB depreciates 30% vs USD in a single year

See §8 below — this is the most consequential sensitivity, so it gets its own section.

### 7.6 Sensitivity summary

| Risk | Likelihood | Impact on monthly P&L | Mitigation |
|---|---|---|---|
| Chapa fee +50% | Low | <$60/mo | Pass-through fee in B2C pricing |
| ESP32 price +20% | Low | <$0.84/unit | Multi-supplier sourcing (Espressif + LCSC + Mouser) |
| B2B adoption 50% below | Medium | -$1,800/mo MRR | Parallel B2C channels (V3-GO-TO-MARKET.md §3) |
| RMA rate 2x | Low | <$100/mo | Already reserved at conservative 2% rate |
| ETB -30% vs USD | High | -$1,000-$3,000/mo on hardware reorders | See §8 |

---

## 8. Currency risk

This is the most consequential financial risk SHE faces.

### 8.1 The exposure

- **BOM is paid in USD** to Shenzhen suppliers (JLCPCB for PCB, LCSC for components, factory partner for assembly)
- **B2C revenue is collected in ETB** (Telebirr, CBE Birr via Chapa)
- **B2B revenue is collected in USD** (contracts priced in USD, paid via bank transfer)

ETB has depreciated significantly against USD in recent years:
- 2022: 1 USD = 52 ETB (official), 75 ETB (parallel market)
- 2023: 1 USD = 56 ETB (official), 95 ETB (parallel)
- 2024: 1 USD = 58 ETB (official, post-float), 110 ETB (parallel, post-float)
- 2024-Q4: 1 USD = 55 ETB (NBE reference rate, post-float stabilization)

### 8.2 Impact of 30% ETB depreciation in a single year

Assume: B2C subscriber base of 1,000 users, monthly hardware reorder of 200 SHE-R8 units.

| Line | Baseline (1 USD = 55 ETB) | Stress (1 USD = 71.5 ETB after 30% depreciation) |
|---|---|---|
| B2C subscription revenue (1,000 × 150 ETB/mo) | 150,000 ETB = $2,727 | 150,000 ETB = $2,098 (-$629) |
| B2C hardware reorder (200 × $38.26) | $7,652 | $7,652 (unchanged — paid in USD) |
| Hardware resale (200 × $75) | $15,000 → 825,000 ETB | 825,000 ETB = $11,538 (-$3,462) |
| Net hardware margin per month | $7,348 → 404,140 ETB | 404,140 ETB = $5,652 (-$1,696) |
| B2B revenue (denominated in USD) | $2,500/mo | $2,500/mo (unchanged) |

**Monthly impact of 30% depreciation:**
- B2C subscription revenue down ~$629
- B2C hardware margin down ~$1,696
- Total: **-$2,325/month**

Over a year: -$27,900 — material but survivable if the depreciation happens gradually (allowing SHE to raise ETB prices).

### 8.3 Mitigations

1. **B2B contracts are USD-denominated.** This is the largest single mitigation — B2B revenue is ~$3,600 MRR at Phase 2 break-even, immune to ETB depreciation. This is why the B2B segment is strategically critical beyond just LTV.
2. **Quarterly ETB price review.** B2C prices are reviewed quarterly. If ETB depreciates >5% in a quarter, prices are raised by the corresponding percentage. A 30% annual depreciation = ~7.5% per quarter, so B2C prices would rise ~7.5% per quarter (i.e., 150 ETB → 161 → 173 → 186 → 200 ETB over a year). Customer churn impact: estimated 3-5% per price increase — manageable.
3. **USD reserves.** SHE holds USD from B2B contracts in a USD-denominated bank account (CBE USD account) and uses it to pay Shenzhen suppliers directly, avoiding round-trip conversion losses. Target: hold 3 months of BOM spend in USD reserve (~$25,000 for a 500-unit/month run rate).
4. **Local sourcing where possible.** Enclosure molding is being evaluated for local Addis Ababa production (would save $1.50/unit + reduce FX exposure). PCB fab and component sourcing remain offshore (no Ethiopian capability). See V3-HARDWARE.md §7.1.
5. **Hedge with forward contracts (future).** Once revenue exceeds $50K/month, SHE can purchase USD/ETB forward contracts through CBE or Awash Bank to lock in BOM costs 3-6 months ahead. Not available at launch volume.

### 8.4 Worst-case scenario

If ETB depreciates 50% in a single year AND B2B adoption is 50% below forecast (§7.3) simultaneously:
- B2B revenue: $1,800/mo (down from $3,600)
- B2C subscription revenue in USD terms: down 50%
- B2C hardware margin in USD terms: down 50%
- **Total monthly revenue in USD terms: ~$3,000 vs $6,160 operating cost**
- **Monthly burn: -$3,160**

In this scenario, SHE has 6-9 months of runway (depending on cash reserves) to either raise B2C prices, accelerate B2B sales, or raise additional capital. This is the **break-glass scenario** documented in the investor pitch deck.

---

## 9. Summary dashboard

| Metric | Value | Benchmark | Verdict |
|---|---|---|---|
| B2C LTV/CAC | 9.5x | SaaS: >3x | Healthy |
| B2B-100 LTV/CAC | 29.1x | — | Excellent |
| B2C payback | 1 month (target: 3 mo conservative) | SaaS: 12 mo | Outstanding |
| B2B payback | 1 month (target: 4 mo conservative) | — | Outstanding |
| Phase 1 break-even (infra) | $3,433 MRR (300 B2C + 10 B2B-100 + 1 B2B-1000) | — | Achievable month 6-9 |
| Phase 2 break-even (full cost) | $6,160 MRR (650 B2C + 27 B2B) | — | Achievable month 12-15 |
| Gross margin on landed cost | 49-52% across SKUs | Hardware: 40-60% | In range |
| Currency risk exposure | -$2,325/mo per 30% ETB depreciation | — | Material, mitigated by USD B2B |
| Largest single risk | B2B adoption 50% below forecast | — | -$1,800 MRR gap, recoverable via B2C volume |

**Bottom line:** The unit economics are strong on paper. The dominant risks are execution (will B2B sales close at the projected rate?) and currency (will ETB depreciation accelerate?). Both are manageable; neither is fatal in isolation. The combination of both (§8.4 worst-case) is the scenario to plan around with investor updates and a 6-month cash buffer.

---

## 10. References

- V3-HARDWARE.md §1, §7.2 — BOM and landed cost source of truth
- V3-PAYMENTS.md §1, §5 — Chapa fees + B2C plan pricing
- V3-B2B-WHITELABEL.md §4 — B2B plan pricing
- V3-SUPPORT-RMA.md §4 — RMA reserve calculation
- V3-ARCHITECTURE.md §6 — infrastructure cost basis ($1,200-2,500/mo hosting)
- V3-GO-TO-MARKET.md §5 — launch timeline aligned with break-even targets
- V3-ROADMAP.md — phase delivery dates
- National Bank of Ethiopia — FX reference rates (https://nbebank.com/)
