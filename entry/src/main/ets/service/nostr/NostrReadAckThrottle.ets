/**
 * Read-receipt pacing for the Nostr transport, mirroring the READ_ACK
 * throttle in bitchat-android NostrTransport.kt: READ receipts are
 * queued and emitted at most one per READ_ACK_INTERVAL_MS (350ms,
 * ~3 per second) so a burst of reads cannot trip relay rate limits.
 * The sender and the scheduler are injected; the device side wires
 * them to the transport and setTimeout, contract tests to fakes.
 * Pure ArkTS: no @ohos/@kit imports, host-runnable by the
 * contract-test harness.
 */
import { NostrConstants } from '../../common/ProtocolConstants';

export class NostrReadAckItem {
  readonly messageId: string;
  readonly peerId: string;

  constructor(messageId: string, peerId: string) {
    this.messageId = messageId;
    this.peerId = peerId;
  }
}

export class NostrReadAckThrottle {
  private readonly intervalMs: number;
  private readonly sender: (item: NostrReadAckItem) => void;
  private readonly scheduler: (delayMs: number, action: () => void) => void;
  private readonly queue: NostrReadAckItem[] = [];
  private sending: boolean = false;

  constructor(intervalMs: number, sender: (item: NostrReadAckItem) => void,
    scheduler: (delayMs: number, action: () => void) => void) {
    this.intervalMs = intervalMs;
    this.sender = sender;
    this.scheduler = scheduler;
  }

  /** Default throttle at the Android/iOS read-ack interval. */
  static atDefaultInterval(sender: (item: NostrReadAckItem) => void,
    scheduler: (delayMs: number, action: () => void) => void): NostrReadAckThrottle {
    return new NostrReadAckThrottle(NostrConstants.READ_ACK_INTERVAL_MS, sender, scheduler);
  }

  enqueue(messageId: string, peerId: string): void {
    this.queue.push(new NostrReadAckItem(messageId, peerId));
    this.pumpIfNeeded();
  }

  pendingCount(): number {
    return this.queue.length;
  }

  /** Drop all queued items (transport cleanup / panic wipe). */
  clear(): void {
    this.queue.splice(0, this.queue.length);
  }

  private pumpIfNeeded(): void {
    if (this.sending || this.queue.length === 0) {
      return;
    }
    this.sending = true;
    this.sendNext();
  }

  private sendNext(): void {
    const item: NostrReadAckItem | undefined = this.queue.shift();
    if (item === undefined) {
      this.sending = false;
      return;
    }
    this.sender(item);
    this.scheduler(this.intervalMs, (): void => {
      this.sending = false;
      this.pumpIfNeeded();
    });
  }
}
