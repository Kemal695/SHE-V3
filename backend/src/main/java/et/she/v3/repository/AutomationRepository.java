package et.she.v3.repository;

import et.she.v3.entity.Automation;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface AutomationRepository extends JpaRepository<Automation, UUID> {

    @Query("SELECT a FROM Automation a WHERE a.homeId = :homeId AND a.deletedAt IS NULL ORDER BY a.createdAt")
    List<Automation> findAllByHomeId(@Param("homeId") UUID homeId);

    @Query("SELECT a FROM Automation a WHERE a.id = :id AND a.deletedAt IS NULL")
    Optional<Automation> findByIdAndNotDeleted(@Param("id") UUID id);

    @Query("SELECT a FROM Automation a WHERE a.enabled = true AND a.deletedAt IS NULL")
    List<Automation> findAllEnabled();
}
