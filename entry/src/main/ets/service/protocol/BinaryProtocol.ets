/**
 * Binary packet codec for the bitchat wire format (v1 and v2), 100%
 * backward compatible with the iOS version. Mirrors bitchat-android
 * BinaryProtocol.kt byte-for-byte.
 *
 * Header (14 bytes for v1, 16 bytes for v2):
 * - Version: 1 byte
 * - Type: 1 byte
 * - TTL: 1 byte
 * - Timestamp: 8 bytes (UInt64, big-endian)
 * - Flags: 1 byte (bit0 hasRecipient, bit1 hasSignature, bit2 isCompressed, bit3 hasRoute)
 * - PayloadLength: 2 bytes (v1) / 4 bytes (v2), big-endian
 *
 * Variable sections:
 * - SenderID: 8 bytes (fixed)
 * - RecipientID: 8 bytes (if hasRecipient)
 * - Route: 1 byte count + count*8 bytes (v2, if hasRoute)
 * - Payload: variable (includes original size prefix if compressed)
 * - Signature: 64 bytes (if hasSignature)
 */
import { ByteUtils, ByteWriter, ByteReader } from '../../common/ByteUtils';
import { WireConstants } from '../../common/ProtocolConstants';
import { BitchatPacket, WirePayload } from '../../model/BitchatPacket';
import { PacketPayloadLimits } from './PacketPayloadLimits';
import { MessagePadding } from './MessagePadding';
import { CompressionUtil } from './Compression';

export class BinaryProtocol {
  static readonly HAS_RECIPIENT: number = 0x01;
  static readonly HAS_SIGNATURE: number = 0x02;
  static readonly IS_COMPRESSED: number = 0x04;
  static readonly HAS_ROUTE: number = 0x08;

  private static getHeaderSize(version: number): number {
    return version === 1 ? WireConstants.HEADER_SIZE_V1 : WireConstants.HEADER_SIZE_V2;
  }

  static encode(packet: BitchatPacket, padding: boolean = true): Uint8Array | null {
    try {
      if (packet.payload.length > WireConstants.MAX_PAYLOAD_LENGTH) {
        return null;
      }

      let payload: Uint8Array = packet.payload;
      let originalPayloadSize: number = 0;
      let hasOriginalSize: boolean = false;
      let isCompressed: boolean = false;

      // Re-encode of a decoded packet: reuse the originator's bytes so a
      // signature over a re-encoding keeps verifying across DEFLATE encoders.
      const wire: WirePayload | null = packet.wirePayload;
      if (wire !== null && ByteUtils.equals(wire.forPayload, packet.payload)) {
        if (wire.compressed) {
          payload = wire.bytes;
          originalPayloadSize = packet.payload.length;
          hasOriginalSize = true;
          isCompressed = true;
        }
        // Uncompressed on the wire: keep it that way.
      } else if (CompressionUtil.shouldCompress(payload)) {
        const compressed: Uint8Array | null = CompressionUtil.compress(payload);
        if (compressed !== null) {
          originalPayloadSize = payload.length;
          payload = compressed;
          isCompressed = true;
        }
      }

      const headerSize: number = BinaryProtocol.getHeaderSize(packet.version);
      const sizeFieldBytes: number = isCompressed ? (packet.version >= 2 ? 4 : 2) : 0;
      const payloadDataSize: number = payload.length + sizeFieldBytes;

      if (packet.version < 2) {
        if (payloadDataSize > 0xFFFF || (hasOriginalSize ? originalPayloadSize : 0) > 0xFFFF) {
          return null;
        }
      }

      let flags: number = 0;
      if (packet.recipientId !== null) {
        flags |= BinaryProtocol.HAS_RECIPIENT;
      }
      if (packet.signature !== null) {
        flags |= BinaryProtocol.HAS_SIGNATURE;
      }
      if (isCompressed) {
        flags |= BinaryProtocol.IS_COMPRESSED;
      }
      const hasRoute: boolean = packet.route !== null && packet.route.length > 0 && packet.version >= 2;
      if (hasRoute) {
        flags |= BinaryProtocol.HAS_ROUTE;
      }

      const writer: ByteWriter = new ByteWriter(headerSize + WireConstants.SENDER_ID_SIZE +
        WireConstants.RECIPIENT_ID_SIZE + payloadDataSize + WireConstants.SIGNATURE_SIZE + 16);

      // Header
      writer.putByte(packet.version & 0xFF);
      writer.putByte(packet.type & 0xFF);
      writer.putByte(packet.ttl & 0xFF);
      if (packet.timestampRaw !== null) {
        writer.putBytes(packet.timestampRaw);
      } else {
        writer.putU64BE(packet.timestamp);
      }
      writer.putByte(flags);
      if (packet.version >= 2) {
        writer.putU32BE(payloadDataSize);
      } else {
        writer.putU16BE(payloadDataSize);
      }

      // SenderID (exactly 8 bytes, zero-padded)
      BinaryProtocol.putFixedId(writer, packet.senderId, WireConstants.SENDER_ID_SIZE);

      // RecipientID (if present)
      if (packet.recipientId !== null) {
        BinaryProtocol.putFixedId(writer, packet.recipientId, WireConstants.RECIPIENT_ID_SIZE);
      }

      // Route (optional, v2+ only): 1 byte count + N*8 bytes
      if (hasRoute && packet.route !== null) {
        const count: number = Math.min(packet.route.length, 255);
        writer.putByte(count);
        for (let i: number = 0; i < count; i++) {
          BinaryProtocol.putFixedId(writer, packet.route[i], WireConstants.SENDER_ID_SIZE);
        }
      }

      // Payload (with original size prepended if compressed)
      if (isCompressed) {
        if (packet.version >= 2) {
          writer.putU32BE(originalPayloadSize);
        } else {
          writer.putU16BE(originalPayloadSize);
        }
      }
      writer.putBytes(payload);

      // Signature (if present, truncated to 64 bytes)
      if (packet.signature !== null) {
        const sig: Uint8Array = packet.signature.length > WireConstants.SIGNATURE_SIZE
          ? packet.signature.subarray(0, WireConstants.SIGNATURE_SIZE)
          : packet.signature;
        writer.putBytes(sig);
      }

      const result: Uint8Array = writer.toUint8Array();

      // Apply padding if requested (iOS-compatible selective padding for privacy)
      if (padding) {
        const optimalSize: number = MessagePadding.optimalBlockSize(result.length);
        return MessagePadding.pad(result, optimalSize);
      }
      return result;
    } catch (e) {
      return null;
    }
  }

  private static putFixedId(writer: ByteWriter, id: Uint8Array, size: number): void {
    const n: number = Math.min(id.length, size);
    for (let i: number = 0; i < n; i++) {
      writer.putByte(id[i]);
    }
    for (let i: number = n; i < size; i++) {
      writer.putByte(0);
    }
  }

  static decode(data: Uint8Array): BitchatPacket | null {
    // Try decode as-is first (robust when padding wasn't applied) - iOS fix
    const direct: BitchatPacket | null = BinaryProtocol.decodeCore(data);
    if (direct !== null) {
      return direct;
    }
    // If that fails, try after removing padding
    const unpadded: Uint8Array = MessagePadding.unpad(data);
    if (unpadded.length === data.length) {
      return null;
    }
    return BinaryProtocol.decodeCore(unpadded);
  }

  /**
   * Canonical re-encoding used for signing/verification: no signature, fixed
   * TTL (0) because TTL changes during relay, original wire bytes preserved.
   */
  static toBinaryDataForSigning(packet: BitchatPacket): Uint8Array | null {
    const unsigned: BitchatPacket = new BitchatPacket(
      packet.version,
      packet.type,
      packet.senderId,
      packet.recipientId,
      packet.timestamp,
      packet.payload,
      null,
      0,
      packet.route
    );
    unsigned.wirePayload = packet.wirePayload;
    unsigned.timestampRaw = packet.timestampRaw === null ? null : packet.timestampRaw.slice(0);
    return BinaryProtocol.encode(unsigned);
  }

  private static decodeCore(raw: Uint8Array): BitchatPacket | null {
    try {
      if (raw.length < WireConstants.HEADER_SIZE_V1 + WireConstants.SENDER_ID_SIZE) {
        return null;
      }
      const reader: ByteReader = new ByteReader(raw);

      const version: number = reader.getByte();
      if (version !== 1 && version !== 2) {
        return null;
      }
      const headerSize: number = BinaryProtocol.getHeaderSize(version);

      const type: number = reader.getByte();
      const ttl: number = reader.getByte();
      const timestampRaw: Uint8Array = reader.getU64Bytes();
      const timestamp: number = ByteUtils.u64BytesToNumber(timestampRaw);

      const flags: number = reader.getByte();
      const hasRecipient: boolean = (flags & BinaryProtocol.HAS_RECIPIENT) !== 0;
      const hasSignature: boolean = (flags & BinaryProtocol.HAS_SIGNATURE) !== 0;
      const isCompressed: boolean = (flags & BinaryProtocol.IS_COMPRESSED) !== 0;
      // HAS_ROUTE is only valid for v2+ packets; ignore the flag for v1
      const hasRoute: boolean = version >= 2 && (flags & BinaryProtocol.HAS_ROUTE) !== 0;

      const payloadLength: number = version >= 2 ? reader.getU32BE() : reader.getU16BE();
      if (payloadLength > WireConstants.MAX_PAYLOAD_LENGTH) {
        return null;
      }

      // Per-type ceiling on the decoded payload, compressed or not, checked
      // before any allocation.
      const maxPayloadSize: number = PacketPayloadLimits.maxPayloadBytes(type);

      let expectedSize: number = headerSize + WireConstants.SENDER_ID_SIZE + payloadLength;
      if (hasRecipient) {
        expectedSize += WireConstants.RECIPIENT_ID_SIZE;
      }
      let routeCount: number = 0;
      if (hasRoute) {
        const routeOffset: number = headerSize + WireConstants.SENDER_ID_SIZE +
          (hasRecipient ? WireConstants.RECIPIENT_ID_SIZE : 0);
        if (raw.length >= routeOffset + 1) {
          routeCount = raw[routeOffset] & 0xFF;
        }
        expectedSize += 1 + routeCount * WireConstants.SENDER_ID_SIZE;
      }
      if (hasSignature) {
        expectedSize += WireConstants.SIGNATURE_SIZE;
      }
      if (raw.length < expectedSize) {
        return null;
      }

      const senderId: Uint8Array = reader.getBytes(WireConstants.SENDER_ID_SIZE);
      const recipientId: Uint8Array | null = hasRecipient
        ? reader.getBytes(WireConstants.RECIPIENT_ID_SIZE) : null;

      const route: Uint8Array[] | null = hasRoute
        ? BinaryProtocol.readRoute(reader) : null;

      let receivedCompressed: Uint8Array | null = null;
      let payload: Uint8Array;
      if (isCompressed) {
        const lengthFieldBytes: number = version >= 2 ? 4 : 2;
        if (payloadLength < lengthFieldBytes) {
          return null;
        }
        const originalSize: number = version >= 2 ? reader.getU32BE() : reader.getU16BE();
        if (originalSize <= 0 || originalSize > maxPayloadSize) {
          return null;
        }
        const compressedSize: number = payloadLength - lengthFieldBytes;
        if (compressedSize === 0) {
          return null;
        }
        // Security check: compression bomb protection
        if (originalSize > compressedSize * PacketPayloadLimits.MAX_DEFLATE_RATIO) {
          return null;
        }
        const compressedPayload: Uint8Array = reader.getBytes(compressedSize);
        const expanded: Uint8Array | null = CompressionUtil.decompress(compressedPayload, originalSize);
        if (expanded === null || expanded.length !== originalSize) {
          return null;
        }
        receivedCompressed = compressedPayload;
        payload = expanded;
      } else {
        // Uncompressed payloads get the same ceiling, or a large frame could
        // arrive as small compressed fragments and be reassembled.
        if (payloadLength > maxPayloadSize) {
          return null;
        }
        payload = reader.getBytes(payloadLength);
      }

      const signature: Uint8Array | null = hasSignature
        ? reader.getBytes(WireConstants.SIGNATURE_SIZE) : null;

      const packet: BitchatPacket = new BitchatPacket(
        version, type, senderId, recipientId, timestamp, payload, signature, ttl, route
      );
      packet.timestampRaw = timestampRaw;
      packet.wirePayload = new WirePayload(
        receivedCompressed === null ? payload : receivedCompressed,
        receivedCompressed !== null,
        payload
      );
      return packet;
    } catch (e) {
      return null;
    }
  }

  private static readRoute(reader: ByteReader): Uint8Array[] | null {
    const count: number = reader.getByte();
    if (count === 0) {
      return null; // Treat empty route list as null to enforce canonical form
    }
    const hops: Uint8Array[] = [];
    for (let i: number = 0; i < count; i++) {
      hops.push(reader.getBytes(WireConstants.SENDER_ID_SIZE));
    }
    return hops;
  }
}
