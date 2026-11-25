/**
 * Noise X seal golden tests (T062).
 *
 * The X transcript vectors are the Cacophony vectors for
 * Noise_X_25519_ChaChaPoly_SHA256 from the official Noise test
 * vector set (flynn/noise vectors.txt): fixed initiator/responder
 * static keys, fixed initiator ephemeral, optional "notsecret"
 * prologue and handshake/transport payloads - vector values
 * unchanged. The seal cases pin the courier-envelope semantics:
 * one-way X seal message (e || enc(s) || enc(payload)), sender
 * identity authenticated inside the ciphertext, split() transport
 * pair continuing the turn order and fail-closed open().
 */
import { Curve25519 } from '../../main/ets/service/noise/Curve25519';
import { NoisePeerIdentity } from '../../main/ets/service/noise/NoisePeerIdentity';
import {
  NoiseXHandshake,
  NoiseXSeal,
  NoiseXSealOpenResult
} from '../../main/ets/service/noise/NoiseXSeal';
import { ChaChaPolyCipher } from '../../main/ets/service/noise/ChaCha20Poly1305';
import {
  NoiseHandshakeAction,
  NoiseHandshakeRole
} from '../../main/ets/service/noise/NoiseXXHandshake';
import { ByteUtils } from '../../main/ets/common/ByteUtils';
import { ContractAssert } from './ContractAssert';

const VECTOR_INIT_STATIC: string =
  '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
const VECTOR_RESP_STATIC: string =
  '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20';
const VECTOR_INIT_EPHEMERAL: string =
  '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f';
const VECTOR_PROLOGUE: string = '6e6f74736563726574';
const VECTOR_PAYLOAD: string = '746573745f6d73675f30';
const VECTOR_EMPTY_MSG_0: string =
  '358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254' +
  '8cccfba3094925ef50f41bb45d6e69936ad15fcba0c3479a46afb577d3459497' +
  'de729f4d8d615d5886e52f4f888dd49490ed46957206fa937490058feca88e4c';
const VECTOR_PAYLOAD_MSG_0: string =
  '358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254' +
  '8cccfba3094925ef50f41bb45d6e69936ad15fcba0c3479a46afb577d3459497' +
  'de729f4d8d615d5886e52f4f888dd49486d56a823c51b82cc9bbf955b0358da7' +
  '4bdd0b077ee1f02b887f';
const VECTOR_PROLOGUE_MSG_0: string =
  '358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254' +
  '8cccfba3094925ef50f41bb45d6e69936ad15fcba0c3479a46afb577d3459497' +
  'a2b1b0c7f3c1107df1feeb7d2e340fd8d5f49ce97438f6953faa0fd6fa333a9e';
const VECTOR_PROLOGUE_PAYLOAD_MSG_0: string =
  '358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254' +
  '8cccfba3094925ef50f41bb45d6e69936ad15fcba0c3479a46afb577d3459497' +
  'a2b1b0c7f3c1107df1feeb7d2e340fd886d56a823c51b82cc9bbef609fcb249a' +
  'a5dc6bfae8b03f645e11';
const VECTOR_TRANSPORT_1_PAYLOAD: string = '79656c6c6f777375626d6172696e65';
const VECTOR_TRANSPORT_1_CIPHERTEXT: string =
  '2e04749040fde470ab93dda9ca2d7dc69896d0c564d0898755a09830735187';
const VECTOR_TRANSPORT_2_PAYLOAD: string = '7375626d6172696e6579656c6c6f77';
const VECTOR_TRANSPORT_2_CIPHERTEXT: string =
  '11ca4c30bd3b563c23f5a5ae83844d038b1ae8ac7ed4e7e788ad9cdfb56c39';

function hexToBytes(hex: string): Uint8Array {
  return ByteUtils.hexToBytes(hex);
}

function vectorInitiatorPublic(): Uint8Array {
  return Curve25519.publicKeyFromPrivateKey(hexToBytes(VECTOR_INIT_STATIC));
}

function vectorResponderPublic(): Uint8Array {
  return Curve25519.publicKeyFromPrivateKey(hexToBytes(VECTOR_RESP_STATIC));
}

function vectorEphemeralSource(): Uint8Array {
  return hexToBytes(VECTOR_INIT_EPHEMERAL);
}

function makeVectorInitiator(prologue: Uint8Array | null): NoiseXHandshake {
  const handshake: NoiseXHandshake =
    new NoiseXHandshake(NoiseHandshakeRole.INITIATOR, null);
  if (prologue !== null) {
    handshake.setPrologue(prologue);
  }
  handshake.getLocalKeyPair().setPrivateKey(hexToBytes(VECTOR_INIT_STATIC));
  handshake.getRemotePublicKey().setPublicKey(vectorResponderPublic());
  handshake.getFixedEphemeralKey().setPrivateKey(hexToBytes(VECTOR_INIT_EPHEMERAL));
  handshake.start();
  return handshake;
}

function makeVectorResponder(prologue: Uint8Array | null): NoiseXHandshake {
  const handshake: NoiseXHandshake =
    new NoiseXHandshake(NoiseHandshakeRole.RESPONDER, null);
  if (prologue !== null) {
    handshake.setPrologue(prologue);
  }
  handshake.getLocalKeyPair().setPrivateKey(hexToBytes(VECTOR_RESP_STATIC));
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
    'transport ciphertext matches the Cacophony vector');
  const decrypted: Uint8Array = new Uint8Array(encryptedLength);
  const decryptedLength: number =
    receiver.decryptWithAd(null, encrypted, 0, decrypted, 0, encryptedLength);
  t.equalBytes(payload, decrypted.subarray(0, decryptedLength),
    'transport plaintext roundtrips against the Cacophony vector');
}

export function runNoiseXSealContractTests(t: ContractAssert): void {
  // Cacophony X transcript: every handshake and transport byte matches.
  {
    const initiator: NoiseXHandshake = makeVectorInitiator(null);
    const responder: NoiseXHandshake = makeVectorResponder(null);

    const msg0: Uint8Array = initiator.writeMessage(new Uint8Array(0));
    t.equalBytes(hexToBytes(VECTOR_EMPTY_MSG_0), msg0,
      'X message 0 matches the Cacophony vector');
    t.equalBytes(new Uint8Array(0), responder.readMessage(msg0),
      'X message 0 payload roundtrips empty');
    t.equalNumber(96, msg0.length, 'the empty-payload X seal is 96 bytes');

    t.equalNumber(NoiseHandshakeAction.SPLIT, initiator.getAction(),
      'initiator reaches SPLIT after the one-way message');
    t.equalNumber(NoiseHandshakeAction.SPLIT, responder.getAction(),
      'responder reaches SPLIT after the one-way message');
    t.equalBytes(initiator.getHandshakeHash(), responder.getHandshakeHash(),
      'handshake hashes agree');

    const initiatorCiphers = initiator.split();
    const responderCiphers = responder.split();
    assertTransportMessage(initiatorCiphers.sender, responderCiphers.receiver,
      VECTOR_TRANSPORT_1_PAYLOAD, VECTOR_TRANSPORT_1_CIPHERTEXT, t);
    assertTransportMessage(responderCiphers.sender, initiatorCiphers.receiver,
      VECTOR_TRANSPORT_2_PAYLOAD, VECTOR_TRANSPORT_2_CIPHERTEXT, t);
  }

  // The seal facade reproduces every Cacophony variant byte for byte.
  {
    const emptySeal: Uint8Array = NoiseXSeal.seal(new Uint8Array(0),
      hexToBytes(VECTOR_INIT_STATIC), vectorResponderPublic(),
      vectorEphemeralSource, null);
    t.equalBytes(hexToBytes(VECTOR_EMPTY_MSG_0), emptySeal,
      'seal() with an empty payload matches the Cacophony vector');

    const payloadSeal: Uint8Array = NoiseXSeal.seal(hexToBytes(VECTOR_PAYLOAD),
      hexToBytes(VECTOR_INIT_STATIC), vectorResponderPublic(),
      vectorEphemeralSource, null);
    t.equalBytes(hexToBytes(VECTOR_PAYLOAD_MSG_0), payloadSeal,
      'seal() with a payload matches the Cacophony vector');
    t.equalNumber(106, payloadSeal.length, 'a 10-byte payload seals into 96 + 10 bytes');

    const prologueSeal: Uint8Array = NoiseXSeal.seal(new Uint8Array(0),
      hexToBytes(VECTOR_INIT_STATIC), vectorResponderPublic(),
      vectorEphemeralSource, hexToBytes(VECTOR_PROLOGUE));
    t.equalBytes(hexToBytes(VECTOR_PROLOGUE_MSG_0), prologueSeal,
      'seal() honors the prologue vector');

    const prologuePayloadSeal: Uint8Array = NoiseXSeal.seal(hexToBytes(VECTOR_PAYLOAD),
      hexToBytes(VECTOR_INIT_STATIC), vectorResponderPublic(),
      vectorEphemeralSource, hexToBytes(VECTOR_PROLOGUE));
    t.equalBytes(hexToBytes(VECTOR_PROLOGUE_PAYLOAD_MSG_0), prologuePayloadSeal,
      'seal() matches the prologue + payload vector');
  }

  // open() returns the payload and the authenticated sender identity.
  {
    const sealed: Uint8Array = NoiseXSeal.seal(hexToBytes(VECTOR_PAYLOAD),
      hexToBytes(VECTOR_INIT_STATIC), vectorResponderPublic(),
      vectorEphemeralSource, null);
    const opened: NoiseXSealOpenResult =
      NoiseXSeal.open(sealed, hexToBytes(VECTOR_RESP_STATIC), null);
    t.equalBytes(hexToBytes(VECTOR_PAYLOAD), opened.payload,
      'open() returns the sealed payload');
    t.equalBytes(vectorInitiatorPublic(), opened.senderStaticPublicKey,
      'open() authenticates the sender static key inside the ciphertext');
    t.equalString(
      NoisePeerIdentity.derivePeerID(opened.senderStaticPublicKey) ?? '',
      NoisePeerIdentity.derivePeerID(vectorInitiatorPublic()) ?? '',
      'the recipient derives the sender peer ID from the opened seal');
  }

  // Fail-closed open(): wrong keys, wrong prologue, tamper, short buffer.
  {
    const sealed: Uint8Array = NoiseXSeal.seal(hexToBytes(VECTOR_PAYLOAD),
      hexToBytes(VECTOR_INIT_STATIC), vectorResponderPublic(),
      vectorEphemeralSource, hexToBytes(VECTOR_PROLOGUE));
    t.throws((): void => {
      NoiseXSeal.open(sealed, hexToBytes(VECTOR_RESP_STATIC), null);
    }, 'opening without the sealing prologue must fail');
    t.throws((): void => {
      NoiseXSeal.open(sealed, hexToBytes(VECTOR_RESP_STATIC),
        ByteUtils.utf8Encode('wrong'));
    }, 'a mismatched prologue must fail');
    t.throws((): void => {
      NoiseXSeal.open(sealed, hexToBytes(VECTOR_INIT_STATIC),
        hexToBytes(VECTOR_PROLOGUE));
    }, 'opening with the wrong recipient key must fail');
    const tampered: Uint8Array = new Uint8Array(sealed);
    tampered[tampered.length - 1] ^= 1;
    t.throws((): void => {
      NoiseXSeal.open(tampered, hexToBytes(VECTOR_RESP_STATIC),
        hexToBytes(VECTOR_PROLOGUE));
    }, 'a tampered seal must fail authentication');
    t.throws((): void => {
      NoiseXSeal.open(new Uint8Array(95), hexToBytes(VECTOR_RESP_STATIC), null);
    }, 'a seal shorter than the 96-byte minimum must fail');
  }

  // State-machine guards: pre-message requirement, role rules, FAILED.
  {
    const noRemote: NoiseXHandshake =
      new NoiseXHandshake(NoiseHandshakeRole.INITIATOR, vectorEphemeralSource);
    noRemote.getLocalKeyPair().setPrivateKey(hexToBytes(VECTOR_INIT_STATIC));
    t.throws((): void => {
      noRemote.start();
    }, 'an X initiator without the responder static key cannot start');

    const responder: NoiseXHandshake = makeVectorResponder(null);
    t.throws((): void => {
      responder.writeMessage(null);
    }, 'the X responder cannot write the one-way message');

    const initiator: NoiseXHandshake = makeVectorInitiator(null);
    t.throws((): void => {
      initiator.start();
    }, 'starting a started X handshake must throw');

    const tamperedResponder: NoiseXHandshake = makeVectorResponder(null);
    const msg0: Uint8Array = makeVectorInitiator(null).writeMessage(new Uint8Array(0));
    const tampered0: Uint8Array = new Uint8Array(msg0);
    tampered0[40] ^= 1;
    t.throws((): void => {
      tamperedResponder.readMessage(tampered0);
    }, 'a tampered X seal must fail the responder');
    t.equalNumber(NoiseHandshakeAction.FAILED, tamperedResponder.getAction(),
      'failed read marks the X state FAILED');
  }

  // Sealed sizing and fresh-ephemeral seals open to the same payload.
  {
    t.equalNumber(96, NoiseXSeal.SEALED_OVERHEAD_BYTES,
      'the X seal overhead is e + enc(s) + payload tag');
    t.equalNumber(96, NoiseXSeal.sealedSize(0), 'an empty payload seals to 96 bytes');
    t.equalNumber(106, NoiseXSeal.sealedSize(10),
      'sealedSize adds the payload bytes to the overhead');

    let counter: number = 0;
    const freshEphemeral = (): Uint8Array => {
      const key: Uint8Array = new Uint8Array(32);
      // X25519 clamps the low three bits of byte 0, so step by 8 to
      // keep the scalars distinct.
      key[0] = counter * 8;
      counter += 1;
      return key;
    };
    const first: Uint8Array = NoiseXSeal.seal(hexToBytes(VECTOR_PAYLOAD),
      hexToBytes(VECTOR_INIT_STATIC), vectorResponderPublic(), freshEphemeral, null);
    const second: Uint8Array = NoiseXSeal.seal(hexToBytes(VECTOR_PAYLOAD),
      hexToBytes(VECTOR_INIT_STATIC), vectorResponderPublic(), freshEphemeral, null);
    t.isFalse(ByteUtils.equals(first, second),
      'fresh ephemerals produce distinct seals');
    t.equalNumber(first.length, second.length,
      'seal length is independent of the ephemeral choice');
    const openedFirst: NoiseXSealOpenResult =
      NoiseXSeal.open(first, hexToBytes(VECTOR_RESP_STATIC), null);
    const openedSecond: NoiseXSealOpenResult =
      NoiseXSeal.open(second, hexToBytes(VECTOR_RESP_STATIC), null);
    t.equalBytes(hexToBytes(VECTOR_PAYLOAD), openedFirst.payload,
      'the first fresh seal opens');
    t.equalBytes(hexToBytes(VECTOR_PAYLOAD), openedSecond.payload,
      'the second fresh seal opens');
    t.equalBytes(openedFirst.senderStaticPublicKey, openedSecond.senderStaticPublicKey,
      'both seals authenticate the same sender identity');
  }
}
