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

/* Provisioning payload (JSON, sent via BLE GATT write to SHE_BLE_CHAR_WIFI_UUID) */
typedef struct {
    char wifi_ssid[33];
    char wifi_password[65];
    char tenant_id[40];         /* UUID */
    char claim_token[256];      /* 10-min TTL JWT */
    char api_base_url[128];     /* "https://api.she.et" */
} she_provision_payload_t;

/**
 * Start BLE provisioning — blocks until provisioning completes or times out.
 * Reads PoP from fctry NVS, advertises BLE service, accepts Wi-Fi creds via GATT,
 * then POSTs to /api/v3/nodes/claim to register the device with the cloud.
 *
 * V3-FIRMWARE §5.1 — full flow:
 *   1. ESP32 boots unprovisioned → starts BLE provisioning service
 *   2. Flutter app scans → finds "SHE-R8-AABBCC" (advertised name = node_id)
 *   3. App connects (BLE Security 1, PoP required)
 *   4. App sends {wifi_ssid, wifi_password, tenant_id, claim_token, api_base_url}
 *   5. ESP32 connects to Wi-Fi
 *   6. ESP32 POSTs to {api_base_url}/api/v3/nodes/claim
 *      Body: { mac, claim_token, sku, tenant_id, config }
 *      Returns: { node_db_id, mqtt_broker }
 *   7. ESP32 stores mqtt_broker + tenant mapping in NVS
 *   8. ESP32 disconnects BLE, reboots
 */
esp_err_t ble_provisioning_start(she_node_t *node);

/**
 * Check if device is already provisioned (has Wi-Fi creds + tenant_id in NVS).
 */
bool ble_provisioning_is_provisioned(void);

#ifdef __cplusplus
}
#endif

#endif /* SHE_BLE_PROVISIONING_H */
