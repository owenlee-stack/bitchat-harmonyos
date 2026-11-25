/**
 * Golomb-Coded Set (GCS) filter for sync - mirrors bitchat-android GCSFilter.kt.
 *
 * Hashing:
 * - h64(id) = first 8 bytes of SHA-256 over the 16-byte PacketId (big-endian
 *   unsigned), masked to 63 bits, then mapped to [0, M) via h64 % M.
 * - h63 values exceed double's exact 2^53 integer range, so the modulo is
 *   computed byte-wise: acc = (acc * 256 + byte) % M, which is exact for all
 *   M < 2^45 (every wire-reachable M is a uint32).
 *
 * Encoding (v1):
 * - Sort mapped values ascending; encode deltas (first is v0, then
 *   vi - v{i-1}) as positive integers.
 * - For each delta x >= 1, write Golomb-Rice code with parameter P:
 *   q = (x - 1) >> P (unary q ones followed by a zero), then P low bits
 *   r = (x - 1) & ((1 << P) - 1). Bitstream packed MSB-first per byte.
 */
import { ByteUtils } from '../../common/ByteUtils';

export class GcsFilterParams {
  readonly p: number;
  readonly m: number;
  readonly data: Uint8Array;

  constructor(p: number, m: number, data: Uint8Array) {
    this.p = p;
    this.m = m;
    this.data = data;
  }
}

/** MSB-first bit writer. */
class GcsBitWriter {
  private buf: number[] = [];
  private cur: number = 0;
  private nbits: number = 0;

  writeBit(bit: number): void {
    this.cur = ((this.cur << 1) | (bit & 1)) & 0xFF;
    this.nbits += 1;
    if (this.nbits === 8) {
      this.buf.push(this.cur);
      this.cur = 0;
      this.nbits = 0;
    }
  }

  writeBits(value: number, count: number): void {
    if (count <= 0) {
      return;
    }
    for (let i: number = count - 1; i >= 0; i--) {
      const bit: number = Math.floor(value / Math.pow(2, i)) % 2;
      this.writeBit(bit);
    }
  }

  toUint8Array(): Uint8Array {
    if (this.nbits > 0) {
      const rem: number = (this.cur << (8 - this.nbits)) & 0xFF;
      this.buf.push(rem);
      this.cur = 0;
      this.nbits = 0;
    }
    const out: Uint8Array = new Uint8Array(this.buf.length);
    for (let i: number = 0; i < this.buf.length; i++) {
      out[i] = this.buf[i];
    }
    return out;
  }
}

/** MSB-first bit reader. */
class GcsBitReader {
  private readonly data: Uint8Array;
  private i: number = 0;
  private nleft: number = 8;
  private cur: number;
  private lastWasEOF: boolean = false;

  constructor(data: Uint8Array) {
    this.data = data;
    this.cur = data.length > 0 ? (data[0] & 0xFF) : 0;
  }

  eof(): boolean {
    return this.i >= this.data.length;
  }

  wasEOF(): boolean {
    return this.lastWasEOF;
  }

  readBit(): number | null {
    if (this.i >= this.data.length) {
      this.lastWasEOF = true;
      return null;
    }
    const bit: number = (this.cur >>> 7) & 1;
    this.cur = (this.cur << 1) & 0xFF;
    this.nleft -= 1;
    if (this.nleft === 0) {
      this.i += 1;
      if (this.i < this.data.length) {
        this.cur = this.data[this.i] & 0xFF;
        this.nleft = 8;
      }
    }
    return bit;
  }

  readBits(count: number): number | null {
    let v: number = 0;
    for (let k: number = 0; k < count; k++) {
      const b: number | null = this.readBit();
      if (b === null) {
        return null;
      }
      v = v * 2 + b;
    }
    return v;
  }
}

export class GCSFilter {
  /**
   * Highest Golomb-Rice parameter accepted from the wire. P maps to an FPR of
   * ~1/2^P; beyond 32 the remainder width exceeds any practical filter and
   * shifts silently wrap into garbage values.
   */
  static readonly MAX_P: number = 32;

  /** Derive P from target FPR; FPR ~= 1 / 2^P. */
  static deriveP(targetFpr: number): number {
    const f: number = Math.min(Math.max(targetFpr, 0.000001), 0.25);
    return Math.max(Math.ceil(Math.log(1.0 / f) / Math.log(2.0)), 1);
  }

  /** Rough capacity estimate: expected bits per element ~= P + 2. */
  static estimateMaxElementsForSize(bytes: number, p: number): number {
    const bits: number = Math.max(bytes * 8, 8);
    const per: number = Math.max(p + 2, 3);
    return Math.max(Math.floor(bits / per), 1);
  }

  static buildFilter(ids: Uint8Array[], maxBytes: number, targetFpr: number): GcsFilterParams {
    const p: number = GCSFilter.deriveP(targetFpr);
    const nCap: number = GCSFilter.estimateMaxElementsForSize(maxBytes, p);
    let trimmedN: number = Math.min(ids.length, nCap);

    let finalM: number = Math.max(trimmedN * Math.pow(2, p), 1);
    let mapped: number[] = GCSFilter.mapIds(ids, trimmedN, finalM);
    let encoded: Uint8Array = GCSFilter.encodeSorted(mapped, p);

    // If the estimate was too optimistic, trim until it fits.
    while (encoded.length > maxBytes && trimmedN > 0) {
      trimmedN = Math.floor((trimmedN * 9) / 10); // drop 10%
      finalM = Math.max(trimmedN * Math.pow(2, p), 1);
      mapped = GCSFilter.mapIds(ids, trimmedN, finalM);
      encoded = GCSFilter.encodeSorted(mapped, p);
    }

    return new GcsFilterParams(p, finalM, encoded);
  }

  static decodeToSortedSet(p: number, m: number, data: Uint8Array): number[] {
    // p and m arrive off the wire. Reject out-of-range parameters rather than
    // decoding garbage: callers read the result as "peer has nothing" and fall
    // back to sending the data, which is the safe direction.
    if (p < 1 || p > GCSFilter.MAX_P || m <= 1) {
      return [];
    }
    const values: number[] = [];
    const reader: GcsBitReader = new GcsBitReader(data);
    let acc: number = 0;
    const twoPowP: number = Math.pow(2, p);
    while (!reader.eof()) {
      // Read unary quotient (q ones terminated by zero).
      let q: number = 0;
      while (true) {
        const b: number | null = reader.readBit();
        if (b === null) {
          break;
        }
        if (b === 1) {
          q += 1;
        } else {
          break;
        }
      }
      if (reader.wasEOF()) {
        break;
      }
      // Read remainder.
      const r: number | null = reader.readBits(p);
      if (r === null) {
        break;
      }
      const x: number = q * twoPowP + r + 1;
      acc += x;
      if (acc >= m) {
        break; // out of range safeguard
      }
      values.push(acc);
    }
    return values;
  }

  static contains(sortedValues: number[], candidate: number): boolean {
    let lo: number = 0;
    let hi: number = sortedValues.length - 1;
    while (lo <= hi) {
      const mid: number = Math.floor((lo + hi) / 2);
      const v: number = sortedValues[mid];
      if (v === candidate) {
        return true;
      }
      if (v < candidate) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return false;
  }

  /**
   * h64(id16) mod m: first 8 bytes of SHA-256(id16) big-endian, masked to 63
   * bits, reduced mod m. Computed byte-wise so the 63-bit intermediate never
   * materializes as a double.
   */
  static h64modM(id16: Uint8Array, m: number): number {
    const d: Uint8Array = ByteUtils.sha256(id16);
    let acc: number = d[0] & 0x7F; // mask off the top bit
    for (let i: number = 1; i < 8; i++) {
      acc = (acc * 256 + (d[i] & 0xFF)) % m;
    }
    return acc;
  }

  private static mapIds(ids: Uint8Array[], count: number, m: number): number[] {
    const raw: number[] = [];
    for (let i: number = 0; i < count; i++) {
      const v: number = GCSFilter.h64modM(ids[i], m);
      raw.push(v === 0 ? 1 : v);
    }
    raw.sort((a: number, b: number): number => a - b);
    // Deduplicate in place after sorting.
    const mapped: number[] = [];
    for (let i: number = 0; i < raw.length; i++) {
      if (i === 0 || raw[i] !== raw[i - 1]) {
        mapped.push(raw[i]);
      }
    }
    return mapped;
  }

  private static encodeSorted(sorted: number[], p: number): Uint8Array {
    const bw: GcsBitWriter = new GcsBitWriter();
    let prev: number = 0;
    const twoPowP: number = Math.pow(2, p);
    for (let i: number = 0; i < sorted.length; i++) {
      const delta: number = sorted[i] - prev;
      prev = sorted[i];
      const x: number = delta;
      const q: number = Math.floor((x - 1) / twoPowP);
      const r: number = (x - 1) % twoPowP;
      // Unary q ones then a zero.
      for (let k: number = 0; k < q; k++) {
        bw.writeBit(1);
      }
      bw.writeBit(0);
      // Then P bits of r (MSB-first).
      bw.writeBits(r, p);
    }
    return bw.toUint8Array();
  }
}
