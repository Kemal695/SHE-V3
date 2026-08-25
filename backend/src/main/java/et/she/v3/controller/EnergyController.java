package et.she.v3.controller;

import et.she.v3.energy.EnergyService;
import et.she.v3.entity.Node;
import et.she.v3.errors.SheException;
import et.she.v3.repository.NodeRepository;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.time.Instant;
import java.util.Map;
import java.util.UUID;

/**
 * Energy REST endpoints.
 * V3-API-SPECIFICATION §10. V3-ENERGY-MONITORING §7.
 */
@RestController
@RequestMapping("/api/v3")
public class EnergyController {

    private final EnergyService energyService;
    private final NodeRepository nodeRepository;

    public EnergyController(EnergyService energyService, NodeRepository nodeRepository) {
        this.energyService = energyService;
        this.nodeRepository = nodeRepository;
    }

    /**
     * GET /api/v3/nodes/{id}/energy?from=&to=&granularity=
     */
    @GetMapping("/nodes/{id}/energy")
    public ResponseEntity<Map<String, Object>> getNodeEnergy(
            @PathVariable UUID id,
            @RequestParam(required = false) String from,
            @RequestParam(required = false) String to,
            @RequestParam(required = false, defaultValue = "1h") String granularity) {

        Node node = nodeRepository.findActiveById(id)
                .orElseThrow(() -> new SheException("NODE_NOT_FOUND", "Node " + id + " not found", 404));

        Instant fromInstant = from != null ? Instant.parse(from) : Instant.now().minusSeconds(86400);
        Instant toInstant = to != null ? Instant.parse(to) : Instant.now();

        Map<String, Object> summary = energyService.getEnergySummary(node.getTenantId(), node.getId(), fromInstant, toInstant);
        return ResponseEntity.ok(Map.of("data", summary));
    }

    /**
     * GET /api/v3/homes/{homeId}/energy/summary — aggregate across all nodes in home
     */
    @GetMapping("/homes/{homeId}/energy/summary")
    public ResponseEntity<Map<String, Object>> getHomeEnergySummary(
            @PathVariable UUID homeId,
            @RequestParam(required = false) String from,
            @RequestParam(required = false) String to) {

        Instant fromInstant = from != null ? Instant.parse(from) : Instant.now().minusSeconds(86400);
        Instant toInstant = to != null ? Instant.parse(to) : Instant.now();

        // For Phase 1: return a per-node breakdown
        // TODO: aggregate query across all nodes in the home
        return ResponseEntity.ok(Map.of("data", Map.of(
                "homeId", homeId,
                "from", fromInstant.toString(),
                "to", toInstant.toString(),
                "note", "Per-home aggregation comes in Phase 4 (Energy dashboard)"
        )));
    }
}
