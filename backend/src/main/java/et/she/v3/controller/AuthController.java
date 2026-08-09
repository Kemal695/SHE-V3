package et.she.v3.controller;

import et.she.v3.dto.AuthResponse;
import et.she.v3.dto.LoginRequest;
import et.she.v3.dto.MeResponse;
import et.she.v3.dto.RefreshRequest;
import et.she.v3.dto.RegisterRequest;
import et.she.v3.service.AuthService;
import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * Auth endpoints (V3-API-SPECIFICATION §3).
 *
 *   POST /api/v3/auth/register    — create new B2C user
 *   POST /api/v3/auth/login       — exchange credentials for JWT pair
 *   POST /api/v3/auth/refresh     — rotate refresh token
 *   POST /api/v3/auth/logout      — blacklist refresh token jti
 *   GET  /api/v3/auth/me          — current user profile
 *
 * All responses use the success envelope: {"data": ..., "meta": {...}}
 */
@RestController
@RequestMapping("/api/v3/auth")
public class AuthController {

    private final AuthService authService;

    public AuthController(AuthService authService) {
        this.authService = authService;
    }

    @PostMapping("/register")
    public ResponseEntity<Map<String, Object>> register(@Valid @RequestBody RegisterRequest req) {
        AuthResponse auth = authService.register(req);
        return ResponseEntity.status(201).body(Map.of("data", auth));
    }

    @PostMapping("/login")
    public ResponseEntity<Map<String, Object>> login(@Valid @RequestBody LoginRequest req) {
        AuthResponse auth = authService.login(req);
        return ResponseEntity.ok(Map.of("data", auth));
    }

    @PostMapping("/refresh")
    public ResponseEntity<Map<String, Object>> refresh(@Valid @RequestBody RefreshRequest req) {
        AuthResponse auth = authService.refresh(req);
        return ResponseEntity.ok(Map.of("data", auth));
    }

    @PostMapping("/logout")
    public ResponseEntity<Void> logout(@Valid @RequestBody RefreshRequest req) {
        authService.logout(req);
        return ResponseEntity.noContent().build();
    }

    @GetMapping("/me")
    public ResponseEntity<Map<String, Object>> me() {
        MeResponse me = authService.me();
        return ResponseEntity.ok(Map.of("data", me));
    }
}
