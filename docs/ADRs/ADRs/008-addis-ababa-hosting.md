# ADR-008: Host Production Infrastructure in Addis Ababa

**Status:** Locked
**Date:** 2024-Q4
**Decision maker:** Lead Engineer

## Context

SHE V3 is a B2B+B2C IoT platform where every device in the fleet maintains a persistent MQTT connection to the cloud, telemetry flows continuously, and personal data (user accounts, home layouts, device usage patterns, energy consumption) is stored in Postgres. The Ethiopian Data Protection Proclamation (PDPP) requires personal data of Ethiopian residents to be processed and stored in Ethiopia under a registered data controller, with cross-border transfers permitted only under narrow exceptions (consent, contractual necessity, or specific government authorization). Several of our target B2B tenants (ISPs, government-adjacent operators, regulated industries) have contractual clauses that prohibit personal data from leaving Ethiopia at all.

Beyond compliance, there are operational reasons to host in Addis Ababa: (1) latency — Ethiopian users on Ethio Telecom or Safaricom Ethiopia mobile networks see ~5–20 ms RTT to an Addis DC vs ~50 ms to Bahrain (AWS me-south-1) or ~180 ms to Cape Town (AWS af-south-1); (2) B2B sales — a tenant evaluating a 1,000-device deployment can be told "your data is in Addis, in a DC you can physically visit"; (3) cost — Ethio Telecom Cloud pricing for VMs is competitive with AWS for steady-state workloads and avoids USD-denominated bandwidth egress charges that compound at IoT telemetry volumes.

The trade-off is real: Addis Ababa has fewer hosting providers than AWS regions, less mature network redundancy, and the rare-but-real risk of a national internet shutdown (Ethiopia has had several in recent years). We must design for both the steady-state case (Addis hosting wins) and the outage case (the system degrades gracefully when the DC is unreachable).

## Decision

Host all production infrastructure in an **Addis Ababa data center** (target provider: **Ethio Telecom Cloud** — the state telecom's cloud arm, with the largest in-country footprint and direct peering with Ethio Telecom mobile network). Single-region deployment for V3; no multi-region active-active.

The full stack runs in Addis:
- EMQX 3-node MQTT cluster (3 VMs)
- Spring Boot REST API (2+ VMs behind Nginx)
- PostgreSQL 16 + TimescaleDB (primary + replica)
- Redis 7 (1 primary + 1 replica)
- MinIO object storage (single node, erasure-coded)
- step-ca CA server (1 VM, isolated network)
- Grafana + Prometheus (observability)

**Cross-border traffic — what does and does not leave Ethiopia:**
- **Stays in Ethiopia:** all device telemetry, all user PII, all device certs, all payment records, all MQTT traffic, all Postgres data, all MinIO OTA images, all Redis state
- **Transits cross-border (by design, documented in DPIA):**
  - **Push notification tokens** — Firebase Cloud Messaging (FCM) for Android, Apple Push Notification service (APNs) for iOS. The push *token* (an opaque device identifier, not device data) must transit to Google/Apple to deliver notifications. The *content* of the notification (e.g., "Garage door opened") is sent to FCM/APNs as well. Mitigation: keep push content minimal ("Device alert" rather than "Garage door opened at 14:32"), and document this honestly in V3-PRIVACY-COMPLIANCE.md and V3-DPIA.md
  - **Cloudflare** — TLS terminates at the nearest Cloudflare edge (could be Nairobi, Frankfurt, or Djibouti depending on routing). No device data transits Cloudflare beyond the TLS handshake; all HTTP bodies are re-encrypted and forwarded to Addis
  - **Chapa webhooks** — payment notifications originate from Chapa's infrastructure (hosted in Ethiopia on AWS af-south-1 Cape Town as of 2024-Q4, though Chapa is migrating to in-country hosting). Webhook payloads contain `tx_ref` + amount, not PII
  - **Outgoing email** — transactional email (password reset, OTP) via a third-party SMTP relay (Mailgun or Postmark) — minimum necessary PII (email address only), documented in DPIA

This is **not** a "no data leaves Ethiopia ever" claim — that would be dishonest. It is a "primary data stays in Ethiopia, three documented subprocessors handle narrowly-scoped cross-border traffic" claim, which is defensible under PDPP's contractual-necessity exception.

## Alternatives Considered

### Alternative A: AWS me-south-1 (Bahrain)
- **Pros:** Mature managed services (RDS, ElastiCache, IoT Core, MSK); closest AWS region to Ethiopia (~50 ms RTT); reliable; SOC2/ISO27001 certified.
- **Cons:** **Violates PDPP** — Bahrain is a foreign jurisdiction, personal data of Ethiopian residents cannot be stored there without explicit consent per data subject (impractical at B2C scale); B2B tenants with "no foreign cloud" clauses cannot be sold to; USD-denominated pricing exposed to ETB depreciation; egress charges compound at IoT telemetry volumes (5k devices × 100 msgs/day × $0.09/GB = meaningful cost). **Rejected.**

### Alternative B: AWS af-south-1 (Cape Town)
- **Pros:** Same as Bahrain; geographically in Africa (mildly better optics for an "African" company); slightly cheaper than Bahrain.
- **Cons:** **Same PDPP violation as Bahrain** — Cape Town is still a foreign jurisdiction; higher latency (~180 ms RTT from Ethiopia); African continent is large, "in Africa" is not the same as "in Ethiopia". **Rejected.**

### Alternative C: On-premises hosting (SHE-owned servers in an Addis office)
- **Pros:** Maximum control; no cloud-provider dependency; can be sold to government tenants as "fully sovereign."
- **Cons:** We don't own a data center — office space in Addis does not have industrial UPS, generator backup, fire suppression, or physical security (mantrap, CCTV, 24/7 staff); single-point-of-failure risk (one office fire = total platform outage); no IPv4 BGP / public ASN — we'd depend on Ethio Telecom for transit; insurance and compliance audit overhead. **Rejected for V3 — revisit only if a specific government-adjacent B2B tenant contractually requires on-prem hosting (then spin up a dedicated rack at that tenant's facility).**

### Alternative D: Azure South Africa North (Johannesburg)
- **Pros:** Same general value prop as AWS regions; Microsoft has historically had better enterprise relationships in Africa.
- **Cons:** Same PDPP violation as AWS Bahrain/Cape Town; higher latency than AWS Bahrain (~180 ms RTT); no Ethiopia-local Azure region planned. **Rejected.**

### Alternative E: Multi-region active-active (Addis + AWS Bahrain failover)
- **Pros:** Survives a national internet shutdown by failing over to Bahrain; geographic redundancy.
- **Cons:** **Violates PDPP** (Bahrain replica would hold personal data of Ethiopian residents); multi-region Postgres replication is complex and expensive; failover semantics for MQTT (persistent sessions, retained messages) are non-trivial; we'd pay for two clouds. **Rejected for V3 — revisit if PDPP is amended to permit contractual-necessity cross-border replication (then store only non-personal data in the failover region).**

## Consequences

### Positive
- **PDPP-compliant** — primary data stays in Ethiopia under our control; cross-border traffic is narrowly scoped and documented in DPIA
- **Low latency** — Ethiopian users see ~5–20 ms RTT to the broker vs ~50–180 ms to foreign AWS regions; MQTT commands feel instant
- **B2B-friendly** — ISPs, government-adjacent operators, and regulated industries can be told "your data is in Addis, in a DC you can physically visit"; this closes deals that AWS-hosted competitors cannot
- **USD-ETB exposure bounded** — Ethio Telecom Cloud bills in ETB, insulating the platform cost line from FX depreciation (B2B revenue is USD, B2C is ETB; costs in ETB is a natural hedge)
- **Single-region simplicity** — no cross-region replication, no failover orchestration, no split-brain risk for V3
- **Cloudflare + Ethio Telecom combination** — DDoS protection at the edge, low-latency origin in Addis

### Negative
- **Single point of failure** — if the Addis DC goes down (power, network, fire, civil unrest), the entire platform is down. Mitigation: design devices to fail-safe (relays hold last state, OTA resumes on reconnect, app shows cached state with "offline" banner)
- **National internet shutdown risk** — Ethiopia has had government-ordered internet shutdowns in recent years; during a shutdown, devices can still be controlled via BLE locally (V3-FIRMWARE.md §5) but cloud control is lost. Mitigation: BLE local control is a first-class feature, not a fallback
- **Higher cost than AWS at small scale** — Ethio Telecom Cloud VMs are priced for enterprise buyers; at our scale (3 EMQX + 2 Spring Boot + 2 Postgres + 2 Redis + 1 MinIO + 1 step-ca + 1 observability = 12 VMs) we estimate ~$800/month vs ~$600/month on AWS. The PDPP compliance is worth the $200/month premium
- **Limited provider choice** — Ethio Telecom Cloud is the only mature in-country cloud provider as of 2024-Q4; Safaricom Ethiopia Cloud is emerging but not yet enterprise-ready. If Ethio Telecom Cloud degrades, we have limited fallback options
- **Push notification tokens transit Google/Apple** — this is honestly disclosed in V3-DPIA.md and V3-PRIVACY-COMPLIANCE.md, but it is a deviation from the marketing "no data leaves Ethiopia" claim that must be communicated carefully to B2B prospects
- **Cloudflare is a foreign subprocessor** — TLS termination at the edge means Cloudflare briefly holds the TCP connection; not a data-residency issue (no HTTP body is decrypted at the edge) but a DPA relationship that must be disclosed

### Neutral
- The "Ethiopia only" data-residency claim is defensible but qualified — three subprocessors (FCM, APNs, Cloudflare) handle narrowly-scoped cross-border traffic under PDPP's contractual-necessity exception. This is the honest position; a "no data leaves Ethiopia ever" claim would be false
- step-ca CA server runs on an isolated network segment within the Addis DC, with the root CA offline (air-gapped machine + USB backup) per V3-SECURITY-MODEL.md §3.1
- Observability (Prometheus + Grafana) runs in Addis — alerting flows to PagerDuty (foreign subprocessor, narrowly scoped to alert metadata)

## References
- V3-OVERVIEW.md §2.1 (self-hosted device cloud, Addis hosting)
- V3-ARCHITECTURE.md §6 (infrastructure sizing, Ethio Telecom Cloud)
- V3-SECURITY-MODEL.md §3 (CA hosted on Addis DC)
- V3-PRIVACY-COMPLIANCE.md (subprocessor inventory, cross-border data flow)
- V3-DPIA.md (push notification tokens as cross-border traffic, lawful basis)
- ADR-001 (self-hosted cloud — precondition for Addis hosting)
- ADR-003 (multi-tenant RLS — Postgres runs in Addis)
- ADR-004 (cert-based MQTT auth — step-ca CA runs in Addis)
- Ethio Telecom Cloud: https://cloud.ethiotelecom.et/
