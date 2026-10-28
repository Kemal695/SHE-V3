/* =============================================================================
 * SHE V3 firmware — sensors.h
 * =============================================================================
 * Environmental sensors, ported from the reference SHE-V3 `sensors.c` (itself
 * ported from the RainMaker-era firmware):
 *
 *   DHT22    temperature + humidity      GPIO 27   (bit-banged 1-wire)
 *   MQ-135   air quality, 6 gas curves   GPIO 32   (ADC1 channel 4)
 *   Soil     moisture percentage         GPIO 33   (ADC1 channel 5)
 *
 * ---- DHT11 vs DHT22 (this board has a DHT22) --------------------------------
 * Both speak the same 1-wire protocol and 40-bit frame, but the DATA ENCODING
 * differs:
 *   DHT11: data[0]=humidity int, data[2]=temp int (data[1]/data[3] = 0)
 *   DHT22: humidity = ((data[0]<<8)|data[1]) / 10
 *          temp     = (((data[2]&0x7F)<<8)|data[3]) / 10, negative if data[2]&0x80
 * The reference used the DHT11 formula (`data[0]+data[1]/10`), which on a DHT22
 * returns garbage. This driver uses the 16-bit DHT22 formula (see sensors.c).
 *
 * ---- ADC notes that matter on this hardware ---------------------------------
 * Both analog sensors are on **ADC1**. ADC2 is unusable while Wi-Fi is running on
 * the classic ESP32 (the radio owns it), so an ADC2 sensor would silently read
 * garbage once the board associates. ADC1 channels 4 and 5 are GPIO 32 / 33.
 *
 * ---- Presence gating --------------------------------------------------------
 * A board that has only the DHT22 fitted must NOT report a soil % or gas PPM:
 * a fabricated 0 looks like a real (bone-dry / clean-air) reading. So the soil
 * value is only marked valid when its raw count is off the ADC rails, and the
 * MQ-135 only after a successful R0 calibration. Until then those params stay 0
 * and are omitted from the telemetry payload.
 * ==========================================================================*/

#ifndef SHE_SENSORS_H
#define SHE_SENSORS_H

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"
#include "device_profiles.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Pin / channel assignment ---- */
#define SHE_DHT22_GPIO        27
#define SHE_MQ135_ADC_CHANNEL 4    /* ADC1 channel 4 = GPIO 32 */
#define SHE_MQ135_GPIO        32
#define SHE_SOIL_ADC_CHANNEL  5    /* ADC1 channel 5 = GPIO 33 */
#define SHE_SOIL_GPIO         33

/* ---- Sampling cadence ----
 * 30 s. The DHT22 datasheet demands >= 2 s between reads; the MQ-135 wants a
 * settled heater; the soil probe is passive. 30 s keeps the dashboard feeling
 * live without hammering the sensors, and two samples land in every 60 s
 * telemetry window. */
#define SHE_SENSOR_PERIOD_MS  30000

/* DHT22 retries per cycle (a single checksum failure is normal). */
#define SHE_DHT22_ATTEMPTS    3
#define SHE_DHT22_RETRY_MS    2100

/* ---- MQ-135 calibration ----
 * R0 = the sensor's resistance in clean air, averaged over N samples taken inside
 * the sampling task (NOT at boot, so boot is never blocked). Best-effort in-situ
 * figure — a proper value needs a 24-48 h burn-in in genuinely clean air. */
#define SHE_MQ135_CAL_SAMPLES      10
#define SHE_MQ135_CAL_INTERVAL_MS  500
#define SHE_MQ135_RATIO_CLEAN_AIR  3.6f

/* Load resistor on the MQ-135 module, in kOhm. */
#define SHE_MQ135_RL_KOHM          10.0f

/* ---- ADC scaling ----
 * Both channels use 11 dB attenuation (~0-3.1 V) with a 3.3 V reference. (The
 * reference firmware's MQ-135 used 0 dB but converted with a 3.3 V reference, so
 * anything above ~1.1 V clamped — fixed here.) */
#define SHE_ADC_FULL_SCALE     4095.0f   /* 12-bit */
#define SHE_ADC_VREF_MV        3300.0f

/* ---- Soil moisture calibration ----
 * Defaults reproduce the old `100 - raw*100/4095` formula. Move them once the
 * real probe's air/water endpoints are measured via sensors_set_soil_calibration(). */
#define SHE_SOIL_RAW_DRY_DEFAULT  4095
#define SHE_SOIL_RAW_WET_DEFAULT  0

/* Raw ADC counts considered "off the rails". A disconnected / floating pin
 * usually rails at 0 or 4095; a real probe sits in between. */
#define SHE_SOIL_RAW_MIN_VALID    30
#define SHE_SOIL_RAW_MAX_VALID    4060

/* ---- One reading of every sensor ---- */
typedef struct sensor_sample {
    /* DHT22 — false until a checksum-valid frame has been decoded */
    bool  dht_valid;
    float temperature_c;
    float humidity_pct;

    /* Soil moisture */
    bool  soil_valid;
    int   soil_pct;
    int   soil_raw;

    /* MQ-135 */
    bool  air_valid;          /* false until R0 has been calibrated */
    float co_ppm;
    float alcohol_ppm;
    float co2_ppm;
    float toluene_ppm;        /* computed + logged, not published */
    float nh3_ppm;            /* computed + logged, not published */
    float acetone_ppm;        /* computed + logged, not published */
    float air_voltage;        /* the raw voltage the curves were derived from */
    float r0_kohm;

    /* Bookkeeping */
    uint32_t samples;         /* completed sampling cycles */
    uint32_t dht_failures;    /* cumulative checksum/timeout failures */
} sensor_sample_t;

/**
 * Configure GPIO + ADC. Does NOT touch the sensors and does NOT block.
 * Safe to call before Wi-Fi is up. Returns ESP_OK even if a sensor is absent.
 */
esp_err_t sensors_init(void);

/**
 * Start the sampling task. Must be called AFTER the node profile exists (the
 * task writes readings into the Sensors device's params). Returns as soon as the
 * task is created — it never blocks the caller.
 */
esp_err_t sensors_start(she_node_t *node);

/**
 * Copy the most recent reading. Returns false if no cycle has completed yet.
 * Locked against the sampling task, so the caller always sees a coherent set.
 */
bool sensors_get_latest(sensor_sample_t *out);

/** True if the sampling task is running. */
bool sensors_is_running(void);

/**
 * Override the soil probe's dry/wet raw endpoints. Call before sensors_start().
 */
void sensors_set_soil_calibration(int raw_dry, int raw_wet);

#ifdef __cplusplus
}
#endif

#endif /* SHE_SENSORS_H */
