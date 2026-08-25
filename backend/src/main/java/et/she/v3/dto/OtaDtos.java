package et.she.v3.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.PositiveOrZero;
import jakarta.validation.constraints.Size;

import java.util.UUID;

/**
 * DTOs for the OTA domain.
 * V3-API-SPECIFICATION §9.
 */
public class OtaDtos {

    // ─── POST /api/v3/homes/{homeId}/ota/batches ─────────────────────────────
    public record CreateBatchRequest(
            @NotBlank @Size(max = 50) String firmware_version,
            @NotBlank String firmware_url,
            @NotBlank @Size(max = 64) String firmware_checksum,
            @NotBlank String signature_ed25519,
            @NotBlank @Size(max = 20) String target_sku,
            @PositiveOrZero Short rollout_percent,
            Boolean auto_approve
    ) {}

    public record BatchResponse(
            UUID id,
            String firmware_version,
            String target_sku,
            String status,
            Short rollout_percent,
            boolean auto_approve,
            String created_at,
            int approval_count
    ) {}

    // ─── POST /api/v3/ota/batches/{id}/start ─────────────────────────────────
    // ─── POST /api/v3/ota/batches/{id}/abort ─────────────────────────────────
    public record BatchActionResponse(UUID id, String status, int affected_nodes) {}

    // ─── POST /api/v3/ota/approvals/{id}/approve ─────────────────────────────
    // ─── POST /api/v3/ota/approvals/{id}/decline ─────────────────────────────
    public record ApprovalResponse(
            UUID id,
            UUID batch_id,
            UUID node_id,
            String status,
            String deployment_status,
            int progress,
            String last_error
    ) {}
}
