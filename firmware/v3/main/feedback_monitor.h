/* =============================================================================
 * SHE V3 firmware — feedback_monitor.h
 * =============================================================================
 * Optocoupler feedback via CD4051 8:1 mux + ADC. V3-FIRMWARE §8.
 * Reads each relay channel's actual contact state every 100ms.
 *
 * Truth table (V3-FIRMWARE §8):
 *   Commanded ON  + Feedback ON  → Normal — sync to cloud
 *   Commanded ON  + Feedback OFF → Relay fault — publish alert
 *   Commanded OFF + Feedback OFF → Normal — sync to cloud
 *   Commanded OFF + Feedback ON  → Manual override detected (wall switch)
 * ==========================================================================*/

#ifndef SHE_FEEDBACK_MONITOR_H
#define SHE_FEEDBACK_MONITOR_H

#include "esp_err.h"
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Initialize CD4051 mux + ADC for feedback monitoring.
 */
esp_err_t feedback_monitor_init(uint8_t relay_count);

/**
 * Start the feedback_monitor FreeRTOS task (priority 3, 3072 stack, core 0).
 * Polls each relay channel every 100ms, compares to commanded state,
 * publishes alerts on fault/manual-override.
 */
esp_err_t feedback_monitor_start(void);

#ifdef __cplusplus
}
#endif

#endif /* SHE_FEEDBACK_MONITOR_H */
