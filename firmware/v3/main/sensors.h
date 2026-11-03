/* =============================================================================
 * SHE V3 firmware — sensors.h
 * =============================================================================
 * Environmental sensors, ported from the RainMaker-era firmware
 * (`SMTHIOT24_Firmware/HOME-DEMO`): DHT22 (AM2302), MQ-135 and a soil-moisture probe.
 *
 *   DHT22    temperature + humidity      GPIO 27   (bit-banged 1-wire; DHT11 also supported)
 *   MQ-135   air quality, 6 gas curves   GPIO 32   (ADC1 channel 4)
 *   Soil     moisture percentage         GPIO 33   (ADC1 channel 5)
 *
 * ---- Why this file did not exist until now -----------------------------------
 * The R24 build had NO environmental sensors at all: its only sensing was the
 * state of its own relays and loads through the four PCF8574 input expanders
 * (see input_monitor.c). The sensor set existed only in the old RainMaker
 * firmware, which is what this file ports. Everything below is a deliberate
 * adaptation of that code, not a copy — the changes are listed in sensors.c.
 *
 * ---- ADC notes that matter on this hardware ----------------------------------
 * Both analog sensors are on **ADC1**. That is not a preference: ADC2 is
 * unusable while Wi-Fi is running on the classic ESP32 (the radio owns it), so
 * a sensor on ADC2 would silently read garbage or fail to read at all once the
 * board associates. ADC1 channels 4 and 5 are GPIO 32 and 33 respectively.
 *
 * GPIO 27 (DHT22 / AM2302) and GPIO 32/33 are free on the SHE-R24 board: the output
 * expanders are on I²C bus 0 (SDA 15 / SCL 13), the input expanders on bus 1
 * (SDA 4 / SCL 5), the button is GPIO 0, and 6-11 are the flash group.
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
#define SHE_DHT11_GPIO        27   /* DHT data line — adopted from reference repo (GPIO 27) */
/* DHT device model the board carries: 11 (DHT11) or 22 (DHT22 / AM2302).
 * Both parts share the same 1-Wire bus protocol; only the 40-bit payload
 * decode differs (handled in sensors.c). 22 is the default because the
 * SHE-R24 sensor header carries a DHT22. */
#ifndef SHE_DHT_MODEL
#define SHE_DHT_MODEL         22
#endif

/* Boot-time diagnostic: once at startup, toggle GPIO 27 so the physical pin
 * that maps to the DHT DATA line can be located with a DC voltmeter, and read
 * the idle line with the internal pull-up OFF to confirm the DHT module's own
 * pull-up is electrically present on this pin. Set to 0 once the sensor reads.
 * See dht_self_test() in sensors.c for how to read the result. */
#ifndef SHE_DHT_PROBE
#define SHE_DHT_PROBE          1
#endif

/* ---- Terminal → GPIO pin-map mode ------------------------------------------
 * There is NO published schematic for the 6-terminal sensor block (1-4 = DATA,
 * + GND + 3.3V), so the terminal→GPIO map must be measured. Set this to 1 and
 * flash a dedicated "mapper" build: at boot the firmware drives each candidate
 * GPIO in turn with a slow 2 Hz blink (6 s each) and logs "NOW DRIVING GPIOx".
 * Put a DC voltmeter (or an LED) on each terminal and note which GPIO window
 * makes it toggle — that IS the real map. Then set SHE_DHT11_GPIO /
 * SHE_MQ135_GPIO / SHE_SOIL_GPIO below to the measured values and rebuild with
 * this flag back to 0.
 *
 * Known already (from the backend telemetry, 846 readings Oct 27–Nov 1):
 *   the DHT's DATA terminal == GPIO27 (it read real values for days there).
 * --------------------------------------------------------------------------- */
#ifndef SHE_PINMAP_MODE
#define SHE_PINMAP_MODE        0
#endif
#define SHE_MQ135_ADC_CHANNEL 4    /* ADC1 channel 4 = GPIO 32 */
#define SHE_MQ135_GPIO        32
#define SHE_SOIL_ADC_CHANNEL  5    /* ADC1 channel 5 = GPIO 33 */
#define SHE_SOIL_GPIO         33

/* ---- Sampling cadence ----
 * 30 s. The DHT22 (and DHT11) datasheet demands >= 2 s between reads and the part is only
 * accurate to about 1 Hz anyway; the MQ-135 wants a settled heater; the soil
 * probe is passive. 30 s keeps the dashboard feeling live without hammering the
 * sensors, and two samples land in every 60 s telemetry window. */
#define SHE_SENSOR_PERIOD_MS  30000

/* ---- MQ-135 calibration ----
 * R0 is the sensor's resistance in clean air. The old firmware averaged 10
 * `calibrate(3.6)` samples 500 ms apart at boot, BEFORE Wi-Fi was up; here the
 * same average runs inside the sensor task instead, so boot is never blocked
 * (a 5 s stall before `app_wifi_connect()` risks the 30 s association window).
 *
 * ⚠ R0 is only as good as the air it was measured in. A proper value needs a
 * 24-48 h burn-in in genuinely clean air; this is a best-effort in-situ figure,
 * which is exactly what the old firmware produced too. */
#define SHE_MQ135_CAL_SAMPLES      10
#define SHE_MQ135_CAL_INTERVAL_MS  500
#define SHE_MQ135_RATIO_CLEAN_AIR  3.6f

/* Load resistor on the MQ-135 module, in kOhm. */
#define SHE_MQ135_RL_KOHM          10.0f

/* ---- ADC scaling ----
 * ⚠ This is a FIX to a real bug in the old firmware. It configured the MQ-135
 * channel with `ADC_ATTEN_DB_0`, whose full scale on an ESP32 is about 1.1 V,
 * and then converted the raw reading with a 3.3 V reference:
 *
 *     voltage = raw * 3.3 / 4095
 *
 * An MQ-135's analog output routinely exceeds 1.1 V, so the ADC pinned at 4095
 * for most of its useful range — every reading above ~1.1 V came out as exactly
 * 3.3 V, and the derived PPM was meaningless. The soil sensor in the same
 * firmware got this right (`ADC_ATTEN_DB_11`), which is how the inconsistency
 * was spotted.
 *
 * Both channels now use 11 dB attenuation (~0-3.1 V) with the same 3.3 V
 * reference, so the conversion is consistent and no longer saturates. R0 is
 * measured at runtime, so it re-derives itself and does not need to be carried
 * over — but any R0 value saved from the OLD firmware is invalid. */
#define SHE_ADC_FULL_SCALE     4095.0f   /* 12-bit */
#define SHE_ADC_VREF_MV        3300.0f

/* ---- Soil moisture calibration ----
 * The old firmware returned `100 - (raw * 100 / 4095)`, i.e. it assumed raw
 * 4095 = bone dry and raw 0 = submerged. Those are the endpoints of a
 * *resistive* probe; a capacitive probe idles around 2500-3000 in air.
 *
 * The two constants below are therefore the calibration. The defaults reproduce
 * the old formula EXACTLY (so readings do not jump when this firmware is
 * flashed), and can be moved once the real probe's air/water endpoints are
 * measured — see sensors_set_soil_calibration(). */
#define SHE_SOIL_RAW_DRY_DEFAULT  4095
#define SHE_SOIL_RAW_WET_DEFAULT  0

/* ---- One reading of every sensor ---- */
typedef struct {
    /* DHT — false until a checksum-valid frame has been decoded */
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
    float toluene_ppm;
    float nh3_ppm;
    float acetone_ppm;
    float air_voltage;        /* the raw voltage the curves were derived from */
    float r0_kohm;

    /* Bookkeeping */
    uint32_t samples;         /* completed sampling cycles */
    uint32_t dht_failures;    /* DHT checksum/timeout failures, cumulative */
} sensor_sample_t;

/**
 * Configure GPIO + ADC. Does NOT touch the sensors and does NOT block.
 *
 * Safe to call before Wi-Fi is up. Returns ESP_OK even if a sensor is absent —
 * a missing DHT must not stop the board from booting, because the relays are
 * the primary function.
 */
esp_err_t sensors_init(void);

/**
 * Start the sampling task.
 *
 * Must be called AFTER the node profile exists, because the task writes each
 * reading into the Sensors device's params and publishes `params/local` when a
 * value moves. Returns as soon as the task is created — it never blocks the
 * caller (see the note in sensors.c about the `while(true)` trap that once made
 * the physical button dead on the provisioning path).
 */
esp_err_t sensors_start(she_node_t *node);

/**
 * Copy the most recent reading. Returns false if no cycle has completed yet.
 *
 * Locked against the sampling task, so the caller always sees a coherent set —
 * half-updated values would show a new temperature against a stale humidity.
 */
bool sensors_get_latest(sensor_sample_t *out);

/** True if the sampling task is running. */
bool sensors_is_running(void);

/**
 * Override the soil probe's dry/wet raw endpoints.
 *
 * Call before sensors_start(). Useful because the correct values depend on the
 * physical probe, not the board.
 */
void sensors_set_soil_calibration(int raw_dry, int raw_wet);

#ifdef __cplusplus
}
#endif

#endif /* SHE_SENSORS_H */
