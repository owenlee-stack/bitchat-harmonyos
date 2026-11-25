/**
 * Generation-scoped authenticated peer-state exchange for Noise payload
 * type 0x21 (US10, T051; Android AuthenticatedPeerStateCoordinator parity).
 *
 * Each authenticated Noise generation (remote static key + handshake-hash
 * session token) carries its own 0x21 exchange:
 *  - the local state (capability bitfield + Ed25519 public key) is emitted
 *    once per generation/rekey, and the first valid remote proof is echoed
 *    back exactly once;
 *  - the first valid proof wins: repeated equal proofs are idempotent, a
 *    different proof cannot replace it within the same generation;
 *  - the proof is persisted durably (HSTS-style pin, keyed by the SHA-256
 *    fingerprint of the authenticated static key) BEFORE the replacement
 *    Ed key is published to the peer table, so a restart cannot reopen
 *    copied-static first-announce poisoning;
 *  - a proof-timeout watchdog (default 5s) resolves generations that never
 *    saw a proof; the watchdog is never reset by policy reads.
 *
 * Announcements alone can never create or refresh a pin.
 *
 * Deliberately pure ArkTS (no @kit imports): the watchdog scheduler and the
 * live Noise generation provider are injected, so the contract tests run on
 * the host harness with a fake scheduler; the device wiring passes the live
 * NoiseSessionManager (service/noise) and setTimeout/clearTimeout.
 */
import { ByteUtils } from '../../common/ByteUtils';
import { AuthenticatedPeerState } from '../../model/IdentityModels';
import { AuthenticatedNoiseSession } from '../noise/NoiseSessionManager';
import { NoisePeerIdentity } from '../noise/NoisePeerIdentity';

/** Durable pin store keyed by the static-key fingerprint. */
export interface PeerStateStore {
  load(fingerprint: string): AuthenticatedPeerState | null;
  persist(fingerprint: string, state: AuthenticatedPeerState,
    onCommitted: () => void): boolean;
  isPrivateMediaPinned(fingerprint: string): boolean;
}

/** Resolution of the 0x21 exchange for one live Noise generation. */
export enum PeerStateStatus {
  MISSING = 0,
  AWAITING = 1,
  TIMED_OUT = 2,
  PROVEN = 3
}

/** Injected collaborators (device wiring in a later task). */
export interface PeerStateManagerDeps {
  authenticatedSessionProvider: (peerID: string) => AuthenticatedNoiseSession | null;
  withAuthenticatedSession: (peerID: string, expectedSession: AuthenticatedNoiseSession,
    action: () => boolean) => boolean;
  store: PeerStateStore;
  localStateProvider: () => AuthenticatedPeerState;
  applyAuthenticatedState: (peerID: string, authenticatedNoisePublicKey: Uint8Array,
    state: AuthenticatedPeerState) => void;
  sendState: (peerID: string, state: AuthenticatedPeerState,
    session: AuthenticatedNoiseSession) => boolean;
  onResolution: (peerID: string) => void;
  proofTimeoutMs: number;
  schedule: (delayMs: number, task: () => void) => number;
  cancel: (handle: number) => void;
}

/** One tracked Noise generation's exchange state. */
class TrackedGeneration {
  readonly authenticatedSession: AuthenticatedNoiseSession;
  readonly fingerprint: string;
  status: PeerStateStatus;
  provenState: AuthenticatedPeerState | null;
  echoSent: boolean;
  timeoutHandle: number | null;

  constructor(authenticatedSession: AuthenticatedNoiseSession, fingerprint: string) {
    this.authenticatedSession = authenticatedSession;
    this.fingerprint = fingerprint;
    this.status = PeerStateStatus.AWAITING;
    this.provenState = null;
    this.echoSent = false;
    this.timeoutHandle = null;
  }
}

/** Captures whether the current generation still owes its echo. */
class EchoPlan {
  session: AuthenticatedNoiseSession | null = null;
}

export class PeerStateManager {
  static readonly PROOF_TIMEOUT_MS: number = 5000;
  static readonly SESSION_TOKEN_SIZE: number = 32;
  static readonly STATIC_PUBLIC_KEY_SIZE: number = 32;

  private readonly deps: PeerStateManagerDeps;
  private readonly generations: Map<string, TrackedGeneration> = new Map();

  constructor(deps: PeerStateManagerDeps) {
    this.deps = deps;
  }

  /** Fresh, generation-scoped entry point for a completed Noise handshake. */
  onSessionAuthenticated(peerID: string, authenticatedRemoteStatic: Uint8Array,
    authenticatedSessionToken: Uint8Array): void {
    if (!PeerStateManager.validBinding(peerID, authenticatedRemoteStatic,
      authenticatedSessionToken)) {
      return;
    }
    const session: AuthenticatedNoiseSession =
      new AuthenticatedNoiseSession(authenticatedRemoteStatic, authenticatedSessionToken);
    this.ensureGeneration(peerID, session);
  }

  /**
   * Accept the first valid proof for this generation; repeated equal proofs
   * are idempotent. The pin is persisted before the replacement Ed key is
   * published in memory, so a restart cannot reopen first-announce poisoning.
   */
  receive(peerID: string, state: AuthenticatedPeerState,
    decryptedSession: AuthenticatedNoiseSession): boolean {
    const remoteStatic: Uint8Array = decryptedSession.getRemoteStaticKey();
    if (!PeerStateManager.validBinding(peerID, remoteStatic, decryptedSession.getSessionToken())) {
      return false;
    }
    const currentFingerprint: string = PeerStateManager.fingerprint(remoteStatic);
    const echoPlan: EchoPlan = new EchoPlan();
    let accepted: boolean = false;
    try {
      accepted = this.deps.withAuthenticatedSession(peerID, decryptedSession, (): boolean => {
        const current: TrackedGeneration | undefined = this.generations.get(peerID);
        if (current === undefined) {
          return false;
        }
        if (current.fingerprint !== currentFingerprint ||
          !current.authenticatedSession.equals(decryptedSession)) {
          return false;
        }
        if (current.status === PeerStateStatus.PROVEN) {
          return current.provenState !== null &&
            AuthenticatedPeerState.equals(current.provenState, state);
        }
        // Persist before publishing the replacement Ed key in memory. The
        // withAuthenticatedSession lease prevents this generation from being
        // replaced during the transition; onCommitted publishes while the
        // persistence epoch lock is still held.
        const committed: boolean = this.deps.store.persist(currentFingerprint, state, (): void => {
          this.deps.applyAuthenticatedState(peerID, remoteStatic, state);
        });
        if (!committed) {
          return false;
        }
        if (current.timeoutHandle !== null) {
          this.deps.cancel(current.timeoutHandle);
          current.timeoutHandle = null;
        }
        current.status = PeerStateStatus.PROVEN;
        current.provenState = state;
        if (!current.echoSent) {
          current.echoSent = true;
          echoPlan.session = current.authenticatedSession;
        }
        return true;
      });
    } catch (e) {
      return false;
    }
    if (!accepted) {
      return false;
    }
    const echoSession: AuthenticatedNoiseSession | null = echoPlan.session;
    if (echoSession !== null) {
      try {
        this.deps.sendState(peerID, this.deps.localStateProvider(), echoSession);
      } catch (e) {
        // An echo failure must not undo the accepted proof.
      }
    }
    this.deps.onResolution(peerID);
    return true;
  }

  /** Install one watchdog/exchange for this exact live generation, without resetting it. */
  status(peerID: string, authenticatedSession: AuthenticatedNoiseSession): PeerStateStatus {
    this.ensureGeneration(peerID, authenticatedSession);
    const currentFingerprint: string =
      PeerStateManager.fingerprint(authenticatedSession.getRemoteStaticKey());
    const current: TrackedGeneration | undefined = this.generations.get(peerID);
    if (current === undefined || current.fingerprint !== currentFingerprint ||
      !current.authenticatedSession.equals(authenticatedSession)) {
      return PeerStateStatus.MISSING;
    }
    return current.status;
  }

  /** The proven state for this exact generation, or null unless PROVEN. */
  provenState(peerID: string,
    authenticatedSession: AuthenticatedNoiseSession): AuthenticatedPeerState | null {
    const kind: PeerStateStatus = this.status(peerID, authenticatedSession);
    if (kind !== PeerStateStatus.PROVEN) {
      return null;
    }
    const current: TrackedGeneration | undefined = this.generations.get(peerID);
    if (current === undefined || current.provenState === null) {
      return null;
    }
    return current.provenState;
  }

  /** Durable Ed25519 key pinned for an authenticated static key. */
  persistedSigningKeyFor(noisePublicKey: Uint8Array): Uint8Array | null {
    if (noisePublicKey.length !== PeerStateManager.STATIC_PUBLIC_KEY_SIZE) {
      return null;
    }
    const stored: AuthenticatedPeerState | null =
      this.deps.store.load(PeerStateManager.fingerprint(noisePublicKey));
    return stored === null ? null : stored.signingPublicKey.slice();
  }

  /** True when the live generation's static key has a durable private-media pin. */
  isPrivateMediaPinned(peerID: string): boolean {
    const live: AuthenticatedNoiseSession | null =
      this.deps.authenticatedSessionProvider(peerID);
    if (live === null) {
      return false;
    }
    return this.deps.store.isPrivateMediaPinned(PeerStateManager.fingerprint(live.getRemoteStaticKey()));
  }

  /** Forget the tracked generation (peer disconnect / session teardown). */
  clear(peerID: string): void {
    const current: TrackedGeneration | undefined = this.generations.get(peerID);
    if (current === undefined) {
      return;
    }
    if (current.timeoutHandle !== null) {
      this.deps.cancel(current.timeoutHandle);
      current.timeoutHandle = null;
    }
    this.generations.delete(peerID);
  }

  /** Install one watchdog/exchange for this exact live generation, without resetting it. */
  private ensureGeneration(peerID: string,
    session: AuthenticatedNoiseSession): TrackedGeneration | null {
    const remoteStatic: Uint8Array = session.getRemoteStaticKey();
    if (!PeerStateManager.validBinding(peerID, remoteStatic, session.getSessionToken())) {
      return null;
    }
    // Ignore a delayed callback or policy snapshot if a later generation is
    // already active.
    const live: AuthenticatedNoiseSession | null = this.deps.authenticatedSessionProvider(peerID);
    if (live === null || !live.equals(session)) {
      return null;
    }
    const generation: TrackedGeneration =
      new TrackedGeneration(session, PeerStateManager.fingerprint(remoteStatic));
    let installed: boolean = false;
    try {
      installed = this.deps.withAuthenticatedSession(peerID, session, (): boolean => {
        const existing: TrackedGeneration | undefined = this.generations.get(peerID);
        if (existing !== undefined && existing.authenticatedSession.equals(session)) {
          return false;
        }
        if (existing !== undefined && existing.timeoutHandle !== null) {
          this.deps.cancel(existing.timeoutHandle);
          existing.timeoutHandle = null;
        }
        this.generations.set(peerID, generation);
        return true;
      });
    } catch (e) {
      return null;
    }
    if (!installed) {
      const existing: TrackedGeneration | undefined = this.generations.get(peerID);
      return existing === undefined ? null : existing;
    }

    // Emit for every authenticated generation/rekey. Failure does not relax
    // the watchdog.
    try {
      this.deps.sendState(peerID, this.deps.localStateProvider(), session);
    } catch (e) {
      // The watchdog still resolves an unsent exchange.
    }
    const handle: number = this.deps.schedule(this.deps.proofTimeoutMs, (): void => {
      const current: TrackedGeneration | undefined = this.generations.get(peerID);
      if (current === undefined || current !== generation) {
        return;
      }
      if (current.status !== PeerStateStatus.AWAITING) {
        return;
      }
      current.status = PeerStateStatus.TIMED_OUT;
      this.deps.onResolution(peerID);
    });
    generation.timeoutHandle = handle;
    return generation;
  }

  private static validBinding(peerID: string, staticPublicKey: Uint8Array,
    sessionToken: Uint8Array): boolean {
    if (!NoisePeerIdentity.matchesClaimedPeerID(peerID, staticPublicKey)) {
      return false;
    }
    if (sessionToken.length !== PeerStateManager.SESSION_TOKEN_SIZE) {
      return false;
    }
    return PeerStateManager.hasNonZeroByte(sessionToken);
  }

  private static hasNonZeroByte(bytes: Uint8Array): boolean {
    for (let i: number = 0; i < bytes.length; i++) {
      if (bytes[i] !== 0) {
        return true;
      }
    }
    return false;
  }

  static fingerprint(publicKey: Uint8Array): string {
    return ByteUtils.bytesToHex(ByteUtils.sha256(publicKey));
  }
}
