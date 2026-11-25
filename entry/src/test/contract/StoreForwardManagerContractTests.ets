/**
 * Contract vectors for the store-and-forward manager (T064, spec US17 /
 * FR-034, plan D11), mirrored from bitchat-android StoreForwardManager.kt:
 * the global regular cache capped at 100 with a 12h age-out, per-peer
 * favorite queues capped at 1000 that are never aged out, the Android
 * cache skip list, one replay per peer per tracking window with 10ms
 * pacing between replayed packets (first packet immediate), delivered-ID
 * dedup, the wholesale tracking trims (delivered 1000 / replay-once 200),
 * the 10-minute cleanup loop and clearAllCache.
 */
import { ContractAssert } from './ContractAssert';
import { ByteUtils } from '../../main/ets/common/ByteUtils';
import { StoreForwardManagerDeps } from '../../main/ets/service/mesh/StoreForwardManager';
import { StoreForwardManager } from '../../main/ets/service/mesh/StoreForwardManager';
import {
  BitchatPacket,
  MessageType,
  specialRecipientBroadcast
} from '../../main/ets/model/BitchatPacket';
import { StoreForwardConstants } from '../../main/ets/common/ProtocolConstants';

function messagePacket(payload: string, recipient: Uint8Array): BitchatPacket {
  return new BitchatPacket(2, MessageType.MESSAGE, ByteUtils.hexToBytes('1020304050607080'),
    recipient, 1737000000000, ByteUtils.utf8Encode(payload), null, 7, null);
}

class ScheduledTask {
  readonly delayMs: number;
  readonly task: () => void;
  cancelled: boolean;

  constructor(delayMs: number, task: () => void) {
    this.delayMs = delayMs;
    this.task = task;
    this.cancelled = false;
  }
}

class FakeScheduler {
  private nextHandle: number = 1;
  private readonly byHandle: Map<number, ScheduledTask> = new Map();
  readonly tasks: ScheduledTask[] = [];

  schedule(delayMs: number, task: () => void): number {
    const handle: number = this.nextHandle;
    this.nextHandle += 1;
    const entry: ScheduledTask = new ScheduledTask(delayMs, task);
    this.tasks.push(entry);
    this.byHandle.set(handle, entry);
    return handle;
  }

  cancel(handle: number): void {
    const entry: ScheduledTask | undefined = this.byHandle.get(handle);
    if (entry !== undefined) {
      entry.cancelled = true;
    }
  }

  run(index: number): void {
    const entry: ScheduledTask | undefined = this.tasks[index];
    if (entry !== undefined && !entry.cancelled) {
      entry.task();
    }
  }

  runAll(): void {
    for (let i: number = 0; i < this.tasks.length; i++) {
      this.run(i);
    }
  }

  delays(): number[] {
    const out: number[] = [];
    for (let i: number = 0; i < this.tasks.length; i++) {
      out.push(this.tasks[i].delayMs);
    }
    return out;
  }
}

class FakeStoreForwardDeps implements StoreForwardManagerDeps {
  now: number = 1737000000000;
  readonly favorites: Set<string> = new Set();
  readonly online: Set<string> = new Set();
  readonly sent: BitchatPacket[] = [];
  readonly scheduler: FakeScheduler = new FakeScheduler();
  readonly nowMs: () => number = (): number => this.now;
  readonly isFavorite: (peerID: string) => boolean =
    (peerID: string): boolean => this.favorites.has(peerID);
  readonly isPeerOnline: (peerID: string) => boolean =
    (peerID: string): boolean => this.online.has(peerID);
  readonly sendPacket: (packet: BitchatPacket) => void =
    (packet: BitchatPacket): void => {
      this.sent.push(packet);
    };
  readonly schedule: (delayMs: number, task: () => void) => number =
    (delayMs: number, task: () => void): number => this.scheduler.schedule(delayMs, task);
  readonly cancel: (handle: number) => void =
    (handle: number): void => this.scheduler.cancel(handle);
}

function sentPayloadIs(deps: FakeStoreForwardDeps, index: number, expected: string): boolean {
  const packet: BitchatPacket | undefined = deps.sent[index];
  if (packet === undefined) {
    return false;
  }
  return ByteUtils.equals(ByteUtils.utf8Encode(expected), packet.payload);
}

export function runStoreForwardManagerContractTests(t: ContractAssert): void {
  const peerA: Uint8Array = ByteUtils.hexToBytes('0011223344556677');
  const peerB: Uint8Array = ByteUtils.hexToBytes('8899aabbccddeeff');
  const peerAID: string = '0011223344556677';
  const peerBID: string = '8899aabbccddeeff';

  // Plan constants not locked by CourierModelsContractTests.
  {
    t.equalNumber(100, StoreForwardConstants.MAX_CACHED_MESSAGES,
      'the regular cache holds at most 100 entries');
    t.equalNumber(600000, StoreForwardConstants.CLEANUP_INTERVAL_MS,
      'the cleanup loop runs every 10 minutes');
    t.equalNumber(1000, StoreForwardManager.DELIVERED_IDS_MAX,
      'delivered-ID tracking is trimmed past 1000 entries');
    t.equalNumber(200, StoreForwardManager.SENT_TRACKING_MAX,
      'replay-once tracking is trimmed past 200 peers');
  }

  // cache(): the Android skip list plus routing between the regular cache
  // and the per-peer favorite queue.
  {
    const deps: FakeStoreForwardDeps = new FakeStoreForwardDeps();
    const manager: StoreForwardManager = new StoreForwardManager(deps);
    t.isTrue(manager.cache(messagePacket('ok-1', peerA), 'ok-1'),
      'a directed MESSAGE for a regular peer is cached');
    t.equalNumber(1, manager.getCachedMessageCount(peerAID), 'the regular cache counts it');
    deps.favorites.add(peerBID);
    t.isTrue(manager.cache(messagePacket('fav-1', peerB), 'fav-1'),
      'a directed MESSAGE for a favorite is cached');
    t.equalNumber(1, manager.getCachedMessageCount(peerBID), 'the favorite queue counts it');
    t.isFalse(manager.cache(new BitchatPacket(2, MessageType.NOISE_HANDSHAKE,
      ByteUtils.hexToBytes('1020304050607080'), peerA, 1737000000000,
      ByteUtils.utf8Encode('x'), null, 7, null), 'h-1'),
      'NOISE_HANDSHAKE is never cached');
    t.isFalse(manager.cache(new BitchatPacket(2, MessageType.NOISE_ENCRYPTED,
      ByteUtils.hexToBytes('1020304050607080'), peerA, 1737000000000,
      ByteUtils.utf8Encode('x'), null, 7, null), 'h-2'),
      'NOISE_ENCRYPTED is never cached');
    t.isFalse(manager.cache(new BitchatPacket(2, MessageType.ANNOUNCE,
      ByteUtils.hexToBytes('1020304050607080'), peerA, 1737000000000,
      ByteUtils.utf8Encode('x'), null, 7, null), 'h-3'),
      'ANNOUNCE is never cached');
    t.isFalse(manager.cache(new BitchatPacket(2, MessageType.LEAVE,
      ByteUtils.hexToBytes('1020304050607080'), peerA, 1737000000000,
      ByteUtils.utf8Encode('x'), null, 7, null), 'h-4'),
      'LEAVE is never cached');
    t.isFalse(manager.cache(messagePacket('b-1', specialRecipientBroadcast()), 'b-1'),
      'a broadcast is never cached');
    t.isFalse(manager.cache(new BitchatPacket(2, MessageType.MESSAGE,
      ByteUtils.hexToBytes('1020304050607080'), null, 1737000000000,
      ByteUtils.utf8Encode('n-1'), null, 7, null), 'n-1'),
      'a packet without a recipient is never cached');
    t.equalNumber(1, manager.getCachedMessageCount(peerAID),
      'rejected packets leave the cache untouched');
  }

  // shouldCacheForPeer(): offline favorites only.
  {
    const deps: FakeStoreForwardDeps = new FakeStoreForwardDeps();
    const manager: StoreForwardManager = new StoreForwardManager(deps);
    deps.favorites.add(peerAID);
    t.isTrue(manager.shouldCacheForPeer(peerAID),
      'an offline favorite should be cached for');
    deps.online.add(peerAID);
    t.isFalse(manager.shouldCacheForPeer(peerAID),
      'an online favorite needs no cache');
    deps.online.delete(peerAID);
    deps.favorites.delete(peerAID);
    t.isFalse(manager.shouldCacheForPeer(peerAID),
      'an offline non-favorite is not cached for');
    deps.online.add(peerAID);
    t.isFalse(manager.shouldCacheForPeer(peerAID),
      'an online non-favorite is not cached for');
  }

  // Regular cache: global cap of 100, oldest evicted first (FIFO).
  {
    const deps: FakeStoreForwardDeps = new FakeStoreForwardDeps();
    const manager: StoreForwardManager = new StoreForwardManager(deps);
    for (let i: number = 0; i <= 100; i++) {
      const cached: boolean = manager.cache(messagePacket('m-' + i.toString(), peerA),
        'm-' + i.toString());
      if (!cached) {
        throw new Error('regular cache entry ' + i.toString() + ' was rejected');
      }
      deps.now += 1;
    }
    const replayed: number = manager.onPeerOnline(peerAID);
    t.equalNumber(100, replayed, 'the 101st regular entry evicted the oldest');
    t.isTrue(sentPayloadIs(deps, 0, 'm-1'), 'the evicted m-0 is never replayed');
    deps.scheduler.runAll();
    t.equalNumber(100, deps.sent.length, 'exactly 100 entries were replayed');
    t.isTrue(sentPayloadIs(deps, 99, 'm-100'), 'the newest entry is replayed last');
    t.equalNumber(0, manager.getCachedMessageCount(peerAID),
      'the regular cache is empty after the replay');
  }

  // Favorite queue: per-peer cap of 1000, oldest evicted first.
  {
    const deps: FakeStoreForwardDeps = new FakeStoreForwardDeps();
    const manager: StoreForwardManager = new StoreForwardManager(deps);
    deps.favorites.add(peerAID);
    for (let i: number = 0; i <= 1000; i++) {
      manager.cache(messagePacket('f-' + i.toString(), peerA), 'f-' + i.toString());
      deps.now += 1;
    }
    const replayed: number = manager.onPeerOnline(peerAID);
    t.equalNumber(1000, replayed, 'the 1001st favorite entry evicted the oldest');
    t.isTrue(sentPayloadIs(deps, 0, 'f-1'), 'the evicted f-0 is never replayed');
    deps.scheduler.runAll();
    t.equalNumber(1000, deps.sent.length, 'exactly 1000 entries were replayed');
    t.isTrue(sentPayloadIs(deps, 999, 'f-1000'), 'the newest entry is replayed last');
  }

  // onPeerOnline(): favorite queue and regular entries merge in cached-at
  // order, the first packet goes out immediately, then one every 10ms.
  {
    const deps: FakeStoreForwardDeps = new FakeStoreForwardDeps();
    const manager: StoreForwardManager = new StoreForwardManager(deps);
    manager.cache(messagePacket('r-1', peerA), 'r-1');
    deps.now += 10;
    deps.favorites.add(peerAID);
    manager.cache(messagePacket('fav-1', peerA), 'fav-1');
    deps.now += 10;
    manager.cache(messagePacket('fav-2', peerA), 'fav-2');
    manager.cache(messagePacket('other-1', peerB), 'other-1');
    const replayed: number = manager.onPeerOnline(peerAID);
    t.equalNumber(3, replayed, 'queue and regular entries merge');
    t.equalNumber(1, deps.sent.length, 'only the first packet is sent immediately');
    t.isTrue(sentPayloadIs(deps, 0, 'r-1'), 'the oldest entry is sent first');
    const delays: number[] = deps.scheduler.delays();
    t.equalNumber(2, delays.length, 'the remaining packets are paced');
    t.equalNumber(10, delays[0], 'the second packet follows after 10ms');
    t.equalNumber(20, delays[1], 'the third packet follows after 20ms');
    deps.scheduler.run(0);
    t.isTrue(sentPayloadIs(deps, 1, 'fav-1'), 'the second packet is the older favorite');
    deps.scheduler.run(1);
    t.isTrue(sentPayloadIs(deps, 2, 'fav-2'), 'the third packet is the newer favorite');
    t.equalNumber(0, manager.getCachedMessageCount(peerAID),
      'peer A leaves no cached entries behind');
    t.equalNumber(1, manager.getCachedMessageCount(peerBID),
      'peer B keeps its cached entry');
  }

  // onPeerOnline(): one replay per peer per tracking window.
  {
    const deps: FakeStoreForwardDeps = new FakeStoreForwardDeps();
    const manager: StoreForwardManager = new StoreForwardManager(deps);
    manager.cache(messagePacket('a-1', peerA), 'a-1');
    t.equalNumber(1, manager.onPeerOnline(peerAID), 'the first replay serves the cache');
    manager.cache(messagePacket('a-2', peerA), 'a-2');
    t.equalNumber(0, manager.onPeerOnline(peerAID),
      'a peer is served once per tracking window');
    t.equalNumber(1, deps.sent.length, 'no second replay happened');
    for (let i: number = 0; i < 200; i++) {
      manager.onPeerOnline('fill-' + i.toString());
    }
    manager.cleanupNow();
    manager.cache(messagePacket('a-3', peerA), 'a-3');
    t.equalNumber(2, manager.onPeerOnline(peerAID),
      'the 200-peer trim re-enables replay for served peers');
    deps.scheduler.runAll();
    t.equalNumber(3, deps.sent.length, 'the missed entry and the new entry are both replayed');
    t.isTrue(sentPayloadIs(deps, 1, 'a-2'), 'the entry missed by the one-shot window is served');
    t.isTrue(sentPayloadIs(deps, 2, 'a-3'), 'the entry cached after the trim is served');
  }

  // Delivered IDs are never replayed; duplicate IDs collapse; the
  // 1000-entry trim forgets them wholesale.
  {
    const deps: FakeStoreForwardDeps = new FakeStoreForwardDeps();
    const manager: StoreForwardManager = new StoreForwardManager(deps);
    manager.cache(messagePacket('d-1', peerA), 'd-1');
    manager.markMessageAsDelivered('d-1');
    t.equalNumber(0, manager.onPeerOnline(peerAID),
      'a delivered message ID is never replayed');

    const deps2: FakeStoreForwardDeps = new FakeStoreForwardDeps();
    const manager2: StoreForwardManager = new StoreForwardManager(deps2);
    manager2.cache(messagePacket('dup', peerA), 'dup');
    manager2.cache(messagePacket('dup', peerA), 'dup');
    t.equalNumber(2, manager2.onPeerOnline(peerAID),
      'within-batch copies are both replayed (Android collects before marking delivered)');
    deps2.scheduler.runAll();
    t.equalNumber(2, deps2.sent.length, 'both copies were sent');

    const deps3: FakeStoreForwardDeps = new FakeStoreForwardDeps();
    const manager3: StoreForwardManager = new StoreForwardManager(deps3);
    manager3.markMessageAsDelivered('x');
    for (let i: number = 0; i <= 1000; i++) {
      manager3.markMessageAsDelivered('bulk-' + i.toString());
    }
    manager3.cleanupNow();
    manager3.cache(messagePacket('x', peerB), 'x');
    t.equalNumber(1, manager3.onPeerOnline(peerBID),
      'the delivered-ID trim forgets old IDs wholesale');
  }

  // cleanupNow(): the 12h age-out hits the regular cache only.
  {
    const deps: FakeStoreForwardDeps = new FakeStoreForwardDeps();
    const manager: StoreForwardManager = new StoreForwardManager(deps);
    manager.cache(messagePacket('e-1', peerA), 'e-1');
    deps.now += StoreForwardConstants.MESSAGE_CACHE_TIMEOUT_MS;
    manager.cleanupNow();
    t.equalNumber(0, manager.getCachedMessageCount(peerAID),
      'a regular entry expires at the 12h timeout');

    const deps2: FakeStoreForwardDeps = new FakeStoreForwardDeps();
    const manager2: StoreForwardManager = new StoreForwardManager(deps2);
    deps2.favorites.add(peerAID);
    manager2.cache(messagePacket('e-2', peerA), 'e-2');
    deps2.now += StoreForwardConstants.MESSAGE_CACHE_TIMEOUT_MS + 3600000;
    manager2.cleanupNow();
    t.equalNumber(1, manager2.getCachedMessageCount(peerAID),
      'favorite-queued entries are never aged out');
    t.equalNumber(1, manager2.onPeerOnline(peerAID),
      'a 13h-old favorite entry is still replayed');
  }

  // Periodic cleanup: 10-minute cadence, self-rescheduling, idempotent
  // start, and stop cancels the pending tick.
  {
    const deps: FakeStoreForwardDeps = new FakeStoreForwardDeps();
    const manager: StoreForwardManager = new StoreForwardManager(deps);
    manager.cache(messagePacket('p-1', peerA), 'p-1');
    manager.startPeriodicCleanup();
    t.equalNumber(1, deps.scheduler.tasks.length, 'starting the loop schedules one tick');
    t.equalNumber(600000, deps.scheduler.delays()[0], 'the first tick fires in 10 minutes');
    deps.now += StoreForwardConstants.MESSAGE_CACHE_TIMEOUT_MS;
    deps.scheduler.run(0);
    t.equalNumber(0, manager.getCachedMessageCount(peerAID),
      'the tick runs the 12h age-out');
    t.equalNumber(2, deps.scheduler.tasks.length, 'the tick reschedules itself');
    manager.startPeriodicCleanup();
    t.equalNumber(2, deps.scheduler.tasks.length, 'a second start is a no-op');
    manager.stopPeriodicCleanup();
    t.isTrue(deps.scheduler.tasks[1].cancelled, 'stopping cancels the pending tick');
    deps.scheduler.run(1);
    t.equalNumber(2, deps.scheduler.tasks.length, 'a cancelled tick does not reschedule');
    manager.startPeriodicCleanup();
    t.equalNumber(3, deps.scheduler.tasks.length, 'restarting schedules a fresh tick');
    t.equalNumber(600000, deps.scheduler.delays()[2], 'the fresh tick fires in 10 minutes');
    manager.stopPeriodicCleanup();
  }

  // clearAllCache(): every queue and all tracking is dropped.
  {
    const deps: FakeStoreForwardDeps = new FakeStoreForwardDeps();
    const manager: StoreForwardManager = new StoreForwardManager(deps);
    deps.favorites.add(peerAID);
    manager.cache(messagePacket('c-1', peerA), 'c-1');
    manager.cache(messagePacket('c-2', peerB), 'c-2');
    manager.markMessageAsDelivered('c-1');
    t.equalNumber(1, manager.getCachedMessageCount(peerAID), 'peer A has one entry');
    t.equalNumber(1, manager.getCachedMessageCount(peerBID), 'peer B has one entry');
    manager.clearAllCache();
    t.equalNumber(0, manager.getCachedMessageCount(peerAID), 'peer A is empty');
    t.equalNumber(0, manager.getCachedMessageCount(peerBID), 'peer B is empty');
    t.equalNumber(0, manager.onPeerOnline(peerAID), 'the tracking window is empty too');
  }
}
