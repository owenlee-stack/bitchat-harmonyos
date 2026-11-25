/**
 * BitChat-over-Nostr adapter (US12, T060; Android
 * NostrEmbeddedBitChat.kt parity).
 *
 * Encodes a BitChat packet (v1, NOISE_ENCRYPTED, TTL
 * MESSAGE_TTL_HOPS) carrying a Noise payload into the
 * "bitchat1:" + base64url (unpadded) content string that travels
 * inside a NIP-17 gift wrap, and decodes it back on receipt.
 *
 * The recipient-addressed envelopes embed the 8-byte mesh peer IDs
 * (the recipient's derived from their Noise key when needed); the
 * recipient-less variants (inbound geohash DM acks) randomize the
 * sender ID per envelope so the mesh peer ID - the stable Noise
 * fingerprint prefix - never leaks a persona link (Android
 * unlinkableSenderID parity).
 *
 * Pure ArkTS: no @ohos/@kit imports, host-runnable by the
 * contract-test harness.
 */
import { ByteUtils } from '../../common/ByteUtils';
import { PkTtl } from '../../common/ProtocolConstants';
import { BitchatPacket, MessageType } from '../../model/BitchatPacket';
import { NoisePayload, NoisePayloadType, PrivateMessagePacket } from '../../model/IdentityModels';
import { BinaryProtocol } from '../protocol/BinaryProtocol';
import { ContactIdentityResolver } from '../identity/ContactIdentityResolver';
import { NostrRandomSource } from './NostrRandomSource';

/** Content prefix marking an embedded BitChat packet (iOS parity). */
export const EMBEDDED_BITCHAT_PREFIX: string = 'bitchat1:';

/** A decoded embedded BitChat envelope: packet plus its Noise payload. */
export class EmbeddedBitChatMessage {
  readonly packet: BitchatPacket;
  readonly payload: NoisePayload;

  constructor(packet: BitchatPacket, payload: NoisePayload) {
    this.packet = packet;
    this.payload = payload;
  }
}

export class NostrEmbeddedBitChat {
  private static readonly SENDER_ID_SIZE: number = 8;

  /** Build a "bitchat1:" private message for recipient-addressed Nostr DMs. */
  static encodePMForNostr(content: string, messageID: string, recipientPeerID: string,
    senderPeerID: string, nowMs: number): string | null {
    const pm: PrivateMessagePacket = new PrivateMessagePacket(messageID, content);
    const tlv: Uint8Array | null = pm.encode();
    if (tlv === null) {
      return null;
    }
    const payload: Uint8Array =
      new NoisePayload(NoisePayloadType.PRIVATE_MESSAGE, tlv).encode();
    return NostrEmbeddedBitChat.encodeEmbedded(payload,
      NostrEmbeddedBitChat.normalizeRecipientPeerID(recipientPeerID), senderPeerID, nowMs);
  }

  /** Build a "bitchat1:" DELIVERED/READ_RECEIPT ack for recipient-addressed DMs. */
  static encodeAckForNostr(type: NoisePayloadType, messageID: string, recipientPeerID: string,
    senderPeerID: string, nowMs: number): string | null {
    if (type !== NoisePayloadType.DELIVERED && type !== NoisePayloadType.READ_RECEIPT) {
      return null;
    }
    const payload: Uint8Array = NostrEmbeddedBitChat.ackPayload(type, messageID);
    return NostrEmbeddedBitChat.encodeEmbedded(payload,
      NostrEmbeddedBitChat.normalizeRecipientPeerID(recipientPeerID), senderPeerID, nowMs);
  }

  /**
   * Build a "bitchat1:" ack without an embedded recipient peer ID
   * (geohash DMs). The sender ID is fresh random per envelope; see the
   * file header for the unlinkability rationale.
   */
  static encodeAckForNostrNoRecipient(type: NoisePayloadType, messageID: string,
    random: NostrRandomSource, nowMs: number): string | null {
    if (type !== NoisePayloadType.DELIVERED && type !== NoisePayloadType.READ_RECEIPT) {
      return null;
    }
    const payload: Uint8Array = NostrEmbeddedBitChat.ackPayload(type, messageID);
    const packet: BitchatPacket = new BitchatPacket(1, MessageType.NOISE_ENCRYPTED,
      random.nextBytes(NostrEmbeddedBitChat.SENDER_ID_SIZE), null, nowMs, payload,
      null, PkTtl.MESSAGE_TTL_HOPS, null);
    return NostrEmbeddedBitChat.encodePacket(packet);
  }

  /**
   * Decode a "bitchat1:" content string back into its packet and Noise
   * payload. Null when the prefix, base64, binary packet, packet type
   * or Noise payload is invalid.
   */
  static decodeEmbedded(content: string): EmbeddedBitChatMessage | null {
    if (!content.startsWith(EMBEDDED_BITCHAT_PREFIX)) {
      return null;
    }
    const data: Uint8Array =
      ByteUtils.base64Decode(content.substring(EMBEDDED_BITCHAT_PREFIX.length));
    const packet: BitchatPacket | null = BinaryProtocol.decode(data);
    if (packet === null) {
      return null;
    }
    if (packet.type !== MessageType.NOISE_ENCRYPTED) {
      return null;
    }
    const payload: NoisePayload | null = NoisePayload.decode(packet.payload);
    if (payload === null) {
      return null;
    }
    return new EmbeddedBitChatMessage(packet, payload);
  }

  /**
   * Normalize a recipient peer ID (iOS parity): a 64-hex Noise key
   * resolves to its 16-hex mesh peer ID, a mesh peer ID passes through
   * lowercased, anything else is returned verbatim.
   */
  static normalizeRecipientPeerID(recipientPeerID: string): string {
    const clean: string = recipientPeerID.trim().toLowerCase();
    if (ContactIdentityResolver.isNoiseKeyHex(clean)) {
      const derived: string | null = ContactIdentityResolver.peerIdForNoiseKeyHex(clean);
      return derived !== null ? derived : clean;
    }
    if (ContactIdentityResolver.isMeshPeerId(clean)) {
      return clean;
    }
    return recipientPeerID;
  }

  /** [type_byte][message_id_utf8] ack payload. */
  private static ackPayload(type: NoisePayloadType, messageID: string): Uint8Array {
    const idBytes: Uint8Array = ByteUtils.utf8Encode(messageID);
    const payload: Uint8Array = new Uint8Array(1 + idBytes.length);
    payload[0] = type;
    payload.set(idBytes, 1);
    return payload;
  }

  private static encodeEmbedded(payload: Uint8Array, recipientIDHex: string,
    senderPeerID: string, nowMs: number): string | null {
    const packet: BitchatPacket = new BitchatPacket(1, MessageType.NOISE_ENCRYPTED,
      ByteUtils.hexToBytes(senderPeerID), ByteUtils.hexToBytes(recipientIDHex), nowMs,
      payload, null, PkTtl.MESSAGE_TTL_HOPS, null);
    return NostrEmbeddedBitChat.encodePacket(packet);
  }

  private static encodePacket(packet: BitchatPacket): string | null {
    const data: Uint8Array | null = BinaryProtocol.encode(packet);
    if (data === null) {
      return null;
    }
    return EMBEDDED_BITCHAT_PREFIX + ByteUtils.base64UrlEncode(data);
  }
}
