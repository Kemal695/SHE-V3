package et.she.v3.controller;

import et.she.v3.dto.AuthResponse;
import et.she.v3.dto.LoginRequest;
import et.she.v3.dto.MeResponse;
import et.she.v3.dto.OAuthRequest;
import et.she.v3.dto.RefreshRequest;
import et.she.v3.dto.RegisterRequest;
import et.she.v3.dto.UpdateProfileRequest;
import et.she.v3.service.AuthService;
import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
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
 *   POST /api/v3/auth/claim-token — issue 10-min claim JWT for BLE provisioning
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

    /**
     * POST /api/v3/auth/oauth/google — exchange a Google ID token for a JWT pair.
     * Creates the account (and a default home) on first sign-in.
     */
    @PostMapping("/oauth/google")
    public ResponseEntity<Map<String, Object>> oauthGoogle(@Valid @RequestBody OAuthRequest req) {
        AuthResponse auth = authService.oauthLogin("google", req.id_token());
        return ResponseEntity.ok(Map.of("data", auth));
    }

    /**
     * POST /api/v3/auth/oauth/apple — exchange an Apple ID token for a JWT pair.
     */
    @PostMapping("/oauth/apple")
    public ResponseEntity<Map<String, Object>> oauthApple(@Valid @RequestBody OAuthRequest req) {
        AuthResponse auth = authService.oauthLogin("apple", req.id_token());
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

    /**
     * PATCH /api/v3/auth/me — the signed-in user updating their own profile.
     * Body: {full_name?, phone_number?, preferred_language?}. Returns the
     * refreshed /auth/me payload.
     */
    @PatchMapping("/me")
    public ResponseEntity<Map<String, Object>> updateMe(
            @RequestBody UpdateProfileRequest req) {
        MeResponse me = authService.updateMe(req);
        return ResponseEntity.ok(Map.of("data", me));
    }

    @PostMapping("/claim-token")
    public ResponseEntity<Map<String, Object>> claimToken() {
        return ResponseEntity.ok(Map.of("data", authService.claimToken()));
    }
}
