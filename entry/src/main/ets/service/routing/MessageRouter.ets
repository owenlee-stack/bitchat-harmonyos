/**
 * Private-message routing with a mesh-first policy, a Nostr fallback for
 * mutually-favorited contacts, a Noise X courier fallback for sealed
 * envelope delivery and an outbox for undeliverable messages - port of
 * bitchat-android MessageRouter.kt extended with the US17 courier tier
 * (plan.md: mesh -> nostr -> courier -> outbox).
 *
 * Every alias of a contact (mesh peer ID, Noise key hex, ...) maps to one
 * canonical conversation key through the delegate; sends are queued under
 * the canonical key and flushed however the contact becomes reachable.
 *
 * Decision order for sendPrivate:
 *  1. canonical conversation connected with an established Noise session ->
 *     direct mesh send (a transport failure falls through to the next tier
 *     instead of surfacing, so the per-entry retry budget applies)
 *  2. Nostr fallback available (mutual favorite with a known Nostr pubkey)
 *     -> send via Nostr; a failed send falls through to the courier tier
 *  3. Courier fallback available (recipient static key known and courier
 *     candidates connected, US17) -> Noise X sealed envelope deposited
 *     with up to 3 couriers; a failed deposit falls through to the outbox
 *  4. otherwise -> enqueue into the Outbox (100/peer cap, 24h TTL) under the
 *     canonical key and kick the Noise handshake immediately when the peer
 *     is connected but has no session yet
 *
 * A new qualified courier connection triggers a deposit retry through
 * onCourierConnected() (plan.md: 新合格信使连接触发存款重试); the outbox
 * flush itself only retries the mesh and Nostr tiers, because a courier
 * deposit is a one-shot spray tracked by the courier system, not a
 * per-entry retry budget.
 *
 * The 2s tick expires stale entries, flushes whatever became deliverable
 * and re-initiates handshakes for connected peers with queued messages,
 * applying the 5/15/30/60s backoff ladder (capped at 60s).
 *
 * Divergences from the Android source, all intentional:
 *  - a failed direct mesh send enqueues for retry instead of propagating
 *    (plan.md OutboxEntry retryCount <= 8): each failed flush attempt
 *    increments retryCount and the entry is dropped once it exceeds 8
 *  - automatic handshake retries stop after MAX_HANDSHAKE_ATTEMPTS (8)
 *    ladder climbs without success; an immediate kick (peer reappeared,
 *    new message queued) restarts the ladder - Android retries at 60s
 *    forever
 *  - no ContactDirectory yet: the raw peer ID is the conversation ID
 *
 * The mesh facade, clock and tick scheduler are injected so the routing
 * semantics run in the host contract harness.
 */
import { Outbox, OutboxEntry } from './Outbox';

export enum RouteResult {
  MESH = 0,
  NOSTR = 1,
  QUEUED = 2,
  DROPPED = 3,
  /** Fourth decision tier (US17): sealed envelope deposited with couriers. */
  COURIER = 4
}

/** Mesh facade the router drives (implemented by the mesh stack wiring). */
export interface MessageRouterDelegate {
  isConnected(peerID: string): boolean;
  hasEstablishedSession(peerID: string): boolean;
  sendPrivateMessage(content: string, toPeerID: string,
    recipientNickname: string, messageID: string | null): void;
  initiateNoiseHandshake(peerID: string): void;
  /** Canonical conversation key for any alias of a contact. */
  canonicalConversationId(peerID: string): string;
  /** Whether the contact can receive private messages over Nostr right now. */
  canSendViaNostr(peerID: string): boolean;
  /** Send one private message over Nostr; false when the send failed. */
  sendPrivateMessageViaNostr(content: string, targetPeerID: string,
    recipientNickname: string, messageID: string): boolean;
  /** Whether a Noise X courier envelope can reach this contact now (US17). */
  canSendViaCourier(peerID: string): boolean;
  /** Seal and deposit one private message with the connected couriers (US17); false when the deposit failed. */
  sendPrivateMessageViaCourier(content: string, targetPeerID: string,
    recipientNickname: string, messageID: string): boolean;
  /** A new qualified courier connected (US17): retry pending envelope deposits. */
  retryCourierDeposits(): void;
}

/** Per-conversation handshake retry state. */
class ConversationRetry {
  readonly handshakeAttempts: number;
  readonly nextHandshakeAttemptAtMs: number;

  constructor(handshakeAttempts: number, nextHandshakeAttemptAtMs: number) {
    this.handshakeAttempts = handshakeAttempts;
    this.nextHandshakeAttemptAtMs = nextHandshakeAttemptAtMs;
  }
}

export class MessageRouter {
  static readonly OUTBOX_TICK_MS: number = 2000;
  static readonly HANDSHAKE_RETRY_BACKOFF_MS: number[] = [5000, 15000, 30000, 60000];
  static readonly MAX_HANDSHAKE_ATTEMPTS: number = 8;

  private readonly delegate: MessageRouterDelegate;
  private readonly outbox: Outbox;
  private readonly retryState: Map<string, ConversationRetry> = new Map();
  private readonly schedule: ((delayMs: number, task: () => void) => number) | null;
  private readonly cancel: ((handle: number) => void) | null;
  private readonly clock: () => number;
  private tickHandle: number | null = null;

  /** Called with the message ID of queued messages that expired, were evicted or exhausted their retries. */
  onMessageExpired: ((messageID: string) => void) | null = null;

  constructor(delegate: MessageRouterDelegate, outbox: Outbox | null = null,
    schedule: ((delayMs: number, task: () => void) => number) | null = null,
    cancel: ((handle: number) => void) | null = null,
    clock: () => number = (): number => Date.now()) {
    this.delegate = delegate;
    this.outbox = outbox !== null ? outbox : new Outbox();
    this.schedule = schedule;
    this.cancel = cancel;
    this.clock = clock;
    if (this.schedule !== null) {
      this.startOutboxScheduler();
    }
  }

  getOutbox(): Outbox {
    return this.outbox;
  }

  clearAll(): void {
    this.outbox.clearAll();
    this.retryState.clear();
  }

  sendPrivate(content: string, toPeerID: string, recipientNickname: string,
    messageID: string): RouteResult {
    const canonical: string = this.delegate.canonicalConversationId(toPeerID);
    const connected: boolean = this.delegate.isConnected(canonical);
    const established: boolean = this.delegate.hasEstablishedSession(canonical);
    if (connected && established) {
      try {
        this.delegate.sendPrivateMessage(content, canonical, recipientNickname, messageID);
        return RouteResult.MESH;
      } catch (e) {
        // Transport hiccup: fall through to the next tier so the retry
        // budget applies instead of dropping the message.
      }
    }
    if (this.delegate.canSendViaNostr(toPeerID)) {
      try {
        if (this.delegate.sendPrivateMessageViaNostr(content, toPeerID,
          recipientNickname, messageID)) {
          return RouteResult.NOSTR;
        }
      } catch (e) {
        // Nostr hiccups queue like any other failure.
      }
    }
    if (this.delegate.canSendViaCourier(toPeerID)) {
      try {
        if (this.delegate.sendPrivateMessageViaCourier(content, toPeerID,
          recipientNickname, messageID)) {
          return RouteResult.COURIER;
        }
      } catch (e) {
        // Courier hiccups queue like any other failure.
      }
    }
    const entry: OutboxEntry = new OutboxEntry(messageID, content,
      recipientNickname, this.clock());
    const evicted: string[] = this.outbox.enqueue(canonical, entry);
    this.notifyExpiredAll(evicted);
    if (connected && !established) {
      this.kickHandshake(canonical, canonical, true);
    }
    return RouteResult.QUEUED;
  }

  /**
   * Flush any queued messages for a peer that is ready to receive. Entries
   * under either the canonical or the raw target key are attempted: mesh
   * first when the canonical session is ready, Nostr otherwise (Android
   * if/else parity); failures burn the per-entry retry budget.
   */
  flushOutboxFor(targetPeerID: string): void {
    const canonical: string = this.delegate.canonicalConversationId(targetPeerID);
    const queueKey: string | null = this.firstQueueKey(canonical, targetPeerID);
    if (queueKey === null) {
      this.outbox.removeConversationIfEmpty(canonical);
      this.outbox.removeConversationIfEmpty(targetPeerID);
      return;
    }
    const now: number = this.clock();
    const entries: OutboxEntry[] | null = this.outbox.getQueuedEntries(queueKey);
    if (entries === null || entries.length === 0) {
      return;
    }
    for (let i: number = 0; i < entries.length; i++) {
      const entry: OutboxEntry = entries[i];
      if (this.isReady(canonical)) {
        try {
          this.delegate.sendPrivateMessage(entry.content, canonical, entry.nickname,
            entry.messageID);
          this.outbox.removeEntry(queueKey, entry);
        } catch (e) {
          this.countFailedAttempt(queueKey, entry, now);
        }
      } else if (this.delegate.canSendViaNostr(targetPeerID)) {
        let sent: boolean = false;
        try {
          sent = this.delegate.sendPrivateMessageViaNostr(entry.content, targetPeerID,
            entry.nickname, entry.messageID);
        } catch (e) {
          sent = false;
        }
        if (sent) {
          this.outbox.removeEntry(queueKey, entry);
        } else {
          this.countFailedAttempt(queueKey, entry, now);
        }
      }
    }
    if (this.outbox.removeConversationIfEmpty(queueKey)) {
      this.resetRetry(queueKey);
    }
    this.outbox.removeConversationIfEmpty(canonical);
    this.outbox.removeConversationIfEmpty(targetPeerID);
    this.resetRetry(canonical);
    this.resetRetry(targetPeerID);
  }

  /**
   * One scheduler pass: expire old entries, flush what can be sent, and
   * re-initiate handshakes (with backoff) for peers that are connected but
   * have no established session yet.
   */
  tickOutbox(nowMs: number): void {
    const conversationIDs: string[] = this.outbox.getConversationIDs();
    for (const conversationID of conversationIDs) {
      const expired: string[] = this.outbox.expireOldEntries(conversationID, nowMs);
      this.notifyExpiredAll(expired);
      if (this.outbox.getEntryCount(conversationID) === 0) {
        this.outbox.removeConversationIfEmpty(conversationID);
        this.resetRetry(conversationID);
        continue;
      }
      const canonical: string = this.delegate.canonicalConversationId(conversationID);
      if (this.isReady(canonical)) {
        this.flushOutboxFor(conversationID);
        continue;
      }
      if (this.delegate.canSendViaNostr(conversationID)) {
        this.flushOutboxFor(conversationID);
        continue;
      }
      if (this.delegate.isConnected(canonical)) {
        this.kickHandshake(conversationID, canonical, false);
      }
    }
  }

  /** Called when mesh peer list changes; flush matching outbox entries. */
  onPeersUpdated(peerIDs: string[]): void {
    for (const peerID of peerIDs) {
      this.kickHandshakeIfPending(peerID);
      this.flushOutboxFor(peerID);
    }
  }

  /** Called when a Noise session becomes established; flush the peer. */
  onSessionEstablished(peerID: string): void {
    this.resetRetry(peerID);
    this.flushOutboxFor(peerID);
  }

  /**
   * Called when a new qualified courier peer connects (US17): pending
   * envelope deposits retry with the widened courier candidate set.
   */
  onCourierConnected(): void {
    try {
      this.delegate.retryCourierDeposits();
    } catch (e) {
      // A retry failure must not break the caller's connect path.
    }
  }

  isSchedulerRunning(): boolean {
    return this.tickHandle !== null;
  }

  startOutboxScheduler(): void {
    if (this.schedule === null || this.tickHandle !== null) {
      return;
    }
    this.tickHandle = this.schedule(MessageRouter.OUTBOX_TICK_MS, (): void => {
      try {
        this.tickOutbox(this.clock());
      } catch (e) {
        // One failed tick must not kill the rescheduling loop.
      }
      this.tickHandle = null;
      this.startOutboxScheduler();
    });
  }

  stopOutboxScheduler(): void {
    if (this.tickHandle !== null && this.cancel !== null) {
      this.cancel(this.tickHandle);
    }
    this.tickHandle = null;
  }

  private isReady(peerID: string): boolean {
    return this.delegate.isConnected(peerID) &&
      this.delegate.hasEstablishedSession(peerID);
  }

  /** The outbox key holding the queue for this target: canonical first, raw next. */
  private firstQueueKey(canonical: string, targetPeerID: string): string | null {
    if (this.outbox.getEntryCount(canonical) > 0) {
      return canonical;
    }
    if (this.outbox.getEntryCount(targetPeerID) > 0) {
      return targetPeerID;
    }
    return null;
  }

  /** Burn one send attempt; evict and report the entry once the budget is gone. */
  private countFailedAttempt(queueKey: string, entry: OutboxEntry, now: number): void {
    entry.lastAttemptAtMs = now;
    entry.retryCount += 1;
    if (entry.retryCount > Outbox.MAX_SEND_ATTEMPTS) {
      this.outbox.removeEntry(queueKey, entry);
      this.notifyExpired(entry.messageID);
    }
  }

  /**
   * Initiate a Noise handshake for a conversation with queued messages,
   * applying the backoff ladder between attempts. An immediate kick resets
   * the backoff (peer just appeared or a new message was queued). Kicks are
   * suppressed while a previous attempt is still inside its backoff window.
   */
  private kickHandshake(conversationID: string, meshTarget: string, immediate: boolean): void {
    const now: number = this.clock();
    const current: ConversationRetry | null = this.retryState.get(conversationID) ?? null;
    if (current !== null && now < current.nextHandshakeAttemptAtMs) {
      return;
    }
    const attempts: number = immediate ? 0 :
      (current !== null ? current.handshakeAttempts : 0);
    if (!immediate && attempts >= MessageRouter.MAX_HANDSHAKE_ATTEMPTS) {
      // Retry budget exhausted: wait for a reconnect or new message.
      return;
    }
    try {
      this.delegate.initiateNoiseHandshake(meshTarget);
    } catch (e) {
      // Transport hiccups must not break the backoff bookkeeping.
    }
    const backoff: number = MessageRouter.HANDSHAKE_RETRY_BACKOFF_MS[
      Math.min(attempts, MessageRouter.HANDSHAKE_RETRY_BACKOFF_MS.length - 1)];
    this.retryState.set(conversationID, new ConversationRetry(attempts + 1, now + backoff));
  }

  /**
   * A peer (re)appeared: if we still owe them queued messages and there is
   * no working session yet, restart the handshake immediately instead of
   * waiting for the backoff.
   */
  private kickHandshakeIfPending(peerID: string): void {
    const canonical: string = this.delegate.canonicalConversationId(peerID);
    if (this.firstQueueKey(canonical, peerID) === null) {
      return;
    }
    if (this.isReady(canonical)) {
      return;
    }
    if (!this.delegate.isConnected(canonical)) {
      return;
    }
    this.kickHandshake(canonical, canonical, true);
  }

  private resetRetry(peerID: string): void {
    this.retryState.delete(peerID);
  }

  private notifyExpiredAll(messageIDs: string[]): void {
    for (let i: number = 0; i < messageIDs.length; i++) {
      this.notifyExpired(messageIDs[i]);
    }
  }

  private notifyExpired(messageID: string): void {
    if (this.onMessageExpired !== null) {
      try {
        this.onMessageExpired(messageID);
      } catch (e) {
        // Listener errors must not break routing.
      }
    }
  }
}
