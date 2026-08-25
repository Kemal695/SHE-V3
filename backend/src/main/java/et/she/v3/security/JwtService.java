package et.she.v3.security;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import et.she.v3.config.SheProperties;
import et.she.v3.errors.SheException;
import jakarta.annotation.PostConstruct;
import org.springframework.stereotype.Service;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyFactory;
import java.security.MessageDigest;
import java.security.PrivateKey;
import java.security.PublicKey;
import java.security.Signature;
import java.security.spec.PKCS8EncodedKeySpec;
import java.security.spec.X509EncodedKeySpec;
import java.util.Base64;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * JWT encoder/decoder using EdDSA (Ed25519) with `kid` header for multi-key rotation.
 *
 * Canonical references:
 *   - V3-SECURITY-MODEL.md §1.1 (JWT spec — EdDSA, 15-min access, 30-day refresh for USER)
 *   - V3-CONFIGURATION.md §2.1.5 (env vars: JWT_SIGNING_PRIVATE_KEY_PATH, JWT_SIGNING_PUBLIC_KEYS, JWT_SIGNING_KEY_ID)
 *   - P1-6: EdDSA (Ed25519) with kid header — replaces legacy HS256/JWT_SECRET
 *   - P2-1: all HS256 references corrected to EdDSA/Ed25519
 *
 * Multi-key rotation (P1-6): Spring Boot accepts a SET of Ed25519 public keys
 * (each identified by kid). Old tokens continue to validate against previous
 * kid until they expire. No forced re-login during rotation.
 *
 * Implementation uses JDK 15+ built-in EdDSA (java.security.*) — no BouncyCastle needed.
 */
@Service
public class JwtService {

    private static final Base64.Encoder B64_URL = Base64.getUrlEncoder().withoutPadding();
    private static final Base64.Decoder B64_URL_DEC = Base64.getUrlDecoder();

    private final SheProperties props;
    private final ObjectMapper objectMapper;

    /** Currently-signing private key (kid → key). */
    private PrivateKey signingPrivateKey;
    private String signingKid;

    /** All accepted public keys (kid → key) — rotation window per P1-6. */
    private final Map<String, PublicKey> verificationKeys = new HashMap<>();

    public JwtService(SheProperties props, ObjectMapper objectMapper) {
        this.props = props;
        this.objectMapper = objectMapper;
    }

    @PostConstruct
    void init() {
        try {
            loadSigningKey();
            loadVerificationKeys();
        } catch (Exception e) {
            throw new IllegalStateException("Failed to initialize JWT keys: " + e.getMessage(), e);
        }
    }

    // =========================================================================
    // ENCODE
    // =========================================================================

    /**
     * Issue a signed JWT. Claims are populated by the caller.
     */
    public String encode(Map<String, Object> claims) {
        try {
            // Header: {"alg":"EdDSA","typ":"JWT","kid":"<signingKid>"}
            Map<String, Object> header = new LinkedHashMap<>();
            header.put("alg", "EdDSA");
            header.put("typ", "JWT");
            header.put("kid", signingKid);

            String headerJson  = objectMapper.writeValueAsString(header);
            String payloadJson = objectMapper.writeValueAsString(claims);

            String headerB64  = B64_URL.encodeToString(headerJson.getBytes(StandardCharsets.UTF_8));
            String payloadB64 = B64_URL.encodeToString(payloadJson.getBytes(StandardCharsets.UTF_8));

            String signingInput = headerB64 + "." + payloadB64;
            byte[] sig = sign(signingInput.getBytes(StandardCharsets.UTF_8));

            String sigB64 = B64_URL.encodeToString(sig);
            return signingInput + "." + sigB64;
        } catch (Exception e) {
            throw new SheException("INTERNAL_ERROR", "JWT encode failed: " + e.getMessage(), 500, e);
        }
    }

    private byte[] sign(byte[] message) throws Exception {
        Signature signer = Signature.getInstance("Ed25519");
        signer.initSign(signingPrivateKey);
        signer.update(message);
        return signer.sign();
    }

    // =========================================================================
    // DECODE + VERIFY
    // =========================================================================

    /**
     * Verify signature + decode claims. Throws SheException on invalid/expired token.
     */
    public Map<String, Object> decode(String token) {
        String[] parts = token.split("\\.");
        if (parts.length != 3) {
            throw new SheException("AUTH_TOKEN_INVALID", "Malformed JWT (expected 3 parts)", 401);
        }
        String headerB64  = parts[0];
        String payloadB64 = parts[1];
        String sigB64     = parts[2];

        Map<String, Object> header = parseJson(B64_URL_DEC.decode(headerB64));
        String alg = (String) header.get("alg");
        if (!"EdDSA".equals(alg)) {
            throw new SheException("AUTH_TOKEN_INVALID", "Unsupported alg: " + alg + " (expected EdDSA)", 401);
        }
        String kid = (String) header.get("kid");
        if (kid == null) {
            throw new SheException("AUTH_TOKEN_INVALID", "Missing kid header", 401);
        }
        PublicKey publicKey = verificationKeys.get(kid);
        if (publicKey == null) {
            throw new SheException("AUTH_TOKEN_INVALID", "Unknown kid: " + kid, 401);
        }

        byte[] sig = B64_URL_DEC.decode(sigB64);
        byte[] signingInput = (headerB64 + "." + payloadB64).getBytes(StandardCharsets.UTF_8);

        if (!verify(publicKey, signingInput, sig)) {
            throw new SheException("AUTH_TOKEN_INVALID", "Signature verification failed", 401);
        }

        Map<String, Object> claims = parseJson(B64_URL_DEC.decode(payloadB64));

        // Validate exp (null-safe — avoid NPE if claim is missing)
        Object expObj = claims.get("exp");
        if (expObj == null) {
            throw new SheException("AUTH_TOKEN_INVALID", "Missing exp claim", 401);
        }
        long exp;
        try {
            exp = ((Number) expObj).longValue();
        } catch (ClassCastException e) {
            throw new SheException("AUTH_TOKEN_INVALID", "Invalid exp claim type", 401);
        }
        if (exp < System.currentTimeMillis() / 1000) {
            throw new SheException("AUTH_TOKEN_EXPIRED", "Token expired", 401);
        }

        // Validate iss + aud (V3-SECURITY-MODEL §1.2)
        String iss = (String) claims.get("iss");
        String aud = (String) claims.get("aud");
        if (iss == null || !iss.equals(props.jwt().issuer())) {
            throw new SheException("AUTH_TOKEN_INVALID", "Invalid iss claim", 401);
        }
        if (aud == null || !aud.equals(props.jwt().audience())) {
            throw new SheException("AUTH_TOKEN_INVALID", "Invalid aud claim", 401);
        }

        return claims;
    }

    private boolean verify(PublicKey publicKey, byte[] message, byte[] signature) {
        try {
            Signature verifier = Signature.getInstance("Ed25519");
            verifier.initVerify(publicKey);
            verifier.update(message);
            return verifier.verify(signature);
        } catch (Exception e) {
            return false;
        }
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> parseJson(byte[] json) {
        try {
            return objectMapper.readValue(json, new TypeReference<Map<String, Object>>() {});
        } catch (Exception e) {
            throw new SheException("AUTH_TOKEN_INVALID", "JSON parse failed: " + e.getMessage(), 401);
        }
    }

    // =========================================================================
    // KEY LOADING (PKCS#8 private + X.509 public, JDK EdDSA)
    // =========================================================================

    private void loadSigningKey() throws Exception {
        String path = props.jwt().signingPrivateKeyPath();
        if (path == null || path.isBlank()) {
            throw new IllegalStateException("JWT_SIGNING_PRIVATE_KEY_PATH is not set");
        }
        byte[] pemBytes = Files.readAllBytes(Path.of(path));
        byte[] derBytes = extractDerFromPem(pemBytes, "PRIVATE KEY");
        PKCS8EncodedKeySpec spec = new PKCS8EncodedKeySpec(derBytes);
        KeyFactory kf = KeyFactory.getInstance("Ed25519");
        signingPrivateKey = kf.generatePrivate(spec);

        signingKid = props.jwt().signingKeyId();
        if (signingKid == null || signingKid.isBlank()) {
            throw new IllegalStateException("JWT_SIGNING_KEY_ID is not set");
        }
    }

    @SuppressWarnings("unchecked")
    private void loadVerificationKeys() throws Exception {
        String json = props.jwt().signingPublicKeysJson();
        if (json == null || json.isBlank()) {
            throw new IllegalStateException("JWT_SIGNING_PUBLIC_KEYS is not set");
        }
        List<Map<String, String>> entries = objectMapper.readValue(json, new TypeReference<>() {});
        KeyFactory kf = KeyFactory.getInstance("Ed25519");
        for (Map<String, String> entry : entries) {
            String kid = entry.get("kid");
            String pem = entry.get("public_key_pem");
            if (kid == null || pem == null) {
                throw new IllegalStateException("JWT_SIGNING_PUBLIC_KEYS entries must have kid + public_key_pem");
            }
            byte[] pemBytes = pem.getBytes(StandardCharsets.UTF_8);
            byte[] derBytes = extractDerFromPem(pemBytes, "PUBLIC KEY");
            X509EncodedKeySpec spec = new X509EncodedKeySpec(derBytes);
            verificationKeys.put(kid, kf.generatePublic(spec));
        }
        if (!verificationKeys.containsKey(signingKid)) {
            throw new IllegalStateException("JWT_SIGNING_KEY_ID=" + signingKid +
                    " not present in JWT_SIGNING_PUBLIC_KEYS");
        }
    }

    /**
     * Naive PEM parser — strips header/footer + base64-decodes the body.
     */
    private byte[] extractDerFromPem(byte[] pemBytes, String keyType) {
        String pem = new String(pemBytes, StandardCharsets.UTF_8);
        String begin = "-----BEGIN " + keyType + "-----";
        String end   = "-----END "   + keyType + "-----";
        int beginIdx = pem.indexOf(begin);
        int endIdx   = pem.indexOf(end);
        if (beginIdx < 0 || endIdx < 0) {
            throw new IllegalStateException("PEM does not contain " + begin + " / " + end);
        }
        String b64 = pem.substring(beginIdx + begin.length(), endIdx).replaceAll("\\s+", "");
        return Base64.getDecoder().decode(b64);
    }

    /**
     * SHA-256 fingerprint (lowercase hex) — used for cert fingerprint lookups.
     */
    public static String sha256Hex(byte[] data) throws Exception {
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        byte[] hash = md.digest(data);
        StringBuilder sb = new StringBuilder();
        for (byte b : hash) sb.append(String.format("%02x", b));
        return sb.toString();
    }
}
