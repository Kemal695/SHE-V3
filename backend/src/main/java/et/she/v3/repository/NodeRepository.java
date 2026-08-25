package et.she.v3.repository;

import et.she.v3.entity.Node;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * Node repository — RainMaker hierarchy root.
 *
 * V3-SECURITY-MODEL §4.2 — EMQX auth backend looks up by cert_fingerprint.
 * V3-ARCHITECTURE §7 — MQTT topic namespace uses normalized_mac.
 */
public interface NodeRepository extends JpaRepository<Node, UUID> {

    @Query("SELECT n FROM Node n WHERE n.tenantId = :tenantId AND n.homeId = :homeId AND n.deletedAt IS NULL ORDER BY n.name")
    List<Node> findAllByTenantAndHome(@Param("tenantId") UUID tenantId, @Param("homeId") UUID homeId);

    @Query("SELECT n FROM Node n WHERE n.id = :id AND n.deletedAt IS NULL")
    Optional<Node> findActiveById(@Param("id") UUID id);

    @Query("SELECT n FROM Node n WHERE n.normalizedMac = :mac AND n.deletedAt IS NULL")
    Optional<Node> findByNormalizedMac(@Param("mac") String mac);

    @Query("SELECT n FROM Node n WHERE n.certFingerprint = :fp AND n.deletedAt IS NULL")
    Optional<Node> findByCertFingerprint(@Param("fp") String fp);

    @Query("SELECT n FROM Node n WHERE n.tenantId IS NULL AND n.deletedAt IS NULL")
    List<Node> findUnclaimedNodes();

    @Modifying
    @Query("UPDATE Node n SET n.isOnline = :online, n.lastSeenAt = :lastSeen WHERE n.id = :id")
    void updatePresence(@Param("id") UUID id, @Param("online") boolean online, @Param("lastSeen") Instant lastSeen);

    @Modifying
    @Query("UPDATE Node n SET n.tenantId = :tenantId, n.provisionedAt = :provisionedAt WHERE n.id = :id")
    int claimNode(@Param("id") UUID id, @Param("tenantId") UUID tenantId, @Param("provisionedAt") Instant provisionedAt);
}
