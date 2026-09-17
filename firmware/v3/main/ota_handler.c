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
#include "esp_app_desc.h"
#include "esp_efuse.h"
#include "esp_efuse_table.h"
#include "mbedtls/sha256.h"
#include "mbedtls/base64.h"
#include "tweetnacl.h"          /* vendored Ed25519 — see third_party/README.md */
#include <stdlib.h>             /* malloc/free for the streaming hash buffer */
#include <string.h>

static const char *TAG = "she_ota";

/* Embedded CA bundle (root + intermediate) from certs/ca.pem — already linked for MQTT,
 * reused here so the OTA download authenticates the server as well as the image. */
extern const char ca_pem_start[] asm("_binary_ca_pem_start");

/* Ed25519 public key for OTA signature verification.
 * V3-SECURITY-MODEL §5.5 + P1-27:
 *   - ESP32-S3 (R8/R16): burned into eFuse BLOCK_KEY2 (KEY_PURPOSE=USER) at factory
 *   - ESP32-C3 (R4): compiled into firmware (protected by Secure Boot v2)
 *
 * ⚠️ CURRENTLY COMPILED-IN FOR EVERY TARGET. The eFuse path is deliberately not
 * implemented yet, for two reasons:
 *   1. This bring-up board is a classic ESP32-D0WD, not S3 or C3, so neither rule
 *      in P1-27 applies to it directly.
 *   2. Burning an eFuse key is IRREVERSIBLE. It belongs in the factory flow
 *      (V3-FACTORY-OPS) on production silicon, not on a dev board.
 * Switching to eFuse later is a contained change to this file plus the factory
 * provisioning step — it does not affect the signing tool or the backend.
 *
 * The matching private key is NOT in this repo (gitignored, see ota-keys/).
 * Rotating the key means regenerating it, re-embedding this array, and reflashing —
 * plan for key rotation to coincide with a firmware release.
 */
static const uint8_t ota_ed25519_pubkey[32] = {
    0x89, 0x1b, 0x43, 0x85, 0xc3, 0xc2, 0x35, 0xe3,
    0x9f, 0x94, 0x3f, 0x13, 0x76, 0x0d, 0x0c, 0x3b,
    0xd6, 0x11, 0x77, 0x96, 0xf2, 0x77, 0x8e, 0x64,
    0x25, 0x0c, 0x33, 0x7b, 0xb4, 0xf6, 0x84, 0x50,
};

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
static uint32_t popcount32(uint32_t v) {
    uint32_t c = 0;
    while (v) {
        c += v & 1u;
        v >>= 1;
    }
    return c;
}

static esp_err_t check_anti_rollback(uint32_t fw_secure_version) {
    /* V3-SECURITY-MODEL §5.3 + P0-4:
     *   - eFuse SECURE_VERSION is 32-bit with POPCOUNT semantics: each set bit is one
     *     version increment, so at most 32 versions — NOT 4 billion.
     *   - The effective counter is popcount(raw), not raw. Comparing the raw value
     *     would let a firmware declaring 0xFFFFFFFF sail past any eFuse state.
     */
    uint32_t efuse_raw = 0;
    esp_err_t err = esp_efuse_read_field_blob(ESP_EFUSE_SECURE_VERSION, &efuse_raw, 32);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "Cannot read eFuse SECURE_VERSION (%s) — assuming 0",
                 esp_err_to_name(err));
        efuse_raw = 0;
    }
    const uint32_t efuse_ver = popcount32(efuse_raw);

    if (fw_secure_version < efuse_ver) {
        ESP_LOGE(TAG, "Anti-rollback: firmware secure_version %lu < eFuse %lu — REJECTED",
                 (unsigned long)fw_secure_version, (unsigned long)efuse_ver);
        return ESP_FAIL;
    }

    /* Be honest about the guarantee: the bootloader is the real enforcement point,
     * and CONFIG_BOOTLOADER_APP_ANTI_ROLLBACK is NOT enabled in this build (enabling
     * it requires burning eFuse bits — a factory decision). So this stops the app
     * from *installing* a downgrade over the air, but a manually flashed image is
     * still only bounded by the eFuse value itself. */
    ESP_LOGI(TAG, "Anti-rollback: firmware secure_version %lu >= eFuse %lu OK "
                  "(advisory only — bootloader enforcement disabled)",
             (unsigned long)fw_secure_version, (unsigned long)efuse_ver);
    return ESP_OK;
}

/* ---- Verify Ed25519 signature over the image in the update partition ----
 *
 * V3-SECURITY-MODEL §5.5: SHA-256(image) → Ed25519-verify(signature, hash, pubkey).
 *
 * The image is read back from the OTA partition rather than hashed in flight, so the
 * bytes that are verified are exactly the bytes that will boot. Hashing a stream on the
 * way in would verify something subtly different from what lands in flash.
 *
 * Reads in chunks: the image is ~1.5 MB and will not fit in RAM.
 */
#define OTA_HASH_CHUNK 4096

static esp_err_t verify_ed25519_signature(const esp_partition_t *part, size_t image_len,
                                          const char *sig_base64) {
    if (!part || image_len == 0) {
        ESP_LOGE(TAG, "Signature verify: bad arguments (part=%p len=%u)",
                 (const void *)part, (unsigned)image_len);
        return ESP_ERR_INVALID_ARG;
    }

    /* 1. SHA-256 the image, streaming. */
    uint8_t hash[32];
    mbedtls_sha256_context sha;
    mbedtls_sha256_init(&sha);
    mbedtls_sha256_starts(&sha, 0);          /* 0 = SHA-256 (not SHA-224) */

    uint8_t *chunk = malloc(OTA_HASH_CHUNK);
    if (!chunk) {
        mbedtls_sha256_free(&sha);
        return ESP_ERR_NO_MEM;
    }

    esp_err_t err = ESP_OK;
    size_t offset = 0;
    while (offset < image_len) {
        size_t n = image_len - offset;
        if (n > OTA_HASH_CHUNK) n = OTA_HASH_CHUNK;
        err = esp_partition_read(part, offset, chunk, n);
        if (err != ESP_OK) break;
        mbedtls_sha256_update(&sha, chunk, n);
        offset += n;
    }
    free(chunk);
    if (err != ESP_OK) {
        mbedtls_sha256_free(&sha);
        ESP_LOGE(TAG, "Signature verify: partition read failed at %u: %s",
                 (unsigned)offset, esp_err_to_name(err));
        return err;
    }
    mbedtls_sha256_finish(&sha, hash);
    mbedtls_sha256_free(&sha);

    /* 2. base64-decode the detached 64-byte signature. */
    uint8_t sig[64];
    size_t sig_len = 0;
    int rc = mbedtls_base64_decode(sig, sizeof(sig), &sig_len,
                                   (const unsigned char *)sig_base64,
                                   strlen(sig_base64));
    if (rc != 0 || sig_len != sizeof(sig)) {
        ESP_LOGE(TAG, "Signature is not base64 for 64 bytes (rc=%d, got %u)",
                 rc, (unsigned)sig_len);
        return ESP_ERR_INVALID_ARG;
    }

    /* 3. Ed25519-verify. TweetNaCl wants signature||message and returns 0 on success;
     *    the signed message is the 32-byte digest, matching the spec's
     *    Ed25519-verify(signature, hash, public_key). */
    uint8_t sm[64 + 32];
    memcpy(sm, sig, 64);
    memcpy(sm + 64, hash, 32);

    uint8_t out[64 + 32];
    unsigned long long out_len = 0;
    if (crypto_sign_open(out, &out_len, sm, sizeof(sm), ota_ed25519_pubkey) != 0) {
        ESP_LOGE(TAG, "Ed25519 verification FAILED — image not signed by the OTA key "
                      "(sha256=%02x%02x%02x%02x...)",
                 hash[0], hash[1], hash[2], hash[3]);
        return ESP_ERR_INVALID_CRC;
    }

    ESP_LOGI(TAG, "Ed25519 signature verified over %u bytes (sha256=%02x%02x%02x%02x...)",
             (unsigned)image_len, hash[0], hash[1], hash[2], hash[3]);
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
        /* Authenticate the server too. The Ed25519 check protects image integrity, but
         * without this the download itself is unauthenticated — and an attacker who
         * controls the URL could still deny or replay updates. The CA bundle is already
         * embedded for MQTT, so this costs nothing. */
        .cert_pem = ca_pem_start,
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

    /* Progress needs a real denominator.
     *
     * The backend sends "size": 0 (OtaService.publishOtaUrlToNode has no MinIO client to
     * HEAD the object), and the old fallback divided by 1 — which logged
     * "OTA progress: 22835200% (228352/0 bytes)". True, and useless. Take the size the
     * OTA layer read from the HTTP response instead; it is authoritative. */
    size_t total_size = esp_https_ota_get_image_size(ota_handle);
    if (total_size == 0) {
        total_size = payload.size;
    }

    int last_percent = 0;
    size_t last_reported = 0;
    while (true) {
        err = esp_https_ota_perform(ota_handle);
        if (err != ESP_ERR_HTTPS_OTA_IN_PROGRESS) break;

        const size_t done = esp_https_ota_get_image_len_read(ota_handle);

        if (total_size > 0) {
            const int percent = (int)(done * 100 / total_size);
            if (percent >= last_percent + 10) {
                last_percent = percent;
                mqtt_publish_ota_progress(percent, done, total_size);
                ESP_LOGI(TAG, "OTA progress: %d%% (%u/%u bytes)",
                         percent, (unsigned)done, (unsigned)total_size);
            }
        } else if (done >= last_reported + (256 * 1024)) {
            /* Size unknown — report bytes only rather than invent a percentage. */
            last_reported = done;
            mqtt_publish_ota_progress(0, done, 0);
            ESP_LOGI(TAG, "OTA progress: %u bytes (total size unknown)", (unsigned)done);
        }
    }

    if (err != ESP_OK) {
        ESP_LOGE(TAG, "OTA perform failed: %s", esp_err_to_name(err));
        mqtt_publish_ota_status("failed", payload.version, "OTA_DOWNLOAD_FAILED");
        esp_https_ota_abort(ota_handle);
        return err;
    }

    /* ---- Verify the Ed25519 signature BEFORE activating the image ----
     *
     * Order matters: esp_https_ota_finish() is what marks the partition bootable, so
     * verifying afterwards would mean a rejected image had already been selected for
     * boot. Verify first, and abort (which discards the staged image) on failure.
     *
     * V3-SECURITY-MODEL §5.5. This is the check that makes the update path trustworthy;
     * without it the device would flash whatever a URL served it. */
    const esp_partition_t *next = esp_ota_get_next_update_partition(NULL);
    size_t image_len = esp_https_ota_get_image_len_read(ota_handle);
    if (image_len == 0) {
        image_len = payload.size;      /* fall back to the declared size */
    }

    if (verify_ed25519_signature(next, image_len, payload.sig) != ESP_OK) {
        ESP_LOGE(TAG, "OTA rejected — signature verification failed, discarding image");
        mqtt_publish_ota_status("failed", payload.version, "OTA_INVALID_SIGNATURE");
        esp_https_ota_abort(ota_handle);
        return ESP_FAIL;
    }

    /* Signature good — now finalise. finish() validates the image and sets the
     * boot partition (V3-FIRMWARE §6.3). */
    if (esp_https_ota_finish(ota_handle) != ESP_OK) {
        ESP_LOGE(TAG, "OTA finish (image validation) failed");
        mqtt_publish_ota_status("failed", payload.version, "OTA_INVALID_SIGNATURE");
        return ESP_FAIL;
    }
    esp_ota_set_boot_partition(next);

    /* Publish status: rebooting */
    mqtt_publish_ota_status("rebooting", payload.version, NULL);
    ESP_LOGI(TAG, "OTA complete — rebooting in 2s");

    vTaskDelay(pdMS_TO_TICKS(2000));
    esp_restart();

    return ESP_OK;
}

/* ---- Check if this boot still has to prove itself ----
 *
 * Two states mean "freshly updated, not yet trusted":
 *
 *   ESP_OTA_IMG_PENDING_VERIFY - the bootloader promotes NEW to this when it was built with
 *                                CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE.
 *   ESP_OTA_IMG_NEW            - what the app itself writes via esp_ota_set_boot_partition()
 *                                when *it* was built with the flag. A bootloader built without
 *                                the flag never promotes NEW, so it just sits there.
 *
 * Checking only PENDING_VERIFY silently disables the health check on any device whose
 * bootloader predates the flag - and OTA never rewrites the bootloader, so such a device can
 * never start verifying over the air. Accepting NEW as well means one OTA is enough to bring
 * a deployed device onto the health-check path, with no serial reflash.
 *
 * (Why the very first OTA after enabling the flag still cannot verify: the OTA is performed by
 * the *old* app, and esp_ota_ops.c writes ESP_OTA_IMG_UNDEFINED when the flag is off. So the
 * image lands unverified - expected, and it self-corrects on the next OTA.)
 */
bool ota_handler_is_pending_verify(void) {
    const esp_partition_t *running = esp_ota_get_running_partition();
    esp_ota_img_states_t state;
    if (esp_ota_get_state_partition(running, &state) == ESP_OK) {
        return state == ESP_OTA_IMG_PENDING_VERIFY || state == ESP_OTA_IMG_NEW;
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
