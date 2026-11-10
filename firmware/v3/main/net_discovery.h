/* =============================================================================
 * SHE V3 firmware — net_discovery.h
 * =============================================================================
 * Locate the SHE backend on the local subnet.
 *
 * WHY THIS EXISTS
 * ---------------
 * Provisioning only ever wrote Wi-Fi credentials. The broker and API base live
 * in the `fctry` partition, written once at manufacturing, and nothing updated
 * them afterwards. So when the router changed, the board joined the new network
 * and then dialled a host that no longer existed — silently, forever, with no
 * symptom beyond "the device never appears in the app".
 *
 * The device therefore has to be able to answer one question by itself: "where
 * is the backend on THIS network?" It does that by looking for it.
 * ==========================================================================*/
#ifndef SHE_NET_DISCOVERY_H
#define SHE_NET_DISCOVERY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"

/* Default port the backend listens on (Spring Boot, application.yml server.port). */
#define NET_DISCOVERY_API_PORT   8080

/**
 * Probe the device's own /24 for a host answering GET /actuator/health with
 * `"status":"UP"`.
 *
 * @param host_out   Receives the dotted-quad address, e.g. "192.168.1.21".
 * @param host_len   Size of host_out; needs at least 16 bytes.
 * @param api_port   Backend HTTP port, normally NET_DISCOVERY_API_PORT.
 *
 * @return ESP_OK when a backend was found and host_out is filled.
 *         ESP_ERR_NOT_FOUND when the scan completed with no match.
 *         ESP_ERR_INVALID_STATE when the station has no IP yet.
 *
 * Blocks for roughly 5-8 s in the worst case (the /24 is probed in batches of
 * six, 120 ms per batch). Call it only when the configured broker is already
 * known to be unreachable — never on the normal boot path.
 */
esp_err_t net_discovery_find_backend(char *host_out, size_t host_len, uint16_t api_port);

/**
 * Is `host` accepting TCP connections on `port`?
 *
 * Used to decide whether the configured broker is still there before paying for
 * a subnet scan. Only dotted-quad addresses are accepted; anything else (a DNS
 * name, an empty string) returns false.
 *
 * @return true when the TCP handshake completed inside timeout_ms.
 */
bool net_discovery_probe_host(const char *host, uint16_t port, int timeout_ms);

#endif /* SHE_NET_DISCOVERY_H */
