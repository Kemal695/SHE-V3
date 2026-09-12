/* =============================================================================
 * SHE V3 firmware — ble_provisioning.c (app-claims flow)
 * =============================================================================
 * Standard Espressif wifi_prov_mgr BLE provisioning (Security 1, PoP).
 * V3-FIRMWARE §5. P1-1, P1-2, P1-3, P1-26. P0-1 (cert is factory-issued).
 * App-claims: device only does Wi-Fi provisioning here. The mobile app calls
 * POST /api/v3/nodes/claim (P1-3) afterwards; the device never POSTs claim.
 * ==========================================================================*/

#include "ble_provisioning.h"
#include "nvs_keys.h"
#include "esp_log.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_system.h"
#include "nvs_flash.h"
#include "wifi_provisioning/manager.h"
#include "wifi_provisioning/scheme_ble.h"
#include "esp_mac.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include <string.h>

static const char *TAG = "she_ble";

/* DevKit bring-up PoP (P1-26 format: 9-digit numeric). DEV ONLY — production
 * devices get a CSPRNG PoP programmed at the factory (P1-1). */
#define SHE_DEVKIT_DEFAULT_POP    "123456789"

/* ---- Read PoP from fctry NVS (P1-1: 9-digit numeric CSPRNG) ---- */
static esp_err_t read_pop_from_fctry(char *pop, size_t pop_len) {
    nvs_handle_t h;
    esp_err_t err = nvs_open_from_partition("fctry", SHE_FCTRY_NAMESPACE, NVS_READONLY, &h);
    if (err != ESP_OK) return err;
    size_t len = pop_len;
    err = nvs_get_str(h, SHE_FCTRY_KEY_POP, pop, &len);
    nvs_close(h);
    return err;
}

/* ---- Provisioning event handler: mark provisioned + reboot on Wi-Fi success ----
 * App-claims: the app calls POST /api/v3/nodes/claim after Wi-Fi succeeds,
 * so the device only persists the provisioned flag here. */
static void prov_event_handler(void *arg, esp_event_base_t event_base,
                               int32_t event_id, void *event_data) {
    if (event_base == WIFI_PROV_EVENT) {
        switch (event_id) {
        case WIFI_PROV_START:
            ESP_LOGI(TAG, "Provisioning started");
            break;
        case WIFI_PROV_CRED_RECV: {
            wifi_sta_config_t *sta_cfg = (wifi_sta_config_t *)event_data;
            ESP_LOGI(TAG, "Wi-Fi creds received — SSID: %s", sta_cfg->ssid);
            break;
        }
        case WIFI_PROV_CRED_FAIL: {
            wifi_prov_sta_fail_reason_t *reason = (wifi_prov_sta_fail_reason_t *)event_data;
            ESP_LOGE(TAG, "Wi-Fi connect failed: %s",
                     (*reason == WIFI_PROV_STA_AUTH_ERROR) ? "auth error" : "AP not found");
            break;
        }
        case WIFI_PROV_CRED_SUCCESS:
            ESP_LOGI(TAG, "Wi-Fi connected — waiting for IP...");
            break;
        case WIFI_PROV_END:
            ESP_LOGI(TAG, "Provisioning session ended");
            break;
        default:
            break;
        }
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *event = (ip_event_got_ip_t *)event_data;
        ESP_LOGI(TAG, "Got IP: " IPSTR " — marking provisioned, rebooting in 2s",
                 IP2STR(&event->ip_info.ip));

        /* Persist provisioned flag in fctry NVS so next boot skips BLE */
        nvs_handle_t fctry_h;
        if (nvs_open_from_partition("fctry", SHE_FCTRY_NAMESPACE,
                                    NVS_READWRITE, &fctry_h) == ESP_OK) {
            nvs_set_u8(fctry_h, SHE_FCTRY_KEY_PROVISIONED, 1);
            nvs_commit(fctry_h);
            nvs_close(fctry_h);
        }
        vTaskDelay(pdMS_TO_TICKS(2000));
        esp_restart();
    }
}

/* ---- Check if device is already provisioned ---- */
bool ble_provisioning_is_provisioned(void) {
    nvs_handle_t h;
    esp_err_t err = nvs_open_from_partition("fctry", SHE_FCTRY_NAMESPACE, NVS_READONLY, &h);
    if (err != ESP_OK) return false;
    uint8_t provisioned = 0;
    nvs_get_u8(h, SHE_FCTRY_KEY_PROVISIONED, &provisioned);
    nvs_close(h);
    return provisioned == 1;
}

/* ---- Start BLE provisioning ---- */
esp_err_t ble_provisioning_start(she_node_t *node) {
    ESP_LOGI(TAG, "Starting BLE provisioning (Service UUID: %s)", SHE_BLE_SERVICE_UUID);

    /* Read PoP from fctry NVS (P1-1: 9-digit numeric CSPRNG) */
    char pop[16] = {0};
    bool pop_from_nvs = true;
    if (read_pop_from_fctry(pop, sizeof(pop)) != ESP_OK) {
        pop_from_nvs = false;
#ifdef CONFIG_SHE_DEVKIT_ESP32
        /* DevKit bring-up: no factory PoP — use + persist the dev default */
        strncpy(pop, SHE_DEVKIT_DEFAULT_POP, sizeof(pop) - 1);
        nvs_handle_t fctry_h;
        if (nvs_open_from_partition("fctry", SHE_FCTRY_NAMESPACE,
                                    NVS_READWRITE, &fctry_h) == ESP_OK) {
            nvs_set_str(fctry_h, SHE_FCTRY_KEY_POP, pop);
            nvs_commit(fctry_h);
            nvs_close(fctry_h);
        }
        ESP_LOGW(TAG, "No factory PoP — DevKit default PoP: %s", pop);
#else
        ESP_LOGE(TAG, "PoP not found in fctry NVS — factory provisioning incomplete");
        return ESP_FAIL;
#endif
    }
    /* Log the PoP *and* where it came from. The fctry partition survives
     * re-flashing, so a device that was ever provisioned with a different
     * PoP keeps that value and every app handshake fails with a generic
     * "secure session rejected" until the app is given this exact PoP. */
    ESP_LOGI(TAG, "PoP = %s (source: %s) — type this into the app's PoP field",
             pop, pop_from_nvs ? "fctry NVS" : "DevKit default");
    ESP_LOGW(TAG, "Erase stale fctry PoP with: idf.py -p <PORT> erase-flash");

    /* Advertised device name = node_id (e.g. "SHE-R8-AABBCC").
     * DevKit without factory identity: derive "SHE-<MAC24>" from eFuse MAC. */
    char service_name[32];
    if (node->node_id && strlen(node->node_id) > 0) {
        strncpy(service_name, node->node_id, sizeof(service_name) - 1);
        service_name[sizeof(service_name) - 1] = '\0';
    } else {
        uint8_t mac[6] = {0};
        esp_read_mac(mac, ESP_MAC_WIFI_STA);
        snprintf(service_name, sizeof(service_name), "SHE-%02X%02X%02X",
                 mac[3], mac[4], mac[5]);
#ifdef CONFIG_SHE_DEVKIT_ESP32
        ESP_LOGW(TAG, "No node_id — DevKit service name: %s", service_name);
#endif
    }
    ESP_LOGI(TAG, "Advertised name: %s", service_name);

    /* Initialize Wi-Fi provisioning manager with BLE scheme */
    wifi_prov_mgr_config_t cfg = {
        .scheme = wifi_prov_scheme_ble,
#if defined(CONFIG_SHE_R4) || defined(CONFIG_SHE_DEVKIT_ESP32)
        .scheme_event_handler = WIFI_PROV_SCHEME_BLE_EVENT_HANDLER_FREE_BLE,
#else
        .scheme_event_handler = WIFI_PROV_SCHEME_BLE_EVENT_HANDLER_FREE_BTDM,
#endif
    };
    ESP_ERROR_CHECK(wifi_prov_mgr_init(cfg));

    /* Set service UUID (P1-2: 0000ffff-0000-1000-8000-00805f9b34fb).
     * ESP-IDF expects the 128-bit UUID as a LITTLE-ENDIAN (LSB-first) byte
     * array, so the 16-bit 0xFFFF belongs at offset 12-13 — NOT at 2-3.
     * Placing it at 2-3 dropped the 0xFFFF into the wrong UUID field, so the
     * device advertised a service UUID that is not the Bluetooth base UUID
     * and not P1-2 (clients then fail to open a provisioning session on it).
     * Kept static: the API keeps the pointer, and provisioning runs for the
     * lifetime of the firmware. */
    static uint8_t she_ble_service_uuid[16] = {
        0xfb, 0x34, 0x9b, 0x5f, 0x80, 0x00, 0x00, 0x80,
        0x00, 0x10, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00,
    };
    wifi_prov_scheme_ble_set_service_uuid(she_ble_service_uuid);

    /* Standard Espressif Wi-Fi provisioning (prov-session/prov-config/prov-scan).
     * No custom "she-prov" endpoint in app-claims flow — the app sends only
     * Wi-Fi creds over BLE, then calls POST /api/v3/nodes/claim itself. */
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_PROV_EVENT, ESP_EVENT_ANY_ID,
                                               &prov_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                               &prov_event_handler, NULL));
    esp_err_t prov_err = wifi_prov_mgr_start_provisioning(WIFI_PROV_SECURITY_1, pop, service_name, NULL);
    if (prov_err == ESP_ERR_INVALID_STATE) {
        /* Stale manager state: a previous failed attempt left Wi-Fi creds in
         * the manager while our provisioned flag is still 0. The manager then
         * refuses to start and the phone fails with "Failed to create
         * session". Tear down and start clean (deinit/stop are documented
         * no-op-safe when idle). */
        ESP_LOGW(TAG, "Provisioning already started/stale — resetting manager for a clean session");
        wifi_prov_mgr_stop_provisioning();
        wifi_prov_mgr_deinit();
        ESP_ERROR_CHECK(wifi_prov_mgr_init(cfg));
        prov_err = wifi_prov_mgr_start_provisioning(WIFI_PROV_SECURITY_1, pop, service_name, NULL);
    }
    ESP_ERROR_CHECK(prov_err);

    ESP_LOGI(TAG, "BLE provisioning started — waiting for app to connect (PoP: %s)", pop);

    /* Block until provisioning completes (IP_EVENT_STA_GOT_IP reboots above).
     * For Phase 1: placeholder — actual implementation uses event groups. */
    while (true) {
        vTaskDelay(pdMS_TO_TICKS(1000));
    }

    return ESP_OK;
}
