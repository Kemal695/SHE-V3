# ADR-004: X.509 Client Certificates for Device Authentication

**Status:** Locked
**Date:** 2024-Q4
**Decision maker:** Lead Engineer

## Context

Every SHE V3 device must authenticate to the EMQX MQTT broker before it can publish telemetry or accept commands. The auth mechanism must be: (1) cryptographic — no plaintext credentials to brute-force; (2) revocable per-device — a stolen/compromised unit can be killed from the cloud without touching the rest of the fleet; (3) provisionable at scale — 100+ devices per day at the factory, each with a unique identity; (4) survivable across broker restarts and CA rotations; (5) compatible with ESP32 hardware crypto (RSA-2048 verify in ~30 ms, ECDSA P-256 in ~5 ms).

Username/password is the default for many IoT platforms but fails all five criteria: passwords are brutable, revocation means changing every device's password, and there is no per-device cryptographic identity. JWT tokens expire hourly — wrong fit for a 10-year-life device that may sit on a shelf for 6 months before activation. Pre-shared keys (PSK) require per-device key distribution and have weaker crypto than X.509. OAuth2 client-credentials works for HTTP APIs but is awkward for long-lived MQTT sessions.

X.509 client certificates with mutual-TLS (mTLS) is the industry-standard answer: each device has a unique cert signed by our CA, the broker verifies the cert chain on every connection, and revocation is a CRL/OCSP lookup away. The operational cost is running our own CA — but ADR-001 already commits us to self-hosting, and step-ca (Smallstep) makes the CA lifecycle (issuance, rotation, CRL, intermediate rotation) a solved problem rather than an `openssl` CLI adventure.

## Decision

Use **X.509 client certificates** signed by **our own Certificate Authority** for device authentication to EMQX. The PKI is two-tier:

- **Root CA** — RSA 4096-bit, 20-year validity, stored on an air-gapped machine (or HSM if available). Signs only the intermediate CA. Never used to sign device certs directly.
- **Intermediate CA** — RSA 4096-bit, 10-year validity (rotated yearly, see below), stored on the step-ca server with the key encrypted at rest (AES-256-GCM, KEK in YubiHSM 2 in production).
- **Device cert** — RSA 2048-bit, 10-year validity, CN = normalized MAC address (e.g., `24:6F:28:AA:BB:CC`), SAN = `DNS:SHE-R8-AABBCC` (matches `node_id` in V3-DEVICE-MODEL.md §2.2). Private key generated in-chip on the ESP32 during provisioning; never leaves the device.

The CA is operated via **step-ca** (Smallstep), not raw `openssl` CLI. step-ca gives us: a configured provisioner model (JWK provisioner for factory, X5C provisioner for re-issuance), automated CRL generation, a JSON API for Spring Boot to call during provisioning, and audit logging of every cert issuance. See V3-CONFIGURATION.md §2 for the step-ca setup and V3-FACTORY-OPS.md §3 for the factory cert-issuance workflow.

Devices present their cert on every MQTT connection (mutual TLS to EMQX). EMQX is configured with `ca_bundle.pem` (root + intermediate) and verifies the chain on every connect. EMQX calls Spring Boot's `/internal/mqtt/auth` HTTP backend on each connect to check (a) the cert CN is a known `node_id`, (b) the cert serial is not on the CRL, (c) the device's `tenant_id`/`home_id` allows the topic ACL it's about to use.

**Intermediate CA rotation** is yearly, zero-downtime, with overlap window — see V3-SECURITY-MODEL.md §3.3 for the 5-step procedure. Device certs are 10-year validity; a single device will cross ~10 intermediate rotations and continue to validate via the bundle.

## Alternatives Considered

### Alternative A: JWT tokens (signed by Spring Boot, short-lived)
- **Pros:** No PKI to operate; Spring Boot already issues user JWTs so the code is shared; tokens expire naturally (no revocation list needed).
- **Cons:** Devices must mint a fresh JWT before each MQTT connect — requires HTTP round-trip to Spring Boot with a long-lived credential (which is just PSK in disguise); MQTT sessions are long-lived (LWT-style), JWT model fights this; ESP32 has no secure clock source (NTP dependency for `exp` validation); if Spring Boot is down, devices cannot reconnect after a broker disconnect. **Rejected.**

### Alternative B: Pre-Shared Keys (PSK) with TLS-PSK cipher suites
- **Pros:** No cert overhead; smaller handshake; simpler to reason about (one secret per device).
- **Cons:** Weaker crypto (PSK ciphersuites are deprecated in TLS 1.3); per-device PSK distribution is operationally identical to per-device cert issuance but without the chain-of-trust properties; no standard way to revoke a PSK short of pushing an updated PSK list to the broker; EMQX's PSK support is via a custom hook (less battle-tested than mTLS); no defense against a broker-side PSK leak. **Rejected.**

### Alternative C: OAuth2 client-credentials flow (device-as-oauth-client)
- **Pros:** Standard pattern for HTTP APIs; reuses existing OAuth2 infrastructure if we had it; refresh-token rotation is well-understood.
- **Cons:** Designed for HTTP request/response, not long-lived MQTT sessions; the device would need to refresh the access token hourly, breaking MQTT session continuity; OAuth2 doesn't define a native MQTT binding — we'd be inventing one; OAuth2 token introspection on every MQTT publish is expensive; EMQX's OAuth2 support is newer and less mature than mTLS. **Rejected.**

### Alternative D: Public CA (Let's Encrypt / DigiCert) for device certs
- **Pros:** No CA to operate; trusted everywhere.
- **Cons:** Let's Encrypt caps cert validity at 90 days (untenable for devices that may sit on a shelf for 6 months); DigiCert charges per-cert (10k certs × $50/yr = $500k/yr); public CAs will not issue certs with our chosen CN scheme (MAC address); public CAs add a subprocessor (DigiCert/ISRG) to our DPIA; revocation via public OCSP/CRL is at the CA's latency, not ours. **Rejected.**

### Alternative E: Raw OpenSSL CLI for CA (no step-ca)
- **Pros:** No new tool to learn; `openssl ca` is universally available.
- **Cons:** No provisioner model (anyone with the CA key can issue any cert); no audit log by default; CRL generation is manual and error-prone; intermediate rotation is a hand-rolled script; no API for Spring Boot to call — we'd shell out to `openssl`; key custody is "wherever the key file is" with no HSM integration. **Rejected — this is how PKI gets pwned.**

## Consequences

### Positive
- Cryptographic per-device identity — no shared secret, no password to brute-force, no plaintext credentials in NVS
- Per-device revocation via CRL — stolen/compromised unit is killed from the Admin Console without touching any other device
- Industry-standard mTLS — EMQX, Spring Boot, and the ESP32 IDF all have first-class support; no custom crypto
- Chain-of-trust properties — adding a new device is just "sign its CSR with the intermediate"; rotating trust is just "ship a new CA bundle via OTA"
- 10-year device cert validity means most devices never need re-issuance in their service life
- Audit trail — step-ca logs every cert issuance with operator identity, timestamp, and target MAC (V3-FACTORY-OPS.md §1)

### Negative
- CA operation is real operational burden — root key custody (air-gapped machine + offline USB backup, HSM if affordable), intermediate rotation procedure, CRL distribution
- step-ca is one more service to operate (one more thing that can break at 02:00) — mitigated by step-ca being a single Go binary with a small config surface
- Per-device cert issuance at factory adds ~0.5 s/unit to the flash cycle (parallelizable to 4 units at once — V3-FACTORY-OPS.md §3)
- Cert chain in NVS takes ~3 KB of flash (cert + intermediate + key) — negligible but non-zero
- If the intermediate CA key is compromised, every device cert signed by it is suspect until OTA-shipped new bundle propagates — mitigated by yearly rotation + air-gapped root

### Neutral
- We use RSA-2048 for device certs (not ECDSA) for broad ESP32 hardware acceleration compatibility — ECDSA P-256 would be faster (~5 ms vs ~30 ms handshake) but RSA is the safer default for now. Revisit in V4.
- step-ca is an open-source Smallstep product — we depend on their release cadence and security posture, but it is widely deployed and the code is auditable
- The CRL is fetched by EMQX on every connect — at 5k concurrent devices this is a hot path; mitigated by Redis-cached CRL lookup in `/internal/mqtt/auth` (V3-API-SPECIFICATION.md §15)

## References
- V3-SECURITY-MODEL.md §3 (own CA + X.509 mTLS, intermediate rotation procedure, EMQX config)
- V3-CONFIGURATION.md §2 (step-ca setup)
- V3-FACTORY-OPS.md §3 (factory cert-issuance workflow, bulk generation)
- V3-API-SPECIFICATION.md §15 (`/internal/mqtt/auth` EMQX auth backend, `/internal/factory/register-cert`)
- V3-DPIA.md (CA as a subprocessor activity, key custody as a control)
- ADR-001 (self-hosted cloud — precondition for own CA)
- ADR-013 (firmware security — Flash Encryption protects the cert+key in NVS)
- ADR-014 (factory flashing — certs are pre-provisioned at the factory, not on user first-boot)
