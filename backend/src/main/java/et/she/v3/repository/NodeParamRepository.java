package et.she.v3.repository;

import et.she.v3.entity.NodeParam;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface NodeParamRepository extends JpaRepository<NodeParam, UUID> {
    @Query("SELECT p FROM NodeParam p WHERE p.nodeDeviceId = :deviceId")
    List<NodeParam> findAllByDeviceId(@Param("deviceId") UUID deviceId);

    @Query("SELECT p FROM NodeParam p WHERE p.nodeId = :nodeId")
    List<NodeParam> findAllByNodeId(@Param("nodeId") UUID nodeId);

    @Query("SELECT p FROM NodeParam p WHERE p.nodeDeviceId = :deviceId AND p.paramName = :name")
    Optional<NodeParam> findByDeviceAndName(@Param("deviceId") UUID deviceId, @Param("name") String name);

    /**
     * Update cached last_value + last_reported_at on MQTT params/local message.
     * V3-MQTT-STANDARDS §5 — device shadow reconciliation.
     */
    @Modifying
    @Query("UPDATE NodeParam p SET p.lastValue = :value, p.lastReportedAt = :reportedAt WHERE p.id = :id")
    int updateLastValue(@Param("id") UUID id, @Param("value") Object value, @Param("reportedAt") Instant reportedAt);
}
