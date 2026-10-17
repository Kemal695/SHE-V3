-- =============================================================================
-- SHE V3 — Flyway migration V41: uploaded media + per-scene cover image
-- =============================================================================
-- Until now both "images" in the product were BUNDLED ASSETS referenced by key
-- (`node_groups.image` = 'home-dusk', scenes had none at all), so a user could
-- only pick from what shipped in the APK. This adds real uploads:
--
--   media        one row per uploaded file; bytes live on disk under
--                `she.media.dir` (default ./data/media), named by the row id.
--   scenes.image new column — an uploaded /api/v3/media/{id} URL, or (legacy)
--                a bundled asset key.
--   node_groups.image widened from 64 to 300 so it can hold a URL as well as a
--                bundled key. Widening only — existing values stay valid.
--
-- NOTE ON RLS: unlike the rest of the schema, `media` deliberately does NOT
-- enable row-level security. The bytes are fetched by `GET /api/v3/media/{id}`
-- with an unguessable UUID and no JWT (a plain `Image.network` cannot reliably
-- carry one), so a tenant policy would only ever deny those reads. Writes are
-- still authenticated and the owning tenant is recorded for cleanup/audit.
-- =============================================================================

CREATE TABLE IF NOT EXISTS media (
    id            UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id     UUID          NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    owner_id      UUID          NULL,
    content_type  VARCHAR(100)  NOT NULL,
    byte_size     INTEGER       NOT NULL,
    storage_path  VARCHAR(300)  NOT NULL,
    created_at    TIMESTAMPTZ   NOT NULL DEFAULT now()
);

COMMENT ON TABLE media IS 'Uploaded images (scene/group covers, custom icons). Bytes on disk, keyed by id.';

CREATE INDEX IF NOT EXISTS idx_media_tenant ON media (tenant_id);

GRANT SELECT, INSERT, DELETE ON media TO she_app;

-- ---- scenes: cover image -----------------------------------------------------
ALTER TABLE scenes ADD COLUMN IF NOT EXISTS image VARCHAR(300) NULL;

COMMENT ON COLUMN scenes.image IS
    'Cover image: an uploaded /api/v3/media/{id} URL, or a bundled asset key. NULL -> icon only.';

-- ---- node_groups: allow a URL, not just a bundled key ------------------------
ALTER TABLE node_groups ALTER COLUMN image TYPE VARCHAR(300);

COMMENT ON COLUMN node_groups.image IS
    'Hero image: an uploaded /api/v3/media/{id} URL, or a bundled asset key. NULL -> icon only.';
