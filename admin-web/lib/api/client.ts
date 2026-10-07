// =============================================================================
// SHE V3 Admin — API Client (Bearer JWT)
// =============================================================================
// The backend authenticates via `Authorization: Bearer <jwt>` and is stateless
// (no cookies, no CSRF). See token-store.ts for why this differs from the
// original cookie/CSRF design.
// =============================================================================

import type { ApiError as ApiErrorType, ApiSuccess } from '@/lib/types';
import {
  clearTokens,
  getAccessToken,
  getRefreshToken,
  storeTokens,
} from './token-store';

const API_BASE = process.env.NEXT_PUBLIC_API_BASE_URL || 'http://localhost:8080';

export class ApiError extends Error {
  code: string;
  statusCode: number;
  requestId?: string;

  constructor(code: string, message: string, statusCode: number, requestId?: string) {
    super(message);
    this.name = 'ApiError';
    this.code = code;
    this.statusCode = statusCode;
    this.requestId = requestId;
  }
}

// ---- Refresh mutex -----------------------------------------------------------
// The refresh token is SINGLE-USE and rotates on every call. If two requests
// 401 at the same time and both refresh, the loser presents an already-spent
// token and the backend replies 401 AUTH_TOKEN_REVOKED — logging the user out.
// So all refreshes funnel through one shared in-flight promise.
let refreshInFlight: Promise<boolean> | null = null;

async function refreshAccessToken(): Promise<boolean> {
  if (refreshInFlight) return refreshInFlight;

  refreshInFlight = (async () => {
    try {
      const refreshToken = getRefreshToken();
      if (!refreshToken) return false;

      // Bare fetch, NOT this client — going through request() would recurse on
      // a 401 from the refresh call itself.
      const res = await fetch(`${API_BASE}/api/v3/auth/refresh`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ refresh_token: refreshToken }),
        cache: 'no-store',
      });
      if (!res.ok) return false;

      const body = (await res.json().catch(() => null)) as
        | ApiSuccess<{ access_token: string; refresh_token: string }>
        | null;
      const data = body?.data;
      if (!data?.access_token || !data?.refresh_token) return false;

      storeTokens(data.access_token, data.refresh_token);
      return true;
    } catch {
      return false;
    } finally {
      refreshInFlight = null;
    }
  })();

  return refreshInFlight;
}

function redirectToLogin(): void {
  if (typeof window !== 'undefined' && window.location.pathname !== '/login') {
    window.location.href = '/login';
  }
}

class ApiClient {
  private baseUrl: string;

  constructor(baseUrl: string = API_BASE) {
    this.baseUrl = baseUrl;
  }

  private async request<T>(
    path: string,
    options: RequestInit = {},
    isRetry = false
  ): Promise<T> {
    const url = `${this.baseUrl}${path}`;
    const token = getAccessToken();
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      ...(options.headers as Record<string, string>),
    };
    if (token) headers['Authorization'] = `Bearer ${token}`;

    const response = await fetch(url, {
      ...options,
      headers,
      // The backend sets no cookies and needs none — do not send any.
      credentials: 'omit',
      cache: 'no-store',
    });

    // 401 — try a single refresh, then retry the original request once.
    if (response.status === 401) {
      if (!isRetry && (await refreshAccessToken())) {
        return this.request<T>(path, options, true);
      }
      clearTokens();
      redirectToLogin();
      throw new ApiError('AUTH_TOKEN_INVALID', 'Session expired', 401);
    }

    // Parse response
    const data = await response.json().catch(() => null);

    if (!response.ok) {
      const err = data as ApiErrorType | null;
      throw new ApiError(
        err?.error?.code || 'HTTP_ERROR',
        err?.error?.message || `HTTP ${response.status}`,
        response.status,
        err?.error?.request_id
      );
    }

    // 204 No Content
    if (response.status === 204) return undefined as T;

    return data as T;
  }

  async get<T>(path: string): Promise<T> {
    return this.request<T>(path, { method: 'GET' });
  }

  async post<T>(path: string, body?: unknown): Promise<T> {
    return this.request<T>(path, {
      method: 'POST',
      body: body ? JSON.stringify(body) : undefined,
    });
  }

  async put<T>(path: string, body: unknown): Promise<T> {
    return this.request<T>(path, {
      method: 'PUT',
      body: JSON.stringify(body),
    });
  }

  async patch<T>(path: string, body: unknown): Promise<T> {
    return this.request<T>(path, {
      method: 'PATCH',
      body: JSON.stringify(body),
    });
  }

  async delete<T>(path: string): Promise<T> {
    return this.request<T>(path, { method: 'DELETE' });
  }
}

export const api = new ApiClient();
export { refreshAccessToken };
