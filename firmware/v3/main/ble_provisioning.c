/* =============================================================================
 * SHE V3 firmware — ble_provisioning.c (app-claims flow)
 * =============================================================================
 * Standard Espressif wifi_prov_mgr BLE provisioning (Security 1, PoP).
 * V3-FIRMWARE §5. P1-1, P1-2, P1-3, P1-26. P0-1 (cert is factory-issued).
 * App-claims: device only does Wi-Fi provisioning here. The mobile app calls
 * POST /api/v3/nodes/claim (P1-3) afterwards; the device never POSTs claim.
 * ==========================================================================*/

#include "ble_provisioning.h"
#include "app_wifi.h"        /* app_wifi_set_provisioning_active() */
#include "nvs_keys.h"
#include "esp_log.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_system.h"
#include "nvs_flash.h"
#include "wifi_provisioning/manager.h"
#include "wifi_provisioning/scheme_ble.h"
#include "esp_mac.h"
/* Vendored Espressif QR component (third_party/qrcode) — renders the
 * provisioning payload as a scannable QR on the console, exactly as the ESP-IDF
 * wifi_prov_mgr example and ESP RainMaker do. */
#include "qrcode.h"
#include "esp_random.h"      /* esp_random() — generate a PoP when fctry has none */
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include <stdio.h>           /* snprintf */
#include <string.h>

static const char *TAG = "she_ble";

/* DevKit bring-up PoP (P1-26 format: 9-digit numeric). DEV ONLY — production
 * devices get a CSPRNG PoP programmed at the factory (P1-1). */
#define SHE_DEVKIT_DEFAULT_POP    "123456789"

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

/* ---- Percent-encode a string for use as a URL query value ----
 *
 * Everything outside RFC 3986's unreserved set is escaped, because the payload
 * is JSON: its `{`, `"`, `:` and `,` are all unsafe raw inside a URL. The
 * ESP-IDF example gets away with a bare `?data=%s` purely on browser leniency;
 * this does it properly, and stops at the buffer edge rather than overflowing.
 */
static void url_encode(const char *in, char *out, size_t out_len) {
    static const char hex[] = "0123456789ABCDEF";
    size_t o = 0;
    for (const char *p = in; *p != '\0'; p++) {
        unsigned char c = (unsigned char)*p;
        bool unreserved = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                          (c >= '0' && c <= '9') || c == '-' || c == '_' ||
                          c == '.' || c == '~';
        if (unreserved) {
            if (o + 1 >= out_len) break;
            out[o++] = (char)c;
        } else {
            if (o + 3 >= out_len) break;
            out[o++] = '%';
            out[o++] = hex[c >> 4];
            out[o++] = hex[c & 0x0F];
        }
    }
    out[o] = '\0';
}

/* ---- Print the provisioning QR (V3-FACTORY-OPS §4) ----
 *
 * The factory prints this exact JSON on the enclosure sticker. A board whose
 * sticker is missing, scratched, or already boxed into a wall cannot otherwise
 * be added: the app needs the 9-digit PoP and there is nothing on the device to
 * read it from. So the same payload is rendered here as a QR the phone camera
 * can read straight off the console — the same thing the ESP-IDF `wifi_prov_mgr`
 * example and ESP RainMaker do (`esp_qrcode_generate` + `ESP_QRCODE_CONFIG_DEFAULT`).
 *
 * ⚠ This prints the PoP in clear text. That is deliberate and no worse than the
 * sticker, which carries the same value — but it is why this only runs while a
 * provisioning session is starting, and why the console should stay disabled on
 * a production unit.
 *
 * The ESP32 has no display, so the console (or the browser) IS the display.
 * `esp_qrcode_print_console()` draws with Unicode half-blocks, two QR rows per
 * line, so the terminal must be UTF-8 with a font that has U+2580/U+2584/U+2588
 * — hence the URL fallback at the end, which needs no special font.
 */
static void print_provisioning_qr(const she_node_t *node, const char *pop,
                                  const char *service_name) {
    /* static, not automatic: this runs once, at provisioning start, and the main
     * task's stack is small — the payload plus its URL-encoded form is >1 KB. */
    static char payload[320];
    static char encoded[1024];

    char mac[18] = {0};
    char sku[8] = {0};

    /* Prefer the profile built in main.c Step 5 (from fctry, or SHE_BUILD_SKU on
     * an unprovisioned board). Fall back to the eFuse MAC so the payload never
     * ships a missing field — the app keys its claim on this MAC. */
    if (node != NULL && node->mac != NULL && node->mac[0] != '\0') {
        snprintf(mac, sizeof(mac), "%s", node->mac);
    } else {
        uint8_t raw[6] = {0};
        esp_read_mac(raw, ESP_MAC_WIFI_STA);
        snprintf(mac, sizeof(mac), "%02X:%02X:%02X:%02X:%02X:%02X",
                 raw[0], raw[1], raw[2], raw[3], raw[4], raw[5]);
    }
    if (node != NULL && node->sku != NULL && node->sku[0] != '\0') {
        snprintf(sku, sizeof(sku), "%s", node->sku);
    }

    int n = snprintf(payload, sizeof(payload),
                     "{\"ver\":1,\"name\":\"%s\",\"pop\":\"%s\","
                     "\"transport\":\"ble\",\"mac\":\"%s\",\"sku\":\"%s\","
                     "\"url\":\"https://she.et/setup/%s\"}",
                     service_name, pop, mac, sku, service_name);
    if (n <= 0 || n >= (int)sizeof(payload)) {
        ESP_LOGW(TAG, "QR payload does not fit the buffer — skipping the QR");
        return;
    }

    ESP_LOGI(TAG, "Provisioning QR payload (V3-FACTORY-OPS §4):");
    ESP_LOGI(TAG, "  name=%s pop=%s mac=%s sku=%s", service_name, pop, mac, sku);
    /* One machine-greppable line, so an installer can lift the payload out of a
     * captured log without scraping the QR art below. */
    ESP_LOGI(TAG, "SHE_QR_PAYLOAD=%s", payload);

    /* The sticker, on the console. Same bytes, so the phone does not care which
     * one it reads. ECC LOW + version <= 10 is the ESP-IDF/RainMaker default and
     * keeps the symbol small enough to scan off a terminal. */
    esp_qrcode_config_t cfg = ESP_QRCODE_CONFIG_DEFAULT();
    esp_err_t qr_err = esp_qrcode_generate(&cfg, payload);
    if (qr_err != ESP_OK) {
        ESP_LOGW(TAG, "Could not render the QR (%s) — use the payload or the URL below",
                 esp_err_to_name(qr_err));
    }

    /* Escape hatch for terminals that mangle the block characters, and the way to
     * turn the payload into a printable sticker. Same trick as the IDF example. */
    url_encode(payload, encoded, sizeof(encoded));
    ESP_LOGI(TAG, "If the QR above is unreadable, open this in a browser:");
    ESP_LOGI(TAG, "  https://espressif.github.io/esp-jumpstart/qrcode.html?data=%s", encoded);
    ESP_LOGI(TAG, "Or the offline copy in this repo: open she-v3/tools/qr-code.html and paste");
    ESP_LOGI(TAG, "the SHE_QR_PAYLOAD line, or append ?data=<the encoded payload> to its file URL.");
}

/* ---- Provisioning event handler: mark provisioned + reboot on Wi-Fi success ----
 * App-claims: the app calls POST /api/v3/nodes/claim after Wi-Fi succeeds,
 * so the device only persists the provisioned flag here. */
static void prov_event_handler(void *arg, esp_event_base_t event_base,
                               int32_t event_id, void *event_data) {
    if (event_base == WIFI_PROV_EVENT) {
        switch (event_id) {
        case WIFI_PROV_START:
            ESP_LOGI(TAG, "Provisioning started");
            break;
        case WIFI_PROV_CRED_RECV: {
            wifi_sta_config_t *sta_cfg = (wifi_sta_config_t *)event_data;
            ESP_LOGI(TAG, "Wi-Fi creds received — SSID: %s", sta_cfg->ssid);
            break;
        }
        case WIFI_PROV_CRED_FAIL: {
            wifi_prov_sta_fail_reason_t *reason = (wifi_prov_sta_fail_reason_t *)event_data;
            ESP_LOGE(TAG, "Wi-Fi connect failed: %s",
                     (*reason == WIFI_PROV_STA_AUTH_ERROR) ? "auth error" : "AP not found");
            break;
        }
        case WIFI_PROV_CRED_SUCCESS:
            ESP_LOGI(TAG, "Wi-Fi connected — waiting for IP...");
            break;
        case WIFI_PROV_END:
            ESP_LOGI(TAG, "Provisioning session ended");
            break;
        default:
            break;
        }
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *event = (ip_event_got_ip_t *)event_data;
        ESP_LOGI(TAG, "Got IP: " IPSTR " — marking provisioned, rebooting in 2s",
                 IP2STR(&event->ip_info.ip));

        /* Persist provisioned flag in fctry NVS so next boot skips BLE */
        nvs_handle_t fctry_h;
        if (nvs_open_from_partition("fctry", SHE_FCTRY_NAMESPACE,
                                    NVS_READWRITE, &fctry_h) == ESP_OK) {
            nvs_set_u8(fctry_h, SHE_FCTRY_KEY_PROVISIONED, 1);
            nvs_commit(fctry_h);
            nvs_close(fctry_h);
        }
        vTaskDelay(pdMS_TO_TICKS(2000));
        esp_restart();
    }
}

/* ---- Check if device is already provisioned ----
 *
 * The return value of nvs_get_u8() used to be discarded. That silently folded
 * three different situations into "not provisioned":
 *   - the key is absent            -> genuinely never provisioned (expected)
 *   - the key exists with another  -> the board WAS provisioned, by a path that
 *     NVS type (e.g. a string)        wrote the flag differently
 *   - a real read error            -> unknown state
 * Only the first should send the device back into BLE provisioning. Getting that
 * wrong on a provisioned board means it advertises itself as new every boot.
 */
bool ble_provisioning_is_provisioned(void) {
    nvs_handle_t h;
    esp_err_t err = nvs_open_from_partition("fctry", SHE_FCTRY_NAMESPACE, NVS_READONLY, &h);
    if (err != ESP_OK) {
        /* No fctry partition (wrong partition table) or no namespace yet. There
         * is no flag to read, so the board is not provisioned. */
        return false;
    }

    uint8_t provisioned = 0;
    err = nvs_get_u8(h, SHE_FCTRY_KEY_PROVISIONED, &provisioned);
    nvs_close(h);

    if (err == ESP_ERR_NVS_NOT_FOUND) {
        return false;   /* fresh board — the expected case */
    }
    if (err == ESP_ERR_NVS_TYPE_MISMATCH) {
        /* The key EXISTS but was not written as a u8, so the board has been
         * provisioned by something. Treat it as provisioned: re-entering BLE
         * on a working board is the worse failure of the two. */
        ESP_LOGW(TAG, "'%s' exists with a different NVS type (%s) — treating as provisioned",
                 SHE_FCTRY_KEY_PROVISIONED, esp_err_to_name(err));
        return true;
    }
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "nvs_get_u8(%s) failed: %s — treating as not provisioned",
                 SHE_FCTRY_KEY_PROVISIONED, esp_err_to_name(err));
        return false;
    }
    return provisioned == 1;
}

/* ---- Start BLE provisioning ---- */
esp_err_t ble_provisioning_start(she_node_t *node) {
    ESP_LOGI(TAG, "Starting BLE provisioning (Service UUID: %s)", SHE_BLE_SERVICE_UUID);

    /* Read PoP from fctry NVS (P1-1: 9-digit numeric CSPRNG) */
    char pop[16] = {0};
    const char *pop_source = "fctry NVS";
    esp_err_t pop_err = read_pop_from_fctry(pop, sizeof(pop));
    if (pop_err != ESP_OK) {
        /* Say WHICH kind of missing first. "partition not in the flashed table"
         * (wrong partition table) and "partition present but empty" (never
         * factory-provisioned) need completely different fixes. */
        if (pop_err == ESP_ERR_NVS_PART_NOT_FOUND) {
            ESP_LOGE(TAG, "The 'fctry' partition is not in the flashed partition table.");
            ESP_LOGE(TAG, "  Check CONFIG_PARTITION_TABLE_FILENAME (partitions_esp32.csv).");
        } else {
            ESP_LOGW(TAG, "fctry NVS holds no '%s' key (%s)",
                     SHE_FCTRY_KEY_POP, esp_err_to_name(pop_err));
        }

#if defined(CONFIG_SHE_REQUIRE_FACTORY_POP)
        /* Strict P1-1 mode. Refusing here keeps a factory-process failure loud:
         * a board that shipped without its PoP never advertises, so the fault
         * surfaces instead of being papered over. */
        ESP_LOGE(TAG, "CONFIG_SHE_REQUIRE_FACTORY_POP is set — refusing to start provisioning");
        ESP_LOGE(TAG, "  Program the identity image: scripts/build-device-nvs.py");
        return ESP_FAIL;
#else
        /* Bring-up path.
         *
         * A board with no PoP cannot advertise, so it cannot be given Wi-Fi
         * credentials, so it can never come online. That is a dead end, not a
         * safety property — which is what the old unconditional ESP_FAIL made
         * of every unprovisioned board. Generate a PoP, persist it so it is
         * stable across reboots, and print it.
         *
         * The DevKit keeps its fixed, documented default so the existing DevKit
         * bring-up notes stay valid. A real board gets a random 9-digit value
         * so two unprovisioned boards never share a PoP. */
#ifdef CONFIG_SHE_DEVKIT_ESP32
        strncpy(pop, SHE_DEVKIT_DEFAULT_POP, sizeof(pop) - 1);
        pop_source = "DevKit default";
#else
        snprintf(pop, sizeof(pop), "%09u",
                 (unsigned)(100000000u + (esp_random() % 900000000u)));
        pop_source = "generated at first boot";
#endif
        nvs_handle_t fctry_h;
        if (nvs_open_from_partition("fctry", SHE_FCTRY_NAMESPACE,
                                    NVS_READWRITE, &fctry_h) == ESP_OK) {
            nvs_set_str(fctry_h, SHE_FCTRY_KEY_POP, pop);
            nvs_commit(fctry_h);
            nvs_close(fctry_h);
            pop_source = "fctry NVS (generated at first boot)";
            ESP_LOGW(TAG, "No factory PoP — generated one and persisted it to fctry NVS");
        } else {
            ESP_LOGW(TAG, "No factory PoP and fctry is not writable — this PoP is "
                          "valid for the current boot only");
        }
        ESP_LOGW(TAG, "Set CONFIG_SHE_REQUIRE_FACTORY_POP=y for production builds "
                      "to reject unprovisioned boards instead of adopting them");
#endif
    }
    /* Log the PoP *and* where it came from. The fctry partition survives
     * re-flashing, so a device that was ever provisioned with a different
     * PoP keeps that value and every app handshake fails with a generic
     * "secure session rejected" until the app is given this exact PoP. */
    ESP_LOGI(TAG, "PoP = %s (source: %s) — type this into the app's PoP field",
             pop, pop_source);
    /* Deliberately NOT `idf.py erase-flash`: that erases the whole chip,
     * including the mTLS client cert + key stored in fctry, so the node loses
     * its identity and must be factory-provisioned again. Erase only fctry. */
    ESP_LOGW(TAG, "To regenerate the PoP, erase ONLY the fctry partition:");
    ESP_LOGW(TAG, "  esptool.py --chip esp32 -p <PORT> erase_region 0x5C0000 0x10000");

    /* Advertised device name = node_id (e.g. "SHE-R8-AABBCC").
     * DevKit without factory identity: derive "SHE-<MAC24>" from eFuse MAC. */
    char service_name[32];
    if (node->node_id && strlen(node->node_id) > 0) {
        strncpy(service_name, node->node_id, sizeof(service_name) - 1);
        service_name[sizeof(service_name) - 1] = '\0';
    } else {
        uint8_t mac[6] = {0};
        esp_read_mac(mac, ESP_MAC_WIFI_STA);
        snprintf(service_name, sizeof(service_name), "SHE-%02X%02X%02X",
                 mac[3], mac[4], mac[5]);
#ifdef CONFIG_SHE_DEVKIT_ESP32
        ESP_LOGW(TAG, "No node_id — DevKit service name: %s", service_name);
#endif
    }
    ESP_LOGI(TAG, "Advertised name: %s", service_name);

    /* Print the same JSON the factory prints on the sticker — as a scannable QR
     * — so a device with an unreadable label can still be added. */
    print_provisioning_qr(node, pop, service_name);

    /* Initialize Wi-Fi provisioning manager with BLE scheme */
    wifi_prov_mgr_config_t cfg = {
        .scheme = wifi_prov_scheme_ble,
#if defined(CONFIG_SHE_R4) || defined(CONFIG_SHE_DEVKIT_ESP32)
        /* R4 is a C3 (BLE-only radio) and the DevKit has no BT controller use —
         * freeing BLE alone is correct and frees the most RAM. */
        .scheme_event_handler = WIFI_PROV_SCHEME_BLE_EVENT_HANDLER_FREE_BLE,
#else
        /* R8 / R16 / R24 are S3 parts with a full BTDM controller. */
        .scheme_event_handler = WIFI_PROV_SCHEME_BLE_EVENT_HANDLER_FREE_BTDM,
#endif
    };
    ESP_ERROR_CHECK(wifi_prov_mgr_init(cfg));

    /* Set service UUID (P1-2: 0000ffff-0000-1000-8000-00805f9b34fb).
     * ESP-IDF expects the 128-bit UUID as a LITTLE-ENDIAN (LSB-first) byte
     * array, so the 16-bit 0xFFFF belongs at offset 12-13 — NOT at 2-3.
     * Placing it at 2-3 dropped the 0xFFFF into the wrong UUID field, so the
     * device advertised a service UUID that is not the Bluetooth base UUID
     * and not P1-2 (clients then fail to open a provisioning session on it).
     * Kept static: the API keeps the pointer, and provisioning runs for the
     * lifetime of the firmware. */
    static uint8_t she_ble_service_uuid[16] = {
        0xfb, 0x34, 0x9b, 0x5f, 0x80, 0x00, 0x00, 0x80,
        0x00, 0x10, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00,
    };
    wifi_prov_scheme_ble_set_service_uuid(she_ble_service_uuid);

    /* Standard Espressif Wi-Fi provisioning (prov-session/prov-config/prov-scan).
     * No custom "she-prov" endpoint in app-claims flow — the app sends only
     * Wi-Fi creds over BLE, then calls POST /api/v3/nodes/claim itself. */
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_PROV_EVENT, ESP_EVENT_ANY_ID,
                                               &prov_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                               &prov_event_handler, NULL));
    /* The provisioning manager is about to own the STA connection. Tell
     * app_wifi.c to stop running its own reconnect loop over the top of it. */
    app_wifi_set_provisioning_active(true);

    esp_err_t prov_err = wifi_prov_mgr_start_provisioning(WIFI_PROV_SECURITY_1, pop, service_name, NULL);
    if (prov_err == ESP_ERR_INVALID_STATE) {
        /* Stale manager state: a previous failed attempt left Wi-Fi creds in
         * the manager while our provisioned flag is still 0. The manager then
         * refuses to start and the phone fails with "Failed to create
         * session". Tear down and start clean (deinit/stop are documented
         * no-op-safe when idle). */
        ESP_LOGW(TAG, "Provisioning already started/stale — resetting manager for a clean session");
        wifi_prov_mgr_stop_provisioning();
        wifi_prov_mgr_deinit();
        ESP_ERROR_CHECK(wifi_prov_mgr_init(cfg));
        prov_err = wifi_prov_mgr_start_provisioning(WIFI_PROV_SECURITY_1, pop, service_name, NULL);
    }
    ESP_ERROR_CHECK(prov_err);

    ESP_LOGI(TAG, "BLE provisioning started — waiting for app to connect (PoP: %s)", pop);

    /* Return as soon as the manager is advertising; it is the CALLER's job to
     * park app_main until the reboot that prov_event_handler() triggers on
     * GOT_IP (main.c Step 6 does exactly that).
     *
     * This used to spin here forever. That made the caller's ESP_FAIL branch
     * unreachable, so a board whose fctry partition holds no PoP logged
     * "provisioning started" and main.c's entire factory-provisioning recovery
     * message was dead code — the operator saw a healthy-looking device and had
     * nothing to act on. */
    return ESP_OK;
}
