/* =============================================================================
 * SHE V3 firmware — feedback_monitor.c
 * =============================================================================
 * V3-FIRMWARE §8. CD4051 8:1 mux + ADC poll every 100ms.
 * ==========================================================================*/

#include "feedback_monitor.h"
#include "relay_driver.h"
#include "mqtt_client.h"
#include "esp_log.h"
#include "driver/gpio.h"
#include "driver/adc.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "she_feedback";

/* CD4051 mux select pins (GPIO 10, 11, 12 on S3, C3-safe GPIO 4, 5, 6 on R4) */
#ifdef CONFIG_SHE_R4
#define MUX_SEL_A_GPIO    4
#define MUX_SEL_B_GPIO    5
#define MUX_SEL_C_GPIO    6
#define MUX_ADC_CHANNEL   ADC1_CHANNEL_2
#else
#define MUX_SEL_A_GPIO    10
#define MUX_SEL_B_GPIO    11
#define MUX_SEL_C_GPIO    12
#define MUX_ADC_CHANNEL   ADC1_CHANNEL_0
#endif

static uint8_t g_relay_count = 0;

esp_err_t feedback_monitor_init(uint8_t relay_count) {
    g_relay_count = relay_count;

    /* Configure mux select pins as output */
    gpio_config_t io_conf = {
        .pin_bit_mask = (1ULL << MUX_SEL_A_GPIO) | (1ULL << MUX_SEL_B_GPIO) | (1ULL << MUX_SEL_C_GPIO),
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&io_conf);

    /* Configure ADC */
    adc1_config_width(ADC_WIDTH_BIT_12);
    adc1_config_channel_atten(MUX_ADC_CHANNEL, ADC_ATTEN_DB_11);

    ESP_LOGI(TAG, "Feedback monitor initialized for %d relays", relay_count);
    return ESP_OK;
}

/* ---- Read feedback for a single channel via CD4051 mux ---- */
static bool read_feedback(uint8_t channel) {
    /* Set mux select pins to channel */
    gpio_set_level(MUX_SEL_A_GPIO, channel & 0x01);
    gpio_set_level(MUX_SEL_B_GPIO, (channel >> 1) & 0x01);
    gpio_set_level(MUX_SEL_C_GPIO, (channel >> 2) & 0x01);

    /* Small delay for mux settle */
    vTaskDelay(pdMS_TO_TICKS(1));

    /* Read ADC — > 2048 (half of 4095) = contact closed (relay ON) */
    int raw = adc1_get_raw(MUX_ADC_CHANNEL);
    return raw > 2048;
}

/* ---- Feedback monitor task (V3-FIRMWARE §3 — priority 3, 3072 stack, core 0) ---- */
static void feedback_task(void *arg) {
    while (true) {
        for (uint8_t ch = 0; ch < g_relay_count; ch++) {
            bool commanded = relay_get(ch);
            bool actual = read_feedback(ch);

            if (commanded && !actual) {
                /* Relay fault — commanded ON but feedback OFF */
                ESP_LOGW(TAG, "Relay %d FAULT: commanded ON but contact open", ch + 1);
                /* TODO: publish alert via MQTT params/local with Relay N.Fault = true */
            } else if (!commanded && actual) {
                /* Manual override detected — wall switch toggled */
                ESP_LOGI(TAG, "Relay %d MANUAL OVERRIDE: wall switch toggled", ch + 1);
                /* Sync actual state to cloud — update node_params + publish params/local */
                relay_set(ch, true);   /* acknowledge the override */
            }
            /* Normal states (ON/ON or OFF/OFF) — no action needed */
        }
        vTaskDelay(pdMS_TO_TICKS(100));   /* poll every 100ms per V3-FIRMWARE §8 */
    }
}

esp_err_t feedback_monitor_start(void) {
    BaseType_t ret = xTaskCreatePinnedToCore(
        feedback_task, "feedback_task", 3072, NULL, 3, NULL, 0);
    if (ret != pdPASS) {
        ESP_LOGE(TAG, "Failed to create feedback_task");
        return ESP_FAIL;
    }
    ESP_LOGI(TAG, "Feedback monitor task started (priority 3, 3072 stack, core 0)");
    return ESP_OK;
}
