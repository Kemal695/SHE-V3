// =============================================================================
// SHE V3 firmware — NVS namespace + key definitions (single source of truth)
// =============================================================================
// V3-FIRMWARE §2.2 — nvs_keys.h.
// All NVS namespaces + keys are defined here to avoid magic strings.
// =============================================================================

#ifndef SHE_NVS_KEYS_H
#define SHE_NVS_KEYS_H

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Default NVS partition (user Wi-Fi creds, runtime state) ---- */
#define SHE_NVS_NAMESPACE           "she_nvs"

/* ---- Factory NVS partition (fctry) — written at factory, read-only in prod ---- */
#define SHE_FCTRY_NAMESPACE         "she_fctry"

/* Factory NVS keys (V3-FACTORY-OPS §3.2) */
#define SHE_FCTRY_KEY_CERT          "device_cert"     /* X.509 cert PEM */
#define SHE_FCTRY_KEY_KEY           "device_key"      /* ECDSA P-256 private key PEM */
#define SHE_FCTRY_KEY_POP           "device_pop"      /* 9-digit numeric PoP (P1-26) */
#define SHE_FCTRY_KEY_MAC           "device_mac"      /* AA:BB:CC:DD:EE:FF */
#define SHE_FCTRY_KEY_NODE_ID       "node_id"         /* SHE-R8-AABBCC */
#define SHE_FCTRY_KEY_SKU           "device_sku"      /* SHE-R4 | SHE-R8 | SHE-R16 */
#define SHE_FCTRY_KEY_HW_REV        "hw_rev"          /* rev-a | rev-b | rev-c */
#define SHE_FCTRY_KEY_PROVISIONED   "provisioned"     /* bool — set after BLE provisioning */

/* Factory-reset-proof copies of the connectivity config.
 *
 * SHE_CMD_FACTORY_RESET calls nvs_flash_erase(), which wipes the ENTIRE default
 * partition — including she_nvs. It only clears the `provisioned` flag in fctry,
 * deliberately keeping cert/key/PoP. So anything the device needs in order to come
 * back online after a reset must also live in the fctry partition.
 *
 * she_mqtt reads she_nvs first and falls back to these keys (same names, different
 * namespace), so a factory reset degrades to "re-provision Wi-Fi" instead of
 * "device can never start MQTT again".
 */
#define SHE_FCTRY_KEY_TENANT_ID     "tenant_id"       /* UUID */
#define SHE_FCTRY_KEY_HOME_ID       "home_id"         /* UUID (nullable) */
#define SHE_FCTRY_KEY_MQTT_BROKER   "mqtt_broker"     /* e.g. mqtts://host:8883 */
#define SHE_FCTRY_KEY_API_BASE_URL  "api_base_url"    /* e.g. https://api... */

/* Runtime NVS keys (she_nvs namespace) */
#define SHE_NVS_KEY_TENANT_ID       "tenant_id"       /* UUID */
#define SHE_NVS_KEY_HOME_ID         "home_id"         /* UUID (nullable) */
#define SHE_NVS_KEY_ROOM_ID         "room_id"         /* UUID (nullable) */
#define SHE_NVS_KEY_MQTT_BROKER     "mqtt_broker"     /* "ssl://mqtt.she.et:8883" */
#define SHE_NVS_KEY_API_BASE_URL    "api_base_url"    /* "https://api.she.et" */
#define SHE_NVS_KEY_FIRMWARE_VER    "fw_version"      /* "3.0.0" */
#define SHE_NVS_KEY_SECURE_VERSION  "secure_version"  /* anti-rollback counter */
#define SHE_NVS_KEY_RELAY_STATE     "relay_state"     /* uint16_t bitmask (persist property) */
#define SHE_NVS_KEY_PARAM_SEQ       "param_seq"       /* uint32_t monotonic seq for params/remote */

/* ---- NVS encryption keys partition (nvs.keys) ---- */
#define SHE_NVS_KEYS_PARTITION      "nvs.keys"

#ifdef __cplusplus
}
#endif

#endif /* SHE_NVS_KEYS_H */
