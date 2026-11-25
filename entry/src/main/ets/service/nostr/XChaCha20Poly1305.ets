/**
 * XChaCha20-Poly1305 AEAD (draft-irtf-cfrg-xchacha), Tink-compatible.
 *
 * bitchat-android seals NIP-44 conversations with Tink's
 * XChaCha20Poly1305: a 24-byte random nonce, HChaCha20 subkey
 * derivation from the first 16 nonce bytes, then RFC 8439
 * ChaCha20-Poly1305 with the subkey and the remaining 8 nonce bytes
 * (prefixed with 4 NUL bytes). The combined layout is
 * nonce(24) || ciphertext || tag(16). The canonical draft-irtf test
 * vectors (HChaCha20 subkey, AEAD ciphertext/tag) are enforced by
 * NostrContractTests. Pure ArkTS: no @ohos/@kit imports, host-runnable
 * by the contract-test harness.
 */
import { ChaChaCore, Poly1305 } from '../noise/ChaCha20Poly1305';

export class XChaCha20Poly1305 {
  static readonly KEY_SIZE: number = 32;
  static readonly NONCE_SIZE: number = 24;
  static readonly TAG_SIZE: number = 16;

  /**
   * Encrypt + authenticate. Returns the Tink combined layout
   * nonce24 || ciphertext || tag16.
   */
  static seal(key: Uint8Array, nonce: Uint8Array, plaintext: Uint8Array,
    associatedData: Uint8Array | null): Uint8Array {
    if (key.length !== XChaCha20Poly1305.KEY_SIZE) {
      throw new Error('Key must be 32 bytes');
    }
    if (nonce.length !== XChaCha20Poly1305.NONCE_SIZE) {
      throw new Error('Nonce must be 24 bytes');
    }
    const out: Uint8Array = new Uint8Array(
      XChaCha20Poly1305.NONCE_SIZE + plaintext.length + XChaCha20Poly1305.TAG_SIZE);
    out.set(nonce, 0);
    const subKey: Uint8Array = XChaCha20Poly1305.hChaCha20(key, nonce.subarray(0, 16));
    const input: number[] = XChaCha20Poly1305.zeroWords();
    const output: number[] = XChaCha20Poly1305.zeroWords();
    XChaCha20Poly1305.initStreamState(input, subKey, nonce);
    // Block 0 keystream -> one-time Poly1305 key.
    ChaChaCore.hash(output, input);
    const polyKey: Uint8Array = new Uint8Array(32);
    for (let i: number = 0; i < 8; i++) {
      XChaCha20Poly1305.putWordLE(polyKey, i * 4, output[i]);
    }
    XChaCha20Poly1305.incrementCounter(input);
    // Encryption starts at block counter 1.
    let remaining: number = plaintext.length;
    let ptOffset: number = 0;
    let ctOffset: number = XChaCha20Poly1305.NONCE_SIZE;
    while (remaining > 0) {
      ChaChaCore.hash(output, input);
      const chunk: number = remaining > 64 ? 64 : remaining;
      for (let i: number = 0; i < chunk; i++) {
        const word: number = output[i >>> 2];
        out[ctOffset + i] = plaintext[ptOffset + i] ^ ((word >>> ((i & 3) * 8)) & 0xFF);
      }
      XChaCha20Poly1305.incrementCounter(input);
      ptOffset += chunk;
      ctOffset += chunk;
      remaining -= chunk;
    }
    const poly: Poly1305 = new Poly1305();
    poly.reset(polyKey, 0);
    XChaCha20Poly1305.macInput(poly, out, XChaCha20Poly1305.NONCE_SIZE,
      plaintext.length, associatedData);
    poly.finish(out, XChaCha20Poly1305.NONCE_SIZE + plaintext.length);
    return out;
  }

  /**
   * Verify + decrypt a combined nonce24 || ciphertext || tag16 buffer.
   * Throws on short input, tag mismatch, or invalid arguments.
   */
  static open(key: Uint8Array, combined: Uint8Array,
    associatedData: Uint8Array | null): Uint8Array {
    if (key.length !== XChaCha20Poly1305.KEY_SIZE) {
      throw new Error('Key must be 32 bytes');
    }
    if (combined.length < XChaCha20Poly1305.NONCE_SIZE + XChaCha20Poly1305.TAG_SIZE) {
      throw new Error('Ciphertext too short');
    }
    const nonce: Uint8Array = combined.subarray(0, XChaCha20Poly1305.NONCE_SIZE);
    const ctLength: number =
      combined.length - XChaCha20Poly1305.NONCE_SIZE - XChaCha20Poly1305.TAG_SIZE;
    const subKey: Uint8Array = XChaCha20Poly1305.hChaCha20(key, nonce.subarray(0, 16));
    const input: number[] = XChaCha20Poly1305.zeroWords();
    const output: number[] = XChaCha20Poly1305.zeroWords();
    XChaCha20Poly1305.initStreamState(input, subKey, nonce);
    ChaChaCore.hash(output, input);
    const polyKey: Uint8Array = new Uint8Array(32);
    for (let i: number = 0; i < 8; i++) {
      XChaCha20Poly1305.putWordLE(polyKey, i * 4, output[i]);
    }
    const poly: Poly1305 = new Poly1305();
    poly.reset(polyKey, 0);
    XChaCha20Poly1305.macInput(poly, combined, XChaCha20Poly1305.NONCE_SIZE,
      ctLength, associatedData);
    const expected: Uint8Array = new Uint8Array(XChaCha20Poly1305.TAG_SIZE);
    poly.finish(expected, 0);
    const tagOffset: number = XChaCha20Poly1305.NONCE_SIZE + ctLength;
    let diff: number = 0;
    for (let i: number = 0; i < XChaCha20Poly1305.TAG_SIZE; i++) {
      diff |= expected[i] ^ combined[tagOffset + i];
    }
    if (diff !== 0) {
      throw new Error('Bad tag');
    }
    XChaCha20Poly1305.incrementCounter(input);
    const plaintext: Uint8Array = new Uint8Array(ctLength);
    let remaining: number = ctLength;
    let ctOffset: number = XChaCha20Poly1305.NONCE_SIZE;
    let ptOffset: number = 0;
    while (remaining > 0) {
      ChaChaCore.hash(output, input);
      const chunk: number = remaining > 64 ? 64 : remaining;
      for (let i: number = 0; i < chunk; i++) {
        const word: number = output[i >>> 2];
        plaintext[ptOffset + i] = combined[ctOffset + i] ^ ((word >>> ((i & 3) * 8)) & 0xFF);
      }
      XChaCha20Poly1305.incrementCounter(input);
      ctOffset += chunk;
      ptOffset += chunk;
      remaining -= chunk;
    }
    return plaintext;
  }

  /**
   * HChaCha20: subkey derivation from the key and the first 16 bytes of
   * the extended nonce (first and last state rows, little-endian, no
   * feed-forward). Exposed for the draft-irtf golden vector.
   */
  static hChaCha20(key: Uint8Array, nonce16: Uint8Array): Uint8Array {
    if (key.length !== XChaCha20Poly1305.KEY_SIZE) {
      throw new Error('Key must be 32 bytes');
    }
    if (nonce16.length !== 16) {
      throw new Error('HChaCha20 nonce must be 16 bytes');
    }
    const input: number[] = XChaCha20Poly1305.zeroWords();
    const output: number[] = XChaCha20Poly1305.zeroWords();
    ChaChaCore.initKey256(input, key, 0);
    input[12] = XChaCha20Poly1305.wordLE(nonce16, 0);
    input[13] = XChaCha20Poly1305.wordLE(nonce16, 4);
    input[14] = XChaCha20Poly1305.wordLE(nonce16, 8);
    input[15] = XChaCha20Poly1305.wordLE(nonce16, 12);
    // ChaChaCore.hash adds the input state at the end (feed-forward);
    // subtracting it back yields the raw post-rounds state.
    ChaChaCore.hash(output, input);
    const out: Uint8Array = new Uint8Array(32);
    XChaCha20Poly1305.putWordLE(out, 0, (output[0] - input[0]) | 0);
    XChaCha20Poly1305.putWordLE(out, 4, (output[1] - input[1]) | 0);
    XChaCha20Poly1305.putWordLE(out, 8, (output[2] - input[2]) | 0);
    XChaCha20Poly1305.putWordLE(out, 12, (output[3] - input[3]) | 0);
    XChaCha20Poly1305.putWordLE(out, 16, (output[12] - input[12]) | 0);
    XChaCha20Poly1305.putWordLE(out, 20, (output[13] - input[13]) | 0);
    XChaCha20Poly1305.putWordLE(out, 24, (output[14] - input[14]) | 0);
    XChaCha20Poly1305.putWordLE(out, 28, (output[15] - input[15]) | 0);
    return out;
  }

  /** Poly1305 input: ad || pad16 || ct || pad16 || u64le(adLen) || u64le(ctLen). */
  private static macInput(poly: Poly1305, ct: Uint8Array, ctOffset: number,
    ctLength: number, associatedData: Uint8Array | null): void {
    if (associatedData !== null && associatedData.length > 0) {
      poly.update(associatedData, 0, associatedData.length);
      poly.pad();
    }
    poly.update(ct, ctOffset, ctLength);
    poly.pad();
    const lens: Uint8Array = new Uint8Array(16);
    let v: number = associatedData === null ? 0 : associatedData.length;
    for (let i: number = 0; i < 8; i++) {
      lens[i] = v & 0xFF;
      v = Math.floor(v / 256);
    }
    v = ctLength;
    for (let i: number = 8; i < 16; i++) {
      lens[i] = v & 0xFF;
      v = Math.floor(v / 256);
    }
    poly.update(lens, 0, 16);
  }

  /** RFC 8439 stream state: subkey + 12-byte nonce = 4 NUL bytes || nonce[16:24]. */
  private static initStreamState(input: number[], subKey: Uint8Array, nonce: Uint8Array): void {
    ChaChaCore.initKey256(input, subKey, 0);
    input[12] = 0;
    input[13] = 0;
    input[14] = XChaCha20Poly1305.wordLE(nonce, 16);
    input[15] = XChaCha20Poly1305.wordLE(nonce, 20);
  }

  private static incrementCounter(input: number[]): void {
    input[12] = (input[12] + 1) | 0;
    if (input[12] === 0) {
      input[13] = (input[13] + 1) | 0;
    }
  }

  private static wordLE(bytes: Uint8Array, offset: number): number {
    return (bytes[offset] & 0xFF) |
      ((bytes[offset + 1] & 0xFF) << 8) |
      ((bytes[offset + 2] & 0xFF) << 16) |
      ((bytes[offset + 3] & 0xFF) << 24);
  }

  private static putWordLE(out: Uint8Array, offset: number, word: number): void {
    out[offset] = word & 0xFF;
    out[offset + 1] = (word >>> 8) & 0xFF;
    out[offset + 2] = (word >>> 16) & 0xFF;
    out[offset + 3] = (word >>> 24) & 0xFF;
  }

  private static zeroWords(): number[] {
    const words: number[] = [];
    for (let i: number = 0; i < 16; i++) {
      words.push(0);
    }
    return words;
  }
}
