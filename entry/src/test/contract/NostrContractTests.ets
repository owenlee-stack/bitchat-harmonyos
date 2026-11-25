/**
 * Nostr protocol kernel contract tests (US12, T058): Android
 * NostrCrypto / NostrEvent / NostrIdentity / NostrProtocol /
 * RelayReconnectPolicy / relay-catalog parity.
 *
 *  - Secp256k1: BIP-340 official vectors 0-2 sign+verify exact,
 *    vector 3 verify-fails, key-validation bounds, ECDH symmetry;
 *  - XChaCha20Poly1305: draft-irtf-cfrg-xchacha-03 HChaCha20 subkey
 *    golden + AEAD_XCHACHA20_POLY1305 A.3.1 ciphertext/tag golden,
 *    round trip, tamper / wrong-key / short-input rejection;
 *  - Nip44: "v2:" round trips (ASCII + CJK), wrong-recipient and
 *    non-v2 prefix rejection;
 *  - NostrEvent: NIP-01 id serialization golden, Gson HTML-safe
 *    toJsonString golden, parse defaults / tag-anomaly matrix;
 *  - NostrIdentity: npub bech32 round trip, invalid key rejection;
 *  - NostrProtocol: NIP-17 seal/gift-wrap round trip with scripted
 *    randomness (22h max backdating reserves the 2h iOS slack),
 *    forged-seal rejection (signer != rumor pubkey, transplanted
 *    seal signature), timestamp randomization boundaries;
 *  - RelayReconnectPolicy: exponential backoff 1s..300s with
 *    saturation at 10 attempts; NostrRelayCatalog: four default
 *    relays + 48h/1h lookbacks + 48h15min age bound.
 */
import { ContractAssert } from './ContractAssert';
import { ByteUtils } from '../../main/ets/common/ByteUtils';
import { Bech32, Bech32Result } from '../../main/ets/service/nostr/Bech32';
import { Secp256k1 } from '../../main/ets/service/nostr/Secp256k1';
import { Nip44 } from '../../main/ets/service/nostr/Nip44';
import { XChaCha20Poly1305 } from '../../main/ets/service/nostr/XChaCha20Poly1305';
import { NostrEvent, NostrKind } from '../../main/ets/service/nostr/NostrEvent';
import { NostrIdentity } from '../../main/ets/service/nostr/NostrIdentity';
import { DecryptedPrivateMessage, NostrProtocol } from '../../main/ets/service/nostr/NostrProtocol';
import { NostrRandomSource } from '../../main/ets/service/nostr/NostrRandomSource';
import { RelayReconnectPolicy } from '../../main/ets/service/nostr/RelayReconnectPolicy';
import { NostrRelayCatalog } from '../../main/ets/service/nostr/NostrRelayCatalog';

/** BIP-340 vector 0 secret key (all-zero message/aux variants). */
const BIP340_ZEROS32: string = '0000000000000000000000000000000000000000000000000000000000000000';
const BIP340_V0_SEC: string = '0000000000000000000000000000000000000000000000000000000000000003';
const BIP340_V1_SEC: string =
  'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef';
const BIP340_V1_PUB: string =
  'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';
const BIP340_V2_SEC: string =
  'c90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b14e5c9';

/** Deterministic random source with explicit byte/int queues. */
class ScriptedNostrRandom implements NostrRandomSource {
  private readonly bytes: number[];
  private readonly ints: number[];
  private bytePos: number;
  private intPos: number;

  constructor() {
    this.bytes = [];
    this.ints = [];
    this.bytePos = 0;
    this.intPos = 0;
  }

  feedBytes(data: Uint8Array): void {
    for (let i: number = 0; i < data.length; i++) {
      this.bytes.push(data[i]);
    }
  }

  feedInt(value: number): void {
    this.ints.push(value);
  }

  nextBytes(count: number): Uint8Array {
    if (this.bytePos + count > this.bytes.length) {
      throw new Error('scripted random exhausted: nextBytes(' + count + ')');
    }
    const out: Uint8Array = new Uint8Array(count);
    for (let i: number = 0; i < count; i++) {
      out[i] = this.bytes[this.bytePos + i];
    }
    this.bytePos += count;
    return out;
  }

  nextInt(bound: number): number {
    if (this.intPos >= this.ints.length) {
      throw new Error('scripted random exhausted: nextInt(' + bound + ')');
    }
    const value: number = this.ints[this.intPos];
    this.intPos += 1;
    if (value < 0 || value >= bound) {
      throw new Error('scripted int out of range: ' + value);
    }
    return value;
  }
}

/** Lehmer-RNG random source for behavioral (non-golden) tests. */
class CountingNostrRandom implements NostrRandomSource {
  private state: number;

  constructor(seed: number) {
    this.state = seed % 0x7FFFFFFF;
  }

  private advance(): number {
    this.state = (this.state * 48271) % 0x7FFFFFFF;
    return this.state;
  }

  nextBytes(count: number): Uint8Array {
    const out: Uint8Array = new Uint8Array(count);
    for (let i: number = 0; i < count; i++) {
      out[i] = this.advance() & 0xFF;
    }
    return out;
  }

  nextInt(bound: number): number {
    return this.advance() % bound;
  }
}

function ncRepeat(hex2: string, times: number): string {
  let out: string = '';
  for (let i: number = 0; i < times; i++) {
    out += hex2;
  }
  return out;
}

function ncCountingBytes(count: number, start: number): Uint8Array {
  const out: Uint8Array = new Uint8Array(count);
  for (let i: number = 0; i < count; i++) {
    out[i] = (start + i) & 0xFF;
  }
  return out;
}

/** Gift-wrap an arbitrary seal for a recipient (createGiftWrap parity). */
function ncWrapSeal(seal: NostrEvent, recipient: NostrIdentity,
  random: NostrRandomSource, nowSeconds: number): NostrEvent {
  const sealJson: string = seal.toJsonString();
  const wrapPrivateKey: string =
    Secp256k1.privateKeyFromRandomBytes(random.nextBytes(32));
  const wrapPublicKey: string = Secp256k1.derivePublicKey(wrapPrivateKey);
  const encrypted: string = Nip44.encrypt(sealJson, recipient.publicKeyHex,
    wrapPrivateKey, random.nextBytes(24));
  const giftWrap: NostrEvent = new NostrEvent('', wrapPublicKey, nowSeconds,
    NostrKind.GIFT_WRAP, [['p', recipient.publicKeyHex]], encrypted, null);
  return giftWrap.sign(wrapPrivateKey, random);
}

export function runNostrContractTests(t: ContractAssert): void {
  secp256k1Bip340Vectors(t);
  secp256k1KeyHandling(t);
  xchacha20GoldenVectors(t);
  xchacha20RoundTripAndTamper(t);
  nip44RoundTrip(t);
  nostrEventIdGolden(t);
  nostrEventJsonGolden(t);
  nostrEventParseDefaults(t);
  nostrIdentityNpubRoundTrip(t);
  nostrProtocolRoundTrip(t);
  nostrProtocolForgedSealRejection(t);
  nostrProtocolTimestamps(t);
  relayReconnectSchedule(t);
  relayCatalogDefaults(t);
}

function secp256k1Bip340Vectors(t: ContractAssert): void {
  const zeros: Uint8Array = ByteUtils.hexToBytes(BIP340_ZEROS32);
  // Vector 0.
  const v0Pub: string =
    'f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9';
  const v0Sig: string =
    'e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca8215' +
    '25f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0';
  t.equalString(v0Pub, Secp256k1.derivePublicKey(BIP340_V0_SEC),
    'bip340 v0 pubkey derivation');
  t.equalString(v0Sig, Secp256k1.schnorrSign(zeros, BIP340_V0_SEC, zeros),
    'bip340 v0 signature golden');
  t.isTrue(Secp256k1.schnorrVerify(zeros, v0Sig, v0Pub), 'bip340 v0 verify');
  // Vector 1.
  const v1Aux: Uint8Array = ByteUtils.hexToBytes(
    '0000000000000000000000000000000000000000000000000000000000000001');
  const v1Msg: Uint8Array = ByteUtils.hexToBytes(
    '243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89');
  const v1Sig: string =
    '6896bd60eeae296db48a229ff71dfe071bde413e6d43f917dc8dcf8c78de3341' +
    '8906d11ac976abccb20b091292bff4ea897efcb639ea871cfa95f6de339e4b0a';
  t.equalString(BIP340_V1_PUB, Secp256k1.derivePublicKey(BIP340_V1_SEC),
    'bip340 v1 pubkey derivation');
  t.equalString(v1Sig, Secp256k1.schnorrSign(v1Msg, BIP340_V1_SEC, v1Aux),
    'bip340 v1 signature golden');
  t.isTrue(Secp256k1.schnorrVerify(v1Msg, v1Sig, BIP340_V1_PUB), 'bip340 v1 verify');
  // Vector 2.
  const v2Pub: string =
    'dd308afec5777e13121fa72b9cc1b7cc0139715309b086c960e18fd969774eb8';
  const v2Aux: Uint8Array = ByteUtils.hexToBytes(
    'c87aa53824b4d7ae2eb035a2b5bbbccc080e76cdc6d1692c4b0b62d798e6d906');
  const v2Msg: Uint8Array = ByteUtils.hexToBytes(
    '7e2d58d8b3bcdf1abadec7829054f90dda9805aab56c77333024b9d0a508b75c');
  const v2Sig: string =
    '5831aaeed7b44bb74e5eab94ba9d4294c49bcf2a60728d8b4c200f50dd313c1b' +
    'ab745879a5ad954a72c45a91c3a51d3c7adea98d82f8481e0e1e03674a6f3fb7';
  t.equalString(v2Pub, Secp256k1.derivePublicKey(BIP340_V2_SEC),
    'bip340 v2 pubkey derivation');
  t.equalString(v2Sig, Secp256k1.schnorrSign(v2Msg, BIP340_V2_SEC, v2Aux),
    'bip340 v2 signature golden');
  t.isTrue(Secp256k1.schnorrVerify(v2Msg, v2Sig, v2Pub), 'bip340 v2 verify');
  // Official CSV row 3: message equal to the field size (guards against
  // reducing the message modulo p or n).
  const vFieldSec: string =
    '0b432b2677937381aef05bb02a66ecd012773062cf3fa2549e44f58ed2401710';
  const vFieldPub: string =
    '25d1dff95105f5253c4022f628a996ad3a0d95fbf21d468a1b33f8c160d8f517';
  const vFieldAux: Uint8Array = ByteUtils.hexToBytes(ncRepeat('ff', 32));
  const vFieldMsg: Uint8Array = ByteUtils.hexToBytes(ncRepeat('ff', 32));
  const vFieldSig: string =
    '7eb0509757e246f19449885651611cb965ecc1a187dd51b64fda1edc9637d5ec' +
    '97582b9cb13db3933705b32ba982af5af25fd78881ebb32771fc5922efc66ea3';
  t.equalString(vFieldPub, Secp256k1.derivePublicKey(vFieldSec),
    'bip340 field-size-msg pubkey derivation');
  t.equalString(vFieldSig, Secp256k1.schnorrSign(vFieldMsg, vFieldSec, vFieldAux),
    'bip340 field-size-msg signature golden');
  t.isTrue(Secp256k1.schnorrVerify(vFieldMsg, vFieldSig, vFieldPub),
    'bip340 field-size-msg verify');
  // Vector 3: verification must fail.
  const v3Pub: string =
    'eefdea4cdb677750a420fee807eacf21eb9898ae79b9768766e4faa04a2d4a34';
  const v3Sig: string =
    '6cff5c3ba86c69ea4b7376f31a9bcb4f74c1976089b2d9963da2e5543e177769' +
    '69e89b4c5564d00349106b8497785dd7d1d713a8ae82b32fa79d5f7fc407d39b';
  t.isFalse(Secp256k1.schnorrVerify(v1Msg, v3Sig, v3Pub),
    'bip340 v3 verification fails');
  // Negative shapes.
  t.isFalse(Secp256k1.schnorrVerify(zeros, v0Sig.substring(0, 126), v0Pub),
    'short signature rejected');
  t.isFalse(Secp256k1.schnorrVerify(zeros, v0Sig, ncRepeat('ff', 32)),
    'off-curve pubkey rejected');
  t.throws(() => {
    Secp256k1.schnorrSign(zeros, BIP340_ZEROS32, zeros);
  }, 'zero private key rejected');
}

function secp256k1KeyHandling(t: ContractAssert): void {
  const n: string = 'fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141';
  const nMinus1: string = 'fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140';
  t.isFalse(Secp256k1.isValidPrivateKey(BIP340_ZEROS32), 'zero private key invalid');
  t.isFalse(Secp256k1.isValidPrivateKey(n), 'curve-order private key invalid');
  t.isTrue(Secp256k1.isValidPrivateKey(nMinus1), 'n-1 private key valid');
  t.isFalse(Secp256k1.isValidPrivateKey('00'), 'short private key invalid');
  t.equalString(ncRepeat('00', 31) + '01',
    Secp256k1.privateKeyFromRandomBytes(ByteUtils.hexToBytes(BIP340_ZEROS32)),
    'all-zero seed maps to key 1');
  t.isTrue(Secp256k1.isValidPrivateKey(
    Secp256k1.privateKeyFromRandomBytes(ByteUtils.hexToBytes(ncRepeat('ff', 32)))),
    'all-FF seed reduces to a valid key');
  t.isTrue(Secp256k1.isValidXOnlyPublicKey(Secp256k1.derivePublicKey(nMinus1)),
    'derived pubkey lifts to the curve');
  t.isFalse(Secp256k1.isValidXOnlyPublicKey(ncRepeat('ff', 32)),
    'off-curve x-only pubkey invalid');
  // ECDH symmetry: both directions share the same x coordinate.
  const alicePub: string = Secp256k1.derivePublicKey(BIP340_V1_SEC);
  const bobPub: string = Secp256k1.derivePublicKey(BIP340_V2_SEC);
  const ab: Uint8Array | null =
    Secp256k1.ecdhSharedPointCompressed(BIP340_V1_SEC, bobPub, false);
  const ba: Uint8Array | null =
    Secp256k1.ecdhSharedPointCompressed(BIP340_V2_SEC, alicePub, false);
  t.isNotNull(ab, 'ecdh alice-to-bob point');
  t.isNotNull(ba, 'ecdh bob-to-alice point');
  if (ab !== null && ba !== null) {
    t.equalNumber(33, ab.length, 'compressed shared point is 33 bytes');
    t.equalBytes(ab.subarray(1), ba.subarray(1), 'ecdh shared x symmetric');
  }
}

function xchacha20GoldenVectors(t: ContractAssert): void {
  // draft-irtf-cfrg-xchacha-03 section 2.2.1: HChaCha20 subkey.
  const key: Uint8Array = ByteUtils.hexToBytes(
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f');
  const nonce16: Uint8Array =
    ByteUtils.hexToBytes('000000090000004a0000000031415927');
  t.equalBytes(ByteUtils.hexToBytes(
    '82413b4227b27bfed30e42508a877d73a0f9e4d58a74a853c12ec41326d3ecdc'),
    XChaCha20Poly1305.hChaCha20(key, nonce16), 'draft-irtf HChaCha20 subkey golden');
  // draft-irtf-cfrg-xchacha-03 section A.3.1: AEAD_XCHACHA20_POLY1305.
  const aeadKey: Uint8Array = ByteUtils.hexToBytes(
    '808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f');
  const iv: Uint8Array = ByteUtils.hexToBytes(
    '404142434445464748494a4b4c4d4e4f5051525354555657');
  const aad: Uint8Array = ByteUtils.hexToBytes('50515253c0c1c2c3c4c5c6c7');
  const pt: Uint8Array = ByteUtils.hexToBytes(
    '4c616469657320616e642047656e746c656d656e206f662074686520636c6173' +
    '73206f66202739393a204966204920636f756c64206f6666657220796f75206f' +
    '6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73' +
    '637265656e20776f756c642062652069742e');
  const expectedCt: Uint8Array = ByteUtils.hexToBytes(
    'bd6d179d3e83d43b9576579493c0e939572a1700252bfaccbed2902c21396cbb' +
    '731c7f1b0b4aa6440bf3a82f4eda7e39ae64c6708c54c216cb96b72e1213b452' +
    '2f8c9ba40db5d945b11b69b982c1bb9e3f3fac2bc369488f76b2383565d3fff9' +
    '21f9664c97637da9768812f615c68b13b52e');
  const expectedTag: Uint8Array =
    ByteUtils.hexToBytes('c0875924c1c7987947deafd8780acf49');
  const sealed: Uint8Array = XChaCha20Poly1305.seal(aeadKey, iv, pt, aad);
  t.equalNumber(24 + pt.length + 16, sealed.length, 'aead combined length');
  t.equalBytes(iv, sealed.subarray(0, 24), 'aead nonce prefix');
  t.equalBytes(expectedCt, sealed.subarray(24, 24 + expectedCt.length),
    'draft-irtf aead ciphertext golden');
  t.equalBytes(expectedTag, sealed.subarray(24 + expectedCt.length),
    'draft-irtf aead tag golden');
  t.equalBytes(pt, XChaCha20Poly1305.open(aeadKey, sealed, aad),
    'aead golden open');
  t.throws(() => {
    XChaCha20Poly1305.open(aeadKey, sealed, null);
  }, 'aead wrong associated data rejected');
}

function xchacha20RoundTripAndTamper(t: ContractAssert): void {
  const key: Uint8Array = ncCountingBytes(32, 7);
  const nonce: Uint8Array = ncCountingBytes(24, 100);
  const message: Uint8Array = new Uint8Array(200);
  for (let i: number = 0; i < message.length; i++) {
    message[i] = i & 0xFF;
  }
  const sealed: Uint8Array = XChaCha20Poly1305.seal(key, nonce, message, null);
  t.equalBytes(message, XChaCha20Poly1305.open(key, sealed, null),
    'xchacha round trip 200B');
  const tamperedCt: Uint8Array = sealed.slice();
  tamperedCt[30] = tamperedCt[30] ^ 0x01;
  t.throws(() => {
    XChaCha20Poly1305.open(key, tamperedCt, null);
  }, 'tampered ciphertext rejected');
  const tamperedTag: Uint8Array = sealed.slice();
  tamperedTag[tamperedTag.length - 1] = tamperedTag[tamperedTag.length - 1] ^ 0x01;
  t.throws(() => {
    XChaCha20Poly1305.open(key, tamperedTag, null);
  }, 'tampered tag rejected');
  t.throws(() => {
    XChaCha20Poly1305.open(ncCountingBytes(32, 8), sealed, null);
  }, 'wrong key rejected');
  t.throws(() => {
    XChaCha20Poly1305.open(key, sealed.subarray(0, 39), null);
  }, 'short combined input rejected');
  const empty: Uint8Array = new Uint8Array(0);
  const sealedEmpty: Uint8Array = XChaCha20Poly1305.seal(key, nonce, empty, null);
  t.equalNumber(40, sealedEmpty.length, 'empty plaintext combined length');
  t.equalBytes(empty, XChaCha20Poly1305.open(key, sealedEmpty, null),
    'empty plaintext round trip');
  t.equalBytes(empty,
    XChaCha20Poly1305.open(key, sealedEmpty, new Uint8Array(0)),
    'empty associated data round trip');
}

function nip44RoundTrip(t: ContractAssert): void {
  const alice: NostrIdentity = NostrIdentity.fromPrivateKey(BIP340_V1_SEC, 1);
  const bob: NostrIdentity = NostrIdentity.fromPrivateKey(BIP340_V2_SEC, 2);
  const carol: NostrIdentity = NostrIdentity.fromPrivateKey(BIP340_V0_SEC, 3);
  const payload: string = Nip44.encrypt('hello nostr', bob.publicKeyHex,
    alice.privateKeyHex, ncCountingBytes(24, 40));
  t.isTrue(payload.startsWith('v2:'), 'nip44 v2 prefix');
  const body: string = payload.substring(3);
  t.isFalse(body.indexOf('+') >= 0, 'nip44 payload is base64url (no +)');
  t.isFalse(body.indexOf('/') >= 0, 'nip44 payload is base64url (no /)');
  t.isFalse(body.indexOf('=') >= 0, 'nip44 payload is unpadded');
  t.equalString('hello nostr',
    Nip44.decrypt(payload, alice.publicKeyHex, bob.privateKeyHex),
    'nip44 round trip');
  const unicode: string = Nip44.encrypt('互联网私信', bob.publicKeyHex,
    alice.privateKeyHex, ncCountingBytes(24, 90));
  t.equalString('互联网私信',
    Nip44.decrypt(unicode, alice.publicKeyHex, bob.privateKeyHex),
    'nip44 CJK round trip');
  t.throws(() => {
    Nip44.decrypt(payload, alice.publicKeyHex, carol.privateKeyHex);
  }, 'nip44 wrong recipient rejected');
  t.throws(() => {
    Nip44.decrypt('v1:nope', alice.publicKeyHex, bob.privateKeyHex);
  }, 'nip44 non-v2 prefix rejected');
}

function nostrEventIdGolden(t: ContractAssert): void {
  const pk: string = ncRepeat('ab', 32);
  const rp: string = ncRepeat('cd', 32);
  const tags: string[][] = [['p', rp]];
  const serialized: string =
    NostrEvent.serializeForId(pk, 1700000000, 14, tags, 'hello');
  t.equalString('[0,"' + pk + '",1700000000,14,[["p","' + rp + '"]],"hello"]',
    serialized, 'nip-01 id serialization golden');
  const event: NostrEvent =
    new NostrEvent('', pk, 1700000000, 14, tags, 'hello', null);
  const id: string = event.computeEventIdHex();
  t.equalString(ByteUtils.sha256Hex(ByteUtils.utf8Encode(serialized)), id,
    'nip-01 id is sha256 of the serialization');
  t.equalNumber(64, id.length, 'event id length');
  t.equalString('[0,"' + pk + '",0,0,[],""]',
    NostrEvent.serializeForId(pk, 0, 0, [], ''), 'nip-01 empty edge serialization');
  t.equalString('[0,"' + pk + '",1,1,[],"a\\"b\\\\c"]',
    NostrEvent.serializeForId(pk, 1, 1, [], 'a"b\\c'),
    'nip-01 serialization escapes quotes and backslashes');
}

function nostrEventJsonGolden(t: ContractAssert): void {
  const pk: string = ncRepeat('ab', 32);
  const unsigned: NostrEvent =
    new NostrEvent('id1', pk, 1700000000, 13, [], 'x', null);
  t.equalString(
    '{"id":"id1","pubkey":"' + pk + '","created_at":1700000000,"kind":13,' +
    '"tags":[],"content":"x"}',
    unsigned.toJsonString(), 'gson json golden (null sig omitted)');
  const content: string = 'a<b> & \'q=\'\n\t\\X"' +
    String.fromCharCode(0x2028) + 'z';
  const withContent: NostrEvent =
    new NostrEvent('i', pk, 13, 14, [['p', 'v']], content, null);
  t.equalString(
    '{"id":"i","pubkey":"' + pk + '","created_at":13,"kind":14,' +
    '"tags":[["p","v"]],' +
    '"content":"a\\u003cb\\u003e \\u0026 \\u0027q\\u003d\\u0027\\n\\t\\\\X\\"' +
    '\\u2028z"}',
    withContent.toJsonString(), 'gson html-safe escaping golden');
  const signed: NostrEvent = new NostrEvent('id2', pk, 1, 1, [], 'c', '00ff');
  t.equalString(
    '{"id":"id2","pubkey":"' + pk + '","created_at":1,"kind":1,' +
    '"tags":[],"content":"c","sig":"00ff"}',
    signed.toJsonString(), 'gson json golden (sig present)');
}

function nostrEventParseDefaults(t: ContractAssert): void {
  const parsed: NostrEvent | null = NostrEvent.parse(
    '{"id":"i","pubkey":"p","created_at":5,"kind":13,' +
    '"tags":[["p","x"]],"content":"c","sig":"s"}');
  t.isNotNull(parsed, 'full parse');
  if (parsed !== null) {
    t.equalString('i', parsed.id, 'parse id');
    t.equalString('p', parsed.pubkey, 'parse pubkey');
    t.equalNumber(5, parsed.createdAt, 'parse created_at');
    t.equalNumber(13, parsed.kind, 'parse kind');
    t.equalNumber(1, parsed.tags.length, 'parse tags length');
    t.equalString('p', parsed.tags[0][0], 'parse tag key');
    t.equalString('x', parsed.tags[0][1], 'parse tag value');
    t.equalString('c', parsed.content, 'parse content');
    t.isNotNull(parsed.sig, 'parse sig non-null');
    if (parsed.sig !== null) {
      t.equalString('s', parsed.sig, 'parse sig');
    }
  }
  const empty: NostrEvent | null = NostrEvent.parse('{}');
  t.isNotNull(empty, 'empty object parses with Gson defaults');
  if (empty !== null) {
    t.equalString('', empty.id, 'default id');
    t.equalString('', empty.pubkey, 'default pubkey');
    t.equalNumber(0, empty.createdAt, 'default created_at');
    t.equalNumber(0, empty.kind, 'default kind');
    t.equalNumber(0, empty.tags.length, 'default tags');
    t.equalString('', empty.content, 'default content');
    t.isNull(empty.sig, 'default sig');
  }
  t.isNull(NostrEvent.parse('not json'), 'invalid json rejected');
  t.isNull(NostrEvent.parse('[]'), 'array root rejected');
  t.isNull(NostrEvent.parse('{"id":null}'), 'explicit null field rejected');
  t.isNull(NostrEvent.parse('{"tags":"x"}'), 'non-array tags rejected');
  t.isNull(NostrEvent.parse('{"created_at":"5"}'),
    'numeric-string created_at rejected (documented divergence)');
  const mixed: NostrEvent | null = NostrEvent.parse('{"tags":[["a"],"b"]}');
  t.isNotNull(mixed, 'non-array tag element tolerated');
  if (mixed !== null) {
    t.equalNumber(2, mixed.tags.length, 'non-array tag element keeps the list');
    t.equalNumber(1, mixed.tags[0].length, 'valid tag element preserved');
    t.equalNumber(0, mixed.tags[1].length, 'non-array tag element becomes empty tag');
  }
  const innerAnomaly: NostrEvent | null =
    NostrEvent.parse('{"tags":[["a",null]]}');
  t.isNotNull(innerAnomaly, 'inner tag anomaly tolerated');
  if (innerAnomaly !== null) {
    t.equalNumber(0, innerAnomaly.tags.length, 'inner tag anomaly empties tags');
  }
  const coerced: NostrEvent | null =
    NostrEvent.parse('{"tags":[["a",5,true]]}');
  t.isNotNull(coerced, 'scalar tag items coerced');
  if (coerced !== null) {
    t.equalNumber(1, coerced.tags.length, 'coerced tags length');
    t.equalNumber(3, coerced.tags[0].length, 'coerced tag items length');
    t.equalString('5', coerced.tags[0][1], 'numeric tag item coerced');
    t.equalString('true', coerced.tags[0][2], 'boolean tag item coerced');
  }
}

function nostrIdentityNpubRoundTrip(t: ContractAssert): void {
  const random: ScriptedNostrRandom = new ScriptedNostrRandom();
  const seed: Uint8Array = ncCountingBytes(32, 1);
  random.feedBytes(seed);
  const identity: NostrIdentity = NostrIdentity.generate(random, 1700000000000);
  t.equalString(Secp256k1.derivePublicKey(Secp256k1.privateKeyFromRandomBytes(seed)),
    identity.publicKeyHex, 'identity pubkey matches the derivation');
  t.equalNumber(1700000000000, identity.createdAtMs, 'identity created timestamp');
  t.isTrue(identity.npub.startsWith('npub1'), 'npub hrp');
  t.equalNumber(63, identity.npub.length, 'npub length');
  const decoded: Bech32Result = Bech32.decode(identity.npub);
  t.equalString('npub', decoded.hrp, 'npub decode hrp');
  t.equalString(identity.publicKeyHex, ByteUtils.bytesToHex(decoded.data),
    'npub bech32 round trip');
  t.equalString(
    identity.npub.substring(0, 8) + '...' +
    identity.npub.substring(identity.npub.length - 8),
    identity.getShortNpub(), 'short npub format');
  t.equalString(BIP340_V1_PUB,
    NostrIdentity.fromPrivateKey(BIP340_V1_SEC, 0).publicKeyHex,
    'fromPrivateKey derives the pubkey');
  t.throws(() => {
    NostrIdentity.fromPrivateKey(BIP340_ZEROS32, 0);
  }, 'zero private key rejected');
  t.throws(() => {
    NostrIdentity.fromPrivateKey('zz', 0);
  }, 'non-hex private key rejected');
}

function nostrProtocolRoundTrip(t: ContractAssert): void {
  const alice: NostrIdentity = NostrIdentity.fromPrivateKey(BIP340_V1_SEC, 1);
  const bob: NostrIdentity = NostrIdentity.fromPrivateKey(BIP340_V2_SEC, 2);
  const carol: NostrIdentity = NostrIdentity.fromPrivateKey(BIP340_V0_SEC, 3);
  const nowMs: number = 1730000000000;
  const nowSeconds: number = 1730000000;
  const random: ScriptedNostrRandom = new ScriptedNostrRandom();
  // createSeal draws: nonce24, nextInt(79201), sign aux32.
  random.feedBytes(ncCountingBytes(24, 10));
  random.feedInt(79200);
  random.feedBytes(ncCountingBytes(32, 50));
  // createGiftWrap draws: ephemeral key seed32, nonce24, nextInt(79201), aux32.
  const ephemeralSeed: Uint8Array = ncCountingBytes(32, 100);
  random.feedBytes(ephemeralSeed);
  random.feedBytes(ncCountingBytes(24, 140));
  random.feedInt(0);
  random.feedBytes(ncCountingBytes(32, 170));
  const events: NostrEvent[] = NostrProtocol.createPrivateMessage(
    'internet dm', bob.publicKeyHex, alice, random, nowMs);
  t.equalNumber(1, events.length, 'receiver-copy gift wrap only');
  const giftWrap: NostrEvent = events[0];
  const ephemeralPriv: string = Secp256k1.privateKeyFromRandomBytes(ephemeralSeed);
  t.equalString(Secp256k1.derivePublicKey(ephemeralPriv), giftWrap.pubkey,
    'gift wrap ephemeral pubkey');
  t.equalNumber(NostrKind.GIFT_WRAP, giftWrap.kind, 'gift wrap kind 1059');
  t.equalNumber(1, giftWrap.tags.length, 'gift wrap p-tag present');
  t.equalString('p', giftWrap.tags[0][0], 'gift wrap p-tag name');
  t.equalString(bob.publicKeyHex, giftWrap.tags[0][1], 'gift wrap p-tag recipient');
  t.equalNumber(nowSeconds, giftWrap.createdAt,
    'gift wrap created_at (min backdating draw)');
  t.isTrue(giftWrap.isValid(), 'gift wrap signature valid');
  const decrypted: DecryptedPrivateMessage | null =
    NostrProtocol.decryptPrivateMessage(giftWrap, bob);
  t.isNotNull(decrypted, 'round-trip decrypt');
  if (decrypted !== null) {
    t.equalString('internet dm', decrypted.content, 'round-trip content');
    t.equalString(alice.publicKeyHex, decrypted.senderPubkey, 'round-trip sender');
    t.equalNumber(nowSeconds, decrypted.createdAt, 'rumor timestamp deterministic');
  }
  t.isNull(NostrProtocol.decryptPrivateMessage(giftWrap, carol),
    'wrong recipient rejected');
  // Unwrap manually: the seal must use the max backdating draw while
  // reserving the 2h slack inside the 24h iOS lookback.
  const seal: NostrEvent | null = NostrEvent.parse(
    Nip44.decrypt(giftWrap.content, giftWrap.pubkey, bob.privateKeyHex));
  t.isNotNull(seal, 'seal parse');
  if (seal !== null) {
    t.equalNumber(NostrKind.SEAL, seal.kind, 'seal kind 13');
    t.equalString(alice.publicKeyHex, seal.pubkey, 'seal signer is the sender');
    t.equalNumber(nowSeconds - 79200, seal.createdAt,
      'seal max backdating (22h, 2h slack inside the 24h lookback)');
    t.isTrue(seal.isValid(), 'seal signature valid');
    const rumor: NostrEvent | null = NostrEvent.parse(
      Nip44.decrypt(seal.content, seal.pubkey, bob.privateKeyHex));
    t.isNotNull(rumor, 'rumor parse');
    if (rumor !== null) {
      t.equalNumber(NostrKind.DIRECT_MESSAGE, rumor.kind, 'rumor kind 14');
      t.equalString(alice.publicKeyHex, rumor.pubkey, 'rumor pubkey is the sender');
      t.equalNumber(nowSeconds, rumor.createdAt, 'rumor created_at');
      t.equalString('internet dm', rumor.content, 'rumor content');
      t.isNull(rumor.sig, 'rumor unsigned');
    }
  }
}

function nostrProtocolForgedSealRejection(t: ContractAssert): void {
  const alice: NostrIdentity = NostrIdentity.fromPrivateKey(BIP340_V1_SEC, 1);
  const bob: NostrIdentity = NostrIdentity.fromPrivateKey(BIP340_V2_SEC, 2);
  const carol: NostrIdentity = NostrIdentity.fromPrivateKey(BIP340_V0_SEC, 3);
  const random: CountingNostrRandom = new CountingNostrRandom(11);
  const nowSeconds: number = 1730000000;
  // Seal validly signed by alice, but the rumor inside claims carol.
  const forgedRumor: NostrEvent = new NostrEvent('', carol.publicKeyHex,
    nowSeconds, NostrKind.DIRECT_MESSAGE, [['p', bob.publicKeyHex]], 'forged', null);
  const forgedSeal: NostrEvent = new NostrEvent('', alice.publicKeyHex,
    nowSeconds, NostrKind.SEAL, [],
    Nip44.encrypt(forgedRumor.toJsonString(), bob.publicKeyHex,
      alice.privateKeyHex, random.nextBytes(24)), null)
    .sign(alice.privateKeyHex, random);
  t.isTrue(forgedSeal.isValidSignature(), 'forged seal is itself well signed');
  t.isNull(NostrProtocol.decryptPrivateMessage(
    ncWrapSeal(forgedSeal, bob, random, nowSeconds), bob),
    'seal signer must match the rumor pubkey');
  // Transplanted seal signature (signed over different bytes).
  const realRumor: NostrEvent = new NostrEvent('', alice.publicKeyHex,
    nowSeconds, NostrKind.DIRECT_MESSAGE, [['p', bob.publicKeyHex]], 'real', null);
  const goodSeal: NostrEvent = new NostrEvent('', alice.publicKeyHex,
    nowSeconds, NostrKind.SEAL, [],
    Nip44.encrypt(realRumor.toJsonString(), bob.publicKeyHex,
      alice.privateKeyHex, random.nextBytes(24)), null)
    .sign(alice.privateKeyHex, random);
  const otherSeal: NostrEvent = new NostrEvent('', alice.publicKeyHex,
    nowSeconds, NostrKind.SEAL, [], 'other', null)
    .sign(alice.privateKeyHex, random);
  const badSigSeal: NostrEvent = new NostrEvent(goodSeal.id, goodSeal.pubkey,
    goodSeal.createdAt, goodSeal.kind, goodSeal.tags, goodSeal.content, otherSeal.sig);
  t.isFalse(badSigSeal.isValidSignature(), 'transplanted signature invalid');
  t.isNull(NostrProtocol.decryptPrivateMessage(
    ncWrapSeal(badSigSeal, bob, random, nowSeconds), bob),
    'bad seal signature rejected');
  // Control: the untampered seal decrypts.
  const control: DecryptedPrivateMessage | null = NostrProtocol.decryptPrivateMessage(
    ncWrapSeal(goodSeal, bob, random, nowSeconds), bob);
  t.isNotNull(control, 'authenticated seal accepted');
  if (control !== null) {
    t.equalString('real', control.content, 'control content');
    t.equalString(alice.publicKeyHex, control.senderPubkey, 'control sender');
  }
}

function nostrProtocolTimestamps(t: ContractAssert): void {
  const random: ScriptedNostrRandom = new ScriptedNostrRandom();
  random.feedInt(0);
  t.equalNumber(1000, NostrProtocol.randomizeTimestampUpToPast(1000, 100, random),
    'backdating min draw');
  random.feedInt(100);
  t.equalNumber(900, NostrProtocol.randomizeTimestampUpToPast(1000, 100, random),
    'backdating max draw');
  t.equalNumber(500, NostrProtocol.randomizeTimestampUpToPast(500, 0, random),
    'zero window consumes no randomness');
  const jitter: ScriptedNostrRandom = new ScriptedNostrRandom();
  jitter.feedInt(0);
  t.equalNumber(100, NostrProtocol.randomizeTimestamp(1000, jitter),
    'jitter min draw');
  jitter.feedInt(1799);
  t.equalNumber(1899, NostrProtocol.randomizeTimestamp(1000, jitter),
    'jitter max draw');
  jitter.feedInt(900);
  t.equalNumber(1000, NostrProtocol.randomizeTimestamp(1000, jitter),
    'jitter mid draw');
  t.equalNumber(79200, NostrProtocol.NIP17_DEFAULT_MAX_PAST_SECONDS,
    '22h default backdating');
}

function relayReconnectSchedule(t: ContractAssert): void {
  t.equalNumber(1, RelayReconnectPolicy.nextAttempt(0), 'first failure records attempt 1');
  t.equalNumber(6, RelayReconnectPolicy.nextAttempt(5), 'attempt counter increments');
  t.equalNumber(10, RelayReconnectPolicy.nextAttempt(9), 'counter reaches saturation');
  t.equalNumber(10, RelayReconnectPolicy.nextAttempt(10), 'counter saturates at 10');
  t.equalNumber(10, RelayReconnectPolicy.nextAttempt(1000), 'counter never exceeds saturation');
  t.equalNumber(1, RelayReconnectPolicy.nextAttempt(-3), 'negative attempts clamp to first');
  t.equalNumber(1000, RelayReconnectPolicy.backoffMs(1), 'initial backoff 1s');
  t.equalNumber(2000, RelayReconnectPolicy.backoffMs(2), 'backoff doubles');
  t.equalNumber(4000, RelayReconnectPolicy.backoffMs(3), 'backoff 4s');
  t.equalNumber(8000, RelayReconnectPolicy.backoffMs(4), 'backoff 8s');
  t.equalNumber(16000, RelayReconnectPolicy.backoffMs(5), 'backoff 16s');
  t.equalNumber(32000, RelayReconnectPolicy.backoffMs(6), 'backoff 32s');
  t.equalNumber(64000, RelayReconnectPolicy.backoffMs(7), 'backoff 64s');
  t.equalNumber(128000, RelayReconnectPolicy.backoffMs(8), 'backoff 128s');
  t.equalNumber(256000, RelayReconnectPolicy.backoffMs(9), 'backoff 256s');
  t.equalNumber(300000, RelayReconnectPolicy.backoffMs(10), 'backoff caps at 5min');
  t.equalNumber(300000, RelayReconnectPolicy.backoffMs(11), 'backoff stays at cap');
  t.equalNumber(300000, RelayReconnectPolicy.backoffMs(1000), 'backoff stays at cap far out');
  t.equalNumber(1000, RelayReconnectPolicy.backoffMs(0), 'attempt 0 treated as first');
  t.equalNumber(1000, RelayReconnectPolicy.backoffMs(-5), 'negative attempt treated as first');
  t.equalNumber(10, RelayReconnectPolicy.SATURATION_ATTEMPTS,
    'saturation equals max reconnect attempts');
}

function relayCatalogDefaults(t: ContractAssert): void {
  t.equalNumber(4, NostrRelayCatalog.DEFAULT_RELAYS.length, 'four default relays');
  t.equalString('wss://relay.damus.io', NostrRelayCatalog.DEFAULT_RELAYS[0],
    'default relay 1');
  t.equalString('wss://relay.primal.net', NostrRelayCatalog.DEFAULT_RELAYS[1],
    'default relay 2');
  t.equalString('wss://offchain.pub', NostrRelayCatalog.DEFAULT_RELAYS[2],
    'default relay 3');
  t.equalString('wss://nostr21.com', NostrRelayCatalog.DEFAULT_RELAYS[3],
    'default relay 4');
  t.equalNumber(172800000, NostrRelayCatalog.GIFT_WRAP_LOOKBACK_MS,
    'gift wrap lookback 48h');
  t.equalNumber(3600000, NostrRelayCatalog.PRESENCE_LOOKBACK_MS,
    'presence lookback 1h');
  t.equalNumber(173700, NostrRelayCatalog.MAX_MESSAGE_AGE_SECONDS,
    'max message age 48h + 15min');
}
