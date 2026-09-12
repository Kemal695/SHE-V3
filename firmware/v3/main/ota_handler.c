/* =============================================================================
 * SHE V3 firmware — ota_handler.c
 * =============================================================================
 * V3-FIRMWARE §6. V3-SECURITY-MODEL §5.5. P0-4 (anti-rollback popcount semantics).
 * ==========================================================================*/

#include "ota_handler.h"
#include "she_mqtt.h"
#include "esp_log.h"
#include "esp_https_ota.h"
#include "esp_ota_ops.h"
#include "esp_partition.h"
#include "mbedtls/sha256.h"
#include <string.h>

static const char *TAG = "she_ota";

/* Ed25519 public key for OTA signature verification.
 * V3-SECURITY-MODEL §5.5 + P1-27:
 *   - ESP32-S3 (R8/R16): burned into eFuse BLOCK_KEY2 (KEY_PURPOSE=USER) at factory
 *   - ESP32-C3 (R4): compiled into firmware (protected by Secure Boot v2)
 *
 * For S3 builds, this is a fallback; primary verification reads from eFuse.
 * For C3 builds, this IS the verification key.
 */
#if defined(CONFIG_SHE_R4) || defined(CONFIG_SHE_DEVKIT_ESP32)
/* Compiled-in Ed25519 public key for R4 (32 bytes) */
static const uint8_t ota_ed25519_pubkey[32] = {
    /* TODO: Replace with actual Ed25519 public key (generated offline) */
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};
#endif

/* ---- Parse OTA URL JSON payload (V3-MQTT-STANDARDS §3.8) ---- */
typedef struct {
    char version[32];
    char url[512];
    char sig[128];            /* base64 Ed25519 signature */
    size_t size;
    char min_hw_rev[16];
    uint32_t secure_version;  /* anti-rollback (P0-4) */
} ota_payload_t;

static esp_err_t parse_ota_payload(const char *json, size_t len, ota_payload_t *out) {
    cJSON *root = cJSON_ParseWithLength(json, len);
    if (!root) return ESP_FAIL;

    cJSON *v = cJSON_GetObjectItem(root, "version");
    cJSON *u = cJSON_GetObjectItem(root, "url");
    cJSON *s = cJSON_GetObjectItem(root, "sig");
    cJSON *sz = cJSON_GetObjectItem(root, "size");
    cJSON *sv = cJSON_GetObjectItem(root, "secure_version");

    if (v) strncpy(out->version, v->valuestring, sizeof(out->version) - 1);
    if (u) strncpy(out->url, u->valuestring, sizeof(out->url) - 1);
    if (s) strncpy(out->sig, s->valuestring, sizeof(out->sig) - 1);
    if (sz) out->size = sz->valueint;
    if (sv) out->secure_version = sv->valueint;

    cJSON_Delete(root);
    return ESP_OK;
}

/* ---- Anti-rollback check (P0-4 — popcount semantics) ---- */
static esp_err_t check_anti_rollback(uint32_t fw_secure_version) {
    /* Read eFuse SECURE_VERSION (32-bit, popcount semantics) */
    /* V3-SECURITY-MODEL §5.3 + P0-4:
     *   - SECURE_VERSION is 32-bit, each set bit = one version increment
     *   - Max 32 versions (NOT 4 billion)
     *   - Bootloader rejects firmware with version < popcount(SECURE_VERSION)
     */
    uint32_t efuse_secure_version = 0;
    /* TODO: read from eFuse via esp_efuse_read_field_blob(SECURE_VERSION, ...) */
    /* For Phase 1: stub — accept any version >= 1 */
    if (fw_secure_version < 1) {
        ESP_LOGE(TAG, "Anti-rollback: firmware secure_version %lu < eFuse %lu (REJECTED)",
                 (unsigned long)fw_secure_version, (unsigned long)efuse_secure_version);
        return ESP_FAIL;
    }
    ESP_LOGI(TAG, "Anti-rollback: firmware secure_version %lu OK", (unsigned long)fw_secure_version);
    return ESP_OK;
}

/* ---- Verify Ed25519 signature ---- */
static esp_err_t verify_ed25519_signature(const uint8_t *image, size_t image_len,
                                          const char *sig_base64, uint32_t secure_version) {
    /* V3-SECURITY-MODEL §5.5:
     *   1. SHA-256(image)
     *   2. Ed25519-verify(signature, hash, public_key)
     */
    uint8_t hash[32];
    mbedtls_sha256(image, image_len, hash, 0);

    /* Decode base64 signature */
    /* (simplified — production uses mbedtls_base64_decode) */
    uint8_t sig[64];
    /* TODO: base64 decode sig_base64 into sig[] */

    /* Get public key (eFuse on S3, compiled-in on C3) */
#if defined(CONFIG_SHE_R4) || defined(CONFIG_SHE_DEVKIT_ESP32)
    const uint8_t *pubkey = ota_ed25519_pubkey;
#else
    /* S3: read from eFuse BLOCK_KEY2 */
    /* TODO: esp_efuse_read_field_blob(BLOCK_KEY2, pubkey, 256) */
    static uint8_t pubkey[32] = {0};
    ESP_LOGW(TAG, "S3 eFuse BLOCK_KEY2 read not implemented — using stub key");
#endif

    /* Verify */
    /* TODO: mbedtls_ed25519_verify or use libsodium crypto_sign_verify_detached */
    ESP_LOGI(TAG, "Ed25519 signature verified (stub) — image %d bytes, hash[0]=%02x",
             image_len, hash[0]);
    return ESP_OK;
}

/* ---- Start OTA ---- */
esp_err_t ota_handler_start(const char *ota_url_json, size_t json_len) {
    ESP_LOGI(TAG, "OTA start: payload %d bytes", json_len);

    ota_payload_t payload = {0};
    if (parse_ota_payload(ota_url_json, json_len, &payload) != ESP_OK) {
        ESP_LOGE(TAG, "Failed to parse OTA payload");
        mqtt_publish_ota_status("failed", payload.version, "OTA_INVALID_SIGNATURE");
        return ESP_FAIL;
    }

    ESP_LOGI(TAG, "OTA: version=%s size=%d secure_version=%lu",
             payload.version, payload.size, (unsigned long)payload.secure_version);

    /* Anti-rollback check (P0-4) */
    if (check_anti_rollback(payload.secure_version) != ESP_OK) {
        mqtt_publish_ota_status("failed", payload.version, "OTA_VERSION_DOWNGRADE_BLOCKED");
        return ESP_FAIL;
    }

    /* Publish status: downloading */
    mqtt_publish_ota_status("downloading", payload.version, NULL);

    /* Download + flash via esp_https_ota */
    esp_http_client_config_t http_cfg = {
        .url = payload.url,
        .timeout_ms = 30000,
        .keep_alive_enable = true,
    };

    esp_https_ota_config_t ota_cfg = {
        .http_config = &http_cfg,
    };

    esp_https_ota_handle_t ota_handle = NULL;
    esp_err_t err = esp_https_ota_begin(&ota_cfg, &ota_handle);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "OTA begin failed: %s", esp_err_to_name(err));
        mqtt_publish_ota_status("failed", payload.version, "OTA_DOWNLOAD_FAILED");
        return err;
    }

    /* Download loop — publish progress every 10% */
    int last_percent = 0;
    size_t total_read = 0;
    while (true) {
        err = esp_https_ota_perform(ota_handle);
        if (err != ESP_ERR_HTTPS_OTA_IN_PROGRESS) break;

        int percent = esp_https_ota_get_image_len_read(ota_handle) * 100 /
                      (payload.size > 0 ? payload.size : 1);
        if (percent >= last_percent + 10) {
            last_percent = percent;
            size_t done = esp_https_ota_get_image_len_read(ota_handle);
            mqtt_publish_ota_progress(percent, done, payload.size);
            ESP_LOGI(TAG, "OTA progress: %d%% (%d/%d bytes)", percent, done, payload.size);
        }
    }

    if (err != ESP_OK) {
        ESP_LOGE(TAG, "OTA perform failed: %s", esp_err_to_name(err));
        mqtt_publish_ota_status("failed", payload.version, "OTA_DOWNLOAD_FAILED");
        esp_https_ota_abort(ota_handle);
        return err;
    }

    /* Verify checksum */
    if (esp_https_ota_finish(ota_handle) != ESP_OK) {
        ESP_LOGE(TAG, "OTA finish (checksum verify) failed");
        mqtt_publish_ota_status("failed", payload.version, "OTA_INVALID_SIGNATURE");
        return ESP_FAIL;
    }

    /* Verify Ed25519 signature (V3-SECURITY-MODEL §5.5) */
    /* Phase 1: stub verification — full implementation reads image from alternate
     * partition via esp_partition_read + verifies Ed25519 signature.
     * For now, skip verification (TODO: implement using PSA Crypto in Phase 2B). */
    ESP_LOGW(TAG, "Ed25519 signature verification SKIPPED (Phase 1 stub) — TODO: implement in Phase 2B");

    /* Mark alternate partition as PENDING_VERIFY (V3-FIRMWARE §6.3) */
    const esp_partition_t *next = esp_ota_get_next_update_partition(NULL);
    esp_ota_set_boot_partition(next);

    /* Publish status: rebooting */
    mqtt_publish_ota_status("rebooting", payload.version, NULL);
    ESP_LOGI(TAG, "OTA complete — rebooting in 2s");

    vTaskDelay(pdMS_TO_TICKS(2000));
    esp_restart();

    return ESP_OK;
}

/* ---- Check if we're in PENDING_VERIFY state ---- */
bool ota_handler_is_pending_verify(void) {
    const esp_partition_t *running = esp_ota_get_running_partition();
    esp_ota_img_states_t state;
    if (esp_ota_get_state_partition(running, &state) == ESP_OK) {
        return state == ESP_OTA_IMG_PENDING_VERIFY;
    }
    return false;
}

/* ---- Mark current OTA as valid (cancel rollback) ---- */
esp_err_t ota_handler_mark_valid(void) {
    ESP_LOGI(TAG, "OTA health check passed — marking partition valid");
    return esp_ota_mark_app_valid_cancel_rollback();
}

/* ---- Rollback to previous partition ---- */
esp_err_t ota_handler_rollback(void) {
    ESP_LOGE(TAG, "OTA health check FAILED — rolling back to previous partition");
    return esp_ota_mark_app_invalid_rollback_and_reboot();
}
