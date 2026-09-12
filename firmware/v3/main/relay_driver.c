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
#include "nvs_flash.h"
#include <string.h>

static const char *TAG = "she_relay";

/* PCF8574 I2C addresses (A0/A1/A2 grounded = 0x20) */
#define PCF8574_ADDR_CHIP0    0x20
#define PCF8574_ADDR_CHIP1    0x21

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
static uint8_t g_chip0_state = 0xFF;   /* PCF8574 powers up high (relays off) */
static uint8_t g_chip1_state = 0xFF;
static bool g_pcf8574_present = false; /* set by probe in relay_driver_init */

/* Forward declaration (defined below) */
static esp_err_t pcf8574_write_raw(uint8_t addr, uint8_t data);

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

    /* Probe the expander — tolerate a missing chip (dev bring-up without
     * peripherals, loose wiring). Boot must continue; writes become no-ops. */
    g_pcf8574_present = (pcf8574_write_raw(PCF8574_ADDR_CHIP0, 0xFF) == ESP_OK);
    if (!g_pcf8574_present) {
        ESP_LOGW(TAG, "PCF8574 NOT FOUND at 0x%02X on SDA=%d SCL=%d — "
                 "relay writes disabled, boot continues",
                 PCF8574_ADDR_CHIP0, I2C_MASTER_SDA_IO, I2C_MASTER_SCL_IO);
    }

    /* Set all relays off (PCF8574 outputs high = relays de-energized, active-low) */
    g_chip0_state = 0xFF;
    g_chip1_state = 0xFF;
    relay_set_all(0);

    ESP_LOGI(TAG, "PCF8574 initialized (present=%d) — all relays OFF", g_pcf8574_present);
    return ESP_OK;
}

static esp_err_t pcf8574_write_raw(uint8_t addr, uint8_t data) {
    i2c_cmd_handle_t cmd = i2c_cmd_link_create();
    i2c_master_start(cmd);
    i2c_master_write_byte(cmd, (addr << 1) | I2C_MASTER_WRITE, true);
    i2c_master_write_byte(cmd, data, true);
    i2c_master_stop(cmd);
    esp_err_t err = i2c_master_cmd_begin(I2C_MASTER_NUM, cmd, pdMS_TO_TICKS(100));
    i2c_cmd_link_delete(cmd);
    return err;
}

/* Presence-gated write — no-op (with warning) when the chip is absent */
static esp_err_t pcf8574_write(uint8_t addr, uint8_t data) {
    if (!g_pcf8574_present) {
        return ESP_ERR_NOT_FOUND;
    }
    esp_err_t err = pcf8574_write_raw(addr, data);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "PCF8574 write failed (addr 0x%02X): %s", addr, esp_err_to_name(err));
    }
    return err;
}

esp_err_t relay_set(uint8_t channel, bool on) {
    if (channel >= g_relay_count) return ESP_ERR_INVALID_ARG;

    /* PCF8574 is active-low: bit = 0 → relay ON */
    uint8_t bit = 1 << (channel % 8);
    if (channel < 8) {
        if (on) g_chip0_state &= ~bit; else g_chip0_state |= bit;
        return pcf8574_write(PCF8574_ADDR_CHIP0, g_chip0_state);
    } else {
        if (on) g_chip1_state &= ~bit; else g_chip1_state |= bit;
        return pcf8574_write(PCF8574_ADDR_CHIP1, g_chip1_state);
    }
}

bool relay_get(uint8_t channel) {
    if (channel >= g_relay_count) return false;
    uint8_t bit = 1 << (channel % 8);
    uint8_t state = (channel < 8) ? g_chip0_state : g_chip1_state;
    /* Active-low: bit=0 means relay ON */
    return (state & bit) == 0;
}

esp_err_t relay_set_all(uint16_t bitmask) {
    g_chip0_state = 0xFF;   /* All off (active-low: bit=1 = relay OFF) */
    g_chip1_state = 0xFF;
    for (int i = 0; i < g_relay_count && i < 16; i++) {
        if (bitmask & (1 << i)) {
            /* Clear the bit (active-low = relay ON) */
            if (i < 8) g_chip0_state &= ~(1 << i);
            else g_chip1_state &= ~(1 << (i - 8));
        }
    }
    /* CRITICAL: write to both chips unconditionally — even when bitmask=0 */
    pcf8574_write(PCF8574_ADDR_CHIP0, g_chip0_state);
    if (g_relay_count > 8) {
        pcf8574_write(PCF8574_ADDR_CHIP1, g_chip1_state);
    }
    return ESP_OK;
}

uint16_t relay_get_all(void) {
    uint16_t mask = 0;
    for (int i = 0; i < g_relay_count && i < 16; i++) {
        if (relay_get(i)) mask |= (1 << i);
    }
    return mask;
}

esp_err_t relay_restore_state(void) {
    nvs_handle_t h;
    esp_err_t err = nvs_open(SHE_NVS_NAMESPACE, NVS_READONLY, &h);
    if (err != ESP_OK) return err;
    uint16_t state = 0;
    nvs_get_u16(h, SHE_NVS_KEY_RELAY_STATE, &state);
    nvs_close(h);
    ESP_LOGI(TAG, "Restoring relay state: 0x%04X", state);
    return relay_set_all(state);
}

esp_err_t relay_save_state(void) {
    nvs_handle_t h;
    esp_err_t err = nvs_open(SHE_NVS_NAMESPACE, NVS_READWRITE, &h);
    if (err != ESP_OK) return err;
    uint16_t state = relay_get_all();
    nvs_set_u16(h, SHE_NVS_KEY_RELAY_STATE, state);
    nvs_commit(h);
    nvs_close(h);
    return ESP_OK;
}
