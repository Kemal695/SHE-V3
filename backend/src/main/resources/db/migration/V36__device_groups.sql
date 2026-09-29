-- =============================================================================
-- SHE V3 — Flyway migration V36: device-level custom groups
-- =============================================================================
-- V11 created node_groups + node_group_members for NODE-level groups.
-- Custom DEVICE groups (e.g. "Bedroom" spanning several relays on one board)
-- need membership at the node_devices level, so add device_id plus a matching
-- unique index. Existing node-level rows keep device_id = NULL.
-- =============================================================================

ALTER TABLE node_group_members
    ADD COLUMN IF NOT EXISTS device_id UUID REFERENCES node_devices(id) ON DELETE CASCADE;

COMMENT ON COLUMN node_group_members.device_id IS
    'Device-level membership for custom device groups. NULL = node-level membership.';

-- V11 declared UNIQUE (group_id, node_id), which would block two devices of the
-- same node from belonging to one group. Replace it with a device-scoped unique.
ALTER TABLE node_group_members
    DROP CONSTRAINT IF EXISTS node_group_members_group_id_node_id_key;

CREATE UNIQUE INDEX IF NOT EXISTS uq_ngm_group_device
    ON node_group_members (group_id, device_id)
    WHERE device_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_ngm_device ON node_group_members (device_id);

-- node_group_members carries tenant_id; RLS policies for it come from V31 when
-- present. node_groups already has FORCE RLS (V11), so reads/writes must run
-- inside a transaction with app.tenant_id set (TenantContextAspect).
