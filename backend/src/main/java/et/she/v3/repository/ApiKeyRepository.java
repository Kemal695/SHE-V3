package et.she.v3.repository;

import et.she.v3.entity.ApiKey;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface ApiKeyRepository extends JpaRepository<ApiKey, UUID> {

    @Query("SELECT k FROM ApiKey k WHERE k.tenantId = :tenantId AND k.revokedAt IS NULL ORDER BY k.createdAt DESC")
    List<ApiKey> findAllByTenantId(@Param("tenantId") UUID tenantId);

    @Query("SELECT k FROM ApiKey k WHERE k.keyHash = :hash AND k.revokedAt IS NULL")
    Optional<ApiKey> findByKeyHashAndNotRevoked(@Param("hash") String hash);
}
