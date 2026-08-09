package et.she.v3.dto;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

/**
 * POST /api/v3/auth/register request body (V3-API-SPECIFICATION §3).
 *
 * Validation rules per V3-ERROR-CODES §3:
 *   - email: valid format (VALIDATION_EMAIL_INVALID)
 *   - password: min 12 chars, 1 upper, 1 lower, 1 digit, 1 special (VALIDATION_PASSWORD_WEAK)
 *   - phone_number: Ethiopian format ^(\+251|0)?9\d{8}$ (VALIDATION_PHONE_INVALID)
 */
public record RegisterRequest(
        @NotBlank @Email
        String email,

        @NotBlank @Size(min = 12, max = 128)
        @Pattern(regexp = "^(?=.*[a-z])(?=.*[A-Z])(?=.*\\d)(?=.*[^A-Za-z0-9]).+$",
                 message = "Password must contain at least 1 uppercase, 1 lowercase, 1 digit, 1 special char")
        String password,

        @Pattern(regexp = "^(\\+251|0)?9\\d{8}$", message = "Phone must be Ethiopian: (+251|0)?9XXXXXXXX")
        String phone_number,

        @Size(max = 200)
        String full_name,

        @Pattern(regexp = "^(am|en)$", message = "language must be 'am' or 'en'")
        String language
) {}
