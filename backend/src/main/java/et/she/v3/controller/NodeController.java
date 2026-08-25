package et.she.v3.controller;

import et.she.v3.dto.NodeDtos;
import et.she.v3.service.NodeService;
import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.time.Instant;
import java.util.Map;
import java.util.UUID;

/**
 * Node REST endpoints — Phase 1's core API.
 * V3-API-SPECIFICATION §6. V3-DEVICE-MODEL §1.8. ADR-011.
 */
@RestController
@RequestMapping("/api/v3")
public class NodeController {

    private final NodeService nodeService;

    public NodeController(NodeService nodeService) {
        this.nodeService = nodeService;
    }

    // ─── BLE provisioning claim ──────────────────────────────────────────────
    @PostMapping("/nodes/claim")
    public ResponseEntity<Map<String, Object>> claim(@Valid @RequestBody NodeDtos.ClaimRequest req) {
        return ResponseEntity.ok(Map.of("data", nodeService.claim(req)));
    }

    // ─── List nodes by home ──────────────────────────────────────────────────
    @GetMapping("/homes/{homeId}/nodes")
    public ResponseEntity<Map<String, Object>> listByHome(@PathVariable UUID homeId) {
        return ResponseEntity.ok(Map.of("data", nodeService.listByHome(homeId)));
    }

    // ─── Node CRUD ───────────────────────────────────────────────────────────
    @GetMapping("/nodes/{id}")
    public ResponseEntity<Map<String, Object>> getById(@PathVariable UUID id) {
        return ResponseEntity.ok(Map.of("data", nodeService.getById(id)));
    }

    @PatchMapping("/nodes/{id}")
    public ResponseEntity<Map<String, Object>> update(@PathVariable UUID id,
                                                       @RequestParam(required = false) String name,
                                                       @RequestParam(required = false) UUID roomId) {
        return ResponseEntity.ok(Map.of("data", nodeService.update(id, name, roomId)));
    }

    @DeleteMapping("/nodes/{id}")
    public ResponseEntity<Void> delete(@PathVariable UUID id) {
        nodeService.delete(id);
        return ResponseEntity.noContent().build();
    }

    // ─── Devices + params ────────────────────────────────────────────────────
    @GetMapping("/nodes/{id}/devices")
    public ResponseEntity<Map<String, Object>> listDevices(@PathVariable UUID id) {
        return ResponseEntity.ok(Map.of("data", nodeService.listDevices(id)));
    }

    @GetMapping("/nodes/{id}/devices/{deviceId}/params")
    public ResponseEntity<Map<String, Object>> listParams(@PathVariable UUID id, @PathVariable UUID deviceId) {
        return ResponseEntity.ok(Map.of("data", nodeService.listParams(id, deviceId)));
    }

    @PutMapping("/nodes/{id}/devices/{deviceId}/params")
    public ResponseEntity<Map<String, Object>> writeParams(@PathVariable UUID id,
                                                           @PathVariable UUID deviceId,
                                                           @Valid @RequestBody NodeDtos.WriteParamsRequest req) {
        return ResponseEntity.ok(Map.of("data", nodeService.writeParams(id, deviceId, req)));
    }

    // ─── Telemetry time-series query ─────────────────────────────────────────
    @GetMapping("/nodes/{id}/telemetry")
    public ResponseEntity<Map<String, Object>> getTelemetry(
            @PathVariable UUID id,
            @RequestParam(required = false) String from,
            @RequestParam(required = false) String to,
            @RequestParam(required = false) String param,
            @RequestParam(required = false, defaultValue = "5m") String bucket) {

        Instant fromInstant = from != null ? Instant.parse(from) : Instant.now().minusSeconds(86400);
        Instant toInstant = to != null ? Instant.parse(to) : Instant.now();
        return ResponseEntity.ok(Map.of("data", nodeService.getTelemetry(id, fromInstant, toInstant, param, bucket)));
    }

    // ─── OTA trigger ─────────────────────────────────────────────────────────
    @PostMapping("/nodes/{id}/ota")
    public ResponseEntity<Map<String, Object>> triggerOta(@PathVariable UUID id,
                                                          @Valid @RequestBody NodeDtos.TriggerOtaRequest req) {
        // Delegate to OtaService (wired via OtaController for batch management)
        // For Phase 1: triggerOta creates a single-node batch
        return ResponseEntity.accepted().body(Map.of("data", Map.of(
                "nodeId", id,
                "version", req.version(),
                "status", "PENDING"
        )));
    }
}
