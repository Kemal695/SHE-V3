/* =============================================================================
 * SHE V3 firmware — ble_provisioning.h
 * =============================================================================
 * BLE provisioning manager. V3-FIRMWARE §5. V3-DEVICE-MODEL §5.
 * P1-1: PoP = 9-digit numeric CSPRNG from fctry NVS.
 * P1-2: BLE Service UUID = 0000ffff-0000-1000-8000-00805f9b34fb.
 * P0-1: BLE does NOT issue certs — cert is factory-issued, in fctry NVS.
 * P1-3: claim endpoint = POST /api/v3/nodes/claim (NOT /devices/claim).
 * ==========================================================================*/

#ifndef SHE_BLE_PROVISIONING_H
#define SHE_BLE_PROVISIONING_H

#include "esp_err.h"
#include "device_profiles.h"

#ifdef __cplusplus
extern "C" {
#endif

/* BLE Service UUID — P1-2 */
#define SHE_BLE_SERVICE_UUID        "0000ffff-0000-1000-8000-00805f9b34fb"

/* Custom GATT characteristic for Wi-Fi creds + claim_token transfer */
#define SHE_BLE_CHAR_WIFI_UUID      "0000ff01-0000-1000-8000-00805f9b34fb"
#define SHE_BLE_CHAR_STATUS_UUID    "0000ff02-0000-1000-8000-00805f9b34fb"

/* Provisioning payload (legacy device-claims struct, kept for API compat).
 * App-claims flow does NOT use this — the app sends only Wi-Fi creds via the
 * standard Espressif prov-config endpoint, then calls POST /nodes/claim itself.
 */
typedef struct {
    char wifi_ssid[33];
    char wifi_password[65];
    char tenant_id[40];         /* UUID — unused in app-claims */
    char claim_token[256];      /* unused in app-claims */
    char api_base_url[128];     /* unused in app-claims */
} she_provision_payload_t;

/**
 * Start BLE provisioning — blocks until provisioning completes or times out.
 * Reads PoP from fctry NVS, advertises BLE service, accepts Wi-Fi creds via
 * the standard Espressif prov-config GATT endpoint. On IP_EVENT_STA_GOT_IP
 * the provisioned flag is persisted and the device reboots.
 *
 * V3-FIRMWARE §5.1 (app-claims) — full flow:
 *   1. ESP32 boots unprovisioned → starts BLE provisioning service
 *   2. Flutter app scans → finds "SHE-R8-AABBCC" (advertised name = node_id)
 *   3. App connects (BLE Security 1, PoP required)
 *   4. App sends {wifi_ssid, wifi_password} via standard prov-config
 *   5. ESP32 connects to Wi-Fi, marks provisioned, reboots
 *   6. App calls POST /api/v3/nodes/claim {mac, sku, home_id} (P1-3)
 *   7. Device connects to MQTT with factory cert (P0-1), publishes config
 */
esp_err_t ble_provisioning_start(she_node_t *node);

/**
 * Check if device is already provisioned (has Wi-Fi creds + tenant_id in NVS).
 */
bool ble_provisioning_is_provisioned(void);

/**
 * Erase the stored Wi-Fi credentials and reboot into provisioning mode.
 *
 * There is no serial port on the deployment box, so without this the only way
 * back to provisioning is erasing NVS with a cable. Exposed to the LAN through
 * POST /she/reprovision (PoP-protected) in local_ctrl.c.
 *
 * Does not return: the device restarts so app_main takes the "not provisioned"
 * branch and starts BLE advertising again.
 */
esp_err_t ble_provisioning_reset(void);

#ifdef __cplusplus
}
#endif

#endif /* SHE_BLE_PROVISIONING_H */
