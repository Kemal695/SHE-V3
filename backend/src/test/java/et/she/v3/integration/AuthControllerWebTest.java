package et.she.v3.integration;

import com.fasterxml.jackson.databind.ObjectMapper;
import et.she.v3.controller.AuthController;
import et.she.v3.dto.AuthResponse;
import et.she.v3.dto.LoginRequest;
import et.she.v3.dto.RegisterRequest;
import et.she.v3.errors.GlobalExceptionHandler;
import et.she.v3.service.AuthService;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

import java.util.Map;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/**
 * Web-layer integration test for {@link AuthController}.
 *
 * Uses @WebMvcTest (loads only the web layer + Jackson, NOT the full Spring context).
 * AuthService is mocked — no DB/Redis/JWT keys required.
 *
 * Phase 0 acceptance: verifies endpoint shape, validation, error envelope format.
 */
@WebMvcTest(controllers = AuthController.class)
@AutoConfigureMockMvc(addFilters = false)
@Import(GlobalExceptionHandler.class)
class AuthControllerWebTest {

    @Autowired MockMvc mockMvc;
    @Autowired ObjectMapper objectMapper;

    @MockBean AuthService authService;

    @Test
    @DisplayName("POST /api/v3/auth/register — weak password returns 400 VALIDATION_FAILED")
    void registerWeakPassword() throws Exception {
        mockMvc.perform(post("/api/v3/auth/register")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                            {"email":"user@example.et","password":"short"}
                            """))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error.code").value("VALIDATION_FAILED"))
                .andExpect(jsonPath("$.error.http_status").value(400))
                .andExpect(jsonPath("$.error.request_id").exists());
    }

    @Test
    @DisplayName("POST /api/v3/auth/register — invalid email returns 400 VALIDATION_FAILED")
    void registerInvalidEmail() throws Exception {
        mockMvc.perform(post("/api/v3/auth/register")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                            {"email":"not-an-email","password":"StrongPass!1234"}
                            """))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error.code").value("VALIDATION_FAILED"));
    }

    @Test
    @DisplayName("POST /api/v3/auth/register — invalid phone returns 400 VALIDATION_FAILED")
    void registerInvalidPhone() throws Exception {
        mockMvc.perform(post("/api/v3/auth/register")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                            {"email":"user@example.et","password":"StrongPass!1234","phone_number":"12345"}
                            """))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error.code").value("VALIDATION_FAILED"));
    }

    @Test
    @DisplayName("POST /api/v3/auth/register — valid request returns 201 with success envelope")
    void registerValid() throws Exception {
        AuthResponse fakeResp = new AuthResponse(
                "fake-access-token",
                "fake-refresh-token",
                900L,
                "Bearer",
                Map.of("primary_color", "#0B1D37", "accent_color", "#56B4FA")
        );
        when(authService.register(any(RegisterRequest.class))).thenReturn(fakeResp);

        mockMvc.perform(post("/api/v3/auth/register")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                            {"email":"user@example.et","password":"StrongPass!1234","full_name":"Test User"}
                            """))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.data.access_token").exists())
                .andExpect(jsonPath("$.data.token_type").value("Bearer"))
                .andExpect(jsonPath("$.data.expires_in").value(900))
                .andExpect(jsonPath("$.data.tenant_branding.primary_color").value("#0B1D37"));
    }

    @Test
    @DisplayName("POST /api/v3/auth/login — valid request returns 200 with tokens")
    void loginValid() throws Exception {
        AuthResponse fakeResp = new AuthResponse(
                "fake-access-token", "fake-refresh-token", 900L, "Bearer", Map.of()
        );
        when(authService.login(any(LoginRequest.class))).thenReturn(fakeResp);

        mockMvc.perform(post("/api/v3/auth/login")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                            {"email":"user@example.et","password":"StrongPass!1234"}
                            """))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.data.access_token").exists());
    }

    @Test
    @DisplayName("POST /api/v3/auth/login — missing password returns 400")
    void loginMissingPassword() throws Exception {
        mockMvc.perform(post("/api/v3/auth/login")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                            {"email":"user@example.et"}
                            """))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error.code").value("VALIDATION_FAILED"));
    }
}
