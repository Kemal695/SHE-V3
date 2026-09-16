/* =============================================================================
 * SHE V3 firmware — relay_driver.h
 * =============================================================================
 * PCF8574 I2C GPIO expander driver for relay control.
 * V3-FIRMWARE §8. V3-HARDWARE §4.
 * R4: 1 chip (4 channels), R8: 1 chip (8 channels), R16: 2 chips (16 channels).
 * ==========================================================================*/

#ifndef SHE_RELAY_DRIVER_H
#define SHE_RELAY_DRIVER_H

#include "esp_err.h"
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Initialize PCF8574 I2C expander(s).
 * R4/R8: 1 chip at I2C address 0x20. R16: 2 chips at 0x20 + 0x21.
 */
esp_err_t relay_driver_init(uint8_t relay_count);

/**
 * True when no PCF8574 was found and the driver fell back to driving
 * GPIO 21/22/18/19 directly (DevKit builds only).
 *
 * Callers that would otherwise claim those pins MUST check this: the feedback
 * monitor uses GPIO 18 as its CD4051 mux-select C, which would fight the relay
 * output. See the call site in main.c.
 */
bool relay_driver_is_direct_gpio(void);

/**
 * Set a single relay channel state.
 * @param channel 0-15
 * @param on true = relay energized, false = de-energized
 */
esp_err_t relay_set(uint8_t channel, bool on);

/**
 * Get a single relay channel's commanded state (not feedback).
 */
bool relay_get(uint8_t channel);

/**
 * Set all relays at once from a bitmask.
 * Bit 0 = Relay 1, Bit 1 = Relay 2, etc.
 */
esp_err_t relay_set_all(uint16_t bitmask);

/**
 * Get all relay states as a bitmask.
 */
uint16_t relay_get_all(void);

/**
 * Restore last relay state from NVS (persist property — V3-DEVICE-MODEL §1.5).
 * Called at boot.
 */
esp_err_t relay_restore_state(void);

/**
 * Save current relay state to NVS.
 */
esp_err_t relay_save_state(void);

#ifdef __cplusplus
}
#endif

#endif /* SHE_RELAY_DRIVER_H */
