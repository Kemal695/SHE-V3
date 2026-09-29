/* =============================================================================
 * SHE V3 firmware — input_monitor.h
 * =============================================================================
 * Digital feedback via PCF8574 INPUT expanders on a second I2C bus.
 * ADR-016 (digital I2C input expanders) + ADR-017 (SHE-R24 board port).
 *
 * This is the SHE-R24 feedback source. It is NOT a variant of
 * feedback_monitor.c, which samples a CD4051 analog mux one channel at a time:
 * a PCF8574 latches all eight inputs and reads them in one transaction.
 *
 * Chip map (I2C bus 1):
 *   0  DCIN1 @0x20   DC sense 1-8
 *   1  DCIN2 @0x21   DC sense 9-16
 *   2  ACIN1 @0x22   AC load feedback for Light 1-8
 *   3  ACIN2 @0x23   AC load feedback for Light 9-16
 * ==========================================================================*/

#ifndef SHE_INPUT_MONITOR_H
#define SHE_INPUT_MONITOR_H

#include "esp_err.h"
#include "device_profiles.h"
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Chip indices — the array order is the board's, not alphabetical. */
typedef enum {
    INPUT_CHIP_DCIN1 = 0,
    INPUT_CHIP_DCIN2 = 1,
    INPUT_CHIP_ACIN1 = 2,
    INPUT_CHIP_ACIN2 = 3,
    INPUT_CHIP_COUNT = 4,
} input_chip_t;

/**
 * Install I2C bus 1 and probe the four input expanders.
 * Tolerates missing chips — one dead expander must not take the board down.
 */
esp_err_t input_monitor_init(void);

/** True if the chip answered at init. */
bool input_monitor_present(input_chip_t chip);

/** Last raw byte read from a chip (0 if absent). Bit set = pin electrically high. */
uint8_t input_monitor_raw(input_chip_t chip);

/**
 * Logical state of one input pin: true = asserted.
 *
 * Active-low is applied HERE and nowhere else, so callers never see the
 * electrical inversion. (The reference firmware returned the inverted level
 * from pcf8574_read_pin() and every call site had to remember it.)
 */
bool input_monitor_get(input_chip_t chip, uint8_t pin);

/** Refresh every present chip. Cheap: four transactions, no settling delay. */
esp_err_t input_monitor_poll(void);

/* ---- Board-level conveniences -------------------------------------------- */

/**
 * AC load feedback for a light, indexed 0-15 as "Light 1".."Light 16".
 * The lights are NOT on contiguous relay channels: light 8 lives on relay
 * channel 16 (see the R24 channel map in device_profiles.c).
 */
bool input_monitor_ac(uint8_t light_index);

/** DC sense line, indexed 0-15. */
bool input_monitor_dc(uint8_t index);

/**
 * Start the poll task: refresh every 1 s, and when an AC feedback line changes,
 * sync that light's Power param and republish params/local.
 *
 * `node` is the profile to update; it must outlive the task.
 */
esp_err_t input_monitor_start(she_node_t *node);

/* ---- 2-way (staircase) wall-switch support -------------------------------- */

/**
 * True if `channel` is one of the 16 LIGHT channels (0-7 or 16-23).
 * The sockets (8-15) have no AC sense line and stay plain switches.
 */
bool input_monitor_is_light_channel(uint8_t channel);

/**
 * Set a light ABSOLUTELY on a 2-way wall-switch circuit.
 *
 * On this bench the wall switch's travellers feed the relay's contacts, so the
 * lamp is `wall XOR relay` — the relay is a TOGGLE, not a switch. A blind
 * `relay_set(channel, on)` therefore flips the lamp RELATIVE to the wall switch,
 * which is exactly how the app's "ON" ended up turning a lamp OFF after someone
 * had used the wall switch.
 *
 * So: re-read the AC sense lines, and if the lamp is ALREADY in the requested
 * state, leave the relay ALONE. Only when it differs do we pulse the relay once —
 * and because `sensed != on`, that single flip is guaranteed to land on `on`:
 * with `lamp = wall XOR relay`, `wall = sensed XOR relay_now`, so the relay
 * target is `wall XOR on = !relay_now`.
 *
 * Returns true if the relay was pulsed, false if it was already correct.
 */
bool input_monitor_set_light_absolute(uint8_t channel, bool on);

/**
 * Absolute set for a whole GROUP (e.g. the master "Lights On/Off" mask) on a
 * 2-way wall-switch board.
 *
 * Same reasoning as [input_monitor_set_light_absolute], but for a mask: each
 * LIGHT channel is only flipped when its lamp-side AC feedback disagrees with
 * `on`; channels with no sense line (the sockets) are set directly. The target
 * RELAY state for the whole board is then written in ONE `relay_set_all()`, so
 * a master command stays atomic instead of becoming 24 separate writes.
 *
 * Returns the number of light relays that actually needed a pulse.
 */
uint8_t input_monitor_set_group_absolute(uint32_t mask, bool on);

#ifdef __cplusplus
}
#endif

#endif /* SHE_INPUT_MONITOR_H */
