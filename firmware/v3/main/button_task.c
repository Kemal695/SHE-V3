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

/* GPIO 0 is the BOOT/flash strap on every ESP32 variant, not a user button.
 *
 * The production SHE boards (R4/R8/R16/R24) wire their user button to a
 * dedicated pin; GPIO0 is left as the strap so the device can always be put
 * into download mode. Enabling the factory-reset long press on GPIO0 makes a
 * board hold-to-flash wipe itself instead — which is exactly why the DevKit
 * build disables this task. The R24 SKU originally fell through to the #else
 * branch below and re-armed that hazard (devices are flashed here via manual
 * download mode: hold BOOT, tap EN), so it is now grouped with the DevKit.
 *
 * Production SKUs with a real button pin: define SHE_USER_BUTTON_GPIO and
 * replace BOOT_BUTTON_GPIO in the task below.
 */
#if defined(CONFIG_SHE_DEVKIT_ESP32) || defined(CONFIG_SHE_R24)
#define SHE_BUTTON_TASK_DISABLED 1
#endif

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
                /* Toggle all relays on then off.
                 * 0x00FFFFFF covers 24 channels (ADR-015); the old 0xFFFF would
                 * have left the third expander untouched on a 24-relay board. */
                relay_set_all(0x00FFFFFFu);
                vTaskDelay(pdMS_TO_TICKS(500));
                relay_set_all(0x00000000u);
            }
        }
        last_level = level;
        vTaskDelay(pdMS_TO_TICKS(50));
    }
}

esp_err_t button_task_start(void) {
#ifdef SHE_BUTTON_TASK_DISABLED
    /* On the ESP32-DevKit the only button wired up is GPIO0 — the BOOT/flash strap.
     * Using it as a user button is actively harmful:
     *   - holding it to enter download mode for flashing wipes the device
     *   - so does simply leaning on it for LONG_PRESS_MS (5 s)
     * because a long press fires SHE_CMD_FACTORY_RESET, which calls nvs_flash_erase().
     * That made the board impossible to reflash safely and kept resetting it in the field.
     *
     * Production hardware wires a dedicated button to a different GPIO; this task
     * remains enabled for those builds.
     */
    ESP_LOGW(TAG, "Button task DISABLED on this build — GPIO0 is the BOOT/flash strap, "
                  "not a user button (see button_task.c)");
    return ESP_OK;
#else
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
#endif
}
