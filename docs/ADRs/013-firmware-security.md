# ADR-013: Firmware Security — Secure Boot v2, Flash Encryption, Anti-Rollback, JTAG/UART Disable

**Status:** Locked
**Date:** 2025-Q1
**Decision maker:** Lead Engineer + Security Reviewer

## Context

A relay controller that switches 220VAC mains is a physical safety device as well as a networked computer. An attacker who compromises the firmware of a deployed SHE device could: (1) brick the device (denial of service); (2) hold the relays in a fixed state (e.g., always-on, causing fire risk from a forgotten heater); (3) use the device as a pivot point into the user's home Wi-Fi network; (4) extract the device's X.509 private key (ADR-004) and impersonate it on the MQTT broker; (5) push malicious OTA firmware to the whole fleet if they can sign with a stolen firmware signing key.

The original V3 docs had a critical gap: firmware security (Secure Boot, Flash Encryption, anti-rollback, debug interface disablement) was not addressed at all. The V3-OVERVIEW.md §7.3 review explicitly flagged this as one of the "technical errors fixed" during the documentation finalization. This ADR fills that gap.

The threat model includes both **remote attackers** (who might exploit a network vulnerability to push malicious firmware) and **physical attackers** (who have stolen or borrowed a device, have a soldering iron, and want to extract keys or flash modified firmware). The latter is the harder threat model — physical access is generally assumed to be game-over in security, but for an IoT device fleet we want to raise the bar from "anyone with a USB-to-UART adapter" to "a well-funded lab with electron microscopy."

Espressif's ESP32-C3 (R4) and ESP32-S3 (R8/R16) — chosen in ADR-012 — both support a coherent hardware-rooted security stack: Secure Boot v2 (signed firmware + bootloader verification), Flash Encryption (AES-256-XTS of flash contents at rest), eFuses (one-time-programmable bits that permanently store key material and configuration), and runtime-disableable JTAG/UART. This ADR commits to enabling all of them on production builds.

## Decision

Enable the full Espressif hardware-rooted firmware security stack on **all production SHE V3 devices**:

1. **Secure Boot v2** — the bootloader verifies the signature of the application firmware on every boot, using a public key hash burned into eFuse. Only firmware signed by our private signing key (held offline, in the Lead Engineer's custody on an air-gapped machine) will boot. The bootloader itself is signed and verified by the ROM (immutable on-chip boot code). No unsigned firmware runs, ever, on a production device.
2. **Flash Encryption (RELEASE mode)** — the contents of the SPI flash (firmware binary, NVS partitions including the `fctry` partition holding the device cert + private key, NVS encryption keys) are encrypted at rest with AES-256-XTS. The flash encryption key is stored in eFuse and never leaves the chip. An attacker who desolders the flash chip and reads it on a programmer sees ciphertext, not the device cert or firmware.
3. **Anti-rollback eFuses** — each firmware release carries a `security_version` field; the chip stores the highest accepted `security_version` in an eFuse counter. A firmware OTA that lowers the version (e.g., a downgrade attack reverting to a version with a known vulnerability) is rejected. The eFuse counter is one-way — it can only be incremented, never decremented.
4. **JTAG disable in production** — JTAG and download-mode debug interfaces are disabled by burning the standard ESP32-S3 eFuses: `DIS_PAD_JTAG` (disables JTAG on pads), `DIS_DOWNLOAD_JTAG` (disables JTAG in download mode), `DIS_DOWNLOAD_MODE` (disables UART download mode entirely), and `DIS_USB_JTAG` (disables USB-JTAG). The UART console is set to log-only (no interactive bootloader prompt). Factory flashing is done before these eFuses are burned; the last factory step burns them. (Per CANONICAL-DECISIONS.md P1-7 — earlier drafts referenced non-standard names like `DIS_DOWNLOAD_DCACHE`, `USB_DIS_DOWNLOAD_DPIC`, `CONSOLE_DEBUG_DISABLE`; those are not real ESP32-S3 eFuse fields.)
5. **NVS Encryption** — the `fctry` (factory cert + key + PoP) and `nvs.device_keys` (runtime) NVS partitions are encrypted with NVS-encryption keys derived from the Flash Encryption key, separate from the firmware binary. Even an attacker who extracts the firmware binary cannot read the cert + key without the NVS-encryption key.
6. **Key types and custody (per CANONICAL-DECISIONS.md P0-2):** Three distinct keys are in play, none of them shared across purposes:
   - **Device identity cert** — **ECDSA P-256** keypair, generated on-chip by the ESP32 (mbedTLS). Private key never leaves the device. Cert is signed by the RSA-4096 intermediate CA, 5-year validity. This is what the device presents to EMQX for mTLS.
   - **Secure Boot key** — **AES-256** key, burned into eFuse `BLOCK_KEY0` (purpose `SECURE_BOOT_DIGEST`) at factory. Used for Secure Boot v2 digest verification. Generated on an air-gapped machine, stored on a YubiHSM 2, never present on any internet-connected machine. CI/CD does not sign production firmware — releases are signed manually by the Lead Engineer on the air-gapped machine. See V3-CONFIGURATION.md §3.
   - **Flash Encryption HMAC key** — separate AES-256 key burned into eFuse `BLOCK_KEY1` (purpose `HMAC_DOWN_ENCRYPT`). Used for flash encryption + NVS encryption.
   - **CA chain** — Root CA (RSA-4096, 20-year, self-signed, air-gapped) and Intermediate CA (RSA-4096, 10-year, HSM-backed via YubiHSM 2). These sign device certs only; they are not used for firmware signing or Secure Boot.

   **Earlier drafts of this ADR incorrectly stated that Secure Boot used RSA-PSS 3072-bit. That was wrong — Secure Boot on ESP32-S3 uses its own AES-256 key (per CANONICAL-DECISIONS.md P0-2). RSA-PSS is not used anywhere in the SHE V3 security stack.**

The development builds (internal test units, factory test jigs, engineering samples) ship with Secure Boot *disabled* and Flash Encryption *disabled* — this allows the firmware team to flash debug builds and inspect NVS during development. The factory flashing procedure (ADR-014, V3-FACTORY-OPS.md §5) burns the production eFuses as the last step before the unit is sealed in its enclosure.

## Alternatives Considered

### Alternative A: No Secure Boot, no Flash Encryption (ship development-mode firmware)
- **Pros:** Zero configuration burden; firmware team can flash any build on any device with a USB cable; no signing key custody; OTA is a simple `esptool write_flash`.
- **Cons:** **Any attacker with a USB-to-UART adapter can flash malicious firmware on a stolen/borrowed device** — the firmware binary is unsigned and the bootloader accepts any image; the device cert + private key (ADR-004) in NVS is plaintext and extractable; an attacker who extracts the cert can impersonate the device on the broker even after the legitimate device is powered off; makes the entire cert-based mTLS auth (ADR-004) meaningless. **Rejected — defeats the device-auth security model.**

### Alternative B: Software-only firmware signing (verify signature in app, not bootloader)
- **Pros:** Slightly easier to set up than Secure Boot v2; can be added to existing firmware without bootloader changes; no eFuse burning.
- **Cons:** **The bootloader can be bypassed with physical access** — an attacker with a USB-to-UART adapter can put the chip in download mode and write a new bootloader that skips the signature check, then write a malicious app; software signing protects against remote OTA tampering but not physical tampering; the cert in NVS is still plaintext (no Flash Encryption in this alternative); fails the "well-funded lab" threat model. **Rejected — does not survive physical access.**

### Alternative C: Secure Boot v1 (the deprecated scheme supported by ESP32-WROOM-32)
- **Pros:** Works on the WROOM-32 (Alternative A of ADR-012 — the original V3 plan); simpler key model (one RSA-2048 key).
- **Cons:** **Deprecated by Espressif** — `esp-idf` v5.x emits warnings when SBv1 is enabled, and SBv1 will be removed in a future `esp-idf` release; weaker crypto (SHA-256 only, no rollback protection at the bootloader level); bootloader itself is not signed in SBv1 (only the app image) — an attacker who replaces the bootloader can skip signature checks; requires staying on the WROOM-32 chip (ADR-012 Alternative A, rejected). **Rejected — deprecated and weaker.**

### Alternative D: Secure Boot v2 + Flash Encryption, but no anti-rollback eFuses
- **Pros:** Simpler release process — no `security_version` bumping discipline required; no risk of accidentally bricking a fleet by setting the eFuse too high.
- **Cons:** **Downgrade attacks succeed** — an attacker who obtains a copy of an older, vulnerable firmware image (e.g., version 1.0.0 with a known buffer overflow) can push it via OTA to a device running version 1.5.0, exploiting the older vulnerability; CVE history shows that older firmware versions are commonly available on vendor websites or extracted from devices. **Rejected — anti-rollback is cheap insurance against a known attack class.**

### Alternative E: Secure Boot v2 + Flash Encryption + anti-rollback, but JTAG/UART left enabled
- **Pros:** Engineering team can attach a debugger to production units in the field for troubleshooting; no risk of bricking a unit by burning the wrong eFuse.
- **Cons:** **JTAG is a key-extraction vector** — an attacker with JTAG access can read the flash encryption key and cert private key from the chip's internal memory at runtime, defeating Flash Encryption; UART download mode allows re-flashing unsigned firmware, defeating Secure Boot; the entire security stack collapses if JTAG/UART remain accessible. **Rejected — JTAG/UART must be disabled in production.**

## Consequences

### Positive
- **Bootloader-enforced firmware integrity** — only firmware signed by our offline private key boots; a remote attacker who compromises the OTA pipeline cannot push unsigned firmware
- **At-rest protection for device certs and keys** — Flash Encryption means an attacker who desolders the flash chip sees ciphertext, not the X.509 private key (ADR-004); the entire cert-based auth model remains intact even under physical theft
- **Downgrade attack resistance** — the anti-rollback eFuse counter rejects older vulnerable firmware versions; the fleet stays on the security patch level we push
- **Debug interface locked down** — JTAG and UART download are disabled in production; an attacker with physical access cannot attach a debugger or re-flash unsigned firmware
- **Defense in depth** — even if Flash Encryption is somehow bypassed (e.g., a future side-channel attack on AES-XTS), NVS Encryption adds a second layer protecting the cert + key
- **Industry-standard posture** — Secure Boot v2 + Flash Encryption is the Espressif-recommended production configuration; aligns with what Tuya, Shelly, and other serious IoT vendors ship
- **PDPP + audit defensible** — the firmware security stack is a control we can point to in a security audit or DPIA

### Negative
- **Irreversible eFuse burns** — once `DIS_PAD_JTAG` and the Secure Boot key hash are burned into eFuse, they cannot be unburned. A misconfiguration (wrong key, wrong eFuse) permanently bricks the device. Mitigation: factory flashing procedure (ADR-014) burns eFuses as the *last* step after all QC has passed; pre-production validation runs on dev units that never burn eFuses
- **Firmware signing key custody burden** — the Lead Engineer must sign every production release on an air-gapped machine; CI/CD cannot release production firmware; releases are slower (manual sign step). Mitigation: documented release procedure in V3-CONFIGURATION.md §3
- **Anti-rollback discipline required** — every firmware release with a security fix must bump `security_version`; forgetting to bump leaves the fleet vulnerable to downgrade. Mitigation: CI check that asserts `security_version` is monotonically increasing across releases
- **No field debugging via JTAG** — if a production unit misbehaves, the engineering team cannot attach a debugger; they must rely on log output (UART console remains log-only) and remote diagnostics. Mitigation: extensive logging in production builds, remote telemetry via `esp.service.diag`, RMA path for hard failures (V3-SUPPORT-RMA.md)
- **Flash Encryption imposes ~5% read/write overhead** on NVS access — negligible for our usage pattern (param writes every 5s), measurable but immaterial
- **OTA failures are more consequential** — a failed OTA that leaves the device in an inconsistent state cannot be field-recovered by USB reflash (JTAG/UART disabled); the device must be RMA'd. Mitigation: A/B partition OTA with rollback-on-boot-failure (V3-FIRMWARE.md §6)

### Neutral
- The development vs production build distinction adds a small CI matrix (dev builds unsigned, prod builds signed) — already common in ESP-IDF projects
- The firmware signing key is a high-value target — its compromise would allow an attacker to sign malicious firmware for the whole fleet. Mitigation: air-gapped signing, hardware HSM if budget permits, key rotation procedure documented (though key rotation in Secure Boot v2 requires shipping new bootloaders to all devices, which is painful — we accept this risk for V3)
- `SECURE_VERSION` lives in eFuse as a 32-bit field with **popcount semantics** (each set bit = one version increment; max 32 versions, not 4 billion). Once a bit is burned it cannot be cleared. Strategy: burn 1 bit per **major security release** (CVE patches, auth-bypass fixes — not every minor release). At 2 major security releases/year, this gives a **16-year budget**, sufficient for the 10-year device lifetime. Minor releases use **signed version comparison** in firmware (not eFuse). The bootloader compares the firmware's signed version against `SECURE_VERSION` — if firmware version < popcount(SECURE_VERSION), boot is rejected. (Per CANONICAL-DECISIONS.md P0-4.)

## References
- V3-SECURITY-MODEL.md §5 (firmware security spec — Secure Boot v2, Flash Encryption, anti-rollback, JTAG/UART disable)
- V3-CONFIGURATION.md §3 (firmware signing key custody, release procedure)
- V3-FACTORY-OPS.md §5 (eFuse burning as the last factory step)
- V3-FIRMWARE.md §6 (A/B OTA partition with rollback-on-boot-failure)
- V3-SUPPORT-RMA.md (RMA path for units that cannot be field-recovered)
- ADR-004 (cert-based MQTT auth — Flash Encryption protects the cert + key in NVS)
- ADR-012 (ESP32-C3/S3 chip selection — both support Secure Boot v2)
- ADR-014 (factory flashing — burns the eFuses as the last step)
- Espressif Secure Boot v2: https://docs.espressif.com/projects/esp-idf/en/v5.1/esp32s3/security/secure-boot-v2.html
- Espressif Flash Encryption: https://docs.espressif.com/projects/esp-idf/en/v5.1/esp32s3/security/flash-encryption.html
