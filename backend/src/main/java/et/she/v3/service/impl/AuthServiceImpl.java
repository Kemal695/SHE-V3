package et.she.v3.service.impl;

import et.she.v3.config.SheProperties;
import et.she.v3.dto.AuthResponse;
import et.she.v3.dto.LoginRequest;
import et.she.v3.dto.MeResponse;
import et.she.v3.dto.RefreshRequest;
import et.she.v3.dto.RegisterRequest;
import et.she.v3.entity.Home;
import et.she.v3.entity.HomeMember;
import et.she.v3.entity.Tenant;
import et.she.v3.entity.User;
import et.she.v3.errors.SheException;
import et.she.v3.repository.HomeMemberRepository;
import et.she.v3.repository.HomeRepository;
import et.she.v3.repository.TenantRepository;
import et.she.v3.repository.UserRepository;
import et.she.v3.security.AuthenticatedUser;
import et.she.v3.security.JwtService;
import et.she.v3.security.TenantContextInterceptor;
import et.she.v3.audit.AuditService;
import et.she.v3.service.AuthService;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Duration;
import java.time.Instant;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.TimeUnit;

@Service
@Transactional
public class AuthServiceImpl implements AuthService {

    private static final String REDIS_JTI_BLACKLIST_PREFIX = "jwt:jti:revoked:";
    private static final String REDIS_LOGIN_ATTEMPT_PREFIX = "auth:login:attempts:";

    private final UserRepository userRepository;
    private final TenantRepository tenantRepository;
    private final HomeRepository homeRepository;
    private final HomeMemberRepository homeMemberRepository;
    private final PasswordEncoder passwordEncoder;
    private final JwtService jwtService;
    private final SheProperties props;
    private final StringRedisTemplate redis;
    private final TenantContextInterceptor tenantContextInterceptor;
    private final AuditService auditService;

    public AuthServiceImpl(UserRepository userRepository,
                           TenantRepository tenantRepository,
                           HomeRepository homeRepository,
                           HomeMemberRepository homeMemberRepository,
                           PasswordEncoder passwordEncoder,
                           JwtService jwtService,
                           SheProperties props,
                           StringRedisTemplate redis,
                           TenantContextInterceptor tenantContextInterceptor,
                           AuditService auditService) {
        this.userRepository = userRepository;
        this.tenantRepository = tenantRepository;
        this.homeRepository = homeRepository;
        this.homeMemberRepository = homeMemberRepository;
        this.passwordEncoder = passwordEncoder;
        this.jwtService = jwtService;
        this.props = props;
        this.redis = redis;
        this.tenantContextInterceptor = tenantContextInterceptor;
        this.auditService = auditService;
    }

    // =========================================================================
    // REGISTER
    // =========================================================================

    @Override
    public AuthResponse register(RegisterRequest req) {
        // The tenant id has to be resolved *before* app.tenant_id can be set, but
        // the RLS policy on `tenants` is keyed on exactly that GUC — so the lookup
        // would return zero rows. Open a platform-admin window for this one read.
        // See TenantContextInterceptor#setRlsGucsForTenantLookup.
        tenantContextInterceptor.setRlsGucsForTenantLookup();

        // B2C registration → default tenant
        Tenant tenant = tenantRepository.findBySubdomain("default")
                .orElseThrow(() -> new SheException("INTERNAL_ERROR",
                        "Default B2C tenant not seeded (run V1__tenants.sql)", 500));

        // Bootstrap RLS context — registration happens pre-auth, so we temporarily
        // set is_platform_admin='on' for this transaction. This is safe because:
        //   1. We only INSERT a single user row (no broader query)
        //   2. In `prod` profile this path is disabled (registration goes through admin)
        tenantContextInterceptor.setRlsGucsForBootstrap(tenant.getId());

        if (userRepository.existsByTenantIdAndEmailAndDeletedAtIsNull(tenant.getId(), req.email())) {
            throw new SheException("CONFLICT_EMAIL_TAKEN",
                    "Email already registered", 409);
        }

        User user = new User();
        user.setTenantId(tenant.getId());
        user.setEmail(req.email());
        user.setPasswordHash(passwordEncoder.encode(req.password()));
        user.setPlatformRole("USER");
        user.setTenantRole(null);
        user.setPhoneNumber(req.phone_number());
        user.setFullName(req.full_name());
        user.setPreferredLanguage(req.language() != null ? req.language() : "en");

        User saved = userRepository.save(user);

        // Auto-create a default home so the mobile app's dashboard has somewhere to land.
        // V3-MOBILE-APP §5 — dashboard selects homes.first; without this a fresh user
        // hits "No homes found" with no in-app way to create one.
        Home home = new Home();
        home.setTenantId(tenant.getId());
        home.setOwnerUserId(saved.getId());
        home.setName("My Home");
        home = homeRepository.save(home);

        HomeMember member = new HomeMember();
        member.setTenantId(tenant.getId());
        member.setHomeId(home.getId());
        member.setUserId(saved.getId());
        member.setRole("OWNER");
        member.setGrantedByUserId(saved.getId());
        homeMemberRepository.save(member);

        auditService.record(tenant.getId(), "USER", saved.getId(), "auth.register",
                "user", saved.getId(), Map.of("email", req.email()), null, null, null);

        return issueTokens(saved, tenant);
    }

    // =========================================================================
    // LOGIN RATE LIMITING
    // =========================================================================

    /** Current number of failed login attempts for this key (0 if unset/invalid). */
    private long failedLoginAttempts(String rateKey) {
        String raw = redis.opsForValue().get(rateKey);
        if (raw == null) {
            return 0L;
        }
        try {
            return Long.parseLong(raw.trim());
        } catch (NumberFormatException e) {
            return 0L;
        }
    }

    /**
     * Record one failed login attempt, starting the window on the first failure.
     * Called only from paths that actually rejected the credentials — see login().
     */
    private void recordFailedLogin(String rateKey) {
        Long attempts = redis.opsForValue().increment(rateKey);
        if (attempts != null && attempts == 1L) {
            redis.expire(rateKey, props.security().loginRateLimit().windowMinutes(), TimeUnit.MINUTES);
        }
    }

    // =========================================================================
    // LOGIN
    // =========================================================================

    @Override
    public AuthResponse login(LoginRequest req) {
        // Rate limit: 5 attempts per 15 min per email (V3-SECURITY-MODEL §10.3).
        // Only FAILED attempts are counted. Previously the counter was incremented on
        // every call before authenticating, so legitimate repeated logins (app restart,
        // re-opening the app, token refresh) consumed the budget and locked the user out
        // with 429 even though every attempt succeeded.
        String rateKey = REDIS_LOGIN_ATTEMPT_PREFIX + req.email();
        if (failedLoginAttempts(rateKey) >= props.security().loginRateLimit().maxAttempts()) {
            throw new SheException("RATE_LIMIT_LOGIN",
                    "Too many login attempts. Try again in "
                            + props.security().loginRateLimit().lockoutMinutes() + " minutes", 429);
        }

        // Resolve tenant — for B2C login, use the default tenant.
        // Same pre-resolution RLS window as register(): the tenant lookup has to
        // happen before app.tenant_id can be set.
        tenantContextInterceptor.setRlsGucsForTenantLookup();
        Tenant tenant = tenantRepository.findBySubdomain("default")
                .orElseThrow(() -> new SheException("INTERNAL_ERROR",
                        "Default B2C tenant not seeded", 500));

        // Bootstrap RLS context for the lookup
        tenantContextInterceptor.setRlsGucsForBootstrap(tenant.getId());

        User user = userRepository.findActiveByEmail(tenant.getId(), req.email())
                .orElseThrow(() -> new SheException("AUTH_INVALID_CREDENTIALS",
                        "Invalid email or password", 401));

        if (!passwordEncoder.matches(req.password(), user.getPasswordHash())) {
            recordFailedLogin(rateKey);
            auditService.record(tenant.getId(), "USER", user.getId(), "auth.login.failed",
                    "user", user.getId(), Map.of("email", req.email()), null, null, null);
            throw new SheException("AUTH_INVALID_CREDENTIALS",
                    "Invalid email or password", 401);
        }

        // MFA check (V3-SECURITY-MODEL §6)
        if (user.isMfaEnabled()) {
            if (req.mfa_code() == null || req.mfa_code().isBlank()) {
                throw new SheException("AUTH_MFA_REQUIRED",
                        "MFA code required", 401);
            }
            // TOTP verification stub — full implementation in Phase 5B
            // For Phase 0: accept any 6-digit code (test mode)
            if (!req.mfa_code().matches("^\\d{6}$")) {
                // A wrong code is a failed authentication attempt — count it, but a
                // missing code (AUTH_MFA_REQUIRED above) is not.
                recordFailedLogin(rateKey);
                throw new SheException("AUTH_MFA_INVALID",
                        "Invalid MFA code", 401);
            }
        }

        // Successful login — clear rate limit
        redis.delete(rateKey);

        // Update last_login_at
        user.setLastLoginAt(Instant.now());
        userRepository.save(user);

        auditService.record(tenant.getId(), "USER", user.getId(), "auth.login.success",
                "user", user.getId(), Map.of("email", req.email()), null, null, null);

        return issueTokens(user, tenant);
    }

    // =========================================================================
    // REFRESH (rotating refresh — old jti blacklisted)
    // =========================================================================

    @Override
    public AuthResponse refresh(RefreshRequest req) {
        Map<String, Object> claims = jwtService.decode(req.refresh_token());

        // Check if the refresh token's jti has been blacklisted
        String jti = (String) claims.get("jti");
        if (jti == null) {
            throw new SheException("AUTH_TOKEN_INVALID", "Missing jti claim", 401);
        }
        if (Boolean.TRUE.equals(redis.hasKey(REDIS_JTI_BLACKLIST_PREFIX + jti))) {
            throw new SheException("AUTH_TOKEN_REVOKED", "Refresh token has been revoked", 401);
        }

        // Blacklist the OLD refresh token's jti (rotating refresh — V3-SECURITY-MODEL §1.1)
        // TTL = access token TTL (when the access token would have expired anyway)
        redis.opsForValue().set(
                REDIS_JTI_BLACKLIST_PREFIX + jti,
                "revoked",
                props.jwt().accessTokenTtlSeconds(),
                TimeUnit.SECONDS
        );

        UUID userId = UUID.fromString((String) claims.get("sub"));
        UUID tenantId = UUID.fromString((String) claims.get("tenant_id"));

        // Set RLS context for the user lookup
        tenantContextInterceptor.setRlsGucsForBootstrap(tenantId);

        User user = userRepository.findActiveById(userId)
                .orElseThrow(() -> new SheException("AUTH_TOKEN_INVALID",
                        "User not found for refresh token", 401));
        Tenant tenant = tenantRepository.findById(tenantId)
                .orElseThrow(() -> new SheException("AUTH_TOKEN_INVALID",
                        "Tenant not found", 401));

        return issueTokens(user, tenant);
    }

    // =========================================================================
    // LOGOUT
    // =========================================================================

    @Override
    public void logout(RefreshRequest req) {
        Map<String, Object> claims = jwtService.decode(req.refresh_token());
        String jti = (String) claims.get("jti");
        if (jti != null) {
            // Blacklist the refresh token's jti — TTL = remaining time until natural expiry
            Long exp = ((Number) claims.get("exp")).longValue();
            long ttl = exp - System.currentTimeMillis() / 1000;
            if (ttl > 0) {
                redis.opsForValue().set(
                        REDIS_JTI_BLACKLIST_PREFIX + jti,
                        "revoked",
                        ttl,
                        TimeUnit.SECONDS
                );
            }
        }
    }

    // =========================================================================
    // ME
    // =========================================================================

    @Override
    @Transactional(readOnly = true)
    public MeResponse me() {
        var principal = SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        if (!(principal instanceof AuthenticatedUser auth)) {
            throw new SheException("AUTH_TOKEN_INVALID", "Not authenticated", 401);
        }

        // RLS is already set by TenantContextInterceptor for this request
        User user = userRepository.findActiveById(auth.userId())
                .orElseThrow(() -> new SheException("USER_NOT_FOUND",
                        "Authenticated user not found", 404));
        Tenant tenant = tenantRepository.findById(auth.tenantId())
                .orElseThrow(() -> new SheException("TENANT_NOT_FOUND",
                        "Tenant not found", 404));

        return new MeResponse(
                new MeResponse.UserView(
                        user.getId(),
                        user.getEmail(),
                        user.getPlatformRole(),
                        user.getTenantRole(),
                        user.getPhoneNumber(),
                        user.getPreferredLanguage(),
                        user.getFullName(),
                        user.isMfaEnabled(),
                        user.getCreatedAt()
                ),
                new MeResponse.TenantView(
                        tenant.getId(),
                        tenant.getName(),
                        tenant.getSubdomain(),
                        tenant.getPlan(),
                        tenant.getStatus()
                ),
                tenant.getBrandingConfig()
        );
    }

    // =========================================================================
    // CLAIM-TOKEN (BLE provisioning — P1-3)
    // =========================================================================

    @Override
    public Map<String, Object> claimToken() {
        var principal = SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        if (!(principal instanceof AuthenticatedUser auth)) {
            throw new SheException("AUTH_TOKEN_INVALID", "Not authenticated", 401);
        }
        Instant now = Instant.now();
        // 10-min TTL per V3-API-SPECIFICATION (NodeDtos.ClaimRequest).
        Instant expiry = now.plus(Duration.ofMinutes(10));

        Map<String, Object> claims = new LinkedHashMap<>();
        claims.put("sub", auth.userId().toString());
        claims.put("tenant_id", auth.tenantId().toString());
        claims.put("type", "claim");
        claims.put("jti", UUID.randomUUID().toString());
        claims.put("iat", now.getEpochSecond());
        claims.put("exp", expiry.getEpochSecond());
        claims.put("iss", props.jwt().issuer());
        claims.put("aud", props.jwt().audience());

        Map<String, Object> data = new LinkedHashMap<>();
        data.put("claim_token", jwtService.encode(claims));
        data.put("expires_in", 600);
        data.put("token_type", "Bearer");
        return data;
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    private AuthResponse issueTokens(User user, Tenant tenant) {
        Instant now = Instant.now();
        Instant accessExpiry = now.plus(props.jwt().accessTokenTtl());
        Instant refreshExpiry = now.plus(props.jwt().refreshTokenTtl(user.getPlatformRole()));

        // Access token claims (V3-SECURITY-MODEL §1.2)
        Map<String, Object> accessClaims = new LinkedHashMap<>();
        accessClaims.put("sub", user.getId().toString());
        accessClaims.put("email", user.getEmail());
        accessClaims.put("platform_role", user.getPlatformRole());
        accessClaims.put("tenant_id", user.getTenantId().toString());
        accessClaims.put("tenant_role", user.getTenantRole());
        accessClaims.put("home_roles", new HashMap<String, String>());   // Phase 1+ will populate
        accessClaims.put("jti", UUID.randomUUID().toString());
        accessClaims.put("iat", now.getEpochSecond());
        accessClaims.put("exp", accessExpiry.getEpochSecond());
        accessClaims.put("iss", props.jwt().issuer());
        accessClaims.put("aud", props.jwt().audience());
        accessClaims.put("type", "access");

        // Refresh token claims — same shape, longer TTL, different jti
        Map<String, Object> refreshClaims = new LinkedHashMap<>(accessClaims);
        refreshClaims.put("jti", UUID.randomUUID().toString());
        refreshClaims.put("exp", refreshExpiry.getEpochSecond());
        refreshClaims.put("type", "refresh");

        String accessToken = jwtService.encode(accessClaims);
        String refreshToken = jwtService.encode(refreshClaims);

        return new AuthResponse(
                accessToken,
                refreshToken,
                props.jwt().accessTokenTtlSeconds(),
                "Bearer",
                tenant.getBrandingConfig()
        );
    }
}
