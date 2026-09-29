/* =============================================================================
 * SHE V3 firmware — relay_driver.c
 * =============================================================================
 * PCF8574 I2C GPIO expander. V3-FIRMWARE §8. V3-HARDWARE §4.
 * Active-low: PCF8574 output bit = 0 → relay energized.
 * ==========================================================================*/

#include "relay_driver.h"
#include "nvs_keys.h"
#include "esp_log.h"
#include "esp_rom_sys.h"     /* esp_rom_delay_us — bus-settle delay in the pre-init probe */
#include "driver/i2c.h"
#include "driver/gpio.h"     /* direct-GPIO fallback when no PCF8574 is present */
#include "nvs_flash.h"
/* Explicit: relay_selftest() uses vTaskDelay(). It compiled before only because
 * driver/i2c.h pulls FreeRTOS in transitively — not something to rely on. */
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include <string.h>

static const char *TAG = "she_relay";

/* ── Expander chips ────────────────────────────────────────────────────────
 *
 * One entry per PCF8574. Previously this was a hardcoded `g_chip0_state` /
 * `g_chip1_state` pair with an `if (channel < 8) … else …` branch, which capped
 * the board at 16 relays. The 24-relay board needs a third chip, and adding it
 * that way would have meant a third variable and a third branch — with a fourth
 * chip meaning a fourth of each. (See ADR-015.)
 *
 * Channels map to chips by simple division: chip = channel / 8, pin = channel % 8.
 * That makes a fourth chip a table entry rather than new code.
 *
 * Each entry carries its own BUS. The reference firmware hardcoded I2C_NUM_1 for
 * reads and I2C_NUM_0 for writes regardless of which device was passed in, which
 * only worked because that board happened to split outputs and inputs across two
 * buses. Encoding the bus per chip makes the assumption explicit, and survives a
 * board that puts both sides on one bus. (See ADR-016.)
 *
 * Addresses: PCF8574 straps A0/A1/A2 to set its address; 0x20 = all three low.
 * This board's output banks sit at 0x24/0x26/0x25 (A2=1, A1/A0 differing) — see
 * the provenance note below before touching them.
 * Chip 2 is the 24-relay board's third output expander.
 *
 * ⚠️ ADDRESS PROVENANCE — read this before changing a number.
 *
 * The user physically straps the R24 output expanders to **0x24 / 0x25 / 0x26**
 * and has confirmed this directly ("i use 0x24 adress"). That is the value this
 * firmware must look for on the real board.
 *
 * Note the hardware spec (docs/v3-docs-final/V3-HARDWARE.md §3.2) documents the
 * ladder only up to SHE-R16 (0x20 + 0x21) and never covers a 24-channel part, so
 * for R24 the spec is silent and the **bench-strapped address wins**.
 *
 * Map (from Project X/app_main.c, which is the reference firmware for THIS
 * `SHE-IOT24-hw-v1.0` board — only its defining header is missing):
 *     pcf8574_OUT_1 -> 0x24
 *     pcf8574_OUT_3 -> 0x25      <-- note: the SECOND address is OUT_3, not OUT_2
 *     pcf8574_OUT_2 -> 0x26
 * Paired with device_profiles.c's bank order that gives:
 *     bank 0 (Light 1-8)   = OUT_1 @ 0x24
 *     bank 1 (Socket 1-8)  = OUT_2 @ 0x26
 *     bank 2 (Light 9-16)  = OUT_3 @ 0x25
 * i.e. the addresses are NOT in ascending bank order. Do not "tidy" them into
 * 0x24/0x25/0x26 = bank0/1/2 — that silently swaps the sockets and Light 9-16.
 *
 * The driver still does not trust these blindly: relay_driver_init() scans the
 * strap range first and adopts only what actually answered (see
 * relay_driver_scan_bus()). These macros are the expected map, used as the
 * tie-breaker, and a mismatch is logged loudly rather than silently applied.
 * This matters here because the board exposes a SECOND I2C bus (`SDA II`/`SCL II`)
 * with DC/AC *input*-sense expanders on it — buses 1 and 2 can answer on the same
 * strap range, so "three chips replied" is not by itself proof of the outputs.
 */
#if defined(CONFIG_SHE_R24)
/* SHE-R24 — from the board's own pcf8574.h (BUILD-R24.md §1, ADR-017). Note the
 * order is NOT ascending: 0x25 is OUT_3 (Light 9-16), 0x26 is OUT_2 (Sockets). */
#define PCF8574_ADDR_CHIP0    0x24   /* ch 0-7   (Light 1-8)   = OUT_1 */
#define PCF8574_ADDR_CHIP1    0x26   /* ch 8-15  (Socket 1-8)  = OUT_2 */
#define PCF8574_ADDR_CHIP2    0x25   /* ch 16-23 (Light 9-16)  = OUT_3 */
#else
/* R4/R8/R16 — the documented ladder in V3-HARDWARE.md §3.2. */
#define PCF8574_ADDR_CHIP0    0x20
#define PCF8574_ADDR_CHIP1    0x21
#define PCF8574_ADDR_CHIP2    0x22
#endif

/* Addresses we are willing to probe. 0x20-0x27 is the full PCF8574 A2..A0 strap
 * range, so the R24 banks at 0x24/0x25/0x26 fall inside it. Scanning the whole
 * range on every boot would be wrong for a different reason: this board also
 * carries DC/AC *input*-sense expanders (and exposes a second bus, `SDA II`/
 * `SCL II`), so blindly adopting "the first three chips that answer" could bind a
 * relay bank to an input expander. Only addresses in this range are considered,
 * and they are candidates, not conclusions. */
#define PCF8574_SCAN_FIRST     0x20
#define PCF8574_SCAN_LAST      0x27

#define RELAY_CHIPS           3
#define RELAY_CHANNELS_MAX    (RELAY_CHIPS * 8)   /* 24 */

/* Bus each output chip sits on. All outputs share one bus on this board. */
#define RELAY_CHIP_BUS        0

/* Active-low: a PCF8574 output bit of 0 energises the relay. Applied in exactly
 * one place (relay_set below) rather than at every call site — the reference
 * firmware scattered `state ? 0 : 1` everywhere and it made polarity impossible
 * to reason about. */
static uint8_t  g_chip_state[RELAY_CHIPS] = { 0xFF, 0xFF, 0xFF };
static uint8_t  g_chip_addr[RELAY_CHIPS]  = {
    PCF8574_ADDR_CHIP0, PCF8574_ADDR_CHIP1, PCF8574_ADDR_CHIP2
};
static uint8_t  g_chip_bus[RELAY_CHIPS]   = {
    RELAY_CHIP_BUS, RELAY_CHIP_BUS, RELAY_CHIP_BUS
};
static bool     g_chip_present[RELAY_CHIPS] = { false, false, false };

/* Any chip answering on the bus. Kept as a single flag because the existing
 * bring-up path (and relay_driver_is_direct_gpio fallback) keys off it. */
static bool g_pcf8574_present = false;

/* I2C pins.
 *
 * ⚠️ THE PINS DEPEND ON THE SILICON, NOT JUST THE SKU. Read this before editing.
 *
 * The V3 hardware spec (`docs/v3-docs-final/V3-HARDWARE.md` §4.2) says the
 * expanders sit on **GPIO 8 (SDA) / GPIO 9 (SCL)**, and every production SKU in
 * that spec except R4 is an **ESP32-S3**. On an S3 those pins are ordinary GPIO
 * and 8/9 is correct.
 *
 * On the **classic ESP32 (D0WD / WROOM-32)** — which is what the bench board
 * actually is (boot log: `boot.esp32:`, Multicore, rev v1.1, DIO flash) — the
 * **GPIO 6-11 group belongs to the SPI flash**. Calling `gpio_config()` or
 * `i2c_param_config()` on GPIO 8/9 re-muxes pads the live flash controller owns
 * and **hard-resets the chip instantly with NO panic output**, in an endless
 * `TG1WDT_SYS_RESET` boot loop. That was observed on real hardware on
 * 2026-09-28 and cost several flash cycles to identify.
 *
 * So: on a classic ESP32 we MUST fall back to GPIO 21/22 (the Arduino I2C
 * default; also the pins this project used before the spec was applied), and we
 * do it in code rather than by remembering, because forgetting it bricks boot.
 *
 * HISTORY / DO NOT REPEAT: this block once keyed the pins purely off the DevKit
 * flag via an #else. Because the Kconfig SKU list had no SHE_R24 entry, an R24
 * build had to start from the DevKit baseline and silently inherited 21/22 —
 * so the scan probed pins with nothing on them and the board came up as SHE-R4
 * with "0 device(s) responded". SHE_R24 is now explicit, and the classic-ESP32
 * flash-pin hazard is guarded separately so neither can regress silently.
 */
#if defined(CONFIG_SHE_R24)
/* SHE-R24 — the REAL board pins, from the board's own build guide
 * (`she-v3-r24-source/v3/BUILD-R24.md` §1 + ADR-017):
 *     output expanders, bus 0:  SDA=15 / SCL=13   (0x24/0x26/0x25)
 *     input expanders,  bus 1:  SDA=4  / SCL=5    (0x20-0x23, input_monitor.c)
 * This is a classic ESP32-D0WD, but it does NOT use the 21/22 Arduino default —
 * 15/13 are the board's own routed I2C pins. Both are outside the 6-11 flash
 * group, so they are safe. This branch MUST come first: R24 is also
 * CONFIG_IDF_TARGET_ESP32, and the classic-ESP32 branch below would otherwise
 * grab 21/22 (which is what the earlier failed attempts did). */
#define I2C_MASTER_SDA_IO     15
#define I2C_MASTER_SCL_IO     13
#define I2C_MASTER_FREQ_HZ    100000
#define I2C_MASTER_NUM        0
#elif defined(CONFIG_IDF_TARGET_ESP32)
/* Classic ESP32 (non-R24): GPIO 8/9 are flash pins and are lethal. Use 21/22. */
#define I2C_MASTER_SDA_IO     21
#define I2C_MASTER_SCL_IO     22
#define I2C_MASTER_FREQ_HZ    100000
#define I2C_MASTER_NUM        0
#elif defined(CONFIG_SHE_R16) || defined(CONFIG_SHE_R8) || defined(CONFIG_SHE_R4)
/* ESP32-S3 (and C3 for R4) production boards: spec pins are safe here. */
#define I2C_MASTER_SDA_IO     8
#define I2C_MASTER_SCL_IO     9
#define I2C_MASTER_FREQ_HZ    100000
#define I2C_MASTER_NUM        0
#elif defined(CONFIG_SHE_DEVKIT_ESP32)
#define I2C_MASTER_SDA_IO     21
#define I2C_MASTER_SCL_IO     22
#define I2C_MASTER_FREQ_HZ    100000
#define I2C_MASTER_NUM        0
#else
#error "No SHE SKU selected — set CONFIG_SHE_R4/R8/R16/R24 or CONFIG_SHE_DEVKIT_ESP32"
#endif

/* Compile-time guard: refuse to build a classic-ESP32 image that points I2C at
 * the flash pin group, whatever the SKU says. Cheap insurance against exactly
 * the hang documented above. */
#if defined(CONFIG_IDF_TARGET_ESP32) \
 && (I2C_MASTER_SDA_IO >= 6 && I2C_MASTER_SDA_IO <= 11)
#error "I2C_MASTER_SDA_IO is in the classic-ESP32 SPI-flash range (GPIO 6-11). This will hard-reset the chip with no panic. See the comment above."
#endif

static uint8_t g_relay_count = 0;

/* ---- Direct-GPIO fallback -------------------------------------------------
 *
 * When no PCF8574 is on the bus we drive these pins straight from the SoC so a
 * bare DevKit can still be exercised (e.g. metering the pins with a multimeter)
 * instead of relay writes silently doing nothing.
 *
 * ACTIVE-HIGH here, unlike the PCF8574 path: ON = 3.3 V, OFF = 0 V. That is the
 * intuitive reading for a probe and avoids the inverted-logic confusion the
 * active-low expander causes.
 *
 * GPIO 18 is normally the CD4051 mux select C for the feedback monitor, so
 * feedback_monitor_init() MUST be skipped while direct mode is active — see
 * relay_driver_is_direct_gpio() and its call site in main.c.
 *
 * NOTE on the #if guards below: the direct-GPIO *pins* only exist on a DevKit,
 * but the flag `g_direct_gpio` is referenced from functions that are compiled on
 * every SKU (relay_driver_readback, relay_driver_verify_shadow). It used to be
 * declared inside the DevKit-only block, so building any production SKU
 * (SHE_R4/R8/R16/R24) failed with "'g_direct_gpio' undeclared". The flag is now
 * always defined and simply never set true off-DevKit, which is also the honest
 * answer: "are we in direct-GPIO mode?" is false on every production board.
 */
static bool g_direct_gpio = false;   /* set true only by the DevKit fallback path */

#if defined(CONFIG_SHE_DEVKIT_ESP32)
#define DIRECT_RELAY_COUNT 4
static const int DIRECT_RELAY_PINS[DIRECT_RELAY_COUNT] = { 21, 22, 18, 19 };

/* Shadow of the levels we last drove.
 *
 * relay_get() used to read the pin back with gpio_get_level(). The pins are
 * configured GPIO_MODE_OUTPUT, which leaves the pad's input path disabled, so
 * the read-back returned 0 even while the relay was energised. relay_get_all()
 * is what relay_save_state() persists, so every save wrote "all off" and a
 * reboot always came back with every relay de-energised. The shadow is the
 * authoritative intent; it is seeded from NVS by relay_restore_state(). */
static uint16_t g_direct_state = 0;

/* Set to 1 if the driven stage inverts (ON must pull the pin LOW).
 * Default 0 = active-HIGH: ON = 3.3 V, OFF = 0 V. */
#define DIRECT_RELAY_ACTIVE_LOW 0
#endif

bool relay_driver_is_direct_gpio(void) {
    /* g_direct_gpio is false on every production SKU (it is only ever set by the
     * DevKit fallback branch in relay_driver_init), so no #if is needed here. */
    return g_direct_gpio;
}

/* Forward declarations (defined below) */
static esp_err_t pcf8574_write_raw(uint8_t bus, uint8_t addr, uint8_t data);
static esp_err_t pcf8574_read_raw(uint8_t bus, uint8_t addr, uint8_t *out);

/* ---- Safe I2C bus scan (replaces writing to guessed addresses) ------------
 *
 * Strategy: read-only probe of the strap range (a PCF8574 has no register
 * address, so a 1-byte read IS the presence test — no state is disturbed). Then:
 *   1. If all three expected addresses (0x24/0x26/0x25) answered, use them.
 *   2. Otherwise adopt the responding addresses in ascending order, but only if
 *      exactly three responded AND the board's address order is ascending.
 *      Any other count is reported and the banks are left absent.
 *
 * ⚠️ Why step 2 refuses on this board: the R24 map is NOT ascending
 * (0x24=OUT_1, 0x25=OUT_3, 0x26=OUT_2), so sorting responders positionally would
 * bind bank 1 to OUT_3 and bank 2 to OUT_2 — silently swapping the sockets with
 * Light 9-16. That is a live-loads-toggling-on-the-wrong-circuit bug, so the
 * positional fallback is only allowed when the map really is monotonic
 * (i.e. the R4/R8/R16 0x20/0x21/0x22 ladder). Otherwise we refuse and log.
 *
 * The "exactly three" guard exists because a populated board may carry more I2C
 * devices than the three relay banks — this board physically exposes a second
 * bus (`SDA II`/`SCL II`) for DC/AC input-sense expanders, and binding a relay
 * bank to a sense chip would report the wrong circuit and a later write would
 * toggle it.
 *
 * Deliberately no assignment when a bank is absent: relay_set() then returns
 * ESP_ERR_NOT_FOUND and the caller reports failure honestly, rather than
 * energising whatever is at a stale address. */
static void relay_driver_scan_bus(void) {
    uint8_t responders[PCF8574_SCAN_LAST - PCF8574_SCAN_FIRST + 1];
    uint8_t n = 0;

    for (uint8_t a = PCF8574_SCAN_FIRST; a <= PCF8574_SCAN_LAST; a++) {
        uint8_t dummy = 0;
        /* Log BEFORE the probe, not after: a bus stuck low blocks inside this
         * call, so a marker printed after it would never appear and the log would
         * look identical to a hang in the loop above. */
        ESP_LOGI(TAG, "  probing 0x%02X…", a);
        if (pcf8574_read_raw(RELAY_CHIP_BUS, a, &dummy) == ESP_OK) {
            responders[n++] = a;
            ESP_LOGI(TAG, "  → 0x%02X ACKed", a);
        }
    }

    ESP_LOGI(TAG, "I2C scan 0x%02X-0x%02X: %u device(s) responded",
             PCF8574_SCAN_FIRST, PCF8574_SCAN_LAST, (unsigned)n);

    if (n == 0) {
        ESP_LOGW(TAG, "No I2C device answered — check SDA=%d SCL=%d and 3V3",
                 I2C_MASTER_SDA_IO, I2C_MASTER_SCL_IO);
        for (int i = 0; i < RELAY_CHIPS; i++) g_chip_addr[i] = 0x00;
        return;
    }

    /* Preferred: the reference map answered verbatim. Trust it and stop. */
    const uint8_t want[RELAY_CHIPS] = {
        PCF8574_ADDR_CHIP0, PCF8574_ADDR_CHIP1, PCF8574_ADDR_CHIP2
    };
    bool exact = true;
    for (int i = 0; i < RELAY_CHIPS; i++) {
        bool seen = false;
        for (uint8_t j = 0; j < n; j++) {
            if (responders[j] == want[i]) { seen = true; break; }
        }
        if (!seen) { exact = false; break; }
    }
    if (exact) {
        ESP_LOGI(TAG, "Relay expanders match the reference map 0x%02X/0x%02X/0x%02X",
                 want[0], want[1], want[2]);
        for (int i = 0; i < RELAY_CHIPS; i++) g_chip_addr[i] = want[i];
        return;
    }

    /* Guard: positional adoption is only meaningful if the reference map is
     * ascending. On R24 it is not, and guessing would cross the banks. */
    if (!(want[0] < want[1] && want[1] < want[2])) {
        ESP_LOGE(TAG, "Expected 0x%02X/0x%02X/0x%02X all answered but they did not. "
                      "The R24 address map is non-ascending (0x24/0x26/0x25), so I will "
                      "not adopt %u responders positionally — that would swap the socket "
                      "bank with Light 9-16. Check the expander straps and whether the "
                      "chips are on the expected bus.",
                 want[0], want[1], want[2], (unsigned)n);
        for (int i = 0; i < RELAY_CHIPS; i++) g_chip_addr[i] = 0x00;
        return;
    }

    /* Fallback: only adopt a positional mapping when the bus holds EXACTLY the
     * three relay banks AND the map is ascending (R4/R8/R16). A different count
     * means sense chips are present too and we cannot tell which is which. */
    if (n == RELAY_CHIPS) {
        ESP_LOGW(TAG, "Reference addresses absent; adopting the 3 responders in "
                      "ascending order as banks 0/1/2");
        for (int i = 0; i < RELAY_CHIPS; i++) g_chip_addr[i] = responders[i];
        return;
    }

    ESP_LOGE(TAG, "%u devices on the bus but not the expected relay map — refusing to "
                  "guess which are outputs. Relay control disabled; run an I2C scan "
                  "and set PCF8574_ADDR_CHIP0/1/2 from the real board.", (unsigned)n);
    for (int i = 0; i < RELAY_CHIPS; i++) g_chip_addr[i] = 0x00;
}

/* ---- TEMPORARY bench instrument: I2C pin hunt ----------------------------
 *
 * Why this exists: the previous boot proved the configured pins (21/22) carry a
 * *live but empty* bus — both lines idle HIGH (pull-ups present) but no PCF8574
 * ACKs. The relay chips are written over I2C_NUM_0 in the vendor firmware
 * (`pcf8574_write8` → `i2c_master_write_to_device(I2C_NUM_0, …)`), so they are
 * on bus 0 — just not on whatever physical pins we assumed. The board's own
 * header (`pcf8574.h`) that named the pins is not in this repo, and the GPIO
 * silkscreen is not legible on the photo, so there is nothing left to read:
 * we have to *measure*.
 *
 * How it works: for each candidate (SDA, SCL) pair, install a throwaway I2C
 * master, read-probe 0x24/0x25/0x26 (a PCF8574 has no register pointer, so a
 * 1-byte read is a safe, non-disturbing presence test), then uninstall. Any pair
 * that sees an ACK is the relay bus. Nothing is written, so an ACK on a wrong
 * guess toggles no load.
 *
 * This runs BEFORE the real bus install and always tears its driver down, so it
 * cannot fight the production path. Remove once the true pins are known and
 * hard-coded (this is scaffolding, not a shipping feature).
 *
 * The candidate list deliberately avoids GPIO 6-11 (classic-ESP32 flash pins —
 * touching them hard-resets the chip, the bug that caused the original boot
 * loop) and inputs-only GPIO 34-39.
 *
 * COMPILED OUT by default (#if 0). It is scaffolding, kept in-tree so the survey
 * can be re-enabled with a one-line change, but NOT part of a shipping image:
 * the build that carried it was never observed to boot, and it is suspected of
 * wedging the chip. Do not re-enable without re-confirming against a known-good
 * boot first.
 */
#if 0
static const int HUNT_PINS[][2] = {
    /* {SDA, SCL} — most-likely-first */
    { 21, 22 },   /* Arduino default / current config (already proven empty) */
    { 16, 17 },   /* common board pairing */
    { 18, 19 },   /* DevKit fallback pair */
    { 25, 26 },   /* free pins */
    { 32, 33 },   /* free pins */
    { 4,  5  },   /* pins now used by the feedback mux — checked to rule out */
    { 13, 14 }, { 15, 2 }, { 12, 27 }, { 23, 5 }, { 26, 27 }, { 33, 25 },
    { 27, 14 }, { 14, 27 }, { 2,  15 }, { 17, 16 }, { 19, 18 }, { 22, 21 },
    { 23, 19 }, { 5,  17 }, { 13, 15 }, { 15, 13 },
};
#define HUNT_PIN_PAIRS (sizeof(HUNT_PINS) / sizeof(HUNT_PINS[0]))

static void relay_driver_hunt_i2c_pins(void) {
    const uint8_t probes[] = {
        PCF8574_ADDR_CHIP0, PCF8574_ADDR_CHIP1, PCF8574_ADDR_CHIP2
    };
    ESP_LOGW(TAG, "=== I2C PIN HUNT: scanning %u candidate pin pairs for the relay "
                  "expanders (0x%02X/0x%02X/0x%02X) ===",
             (unsigned)HUNT_PIN_PAIRS, probes[0], probes[1], probes[2]);

    for (size_t k = 0; k < HUNT_PIN_PAIRS; k++) {
        int sda = HUNT_PINS[k][0];
        int scl = HUNT_PINS[k][1];

        /* Never touch the classic-ESP32 flash group: it hard-resets with no panic. */
        if ((sda >= 6 && sda <= 11) || (scl >= 6 && scl <= 11)) continue;

        /* --- Electrical survey BEFORE probing ---------------------------------
         * An I2C ACK can only happen if the bus is pulled up by EXTERNAL
         * resistors — the ESP32's internal ~45k pull-ups are far too weak to
         * drive a real bus at 100 kHz, and a floating line reads HIGH in BOTH
         * cases, which is exactly the false positive that fooled the first
         * attempt: 21/22 read "idle high" only because *we* enabled the internal
         * pull-up. So sample each line twice:
         *   float : pull-up OFF -> HIGH means a real external pull-up exists
         *   pull  : pull-up ON  -> LOW  means something is actively holding it down
         * Only "float=HIGH" is evidence of a genuinely wired bus. */
        gpio_config_t off = {
            .pin_bit_mask = (1ULL << sda) | (1ULL << scl),
            .mode = GPIO_MODE_INPUT,
            .pull_up_en = GPIO_PULLUP_DISABLE,
            .pull_down_en = GPIO_PULLDOWN_DISABLE,
            .intr_type = GPIO_INTR_DISABLE,
        };
        gpio_config(&off);
        esp_rom_delay_us(2000);
        int f_sda = gpio_get_level(sda);
        int f_scl = gpio_get_level(scl);

        gpio_config_t on = off;
        on.pull_up_en = GPIO_PULLUP_ENABLE;
        gpio_config(&on);
        esp_rom_delay_us(2000);
        int p_sda = gpio_get_level(sda);
        int p_scl = gpio_get_level(scl);

        ESP_LOGI(TAG, "  [SDA=%d SCL=%d] float(SDA=%d SCL=%d) with-pullup(SDA=%d SCL=%d)%s",
                 sda, scl, f_sda, f_scl, p_sda, p_scl,
                 (f_sda && f_scl) ? "  <-- EXTERNAL PULL-UPS PRESENT" : "");

        i2c_config_t c = {
            .mode = I2C_MODE_MASTER,
            .sda_io_num = sda,
            .scl_io_num = scl,
            .sda_pullup_en = GPIO_PULLUP_ENABLE,
            .scl_pullup_en = GPIO_PULLUP_ENABLE,
            .master.clk_speed = 100000,
        };
        if (i2c_param_config(I2C_MASTER_NUM, &c) != ESP_OK) {
            ESP_LOGW(TAG, "  [SDA=%d SCL=%d] param_config failed", sda, scl);
            continue;
        }
        if (i2c_driver_install(I2C_MASTER_NUM, c.mode, 0, 0, 0) != ESP_OK) {
            ESP_LOGW(TAG, "  [SDA=%d SCL=%d] driver_install failed", sda, scl);
            continue;
        }

        int hits = 0;
        char hit_list[48] = {0};
        for (size_t p = 0; p < sizeof(probes); p++) {
            uint8_t dummy = 0;
            if (pcf8574_read_raw(I2C_MASTER_NUM, probes[p], &dummy) == ESP_OK) {
                hits++;
                size_t len = strlen(hit_list);
                snprintf(hit_list + len, sizeof(hit_list) - len, " 0x%02X", probes[p]);
            }
        }
        ESP_LOGI(TAG, "  [SDA=%d SCL=%d] %d/%u relay addr(s) ACKed%s",
                 sda, scl, hits, (unsigned)sizeof(probes),
                 hits ? hit_list : "");

        i2c_driver_delete(I2C_MASTER_NUM);
        vTaskDelay(pdMS_TO_TICKS(10));
    }
    ESP_LOGW(TAG, "=== I2C PIN HUNT done — a pair with EXTERNAL PULL-UPS + hits>0 is "
                  "the relay bus; if NONE has external pull-ups, the expanders are "
                  "unpowered or on a bus wired to different pins ===");
}
#endif /* 0 — hunt compiled out; see the note above */

esp_err_t relay_driver_init(uint8_t relay_count) {
    g_relay_count = relay_count;
    ESP_LOGI(TAG, "Initializing PCF8574 for %d relays (SDA=%d SCL=%d)",
             relay_count, I2C_MASTER_SDA_IO, I2C_MASTER_SCL_IO);

    /* TEMPORARY: locate the real bus pins before trusting the configured ones.
     * Disabled while recovering the board — the survey build is suspected of
     * wedging the chip (never booted cleanly). Re-enable deliberately once the
     * known-good image is confirmed booting again. */
    /* relay_driver_hunt_i2c_pins(); */

    /* ---- Pre-init bus health check (plain GPIO, BEFORE the I2C peripheral) ----
     *
     * Why this exists: a previous boot printed this init line and then hung; the
     * task watchdog reset the chip in a loop and no panic ever appeared. That
     * symptom is indistinguishable between "the I2C peripheral blocked" and "the
     * bus is physically stuck", so sample the two lines as plain inputs first.
     *
     * A healthy IDLE I2C bus reads HIGH on both lines (pull-ups dominate). If
     * either reads LOW with the pins released, something is holding it down —
     * no pull-ups fitted, a short, a chip held in reset, or the expanders not
     * actually wired to these GPIOs. That is a hardware finding, and it is far
     * more useful than a watchdog loop.
     *
     * Safe now that the pin-selection block above refuses to put I2C on the
     * classic-ESP32 flash group (GPIO 6-11). If those pins were ever selected,
     * touching them here would reset the chip with no panic. */
    {
        gpio_config_t probe = {
            .pin_bit_mask = (1ULL << I2C_MASTER_SDA_IO) | (1ULL << I2C_MASTER_SCL_IO),
            .mode = GPIO_MODE_INPUT,
            .pull_up_en = GPIO_PULLUP_ENABLE,   /* internal weak pull-up */
            .pull_down_en = GPIO_PULLDOWN_DISABLE,
            .intr_type = GPIO_INTR_DISABLE,
        };
        gpio_config(&probe);
        esp_rom_delay_us(2000);                 /* let the lines settle */
        int sda = gpio_get_level(I2C_MASTER_SDA_IO);
        int scl = gpio_get_level(I2C_MASTER_SCL_IO);
        ESP_LOGI(TAG, "I2C idle levels: SDA(GPIO%d)=%d SCL(GPIO%d)=%d",
                 I2C_MASTER_SDA_IO, sda, I2C_MASTER_SCL_IO, scl);
        if (sda == 0 || scl == 0) {
            ESP_LOGE(TAG, "I2C bus is STUCK LOW (SDA=%d SCL=%d) before any transfer. "
                          "Check: 3V3 present, pull-ups fitted, expanders actually on "
                          "GPIO %d/%d, no short. Continuing — the scan will fail fast.",
                     sda, scl, I2C_MASTER_SDA_IO, I2C_MASTER_SCL_IO);
        } else {
            ESP_LOGI(TAG, "I2C bus idle-high — wiring looks electrically sane, probing");
        }
        gpio_reset_pin(I2C_MASTER_SDA_IO);
        gpio_reset_pin(I2C_MASTER_SCL_IO);
    }

    i2c_config_t conf = {
        .mode = I2C_MODE_MASTER,
        .sda_io_num = I2C_MASTER_SDA_IO,
        .scl_io_num = I2C_MASTER_SCL_IO,
        .sda_pullup_en = GPIO_PULLUP_ENABLE,
        .scl_pullup_en = GPIO_PULLUP_ENABLE,
        .master.clk_speed = I2C_MASTER_FREQ_HZ,
    };
    /* Fine-grained progress logs. A previous boot hung with this init message as
     * the LAST line ever printed and no panic — the watchdog simply reset the chip
     * in a loop. Without a marker either side of each call there is no way to tell
     * a hang in i2c_param_config from one in i2c_driver_install from one in the bus
     * scan. These make that unambiguous, and they are cheap. */
    ESP_LOGI(TAG, "[i2c] param_config…");
    ESP_ERROR_CHECK(i2c_param_config(I2C_MASTER_NUM, &conf));
    ESP_LOGI(TAG, "[i2c] driver_install…");
    ESP_ERROR_CHECK(i2c_driver_install(I2C_MASTER_NUM, conf.mode, 0, 0, 0));
    ESP_LOGI(TAG, "[i2c] installed; scanning bus…");

    /* Probe every expander. Tolerate missing chips — dev bring-up without
     * peripherals, loose wiring, or one dead chip on a 24-relay board. Boot must
     * continue and the working chips must keep working; that is why each is
     * probed individually rather than assuming they are all-or-nothing.
     *
     * Nothing is written before the scan: see pcf8574_scan_bus(). Writing 0xFF
     * to a guessed address is how the previous version could have driven the
     * wrong circuit on a real board. */
    relay_driver_scan_bus();

    uint8_t found = 0;
    for (int i = 0; i < RELAY_CHIPS; i++) {
        g_chip_present[i] = (g_chip_addr[i] != 0x00);
        if (g_chip_present[i]) {
            found++;
            ESP_LOGI(TAG, "Relay expander %d = 0x%02X (ch %d-%d)",
                     i, g_chip_addr[i], i * 8, i * 8 + 7);
        } else {
            ESP_LOGW(TAG, "Relay expander %d not found — its 8 channels "
                          "will report as unavailable", i);
        }
    }
    g_pcf8574_present = (found > 0);
    ESP_LOGI(TAG, "%u/%d expanders responded", (unsigned)found, RELAY_CHIPS);

#if defined(CONFIG_SHE_DEVKIT_ESP32)
    if (!g_pcf8574_present) {
        /* No expander: take the I2C pins back and drive relays directly, so the
         * app's toggles produce a measurable pin change instead of a silent
         * no-op. Requires releasing the I2C driver first — it owns 21/22. */
        ESP_LOGW(TAG, "PCF8574 NOT FOUND at 0x%02X — falling back to DIRECT GPIO on "
                      "21/22/18/19 (active-HIGH: ON = 3.3V)",
                 PCF8574_ADDR_CHIP0);        i2c_driver_delete(I2C_MASTER_NUM);

        gpio_config_t io_conf = {
            .pin_bit_mask = 0,
            .mode = GPIO_MODE_OUTPUT,
            .pull_up_en = GPIO_PULLUP_DISABLE,
            .pull_down_en = GPIO_PULLDOWN_DISABLE,
            .intr_type = GPIO_INTR_DISABLE,
        };
        for (int i = 0; i < DIRECT_RELAY_COUNT; i++) {
            /* gpio_reset_pin() first: 21/22 were driven by the I2C peripheral, and
             * gpio_config() alone does not necessarily detach the IO-matrix routing —
             * leaving the pin controlled by I2C instead of our output register. */
            gpio_reset_pin(DIRECT_RELAY_PINS[i]);
            io_conf.pin_bit_mask |= (1ULL << DIRECT_RELAY_PINS[i]);
        }
        gpio_config(&io_conf);
        for (int i = 0; i < DIRECT_RELAY_COUNT; i++) {
            gpio_set_level(DIRECT_RELAY_PINS[i], 0);   /* all off */
        }

        g_direct_gpio = true;
        g_relay_count = DIRECT_RELAY_COUNT;
        ESP_LOGI(TAG, "Direct GPIO relay mode: %d channels on GPIO %d/%d/%d/%d",
                 DIRECT_RELAY_COUNT,
                 DIRECT_RELAY_PINS[0], DIRECT_RELAY_PINS[1],
                 DIRECT_RELAY_PINS[2], DIRECT_RELAY_PINS[3]);
        return ESP_OK;
    }
#endif

    if (!g_pcf8574_present) {
        ESP_LOGW(TAG, "PCF8574 NOT FOUND at 0x%02X on SDA=%d SCL=%d — "
                 "relay writes disabled, boot continues",
                 PCF8574_ADDR_CHIP0, I2C_MASTER_SDA_IO, I2C_MASTER_SCL_IO);
    }

    /* Set all relays off (PCF8574 outputs high = relays de-energized, active-low) */
    for (int i = 0; i < RELAY_CHIPS; i++) {
        g_chip_state[i] = 0xFF;
    }
    relay_set_all(0);

    ESP_LOGI(TAG, "PCF8574 initialized (present=%d, %u chips) — all relays OFF",
             g_pcf8574_present, (unsigned)found);
    return ESP_OK;
}

static esp_err_t pcf8574_write_raw(uint8_t bus, uint8_t addr, uint8_t data) {
    i2c_cmd_handle_t cmd = i2c_cmd_link_create();
    i2c_master_start(cmd);
    i2c_master_write_byte(cmd, (addr << 1) | I2C_MASTER_WRITE, true);
    i2c_master_write_byte(cmd, data, true);
    i2c_master_stop(cmd);
    esp_err_t err = i2c_master_cmd_begin(bus, cmd, pdMS_TO_TICKS(100));
    i2c_cmd_link_delete(cmd);
    return err;
}

/* Presence-gated write — no-op (with warning) when the chip is absent */
/**
 * Read one byte from a PCF8574.
 *
 * A PCF8574 has no register address and no pin select: you read the whole port
 * in one transaction and mask. That is why the input side (ADR-016) reads eight
 * inputs at once rather than one at a time like the CD4051 mux path does.
 *
 * Also used to read back the OUTPUT expanders. A write can be ACKed and still
 * not stick — a bad solder joint on a PCF8574's pins, or a chip that resets
 * itself — and the only way to tell is to read what it actually holds. That is
 * what relay_driver_readback() below is for.
 */
static esp_err_t pcf8574_read_raw(uint8_t bus, uint8_t addr, uint8_t *out) {
    if (out == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    i2c_cmd_handle_t cmd = i2c_cmd_link_create();
    i2c_master_start(cmd);
    i2c_master_write_byte(cmd, (addr << 1) | I2C_MASTER_READ, true);
    uint8_t data = 0;
    i2c_master_read_byte(cmd, &data, I2C_MASTER_NACK);
    i2c_master_stop(cmd);
    esp_err_t err = i2c_master_cmd_begin(bus, cmd, pdMS_TO_TICKS(100));
    i2c_cmd_link_delete(cmd);
    if (err == ESP_OK) {
        *out = data;
    }
    return err;
}

static esp_err_t pcf8574_write(uint8_t bus, uint8_t addr, uint8_t data) {
    if (!g_pcf8574_present) {
        return ESP_ERR_NOT_FOUND;
    }
    esp_err_t err = pcf8574_write_raw(bus, addr, data);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "PCF8574 write failed (addr 0x%02X): %s", addr, esp_err_to_name(err));
    }
    return err;
}

esp_err_t relay_set(uint8_t channel, bool on) {
    if (channel >= g_relay_count) return ESP_ERR_INVALID_ARG;

#if defined(CONFIG_SHE_DEVKIT_ESP32)
    if (g_direct_gpio) {
#if DIRECT_RELAY_ACTIVE_LOW
        const int level = on ? 0 : 1;   /* inverting stage */
#else
        const int level = on ? 1 : 0;   /* active-HIGH: ON = 3.3 V */
#endif
        esp_err_t e = gpio_set_level(DIRECT_RELAY_PINS[channel], level);
        if (on) g_direct_state |=  (1u << channel);
        else    g_direct_state &= ~(1u << channel);
        /* Log the level actually driven — the only way to tell a firmware polarity
         * mistake apart from an inverting stage on the PCB. */
        ESP_LOGI(TAG, "direct ch=%u pin=%d on=%d level=%d mask=0x%04X",
                 (unsigned)channel, DIRECT_RELAY_PINS[channel], (int)on, level,
                 (unsigned)g_direct_state);
        return e;
    }
#endif

    /* chip = channel / 8, pin = channel % 8. Active-low: bit 0 → relay ON.
     * Polarity is applied HERE and nowhere else (see ADR-015). */
    const uint8_t chip = channel / 8;
    const uint8_t bit  = (uint8_t)(1u << (channel % 8));

    if (chip >= RELAY_CHIPS) return ESP_ERR_INVALID_ARG;
    if (!g_chip_present[chip]) return ESP_ERR_NOT_FOUND;

    if (on) g_chip_state[chip] &= ~bit;
    else    g_chip_state[chip] |= bit;

    return pcf8574_write(g_chip_bus[chip], g_chip_addr[chip], g_chip_state[chip]);
}

bool relay_get(uint8_t channel) {
    if (channel >= g_relay_count) return false;

#if defined(CONFIG_SHE_DEVKIT_ESP32)
    if (g_direct_gpio) {
        /* Shadow, not pin read-back: the input path is disabled in
         * GPIO_MODE_OUTPUT, so gpio_get_level() always reported 0. */
        return (g_direct_state >> channel) & 1u;
    }
#endif

    const uint8_t chip = channel / 8;
    const uint8_t bit  = (uint8_t)(1u << (channel % 8));
    if (chip >= RELAY_CHIPS) return false;
    /* Active-low: bit = 0 means relay ON */
    return (g_chip_state[chip] & bit) == 0;
}

esp_err_t relay_set_all(uint32_t bitmask) {
#if defined(CONFIG_SHE_DEVKIT_ESP32)
    if (g_direct_gpio) {
        g_direct_state = (uint16_t)bitmask;
        for (int i = 0; i < g_relay_count && i < DIRECT_RELAY_COUNT; i++) {
            const int on = (bitmask & (1u << i)) ? 1 : 0;
#if DIRECT_RELAY_ACTIVE_LOW
            gpio_set_level(DIRECT_RELAY_PINS[i], on ? 0 : 1);
#else
            gpio_set_level(DIRECT_RELAY_PINS[i], on);
#endif
        }
        ESP_LOGI(TAG, "direct set_all mask=0x%04X", (unsigned)g_direct_state);
        return ESP_OK;
    }
#endif

    /* Build one byte per chip from the requested mask, then write each present
     * chip. Previously this was hardcoded to two chips; it is now a loop, so a
     * third (or fourth) expander needs no new code. (See ADR-015.) */
    esp_err_t first_err = ESP_OK;
    for (int c = 0; c < RELAY_CHIPS; c++) {
        uint8_t byte = 0xFF;   /* all off (active-low: 1 = relay OFF) */
        for (int p = 0; p < 8; p++) {
            const int ch = c * 8 + p;
            if (ch < (int)g_relay_count && (bitmask & (1u << ch))) {
                byte &= ~(1u << p);   /* clear the bit = relay ON */
            }
        }
        g_chip_state[c] = byte;
    }

    /* CRITICAL: write every present chip unconditionally — even when bitmask=0.
     * A partial write would leave a chip holding its previous state, which is
     * how a "turn everything off" ends up leaving one bank energised. */
    for (int c = 0; c < RELAY_CHIPS; c++) {
        if (!g_chip_present[c]) continue;
        esp_err_t e = pcf8574_write(g_chip_bus[c], g_chip_addr[c], g_chip_state[c]);
        if (e != ESP_OK && first_err == ESP_OK) first_err = e;
    }
    return first_err;
}

uint32_t relay_get_all(void) {
    uint32_t mask = 0;
    for (int i = 0; i < g_relay_count && i < RELAY_CHANNELS_MAX; i++) {
        if (relay_get((uint8_t)i)) mask |= (1u << i);
    }
    return mask;
}

/**
 * Read back what an output expander ACTUALLY holds, as opposed to what we last
 * wrote to it.
 *
 * The shadow (g_chip_state) records intent. If a chip ACKs a write but does not
 * hold it — dry joint on its pins, chip browning out, address collision with
 * another device on the bus — the shadow and reality diverge and nothing else
 * would notice: relay_get() would keep reporting the intended state and the
 * server would keep showing it. This is the function that can tell.
 *
 * @param chip   0..RELAY_CHIPS-1
 * @param actual receives the byte read from the chip
 * @return ESP_OK, ESP_ERR_INVALID_ARG, or ESP_ERR_NOT_FOUND if that chip was
 *         never seen on the bus at init.
 */
esp_err_t relay_driver_readback(uint8_t chip, uint8_t *actual) {
    if (actual == NULL || chip >= RELAY_CHIPS) {
        return ESP_ERR_INVALID_ARG;
    }
    if (g_direct_gpio || !g_chip_present[chip]) {
        return ESP_ERR_NOT_FOUND;
    }
    return pcf8574_read_raw(g_chip_bus[chip], g_chip_addr[chip], actual);
}

/**
 * Compare every present output expander against its shadow.
 *
 * @param first_mismatch set to the first chip whose read-back disagrees with
 *        what we wrote, or -1 if all agree. May be NULL.
 * @return ESP_OK if every present chip agrees, ESP_ERR_INVALID_STATE on any
 *         mismatch, or the first bus error encountered.
 *
 * NOT called anywhere yet — kept as the diagnostic hook for bringing up real
 * expander hardware, where a silently-not-holding chip is the failure mode that
 * otherwise presents as "the relay clicks but nothing switches".
 */
esp_err_t relay_driver_verify_shadow(int *first_mismatch) {
    if (first_mismatch) *first_mismatch = -1;
    if (g_direct_gpio) {
        return ESP_OK;   /* no expanders in this mode */
    }
    for (uint8_t c = 0; c < RELAY_CHIPS; c++) {
        if (!g_chip_present[c]) continue;
        uint8_t actual = 0;
        esp_err_t err = pcf8574_read_raw(g_chip_bus[c], g_chip_addr[c], &actual);
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "readback failed for chip %u @0x%02X: %s",
                     c, g_chip_addr[c], esp_err_to_name(err));
            return err;
        }
        if (actual != g_chip_state[c]) {
            ESP_LOGE(TAG, "chip %u @0x%02X mismatch: wrote 0x%02X, reads 0x%02X",
                     c, g_chip_addr[c], g_chip_state[c], actual);
            if (first_mismatch) *first_mismatch = (int)c;
            return ESP_ERR_INVALID_STATE;
        }
    }
    return ESP_OK;
}

esp_err_t relay_restore_state(void) {
    nvs_handle_t h;
    esp_err_t err = nvs_open(SHE_NVS_NAMESPACE, NVS_READONLY, &h);
    if (err != ESP_OK) return err;
    /* 24 channels need 32 bits — this was nvs_get_u16 before ADR-015, which
     * silently truncated the upper bank on a 24-relay board. */
    uint32_t state = 0;
    err = nvs_get_u32(h, SHE_NVS_KEY_RELAY_STATE, &state);
    nvs_close(h);
    if (err != ESP_OK) return err;
    ESP_LOGI(TAG, "Restoring relay state: 0x%06lX", (unsigned long)state);
    return relay_set_all(state);
}

esp_err_t relay_save_state(void) {
    nvs_handle_t h;
    esp_err_t err = nvs_open(SHE_NVS_NAMESPACE, NVS_READWRITE, &h);
    if (err != ESP_OK) return err;
    uint32_t state = relay_get_all();
    nvs_set_u32(h, SHE_NVS_KEY_RELAY_STATE, state);
    nvs_commit(h);
    nvs_close(h);
    ESP_LOGI(TAG, "Saved relay state mask=0x%06lX", (unsigned long)state);
    return ESP_OK;
}

esp_err_t relay_apply_group(uint32_t group_mask, bool on) {
    /* Read-modify-write so a master control cannot disturb channels outside its
     * group. relay_set_all() would clobber everything, which is why "all lights
     * off" must not be implemented with it on this board — the sockets would go
     * off too. */
    const uint32_t current = relay_get_all();
    const uint32_t next = on ? (current | group_mask) : (current & ~group_mask);

    ESP_LOGI(TAG, "group 0x%06lX -> %s (mask 0x%06lX -> 0x%06lX)",
             (unsigned long)group_mask, on ? "ON" : "OFF",
             (unsigned long)current, (unsigned long)next);

    return relay_set_all(next);
}

esp_err_t relay_selftest(uint32_t step_delay_ms) {
    ESP_LOGW(TAG, "=== RELAY SELF-TEST: %u channels, %ums per step ===",
             (unsigned)g_relay_count, (unsigned)step_delay_ms);
    ESP_LOGW(TAG, "Watch which relay clicks as each channel is named below.");

    for (uint8_t ch = 0; ch < g_relay_count; ch++) {
        const uint8_t chip = ch / 8;
        const uint8_t pin  = ch % 8;

        ESP_LOGW(TAG, "  ch %2u  (expander %u @0x%02X, pin %u)  -> ON",
                 ch, chip, g_chip_addr[chip], pin);
        relay_set(ch, true);
        vTaskDelay(pdMS_TO_TICKS(step_delay_ms));

        relay_set(ch, false);
        vTaskDelay(pdMS_TO_TICKS(step_delay_ms / 2));
    }

    /* Leave everything off regardless of how we got here — a self-test that
     * ends with a relay energised is a self-test nobody will run twice. */
    relay_set_all(0);
    ESP_LOGW(TAG, "=== SELF-TEST DONE — all relays OFF ===");
    return ESP_OK;
}
