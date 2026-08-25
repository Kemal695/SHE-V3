package et.she.v3.repository;

import et.she.v3.entity.OtaApproval;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
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
}
