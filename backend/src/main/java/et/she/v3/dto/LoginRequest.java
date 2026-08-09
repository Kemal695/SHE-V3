package et.she.v3.dto;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;

/**
 * POST /api/v3/auth/login request body (V3-API-SPECIFICATION §3).
 *
 * Response (200):
 * <pre>
 * {
 *   "access_token": "eyJ...",
 *   "refresh_token": "eyJ...",
 *   "expires_in": 900,
 *   "token_type": "Bearer",
 *   "tenant_branding": { "primary_color": "#0B1D37", ... }
 * }
 * </pre>
 *
 * If MFA is enabled and mfa_code is missing → 401 AUTH_MFA_REQUIRED.
 */
public record LoginRequest(
        @NotBlank @Email
        String email,

        @NotBlank
        String password,

        String mfa_code
) {}
