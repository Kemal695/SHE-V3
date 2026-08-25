package et.she.v3.controller;

import et.she.v3.dto.OtaDtos;
import et.she.v3.ota.OtaService;
import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.Map;
import java.util.UUID;

/**
 * OTA REST endpoints.
 * V3-API-SPECIFICATION §9.
 */
@RestController
@RequestMapping("/api/v3")
public class OtaController {

    private final OtaService otaService;

    public OtaController(OtaService otaService) {
        this.otaService = otaService;
    }

    @PostMapping("/homes/{homeId}/ota/batches")
    public ResponseEntity<Map<String, Object>> createBatch(@PathVariable UUID homeId,
                                                            @Valid @RequestBody OtaDtos.CreateBatchRequest req) {
        return ResponseEntity.status(201).body(Map.of("data", otaService.createBatch(homeId, req)));
    }

    @GetMapping("/homes/{homeId}/ota/batches")
    public ResponseEntity<Map<String, Object>> listBatches(@PathVariable UUID homeId) {
        return ResponseEntity.ok(Map.of("data", otaService.listBatches(homeId)));
    }

    @GetMapping("/ota/batches/{batchId}")
    public ResponseEntity<Map<String, Object>> getBatch(@PathVariable UUID batchId) {
        return ResponseEntity.ok(Map.of("data", otaService.getBatch(batchId)));
    }

    @PostMapping("/ota/batches/{batchId}/start")
    public ResponseEntity<Map<String, Object>> startBatch(@PathVariable UUID batchId) {
        return ResponseEntity.ok(Map.of("data", otaService.startBatch(batchId)));
    }

    @PostMapping("/ota/batches/{batchId}/abort")
    public ResponseEntity<Map<String, Object>> abortBatch(@PathVariable UUID batchId) {
        return ResponseEntity.ok(Map.of("data", otaService.abortBatch(batchId)));
    }

    @PostMapping("/ota/approvals/{approvalId}/approve")
    public ResponseEntity<Map<String, Object>> approve(@PathVariable UUID approvalId) {
        return ResponseEntity.ok(Map.of("data", otaService.approveApproval(approvalId)));
    }

    @PostMapping("/ota/approvals/{approvalId}/decline")
    public ResponseEntity<Map<String, Object>> decline(@PathVariable UUID approvalId) {
        return ResponseEntity.ok(Map.of("data", otaService.declineApproval(approvalId)));
    }
}
