/* =============================================================================
 * SHE V3 firmware — system_service.c
 * =============================================================================
 * V3-FIRMWARE §2.2.
 * ==========================================================================*/

#include "system_service.h"
#include "nvs_keys.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_sntp.h"
#include "lwip/apps/sntp.h"
#include "nvs_flash.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

static const char *TAG = "she_sys";

/* ---- Time synchronisation (SNTP) ------------------------------------------
 *
 * The device had no SNTP at all, so its clock was never set — yet payloads stamp
 * themselves with time(NULL): device_profiles.c builds "published_at", and the status
 * payload carries "ts". Those values were meaningless.
 *
 * Nothing was corrupted by it: the backend stamps stored telemetry itself and ignores the
 * device-supplied fields. But the device ought to know what time it is, and sync_time was a
 * command that only logged.
 *
 * SNTP is part of lwIP and is already compiled in — IDF 5.1 has no CONFIG_LWIP_SNTP bool,
 * sntp.c is always built — so this needs no sdkconfig change. Starting it early is enough:
 * lwIP retries until it gets a response, so no "wait for Wi-Fi" hook is required.
 */
#define SNTP_SERVER           "pool.ntp.org"
#define TIME_SYNC_TIMEOUT_MS  20000
/* 2023-11-14. time(NULL) is well below this until SNTP has actually set the clock, so it is
 * a more reliable "is it set yet" test than the sync status on a restart. */
#define TIME_SET_FLOOR        1700000000L

static bool s_sntp_started = false;

static void time_sync_cb(struct timeval *tv) {
    ESP_LOGI(TAG, "Time synchronised via SNTP");
}

void system_service_time_sync_start(void) {
    if (s_sntp_started) {
        return;
    }
    /* Local time is Ethiopia (EAT, UTC+3, no DST) — required so that a schedule the
     * user sets as "20:00" means 20:00 Ethiopian, not 20:00 UTC (which would be
     * 23:00 local, three hours late).
     *
     * This is SAFE for existing payload timestamps: every one is built with
     * gmtime()/gmtime_r() (device_profiles.c published_at, and the sync log below),
     * which is unaffected by TZ. Nothing in the tree calls localtime() or mktime()
     * except the schedule watcher, which is exactly what wants local time.
     *
     * POSIX offset is "time added to local to reach UTC", so UTC+3 is -3.
     */
    setenv("TZ", "EAT-3", 1);
    tzset();

    esp_sntp_setoperatingmode(SNTP_OPMODE_POLL);
    esp_sntp_setservername(0, SNTP_SERVER);
    sntp_set_time_sync_notification_cb(time_sync_cb);
    esp_sntp_init();
    s_sntp_started = true;
    ESP_LOGI(TAG, "SNTP started (server=%s) — clock will sync once Wi-Fi is up", SNTP_SERVER);
}

static esp_err_t sync_time_now(void) {
    system_service_time_sync_start();
    /* Ask now instead of waiting out the 1-hour poll interval. */
    sntp_restart();

    for (int waited = 0; waited < TIME_SYNC_TIMEOUT_MS; waited += 500) {
        time_t now = time(NULL);
        if (now > TIME_SET_FLOOR) {
            struct tm t;
            char buf[32];
            gmtime_r(&now, &t);
            strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &t);
            ESP_LOGI(TAG, "Time sync OK: %s (epoch=%ld)", buf, (long)now);
            return ESP_OK;
        }
        vTaskDelay(pdMS_TO_TICKS(500));
    }
    ESP_LOGW(TAG, "Time sync timed out after %d ms — Wi-Fi up? NTP reachable?",
             TIME_SYNC_TIMEOUT_MS);
    return ESP_ERR_TIMEOUT;
}

esp_err_t system_service_execute(she_system_cmd_t cmd, const char *reason) {
    ESP_LOGI(TAG, "System command: %d reason=%s", cmd, reason ? reason : "none");

    switch (cmd) {
    case SHE_CMD_REBOOT:
        ESP_LOGI(TAG, "Rebooting in 1s...");
        vTaskDelay(pdMS_TO_TICKS(1000));
        esp_restart();
        break;

    case SHE_CMD_FACTORY_RESET:
        ESP_LOGW(TAG, "Factory reset — erasing NVS + fctry provisioning flag");
        /* Erase default NVS (Wi-Fi creds, runtime state) */
        nvs_flash_erase();
        nvs_flash_init();
        /* Clear the provisioned flag in fctry NVS (keep cert + key + PoP) */
        nvs_handle_t h;
        nvs_open_from_partition("fctry", SHE_FCTRY_NAMESPACE, NVS_READWRITE, &h);
        nvs_set_u8(h, SHE_FCTRY_KEY_PROVISIONED, 0);
        nvs_commit(h);
        nvs_close(h);
        ESP_LOGI(TAG, "Factory reset complete — rebooting into BLE provisioning mode");
        vTaskDelay(pdMS_TO_TICKS(1000));
        esp_restart();
        break;

    case SHE_CMD_SYNC_TIME:
        return sync_time_now();

    case SHE_CMD_PING:
        ESP_LOGI(TAG, "Ping received");
        break;

    default:
        ESP_LOGW(TAG, "Unknown system command: %d", cmd);
        return ESP_ERR_INVALID_ARG;
    }
    return ESP_OK;
}
