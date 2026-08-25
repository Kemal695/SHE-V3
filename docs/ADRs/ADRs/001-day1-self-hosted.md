# ADR-001: Fully Self-Hosted Device Cloud from Day 1

**Status:** Locked
**Date:** 2024-Q4
**Decision maker:** Lead Engineer

## Context

SHE V3 needs a device cloud that handles MQTT messaging, OTA firmware distribution, device provisioning, telemetry ingestion, and time-series storage. The classic shortcut for an IoT startup is to bolt onto a third-party managed IoT platform — AWS IoT Core, Azure IoT Hub, Google Cloud IoT, or Espressif's own ESP RainMaker — and defer the operational burden of running a broker and a CA.

For SHE V3 that shortcut is not viable. The Ethiopian Data Protection Proclamation (PDPP) requires personal data to remain in-country under the control of a data controller registered with the ECA. Several B2B target tenants (ISPs, hotel groups, government-adjacent operators) have contractual clauses that explicitly prohibit device telemetry from transiting foreign cloud regions. A managed IoT platform also introduces per-device pricing (typically $0.08–$0.50/device/month) that compounds with our volume SKU forecast of 5,000 registered devices in year 1 and 50,000 by year 3. Finally, vendor lock-in on the device-auth and OTA paths is a strategic risk: any vendor that changes pricing or deprecates an API can hold the fleet hostage.

This decision is the load-bearing architectural choice for V3 — it forces us to operate our own EMQX cluster, our own CA, our own OTA store, and our own time-series store. It is also the precondition for several other ADRs: ADR-004 (own CA + X.509 mTLS), ADR-008 (Addis Ababa hosting), ADR-011 (RainMaker hierarchy adoption, data model only), and ADR-014 (factory flashing).

## Decision

Build the entire device cloud ourselves on SHE-owned infrastructure in Addis Ababa. No third-party IoT platform at any layer. The stack is:

- **EMQX 5.x** (3-node cluster) for MQTT messaging with mutual-TLS
- **Our own Certificate Authority** (root + intermediate) managed via step-ca, issuing X.509 client certs per device (ADR-004)
- **Spring Boot 3.x** for REST API, auth, multi-tenancy, automations, payments
- **PostgreSQL 16** with Row-Level Security (ADR-003) and **TimescaleDB** for telemetry
- **MinIO** for OTA firmware image storage
- **Redis 7** for cache, session state, JWT blacklist, idempotency keys
- **Cloudflare** for DDoS protection + DNS only — TLS terminates at the edge, but data at rest and MQTT traffic stays in Ethiopia

This is a **day-1 commitment**, not a "start self-hosted then migrate to RainMaker later" plan. The architectural cost of porting a fleet of devices between broker/PKI/OTA vendors mid-flight is far higher than the operational cost of running those services ourselves from the start.

> **Clarification on ADR-011 (RainMaker hierarchy):** SHE V3 *does* adopt the ESP RainMaker **data hierarchy** (Node → Device → Service → Parameter → Attribute) as its device model — see V3-DEVICE-MODEL.md and ADR-011. This is the conceptual model only. It does **not** mean we adopt the RainMaker cloud service, the RainMaker MQTT broker, the RainMaker OTA pipeline, or the RainMaker console. The RainMaker cloud service is exactly the kind of third-party IoT platform this ADR rejects. There is no contradiction: we borrow the schema, not the service.

## Alternatives Considered

### Alternative A: ESP RainMaker cloud (managed)
- **Pros:** Zero broker/CA/OTA infrastructure to operate; tight ESP32 firmware integration via `esp_rmaker_*` SDK calls; built-in Apple Home / Google Home / Alexa integrations via RainMaker's cloud skills; faster time-to-market.
- **Cons:** Violates PDPP data residency (RainMaker runs on AWS, region not in Ethiopia); per-device pricing ($0.10–$0.30/device/month estimated at scale); vendor lock-in on device auth, OTA, and topic namespace; B2B tenants with "no foreign cloud" clauses cannot be sold to; RainMaker's billing portal is USD-only and not B2B white-label. **Rejected.**

### Alternative B: AWS IoT Core (me-south-1 Bahrain or af-south-1 Cape Town)
- **Pros:** Mature, well-documented, scalable; per-device pricing is transparent; integrates with the rest of AWS (Lambda, IoT Analytics, Greengrass) if we ever need it.
- **Cons:** No AWS region in Ethiopia — Bahrain is ~50 ms RTT and Cape Town ~180 ms RTT, both of which cross a national border and violate PDPP for personal data; AWS IoT Core's pricing model ($0.08/million msgs + $0.50/GB egress + per-cert attached-principal fee) is unfavorable for high-frequency telemetry; we'd still need our own CA or pay AWS PCA per cert; B2B "no foreign cloud" clauses still violated. **Rejected.**

### Alternative C: Azure IoT Hub
- **Pros:** Same general value prop as AWS IoT Core; first-class MQTT support; Azure Sphere is a (very different) end-to-end story.
- **Cons:** Same data-residency issue (no Ethiopia region — closest is South Africa North, Johannesburg); per-device pricing tier limits (S1/S2/S3 tiers cap daily messages); weaker fit for our ESP32 + EMQX + Postgres stack; no upside over AWS for our use case. **Rejected.**

### Alternative D: Hybrid — own broker, third-party OTA (e.g., Mender Cloud, AWS IoT Jobs)
- **Pros:** Lets us skip operating object storage + an OTA orchestration service.
- **Cons:** Introduces a third-party subprocessor with device-identifiable data (firmware version, MAC, serial); requires another data-processing agreement; doesn't actually save much operational pain — MinIO + a Spring Boot `/ota` endpoint is a small surface area. **Rejected.**

## Consequences

### Positive
- Full control of every byte of device and user data — PDPP-compliant and B2B-tenant-friendly out of the box
- No per-device cloud fees — the only marginal cost of a new device is the cert issuance (one-time, ~0.1 s of step-ca CPU)
- We own the MQTT topic namespace, OTA versioning policy, and device auth lifecycle end-to-end; nothing can be deprecated out from under us
- B2B white-label tenants can be told truthfully that "no device data leaves Ethiopia" — a hard sales requirement for ISP and government-adjacent accounts
- CA and broker are co-located, so mTLS handshake latency is sub-millisecond inside the Addis DC

### Negative
- We have to operate EMQX at 3-node HA — this is real operational burden (upgrades, config drift, broker cert rotation, ACL debugging)
- We have to operate a step-ca CA with proper key custody (root key air-gapped, intermediate in HSM if affordable) — security team must own this, not ad-hoc
- We have to operate MinIO, Postgres, TimescaleDB, and Redis ourselves — the typical "managed cloud" convenience is gone
- No vendor SLA — if the EMQX cluster goes down at 02:00 on a Sunday, it is *our* on-call, not AWS Support
- Step-ca and EMQX expertise is scarce in the Addis hiring market; we will be training from scratch
- We carry the cost of capacity planning ourselves — no auto-scaling group magic; we must size VMs for peak MQTT concurrency (5,000 concurrent device connections in year 1, 50,000 by year 3)

### Neutral
- The operational maturity required for self-hosting effectively forces us to write proper runbooks, dashboards, and on-call rotations earlier than a team using AWS IoT Core would — this is a long-term positive but a short-term tax
- Cloudflare remains a foreign subprocessor (for DDoS + DNS only, no device data) — documented honestly in V3-DPIA.md and V3-PRIVACY-COMPLIANCE.md
- The choice is reversible in principle (we could migrate to AWS IoT later) but expensive in practice — the device cert issuance, MQTT topic namespace, and OTA pipeline would all need migration
- Self-hosting is a hiring filter — engineers who join SHE V3 will be exposed to "real" infrastructure (broker ops, CA management, PKI rotation) which is rare in the Ethiopian market; this is both an attraction and a training burden

## References
- V3-OVERVIEW.md §2.1 (self-hosted device cloud)
- V3-ARCHITECTURE.md (system architecture, data flows)
- V3-SECURITY-MODEL.md §3 (own CA + X.509 mTLS)
- V3-FACTORY-OPS.md (factory workflow that depends on self-hosted CA + API)
- V3-PRIVACY-COMPLIANCE.md + V3-DPIA.md (PDPP data residency)
- ADR-004 (cert-based MQTT auth — depends on this ADR)
- ADR-008 (Addis Ababa hosting — where this ADR's infra physically lives)
- ADR-011 (RainMaker hierarchy — clarifies the data-model-only vs cloud-service distinction)
