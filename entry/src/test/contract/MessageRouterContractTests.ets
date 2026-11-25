/**
 * Port of bitchat-android MessageRouterTest.kt plus the HarmonyOS-specific
 * outbox semantics (plan.md OutboxEntry): the 100/peer cap with
 * oldest-first eviction, the 24h TTL boundary, the 5/15/30/60s handshake
 * backoff ladder, the eight-attempt handshake retry budget, the per-entry
 * retry budget for failed sends, and the typed snapshot roundtrip that the
 * encrypted persistence hook consumes.
 *
 * The Android test drives a mocked MeshService through Robolectric; here a
 * recording delegate stands in for the mesh facade and the clock is
 * injected, so the routing semantics run on the host contract harness.
 * Vector timings below mirror the Android test exactly (fakeTime offsets
 * of 6s/7s/9s/31s/61s across the backoff ladder).
 */
import { ContractAssert } from './ContractAssert';
import {
  MessageRouter,
  RouteResult
} from '../../main/ets/service/routing/MessageRouter';
import { MessageRouterDelegate } from '../../main/ets/service/routing/MessageRouter';
import {
  Outbox,
  OutboxEntry,
  OutboxEntrySnapshot,
  OutboxSnapshot
} from '../../main/ets/service/routing/Outbox';
import {
  BcEvents,
  CourierDepositedPayload,
  CourierDeliveredPayload
} from '../../main/ets/common/EventBus';

const PEER_ID: string = 'aaaabbbbccccdddd';
const OTHER_PEER_ID: string = '1111222233334444';
const NOISE_KEY_HEX: string = 'abcd'.repeat(16);

/** Recording mesh facade. */
class RecordingMeshDelegate implements MessageRouterDelegate {
  private readonly connectedPeers: Set<string> = new Set();
  private readonly establishedPeers: Set<string> = new Set();
  private readonly canonicalAliases: Map<string, string> = new Map();
  private readonly nostrCapablePeers: Set<string> = new Set();
  private readonly courierCapablePeers: Set<string> = new Set();
  sendShouldFail: boolean = false;
  handshakeInitiations: string[] = [];
  sendAttempts: number = 0;
  sentContent: string[] = [];
  sentTargets: string[] = [];
  sentMessageIDs: (string | null)[] = [];
  nostrSendShouldFail: boolean = false;
  nostrSends: number = 0;
  nostrTargets: string[] = [];
  nostrContent: string[] = [];
  nostrMessageIDs: string[] = [];
  courierSendShouldFail: boolean = false;
  courierSendShouldThrow: boolean = false;
  courierSends: number = 0;
  courierTargets: string[] = [];
  courierContent: string[] = [];
  courierMessageIDs: string[] = [];
  depositRetries: number = 0;

  setConnected(peerID: string, connected: boolean): void {
    if (connected) {
      this.connectedPeers.add(peerID);
    } else {
      this.connectedPeers.delete(peerID);
    }
  }

  setEstablished(peerID: string, established: boolean): void {
    if (established) {
      this.establishedPeers.add(peerID);
    } else {
      this.establishedPeers.delete(peerID);
    }
  }

  registerAlias(alias: string, canonical: string): void {
    this.canonicalAliases.set(alias, canonical);
  }

  setNostrCapable(peerID: string, capable: boolean): void {
    if (capable) {
      this.nostrCapablePeers.add(peerID);
    } else {
      this.nostrCapablePeers.delete(peerID);
    }
  }

  isConnected(peerID: string): boolean {
    return this.connectedPeers.has(peerID);
  }

  hasEstablishedSession(peerID: string): boolean {
    return this.establishedPeers.has(peerID);
  }

  canonicalConversationId(peerID: string): string {
    const mapped: string | undefined = this.canonicalAliases.get(peerID);
    return mapped !== undefined ? mapped : peerID;
  }

  canSendViaNostr(peerID: string): boolean {
    return this.nostrCapablePeers.has(peerID);
  }

  sendPrivateMessageViaNostr(content: string, targetPeerID: string,
    recipientNickname: string, messageID: string): boolean {
    this.nostrSends += 1;
    if (this.nostrSendShouldFail) {
      return false;
    }
    this.nostrContent.push(content);
    this.nostrTargets.push(targetPeerID);
    this.nostrMessageIDs.push(messageID);
    return true;
  }

  setCourierCapable(peerID: string, capable: boolean): void {
    if (capable) {
      this.courierCapablePeers.add(peerID);
    } else {
      this.courierCapablePeers.delete(peerID);
    }
  }

  canSendViaCourier(peerID: string): boolean {
    return this.courierCapablePeers.has(peerID);
  }

  sendPrivateMessageViaCourier(content: string, targetPeerID: string,
    recipientNickname: string, messageID: string): boolean {
    this.courierSends += 1;
    if (this.courierSendShouldThrow) {
      throw new Error('courier deposit failed');
    }
    if (this.courierSendShouldFail) {
      return false;
    }
    this.courierContent.push(content);
    this.courierTargets.push(targetPeerID);
    this.courierMessageIDs.push(messageID);
    return true;
  }

  retryCourierDeposits(): void {
    this.depositRetries += 1;
  }

  sendPrivateMessage(content: string, toPeerID: string,
    recipientNickname: string, messageID: string | null): void {
    this.sendAttempts += 1;
    if (this.sendShouldFail) {
      throw new Error('transport down');
    }
    this.sentContent.push(content);
    this.sentTargets.push(toPeerID);
    this.sentMessageIDs.push(messageID);
  }

  initiateNoiseHandshake(peerID: string): void {
    this.handshakeInitiations.push(peerID);
  }

  handshakeCount(): number {
    return this.handshakeInitiations.length;
  }

  sentCount(): number {
    return this.sentContent.length;
  }

  sentTimes(content: string): number {
    let count: number = 0;
    for (let i: number = 0; i < this.sentContent.length; i++) {
      if (this.sentContent[i] === content) {
        count += 1;
      }
    }
    return count;
  }
}

/** Records expired notifications without closure-narrowing hazards. */
class ExpiredRecorder {
  ids: string[] = [];

  readonly onExpired: (messageID: string) => void = (messageID: string): void => {
    this.ids.push(messageID);
  };
}

/** Records snapshot changes fired by the outbox. */
class SnapshotRecorder {
  count: number = 0;
  last: OutboxSnapshot | null = null;

  readonly onSnapshotChanged: (snapshot: OutboxSnapshot) => void =
    (snapshot: OutboxSnapshot): void => {
      this.count += 1;
      this.last = snapshot;
    };
}

/** Injected scheduler double. */
class FakeScheduler {
  nextHandle: number = 1;
  handles: number[] = [];
  cancelled: number[] = [];
  delays: number[] = [];
  tasks: (() => void)[] = [];

  readonly schedule: (delayMs: number, task: () => void) => number =
    (delayMs: number, task: () => void): number => {
      const handle: number = this.nextHandle;
      this.nextHandle += 1;
      this.handles.push(handle);
      this.delays.push(delayMs);
      this.tasks.push(task);
      return handle;
    };

  readonly cancel: (handle: number) => void = (handle: number): void => {
    this.cancelled.push(handle);
  };

  runLast(): void {
    if (this.tasks.length === 0) {
      return;
    }
    const task: () => void = this.tasks[this.tasks.length - 1];
    task();
  }
}

function newRouter(delegate: RecordingMeshDelegate,
  clock: () => number): MessageRouter {
  return new MessageRouter(delegate, null, null, null, clock);
}

export function runMessageRouterContractTests(t: ContractAssert): void {
  // Queued message flushes after the peer returns and the session establishes.
  {
    let fakeTime: number = 1000000;
    const delegate: RecordingMeshDelegate = new RecordingMeshDelegate();
    const router: MessageRouter = newRouter(delegate, (): number => fakeTime);
    delegate.setConnected(PEER_ID, false);

    const result: RouteResult = router.sendPrivate('hello', PEER_ID, 'peer', 'msg-1');
    t.equalNumber(RouteResult.QUEUED, result, 'an offline peer queues the message');
    t.equalNumber(0, delegate.sentCount(), 'nothing is sent to an offline peer');
    t.equalNumber(0, delegate.handshakeCount(), 'no handshake is kicked while offline');

    // Peer reappears without a session: handshake kicked immediately.
    delegate.setConnected(PEER_ID, true);
    router.onPeersUpdated([PEER_ID]);
    t.equalNumber(1, delegate.handshakeCount(),
      'peer reappearance kicks the handshake once');
    t.equalNumber(0, delegate.sentCount(), 'nothing is sent before the session exists');

    // Session established: the queued message is sent.
    delegate.setEstablished(PEER_ID, true);
    router.onSessionEstablished(PEER_ID);
    t.equalNumber(1, delegate.sentCount(), 'the queued message is flushed');
    t.equalString('hello', delegate.sentContent[0], 'the flushed content matches');
    t.equalString('msg-1', delegate.sentMessageIDs[0] ?? '', 'the flushed message ID matches');
    t.equalNumber(0, router.getOutbox().getEntryCount(PEER_ID), 'the outbox is empty');
  }

  // The scheduler retries the handshake with the capped 5/15/30/60s backoff.
  {
    let fakeTime: number = 1000000;
    const delegate: RecordingMeshDelegate = new RecordingMeshDelegate();
    const router: MessageRouter = newRouter(delegate, (): number => fakeTime);
    delegate.setConnected(PEER_ID, true);

    const result: RouteResult = router.sendPrivate('hello', PEER_ID, 'peer', 'msg-1');
    t.equalNumber(RouteResult.QUEUED, result, 'a sessionless peer queues the message');
    t.equalNumber(1, delegate.handshakeCount(), 'enqueue kicks the handshake immediately');

    router.tickOutbox(fakeTime);
    t.equalNumber(1, delegate.handshakeCount(), 'the 5s backoff suppresses the first tick');

    fakeTime += 6000;
    router.tickOutbox(fakeTime);
    t.equalNumber(2, delegate.handshakeCount(), 'attempt 2 fires after the 5s backoff');

    fakeTime += 7000;
    router.tickOutbox(fakeTime);
    t.equalNumber(2, delegate.handshakeCount(), 'the 15s backoff is still running');

    fakeTime += 9000;
    router.tickOutbox(fakeTime);
    t.equalNumber(3, delegate.handshakeCount(), 'attempt 3 fires after the 15s backoff');

    fakeTime += 31000;
    router.tickOutbox(fakeTime);
    t.equalNumber(4, delegate.handshakeCount(), 'attempt 4 fires after the 30s backoff');

    fakeTime += 61000;
    router.tickOutbox(fakeTime);
    t.equalNumber(5, delegate.handshakeCount(),
      'attempt 5 fires after the capped 60s backoff');
  }

  // Expired entries are dropped and reported; the TTL boundary is exact.
  {
    let fakeTime: number = 1000000;
    const delegate: RecordingMeshDelegate = new RecordingMeshDelegate();
    const router: MessageRouter = newRouter(delegate, (): number => fakeTime);
    const expired: ExpiredRecorder = new ExpiredRecorder();
    router.onMessageExpired = expired.onExpired;
    delegate.setConnected(PEER_ID, false);

    router.sendPrivate('old message', PEER_ID, 'peer', 'msg-old');

    fakeTime += 86400000;
    router.tickOutbox(fakeTime);
    t.equalNumber(0, expired.ids.length, 'the 24h TTL boundary itself does not expire');

    fakeTime += 1;
    router.tickOutbox(fakeTime);
    t.equalNumber(1, expired.ids.length, 'a past-TTL entry expires');
    t.equalString('msg-old', expired.ids[0], 'the expired message ID is reported');

    // Nothing left to flush even when the peer becomes reachable.
    delegate.setConnected(PEER_ID, true);
    delegate.setEstablished(PEER_ID, true);
    router.tickOutbox(fakeTime);
    t.equalNumber(0, delegate.sentCount(), 'an expired entry is never sent');
  }

  // The outbox cap evicts the oldest and preserves order.
  {
    let fakeTime: number = 1000000;
    const delegate: RecordingMeshDelegate = new RecordingMeshDelegate();
    const router: MessageRouter = newRouter(delegate, (): number => fakeTime);
    const expired: ExpiredRecorder = new ExpiredRecorder();
    router.onMessageExpired = expired.onExpired;
    delegate.setConnected(PEER_ID, false);

    for (let i: number = 0; i <= 100; i++) {
      router.sendPrivate('content-' + i, PEER_ID, 'peer', 'msg-' + i);
    }

    t.equalNumber(1, expired.ids.length, 'the 101st message evicts exactly one entry');
    t.equalString('msg-0', expired.ids[0], 'the oldest message is evicted');

    delegate.setConnected(PEER_ID, true);
    delegate.setEstablished(PEER_ID, true);
    router.onSessionEstablished(PEER_ID);
    t.equalNumber(100, delegate.sentCount(), 'the remaining 100 messages are flushed');
    t.equalString('content-1', delegate.sentContent[0], 'flushing starts at the oldest kept');
    t.equalString('msg-1', delegate.sentMessageIDs[0] ?? '', 'flushing is ordered by enqueue');
    t.equalString('content-100', delegate.sentContent[99], 'flushing ends with the newest');
    t.equalNumber(0, delegate.sentTimes('content-0'), 'the evicted message is never sent');
  }

  // Peer reappearance without pending messages does not kick a handshake.
  {
    let fakeTime: number = 1000000;
    const delegate: RecordingMeshDelegate = new RecordingMeshDelegate();
    const router: MessageRouter = newRouter(delegate, (): number => fakeTime);
    delegate.setConnected(PEER_ID, true);

    router.onPeersUpdated([PEER_ID]);

    t.equalNumber(0, delegate.handshakeCount(),
      'no handshake is kicked without pending messages');
  }

  // An established session sends directly without handshake retry state.
  {
    let fakeTime: number = 1000000;
    const delegate: RecordingMeshDelegate = new RecordingMeshDelegate();
    const router: MessageRouter = newRouter(delegate, (): number => fakeTime);
    delegate.setConnected(PEER_ID, true);
    delegate.setEstablished(PEER_ID, true);

    const result: RouteResult = router.sendPrivate('direct', PEER_ID, 'peer', 'msg-direct');

    t.equalNumber(RouteResult.MESH, result, 'a ready peer is served via mesh');
    t.equalNumber(1, delegate.sentCount(), 'the message is sent exactly once');
    t.equalString('direct', delegate.sentContent[0], 'the direct content matches');
    t.equalNumber(0, delegate.handshakeCount(), 'no handshake is kicked for a ready peer');
  }

  // Handshake retries stop after eight ladder climbs; an immediate kick restarts.
  {
    let fakeTime: number = 1000000;
    const delegate: RecordingMeshDelegate = new RecordingMeshDelegate();
    const router: MessageRouter = newRouter(delegate, (): number => fakeTime);
    delegate.setConnected(PEER_ID, true);

    router.sendPrivate('hello', PEER_ID, 'peer', 'msg-1');
    t.equalNumber(1, delegate.handshakeCount(), 'the enqueue kicks immediately');

    // Climb the ladder: attempts 2..8 across the 5/15/30/60s backoffs.
    const tickTimes: number[] = [6000, 22000, 53000, 114000, 175000, 236000, 297000];
    for (let i: number = 0; i < tickTimes.length; i++) {
      fakeTime = 1000000 + tickTimes[i];
      router.tickOutbox(fakeTime);
    }
    t.equalNumber(8, delegate.handshakeCount(),
      'eight handshake attempts are made in total');

    // The retry budget is exhausted: further ticks do not kick.
    fakeTime = 1000000 + 358000;
    router.tickOutbox(fakeTime);
    t.equalNumber(8, delegate.handshakeCount(),
      'the eighth attempt exhausts the automatic retry budget');

    // A peer reappearance restarts the ladder with an immediate kick.
    router.onPeersUpdated([PEER_ID]);
    t.equalNumber(9, delegate.handshakeCount(),
      'an immediate kick restarts the ladder after the budget');
  }

  // Failed sends retry up to the per-entry budget, then the entry is dropped.
  {
    let fakeTime: number = 1000000;
    const delegate: RecordingMeshDelegate = new RecordingMeshDelegate();
    const router: MessageRouter = newRouter(delegate, (): number => fakeTime);
    const expired: ExpiredRecorder = new ExpiredRecorder();
    router.onMessageExpired = expired.onExpired;
    delegate.setConnected(PEER_ID, true);
    delegate.setEstablished(PEER_ID, true);
    delegate.sendShouldFail = true;

    const result: RouteResult = router.sendPrivate('flaky', PEER_ID, 'peer', 'msg-flaky');
    t.equalNumber(RouteResult.QUEUED, result,
      'a failed direct send falls back to the outbox');

    // Eight flush attempts stay within the retry budget.
    for (let i: number = 0; i < 8; i++) {
      fakeTime += 2000;
      router.tickOutbox(fakeTime);
    }
    t.equalNumber(9, delegate.sendAttempts, 'one direct attempt plus eight retries');
    t.equalNumber(1, router.getOutbox().getEntryCount(PEER_ID),
      'the entry survives its eighth retry');

    // The ninth failure exceeds the budget: drop and report.
    fakeTime += 2000;
    router.tickOutbox(fakeTime);
    t.equalNumber(0, router.getOutbox().getEntryCount(PEER_ID),
      'the entry is dropped after exceeding the retry budget');
    t.equalNumber(1, expired.ids.length, 'the dropped entry is reported');
    t.equalString('msg-flaky', expired.ids[0], 'the dropped message ID is reported');

    delegate.sendShouldFail = false;
    router.tickOutbox(fakeTime);
    t.equalNumber(0, delegate.sentCount(), 'a dropped entry is never sent');
    t.equalNumber(0, delegate.handshakeCount(), 'no handshake is kicked for a ready peer');
  }

  // The outbox snapshot roundtrips content, order and retry state.
  {
    let fakeTime: number = 1000000;
    const delegate: RecordingMeshDelegate = new RecordingMeshDelegate();
    const router: MessageRouter = newRouter(delegate, (): number => fakeTime);
    const snapshots: SnapshotRecorder = new SnapshotRecorder();
    router.getOutbox().onSnapshotChanged = snapshots.onSnapshotChanged;
    delegate.setConnected(PEER_ID, false);
    delegate.setConnected(OTHER_PEER_ID, false);

    router.sendPrivate('first', PEER_ID, 'peer', 'msg-a');
    fakeTime += 1000;
    router.sendPrivate('second', PEER_ID, 'peer', 'msg-b');
    router.sendPrivate('other', OTHER_PEER_ID, 'other', 'msg-c');
    t.isTrue(snapshots.count > 0, 'mutations fire snapshot change notifications');

    const snapshot: OutboxSnapshot = router.getOutbox().toSnapshot();
    t.equalNumber(2, snapshot.conversations.length,
      'the snapshot holds both conversations');

    const restored: Outbox = new Outbox();
    restored.restoreSnapshot(snapshot);
    t.equalNumber(2, restored.getEntryCount(PEER_ID), 'the peer queue is restored');
    t.equalNumber(1, restored.getEntryCount(OTHER_PEER_ID),
      'the other peer queue is restored');
    const entries: OutboxEntry[] | null = restored.getQueuedEntries(PEER_ID);
    if (entries === null) {
      throw new Error('restored queue missing');
    }
    t.equalNumber(2, entries.length, 'both entries are restored');
    t.equalString('msg-a', entries[0].messageID, 'the restore preserves order');
    t.equalString('second', entries[1].content, 'the restore preserves content');
    t.equalNumber(1000000, entries[0].enqueuedAtMs,
      'the restore preserves the enqueue time');
    t.equalString('peer', entries[1].nickname, 'the restore preserves the nickname');

    // Snapshot entries are immutable copies: mutating the live outbox does
    // not change an already captured snapshot.
    const before: OutboxEntrySnapshot[] = snapshot.conversations[0].entries;
    router.sendPrivate('third', PEER_ID, 'peer', 'msg-d');
    t.equalNumber(before.length, 2, 'a captured snapshot is not mutated afterwards');
  }

  // The scheduler starts with the router, stops on demand and ticks when fired.
  {
    let fakeTime: number = 1000000;
    const delegate: RecordingMeshDelegate = new RecordingMeshDelegate();
    const scheduler: FakeScheduler = new FakeScheduler();
    const router: MessageRouter =
      new MessageRouter(delegate, null, scheduler.schedule, scheduler.cancel,
        (): number => fakeTime);

    t.isTrue(router.isSchedulerRunning(), 'the router starts its scheduler');
    t.equalNumber(1, scheduler.handles.length, 'one tick is scheduled');
    t.equalNumber(2000, scheduler.delays[0], 'the tick interval is 2s');

    router.stopOutboxScheduler();
    t.isFalse(router.isSchedulerRunning(), 'the scheduler stops on demand');
    t.equalNumber(1, scheduler.cancelled.length, 'the pending tick is cancelled');

    router.startOutboxScheduler();
    t.isTrue(router.isSchedulerRunning(), 'the scheduler restarts');

    // The scheduled task performs a real tick pass.
    delegate.setConnected(PEER_ID, false);
    const expired: ExpiredRecorder = new ExpiredRecorder();
    router.onMessageExpired = expired.onExpired;
    router.sendPrivate('tick-me', PEER_ID, 'peer', 'msg-tick');
    fakeTime += 86400001;
    scheduler.runLast();
    t.equalNumber(1, expired.ids.length, 'the fired tick expires past-TTL entries');
    t.equalNumber(3, scheduler.handles.length, 'the tick reschedules itself');
  }

  // US12 (T060): a ready mesh session wins; Nostr is the second tier.
  {
    let fakeTime: number = 1000000;
    const delegate: RecordingMeshDelegate = new RecordingMeshDelegate();
    const router: MessageRouter = newRouter(delegate, (): number => fakeTime);
    delegate.setConnected(PEER_ID, true);
    delegate.setEstablished(PEER_ID, true);
    delegate.setNostrCapable(PEER_ID, true);

    const result: RouteResult = router.sendPrivate('mesh-first', PEER_ID, 'peer', 'msg-m1');
    t.equalNumber(RouteResult.MESH, result, 'a ready mesh session wins over Nostr');
    t.equalNumber(1, delegate.sentCount(), 'the message goes over the mesh');
    t.equalNumber(0, delegate.nostrSends, 'Nostr is not touched when mesh is ready');
  }

  // US12 (T060): an offline but Nostr-capable contact is served via Nostr.
  {
    let fakeTime: number = 1000000;
    const delegate: RecordingMeshDelegate = new RecordingMeshDelegate();
    const router: MessageRouter = newRouter(delegate, (): number => fakeTime);
    delegate.setNostrCapable(PEER_ID, true);

    const result: RouteResult = router.sendPrivate('via-nostr', PEER_ID, 'peer', 'msg-n1');
    t.equalNumber(RouteResult.NOSTR, result, 'an offline Nostr contact is served via Nostr');
    t.equalNumber(1, delegate.nostrSends, 'the Nostr send happens exactly once');
    t.equalString('via-nostr', delegate.nostrContent[0], 'the Nostr content matches');
    t.equalString('msg-n1', delegate.nostrMessageIDs[0], 'the Nostr message ID matches');
    t.equalNumber(0, router.getOutbox().getEntryCount(PEER_ID),
      'a Nostr send leaves nothing queued');
    t.equalNumber(0, delegate.handshakeCount(), 'no handshake is kicked while offline');
  }

  // US12 (T060): a failed Nostr send queues; the tick retries via Nostr.
  {
    let fakeTime: number = 1000000;
    const delegate: RecordingMeshDelegate = new RecordingMeshDelegate();
    const router: MessageRouter = newRouter(delegate, (): number => fakeTime);
    const expired: ExpiredRecorder = new ExpiredRecorder();
    router.onMessageExpired = expired.onExpired;
    delegate.setNostrCapable(PEER_ID, true);
    delegate.nostrSendShouldFail = true;

    const result: RouteResult = router.sendPrivate('flaky-nostr', PEER_ID, 'peer', 'msg-n2');
    t.equalNumber(RouteResult.QUEUED, result, 'a failed Nostr send falls back to the outbox');
    t.equalNumber(1, delegate.nostrSends, 'one Nostr attempt was made');
    t.equalNumber(1, router.getOutbox().getEntryCount(PEER_ID),
      'the failed Nostr entry is queued');

    delegate.nostrSendShouldFail = false;
    fakeTime += 2000;
    router.tickOutbox(fakeTime);
    t.equalNumber(2, delegate.nostrSends, 'the tick retries the Nostr send');
    t.equalString('flaky-nostr', delegate.nostrContent[0], 'the retried content matches');
    t.equalNumber(0, router.getOutbox().getEntryCount(PEER_ID),
      'the retried Nostr entry leaves the outbox');
    t.equalNumber(0, expired.ids.length, 'a flushed entry never expires');
  }

  // US12 (T060): failed Nostr flushes burn the per-entry budget (8) then drop.
  {
    let fakeTime: number = 1000000;
    const delegate: RecordingMeshDelegate = new RecordingMeshDelegate();
    const router: MessageRouter = newRouter(delegate, (): number => fakeTime);
    const expired: ExpiredRecorder = new ExpiredRecorder();
    router.onMessageExpired = expired.onExpired;
    delegate.setNostrCapable(PEER_ID, true);
    delegate.nostrSendShouldFail = true;

    router.sendPrivate('nostr-budget', PEER_ID, 'peer', 'msg-n3');
    t.equalNumber(1, delegate.nostrSends, 'the send attempts Nostr once');

    // Eight failed tick flushes stay within the per-entry retry budget.
    for (let i: number = 0; i < 8; i++) {
      fakeTime += 2000;
      router.tickOutbox(fakeTime);
    }
    t.equalNumber(9, delegate.nostrSends, 'one send attempt plus eight retries');
    t.equalNumber(1, router.getOutbox().getEntryCount(PEER_ID),
      'the entry survives its eighth Nostr retry');

    // The ninth failure exceeds the budget: drop and report.
    fakeTime += 2000;
    router.tickOutbox(fakeTime);
    t.equalNumber(10, delegate.nostrSends, 'the ninth Nostr retry exceeds the budget');
    t.equalNumber(0, router.getOutbox().getEntryCount(PEER_ID),
      'the entry is dropped after exceeding the Nostr retry budget');
    t.equalNumber(1, expired.ids.length, 'the dropped Nostr entry is reported');
    t.equalString('msg-n3', expired.ids[0], 'the dropped Nostr message ID is reported');
  }

  // US12 (T060): the flush resolves queues under canonical and raw keys.
  {
    let fakeTime: number = 1000000;
    const delegate: RecordingMeshDelegate = new RecordingMeshDelegate();
    const router: MessageRouter = newRouter(delegate, (): number => fakeTime);

    // Queued before the alias was registered: stored under the raw key.
    const resultA: RouteResult = router.sendPrivate('pre-alias', NOISE_KEY_HEX,
      'peer', 'msg-k1');
    t.equalNumber(RouteResult.QUEUED, resultA, 'an unknown alias queues');
    t.equalNumber(1, router.getOutbox().getEntryCount(NOISE_KEY_HEX),
      'the entry waits under the raw noise-key key');

    delegate.registerAlias(NOISE_KEY_HEX, PEER_ID);
    delegate.setConnected(PEER_ID, true);
    delegate.setEstablished(PEER_ID, true);

    // A canonical-key flush does not see the raw queue...
    router.flushOutboxFor(PEER_ID);
    t.equalNumber(0, delegate.sentCount(),
      'the canonical flush misses the raw-key queue');

    // ...but flushing the alias (onFavoriteChanged path) drains it via mesh.
    router.flushOutboxFor(NOISE_KEY_HEX);
    t.equalNumber(1, delegate.sentCount(), 'the alias flush drains the raw queue');
    t.equalString('pre-alias', delegate.sentContent[0], 'the drained content matches');
    t.equalString('msg-k1', delegate.sentMessageIDs[0] ?? '',
      'the drained message ID matches');
    t.equalNumber(0, router.getOutbox().getEntryCount(NOISE_KEY_HEX),
      'the raw queue is empty after the flush');

    // After registration a new alias send goes straight to the canonical peer.
    const resultB: RouteResult = router.sendPrivate('post-alias', NOISE_KEY_HEX,
      'peer', 'msg-k2');
    t.equalNumber(RouteResult.MESH, resultB,
      'the aliased send routes via the canonical mesh');
    t.equalString(PEER_ID, delegate.sentTargets[1], 'the canonical peer receives the send');
  }

  // US17 (T065): the four-level decision - mesh, Nostr, courier, outbox.
  {
    let fakeTime: number = 1000000;
    const delegate: RecordingMeshDelegate = new RecordingMeshDelegate();
    const router: MessageRouter = newRouter(delegate, (): number => fakeTime);
    delegate.setConnected(PEER_ID, true);
    delegate.setEstablished(PEER_ID, true);
    delegate.setNostrCapable(PEER_ID, true);
    delegate.setCourierCapable(PEER_ID, true);

    const result: RouteResult = router.sendPrivate('mesh-still-first', PEER_ID,
      'peer', 'msg-c0');
    t.equalNumber(RouteResult.MESH, result, 'a ready mesh session wins over every fallback');
    t.equalNumber(1, delegate.sentCount(), 'the message goes over the mesh');
    t.equalNumber(0, delegate.nostrSends, 'Nostr is not touched when mesh is ready');
    t.equalNumber(0, delegate.courierSends, 'Courier is not touched when mesh is ready');
  }

  // US17 (T065): Nostr outranks the courier tier.
  {
    let fakeTime: number = 1000000;
    const delegate: RecordingMeshDelegate = new RecordingMeshDelegate();
    const router: MessageRouter = newRouter(delegate, (): number => fakeTime);
    delegate.setNostrCapable(PEER_ID, true);
    delegate.setCourierCapable(PEER_ID, true);

    const result: RouteResult = router.sendPrivate('nostr-second', PEER_ID,
      'peer', 'msg-c1');
    t.equalNumber(RouteResult.NOSTR, result, 'an online Nostr contact beats the courier tier');
    t.equalNumber(1, delegate.nostrSends, 'the Nostr send happens exactly once');
    t.equalNumber(0, delegate.courierSends, 'the courier tier is not touched');
  }

  // US17 (T065): a courier-capable contact is served via the sealed-envelope tier.
  {
    let fakeTime: number = 1000000;
    const delegate: RecordingMeshDelegate = new RecordingMeshDelegate();
    const router: MessageRouter = newRouter(delegate, (): number => fakeTime);
    delegate.setCourierCapable(PEER_ID, true);

    t.equalNumber(4, RouteResult.COURIER, 'the courier result holds the reserved enum slot');
    const result: RouteResult = router.sendPrivate('via-courier', PEER_ID,
      'peer', 'msg-c2');
    t.equalNumber(RouteResult.COURIER, result, 'a courier-capable contact is served via courier');
    t.equalNumber(1, delegate.courierSends, 'the courier deposit happens exactly once');
    t.equalString('via-courier', delegate.courierContent[0], 'the courier content matches');
    t.equalString(PEER_ID, delegate.courierTargets[0], 'the courier target matches');
    t.equalString('msg-c2', delegate.courierMessageIDs[0], 'the courier message ID matches');
    t.equalNumber(0, router.getOutbox().getEntryCount(PEER_ID),
      'a courier send leaves nothing queued');
  }

  // US17 (T065): a failed courier deposit falls through to the outbox.
  {
    let fakeTime: number = 1000000;
    const delegate: RecordingMeshDelegate = new RecordingMeshDelegate();
    const router: MessageRouter = newRouter(delegate, (): number => fakeTime);
    delegate.setCourierCapable(PEER_ID, true);
    delegate.courierSendShouldFail = true;

    const result: RouteResult = router.sendPrivate('flaky-courier', PEER_ID,
      'peer', 'msg-c3');
    t.equalNumber(RouteResult.QUEUED, result, 'a failed courier deposit falls back to the outbox');
    t.equalNumber(1, delegate.courierSends, 'one courier attempt was made');
    t.equalNumber(1, router.getOutbox().getEntryCount(PEER_ID),
      'the failed courier entry is queued');

    delegate.courierSendShouldFail = false;
    fakeTime += 2000;
    router.tickOutbox(fakeTime);
    t.equalNumber(1, router.getOutbox().getEntryCount(PEER_ID),
      'the queued entry survives while the peer is unreachable');
    delegate.setConnected(PEER_ID, true);
    delegate.setEstablished(PEER_ID, true);
    router.onSessionEstablished(PEER_ID);
    t.equalNumber(0, router.getOutbox().getEntryCount(PEER_ID),
      'the queued entry flushes once the mesh session is ready');
    t.equalNumber(1, delegate.sentCount(), 'the flushed entry goes over the mesh');
  }

  // US17 (T065): a throwing courier deposit queues like any other failure.
  {
    let fakeTime: number = 1000000;
    const delegate: RecordingMeshDelegate = new RecordingMeshDelegate();
    const router: MessageRouter = newRouter(delegate, (): number => fakeTime);
    delegate.setCourierCapable(PEER_ID, true);
    delegate.courierSendShouldThrow = true;

    const result: RouteResult = router.sendPrivate('throwing-courier', PEER_ID,
      'peer', 'msg-c4');
    t.equalNumber(RouteResult.QUEUED, result, 'a throwing courier deposit falls back to the outbox');
    t.equalNumber(1, router.getOutbox().getEntryCount(PEER_ID),
      'the thrown courier entry is queued');
  }

  // US17 (T065): a new qualified courier connection retries pending deposits.
  {
    let fakeTime: number = 1000000;
    const delegate: RecordingMeshDelegate = new RecordingMeshDelegate();
    const router: MessageRouter = newRouter(delegate, (): number => fakeTime);

    t.equalNumber(0, delegate.depositRetries, 'no deposit retry happened yet');
    router.onCourierConnected();
    t.equalNumber(1, delegate.depositRetries, 'a new courier triggers one deposit retry');
    router.onCourierConnected();
    t.equalNumber(2, delegate.depositRetries, 'every new courier triggers a retry');
  }

  // US17 (T065): the courier EventBus contract - event names and payloads.
  {
    t.equalString('courier-deposited', BcEvents.COURIER_DEPOSITED,
      'the deposited event name is fixed');
    t.equalString('courier-delivered', BcEvents.COURIER_DELIVERED,
      'the delivered event name is fixed');
    const deposited: CourierDepositedPayload = new CourierDepositedPayload('env-1', 'courier-a');
    t.equalString(BcEvents.COURIER_DEPOSITED, deposited.eventName,
      'the deposited payload carries its event name');
    t.equalString('env-1', deposited.envelopeID, 'the deposited payload carries the envelope ID');
    t.equalString('courier-a', deposited.courierPeerID, 'the deposited payload carries the courier');
    const delivered: CourierDeliveredPayload = new CourierDeliveredPayload('env-2', 'peer-b');
    t.equalString(BcEvents.COURIER_DELIVERED, delivered.eventName,
      'the delivered payload carries its event name');
    t.equalString('env-2', delivered.envelopeID, 'the delivered payload carries the envelope ID');
    t.equalString('peer-b', delivered.recipientPeerID, 'the delivered payload carries the recipient');
  }
}
