// =============================================================================
// SHE V3 firmware — Device-local schedules (implementation)
// =============================================================================
// See schedule_store.h for the design notes on repeating + dedup.
// =============================================================================

#include "schedule_store.h"

#include <string.h>
#include <time.h>

#include "esp_log.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "nvs_keys.h"
#include "relay_driver.h"

static const char *TAG = "she_sched";

/* Matches system_service.c: time(NULL) is below this until SNTP has actually set
 * the clock. Ticking before then would compare against 1970 and never fire. */
#define SCHED_TIME_SET_FLOOR 1700000000L

static she_sched_t s_scheds[SHE_SCHED_MAX];
static bool s_loaded = false;

/* ---- Persistence ---------------------------------------------------------- */

esp_err_t schedule_store_init(void) {
    memset(s_scheds, 0, sizeof(s_scheds));

    nvs_handle_t h;
    esp_err_t err = nvs_open(SHE_NVS_NAMESPACE, NVS_READONLY, &h);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        /* No schedules stored yet — that is normal on first boot. */
        ESP_LOGI(TAG, "No stored schedules (first boot)");
        s_loaded = true;
        return ESP_OK;
    }
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "nvs_open failed: %s", esp_err_to_name(err));
        return err;
    }

    size_t len = sizeof(s_scheds);
    err = nvs_get_blob(h, SHE_NVS_KEY_SCHEDULES, s_scheds, &len);
    nvs_close(h);

    if (err == ESP_ERR_NVS_NOT_FOUND) {
        ESP_LOGI(TAG, "No stored schedules");
        err = ESP_OK;
    } else if (err != ESP_OK) {
        ESP_LOGW(TAG, "nvs_get_blob failed: %s", esp_err_to_name(err));
        memset(s_scheds, 0, sizeof(s_scheds));
    } else if (len != sizeof(s_scheds)) {
        /* Stored size differs (struct changed) — do not trust it. */
        ESP_LOGW(TAG, "Stored schedule size %u != %u, ignoring",
                 (unsigned)len, (unsigned)sizeof(s_scheds));
        memset(s_scheds, 0, sizeof(s_scheds));
    }

    s_loaded = true;
    return err;
}

esp_err_t schedule_store_save(void) {
    nvs_handle_t h;
    esp_err_t err = nvs_open(SHE_NVS_NAMESPACE, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "save: nvs_open failed: %s", esp_err_to_name(err));
        return err;
    }

    err = nvs_set_blob(h, SHE_NVS_KEY_SCHEDULES, s_scheds, sizeof(s_scheds));
    if (err == ESP_OK) {
        err = nvs_commit(h);
    } else {
        ESP_LOGW(TAG, "save: nvs_set_blob failed: %s", esp_err_to_name(err));
    }
    nvs_close(h);
    return err;
}

/* ---- List access ---------------------------------------------------------- */

const she_sched_t *schedule_list(size_t *out_count) {
    if (out_count) *out_count = SHE_SCHED_MAX;
    return s_scheds;
}

esp_err_t schedule_add(const she_sched_t *sched, int *out_index) {
    if (sched == NULL) return ESP_ERR_INVALID_ARG;
    if (!s_loaded) schedule_store_init();

    for (int i = 0; i < SHE_SCHED_MAX; i++) {
        if (!s_scheds[i].enabled) {
            s_scheds[i] = *sched;
            s_scheds[i].enabled = 1;
            s_scheds[i].reserved = 0;
            /* Seed with NOW, not 0. With catch-up in place, a zero would make a
             * schedule added for a time that has ALREADY passed today fire the
             * instant it is created — surprising, and not what "catch up" means.
             * Catch-up is for a minute missed while the device was down, not for a
             * past time someone deliberately typed. */
            s_scheds[i].last_fired_min = (uint32_t)(time(NULL) / 60);
            if (out_index) *out_index = i;
            return schedule_store_save();
        }
    }
    ESP_LOGW(TAG, "Schedule list full (%d max)", SHE_SCHED_MAX);
    return ESP_ERR_NO_MEM;
}

esp_err_t schedule_remove(int index) {
    if (index < 0 || index >= SHE_SCHED_MAX) return ESP_ERR_INVALID_ARG;
    memset(&s_scheds[index], 0, sizeof(s_scheds[index]));
    return schedule_store_save();
}

esp_err_t schedule_clear_all(void) {
    memset(s_scheds, 0, sizeof(s_scheds));
    return schedule_store_save();
}

/* ---- Ticking -------------------------------------------------------------- */

int schedule_tick(void) {
    if (!s_loaded) return 0;

    const time_t now = time(NULL);
    if (now < SCHED_TIME_SET_FLOOR) {
        /* Clock not set yet — scheduling against 1970 is meaningless. */
        return 0;
    }

    struct tm t;
    localtime_r(&now, &t);          /* local = EAT (TZ set by system_service) */

    const uint32_t min_key = (uint32_t)(now / 60);
    const uint8_t today_bit = SHE_SCHED_DAY_BIT(t.tm_wday);

    int fired = 0;
    bool dirty = false;

    /* Periodic heartbeat so the watcher is observable from the serial console:
     * proves the task is alive and shows the clock/timezone it is matching against. */
    static int s_tick_count = 0;
    const bool heartbeat = ((s_tick_count++ % 12) == 0);   /* every ~60 s */
    if (heartbeat) {
        unsigned en = 0;
        for (int i = 0; i < SHE_SCHED_MAX; i++) if (s_scheds[i].enabled) en++;
        ESP_LOGI(TAG, "tick %02d:%02d wday=%d bit=0x%02X enabled=%u min_key=%u",
                 t.tm_hour, t.tm_min, t.tm_wday, today_bit, en,
                 (unsigned)min_key);
    }

    for (int i = 0; i < SHE_SCHED_MAX; i++) {
        she_sched_t *s = &s_scheds[i];
        if (!s->enabled) continue;

        /* Walk back over the catch-up window looking for the MOST RECENT time this
         * schedule should have fired. off == 0 is "on time"; a larger off recovers a
         * minute that passed while the device was rebooting, asleep or unpowered.
         * This single loop handles both cases, so there is no separate boot path. */
        bool due = false;
        int late_by = 0;
        for (int off = 0; off <= SHE_SCHED_CATCHUP_MINUTES; off++) {
            const time_t cand = now - (time_t)off * 60;
            struct tm c;
            localtime_r(&cand, &c);

            if (c.tm_hour != s->hour || c.tm_min != s->minute) continue;

            /* Day gate, evaluated for the CANDIDATE's weekday (not today's), so a
             * catch-up just after midnight is judged against the right day. */
            const uint8_t cand_bit = SHE_SCHED_DAY_BIT(c.tm_wday);
            if (s->days_mask != SHE_SCHED_ONE_SHOT && (s->days_mask & cand_bit) == 0) {
                if (off == 0) {
                    ESP_LOGW(TAG, "  #%d DAY REJECT: mask=0x%02X & bit=0x%02X == 0 (wday=%d)",
                             i, (unsigned)s->days_mask, (unsigned)cand_bit, c.tm_wday);
                }
                break;
            }

            const uint32_t cand_key = (uint32_t)(cand / 60);
            /* Already handled this slot, or a later one — nothing to do. */
            if (s->last_fired_min >= cand_key) break;

            due = true;
            late_by = off;
            if (off > 0) {
                ESP_LOGI(TAG, "  #%d CATCH-UP: missed %02d:%02d, firing %d min late",
                         i, c.tm_hour, c.tm_min, off);
            }
            ESP_LOGI(TAG, "  #%d MATCH -> firing (mask=0x%02X last_fired=%u cand=%u now=%u)",
                     i, (unsigned)s->days_mask, (unsigned)s->last_fired_min,
                     (unsigned)cand_key, (unsigned)min_key);
            break;   /* fire only the most recent occurrence */
        }
        if (!due) continue;

        const bool on = (s->action == SHE_SCHED_ACTION_ON);
        if (relay_set(s->relay, on) != ESP_OK) {
            ESP_LOGW(TAG, "relay_set(%d,%d) failed", s->relay, on);
            continue;   /* leave last_fired_min alone so it retries next tick */
        }
        relay_save_state();          /* persist the new relay state, as params/remote does */

        s->last_fired_min = min_key;
        if (s->days_mask == SHE_SCHED_ONE_SHOT) {
            s->enabled = 0;          /* one-shot is consumed */
            ESP_LOGI(TAG, "One-shot #%d fired (relay %d -> %s); now disabled",
                     i, s->relay, on ? "ON" : "OFF");
        } else {
            ESP_LOGI(TAG, "Schedule #%d fired (relay %d -> %s), mask=0x%02X",
                     i, s->relay, on ? "ON" : "OFF", s->days_mask);
        }

        dirty = true;
        fired++;
    }

    if (dirty) schedule_store_save();
    return fired;
}

/* ---- Watcher task -------------------------------------------------------- */

/* 5 s is fine: schedules are minute-granular, and last_fired_min dedups anyway, so a
 * slightly late tick can never cause a double fire or a missed day. */
#define SCHED_TICK_MS 5000

static bool s_task_started = false;

static void schedule_task_fn(void *arg) {
    (void)arg;
    while (1) {
        schedule_tick();
        vTaskDelay(pdMS_TO_TICKS(SCHED_TICK_MS));
    }
}

esp_err_t schedule_task_start(void) {
    if (s_task_started) return ESP_OK;

    BaseType_t ok = xTaskCreate(schedule_task_fn, "she_sched",
                                3072, NULL, 5, NULL);
    if (ok != pdPASS) {
        ESP_LOGE(TAG, "Failed to create schedule task");
        return ESP_FAIL;
    }
    s_task_started = true;
    ESP_LOGI(TAG, "Schedule watcher started (tick every %d ms)", SCHED_TICK_MS);
    return ESP_OK;
}
