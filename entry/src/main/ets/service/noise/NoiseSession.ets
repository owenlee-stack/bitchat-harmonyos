/**
 * Individual Noise session for a specific peer - port of
 * bitchat-android NoiseSession.kt, 100% compatible with the iOS
 * bitchat Noise protocol.
 *
 * Wraps the NoiseXXHandshake state machine (Noise_XX_25519_ChaChaPoly_
 * SHA256) with the bitchat session lifecycle: XX handshake drive
 * (initiator 32-byte -> e; responder 96-byte <- e, ee, s, es;
 * initiator 64-byte -> s, se + tag with empty payloads), remote
 * static key binding to the claimed mesh peer ID via
 * NoisePeerIdentity, transport framing as <nonce(4)><ciphertext>
 * with a 1024-entry sliding replay window, and the rekey policy
 * (1h / 1000 encryption-service / 10000 session message limits).
 *
 * One intentional divergence from the Android source: successful
 * decrypts increment messagesReceived (Android resets the counter but
 * never increments it, which silently disables the message-count
 * rekey trigger on received traffic). A second one: the replay
 * window slide uses the correct bit direction - the Android
 * markNonceAsSeen swaps ushr/shl for non-byte-aligned shifts, which
 * drops seen bits and lets replays through after a partial slide;
 * the corrected window only ever rejects true replays, so it cannot
 * break interoperability.
 *
 * Pure ArkTS: no @ohos/@kit imports, host-runnable by the
 * contract-test harness. The ephemeral key source and clock are
 * injectable so the device stack wires cryptoFramework while
 * contract tests run deterministic vectors.
 */
import { ChaChaPolyCipher } from './ChaCha20Poly1305';
import { NoisePeerIdentity } from './NoisePeerIdentity';
import {
  NoiseHandshakeAction,
  NoiseHandshakeRole,
  NoiseXxDHKey,
  NoiseXXHandshake
} from './NoiseXXHandshake';
import { NoiseCipherStatePair } from './NoiseSymmetricState';

export enum NoiseSessionState {
  UNINITIALIZED = 0,
  HANDSHAKING = 1,
  ESTABLISHED = 2,
  FAILED = 3
}

export interface NoiseSessionOptions {
  generateEphemeralPrivateKey?: () => Uint8Array;
  nowMs?: () => number;
}

/**
 * Sliding-window replay protection (1024 entries, bit-packed into
 * 128 bytes) - port of the NoiseSession.kt companion helpers.
 */
export class NoiseReplayWindow {
  static readonly WINDOW_SIZE: number = 1024;
  static readonly WINDOW_BYTES: number = 128;

  private highestReceivedNonce: number = 0;
  private window: Uint8Array = new Uint8Array(NoiseReplayWindow.WINDOW_BYTES);

  getHighestReceivedNonce(): number {
    return this.highestReceivedNonce;
  }

  isValid(receivedNonce: number): boolean {
    if (receivedNonce + NoiseReplayWindow.WINDOW_SIZE <= this.highestReceivedNonce) {
      return false;
    }
    if (receivedNonce > this.highestReceivedNonce) {
      return true;
    }
    const offset: number = this.highestReceivedNonce - receivedNonce;
    const byteIndex: number = Math.floor(offset / 8);
    const bitIndex: number = offset % 8;
    return (this.window[byteIndex] & (1 << bitIndex)) === 0;
  }

  markSeen(receivedNonce: number): void {
    if (receivedNonce > this.highestReceivedNonce) {
      const shift: number = receivedNonce - this.highestReceivedNonce;
      if (shift >= NoiseReplayWindow.WINDOW_SIZE) {
        this.window.fill(0);
      } else {
        const byteShift: number = Math.floor(shift / 8);
        const bitShift: number = shift % 8;
        for (let i: number = NoiseReplayWindow.WINDOW_BYTES - 1; i >= 0; i--) {
          const sourceByteIndex: number = i - byteShift;
          let newByte: number = 0;
          if (sourceByteIndex >= 0) {
            newByte = ((this.window[sourceByteIndex] & 0xFF) << bitShift) & 0xFF;
            if (sourceByteIndex > 0 && bitShift !== 0) {
              newByte |= (this.window[sourceByteIndex - 1] & 0xFF) >>> (8 - bitShift);
            }
          }
          this.window[i] = newByte & 0xFF;
        }
      }
      this.highestReceivedNonce = receivedNonce;
      this.window[0] = (this.window[0] | 1) & 0xFF;
    } else {
      const offset: number = this.highestReceivedNonce - receivedNonce;
      const byteIndex: number = Math.floor(offset / 8);
      const bitIndex: number = offset % 8;
      this.window[byteIndex] = (this.window[byteIndex] | (1 << bitIndex)) & 0xFF;
    }
  }

  reset(): void {
    this.highestReceivedNonce = 0;
    this.window.fill(0);
  }
}

export class NoiseSession {
  /** Rekey thresholds (AppConstants.Noise, matching iOS). */
  static readonly REKEY_TIME_LIMIT_MS: number = 3600000;
  static readonly REKEY_MESSAGE_LIMIT_ENCRYPTION: number = 1000;
  static readonly REKEY_MESSAGE_LIMIT_SESSION: number = 10000;
  static readonly MAX_PAYLOAD_SIZE: number = 256;
  static readonly HIGH_NONCE_WARNING_THRESHOLD: number = 1000000000;

  private static readonly NOISE_XX_PATTERN_LENGTH: number = 3;
  private static readonly NONCE_SIZE_BYTES: number = 4;
  private static readonly UINT32_MAX: number = 4294967295;

  private readonly peerID: string;
  private readonly initiatorRole: boolean;
  private readonly localStaticPrivateKey: Uint8Array;
  private readonly localStaticPublicKey: Uint8Array;
  private readonly generateEphemeralPrivateKey: (() => Uint8Array) | null;
  private readonly nowMs: () => number;

  private handshakeState: NoiseXXHandshake | null = null;
  private sendCipher: ChaChaPolyCipher | null = null;
  private receiveCipher: ChaChaPolyCipher | null = null;
  private state: NoiseSessionState = NoiseSessionState.UNINITIALIZED;
  private failureReason: string = '';
  private readonly creationTime: number;
  private handshakeStartMs: number | null = null;
  private lastHandshakeActivityMs: number | null = null;
  private handshakeMessage1: Uint8Array | null = null;
  private currentPattern: number = 0;
  private messagesSent: number = 0;
  private messagesReceived: number = 0;
  private replayWindow: NoiseReplayWindow = new NoiseReplayWindow();
  private remoteStaticPublicKey: Uint8Array | null = null;
  private handshakeHash: Uint8Array | null = null;

  constructor(peerID: string, isInitiator: boolean, localStaticPrivateKey: Uint8Array,
    localStaticPublicKey: Uint8Array, options?: NoiseSessionOptions) {
    this.peerID = peerID;
    this.initiatorRole = isInitiator;
    this.localStaticPrivateKey = new Uint8Array(localStaticPrivateKey);
    this.localStaticPublicKey = new Uint8Array(localStaticPublicKey);
    this.generateEphemeralPrivateKey =
      options !== undefined && options.generateEphemeralPrivateKey !== undefined
        ? options.generateEphemeralPrivateKey
        : null;
    this.nowMs =
      options !== undefined && options.nowMs !== undefined
        ? options.nowMs
        : (): number => Date.now();
    this.creationTime = this.nowMs();
    try {
      this.validateStaticKeys();
    } catch (e) {
      this.state = NoiseSessionState.FAILED;
      this.failureReason = 'Invalid static keys';
    }
  }

  getState(): NoiseSessionState {
    return this.state;
  }

  isEstablished(): boolean {
    return this.state === NoiseSessionState.ESTABLISHED;
  }

  isHandshaking(): boolean {
    return this.state === NoiseSessionState.HANDSHAKING;
  }

  getCreationTime(): number {
    return this.creationTime;
  }

  isInitiatorRole(): boolean {
    return this.initiatorRole;
  }

  getHandshakeStartMs(): number | null {
    return this.handshakeStartMs;
  }

  getLastHandshakeActivityMs(): number | null {
    return this.lastHandshakeActivityMs;
  }

  getHandshakeMessage1(): Uint8Array | null {
    return this.handshakeMessage1 !== null ? new Uint8Array(this.handshakeMessage1) : null;
  }

  getFailureReason(): string {
    return this.failureReason;
  }

  getMessagesSent(): number {
    return this.messagesSent;
  }

  getMessagesReceived(): number {
    return this.messagesReceived;
  }

  getPeerID(): string {
    return this.peerID;
  }

  startHandshake(): Uint8Array {
    if (!this.initiatorRole) {
      throw new Error('Only initiator can start handshake');
    }
    if (this.state !== NoiseSessionState.UNINITIALIZED) {
      throw new Error('Handshake already started');
    }
    try {
      const handshake: NoiseXXHandshake = this.initializeNoiseHandshake(NoiseHandshakeRole.INITIATOR);
      this.handshakeState = handshake;
      this.state = NoiseSessionState.HANDSHAKING;
      if (this.handshakeStartMs === null) {
        this.handshakeStartMs = this.nowMs();
      }
      this.lastHandshakeActivityMs = this.nowMs();
      const firstMessage: Uint8Array = handshake.writeMessage(null);
      this.currentPattern++;
      this.handshakeMessage1 = new Uint8Array(firstMessage);
      return firstMessage;
    } catch (e) {
      this.state = NoiseSessionState.FAILED;
      this.failureReason = 'Failed to start handshake';
      const err: Error = e instanceof Error ? e : new Error(String(e));
      throw err;
    }
  }

  processHandshakeMessage(message: Uint8Array): Uint8Array | null {
    try {
      if (this.state === NoiseSessionState.UNINITIALIZED && !this.initiatorRole) {
        this.handshakeState = this.initializeNoiseHandshake(NoiseHandshakeRole.RESPONDER);
        this.state = NoiseSessionState.HANDSHAKING;
        if (this.handshakeStartMs === null) {
          this.handshakeStartMs = this.nowMs();
        }
      }
      if (this.state !== NoiseSessionState.HANDSHAKING) {
        throw new Error('Invalid state for handshake: ' + this.state);
      }
      this.lastHandshakeActivityMs = this.nowMs();
      const handshake: NoiseXXHandshake | null = this.handshakeState;
      if (handshake === null) {
        throw new Error('Handshake state is null');
      }
      handshake.readMessage(message);
      this.currentPattern++;
      const action: NoiseHandshakeAction = handshake.getAction();
      if (action === NoiseHandshakeAction.WRITE_MESSAGE) {
        const response: Uint8Array = handshake.writeMessage(null);
        this.currentPattern++;
        this.completeHandshake(handshake);
        return response;
      }
      if (action === NoiseHandshakeAction.SPLIT) {
        this.completeHandshake(handshake);
        return null;
      }
      if (action === NoiseHandshakeAction.FAILED) {
        throw new Error('Handshake failed - state machine reported FAILED');
      }
      return null;
    } catch (e) {
      this.state = NoiseSessionState.FAILED;
      this.failureReason = 'Handshake failed';
      const err: Error = e instanceof Error ? e : new Error(String(e));
      throw err;
    }
  }

  encrypt(data: Uint8Array): Uint8Array {
    if (!this.isEstablished()) {
      throw new Error('Session not established');
    }
    const sendCipher: ChaChaPolyCipher | null = this.sendCipher;
    if (sendCipher === null) {
      throw new Error('Send cipher not available');
    }
    if (this.messagesSent > NoiseSession.UINT32_MAX - 1) {
      throw new Error('Nonce value ' + this.messagesSent + ' exceeds 4-byte limit');
    }
    if (sendCipher.getMacLength() !== 16) {
      throw new Error('Send cipher MAC length is not 16');
    }
    const ciphertext: Uint8Array = new Uint8Array(data.length + sendCipher.getMacLength());
    sendCipher.setNonce(this.messagesSent);
    const ciphertextLength: number =
      sendCipher.encryptWithAd(null, data, 0, ciphertext, 0, data.length);
    const currentNonce: number = this.messagesSent;
    this.messagesSent++;
    const combinedPayload: Uint8Array =
      new Uint8Array(NoiseSession.NONCE_SIZE_BYTES + ciphertextLength);
    combinedPayload[0] = (currentNonce >>> 24) & 0xFF;
    combinedPayload[1] = (currentNonce >>> 16) & 0xFF;
    combinedPayload[2] = (currentNonce >>> 8) & 0xFF;
    combinedPayload[3] = currentNonce & 0xFF;
    combinedPayload.set(ciphertext.subarray(0, ciphertextLength), NoiseSession.NONCE_SIZE_BYTES);
    return combinedPayload;
  }

  decrypt(combinedPayload: Uint8Array): Uint8Array {
    if (!this.isEstablished()) {
      throw new Error('Session not established');
    }
    const receiveCipher: ChaChaPolyCipher | null = this.receiveCipher;
    if (receiveCipher === null) {
      throw new Error('Receive cipher not available');
    }
    if (combinedPayload.length < NoiseSession.NONCE_SIZE_BYTES) {
      throw new Error('Combined payload too small');
    }
    let extractedNonce: number = 0;
    for (let i: number = 0; i < NoiseSession.NONCE_SIZE_BYTES; i++) {
      extractedNonce = (extractedNonce * 256) + (combinedPayload[i] & 0xFF);
    }
    const ciphertext: Uint8Array = combinedPayload.slice(NoiseSession.NONCE_SIZE_BYTES);
    if (ciphertext.length < receiveCipher.getMacLength()) {
      throw new Error('Ciphertext too short');
    }
    if (!this.replayWindow.isValid(extractedNonce)) {
      throw new Error('Replay attack detected: nonce ' + extractedNonce + ' rejected');
    }
    const plaintext: Uint8Array = new Uint8Array(ciphertext.length);
    receiveCipher.setNonce(extractedNonce);
    const plaintextLength: number =
      receiveCipher.decryptWithAd(null, ciphertext, 0, plaintext, 0, ciphertext.length);
    this.replayWindow.markSeen(extractedNonce);
    this.messagesReceived++;
    return plaintext.slice(0, plaintextLength);
  }

  getRemoteStaticPublicKey(): Uint8Array | null {
    return this.remoteStaticPublicKey !== null ? new Uint8Array(this.remoteStaticPublicKey) : null;
  }

  getHandshakeHash(): Uint8Array | null {
    return this.handshakeHash !== null ? new Uint8Array(this.handshakeHash) : null;
  }

  needsRekey(): boolean {
    if (!this.isEstablished()) {
      return false;
    }
    const timeLimit: boolean =
      this.nowMs() - this.creationTime > NoiseSession.REKEY_TIME_LIMIT_MS;
    const messageLimit: boolean =
      (this.messagesSent + this.messagesReceived) > NoiseSession.REKEY_MESSAGE_LIMIT_SESSION;
    return timeLimit || messageLimit;
  }

  getSessionStats(): string {
    return 'NoiseSession with ' + this.peerID + ': state=' + this.state +
      ', role=' + (this.initiatorRole ? 'initiator' : 'responder') +
      ', sent=' + this.messagesSent + ', received=' + this.messagesReceived +
      ', needsRekey=' + this.needsRekey();
  }

  reset(): void {
    this.sendCipher = null;
    this.receiveCipher = null;
    this.handshakeState = null;
    this.remoteStaticPublicKey = null;
    this.handshakeHash = null;
    this.messagesSent = 0;
    this.messagesReceived = 0;
    this.currentPattern = 0;
    this.replayWindow.reset();
    this.state = NoiseSessionState.UNINITIALIZED;
    this.failureReason = '';
  }

  destroy(): void {
    if (this.sendCipher !== null) {
      this.sendCipher.destroy();
      this.sendCipher = null;
    }
    if (this.receiveCipher !== null) {
      this.receiveCipher.destroy();
      this.receiveCipher = null;
    }
    this.handshakeState = null;
    this.remoteStaticPublicKey = null;
    this.handshakeHash = null;
    if (this.state !== NoiseSessionState.FAILED) {
      this.state = NoiseSessionState.FAILED;
    }
    this.failureReason = 'Session destroyed';
  }

  private validateStaticKeys(): void {
    if (this.localStaticPrivateKey.length !== NoisePeerIdentity.STATIC_PUBLIC_KEY_SIZE) {
      throw new Error('Local static private key must be 32 bytes, got ' +
        this.localStaticPrivateKey.length);
    }
    if (this.localStaticPublicKey.length !== NoisePeerIdentity.STATIC_PUBLIC_KEY_SIZE) {
      throw new Error('Local static public key must be 32 bytes, got ' +
        this.localStaticPublicKey.length);
    }
    let privateZero: number = 0;
    for (let i: number = 0; i < this.localStaticPrivateKey.length; i++) {
      privateZero |= this.localStaticPrivateKey[i];
    }
    if (privateZero === 0) {
      throw new Error('Local static private key cannot be all zeros');
    }
    let publicZero: number = 0;
    for (let i: number = 0; i < this.localStaticPublicKey.length; i++) {
      publicZero |= this.localStaticPublicKey[i];
    }
    if (publicZero === 0) {
      throw new Error('Local static public key cannot be all zeros');
    }
  }

  private initializeNoiseHandshake(role: NoiseHandshakeRole): NoiseXXHandshake {
    const handshake: NoiseXXHandshake =
      new NoiseXXHandshake(role, this.generateEphemeralPrivateKey);
    const localKeyPair: NoiseXxDHKey = handshake.getLocalKeyPair();
    localKeyPair.setPrivateKey(this.localStaticPrivateKey);
    handshake.start();
    return handshake;
  }

  private completeHandshake(handshake: NoiseXXHandshake): void {
    if (this.currentPattern < NoiseSession.NOISE_XX_PATTERN_LENGTH) {
      return;
    }
    if (!handshake.hasRemotePublicKey()) {
      throw new Error('Handshake failed - missing remote public key');
    }
    const authenticatedRemoteKey: Uint8Array =
      new Uint8Array(handshake.getRemotePublicKey().publicKey);
    if (!NoisePeerIdentity.matchesClaimedPeerID(this.peerID, authenticatedRemoteKey)) {
      const derived: string | null = NoisePeerIdentity.derivePeerID(authenticatedRemoteKey);
      throw new Error('Peer identity mismatch: claimed ' + this.peerID +
        ', derived ' + derived);
    }
    this.remoteStaticPublicKey = authenticatedRemoteKey;
    const cipherPair: NoiseCipherStatePair = handshake.split();
    this.sendCipher = cipherPair.sender;
    this.receiveCipher = cipherPair.receiver;
    this.handshakeHash = handshake.getHandshakeHash();
    this.handshakeState = null;
    this.messagesSent = 0;
    this.messagesReceived = 0;
    this.currentPattern = 0;
    this.replayWindow.reset();
    this.state = NoiseSessionState.ESTABLISHED;
  }
}
