/* =============================================================================
 * SHE V3 firmware — input_monitor.c
 * =============================================================================
 * PCF8574 digital INPUT expanders on I2C bus 1. ADR-016 + ADR-017.
 *
 * Why this is not feedback_monitor.c
 * ----------------------------------
 * feedback_monitor.c samples a CD4051 analog mux through the ADC, one channel
 * at a time, with a settling delay per channel. A PCF8574 has no pin select: it
 * latches all eight inputs and you read the whole port in ONE transaction and
 * mask. Different principle, different cost. On SHE-R24 the mux path is not
 * started at all — the two would fight over GPIO 4/5.
 *
 * Polarity
 * --------
 * Inputs are active-low: a bit of 0 means the line is asserted. That inversion
 * happens in exactly one function (input_monitor_get) so no caller has to carry
 * it. The reference firmware returned the electrical level and relied on every
 * call site to remember — which is how "on" and "off" quietly swap.
 * ==========================================================================*/

#include "input_monitor.h"
#include "she_mqtt.h"
#include "relay_driver.h"
#include "esp_log.h"
#include "driver/i2c.h"
#include "driver/gpio.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include <string.h>

static const char *TAG = "she_inputs";

/* Input bus — separate from the output bus relay_driver.c owns. Pins come from
 * the board's own pcf8574.h (ADR-017). GPIO 6-11 on a classic ESP32-D0WD are
 * wired to the integrated SPI flash and MUST NOT be repurposed. */
#define INPUT_I2C_NUM        1
#define INPUT_I2C_SDA_IO     4
#define INPUT_I2C_SCL_IO     5
#define INPUT_I2C_FREQ_HZ    100000
#define INPUT_I2C_TIMEOUT_MS 100

static const uint8_t g_input_addr[INPUT_CHIP_COUNT] = {
    0x20,   /* DCIN1 */
    0x21,   /* DCIN2 */
    0x22,   /* ACIN1 */
    0x23,   /* ACIN2 */
};

static const char *const g_input_name[INPUT_CHIP_COUNT] = {
    "DCIN1", "DCIN2", "ACIN1", "ACIN2",
};

static uint8_t g_input_raw[INPUT_CHIP_COUNT]     = { 0xFF, 0xFF, 0xFF, 0xFF };
static bool    g_input_present[INPUT_CHIP_COUNT] = { false, false, false, false };

/* AC feedback for the 16 lights, indexed "Light 1".."Light 16" (0-15).
 * Kept separate from the raw bytes so the light index does not have to know
 * which chip it came from. */
static bool g_ac_state[16];
static bool g_dc_state[16];

/* ---- Low-level bus access ------------------------------------------------- */

static esp_err_t input_read_raw(uint8_t addr, uint8_t *out) {
    i2c_cmd_handle_t cmd = i2c_cmd_link_create();
    i2c_master_start(cmd);
    i2c_master_write_byte(cmd, (addr << 1) | I2C_MASTER_READ, true);
    uint8_t data = 0;
    i2c_master_read_byte(cmd, &data, I2C_MASTER_NACK);
    i2c_master_stop(cmd);
    esp_err_t err = i2c_master_cmd_begin(INPUT_I2C_NUM, cmd,
                                         pdMS_TO_TICKS(INPUT_I2C_TIMEOUT_MS));
    i2c_cmd_link_delete(cmd);
    if (err == ESP_OK) {
        *out = data;
    }
    return err;
}

/* A write of 0xFF to a PCF8574 leaves every pin in input mode (the device has
 * no configuration register — writing 1 makes a pin a high-impedance input).
 * Without this the chip's outputs would drive against whatever the board wires
 * to the sense lines. */
static esp_err_t input_set_all_inputs(uint8_t addr) {
    i2c_cmd_handle_t cmd = i2c_cmd_link_create();
    i2c_master_start(cmd);
    i2c_master_write_byte(cmd, (addr << 1) | I2C_MASTER_WRITE, true);
    i2c_master_write_byte(cmd, 0xFF, true);
    i2c_master_stop(cmd);
    esp_err_t err = i2c_master_cmd_begin(INPUT_I2C_NUM, cmd,
                                         pdMS_TO_TICKS(INPUT_I2C_TIMEOUT_MS));
    i2c_cmd_link_delete(cmd);
    return err;
}

/* ---- Public API ----------------------------------------------------------- */

esp_err_t input_monitor_init(void) {
    i2c_config_t conf = {
        .mode = I2C_MODE_MASTER,
        .sda_io_num = INPUT_I2C_SDA_IO,
        .scl_io_num = INPUT_I2C_SCL_IO,
        .sda_pullup_en = GPIO_PULLUP_ENABLE,
        .scl_pullup_en = GPIO_PULLUP_ENABLE,
        .master.clk_speed = INPUT_I2C_FREQ_HZ,
    };
    esp_err_t err = i2c_param_config(INPUT_I2C_NUM, &conf);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "I2C bus %d param config failed: %s", INPUT_I2C_NUM,
                 esp_err_to_name(err));
        return err;
    }
    err = i2c_driver_install(INPUT_I2C_NUM, conf.mode, 0, 0, 0);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "I2C bus %d install failed: %s", INPUT_I2C_NUM,
                 esp_err_to_name(err));
        return err;
    }

    /* Probe each chip individually. A 24-relay board with four input expanders
     * must not go dark because one of them is unpopulated or badly soldered —
     * the working ones still report, and the log names the missing one. */
    uint8_t found = 0;
    for (int i = 0; i < INPUT_CHIP_COUNT; i++) {
        g_input_present[i] = (input_set_all_inputs(g_input_addr[i]) == ESP_OK);
        if (g_input_present[i]) {
            found++;
        } else {
            ESP_LOGW(TAG, "input expander %s @0x%02X not found — its 8 lines "
                          "will read as inactive", g_input_name[i], g_input_addr[i]);
        }
    }

    ESP_LOGI(TAG, "I2C%d input bus ready (SDA=%d SCL=%d) — %u/%d expanders responded",
             INPUT_I2C_NUM, INPUT_I2C_SDA_IO, INPUT_I2C_SCL_IO,
             (unsigned)found, INPUT_CHIP_COUNT);

    /* Seed the caches so the first poll does not look like 32 simultaneous
     * transitions. */
    input_monitor_poll();
    for (int i = 0; i < 8; i++) {
        g_ac_state[i]      = input_monitor_get(INPUT_CHIP_ACIN1, (uint8_t)i);
        g_ac_state[8 + i]  = input_monitor_get(INPUT_CHIP_ACIN2, (uint8_t)i);
        g_dc_state[i]      = input_monitor_get(INPUT_CHIP_DCIN1, (uint8_t)i);
        g_dc_state[8 + i]  = input_monitor_get(INPUT_CHIP_DCIN2, (uint8_t)i);
    }
    return ESP_OK;
}

bool input_monitor_present(input_chip_t chip) {
    if (chip >= INPUT_CHIP_COUNT) return false;
    return g_input_present[chip];
}

uint8_t input_monitor_raw(input_chip_t chip) {
    if (chip >= INPUT_CHIP_COUNT) return 0xFF;
    return g_input_raw[chip];
}

bool input_monitor_get(input_chip_t chip, uint8_t pin) {
    if (chip >= INPUT_CHIP_COUNT || pin > 7) return false;
    if (!g_input_present[chip]) return false;
    /* THE polarity inversion — active-low: a cleared bit means asserted. */
    return (g_input_raw[chip] & (1u << pin)) == 0;
}

esp_err_t input_monitor_poll(void) {
    esp_err_t first_err = ESP_OK;
    for (int i = 0; i < INPUT_CHIP_COUNT; i++) {
        if (!g_input_present[i]) continue;
        uint8_t raw = 0;
        esp_err_t err = input_read_raw(g_input_addr[i], &raw);
        if (err == ESP_OK) {
            g_input_raw[i] = raw;
        } else if (first_err == ESP_OK) {
            first_err = err;
        }
    }
    return first_err;
}

bool input_monitor_ac(uint8_t light_index) {
    if (light_index >= 16) return false;
    return g_ac_state[light_index];
}

bool input_monitor_dc(uint8_t index) {
    if (index >= 16) return false;
    return g_dc_state[index];
}

/* ---- AC feedback → light Power param -------------------------------------- */

/* "Light N" (1-based) lives on relay channel 0-7 for N=1..8 and 16-23 for
 * N=9..16. Sockets occupy channels 8-15 and have no AC feedback line. */
static uint8_t light_index_to_channel(uint8_t light_index) {
    return (light_index < 8) ? light_index : (uint8_t)(light_index + 8);
}

/* Sync the profile's cached Power value for one light to the measured feedback
 * and return true if the node was touched.
 *
 * This is the reference firmware's feedback_task behaviour, kept deliberately:
 * the AC line senses the load, so when a wall switch flips a circuit the cloud
 * should be told what is actually energised rather than what we last commanded.
 * Note it does NOT drive the relay — reporting the divergence is the point; a
 * feedback loop that silently re-asserts the command would hide the fault. */
static bool sync_light_param(she_node_t *node, uint8_t light_index, bool on) {
    if (!node) return false;
    const uint8_t channel = light_index_to_channel(light_index);

    for (int i = 0; i < node->device_count; i++) {
        node_device_t *d = &node->devices[i];
        if (d->channel != channel) continue;
        if (strncmp(d->name, "Light", 5) != 0) continue;

        for (int j = 0; j < d->param_count; j++) {
            node_param_t *p = &d->params[j];
            if (strcmp(p->name, "Power") != 0) continue;
            if (p->last_value.val.b == on) return false;   /* no change */
            p->last_value = param_bool(on);
            p->dirty = true;
            ESP_LOGI(TAG, "%s feedback -> %s (relay channel %u)",
                     d->name, on ? "ON" : "OFF", (unsigned)channel);
            return true;
        }
    }
    return false;
}

/* ---- Poll task ------------------------------------------------------------ */

static void input_task(void *arg) {
    she_node_t *node = (she_node_t *)arg;

    while (true) {
        input_monitor_poll();

        bool ac_changed = false;
        for (int i = 0; i < 8; i++) {
            bool a1 = input_monitor_get(INPUT_CHIP_ACIN1, (uint8_t)i);
            bool a2 = input_monitor_get(INPUT_CHIP_ACIN2, (uint8_t)i);
            g_ac_state[i] = a1;
            g_ac_state[8 + i] = a2;

            /* Sync EVERY poll — NOT only on a transition.
             *
             * A command that turns a relay ON while its AC sense line is already
             * OFF (the lamp is dark — e.g. the wall switch is off, or the bulb is
             * dead) produces NO transition, so a change-only sync never fired and
             * the cached Power stayed at the COMMANDED ON. The cloud — and so the
             * app — then showed ON with the bulb off, which is exactly the
             * "toggle on without feedback" bug.
             *
             * sync_light_param() is a no-op when the cached value already matches,
             * and it never drives the relay, so calling it every second is cheap
             * and safe: the reported state always converges to what the AC line
             * actually measures. */
            if (sync_light_param(node, (uint8_t)i, a1)) ac_changed = true;
            if (sync_light_param(node, (uint8_t)(8 + i), a2)) ac_changed = true;
        }

        if (ac_changed) {
            /* Publish immediately rather than waiting for the 60 s main loop:
             * a wall-switch flip is exactly the event an operator is watching
             * for, and a minute of stale state makes it look broken. */
            mqtt_publish_params_local(node);
        }

        /* DC sense lines are read-only telemetry in the reference firmware; keep
         * them observable without pretending they are controllable. */
        for (int i = 0; i < 8; i++) {
            bool d1 = input_monitor_get(INPUT_CHIP_DCIN1, (uint8_t)i);
            bool d2 = input_monitor_get(INPUT_CHIP_DCIN2, (uint8_t)i);
            if (d1 != g_dc_state[i]) {
                g_dc_state[i] = d1;
                ESP_LOGI(TAG, "DCIN1.%d -> %d", i, (int)d1);
            }
            if (d2 != g_dc_state[8 + i]) {
                g_dc_state[8 + i] = d2;
                ESP_LOGI(TAG, "DCIN2.%d -> %d", i, (int)d2);
            }
        }

        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}

esp_err_t input_monitor_start(she_node_t *node) {
    BaseType_t ret = xTaskCreatePinnedToCore(
        input_task, "input_task", 3072, node, 3, NULL, 0);
    if (ret != pdPASS) {
        ESP_LOGE(TAG, "Failed to create input_task");
        return ESP_FAIL;
    }
    ESP_LOGI(TAG, "Input feedback task started (1 s poll)");
    return ESP_OK;
}

/* ---- Absolute light control over a 2-way wall switch ---------------------- */

bool input_monitor_is_light_channel(uint8_t channel) {
    return channel < 8 || (channel >= 16 && channel < 24);
}

/* Lamp-side sense for a light index, read FRESH rather than from the task's
 * cache: a stale reading here would invert the intent of an absolute write. */
static bool sensed_ac(uint8_t light_index) {
    if (light_index < 8) return input_monitor_get(INPUT_CHIP_ACIN1, light_index);
    return input_monitor_get(INPUT_CHIP_ACIN2, (uint8_t)(light_index - 8));
}

bool input_monitor_set_light_absolute(uint8_t channel, bool on) {
    if (!input_monitor_is_light_channel(channel)) return false;

    /* Without the AC feedback there is nothing to be "absolute" about: `sensed`
     * would read false for every lamp, so we would toggle relays that were
     * already correct. Fall back to a plain set. */
    if (!input_monitor_present(INPUT_CHIP_ACIN1) ||
        !input_monitor_present(INPUT_CHIP_ACIN2)) {
        ESP_LOGW(TAG, "no AC feedback — plain relay_set(ch %u, %s)",
                 (unsigned)channel, on ? "ON" : "OFF");
        relay_set(channel, on);
        return false;
    }

    const uint8_t li = (channel < 8) ? channel : (uint8_t)(channel - 8);

    input_monitor_poll();                 /* fresh raw bytes before deciding */

    if (sensed_ac(li) == on) {
        ESP_LOGI(TAG, "Light %u already %s — relay left alone",
                 (unsigned)(li + 1), on ? "ON" : "OFF");
        return false;                     /* correct already: do NOT toggle */
    }

    /* sensed != on, so ONE flip lands on `on` regardless of the wall switch. */
    const bool relay_now = relay_get(channel);
    ESP_LOGI(TAG, "Light %u -> %s (lamp was %s) — pulsing relay ch %u",
             (unsigned)(li + 1), on ? "ON" : "OFF", on ? "OFF" : "ON",
             (unsigned)channel);
    relay_set(channel, !relay_now);
    return true;
}

uint8_t input_monitor_set_group_absolute(uint32_t mask, bool on) {
    /* No feedback → the mask is a plain relay intent (the original behaviour). */
    if (!input_monitor_present(INPUT_CHIP_ACIN1) ||
        !input_monitor_present(INPUT_CHIP_ACIN2)) {
        ESP_LOGW(TAG, "group set with no AC feedback — setting relays directly");
        relay_apply_group(mask, on);
        return 0;
    }

    input_monitor_poll();                       /* one fresh read for the group */

    uint32_t target = relay_get_all();          /* keep every channel not in the mask */
    uint8_t pulsed = 0;

    for (uint8_t ch = 0; ch < 24; ch++) {
        if (!(mask & (1u << ch))) continue;

        bool want;
        if (input_monitor_is_light_channel(ch)) {
            const uint8_t li = (ch < 8) ? ch : (uint8_t)(ch - 8);
            if (sensed_ac(li) == on) continue;  /* lamp already right: leave this relay */
            want = ((target >> ch) & 1u) == 0;  /* sensed != on ⇒ a toggle lands on `on` */
            pulsed++;
        } else {
            want = on;                          /* sockets have no sense line */
        }
        if (want) target |= (1u << ch); else target &= ~(1u << ch);
    }

    /* ONE atomic write for the whole board — a master command must not apply
     * half a group. */
    relay_set_all(target);
    ESP_LOGI(TAG, "group set: %u light relay(s) pulsed, rest already correct",
             (unsigned)pulsed);
    return pulsed;
}
