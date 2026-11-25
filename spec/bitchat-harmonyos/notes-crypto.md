# Crypto Availability Notes (T009 / D1)

Date: 2026-11-05
Scope: cryptographic primitive sourcing for the Noise stack and app-layer crypto, per plan.md D1.

## cryptoFramework availability (API 26 target, verified against local SDK docs)

| Primitive | cryptoFramework support | API level | Sync API? | Decision |
|---|---|---|---|---|
| SHA-256 / HMAC-SHA256 | Yes (`createMd`/`createMac`) | 9+ | No (Promise/callback) | Pure ArkTS (`common/ByteUtils`), needed sync + host-testable |
| ChaCha20-Poly1305 AEAD | Yes (`ChaCha20` cipher + Poly1305 AEAD params) | 22+ | No | Pure ArkTS port (`service/noise/ChaCha20Poly1305.ets`) |
| X25519 | Yes (`createAsyKeyGenerator('X25519')` key agreement) | 12+ | No | Pure ArkTS (`service/noise/Curve25519.ets`) |
| Ed25519 | Yes (key generation + sign/verify) | 12+ | No | cryptoFramework on device (profile signatures; not in the sync Noise path) |
| AES-GCM | Yes | 9+ | No | cryptoFramework on device (SecureKeyStore app-layer encryption, T010) |
| HKDF (`HKDF\|SHA256`) | Yes (`createKdf('HKDF\|SHA256')`) | 12+ | No | Pure ArkTS (`NoisePrimitives.hkdfSha256`, noise 2-output form) |
| Secure random | Yes (`createRandom`) | 9+ | Sync (`generateRandomSync`) + async | cryptoFramework on device; injectable into the Noise machine (T032) |

## Why the Noise path is pure ArkTS

1. **Sync semantics**: the noise-java state machine (HandshakeState/CipherState) is a
   synchronous API; cryptoFramework cipher/kdf operations are Promise-based and
   cannot serve it without rewriting the handshake as async state machine.
2. **Host testability**: the golden-vector contract harness stages the kernel on
   Node; any `@ohos/@kit` import in the Noise path would break that gate.
3. **Byte-exactness**: ports of the vendored southernstorm sources are locked by
   the Noise external golden vectors, which is the interop contract.

## Implementation notes

- `ChaCha20Poly1305.ets`: ChaChaCore is a direct port of `ChaChaCore.java`
  (32-bit quarter-round arithmetic). The AEAD framing mirrors
  `ChaChaPolyCipherState.java`: 64-bit packet counter `n` in ChaCha words 14/15,
  words 12/13 as block counter, Poly1305 key from the first 32 keystream bytes,
  `ct||tag` layout, AD padded then LE64(adLen)||LE64(dataLen).
- Poly1305 and X25519 use **BigInt**: a direct port of the 26-bit-limb Java code
  is not exact in JS doubles (limb products and accumulations exceed 2^53 and
  lose precision). BigInt keeps the 130-bit/255-bit accumulators exact.
- `Curve25519.ets`: RFC 7748 Montgomery ladder with noise-java clamping
  semantics (low three bits cleared, bit 254 forced, bit 255 ignored inside the
  evaluation; public inputs reduced mod 2^255-19).

## Verification status

- Cross-verified on host against Node/OpenSSL: ChaCha20 block function vs
  `chacha20`; ChaChaPoly AEAD vs `chacha20-poly1305` (200 randomized
  key/nonce/AD/length iterations, both directions, tamper rejection); X25519
  vs `x25519` (50 randomized keypairs, public keys + shared secrets).
- Locked in the committed contract gate: `NoisePrimitivesContractTests`
  (RFC 7539 block vector, OpenSSL-generated AEAD golden bytes, RFC 5869-style
  2-output HKDF, cacophony e vectors from NoiseExternalVectorTest.kt, RFC 7748
  section 6.1 DH example).
- End-to-end lock pending: the full Noise_XX cacophony transcript test
  (NoiseExternalVectorTest port) lands with the HandshakeState port (T032) and
  exercises the DH + HKDF + AEAD chain through real handshake messages.

## Performance and constant-time assessment

- BigInt arithmetic is not constant-time and allocates per operation. This is
  acceptable for the handshake (once per peer connection) and for mesh packet
  sizes (roughly 0.1–1 KB per packet), but **device-side benchmarks are still
  pending** (no device run yet). D1 fallback: if per-packet ChaChaPoly or
  handshake X25519 throughput is insufficient on device (8 concurrent peers),
  demote the hot primitive to a C++ NAPI library (`library_native/`) keeping
  the same facade contract.
- Re-evaluate after the M1 device integration; record numbers here.
