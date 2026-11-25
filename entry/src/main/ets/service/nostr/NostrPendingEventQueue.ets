/**
 * Bounded per-relay delivery queue for reconnect reliability,
 * mirroring bitchat-android NostrPendingEventQueue.kt (capacity 500
 * from NostrRelayManager.MAX_QUEUED_EVENTS). Queue entries carry a
 * local queue ID rather than the Nostr event ID because the same
 * signed event may be intentionally published to different relay
 * sets. ArkTS is single-threaded per instance, so no locking is
 * needed. Pure ArkTS: no @ohos/@kit imports, host-runnable by the
 * contract-test harness.
 */
import { NostrEvent } from './NostrEvent';

export class NostrPendingDelivery {
  readonly queueId: number;
  readonly event: NostrEvent;

  constructor(queueId: number, event: NostrEvent) {
    this.queueId = queueId;
    this.event = event;
  }
}

class NostrPendingQueueEntry {
  readonly queueId: number;
  readonly event: NostrEvent;
  readonly pendingRelayUrls: Set<string>;

  constructor(queueId: number, event: NostrEvent, pendingRelayUrls: Set<string>) {
    this.queueId = queueId;
    this.event = event;
    this.pendingRelayUrls = pendingRelayUrls;
  }
}

export class NostrPendingEventQueue {
  private readonly capacity: number;
  private readonly entries: NostrPendingQueueEntry[] = [];
  private nextQueueId: number = 1;

  constructor(capacity: number) {
    if (capacity <= 0) {
      throw new Error('NostrPendingEventQueue capacity must be positive');
    }
    this.capacity = capacity;
  }

  /** Enqueue a delivery; null when no non-blank relay URL remains. */
  enqueue(event: NostrEvent, relayUrls: string[]): number | null {
    const pendingRelays: Set<string> = new Set<string>();
    for (let i: number = 0; i < relayUrls.length; i++) {
      const url: string = relayUrls[i];
      if (url.trim().length > 0) {
        pendingRelays.add(url);
      }
    }
    if (pendingRelays.size === 0) {
      return null;
    }
    if (this.entries.length >= this.capacity) {
      this.entries.shift();
    }
    const queueId: number = this.nextQueueId;
    this.nextQueueId += 1;
    this.entries.push(new NostrPendingQueueEntry(queueId, event, pendingRelays));
    return queueId;
  }

  /** Deliveries still awaiting the given relay (oldest first). */
  pendingForRelay(relayUrl: string): NostrPendingDelivery[] {
    const out: NostrPendingDelivery[] = [];
    for (let i: number = 0; i < this.entries.length; i++) {
      const entry: NostrPendingQueueEntry = this.entries[i];
      if (entry.pendingRelayUrls.has(relayUrl)) {
        out.push(new NostrPendingDelivery(entry.queueId, entry.event));
      }
    }
    return out;
  }

  /** Record one relay as served; the entry drops once every relay is done. */
  markDelivered(queueId: number, relayUrl: string): void {
    for (let i: number = 0; i < this.entries.length; i++) {
      const entry: NostrPendingQueueEntry = this.entries[i];
      if (entry.queueId !== queueId) {
        continue;
      }
      entry.pendingRelayUrls.delete(relayUrl);
      if (entry.pendingRelayUrls.size === 0) {
        this.entries.splice(i, 1);
      }
      return;
    }
  }

  clear(): void {
    this.entries.length = 0;
  }

  size(): number {
    return this.entries.length;
  }
}
