package et.she.v3.dto;

import jakarta.validation.constraints.NotBlank;

/**
 * Request body for POST /api/v3/auth/oauth/{google|apple}.
 *
 * The mobile SDK (google_sign_in / sign_in_with_apple) hands us a signed ID
 * token; the backend verifies it against the provider's public JWKS — it never
 * trusts the client.
 */
public record OAuthRequest(@NotBlank String id_token) {}
