# PCF8574 I2C GPIO Expander Component

Custom ESP-IDF component for the PCF8574 remote 8-bit I/O expander.
Used by SHE-R4 (1 chip, 4 channels), SHE-R8 (1 chip, 8 channels), SHE-R16 (2 chips, 16 channels).

V3-HARDWARE §4. V3-FIRMWARE §8.

## Integration

The PCF8574 driver is implemented directly in `main/relay_driver.c` (no separate component needed).
This directory is a placeholder for future extraction into a standalone component if needed.

## I2C Address

- Chip 0: `0x20` (A0/A1/A2 grounded)
- Chip 1: `0x21` (A0 high, A1/A2 grounded) — R16 only

## Active-Low Logic

PCF8574 outputs are active-low: bit = 0 → relay energized.
The `relay_driver.c` module handles this inversion transparently.
