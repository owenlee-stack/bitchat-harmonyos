/**
 * Symmetric state for the Noise_XX_25519_ChaChaPoly_SHA256 handshake.
 *
 * Direct port of the vendored noise-java SymmetricState.java
 * (bitchat-android .../noise/southernstorm/protocol), specialized to
 * SHA-256 and ChaChaPoly: ck/h chaining state, MixKey via the Noise
 * two-output HKDF, EncryptAndHash / DecryptAndHash with the prev_h
 * associated-data snapshot, and Split into the transport cipher pair.
 * The ChaChaPoly cipher state itself lives in ChaCha20Poly1305.ets.
 * Pure ArkTS: no @ohos/@kit imports, host-runnable by the
 * contract-test harness.
 */
import { ChaChaPolyCipher } from './ChaCha20Poly1305';
import { NoisePrimitives } from './NoisePrimitives';
import { ByteUtils } from '../../common/ByteUtils';

/** Sender/receiver cipher pair produced by NoiseSymmetricState.split(). */
export class NoiseCipherStatePair {
  sender: ChaChaPolyCipher;
  receiver: ChaChaPolyCipher;

  constructor(sender: ChaChaPolyCipher, receiver: ChaChaPolyCipher) {
    this.sender = sender;
    this.receiver = receiver;
  }

  swap(): void {
    const temp: ChaChaPolyCipher = this.sender;
    this.sender = this.receiver;
    this.receiver = temp;
  }
}

export class NoiseSymmetricState {
  private static readonly HASH_LENGTH: number = 32;

  private cipher: ChaChaPolyCipher = new ChaChaPolyCipher();
  private ck: Uint8Array = new Uint8Array(NoiseSymmetricState.HASH_LENGTH);
  private h: Uint8Array = new Uint8Array(NoiseSymmetricState.HASH_LENGTH);
  private prevH: Uint8Array = new Uint8Array(NoiseSymmetricState.HASH_LENGTH);

  constructor(protocolName: string) {
    const nameBytes: Uint8Array = ByteUtils.utf8Encode(protocolName);
    if (nameBytes.length <= NoiseSymmetricState.HASH_LENGTH) {
      this.h.set(nameBytes, 0);
    } else {
      this.h.set(ByteUtils.sha256(nameBytes));
    }
    this.ck.set(this.h);
  }

  getMacLength(): number {
    return this.cipher.getMacLength();
  }

  mixKey(data: Uint8Array): void {
    const nextCk: Uint8Array = new Uint8Array(NoiseSymmetricState.HASH_LENGTH);
    const tempKey: Uint8Array = new Uint8Array(32);
    NoisePrimitives.hkdfSha256(this.ck, data, nextCk, tempKey);
    this.ck.set(nextCk);
    this.cipher.initializeKey(tempKey, 0);
  }

  mixHash(data: Uint8Array): void {
    const combined: Uint8Array = new Uint8Array(NoiseSymmetricState.HASH_LENGTH + data.length);
    combined.set(this.h, 0);
    combined.set(data, NoiseSymmetricState.HASH_LENGTH);
    this.h.set(ByteUtils.sha256(combined));
  }

  encryptAndHash(plaintext: Uint8Array): Uint8Array {
    const ad: Uint8Array = new Uint8Array(this.h);
    const ciphertext: Uint8Array = new Uint8Array(plaintext.length + this.cipher.getMacLength());
    const length: number = this.cipher.encryptWithAd(ad, plaintext, 0, ciphertext, 0, plaintext.length);
    const output: Uint8Array = ciphertext.slice(0, length);
    this.mixHash(output);
    return output;
  }

  decryptAndHash(ciphertext: Uint8Array): Uint8Array {
    this.prevH.set(this.h);
    this.mixHash(ciphertext);
    const ad: Uint8Array = new Uint8Array(this.prevH);
    const plaintext: Uint8Array = new Uint8Array(ciphertext.length);
    const length: number = this.cipher.decryptWithAd(ad, ciphertext, 0, plaintext, 0, ciphertext.length);
    return plaintext.slice(0, length);
  }

  split(): NoiseCipherStatePair {
    const k1: Uint8Array = new Uint8Array(32);
    const k2: Uint8Array = new Uint8Array(32);
    NoisePrimitives.hkdfSha256(this.ck, new Uint8Array(0), k1, k2);
    return new NoiseCipherStatePair(this.cipher.fork(k1, 0), this.cipher.fork(k2, 0));
  }

  getHandshakeHash(): Uint8Array {
    return new Uint8Array(this.h);
  }
}
