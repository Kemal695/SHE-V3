/* =============================================================================
 * SHE V3 firmware — energy_monitor.h
 * =============================================================================
 * PZEM-004T v3 energy monitor driver. V3-FIRMWARE §9. V3-ENERGY-MONITORING §3.
 * SHE-R8/R16 only (R4 has no PZEM).
 * Modbus RTU over UART1 (GPIO 17/18 on S3). Poll every 5s.
 *
 * V3-MQTT-STANDARDS §3.7 — short-form keys (v, i, p, wh, pf, freq).
 * ==========================================================================*/

#ifndef SHE_ENERGY_MONITOR_H
#define SHE_ENERGY_MONITOR_H

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    float voltage;       /* V */
    float current;       /* A */
    float power_w;       /* W (instantaneous) */
    float energy_wh;     /* Wh (cumulative from PZEM) */
    float power_factor;  /* 0.0-1.0 */
    float frequency;     /* Hz */
} pzem_reading_t;

/**
 * Initialize PZEM-004T v3 on UART1.
 * V3-FIRMWARE §9 — Modbus RTU, 9600 baud, 8N1.
 */
esp_err_t energy_monitor_init(void);

/**
 * Read a single PZEM-004T v3 measurement.
 */
esp_err_t energy_monitor_read(pzem_reading_t *reading);

/**
 * Start the energy_monitor FreeRTOS task (priority 2, 3072 stack, core 0).
 * Polls PZEM every 5s, publishes to MQTT energy topic (QoS 0).
 */
esp_err_t energy_monitor_start(void);

#ifdef __cplusplus
}
#endif

#endif /* SHE_ENERGY_MONITOR_H */
