/**
 * Nostr transport for offline private messages, receipts and favorite
 * notifications (US12, T060; Android NostrTransport.kt parity).
 *
 * Every send path resolves the recipient's Nostr pubkey through the
 * injected dependency, embeds a "bitchat1:" BitChat packet via
 * NostrEmbeddedBitChat, wraps it with NostrProtocol.createPrivateMessage
 * (NIP-17) and hands the resulting gift wrap events to the injected
 * publisher (the device wiring registers them as pending gift wraps
 * and sends them through NostrRelayManager; contract tests capture
 * them for golden verification).
 *
 * READ receipts are paced through NostrReadAckThrottle (350ms) so a
 * burst of reads cannot trip relay rate limits; delivery acks and
 * everything else go out immediately (Android parity).
 *
 * The no-recipient variants mirror Android's geohash ack helpers: the
 * sender ID inside the embedded packet is fresh random per envelope
 * so the stable mesh peer ID never links personas. They are also the
 * ack path for inbound account-DM gift wraps (Android
 * NostrDirectMessageHandler uses them for every decrypted gift wrap).
 *
 * Pure ArkTS: no @ohos/@kit imports, host-runnable by the
 * contract-test harness.
 */
import { ByteUtils } from '../../common/ByteUtils';
import { FavoriteControlMessage } from '../../model/FavoriteModels';
import { NoisePayloadType } from '../../model/IdentityModels';
import { ContactIdentityResolver } from '../identity/ContactIdentityResolver';
import { NostrEmbeddedBitChat } from './NostrEmbeddedBitChat';
import { NostrIdentity } from './NostrIdentity';
import { NostrEvent } from './NostrEvent';
import { NostrProtocol } from './NostrProtocol';
import { NostrRandomSource } from './NostrRandomSource';
import { NostrReadAckItem, NostrReadAckThrottle } from './NostrReadAckThrottle';

/** Injected transport dependencies; all device touch points live here. */
export interface NostrTransportDeps {
  /** 16-hex mesh peer ID embedded in recipient-addressed envelopes. */
  senderPeerID: () => string;
  /** Current Nostr identity, or null when none is available. */
  currentIdentity: () => NostrIdentity | null;
  /** Resolve a peer alias to its Nostr pubkey (npub or hex); null when unknown. */
  resolveNostrPubkey: (peerID: string) => string | null;
  /** Mesh peer ID stored for a Nostr pubkey; null when none is known. */
  findPeerIDForNostrPubkey: (npubOrHex: string) => string | null;
  /** Cryptographically secure randomness. */
  random: () => NostrRandomSource;
  /** Wall clock in milliseconds. */
  now: () => number;
  /** Publish gift wrap events (device: pending-wrap registration + relay send). */
  publish: (events: NostrEvent[]) => void;
  /** Schedule a task after delayMs; returns a cancellable handle. */
  schedule: (delayMs: number, task: () => void) => number;
}

export class NostrTransport {
  private readonly deps: NostrTransportDeps;
  private readonly readThrottle: NostrReadAckThrottle;

  constructor(deps: NostrTransportDeps) {
    this.deps = deps;
    this.readThrottle = NostrReadAckThrottle.atDefaultInterval(
      (item: NostrReadAckItem): void => {
        this.deliverReadReceipt(item.messageId, item.peerId);
      },
      (delayMs: number, action: () => void): void => {
        this.deps.schedule(delayMs, action);
      });
  }

  /** Send a private message; false when any step fails (caller queues/retries). */
  sendPrivateMessage(content: string, to: string, messageID: string): boolean {
    const recipientHex: string | null = this.resolveRecipientHex(to);
    if (recipientHex === null) {
      return false;
    }
    const identity: NostrIdentity | null = this.deps.currentIdentity();
    if (identity === null) {
      return false;
    }
    const recipientNostrPubkey: string | null = this.deps.resolveNostrPubkey(to);
    if (recipientNostrPubkey === null) {
      return false;
    }
    const recipientPeerIDForEmbed: string | null =
      this.deps.findPeerIDForNostrPubkey(recipientNostrPubkey);
    if (recipientPeerIDForEmbed === null || recipientPeerIDForEmbed === '') {
      // Android parity: without a stored peer ID the PM cannot be
      // embedded, so the send is refused.
      return false;
    }
    const embedded: string | null = NostrEmbeddedBitChat.encodePMForNostr(content,
      messageID, recipientPeerIDForEmbed, this.deps.senderPeerID(), this.deps.now());
    if (embedded === null) {
      return false;
    }
    this.publishPrivate(embedded, recipientHex, identity);
    return true;
  }

  /** Send a DELIVERED ack immediately (not throttled; Android parity). */
  sendDeliveryAck(messageID: string, to: string): boolean {
    return this.sendRecipientAck(NoisePayloadType.DELIVERED, messageID, to);
  }

  /** Queue a READ receipt; emitted at most one per 350ms. */
  sendReadReceipt(messageID: string, to: string): void {
    this.readThrottle.enqueue(messageID, to);
  }

  /** Send a favorite/unfavorite control message (not gated on canSendViaNostr). */
  sendFavoriteNotification(to: string, isFavorite: boolean): boolean {
    const recipientHex: string | null = this.resolveRecipientHex(to);
    if (recipientHex === null) {
      return false;
    }
    const identity: NostrIdentity | null = this.deps.currentIdentity();
    if (identity === null) {
      return false;
    }
    const content: string = FavoriteControlMessage.encode(isFavorite, identity.npub);
    const messageID: string = ByteUtils.bytesToHex(this.deps.random().nextBytes(16));
    const embedded: string | null = NostrEmbeddedBitChat.encodePMForNostr(content,
      messageID, to, this.deps.senderPeerID(), this.deps.now());
    if (embedded === null) {
      return false;
    }
    this.publishPrivate(embedded, recipientHex, identity);
    return true;
  }

  /** DELIVERED ack without an embedded recipient (inbound gift-wrap acks). */
  sendDeliveryAckNoRecipient(messageID: string, toRecipientHex: string): boolean {
    return this.sendNoRecipientAck(NoisePayloadType.DELIVERED, messageID, toRecipientHex);
  }

  /** READ receipt without an embedded recipient (inbound gift-wrap acks). */
  sendReadReceiptNoRecipient(messageID: string, toRecipientHex: string): boolean {
    return this.sendNoRecipientAck(NoisePayloadType.READ_RECEIPT, messageID, toRecipientHex);
  }

  pendingReadReceiptCount(): number {
    return this.readThrottle.pendingCount();
  }

  /** Drop queued READ receipts (panic wipe / transport teardown). */
  cleanup(): void {
    this.readThrottle.clear();
  }

  private deliverReadReceipt(messageID: string, to: string): boolean {
    return this.sendRecipientAck(NoisePayloadType.READ_RECEIPT, messageID, to);
  }

  private sendRecipientAck(type: NoisePayloadType, messageID: string, to: string): boolean {
    const recipientHex: string | null = this.resolveRecipientHex(to);
    if (recipientHex === null) {
      return false;
    }
    const identity: NostrIdentity | null = this.deps.currentIdentity();
    if (identity === null) {
      return false;
    }
    const ack: string | null = NostrEmbeddedBitChat.encodeAckForNostr(type, messageID,
      to, this.deps.senderPeerID(), this.deps.now());
    if (ack === null) {
      return false;
    }
    this.publishPrivate(ack, recipientHex, identity);
    return true;
  }

  private sendNoRecipientAck(type: NoisePayloadType, messageID: string,
    toRecipientHex: string): boolean {
    if (toRecipientHex === '') {
      return false;
    }
    const identity: NostrIdentity | null = this.deps.currentIdentity();
    if (identity === null) {
      return false;
    }
    const embedded: string | null = NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(
      type, messageID, this.deps.random(), this.deps.now());
    if (embedded === null) {
      return false;
    }
    this.publishPrivate(embedded, toRecipientHex, identity);
    return true;
  }

  private resolveRecipientHex(peerID: string): string | null {
    const recipientNostrPubkey: string | null = this.deps.resolveNostrPubkey(peerID);
    if (recipientNostrPubkey === null) {
      return null;
    }
    return ContactIdentityResolver.nostrPubkeyHex(recipientNostrPubkey);
  }

  private publishPrivate(content: string, recipientHex: string,
    identity: NostrIdentity): void {
    const giftWraps: NostrEvent[] = NostrProtocol.createPrivateMessage(content,
      recipientHex, identity, this.deps.random(), this.deps.now());
    this.deps.publish(giftWraps);
  }
}
