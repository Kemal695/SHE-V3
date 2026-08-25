# ADR-014: Pre-Flash Device Certificates at Factory via step-ca + Admin CLI

**Status:** Locked
**Date:** 2025-Q1
**Decision maker:** Lead Engineer + Hardware Lead

## Context

Every SHE V3 device needs an X.509 client certificate (ADR-004) before it can connect to the EMQX MQTT broker. The certificate (CN = MAC address, signed by our intermediate CA) and its private key must be present in the device's NVS at first boot — there is no "claim-on-first-boot" path where the device fetches its cert from the cloud, because the device cannot reach the cloud without a cert (chicken-and-egg).

The cert issuance workflow has three constraints: (1) **scale** — the factory must process 100+ units per day per workstation, with a 90-second test cycle per unit (V3-HARDWARE.md §7.3); (2) **security** — the device private key must never leave the device, and the cert issuance must be auditable per MAC for PDPP/ECA compliance; (3) **offline-tolerance** — the factory floor in Shenzhen does not have reliable access to the Addis Ababa step-ca server, so cert issuance must work either against a local step-ca instance at the factory or via a pre-generated batch that the factory imports.

The two natural options are: (a) **factory pre-flash** — generate the cert + key at the factory, write them to the device's `fctry` NVS partition before the unit is sealed in its enclosure; (b) **claim-on-first-boot** — the device generates a CSR on first boot at the user's home, the user's app submits it to the cloud via a one-time `claim_token`, the cloud signs and returns the cert. Option (b) is what RainMaker and AWS IoT Core use; option (a) is what serious B2B IoT fleets use.

For SHE V3, option (b) fails because: the user's home internet may be unreliable (the device is stuck without a cert and cannot be controlled), the BLE provisioning flow (V3-FIRMWARE.md §5) becomes a 3-step dance (BLE → CSR → cert install) instead of a 1-step (BLE → already has cert), and the factory cannot do MQTT-connect QC (V3-HARDWARE.md §7.3 step 8) without a cert. Option (a) is the right answer.

## Decision

Pre-flash device X.509 certificates at the factory using the **`she-admin` Admin CLI** wrapping **step-ca** for cert issuance and **esptool** for flashing. **The ESP32 generates its own ECDSA P-256 keypair on-chip — the factory workstation NEVER has the private key.** This is the canonical decision per CANONICAL-DECISIONS.md P0-1 (earlier drafts of this ADR had the factory generating the private key locally via `step`; that was wrong). The full workflow is documented in V3-FACTORY-OPS.md §3–5; the summary:

1. **Factory workstation setup** (before flashing begins):
   - `step-ca` running locally on the factory workstation (or a dedicated factory CA server), with the factory intermediate CA cross-signed by the production root CA (see V3-CONFIGURATION.md §2)
   - The Admin CLI is authenticated to step-ca via a long-lived factory JWT
   - No pre-generated batch of certs/keys is needed — each device generates its own keypair on-chip

2. **Per-device factory flash + cert issuance** (the 90-second test cycle):
   - Operator places PCB on pogo-pin jig → Admin CLI flashes firmware via esptool
   - **ESP32 boots in factory mode** and executes the on-chip key generation flow:
     1. Firmware calls `mbedtls_ecdsa_genkey()` → generates **ECDSA P-256 keypair in RAM**
     2. Private key written to `fctry` NVS partition (encrypted via Flash Encryption — ADR-013)
     3. Firmware generates **CSR** with `CN={MAC_ADDRESS}`
     4. Factory workstation **reads CSR from ESP32 over USB serial** (the CSR is public; only the private key stays on-chip)
     5. Factory workstation sends CSR to step-ca: `step ca sign {csr} --not-after=43800h` (5-year validity)
     6. step-ca signs the cert (intermediate CA, ECDSA P-256, 5-year)
     7. Cert returned to ESP32 over USB serial, stored in `fctry` NVS
     8. Factory workstation logs cert fingerprint + MAC + node_id to `factory_audit_log` — **but NEVER has the private key**
   - QC test runs (V3-HARDWARE.md §7.3): visual, power, Wi-Fi, BLE, relay cycle, PZEM, **cert verification (MQTT connect to factory broker)**, QR sticker print, final QC
   - **Last step: burn production eFuses** (canonical 8-step sequence per CANONICAL-DECISIONS.md P0-3 — see §3 below)
   - Admin CLI calls `POST /internal/factory/register-cert` on the SHE Spring Boot API (authenticated by a long-lived factory JWT), registering the `node_id` ↔ cert serial ↔ MAC mapping in the `device_certs` table

3. **eFuse burn sequence** (canonical, per CANONICAL-DECISIONS.md P0-3) — all burns via `espefuse.py`, in order:
   ```bash
   # 1. Burn Secure Boot key (AES-256, used for Secure Boot v2 digest)
   espefuse.py burn_key BLOCK_KEY0 secure_boot_key.bin SECURE_BOOT_DIGEST

   # 2. Burn Flash Encryption HMAC key (used for flash encryption + NVS encryption)
   espefuse.py burn_key BLOCK_KEY1 flash_enc_key.bin HMAC_DOWN_ENCRYPT

   # 3. Burn Ed25519 OTA verification public key (immutable, used for OTA signature verify)
   espefuse.py burn_key BLOCK_KEY2 ota_ed25519_pubkey.bin USER

   # 4. Set initial SECURE_VERSION (anti-rollback, popcount semantics)
   espefuse.py burn_efuse SECURE_VERSION 0x01

   # 5. Disable JTAG (physical debug access)
   espefuse.py burn_efuse DIS_PAD_JTAG 1
   espefuse.py burn_efuse DIS_DOWNLOAD_JTAG 1

   # 6. Disable download mode (UART flashing)
   espefuse.py burn_efuse DIS_DOWNLOAD_MODE 1

   # 7. Enable Secure Boot (IRREVERSIBLE — after this, only signed firmware boots)
   espefuse.py burn_efuse SECURE_BOOT_EN 1

   # 8. Enable Flash Encryption (IRREVERSIBLE — encrypts all flash on next boot)
   #    On ESP32-S3, use esp_flash_encrypt from IDF (it handles FLASH_CRYPT_CNT correctly)
   #    OR manually: espefuse.py burn_efuse FLASH_CRYPT_CNT 0xFF
   esp_flash_encrypt
   ```
   **Note on Flash Encryption (per CANONICAL-DECISIONS.md P1-5):** Do NOT manually burn `FLASH_CRYPT_CNT 0x7F`. Use `esp_flash_encrypt` from ESP-IDF — it handles platform differences correctly. On ESP32-S3, this sets `FLASH_CRYPT_CNT` to `0xFF` (all 8 bits). On the ESP32-C3 (SHE-R4), `BLOCK_KEY2` (Ed25519 OTA pubkey) is NOT available — the Ed25519 pubkey is compiled into firmware (protected by Secure Boot). This is a documented C3 limitation (ADR-012).

4. **Cert + key storage** on the device:
   - Stored in the `fctry` NVS partition (read-only after factory, encrypted by Flash Encryption — ADR-013)
   - Layout: `fctry.cert` (PEM), `fctry.key` (PEM, encrypted at rest), `fctry.pop` (9-digit string), `fctry.node_id` (string), `fctry.sku` (string), `fctry.fw_version` (string)
   - The `fctry` partition is the Espressif convention for factory-burned calibration/provisioning data — separate from the runtime `nvs` partition, never overwritten by OTA

5. **Audit trail**:
   - Every CSR submission, cert issuance, flash, and eFuse burn is logged to `factory_audit_log` (10-year retention, PDPP + ECA compliance) with: batch_id, MAC, node_id, cert serial, cert fingerprint, operator, timestamp, workstation ID
   - The private key is NEVER logged, NEVER stored on the factory workstation, NEVER transmitted over USB serial — only the CSR (public) and the signed cert (public) transit the USB link

## Alternatives Considered

### Alternative A: Claim-on-first-boot (device generates CSR at user's home, app submits to cloud)
- **Pros:** No cert generation at the factory (factory just flashes firmware); key is generated in-chip (truly never leaves the device); no batch cert files to manage; standard RainMaker/AWS IoT pattern.
- **Cons:** **Requires internet at user's site** — Ethiopian home internet is unreliable; if the user's Wi-Fi is down on setup day, the device is a brick; the BLE provisioning flow becomes a 3-step dance (BLE pair → CSR generation → cloud CSR submission → cert install) instead of a 1-step (BLE pair → already has cert, just connect Wi-Fi); factory cannot do MQTT-connect QC (V3-HARDWARE.md §7.3 step 8) because the device has no cert at factory exit; harder UX for non-technical users (the app must walk them through "wait while we provision your device's security certificate"); a cloud outage on setup day blocks all new device activations. **Rejected — fails the Ethiopian-market reliability requirement.**

### Alternative B: Manual cert per device (engineer hand-generates each cert)
- **Pros:** No factory tooling needed; full manual control; each cert is reviewed before flashing.
- **Cons:** **Does not scale** — at 100 units/day, an engineer would spend 8 hours/day generating certs; impossible at 5,000 units/year; error-prone (manual MAC entry, manual QR generation); no audit trail (just `openssl` CLI invocations in a shell history); does not integrate with the factory test jig. **Rejected — operationally untenable at scale.**

### Alternative C: No device certs (use MAC-based auth or shared PSK)
- **Pros:** No cert generation, no CA, no NVS cert storage; factory just flashes firmware.
- **Cons:** **No cryptographic per-device identity** — a MAC address is spoofable in software; a shared PSK means compromising one device compromises the fleet; fails the security model in ADR-004 entirely; EMQX cannot do per-device revocation; B2B tenants with "no foreign cloud" clauses also typically require cert-based auth. **Rejected — security posture unacceptable.**

### Alternative D: ~~On-device key generation~~ — ADOPTED (was previously rejected)
- **Previous status:** Rejected for V3 — the CSR round-trip was estimated at 5–8 seconds per unit, exceeding the 90-second test cycle.
- **Reconsideration:** Subsequent benchmarking showed **ECDSA P-256 keypair generation on the ESP32-S3 takes ~10ms** (hardware-assisted), and CSR generation + USB serial read takes <1 second total. The 90-second cycle has ample headroom. The previous rejection was based on a faulty RSA-2048 estimate (~2 seconds); switching to ECDSA P-256 (per CANONICAL-DECISIONS.md P0-2) eliminates the bottleneck.
- **Current status:** **ADOPTED as the canonical decision per CANONICAL-DECISIONS.md P0-1.** This is now the model described in the Decision section above. The factory workstation NEVER has the private key — only the CSR (public) and signed cert (public) transit the USB serial link. This eliminates the largest negative consequence of the previous factory-generated-key model (no factory workstation trust required for key confidentiality).

### Alternative E: Certs pre-generated by Addis CA, shipped to factory as encrypted bundle
- **Pros:** Addis team controls the CA; factory never sees the CA key; bundle is cryptographically sealed.
- **Cons:** Adds a shipping dependency (Addis must generate the batch and securely transfer it to Shenzhen before the factory can run); introduces a delay (batch generation → secure transfer → factory import → flash); the secure transfer itself is a new attack surface (bundle decryption key custody at the factory); V3-FACTORY-OPS.md §2.1 already runs a step-ca instance on the factory workstation or a dedicated factory CA server, so the Addis-CA dependency is unnecessary. **Rejected — adds operational complexity without security benefit, given the factory-local step-ca approach.**

## Consequences

### Positive
- **Factory controls the full provisioning lifecycle** — firmware flash, on-chip key generation, CSR submission, cert issuance, QC, eFuse burn, and audit logging all happen in one workstation, in one 90-second cycle per unit
- **Device works out-of-the-box** — at user first-boot, the cert is already in NVS; the device connects to EMQX immediately on Wi-Fi join; no claim-on-first-boot dance; no internet dependency at setup time
- **Private key NEVER leaves the device** (per CANONICAL-DECISIONS.md P0-1) — the ESP32 generates its own ECDSA P-256 keypair on-chip; the factory workstation, factory operator, and factory step-ca only ever see the CSR (public) and the signed cert (public). This is the strongest possible PKI hygiene for factory provisioning.
- **Factory QC includes MQTT-connect test** — every unit is verified to actually authenticate to a factory broker before it ships (catches cert-format errors, CA-trust errors, NVS-write errors at the factory, not in the customer's home)
- **Audit trail** — every CSR + cert issuance + eFuse burn is logged with batch_id, MAC, node_id, cert serial, cert fingerprint, operator, timestamp; PDPP + ECA defensible
- **QR codes printed at factory** — the QR sticker (BLE provisioning PoP + node_id + setup URL) is printed at the factory, applied to the enclosure, and verified before sealing
- **Works offline** — the factory step-ca runs locally; no Addis-CA dependency during the flash cycle

### Negative
- **~~Private key is generated off-device~~** — **RESOLVED.** Earlier drafts of this ADR had the factory workstation generate the private key via `step` and flash it to the device. That model is **no longer in use** — per CANONICAL-DECISIONS.md P0-1, the ESP32 generates its own ECDSA P-256 keypair on-chip, and the factory workstation NEVER has the private key. The previous trade-off (factory workstation trusted with key material) is eliminated.
- **Factory step-ca is a new attack surface** — if the factory workstation or its step-ca is compromised, an attacker could sign certs for arbitrary MACs. Mitigation: factory step-ca uses a factory-specific intermediate CA (not the production intermediate); production-CA-trust is established only when the device first connects to the production EMQX with its factory-signed cert (factory intermediate is in the device's CA bundle and is cross-signed by the production root). Note: even if the factory step-ca is compromised, the attacker cannot extract existing device private keys (they're on-chip, never transited the workstation).
- **5-year cert validity means factory burn-in is 5 years** — devices that sit on a shelf for >5 years before activation will have expired certs; mitigated by V3-FACTORY-OPS.md §8 (RMA + re-provisioning procedure for shelf-stale stock)
- **Factory workstation operator is a trusted role** — the operator can theoretically submit a CSR for an arbitrary MAC (issuing a valid cert for a counterfeit device). Mitigation: factory workstation enforces per-operator audit logging; MACs are scanned from the PCB's barcode (not manually entered); the cert-issuance rate is monitored against the production schedule (a spike in CSRs above the planned batch size triggers an alert)
- **CSR round-trip adds ~1 second per unit** — the ESP32 must generate a keypair, build a CSR, and accept the signed cert over USB serial. With the 90-second test cycle, this is ~1% overhead and well within budget. No mitigation required.

### Neutral
- The factory step-ca instance is a separate deployment from the Addis production step-ca (ADR-004) — they use different intermediate CA keys (the factory intermediate is cross-signed by the production root). This is standard PKI hygiene for "issuing CA at the factory, root CA in the data center"
- The QR sticker contains the BLE PoP — anyone who reads the QR before the device is paired can pair the device. Mitigation: the QR is on the bottom of the enclosure, under a tamper-evident seal; the PoP is also invalidated after first successful pairing
- The `fctry` NVS partition is read-only after factory (firmware uses it for cert + PoP + node config, never writes to it) — OTA cannot modify it; mitigates a class of attacks where malicious OTA replaces the cert

## References
- V3-FACTORY-OPS.md (full factory workflow: cert generation, flashing, QC, eFuse burn, audit logging)
- V3-CONFIGURATION.md §2 (step-ca setup, factory vs production CAs)
- V3-SECURITY-MODEL.md §3 (CA hierarchy, cert lifecycle, intermediate rotation)
- V3-HARDWARE.md §7.3 (factory production test procedure, 90-second cycle, MQTT-connect QC)
- V3-API-SPECIFICATION.md §15 (`/internal/factory/register-cert` endpoint, `/internal/mqtt/auth` EMQX backend)
- ADR-001 (self-hosted cloud — precondition for own CA + factory-local step-ca)
- ADR-004 (cert-based MQTT auth — the certs this ADR pre-flashes)
- ADR-013 (firmware security — the eFuses this ADR burns as the last step)
- step-ca docs: https://smallstep.com/docs/step-ca/
