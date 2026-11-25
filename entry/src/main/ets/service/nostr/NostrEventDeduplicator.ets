/**
 * LRU Nostr event deduplication, mirroring bitchat-android
 * NostrEventDeduplicator.kt: events commonly arrive via multiple
 * relays, so seen event IDs are kept in a most-recently-used-ordered
 * cache of at most 10,000 entries (oldest evicted) and duplicates are
 * reported once per re-arrival. ArkTS is single-threaded per
 * instance, so no locking is needed. Pure ArkTS: no @ohos/@kit
 * imports, host-runnable by the contract-test harness.
 */
import { NostrConstants } from '../../common/ProtocolConstants';

export class DeduplicationStats {
  readonly capacity: number;
  readonly currentSize: number;
  readonly totalChecks: number;
  readonly duplicateCount: number;
  readonly evictionCount: number;
  readonly hitRate: number;

  constructor(capacity: number, currentSize: number, totalChecks: number,
    duplicateCount: number, evictionCount: number, hitRate: number) {
    this.capacity = capacity;
    this.currentSize = currentSize;
    this.totalChecks = totalChecks;
    this.duplicateCount = duplicateCount;
    this.evictionCount = evictionCount;
    this.hitRate = hitRate;
  }
}

export class NostrEventDeduplicator {
  private readonly maxCapacity: number;
  /** Insertion order: index 0 least recent, last index most recent. */
  private readonly order: string[] = [];
  private readonly lookup: Set<string> = new Set<string>();
  private totalChecks: number = 0;
  private duplicateCount: number = 0;
  private evictionCount: number = 0;

  constructor(maxCapacity: number = NostrConstants.DEFAULT_DEDUP_CAPACITY) {
    this.maxCapacity = maxCapacity;
  }

  /** True when the event was already seen; re-observation refreshes recency. */
  isDuplicate(eventId: string): boolean {
    this.totalChecks += 1;
    if (this.lookup.has(eventId)) {
      this.moveToFront(eventId);
      this.duplicateCount += 1;
      return true;
    }
    this.order.push(eventId);
    this.lookup.add(eventId);
    while (this.order.length > this.maxCapacity) {
      const evicted: string | undefined = this.order.shift();
      if (evicted === undefined) {
        break;
      }
      this.lookup.delete(evicted);
      this.evictionCount += 1;
    }
    return false;
  }

  /** Presence check without touching recency or statistics. */
  contains(eventId: string): boolean {
    return this.lookup.has(eventId);
  }

  size(): number {
    return this.lookup.size;
  }

  getStats(): DeduplicationStats {
    const hitRate: number = this.totalChecks > 0
      ? this.duplicateCount / this.totalChecks : 0;
    return new DeduplicationStats(this.maxCapacity, this.lookup.size,
      this.totalChecks, this.duplicateCount, this.evictionCount, hitRate);
  }

  clear(): void {
    this.order.length = 0;
    this.lookup.clear();
    this.totalChecks = 0;
    this.duplicateCount = 0;
    this.evictionCount = 0;
  }

  private moveToFront(eventId: string): void {
    const index: number = this.order.indexOf(eventId);
    if (index >= 0) {
      this.order.splice(index, 1);
    }
    this.order.push(eventId);
  }
}
