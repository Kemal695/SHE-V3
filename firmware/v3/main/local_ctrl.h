/* =============================================================================
 * SHE V3 firmware — local_ctrl.h
 * =============================================================================
 * Local control: mDNS + HTTPS server + PoP-protected endpoints.
 * V3-FIRMWARE §7. P1-1 (PoP = 9-digit CSPRNG). V3-DEVICE-MODEL §7.
 * Works on same Wi-Fi even when internet is down.
 * ==========================================================================*/

#ifndef SHE_LOCAL_CTRL_H
#define SHE_LOCAL_CTRL_H

#include "esp_err.h"
#include "device_profiles.h"

#ifdef __cplusplus
extern "C" {
#endif

/* mDNS service name — V3-FIRMWARE §7.1 */
#define SHE_MDNS_SERVICE_TYPE    "_she_ctrl"
#define SHE_MDNS_PROTO           "_tcp"
#define SHE_MDNS_PORT            443

/**
 * Start local control: mDNS advertisement + HTTPS server on port 443.
 *
 * V3-FIRMWARE §7 — flow:
 *   1. mDNS advertisement: _she_ctrl._tcp.local. → ESP32 IP
 *   2. Flutter app on same Wi-Fi: mDNS scan → discovers ESP32 IP
 *   3. HTTPS GET /she/info → {node_id, sku, devices[], params[]}
 *   4. HTTPS POST /she/ctrl → {"device_name":"Relay 1","params":{"Power":true}}
 *   5. ESP32 toggles relay directly (no cloud round-trip)
 *
 * Security:
 *   - Self-signed cert per device (generated on first boot)
 *   - PoP (9-digit from fctry NVS) verified on every request (constant-time compare)
 *   - ChaCha20-Poly1305 encryption after handshake (key from PoP via HKDF)
 */
esp_err_t local_ctrl_start(she_node_t *node);

#ifdef __cplusplus
}
#endif

#endif /* SHE_LOCAL_CTRL_H */
