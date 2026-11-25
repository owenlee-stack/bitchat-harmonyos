/**
 * Noise_XX_25519_ChaChaPoly_SHA256 handshake state machine.
 *
 * Direct port of the vendored noise-java HandshakeState.java
 * (bitchat-android .../noise/southernstorm/protocol) specialized to the
 * single XX pattern bitchat uses: -> e | <- e, ee, s, es | -> s, se.
 * Actions, error semantics (any failure flips the action to FAILED),
 * fixed-ephemeral vector-test hooks, split() role swap and handshake
 * hash all mirror noise-java. Ephemeral key generation is injectable
 * so the device stack can back it with cryptoFramework while the
 * contract harness runs fully deterministic vectors.
 * Pure ArkTS: no @ohos/@kit imports, host-runnable by the
 * contract-test harness.
 */
import { Curve25519 } from './Curve25519';
import { NoiseCipherStatePair, NoiseSymmetricState } from './NoiseSymmetricState';

export enum NoiseHandshakeRole {
  INITIATOR = 1,
  RESPONDER = 2
}

export enum NoiseHandshakeAction {
  NO_ACTION = 0,
  WRITE_MESSAGE = 1,
  READ_MESSAGE = 2,
  FAILED = 3,
  SPLIT = 4,
  COMPLETE = 5
}

const PATTERN_S: number = 1;
const PATTERN_E: number = 2;
const PATTERN_EE: number = 3;
const PATTERN_ES: number = 4;
const PATTERN_SE: number = 5;
const PATTERN_FLIP_DIR: number = 255;

/** X25519 key holder (mirrors Curve25519DHState.java). */
export class NoiseXxDHKey {
  publicKey: Uint8Array = new Uint8Array(32);
  private priv: Uint8Array = new Uint8Array(32);
  private hasPriv: boolean = false;
  private hasPub: boolean = false;

  setPrivateKey(key: Uint8Array): void {
    if (key.length < 32) {
      throw new Error('Private key must be at least 32 bytes');
    }
    this.priv.set(key.subarray(0, 32), 0);
    Curve25519.eval(this.publicKey, 0, this.priv, null);
    this.hasPriv = true;
    this.hasPub = true;
  }

  setPublicKey(key: Uint8Array): void {
    if (key.length < 32) {
      throw new Error('Public key must be at least 32 bytes');
    }
    this.publicKey.set(key.subarray(0, 32), 0);
    this.priv.fill(0);
    this.hasPriv = false;
    this.hasPub = true;
  }

  getPrivateKey(): Uint8Array {
    return new Uint8Array(this.priv);
  }

  hasPublicKey(): boolean {
    return this.hasPub;
  }

  hasPrivateKey(): boolean {
    return this.hasPriv;
  }

  isNullPublicKey(): boolean {
    if (!this.hasPub) {
      return false;
    }
    let acc: number = 0;
    for (let i: number = 0; i < 32; i++) {
      acc |= this.publicKey[i];
    }
    return acc === 0;
  }

  generateKeyPair(generatePrivateKey: () => Uint8Array): void {
    const key: Uint8Array = generatePrivateKey();
    if (key.length < 32) {
      throw new Error('Ephemeral key source must produce at least 32 bytes');
    }
    this.priv.set(key.subarray(0, 32), 0);
    Curve25519.eval(this.publicKey, 0, this.priv, null);
    this.hasPriv = true;
    this.hasPub = true;
  }

  copyFrom(other: NoiseXxDHKey): void {
    if (other === this) {
      return;
    }
    this.priv.set(other.priv);
    this.publicKey.set(other.publicKey);
    this.hasPriv = other.hasPriv;
    this.hasPub = other.hasPub;
  }
}

export class NoiseXXHandshake {
  static readonly PROTOCOL_NAME: string = 'Noise_XX_25519_ChaChaPoly_SHA256';
  private static readonly XX_PATTERN: number[] = [
    PATTERN_E, PATTERN_FLIP_DIR,
    PATTERN_E, PATTERN_EE, PATTERN_S, PATTERN_ES, PATTERN_FLIP_DIR,
    PATTERN_S, PATTERN_SE
  ];

  private symmetric: NoiseSymmetricState = new NoiseSymmetricState(NoiseXXHandshake.PROTOCOL_NAME);
  private readonly role: NoiseHandshakeRole;
  private action: NoiseHandshakeAction = NoiseHandshakeAction.NO_ACTION;
  private prologue: Uint8Array | null = null;
  private localKeyPair: NoiseXxDHKey = new NoiseXxDHKey();
  private remotePublicKey: NoiseXxDHKey = new NoiseXxDHKey();
  private localEphemeral: NoiseXxDHKey = new NoiseXxDHKey();
  private remoteEphemeral: NoiseXxDHKey = new NoiseXxDHKey();
  private fixedEphemeral: NoiseXxDHKey | null = null;
  private patternIndex: number = 0;
  private readonly generateEphemeralPrivateKey: (() => Uint8Array) | null;

  constructor(role: NoiseHandshakeRole, generateEphemeralPrivateKey: (() => Uint8Array) | null) {
    this.role = role;
    this.generateEphemeralPrivateKey = generateEphemeralPrivateKey;
  }

  getRole(): NoiseHandshakeRole {
    return this.role;
  }

  getAction(): NoiseHandshakeAction {
    return this.action;
  }

  isInitiator(): boolean {
    return this.role === NoiseHandshakeRole.INITIATOR;
  }

  setPrologue(prologue: Uint8Array): void {
    this.prologue = new Uint8Array(prologue);
  }

  getLocalKeyPair(): NoiseXxDHKey {
    return this.localKeyPair;
  }

  needsLocalKeyPair(): boolean {
    return true;
  }

  hasLocalKeyPair(): boolean {
    return this.localKeyPair.hasPrivateKey();
  }

  getRemotePublicKey(): NoiseXxDHKey {
    if (this.action !== NoiseHandshakeAction.SPLIT &&
      this.action !== NoiseHandshakeAction.COMPLETE) {
      throw new Error('Handshake has not completed');
    }
    return this.remotePublicKey;
  }

  hasRemotePublicKey(): boolean {
    return this.remotePublicKey.hasPublicKey();
  }

  getFixedEphemeralKey(): NoiseXxDHKey {
    if (this.fixedEphemeral === null) {
      this.fixedEphemeral = new NoiseXxDHKey();
    }
    return this.fixedEphemeral;
  }

  start(): void {
    if (this.action !== NoiseHandshakeAction.NO_ACTION) {
      throw new Error('Handshake has already started; cannot start again');
    }
    if (!this.localKeyPair.hasPrivateKey()) {
      throw new Error('Local static key required');
    }
    if (this.prologue !== null) {
      this.symmetric.mixHash(this.prologue);
    } else {
      this.symmetric.mixHash(new Uint8Array(0));
    }
    this.action = this.isInitiator()
      ? NoiseHandshakeAction.WRITE_MESSAGE
      : NoiseHandshakeAction.READ_MESSAGE;
  }

  writeMessage(payload: Uint8Array | null): Uint8Array {
    if (this.action !== NoiseHandshakeAction.WRITE_MESSAGE) {
      throw new Error('Handshake state does not allow writing messages');
    }
    const parts: Uint8Array[] = [];
    try {
      for (;;) {
        if (this.patternIndex >= NoiseXXHandshake.XX_PATTERN.length) {
          this.action = NoiseHandshakeAction.SPLIT;
          break;
        }
        const token: number = NoiseXXHandshake.XX_PATTERN[this.patternIndex++];
        if (token === PATTERN_FLIP_DIR) {
          this.action = NoiseHandshakeAction.READ_MESSAGE;
          break;
        }
        switch (token) {
          case PATTERN_E: {
            if (this.fixedEphemeral !== null) {
              this.localEphemeral.copyFrom(this.fixedEphemeral);
            } else {
              if (this.generateEphemeralPrivateKey === null) {
                throw new Error('No ephemeral key source available');
              }
              this.localEphemeral.generateKeyPair(this.generateEphemeralPrivateKey);
            }
            const e: Uint8Array = new Uint8Array(this.localEphemeral.publicKey);
            this.symmetric.mixHash(e);
            parts.push(e);
            break;
          }
          case PATTERN_S: {
            parts.push(this.symmetric.encryptAndHash(new Uint8Array(this.localKeyPair.publicKey)));
            break;
          }
          case PATTERN_EE: {
            this.mixDH(this.localEphemeral, this.remoteEphemeral);
            break;
          }
          case PATTERN_ES: {
            if (this.isInitiator()) {
              this.mixDH(this.localEphemeral, this.remotePublicKey);
            } else {
              this.mixDH(this.localKeyPair, this.remoteEphemeral);
            }
            break;
          }
          case PATTERN_SE: {
            if (this.isInitiator()) {
              this.mixDH(this.localKeyPair, this.remoteEphemeral);
            } else {
              this.mixDH(this.localEphemeral, this.remotePublicKey);
            }
            break;
          }
          default:
            throw new Error('Unknown handshake token ' + token);
        }
      }
      parts.push(this.symmetric.encryptAndHash(
        payload !== null ? payload : new Uint8Array(0)));
    } catch (e) {
      this.action = NoiseHandshakeAction.FAILED;
      const err: Error = e instanceof Error ? e : new Error(String(e));
      throw err;
    }
    return NoiseXXHandshake.concat(parts);
  }

  readMessage(message: Uint8Array): Uint8Array {
    if (this.action !== NoiseHandshakeAction.READ_MESSAGE) {
      throw new Error('Handshake state does not allow reading messages');
    }
    let offset: number = 0;
    try {
      for (;;) {
        if (this.patternIndex >= NoiseXXHandshake.XX_PATTERN.length) {
          this.action = NoiseHandshakeAction.SPLIT;
          break;
        }
        const token: number = NoiseXXHandshake.XX_PATTERN[this.patternIndex++];
        if (token === PATTERN_FLIP_DIR) {
          this.action = NoiseHandshakeAction.WRITE_MESSAGE;
          break;
        }
        switch (token) {
          case PATTERN_E: {
            if (message.length - offset < 32) {
              throw new Error('Short buffer for remote ephemeral key');
            }
            const eBytes: Uint8Array = message.slice(offset, offset + 32);
            this.symmetric.mixHash(eBytes);
            this.remoteEphemeral.setPublicKey(eBytes);
            if (this.remoteEphemeral.isNullPublicKey()) {
              throw new Error('Null remote public key');
            }
            offset += 32;
            break;
          }
          case PATTERN_S: {
            const macLength: number = this.symmetric.getMacLength();
            if (message.length - offset < 32 + macLength) {
              throw new Error('Short buffer for remote static key');
            }
            const sBytes: Uint8Array = message.slice(offset, offset + 32 + macLength);
            const plain: Uint8Array = this.symmetric.decryptAndHash(sBytes);
            if (plain.length !== 32) {
              throw new Error('Remote static key decrypt length mismatch');
            }
            this.remotePublicKey.setPublicKey(plain);
            offset += 32 + macLength;
            break;
          }
          case PATTERN_EE: {
            this.mixDH(this.localEphemeral, this.remoteEphemeral);
            break;
          }
          case PATTERN_ES: {
            if (this.isInitiator()) {
              this.mixDH(this.localEphemeral, this.remotePublicKey);
            } else {
              this.mixDH(this.localKeyPair, this.remoteEphemeral);
            }
            break;
          }
          case PATTERN_SE: {
            if (this.isInitiator()) {
              this.mixDH(this.localKeyPair, this.remoteEphemeral);
            } else {
              this.mixDH(this.localEphemeral, this.remotePublicKey);
            }
            break;
          }
          default:
            throw new Error('Unknown handshake token ' + token);
        }
      }
      return this.symmetric.decryptAndHash(message.slice(offset));
    } catch (e) {
      this.action = NoiseHandshakeAction.FAILED;
      const err: Error = e instanceof Error ? e : new Error(String(e));
      throw err;
    }
  }

  split(): NoiseCipherStatePair {
    if (this.action !== NoiseHandshakeAction.SPLIT) {
      throw new Error('Handshake has not finished');
    }
    const pair: NoiseCipherStatePair = this.symmetric.split();
    if (!this.isInitiator()) {
      pair.swap();
    }
    this.action = NoiseHandshakeAction.COMPLETE;
    return pair;
  }

  getHandshakeHash(): Uint8Array {
    if (this.action !== NoiseHandshakeAction.SPLIT &&
      this.action !== NoiseHandshakeAction.COMPLETE) {
      throw new Error('Handshake has not completed');
    }
    return this.symmetric.getHandshakeHash();
  }

  private mixDH(local: NoiseXxDHKey, remote: NoiseXxDHKey): void {
    const shared: Uint8Array = Curve25519.sharedSecret(local.getPrivateKey(), remote.publicKey);
    this.symmetric.mixKey(shared);
  }

  private static concat(parts: Uint8Array[]): Uint8Array {
    let total: number = 0;
    for (const part of parts) {
      total += part.length;
    }
    const output: Uint8Array = new Uint8Array(total);
    let offset: number = 0;
    for (const part of parts) {
      output.set(part, offset);
      offset += part.length;
    }
    return output;
  }
}
