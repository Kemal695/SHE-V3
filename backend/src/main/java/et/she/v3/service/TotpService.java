package et.she.v3.service;

import org.springframework.stereotype.Service;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.ByteBuffer;
import java.security.SecureRandom;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;

/**
 * TOTP (RFC 6238) for two-factor authentication — V3-SECURITY-MODEL §6.
 *
 * Implemented directly on javax.crypto rather than adding a dependency:
 * HMAC-SHA1, 30-second step, 6 digits, and a ±1 window for clock drift
 * (phones are routinely a few seconds off). Base32 secrets are what every
 * authenticator app (Google Authenticator, Authy, 1Password, Aegis) expects,
 * so the user can enrol with whatever they already have.
 */
@Service
public class TotpService {

    private static final int SECRET_BYTES = 20;   // 160-bit, per RFC 4226
    private static final int CODE_DIGITS = 6;
    private static final long TIME_STEP_SECONDS = 30;
    private static final int DRIFT_WINDOWS = 1;   // accept ±30 s

    private static final String BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    private static final SecureRandom RANDOM = new SecureRandom();

    /** A fresh 160-bit secret, Base32-encoded (the format authenticator apps want). */
    public String generateSecret() {
        byte[] raw = new byte[SECRET_BYTES];
        RANDOM.nextBytes(raw);
        return base32Encode(raw);
    }

    /** otpauth:// URI for the QR code shown during enrolment. */
    public String otpAuthUri(String secret, String accountEmail, String issuer) {
        return "otpauth://totp/"
                + urlEncode(issuer) + ":" + urlEncode(accountEmail)
                + "?secret=" + secret
                + "&issuer=" + urlEncode(issuer)
                + "&algorithm=SHA1&digits=" + CODE_DIGITS
                + "&period=" + TIME_STEP_SECONDS;
    }

    /** True when [code] is a current TOTP for [secret], within the drift window. */
    public boolean verifyCode(String secret, String code) {
        if (secret == null || code == null) return false;
        String normalised = code.replace(" ", "").trim();
        if (!normalised.matches("\\d{" + CODE_DIGITS + "}")) return false;

        long counter = Instant.now().getEpochSecond() / TIME_STEP_SECONDS;
        for (int i = -DRIFT_WINDOWS; i <= DRIFT_WINDOWS; i++) {
            if (constantTimeEquals(generateCode(secret, counter + i), normalised)) {
                return true;
            }
        }
        return false;
    }

    /**
     * Single-use recovery codes, in case the user loses their phone.
     *
     * Plain 8-character codes rather than 10-digit numbers: they are typed once
     * and stored hashed, and the alphabet avoids look-alike characters.
     */
    public List<String> generateRecoveryCodes(int count) {
        List<String> codes = new ArrayList<>(count);
        for (int i = 0; i < count; i++) {
            codes.add(randomCode());
        }
        return codes;
    }

    /** Base64 of the SHA-256 of a code, for at-rest storage. */
    public String hashRecoveryCode(String code) {
        try {
            byte[] digest = java.security.MessageDigest.getInstance("SHA-256")
                    .digest(code.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            return Base64.getEncoder().encodeToString(digest);
        } catch (Exception e) {
            throw new IllegalStateException("SHA-256 unavailable", e);
        }
    }

    // -------------------------------------------------------------------------

    private String generateCode(String base32Secret, long counter) {
        try {
            byte[] key = base32Decode(base32Secret);
            byte[] data = ByteBuffer.allocate(8).putLong(counter).array();

            Mac mac = Mac.getInstance("HmacSHA1");
            mac.init(new SecretKeySpec(key, "HmacSHA1"));
            byte[] hash = mac.doFinal(data);

            // Dynamic truncation (RFC 4226 §5.4).
            int offset = hash[hash.length - 1] & 0x0F;
            int binary = ((hash[offset] & 0x7F) << 24)
                    | ((hash[offset + 1] & 0xFF) << 16)
                    | ((hash[offset + 2] & 0xFF) << 8)
                    | (hash[offset + 3] & 0xFF);

            int code = binary % (int) Math.pow(10, CODE_DIGITS);
            return String.format("%0" + CODE_DIGITS + "d", code);
        } catch (Exception e) {
            throw new IllegalStateException("TOTP generation failed", e);
        }
    }

    private String randomCode() {
        String alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
        StringBuilder sb = new StringBuilder(10);
        for (int i = 0; i < 10; i++) {
            sb.append(alphabet.charAt(RANDOM.nextInt(alphabet.length())));
        }
        return sb.toString();
    }

    private boolean constantTimeEquals(String a, String b) {
        if (a.length() != b.length()) return false;
        int diff = 0;
        for (int i = 0; i < a.length(); i++) {
            diff |= a.charAt(i) ^ b.charAt(i);
        }
        return diff == 0;
    }

    private static String urlEncode(String s) {
        try {
            return java.net.URLEncoder.encode(s, java.nio.charset.StandardCharsets.UTF_8);
        } catch (Exception e) {
            return s;
        }
    }

    // ---- Base32 -------------------------------------------------------------

    private static String base32Encode(byte[] data) {
        StringBuilder out = new StringBuilder();
        int buffer = 0;
        int bitsLeft = 0;
        for (byte b : data) {
            buffer = (buffer << 8) | (b & 0xFF);
            bitsLeft += 8;
            while (bitsLeft >= 5) {
                out.append(BASE32_ALPHABET.charAt((buffer >> (bitsLeft - 5)) & 0x1F));
                bitsLeft -= 5;
            }
        }
        if (bitsLeft > 0) {
            out.append(BASE32_ALPHABET.charAt((buffer << (5 - bitsLeft)) & 0x1F));
        }
        return out.toString();
    }

    private static byte[] base32Decode(String base32) {
        String clean = base32.replace("=", "").replace(" ", "").toUpperCase();
        java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
        int buffer = 0;
        int bitsLeft = 0;
        for (int i = 0; i < clean.length(); i++) {
            int value = BASE32_ALPHABET.indexOf(clean.charAt(i));
            if (value < 0) throw new IllegalArgumentException("bad base32 char");
            buffer = (buffer << 5) | value;
            bitsLeft += 5;
            if (bitsLeft >= 8) {
                out.write((buffer >> (bitsLeft - 8)) & 0xFF);
                bitsLeft -= 8;
            }
        }
        return out.toByteArray();
    }
}
