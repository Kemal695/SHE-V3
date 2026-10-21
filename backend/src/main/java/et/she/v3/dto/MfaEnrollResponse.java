package et.she.v3.dto;

/**
 * Response to starting MFA enrolment.
 *
 * @param secret      Base32 secret to type in manually if the QR will not scan
 * @param otpAuthUri  otpauth:// URI to render as a QR code
 * @param issuer      Name shown in the authenticator app
 */
public record MfaEnrollResponse(
        String secret,
        String otpAuthUri,
        String issuer
) {
}
