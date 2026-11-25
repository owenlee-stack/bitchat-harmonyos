/**
 * Courier sealed-mail manager (spec US17 / FR-034, plan D11, T063): the
 * deposit side (seal a private message with Noise X and hand it to up to
 * three connected couriers, retrying until then), the carry side (a
 * bounded envelope pool with per-depositor trust quotas), the
 * spray-and-wait handoff between couriers, the handover on recipient
 * announces (direct -> deliver over the active link and remove, relayed
 * -> one targeted-flood copy per 10 minutes, original kept) and the
 * recipient side (rotation-tag match, decrypt, blocked-sender
 * decrypt-discard, message-ID dedupe).
 *
 * Pool policy: a carrier holds at most POOL_SLOTS(40) envelopes, of which
 * at most POOL_USABLE_SLOTS(20) may be verified-tier; a mutual-favorite
 * depositor may hold 5 slots, an announce-verified depositor 2; favorite
 * mail is never evicted, and overflow evicts the oldest verified-tier
 * envelope first (spec US17 acceptance scenario 4).
 *
 * Trust is evaluated against the DIRECT counterparty: the wire envelope
 * stays opaque (16-byte rotation tag + ciphertext only, spec US17
 * scenario 3), so an envelope relayed through a second courier is
 * quota'd against the courier that handed it over.
 *
 * Deliberately pure ArkTS (no @kit imports): clock, RNG, link send,
 * targeted flood, trust/block/dedupe policy and the encrypted
 * persistence are injected, so the contract tests run on the host
 * harness; the device wiring (T065) passes the live mesh link, the
 * favorites table, the seen-set and the data-layer encrypted store
 * (plan D7/D8: carried mail, budgets and spray history survive restarts).
 */
import { ByteUtils, ByteReader, ByteWriter } from '../../common/ByteUtils';
import { CourierConstants } from '../../common/ProtocolConstants';
import { CourierEnvelope, CourierEnvelopeTier, CourierRecipientTag } from '../../model/CourierModels';
import { PrivateMessagePacket } from '../../model/IdentityModels';
import { NoiseXSeal, NoiseXSealOpenResult } from '../noise/NoiseXSeal';

/**
 * Wire envelope exchanged between peers (iOS courier wire type 0x04
 * payload): version(1) | recipientTag(16) | copyBudget(1) |
 * createdAt u64be(8) | ciphertext(1..16384). No sender, recipient or
 * tier travels outside the ciphertext.
 */
export class CourierEnvelopeWireData {
  readonly recipientTag: Uint8Array;
  readonly copyBudget: number;
  readonly createdAt: number;
  readonly ciphertext: Uint8Array;

  constructor(recipientTag: Uint8Array, copyBudget: number, createdAt: number,
    ciphertext: Uint8Array) {
    this.recipientTag = recipientTag;
    this.copyBudget = copyBudget;
    this.createdAt = createdAt;
    this.ciphertext = ciphertext;
  }
}

export class CourierEnvelopeWire {
  static readonly VERSION: number = 0x01;
  static readonly HEADER_BYTES: number = 26;

  static encode(ciphertext: Uint8Array, recipientTag: Uint8Array, createdAt: number,
    copyBudget: number): Uint8Array {
    if (recipientTag.length !== CourierConstants.RECIPIENT_TAG_SIZE) {
      throw new Error('Courier wire recipient tag must be 16 bytes');
    }
    if (ciphertext.length === 0 || ciphertext.length > CourierConstants.ENVELOPE_MAX_BYTES) {
      throw new Error('Courier wire ciphertext must be 1..16384 bytes');
    }
    if (createdAt < 0) {
      throw new Error('Courier wire creation time must be non-negative epoch milliseconds');
    }
    if (copyBudget < 0 || copyBudget > CourierConstants.COPY_BUDGET_MAX) {
      throw new Error('Courier wire copy budget must be between 0 and 8');
    }
    const writer: ByteWriter =
      new ByteWriter(CourierEnvelopeWire.HEADER_BYTES + ciphertext.length);
    writer.putByte(CourierEnvelopeWire.VERSION);
    writer.putBytes(recipientTag);
    writer.putByte(copyBudget);
    const createdAtBytes: Uint8Array = new Uint8Array(8);
    let rest: number = createdAt;
    for (let i: number = 7; i >= 0; i--) {
      createdAtBytes[i] = rest % 256;
      rest = Math.floor(rest / 256);
    }
    writer.putBytes(createdAtBytes);
    writer.putBytes(ciphertext);
    return writer.toUint8Array();
  }

  static decode(wire: Uint8Array): CourierEnvelopeWireData | null {
    if (wire.length <= CourierEnvelopeWire.HEADER_BYTES) {
      return null;
    }
    try {
      const reader: ByteReader = new ByteReader(wire);
      if (reader.getByte() !== CourierEnvelopeWire.VERSION) {
        return null;
      }
      const recipientTag: Uint8Array = reader.getBytes(CourierConstants.RECIPIENT_TAG_SIZE);
      const copyBudget: number = reader.getByte();
      if (copyBudget > CourierConstants.COPY_BUDGET_MAX) {
        return null;
      }
      const createdAt: number = reader.getU64BE();
      const ciphertext: Uint8Array = reader.getBytes(reader.remaining());
      if (ciphertext.length === 0 || ciphertext.length > CourierConstants.ENVELOPE_MAX_BYTES) {
        return null;
      }
      return new CourierEnvelopeWireData(recipientTag, copyBudget, createdAt, ciphertext);
    } catch (e) {
      return null;
    }
  }
}

/** Outcome of offering a sealed envelope to its addressee. */
export enum CourierOpenStatus {
  /** The rotation tag does not address the local static key. */
  NOT_ADDRESSED = 0,
  /** Undecodable wire or a ciphertext that fails Noise X. */
  MALFORMED = 1,
  /** Decrypted, but the sender is blocked - the caller must discard. */
  BLOCKED = 2,
  /** Decrypted, but the message ID was already seen - discard. */
  DUPLICATE = 3,
  /** Decrypted fresh mail, ready for the conversation layer. */
  OPENED = 4
}

export class CourierOpenedMail {
  readonly status: CourierOpenStatus;
  readonly payload: Uint8Array;
  readonly messageID: string | null;
  readonly senderStaticPublicKey: Uint8Array | null;

  constructor(status: CourierOpenStatus, payload: Uint8Array, messageID: string | null,
    senderStaticPublicKey: Uint8Array | null) {
    this.status = status;
    this.payload = payload;
    this.messageID = messageID;
    this.senderStaticPublicKey = senderStaticPublicKey;
  }

  static notAddressed(): CourierOpenedMail {
    return new CourierOpenedMail(CourierOpenStatus.NOT_ADDRESSED, new Uint8Array(0),
      null, null);
  }

  static malformed(): CourierOpenedMail {
    return new CourierOpenedMail(CourierOpenStatus.MALFORMED, new Uint8Array(0),
      null, null);
  }
}

/** One carried envelope as persisted (wire bytes carry the current budget). */
export class CarriedMailSnapshot {
  readonly wireBytes: Uint8Array;
  readonly tier: CourierEnvelopeTier;
  readonly depositorPeerID: string;
  readonly receivedAtMs: number;
  readonly lastRelayedAttemptMs: number;
  readonly sprayedTo: string[];

  constructor(wireBytes: Uint8Array, tier: CourierEnvelopeTier, depositorPeerID: string,
    receivedAtMs: number, lastRelayedAttemptMs: number, sprayedTo: string[]) {
    this.wireBytes = wireBytes;
    this.tier = tier;
    this.depositorPeerID = depositorPeerID;
    this.receivedAtMs = receivedAtMs;
    this.lastRelayedAttemptMs = lastRelayedAttemptMs;
    this.sprayedTo = sprayedTo;
  }
}

export class CourierPoolSnapshot {
  readonly entries: CarriedMailSnapshot[];

  constructor(entries: CarriedMailSnapshot[]) {
    this.entries = entries;
  }
}

/**
 * Encrypted persistence of the carried pool (plan D7/D8): the device
 * backend encrypts the snapshot at rest; the manager only serializes.
 */
export interface CourierPersistence {
  savePool(snapshot: CourierPoolSnapshot): void;
  loadPool(): CourierPoolSnapshot | null;
}

/** Injected collaborators (device wiring lands with the T065 integration). */
export interface CourierManagerDeps {
  nowMs: () => number;
  generateEphemeralPrivateKey: () => Uint8Array;
  localStaticPrivateKey: () => Uint8Array;
  localStaticPublicKey: () => Uint8Array;
  /** Peer IDs of connected couriers eligible to carry mail. */
  courierCandidates: () => string[];
  /** Send one wire envelope over an active link. */
  sendToPeer: (peerID: string, wire: Uint8Array) => boolean;
  /** Send one copy toward a peer via targeted flooding (relayed announce). */
  sendFloodToward: (towardPeerID: string, wire: Uint8Array) => boolean;
  isMutualFavorite: (peerID: string) => boolean;
  isVerifiedPeer: (peerID: string) => boolean;
  isBlockedSender: (senderStaticPublicKey: Uint8Array) => boolean;
  hasSeenMessageID: (messageID: string) => boolean;
  persistence: CourierPersistence;
  onDeposited: (envelopeID: string, courierPeerID: string) => void;
  onHandoverDelivered: (envelopeID: string, recipientPeerID: string) => void;
  onMailOpened: (messageID: string, senderStaticPublicKeyHex: string) => void;
}

/** One outbound envelope still short of the 3-courier deposit target. */
class PendingDeposit {
  readonly envelopeID: string;
  readonly wireBytes: Uint8Array;
  readonly createdAt: number;
  readonly depositedTo: string[] = [];

  constructor(envelopeID: string, wireBytes: Uint8Array, createdAt: number) {
    this.envelopeID = envelopeID;
    this.wireBytes = wireBytes;
    this.createdAt = createdAt;
  }
}

/** One envelope carried in the local pool, with its custody bookkeeping. */
class CarriedEntry {
  readonly envelopeID: string;
  readonly envelope: CourierEnvelope;
  readonly depositorPeerID: string;
  readonly receivedAtMs: number;
  lastRelayedAttemptMs: number;
  readonly sprayedTo: Set<string>;

  constructor(envelopeID: string, envelope: CourierEnvelope, depositorPeerID: string,
    receivedAtMs: number, lastRelayedAttemptMs: number, sprayedTo: Set<string>) {
    this.envelopeID = envelopeID;
    this.envelope = envelope;
    this.depositorPeerID = depositorPeerID;
    this.receivedAtMs = receivedAtMs;
    this.lastRelayedAttemptMs = lastRelayedAttemptMs;
    this.sprayedTo = sprayedTo;
  }
}

export class CourierManager {
  private readonly deps: CourierManagerDeps;
  private readonly pendingDeposits: Map<string, PendingDeposit> = new Map();
  private readonly pool: Map<string, CarriedEntry> = new Map();

  constructor(deps: CourierManagerDeps) {
    this.deps = deps;
  }

  /** Restore the carried pool (mail, budgets, spray history, throttles). */
  initialize(): void {
    const snapshot: CourierPoolSnapshot | null = this.deps.persistence.loadPool();
    if (snapshot === null) {
      return;
    }
    const now: number = this.deps.nowMs();
    for (let i: number = 0; i < snapshot.entries.length; i++) {
      const saved: CarriedMailSnapshot = snapshot.entries[i];
      const data: CourierEnvelopeWireData | null = CourierEnvelopeWire.decode(saved.wireBytes);
      if (data === null) {
        continue;
      }
      const envelope: CourierEnvelope = new CourierEnvelope(data.ciphertext, data.recipientTag,
        data.createdAt, saved.tier, data.copyBudget);
      if (envelope.isExpired(now)) {
        continue;
      }
      const sprayedTo: Set<string> = new Set<string>();
      for (let j: number = 0; j < saved.sprayedTo.length; j++) {
        sprayedTo.add(saved.sprayedTo[j]);
      }
      const envelopeID: string = CourierManager.envelopeID(data.ciphertext);
      this.pool.set(envelopeID, new CarriedEntry(envelopeID, envelope, saved.depositorPeerID,
        saved.receivedAtMs, saved.lastRelayedAttemptMs, sprayedTo));
    }
  }

  /**
   * Seal a private message with Noise X, tag it for the recipient and
   * deposit it with up to 3 connected couriers; envelopes that cannot
   * reach 3 couriers stay pending for the retry trigger (T065 wiring).
   * Returns the envelope ID, or null when the payload does not fit.
   */
  sealAndDeposit(payload: Uint8Array, recipientStaticPublic: Uint8Array): string | null {
    if (payload.length === 0 ||
      NoiseXSeal.sealedSize(payload.length) > CourierConstants.ENVELOPE_MAX_BYTES) {
      return null;
    }
    const now: number = this.deps.nowMs();
    let ciphertext: Uint8Array;
    try {
      ciphertext = NoiseXSeal.seal(payload, this.deps.localStaticPrivateKey(),
        recipientStaticPublic, this.deps.generateEphemeralPrivateKey, null);
    } catch (e) {
      return null;
    }
    const recipientTag: Uint8Array = CourierRecipientTag.compute(recipientStaticPublic, now);
    const wire: Uint8Array = CourierEnvelopeWire.encode(ciphertext, recipientTag, now,
      CourierConstants.COPY_BUDGET_INITIAL);
    const envelopeID: string = CourierManager.envelopeID(ciphertext);
    this.pendingDeposits.set(envelopeID, new PendingDeposit(envelopeID, wire, now));
    this.retryPendingDeposits();
    return envelopeID;
  }

  /**
   * Try to bring every pending deposit to 3 couriers; a new qualified
   * courier connection (T065) calls this. Returns the number of newly
   * accepted courier deposits.
   */
  retryPendingDeposits(): number {
    const now: number = this.deps.nowMs();
    this.sweepExpiredAt(now);
    const queue: PendingDeposit[] = [];
    this.pendingDeposits.forEach((pending: PendingDeposit) => {
      queue.push(pending);
    });
    let sent: number = 0;
    for (let i: number = 0; i < queue.length; i++) {
      const pending: PendingDeposit = queue[i];
      if (this.pendingDeposits.get(pending.envelopeID) !== pending) {
        continue;
      }
      const candidates: string[] = this.deps.courierCandidates();
      for (let j: number = 0; j < candidates.length; j++) {
        if (pending.depositedTo.length >= CourierConstants.DEPOSIT_COURIER_TARGET) {
          break;
        }
        const courier: string = candidates[j];
        if (pending.depositedTo.indexOf(courier) >= 0) {
          continue;
        }
        let accepted: boolean = false;
        try {
          accepted = this.deps.sendToPeer(courier, pending.wireBytes);
        } catch (e) {
          accepted = false;
        }
        if (!accepted) {
          continue;
        }
        pending.depositedTo.push(courier);
        sent += 1;
        this.deps.onDeposited(pending.envelopeID, courier);
      }
      if (pending.depositedTo.length >= CourierConstants.DEPOSIT_COURIER_TARGET) {
        this.pendingDeposits.delete(pending.envelopeID);
      }
    }
    return sent;
  }

  /**
   * Carrier side: accept a wire envelope from a directly connected peer
   * into the bounded pool (favorite quota 5 / verified quota 2 per
   * depositor, 20 verified-tier and 40 total slots, favorite mail never
   * evicted, overflow evicts the oldest verified-tier envelope first).
   * Re-offers of an already-carried envelope are idempotent and only
   * raise the carried budget.
   */
  receiveEnvelope(fromPeerID: string, wire: Uint8Array): boolean {
    const data: CourierEnvelopeWireData | null = CourierEnvelopeWire.decode(wire);
    if (data === null) {
      return false;
    }
    const now: number = this.deps.nowMs();
    this.sweepExpiredAt(now);
    const favorite: boolean = this.deps.isMutualFavorite(fromPeerID);
    if (!favorite && !this.deps.isVerifiedPeer(fromPeerID)) {
      return false;
    }
    const envelopeID: string = CourierManager.envelopeID(data.ciphertext);
    const existing: CarriedEntry | undefined = this.pool.get(envelopeID);
    if (existing !== undefined) {
      if (data.copyBudget > existing.envelope.copyBudget) {
        existing.envelope.copyBudget = data.copyBudget;
        this.persist();
      }
      return true;
    }
    const tier: CourierEnvelopeTier =
      favorite ? CourierEnvelopeTier.FAVORITE : CourierEnvelopeTier.VERIFIED;
    const quota: number = favorite ?
      CourierConstants.QUOTA_MUTUAL_FAVORITE : CourierConstants.QUOTA_VERIFIED;
    if (this.depositedByCount(fromPeerID) >= quota) {
      return false;
    }
    const envelope: CourierEnvelope = new CourierEnvelope(data.ciphertext, data.recipientTag,
      data.createdAt, tier, data.copyBudget);
    if (envelope.isExpired(now)) {
      return false;
    }
    if (tier === CourierEnvelopeTier.VERIFIED) {
      while (this.verifiedCount() >= CourierConstants.POOL_USABLE_SLOTS) {
        if (!this.evictOldestVerified()) {
          return false;
        }
      }
    }
    while (this.pool.size >= CourierConstants.POOL_SLOTS) {
      if (!this.evictOldestVerified()) {
        return false;
      }
    }
    this.pool.set(envelopeID, new CarriedEntry(envelopeID, envelope, fromPeerID, now, 0,
      new Set<string>()));
    this.persist();
    return true;
  }

  /**
   * Handover on a verified DIRECT announce from the recipient: matching
   * envelopes are delivered over the active link and removed from the
   * pool. Returns the number delivered.
   */
  onDirectAnnounce(announcerPeerID: string, announcerStaticKey: Uint8Array): number {
    const now: number = this.deps.nowMs();
    this.sweepExpiredAt(now);
    const matched: string[] = this.collectMatching(announcerStaticKey, now);
    let delivered: number = 0;
    for (let i: number = 0; i < matched.length; i++) {
      const entry: CarriedEntry | undefined = this.pool.get(matched[i]);
      if (entry === undefined) {
        continue;
      }
      const wire: Uint8Array = CourierEnvelopeWire.encode(entry.envelope.ciphertext,
        entry.envelope.recipientTag, entry.envelope.createdAt, entry.envelope.copyBudget);
      let accepted: boolean = false;
      try {
        accepted = this.deps.sendToPeer(announcerPeerID, wire);
      } catch (e) {
        accepted = false;
      }
      if (!accepted) {
        continue;
      }
      this.pool.delete(entry.envelopeID);
      delivered += 1;
      this.deps.onHandoverDelivered(entry.envelopeID, announcerPeerID);
    }
    if (delivered > 0) {
      this.persist();
    }
    return delivered;
  }

  /**
   * Handover on a verified RELAYED announce: one targeted-flood copy is
   * sent toward the recipient, the original stays in the pool, at most
   * once per envelope per 10 minutes. Returns the number of copies sent.
   */
  onRelayedAnnounce(announcerPeerID: string, announcerStaticKey: Uint8Array): number {
    const now: number = this.deps.nowMs();
    this.sweepExpiredAt(now);
    const matched: string[] = this.collectMatching(announcerStaticKey, now);
    let attempted: number = 0;
    let changed: boolean = false;
    for (let i: number = 0; i < matched.length; i++) {
      const entry: CarriedEntry | undefined = this.pool.get(matched[i]);
      if (entry === undefined) {
        continue;
      }
      if (entry.lastRelayedAttemptMs > 0 &&
        now - entry.lastRelayedAttemptMs < CourierConstants.RELAYED_ANNOUNCE_THROTTLE_MS) {
        continue;
      }
      const wire: Uint8Array = CourierEnvelopeWire.encode(entry.envelope.ciphertext,
        entry.envelope.recipientTag, entry.envelope.createdAt, entry.envelope.copyBudget);
      let accepted: boolean = false;
      try {
        accepted = this.deps.sendFloodToward(announcerPeerID, wire);
      } catch (e) {
        accepted = false;
      }
      if (!accepted) {
        continue;
      }
      entry.lastRelayedAttemptMs = now;
      attempted += 1;
      changed = true;
    }
    if (changed) {
      this.persist();
    }
    return attempted;
  }

  /**
   * Spray-and-wait: hand half of each remaining budget to another
   * courier met in passing (each courier at most once per envelope).
   * Returns the number of envelopes handed over.
   */
  sprayTo(otherCourierPeerID: string): number {
    const now: number = this.deps.nowMs();
    this.sweepExpiredAt(now);
    const ids: string[] = [];
    this.pool.forEach((entry: CarriedEntry, envelopeID: string) => {
      ids.push(envelopeID);
    });
    let handed: number = 0;
    let changed: boolean = false;
    for (let i: number = 0; i < ids.length; i++) {
      const entry: CarriedEntry | undefined = this.pool.get(ids[i]);
      if (entry === undefined) {
        continue;
      }
      if (entry.envelope.copyBudget <= 0 || entry.sprayedTo.has(otherCourierPeerID)) {
        continue;
      }
      const handedBudget: number = entry.envelope.handoffHalfBudget();
      if (handedBudget === 0) {
        continue;
      }
      const wire: Uint8Array = CourierEnvelopeWire.encode(entry.envelope.ciphertext,
        entry.envelope.recipientTag, entry.envelope.createdAt, handedBudget);
      let accepted: boolean = false;
      try {
        accepted = this.deps.sendToPeer(otherCourierPeerID, wire);
      } catch (e) {
        accepted = false;
      }
      if (accepted) {
        entry.sprayedTo.add(otherCourierPeerID);
        handed += 1;
        changed = true;
      } else {
        entry.envelope.addCopyBudget(handedBudget);
      }
    }
    if (changed) {
      this.persist();
    }
    return handed;
  }

  /**
   * Recipient side: offer a wire envelope to the local identity. The
   * rotation tag must address the local static key; the ciphertext is
   * then opened with Noise X, blocked senders are discarded after
   * decryption, and already-seen message IDs are reported as duplicates.
   */
  receiveSealedMail(wire: Uint8Array): CourierOpenedMail {
    const data: CourierEnvelopeWireData | null = CourierEnvelopeWire.decode(wire);
    if (data === null) {
      return CourierOpenedMail.malformed();
    }
    if (!CourierRecipientTag.matches(this.deps.localStaticPublicKey(), data.recipientTag,
      this.deps.nowMs())) {
      return CourierOpenedMail.notAddressed();
    }
    let opened: NoiseXSealOpenResult | null = null;
    try {
      opened = NoiseXSeal.open(data.ciphertext, this.deps.localStaticPrivateKey(), null);
    } catch (e) {
      return CourierOpenedMail.malformed();
    }
    if (opened === null) {
      return CourierOpenedMail.malformed();
    }
    if (this.deps.isBlockedSender(opened.senderStaticPublicKey)) {
      return new CourierOpenedMail(CourierOpenStatus.BLOCKED, opened.payload, null,
        opened.senderStaticPublicKey);
    }
    const parsed: PrivateMessagePacket | null = PrivateMessagePacket.decode(opened.payload);
    const messageID: string | null = parsed === null ? null : parsed.messageID;
    if (messageID !== null && this.deps.hasSeenMessageID(messageID)) {
      return new CourierOpenedMail(CourierOpenStatus.DUPLICATE, opened.payload, messageID,
        opened.senderStaticPublicKey);
    }
    this.deps.onMailOpened(messageID === null ? '' : messageID,
      ByteUtils.bytesToHex(opened.senderStaticPublicKey));
    return new CourierOpenedMail(CourierOpenStatus.OPENED, opened.payload, messageID,
      opened.senderStaticPublicKey);
  }

  /** Drop carried and pending envelopes past the 24h lifetime. */
  sweepExpired(): number {
    return this.sweepExpiredAt(this.deps.nowMs());
  }

  poolSize(): number {
    return this.pool.size;
  }

  pendingDepositCount(): number {
    return this.pendingDeposits.size;
  }

  carriedEnvelopeIDs(): string[] {
    const ids: string[] = [];
    this.pool.forEach((entry: CarriedEntry, envelopeID: string) => {
      ids.push(envelopeID);
    });
    return ids;
  }

  static envelopeID(ciphertext: Uint8Array): string {
    return ByteUtils.bytesToHex(ByteUtils.sha256(ciphertext));
  }

  private sweepExpiredAt(now: number): number {
    const expiredIDs: string[] = [];
    this.pool.forEach((entry: CarriedEntry) => {
      if (entry.envelope.isExpired(now)) {
        expiredIDs.push(entry.envelopeID);
      }
    });
    for (let i: number = 0; i < expiredIDs.length; i++) {
      this.pool.delete(expiredIDs[i]);
    }
    const expiredPending: string[] = [];
    this.pendingDeposits.forEach((pending: PendingDeposit) => {
      if (now - pending.createdAt >= CourierConstants.ENVELOPE_TTL_MS) {
        expiredPending.push(pending.envelopeID);
      }
    });
    for (let i: number = 0; i < expiredPending.length; i++) {
      this.pendingDeposits.delete(expiredPending[i]);
    }
    if (expiredIDs.length > 0) {
      this.persist();
    }
    return expiredIDs.length;
  }

  private collectMatching(staticKey: Uint8Array, now: number): string[] {
    const matched: string[] = [];
    this.pool.forEach((entry: CarriedEntry, envelopeID: string) => {
      if (CourierRecipientTag.matches(staticKey, entry.envelope.recipientTag, now)) {
        matched.push(envelopeID);
      }
    });
    return matched;
  }

  private depositedByCount(depositorPeerID: string): number {
    let count: number = 0;
    this.pool.forEach((entry: CarriedEntry) => {
      if (entry.depositorPeerID === depositorPeerID) {
        count += 1;
      }
    });
    return count;
  }

  private verifiedCount(): number {
    let count: number = 0;
    this.pool.forEach((entry: CarriedEntry) => {
      if (entry.envelope.tier === CourierEnvelopeTier.VERIFIED) {
        count += 1;
      }
    });
    return count;
  }

  /** Evict the oldest verified-tier envelope; favorites are never victims. */
  private evictOldestVerified(): boolean {
    let victim: CarriedEntry | null = null;
    this.pool.forEach((entry: CarriedEntry) => {
      if (entry.envelope.tier !== CourierEnvelopeTier.VERIFIED) {
        return;
      }
      if (victim === null || CourierManager.isOlder(entry, victim)) {
        victim = entry;
      }
    });
    if (victim === null) {
      return false;
    }
    const target: CarriedEntry = victim;
    this.pool.delete(target.envelopeID);
    return true;
  }

  private static isOlder(a: CarriedEntry, b: CarriedEntry): boolean {
    if (a.receivedAtMs !== b.receivedAtMs) {
      return a.receivedAtMs < b.receivedAtMs;
    }
    if (a.envelope.createdAt !== b.envelope.createdAt) {
      return a.envelope.createdAt < b.envelope.createdAt;
    }
    return a.envelopeID < b.envelopeID;
  }

  private persist(): void {
    const entries: CarriedMailSnapshot[] = [];
    this.pool.forEach((entry: CarriedEntry) => {
      const sprayedTo: string[] = [];
      entry.sprayedTo.forEach((peerID: string) => {
        sprayedTo.push(peerID);
      });
      entries.push(new CarriedMailSnapshot(
        CourierEnvelopeWire.encode(entry.envelope.ciphertext, entry.envelope.recipientTag,
          entry.envelope.createdAt, entry.envelope.copyBudget),
        entry.envelope.tier, entry.depositorPeerID, entry.receivedAtMs,
        entry.lastRelayedAttemptMs, sprayedTo));
    });
    this.deps.persistence.savePool(new CourierPoolSnapshot(entries));
  }
}
