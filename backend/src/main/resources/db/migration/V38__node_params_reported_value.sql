-- =============================================================================
-- V38 — node_params.reported_value
-- =============================================================================
-- node_params.last_value is CONFLATED: writeParams() and the group-set path
-- write the app's DESIRED value into it immediately, and the device's
-- params/local report also writes it. So the mobile could show a relay "on"
-- purely from the user's own command, with no feedback from the board.
--
-- reported_value holds ONLY what the DEVICE last reported (params/local). The
-- app's power switch reads it as the source of truth: ON only when the board
-- says so, otherwise OFF.
-- =============================================================================

ALTER TABLE node_params
    ADD COLUMN IF NOT EXISTS reported_value jsonb NULL;

COMMENT ON COLUMN node_params.reported_value IS
    'Value last REPORTED BY THE DEVICE (params/local). Distinct from last_value, which app commands also write.';

-- Best-effort backfill so existing rows have a starting reported value.
UPDATE node_params
   SET reported_value = last_value
 WHERE reported_value IS NULL
   AND last_value IS NOT NULL;
