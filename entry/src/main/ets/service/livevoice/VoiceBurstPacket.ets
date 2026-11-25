/**
 * Live push-to-talk burst wire format (US14, T069) - mirrors bitchat-android
 * features/voice/VoiceBurstPacket.kt (shared with iOS, FR-028).
 *
 * One burst packet on the wire:
 *   `[burstID: 8][seq: u16 BE][flags: u8][payload...]`
 * with FLAG_START (codec byte), FLAG_END (total packets u16 BE + duration
 * u32 BE), FLAG_CANCELED and flag 0 carrying length-prefixed AAC access
 * units (u16 BE length each, at most MAX_FRAMES_PER_PACKET per packet).
 *
 * The greedy packetizer keeps one Noise-wrapped frame under the wire budget
 * (MAX_CONTENT_BYTES) so a burst packet never needs fragmentation, and
 * AdtsFramer adds the 7-byte ADTS header an ADTS-less AAC-LC/16 kHz/mono
 * access unit needs for file/live playback.
 *
 * Deliberately free of device imports so the codec runs in the host
 * contract harness (same policy as the protocol kernel).
 */
import { ByteUtils } from '../../common/ByteUtils';

/** iOS-compatible codec identifier carried by a live burst START packet. */
export enum VoiceBurstCodec {
  AAC_LC_16K_MONO = 0x01
}

export function voiceBurstCodecFromValue(value: number): VoiceBurstCodec | null {
  if (value === VoiceBurstCodec.AAC_LC_16K_MONO) {
    return VoiceBurstCodec.AAC_LC_16K_MONO;
  }
  return null;
}

/** Burst packet kind (Android sealed Kind). */
export abstract class VoiceBurstKind {
}

export class VoiceBurstStart extends VoiceBurstKind {
  readonly codec: VoiceBurstCodec;

  constructor(codec: VoiceBurstCodec) {
    super();
    this.codec = codec;
  }
}

export class VoiceBurstFrames extends VoiceBurstKind {
  readonly frames: Uint8Array[];

  constructor(frames: Uint8Array[]) {
    super();
    this.frames = frames;
  }
}

export class VoiceBurstEnd extends VoiceBurstKind {
  readonly totalDataPackets: number;
  readonly durationMs: number;

  constructor(totalDataPackets: number, durationMs: number) {
    super();
    this.totalDataPackets = totalDataPackets;
    this.durationMs = durationMs;
  }
}

export class VoiceBurstCanceled extends VoiceBurstKind {
}

/** One live push-to-talk burst packet. */
export class VoiceBurstPacket {
  static readonly BURST_ID_SIZE: number = 8;
  static readonly HEADER_SIZE: number = 11;
  static readonly MAX_FRAMES_PER_PACKET: number = 8;
  /** Packetizer budget: wire bytes of one Frames packet stay unfragmented. */
  static readonly MAX_CONTENT_BYTES: number = 210;
  static readonly FLAG_START: number = 0x01;
  static readonly FLAG_END: number = 0x02;
  static readonly FLAG_CANCELED: number = 0x04;

  readonly burstID: Uint8Array;
  readonly sequence: number;
  readonly kind: VoiceBurstKind;

  private constructor(burstID: Uint8Array, sequence: number, kind: VoiceBurstKind) {
    this.burstID = burstID;
    this.sequence = sequence;
    this.kind = kind;
  }

  encode(): Uint8Array {
    let size: number = VoiceBurstPacket.HEADER_SIZE;
    if (this.kind instanceof VoiceBurstStart) {
      size += 1;
    } else if (this.kind instanceof VoiceBurstFrames) {
      const frames: Uint8Array[] = this.kind.frames;
      for (let i: number = 0; i < frames.length; i++) {
        size += 2 + frames[i].length;
      }
    } else if (this.kind instanceof VoiceBurstEnd) {
      size += 6;
    }
    // Canceled carries the bare header.
    const out: Uint8Array = new Uint8Array(size);
    out.set(this.burstID, 0);
    out[8] = (this.sequence >>> 8) & 0xFF;
    out[9] = this.sequence & 0xFF;
    if (this.kind instanceof VoiceBurstStart) {
      out[10] = VoiceBurstPacket.FLAG_START;
      out[11] = this.kind.codec;
    } else if (this.kind instanceof VoiceBurstFrames) {
      out[10] = 0;
      let offset: number = VoiceBurstPacket.HEADER_SIZE;
      const frames: Uint8Array[] = this.kind.frames;
      for (let i: number = 0; i < frames.length; i++) {
        const frame: Uint8Array = frames[i];
        out[offset] = (frame.length >>> 8) & 0xFF;
        out[offset + 1] = frame.length & 0xFF;
        out.set(frame, offset + 2);
        offset += 2 + frame.length;
      }
    } else if (this.kind instanceof VoiceBurstEnd) {
      out[10] = VoiceBurstPacket.FLAG_END;
      out[11] = (this.kind.totalDataPackets >>> 8) & 0xFF;
      out[12] = this.kind.totalDataPackets & 0xFF;
      out[13] = (this.kind.durationMs >>> 24) & 0xFF;
      out[14] = (this.kind.durationMs >>> 16) & 0xFF;
      out[15] = (this.kind.durationMs >>> 8) & 0xFF;
      out[16] = this.kind.durationMs & 0xFF;
    } else {
      out[10] = VoiceBurstPacket.FLAG_CANCELED;
    }
    return out;
  }

  /** Validate and build one packet; null when any field violates the contract. */
  static create(burstID: Uint8Array, sequence: number,
    kind: VoiceBurstKind): VoiceBurstPacket | null {
    if (burstID.length !== VoiceBurstPacket.BURST_ID_SIZE) {
      return null;
    }
    if (sequence < 0 || sequence > 0xFFFF) {
      return null;
    }
    if (kind instanceof VoiceBurstFrames) {
      const frames: Uint8Array[] = kind.frames;
      if (frames.length === 0 || frames.length > VoiceBurstPacket.MAX_FRAMES_PER_PACKET) {
        return null;
      }
      for (let i: number = 0; i < frames.length; i++) {
        if (frames[i].length === 0 || frames[i].length > 0xFFFF) {
          return null;
        }
      }
    } else if (kind instanceof VoiceBurstEnd) {
      if (kind.totalDataPackets < 0 || kind.totalDataPackets > 0xFFFF ||
        kind.durationMs < 0 || kind.durationMs > 0xFFFFFFFF) {
        return null;
      }
    }
    return new VoiceBurstPacket(burstID.slice(), sequence, kind);
  }

  /** Decode one burst packet; null on any malformed layout. */
  static decode(data: Uint8Array): VoiceBurstPacket | null {
    if (data.length < VoiceBurstPacket.HEADER_SIZE) {
      return null;
    }
    const burstID: Uint8Array = data.slice(0, VoiceBurstPacket.BURST_ID_SIZE);
    const sequence: number = ((data[8] & 0xFF) << 8) | (data[9] & 0xFF);
    const flags: number = data[10] & 0xFF;
    const offset: number = VoiceBurstPacket.HEADER_SIZE;
    let kind: VoiceBurstKind | null = null;
    if (flags === VoiceBurstPacket.FLAG_START) {
      if (offset >= data.length) {
        return null;
      }
      const codec: VoiceBurstCodec | null = voiceBurstCodecFromValue(data[offset] & 0xFF);
      if (codec === null) {
        return null;
      }
      kind = new VoiceBurstStart(codec);
    } else if (flags === VoiceBurstPacket.FLAG_END) {
      if (data.length - offset < 6) {
        return null;
      }
      const total: number = ((data[offset] & 0xFF) << 8) | (data[offset + 1] & 0xFF);
      let duration: number = 0;
      for (let i: number = 0; i < 4; i++) {
        duration = (duration * 256) + (data[offset + 2 + i] & 0xFF);
      }
      kind = new VoiceBurstEnd(total, duration);
    } else if (flags === VoiceBurstPacket.FLAG_CANCELED) {
      kind = new VoiceBurstCanceled();
    } else if (flags === 0) {
      const frames: Uint8Array[] = [];
      let cursor: number = offset;
      while (cursor < data.length) {
        if (data.length - cursor < 2 ||
          frames.length >= VoiceBurstPacket.MAX_FRAMES_PER_PACKET) {
          return null;
        }
        const length: number = ((data[cursor] & 0xFF) << 8) | (data[cursor + 1] & 0xFF);
        cursor += 2;
        if (length <= 0 || data.length - cursor < length) {
          return null;
        }
        frames.push(data.slice(cursor, cursor + length));
        cursor += length;
      }
      if (frames.length === 0) {
        return null;
      }
      kind = new VoiceBurstFrames(frames);
    } else {
      return null;
    }
    return VoiceBurstPacket.create(burstID, sequence, kind);
  }

  /** Fresh 8-byte burst ID from the injected CSPRNG (device wires crypto). */
  static makeBurstID(randomBytes: (count: number) => Uint8Array): Uint8Array {
    return randomBytes(VoiceBurstPacket.BURST_ID_SIZE);
  }

  static burstIDHex(burstID: Uint8Array): string {
    return ByteUtils.bytesToHex(burstID);
  }
}

/**
 * Greedy packetizer constrained so one Noise-wrapped frame stays out of
 * fragmentation (Android VoiceBurstPacketizer). Sequence 0 is reserved for
 * the START packet; data packets number from 1.
 */
export class VoiceBurstPacketizer {
  private readonly burstID: Uint8Array;
  private readonly budget: number;
  private pendingFrames: Uint8Array[] = [];
  private pendingSize: number = 0;
  private sequence: number = 1;
  private dataPacketCount: number = 0;
  private droppedFrameCount: number = 0;

  constructor(burstID: Uint8Array, budget: number = VoiceBurstPacket.MAX_CONTENT_BYTES) {
    this.burstID = burstID;
    this.budget = budget;
  }

  /** Queue one encoded access unit; returns packets that must go out now. */
  add(frame: Uint8Array): Uint8Array[] {
    const frameCost: number = 2 + frame.length;
    if (VoiceBurstPacket.HEADER_SIZE + frameCost > this.budget) {
      this.droppedFrameCount += 1;
      return [];
    }
    const output: Uint8Array[] = [];
    if (this.pendingFrames.length > 0 &&
      (VoiceBurstPacket.HEADER_SIZE + this.pendingSize + frameCost > this.budget ||
        this.pendingFrames.length >= VoiceBurstPacket.MAX_FRAMES_PER_PACKET)) {
      const flushed: Uint8Array[] = this.flush();
      for (let i: number = 0; i < flushed.length; i++) {
        output.push(flushed[i]);
      }
    }
    this.pendingFrames.push(frame.slice());
    this.pendingSize += frameCost;
    return output;
  }

  /** Emit the pending frames as one packet (empty when nothing is pending). */
  flush(): Uint8Array[] {
    if (this.pendingFrames.length === 0) {
      return [];
    }
    const packet: VoiceBurstPacket | null = VoiceBurstPacket.create(
      this.burstID, this.sequence, new VoiceBurstFrames(this.pendingFrames));
    this.pendingFrames = [];
    this.pendingSize = 0;
    if (packet === null) {
      return [];
    }
    this.sequence = (this.sequence + 1) & 0xFFFF;
    if (this.dataPacketCount < 0xFFFF) {
      this.dataPacketCount += 1;
    }
    return [packet.encode()];
  }

  getNextSequence(): number {
    return this.sequence;
  }

  getDataPacketCount(): number {
    return this.dataPacketCount;
  }

  getDroppedFrameCount(): number {
    return this.droppedFrameCount;
  }
}

/** Adds the seven-byte ADTS header to an ADTS-less AAC-LC/16 kHz/mono unit. */
export class AdtsFramer {
  static frame(payload: Uint8Array): Uint8Array | null {
    const frameLength: number = payload.length + 7;
    if (frameLength > 0x1FFF) {
      return null;
    }
    const output: Uint8Array = new Uint8Array(frameLength);
    output[0] = 0xFF;
    output[1] = 0xF1;
    // AAC-LC, 16 kHz frequency index, mono channel config high bit.
    output[2] = 0x60;
    output[3] = (0x40 | ((frameLength >>> 11) & 0x03)) & 0xFF;
    output[4] = (frameLength >>> 3) & 0xFF;
    output[5] = (((frameLength & 0x07) << 5) | 0x1F) & 0xFF;
    output[6] = 0xFC;
    output.set(payload, 7);
    return output;
  }
}
