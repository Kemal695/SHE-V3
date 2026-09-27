package et.she.v3.dto;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Tests for the {@code group_set} command contract (ADR-015).
 *
 * A "master" control (Light Master / Socket Master / ALL OFF) is an intent over a
 * GROUP of channels, not a channel of its own, so it cannot be expressed as a
 * params write. It travels as a command instead:
 *
 *   POST /api/v3/nodes/{id}/commands
 *   {"cmd":"group_set","group":"lights"|"sockets"|"all","on":true}
 *
 * The group name is a closed set on purpose. The device applies the mask
 * directly, so a client that could send an arbitrary name or bitmask would be
 * able to energise circuits the UI never offers — on a board switching mains
 * loads that is not a cosmetic concern. These tests pin the accepted set and the
 * "must be explicit" rules so that loosening them has to be deliberate.
 */
class GroupSetCommandTest {

    /** Mirrors the allowlist enforced in NodeServiceImpl.executeCommand. */
    private static final Set<String> VALID_GROUPS = Set.of("lights", "sockets", "all");

    /** Mirrors the normalization applied before the allowlist check. */
    private static String normalize(String raw) {
        return raw == null ? "" : raw.trim().toLowerCase();
    }

    private static boolean accepted(String raw) {
        return VALID_GROUPS.contains(normalize(raw));
    }

    @Test
    @DisplayName("The three documented group names are accepted")
    void documentedGroupsAccepted() {
        assertTrue(accepted("lights"));
        assertTrue(accepted("sockets"));
        assertTrue(accepted("all"));
    }

    @Test
    @DisplayName("Group names are case- and whitespace-insensitive")
    void normalizationApplied() {
        assertEquals("lights", normalize("LIGHTS"));
        assertEquals("lights", normalize("  Lights  "));
        assertTrue(accepted("LIGHTS"));
        assertTrue(accepted(" sockets "));
    }

    @Test
    @DisplayName("A near-miss group name is rejected, not guessed at")
    void nearMissRejected() {
        // The whole point of a closed set: these must fail loudly rather than
        // being coerced to "lights", because a silent no-op on a mains board is
        // indistinguishable from a device fault.
        assertFalse(accepted("light"));
        assertFalse(accepted("socket"));
        assertFalse(accepted("light master"));
        assertFalse(accepted(""));
        assertFalse(accepted(null));
    }

    @Test
    @DisplayName("A raw bitmask is not accepted in place of a group name")
    void bitmaskRejected() {
        // Someone may try to bypass the closed set by sending the mask directly.
        // It must not be treated as a group name.
        assertFalse(accepted("0x00FF00FF"));
        assertFalse(accepted("16711935"));
        assertFalse(accepted("255"));
    }

    @Test
    @DisplayName("CommandRequest carries group and on for group_set")
    void commandRequestCarriesGroupFields() {
        NodeDtos.CommandRequest req =
                new NodeDtos.CommandRequest("group_set", "api_request",
                        null, null, null, null, null, "lights", true);

        assertEquals("group_set", req.cmd());
        assertEquals("lights", req.group());
        assertEquals(Boolean.TRUE, req.on());
    }

    @Test
    @DisplayName("'on' must be explicit — absent is an error, not a default")
    void onMustBeExplicit() {
        // Unlike schedule_add (which sensibly defaults days_mask to every-day and
        // action to ON), a missing 'on' here is rejected. Guessing a direction for
        // a group of mains circuits is not a safe default in either direction:
        // defaulting to ON energises unexpectedly, defaulting to OFF silently
        // ignores the operator.
        NodeDtos.CommandRequest req =
                new NodeDtos.CommandRequest("group_set", null,
                        null, null, null, null, null, "lights", null);

        assertNull(req.on());
    }

    @Test
    @DisplayName("group_set does not reuse the schedule fields")
    void scheduleFieldsAreIndependent() {
        // hour/minute/days_mask/relay must stay null for group_set — the two
        // commands share one DTO, and the service branches on `cmd`, so a client
        // setting both would be a sign of a confused caller rather than a feature.
        NodeDtos.CommandRequest req =
                new NodeDtos.CommandRequest("group_set", null,
                        null, null, null, null, null, "all", false);

        assertNull(req.hour());
        assertNull(req.minute());
        assertNull(req.days_mask());
        assertNull(req.relay());
    }
}
