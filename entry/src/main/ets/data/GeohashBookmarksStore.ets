/**
 * Persisted geohash location-channel bookmarks (US13, T068).
 *
 * A JSON string array under one PreferenceStore key, so the panic wipe
 * (T043 clearAll) erases the bookmarks with every other preference and
 * no extra panic wiring is needed. Normalization, de-duplication and
 * the newest-first order live in the pure GeohashBookmarkCodec; this
 * class adds the device persistence and an in-memory mirror.
 */
import { PreferenceStore } from './PreferenceStore';
import { GeohashBookmarkCodec, GeohashBookmarkToggle } from '../service/nostr/GeohashChannels';

const BOOKMARKS_KEY = 'geohash_channel_bookmarks';

export class GeohashBookmarksStore {
  private static instance: GeohashBookmarksStore | null = null;
  private cache: string[] = [];
  private loadPromise: Promise<string[]> | null = null;

  static getInstance(): GeohashBookmarksStore {
    if (GeohashBookmarksStore.instance === null) {
      GeohashBookmarksStore.instance = new GeohashBookmarksStore();
    }
    return GeohashBookmarksStore.instance;
  }

  /** Idempotent; concurrent callers share one load. */
  ensureLoaded(): Promise<string[]> {
    if (this.loadPromise === null) {
      this.loadPromise = PreferenceStore.getInstance()
        .getString(BOOKMARKS_KEY, '[]')
        .then((raw: string) => {
          this.cache = GeohashBookmarkCodec.fromJson(raw);
          return this.cache.slice(0);
        });
    }
    return this.loadPromise;
  }

  /** The loaded bookmark snapshot (empty before the first ensureLoaded). */
  getList(): string[] {
    return this.cache.slice(0);
  }

  /** Panic stage: drop the in-memory mirror so a stale list never leaks. */
  clearCache(): void {
    this.cache = [];
    this.loadPromise = null;
  }

  /** Toggle one bookmark and persist; reports added-vs-removed. */
  async toggle(geohash: string): Promise<GeohashBookmarkToggle> {
    await this.ensureLoaded();
    const result: GeohashBookmarkToggle = GeohashBookmarkCodec.toggle(this.cache, geohash);
    this.cache = result.list;
    await PreferenceStore.getInstance().setString(BOOKMARKS_KEY,
      GeohashBookmarkCodec.toJson(this.cache));
    return result;
  }

  /** Add one bookmark unless already present; reports added-vs-present. */
  async add(geohash: string): Promise<boolean> {
    await this.ensureLoaded();
    if (this.cache.indexOf(geohash) >= 0) {
      return false;
    }
    this.cache = [geohash].concat(this.cache);
    await PreferenceStore.getInstance().setString(BOOKMARKS_KEY,
      GeohashBookmarkCodec.toJson(this.cache));
    return true;
  }

  /** Remove one bookmark if present. */
  async remove(geohash: string): Promise<void> {
    await this.ensureLoaded();
    const next: string[] = [];
    for (let i: number = 0; i < this.cache.length; i++) {
      if (this.cache[i] !== geohash) {
        next.push(this.cache[i]);
      }
    }
    this.cache = next;
    await PreferenceStore.getInstance().setString(BOOKMARKS_KEY,
      GeohashBookmarkCodec.toJson(this.cache));
  }
}
