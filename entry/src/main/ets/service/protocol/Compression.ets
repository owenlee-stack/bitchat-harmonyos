/**
 * Pure-ArkTS DEFLATE (RFC 1951) + zlib (RFC 1950) codec.
 * Mirrors bitchat-android CompressionUtil.kt semantics exactly:
 * - compress() emits a raw DEFLATE stream (no zlib wrapper), fixed-Huffman
 *   blocks with LZ77 matching, and returns null unless the output is smaller.
 * - decompress() accepts raw or zlib-wrapped streams, tries zlib first when
 *   the RFC 1950 header is plausible, and requires an exact-size, complete,
 *   fully-consumed stream (compression-bomb and truncation safe).
 * Deliberately free of any @ohos.* import so it stays unit-testable.
 */
import { WireConstants } from '../../common/ProtocolConstants';

const LENGTH_BASE: number[] = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
  35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258
];
const LENGTH_EXTRA: number[] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
  3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0
];
const DIST_BASE: number[] = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
  257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
  8193, 12289, 16385, 24577
];
const DIST_EXTRA: number[] = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
  7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13
];
const CODE_LENGTH_ORDER: number[] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

function zeros(n: number): number[] {
  const out: number[] = [];
  for (let i: number = 0; i < n; i++) {
    out.push(0);
  }
  return out;
}

class HuffmanTables {
  readonly count: number[];
  readonly symbol: number[];

  constructor(count: number[], symbol: number[]) {
    this.count = count;
    this.symbol = symbol;
  }
}

/** Canonical Huffman construction (puff.c style). Throws on over-subscription. */
function constructHuffman(lengths: number[], n: number): HuffmanTables {
  const count: number[] = zeros(16);
  for (let i: number = 0; i < n; i++) {
    count[lengths[i]] += 1;
  }
  let left: number = 1;
  for (let len: number = 1; len <= 15; len++) {
    left = left << 1;
    left -= count[len];
    if (left < 0) {
      throw new Error('deflate: over-subscribed huffman code');
    }
  }
  const offs: number[] = zeros(16);
  for (let len: number = 1; len < 15; len++) {
    offs[len + 1] = offs[len] + count[len];
  }
  const symbol: number[] = zeros(n);
  for (let i: number = 0; i < n; i++) {
    if (lengths[i] !== 0) {
      symbol[offs[lengths[i]]] = i;
      offs[lengths[i]] += 1;
    }
  }
  return new HuffmanTables(count, symbol);
}

/** LSB-first DEFLATE bit reader over a byte range. */
class DeflateBitReader {
  private data: Uint8Array;
  private pos: number;
  private bit: number;

  constructor(data: Uint8Array, startByte: number) {
    this.data = data;
    this.pos = startByte;
    this.bit = 0;
  }

  readBit(): number {
    if (this.pos >= this.data.length) {
      throw new Error('deflate: unexpected end of input');
    }
    const v: number = (this.data[this.pos] >>> this.bit) & 1;
    this.bit += 1;
    if (this.bit === 8) {
      this.bit = 0;
      this.pos += 1;
    }
    return v;
  }

  readBits(n: number): number {
    let v: number = 0;
    for (let i: number = 0; i < n; i++) {
      v |= this.readBit() << i;
    }
    return v;
  }

  alignToByte(): void {
    if (this.bit !== 0) {
      this.bit = 0;
      this.pos += 1;
    }
  }

  readByte(): number {
    if (this.pos >= this.data.length) {
      throw new Error('deflate: unexpected end of input');
    }
    const v: number = this.data[this.pos] & 0xFF;
    this.pos += 1;
    return v;
  }

  readU16LE(): number {
    const lo: number = this.readByte();
    const hi: number = this.readByte();
    return lo | (hi << 8);
  }

  remainingBytes(): number {
    return this.data.length - this.pos;
  }

  /** Bytes considered consumed, counting a partially consumed byte (Java semantics). */
  consumedBytes(): number {
    return this.bit === 0 ? this.pos : this.pos + 1;
  }
}

function decodeSymbol(reader: DeflateBitReader, tables: HuffmanTables): number {
  let code: number = 0;
  let first: number = 0;
  let index: number = 0;
  for (let len: number = 1; len <= 15; len++) {
    code |= reader.readBit();
    const cnt: number = tables.count[len];
    if (code - first < cnt) {
      return tables.symbol[index + (code - first)];
    }
    index += cnt;
    first = (first + cnt) << 1;
    code = code << 1;
  }
  throw new Error('deflate: invalid huffman code');
}

function buildFixedTables(): HuffmanTables[] {
  const lengths: number[] = zeros(288);
  for (let i: number = 0; i <= 143; i++) {
    lengths[i] = 8;
  }
  for (let i: number = 144; i <= 255; i++) {
    lengths[i] = 9;
  }
  for (let i: number = 256; i <= 279; i++) {
    lengths[i] = 7;
  }
  for (let i: number = 280; i <= 287; i++) {
    lengths[i] = 8;
  }
  const lit: HuffmanTables = constructHuffman(lengths, 288);
  const distLengths: number[] = zeros(30);
  for (let i: number = 0; i < 30; i++) {
    distLengths[i] = 5;
  }
  const dist: HuffmanTables = constructHuffman(distLengths, 30);
  const tables: HuffmanTables[] = [lit, dist];
  return tables;
}

function readDynamicTables(reader: DeflateBitReader): HuffmanTables[] {
  const hlit: number = reader.readBits(5) + 257;
  const hdist: number = reader.readBits(5) + 1;
  const hclen: number = reader.readBits(4) + 4;
  if (hlit > 286 || hdist > 30) {
    throw new Error('deflate: invalid dynamic table sizes');
  }
  const clLengths: number[] = zeros(19);
  for (let i: number = 0; i < hclen; i++) {
    clLengths[CODE_LENGTH_ORDER[i]] = reader.readBits(3);
  }
  const clTable: HuffmanTables = constructHuffman(clLengths, 19);
  const lengths: number[] = zeros(hlit + hdist);
  let i: number = 0;
  while (i < hlit + hdist) {
    const sym: number = decodeSymbol(reader, clTable);
    if (sym < 16) {
      lengths[i] = sym;
      i += 1;
    } else if (sym === 16) {
      if (i === 0) {
        throw new Error('deflate: repeat with no previous length');
      }
      const prev: number = lengths[i - 1];
      const rep: number = 3 + reader.readBits(2);
      if (i + rep > hlit + hdist) {
        throw new Error('deflate: repeat overruns table');
      }
      for (let j: number = 0; j < rep; j++) {
        lengths[i] = prev;
        i += 1;
      }
    } else if (sym === 17) {
      const rep: number = 3 + reader.readBits(3);
      if (i + rep > hlit + hdist) {
        throw new Error('deflate: repeat overruns table');
      }
      i += rep;
    } else {
      const rep: number = 11 + reader.readBits(7);
      if (i + rep > hlit + hdist) {
        throw new Error('deflate: repeat overruns table');
      }
      i += rep;
    }
  }
  if (lengths[256] === 0) {
    throw new Error('deflate: missing end-of-block code');
  }
  const lit: HuffmanTables = constructHuffman(lengths.slice(0, hlit), hlit);
  const dist: HuffmanTables = constructHuffman(lengths.slice(hlit), hdist);
  const tables: HuffmanTables[] = [lit, dist];
  return tables;
}

/** Inflate a complete stream into exactly cap bytes; throws on any violation. */
function inflateStream(reader: DeflateBitReader, cap: number): Uint8Array {
  const out: Uint8Array = new Uint8Array(cap);
  let written: number = 0;
  let done: boolean = false;
  while (!done) {
    const bfinal: number = reader.readBit();
    const btype: number = reader.readBits(2);
    if (btype === 0) {
      reader.alignToByte();
      const len: number = reader.readU16LE();
      const nlen: number = reader.readU16LE();
      if ((len ^ 0xFFFF) !== nlen) {
        throw new Error('deflate: stored block length mismatch');
      }
      if (written + len > cap) {
        throw new Error('deflate: output exceeds declared size');
      }
      for (let i: number = 0; i < len; i++) {
        out[written] = reader.readByte();
        written += 1;
      }
    } else if (btype === 1 || btype === 2) {
      const tables: HuffmanTables[] = btype === 1 ? buildFixedTables() : readDynamicTables(reader);
      const lit: HuffmanTables = tables[0];
      const dist: HuffmanTables = tables[1];
      let endOfBlock: boolean = false;
      while (!endOfBlock) {
        const sym: number = decodeSymbol(reader, lit);
        if (sym < 256) {
          if (written >= cap) {
            throw new Error('deflate: output exceeds declared size');
          }
          out[written] = sym;
          written += 1;
        } else if (sym === 256) {
          endOfBlock = true;
        } else {
          const li: number = sym - 257;
          if (li >= 29) {
            throw new Error('deflate: invalid length symbol');
          }
          const len: number = LENGTH_BASE[li] +
            (LENGTH_EXTRA[li] > 0 ? reader.readBits(LENGTH_EXTRA[li]) : 0);
          const dsym: number = decodeSymbol(reader, dist);
          if (dsym >= 30) {
            throw new Error('deflate: invalid distance symbol');
          }
          const distv: number = DIST_BASE[dsym] +
            (DIST_EXTRA[dsym] > 0 ? reader.readBits(DIST_EXTRA[dsym]) : 0);
          if (distv > written) {
            throw new Error('deflate: distance too far back');
          }
          if (written + len > cap) {
            throw new Error('deflate: output exceeds declared size');
          }
          let from: number = written - distv;
          for (let i: number = 0; i < len; i++) {
            out[written] = out[from];
            written += 1;
            from += 1;
          }
        }
      }
    } else {
      throw new Error('deflate: invalid block type');
    }
    if (bfinal === 1) {
      done = true;
    }
  }
  if (written !== cap) {
    throw new Error('deflate: stream expanded to ' + written + ' instead of ' + cap);
  }
  return out;
}

function adler32(data: Uint8Array): number {
  let a: number = 1;
  let b: number = 0;
  for (let i: number = 0; i < data.length; i++) {
    a = (a + (data[i] & 0xFF)) % 65521;
    b = (b + a) % 65521;
  }
  return b * 65536 + a;
}

/** LSB-first bit writer with MSB-first Huffman code emission. */
class DeflateBitWriter {
  private bytes: number[];
  private bitBuf: number;
  private bitCnt: number;

  constructor() {
    this.bytes = [];
    this.bitBuf = 0;
    this.bitCnt = 0;
  }

  writeBits(value: number, count: number): void {
    this.bitBuf |= value << this.bitCnt;
    this.bitCnt += count;
    while (this.bitCnt >= 8) {
      this.bytes.push(this.bitBuf & 0xFF);
      this.bitBuf = this.bitBuf >>> 8;
      this.bitCnt -= 8;
    }
  }

  writeCode(code: number, length: number): void {
    let rev: number = 0;
    for (let i: number = 0; i < length; i++) {
      rev = (rev << 1) | ((code >>> (length - 1 - i)) & 1);
    }
    this.writeBits(rev, length);
  }

  flush(): void {
    if (this.bitCnt > 0) {
      this.bytes.push(this.bitBuf & 0xFF);
      this.bitBuf = 0;
      this.bitCnt = 0;
    }
  }

  toUint8Array(): Uint8Array {
    const out: Uint8Array = new Uint8Array(this.bytes.length);
    for (let i: number = 0; i < this.bytes.length; i++) {
      out[i] = this.bytes[i];
    }
    return out;
  }
}

/** Fixed-Huffman LZ77 compressor producing a single raw DEFLATE block. */
class FixedDeflater {
  private static readonly MIN_MATCH: number = 3;
  private static readonly MAX_MATCH: number = 258;
  private static readonly WINDOW: number = 32768;
  private static readonly HASH_BITS: number = 15;
  private static readonly HASH_SIZE: number = 1 << 15;
  private static readonly MAX_CHAIN: number = 128;

  private data: Uint8Array;
  private head: Int32Array;
  private prev: Int32Array;
  private writer: DeflateBitWriter;

  constructor(data: Uint8Array) {
    this.data = data;
    this.head = new Int32Array(FixedDeflater.HASH_SIZE).fill(-1);
    this.prev = new Int32Array(data.length).fill(-1);
    this.writer = new DeflateBitWriter();
  }

  private hash(p: number): number {
    return (((this.data[p] << 10) ^ (this.data[p + 1] << 5) ^ this.data[p + 2]) &
      (FixedDeflater.HASH_SIZE - 1)) >>> 0;
  }

  private insert(p: number): void {
    const h: number = this.hash(p);
    this.prev[p] = this.head[h];
    this.head[h] = p;
  }

  private emitLiteral(b: number): void {
    if (b <= 143) {
      this.writer.writeCode(0x30 + b, 8);
    } else {
      this.writer.writeCode(0x190 + (b - 144), 9);
    }
  }

  private emitEndOfBlock(): void {
    this.writer.writeCode(0, 7);
  }

  private emitMatch(len: number, dist: number): void {
    let li: number = 0;
    for (let i: number = 28; i >= 0; i--) {
      if (LENGTH_BASE[i] <= len) {
        li = i;
        break;
      }
    }
    const sym: number = 257 + li;
    if (sym <= 279) {
      this.writer.writeCode(sym - 256, 7);
    } else {
      this.writer.writeCode(0xC0 + (sym - 280), 8);
    }
    if (LENGTH_EXTRA[li] > 0) {
      this.writer.writeBits(len - LENGTH_BASE[li], LENGTH_EXTRA[li]);
    }
    let di: number = 0;
    for (let i: number = 29; i >= 0; i--) {
      if (DIST_BASE[i] <= dist) {
        di = i;
        break;
      }
    }
    this.writer.writeCode(di, 5);
    if (DIST_EXTRA[di] > 0) {
      this.writer.writeBits(dist - DIST_BASE[di], DIST_EXTRA[di]);
    }
  }

  run(): Uint8Array {
    this.writer.writeBits(1, 1); // BFINAL
    this.writer.writeBits(1, 2); // BTYPE = fixed Huffman
    const n: number = this.data.length;
    let pos: number = 0;
    while (pos < n) {
      let bestLen: number = 0;
      let bestDist: number = 0;
      if (pos + FixedDeflater.MIN_MATCH <= n) {
        const h: number = this.hash(pos);
        let cand: number = this.head[h];
        let attempts: number = 0;
        const maxLen: number = Math.min(FixedDeflater.MAX_MATCH, n - pos);
        while (cand >= 0 && attempts < FixedDeflater.MAX_CHAIN &&
          pos - cand <= FixedDeflater.WINDOW) {
          attempts += 1;
          let len: number = 0;
          while (len < maxLen && this.data[cand + len] === this.data[pos + len]) {
            len += 1;
          }
          if (len > bestLen) {
            bestLen = len;
            bestDist = pos - cand;
            if (len >= maxLen) {
              break;
            }
          }
          cand = this.prev[cand];
        }
      }
      if (bestLen >= FixedDeflater.MIN_MATCH) {
        this.emitMatch(bestLen, bestDist);
        const end: number = pos + bestLen;
        let p: number = pos;
        while (p < end && p + FixedDeflater.MIN_MATCH <= n) {
          this.insert(p);
          p += 1;
        }
        pos = end;
      } else {
        this.emitLiteral(this.data[pos]);
        if (pos + FixedDeflater.MIN_MATCH <= n) {
          this.insert(pos);
        }
        pos += 1;
      }
    }
    this.emitEndOfBlock();
    this.writer.flush();
    return this.writer.toUint8Array();
  }
}

export class CompressionUtil {
  /** Compress only if at least the threshold size and entropy is low enough. */
  static shouldCompress(data: Uint8Array): boolean {
    if (data.length < WireConstants.COMPRESSION_THRESHOLD_BYTES) {
      return false;
    }
    const seen: Uint8Array = new Uint8Array(256);
    let unique: number = 0;
    for (let i: number = 0; i < data.length; i++) {
      const b: number = data[i] & 0xFF;
      if (seen[b] === 0) {
        seen[b] = 1;
        unique += 1;
      }
    }
    const denominator: number = Math.min(data.length, 256);
    const uniqueByteRatio: number = unique / denominator;
    return uniqueByteRatio < 0.9;
  }

  /** Raw DEFLATE (no zlib wrapper); null when not beneficial. */
  static compress(data: Uint8Array): Uint8Array | null {
    if (data.length < WireConstants.COMPRESSION_THRESHOLD_BYTES) {
      return null;
    }
    try {
      const compressed: Uint8Array = new FixedDeflater(data).run();
      if (compressed.length > 0 && compressed.length < data.length) {
        return compressed;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  static decompress(compressedData: Uint8Array, originalSize: number): Uint8Array | null {
    if (!CompressionUtil.isValidRequest(compressedData, originalSize)) {
      return null;
    }
    return CompressionUtil.decompressExact(compressedData, originalSize);
  }

  private static isValidRequest(compressedData: Uint8Array, originalSize: number): boolean {
    if (compressedData.length === 0) {
      return false;
    }
    if (originalSize <= 0 || originalSize > WireConstants.MAX_PAYLOAD_LENGTH) {
      return false;
    }
    return true;
  }

  private static decompressExact(compressedData: Uint8Array, originalSize: number): Uint8Array | null {
    if (CompressionUtil.looksLikeZlib(compressedData)) {
      // A raw stream can coincidentally begin with a valid-looking zlib
      // header; the header only decides which format to try first.
      const zlibResult: Uint8Array | null = CompressionUtil.inflateExactZlib(compressedData, originalSize);
      if (zlibResult !== null) {
        return zlibResult;
      }
      return CompressionUtil.inflateExactRaw(compressedData, originalSize);
    }
    return CompressionUtil.inflateExactRaw(compressedData, originalSize);
  }

  /** RFC 1950 header check used to avoid speculative double inflation. */
  static looksLikeZlib(data: Uint8Array): boolean {
    if (data.length < 2) {
      return false;
    }
    const cmf: number = data[0] & 0xFF;
    const flg: number = data[1] & 0xFF;
    return (cmf & 0x0F) === 8 &&
      (cmf >>> 4) <= 7 &&
      (((cmf << 8) | flg) % 31) === 0;
  }

  private static inflateExactRaw(data: Uint8Array, originalSize: number): Uint8Array | null {
    try {
      const reader: DeflateBitReader = new DeflateBitReader(data, 0);
      const out: Uint8Array = inflateStream(reader, originalSize);
      if (reader.consumedBytes() !== data.length) {
        return null;
      }
      return out;
    } catch (e) {
      return null;
    }
  }

  private static inflateExactZlib(data: Uint8Array, originalSize: number): Uint8Array | null {
    try {
      const cmf: number = data[0] & 0xFF;
      const flg: number = data[1] & 0xFF;
      if ((cmf & 0x0F) !== 8 || (cmf >>> 4) > 7 || (((cmf << 8) | flg) % 31) !== 0) {
        return null;
      }
      if ((flg & 0x20) !== 0) {
        return null; // preset dictionaries are not used by bitchat clients
      }
      const reader: DeflateBitReader = new DeflateBitReader(data, 2);
      const out: Uint8Array = inflateStream(reader, originalSize);
      const trailerAt: number = reader.consumedBytes();
      if (trailerAt + 4 !== data.length) {
        return null;
      }
      const expected: number = ((data[trailerAt] & 0xFF) * 0x1000000) +
        ((data[trailerAt + 1] & 0xFF) << 16) +
        ((data[trailerAt + 2] & 0xFF) << 8) +
        (data[trailerAt + 3] & 0xFF);
      if (adler32(out) !== expected) {
        return null;
      }
      return out;
    } catch (e) {
      return null;
    }
  }
}
