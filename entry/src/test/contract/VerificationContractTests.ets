/**
 * QR identity-verification + favorite-relationship contract tests
 * (US11, T055-T057): Android VerificationServiceTest /
 * FavoriteRelationshipTest / FavoriteControlMessage parity.
 *
 *  - ContactIdentityResolver: mesh-peer-id / noise-key-hex shape gates,
 *    SHA-256 fingerprint, contact_ conversation id, strict hex decode,
 *    bech32 npub <-> hex round trip, nostr alias derivation;
 *  - FavoriteRelationship: withPeerFavoritedUs bare/preserve semantics,
 *    isMutual, equals; FavoriteRelationshipCodec JSON round trip with
 *    invalid-entry skipping; FavoriteControlMessage
 *    "[FAVORITED]:npub" / "[UNFAVORITED]:npub" parse/encode vectors;
 *  - VerificationService: skew saturation, canonical length-prefixed
 *    signing bytes (golden), deep-link URL build/strict parse (first
 *    occurrence wins, malformed rejection), buildMyQRString 60s cache,
 *    ±300s freshness window incl. boundary and tamper rejection,
 *    challenge/response TLV golden layouts, the exact response signing
 *    message and verifyResponseSignature accept/tamper matrix.
 *
 * The Ed25519 engine and random source are faked (deterministic keys,
 * sha256 stand-in signature), so the suite runs on the host harness.
 */
import { ContractAssert } from './ContractAssert';
import { ByteUtils } from '../../main/ets/common/ByteUtils';
import { ContactIdentityResolver } from '../../main/ets/service/identity/ContactIdentityResolver';
import { VerificationSigner } from '../../main/ets/service/identity/VerificationService';
import {
  VERIFICATION_RESPONSE_CONTEXT,
  VerificationQR,
  VerificationService,
  VerifyChallenge,
  VerifyResponse
} from '../../main/ets/service/identity/VerificationService';
import {
  FavoriteControlMessage,
  FavoriteRelationship,
  FavoriteRelationshipCodec
} from '../../main/ets/model/FavoriteModels';

export function runVerificationContractTests(t: ContractAssert): void {
  contactIdentityResolution(t);
  favoriteRelationshipSemantics(t);
  favoriteCodecRoundTrip(t);
  favoriteControlMessageVectors(t);
  verificationSkewSaturation(t);
  verificationCanonicalBytes(t);
  verificationUrlRoundTrip(t);
  verificationMyQrBuild(t);
  verificationFreshnessWindow(t);
  verificationChallengeResponseTlv(t);
}

function vcFilled(length: number, value: number): Uint8Array {
  const out: Uint8Array = new Uint8Array(length);
  for (let i: number = 0; i < length; i++) {
    out[i] = value;
  }
  return out;
}

function vcHexRepeat(unit: string, count: number): string {
  let out: string = '';
  for (let i: number = 0; i < count; i++) {
    out += unit;
  }
  return out;
}

function vcFixedNonce(): Uint8Array {
  const out: Uint8Array = new Uint8Array(16);
  for (let i: number = 0; i < 16; i++) {
    out[i] = i;
  }
  return out;
}

/** Deterministic signer: fixed keys, sha256 stand-in signature. */
class VcFakeSigner implements VerificationSigner {
  private readonly staticKey: Uint8Array;
  private readonly signingKey: Uint8Array;
  lastSigned: Uint8Array;
  signCalls: number;
  failSign: boolean;

  constructor() {
    this.staticKey = vcFilled(32, 0x0A);
    this.signingKey = vcFilled(32, 0x0B);
    this.lastSigned = new Uint8Array(0);
    this.signCalls = 0;
    this.failSign = false;
  }

  getStaticPublicKey(): Uint8Array {
    return this.staticKey;
  }

  getSigningPublicKey(): Uint8Array {
    return this.signingKey;
  }

  sign(data: Uint8Array): Uint8Array | null {
    this.signCalls += 1;
    if (this.failSign) {
      return null;
    }
    this.lastSigned = data;
    return ByteUtils.sha256(data);
  }
}

function contactIdentityResolution(t: ContractAssert): void {
  t.isTrue(ContactIdentityResolver.isMeshPeerId('0123456789abcdef'), '16-hex mesh peer id accepted');
  t.isFalse(ContactIdentityResolver.isMeshPeerId('0123456789abcde'), '15-char mesh id rejected');
  t.isFalse(ContactIdentityResolver.isMeshPeerId('0123456789abcdef0'), '17-char mesh id rejected');
  t.isFalse(ContactIdentityResolver.isMeshPeerId('0123456789abcdeg'), 'non-hex mesh id rejected');
  t.isTrue(ContactIdentityResolver.isMeshPeerId('0123456789ABCDEF'), 'uppercase mesh id accepted');

  t.isTrue(ContactIdentityResolver.isNoiseKeyHex(vcHexRepeat('ab', 32)), '64-hex noise key accepted');
  t.isFalse(ContactIdentityResolver.isNoiseKeyHex(vcHexRepeat('ab', 31)), '62-char noise key rejected');
  t.equalString(vcHexRepeat('ab', 32),
    ContactIdentityResolver.noiseKeyHex(ByteUtils.hexToBytes(vcHexRepeat('AB', 32))),
    'noiseKeyHex lowercases input');

  const keyBytes: Uint8Array = ByteUtils.hexToBytes(vcHexRepeat('ab', 32));
  const fingerprint: string = ContactIdentityResolver.fingerprintHex(keyBytes);
  t.equalString(ByteUtils.sha256Hex(keyBytes).toLowerCase(), fingerprint, 'fingerprint is lowercased sha256 hex');
  t.equalString(fingerprint.substring(0, 16), ContactIdentityResolver.peerIdForNoiseKey(keyBytes),
    'mesh peer id is the 16-char fingerprint prefix');
  t.equalString(fingerprint.substring(0, 16), ContactIdentityResolver.peerIdForNoiseKeyHex(vcHexRepeat('ab', 32)) ?? '',
    'peer id derivable from noise key hex');
  t.isNull(ContactIdentityResolver.peerIdForNoiseKeyHex(vcHexRepeat('ab', 31)), 'short noise key hex rejected');

  t.isTrue(ContactIdentityResolver.isContactConversationId('contact_' + fingerprint), 'contact_ id accepted');
  t.isFalse(ContactIdentityResolver.isContactConversationId('contact_' + fingerprint.substring(0, 63)),
    'short contact fingerprint rejected');
  t.isFalse(ContactIdentityResolver.isContactConversationId('contact_' + vcHexRepeat('zz', 32)),
    'non-hex contact fingerprint rejected');
  t.equalString(fingerprint,
    ContactIdentityResolver.fingerprintFromContactConversationId('contact_' + fingerprint.toUpperCase()) ?? '',
    'contact_ id parse lowercases the fingerprint');
  t.isNull(ContactIdentityResolver.fingerprintFromContactConversationId(fingerprint),
    'missing contact_ prefix rejected');

  t.isNull(ContactIdentityResolver.bytesFromHex('abc'), 'odd-length hex rejected');
  t.isNull(ContactIdentityResolver.bytesFromHex('zz'), 'non-hex characters rejected');
  t.isNull(ContactIdentityResolver.bytesFromHex('  '), 'blank hex rejected');
  const decoded: Uint8Array | null = ContactIdentityResolver.bytesFromHex(' AbCd ');
  t.isNotNull(decoded, 'hex decode trims surrounding whitespace');
  if (decoded === null) {
    return;
  }
  t.equalBytes(ByteUtils.hexToBytes('abcd'), decoded, 'trimmed hex decodes exactly');

  const hex12: string = vcHexRepeat('12', 32);
  const npub: string | null = ContactIdentityResolver.npubFromHex(hex12);
  t.isNotNull(npub, 'npub derivable from 32-byte hex');
  if (npub === null) {
    return;
  }
  t.isTrue(npub.startsWith('npub1'), 'npub carries the npub1 prefix');
  t.equalString(hex12, ContactIdentityResolver.nostrPubkeyHex(npub) ?? '', 'npub decodes back to pubkey hex');
  t.equalString(hex12, ContactIdentityResolver.nostrPubkeyHex(npub.toUpperCase()) ?? '',
    'uppercase npub tolerated on decode');
  t.equalString(hex12, ContactIdentityResolver.nostrPubkeyHex(hex12.toUpperCase()) ?? '',
    'raw uppercase hex accepted and lowercased');
  t.isNull(ContactIdentityResolver.nostrPubkeyHex('npub1short'), 'invalid npub rejected');
  t.isNull(ContactIdentityResolver.nostrPubkeyHex(hex12.substring(0, 62)), 'short raw hex rejected');
  t.isNull(ContactIdentityResolver.npubFromHex('abcd'), 'npub encoding needs 32 bytes');

  t.isTrue(ContactIdentityResolver.isNostrAlias('nostr_abc'), 'nostr_ alias prefix accepted');
  t.isTrue(ContactIdentityResolver.isNostrAlias('nostr:abc'), 'nostr: alias prefix accepted');
  t.isFalse(ContactIdentityResolver.isNostrAlias('npub1abc'), 'npub is not an alias');
  t.isFalse(ContactIdentityResolver.isNostrAlias('nostr'), 'bare nostr rejected');
  t.equalString('nostr_' + hex12.substring(0, 16), ContactIdentityResolver.nostrAliasForPubkey(hex12) ?? '',
    'alias derived from pubkey hex');
  t.equalString('nostr_' + hex12.substring(0, 16), ContactIdentityResolver.nostrAliasForPubkey(npub) ?? '',
    'alias derived from npub');
  t.isNull(ContactIdentityResolver.nostrAliasForPubkey('nope'), 'invalid alias source rejected');
}

function favoriteRelationshipSemantics(t: ContractAssert): void {
  const noiseKey: Uint8Array = ByteUtils.hexToBytes(vcHexRepeat('ab', 32));

  const bare: FavoriteRelationship = FavoriteRelationship.withPeerFavoritedUs(null, noiseKey, true, 1000);
  t.isFalse(bare.isFavorite, 'bare received-only relationship is not our favorite');
  t.isTrue(bare.theyFavoritedUs, 'bare received-only relationship records their favorite');
  t.equalString('Unknown', bare.peerNickname, 'bare relationship uses Unknown nickname');
  t.isFalse(bare.isMutual(), 'bare received-only relationship is not mutual');
  t.equalNumber(1000, bare.favoritedAtMs, 'bare relationship favoritedAt defaults to now');
  t.equalNumber(1000, bare.lastUpdatedMs, 'bare relationship lastUpdated defaults to now');
  t.isNull(bare.peerNostrPublicKey, 'bare relationship has no npub');

  const base: FavoriteRelationship =
    new FavoriteRelationship(noiseKey, 'npub1abc', 'carol', true, false, 500, 600);
  const updated: FavoriteRelationship = FavoriteRelationship.withPeerFavoritedUs(base, noiseKey, true, 2000);
  t.isTrue(updated.isFavorite, 'existing favorite preserved on received transition');
  t.isTrue(updated.theyFavoritedUs, 'received transition marks theyFavoritedUs');
  t.isTrue(updated.isMutual(), 'both-sided relationship is mutual');
  t.equalString('carol', updated.peerNickname, 'existing nickname preserved');
  t.equalString('npub1abc', updated.peerNostrPublicKey ?? '', 'existing npub preserved');
  t.equalNumber(500, updated.favoritedAtMs, 'existing favoritedAt preserved');
  t.equalNumber(2000, updated.lastUpdatedMs, 'lastUpdated refreshed to now');

  const unfavored: FavoriteRelationship = FavoriteRelationship.withPeerFavoritedUs(updated, noiseKey, false, 3000);
  t.isFalse(unfavored.theyFavoritedUs, 'unfavorite transition clears theyFavoritedUs');
  t.isTrue(unfavored.isFavorite, 'unfavorite transition keeps our favorite');
  t.isFalse(unfavored.isMutual(), 'one-sided relationship is not mutual');

  t.isTrue(FavoriteRelationship.equals(base,
    new FavoriteRelationship(ByteUtils.hexToBytes(vcHexRepeat('ab', 32)), 'npub1abc', 'carol', true, false, 500, 600)),
    'equals accepts an identical relationship');
  t.isFalse(FavoriteRelationship.equals(base, updated), 'different lastUpdated breaks equals');
  t.isFalse(FavoriteRelationship.equals(base,
    new FavoriteRelationship(ByteUtils.hexToBytes(vcHexRepeat('cd', 32)), 'npub1abc', 'carol', true, false, 500, 600)),
    'different noise key breaks equals');
}

function favoriteCodecRoundTrip(t: ContractAssert): void {
  const keyA: string = vcHexRepeat('ab', 32);
  const keyB: string = vcHexRepeat('cd', 32);
  const relA: FavoriteRelationship =
    new FavoriteRelationship(ByteUtils.hexToBytes(keyA), 'npub1abc', 'carol', true, true, 500, 600);
  const relB: FavoriteRelationship =
    new FavoriteRelationship(ByteUtils.hexToBytes(keyB), null, 'dave', false, true, 700, 800);
  const map: Map<string, FavoriteRelationship> = new Map<string, FavoriteRelationship>();
  map.set(keyA, relA);
  map.set(keyB, relB);

  const back: Map<string, FavoriteRelationship> | null =
    FavoriteRelationshipCodec.fromJson(FavoriteRelationshipCodec.toJson(map));
  t.isNotNull(back, 'codec round trip produces a map');
  if (back === null) {
    return;
  }
  t.equalNumber(2, back.size, 'codec round trip keeps both entries');
  const backA: FavoriteRelationship | undefined = back.get(keyA);
  t.isTrue(backA !== undefined, 'entry A present after round trip');
  if (backA !== undefined) {
    t.isTrue(FavoriteRelationship.equals(relA, backA), 'entry A round trips field-by-field');
  }
  const backB: FavoriteRelationship | undefined = back.get(keyB);
  t.isTrue(backB !== undefined, 'entry B present after round trip');
  if (backB !== undefined) {
    t.isTrue(FavoriteRelationship.equals(relB, backB), 'entry B round trips field-by-field');
    t.isNull(backB.peerNostrPublicKey, 'null npub survives the round trip');
  }

  t.isNull(FavoriteRelationshipCodec.fromJson('{not json'), 'invalid JSON returns null');
  t.isNull(FavoriteRelationshipCodec.fromJson('null'), 'JSON null returns null');
  t.isNull(FavoriteRelationshipCodec.fromJson('"text"'), 'non-object JSON returns null');

  const mixedDoc: string = '{"badhex":{"peerNoisePublicKeyHex":"nothex!","peerNickname":"x"},' +
    '"scalar":42,' +
    '"' + keyA + '":{"peerNoisePublicKeyHex":"' + keyA + '","peerNickname":"carol",' +
    '"isFavorite":true,"theyFavoritedUs":false,"favoritedAt":5,"lastUpdated":6}}';
  const mixed: Map<string, FavoriteRelationship> | null = FavoriteRelationshipCodec.fromJson(mixedDoc);
  t.isNotNull(mixed, 'mixed document still parses');
  if (mixed === null) {
    return;
  }
  t.equalNumber(1, mixed.size, 'structurally invalid entries are skipped');
  const mixedEntry: FavoriteRelationship | undefined = mixed.get(keyA);
  t.isTrue(mixedEntry !== undefined, 'valid entry kept from mixed document');
  if (mixedEntry !== undefined) {
    t.equalString('carol', mixedEntry.peerNickname, 'mixed entry nickname decoded');
    t.isTrue(mixedEntry.isFavorite, 'mixed entry isFavorite decoded');
    t.isFalse(mixedEntry.theyFavoritedUs, 'mixed entry theyFavoritedUs decoded');
    t.equalNumber(5, mixedEntry.favoritedAtMs, 'mixed entry favoritedAt decoded');
    t.equalNumber(6, mixedEntry.lastUpdatedMs, 'mixed entry lastUpdated decoded');
  }

  const partialDoc: string = '{"' + keyA + '":{"peerNoisePublicKeyHex":"' + keyA + '"}}';
  const partial: Map<string, FavoriteRelationship> | null = FavoriteRelationshipCodec.fromJson(partialDoc);
  t.isNotNull(partial, 'minimal entry document parses');
  if (partial === null) {
    return;
  }
  const partialEntry: FavoriteRelationship | undefined = partial.get(keyA);
  t.isTrue(partialEntry !== undefined, 'minimal entry decoded');
  if (partialEntry !== undefined) {
    t.equalString('Unknown', partialEntry.peerNickname, 'missing nickname defaults to Unknown');
    t.isNull(partialEntry.peerNostrPublicKey, 'missing npub defaults to null');
    t.isFalse(partialEntry.isFavorite, 'missing isFavorite defaults to false');
    t.isFalse(partialEntry.theyFavoritedUs, 'missing theyFavoritedUs defaults to false');
    t.equalNumber(0, partialEntry.favoritedAtMs, 'missing favoritedAt defaults to 0');
    t.equalNumber(0, partialEntry.lastUpdatedMs, 'missing lastUpdated defaults to 0');
  }
}

function favoriteControlMessageVectors(t: ContractAssert): void {
  const hex12: string = vcHexRepeat('12', 32);
  const npub: string | null = ContactIdentityResolver.npubFromHex(hex12);
  t.isNotNull(npub, 'npub vector derivable');
  if (npub === null) {
    return;
  }

  const favorited: FavoriteControlMessage | null = FavoriteControlMessage.parse('[FAVORITED]:' + npub);
  t.isNotNull(favorited, 'favorited control message parses');
  if (favorited !== null) {
    t.isTrue(favorited.isFavorite, 'favorited control message flag');
    t.equalString(npub, favorited.npub ?? '', 'favorited control message carries npub');
  }

  const unfavorited: FavoriteControlMessage | null = FavoriteControlMessage.parse('[UNFAVORITED]:' + npub);
  t.isNotNull(unfavorited, 'unfavorited control message parses');
  if (unfavorited !== null) {
    t.isFalse(unfavorited.isFavorite, 'unfavorited control message flag');
    t.equalString(npub, unfavorited.npub ?? '', 'unfavorited control message carries npub');
  }

  t.isNull(FavoriteControlMessage.parse('hello world'), 'plain text is not a control message');

  const bareFavorited: FavoriteControlMessage | null = FavoriteControlMessage.parse('[FAVORITED]:');
  t.isNotNull(bareFavorited, 'favorited without key parses');
  if (bareFavorited !== null) {
    t.isTrue(bareFavorited.isFavorite, 'favorited without key keeps flag');
    t.isNull(bareFavorited.npub, 'favorited without key has null npub');
  }

  const noSeparator: FavoriteControlMessage | null = FavoriteControlMessage.parse('[UNFAVORITED]');
  t.isNotNull(noSeparator, 'unfavorited without separator parses');
  if (noSeparator !== null) {
    t.isFalse(noSeparator.isFavorite, 'unfavorited without separator keeps flag');
    t.isNull(noSeparator.npub, 'unfavorited without separator has null npub');
  }

  const invalidKey: FavoriteControlMessage | null = FavoriteControlMessage.parse('[FAVORITED]:not-an-npub');
  t.isNotNull(invalidKey, 'favorited with invalid key still parses');
  if (invalidKey !== null) {
    t.isTrue(invalidKey.isFavorite, 'favorited with invalid key keeps flag');
    t.isNull(invalidKey.npub, 'invalid key yields null npub');
  }

  const byHex: FavoriteControlMessage | null = FavoriteControlMessage.parse('[FAVORITED]:' + hex12);
  t.isNotNull(byHex, 'raw hex key accepted');
  if (byHex !== null) {
    t.equalString(npub, byHex.npub ?? '', 'raw hex key canonicalized to npub');
  }

  const padded: FavoriteControlMessage | null = FavoriteControlMessage.parse('  [FAVORITED]:' + npub + '  ');
  t.isNotNull(padded, 'surrounding whitespace tolerated');
  if (padded !== null) {
    t.isTrue(padded.isFavorite, 'padded control message flag');
    t.equalString(npub, padded.npub ?? '', 'padded control message npub');
  }

  t.equalString('[FAVORITED]:' + npub, FavoriteControlMessage.encode(true, npub), 'encode favorited');
  t.equalString('[UNFAVORITED]:', FavoriteControlMessage.encode(false, null), 'encode unfavorited without key');
  const roundTrip: FavoriteControlMessage | null =
    FavoriteControlMessage.parse(FavoriteControlMessage.encode(true, npub));
  t.isNotNull(roundTrip, 'encode output parses back');
  if (roundTrip !== null) {
    t.isTrue(roundTrip.isFavorite, 'encode/parse round trip flag');
    t.equalString(npub, roundTrip.npub ?? '', 'encode/parse round trip npub');
  }
}

function verificationSkewSaturation(t: ContractAssert): void {
  t.equalNumber(0, VerificationService.verificationTimestampSkewSeconds(100, 100), 'same timestamp has zero skew');
  t.equalNumber(60, VerificationService.verificationTimestampSkewSeconds(100, 160), '60s past skew');
  t.equalNumber(3600, VerificationService.verificationTimestampSkewSeconds(100, 3700), '1h past skew');
  t.equalNumber(3600, VerificationService.verificationTimestampSkewSeconds(3700, 100), '1h future skew');
  t.equalNumber(300, VerificationService.verificationTimestampSkewSeconds(400, 100), 'boundary skew is exact');
  t.equalNumber(Number.MAX_SAFE_INTEGER, VerificationService.verificationTimestampSkewSeconds(0, 1e16),
    'hostile huge timestamp saturates instead of wrapping');
  t.equalNumber(Number.MAX_SAFE_INTEGER, VerificationService.verificationTimestampSkewSeconds(1e308, -1e308),
    'non-finite difference saturates');
}

function verificationCanonicalBytes(t: ContractAssert): void {
  const tiny: VerificationQR = new VerificationQR(1, 'aa', 'bb', null, 'bob', 123, 'NA', 'cc');
  t.equalBytes(ByteUtils.hexToBytes(
    '11626974636861742d7665726966792d763101310261610262620003626f6203313233024e41'),
    tiny.canonicalBytes(), 'canonical signing bytes golden layout');

  const upper: VerificationQR =
    new VerificationQR(1, vcHexRepeat('AB', 32), vcHexRepeat('CD', 32), null, 'bob', 123, 'NA', 'cc');
  const lower: VerificationQR =
    new VerificationQR(1, vcHexRepeat('ab', 32), vcHexRepeat('cd', 32), null, 'bob', 123, 'NA', 'cc');
  t.equalBytes(lower.canonicalBytes(), upper.canonicalBytes(),
    'canonical bytes normalize key hex to lowercase');

  const withNpub: VerificationQR =
    new VerificationQR(1, 'aa', 'bb', 'npub1xyz', 'bob', 123, 'NA', 'cc');
  t.isFalse(ByteUtils.equals(tiny.canonicalBytes(), withNpub.canonicalBytes()),
    'npub participates in the canonical bytes');

  const longNick: VerificationQR =
    new VerificationQR(1, '', '', null, vcHexRepeat('x', 300), 1, 'NA', 'cc');
  const clipped: Uint8Array = longNick.canonicalBytes();
  // ctx(1+17) + v(1+1) + noise(1+0) + sign(1+0) + npub(1+0) = 23 bytes.
  t.equalNumber(255, clipped[23], 'fields longer than 255 bytes clip to 255');
  t.equalNumber(0x78, clipped[24], 'clipped nickname content starts after the length byte');
  t.equalNumber(284, clipped.length, 'clipped canonical total length');
  t.equalNumber(1, clipped[279], 'ts field follows the clipped nickname');
}

function verificationUrlRoundTrip(t: ContractAssert): void {
  const qr: VerificationQR =
    new VerificationQR(1, vcHexRepeat('AB', 32), vcHexRepeat('cd', 32), null, 'Li Si & Co+', 1700000000,
      'Tl-ycw', 'aabbcc');
  const urlString: string = qr.toUrlString();
  t.isTrue(urlString.startsWith('bitchat://verify?'), 'url carries the verify scheme');
  t.isTrue(urlString.indexOf('npub=') < 0, 'null npub omitted from url');

  const parsed: VerificationQR | null = VerificationQR.fromUrlString(urlString);
  t.isNotNull(parsed, 'built url parses back');
  if (parsed === null) {
    return;
  }
  t.isTrue(VerificationQR.equals(qr, parsed), 'url round trip preserves every field');
  t.equalString(vcHexRepeat('AB', 32), parsed.noiseKeyHex, 'url round trip keeps raw key case');
  t.equalString('Li Si & Co+', parsed.nickname, 'special characters survive percent-encoding');

  const withNpub: VerificationQR =
    new VerificationQR(1, 'aa', 'bb', 'npub1xyz', 'bob', 123, 'NA', 'cc');
  const npubUrl: string = withNpub.toUrlString();
  t.isTrue(npubUrl.indexOf('npub=npub1xyz') >= 0, 'npub included when present');
  const npubParsed: VerificationQR | null = VerificationQR.fromUrlString(npubUrl);
  t.isNotNull(npubParsed, 'npub url parses back');
  if (npubParsed !== null) {
    t.equalString('npub1xyz', npubParsed.npub ?? '', 'npub round trips');
  }

  const duplicated: VerificationQR | null = VerificationQR.fromUrlString(
    'bitchat://verify?v=1&noise=aa&sign=bb&nick=first&nick=second&ts=5&nonce=NA&sig=ff');
  t.isNotNull(duplicated, 'duplicate-key url parses');
  if (duplicated !== null) {
    t.equalString('first', duplicated.nickname, 'duplicate keys resolve to the first occurrence');
  }

  t.isNull(VerificationQR.fromUrlString('https://bitchat/verify?v=1'), 'foreign scheme rejected');
  t.isNull(VerificationQR.fromUrlString('bitchat://verify/extra?v=1'), 'path after host rejected');
  t.isNull(VerificationQR.fromUrlString('bitchat://verify'), 'empty query rejected');
  t.isNull(VerificationQR.fromUrlString('bitchat://verify?v=1&noise=aa&sign=bb&nick=x&ts=5&nonce=NA'),
    'missing sig rejected');
  t.isNull(VerificationQR.fromUrlString('bitchat://verify?v=1.5&noise=aa&sign=bb&nick=x&ts=5&nonce=NA&sig=ff'),
    'non-integer version rejected');
  t.isNull(VerificationQR.fromUrlString('bitchat://verify?v=1&noise=aa&sign=bb&nick=x&ts=abc&nonce=NA&sig=ff'),
    'non-integer timestamp rejected');
  t.isNull(VerificationQR.fromUrlString('bitchat://verify?v=%zz&noise=aa&sign=bb&nick=x&ts=5&nonce=NA&sig=ff'),
    'bad percent-encoding rejected');
  t.isNull(VerificationQR.fromUrlString('bitchat://verify?v=1&noise'),
    'pair without equals sign rejected');
}

function verificationMyQrBuild(t: ContractAssert): void {
  VerificationService.clearQrCache();
  const signer: VcFakeSigner = new VcFakeSigner();
  let nonceCalls: number = 0;
  const nonce: Uint8Array = vcFixedNonce();
  const nonceFactory = (): Uint8Array => {
    nonceCalls += 1;
    return nonce;
  };

  const out1: string | null = VerificationService.buildMyQRString(signer, 'alice', null, 1000000, nonceFactory);
  t.isNotNull(out1, 'my QR builds');
  if (out1 === null) {
    return;
  }
  t.equalNumber(1, nonceCalls, 'fresh build mints one nonce');

  const parsed1: VerificationQR | null = VerificationQR.fromUrlString(out1);
  t.isNotNull(parsed1, 'built QR parses back');
  if (parsed1 === null) {
    return;
  }
  t.equalNumber(1, parsed1.v, 'built QR version');
  t.equalString(vcHexRepeat('0a', 32), parsed1.noiseKeyHex, 'built QR carries the noise static key');
  t.equalString(vcHexRepeat('0b', 32), parsed1.signKeyHex, 'built QR carries the signing key');
  t.equalString('alice', parsed1.nickname, 'built QR carries the nickname');
  t.equalNumber(1000, parsed1.ts, 'built QR timestamp is epoch seconds');
  t.equalString(ByteUtils.base64UrlEncode(nonce), parsed1.nonceB64, 'built QR nonce is base64url of the minted nonce');
  t.isNull(parsed1.npub, 'null npub omitted');
  t.equalString(ByteUtils.bytesToHex(ByteUtils.sha256(parsed1.canonicalBytes())), parsed1.sigHex,
    'signature covers the canonical bytes');

  const cached: string | null = VerificationService.buildMyQRString(signer, 'alice', null, 1050000, nonceFactory);
  t.equalString(out1, cached ?? '', 'same identity within 60s reuses the cached QR');
  t.equalNumber(1, nonceCalls, 'cache hit does not mint a new nonce');

  const expired: string | null = VerificationService.buildMyQRString(signer, 'alice', null, 1060000, nonceFactory);
  t.isNotNull(expired, 'expired cache rebuilds');
  if (expired === null) {
    return;
  }
  t.equalNumber(2, nonceCalls, 'expired cache mints a new nonce');
  const parsedExpired: VerificationQR | null = VerificationQR.fromUrlString(expired);
  t.isNotNull(parsedExpired, 'rebuilt QR parses');
  if (parsedExpired !== null) {
    t.equalNumber(1060, parsedExpired.ts, 'rebuilt QR refreshes the timestamp');
  }

  const renamed: string | null = VerificationService.buildMyQRString(signer, 'bob', null, 1060001, nonceFactory);
  t.isNotNull(renamed, 'nickname change rebuilds');
  t.equalNumber(3, nonceCalls, 'nickname change busts the cache');

  const withNpub: string | null =
    VerificationService.buildMyQRString(signer, 'bob', 'npub1xyz', 1060002, nonceFactory);
  t.isNotNull(withNpub, 'npub change rebuilds');
  t.equalNumber(4, nonceCalls, 'npub change busts the cache');

  const emptyNonce: string | null =
    VerificationService.buildMyQRString(signer, 'carol', null, 2000000, (): Uint8Array => new Uint8Array(0));
  t.isNull(emptyNonce, 'empty nonce rejected');

  signer.failSign = true;
  VerificationService.clearQrCache();
  const failedSign: string | null =
    VerificationService.buildMyQRString(signer, 'dave', null, 3000000, nonceFactory);
  t.isNull(failedSign, 'signing failure rejected');
  signer.failSign = false;
  VerificationService.clearQrCache();
}

function verificationFreshnessWindow(t: ContractAssert): void {
  VerificationService.clearQrCache();
  const signer: VcFakeSigner = new VcFakeSigner();
  const nonceFactory = (): Uint8Array => vcFixedNonce();
  const okVerifier = (signature: Uint8Array, data: Uint8Array, publicKey: Uint8Array): boolean =>
    ByteUtils.equals(signature, ByteUtils.sha256(data));

  const url: string | null = VerificationService.buildMyQRString(signer, 'alice', null, 1000000, nonceFactory);
  t.isNotNull(url, 'freshness fixture builds');
  if (url === null) {
    return;
  }

  t.isNotNull(VerificationService.verifyScannedQR(url, 1000000, okVerifier), 'fresh QR accepted');
  t.isNotNull(VerificationService.verifyScannedQR(url, 1300000, okVerifier), '+300s boundary accepted');
  t.isNull(VerificationService.verifyScannedQR(url, 1301000, okVerifier), '+301s rejected');
  t.isNotNull(VerificationService.verifyScannedQR(url, 700000, okVerifier), '-300s boundary accepted');
  t.isNull(VerificationService.verifyScannedQR(url, 699000, okVerifier), '-301s rejected');

  t.isNotNull(VerificationService.verifyScannedQR(url, 1300000, okVerifier, 300), 'custom window 300 accepts boundary');
  t.isNull(VerificationService.verifyScannedQR(url, 1300000, okVerifier, 299), 'custom window 299 rejects');

  const denyVerifier = (signature: Uint8Array, data: Uint8Array, publicKey: Uint8Array): boolean => false;
  t.isNull(VerificationService.verifyScannedQR(url, 1000000, denyVerifier), 'failing verifier rejects');

  const tamperedNick: string = url.replace('nick=alice', 'nick=alice2');
  t.isNull(VerificationService.verifyScannedQR(tamperedNick, 1000000, okVerifier), 'nickname tamper rejected');
  const tamperedVersion: string = url.replace('v=1&', 'v=2&');
  t.isNull(VerificationService.verifyScannedQR(tamperedVersion, 1000000, okVerifier), 'version tamper rejected');
  const noSigIndex: number = url.indexOf('&sig=');
  t.isTrue(noSigIndex > 0, 'sig parameter located');
  t.isNull(VerificationService.verifyScannedQR(url.substring(0, noSigIndex), 1000000, okVerifier),
    'missing sig parameter rejected');
  t.isNull(VerificationService.verifyScannedQR('https://evil?x=1', 1000000, okVerifier), 'foreign scheme rejected');
  t.isNull(VerificationService.verifyScannedQR('bitchat://verify?v=1&noise=aa&sign=bb&nick=x&ts=1000&nonce=NA&sig=',
    1000000, okVerifier), 'empty signature rejected');
  t.isNull(VerificationService.verifyScannedQR(
    'bitchat://verify?v=1&noise=aa&sign=bb&nick=x&ts=1000000000000000&nonce=NA&sig=ff',
    1000000, okVerifier), 'hostile far-future timestamp rejected');
  VerificationService.clearQrCache();
}

function verificationChallengeResponseTlv(t: ContractAssert): void {
  const noiseHex: string = vcHexRepeat('ab', 32);
  const nonceA: Uint8Array = vcFixedNonce();

  const challenge: Uint8Array = VerificationService.buildVerifyChallenge(noiseHex, nonceA);
  t.equalBytes(ByteUtils.hexToBytes('0140' + vcHexRepeat('6162', 32) +
    '0210000102030405060708090a0b0c0d0e0f'), challenge, 'challenge TLV golden layout');

  const parsedChallenge: VerifyChallenge | null = VerificationService.parseVerifyChallenge(challenge);
  t.isNotNull(parsedChallenge, 'challenge parses');
  if (parsedChallenge !== null) {
    t.equalString(noiseHex, parsedChallenge.noiseKeyHex, 'challenge noise key round trips');
    t.equalBytes(nonceA, parsedChallenge.nonceA, 'challenge nonce round trips');
  }

  t.isNull(VerificationService.parseVerifyChallenge(challenge.subarray(0, 10)), 'truncated challenge rejected');
  t.isNull(VerificationService.parseVerifyChallenge(ByteUtils.hexToBytes('020161')), 'wrong challenge type byte rejected');
  t.isNull(VerificationService.parseVerifyChallenge(ByteUtils.hexToBytes('01026162')), 'challenge missing nonce section rejected');
  t.isNull(VerificationService.parseVerifyChallenge(new Uint8Array(0)), 'empty challenge rejected');

  const emptyNonceChallenge: Uint8Array =
    VerificationService.buildVerifyChallenge(noiseHex, new Uint8Array(0));
  const parsedEmpty: VerifyChallenge | null = VerificationService.parseVerifyChallenge(emptyNonceChallenge);
  t.isNotNull(parsedEmpty, 'challenge with empty nonce parses');
  if (parsedEmpty !== null) {
    t.equalNumber(0, parsedEmpty.nonceA.length, 'empty nonce round trips');
  }

  const signer: VcFakeSigner = new VcFakeSigner();
  const response: Uint8Array | null = VerificationService.buildVerifyResponse(signer, noiseHex, nonceA);
  t.isNotNull(response, 'response builds');
  if (response === null) {
    return;
  }

  const expectedMessage: Uint8Array = ByteUtils.concat(
    ByteUtils.utf8Encode(VERIFICATION_RESPONSE_CONTEXT),
    ByteUtils.hexToBytes('40'),
    ByteUtils.utf8Encode(noiseHex),
    nonceA);
  t.equalBytes(expectedMessage, signer.lastSigned,
    'response signature covers [context][len][noiseKeyHex][nonceA raw]');

  const expectedResponse: Uint8Array = ByteUtils.concat(
    ByteUtils.hexToBytes('0140'),
    ByteUtils.utf8Encode(noiseHex),
    ByteUtils.hexToBytes('0210'),
    nonceA,
    ByteUtils.hexToBytes('0320'),
    ByteUtils.sha256(expectedMessage));
  t.equalBytes(expectedResponse, response, 'response TLV golden layout');

  const parsedResponse: VerifyResponse | null = VerificationService.parseVerifyResponse(response);
  t.isNotNull(parsedResponse, 'response parses');
  if (parsedResponse === null) {
    return;
  }
  t.equalString(noiseHex, parsedResponse.noiseKeyHex, 'response noise key round trips');
  t.equalBytes(nonceA, parsedResponse.nonceA, 'response nonce round trips');
  t.equalBytes(ByteUtils.sha256(expectedMessage), parsedResponse.signature, 'response signature round trips');

  t.isNull(VerificationService.parseVerifyResponse(response.subarray(0, response.length - 1)),
    'truncated response rejected');
  t.isNull(VerificationService.parseVerifyResponse(response.subarray(0, 84)), 'response missing signature section rejected');
  t.isNull(VerificationService.parseVerifyResponse(new Uint8Array(0)), 'empty response rejected');

  const strictVerifier = (signature: Uint8Array, data: Uint8Array, publicKey: Uint8Array): boolean =>
    ByteUtils.equals(publicKey, signer.getSigningPublicKey()) &&
    ByteUtils.equals(signature, ByteUtils.sha256(data));
  const signerKeyHex: string = vcHexRepeat('0b', 32);

  t.isTrue(VerificationService.verifyResponseSignature(noiseHex, nonceA, parsedResponse.signature,
    signerKeyHex, strictVerifier), 'valid response signature verifies');

  const tamperedSig: Uint8Array = new Uint8Array(parsedResponse.signature);
  tamperedSig[0] = (tamperedSig[0] + 1) % 256;
  t.isFalse(VerificationService.verifyResponseSignature(noiseHex, nonceA, tamperedSig,
    signerKeyHex, strictVerifier), 'tampered signature rejected');

  const wrongNonce: Uint8Array = new Uint8Array(nonceA);
  wrongNonce[0] = (wrongNonce[0] + 1) % 256;
  t.isFalse(VerificationService.verifyResponseSignature(noiseHex, wrongNonce, parsedResponse.signature,
    signerKeyHex, strictVerifier), 'wrong nonce rejected');

  t.isFalse(VerificationService.verifyResponseSignature(noiseHex, nonceA, parsedResponse.signature,
    vcHexRepeat('0c', 32), strictVerifier), 'wrong signer key rejected');
  t.isFalse(VerificationService.verifyResponseSignature(noiseHex, nonceA, parsedResponse.signature,
    'zz', strictVerifier), 'malformed signer key rejected');
}
