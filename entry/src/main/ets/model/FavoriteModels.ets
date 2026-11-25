/**
 * Favorite-relationship models (US11, T055;
 * Android FavoriteRelationship.kt / FavoriteControlMessage.kt parity).
 *
 * Pure ArkTS (no @kit) so the contract harness can exercise the
 * relationship semantics, the wire control-message format and the JSON
 * persistence codec on the host. The @kit-backed store lives in
 * data/FavoritesStore.ets.
 */
import { ByteUtils } from '../common/ByteUtils';
import { ContactIdentityResolver } from '../service/identity/ContactIdentityResolver';

/** One Noise<->Nostr favorite relationship, keyed by Noise public key hex. */
export class FavoriteRelationship {
  readonly peerNoisePublicKey: Uint8Array;
  readonly peerNostrPublicKey: string | null;
  readonly peerNickname: string;
  /** We favorited them. */
  readonly isFavorite: boolean;
  /** They favorited us. */
  readonly theyFavoritedUs: boolean;
  readonly favoritedAtMs: number;
  readonly lastUpdatedMs: number;

  constructor(peerNoisePublicKey: Uint8Array, peerNostrPublicKey: string | null,
    peerNickname: string, isFavorite: boolean, theyFavoritedUs: boolean,
    favoritedAtMs: number, lastUpdatedMs: number) {
    this.peerNoisePublicKey = new Uint8Array(peerNoisePublicKey);
    this.peerNostrPublicKey = peerNostrPublicKey;
    this.peerNickname = peerNickname;
    this.isFavorite = isFavorite;
    this.theyFavoritedUs = theyFavoritedUs;
    this.favoritedAtMs = favoritedAtMs;
    this.lastUpdatedMs = lastUpdatedMs;
  }

  isMutual(): boolean {
    return this.isFavorite && this.theyFavoritedUs;
  }

  /**
   * Android withPeerFavoritedUs extension: apply an inbound
   * "they favorited us" transition, creating a bare received-only
   * relationship when none exists yet (Android parity).
   */
  static withPeerFavoritedUs(existing: FavoriteRelationship | null,
    noisePublicKey: Uint8Array, theyFavoritedUs: boolean,
    nowMs: number): FavoriteRelationship {
    if (existing !== null) {
      return new FavoriteRelationship(existing.peerNoisePublicKey,
        existing.peerNostrPublicKey, existing.peerNickname, existing.isFavorite,
        theyFavoritedUs, existing.favoritedAtMs, nowMs);
    }
    return new FavoriteRelationship(noisePublicKey, null, 'Unknown', false,
      theyFavoritedUs, nowMs, nowMs);
  }

  static equals(a: FavoriteRelationship, b: FavoriteRelationship): boolean {
    if (!ByteUtils.equals(a.peerNoisePublicKey, b.peerNoisePublicKey)) {
      return false;
    }
    if (a.peerNostrPublicKey !== b.peerNostrPublicKey) {
      return false;
    }
    if (a.peerNickname !== b.peerNickname) {
      return false;
    }
    if (a.isFavorite !== b.isFavorite) {
      return false;
    }
    if (a.theyFavoritedUs !== b.theyFavoritedUs) {
      return false;
    }
    if (a.favoritedAtMs !== b.favoritedAtMs) {
      return false;
    }
    return a.lastUpdatedMs === b.lastUpdatedMs;
  }
}

/** Raw JSON shape of one persisted relationship (Gson FavoriteRelationshipData parity). */
export class FavoriteRelationshipData {
  peerNoisePublicKeyHex: string = '';
  peerNostrPublicKey: string | null = null;
  peerNickname: string = '';
  isFavorite: boolean = false;
  theyFavoritedUs: boolean = false;
  favoritedAt: number = 0;
  lastUpdated: number = 0;
}

/** JSON codec for the map of relationships keyed by Noise public key hex. */
export class FavoriteRelationshipCodec {
  /** Serialize to a JSON object keyed by noise key hex. */
  static toJson(relationships: Map<string, FavoriteRelationship>): string {
    const raw: Record<string, FavoriteRelationshipData> = {};
    relationships.forEach((relationship: FavoriteRelationship, keyHex: string): void => {
      const data: FavoriteRelationshipData = new FavoriteRelationshipData();
      data.peerNoisePublicKeyHex = ContactIdentityResolver.noiseKeyHex(
        relationship.peerNoisePublicKey);
      data.peerNostrPublicKey = relationship.peerNostrPublicKey;
      data.peerNickname = relationship.peerNickname;
      data.isFavorite = relationship.isFavorite;
      data.theyFavoritedUs = relationship.theyFavoritedUs;
      data.favoritedAt = relationship.favoritedAtMs;
      data.lastUpdated = relationship.lastUpdatedMs;
      raw[keyHex.toLowerCase()] = data;
    });
    return JSON.stringify(raw);
  }

  /**
   * Parse a document produced by toJson. Invalid JSON returns null;
   * structurally invalid entries are skipped (Gson field defaults parity).
   */
  static fromJson(text: string): Map<string, FavoriteRelationship> | null {
    let parsed: Record<string, Object> | null = null;
    try {
      parsed = JSON.parse(text) as Record<string, Object>;
    } catch (e) {
      return null;
    }
    if (parsed === null || typeof parsed !== 'object') {
      return null;
    }
    const out: Map<string, FavoriteRelationship> = new Map<string, FavoriteRelationship>();
    const keys: string[] = Object.keys(parsed);
    for (let i: number = 0; i < keys.length; i++) {
      const keyHex: string = keys[i].toLowerCase();
      const value: Object = parsed[keys[i]];
      if (typeof value !== 'object' || value === null || Array.isArray(value)) {
        continue;
      }
      const entry: Record<string, Object> = value as Record<string, Object>;
      const decoded: FavoriteRelationship | null =
        FavoriteRelationshipCodec.decodeEntry(keyHex, entry);
      if (decoded !== null) {
        out.set(keyHex, decoded);
      }
    }
    return out;
  }

  private static decodeEntry(keyHex: string,
    entry: Record<string, Object>): FavoriteRelationship | null {
    const hexValue: Object | undefined = entry['peerNoisePublicKeyHex'];
    if (typeof hexValue !== 'string' || hexValue === '') {
      return null;
    }
    const noiseKey: Uint8Array | null = ContactIdentityResolver.bytesFromHex(hexValue);
    if (noiseKey === null || noiseKey.length === 0) {
      return null;
    }
    const nicknameValue: Object | undefined = entry['peerNickname'];
    const nickname: string = typeof nicknameValue === 'string' ? nicknameValue : 'Unknown';
    const npubValue: Object | undefined = entry['peerNostrPublicKey'];
    const npub: string | null = typeof npubValue === 'string' ? npubValue : null;
    const isFavorite: boolean = FavoriteRelationshipCodec.booleanField(entry, 'isFavorite');
    const theyFavoritedUs: boolean =
      FavoriteRelationshipCodec.booleanField(entry, 'theyFavoritedUs');
    const favoritedAt: number = FavoriteRelationshipCodec.numberField(entry, 'favoritedAt');
    const lastUpdated: number = FavoriteRelationshipCodec.numberField(entry, 'lastUpdated');
    return new FavoriteRelationship(noiseKey, npub, nickname, isFavorite,
      theyFavoritedUs, favoritedAt, lastUpdated);
  }

  private static booleanField(entry: Record<string, Object>, field: string): boolean {
    const value: Object | undefined = entry[field];
    return typeof value === 'boolean' ? value : false;
  }

  private static numberField(entry: Record<string, Object>, field: string): number {
    const value: Object | undefined = entry[field];
    return typeof value === 'number' ? value : 0;
  }
}

/**
 * Favorite/unfavorite notice carried inside a normal private message
 * (Android FavoriteControlMessage parity).
 * Wire content: "[FAVORITED]:npub..." / "[UNFAVORITED]:npub...".
 */
export class FavoriteControlMessage {
  private static readonly FAVORITED: string = '[FAVORITED]';
  private static readonly UNFAVORITED: string = '[UNFAVORITED]';

  readonly isFavorite: boolean;
  readonly npub: string | null;

  constructor(isFavorite: boolean, npub: string | null) {
    this.isFavorite = isFavorite;
    this.npub = npub;
  }

  /** Parse a private-message content string; null when it is not a control message. */
  static parse(content: string): FavoriteControlMessage | null {
    const trimmed: string = content.trim();
    let isFavorite: boolean;
    if (trimmed.startsWith(FavoriteControlMessage.FAVORITED)) {
      isFavorite = true;
    } else if (trimmed.startsWith(FavoriteControlMessage.UNFAVORITED)) {
      isFavorite = false;
    } else {
      return null;
    }
    // Kotlin substringAfter(":", ""): text after the first ':', '' when absent.
    const separator: number = trimmed.indexOf(':');
    const encodedKey: string = separator < 0 ? '' : trimmed.substring(separator + 1).trim();
    let npub: string | null = null;
    if (encodedKey !== '') {
      const hex: string | null = ContactIdentityResolver.nostrPubkeyHex(encodedKey);
      if (hex !== null) {
        npub = ContactIdentityResolver.npubFromHex(hex);
      }
    }
    return new FavoriteControlMessage(isFavorite, npub);
  }

  static encode(isFavorite: boolean, npub: string | null): string {
    const prefix: string = isFavorite
      ? FavoriteControlMessage.FAVORITED : FavoriteControlMessage.UNFAVORITED;
    return prefix + ':' + (npub !== null ? npub : '');
  }
}
