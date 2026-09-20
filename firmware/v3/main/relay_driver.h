/* =============================================================================
 * SHE V3 firmware — relay_driver.h
 * =============================================================================
 * PCF8574 I2C GPIO expander driver for relay control.
 * V3-FIRMWARE §8. V3-HARDWARE §4.
 * R4: 1 chip (4 channels), R8: 1 chip (8 channels), R16: 2 chips (16 channels),
 * R24: 3 chips (24 channels — 16 lights + 8 sockets). See ADR-015.
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
 *
 * Widened from uint16_t to uint32_t by ADR-015: the 24-relay board needs
 * 24 bits, which does not fit in 16. See
 * docs/ADRs/015-32bit-relay-mask-and-expander-layer.md
 */
esp_err_t relay_set_all(uint32_t bitmask);

/**
 * Get all relay states as a bitmask (32-bit, per ADR-015).
 */
uint32_t relay_get_all(void);

/**
 * Restore last relay state from NVS (persist property — V3-DEVICE-MODEL §1.5).
 * Called at boot.
 */
esp_err_t relay_restore_state(void);

/**
 * Save current relay state to NVS.
 */
esp_err_t relay_save_state(void);

/* ── Group intents (ADR-015) ───────────────────────────────────────────────
 *
 * A "master" is an intent, not a channel. These masks describe the 24-relay
 * board's layout:
 *
 *   ch  0-7   Light 1-8
 *   ch  8-15  Socket 1-8
 *   ch 16-23  Light 9-16
 *
 * Note that "lights" is deliberately NOT a contiguous range — the sockets sit
 * in the middle of them, because that is how the expanders are wired. Getting
 * this wrong is the difference between "all lights off" and "everything off".
 */
#define RELAY_GROUP_LIGHTS_R24   0x00FF00FFu   /* ch 0-7 + ch 16-23 */
#define RELAY_GROUP_SOCKETS_R24  0x0000FF00u   /* ch 8-15 */
#define RELAY_GROUP_ALL_R24      0x00FFFFFFu   /* all 24 */

/**
 * Apply an intent to a GROUP of channels without disturbing the others.
 *
 * Reads the current mask, merges in the requested group, writes back. Use this
 * for master controls; use relay_set_all() only when you mean "every channel,
 * absolutely" — a master that clobbers unrelated relays is a nasty surprise.
 */
esp_err_t relay_apply_group(uint32_t group_mask, bool on);

/**
 * Bench self-test: walk every channel ON then OFF, one at a time, logging each
 * step with its channel number and name.
 *
 * Run this first on a new board. Watch which relay actually clicks when the log
 * says "ch 8 (Socket 1)" — if the wrong one moves, the channel map or an
 * expander address is wrong, and that is much cheaper to find here than through
 * a half-working app. Leaves every relay OFF.
 *
 * @param step_delay_ms pause per step; 400 ms is enough to see and hear.
 */
esp_err_t relay_selftest(uint32_t step_delay_ms);

#ifdef __cplusplus
}
#endif

#endif /* SHE_RELAY_DRIVER_H */
