/* =============================================================================
 * SHE V3 firmware — ble_provisioning.c
 * =============================================================================
 * BLE SoftAP provisioning + custom claim flow.
 * V3-FIRMWARE §5. P1-1, P1-2, P1-3, P1-26. P0-1 (cert is factory-issued).
 * ==========================================================================*/

#include "ble_provisioning.h"
#include "nvs_keys.h"
#include "esp_log.h"
#include "esp_wifi.h"
#include "nvs_flash.h"
#include "wifi_provisioning/manager.h"
#include "wifi_provisioning/scheme_ble.h"
#include "esp_http_client.h"
#include "cJSON.h"
#include <string.h>

static const char *TAG = "she_ble";

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

/* ---- POST /api/v3/nodes/claim ---- */
static esp_err_t post_claim(const char *api_base_url, const char *mac,
                            const char *sku, const char *claim_token,
                            const char *tenant_id, const char *config_json,
                            char *out_mqtt_broker, size_t broker_len) {
    /* Build request body */
    cJSON *body = cJSON_CreateObject();
    cJSON_AddStringToObject(body, "mac", mac);
    cJSON_AddStringToObject(body, "claim_token", claim_token);
    cJSON_AddStringToObject(body, "sku", sku);
    cJSON_AddStringToObject(body, "tenant_id", tenant_id);
    cJSON_AddRawToObject(body, "config", config_json);
    char *body_str = cJSON_PrintUnformatted(body);

    /* Build URL */
    char url[256];
    snprintf(url, sizeof(url), "%s/api/v3/nodes/claim", api_base_url);

    esp_http_client_config_t config = {
        .url = url,
        .method = HTTP_METHOD_POST,
        .timeout_ms = 10000,
    };
    esp_http_client_handle_t client = esp_http_client_init(&config);
    esp_http_client_set_header(client, "Content-Type", "application/json");
    esp_http_client_set_post_field(client, body_str, strlen(body_str));

    esp_err_t err = esp_http_client_perform(client);
    if (err == ESP_OK) {
        int status = esp_http_client_get_status_code(client);
        int len = esp_http_client_get_content_length(client);
        if (status == 200 && len > 0) {
            char *resp = malloc(len + 1);
            esp_http_client_read(client, resp, len);
            resp[len] = '\0';
            /* Parse response: {"data":{"node_db_id":"...","mqtt_broker":"ssl://mqtt.she.et:8883","node_id":"..."}} */
            cJSON *resp_json = cJSON_Parse(resp);
            cJSON *data = cJSON_GetObjectItem(resp_json, "data");
            cJSON *broker = cJSON_GetObjectItem(data, "mqtt_broker");
            if (broker && cJSON_IsString(broker)) {
                strncpy(out_mqtt_broker, broker->valuestring, broker_len - 1);
                out_mqtt_broker[broker_len - 1] = '\0';
            }
            cJSON_Delete(resp_json);
            free(resp);
            ESP_LOGI(TAG, "Claim successful — mqtt_broker=%s", out_mqtt_broker);
        } else {
            ESP_LOGE(TAG, "Claim failed: HTTP %d", status);
            err = ESP_FAIL;
        }
    }
    esp_http_client_cleanup(client);
    free(body_str);
    cJSON_Delete(body);
    return err;
}

/* ---- Store provisioning info in NVS ---- */
static esp_err_t store_provisioning(const she_provision_payload_t *payload, const char *mqtt_broker) {
    nvs_handle_t h;
    esp_err_t err = nvs_open(SHE_NVS_NAMESPACE, NVS_READWRITE, &h);
    if (err != ESP_OK) return err;

    nvs_set_str(h, SHE_NVS_KEY_TENANT_ID, payload->tenant_id);
    nvs_set_str(h, SHE_NVS_KEY_MQTT_BROKER, mqtt_broker);
    nvs_set_str(h, SHE_NVS_KEY_API_BASE_URL, payload->api_base_url);

    /* Mark as provisioned in fctry NVS */
    nvs_handle_t fctry_h;
    nvs_open_from_partition("fctry", SHE_FCTRY_NAMESPACE, NVS_READWRITE, &fctry_h);
    nvs_set_u8(fctry_h, SHE_FCTRY_KEY_PROVISIONED, 1);
    nvs_commit(fctry_h);
    nvs_close(fctry_h);

    nvs_commit(h);
    nvs_close(h);
    return ESP_OK;
}

/* ---- Custom protobuf callback — receives provisioning payload from app ---- */
static void prov_recv_handler(const uint8_t *data, size_t len) {
    ESP_LOGI(TAG, "Received provisioning payload (%d bytes)", len);
    /* Parse JSON: {wifi_ssid, wifi_password, tenant_id, claim_token, api_base_url} */
    char *json = malloc(len + 1);
    memcpy(json, data, len);
    json[len] = '\0';

    cJSON *root = cJSON_Parse(json);
    if (!root) {
        ESP_LOGE(TAG, "Invalid JSON in provisioning payload");
        free(json);
        return;
    }

    she_provision_payload_t payload = {0};
    cJSON *ssid = cJSON_GetObjectItem(root, "wifi_ssid");
    cJSON *pass = cJSON_GetObjectItem(root, "wifi_password");
    cJSON *tenant = cJSON_GetObjectItem(root, "tenant_id");
    cJSON *token = cJSON_GetObjectItem(root, "claim_token");
    cJSON *api = cJSON_GetObjectItem(root, "api_base_url");

    if (ssid) strncpy(payload.wifi_ssid, ssid->valuestring, sizeof(payload.wifi_ssid) - 1);
    if (pass) strncpy(payload.wifi_password, pass->valuestring, sizeof(payload.wifi_password) - 1);
    if (tenant) strncpy(payload.tenant_id, tenant->valuestring, sizeof(payload.tenant_id) - 1);
    if (token) strncpy(payload.claim_token, token->valuestring, sizeof(payload.claim_token) - 1);
    if (api) strncpy(payload.api_base_url, api->valuestring, sizeof(payload.api_base_url) - 1);

    ESP_LOGI(TAG, "Wi-Fi SSID: %s", payload.wifi_ssid);
    ESP_LOGI(TAG, "Tenant ID: %s", payload.tenant_id);
    ESP_LOGI(TAG, "API base: %s", payload.api_base_url);

    /* 1. Connect to Wi-Fi with provided creds */
    wifi_config_t wifi_cfg = {0};
    strncpy((char *)wifi_cfg.sta.ssid, payload.wifi_ssid, sizeof(wifi_cfg.sta.ssid) - 1);
    strncpy((char *)wifi_cfg.sta.password, payload.wifi_password, sizeof(wifi_cfg.sta.password) - 1);
    esp_wifi_set_config(WIFI_IF_STA, &wifi_cfg);
    esp_wifi_connect();

    /* Wait for Wi-Fi (10s timeout) */
    /* TODO: event group wait */

    /* 2. POST /api/v3/nodes/claim */
    /* Read MAC + SKU from fctry NVS */
    char mac[18] = {0};
    char sku[8] = {0};
    nvs_handle_t fctry_h;
    nvs_open_from_partition("fctry", SHE_FCTRY_NAMESPACE, NVS_READONLY, &fctry_h);
    size_t len2 = sizeof(mac);
    nvs_get_str(fctry_h, SHE_FCTRY_KEY_MAC, mac, &len2);
    len2 = sizeof(sku);
    nvs_get_str(fctry_h, SHE_FCTRY_KEY_SKU, sku, &len2);
    nvs_close(fctry_h);

    /* Build config JSON (minimal for claim) */
    const char *config_json = "{}";   /* Full config published on MQTT connect */

    char mqtt_broker[128] = {0};
    esp_err_t err = post_claim(payload.api_base_url, mac, sku,
                               payload.claim_token, payload.tenant_id,
                               config_json, mqtt_broker, sizeof(mqtt_broker));
    if (err == ESP_OK) {
        /* 3. Store provisioning info in NVS */
        store_provisioning(&payload, mqtt_broker);
        ESP_LOGI(TAG, "Provisioning complete — rebooting in 2s");
        vTaskDelay(pdMS_TO_TICKS(2000));
        esp_restart();
    } else {
        ESP_LOGE(TAG, "Claim failed — user should retry");
    }

    cJSON_Delete(root);
    free(json);
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
    if (read_pop_from_fctry(pop, sizeof(pop)) != ESP_OK) {
        ESP_LOGE(TAG, "PoP not found in fctry NVS — factory provisioning incomplete");
        return ESP_FAIL;
    }
    ESP_LOGI(TAG, "PoP loaded: %s (P1-26: 9-digit numeric)", pop);

    /* Advertised device name = node_id (e.g. "SHE-R8-AABBCC") */
    ESP_LOGI(TAG, "Advertised name: %s", node->node_id);

    /* Initialize Wi-Fi provisioning manager with BLE scheme */
    wifi_prov_mgr_config_t cfg = {
        .scheme = wifi_prov_scheme_ble,
#ifdef CONFIG_SHE_R4
        .scheme_event_handler = WIFI_PROV_SCHEME_BLE_EVENT_HANDLER_FREE_BLE,
#else
        .scheme_event_handler = WIFI_PROV_SCHEME_BLE_EVENT_HANDLER_FREE_BTDM,
#endif
    };
    ESP_ERROR_CHECK(wifi_prov_mgr_init(cfg));

    /* Set service UUID (P1-2: 0000ffff-0000-1000-8000-00805f9b34fb) */
    /* The 16-bit UUID 0xFFFF expands to the full 128-bit Bluetooth Base UUID automatically */
    uint8_t service_uuid[16] = {0};
    service_uuid[2] = 0xFF;
    service_uuid[3] = 0xFF;
    wifi_prov_scheme_ble_set_service_uuid(service_uuid);

    /* Set device name + PoP */
    wifi_prov_mgr_endpoint_create("she-prov");
    wifi_prov_mgr_endpoint_register("she-prov", prov_recv_handler, NULL);
    wifi_prov_mgr_start_provisioning(WIFI_PROV_SECURITY_1, pop, node->node_id, NULL);

    ESP_LOGI(TAG, "BLE provisioning started — waiting for app to connect (PoP: %s)", pop);

    /* Register custom endpoint for receiving provisioning payload */
    /* (In production, register a protocomm handler for "she-prov" endpoint) */

    /* Block until provisioning completes (or timeout) */
    /* For Phase 1: this is a placeholder — actual implementation uses event groups */
    while (true) {
        vTaskDelay(pdMS_TO_TICKS(1000));
    }

    return ESP_OK;
}
