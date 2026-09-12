/* =============================================================================
 * SHE V3 firmware — mqtt_client.c
 * =============================================================================
 * mTLS MQTT client using ESP-IDF mqtt_client component.
 * V3-FIRMWARE §12.6. V3-MQTT-STANDARDS §7. P1-10, P1-13.
 * ==========================================================================*/

#include "she_mqtt.h"
#include "nvs_keys.h"
#include "esp_log.h"
#include "esp_event.h"
#include "nvs_flash.h"
#include "cJSON.h"
#include "esp_idf_version.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <ctype.h>
#include <time.h>

static const char *TAG = "she_mqtt";

/* Embedded CA bundle (root + intermediate) — from certs/ca.pem */
extern const char ca_pem_start[]   asm("_binary_ca_pem_start");
extern const char ca_pem_end[]   asm("_binary_ca_pem_end");

static esp_mqtt_client_handle_t mqtt_client = NULL;
static bool g_mqtt_connected = false;
static she_node_t *g_node = NULL;

/* Cached provisioning info (from NVS) */
static char g_tenant_short[16];
static char g_home_short[16];
static char g_room_short[16];
static char g_mac[16];             /* normalized MAC (lowercase, no colons) */
static char g_mqtt_broker[128];

/* ---- Build topic: she/{tenant}/{home}/{room}/{mac}/{direction} ---- */
char* mqtt_build_topic(const char *direction) {
    /* room_short may be "unassigned" if device has no room */
    const char *room = (strlen(g_room_short) > 0) ? g_room_short : "unassigned";
    size_t len = strlen("she//////") + strlen(g_tenant_short) + strlen(g_home_short) +
                 strlen(room) + strlen(g_mac) + strlen(direction) + 1;
    char *topic = malloc(len);
    snprintf(topic, len, "she/%s/%s/%s/%s/%s", g_tenant_short, g_home_short, room, g_mac, direction);
    return topic;
}

/* ---- Load provisioning info from NVS ---- */
static esp_err_t load_provisioning_info(void) {
    nvs_handle_t h;
    esp_err_t err = nvs_open(SHE_NVS_NAMESPACE, NVS_READONLY, &h);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to open NVS namespace %s: %s", SHE_NVS_NAMESPACE, esp_err_to_name(err));
        return err;
    }

    /* Read tenant_id (UUID) — take first 8 chars as short form */
    char tenant_uuid[40] = {0};
    size_t len = sizeof(tenant_uuid);
    nvs_get_str(h, SHE_NVS_KEY_TENANT_ID, tenant_uuid, &len);
    /* Extract first 8 hex chars (no dashes) */
    char *dash = tenant_uuid;
    int out_idx = 0;
    for (int i = 0; tenant_uuid[i] && out_idx < 8; i++) {
        if (tenant_uuid[i] != '-') {
            g_tenant_short[out_idx++] = tolower(tenant_uuid[i]);
        }
    }
    g_tenant_short[out_idx] = '\0';

    /* Home ID (may be empty) */
    char home_uuid[40] = {0};
    len = sizeof(home_uuid);
    if (nvs_get_str(h, SHE_NVS_KEY_HOME_ID, home_uuid, &len) == ESP_OK) {
        out_idx = 0;
        for (int i = 0; home_uuid[i] && out_idx < 8; i++) {
            if (home_uuid[i] != '-') {
                g_home_short[out_idx++] = tolower(home_uuid[i]);
            }
        }
        g_home_short[out_idx] = '\0';
    } else {
        strcpy(g_home_short, "00000000");
    }

    /* Room ID (may be empty) */
    char room_uuid[40] = {0};
    len = sizeof(room_uuid);
    if (nvs_get_str(h, SHE_NVS_KEY_ROOM_ID, room_uuid, &len) == ESP_OK) {
        out_idx = 0;
        for (int i = 0; room_uuid[i] && out_idx < 8; i++) {
            if (room_uuid[i] != '-') {
                g_room_short[out_idx++] = tolower(room_uuid[i]);
            }
        }
        g_room_short[out_idx] = '\0';
    } else {
        g_room_short[0] = '\0';   /* will use "unassigned" */
    }

    /* MQTT broker URL */
    len = sizeof(g_mqtt_broker);
    if (nvs_get_str(h, SHE_NVS_KEY_MQTT_BROKER, g_mqtt_broker, &len) != ESP_OK) {
        strcpy(g_mqtt_broker, "mqtts://mqtt.she.et:8883");
    }

    nvs_close(h);

    /* MAC comes from the node (passed in) — normalized lowercase */
    if (g_node && g_node->mac) {
        /* Normalize: lowercase, strip colons */
        const char *src = g_node->mac;
        out_idx = 0;
        for (int i = 0; src[i] && out_idx < 12; i++) {
            if (src[i] != ':') {
                g_mac[out_idx++] = tolower(src[i]);
            }
        }
        g_mac[out_idx] = '\0';
    }

    ESP_LOGI(TAG, "Provisioning: tenant=%.8s home=%.8s room=%s mac=%s broker=%s",
             g_tenant_short, g_home_short,
             strlen(g_room_short) > 0 ? g_room_short : "unassigned",
             g_mac, g_mqtt_broker);

    return ESP_OK;
}

/* ---- Load device cert + key from fctry NVS partition ---- */
static esp_err_t load_device_cert(char **cert_pem, char **key_pem) {
    nvs_handle_t h;
    /* fctry partition — V3-FACTORY-OPS §3.2 */
    esp_err_t err = nvs_flash_init_partition("fctry");
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to init fctry partition: %s", esp_err_to_name(err));
        return err;
    }
    err = nvs_open_from_partition("fctry", SHE_FCTRY_NAMESPACE, NVS_READONLY, &h);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to open fctry namespace: %s", esp_err_to_name(err));
        return err;
    }

    /* Get cert size + read */
    size_t cert_len = 0;
    nvs_get_str(h, SHE_FCTRY_KEY_CERT, NULL, &cert_len);
    *cert_pem = malloc(cert_len);
    nvs_get_str(h, SHE_FCTRY_KEY_CERT, *cert_pem, &cert_len);

    /* Get key size + read */
    size_t key_len = 0;
    nvs_get_str(h, SHE_FCTRY_KEY_KEY, NULL, &key_len);
    *key_pem = malloc(key_len);
    nvs_get_str(h, SHE_FCTRY_KEY_KEY, *key_pem, &key_len);

    nvs_close(h);
    ESP_LOGI(TAG, "Loaded device cert (%d bytes) + key (%d bytes) from fctry NVS", cert_len, key_len);
    return ESP_OK;
}

/* ---- MQTT event handler ---- */
static void mqtt_event_handler(void *handler_args, esp_event_base_t base,
                                int32_t event_id, void *event_data) {
    esp_mqtt_event_handle_t event = event_data;

    switch ((esp_mqtt_event_id_t)event_id) {
    case MQTT_EVENT_CONNECTED: {
        g_mqtt_connected = true;
        ESP_LOGI(TAG, "MQTT connected — publishing status=online + config");
        mqtt_publish_status(true);
        if (g_node) mqtt_publish_config(g_node);

        /* Subscribe to she/.../{mac}/params/remote (commands) */
        char *params_remote_topic = mqtt_build_topic("params/remote");
        esp_mqtt_client_subscribe(mqtt_client, params_remote_topic, 1);
        ESP_LOGI(TAG, "Subscribed to %s", params_remote_topic);
        free(params_remote_topic);

        /* Subscribe to she/.../{mac}/ota/url (OTA trigger) */
        char *ota_url_topic = mqtt_build_topic("ota/url");
        esp_mqtt_client_subscribe(mqtt_client, ota_url_topic, 1);
        ESP_LOGI(TAG, "Subscribed to %s", ota_url_topic);
        free(ota_url_topic);

        /* Subscribe to she/.../{mac}/command (reboot, factory_reset, etc.) */
        char *command_topic = mqtt_build_topic("command");
        esp_mqtt_client_subscribe(mqtt_client, command_topic, 1);
        free(command_topic);
        break;
    }
    case MQTT_EVENT_DISCONNECTED:
        g_mqtt_connected = false;
        ESP_LOGW(TAG, "MQTT disconnected — LWT will fire on broker side");
        break;
    case MQTT_EVENT_DATA: {
        /* Received a message — parse topic + dispatch */
        ESP_LOGD(TAG, "MQTT msg: topic=%.*s payload=%.*s",
                 event->topic_len, event->topic,
                 event->data_len, event->data);

        /* Extract direction from topic (last segment after /mac/) */
        char topic[256];
        snprintf(topic, sizeof(topic), "%.*s", event->topic_len, event->topic);

        /* Find the direction segment */
        char *direction = NULL;
        char *p = topic;
        int slash_count = 0;
        while (*p) {
            if (*p == '/') slash_count++;
            if (slash_count == 5) {
                direction = p + 1;
                break;
            }
            p++;
        }
        if (!direction) break;

        if (strcmp(direction, "params/remote") == 0) {
            /* User command — toggle relay(s) */
            /* V3-MQTT-STANDARDS §3.4 payload: {"Relay 1":{"Power":true},"seq":12345,"ts":"..."} */
            /* TODO: parse JSON, find matching device, set relay state via relay_driver */
            ESP_LOGI(TAG, "Received params/remote command: %.*s", event->data_len, event->data);
            /* For Phase 1: log only — full handler in relay_driver integration */
        } else if (strcmp(direction, "ota/url") == 0) {
            /* OTA trigger — pass to ota_handler */
            /* V3-MQTT-STANDARDS §3.8 payload */
            ESP_LOGI(TAG, "Received ota/url — starting OTA");
            /* ota_handler_start(event->data, event->data_len); */
        } else if (strcmp(direction, "command") == 0) {
            /* System command (reboot, factory_reset, sync_time, ping) */
            ESP_LOGI(TAG, "Received command: %.*s", event->data_len, event->data);
            /* TODO: parse JSON cmd field + dispatch */
        }
        break;
    }
    case MQTT_EVENT_ERROR:
        ESP_LOGE(TAG, "MQTT error: type=%d", event->error_handle->error_type);
        break;
    default:
        break;
    }
}

/* ---- Start MQTT client ---- */
esp_err_t mqtt_client_start(she_node_t *node) {
    g_node = node;

    /* Load provisioning info from NVS */
    esp_err_t err = load_provisioning_info();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Device not provisioned — cannot start MQTT");
        return err;
    }

    /* Load device cert + key from fctry NVS */
    char *cert_pem = NULL, *key_pem = NULL;
    err = load_device_cert(&cert_pem, &key_pem);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to load device cert — factory provisioning incomplete");
        return err;
    }

    /* MQTT client config — V3-FIRMWARE §12.6 (nested esp-mqtt v5 API, IDF >= 5.0) */
    char *lwt_topic = mqtt_build_topic("status");
#if ESP_IDF_VERSION_MAJOR >= 5
    esp_mqtt_client_config_t mqtt_cfg = {
        .broker.address.uri = g_mqtt_broker,
        .broker.verification.certificate = ca_pem_start,
        .credentials.authentication.certificate = cert_pem,
        .credentials.authentication.key = key_pem,
        .credentials.client_id = g_mac,
        .session.keepalive = 30,
        .session.disable_clean_session = false,
        .session.last_will.topic = lwt_topic,
        .session.last_will.msg = "{\"status\":\"offline\"}",
        .session.last_will.qos = 1,
        .session.last_will.retain = 1,
        .task.priority = 5,
        .task.stack_size = 6144,
        .buffer.size = 4096,
    };
#else
    esp_mqtt_client_config_t mqtt_cfg = {
        .uri = g_mqtt_broker,
        .client_cert_pem = cert_pem,
        .client_key_pem = key_pem,
        .cert_pem = ca_pem_start,
        .client_id = g_mac,
        .keepalive = 30,
        .disable_clean_session = false,
        .task_stack = 6144,
        .buffer_size = 4096,
        .lwt_topic = lwt_topic,
        .lwt_msg = "{\"status\":\"offline\"}",
        .lwt_qos = 1,
        .lwt_retain = 1,
    };
#endif

    mqtt_client = esp_mqtt_client_init(&mqtt_cfg);
    if (!mqtt_client) {
        ESP_LOGE(TAG, "Failed to init MQTT client");
        free(cert_pem);
        free(key_pem);
        return ESP_FAIL;
    }

    esp_mqtt_client_register_event(mqtt_client, MQTT_EVENT_ANY, mqtt_event_handler, NULL);
    esp_mqtt_client_start(mqtt_client);

    /* Note: cert_pem + key_pem are now owned by the MQTT client — don't free yet */

    ESP_LOGI(TAG, "MQTT client started: broker=%s client_id=%s", g_mqtt_broker, g_mac);
    return ESP_OK;
}

esp_err_t mqtt_client_stop(void) {
    if (mqtt_client) {
        esp_mqtt_client_stop(mqtt_client);
        esp_mqtt_client_destroy(mqtt_client);
        mqtt_client = NULL;
        g_mqtt_connected = false;
    }
    return ESP_OK;
}

bool mqtt_client_is_connected(void) {
    return g_mqtt_connected;
}

/* ---- Publish helpers ---- */
esp_err_t mqtt_publish(const char *topic, const char *payload, int qos, bool retained) {
    if (!mqtt_client) return ESP_FAIL;
    int msg_id = esp_mqtt_client_publish(mqtt_client, topic, payload, strlen(payload), qos, retained ? 1 : 0);
    if (msg_id < 0) {
        ESP_LOGW(TAG, "Publish failed: topic=%s", topic);
        return ESP_FAIL;
    }
    return ESP_OK;
}

esp_err_t mqtt_publish_config(she_node_t *node) {
    char *topic = mqtt_build_topic("config");
    cJSON *config = profile_to_config_json(node);
    char *payload = cJSON_PrintUnformatted(config);

    esp_err_t err = mqtt_publish(topic, payload, 1, true);   /* QoS 1, retained */
    ESP_LOGI(TAG, "Published config to %s (%d bytes)", topic, (int)strlen(payload));

    free(topic);
    free(payload);
    cJSON_Delete(config);
    return err;
}

esp_err_t mqtt_publish_status(bool online) {
    char *topic = mqtt_build_topic("status");
    const char *payload = online ? "{\"status\":\"online\"}" : "{\"status\":\"offline\"}";
    esp_err_t err = mqtt_publish(topic, payload, 1, true);   /* QoS 1, retained */
    free(topic);
    return err;
}

esp_err_t mqtt_publish_params_local(she_node_t *node) {
    char *topic = mqtt_build_topic("params/local");

    /* Build payload: {"Relay 1":{"Power":true},"Relay 2":{"Power":false},...,"Diagnostics":{...}} */
    cJSON *root = cJSON_CreateObject();
    for (int i = 0; i < node->device_count; i++) {
        const node_device_t *d = &node->devices[i];
        cJSON *device_obj = cJSON_CreateObject();
        for (int j = 0; j < d->param_count; j++) {
            const node_param_t *p = &d->params[j];
            switch (p->data_type) {
                case DATA_BOOL:   cJSON_AddBoolToObject(device_obj, p->name, p->last_value.val.b); break;
                case DATA_INT:    cJSON_AddNumberToObject(device_obj, p->name, p->last_value.val.i); break;
                case DATA_FLOAT:  cJSON_AddNumberToObject(device_obj, p->name, p->last_value.val.f); break;
                case DATA_STRING: cJSON_AddStringToObject(device_obj, p->name, p->last_value.val.s ? p->last_value.val.s : ""); break;
            }
        }
        cJSON_AddItemToObject(root, d->name, device_obj);
    }
    char *payload = cJSON_PrintUnformatted(root);

    esp_err_t err = mqtt_publish(topic, payload, 0, false);   /* QoS 0, not retained */
    free(topic);
    free(payload);
    cJSON_Delete(root);
    return err;
}

esp_err_t mqtt_publish_energy(float voltage, float current, float power_w,
                              float energy_wh, float power_factor, float frequency) {
    char *topic = mqtt_build_topic("energy");
    /* V3-MQTT-STANDARDS §3.7 — short-form keys (v, i, p, wh, pf, freq) */
    char payload[256];
    snprintf(payload, sizeof(payload),
             "{\"v\":%.1f,\"i\":%.2f,\"p\":%.1f,\"wh\":%.2f,\"pf\":%.2f,\"freq\":%.1f,\"ts\":\"%ld\"}",
             voltage, current, power_w, energy_wh, power_factor, frequency, (long)time(NULL));

    esp_err_t err = mqtt_publish(topic, payload, 0, false);   /* QoS 0 */
    free(topic);
    return err;
}

esp_err_t mqtt_publish_ota_status(const char *status, const char *version, const char *error) {
    char *topic = mqtt_build_topic("ota/status");
    char payload[256];
    if (error) {
        snprintf(payload, sizeof(payload),
                 "{\"status\":\"%s\",\"version\":\"%s\",\"error\":\"%s\"}",
                 status, version ? version : "", error);
    } else {
        snprintf(payload, sizeof(payload),
                 "{\"status\":\"%s\",\"version\":\"%s\",\"error\":null}",
                 status, version ? version : "");
    }
    esp_err_t err = mqtt_publish(topic, payload, 1, false);   /* QoS 1 */
    free(topic);
    return err;
}

esp_err_t mqtt_publish_ota_progress(int percent, size_t bytes_done, size_t bytes_total) {
    char *topic = mqtt_build_topic("ota/progress");
    char payload[256];
    snprintf(payload, sizeof(payload),
             "{\"percent\":%d,\"bytes_done\":%zu,\"bytes_total\":%zu,\"ts\":\"%ld\"}",
             percent, bytes_done, bytes_total, (long)time(NULL));
    esp_err_t err = mqtt_publish(topic, payload, 0, false);   /* QoS 0 */
    free(topic);
    return err;
}
