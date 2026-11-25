/**
 * Store-and-forward cache for offline peers (spec US17 / FR-034, T064):
 * this device, acting as a relay, caches directed packets for peers that
 * are not reachable right now and replays them in order when the peer
 * comes back online. Mirrors bitchat-android StoreForwardManager.kt (the
 * one Android reference for this domain): a global regular cache capped
 * at 100 entries with a 12h age-out, per-favorite-peer queues capped at
 * 1000 entries that are never aged out (they leave on delivery), a 10
 * minute cleanup cadence, one replay per peer per tracking window, and
 * 10ms pacing between replayed packets. Noise handshakes/frames,
 * announces, leaves and broadcasts are never cached (the skip list is
 * locked by StoreForwardEntry.isCacheablePacket, T061).
 *
 * Entries leave the regular cache only by age, by the 100-cap FIFO or by
 * replay; a replay marks its message IDs delivered first (a duplicate
 * copy arriving later is never replayed twice) and sends the packets in
 * cachedAt order - the first immediately, then one every 10ms.
 *
 * Deliberately pure ArkTS (no @kit imports): clock, favorite/online
 * lookup, packet send and the scheduler are injected, so the contract
 * tests run on the host harness with a fake scheduler; the device wiring
 * (T065) passes the live mesh link and setTimeout/clearTimeout.
 */
import { ByteUtils } from '../../common/ByteUtils';
import { StoreForwardConstants } from '../../common/ProtocolConstants';
import { BitchatPacket } from '../../model/BitchatPacket';
import { StoreForwardEntry } from '../../model/CourierModels';

/** Injected collaborators (device wiring lands with the T065 integration). */
export interface StoreForwardManagerDeps {
  nowMs: () => number;
  isFavorite: (peerID: string) => boolean;
  isPeerOnline: (peerID: string) => boolean;
  sendPacket: (packet: BitchatPacket) => void;
  schedule: (delayMs: number, task: () => void) => number;
  cancel: (handle: number) => void;
}

export class StoreForwardManager {
  /** Delivered-ID tracking is trimmed wholesale past this size. */
  static readonly DELIVERED_IDS_MAX: number = 1000;
  /** Per-peer replay-once tracking is trimmed wholesale past this size. */
  static readonly SENT_TRACKING_MAX: number = 200;

  private readonly deps: StoreForwardManagerDeps;
  private regularCache: StoreForwardEntry[] = [];
  private readonly favoriteQueues: Map<string, StoreForwardEntry[]> = new Map();
  private readonly deliveredMessages: Set<string> = new Set();
  private readonly sentCacheToPeer: Set<string> = new Set();
  private cleanupHandle: number | null = null;
  private cleanupRunning: boolean = false;

  constructor(deps: StoreForwardManagerDeps) {
    this.deps = deps;
  }

  /**
   * Cache one directed packet for a possibly-offline peer (Android
   * cacheMessage): favorites land in their per-peer queue (cap 1000),
   * everything else in the global regular cache (cap 100, oldest first
   * out); the skip list rejects handshakes, noise frames, announces,
   * leaves, broadcasts and missing recipients. Returns true when cached.
   */
  cache(packet: BitchatPacket, messageID: string): boolean {
    if (!StoreForwardEntry.isCacheablePacket(packet)) {
      return false;
    }
    const recipientId: Uint8Array | null = packet.recipientId;
    if (recipientId === null) {
      return false;
    }
    const recipientPeerID: string = ByteUtils.bytesToHex(recipientId);
    const isForFavorite: boolean = this.deps.isFavorite(recipientPeerID);
    const entry: StoreForwardEntry =
      new StoreForwardEntry(packet, this.deps.nowMs(), messageID, isForFavorite);
    if (isForFavorite) {
      let queue: StoreForwardEntry[] | undefined = this.favoriteQueues.get(recipientPeerID);
      if (queue === undefined) {
        queue = [];
        this.favoriteQueues.set(recipientPeerID, queue);
      }
      queue.push(entry);
      if (queue.length > StoreForwardConstants.MAX_CACHED_MESSAGES_FAVORITES) {
        queue.shift();
      }
      return true;
    }
    this.expireRegularCache(this.deps.nowMs());
    this.regularCache.push(entry);
    if (this.regularCache.length > StoreForwardConstants.MAX_CACHED_MESSAGES) {
      this.regularCache.shift();
    }
    return true;
  }

  /**
   * Replay every cached packet for a peer that just came online (Android
   * sendCachedMessages): favorite queue first, then the regular entries
   * for this recipient, merged and sorted by cached time, the first sent
   * immediately and one more every 10ms. Each peer is served once per
   * tracking window. Returns the number of packets queued for replay.
   */
  onPeerOnline(peerID: string): number {
    if (this.sentCacheToPeer.has(peerID)) {
      return 0;
    }
    this.sentCacheToPeer.add(peerID);
    this.expireRegularCache(this.deps.nowMs());
    const toSend: StoreForwardEntry[] = [];
    const queue: StoreForwardEntry[] | undefined = this.favoriteQueues.get(peerID);
    if (queue !== undefined) {
      for (let i: number = 0; i < queue.length; i++) {
        if (!this.deliveredMessages.has(queue[i].messageID)) {
          toSend.push(queue[i]);
        }
      }
      this.favoriteQueues.delete(peerID);
    }
    const kept: StoreForwardEntry[] = [];
    for (let i: number = 0; i < this.regularCache.length; i++) {
      const entry: StoreForwardEntry = this.regularCache[i];
      if (entry.recipientPeerID() === peerID && !this.deliveredMessages.has(entry.messageID)) {
        toSend.push(entry);
      } else {
        kept.push(entry);
      }
    }
    this.regularCache = kept;
    toSend.sort((a: StoreForwardEntry, b: StoreForwardEntry): number => a.cachedAt - b.cachedAt);
    for (let i: number = 0; i < toSend.length; i++) {
      this.deliveredMessages.add(toSend[i].messageID);
    }
    for (let i: number = 0; i < toSend.length; i++) {
      const entry: StoreForwardEntry = toSend[i];
      if (i === 0) {
        this.deps.sendPacket(entry.packet);
      } else {
        this.deps.schedule(i * StoreForwardConstants.REPLAY_INTERVAL_MS, (): void => {
          this.deps.sendPacket(entry.packet);
        });
      }
    }
    return toSend.length;
  }

  /** Whether the caller should cache for this peer: offline favorites. */
  shouldCacheForPeer(recipientPeerID: string): boolean {
    return !this.deps.isPeerOnline(recipientPeerID) && this.deps.isFavorite(recipientPeerID);
  }

  /** Mark a message ID delivered; it is never replayed afterwards. */
  markMessageAsDelivered(messageID: string): void {
    this.deliveredMessages.add(messageID);
  }

  /** Favorite-queue plus regular entries cached for one peer. */
  getCachedMessageCount(peerID: string): number {
    const queue: StoreForwardEntry[] | undefined = this.favoriteQueues.get(peerID);
    let count: number = queue === undefined ? 0 : queue.length;
    for (let i: number = 0; i < this.regularCache.length; i++) {
      if (this.regularCache[i].recipientPeerID() === peerID) {
        count += 1;
      }
    }
    return count;
  }

  /** One cleanup pass: 12h regular age-out plus tracking trims. */
  cleanupNow(): void {
    this.expireRegularCache(this.deps.nowMs());
    if (this.deliveredMessages.size > StoreForwardManager.DELIVERED_IDS_MAX) {
      this.deliveredMessages.clear();
    }
    if (this.sentCacheToPeer.size > StoreForwardManager.SENT_TRACKING_MAX) {
      this.sentCacheToPeer.clear();
    }
  }

  /** Start the 10-minute cleanup loop (Android startPeriodicCleanup). */
  startPeriodicCleanup(): void {
    if (this.cleanupRunning) {
      return;
    }
    this.cleanupRunning = true;
    this.scheduleNextCleanup();
  }

  stopPeriodicCleanup(): void {
    this.cleanupRunning = false;
    if (this.cleanupHandle !== null) {
      this.deps.cancel(this.cleanupHandle);
      this.cleanupHandle = null;
    }
  }

  /** Drop every cached entry and all delivery tracking (Android clearAllCache). */
  clearAllCache(): void {
    this.regularCache = [];
    this.favoriteQueues.clear();
    this.deliveredMessages.clear();
    this.sentCacheToPeer.clear();
  }

  private expireRegularCache(now: number): number {
    const kept: StoreForwardEntry[] = [];
    let removed: number = 0;
    for (let i: number = 0; i < this.regularCache.length; i++) {
      const entry: StoreForwardEntry = this.regularCache[i];
      if (entry.isExpired(now)) {
        removed += 1;
      } else {
        kept.push(entry);
      }
    }
    if (removed > 0) {
      this.regularCache = kept;
    }
    return removed;
  }

  private scheduleNextCleanup(): void {
    if (!this.cleanupRunning) {
      return;
    }
    this.cleanupHandle = this.deps.schedule(StoreForwardConstants.CLEANUP_INTERVAL_MS, (): void => {
      this.cleanupNow();
      this.scheduleNextCleanup();
    });
  }
}
