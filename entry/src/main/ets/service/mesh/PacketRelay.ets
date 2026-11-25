/**
 * Controlled-flooding relay decisions (US3, T027) - implements FR-004:
 * TTL-bound flooding aligned with the Android relay optimization trio.
 *
 *  - Directed traffic (recipient set, not broadcast): deterministic TTL-1
 *    forwarding, never subset-fanned.
 *  - Dense graphs (>= DENSE_LINK_THRESHOLD links): broadcast packets are
 *    forwarded with TTL clamped to DENSE_TTL_CAP and a broadcast MESSAGE is
 *    fanned out to a deterministic log2(degree)-sized subset of links seeded
 *    by the message ID; the jitter span widens by DENSE_JITTER_MULTIPLIER.
 *  - Thin links (<= THIN_LINK_THRESHOLD): full remaining depth, no clamping.
 *  - ANNOUNCE / FRAGMENT packets always fan out to every candidate link.
 *  - Split horizon: the ingress link is always excluded from fanout.
 *  - Forwarding jitter: JITTER_MIN_MS..JITTER_MAX_MS before the send fires.
 *  - A duplicate packet arriving before the scheduled relay fires cancels it
 *    (first-arrival cancels the pending relay, no re-schedule).
 *  - REQUEST_SYNC (TTL 0 by construction) and expired-TTL packets never relay.
 *
 * The scheduler, cancel hook and RNG are injected so the decision semantics
 * run deterministically in the host contract harness. Free of device imports.
 */
import { BitchatPacket, MessageType, messageTypeFromValue } from '../../model/BitchatPacket';
import { RoutedPacket } from './PacketProcessor';
import { PacketIdUtil } from '../sync/PacketIdUtil';
import { RelayConstants } from '../../common/ProtocolConstants';
import { ByteUtils } from '../../common/ByteUtils';

export interface PacketRelayDelegate {
  /** IDs of all currently connected transport links. */
  getConnectedLinkIds(): string[];

  /** Send one relayed packet on a specific link. */
  sendOnLink(linkId: string, packet: BitchatPacket): boolean;
}

class PendingRelay {
  readonly handle: number;

  constructor(handle: number) {
    this.handle = handle;
  }
}

export class PacketRelay {
  private readonly myPeerID: string;
  private readonly delegate: PacketRelayDelegate;
  private readonly schedule: (delayMs: number, task: () => void) => number;
  private readonly cancel: (handle: number) => void;
  private readonly rng: () => number;
  private readonly pending: Map<string, PendingRelay> = new Map();
  private relayEnabled: boolean = true;
  private cancelledRelays: number = 0;

  constructor(myPeerID: string, delegate: PacketRelayDelegate,
    schedule: (delayMs: number, task: () => void) => number =
      (delayMs: number, task: () => void): number => {
        return setTimeout(task, delayMs);
      },
    cancel: (handle: number) => void = (handle: number): void => {
      clearTimeout(handle);
    },
    rng: () => number = Math.random) {
    this.myPeerID = myPeerID;
    this.delegate = delegate;
    this.schedule = schedule;
    this.cancel = cancel;
    this.rng = rng;
  }

  setRelayEnabled(enabled: boolean): void {
    this.relayEnabled = enabled;
  }

  /**
   * Entry point for relay decisions; only packets that stayed valid in the
   * packet processor reach this (its relay hook). The relay re-checks its own
   * exclusions (addressed to us, our own packets, sync/expired TTL).
   */
  considerRelay(routed: RoutedPacket): void {
    if (!this.relayEnabled) {
      return;
    }
    const packet: BitchatPacket = routed.packet;
    if (this.isPacketAddressedToMe(packet)) {
      return;
    }
    if (routed.peerID === this.myPeerID) {
      return;
    }
    const messageType: MessageType | null = messageTypeFromValue(packet.type);
    if (messageType === MessageType.REQUEST_SYNC) {
      // Sync negotiation is TTL 0 by construction and never relayed.
      return;
    }
    if (packet.ttl <= 0) {
      return;
    }

    // Split horizon: never send a packet back out on its ingress link.
    const linkIds: string[] = this.delegate.getConnectedLinkIds();
    const candidates: string[] = [];
    for (let i: number = 0; i < linkIds.length; i++) {
      if (linkIds[i] !== routed.ingressLinkID) {
        candidates.push(linkIds[i]);
      }
    }
    if (candidates.length === 0) {
      return;
    }

    const directed: boolean = packet.recipientId !== null &&
      !BitchatPacket.isBroadcastRecipient(packet.recipientId);
    const dense: boolean = linkIds.length >= RelayConstants.DENSE_LINK_THRESHOLD;
    // Dense graphs clamp broadcast TTL; thin links forward at full depth.
    let relayTtl: number = packet.ttl - 1;
    if (dense && !directed) {
      relayTtl = Math.min(relayTtl, RelayConstants.DENSE_TTL_CAP);
    }

    // Broadcast chat messages fan out to a deterministic message-ID-seeded
    // log2(degree)-sized subset in dense graphs; everything else (announces,
    // fragments, directed traffic) uses the full candidate set.
    let targets: string[] = candidates;
    if (dense && !directed && messageType === MessageType.MESSAGE) {
      const subsetSize: number =
        Math.max(1, Math.floor(Math.log(linkIds.length) / Math.log(2)));
      targets = PacketRelay.selectSubset(PacketIdUtil.computeIdHex(packet), candidates, subsetSize);
    }

    const key: string = routed.peerID + '-' + PacketIdUtil.computeIdHex(packet);
    const existing: PendingRelay | undefined = this.pending.get(key);
    if (existing !== undefined) {
      // First-arrival wins: a duplicate cancels the already-scheduled relay.
      this.cancel(existing.handle);
      this.pending.delete(key);
      this.cancelledRelays += 1;
      return;
    }

    const relayPacket: BitchatPacket = PacketRelay.copyWithTtl(packet, relayTtl);
    const delayMs: number = this.nextJitter(dense);
    const handle: number = this.schedule(delayMs, () => {
      this.pending.delete(key);
      this.executeRelay(relayPacket, targets);
    });
    this.pending.set(key, new PendingRelay(handle));
  }

  /** True when the packet's recipient specifically addresses this device. */
  isPacketAddressedToMe(packet: BitchatPacket): boolean {
    const recipientId: Uint8Array | null = packet.recipientId;
    if (recipientId === null) {
      return false;
    }
    if (BitchatPacket.isBroadcastRecipient(recipientId)) {
      return false;
    }
    return ByteUtils.bytesToHex(recipientId) === this.myPeerID;
  }

  getCancelledRelayCount(): number {
    return this.cancelledRelays;
  }

  getPendingRelayCount(): number {
    return this.pending.size;
  }

  getDebugInfo(): string {
    return '=== Packet Relay Debug Info ===\n' +
      'Relay Enabled: ' + this.relayEnabled + '\n' +
      'My Peer ID: ' + this.myPeerID + '\n' +
      'Pending Relays: ' + this.pending.size + '\n' +
      'Cancelled Relays: ' + this.cancelledRelays;
  }

  /** Cancel every scheduled relay. */
  shutdown(): void {
    this.pending.forEach((pending: PendingRelay): void => {
      this.cancel(pending.handle);
    });
    this.pending.clear();
  }

  private executeRelay(packet: BitchatPacket, targets: string[]): void {
    for (let i: number = 0; i < targets.length; i++) {
      this.delegate.sendOnLink(targets[i], packet);
    }
  }

  /** Forwarding jitter: 10-220ms, widened by the dense multiplier. */
  private nextJitter(dense: boolean): number {
    const span: number = (RelayConstants.JITTER_MAX_MS - RelayConstants.JITTER_MIN_MS) *
      (dense ? RelayConstants.DENSE_JITTER_MULTIPLIER : 1.0);
    return Math.floor(RelayConstants.JITTER_MIN_MS + this.rng() * span);
  }

  /**
   * Deterministic message-ID-seeded subset: rank candidate links by an
   * FNV-1a hash of (messageId|linkId) and keep the lowest `count` ranks.
   */
  private static selectSubset(messageId: string, candidates: string[], count: number): string[] {
    if (count >= candidates.length) {
      return candidates.slice();
    }
    const ranked: string[] = candidates.slice().sort((a: string, b: string): number => {
      const rankA: number = PacketRelay.seedRank(messageId, a);
      const rankB: number = PacketRelay.seedRank(messageId, b);
      if (rankA !== rankB) {
        return rankA - rankB;
      }
      return a < b ? -1 : 1;
    });
    return ranked.slice(0, count);
  }

  private static seedRank(seed: string, linkId: string): number {
    const text: string = seed + '|' + linkId;
    let hash: number = 0x811C9DC5;
    for (let i: number = 0; i < text.length; i++) {
      hash ^= text.charCodeAt(i);
      hash = Math.imul(hash, 0x01000193);
    }
    return hash & 0x7FFFFFFF;
  }

  /** Packet copy with an adjusted TTL, preserving wire-level fields. */
  private static copyWithTtl(packet: BitchatPacket, ttl: number): BitchatPacket {
    const copy: BitchatPacket = new BitchatPacket(packet.version, packet.type, packet.senderId,
      packet.recipientId, packet.timestamp, packet.payload, packet.signature, ttl, packet.route);
    copy.timestampRaw = packet.timestampRaw;
    copy.wirePayload = packet.wirePayload;
    return copy;
  }
}
