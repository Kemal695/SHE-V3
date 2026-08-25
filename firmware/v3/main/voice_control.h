/* =============================================================================
 * SHE V3 firmware — voice_control.h
 * =============================================================================
 * Picovoice offline voice control. SHE-R16 only.
 * V3-FIRMWARE §10. V3-VOICE-MATTER §1.4. ADR-006.
 * Wake word: "Hey Sheba" (custom Porcupine model).
 * Intent model: ~25 Amharic + English intents.
 * ==========================================================================*/

#ifndef SHE_VOICE_CONTROL_H
#define SHE_VOICE_CONTROL_H

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#ifdef CONFIG_SHE_R16

/**
 * Initialize Picovoice SDK (Porcupine wake word + Rhino intent).
 * Loads custom "Hey Sheba" Porcupine model + SmartHome_Ethiopian Rhino context.
 */
esp_err_t voice_control_init(void);

/**
 * Start the voice_control FreeRTOS task (priority 3, 8192 stack, core 1).
 * Listens via INMP441 I2S mic, fires on "Hey Sheba" wake word.
 */
esp_err_t voice_control_start(void);

#endif /* CONFIG_SHE_R16 */

#ifdef __cplusplus
}
#endif

#endif /* SHE_VOICE_CONTROL_H */
