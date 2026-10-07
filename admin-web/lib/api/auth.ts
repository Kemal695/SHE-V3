// =============================================================================
// SHE V3 Admin — Auth API (Bearer JWT)
// =============================================================================
// Backend contract (AuthController):
//   POST /api/v3/auth/login   -> {"data": {access_token, refresh_token, ...}}
//   POST /api/v3/auth/refresh -> {"data": {access_token, refresh_token, ...}}
//   POST /api/v3/auth/logout  -> 204, body {"refresh_token": "..."} (blacklists jti)
//   GET  /api/v3/auth/me      -> {"data": {user, tenant, branding}}
//
// Tokens are persisted by the token store (access in memory, refresh in a
// SameSite=Lax cookie) — the backend sets no cookies of its own.
// =============================================================================
import { api } from './client';
import { clearTokens, getRefreshToken, storeTokens } from './token-store';
import type { ApiSuccess, AuthResponse, MeResponse } from '@/lib/types';

export const authApi = {
  async login(
    email: string,
    password: string,
    mfaCode?: string
  ): Promise<ApiSuccess<AuthResponse>> {
    const res = await api.post<ApiSuccess<AuthResponse>>('/api/v3/auth/login', {
      email,
      password,
      mfa_code: mfaCode,
    });
    // Persist the pair before returning so the very next request is authorised.
    storeTokens(res.data.access_token, res.data.refresh_token);
    return res;
  },

  async logout(): Promise<void> {
    const refreshToken = getRefreshToken();
    try {
      // Best-effort: blacklist the refresh-token jti server-side.
      if (refreshToken) {
        await api.post<void>('/api/v3/auth/logout', { refresh_token: refreshToken });
      }
    } catch {
      // Network/expiry failures must not block a local sign-out.
    } finally {
      clearTokens();
    }
  },

  me: () => api.get<ApiSuccess<MeResponse>>('/api/v3/auth/me'),

  async refresh(refreshToken: string): Promise<ApiSuccess<AuthResponse>> {
    const res = await api.post<ApiSuccess<AuthResponse>>('/api/v3/auth/refresh', {
      refresh_token: refreshToken,
    });
    storeTokens(res.data.access_token, res.data.refresh_token);
    return res;
  },
};
