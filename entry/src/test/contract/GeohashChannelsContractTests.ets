/**
 * Contract vectors for the geohash location-channel UI plumbing (T068,
 * spec US13), mirrored from bitchat-android: GeohashBookmarksStore.kt
 * (normalize trim/lowercase/'#'/base32 filtering, newest-first bookmark
 * JSON persistence, toggle semantics), LocationChannelsSheet.kt
 * (validateGeohash, coverageString precision labels), the offline
 * place-name display (nearest gazetteer city via haversine, '~' label,
 * cell-diagonal search radius) and the inbound event classification
 * (kind 20000 chat g/n/t tags, kind 20001 presence, geohash
 * normalization on the g tag).
 */
import { ContractAssert } from './ContractAssert';
import { GeohashBookmarkCodec, GeohashBookmarkToggle, GeohashChannels,
  GeohashEventRouter, GeohashPlace, GeohashPlaceResolver } from
  '../../main/ets/service/nostr/GeohashChannels';
import { GlobeCity } from '../../main/ets/service/globe/GlobeWorldData';
import { NostrEvent, NostrKind } from '../../main/ets/service/nostr/NostrEvent';

const CHAT_PUBKEY: string =
  '0101010101010101010101010101010101010101010101010101010101010101';

export function runGeohashChannelsContractTests(t: ContractAssert): void {
  // Input normalization: trim, lowercase, strip '#' and drop every
  // non-base32 character (Android GeohashBookmarksStore.normalize).
  {
    t.equalString('ezs42', GeohashChannels.normalize('  #EZS42 '),
      'leading/trailing space, # and uppercase all normalize away');
    t.equalString('ezs42', GeohashChannels.normalize('ezs42!'),
      'a non-alphabet suffix is dropped');
    t.equalString('ezs', GeohashChannels.normalize('e-z_s'),
      'punctuation inside the input is dropped');
    t.equalString('b', GeohashChannels.normalize('abilo'),
      'the base32 alphabet excludes a, i, l and o');
    t.equalString('', GeohashChannels.normalize('   '),
      'whitespace-only input normalizes to the empty string');
    t.equalString('', GeohashChannels.normalize('###!'),
      'input with no base32 characters normalizes to the empty string');
  }

  // Validation: 1..12 base32 characters (Android validateGeohash).
  {
    t.isTrue(GeohashChannels.isValid('ezs42'), 'a canonical geohash is valid');
    t.isTrue(GeohashChannels.isValid('z'), 'a single base32 character is valid');
    t.isTrue(GeohashChannels.isValid('u33d8pupupup'),
      'a 12-character geohash is still valid');
    t.isFalse(GeohashChannels.isValid(''), 'the empty string is invalid');
    t.isFalse(GeohashChannels.isValid('a'), 'a is not in the base32 alphabet');
    t.isFalse(GeohashChannels.isValid('ezs4z!'),
      'non-alphabet characters invalidate the input');
    t.isFalse(GeohashChannels.isValid('u33d8pupupup2'),
      'more than 12 characters is invalid');
  }

  // Coverage labels: precision-to-extent strings (Android
  // LocationChannelsSheet coverageString).
  {
    t.equalString('~5000 km', GeohashChannels.coverageString(1),
      'precision 1 covers ~5000 km');
    t.equalString('~1250 km', GeohashChannels.coverageString(2),
      'precision 2 covers ~1250 km');
    t.equalString('~156 km', GeohashChannels.coverageString(3),
      'precision 3 covers ~156 km');
    t.equalString('~39.1 km', GeohashChannels.coverageString(4),
      'precision 4 covers ~39.1 km');
    t.equalString('~4.9 km', GeohashChannels.coverageString(5),
      'precision 5 covers ~4.9 km');
    t.equalString('~1.2 km', GeohashChannels.coverageString(6),
      'precision 6 covers ~1.2 km');
    t.equalString('~153 m', GeohashChannels.coverageString(7),
      'precision 7 covers ~153 m');
    t.equalString('~38 m', GeohashChannels.coverageString(8),
      'precision 8 covers ~38 m');
    t.equalString('~5 m', GeohashChannels.coverageString(9),
      'precision 9 covers ~5 m');
  }

  // Bookmark codec: JSON round-trip, corrupt input, normalization and
  // de-duplication on load, newest-first toggle (Android
  // GeohashBookmarksStore semantics).
  {
    t.equalString('["ezs42","u4pru"]', GeohashBookmarkCodec.toJson(['ezs42', 'u4pru']),
      'the bookmark list serializes as a JSON string array');
    t.equalString('[]', GeohashBookmarkCodec.toJson([]),
      'an empty list serializes as an empty JSON array');

    const roundTrip: string[] =
      GeohashBookmarkCodec.fromJson(GeohashBookmarkCodec.toJson(['ezs42', 'u4pru']));
    t.equalNumber(2, roundTrip.length, 'the JSON round-trip keeps every entry');
    t.equalString('ezs42', roundTrip[0], 'the round-trip preserves the order');
    t.equalString('u4pru', roundTrip[1], 'the round-trip preserves the values');

    t.equalNumber(0, GeohashBookmarkCodec.fromJson('not json').length,
      'a corrupt document yields the empty list');
    t.equalNumber(0, GeohashBookmarkCodec.fromJson('{"a":1}').length,
      'a non-array document yields the empty list');
    t.equalNumber(0, GeohashBookmarkCodec.fromJson('[1,2]').length,
      'non-string entries are dropped');

    const messy: string[] =
      GeohashBookmarkCodec.fromJson('["EZS42","ezs42","#u33","x",null]');
    t.equalNumber(3, messy.length,
      'entries are normalized and duplicates dropped');
    t.equalString('ezs42', messy[0], 'uppercase entries normalize on load');
    t.equalString('u33', messy[1], 'the # prefix is stripped on load');
    t.equalString('x', messy[2], 'valid short entries are kept');

    const added: GeohashBookmarkToggle = GeohashBookmarkCodec.toggle([], 'ezs42');
    t.isTrue(added.added, 'toggling a fresh geohash adds it');
    t.equalNumber(1, added.list.length, 'the added list holds one entry');
    t.equalString('ezs42', added.list[0], 'the added entry is the geohash');

    const removed: GeohashBookmarkToggle =
      GeohashBookmarkCodec.toggle(['ezs42'], 'ezs42');
    t.isFalse(removed.added, 'toggling a bookmarked geohash removes it');
    t.equalNumber(0, removed.list.length, 'the removed list is empty');

    const front: GeohashBookmarkToggle =
      GeohashBookmarkCodec.toggle(['a', 'b'], 'c');
    t.isTrue(front.added, 'a new entry is added');
    t.equalString('c', front.list[0], 'a new entry lands at the front');
    t.equalString('a', front.list[1], 'the previous order is preserved');
    t.equalString('b', front.list[2], 'the previous tail is preserved');

    const normalized: GeohashBookmarkToggle =
      GeohashBookmarkCodec.toggle([], '#E');
    t.isTrue(normalized.added, 'toggle normalizes its input');
    t.equalString('e', normalized.list[0], 'the normalized entry is stored');

    const nothing: GeohashBookmarkToggle = GeohashBookmarkCodec.toggle(['a'], '!?');
    t.isFalse(nothing.added, 'an unparsable input toggles nothing');
    t.equalNumber(1, nothing.list.length, 'the list is unchanged');
  }

  // Offline place-name resolution: haversine distance, cell diagonal
  // and the nearest gazetteer city with the '~' label.
  {
    const berlinToParis: number =
      GeohashPlaceResolver.haversineKm(52.5200, 13.4050, 48.8566, 2.3522);
    t.isTrue(Math.abs(berlinToParis - 878) < 5,
      'the Berlin-Paris haversine distance is ~878 km');
    t.isTrue(Math.abs(GeohashPlaceResolver.haversineKm(10, 20, 10, 20)) < 1e-9,
      'the distance between identical points is zero');

    const diagonal: number = GeohashPlaceResolver.cellDiagonalKm('ezs42');
    t.isTrue(diagonal > 5 && diagonal < 9,
      'the 5-char cell diagonal is between 5 and 9 km');
    t.equalNumber(0, GeohashPlaceResolver.cellDiagonalKm(''),
      'an invalid geohash has a zero diagonal');

    const cities: GlobeCity[] = [
      new GlobeCity('Berlin', 52.5200, 13.4050, 1, true, true),
      new GlobeCity('Paris', 48.8566, 2.3522, 1, true, true)
    ];

    const near: GeohashPlace | null =
      GeohashPlaceResolver.nearestCity(cities, 'u33', 200);
    t.isNotNull(near, 'Berlin is found near the u33 cell');
    if (near !== null) {
      t.equalString('Berlin', near.name, 'u33 resolves to Berlin');
      t.isTrue(near.distanceKm > 0 && near.distanceKm < 100,
        'the Berlin distance is below 100 km');
    }

    const none: GeohashPlace | null =
      GeohashPlaceResolver.nearestCity(cities, 'u33', 1);
    t.isNull(none, 'a radius below the distance finds nothing');
    t.isNull(GeohashPlaceResolver.nearestCity(cities, '', 200),
      'an invalid geohash resolves to no city');

    t.equalString('~Berlin', GeohashPlaceResolver.placeLabel(cities, 'u33'),
      'the u33 place label is ~Berlin');

    const parisOnly: GlobeCity[] = [cities[1]];
    t.equalString('', GeohashPlaceResolver.placeLabel(parisOnly, 'ezs42'),
      'a cell with no city inside its radius has no place label');
  }

  // Event classification: kind 20000 chat vs kind 20001 presence, g
  // tag normalization, n nickname and t/teleport accessors.
  {
    const chat: NostrEvent = new NostrEvent('chat', CHAT_PUBKEY, 1737000000,
      NostrKind.EPHEMERAL_EVENT,
      [['g', 'ezs42'], ['n', 'nick'], ['t', 'teleport']], 'hello', null);
    t.equalString('ezs42', GeohashEventRouter.chatGeohash(chat) ?? '',
      'a kind 20000 event routes to its g tag channel');
    t.isNull(GeohashEventRouter.presenceGeohash(chat),
      'a chat event is not a presence event');
    t.equalString('nick', GeohashEventRouter.nicknameOf(chat),
      'the nickname accessor reads the n tag');
    t.isTrue(GeohashEventRouter.isTeleported(chat),
      'the t/teleport tag marks a teleported join');

    const presence: NostrEvent = new NostrEvent('pres', CHAT_PUBKEY, 1737000000,
      NostrKind.GEOHASH_PRESENCE, [['g', 'u33']], '', null);
    t.equalString('u33', GeohashEventRouter.presenceGeohash(presence) ?? '',
      'a kind 20001 event routes to its g tag channel');
    t.isNull(GeohashEventRouter.chatGeohash(presence),
      'a presence event is not a chat event');

    const plainChat: NostrEvent = new NostrEvent('plain', CHAT_PUBKEY, 1737000000,
      NostrKind.EPHEMERAL_EVENT, [['g', 'ezs42']], 'hi', null);
    t.equalString('', GeohashEventRouter.nicknameOf(plainChat),
      'a chat event without an n tag has an empty nickname');
    t.isFalse(GeohashEventRouter.isTeleported(plainChat),
      'a chat event without a t tag is not teleported');

    const textNote: NostrEvent = new NostrEvent('note', CHAT_PUBKEY, 1737000000,
      NostrKind.TEXT_NOTE, [['g', 'ezs42']], 'hi', null);
    t.isNull(GeohashEventRouter.chatGeohash(textNote),
      'a kind 1 text note never routes into location channels');
    t.isNull(GeohashEventRouter.presenceGeohash(textNote),
      'a kind 1 text note is never a presence event');

    const noTag: NostrEvent = new NostrEvent('notag', CHAT_PUBKEY, 1737000000,
      NostrKind.EPHEMERAL_EVENT, [], 'hi', null);
    t.isNull(GeohashEventRouter.chatGeohash(noTag),
      'a chat event without tags routes to no channel');

    const messy: NostrEvent = new NostrEvent('messy', CHAT_PUBKEY, 1737000000,
      NostrKind.EPHEMERAL_EVENT, [['g', '  #EZS42! '], ['g', 'u33']], 'x', null);
    t.equalString('ezs42', GeohashEventRouter.chatGeohash(messy) ?? '',
      'the g tag is normalized before routing and the first tag wins');

    const invalid: NostrEvent = new NostrEvent('bad', CHAT_PUBKEY, 1737000000,
      NostrKind.EPHEMERAL_EVENT, [['g', '!?']], 'x', null);
    t.isNull(GeohashEventRouter.chatGeohash(invalid),
      'an unparsable g tag routes to no channel');
  }
}
