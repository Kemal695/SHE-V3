-- =============================================================================
-- SHE V3 — Flyway migration V42: widen the icon columns for uploaded icons
-- =============================================================================
-- V41 let a scene/group icon be an uploaded `/api/v3/media/<uuid>` path instead
-- of a short key like 'moon'. That path is exactly 50 characters, which is the
-- full width of `scenes.icon` (VARCHAR(50)) — it fits today but with zero
-- margin, and `node_groups.icon` was only 64. Widen both so a slightly longer
-- value (a different prefix, a proxy path) cannot silently truncate or 500.
-- =============================================================================

ALTER TABLE scenes ALTER COLUMN icon TYPE VARCHAR(300);

COMMENT ON COLUMN scenes.icon IS
    'Either a short key (sun, moon, ...) or an uploaded /api/v3/media/{id} path.';

ALTER TABLE node_groups ALTER COLUMN icon TYPE VARCHAR(300);

COMMENT ON COLUMN node_groups.icon IS
    'Either a short key (lights, sockets, ...) or an uploaded /api/v3/media/{id} path.';
