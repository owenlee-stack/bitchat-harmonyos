/**
 * Noise session golden tests (T032).
 *
 * The XX transcript vectors are the Cacophony/Noise-C vectors for
 * Noise_XX_25519_ChaChaPoly_SHA256, transcribed literally from the
 * Android NoiseExternalVectorTest.kt (fixed static/ephemeral keys,
 * "John Galt" prologue, three handshake payloads and three transport
 * payloads - vector values unchanged). The session-level cases pin
 * the bitchat NoiseSession semantics: XX message sizes, peer-ID
 * binding, <nonce(4)><ciphertext> transport framing, sliding replay
 * window and the rekey policy clock.
 */
import { ChaChaPolyCipher } from '../../main/ets/service/noise/ChaCha20Poly1305';
import { Curve25519 } from '../../main/ets/service/noise/Curve25519';
import { NoisePeerIdentity } from '../../main/ets/service/noise/NoisePeerIdentity';
import { NoiseSession, NoiseReplayWindow, NoiseSessionState } from '../../main/ets/service/noise/NoiseSession';
import { NoiseCipherStatePair } from '../../main/ets/service/noise/NoiseSymmetricState';
import {
  NoiseHandshakeAction,
  NoiseHandshakeRole,
  NoiseXXHandshake
} from '../../main/ets/service/noise/NoiseXXHandshake';
import { ByteUtils } from '../../main/ets/common/ByteUtils';
import { ContractAssert } from './ContractAssert';

const VECTOR_INITIATOR_STATIC: string =
  'e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1';
const VECTOR_RESPONDER_STATIC: string =
  '4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893';
const VECTOR_INITIATOR_EPHEMERAL: string =
  '893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a';
const VECTOR_RESPONDER_EPHEMERAL: string =
  'bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b';

function hexToBytes(hex: string): Uint8Array {
  return ByteUtils.hexToBytes(hex);
}

function makeVectorHandshake(role: NoiseHandshakeRole): NoiseXXHandshake {
  const handshake: NoiseXXHandshake = new NoiseXXHandshake(role, null);
  handshake.setPrologue(hexToBytes('4a6f686e2047616c74'));
  const staticPrivate: Uint8Array = role === NoiseHandshakeRole.INITIATOR
    ? hexToBytes(VECTOR_INITIATOR_STATIC)
    : hexToBytes(VECTOR_RESPONDER_STATIC);
  const ephemeralPrivate: Uint8Array = role === NoiseHandshakeRole.INITIATOR
    ? hexToBytes(VECTOR_INITIATOR_EPHEMERAL)
    : hexToBytes(VECTOR_RESPONDER_EPHEMERAL);
  handshake.getLocalKeyPair().setPrivateKey(staticPrivate);
  handshake.getFixedEphemeralKey().setPrivateKey(ephemeralPrivate);
  handshake.start();
  return handshake;
}

function assertTransportMessage(sender: ChaChaPolyCipher, receiver: ChaChaPolyCipher,
  payloadHex: string, ciphertextHex: string, t: ContractAssert): void {
  const payload: Uint8Array = hexToBytes(payloadHex);
  const encrypted: Uint8Array = new Uint8Array(payload.length + sender.getMacLength());
  const encryptedLength: number =
    sender.encryptWithAd(null, payload, 0, encrypted, 0, payload.length);
  t.equalBytes(hexToBytes(ciphertextHex), encrypted.subarray(0, encryptedLength),
    'transport ciphertext matches the Noise-C vector');
  const decrypted: Uint8Array = new Uint8Array(encryptedLength);
  const decryptedLength: number =
    receiver.decryptWithAd(null, encrypted, 0, decrypted, 0, encryptedLength);
  t.equalBytes(payload, decrypted.subarray(0, decryptedLength),
    'transport plaintext roundtrips against the Noise-C vector');
}

class NoiseSessionTestPair {
  initiator: NoiseSession;
  responder: NoiseSession;

  constructor(initiator: NoiseSession, responder: NoiseSession) {
    this.initiator = initiator;
    this.responder = responder;
  }
}

function establishSessionPair(t: ContractAssert, nowMs: () => number): NoiseSessionTestPair {
  const initiatorStatic: Uint8Array = hexToBytes(VECTOR_INITIATOR_STATIC);
  const responderStatic: Uint8Array = hexToBytes(VECTOR_RESPONDER_STATIC);
  const initiatorPublic: Uint8Array = Curve25519.publicKeyFromPrivateKey(initiatorStatic);
  const responderPublic: Uint8Array = Curve25519.publicKeyFromPrivateKey(responderStatic);
  const responderPeerID: string = NoisePeerIdentity.derivePeerID(responderPublic) ?? '';
  const initiatorPeerID: string = NoisePeerIdentity.derivePeerID(initiatorPublic) ?? '';
  const initiator: NoiseSession = new NoiseSession(responderPeerID, true,
    initiatorStatic, initiatorPublic, {
      generateEphemeralPrivateKey: (): Uint8Array => hexToBytes(VECTOR_INITIATOR_EPHEMERAL),
      nowMs: nowMs
    });
  const responder: NoiseSession = new NoiseSession(initiatorPeerID, false,
    responderStatic, responderPublic, {
      generateEphemeralPrivateKey: (): Uint8Array => hexToBytes(VECTOR_RESPONDER_EPHEMERAL),
      nowMs: nowMs
    });
  const m1: Uint8Array = initiator.startHandshake();
  t.equalNumber(32, m1.length, 'session XX message 1 is 32 bytes');
  const m2: Uint8Array | null = responder.processHandshakeMessage(m1);
  if (m2 === null) {
    t.isTrue(false, 'responder must produce XX message 2');
    return new NoiseSessionTestPair(initiator, responder);
  }
  t.equalNumber(96, m2.length, 'session XX message 2 is 96 bytes');
  const m3: Uint8Array | null = initiator.processHandshakeMessage(m2);
  if (m3 === null) {
    t.isTrue(false, 'initiator must produce XX message 3');
    return new NoiseSessionTestPair(initiator, responder);
  }
  t.equalNumber(64, m3.length, 'session XX message 3 is 48-byte encrypted static plus 16-byte tag');
  const finalResult: Uint8Array | null = responder.processHandshakeMessage(m3);
  t.isNull<Uint8Array>(finalResult, 'responder completes the handshake on message 3');
  t.isTrue(initiator.isEstablished(), 'initiator session is established');
  t.isTrue(responder.isEstablished(), 'responder session is established');
  return new NoiseSessionTestPair(initiator, responder);
}

export function runNoiseSessionContractTests(t: ContractAssert): void {
  // Noise-C XX transcript: every handshake and transport byte matches.
  {
    const initiator: NoiseXXHandshake = makeVectorHandshake(NoiseHandshakeRole.INITIATOR);
    const responder: NoiseXXHandshake = makeVectorHandshake(NoiseHandshakeRole.RESPONDER);

    const msg1: Uint8Array = initiator.writeMessage(hexToBytes('4c756477696720766f6e204d69736573'));
    t.equalBytes(hexToBytes(
      'ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c7944' +
      '4c756477696720766f6e204d69736573'),
      msg1, 'XX message 1 matches the Noise-C vector');
    t.equalBytes(hexToBytes('4c756477696720766f6e204d69736573'), responder.readMessage(msg1),
      'XX message 1 payload roundtrips');

    const msg2: Uint8Array = responder.writeMessage(hexToBytes('4d757272617920526f746862617264'));
    t.equalBytes(hexToBytes(
      '95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f144808843' +
      '81cbad1f276e038c48378ffce2b65285e08d6b68aaa3629a5a8639392490e5b9' +
      'bd5269c2f1e4f488ed8831161f19b7815528f8982ffe09be9b5c412f8a0db50f' +
      '8814c7194e83f23dbd8d162c9326ad'),
      msg2, 'XX message 2 matches the Noise-C vector');
    t.equalBytes(hexToBytes('4d757272617920526f746862617264'), initiator.readMessage(msg2),
      'XX message 2 payload roundtrips');

    const msg3: Uint8Array = initiator.writeMessage(hexToBytes('462e20412e20486179656b'));
    t.equalBytes(hexToBytes(
      'c7195ffacac1307ff99046f219750fc47693e23c3cb08b89c2af808b444850a8' +
      '0ae475b9df0f169ae80a89be0865b57f58c9fea0d4ec82a286427402f113e4b6' +
      'ae769a1d95941d49b25030'),
      msg3, 'XX message 3 matches the Noise-C vector');
    t.equalBytes(hexToBytes('462e20412e20486179656b'), responder.readMessage(msg3),
      'XX message 3 payload roundtrips');

    t.equalNumber(NoiseHandshakeAction.SPLIT, initiator.getAction(), 'initiator reaches SPLIT');
    t.equalNumber(NoiseHandshakeAction.SPLIT, responder.getAction(), 'responder reaches SPLIT');
    t.equalBytes(initiator.getHandshakeHash(), responder.getHandshakeHash(),
      'handshake hashes agree');

    const initiatorCiphers: NoiseCipherStatePair = initiator.split();
    const responderCiphers: NoiseCipherStatePair = responder.split();
    assertTransportMessage(responderCiphers.sender, initiatorCiphers.receiver,
      '4361726c204d656e676572',
      '96763ed773f8e47bb3712f0e29b3060ffc956ffc146cee53d5e1df', t);
    assertTransportMessage(initiatorCiphers.sender, responderCiphers.receiver,
      '4a65616e2d426170746973746520536179',
      '3e40f15f6f3a46ae446b253bf8b1d9ffb6ed9b174d272328ff91a7e2e5c79c07f5', t);
    assertTransportMessage(responderCiphers.sender, initiatorCiphers.receiver,
      '457567656e2042f6686d20766f6e2042617765726b',
      'eb3f3515110702e047a6c9da4478b6ead94873c11c0f2d710ddb3f09fce024b3' +
      'a58502ae3f', t);
  }

  // The state machine rejects invalid actions and a tampered handshake tag.
  {
    const initiator: NoiseXXHandshake = makeVectorHandshake(NoiseHandshakeRole.INITIATOR);
    const responder: NoiseXXHandshake = makeVectorHandshake(NoiseHandshakeRole.RESPONDER);
    t.throws((): void => {
      initiator.start();
    }, 'starting a started handshake must throw');
    t.throws((): void => {
      responder.writeMessage(null);
    }, 'responder cannot write before reading');

    const msg1: Uint8Array = initiator.writeMessage(hexToBytes('4c756477696720766f6e204d69736573'));
    responder.readMessage(msg1);
    const msg2: Uint8Array = responder.writeMessage(hexToBytes('4d757272617920526f746862617264'));
    const tampered: Uint8Array = new Uint8Array(msg2);
    tampered[tampered.length - 1] ^= 1;
    t.throws((): void => {
      initiator.readMessage(tampered);
    }, 'a tampered handshake tag must be rejected');
    t.equalNumber(NoiseHandshakeAction.FAILED, initiator.getAction(),
      'failed read marks the state FAILED');
  }

  // Session XX drive: sizes, binding, transport framing, replay protection.
  {
    const pair: NoiseSessionTestPair =
      establishSessionPair(t, (): number => Date.now());
    const handshakeHashA: Uint8Array | null = pair.initiator.getHandshakeHash();
    const handshakeHashB: Uint8Array | null = pair.responder.getHandshakeHash();
    t.isNotNull<Uint8Array>(handshakeHashA, 'initiator exposes a handshake hash');
    t.isNotNull<Uint8Array>(handshakeHashB, 'responder exposes a handshake hash');
    if (handshakeHashA !== null && handshakeHashB !== null) {
      t.equalBytes(handshakeHashA, handshakeHashB, 'session handshake hashes agree');
    }
    const message1: Uint8Array | null = pair.initiator.getHandshakeMessage1();
    t.isNotNull<Uint8Array>(message1, 'initiator keeps handshake message 1');
    if (message1 !== null) {
      t.equalNumber(32, message1.length, 'handshake message 1 retained at 32 bytes');
    }
    const remoteStatic: Uint8Array | null = pair.initiator.getRemoteStaticPublicKey();
    t.isNotNull<Uint8Array>(remoteStatic, 'initiator exposes the remote static key');
    if (remoteStatic !== null) {
      t.equalBytes(Curve25519.publicKeyFromPrivateKey(hexToBytes(VECTOR_RESPONDER_STATIC)),
        remoteStatic, 'remote static key matches the responder identity');
    }

    const frame: Uint8Array = pair.initiator.encrypt(ByteUtils.utf8Encode('hello'));
    t.equalNumber(4 + 5 + 16, frame.length, 'transport frame is nonce + ciphertext + tag');
    t.equalNumber(0, frame[0], 'first transport nonce prefix is zero');
    t.equalNumber(0, frame[1], 'first transport nonce prefix is zero');
    t.equalNumber(0, frame[2], 'first transport nonce prefix is zero');
    t.equalNumber(0, frame[3], 'first transport nonce prefix is zero');
    t.equalBytes(ByteUtils.utf8Encode('hello'), pair.responder.decrypt(frame),
      'transport roundtrips initiator to responder');
    t.equalNumber(1, pair.initiator.getMessagesSent(), 'encrypt counts the sent message');
    t.equalNumber(1, pair.responder.getMessagesReceived(), 'decrypt counts the received message');

    const reply: Uint8Array = pair.responder.encrypt(ByteUtils.utf8Encode('ok'));
    t.equalBytes(ByteUtils.utf8Encode('ok'), pair.initiator.decrypt(reply),
      'transport roundtrips responder to initiator');

    t.throws((): void => {
      pair.responder.decrypt(frame);
    }, 'a replayed transport frame must be rejected');

    const tamperedFrame: Uint8Array = new Uint8Array(frame);
    tamperedFrame[tamperedFrame.length - 1] ^= 1;
    t.throws((): void => {
      pair.responder.decrypt(tamperedFrame);
    }, 'a tampered transport frame must be rejected');
    const afterTamper: Uint8Array = pair.initiator.encrypt(ByteUtils.utf8Encode('still alive'));
    t.equalBytes(ByteUtils.utf8Encode('still alive'), pair.responder.decrypt(afterTamper),
      'valid traffic still flows after a rejected frame');
  }

  // Out-of-order but in-window nonces are accepted; the seen one replays closed.
  {
    const pair: NoiseSessionTestPair =
      establishSessionPair(t, (): number => Date.now());
    const first: Uint8Array = pair.initiator.encrypt(ByteUtils.utf8Encode('a'));
    const second: Uint8Array = pair.initiator.encrypt(ByteUtils.utf8Encode('b'));
    t.equalBytes(ByteUtils.utf8Encode('b'), pair.responder.decrypt(second),
      'the newer nonce decrypts first');
    t.equalBytes(ByteUtils.utf8Encode('a'), pair.responder.decrypt(first),
      'the older in-window nonce still decrypts');
    t.throws((): void => {
      pair.responder.decrypt(first);
    }, 'the already-seen older nonce is rejected on replay');
  }

  // Peer identity mismatch: a claimed peer ID that does not match the
  // authenticated remote static key fails the handshake.
  {
    const initiatorStatic: Uint8Array = hexToBytes(VECTOR_INITIATOR_STATIC);
    const responderStatic: Uint8Array = hexToBytes(VECTOR_RESPONDER_STATIC);
    const initiatorPublic: Uint8Array = Curve25519.publicKeyFromPrivateKey(initiatorStatic);
    const responderPublic: Uint8Array = Curve25519.publicKeyFromPrivateKey(responderStatic);
    const initiatorPeerID: string = NoisePeerIdentity.derivePeerID(initiatorPublic) ?? '';
    const initiator: NoiseSession = new NoiseSession('deadbeefdeadbeef', true,
      initiatorStatic, initiatorPublic, {
        generateEphemeralPrivateKey: (): Uint8Array => hexToBytes(VECTOR_INITIATOR_EPHEMERAL),
        nowMs: (): number => 1000
      });
    const responder: NoiseSession = new NoiseSession(initiatorPeerID, false,
      responderStatic, responderPublic, {
        generateEphemeralPrivateKey: (): Uint8Array => hexToBytes(VECTOR_RESPONDER_EPHEMERAL),
        nowMs: (): number => 1000
      });
    const m1: Uint8Array = initiator.startHandshake();
    const m2: Uint8Array | null = responder.processHandshakeMessage(m1);
    t.isNotNull<Uint8Array>(m2, 'responder answers message 1');
    if (m2 === null) {
      return;
    }
    t.throws((): void => {
      initiator.processHandshakeMessage(m2);
    }, 'a mismatched peer identity must fail the handshake');
    t.equalNumber(NoiseSessionState.FAILED, initiator.getState(),
      'initiator session is FAILED after identity mismatch');
    t.isFalse(initiator.isEstablished(), 'mismatched session is not established');
  }

  // Sliding replay window unit semantics (1024 entries, 128 bytes).
  {
    const window: NoiseReplayWindow = new NoiseReplayWindow();
    t.isTrue(window.isValid(0), 'a fresh window accepts nonce 0');
    window.markSeen(0);
    t.isFalse(window.isValid(0), 'the seen nonce is rejected');
    t.isTrue(window.isValid(1), 'a newer nonce is accepted');
    window.markSeen(1);
    t.isFalse(window.isValid(0), 'the older seen nonce stays rejected after the slide');
    t.isTrue(window.isValid(10), 'a gap nonce is accepted');
    window.markSeen(10);
    t.isTrue(window.isValid(5), 'an unseen in-window nonce is accepted');
    t.isFalse(window.isValid(10), 'the marked gap nonce is rejected');
    window.markSeen(2000);
    t.equalNumber(2000, window.getHighestReceivedNonce(), 'the highest nonce tracks the mark');
    t.isFalse(window.isValid(976), 'a nonce below the window is rejected');
    t.isTrue(window.isValid(977), 'a nonce at the window edge is accepted');
    t.isTrue(window.isValid(2001), 'a nonce above the highest is accepted');
    window.reset();
    t.isTrue(window.isValid(0), 'a reset window accepts nonce 0 again');
  }

  // Rekey policy: 1h time limit, 1000 encryption-service and 10000
  // session message limits (AppConstants.Noise).
  {
    t.equalNumber(3600000, NoiseSession.REKEY_TIME_LIMIT_MS, 'rekey time limit is 1 hour');
    t.equalNumber(1000, NoiseSession.REKEY_MESSAGE_LIMIT_ENCRYPTION,
      'encryption-service rekey limit is 1000 messages');
    t.equalNumber(10000, NoiseSession.REKEY_MESSAGE_LIMIT_SESSION,
      'session rekey limit is 10000 messages');
    let clock: number = 1000000;
    const pair: NoiseSessionTestPair =
      establishSessionPair(t, (): number => clock);
    t.isFalse(pair.initiator.needsRekey(), 'a fresh session does not need a rekey');
    t.isFalse(pair.responder.needsRekey(), 'a fresh responder session does not need a rekey');
    clock += NoiseSession.REKEY_TIME_LIMIT_MS + 1;
    t.isTrue(pair.initiator.needsRekey(), 'a session past the 1h limit needs a rekey');
    t.isTrue(pair.responder.needsRekey(), 'the responder tracks rekey on its own clock too');
  }

  // Static key validation and state errors fail closed.
  {
    const badKeys: NoiseSession = new NoiseSession('0011223344556677', true,
      new Uint8Array(31), new Uint8Array(32));
    t.equalNumber(NoiseSessionState.FAILED, badKeys.getState(),
      'a short static private key fails validation');
    t.throws((): void => {
      badKeys.startHandshake();
    }, 'a failed session cannot start a handshake');

    const responderStatic: Uint8Array = hexToBytes(VECTOR_RESPONDER_STATIC);
    const responderPublic: Uint8Array = Curve25519.publicKeyFromPrivateKey(responderStatic);
    const responderOnly: NoiseSession = new NoiseSession('0011223344556677', false,
      responderStatic, responderPublic);
    t.throws((): void => {
      responderOnly.startHandshake();
    }, 'only the initiator can start the handshake');
    t.throws((): void => {
      responderOnly.encrypt(hexToBytes('0011'));
    }, 'encrypting before establishment must throw');
    t.throws((): void => {
      responderOnly.decrypt(new Uint8Array(2));
    }, 'decrypting before establishment must throw');

    const pair: NoiseSessionTestPair =
      establishSessionPair(t, (): number => 5000);
    t.throws((): void => {
      pair.responder.decrypt(new Uint8Array(3));
    }, 'a payload shorter than the nonce prefix must throw');
    const frame: Uint8Array = pair.initiator.encrypt(ByteUtils.utf8Encode('x'));
    pair.responder.decrypt(frame);
    t.throws((): void => {
      pair.responder.decrypt(frame);
    }, 'replaying the frame after the short-payload probe still throws');
  }
}
