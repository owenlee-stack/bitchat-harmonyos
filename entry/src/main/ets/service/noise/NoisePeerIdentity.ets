/**
 * Canonical binding between an authenticated Noise static key and its mesh wire
 * identity - mirrors bitchat-android NoisePeerIdentity.kt.
 *
 * Mesh peer IDs are the first eight bytes of SHA-256(staticPublicKey), encoded
 * as 16 lowercase hexadecimal characters. A self-signed announcement or
 * completed Noise XX handshake is not sufficient on its own: the claimed wire
 * ID must also match this derivation.
 */
import { ByteUtils } from '../../common/ByteUtils';

export class NoisePeerIdentity {
  static readonly STATIC_PUBLIC_KEY_SIZE: number = 32;
  static readonly WIRE_PEER_ID_LENGTH: number = 16;

  static derivePeerID(staticPublicKey: Uint8Array): string | null {
    if (staticPublicKey.length !== NoisePeerIdentity.STATIC_PUBLIC_KEY_SIZE) {
      return null;
    }
    const digest: Uint8Array = ByteUtils.sha256(staticPublicKey);
    return ByteUtils.bytesToHex(digest.slice(0, 8));
  }

  static matchesClaimedPeerID(claimedPeerID: string, staticPublicKey: Uint8Array): boolean {
    if (!/^[0-9a-f]{16}$/.test(claimedPeerID)) {
      return false;
    }
    const derived: string | null = NoisePeerIdentity.derivePeerID(staticPublicKey);
    return derived !== null && derived === claimedPeerID;
  }
}
