/* =============================================================================
 * SHE V3 firmware — app_wifi.h
 * =============================================================================
 * Wi-Fi connect + reconnect with exponential backoff.
 * V3-FIRMWARE §2.2.
 * ==========================================================================*/

#ifndef SHE_APP_WIFI_H
#define SHE_APP_WIFI_H

#include "esp_err.h"

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

#ifdef __cplusplus
}
#endif

#endif /* SHE_APP_WIFI_H */
