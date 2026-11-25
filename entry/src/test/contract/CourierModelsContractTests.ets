/**
 * Contract vectors for the courier sealed-mail models (T061, spec FR-034,
 * plan D11): the 16-byte rotation recipient-tag derivation (format lock:
 * domain prefix || u64be UTC day, HMAC-SHA256, truncated to 16 bytes), day
 * rotation and cross-day unlinkability, envelope validation, 24h lifetime
 * and spray-and-wait budget semantics, and the store-forward cache-entry
 * rules mirrored from bitchat-android StoreForwardManager.kt (skip list,
 * 12h regular-cache timeout, favorite exemption).
 */
import { ContractAssert } from './ContractAssert';
import { ByteUtils, HmacSha256 } from '../../main/ets/common/ByteUtils';
import {
  CourierEnvelopeTier,
  CourierRecipientTag,
  CourierEnvelope,
  StoreForwardEntry
} from '../../main/ets/model/CourierModels';
import {
  BitchatPacket,
  MessageType,
  specialRecipientBroadcast
} from '../../main/ets/model/BitchatPacket';
import {
  CourierConstants,
  StoreForwardConstants
} from '../../main/ets/common/ProtocolConstants';

function makePacket(type: number, recipient: Uint8Array | null): BitchatPacket {
  return new BitchatPacket(2, type, ByteUtils.hexToBytes('1020304050607080'), recipient,
    1737000000000, ByteUtils.utf8Encode('payload'), null, 7, null);
}

function filledBytes(length: number, fill: number): Uint8Array {
  const out: Uint8Array = new Uint8Array(length);
  for (let i: number = 0; i < length; i++) {
    out[i] = fill;
  }
  return out;
}

function u64be(value: number): Uint8Array {
  const out: Uint8Array = new Uint8Array(8);
  let rest: number = value;
  for (let i: number = 7; i >= 0; i--) {
    out[i] = rest % 256;
    rest = Math.floor(rest / 256);
  }
  return out;
}

export function runCourierModelsContractTests(t: ContractAssert): void {
  const key: Uint8Array = ByteUtils.hexToBytes(
    'aa112233445566778899001122334455f0e0d0c0b0a09080706050403020100');
  const otherKey: Uint8Array = ByteUtils.hexToBytes(
    'bb112233445566778899001122334455f0e0d0c0b0a090807060504030201ee');

  // Plan constants (FR-034): budgets, quotas, pool bounds, lifetimes.
  {
    t.equalNumber(4, CourierConstants.COPY_BUDGET_INITIAL, 'initial copy budget is 4');
    t.equalNumber(8, CourierConstants.COPY_BUDGET_MAX, 'maximum copy budget is 8');
    t.equalNumber(5, CourierConstants.QUOTA_MUTUAL_FAVORITE, 'mutual-favorite deposit quota is 5');
    t.equalNumber(2, CourierConstants.QUOTA_VERIFIED, 'verified deposit quota is 2');
    t.equalNumber(40, CourierConstants.POOL_SLOTS, 'envelope pool has 40 slots');
    t.equalNumber(20, CourierConstants.POOL_USABLE_SLOTS, '20 usable pool slots');
    t.equalNumber(16384, CourierConstants.ENVELOPE_MAX_BYTES, 'envelope ciphertext bound is 16 KiB');
    t.equalNumber(86400000, CourierConstants.ENVELOPE_TTL_MS, 'envelope lifetime is 24h');
    t.equalNumber(3, CourierConstants.DEPOSIT_COURIER_TARGET, 'deposit retry target is 3 couriers');
    t.equalNumber(600000, CourierConstants.RELAYED_ANNOUNCE_THROTTLE_MS,
      'relayed-announce duplicate throttle is 10 minutes');
    t.equalNumber(0x04, CourierConstants.ENVELOPE_WIRE_TYPE, 'iOS courier envelope wire type is 0x04');
    t.equalNumber(10, StoreForwardConstants.REPLAY_INTERVAL_MS, 'online replay interval is 10ms');
    t.equalNumber(43200000, StoreForwardConstants.MESSAGE_CACHE_TIMEOUT_MS,
      'store-forward cache timeout is 12h');
    t.equalNumber(1000, StoreForwardConstants.MAX_CACHED_MESSAGES_FAVORITES,
      'favorite queue holds up to 1000 entries');
  }

  // Rotation tag: UTC day bucketing.
  {
    t.equalNumber(0, CourierRecipientTag.utcDayIndex(0), 'epoch starts in day 0');
    t.equalNumber(0, CourierRecipientTag.utcDayIndex(86399999), 'last millisecond of day 0');
    t.equalNumber(1, CourierRecipientTag.utcDayIndex(86400000), 'first millisecond of day 1');
    t.equalNumber(20104, CourierRecipientTag.utcDayIndex(1737000000000),
      '2025-01-16T04:00Z falls in UTC day 20104');
  }

  // Rotation tag: format lock - the composition is exactly
  // HMAC-SHA256(staticKey, "bitchat-courier-tag-v1" || u64be(day))[0..16).
  {
    const day: number = CourierRecipientTag.utcDayIndex(1737000000000);
    const input: Uint8Array = ByteUtils.concat(
      ByteUtils.utf8Encode(CourierRecipientTag.DOMAIN), u64be(day));
    const expected: Uint8Array = HmacSha256.compute(key, input).slice(0, 16);
    t.equalBytes(expected, CourierRecipientTag.compute(key, 1737000000000),
      'tag derivation format lock');
  }

  // Rotation tag: size, same-day stability, cross-day unlinkability.
  {
    const t0: number = 1737000000000;
    const tag: Uint8Array = CourierRecipientTag.compute(key, t0);
    t.equalNumber(16, tag.length, 'recipient tag is 16 bytes');
    t.equalBytes(tag, CourierRecipientTag.compute(key, t0 + 3600000),
      'timestamps within one UTC day share a tag');
    const nextDay: Uint8Array = CourierRecipientTag.compute(key, t0 + 86400000);
    t.isFalse(ByteUtils.equals(tag, nextDay), 'tags do not carry across UTC midnight');
    t.equalBytes(nextDay, CourierRecipientTag.compute(key, t0 + 86400000 + 3600000),
      'the next day is itself stable');
    t.isFalse(ByteUtils.equals(tag, CourierRecipientTag.compute(otherKey, t0)),
      'a different static key yields an unrelated tag');
    t.throws((): void => {
      CourierRecipientTag.compute(key, -1);
    }, 'negative timestamps are rejected');
  }

  // Rotation tag: matches() accepts only the current and previous UTC day.
  {
    const now: number = 1737000000000;
    const today: Uint8Array = CourierRecipientTag.compute(key, now);
    const yesterday: Uint8Array = CourierRecipientTag.compute(key, now - 86400000);
    const twoDaysAgo: Uint8Array = CourierRecipientTag.compute(key, now - 2 * 86400000);
    t.isTrue(CourierRecipientTag.matches(key, today, now), 'today tag matches');
    t.isTrue(CourierRecipientTag.matches(key, yesterday, now),
      'yesterday tag still matches within the 24h envelope life');
    t.isFalse(CourierRecipientTag.matches(key, twoDaysAgo, now), 'older tags are rejected');
    t.isFalse(CourierRecipientTag.matches(otherKey, today, now), 'another key cannot match');
    t.isFalse(CourierRecipientTag.matches(key, today.subarray(0, 15), now), 'short tag rejected');
    const longTag: Uint8Array = new Uint8Array(17);
    longTag.set(today, 0);
    t.isFalse(CourierRecipientTag.matches(key, longTag, now), 'overlong tag rejected');
  }

  // Envelope: a fresh deposit starts with the initial spray budget.
  {
    const tag: Uint8Array = CourierRecipientTag.compute(key, 1737000000000);
    const envelope: CourierEnvelope = CourierEnvelope.forDeposit(
      ByteUtils.utf8Encode('sealed'), tag, 1737000000000, CourierEnvelopeTier.FAVORITE);
    t.equalNumber(4, envelope.copyBudget, 'fresh deposit carries the initial budget');
    t.equalNumber(CourierEnvelopeTier.FAVORITE, envelope.tier, 'deposit tier is stored');
    t.equalBytes(tag, envelope.recipientTag, 'recipient tag is stored');
    t.equalBytes(ByteUtils.utf8Encode('sealed'), envelope.ciphertext, 'ciphertext is stored');
  }

  // Envelope: validation is fail-closed.
  {
    const tag: Uint8Array = CourierRecipientTag.compute(key, 1737000000000);
    const small: Uint8Array = ByteUtils.utf8Encode('sealed');
    t.throws((): void => {
      new CourierEnvelope(small, tag.subarray(0, 15), 1737000000000, CourierEnvelopeTier.VERIFIED, 4);
    }, 'a 15-byte recipient tag is rejected');
    t.throws((): void => {
      const longTag: Uint8Array = new Uint8Array(17);
      longTag.set(tag, 0);
      new CourierEnvelope(small, longTag, 1737000000000, CourierEnvelopeTier.VERIFIED, 4);
    }, 'a 17-byte recipient tag is rejected');
    t.throws((): void => {
      new CourierEnvelope(new Uint8Array(0), tag, 1737000000000, CourierEnvelopeTier.VERIFIED, 4);
    }, 'an empty ciphertext is rejected');
    t.throws((): void => {
      new CourierEnvelope(filledBytes(16385, 1), tag, 1737000000000, CourierEnvelopeTier.VERIFIED, 4);
    }, 'an oversized ciphertext is rejected');
    t.throws((): void => {
      new CourierEnvelope(small, tag, -1, CourierEnvelopeTier.VERIFIED, 4);
    }, 'a negative creation time is rejected');
    t.throws((): void => {
      new CourierEnvelope(small, tag, 1737000000000, CourierEnvelopeTier.VERIFIED, -1);
    }, 'a negative copy budget is rejected');
    t.throws((): void => {
      new CourierEnvelope(small, tag, 1737000000000, CourierEnvelopeTier.VERIFIED, 9);
    }, 'a copy budget above the cap is rejected');
    const atBounds: CourierEnvelope = new CourierEnvelope(filledBytes(16384, 2), tag, 0,
      CourierEnvelopeTier.VERIFIED, 0);
    t.equalNumber(16384, atBounds.ciphertext.length, 'a 16 KiB ciphertext is accepted at the bound');
    t.equalNumber(0, atBounds.copyBudget, 'a zero copy budget is accepted');
  }

  // Envelope: 24h lifetime boundary.
  {
    const tag: Uint8Array = CourierRecipientTag.compute(key, 1737000000000);
    const envelope: CourierEnvelope = CourierEnvelope.forDeposit(
      ByteUtils.utf8Encode('sealed'), tag, 1737000000000, CourierEnvelopeTier.VERIFIED);
    t.isFalse(envelope.isExpired(1737000000000 + CourierConstants.ENVELOPE_TTL_MS - 1),
      'still alive one millisecond before the TTL');
    t.isTrue(envelope.isExpired(1737000000000 + CourierConstants.ENVELOPE_TTL_MS),
      'expired exactly at the TTL');
  }

  // Envelope: budget top-up is clamped at 8.
  {
    const tag: Uint8Array = CourierRecipientTag.compute(key, 1737000000000);
    const envelope: CourierEnvelope = CourierEnvelope.forDeposit(
      ByteUtils.utf8Encode('sealed'), tag, 1737000000000, CourierEnvelopeTier.VERIFIED);
    t.equalNumber(0, envelope.addCopyBudget(0), 'a zero top-up adds nothing');
    t.equalNumber(0, envelope.addCopyBudget(-3), 'a negative top-up adds nothing');
    t.equalNumber(2, envelope.addCopyBudget(2), 'a top-up within the cap is fully granted');
    t.equalNumber(6, envelope.copyBudget, 'budget is 6 after the top-up');
    t.equalNumber(2, envelope.addCopyBudget(10), 'a top-up beyond the cap is clamped');
    t.equalNumber(8, envelope.copyBudget, 'the budget never exceeds 8');
  }

  // Envelope: copies can be spent until the budget is exhausted.
  {
    const tag: Uint8Array = CourierRecipientTag.compute(key, 1737000000000);
    const envelope: CourierEnvelope = CourierEnvelope.forDeposit(
      ByteUtils.utf8Encode('sealed'), tag, 1737000000000, CourierEnvelopeTier.VERIFIED);
    envelope.addCopyBudget(4);
    let spent: number = 0;
    while (envelope.trySpendCopy()) {
      spent += 1;
    }
    t.equalNumber(8, spent, 'eight copies were spent');
    t.isFalse(envelope.trySpendCopy(), 'an exhausted budget spends nothing');
    t.equalNumber(0, envelope.copyBudget, 'the budget rests at zero');
  }

  // Envelope: spray-and-wait handover hands half the remaining budget.
  {
    const tag: Uint8Array = CourierRecipientTag.compute(key, 1737000000000);
    const envelope: CourierEnvelope = CourierEnvelope.forDeposit(
      ByteUtils.utf8Encode('sealed'), tag, 1737000000000, CourierEnvelopeTier.FAVORITE);
    t.equalNumber(2, envelope.handoffHalfBudget(), 'budget 4 hands 2');
    t.equalNumber(2, envelope.copyBudget, 'budget 4 keeps 2');
    t.equalNumber(1, envelope.handoffHalfBudget(), 'budget 2 hands 1');
    t.equalNumber(0, envelope.handoffHalfBudget(), 'budget 1 hands 0');
    t.equalNumber(1, envelope.copyBudget, 'the last copy is kept');
    const drained: CourierEnvelope = new CourierEnvelope(ByteUtils.utf8Encode('sealed'), tag,
      1737000000000, CourierEnvelopeTier.FAVORITE, 0);
    t.equalNumber(0, drained.handoffHalfBudget(), 'an empty budget hands nothing');
  }

  // Envelope: equality covers every field.
  {
    const tag: Uint8Array = CourierRecipientTag.compute(key, 1737000000000);
    const a: CourierEnvelope = CourierEnvelope.forDeposit(
      ByteUtils.utf8Encode('sealed'), tag, 1737000000000, CourierEnvelopeTier.FAVORITE);
    const same: CourierEnvelope = CourierEnvelope.forDeposit(
      ByteUtils.utf8Encode('sealed'), tag, 1737000000000, CourierEnvelopeTier.FAVORITE);
    t.isTrue(CourierEnvelope.equals(a, same), 'identical envelopes are equal');
    const raised: CourierEnvelope = CourierEnvelope.forDeposit(
      ByteUtils.utf8Encode('sealed'), tag, 1737000000000, CourierEnvelopeTier.FAVORITE);
    raised.addCopyBudget(1);
    t.isFalse(CourierEnvelope.equals(a, raised), 'a budget difference breaks equality');
    const otherTier: CourierEnvelope = CourierEnvelope.forDeposit(
      ByteUtils.utf8Encode('sealed'), tag, 1737000000000, CourierEnvelopeTier.VERIFIED);
    t.isFalse(CourierEnvelope.equals(a, otherTier), 'a tier difference breaks equality');
    const otherTag: CourierEnvelope = CourierEnvelope.forDeposit(
      ByteUtils.utf8Encode('sealed'), CourierRecipientTag.compute(otherKey, 1737000000000),
      1737000000000, CourierEnvelopeTier.FAVORITE);
    t.isFalse(CourierEnvelope.equals(a, otherTag), 'a tag difference breaks equality');
    const otherCiphertext: CourierEnvelope = CourierEnvelope.forDeposit(
      ByteUtils.utf8Encode('sealede'), tag, 1737000000000, CourierEnvelopeTier.FAVORITE);
    t.isFalse(CourierEnvelope.equals(a, otherCiphertext), 'a ciphertext difference breaks equality');
  }

  // Store-forward: the Android skip list - handshakes, noise frames,
  // announces, leaves and broadcasts are never cached.
  {
    const peer: Uint8Array = ByteUtils.hexToBytes('0011223344556677');
    t.isTrue(StoreForwardEntry.isCacheablePacket(makePacket(MessageType.MESSAGE, peer)),
      'a directed MESSAGE is cacheable');
    t.isTrue(StoreForwardEntry.isCacheablePacket(makePacket(MessageType.FRAGMENT, peer)),
      'a FRAGMENT is cacheable');
    t.isTrue(StoreForwardEntry.isCacheablePacket(makePacket(MessageType.FILE_TRANSFER, peer)),
      'a FILE_TRANSFER is cacheable');
    t.isFalse(StoreForwardEntry.isCacheablePacket(makePacket(MessageType.NOISE_HANDSHAKE, peer)),
      'NOISE_HANDSHAKE is never cached');
    t.isFalse(StoreForwardEntry.isCacheablePacket(makePacket(MessageType.NOISE_ENCRYPTED, peer)),
      'NOISE_ENCRYPTED is never cached');
    t.isFalse(StoreForwardEntry.isCacheablePacket(makePacket(MessageType.ANNOUNCE, peer)),
      'ANNOUNCE is never cached');
    t.isFalse(StoreForwardEntry.isCacheablePacket(makePacket(MessageType.LEAVE, peer)),
      'LEAVE is never cached');
    t.isFalse(StoreForwardEntry.isCacheablePacket(makePacket(MessageType.MESSAGE, null)),
      'a packet without a recipient is never cached');
    t.isFalse(StoreForwardEntry.isCacheablePacket(
      makePacket(MessageType.MESSAGE, specialRecipientBroadcast())),
      'a broadcast is never cached');
  }

  // Store-forward: entry fields, recipient identity and the 12h timeout.
  {
    const peer: Uint8Array = ByteUtils.hexToBytes('0011223344556677');
    const packet: BitchatPacket = makePacket(MessageType.MESSAGE, peer);
    const entry: StoreForwardEntry = new StoreForwardEntry(packet, 1737000000000, 'msg-1', false);
    t.equalString('msg-1', entry.messageID, 'the message ID is stored');
    const peerID: string | null = entry.recipientPeerID();
    t.isNotNull(peerID, 'the recipient peer ID is present');
    t.equalString('0011223344556677', peerID === null ? '' : peerID,
      'the recipient peer ID is the hex form of the recipient bytes');
    t.isFalse(entry.isExpired(1737000000000 + StoreForwardConstants.MESSAGE_CACHE_TIMEOUT_MS - 1),
      'a regular entry is still cached one millisecond before the timeout');
    t.isTrue(entry.isExpired(1737000000000 + StoreForwardConstants.MESSAGE_CACHE_TIMEOUT_MS),
      'a regular entry expires at the 12h timeout');
    const favorite: StoreForwardEntry = new StoreForwardEntry(packet, 1737000000000, 'msg-2', true);
    t.isFalse(favorite.isExpired(1737000000000 + StoreForwardConstants.MESSAGE_CACHE_TIMEOUT_MS + 60000),
      'favorite-queued entries are not aged out');
    const anonymous: StoreForwardEntry = new StoreForwardEntry(
      makePacket(MessageType.MESSAGE, null), 1737000000000, 'msg-3', false);
    t.isNull(anonymous.recipientPeerID(), 'a null recipient has no peer ID');
  }
}
