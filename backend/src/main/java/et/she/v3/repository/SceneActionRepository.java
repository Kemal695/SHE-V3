package et.she.v3.repository;

import et.she.v3.entity.SceneAction;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public interface SceneActionRepository extends JpaRepository<SceneAction, UUID> {

    @Query("SELECT a FROM SceneAction a WHERE a.sceneId = :sceneId ORDER BY a.sortOrder, a.createdAt")
    List<SceneAction> findAllBySceneId(@Param("sceneId") UUID sceneId);
}
