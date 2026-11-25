/**
 * Port of the bitchat-android NoiseSessionManager unit tests
 * (NoiseSessionManagerHandshakeTimeoutTest.kt and
 * NoiseSessionManagerIdentityBindingTest.kt).
 *
 * Coverage kept from Android:
 *  - stale initiator handshakes expire with a 'Handshake timed out'
 *    failure callback, fresh ones survive, expired ones restart
 *  - established sessions are never touched by the sweep
 *  - responder candidates expire without harming the working session
 *  - initiator and responder identity binding (NoisePeerIdentity) with
 *    no authenticated callback escaping a mismatch
 *  - mismatched responder replacement preserves the working session and
 *    a later valid restart still promotes cleanly
 *  - generation-bound encryption (encryptForSession/withAuthenticatedSession)
 *    rejects stale bindings after a replacement
 *  - fresh initiator replacement (replaceEstablished) parks a candidate
 *    until authentication completes
 *  - simultaneous-initiator collisions resolve deterministically by peer
 *    ID tie break, over the full matrix of the four fixed Android
 *    identities
 *  - peer ID derivation rejects malformed keys and non-wire claims
 *
 * Not portable from Android: the CountDownLatch lease/threading test -
 * the event loop runs the action synchronously, so the lease semantics
 * are exercised through withAuthenticatedSession generation checks.
 */
import { ContractAssert } from './ContractAssert';
import { ByteUtils } from '../../main/ets/common/ByteUtils';
import { Curve25519 } from '../../main/ets/service/noise/Curve25519';
import { NoisePeerIdentity } from '../../main/ets/service/noise/NoisePeerIdentity';
import { NoiseSession } from '../../main/ets/service/noise/NoiseSession';
import {
  AuthenticatedNoiseSession,
  NoiseSessionManager
} from '../../main/ets/service/noise/NoiseSessionManager';

class TestIdentity {
  readonly privateKey: Uint8Array;
  readonly publicKey: Uint8Array;
  readonly peerID: string;

  constructor(privateKey: Uint8Array, publicKey: Uint8Array, peerID: string) {
    this.privateKey = privateKey;
    this.publicKey = publicKey;
    this.peerID = peerID;
  }
}

/** Records manager callbacks without closure-narrowing hazards. */
class CallbackRecorder {
  establishedPeerIDs: string[] = [];
  establishedKeys: Uint8Array[] = [];
  failedPeerIDs: string[] = [];
  failureMessages: string[] = [];

  readonly onSessionEstablished: (peerID: string, remoteStaticKey: Uint8Array) => void =
    (peerID: string, remoteStaticKey: Uint8Array): void => {
      this.establishedPeerIDs.push(peerID);
      this.establishedKeys.push(remoteStaticKey);
    };

  readonly onSessionFailed: (peerID: string, error: Error) => void =
    (peerID: string, error: Error): void => {
      this.failedPeerIDs.push(peerID);
      this.failureMessages.push(error.message);
    };

  establishedCount(): number {
    return this.establishedPeerIDs.length;
  }
}

let rngState: number = 0x2a35b17c | 0;

/** Deterministic xorshift32 test RNG - not cryptographic, tests only. */
function randomBytes(length: number): Uint8Array {
  const out: Uint8Array = new Uint8Array(length);
  for (let i: number = 0; i < length; i++) {
    rngState ^= rngState << 13;
    rngState ^= rngState >>> 17;
    rngState ^= rngState << 5;
    out[i] = rngState & 0xFF;
  }
  return out;
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
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

function identityFromPrivateKey(privateKey: Uint8Array): TestIdentity {
  const publicKey: Uint8Array = Curve25519.publicKeyFromPrivateKey(privateKey);
  const peerID: string | null = NoisePeerIdentity.derivePeerID(publicKey);
  if (peerID === null) {
    throw new Error('test identity derivation failed');
  }
  return new TestIdentity(new Uint8Array(privateKey), publicKey, peerID);
}

function identity(): TestIdentity {
  return identityFromPrivateKey(randomBytes(32));
}

function manager(identity: TestIdentity): NoiseSessionManager {
  return new NoiseSessionManager(identity.privateKey, identity.publicKey,
    identity.peerID, (): Uint8Array => randomBytes(32), null, null);
}

function completeHandshake(t: ContractAssert,
  initiator: NoiseSessionManager, initiatorPeerID: string,
  responder: NoiseSessionManager, responderPeerID: string): void {
  const message1: Uint8Array | null = initiator.initiateHandshake(responderPeerID);
  if (message1 === null) {
    throw new Error('initiateHandshake produced no message 1');
  }
  const message2: Uint8Array | null =
    responder.processHandshakeMessage(initiatorPeerID, message1);
  if (message2 === null) {
    throw new Error('responder produced no message 2');
  }
  const message3: Uint8Array | null =
    initiator.processHandshakeMessage(responderPeerID, message2);
  if (message3 === null) {
    throw new Error('initiator produced no message 3');
  }
  t.isNull(responder.processHandshakeMessage(initiatorPeerID, message3),
    'final handshake message yields no response');
}

function expectIdentityMismatch(t: ContractAssert, action: () => void): void {
  try {
    action();
  } catch (e) {
    const message: string = e instanceof Error ? e.message : String(e);
    if (message.indexOf('identity mismatch') >= 0 || message.indexOf('derives to') >= 0) {
      return;
    }
    throw new Error('expected identity mismatch, got: ' + message);
  }
  throw new Error('expected identity mismatch but no error was thrown');
}

export function runNoiseSessionManagerContractTests(t: ContractAssert): void {
  // --- NoiseSessionManagerHandshakeTimeoutTest ---

  // Stale initiator handshake is expired and reported as timeout.
  {
    const alice: TestIdentity = identity();
    const bob: TestIdentity = identity();
    const aliceManager: NoiseSessionManager = manager(alice);
    const recorder: CallbackRecorder = new CallbackRecorder();
    aliceManager.onSessionFailed = recorder.onSessionFailed;

    t.isNotNull(aliceManager.initiateHandshake(bob.peerID), 'message 1 is produced');
    const session: NoiseSession | null = aliceManager.getSession(bob.peerID);
    t.isNotNull(session, 'handshaking session exists');
    if (session !== null) {
      t.isTrue(session.isHandshaking(), 'the session is handshaking');
    }

    aliceManager.cleanupStaleHandshakes(Date.now() + 11000);

    t.isNull(aliceManager.getSession(bob.peerID), 'the stale handshake is swept');
    t.equalNumber(1, recorder.failedPeerIDs.length, 'a failure is reported');
    if (recorder.failureMessages.length === 1) {
      t.equalString('Handshake timed out', recorder.failureMessages[0],
        'the failure is a handshake timeout');
    }
  }

  // Fresh handshake is not expired.
  {
    const alice: TestIdentity = identity();
    const bob: TestIdentity = identity();
    const aliceManager: NoiseSessionManager = manager(alice);

    t.isNotNull(aliceManager.initiateHandshake(bob.peerID), 'message 1 is produced');

    aliceManager.cleanupStaleHandshakes(Date.now() + 9000);

    const session: NoiseSession | null = aliceManager.getSession(bob.peerID);
    t.isNotNull(session, 'the session survives');
    if (session !== null) {
      t.isTrue(session.isHandshaking(), 'the fresh handshake is still handshaking');
    }
  }

  // Expired handshake can be re-initiated immediately.
  {
    const alice: TestIdentity = identity();
    const bob: TestIdentity = identity();
    const aliceManager: NoiseSessionManager = manager(alice);

    t.isNotNull(aliceManager.initiateHandshake(bob.peerID), 'message 1 is produced');
    aliceManager.cleanupStaleHandshakes(Date.now() + 11000);

    t.isNotNull(aliceManager.initiateHandshake(bob.peerID),
      'handshake restarts after expiry');
    const session: NoiseSession | null = aliceManager.getSession(bob.peerID);
    t.isNotNull(session, 'the restarted session exists');
    if (session !== null) {
      t.isTrue(session.isHandshaking(), 'the restarted session is handshaking');
    }
  }

  // Established session is never expired by the sweep.
  {
    const alice: TestIdentity = identity();
    const bob: TestIdentity = identity();
    const aliceManager: NoiseSessionManager = manager(alice);
    const bobManager: NoiseSessionManager = manager(bob);
    completeHandshake(t, aliceManager, alice.peerID, bobManager, bob.peerID);
    const aliceSession: NoiseSession | null = aliceManager.getSession(bob.peerID);
    const bobSession: NoiseSession | null = bobManager.getSession(alice.peerID);
    t.isNotNull(aliceSession, 'alice session established');
    t.isNotNull(bobSession, 'bob session established');

    aliceManager.cleanupStaleHandshakes(Date.now() + 60000);
    bobManager.cleanupStaleHandshakes(Date.now() + 60000);

    t.isTrue(aliceSession === aliceManager.getSession(bob.peerID),
      'alice session survives the sweep');
    t.isTrue(bobSession === bobManager.getSession(alice.peerID),
      'bob session survives the sweep');
    t.isTrue(aliceManager.hasEstablishedSession(bob.peerID), 'alice link established');
    t.isTrue(bobManager.hasEstablishedSession(alice.peerID), 'bob link established');

    const plaintext: Uint8Array = ByteUtils.utf8Encode('still alive');
    const ciphertext: Uint8Array = aliceManager.encrypt(plaintext, bob.peerID);
    t.equalBytes(plaintext, bobManager.decrypt(ciphertext, alice.peerID),
      'transport still works after the sweep');
  }

  // Stale responder candidate expires while the established session survives.
  {
    const alice: TestIdentity = identity();
    const bob: TestIdentity = identity();
    const aliceManager: NoiseSessionManager = manager(alice);
    const bobManager: NoiseSessionManager = manager(bob);
    completeHandshake(t, aliceManager, alice.peerID, bobManager, bob.peerID);
    const established: NoiseSession | null = aliceManager.getSession(bob.peerID);
    t.isNotNull(established, 'alice session established');

    // Bob comes back and starts a replacement handshake: alice keeps the
    // established session and parks the new handshake as a responder candidate.
    const replacementManager: NoiseSessionManager = manager(bob);
    const message1: Uint8Array | null = replacementManager.initiateHandshake(alice.peerID);
    if (message1 === null) {
      throw new Error('replacement message 1 missing');
    }
    t.isNotNull(aliceManager.processHandshakeMessage(bob.peerID, message1),
      'the replacement handshake is answered');
    t.isTrue(established === aliceManager.getSession(bob.peerID),
      'the working session is untouched by the candidate');

    // Bob never finishes (message 2 lost): the candidate must expire
    // without touching the working session.
    aliceManager.cleanupStaleHandshakes(Date.now() + 11000);

    t.isTrue(established === aliceManager.getSession(bob.peerID),
      'the working session survives the candidate expiry');
    t.isTrue(aliceManager.hasEstablishedSession(bob.peerID), 'the link stays established');
    const plaintext: Uint8Array = ByteUtils.utf8Encode('unharmed');
    const ciphertext: Uint8Array = aliceManager.encrypt(plaintext, bob.peerID);
    t.equalBytes(plaintext, bobManager.decrypt(ciphertext, alice.peerID),
      'transport survives the candidate expiry');
  }

  // --- NoiseSessionManagerIdentityBindingTest ---

  // Valid derived identities establish in initiator and responder roles.
  {
    const alice: TestIdentity = identity();
    const bob: TestIdentity = identity();
    const aliceManager: NoiseSessionManager = manager(alice);
    const bobManager: NoiseSessionManager = manager(bob);
    completeHandshake(t, aliceManager, alice.peerID, bobManager, bob.peerID);

    t.isTrue(aliceManager.hasEstablishedSession(bob.peerID), 'alice link established');
    t.isTrue(bobManager.hasEstablishedSession(alice.peerID), 'bob link established');
    const aliceRemote: Uint8Array | null = aliceManager.getRemoteStaticKey(bob.peerID);
    const bobRemote: Uint8Array | null = bobManager.getRemoteStaticKey(alice.peerID);
    t.isNotNull(aliceRemote, 'alice sees the remote static key');
    t.isNotNull(bobRemote, 'bob sees the remote static key');
    if (aliceRemote !== null && bobRemote !== null) {
      t.equalBytes(bob.publicKey, aliceRemote, 'alice bound to bob static key');
      t.equalBytes(alice.publicKey, bobRemote, 'bob bound to alice static key');
    }

    const plaintext: Uint8Array = ByteUtils.utf8Encode('bound transport');
    const aliceSession: AuthenticatedNoiseSession | null =
      aliceManager.getAuthenticatedSession(bob.peerID);
    const bobSession: AuthenticatedNoiseSession | null =
      bobManager.getAuthenticatedSession(alice.peerID);
    t.isNotNull(aliceSession, 'alice binding exists');
    t.isNotNull(bobSession, 'bob binding exists');
    if (aliceSession !== null && bobSession !== null) {
      const ciphertext: Uint8Array =
        aliceManager.encryptForSession(plaintext, bob.peerID, aliceSession);
      const decrypted = bobManager.decryptWithSession(ciphertext, alice.peerID);
      t.equalBytes(plaintext, decrypted.getPlaintext(), 'generation-bound transport works');
      t.equalBytes(bobSession.getSessionToken(),
        decrypted.getAuthenticatedSession().getSessionToken(),
        'the decryption is bound to bob generation token');
    }
  }

  // Initiator rejects the remote static key before returning message three.
  {
    const alice: TestIdentity = identity();
    const bob: TestIdentity = identity();
    const victim: TestIdentity = identity();
    const aliceManager: NoiseSessionManager = manager(alice);
    const bobManager: NoiseSessionManager = manager(bob);
    const recorder: CallbackRecorder = new CallbackRecorder();
    aliceManager.onSessionEstablished = recorder.onSessionEstablished;

    const message1: Uint8Array | null = aliceManager.initiateHandshake(victim.peerID);
    if (message1 === null) {
      throw new Error('message 1 missing');
    }
    const message2: Uint8Array | null = bobManager.processHandshakeMessage(alice.peerID, message1);
    if (message2 === null) {
      throw new Error('message 2 missing');
    }

    expectIdentityMismatch(t, (): void => {
      aliceManager.processHandshakeMessage(victim.peerID, message2);
    });

    t.isFalse(aliceManager.hasEstablishedSession(victim.peerID),
      'no session survives the mismatch');
    t.isNull(aliceManager.getSession(victim.peerID), 'the mismatched session is removed');
    t.equalNumber(0, recorder.establishedCount(),
      'no authenticated callback escapes a mismatched initiator');
  }

  // Responder rejects an authenticated initiator key under a different claimed ID.
  {
    const alice: TestIdentity = identity();
    const bob: TestIdentity = identity();
    const victim: TestIdentity = identity();
    const aliceManager: NoiseSessionManager = manager(alice);
    const bobManager: NoiseSessionManager = manager(bob);
    const recorder: CallbackRecorder = new CallbackRecorder();
    bobManager.onSessionEstablished = recorder.onSessionEstablished;

    const message1: Uint8Array | null = aliceManager.initiateHandshake(bob.peerID);
    if (message1 === null) {
      throw new Error('message 1 missing');
    }
    const message2: Uint8Array | null =
      bobManager.processHandshakeMessage(victim.peerID, message1);
    if (message2 === null) {
      throw new Error('message 2 missing');
    }
    const message3: Uint8Array | null =
      aliceManager.processHandshakeMessage(bob.peerID, message2);
    if (message3 === null) {
      throw new Error('message 3 missing');
    }

    expectIdentityMismatch(t, (): void => {
      bobManager.processHandshakeMessage(victim.peerID, message3);
    });

    t.isFalse(bobManager.hasEstablishedSession(victim.peerID),
      'no session survives the mismatch');
    t.isNull(bobManager.getSession(victim.peerID), 'the mismatched session is removed');
    t.equalNumber(0, recorder.establishedCount(),
      'no authenticated callback escapes a mismatched responder');
  }

  // Mismatched responder replacement preserves the established session and
  // transport keys.
  {
    const alice: TestIdentity = identity();
    const bob: TestIdentity = identity();
    const attacker: TestIdentity = identity();
    const aliceManager: NoiseSessionManager = manager(alice);
    const bobManager: NoiseSessionManager = manager(bob);
    const attackerManager: NoiseSessionManager = manager(attacker);
    const recorder: CallbackRecorder = new CallbackRecorder();
    aliceManager.onSessionEstablished = recorder.onSessionEstablished;

    completeHandshake(t, aliceManager, alice.peerID, bobManager, bob.peerID);
    const originalSession: NoiseSession | null = aliceManager.getSession(bob.peerID);
    t.isNotNull(originalSession, 'original session established');
    t.equalNumber(1, recorder.establishedCount(), 'one authenticated callback fired');

    const attackerMessage1: Uint8Array | null =
      attackerManager.initiateHandshake(alice.peerID);
    if (attackerMessage1 === null) {
      throw new Error('attacker message 1 missing');
    }
    const aliceMessage2: Uint8Array | null =
      aliceManager.processHandshakeMessage(bob.peerID, attackerMessage1);
    if (aliceMessage2 === null) {
      throw new Error('alice message 2 missing');
    }
    const attackerMessage3: Uint8Array | null =
      attackerManager.processHandshakeMessage(alice.peerID, aliceMessage2);
    if (attackerMessage3 === null) {
      throw new Error('attacker message 3 missing');
    }

    expectIdentityMismatch(t, (): void => {
      aliceManager.processHandshakeMessage(bob.peerID, attackerMessage3);
    });

    t.isTrue(originalSession === aliceManager.getSession(bob.peerID),
      'the rejected candidate does not replace the working session');
    t.isTrue(aliceManager.hasEstablishedSession(bob.peerID), 'the link stays established');
    const remoteKey: Uint8Array | null = aliceManager.getRemoteStaticKey(bob.peerID);
    t.isNotNull(remoteKey, 'remote static key still bound');
    if (remoteKey !== null) {
      t.equalBytes(bob.publicKey, remoteKey, 'the working binding is intact');
    }
    t.equalNumber(1, recorder.establishedCount(),
      'the rejected replacement fires no authentication callback');

    const plaintext: Uint8Array = ByteUtils.utf8Encode('original session survives');
    const ciphertext: Uint8Array = aliceManager.encrypt(plaintext, bob.peerID);
    t.equalBytes(plaintext, bobManager.decrypt(ciphertext, alice.peerID),
      'the original transport still works');

    // The failed candidate must be fully removed so a later valid restart
    // can replace cleanly.
    const restartedBobManager: NoiseSessionManager = manager(bob);
    const validMessage1: Uint8Array | null =
      restartedBobManager.initiateHandshake(alice.peerID);
    if (validMessage1 === null) {
      throw new Error('valid restart message 1 missing');
    }
    const validMessage2: Uint8Array | null =
      aliceManager.processHandshakeMessage(bob.peerID, validMessage1);
    if (validMessage2 === null) {
      throw new Error('valid restart message 2 missing');
    }
    const validMessage3: Uint8Array | null =
      restartedBobManager.processHandshakeMessage(alice.peerID, validMessage2);
    if (validMessage3 === null) {
      throw new Error('valid restart message 3 missing');
    }
    t.isNull(aliceManager.processHandshakeMessage(bob.peerID, validMessage3),
      'the valid replacement completes without a response');
    t.equalNumber(2, recorder.establishedCount(),
      'the valid replacement fires the authentication callback');

    const retriedPlaintext: Uint8Array = ByteUtils.utf8Encode('valid retry promoted');
    const retriedCiphertext: Uint8Array =
      restartedBobManager.encrypt(retriedPlaintext, alice.peerID);
    t.equalBytes(retriedPlaintext, aliceManager.decrypt(retriedCiphertext, bob.peerID),
      'the replacement transport works');
  }

  // Valid responder replacement promotes only after the bound handshake
  // completes, and stale generation tokens are rejected.
  {
    const alice: TestIdentity = identity();
    const bob: TestIdentity = identity();
    const aliceManager: NoiseSessionManager = manager(alice);
    const originalBobManager: NoiseSessionManager = manager(bob);
    const recorder: CallbackRecorder = new CallbackRecorder();
    aliceManager.onSessionEstablished = recorder.onSessionEstablished;

    completeHandshake(t, aliceManager, alice.peerID, originalBobManager, bob.peerID);
    const originalSession: NoiseSession | null = aliceManager.getSession(bob.peerID);
    const originalBinding: AuthenticatedNoiseSession | null =
      aliceManager.getAuthenticatedSession(bob.peerID);
    t.isNotNull(originalSession, 'original session established');
    t.isNotNull(originalBinding, 'original binding exists');

    // Simulate Bob restarting with the same persistent static identity and
    // no session state.
    const restartedBobManager: NoiseSessionManager = manager(bob);
    const message1: Uint8Array | null = restartedBobManager.initiateHandshake(alice.peerID);
    if (message1 === null) {
      throw new Error('restart message 1 missing');
    }
    const message2: Uint8Array | null =
      aliceManager.processHandshakeMessage(bob.peerID, message1);
    if (message2 === null) {
      throw new Error('restart message 2 missing');
    }
    const message3: Uint8Array | null =
      restartedBobManager.processHandshakeMessage(alice.peerID, message2);
    if (message3 === null) {
      throw new Error('restart message 3 missing');
    }
    t.isNull(aliceManager.processHandshakeMessage(bob.peerID, message3),
      'the replacement completes without a response');

    t.isTrue(originalSession !== null &&
      originalSession !== aliceManager.getSession(bob.peerID),
      'the replacement swapped the session object');
    t.isTrue(aliceManager.hasEstablishedSession(bob.peerID), 'the link stays established');
    const remoteKey: Uint8Array | null = aliceManager.getRemoteStaticKey(bob.peerID);
    t.isNotNull(remoteKey, 'remote static key still bound');
    if (remoteKey !== null) {
      t.equalBytes(bob.publicKey, remoteKey, 'the binding still matches bob');
    }
    t.equalNumber(2, recorder.establishedCount(), 'both authentications fired callbacks');
    const replacementBinding: AuthenticatedNoiseSession | null =
      aliceManager.getAuthenticatedSession(bob.peerID);
    t.isNotNull(replacementBinding, 'replacement binding exists');
    if (originalBinding !== null && replacementBinding !== null) {
      t.isFalse(bytesEqual(originalBinding.getSessionToken(),
        replacementBinding.getSessionToken()),
        'the replacement generation has a fresh token');
      t.throws((): void => {
        aliceManager.encryptForSession(ByteUtils.utf8Encode('stale generation'),
          bob.peerID, originalBinding);
      }, 'stale generation-bound encryption is rejected');
    }

    const plaintext: Uint8Array = ByteUtils.utf8Encode('replacement transport');
    const ciphertext: Uint8Array =
      restartedBobManager.encrypt(plaintext, alice.peerID);
    t.equalBytes(plaintext, aliceManager.decrypt(ciphertext, bob.peerID),
      'the replacement transport works');
  }

  // withAuthenticatedSession runs for the live generation and rejects a
  // stale one (the event-loop form of the Android lease test).
  {
    const alice: TestIdentity = identity();
    const bob: TestIdentity = identity();
    const aliceManager: NoiseSessionManager = manager(alice);
    const originalBobManager: NoiseSessionManager = manager(bob);
    completeHandshake(t, aliceManager, alice.peerID, originalBobManager, bob.peerID);
    const binding: AuthenticatedNoiseSession | null =
      aliceManager.getAuthenticatedSession(bob.peerID);
    t.isNotNull(binding, 'binding exists');
    if (binding !== null) {
      let actionRan: boolean = false;
      t.isTrue(aliceManager.withAuthenticatedSession(bob.peerID, binding, (): boolean => {
        actionRan = true;
        return true;
      }) && actionRan, 'the action runs for the current generation');

      // Replace the generation, then the old binding must be rejected.
      const restartedBobManager: NoiseSessionManager = manager(bob);
      const message1: Uint8Array | null = restartedBobManager.initiateHandshake(alice.peerID);
      if (message1 === null) {
        throw new Error('restart message 1 missing');
      }
      const message2: Uint8Array | null =
        aliceManager.processHandshakeMessage(bob.peerID, message1);
      if (message2 === null) {
        throw new Error('restart message 2 missing');
      }
      const message3: Uint8Array | null =
        restartedBobManager.processHandshakeMessage(alice.peerID, message2);
      if (message3 === null) {
        throw new Error('restart message 3 missing');
      }
      t.isNull(aliceManager.processHandshakeMessage(bob.peerID, message3),
        'the replacement completes');

      let staleActionRan: boolean = false;
      t.isFalse(aliceManager.withAuthenticatedSession(bob.peerID, binding, (): boolean => {
        staleActionRan = true;
        return true;
      }), 'a stale generation is rejected');
      t.isFalse(staleActionRan, 'the stale action never runs');
    }
  }

  // Fresh initiator replacement preserves the active session until
  // authentication completes.
  {
    const alice: TestIdentity = identity();
    const bob: TestIdentity = identity();
    const aliceManager: NoiseSessionManager = manager(alice);
    const originalBobManager: NoiseSessionManager = manager(bob);
    completeHandshake(t, aliceManager, alice.peerID, originalBobManager, bob.peerID);
    const originalSession: NoiseSession | null = aliceManager.getSession(bob.peerID);
    t.isNotNull(originalSession, 'original session established');

    const restartedBobManager: NoiseSessionManager = manager(bob);
    const message1: Uint8Array | null =
      aliceManager.initiateHandshake(bob.peerID, true);
    if (message1 === null) {
      throw new Error('replacement message 1 missing');
    }
    t.isTrue(originalSession === aliceManager.getSession(bob.peerID),
      'the working session is parked during the replacement');
    t.isTrue(aliceManager.hasEstablishedSession(bob.peerID), 'the link stays established');

    const message2: Uint8Array | null =
      restartedBobManager.processHandshakeMessage(alice.peerID, message1);
    if (message2 === null) {
      throw new Error('replacement message 2 missing');
    }
    const message3: Uint8Array | null =
      aliceManager.processHandshakeMessage(bob.peerID, message2);
    if (message3 === null) {
      throw new Error('replacement message 3 missing');
    }
    t.isNull(restartedBobManager.processHandshakeMessage(alice.peerID, message3),
      'the replacement completes without a response');

    t.isTrue(originalSession !== null &&
      originalSession !== aliceManager.getSession(bob.peerID),
      'the replacement swapped the session object');
    const plaintext: Uint8Array = ByteUtils.utf8Encode('fresh link authenticated');
    const ciphertext: Uint8Array = aliceManager.encrypt(plaintext, bob.peerID);
    t.equalBytes(plaintext, restartedBobManager.decrypt(ciphertext, alice.peerID),
      'the fresh link transports');
  }

  // Simultaneous initiator replacements use the peer ID tie break and complete.
  {
    const alice: TestIdentity = identity();
    const bob: TestIdentity = identity();
    const aliceManager: NoiseSessionManager = manager(alice);
    const bobManager: NoiseSessionManager = manager(bob);
    completeHandshake(t, aliceManager, alice.peerID, bobManager, bob.peerID);

    const originalAliceSession: NoiseSession | null = aliceManager.getSession(bob.peerID);
    const originalBobSession: NoiseSession | null = bobManager.getSession(alice.peerID);
    const aliceMessage1: Uint8Array | null =
      aliceManager.initiateHandshake(bob.peerID, true);
    const bobMessage1: Uint8Array | null =
      bobManager.initiateHandshake(alice.peerID, true);
    if (aliceMessage1 === null || bobMessage1 === null) {
      throw new Error('replacement initiations missing');
    }

    const aliceCollisionResponse: Uint8Array | null =
      aliceManager.processHandshakeMessage(bob.peerID, bobMessage1);
    const bobCollisionResponse: Uint8Array | null =
      bobManager.processHandshakeMessage(alice.peerID, aliceMessage1);

    if (alice.peerID < bob.peerID) {
      t.isNull(aliceCollisionResponse, 'the lower peer ID keeps its initiation');
      if (bobCollisionResponse === null) {
        throw new Error('collision message 2 missing');
      }
      const message3: Uint8Array | null =
        aliceManager.processHandshakeMessage(bob.peerID, bobCollisionResponse);
      if (message3 === null) {
        throw new Error('collision message 3 missing');
      }
      t.isNull(bobManager.processHandshakeMessage(alice.peerID, message3),
        'the collision completes');
    } else {
      t.isNull(bobCollisionResponse, 'the lower peer ID keeps its initiation');
      if (aliceCollisionResponse === null) {
        throw new Error('collision message 2 missing');
      }
      const message3: Uint8Array | null =
        bobManager.processHandshakeMessage(alice.peerID, aliceCollisionResponse);
      if (message3 === null) {
        throw new Error('collision message 3 missing');
      }
      t.isNull(aliceManager.processHandshakeMessage(bob.peerID, message3),
        'the collision completes');
    }

    t.isTrue(originalAliceSession !== null &&
      originalAliceSession !== aliceManager.getSession(bob.peerID),
      'the alice session was replaced');
    t.isTrue(originalBobSession !== null &&
      originalBobSession !== bobManager.getSession(alice.peerID),
      'the bob session was replaced');
    const plaintext: Uint8Array = ByteUtils.utf8Encode('collision replacement transport');
    const ciphertext: Uint8Array = aliceManager.encrypt(plaintext, bob.peerID);
    t.equalBytes(plaintext, bobManager.decrypt(ciphertext, alice.peerID),
      'the collision-replaced transport works');
  }

  // Simultaneous handshake collision matrix has one deterministic winner
  // (the four fixed Android identities, all six pairs).
  {
    const identities: TestIdentity[] = [
      identityFromPrivateKey(ByteUtils.hexToBytes(
        'e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1')),
      identityFromPrivateKey(ByteUtils.hexToBytes(
        '4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893')),
      identityFromPrivateKey(ByteUtils.hexToBytes(
        '77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a')),
      identityFromPrivateKey(ByteUtils.hexToBytes(
        '5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb'))
    ];

    for (let leftIndex: number = 0; leftIndex < identities.length; leftIndex++) {
      for (let rightIndex: number = leftIndex + 1;
        rightIndex < identities.length; rightIndex++) {
        const left: TestIdentity = identities[leftIndex];
        const right: TestIdentity = identities[rightIndex];
        const leftManager: NoiseSessionManager = manager(left);
        const rightManager: NoiseSessionManager = manager(right);
        const leftMessage1: Uint8Array | null = leftManager.initiateHandshake(right.peerID);
        const rightMessage1: Uint8Array | null = rightManager.initiateHandshake(left.peerID);
        if (leftMessage1 === null || rightMessage1 === null) {
          throw new Error('matrix initiations missing');
        }

        const leftResponse: Uint8Array | null =
          leftManager.processHandshakeMessage(right.peerID, rightMessage1);
        const rightResponse: Uint8Array | null =
          rightManager.processHandshakeMessage(left.peerID, leftMessage1);

        if (left.peerID < right.peerID) {
          t.isNull(leftResponse, 'the lower peer ID keeps its initiation');
          if (rightResponse === null) {
            throw new Error('matrix message 2 missing');
          }
          const message3: Uint8Array | null =
            leftManager.processHandshakeMessage(right.peerID, rightResponse);
          if (message3 === null) {
            throw new Error('matrix message 3 missing');
          }
          t.isNull(rightManager.processHandshakeMessage(left.peerID, message3),
            'the matrix handshake completes');
        } else {
          t.isNull(rightResponse, 'the lower peer ID keeps its initiation');
          if (leftResponse === null) {
            throw new Error('matrix message 2 missing');
          }
          const message3: Uint8Array | null =
            rightManager.processHandshakeMessage(left.peerID, leftResponse);
          if (message3 === null) {
            throw new Error('matrix message 3 missing');
          }
          t.isNull(leftManager.processHandshakeMessage(right.peerID, message3),
            'the matrix handshake completes');
        }

        t.isTrue(leftManager.hasEstablishedSession(right.peerID),
          'the left matrix link is established');
        t.isTrue(rightManager.hasEstablishedSession(left.peerID),
          'the right matrix link is established');
        const payload: Uint8Array =
          ByteUtils.utf8Encode('matrix-' + leftIndex + '-' + rightIndex);
        t.equalBytes(payload,
          rightManager.decrypt(leftManager.encrypt(payload, right.peerID), left.peerID),
          'the matrix transport works');
      }
    }
  }

  // Peer ID derivation rejects malformed keys and non-wire claims.
  {
    const peer: TestIdentity = identity();

    t.isTrue(NoisePeerIdentity.matchesClaimedPeerID(peer.peerID, peer.publicKey),
      'the own wire ID matches');
    t.isFalse(NoisePeerIdentity.matchesClaimedPeerID(peer.peerID.toUpperCase(), peer.publicKey),
      'an uppercase claim is rejected');
    t.isFalse(NoisePeerIdentity.matchesClaimedPeerID('not-a-wire-id', peer.publicKey),
      'a non-wire claim is rejected');
    t.isFalse(NoisePeerIdentity.matchesClaimedPeerID(peer.peerID, new Uint8Array(31)),
      'a short static key is rejected');
    t.isNull(NoisePeerIdentity.derivePeerID(new Uint8Array(31)),
      'derivation rejects short keys');
  }
}
