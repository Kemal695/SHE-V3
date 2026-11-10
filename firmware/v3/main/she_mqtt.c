/* =============================================================================
 * SHE V3 firmware — mqtt_client.c
 * =============================================================================
 * mTLS MQTT client using ESP-IDF mqtt_client component.
 * V3-FIRMWARE §12.6. V3-MQTT-STANDARDS §7. P1-10, P1-13.
 * ==========================================================================*/

#include "she_mqtt.h"
#include "nvs_keys.h"
#include "relay_driver.h"    /* relay_set()/relay_save_state() for params/remote commands */
#include "input_monitor.h"   /* absolute light set over a 2-way wall switch (SHE-R24) */
#include "sensors.h"         /* environmental readings folded into the telemetry payload */
#include "schedule_store.h"  /* device-local schedules (schedule_add/clear via cmd topic) */
#include "app_wifi.h"        /* app_wifi_disconnect_count() for the telemetry topic */
#include "ota_handler.h"     /* ota_handler_start() for the ota/url direction */
#include "system_service.h"  /* system_service_execute() for the command direction */
#include "net_discovery.h"   /* find the backend when the stored broker is gone */
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
#include <math.h>   /* isfinite() — a NaN sensor value is not valid JSON */
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
    *cert_pem = NULL;
    *key_pem  = NULL;

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

    /* Get cert size + read.
     *
     * Both nvs_get_str calls used to have their return value ignored. A blank
     * fctry partition therefore produced `cert_len = 0`, `malloc(0)` and a
     * cheerful "Loaded device cert (0 bytes) + key (0 bytes) from fctry NVS",
     * and the function still returned ESP_OK. The caller's
     * `if (err != ESP_OK) { ... factory provisioning incomplete }` guard could
     * never fire, so the device went on to build an mTLS client with NULL cert
     * material and failed much later with an opaque -0x2700 handshake error.
     * Report the missing key here, where the cause is still obvious. */
    size_t cert_len = 0;
    err = nvs_get_str(h, SHE_FCTRY_KEY_CERT, NULL, &cert_len);
    if (err != ESP_OK || cert_len == 0) {
        ESP_LOGE(TAG, "fctry NVS has no '%s' (%s) — this board carries no client identity",
                 SHE_FCTRY_KEY_CERT, esp_err_to_name(err));
        nvs_close(h);
        return ESP_ERR_NVS_NOT_FOUND;
    }
    *cert_pem = malloc(cert_len);
    if (!*cert_pem) {
        ESP_LOGE(TAG, "Out of memory for device cert (%u bytes)", (unsigned)cert_len);
        nvs_close(h);
        return ESP_ERR_NO_MEM;
    }
    err = nvs_get_str(h, SHE_FCTRY_KEY_CERT, *cert_pem, &cert_len);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to read '%s': %s", SHE_FCTRY_KEY_CERT, esp_err_to_name(err));
        free(*cert_pem);
        *cert_pem = NULL;
        nvs_close(h);
        return err;
    }

    /* Get key size + read */
    size_t key_len = 0;
    err = nvs_get_str(h, SHE_FCTRY_KEY_KEY, NULL, &key_len);
    if (err != ESP_OK || key_len == 0) {
        ESP_LOGE(TAG, "fctry NVS has no '%s' (%s) — cert present but the private key is not",
                 SHE_FCTRY_KEY_KEY, esp_err_to_name(err));
        free(*cert_pem);
        *cert_pem = NULL;
        nvs_close(h);
        return ESP_ERR_NVS_NOT_FOUND;
    }
    *key_pem = malloc(key_len);
    if (!*key_pem) {
        ESP_LOGE(TAG, "Out of memory for device key (%u bytes)", (unsigned)key_len);
        free(*cert_pem);
        *cert_pem = NULL;
        nvs_close(h);
        return ESP_ERR_NO_MEM;
    }
    err = nvs_get_str(h, SHE_FCTRY_KEY_KEY, *key_pem, &key_len);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to read '%s': %s", SHE_FCTRY_KEY_KEY, esp_err_to_name(err));
        free(*cert_pem);
        free(*key_pem);
        *cert_pem = NULL;
        *key_pem  = NULL;
        nvs_close(h);
        return err;
    }

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

#if defined(CONFIG_SHE_R24) && SHE_AC_FEEDBACK
                /* 2-way wall switch: the relay is a TOGGLE (lamp = wall XOR
                 * relay), so a blind relay_set() flips the lamp RELATIVE to the
                 * wall switch — that is why the app's "ON" could turn a lamp OFF
                 * after someone had used the wall switch. Make the write
                 * absolute by consulting the lamp-side AC feedback. */
                if (input_monitor_is_light_channel(d->channel)) {
                    input_monitor_set_light_absolute(d->channel, on);
                    changed = true;
                } else
#endif
                {
                    /* Sockets (no AC sense line): Power follows the relay command. */
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
    }

    cJSON_Delete(root);

    if (changed) {
        relay_save_state();
        mqtt_publish_params_local(g_node);
    }
}

/* ---- Update the cached params for a group mask ----------------------------
 *
 * group_set applies the mask to the HARDWARE but used to leave the profile's
 * params untouched — so the params/local publish that follows reported the OLD
 * values. For the LIGHTS that was masked by the AC feedback task, which syncs
 * them from the lamp; the SOCKETS have no sense line, so their stale value went
 * to the cloud and overwrote the correct state — which is why a master
 * Sockets/All press never moved the app's socket switches.
 *
 * Keyed off the CHANNEL (not the device name) so it tracks the relay map.
 * -------------------------------------------------------------------------- */
static void sync_group_params(she_node_t *node, uint32_t mask, bool on) {
    if (!node) return;
    for (int i = 0; i < node->device_count; i++) {
        node_device_t *d = &node->devices[i];
        if (!(mask & (1u << d->channel))) continue;
#if defined(CONFIG_SHE_R24) && SHE_AC_FEEDBACK
        /* Lights: Power is owned by the lamp-side AC feedback, not the group
         * command — do not stamp the commanded value onto their cached param. */
        if (input_monitor_is_light_channel(d->channel)) continue;
#endif
        for (int j = 0; j < d->param_count; j++) {
            node_param_t *p = &d->params[j];
            if (strcmp(p->name, "Power") != 0) continue;
            p->last_value.type = DATA_BOOL;
            p->last_value.val.b = on;
            p->dirty = true;
            ESP_LOGI(TAG, "group_set: %s cached -> %s", d->name, on ? "ON" : "OFF");
        }
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
    } else if (strcmp(cmd->valuestring, "group_set") == 0) {
        /* Master control — an intent over a GROUP of channels (ADR-015).
         *
         *   {"cmd":"group_set","group":"lights"|"sockets"|"all","on":true}
         *
         * This is what "Light Master" / "Socket Master" / "ALL OFF" resolve to.
         * It exists as its own command rather than a loop of per-channel writes
         * because it must be atomic: a client setting 24 channels one at a time
         * through params/remote takes 24 round trips and can be interrupted
         * halfway, leaving half a group energised.
         *
         * Deliberately NOT relay_set_all(): on this board the lights are
         * ch 0-7 + 16-23, with the sockets in between, so "all lights off"
         * implemented as "all relays off" would black out the sockets too.
         * relay_apply_group() is read-modify-write and cannot do that.
         *
         * An unknown group name is rejected rather than defaulted — guessing
         * here means energising circuits the operator did not ask for.
         */
        const cJSON *j_group = cJSON_GetObjectItem(root, "group");
        const cJSON *j_on    = cJSON_GetObjectItem(root, "on");

        if (!cJSON_IsString(j_group)) {
            ESP_LOGE(TAG, "command: group_set needs a string 'group' "
                          "(lights|sockets|all)");
        } else if (!cJSON_IsBool(j_on)) {
            ESP_LOGE(TAG, "command: group_set needs a boolean 'on'");
        } else {
            uint32_t mask = 0;
            const char *g = j_group->valuestring;
            if (strcmp(g, "lights") == 0)       mask = RELAY_GROUP_LIGHTS_R24;
            else if (strcmp(g, "sockets") == 0) mask = RELAY_GROUP_SOCKETS_R24;
            else if (strcmp(g, "all") == 0)     mask = RELAY_GROUP_ALL_R24;

            if (mask == 0) {
                ESP_LOGE(TAG, "command: group_set unknown group '%s' — ignored "
                              "(expected lights|sockets|all)", g);
            } else {
                const bool on = cJSON_IsTrue(j_on);
                ESP_LOGW(TAG, "command: group_set %s -> %s (reason=%s)",
                         g, on ? "ON" : "OFF", reason_str ? reason_str : "none");
#if defined(CONFIG_SHE_R24) && SHE_AC_FEEDBACK
                /* 2-way wall switches: relay_apply_group() sets the RELAY
                 * positions, which flips each lamp RELATIVE to its wall switch —
                 * the same trap the per-device write had, and the reason a master
                 * "lights off" left lamps on. Derive the target relay mask from
                 * the lamp-side AC feedback and apply it in ONE atomic write. */
                input_monitor_set_group_absolute(mask, on);
#else
                relay_apply_group(mask, on);
#endif
                relay_save_state();
                /* Cache the new state BEFORE publishing: without this the
                 * params/local below reports the pre-command values, and the
                 * sockets (no feedback to correct them) would stay stale in the
                 * cloud and in the app. */
                sync_group_params(g_node, mask, on);
                /* Report the resulting mask so the client can confirm the whole
                 * group moved and not just its first channel. */
                mqtt_publish_status(true);
                /* ALSO republish params/local.
                 *
                 * publish_status() carries node presence only — NOT per-param
                 * values — so without this the cloud's cached Power values stayed
                 * stale after a master-control press: the device applied the group
                 * but never told anyone the new per-channel state, and every app
                 * switch failed to follow. params/remote (scenes, individual
                 * toggles) already republishes params/local; group_set was the one
                 * path that did not, which is why scenes updated the app and the
                 * master buttons did not. */
                mqtt_publish_params_local(g_node);
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

/* ---- Inbound dispatch ----------------------------------------------------
 *
 * Split out of MQTT_EVENT_DATA so it can be called either for a whole message
 * or, once reassembled, for one that arrived in fragments.
 */
static void dispatch_incoming(const char *topic_buf, int topic_len,
                              const char *data, int data_len) {
    /* Extract the direction segment — the 6th path element, i.e. what follows
     * she/{tenant}/{home}/{room}/{mac}/ */
    char topic[256];
    snprintf(topic, sizeof(topic), "%.*s", topic_len, topic_buf);

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
    if (!direction) {
        ESP_LOGW(TAG, "Inbound topic has no direction segment: %s", topic);
        return;
    }

    if (strcmp(direction, "params/remote") == 0) {
        /* User command — toggle relay(s).
         * V3-MQTT-STANDARDS §3.4 payload: {"Relay 1":{"Power":true},"seq":12345,"ts":"..."} */
        ESP_LOGI(TAG, "Received params/remote command (%d bytes)", data_len);
        handle_params_remote(data, data_len);
    } else if (strcmp(direction, "ota/url") == 0) {
        /* OTA trigger (V3-MQTT-STANDARDS §3.8). Dispatched to its own task — see
         * ota_task() above for why it must not run on the MQTT event task. */
        ESP_LOGI(TAG, "Received ota/url — dispatching OTA task");
        char *ota_payload = malloc(data_len + 1);
        if (ota_payload) {
            memcpy(ota_payload, data, data_len);
            ota_payload[data_len] = '\0';
            if (xTaskCreate(ota_task, "she_ota", 8192, ota_payload, 5, NULL) != pdPASS) {
                ESP_LOGE(TAG, "Failed to create OTA task — OTA not started");
                free(ota_payload);
            }
        } else {
            ESP_LOGE(TAG, "Failed to allocate OTA payload (%d bytes)", data_len);
        }
    } else if (strcmp(direction, "command") == 0) {
        /* Out-of-band system command — see handle_command(). Called inline rather
         * than in a task: reboot/factory_reset end in esp_restart(), and blocking
         * the MQTT task for their 1 s delay is irrelevant when the device is
         * about to reboot anyway. */
        handle_command(data, data_len);
    } else {
        ESP_LOGD(TAG, "Inbound direction '%s' ignored", direction);
    }
}

/* ---- Large-message reassembly --------------------------------------------
 *
 * esp-mqtt SPLITS an inbound PUBLISH whose total length exceeds the client
 * buffer (mqtt_client.c:1179-1215): it reads the fixed header + topic, then
 * hands the payload over as SEVERAL MQTT_EVENT_DATA events, each carrying its
 * own current_data_offset / total_data_len. mqtt_client.h says so outright:
 * "Multiple MQTT_EVENT_DATA could be fired for one message".
 *
 * `buffer.size` is 4096 here, so any inbound message larger than that arrives
 * split. This handler used to ignore both fields and run every fragment through
 * cJSON as though it were a complete message — a truncated payload fails to
 * parse at best, and at worst a fragment that happens to be valid JSON is
 * applied as a whole command. Reassemble first, dispatch exactly once.
 */
static char  *s_rx_buf   = NULL;   /* reassembly buffer, owned here */
static size_t s_rx_cap   = 0;      /* allocated capacity (bytes incl. NUL) */
static size_t s_rx_total = 0;      /* total_data_len of the message in flight */

static void rx_reassembly_reset(void) {
    free(s_rx_buf);
    s_rx_buf   = NULL;
    s_rx_cap   = 0;
    s_rx_total = 0;
}

/* ---- MQTT event handler ---- */
static void mqtt_event_handler(void *handler_args, esp_event_base_t base,
                                int32_t event_id, void *event_data) {
    esp_mqtt_event_handle_t event = event_data;

    switch ((esp_mqtt_event_id_t)event_id) {
    case MQTT_EVENT_CONNECTED: {
        g_mqtt_connected = true;
        rx_reassembly_reset();   /* a new session cannot continue an old message */
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
        rx_reassembly_reset();   /* the rest of a split message will never arrive */
        /* Each drop is followed by a reconnect, so counting disconnects is a
         * faithful proxy for `mqtt_reconnects`. */
        g_mqtt_reconnects++;
        ESP_LOGW(TAG, "MQTT disconnected — LWT will fire on broker side (drops=%u)",
                 (unsigned)g_mqtt_reconnects);
        break;
    case MQTT_EVENT_DATA: {
        const int total  = event->total_data_len;
        const int offset = event->current_data_offset;

        ESP_LOGD(TAG, "MQTT msg: topic=%.*s payload=%.*s (%d/%d @%d)",
                 event->topic_len, event->topic,
                 event->data_len, event->data,
                 event->data_len, total, offset);

        if (total > 0 && event->data_len < total) {
            /* Fragmented — accumulate and dispatch only on the last piece. */
            if (offset == 0) {
                rx_reassembly_reset();
                s_rx_cap = (size_t)total + 1;      /* room for the NUL */
                s_rx_buf = malloc(s_rx_cap);
                if (!s_rx_buf) {
                    ESP_LOGE(TAG, "No memory to reassemble a %d-byte message — dropping", total);
                    s_rx_cap = s_rx_total = 0;
                    break;
                }
                s_rx_total = (size_t)total;
            }

            if (!s_rx_buf || s_rx_total != (size_t)total ||
                (size_t)offset + (size_t)event->data_len > s_rx_cap - 1) {
                ESP_LOGW(TAG, "Reassembly out of step (offset=%d len=%d total=%d) — resetting",
                         offset, event->data_len, total);
                rx_reassembly_reset();
                break;
            }

            memcpy(s_rx_buf + offset, event->data, event->data_len);
            size_t got = (size_t)offset + (size_t)event->data_len;
            if (got < s_rx_total) {
                ESP_LOGD(TAG, "Reassembling: %u/%u bytes",
                         (unsigned)got, (unsigned)s_rx_total);
                break;                              /* more fragments to come */
            }

            s_rx_buf[got] = '\0';
            ESP_LOGI(TAG, "Reassembled a %u-byte message from fragments", (unsigned)got);
            dispatch_incoming(event->topic, event->topic_len, s_rx_buf, (int)got);
            rx_reassembly_reset();
            break;
        }

        /* Whole message in a single event — the normal path. Drop any half-built
         * message first: a truncated one can only be stale by now. */
        rx_reassembly_reset();
        dispatch_incoming(event->topic, event->topic_len, event->data, event->data_len);
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

/* ---- Broker self-healing ----
 *
 * The broker address lives in `fctry`, written once when the board was made,
 * and provisioning never touched it. That is fine until the network changes:
 * the board then joins the new Wi-Fi and dials a host that no longer exists,
 * forever, with no visible symptom other than never appearing in the app.
 *
 * So before the client is created, check the address we are about to use. If
 * nothing is listening there, look for the backend on this LAN and adopt what
 * we find. The result is written to the RUNTIME nvs namespace, which
 * cfg_get_str() consults before fctry — so it survives reboots, and a factory
 * reset simply drops back to the factory value.
 */

/* "mqtts://192.168.1.21:8883" -> host + port. Defaults by scheme. */
static bool broker_parse(const char *uri, char *host, size_t host_len, uint16_t *port)
{
    if (uri == NULL || host == NULL || port == NULL) return false;

    *port = (strncmp(uri, "mqtts", 5) == 0) ? 8883 : 1883;

    const char *p = strstr(uri, "://");
    p = (p != NULL) ? p + 3 : uri;

    const char *end = strchr(p, '/');           /* optional path */
    if (end == NULL) end = p + strlen(p);

    const char *colon = memchr(p, ':', (size_t)(end - p));
    size_t hlen = (colon != NULL) ? (size_t)(colon - p) : (size_t)(end - p);
    if (hlen == 0 || hlen >= host_len) return false;

    memcpy(host, p, hlen);
    host[hlen] = '\0';

    if (colon != NULL) {
        long v = strtol(colon + 1, NULL, 10);
        if (v > 0 && v < 65536) *port = (uint16_t)v;
    }
    return true;
}

static void broker_refresh_if_unreachable(void)
{
    char host[64];
    uint16_t port = 8883;
    if (!broker_parse(g_mqtt_broker, host, sizeof(host), &port)) return;

    if (net_discovery_probe_host(host, port, 1500)) {
        return;                                 /* configured broker is alive */
    }

    ESP_LOGW(TAG, "Broker %s:%u is unreachable — searching this LAN for the backend",
             host, (unsigned)port);

    char found[32];
    if (net_discovery_find_backend(found, sizeof(found), NET_DISCOVERY_API_PORT) != ESP_OK) {
        ESP_LOGW(TAG, "Discovery found nothing — keeping %s", g_mqtt_broker);
        return;
    }

    char new_broker[128];
    snprintf(new_broker, sizeof(new_broker), "mqtts://%s:8883", found);

    ESP_LOGW(TAG, "Adopting discovered backend: %s -> %s", g_mqtt_broker, new_broker);
    strncpy(g_mqtt_broker, new_broker, sizeof(g_mqtt_broker) - 1);
    g_mqtt_broker[sizeof(g_mqtt_broker) - 1] = '\0';

    char api[128];
    snprintf(api, sizeof(api), "http://%s:%u", found, (unsigned)NET_DISCOVERY_API_PORT);

    nvs_handle_t h;
    if (nvs_open(SHE_NVS_NAMESPACE, NVS_READWRITE, &h) == ESP_OK) {
        nvs_set_str(h, SHE_NVS_KEY_MQTT_BROKER, g_mqtt_broker);
        nvs_set_str(h, SHE_NVS_KEY_API_BASE_URL, api);
        nvs_commit(h);
        nvs_close(h);
        ESP_LOGI(TAG, "Saved broker + api_base (%s) to NVS — this sticks across reboots", api);
    } else {
        ESP_LOGW(TAG, "Could not persist the new broker — correct for this boot only");
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

    /* Network may have moved since this address was written. */
    broker_refresh_if_unreachable();

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

    /* Presence heartbeat. The one-shot retained status published on connect can
     * be missed by the backend (shared subscription + retained = unreliable), so
     * re-publish periodically instead. The task no-ops until we're connected. */
    mqtt_start_status_heartbeat();

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

/* ---- Presence heartbeat --------------------------------------------------
 *
 * Status used to be published ONCE on connect, retained. That is not enough:
 * the backend subscribes through a SHARED subscription
 * ($share/she-backend/she/+/+/+/+/status), and retained messages are not
 * reliably delivered to shared-subscription members. So a device that booted
 * before the backend subscribed stays grey in the app indefinitely — it is
 * connected and talking, but the server never learned it was online.
 *
 * Re-publishing on a timer makes presence self-healing: whatever the
 * subscribe order, the backend hears from the device within one interval.
 */
#define STATUS_HEARTBEAT_S  60

static void status_heartbeat_task(void *arg)
{
    (void)arg;
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(STATUS_HEARTBEAT_S * 1000));
        if (!g_mqtt_connected) continue;        /* don't publish while offline */
        if (mqtt_publish_status(true) != ESP_OK) {
            ESP_LOGW(TAG, "status heartbeat publish failed");
        }
    }
}

void mqtt_start_status_heartbeat(void)
{
    static bool started = false;
    if (started) return;
    if (xTaskCreate(status_heartbeat_task, "she_status_hb", 3072, NULL, 4, NULL) == pdPASS) {
        started = true;
        ESP_LOGI(TAG, "status heartbeat every %ds", STATUS_HEARTBEAT_S);
    } else {
        ESP_LOGW(TAG, "could not start status heartbeat task");
    }
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

        /* ⚠ The Local Control service is deliberately NOT echoed here.
         *
         * Its only real content is the POP — this board's LAN credential — which
         * is published ONCE in the retained `config` payload so the mobile app
         * can arm local control without prompting the user (the ESP RainMaker
         * behaviour). params/local is QoS 0, is republished every 60 s, and is
         * fanned out to every connected client through the backend's WebSocket,
         * so echoing it here would turn a one-time disclosure into a continuous
         * broadcast of a device credential. `Type` is static too, so the whole
         * device is skipped rather than filtered param by param. */
        if (strcmp(d->type, "esp.service.local_control") == 0) continue;

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
                                 uint32_t min_free_heap, const char *reset_reason,
                                 const sensor_sample_t *sensors) {
    char *topic = mqtt_build_topic("telemetry");

    /* V3-MQTT-STANDARDS §8.5 — FLAT diagnostics payload.
     *
     * The backend reads these keys directly (root.path("uptime_s") and friends).
     * Wrapping them in {ts, params:{...}} makes every field resolve to 0, and
     * handleTelemetry() then silently inserts nothing — no error, just an empty
     * device_telemetry table. Keep it flat.
     *
     * The payload's `ts` is advisory only: the backend stamps each row with its
     * own Instant.now(), so an unsynced device clock cannot corrupt the series.
     *
     * ---- Why this is assembled in pieces -----------------------------------
     * The sensor block is optional (a board with no DHT must not publish a
     * temperature of 0.0 — that is a plausible reading and would look real on
     * the chart). So the base is written first and the sensor fields are
     * appended only when they are actually valid.
     *
     * ⚠ The buffer is 768, not the original 320. The old size was already only
     * just enough for the diagnostics block, and snprintf SILENTLY TRUNCATES —
     * which here would emit malformed JSON that the backend drops without a
     * word, the same failure mode as the {ts, params} wrapper above. The
     * offset tracking below turns any truncation into a loud ESP_LOGE instead. */
    char payload[768];
    int off = snprintf(payload, sizeof(payload),
                       "{\"uptime_s\":%d,\"rssi_dbm\":%d,\"free_heap_bytes\":%u,"
                       "\"min_free_heap_bytes\":%u,\"wifi_disconnects\":%u,"
                       "\"mqtt_reconnects\":%u,\"reset_reason\":\"%s\",\"ts\":%ld",
                       uptime_s, rssi_dbm,
                       (unsigned)free_heap, (unsigned)min_free_heap,
                       (unsigned)app_wifi_disconnect_count(), (unsigned)g_mqtt_reconnects,
                       reset_reason ? reset_reason : "unknown", (long)time(NULL));
    if (off < 0 || off >= (int)sizeof(payload)) {
        ESP_LOGE(TAG, "Telemetry payload overflow while writing the diagnostics block");
        free(topic);
        return ESP_FAIL;
    }

    if (sensors) {
        /* isfinite() on every float: a NaN or inf would serialise as `nan`/`inf`,
         * which is NOT valid JSON and makes the whole message unparseable — one
         * bad sensor reading would take the entire telemetry row set down with
         * it, not just its own field. */
        if (sensors->dht_valid &&
            isfinite(sensors->temperature_c) && isfinite(sensors->humidity_pct)) {
            const int n = snprintf(payload + off, sizeof(payload) - (size_t)off,
                                   ",\"temp_c\":%.1f,\"humidity_pct\":%.1f",
                                   (double)sensors->temperature_c,
                                   (double)sensors->humidity_pct);
            if (n < 0 || n >= (int)(sizeof(payload) - (size_t)off)) {
                ESP_LOGE(TAG, "Telemetry payload overflow at the climate block");
                free(topic);
                return ESP_FAIL;
            }
            off += n;
        }
        if (sensors->soil_valid) {
            const int n = snprintf(payload + off, sizeof(payload) - (size_t)off,
                                   ",\"soil_pct\":%d", sensors->soil_pct);
            if (n < 0 || n >= (int)(sizeof(payload) - (size_t)off)) {
                ESP_LOGE(TAG, "Telemetry payload overflow at the soil block");
                free(topic);
                return ESP_FAIL;
            }
            off += n;
        }
        if (sensors->air_valid &&
            isfinite(sensors->co_ppm) && isfinite(sensors->alcohol_ppm) &&
            isfinite(sensors->co2_ppm)) {
            const int n = snprintf(payload + off, sizeof(payload) - (size_t)off,
                                   ",\"co_ppm\":%.1f,\"alcohol_ppm\":%.1f,\"co2_ppm\":%.1f",
                                   (double)sensors->co_ppm,
                                   (double)sensors->alcohol_ppm,
                                   (double)sensors->co2_ppm);
            if (n < 0 || n >= (int)(sizeof(payload) - (size_t)off)) {
                ESP_LOGE(TAG, "Telemetry payload overflow at the air-quality block");
                free(topic);
                return ESP_FAIL;
            }
            off += n;
        }
    }

    /* The closing brace AND its terminator need two bytes, but each guard above
     * only reserves one: it accepts a block that lands exactly on the last valid
     * index (n <= 767 - off), leaving `off == 767`. Writing '}' at 767 then '\0'
     * at 768 would step one byte past this array. Check, do not trust the
     * arithmetic. (Unreachable at the current payload size, but the whole point
     * of this block is to make truncation loud rather than silent.) */
    if (off > (int)sizeof(payload) - 2) {
        ESP_LOGE(TAG, "Telemetry payload full before the closing brace");
        free(topic);
        return ESP_FAIL;
    }
    payload[off++] = '}';
    payload[off]   = '\0';

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
