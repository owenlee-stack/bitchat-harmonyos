/**
 * Authenticated peer-state contract tests (US10, T051): the Noise payload
 * 0x21 codec golden bytes (AuthenticatedPeerState parity with the Android /
 * iOS canonical form), the generation-scoped exchange semantics (emit per
 * generation, first-proof-wins, idempotent repeats, echo exactly once),
 * the 5s proof-timeout watchdog (never reset by policy reads), the
 * persist-before-publish pin ordering, and the HSTS-style pin lookups.
 *
 * The scheduler and the Noise session generation provider are stubbed, so
 * the whole suite runs synchronously on the host contract harness.
 */
import { ContractAssert } from './ContractAssert';
import { PeerStateStore } from '../../main/ets/service/mesh/PeerStateManager';
import { PeerStateManagerDeps } from '../../main/ets/service/mesh/PeerStateManager';
import { PeerStateManager, PeerStateStatus } from '../../main/ets/service/mesh/PeerStateManager';
import { AuthenticatedPeerState, NoisePayload, NoisePayloadType, PeerCapabilities } from '../../main/ets/model/IdentityModels';
import { AuthenticatedNoiseSession } from '../../main/ets/service/noise/NoiseSessionManager';
import { NoisePeerIdentity } from '../../main/ets/service/noise/NoisePeerIdentity';

/** In-memory pin store: records persists, optionally fails them. */
class MemoryPeerStateStore implements PeerStateStore {
  readonly states: Map<string, AuthenticatedPeerState> = new Map();
  readonly pins: Set<string> = new Set();
  failPersist: boolean = false;
  persistCount: number = 0;

  load(fingerprint: string): AuthenticatedPeerState | null {
    return this.states.get(fingerprint) ?? null;
  }

  persist(fingerprint: string, state: AuthenticatedPeerState,
    onCommitted: () => void): boolean {
    if (this.failPersist) {
      return false;
    }
    this.persistCount += 1;
    this.states.set(fingerprint, state);
    if (state.capabilities.contains(PeerCapabilities.PRIVATE_MEDIA)) {
      this.pins.add(fingerprint);
    }
    onCommitted();
    return true;
  }

  isPrivateMediaPinned(fingerprint: string): boolean {
    return this.pins.has(fingerprint);
  }
}

/** Manually-fired watchdog scheduler: captures tasks and their delays. */
class FakeScheduler {
  private readonly tasks: Map<number, ScheduledTask> = new Map();
  private nextHandle: number = 1;
  scheduledCount: number = 0;
  lastDelayMs: number = -1;

  schedule(delayMs: number, task: () => void): number {
    this.scheduledCount += 1;
    this.lastDelayMs = delayMs;
    const handle: number = this.nextHandle;
    this.nextHandle += 1;
    this.tasks.set(handle, new ScheduledTask(task));
    return handle;
  }

  cancel(handle: number): void {
    this.tasks.delete(handle);
  }

  /** Fire every still-pending watchdog, oldest first. */
  fireAll(): void {
    const handles: number[] = [];
    this.tasks.forEach((task: ScheduledTask, handle: number): void => {
      handles.push(handle);
    });
    handles.sort((a: number, b: number): number => a - b);
    for (let i: number = 0; i < handles.length; i++) {
      const entry: ScheduledTask | undefined = this.tasks.get(handles[i]);
      if (entry !== undefined) {
        this.tasks.delete(handles[i]);
        entry.task();
      }
    }
  }
}

class ScheduledTask {
  readonly task: () => void;

  constructor(task: () => void) {
    this.task = task;
  }
}

/** Wires a PeerStateManager against the stubs; records every side effect. */
class TestRig {
  readonly store: MemoryPeerStateStore = new MemoryPeerStateStore();
  readonly scheduler: FakeScheduler = new FakeScheduler();
  readonly sent: AuthenticatedPeerState[] = [];
  readonly sentTokens: Uint8Array[] = [];
  readonly applied: AuthenticatedPeerState[] = [];
  readonly appliedKeys: Uint8Array[] = [];
  readonly resolutions: string[] = [];
  readonly manager: PeerStateManager;
  activeSession: AuthenticatedNoiseSession;

  constructor(activeSession: AuthenticatedNoiseSession, proofTimeoutMs: number = 5000) {
    this.activeSession = activeSession;
    const deps: PeerStateManagerDeps = {
      authenticatedSessionProvider: (peerID: string): AuthenticatedNoiseSession | null => {
        return this.activeSession;
      },
      withAuthenticatedSession: (peerID: string, expectedSession: AuthenticatedNoiseSession,
        action: () => boolean): boolean => {
        if (!expectedSession.equals(this.activeSession)) {
          return false;
        }
        return action();
      },
      store: this.store,
      localStateProvider: (): AuthenticatedPeerState => localState,
      applyAuthenticatedState: (peerID: string, authenticatedNoisePublicKey: Uint8Array,
        state: AuthenticatedPeerState): void => {
        this.appliedKeys.push(authenticatedNoisePublicKey);
        this.applied.push(state);
      },
      sendState: (peerID: string, state: AuthenticatedPeerState,
        session: AuthenticatedNoiseSession): boolean => {
        this.sent.push(state);
        this.sentTokens.push(session.getSessionToken());
        return true;
      },
      onResolution: (peerID: string): void => {
        this.resolutions.push(peerID);
      },
      proofTimeoutMs: proofTimeoutMs,
      schedule: (delayMs: number, task: () => void): number => {
        return this.scheduler.schedule(delayMs, task);
      },
      cancel: (handle: number): void => {
        this.scheduler.cancel(handle);
      }
    };
    this.manager = new PeerStateManager(deps);
  }
}

const remoteStatic: Uint8Array = filled(32, 0x33);
const peerID: string = NoisePeerIdentity.derivePeerID(remoteStatic) ?? '';
const firstSession: AuthenticatedNoiseSession =
  new AuthenticatedNoiseSession(remoteStatic, filled(32, 0x71));
const secondSession: AuthenticatedNoiseSession =
  new AuthenticatedNoiseSession(remoteStatic, filled(32, 0x72));
const localState: AuthenticatedPeerState =
  new AuthenticatedPeerState(PeerCapabilities.PRIVATE_MEDIA, filled(32, 0x44));
const remoteState: AuthenticatedPeerState =
  new AuthenticatedPeerState(PeerCapabilities.PRIVATE_MEDIA, filled(32, 0x55));

function filled(length: number, value: number): Uint8Array {
  const out: Uint8Array = new Uint8Array(length);
  for (let i: number = 0; i < length; i++) {
    out[i] = value;
  }
  return out;
}

function concatBytes(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out: Uint8Array = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

export function runPeerStateManagerContractTests(t: ContractAssert): void {
  // ------------------------------------------------------------------
  // 0x21 payload codec (AuthenticatedPeerState golden vectors)
  // ------------------------------------------------------------------
  const signingKey: Uint8Array = new Uint8Array(32);
  for (let i: number = 0; i < 32; i++) {
    signingKey[i] = i;
  }
  const state: AuthenticatedPeerState =
    new AuthenticatedPeerState(PeerCapabilities.PRIVATE_MEDIA, signingKey);
  const encoded: Uint8Array = state.encode();
  t.equalBytes(concatBytes(new Uint8Array(
    [0x01, 0x01, 0x02, 0x00, 0x01, 0x02, 0x20]), signingKey), encoded,
  'encoder matches canonical iOS bytes');
  const decoded: AuthenticatedPeerState | null = AuthenticatedPeerState.decode(encoded);
  t.isNotNull(decoded, 'canonical payload decodes');
  if (decoded !== null) {
    t.isTrue(AuthenticatedPeerState.equals(state, decoded), 'decode round-trips');
  }

  // Unknown TLVs are skipped; either known-field order is accepted.
  const reordered: Uint8Array = concatBytes(concatBytes(new Uint8Array(
    [0x01, 0x7F, 0x02, 0x55, 0x66, 0x02, 0x20]), signingKey), new Uint8Array([0x01, 0x01, 0x00]));
  const reorderedDecoded: AuthenticatedPeerState | null = AuthenticatedPeerState.decode(reordered);
  t.isNotNull(reorderedDecoded, 'reordered payload decodes');
  if (reorderedDecoded !== null) {
    t.isTrue(AuthenticatedPeerState.equals(
      new AuthenticatedPeerState(PeerCapabilities.NONE, signingKey), reorderedDecoded),
    'unknown TLVs skipped and order accepted');
  }

  // Malformed / duplicate / missing / noncanonical fields are rejected.
  const validCapabilities: Uint8Array = new Uint8Array([0x01, 0x01, 0x00]);
  const validSigning: Uint8Array = concatBytes(new Uint8Array([0x02, 0x20]), signingKey);
  const invalid: Uint8Array[] = [
    new Uint8Array(0),
    concatBytes(new Uint8Array([0x02]), concatBytes(validCapabilities, validSigning)),
    concatBytes(new Uint8Array([0x01]), validCapabilities),
    concatBytes(new Uint8Array([0x01]), validSigning),
    concatBytes(new Uint8Array([0x01]),
      concatBytes(validCapabilities, concatBytes(validCapabilities, validSigning))),
    concatBytes(new Uint8Array([0x01, 0x01, 0x02, 0x00, 0x00]), validSigning),
    concatBytes(new Uint8Array([0x01, 0x01, 0x00]), validSigning),
    concatBytes(concatBytes(new Uint8Array([0x01, 0x01, 0x09]), filled(9, 0x01)),
      validSigning),
    concatBytes(concatBytes(new Uint8Array([0x01, 0x02, 0x1F]), filled(31, 0x01)),
      validCapabilities),
    new Uint8Array([0x01, 0x7F]),
    new Uint8Array([0x01, 0x7F, 0x02, 0x01])
  ];
  for (let i: number = 0; i < invalid.length; i++) {
    t.isNull(AuthenticatedPeerState.decode(invalid[i]), 'invalid payload ' + i + ' rejected');
  }

  // Noise wrapper emits and decodes the canonical 0x21.
  const wrapped: Uint8Array =
    new NoisePayload(NoisePayloadType.PEER_STATE, state.encode()).encode();
  t.equalNumber(0x21, wrapped[0] & 0xFF, 'wrapper emits 0x21');
  const unwrapped: NoisePayload | null = NoisePayload.decode(wrapped);
  t.isNotNull(unwrapped, 'wrapper decodes');
  if (unwrapped !== null) {
    t.equalNumber(NoisePayloadType.PEER_STATE, unwrapped.type, 'wrapper type is PEER_STATE');
  }

  // ------------------------------------------------------------------
  // Generation-scoped exchange (coordinator semantics)
  // ------------------------------------------------------------------
  t.isFalse(peerID === '', 'peer id derived');

  // Every generation emits and the first valid proof echoes exactly once.
  const rig: TestRig = new TestRig(firstSession);
  rig.manager.onSessionAuthenticated(peerID, remoteStatic, firstSession.getSessionToken());
  t.equalNumber(PeerStateStatus.AWAITING, rig.manager.status(peerID, firstSession),
    'first generation awaits proof');
  t.equalNumber(1, rig.sent.length, 'generation emitted local state');
  t.isTrue(rig.manager.receive(peerID, remoteState, firstSession), 'first proof accepted');
  t.equalNumber(2, rig.sent.length, 'proof echoed exactly once');
  t.isTrue(rig.manager.receive(peerID, remoteState, firstSession),
    'repeated equal proof is idempotent');
  t.equalNumber(2, rig.sent.length, 'repeated proof must not echo again');
  t.equalNumber(1, rig.applied.length, 'proof applied once');

  const different: AuthenticatedPeerState =
    new AuthenticatedPeerState(PeerCapabilities.NONE, filled(32, 0x66));
  t.isFalse(rig.manager.receive(peerID, different, firstSession),
    'a generation cannot replace its first proof');

  // A crypto swap observed before its completion callback adopts the new
  // token as AWAITING instead of reusing the previous generation's PROVEN.
  rig.activeSession = secondSession;
  t.equalNumber(PeerStateStatus.AWAITING, rig.manager.status(peerID, secondSession),
    'new generation adopted as awaiting');
  t.equalNumber(3, rig.sent.length, 'new generation emitted local state');
  rig.manager.onSessionAuthenticated(peerID, remoteStatic, secondSession.getSessionToken());
  t.equalNumber(3, rig.sent.length, 'duplicate authenticated callback does not re-emit');
  t.equalNumber(PeerStateStatus.AWAITING, rig.manager.status(peerID, secondSession),
    'second generation still awaits');
  t.isFalse(rig.manager.receive(peerID, remoteState, firstSession),
    'old generation proof rejected after swap');
  t.isTrue(rig.manager.receive(peerID, different, secondSession),
    'new generation accepts its first proof');
  t.equalNumber(4, rig.sent.length, 'new generation echoed once');
  t.equalNumber(2, rig.applied.length, 'new proof applied');

  // Proven state + HSTS-style pin lookups.
  const proven: AuthenticatedPeerState | null = rig.manager.provenState(peerID, secondSession);
  t.isNotNull(proven, 'proven state exposed');
  if (proven !== null) {
    t.isTrue(AuthenticatedPeerState.equals(different, proven), 'proven state matches proof');
  }
  t.isNull(rig.manager.provenState(peerID, firstSession),
    'old generation has no proven state');
  t.isTrue(rig.manager.isPrivateMediaPinned(peerID),
    'durable pin survives the generation swap');
  const pinnedRig: TestRig = new TestRig(firstSession);
  pinnedRig.store.pins.add(PeerStateManager.fingerprint(remoteStatic));
  t.isTrue(pinnedRig.manager.isPrivateMediaPinned(peerID), 'durable pin is visible');
  const persistedKey: Uint8Array | null =
    rig.manager.persistedSigningKeyFor(remoteStatic);
  t.isNotNull(persistedKey, 'persisted signing key exposed');
  if (persistedKey !== null) {
    t.equalBytes(different.signingPublicKey, persistedKey, 'persisted key matches proof');
  }
  t.isNull(rig.manager.persistedSigningKeyFor(filled(31, 0x01)),
    'wrong-size static key rejected');

  // Watchdog: fires once per unresolved generation; never reset by reads.
  const watchdogRig: TestRig = new TestRig(firstSession, 20);
  t.equalNumber(PeerStateStatus.AWAITING, watchdogRig.manager.status(peerID, firstSession),
    'watchdog generation awaits');
  t.equalNumber(1, watchdogRig.scheduler.scheduledCount, 'watchdog scheduled');
  t.equalNumber(20, watchdogRig.scheduler.lastDelayMs, 'watchdog uses proof timeout');
  t.equalNumber(PeerStateStatus.AWAITING, watchdogRig.manager.status(peerID, firstSession),
    'policy read does not reset the watchdog');
  t.equalNumber(1, watchdogRig.scheduler.scheduledCount, 'watchdog not rescheduled by reads');
  watchdogRig.scheduler.fireAll();
  t.equalNumber(PeerStateStatus.TIMED_OUT, watchdogRig.manager.status(peerID, firstSession),
    'generation timed out');
  t.equalNumber(1, watchdogRig.sent.length, 'no extra emission after timeout');
  t.equalNumber(1, watchdogRig.resolutions.length, 'timeout resolved once');
  t.equalString(peerID, watchdogRig.resolutions[0], 'timeout resolution names the peer');

  // Watchdog resolves without trusting persisted prior state.
  const staleRig: TestRig = new TestRig(firstSession, 20);
  staleRig.store.states.set(PeerStateManager.fingerprint(remoteStatic), remoteState);
  staleRig.manager.onSessionAuthenticated(peerID, remoteStatic, firstSession.getSessionToken());
  staleRig.scheduler.fireAll();
  t.equalNumber(PeerStateStatus.TIMED_OUT, staleRig.manager.status(peerID, firstSession),
    'watchdog ignores persisted prior state');
  t.equalNumber(1, staleRig.resolutions.length, 'stale generation resolved');

  // Delayed old completion cannot replace a newer tracked generation.
  const delayedRig: TestRig = new TestRig(secondSession);
  delayedRig.manager.onSessionAuthenticated(peerID, remoteStatic, secondSession.getSessionToken());
  delayedRig.manager.onSessionAuthenticated(peerID, remoteStatic, firstSession.getSessionToken());
  t.equalNumber(PeerStateStatus.AWAITING, delayedRig.manager.status(peerID, secondSession),
    'newer generation still tracked');
  t.equalNumber(1, delayedRig.sentTokens.length, 'only the live generation emitted');
  t.equalBytes(secondSession.getSessionToken(), delayedRig.sentTokens[0],
    'emission bound to the live token');

  // Copied-static preannounce: the authenticated proof replaces the Ed key,
  // published with the authenticated static key.
  const poisonRig: TestRig = new TestRig(firstSession);
  poisonRig.manager.onSessionAuthenticated(peerID, remoteStatic, firstSession.getSessionToken());
  const victimState: AuthenticatedPeerState =
    new AuthenticatedPeerState(PeerCapabilities.PRIVATE_MEDIA, filled(32, 0x22));
  t.isTrue(poisonRig.manager.receive(peerID, victimState, firstSession),
    'authenticated proof accepted');
  t.equalNumber(1, poisonRig.appliedKeys.length, 'proof published once');
  t.equalBytes(remoteStatic, poisonRig.appliedKeys[0],
    'publication carries the authenticated static key');
  t.equalBytes(victimState.signingPublicKey, poisonRig.applied[0].signingPublicKey,
    'authenticated Ed key replaces the preannounced one');

  // Failed durable persistence cannot publish peer state in memory.
  const failingRig: TestRig = new TestRig(firstSession);
  failingRig.store.failPersist = true;
  failingRig.manager.onSessionAuthenticated(peerID, remoteStatic, firstSession.getSessionToken());
  t.isFalse(failingRig.manager.receive(peerID, remoteState, firstSession),
    'proof rejected when the pin cannot persist');
  t.equalNumber(PeerStateStatus.AWAITING, failingRig.manager.status(peerID, firstSession),
    'generation still awaits after failed persistence');
  t.equalNumber(0, failingRig.applied.length, 'nothing published on failed persistence');
  t.isFalse(failingRig.manager.isPrivateMediaPinned(peerID),
    'failed persistence leaves no pin');

  // Stale decryption lease cannot persist or apply after generation replacement.
  const leaseRig: TestRig = new TestRig(firstSession);
  leaseRig.manager.onSessionAuthenticated(peerID, remoteStatic, firstSession.getSessionToken());
  leaseRig.activeSession = secondSession;
  t.isFalse(leaseRig.manager.receive(peerID, remoteState, firstSession),
    'stale lease proof rejected');
  t.equalNumber(0, leaseRig.store.persistCount, 'stale lease did not persist');
  t.equalNumber(0, leaseRig.applied.length, 'stale lease did not apply');

  // Clear forgets the tracked generation.
  const clearRig: TestRig = new TestRig(firstSession);
  clearRig.manager.onSessionAuthenticated(peerID, remoteStatic, firstSession.getSessionToken());
  clearRig.manager.clear(peerID);
  t.isFalse(clearRig.manager.receive(peerID, remoteState, firstSession),
    'cleared generation rejects proofs');
  t.equalNumber(PeerStateStatus.MISSING, clearRig.manager.status(peerID, secondSession),
    'cleared generation is missing for other sessions');
}
