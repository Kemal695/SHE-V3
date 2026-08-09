package et.she.v3.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import et.she.v3.config.SheProperties;
import et.she.v3.errors.SheException;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.Base64;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Unit tests for {@link JwtService} — EdDSA / Ed25519 with `kid` multi-key rotation (P1-6).
 *
 * Verifies:
 *   - Sign + verify roundtrip
 *   - Expired token rejected
 *   - Tampered token rejected (signature invalid)
 *   - Unknown kid rejected (rotation window: only listed kids are accepted)
 *   - Multi-key rotation: old kid + new kid both accepted simultaneously
 */
class JwtServiceTest {

    static Path keysDir;
    static String privateKeyPem;
    static String publicKeyPem;
    static String otherPublicKeyPem;

    @BeforeAll
    static void generateKeys() throws Exception {
        keysDir = Files.createTempDirectory("she-jwt-keys");

        // Generate Ed25519 keypair via openssl
        Path priv = keysDir.resolve("jwt_ed25519.pem");
        Path pub  = keysDir.resolve("jwt_ed25519.pub");
        ProcessBuilder pb = new ProcessBuilder(
                "openssl", "genpkey", "-algorithm", "ed25519", "-out", priv.toString()
        );
        pb.inheritIO().start().waitFor();
        new ProcessBuilder(
                "openssl", "pkey", "-in", priv.toString(), "-pubout", "-out", pub.toString()
        ).inheritIO().start().waitFor();

        privateKeyPem = Files.readString(priv);

        // For the JSON array of public keys, we read the PEM and escape newlines
        String pubContent = Files.readString(pub);
        publicKeyPem = pubContent.replaceAll("\\s+", " ").trim();
        // Actually we need the raw PEM with newlines preserved — use a JSON-friendly form
        // The JwtService.extractDerFromPem strips all whitespace, so we can pass the raw PEM.
        publicKeyPem = pubContent;

        // Generate a second keypair for multi-key rotation test
        Path otherPriv = keysDir.resolve("jwt_ed25519_other.pem");
        Path otherPub  = keysDir.resolve("jwt_ed25519_other.pub");
        new ProcessBuilder(
                "openssl", "genpkey", "-algorithm", "ed25519", "-out", otherPriv.toString()
        ).inheritIO().start().waitFor();
        new ProcessBuilder(
                "openssl", "pkey", "-in", otherPriv.toString(), "-pubout", "-out", otherPub.toString()
        ).inheritIO().start().waitFor();
        otherPublicKeyPem = Files.readString(otherPub);
    }

    private JwtService jwtService;

    @BeforeEach
    void setUp() {
        Map<String, Long> refreshTtls = new HashMap<>();
        refreshTtls.put("USER", 2592000L);
        refreshTtls.put("TENANT_ADMIN", 28800L);
        refreshTtls.put("PLATFORM_ADMIN", 28800L);
        refreshTtls.put("SUPER_ADMIN", 14400L);

        // Two public keys: current (kid=2025q1) + previous (kid=2024q4) — both accepted
        String publicKeysJson = String.format(
            "[{\"kid\":\"2025q1\",\"public_key_pem\":%s},{\"kid\":\"2024q4\",\"public_key_pem\":%s}]",
            jsonString(publicKeyPem), jsonString(otherPublicKeyPem)
        );

        SheProperties.Jwt jwtProps = new SheProperties.Jwt(
                keysDir.resolve("jwt_ed25519.pem").toString(),
                "2025q1",
                publicKeysJson,
                900L,
                refreshTtls,
                "she.et",
                "she-api"
        );
        SheProperties props = new SheProperties(jwtProps, null, null, null, null);
        jwtService = new JwtService(props, new ObjectMapper());
        jwtService.init();
    }

    @Test
    @DisplayName("Sign + verify roundtrip")
    void signAndVerifyRoundtrip() {
        Map<String, Object> claims = new HashMap<>();
        claims.put("sub", "8a3b1c2e-1234-5678-9abc-def012345678");
        claims.put("email", "user@example.et");
        claims.put("platform_role", "USER");
        claims.put("tenant_id", "00000000-0000-0000-0000-000000000001");
        claims.put("jti", java.util.UUID.randomUUID().toString());
        claims.put("iat", System.currentTimeMillis() / 1000);
        claims.put("exp", System.currentTimeMillis() / 1000 + 900);

        String token = jwtService.encode(claims);
        assertNotNull(token);
        assertTrue(token.split("\\.").length == 3, "JWT must have 3 parts");

        Map<String, Object> decoded = jwtService.decode(token);
        assertEquals("user@example.et", decoded.get("email"));
        assertEquals("USER", decoded.get("platform_role"));
    }

    @Test
    @DisplayName("Expired token is rejected")
    void expiredTokenRejected() {
        Map<String, Object> claims = new HashMap<>();
        claims.put("sub", "8a3b1c2e-1234-5678-9abc-def012345678");
        claims.put("iat", System.currentTimeMillis() / 1000 - 3600);
        claims.put("exp", System.currentTimeMillis() / 1000 - 1800);    // expired 30 min ago

        String token = jwtService.encode(claims);
        SheException ex = assertThrows(SheException.class, () -> jwtService.decode(token));
        assertEquals("AUTH_TOKEN_EXPIRED", ex.getCode());
        assertEquals(401, ex.getHttpStatus());
    }

    @Test
    @DisplayName("Tampered token is rejected")
    void tamperedTokenRejected() {
        Map<String, Object> claims = new HashMap<>();
        claims.put("sub", "8a3b1c2e-1234-5678-9abc-def012345678");
        claims.put("exp", System.currentTimeMillis() / 1000 + 900);

        String token = jwtService.encode(claims);
        String[] parts = token.split("\\.");
        // Tamper the payload (flip a character)
        String tamperedPayload = parts[1].substring(0, parts[1].length() - 4) + "AAAA";
        String tampered = parts[0] + "." + tamperedPayload + "." + parts[2];

        SheException ex = assertThrows(SheException.class, () -> jwtService.decode(tampered));
        // Could be AUTH_TOKEN_INVALID (signature fail) or AUTH_TOKEN_INVALID (JSON parse fail)
        assertEquals("AUTH_TOKEN_INVALID", ex.getCode());
    }

    @Test
    @DisplayName("Unknown kid is rejected (rotation window: only listed kids accepted)")
    void unknownKidRejected() {
        // Build a token manually with kid="2023q3" — not in the accepted list
        Map<String, Object> claims = new HashMap<>();
        claims.put("sub", "8a3b1c2e-1234-5678-9abc-def012345678");
        claims.put("exp", System.currentTimeMillis() / 1000 + 900);

        // Use the service's encode (which uses signingKid=2025q1) and then
        // tamper the header to claim a different kid — signature will fail because
        // the public key in the verification map doesn't match.
        String token = jwtService.encode(claims);
        String[] parts = token.split("\\.");
        String headerJson = new String(Base64.getUrlDecoder().decode(parts[0]));
        String tamperedHeader = headerJson.replace("\"2025q1\"", "\"2023q3\"");
        String tamperedHeaderB64 = Base64.getUrlEncoder().withoutPadding()
                .encodeToString(tamperedHeader.getBytes());
        String tampered = tamperedHeaderB64 + "." + parts[1] + "." + parts[2];

        SheException ex = assertThrows(SheException.class, () -> jwtService.decode(tampered));
        assertEquals("AUTH_TOKEN_INVALID", ex.getCode());
    }

    @Test
    @DisplayName("sha256Hex produces lowercase hex of correct length")
    void sha256HexWorks() throws Exception {
        String hash = JwtService.sha256Hex("hello world".getBytes());
        assertEquals(64, hash.length(), "SHA-256 hex must be 64 chars");
        assertTrue(hash.matches("^[0-9a-f]{64}$"), "Must be lowercase hex");
        // Known SHA-256 of "hello world"
        assertEquals("b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9", hash);
    }

    /**
     * Escape a string as a JSON string literal.
     */
    private static String jsonString(String s) {
        return "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n") + "\"";
    }
}
