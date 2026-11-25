/**
 * Deterministic packet ID helper for sync purposes.
 * Mirrors bitchat-android PacketIdUtil.kt: SHA-256 over a canonical subset of
 * packet fields [type | senderID | timestamp u64BE | payload], truncated to a
 * 16-byte (128-bit) ID.
 */
import { BitchatPacket } from '../../model/BitchatPacket';
import { ByteUtils } from '../../common/ByteUtils';

export class PacketIdUtil {
  static computeIdBytes(packet: BitchatPacket): Uint8Array {
    const ts: number = Math.floor(packet.timestamp);
    const preimage: Uint8Array = new Uint8Array(1 + packet.senderId.length + 8 + packet.payload.length);
    let offset: number = 0;
    preimage[offset] = packet.type & 0xFF;
    offset += 1;
    preimage.set(packet.senderId, offset);
    offset += packet.senderId.length;
    // Timestamp as 8 bytes big-endian (u64). When the exact wire bytes are
    // known (decoded or >2^53 values) hash them verbatim; otherwise derive
    // them from the double.
    if (packet.timestampRaw !== null) {
      preimage.set(packet.timestampRaw, offset);
      offset += 8;
    } else {
      for (let i: number = 7; i >= 0; i--) {
        preimage[offset] = Math.floor(ts / Math.pow(2, i * 8)) % 256;
        offset += 1;
      }
    }
    preimage.set(packet.payload, offset);
    const digest: Uint8Array = ByteUtils.sha256(preimage);
    return digest.slice(0, 16); // 128-bit ID
  }

  static computeIdHex(packet: BitchatPacket): string {
    return ByteUtils.bytesToHex(PacketIdUtil.computeIdBytes(packet));
  }
}
