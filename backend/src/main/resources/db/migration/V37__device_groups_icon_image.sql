-- =============================================================================
-- SHE V3 — Flyway migration V37: per-group icon + hero image (picker-based)
-- =============================================================================
-- The Scenes table has an icon column and the scene detail hero picks a bundled
-- image. Custom device groups (node_groups, V11) did not — the card had to
-- infer an icon from its members' role names and the detail page had no hero.
--
-- Both fields are SHORT string keys the app resolves to bundled assets, so the
-- contract is the same as scenes: the database stores "home-dusk" / "lights",
-- the client maps that to `assets/img/home-dusk.png` or `Icons.lightbulb_outline`.
--
-- This is the "pick from bundled" half. Real photo upload (camera / gallery →
-- MinIO) is a later migration; until then the API only round-trips these keys.
-- =============================================================================

ALTER TABLE node_groups
    ADD COLUMN IF NOT EXISTS icon  VARCHAR(64) NULL,
    ADD COLUMN IF NOT EXISTS image VARCHAR(64) NULL;

COMMENT ON COLUMN node_groups.icon IS
    'Icon key for the card (e.g. "lights", "folder"). NULL → derive from members.';
COMMENT ON COLUMN node_groups.image IS
    'Hero image key for the detail page (e.g. "home-dusk"). NULL → no hero image.';