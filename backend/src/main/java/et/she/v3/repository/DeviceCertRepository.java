package et.she.v3.repository;

import et.she.v3.entity.DeviceCert;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Optional;
import java.util.UUID;

/**
 * Device cert repository — used by EMQX HTTP auth backend endpoint
 * POST /internal/mqtt/auth (V3-SECURITY-MODEL §4.2).
 */
public interface DeviceCertRepository extends JpaRepository<DeviceCert, UUID> {

    /**
     * Find an ACTIVE device cert by SHA-256 fingerprint.
     * EMQX calls this on every new MQTT connection (cache TTL 300s per P1-11).
     */
    @Query("""
        SELECT dc FROM DeviceCert dc
        WHERE dc.fingerprint = :fingerprint
          AND dc.status = 'ACTIVE'
          AND dc.expiresAt > CURRENT_TIMESTAMP
        """)
    Optional<DeviceCert> findActiveByFingerprint(@Param("fingerprint") String fingerprint);

    /**
     * Find by CN (normalized MAC) — used to lookup during cert issuance.
     */
    @Query("""
        SELECT dc FROM DeviceCert dc
        WHERE dc.cn = :cn
          AND dc.status = 'ACTIVE'
        """)
    Optional<DeviceCert> findActiveByCn(@Param("cn") String cn);

    /**
     * Find by cert serial — used by revocation endpoint.
     */
    @Query("""
        SELECT dc FROM DeviceCert dc
        WHERE dc.certSerial = :serial
          AND dc.status = 'ACTIVE'
        """)
    Optional<DeviceCert> findActiveByCertSerial(@Param("serial") String serial);

    /**
     * Check if a cert with the given serial already exists (idempotency for factory).
     */
    boolean existsByCertSerial(String certSerial);
}
