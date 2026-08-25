/* =============================================================================
 * SHE V3 firmware — mqtt_client.h
 * =============================================================================
 * mTLS MQTT client. V3-FIRMWARE §12.6. V3-MQTT-STANDARDS §7. P1-10 (no superuser).
 * P1-13: LWT payload = JSON {"status":"offline"}.
 * ==========================================================================*/

#ifndef SHE_MQTT_CLIENT_H
#define SHE_MQTT_CLIENT_H

#include "esp_err.h"
#include "device_profiles.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Initialize + start the MQTT client (mTLS, shared subscription for backend).
 * For devices: connects with factory-issued cert, subscribes to its own
 * she/{tenant}/{home}/{room}/{mac}/params/remote + ota/url topics.
 *
 * V3-MQTT-STANDARDS §10 — device client ID = normalized MAC.
 * V3-SECURITY-MODEL §3.4 — mutual TLS only, NO username/password.
 */
esp_err_t mqtt_client_start(she_node_t *node);

/**
 * Stop the MQTT client (clean shutdown).
 */
esp_err_t mqtt_client_stop(void);

/**
 * Publish a message to a topic.
 * Used internally by other firmware modules (energy_monitor, feedback_monitor, etc.)
 */
esp_err_t mqtt_publish(const char *topic, const char *payload, int qos, bool retained);

/**
 * Build the full topic path: she/{tenant}/{home}/{room}/{mac}/{direction}
 * Returns a malloc'd string — caller must free().
 */
char* mqtt_build_topic(const char *direction);

/**
 * Publish node config to she/.../{mac}/config (retained, QoS 1).
 * Called on MQTT connect.
 */
esp_err_t mqtt_publish_config(she_node_t *node);

/**
 * Publish node status (online/offline) to she/.../{mac}/status (retained, QoS 1).
 * V3-MQTT-STANDARDS §3.6 + P1-13 — payload is JSON {"status":"online"}.
 */
esp_err_t mqtt_publish_status(bool online);

/**
 * Publish params/local to she/.../{mac}/params/local (QoS 0, every 5s).
 * V3-MQTT-STANDARDS §3.3.
 */
esp_err_t mqtt_publish_params_local(she_node_t *node);

/**
 * Publish energy reading to she/.../{mac}/energy (QoS 0, every 5s).
 * V3-MQTT-STANDARDS §3.7 — short-form keys (v, i, p, wh, pf, freq).
 */
esp_err_t mqtt_publish_energy(float voltage, float current, float power_w,
                              float energy_wh, float power_factor, float frequency);

/**
 * Publish OTA status to she/.../{mac}/ota/status (QoS 1).
 * V3-MQTT-STANDARDS §3.9.
 */
esp_err_t mqtt_publish_ota_status(const char *status, const char *version, const char *error);

/**
 * Publish OTA progress to she/.../{mac}/ota/progress (QoS 0).
 * V3-MQTT-STANDARDS §3.10.
 */
esp_err_t mqtt_publish_ota_progress(int percent, size_t bytes_done, size_t bytes_total);

#ifdef __cplusplus
}
#endif

#endif /* SHE_MQTT_CLIENT_H */
