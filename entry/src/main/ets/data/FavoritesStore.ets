/**
 * Durable favorites store (US11, T055; Android
 * FavoritesPersistenceService parity).
 *
 * Bridges Noise and Nostr favorites: one FavoriteRelationship per peer
 * keyed by the Noise static public key hex, plus a 16-hex mesh peer ID ->
 * npub index for peers whose Noise key has not been seen yet.
 *
 * plan.md D5 storage decision: favorites/mappings persist as encrypted
 * JSON files. Each document is sealed with the SecureKeyStore HUKS
 * AES-256-GCM envelope (version | nonce | ciphertext | tag), so the
 * content is unreadable without the non-exportable device key and is
 * destroyed by the panic "clear cryptographic data" stage; the explicit
 * panic stage additionally deletes both files outright.
 *
 * The relationship semantics, control-message format and JSON codec live
 * in pure ArkTS (model/FavoriteModels.ets) for host testing.
 */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { FavoriteRelationship, FavoriteRelationshipCodec } from '../model/FavoriteModels';
import { ContactIdentityResolver } from '../service/identity/ContactIdentityResolver';
import { ByteUtils } from '../common/ByteUtils';
import { SecureKeyStore } from './SecureKeyStore';

const DOMAIN = 0x0000;
const TAG = 'FavoritesStore';

/** filesDir subdirectory holding the two encrypted JSON documents. */
const FAVORITES_DIR = 'favorites';
const RELATIONSHIPS_FILE = 'relationships.aead';
const PEERID_INDEX_FILE = 'peerid_index.aead';

/** Listener over favorite changes (Android FavoritesChangeListener parity). */
export interface FavoritesChangeListener {
  onFavoriteChanged(noiseKeyHex: string): void;
  onAllCleared(): void;
}

export class FavoritesStore {
  private static instance: FavoritesStore | null = null;

  private filesRoot: string = '';
  private favorites: Map<string, FavoriteRelationship> =
    new Map<string, FavoriteRelationship>();
  private peerIdIndex: Map<string, string> = new Map<string, string>();
  private listeners: FavoritesChangeListener[] = [];
  private loadPromise: Promise<void> | null = null;

  static getInstance(): FavoritesStore {
    if (FavoritesStore.instance === null) {
      FavoritesStore.instance = new FavoritesStore();
    }
    return FavoritesStore.instance;
  }

  private constructor() {
  }

  /** Capture the sandbox root and load both documents; idempotent. */
  init(context: common.Context): Promise<void> {
    this.filesRoot = context.filesDir;
    if (this.loadPromise === null) {
      this.loadPromise = this.loadAll();
    }
    return this.loadPromise;
  }

  /** Wait until init() finished loading (or failed benignly). */
  ready(): Promise<void> {
    return this.loadPromise !== null ? this.loadPromise : Promise.resolve();
  }

  // ------------------------------------------------------------------
  // Queries
  // ------------------------------------------------------------------

  /** Favorite status for a Noise public key. */
  getFavoriteStatusForNoiseKey(noisePublicKey: Uint8Array): FavoriteRelationship | null {
    return this.favorites.get(ContactIdentityResolver.noiseKeyHex(noisePublicKey)) ?? null;
  }

  /**
   * Favorite status for any alias: Noise key hex, contact conversation ID,
   * or 16-hex mesh peer ID (index lookup first, then linear scan).
   */
  getFavoriteStatus(peerID: string): FavoriteRelationship | null {
    const pid: string = peerID.trim().toLowerCase();
    if (ContactIdentityResolver.isNoiseKeyHex(pid)) {
      return this.favorites.get(pid) ?? null;
    }
    const fingerprint: string | null =
      ContactIdentityResolver.fingerprintFromContactConversationId(pid);
    if (fingerprint !== null) {
      const matches: FavoriteRelationship[] = this.allRelationships();
      for (let i: number = 0; i < matches.length; i++) {
        if (ContactIdentityResolver.fingerprintHex(matches[i].peerNoisePublicKey)
          === fingerprint) {
          return matches[i];
        }
      }
      return null;
    }
    if (ContactIdentityResolver.isMeshPeerId(pid)) {
      const indexedNpub: string | undefined = this.peerIdIndex.get(pid);
      if (indexedNpub !== undefined) {
        const noiseKey: Uint8Array | null = this.findNoiseKey(indexedNpub);
        if (noiseKey !== null) {
          return this.getFavoriteStatusForNoiseKey(noiseKey);
        }
      }
      const matches: FavoriteRelationship[] = this.allRelationships();
      for (let i: number = 0; i < matches.length; i++) {
        if (ContactIdentityResolver.peerIdForNoiseKey(matches[i].peerNoisePublicKey) === pid) {
          return matches[i];
        }
      }
    }
    return null;
  }

  getMutualFavorites(): FavoriteRelationship[] {
    return this.allRelationships().filter(
      (relationship: FavoriteRelationship): boolean => relationship.isMutual());
  }

  getOurFavorites(): FavoriteRelationship[] {
    return this.allRelationships().filter(
      (relationship: FavoriteRelationship): boolean => relationship.isFavorite);
  }

  getAllRelationships(): FavoriteRelationship[] {
    return this.allRelationships();
  }

  /** Resolve the Nostr pubkey (npub) for a peer ID alias. */
  findNostrPubkeyForPeerID(peerID: string): string | null {
    const pid: string = peerID.trim().toLowerCase();
    const indexed: string | undefined = this.peerIdIndex.get(pid);
    if (indexed !== undefined) {
      return indexed;
    }
    const relationship: FavoriteRelationship | null = this.getFavoriteStatus(pid);
    return relationship !== null ? relationship.peerNostrPublicKey : null;
  }

  /** Resolve the mesh peer ID for a Nostr pubkey (npub or hex). */
  findPeerIDForNostrPubkey(nostrPubkey: string): string | null {
    const targetHex: string | null = ContactIdentityResolver.nostrPubkeyHex(nostrPubkey);
    if (targetHex === null) {
      return null;
    }
    const indexEntries: string[] = Array.from(this.peerIdIndex.keys());
    for (let i: number = 0; i < indexEntries.length; i++) {
      const stored: string | undefined = this.peerIdIndex.get(indexEntries[i]);
      if (stored !== undefined &&
        ContactIdentityResolver.nostrPubkeyHex(stored) === targetHex) {
        return indexEntries[i];
      }
    }
    const matches: FavoriteRelationship[] = this.allRelationships();
    for (let i: number = 0; i < matches.length; i++) {
      const npub: string | null = matches[i].peerNostrPublicKey;
      if (npub !== null && ContactIdentityResolver.nostrPubkeyHex(npub) === targetHex) {
        return ContactIdentityResolver.peerIdForNoiseKey(matches[i].peerNoisePublicKey);
      }
    }
    return null;
  }

  /** Find the stored Noise public key for a Nostr pubkey (npub or hex). */
  findNoiseKey(forNostrPubkey: string): Uint8Array | null {
    const targetHex: string | null = ContactIdentityResolver.nostrPubkeyHex(forNostrPubkey);
    if (targetHex === null) {
      return null;
    }
    const matches: FavoriteRelationship[] = this.allRelationships();
    for (let i: number = 0; i < matches.length; i++) {
      const npub: string | null = matches[i].peerNostrPublicKey;
      if (npub !== null && ContactIdentityResolver.nostrPubkeyHex(npub) === targetHex) {
        return matches[i].peerNoisePublicKey;
      }
    }
    return null;
  }

  /** Find the Nostr pubkey associated with a Noise public key. */
  findNostrPubkey(forNoiseKey: Uint8Array): string | null {
    const relationship: FavoriteRelationship | null =
      this.getFavoriteStatusForNoiseKey(forNoiseKey);
    return relationship !== null ? relationship.peerNostrPublicKey : null;
  }

  // ------------------------------------------------------------------
  // Mutations
  // ------------------------------------------------------------------

  /** Associate (or refresh) a Nostr pubkey for a peer indexed by Noise key. */
  updateNostrPublicKey(noisePublicKey: Uint8Array, nostrPubkey: string): void {
    const keyHex: string = ContactIdentityResolver.noiseKeyHex(noisePublicKey);
    const pubkeyHex: string | null = ContactIdentityResolver.nostrPubkeyHex(nostrPubkey);
    const normalizedNpub: string =
      pubkeyHex !== null && ContactIdentityResolver.npubFromHex(pubkeyHex) !== null
        ? ContactIdentityResolver.npubFromHex(pubkeyHex) as string : nostrPubkey;
    const existing: FavoriteRelationship | null = this.favorites.get(keyHex) ?? null;
    const now: number = Date.now();
    let updated: FavoriteRelationship;
    if (existing !== null) {
      updated = new FavoriteRelationship(existing.peerNoisePublicKey, normalizedNpub,
        existing.peerNickname, existing.isFavorite, existing.theyFavoritedUs,
        existing.favoritedAtMs, now);
    } else {
      updated = new FavoriteRelationship(noisePublicKey, normalizedNpub, 'Unknown',
        false, false, now, now);
    }
    this.favorites.set(keyHex, updated);
    void this.saveFavorites();
    this.notifyChanged(keyHex);
  }

  /** Index an npub under a 16-hex mesh peer ID (pre-Noise-key mapping). */
  updateNostrPublicKeyForPeerID(peerID: string, nostrPubkey: string): void {
    const pid: string = peerID.trim().toLowerCase();
    const pubkeyHex: string | null = ContactIdentityResolver.nostrPubkeyHex(nostrPubkey);
    const normalizedNpub: string =
      pubkeyHex !== null && ContactIdentityResolver.npubFromHex(pubkeyHex) !== null
        ? ContactIdentityResolver.npubFromHex(pubkeyHex) as string : nostrPubkey;
    if (!ContactIdentityResolver.isMeshPeerId(pid)) {
      hilog.warn(DOMAIN, TAG, 'ignore npub index for non-16hex peerID');
      return;
    }
    this.peerIdIndex.set(pid, normalizedNpub);
    void this.savePeerIdIndex();
    this.notifyChanged(pid);
  }

  /** Update our-favorite status (Android updateFavoriteStatus parity). */
  updateFavoriteStatus(noisePublicKey: Uint8Array, nickname: string,
    isFavorite: boolean): void {
    const keyHex: string = ContactIdentityResolver.noiseKeyHex(noisePublicKey);
    const existing: FavoriteRelationship | null = this.favorites.get(keyHex) ?? null;
    const now: number = Date.now();
    let updated: FavoriteRelationship;
    if (existing !== null) {
      const favoritedAt: number = isFavorite && !existing.isFavorite
        ? now : existing.favoritedAtMs;
      updated = new FavoriteRelationship(existing.peerNoisePublicKey,
        existing.peerNostrPublicKey, nickname, isFavorite, existing.theyFavoritedUs,
        favoritedAt, now);
    } else {
      updated = new FavoriteRelationship(noisePublicKey, null, nickname,
        isFavorite, false, now, now);
    }
    this.favorites.set(keyHex, updated);
    void this.saveFavorites();
    this.notifyChanged(keyHex);
  }

  /** Update the inbound "they favorited us" flag (Android parity). */
  updatePeerFavoritedUs(noisePublicKey: Uint8Array, theyFavoritedUs: boolean): void {
    const keyHex: string = ContactIdentityResolver.noiseKeyHex(noisePublicKey);
    const existing: FavoriteRelationship | null = this.favorites.get(keyHex) ?? null;
    const updated: FavoriteRelationship = FavoriteRelationship.withPeerFavoritedUs(
      existing, noisePublicKey, theyFavoritedUs, Date.now());
    this.favorites.set(keyHex, updated);
    void this.saveFavorites();
    this.notifyChanged(keyHex);
  }

  /** Drop every relationship and index entry (panic stage CLEAR_FAVORITES). */
  clearAllFavorites(): boolean {
    this.favorites.clear();
    this.peerIdIndex.clear();
    let filesRemoved: boolean = true;
    if (this.filesRoot !== '') {
      const dir: string = FavoritesStore.joinPath(this.filesRoot, FAVORITES_DIR);
      if (fileIo.accessSync(dir)) {
        try {
          fileIo.rmdirSync(dir);
        } catch (e) {
          const err = e as BusinessError;
          hilog.error(DOMAIN, TAG, 'clear favorites dir failed: %{public}s', err.message);
          filesRemoved = false;
        }
      }
    }
    this.notifyAllCleared();
    return filesRemoved;
  }

  // ------------------------------------------------------------------
  // Listeners
  // ------------------------------------------------------------------

  addListener(listener: FavoritesChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  removeListener(listener: FavoritesChangeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  // ------------------------------------------------------------------
  // Persistence (encrypted JSON; HUKS envelope via SecureKeyStore)
  // ------------------------------------------------------------------

  private async loadAll(): Promise<void> {
    await this.loadFavorites();
    await this.loadPeerIdIndex();
  }

  private async loadFavorites(): Promise<void> {
    const path: string = this.relationshipsPath();
    if (this.filesRoot === '' || !fileIo.accessSync(path)) {
      return;
    }
    try {
      const plain: Uint8Array = await SecureKeyStore.getInstance().decryptFile(path);
      const parsed: Map<string, FavoriteRelationship> | null =
        FavoriteRelationshipCodec.fromJson(ByteUtils.utf8Decode(plain));
      if (parsed !== null) {
        this.favorites = parsed;
      }
      hilog.info(DOMAIN, TAG, 'loaded %{public}d favorite relationships', parsed !== null
        ? parsed.size : 0);
    } catch (e) {
      const err = e as BusinessError;
      // Panic wiped the HUKS key: the leftover envelope is unreadable and
      // the store restarts empty, which is the intended post-panic state.
      hilog.warn(DOMAIN, TAG, 'favorites load failed (fresh start?): %{public}s', err.message);
    }
  }

  private async loadPeerIdIndex(): Promise<void> {
    const path: string = this.peerIdIndexPath();
    if (this.filesRoot === '' || !fileIo.accessSync(path)) {
      return;
    }
    try {
      const plain: Uint8Array = await SecureKeyStore.getInstance().decryptFile(path);
      const parsed: Record<string, string> | null = FavoritesStore.parseIndexJson(
        ByteUtils.utf8Decode(plain));
      if (parsed !== null) {
        const keys: string[] = Object.keys(parsed);
        for (let i: number = 0; i < keys.length; i++) {
          const pid: string = keys[i].toLowerCase();
          if (ContactIdentityResolver.isMeshPeerId(pid)) {
            this.peerIdIndex.set(pid, parsed[keys[i]]);
          }
        }
      }
      hilog.info(DOMAIN, TAG, 'loaded %{public}d peerID->npub mappings', this.peerIdIndex.size);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'peerID index load failed: %{public}s', err.message);
    }
  }

  private async saveFavorites(): Promise<void> {
    if (this.filesRoot === '') {
      return;
    }
    try {
      this.ensureDir();
      const json: Uint8Array = ByteUtils.utf8Encode(
        FavoriteRelationshipCodec.toJson(this.favorites));
      await SecureKeyStore.getInstance().encryptFile(json, this.relationshipsPath());
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'save favorites failed: %{public}s', err.message);
    }
  }

  private async savePeerIdIndex(): Promise<void> {
    if (this.filesRoot === '') {
      return;
    }
    try {
      this.ensureDir();
      const raw: Record<string, string> = {};
      this.peerIdIndex.forEach((npub: string, peerID: string): void => {
        raw[peerID] = npub;
      });
      const json: Uint8Array = ByteUtils.utf8Encode(JSON.stringify(raw));
      await SecureKeyStore.getInstance().encryptFile(json, this.peerIdIndexPath());
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'save peerID index failed: %{public}s', err.message);
    }
  }

  private static parseIndexJson(text: string): Record<string, string> | null {
    let parsed: Record<string, string> | null = null;
    try {
      parsed = JSON.parse(text) as Record<string, string>;
    } catch (e) {
      return null;
    }
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return null;
    }
    const out: Record<string, string> = {};
    const keys: string[] = Object.keys(parsed);
    for (let i: number = 0; i < keys.length; i++) {
      const value: string = parsed[keys[i]];
      if (typeof value === 'string') {
        out[keys[i]] = value;
      }
    }
    return out;
  }

  private ensureDir(): void {
    const dir: string = FavoritesStore.joinPath(this.filesRoot, FAVORITES_DIR);
    if (!fileIo.accessSync(dir)) {
      fileIo.mkdirSync(dir, true);
    }
  }

  private relationshipsPath(): string {
    return FavoritesStore.joinPath(
      FavoritesStore.joinPath(this.filesRoot, FAVORITES_DIR), RELATIONSHIPS_FILE);
  }

  private peerIdIndexPath(): string {
    return FavoritesStore.joinPath(
      FavoritesStore.joinPath(this.filesRoot, FAVORITES_DIR), PEERID_INDEX_FILE);
  }

  private allRelationships(): FavoriteRelationship[] {
    const out: FavoriteRelationship[] = [];
    this.favorites.forEach((relationship: FavoriteRelationship): void => {
      out.push(relationship);
    });
    return out;
  }

  private notifyChanged(noiseKeyHex: string): void {
    for (let i: number = 0; i < this.listeners.length; i++) {
      try {
        this.listeners[i].onFavoriteChanged(noiseKeyHex);
      } catch (e) {
        // A broken listener never blocks the others (Android runCatching parity).
      }
    }
  }

  private notifyAllCleared(): void {
    for (let i: number = 0; i < this.listeners.length; i++) {
      try {
        this.listeners[i].onAllCleared();
      } catch (e) {
        // Ignore.
      }
    }
  }

  private static joinPath(base: string, child: string): string {
    return base.endsWith('/') ? base + child : base + '/' + child;
  }
}
