/**
 * Geohash location-channel service (spec US13, T066).
 *
 * Mirrors bitchat-android:
 * - Geohash.kt: the base32 codec (encode/decodeToBounds/decodeToCenter/
 *   neighborsSamePrecision with longitude wrap and latitude clamp).
 * - LocationChannel.kt + LocationChannelsSheet.kt levelForLength: the six
 *   location-channel levels (BUILDING 8 / BLOCK 7 / NEIGHBORHOOD 6 /
 *   CITY 5 / PROVINCE 4 / REGION 2) and the length-to-level mapping.
 * - NostrIdentityBridge.deriveIdentity: per-geohash unlinkable Nostr
 *   identities, HMAC-SHA256(deviceSeed, geohash || u32le(i)) for i in
 *   0..9 taking the first valid secp256k1 private key, with a
 *   SHA-256(seed || geohash) fallback, cached per geohash.
 * - NostrProofOfWork.kt: NIP-13 difficulty (leading zero bits of the
 *   event id), nonce-tag validation, and deterministic mining; geohash
 *   mining allows 2M iterations and difficulty 12 is OFF by default.
 * - NostrProtocol.createEphemeralGeohashEvent: kind 20000 chat events
 *   with g/n/t(teleport) tags, PoW mined before signing, and
 *   createGeohashPresenceEvent: kind 20001 presence with an empty
 *   content and only the g tag (GeohashPresenceSpec.md).
 * - Presence policy: broadcast only at REGION/PROVINCE/CITY levels, the
 *   40-80s randomized heartbeat band and the 1h presence lookback.
 *
 * Deliberately pure ArkTS (no @ohos/@kit imports): the clock, randomness
 * and device seed are injected so the contract tests run on the host
 * harness; the device wiring passes the live clock, the crypto-secure
 * random source and the persisted device seed.
 */
import { ByteUtils, HmacSha256, Sha256 } from '../../common/ByteUtils';
import { NostrEvent, NostrKind } from './NostrEvent';
import { NostrIdentity } from './NostrIdentity';
import { NostrRandomSource } from './NostrRandomSource';
import { Secp256k1 } from './Secp256k1';

/** Bounding box of one geohash cell (Android Geohash.Bounds). */
export class GeohashBounds {
  readonly latMin: number;
  readonly latMax: number;
  readonly lonMin: number;
  readonly lonMax: number;

  constructor(latMin: number, latMax: number, lonMin: number, lonMax: number) {
    this.latMin = latMin;
    this.latMax = latMax;
    this.lonMin = lonMin;
    this.lonMax = lonMax;
  }
}

/** Latitude/longitude pair (Android Pair<Double, Double>). */
export class GeohashPoint {
  readonly lat: number;
  readonly lon: number;

  constructor(lat: number, lon: number) {
    this.lat = lat;
    this.lon = lon;
  }
}

/** Base32 geohash codec (Android Geohash.kt, port of the iOS original). */
export class Geohash {
  private static readonly BASE32: string = '0123456789bcdefghjkmnpqrstuvwxyz';

  /** Encode coordinates to a `precision`-character base32 geohash. */
  static encode(latitude: number, longitude: number, precision: number): string {
    if (precision <= 0) {
      return '';
    }
    let latMin: number = -90.0;
    let latMax: number = 90.0;
    let lonMin: number = -180.0;
    let lonMax: number = 180.0;
    let isEven: boolean = true;
    let bit: number = 0;
    let ch: number = 0;
    let out: string = '';
    const lat: number = Math.max(-90.0, Math.min(90.0, latitude));
    const lon: number = Math.max(-180.0, Math.min(180.0, longitude));
    while (out.length < precision) {
      if (isEven) {
        const mid: number = (lonMin + lonMax) / 2;
        if (lon >= mid) {
          ch |= (1 << (4 - bit));
          lonMin = mid;
        } else {
          lonMax = mid;
        }
      } else {
        const mid: number = (latMin + latMax) / 2;
        if (lat >= mid) {
          ch |= (1 << (4 - bit));
          latMin = mid;
        } else {
          latMax = mid;
        }
      }
      isEven = !isEven;
      if (bit < 4) {
        bit += 1;
      } else {
        out += Geohash.BASE32.charAt(ch);
        bit = 0;
        ch = 0;
      }
    }
    return out;
  }

  /** Decode a geohash to its bounding box; empty or invalid input is the zero box. */
  static decodeToBounds(geohash: string): GeohashBounds {
    if (geohash.length === 0) {
      return new GeohashBounds(0.0, 0.0, 0.0, 0.0);
    }
    let latMin: number = -90.0;
    let latMax: number = 90.0;
    let lonMin: number = -180.0;
    let lonMax: number = 180.0;
    let isEven: boolean = true;
    const lowered: string = geohash.toLowerCase();
    for (let i: number = 0; i < lowered.length; i++) {
      const cd: number = Geohash.BASE32.indexOf(lowered.charAt(i));
      if (cd < 0) {
        return new GeohashBounds(0.0, 0.0, 0.0, 0.0);
      }
      for (let mask: number = 16; mask >= 1; mask = mask >> 1) {
        if (isEven) {
          const mid: number = (lonMin + lonMax) / 2;
          if ((cd & mask) !== 0) {
            lonMin = mid;
          } else {
            lonMax = mid;
          }
        } else {
          const mid: number = (latMin + latMax) / 2;
          if ((cd & mask) !== 0) {
            latMin = mid;
          } else {
            latMax = mid;
          }
        }
        isEven = !isEven;
      }
    }
    return new GeohashBounds(Math.min(latMin, latMax), Math.max(latMin, latMax),
      Math.min(lonMin, lonMax), Math.max(lonMin, lonMax));
  }

  /** Decode a geohash to the center of its cell. */
  static decodeToCenter(geohash: string): GeohashPoint {
    const b: GeohashBounds = Geohash.decodeToBounds(geohash);
    return new GeohashPoint((b.latMin + b.latMax) / 2, (b.lonMin + b.lonMax) / 2);
  }

  /**
   * The distinct neighboring cells at the same precision (Android
   * neighborsSamePrecision): centers offset by one cell in dx/dy with
   * longitude wrap and latitude clamp, center excluded, duplicates
   * collapsed.
   */
  static neighborsSamePrecision(geohash: string): string[] {
    if (geohash.length === 0) {
      return [];
    }
    const precision: number = geohash.length;
    const b: GeohashBounds = Geohash.decodeToBounds(geohash);
    const dLat: number = b.latMax - b.latMin;
    const dLon: number = b.lonMax - b.lonMin;
    const seen: Set<string> = new Set();
    const out: string[] = [];
    for (let dy: number = -1; dy <= 1; dy++) {
      for (let dx: number = -1; dx <= 1; dx++) {
        if (dx === 0 && dy === 0) {
          continue;
        }
        const centerLat: number = (b.latMin + b.latMax) / 2 + dy * dLat;
        const rawLon: number = (b.lonMin + b.lonMax) / 2 + dx * dLon;
        const centerLon: number = Geohash.wrapLon(rawLon);
        const enc: string = Geohash.encode(
          Math.max(-90.0, Math.min(90.0, centerLat)), centerLon, precision);
        if (enc.length > 0 && enc !== geohash && !seen.has(enc)) {
          seen.add(enc);
          out.push(enc);
        }
      }
    }
    return out;
  }

  private static wrapLon(lon: number): number {
    let x: number = lon;
    while (x > 180.0) {
      x -= 360.0;
    }
    while (x < -180.0) {
      x += 360.0;
    }
    return x;
  }
}

/** Location-channel levels mapped to geohash precisions (Android GeohashChannelLevel). */
export enum GeohashChannelLevel {
  BUILDING = 8,
  BLOCK = 7,
  NEIGHBORHOOD = 6,
  CITY = 5,
  PROVINCE = 4,
  REGION = 2
}

/** Level helpers (Android GeohashChannelLevel companion + levelForLength). */
export class GeohashLevels {
  /** Length-to-level mapping (Android LocationChannelsSheet.levelForLength). */
  static levelForLength(length: number): GeohashChannelLevel {
    if (length <= 2) {
      return GeohashChannelLevel.REGION;
    }
    if (length <= 4) {
      return GeohashChannelLevel.PROVINCE;
    }
    if (length === 5) {
      return GeohashChannelLevel.CITY;
    }
    if (length === 6) {
      return GeohashChannelLevel.NEIGHBORHOOD;
    }
    if (length === 7) {
      return GeohashChannelLevel.BLOCK;
    }
    return GeohashChannelLevel.BUILDING;
  }

  /** The geohash precision (character count) of one level. */
  static precision(level: GeohashChannelLevel): number {
    if (level === GeohashChannelLevel.BUILDING) {
      return 8;
    }
    if (level === GeohashChannelLevel.BLOCK) {
      return 7;
    }
    if (level === GeohashChannelLevel.NEIGHBORHOOD) {
      return 6;
    }
    if (level === GeohashChannelLevel.CITY) {
      return 5;
    }
    if (level === GeohashChannelLevel.PROVINCE) {
      return 4;
    }
    return 2;
  }

  /** Human-readable level name (Android displayName; REGION keeps the raw enum name). */
  static displayName(level: GeohashChannelLevel): string {
    if (level === GeohashChannelLevel.BLOCK) {
      return 'Block';
    }
    if (level === GeohashChannelLevel.NEIGHBORHOOD) {
      return 'Neighborhood';
    }
    if (level === GeohashChannelLevel.CITY) {
      return 'City';
    }
    if (level === GeohashChannelLevel.PROVINCE) {
      return 'Province';
    }
    if (level === GeohashChannelLevel.REGION) {
      return 'REGION';
    }
    return 'Building';
  }

  /** The enum name used in channel ids and persistence (Android level.name). */
  static levelName(level: GeohashChannelLevel): string {
    if (level === GeohashChannelLevel.BLOCK) {
      return 'BLOCK';
    }
    if (level === GeohashChannelLevel.NEIGHBORHOOD) {
      return 'NEIGHBORHOOD';
    }
    if (level === GeohashChannelLevel.CITY) {
      return 'CITY';
    }
    if (level === GeohashChannelLevel.PROVINCE) {
      return 'PROVINCE';
    }
    if (level === GeohashChannelLevel.REGION) {
      return 'REGION';
    }
    return 'BUILDING';
  }

  /** All six levels, coarsest last (Android allCases ordering). */
  static allCases(): GeohashChannelLevel[] {
    return [GeohashChannelLevel.BUILDING, GeohashChannelLevel.BLOCK,
      GeohashChannelLevel.NEIGHBORHOOD, GeohashChannelLevel.CITY,
      GeohashChannelLevel.PROVINCE, GeohashChannelLevel.REGION];
  }
}

/** A computed geohash channel option (Android GeohashChannel). */
export class GeohashChannel {
  readonly level: GeohashChannelLevel;
  readonly geohash: string;

  constructor(level: GeohashChannelLevel, geohash: string) {
    this.level = level;
    this.geohash = geohash;
  }

  /** Stable channel identifier: "<LEVEL>-<geohash>" (Android id). */
  channelId(): string {
    return GeohashLevels.levelName(this.level) + '-' + this.geohash;
  }

  /** UI label: "<displayName> • <geohash>" (Android displayName). */
  channelDisplayName(): string {
    return GeohashLevels.displayName(this.level) + ' • ' + this.geohash;
  }
}

/** NIP-13 Proof of Work over Nostr event ids (Android NostrProofOfWork.kt). */
export class NostrProofOfWork {
  /** Leading zero bits of a hex event id. */
  static calculateDifficulty(eventIdHex: string): number {
    let count: number = 0;
    for (let i: number = 0; i < eventIdHex.length; i++) {
      const nibble: number = NostrProofOfWork.hexNibble(eventIdHex.charAt(i));
      if (nibble < 0) {
        break;
      }
      if (nibble === 0) {
        count += 4;
        continue;
      }
      if (nibble === 1) {
        count += 3;
      } else if (nibble <= 3) {
        count += 2;
      } else if (nibble <= 7) {
        count += 1;
      }
      break;
    }
    return count;
  }

  /** Whether the event carries a nonce tag (mined per NIP-13). */
  static hasNonce(event: NostrEvent): boolean {
    for (let i: number = 0; i < event.tags.length; i++) {
      const tag: string[] = event.tags[i];
      if (tag.length > 0 && tag[0] === 'nonce') {
        return true;
      }
    }
    return false;
  }

  /** The nonce value of the first nonce tag, or null. */
  static getNonce(event: NostrEvent): string | null {
    for (let i: number = 0; i < event.tags.length; i++) {
      const tag: string[] = event.tags[i];
      if (tag.length >= 2 && tag[0] === 'nonce') {
        return tag[1];
      }
    }
    return null;
  }

  /** The committed difficulty of the first nonce tag, or null. */
  static getCommittedDifficulty(event: NostrEvent): number | null {
    for (let i: number = 0; i < event.tags.length; i++) {
      const tag: string[] = event.tags[i];
      if (tag.length >= 3 && tag[0] === 'nonce') {
        const parsed: number = Number.parseInt(tag[2]);
        if (Number.isNaN(parsed)) {
          return null;
        }
        return parsed;
      }
    }
    return null;
  }

  /** Validate an event against a minimum difficulty (Android validateDifficulty). */
  static validateDifficulty(event: NostrEvent, minimumDifficulty: number): boolean {
    if (minimumDifficulty <= 0) {
      return true;
    }
    if (!NostrProofOfWork.hasNonce(event)) {
      return false;
    }
    const actual: number = NostrProofOfWork.calculateDifficulty(event.id);
    if (actual < minimumDifficulty) {
      return false;
    }
    const committed: number | null = NostrProofOfWork.getCommittedDifficulty(event);
    if (committed !== null && committed < minimumDifficulty) {
      return false;
    }
    return true;
  }

  /**
   * Return a copy of the event with the nonce tag replaced by
   * ["nonce", nonce, targetDifficulty] and created_at refreshed to
   * nowMs/1000 (Android addNonceTag).
   */
  static withNonceTag(event: NostrEvent, nonce: string, targetDifficulty: number,
    nowMs: number): NostrEvent {
    const tags: string[][] = [];
    for (let i: number = 0; i < event.tags.length; i++) {
      const tag: string[] = event.tags[i];
      if (tag.length > 0 && tag[0] === 'nonce') {
        continue;
      }
      tags.push(tag);
    }
    const nonceTag: string[] = ['nonce', nonce, targetDifficulty.toString()];
    tags.push(nonceTag);
    return new NostrEvent(event.id, event.pubkey, Math.floor(nowMs / 1000),
      event.kind, tags, event.content, event.sig);
  }

  /**
   * Mine the event to the target difficulty by iterating nonces from
   * `startNonce` (deterministic; Android draws the start randomly).
   * Returns the event with the nonce tag and the computed id set, or
   * null after maxIterations failed attempts.
   */
  static mineEvent(event: NostrEvent, targetDifficulty: number, maxIterations: number,
    startNonce: number, nowMs: number): NostrEvent | null {
    if (targetDifficulty <= 0) {
      return event;
    }
    let nonce: number = startNonce;
    let iterations: number = 0;
    while (iterations < maxIterations) {
      const candidate: NostrEvent = NostrProofOfWork.withNonceTag(
        event, nonce.toString(), targetDifficulty, nowMs);
      const eventId: string = candidate.computeEventIdHex();
      if (NostrProofOfWork.calculateDifficulty(eventId) >= targetDifficulty) {
        return new NostrEvent(eventId, candidate.pubkey, candidate.createdAt,
          candidate.kind, candidate.tags, candidate.content, candidate.sig);
      }
      nonce += 1;
      iterations += 1;
    }
    return null;
  }

  private static hexNibble(ch: string): number {
    const code: number = ch.charCodeAt(0);
    if (code >= 48 && code <= 57) {
      return code - 48;
    }
    if (code >= 97 && code <= 102) {
      return code - 87;
    }
    if (code >= 65 && code <= 70) {
      return code - 55;
    }
    return -1;
  }
}

/** NIP-13 spam-deterrence settings; difficulty 12 is OFF by default. */
export class GeohashPowSettings {
  readonly enabled: boolean;
  readonly difficulty: number;

  constructor(enabled: boolean, difficulty: number) {
    this.enabled = enabled;
    this.difficulty = difficulty;
  }

  /** The default settings: disabled, difficulty 12. */
  static defaults(): GeohashPowSettings {
    return new GeohashPowSettings(false, 12);
  }
}

/**
 * The geohash location-channel service: per-geohash identity
 * derivation and kind 20000 chat / kind 20001 presence event creation.
 */
export class GeohashService {
  /** Presence and chat history look back one hour (spec US13). */
  static readonly PRESENCE_LOOKBACK_MS: number = 3600000;
  /** Heartbeat band floor: 40 seconds (GeohashPresenceSpec.md). */
  static readonly HEARTBEAT_MIN_INTERVAL_MS: number = 40000;
  /** Heartbeat band ceiling: 80 seconds (GeohashPresenceSpec.md). */
  static readonly HEARTBEAT_MAX_INTERVAL_MS: number = 80000;
  /** The default NIP-13 difficulty; PoW ships disabled. */
  static readonly DEFAULT_POW_DIFFICULTY: number = 12;
  /** Geohash mining iteration cap (Android createEphemeralGeohashEvent). */
  static readonly MAX_MINING_ITERATIONS: number = 2000000;

  private readonly nowMs: () => number;
  private readonly random: NostrRandomSource;
  private readonly deviceSeed: Uint8Array;
  private readonly identityCache: Map<string, NostrIdentity> = new Map();

  constructor(nowMs: () => number, random: NostrRandomSource, deviceSeed: Uint8Array) {
    this.nowMs = nowMs;
    this.random = random;
    this.deviceSeed = deviceSeed;
  }

  /**
   * Derive the deterministic, unlinkable Nostr identity for one geohash
   * (Android NostrIdentityBridge.deriveIdentity): up to ten
   * HMAC-SHA256(deviceSeed, geohash || u32le(i)) candidates, the first
   * valid secp256k1 private key wins, with a SHA-256(seed || geohash)
   * fallback; results are cached per geohash.
   */
  deriveIdentity(forGeohash: string): NostrIdentity {
    const cached: NostrIdentity | undefined = this.identityCache.get(forGeohash);
    if (cached !== undefined) {
      return cached;
    }
    const geohashBytes: Uint8Array = ByteUtils.utf8Encode(forGeohash);
    for (let i: number = 0; i < 10; i++) {
      const candidate: Uint8Array = HmacSha256.compute(this.deviceSeed,
        ByteUtils.concat(geohashBytes, GeohashService.u32le(i)));
      const candidateHex: string = ByteUtils.bytesToHex(candidate);
      if (Secp256k1.isValidPrivateKey(candidateHex)) {
        const identity: NostrIdentity =
          NostrIdentity.fromPrivateKey(candidateHex, this.nowMs());
        this.identityCache.set(forGeohash, identity);
        return identity;
      }
    }
    const fallback: Uint8Array =
      Sha256.digest(ByteUtils.concat(this.deviceSeed, geohashBytes));
    const fallbackIdentity: NostrIdentity =
      NostrIdentity.fromPrivateKey(ByteUtils.bytesToHex(fallback), this.nowMs());
    this.identityCache.set(forGeohash, fallbackIdentity);
    return fallbackIdentity;
  }

  /**
   * Create a geohash-scoped ephemeral public chat event (kind 20000,
   * Android createEphemeralGeohashEvent): g tag always, n tag when a
   * non-empty nickname is given, t/teleport tag when teleported, PoW
   * mined before signing when enabled (mining failure proceeds without
   * PoW), signed with the geohash-derived identity.
   */
  createChatEvent(content: string, geohash: string, nickname: string | null,
    teleported: boolean, pow: GeohashPowSettings): NostrEvent {
    const identity: NostrIdentity = this.deriveIdentity(geohash);
    const tags: string[][] = [];
    const gTag: string[] = ['g', geohash];
    tags.push(gTag);
    if (nickname !== null && nickname.length > 0) {
      const nTag: string[] = ['n', nickname];
      tags.push(nTag);
    }
    if (teleported) {
      const tTag: string[] = ['t', 'teleport'];
      tags.push(tTag);
    }
    let event: NostrEvent = new NostrEvent('', identity.publicKeyHex,
      Math.floor(this.nowMs() / 1000), NostrKind.EPHEMERAL_EVENT, tags, content, null);
    if (pow.enabled && pow.difficulty > 0) {
      const mined: NostrEvent | null = NostrProofOfWork.mineEvent(event,
        pow.difficulty, GeohashService.MAX_MINING_ITERATIONS,
        this.random.nextInt(1000000), this.nowMs());
      if (mined !== null) {
        event = mined;
      }
    }
    return identity.signEvent(event, this.random);
  }

  /**
   * Create a geohash presence heartbeat (kind 20001,
   * GeohashPresenceSpec.md): empty content, only the g tag, signed with
   * the same geohash-derived identity as chat messages.
   */
  createPresenceEvent(geohash: string): NostrEvent {
    const identity: NostrIdentity = this.deriveIdentity(geohash);
    const gTag: string[] = ['g', geohash];
    const tags: string[][] = [gTag];
    const event: NostrEvent = new NostrEvent('', identity.publicKeyHex,
      Math.floor(this.nowMs() / 1000), NostrKind.GEOHASH_PRESENCE, tags, '', null);
    return identity.signEvent(event, this.random);
  }

  /**
   * Whether presence may be broadcast at this level: only the
   * low-precision REGION/PROVINCE/CITY levels (GeohashPresenceSpec.md
   * privacy restriction).
   */
  presenceBroadcastAllowed(level: GeohashChannelLevel): boolean {
    return level === GeohashChannelLevel.REGION ||
      level === GeohashChannelLevel.PROVINCE ||
      level === GeohashChannelLevel.CITY;
  }

  /** The next randomized heartbeat interval within the 40-80s band. */
  nextHeartbeatIntervalMs(): number {
    return GeohashService.HEARTBEAT_MIN_INTERVAL_MS +
      this.random.nextInt(
        GeohashService.HEARTBEAT_MAX_INTERVAL_MS - GeohashService.HEARTBEAT_MIN_INTERVAL_MS + 1);
  }

  /** The subscription `since` timestamp for the 1h presence lookback. */
  static presenceFilterSinceMs(nowMs: number): number {
    return nowMs - GeohashService.PRESENCE_LOOKBACK_MS;
  }

  private static u32le(value: number): Uint8Array {
    const out: Uint8Array = new Uint8Array(4);
    out[0] = value & 0xFF;
    out[1] = (value >>> 8) & 0xFF;
    out[2] = (value >>> 16) & 0xFF;
    out[3] = (value >>> 24) & 0xFF;
    return out;
  }
}
