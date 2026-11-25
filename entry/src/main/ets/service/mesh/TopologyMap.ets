/**
 * Announce-topology source routing (US3, T028) - implements FR-033:
 * a shallow (max 2-hop) topology graph built from the direct-neighbor TLV
 * (0x04) that peers embed in their ANNOUNCE payloads (US2, T024), with
 * bidirectionally confirmed, freshness-bounded edges.
 *
 *  - Edge freshness: an announce-claimed edge or a direct link stays usable
 *    for TopologyConstants.EDGE_FRESHNESS_MS (60s); stale entries are
 *    ignored and prunable.
 *  - Bidirectional confirmation: the 2-hop route me -> X -> target requires
 *    X's announce to claim target AND target's announce to claim X, both
 *    fresh (prevents routing through one-sided/stale claims).
 *  - Source route shape follows the Android relay: [myId, intermediate...];
 *    the final target is not repeated in the route - relays fall back to the
 *    packet recipient after the last intermediate.
 *  - Fallback to flooding: computeSourceRoute returns null when no confirmed
 *    path exists; the caller then broadcasts without a route. Receiving-side
 *    next-hop resolution is static so any relay can follow a route, and the
 *    caller falls back to flooding when the next hop is not a direct link.
 *
 * Deliberately free of device imports so the routing decisions run in the
 * host contract harness; time is injected as nowMs.
 */
import { ByteUtils } from '../../common/ByteUtils';
import { GossipTlv } from './GossipTlv';
import { TopologyConstants } from '../../common/ProtocolConstants';

/** One peer's announce-claimed direct-neighbor set, time-stamped. */
class PeerClaim {
  readonly neighbors: string[];
  readonly updatedAtMs: number;

  constructor(neighbors: string[], updatedAtMs: number) {
    this.neighbors = neighbors;
    this.updatedAtMs = updatedAtMs;
  }
}

export class TopologyMap {
  private readonly myPeerID: string;
  private readonly claims: Map<string, PeerClaim> = new Map();
  /** My directly connected peers -> last contact time. */
  private readonly directLinks: Map<string, number> = new Map();

  constructor(myPeerID: string) {
    this.myPeerID = myPeerID;
  }

  /** Refresh (or establish) a direct-connection edge to one peer. */
  recordDirectLink(peerID: string, nowMs: number): void {
    this.directLinks.set(peerID, nowMs);
  }

  /** Drop a direct-connection edge (disconnect/leave). */
  removeDirectLink(peerID: string): void {
    this.directLinks.delete(peerID);
  }

  /**
   * Feed one peer's ANNOUNCE payload in. Only a present neighbor TLV (0x04)
   * updates the claim; a TLV-less announce leaves the previous claim in
   * place until freshness expiry.
   */
  onAnnouncePayload(peerID: string, payload: Uint8Array, nowMs: number): void {
    const neighbors: string[] | null =
      GossipTlv.decodeNeighborsFromAnnouncementPayload(payload);
    if (neighbors === null) {
      return;
    }
    this.claims.set(peerID, new PeerClaim(neighbors, nowMs));
  }

  /** True while the peer is a directly connected link within freshness. */
  isDirectNeighbor(peerID: string, nowMs: number): boolean {
    const lastSeenMs: number | undefined = this.directLinks.get(peerID);
    if (lastSeenMs === undefined) {
      return false;
    }
    return nowMs - lastSeenMs <= TopologyConstants.EDGE_FRESHNESS_MS;
  }

  /** Fresh announce-claimed neighbors of one peer (empty when none/stale). */
  getClaimedNeighbors(peerID: string, nowMs: number): string[] {
    const claim: PeerClaim | undefined = this.claims.get(peerID);
    if (claim === undefined) {
      return [];
    }
    if (nowMs - claim.updatedAtMs > TopologyConstants.EDGE_FRESHNESS_MS) {
      return [];
    }
    return claim.neighbors.slice();
  }

  /**
   * Sender-side route decision (FR-033):
   *  - [] when the target is directly connected (no route needed);
   *  - [myId, intermediate] when a fresh bidirectionally confirmed 2-hop
   *    path exists - the intermediate is a current direct link whose claim
   *    and the target's claim mutually confirm their edge;
   *  - null when no confirmed path exists: the caller falls back to
   *    flooding (broadcast without a route).
   * When several intermediates qualify, the lowest peer ID wins so the
   * decision stays deterministic.
   */
  computeSourceRoute(targetPeerId: string, nowMs: number): Uint8Array[] | null {
    if (targetPeerId === this.myPeerID) {
      return [];
    }
    if (this.isDirectNeighbor(targetPeerId, nowMs)) {
      return [];
    }
    const candidates: string[] = [];
    this.directLinks.forEach((lastSeenMs: number, peerID: string): void => {
      if (peerID === targetPeerId || peerID === this.myPeerID) {
        return;
      }
      if (nowMs - lastSeenMs > TopologyConstants.EDGE_FRESHNESS_MS) {
        return;
      }
      if (this.isEdgeConfirmed(peerID, targetPeerId, nowMs)) {
        candidates.push(peerID);
      }
    });
    if (candidates.length === 0) {
      return null;
    }
    candidates.sort();
    const route: Uint8Array[] = [];
    route.push(ByteUtils.hexToBytes(this.myPeerID));
    route.push(ByteUtils.hexToBytes(candidates[0]));
    return route;
  }

  /**
   * Receiving-side next-hop resolution (Android source-route relay
   * semantics): find ourselves in the route and hand back the following
   * hop, falling back to the packet recipient after the last intermediate.
   * Null when the route is not ours or no next hop can be determined -
   * the caller then falls back to flooding.
   */
  static resolveNextHop(route: Uint8Array[], myPeerID: string,
    recipientId: Uint8Array | null): string | null {
    let index: number = -1;
    for (let i: number = 0; i < route.length; i++) {
      if (ByteUtils.bytesToHex(route[i]) === myPeerID) {
        index = i;
        break;
      }
    }
    if (index < 0) {
      return null;
    }
    if (index + 1 < route.length) {
      return ByteUtils.bytesToHex(route[index + 1]);
    }
    if (recipientId !== null) {
      return ByteUtils.bytesToHex(recipientId);
    }
    return null;
  }

  /** Duplicate-hop loop guard (the Android relay drops such packets). */
  static hasDuplicateHops(route: Uint8Array[]): boolean {
    const seen: Set<string> = new Set();
    for (let i: number = 0; i < route.length; i++) {
      const id: string = ByteUtils.bytesToHex(route[i]);
      if (seen.has(id)) {
        return true;
      }
      seen.add(id);
    }
    return false;
  }

  /** Drop stale claims and direct links (call periodically). */
  prune(nowMs: number): void {
    this.claims.forEach((claim: PeerClaim, peerID: string): void => {
      if (nowMs - claim.updatedAtMs > TopologyConstants.EDGE_FRESHNESS_MS) {
        this.claims.delete(peerID);
      }
    });
    this.directLinks.forEach((lastSeenMs: number, peerID: string): void => {
      if (nowMs - lastSeenMs > TopologyConstants.EDGE_FRESHNESS_MS) {
        this.directLinks.delete(peerID);
      }
    });
  }

  /** Number of fresh announce claims (topology nodes beyond direct links). */
  getClaimedPeerCount(nowMs: number): number {
    let count: number = 0;
    this.claims.forEach((claim: PeerClaim): void => {
      if (nowMs - claim.updatedAtMs <= TopologyConstants.EDGE_FRESHNESS_MS) {
        count += 1;
      }
    });
    return count;
  }

  /** Number of fresh direct links. */
  getDirectLinkCount(nowMs: number): number {
    let count: number = 0;
    this.directLinks.forEach((lastSeenMs: number): void => {
      if (nowMs - lastSeenMs <= TopologyConstants.EDGE_FRESHNESS_MS) {
        count += 1;
      }
    });
    return count;
  }

  /** Edge a<->b usable: both sides fresh-claim each other. */
  private isEdgeConfirmed(a: string, b: string, nowMs: number): boolean {
    const claimA: PeerClaim | undefined = this.claims.get(a);
    const claimB: PeerClaim | undefined = this.claims.get(b);
    if (claimA === undefined || claimB === undefined) {
      return false;
    }
    if (nowMs - claimA.updatedAtMs > TopologyConstants.EDGE_FRESHNESS_MS) {
      return false;
    }
    if (nowMs - claimB.updatedAtMs > TopologyConstants.EDGE_FRESHNESS_MS) {
      return false;
    }
    return claimA.neighbors.indexOf(b) >= 0 && claimB.neighbors.indexOf(a) >= 0;
  }
}
