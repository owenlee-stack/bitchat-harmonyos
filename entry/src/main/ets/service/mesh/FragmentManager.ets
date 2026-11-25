/**
 * Message fragmentation and reassembly - mirrors bitchat-android
 * FragmentManager.kt (100% iOS compatible).
 *
 * - Same fragment payload structure (13-byte header + data)
 * - Same MTU thresholds and fragment sizes
 * - Same reassembly logic and timeout handling
 */
import { BitchatPacket, MessageType } from '../../model/BitchatPacket';
import { FragmentPayload } from '../../model/FragmentModels';
import { FragmentationConstants } from '../../common/ProtocolConstants';
import { ByteUtils } from '../../common/ByteUtils';
import { BinaryProtocol } from '../protocol/BinaryProtocol';
import { MessagePadding } from '../protocol/MessagePadding';

class FragmentSetMetadata {
  readonly originalType: number;
  readonly total: number;
  readonly timestamp: number;

  constructor(originalType: number, total: number, timestamp: number) {
    this.originalType = originalType;
    this.total = total;
    this.timestamp = timestamp;
  }
}

export class FragmentManager {
  /** iOS equivalent: incomingFragments: [String: [Int: Data]]. */
  private incomingFragments: Map<string, Map<number, Uint8Array>> = new Map();
  /** iOS equivalent: fragmentMetadata: [String: (type: UInt8, total: Int, timestamp: Date)]. */
  private fragmentMetadata: Map<string, FragmentSetMetadata> = new Map();
  private fragmentCumulativeSize: Map<string, number> = new Map();
  private globalBufferedBytes: number = 0;

  /**
   * Create fragments from a large packet. Generic/public packets retain the
   * full UInt16 fragment-count range; private media callers pass a tighter cap.
   */
  createFragments(packet: BitchatPacket, maxFragments: number = 0xFFFF): BitchatPacket[] {
    try {
      if (maxFragments < 1 || maxFragments > 0xFFFF) {
        return [];
      }
      const encoded: Uint8Array | null = BinaryProtocol.encode(packet);
      if (encoded === null) {
        return [];
      }

      // Fragment the unpadded frame; each fragment will be encoded (and
      // padded) independently - iOS fix.
      const fullData: Uint8Array = MessagePadding.unpad(encoded);

      // iOS logic: if data.count > 512 && packet.type != fragment.
      if (fullData.length <= FragmentationConstants.FRAGMENT_SIZE_THRESHOLD) {
        return [packet]; // No fragmentation needed
      }

      const fragmentID: Uint8Array = FragmentPayload.generateFragmentID();

      // Packet = Header + Sender + Recipient + Route + FragmentHeader +
      // Payload + PaddingBuffer. Header sizes mirror the iOS sizing table
      // (13/15) so fragment counts match the reference clients byte-for-byte.
      const hasRoute: boolean = packet.route !== null;
      const version: number = hasRoute ? 2 : 1;
      const headerSize: number = version === 2 ? 15 : 13;
      const senderSize: number = 8;
      const recipientSize: number = packet.recipientId !== null ? 8 : 0;
      // Route: 1 byte count + 8 bytes per hop.
      const routeSize: number = hasRoute && packet.route !== null ? 1 + packet.route.length * 8 : 0;
      const fragmentHeaderSize: number = FragmentPayload.HEADER_SIZE;
      const paddingBuffer: number = 16; // MessagePadding.optimalBlockSize adds 16 bytes overhead

      // 512 - Overhead
      const packetOverhead: number = headerSize + senderSize + recipientSize + routeSize +
        fragmentHeaderSize + paddingBuffer;
      const maxDataSize: number = Math.min(512 - packetOverhead, FragmentationConstants.MAX_FRAGMENT_SIZE);

      if (maxDataSize <= 0) {
        return [];
      }

      const requiredFragments: number = Math.ceil(fullData.length / maxDataSize);
      if (requiredFragments > maxFragments) {
        return [];
      }

      const fragments: BitchatPacket[] = [];
      let offset: number = 0;
      let index: number = 0;
      while (offset < fullData.length) {
        const endOffset: number = Math.min(offset + maxDataSize, fullData.length);
        const fragmentData: Uint8Array = fullData.slice(offset, endOffset);

        const fragmentPayload: FragmentPayload = new FragmentPayload(
          fragmentID, index, requiredFragments, packet.type, fragmentData);

        // Fragments inherit the source route and use v2 if routed.
        const fragmentPacket: BitchatPacket = new BitchatPacket(
          version,
          MessageType.FRAGMENT,
          packet.senderId,
          packet.recipientId,
          packet.timestamp,
          fragmentPayload.encode(),
          null,
          packet.ttl,
          packet.route);
        fragmentPacket.timestampRaw = packet.timestampRaw === null ? null : packet.timestampRaw.slice(0);
        fragments.push(fragmentPacket);

        offset = endOffset;
        index += 1;
      }

      return fragments;
    } catch (e) {
      return [];
    }
  }

  /**
   * Handle an incoming fragment. Returns the fully reassembled packet with its
   * TTL suppressed to 0 (iOS: do not relay reassembled packets), or null while
   * the set is still incomplete / invalid.
   */
  handleFragment(packet: BitchatPacket, nowMs: number = Date.now()): BitchatPacket | null {
    // iOS: guard packet.payload.count > 13.
    if (packet.payload.length < FragmentPayload.HEADER_SIZE) {
      return null;
    }

    try {
      const fragmentPayload: FragmentPayload | null = FragmentPayload.decode(packet.payload);
      if (fragmentPayload === null || !fragmentPayload.isValid()) {
        return null;
      }

      const fragmentIDString: string = fragmentPayload.getFragmentIDString();

      if (fragmentPayload.total > FragmentationConstants.MAX_FRAGMENTS_PER_ID) {
        return null;
      }

      const existingMetadata: FragmentSetMetadata | undefined = this.fragmentMetadata.get(fragmentIDString);
      if (existingMetadata !== undefined) {
        if (existingMetadata.total !== fragmentPayload.total ||
          existingMetadata.originalType !== fragmentPayload.originalType) {
          // Reject the fragment, keep the stream. Nothing from a conflicting
          // header is ever stored; a stream that genuinely stalls is reaped by
          // the timeout sweep.
          return null;
        }
      }

      const isNewSet: boolean = !this.incomingFragments.has(fragmentIDString);
      if (isNewSet) {
        if (this.incomingFragments.size >= FragmentationConstants.MAX_ACTIVE_FRAGMENT_SETS) {
          return null;
        }
        this.incomingFragments.set(fragmentIDString, new Map<number, Uint8Array>());
        this.fragmentMetadata.set(fragmentIDString,
          new FragmentSetMetadata(fragmentPayload.originalType, fragmentPayload.total, nowMs));
        this.fragmentCumulativeSize.set(fragmentIDString, 0);
      }

      const fragmentMap: Map<number, Uint8Array> | undefined = this.incomingFragments.get(fragmentIDString);
      if (fragmentMap === undefined) {
        this.removeFragmentSet(fragmentIDString);
        return null;
      }

      const currentSizeOpt: number | undefined = this.fragmentCumulativeSize.get(fragmentIDString);
      if (currentSizeOpt === undefined) {
        this.removeFragmentSet(fragmentIDString);
        return null;
      }
      const currentSize: number = currentSizeOpt;

      const heldEntry: Uint8Array | undefined = fragmentMap.get(fragmentPayload.index);
      if (heldEntry !== undefined && !ByteUtils.equals(heldEntry, fragmentPayload.data)) {
        // Duplicate delivery is normal in a mesh, but one index of a stream
        // must always carry the same bytes; never overwrite bytes already
        // received from the real sender.
        return null;
      }
      const oldEntrySize: number = heldEntry !== undefined ? heldEntry.length : 0;
      const newSize: number = currentSize - oldEntrySize + fragmentPayload.data.length;
      if (newSize > FragmentationConstants.MAX_FRAGMENT_TOTAL_BYTES) {
        // Only a set this fragment itself created has nothing worth
        // preserving. An oversized fragment must not destroy an assembly it
        // did not start.
        if (isNewSet) {
          this.removeFragmentSet(fragmentIDString);
        }
        return null;
      }

      const delta: number = fragmentPayload.data.length - oldEntrySize;
      if (this.globalBufferedBytes + delta > FragmentationConstants.MAX_GLOBAL_FRAGMENT_TOTAL_BYTES) {
        if (isNewSet) {
          this.removeFragmentSet(fragmentIDString);
        }
        return null;
      }

      fragmentMap.set(fragmentPayload.index, fragmentPayload.data);
      this.fragmentCumulativeSize.set(fragmentIDString, newSize);
      this.globalBufferedBytes += delta;

      const metadata: FragmentSetMetadata | undefined = this.fragmentMetadata.get(fragmentIDString);
      const expectedTotal: number = metadata !== undefined ? metadata.total : fragmentPayload.total;
      if (fragmentMap.size === expectedTotal) {
        // iOS reassembly logic: for i in 0..<total, append whichever fragment
        // is present (missing indices are skipped).
        let reassembledLength: number = 0;
        for (let i: number = 0; i < expectedTotal; i++) {
          const piece: Uint8Array | undefined = fragmentMap.get(i);
          if (piece !== undefined) {
            reassembledLength += piece.length;
          }
        }
        const reassembledData: Uint8Array = new Uint8Array(reassembledLength);
        let writeOffset: number = 0;
        for (let i: number = 0; i < expectedTotal; i++) {
          const piece: Uint8Array | undefined = fragmentMap.get(i);
          if (piece !== undefined) {
            reassembledData.set(piece, writeOffset);
            writeOffset += piece.length;
          }
        }

        const originalPacket: BitchatPacket | null = BinaryProtocol.decode(reassembledData);
        if (originalPacket !== null) {
          this.removeFragmentSet(fragmentIDString);
          const suppressedTtlPacket: BitchatPacket = new BitchatPacket(
            originalPacket.version,
            originalPacket.type,
            originalPacket.senderId,
            originalPacket.recipientId,
            originalPacket.timestamp,
            originalPacket.payload,
            originalPacket.signature,
            0,
            originalPacket.route);
          suppressedTtlPacket.wirePayload = originalPacket.wirePayload;
          suppressedTtlPacket.timestampRaw = originalPacket.timestampRaw;
          return suppressedTtlPacket;
        }
      }
    } catch (e) {
      return null;
    }
    return null;
  }

  private removeFragmentSet(fragmentIDString: string): void {
    this.incomingFragments.delete(fragmentIDString);
    this.fragmentMetadata.delete(fragmentIDString);
    const bytesOpt: number | undefined = this.fragmentCumulativeSize.get(fragmentIDString);
    this.fragmentCumulativeSize.delete(fragmentIDString);
    const bytes: number = bytesOpt !== undefined ? bytesOpt : 0;
    if (bytes !== 0) {
      this.globalBufferedBytes = Math.max(this.globalBufferedBytes - bytes, 0);
    }
  }

  /**
   * iOS cleanup - exactly matching performCleanup(): clean fragment sets older
   * than 30 seconds. The mesh service owns the periodic timer (10s interval).
   */
  cleanupOldFragments(nowMs: number = Date.now()): void {
    const cutoff: number = nowMs - FragmentationConstants.FRAGMENT_TIMEOUT_MS;
    const expired: string[] = [];
    this.fragmentMetadata.forEach((meta: FragmentSetMetadata, key: string): void => {
      if (meta.timestamp < cutoff) {
        expired.push(key);
      }
    });
    for (let i: number = 0; i < expired.length; i++) {
      this.removeFragmentSet(expired[i]);
    }
  }

  getDebugInfo(): string {
    const lines: string[] = [];
    lines.push('=== Fragment Manager Debug Info (iOS Compatible) ===');
    lines.push('Active Fragment Sets: ' + this.incomingFragments.size);
    lines.push('Fragment Size Threshold: ' + FragmentationConstants.FRAGMENT_SIZE_THRESHOLD + ' bytes');
    lines.push('Max Fragment Size: ' + FragmentationConstants.MAX_FRAGMENT_SIZE + ' bytes');
    lines.push('Global Buffered Bytes: ' + this.globalBufferedBytes);
    this.fragmentMetadata.forEach((meta: FragmentSetMetadata, key: string): void => {
      const map: Map<number, Uint8Array> | undefined = this.incomingFragments.get(key);
      const received: number = map !== undefined ? map.size : 0;
      const bytes: number = this.fragmentCumulativeSize.get(key) ?? 0;
      lines.push('  - ' + key + ': ' + received + '/' + meta.total +
        ' fragments, bytes=' + bytes + ', type: ' + meta.originalType);
    });
    return lines.join('\n');
  }

  clearAllFragments(): void {
    this.incomingFragments.clear();
    this.fragmentMetadata.clear();
    this.fragmentCumulativeSize.clear();
    this.globalBufferedBytes = 0;
  }
}
