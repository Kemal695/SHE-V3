package et.she.v3.repository;

import et.she.v3.entity.Payment;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface PaymentRepository extends JpaRepository<Payment, UUID> {

    @Query("SELECT p FROM Payment p WHERE p.tenantId = :tenantId ORDER BY p.createdAt DESC")
    List<Payment> findAllByTenantId(@Param("tenantId") UUID tenantId);

    @Query("SELECT p FROM Payment p WHERE p.status = :status AND p.createdAt < :before")
    List<Payment> findPendingBefore(@Param("status") String status, @Param("before") java.time.Instant before);

    boolean existsByIdempotencyKeyAndTenantId(UUID idempotencyKey, UUID tenantId);
}
