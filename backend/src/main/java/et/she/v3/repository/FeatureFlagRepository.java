package et.she.v3.repository;

import et.she.v3.entity.FeatureFlag;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface FeatureFlagRepository extends JpaRepository<FeatureFlag, UUID> {

    @Query("SELECT f FROM FeatureFlag f WHERE f.tenantId = :tenantId ORDER BY f.flagKey")
    List<FeatureFlag> findAllByTenantId(@Param("tenantId") UUID tenantId);

    @Query("SELECT f FROM FeatureFlag f WHERE f.tenantId = :tenantId AND f.flagKey = :flagKey")
    Optional<FeatureFlag> findByTenantAndKey(@Param("tenantId") UUID tenantId, @Param("flagKey") String flagKey);
}
