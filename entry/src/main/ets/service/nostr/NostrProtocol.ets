/**
 * NIP-17 private direct messages (rumor -> seal -> gift wrap),
 * bit-for-bit compatible with the bitchat-android / iOS envelopes.
 *
 * createPrivateMessage returns the receiver-copy gift wrap only (per
 * iOS); the rumor is kind 14 with a p-tag, the seal is kind 13 (NIP-44
 * v2 encrypted rumor JSON, signed by the sender identity), and the gift
 * wrap is kind 1059 (NIP-44 v2 encrypted seal JSON under a fresh
 * ephemeral key, p-tagged to the recipient). Seal and wrap timestamps
 * are randomized up to 22 hours into the past, leaving 2 hours of slack
 * inside the 24-hour iOS lookback. decryptPrivateMessage re-checks the
 * seal signature and that the seal signer matches the rumor pubkey, so
 * a forged seal from a different key is rejected. Pure ArkTS: no
 * @ohos/@kit imports, host-runnable by the contract-test harness.
 */
import { NostrEvent, NostrKind } from './NostrEvent';
import { NostrIdentity } from './NostrIdentity';
import { NostrRandomSource } from './NostrRandomSource';
import { Nip44 } from './Nip44';
import { Secp256k1 } from './Secp256k1';

/** Result of a successful NIP-17 decryption. */
export class DecryptedPrivateMessage {
  readonly content: string;
  readonly senderPubkey: string;
  readonly createdAt: number;

  constructor(content: string, senderPubkey: string, createdAt: number) {
    this.content = content;
    this.senderPubkey = senderPubkey;
    this.createdAt = createdAt;
  }
}

export class NostrProtocol {
  /** 22h default backdating: 24h iOS lookback minus 2h of safety slack. */
  static readonly NIP17_DEFAULT_MAX_PAST_SECONDS: number = 79200;

  /**
   * Create a NIP-17 private message gift wrap (receiver copy only per
   * iOS). `nowMs` drives the rumor timestamp; all other randomness is
   * drawn from the injected source so contract tests stay golden.
   */
  static createPrivateMessage(content: string, recipientPubkey: string,
    senderIdentity: NostrIdentity, random: NostrRandomSource,
    nowMs: number): NostrEvent[] {
    const nowSeconds: number = Math.floor(nowMs / 1000);
    // 1. Unsigned rumor (kind 14) with p-tag.
    const rumorBase: NostrEvent = new NostrEvent('', senderIdentity.publicKeyHex,
      nowSeconds, NostrKind.DIRECT_MESSAGE, [['p', recipientPubkey]], content, null);
    const rumorId: string = rumorBase.computeEventIdHex();
    const rumor: NostrEvent = new NostrEvent(rumorId, senderIdentity.publicKeyHex,
      nowSeconds, NostrKind.DIRECT_MESSAGE, [['p', recipientPubkey]], content, null);
    // 2. Seal the rumor (kind 13), signed by the sender identity key.
    const sealedEvent: NostrEvent = NostrProtocol.createSeal(rumor, recipientPubkey,
      senderIdentity.privateKeyHex, senderIdentity.publicKeyHex, random, nowSeconds);
    // 3. Gift wrap to the recipient (kind 1059).
    const giftWrapToRecipient: NostrEvent =
      NostrProtocol.createGiftWrap(sealedEvent, recipientPubkey, random, nowSeconds);
    return [giftWrapToRecipient];
  }

  /**
   * Decrypt a received NIP-17 message. Returns the content, sender
   * pubkey and rumor timestamp, or null when the gift wrap cannot be
   * opened, the seal signature is invalid, or the seal signer does not
   * match the rumor pubkey.
   */
  static decryptPrivateMessage(giftWrap: NostrEvent,
    recipientIdentity: NostrIdentity): DecryptedPrivateMessage | null {
    try {
      const seal: NostrEvent | null =
        NostrProtocol.unwrapGiftWrap(giftWrap, recipientIdentity.privateKeyHex);
      if (seal === null) {
        return null;
      }
      if (seal.kind !== NostrKind.SEAL || !seal.isValidSignature()) {
        return null;
      }
      const rumor: NostrEvent | null =
        NostrProtocol.openSeal(seal, recipientIdentity.privateKeyHex);
      if (rumor === null) {
        return null;
      }
      if (seal.pubkey !== rumor.pubkey) {
        return null;
      }
      return new DecryptedPrivateMessage(rumor.content, rumor.pubkey, rumor.createdAt);
    } catch (e) {
      return null;
    }
  }

  /** Random timestamp up to `maxPastSeconds` in the past (NIP-17 backdating). */
  static randomizeTimestampUpToPast(nowSeconds: number, maxPastSeconds: number,
    random: NostrRandomSource): number {
    const offset: number = maxPastSeconds > 0 ? random.nextInt(maxPastSeconds + 1) : 0;
    return nowSeconds - offset;
  }

  /** Random timestamp within +/- 15 minutes of the base (seconds). */
  static randomizeTimestamp(baseSeconds: number, random: NostrRandomSource): number {
    const offset: number = random.nextInt(1800) - 900;
    return baseSeconds + offset;
  }

  private static createSeal(rumor: NostrEvent, recipientPubkey: string,
    senderPrivateKey: string, senderPublicKey: string, random: NostrRandomSource,
    nowSeconds: number): NostrEvent {
    const rumorJson: string = rumor.toJsonString();
    const encrypted: string =
      Nip44.encrypt(rumorJson, recipientPubkey, senderPrivateKey, random.nextBytes(24));
    const seal: NostrEvent = new NostrEvent('', senderPublicKey,
      NostrProtocol.randomizeTimestampUpToPast(nowSeconds,
        NostrProtocol.NIP17_DEFAULT_MAX_PAST_SECONDS, random),
      NostrKind.SEAL, [], encrypted, null);
    // NIP-17 requires the seal to be signed by the sender identity key.
    return seal.sign(senderPrivateKey, random);
  }

  private static createGiftWrap(seal: NostrEvent, recipientPubkey: string,
    random: NostrRandomSource, nowSeconds: number): NostrEvent {
    const sealJson: string = seal.toJsonString();
    // Fresh ephemeral key for the gift wrap.
    const wrapPrivateKey: string =
      Secp256k1.privateKeyFromRandomBytes(random.nextBytes(32));
    const wrapPublicKey: string = Secp256k1.derivePublicKey(wrapPrivateKey);
    const encrypted: string =
      Nip44.encrypt(sealJson, recipientPubkey, wrapPrivateKey, random.nextBytes(24));
    const giftWrap: NostrEvent = new NostrEvent('', wrapPublicKey,
      NostrProtocol.randomizeTimestampUpToPast(nowSeconds,
        NostrProtocol.NIP17_DEFAULT_MAX_PAST_SECONDS, random),
      NostrKind.GIFT_WRAP, [['p', recipientPubkey]], encrypted, null);
    // Sign with the gift wrap ephemeral key.
    return giftWrap.sign(wrapPrivateKey, random);
  }

  private static unwrapGiftWrap(giftWrap: NostrEvent,
    recipientPrivateKey: string): NostrEvent | null {
    try {
      const decrypted: string =
        Nip44.decrypt(giftWrap.content, giftWrap.pubkey, recipientPrivateKey);
      return NostrEvent.parse(decrypted);
    } catch (e) {
      return null;
    }
  }

  private static openSeal(seal: NostrEvent, recipientPrivateKey: string): NostrEvent | null {
    try {
      const decrypted: string =
        Nip44.decrypt(seal.content, seal.pubkey, recipientPrivateKey);
      return NostrEvent.parse(decrypted);
    } catch (e) {
      return null;
    }
  }
}
