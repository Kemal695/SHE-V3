/* =============================================================================
 * SHE V3 firmware — sensors.c
 * =============================================================================
 * DHT22 (GPIO 27) + MQ-135 (ADC1 ch4 / GPIO 32) + soil moisture (ADC1 ch5 /
 * GPIO 33). Ported from the reference SHE-V3 sensors.c (RainMaker lineage).
 *
 * Changes vs the reference, all deliberate:
 *   1. DHT22 ENCODING (the important one). The reference used the DHT11 formula
 *      (`data[0] + data[1]/10`), which on a DHT22 yields a nonsense humidity and
 *      temperature. This uses the 16-bit DHT22 formula and the -40..+80 °C range.
 *   2. Soil/gas are PRESENCE-GATED. A board with only a DHT22 must not publish a
 *      fake soil % or PPM; soil is valid only off the ADC rails, gas only after a
 *      successful R0 calibration.
 *   3. MQ-135 attenuation is 11 dB with a 3.3 V reference (the reference used
 *      0 dB + 3.3 V reference, which clamped everything above ~1.1 V).
 *   4. `ets_delay_us()` -> `esp_rom_delay_us()` (rom/ets_sys.h is deprecated).
 *   5. The 40-bit DHT read runs in a critical section so a Wi-Fi ISR cannot
 *      stretch a bit past the decode threshold.
 * ==========================================================================*/

#include "sensors.h"
#include "she_mqtt.h"
#include "esp_log.h"
#include "esp_rom_sys.h"
#include "esp_adc/adc_oneshot.h"   /* IDF 5.x ADC API (driver/adc.h is gone) */
#include "driver/gpio.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include <math.h>
#include <string.h>

static const char *TAG = "she_sensors";

/* ---- Shared state --------------------------------------------------------- */

static sensor_sample_t   g_latest;            /* guarded by g_lock */
static SemaphoreHandle_t g_lock;
static bool              g_running;
static int               g_soil_raw_dry = SHE_SOIL_RAW_DRY_DEFAULT;
static int               g_soil_raw_wet = SHE_SOIL_RAW_WET_DEFAULT;
static portMUX_TYPE      g_dht_mux = portMUX_INITIALIZER_UNLOCKED;
static float             g_mq135_r0 = 0.0f;   /* kOhm, 0 = not calibrated */
static adc_oneshot_unit_handle_t g_adc1 = NULL;   /* ADC1 unit (MQ-135 + soil) */
static int               g_dht_gpio = SHE_DHT22_GPIO;  /* runtime-detected DHT pin */
static int               g_dht_status = 2;             /* 0=ok,1=handshake-only,2=none */

/* =============================================================================
 * DHT22 — bit-banged 1-wire, GPIO 27
 * ==========================================================================*/

static esp_err_t dht22_bus_init(void) {
    gpio_config_t cfg = {
        .pin_bit_mask = (1ULL << g_dht_gpio),
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
        ESP_LOGE(TAG, "DHT GPIO %d config failed: %s", g_dht_gpio, esp_err_to_name(err));
        return err;
    }
    gpio_set_level(g_dht_gpio, 1);   /* release the bus */
    return ESP_OK;
}

/** Wait until the line reads `level`. Returns microseconds waited, or -1. */
static int dht22_wait_for_level(int level, int timeout_us) {
    int waited = 0;
    while (gpio_get_level(g_dht_gpio) != level) {
        if (waited >= timeout_us) return -1;
        esp_rom_delay_us(1);
        waited++;
    }
    return waited;
}

/* Forward declaration — dht22_detect() below uses this before its definition. */
static esp_err_t dht22_read_once(float *temperature_c, float *humidity_pct);

/**
 * Probe one GPIO for a DHT-style sensor: send the start pulse and see whether
 * the line is pulled LOW (the sensor's response) within ~150 µs. An idle line
 * stays HIGH because of the pull-up.
 */
static bool dht22_probe_pin(int gpio) {
    gpio_config_t cfg = {
        .pin_bit_mask = (1ULL << gpio),
        .mode         = GPIO_MODE_INPUT_OUTPUT_OD,
        .pull_up_en   = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type    = GPIO_INTR_DISABLE,
    };
    if (gpio_config(&cfg) != ESP_OK) return false;
    gpio_set_level(gpio, 1);          /* release the bus */
    esp_rom_delay_us(2000);           /* settle */
    /* A real DHT data line idles HIGH (pull-up). A pin that idles LOW has an
     * external pull-down (strapping / LED) and is not a sensor — skip it. */
    if (gpio_get_level(gpio) != 1) return false;
    /* Start pulse: >=18 ms for DHT11, >=1 ms for DHT22. 20 ms satisfies both. */
    gpio_set_level(gpio, 0);
    esp_rom_delay_us(20000);
    gpio_set_level(gpio, 1);
    esp_rom_delay_us(30);
    int w = 0;
    while (gpio_get_level(gpio) != 0) {
        if (w >= 150) return false;       /* nothing pulled it low */
        esp_rom_delay_us(1);
        w++;
    }
    return true;
}

/** Find the GPIO the DHT is wired to. Returns -1 if none responded. */
static int dht22_detect(void) {
    /* Documented-free pins first (27/32/33), then the direct-relay pins
     * (21/22/18/19 — unused in PCF8574 mode) and the rest of the free set. */
    static const int cand[] = { 27, 32, 33, 21, 22, 18, 19, 14, 25, 26, 2, 23,
                                12, 16, 17 };
    int weak = -1;   /* handshake worked but no valid frame */
    float t, h;

    for (size_t i = 0; i < sizeof(cand) / sizeof(cand[0]); i++) {
        if (!dht22_probe_pin(cand[i])) continue;   /* nothing pulled the line low */

        /* A pin with an external pull-down also reads "low" after release, so
         * a handshake alone is not proof. Require a full valid frame. */
        g_dht_gpio = cand[i];
        if (dht22_bus_init() != ESP_OK) continue;
        for (int attempt = 0; attempt < 2; attempt++) {
            if (dht22_read_once(&t, &h) == ESP_OK) {
                ESP_LOGI(TAG, "DHT valid frame on GPIO %d (T=%.1f H=%.1f)",
                         cand[i], t, h);
                g_dht_status = 0;
                return cand[i];
            }
        }
        if (weak < 0) weak = cand[i];   /* handshake-only candidate */
    }

    if (weak >= 0) {
        ESP_LOGW(TAG, "DHT handshake on GPIO %d but no valid frame — check pull-up",
                 weak);
        g_dht_status = 1;
        return weak;
    }
    g_dht_status = 2;
    return -1;
}

/**
 * One read attempt. Returns ESP_OK and fills t/h, or ESP_FAIL.
 *
 * Bits are decoded by RELATIVE pulse width (high period longer than the low
 * period => 1). Absolute thresholds break as soon as the CPU clock or interrupt
 * latency changes — which is exactly what happens when Wi-Fi comes up.
 */
static esp_err_t dht22_read_once(float *temperature_c, float *humidity_pct) {
    if (!temperature_c || !humidity_pct) return ESP_FAIL;

    uint8_t data[5] = {0, 0, 0, 0, 0};

    /* ---- Start signal ----
     * 20 ms: the DHT11 datasheet requires >= 18 ms; the DHT22 needs >= 1 ms, so
     * 20 ms satisfies both. (2 ms was too short for a DHT11 — it could handshake
     * but never deliver a valid frame.) */
    gpio_set_level(g_dht_gpio, 0);
    esp_rom_delay_us(20000);
    gpio_set_level(g_dht_gpio, 1);        /* release */
    esp_rom_delay_us(30);                 /* sensor pulls low within 20-40 µs */

    /* ---- Handshake: low 80 µs, high 80 µs, then the first low ---- */
    if (dht22_wait_for_level(0, 150) < 0 ||
        dht22_wait_for_level(1, 150) < 0 ||
        dht22_wait_for_level(0, 150) < 0) {
        return ESP_FAIL;                  /* no sensor, or it did not respond */
    }

    /* ---- 40 bits ---- */
    portENTER_CRITICAL(&g_dht_mux);
    for (int i = 0; i < 5; i++) {
        for (int j = 0; j < 8; j++) {
            const int low_us  = dht22_wait_for_level(1, 120);  /* ~50 µs */
            const int high_us = dht22_wait_for_level(0, 120);  /* 27 µs = 0, 70 µs = 1 */
            if (low_us < 0 || high_us < 0) {
                portEXIT_CRITICAL(&g_dht_mux);
                return ESP_FAIL;
            }
            data[i] |= (uint8_t)((high_us > low_us) << (7 - j));
        }
    }
    portEXIT_CRITICAL(&g_dht_mux);

    const uint8_t checksum = (uint8_t)(data[0] + data[1] + data[2] + data[3]);
    if (checksum != data[4]) {
        ESP_LOGW(TAG, "DHT checksum mismatch (got 0x%02X, computed 0x%02X)",
                 data[4], checksum);
        return ESP_FAIL;
    }

    /* ---- Try the DHT22 16-bit encoding first ---- */
    float rh = (float)(((uint16_t)data[0] << 8) | data[1]) / 10.0f;
    int16_t raw_t = (int16_t)(((uint16_t)(data[2] & 0x7F) << 8) | data[3]);
    float tc = (float)raw_t / 10.0f;
    if (data[2] & 0x80) tc = -tc;         /* sign bit */

    if (tc >= -40.0f && tc <= 80.0f && rh >= 0.0f && rh <= 100.0f) {
        *temperature_c = tc;
        *humidity_pct  = rh;
        return ESP_OK;
    }

    /* ---- Fall back to the DHT11 8-bit encoding ----
     * A DHT11 frame read with the DHT22 formula lands far outside the range
     * (e.g. 45% / 23 °C -> 1152% / 588 °C) and would otherwise read as 0. */
    const float rh11 = (float)data[0] + (float)data[1] / 10.0f;
    const float tc11 = (float)data[2] + (float)data[3] / 10.0f;
    if (tc11 >= -40.0f && tc11 <= 80.0f && rh11 >= 0.0f && rh11 <= 100.0f) {
        *temperature_c = tc11;
        *humidity_pct  = rh11;
        return ESP_OK;
    }

    ESP_LOGW(TAG, "DHT out of range (T22=%.1f H22=%.1f / T11=%.1f H11=%.1f) — discarding",
             tc, rh, tc11, rh11);
    return ESP_FAIL;
}

/** Read with a few spaced retries (a single checksum failure is normal). */
static esp_err_t dht22_read(float *temperature_c, float *humidity_pct) {
    for (int attempt = 0; attempt < SHE_DHT22_ATTEMPTS; attempt++) {
        if (dht22_read_once(temperature_c, humidity_pct) == ESP_OK) {
            return ESP_OK;
        }
        if (attempt + 1 < SHE_DHT22_ATTEMPTS) {
            vTaskDelay(pdMS_TO_TICKS(SHE_DHT22_RETRY_MS));
        }
    }
    return ESP_FAIL;
}

/* =============================================================================
 * MQ-135 — air quality, ADC1 channel 4 (GPIO 32)
 * ==========================================================================*/

typedef struct {
    const char *name;
    float a;
    float b;
    float offset;   /* added after the curve (CO2 is referenced to fresh air) */
} mq135_curve_t;

/* Datasheet curves: PPM = a * ratio^b + offset, where ratio = RS / R0. */
static const mq135_curve_t k_curves[] = {
    { "CO",      605.18f, -3.937f,   0.0f },
    { "Alcohol",  77.255f, -3.18f,   0.0f },
    { "CO2",     110.47f, -2.862f, 400.0f },   /* CO2_OFFSET */
    { "Toluene",  44.947f, -3.445f,  0.0f },
    { "NH3",     102.2f,  -2.473f,   0.0f },
    { "Acetone",  34.668f, -3.369f,  0.0f },
};

/** Create the ADC1 oneshot unit once (shared by MQ-135 and soil). */
static esp_err_t adc1_setup(void) {
    if (g_adc1) return ESP_OK;
    adc_oneshot_unit_init_cfg_t init_cfg = { .unit_id = ADC_UNIT_1 };
    esp_err_t err = adc_oneshot_new_unit(&init_cfg, &g_adc1);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "ADC1 unit init failed: %s", esp_err_to_name(err));
        g_adc1 = NULL;
    }
    return err;
}

/** 11 dB attenuation (~0-3.1 V) + 12-bit, per channel. */
static esp_err_t adc1_config_ch(adc_channel_t ch) {
    adc_oneshot_chan_cfg_t cfg = {
        .atten    = ADC_ATTEN_DB_11,
        .bitwidth = ADC_BITWIDTH_12,
    };
    esp_err_t err = adc_oneshot_config_channel(g_adc1, ch, &cfg);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "ADC1 channel %d config failed: %s", (int)ch, esp_err_to_name(err));
    }
    return err;
}

/** Mean of 8 raw reads — one ADC sample on this part is noisy by ~2%. */
static int adc1_read_mean(adc_channel_t ch) {
    if (!g_adc1) return 0;
    int32_t sum = 0;
    int ok = 0;
    for (int i = 0; i < 8; i++) {
        int raw = 0;
        if (adc_oneshot_read(g_adc1, ch, &raw) == ESP_OK) {
            sum += raw;
            ok++;
        }
    }
    return ok > 0 ? (int)(sum / ok) : 0;
}

static esp_err_t mq135_init(void) {
    esp_err_t err = adc1_setup();
    if (err != ESP_OK) return err;
    return adc1_config_ch((adc_channel_t)SHE_MQ135_ADC_CHANNEL);
}

static float mq135_read_voltage(void) {
    const int raw = adc1_read_mean((adc_channel_t)SHE_MQ135_ADC_CHANNEL);
    return (float)raw * SHE_ADC_VREF_MV / SHE_ADC_FULL_SCALE / 1000.0f;   /* volts */
}

/** RS at the current voltage, in kOhm, or -1 if the reading is unusable. */
static float mq135_rs_kohm(float voltage, float vc, float rl) {
    if (voltage < 0.01f) return -1.0f;      /* open circuit / floating pin */
    if (voltage > vc - 0.01f) return -1.0f; /* saturated — no headroom */
    const float rs = (vc * rl / voltage) - rl;
    return rs > 0.0f ? rs : 0.0f;
}

/**
 * R0 = RS_in_clean_air / RATIO_CLEAN_AIR, averaged over N samples.
 * Blocks for N * interval (5 s) — called from the sensor TASK, never from boot.
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
        ESP_LOGE(TAG, "MQ-135 calibration failed: no usable sample. Check the "
                      "analog wiring and that the module has 5 V (heater).");
        return -1.0f;
    }
    return sum / (float)good;
}

/* =============================================================================
 * Soil moisture — ADC1 channel 5 (GPIO 33)
 * ==========================================================================*/

static esp_err_t soil_init(void) {
    esp_err_t err = adc1_setup();
    if (err != ESP_OK) return err;
    return adc1_config_ch((adc_channel_t)SHE_SOIL_ADC_CHANNEL);
}

static int soil_read_raw(void) {
    return adc1_read_mean((adc_channel_t)SHE_SOIL_ADC_CHANNEL);
}

/** Raw counts -> percentage between the two calibrated endpoints. */
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

            /* Only publish on a real move — a DHT22 dithers by a tenth of a
             * degree and the ADC by a few counts. */
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
 * A FreeRTOS task body must never return. This is a task body (not a helper
 * called from app_main), and sensors_start() returns as soon as it exists.
 */
static void sensor_task(void *arg) {
    she_node_t *node = (she_node_t *)arg;

    /* ---- Detect which GPIO the DHT is wired to ----
     * This board's "port 1" is not documented and the sensor may have been
     * plugged into any of the free pins, so probe once at startup instead of
     * trusting the compile-time default. */
    {
        vTaskDelay(pdMS_TO_TICKS(800));   /* let the sensor power up / settle */
        const int found = dht22_detect();
        if (found >= 0) {
            g_dht_gpio = found;
            ESP_LOGI(TAG, "DHT detected on GPIO %d", g_dht_gpio);
        } else {
            ESP_LOGW(TAG, "No DHT response on any probed GPIO — keeping fallback GPIO %d",
                     g_dht_gpio);
        }
        dht22_bus_init();   /* (re)configure whichever pin we settled on */
        /* Publish the detected pin (-1 = none) so it is visible in /she/info
         * without a serial console. */
        sensor_set_param(node, "DHT_GPIO", (float)(found >= 0 ? found : -1), 0.5f);
        sensor_set_param(node, "DHT_Status", (float)g_dht_status, 0.5f);
        /* Idle level of the detected pin: 1 = pulled up (real data line),
         * 0 = pulled down (strapping/LED pin -> false positive). */
        {
            gpio_config_t icfg = {
                .pin_bit_mask = (1ULL << g_dht_gpio),
                .mode         = GPIO_MODE_INPUT,
                .pull_up_en   = GPIO_PULLUP_ENABLE,
                .pull_down_en = GPIO_PULLDOWN_DISABLE,
                .intr_type    = GPIO_INTR_DISABLE,
            };
            gpio_config(&icfg);
            vTaskDelay(pdMS_TO_TICKS(5));
            sensor_set_param(node, "DHT_Idle", (float)gpio_get_level(g_dht_gpio), 0.5f);
            dht22_bus_init();   /* restore open-drain for reads */
        }
        mqtt_publish_params_local(node);
    }

    /* ---- Calibrate the MQ-135 once, in here rather than at boot ---- */
    ESP_LOGI(TAG, "MQ-135 calibrating (%d samples, ~%d ms) — keep the sensor in clean air",
             SHE_MQ135_CAL_SAMPLES, SHE_MQ135_CAL_SAMPLES * SHE_MQ135_CAL_INTERVAL_MS);
    g_mq135_r0 = mq135_calibrate();
    if (g_mq135_r0 > 0.0f) {
        ESP_LOGI(TAG, "MQ-135 R0 = %.2f kOhm", g_mq135_r0);
    } else {
        ESP_LOGW(TAG, "MQ-135 unavailable — air-quality values will not be published");
    }

    while (true) {
        sensor_sample_t s;
        memset(&s, 0, sizeof(s));

        /* ---- DHT22 ---- */
        if (dht22_read(&s.temperature_c, &s.humidity_pct) == ESP_OK) {
            s.dht_valid = true;
        } else {
            s.dht_failures++;
        }

        /* ---- Soil (only when off the ADC rails = a probe is present) ---- */
        s.soil_raw = soil_read_raw();
        if (s.soil_raw > SHE_SOIL_RAW_MIN_VALID && s.soil_raw < SHE_SOIL_RAW_MAX_VALID) {
            s.soil_pct   = soil_raw_to_pct(s.soil_raw);
            s.soil_valid = true;
        }

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
            s.dht_failures += g_latest.dht_failures;
            g_latest = s;
            xSemaphoreGive(g_lock);
        }

        ESP_LOGI(TAG, "T=%.1fC H=%.1f%%%s  soil=%d%%%s (raw %d)  CO2=%.0f CO=%.1f Alc=%.1f ppm%s  "
                      "[Tol=%.1f NH3=%.1f Ace=%.1f not published]",
                 s.temperature_c, s.humidity_pct, s.dht_valid ? "" : "(DHT fail)",
                 s.soil_valid ? s.soil_pct : -1, s.soil_valid ? "" : "(no probe)", s.soil_raw,
                 s.co2_ppm, s.co_ppm, s.alcohol_ppm, s.air_valid ? "" : "(no gas)",
                 s.toluene_ppm, s.nh3_ppm, s.acetone_ppm);

        /* ---- Mirror into the Sensors device params ---- */
        bool changed = false;
        if (s.dht_valid) {
            changed |= sensor_set_param(node, "Temperature", s.temperature_c, 0.5f);
            changed |= sensor_set_param(node, "Humidity",    s.humidity_pct,   1.0f);
        }
        if (s.soil_valid) {
            changed |= sensor_set_param(node, "Soil_Moisture", (float)s.soil_pct, 1.0f);
        }
        if (s.air_valid) {
            changed |= sensor_set_param(node, "CO",      s.co_ppm,      1.0f);
            changed |= sensor_set_param(node, "Alcohol", s.alcohol_ppm, 1.0f);
            changed |= sensor_set_param(node, "CO2",     s.co2_ppm,     5.0f);
        }
        if (changed) {
            mqtt_publish_params_local(node);
        }

        vTaskDelay(pdMS_TO_TICKS(SHE_SENSOR_PERIOD_MS));
    }
}

/* =============================================================================
 * Public API
 * ==========================================================================*/

esp_err_t sensors_init(void) {
    if (!g_lock) {
        g_lock = xSemaphoreCreateMutex();
        if (!g_lock) {
            ESP_LOGE(TAG, "Could not create sensor mutex");
            return ESP_ERR_NO_MEM;
        }
    }
    memset(&g_latest, 0, sizeof(g_latest));

    /* Every failure below is logged and tolerated. The relays are the board's
     * primary function; a missing sensor must never stop it booting. */
    esp_err_t dht_err  = dht22_bus_init();
    esp_err_t air_err  = mq135_init();
    esp_err_t soil_err = soil_init();

    if (dht_err != ESP_OK)  ESP_LOGW(TAG, "DHT22 unavailable — no temperature/humidity");
    if (air_err != ESP_OK)  ESP_LOGW(TAG, "MQ-135 ADC unavailable — no air quality");
    if (soil_err != ESP_OK) ESP_LOGW(TAG, "Soil ADC unavailable — no soil moisture");

    if (dht_err != ESP_OK && air_err != ESP_OK && soil_err != ESP_OK) {
        return ESP_FAIL;
    }
    ESP_LOGI(TAG, "Sensors initialised: DHT22=GPIO%d, MQ-135=ADC1_CH%d(GPIO%d), "
                  "soil=ADC1_CH%d(GPIO%d)",
             SHE_DHT22_GPIO, SHE_MQ135_ADC_CHANNEL, SHE_MQ135_GPIO,
             SHE_SOIL_ADC_CHANNEL, SHE_SOIL_GPIO);
    return ESP_OK;
}

esp_err_t sensors_start(she_node_t *node) {
    if (g_running) return ESP_ERR_INVALID_STATE;
    if (!g_lock) {
        ESP_LOGE(TAG, "sensors_start() before sensors_init()");
        return ESP_ERR_INVALID_STATE;
    }
    /* 4096 bytes: the log line formats nine floats, and ESP_LOG with floats is
     * stack-hungry. */
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
