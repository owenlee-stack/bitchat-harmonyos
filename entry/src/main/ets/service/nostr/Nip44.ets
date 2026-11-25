/**
 * NIP-44 v2 conversation encryption, bitchat variant.
 *
 * Mirrors bitchat-android NostrCrypto.encryptNIP44/decryptNIP44: the
 * HKDF input is the compressed 33-byte ECDH shared point (NOT the
 * 32-byte x-only secret of the standard NIP-44), the HKDF is
 * extract(empty salt) then expand("nip44-v2" || 0x01, 32), and the
 * payload is "v2:" + base64url(nopad) of the Tink XChaCha20-Poly1305
 * combined layout nonce24 || ciphertext || tag16. Decryption tries the
 * even-Y lift first, then the odd-Y lift. Pure ArkTS: no @ohos/@kit
 * imports, host-runnable by the contract-test harness.
 */
import { ByteUtils, HmacSha256 } from '../../common/ByteUtils';
import { Secp256k1 } from './Secp256k1';
import { XChaCha20Poly1305 } from './XChaCha20Poly1305';

export class Nip44 {
  /**
   * Encrypt a plaintext for the recipient. The nonce is injected so the
   * contract tests stay deterministic.
   */
  static encrypt(plaintext: string, recipientPublicKeyHex: string,
    senderPrivateKeyHex: string, nonce24: Uint8Array): string {
    const sharedPoint: Uint8Array | null = Secp256k1.ecdhSharedPointCompressed(
      senderPrivateKeyHex, recipientPublicKeyHex, false);
    if (sharedPoint === null) {
      throw new Error('NIP-44 v2 encryption failed: invalid keys');
    }
    const conversationKey: Uint8Array = Nip44.deriveConversationKey(sharedPoint);
    const combined: Uint8Array = XChaCha20Poly1305.seal(
      conversationKey, nonce24, ByteUtils.utf8Encode(plaintext), null);
    return 'v2:' + ByteUtils.base64UrlEncode(combined);
  }

  /**
   * Decrypt a "v2:" payload. Only the exact "v2:" base64url format is
   * accepted; both even/odd Y lifts of the x-only sender key are tried
   * (even first, matching Android). Throws when decryption fails.
   */
  static decrypt(ciphertext: string, senderPublicKeyHex: string,
    recipientPrivateKeyHex: string): string {
    if (!ciphertext.startsWith('v2:')) {
      throw new Error('NIP-44 v2 decryption failed: invalid version prefix');
    }
    const encryptedData: Uint8Array = ByteUtils.base64Decode(ciphertext.substring(3));
    // Even-Y lift first, then odd-Y (Android parity order).
    for (let i: number = 0; i < 2; i++) {
      const preferOdd: boolean = i === 1;
      const sharedPoint: Uint8Array | null = Secp256k1.ecdhSharedPointCompressed(
        recipientPrivateKeyHex, senderPublicKeyHex, preferOdd);
      if (sharedPoint === null) {
        continue;
      }
      const conversationKey: Uint8Array = Nip44.deriveConversationKey(sharedPoint);
      try {
        const plaintext: Uint8Array =
          XChaCha20Poly1305.open(conversationKey, encryptedData, null);
        return ByteUtils.utf8Decode(plaintext);
      } catch (e) {
        // Try the other Y parity, mirroring the Android fallback loop.
      }
    }
    throw new Error('NIP-44 v2 decryption failed');
  }

  /** HKDF-SHA256: extract with empty salt, expand with info "nip44-v2", 32 bytes. */
  private static deriveConversationKey(sharedPoint33: Uint8Array): Uint8Array {
    const prk: Uint8Array = HmacSha256.compute(new Uint8Array(0), sharedPoint33);
    const info: Uint8Array =
      ByteUtils.concat(ByteUtils.utf8Encode('nip44-v2'), new Uint8Array([0x01]));
    return HmacSha256.compute(prk, info);
  }
}
