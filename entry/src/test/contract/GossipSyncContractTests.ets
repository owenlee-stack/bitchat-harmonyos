/**
 * Contract tests for the T029 gossip sync (FR-009):
 * - RequestSyncPacket TLV wire format golden layout, roundtrip, uint32 M
 *   clamp, malformed/oversized decode rejection
 * - cache admission: broadcast MESSAGE + ANNOUNCE only, 6h window boundary,
 *   180s stale-announcement boundary, per-type capacity eviction
 * - periodic ~15s reconciliation loop, broadcast + directed REQUEST_SYNC
 *   (TTL 0, sender/recipient fields, GCS payload P=7 at 1% FPR)
 * - REQUEST_SYNC response: offers exactly the filter-missing snapshot,
 *   announcements first then messages by timestamp, TTL 0 copies that never
 *   mutate the cache
 * - stale pruning (announcement + sender's messages), exportCache/importCache
 *   persistence roundtrip, stop() cancels the periodic loop
 */
import { ContractAssert } from './ContractAssert';
import { GossipSyncManager } from '../../main/ets/service/sync/GossipSyncManager';
import { GossipSyncDelegate } from '../../main/ets/service/sync/GossipSyncManager';
import { GossipSyncConfig } from '../../main/ets/service/sync/GossipSyncManager';
import { RequestSyncPacket } from '../../main/ets/model/RequestSyncPacket';
import { GCSFilter, GcsFilterParams } from '../../main/ets/service/sync/GCSFilter';
import { PacketIdUtil } from '../../main/ets/service/sync/PacketIdUtil';
import { BitchatPacket, MessageType, specialRecipientBroadcast } from '../../main/ets/model/BitchatPacket';
import { ByteUtils } from '../../main/ets/common/ByteUtils';
import { PkTtl, SyncConstants } from '../../main/ets/common/ProtocolConstants';

class ScheduledTask {
  readonly handle: number;
  readonly delayMs: number;
  task: (() => void) | null;
  cancelled: boolean = false;

  constructor(handle: number, delayMs: number, task: () => void) {
    this.handle = handle;
    this.delayMs = delayMs;
    this.task = task;
  }
}

/** Manual scheduler: tasks collect until fired, cancellable by handle. */
class SyncVirtualScheduler {
  tasks: ScheduledTask[] = [];
  private nextHandle: number = 1;

  schedule(delayMs: number, task: () => void): number {
    const scheduled: ScheduledTask = new ScheduledTask(this.nextHandle, delayMs, task);
    this.tasks.push(scheduled);
    this.nextHandle += 1;
    return scheduled.handle;
  }

  cancel(handle: number): void {
    for (let i: number = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].handle === handle) {
        this.tasks[i].cancelled = true;
      }
    }
  }

  activeCount(): number {
    let count: number = 0;
    for (let i: number = 0; i < this.tasks.length; i++) {
      if (!this.tasks[i].cancelled && this.tasks[i].task !== null) {
        count += 1;
      }
    }
    return count;
  }

  fire(handle: number): void {
    for (let i: number = 0; i < this.tasks.length; i++) {
      const task: ScheduledTask = this.tasks[i];
      if (task.handle === handle && !task.cancelled && task.task !== null) {
        const run: (() => void) = task.task;
        task.task = null;
        run();
        return;
      }
    }
  }
}

class TestClock {
  now: number;

  constructor(start: number) {
    this.now = start;
  }
}

function makeSyncMessage(senderHex: string, timestamp: number, marker: number): BitchatPacket {
  return new BitchatPacket(1, MessageType.MESSAGE, ByteUtils.hexToBytes(senderHex),
    specialRecipientBroadcast(), timestamp, new Uint8Array([marker]), null,
    PkTtl.MESSAGE_TTL_HOPS, null);
}

function makeSyncAnnounce(senderHex: string, timestamp: number): BitchatPacket {
  return new BitchatPacket(1, MessageType.ANNOUNCE, ByteUtils.hexToBytes(senderHex),
    null, timestamp, new Uint8Array([0x0A]), null, PkTtl.MESSAGE_TTL_HOPS, null);
}

export function runGossipSyncContractTests(t: ContractAssert): void {
  const myPeerID: string = '0011223344556677';
  const requesterPeer: string = '9988776655443322';
  const senderA: string = 'aabbccddeeff0011';
  const senderB: string = 'bbbbcccddeeeff00';
  const base: number = 1000000;

  // ------------------------------------------------------------------
  // RequestSyncPacket wire format (TLV golden layout + roundtrip).
  // ------------------------------------------------------------------
  const golden: Uint8Array = new Uint8Array([
    0x01, 0x00, 0x01, 0x07,             // P = 7 (len16 = 1)
    0x02, 0x00, 0x04, 0x00, 0x00, 0x03, 0xE8, // M = 1000 (len16 = 4, uint32 BE)
    0x03, 0x00, 0x02, 0xAB, 0xCD        // data = AB CD (len16 = 2)
  ]);
  const encoded: Uint8Array = new RequestSyncPacket(7, 1000,
    new Uint8Array([0xAB, 0xCD])).encode();
  t.equalBytes(golden, encoded, 'REQUEST_SYNC payload TLV golden layout');

  const decoded: RequestSyncPacket | null = RequestSyncPacket.decode(golden);
  t.isNotNull(decoded, 'golden payload decodes');
  if (decoded !== null) {
    t.equalNumber(7, decoded.p, 'decoded P');
    t.equalNumber(1000, decoded.m, 'decoded M');
    t.equalBytes(new Uint8Array([0xAB, 0xCD]), decoded.data, 'decoded filter data');
  }

  // Empty data still roundtrips (empty TLV value, not a missing TLV).
  const emptyRound: RequestSyncPacket | null = RequestSyncPacket.decode(
    new RequestSyncPacket(1, 1, new Uint8Array(0)).encode());
  t.isNotNull(emptyRound, 'empty filter roundtrips');
  if (emptyRound !== null) {
    t.equalNumber(0, emptyRound.data.length, 'empty filter data stays empty');
  }

  // M clamps to uint32 on encode.
  const clamped: RequestSyncPacket | null = RequestSyncPacket.decode(
    new RequestSyncPacket(7, 4294967296 + 7, new Uint8Array([0x01])).encode());
  t.isNotNull(clamped, 'uint32-clamped M decodes');
  if (clamped !== null) {
    t.equalNumber(4294967295, clamped.m, 'M clamps to 0xFFFFFFFF on encode');
  }

  // Malformed inputs fail closed.
  t.isNull(RequestSyncPacket.decode(new Uint8Array(0)), 'empty input decodes to null');
  t.isNull(RequestSyncPacket.decode(new Uint8Array([0x01, 0x00, 0x01, 0x07])),
    'missing M/data TLVs decode to null');
  t.isNull(RequestSyncPacket.decode(new Uint8Array([0x03, 0x10, 0x00, 0x01])),
    'truncated TLV value decodes to null');
  const oversized: Uint8Array = new RequestSyncPacket(7, 128,
    new Uint8Array(SyncConstants.MAX_ACCEPT_FILTER_BYTES + 1)).encode();
  t.isNull(RequestSyncPacket.decode(oversized),
    'filter data over the accept cap decodes to null');

  // ------------------------------------------------------------------
  // Cache admission: types, 6h window, stale announcements, capacity.
  // ------------------------------------------------------------------
  class FixedConfig implements GossipSyncConfig {
    capacity: number = SyncConstants.CACHE_CAPACITY;

    seenCapacity(): number {
      return this.capacity;
    }

    gcsMaxBytes(): number {
      return SyncConstants.DEFAULT_FILTER_BYTES;
    }

    gcsTargetFpr(): number {
      return SyncConstants.DEFAULT_FPR_PERCENT / 100.0;
    }
  }

  class RecordingDelegate implements GossipSyncDelegate {
    sent: BitchatPacket[] = [];
    sentTo: Map<string, BitchatPacket[]> = new Map();

    sendPacket(packet: BitchatPacket): void {
      this.sent.push(packet);
    }

    sendPacketToPeer(peerID: string, packet: BitchatPacket): void {
      const list: BitchatPacket[] | undefined = this.sentTo.get(peerID);
      if (list === undefined) {
        this.sentTo.set(peerID, [packet]);
      } else {
        list.push(packet);
      }
    }

    signPacketForBroadcast(packet: BitchatPacket): BitchatPacket {
      return packet;
    }
  }

  const scheduler: SyncVirtualScheduler = new SyncVirtualScheduler();
  const clock: TestClock = new TestClock(base);
  const delegate: RecordingDelegate = new RecordingDelegate();
  const config: FixedConfig = new FixedConfig();
  const manager: GossipSyncManager = new GossipSyncManager(myPeerID, delegate, config,
    (delayMs: number, task: () => void): number => scheduler.schedule(delayMs, task),
    (handle: number): void => scheduler.cancel(handle),
    (): number => clock.now);

  manager.onPublicPacketSeen(makeSyncMessage(senderA, base - 1000, 1));
  t.equalNumber(1, manager.getCachedMessageCount(), 'broadcast MESSAGE cached');
  manager.onPublicPacketSeen(new BitchatPacket(1, MessageType.MESSAGE,
    ByteUtils.hexToBytes(senderA), ByteUtils.hexToBytes(requesterPeer), base - 1000,
    new Uint8Array([2]), null, PkTtl.MESSAGE_TTL_HOPS, null));
  t.equalNumber(1, manager.getCachedMessageCount(), 'directed MESSAGE not cached');
  manager.onPublicPacketSeen(new BitchatPacket(1, MessageType.NOISE_ENCRYPTED,
    ByteUtils.hexToBytes(senderA), null, base - 1000, new Uint8Array([3]), null,
    PkTtl.MESSAGE_TTL_HOPS, null));
  t.equalNumber(1, manager.getCachedMessageCount(), 'non-public types not cached');

  manager.onPublicPacketSeen(makeSyncAnnounce(senderA, base - 1000));
  t.equalNumber(1, manager.getCachedAnnouncementCount(), 'ANNOUNCE cached per sender');
  manager.onPublicPacketSeen(makeSyncAnnounce(senderA, base - 500));
  t.equalNumber(1, manager.getCachedAnnouncementCount(), 'latest ANNOUNCE replaces per sender');
  manager.onPublicPacketSeen(makeSyncAnnounce(senderB, base - (180000 + 1)));
  t.equalNumber(1, manager.getCachedAnnouncementCount(),
    'ANNOUNCE older than the stale boundary ignored');
  manager.onPublicPacketSeen(makeSyncAnnounce(senderB, base - 180000));
  t.equalNumber(2, manager.getCachedAnnouncementCount(),
    'ANNOUNCE at the stale boundary still cached');

  manager.onPublicPacketSeen(makeSyncMessage(senderB, base - SyncConstants.HISTORY_WINDOW_MS, 4));
  t.equalNumber(2, manager.getCachedMessageCount(), 'message at the 6h boundary cached');
  manager.onPublicPacketSeen(makeSyncMessage(senderB, base - SyncConstants.HISTORY_WINDOW_MS - 1, 5));
  t.equalNumber(2, manager.getCachedMessageCount(), 'message past the 6h window ignored');

  // Capacity eviction: oldest entries drop first.
  config.capacity = 3;
  manager.clear();
  for (let i: number = 0; i < 5; i++) {
    manager.onPublicPacketSeen(makeSyncMessage(senderA, base - 100 + i, 10 + i));
  }
  t.equalNumber(3, manager.getCachedMessageCount(), 'capacity evicts oldest messages');
  config.capacity = SyncConstants.CACHE_CAPACITY;

  // ------------------------------------------------------------------
  // Periodic reconciliation loop and REQUEST_SYNC emission.
  // ------------------------------------------------------------------
  manager.clear();
  manager.start();
  t.isTrue(manager.isRunning(), 'manager running after start');
  t.equalNumber(1, scheduler.activeCount(), 'periodic loop scheduled');
  t.equalNumber(SyncConstants.SYNC_PERIOD_MS, scheduler.tasks[0].delayMs,
    'periodic interval is ~15s');
  scheduler.fire(1);
  t.equalNumber(1, delegate.sent.length, 'periodic tick emits one REQUEST_SYNC');
  const request: BitchatPacket = delegate.sent[0];
  t.equalNumber(MessageType.REQUEST_SYNC, request.type, 'periodic request type');
  t.equalNumber(PkTtl.SYNC_TTL_HOPS, request.ttl, 'REQUEST_SYNC carries TTL 0');
  t.isNull(request.recipientId, 'periodic request is a broadcast');
  t.equalString(myPeerID, ByteUtils.bytesToHex(request.senderId),
    'REQUEST_SYNC sender is my peer ID');
  const decodedRequest: RequestSyncPacket | null = RequestSyncPacket.decode(request.payload);
  t.isNotNull(decodedRequest, 'periodic request payload decodes');
  if (decodedRequest !== null) {
    t.equalNumber(GCSFilter.deriveP(SyncConstants.DEFAULT_FPR_PERCENT / 100.0),
      decodedRequest.p, 'empty cache advertises P=7 (1% FPR)');
    t.equalNumber(1, decodedRequest.m, 'empty cache advertises M=1');
    t.equalNumber(0, decodedRequest.data.length, 'empty cache advertises no data');
  }
  t.equalNumber(1, scheduler.activeCount(), 'periodic loop reschedules after a tick');

  // New-peer triggered initial sync is directed.
  manager.scheduleInitialSyncToPeer(requesterPeer);
  scheduler.fire(3);
  const directed: BitchatPacket[] | undefined = delegate.sentTo.get(requesterPeer);
  t.isNotNull(directed, 'initial sync reached the peer');
  if (directed !== undefined && directed.length > 0) {
    t.equalNumber(MessageType.REQUEST_SYNC, directed[0].type, 'initial sync type');
    const directedRecipient: Uint8Array | null = directed[0].recipientId;
    t.isNotNull(directedRecipient, 'initial sync carries a recipient');
    if (directedRecipient !== null) {
      t.equalString(requesterPeer, ByteUtils.bytesToHex(directedRecipient),
        'initial sync is directed at the new peer');
    }
  }

  // ------------------------------------------------------------------
  // REQUEST_SYNC response offers exactly the filter-missing snapshot.
  // ------------------------------------------------------------------
  manager.clear();
  const msgHave: BitchatPacket = makeSyncMessage(senderA, base - 3000, 0x01);
  const msgMissing: BitchatPacket = makeSyncMessage(senderA, base - 2000, 0x02);
  const announce: BitchatPacket = makeSyncAnnounce(senderA, base - 4000);
  manager.onPublicPacketSeen(announce);
  manager.onPublicPacketSeen(msgHave);
  manager.onPublicPacketSeen(msgMissing);

  // Requester already holds msgHave: its filter contains that packet only.
  const requesterFilter: GcsFilterParams = GCSFilter.buildFilter(
    [PacketIdUtil.computeIdBytes(msgHave)], SyncConstants.DEFAULT_FILTER_BYTES,
    SyncConstants.DEFAULT_FPR_PERCENT / 100.0);
  const requesterPayload: Uint8Array = new RequestSyncPacket(requesterFilter.p,
    requesterFilter.m, requesterFilter.data).encode();
  const requesterRequest: RequestSyncPacket | null = RequestSyncPacket.decode(requesterPayload);
  t.isNotNull(requesterRequest, 'requester filter payload decodes');
  if (requesterRequest !== null) {
    delegate.sentTo.clear();
    manager.handleRequestSync(requesterPeer, requesterRequest);
    const response: BitchatPacket[] | undefined = delegate.sentTo.get(requesterPeer);
    t.isNotNull(response, 'response reached the requester');
    if (response !== undefined) {
      t.equalNumber(2, response.length, 'only filter-missing packets offered');
      t.equalNumber(MessageType.ANNOUNCE, response[0].type,
        'announcements are offered first');
      t.equalNumber(MessageType.MESSAGE, response[1].type, 'missing message offered second');
      t.equalBytes(msgMissing.payload, response[1].payload, 'the right message content');
      t.equalNumber(PkTtl.SYNC_TTL_HOPS, response[0].ttl, 'responses carry TTL 0');
      t.equalNumber(PkTtl.SYNC_TTL_HOPS, response[1].ttl, 'responses carry TTL 0');
    }
  }
  // The cached message was sent as a copy: the cache keeps its original TTL.
  t.equalNumber(PkTtl.MESSAGE_TTL_HOPS, msgMissing.ttl, 'cached packet TTL not mutated');

  // A requester holding everything receives nothing.
  const fullFilter: GcsFilterParams = GCSFilter.buildFilter(
    [PacketIdUtil.computeIdBytes(msgHave), PacketIdUtil.computeIdBytes(msgMissing),
      PacketIdUtil.computeIdBytes(announce)],
    SyncConstants.DEFAULT_FILTER_BYTES, SyncConstants.DEFAULT_FPR_PERCENT / 100.0);
  const fullRequest: RequestSyncPacket | null = RequestSyncPacket.decode(
    new RequestSyncPacket(fullFilter.p, fullFilter.m, fullFilter.data).encode());
  t.isNotNull(fullRequest, 'full filter payload decodes');
  if (fullRequest !== null) {
    delegate.sentTo.clear();
    manager.handleRequestSync(requesterPeer, fullRequest);
    const fullResponse: BitchatPacket[] | undefined = delegate.sentTo.get(requesterPeer);
    t.isTrue(fullResponse === undefined || fullResponse.length === 0,
      'requester holding everything receives nothing');
  }

  // ------------------------------------------------------------------
  // Stale pruning drops announcements, their senders' messages and
  // out-of-window messages.
  // ------------------------------------------------------------------
  manager.clear();
  manager.onPublicPacketSeen(makeSyncAnnounce(senderA, base - 1000));
  manager.onPublicPacketSeen(makeSyncMessage(senderA, base - 1000, 0x21));
  manager.onPublicPacketSeen(makeSyncMessage(senderB, base - 1000, 0x22));
  t.equalNumber(2, manager.getCachedMessageCount(), 'two senders cached before prune');
  clock.now = base - 1000 + 180001;
  manager.pruneStale();
  t.equalNumber(0, manager.getCachedAnnouncementCount(), 'stale announcement pruned');
  t.equalNumber(1, manager.getCachedMessageCount(),
    'stale sender messages pruned, other senders kept');
  manager.clear();
  manager.onPublicPacketSeen(makeSyncMessage(senderA, base - 1000, 0x31));
  clock.now = base - 1000 + SyncConstants.HISTORY_WINDOW_MS + 1;
  manager.pruneStale();
  t.equalNumber(0, manager.getCachedMessageCount(), 'out-of-window message pruned');

  // ------------------------------------------------------------------
  // Persistence roundtrip: exportCache -> importCache.
  // ------------------------------------------------------------------
  manager.clear();
  clock.now = base;
  manager.onPublicPacketSeen(makeSyncAnnounce(senderA, base - 1000));
  manager.onPublicPacketSeen(makeSyncMessage(senderA, base - 1000, 0x41));
  const exported = manager.exportCache();
  const restored: GossipSyncManager = new GossipSyncManager(myPeerID, delegate, config,
    (delayMs: number, task: () => void): number => scheduler.schedule(delayMs, task),
    (handle: number): void => scheduler.cancel(handle),
    (): number => clock.now);
  restored.importCache(exported);
  t.equalNumber(manager.getCachedMessageCount(), restored.getCachedMessageCount(),
    'restored cache holds the same messages');
  t.equalNumber(manager.getCachedAnnouncementCount(), restored.getCachedAnnouncementCount(),
    'restored cache holds the same announcements');
  // Messages beyond the 6h window do not survive import.
  const oldExported = new GossipSyncManager(myPeerID, delegate, config,
    (delayMs: number, task: () => void): number => scheduler.schedule(delayMs, task),
    (handle: number): void => scheduler.cancel(handle),
    (): number => clock.now);
  oldExported.importCache([{
    idHex: PacketIdUtil.computeIdHex(makeSyncMessage(senderA, base - SyncConstants.HISTORY_WINDOW_MS - 5, 0x51)),
    packet: makeSyncMessage(senderA, base - SyncConstants.HISTORY_WINDOW_MS - 5, 0x51)
  }]);
  t.equalNumber(0, oldExported.getCachedMessageCount(), 'import skips out-of-window messages');

  // ------------------------------------------------------------------
  // stop() cancels the periodic loop.
  // ------------------------------------------------------------------
  const stopScheduler: SyncVirtualScheduler = new SyncVirtualScheduler();
  const stopManager: GossipSyncManager = new GossipSyncManager(myPeerID, delegate, config,
    (delayMs: number, task: () => void): number => stopScheduler.schedule(delayMs, task),
    (handle: number): void => stopScheduler.cancel(handle),
    (): number => clock.now);
  stopManager.start();
  t.equalNumber(1, stopScheduler.activeCount(), 'periodic task pending before stop');
  stopManager.stop();
  t.isFalse(stopManager.isRunning(), 'manager stopped');
  t.equalNumber(0, stopScheduler.activeCount(), 'stop cancels the periodic task');
}
