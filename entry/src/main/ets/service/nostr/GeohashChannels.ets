/**
 * Geohash location-channel UI plumbing (US13, T068).
 *
 * Pure helpers shared by the location-channel surfaces:
 *  - GeohashChannels: base32 normalization/validation (Android
 *    GeohashBookmarksStore.normalize + LocationChannelsSheet
 *    validateGeohash) and the precision-to-coverage label
 *    (coverageString).
 *  - GeohashBookmarkCodec: the persisted bookmark list — a JSON string
 *    array normalized to lowercase base32, de-duplicated, newest first
 *    (Android GeohashBookmarksStore persistence semantics).
 *  - GeohashPlaceResolver: offline reverse geocoding — the nearest
 *    bundled Natural Earth city labels the channel ("~Berlin"), the
 *    Android Geocoder place-name display without any network or
 *    platform geocoder.
 *  - GeohashEventRouter: classifies inbound Nostr events into the
 *    location-channel timelines (kind 20000 chat with g/n/t tags,
 *    kind 20001 presence with the g tag; GeohashPresenceSpec.md).
 *
 * Deliberately pure ArkTS (no @ohos/@kit imports) so the contract
 * tests run on the host harness; the device wiring lives in
 * ChatViewModel and the views.
 */
import { Geohash, GeohashBounds, GeohashPoint } from './GeohashService';
import { GlobeCity } from '../globe/GlobeWorldData';
import { NostrEvent, NostrKind } from './NostrEvent';

/** Base32 geohash alphabet (Android Geohash.BASE32). */
const GEOHASH_BASE32 = '0123456789bcdefghjkmnpqrstuvwxyz';

/** Longest accepted geohash (Android validateGeohash cap). */
const MAX_GEOHASH_LENGTH = 12;

/** Fallback place-name search radius when the cell is tiny (km). */
const MIN_PLACE_SEARCH_KM = 50;

/** Mean Earth radius for the haversine distance (km). */
const EARTH_RADIUS_KM = 6371.0;

export class GeohashChannels {
  /**
   * Normalize raw user input to a lowercase base32 geohash: trim,
   * lowercase, strip '#' and drop every non-alphabet character
   * (Android GeohashBookmarksStore.normalize).
   */
  static normalize(raw: string): string {
    const lowered: string = raw.trim().toLowerCase();
    let out: string = '';
    for (let i: number = 0; i < lowered.length; i++) {
      const ch: string = lowered.charAt(i);
      if (ch !== '#' && GEOHASH_BASE32.indexOf(ch) >= 0) {
        out += ch;
      }
    }
    return out;
  }

  /** True for a 1..12 character base32 geohash (Android validateGeohash). */
  static isValid(geohash: string): boolean {
    if (geohash.length === 0 || geohash.length > MAX_GEOHASH_LENGTH) {
      return false;
    }
    for (let i: number = 0; i < geohash.length; i++) {
      if (GEOHASH_BASE32.indexOf(geohash.charAt(i)) < 0) {
        return false;
      }
    }
    return true;
  }

  /** Coverage label of one precision ("~38.2 m" … "~1250 km"). */
  static coverageString(precision: number): string {
    let maxMeters: number;
    if (precision <= 1) {
      maxMeters = 5000000;
    } else if (precision === 2) {
      maxMeters = 1250000;
    } else if (precision === 3) {
      maxMeters = 156000;
    } else if (precision === 4) {
      maxMeters = 39100;
    } else if (precision === 5) {
      maxMeters = 4890;
    } else if (precision === 6) {
      maxMeters = 1220;
    } else if (precision === 7) {
      maxMeters = 153;
    } else if (precision === 8) {
      maxMeters = 38.2;
    } else if (precision === 9) {
      maxMeters = 4.77;
    } else if (precision === 10) {
      maxMeters = 1.19;
    } else {
      maxMeters = 1.19 * Math.pow(0.25, precision - 10);
    }
    const km: number = maxMeters / 1000;
    if (km >= 100) {
      return `~${Math.round(km)} km`;
    }
    if (km >= 1) {
      return `~${km.toFixed(1)} km`;
    }
    return `~${Math.round(maxMeters)} m`;
  }
}

/** Outcome of one bookmark toggle (added vs removed + next list). */
export class GeohashBookmarkToggle {
  readonly added: boolean;
  readonly list: string[];

  constructor(added: boolean, list: string[]) {
    this.added = added;
    this.list = list;
  }
}

/** Persisted bookmark list codec (Android GeohashBookmarksStore). */
export class GeohashBookmarkCodec {
  /** Serialize the bookmark list (already-normalized entries pass through). */
  static toJson(bookmarks: string[]): string {
    let out: string = '[';
    for (let i: number = 0; i < bookmarks.length; i++) {
      if (i > 0) {
        out += ',';
      }
      out += '"' + NostrEvent.jsonString(bookmarks[i], false) + '"';
    }
    return out + ']';
  }

  /**
   * Parse a persisted bookmark list: every entry is normalized,
   * empties and duplicates are dropped and the stored order is kept
   * (a corrupt document yields the empty list, never a throw).
   */
  static fromJson(text: string): string[] {
    let parsed: Object | null = null;
    try {
      parsed = JSON.parse(text);
    } catch (e) {
      return [];
    }
    if (parsed === null || typeof parsed !== 'object' || !Array.isArray(parsed)) {
      return [];
    }
    const rawEntries: Object[] = parsed as Object[];
    const seen: Set<string> = new Set<string>();
    const out: string[] = [];
    for (let i: number = 0; i < rawEntries.length; i++) {
      const raw: Object = rawEntries[i];
      if (typeof raw !== 'string') {
        continue;
      }
      const gh: string = GeohashChannels.normalize(raw);
      if (gh.length > 0 && !seen.has(gh)) {
        seen.add(gh);
        out.push(gh);
      }
    }
    return out;
  }

  /**
   * Toggle one geohash: a new entry lands at the front (newest first),
   * an existing entry is removed (Android GeohashBookmarksStore.toggle).
   */
  static toggle(bookmarks: string[], geohash: string): GeohashBookmarkToggle {
    const gh: string = GeohashChannels.normalize(geohash);
    if (gh.length === 0) {
      return new GeohashBookmarkToggle(false, bookmarks.slice(0));
    }
    const next: string[] = [];
    let removed: boolean = false;
    for (let i: number = 0; i < bookmarks.length; i++) {
      if (bookmarks[i] === gh) {
        removed = true;
        continue;
      }
      next.push(bookmarks[i]);
    }
    if (removed) {
      return new GeohashBookmarkToggle(false, next);
    }
    next.unshift(gh);
    return new GeohashBookmarkToggle(true, next);
  }
}

/** One resolved place label with its distance from the channel center. */
export class GeohashPlace {
  readonly name: string;
  readonly distanceKm: number;

  constructor(name: string, distanceKm: number) {
    this.name = name;
    this.distanceKm = distanceKm;
  }
}

/** Offline place-name resolution over the bundled city gazetteer. */
export class GeohashPlaceResolver {
  /** Great-circle distance between two coordinates (km, haversine). */
  static haversineKm(lat1: number, lon1: number, lat2: number, lon2: number): number {
    const toRad: number = Math.PI / 180.0;
    const dLat: number = (lat2 - lat1) * toRad;
    const dLon: number = (lon2 - lon1) * toRad;
    const sinLat: number = Math.sin(dLat / 2);
    const sinLon: number = Math.sin(dLon / 2);
    const a: number = sinLat * sinLat +
      Math.cos(lat1 * toRad) * Math.cos(lat2 * toRad) * sinLon * sinLon;
    return 2 * EARTH_RADIUS_KM * Math.asin(Math.min(1.0, Math.sqrt(a)));
  }

  /** The diagonal of one geohash cell (km). */
  static cellDiagonalKm(geohash: string): number {
    if (!GeohashChannels.isValid(geohash)) {
      return 0;
    }
    const b: GeohashBounds = Geohash.decodeToBounds(geohash);
    return GeohashPlaceResolver.haversineKm(b.latMin, b.lonMin, b.latMax, b.lonMax);
  }

  /**
   * The nearest city within maxDistanceKm of the geohash center, or
   * null when the gazetteer has nothing that close.
   */
  static nearestCity(cities: GlobeCity[], geohash: string,
    maxDistanceKm: number): GeohashPlace | null {
    if (!GeohashChannels.isValid(geohash)) {
      return null;
    }
    const center: GeohashPoint = Geohash.decodeToCenter(geohash);
    const lat: number = center.lat;
    const lon: number = center.lon;
    let best: GeohashPlace | null = null;
    for (let i: number = 0; i < cities.length; i++) {
      const distance: number = GeohashPlaceResolver.haversineKm(
        lat, lon, cities[i].lat, cities[i].lon);
      if (distance <= maxDistanceKm && (best === null || distance < best.distanceKm)) {
        best = new GeohashPlace(cities[i].name, distance);
      }
    }
    return best;
  }

  /**
   * The channel's place label ("~Berlin"): the nearest gazetteer city
   * within the cell's own diagonal (at least the fallback radius);
   * '' when nothing qualifies (the level name covers the display).
   */
  static placeLabel(cities: GlobeCity[], geohash: string): string {
    const radius: number = Math.max(GeohashPlaceResolver.cellDiagonalKm(geohash),
      MIN_PLACE_SEARCH_KM);
    const place: GeohashPlace | null =
      GeohashPlaceResolver.nearestCity(cities, geohash, radius);
    return place !== null ? '~' + place.name : '';
  }
}

/** Classification of inbound Nostr events into the location channels. */
export class GeohashEventRouter {
  /**
   * The g-tag geohash of a kind 20000 chat event, normalized; null for
   * any other kind or an event without a usable g tag.
   */
  static chatGeohash(event: NostrEvent): string | null {
    if (event.kind !== NostrKind.EPHEMERAL_EVENT) {
      return null;
    }
    return GeohashEventRouter.geohashTagOf(event);
  }

  /** The g-tag geohash of a kind 20001 presence event, or null. */
  static presenceGeohash(event: NostrEvent): string | null {
    if (event.kind !== NostrKind.GEOHASH_PRESENCE) {
      return null;
    }
    return GeohashEventRouter.geohashTagOf(event);
  }

  /** The n-tag nickname of a chat event ('' when absent). */
  static nicknameOf(event: NostrEvent): string {
    const tag: string | null = GeohashEventRouter.tagValue(event, 'n');
    return tag !== null ? tag : '';
  }

  /** Whether the event carries the t/teleport tag. */
  static isTeleported(event: NostrEvent): boolean {
    return GeohashEventRouter.tagValue(event, 't') === 'teleport';
  }

  private static geohashTagOf(event: NostrEvent): string | null {
    const raw: string | null = GeohashEventRouter.tagValue(event, 'g');
    if (raw === null) {
      return null;
    }
    const gh: string = GeohashChannels.normalize(raw);
    return GeohashChannels.isValid(gh) ? gh : null;
  }

  private static tagValue(event: NostrEvent, name: string): string | null {
    for (let i: number = 0; i < event.tags.length; i++) {
      const tag: string[] = event.tags[i];
      if (tag.length >= 2 && tag[0] === name) {
        return tag[1];
      }
    }
    return null;
  }
}
