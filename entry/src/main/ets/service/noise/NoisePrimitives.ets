/**
 * Cryptographic primitives facade for the Noise stack (T009, D1 decision).
 *
 * Availability conclusions (cryptoFramework, verified against the API 26
 * local docs) are recorded in spec/bitchat-harmonyos/notes-crypto.md:
 * the Noise state machine requires synchronous, host-testable primitives,
 * so ChaCha20-Poly1305 and X25519 are pure ArkTS ports of the vendored
 * noise-java sources, locked by the Noise external golden vectors.
 * SHA-256/HMAC-SHA256 come from common/ByteUtils. Device-only crypto
 * (Asset-backed key storage, HUKS key derivation, AES-GCM app-layer
 * encryption) lives in data/SecureKeyStore and does not run through this
 * facade. Pure ArkTS: no @ohos/@kit imports, host-runnable by the
 * contract-test harness.
 */
import { ChaChaPolyCipher } from './ChaCha20Poly1305';
import { Curve25519 } from './Curve25519';
import { HmacSha256 } from '../../common/ByteUtils';

export { ChaChaPolyCipher };
export { Curve25519 };

export class NoisePrimitives {
  /**
   * Noise-style two-output HKDF over HMAC-SHA256 (SymmetricState.java hkdf):
   * tempKey = HMAC-SHA256(chainingKey, data);
   * output1 = HMAC-SHA256(tempKey, 0x01);
   * output2 = HMAC-SHA256(tempKey, output1 || 0x02);
   * each output truncated to its own length (at most 32 bytes).
   */
  static hkdfSha256(chainingKey: Uint8Array, data: Uint8Array,
    output1: Uint8Array, output2: Uint8Array): void {
    const tempKey: Uint8Array = HmacSha256.compute(chainingKey, data);
    const first: Uint8Array = new Uint8Array([1]);
    const t1: Uint8Array = HmacSha256.compute(tempKey, first);
    output1.set(t1.subarray(0, output1.length));
    const t1AndCounter: Uint8Array = new Uint8Array(33);
    t1AndCounter.set(t1, 0);
    t1AndCounter[32] = 2;
    const t2: Uint8Array = HmacSha256.compute(tempKey, t1AndCounter);
    output2.set(t2.subarray(0, output2.length));
  }
}
