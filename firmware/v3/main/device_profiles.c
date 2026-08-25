/* =============================================================================
 * SHE V3 firmware — device_profiles.c
 * =============================================================================
 * RainMaker hierarchy profile builders for SHE-R4, SHE-R8, SHE-R16.
 * V3-DEVICE-MODEL §1-5. V3-FIRMWARE §11. ADR-011, ADR-012.
 * ==========================================================================*/

#include "device_profiles.h"
#include "nvs_keys.h"
#include "esp_log.h"
#include "nvs_flash.h"
#include <string.h>
#include <stdlib.h>

static const char *TAG = "device_profiles";

/* ---- Relay names (V3-DEVICE-MODEL §1.3) ---- */
static const char *relay_names_r4[]  = {"Relay 1", "Relay 2", "Relay 3", "Relay 4"};
static const char *relay_names_r8[]  = {"Relay 1", "Relay 2", "Relay 3", "Relay 4",
                                        "Relay 5", "Relay 6", "Relay 7", "Relay 8"};
static const char *relay_names_r16[] = {"Relay 1", "Relay 2", "Relay 3", "Relay 4",
                                        "Relay 5", "Relay 6", "Relay 7", "Relay 8",
                                        "Relay 9", "Relay 10", "Relay 11", "Relay 12",
                                        "Relay 13", "Relay 14", "Relay 15", "Relay 16"};

/* ---- Param value helpers ---- */
param_value_t param_bool(bool v)   { param_value_t p = {.type = DATA_BOOL,  .val.b = v}; return p; }
param_value_t param_int(int v)     { param_value_t p = {.type = DATA_INT,   .val.i = v}; return p; }
param_value_t param_float(float v) { param_value_t p = {.type = DATA_FLOAT, .val.f = v}; return p; }
param_value_t param_string(const char *v) {
    param_value_t p = {.type = DATA_STRING, .val.s = (char *)v};
    return p;
}

/* ---- Build OTA service device (esp.service.ota) ---- */
static node_device_t build_ota_service(void) {
    static node_param_t ota_params[3];
    ota_params[0] = (node_param_t){
        .name = "URL", .type = "esp.param.ota_url", .data_type = DATA_STRING,
        .properties = PROP_WRITE,
    };
    ota_params[1] = (node_param_t){
        .name = "Status", .type = "esp.param.ota_status", .data_type = DATA_STRING,
        .properties = PROP_READ,
    };
    ota_params[2] = (node_param_t){
        .name = "Progress", .type = "esp.param.ota_progress", .data_type = DATA_INT,
        .properties = PROP_READ, .min_val = 0, .max_val = 100,
    };
    return (node_device_t){
        .name = "OTA", .type = "esp.service.ota", .channel = 0,
        .params = ota_params, .param_count = 3,
        .attributes = cJSON_CreateObject(),
    };
}

/* ---- Build Diagnostics service device (esp.service.diag) ---- */
static node_device_t build_diagnostics_service(void) {
    static node_param_t diag_params[4];
    diag_params[0] = (node_param_t){
        .name = "Uptime", .type = "esp.param.uptime", .data_type = DATA_INT,
        .properties = PROP_READ | PROP_TIME_SERIES,
    };
    diag_params[1] = (node_param_t){
        .name = "RSSI", .type = "esp.param.rssi", .data_type = DATA_INT,
        .properties = PROP_READ | PROP_TIME_SERIES,
    };
    diag_params[2] = (node_param_t){
        .name = "Free_Heap", .type = "esp.param.free_heap", .data_type = DATA_INT,
        .properties = PROP_READ | PROP_TIME_SERIES,
    };
    diag_params[3] = (node_param_t){
        .name = "Reset_Reason", .type = "esp.param.reset_reason", .data_type = DATA_STRING,
        .properties = PROP_READ,
    };
    return (node_device_t){
        .name = "Diagnostics", .type = "esp.service.diag", .channel = 0,
        .params = diag_params, .param_count = 4,
        .attributes = cJSON_CreateObject(),
    };
}

/* ---- Build a single relay device (esp.device.switch with Power param) ---- */
static node_device_t build_relay_device(const char *name, uint8_t channel) {
    node_param_t *params = calloc(1, sizeof(node_param_t));
    params[0] = (node_param_t){
        .name = "Power", .type = "esp.param.power", .data_type = DATA_BOOL,
        .properties = PROP_READ | PROP_WRITE | PROP_PERSIST,
        .last_value = param_bool(false),
    };
    cJSON *attrs = cJSON_CreateObject();
    cJSON_AddStringToObject(attrs, "Label", name);
    cJSON_AddNumberToObject(attrs, "Channel", channel);
    return (node_device_t){
        .name = name, .type = "esp.device.switch", .channel = channel,
        .params = params, .param_count = 1, .attributes = attrs,
    };
}

/* =============================================================================
 * Profile builders
 * ==========================================================================*/

she_node_t* profile_build_r4(void) {
    static node_device_t devices[6];   /* 4 relays + OTA + Diagnostics */
    static node_param_t relay_params[4];

    for (int i = 0; i < 4; i++) {
        relay_params[i] = (node_param_t){
            .name = "Power", .type = "esp.param.power", .data_type = DATA_BOOL,
            .properties = PROP_READ | PROP_WRITE | PROP_PERSIST,
            .last_value = param_bool(false),
        };
        devices[i] = build_relay_device(relay_names_r4[i], i);
    }
    devices[4] = build_ota_service();
    devices[5] = build_diagnostics_service();

    static she_node_t node = {
        .node_id = "SHE-R4-PLACEHOLDER",
        .mac = "00:00:00:00:00:00",
        .sku = "SHE-R4",
        .firmware = "3.0.0",
        .hw_rev = "rev-c",
        .secure_version = 1,
        .devices = devices,
        .device_count = 6,
    };
    return &node;
}

she_node_t* profile_build_r8(void) {
    static node_device_t devices[10];   /* 8 relays + OTA + Diagnostics */

    for (int i = 0; i < 8; i++) {
        devices[i] = build_relay_device(relay_names_r8[i], i);
    }
    devices[8] = build_ota_service();
    devices[9] = build_diagnostics_service();

    static she_node_t node = {
        .node_id = "SHE-R8-PLACEHOLDER",
        .mac = "00:00:00:00:00:00",
        .sku = "SHE-R8",
        .firmware = "3.0.0",
        .hw_rev = "rev-c",
        .secure_version = 1,
        .devices = devices,
        .device_count = 10,
    };
    return &node;
}

she_node_t* profile_build_r16(void) {
    static node_device_t devices[19];   /* 16 relays + OTA + Diagnostics + Voice */

    for (int i = 0; i < 16; i++) {
        devices[i] = build_relay_device(relay_names_r16[i], i);
    }
    devices[16] = build_ota_service();
    devices[17] = build_diagnostics_service();

    /* Voice service (R16 only) — V3-DEVICE-MODEL §1.4 + V3-FIRMWARE §10 */
    static node_param_t voice_params[3];
    voice_params[0] = (node_param_t){
        .name = "Wake Word Active", .type = "esp.param.wake_word", .data_type = DATA_BOOL,
        .properties = PROP_READ,
    };
    voice_params[1] = (node_param_t){
        .name = "Last Intent", .type = "esp.param.intent", .data_type = DATA_STRING,
        .properties = PROP_READ,
    };
    voice_params[2] = (node_param_t){
        .name = "Last Confidence", .type = "esp.param.confidence", .data_type = DATA_FLOAT,
        .properties = PROP_READ, .min_val = 0.0, .max_val = 1.0,
    };
    devices[18] = (node_device_t){
        .name = "Voice", .type = "esp.service.voice", .channel = 0,
        .params = voice_params, .param_count = 3,
        .attributes = cJSON_CreateObject(),
    };

    static she_node_t node = {
        .node_id = "SHE-R16-PLACEHOLDER",
        .mac = "00:00:00:00:00:00",
        .sku = "SHE-R16",
        .firmware = "3.0.0",
        .hw_rev = "rev-c",
        .secure_version = 1,
        .devices = devices,
        .device_count = 19,
    };
    return &node;
}

she_node_t* profile_build_for_sku(const char *sku) {
    if (strcmp(sku, "SHE-R4") == 0)  return profile_build_r4();
    if (strcmp(sku, "SHE-R8") == 0)  return profile_build_r8();
    if (strcmp(sku, "SHE-R16") == 0) return profile_build_r16();
    ESP_LOGE(TAG, "Unknown SKU: %s", sku);
    return NULL;
}

/* =============================================================================
 * Serialize node to JSON for MQTT config topic
 * V3-MQTT-STANDARDS §3.1 — config payload format.
 * ==========================================================================*/
cJSON* profile_to_config_json(const she_node_t *node) {
    cJSON *root = cJSON_CreateObject();
    cJSON_AddStringToObject(root, "node_id", node->node_id);
    cJSON_AddStringToObject(root, "mac", node->mac);
    cJSON_AddStringToObject(root, "model", node->sku);
    cJSON_AddStringToObject(root, "hw_rev", node->hw_rev);

    cJSON *firmware = cJSON_CreateObject();
    cJSON_AddStringToObject(firmware, "version", node->firmware);
    cJSON_AddNumberToObject(firmware, "secure_version", node->secure_version);
    cJSON_AddStringToObject(firmware, "compiled_at", __DATE__ " " __TIME__);
    cJSON_AddItemToObject(root, "firmware", firmware);

    /* Devices array (esp.device.*) */
    cJSON *devices_arr = cJSON_CreateArray();
    cJSON *services_arr = cJSON_CreateArray();

    for (int i = 0; i < node->device_count; i++) {
        const node_device_t *d = &node->devices[i];
        cJSON *dev_obj = cJSON_CreateObject();
        cJSON_AddStringToObject(dev_obj, "name", d->name);
        cJSON_AddStringToObject(dev_obj, "type", d->type);

        cJSON *params_arr = cJSON_CreateArray();
        for (int j = 0; j < d->param_count; j++) {
            const node_param_t *p = &d->params[j];
            cJSON *param_obj = cJSON_CreateObject();
            cJSON_AddStringToObject(param_obj, "name", p->name);
            cJSON_AddStringToObject(param_obj, "type", p->type);

            const char *dt = "string";
            switch (p->data_type) {
                case DATA_BOOL:   dt = "bool";   break;
                case DATA_INT:    dt = "int";    break;
                case DATA_FLOAT:  dt = "float";  break;
                case DATA_STRING: dt = "string"; break;
            }
            cJSON_AddStringToObject(param_obj, "data_type", dt);

            cJSON *props = cJSON_CreateArray();
            if (p->properties & PROP_READ)        cJSON_AddItemToArray(props, cJSON_CreateString("read"));
            if (p->properties & PROP_WRITE)       cJSON_AddItemToArray(props, cJSON_CreateString("write"));
            if (p->properties & PROP_PERSIST)     cJSON_AddItemToArray(props, cJSON_CreateString("persist"));
            if (p->properties & PROP_TIME_SERIES) cJSON_AddItemToArray(props, cJSON_CreateString("time_series"));
            cJSON_AddItemToObject(param_obj, "properties", props);

            /* Value (cached) */
            switch (p->data_type) {
                case DATA_BOOL:   cJSON_AddBoolToObject(param_obj, "value", p->last_value.val.b); break;
                case DATA_INT:    cJSON_AddNumberToObject(param_obj, "value", p->last_value.val.i); break;
                case DATA_FLOAT:  cJSON_AddNumberToObject(param_obj, "value", p->last_value.val.f); break;
                case DATA_STRING: cJSON_AddStringToObject(param_obj, "value", p->last_value.val.s ? p->last_value.val.s : ""); break;
            }
            cJSON_AddItemToArray(params_arr, param_obj);
        }
        cJSON_AddItemToObject(dev_obj, "params", params_arr);
        if (d->attributes) cJSON_AddItemToObject(dev_obj, "attributes", cJSON_Duplicate(d->attributes, true));

        /* Services go in a separate array */
        if (strncmp(d->type, "esp.service.", 12) == 0) {
            cJSON_AddItemToArray(services_arr, dev_obj);
        } else {
            cJSON_AddItemToArray(devices_arr, dev_obj);
        }
    }

    cJSON_AddItemToObject(root, "devices", devices_arr);
    cJSON_AddItemToObject(root, "services", services_arr);

    /* Timestamp */
    time_t now;
    time(&now);
    struct tm *tm_info = gmtime(&now);
    char ts_buf[32];
    strftime(ts_buf, sizeof(ts_buf), "%Y-%m-%dT%H:%M:%SZ", tm_info);
    cJSON_AddStringToObject(root, "published_at", ts_buf);

    return root;
}

void profile_free(she_node_t *node) {
    if (!node) return;
    for (int i = 0; i < node->device_count; i++) {
        if (node->devices[i].params) free(node->devices[i].params);
        if (node->devices[i].attributes) cJSON_Delete(node->devices[i].attributes);
    }
}
