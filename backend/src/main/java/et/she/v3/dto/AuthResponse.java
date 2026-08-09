package et.she.v3.dto;

import java.util.Map;

/**
 * Successful auth response (login + refresh).
 * V3-API-SPECIFICATION §3 — fields use snake_case (matches the API contract).
 */
public record AuthResponse(
        String access_token,
        String refresh_token,
        long expires_in,            // seconds until access_token expiry
        String token_type,          // always "Bearer"
        Map<String, Object> tenant_branding
) {}
