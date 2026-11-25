/**
 * On-the-wire packet model - mirrors bitchat-android BinaryProtocol.kt.
 * Encoding/decoding lives in service/protocol/BinaryProtocol.ets to keep this
 * model dependency-free (Android has the same split across model/protocol).
 */
import { WireConstants } from '../common/ProtocolConstants';
import { ByteUtils } from '../common/ByteUtils';

export enum MessageType {
  ANNOUNCE = 0x01,
  MESSAGE = 0x02,
  LEAVE = 0x03,
  NOISE_HANDSHAKE = 0x10,
  NOISE_ENCRYPTED = 0x11,
  FRAGMENT = 0x20,
  REQUEST_SYNC = 0x21,
  FILE_TRANSFER = 0x22,
  VOICE_FRAME = 0x29,
}

export function messageTypeFromValue(value: number): MessageType | null {
  const values: MessageType[] = [
    MessageType.ANNOUNCE, MessageType.MESSAGE, MessageType.LEAVE,
    MessageType.NOISE_HANDSHAKE, MessageType.NOISE_ENCRYPTED,
    MessageType.FRAGMENT, MessageType.REQUEST_SYNC,
    MessageType.FILE_TRANSFER, MessageType.VOICE_FRAME
  ];
  for (let i: number = 0; i < values.length; i++) {
    if (values[i] === value) {
      return values[i];
    }
  }
  return null;
}

export function specialRecipientBroadcast(): Uint8Array {
  return new Uint8Array([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
}

/**
 * Payload bytes exactly as they arrived on the wire. Reused on re-encode so a
 * DEFLATE stream produced by a different encoder never breaks signatures.
 */
export class WirePayload {
  readonly bytes: Uint8Array;
  readonly compressed: boolean;
  readonly forPayload: Uint8Array;

  constructor(bytes: Uint8Array, compressed: boolean, forPayload: Uint8Array) {
    this.bytes = bytes;
    this.compressed = compressed;
    this.forPayload = forPayload;
  }
}

export class BitchatPacket {
  version: number;
  /** Raw wire type byte; unknown types must stay relayable. */
  type: number;
  senderId: Uint8Array;
  recipientId: Uint8Array | null;
  timestamp: number;
  /**
   * Exact 8-byte wire form of `timestamp`. Doubles cannot represent u64
   * timestamps beyond 2^53 (e.g. the 0x0102030405060708 golden vector), so
   * callers that build or receive such packets keep the raw bytes here;
   * BinaryProtocol uses them verbatim on re-encode.
   */
  timestampRaw: Uint8Array | null;
  payload: Uint8Array;
  signature: Uint8Array | null;
  ttl: number;
  route: Uint8Array[] | null;
  wirePayload: WirePayload | null;

  constructor(version: number, type: number, senderId: Uint8Array,
    recipientId: Uint8Array | null, timestamp: number, payload: Uint8Array,
    signature: Uint8Array | null, ttl: number, route: Uint8Array[] | null) {
    this.version = version;
    this.type = type;
    this.senderId = senderId;
    this.recipientId = recipientId;
    this.timestamp = timestamp;
    this.timestampRaw = null;
    this.payload = payload;
    this.signature = signature;
    this.ttl = ttl;
    this.route = route;
    this.wirePayload = null;
  }

  static isBroadcastRecipient(recipientId: Uint8Array | null): boolean {
    if (recipientId === null) {
      return false;
    }
    for (let i: number = 0; i < WireConstants.RECIPIENT_ID_SIZE; i++) {
      if (recipientId[i] !== 0xFF) {
        return false;
      }
    }
    return true;
  }

  static equals(a: BitchatPacket, b: BitchatPacket): boolean {
    if (a.version !== b.version || a.type !== b.type || a.ttl !== b.ttl || a.timestamp !== b.timestamp) {
      return false;
    }
    if (a.timestampRaw !== null && b.timestampRaw !== null &&
      !ByteUtils.equals(a.timestampRaw, b.timestampRaw)) {
      return false;
    }
    if (!ByteUtils.equals(a.senderId, b.senderId)) {
      return false;
    }
    if (!ByteUtils.equals(a.payload, b.payload)) {
      return false;
    }
    if ((a.recipientId === null) !== (b.recipientId === null)) {
      return false;
    }
    if (a.recipientId !== null && b.recipientId !== null && !ByteUtils.equals(a.recipientId, b.recipientId)) {
      return false;
    }
    if ((a.signature === null) !== (b.signature === null)) {
      return false;
    }
    if (a.signature !== null && b.signature !== null && !ByteUtils.equals(a.signature, b.signature)) {
      return false;
    }
    if ((a.route === null) !== (b.route === null)) {
      return false;
    }
    if (a.route !== null && b.route !== null) {
      if (a.route.length !== b.route.length) {
        return false;
      }
      for (let i: number = 0; i < a.route.length; i++) {
        if (!ByteUtils.equals(a.route[i], b.route[i])) {
          return false;
        }
      }
    }
    return true;
  }
}
