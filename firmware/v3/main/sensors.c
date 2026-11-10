/* =============================================================================
 * SHE V3 firmware — sensors.c
 * =============================================================================
 * DHT22 (AM2302) (GPIO 27) + MQ-135 (ADC1 ch4 / GPIO 32) + soil moisture (ADC1 ch5 /
 * GPIO 33). Ported from the RainMaker-era firmware in
 * `SMTHIOT24_Firmware/HOME-DEMO/main/` — see sensors.h for the pin rationale.
 *
 * ---- What changed in the port, and why ---------------------------------------
 *
 *  1. ATTENUATION BUG FIXED (the important one). The old MQ-135 code used
 *     `ADC_ATTEN_DB_0` (~1.1 V full scale) but converted raw -> volts with a
 *     3.3 V reference, so any sensor output above ~1.1 V clamped to 4095 and
 *     read as exactly 3.3 V. The derived PPM was meaningless over most of the
 *     sensor's range. Both channels now use 11 dB (~0-3.1 V), matching what the
 *     old soil driver already did.
 *
 *  2. `ets_delay_us()` -> `esp_rom_delay_us()`. `rom/ets_sys.h` is deprecated in
 *     IDF 5.x; the old header still compiles but warns.
 *
 *  3. 1-wire pin handling. The old `hold_low()` switched the pin to OUTPUT,
 *     drove it high to "release", and then each read switched it back to INPUT.
 *     That momentarily drives the bus high against the pull-up and against the
 *     DHT11's own open-drain output. The pin is now configured once as
 *     INPUT_OUTPUT_OD with a pull-up, which is what a 1-wire bus actually is:
 *     driving 0 pulls low, driving 1 releases the line.
 *
 *  4. The 40-bit read runs inside a critical section. The old code had no
 *     protection at all, so Wi-Fi interrupts could stretch a bit period past the
 *     decode threshold and the frame failed its checksum — which is why it
 *     needed a 5-attempt retry loop. Retries are kept (they are still the right
 *     response to a genuinely absent sensor) but the common cause is gone.
 *
 *  5. Calibration moved into the task. The old code blocked boot for ~5 s before
 *     Wi-Fi was up, which risks the 30 s association window. It now runs inside
 *     the sampling task, where a 5 s stall costs nothing.
 *
 *  6. Division-by-zero guards on the MQ-135. The old `readSensor()` computed
 *     `(Vc * RL / sensor_volt) - RL` with no check on `sensor_volt`; a floating
 *     pin gave 0 V -> infinity -> NaN PPM, which then went to the cloud.
 *
 *  7. Toluene / NH3 / acetone are computed and logged but NOT published, which
 *     matches what the old firmware did (those three publishes were commented
 *     out). An MQ-135 is a single heated metal-oxide element with no gas
 *     selectivity: all six "concentrations" are the same measurement pushed
 *     through six different datasheet curves, so publishing all six would imply
 *     six independent measurements. CO2, CO and alcohol are the three the
 *     product actually shows.
 * ==========================================================================*/

#include "sensors.h"
#include "she_mqtt.h"
#include "esp_log.h"
#include "esp_rom_sys.h"
#include "driver/adc.h"
#include "driver/gpio.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

static const char *TAG = "she_sensors";

/* ---- Shared state --------------------------------------------------------- */

static sensor_sample_t     g_latest;            /* guarded by g_lock */
static SemaphoreHandle_t   g_lock;
static bool                g_running;
static int                 g_soil_raw_dry = SHE_SOIL_RAW_DRY_DEFAULT;
static int                 g_soil_raw_wet = SHE_SOIL_RAW_WET_DEFAULT;
static portMUX_TYPE        g_dht_mux = portMUX_INITIALIZER_UNLOCKED;

/* =============================================================================
 * DHT — bit-banged 1-wire, GPIO 27
 * ==========================================================================*/

/** Which DHT part is actually on the bus, as detected from the live frame. */
static int g_dht_detected = 0;   /* 0 = unknown yet, 11 or 22 once known */

/** Runtime-selected DHT GPIO. Defaults to the configured SHE_DHT11_GPIO but is
 * moved by dht_find_pin() if the sensor actually answers on a different terminal
 * (the custom PCB has 4 data terminals and no published pin map). */
static int g_dht_gpio = SHE_DHT11_GPIO;

/** Cumulative read stats for the boot/log diagnostics. */
static int g_dht_total = 0;      /* total dht_read() calls */
static int g_dht_fails = 0;      /* calls that returned ESP_FAIL (no/garbled frame) */

/* ---- Self-healing pin detection ----
 *
 * dht_find_pin() used to run ONLY at boot. Plug the sensor in afterwards and the
 * board kept reading the old fallback pin forever: every read timed out, and
 * because publishing is gated on dht_valid, the app received nothing at all —
 * not even a zero. That reads as "the app is broken", when the sensor had simply
 * been connected after the scan.
 *
 * So while every read is failing, re-scan. A sensor that is answering is never
 * disturbed, and a re-scan costs nothing when the hardware is healthy.
 */
#define DHT_REDETECT_FAILS      5
#define DHT_REDETECT_PERIOD_MS  (120 * 1000)

static int          s_fails_at_last_detect = 0;
static TickType_t   s_last_detect_tick     = 0;
static int g_probe_cycle = 0;    /* counts sensor cycles for the periodic wiring probe */

/** One decoded frame plus whether it landed inside the part's plausible range. */
typedef struct {
    float humidity_pct;
    float temperature_c;
    bool  in_range;
} dht_decoded_t;

/**
 * Decode as a DHT11: 8-bit integer RH and T, low bytes always 0.
 * Documented range: 0-50 °C, 20-90 % RH (widened to 0-60 / 0-100 here, because
 * a sensor sitting in a cold room legitimately reads below 20 % RH).
 */
static dht_decoded_t dht_decode_dht11(const uint8_t d[5]) {
    dht_decoded_t r;
    r.humidity_pct  = (float)d[0] + (float)d[1] / 10.0f;
    r.temperature_c = (float)d[2] + (float)d[3] / 10.0f;
    r.in_range = (r.temperature_c >= 0.0f && r.temperature_c <= 60.0f &&
                  r.humidity_pct  >= 0.0f && r.humidity_pct  <= 100.0f);
    return r;
}

/**
 * Decode as a DHT22: 16-bit RH and T in 1/10 units, temperature sign in bit15
 * of the temperature word. Documented range: -40-80 °C, 0-100 % RH.
 */
static dht_decoded_t dht_decode_dht22(const uint8_t d[5]) {
    const uint16_t rh_raw = ((uint16_t)d[0] << 8) | d[1];
    const uint16_t t_raw  = ((uint16_t)d[2] << 8) | d[3];

    dht_decoded_t r;
    r.humidity_pct  = (float)rh_raw / 10.0f;
    r.temperature_c = (t_raw & 0x8000) ? -((float)(t_raw & 0x7FFF)) / 10.0f
                                       :  (float)t_raw / 10.0f;
    r.in_range = (r.temperature_c >= -40.0f && r.temperature_c <= 80.0f &&
                  r.humidity_pct  >= 0.0f && r.humidity_pct  <= 100.0f);
    return r;
}

static esp_err_t dht_bus_init(int gpio) {
    gpio_config_t cfg = {
        .pin_bit_mask = (1ULL << gpio),
        /* Open-drain + pull-up IS the 1-wire bus: 0 pulls the line down, 1
         * releases it and the pull-up (plus the sensor's own drive) takes it
         * back high. Never push-pull — that would fight the sensor. */
        .mode         = GPIO_MODE_INPUT_OUTPUT_OD,
        .pull_up_en   = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type    = GPIO_INTR_DISABLE,
    };
    esp_err_t err = gpio_config(&cfg);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "DHT GPIO %d config failed: %s", gpio, esp_err_to_name(err));
        return err;
    }
    gpio_set_level(gpio, 1);   /* release the bus */
    return ESP_OK;
}

/**
 * Boot-time pin survey — read every sensor GPIO as a plain input (internal
 * pull-up OFF) and report which ones have an external pull-up present.
 *
 * With the DHT being the ONLY device on the sensor header (the gas/soil pins
 * are empty), exactly ONE pin should read HIGH: that pin is the DHT's GPIO. If
 * it is 27, the wiring is correct and the module itself is at fault; if it is
 * 32 or 33, the DHT is on the wrong GPIO and SHE_DHT11_GPIO must move. A floating
 * empty pin reads LOW/noisy, not a clean HIGH, so a solid HIGH is unambiguous.
 *
 * Runs BEFORE dht_bus_init()/mq135_init()/soil_init() so those calls reconfigure
 * the pins to their real functions afterwards.
 */
static void sensor_pin_survey(void) {
    const int pins[] = { SHE_DHT11_GPIO, SHE_MQ135_GPIO, SHE_SOIL_GPIO };
    ESP_LOGI(TAG, "Pin survey (idle, internal PU OFF): a pin reading HIGH has an external pull-up");
    for (int i = 0; i < (int)(sizeof(pins) / sizeof(pins[0])); i++) {
        gpio_config_t c = {
            .pin_bit_mask = (1ULL << pins[i]),
            .mode         = GPIO_MODE_INPUT,
            .pull_up_en   = GPIO_PULLUP_DISABLE,
            .pull_down_en = GPIO_PULLDOWN_DISABLE,
            .intr_type    = GPIO_INTR_DISABLE,
        };
        gpio_config(&c);
        const int lvl = gpio_get_level(pins[i]);
        ESP_LOGI(TAG, "  GPIO%d = %s", pins[i],
                 lvl ? "HIGH (external pull-up PRESENT -> a module is on this pin)"
                     : "LOW  (no pull-up seen)");
    }
}

/**
 * Boot-time diagnostic for the "wired but never reads" case.
 *
 * Two checks, run once at sensors_init():
 *
 *  1. PRESENCE — reconfigure the pin as a plain input with the ESP32's own
 *     pull-up DISABLED, then read it. The DHT module (if it carries a pull-up,
 *     as every DHT22 breakout does) would pull this line HIGH. Reading HIGH
 *     therefore proves the module's pull-up is electrically present on this
 *     very pin. Reading LOW means nothing is pulling the line up here:
 *     either the DATA wire is not connected to GPIO 27 (wrong header pin,
 *     broken trace) or the module has no pull-up and none was added.
 *
 *  2. IDENTITY — if SHE_DHT_PROBE is set, toggle the pin for ~3 s. Measure the
 *     DHT DATA pin with a DC voltmeter: the correct pin reads ~1.6 V (the
 *     average of 0 / 3.3 V), a wrong pin reads a steady 3.3 V (module pull-up)
 *     or 0 V (grounded). This locates which physical pad/header actually IS
 *     GPIO 27 when no schematic is available.
 *
 * Neither check talks to the sensor; both restore the 1-wire bus afterwards.
 */
static void dht_self_test(void) {
    ESP_LOGI(TAG, "DHT self-test: running on GPIO %d (configured GPIO %d, model %d)",
             g_dht_gpio, SHE_DHT11_GPIO, SHE_DHT_MODEL);

    /* ---- 1. Presence: pull-down vs pull-up comparison ----
     *
     * The old check read the line with the internal pull-up OFF and trusted a
     * HIGH as "external pull-up present". That was a FALSE POSITIVE: dht_bus_init()
     * enables the ESP's own internal pull-up, and the immediate read caught its
     * residual charge before the line discharged, so a line with no external
     * pull-up still read HIGH. (The clean pin survey read the same pin LOW.)
     *
     * The decisive method is to fight the external pull-up with the internal
     * PULL-DOWN: a real module pull-up (typ. 4.7-10k) easily beats the ESP's
     * ~45k pull-down and the line stays HIGH; with no external pull-up the
     * internal pull-down wins and the line reads LOW. We then confirm with the
     * internal PULL-UP as a sanity check (a line that follows both is truly
     * floating/empty, not connected to a module). */
    gpio_config_t pd = {
        .pin_bit_mask = (1ULL << g_dht_gpio),
        .mode         = GPIO_MODE_INPUT,
        .pull_up_en   = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_ENABLE,
        .intr_type    = GPIO_INTR_DISABLE,
    };
    gpio_config(&pd);
    esp_rom_delay_us(2000);   /* let the line settle against the ~45k pull-down */
    const int pd_level = gpio_get_level(g_dht_gpio);

    gpio_config_t pu = {
        .pin_bit_mask = (1ULL << g_dht_gpio),
        .mode         = GPIO_MODE_INPUT,
        .pull_up_en   = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type    = GPIO_INTR_DISABLE,
    };
    gpio_config(&pu);
    esp_rom_delay_us(2000);
    const int pu_level = gpio_get_level(g_dht_gpio);

    ESP_LOGI(TAG, "  presence: internal-pulldown=%d internal-pullup=%d",
             pd_level, pu_level);
    if (pd_level == 1) {
        ESP_LOGI(TAG, "  => STRONG external pull-up PRESENT on GPIO%d: a module is wired to this pin",
                 g_dht_gpio);
    } else if (pu_level == 1) {
        ESP_LOGW(TAG, "  => NO strong external pull-up on GPIO%d: the line follows the internal "
                      "pull (pulldown=LOW, pullup=HIGH), so either the DATA wire is not on this pin, "
                      "the trace is open, or the module has only a weak ~45k pull-up",
                 g_dht_gpio);
    } else {
        ESP_LOGW(TAG, "  => line stuck LOW on GPIO%d even with the internal pull-up: shorted to GND "
                      "or driven low by something else", g_dht_gpio);
    }

    /* Restore the 1-wire bus before any further use. */
    dht_bus_init(g_dht_gpio);

#if SHE_DHT_PROBE
    ESP_LOGI(TAG, "  PROBE: toggling GPIO%d for ~3s — measure your DHT DATA pin with a DC voltmeter; "
                  "it should read ~1.6V average if that pin is GPIO%d", g_dht_gpio, g_dht_gpio);
    for (int i = 0; i < 8; i++) {
        gpio_set_level(g_dht_gpio, 0);
        vTaskDelay(pdMS_TO_TICKS(200));
        gpio_set_level(g_dht_gpio, 1);
        vTaskDelay(pdMS_TO_TICKS(200));
    }
    ESP_LOGI(TAG, "  PROBE done — restoring 1-wire bus");
    dht_bus_init(g_dht_gpio);
#endif
}

/** Wait until the line reads `level`. Returns microseconds waited, or -1. */
static int dht_wait_for_level(int gpio, int level, int timeout_us) {
    int waited = 0;
    while (gpio_get_level(gpio) != level) {
        if (waited >= timeout_us) return -1;
        esp_rom_delay_us(1);
        waited++;
    }
    return waited;
}

/**
 * Read one frame. Returns ESP_OK and fills t/h, or ESP_FAIL.
 *
 * Decoding is by RELATIVE pulse width rather than absolute: a bit is 0 or 1
 * according to whether the high period is longer than the preceding low period.
 * That is the same trick the original driver used, and it is the right one —
 * absolute thresholds break the moment the CPU clock or interrupt latency
 * changes, which is exactly what happens when Wi-Fi comes up.
 *
 * Timeouts below are the original values, converted from the old 2 µs count
 * units to microseconds.
 */
static esp_err_t dht_read_on_gpio(int gpio, float *temperature_c, float *humidity_pct) {
    if (!temperature_c || !humidity_pct) return ESP_FAIL;
    g_dht_total++;

    uint8_t data[5] = {0, 0, 0, 0, 0};

    /* ---- Start signal ---- */
    gpio_set_level(gpio, 0);
    esp_rom_delay_us(18000);              /* datasheet: >= 18 ms */
    gpio_set_level(gpio, 1);    /* release */
    esp_rom_delay_us(30);                 /* sensor pulls low within 20-40 µs */

    /* ---- Handshake: low 80 µs, high 80 µs, then the first low ----
     * Each stage is checked separately so the periodic log can report WHERE the
     * bus died: 'start' timing out means the sensor never pulled the line low
     * in response to our start pulse (not electrically connected / wrong pin /
     * dead sensor); 'handHi'/'handLo' timing out means it began responding but
     * stalled. */
    const int w_start = dht_wait_for_level(gpio, 0, 80);
    const int w_hi    = (w_start >= 0) ? dht_wait_for_level(gpio, 1, 180) : -1;
    const int w_lo    = (w_hi    >= 0) ? dht_wait_for_level(gpio, 0, 180) : -1;
    if (w_start < 0 || w_hi < 0 || w_lo < 0) {
        g_dht_fails++;
        if ((g_dht_total % 5) == 0) {
            ESP_LOGW(TAG, "DHT no response on GPIO%d (start=%s handHi=%s handLo=%s) after %d attempts",
                     gpio,
                     w_start < 0 ? "TIMEOUT" : "ok",
                     w_hi    < 0 ? "TIMEOUT" : "ok",
                     w_lo    < 0 ? "TIMEOUT" : "ok",
                     g_dht_total);
        }
        return ESP_FAIL;                  /* no sensor, or it did not respond */
    }

    /* ---- 40 bits ----
     * Interrupts off for ~3 ms. Without this a Wi-Fi ISR can stretch a bit past
     * the decode threshold and the checksum fails; the old driver worked around
     * that with five retries, which is a symptom, not a fix. */
    portENTER_CRITICAL(&g_dht_mux);
    for (int i = 0; i < 5; i++) {
        for (int j = 0; j < 8; j++) {
            const int low_us  = dht_wait_for_level(gpio, 1, 116);
            const int high_us = dht_wait_for_level(gpio, 0, 148);
            if (low_us < 0 || high_us < 0) {
                portEXIT_CRITICAL(&g_dht_mux);
                g_dht_fails++;
                return ESP_FAIL;
            }
            data[i] |= (uint8_t)((high_us > low_us) << (7 - j));
        }
    }
    portEXIT_CRITICAL(&g_dht_mux);

    const uint8_t checksum = (uint8_t)(data[0] + data[1] + data[2] + data[3]);
    if (checksum != data[4]) {
        ESP_LOGW(TAG, "DHT%d checksum mismatch (got 0x%02X, computed 0x%02X)", SHE_DHT_MODEL,
                 data[4], checksum);
        return ESP_FAIL;
    }

    /* ---- Decode the 40-bit payload ----
     *
     * Both parts send 5 bytes (RH hi, RH lo, T hi, T lo, checksum) and the
     * framing is identical. Only the ENCODING differs:
     *
     *   DHT11: RH and T are 8-bit integers; the low bytes (data[1], data[3])
     *          are always 0.
     *   DHT22: RH and T are 16-bit values in 1/10 units — RH 60 % arrives as
     *          raw 600 = 0x0258 and T 25.0 °C as raw 250 = 0x00FA. The sign of
     *          a negative temperature is bit15 of the temperature word.
     *
     * The two are told apart by decoding BOTH and keeping whichever lands in
     * range. That is unambiguous in practice:
     *
     *   - A DHT11 frame [60, 0, 25, 0] read as DHT22 gives RH = (60 << 8) / 10
     *     = 1536 % — out of range, so the DHT11 reading is kept.
     *   - A DHT22 frame [2, 88, 0, 250] read as DHT11 gives RH = 2 + 8.8 =
     *     10.8 % with a plausible-looking T = 25.0 °C — the temperature looks
     *     right but the humidity is wrong, and the DHT22 reading (60.0 %,
     *     25.0 °C) is the correct one.
     *
     * So the rule is: decode with the configured model first; if that result is
     * out of range, decode with the other model and log the mismatch. A board
     * built for one part therefore still reads the other when it is dropped into
     * the socket, instead of showing a frozen 0.0 — which is the symptom this
     * exists to fix. Both RH AND T must be in range for a decode to be
     * accepted, and for a DHT11 frame either one being >= 4 is enough to rule
     * the DHT22 interpretation out, so misdetection needs BOTH below 4.
     */
    dht_decoded_t dec;
    if (SHE_DHT_MODEL == 22) {
        dec = dht_decode_dht22(data);
        if (!dec.in_range) {
            const dht_decoded_t alt = dht_decode_dht11(data);
            if (alt.in_range) {
                ESP_LOGW(TAG, "Frame decoded as DHT11 but DHT22 is configured "
                              "(DHT22 gave T=%.1fC H=%.1f%%, out of range) — using DHT11",
                         dec.temperature_c, dec.humidity_pct);
                dec = alt;
                g_dht_detected = 11;
            }
        } else {
            g_dht_detected = 22;
        }
    } else {
        dec = dht_decode_dht11(data);
        if (!dec.in_range) {
            const dht_decoded_t alt = dht_decode_dht22(data);
            if (alt.in_range) {
                ESP_LOGW(TAG, "Frame decoded as DHT22 but DHT11 is configured "
                              "(DHT11 gave T=%.1fC H=%.1f%%, out of range) — using DHT22",
                         dec.temperature_c, dec.humidity_pct);
                dec = alt;
                g_dht_detected = 22;
            }
        } else {
            g_dht_detected = 11;
        }
    }

    /* A frame that checksums but still lands outside the part's range is a
     * misread, not a real measurement — publishing it would put a fake spike on
     * the trend chart. */
    if (!dec.in_range) {
        ESP_LOGW(TAG, "DHT out of range (T=%.1f H=%.1f) — discarding",
                 dec.temperature_c, dec.humidity_pct);
        return ESP_FAIL;
    }

    *humidity_pct  = dec.humidity_pct;
    *temperature_c = dec.temperature_c;
    return ESP_OK;
}

/* Read the DHT on the currently-selected runtime pin (set by dht_find_pin()). */
static esp_err_t dht_read(float *temperature_c, float *humidity_pct) {
    return dht_read_on_gpio(g_dht_gpio, temperature_c, humidity_pct);
}

/* =============================================================================
 * DHT pin auto-detect
 * =============================================================================
 *
 * The custom PCB exposes four data terminals whose GPIO mapping is unknown, and
 * the passive pull-up survey proved unreliable (floating pins read HIGH/LOW
 * inconsistently). The unambiguous test is to actually drive a start pulse on
 * each candidate GPIO and see which one the sensor answers: a real DHT pulls the
 * line LOW in response, so a valid (checksum-OK) frame can only come from the
 * pin it is truly on. No voltmeter required.
 *
 * Tries the three known sensor GPIOs (27/32/33) first, then every other
 * output-capable GPIO that is free on this board. The relays are driven by I2C
 * expanders (not ESP32 GPIOs), so these free GPIOs are the only plausible
 * sensor-header pins. Excluded: the flash group (6-11), I2C (4/5/13/15), the
 * BOOT button (0), the strapping pin (12), and the PZEM UART (17/18). If the
 * DHT sits on a 4th terminal mapped to one of these, we find it.
 *
 * Returns the GPIO the sensor answered on, or -1 if none did.
 */
static int dht_find_pin(void) {
    static const int candidates[] = {
        SHE_DHT11_GPIO, SHE_MQ135_GPIO, SHE_SOIL_GPIO,
        2, 14, 16, 19, 21, 22, 23, 25, 26
    };
    const int n = (int)(sizeof(candidates) / sizeof(candidates[0]));
    int found = -1;

    ESP_LOGI(TAG, "DHT pin auto-detect: probing %d GPIOs for a live DHT%d", n, SHE_DHT_MODEL);

    for (int i = 0; i < n; i++) {
        const int gpio = candidates[i];
        /* Configure this pin as the 1-wire bus and try a few handshakes. A real
         * DHT answers on the very first clean start; we allow 3 attempts to ride
         * out a single missed low period. */
        dht_bus_init(gpio);
        bool answered = false;
        for (int attempt = 0; attempt < 3 && !answered; attempt++) {
            float t = 0.0f, h = 0.0f;
            if (dht_read_on_gpio(gpio, &t, &h) == ESP_OK) {
                answered = true;
                ESP_LOGI(TAG, "  GPIO%d: DHT ANSWERED (T=%.1fC H=%.1f%%)", gpio, t, h);
            }
            esp_rom_delay_us(1500);
        }
        if (answered) {
            found = gpio;
            break;
        }
        ESP_LOGI(TAG, "  GPIO%d: no DHT answer", gpio);
        /* Leave non-matching pins as plain inputs so we do not hold any other
         * circuit's line in an unexpected state for the rest of the session. */
        gpio_config_t cfg = {
            .pin_bit_mask = (1ULL << gpio),
            .mode         = GPIO_MODE_INPUT,
            .pull_up_en   = GPIO_PULLUP_DISABLE,
            .pull_down_en = GPIO_PULLDOWN_DISABLE,
            .intr_type    = GPIO_INTR_DISABLE,
        };
        gpio_config(&cfg);
    }

    if (found < 0) {
        ESP_LOGW(TAG, "DHT pin auto-detect: no DHT answered on ANY candidate GPIO "
                      "(27/32/33 + 2/14/16/19/21-23/25/26). The module is dead, "
                      "unpowered, or missing its GND/VCC/pull-up. Falling back to GPIO%d.",
                 SHE_DHT11_GPIO);
    }
    return found;
}

/* =============================================================================
 * DHT raw-edge scan — the decisive "is the sensor alive" test
 * =============================================================================
 *
 * dht_find_pin() only reports whether a *valid, checksum-OK* frame was decoded;
 * it cannot distinguish "no sensor" from "sensor present but timing/decoding
 * off". This scan records the RAW line transitions after a start pulse on every
 * candidate GPIO. A live DHT always drives the 80/80 us handshake and then 40
 * bits, so its pin shows many edges. A pin with ZERO edges after the start
 * pulse has nothing driving it (dead sensor, DATA not connected, or unpowered).
 *
 * Only pins that actually show edges are logged, so the output stays short.
 */
static void dht_edge_scan(void) {
    static const int candidates[] = {
        SHE_DHT11_GPIO, SHE_MQ135_GPIO, SHE_SOIL_GPIO,
        2, 14, 16, 19, 21, 22, 23, 25, 26
    };
    const int n = (int)(sizeof(candidates) / sizeof(candidates[0]));
    ESP_LOGW(TAG, "DHT edge-scan: capturing raw line edges on %d GPIOs "
                  "(a live sensor shows edges; a dead/unwired one shows none)", n);

    int pins_with_edges = 0;
    for (int i = 0; i < n; i++) {
        const int gpio = candidates[i];
        dht_bus_init(gpio);
        gpio_set_level(gpio, 0);          /* start pulse */
        esp_rom_delay_us(18000);
        gpio_set_level(gpio, 1);          /* release, then watch */

        /* ~1 us/iteration; 5000 iterations ~ 8-10 ms real, which covers the
         * 80/80 us handshake plus the ~3-4 ms of 40 data bits. */
        uint8_t  lvl[96];
        uint16_t t_us[96];
        int      ne   = 0;
        int      last = gpio_get_level(gpio);
        int      t    = 0;
        while (t < 5000 && ne < 96) {
            int cur = gpio_get_level(gpio);
            if (cur != last) {
                lvl[ne]  = (uint8_t)cur;
                t_us[ne] = (uint16_t)t;
                ne++;
                last = cur;
            }
            esp_rom_delay_us(1);
            t++;
        }

        if (ne >= 2) {
            /* Two or more edges = the line actually toggled after release, i.e.
             * something is driving it (a real DHT gives ~80). */
            pins_with_edges++;
            ESP_LOGW(TAG, "  GPIO%d: %d edges in %d us -> SENSOR RESPONDS", gpio, ne, t);
            char buf[128];
            int pos = 0;
            for (int e = 0; e < ne; e++) {
                pos += snprintf(buf + pos, sizeof(buf) - pos, "%d@%u ", lvl[e], t_us[e]);
                if ((e + 1) % 8 == 0 || e == ne - 1) {
                    ESP_LOGW(TAG, "     %s", buf);
                    pos = 0;
                }
            }
        } else if (gpio == SHE_DHT11_GPIO) {
            /* ne==1 is just our own start-pulse release (LOW->HIGH); ne==0 means
             * the line was already HIGH. Neither is a sensor response. */
            ESP_LOGW(TAG, "  GPIO%d: no sensor edges in 5 ms (only the release edge; line ended %s) "
                          "-> nothing drives this pin", gpio, last ? "HIGH" : "LOW");
        }
        dht_bus_init(gpio);
    }
    if (pins_with_edges == 0) {
        ESP_LOGW(TAG, "DHT edge-scan: NO GPIO showed any line activity. The sensor is dead, its "
                      "DATA pin is not connected to any header pin, or it is unpowered.");
    }
}

/* =============================================================================
 * MQ-135 — air quality, ADC1 channel 4 (GPIO 32)
 * =============================================================================*/

typedef struct {
    const char *name;
    float a;
    float b;
    float offset;   /* added after the curve (CO2 is referenced to fresh air) */
} mq135_curve_t;

/* Datasheet curves, verbatim from the old firmware. PPM = a * ratio^b, where
 * ratio = RS / R0. */
static const mq135_curve_t k_curves[] = {
    { "CO",      605.18f, -3.937f,   0.0f },
    { "Alcohol",  77.255f, -3.18f,   0.0f },
    { "CO2",     110.47f, -2.862f, 400.0f },   /* CO2_OFFSET */
    { "Toluene",  44.947f, -3.445f,  0.0f },
    { "NH3",     102.2f,  -2.473f,   0.0f },
    { "Acetone",  34.668f, -3.369f,  0.0f },
};

static float g_mq135_r0 = 0.0f;      /* kOhm, 0 = not calibrated */

static esp_err_t mq135_init(void) {
    /* ⚠ ADC_WIDTH_BIT_12, never the literal 12. `adc_bits_width_t` is an enum
     * whose members are 0-3 (ADC_WIDTH_BIT_12 == 3), so passing 12 is out of
     * range and adc1_config_width() rejects it. The old firmware's soil driver
     * used the named constant and was fine; this is only a hazard for code that
     * thinks of the width as "the number twelve". */
    esp_err_t err = adc1_config_width(ADC_WIDTH_BIT_12);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "ADC width config failed: %s", esp_err_to_name(err));
        return err;
    }
    /* 11 dB, NOT the old DB_0 — see the header comment. ~0-3.1 V full scale. */
    err = adc1_config_channel_atten((adc1_channel_t)SHE_MQ135_ADC_CHANNEL, ADC_ATTEN_DB_11);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "MQ-135 ADC atten config failed: %s", esp_err_to_name(err));
        return err;
    }
    return ESP_OK;
}

/** Mean of a few raw reads — one ADC sample on this part is noisy by ~2%. */
static float mq135_read_voltage(void) {
    int32_t sum = 0;
    const int n = 8;
    for (int i = 0; i < n; i++) {
        sum += adc1_get_raw((adc1_channel_t)SHE_MQ135_ADC_CHANNEL);
    }
    const float raw = (float)sum / (float)n;
    return raw * SHE_ADC_VREF_MV / SHE_ADC_FULL_SCALE / 1000.0f;   /* volts */
}

/**
 * RS at the current voltage, in kOhm, or -1 if the reading is unusable.
 *
 * RS = (Vc * RL / Vout) - RL. Guarded: the old code divided by `sensor_volt`
 * with no check, so a disconnected sensor (0 V) produced infinity and every
 * derived PPM became NaN.
 */
static float mq135_rs_kohm(float voltage, float vc, float rl) {
    if (voltage < 0.01f) return -1.0f;      /* open circuit / floating pin */
    if (voltage > vc - 0.01f) return -1.0f; /* saturated — RL divider has no headroom */
    const float rs = (vc * rl / voltage) - rl;
    return rs > 0.0f ? rs : 0.0f;
}

/**
 * R0 = RS_in_clean_air / RATIO_CLEAN_AIR, averaged over N samples.
 *
 * Returns the averaged R0, or -1 if no sample was usable. Blocks for
 * N * interval (5 s by default) — called from the sensor TASK, never from boot.
 */
static float mq135_calibrate(void) {
    float sum = 0.0f;
    int   good = 0;

    for (int i = 0; i < SHE_MQ135_CAL_SAMPLES; i++) {
        const float v  = mq135_read_voltage();
        const float rs = mq135_rs_kohm(v, 3.3f, SHE_MQ135_RL_KOHM);
        if (rs > 0.0f) {
            sum += rs / SHE_MQ135_RATIO_CLEAN_AIR;
            good++;
        }
        vTaskDelay(pdMS_TO_TICKS(SHE_MQ135_CAL_INTERVAL_MS));
    }

    if (good == 0) {
        ESP_LOGE(TAG, "MQ-135 calibration failed: no usable sample. Check the analog "
                      "wiring and that the module has 5 V (the heater needs it).");
        return -1.0f;
    }
    return sum / (float)good;
}

/* =============================================================================
 * Soil moisture — ADC1 channel 5 (GPIO 33)
 * ==========================================================================*/

static esp_err_t soil_init(void) {
    /* adc1_config_width() is already set by mq135_init(); setting it twice is
     * harmless but the attenuation is per-channel and must be set here too. */
    esp_err_t err = adc1_config_channel_atten((adc1_channel_t)SHE_SOIL_ADC_CHANNEL,
                                              ADC_ATTEN_DB_11);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Soil ADC atten config failed: %s", esp_err_to_name(err));
        return err;
    }
    return ESP_OK;
}

static int soil_read_raw(void) {
    int32_t sum = 0;
    const int n = 8;
    for (int i = 0; i < n; i++) {
        sum += adc1_get_raw((adc1_channel_t)SHE_SOIL_ADC_CHANNEL);
    }
    return (int)(sum / n);
}

/**
 * Raw counts -> percentage, between two measured endpoints.
 *
 * With the default endpoints (4095 dry, 0 wet) this is algebraically identical
 * to the old firmware's `100 - (raw * 100 / 4095)`, so flashing this build does
 * not make the readings jump. It differs in using the endpoints as a real
 * calibration, so a capacitive probe can be corrected by changing two numbers
 * instead of editing the formula.
 */
static int soil_raw_to_pct(int raw) {
    const int span = g_soil_raw_dry - g_soil_raw_wet;
    if (span == 0) return 0;
    int pct = (g_soil_raw_dry - raw) * 100 / span;
    if (pct < 0)   pct = 0;
    if (pct > 100) pct = 100;
    return pct;
}

/* =============================================================================
 * Param sync — mirror the reading into the Sensors device
 * ==========================================================================*/

/** Write a float into a named param of the Sensors device. Returns true if it moved. */
static bool sensor_set_param(she_node_t *node, const char *param_name, float value,
                             float epsilon) {
    if (!node) return false;
    for (int i = 0; i < node->device_count; i++) {
        node_device_t *d = &node->devices[i];
        if (strcmp(d->name, "Sensors") != 0) continue;
        for (int j = 0; j < d->param_count; j++) {
            node_param_t *p = &d->params[j];
            if (strcmp(p->name, param_name) != 0) continue;

            /* Only publish on a real move. A DHT dithers by a tenth of a
             * degree between reads and the ADC by a few counts; publishing
             * every 30 s for noise would make the cloud log useless and burn
             * radio time for nothing. */
            if (p->last_value.type == DATA_FLOAT &&
                fabsf(p->last_value.val.f - value) < epsilon) {
                return false;
            }
            p->last_value = param_float(value);
            p->dirty = true;
            return true;
        }
    }
    return false;
}

/* =============================================================================
 * Sampling task
 * ==========================================================================*/

/**
 * ⚠ This `while (true)` is CORRECT and must stay.
 *
 * A FreeRTOS task function must never return — returning from one panics. The
 * project rule about `while(true)` is about HELPERS CALLED FROM app_main: a
 * helper that never returns silently kills the caller's error handling, which
 * is what once made the physical button dead on the provisioning path. This is
 * a task body, not a helper, and sensors_start() returns as soon as the task
 * exists.
 */
static void sensor_task(void *arg) {
    she_node_t *node = (she_node_t *)arg;

    /* ---- Calibrate the MQ-135 once, in here rather than at boot ---- */
    ESP_LOGI(TAG, "MQ-135 calibrating (%d samples, ~%d ms) — keep the sensor in clean air",
             SHE_MQ135_CAL_SAMPLES,
             SHE_MQ135_CAL_SAMPLES * SHE_MQ135_CAL_INTERVAL_MS);
    g_mq135_r0 = mq135_calibrate();
    if (g_mq135_r0 > 0.0f) {
        ESP_LOGI(TAG, "MQ-135 R0 = %.2f kOhm", g_mq135_r0);
    } else {
        ESP_LOGW(TAG, "MQ-135 unavailable — air-quality values will not be published");
    }

    while (true) {
        sensor_sample_t s;
        memset(&s, 0, sizeof(s));

        /* ---- Wiring probe (every 5th cycle) ----
         * Briefly read GPIO 27 as a plain input with the ESP32's internal
         * pull-up OFF and report the level. If the DHT module (with its own
         * pull-up) is electrically on this pin, the line is pulled HIGH; if we
         * read LOW, nothing pulls it up here (wrong terminal / open trace / no
         * module pull-up). Printed every 5th cycle (~2.5 min) so a serial
         * capture of any window shows it WITHOUT needing to catch the one-time
         * boot self-test. The 1-wire bus is restored immediately afterwards. */
        if ((++g_probe_cycle % 5) == 0) {
            gpio_config_t pc = {
                .pin_bit_mask = (1ULL << g_dht_gpio),
                .mode         = GPIO_MODE_INPUT,
                .pull_up_en   = GPIO_PULLUP_DISABLE,
                .pull_down_en = GPIO_PULLDOWN_DISABLE,
                .intr_type    = GPIO_INTR_DISABLE,
            };
            gpio_config(&pc);
            const int lvl = gpio_get_level(g_dht_gpio);
            dht_bus_init(g_dht_gpio);   /* restore 1-wire bus (OD + pull-up) */
            ESP_LOGI(TAG, "[probe] GPIO%d idle (PU off) = %s -> %s", g_dht_gpio,
                     lvl ? "HIGH/3.3V" : "LOW/0V",
                     lvl ? "external pull-up PRESENT (DHT module on this pin)"
                         : "NO pull-up on GPIO%d (wrong terminal / open trace / no module PU)");
        }

        /* ---- DHT (DHT22 / AM2302) ---- */
        if (dht_read(&s.temperature_c, &s.humidity_pct) == ESP_OK) {
            s.dht_valid = true;
        } else {
            s.dht_failures++;

            /* Every read is failing — the sensor may have been plugged in after
             * the boot scan. Re-detect, but not more often than every two
             * minutes so a genuinely dead module cannot turn this into a scan
             * loop that hogs the bus. */
            if (g_dht_fails >= DHT_REDETECT_FAILS &&
                g_dht_fails > s_fails_at_last_detect &&
                (s_last_detect_tick == 0 ||
                 (xTaskGetTickCount() - s_last_detect_tick) >=
                     pdMS_TO_TICKS(DHT_REDETECT_PERIOD_MS))) {

                const int since = g_dht_fails - s_fails_at_last_detect;
                s_last_detect_tick     = xTaskGetTickCount();
                s_fails_at_last_detect = g_dht_fails;

                ESP_LOGW(TAG, "DHT silent (%d failed reads since last check) — "
                              "re-scanning pins; the sensor may have been connected "
                              "after boot", since);

                const int re_found = dht_find_pin();
                if (re_found >= 0) {
                    if (re_found != g_dht_gpio) {
                        ESP_LOGW(TAG, "DHT found on GPIO%d (was GPIO%d) — adopting it",
                                 re_found, g_dht_gpio);
                        g_dht_gpio = re_found;
                    } else {
                        ESP_LOGI(TAG, "DHT re-confirmed on GPIO%d", re_found);
                    }
                }
                /* dht_find_pin() leaves the last pin it probed as a plain input;
                 * put the active pin back into 1-wire mode either way. */
                dht_bus_init(g_dht_gpio);
            }
        }

        /* ---- Soil ---- */
        s.soil_raw   = soil_read_raw();
        s.soil_pct   = soil_raw_to_pct(s.soil_raw);
        s.soil_valid = true;

        /* ---- MQ-135 ---- */
        s.r0_kohm = g_mq135_r0;
        if (g_mq135_r0 > 0.0f) {
            const float v  = mq135_read_voltage();
            const float rs = mq135_rs_kohm(v, 3.3f, SHE_MQ135_RL_KOHM);
            if (rs >= 0.0f) {
                const float ratio = rs / g_mq135_r0;
                s.air_voltage = v;
                s.air_valid   = true;
                for (size_t i = 0; i < sizeof(k_curves) / sizeof(k_curves[0]); i++) {
                    float ppm = k_curves[i].a * powf(ratio, k_curves[i].b) + k_curves[i].offset;
                    if (!(ppm > 0.0f) || ppm > 100000.0f) ppm = 0.0f;  /* NaN / absurd */
                    switch (i) {
                        case 0: s.co_ppm      = ppm; break;
                        case 1: s.alcohol_ppm = ppm; break;
                        case 2: s.co2_ppm     = ppm; break;
                        case 3: s.toluene_ppm = ppm; break;
                        case 4: s.nh3_ppm     = ppm; break;
                        case 5: s.acetone_ppm = ppm; break;
                    }
                }
            }
        }

        if (xSemaphoreTake(g_lock, pdMS_TO_TICKS(200)) == pdTRUE) {
            s.samples = g_latest.samples + 1;
            g_latest = s;
            xSemaphoreGive(g_lock);
        }

        ESP_LOGI(TAG, "T=%.1fC H=%.1f%%  soil=%d%% (raw %d)  CO2=%.0fppm CO=%.1fppm Alc=%.1fppm  "
                      "(raw %.2fV, R0 %.2fk)  [Tol=%.1f NH3=%.1f Ace=%.1f not published]  "
                      "(DHT gpio=%d tries=%d fails=%d%s)%s",
                 s.temperature_c, s.humidity_pct, s.soil_pct, s.soil_raw,
                 s.co2_ppm, s.co_ppm, s.alcohol_ppm,
                 s.air_voltage, s.r0_kohm,
                 s.toluene_ppm, s.nh3_ppm, s.acetone_ppm,
                 g_dht_gpio, g_dht_total, g_dht_fails,
                 g_dht_detected ? " DHT22" : "",
                 g_dht_detected ? " [detected]" : "");

        /* ---- Mirror into the Sensors device params ---- */
        bool changed = false;
        if (s.dht_valid) {
            changed |= sensor_set_param(node, "Temperature", s.temperature_c, 0.5f);
            changed |= sensor_set_param(node, "Humidity",    s.humidity_pct,   1.0f);
        }
        changed |= sensor_set_param(node, "Soil_Moisture", (float)s.soil_pct, 1.0f);
        if (s.air_valid) {
            changed |= sensor_set_param(node, "CO",      s.co_ppm,      1.0f);
            changed |= sensor_set_param(node, "Alcohol", s.alcohol_ppm, 1.0f);
            changed |= sensor_set_param(node, "CO2",     s.co2_ppm,     5.0f);
        }

        /* Publish immediately when something moved, rather than waiting up to a
         * minute for the main loop — the same reasoning as the AC feedback path
         * in input_monitor.c. */
        if (changed) {
            mqtt_publish_params_local(node);
        }

        vTaskDelay(pdMS_TO_TICKS(SHE_SENSOR_PERIOD_MS));
    }
}

/* =============================================================================
 * Public API
 * ==========================================================================*/

#if SHE_PINMAP_MODE
/* =============================================================================
 * Terminal → GPIO pin mapper (diagnostic build)
 * =============================================================================
 *
 * Drives each candidate GPIO in turn as a push-pull output at 2 Hz for 6 s,
 * logging which GPIO is active. Watch a DC voltmeter (or an LED) on one screw
 * terminal: the terminal that toggles 0 <-> 3.3 V during the "GPIOxx" window is
 * wired to that GPIO. Repeat per terminal to build the full map, then set the
 * SHE_*_GPIO macros and rebuild with SHE_PINMAP_MODE=0.
 */
static void pinmap_run(void) {
    static const int pins[] = {
        SHE_DHT11_GPIO, SHE_MQ135_GPIO, SHE_SOIL_GPIO,
        2, 14, 16, 19, 21, 22, 23, 25, 26
    };
    const int n = (int)(sizeof(pins) / sizeof(pins[0]));

    ESP_LOGW(TAG, "================= PINMAP MODE =================");
    ESP_LOGW(TAG, "Each GPIO blinks 2 Hz for 6 s, one at a time, in this order:");
    for (int i = 0; i < n; i++) {
        ESP_LOGW(TAG, "  %2d) GPIO%d", i + 1, pins[i]);
    }
    ESP_LOGW(TAG, "Put a DC voltmeter on ONE terminal; note WHICH window makes it");
    ESP_LOGW(TAG, "toggle 0<->3.3V. That window's GPIO is that terminal's GPIO.");
    ESP_LOGW(TAG, "===============================================");

    for (int i = 0; i < n; i++) {
        const int g = pins[i];
        gpio_config_t out = {
            .pin_bit_mask = (1ULL << g),
            .mode         = GPIO_MODE_INPUT_OUTPUT,   /* push-pull: strong drive */
            .pull_up_en   = GPIO_PULLUP_DISABLE,
            .pull_down_en = GPIO_PULLDOWN_DISABLE,
            .intr_type    = GPIO_INTR_DISABLE,
        };
        gpio_config(&out);
        ESP_LOGW(TAG, ">>> [%d/%d] NOW DRIVING GPIO%d for 6 s <<<", i + 1, n, g);
        for (int k = 0; k < 6; k++) {
            gpio_set_level(g, 1);
            vTaskDelay(pdMS_TO_TICKS(500));
            gpio_set_level(g, 0);
            vTaskDelay(pdMS_TO_TICKS(500));
        }
        gpio_set_level(g, 0);
        /* Release the pin back to a plain input so the next one is clean. */
        gpio_config_t in = {
            .pin_bit_mask = (1ULL << g),
            .mode         = GPIO_MODE_INPUT,
            .pull_up_en   = GPIO_PULLUP_DISABLE,
            .pull_down_en = GPIO_PULLDOWN_DISABLE,
            .intr_type    = GPIO_INTR_DISABLE,
        };
        gpio_config(&in);
        vTaskDelay(pdMS_TO_TICKS(1500));   /* pause so you can note the result */
    }
    ESP_LOGW(TAG, "================= PINMAP DONE =================");
}
#endif /* SHE_PINMAP_MODE */

esp_err_t sensors_init(void) {
#if SHE_PINMAP_MODE
    /* Dedicated mapping session: run the mapper first, then continue to normal
     * init so the board still boots (relays/Wi-Fi). Boot is ~90 s slower. */
    pinmap_run();
#endif
    if (!g_lock) {
        g_lock = xSemaphoreCreateMutex();
        if (!g_lock) {
            ESP_LOGE(TAG, "Could not create sensor mutex");
            return ESP_ERR_NO_MEM;
        }
    }
    memset(&g_latest, 0, sizeof(g_latest));

    /* Reset the runtime DHT pin to the configured default before auto-detect. */
    g_dht_gpio = SHE_DHT11_GPIO;

    /* Survey which sensor pins carry an external pull-up, BEFORE configuring them
     * for their real functions. INFORMATIONAL ONLY — floating empty pins read
     * HIGH/LOW inconsistently, so this is NOT a reliable pin locator (that is
     * what dht_find_pin() below is for). */
    sensor_pin_survey();

    /* Auto-detect which terminal the DHT is really on. The custom PCB has four
     * data terminals and no published pin map, so the firmware assumes GPIO 27;
     * if the sensor is on a different terminal it would otherwise never answer. */
    const int found = dht_find_pin();
    if (found >= 0) {
        g_dht_gpio = found;
        if (found == SHE_DHT11_GPIO) {
            ESP_LOGI(TAG, "DHT auto-detect: confirmed on GPIO%d (matches config)", found);
        } else {
            ESP_LOGW(TAG, "DHT auto-detect: sensor is on GPIO%d, NOT the configured GPIO%d. "
                          "Using GPIO%d. NOTE: this collides with the %s pin — that sensor will "
                          "be disabled so the two do not fight for the same line.",
                     found, SHE_DHT11_GPIO, found,
                     found == SHE_MQ135_GPIO ? "MQ-135" : "soil");
        }
    } else {
        ESP_LOGW(TAG, "DHT auto-detect found nothing; keeping configured GPIO%d", SHE_DHT11_GPIO);
    }

    /* Baseline for the periodic re-detect in the sensor task. The boot scan above
     * bumps g_dht_fails for every pin it probes, so without this the task would
     * see "already failing" and immediately scan a second time. */
    s_fails_at_last_detect = g_dht_fails;
    s_last_detect_tick     = xTaskGetTickCount();

    /* Decisive hardware check: record the raw line edges on every candidate GPIO
     * after a start pulse. This distinguishes a dead/unwired sensor (no edges
     * anywhere) from a live one the decoder is mishandling (edges on one pin). */
    dht_edge_scan();

    /* Configure the DHT bus on the detected pin. */
    esp_err_t dht_err  = dht_bus_init(g_dht_gpio);

    /* Analogue sensors — skip any that share the DHT's pin (hardware conflict).
     * The DHT is open-drain 1-wire and would be reconfigured as ADC, breaking it. */
    esp_err_t air_err  = ESP_OK;
    esp_err_t soil_err = ESP_OK;
    if (g_dht_gpio == SHE_MQ135_GPIO) {
        ESP_LOGW(TAG, "MQ-135 disabled: shares GPIO%d with the DHT", SHE_MQ135_GPIO);
        air_err = ESP_FAIL;
    } else {
        air_err = mq135_init();
    }
    if (g_dht_gpio == SHE_SOIL_GPIO) {
        ESP_LOGW(TAG, "Soil sensor disabled: shares GPIO%d with the DHT", SHE_SOIL_GPIO);
        soil_err = ESP_FAIL;
    } else {
        soil_err = soil_init();
    }

    /* Boot-time wiring check — only meaningful if the pin configured at all. */
    if (dht_err == ESP_OK) {
        dht_self_test();
    }

    if (dht_err != ESP_OK)  ESP_LOGW(TAG, "DHT%d unavailable — no temperature/humidity", SHE_DHT_MODEL);
    if (air_err != ESP_OK)  ESP_LOGW(TAG, "MQ-135 ADC unavailable — no air quality");
    if (soil_err != ESP_OK) ESP_LOGW(TAG, "Soil ADC unavailable — no soil moisture");

    if (dht_err != ESP_OK && air_err != ESP_OK && soil_err != ESP_OK) {
        return ESP_FAIL;   /* nothing usable — do not start a task that logs nothing */
    }
    ESP_LOGI(TAG, "Sensors initialised: DHT%d=GPIO%d (auto-detected from configured %d), "
                  "MQ-135=ADC1_CH%d(GPIO%d), soil=ADC1_CH%d(GPIO%d)",
             SHE_DHT_MODEL, g_dht_gpio, SHE_DHT11_GPIO,
             SHE_MQ135_ADC_CHANNEL, SHE_MQ135_GPIO,
             SHE_SOIL_ADC_CHANNEL, SHE_SOIL_GPIO);
    return ESP_OK;
}

esp_err_t sensors_start(she_node_t *node) {
    if (g_running) return ESP_ERR_INVALID_STATE;
    if (!g_lock) {
        ESP_LOGE(TAG, "sensors_start() before sensors_init()");
        return ESP_ERR_INVALID_STATE;
    }
    /* 4096 bytes: the log line alone formats nine floats, and ESP_LOG with
     * floats is stack-hungry. The old firmware used 2048 for the DHT task and
     * never formatted this much. */
    if (xTaskCreate(sensor_task, "sensors", 4096, node, 4, NULL) != pdPASS) {
        ESP_LOGE(TAG, "Could not create the sensor task");
        return ESP_ERR_NO_MEM;
    }
    g_running = true;
    ESP_LOGI(TAG, "Sensor task started (%d ms period)", SHE_SENSOR_PERIOD_MS);
    return ESP_OK;
}

bool sensors_get_latest(sensor_sample_t *out) {
    if (!out || !g_lock) return false;
    bool ok = false;
    if (xSemaphoreTake(g_lock, pdMS_TO_TICKS(100)) == pdTRUE) {
        if (g_latest.samples > 0) {
            *out = g_latest;
            ok = true;
        }
        xSemaphoreGive(g_lock);
    }
    return ok;
}

bool sensors_is_running(void) {
    return g_running;
}

void sensors_set_soil_calibration(int raw_dry, int raw_wet) {
    if (raw_dry == raw_wet) {
        ESP_LOGW(TAG, "Ignoring soil calibration: dry and wet endpoints are equal");
        return;
    }
    g_soil_raw_dry = raw_dry;
    g_soil_raw_wet = raw_wet;
    ESP_LOGI(TAG, "Soil calibration set: dry=%d wet=%d", raw_dry, raw_wet);
}
