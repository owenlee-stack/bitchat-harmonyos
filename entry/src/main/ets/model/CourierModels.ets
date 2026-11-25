/**
 * Courier sealed-mail models (whitepaper §6.2, spec FR-034, plan D11): the
 * Noise X sealed envelope carried peer-to-peer, the 16-byte rotation
 * recipient tag that hides routing information, and the store-forward cache
 * entry for offline peers.
 *
 * StoreForwardEntry mirrors bitchat-android StoreForwardManager.StoredMessage
 * (the one Android reference for this domain; the courier system itself is
 * not implemented on Android). The rotation-tag derivation therefore has no
 * cross-client golden source; its format is fixed here and locked by
 * CourierModelsContractTests:
 *   tag = HMAC-SHA256(staticKey, "bitchat-courier-tag-v1" || u64be(day))[0..16)
 * where day = floor(timestampMs / 24h) in UTC, so tags are unlinkable across
 * UTC-midnight boundaries. Pure ArkTS: no @ohos/@kit imports, host-runnable
 * by the contract-test harness.
 */
import { ByteUtils, HmacSha256 } from '../common/ByteUtils';
import { BitchatPacket, MessageType } from './BitchatPacket';
import { CourierConstants, StoreForwardConstants } from '../common/ProtocolConstants';

/** Trust tier under which an envelope was deposited (quota 5 favorite / 2 verified). */
export enum CourierEnvelopeTier {
  FAVORITE = 0,
  VERIFIED = 1
}

/**
 * 16-byte rotating recipient tag: the only routing information visible on a
 * sealed envelope. Computable only with the recipient's static key; a
 * different static key or a different UTC day yields an unrelated tag.
 */
export class CourierRecipientTag {
  static readonly TAG_SIZE: number = CourierConstants.RECIPIENT_TAG_SIZE;
  static readonly DOMAIN: string = 'bitchat-courier-tag-v1';

  /** UTC day bucket a timestamp falls into (tags rotate at UTC midnight). */
  static utcDayIndex(timestampMs: number): number {
    return Math.floor(timestampMs / CourierConstants.UTC_DAY_MS);
  }

  /** Domain-separated 16-byte tag for the UTC day of `timestampMs`. */
  static compute(staticKey: Uint8Array, timestampMs: number): Uint8Array {
    if (timestampMs < 0) {
      throw new Error('Recipient tag timestamps must be non-negative epoch milliseconds');
    }
    const prefix: Uint8Array = ByteUtils.utf8Encode(CourierRecipientTag.DOMAIN);
    const dayBytes: Uint8Array = new Uint8Array(8);
    let rest: number = CourierRecipientTag.utcDayIndex(timestampMs);
    for (let i: number = 7; i >= 0; i--) {
      dayBytes[i] = rest % 256;
      rest = Math.floor(rest / 256);
    }
    const mac: Uint8Array = HmacSha256.compute(staticKey, ByteUtils.concat(prefix, dayBytes));
    return mac.slice(0, CourierRecipientTag.TAG_SIZE);
  }

  /**
   * Whether `tag` addresses the holder of `staticKey` at `nowMs`. Envelopes
   * live up to 24h, so a tag minted on the previous UTC day must still match.
   */
  static matches(staticKey: Uint8Array, tag: Uint8Array, nowMs: number): boolean {
    if (tag.length !== CourierRecipientTag.TAG_SIZE) {
      return false;
    }
    const today: Uint8Array = CourierRecipientTag.compute(staticKey, nowMs);
    if (ByteUtils.equals(tag, today)) {
      return true;
    }
    const previousDay: Uint8Array =
      CourierRecipientTag.compute(staticKey, nowMs - CourierConstants.UTC_DAY_MS);
    return ByteUtils.equals(tag, previousDay);
  }
}

/**
 * Sealed courier envelope: Noise X ciphertext plus the rotation tag, spray
 * budget, creation time and deposit tier. Opaque to carriers - no sender or
 * recipient identity travels outside the ciphertext (spec US17 scenario 3).
 */
export class CourierEnvelope {
  readonly ciphertext: Uint8Array;
  readonly recipientTag: Uint8Array;
  readonly createdAt: number;
  readonly tier: CourierEnvelopeTier;
  /** Remaining spray-and-wait copies; starts at 4, never exceeds 8. */
  copyBudget: number;

  constructor(ciphertext: Uint8Array, recipientTag: Uint8Array, createdAt: number,
    tier: CourierEnvelopeTier, copyBudget: number) {
    if (recipientTag.length !== CourierRecipientTag.TAG_SIZE) {
      throw new Error('Courier recipient tag must be exactly 16 bytes');
    }
    if (ciphertext.length === 0 || ciphertext.length > CourierConstants.ENVELOPE_MAX_BYTES) {
      throw new Error('Courier envelope ciphertext must be 1..16384 bytes');
    }
    if (createdAt < 0) {
      throw new Error('Courier envelope createdAt must be non-negative epoch milliseconds');
    }
    if (copyBudget < 0 || copyBudget > CourierConstants.COPY_BUDGET_MAX) {
      throw new Error('Courier copy budget must be between 0 and 8');
    }
    this.ciphertext = ciphertext;
    this.recipientTag = recipientTag;
    this.createdAt = createdAt;
    this.tier = tier;
    this.copyBudget = copyBudget;
  }

  /** Fresh deposit with the initial spray budget. */
  static forDeposit(ciphertext: Uint8Array, recipientTag: Uint8Array, createdAt: number,
    tier: CourierEnvelopeTier): CourierEnvelope {
    return new CourierEnvelope(ciphertext, recipientTag, createdAt, tier,
      CourierConstants.COPY_BUDGET_INITIAL);
  }

  /** 24h envelope lifetime (FR-034). */
  isExpired(nowMs: number): boolean {
    return nowMs - this.createdAt >= CourierConstants.ENVELOPE_TTL_MS;
  }

  /** Top up the spray budget without exceeding the cap; returns the amount added. */
  addCopyBudget(amount: number): number {
    if (amount <= 0) {
      return 0;
    }
    const before: number = this.copyBudget;
    this.copyBudget = Math.min(CourierConstants.COPY_BUDGET_MAX, before + amount);
    return this.copyBudget - before;
  }

  /** Consume one copy budget for a spray; false when exhausted. */
  trySpendCopy(): boolean {
    if (this.copyBudget <= 0) {
      return false;
    }
    this.copyBudget -= 1;
    return true;
  }

  /**
   * Spray-and-wait handover: hand half of the remaining budget to another
   * courier, keeping the rest; returns the handed amount.
   */
  handoffHalfBudget(): number {
    const half: number = Math.floor(this.copyBudget / 2);
    this.copyBudget -= half;
    return half;
  }

  static equals(a: CourierEnvelope, b: CourierEnvelope): boolean {
    if (a.createdAt !== b.createdAt || a.copyBudget !== b.copyBudget || a.tier !== b.tier) {
      return false;
    }
    return ByteUtils.equals(a.ciphertext, b.ciphertext) &&
      ByteUtils.equals(a.recipientTag, b.recipientTag);
  }
}

/**
 * One cached packet awaiting an offline peer. Mirrors the Android
 * StoredMessage (packet, timestamp, messageID, isForFavorite); the 12h
 * cleanup applies to the regular cache only - favorite-queued entries are
 * removed on delivery, not by age.
 */
export class StoreForwardEntry {
  readonly packet: BitchatPacket;
  readonly cachedAt: number;
  readonly messageID: string;
  readonly isForFavorite: boolean;

  constructor(packet: BitchatPacket, cachedAt: number, messageID: string,
    isForFavorite: boolean) {
    this.packet = packet;
    this.cachedAt = cachedAt;
    this.messageID = messageID;
    this.isForFavorite = isForFavorite;
  }

  /** Recipient peer ID (hex of the recipient bytes) this entry is cached for. */
  recipientPeerID(): string | null {
    return this.packet.recipientId === null ? null : ByteUtils.bytesToHex(this.packet.recipientId);
  }

  /** 12h cache timeout, favorites exempt (Android cleanupMessageCache). */
  isExpired(nowMs: number): boolean {
    return !this.isForFavorite &&
      nowMs - this.cachedAt >= StoreForwardConstants.MESSAGE_CACHE_TIMEOUT_MS;
  }

  /**
   * Android cache skip list (StoreForwardManager.cacheMessage): never cache
   * noise handshakes, encrypted noise frames, announces, leaves or
   * broadcast packets.
   */
  static isCacheablePacket(packet: BitchatPacket): boolean {
    if (packet.type === MessageType.NOISE_HANDSHAKE || packet.type === MessageType.NOISE_ENCRYPTED ||
      packet.type === MessageType.ANNOUNCE || packet.type === MessageType.LEAVE) {
      return false;
    }
    if (packet.recipientId === null || BitchatPacket.isBroadcastRecipient(packet.recipientId)) {
      return false;
    }
    return true;
  }
}
