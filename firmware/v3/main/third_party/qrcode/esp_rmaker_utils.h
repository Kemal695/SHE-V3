/* =============================================================================
 * third_party/qrcode — compatibility shim for the vendored Espressif QR component
 * =============================================================================
 * `esp_qrcode_main.c` is byte-for-byte upstream and asks for exactly one symbol
 * from RainMaker: MEM_CALLOC_EXTRAM, the allocator RainMaker uses to prefer
 * PSRAM. SHE V3 does not link RainMaker, and `third_party/README.md` forbids
 * editing a vendored file — so this header stands in for it instead.
 *
 * It MUST keep the upstream include name, because that is the name the
 * untouched `.c` file asks for (`#include <esp_rmaker_utils.h>`), and the
 * directory is on the component's include path.
 *
 * Upstream definition being mirrored
 * (esp-rainmaker/components/esp-insights/components/rmaker_common/include/esp_rmaker_utils.h):
 *
 *     #if CONFIG_SPIRAM
 *     #define MEM_CALLOC_EXTRAM(n, s) \
 *         heap_caps_calloc_prefer(n, s, 2, MALLOC_CAP_DEFAULT | MALLOC_CAP_SPIRAM, \
 *                                 MALLOC_CAP_DEFAULT | MALLOC_CAP_INTERNAL)
 *     #else
 *     #define MEM_CALLOC_EXTRAM(n, s)   calloc(n, s)
 *     #endif
 *
 * SHE-R24 is an ESP32-D0WD with NO PSRAM, so upstream's own #else branch is the
 * right one here: plain calloc(). The only two allocations are the QR matrix and
 * its scratch buffer — ~2 x 360 bytes for max_qrcode_version = 10.
 * ==========================================================================*/

#ifndef SHE_THIRD_PARTY_QRCODE_ESPRESSIF_RMAKER_UTILS_SHIM_H
#define SHE_THIRD_PARTY_QRCODE_ESPRESSIF_RMAKER_UTILS_SHIM_H

#include <stdlib.h>   /* calloc */

/* The one symbol esp_qrcode_main.c actually uses. */
#define MEM_CALLOC_EXTRAM(num, size)   calloc((num), (size))

#endif /* SHE_THIRD_PARTY_QRCODE_ESPRESSIF_RMAKER_UTILS_SHIM_H */
