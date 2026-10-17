package et.she.v3.repository;

import et.she.v3.entity.User;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Optional;
import java.util.UUID;

/**
 * User repository — Phase 0's CRUD endpoint target.
 *
 * Custom queries respect RLS via the `app.tenant_id` GUC set by TenantContextFilter (P0-5).
 */
public interface UserRepository extends JpaRepository<User, UUID> {

    /**
     * Find a non-deleted user by email within the current tenant (RLS-enforced).
     * Used by /api/v3/auth/login.
     */
    @Query("""
        SELECT u FROM User u
        WHERE u.email = :email
          AND u.tenantId = :tenantId
          AND u.deletedAt IS NULL
        """)
    Optional<User> findActiveByEmail(@Param("tenantId") UUID tenantId, @Param("email") String email);

    /**
     * Check if email is taken (for /auth/register validation).
     */
    boolean existsByTenantIdAndEmailAndDeletedAtIsNull(UUID tenantId, String email);

    /**
     * Find a non-deleted user by ID (RLS-enforced via the policy).
     */
    @Query("""
        SELECT u FROM User u
        WHERE u.id = :id
          AND u.deletedAt IS NULL
        """)
    Optional<User> findActiveById(@Param("id") UUID id);

    /**
     * Find a non-deleted user already linked to a given OAuth provider identity.
     * Used by /auth/oauth/{provider} so a returning social user is matched by
     * subject (stable) rather than email (Apple only sends it once).
     */
    @Query("""
        SELECT u FROM User u
        WHERE u.tenantId = :tenantId
          AND u.oauthProvider = :provider
          AND u.oauthSubject = :subject
          AND u.deletedAt IS NULL
        """)
    Optional<User> findActiveByOauth(@Param("tenantId") UUID tenantId,
                                     @Param("provider") String provider,
                                     @Param("subject") String subject);
}
