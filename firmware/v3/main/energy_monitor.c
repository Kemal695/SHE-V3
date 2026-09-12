/* =============================================================================
 * SHE V3 firmware — energy_monitor.c
 * =============================================================================
 * PZEM-004T v3 driver. V3-FIRMWARE §9. V3-ENERGY-MONITORING §3.
 * Modbus RTU master. Poll every 5s. Publish short-form JSON to MQTT.
 * ==========================================================================*/

#include "energy_monitor.h"
#include "she_mqtt.h"
#include "esp_log.h"
#include "driver/uart.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include <string.h>

static const char *TAG = "she_energy";

#define PZEM_UART_NUM        1
#define PZEM_UART_BAUDRATE   9600
#define PZEM_UART_TX_PIN     17
#define PZEM_UART_RX_PIN     18
#define PZEM_UART_BUF_SIZE   256

#define PZEM_ADDR            0x01    /* Modbus slave address (default) */
#define PZEM_CMD_READ        0x04    /* Function code: read input registers */

/* PZEM-004T v3 register map (V3-ENERGY-MONITORING §3) */
#define PZEM_REG_VOLTAGE     0x0000  /* 1 register, 0.1V */
#define PZEM_REG_CURRENT     0x0001  /* 2 registers, 0.001A */
#define PZEM_REG_POWER       0x0003  /* 2 registers, 0.1W */
#define PZEM_REG_ENERGY      0x0005  /* 2 registers, 1Wh */
#define PZEM_REG_FREQUENCY   0x0007  /* 1 register, 0.1Hz */
#define PZEM_REG_PF          0x0008  /* 1 register, 0.01 */
#define PZEM_REG_ALARM       0x0009  /* 1 register */

/* ---- Build Modbus RTU request frame ---- */
static size_t build_modbus_request(uint8_t *buf, uint8_t addr, uint8_t func,
                                    uint16_t reg, uint16_t count) {
    buf[0] = addr;
    buf[1] = func;
    buf[2] = (reg >> 8) & 0xFF;
    buf[3] = reg & 0xFF;
    buf[4] = (count >> 8) & 0xFF;
    buf[5] = count & 0xFF;
    /* CRC16 (Modbus) */
    uint16_t crc = 0xFFFF;
    for (int i = 0; i < 6; i++) {
        crc ^= buf[i];
        for (int j = 0; j < 8; j++) {
            if (crc & 0x0001) crc = (crc >> 1) ^ 0xA001;
            else crc >>= 1;
        }
    }
    buf[6] = crc & 0xFF;
    buf[7] = (crc >> 8) & 0xFF;
    return 8;
}

/* ---- Compute CRC16 for response verification ---- */
static uint16_t modbus_crc16(const uint8_t *data, size_t len) {
    uint16_t crc = 0xFFFF;
    for (size_t i = 0; i < len; i++) {
        crc ^= data[i];
        for (int j = 0; j < 8; j++) {
            if (crc & 0x0001) crc = (crc >> 1) ^ 0xA001;
            else crc >>= 1;
        }
    }
    return crc;
}

esp_err_t energy_monitor_init(void) {
    uart_config_t uart_cfg = {
        .baud_rate = PZEM_UART_BAUDRATE,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_APB,
    };
    ESP_ERROR_CHECK(uart_param_config(PZEM_UART_NUM, &uart_cfg));
    ESP_ERROR_CHECK(uart_set_pin(PZEM_UART_NUM, PZEM_UART_TX_PIN, PZEM_UART_RX_PIN,
                                  UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE));
    ESP_ERROR_CHECK(uart_driver_install(PZEM_UART_NUM, PZEM_UART_BUF_SIZE * 2, 0, 0, NULL, 0));
    ESP_LOGI(TAG, "PZEM-004T v3 initialized on UART%d (TX=%d, RX=%d, 9600 8N1)",
             PZEM_UART_NUM, PZEM_UART_TX_PIN, PZEM_UART_RX_PIN);
    return ESP_OK;
}

esp_err_t energy_monitor_read(pzem_reading_t *reading) {
    uint8_t req[8];
    build_modbus_request(req, PZEM_ADDR, PZEM_CMD_READ, PZEM_REG_VOLTAGE, 10);

    /* Flush RX + send request */
    uart_flush_input(PZEM_UART_NUM);
    uart_write_bytes(PZEM_UART_NUM, req, sizeof(req));

    /* Wait for response (25 bytes: 1 addr + 1 func + 1 byte_count + 20 data + 2 CRC) */
    uint8_t resp[25] = {0};
    int len = uart_read_bytes(PZEM_UART_NUM, resp, sizeof(resp), pdMS_TO_TICKS(1000));
    if (len < 25) {
        ESP_LOGW(TAG, "PZEM response too short: %d bytes", len);
        return ESP_ERR_TIMEOUT;
    }

    /* Verify CRC */
    uint16_t crc_recv = (resp[24] << 8) | resp[23];
    uint16_t crc_calc = modbus_crc16(resp, 23);
    if (crc_recv != crc_calc) {
        ESP_LOGW(TAG, "PZEM CRC mismatch: recv=%04X calc=%04X", crc_recv, crc_calc);
        return ESP_ERR_INVALID_CRC;
    }

    /* Parse registers (big-endian) — PZEM-004T v3 sends MSB first */
    reading->voltage      = ((resp[3] << 8) | resp[4]) * 0.1;                            /* 0.1V → V */
    reading->current      = ((uint32_t)(resp[5] << 24) | (resp[6] << 16) | (resp[7] << 8) | resp[8]) * 0.001;  /* 0.001A → A */
    reading->power_w      = ((uint32_t)(resp[9] << 24) | (resp[10] << 16) | (resp[11] << 8) | resp[12]) * 0.1; /* 0.1W → W */
    reading->energy_wh    = ((uint32_t)(resp[13] << 24) | (resp[14] << 16) | (resp[15] << 8) | resp[16]) * 1.0; /* 1Wh → Wh */
    reading->frequency    = ((resp[17] << 8) | resp[18]) * 0.1;                           /* 0.1Hz → Hz */
    reading->power_factor = ((resp[19] << 8) | resp[20]) * 0.01;                          /* 0.01 → 0-1 */

    return ESP_OK;
}

/* ---- Energy monitor task (V3-FIRMWARE §3 — priority 2, 3072 stack, core 0) ---- */
static void energy_task(void *arg) {
    pzem_reading_t reading;
    while (true) {
        if (energy_monitor_read(&reading) == ESP_OK) {
            ESP_LOGD(TAG, "V=%.1f I=%.2f P=%.1f Wh=%.2f PF=%.2f F=%.1f",
                     reading.voltage, reading.current, reading.power_w,
                     reading.energy_wh, reading.power_factor, reading.frequency);

            /* Publish to MQTT energy topic (QoS 0, every 5s)
             * V3-MQTT-STANDARDS §3.7 — short-form keys (v, i, p, wh, pf, freq) */
            mqtt_publish_energy(reading.voltage, reading.current, reading.power_w,
                                reading.energy_wh, reading.power_factor, reading.frequency);
        } else {
            ESP_LOGW(TAG, "PZEM read failed — will retry in 5s");
        }
        vTaskDelay(pdMS_TO_TICKS(5000));   /* poll every 5s per V3-FIRMWARE §9 */
    }
}

esp_err_t energy_monitor_start(void) {
#ifndef CONFIG_SHE_HAS_PZEM
    ESP_LOGI(TAG, "PZEM not available on this SKU — energy monitor disabled");
    return ESP_OK;
#endif
    BaseType_t ret = xTaskCreatePinnedToCore(
        energy_task, "energy_task", 3072, NULL, 2, NULL, 0);
    if (ret != pdPASS) {
        ESP_LOGE(TAG, "Failed to create energy_task");
        return ESP_FAIL;
    }
    ESP_LOGI(TAG, "Energy monitor task started (priority 2, 3072 stack, core 0, 5s poll)");
    return ESP_OK;
}
