# V3 — Go-to-Market

**Status:** Locked
**Last updated:** 2024-Q4
**Owner:** Lead Engineer + Sales Lead
**Cross-references:** V3-UNIT-ECONOMICS.md (LTV/CAC/payback), V3-PAYMENTS.md (pricing), V3-B2B-WHITELABEL.md (B2B plans), V3-HARDWARE.md (SKUs), V3-SUPPORT-RMA.md (post-sale experience)

---

## 0. Document purpose

This document defines how SHE V3 reaches the market in Ethiopia: who we sell to, what we charge, how we acquire customers, how we market, and what the 12-month launch timeline looks like. It is the operational complement to V3-UNIT-ECONOMICS.md (which is the financial model).

The Ethiopian smart home market in 2024 is nascent: smartphone penetration is ~30%, mobile money (Telebirr) has 50M+ users, urban middle-class homeownership in Addis Ababa is growing, and imported Tuya/Smart Life products dominate the available choices but lack local support, Amharic UI, or Telebirr integration. SHE's wedge is **a locally-built, locally-supported, Amharic-first smart home platform priced for the Ethiopian middle class.**

---

## 1. Target market segments

### 1.1 B2C — Middle-class homeowners in Addis Ababa

| Attribute | Value |
|---|---|
| Geography | Addis Ababa (Phase 1); Adama, Bahir Dar, Hawassa (Phase 2, post-month 12) |
| Neighborhoods (priority) | Bole, Kazanchis, CMC, Sarbet, Gerji, Old Airport, Lideta |
| Household income | 50,000 – 150,000 ETB/month ($910 – $2,730/month at 55 ETB/$) |
| Homeownership | Owns or long-term-rents a single-family home or large apartment |
| Tech profile | Smartphone owner (Android 80%, iOS 20%); has Wi-Fi at home (Ethio Telecom fiber or 4G LTE); uses Telebirr weekly |
| Pain points | Rising electricity bills (EEU block tariff penalizes high usage), inability to control appliances remotely, no central switch for "leaving the house" routine, security concerns when traveling, elderly family members who can't use smartphone-based controls |
| Decision-maker | Primary: male head-of-household 28-45 years old; Secondary: spouse (joint decision); Influencer: teenage children (push for tech adoption) |
| Willingness to pay | One-time hardware: $50-$150 (3,000-8,000 ETB). Monthly subscription: 100-300 ETB (Premium/Family plans) |
| Estimated segment size | ~120,000 households in Addis Ababa match this profile (source: CSA 2023 + Ethio Telecom broadband subscriber count) |
| Realistic 3-year capture | 5,000-8,000 households (4-7% of segment) |

### 1.2 B2B — Real estate developers

| Attribute | Value |
|---|---|
| Target companies | Bole Real Estate, Sunshine Construction, Flintwood Homes, Habesha Construction |
| Use case | Pre-install SHE-R16 in new apartment buildings as a smart-home differentiator; recurring revenue via tenant billing |
| Decision-maker | Sales/Marketing Director (wants to differentiate the property) + IT Manager (evaluates the platform) + Construction Manager (approves the install) |
| Sales cycle | 4-6 months from first contact to signed contract; 6-12 months to first deployment |
| Deal size | $3,000-$15,000 hardware (50-200 units) + $1,000-$2,000/month recurring |
| Pilot strategy | 1-2 buildings in pilot phase (10-50 units), scale to portfolio-wide deployment if successful |

### 1.3 B2B — Hotels

| Attribute | Value |
|---|---|
| Target companies | Hayat Hotel (chain), Radisson Blu Addis Ababa, Golden Tulip, Friendship International Hotel |
| Use case | Guest-room automation (key-card → lights/AC, energy savings when room unoccupied), centralized front-desk control |
| Decision-maker | General Manager + IT Manager + Facilities Director |
| Sales cycle | 3-6 months (faster than real estate if GM champion is engaged) |
| Deal size | $5,000-$25,000 hardware (30-150 rooms × R8/R16) + $500-$2,000/month recurring |

### 1.4 B2B — ISPs and telecom resellers

| Attribute | Value |
|---|---|
| Target companies | Ethio Telecom (reseller/whitelist model), SprintZone, SEO (Smart Express Online), MyISP |
| Use case | White-label SHE app, bundle smart home with fiber internet subscription, monthly bill add-on |
| Decision-maker | Product Manager + Head of Consumer + IT |
| Sales cycle | 6-9 months (longest of B2B segments; large org procurement) |
| Deal size | $20,000-$100,000 hardware (initial batch for subscriber rollout) + $2,000-$5,000/month recurring at scale |

### 1.5 B2B — Universities and institutions

| Attribute | Value |
|---|---|
| Target | Addis Ababa University (dorms), Ethiopian Civil Service University, Mekelle University, Jimma University |
| Use case | Dorm energy management (cap electricity use per student), remote shut-off during breaks, central monitoring |
| Decision-maker | Facilities Director + IT Director + Procurement |
| Sales cycle | 9-12 months (institutional procurement; budget cycle alignment) |
| Deal size | $10,000-$40,000 hardware + $1,000-$3,000/month recurring |

### 1.6 B2B segment priority

For the first 12 months, focus is on **real estate developers** (highest close probability, repeatable) and **hotels** (fastest sales cycle). ISPs and universities are Phase 2 (year 2) targets.

---

## 2. Pricing strategy

### 2.1 B2C pricing (in ETB, inclusive of VAT)

| Plan | Price (ETB/month) | Price (USD/month) | Devices supported | Features |
|---|---|---|---|---|
| Free | 0 | $0 | Up to 10 devices, 1 home | Basic on/off control, no automations, no OTA, no energy monitoring |
| Premium | 150 | ~$2.73 | Unlimited devices, up to 2 homes | All features: automations, scenes, OTA, energy monitoring, push notifications |
| Family | 300 | ~$5.45 | Unlimited devices, up to 5 homes, up to 5 members | All Premium features + shared homes + priority support |

**Annual prepay discount:** 10% off (Premium: 1,620 ETB/year; Family: 3,240 ETB/year). Encourages cash collection upfront and improves retention.

**Hardware sold separately** — subscription covers cloud service, not the hardware. Customers who buy hardware and never subscribe can still use the Free plan (basic control, no advanced features).

### 2.2 B2B pricing (in USD)

| Plan | Devices | Price/month | Per-device price | Notes |
|---|---|---|---|---|
| B2B-100 | Up to 100 | $100 | $1.00/device | All features, 1 tenant admin, no API access |
| B2B-1000 | Up to 1,000 | $800 | $0.80/device | All features, 5 admins, API access, white-label branding |
| B2B-UNLIMITED | Unlimited | $2,000 flat | n/a | All features, unlimited admins, 24/7 SLA, dedicated CSM |

**Hardware is bundled into B2B contracts** at a 15% discount vs B2C retail. For a B2B-100 tenant with 100 SHE-R8 devices: hardware = 100 × $75 × 0.85 = $6,375 (one-time) + $100/month recurring.

**Overage:** B2B-100 tenants exceeding 100 devices pay $1.50/device/month for each additional device (incentive to upgrade to B2B-1000 at the 1001-device mark).

### 2.3 Pricing rationale

- **B2C Premium at 150 ETB/month** is comparable to a Netflix subscription or 2-3 large lattes at Kaldi's Coffee. Anchored against monthly electricity bill savings (energy monitoring typically saves 10-20% on EEU bill = 100-300 ETB/month for a mid-sized home). ROI is immediate.
- **B2C Family at 300 ETB/month** matches a typical household internet bill. The shared-home feature is the value hook.
- **B2B-100 at $100/month** is intentionally low to lower the barrier for first B2B customers. The LTV (V3-UNIT-ECONOMICS.md §4.3) is $7,331, so even at $100/month the unit economics work.
- **B2B-UNLIMITED at $2,000/month** is positioned as enterprise — covers the cost of dedicated support engineer time + SLA penalties.

### 2.4 Discounts and promotions

| Promotion | Eligibility | Discount | Duration |
|---|---|---|---|
| Early adopter (months 1-3) | First 100 B2C Premium subscribers | 50% off for 6 months | Launch quarter |
| Friends & family beta | 20 invited beta users (months 1-2) | Free hardware + lifetime Premium | Permanent for this cohort |
| B2B pilot | First 2 B2B-100 tenants | 50% off first 3 months | Months 7-9 |
| Referral | Existing Premium user refers new user | Both get 1 month free Premium | Ongoing |
| Annual prepay | Any B2C or B2B plan | 10% off | Annual |

---

## 3. Sales channels

### 3.1 B2C channels

| Channel | Volume target (year 1) | Cost / acquisition | Notes |
|---|---|---|---|
| Online (website + Telegram bot) | 60% of B2C | $11 | Customer self-checkout via Chapa, hardware shipped from Addis warehouse or pickup at retail partner |
| Retail (2 electronics shops: 1 in Bole, 1 in Sarbet) | 20% of B2C | $15 | 10% retailer commission on hardware, in-store demo unit, instant pickup |
| Installer network (10 certified electricians in Addis Ababa) | 15% of B2C | $22 | $10 referral fee to electrician + customer pays $30 install fee; targets less-technical homeowners |
| Word of mouth / referral | 5% of B2C | $5 | Referral program credits both parties |

### 3.2 B2B channels

| Channel | Volume target (year 1) | Cost / acquisition | Notes |
|---|---|---|---|
| Direct sales (Lead Engineer + 1 sales rep) | 70% of B2B | $250 | 4-month sales cycle; demo kit + RFP response + on-site presentation |
| RFP responses (government + enterprise procurement) | 20% of B2B | $400 | Respond to public tenders; longer cycle, lower close rate, but higher contract value |
| Partner referrals (Ethio Telecom, banks) | 10% of B2B | $150 | Co-selling through partner relationships |

### 3.3 Channel economics

Total addressable through these channels in year 1:
- B2C: ~1,000 paying subscribers (60% online + 20% retail + 15% installer + 5% referral)
- B2B: ~12 tenants (8 B2B-100 + 3 B2B-1000 + 1 B2B-UNLIMITED)

This matches the V3-UNIT-ECONOMICS.md §6 break-even targets.

### 3.4 Channel scaling plan

| Phase | Months | B2C channel expansion | B2B channel expansion |
|---|---|---|---|
| 1 | 1-3 | Website + Telegram bot only; friends & family beta | Direct outreach to 5 real estate developers |
| 2 | 4-6 | Add 2 retail partners (Bole + Sarbet); recruit first 5 electricians | Sign 2 B2B-100 pilot tenants |
| 3 | 7-9 | Recruit 5 more electricians (total 10); expand retail to 4 shops | Close 3 more B2B-100 + 1 B2B-1000 |
| 4 | 10-12 | Explore Adama + Bahir Dar retail | Close 2 B2B-1000 + 1 B2B-UNLIMITED |

---

## 4. Marketing

### 4.1 Social media

| Platform | Audience (Ethiopia, 2024) | SHE use | Posting cadence |
|---|---|---|---|
| Telegram | ~25M users; primary social platform | Channel for product updates, support, community. Telegram bot for order + support. | Daily: 1 product tip / customer story |
| Facebook | ~8M users; primary advertising platform | Paid ads (targeting Addis Ababa, 25-45, income proxy by phone model); organic page for testimonials | 3-4 posts/week; $500/month ad spend |
| Instagram | ~3M users; younger urban demographic | Visual content: install photos, before/after energy bills, Amharic + English captions | 3 posts/week |
| YouTube | ~5M viewers | Installation tutorials in Amharic; "Day in the Life" demos; energy saving tips | 1 video/2 weeks |
| TikTok | ~4M users, younger | Short-form: relay click sound, scene activation demo, voice control demo (R16) | 2 videos/week |
| X (Twitter) | ~500K users; tech + diaspora | English-language tech announcements; engages Ethiopian diaspora (influencer purchase decisions) | Weekly |

### 4.2 Content marketing

| Content type | Topic examples | Channel | Frequency |
|---|---|---|---|
| Installation videos | "How to install SHE-R8 in your kitchen" (Amharic), "Wiring the SHE-R16 to your distribution board" (English) | YouTube | Monthly |
| Blog posts | "EEU block tariff explained: how SHE saved us 1,200 ETB/month", "5 automations every Ethiopian home needs" | she.et/blog | Bi-weekly |
| Case studies | "How Hayat Hotel cut guest-room energy 22% with SHE", "Sunshine Real Estate's smart-home differentiation" | she.et/case-studies | Quarterly (post B2B wins) |
| Press releases | Launch, partnerships, certifications | Ethio Telecom Press, Addis Fortune, The Reporter | Quarterly |

### 4.3 Partnerships

| Partner | Nature of partnership | Status | Expected impact |
|---|---|---|---|
| **Ethio Telecom** | Bundle SHE with Ethio Telecom fiber internet subscription; SHE listed on Ethio Telecom's value-added services catalog | Discussion initiated 2024-Q3; LOI target 2025-Q1 | Significant: Ethio Telecom is the dominant ISP; bundle distribution could double B2C acquisition velocity |
| **Berhan Ena Selam Bank / CBE** | Hardware financing for B2C customers (0% interest installment plan over 6 months) | Discussion initiated | Removes price barrier for middle-income customers; increases conversion rate |
| **Chapa** | Co-marketing — SHE featured as a Chapa merchant success story | LOI signed 2024-Q4 | Modest: positions SHE as a Telebirr success case |
| **Addis Ababa University (Electrical Engineering dept)** | Internship program; final-year projects on SHE firmware; possible R&D collaboration | MoU draft | Talent pipeline + credibility |
| **ECA (Ethiopian Communications Authority)** | Type approval partnership; co-marketing around local manufacturing | Application in progress | Regulatory tailwind + "made in Ethiopia" branding |

### 4.4 Events

| Event | Date | SHE activity | Budget |
|---|---|---|---|
| ICT Ethiopia trade show (Addis Ababa) | 2025-Q1 | Booth, live demo, B2B lead capture | $3,000 |
| Addis Ababa Housing Expo | 2025-Q2 | Booth + B2B meetings with real estate developers | $2,000 |
| Ethiopia Innovation Week | 2025-Q3 | Speaking slot ("Building IoT in Ethiopia") | $500 |
| Hospitality Ethiopia (hotel industry) | 2025-Q4 | B2B meetings with hotel GMs | $1,500 |

### 4.5 Marketing budget

| Line item | Monthly | Annual |
|---|---|---|
| Facebook + Instagram ads | $500 | $6,000 |
| Content production (videos, blog, design) | $400 | $4,800 |
| Event attendance | $700 amortized | $8,400 |
| Telegram bot infrastructure + community manager | $300 | $3,600 |
| Misc (swag, printed materials, signage) | $200 | $2,400 |
| **Total marketing budget** | **$2,100** | **$25,200** |

This budget supports the B2C CAC target of $12 (V3-UNIT-ECONOMICS.md §3.1) — at $12 CAC, $500/month Facebook ads yields ~42 new customers/month, matching the projected ramp.

---

## 5. Launch timeline

| Phase | Months | B2C target | B2B target | Revenue target | Cost target |
|---|---|---|---|---|---|
| **Phase 1: Friends & Family beta** | 1-2 | 20 free-hardware beta users | 0 | $0 (free beta) | $2,500/mo (founders + hosting) |
| **Phase 2: Public B2C launch** | 3-6 | 200 paying Premium + 50 Family | 1 B2B-100 pilot | $1,800/mo MRR (end of phase) | $3,000/mo |
| **Phase 3: B2B pilot** | 7-9 | 350 Premium + 80 Family | 5 B2B-100 + 1 B2B-1000 | $3,500/mo MRR | $4,500/mo (added Cloudflare Business + 1 support hire) |
| **Phase 4: Scale** | 10-12 | 1,000 Premium + 200 Family | 10 B2B-100 + 3 B2B-1000 + 1 B2B-UNLIMITED | $7,500/mo MRR | $6,000/mo (full team + RMA reserve) |

### 5.1 Phase 1 milestones (months 1-2)

- Hardware: first 50 SHE-R8 + 10 SHE-R16 received from Shenzhen factory, customs cleared
- Software: V3 GA firmware frozen, mobile app submitted to Google Play + App Store
- Cloud: Ethio Telecom Cloud production environment deployed, EMQX cluster healthy, certs generated for first 100 devices
- Sales: 20 friends & family beta users selected (Lead Engineer's personal network + 5 diaspora contacts), free hardware delivered, in-person install assistance
- Goal: validate end-to-end UX, find top-10 bugs, gather testimonials for marketing launch

### 5.2 Phase 2 milestones (months 3-6)

- Public B2C launch event in Addis Ababa
- Press coverage in Addis Fortune + The Reporter + Ethio Telecom newsletter
- Online ordering live on she.et + Telegram bot
- 2 retail partners signed (Bole + Sarbet)
- First 5 certified electricians onboarded
- Target: 200 paying Premium + 50 Family subscribers by end of month 6
- 1 B2B-100 pilot signed (real estate developer — building handover in month 6)

### 5.3 Phase 3 milestones (months 7-9)

- B2B pilot deployment: 50-100 SHE-R16 units installed in pilot building
- Close 4 more B2B-100 tenants + 1 B2B-1000 (large property developer)
- Customer satisfaction survey: target ≥8/10 (V3-SUCCESS-METRICS.md)
- First paid advertising campaign optimized based on Phase 2 conversion data
- Hire 1 customer support agent (Telegram + in-app chat Tier 1)

### 5.4 Phase 4 milestones (months 10-12)

- Reach 1,000 B2C Premium + 200 Family subscribers
- Close 5 more B2B-100 + 2 B2B-1000 + 1 B2B-UNLIMITED (10 B2B total)
- Hit $7,500 MRR (above the $5,200 break-even in V3-UNIT-ECONOMICS.md §6.1)
- Begin Adama + Bahir Dar expansion scoping (Phase 2 geography)
- Series A fundraise preparation (deck + financial model + customer references)

---

## 6. Competitive positioning

### 6.1 Direct competitors

| Competitor | Product | Price | Strengths | Weaknesses |
|---|---|---|---|---|
| Tuya / Smart Life (imported) | White-label smart switches + hubs | 1,500-5,000 ETB per switch (uninstalled) | Cheap, broad ecosystem, available on AliExpress / Jumia | Chinese cloud (data leaves Ethiopia), English-only app, no Telebirr, no local support, no Amharic, no PDPP compliance |
| Sonoff (imported) | DIY smart switches | 800-2,500 ETB per switch | Cheap, Tasmota-compatible, broad community | Same data/cloud issues as Tuya; requires technical user to install |
| Custom installers (local electricians) | Custom PLC or wired solutions | 30,000-80,000 ETB total install | Locally supported, electrician is on call | 2-3x more expensive than SHE; no app control; no remote access; no automations; no energy monitoring |
| Imported Matter devices (future) | Apple HomePod + Eve Energy, etc. | 5,000+ ETB per device, Apple Home required | Premium brand, Matter interop | Very expensive, requires iPhone, no Amharic, no Telebirr, no local support |

### 6.2 SHE's wedge

SHE V3's differentiation against all competitors rests on four pillars:

1. **Locally supported.** SHE has a phone number, an Addis Ababa office, a Telegram support channel, and (for B2B-UNLIMITED) on-site field service within 48 hours. Imported Tuya/Sonoff products have zero local support — when they break, the customer is on their own.

2. **Amharic-first UI.** The mobile app defaults to Amharic (English available). Alexa/Google Home/Siri are not available in Amharic. SHE's Picovoice offline voice control supports Amharic intents (SHE-R16 only, V3-VOICE-MATTER.md §1). This matters because the household decision-maker's parents (who may control devices) often speak only Amharic.

3. **Telebirr payment.** SHE accepts Telebirr + CBE Birr via Chapa. Imported products require international credit cards (rare in Ethiopia) or USD PayPal (blocked). This is a hard moat — Tuya cannot accept Telebirr without a local Ethiopian entity.

4. **PDPP compliance.** SHE is the only locally-hosted option. B2B customers (banks, government, hotels) have data residency requirements under PDPP that imported products cannot satisfy. This is a procurement-level advantage for B2B sales.

### 6.3 Price comparison

| Use case | Tuya/Smart Life (imported) | Custom installer | SHE V3 |
|---|---|---|---|
| 8-channel smart switch (1 room) | ~$70 hardware + Chinese cloud (free) | $200-300 install (no app) | $75 hardware (SHE-R8) + $3/month |
| Whole-home (3 rooms, 24 channels) | ~$210 hardware + Chinese cloud | $600-1,500 install | $225 hardware (3× SHE-R8) + $3/month |
| Whole-home with voice | Not available | Not available | $120 hardware (SHE-R16) + $6/month (Family) |
| Hotel (100 rooms) | Not feasible (no B2B offering) | $30,000+ custom install | $7,500 hardware + $100/month |

**SHE is 60% cheaper than custom installers** for comparable functionality, with the added benefit of mobile app control, automations, and remote access.

### 6.4 Strategic positioning statement

> *"SHE is the smart home platform built in Ethiopia, for Ethiopia. Locally hosted, locally supported, Amharic-first, Telebirr-integrated, and PDPP-compliant. We deliver premium smart-home functionality at 60% lower cost than custom installers, with full local support that imported products cannot match."*

---

## 7. Risks

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| 7.1 | **ETB depreciation vs USD** (BOM in USD, B2C revenue in ETB) | High | High — $2,350/mo cost per 30% depreciation | USD-denominated B2B contracts; quarterly ETB price reviews; 3-month USD reserve; potential local enclosure molding to reduce FX exposure (V3-UNIT-ECONOMICS.md §8) |
| 7.2 | **Component supply chain disruption** (Shenzhen shipping delays, customs hold-ups, China-Ethiopia trade friction) | Medium | Medium — 2-4 week stockouts if a single Shenzhen shipment is delayed | Maintain 6-week buffer inventory in Addis Ababa; dual-source critical components (ESP32 from Espressif directly + LCSC + Mouser); air-freight fallback ($3/unit premium) for emergency restock |
| 7.3 | **Chapa service interruption** (Chapa is the single payment aggregator) | Low | High — all B2C subscription billing halts | Maintain direct Telebirr API integration as fallback (V3-PAYMENTS.md §1, deferred to V3.1); CBE Birr direct integration also feasible; manual bank transfer as ultimate fallback |
| 7.4 | **Competitor entry** (Tuya local distributor, or a local competitor copies the model) | Medium | Medium — price pressure on hardware; commodity perception risk | Lock in B2B contracts with 3-year terms; build brand moat via Amharic content + community (Telegram channel with 10K+ members by month 12); pursue ECA type approval as a regulatory barrier (imported products without type approval cannot legally be sold in Ethiopia) |
| 7.5 | **Ethio Telecom Cloud outage** (single-region hosting; no DR site) | Low | High — full platform downtime | Ethio Telecom's SLA is 99.5% (43 hours/year allowed downtime); backup snapshots to local NAS + offsite (AWS S3 in Bahrain) nightly; cold-standby Spring Boot instance can be promoted in 4 hours; see V3-OPS-RUNBOOK.md |
| 7.6 | **Cybersecurity incident** (account takeover, device compromise, data breach) | Medium | High — PDPP Art. 33 breach notification, reputational damage | Defense-in-depth (RLS, mTLS, MFA, WAF) per V3-SECURITY-MODEL.md; quarterly tabletop breach exercises per V3-PRIVACY-COMPLIANCE.md §5; cyber insurance policy (target 2025-Q2) |
| 7.7 | **Talent attrition** (Lead Engineer or Backend Engineer leaves) | Medium | High — bus factor risk | Equity participation for both engineers; documentation set (this V3 doc set) reduces bus factor; engage 1-2 part-time contractors as bench depth |
| 7.8 | **Regulatory change** (PDPP amendment, ECA type approval changes, new import tariffs) | Low | Medium | Annual review of V3-PRIVACY-COMPLIANCE.md + V3-DPIA.md; maintain relationships with ECA + Ministry of Innovation and Technology |
| 7.9 | **Smartphone adoption slowdown** (smartphone penetration stalls below 35%) | Low | Medium — limits B2C addressable market | Voice control (SHE-R16) + Telegram bot as feature-phone alternatives (Telegram works on basic phones via USSD in some configurations); B2B segment is less smartphone-dependent |
| 7.10 | **Customer adoption slower than forecast** (B2C or B2B conversion below plan) | Medium | High — slower path to break-even | Lean cost structure (V3-UNIT-ECONOMICS.md §6.1); founders take reduced salary until $5K MRR; Series A bridge possible if needed |

### 7.1 Risk register owner and review

Each risk has a named owner (Lead Engineer by default; DPO for 7.6 once hired; Sales Lead for 7.10). Reviewed quarterly at the leadership meeting. Top 3 risks (7.1 currency, 7.2 supply chain, 7.4 competitor entry) are reviewed monthly.

---

## 8. Success metrics (year 1)

Cross-reference: V3-SUCCESS-METRICS.md (canonical KPIs).

| Metric | Target (end of month 12) | Stretch |
|---|---|---|
| B2C paying subscribers | 1,200 | 2,000 |
| B2B tenants | 14 | 20 |
| Monthly recurring revenue | $7,500 | $12,000 |
| Active devices online (24h rolling) | 5,000 | 8,000 |
| Customer satisfaction (avg rating) | ≥8/10 | ≥9/10 |
| Monthly churn (B2C) | <5% | <3% |
| Annual churn (B2B) | <10% | <5% |
| RMA rate | <2% | <1% |
| Time-to-first-response (support) | <2h | <1h |
| App store rating | ≥4.5 | ≥4.7 |

---

## 9. References

- V3-UNIT-ECONOMICS.md — financial model underlying all targets in this document
- V3-PAYMENTS.md — Chapa integration + B2C plan definitions
- V3-B2B-WHITELABEL.md — B2B plan definitions + tenant onboarding
- V3-HARDWARE.md §1 — SKU definitions + sale prices
- V3-SUPPORT-RMA.md — post-sale customer experience
- V3-SUCCESS-METRICS.md — KPIs and targets
- V3-ROADMAP.md — engineering roadmap aligned with launch phases
- CSA (Central Statistical Agency of Ethiopia) — 2023 household survey
- Ethio Telecom — broadband subscriber statistics 2024
- National Bank of Ethiopia — FX rates and monetary policy
