/* =============================================================================
 * SHE V3 firmware — net_discovery.c
 * =============================================================================
 * Find the SHE backend on the device's own /24.
 *
 * Strategy, cheapest first:
 *   1. TCP-connect probe :8080 across the /24, six at a time, 120 ms each.
 *      A host that is not there never answers, so the probe is bounded by the
 *      timeout rather than by the network — 254 hosts ≈ 5 s worst case.
 *   2. Only the few hosts that accepted a connection get an HTTP GET
 *      /actuator/health, and only one that returns `"status":"UP"` is adopted.
 *
 * Deliberately /24, not the real netmask: a /16 would mean 65 000 probes, and
 * every network this product is deployed on is /24 or smaller.
 *
 * This runs only when the configured broker is unreachable, so the normal boot
 * path pays nothing for it.
 * ==========================================================================*/
#include "net_discovery.h"

#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <fcntl.h>

#include "esp_log.h"
#include "esp_netif.h"
#include "lwip/sockets.h"
#include "lwip/inet.h"

static const char *TAG = "she_disc";

/* Kept below CONFIG_LWIP_MAX_SOCKETS (10) with room for the MQTT/TLS sockets
 * that are already open by the time this can run. */
#define PROBE_CONCURRENCY    6
/* 400 ms, not 120. A host that is present still has to be resolved by ARP
 * before its SYN can be answered, and on Wi-Fi that is routinely 100-300 ms
 * for an address the device has never talked to. At 120 ms the scan walked the
 * whole /24 and reported "no host" while the backend was up and reachable on
 * that very subnet — a false negative that reads exactly like a missing
 * backend. The cost is bounded: 254/6 x 400 ms ~= 17 s, and this only runs when
 * the configured broker is already dead. */
#define PROBE_TIMEOUT_MS     400
#define HTTP_TIMEOUT_S       2
#define HEALTH_PATH          "/actuator/health"
#define HEALTH_MAX_BYTES     512

/* ---------------------------------------------------------------------------
 * Non-blocking connect, left pending. Caller waits on the fd.
 * Returns fd >= 0, or -1.
 * ------------------------------------------------------------------------- */
static int connect_pending(uint32_t ip_be, uint16_t port)
{
    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) return -1;

    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        close(fd);
        return -1;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = ip_be;

    int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (rc == 0) return fd;                 /* connected immediately */
    if (errno == EINPROGRESS) return fd;    /* pending — caller selects */
    close(fd);
    return -1;
}

/* Did a pending connect succeed? Consumes nothing; caller closes the fd. */
static bool connect_completed(int fd)
{
    int so_err = 0;
    socklen_t len = sizeof(so_err);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &so_err, &len) != 0) return false;
    return so_err == 0;
}

/* Blocking single-host probe, used to check the configured broker is alive. */
static bool probe_blocking(uint32_t ip_be, uint16_t port, int timeout_ms)
{
    int fd = connect_pending(ip_be, port);
    if (fd < 0) return false;

    fd_set wfds;
    FD_ZERO(&wfds);
    FD_SET(fd, &wfds);
    struct timeval tv;
    tv.tv_sec  = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;

    bool ok = false;
    if (select(fd + 1, NULL, &wfds, NULL, &tv) > 0 && FD_ISSET(fd, &wfds)) {
        ok = connect_completed(fd);
    }
    close(fd);
    return ok;
}

/* ---------------------------------------------------------------------------
 * Ask a candidate whether it really is the SHE backend.
 *
 * `why` receives a short human-readable reason when the answer is "no". Without
 * it this function's only output was a single line — "1 host(s) answered but
 * none looked like the SHE backend" — which named neither the host nor the
 * response, so a live backend could be rejected and there was nothing to go on.
 * That exact message cost hours.
 * ------------------------------------------------------------------------- */
static bool http_is_backend(uint32_t ip_be, uint16_t port, char *why, size_t why_len)
{
    /* Callers may not care about the reason; keep the snprintf() calls below
     * safe rather than sprinkling NULL checks through every branch. */
    char sink[1];
    if (why == NULL || why_len == 0) {
        why = sink;
        why_len = sizeof(sink);
    }
    why[0] = '\0';

    int fd = connect_pending(ip_be, port);
    if (fd < 0) {
        snprintf(why, why_len, "connect could not be started");
        return false;
    }

    /* The host answered a TCP probe a moment ago, so give connect the same
     * bounded wait rather than trusting a blocking connect to return. */
    fd_set wfds;
    FD_ZERO(&wfds);
    FD_SET(fd, &wfds);
    struct timeval tv = { .tv_sec = HTTP_TIMEOUT_S, .tv_usec = 0 };
    if (select(fd + 1, NULL, &wfds, NULL, &tv) <= 0 || !connect_completed(fd)) {
        close(fd);
        snprintf(why, why_len, "connect did not complete within %ds", HTTP_TIMEOUT_S);
        return false;
    }

    /* Back to blocking for the request/response exchange. */
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
    struct timeval rcv = { .tv_sec = HTTP_TIMEOUT_S, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rcv, sizeof(rcv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &rcv, sizeof(rcv));

    static const char req[] =
        "GET " HEALTH_PATH " HTTP/1.0\r\n"
        "Host: she\r\n"
        "Connection: close\r\n"
        "\r\n";

    if (send(fd, req, sizeof(req) - 1, 0) < 0) {
        close(fd);
        snprintf(why, why_len, "request could not be sent");
        return false;
    }

    /* Static, not automatic: this runs on the main task, which has only
     * CONFIG_ESP_MAIN_TASK_STACK_SIZE (3584 B) and is already holding the MQTT
     * client config. A 512-byte local here is how you turn "broker discovery"
     * into a stack-overflow panic. The function is only ever called
     * sequentially from one task, so a single static buffer is safe. */
    static char buf[HEALTH_MAX_BYTES];
    int total = 0;
    bool matched = false;
    while (total < (int)sizeof(buf) - 1) {
        int n = recv(fd, buf + total, sizeof(buf) - 1 - total, 0);
        if (n <= 0) break;
        total += n;
        buf[total] = '\0';
        /* Spring Boot's health payload: {"status":"UP","components":{...}} */
        if (strstr(buf, "\"status\":\"UP\"") != NULL) {
            matched = true;
            break;
        }
    }
    close(fd);

    if (!matched) {
        if (total == 0) {
            snprintf(why, why_len, "no HTTP response");
        } else {
            /* Report the status line and the first few body bytes, with control
             * characters stripped so the log stays one line. */
            char snippet[64];
            size_t j = 0;
            for (int i = 0; i < total && j < sizeof(snippet) - 1; i++) {
                char c = buf[i];
                snippet[j++] = (c == '\r' || c == '\n' || c == '\t') ? ' ' : c;
            }
            snippet[j] = '\0';
            snprintf(why, why_len, "HTTP response did not contain \"status\":\"UP\" — %s", snippet);
        }
    }
    return matched;
}

/* ---------------------------------------------------------------------------
 * Public API
 * ------------------------------------------------------------------------- */
esp_err_t net_discovery_find_backend(char *host_out, size_t host_len, uint16_t api_port)
{
    if (host_out == NULL || host_len < 16) return ESP_ERR_INVALID_ARG;

    esp_netif_t *netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
    if (netif == NULL) {
        ESP_LOGW(TAG, "No station netif — cannot scan");
        return ESP_ERR_INVALID_STATE;
    }

    esp_netif_ip_info_t info;
    if (esp_netif_get_ip_info(netif, &info) != ESP_OK || info.ip.addr == 0) {
        ESP_LOGW(TAG, "No IP yet — cannot scan");
        return ESP_ERR_INVALID_STATE;
    }

    const uint32_t own_h  = ntohl(info.ip.addr);
    const uint32_t net24  = own_h & 0xFFFFFF00u;   /* our own /24, whatever the mask */
    const uint32_t own_be = info.ip.addr;

    ESP_LOGW(TAG, "Broker unreachable — scanning %u.%u.%u.0/24 for the backend",
             (unsigned)((net24 >> 24) & 0xFF), (unsigned)((net24 >> 16) & 0xFF),
             (unsigned)((net24 >> 8) & 0xFF));

    uint32_t candidates[8];
    int n_candidates = 0;
    int socket_fails = 0;      /* probes skipped because no socket was available */

    /* ---- Phase 1: who has :8080 open? ---- */
    for (uint32_t host = 1; host <= 254 && n_candidates < (int)(sizeof(candidates) / sizeof(candidates[0])); ) {
        int fds[PROBE_CONCURRENCY];
        uint32_t ips[PROBE_CONCURRENCY];
        int n = 0;

        while (n < PROBE_CONCURRENCY && host <= 254) {
            uint32_t ip_be = htonl(net24 + host);
            host++;
            if (ip_be == own_be) continue;          /* never probe ourselves */

            int fd = connect_pending(ip_be, api_port);
            if (fd < 0) { socket_fails++; continue; }   /* out of sockets */
            fds[n] = fd;
            ips[n] = ip_be;
            n++;
        }
        if (n == 0) break;

        fd_set wfds;
        FD_ZERO(&wfds);
        int maxfd = -1;
        for (int k = 0; k < n; k++) {
            FD_SET(fds[k], &wfds);
            if (fds[k] > maxfd) maxfd = fds[k];
        }
        struct timeval tv;
        tv.tv_sec  = PROBE_TIMEOUT_MS / 1000;
        tv.tv_usec = (PROBE_TIMEOUT_MS % 1000) * 1000;

        if (select(maxfd + 1, NULL, &wfds, NULL, &tv) > 0) {
            for (int k = 0; k < n; k++) {
                if (FD_ISSET(fds[k], &wfds) && connect_completed(fds[k])) {
                    if (n_candidates < (int)(sizeof(candidates) / sizeof(candidates[0]))) {
                        candidates[n_candidates++] = ips[k];
                    }
                }
            }
        }
        for (int k = 0; k < n; k++) close(fds[k]);
    }

    if (n_candidates == 0) {
        ESP_LOGW(TAG, "No host on the /24 accepted TCP %u "
                      "(%d probes skipped: no socket)",
                 (unsigned)api_port, socket_fails);
        return ESP_ERR_NOT_FOUND;
    }

    /* Name the hosts that answered. Without this, "none looked like the SHE
     * backend" cannot be told apart from "the backend was never even a
     * candidate" — which is the difference between a health-check bug and a
     * probing bug, and both look identical from the outside. */
    for (int k = 0; k < n_candidates; k++) {
        struct in_addr c = { .s_addr = candidates[k] };
        ESP_LOGW(TAG, "  candidate %s:%u answered TCP",
                 inet_ntoa(c), (unsigned)api_port);
    }

    /* ---- Phase 2: which of them is actually the SHE backend? ---- */
    for (int k = 0; k < n_candidates; k++) {
        char why[96];
        if (!http_is_backend(candidates[k], api_port, why, sizeof(why))) {
            struct in_addr bad = { .s_addr = candidates[k] };
            ESP_LOGW(TAG, "  %s:%u answered TCP but was rejected — %s",
                     inet_ntoa(bad), (unsigned)api_port, why);
            continue;
        }

        struct in_addr a = { .s_addr = candidates[k] };
        snprintf(host_out, host_len, "%s", inet_ntoa(a));
        ESP_LOGW(TAG, "Backend found at %s:%u", host_out, (unsigned)api_port);
        return ESP_OK;
    }

    ESP_LOGW(TAG, "%d host(s) answered TCP %u but none served %s with a healthy "
                  "payload — see the per-host reasons above",
             n_candidates, (unsigned)api_port, HEALTH_PATH);
    return ESP_ERR_NOT_FOUND;
}

bool net_discovery_probe_host(const char *host, uint16_t port, int timeout_ms)
{
    if (host == NULL || host[0] == '\0') return false;

    /* inet_addr returns INADDR_NONE for anything that is not a dotted quad.
     * Hostnames are out of scope: the stored broker is always an IP here. */
    struct in_addr a;
    a.s_addr = inet_addr(host);
    if (a.s_addr == INADDR_NONE) return false;
    return probe_blocking(a.s_addr, port, timeout_ms);
}
