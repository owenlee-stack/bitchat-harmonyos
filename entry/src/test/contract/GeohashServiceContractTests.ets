/**
 * Contract vectors for the geohash location-channel service (T066, spec
 * US13), mirrored from bitchat-android: Geohash.kt (base32 codec golden
 * vectors, bounds, neighbors with longitude wrap / latitude clamp / polar
 * collapse), LocationChannel.kt + LocationChannelsSheet.kt (six levels,
 * levelForLength, channel id/displayName), NostrIdentityBridge
 * .deriveIdentity (HMAC-SHA256 iteration format lock, caching,
 * determinism, unlinkability), NostrProofOfWork.kt (NIP-13 difficulty
 * vectors, nonce accessors, validation, deterministic mining) and
 * NostrProtocol.kt (kind 20000 chat with g/n/t tags, PoW difficulty 12
 * off by default, kind 20001 presence with empty content, the 40-80s
 * heartbeat band and the 1h presence lookback).
 */
import { ContractAssert } from './ContractAssert';
import { ByteUtils, HmacSha256 } from '../../main/ets/common/ByteUtils';
import {
  Geohash,
  GeohashBounds,
  GeohashChannel,
  GeohashChannelLevel,
  GeohashLevels,
  GeohashPoint,
  GeohashPowSettings,
  GeohashService,
  NostrProofOfWork
} from '../../main/ets/service/nostr/GeohashService';
import { NostrEvent, NostrKind } from '../../main/ets/service/nostr/NostrEvent';
import { NostrIdentity } from '../../main/ets/service/nostr/NostrIdentity';
import { NostrRandomSource } from '../../main/ets/service/nostr/NostrRandomSource';
import { Secp256k1 } from '../../main/ets/service/nostr/Secp256k1';

function u32le(value: number): Uint8Array {
  const out: Uint8Array = new Uint8Array(4);
  out[0] = value & 0xFF;
  out[1] = (value >>> 8) & 0xFF;
  out[2] = (value >>> 16) & 0xFF;
  out[3] = (value >>> 24) & 0xFF;
  return out;
}

function fixedNow(): number {
  return 1737000000000;
}

class ScriptedRandom implements NostrRandomSource {
  private readonly scriptedInts: number[];
  private intIndex: number = 0;
  private byteCounter: number = 0;

  constructor(scriptedInts: number[]) {
    this.scriptedInts = scriptedInts;
  }

  nextBytes(count: number): Uint8Array {
    const out: Uint8Array = new Uint8Array(count);
    for (let i: number = 0; i < count; i++) {
      out[i] = (this.byteCounter + i) & 0xFF;
    }
    this.byteCounter += count;
    return out;
  }

  nextInt(bound: number): number {
    const raw: number = this.scriptedInts[this.intIndex % this.scriptedInts.length];
    this.intIndex += 1;
    return raw % bound;
  }
}

const DEVICE_SEED_HEX: string =
  '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20';

export function runGeohashServiceContractTests(t: ContractAssert): void {
  const seed: Uint8Array = ByteUtils.hexToBytes(DEVICE_SEED_HEX);

  // Codec: canonical base32 golden vectors plus clamping and bounds.
  {
    t.equalString('ezs42', Geohash.encode(42.605, -5.603, 5),
      'golden vector: (42.605, -5.603) at precision 5 encodes to ezs42');
    t.equalString('u4pruydqqvj', Geohash.encode(57.64911, 10.40744, 11),
      'golden vector: (57.64911, 10.40744) at precision 11 encodes to u4pruydqqvj');
    t.equalString('', Geohash.encode(42.6, -5.6, 0),
      'precision 0 encodes to the empty string');
    t.equalString('', Geohash.encode(42.6, -5.6, -3),
      'negative precision encodes to the empty string');
    t.equalString('ez', Geohash.encode(42.605, -5.603, 2),
      'the 2-char code prefixes the 5-char code');
    t.equalString(Geohash.encode(90, 180, 5), Geohash.encode(91, 181, 5),
      'coordinates above the range are clamped before encoding');
    t.equalString(Geohash.encode(-90, -180, 5), Geohash.encode(-91, -181, 5),
      'coordinates below the range are clamped before encoding');

    const b: GeohashBounds = Geohash.decodeToBounds('ezs42');
    t.isTrue(Math.abs((b.latMax - b.latMin) - 180 / 4096) < 1e-9,
      'a 5-char cell spans 12 latitude bits');
    t.isTrue(Math.abs((b.lonMax - b.lonMin) - 360 / 8192) < 1e-9,
      'a 5-char cell spans 13 longitude bits');
    const c: GeohashPoint = Geohash.decodeToCenter('ezs42');
    t.equalString('ezs42', Geohash.encode(c.lat, c.lon, 5),
      'the cell center re-encodes to the same cell');
    t.isTrue(c.lat >= b.latMin && c.lat <= b.latMax && c.lon >= b.lonMin && c.lon <= b.lonMax,
      'the decoded center lies within its bounds');

    const empty: GeohashBounds = Geohash.decodeToBounds('');
    t.equalNumber(0, empty.latMin, 'an empty geohash decodes to the zero bounds');
    t.equalNumber(0, empty.lonMax, 'an empty geohash has zero longitude extent');
    const bad: GeohashBounds = Geohash.decodeToBounds('ea');
    t.equalNumber(0, bad.latMin,
      'a character outside the base32 alphabet decodes to the zero bounds');
    const upper: GeohashBounds = Geohash.decodeToBounds('EZS42');
    t.equalNumber(b.latMin, upper.latMin, 'uppercase geohash input is accepted');
    t.equalNumber(b.lonMax, upper.lonMax, 'uppercase bounds match the lowercase ones');
  }

  // Neighbors: eight distinct cells mid-latitude, collapse at the polar
  // corner, longitude wrap, latitude clamp, center excluded.
  {
    const nbs: string[] = Geohash.neighborsSamePrecision('ezs42');
    t.equalNumber(8, nbs.length, 'a mid-latitude cell has 8 distinct neighbors');
    const seen: Set<string> = new Set();
    for (let i: number = 0; i < nbs.length; i++) {
      const nb: string = nbs[i];
      t.equalNumber(5, nb.length, 'neighbors keep the input precision');
      t.isFalse(nb === 'ezs42', 'the center cell is never its own neighbor');
      t.isFalse(seen.has(nb), 'neighbors are distinct');
      seen.add(nb);
      const center: GeohashPoint = Geohash.decodeToCenter(nb);
      t.equalString(nb, Geohash.encode(center.lat, center.lon, 5),
        'each neighbor round-trips through its center');
    }

    const polar: string[] = Geohash.neighborsSamePrecision('z');
    t.equalNumber(5, polar.length, 'the polar corner cell z has 5 distinct neighbors');
    const polarSeen: Set<string> = new Set(['w', 'x', '8', 'y', 'b']);
    for (let i: number = 0; i < polar.length; i++) {
      const nb: string = polar[i];
      t.equalNumber(1, nb.length, 'polar neighbors keep the 1-char precision');
      t.isFalse(nb === 'z', 'the clamped polar row never yields the center');
      t.isTrue(polarSeen.has(nb), 'polar neighbor ' + nb + ' is one of w/x/8/y/b');
      const center: GeohashPoint = Geohash.decodeToCenter(nb);
      t.equalString(nb, Geohash.encode(center.lat, center.lon, 1),
        'each polar neighbor round-trips through its center');
    }
    t.equalNumber(0, Geohash.neighborsSamePrecision('').length,
      'an empty geohash has no neighbors');
  }

  // Levels: precision values, length mapping, display names, channel ids.
  {
    t.equalNumber(8, GeohashLevels.precision(GeohashChannelLevel.BUILDING),
      'BUILDING maps to precision 8');
    t.equalNumber(7, GeohashLevels.precision(GeohashChannelLevel.BLOCK),
      'BLOCK maps to precision 7');
    t.equalNumber(6, GeohashLevels.precision(GeohashChannelLevel.NEIGHBORHOOD),
      'NEIGHBORHOOD maps to precision 6');
    t.equalNumber(5, GeohashLevels.precision(GeohashChannelLevel.CITY),
      'CITY maps to precision 5');
    t.equalNumber(4, GeohashLevels.precision(GeohashChannelLevel.PROVINCE),
      'PROVINCE maps to precision 4');
    t.equalNumber(2, GeohashLevels.precision(GeohashChannelLevel.REGION),
      'REGION maps to precision 2');

    t.equalNumber(GeohashChannelLevel.REGION, GeohashLevels.levelForLength(0),
      'length 0 maps to REGION');
    t.equalNumber(GeohashChannelLevel.REGION, GeohashLevels.levelForLength(2),
      'length 2 maps to REGION');
    t.equalNumber(GeohashChannelLevel.PROVINCE, GeohashLevels.levelForLength(3),
      'length 3 maps to PROVINCE');
    t.equalNumber(GeohashChannelLevel.PROVINCE, GeohashLevels.levelForLength(4),
      'length 4 maps to PROVINCE');
    t.equalNumber(GeohashChannelLevel.CITY, GeohashLevels.levelForLength(5),
      'length 5 maps to CITY');
    t.equalNumber(GeohashChannelLevel.NEIGHBORHOOD, GeohashLevels.levelForLength(6),
      'length 6 maps to NEIGHBORHOOD');
    t.equalNumber(GeohashChannelLevel.BLOCK, GeohashLevels.levelForLength(7),
      'length 7 maps to BLOCK');
    t.equalNumber(GeohashChannelLevel.BUILDING, GeohashLevels.levelForLength(8),
      'length 8 maps to BUILDING');
    t.equalNumber(GeohashChannelLevel.BUILDING, GeohashLevels.levelForLength(11),
      'length 11 maps to BUILDING');
    t.equalNumber(6, GeohashLevels.allCases().length, 'there are six levels');

    const city: GeohashChannel = new GeohashChannel(GeohashChannelLevel.CITY, 'euwn');
    t.equalString('CITY-euwn', city.channelId(), 'the channel id is LEVEL-geohash');
    t.equalString('City • euwn', city.channelDisplayName(),
      'the channel label is displayName • geohash');
    const region: GeohashChannel = new GeohashChannel(GeohashChannelLevel.REGION, 'ez');
    t.equalString('REGION-ez', region.channelId(), 'REGION keeps the raw enum name in ids');
    t.equalString('REGION • ez', region.channelDisplayName(),
      'REGION keeps the raw enum name as its display name');
  }

  // NIP-13 PoW: difficulty vectors, nonce accessors, validation and
  // deterministic mining.
  {
    t.equalNumber(0, NostrProofOfWork.calculateDifficulty(''),
      'an empty id has difficulty 0');
    t.equalNumber(4, NostrProofOfWork.calculateDifficulty('0'),
      'a leading 0 nibble adds 4 bits');
    t.equalNumber(3, NostrProofOfWork.calculateDifficulty('1'),
      'a leading 1 nibble adds 3 bits');
    t.equalNumber(2, NostrProofOfWork.calculateDifficulty('2'),
      'a leading 2 nibble adds 2 bits');
    t.equalNumber(2, NostrProofOfWork.calculateDifficulty('3'),
      'a leading 3 nibble adds 2 bits');
    t.equalNumber(1, NostrProofOfWork.calculateDifficulty('4'),
      'a leading 4 nibble adds 1 bit');
    t.equalNumber(1, NostrProofOfWork.calculateDifficulty('7'),
      'a leading 7 nibble adds 1 bit');
    t.equalNumber(0, NostrProofOfWork.calculateDifficulty('8'),
      'a leading 8 nibble adds no bits');
    t.equalNumber(0, NostrProofOfWork.calculateDifficulty('f'),
      'a leading f nibble adds no bits');
    t.equalNumber(8, NostrProofOfWork.calculateDifficulty('00'),
      'two zero nibbles add 8 bits');
    t.equalNumber(3, NostrProofOfWork.calculateDifficulty('10'),
      'a leading one nibble stops the count at 3');
    t.equalNumber(7, NostrProofOfWork.calculateDifficulty('01'),
      'a zero then one nibble adds 7 bits');
    t.equalNumber(2, NostrProofOfWork.calculateDifficulty('20'),
      'the first non-zero nibble stops the count');
    t.equalNumber(32, NostrProofOfWork.calculateDifficulty('00000000'),
      'eight zero nibbles add 32 bits');

    let id4: string = '0f';
    for (let i: number = 0; i < 31; i++) {
      id4 += 'ab';
    }
    const withNonce: NostrEvent = new NostrEvent(id4,
      '0101010101010101010101010101010101010101010101010101010101010101',
      1737000000, NostrKind.EPHEMERAL_EVENT,
      [['g', 'ezs42'], ['nonce', '77', '9']], 'x', null);
    t.isTrue(NostrProofOfWork.hasNonce(withNonce), 'hasNonce finds the nonce tag');
    t.equalString('77', NostrProofOfWork.getNonce(withNonce) ?? '',
      'getNonce returns the nonce value');
    t.equalNumber(9, NostrProofOfWork.getCommittedDifficulty(withNonce) ?? -1,
      'getCommittedDifficulty returns the committed target');
    t.isTrue(NostrProofOfWork.validateDifficulty(withNonce, 0),
      'a zero minimum accepts any event');
    t.isTrue(NostrProofOfWork.validateDifficulty(withNonce, 4),
      'a difficulty-4 id with a nonce passes minimum 4');
    t.isFalse(NostrProofOfWork.validateDifficulty(withNonce, 5),
      'a difficulty-4 id fails minimum 5');

    const noNonce: NostrEvent = new NostrEvent(id4,
      '0101010101010101010101010101010101010101010101010101010101010101',
      1737000000, NostrKind.EPHEMERAL_EVENT, [['g', 'ezs42']], 'x', null);
    t.isFalse(NostrProofOfWork.validateDifficulty(noNonce, 4),
      'an event without a nonce tag is treated as no PoW');

    const lowCommitted: NostrEvent = new NostrEvent(id4,
      '0101010101010101010101010101010101010101010101010101010101010101',
      1737000000, NostrKind.EPHEMERAL_EVENT, [['nonce', '5', '3']], 'x', null);
    t.isFalse(NostrProofOfWork.validateDifficulty(lowCommitted, 4),
      'a committed difficulty below the minimum is spam');

    const noCommit: NostrEvent = new NostrEvent(id4,
      '0101010101010101010101010101010101010101010101010101010101010101',
      1737000000, NostrKind.EPHEMERAL_EVENT, [['nonce', '5']], 'x', null);
    t.isTrue(NostrProofOfWork.validateDifficulty(noCommit, 4),
      'an absent committed difficulty falls back to the actual difficulty');

    const base: NostrEvent = new NostrEvent('old',
      '0101010101010101010101010101010101010101010101010101010101010101',
      1, NostrKind.EPHEMERAL_EVENT,
      [['g', 'ezs42'], ['nonce', '9', '3']], 'c', null);
    const tagged: NostrEvent =
      NostrProofOfWork.withNonceTag(base, '42', 8, 1737000000000);
    t.equalNumber(1737000000, tagged.createdAt,
      'withNonceTag refreshes created_at to nowMs/1000');
    t.equalNumber(2, tagged.tags.length, 'withNonceTag replaces the old nonce tag');
    t.equalString('g', tagged.tags[0][0], 'the g tag keeps its position');
    t.equalString('nonce', tagged.tags[1][0], 'the fresh nonce tag lands last');
    t.equalString('42', tagged.tags[1][1], 'the fresh nonce value is kept');
    t.equalString('8', tagged.tags[1][2], 'the fresh target difficulty is kept');
    t.equalString('c', tagged.content, 'withNonceTag preserves the content');

    const unmined: NostrEvent =
      NostrProofOfWork.mineEvent(base, 0, 10, 0, 1737000000000);
    t.isTrue(unmined === base, 'difficulty 0 returns the event unchanged');

    const mined: NostrEvent | null =
      NostrProofOfWork.mineEvent(base, 8, 100000, 0, 1737000000000);
    t.isNotNull(mined, 'difficulty 8 mines within 100000 iterations');
    if (mined !== null) {
      t.isTrue(NostrProofOfWork.calculateDifficulty(mined.id) >= 8,
        'the mined id reaches the target difficulty');
      t.equalString(mined.computeEventIdHex(), mined.id,
        'the mined id matches the canonical serialization');
      t.equalNumber(8, NostrProofOfWork.getCommittedDifficulty(mined) ?? -1,
        'the mined event commits the target difficulty');
      t.equalNumber(1737000000, mined.createdAt,
        'mining stamps created_at at nowMs/1000');
    }
    const minedAgain: NostrEvent | null =
      NostrProofOfWork.mineEvent(base, 8, 100000, 0, 1737000000000);
    t.isNotNull(minedAgain, 'the repeat mining run also succeeds');
    if (mined !== null && minedAgain !== null) {
      t.equalString(mined.id, minedAgain.id,
        'mining is deterministic for a fixed start nonce');
    }
    const impossible: NostrEvent | null =
      NostrProofOfWork.mineEvent(base, 64, 10, 0, 1737000000000);
    t.isNull(impossible, '10 iterations cannot mine 64 bits');
  }

  // Identity derivation: HMAC format lock, caching, determinism and
  // unlinkability across geohashes and seeds.
  {
    const service: GeohashService =
      new GeohashService(fixedNow, new ScriptedRandom([0]), seed);
    const identity: NostrIdentity = service.deriveIdentity('ezs42');

    let expectedHex: string = '';
    for (let i: number = 0; i < 10; i++) {
      const candidate: Uint8Array = HmacSha256.compute(seed,
        ByteUtils.concat(ByteUtils.utf8Encode('ezs42'), u32le(i)));
      const candidateHex: string = ByteUtils.bytesToHex(candidate);
      if (Secp256k1.isValidPrivateKey(candidateHex)) {
        expectedHex = candidateHex;
        break;
      }
    }
    t.isTrue(expectedHex.length > 0, 'the first HMAC candidate is a valid private key');
    t.equalString(expectedHex, identity.privateKeyHex,
      'the derived key is the first valid HMAC-SHA256(seed, geohash || u32le(i)) candidate');
    t.equalString(Secp256k1.derivePublicKey(expectedHex), identity.publicKeyHex,
      'the derived public key matches the private key');
    t.isTrue(identity.npub.startsWith('npub1'),
      'the derived identity carries an npub bech32 encoding');

    t.isTrue(service.deriveIdentity('ezs42') === identity,
      'identities are cached per geohash');
    const serviceAgain: GeohashService =
      new GeohashService(fixedNow, new ScriptedRandom([0]), seed);
    t.equalString(identity.privateKeyHex, serviceAgain.deriveIdentity('ezs42').privateKeyHex,
      'the same seed derives the same geohash identity');

    const otherGeo: NostrIdentity = service.deriveIdentity('ezs43');
    t.isFalse(otherGeo.privateKeyHex === identity.privateKeyHex,
      'a different geohash derives a different identity');
    const otherSeed: Uint8Array = ByteUtils.hexToBytes(
      '201f1e1d1c1b1a191817161514131211100f0e0d0c0b0a090807060504030201');
    const otherSeedService: GeohashService =
      new GeohashService(fixedNow, new ScriptedRandom([0]), otherSeed);
    t.isFalse(otherSeedService.deriveIdentity('ezs42').privateKeyHex === identity.privateKeyHex,
      'a different device seed derives a different identity');
  }

  // Chat events: kind 20000, g/n/t tags, derived pubkey, valid
  // signature, PoW off by default and mined when enabled.
  {
    t.isFalse(GeohashPowSettings.defaults().enabled, 'PoW is disabled by default');
    t.equalNumber(12, GeohashPowSettings.defaults().difficulty,
      'the default PoW difficulty is 12');
    t.equalNumber(12, GeohashService.DEFAULT_POW_DIFFICULTY,
      'the canonical default difficulty constant is 12');

    const service: GeohashService =
      new GeohashService(fixedNow, new ScriptedRandom([0]), seed);
    const event: NostrEvent = service.createChatEvent('hello geohash', 'ezs42',
      'nick', true, GeohashPowSettings.defaults());
    t.equalNumber(NostrKind.EPHEMERAL_EVENT, event.kind,
      'geohash chat is a kind 20000 ephemeral event');
    t.equalString('hello geohash', event.content, 'the chat content is preserved');
    t.equalNumber(1737000000, event.createdAt, 'created_at is nowMs/1000');
    t.equalNumber(3, event.tags.length, 'g, n and teleport tags are all present');
    t.equalString('g', event.tags[0][0], 'the g tag comes first');
    t.equalString('ezs42', event.tags[0][1], 'the g tag carries the geohash');
    t.equalString('n', event.tags[1][0], 'the nickname tag comes second');
    t.equalString('nick', event.tags[1][1], 'the nickname tag carries the nickname');
    t.equalString('t', event.tags[2][0], 'the teleport marker comes last');
    t.equalString('teleport', event.tags[2][1], 'the teleport marker is t/teleport');
    t.equalString(service.deriveIdentity('ezs42').publicKeyHex, event.pubkey,
      'the chat event is signed by the geohash-derived identity');
    t.equalString(event.computeEventIdHex(), event.id,
      'the id matches the canonical serialization');
    t.isTrue(event.isValidSignature(), 'the chat event signature verifies');
    t.isFalse(NostrProofOfWork.hasNonce(event), 'default settings mine no nonce');

    const bare: NostrEvent = service.createChatEvent('bare', 'ezs42', null, false,
      GeohashPowSettings.defaults());
    t.equalNumber(1, bare.tags.length, 'no nickname and no teleport leave only the g tag');
    const emptyNick: NostrEvent = service.createChatEvent('x', 'ezs42', '', false,
      GeohashPowSettings.defaults());
    t.equalNumber(1, emptyNick.tags.length, 'an empty nickname adds no n tag');
    const noTeleport: NostrEvent = service.createChatEvent('y', 'ezs42', 'n2', false,
      GeohashPowSettings.defaults());
    t.equalNumber(2, noTeleport.tags.length, 'a nickname without teleport omits the t tag');

    const minedChat: NostrEvent = service.createChatEvent('mined', 'ezs42', null, false,
      new GeohashPowSettings(true, 8));
    t.isTrue(NostrProofOfWork.hasNonce(minedChat), 'enabled PoW mines a nonce tag');
    t.isTrue(NostrProofOfWork.calculateDifficulty(minedChat.id) >= 8,
      'the mined chat id reaches the target difficulty');
    t.equalNumber(8, NostrProofOfWork.getCommittedDifficulty(minedChat) ?? -1,
      'the mined chat event commits the target difficulty');
    t.isTrue(minedChat.isValidSignature(), 'the mined chat event is still validly signed');
    t.isTrue(NostrProofOfWork.validateDifficulty(minedChat, 8),
      'the mined chat event validates against its own difficulty');
  }

  // Presence events: kind 20001, empty content, only the g tag, signed
  // by the same derived identity.
  {
    const service: GeohashService =
      new GeohashService(fixedNow, new ScriptedRandom([0]), seed);
    const event: NostrEvent = service.createPresenceEvent('ezs42');
    t.equalNumber(NostrKind.GEOHASH_PRESENCE, event.kind,
      'presence is a kind 20001 heartbeat');
    t.equalString('', event.content, 'presence carries an empty content');
    t.equalNumber(1, event.tags.length, 'presence carries only the g tag');
    t.equalString('g', event.tags[0][0], 'the presence tag is g');
    t.equalString('ezs42', event.tags[0][1], 'the presence g tag carries the geohash');
    t.equalString(service.deriveIdentity('ezs42').publicKeyHex, event.pubkey,
      'presence is signed by the geohash-derived identity');
    t.equalNumber(1737000000, event.createdAt, 'presence created_at is nowMs/1000');
    t.isTrue(event.isValidSignature(), 'the presence signature verifies');
  }

  // Presence policy, heartbeat band, lookback and mining cap.
  {
    const service: GeohashService =
      new GeohashService(fixedNow, new ScriptedRandom([0, 40000, 12345]), seed);
    t.isTrue(service.presenceBroadcastAllowed(GeohashChannelLevel.REGION),
      'presence may be broadcast at REGION');
    t.isTrue(service.presenceBroadcastAllowed(GeohashChannelLevel.PROVINCE),
      'presence may be broadcast at PROVINCE');
    t.isTrue(service.presenceBroadcastAllowed(GeohashChannelLevel.CITY),
      'presence may be broadcast at CITY');
    t.isFalse(service.presenceBroadcastAllowed(GeohashChannelLevel.NEIGHBORHOOD),
      'presence is denied at NEIGHBORHOOD');
    t.isFalse(service.presenceBroadcastAllowed(GeohashChannelLevel.BLOCK),
      'presence is denied at BLOCK');
    t.isFalse(service.presenceBroadcastAllowed(GeohashChannelLevel.BUILDING),
      'presence is denied at BUILDING');

    t.equalNumber(3600000, GeohashService.PRESENCE_LOOKBACK_MS,
      'presence looks back one hour');
    t.equalNumber(1737000000000 - 3600000,
      GeohashService.presenceFilterSinceMs(1737000000000),
      'the presence filter since timestamp is one hour back');
    t.equalNumber(40000, GeohashService.HEARTBEAT_MIN_INTERVAL_MS,
      'the heartbeat band starts at 40 seconds');
    t.equalNumber(80000, GeohashService.HEARTBEAT_MAX_INTERVAL_MS,
      'the heartbeat band ends at 80 seconds');
    t.equalNumber(40000, service.nextHeartbeatIntervalMs(),
      'a scripted 0 draw gives the 40s floor');
    t.equalNumber(80000, service.nextHeartbeatIntervalMs(),
      'a scripted max draw gives the 80s ceiling');
    t.equalNumber(52345, service.nextHeartbeatIntervalMs(),
      'an in-between draw stays inside the band');
    t.equalNumber(2000000, GeohashService.MAX_MINING_ITERATIONS,
      'geohash mining allows two million iterations');
  }
}
