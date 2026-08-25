/* =============================================================================
 * SHE V3 firmware — ota_handler.h
 * =============================================================================
 * Self-hosted OTA: MinIO download + Ed25519 verify + A/B partition + auto-rollback.
 * V3-FIRMWARE §6. V3-SECURITY-MODEL §5.5. ADR-013. P0-4 (anti-rollback).
 * ==========================================================================*/

#ifndef SHE_OTA_HANDLER_H
#define SHE_OTA_HANDLER_H

#include "esp_err.h"
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Start OTA download + flash from a URL.
 *
 * V3-FIRMWARE §6.2 — sequence:
 *   1. esp_https_ota_begin() — opens HTTPS connection to MinIO
 *   2. Loop: esp_https_ota_perform() — writes stream to alternate partition
 *      Publish progress every 10% to MQTT ota/progress
 *   3. esp_https_ota_finish() — verifies SHA-256 checksum
 *   4. Verify Ed25519 signature (S3: eFuse BLOCK_KEY2; C3: compiled-in pubkey)
 *   5. esp_ota_set_boot_partition() — mark alternate as PENDING_VERIFY
 *   6. Update Status=REBOOTING
 *   7. esp_restart()
 *
 * V3-FIRMWARE §6.3 — post-reboot:
 *   - 5-min health check (Wi-Fi + MQTT must connect)
 *   - If fail: esp_ota_mark_app_invalid_rollback_and_reboot()
 *   - If success: esp_ota_mark_app_valid_cancel_rollback() + Status=COMPLETED
 */
esp_err_t ota_handler_start(const char *ota_url_json, size_t json_len);

/**
 * Check if we're in PENDING_VERIFY state (just rebooted after OTA).
 * Called from app_main — if true, start 5-min health check.
 */
bool ota_handler_is_pending_verify(void);

/**
 * Mark the current OTA as healthy (cancel rollback).
 * Called after Wi-Fi + MQTT connect successfully within 5 min.
 */
esp_err_t ota_handler_mark_valid(void);

/**
 * Mark the current OTA as failed + trigger rollback.
 * Called if health check fails.
 */
esp_err_t ota_handler_rollback(void);

#ifdef __cplusplus
}
#endif

#endif /* SHE_OTA_HANDLER_H */
