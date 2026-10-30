/* =============================================================================
 * SHE V3 firmware — app_wifi.c
 * =============================================================================
 * V3-FIRMWARE §2.2.
 * ==========================================================================*/

#include "app_wifi.h"
#include "esp_log.h"
#include "esp_wifi.h"
#include "nvs_flash.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include <string.h>

static const char *TAG = "she_wifi";

#define WIFI_CONNECTED_BIT  BIT0
#define WIFI_FAIL_BIT       BIT1
#define MAX_RETRY           5

static EventGroupHandle_t s_wifi_event_group;
static int s_retry_count = 0;
static bool s_connected = false;

/* Cumulative disconnects since boot — reported on the `telemetry` topic so the
 * cloud can chart link stability. Distinct from s_retry_count, which resets to 0
 * on every successful connect. */
static uint32_t s_disconnect_count = 0;

/* True while wifi_prov_mgr owns the STA connection — see app_wifi.h. */
static bool s_provisioning_active = false;

void app_wifi_set_provisioning_active(bool active) {
    s_provisioning_active = active;
}

uint32_t app_wifi_disconnect_count(void) {
    return s_disconnect_count;
}

static void event_handler(void *arg, esp_event_base_t event_base,
                          int32_t event_id, void *event_data) {
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_START) {
        /* wifi_prov_mgr starts the driver itself, and at that point no SSID is
         * configured yet — esp_wifi_connect() would just fail with
         * ESP_ERR_WIFI_SSID and emit no STA_DISCONNECTED event. Let the manager
         * do the connecting while it owns the session. */
        if (!s_provisioning_active) {
            esp_wifi_connect();
        }
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        s_connected = false;
        s_disconnect_count++;
        if (s_provisioning_active) {
            /* The provisioning manager is driving the connection and counting the
             * failures itself. Racing it here (and blocking the event loop with
             * the backoff below) is what left the board retrying forever instead
             * of concluding that the join had failed. */
            return;
        }
        if (s_retry_count < MAX_RETRY) {
            /* F11 fix: exponential backoff — 500ms, 1s, 2s, 4s, 8s (cap 10s).
             * Gentler on the AP and on the event task than a tight retry loop. */
            int backoff_ms = 500 << s_retry_count;
            if (backoff_ms > 10000) backoff_ms = 10000;
            s_retry_count++;
            ESP_LOGI(TAG, "Retrying Wi-Fi connect (%d/%d) in %dms", s_retry_count, MAX_RETRY, backoff_ms);
            vTaskDelay(pdMS_TO_TICKS(backoff_ms));
            esp_wifi_connect();
        } else {
            xEventGroupSetBits(s_wifi_event_group, WIFI_FAIL_BIT);
        }
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *event = (ip_event_got_ip_t *)event_data;
        ESP_LOGI(TAG, "Got IP: " IPSTR, IP2STR(&event->ip_info.ip));
        s_retry_count = 0;
        s_connected = true;
        xEventGroupSetBits(s_wifi_event_group, WIFI_CONNECTED_BIT);
    }
}

esp_err_t app_wifi_init(void) {
    s_wifi_event_group = xEventGroupCreate();

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));

    esp_event_handler_instance_t instance_any_id;
    esp_event_handler_instance_t instance_got_ip;
    ESP_ERROR_CHECK(esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                                         &event_handler, NULL, &instance_any_id));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                                         &event_handler, NULL, &instance_got_ip));

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));

    ESP_LOGI(TAG, "Wi-Fi subsystem initialized (STA mode)");
    return ESP_OK;
}

esp_err_t app_wifi_connect(void) {
    ESP_ERROR_CHECK(esp_wifi_start());

    /* Disable Wi-Fi MODEM SLEEP (2026-10-30).
     *
     * The IDF default is WIFI_PS_MIN_MODEM, which parks the radio between
     * beacons: measured on this board with an EXCELLENT signal (-47 dBm, zero
     * disconnects) the LAN RTT was 209-800 ms and 1.2 KB pings lost up to 50 %.
     * Small frames still get through, so MQTT looked perfectly healthy while
     * local control was unusable — a TLS handshake needs several round trips
     * plus ~1-2 KB frames, and it simply never completed ("Board not reachable",
     * /she/info returning 200 with an empty body, errno 104).
     *
     * This board is mains-powered through the relay PSU, so the battery saving
     * buys nothing and costs the whole local-control feature. WIFI_PS_NONE keeps
     * the radio awake and brings the RTT back to single-digit ms. */
    ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_NONE));

    /* Distinguish "no SSID stored at all" from "SSID stored, association
     * failed". The two need opposite handling in main.c: the first means the
     * device is not really provisioned, the second means the AP is down or the
     * password is wrong.
     *
     * The previous check — nvs_open("nvs.net80211") — could not tell them
     * apart. The Wi-Fi driver creates that namespace during esp_wifi_init(),
     * so it opens successfully even on a board that has never been
     * provisioned. The connect then fails inside the STA_START handler
     * (esp_wifi_connect() -> ESP_ERR_WIFI_SSID, logged as "invalid ssid"), and
     * that failure emits no STA_DISCONNECTED event, so WIFI_FAIL_BIT is never
     * set and the caller eats the full 30s timeout with no idea why.
     *
     * esp_wifi_get_config() reports what the driver actually loaded, which is
     * the honest answer. esp_wifi_start() has already re-applied the stored
     * config synchronously by the time it returns. */
    wifi_config_t conf = {0};
    if (esp_wifi_get_config(WIFI_IF_STA, &conf) == ESP_OK && conf.sta.ssid[0] == '\0') {
        ESP_LOGE(TAG, "No SSID configured — this device has no Wi-Fi credentials");
        return ESP_ERR_INVALID_STATE;
    }

    /* Wait for connection or timeout (30s) */
    EventBits_t bits = xEventGroupWaitBits(s_wifi_event_group,
        WIFI_CONNECTED_BIT | WIFI_FAIL_BIT,
        pdFALSE, pdFALSE,
        pdMS_TO_TICKS(30000));

    if (bits & WIFI_CONNECTED_BIT) {
        ESP_LOGI(TAG, "Connected to Wi-Fi");
        return ESP_OK;
    } else {
        ESP_LOGE(TAG, "Failed to connect to Wi-Fi within 30s");
        return ESP_FAIL;
    }
}

bool app_wifi_is_connected(void) {
    return s_connected;
}
