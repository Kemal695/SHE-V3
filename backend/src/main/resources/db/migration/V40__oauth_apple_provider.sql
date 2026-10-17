-- =============================================================================
-- SHE V3 — Flyway migration V40: allow Apple as an OAuth provider
-- =============================================================================
-- V2/V16 restricted oauth_provider to ('GITHUB','GOOGLE'). The mobile app now
-- offers "Sign in with Apple", so APPLE must be an allowed provider value on
-- both the users table and the oauth_identities linkage table.
-- =============================================================================

ALTER TABLE users DROP CONSTRAINT IF EXISTS users_oauth_provider_check;
ALTER TABLE users ADD CONSTRAINT users_oauth_provider_check
    CHECK (oauth_provider IN ('GITHUB', 'GOOGLE', 'APPLE') OR oauth_provider IS NULL);

ALTER TABLE oauth_identities DROP CONSTRAINT IF EXISTS oauth_identities_provider_check;
ALTER TABLE oauth_identities ADD CONSTRAINT oauth_identities_provider_check
    CHECK (provider IN ('GITHUB', 'GOOGLE', 'APPLE'));
