/* =============================================================================
 * SHE V3 firmware — mqtt_client.c
 * =============================================================================
 * mTLS MQTT client using ESP-IDF mqtt_client component.
 * V3-FIRMWARE §12.6. V3-MQTT-STANDARDS §7. P1-10, P1-13.
 * ==========================================================================*/

#include "she_mqtt.h"
#include "nvs_keys.h"
#include "relay_driver.h"    /* relay_set()/relay_save_state() for params/remote commands */
#include "schedule_store.h"  /* device-local schedules (schedule_add/clear via cmd topic) */
#include "app_wifi.h"        /* app_wifi_disconnect_count() for the telemetry topic */
#include "ota_handler.h"     /* ota_handler_start() for the ota/url direction */
#include "system_service.h"  /* system_service_execute() for the command direction */
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_event.h"
#include "esp_heap_caps.h"   /* heap diagnostics for TLS handshake failures */
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

/* Cumulative broker disconnects since boot — reported as `mqtt_reconnects`. */
static uint32_t g_mqtt_reconnects = 0;

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

/* ---- Read a config string: runtime she_nvs first, fctry as fallback ----
 *
 * Factory reset wipes the whole default NVS partition, so she_nvs is not a safe
 * home for anything the device needs to come back online. Prefer the runtime copy
 * (it can be updated over the air) and fall back to the factory copy.
 */
static bool cfg_get_str(nvs_handle_t rt, nvs_handle_t fc, const char *key,
                        char *out, size_t out_size) {
    size_t len = out_size;
    if (rt && nvs_get_str(rt, key, out, &len) == ESP_OK) {
        return true;
    }
    if (fc) {
        len = out_size;
        if (nvs_get_str(fc, key, out, &len) == ESP_OK) {
            return true;
        }
    }
    return false;
}

/* ---- Load provisioning info from NVS ---- */
static esp_err_t load_provisioning_info(void) {
    nvs_handle_t h  = 0;   /* runtime she_nvs   — wiped by factory reset */
    nvs_handle_t fh = 0;   /* factory she_fctry — survives factory reset  */

    bool have_rt = (nvs_open(SHE_NVS_NAMESPACE, NVS_READONLY, &h) == ESP_OK);
    bool have_fc = (nvs_open_from_partition("fctry", SHE_FCTRY_NAMESPACE,
                                            NVS_READONLY, &fh) == ESP_OK);

    if (!have_rt) {
        /* Not fatal: the factory copy carries the connectivity config. */
        ESP_LOGW(TAG, "Namespace %s unavailable — using fctry fallback (%s)",
                 SHE_NVS_NAMESPACE, have_fc ? "found" : "MISSING");
    }
    if (!have_rt && !have_fc) {
        ESP_LOGE(TAG, "No provisioning config: could open neither %s nor fctry/%s",
                 SHE_NVS_NAMESPACE, SHE_FCTRY_NAMESPACE);
        return ESP_ERR_NOT_FOUND;
    }

    nvs_handle_t rt = have_rt ? h : 0;
    nvs_handle_t fc = have_fc ? fh : 0;

    /* Read tenant_id (UUID) — take first 8 chars as short form */
    char tenant_uuid[40] = {0};
    cfg_get_str(rt, fc, SHE_NVS_KEY_TENANT_ID, tenant_uuid, sizeof(tenant_uuid));
    /* Extract first 8 hex chars (no dashes) */
    int out_idx = 0;
    for (int i = 0; tenant_uuid[i] && out_idx < 8; i++) {
        if (tenant_uuid[i] != '-') {
            g_tenant_short[out_idx++] = tolower(tenant_uuid[i]);
        }
    }
    g_tenant_short[out_idx] = '\0';

    /* Home ID (may be empty) */
    char home_uuid[40] = {0};
    if (cfg_get_str(rt, fc, SHE_NVS_KEY_HOME_ID, home_uuid, sizeof(home_uuid))) {
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

    /* Room ID — runtime only; a reset legitimately clears room assignment */
    char room_uuid[40] = {0};
    size_t len = sizeof(room_uuid);
    if (have_rt && nvs_get_str(h, SHE_NVS_KEY_ROOM_ID, room_uuid, &len) == ESP_OK) {
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
    char broker[128] = {0};
    if (cfg_get_str(rt, fc, SHE_NVS_KEY_MQTT_BROKER, broker, sizeof(broker))) {
        strncpy(g_mqtt_broker, broker, sizeof(g_mqtt_broker) - 1);
        g_mqtt_broker[sizeof(g_mqtt_broker) - 1] = '\0';
    } else {
        strcpy(g_mqtt_broker, "mqtts://mqtt.she.et:8883");
    }

    if (have_rt) nvs_close(h);
    if (have_fc) nvs_close(fh);

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

/* ---- Handle params/remote (user command → relay hardware) ------------------
 *
 * V3-MQTT-STANDARDS §3.4 payload:
 *   {"Relay 1":{"Power":true},"seq":12345,"ts":"..."}
 *
 * Device names come from the node profile, and each node_device_t already
 * carries a `channel` that maps straight onto a PCF8574 pin — so no name
 * parsing is required. We only act on writable (PROP_WRITE) bool params, which
 * is exactly the relay "Power" parameter; read-only service params (Diagnostics
 * uptime/RSSI/heap) are skipped.
 *
 * After applying a change we persist it (survives reboot via relay_restore_state)
 * and republish params/local so the cloud and app reflect real hardware state
 * rather than optimistically echoing the command.
 * -------------------------------------------------------------------------- */
static void handle_params_remote(const char *data, size_t len) {
    if (!g_node) return;

    cJSON *root = cJSON_ParseWithLength(data, len);
    if (!root) {
        ESP_LOGE(TAG, "params/remote: malformed JSON payload");
        return;
    }

    bool changed = false;

    for (int i = 0; i < g_node->device_count; i++) {
        node_device_t *d = &g_node->devices[i];
        cJSON *dev_obj = cJSON_GetObjectItem(root, d->name);
        if (!dev_obj) {
            continue;
        }

        for (int j = 0; j < d->param_count; j++) {
            node_param_t *p = &d->params[j];

            /* Only writable params are commands; everything else is telemetry. */
            if (!(p->properties & PROP_WRITE)) {
                continue;
            }

            cJSON *v = cJSON_GetObjectItem(dev_obj, p->name);
            if (!v) {
                continue;
            }

            if (p->data_type == DATA_BOOL && cJSON_IsBool(v)) {
                const bool on = cJSON_IsTrue(v);
                p->last_value.type = DATA_BOOL;
                p->last_value.val.b = on;
                p->dirty = true;

                esp_err_t err = relay_set(d->channel, on);
                if (err != ESP_OK) {
                    ESP_LOGW(TAG, "relay_set(ch=%d, %s) failed: %s",
                             d->channel, on ? "ON" : "OFF", esp_err_to_name(err));
                } else {
                    ESP_LOGI(TAG, "%s (ch %d) -> %s",
                             d->name, d->channel, on ? "ON" : "OFF");
                }
                changed = true;
            }
        }
    }

    cJSON_Delete(root);

    if (changed) {
        relay_save_state();
        mqtt_publish_params_local(g_node);
    }
}

/* ---- Out-of-band system commands (V3-MQTT-STANDARDS §3.2) ----
 *
 * Payload: {"cmd":"reboot"|"factory_reset"|"sync_time"|"ping", "reason":"...", "seq":N, "ts":"..."}
 *
 * Flat JSON with seq/ts, matching the other server→device directions (ota/url, params/remote).
 * The spec names the topic and the four commands but does not fix a schema, so this is the
 * contract — if the backend's publisher changes shape, change both together.
 *
 * Note there is deliberately NO `reason`-less path to factory_reset: an unknown or malformed
 * `cmd` is logged and ignored rather than guessed at. Silently defaulting would turn a typo
 * into a wiped device.
 */
static void handle_command(const char *data, size_t len) {
    cJSON *root = cJSON_ParseWithLength(data, len);
    if (!root) {
        ESP_LOGE(TAG, "command: malformed JSON payload");
        return;
    }

    const cJSON *cmd = cJSON_GetObjectItem(root, "cmd");
    const cJSON *reason = cJSON_GetObjectItem(root, "reason");

    if (!cJSON_IsString(cmd)) {
        ESP_LOGE(TAG, "command: missing or non-string 'cmd' field");
        cJSON_Delete(root);
        return;
    }

    const char *reason_str = cJSON_IsString(reason) ? reason->valuestring : NULL;

    if (strcmp(cmd->valuestring, "reboot") == 0) {
        ESP_LOGW(TAG, "command: reboot requested (reason=%s)", reason_str ? reason_str : "none");
        system_service_execute(SHE_CMD_REBOOT, reason_str);      /* does not return */
    } else if (strcmp(cmd->valuestring, "factory_reset") == 0) {
        ESP_LOGW(TAG, "command: FACTORY RESET requested (reason=%s)",
                 reason_str ? reason_str : "none");
        system_service_execute(SHE_CMD_FACTORY_RESET, reason_str); /* does not return */
    } else if (strcmp(cmd->valuestring, "sync_time") == 0) {
        system_service_execute(SHE_CMD_SYNC_TIME, reason_str);
    } else if (strcmp(cmd->valuestring, "ping") == 0) {
        /* Answer with a status publish so the operator can confirm the device is
         * listening, rather than just trusting that the message arrived. */
        ESP_LOGI(TAG, "command: ping received — replying with status");
        system_service_execute(SHE_CMD_PING, reason_str);
        mqtt_publish_status(true);
    } else if (strcmp(cmd->valuestring, "schedule_add") == 0) {
        /* Device-local schedule — fires WITHOUT the cloud, after SNTP sets the clock.
         *
         *   {"cmd":"schedule_add","hour":20,"minute":0,"days_mask":127,
         *    "relay":0,"action":1}
         *
         * days_mask: bit0=Sun … bit6=Sat. 127 (0x7F) = EVERY DAY — the repeating
         * case. A subset repeats on those weekdays only. 0 = ONE-SHOT: fires once
         * then self-disables. action: 1=on, 0=off (defaults to on when absent).
         *
         * Deliberately strict: a missing/invalid hour or minute is rejected rather
         * than defaulted to 00:00, which would silently create a midnight schedule.
         */
        const cJSON *j_hour   = cJSON_GetObjectItem(root, "hour");
        const cJSON *j_min    = cJSON_GetObjectItem(root, "minute");
        const cJSON *j_mask   = cJSON_GetObjectItem(root, "days_mask");
        const cJSON *j_relay  = cJSON_GetObjectItem(root, "relay");
        const cJSON *j_action = cJSON_GetObjectItem(root, "action");

        if (!cJSON_IsNumber(j_hour) || !cJSON_IsNumber(j_min)) {
            ESP_LOGE(TAG, "command: schedule_add needs numeric 'hour' and 'minute'");
        } else {
            she_sched_t s;
            memset(&s, 0, sizeof(s));
            s.hour      = (uint8_t)j_hour->valuedouble;
            s.minute    = (uint8_t)j_min->valuedouble;
            s.days_mask = cJSON_IsNumber(j_mask) ? (uint8_t)j_mask->valuedouble
                                                 : SHE_SCHED_EVERY_DAY;
            s.relay     = cJSON_IsNumber(j_relay) ? (uint8_t)j_relay->valuedouble : 0;
            s.action    = (!cJSON_IsNumber(j_action) || j_action->valuedouble != 0)
                              ? SHE_SCHED_ACTION_ON : SHE_SCHED_ACTION_OFF;

            if (s.hour > 23 || s.minute > 59) {
                ESP_LOGE(TAG, "command: schedule_add out-of-range time %02u:%02u",
                         (unsigned)s.hour, (unsigned)s.minute);
            } else {
                int idx = -1;
                esp_err_t e = schedule_add(&s, &idx);
                ESP_LOGI(TAG,
                         "command: schedule_add -> %s (slot %d) %02u:%02u mask=0x%02X "
                         "relay=%u %s%s",
                         esp_err_to_name(e), idx, (unsigned)s.hour, (unsigned)s.minute,
                         s.days_mask, (unsigned)s.relay,
                         s.action == SHE_SCHED_ACTION_ON ? "ON" : "OFF",
                         s.days_mask == SHE_SCHED_ONE_SHOT ? " (one-shot)" : "");
                // Report the resulting state either way. A NO_MEM (list full) is
                // otherwise invisible from the server, which returns 200 regardless.
                mqtt_publish_schedules();
            }
        }
    } else if (strcmp(cmd->valuestring, "relay_test") == 0) {
        // Bench self-test: walk every channel ON/OFF one at a time, logging each
        // with its channel number and expander. Watch which relay actually clicks
        // — a mismatch means the channel map or an expander address is wrong.
        // Triggerable over MQTT because serial has not always been available.
        ESP_LOGW(TAG, "command: RELAY SELF-TEST requested (reason=%s)",
                 reason_str ? reason_str : "none");
        relay_selftest(400);
    } else if (strcmp(cmd->valuestring, "schedule_list") == 0) {
        // Diagnostic: report what the device actually holds.
        mqtt_publish_schedules();
    } else if (strcmp(cmd->valuestring, "schedule_clear") == 0) {
        ESP_LOGW(TAG, "command: clearing ALL device-local schedules (reason=%s)",
                 reason_str ? reason_str : "none");
        schedule_clear_all();
        mqtt_publish_schedules();
    } else {
        ESP_LOGW(TAG, "command: unknown cmd '%s' — ignored", cmd->valuestring);
    }

    cJSON_Delete(root);
}

/* ---- OTA task ----
 *
 * ota_handler_start() downloads ~1.5 MB, verifies the signature and reboots — minutes
 * of blocking work. Running it on the MQTT event-handler task would stall the very
 * connection used to report download progress, so it gets its own task. The payload is
 * heap-copied because the MQTT event buffer is only valid for the duration of the event.
 */
static void ota_task(void *arg) {
    char *payload = (char *)arg;
    if (payload) {
        ota_handler_start(payload, strlen(payload));
        free(payload);
    }
    vTaskDelete(NULL);
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
        /* Each drop is followed by a reconnect, so counting disconnects is a
         * faithful proxy for `mqtt_reconnects`. */
        g_mqtt_reconnects++;
        ESP_LOGW(TAG, "MQTT disconnected — LWT will fire on broker side (drops=%u)",
                 (unsigned)g_mqtt_reconnects);
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
            ESP_LOGI(TAG, "Received params/remote command: %.*s", event->data_len, event->data);
            handle_params_remote(event->data, event->data_len);
        } else if (strcmp(direction, "ota/url") == 0) {
            /* OTA trigger (V3-MQTT-STANDARDS §3.8). Dispatched to its own task — see
             * ota_task() above for why it must not run on the MQTT event task. */
            ESP_LOGI(TAG, "Received ota/url — dispatching OTA task");
            char *ota_payload = malloc(event->data_len + 1);
            if (ota_payload) {
                memcpy(ota_payload, event->data, event->data_len);
                ota_payload[event->data_len] = '\0';
                if (xTaskCreate(ota_task, "she_ota", 8192, ota_payload, 5, NULL) != pdPASS) {
                    ESP_LOGE(TAG, "Failed to create OTA task — OTA not started");
                    free(ota_payload);
                }
            } else {
                ESP_LOGE(TAG, "Failed to allocate OTA payload (%d bytes)", event->data_len);
            }
        } else if (strcmp(direction, "command") == 0) {
            /* Out-of-band system command — see handle_command(). Called inline rather
             * than in a task: reboot/factory_reset end in esp_restart(), and blocking
             * the MQTT task for their 1 s delay is irrelevant when the device is
             * about to reboot anyway. */
            handle_command(event->data, event->data_len);
        }
        break;
    }
    case MQTT_EVENT_ERROR:
        /* error_type 1 == MQTT_ERROR_TYPE_TCP_TRANSPORT, i.e. the TLS layer failed.
         * Report heap here too: MBEDTLS_ERR_SSL_INTERNAL_ERROR is what mbedtls
         * returns when an internal allocation fails, and without heap numbers a
         * memory problem is indistinguishable from a protocol problem. */
        ESP_LOGE(TAG, "MQTT error: type=%d heap_free=%u largest_block=%u",
                 event->error_handle->error_type,
                 (unsigned)esp_get_free_heap_size(),
                 (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT));
        if (event->error_handle->error_type == MQTT_ERROR_TYPE_TCP_TRANSPORT) {
            ESP_LOGE(TAG, "  transport: esp_tls_last_esp_err=0x%x tls_stack_err=0x%x sock_errno=%d",
                     event->error_handle->esp_tls_last_esp_err,
                     event->error_handle->esp_tls_stack_err,
                     event->error_handle->esp_transport_sock_errno);
        }
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

/**
 * Report the device-local schedule list over MQTT (diagnostic).
 *
 * Publishes what the device ACTUALLY holds, which is the only way to tell a
 * REJECTED schedule_add (list full / NVS failure) apart from a stored-but-not-
 * firing one. Both looked identical from the server: the API returns 200 either
 * way, because it only reports "published", never "stored".
 *
 *   {"count":1,"entries":[{"i":0,"h":6,"m":0,"mask":127,"relay":0,"act":1,"lf":29830512}]}
 */
esp_err_t mqtt_publish_schedules(void) {
    size_t count = 0;
    const she_sched_t *list = schedule_list(&count);

    cJSON *root = cJSON_CreateObject();
    cJSON_AddNumberToObject(root, "count", (double)count);
    cJSON *arr = cJSON_AddArrayToObject(root, "entries");
    for (size_t i = 0; i < count; i++) {
        const she_sched_t *s = &list[i];
        if (!s->enabled) continue;   /* only report live entries */
        cJSON *e = cJSON_CreateObject();
        cJSON_AddNumberToObject(e, "i", (double)i);
        cJSON_AddNumberToObject(e, "h", s->hour);
        cJSON_AddNumberToObject(e, "m", s->minute);
        cJSON_AddNumberToObject(e, "mask", s->days_mask);
        cJSON_AddNumberToObject(e, "relay", s->relay);
        cJSON_AddNumberToObject(e, "act", s->action);
        cJSON_AddNumberToObject(e, "lf", (double)s->last_fired_min);
        cJSON_AddItemToArray(arr, e);
    }

    char *payload = cJSON_PrintUnformatted(root);
    char *topic = mqtt_build_topic("schedules");
    esp_err_t err = mqtt_publish(topic, payload, 1, false);
    ESP_LOGI(TAG, "Published schedules: %s", payload);

    free(topic);
    free(payload);
    cJSON_Delete(root);
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

esp_err_t mqtt_publish_telemetry(int uptime_s, int rssi_dbm, uint32_t free_heap,
                                 uint32_t min_free_heap, const char *reset_reason) {
    char *topic = mqtt_build_topic("telemetry");

    /* V3-MQTT-STANDARDS §8.5 — FLAT diagnostics payload.
     *
     * The backend reads these keys directly (root.path("uptime_s") and friends).
     * Wrapping them in {ts, params:{...}} makes every field resolve to 0, and
     * handleTelemetry() then silently inserts nothing — no error, just an empty
     * device_telemetry table. Keep it flat.
     *
     * The payload's `ts` is advisory only: the backend stamps each row with its
     * own Instant.now(), so an unsynced device clock cannot corrupt the series. */
    char payload[320];
    snprintf(payload, sizeof(payload),
             "{\"uptime_s\":%d,\"rssi_dbm\":%d,\"free_heap_bytes\":%u,"
             "\"min_free_heap_bytes\":%u,\"wifi_disconnects\":%u,"
             "\"mqtt_reconnects\":%u,\"reset_reason\":\"%s\",\"ts\":%ld}",
             uptime_s, rssi_dbm,
             (unsigned)free_heap, (unsigned)min_free_heap,
             (unsigned)app_wifi_disconnect_count(), (unsigned)g_mqtt_reconnects,
             reset_reason ? reset_reason : "unknown", (long)time(NULL));

    esp_err_t err = mqtt_publish(topic, payload, 0, false);   /* QoS 0, not retained */
    free(topic);
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
