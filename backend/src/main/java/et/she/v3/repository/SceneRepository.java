package et.she.v3.repository;

import et.she.v3.entity.Scene;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface SceneRepository extends JpaRepository<Scene, UUID> {

    @Query("SELECT s FROM Scene s WHERE s.homeId = :homeId AND s.deletedAt IS NULL ORDER BY s.sortOrder, s.createdAt")
    List<Scene> findAllByHomeId(@Param("homeId") UUID homeId);

    @Query("SELECT s FROM Scene s WHERE s.id = :id AND s.deletedAt IS NULL")
    Optional<Scene> findByIdAndNotDeleted(@Param("id") UUID id);
}
