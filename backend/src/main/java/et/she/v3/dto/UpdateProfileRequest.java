package et.she.v3.dto;

/**
 * PATCH /api/v3/auth/me — the signed-in user editing their own profile.
 *
 * Every field is optional: only the ones present are written, so a client can
 * change the name without touching the phone number. Field names are snake_case
 * to match {@link MeResponse.UserView} (the project's wire format for this API).
 */
public record UpdateProfileRequest(
        String full_name,
        String phone_number,
        String preferred_language
) {}
