package et.she.v3.controller;

import et.she.v3.dto.PagedResponse;
import et.she.v3.dto.UserDtos;
import et.she.v3.service.UserService;
import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;
import java.util.UUID;

/**
 * Users CRUD endpoint — Phase 0's required single CRUD endpoint.
 *
 * V3-API-SPECIFICATION §4 (admin endpoints).
 * Authorization: TENANT_ADMIN, PLATFORM_ADMIN, or SUPER_ADMIN role (enforced in UserServiceImpl).
 *
 * RLS-enforced via TenantContextInterceptor setting `app.tenant_id` GUC per request (P0-5).
 */
@RestController
@RequestMapping("/api/v3/users")
public class UsersController {

    private final UserService userService;

    public UsersController(UserService userService) {
        this.userService = userService;
    }

    @PostMapping
    public ResponseEntity<Map<String, Object>> create(@Valid @RequestBody UserDtos.CreateUserRequest req) {
        UserDtos.UserResponse resp = userService.create(req);
        return ResponseEntity.status(201).body(Map.of("data", resp));
    }

    @GetMapping("/{id}")
    public ResponseEntity<Map<String, Object>> getById(@PathVariable UUID id) {
        UserDtos.UserResponse resp = userService.getById(id);
        return ResponseEntity.ok(Map.of("data", resp));
    }

    @GetMapping
    public ResponseEntity<Map<String, Object>> list(
            @RequestParam(defaultValue = "0") int page,
            @RequestParam(defaultValue = "20") int size) {
        PagedResponse<UserDtos.UserResponse> resp = userService.list(page, size);
        return ResponseEntity.ok(Map.of("data", resp.data(), "meta", resp.meta()));
    }

    @PutMapping("/{id}")
    public ResponseEntity<Map<String, Object>> update(@PathVariable UUID id,
                                                       @Valid @RequestBody UserDtos.UpdateUserRequest req) {
        UserDtos.UserResponse resp = userService.update(id, req);
        return ResponseEntity.ok(Map.of("data", resp));
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<Void> delete(@PathVariable UUID id) {
        userService.softDelete(id);
        return ResponseEntity.noContent().build();
    }
}
