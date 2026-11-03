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
#include <time.h>

static const char *TAG = "device_profiles";

/* ---- Relay names (V3-DEVICE-MODEL §1.3) ---- */
static const char *relay_names_r4[]  = {"Relay 1", "Relay 2", "Relay 3", "Relay 4"};
static const char *relay_names_r8[]  = {"Relay 1", "Relay 2", "Relay 3", "Relay 4",
                                        "Relay 5", "Relay 6", "Relay 7", "Relay 8"};
/* R24 board (ADR-015): 16 lights + 8 sockets across 3 × PCF8574.
 *
 * Channel map — note the sockets sit BETWEEN the two light banks, because that
 * is how the expanders are physically wired, AND the addresses are not in
 * ascending bank order (0x25 is OUT_3, not OUT_2):
 *    ch  0-7  Light 1-8    (expander 0x24 = OUT_1)
 *    ch  8-15 Socket 1-8   (expander 0x26 = OUT_2)
 *    ch 16-23 Light 9-16   (expander 0x25 = OUT_3)
 *
 * Names are the cloud-facing contract: a person finds a light by room and name,
 * not by expander pin. Room labels (bilingual) go in the device attributes. */
static const char *relay_names_r24[] = {
    "Light 1",  "Light 2",  "Light 3",  "Light 4",
    "Light 5",  "Light 6",  "Light 7",  "Light 8",
    "Socket 1", "Socket 2", "Socket 3", "Socket 4",
    "Socket 5", "Socket 6", "Socket 7", "Socket 8",
    "Light 9",  "Light 10", "Light 11", "Light 12",
    "Light 13", "Light 14", "Light 15", "Light 16",
};

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

/* ---- Build the Local Control service (esp.service.local_control) ----
 *
 * This is ESP RainMaker's own mechanism, reproduced.
 *
 * RainMaker never asks the user for a proof of possession in order to use local
 * control. The NODE publishes a `Local Control` service whose POP param carries
 * the credential, and a client that has the node associated simply reads it out
 * of the node description:
 *
 *   "Whenever a node gets associated with a user, clients such as mobile apps can
 *    check if the node supports secure local control by searching for the local
 *    control service in the node configuration. If available, it gets the PoP
 *    from the node parameters."
 *
 * The value is this board's factory PoP — the same 9 digits the physical label
 * and the QR code carry, and the same one local_ctrl.c's verify_pop() compares
 * the `X-SHE-PoP` header against. Advertising it here is what lets the app arm
 * the LAN path with NO prompt, and what lets a second phone (or a fresh install)
 * command the board without the label.
 *
 * Consequences worth knowing:
 *  - The PoP now travels with the node's cloud description, so anyone who can
 *    read this node's params can command the board over the LAN. That is
 *    RainMaker's own trade-off, and the description is reachable only through the
 *    account's authenticated REST API (and the broker's per-device mTLS topic).
 *  - It is published ONCE, in the retained `config` payload. It is deliberately
 *    excluded from `params/local` (see mqtt_publish_params_local) so the
 *    credential is not re-broadcast every 60 s.
 *  - local_ctrl.c's /she/info skips `esp.service.*` devices, so the PoP is not
 *    readable over the LAN by someone who does not already have it.
 *
 * ⚠ Static params, NOT calloc'd. profile_free() frees `.params` only for devices
 * whose type is not `esp.service.*` (the F5 note), and this one IS a service —
 * so the array must be static, exactly the opposite of build_sensor_device(). */
static char s_local_control_pop[16];

static void load_local_control_pop(void) {
    if (s_local_control_pop[0] != '\0') return;
    nvs_handle_t h;
    if (nvs_open_from_partition("fctry", SHE_FCTRY_NAMESPACE, NVS_READONLY, &h) != ESP_OK) {
        ESP_LOGW(TAG, "Local Control: fctry NVS unreadable — POP not advertised");
        return;
    }
    size_t len = sizeof(s_local_control_pop);
    esp_err_t err = nvs_get_str(h, SHE_FCTRY_KEY_POP, s_local_control_pop, &len);
    nvs_close(h);
    if (err != ESP_OK) {
        /* An unprovisioned board has an empty fctry partition. Advertising an
         * empty POP would make the app think local control is armed and then
         * fail every LAN command with 401 — say nothing instead, and the app
         * falls back to whatever it captured at provisioning. */
        s_local_control_pop[0] = '\0';
        ESP_LOGW(TAG, "Local Control: no %s in fctry NVS — POP not advertised",
                 SHE_FCTRY_KEY_POP);
    }
}

static node_device_t build_local_control_service(void) {
    /* Fills s_local_control_pop BEFORE the value below is ever serialized. The
     * pointer in the static initializer is resolved at load time, so the order
     * here does not matter — the string is read at publish time, not now. */
    load_local_control_pop();

    static node_param_t lc_params[2];
    lc_params[0] = (node_param_t){
        .name = "POP", .type = "esp.param.local_control_pop", .data_type = DATA_STRING,
        .properties = PROP_READ,
        .last_value = {.type = DATA_STRING, .val.s = s_local_control_pop},
    };
    /* Type 1 = "secure local control with a PoP", the only scheme this firmware
     * implements. RainMaker's clients read it to decide how to open the session;
     * ours only checks that the service is present, but the param is part of the
     * contract and costs two bytes. */
    lc_params[1] = (node_param_t){
        .name = "Type", .type = "esp.param.local_control_type", .data_type = DATA_INT,
        .properties = PROP_READ,
        .last_value = {.type = DATA_INT, .val.i = 1},
    };
    return (node_device_t){
        .name = "Local Control", .type = "esp.service.local_control", .channel = 0,
        .params = lc_params, .param_count = 2,
        .attributes = cJSON_CreateObject(),
    };
}

/* ---- Build the Sensors device (esp.device.sensor) ----
 *
 * The environmental sensors ported from the RainMaker-era firmware: DHT22 (AM2302)
 * (temperature + humidity), an MQ-135 (air quality) and a soil-moisture probe.
 * See sensors.c / sensors.h.
 *
 * ⚠ This is NOT a service. It goes in the `devices` array, so the backend stores
 * it with `is_service = false` — the same as a relay. The mobile app's front
 * page used to decide "is this a relay?" from `is_service` alone, which would
 * have rendered this device as a 25th relay button on the R24 grid; it now
 * checks the device TYPE (see relaysOf() in node_service.dart). Any new
 * non-switch device type must be filtered there too.
 *
 * Every param is read-only and PROP_TIME_SERIES, so the backend derives a
 * "read_only" UI hint and the values flow into the device_telemetry hypertable
 * as well as into node_params.
 *
 * Names are snake_case to match this firmware's existing convention ("Free_Heap",
 * "Reset_Reason"). The old RainMaker build used a space ("Soil Moisture"); that
 * is deliberately not carried over, because a space in a param name has to be
 * URL-encoded in every API path that addresses it by name. */
static node_device_t build_sensor_device(void) {
    /* Heap, not static: profile_free() frees .params for every device whose type
     * is not `esp.service.*`, and this one is an `esp.device.*`. Handing it a
     * static array would make that free() undefined behaviour — the same trap
     * the F5 fix documented for service devices, in the opposite direction. */
    node_param_t *sensor_params = calloc(6, sizeof(node_param_t));
    sensor_params[0] = (node_param_t){
        .name = "Temperature", .type = "esp.param.temperature", .data_type = DATA_FLOAT,
        .properties = PROP_READ | PROP_TIME_SERIES, .min_val = -10.0f, .max_val = 60.0f,
    };
    sensor_params[1] = (node_param_t){
        .name = "Humidity", .type = "esp.param.humidity", .data_type = DATA_FLOAT,
        .properties = PROP_READ | PROP_TIME_SERIES, .min_val = 0.0f, .max_val = 100.0f,
    };
    sensor_params[2] = (node_param_t){
        .name = "Soil_Moisture", .type = "esp.param.soil_moisture", .data_type = DATA_FLOAT,
        .properties = PROP_READ | PROP_TIME_SERIES, .min_val = 0.0f, .max_val = 100.0f,
    };
    /* The three gases the product actually reports. The MQ-135's Toluene / NH3 /
     * acetone curves are computed and logged on the device but not published:
     * they are the same single measurement pushed through three more datasheet
     * curves, and publishing them would imply four independent gas sensors. */
    sensor_params[3] = (node_param_t){
        .name = "CO", .type = "esp.param.co", .data_type = DATA_FLOAT,
        .properties = PROP_READ | PROP_TIME_SERIES,
    };
    sensor_params[4] = (node_param_t){
        .name = "Alcohol", .type = "esp.param.alcohol", .data_type = DATA_FLOAT,
        .properties = PROP_READ | PROP_TIME_SERIES,
    };
    sensor_params[5] = (node_param_t){
        .name = "CO2", .type = "esp.param.co2", .data_type = DATA_FLOAT,
        .properties = PROP_READ | PROP_TIME_SERIES,
    };

    cJSON *attrs = cJSON_CreateObject();
    /* Plain English keys, like the relay devices' Label/Channel. The old
     * RainMaker build put bilingual strings here because RainMaker rendered
     * attributes directly; in V3 the app owns presentation and localises itself,
     * so attributes stay machine-readable metadata. */
    cJSON_AddStringToObject(attrs, "Sensor Type",
                            "Temperature, Humidity, Air Quality, Soil Moisture");
    cJSON_AddStringToObject(attrs, "Measurement", "Celsius, Percent, PPM");
    cJSON_AddStringToObject(attrs, "Hardware",
                            "DHT22/AM2302 (GPIO27), MQ-135 (ADC1_CH4/GPIO32), Soil (ADC1_CH5/GPIO33)");

    return (node_device_t){
        .name = "Sensors", .type = "esp.device.sensor", .channel = 0,
        .params = sensor_params, .param_count = 6,
        .attributes = attrs,
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
    static node_device_t devices[7];   /* 4 relays + OTA + Diagnostics + Local Control */

    /* NOTE: there is deliberately no `relay_params` array here. Each relay gets
     * its own heap-allocated param array from build_relay_device() — which is
     * what profile_free() expects to free(). A static array assigned to
     * `.params` would make profile_free() call free() on static storage. */
    for (int i = 0; i < 4; i++) {
        devices[i] = build_relay_device(relay_names_r4[i], i);
    }
    devices[4] = build_ota_service();
    devices[5] = build_diagnostics_service();
    devices[6] = build_local_control_service();

    static she_node_t node = {
        .node_id = "SHE-R4-PLACEHOLDER",
        .mac = "00:00:00:00:00:00",
        .sku = "SHE-R4",
        .firmware = SHE_FIRMWARE_VERSION,   /* single source of truth — see device_profiles.h */
        .hw_rev = "rev-c",
        .secure_version = 1,
        .devices = devices,
        .device_count = 7,
    };
    return &node;
}

she_node_t* profile_build_r8(void) {
    static node_device_t devices[11];   /* 8 relays + OTA + Diagnostics + Local Control */

    for (int i = 0; i < 8; i++) {
        devices[i] = build_relay_device(relay_names_r8[i], i);
    }
    devices[8] = build_ota_service();
    devices[9] = build_diagnostics_service();
    devices[10] = build_local_control_service();

    static she_node_t node = {
        .node_id = "SHE-R8-PLACEHOLDER",
        .mac = "00:00:00:00:00:00",
        .sku = "SHE-R8",
        .firmware = SHE_FIRMWARE_VERSION,   /* single source of truth — see device_profiles.h */
        .hw_rev = "rev-c",
        .secure_version = 1,
        .devices = devices,
        .device_count = 11,
    };
    return &node;
}

she_node_t* profile_build_r16(void) {
    static node_device_t devices[20];   /* 16 relays + OTA + Diagnostics + Voice + Local Control */

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
    devices[19] = build_local_control_service();

    static she_node_t node = {
        .node_id = "SHE-R16-PLACEHOLDER",
        .mac = "00:00:00:00:00:00",
        .sku = "SHE-R16",
        .firmware = SHE_FIRMWARE_VERSION,   /* single source of truth — see device_profiles.h */
        .hw_rev = "rev-c",
        .secure_version = 1,
        .devices = devices,
        .device_count = 20,
    };
    return &node;
}

/* R24: 24 relays (16 lights + 8 sockets) on 3 × PCF8574, per ADR-015.
 *
 * The master controls (Light Master / Socket Master / ALL OFF) are NOT modelled
 * as devices here. A master is an intent over a group of channels, not a channel
 * of its own — it is served by relay_apply_group() with the RELAY_GROUP_* masks
 * from relay_driver.h. Modelling it as a device would imply it has a pin. */
she_node_t* profile_build_r24(void) {
    static node_device_t devices[28];   /* 24 relays + OTA + Diagnostics + Sensors + Local Control */

    for (int i = 0; i < 24; i++) {
        devices[i] = build_relay_device(relay_names_r24[i], i);
    }
    devices[24] = build_ota_service();
    devices[25] = build_diagnostics_service();
    /* Sensors are wired on THIS board (DHT22/AM2302 GPIO27, MQ-135 GPIO32, soil GPIO33).
     * Only the R24 profile declares them — a bare DevKit has nothing on those
     * pins, and advertising a Sensors device it cannot read would put six dead
     * params in the app. Add the same call to another profile when that board
     * actually carries the parts. */
    devices[26] = build_sensor_device();
    devices[27] = build_local_control_service();

    static she_node_t node = {
        .node_id = "SHE-R24-PLACEHOLDER",
        .mac = "00:00:00:00:00:00",
        .sku = "SHE-R24",
        .firmware = SHE_FIRMWARE_VERSION,   /* single source of truth — see device_profiles.h */
        .hw_rev = "rev-a",
        .secure_version = 1,
        .devices = devices,
        .device_count = 28,
    };
    return &node;
}

she_node_t* profile_build_for_sku(const char *sku) {
    if (strcmp(sku, "SHE-R4") == 0)  return profile_build_r4();
    if (strcmp(sku, "SHE-R8") == 0)  return profile_build_r8();
    if (strcmp(sku, "SHE-R16") == 0) return profile_build_r16();
    if (strcmp(sku, "SHE-R24") == 0) return profile_build_r24();
#ifdef CONFIG_SHE_DEVKIT_ESP32
    /* DevKit has no factory-programmed SKU — fall back to the R4 profile
     * (4 relays, no PZEM) so bring-up can proceed to BLE provisioning. */
    ESP_LOGW(TAG, "Unknown SKU: %s — DevKit fallback to SHE-R4 profile", sku);
    return profile_build_r4();
#else
    ESP_LOGE(TAG, "Unknown SKU: %s", sku);
    return NULL;
#endif
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
        /* F5 fix: only relay devices own heap params (calloc'd in
         * build_relay_device). Service devices (esp.service.*) point at
         * static arrays — freeing those is undefined behavior (crash). */
        if (strncmp(node->devices[i].type, "esp.service.", 12) != 0) {
            free(node->devices[i].params);
            node->devices[i].params = NULL;
        }
        if (node->devices[i].attributes) {
            cJSON_Delete(node->devices[i].attributes);
            node->devices[i].attributes = NULL;
        }
    }
}
