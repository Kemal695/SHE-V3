/* =============================================================================
 * SHE V3 firmware — main.c
 * =============================================================================
 * Boot orchestration. V3-FIRMWARE §4 (boot flow, verbatim).
 *
 * Sequence:
 *   1. NVS init (default + fctry partitions)
 *   2. Wi-Fi subsystem init (does NOT connect yet)
 *   3. Driver init (PCF8574, CD4051, PZEM)
 *   4. Restore last relay state from NVS (persist property)
 *   5. Node init — device_profiles.c builds the RainMaker hierarchy
 *   6. If not provisioned → start BLE provisioning (blocks)
 *   7. Wi-Fi connect (from NVS creds, 30s timeout)
 *   8. MQTT connect (mTLS, cert from fctry NVS)
 *      - Set LWT: {"status":"offline"} (JSON, P1-13)
 *      - On connect: publish {"status":"online"}
 *      - Publish node config to she/.../config (retained)
 *      - Subscribe to params/remote + ota/url + command
 *   9. Start esp_local_ctrl (mDNS + HTTPS + PoP)
 *  10. Start energy_monitor (R8/R16 only)
 *  11. Start voice_control (R16 only)
 *  12. Start OTA handler — if PENDING_VERIFY, start 5-min health check
 *  13. Main loop: publish heartbeat + telemetry every 60s
 * ==========================================================================*/

#include "nvs_keys.h"
#include "device_profiles.h"
#include "app_wifi.h"
#include "she_mqtt.h"
#include "ble_provisioning.h"
#include "ota_handler.h"
#include "local_ctrl.h"
#include "relay_driver.h"
#include "feedback_monitor.h"
#include "energy_monitor.h"
#include "button_task.h"
#include "system_service.h"

#ifdef CONFIG_SHE_R16
#include "voice_control.h"
#endif

#include "esp_log.h"
#include "esp_system.h"
#include "nvs_flash.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "she_main";

/* ---- Read SKU + MAC from fctry NVS to build the node identity ---- */
static esp_err_t read_node_identity(char *mac, size_t mac_len,
                                      char *sku, size_t sku_len,
                                      char *node_id, size_t node_id_len) {
    nvs_handle_t h;
    esp_err_t err = nvs_open_from_partition("fctry", SHE_FCTRY_NAMESPACE, NVS_READONLY, &h);
    if (err != ESP_OK) return err;

    size_t len = mac_len;
    nvs_get_str(h, SHE_FCTRY_KEY_MAC, mac, &len);
    len = sku_len;
    nvs_get_str(h, SHE_FCTRY_KEY_SKU, sku, &len);
    len = node_id_len;
    nvs_get_str(h, SHE_FCTRY_KEY_NODE_ID, node_id, &len);

    nvs_close(h);
    return ESP_OK;
}

/* ---- 5-minute OTA health check task (F6 fix) ---- */
static void ota_health_check_task(void *arg) {
    ESP_LOGI(TAG, "OTA health check started: waiting 5 minutes for stable Wi-Fi + MQTT...");
    int stable_seconds = 0;
    while (stable_seconds < 300) {
        vTaskDelay(pdMS_TO_TICKS(1000));
        if (app_wifi_is_connected() && mqtt_client_is_connected()) {
            stable_seconds++;
        } else {
            ESP_LOGW(TAG, "OTA health check unstable at %ds: Wi-Fi or MQTT disconnected — rolling back!", stable_seconds);
            ota_handler_rollback();
            vTaskDelay(pdMS_TO_TICKS(2000));
            esp_restart();
        }
    }
    ota_handler_mark_valid();
    ESP_LOGI(TAG, "OTA health check PASSED: stable for 5 minutes — marked valid.");
    vTaskDelete(NULL);
}

/* ---- Update node identity in the profile (replaces placeholders) ---- */
static void update_node_identity(she_node_t *node, const char *mac, const char *sku, const char *node_id) {
    /* The profile builders use static strings with "PLACEHOLDER" — replace them.
     * (In production, use strdup + free; for firmware we use static buffers.) */
    node->node_id = node_id;
    node->mac = mac;
    node->sku = sku;
}

/* ---- app_main — boot orchestration per V3-FIRMWARE §4 ---- */
void app_main(void) {
    ESP_LOGI(TAG, "========================================");
    ESP_LOGI(TAG, "  SHE V3 firmware starting...");
    ESP_LOGI(TAG, "  Firmware version: %s", CONFIG_SHE_FIRMWARE_VERSION);
    ESP_LOGI(TAG, "  Secure version: %d", CONFIG_SHE_SECURE_VERSION);
    ESP_LOGI(TAG, "  Compiled at: %s %s", __DATE__, __TIME__);
    ESP_LOGI(TAG, "========================================");

    /* 1. NVS init (default + fctry partitions) */
    ESP_ERROR_CHECK(nvs_flash_init());
    ESP_ERROR_CHECK(nvs_flash_init_partition("fctry"));
    ESP_LOGI(TAG, "Step 1: NVS initialized (default + fctry)");

    /* 2. Wi-Fi subsystem init (does NOT connect yet) */
    ESP_ERROR_CHECK(app_wifi_init());
    ESP_LOGI(TAG, "Step 2: Wi-Fi subsystem initialized");

    /* 3. Driver init */
    /* Read SKU from fctry NVS to determine relay count */
    char mac[18] = {0}, sku[8] = {0}, node_id[32] = {0};
    read_node_identity(mac, sizeof(mac), sku, sizeof(sku), node_id, sizeof(node_id));

    uint8_t relay_count = 8;   /* default */
#ifdef CONFIG_SHE_DEVKIT_ESP32
    relay_count = 4;           /* DevKit falls back to the SHE-R4 profile */
#endif
    if (strcmp(sku, "SHE-R4") == 0)  relay_count = 4;
    else if (strcmp(sku, "SHE-R8") == 0)  relay_count = 8;
    else if (strcmp(sku, "SHE-R16") == 0) relay_count = 16;

    ESP_ERROR_CHECK(relay_driver_init(relay_count));
    ESP_LOGI(TAG, "Step 3a: PCF8574 relay driver initialized (%d relays)", relay_count);

    ESP_ERROR_CHECK(feedback_monitor_init(relay_count));
    ESP_LOGI(TAG, "Step 3b: CD4051 feedback monitor initialized");

#ifdef CONFIG_SHE_HAS_PZEM
    ESP_ERROR_CHECK(energy_monitor_init());
    ESP_LOGI(TAG, "Step 3c: PZEM-004T energy monitor initialized");
#endif

    /* 4. Restore last relay state from NVS (persist property) */
    relay_restore_state();
    ESP_LOGI(TAG, "Step 4: Relay state restored from NVS");

    /* 5. Node init — build the RainMaker hierarchy */
    she_node_t *node = profile_build_for_sku(sku);
    if (!node) {
        ESP_LOGE(TAG, "Failed to build node profile for SKU %s — halting", sku);
        vTaskDelay(portMAX_DELAY);
    }
    update_node_identity(node, mac, sku, node_id);
    ESP_LOGI(TAG, "Step 5: Node profile built — node_id=%s mac=%s sku=%s (%d devices)",
             node->node_id, node->mac, node->sku, node->device_count);

    /* 6. If not provisioned → start BLE provisioning (blocks) */
    if (!ble_provisioning_is_provisioned()) {
        ESP_LOGI(TAG, "Step 6: Device not provisioned — starting BLE provisioning");
        ble_provisioning_start(node);
        /* This should not return — device reboots after provisioning */
    } else {
        ESP_LOGI(TAG, "Step 6: Device already provisioned — skipping BLE");
    }

    /* 7. Wi-Fi connect (from NVS creds, 30s timeout) */
    ESP_LOGI(TAG, "Step 7: Connecting to Wi-Fi...");
    if (app_wifi_connect() != ESP_OK) {
        ESP_LOGE(TAG, "Wi-Fi connect failed — retrying in 30s");
        vTaskDelay(pdMS_TO_TICKS(30000));
        esp_restart();
    }

    /* 8. MQTT connect (mTLS, cert from fctry NVS) */
    ESP_LOGI(TAG, "Step 8: Starting MQTT client (mTLS)...");
    /* F7 fix: bounded retry with backoff, then reboot to a clean state
     * instead of running headless forever without cloud connectivity. */
    int mqtt_attempts = 0;
    esp_err_t mqtt_err = mqtt_client_start(node);
    while (mqtt_err != ESP_OK && mqtt_attempts < 3) {
        mqtt_attempts++;
        ESP_LOGW(TAG, "MQTT start failed (attempt %d/3) — retrying in 10s", mqtt_attempts);
        vTaskDelay(pdMS_TO_TICKS(10000));
        mqtt_err = mqtt_client_start(node);
    }
    if (mqtt_err != ESP_OK) {
        ESP_LOGE(TAG, "MQTT init failed after 3 attempts — rebooting in 30s");
        vTaskDelay(pdMS_TO_TICKS(30000));
        esp_restart();
    }
    /* NOTE: the actual broker connection completes async (MQTT_EVENT_CONNECTED).
     * Runtime drops are handled by the OTA health check (step 12) + esp-mqtt
     * reconnect, not here. */

    /* 9. Start esp_local_ctrl (mDNS + HTTPS + PoP) */
    ESP_ERROR_CHECK(local_ctrl_start(node));
    ESP_LOGI(TAG, "Step 9: Local control started (mDNS _she_ctrl._tcp + HTTPS :443)");

    /* 10. Start energy_monitor (R8/R16 only) */
#ifdef CONFIG_SHE_HAS_PZEM
    energy_monitor_start();
    ESP_LOGI(TAG, "Step 10: Energy monitor started (5s poll)");
#else
    ESP_LOGI(TAG, "Step 10: Energy monitor disabled (no PZEM on this SKU)");
#endif

    /* 11. Start voice_control (R16 only) */
#ifdef CONFIG_SHE_R16
    voice_control_init();
    voice_control_start();
    ESP_LOGI(TAG, "Step 11: Voice control started (Picovoice 'Hey Sheba')");
#else
    ESP_LOGI(TAG, "Step 11: Voice control disabled (R16 only)");
#endif

    /* 12. Start OTA handler — if PENDING_VERIFY, start 5-min health check */
    if (ota_handler_is_pending_verify()) {
        ESP_LOGW(TAG, "Step 12: OTA PENDING_VERIFY — starting 5-min health check task");
        xTaskCreate(ota_health_check_task, "ota_health_check", 2048, NULL, 3, NULL);
    } else {
        ESP_LOGI(TAG, "Step 12: No OTA pending — skipping health check");
    }

    /* Start feedback monitor task (after Wi-Fi + MQTT so it can publish) */
    feedback_monitor_start();
    ESP_LOGI(TAG, "Feedback monitor task started");

    /* Start button task */
    button_task_start();
    ESP_LOGI(TAG, "Button task started");

    /* 13. Main loop: publish heartbeat + telemetry every 60s */
    ESP_LOGI(TAG, "========================================");
    ESP_LOGI(TAG, "  Boot complete — entering main loop");
    ESP_LOGI(TAG, "========================================");

    while (true) {
        /* Publish params/local every 60s (V3-FIRMWARE §4 step 13) */
        mqtt_publish_params_local(node);
        /* TODO: publish full telemetry (uptime, RSSI, heap, reset_reason) every 60s */

        vTaskDelay(pdMS_TO_TICKS(60000));
    }
}
