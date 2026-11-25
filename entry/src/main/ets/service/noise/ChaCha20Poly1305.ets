/**
 * ChaCha20-Poly1305 AEAD ("ChaChaPoly") for the Noise protocol.
 *
 * ChaChaCore is a direct port of the vendored noise-java ChaChaCore.java
 * (32-bit quarter-round arithmetic). Poly1305 is implemented with BigInt so
 * the 130-bit accumulator is exact. The AEAD framing -- per-message 64-bit
 * nonce counter, Poly1305 key derivation from the first ChaCha20 block,
 * ciphertext||tag layout, and AD/length padding -- mirrors
 * ChaChaPolyCipherState.java byte-for-byte. Pure ArkTS: no @ohos/@kit
 * imports, host-runnable by the contract-test harness.
 */

/** ChaCha20 core hash transformation (RFC 7539). */
export class ChaChaCore {
  static hash(output: number[], input: number[]): void {
    for (let index: number = 0; index < 16; ++index) {
      output[index] = input[index];
    }
    for (let index: number = 0; index < 20; index += 2) {
      ChaChaCore.quarterRound(output, 0, 4, 8, 12);
      ChaChaCore.quarterRound(output, 1, 5, 9, 13);
      ChaChaCore.quarterRound(output, 2, 6, 10, 14);
      ChaChaCore.quarterRound(output, 3, 7, 11, 15);
      ChaChaCore.quarterRound(output, 0, 5, 10, 15);
      ChaChaCore.quarterRound(output, 1, 6, 11, 12);
      ChaChaCore.quarterRound(output, 2, 7, 8, 13);
      ChaChaCore.quarterRound(output, 3, 4, 9, 14);
    }
    for (let index: number = 0; index < 16; ++index) {
      output[index] = (output[index] + input[index]) | 0;
    }
  }

  static initKey256(output: number[], key: Uint8Array, offset: number): void {
    output[0] = ChaChaCore.char4('e', 'x', 'p', 'a');
    output[1] = ChaChaCore.char4('n', 'd', ' ', '3');
    output[2] = ChaChaCore.char4('2', '-', 'b', 'y');
    output[3] = ChaChaCore.char4('t', 'e', ' ', 'k');
    output[4] = ChaChaCore.fromLittleEndian(key, offset);
    output[5] = ChaChaCore.fromLittleEndian(key, offset + 4);
    output[6] = ChaChaCore.fromLittleEndian(key, offset + 8);
    output[7] = ChaChaCore.fromLittleEndian(key, offset + 12);
    output[8] = ChaChaCore.fromLittleEndian(key, offset + 16);
    output[9] = ChaChaCore.fromLittleEndian(key, offset + 20);
    output[10] = ChaChaCore.fromLittleEndian(key, offset + 24);
    output[11] = ChaChaCore.fromLittleEndian(key, offset + 28);
    output[12] = 0;
    output[13] = 0;
    output[14] = 0;
    output[15] = 0;
  }

  static initIV(output: number[], iv: number): void {
    output[12] = 0;
    output[13] = 0;
    output[14] = iv | 0;
    output[15] = Math.floor(iv / 0x100000000) | 0;
  }

  private static char4(c1: string, c2: string, c3: string, c4: string): number {
    return (c1.charCodeAt(0) & 0xFF) |
      ((c2.charCodeAt(0) & 0xFF) << 8) |
      ((c3.charCodeAt(0) & 0xFF) << 16) |
      ((c4.charCodeAt(0) & 0xFF) << 24);
  }

  private static fromLittleEndian(key: Uint8Array, offset: number): number {
    return (key[offset] & 0xFF) |
      ((key[offset + 1] & 0xFF) << 8) |
      ((key[offset + 2] & 0xFF) << 16) |
      ((key[offset + 3] & 0xFF) << 24);
  }

  private static quarterRound(v: number[], a: number, b: number, c: number, d: number): void {
    v[a] = (v[a] + v[b]) | 0;
    let t: number = v[d] ^ v[a];
    v[d] = (t << 16) | (t >>> 16);
    v[c] = (v[c] + v[d]) | 0;
    t = v[b] ^ v[c];
    v[b] = (t << 12) | (t >>> 20);
    v[a] = (v[a] + v[b]) | 0;
    t = v[d] ^ v[a];
    v[d] = (t << 8) | (t >>> 24);
    v[c] = (v[c] + v[d]) | 0;
    t = v[b] ^ v[c];
    v[b] = (t << 7) | (t >>> 25);
  }
}

/** Poly1305 message authenticator (RFC 7539), BigInt-exact. */
export class Poly1305 {
  private static readonly P: bigint = (1n << 130n) - 5n;
  private r: bigint = 0n;
  private s: bigint = 0n;
  private h: bigint = 0n;
  private block: Uint8Array = new Uint8Array(16);
  private posn: number = 0;

  reset(key: Uint8Array, offset: number): void {
    let r: bigint = 0n;
    for (let i: number = 15; i >= 0; i--) {
      r = (r << 8n) | BigInt(key[offset + i] & 0xFF);
    }
    this.r = r & 0x0ffffffc0ffffffc0ffffffc0fffffffn;
    let s: bigint = 0n;
    for (let i: number = 15; i >= 0; i--) {
      s = (s << 8n) | BigInt(key[offset + 16 + i] & 0xFF);
    }
    this.s = s;
    this.h = 0n;
    this.posn = 0;
  }

  update(data: Uint8Array, offset: number, length: number): void {
    while (length > 0) {
      if (this.posn === 0 && length >= 16) {
        this.processChunk(data, offset, false);
        offset += 16;
        length -= 16;
      } else {
        let temp: number = 16 - this.posn;
        if (temp > length) {
          temp = length;
        }
        this.block.set(data.subarray(offset, offset + temp), this.posn);
        offset += temp;
        length -= temp;
        this.posn += temp;
        if (this.posn >= 16) {
          this.processChunk(this.block, 0, false);
          this.posn = 0;
        }
      }
    }
  }

  pad(): void {
    if (this.posn !== 0) {
      for (let i: number = this.posn; i < 16; i++) {
        this.block[i] = 0;
      }
      this.processChunk(this.block, 0, false);
      this.posn = 0;
    }
  }

  finish(token: Uint8Array, offset: number): void {
    if (this.posn !== 0) {
      this.block[this.posn] = 1;
      for (let i: number = this.posn + 1; i < 16; i++) {
        this.block[i] = 0;
      }
      this.processChunk(this.block, 0, true);
      this.posn = 0;
    }
    let tag: bigint = (this.h + this.s) & ((1n << 128n) - 1n);
    for (let i: number = 0; i < 16; i++) {
      token[offset + i] = Number(tag & 0xFFn);
      tag >>= 8n;
    }
  }

  destroy(): void {
    this.r = 0n;
    this.s = 0n;
    this.h = 0n;
    this.block.fill(0);
    this.posn = 0;
  }

  private processChunk(chunk: Uint8Array, offset: number, finalChunk: boolean): void {
    let n: bigint = 0n;
    for (let i: number = 15; i >= 0; i--) {
      n = (n << 8n) | BigInt(chunk[offset + i] & 0xFF);
    }
    if (!finalChunk) {
      n += 1n << 128n;
    }
    this.h = ((this.h + n) * this.r) % Poly1305.P;
  }
}

/** ChaChaPoly cipher state for Noise (mirrors ChaChaPolyCipherState.java). */
export class ChaChaPolyCipher {
  private poly: Poly1305 = new Poly1305();
  private input: number[] = ChaChaPolyCipher.zeroWords();
  private output: number[] = ChaChaPolyCipher.zeroWords();
  private polyKey: Uint8Array = new Uint8Array(32);
  private n: number = 0;
  private haskey: boolean = false;

  getCipherName(): string {
    return 'ChaChaPoly';
  }

  getKeyLength(): number {
    return 32;
  }

  getMacLength(): number {
    return this.haskey ? 16 : 0;
  }

  hasKey(): boolean {
    return this.haskey;
  }

  initializeKey(key: Uint8Array, offset: number): void {
    ChaChaCore.initKey256(this.input, key, offset);
    this.n = 0;
    this.haskey = true;
  }

  setNonce(nonce: number): void {
    this.n = nonce;
  }

  fork(key: Uint8Array, offset: number): ChaChaPolyCipher {
    const cipher: ChaChaPolyCipher = new ChaChaPolyCipher();
    cipher.initializeKey(key, offset);
    return cipher;
  }

  encryptWithAd(ad: Uint8Array | null, plaintext: Uint8Array, plaintextOffset: number,
    ciphertext: Uint8Array, ciphertextOffset: number, length: number): number {
    if (ciphertextOffset < 0 || ciphertextOffset > ciphertext.length) {
      throw new Error('Invalid ciphertext offset');
    }
    if (length < 0 || plaintextOffset < 0 || plaintextOffset > plaintext.length ||
      length > plaintext.length || (plaintext.length - plaintextOffset) < length) {
      throw new Error('Invalid plaintext arguments');
    }
    const space: number = ciphertext.length - ciphertextOffset;
    if (!this.haskey) {
      if (length > space) {
        throw new Error('Short buffer');
      }
      if (plaintext !== ciphertext || plaintextOffset !== ciphertextOffset) {
        ciphertext.set(plaintext.subarray(plaintextOffset, plaintextOffset + length), ciphertextOffset);
      }
      return length;
    }
    if (space < 16 || length > (space - 16)) {
      throw new Error('Short buffer');
    }
    this.setup(ad);
    this.encrypt(plaintext, plaintextOffset, ciphertext, ciphertextOffset, length);
    this.poly.update(ciphertext, ciphertextOffset, length);
    this.finish(ad, length);
    ciphertext.set(this.polyKey.subarray(0, 16), ciphertextOffset + length);
    return length + 16;
  }

  decryptWithAd(ad: Uint8Array | null, ciphertext: Uint8Array, ciphertextOffset: number,
    plaintext: Uint8Array, plaintextOffset: number, length: number): number {
    if (ciphertextOffset < 0 || ciphertextOffset > ciphertext.length) {
      throw new Error('Invalid ciphertext offset');
    }
    const cipherSpace: number = ciphertext.length - ciphertextOffset;
    if (length > cipherSpace) {
      throw new Error('Short buffer');
    }
    if (length < 0 || plaintextOffset < 0 || plaintextOffset > plaintext.length ||
      length > ciphertext.length || (ciphertext.length - ciphertextOffset) < length) {
      throw new Error('Invalid ciphertext arguments');
    }
    const space: number = plaintext.length - plaintextOffset;
    if (!this.haskey) {
      if (length > space) {
        throw new Error('Short buffer');
      }
      if (plaintext !== ciphertext || plaintextOffset !== ciphertextOffset) {
        plaintext.set(ciphertext.subarray(ciphertextOffset, ciphertextOffset + length), plaintextOffset);
      }
      return length;
    }
    if (length < 16) {
      throw new Error('Bad tag');
    }
    const dataLen: number = length - 16;
    if (dataLen > space) {
      throw new Error('Short buffer');
    }
    this.setup(ad);
    this.poly.update(ciphertext, ciphertextOffset, dataLen);
    this.finish(ad, dataLen);
    let temp: number = 0;
    for (let index: number = 0; index < 16; ++index) {
      temp |= this.polyKey[index] ^ ciphertext[ciphertextOffset + dataLen + index];
    }
    if (temp !== 0) {
      throw new Error('Bad tag');
    }
    this.encrypt(ciphertext, ciphertextOffset, plaintext, plaintextOffset, dataLen);
    return dataLen;
  }

  destroy(): void {
    this.poly.destroy();
    for (let i: number = 0; i < 16; i++) {
      this.input[i] = 0;
      this.output[i] = 0;
    }
    this.polyKey.fill(0);
    this.n = 0;
    this.haskey = false;
  }

  private setup(ad: Uint8Array | null): void {
    if (this.n < 0) {
      throw new Error('Nonce has wrapped around');
    }
    ChaChaCore.initIV(this.input, this.n);
    this.n += 1;
    ChaChaCore.hash(this.output, this.input);
    this.polyKey.fill(0);
    ChaChaPolyCipher.xorBlock(this.polyKey, 0, this.polyKey, 0, 32, this.output);
    this.poly.reset(this.polyKey, 0);
    if (ad !== null) {
      this.poly.update(ad, 0, ad.length);
      this.poly.pad();
    }
    this.input[12] = (this.input[12] + 1) | 0;
    if (this.input[12] === 0) {
      this.input[13] = (this.input[13] + 1) | 0;
    }
  }

  private finish(ad: Uint8Array | null, length: number): void {
    this.poly.pad();
    ChaChaPolyCipher.putLittleEndian64(this.polyKey, 0, ad !== null ? ad.length : 0);
    ChaChaPolyCipher.putLittleEndian64(this.polyKey, 8, length);
    this.poly.update(this.polyKey, 0, 16);
    this.poly.finish(this.polyKey, 0);
  }

  private encrypt(plaintext: Uint8Array, plaintextOffset: number,
    ciphertext: Uint8Array, ciphertextOffset: number, length: number): void {
    while (length > 0) {
      let tempLen: number = 64;
      if (tempLen > length) {
        tempLen = length;
      }
      ChaChaCore.hash(this.output, this.input);
      ChaChaPolyCipher.xorBlock(plaintext, plaintextOffset, ciphertext, ciphertextOffset, tempLen, this.output);
      this.input[12] = (this.input[12] + 1) | 0;
      if (this.input[12] === 0) {
        this.input[13] = (this.input[13] + 1) | 0;
      }
      plaintextOffset += tempLen;
      ciphertextOffset += tempLen;
      length -= tempLen;
    }
  }

  private static xorBlock(input: Uint8Array, inputOffset: number, output: Uint8Array,
    outputOffset: number, length: number, block: number[]): void {
    let posn: number = 0;
    let value: number = 0;
    while (length >= 4) {
      value = block[posn];
      posn += 1;
      output[outputOffset] = input[inputOffset] ^ value;
      output[outputOffset + 1] = input[inputOffset + 1] ^ (value >>> 8);
      output[outputOffset + 2] = input[inputOffset + 2] ^ (value >>> 16);
      output[outputOffset + 3] = input[inputOffset + 3] ^ (value >>> 24);
      inputOffset += 4;
      outputOffset += 4;
      length -= 4;
    }
    if (length === 3) {
      value = block[posn];
      output[outputOffset] = input[inputOffset] ^ value;
      output[outputOffset + 1] = input[inputOffset + 1] ^ (value >>> 8);
      output[outputOffset + 2] = input[inputOffset + 2] ^ (value >>> 16);
    } else if (length === 2) {
      value = block[posn];
      output[outputOffset] = input[inputOffset] ^ value;
      output[outputOffset + 1] = input[inputOffset + 1] ^ (value >>> 8);
    } else if (length === 1) {
      value = block[posn];
      output[outputOffset] = input[inputOffset] ^ value;
    }
  }

  private static putLittleEndian64(output: Uint8Array, offset: number, value: number): void {
    output[offset] = value & 0xFF;
    output[offset + 1] = (value / 0x100) & 0xFF;
    output[offset + 2] = (value / 0x10000) & 0xFF;
    output[offset + 3] = (value / 0x1000000) & 0xFF;
    output[offset + 4] = (value / 0x100000000) & 0xFF;
    output[offset + 5] = (value / 0x10000000000) & 0xFF;
    output[offset + 6] = (value / 0x1000000000000) & 0xFF;
    output[offset + 7] = (value / 0x100000000000000) & 0xFF;
  }

  private static zeroWords(): number[] {
    const words: number[] = [];
    for (let i: number = 0; i < 16; i++) {
      words.push(0);
    }
    return words;
  }
}
