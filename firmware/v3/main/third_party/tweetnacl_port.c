/* =============================================================================
 * tweetnacl_port.c — the only adaptation layer for vendored TweetNaCl
 * =============================================================================
 * tweetnacl.c declares `extern void randombytes(u8 *, u64);` and calls it from
 * crypto_sign_keypair(). We only ever call crypto_sign_open() (verify), but keygen lives in
 * the same upstream translation unit, so the symbol must still resolve at link time.
 *
 * Supplying it here keeps tweetnacl.c byte-for-byte upstream, so the sha256 recorded in
 * README.md stays meaningful. Do NOT edit tweetnacl.c to drop the dependency instead — a
 * patched crypto file loses its provenance and nobody can re-verify it later.
 *
 * The device never generates or signs with an OTA key: signing happens off-device. This
 * function exists purely to satisfy the linker, and deliberately uses the ESP32 hardware RNG
 * rather than anything weaker.
 * ==========================================================================*/

#include "esp_random.h"
#include "tweetnacl.h"

void randombytes(unsigned char *p, unsigned long long n)
{
    esp_fill_random(p, (size_t)n);
}
