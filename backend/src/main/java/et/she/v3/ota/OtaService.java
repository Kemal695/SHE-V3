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

    public OtaService(OtaBatchRepository batchRepository, OtaApprovalRepository approvalRepository,
                      NodeRepository nodeRepository, MqttPublishService mqttPublishService) {
        this.batchRepository = batchRepository;
        this.approvalRepository = approvalRepository;
        this.nodeRepository = nodeRepository;
        this.mqttPublishService = mqttPublishService;
    }

    public OtaDtos.BatchResponse createBatch(UUID homeId, OtaDtos.CreateBatchRequest req) {
        requireTenantAdmin();
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
        batch = batchRepository.save(batch);
        log.info("OTA batch created: id={} version={} sku={}", batch.getId(), batch.getFirmwareVersion(), batch.getTargetSku());
        return toBatchResponse(batch, 0);
    }

    @Transactional(readOnly = true)
    public List<OtaDtos.BatchResponse> listBatches(UUID homeId) {
        AuthenticatedUser user = currentUser();
        return batchRepository.findAllByTenantAndHome(user.tenantId(), homeId).stream()
                .map(b -> toBatchResponse(b, approvalRepository.findAllByBatchId(b.getId()).size()))
                .toList();
    }

    @Transactional(readOnly = true)
    public OtaDtos.BatchResponse getBatch(UUID batchId) {
        OtaBatch batch = batchRepository.findById(batchId)
                .orElseThrow(() -> new SheException("OTA_BATCH_NOT_FOUND", "Batch " + batchId + " not found", 404));
        return toBatchResponse(batch, approvalRepository.findAllByBatchId(batchId).size());
    }

    /**
     * Start batch — creates PENDING approvals for matching nodes + publishes ota/url via MQTT.
     */
    public OtaDtos.BatchActionResponse startBatch(UUID batchId) {
        requireTenantAdmin();
        AuthenticatedUser user = currentUser();
        OtaBatch batch = batchRepository.findById(batchId)
                .orElseThrow(() -> new SheException("OTA_BATCH_NOT_FOUND", "Batch " + batchId + " not found", 404));

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
        requireTenantAdmin();
        OtaBatch batch = batchRepository.findById(batchId)
                .orElseThrow(() -> new SheException("OTA_BATCH_NOT_FOUND", "Batch " + batchId + " not found", 404));
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
        requireTenantAdmin();
        AuthenticatedUser user = currentUser();
        OtaApproval approval = approvalRepository.findById(approvalId)
                .orElseThrow(() -> new SheException("OTA_APPROVAL_NOT_FOUND", "Approval " + approvalId + " not found", 404));
        approval.setStatus("APPROVED");
        approval.setApprovedByUserId(user.userId());
        approval.setApprovedAt(Instant.now());
        approvalRepository.save(approval);

        // Publish ota/url to the device
        OtaBatch batch = batchRepository.findById(approval.getBatchId()).orElseThrow();
        Node node = nodeRepository.findById(approval.getNodeId()).orElseThrow();
        publishOtaUrlToNode(node, batch);
        approval.setDeploymentStatus("DOWNLOADING");
        approvalRepository.save(approval);

        return toApprovalResponse(approval);
    }

    public OtaDtos.ApprovalResponse declineApproval(UUID approvalId) {
        requireTenantAdmin();
        OtaApproval approval = approvalRepository.findById(approvalId)
                .orElseThrow(() -> new SheException("OTA_APPROVAL_NOT_FOUND", "Approval " + approvalId + " not found", 404));
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

    private void requireTenantAdmin() {
        AuthenticatedUser user = currentUser();
        boolean isTenantAdmin = "TENANT_ADMIN".equals(user.tenantRole()) || user.isBypassCapable();
        if (!isTenantAdmin) {
            throw new SheException("RBAC_INSUFFICIENT_ROLE", "Tenant admin role required for OTA operations", 403);
        }
    }

    private AuthenticatedUser currentUser() {
        return (AuthenticatedUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal();
    }
}
