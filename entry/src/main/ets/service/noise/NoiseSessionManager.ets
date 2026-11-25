/**
 * Per-peer Noise session table with handshake lifecycle management -
 * port of bitchat-android NoiseSessionManager.kt.
 *
 * Differences from the Android source, all intentional:
 *  - No Executors/ConcurrentHashMap: the 2s handshake sweeper runs on an
 *    injected scheduler, the clock is an injected nowMs callback, and the
 *    ephemeral key source is an injected generator so the manager stays
 *    free of device APIs and its decision semantics run in the host
 *    contract harness (the device wiring injects cryptoFramework random).
 *  - Kotlin's sealed NoiseSessionError hierarchy becomes plain Error
 *    objects carrying the exact Android message strings
 *    ('Handshake timed out', 'Authenticated Noise key derives to ...').
 *  - withAuthenticatedSession keeps the generation check but the action
 *    callback runs synchronously on the single-threaded event loop, so the
 *    Android lease/threading semantics are not needed to prevent
 *    interleaved replacement.
 *
 * Security-critical rules preserved verbatim:
 *  - An inbound replacement handshake must complete authentication and
 *    prove the claimed peer ID (NoisePeerIdentity binding) before it can
 *    evict a working transport session; responder candidates live outside
 *    the active map until then.
 *  - Handshake collisions resolve deterministically by peer ID string
 *    comparison (the higher peer ID yields to the responder role).
 *  - Established sessions are never touched by the stale-handshake sweep.
 */
import { NoiseSession, NoiseSessionState } from './NoiseSession';
import { NoisePeerIdentity } from './NoisePeerIdentity';

function noiseBytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let i: number = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}

/** Result of feeding one handshake message into the manager. */
export class NoiseHandshakeProcessingResult {
  private readonly responseBytes: Uint8Array | null;
  private readonly establishedNow: boolean;
  private readonly remoteStaticKey: Uint8Array | null;
  private readonly sessionToken: Uint8Array | null;

  constructor(response: Uint8Array | null, establishedNow: boolean,
    authenticatedRemoteStaticKey: Uint8Array | null,
    authenticatedSessionToken: Uint8Array | null) {
    this.responseBytes = response;
    this.establishedNow = establishedNow;
    this.remoteStaticKey = authenticatedRemoteStaticKey;
    this.sessionToken = authenticatedSessionToken;
  }

  getResponse(): Uint8Array | null {
    return this.responseBytes;
  }

  isEstablishedNow(): boolean {
    return this.establishedNow;
  }

  getAuthenticatedRemoteStaticKey(): Uint8Array | null {
    return this.remoteStaticKey;
  }

  getAuthenticatedSessionToken(): Uint8Array | null {
    return this.sessionToken;
  }
}

/** Snapshot of the live authenticated Noise generation. */
export class AuthenticatedNoiseSession {
  private readonly remoteStaticKeyBytes: Uint8Array;
  private readonly sessionTokenBytes: Uint8Array;

  constructor(remoteStaticKey: Uint8Array, sessionToken: Uint8Array) {
    this.remoteStaticKeyBytes = new Uint8Array(remoteStaticKey);
    this.sessionTokenBytes = new Uint8Array(sessionToken);
  }

  getRemoteStaticKey(): Uint8Array {
    return new Uint8Array(this.remoteStaticKeyBytes);
  }

  getSessionToken(): Uint8Array {
    return new Uint8Array(this.sessionTokenBytes);
  }

  equals(other: AuthenticatedNoiseSession): boolean {
    return noiseBytesEqual(this.remoteStaticKeyBytes, other.remoteStaticKeyBytes) &&
      noiseBytesEqual(this.sessionTokenBytes, other.sessionTokenBytes);
  }
}

/** Plaintext plus the generation that decrypted it, captured atomically. */
export class NoiseDecryptionResult {
  private readonly plaintextBytes: Uint8Array;
  private readonly authenticatedSession: AuthenticatedNoiseSession;

  constructor(plaintext: Uint8Array, authenticatedSession: AuthenticatedNoiseSession) {
    this.plaintextBytes = plaintext;
    this.authenticatedSession = authenticatedSession;
  }

  getPlaintext(): Uint8Array {
    return new Uint8Array(this.plaintextBytes);
  }

  getAuthenticatedSession(): AuthenticatedNoiseSession {
    return this.authenticatedSession;
  }
}

export class NoiseSessionManager {
  static readonly HANDSHAKE_TIMEOUT_MS: number = 10000;
  static readonly HANDSHAKE_SWEEP_INTERVAL_MS: number = 2000;
  static readonly HANDSHAKE_MESSAGE_1_SIZE: number = 32;
  static readonly SESSION_TOKEN_SIZE: number = 32;

  private readonly localStaticPrivateKey: Uint8Array;
  private readonly localStaticPublicKey: Uint8Array;
  private readonly localPeerID: string;
  private readonly generateEphemeralPrivateKey: (() => Uint8Array) | null;
  private readonly schedule: ((delayMs: number, task: () => void) => number) | null;
  private readonly cancel: ((handle: number) => void) | null;
  private readonly nowMs: () => number;

  private readonly sessions: Map<string, NoiseSession> = new Map();
  // An inbound replacement handshake must prove its authenticated
  // static-key binding before it can evict a working transport session.
  // Keep responder candidates outside the active map.
  private readonly responderCandidates: Map<string, NoiseSession> = new Map();
  private sweepHandle: number | null = null;

  onSessionEstablished: ((peerID: string, remoteStaticKey: Uint8Array) => void) | null = null;
  onSessionFailed: ((peerID: string, error: Error) => void) | null = null;

  constructor(localStaticPrivateKey: Uint8Array, localStaticPublicKey: Uint8Array,
    localPeerID: string,
    generateEphemeralPrivateKey: (() => Uint8Array) | null = null,
    schedule: ((delayMs: number, task: () => void) => number) | null = null,
    cancel: ((handle: number) => void) | null = null,
    nowMs: () => number = (): number => Date.now()) {
    this.localStaticPrivateKey = new Uint8Array(localStaticPrivateKey);
    this.localStaticPublicKey = new Uint8Array(localStaticPublicKey);
    this.localPeerID = localPeerID;
    this.generateEphemeralPrivateKey = generateEphemeralPrivateKey;
    this.schedule = schedule;
    this.cancel = cancel;
    this.nowMs = nowMs;
    if (this.schedule !== null) {
      this.scheduleSweep();
    }
  }

  addSession(peerID: string, session: NoiseSession): void {
    const previous: NoiseSession | null = this.sessions.get(peerID) ?? null;
    this.sessions.set(peerID, session);
    if (previous !== null && previous !== session) {
      previous.destroy();
    }
  }

  getSession(peerID: string): NoiseSession | null {
    return this.sessions.get(peerID) ?? null;
  }

  removeSession(peerID: string): void {
    const session: NoiseSession | null = this.sessions.get(peerID) ?? null;
    if (session !== null) {
      this.sessions.delete(peerID);
      session.destroy();
    }
    const candidate: NoiseSession | null = this.responderCandidates.get(peerID) ?? null;
    if (candidate !== null) {
      this.responderCandidates.delete(peerID);
      candidate.destroy();
    }
  }

  initiateHandshake(peerID: string, replaceEstablished: boolean = false): Uint8Array | null {
    const now: number = this.nowMs();
    const existing: NoiseSession | null = this.sessions.get(peerID) ?? null;
    if (existing !== null) {
      if (existing.isEstablished()) {
        if (!replaceEstablished) {
          return null;
        }
        const staleCandidate: NoiseSession | null =
          this.responderCandidates.get(peerID) ?? null;
        if (staleCandidate !== null) {
          this.responderCandidates.delete(peerID);
          staleCandidate.destroy();
        }
        const candidate: NoiseSession = this.createSession(peerID, true);
        this.responderCandidates.set(peerID, candidate);
        try {
          return candidate.startHandshake();
        } catch (e) {
          const err: Error = e instanceof Error ? e : new Error(String(e));
          if (this.responderCandidates.get(peerID) === candidate) {
            this.responderCandidates.delete(peerID);
          }
          candidate.destroy();
          throw err;
        }
      }
      if (existing.isHandshaking()) {
        if (!this.isHandshakeStale(existing, now)) {
          return null;
        }
        this.removeSession(peerID);
      } else {
        this.removeSession(peerID);
      }
    }

    const session: NoiseSession = this.createSession(peerID, true);
    this.addSession(peerID, session);
    try {
      return session.startHandshake();
    } catch (e) {
      const err: Error = e instanceof Error ? e : new Error(String(e));
      if (this.sessions.get(peerID) === session) {
        this.sessions.delete(peerID);
        session.destroy();
      }
      throw err;
    }
  }

  processHandshakeMessage(peerID: string, message: Uint8Array): Uint8Array | null {
    return this.processHandshakeMessageWithResult(peerID, message).getResponse();
  }

  processHandshakeMessageWithResult(peerID: string,
    message: Uint8Array): NoiseHandshakeProcessingResult {
    let activeSession: NoiseSession | null = null;
    let isReplacementCandidate: boolean = false;
    let establishedRemoteKey: Uint8Array | null = null;
    let establishedSessionToken: Uint8Array | null = null;
    let response: Uint8Array | null = null;

    try {
      const existingCandidate: NoiseSession | null =
        this.responderCandidates.get(peerID) ?? null;
      if (existingCandidate !== null) {
        if (message.length === NoiseSessionManager.HANDSHAKE_MESSAGE_1_SIZE) {
          if (existingCandidate.isInitiatorRole()) {
            const shouldYield: boolean = this.localPeerID > peerID;
            if (!shouldYield) {
              return new NoiseHandshakeProcessingResult(null, false, null, null);
            }
          }
          if (this.responderCandidates.get(peerID) === existingCandidate) {
            this.responderCandidates.delete(peerID);
          }
          existingCandidate.destroy();
          const fresh: NoiseSession = this.createSession(peerID, false);
          this.responderCandidates.set(peerID, fresh);
          activeSession = fresh;
        } else {
          activeSession = existingCandidate;
        }
        isReplacementCandidate = true;
      } else {
        let session: NoiseSession | null = this.sessions.get(peerID) ?? null;

        // Collision handling: both sides initiated and we received message 1.
        if (session !== null && session.isHandshaking() && session.isInitiatorRole() &&
          message.length === NoiseSessionManager.HANDSHAKE_MESSAGE_1_SIZE) {
          const shouldYield: boolean = this.localPeerID > peerID;
          if (shouldYield) {
            if (this.sessions.get(peerID) === session) {
              this.sessions.delete(peerID);
              session.destroy();
            }
            session = null;
          } else {
            return new NoiseHandshakeProcessingResult(null, false, null, null);
          }
        }

        if (session === null) {
          const fresh: NoiseSession = this.createSession(peerID, false);
          this.sessions.set(peerID, fresh);
          activeSession = fresh;
        } else if (session.isEstablished()) {
          isReplacementCandidate = true;
          const fresh: NoiseSession = this.createSession(peerID, false);
          this.responderCandidates.set(peerID, fresh);
          activeSession = fresh;
        } else if (session.isHandshaking() && !session.isInitiatorRole() &&
          message.length === NoiseSessionManager.HANDSHAKE_MESSAGE_1_SIZE) {
          // A restarted responder handshake can replace an incomplete
          // session because there is no working transport state to preserve.
          if (this.sessions.get(peerID) === session) {
            this.sessions.delete(peerID);
            session.destroy();
          }
          const fresh: NoiseSession = this.createSession(peerID, false);
          this.sessions.set(peerID, fresh);
          activeSession = fresh;
        } else {
          activeSession = session;
        }
      }

      if (activeSession === null) {
        throw new Error('Session in invalid state');
      }
      const session: NoiseSession = activeSession;

      response = session.processHandshakeMessage(message);

      if (session.isEstablished()) {
        const remoteStaticKey: Uint8Array | null = session.getRemoteStaticPublicKey();
        if (remoteStaticKey === null) {
          throw new Error('Handshake failed');
        }
        const derivedPeerID: string | null =
          NoisePeerIdentity.derivePeerID(remoteStaticKey);
        if (!NoisePeerIdentity.matchesClaimedPeerID(peerID, remoteStaticKey)) {
          throw new Error('Authenticated Noise key derives to ' +
            (derivedPeerID ?? 'invalid') + ', not claimed peer ' + peerID);
        }
        const token: Uint8Array | null = session.getHandshakeHash();
        if (token === null || token.length !== NoiseSessionManager.SESSION_TOKEN_SIZE ||
          !NoiseSessionManager.hasNonZeroByte(token)) {
          throw new Error('Handshake failed');
        }
        if (isReplacementCandidate) {
          if (this.responderCandidates.get(peerID) === session) {
            this.responderCandidates.delete(peerID);
          }
          const previous: NoiseSession | null = this.sessions.get(peerID) ?? null;
          this.sessions.set(peerID, session);
          if (previous !== null && previous !== session) {
            previous.destroy();
          }
        }
        establishedRemoteKey = remoteStaticKey;
        establishedSessionToken = token;
      }
    } catch (e) {
      const err: Error = e instanceof Error ? e : new Error(String(e));
      const failed: NoiseSession | null = activeSession;
      if (failed !== null) {
        if (isReplacementCandidate) {
          if (this.responderCandidates.get(peerID) === failed) {
            this.responderCandidates.delete(peerID);
          }
        } else if (this.sessions.get(peerID) === failed) {
          this.sessions.delete(peerID);
        }
        failed.destroy();
      }
      if (this.onSessionFailed !== null) {
        this.onSessionFailed(peerID, err);
      }
      throw err;
    }

    if (establishedRemoteKey !== null && this.onSessionEstablished !== null) {
      this.onSessionEstablished(peerID, new Uint8Array(establishedRemoteKey));
    }
    return new NoiseHandshakeProcessingResult(response,
      establishedRemoteKey !== null,
      establishedRemoteKey !== null ? new Uint8Array(establishedRemoteKey) : null,
      establishedSessionToken !== null ? new Uint8Array(establishedSessionToken) : null);
  }

  cleanupStaleHandshakes(nowMs: number): void {
    const sessionPeerIDs: string[] = [];
    this.sessions.forEach((session: NoiseSession, peerID: string) => {
      sessionPeerIDs.push(peerID);
    });
    for (const peerID of sessionPeerIDs) {
      const session: NoiseSession | null = this.sessions.get(peerID) ?? null;
      if (session !== null && session.isHandshaking() &&
        this.isHandshakeStale(session, nowMs)) {
        if (this.sessions.get(peerID) === session) {
          this.sessions.delete(peerID);
          session.destroy();
          if (this.onSessionFailed !== null) {
            this.onSessionFailed(peerID, new Error('Handshake timed out'));
          }
        }
      }
    }
    const candidatePeerIDs: string[] = [];
    this.responderCandidates.forEach((session: NoiseSession, peerID: string) => {
      candidatePeerIDs.push(peerID);
    });
    for (const peerID of candidatePeerIDs) {
      const session: NoiseSession | null = this.responderCandidates.get(peerID) ?? null;
      if (session !== null && session.isHandshaking() &&
        this.isHandshakeStale(session, nowMs)) {
        if (this.responderCandidates.get(peerID) === session) {
          this.responderCandidates.delete(peerID);
          session.destroy();
        }
      }
    }
  }

  encrypt(data: Uint8Array, peerID: string): Uint8Array {
    const session: NoiseSession | null = this.sessions.get(peerID) ?? null;
    if (session === null) {
      throw new Error('No session found for ' + peerID);
    }
    if (!session.isEstablished()) {
      throw new Error('Session not established with ' + peerID);
    }
    return session.encrypt(data);
  }

  /** Encrypt only if the exact generation that authorized the operation is still active. */
  encryptForSession(data: Uint8Array, peerID: string,
    expectedSession: AuthenticatedNoiseSession): Uint8Array {
    const session: NoiseSession | null = this.sessions.get(peerID) ?? null;
    if (session === null) {
      throw new Error('Session not found');
    }
    if (!session.isEstablished()) {
      throw new Error('Session not established');
    }
    const current: AuthenticatedNoiseSession | null = this.authenticatedSession(session);
    if (current === null) {
      throw new Error('Session not established');
    }
    if (!current.equals(expectedSession)) {
      throw new Error('Noise session generation changed');
    }
    return session.encrypt(data);
  }

  decrypt(encryptedData: Uint8Array, peerID: string): Uint8Array {
    return this.decryptWithSession(encryptedData, peerID).getPlaintext();
  }

  decryptWithSession(encryptedData: Uint8Array,
    peerID: string): NoiseDecryptionResult {
    const session: NoiseSession | null = this.sessions.get(peerID) ?? null;
    if (session === null) {
      throw new Error('No session found for ' + peerID);
    }
    if (!session.isEstablished()) {
      throw new Error('Session not established with ' + peerID);
    }
    const plaintext: Uint8Array = session.decrypt(encryptedData);
    const authenticatedSession: AuthenticatedNoiseSession | null =
      this.authenticatedSession(session);
    if (authenticatedSession === null) {
      throw new Error('Established session for ' + peerID + ' has no channel binding');
    }
    return new NoiseDecryptionResult(plaintext, authenticatedSession);
  }

  hasEstablishedSession(peerID: string): boolean {
    const session: NoiseSession | null = this.sessions.get(peerID) ?? null;
    return session !== null && session.isEstablished();
  }

  getSessionState(peerID: string): NoiseSessionState {
    const session: NoiseSession | null = this.sessions.get(peerID) ?? null;
    return session !== null ? session.getState() : NoiseSessionState.UNINITIALIZED;
  }

  getRemoteStaticKey(peerID: string): Uint8Array | null {
    const authenticated: AuthenticatedNoiseSession | null =
      this.getAuthenticatedSession(peerID);
    return authenticated !== null ? authenticated.getRemoteStaticKey() : null;
  }

  getAuthenticatedSession(peerID: string): AuthenticatedNoiseSession | null {
    const session: NoiseSession | null = this.sessions.get(peerID) ?? null;
    if (session === null) {
      return null;
    }
    if (!session.isEstablished()) {
      return null;
    }
    return this.authenticatedSession(session);
  }

  /** Execute a state transition only while the expected generation is active. */
  withAuthenticatedSession(peerID: string, expectedSession: AuthenticatedNoiseSession,
    action: () => boolean): boolean {
    const session: NoiseSession | null = this.sessions.get(peerID) ?? null;
    if (session === null) {
      return false;
    }
    if (!session.isEstablished()) {
      return false;
    }
    const current: AuthenticatedNoiseSession | null = this.authenticatedSession(session);
    if (current === null || !current.equals(expectedSession)) {
      return false;
    }
    return action();
  }

  getHandshakeHash(peerID: string): Uint8Array | null {
    const authenticated: AuthenticatedNoiseSession | null =
      this.getAuthenticatedSession(peerID);
    return authenticated !== null ? authenticated.getSessionToken() : null;
  }

  getSessionsNeedingRekey(): string[] {
    const result: string[] = [];
    this.sessions.forEach((session: NoiseSession, peerID: string) => {
      if (session.isEstablished() && session.needsRekey()) {
        result.push(peerID);
      }
    });
    return result;
  }

  getDebugInfo(): string {
    let info: string = '=== Noise Session Manager Debug ===\n';
    info += 'Active sessions: ' + this.sessions.size + '\n';
    info += 'Responder candidates: ' + this.responderCandidates.size + '\n';
    this.sessions.forEach((session: NoiseSession, peerID: string) => {
      info += '  ' + peerID + ': ' + session.getState() + '\n';
    });
    return info;
  }

  shutdown(): void {
    if (this.sweepHandle !== null && this.cancel !== null) {
      this.cancel(this.sweepHandle);
      this.sweepHandle = null;
    }
    this.sessions.forEach((session: NoiseSession) => {
      session.destroy();
    });
    this.responderCandidates.forEach((session: NoiseSession) => {
      session.destroy();
    });
    this.sessions.clear();
    this.responderCandidates.clear();
  }

  private createSession(peerID: string, isInitiator: boolean): NoiseSession {
    return new NoiseSession(peerID, isInitiator, this.localStaticPrivateKey,
      this.localStaticPublicKey, {
        generateEphemeralPrivateKey: this.generateEphemeralPrivateKey ?? undefined,
        nowMs: this.nowMs
      });
  }

  private isHandshakeStale(session: NoiseSession, nowMs: number): boolean {
    const lastActivity: number | null =
      session.getLastHandshakeActivityMs() ?? session.getHandshakeStartMs();
    if (lastActivity === null) {
      return false;
    }
    return (nowMs - lastActivity) > NoiseSessionManager.HANDSHAKE_TIMEOUT_MS;
  }

  private scheduleSweep(): void {
    if (this.schedule === null) {
      return;
    }
    this.sweepHandle = this.schedule(NoiseSessionManager.HANDSHAKE_SWEEP_INTERVAL_MS,
      (): void => {
        try {
          this.cleanupStaleHandshakes(this.nowMs());
        } catch (e) {
          // One failed sweep must not kill the rescheduling loop.
        }
        this.scheduleSweep();
      });
  }

  private authenticatedSession(session: NoiseSession): AuthenticatedNoiseSession | null {
    const remoteStaticKey: Uint8Array | null = session.getRemoteStaticPublicKey();
    if (remoteStaticKey === null ||
      remoteStaticKey.length !== NoiseSessionManager.SESSION_TOKEN_SIZE) {
      return null;
    }
    const token: Uint8Array | null = session.getHandshakeHash();
    if (token === null || token.length !== NoiseSessionManager.SESSION_TOKEN_SIZE ||
      !NoiseSessionManager.hasNonZeroByte(token)) {
      return null;
    }
    return new AuthenticatedNoiseSession(remoteStaticKey, token);
  }

  private static hasNonZeroByte(bytes: Uint8Array): boolean {
    for (let i: number = 0; i < bytes.length; i++) {
      if (bytes[i] !== 0) {
        return true;
      }
    }
    return false;
  }
}
