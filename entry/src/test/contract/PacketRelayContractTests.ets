/**
 * Contract tests for the T027 controlled-flooding relay (FR-004):
 * - split horizon + deterministic TTL-1 forwarding on thin/mid graphs
 * - dense-graph broadcast TTL clamp to 5 and log2(degree) message-ID-seeded
 *   deterministic subset fanout for broadcast MESSAGE only
 * - ANNOUNCE/FRAGMENT stay full-fanout under density (still TTL-clamped)
 * - directed traffic is full fanout, never clamped, plain TTL-1
 * - forwarding jitter 10-220ms, span widened (x2) when dense
 * - REQUEST_SYNC / expired TTL / addressed-to-me / own packets never relay
 * - duplicate arrival cancels the pending relay; relay toggle; shutdown
 * All schedulers and the RNG are injected so no timers run on the host.
 */
import { ContractAssert } from './ContractAssert';
import { PacketRelay } from '../../main/ets/service/mesh/PacketRelay';
import { PacketRelayDelegate } from '../../main/ets/service/mesh/PacketRelay';
import { RoutedPacket } from '../../main/ets/service/mesh/PacketProcessor';
import { BitchatPacket, MessageType, specialRecipientBroadcast } from '../../main/ets/model/BitchatPacket';
import { ByteUtils } from '../../main/ets/common/ByteUtils';

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

/** Manual scheduler: tasks collect until fired by name, cancellable. */
class VirtualScheduler {
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

  activeCount(): number {
    let count: number = 0;
    for (let i: number = 0; i < this.tasks.length; i++) {
      if (!this.tasks[i].cancelled && this.tasks[i].task !== null) {
        count += 1;
      }
    }
    return count;
  }
}

class RelayTestDelegate implements PacketRelayDelegate {
  linkIds: string[] = [];
  sends: string[] = [];

  getConnectedLinkIds(): string[] {
    return this.linkIds;
  }

  sendOnLink(linkId: string, packet: BitchatPacket): boolean {
    this.sends.push(linkId + '@' + packet.ttl);
    return true;
  }
}

function makeRelayPacket(type: number, recipient: Uint8Array | null, ttl: number,
  timestamp: number): BitchatPacket {
  return new BitchatPacket(1, type, new Uint8Array(8), recipient, timestamp,
    new Uint8Array([0xAB, 0xCD]), null, ttl, null);
}

function linksOf(delegate: RelayTestDelegate): string[] {
  const links: string[] = [];
  for (let i: number = 0; i < delegate.sends.length; i++) {
    links.push(delegate.sends[i].split('@')[0]);
  }
  links.sort();
  return links;
}

export function runPacketRelayContractTests(t: ContractAssert): void {
  const myPeerID: string = '0011223344556677';
  const sender: string = '9988776655443322';
  const halfRng: () => number = (): number => {
    return 0.5;
  };

  // ------------------------------------------------------------------
  // isPacketAddressedToMe semantics.
  // ------------------------------------------------------------------
  const scheduler0: VirtualScheduler = new VirtualScheduler();
  const delegate0: RelayTestDelegate = new RelayTestDelegate();
  const relay0: PacketRelay = new PacketRelay(myPeerID, delegate0,
    (delayMs: number, task: () => void): number => scheduler0.schedule(delayMs, task),
    (handle: number): void => scheduler0.cancel(handle), halfRng);
  t.isFalse(relay0.isPacketAddressedToMe(makeRelayPacket(MessageType.MESSAGE, null, 7, 1)),
    'null recipient is not addressed to me');
  t.isFalse(relay0.isPacketAddressedToMe(
    makeRelayPacket(MessageType.MESSAGE, specialRecipientBroadcast(), 7, 2)),
    'broadcast recipient is not addressed to me');
  t.isTrue(relay0.isPacketAddressedToMe(
    makeRelayPacket(MessageType.MESSAGE, ByteUtils.hexToBytes(myPeerID), 7, 3)),
    'specific recipient matching my ID is addressed to me');
  t.isFalse(relay0.isPacketAddressedToMe(
    makeRelayPacket(MessageType.MESSAGE, ByteUtils.hexToBytes('fffffffffffffffe'), 7, 4)),
    'other specific recipient is not addressed to me');

  // ------------------------------------------------------------------
  // Thin graph (2 links): split horizon, full depth, TTL-1, 115ms jitter.
  // ------------------------------------------------------------------
  const thinScheduler: VirtualScheduler = new VirtualScheduler();
  const thinDelegate: RelayTestDelegate = new RelayTestDelegate();
  thinDelegate.linkIds = ['L1', 'L2'];
  const thinRelay: PacketRelay = new PacketRelay(myPeerID, thinDelegate,
    (delayMs: number, task: () => void): number => thinScheduler.schedule(delayMs, task),
    (handle: number): void => thinScheduler.cancel(handle), halfRng);
  thinRelay.considerRelay(new RoutedPacket(
    makeRelayPacket(MessageType.MESSAGE, specialRecipientBroadcast(), 7, 100),
    sender, null, 'L1'));
  t.equalNumber(1, thinScheduler.activeCount(), 'thin relay schedules one relay task');
  t.equalNumber(115, thinScheduler.tasks[0].delayMs, 'thin jitter is 115ms at rng 0.5');
  thinScheduler.fire(1);
  t.equalString('L2@6', thinDelegate.sends.join(','), 'thin relay: split horizon, TTL-1');

  // ------------------------------------------------------------------
  // Mid graph (4 links): full fanout (no subset), TTL-1, thin jitter.
  // ------------------------------------------------------------------
  const midScheduler: VirtualScheduler = new VirtualScheduler();
  const midDelegate: RelayTestDelegate = new RelayTestDelegate();
  midDelegate.linkIds = ['L1', 'L2', 'L3', 'L4'];
  const midRelay: PacketRelay = new PacketRelay(myPeerID, midDelegate,
    (delayMs: number, task: () => void): number => midScheduler.schedule(delayMs, task),
    (handle: number): void => midScheduler.cancel(handle), halfRng);
  midRelay.considerRelay(new RoutedPacket(
    makeRelayPacket(MessageType.MESSAGE, specialRecipientBroadcast(), 7, 200),
    sender, null, 'L1'));
  midScheduler.fire(1);
  t.equalNumber(3, midDelegate.sends.length, 'mid graph fans out to all non-ingress links');
  t.equalString('L2,L3,L4', linksOf(midDelegate).join(','), 'mid graph full fanout, no ingress');
  for (let i: number = 0; i < midDelegate.sends.length; i++) {
    t.isTrue(midDelegate.sends[i].endsWith('@6'), 'mid graph relays at TTL-1');
  }

  // ------------------------------------------------------------------
  // Dense graph (8 links): broadcast MESSAGE TTL clamped to 5 and a
  // deterministic log2(8)=3-link subset; widened 220ms jitter.
  // ------------------------------------------------------------------
  const denseScheduler: VirtualScheduler = new VirtualScheduler();
  const denseDelegate: RelayTestDelegate = new RelayTestDelegate();
  denseDelegate.linkIds = ['L1', 'L2', 'L3', 'L4', 'L5', 'L6', 'L7', 'L8'];
  const denseRelay: PacketRelay = new PacketRelay(myPeerID, denseDelegate,
    (delayMs: number, task: () => void): number => denseScheduler.schedule(delayMs, task),
    (handle: number): void => denseScheduler.cancel(handle), halfRng);
  const denseMessage: BitchatPacket =
    makeRelayPacket(MessageType.MESSAGE, specialRecipientBroadcast(), 7, 300);
  denseRelay.considerRelay(new RoutedPacket(denseMessage, sender, null, 'L1'));
  t.equalNumber(220, denseScheduler.tasks[0].delayMs, 'dense jitter widens to 220ms at rng 0.5');
  denseScheduler.fire(1);
  t.equalNumber(3, denseDelegate.sends.length, 'dense broadcast MESSAGE subsets to log2(degree) links');
  const denseLinks: string[] = linksOf(denseDelegate);
  t.isFalse(denseLinks.indexOf('L1') >= 0, 'subset never includes the ingress link');
  for (let i: number = 0; i < denseDelegate.sends.length; i++) {
    t.isTrue(denseDelegate.sends[i].endsWith('@5'), 'dense broadcast TTL clamped to 5');
  }

  // Determinism: the same message seeds the same subset on another relay.
  const denseScheduler2: VirtualScheduler = new VirtualScheduler();
  const denseDelegate2: RelayTestDelegate = new RelayTestDelegate();
  denseDelegate2.linkIds = ['L1', 'L2', 'L3', 'L4', 'L5', 'L6', 'L7', 'L8'];
  const denseRelay2: PacketRelay = new PacketRelay(myPeerID, denseDelegate2,
    (delayMs: number, task: () => void): number => denseScheduler2.schedule(delayMs, task),
    (handle: number): void => denseScheduler2.cancel(handle), halfRng);
  denseRelay2.considerRelay(new RoutedPacket(denseMessage, sender, null, 'L1'));
  denseScheduler2.fire(1);
  t.equalString(linksOf(denseDelegate).join(','), linksOf(denseDelegate2).join(','),
    'same message ID selects the same subset');

  // ------------------------------------------------------------------
  // ANNOUNCE / FRAGMENT stay full-fanout under density, TTL still clamped.
  // ------------------------------------------------------------------
  const announceDelegate: RelayTestDelegate = new RelayTestDelegate();
  announceDelegate.linkIds = ['L1', 'L2', 'L3', 'L4', 'L5', 'L6', 'L7', 'L8'];
  const announceScheduler: VirtualScheduler = new VirtualScheduler();
  const announceRelay: PacketRelay = new PacketRelay(myPeerID, announceDelegate,
    (delayMs: number, task: () => void): number => announceScheduler.schedule(delayMs, task),
    (handle: number): void => announceScheduler.cancel(handle), halfRng);
  announceRelay.considerRelay(new RoutedPacket(
    makeRelayPacket(MessageType.ANNOUNCE, specialRecipientBroadcast(), 7, 400),
    sender, null, 'L1'));
  announceScheduler.fire(1);
  t.equalNumber(7, announceDelegate.sends.length, 'dense ANNOUNCE fans out to every link');
  for (let i: number = 0; i < announceDelegate.sends.length; i++) {
    t.isTrue(announceDelegate.sends[i].endsWith('@5'), 'dense ANNOUNCE TTL clamped to 5');
  }

  const fragmentDelegate: RelayTestDelegate = new RelayTestDelegate();
  fragmentDelegate.linkIds = ['L1', 'L2', 'L3', 'L4', 'L5', 'L6', 'L7', 'L8'];
  const fragmentScheduler: VirtualScheduler = new VirtualScheduler();
  const fragmentRelay: PacketRelay = new PacketRelay(myPeerID, fragmentDelegate,
    (delayMs: number, task: () => void): number => fragmentScheduler.schedule(delayMs, task),
    (handle: number): void => fragmentScheduler.cancel(handle), halfRng);
  fragmentRelay.considerRelay(new RoutedPacket(
    makeRelayPacket(MessageType.FRAGMENT, specialRecipientBroadcast(), 7, 500),
    sender, null, 'L1'));
  fragmentScheduler.fire(1);
  t.equalNumber(7, fragmentDelegate.sends.length, 'dense FRAGMENT fans out to every link');
  for (let i: number = 0; i < fragmentDelegate.sends.length; i++) {
    t.isTrue(fragmentDelegate.sends[i].endsWith('@5'), 'dense FRAGMENT TTL clamped to 5');
  }

  // ------------------------------------------------------------------
  // Directed traffic: full fanout, no clamp, plain TTL-1 even when dense.
  // ------------------------------------------------------------------
  const directedDelegate: RelayTestDelegate = new RelayTestDelegate();
  directedDelegate.linkIds = ['L1', 'L2', 'L3', 'L4', 'L5', 'L6', 'L7', 'L8'];
  const directedScheduler: VirtualScheduler = new VirtualScheduler();
  const directedRelay: PacketRelay = new PacketRelay(myPeerID, directedDelegate,
    (delayMs: number, task: () => void): number => directedScheduler.schedule(delayMs, task),
    (handle: number): void => directedScheduler.cancel(handle), halfRng);
  directedRelay.considerRelay(new RoutedPacket(
    makeRelayPacket(MessageType.NOISE_ENCRYPTED, ByteUtils.hexToBytes('fffffffffffffffe'), 7, 600),
    sender, null, 'L1'));
  directedScheduler.fire(1);
  t.equalNumber(7, directedDelegate.sends.length, 'directed traffic fans out to every link');
  for (let i: number = 0; i < directedDelegate.sends.length; i++) {
    t.isTrue(directedDelegate.sends[i].endsWith('@6'), 'directed traffic relays at TTL-1, no clamp');
  }

  // ------------------------------------------------------------------
  // Never relayed: REQUEST_SYNC, expired TTL, addressed-to-me, own packets.
  // ------------------------------------------------------------------
  const skipDelegate: RelayTestDelegate = new RelayTestDelegate();
  skipDelegate.linkIds = ['L1', 'L2', 'L3'];
  const skipScheduler: VirtualScheduler = new VirtualScheduler();
  const skipRelay: PacketRelay = new PacketRelay(myPeerID, skipDelegate,
    (delayMs: number, task: () => void): number => skipScheduler.schedule(delayMs, task),
    (handle: number): void => skipScheduler.cancel(handle), halfRng);
  skipRelay.considerRelay(new RoutedPacket(
    makeRelayPacket(MessageType.REQUEST_SYNC, null, 0, 700), sender, null, 'L1'));
  skipRelay.considerRelay(new RoutedPacket(
    makeRelayPacket(MessageType.MESSAGE, specialRecipientBroadcast(), 0, 701), sender, null, 'L1'));
  skipRelay.considerRelay(new RoutedPacket(
    makeRelayPacket(MessageType.MESSAGE, ByteUtils.hexToBytes(myPeerID), 7, 702), sender, null, 'L1'));
  skipRelay.considerRelay(new RoutedPacket(
    makeRelayPacket(MessageType.MESSAGE, specialRecipientBroadcast(), 7, 703), myPeerID, null, 'L1'));
  t.equalNumber(0, skipScheduler.tasks.length, 'excluded packets never schedule a relay');
  t.equalNumber(0, skipRelay.getPendingRelayCount(), 'no pending relays for excluded packets');
  t.equalNumber(0, skipDelegate.sends.length, 'excluded packets send nothing');

  // A packet without link provenance relays on every link (no split horizon).
  skipRelay.considerRelay(new RoutedPacket(
    makeRelayPacket(MessageType.MESSAGE, specialRecipientBroadcast(), 7, 704), sender, null, null));
  t.equalNumber(1, skipScheduler.tasks.length, 'null-ingress packet still relays');
  skipScheduler.fire(1);
  t.equalString('L1@6,L2@6,L3@6', skipDelegate.sends.sort().join(','),
    'null-ingress relay has no split-horizon exclusion');

  // ------------------------------------------------------------------
  // Duplicate arrival cancels the pending relay (first-arrival wins, no
  // re-schedule).
  // ------------------------------------------------------------------
  const dupScheduler: VirtualScheduler = new VirtualScheduler();
  const dupDelegate: RelayTestDelegate = new RelayTestDelegate();
  dupDelegate.linkIds = ['L1', 'L2'];
  const dupRelay: PacketRelay = new PacketRelay(myPeerID, dupDelegate,
    (delayMs: number, task: () => void): number => dupScheduler.schedule(delayMs, task),
    (handle: number): void => dupScheduler.cancel(handle), halfRng);
  const dupPacket: BitchatPacket =
    makeRelayPacket(MessageType.MESSAGE, specialRecipientBroadcast(), 7, 800);
  dupRelay.considerRelay(new RoutedPacket(dupPacket, sender, null, 'L1'));
  t.equalNumber(1, dupRelay.getPendingRelayCount(), 'first arrival schedules the relay');
  dupRelay.considerRelay(new RoutedPacket(dupPacket, sender, null, 'L1'));
  t.equalNumber(0, dupRelay.getPendingRelayCount(), 'duplicate cancels the pending relay');
  t.equalNumber(1, dupRelay.getCancelledRelayCount(), 'duplicate counted as cancelled');
  t.equalNumber(0, dupScheduler.activeCount(), 'no active task remains after cancellation');
  dupScheduler.fire(1);
  t.equalNumber(0, dupDelegate.sends.length, 'cancelled relay never sends');

  // ------------------------------------------------------------------
  // Relay toggle and shutdown cancel pending relays.
  // ------------------------------------------------------------------
  const offScheduler: VirtualScheduler = new VirtualScheduler();
  const offDelegate: RelayTestDelegate = new RelayTestDelegate();
  offDelegate.linkIds = ['L1', 'L2'];
  const offRelay: PacketRelay = new PacketRelay(myPeerID, offDelegate,
    (delayMs: number, task: () => void): number => offScheduler.schedule(delayMs, task),
    (handle: number): void => offScheduler.cancel(handle), halfRng);
  offRelay.setRelayEnabled(false);
  offRelay.considerRelay(new RoutedPacket(
    makeRelayPacket(MessageType.MESSAGE, specialRecipientBroadcast(), 7, 900),
    sender, null, 'L1'));
  t.equalNumber(0, offScheduler.tasks.length, 'relay toggle off schedules nothing');

  const shutdownScheduler: VirtualScheduler = new VirtualScheduler();
  const shutdownDelegate: RelayTestDelegate = new RelayTestDelegate();
  shutdownDelegate.linkIds = ['L1', 'L2'];
  const shutdownRelay: PacketRelay = new PacketRelay(myPeerID, shutdownDelegate,
    (delayMs: number, task: () => void): number => shutdownScheduler.schedule(delayMs, task),
    (handle: number): void => shutdownScheduler.cancel(handle), halfRng);
  shutdownRelay.considerRelay(new RoutedPacket(
    makeRelayPacket(MessageType.MESSAGE, specialRecipientBroadcast(), 7, 901),
    sender, null, 'L1'));
  t.equalNumber(1, shutdownRelay.getPendingRelayCount(), 'relay pending before shutdown');
  shutdownRelay.shutdown();
  t.equalNumber(0, shutdownRelay.getPendingRelayCount(), 'shutdown clears pending relays');
  t.equalNumber(0, shutdownScheduler.activeCount(), 'shutdown cancels the scheduled task');
  shutdownScheduler.fire(1);
  t.equalNumber(0, shutdownDelegate.sends.length, 'shutdown relay never sends');
}
