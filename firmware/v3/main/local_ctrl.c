/* =============================================================================
 * SHE V3 firmware — local_ctrl.c
 * =============================================================================
 * V3-FIRMWARE §7. P1-1 (PoP constant-time compare).
 * ==========================================================================*/

#include "local_ctrl.h"
#include "she_mqtt.h"
#include "relay_driver.h"     /* relay_set() / relay_save_state() for the offline control path */
#include "nvs_keys.h"
#include "esp_log.h"
#include "esp_http_server.h"
#include "esp_https_server.h"
#ifdef CONFIG_MDNS
#include "mdns.h"
#endif
#include "mbedtls/constant_time.h"
#include "nvs_flash.h"
#include "cJSON.h"
#include <stdio.h>            /* snprintf */
#include <stdlib.h>
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
        httpd_resp_sendstr(req, "{\"error\":\"invalid_pop\"}");
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
        httpd_resp_sendstr(req, "{\"error\":\"invalid_pop\"}");
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
    if (!root) {
        httpd_resp_set_status(req, "400 Bad Request");
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"error\":\"malformed_json\"}");
        return ESP_OK;
    }

    cJSON *dev_name = cJSON_GetObjectItem(root, "device_name");
    cJSON *params = cJSON_GetObjectItem(root, "params");

    if (!cJSON_IsString(dev_name) || !cJSON_IsObject(params)) {
        cJSON_Delete(root);
        httpd_resp_set_status(req, "400 Bad Request");
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"error\":\"expected device_name:string, params:object\"}");
        return ESP_OK;
    }

    if (!g_node) {
        cJSON_Delete(root);
        httpd_resp_set_status(req, "503 Service Unavailable");
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"error\":\"node_profile_not_ready\"}");
        return ESP_OK;
    }

    /* Resolve the device by name and apply every writable bool param it declares.
     *
     * This mirrors handle_params_remote() in she_mqtt.c, but for the single-device
     * shape the local API uses. It is the offline path: when the broker is
     * unreachable this is the ONLY way to operate a relay, so it must actually
     * drive the hardware — and it must report failure honestly rather than
     * returning accepted:true for a request it ignored. */
    node_device_t *dev = NULL;
    for (int i = 0; i < g_node->device_count; i++) {
        if (strcmp(g_node->devices[i].name, dev_name->valuestring) == 0) {
            dev = &g_node->devices[i];
            break;
        }
    }

    if (!dev) {
        ESP_LOGW(TAG, "Local control: unknown device '%s'", dev_name->valuestring);
        cJSON_Delete(root);
        httpd_resp_set_status(req, "404 Not Found");
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"error\":\"unknown_device\"}");
        return ESP_OK;
    }

    int applied = 0;
    for (int j = 0; j < dev->param_count; j++) {
        node_param_t *p = &dev->params[j];
        if (!(p->properties & PROP_WRITE)) {
            continue;                      /* read-only params are not commands */
        }
        cJSON *v = cJSON_GetObjectItem(params, p->name);
        if (!v) {
            continue;
        }
        if (p->data_type == DATA_BOOL && cJSON_IsBool(v)) {
            const bool on = cJSON_IsTrue(v);
            p->last_value.type = DATA_BOOL;
            p->last_value.val.b = on;
            p->dirty = true;

            esp_err_t err = relay_set(dev->channel, on);
            if (err != ESP_OK) {
                ESP_LOGW(TAG, "Local control: relay_set(ch=%d, %s) failed: %s",
                         dev->channel, on ? "ON" : "OFF", esp_err_to_name(err));
            } else {
                ESP_LOGI(TAG, "Local control: %s (ch %d) -> %s",
                         dev->name, dev->channel, on ? "ON" : "OFF");
                applied++;
            }
        }
    }

    if (applied == 0) {
        cJSON_Delete(root);
        httpd_resp_set_status(req, "400 Bad Request");
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"error\":\"no_writable_param_applied\"}");
        return ESP_OK;
    }

    /* Persist so the state survives a reboot, and mirror it to the cloud shadow.
     * mqtt_publish_params_local() is a no-op while disconnected, which is exactly
     * what we want offline. */
    relay_save_state();
    mqtt_publish_params_local(g_node);

    char resp[160];
    snprintf(resp, sizeof(resp),
             "{\"accepted\":true,\"device\":\"%s\",\"applied\":%d}",
             dev->name, applied);
    cJSON_Delete(root);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, resp);
    return ESP_OK;
}

/* ---- Write one connectivity key into BOTH NVS partitions ----
 *
 * she_mqtt reads she_nvs first and falls back to fctry, and fctry holds the
 * factory-reset-proof copy (see nvs_keys.h). Writing only she_nvs would leave the
 * two disagreeing, so a later factory reset would silently revert the device to a
 * stale broker address. Keep them in step.
 */
static esp_err_t write_conn_key(const char *key, const char *value) {
    esp_err_t result = ESP_OK;

    nvs_handle_t h;
    if (nvs_open(SHE_NVS_NAMESPACE, NVS_READWRITE, &h) == ESP_OK) {
        esp_err_t e = nvs_set_str(h, key, value);
        if (e == ESP_OK) e = nvs_commit(h);
        nvs_close(h);
        if (e != ESP_OK) {
            ESP_LOGW(TAG, "Failed to write %s to %s: %s", key, SHE_NVS_NAMESPACE,
                     esp_err_to_name(e));
            result = e;
        }
    } else {
        ESP_LOGW(TAG, "Could not open %s for write", SHE_NVS_NAMESPACE);
        result = ESP_FAIL;
    }

    nvs_handle_t fh;
    if (nvs_open_from_partition("fctry", SHE_FCTRY_NAMESPACE, NVS_READWRITE, &fh) == ESP_OK) {
        esp_err_t e = nvs_set_str(fh, key, value);
        if (e == ESP_OK) e = nvs_commit(fh);
        nvs_close(fh);
        if (e != ESP_OK) {
            ESP_LOGW(TAG, "Failed to write %s to fctry: %s", key, esp_err_to_name(e));
        }
    }
    return result;
}

/* ---- HTTP POST /she/config ----
 *
 * Re-point the device at a different broker/API without a reflash and without
 * losing the Wi-Fi credentials that live in she_nvs. This exists because the
 * broker address is baked into NVS at provisioning time, so a DHCP change used to
 * mean re-provisioning the whole device.
 *
 * Body (both keys optional):
 *   {"mqtt_broker":"mqtts://192.168.1.7:8883","api_base_url":"http://192.168.1.7:8080"}
 */
static esp_err_t handler_config(httpd_req_t *req) {
    char pop_header[16] = {0};
    size_t pop_len = httpd_req_get_hdr_value_len(req, "X-SHE-PoP");
    if (pop_len > 0 && pop_len < sizeof(pop_header)) {
        httpd_req_get_hdr_value_str(req, "X-SHE-PoP", pop_header, sizeof(pop_header));
    }
    if (!verify_pop(pop_header, strlen(pop_header))) {
        httpd_resp_set_status(req, "401 Unauthorized");
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"error\":\"invalid_pop\"}");
        return ESP_OK;
    }

    char buf[320] = {0};
    int read = httpd_req_recv(req, buf, sizeof(buf) - 1);
    if (read <= 0) {
        httpd_resp_set_status(req, "400 Bad Request");
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"error\":\"empty_body\"}");
        return ESP_OK;
    }

    cJSON *root = cJSON_Parse(buf);
    if (!root) {
        httpd_resp_set_status(req, "400 Bad Request");
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"error\":\"malformed_json\"}");
        return ESP_OK;
    }

    cJSON *broker = cJSON_GetObjectItem(root, "mqtt_broker");
    cJSON *api = cJSON_GetObjectItem(root, "api_base_url");

    if (!cJSON_IsString(broker) && !cJSON_IsString(api)) {
        cJSON_Delete(root);
        httpd_resp_set_status(req, "400 Bad Request");
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"error\":\"expected mqtt_broker and/or api_base_url\"}");
        return ESP_OK;
    }

    char new_broker[80] = {0};
    char new_api[80] = {0};

    if (cJSON_IsString(broker)) {
        snprintf(new_broker, sizeof(new_broker), "%s", broker->valuestring);
        write_conn_key(SHE_NVS_KEY_MQTT_BROKER, new_broker);
        ESP_LOGI(TAG, "Config: mqtt_broker -> %s", new_broker);
    }
    if (cJSON_IsString(api)) {
        snprintf(new_api, sizeof(new_api), "%s", api->valuestring);
        write_conn_key(SHE_NVS_KEY_API_BASE_URL, new_api);
        ESP_LOGI(TAG, "Config: api_base_url -> %s", new_api);
    }
    cJSON_Delete(root);

    /* Reconnect MQTT so the new address takes effect now rather than at the next
     * reboot — we cannot reboot from here, the board has no working reset line. */
    if (new_broker[0] != '\0' && g_node) {
        mqtt_client_stop();
        esp_err_t e = mqtt_client_start(g_node);
        ESP_LOGI(TAG, "Config: MQTT restarted on new broker: %s", esp_err_to_name(e));
    }

    /* Sized so the compiler can prove no truncation: 42 fixed chars + two
     * 79-char values + NUL = 201, comfortably inside 256. -Werror=format-truncation
     * rejects anything it cannot bound. */
    char resp[256];
    snprintf(resp, sizeof(resp),
             "{\"accepted\":true,\"mqtt_broker\":\"%s\",\"api_base_url\":\"%s\"}",
             new_broker, new_api);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, resp);
    return ESP_OK;
}

/* ---- Start mDNS advertisement ---- */
static esp_err_t start_mdns(she_node_t *node) {
#ifdef CONFIG_MDNS
    ESP_ERROR_CHECK(mdns_init());
    /* Hostname = node_id (e.g. "she-r8-aabbcc") */
    char hostname[32];
    snprintf(hostname, sizeof(hostname), "%s", node->node_id);
    for (char *p = hostname; *p; p++) *p = tolower(*p);
    ESP_ERROR_CHECK(mdns_hostname_set(hostname));
    ESP_ERROR_CHECK(mdns_service_add(hostname, SHE_MDNS_SERVICE_TYPE, SHE_MDNS_PROTO, SHE_MDNS_PORT, NULL, 0));
    ESP_LOGI(TAG, "mDNS: %s.%s.local.:%d", hostname, SHE_MDNS_SERVICE_TYPE, SHE_MDNS_PORT);
#else
    ESP_LOGI(TAG, "mDNS disabled (CONFIG_MDNS=n) — local control via mDNS stubbed");
    (void)node;
#endif
    return ESP_OK;
}

/* ---- Read a PEM string from fctry NVS (malloc'd, caller frees) ---- */
static esp_err_t read_fctry_pem(const char *key, char **out) {
    nvs_handle_t h;
    esp_err_t err = nvs_open_from_partition("fctry", SHE_FCTRY_NAMESPACE, NVS_READONLY, &h);
    if (err != ESP_OK) return err;
    size_t len = 0;
    err = nvs_get_str(h, key, NULL, &len);
    if (err != ESP_OK || len == 0) {
        nvs_close(h);
        return ESP_FAIL;
    }
    *out = malloc(len);
    if (!*out) {
        nvs_close(h);
        return ESP_ERR_NO_MEM;
    }
    err = nvs_get_str(h, key, *out, &len);
    nvs_close(h);
    return err;
}

/* ---- Register /she/info + /she/ctrl on a started server ---- */
static esp_err_t register_uris(httpd_handle_t server) {
    httpd_uri_t uri_info = {
        .uri = "/she/info", .method = HTTP_GET, .handler = handler_info,
    };
    ESP_ERROR_CHECK(httpd_register_uri_handler(server, &uri_info));

    httpd_uri_t uri_ctrl = {
        .uri = "/she/ctrl", .method = HTTP_POST, .handler = handler_ctrl,
    };
    ESP_ERROR_CHECK(httpd_register_uri_handler(server, &uri_ctrl));

    httpd_uri_t uri_config = {
        .uri = "/she/config", .method = HTTP_POST, .handler = handler_config,
    };
    return httpd_register_uri_handler(server, &uri_config);
}

/* ---- Start HTTPS server (F1 fix: real TLS via esp_https_server) ----
 * Uses the factory-issued device cert + key from fctry NVS (same identity
 * as MQTT mTLS). Plain HTTP is only allowed on DevKit bring-up builds. */
static esp_err_t start_https_server(void) {
    char *cert_pem = NULL, *key_pem = NULL;
    bool have_tls = (read_fctry_pem(SHE_FCTRY_KEY_CERT, &cert_pem) == ESP_OK)
                 && (read_fctry_pem(SHE_FCTRY_KEY_KEY, &key_pem) == ESP_OK);

    if (have_tls) {
        httpd_ssl_config_t conf = HTTPD_SSL_CONFIG_DEFAULT();
        conf.httpd.server_port = SHE_MDNS_PORT;
        conf.httpd.ctrl_port = 32768;
        conf.servercert = (const uint8_t *)cert_pem;
        conf.servercert_len = strlen(cert_pem) + 1;
        conf.prvtkey_pem = (const uint8_t *)key_pem;
        conf.prvtkey_len = strlen(key_pem) + 1;

        httpd_handle_t server = NULL;
        esp_err_t err = httpd_ssl_start(&server, &conf);
        /* Buffers are copied by httpd_ssl_start — free our copies */
        free(cert_pem);
        free(key_pem);
        if (err == ESP_OK) {
            ESP_ERROR_CHECK(register_uris(server));
            ESP_LOGI(TAG, "HTTPS server started on port %d (mDNS _she_ctrl._tcp)", SHE_MDNS_PORT);
            return ESP_OK;
        }
        ESP_LOGE(TAG, "httpd_ssl_start failed: %s", esp_err_to_name(err));
        return err;
    }

    free(cert_pem);
    free(key_pem);
#ifdef CONFIG_SHE_DEVKIT_ESP32
    ESP_LOGW(TAG, "No device cert in fctry NVS — DevKit fallback to PLAIN HTTP on :%d", SHE_MDNS_PORT);
    httpd_handle_t server = NULL;
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.server_port = SHE_MDNS_PORT;
    config.ctrl_port = 32768;
    if (httpd_start(&server, &config) == ESP_OK) {
        ESP_ERROR_CHECK(register_uris(server));
        return ESP_OK;
    }
    return ESP_FAIL;
#else
    ESP_LOGE(TAG, "No device cert in fctry NVS — refusing plain HTTP (factory provisioning incomplete)");
    return ESP_FAIL;
#endif
}

/* ---- Start local control ---- */
esp_err_t local_ctrl_start(she_node_t *node) {
    g_node = node;
    start_mdns(node);
    return start_https_server();
}
