-- =============================================================================
-- SHE V3 — Flyway migration V35: Add automations.last_fired_at
-- =============================================================================
-- Enables SCHEDULE catch-up (V3-API-SPECIFICATION §7.1).
--
-- PROBLEM: runScheduled() only fires when the cron matches the CURRENT minute.
-- If the backend is down, restarting, or the host is asleep at the scheduled
-- time, the run is silently lost forever — a "turn off the geyser at 06:00"
-- automation simply doesn't happen.
--
-- FIX: record when each automation last fired. The sweep can then look back
-- over the missed window and fire once if the cron matched at any minute since.
--
-- Nullable on purpose: an automation that has never fired has no value, and
-- the catch-up window is bounded in code (see AutomationService.CATCHUP_WINDOW)
-- so a long outage cannot replay a week of missed runs.
-- =============================================================================

ALTER TABLE automations ADD COLUMN IF NOT EXISTS last_fired_at TIMESTAMPTZ;

COMMENT ON COLUMN automations.last_fired_at IS
    'When this SCHEDULE automation last fired. Used for bounded catch-up after backend downtime. V3-API-SPECIFICATION §7.1.';

-- Supports the catch-up sweep, which scans enabled SCHEDULE automations and
-- compares last_fired_at against now.
CREATE INDEX IF NOT EXISTS idx_automations_schedule_catchup
    ON automations (last_fired_at)
    WHERE deleted_at IS NULL;
