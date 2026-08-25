package et.she.v3.controller;

import et.she.v3.dto.HomeDtos;
import et.she.v3.service.HomeService;
import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.Map;
import java.util.UUID;

/**
 * Home + Room + Member REST endpoints.
 * V3-API-SPECIFICATION §4-5.
 */
@RestController
@RequestMapping("/api/v3")
public class HomeController {

    private final HomeService homeService;

    public HomeController(HomeService homeService) {
        this.homeService = homeService;
    }

    // ─── Homes ───────────────────────────────────────────────────────────────
    @PostMapping("/homes")
    public ResponseEntity<Map<String, Object>> create(@Valid @RequestBody HomeDtos.CreateHomeRequest req) {
        return ResponseEntity.status(201).body(Map.of("data", homeService.create(req)));
    }

    @GetMapping("/homes")
    public ResponseEntity<Map<String, Object>> list() {
        return ResponseEntity.ok(Map.of("data", homeService.list()));
    }

    @GetMapping("/homes/{homeId}")
    public ResponseEntity<Map<String, Object>> getById(@PathVariable UUID homeId) {
        return ResponseEntity.ok(Map.of("data", homeService.getById(homeId)));
    }

    @PatchMapping("/homes/{homeId}")
    public ResponseEntity<Map<String, Object>> update(@PathVariable UUID homeId,
                                                       @Valid @RequestBody HomeDtos.UpdateHomeRequest req) {
        return ResponseEntity.ok(Map.of("data", homeService.update(homeId, req)));
    }

    @DeleteMapping("/homes/{homeId}")
    public ResponseEntity<Void> delete(@PathVariable UUID homeId) {
        homeService.delete(homeId);
        return ResponseEntity.noContent().build();
    }

    // ─── Rooms ───────────────────────────────────────────────────────────────
    @PostMapping("/homes/{homeId}/rooms")
    public ResponseEntity<Map<String, Object>> createRoom(@PathVariable UUID homeId,
                                                           @Valid @RequestBody HomeDtos.CreateRoomRequest req) {
        return ResponseEntity.status(201).body(Map.of("data", homeService.createRoom(homeId, req)));
    }

    @GetMapping("/homes/{homeId}/rooms")
    public ResponseEntity<Map<String, Object>> listRooms(@PathVariable UUID homeId) {
        return ResponseEntity.ok(Map.of("data", homeService.listRooms(homeId)));
    }

    @PatchMapping("/homes/{homeId}/rooms/{roomId}")
    public ResponseEntity<Map<String, Object>> updateRoom(@PathVariable UUID homeId,
                                                           @PathVariable UUID roomId,
                                                           @Valid @RequestBody HomeDtos.UpdateRoomRequest req) {
        return ResponseEntity.ok(Map.of("data", homeService.updateRoom(homeId, roomId, req)));
    }

    @DeleteMapping("/homes/{homeId}/rooms/{roomId}")
    public ResponseEntity<Void> deleteRoom(@PathVariable UUID homeId, @PathVariable UUID roomId) {
        homeService.deleteRoom(homeId, roomId);
        return ResponseEntity.noContent().build();
    }

    // ─── Members ─────────────────────────────────────────────────────────────
    @GetMapping("/homes/{homeId}/members")
    public ResponseEntity<Map<String, Object>> listMembers(@PathVariable UUID homeId) {
        return ResponseEntity.ok(Map.of("data", homeService.listMembers(homeId)));
    }

    @PostMapping("/homes/{homeId}/members")
    public ResponseEntity<Map<String, Object>> addMember(@PathVariable UUID homeId,
                                                          @Valid @RequestBody HomeDtos.AddMemberRequest req) {
        return ResponseEntity.status(201).body(Map.of("data", homeService.addMember(homeId, req)));
    }

    @PatchMapping("/homes/{homeId}/members/{userId}")
    public ResponseEntity<Map<String, Object>> updateMember(@PathVariable UUID homeId,
                                                            @PathVariable UUID userId,
                                                            @Valid @RequestBody HomeDtos.UpdateMemberRequest req) {
        return ResponseEntity.ok(Map.of("data", homeService.updateMember(homeId, userId, req)));
    }

    @DeleteMapping("/homes/{homeId}/members/{userId}")
    public ResponseEntity<Void> removeMember(@PathVariable UUID homeId, @PathVariable UUID userId) {
        homeService.removeMember(homeId, userId);
        return ResponseEntity.noContent().build();
    }
}
