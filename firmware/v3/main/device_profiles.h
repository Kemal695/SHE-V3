/* =============================================================================
 * SHE V3 firmware — device_profiles.h
 * =============================================================================
 * RainMaker hierarchy in C: Node → Device → Service → Parameter → Attribute.
 * V3-DEVICE-MODEL §1-5. ADR-011. V3-FIRMWARE §11.
 *
 * This is the canonical schema all other firmware modules consume.
 * ==========================================================================*/

#ifndef SHE_DEVICE_PROFILES_H
#define SHE_DEVICE_PROFILES_H

#include <stdint.h>
#include <stdbool.h>
#include "cJSON.h"

/**
 * Firmware version reported by every device profile.
 *
 * Single source of truth. Previously each profile hardcoded its own string, so
 * after an OTA the app kept showing the version baked in at build time rather
 * than what was actually running — you could not tell an update had landed.
 * Bump this one value before every release, and keep it in step with the
 * `firmware_version` used when creating an OTA batch.
 */
#define SHE_FIRMWARE_VERSION "3.0.9"

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Parameter property bitmask (V3-DEVICE-MODEL §1.5) ---- */
typedef enum {
    PROP_READ        = 1 << 0,
    PROP_WRITE       = 1 << 1,
    PROP_PERSIST     = 1 << 2,
    PROP_TIME_SERIES = 1 << 3,
} param_props_t;

/* ---- Data types ---- */
typedef enum {
    DATA_BOOL = 0,
    DATA_INT,
    DATA_FLOAT,
    DATA_STRING,
} data_type_t;

/* ---- Union for cached param value ---- */
typedef struct {
    data_type_t type;
    union {
        bool    b;
        int     i;
        float   f;
        char   *s;
    } val;
} param_value_t;

/* ---- Parameter (V3-DEVICE-MODEL §1.4) ---- */
typedef struct {
    const char       *name;          /* "Power" */
    const char       *type;          /* "esp.param.power" */
    data_type_t       data_type;     /* DATA_BOOL */
    param_props_t     properties;    /* PROP_READ | PROP_WRITE | PROP_PERSIST */
    float             min_val;       /* 0 (for sliders) */
    float             max_val;       /* 100 */
    param_value_t     last_value;    /* cached (synced to cloud via MQTT) */
    bool              dirty;         /* TRUE = needs to be published */
} node_param_t;

/* ---- Device (V3-DEVICE-MODEL §1.3) ---- */
typedef struct {
    const char        *name;         /* "Relay 1" */
    const char        *type;         /* "esp.device.switch" */
    uint8_t            channel;      /* 0-15 (maps to PCF8574 pin) */
    node_param_t      *params;       /* array */
    uint8_t            param_count;
    cJSON             *attributes;   /* {"Label":"Kitchen Light","Channel":"0"} */
} node_device_t;

/* ---- Node (V3-DEVICE-MODEL §1.2) ---- */
typedef struct {
    const char        *node_id;      /* "SHE-R8-AABBCC" */
    const char        *mac;          /* "24:6F:28:AA:BB:CC" */
    const char        *sku;          /* "SHE-R8" */
    const char        *firmware;     /* "3.0.0" */
    const char        *hw_rev;       /* "rev-c" */
    uint32_t           secure_version; /* anti-rollback counter */
    node_device_t     *devices;      /* array (includes services) */
    uint8_t            device_count;
} she_node_t;

/* ---- Profile builders (one per SKU) ---- */
she_node_t* profile_build_r4(void);
she_node_t* profile_build_r8(void);
she_node_t* profile_build_r16(void);

/** R24: 24 relays (16 lights + 8 sockets) on 3 × PCF8574. See ADR-015. */
she_node_t* profile_build_r24(void);

/* ---- Helpers ---- */
she_node_t* profile_build_for_sku(const char *sku);
cJSON* profile_to_config_json(const she_node_t *node);   /* for MQTT config publish */
void profile_free(she_node_t *node);

/* ---- Param helpers ---- */
param_value_t param_bool(bool v);
param_value_t param_int(int v);
param_value_t param_float(float v);
param_value_t param_string(const char *v);

#ifdef __cplusplus
}
#endif

#endif /* SHE_DEVICE_PROFILES_H */
