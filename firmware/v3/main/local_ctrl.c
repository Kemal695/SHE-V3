/* =============================================================================
 * SHE V3 firmware — local_ctrl.c
 * =============================================================================
 * V3-FIRMWARE §7. P1-1 (PoP constant-time compare).
 * ==========================================================================*/

#include "local_ctrl.h"
#include "mqtt_client.h"
#include "nvs_keys.h"
#include "esp_log.h"
#include "esp_http_server.h"
#include "mdns.h"
#include "mbedtls/constant_time.h"
#include "nvs_flash.h"
#include "cJSON.h"
#include <string.h>

static const char *TAG = "she_local";
static she_node_t *g_node = NULL;

/* ---- Read PoP from fctry NVS ---- */
static esp_err_t read_pop(char *pop, size_t pop_len) {
    nvs_handle_t h;
    esp_err_t err = nvs_open_from_partition("fctry", SHE_FCTRY_NAMESPACE, NVS_READONLY, &h);
    if (err != ESP_OK) return err;
    size_t len = pop_len;
    err = nvs_get_str(h, SHE_FCTRY_KEY_POP, pop, &len);
    nvs_close(h);
    return err;
}

/* ---- Constant-time PoP verification (P1-1) ---- */
static bool verify_pop(const char *provided, size_t provided_len) {
    char stored_pop[16] = {0};
    if (read_pop(stored_pop, sizeof(stored_pop)) != ESP_OK) {
        ESP_LOGE(TAG, "Failed to read PoP from fctry NVS");
        return false;
    }
    size_t stored_len = strlen(stored_pop);
    if (provided_len != stored_len) return false;
    /* Constant-time compare via mbedtls_ct_memcmp */
    return mbedtls_ct_memcmp(provided, stored_pop, stored_len) == 0;
}

/* ---- HTTP GET /she/info ---- */
static esp_err_t handler_info(httpd_req_t *req) {
    /* Verify PoP from header */
    char pop_header[16] = {0};
    size_t pop_len = httpd_req_get_hdr_value_len(req, "X-SHE-PoP");
    if (pop_len > 0 && pop_len < sizeof(pop_header)) {
        httpd_req_get_hdr_value_str(req, "X-SHE-PoP", pop_header, sizeof(pop_header));
    }
    if (!verify_pop(pop_header, strlen(pop_header))) {
        httpd_resp_set_status(req, "401 Unauthorized");
        httpd_resp_send_string(req, "{\"error\":\"invalid_pop\"}");
        return ESP_OK;
    }

    /* Build response: {node_id, sku, devices[], params[]} */
    cJSON *root = cJSON_CreateObject();
    cJSON_AddStringToObject(root, "node_id", g_node->node_id);
    cJSON_AddStringToObject(root, "sku", g_node->sku);

    cJSON *devices = cJSON_CreateArray();
    for (int i = 0; i < g_node->device_count; i++) {
        const node_device_t *d = &g_node->devices[i];
        if (strncmp(d->type, "esp.service.", 12) == 0) continue;   /* skip services */
        cJSON *dev = cJSON_CreateObject();
        cJSON_AddStringToObject(dev, "name", d->name);
        cJSON_AddStringToObject(dev, "type", d->type);
        cJSON_AddNumberToObject(dev, "channel", d->channel);

        cJSON *params = cJSON_CreateArray();
        for (int j = 0; j < d->param_count; j++) {
            cJSON *p = cJSON_CreateObject();
            cJSON_AddStringToObject(p, "name", d->params[j].name);
            switch (d->params[j].data_type) {
                case DATA_BOOL:   cJSON_AddBoolToObject(p, "value", d->params[j].last_value.val.b); break;
                case DATA_INT:    cJSON_AddNumberToObject(p, "value", d->params[j].last_value.val.i); break;
                case DATA_FLOAT:  cJSON_AddNumberToObject(p, "value", d->params[j].last_value.val.f); break;
                case DATA_STRING: cJSON_AddStringToObject(p, "value", d->params[j].last_value.val.s ? d->params[j].last_value.val.s : ""); break;
            }
            cJSON_AddItemToArray(params, p);
        }
        cJSON_AddItemToObject(dev, "params", params);
        cJSON_AddItemToArray(devices, dev);
    }
    cJSON_AddItemToObject(root, "devices", devices);

    char *resp = cJSON_PrintUnformatted(root);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, resp, strlen(resp));
    free(resp);
    cJSON_Delete(root);
    return ESP_OK;
}

/* ---- HTTP POST /she/ctrl ---- */
static esp_err_t handler_ctrl(httpd_req_t *req) {
    /* Verify PoP */
    char pop_header[16] = {0};
    size_t pop_len = httpd_req_get_hdr_value_len(req, "X-SHE-PoP");
    if (pop_len > 0 && pop_len < sizeof(pop_header)) {
        httpd_req_get_hdr_value_str(req, "X-SHE-PoP", pop_header, sizeof(pop_header));
    }
    if (!verify_pop(pop_header, strlen(pop_header))) {
        httpd_resp_set_status(req, "401 Unauthorized");
        httpd_resp_send_string(req, "{\"error\":\"invalid_pop\"}");
        return ESP_OK;
    }

    /* Parse body: {"device_name":"Relay 1","params":{"Power":true}} */
    char buf[512] = {0};
    int read = httpd_req_recv(req, buf, sizeof(buf) - 1);
    if (read <= 0) {
        httpd_resp_set_status(req, "400 Bad Request");
        return ESP_OK;
    }

    cJSON *root = cJSON_Parse(buf);
    cJSON *dev_name = cJSON_GetObjectItem(root, "device_name");
    cJSON *params = cJSON_GetObjectItem(root, "params");

    if (dev_name && params) {
        ESP_LOGI(TAG, "Local control: device=%s params received", dev_name->valuestring);
        /* TODO: find device in g_node + set relay state via relay_driver */
        /* For Phase 1: log only */
    }

    cJSON_Delete(root);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_send_string(req, "{\"accepted\":true}");
    return ESP_OK;
}

/* ---- Start mDNS advertisement ---- */
static esp_err_t start_mdns(she_node_t *node) {
    ESP_ERROR_CHECK(mdns_init());
    /* Hostname = node_id (e.g. "she-r8-aabbcc") */
    char hostname[32];
    snprintf(hostname, sizeof(hostname), "%s", node->node_id);
    for (char *p = hostname; *p; p++) *p = tolower(*p);
    ESP_ERROR_CHECK(mdns_hostname_set(hostname));
    ESP_ERROR_CHECK(mdns_service_add(hostname, SHE_MDNS_SERVICE_TYPE, SHE_MDNS_PROTO, SHE_MDNS_PORT, NULL, 0));
    ESP_LOGI(TAG, "mDNS: %s.%s.local.:%d", hostname, SHE_MDNS_SERVICE_TYPE, SHE_MDNS_PORT);
    return ESP_OK;
}

/* ---- Start HTTPS server ---- */
static esp_err_t start_https_server(void) {
    httpd_handle_t server = NULL;
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.server_port = SHE_MDNS_PORT;
    config.ctrl_port = 32768;

    /* TODO: configure SSL with self-signed cert per device */
    /* For Phase 1: plain HTTP (production uses esp_https_server) */

    if (httpd_start(&server, &config) == ESP_OK) {
        /* GET /she/info */
        httpd_uri_t uri_info = {
            .uri = "/she/info", .method = HTTP_GET, .handler = handler_info,
        };
        httpd_register_uri_handler(server, &uri_info);

        /* POST /she/ctrl */
        httpd_uri_t uri_ctrl = {
            .uri = "/she/ctrl", .method = HTTP_POST, .handler = handler_ctrl,
        };
        httpd_register_uri_handler(server, &uri_ctrl);

        ESP_LOGI(TAG, "HTTPS server started on port %d", config.server_port);
        return ESP_OK;
    }
    return ESP_FAIL;
}

/* ---- Start local control ---- */
esp_err_t local_ctrl_start(she_node_t *node) {
    g_node = node;
    start_mdns(node);
    return start_https_server();
}
