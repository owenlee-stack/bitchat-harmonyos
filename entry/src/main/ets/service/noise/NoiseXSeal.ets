/**
 * Noise_X_25519_ChaChaPoly_SHA256 one-way seal (courier envelopes, T062).
 *
 * Direct port of the vendored noise-java HandshakeState.java
 * (bitchat-android .../noise/southernstorm/protocol) specialized to
 * the one-way X pattern the courier system uses:
 *   <- s
 *   ...
 *   -> e, es, s, ss
 * The initiator's single seal message (e || enc(s) || enc(payload))
 * authenticates the sender identity inside the ciphertext while the
 * only external addressing hint is the recipient tag. Actions, error
 * semantics (any failure flips the action to FAILED), fixed-ephemeral
 * vector-test hooks and split() role swap all mirror noise-java.
 * Ephemeral key generation is injectable so the device stack can
 * back it with cryptoFramework while the contract harness runs fully
 * deterministic vectors. Pure ArkTS: no @ohos/@kit imports,
 * host-runnable by the contract-test harness.
 */
import { Curve25519 } from './Curve25519';
import { NoiseCipherStatePair, NoiseSymmetricState } from './NoiseSymmetricState';
import {
  NoiseHandshakeAction,
  NoiseHandshakeRole,
  NoiseXxDHKey
} from './NoiseXXHandshake';

const PATTERN_S: number = 1;
const PATTERN_E: number = 2;
const PATTERN_ES: number = 4;
const PATTERN_SS: number = 6;

export class NoiseXHandshake {
  static readonly PROTOCOL_NAME: string = 'Noise_X_25519_ChaChaPoly_SHA256';
  private static readonly X_PATTERN: number[] = [
    PATTERN_E, PATTERN_ES, PATTERN_S, PATTERN_SS
  ];

  private symmetric: NoiseSymmetricState = new NoiseSymmetricState(NoiseXHandshake.PROTOCOL_NAME);
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

  hasLocalKeyPair(): boolean {
    return this.localKeyPair.hasPrivateKey();
  }

  /**
   * Unlike XX, the X initiator must set the responder's pre-message
   * static public key here before start(); the responder reads the
   * authenticated initiator static from here after the handshake.
   */
  getRemotePublicKey(): NoiseXxDHKey {
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
    if (this.isInitiator() && !this.remotePublicKey.hasPublicKey()) {
      throw new Error('Initiator requires the responder static public key (pre-message)');
    }
    if (this.prologue !== null) {
      this.symmetric.mixHash(this.prologue);
    } else {
      this.symmetric.mixHash(new Uint8Array(0));
    }
    // noise-java HandshakeState.start() mixes the pattern's pre-message
    // public keys into the handshake hash: for X the responder's "<- s"
    // static is mixed by both roles (the initiator mixes the known
    // remote static, the responder its own local static public key),
    // so both sides agree before the first message.
    if (this.isInitiator()) {
      this.symmetric.mixHash(new Uint8Array(this.remotePublicKey.publicKey));
    } else {
      this.symmetric.mixHash(new Uint8Array(this.localKeyPair.publicKey));
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
        if (this.patternIndex >= NoiseXHandshake.X_PATTERN.length) {
          this.action = NoiseHandshakeAction.SPLIT;
          break;
        }
        const token: number = NoiseXHandshake.X_PATTERN[this.patternIndex++];
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
          case PATTERN_ES: {
            this.mixDH(this.localEphemeral, this.remotePublicKey);
            break;
          }
          case PATTERN_S: {
            parts.push(this.symmetric.encryptAndHash(new Uint8Array(this.localKeyPair.publicKey)));
            break;
          }
          case PATTERN_SS: {
            this.mixDH(this.localKeyPair, this.remotePublicKey);
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
    return NoiseXHandshake.concat(parts);
  }

  readMessage(message: Uint8Array): Uint8Array {
    if (this.action !== NoiseHandshakeAction.READ_MESSAGE) {
      throw new Error('Handshake state does not allow reading messages');
    }
    let offset: number = 0;
    try {
      for (;;) {
        if (this.patternIndex >= NoiseXHandshake.X_PATTERN.length) {
          this.action = NoiseHandshakeAction.SPLIT;
          break;
        }
        const token: number = NoiseXHandshake.X_PATTERN[this.patternIndex++];
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
          case PATTERN_ES: {
            this.mixDH(this.localKeyPair, this.remoteEphemeral);
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
          case PATTERN_SS: {
            this.mixDH(this.localKeyPair, this.remotePublicKey);
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

/** Result of NoiseXSeal.open(): the payload plus the sender identity. */
export class NoiseXSealOpenResult {
  readonly payload: Uint8Array;
  readonly senderStaticPublicKey: Uint8Array;

  constructor(payload: Uint8Array, senderStaticPublicKey: Uint8Array) {
    this.payload = payload;
    this.senderStaticPublicKey = senderStaticPublicKey;
  }
}

/** One-way Noise X seal facade used by the courier envelope pipeline. */
export class NoiseXSeal {
  static readonly PROTOCOL_NAME: string = 'Noise_X_25519_ChaChaPoly_SHA256';
  /** e (32) + encrypted sender static (32 + 16) + payload tag (16). */
  static readonly SEALED_OVERHEAD_BYTES: number = 96;

  static sealedSize(payloadBytes: number): number {
    return NoiseXSeal.SEALED_OVERHEAD_BYTES + payloadBytes;
  }

  static seal(payload: Uint8Array, senderStaticPrivate: Uint8Array,
    recipientStaticPublic: Uint8Array, generateEphemeralPrivateKey: () => Uint8Array,
    prologue: Uint8Array | null): Uint8Array {
    const handshake: NoiseXHandshake =
      new NoiseXHandshake(NoiseHandshakeRole.INITIATOR, generateEphemeralPrivateKey);
    if (prologue !== null) {
      handshake.setPrologue(prologue);
    }
    handshake.getLocalKeyPair().setPrivateKey(senderStaticPrivate);
    handshake.getRemotePublicKey().setPublicKey(recipientStaticPublic);
    handshake.start();
    return handshake.writeMessage(payload);
  }

  static open(sealed: Uint8Array, recipientStaticPrivate: Uint8Array,
    prologue: Uint8Array | null): NoiseXSealOpenResult {
    if (sealed.length < NoiseXSeal.SEALED_OVERHEAD_BYTES) {
      throw new Error('Sealed message shorter than the minimum Noise X envelope');
    }
    const handshake: NoiseXHandshake =
      new NoiseXHandshake(NoiseHandshakeRole.RESPONDER, null);
    if (prologue !== null) {
      handshake.setPrologue(prologue);
    }
    handshake.getLocalKeyPair().setPrivateKey(recipientStaticPrivate);
    handshake.start();
    const payload: Uint8Array = handshake.readMessage(sealed);
    const senderStaticPublicKey: Uint8Array =
      new Uint8Array(handshake.getRemotePublicKey().publicKey);
    return new NoiseXSealOpenResult(payload, senderStaticPublicKey);
  }
}
