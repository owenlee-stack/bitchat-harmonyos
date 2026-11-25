/**
 * Gossip public-history synchronization (US3, T029) - implements FR-009,
 * mirroring bitchat-android GossipSyncManager.kt.
 *
 * Tracks seen public packets (latest ANNOUNCE per peer + broadcast MESSAGE)
 * in a bounded cache and periodically reconciles them against neighbors via
 * GCS filters (every SyncConstants.SYNC_PERIOD_MS ~15s plus a new-peer
 * triggered initial sync). A REQUEST_SYNC answer offers exactly the packets
 * the requester's filter does not contain: ANNOUNCE first, then messages by
 * timestamp, each with TTL 0 (neighbor only).
 *
 *  - Cache bounds: SyncConstants.CACHE_CAPACITY (1000) entries per type;
 *    oldest evicted first. Messages outside the 6-hour sync window
 *    (HISTORY_WINDOW_MS) are never cached nor offered; stale announcements
 *    (STALE_PEER_TIMEOUT_MS) and their senders' messages are pruned.
 *  - Advertised window == offered window: both the REQUEST_SYNC payload and
 *    the response draw from the same dependency-closed snapshot (a selected
 *    MESSAGE always carries its sender's latest ANNOUNCE when room remains).
 *  - GCS parameters: SHA-256 first 8 bytes, MSB-first bitstream, P <= 32,
 *    default filter 256B / 1% FPR, wire accept cap 1024B (GCSFilter +
 *    RequestSyncPacket).
 *
 * Timers and the clock are injected so the manager stays host-testable;
 * persistence of the cache is a facade concern (exportCache/importCache).
 */
import { BitchatPacket, MessageType, messageTypeFromValue } from '../../model/BitchatPacket';
import { RequestSyncPacket } from '../../model/RequestSyncPacket';
import { GCSFilter, GcsFilterParams } from './GCSFilter';
import { PacketIdUtil } from './PacketIdUtil';
import { PkTtl, SyncConstants, MeshConstants } from '../../common/ProtocolConstants';
import { ByteUtils } from '../../common/ByteUtils';

export interface GossipSyncDelegate {
  sendPacket(packet: BitchatPacket): void;

  sendPacketToPeer(peerID: string, packet: BitchatPacket): void;

  signPacketForBroadcast(packet: BitchatPacket): BitchatPacket;
}

export interface GossipSyncConfig {
  /** Max packets cached and synced per request (cap across types). */
  seenCapacity(): number;

  /** GCS filter byte budget (SyncConstants.DEFAULT_FILTER_BYTES). */
  gcsMaxBytes(): number;

  /** GCS target false-positive rate as a 0.0..1.0 fraction. */
  gcsTargetFpr(): number;
}

/** One cached packet keyed by its 16-byte packet-ID hex. */
export interface CachedPacketEntry {
  readonly idHex: string;
  readonly packet: BitchatPacket;
}

/** Latest announcement per peer (id + packet). */
class AnnouncementEntry {
  readonly idHex: string;
  readonly packet: BitchatPacket;

  constructor(idHex: string, packet: BitchatPacket) {
    this.idHex = idHex;
    this.packet = packet;
  }
}

/** Advertised == offered window: selected entries plus the encoded filter. */
class SyncSnapshot {
  readonly entries: CachedPacketEntry[];
  readonly filter: GcsFilterParams;

  constructor(entries: CachedPacketEntry[], filter: GcsFilterParams) {
    this.entries = entries;
    this.filter = filter;
  }
}

export class GossipSyncManager {
  private readonly myPeerID: string;
  private readonly delegate: GossipSyncDelegate;
  private readonly config: GossipSyncConfig;
  private readonly schedule: (delayMs: number, task: () => void) => number;
  private readonly cancel: (handle: number) => void;
  private readonly nowMs: () => number;
  /** Insertion-ordered message cache: packet-ID hex -> packet. */
  private readonly messages: Map<string, BitchatPacket> = new Map();
  private readonly latestAnnouncementByPeer: Map<string, AnnouncementEntry> = new Map();
  private running: boolean = false;
  private periodicHandle: number = -1;

  constructor(myPeerID: string, delegate: GossipSyncDelegate, config: GossipSyncConfig,
    schedule: (delayMs: number, task: () => void) => number =
      (delayMs: number, task: () => void): number => {
        return setTimeout(task, delayMs);
      },
    cancel: (handle: number) => void = (handle: number): void => {
      clearTimeout(handle);
    },
    nowMs: () => number = Date.now) {
    this.myPeerID = myPeerID;
    this.delegate = delegate;
    this.config = config;
    this.schedule = schedule;
    this.cancel = cancel;
    this.nowMs = nowMs;
  }

  /** Start the periodic reconciliation loop (~15s). */
  start(): void {
    if (this.running) {
      return;
    }
    this.running = true;
    this.schedulePeriodic();
  }

  stop(): void {
    this.running = false;
    if (this.periodicHandle >= 0) {
      this.cancel(this.periodicHandle);
      this.periodicHandle = -1;
    }
  }

  isRunning(): boolean {
    return this.running;
  }

  /** Drop all cached packets (identity change / logout). */
  clear(): void {
    this.messages.clear();
    this.latestAnnouncementByPeer.clear();
  }

  /** Initial sync after joining the mesh (broadcast REQUEST_SYNC). */
  scheduleInitialSync(delayMs: number = SyncConstants.INITIAL_SYNC_DELAY_MS): void {
    this.schedule(delayMs, (): void => {
      if (this.running) {
        this.sendRequestSync();
      }
    });
  }

  /** New-peer triggered initial sync, directed at that peer. */
  scheduleInitialSyncToPeer(peerID: string,
    delayMs: number = SyncConstants.INITIAL_SYNC_DELAY_MS): void {
    this.schedule(delayMs, (): void => {
      if (this.running) {
        this.sendRequestSyncToPeer(peerID);
      }
    });
  }

  /**
   * Feed every publicly seen packet in. Only broadcast MESSAGE and ANNOUNCE
   * are cached; messages outside the 6h window and stale announcements are
   * ignored; per-type capacity evicts the oldest entries.
   */
  onPublicPacketSeen(packet: BitchatPacket): void {
    const messageType: MessageType | null = messageTypeFromValue(packet.type);
    const isBroadcastMessage: boolean = messageType === MessageType.MESSAGE &&
      (packet.recipientId === null || BitchatPacket.isBroadcastRecipient(packet.recipientId));
    const isAnnouncement: boolean = messageType === MessageType.ANNOUNCE;
    if (!isBroadcastMessage && !isAnnouncement) {
      return;
    }
    const idHex: string = PacketIdUtil.computeIdHex(packet);
    if (isBroadcastMessage) {
      if (this.nowMs() - packet.timestamp > SyncConstants.HISTORY_WINDOW_MS) {
        return;
      }
      this.messages.set(idHex, packet);
      GossipSyncManager.evictOldest(this.messages, this.capacity());
      return;
    }
    if (this.nowMs() - packet.timestamp > MeshConstants.STALE_PEER_TIMEOUT_MS) {
      return;
    }
    const senderHex: string = ByteUtils.bytesToHex(packet.senderId);
    this.latestAnnouncementByPeer.set(senderHex, new AnnouncementEntry(idHex, packet));
    GossipSyncManager.evictOldestByValue(this.latestAnnouncementByPeer, this.capacity());
  }

  /**
   * Answer a REQUEST_SYNC: send every snapshot packet the requester's GCS
   * filter does not contain, announcements first, then by timestamp, each
   * with TTL 0 (neighbor only).
   */
  handleRequestSync(fromPeerID: string, request: RequestSyncPacket): void {
    if (!this.running) {
      return;
    }
    const sorted: number[] = GCSFilter.decodeToSortedSet(request.p, request.m, request.data);
    const snapshot: SyncSnapshot = this.buildSyncSnapshot();
    const missing: CachedPacketEntry[] = [];
    for (let i: number = 0; i < snapshot.entries.length; i++) {
      const entry: CachedPacketEntry = snapshot.entries[i];
      const idBytes: Uint8Array = ByteUtils.hexToBytes(entry.idHex);
      if (!GossipSyncManager.mightContain(sorted, idBytes, request.m)) {
        missing.push(entry);
      }
    }
    missing.sort((a: CachedPacketEntry, b: CachedPacketEntry): number => {
      const aAnnounce: number = a.packet.type === MessageType.ANNOUNCE ? 0 : 1;
      const bAnnounce: number = b.packet.type === MessageType.ANNOUNCE ? 0 : 1;
      if (aAnnounce !== bAnnounce) {
        return aAnnounce - bAnnounce;
      }
      if (a.packet.timestamp !== b.packet.timestamp) {
        return a.packet.timestamp - b.packet.timestamp;
      }
      return a.idHex < b.idHex ? -1 : (a.idHex > b.idHex ? 1 : 0);
    });
    for (let i: number = 0; i < missing.length; i++) {
      const relayed: BitchatPacket =
        GossipSyncManager.copyWithTtl(missing[i].packet, PkTtl.SYNC_TTL_HOPS);
      this.delegate.sendPacketToPeer(fromPeerID, relayed);
    }
  }

  /** Remove stale announcements (and their senders' messages) and messages
   * outside the 6-hour window; runs on every periodic tick. */
  pruneStale(): void {
    const now: number = this.nowMs();
    const staleSenders: string[] = [];
    this.latestAnnouncementByPeer.forEach((entry: AnnouncementEntry, senderHex: string): void => {
      if (now - entry.packet.timestamp > MeshConstants.STALE_PEER_TIMEOUT_MS) {
        staleSenders.push(senderHex);
      }
    });
    for (let i: number = 0; i < staleSenders.length; i++) {
      this.removeAnnouncementForPeer(staleSenders[i]);
    }
    const expiredIds: string[] = [];
    this.messages.forEach((packet: BitchatPacket, idHex: string): void => {
      if (now - packet.timestamp > SyncConstants.HISTORY_WINDOW_MS) {
        expiredIds.push(idHex);
      }
    });
    for (let i: number = 0; i < expiredIds.length; i++) {
      this.messages.delete(expiredIds[i]);
    }
  }

  /** Drop one peer's announcement and all cached messages from that sender. */
  removeAnnouncementForPeer(peerID: string): void {
    const key: string = peerID.toLowerCase();
    this.latestAnnouncementByPeer.delete(key);
    const idsToRemove: string[] = [];
    this.messages.forEach((packet: BitchatPacket, idHex: string): void => {
      if (ByteUtils.bytesToHex(packet.senderId) === key) {
        idsToRemove.push(idHex);
      }
    });
    for (let i: number = 0; i < idsToRemove.length; i++) {
      this.messages.delete(idsToRemove[i]);
    }
  }

  /** Cache contents for persistence (messages + latest announcements). */
  exportCache(): CachedPacketEntry[] {
    const entries: CachedPacketEntry[] = [];
    this.latestAnnouncementByPeer.forEach((entry: AnnouncementEntry): void => {
      entries.push({ idHex: entry.idHex, packet: entry.packet });
    });
    this.messages.forEach((packet: BitchatPacket, idHex: string): void => {
      entries.push({ idHex: idHex, packet: packet });
    });
    return entries;
  }

  /** Restore a persisted cache (6h window still applies to messages). */
  importCache(entries: CachedPacketEntry[]): void {
    for (let i: number = 0; i < entries.length; i++) {
      const entry: CachedPacketEntry = entries[i];
      const messageType: MessageType | null = messageTypeFromValue(entry.packet.type);
      if (messageType === MessageType.MESSAGE) {
        if (this.nowMs() - entry.packet.timestamp > SyncConstants.HISTORY_WINDOW_MS) {
          continue;
        }
        this.messages.set(entry.idHex, entry.packet);
      } else if (messageType === MessageType.ANNOUNCE) {
        const senderHex: string = ByteUtils.bytesToHex(entry.packet.senderId);
        this.latestAnnouncementByPeer.set(senderHex,
          new AnnouncementEntry(entry.idHex, entry.packet));
      }
    }
    GossipSyncManager.evictOldest(this.messages, this.capacity());
    GossipSyncManager.evictOldestByValue(this.latestAnnouncementByPeer, this.capacity());
  }

  getCachedMessageCount(): number {
    return this.messages.size;
  }

  getCachedAnnouncementCount(): number {
    return this.latestAnnouncementByPeer.size;
  }

  // ------------------------------------------------------------------
  // Internals
  // ------------------------------------------------------------------

  private schedulePeriodic(): void {
    if (!this.running) {
      return;
    }
    this.periodicHandle = this.schedule(SyncConstants.SYNC_PERIOD_MS, (): void => {
      this.periodicHandle = -1;
      if (!this.running) {
        return;
      }
      this.sendRequestSync();
      this.pruneStale();
      this.schedulePeriodic();
    });
  }

  private capacity(): number {
    return Math.max(this.config.seenCapacity(), 1);
  }

  /** Build + sign + broadcast a REQUEST_SYNC carrying our GCS filter. */
  private sendRequestSync(): void {
    const payload: Uint8Array = this.buildGcsPayload();
    const packet: BitchatPacket = new BitchatPacket(1, MessageType.REQUEST_SYNC,
      ByteUtils.hexToBytes(this.myPeerID), null, this.nowMs(), payload, null,
      PkTtl.SYNC_TTL_HOPS, null);
    const signed: BitchatPacket = this.delegate.signPacketForBroadcast(packet);
    this.delegate.sendPacket(signed);
  }

  /** Build + sign + send a directed REQUEST_SYNC to one peer. */
  private sendRequestSyncToPeer(peerID: string): void {
    const payload: Uint8Array = this.buildGcsPayload();
    const packet: BitchatPacket = new BitchatPacket(1, MessageType.REQUEST_SYNC,
      ByteUtils.hexToBytes(this.myPeerID), ByteUtils.hexToBytes(peerID), this.nowMs(),
      payload, null, PkTtl.SYNC_TTL_HOPS, null);
    const signed: BitchatPacket = this.delegate.signPacketForBroadcast(packet);
    this.delegate.sendPacketToPeer(peerID, signed);
  }

  /**
   * Same bounded window is advertised and offered: stable sort by timestamp
   * (descending, then ID), dependency-closed selection (a MESSAGE brings its
   * sender's latest ANNOUNCE when room remains), GCS encode within the byte
   * budget, and trim to what the filter actually encoded.
   */
  private buildSyncSnapshot(): SyncSnapshot {
    const announcements: Map<string, AnnouncementEntry> = new Map();
    this.latestAnnouncementByPeer.forEach((entry: AnnouncementEntry, senderHex: string): void => {
      announcements.set(senderHex, entry);
    });
    const candidates: CachedPacketEntry[] = [];
    announcements.forEach((entry: AnnouncementEntry): void => {
      candidates.push({ idHex: entry.idHex, packet: entry.packet });
    });
    this.messages.forEach((packet: BitchatPacket, idHex: string): void => {
      candidates.push({ idHex: idHex, packet: packet });
    });
    candidates.sort((a: CachedPacketEntry, b: CachedPacketEntry): number => {
      if (a.packet.timestamp !== b.packet.timestamp) {
        return b.packet.timestamp - a.packet.timestamp;
      }
      return a.idHex < b.idHex ? -1 : (a.idHex > b.idHex ? 1 : 0);
    });
    const maxBytes: number = this.config.gcsMaxBytes();
    const fpr: number = this.config.gcsTargetFpr();
    const cap: number = this.capacity();
    const limit: number = Math.min(cap,
      GCSFilter.estimateMaxElementsForSize(maxBytes, GCSFilter.deriveP(fpr)));
    const selectedById: Map<string, BitchatPacket> = new Map();
    for (let i: number = 0; i < candidates.length; i++) {
      const candidate: CachedPacketEntry = candidates[i];
      if (selectedById.has(candidate.idHex)) {
        continue;
      }
      let announcement: AnnouncementEntry | null = null;
      if (candidate.packet.type === MessageType.MESSAGE) {
        const senderHex: string = ByteUtils.bytesToHex(candidate.packet.senderId);
        const senderAnnounce: AnnouncementEntry | undefined = announcements.get(senderHex);
        if (senderAnnounce !== undefined && !selectedById.has(senderAnnounce.idHex)) {
          announcement = senderAnnounce;
        }
      }
      const required: number = announcement === null ? 1 : 2;
      if (selectedById.size + required > limit) {
        continue;
      }
      if (announcement !== null) {
        selectedById.set(announcement.idHex, announcement.packet);
      }
      selectedById.set(candidate.idHex, candidate.packet);
    }
    const selected: CachedPacketEntry[] = [];
    selectedById.forEach((packet: BitchatPacket, idHex: string): void => {
      selected.push({ idHex: idHex, packet: packet });
    });
    const ids: Uint8Array[] = [];
    for (let i: number = 0; i < selected.length; i++) {
      ids.push(ByteUtils.hexToBytes(selected[i].idHex));
    }
    const filter: GcsFilterParams = GCSFilter.buildFilter(ids, maxBytes, fpr);
    const encodedCount: number = Math.min(
      Math.max(Math.floor(filter.m / Math.pow(2, filter.p)), 0), selected.length);
    return new SyncSnapshot(selected.slice(0, encodedCount), filter);
  }

  private buildGcsPayload(): Uint8Array {
    const snapshot: SyncSnapshot = this.buildSyncSnapshot();
    const request: RequestSyncPacket = new RequestSyncPacket(snapshot.filter.p,
      Math.max(snapshot.filter.m, 1), snapshot.filter.data);
    return request.encode();
  }

  /** GCS membership: h64(id16) mod m (zero mapped to 1), binary search. */
  private static mightContain(sorted: number[], id16: Uint8Array, m: number): boolean {
    const value: number = GCSFilter.h64modM(id16, m);
    return GCSFilter.contains(sorted, value === 0 ? 1 : value);
  }

  /** Evict the oldest entries beyond capacity (insertion order). */
  private static evictOldest(map: Map<string, BitchatPacket>, capacity: number): void {
    while (map.size > capacity) {
      let removed: boolean = false;
      for (const key of map.keys()) {
        map.delete(key);
        removed = true;
        break;
      }
      if (!removed) {
        return;
      }
    }
  }

  private static evictOldestByValue(map: Map<string, AnnouncementEntry>,
    capacity: number): void {
    while (map.size > capacity) {
      let removed: boolean = false;
      for (const key of map.keys()) {
        map.delete(key);
        removed = true;
        break;
      }
      if (!removed) {
        return;
      }
    }
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
