/**
 * Receive-side ceilings on how large a packet's payload may be, per type.
 * Mirrors bitchat-android PacketPayloadLimits.kt (and iOS bitchat#1719).
 * Receive-side only: senders are unchanged.
 */
import { MessageType, messageTypeFromValue } from '../../model/BitchatPacket';
import { WireConstants } from '../../common/ProtocolConstants';

export class PacketPayloadLimits {
  /**
   * Raw DEFLATE's hard expansion ceiling: every 258-byte match costs at least
   * a 1-bit length code plus a 1-bit distance code. A declared original size
   * beyond this multiple of the compressed bytes cannot be produced by any
   * stream, so it is rejected before the output buffer is allocated.
   */
  static readonly MAX_DEFLATE_RATIO: number = 1032;

  private static readonly FRAGMENT_BYTES: number = 1280;
  private static readonly CONTROL_BYTES: number = 4 * 1024;
  private static readonly REQUEST_SYNC_BYTES: number = 8 * 1024;
  private static readonly ENVELOPE_BYTES: number = 64 * 1024;
  private static readonly TWICE_V1_FRAME_BYTES: number = 128 * 1024;

  // iOS-only types this client does not decode yet; capped the same way iOS
  // caps them so they stay relayable without becoming a memory amplifier.
  private static readonly COURIER_ENVELOPE: number = 0x04;
  private static readonly BOARD_POST: number = 0x23;
  private static readonly PREKEY_BUNDLE: number = 0x24;
  private static readonly GROUP_MESSAGE: number = 0x25;
  private static readonly PING: number = 0x26;
  private static readonly PONG: number = 0x27;
  private static readonly NOSTR_CARRIER: number = 0x28;

  /** Largest decoded payload accepted for a packet of the given raw type byte. */
  static maxPayloadBytes(type: number): number {
    const known: MessageType | null = messageTypeFromValue(type);
    if (known !== null) {
      if (known === MessageType.FILE_TRANSFER || known === MessageType.NOISE_ENCRYPTED) {
        return WireConstants.MAX_PAYLOAD_LENGTH;
      }
      if (known === MessageType.MESSAGE) {
        return PacketPayloadLimits.TWICE_V1_FRAME_BYTES;
      }
      if (known === MessageType.REQUEST_SYNC) {
        return PacketPayloadLimits.REQUEST_SYNC_BYTES;
      }
      if (known === MessageType.FRAGMENT) {
        return PacketPayloadLimits.FRAGMENT_BYTES;
      }
      // ANNOUNCE, LEAVE, NOISE_HANDSHAKE, VOICE_FRAME
      return PacketPayloadLimits.CONTROL_BYTES;
    }
    if (type === PacketPayloadLimits.GROUP_MESSAGE) {
      return PacketPayloadLimits.TWICE_V1_FRAME_BYTES;
    }
    if (type === PacketPayloadLimits.COURIER_ENVELOPE || type === PacketPayloadLimits.NOSTR_CARRIER) {
      return PacketPayloadLimits.ENVELOPE_BYTES;
    }
    if (type === PacketPayloadLimits.BOARD_POST || type === PacketPayloadLimits.PREKEY_BUNDLE ||
      type === PacketPayloadLimits.PING || type === PacketPayloadLimits.PONG) {
      return PacketPayloadLimits.CONTROL_BYTES;
    }
    return PacketPayloadLimits.TWICE_V1_FRAME_BYTES;
  }
}
