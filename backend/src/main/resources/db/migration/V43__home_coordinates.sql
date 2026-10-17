-- =============================================================================
-- SHE V3 — Flyway migration V43: home coordinates (location automations)
-- =============================================================================
-- A LOCATION automation ("when I arrive / leave home") needs something to
-- measure distance against. `homes` only had a free-text address, so there was
-- nothing to geofence. These two nullable columns hold the home's point; NULL
-- simply means "not set yet" and the app asks the user to capture it.
--
-- The geofence itself is evaluated on the PHONE (foreground only) — the server
-- never sees the device's position, so nothing about the user's location is
-- stored beyond their own home.
-- =============================================================================

ALTER TABLE homes ADD COLUMN IF NOT EXISTS latitude  DOUBLE PRECISION NULL;
ALTER TABLE homes ADD COLUMN IF NOT EXISTS longitude DOUBLE PRECISION NULL;

COMMENT ON COLUMN homes.latitude IS
    'Home latitude for LOCATION automations. NULL -> not captured yet.';
COMMENT ON COLUMN homes.longitude IS
    'Home longitude for LOCATION automations. NULL -> not captured yet.';
