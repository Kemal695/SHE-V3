/* =============================================================================
 * SHE V3 firmware — voice_control.c
 * =============================================================================
 * Picovoice offline voice control. SHE-R16 only.
 * V3-FIRMWARE §10. V3-VOICE-MATTER §1.4.
 *
 * Phase 1: stub implementation — full Picovoice integration in Phase 4C.
 * ==========================================================================*/

#ifdef CONFIG_SHE_R16

#include "voice_control.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "she_voice";

static void voice_task(void *arg) {
    ESP_LOGI(TAG, "Voice task started — listening for 'Hey Sheba' (Porcupine)");
    ESP_LOGI(TAG, "Intent model: SmartHome_Ethiopian (~25 Amharic + English intents)");

    /* TODO: Picovoice SDK init
     *   1. pv_porcupine_init() with custom "Hey Sheba" model (Picovoice Console-trained)
     *   2. pv_rhino_init() with SmartHome_Ethiopian context (.rhn file)
     *   3. I2S read loop (INMP441, 16kHz, 16-bit mono)
     *   4. pv_porcupine_process() — wake word detection
     *   5. On wake: pv_rhino_process() — intent inference
     *   6. Map intent to relay action (turn_on, turn_off, activate_scene)
     */

    while (true) {
        vTaskDelay(pdMS_TO_TICKS(1000));
        /* Stub — no audio processing in Phase 1 */
    }
}

esp_err_t voice_control_init(void) {
    ESP_LOGI(TAG, "Initializing Picovoice SDK (R16 only)");
    /* TODO: load Porcupine model + Rhino context from flash */
    /* TODO: init I2S for INMP441 (BCLK=GPIO4, WS=GPIO5, DATA=GPIO6) */
    return ESP_OK;
}

esp_err_t voice_control_start(void) {
    BaseType_t ret = xTaskCreatePinnedToCore(
        voice_task, "voice_task", 8192, NULL, 3, NULL, 1);   /* core 1 */
    if (ret != pdPASS) {
        ESP_LOGE(TAG, "Failed to create voice_task");
        return ESP_FAIL;
    }
    ESP_LOGI(TAG, "Voice task started (priority 3, 8192 stack, core 1)");
    return ESP_OK;
}

#endif /* CONFIG_SHE_R16 */
