package et.she.v3.mqtt;

import javax.net.ssl.KeyManagerFactory;
import java.io.ByteArrayInputStream;
import java.io.StringReader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Convert PEM cert + PEM private key into a Java KeyStore for mTLS.
 *
 * <p>In production, the private key is HSM-backed (PKCS#11) per P1-24 — this
 * helper is for local/dev where keys are PEM files on disk.</p>
 * <p>Supports: unencrypted PKCS#8 (Ed25519/EC/RSA), SEC1 EC (BEGIN EC PRIVATE KEY),
 * and traditional SSLeay-encrypted PEM (Proc-Type: 4,ENCRYPTED) via BouncyCastle.</p>
 */
public final class PemToKeyStore {

    static {
        if (java.security.Security.getProvider("BC") == null) {
            java.security.Security.addProvider(new org.bouncycastle.jce.provider.BouncyCastleProvider());
        }
    }

    private PemToKeyStore() {}

    // Regex to extract the base64 body between PEM headers
    private static final Pattern PEM_BODY = Pattern.compile(
        "-----BEGIN ([A-Z ]+)-----(.*?)-----END \\1-----",
        Pattern.DOTALL
    );

    public static KeyStore convert(String certPemPath, String keyPemPath) throws Exception {
        byte[] certPem = Files.readAllBytes(Path.of(certPemPath));
        byte[] keyPem = Files.readAllBytes(Path.of(keyPemPath));

        CertificateFactory cf = CertificateFactory.getInstance("X.509");
        X509Certificate cert = (X509Certificate) cf.generateCertificate(new ByteArrayInputStream(certPem));

        PrivateKey privateKey = parsePrivateKey(keyPem);

        KeyStore ks = KeyStore.getInstance(KeyStore.getDefaultType());
        ks.load(null, new char[0]);
        ks.setKeyEntry("she-backend", privateKey, new char[0], new Certificate[]{ cert });
        return ks;
    }

    /**
     * Parse PEM private key with broad compatibility:
     * - BouncyCastle PEMParser handles SEC1 EC, PKCS#8, and encrypted (AES-256-CBC) PEMs.
     * - Falls back to JDK-only PKCS#8 parsing for minimal dependency.
     */
    private static PrivateKey parsePrivateKey(byte[] pemBytes) throws Exception {
        String pem = new String(pemBytes);

        // Try BouncyCastle first — handles SEC1 and encrypted PEMs
        try (org.bouncycastle.openssl.PEMParser parser = new org.bouncycastle.openssl.PEMParser(new StringReader(pem))) {
            Object obj;
            while ((obj = parser.readObject()) != null) {
                org.bouncycastle.openssl.jcajce.JcaPEMKeyConverter converter = new org.bouncycastle.openssl.jcajce.JcaPEMKeyConverter();
                // Encrypted key pair (traditional SSLeay: Proc-Type: 4,ENCRYPTED)
                if (obj instanceof org.bouncycastle.openssl.PEMEncryptedKeyPair) {
                    String password = resolveKeyPassword();
                    org.bouncycastle.openssl.PEMDecryptorProvider decProv = new org.bouncycastle.openssl.jcajce.JcePEMDecryptorProviderBuilder().build(password.toCharArray());
                    obj = ((org.bouncycastle.openssl.PEMEncryptedKeyPair) obj).decryptKeyPair(decProv);
                }
                if (obj instanceof org.bouncycastle.openssl.PEMKeyPair) {
                    return converter.getPrivateKey(((org.bouncycastle.openssl.PEMKeyPair) obj).getPrivateKeyInfo());
                }
                if (obj instanceof org.bouncycastle.asn1.pkcs.PrivateKeyInfo) {
                    return converter.getPrivateKey((org.bouncycastle.asn1.pkcs.PrivateKeyInfo) obj);
                }
                // Also handle PEMPrivateKey (some BC versions)
                if (obj instanceof java.security.PrivateKey) {
                    return (java.security.PrivateKey) obj;
                }
            }
        } catch (Exception e) {
            // Fall through to JDK fallback — will throw if still fails
            // Only suppress if BC was attempted and failed; keep original cause for debugging
            if (pem.contains("Proc-Type: 4,ENCRYPTED") && e.getMessage() != null && e.getMessage().contains("password")) {
                throw new IllegalStateException("Encrypted PEM key requires password — set STEP_CA_CLIENT_PROVISIONER_PASSWORD_FILE or decrypt key: openssl pkcs8 -topk8 -nocrypt -in <key> -out <key>.pkcs8", e);
            }
            // otherwise fall through
        }

        // JDK fallback: unencrypted PKCS#8 (Ed25519/EC/RSA)
        Matcher m = PEM_BODY.matcher(pem);
        if (!m.find()) {
            throw new IllegalArgumentException("No PEM private key block found");
        }
        // For encrypted PEM, the body includes headers like Proc-Type/DEK-Info — strip them
        String rawBody = m.group(2);
        // Remove traditional encryption headers if present
        rawBody = rawBody.replaceAll("Proc-Type:.*", "").replaceAll("DEK-Info:.*", "");
        String b64 = rawBody.replaceAll("\\s+", "");
        byte[] der;
        try {
            der = java.util.Base64.getDecoder().decode(b64);
        } catch (IllegalArgumentException iae) {
            throw new IllegalStateException("Failed to Base64-decode PEM key — likely encrypted key without BouncyCastle decryption or malformed PEM", iae);
        }

        // Try Ed25519 first (primary use case for SHE V3)
        try {
            java.security.KeyFactory kf = java.security.KeyFactory.getInstance("Ed25519");
            return kf.generatePrivate(new java.security.spec.PKCS8EncodedKeySpec(der));
        } catch (Exception ignored) {}

        // Try EC (P-256 etc.)
        try {
            java.security.KeyFactory kf = java.security.KeyFactory.getInstance("EC");
            return kf.generatePrivate(new java.security.spec.PKCS8EncodedKeySpec(der));
        } catch (Exception ignored) {}

        // Try RSA
        java.security.KeyFactory kf = java.security.KeyFactory.getInstance("RSA");
        return kf.generatePrivate(new java.security.spec.PKCS8EncodedKeySpec(der));
    }

    private static String resolveKeyPassword() {
        // The MQTT backend key is its own credential — it is NOT the step-ca provisioner
        // key, and the two passwords differ. Looking up the step-ca password first meant
        // the backend silently failed to decrypt she-backend.key (BadPaddingException) as
        // soon as the provisioner password was rotated, which killed the backend's own
        // MQTT subscriber while everything else looked healthy.
        for (String var : new String[]{"MQTT_KEY_PASSWORD", "EMQX_KEY_PASSWORD"}) {
            String direct = System.getenv(var);
            if (direct != null && !direct.isBlank()) return direct;
        }

        // Try env var pointing to password file
        String pwFile = System.getenv("MQTT_KEY_PASSWORD_FILE");
        if (pwFile == null) pwFile = System.getenv("STEP_CA_CLIENT_PROVISIONER_PASSWORD_FILE");
        if (pwFile == null) pwFile = System.getenv("STEP_CA_PROVISIONER_PASSWORD_FILE");
        if (pwFile == null) {
            // Fallback to common dev paths
            for (String candidate : new String[]{
                "D:/she-v3/infra/ca/step-ca-provisioner-password.txt",
                "/d/she-v3/infra/ca/step-ca-provisioner-password.txt",
                "infra/ca/step-ca-provisioner-password.txt",
                "../infra/ca/step-ca-provisioner-password.txt"
            }) {
                if (Files.exists(Path.of(candidate))) {
                    pwFile = candidate;
                    break;
                }
            }
        }
        if (pwFile != null) {
            try {
                String pw = Files.readString(Path.of(pwFile)).trim();
                if (!pw.isEmpty()) return pw;
            } catch (Exception ignored) {}
        }
        // Also try direct password env
        String direct = System.getenv("STEP_CA_PASSWORD");
        if (direct != null && !direct.isEmpty()) return direct;
        return "";
    }
}
