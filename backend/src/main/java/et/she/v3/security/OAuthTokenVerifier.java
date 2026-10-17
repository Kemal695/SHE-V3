package et.she.v3.security;

import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.jwk.source.JWKSource;
import com.nimbusds.jose.jwk.source.RemoteJWKSet;
import com.nimbusds.jose.proc.JWSAlgorithmFamilyJWSKeySelector;
import com.nimbusds.jose.proc.JWSKeySelector;
import com.nimbusds.jose.proc.SecurityContext;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.proc.ConfigurableJWTProcessor;
import com.nimbusds.jwt.proc.DefaultJWTClaimsVerifier;
import com.nimbusds.jwt.proc.DefaultJWTProcessor;
import et.she.v3.errors.SheException;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.net.URL;
import java.util.Arrays;
import java.util.List;
import java.util.Set;

/**
 * Verifies Google / Apple "Sign in" ID tokens.
 *
 * The client only ever sends the signed token — we verify the RS256 signature
 * against the provider's published JWKS, then check issuer and audience. This is
 * the security boundary: a forged or replayed-for-another-app token is rejected.
 *
 * Configuration (application.yml / env):
 *   she.oauth.google.client-ids = <web client id>[,<android client id>]
 *   she.oauth.apple.client-ids  = <bundle id or services id>
 */
@Component
public class OAuthTokenVerifier {

    private static final String GOOGLE_ISSUER = "https://accounts.google.com";
    private static final String GOOGLE_ISSUER_ALT = "accounts.google.com";
    private static final String GOOGLE_JWKS = "https://www.googleapis.com/oauth2/v3/certs";

    private static final String APPLE_ISSUER = "https://appleid.apple.com";
    private static final String APPLE_JWKS = "https://appleid.apple.com/auth/keys";

    private final List<String> googleClientIds;
    private final List<String> appleClientIds;

    public OAuthTokenVerifier(
            @Value("${she.oauth.google.client-ids:}") String googleClientIds,
            @Value("${she.oauth.apple.client-ids:}") String appleClientIds) {
        this.googleClientIds = split(googleClientIds);
        this.appleClientIds = split(appleClientIds);
    }

    private static List<String> split(String raw) {
        if (raw == null || raw.isBlank()) {
            return List.of();
        }
        return Arrays.stream(raw.split(","))
                .map(String::trim)
                .filter(s -> !s.isEmpty())
                .toList();
    }

    /** The identity extracted from a verified provider token. */
    public record OAuthUserInfo(String provider, String subject, String email, String name) {}

    public OAuthUserInfo verifyGoogle(String idToken) {
        if (googleClientIds.isEmpty()) {
            throw new SheException("OAUTH_NOT_CONFIGURED",
                    "Google sign-in is not configured on this server", 503);
        }
        JWTClaimsSet claims = verify(idToken, GOOGLE_JWKS, List.of(GOOGLE_ISSUER, GOOGLE_ISSUER_ALT),
                googleClientIds);
        return new OAuthUserInfo(
                "GOOGLE",
                claims.getSubject(),
                (String) claims.getClaim("email"),
                (String) claims.getClaim("name"));
    }

    public OAuthUserInfo verifyApple(String idToken) {
        if (appleClientIds.isEmpty()) {
            throw new SheException("OAUTH_NOT_CONFIGURED",
                    "Apple sign-in is not configured on this server", 503);
        }
        JWTClaimsSet claims = verify(idToken, APPLE_JWKS, List.of(APPLE_ISSUER), appleClientIds);
        return new OAuthUserInfo(
                "APPLE",
                claims.getSubject(),
                (String) claims.getClaim("email"),
                null);
    }

    private JWTClaimsSet verify(String idToken, String jwksUrl, List<String> issuers,
                                List<String> audiences) {
        try {
            ConfigurableJWTProcessor<SecurityContext> processor = new DefaultJWTProcessor<>();
            JWKSource<SecurityContext> keySource = new RemoteJWKSet<>(new URL(jwksUrl));
            JWSKeySelector<SecurityContext> keySelector =
                    new JWSAlgorithmFamilyJWSKeySelector<>(JWSAlgorithm.Family.RSA, keySource);
            processor.setJWSKeySelector(keySelector);

            DefaultJWTClaimsVerifier<SecurityContext> verifier =
                    new DefaultJWTClaimsVerifier<>(null, Set.of("sub", "exp", "iss", "aud"));
            verifier.setMaxClockSkew(60);
            processor.setJWTClaimsSetVerifier(verifier);

            JWTClaimsSet claims = processor.process(idToken, null);

            if (claims.getIssuer() == null || !issuers.contains(claims.getIssuer())) {
                throw new SheException("OAUTH_INVALID_TOKEN", "Unexpected token issuer", 401);
            }
            List<String> aud = claims.getAudience();
            if (aud == null || aud.stream().noneMatch(audiences::contains)) {
                throw new SheException("OAUTH_INVALID_TOKEN",
                        "Token audience does not match this app", 401);
            }
            if (claims.getSubject() == null || claims.getSubject().isBlank()) {
                throw new SheException("OAUTH_INVALID_TOKEN", "Token has no subject", 401);
            }
            return claims;
        } catch (SheException e) {
            throw e;
        } catch (Exception e) {
            // Signature/expiry/JWKS failures all land here — never leak details.
            throw new SheException("OAUTH_INVALID_TOKEN", "Could not verify the sign-in token", 401);
        }
    }
}
