package et.she.v3.util;

import java.time.Instant;

/**
 * Lenient ISO-8601 parsing for time-range query parameters.
 *
 * <p>The Flutter client builds {@code from}/{@code to} with {@code DateTime.toIso8601String()},
 * which omits the offset for a <em>local</em> {@code DateTime}. The app therefore sends
 * {@code 2026-09-14T14:18:16.183777} with no zone, and {@code Instant.parse()} rejects it:
 *
 * <pre>
 * java.time.format.DateTimeParseException: Text '2026-09-14T14:18:16.183777'
 *     could not be parsed at index 26
 * </pre>
 *
 * <p>That surfaced as an unhandled 500 on {@code /energy} and {@code /telemetry}, so the Energy
 * screen fell into its error branch and rendered nothing at all — the data was present in
 * TimescaleDB the whole time.
 *
 * <p>A zoneless timestamp is read as UTC: that is the ISO-8601 convention and it keeps the API
 * working for clients that omit the offset. Values carrying {@code Z} or an explicit offset are
 * honoured exactly as sent.
 */
public final class IsoTime {

    private IsoTime() {
    }

    /** Parse {@code text} as an Instant, assuming UTC when no zone or offset is present. */
    public static Instant parse(String text) {
        if (text == null) {
            return null;
        }
        String s = text.trim();
        if (s.isEmpty()) {
            return null;
        }
        if (!hasZone(s)) {
            s = s + "Z";
        }
        return Instant.parse(s);
    }

    /**
     * True when the string already carries a zone designator or a UTC offset.
     *
     * <p>An offset is only looked for <em>after</em> the 'T' separator: '-' also appears inside
     * the date itself ({@code 2026-09-14}), so scanning the whole string would misread every
     * date as offset-bearing.
     */
    private static boolean hasZone(String s) {
        if (s.endsWith("Z") || s.endsWith("z")) {
            return true;
        }
        int t = s.indexOf('T');
        if (t < 0) {
            return false;
        }
        return s.indexOf('+', t) >= 0 || s.indexOf('-', t) >= 0;
    }
}
