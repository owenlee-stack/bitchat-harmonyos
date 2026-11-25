/**
 * Pure byte/hex/base64/UTF-8/sha256 utilities for the bitchat protocol kernel.
 * Deliberately free of any @ohos.* import so the whole kernel stays testable
 * in local unit tests and portable across environments.
 */

const HEX_CHARS: string[] = [
  '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'
];

const B64_CHARS: string[] = [
  'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P',
  'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'a', 'b', 'c', 'd', 'e', 'f',
  'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v',
  'w', 'x', 'y', 'z', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '+', '/'
];

const B64URL_CHARS: string[] = [
  'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P',
  'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'a', 'b', 'c', 'd', 'e', 'f',
  'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v',
  'w', 'x', 'y', 'z', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '-', '_'
];

const PAD: string = '=';

function b64ValueOf(ch: string): number {
  const code: number = ch.charCodeAt(0);
  if (code >= 65 && code <= 90) {
    return code - 65;
  }
  if (code >= 97 && code <= 122) {
    return code - 97 + 26;
  }
  if (code >= 48 && code <= 57) {
    return code - 48 + 52;
  }
  if (ch === '+' || ch === '-') {
    return 62;
  }
  if (ch === '/' || ch === '_') {
    return 63;
  }
  return -1;
}

/** Growable big-endian byte writer used by every encoder. */
export class ByteWriter {
  private buf: Uint8Array;
  private pos: number;

  constructor(initialCapacity: number) {
    const cap: number = initialCapacity > 0 ? initialCapacity : 64;
    this.buf = new Uint8Array(cap);
    this.pos = 0;
  }

  get position(): number {
    return this.pos;
  }

  private ensure(extra: number): void {
    if (this.pos + extra <= this.buf.length) {
      return;
    }
    let newCap: number = this.buf.length * 2;
    while (newCap < this.pos + extra) {
      newCap *= 2;
    }
    const grown: Uint8Array = new Uint8Array(newCap);
    grown.set(this.buf.subarray(0, this.pos), 0);
    this.buf = grown;
  }

  putByte(value: number): void {
    this.ensure(1);
    this.buf[this.pos] = value & 0xFF;
    this.pos += 1;
  }

  putBytes(bytes: Uint8Array): void {
    this.ensure(bytes.length);
    this.buf.set(bytes, this.pos);
    this.pos += bytes.length;
  }

  putU16BE(value: number): void {
    this.ensure(2);
    this.buf[this.pos] = (value >>> 8) & 0xFF;
    this.buf[this.pos + 1] = value & 0xFF;
    this.pos += 2;
  }

  putU32BE(value: number): void {
    this.ensure(4);
    this.buf[this.pos] = (value >>> 24) & 0xFF;
    this.buf[this.pos + 1] = (value >>> 16) & 0xFF;
    this.buf[this.pos + 2] = (value >>> 8) & 0xFF;
    this.buf[this.pos + 3] = value & 0xFF;
    this.pos += 4;
  }

  putU64BE(value: number): void {
    this.ensure(8);
    let v: number = value;
    for (let i: number = 7; i >= 0; i--) {
      this.buf[this.pos + i] = v & 0xFF;
      v = Math.floor(v / 256);
    }
    this.pos += 8;
  }

  toUint8Array(): Uint8Array {
    const out: Uint8Array = new Uint8Array(this.pos);
    out.set(this.buf.subarray(0, this.pos), 0);
    return out;
  }
}

/** Sequential big-endian byte reader used by every decoder. */
export class ByteReader {
  private buf: Uint8Array;
  private pos: number;

  constructor(buf: Uint8Array) {
    this.buf = buf;
    this.pos = 0;
  }

  get offset(): number {
    return this.pos;
  }

  hasRemaining(): boolean {
    return this.pos < this.buf.length;
  }

  remaining(): number {
    return this.buf.length - this.pos;
  }

  getByte(): number {
    if (this.pos >= this.buf.length) {
      throw new Error('ByteReader underflow: no byte remaining');
    }
    const v: number = this.buf[this.pos];
    this.pos += 1;
    return v & 0xFF;
  }

  getBytes(count: number): Uint8Array {
    if (!(count >= 0) || count > this.buf.length - this.pos) {
      throw new Error('ByteReader underflow: requested ' + count + ' bytes');
    }
    const out: Uint8Array = this.buf.slice(this.pos, this.pos + count);
    this.pos += count;
    return out;
  }

  getU16BE(): number {
    if (this.buf.length - this.pos < 2) {
      throw new Error('ByteReader underflow: requested 2 bytes');
    }
    const v: number = ((this.buf[this.pos] & 0xFF) << 8) | (this.buf[this.pos + 1] & 0xFF);
    this.pos += 2;
    return v;
  }

  getU32BE(): number {
    if (this.buf.length - this.pos < 4) {
      throw new Error('ByteReader underflow: requested 4 bytes');
    }
    const v: number = ((this.buf[this.pos] & 0xFF) << 24) | ((this.buf[this.pos + 1] & 0xFF) << 16) |
      ((this.buf[this.pos + 2] & 0xFF) << 8) | (this.buf[this.pos + 3] & 0xFF);
    this.pos += 4;
    return v >>> 0;
  }

  getU64BE(): number {
    const raw: Uint8Array = this.getU64Bytes();
    return ByteUtils.u64BytesToNumber(raw);
  }

  /** Exact 8 wire bytes of a u64, preserving values beyond 2^53. */
  getU64Bytes(): Uint8Array {
    if (this.buf.length - this.pos < 8) {
      throw new Error('ByteReader underflow: requested 8 bytes');
    }
    const out: Uint8Array = this.buf.slice(this.pos, this.pos + 8);
    this.pos += 8;
    return out;
  }

  peekByte(at: number): number {
    return this.buf[at] & 0xFF;
  }
}

/** Pure-ArkTS SHA-256 (FIPS 180-4). */
export class Sha256 {
  private static readonly K: number[] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  ];

  private static rotr(x: number, n: number): number {
    return ((x >>> n) | (x << (32 - n))) >>> 0;
  }

  static digest(data: Uint8Array): Uint8Array {
    const h: number[] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    const bitLen: number = data.length * 8;
    const paddedLen: number = (((data.length + 8) >> 6) + 1) << 6;
    const padded: Uint8Array = new Uint8Array(paddedLen);
    padded.set(data, 0);
    padded[data.length] = 0x80;
    // 64-bit big-endian bit length; JS safe-integer range keeps the high word meaningful here.
    const hi: number = Math.floor(bitLen / 0x100000000);
    const lo: number = bitLen >>> 0;
    padded[paddedLen - 8] = (hi >>> 24) & 0xFF;
    padded[paddedLen - 7] = (hi >>> 16) & 0xFF;
    padded[paddedLen - 6] = (hi >>> 8) & 0xFF;
    padded[paddedLen - 5] = hi & 0xFF;
    padded[paddedLen - 4] = (lo >>> 24) & 0xFF;
    padded[paddedLen - 3] = (lo >>> 16) & 0xFF;
    padded[paddedLen - 2] = (lo >>> 8) & 0xFF;
    padded[paddedLen - 1] = lo & 0xFF;

    const w: number[] = new Array<number>(64);
    for (let block: number = 0; block < paddedLen; block += 64) {
      for (let t: number = 0; t < 16; t++) {
        const i: number = block + t * 4;
        w[t] = ((padded[i] << 24) | (padded[i + 1] << 16) | (padded[i + 2] << 8) | padded[i + 3]) >>> 0;
      }
      for (let t: number = 16; t < 64; t++) {
        const s0: number = Sha256.rotr(w[t - 15], 7) ^ Sha256.rotr(w[t - 15], 18) ^ (w[t - 15] >>> 3);
        const s1: number = Sha256.rotr(w[t - 2], 17) ^ Sha256.rotr(w[t - 2], 19) ^ (w[t - 2] >>> 10);
        w[t] = (w[t - 16] + s0 + w[t - 7] + s1) >>> 0;
      }
      let a: number = h[0];
      let b: number = h[1];
      let c: number = h[2];
      let d: number = h[3];
      let e: number = h[4];
      let f: number = h[5];
      let g: number = h[6];
      let hh: number = h[7];
      for (let t: number = 0; t < 64; t++) {
        const S1: number = Sha256.rotr(e, 6) ^ Sha256.rotr(e, 11) ^ Sha256.rotr(e, 25);
        const ch: number = (e & f) ^ (~e & g);
        const temp1: number = (hh + S1 + ch + Sha256.K[t] + w[t]) >>> 0;
        const S0: number = Sha256.rotr(a, 2) ^ Sha256.rotr(a, 13) ^ Sha256.rotr(a, 22);
        const maj: number = (a & b) ^ (a & c) ^ (b & c);
        const temp2: number = (S0 + maj) >>> 0;
        hh = g;
        g = f;
        f = e;
        e = (d + temp1) >>> 0;
        d = c;
        c = b;
        b = a;
        a = (temp1 + temp2) >>> 0;
      }
      h[0] = (h[0] + a) >>> 0;
      h[1] = (h[1] + b) >>> 0;
      h[2] = (h[2] + c) >>> 0;
      h[3] = (h[3] + d) >>> 0;
      h[4] = (h[4] + e) >>> 0;
      h[5] = (h[5] + f) >>> 0;
      h[6] = (h[6] + g) >>> 0;
      h[7] = (h[7] + hh) >>> 0;
    }

    const out: Uint8Array = new Uint8Array(32);
    for (let i: number = 0; i < 8; i++) {
      out[i * 4] = (h[i] >>> 24) & 0xFF;
      out[i * 4 + 1] = (h[i] >>> 16) & 0xFF;
      out[i * 4 + 2] = (h[i] >>> 8) & 0xFF;
      out[i * 4 + 3] = h[i] & 0xFF;
    }
    return out;
  }
}

/** HMAC-SHA256 (RFC 2104). */
export class HmacSha256 {
  static compute(key: Uint8Array, data: Uint8Array): Uint8Array {
    let k: Uint8Array = key;
    if (k.length > 64) {
      k = Sha256.digest(k);
    }
    const ipad: Uint8Array = new Uint8Array(64);
    const opad: Uint8Array = new Uint8Array(64);
    ipad.set(k, 0);
    opad.set(k, 0);
    for (let i: number = 0; i < 64; i++) {
      ipad[i] ^= 0x36;
      opad[i] ^= 0x5c;
    }
    const inner: Uint8Array = ByteUtils.concat(ipad, data);
    const innerHash: Uint8Array = Sha256.digest(inner);
    return Sha256.digest(ByteUtils.concat(opad, innerHash));
  }
}

export class ByteUtils {
  static bytesToHex(bytes: Uint8Array): string {
    let out: string = '';
    for (let i: number = 0; i < bytes.length; i++) {
      const v: number = bytes[i] & 0xFF;
      out += HEX_CHARS[(v >>> 4) & 0x0F];
      out += HEX_CHARS[v & 0x0F];
    }
    return out;
  }

  static hexToBytes(hex: string): Uint8Array {
    const clean: string = hex.length % 2 === 0 ? hex : '0' + hex;
    const out: Uint8Array = new Uint8Array(clean.length / 2);
    for (let i: number = 0; i < out.length; i++) {
      const hi: number = ByteUtils.hexDigitValue(clean.charAt(i * 2));
      const lo: number = ByteUtils.hexDigitValue(clean.charAt(i * 2 + 1));
      if (hi < 0 || lo < 0) {
        return new Uint8Array(0);
      }
      out[i] = (hi << 4) | lo;
    }
    return out;
  }

  private static hexDigitValue(ch: string): number {
    const code: number = ch.charCodeAt(0);
    if (code >= 48 && code <= 57) {
      return code - 48;
    }
    if (code >= 97 && code <= 102) {
      return code - 97 + 10;
    }
    if (code >= 65 && code <= 70) {
      return code - 65 + 10;
    }
    return -1;
  }

  /** Correct UTF-8 encode over the full code-point range. */
  static utf8Encode(text: string): Uint8Array {
    const writer: ByteWriter = new ByteWriter(text.length + 16);
    for (let i: number = 0; i < text.length; i++) {
      let code: number = text.charCodeAt(i);
      if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
        const next: number = text.charCodeAt(i + 1);
        if (next >= 0xDC00 && next <= 0xDFFF) {
          code = ((code - 0xD800) << 10) + (next - 0xDC00) + 0x10000;
          i += 1;
        }
      }
      if (code < 0x80) {
        writer.putByte(code);
      } else if (code < 0x800) {
        writer.putByte(0xC0 | (code >>> 6));
        writer.putByte(0x80 | (code & 0x3F));
      } else if (code < 0x10000) {
        writer.putByte(0xE0 | (code >>> 12));
        writer.putByte(0x80 | ((code >>> 6) & 0x3F));
        writer.putByte(0x80 | (code & 0x3F));
      } else {
        writer.putByte(0xF0 | (code >>> 18));
        writer.putByte(0x80 | ((code >>> 12) & 0x3F));
        writer.putByte(0x80 | ((code >>> 6) & 0x3F));
        writer.putByte(0x80 | (code & 0x3F));
      }
    }
    return writer.toUint8Array();
  }

  /** Correct UTF-8 decode; invalid sequences become U+FFFD. */
  static utf8Decode(bytes: Uint8Array): string {
    let out: string = '';
    let i: number = 0;
    while (i < bytes.length) {
      const b0: number = bytes[i] & 0xFF;
      if (b0 < 0x80) {
        out += String.fromCharCode(b0);
        i += 1;
        continue;
      }
      let cp: number = -1;
      let len: number = 0;
      if ((b0 & 0xE0) === 0xC0) {
        cp = b0 & 0x1F;
        len = 2;
      } else if ((b0 & 0xF0) === 0xE0) {
        cp = b0 & 0x0F;
        len = 3;
      } else if ((b0 & 0xF8) === 0xF0) {
        cp = b0 & 0x07;
        len = 4;
      } else {
        out += String.fromCharCode(0xFFFD);
        i += 1;
        continue;
      }
      if (i + len > bytes.length) {
        out += String.fromCharCode(0xFFFD);
        i += 1;
        continue;
      }
      let valid: boolean = true;
      for (let j: number = 1; j < len; j++) {
        const bj: number = bytes[i + j] & 0xFF;
        if ((bj & 0xC0) !== 0x80) {
          valid = false;
          break;
        }
        cp = (cp << 6) | (bj & 0x3F);
      }
      if (!valid || (len === 2 && cp < 0x80) || (len === 3 && cp < 0x800) ||
        (len === 4 && cp < 0x10000) || cp > 0x10FFFF) {
        out += String.fromCharCode(0xFFFD);
        i += 1;
        continue;
      }
      if (cp < 0x10000) {
        out += String.fromCharCode(cp);
      } else {
        const v: number = cp - 0x10000;
        out += String.fromCharCode(0xD800 + (v >>> 10), 0xDC00 + (v & 0x3FF));
      }
      i += len;
    }
    return out;
  }

  static base64Encode(bytes: Uint8Array): string {
    return ByteUtils.base64EncodeWith(bytes, B64_CHARS, true);
  }

  static base64UrlEncode(bytes: Uint8Array): string {
    return ByteUtils.base64EncodeWith(bytes, B64URL_CHARS, false);
  }

  private static base64EncodeWith(bytes: Uint8Array, alphabet: string[], addPad: boolean): string {
    let out: string = '';
    let i: number = 0;
    while (i + 2 < bytes.length) {
      const n: number = ((bytes[i] & 0xFF) << 16) | ((bytes[i + 1] & 0xFF) << 8) | (bytes[i + 2] & 0xFF);
      out += alphabet[(n >>> 18) & 0x3F];
      out += alphabet[(n >>> 12) & 0x3F];
      out += alphabet[(n >>> 6) & 0x3F];
      out += alphabet[n & 0x3F];
      i += 3;
    }
    const rem: number = bytes.length - i;
    if (rem === 1) {
      const n: number = (bytes[i] & 0xFF) << 16;
      out += alphabet[(n >>> 18) & 0x3F];
      out += alphabet[(n >>> 12) & 0x3F];
      if (addPad) {
        out += PAD + PAD;
      }
    } else if (rem === 2) {
      const n: number = ((bytes[i] & 0xFF) << 16) | ((bytes[i + 1] & 0xFF) << 8);
      out += alphabet[(n >>> 18) & 0x3F];
      out += alphabet[(n >>> 12) & 0x3F];
      out += alphabet[(n >>> 6) & 0x3F];
      if (addPad) {
        out += PAD;
      }
    }
    return out;
  }

  /** Decodes both standard and URL-safe alphabets, with or without padding. */
  static base64Decode(text: string): Uint8Array {
    let clean: string = '';
    for (let i: number = 0; i < text.length; i++) {
      const ch: string = text.charAt(i);
      if (ch !== PAD && ch !== '\n' && ch !== '\r') {
        clean += ch;
      }
    }
    const out: Uint8Array = new Uint8Array(Math.floor(clean.length * 3 / 4));
    let pos: number = 0;
    let acc: number = 0;
    let bits: number = 0;
    for (let i: number = 0; i < clean.length; i++) {
      const v: number = b64ValueOf(clean.charAt(i));
      if (v < 0) {
        return new Uint8Array(0);
      }
      acc = (acc << 6) | v;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out[pos] = (acc >>> bits) & 0xFF;
        pos += 1;
      }
    }
    return out.slice(0, pos);
  }

  /**
   * Big-endian u64 bytes to number. Values beyond 2^53 lose precision in the
   * returned double; callers that must preserve them keep the raw bytes
   * (BitchatPacket.timestampRaw / BitchatMessage.timestampRaw).
   */
  static u64BytesToNumber(bytes: Uint8Array): number {
    let v: number = 0;
    const n: number = Math.min(bytes.length, 8);
    for (let i: number = 0; i < n; i++) {
      v = v * 256 + (bytes[i] & 0xFF);
    }
    return v;
  }

  static concat(...arrays: Uint8Array[]): Uint8Array {
    let total: number = 0;
    for (let i: number = 0; i < arrays.length; i++) {
      total += arrays[i].length;
    }
    const out: Uint8Array = new Uint8Array(total);
    let pos: number = 0;
    for (let i: number = 0; i < arrays.length; i++) {
      out.set(arrays[i], pos);
      pos += arrays[i].length;
    }
    return out;
  }

  static equals(a: Uint8Array, b: Uint8Array): boolean {
    if (a.length !== b.length) {
      return false;
    }
    let diff: number = 0;
    for (let i: number = 0; i < a.length; i++) {
      diff |= (a[i] ^ b[i]);
    }
    return diff === 0;
  }

  static sha256(data: Uint8Array): Uint8Array {
    return Sha256.digest(data);
  }

  static sha256Hex(data: Uint8Array): string {
    return ByteUtils.bytesToHex(Sha256.digest(data));
  }
}
