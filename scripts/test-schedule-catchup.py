#!/usr/bin/env python3
"""
Logic test for the device-local schedule catch-up algorithm.

WHY THIS EXISTS
---------------
The `off > 0` branch in `schedule_store.c` could not be exercised on real
hardware: the ESP32's RTC survives a software reset, so a reboot never blinds the
scheduler, and only a physical power cut can create a missed window. That leaves
the late-fire path unproven.

This ports the exact matching loop from `schedule_tick()` and tests it against the
scenarios a power cut would produce. It verifies the ALGORITHM (bounds, the
`>=` dedup guard, the candidate-day gate) — it is NOT a substitute for the
hardware test, but it does rule out off-by-one and comparison mistakes.

Mirrors schedule_store.c:
    for (off = 0; off <= SHE_SCHED_CATCHUP_MINUTES; off++) {
        cand = now - off*60
        if (cand.hour != s.hour || cand.min != s.minute) continue
        if (s.days_mask != ONE_SHOT && (s.days_mask & bit(cand.wday)) == 0) break
        if (s.last_fired_min >= cand/60) break
        -> FIRE with late_by = off
    }
"""

CATCHUP_MINUTES = 10
EVERY_DAY = 0x7F
ONE_SHOT = 0x00
DAY_BIT = lambda wday: 1 << (wday & 0x7)


def tick(schedules, now_minute, wday_of):
    """Returns list of (index, late_by) that would fire.

    now_minute : integer minute-of-epoch (mirrors time(NULL)/60)
    wday_of    : callable(minute) -> weekday 0..6 (Sunday=0), standing in for
                 localtime_r() on the candidate instant
    """
    fired = []
    for i, s in enumerate(schedules):
        if not s["enabled"]:
            continue
        due = False
        late_by = 0
        for off in range(0, CATCHUP_MINUTES + 1):
            cand = now_minute - off
            c_hour, c_min = (cand // 60) % 24, cand % 60
            if c_hour != s["hour"] or c_min != s["minute"]:
                continue
            if s["days_mask"] != ONE_SHOT:
                if (s["days_mask"] & DAY_BIT(wday_of(cand))) == 0:
                    break
            if s["last_fired_min"] >= cand:
                break
            due = True
            late_by = off
            break
        if due:
            fired.append((i, late_by))
    return fired


def sched(hour, minute, mask=EVERY_DAY, last_fired=0, enabled=True):
    return {"hour": hour, "minute": minute, "days_mask": mask,
            "last_fired_min": last_fired, "enabled": enabled}


# Reference point: a fixed "now" at 18:15 local (minute-of-day 1095 = 18*60+15),
# so sched(18, 15) matches BASE exactly. Weekday is supplied by wday_of().
BASE = 1440 * 20715 + 1095
MON = 1                      # kept for readability; weekday is controlled per-test


def wday_all(_):
    return 6                 # Saturday, as during the real hardware tests


results = []


def check(name, got, want):
    ok = got == want
    results.append(ok)
    print(f"  {'PASS' if ok else 'FAIL'}  {name}")
    if not ok:
        print(f"        got={got}  want={want}")


print("Catch-up logic tests")
print("=" * 58)

# 1. On time (off = 0). BASE itself IS the 18:15 minute.
s = [sched(18, 15)]
check("on time fires with late_by=0",
      tick(s, BASE, wday_all), [(0, 0)])

# 2. Missed by 1 minute -> catch-up
s = [sched(18, 15)]
check("missed by 1 min fires late_by=1",
      tick(s, BASE + 1, wday_all), [(0, 1)])

# 3. Missed by exactly the window edge (10 min)
s = [sched(18, 15)]
check("missed by 10 min (window edge) fires",
      tick(s, BASE + 10, wday_all), [(0, 10)])

# 4. Missed by 11 min -> OUTSIDE window, must NOT fire
s = [sched(18, 15)]
check("missed by 11 min does NOT fire",
      tick(s, BASE + 11, wday_all), [])

# 5. Already fired for that slot -> no double fire
s = [sched(18, 15, last_fired=BASE)]
check("already fired -> no re-fire",
      tick(s, BASE + 1, wday_all), [])

# 6. Weekday mask rejects the wrong day
s = [sched(18, 15, mask=DAY_BIT(1))]      # Mondays only
check("weekday mask rejects wrong day",
      tick(s, BASE, lambda _: 6), [])       # now is Saturday

# 7. Weekday mask accepts the right day
s = [sched(18, 15, mask=DAY_BIT(6))]      # Saturdays only
check("weekday mask accepts right day",
      tick(s, BASE, lambda _: 6), [(0, 0)])

# 8. One-shot ignores the day mask entirely
s = [sched(18, 15, mask=ONE_SHOT)]
check("one-shot ignores day mask",
      tick(s, BASE, lambda _: 3), [(0, 0)])

# 9. Catch-up across midnight: candidate is yesterday, different weekday.
#    BASE2 is the 23:59 minute; one minute later it is 00:00 the next day, so the
#    candidate's weekday (Friday) must be used, not "today's" (Saturday).
s = [sched(23, 59, mask=DAY_BIT(5))]      # Fridays
BASE2 = BASE - (BASE % 1440) + 1439       # 23:59
check("catch-up across midnight uses candidate weekday",
      tick(s, BASE2 + 1, lambda m: 5 if (m % 1440) == 1439 else 6),
      [(0, 1)])

# 10. Disabled schedule never fires
s = [sched(18, 15, enabled=False)]
check("disabled schedule never fires",
      tick(s, BASE, wday_all), [])

# 11. Two schedules, one due one not (18:30 is not due at 18:16)
s = [sched(18, 15), sched(18, 30)]
check("only the due schedule fires",
      tick(s, BASE + 1, wday_all), [(0, 1)])

print("=" * 58)
print(f"  {sum(results)}/{len(results)} passed")
raise SystemExit(0 if all(results) else 1)
