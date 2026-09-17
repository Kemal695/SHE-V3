/* =============================================================================
 * SHE V3 firmware — system_service.h
 * =============================================================================
 * System commands: reboot, factory_reset, sync_time, ping.
 * V3-FIRMWARE §2.2 + V3-MQTT-STANDARDS §3.2 (command payload).
 * ==========================================================================*/

#ifndef SHE_SYSTEM_SERVICE_H
#define SHE_SYSTEM_SERVICE_H

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    SHE_CMD_REBOOT,
    SHE_CMD_FACTORY_RESET,
    SHE_CMD_SYNC_TIME,
    SHE_CMD_PING,
} she_system_cmd_t;

/**
 * Execute a system command (received via MQTT command topic).
 */
esp_err_t system_service_execute(she_system_cmd_t cmd, const char *reason);

/**
 * Start SNTP so the device has a real clock.
 *
 * Safe to call more than once. Call it any time after the network stack is up — lwIP retries
 * until it gets a response, so there is no need to wait for a Wi-Fi connection first.
 */
void system_service_time_sync_start(void);

#ifdef __cplusplus
}
#endif

#endif /* SHE_SYSTEM_SERVICE_H */
