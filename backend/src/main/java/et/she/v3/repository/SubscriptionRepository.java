package et.she.v3.repository;

import et.she.v3.entity.Subscription;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface SubscriptionRepository extends JpaRepository<Subscription, UUID> {

    @Query("SELECT s FROM Subscription s WHERE s.tenantId = :tenantId AND s.status = :status")
    Optional<Subscription> findByTenantIdAndStatus(@Param("tenantId") UUID tenantId, @Param("status") String status);

    @Query("SELECT s FROM Subscription s WHERE s.tenantId = :tenantId ORDER BY s.createdAt DESC")
    List<Subscription> findAllByTenantId(@Param("tenantId") UUID tenantId);

    @Query("SELECT s FROM Subscription s WHERE s.status = 'ACTIVE' AND s.expiresAt < :now")
    List<Subscription> findExpiredActive(@Param("now") java.time.Instant now);

    @Query("SELECT s FROM Subscription s WHERE s.status = 'ACTIVE' AND s.expiresAt < :cutoff")
    List<Subscription> findExpiringBefore(@Param("cutoff") java.time.Instant cutoff);
}
