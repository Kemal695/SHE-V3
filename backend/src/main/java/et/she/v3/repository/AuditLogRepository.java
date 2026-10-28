package et.she.v3.repository;

import et.she.v3.entity.AuditLog;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

public interface AuditLogRepository extends JpaRepository<AuditLog, UUID> {

    @Query("""
        SELECT a FROM AuditLog a
        WHERE (:tenantId IS NULL OR a.tenantId = :tenantId)
          AND (:action IS NULL OR a.action = :action)
          AND (:actorType IS NULL OR a.actorType = :actorType)
        ORDER BY a.createdAt DESC
        """)
    Page<AuditLog> findFiltered(@Param("tenantId") UUID tenantId,
                                 @Param("action") String action,
                                 @Param("actorType") String actorType,
                                 Pageable pageable);

    @Query("""
        SELECT a FROM AuditLog a
        WHERE (:tenantId IS NULL OR a.tenantId = :tenantId)
          AND a.createdAt >= :from AND a.createdAt <= :to
        ORDER BY a.createdAt ASC
        """)
    List<AuditLog> findForExport(@Param("tenantId") UUID tenantId,
                                  @Param("from") Instant from,
                                  @Param("to") Instant to);

    /**
     * PDPP Art. 17 erasure: audit entries are RETAINED for security forensics
     * but lose the actor link when the user is anonymized
     * (V3-PRIVACY-COMPLIANCE §2, V3-ADMIN-PLATFORM §4.2).
     */
    @Modifying
    @Transactional
    @Query("UPDATE AuditLog a SET a.actorUserId = NULL WHERE a.actorUserId = :userId")
    int clearActorUserId(@Param("userId") UUID userId);
}
