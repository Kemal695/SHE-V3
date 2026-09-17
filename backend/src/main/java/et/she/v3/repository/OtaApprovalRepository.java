package et.she.v3.repository;

import et.she.v3.entity.OtaApproval;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

public interface OtaApprovalRepository extends JpaRepository<OtaApproval, UUID> {
    @Query("SELECT a FROM OtaApproval a WHERE a.batchId = :batchId")
    List<OtaApproval> findAllByBatchId(@Param("batchId") UUID batchId);

    @Query("SELECT a FROM OtaApproval a WHERE a.batchId = :batchId AND a.nodeId = :nodeId")
    Optional<OtaApproval> findByBatchAndNode(@Param("batchId") UUID batchId, @Param("nodeId") UUID nodeId);

    @Modifying
    @Query("UPDATE OtaApproval a SET a.status = :status, a.deploymentStatus = :depStatus, a.progress = :progress WHERE a.id = :id")
    int updateDeployment(@Param("id") UUID id, @Param("status") String status,
                         @Param("depStatus") String depStatus, @Param("progress") int progress);

    @Modifying
    @Query("UPDATE OtaApproval a SET a.deploymentStatus = :depStatus, a.progress = :progress WHERE a.id = :id")
    int updateProgress(@Param("id") UUID id, @Param("depStatus") String depStatus,
                       @Param("progress") int progress);

    @Modifying
    @Query("UPDATE OtaApproval a SET a.status = :status, a.lastError = :lastError WHERE a.id = :id")
    int updateTerminal(@Param("id") UUID id, @Param("status") String status,
                       @Param("lastError") String lastError);

    /**
     * Counts rather than entities, deliberately.
     *
     * A @Modifying bulk UPDATE does not refresh entities already loaded in the persistence
     * context. recordOtaStatus() loads an approval, updates it by bulk query, then asks whether
     * the whole batch has finished — and reading the entity back returned the *stale* in-memory
     * row (still IN_PROGRESS), so the rollup never fired and a finished batch stayed ROLLING
     * forever. Scalar counts always go to the database, so they see the update.
     */
    @Query("SELECT COUNT(a) FROM OtaApproval a WHERE a.batchId = :batchId")
    long countAllByBatchId(@Param("batchId") UUID batchId);

    @Query("SELECT COUNT(a) FROM OtaApproval a WHERE a.batchId = :batchId "
         + "AND a.status NOT IN ('COMPLETED','FAILED','DECLINED','ROLLED_BACK')")
    long countInFlightByBatchId(@Param("batchId") UUID batchId);

    @Query("SELECT COUNT(a) FROM OtaApproval a WHERE a.batchId = :batchId "
         + "AND a.status IN ('FAILED','ROLLED_BACK')")
    long countFailedByBatchId(@Param("batchId") UUID batchId);

    /**
     * Abandon approvals whose device never reported anything at all.
     *
     * Used by the scheduled sweep. Without it a device that went offline mid-rollout — or one
     * that can never report, see OtaRollupService — pins its batch in ROLLING indefinitely.
     *
     * Keyed on createdAt, not updatedAt, on purpose: updatedAt is @UpdateTimestamp, which
     * Hibernate only maintains on entity save(). The progress/deployment updates here are bulk
     * JPQL and bypass it, so updatedAt does not track device activity and using it would fail
     * rollouts that are in fact still progressing.
     */
    @Modifying
    @Query("UPDATE OtaApproval a SET a.status = 'FAILED', a.lastError = :error "
         + "WHERE a.status IN :states AND a.createdAt < :cutoff")
    int failStaleBefore(@Param("cutoff") Instant cutoff,
                        @Param("states") Set<String> states,
                        @Param("error") String error);

    /**
     * Approvals for a node that are still in flight.
     *
     * The device reports ota/status with only its MAC and a version — never a batch id — so
     * this is how an incoming status is matched back to the rollout it belongs to. Newest
     * first, because a node can have been targeted by more than one batch over time.
     */
    @Query("SELECT a FROM OtaApproval a WHERE a.nodeId = :nodeId "
         + "AND a.status NOT IN ('COMPLETED','FAILED','DECLINED','ROLLED_BACK') "
         + "ORDER BY a.createdAt DESC")
    List<OtaApproval> findActiveByNode(@Param("nodeId") UUID nodeId);
}
