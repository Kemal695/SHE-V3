-- =============================================================================
-- SHE V3 — Flyway migration V34: Add nodes.is_quarantined column
-- =============================================================================
-- BUG FIX: AdminDeviceController.quarantine() references is_quarantined but the
-- column doesn't exist in V27__nodes_hierarchy.sql. V3-SECURITY-MODEL §4.2 says
-- the EMQX auth backend must check nodes.is_quarantined.
--
-- This migration adds the column + index. The entity + MqttAuthController
-- are updated to use it.
-- =============================================================================

ALTER TABLE nodes ADD COLUMN IF NOT EXISTS is_quarantined BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN nodes.is_quarantined IS 'When true, EMQX auth backend denies MQTT connections from this device. V3-SECURITY-MODEL §4.2.';

CREATE INDEX IF NOT EXISTS idx_nodes_quarantined
    ON nodes (is_quarantined)
    WHERE is_quarantined AND deleted_at IS NULL;
