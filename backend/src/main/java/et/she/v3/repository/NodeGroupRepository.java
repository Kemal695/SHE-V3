package et.she.v3.repository;

import et.she.v3.entity.NodeGroup;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface NodeGroupRepository extends JpaRepository<NodeGroup, UUID> {

    @Query("SELECT g FROM NodeGroup g WHERE g.homeId = :homeId AND g.deletedAt IS NULL ORDER BY g.createdAt")
    List<NodeGroup> findAllByHomeId(@Param("homeId") UUID homeId);

    @Query("SELECT g FROM NodeGroup g WHERE g.id = :id AND g.deletedAt IS NULL")
    Optional<NodeGroup> findByIdAndNotDeleted(@Param("id") UUID id);
}
