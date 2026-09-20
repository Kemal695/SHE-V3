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
#include "schedule_store.h"
#include "system_service.h"

#ifdef CONFIG_SHE_R16
#include "voice_control.h"
#endif

#include "esp_log.h"
#include "esp_app_desc.h"    /* esp_app_get_description() — version reported in ota/status */
#include "esp_system.h"
#include "esp_heap_caps.h"   /* heap diagnostics for TLS handshake failures */
#include "esp_timer.h"       /* uptime for the Diagnostics service */
#include "esp_wifi.h"        /* RSSI for the Diagnostics service */
#include "nvs_flash.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include <string.h>

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

/* ---- 5-minute OTA health check task (F6 fix) ----
 *
 * Three numbers, and the first two exist because the original version got them wrong. It
 * demanded "connected" on the very first poll — before Wi-Fi had even associated — so every
 * OTA rolled back at t=0. A health check that cannot succeed is worse than none: it reverts
 * a good image and bricks the update path.
 *
 *   CONNECT_GRACE_S   how long the image has to *get* online after a reboot. Nothing is
 *                     wrong yet during this window; the app is still starting.
 *   BREAK_TOLERANCE_S how long a drop may last once online. A single 1-second MQTT blip is
 *                     normal on real networks; zero tolerance would revert on noise.
 *   STABLE_REQUIRED_S how long it must stay online to be considered good.
 */
#define CONNECT_GRACE_S     180
#define BREAK_TOLERANCE_S    30
#define STABLE_REQUIRED_S   300

static bool link_is_up(void) {
    return app_wifi_is_connected() && mqtt_client_is_connected();
}

static void ota_health_check_task(void *arg) {
    /* Phase 1 — give the image a chance to come up. */
    int waited = 0;
    while (!link_is_up() && waited < CONNECT_GRACE_S) {
        vTaskDelay(pdMS_TO_TICKS(1000));
        waited++;
    }
    if (!link_is_up()) {
        ESP_LOGE(TAG, "OTA health check FAILED: no Wi-Fi/MQTT within %ds of boot — rolling back",
                 CONNECT_GRACE_S);
        ota_handler_rollback();
        vTaskDelay(pdMS_TO_TICKS(2000));
        esp_restart();
        return;
    }
    ESP_LOGI(TAG, "OTA health check: online after %ds — now watching for %ds of stability",
             waited, STABLE_REQUIRED_S);

    /* Phase 2 — stay up, allowing brief interruptions. */
    int stable_seconds = 0;
    int break_seconds = 0;
    while (stable_seconds < STABLE_REQUIRED_S) {
        vTaskDelay(pdMS_TO_TICKS(1000));
        if (link_is_up()) {
            break_seconds = 0;
            stable_seconds++;
        } else {
            break_seconds++;
            ESP_LOGW(TAG, "OTA health check: link down %ds (stable so far: %ds)",
                     break_seconds, stable_seconds);
            if (break_seconds >= BREAK_TOLERANCE_S) {
                ESP_LOGE(TAG, "OTA health check FAILED: down for %ds — rolling back",
                         break_seconds);
                ota_handler_rollback();
                vTaskDelay(pdMS_TO_TICKS(2000));
                esp_restart();
                return;
            }
        }
    }
    ota_handler_mark_valid();
    ESP_LOGI(TAG, "OTA health check PASSED: stable for 5 minutes — marked valid.");

    /* Tell the backend the rollout actually succeeded.
     *
     * Without this the device's last word was "rebooting", so ota_approvals never reached a
     * terminal state and ota_batches stayed ROLLING forever — a rollout that had genuinely
     * worked still looked in-progress in the admin view. The health check is exactly the
     * signal that distinguishes "booted and stayed up" from "booted and fell over", which is
     * why this publish belongs here and not at the end of the OTA handler.
     *
     * Version comes from the app descriptor, so it reports the image actually running. */
    mqtt_publish_ota_status("success", esp_app_get_description()->version, NULL);

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

/* ---- Sample the Diagnostics service params ----
 *
 * mqtt_publish_params_local() publishes whatever sits in each param's last_value,
 * and nothing ever wrote the Diagnostics ones — so the cloud stored Uptime=0,
 * RSSI=0, Free_Heap=0 and Reset_Reason="" forever and the app's Diagnostics card
 * was dead. Fill them from the live system just before each publish.
 *
 * V3-DEVICE-MODEL §1.4 — these are PROP_READ | PROP_TIME_SERIES.
 */
static void sample_diagnostics(she_node_t *node) {
    /* Reset_Reason is fixed for the life of this boot, so resolve it once. The
     * value is handed to cJSON as a borrowed pointer, so it must stay alive —
     * a function-local buffer would dangle. */
    static char reset_reason[24];
    if (reset_reason[0] == '\0') {
        const char *r;
        switch (esp_reset_reason()) {
            case ESP_RST_POWERON:   r = "power_on";   break;
            case ESP_RST_EXT:       r = "ext_pin";    break;
            case ESP_RST_SW:        r = "software";   break;
            case ESP_RST_PANIC:     r = "panic";      break;
            case ESP_RST_INT_WDT:   r = "int_wdt";    break;
            case ESP_RST_TASK_WDT:  r = "task_wdt";   break;
            case ESP_RST_WDT:       r = "wdt";        break;
            case ESP_RST_DEEPSLEEP: r = "deep_sleep"; break;
            case ESP_RST_BROWNOUT:  r = "brownout";   break;
            case ESP_RST_SDIO:      r = "sdio";       break;
            default:                r = "unknown";    break;
        }
        strncpy(reset_reason, r, sizeof(reset_reason) - 1);
        reset_reason[sizeof(reset_reason) - 1] = '\0';
    }

    int rssi = 0;
    wifi_ap_record_t ap;
    if (esp_wifi_sta_get_ap_info(&ap) == ESP_OK) {
        rssi = ap.rssi;
    }

    const int uptime_s = (int)(esp_timer_get_time() / 1000000LL);
    const int free_heap = (int)esp_get_free_heap_size();

    for (int i = 0; i < node->device_count; i++) {
        node_device_t *d = &node->devices[i];
        if (strcmp(d->name, "Diagnostics") != 0) {
            continue;
        }
        for (int j = 0; j < d->param_count; j++) {
            node_param_t *p = &d->params[j];
            if (strcmp(p->name, "Uptime") == 0) {
                p->last_value = param_int(uptime_s);
            } else if (strcmp(p->name, "RSSI") == 0) {
                p->last_value = param_int(rssi);
            } else if (strcmp(p->name, "Free_Heap") == 0) {
                p->last_value = param_int(free_heap);
            } else if (strcmp(p->name, "Reset_Reason") == 0) {
                p->last_value.type  = DATA_STRING;
                p->last_value.val.s = reset_reason;
            }
        }
    }

    /* Also publish the time series.
     *
     * params/local carries only a single current value per param; `telemetry` is
     * what feeds the device_telemetry hypertable and the app's trend chart. The
     * two are separate channels and are easy to conflate — the firmware used to
     * publish only the former, so the telemetry screen stayed empty forever. */
    mqtt_publish_telemetry(uptime_s, rssi, (uint32_t)free_heap,
                           (uint32_t)esp_get_minimum_free_heap_size(), reset_reason);
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

    /* The device clock is otherwise never set, and payloads stamp themselves with it
     * ("published_at", status "ts"). SNTP retries on its own, so it is safe to start here
     * before Wi-Fi has actually associated. */
    system_service_time_sync_start();

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
    /* The driver caps itself to the 4 physically wired pins in direct-GPIO mode;
     * keep the local count in step so the logs below aren't misleading. */
    if (relay_driver_is_direct_gpio()) {
        relay_count = 4;
    }
    ESP_LOGI(TAG, "Step 3a: relay driver initialized (%d relays)", relay_count);

    /* The feedback monitor drives GPIO 18 as its CD4051 mux-select C. In direct
     * GPIO relay mode that pin is a relay output instead, so the two would fight
     * over it — skip the monitor rather than have it stomp relay state. */
    if (relay_driver_is_direct_gpio()) {
        ESP_LOGW(TAG, "Step 3b: feedback monitor SKIPPED — GPIO 18 is a direct relay output");
    } else {
        ESP_ERROR_CHECK(feedback_monitor_init(relay_count));
        ESP_LOGI(TAG, "Step 3b: CD4051 feedback monitor initialized");
    }

#ifdef CONFIG_SHE_HAS_PZEM
    ESP_ERROR_CHECK(energy_monitor_init());
    ESP_LOGI(TAG, "Step 3c: PZEM-004T energy monitor initialized");
#endif

    /* 4. Restore last relay state from NVS (persist property) */
    relay_restore_state();
    ESP_LOGI(TAG, "Step 4: Relay state restored from NVS");

    /* 4b. Load device-local schedules from NVS (does not need Wi-Fi or SNTP —
     * the watcher simply no-ops until the clock is set). */
    if (schedule_store_init() != ESP_OK) {
        ESP_LOGW(TAG, "Step 4b: Schedule store unavailable — device-local "
                      "scheduling disabled (cloud schedules unaffected)");
    } else {
        ESP_LOGI(TAG, "Step 4b: Device-local schedules loaded from NVS");
    }

    /* 5. Node init — build the RainMaker hierarchy.
     *
     * In direct-GPIO mode only 4 channels physically exist, so advertise the R4
     * profile even when fctry says SHE-R8 — otherwise the app shows eight relay
     * switches of which four are inert, and toggling them logs
     * "relay_set(ch=4, ON) failed: ESP_ERR_INVALID_ARG".
     *
     * Self-correcting: fitting a real PCF8574 makes direct mode inactive, so the
     * fctry SKU is used again and all channels come back with no code change.
     */
    const char *profile_sku = sku;
    if (relay_driver_is_direct_gpio()) {
        profile_sku = "SHE-R4";
        ESP_LOGW(TAG, "Direct GPIO mode: advertising SHE-R4 (4 relays) instead of %s", sku);
    }
    she_node_t *node = profile_build_for_sku(profile_sku);
    if (!node) {
        ESP_LOGE(TAG, "Failed to build node profile for SKU %s — halting", profile_sku);
        vTaskDelay(portMAX_DELAY);
    }
    update_node_identity(node, mac, profile_sku, node_id);
    ESP_LOGI(TAG, "Step 5: Node profile built — node_id=%s mac=%s sku=%s (%d devices)",
             node->node_id, node->mac, node->sku, node->device_count);

    /* Re-sync the profile's cached param values against the hardware.
     *
     * relay_restore_state() runs in Step 4 — before this node exists — so it drives
     * the pins correctly but cannot touch the param cache. The profile is built with
     * every Power = false, so the first params/local publish told the cloud that all
     * relays were OFF even when a relay was physically energised: after every reboot
     * the app showed all switches off while the hardware was in the opposite state.
     * Read the real pin levels back so the shadow matches reality from the first publish.
     */
    for (int i = 0; i < node->device_count; i++) {
        node_device_t *d = &node->devices[i];
        for (int j = 0; j < d->param_count; j++) {
            node_param_t *p = &d->params[j];
            if (p->data_type == DATA_BOOL && (p->properties & PROP_WRITE)) {
                p->last_value = param_bool(relay_get(d->channel));
            }
        }
    }
    ESP_LOGI(TAG, "Relay state synced from hardware: mask=0x%06lX",
             (unsigned long)relay_get_all());

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
    /* Diagnostic: mbedtls returns MBEDTLS_ERR_SSL_INTERNAL_ERROR (-0x6C00) when an
     * internal allocation fails, which is indistinguishable from a protocol error
     * in the esp-tls logs. Report heap so a TLS handshake failure can be told apart
     * from a memory exhaustion. */
    ESP_LOGI(TAG, "Heap before MQTT: free=%u min_free=%u largest_block=%u",
             (unsigned)esp_get_free_heap_size(),
             (unsigned)esp_get_minimum_free_heap_size(),
             (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT));
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

    /* Start feedback monitor task (after Wi-Fi + MQTT so it can publish).
     * Skipped in direct-GPIO relay mode: the task drives GPIO 18 as the CD4051
     * mux-select C, which is a relay output in that mode. Guarding only the
     * init() was not enough — the task is started separately here and was still
     * clobbering the pin. */
    if (relay_driver_is_direct_gpio()) {
        ESP_LOGW(TAG, "Feedback monitor task SKIPPED — GPIO 18 is a direct relay output");
    } else {
        feedback_monitor_start();
        ESP_LOGI(TAG, "Feedback monitor task started");
    }

    /* Start button task */
    button_task_start();
    ESP_LOGI(TAG, "Button task started");

    /* 12b. Start the schedule watcher — fires device-local schedules (including
     * repeating/weekday ones) even when the cloud is unreachable. */
    if (schedule_task_start() != ESP_OK) {
        ESP_LOGW(TAG, "Schedule watcher NOT started — device-local schedules inert");
    }

    /* 13. Main loop: publish heartbeat + telemetry every 60s */
    ESP_LOGI(TAG, "========================================");
    ESP_LOGI(TAG, "  Boot complete — entering main loop");
    ESP_LOGI(TAG, "========================================");

    while (true) {
        /* Sample diagnostics first, then publish params/local (V3-FIRMWARE §4 step 13).
         * Order matters — publishing first would ship the previous sample. */
        sample_diagnostics(node);
        mqtt_publish_params_local(node);

        vTaskDelay(pdMS_TO_TICKS(60000));
    }
}
