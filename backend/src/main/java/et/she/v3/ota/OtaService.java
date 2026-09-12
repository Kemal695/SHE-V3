package et.she.v3.ota;

import et.she.v3.dto.OtaDtos;
import et.she.v3.entity.Node;
import et.she.v3.entity.OtaApproval;
import et.she.v3.entity.OtaBatch;
import et.she.v3.errors.SheException;
import et.she.v3.mqtt.MqttPublishService;
import et.she.v3.repository.NodeRepository;
import et.she.v3.repository.OtaApprovalRepository;
import et.she.v3.repository.OtaBatchRepository;
import et.she.v3.security.AuthenticatedUser;
import et.she.v3.service.HomeService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * OTA service — self-hosted OTA via MinIO + Ed25519-signed firmware.
 *
 * V3-FIRMWARE §6. V3-API-SPECIFICATION §9.
 *
 * Flow:
 *   1. Admin creates batch (POST /api/v3/homes/{homeId}/ota/batches)
 *   2. Admin starts batch (POST /api/v3/ota/batches/{id}/start) — creates PENDING approvals
 *   3. Spring Boot publishes ota/url to each node via MQTT
 *   4. Device downloads, verifies Ed25519, writes to alternate partition, reboots
 *   5. Device reports ota/status (downloading → flashing → rebooting → complete/rolled_back/failed)
 *   6. Device reports ota/progress (0-100%)
 *   7. Spring Boot updates ota_approvals + pushes WebSocket ota.progress
 */
@Service
@Transactional
public class OtaService {

    private static final Logger log = LoggerFactory.getLogger(OtaService.class);

    private final OtaBatchRepository batchRepository;
    private final OtaApprovalRepository approvalRepository;
    private final NodeRepository nodeRepository;
    private final MqttPublishService mqttPublishService;
    private final HomeService homeService;

    public OtaService(OtaBatchRepository batchRepository, OtaApprovalRepository approvalRepository,
                      NodeRepository nodeRepository,
                      MqttPublishService mqttPublishService, HomeService homeService) {
        this.batchRepository = batchRepository;
        this.approvalRepository = approvalRepository;
        this.nodeRepository = nodeRepository;
        this.mqttPublishService = mqttPublishService;
        this.homeService = homeService;
    }

    public OtaDtos.BatchResponse createBatch(UUID homeId, OtaDtos.CreateBatchRequest req) {
        // V3-API-SPECIFICATION §9: POST /homes/{homeId}/ota/batches requires home OWNER.
        // (Previously required TENANT_ADMIN, which no normally-registered user can ever
        // hold — registration leaves tenant_role null and only an admin can promote —
        // so OTA was unusable for every real user.)
        homeService.requireHomeAccess(homeId, "OWNER");
        AuthenticatedUser user = currentUser();
        OtaBatch batch = new OtaBatch();
        batch.setTenantId(user.tenantId());
        batch.setHomeId(homeId);
        batch.setFirmwareVersion(req.firmware_version());
        batch.setFirmwareUrl(req.firmware_url());
        batch.setFirmwareChecksum(req.firmware_checksum());
        batch.setSignatureEd25519(req.signature_ed25519());
        batch.setTargetSku(req.target_sku());
        batch.setRolloutPercent(req.rollout_percent() != null ? req.rollout_percent() : 100);
        batch.setAutoApprove(req.auto_approve() != null && req.auto_approve());
        batch.setStatus("DRAFT");
        batch.setCreatedByUserId(user.userId());
        // saveAndFlush, not save: @CreationTimestamp / @UpdateTimestamp are applied when
        // the INSERT executes. With GenerationType.UUID the id is generated in memory, so
        // save() merely registers the entity and defers the INSERT to commit — leaving
        // createdAt null while toBatchResponse() runs and NPE-ing the whole request.
        batch = batchRepository.saveAndFlush(batch);
        log.info("OTA batch created: id={} version={} sku={}", batch.getId(), batch.getFirmwareVersion(), batch.getTargetSku());
        return toBatchResponse(batch, 0);
    }

    @Transactional(readOnly = true)
    public List<OtaDtos.BatchResponse> listBatches(UUID homeId) {
        // V3-API-SPECIFICATION §9: GET /homes/{homeId}/ota/batches requires MEMBER+.
        homeService.requireHomeAccess(homeId, "MEMBER");
        AuthenticatedUser user = currentUser();
        return batchRepository.findAllByTenantAndHome(user.tenantId(), homeId).stream()
                .map(b -> toBatchResponse(b, approvalRepository.findAllByBatchId(b.getId()).size()))
                .toList();
    }

    @Transactional(readOnly = true)
    public OtaDtos.BatchResponse getBatch(UUID batchId) {
        OtaBatch batch = getOwnedBatchOrThrow(batchId);
        homeService.requireHomeAccess(batch.getHomeId(), "MEMBER");
        return toBatchResponse(batch, approvalRepository.findAllByBatchId(batchId).size());
    }

    /**
     * Start batch — creates PENDING approvals for matching nodes + publishes ota/url via MQTT.
     */
    public OtaDtos.BatchActionResponse startBatch(UUID batchId) {
        AuthenticatedUser user = currentUser();
        OtaBatch batch = getOwnedBatchOrThrow(batchId);
        // V3-API-SPECIFICATION §9: POST /ota/batches/{id}/start requires ADMIN+.
        homeService.requireHomeAccess(batch.getHomeId(), "ADMIN");

        batch.setStatus("ROLLING");
        batchRepository.save(batch);

        // Find matching nodes (by sku + home)
        List<Node> matchingNodes = nodeRepository.findAllByTenantAndHome(user.tenantId(), batch.getHomeId())
                .stream()
                .filter(n -> batch.getTargetSku().equals(n.getSku()))
                .filter(n -> n.getDeletedAt() == null)
                .toList();

        int affected = 0;
        for (Node node : matchingNodes) {
            // Apply rollout_percent (deterministic hash-based selection)
            if (Math.abs(node.getId().hashCode()) % 100 >= batch.getRolloutPercent()) continue;

            // Create or update approval
            OtaApproval approval = approvalRepository.findByBatchAndNode(batchId, node.getId())
                    .orElseGet(() -> {
                        OtaApproval a = new OtaApproval();
                        a.setTenantId(user.tenantId());
                        a.setBatchId(batchId);
                        a.setNodeId(node.getId());
                        return a;
                    });

            if (batch.isAutoApprove()) {
                approval.setStatus("APPROVED");
                approval.setApprovedByUserId(user.userId());
                approval.setApprovedAt(Instant.now());
            } else {
                approval.setStatus("PENDING");
            }
            approval.setDeploymentStatus("PENDING");
            approval.setProgress(0);
            approvalRepository.save(approval);
            affected++;

            // Publish ota/url to the device via MQTT (only for APPROVED nodes)
            if ("APPROVED".equals(approval.getStatus())) {
                publishOtaUrlToNode(node, batch);
                approval.setDeploymentStatus("DOWNLOADING");
                approvalRepository.save(approval);
            }
        }

        log.info("OTA batch started: id={} affected={}/{} nodes", batchId, affected, matchingNodes.size());
        return new OtaDtos.BatchActionResponse(batchId, batch.getStatus(), affected);
    }

    public OtaDtos.BatchActionResponse abortBatch(UUID batchId) {
        OtaBatch batch = getOwnedBatchOrThrow(batchId);
        // V3-API-SPECIFICATION §9: POST /ota/batches/{id}/abort requires OWNER.
        homeService.requireHomeAccess(batch.getHomeId(), "OWNER");
        batch.setStatus("ABORTED");
        batchRepository.save(batch);

        // Mark all IN_PROGRESS approvals as FAILED
        List<OtaApproval> approvals = approvalRepository.findAllByBatchId(batchId);
        int affected = 0;
        for (OtaApproval a : approvals) {
            if ("IN_PROGRESS".equals(a.getStatus()) || "APPROVED".equals(a.getStatus())) {
                a.setStatus("FAILED");
                a.setLastError("Batch aborted by admin");
                approvalRepository.save(a);
                affected++;
            }
        }
        log.info("OTA batch aborted: id={} affected={} nodes", batchId, affected);
        return new OtaDtos.BatchActionResponse(batchId, "ABORTED", affected);
    }

    public OtaDtos.ApprovalResponse approveApproval(UUID approvalId) {
        AuthenticatedUser user = currentUser();
        OtaApproval approval = approvalRepository.findById(approvalId)
                .orElseThrow(() -> new SheException("OTA_APPROVAL_NOT_FOUND", "Approval " + approvalId + " not found", 404));
        // V3-API-SPECIFICATION §9: approve requires ADMIN+.
        OtaBatch batch = getOwnedBatchOrThrow(approval.getBatchId());
        homeService.requireHomeAccess(batch.getHomeId(), "ADMIN");
        approval.setStatus("APPROVED");
        approval.setApprovedByUserId(user.userId());
        approval.setApprovedAt(Instant.now());
        approvalRepository.save(approval);

        // Publish ota/url to the device
        Node node = nodeRepository.findById(approval.getNodeId()).orElseThrow();
        publishOtaUrlToNode(node, batch);
        approval.setDeploymentStatus("DOWNLOADING");
        approvalRepository.save(approval);

        return toApprovalResponse(approval);
    }

    public OtaDtos.ApprovalResponse declineApproval(UUID approvalId) {
        OtaApproval approval = approvalRepository.findById(approvalId)
                .orElseThrow(() -> new SheException("OTA_APPROVAL_NOT_FOUND", "Approval " + approvalId + " not found", 404));
        // V3-API-SPECIFICATION §9: decline requires ADMIN+.
        OtaBatch batch = getOwnedBatchOrThrow(approval.getBatchId());
        homeService.requireHomeAccess(batch.getHomeId(), "ADMIN");
        approval.setStatus("DECLINED");
        approvalRepository.save(approval);
        return toApprovalResponse(approval);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    private void publishOtaUrlToNode(Node node, OtaBatch batch) {
        try {
            String tenantShort = shortId(node.getTenantId());
            String homeShort = node.getHomeId() != null ? shortId(node.getHomeId()) : "00000000";
            String roomShort = node.getRoomId() != null ? shortId(node.getRoomId()) : "unassigned";

            Map<String, Object> otaPayload = Map.of(
                    "version", batch.getFirmwareVersion(),
                    "url", batch.getFirmwareUrl(),
                    "sig", batch.getSignatureEd25519(),
                    "size", 0,    // TODO: compute from MinIO HEAD
                    "min_hw_rev", "rev-a",
                    "checksum", batch.getFirmwareChecksum()
            );
            mqttPublishService.publishOtaUrl(tenantShort, homeShort, roomShort,
                    node.getNormalizedMac(), otaPayload, System.currentTimeMillis());
        } catch (Exception e) {
            log.error("Failed to publish ota/url to node {}: {}", node.getNodeId(), e.getMessage());
        }
    }

    private OtaDtos.BatchResponse toBatchResponse(OtaBatch b, int approvalCount) {
        return new OtaDtos.BatchResponse(
                b.getId(), b.getFirmwareVersion(), b.getTargetSku(), b.getStatus(),
                b.getRolloutPercent(), b.isAutoApprove(),
                b.getCreatedAt().toString(), approvalCount
        );
    }

    private OtaDtos.ApprovalResponse toApprovalResponse(OtaApproval a) {
        return new OtaDtos.ApprovalResponse(
                a.getId(), a.getBatchId(), a.getNodeId(), a.getStatus(),
                a.getDeploymentStatus(), a.getProgress(), a.getLastError()
        );
    }

    private String shortId(UUID id) {
        if (id == null) return "00000000";
        return id.toString().replace("-", "").substring(0, 8);
    }

    /**
     * Cross-tenant guard (H2 fix) — batches are tenant-scoped; touching another
     * tenant's batch returns 404 so batch IDs can't be probed across tenants.
     */
    private OtaBatch getOwnedBatchOrThrow(UUID batchId) {
        AuthenticatedUser user = currentUser();
        OtaBatch batch = batchRepository.findById(batchId)
                .orElseThrow(() -> new SheException("OTA_BATCH_NOT_FOUND", "Batch " + batchId + " not found", 404));
        if (batch.getTenantId() == null || !batch.getTenantId().equals(user.tenantId())) {
            throw new SheException("OTA_BATCH_NOT_FOUND", "Batch " + batchId + " not found", 404);
        }
        return batch;
    }

    private AuthenticatedUser currentUser() {
        return (AuthenticatedUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal();
    }
}
