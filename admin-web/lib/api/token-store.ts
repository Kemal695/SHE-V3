// =============================================================================
// SHE V3 Admin — Token store (Bearer JWT)
// =============================================================================
// The backend is STATELESS JWT (SecurityConfig: csrf disabled,
// SessionCreationPolicy.STATELESS) and authenticates ONLY via
// `Authorization: Bearer <jwt>` (JwtAuthenticationFilter). It sets NO cookies,
// so the original design — "HTTP-only cookies set by backend on login" plus a
// CSRF token — can never work against it. This module replaces that model.
//
// Access token : IN MEMORY ONLY, never persisted (V3-SECURITY-MODEL §1.1 — the
//                same rule the mobile app follows via its in-memory provider).
// Refresh token: a JS-set, SameSite=Lax cookie. It is deliberately NOT HttpOnly
//                because the backend will not set it for us, and the middleware
//                (which runs on the edge, before any JS) needs to be able to
//                tell whether a session exists in order to gate routes.
//
// Security note: a JS-readable cookie is exposed to XSS, which is why the
// *access* token is kept out of it — only the refresh token lives there, and the
// refresh token is single-use and rotated on every use (verified: reusing a spent
// refresh token returns 401 AUTH_TOKEN_REVOKED).
// =============================================================================

export const REFRESH_COOKIE = 'she_admin_refresh';

const REFRESH_MAX_AGE_SECONDS = 60 * 60 * 24 * 30; // 30 days

let accessToken: string | null = null;

export function getAccessToken(): string | null {
  return accessToken;
}

export function setAccessToken(token: string | null): void {
  accessToken = token;
}

export function setRefreshToken(token: string): void {
  if (typeof document === 'undefined') return;
  document.cookie =
    `${REFRESH_COOKIE}=${encodeURIComponent(token)}; path=/; ` +
    `max-age=${REFRESH_MAX_AGE_SECONDS}; SameSite=Lax`;
}

export function getRefreshToken(): string | null {
  if (typeof document === 'undefined') return null;
  const match = document.cookie.match(
    new RegExp(`(?:^|; )${REFRESH_COOKIE}=([^;]*)`)
  );
  return match ? decodeURIComponent(match[1]) : null;
}

export function clearTokens(): void {
  accessToken = null;
  if (typeof document === 'undefined') return;
  document.cookie = `${REFRESH_COOKIE}=; path=/; max-age=0; SameSite=Lax`;
}

/** Store a freshly-issued token pair. */
export function storeTokens(access: string, refresh: string): void {
  setAccessToken(access);
  setRefreshToken(refresh);
}
