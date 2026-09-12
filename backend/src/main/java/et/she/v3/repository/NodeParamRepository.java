package et.she.v3.repository;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
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

    /** Serializes param values to JSON text for the jsonb column below. */
    ObjectMapper JSON = new ObjectMapper();

    @Query("SELECT p FROM NodeParam p WHERE p.nodeDeviceId = :deviceId")
    List<NodeParam> findAllByDeviceId(@Param("deviceId") UUID deviceId);

    @Query("SELECT p FROM NodeParam p WHERE p.nodeId = :nodeId")
    List<NodeParam> findAllByNodeId(@Param("nodeId") UUID nodeId);

    @Query("SELECT p FROM NodeParam p WHERE p.nodeDeviceId = :deviceId AND p.paramName = :name")
    Optional<NodeParam> findByDeviceAndName(@Param("deviceId") UUID deviceId, @Param("name") String name);

    /**
     * Update cached last_value + last_reported_at on an MQTT params/local message.
     * V3-MQTT-STANDARDS §5 — device shadow reconciliation.
     *
     * <p>Why a native query with an explicit CAST: {@code node_params.last_value} is
     * {@code jsonb}. The previous HQL bulk update bound {@code :value} using the
     * <em>runtime</em> Java class of the argument (a {@code Boolean} for {@code Power}),
     * which Hibernate sent as a SQL {@code boolean}. Postgres then failed with
     * "column last_value is of type jsonb but expression is of type boolean" and every
     * param write returned HTTP 500. An entity-level {@code @JdbcTypeCode(SqlTypes.JSON)}
     * does not propagate to HQL query parameters, so the value is serialized to a JSON
     * string here and cast to {@code jsonb} explicitly.
     */
    default int updateLastValue(UUID id, Object value, Instant reportedAt) {
        final String json;
        try {
            json = JSON.writeValueAsString(value);
        } catch (JsonProcessingException e) {
            throw new IllegalArgumentException(
                    "Cannot serialize param value to JSON for node_params.last_value: " + value, e);
        }
        return updateLastValueJson(id, json, reportedAt);
    }

    @Modifying
    @Query(value = "UPDATE node_params SET last_value = CAST(:value AS jsonb), "
            + "last_reported_at = :reportedAt WHERE id = :id", nativeQuery = true)
    int updateLastValueJson(@Param("id") UUID id,
                            @Param("value") String value,
                            @Param("reportedAt") Instant reportedAt);
}
