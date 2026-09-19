// =============================================================================
// SHE V3 firmware — Device-local schedules (with repeating)
// =============================================================================
// Lets the ESP32 switch its own relays on a time basis WITHOUT the cloud: it syncs
// its clock over SNTP (system_service), stores schedules in NVS, and a low-priority
// task ticks and fires whatever is due. Survives power cuts and a missing server.
//
// REPEATING (recursive) SCHEDULING
// --------------------------------
// `days_mask` is the whole mechanism — one bit per weekday, bit0=Sunday:
//     0x7F (all 7 bits) = every day          <- the common "daily" case
//     0b0010101         = Mon / Wed / Fri
//     0b0110000         = Sat + Sun only
//     0                 = ONE-SHOT: fires once then self-disables
//
// DEDUP
// -----
// The tick may run every few seconds, so a "20:00" schedule would otherwise fire
// repeatedly for that whole minute. We store `last_fired_min = (uint32_t)(now/60)`
// and only fire when it differs from the current minute key. Because the key
// changes every minute — and every day — repeats across days work for free.
//
// TIME
// ----
// Matching uses localtime_r(), and system_service sets TZ=EAT-3 (Ethiopia, UTC+3),
// so "20:00" means 20:00 Ethiopian. Payload timestamps elsewhere still use gmtime()
// and are unaffected. Never call schedule_tick() before SNTP has set the clock —
// it checks a sane-time floor itself and does nothing until then.
// =============================================================================

#ifndef SHE_SCHEDULE_STORE_H
#define SHE_SCHEDULE_STORE_H

#include <stdint.h>
#include <stddef.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Max simultaneous schedules. 8 * 12 B = 96 B — trivial for NVS. */
#define SHE_SCHED_MAX           8

/* days_mask helpers */
#define SHE_SCHED_EVERY_DAY    0x7F
#define SHE_SCHED_ONE_SHOT     0x00
/* bit0 = Sunday … bit6 = Saturday */
#define SHE_SCHED_DAY_BIT(wday) (uint8_t)(1u << ((wday) & 0x7))

#define SHE_SCHED_ACTION_OFF   0
#define SHE_SCHED_ACTION_ON    1

/**
 * Catch-up window, in minutes.
 *
 * If a schedule's minute passed while the device was rebooting, asleep or briefly
 * without power, it still fires when the device comes back — but only if that
 * minute was within this many minutes ago.
 *
 * 10 is a deliberate choice, not a default: it comfortably covers an OTA reboot
 * (~7 min: download + health check) and a short power blip, while refusing to
 * replay a long outage. Firing "turn the geyser on at 06:00" at 06:07 is useful;
 * firing it at 09:00 is a hazard, and at that point doing nothing is safer.
 *
 * The cloud scheduler uses a 24 h window (V35) because a server that was merely
 * asleep should still act on the day's schedule. A device that was physically off
 * is a different situation.
 */
#define SHE_SCHED_CATCHUP_MINUTES  10

typedef struct {
    uint8_t  enabled;
    uint8_t  hour;            /* 0-23, local (EAT) */
    uint8_t  minute;          /* 0-59 */
    uint8_t  days_mask;       /* bit0=Sun..bit6=Sat; 0x7F=daily; 0=one-shot */
    uint8_t  relay;           /* relay channel index */
    uint8_t  action;          /* SHE_SCHED_ACTION_OFF / _ON */
    uint16_t reserved;        /* keeps the struct 4-byte aligned for NVS blob */
    uint32_t last_fired_min;  /* now/60 at last fire — dedup, see header notes */
} she_sched_t;

/* ---- Lifecycle ------------------------------------------------------------ */

/* Loads schedules from NVS. Safe to call before Wi-Fi/SNTP. */
esp_err_t schedule_store_init(void);

/* Persists the current in-memory list to NVS. */
esp_err_t schedule_store_save(void);

/* ---- List access ---------------------------------------------------------- */

/* Returns the internal array and its length. Do not free. */
const she_sched_t *schedule_list(size_t *out_count);

/* Adds a schedule into the first free slot. `out_index` may be NULL. */
esp_err_t schedule_add(const she_sched_t *sched, int *out_index);

/* Clears the slot at `index`. */
esp_err_t schedule_remove(int index);

/* Removes every schedule (used by factory reset). */
esp_err_t schedule_clear_all(void);

/* ---- Ticking -------------------------------------------------------------- */

/* Evaluates all schedules and fires any that are due. Call ~every few seconds.
 * Returns the number fired (0 almost always). */
int schedule_tick(void);

/* Starts the background "watcher" task that calls schedule_tick() every 5 s.
 * Idempotent — safe to call once at startup. */
esp_err_t schedule_task_start(void);

#ifdef __cplusplus
}
#endif

#endif /* SHE_SCHEDULE_STORE_H */
