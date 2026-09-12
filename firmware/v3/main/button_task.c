/* =============================================================================
 * SHE V3 firmware — button_task.c
 * =============================================================================
 * V3-FIRMWARE §2.2 + §3.
 * ==========================================================================*/

#include "button_task.h"
#include "system_service.h"
#include "relay_driver.h"
#include "esp_log.h"
#include "driver/gpio.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "she_button";

#define BOOT_BUTTON_GPIO    0    /* GPIO 0 = BOOT button on ESP32 dev kits */
#define LONG_PRESS_MS       5000
#define DEBOUNCE_MS         50    /* F10 fix: ignore sub-50ms glitches */

static void button_task(void *arg) {
    bool last_level = true;   /* pulled high = not pressed */

    while (true) {
        bool level = gpio_get_level(BOOT_BUTTON_GPIO);

        if (last_level && !level) {
            /* F10 fix: debounce — re-sample after 50ms, ignore the edge if high */
            vTaskDelay(pdMS_TO_TICKS(DEBOUNCE_MS));
            if (gpio_get_level(BOOT_BUTTON_GPIO)) {
                last_level = true;
                continue;
            }
            /* Button pressed (debounced falling edge) */
            int press_duration = 0;
            while (!gpio_get_level(BOOT_BUTTON_GPIO)) {
                vTaskDelay(pdMS_TO_TICKS(100));
                press_duration += 100;
                if (press_duration >= LONG_PRESS_MS) {
                    /* Long press — factory reset */
                    ESP_LOGW(TAG, "Long press detected — FACTORY RESET");
                    system_service_execute(SHE_CMD_FACTORY_RESET, "button_long_press");
                    break;
                }
            }

            if (press_duration < LONG_PRESS_MS) {
                /* Short press — cycle relays */
                ESP_LOGI(TAG, "Short press — cycling relays");
                /* Toggle all relays on then off */
                relay_set_all(0xFFFF);
                vTaskDelay(pdMS_TO_TICKS(500));
                relay_set_all(0x0000);
            }
        }
        last_level = level;
        vTaskDelay(pdMS_TO_TICKS(50));
    }
}

esp_err_t button_task_start(void) {
    /* Configure BOOT button as input */
    gpio_config_t io_conf = {
        .pin_bit_mask = (1ULL << BOOT_BUTTON_GPIO),
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&io_conf);

    BaseType_t ret = xTaskCreatePinnedToCore(
        button_task, "button_task", 2048, NULL, 2, NULL, 0);
    if (ret != pdPASS) {
        ESP_LOGE(TAG, "Failed to create button_task");
        return ESP_FAIL;
    }
    ESP_LOGI(TAG, "Button task started (priority 2, 2048 stack, core 0)");
    return ESP_OK;
}
