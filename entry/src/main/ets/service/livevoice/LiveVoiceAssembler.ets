/**
 * Live push-to-talk receive-side assembly (US14, T069) - the bounded half of
 * bitchat-android LiveVoiceManager.kt (FR-028), stripped of device concerns:
 * file writes, playback and timeline rows live in the device manager.
 *
 *  - Per-(peer, scope, burst) assembly with the receive quotas: at most
 *    MAX_CONCURRENT_ASSEMBLIES concurrent bursts, MAX_BURST_BYTES per burst
 *    plus an INBOUND_BYTES_PER_SECOND rate ceiling (2 s grace), and at most
 *    MAX_BUFFERED_PACKETS out-of-order packets per burst. A violating frame
 *    finalizes what arrived so far and reports invalid.
 *  - In-order delivery with a bounded reorder window: a GAP_SKIP_MS timer
 *    skips over a missing sequence once the next one is buffered; an
 *    IDLE_TIMEOUT_MS timer finalizes a stalled burst.
 *  - END (total data packets + duration) finalizes as soon as every packet
 *    through the total has been delivered; CANCELED tears the burst down.
 *  - START admits only the AAC-LC 16 kHz mono codec.
 *
 * The clock and scheduler are injectable so the reassembly semantics run
 * deterministically in the host contract harness (PacketRelay policy).
 * Free of device imports.
 */
import {
  VoiceBurstCodec,
  VoiceBurstEnd,
  VoiceBurstCanceled,
  VoiceBurstFrames,
  VoiceBurstPacket,
  VoiceBurstStart
} from './VoiceBurstPacket';

/** Where a live burst travels (Android LiveVoiceScope). */
export enum LiveVoiceScope {
  DIRECT_MESSAGE = 0,
  PUBLIC_MESH = 1
}

export class LiveVoiceConstants {
  static readonly MAX_CONCURRENT_ASSEMBLIES: number = 8;
  static readonly MAX_BURST_BYTES: number = 384 * 1024;
  static readonly INBOUND_BYTES_PER_SECOND: number = 6000;
  static readonly MAX_BUFFERED_PACKETS: number = 128;
  static readonly GAP_SKIP_MS: number = 550;
  static readonly IDLE_TIMEOUT_MS: number = 3000;
}

/** Delivery statistics of one finished burst (Android LiveVoiceEvent.Finished). */
export class LiveVoiceBurstStats {
  readonly dataPackets: number;
  readonly frames: number;
  readonly bytes: number;
  /** Total data packets announced by END; -1 when END never arrived. */
  readonly expectedPackets: number;
  readonly missingPackets: number;

  constructor(dataPackets: number, frames: number, bytes: number,
    expectedPackets: number, missingPackets: number) {
    this.dataPackets = dataPackets;
    this.frames = frames;
    this.bytes = bytes;
    this.expectedPackets = expectedPackets;
    this.missingPackets = missingPackets;
  }
}

export interface LiveVoiceAssemblerDelegate {
  onBurstStarted(peerID: string, burstIDHex: string, scope: LiveVoiceScope,
    timestampMs: number): void;

  /** Ordered AAC access units (ADTS-less) ready for persistence/playback. */
  onOrderedFrames(peerID: string, burstIDHex: string, scope: LiveVoiceScope,
    frames: Uint8Array[]): void;

  onBurstFinished(peerID: string, burstIDHex: string, scope: LiveVoiceScope,
    stats: LiveVoiceBurstStats): void;

  onBurstCanceled(peerID: string, burstIDHex: string, scope: LiveVoiceScope): void;
}

class BurstAssembly {
  readonly key: string;
  readonly peerID: string;
  readonly burstIDHex: string;
  readonly scope: LiveVoiceScope;
  readonly startedAtMs: number;
  buffered: Map<number, Uint8Array[]> = new Map<number, Uint8Array[]>();
  nextSequence: number = 1;
  deliveredFrames: number = 0;
  deliveredPackets: number = 0;
  missingPackets: number = 0;
  receivedBytes: number = 0;
  endTotalPackets: number = -1;
  idleHandle: number = -1;
  gapHandle: number = -1;

  constructor(key: string, peerID: string, burstIDHex: string, scope: LiveVoiceScope,
    startedAtMs: number) {
    this.key = key;
    this.peerID = peerID;
    this.burstIDHex = burstIDHex;
    this.scope = scope;
    this.startedAtMs = startedAtMs;
  }
}

export class LiveVoiceAssembler {
  private readonly delegate: LiveVoiceAssemblerDelegate;
  private readonly nowMs: () => number;
  private readonly schedule: (delayMs: number, task: () => void) => number;
  private readonly cancel: (handle: number) => void;
  private readonly assemblies: Map<string, BurstAssembly> = new Map<string, BurstAssembly>();

  constructor(delegate: LiveVoiceAssemblerDelegate,
    nowMs: () => number = (): number => {
      return Date.now();
    },
    schedule: (delayMs: number, task: () => void) => number =
      (delayMs: number, task: () => void): number => {
        return setTimeout(task, delayMs);
      },
    cancel: (handle: number) => void = (handle: number): void => {
      clearTimeout(handle);
    }) {
    this.delegate = delegate;
    this.nowMs = nowMs;
    this.schedule = schedule;
    this.cancel = cancel;
  }

  /**
   * Ingest one burst packet. Returns false only when the frame violates the
   * live-voice wire/resource contract (malformed payload, quota breach,
   * unsupported codec, over-capacity); a duplicate or late frame stays true.
   */
  handleFrame(peerID: string, scope: LiveVoiceScope, payload: Uint8Array,
    timestampMs: number): boolean {
    const packet: VoiceBurstPacket | null = VoiceBurstPacket.decode(payload);
    if (packet === null) {
      return false;
    }
    const burstIDHex: string = VoiceBurstPacket.burstIDHex(packet.burstID);
    const key: string = LiveVoiceAssembler.assemblyKey(peerID, scope, burstIDHex);
    let assembly: BurstAssembly | undefined = this.assemblies.get(key);
    if (assembly === undefined) {
      if (packet.kind instanceof VoiceBurstEnd || packet.kind instanceof VoiceBurstCanceled) {
        return true;
      }
      if (this.assemblies.size >= LiveVoiceConstants.MAX_CONCURRENT_ASSEMBLIES) {
        return false;
      }
      assembly = new BurstAssembly(key, peerID, burstIDHex, scope, this.nowMs());
      this.assemblies.set(key, assembly);
      this.delegate.onBurstStarted(peerID, burstIDHex, scope, timestampMs);
    }

    assembly.receivedBytes += payload.length;
    const elapsedSeconds: number =
      Math.max(0, this.nowMs() - assembly.startedAtMs) / 1000 + 2;
    if (assembly.receivedBytes > LiveVoiceConstants.MAX_BURST_BYTES ||
      assembly.receivedBytes > LiveVoiceConstants.INBOUND_BYTES_PER_SECOND * elapsedSeconds) {
      this.finalizeAssembly(assembly);
      return false;
    }
    this.rescheduleIdle(assembly);

    if (packet.kind instanceof VoiceBurstStart) {
      if (packet.kind.codec !== VoiceBurstCodec.AAC_LC_16K_MONO) {
        this.cancelAssembly(assembly);
        return false;
      }
      return true;
    }
    if (packet.kind instanceof VoiceBurstFrames) {
      if (packet.sequence < assembly.nextSequence || assembly.buffered.has(packet.sequence)) {
        return true;
      }
      if (assembly.buffered.size >= LiveVoiceConstants.MAX_BUFFERED_PACKETS) {
        return false;
      }
      assembly.buffered.set(packet.sequence, packet.kind.frames);
      this.drainInOrder(assembly);
      return true;
    }
    if (packet.kind instanceof VoiceBurstEnd) {
      assembly.endTotalPackets = packet.kind.totalDataPackets;
      this.drainInOrder(assembly);
      this.finalizeIfComplete(assembly);
      return true;
    }
    this.cancelAssembly(assembly);
    return true;
  }

  /** Number of bursts currently being assembled. */
  getActiveBurstCount(): number {
    return this.assemblies.size;
  }

  /** Cancel every assembly and timer (identity change / logout / panic). */
  reset(): void {
    this.assemblies.forEach((assembly: BurstAssembly): void => {
      if (assembly.idleHandle !== -1) {
        this.cancel(assembly.idleHandle);
        assembly.idleHandle = -1;
      }
      if (assembly.gapHandle !== -1) {
        this.cancel(assembly.gapHandle);
        assembly.gapHandle = -1;
      }
    });
    this.assemblies.clear();
  }

  private static assemblyKey(peerID: string, scope: LiveVoiceScope,
    burstIDHex: string): string {
    return peerID + '|' + scope + '|' + burstIDHex;
  }

  private drainInOrder(assembly: BurstAssembly): void {
    while (true) {
      const frames: Uint8Array[] | undefined = assembly.buffered.get(assembly.nextSequence);
      if (frames !== undefined) {
        assembly.buffered.delete(assembly.nextSequence);
        this.delegate.onOrderedFrames(assembly.peerID, assembly.burstIDHex,
          assembly.scope, frames);
        assembly.deliveredFrames += frames.length;
        assembly.deliveredPackets += 1;
        assembly.nextSequence = (assembly.nextSequence + 1) & 0xFFFF;
        if (assembly.gapHandle !== -1) {
          this.cancel(assembly.gapHandle);
          assembly.gapHandle = -1;
        }
        continue;
      }
      if (assembly.buffered.size > 0 && assembly.gapHandle === -1) {
        const key: string = assembly.key;
        const firstSequence: number = LiveVoiceAssembler.firstKey(assembly.buffered);
        assembly.gapHandle = this.schedule(LiveVoiceConstants.GAP_SKIP_MS, (): void => {
          const current: BurstAssembly | undefined = this.assemblies.get(key);
          if (current === undefined) {
            return;
          }
          current.gapHandle = -1;
          const available: number = LiveVoiceAssembler.firstKey(current.buffered);
          if (current.buffered.size > 0) {
            this.skipGap(current, available);
          }
          this.drainInOrder(current);
          this.finalizeIfComplete(current);
        });
      }
      return;
    }
  }

  private finalizeIfComplete(assembly: BurstAssembly): void {
    if (assembly.endTotalPackets < 0) {
      return;
    }
    if (assembly.nextSequence > assembly.endTotalPackets) {
      this.finalizeAssembly(assembly);
    }
  }

  private finalizeAssembly(assembly: BurstAssembly): void {
    if (!this.assemblies.delete(assembly.key)) {
      return;
    }
    if (assembly.idleHandle !== -1) {
      this.cancel(assembly.idleHandle);
      assembly.idleHandle = -1;
    }
    if (assembly.gapHandle !== -1) {
      this.cancel(assembly.gapHandle);
      assembly.gapHandle = -1;
    }
    while (assembly.buffered.size > 0) {
      this.skipGap(assembly, LiveVoiceAssembler.firstKey(assembly.buffered));
      this.drainInOrder(assembly);
      if (assembly.gapHandle !== -1) {
        this.cancel(assembly.gapHandle);
        assembly.gapHandle = -1;
      }
    }
    const missingPackets: number = assembly.endTotalPackets >= 0 ?
      Math.max(assembly.endTotalPackets - assembly.deliveredPackets, assembly.missingPackets) :
      assembly.missingPackets;
    this.delegate.onBurstFinished(assembly.peerID, assembly.burstIDHex, assembly.scope,
      new LiveVoiceBurstStats(assembly.deliveredPackets, assembly.deliveredFrames,
        assembly.receivedBytes, assembly.endTotalPackets, missingPackets));
  }

  private cancelAssembly(assembly: BurstAssembly): void {
    if (!this.assemblies.delete(assembly.key)) {
      return;
    }
    if (assembly.idleHandle !== -1) {
      this.cancel(assembly.idleHandle);
      assembly.idleHandle = -1;
    }
    if (assembly.gapHandle !== -1) {
      this.cancel(assembly.gapHandle);
      assembly.gapHandle = -1;
    }
    this.delegate.onBurstCanceled(assembly.peerID, assembly.burstIDHex, assembly.scope);
  }

  private skipGap(assembly: BurstAssembly, nextAvailableSequence: number): void {
    const distance: number =
      (nextAvailableSequence - assembly.nextSequence) & 0xFFFF;
    if (distance >= 1 && distance <= 0x7FFF) {
      assembly.missingPackets += distance;
    }
    assembly.nextSequence = nextAvailableSequence;
  }

  private rescheduleIdle(assembly: BurstAssembly): void {
    if (assembly.idleHandle !== -1) {
      this.cancel(assembly.idleHandle);
    }
    const key: string = assembly.key;
    assembly.idleHandle = this.schedule(LiveVoiceConstants.IDLE_TIMEOUT_MS, (): void => {
      const current: BurstAssembly | undefined = this.assemblies.get(key);
      if (current !== undefined) {
        this.finalizeAssembly(current);
      }
    });
  }

  private static firstKey(buffered: Map<number, Uint8Array[]>): number {
    let min: number = 0;
    let first: boolean = true;
    buffered.forEach((_frames: Uint8Array[], sequence: number): void => {
      if (first || sequence < min) {
        min = sequence;
        first = false;
      }
    });
    return min;
  }
}
