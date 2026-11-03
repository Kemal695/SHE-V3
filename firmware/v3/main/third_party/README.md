# third_party — vendored code

Do not edit these files. Their value is that they are byte-for-byte upstream, so the
checksums below remain verifiable. Put any adaptation in a separate `*_port.c`.

## TweetNaCl — Ed25519 verification for OTA

| | |
|---|---|
| Upstream | https://tweetnacl.cr.yp.to/20140427/tweetnacl.c |
| Header | https://tweetnacl.cr.yp.to/20140427/tweetnacl.h |
| Retrieved | 2026-09-16 |
| Licence | Public domain |
| `tweetnacl.c` sha256 | `02e65bc3013ff2168983365e55906bc783c4c7e0a60d8100f17bb303a17175c4` |
| `tweetnacl.h` sha256 | `43f29ad721d9927b747b0100ab4160c119e7bb180c7c98a66e4bf79d31244287` |

### Why this exists

P1-27 (`CANONICAL-DECISIONS.md`, `V3-SECURITY-MODEL.md` §5.5) mandates **Ed25519** for OTA
image signing, and the project pins **ESP-IDF 5.1.4 (LTS)**. That IDF's bundled mbedtls has
**no Ed25519 support**:

- `mbedtls/include/mbedtls/ecp.h` — the `MBEDTLS_ECP_DP_*` enum has no `ED25519` entry.
  It does have `CURVE25519`, but that is the Montgomery form used for **ECDH**, not Ed25519
  signatures. Do not confuse the two.
- `components/mbedtls/Kconfig` — no `ed25519` option, so it cannot be enabled.
- `components/mbedtls/mbedtls/library/` — no `ed25519.c`. The only case-insensitive match in
  the whole tree is a string table in `ssl_debug_helpers_generated.c` (a log label).
- `CONFIG_MBEDTLS_PSA_CRYPTO_C` is not set, so the PSA crypto route is unavailable too.

So the verifier is vendored rather than written from scratch — hand-rolling curve arithmetic is
how you get a signature check that passes everything.

### Scope note

Only `crypto_sign_open()` (verify) is called. `crypto_sign_keypair()` and `crypto_sign()` are
present because they live in the same upstream translation unit, which is why
`tweetnacl_port.c` must supply `randombytes()` for the linker. **The device never generates or
signs with an OTA key** — signing happens off-device.

### Two things to know if you touch this

1. TweetNaCl assumes `unsigned long` is 32-bit and `unsigned long long` is 64-bit. True on
   Xtensa (32-bit) and RISC-V RV32. It would be wrong on a 64-bit host.
2. `tweetnacl.h` is the upstream generated header — a large block of `#define`s mapping the
   generic names onto `*_tweet` symbols. Include it, don't hand-write a reduced version.

## qrcode — QR Code generation for the provisioning sticker

| | |
|---|---|
| Upstream | ESP RainMaker, `examples/common/qrcode/` (Espressif's `esp_qrcode`, itself based on Project Nayuki's QR-Code-generator) |
| Local copy of upstream | `C:\Users\Dell\.espressif\esp-rainmaker\examples\common\qrcode\` |
| Retrieved | 2026-10-03 |
| Licence | Apache-2.0 (Espressif wrapper) + MIT (Nayuki `qrcodegen`) |
| `qrcode.h` sha256 | `442515f7562a3bc3fa4954d740f474214ce7ea76f845057f683adc4a931d4844` |
| `qrcodegen.h` sha256 | `003b2b0b998100ab99abb334536c105b9234d5852dafb616f063d5b74db2ede2` |
| `qrcodegen.c` sha256 | `242d05ba7b88691827fd3fa5d39e2e6d4371bc3cc7bfb1eca06e7474a793bc37` |
| `esp_qrcode_wrapper.c` sha256 | `ecd922672bc5e89d74981b24f83c35c375857ab51aeadeb7c3a09fc85d3df620` |
| `esp_qrcode_main.c` sha256 | `594774dc218f29c3e908e9d437f945ac6f1b1e61480f54efd09bf9fce1d788db` |

### Why this exists

`V3-FACTORY-OPS.md` §4 puts a JSON payload on the enclosure as a QR sticker. A board whose
sticker is missing or unreadable then has no way to be added — the app needs the 9-digit PoP and
there is nothing on the device to read it from. So the firmware prints the same payload as a QR
**on the console**, which is exactly what the ESP-IDF `wifi_prov_mgr` example and RainMaker do
(`esp_qrcode_generate()` + `ESP_QRCODE_CONFIG_DEFAULT()`).

### Why vendored, not a registry component

The canonical way is the managed component `espressif/qrcode` via `idf_component.yml`. That was
rejected here: `firmware/v3/` has **no `managed_components/` and no `dependencies.lock`**, i.e.
the component manager has never run for this project, and its root `idf_component.yml` declares
`idf: "^5.1.0"` while the installed toolchain is **ESP-IDF v5.0.2**. Adding a registry dependency
would make the next `idf.py reconfigure` run version resolution against a constraint the local
IDF does not satisfy — risking a build that fails before it reaches any of our code. Vendoring
keeps the build offline and version-independent, and matches how TweetNaCl is already handled.

### The one adaptation — `esp_rmaker_utils.h`

`esp_qrcode_main.c` includes `<esp_rmaker_utils.h>` for a single symbol, `MEM_CALLOC_EXTRAM`,
which is RainMaker's PSRAM-preferring allocator. Since the vendored `.c` files must stay
byte-for-byte upstream, the shim header of that exact name lives beside them and defines the
macro as plain `calloc()`. That is upstream's own non-PSRAM branch, and correct for the
ESP32-D0WD in the SHE-R24 (no PSRAM).

### Rendering note

`esp_qrcode_print_console()` draws the symbol with Unicode half-blocks (U+2580/U+2584/U+2588),
two QR rows per console line. The serial terminal must therefore be **UTF-8** and use a font that
has those glyphs — a terminal that shows `????` is a font/encoding problem, not a firmware one.
That failure mode is why `ble_provisioning.c` also prints a `?data=` browser URL.
