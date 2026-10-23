/* =============================================================================
 * SHE V3 firmware — app_wifi.h
 * =============================================================================
 * Wi-Fi connect + reconnect with exponential backoff.
 * V3-FIRMWARE §2.2.
 * ==========================================================================*/

#ifndef SHE_APP_WIFI_H
#define SHE_APP_WIFI_H

#include "esp_err.h"
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Initialize Wi-Fi subsystem (does NOT connect — use app_wifi_connect()).
 */
esp_err_t app_wifi_init(void);

/**
 * Connect to Wi-Fi using NVS-stored creds.
 * Blocks until connected or 30s timeout.
 */
esp_err_t app_wifi_connect(void);

/**
 * Check if Wi-Fi is currently connected.
 */
bool app_wifi_is_connected(void);

/**
 * Cumulative STA disconnects since boot (never reset). Reported as
 * `wifi_disconnects` on the telemetry topic.
 */
uint32_t app_wifi_disconnect_count(void);

/**
 * Tell this module that wifi_prov_mgr currently owns the STA connection.
 *
 * While true the reconnect logic is suppressed. Two reasons, both real:
 *  - the provisioning manager runs its own association retry loop and counts the
 *    failures itself (it is what emits WIFI_PROV_CRED_FAIL). A second caller of
 *    esp_wifi_connect() races that accounting, so the manager can be kept
 *    "connecting" indefinitely instead of ever concluding the join failed;
 *  - the backoff below is a vTaskDelay *inside the event handler*, which blocks
 *    the shared event loop — the same loop that delivers WIFI_PROV_EVENT and
 *    IP_EVENT. During provisioning that delays the very events the session needs.
 *
 * Set true by ble_provisioning_start() before wifi_prov_mgr_start_provisioning().
 * A successful provisioning reboots the device, so it never needs clearing.
 */
void app_wifi_set_provisioning_active(bool active);

#ifdef __cplusplus
}
#endif

#endif /* SHE_APP_WIFI_H */
