package et.she.v3.ota;

import et.she.v3.entity.OtaBatch;
import et.she.v3.repository.OtaApprovalRepository;
import et.she.v3.repository.OtaBatchRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * Decides when an OTA batch is finished, and what to do with one that never finishes.
 *
 * Two callers, and they must agree:
 *   - {@code MqttSubscriberService} when a device reports ota/status
 *   - {@code ScheduledJobs} sweeping rollouts that went quiet
 *
 * Why the sweep exists at all: the only thing that moved a batch to a terminal state used to be
 * an incoming device message. If that message never arrives — device offline, powered down, MQTT
 * restart, or simply a device whose bootloader can never produce it — the batch sits in ROLLING
 * forever, and an operator watching the rollout sees "in progress" with no way to tell it died.
 *
 * All reads here are scalar COUNTs, never entities. A {@code @Modifying} bulk update does not
 * refresh entities already in the persistence context, so reading an approval back after
 * updating it returns the pre-update status and every batch looks perpetually in flight.
 */
@Service
public class OtaRollupService {

    private static final Logger log = LoggerFactory.getLogger(OtaRollupService.class);

    /** An approval in any of these has settled — succeeded, failed, or was never actioned. */
    private static final Set<String> TERMINAL_APPROVAL_STATES =
            Set.of("COMPLETED", "FAILED", "DECLINED", "ROLLED_BACK");

    /** An approval in any of these is still waiting on the device. */
    private static final Set<String> IN_FLIGHT_APPROVAL_STATES =
            Set.of("APPROVED", "IN_PROGRESS", "PENDING");

    public static final String STATUS_ROLLING = "ROLLING";

    private final OtaApprovalRepository approvalRepository;
    private final OtaBatchRepository batchRepository;

    public OtaRollupService(OtaApprovalRepository approvalRepository,
                            OtaBatchRepository batchRepository) {
        this.approvalRepository = approvalRepository;
        this.batchRepository = batchRepository;
    }

    /**
     * Move a batch to a terminal state once every approval has settled.
     *
     * @return true if the batch's status actually changed.
     */
    public boolean rollUp(UUID batchId) {
        long total = approvalRepository.countAllByBatchId(batchId);
        if (total == 0) {
            return false;
        }
        long inFlight = approvalRepository.countInFlightByBatchId(batchId);
        if (inFlight > 0) {
            log.debug("OTA batch {} still has {} approval(s) in flight", batchId, inFlight);
            return false;
        }
        long failed = approvalRepository.countFailedByBatchId(batchId);
        String newStatus = failed > 0 ? "FAILED" : "COMPLETED";

        return batchRepository.findById(batchId).map(batch -> {
            if (newStatus.equals(batch.getStatus())) {
                return false;
            }
            batch.setStatus(newStatus);
            batchRepository.save(batch);
            log.info("OTA batch {} rolled up to {} ({} approval(s), {} failed)",
                    batchId, newStatus, total, failed);
            return true;
        }).orElse(false);
    }

    /**
     * Give up on approvals whose device never reported back.
     *
     * The timeout is a judgement call and deliberately generous: too short and a device that
     * was offline for an ordinary outage gets its rollout marked failed while it is in fact
     * still going to apply the update when it returns. Too long and the admin view shows a dead
     * rollout as in-progress. Failing here is recoverable — the device still updates on the
     * next batch — whereas a premature "COMPLETED" would be a lie, so the bias is to wait.
     *
     * @return how many approvals were marked failed.
     */
    public int failStaleApprovals(int staleAfterMinutes) {
        Instant cutoff = Instant.now().minus(staleAfterMinutes, ChronoUnit.MINUTES);
        int n = approvalRepository.failStaleBefore(
                cutoff,
                IN_FLIGHT_APPROVAL_STATES,
                "no ota/status reported within " + staleAfterMinutes + " minutes");
        if (n > 0) {
            log.info("OTA sweep: {} approval(s) gave up after {} min without a device status",
                    n, staleAfterMinutes);
        }
        return n;
    }

    /**
     * Roll up any ROLLING batch whose approvals have all settled.
     *
     * This also repairs batches that were already finished underneath — for example one whose
     * approval reached a terminal state while the batch update was silently skipped, leaving an
     * approval that says COMPLETED next to a batch that still says ROLLING.
     *
     * @return how many batches changed status.
     */
    public int rollUpRollingBatches() {
        List<OtaBatch> rolling = batchRepository.findByStatus(STATUS_ROLLING);
        int changed = 0;
        for (OtaBatch batch : rolling) {
            if (rollUp(batch.getId())) {
                changed++;
            }
        }
        return changed;
    }
}
