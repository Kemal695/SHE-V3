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
