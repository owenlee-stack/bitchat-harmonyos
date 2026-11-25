/**
 * Contract tests for US14 live push-to-talk (T069, FR-028):
 * - VoiceBurstPacket wire format: the iOS golden vectors from the Android
 *   VoiceBurstPacketTest (exact encode layouts for START/END, four-kind
 *   round trip, malformed-packet and construction rejection)
 * - VoiceBurstPacketizer: greedy budget batching, sequence reservation
 *   (0 = START), data-packet/dropped-frame counters, the 8-frames-per-
 *   packet cap and the 7-byte ADTS header
 * - LiveVoiceAssembler: in-order delivery, reorder buffering, gap-skip and
 *   idle timers, END early finalize, CANCELED teardown, duplicate frames,
 *   the receive quotas (concurrency, bytes-per-second rate, buffered
 *   packets) and reset
 * Clock and scheduler are injected so no real timers run on the host.
 */
import { ContractAssert } from './ContractAssert';
import { AdtsFramer, VoiceBurstCanceled, VoiceBurstCodec, VoiceBurstEnd,
  VoiceBurstFrames, VoiceBurstKind, VoiceBurstPacket, VoiceBurstPacketizer,
  VoiceBurstStart } from '../../main/ets/service/livevoice/VoiceBurstPacket';
import { LiveVoiceAssembler, LiveVoiceBurstStats, LiveVoiceConstants,
  LiveVoiceScope } from '../../main/ets/service/livevoice/LiveVoiceAssembler';
import { LiveVoiceAssemblerDelegate } from '../../main/ets/service/livevoice/LiveVoiceAssembler';

const PEER_A: string = 'aabbccddeeff0011';
const PEER_B: string = '1122334455667788';

function goldenBurstID(): Uint8Array {
  return new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]);
}

function repeatBytes(value: number, count: number): Uint8Array {
  const out: Uint8Array = new Uint8Array(count);
  for (let i: number = 0; i < count; i++) {
    out[i] = value;
  }
  return out;
}

function encodeOrFail(t: ContractAssert, burstID: Uint8Array, sequence: number,
  kind: VoiceBurstKind): Uint8Array {
  const packet: VoiceBurstPacket | null = VoiceBurstPacket.create(burstID, sequence, kind);
  t.isNotNull(packet, 'burst packet construction must succeed');
  if (packet === null) {
    throw new Error('unreachable: construction already asserted non-null');
  }
  return packet.encode();
}

/** Deterministic clock + scheduler: fireNext runs the earliest live timer. */
class ScheduledEntry {
  readonly handle: number;
  readonly fireAtMs: number;
  readonly task: () => void;
  cancelled: boolean = false;

  constructor(handle: number, fireAtMs: number, task: () => void) {
    this.handle = handle;
    this.fireAtMs = fireAtMs;
    this.task = task;
  }
}

class FakeTimeline {
  nowMs: number = 10000;
  private readonly entries: ScheduledEntry[] = [];
  private nextHandle: number = 1;

  now(): number {
    return this.nowMs;
  }

  schedule(delayMs: number, task: () => void): number {
    const entry: ScheduledEntry = new ScheduledEntry(this.nextHandle,
      this.nowMs + delayMs, task);
    this.nextHandle += 1;
    this.entries.push(entry);
    return entry.handle;
  }

  cancel(handle: number): void {
    for (let i: number = 0; i < this.entries.length; i++) {
      if (this.entries[i].handle === handle) {
        this.entries[i].cancelled = true;
      }
    }
  }

  fireNext(): void {
    let best: ScheduledEntry | null = null;
    for (let i: number = 0; i < this.entries.length; i++) {
      const entry: ScheduledEntry = this.entries[i];
      if (!entry.cancelled && (best === null || entry.fireAtMs < best.fireAtMs)) {
        best = entry;
      }
    }
    if (best === null) {
      throw new Error('unreachable: fireNext called with no live timer');
    }
    best.cancelled = true;
    this.nowMs = best.fireAtMs;
    best.task();
  }

  /** Runs the earliest live timer when one exists; a no-op otherwise. */
  fireNextSafe(): void {
    let best: ScheduledEntry | null = null;
    for (let i: number = 0; i < this.entries.length; i++) {
      const entry: ScheduledEntry = this.entries[i];
      if (!entry.cancelled && (best === null || entry.fireAtMs < best.fireAtMs)) {
        best = entry;
      }
    }
    if (best === null) {
      return;
    }
    best.cancelled = true;
    this.nowMs = best.fireAtMs;
    best.task();
  }
}

/** Delegate recording every callback as a compact string log. */
class RecordingDelegate implements LiveVoiceAssemblerDelegate {
  log: string[] = [];
  private readonly finishedStats: LiveVoiceBurstStats[] = [];

  onBurstStarted(peerID: string, burstIDHex: string, scope: LiveVoiceScope,
    timestampMs: number): void {
    this.log.push('start:' + peerID + ':' + burstIDHex + ':' + scope + ':' + timestampMs);
  }

  onOrderedFrames(peerID: string, burstIDHex: string, scope: LiveVoiceScope,
    frames: Uint8Array[]): void {
    this.log.push('frames:' + peerID + ':' + burstIDHex + ':' + scope + ':' + frames.length +
      ':' + frames[0][0]);
  }

  onBurstFinished(peerID: string, burstIDHex: string, scope: LiveVoiceScope,
    stats: LiveVoiceBurstStats): void {
    this.finishedStats.push(stats);
    this.log.push('finished:' + peerID + ':' + burstIDHex + ':' + scope + ':' +
      stats.dataPackets + ':' + stats.frames + ':' + stats.expectedPackets + ':' +
      stats.missingPackets);
  }

  onBurstCanceled(peerID: string, burstIDHex: string, scope: LiveVoiceScope): void {
    this.log.push('canceled:' + peerID + ':' + burstIDHex + ':' + scope);
  }

  lastFinishedStats(): LiveVoiceBurstStats {
    if (this.finishedStats.length === 0) {
      throw new Error('unreachable: no finished stats recorded');
    }
    return this.finishedStats[this.finishedStats.length - 1];
  }

  finishedCount(): number {
    return this.finishedStats.length;
  }
}

export function runLiveVoiceContractTests(t: ContractAssert): void {
  const burstID: Uint8Array = goldenBurstID();

  // ------------------------------------------------------------------
  // Wire format: iOS golden encode vectors (Android VoiceBurstPacketTest).
  // ------------------------------------------------------------------
  const startWire: Uint8Array = encodeOrFail(t, burstID, 0,
    new VoiceBurstStart(VoiceBurstCodec.AAC_LC_16K_MONO));
  t.equalBytes(new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 1, 1]), startWire,
    'START golden wire layout');

  const endWire: Uint8Array = encodeOrFail(t, burstID, 42,
    new VoiceBurstEnd(41, 2688));
  t.equalBytes(new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 0, 42, 2, 0, 41, 0, 0, 10, 0x80]),
    endWire, 'END golden wire layout (total 41, duration 2688)');

  const canceledWire: Uint8Array = encodeOrFail(t, burstID, 3, new VoiceBurstCanceled());
  t.equalBytes(new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 0, 3, 4]), canceledWire,
    'CANCELED is the bare 11-byte header');

  // ------------------------------------------------------------------
  // Round trip of all four kinds.
  // ------------------------------------------------------------------
  const framesKind: VoiceBurstFrames = new VoiceBurstFrames([
    new Uint8Array([0xDE, 0xAD]), repeatBytes(0x42, 130)]);
  const roundTrips: Uint8Array[] = [
    startWire,
    encodeOrFail(t, burstID, 7, framesKind),
    endWire,
    canceledWire
  ];
  for (let i: number = 0; i < roundTrips.length; i++) {
    const decoded: VoiceBurstPacket | null = VoiceBurstPacket.decode(roundTrips[i]);
    t.isNotNull(decoded, 'round trip ' + i + ' decodes');
    if (decoded === null) {
      continue;
    }
    t.equalBytes(burstID, decoded.burstID, 'round trip ' + i + ' burst ID');
    if (i === 0) {
      t.isTrue(decoded.kind instanceof VoiceBurstStart, 'packet 0 is START');
      if (decoded.kind instanceof VoiceBurstStart) {
        t.equalNumber(VoiceBurstCodec.AAC_LC_16K_MONO, decoded.kind.codec,
          'START codec round trips');
      }
    } else if (i === 1) {
      t.equalNumber(7, decoded.sequence, 'FRAMES sequence round trips');
      if (decoded.kind instanceof VoiceBurstFrames) {
        t.equalNumber(2, decoded.kind.frames.length, 'FRAMES count round trips');
        t.equalBytes(new Uint8Array([0xDE, 0xAD]), decoded.kind.frames[0],
          'FRAMES first unit round trips');
        t.equalBytes(repeatBytes(0x42, 130), decoded.kind.frames[1],
          'FRAMES second unit round trips');
      }
    } else if (i === 2) {
      t.equalNumber(42, decoded.sequence, 'END sequence round trips');
      if (decoded.kind instanceof VoiceBurstEnd) {
        t.equalNumber(41, decoded.kind.totalDataPackets, 'END total round trips');
        t.equalNumber(2688, decoded.kind.durationMs, 'END duration round trips');
      }
    } else {
      t.isTrue(decoded.kind instanceof VoiceBurstCanceled, 'packet 3 is CANCELED');
    }
  }

  // ------------------------------------------------------------------
  // Malformed packets and construction rejection.
  // ------------------------------------------------------------------
  t.isNull(VoiceBurstPacket.decode(new Uint8Array(0)), 'empty payload rejected');
  t.isNull(VoiceBurstPacket.decode(new Uint8Array(10)), 'short header rejected');
  t.isNull(VoiceBurstPacket.decode(new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 0, 1, 0xFF])),
    'unknown flags rejected');
  t.isNull(VoiceBurstPacket.decode(new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 0, 1, 0])),
    'flag-0 packet without frames rejected');
  t.isNull(VoiceBurstPacket.decode(new Uint8Array(
    [1, 2, 3, 4, 5, 6, 7, 8, 0, 1, 0, 0, 16, 0xAB])),
    'declared frame length beyond actual bytes rejected');
  t.isNull(VoiceBurstPacket.decode(new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 1, 0x7F])),
    'START with unsupported codec rejected');
  t.isNull(VoiceBurstPacket.create(new Uint8Array([1, 2]), 0, new VoiceBurstCanceled()),
    'short burst ID rejected');
  t.isNull(VoiceBurstPacket.create(burstID, 1, new VoiceBurstFrames([])),
    'empty frame list rejected');
  t.isNull(VoiceBurstPacket.create(burstID, 1, new VoiceBurstFrames([new Uint8Array(0)])),
    'zero-length frame rejected');
  t.isNull(VoiceBurstPacket.create(burstID, -1, new VoiceBurstCanceled()),
    'negative sequence rejected');
  t.isNull(VoiceBurstPacket.create(burstID, 0x10000, new VoiceBurstCanceled()),
    'sequence above u16 rejected');
  t.isNull(VoiceBurstPacket.create(burstID, 1, new VoiceBurstEnd(0x10000, 0)),
    'END total above u16 rejected');

  // Burst ID minting + hex rendering.
  const minted: Uint8Array = VoiceBurstPacket.makeBurstID(
    (count: number): Uint8Array => {
      t.equalNumber(8, count, 'burst ID mint asks for exactly 8 bytes');
      return new Uint8Array([0, 1, 2, 3, 4, 5, 6, 7]);
    });
  t.equalBytes(new Uint8Array([0, 1, 2, 3, 4, 5, 6, 7]), minted,
    'makeBurstID returns the injected random bytes');
  t.equalString('0001020304050607', VoiceBurstPacket.burstIDHex(minted),
    'burst ID renders as lowercase hex');

  // ------------------------------------------------------------------
  // Packetizer: budget flow (Android packetizerRespectsBudgetAndCounters).
  // ------------------------------------------------------------------
  const budgetPacketizer: VoiceBurstPacketizer = new VoiceBurstPacketizer(burstID, 210);
  const wireFrame: Uint8Array = repeatBytes(0x55, 130);
  t.equalNumber(0, budgetPacketizer.add(wireFrame).length,
    'first 130B frame queues without emitting');
  const firstOut: Uint8Array[] = budgetPacketizer.add(wireFrame);
  t.equalNumber(1, firstOut.length, 'second 130B frame flushes the first packet');
  const firstDecoded: VoiceBurstPacket | null = VoiceBurstPacket.decode(firstOut[0]);
  t.isNotNull(firstDecoded, 'first packetizer packet decodes');
  if (firstDecoded !== null) {
    t.equalNumber(1, firstDecoded.sequence, 'first data packet carries sequence 1');
  }
  const finalOut: Uint8Array[] = budgetPacketizer.flush();
  t.equalNumber(1, finalOut.length, 'flush emits the pending packet');
  const finalDecoded: VoiceBurstPacket | null = VoiceBurstPacket.decode(finalOut[0]);
  t.isNotNull(finalDecoded, 'final packetizer packet decodes');
  if (finalDecoded !== null) {
    t.equalNumber(2, finalDecoded.sequence, 'second data packet carries sequence 2');
  }
  t.equalNumber(2, budgetPacketizer.getDataPacketCount(), 'two data packets counted');
  t.equalNumber(3, budgetPacketizer.getNextSequence(), 'sequence advanced to 3');
  t.equalNumber(0, budgetPacketizer.flush().length, 'flush on empty pending is empty');
  t.isTrue(firstOut[0].length + 1 + 16 <= 256,
    'Noise-wrapped data packet fits the 256-byte frame budget');

  // ------------------------------------------------------------------
  // Packetizer: batching by frame count and budget.
  // ------------------------------------------------------------------
  const batchPacketizer: VoiceBurstPacketizer = new VoiceBurstPacketizer(burstID, 210);
  for (let i: number = 0; i < 4; i++) {
    t.equalNumber(0, batchPacketizer.add(repeatBytes(0x11, 40)).length,
      '40B frame ' + i + ' queues without emitting');
  }
  const batchOut: Uint8Array[] = batchPacketizer.flush();
  t.equalNumber(1, batchOut.length, 'four 40B frames batch into one packet');
  const batchDecoded: VoiceBurstPacket | null = VoiceBurstPacket.decode(batchOut[0]);
  t.isNotNull(batchDecoded, 'batched packet decodes');
  if (batchDecoded !== null && batchDecoded.kind instanceof VoiceBurstFrames) {
    t.equalNumber(4, batchDecoded.kind.frames.length, 'batched packet carries 4 frames');
    t.equalBytes(repeatBytes(0x11, 40), batchDecoded.kind.frames[3],
      'batched frame content intact');
  }

  // Eight frames per packet cap: the 9th add forces the flush.
  const capPacketizer: VoiceBurstPacketizer = new VoiceBurstPacketizer(burstID, 1000);
  for (let i: number = 0; i < 8; i++) {
    t.equalNumber(0, capPacketizer.add(repeatBytes(0x22, 10)).length,
      'frame ' + i + ' stays queued under the 8-frame cap');
  }
  const capOut: Uint8Array[] = capPacketizer.add(repeatBytes(0x22, 10));
  t.equalNumber(1, capOut.length, 'ninth frame flushes the full 8-frame packet');
  const capDecoded: VoiceBurstPacket | null = VoiceBurstPacket.decode(capOut[0]);
  t.isNotNull(capDecoded, 'capped packet decodes');
  if (capDecoded !== null && capDecoded.kind instanceof VoiceBurstFrames) {
    t.equalNumber(8, capDecoded.kind.frames.length, 'capped packet carries exactly 8 frames');
  }
  t.equalNumber(1, capPacketizer.flush().length, 'the ninth frame flushes alone later');

  // ------------------------------------------------------------------
  // Packetizer: oversized-frame drop accounting.
  // ------------------------------------------------------------------
  const dropPacketizer: VoiceBurstPacketizer = new VoiceBurstPacketizer(burstID, 210);
  t.equalNumber(0, dropPacketizer.add(repeatBytes(0x33, 198)).length,
    'a 198B frame cannot fit the 210B wire budget');
  t.equalNumber(1, dropPacketizer.getDroppedFrameCount(), 'dropped frame counted');
  t.equalNumber(0, dropPacketizer.getDataPacketCount(), 'no data packet emitted');
  t.equalNumber(1, dropPacketizer.getNextSequence(), 'sequence untouched by drops');

  // ------------------------------------------------------------------
  // ADTS framer (golden header bytes).
  // ------------------------------------------------------------------
  const adts: Uint8Array | null = AdtsFramer.frame(new Uint8Array([1, 2, 3]));
  t.isNotNull(adts, 'ADTS frame builds');
  if (adts !== null) {
    t.equalNumber(10, adts.length, 'ADTS frame is payload + 7 header bytes');
    t.equalNumber(0xFF, adts[0], 'ADTS sync word high');
    t.equalNumber(0xF1, adts[1], 'ADTS sync word low / MPEG-4 / no CRC');
    t.equalBytes(new Uint8Array([1, 2, 3]), adts.slice(7), 'ADTS payload appended at 7');
  }
  t.isNull(AdtsFramer.frame(repeatBytes(0x44, 8192 - 7)),
    'a frame above the 0x1FFF ADTS length cap is refused');

  // ------------------------------------------------------------------
  // Assembler: happy path (START -> in-order FRAMES -> END).
  // ------------------------------------------------------------------
  const timeline: FakeTimeline = new FakeTimeline();
  const delegate: RecordingDelegate = new RecordingDelegate();
  const assembler: LiveVoiceAssembler = new LiveVoiceAssembler(delegate,
    (): number => {
      return timeline.now();
    },
    (delayMs: number, task: () => void): number => {
      return timeline.schedule(delayMs, task);
    },
    (handle: number): void => {
      timeline.cancel(handle);
    });

  t.isTrue(assembler.handleFrame(PEER_A, LiveVoiceScope.PUBLIC_MESH, startWire, 12345),
    'START accepted');
  t.equalNumber(1, assembler.getActiveBurstCount(), 'one active burst after START');
  const seq1Wire: Uint8Array = encodeOrFail(t, burstID, 1,
    new VoiceBurstFrames([new Uint8Array([0xAA])]));
  const seq2Wire: Uint8Array = encodeOrFail(t, burstID, 2,
    new VoiceBurstFrames([new Uint8Array([0xBB])]));
  t.isTrue(assembler.handleFrame(PEER_A, LiveVoiceScope.PUBLIC_MESH, seq1Wire, 12350),
    'in-order FRAMES seq 1 accepted');
  t.isTrue(assembler.handleFrame(PEER_A, LiveVoiceScope.PUBLIC_MESH, seq2Wire, 12360),
    'in-order FRAMES seq 2 accepted');
  t.equalNumber(0, delegate.finishedCount(), 'burst not finished before END');
  // END must announce the true data-packet total (2) for the immediate
  // finalize; the golden endWire (total 41) belongs to the wire-format tests.
  const happyEndWire: Uint8Array = encodeOrFail(t, burstID, 3,
    new VoiceBurstEnd(2, 2688));
  t.isTrue(assembler.handleFrame(PEER_A, LiveVoiceScope.PUBLIC_MESH, happyEndWire, 12370),
    'END accepted');
  t.equalNumber(0, assembler.getActiveBurstCount(), 'burst finalized after END');
  t.equalString('start:' + PEER_A + ':0102030405060708:1:12345', delegate.log[0],
    'onBurstStarted fires with peer, burst hex, scope, timestamp');
  t.equalString('frames:' + PEER_A + ':0102030405060708:1:1:170', delegate.log[1],
    'in-order frames deliver immediately');
  t.equalString('frames:' + PEER_A + ':0102030405060708:1:1:187', delegate.log[2],
    'second frame batch delivers');
  t.equalString('finished:' + PEER_A + ':0102030405060708:1:2:2:2:0', delegate.log[3],
    'onBurstFinished reports both packets, zero missing');
  const happyStats: LiveVoiceBurstStats = delegate.lastFinishedStats();
  t.equalNumber(happyStats.dataPackets, happyStats.expectedPackets,
    'delivered packets match the END total');
  t.equalNumber(0, happyStats.missingPackets, 'no missing packets on the happy path');

  // ------------------------------------------------------------------
  // Assembler: out-of-order buffering inside the reorder window.
  // ------------------------------------------------------------------
  const ooTimeline: FakeTimeline = new FakeTimeline();
  const ooDelegate: RecordingDelegate = new RecordingDelegate();
  const ooAssembler: LiveVoiceAssembler = new LiveVoiceAssembler(ooDelegate,
    (): number => {
      return ooTimeline.now();
    },
    (delayMs: number, task: () => void): number => {
      return ooTimeline.schedule(delayMs, task);
    },
    (handle: number): void => {
      ooTimeline.cancel(handle);
    });
  ooAssembler.handleFrame(PEER_B, LiveVoiceScope.DIRECT_MESSAGE, startWire, 20000);
  const ooSeq2: Uint8Array = encodeOrFail(t, burstID, 2,
    new VoiceBurstFrames([new Uint8Array([0xCC])]));
  const ooSeq1: Uint8Array = encodeOrFail(t, burstID, 1,
    new VoiceBurstFrames([new Uint8Array([0xDD])]));
  t.isTrue(ooAssembler.handleFrame(PEER_B, LiveVoiceScope.DIRECT_MESSAGE, ooSeq2, 20010),
    'future FRAMES seq 2 buffers without delivery');
  t.equalNumber(0, ooDelegate.log.filter((entry: string): boolean => {
    return entry.startsWith('frames:');
  }).length, 'no frame delivery while a gap is open');
  t.isTrue(ooAssembler.handleFrame(PEER_B, LiveVoiceScope.DIRECT_MESSAGE, ooSeq1, 20020),
    'missing FRAMES seq 1 arrives');
  const ooEnd: Uint8Array = encodeOrFail(t, burstID, 3, new VoiceBurstEnd(2, 500));
  t.isTrue(ooAssembler.handleFrame(PEER_B, LiveVoiceScope.DIRECT_MESSAGE, ooEnd, 20030),
    'END accepted after reorder');
  t.equalNumber(0, ooAssembler.getActiveBurstCount(),
    'END with every packet delivered finalizes immediately');
  const reorderedFrames: string[] = ooDelegate.log.filter((entry: string): boolean => {
    return entry.startsWith('frames:');
  });
  t.equalNumber(2, reorderedFrames.length, 'both frame batches delivered in order');
  t.isTrue(reorderedFrames[0].endsWith(':221'), 'seq 1 delivers before seq 2');
  t.isTrue(reorderedFrames[1].endsWith(':204'), 'seq 2 delivers after seq 1');
  const ooStats: LiveVoiceBurstStats = ooDelegate.lastFinishedStats();
  t.equalNumber(0, ooStats.missingPackets, 'reordered burst has no missing packets');

  // ------------------------------------------------------------------
  // Assembler: gap-skip timer counts the lost packet.
  // ------------------------------------------------------------------
  const gapTimeline: FakeTimeline = new FakeTimeline();
  const gapDelegate: RecordingDelegate = new RecordingDelegate();
  const gapAssembler: LiveVoiceAssembler = new LiveVoiceAssembler(gapDelegate,
    (): number => {
      return gapTimeline.now();
    },
    (delayMs: number, task: () => void): number => {
      return gapTimeline.schedule(delayMs, task);
    },
    (handle: number): void => {
      gapTimeline.cancel(handle);
    });
  gapAssembler.handleFrame(PEER_A, LiveVoiceScope.PUBLIC_MESH, startWire, 30000);
  const gapSeq2: Uint8Array = encodeOrFail(t, burstID, 2,
    new VoiceBurstFrames([new Uint8Array([0xEE])]));
  const gapEnd: Uint8Array = encodeOrFail(t, burstID, 3, new VoiceBurstEnd(2, 400));
  gapAssembler.handleFrame(PEER_A, LiveVoiceScope.PUBLIC_MESH, gapSeq2, 30010);
  gapAssembler.handleFrame(PEER_A, LiveVoiceScope.PUBLIC_MESH, gapEnd, 30020);
  t.equalNumber(0, gapDelegate.finishedCount(),
    'END alone does not finalize while a packet is missing');
  gapTimeline.fireNext();
  t.equalNumber(0, gapAssembler.getActiveBurstCount(),
    'gap timer skips the missing sequence and finalizes');
  const gapStats: LiveVoiceBurstStats = gapDelegate.lastFinishedStats();
  t.equalNumber(1, gapStats.dataPackets, 'only the arrived packet delivered');
  t.equalNumber(1, gapStats.missingPackets, 'the skipped sequence counts as missing');
  t.equalNumber(2, gapStats.expectedPackets, 'expected total comes from END');

  // ------------------------------------------------------------------
  // Assembler: idle timeout finalizes a stalled burst.
  // ------------------------------------------------------------------
  const idleTimeline: FakeTimeline = new FakeTimeline();
  const idleDelegate: RecordingDelegate = new RecordingDelegate();
  const idleAssembler: LiveVoiceAssembler = new LiveVoiceAssembler(idleDelegate,
    (): number => {
      return idleTimeline.now();
    },
    (delayMs: number, task: () => void): number => {
      return idleTimeline.schedule(delayMs, task);
    },
    (handle: number): void => {
      idleTimeline.cancel(handle);
    });
  idleAssembler.handleFrame(PEER_A, LiveVoiceScope.PUBLIC_MESH, startWire, 40000);
  t.equalNumber(0, idleDelegate.finishedCount(), 'stalled burst waits for the idle timer');
  idleTimeline.fireNext();
  t.equalNumber(0, idleAssembler.getActiveBurstCount(), 'idle timeout finalizes');
  const idleStats: LiveVoiceBurstStats = idleDelegate.lastFinishedStats();
  t.equalNumber(0, idleStats.dataPackets, 'no packets delivered on a START-only burst');
  t.equalNumber(-1, idleStats.expectedPackets, 'expected stays unknown without END');
  t.equalNumber(0, idleStats.missingPackets, 'nothing missing without END');

  // ------------------------------------------------------------------
  // Assembler: duplicates, CANCELED, orphan END/CANCELED.
  // ------------------------------------------------------------------
  const dupTimeline: FakeTimeline = new FakeTimeline();
  const dupDelegate: RecordingDelegate = new RecordingDelegate();
  const dupAssembler: LiveVoiceAssembler = new LiveVoiceAssembler(dupDelegate,
    (): number => {
      return dupTimeline.now();
    },
    (delayMs: number, task: () => void): number => {
      return dupTimeline.schedule(delayMs, task);
    },
    (handle: number): void => {
      dupTimeline.cancel(handle);
    });
  dupAssembler.handleFrame(PEER_A, LiveVoiceScope.PUBLIC_MESH, startWire, 50000);
  const dupSeq1: Uint8Array = encodeOrFail(t, burstID, 1,
    new VoiceBurstFrames([new Uint8Array([0x99])]));
  t.isTrue(dupAssembler.handleFrame(PEER_A, LiveVoiceScope.PUBLIC_MESH, dupSeq1, 50010),
    'frame accepted once');
  t.isTrue(dupAssembler.handleFrame(PEER_A, LiveVoiceScope.PUBLIC_MESH, dupSeq1, 50020),
    'duplicate frame stays valid');
  const dupDelivered: string[] = dupDelegate.log.filter((entry: string): boolean => {
    return entry.startsWith('frames:');
  });
  t.equalNumber(1, dupDelivered.length, 'duplicate frame delivers only once');
  const dupCancel: Uint8Array = encodeOrFail(t, burstID, 2, new VoiceBurstCanceled());
  t.isTrue(dupAssembler.handleFrame(PEER_A, LiveVoiceScope.PUBLIC_MESH, dupCancel, 50030),
    'CANCELED accepted');
  t.equalNumber(0, dupAssembler.getActiveBurstCount(), 'CANCELED tears the burst down');
  t.equalNumber(1, dupDelegate.log.filter((entry: string): boolean => {
    return entry.startsWith('canceled:');
  }).length, 'onBurstCanceled fires once');
  t.equalNumber(0, dupDelegate.finishedCount(), 'canceled burst never finishes');
  // Orphan END / CANCELED without an assembly stay valid (no-op).
  const orphanEnd: Uint8Array = encodeOrFail(t, new Uint8Array([9, 9, 9, 9, 9, 9, 9, 9]),
    1, new VoiceBurstEnd(1, 100));
  t.isTrue(dupAssembler.handleFrame(PEER_A, LiveVoiceScope.PUBLIC_MESH, orphanEnd, 50040),
    'orphan END is a valid no-op');
  t.isTrue(dupAssembler.handleFrame(PEER_A, LiveVoiceScope.PUBLIC_MESH,
    encodeOrFail(t, new Uint8Array([9, 9, 9, 9, 9, 9, 9, 9]), 1, new VoiceBurstCanceled()),
    50041), 'orphan CANCELED is a valid no-op');

  // ------------------------------------------------------------------
  // Assembler: quotas - concurrency, buffered packets, inbound rate.
  // ------------------------------------------------------------------
  t.equalNumber(8, LiveVoiceConstants.MAX_CONCURRENT_ASSEMBLIES, 'concurrency quota is 8');
  t.equalNumber(384 * 1024, LiveVoiceConstants.MAX_BURST_BYTES, 'per-burst byte quota');
  t.equalNumber(6000, LiveVoiceConstants.INBOUND_BYTES_PER_SECOND, 'rate ceiling');
  t.equalNumber(128, LiveVoiceConstants.MAX_BUFFERED_PACKETS, 'buffered packet cap');
  t.equalNumber(550, LiveVoiceConstants.GAP_SKIP_MS, 'gap skip window');
  t.equalNumber(3000, LiveVoiceConstants.IDLE_TIMEOUT_MS, 'idle timeout');

  const quotaTimeline: FakeTimeline = new FakeTimeline();
  const quotaDelegate: RecordingDelegate = new RecordingDelegate();
  const quotaAssembler: LiveVoiceAssembler = new LiveVoiceAssembler(quotaDelegate,
    (): number => {
      return quotaTimeline.now();
    },
    (delayMs: number, task: () => void): number => {
      return quotaTimeline.schedule(delayMs, task);
    },
    (handle: number): void => {
      quotaTimeline.cancel(handle);
    });
  for (let i: number = 0; i < 8; i++) {
    const id: Uint8Array = new Uint8Array([i, i, i, i, i, i, i, i]);
    t.isTrue(quotaAssembler.handleFrame(PEER_A, LiveVoiceScope.PUBLIC_MESH,
      encodeOrFail(t, id, 0, new VoiceBurstStart(VoiceBurstCodec.AAC_LC_16K_MONO)),
      60000 + i), 'concurrent burst ' + i + ' admitted');
  }
  t.equalNumber(8, quotaAssembler.getActiveBurstCount(), 'eight concurrent bursts');
  const ninthStart: Uint8Array = encodeOrFail(t, new Uint8Array([8, 8, 8, 8, 8, 8, 8, 8]),
    0, new VoiceBurstStart(VoiceBurstCodec.AAC_LC_16K_MONO));
  t.isFalse(quotaAssembler.handleFrame(PEER_A, LiveVoiceScope.PUBLIC_MESH, ninthStart, 60009),
    'the ninth concurrent burst is refused');

  // Buffer cap: 128 out-of-order packets buffer, the 129th is refused.
  const bufferTimeline: FakeTimeline = new FakeTimeline();
  const bufferDelegate: RecordingDelegate = new RecordingDelegate();
  const bufferAssembler: LiveVoiceAssembler = new LiveVoiceAssembler(bufferDelegate,
    (): number => {
      return bufferTimeline.now();
    },
    (delayMs: number, task: () => void): number => {
      return bufferTimeline.schedule(delayMs, task);
    },
    (handle: number): void => {
      bufferTimeline.cancel(handle);
    });
  bufferAssembler.handleFrame(PEER_A, LiveVoiceScope.PUBLIC_MESH, startWire, 70000);
  let allBuffered: boolean = true;
  for (let sequence: number = 2; sequence <= 129; sequence++) {
    const ok: boolean = bufferAssembler.handleFrame(PEER_A, LiveVoiceScope.PUBLIC_MESH,
      encodeOrFail(t, burstID, sequence,
        new VoiceBurstFrames([new Uint8Array([0x77])])), 70000 + sequence);
    if (!ok) {
      allBuffered = false;
      break;
    }
  }
  t.isTrue(allBuffered, '128 out-of-order packets stay within the buffer cap');
  const overflow: boolean = bufferAssembler.handleFrame(PEER_A, LiveVoiceScope.PUBLIC_MESH,
    encodeOrFail(t, burstID, 130, new VoiceBurstFrames([new Uint8Array([0x77])])),
    70131);
  t.isFalse(overflow, 'the 129th buffered packet is refused');

  // Rate ceiling: bytes beyond INBOUND_BYTES_PER_SECOND (2s grace) finalize
  // the burst and report the frame invalid.
  const rateTimeline: FakeTimeline = new FakeTimeline();
  const rateDelegate: RecordingDelegate = new RecordingDelegate();
  const rateAssembler: LiveVoiceAssembler = new LiveVoiceAssembler(rateDelegate,
    (): number => {
      return rateTimeline.now();
    },
    (delayMs: number, task: () => void): number => {
      return rateTimeline.schedule(delayMs, task);
    },
    (handle: number): void => {
      rateTimeline.cancel(handle);
    });
  rateAssembler.handleFrame(PEER_A, LiveVoiceScope.PUBLIC_MESH, startWire, 80000);
  // 8 frames x 1500B = 12016B payload + 27B framing > 6000 * 2 grace bytes.
  const hugeFrames: VoiceBurstFrames = new VoiceBurstFrames([
    repeatBytes(0x66, 1500), repeatBytes(0x66, 1500), repeatBytes(0x66, 1500),
    repeatBytes(0x66, 1500), repeatBytes(0x66, 1500), repeatBytes(0x66, 1500),
    repeatBytes(0x66, 1500), repeatBytes(0x66, 1500)]);
  t.isFalse(rateAssembler.handleFrame(PEER_A, LiveVoiceScope.PUBLIC_MESH,
    encodeOrFail(t, burstID, 1, hugeFrames), 80010),
    'over-rate frame finalizes the burst and reports invalid');
  t.equalNumber(0, rateAssembler.getActiveBurstCount(), 'over-rate burst finalized');
  t.equalNumber(1, rateDelegate.finishedCount(), 'over-rate burst emits Finished');

  // ------------------------------------------------------------------
  // Assembler: scope isolation and reset.
  // ------------------------------------------------------------------
  const resetTimeline: FakeTimeline = new FakeTimeline();
  const resetDelegate: RecordingDelegate = new RecordingDelegate();
  const resetAssembler: LiveVoiceAssembler = new LiveVoiceAssembler(resetDelegate,
    (): number => {
      return resetTimeline.now();
    },
    (delayMs: number, task: () => void): number => {
      return resetTimeline.schedule(delayMs, task);
    },
    (handle: number): void => {
      resetTimeline.cancel(handle);
    });
  resetAssembler.handleFrame(PEER_A, LiveVoiceScope.PUBLIC_MESH, startWire, 90000);
  resetAssembler.handleFrame(PEER_A, LiveVoiceScope.DIRECT_MESSAGE, startWire, 90001);
  t.equalNumber(2, resetAssembler.getActiveBurstCount(),
    'same burst ID in different scopes assembles separately');
  resetAssembler.reset();
  t.equalNumber(0, resetAssembler.getActiveBurstCount(), 'reset clears every assembly');
  const resetEvents: number = resetDelegate.log.length;
  resetTimeline.fireNextSafe();
  t.equalNumber(resetEvents, resetDelegate.log.length,
    'reset cancels timers so no further delegate events fire');

  // Malformed live-voice payload is refused without side effects.
  t.isFalse(resetAssembler.handleFrame(PEER_A, LiveVoiceScope.PUBLIC_MESH,
    new Uint8Array(4), 90010), 'truncated burst payload refused');
  t.isFalse(resetAssembler.handleFrame(PEER_A, LiveVoiceScope.PUBLIC_MESH,
    new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 1, 0x7F]), 90011),
    'START with unsupported codec refused as malformed');
}
