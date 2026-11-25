/**
 * Canonical, side-effect-free preflight for a self-signed mesh announcement.
 * Mirrors bitchat-android AnnouncementIdentityValidator.kt.
 */
import { BitchatPacket, MessageType } from '../../model/BitchatPacket';
import { IdentityAnnouncement } from '../../model/IdentityModels';
import { SecurityConstants } from '../../common/ProtocolConstants';
import { ByteUtils } from '../../common/ByteUtils';
import { BinaryProtocol } from '../protocol/BinaryProtocol';
import { NoisePeerIdentity } from '../noise/NoisePeerIdentity';

export class AnnouncementIdentityValidator {
  private static readonly MAX_CLOCK_SKEW_MS: number = SecurityConstants.ANNOUNCE_MAX_CLOCK_SKEW_MS;

  static verify(packet: BitchatPacket, claimedPeerID: string, nowMs: number,
    verifyEd25519: (signature: Uint8Array, data: Uint8Array, publicKey: Uint8Array) => boolean): IdentityAnnouncement | null {
    if (packet.type !== MessageType.ANNOUNCE) {
      return null;
    }
    const now: number = Math.max(Math.floor(nowMs), 0);
    const skew: number = packet.timestamp >= now ? packet.timestamp - now : now - packet.timestamp;
    if (skew > AnnouncementIdentityValidator.MAX_CLOCK_SKEW_MS) {
      return null;
    }
    const announcement: IdentityAnnouncement | null = IdentityAnnouncement.decode(packet.payload);
    if (announcement === null) {
      return null;
    }
    if (announcement.signingPublicKey.length !== 32) {
      return null;
    }

    const derivedPeerID: string | null = NoisePeerIdentity.derivePeerID(announcement.noisePublicKey);
    if (derivedPeerID === null) {
      return null;
    }
    if (ByteUtils.bytesToHex(packet.senderId) !== derivedPeerID || claimedPeerID !== derivedPeerID) {
      return null;
    }

    if (packet.signature === null) {
      return null;
    }
    const canonicalData: Uint8Array | null = BinaryProtocol.toBinaryDataForSigning(packet);
    if (canonicalData === null) {
      return null;
    }
    return verifyEd25519(packet.signature, canonicalData, announcement.signingPublicKey)
      ? announcement
      : null;
  }
}
