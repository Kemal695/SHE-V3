/* =============================================================================
 * SHE V3 firmware — system_service.c
 * =============================================================================
 * V3-FIRMWARE §2.2.
 * ==========================================================================*/

#include "system_service.h"
#include "nvs_keys.h"
#include "esp_log.h"
#include "esp_system.h"
#include "nvs_flash.h"
#include <string.h>

static const char *TAG = "she_sys";

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
        /* TODO: SNTP sync */
        ESP_LOGI(TAG, "Time sync requested (SNTP — TODO)");
        break;

    case SHE_CMD_PING:
        ESP_LOGI(TAG, "Ping received");
        break;

    default:
        ESP_LOGW(TAG, "Unknown system command: %d", cmd);
        return ESP_ERR_INVALID_ARG;
    }
    return ESP_OK;
}
