/**
 * Gossip TLV helpers for embedding direct-neighbor peer IDs in ANNOUNCE
 * payloads (US2, T024). Mirrors bitchat-android GossipTLV.kt:
 * compact TLV [type=0x04][len=1 byte][value=N*8 bytes of peerIDs],
 * up to 10 unique neighbors (FR-008).
 */
import { ByteUtils } from '../../common/ByteUtils';

export class GossipTlv {
  static readonly DIRECT_NEIGHBORS_TYPE: number = 0x04;
  static readonly MAX_NEIGHBORS: number = 10;
  private static readonly PEER_ID_BYTES: number = 8;
  private static readonly PEER_ID_HEX_CHARS: number = 16;

  /**
   * Encode up to 10 unique peerIDs (16 hex chars) as the neighbors TLV.
   * An empty list still emits [0x04][0x00], matching the Android layout.
   */
  static encodeNeighbors(peerIds: string[]): Uint8Array {
    const unique: string[] = [];
    const seen: Set<string> = new Set();
    for (let i: number = 0; i < peerIds.length; i++) {
      const id: string = peerIds[i];
      if (seen.has(id)) {
        continue;
      }
      seen.add(id);
      unique.push(id);
      if (unique.length >= GossipTlv.MAX_NEIGHBORS) {
        break;
      }
    }
    const value: Uint8Array = new Uint8Array(unique.length * GossipTlv.PEER_ID_BYTES);
    for (let i: number = 0; i < unique.length; i++) {
      value.set(GossipTlv.peerIdToBytes(unique[i]), i * GossipTlv.PEER_ID_BYTES);
    }
    const out: Uint8Array = new Uint8Array(2 + value.length);
    out[0] = GossipTlv.DIRECT_NEIGHBORS_TYPE;
    out[1] = value.length;
    out.set(value, 2);
    return out;
  }

  /**
   * Scan a TLV-encoded ANNOUNCE payload and extract the neighbor peerIDs.
   * Returns null when the TLV is absent; an empty list when present but
   * empty; trailing partial IDs (fewer than 8 bytes) are ignored.
   */
  static decodeNeighborsFromAnnouncementPayload(payload: Uint8Array): string[] | null {
    let offset: number = 0;
    while (offset + 2 <= payload.length) {
      const type: number = payload[offset];
      const length: number = payload[offset + 1];
      offset += 2;
      if (offset + length > payload.length) {
        break;
      }
      if (type === GossipTlv.DIRECT_NEIGHBORS_TYPE) {
        const neighbors: string[] = [];
        let pos: number = offset;
        while (pos + GossipTlv.PEER_ID_BYTES <= offset + length) {
          neighbors.push(ByteUtils.bytesToHex(payload.slice(pos, pos + GossipTlv.PEER_ID_BYTES)));
          pos += GossipTlv.PEER_ID_BYTES;
        }
        return neighbors;
      }
      offset += length;
    }
    return null;
  }

  /** Lenient hex peerID -> 8 bytes, matching the Android parser (invalid digits become 0). */
  private static peerIdToBytes(peerId: string): Uint8Array {
    const clean: string = peerId.toLowerCase().substring(0, GossipTlv.PEER_ID_HEX_CHARS);
    const out: Uint8Array = new Uint8Array(GossipTlv.PEER_ID_BYTES);
    let idx: number = 0;
    let outPos: number = 0;
    while (idx + 1 < clean.length && outPos < GossipTlv.PEER_ID_BYTES) {
      const hi: number = GossipTlv.hexDigit(clean.charCodeAt(idx));
      const lo: number = GossipTlv.hexDigit(clean.charCodeAt(idx + 1));
      out[outPos] = (hi << 4) | lo;
      outPos += 1;
      idx += 2;
    }
    return out;
  }

  private static hexDigit(code: number): number {
    if (code >= 0x30 && code <= 0x39) {
      return code - 0x30;
    }
    if (code >= 0x61 && code <= 0x66) {
      return code - 0x61 + 10;
    }
    return 0;
  }
}
