/**
 * Outbox - per-conversation queue of private messages that could not be
 * delivered yet (port of the outbox half of bitchat-android
 * MessageRouter.kt, data model per plan.md OutboxEntry).
 *
 * Semantics:
 *  - FIFO per conversation, oldest first
 *  - cap of 100 queued entries per peer; overflow evicts the oldest and
 *    reports the evicted message IDs to the caller
 *  - 24h TTL per entry (expireOldEntries drops strictly older than the TTL)
 *  - per-entry retryCount bounded by MAX_SEND_ATTEMPTS (8): the router
 *    counts failed delivery attempts and drops an entry once the bound is
 *    exceeded
 *
 * Persistence: the outbox is deliberately free of device APIs. Mutations
 * fire onSnapshotChanged with a typed snapshot; the device wiring (US4
 * persistence layer) encrypts and writes that snapshot, and restores it
 * back through restoreSnapshot on startup.
 */

/** One queued private message. */
export class OutboxEntry {
  readonly messageID: string;
  readonly content: string;
  readonly nickname: string;
  readonly enqueuedAtMs: number;
  retryCount: number;
  lastAttemptAtMs: number | null;

  constructor(messageID: string, content: string, nickname: string, enqueuedAtMs: number) {
    this.messageID = messageID;
    this.content = content;
    this.nickname = nickname;
    this.enqueuedAtMs = enqueuedAtMs;
    this.retryCount = 0;
    this.lastAttemptAtMs = null;
  }
}

/** Immutable copy of an entry for snapshots. */
export class OutboxEntrySnapshot {
  readonly messageID: string;
  readonly content: string;
  readonly nickname: string;
  readonly enqueuedAtMs: number;
  readonly retryCount: number;
  readonly lastAttemptAtMs: number | null;

  constructor(messageID: string, content: string, nickname: string, enqueuedAtMs: number,
    retryCount: number, lastAttemptAtMs: number | null) {
    this.messageID = messageID;
    this.content = content;
    this.nickname = nickname;
    this.enqueuedAtMs = enqueuedAtMs;
    this.retryCount = retryCount;
    this.lastAttemptAtMs = lastAttemptAtMs;
  }
}

/** Immutable copy of one conversation queue. */
export class OutboxConversationSnapshot {
  readonly conversationID: string;
  readonly entries: OutboxEntrySnapshot[];

  constructor(conversationID: string, entries: OutboxEntrySnapshot[]) {
    this.conversationID = conversationID;
    this.entries = entries;
  }
}

/** Immutable copy of the whole outbox. */
export class OutboxSnapshot {
  readonly conversations: OutboxConversationSnapshot[];

  constructor(conversations: OutboxConversationSnapshot[]) {
    this.conversations = conversations;
  }
}

export class Outbox {
  static readonly MAX_PER_PEER: number = 100;
  static readonly MESSAGE_TTL_MS: number = 86400000;
  static readonly MAX_SEND_ATTEMPTS: number = 8;

  private readonly conversations: Map<string, OutboxEntry[]> = new Map();

  /** Fired after every mutation with the new full snapshot. */
  onSnapshotChanged: ((snapshot: OutboxSnapshot) => void) | null = null;

  /**
   * Append an entry to a conversation queue. Returns the message IDs
   * evicted to honor the per-peer cap (oldest first).
   */
  enqueue(conversationID: string, entry: OutboxEntry): string[] {
    let queue: OutboxEntry[] | null = this.conversations.get(conversationID) ?? null;
    if (queue === null) {
      queue = [];
      this.conversations.set(conversationID, queue);
    }
    queue.push(entry);
    const evicted: string[] = [];
    while (queue.length > Outbox.MAX_PER_PEER) {
      const removed: OutboxEntry | undefined = queue.shift();
      if (removed !== undefined) {
        evicted.push(removed.messageID);
      }
    }
    this.notifyChanged();
    return evicted;
  }

  /** Conversation IDs that still hold at least one entry, insertion order. */
  getConversationIDs(): string[] {
    const ids: string[] = [];
    this.conversations.forEach((entries: OutboxEntry[], conversationID: string) => {
      if (entries.length > 0) {
        ids.push(conversationID);
      }
    });
    return ids;
  }

  getEntryCount(conversationID: string): number {
    const queue: OutboxEntry[] | null = this.conversations.get(conversationID) ?? null;
    return queue !== null ? queue.length : 0;
  }

  /** Defensive copy of a conversation queue, oldest first. */
  getQueuedEntries(conversationID: string): OutboxEntry[] | null {
    const queue: OutboxEntry[] | null = this.conversations.get(conversationID) ?? null;
    return queue !== null ? queue.slice(0) : null;
  }

  getConversationCount(): number {
    let count: number = 0;
    this.conversations.forEach((entries: OutboxEntry[]) => {
      if (entries.length > 0) {
        count += 1;
      }
    });
    return count;
  }

  /** Remove a single entry (by reference) from its conversation queue. */
  removeEntry(conversationID: string, entry: OutboxEntry): void {
    const queue: OutboxEntry[] | null = this.conversations.get(conversationID) ?? null;
    if (queue === null) {
      return;
    }
    const index: number = queue.indexOf(entry);
    if (index < 0) {
      return;
    }
    queue.splice(index, 1);
    if (queue.length === 0) {
      this.conversations.delete(conversationID);
    }
    this.notifyChanged();
  }

  /** Drop a conversation key if its queue became empty. */
  removeConversationIfEmpty(conversationID: string): boolean {
    const queue: OutboxEntry[] | null = this.conversations.get(conversationID) ?? null;
    if (queue !== null && queue.length === 0) {
      this.conversations.delete(conversationID);
      this.notifyChanged();
      return true;
    }
    return false;
  }

  /** Drop entries strictly older than the TTL. Returns their message IDs. */
  expireOldEntries(conversationID: string, nowMs: number): string[] {
    const queue: OutboxEntry[] | null = this.conversations.get(conversationID) ?? null;
    if (queue === null) {
      return [];
    }
    const expired: string[] = [];
    let changed: boolean = false;
    let i: number = 0;
    while (i < queue.length) {
      const entry: OutboxEntry = queue[i];
      if (nowMs - entry.enqueuedAtMs > Outbox.MESSAGE_TTL_MS) {
        expired.push(entry.messageID);
        queue.splice(i, 1);
        changed = true;
      } else {
        i += 1;
      }
    }
    if (queue.length === 0) {
      this.conversations.delete(conversationID);
      changed = true;
    }
    if (changed) {
      this.notifyChanged();
    }
    return expired;
  }

  clearAll(): void {
    this.conversations.clear();
    this.notifyChanged();
  }

  toSnapshot(): OutboxSnapshot {
    const conversations: OutboxConversationSnapshot[] = [];
    this.conversations.forEach((entries: OutboxEntry[], conversationID: string) => {
      const entrySnapshots: OutboxEntrySnapshot[] = [];
      for (let i: number = 0; i < entries.length; i++) {
        const entry: OutboxEntry = entries[i];
        entrySnapshots.push(new OutboxEntrySnapshot(entry.messageID, entry.content,
          entry.nickname, entry.enqueuedAtMs, entry.retryCount, entry.lastAttemptAtMs));
      }
      conversations.push(new OutboxConversationSnapshot(conversationID, entrySnapshots));
    });
    return new OutboxSnapshot(conversations);
  }

  /** Replace the whole outbox content from a snapshot (validated copy). */
  restoreSnapshot(snapshot: OutboxSnapshot): void {
    this.conversations.clear();
    for (let c: number = 0; c < snapshot.conversations.length; c++) {
      const conversation: OutboxConversationSnapshot = snapshot.conversations[c];
      const queue: OutboxEntry[] = [];
      for (let i: number = 0; i < conversation.entries.length; i++) {
        const entry: OutboxEntrySnapshot = conversation.entries[i];
        const restored: OutboxEntry = new OutboxEntry(entry.messageID, entry.content,
          entry.nickname, entry.enqueuedAtMs);
        restored.retryCount = entry.retryCount;
        restored.lastAttemptAtMs = entry.lastAttemptAtMs;
        queue.push(restored);
      }
      if (queue.length > 0) {
        this.conversations.set(conversation.conversationID, queue);
      }
    }
    this.notifyChanged();
  }

  private notifyChanged(): void {
    if (this.onSnapshotChanged !== null) {
      this.onSnapshotChanged(this.toSnapshot());
    }
  }
}
