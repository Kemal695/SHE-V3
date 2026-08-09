package et.she.v3.dto;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

import java.util.UUID;

/**
 * User CRUD DTOs — Phase 0's required CRUD endpoint.
 *
 * Phase 0 implements admin-scoped user CRUD (TENANT_ADMIN + PLATFORM_ADMIN + SUPER_ADMIN).
 * Endpoints (V3-API-SPECIFICATION §4 — admin endpoints):
 *   GET    /api/v3/users                 — list (paginated, RLS-enforced)
 *   GET    /api/v3/users/{id}            — get one
 *   POST   /api/v3/users                 — create (TENANT_ADMIN+)
 *   PUT    /api/v3/users/{id}            — update
 *   DELETE /api/v3/users/{id}            — soft delete (sets deleted_at)
 */
public class UserDtos {

    public record CreateUserRequest(
            @NotBlank @Email
            String email,

            @NotBlank @Size(min = 12, max = 128)
            @Pattern(regexp = "^(?=.*[a-z])(?=.*[A-Z])(?=.*\\d)(?=.*[^A-Za-z0-9]).+$",
                     message = "Password must contain at least 1 uppercase, 1 lowercase, 1 digit, 1 special char")
            String password,

            @Pattern(regexp = "^(USER|PLATFORM_ADMIN|SUPER_ADMIN)$",
                     message = "platform_role must be USER | PLATFORM_ADMIN | SUPER_ADMIN")
            String platform_role,

            @Pattern(regexp = "^(TENANT_ADMIN|TENANT_INSTALLER|TENANT_VIEWER|)$")
            String tenant_role,

            @Pattern(regexp = "^(\\+251|0)?9\\d{8}$", message = "Phone must be Ethiopian")
            String phone_number,

            @Size(max = 200) String full_name,

            @Pattern(regexp = "^(am|en)$") String language
    ) {}

    public record UpdateUserRequest(
            @Email String email,
            @Pattern(regexp = "^(\\+251|0)?9\\d{8}$") String phone_number,
            @Size(max = 200) String full_name,
            @Pattern(regexp = "^(am|en)$") String language,
            @Pattern(regexp = "^(USER|PLATFORM_ADMIN|SUPER_ADMIN|)$") String platform_role,
            @Pattern(regexp = "^(TENANT_ADMIN|TENANT_INSTALLER|TENANT_VIEWER|)$") String tenant_role,
            Boolean mfa_enabled
    ) {}

    public record UserResponse(
            UUID id,
            UUID tenant_id,
            String email,
            String platform_role,
            String tenant_role,
            String phone_number,
            String preferred_language,
            String full_name,
            boolean mfa_enabled,
            String created_at,
            String updated_at,
            String last_login_at
    ) {}
}
