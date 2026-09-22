/* =============================================================================
 * SHE V3 firmware — relay_driver.c
 * =============================================================================
 * PCF8574 I2C GPIO expander. V3-FIRMWARE §8. V3-HARDWARE §4.
 * Active-low: PCF8574 output bit = 0 → relay energized.
 * ==========================================================================*/

#include "relay_driver.h"
#include "nvs_keys.h"
#include "esp_log.h"
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
 * Chip 2 is the 24-relay board's third output expander.
 *
 * ⚠️ The ADDRESSES BELOW ARE ASSUMED. 0x20/0x21 came from the pre-existing file;
 * 0x22 is a guess. A wrong address writes to whatever chip IS at that address —
 * on a relay board, the wrong circuit. Confirm against the board's pcf8574.h
 * before flashing anything that drives real expanders.
 */
#define PCF8574_ADDR_CHIP0    0x20
#define PCF8574_ADDR_CHIP1    0x21
#define PCF8574_ADDR_CHIP2    0x22

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

/* I2C pins: production SKUs use GPIO 8/9. Classic ESP32-D0WD DevKit uses
 * GPIO 21/22 — GPIO 6-11 on ESP32-D0WD are wired to the integrated SPI
 * flash and MUST NOT be repurposed (bus hangs + WDT reset). */
#if defined(CONFIG_SHE_DEVKIT_ESP32)
#define I2C_MASTER_SDA_IO     21
#define I2C_MASTER_SCL_IO     22
#define I2C_MASTER_FREQ_HZ    100000
#define I2C_MASTER_NUM        0
#else
#define I2C_MASTER_SDA_IO     8
#define I2C_MASTER_SCL_IO     9
#define I2C_MASTER_FREQ_HZ    100000
#define I2C_MASTER_NUM        0
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
 */
#if defined(CONFIG_SHE_DEVKIT_ESP32)
#define DIRECT_RELAY_COUNT 4
static const int DIRECT_RELAY_PINS[DIRECT_RELAY_COUNT] = { 21, 22, 18, 19 };
static bool g_direct_gpio = false;

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
#if defined(CONFIG_SHE_DEVKIT_ESP32)
    return g_direct_gpio;
#else
    return false;
#endif
}

/* Forward declaration (defined below) */
static esp_err_t pcf8574_write_raw(uint8_t bus, uint8_t addr, uint8_t data);

esp_err_t relay_driver_init(uint8_t relay_count) {
    g_relay_count = relay_count;
    ESP_LOGI(TAG, "Initializing PCF8574 for %d relays (SDA=%d SCL=%d)",
             relay_count, I2C_MASTER_SDA_IO, I2C_MASTER_SCL_IO);

    i2c_config_t conf = {
        .mode = I2C_MODE_MASTER,
        .sda_io_num = I2C_MASTER_SDA_IO,
        .scl_io_num = I2C_MASTER_SCL_IO,
        .sda_pullup_en = GPIO_PULLUP_ENABLE,
        .scl_pullup_en = GPIO_PULLUP_ENABLE,
        .master.clk_speed = I2C_MASTER_FREQ_HZ,
    };
    ESP_ERROR_CHECK(i2c_param_config(I2C_MASTER_NUM, &conf));
    ESP_ERROR_CHECK(i2c_driver_install(I2C_MASTER_NUM, conf.mode, 0, 0, 0));

    /* Probe every expander. Tolerate missing chips — dev bring-up without
     * peripherals, loose wiring, or one dead chip on a 24-relay board. Boot must
     * continue and the working chips must keep working; that is why each is
     * probed individually rather than assuming they are all-or-nothing. */
    uint8_t found = 0;
    for (int i = 0; i < RELAY_CHIPS; i++) {
        g_chip_present[i] = (pcf8574_write_raw(g_chip_bus[i], g_chip_addr[i], 0xFF) == ESP_OK);
        if (g_chip_present[i]) {
            found++;
        } else {
            ESP_LOGW(TAG, "PCF8574 chip %d @0x%02X not found — its 8 channels "
                          "will report as unavailable", i, g_chip_addr[i]);
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
                 PCF8574_ADDR_CHIP0);
        i2c_driver_delete(I2C_MASTER_NUM);

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
