package et.she.v3.service;

import et.she.v3.dto.AuthResponse;
import et.she.v3.dto.LoginRequest;
import et.she.v3.dto.MeResponse;
import et.she.v3.dto.MfaEnrollResponse;
import et.she.v3.dto.MfaStatusResponse;
import et.she.v3.dto.RefreshRequest;
import et.she.v3.dto.RegisterRequest;
import et.she.v3.dto.UpdateProfileRequest;

import java.util.Map;

/**
 * Authentication service — login, register, refresh, logout, me.
 *
 * V3-SECURITY-MODEL §1 (JWT spec), §6 (MFA), §10.3 (rate limits).
 */
public interface AuthService {

    /**
     * POST /api/v3/auth/register
     * Creates a new B2C user in the default tenant (or the tenant resolved from email domain).
     */
    /**
     * POST /api/v3/auth/mfa/enroll — start enrolment: generate a secret and
     * return the otpauth:// URI for the QR code. Idempotent until confirmed.
     */
    MfaEnrollResponse enrollMfa();

    /**
     * POST /api/v3/auth/mfa/confirm — verify a code from the authenticator app
     * and switch MFA on. Returns the recovery codes, which are shown once.
     */
    MfaStatusResponse confirmMfa(String code);

    /**
     * POST /api/v3/auth/mfa/disable — switch MFA off. Requires the password.
     */
    MfaStatusResponse disableMfa(String password);

    /** True when the authenticated user has MFA enabled. */
    boolean mfaEnabled();

    /**
     * POST /api/v3/auth/password-reset/request
     *
     * Issues a single-use reset token for [email]. Returns the token ONLY when
     * the deployment has no mailer configured (dev), otherwise null — the token
     * is then delivered by email and must never appear in a response.
     *
     * Always behaves the same for unknown addresses: no account enumeration.
     */
    String requestPasswordReset(String email);

    /**
     * POST /api/v3/auth/password-reset/confirm
     *
     * Consumes a reset token and sets a new password. The token is single-use
     * and expires after 15 minutes.
     */
    void confirmPasswordReset(String token, String newPassword);

    AuthResponse register(RegisterRequest req);

    /**
     * POST /api/v3/auth/login
     * Verifies credentials, issues access + refresh tokens.
     * If MFA enabled and mfa_code missing → throws AUTH_MFA_REQUIRED.
     */
    AuthResponse login(LoginRequest req);

    /**
     * POST /api/v3/auth/refresh
     * Rotates refresh token (old jti blacklisted in Redis), issues new access + refresh.
     */
    AuthResponse refresh(RefreshRequest req);

    /**
     * POST /api/v3/auth/logout
     * Blacklists the refresh token's jti in Redis (TTL = access token TTL).
     */
    void logout(RefreshRequest req);

    /**
     * GET /api/v3/auth/me
     * Returns the authenticated user's profile + tenant + branding.
     */
    MeResponse me();

    /**
     * POST /api/v3/auth/claim-token
     * Issues a 10-min TTL claim JWT (type=claim) bound to the caller's
     * tenant. The mobile app fetches one right before calling
     * POST /api/v3/nodes/claim (P1-3). Verified by NodeServiceImpl.claim().
     */
    Map<String, Object> claimToken();

    /**
     * POST /api/v3/auth/oauth/{provider}
     * Verifies a Google / Apple ID token, then finds, links or creates the user
     * (with a default home) and issues the same JWT pair as password login.
     *
     * @param provider "google" or "apple" (case-insensitive)
     * @param idToken  the signed ID token from the native SDK
     */
    AuthResponse oauthLogin(String provider, String idToken);

    /**
     * PATCH /api/v3/auth/me
     * The signed-in user editing their own profile (name / phone / language).
     * Returns the refreshed /auth/me payload.
     */
    MeResponse updateMe(UpdateProfileRequest req);
}
