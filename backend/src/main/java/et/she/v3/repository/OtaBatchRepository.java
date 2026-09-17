package et.she.v3.repository;

import et.she.v3.entity.OtaBatch;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface OtaBatchRepository extends JpaRepository<OtaBatch, UUID> {
    @Query("SELECT b FROM OtaBatch b WHERE b.tenantId = :tenantId AND b.homeId = :homeId ORDER BY b.createdAt DESC")
    List<OtaBatch> findAllByTenantAndHome(@Param("tenantId") UUID tenantId, @Param("homeId") UUID homeId);

    @Query("SELECT b FROM OtaBatch b WHERE b.id = :id")
    Optional<OtaBatch> findById(@Param("id") UUID id);

    /**
     * Every batch in a given status, across all tenants.
     *
     * Only ever called by the platform-admin sweep, which sets app.is_platform_admin first —
     * under RLS an unqualified query like this matches nothing otherwise.
     */
    @Query("SELECT b FROM OtaBatch b WHERE b.status = :status")
    List<OtaBatch> findByStatus(@Param("status") String status);
}
