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
}
