package et.she.v3.service;

import et.she.v3.dto.PagedResponse;
import et.she.v3.dto.UserDtos;
import et.she.v3.entity.User;

import java.util.UUID;

/**
 * User CRUD service — Phase 0's required CRUD endpoint.
 *
 * All methods are RLS-enforced via the TenantContextInterceptor setting
 * `app.tenant_id` GUC per request (P0-5).
 */
public interface UserService {

    UserDtos.UserResponse create(UserDtos.CreateUserRequest req);

    UserDtos.UserResponse getById(UUID id);

    PagedResponse<UserDtos.UserResponse> list(int page, int size);

    UserDtos.UserResponse update(UUID id, UserDtos.UpdateUserRequest req);

    void softDelete(UUID id);

    /**
     * Internal helper — returns the entity (not DTO) for use by AuthService.
     */
    User findEntityForAuth(UUID tenantId, String email);
}
