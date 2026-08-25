# ADR-010: Target Ethiopia Exclusively for V3

**Status:** Locked
**Date:** 2024-Q4
**Decision maker:** Lead Engineer

## Context

SHE V3 is built by a 2–3 engineer team (plus a firmware contractor in months 4–9) over 12 months. The team's capacity is the binding constraint — every feature, integration, and certification costs engineering hours, and every new market multiplies those costs.

The Ethiopian smart-home market is large enough to absorb the team's full V3 output: ~120 million people, ~25 million households (avg household size ~4.8), a rapidly urbanizing middle class in Addis Ababa (pop. ~5 million) and secondary cities (Dire Dawa, Bahir Dar, Hawassa, Mekelle, Adama, Jimma), and a growing B2B segment (real-estate developers, hotel chains, ISPs looking to bundle smart-home with broadband). Ethiopia-specific requirements — Telebirr payments, Amharic-first UI, Ethiopian calendar, PDPP compliance, ECA certification, Addis Ababa hosting, unreliable grid (frequent brownouts), low smartphone penetration in rural areas — each require dedicated engineering attention.

If we tried to launch pan-African or pan-East-African from day 1, we would face: (1) M-Pesa integration for Kenya, (2) multiple currencies and FX reconciliation, (3) multiple languages (Swahili, Amharic, Oromo, English), (4) multiple regulatory regimes (Kenya DPA, Uganda DPA, Rwanda Law N°058/2021), (5) multiple certifications per country (CA Kenya, UCC Uganda, RICA Rwanda), (6) hosting decisions for each country (Kenya has AWS af-south-1 in Cape Town as closest — still 180 ms). Each additional country roughly doubles the integration burden. For a 2–3 engineer team, that means shipping nothing well rather than something great.

## Decision

Target **Ethiopia exclusively** for V3 (defined as: V3 GA launch through end of 2025). All product, design, engineering, certification, and go-to-market efforts are scoped to Ethiopia. Specifically:

- **Language:** Amharic-first UI with English fallback (V3-I18N.md). Oromo, Tigrinya, and other Ethiopian languages deferred to V3.1+
- **Payments:** Telebirr + CBE Birr via Chapa (ADR-005). No M-Pesa, no international cards as primary method
- **Calendar:** Ethiopian calendar (13 months, 30 days each + 5/6 day Pagume) supported in app (scheduling, energy-usage charts, audit log timestamps) alongside Gregorian
- **Hosting:** Addis Ababa (ADR-008). No multi-country deployment
- **Certification:** ECA (Ethiopian Communications Authority) — mandatory. CE/FCC pursued for B2B export credibility but not primary market
- **Compliance:** PDPP (Ethiopian Data Protection Proclamation) — primary regulatory regime. No DPA compliance for Kenya/Uganda/etc.
- **Mobile platforms:** Android first (Tecno, Infinix, Samsung A-series dominate the Ethiopian market), iOS second (small but high-value segment in Addis)
- **Pricing:** ETB for B2C, USD for B2B (V3-UNIT-ECONOMICS.md §0)
- **Support:** Amharic + English phone/WhatsApp support, Ethiopia business hours (V3-SUPPORT-RMA.md)
- **Distribution:** Addis Ababa retail partners + installer network first; secondary cities via e-commerce + courier

**Multi-country is a V4+ conversation.** The product architecture (multi-tenant RLS, currency-agnostic schema, i18n-ready Flutter app) is designed to *permit* multi-country expansion later, but the V3 team does not implement any non-Ethiopia-specific feature unless it is free.

## Alternatives Considered

### Alternative A: Pan-African from day 1 (Ethiopia + Kenya + Uganda + Rwanda + Tanzania)
- **Pros:** Larger addressable market; "African smart-home platform" narrative is more fundable; hedges against Ethiopia-specific political/economic risk.
- **Cons:** Each country requires: payment integration (M-Pesa for Kenya/Tanzania, MTN MoMo for Uganda, Airtel Money for Rwanda), language localization (Swahili, English, French for Rwanda), separate regulatory compliance (Kenya DPA, Uganda DPA, Rwanda Law N°058/2021), separate certification (CA Kenya, UCC Uganda, RICA Rwanda), separate hosting decisions (no AWS region in any of these countries either), separate support coverage (4 languages, 4 business-hours zones), separate B2B sales motions (each country has different ISP and real-estate landscapes). For a 2–3 engineer team this means shipping a worse product in 5 countries rather than a great product in 1. **Rejected for V3.**

### Alternative B: East Africa (Ethiopia + Kenya only)
- **Pros:** Kenya is the most mature East African tech market — M-Pesa is reliable, smartphone penetration is higher, B2B segment (Safaricom, ISPs, real-estate) is more ready; two countries is more fundable than one.
- **Cons:** M-Pesa integration is ~6 weeks of backend work + Daraja API merchant onboarding (weeks of Safaricom process); Kenya DPA compliance is a separate legal workstream; Nairobi vs Addis hosting decision (no AWS in Nairobi either — af-south-1 Cape Town is the closest, still 180 ms); Swahili localization; 2 separate certification regimes; 2 separate B2B sales motions. Doubles the engineering surface area for ~2x the market — net negative when team capacity is the constraint. **Rejected for V3 — revisit in V3.2 if Ethiopia launch is stable and we have hired a 4th engineer.**

### Alternative C: Global from day 1 (English-only, Stripe payments, AWS multi-region)
- **Pros:** Maximum addressable market; "global smart-home platform" is the most fundable narrative; no PDPP/Kenya DPA compliance burden if we don't operate in those jurisdictions; English-only means no localization; Stripe payments are easy.
- **Cons:** Competes head-on with Tuya/Sonoff/Shelly/SmartThings/Apple Home/Google Home on their home turf — a 2-3 engineer startup cannot win that fight; no competitive moat in the global market; "Ethiopian company" is our actual moat (we win Ethiopia because we are the only ones who do Telebirr + Amharic + Addis hosting + ECA cert); Stripe does not operate in Ethiopia so we'd lose the home market; the global smart-home market is saturated with cheap Tuya rebrands — no premium positioning is possible without massive marketing spend. **Rejected.**

### Alternative D: Ethiopia + Ethiopian diaspora (US, EU, Gulf)
- **Pros:** Diaspora is a real market — Ethiopian-Americans buying devices for family back home; USD-denominated revenue; diaspora-funded deployments are common.
- **Cons:** Diaspora user is paying, but the *user* is in Ethiopia — so device data still flows to Ethiopia (good) but payment + support must serve two countries (bad); diaspora market is small relative to the domestic Ethiopian market; does not justify the engineering surface area of multi-currency, multi-timezone support. **Rejected for V3 — diaspora buyers will use the Ethiopian app with USD billing, no separate diaspora product.**

## Consequences

### Positive
- **Focused product** — every engineering hour goes to making the Ethiopian experience great, not to multi-country abstraction
- **Deep local integration** — Telebirr, Amharic, Ethiopian calendar, PDPP, ECA, Addis hosting, unreliable grid handling — none of which a foreign competitor will do
- **B2B moat** — ISPs, government-adjacent operators, real-estate developers prefer a local vendor with local hosting, local support, local compliance; foreign competitors (Tuya, SmartThings) cannot match this
- **Realistic scope** — 2–3 engineers can ship Ethiopia-only in 12 months; multi-country cannot be shipped in 12 months by 2–3 engineers
- **Regulatory simplicity** — one DPA (PDPP), one certification (ECA), one tax regime (ERCA), one employment regime
- **Brand positioning** — "Smart Home *Ethiopia*" is a clear, fundable, defensible identity; "Smart Home Global" is not

### Negative
- **Smaller market** — Ethiopia ~25M households vs pan-African ~150M households; revenue ceiling for V3 is bounded
- **Political/economic risk concentration** — single-country exposure to Ethiopian events (civil unrest, currency depreciation, telecom outages, regulatory shifts); no geographic hedge
- **Harder to expand later** — multi-country is a V4+ re-architecture: payment abstraction layer, currency conversion, multi-jurisdiction compliance, multi-region hosting, localization pipeline. The V3 architecture is *designed to permit* this (multi-tenant RLS, i18n-ready app, currency-agnostic schema) but the V4 implementation cost remains real
- **Limited B2B addressable market** — Ethiopian B2B (ISPs, hotel groups, real-estate) is small; some prospects will be too small to justify the B2B sales motion
- **Currency risk on cloud costs** — if Ethio Telecom Cloud reprices in USD (some Ethiopian cloud providers are starting to), we lose the natural ETB-cost hedge

### Neutral
- The "Ethiopia only" decision is reversible in principle but expensive in practice — the longer we wait to add country #2, the more Ethiopia-specific assumptions get baked into the codebase
- Diaspora buyers (Alternative D) remain addressable via the Ethiopian app with USD billing — no separate product needed
- The product architecture is intentionally *not* Ethiopia-hardcoded: phone numbers are E.164, dates are ISO 8601 in storage (Ethiopian calendar is a presentation-layer concern), currencies are ISO 4217 — these choices keep the V4 multi-country door open without costing V3 engineering hours

## References
- V3-OVERVIEW.md §1 (platform vision — Ethiopian market focus)
- V3-I18N.md (Amharic-first i18n, Ethiopian calendar support)
- V3-PAYMENTS.md (Telebirr + CBE Birr via Chapa)
- V3-B2B-WHITELABEL.md (Ethiopian B2B segment — ISPs, hotels, real-estate)
- V3-GO-TO-MARKET.md (Ethiopian sales channels, Addis retail + installer network)
- V3-SUPPORT-RMA.md (Amharic + English support, Ethiopia business hours)
- V3-PRIVACY-COMPLIANCE.md (PDPP — primary regulatory regime)
- ADR-005 (Telebirr via Chapa — Ethiopia-specific payment)
- ADR-006 (Picovoice offline voice — Amharic support is the differentiator)
- ADR-008 (Addis Ababa hosting — Ethiopia-specific infrastructure)
