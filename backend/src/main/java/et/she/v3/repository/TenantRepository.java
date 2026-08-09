package et.she.v3.repository;

import et.she.v3.entity.Tenant;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Optional;
import java.util.UUID;

public interface TenantRepository extends JpaRepository<Tenant, UUID> {

    /**
     * Find by subdomain — used during login to resolve tenant from email domain.
     */
    @Query("""
        SELECT t FROM Tenant t
        WHERE t.subdomain = :subdomain
          AND t.deletedAt IS NULL
        """)
    Optional<Tenant> findBySubdomain(@Param("subdomain") String subdomain);

    /**
     * Find the default B2C tenant (pre-seeded in V1__tenants.sql).
     */
    default Optional<Tenant> findDefaultB2C() {
        return findBySubdomain("default");
    }
}
