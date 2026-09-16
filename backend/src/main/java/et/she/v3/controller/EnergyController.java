package et.she.v3.controller;

import et.she.v3.energy.EnergyService;
import et.she.v3.entity.Node;
import et.she.v3.errors.SheException;
import et.she.v3.repository.NodeRepository;
import et.she.v3.service.NodeService;
import et.she.v3.util.IsoTime;
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
    private final NodeService nodeService;

    public EnergyController(EnergyService energyService, NodeRepository nodeRepository,
                            NodeService nodeService) {
        this.energyService = energyService;
        this.nodeRepository = nodeRepository;
        this.nodeService = nodeService;
    }

    /**
     * GET /api/v3/nodes/{id}/energy?from=&to=&granularity=
     */
    // @Transactional here is required, not decorative. This handler reads the node
    // straight from nodeRepository, and TenantContextAspect only applies the RLS
    // GUCs *inside* a transaction. Without one the lookup runs with no
    // app.tenant_id, RLS filters the row away, and the endpoint 404s for a node
    // that plainly exists.
    @org.springframework.transaction.annotation.Transactional(readOnly = true)
    @GetMapping("/nodes/{id}/energy")
    public ResponseEntity<Map<String, Object>> getNodeEnergy(
            @PathVariable UUID id,
            @RequestParam(required = false) String from,
            @RequestParam(required = false) String to,
            @RequestParam(required = false, defaultValue = "1h") String granularity) {

        Node node = nodeRepository.findActiveById(id)
                .orElseThrow(() -> new SheException("NODE_NOT_FOUND", "Node " + id + " not found", 404));
        nodeService.requireNodeAccess(id, "GUEST");

        Instant fromInstant = from != null ? IsoTime.parse(from) : Instant.now().minusSeconds(86400);
        Instant toInstant = to != null ? IsoTime.parse(to) : Instant.now();

        Map<String, Object> summary = energyService.getEnergySummary(node.getTenantId(), node.getId(), fromInstant, toInstant);
        return ResponseEntity.ok(Map.of("data", summary));
    }

    /**
     * GET /api/v3/nodes/{id}/energy/daily?days=7 — per-day history for the chart.
     */
    // Same reason as /nodes/{id}/energy above: the node lookup happens in this
    // handler, so it must run inside a transaction for the RLS GUCs to apply.
    @org.springframework.transaction.annotation.Transactional(readOnly = true)
    @GetMapping("/nodes/{id}/energy/daily")
    public ResponseEntity<Map<String, Object>> getNodeEnergyDaily(
            @PathVariable UUID id,
            @RequestParam(required = false, defaultValue = "7") int days) {

        Node node = nodeRepository.findActiveById(id)
                .orElseThrow(() -> new SheException("NODE_NOT_FOUND", "Node " + id + " not found", 404));
        nodeService.requireNodeAccess(id, "GUEST");

        return ResponseEntity.ok(Map.of("data",
                energyService.getDailyEnergy(node.getTenantId(), node.getId(), days)));
    }

    /**
     * GET /api/v3/homes/{homeId}/energy/summary — aggregate across all nodes in home
     */
    @GetMapping("/homes/{homeId}/energy/summary")
    public ResponseEntity<Map<String, Object>> getHomeEnergySummary(
            @PathVariable UUID homeId,
            @RequestParam(required = false) String from,
            @RequestParam(required = false) String to) {

        Instant fromInstant = from != null ? IsoTime.parse(from) : Instant.now().minusSeconds(86400);
        Instant toInstant = to != null ? IsoTime.parse(to) : Instant.now();

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
