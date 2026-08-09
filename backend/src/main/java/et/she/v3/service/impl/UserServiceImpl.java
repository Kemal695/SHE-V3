package et.she.v3.service.impl;

import et.she.v3.dto.PagedResponse;
import et.she.v3.dto.UserDtos;
import et.she.v3.entity.User;
import et.she.v3.errors.SheException;
import et.she.v3.repository.UserRepository;
import et.she.v3.security.AuthenticatedUser;
import et.she.v3.security.TenantContextInterceptor;
import et.she.v3.service.UserService;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Sort;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.Base64;
import java.util.List;
import java.util.UUID;

@Service
@Transactional
public class UserServiceImpl implements UserService {

    private final UserRepository userRepository;
    private final PasswordEncoder passwordEncoder;
    private final TenantContextInterceptor tenantContextInterceptor;

    public UserServiceImpl(UserRepository userRepository,
                           PasswordEncoder passwordEncoder,
                           TenantContextInterceptor tenantContextInterceptor) {
        this.userRepository = userRepository;
        this.passwordEncoder = passwordEncoder;
        this.tenantContextInterceptor = tenantContextInterceptor;
    }

    @Override
    public UserDtos.UserResponse create(UserDtos.CreateUserRequest req) {
        AuthenticatedUser currentUser = currentUser();
        UUID tenantId = currentUser.tenantId();

        // Authorization: only TENANT_ADMIN+ or PLATFORM_ADMIN+ can create users
        requireAdminRole(currentUser);

        if (userRepository.existsByTenantIdAndEmailAndDeletedAtIsNull(tenantId, req.email())) {
            throw new SheException("CONFLICT_EMAIL_TAKEN",
                    "Email already in use within this tenant", 409);
        }

        User user = new User();
        user.setTenantId(tenantId);
        user.setEmail(req.email());
        user.setPasswordHash(passwordEncoder.encode(req.password()));
        user.setPlatformRole(req.platform_role() != null ? req.platform_role() : "USER");
        user.setTenantRole(req.tenant_role() != null && !req.tenant_role().isBlank() ? req.tenant_role() : null);
        user.setPhoneNumber(req.phone_number());
        user.setFullName(req.full_name());
        user.setPreferredLanguage(req.language() != null ? req.language() : "en");

        User saved = userRepository.save(user);
        return toResponse(saved);
    }

    @Override
    @Transactional(readOnly = true)
    public UserDtos.UserResponse getById(UUID id) {
        return userRepository.findActiveById(id)
                .map(this::toResponse)
                .orElseThrow(() -> new SheException("USER_NOT_FOUND",
                        "User " + id + " does not exist", 404));
    }

    @Override
    @Transactional(readOnly = true)
    public PagedResponse<UserDtos.UserResponse> list(int page, int size) {
        AuthenticatedUser currentUser = currentUser();
        requireAdminRole(currentUser);

        if (size > 100) size = 100;
        if (page < 0) page = 0;

        PageRequest pageable = PageRequest.of(page, size, Sort.by(Sort.Direction.DESC, "createdAt"));
        Page<User> result = userRepository.findAll(pageable);

        List<UserDtos.UserResponse> data = result.getContent().stream()
                .filter(u -> u.getDeletedAt() == null)
                .map(this::toResponse)
                .toList();

        String nextCursor = result.hasNext()
                ? Base64.getUrlEncoder().encodeToString(String.valueOf(page + 1).getBytes())
                : null;
        return PagedResponse.of(data, nextCursor, result.hasNext(), (int) result.getTotalElements());
    }

    @Override
    public UserDtos.UserResponse update(UUID id, UserDtos.UpdateUserRequest req) {
        AuthenticatedUser currentUser = currentUser();
        requireAdminRole(currentUser);

        User user = userRepository.findActiveById(id)
                .orElseThrow(() -> new SheException("USER_NOT_FOUND",
                        "User " + id + " does not exist", 404));

        if (req.email() != null && !req.email().isBlank()) {
            user.setEmail(req.email());
        }
        if (req.phone_number() != null) user.setPhoneNumber(req.phone_number());
        if (req.full_name() != null)    user.setFullName(req.full_name());
        if (req.language() != null)     user.setPreferredLanguage(req.language());
        if (req.platform_role() != null && !req.platform_role().isBlank()) {
            user.setPlatformRole(req.platform_role());
        }
        if (req.tenant_role() != null && !req.tenant_role().isBlank()) {
            user.setTenantRole(req.tenant_role());
        }
        if (req.mfa_enabled() != null) {
            user.setMfaEnabled(req.mfa_enabled());
        }

        User saved = userRepository.save(user);
        return toResponse(saved);
    }

    @Override
    public void softDelete(UUID id) {
        AuthenticatedUser currentUser = currentUser();
        requireAdminRole(currentUser);

        User user = userRepository.findActiveById(id)
                .orElseThrow(() -> new SheException("USER_NOT_FOUND",
                        "User " + id + " does not exist", 404));

        if (user.getId().equals(currentUser.userId())) {
            throw new SheException("VALIDATION_FAILED",
                    "Cannot delete your own account via this endpoint; use /auth/delete-me", 400);
        }

        user.setDeletedAt(Instant.now());
        userRepository.save(user);
    }

    @Override
    @Transactional(readOnly = true)
    public User findEntityForAuth(UUID tenantId, String email) {
        return userRepository.findActiveByEmail(tenantId, email)
                .orElseThrow(() -> new SheException("AUTH_INVALID_CREDENTIALS",
                        "Invalid email or password", 401));
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    private UserDtos.UserResponse toResponse(User u) {
        return new UserDtos.UserResponse(
                u.getId(),
                u.getTenantId(),
                u.getEmail(),
                u.getPlatformRole(),
                u.getTenantRole(),
                u.getPhoneNumber(),
                u.getPreferredLanguage(),
                u.getFullName(),
                u.isMfaEnabled(),
                u.getCreatedAt() != null ? u.getCreatedAt().toString() : null,
                u.getUpdatedAt() != null ? u.getUpdatedAt().toString() : null,
                u.getLastLoginAt() != null ? u.getLastLoginAt().toString() : null
        );
    }

    private AuthenticatedUser currentUser() {
        var principal = SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        if (!(principal instanceof AuthenticatedUser auth)) {
            throw new SheException("AUTH_TOKEN_INVALID", "Not authenticated", 401);
        }
        return auth;
    }

    private void requireAdminRole(AuthenticatedUser user) {
        boolean isAdmin = user.isPlatformAdmin()
                || user.isSuperAdmin()
                || "TENANT_ADMIN".equals(user.tenantRole());
        if (!isAdmin) {
            throw new SheException("RBAC_INSUFFICIENT_ROLE",
                    "TENANT_ADMIN, PLATFORM_ADMIN, or SUPER_ADMIN role required", 403);
        }
    }
}
