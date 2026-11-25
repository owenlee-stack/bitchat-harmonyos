/**
 * Noise crypto primitive golden tests (T009).
 *
 * ChaChaCore/ChaChaPoly vectors follow RFC 7539 (block function test vector
 * and the AEAD construction with the Noise nonce layout: packet counter in
 * words 14/15). The ChaChaPoly AEAD expected value was cross-verified
 * byte-for-byte against Node's chacha20-poly1305 (OpenSSL); the X25519
 * "cacophony e" vectors are lifted literally from the Android
 * NoiseExternalVectorTest.kt fixed ephemeral keys (the first 32 bytes of
 * handshake messages 1 and 2), and the RFC 7748 section 6.1 values were
 * cross-verified against Node's x25519.
 */
import { ChaChaCore, ChaChaPolyCipher } from '../../main/ets/service/noise/ChaCha20Poly1305';
import { Curve25519 } from '../../main/ets/service/noise/Curve25519';
import { NoisePrimitives } from '../../main/ets/service/noise/NoisePrimitives';
import { ByteUtils } from '../../main/ets/common/ByteUtils';
import { ContractAssert } from './ContractAssert';

function hexToBytes(hex: string): Uint8Array {
  return ByteUtils.hexToBytes(hex);
}

export function runNoisePrimitivesContractTests(t: ContractAssert): void {
  // ChaCha20 block function: RFC 7539 test vector (key 000102..1f,
  // counter 1, nonce 000000090000004a00000000).
  {
    const key: Uint8Array = hexToBytes(
      '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f');
    const nonce: Uint8Array = hexToBytes('000000090000004a00000000');
    const input: number[] = [];
    const output: number[] = [];
    for (let i: number = 0; i < 16; i++) {
      input.push(0);
      output.push(0);
    }
    ChaChaCore.initKey256(input, key, 0);
    input[12] = 1;
    input[13] = 0x09000000;
    input[14] = 0x4a000000;
    input[15] = 0;
    ChaChaCore.hash(output, input);
    const keystream: Uint8Array = new Uint8Array(64);
    for (let i: number = 0; i < 16; i++) {
      keystream[i * 4] = output[i] & 0xFF;
      keystream[i * 4 + 1] = (output[i] >>> 8) & 0xFF;
      keystream[i * 4 + 2] = (output[i] >>> 16) & 0xFF;
      keystream[i * 4 + 3] = (output[i] >>> 24) & 0xFF;
    }
    t.equalString(
      '10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4e' +
      'd2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e',
      ByteUtils.bytesToHex(keystream), 'ChaCha20 block function matches RFC 7539');
  }

  // ChaChaPoly AEAD: RFC 7539 A.5 inputs with the Noise nonce layout (n = 0),
  // expected value cross-verified against Node chacha20-poly1305.
  {
    const key: Uint8Array = hexToBytes(
      '808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f');
    const ad: Uint8Array = hexToBytes('50515253c0c1c2c3c4c5c6c7c8c9cacbcccdcecf');
    const plaintext: Uint8Array = ByteUtils.utf8Encode(
      "Ladies and Gentlemen of the class of '99: If I could offer you " +
      'only one tip for the future, sunscreen would be it.');
    const expected: Uint8Array = hexToBytes(
      '663d7ec45b29ceaaa35505b8c1b3d94613a50fd7e315a748d35a378670746af8' +
      '67ab3404fe7b7655b904162b408190f3f8c781815bb8724e4ac22ea6351d3846' +
      '8cd370aa8ffb19e96edc915893cc6e1861c2af01ab0fb02df97ea145499bb87d' +
      '44ec7d738272327290570a03658b27b11666' +
      '4692f531c901d7dd780c16328febe378');
    const sender: ChaChaPolyCipher = new ChaChaPolyCipher();
    sender.initializeKey(key, 0);
    const ciphertext: Uint8Array = new Uint8Array(plaintext.length + 16);
    const length: number = sender.encryptWithAd(ad, plaintext, 0, ciphertext, 0, plaintext.length);
    t.equalNumber(plaintext.length + 16, length, 'ChaChaPoly encrypt returns ct+tag length');
    t.equalBytes(expected, ciphertext, 'ChaChaPoly AEAD matches OpenSSL-generated golden bytes');

    const receiver: ChaChaPolyCipher = new ChaChaPolyCipher();
    receiver.initializeKey(key, 0);
    const decrypted: Uint8Array = new Uint8Array(length);
    const decryptedLength: number = receiver.decryptWithAd(ad, ciphertext, 0, decrypted, 0, length);
    t.equalNumber(plaintext.length, decryptedLength, 'ChaChaPoly decrypt strips the tag');
    t.equalBytes(plaintext, decrypted.subarray(0, decryptedLength), 'ChaChaPoly decrypt roundtrips');

    // tampering with any tag byte must fail closed
    const tampered: Uint8Array = new Uint8Array(ciphertext);
    tampered[tampered.length - 1] ^= 1;
    t.throws((): void => {
      const fresh: ChaChaPolyCipher = new ChaChaPolyCipher();
      fresh.initializeKey(key, 0);
      fresh.decryptWithAd(ad, tampered, 0, new Uint8Array(length), 0, length);
    }, 'tampered tag must be rejected');

    // a too-short buffer cannot carry a tag
    t.throws((): void => {
      const fresh: ChaChaPolyCipher = new ChaChaPolyCipher();
      fresh.initializeKey(key, 0);
      fresh.decryptWithAd(ad, hexToBytes('00112233'), 0, new Uint8Array(4), 0, 4);
    }, 'input shorter than the tag must be rejected');
  }

  // ChaChaPoly authentication binds nonce, ciphertext, tag and associated
  // data. Port of NoiseExternalVectorTest "ChaChaPoly authentication binds
  // nonce ciphertext tag and associated data".
  {
    const key: Uint8Array = new Uint8Array(32);
    for (let i: number = 0; i < key.length; i++) {
      key[i] = i;
    }
    const plaintext: Uint8Array = ByteUtils.utf8Encode('associated');
    const associatedData: Uint8Array = ByteUtils.utf8Encode('header');
    const sender: ChaChaPolyCipher = new ChaChaPolyCipher();
    const receiver: ChaChaPolyCipher = new ChaChaPolyCipher();
    const wrongAdReceiver: ChaChaPolyCipher = new ChaChaPolyCipher();
    sender.initializeKey(key, 0);
    receiver.initializeKey(key, 0);
    wrongAdReceiver.initializeKey(key, 0);
    sender.setNonce(7);
    receiver.setNonce(7);
    wrongAdReceiver.setNonce(7);
    const ciphertext: Uint8Array = new Uint8Array(plaintext.length + sender.getMacLength());
    const length: number =
      sender.encryptWithAd(associatedData, plaintext, 0, ciphertext, 0, plaintext.length);

    t.throws((): void => {
      wrongAdReceiver.decryptWithAd(
        ByteUtils.utf8Encode('wrong'), ciphertext, 0, new Uint8Array(length), 0, length);
    }, 'wrong associated data must be rejected');
    const output: Uint8Array = new Uint8Array(length);
    const outputLength: number =
      receiver.decryptWithAd(associatedData, ciphertext, 0, output, 0, length);
    t.equalBytes(plaintext, output.subarray(0, outputLength), 'correct associated data decrypts');

    // an unset key passes plaintext through unchanged (Noise pre-key messages)
    const keyless: ChaChaPolyCipher = new ChaChaPolyCipher();
    t.isFalse(keyless.hasKey(), 'fresh cipher has no key');
    t.equalNumber(0, keyless.getMacLength(), 'keyless MAC length is zero');
    const passthrough: Uint8Array = new Uint8Array(4);
    const passthroughLength: number =
      keyless.encryptWithAd(null, hexToBytes('cafebabe'), 0, passthrough, 0, 4);
    t.equalNumber(4, passthroughLength, 'keyless encrypt returns the input length');
    t.equalBytes(hexToBytes('cafebabe'), passthrough, 'keyless encrypt passes bytes through');
  }

  // Noise two-output HKDF over HMAC-SHA256 (extract then two expand blocks).
  {
    const salt: Uint8Array = hexToBytes('000102030405060708090a0b0c');
    const ikm: Uint8Array = new Uint8Array(22);
    for (let i: number = 0; i < ikm.length; i++) {
      ikm[i] = 0x0b;
    }
    const output1: Uint8Array = new Uint8Array(32);
    const output2: Uint8Array = new Uint8Array(32);
    NoisePrimitives.hkdfSha256(salt, ikm, output1, output2);
    t.equalBytes(
      hexToBytes('b2a3d45126d31fb6828ef00d76c6d54e9c2bd4785e49c6ad86e327d89d0de940'),
      output1, 'HKDF output1 matches OpenSSL HKDF-SHA256');
    t.equalBytes(
      hexToBytes('8eeda1cbef2b03f30e053d5be784c2ab37f5a4de412baa10f01f456e9772aae7'),
      output2, 'HKDF output2 matches OpenSSL HKDF-SHA256');
  }

  // X25519: the cacophony e values from NoiseExternalVectorTest.kt are the
  // public keys of the fixed ephemeral private keys (the first 32 bytes of
  // handshake messages 1 and 2).
  {
    const initiatorEphemeral: Uint8Array = hexToBytes(
      '893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a');
    const responderEphemeral: Uint8Array = hexToBytes(
      'bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b');
    const initiatorE: Uint8Array = Curve25519.publicKeyFromPrivateKey(initiatorEphemeral);
    const responderE: Uint8Array = Curve25519.publicKeyFromPrivateKey(responderEphemeral);
    t.equalString('ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c7944',
      ByteUtils.bytesToHex(initiatorE), 'initiator ephemeral public key matches cacophony e');
    t.equalString('95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f144808843',
      ByteUtils.bytesToHex(responderE), 'responder ephemeral public key matches cacophony e');

    // the DH is symmetric
    const sharedInitiator: Uint8Array = Curve25519.sharedSecret(initiatorEphemeral, responderE);
    const sharedResponder: Uint8Array = Curve25519.sharedSecret(responderEphemeral, initiatorE);
    t.equalBytes(sharedInitiator, sharedResponder, 'X25519 shared secret is symmetric');
  }

  // X25519: RFC 7748 section 6.1 Diffie-Hellman example.
  {
    const alicePrivate: Uint8Array = hexToBytes(
      '77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a');
    const alicePublic: Uint8Array = hexToBytes(
      '8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a');
    const bobPrivate: Uint8Array = hexToBytes(
      '5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb');
    const bobPublic: Uint8Array = hexToBytes(
      'de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f');
    const shared: Uint8Array = hexToBytes(
      '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742');
    t.equalBytes(alicePublic, Curve25519.publicKeyFromPrivateKey(alicePrivate),
      'RFC 7748 Alice public key');
    t.equalBytes(bobPublic, Curve25519.publicKeyFromPrivateKey(bobPrivate),
      'RFC 7748 Bob public key');
    t.equalBytes(shared, Curve25519.sharedSecret(alicePrivate, bobPublic),
      'RFC 7748 shared secret');
    t.equalBytes(shared, Curve25519.sharedSecret(bobPrivate, alicePublic),
      'RFC 7748 shared secret is symmetric');
  }
}
