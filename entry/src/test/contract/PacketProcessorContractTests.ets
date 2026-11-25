/**
 * Contract tests for the T026 ingress processor (FR-015):
 * - per-peer serialized ordering via hash-routed slots (Java String.hashCode
 *   golden values for the slot mapping)
 * - bounded admission: per-slot capacity drops the newest packet, global
 *   payload budget, drop counting, byte release after processing
 * - dispatch pipeline order per type, validity gating of liveness/relay,
 *   fragment reassembly recursion, transit semantics for packets not
 *   addressed to us, bad-packet isolation
 * All schedulers are injected so no timers run on the host.
 */
import { ContractAssert } from './ContractAssert';
import { PacketProcessor, RoutedPacket } from '../../main/ets/service/mesh/PacketProcessor';
import { PacketProcessorDelegate } from '../../main/ets/service/mesh/PacketProcessor';
import { BitchatPacket, MessageType } from '../../main/ets/model/BitchatPacket';
import { ProcessorConstants } from '../../main/ets/common/ProtocolConstants';
import { PacketPayloadLimits } from '../../main/ets/service/protocol/PacketPayloadLimits';

function makePacket(type: number, payloadFirstByte: number): BitchatPacket {
  const payload: Uint8Array = new Uint8Array([payloadFirstByte, 0x00]);
  return new BitchatPacket(1, type, new Uint8Array(8), null, 1000, payload, null, 7, null);
}

function makePacketWithPayload(type: number, payloadLength: number): BitchatPacket {
  return new BitchatPacket(1, type, new Uint8Array(8), null, 1000,
    new Uint8Array(payloadLength), null, 7, null);
}

export function runPacketProcessorContractTests(t: ContractAssert): void {
  // ------------------------------------------------------------------
  // Slot mapping golden values (Java String.hashCode semantics).
  // ------------------------------------------------------------------
  t.equalNumber(0, PacketProcessor.slotIndexForPeer(''), 'empty string hashes to slot 0');
  t.equalNumber(1, PacketProcessor.slotIndexForPeer('a'), "'a' (97) hashes to slot 1");
  const slotA: number = PacketProcessor.slotIndexForPeer('0011223344556677');
  t.isTrue(slotA >= 0 && slotA < ProcessorConstants.WORKER_COUNT, 'slot index in range');
  t.equalNumber(slotA, PacketProcessor.slotIndexForPeer('0011223344556677'),
    'same peer always maps to the same slot');

  // ------------------------------------------------------------------
  // Recording delegate.
  // ------------------------------------------------------------------
  class RecordingDelegate implements PacketProcessorDelegate {
    log: string[] = [];
    failValidation: boolean = false;
    announceValid: boolean = true;
    voiceValid: boolean = true;
    addressedToMe: boolean = false;
    reassembled: BitchatPacket | null = null;
    throwOnPayload: number = -1;

    validatePacketSecurity(packet: BitchatPacket, peerID: string): boolean {
      return !this.failValidation;
    }

    isPacketAddressedToMe(packet: BitchatPacket): boolean {
      return this.addressedToMe;
    }

    handleAnnounce(routed: RoutedPacket): boolean {
      this.log.push('announce');
      return this.announceValid;
    }

    handleMessage(routed: RoutedPacket): void {
      this.log.push('m' + routed.packet.payload[0]);
      if (routed.packet.payload[0] === this.throwOnPayload) {
        throw new Error('boom');
      }
    }

    handleVoiceFrame(routed: RoutedPacket): boolean {
      this.log.push('voice');
      return this.voiceValid;
    }

    handleLeave(routed: RoutedPacket): void {
      this.log.push('leave');
    }

    handleFragment(packet: BitchatPacket): BitchatPacket | null {
      this.log.push('fragment');
      return this.reassembled;
    }

    handleNoiseHandshake(routed: RoutedPacket): boolean {
      this.log.push('noise-hs');
      return true;
    }

    handleNoiseEncrypted(routed: RoutedPacket): boolean {
      this.log.push('noise-enc');
      return true;
    }

    handleRequestSync(routed: RoutedPacket): void {
      this.log.push('request-sync');
    }

    updatePeerLastSeen(peerID: string): void {
      this.log.push('s');
    }

    relayPacket(routed: RoutedPacket): void {
      this.log.push('r');
    }
  }

  const immediate: (task: () => void) => void = (task: () => void): void => {
    task();
  };
  const peerId: string = '0011223344556677';

  // ------------------------------------------------------------------
  // Dispatch pipeline per type, with liveness + relay hooks.
  // ------------------------------------------------------------------
  const delegate: RecordingDelegate = new RecordingDelegate();
  const processor: PacketProcessor = new PacketProcessor(delegate, immediate);

  // MESSAGE: handler, liveness, relay.
  processor.processPacket(new RoutedPacket(makePacket(MessageType.MESSAGE, 1), peerId, null, null));
  t.equalString('m1,s,r', delegate.log.join(','), 'MESSAGE dispatch order');

  // FILE_TRANSFER rides the same message routing path.
  delegate.log = [];
  processor.processPacket(new RoutedPacket(makePacket(MessageType.FILE_TRANSFER, 2), peerId, null, null));
  t.equalString('m2,s,r', delegate.log.join(','), 'FILE_TRANSFER routes to message handler');

  // ANNOUNCE valid -> liveness + relay; invalid -> neither.
  delegate.log = [];
  processor.processPacket(new RoutedPacket(makePacket(MessageType.ANNOUNCE, 3), peerId, null, null));
  t.equalString('announce,s,r', delegate.log.join(','), 'valid ANNOUNCE dispatch order');
  delegate.log = [];
  delegate.announceValid = false;
  processor.processPacket(new RoutedPacket(makePacket(MessageType.ANNOUNCE, 3), peerId, null, null));
  t.equalString('announce', delegate.log.join(','), 'invalid ANNOUNCE proves no liveness');

  // VOICE_FRAME validity gates liveness/relay.
  delegate.log = [];
  delegate.announceValid = true;
  delegate.voiceValid = false;
  processor.processPacket(new RoutedPacket(makePacket(MessageType.VOICE_FRAME, 4), peerId, null, null));
  t.equalString('voice', delegate.log.join(','), 'invalid VOICE_FRAME proves no liveness');
  delegate.log = [];
  delegate.voiceValid = true;
  processor.processPacket(new RoutedPacket(makePacket(MessageType.VOICE_FRAME, 4), peerId, null, null));
  t.equalString('voice,s,r', delegate.log.join(','), 'valid VOICE_FRAME dispatch order');

  // LEAVE and REQUEST_SYNC apply and stay relayable.
  delegate.log = [];
  processor.processPacket(new RoutedPacket(makePacket(MessageType.LEAVE, 5), peerId, null, null));
  t.equalString('leave,s,r', delegate.log.join(','), 'LEAVE dispatch order');
  delegate.log = [];
  processor.processPacket(new RoutedPacket(makePacket(MessageType.REQUEST_SYNC, 6), peerId, null, null));
  t.equalString('request-sync,s,r', delegate.log.join(','), 'REQUEST_SYNC dispatch order');

  // Security validation failure stops all dispatch.
  delegate.log = [];
  delegate.failValidation = true;
  processor.processPacket(new RoutedPacket(makePacket(MessageType.MESSAGE, 7), peerId, null, null));
  t.equalNumber(0, delegate.log.length, 'failed validation dispatches nothing');
  delegate.failValidation = false;

  // ------------------------------------------------------------------
  // Fragment reassembly recursion.
  // ------------------------------------------------------------------
  delegate.log = [];
  delegate.reassembled = makePacket(MessageType.MESSAGE, 8);
  processor.processPacket(new RoutedPacket(makePacket(MessageType.FRAGMENT, 9), peerId, null, null));
  t.equalString('fragment,m8,s,r,s,r', delegate.log.join(','),
    'FRAGMENT reassembles then re-enters the pipeline');
  delegate.reassembled = null;

  // ------------------------------------------------------------------
  // Private types: address check gates handlers, transit still relays.
  // ------------------------------------------------------------------
  delegate.log = [];
  delegate.addressedToMe = true;
  processor.processPacket(new RoutedPacket(makePacket(MessageType.NOISE_ENCRYPTED, 10), peerId, null, null));
  t.equalString('noise-enc,s,r', delegate.log.join(','), 'addressed NOISE_ENCRYPTED handled');

  delegate.log = [];
  delegate.addressedToMe = false;
  processor.processPacket(new RoutedPacket(makePacket(MessageType.NOISE_ENCRYPTED, 10), peerId, null, null));
  t.equalString('s,r', delegate.log.join(','),
    'unaddressed NOISE_ENCRYPTED transits without a handler');

  // Unknown type addressed to us is rejected; unknown transit stays relayable.
  delegate.log = [];
  delegate.addressedToMe = true;
  processor.processPacket(new RoutedPacket(makePacket(0x7F, 11), peerId, null, null));
  t.equalNumber(0, delegate.log.length, 'unknown addressed type rejected');

  delegate.log = [];
  delegate.addressedToMe = false;
  processor.processPacket(new RoutedPacket(makePacket(0x7F, 11), peerId, null, null));
  t.equalString('s,r', delegate.log.join(','), 'unknown type transits with liveness + relay');

  // ------------------------------------------------------------------
  // Same-peer FIFO ordering and payload-byte release.
  // ------------------------------------------------------------------
  delegate.log = [];
  for (let i: number = 1; i <= 3; i++) {
    processor.processPacket(new RoutedPacket(makePacket(MessageType.MESSAGE, i), peerId, null, null));
  }
  t.equalString('m1,m2,m3', delegate.log.filter((entry: string): boolean => entry.startsWith('m'))
    .join(','), 'same-peer packets processed in FIFO order');
  t.equalNumber(0, processor.getPendingPayloadBytes(), 'payload bytes released after processing');
  t.equalNumber(0, processor.getPendingPacketCount(), 'queue empty after processing');
  t.equalNumber(0, processor.getDroppedPacketCount(), 'no drops under normal load');

  // ------------------------------------------------------------------
  // Bad packet cannot kill the serialization chain.
  // ------------------------------------------------------------------
  delegate.log = [];
  delegate.throwOnPayload = 21;
  processor.processPacket(new RoutedPacket(makePacket(MessageType.MESSAGE, 21), peerId, null, null));
  processor.processPacket(new RoutedPacket(makePacket(MessageType.MESSAGE, 22), peerId, null, null));
  t.equalString('m21,m22,s,r', delegate.log.join(','),
    'a throwing handler does not block later packets');
  t.equalNumber(0, processor.getPendingPayloadBytes(), 'bytes released for bad packet too');

  // ------------------------------------------------------------------
  // Bounded admission (collected defer: nothing drains until we run it).
  // ------------------------------------------------------------------
  const deferredTasks: (() => void)[] = [];
  const collect: (task: () => void) => void = (task: () => void): void => {
    deferredTasks.push(task);
  };

  const admissionDelegate: RecordingDelegate = new RecordingDelegate();
  const admissionProcessor: PacketProcessor = new PacketProcessor(admissionDelegate, collect);

  // Per-slot capacity: the 65th same-peer packet is dropped (newest dropped).
  for (let i: number = 1; i <= 65; i++) {
    admissionProcessor.processPacket(
      new RoutedPacket(makePacket(MessageType.MESSAGE, i), peerId, null, null));
  }
  t.equalNumber(1, admissionProcessor.getDroppedPacketCount(), 'queue-full drops the newest packet');
  t.equalNumber(ProcessorConstants.QUEUE_CAPACITY, admissionProcessor.getPendingPacketCount(),
    'queue holds exactly QUEUE_CAPACITY packets');
  t.equalNumber(1, deferredTasks.length, 'one drain scheduled per slot cycle');
  deferredTasks[0]();
  const processedMarkers: string[] = admissionDelegate.log
    .filter((entry: string): boolean => entry.startsWith('m'));
  t.equalNumber(64, processedMarkers.length, 'oldest 64 packets processed');
  t.equalString('m1', processedMarkers[0], 'oldest packet kept (first)');
  t.equalString('m64', processedMarkers[63], 'newest admitted packet kept (last)');
  t.equalNumber(0, admissionProcessor.getPendingPayloadBytes(), 'queue drained to zero bytes');

  // Global payload budget: exactly MAX admitted, one more byte dropped.
  // FILE_TRANSFER carries the highest per-type ceiling (MAX_PAYLOAD_LENGTH),
  // so at this size the global budget is what binds, not the type cap.
  const budgetPayload: Uint8Array =
    new Uint8Array(ProcessorConstants.MAX_PENDING_PAYLOAD_BYTES);
  const budgetPacket: BitchatPacket =
    new BitchatPacket(1, MessageType.FILE_TRANSFER, new Uint8Array(8), null, 1000, budgetPayload,
      null, 7, null);
  admissionProcessor.processPacket(new RoutedPacket(budgetPacket, 'ffffffffffffffff', null, null));
  t.equalNumber(ProcessorConstants.MAX_PENDING_PAYLOAD_BYTES,
    admissionProcessor.getPendingPayloadBytes(), 'exact budget admitted');
  admissionProcessor.processPacket(
    new RoutedPacket(makePacket(MessageType.MESSAGE, 1), 'ffffffffffffffff', null, null));
  t.equalNumber(2, admissionProcessor.getDroppedPacketCount(),
    'payload over budget drops the newest packet');

  // ------------------------------------------------------------------
  // T038: per-type receive ceilings gate ingress admission.
  // ------------------------------------------------------------------
  const capDelegate: RecordingDelegate = new RecordingDelegate();
  const capProcessor: PacketProcessor = new PacketProcessor(capDelegate, immediate);
  const messageCap: number = PacketPayloadLimits.maxPayloadBytes(MessageType.MESSAGE);
  const controlCap: number = PacketPayloadLimits.maxPayloadBytes(MessageType.ANNOUNCE);
  const fragmentCap: number = PacketPayloadLimits.maxPayloadBytes(MessageType.FRAGMENT);
  t.isTrue(messageCap > controlCap && controlCap > fragmentCap,
    'per-type ceilings are distinct (message > control > fragment)');

  capProcessor.processPacket(new RoutedPacket(
    makePacketWithPayload(MessageType.MESSAGE, messageCap + 1), peerId, null, null));
  t.equalNumber(1, capProcessor.getDroppedPacketCount(), 'oversize MESSAGE dropped at ingress');
  t.equalNumber(0, capProcessor.getPendingPayloadBytes(), 'oversize MESSAGE occupies no budget');
  t.equalNumber(0, capDelegate.log.length, 'oversize MESSAGE reaches no handler');

  capDelegate.log = [];
  capProcessor.processPacket(new RoutedPacket(
    makePacketWithPayload(MessageType.MESSAGE, messageCap), peerId, null, null));
  t.equalString('m0,s,r', capDelegate.log.join(','), 'MESSAGE at the exact cap dispatches');
  t.equalNumber(1, capProcessor.getDroppedPacketCount(), 'boundary MESSAGE is not dropped');

  capDelegate.log = [];
  capProcessor.processPacket(new RoutedPacket(
    makePacketWithPayload(MessageType.ANNOUNCE, controlCap + 1), peerId, null, null));
  t.equalNumber(2, capProcessor.getDroppedPacketCount(), 'oversize ANNOUNCE dropped at ingress');
  t.equalNumber(0, capDelegate.log.length, 'oversize ANNOUNCE reaches no handler');

  capDelegate.log = [];
  capProcessor.processPacket(new RoutedPacket(
    makePacketWithPayload(MessageType.FRAGMENT, fragmentCap + 1), peerId, null, null));
  t.equalNumber(3, capProcessor.getDroppedPacketCount(), 'oversize FRAGMENT dropped at ingress');
  t.equalNumber(0, capDelegate.log.length, 'oversize FRAGMENT reaches no reassembly');
  t.equalNumber(0, capProcessor.getPendingPayloadBytes(), 'oversize packets released no budget');

  // Cross-slot independence: a full slot for one peer does not block another.
  let otherPeer: string = '';
  for (let i: number = 0; i < 100; i++) {
    const candidate: string = 'bbbb' + i.toString();
    if (PacketProcessor.slotIndexForPeer(candidate) !== PacketProcessor.slotIndexForPeer(peerId)) {
      otherPeer = candidate;
      break;
    }
  }
  t.isTrue(otherPeer !== '', 'found a peer mapping to another slot');
  const fillDelegate: RecordingDelegate = new RecordingDelegate();
  const fillProcessor: PacketProcessor = new PacketProcessor(fillDelegate, collect);
  for (let i: number = 0; i < ProcessorConstants.QUEUE_CAPACITY; i++) {
    fillProcessor.processPacket(
      new RoutedPacket(makePacket(MessageType.MESSAGE, i + 1), peerId, null, null));
  }
  fillProcessor.processPacket(new RoutedPacket(makePacket(MessageType.MESSAGE, 1), otherPeer, null, null));
  t.equalNumber(0, fillProcessor.getDroppedPacketCount(),
    'other-peer packet admitted while one slot is full');
  t.equalNumber(ProcessorConstants.QUEUE_CAPACITY + 1, fillProcessor.getPendingPacketCount(),
    'both slots hold their packets');

  // Shutdown discards queued packets and stops intake.
  fillProcessor.shutdown();
  t.equalNumber(0, fillProcessor.getPendingPacketCount(), 'shutdown empties the queues');
  t.equalNumber(0, fillProcessor.getPendingPayloadBytes(), 'shutdown releases payload bytes');
  const before: number = fillDelegate.log.length;
  const beforeDrops: number = fillProcessor.getDroppedPacketCount();
  fillProcessor.processPacket(new RoutedPacket(makePacket(MessageType.MESSAGE, 1), peerId, null, null));
  t.equalNumber(before, fillDelegate.log.length, 'no processing after shutdown');
  t.equalNumber(beforeDrops, fillProcessor.getDroppedPacketCount(), 'no drop counting after shutdown');

  // ------------------------------------------------------------------
  // T079 (SC-006): accepted/drop-rate admission accounting (<1% budget).
  // ------------------------------------------------------------------
  const rateDelegate: RecordingDelegate = new RecordingDelegate();
  const rateProcessor: PacketProcessor = new PacketProcessor(rateDelegate, immediate);
  t.equalNumber(0, rateProcessor.getAcceptedPacketCount(), 'no accepted packets before traffic');
  t.equalNumber(0, rateProcessor.getDroppedPacketCount(), 'no dropped packets before traffic');
  t.equalNumber(0, rateProcessor.getDropRate(), 'drop rate is 0 with no traffic');

  for (let i: number = 1; i <= 10; i++) {
    rateProcessor.processPacket(new RoutedPacket(makePacket(MessageType.MESSAGE, i), peerId, null, null));
  }
  t.equalNumber(10, rateProcessor.getAcceptedPacketCount(), 'admitted packets are counted');
  t.equalNumber(0, rateProcessor.getDroppedPacketCount(), 'normal load drops nothing');
  t.equalNumber(0, rateProcessor.getDropRate(), 'drop rate stays 0 without drops');

  // One oversize packet: dropped at ingress, never accepted, rate = 1/11.
  rateProcessor.processPacket(new RoutedPacket(
    makePacketWithPayload(MessageType.MESSAGE, PacketPayloadLimits.maxPayloadBytes(MessageType.MESSAGE) + 1),
    peerId, null, null));
  t.equalNumber(10, rateProcessor.getAcceptedPacketCount(), 'oversize packet is not accepted');
  t.equalNumber(1, rateProcessor.getDroppedPacketCount(), 'oversize packet is dropped');
  t.isTrue(Math.abs(rateProcessor.getDropRate() - 1 / 11) < 1e-9,
    'drop rate counts dropped over total');

  // Mixed load: 90 more admitted (100 total) keeps the rate under the 1% budget.
  for (let i: number = 11; i <= 100; i++) {
    rateProcessor.processPacket(new RoutedPacket(makePacket(MessageType.MESSAGE, i % 256), peerId, null, null));
  }
  t.equalNumber(100, rateProcessor.getAcceptedPacketCount(), '100 packets admitted in total');
  t.isTrue(rateProcessor.getDropRate() < 0.01, '100-in/1-out load stays under the 1% drop budget');

  // Diagnostics expose the counters for on-device SC-006 acceptance.
  const debugInfo: string = rateProcessor.getDebugInfo();
  t.isTrue(debugInfo.indexOf('Accepted Packets: 100') >= 0, 'debug info reports accepted packets');
  t.isTrue(debugInfo.indexOf('Drop Rate: 0.0099') >= 0, 'debug info reports the drop rate');
}
