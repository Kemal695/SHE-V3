package et.she.v3.repository;

import et.she.v3.entity.Home;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface HomeRepository extends JpaRepository<Home, UUID> {
    @Query("SELECT h FROM Home h WHERE h.tenantId = :tenantId AND h.deletedAt IS NULL ORDER BY h.createdAt DESC")
    List<Home> findAllByTenantId(@Param("tenantId") UUID tenantId);

    @Query("SELECT h FROM Home h WHERE h.id = :id AND h.deletedAt IS NULL")
    Optional<Home> findActiveById(@Param("id") UUID id);
}
