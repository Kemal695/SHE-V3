package et.she.v3.repository;

import et.she.v3.entity.NodeDevice;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface NodeDeviceRepository extends JpaRepository<NodeDevice, UUID> {
    @Query("SELECT d FROM NodeDevice d WHERE d.nodeId = :nodeId ORDER BY d.channelIndex NULLS LAST, d.deviceName")
    List<NodeDevice> findAllByNodeId(@Param("nodeId") UUID nodeId);

    @Query("SELECT d FROM NodeDevice d WHERE d.nodeId = :nodeId AND d.deviceName = :name")
    Optional<NodeDevice> findByNodeAndName(@Param("nodeId") UUID nodeId, @Param("name") String name);

    @Query("SELECT d FROM NodeDevice d WHERE d.id = :id")
    Optional<NodeDevice> findById(@Param("id") UUID id);
}
