/**
 * Contract vectors for the courier manager (T063, spec US17 / FR-034,
 * plan D11): the opaque wire-envelope codec, Noise X deposit with the
 * 3-courier retry target, the bounded carry pool (favorite 5 / verified 2
 * per depositor, 20 verified-tier and 40 total slots, favorite mail never
 * evicted, overflow evicting the oldest verified-tier envelope first),
 * spray-and-wait handoffs with rollback, direct/relayed handover
 * semantics (deliver-and-remove vs one throttled targeted-flood copy),
 * the recipient side (rotation-tag match, decrypt, blocked-sender
 * decrypt-discard, message-ID dedupe) and the encrypted persistence
 * round-trip of carried mail, budgets, spray history and throttles.
 */
import { ContractAssert } from './ContractAssert';
import { ByteUtils } from '../../main/ets/common/ByteUtils';
import { CourierConstants } from '../../main/ets/common/ProtocolConstants';
import { CourierRecipientTag, CourierEnvelopeTier } from '../../main/ets/model/CourierModels';
import { PrivateMessagePacket } from '../../main/ets/model/IdentityModels';
import { Curve25519 } from '../../main/ets/service/noise/Curve25519';
import { NoiseXSeal, NoiseXSealOpenResult } from '../../main/ets/service/noise/NoiseXSeal';
import {
  CourierManager,
  CourierEnvelopeWire,
  CourierEnvelopeWireData,
  CourierOpenStatus,
  CourierOpenedMail,
  CourierPoolSnapshot
} from '../../main/ets/service/mesh/CourierManager';
import { CourierPersistence } from '../../main/ets/service/mesh/CourierManager';
import { CourierManagerDeps } from '../../main/ets/service/mesh/CourierManager';

const NOW: number = 1737000000000;

const ALICE_PRIVATE_HEX: string =
  '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20';
const BOB_PRIVATE_HEX: string =
  '2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40';
const CAROL_PRIVATE_HEX: string =
  '4142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60';

function hexToBytes(hex: string): Uint8Array {
  return ByteUtils.hexToBytes(hex);
}

function alicePublic(): Uint8Array {
  return Curve25519.publicKeyFromPrivateKey(hexToBytes(ALICE_PRIVATE_HEX));
}

function bobPublic(): Uint8Array {
  return Curve25519.publicKeyFromPrivateKey(hexToBytes(BOB_PRIVATE_HEX));
}

function carolPublic(): Uint8Array {
  return Curve25519.publicKeyFromPrivateKey(hexToBytes(CAROL_PRIVATE_HEX));
}

/** Deterministic direct-seal ephemeral for recipient-side vectors. */
function fixedEphemeral(): Uint8Array {
  return hexToBytes('606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f40');
}

function messagePayload(messageID: string, content: string): Uint8Array {
  const packet: PrivateMessagePacket = new PrivateMessagePacket(messageID, content);
  const encoded: Uint8Array | null = packet.encode();
  return encoded === null ? new Uint8Array(0) : encoded;
}

/** Deterministic 100-byte pseudo-ciphertext envelope wire for pool tests. */
function makeWire(recipientStaticPublic: Uint8Array, createdAt: number, budget: number,
  seed: number): Uint8Array {
  const ciphertext: Uint8Array = new Uint8Array(100);
  for (let i: number = 0; i < ciphertext.length; i++) {
    ciphertext[i] = 0x55;
  }
  ciphertext[0] = seed % 256;
  ciphertext[99] = (seed / 256) % 256;
  return CourierEnvelopeWire.encode(ciphertext,
    CourierRecipientTag.compute(recipientStaticPublic, createdAt), createdAt, budget);
}

function wireEnvelopeID(wire: Uint8Array): string {
  const data: CourierEnvelopeWireData | null = CourierEnvelopeWire.decode(wire);
  return data === null ? '' : CourierManager.envelopeID(data.ciphertext);
}

function decodedBudget(wire: Uint8Array): number {
  const data: CourierEnvelopeWireData | null = CourierEnvelopeWire.decode(wire);
  return data === null ? -1 : data.copyBudget;
}

class SendRecord {
  readonly peerID: string;
  readonly wire: Uint8Array;

  constructor(peerID: string, wire: Uint8Array) {
    this.peerID = peerID;
    this.wire = wire;
  }
}

class MemoryCourierPersistence implements CourierPersistence {
  snapshot: CourierPoolSnapshot | null = null;
  saveCount: number = 0;

  savePool(snapshot: CourierPoolSnapshot): void {
    this.snapshot = snapshot;
    this.saveCount += 1;
  }

  loadPool(): CourierPoolSnapshot | null {
    return this.snapshot;
  }
}

class FakeCourierDeps implements CourierManagerDeps {
  now: number = NOW;
  ephemeralCounter: number = 0;
  candidates: string[] = [];
  directSends: SendRecord[] = [];
  floods: SendRecord[] = [];
  failSendTo: Set<string> = new Set<string>();
  throwSendTo: Set<string> = new Set<string>();
  failFlood: boolean = false;
  favorites: Set<string> = new Set<string>();
  verified: Set<string> = new Set<string>();
  blockedSenderHexes: Set<string> = new Set<string>();
  seenMessageIDs: Set<string> = new Set<string>();
  depositedEvents: string[] = [];
  handoverEvents: string[] = [];
  openedEvents: string[] = [];
  readonly persistence: MemoryCourierPersistence = new MemoryCourierPersistence();
  private readonly localStaticPrivateKeyBytes: Uint8Array;
  private readonly localStaticPublicKeyBytes: Uint8Array;

  constructor(localStaticPrivateKey: Uint8Array) {
    this.localStaticPrivateKeyBytes = localStaticPrivateKey;
    this.localStaticPublicKeyBytes = Curve25519.publicKeyFromPrivateKey(localStaticPrivateKey);
  }

  nowMs(): number {
    return this.now;
  }

  /** Bound arrow: the manager detaches this reference into NoiseXSeal.seal. */
  readonly generateEphemeralPrivateKey: () => Uint8Array = (): Uint8Array => {
    this.ephemeralCounter += 1;
    const key: Uint8Array = hexToBytes(
      '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f');
    key[30] = this.ephemeralCounter % 256;
    key[31] = 0x40;
    return key;
  };

  localStaticPrivateKey(): Uint8Array {
    return this.localStaticPrivateKeyBytes;
  }

  localStaticPublicKey(): Uint8Array {
    return this.localStaticPublicKeyBytes;
  }

  courierCandidates(): string[] {
    return this.candidates;
  }

  sendToPeer(peerID: string, wire: Uint8Array): boolean {
    if (this.throwSendTo.has(peerID)) {
      throw new Error('link down');
    }
    if (this.failSendTo.has(peerID)) {
      return false;
    }
    this.directSends.push(new SendRecord(peerID, wire));
    return true;
  }

  sendFloodToward(towardPeerID: string, wire: Uint8Array): boolean {
    if (this.failFlood) {
      return false;
    }
    this.floods.push(new SendRecord(towardPeerID, wire));
    return true;
  }

  isMutualFavorite(peerID: string): boolean {
    return this.favorites.has(peerID);
  }

  isVerifiedPeer(peerID: string): boolean {
    return this.verified.has(peerID);
  }

  isBlockedSender(senderStaticPublicKey: Uint8Array): boolean {
    return this.blockedSenderHexes.has(ByteUtils.bytesToHex(senderStaticPublicKey));
  }

  hasSeenMessageID(messageID: string): boolean {
    return this.seenMessageIDs.has(messageID);
  }

  onDeposited(envelopeID: string, courierPeerID: string): void {
    this.depositedEvents.push(envelopeID + '@' + courierPeerID);
  }

  onHandoverDelivered(envelopeID: string, recipientPeerID: string): void {
    this.handoverEvents.push(envelopeID + '@' + recipientPeerID);
  }

  onMailOpened(messageID: string, senderStaticPublicKeyHex: string): void {
    this.openedEvents.push(messageID + '@' + senderStaticPublicKeyHex);
  }
}

export function runCourierManagerContractTests(t: ContractAssert): void {
  const bobPublic_ = bobPublic();

  // Wire codec: round-trip of every field.
  {
    const tag: Uint8Array = CourierRecipientTag.compute(bobPublic_, NOW);
    const ciphertext: Uint8Array = ByteUtils.utf8Encode('sealed-mail');
    const wire: Uint8Array = CourierEnvelopeWire.encode(ciphertext, tag, NOW, 4);
    t.equalNumber(37, wire.length, 'wire length is the 26-byte header plus ciphertext');
    const data: CourierEnvelopeWireData | null = CourierEnvelopeWire.decode(wire);
    t.isNotNull(data, 'a well-formed wire decodes');
    if (data !== null) {
      t.equalBytes(tag, data.recipientTag, 'the recipient tag round-trips');
      t.equalNumber(4, data.copyBudget, 'the copy budget round-trips');
      t.equalNumber(NOW, data.createdAt, 'the u64be creation time round-trips');
      t.equalBytes(ciphertext, data.ciphertext, 'the ciphertext round-trips');
    }
  }

  // Wire codec: fail-closed decode.
  {
    const tag: Uint8Array = CourierRecipientTag.compute(bobPublic_, NOW);
    const ciphertext: Uint8Array = ByteUtils.utf8Encode('sealed-mail');
    const wire: Uint8Array = CourierEnvelopeWire.encode(ciphertext, tag, NOW, 4);
    t.isNull(CourierEnvelopeWire.decode(wire.subarray(0, 26)),
      'a header-only wire has no ciphertext and is rejected');
    const badVersion: Uint8Array = wire.slice(0);
    badVersion[0] = 0x02;
    t.isNull(CourierEnvelopeWire.decode(badVersion), 'an unknown wire version is rejected');
    const badBudget: Uint8Array = wire.slice(0);
    badBudget[17] = 9;
    t.isNull(CourierEnvelopeWire.decode(badBudget), 'a copy budget above 8 is rejected');
    const longCiphertext: Uint8Array = new Uint8Array(16385);
    const longWire: Uint8Array = ByteUtils.concat(
      CourierEnvelopeWire.encode(ciphertext, tag, NOW, 4).subarray(0, 26), longCiphertext);
    t.isNull(CourierEnvelopeWire.decode(longWire), 'an oversized ciphertext is rejected');
    t.throws((): void => {
      CourierEnvelopeWire.encode(new Uint8Array(16385), tag, NOW, 4);
    }, 'encoding an oversized ciphertext throws');
    t.throws((): void => {
      CourierEnvelopeWire.encode(ciphertext, tag.subarray(0, 15), NOW, 4);
    }, 'encoding a 15-byte tag throws');
    t.throws((): void => {
      CourierEnvelopeWire.encode(ciphertext, tag, NOW, 9);
    }, 'encoding a budget above 8 throws');
  }

  // Deposit: three couriers receive the sealed envelope, nothing pending.
  {
    const deps: FakeCourierDeps = new FakeCourierDeps(hexToBytes(ALICE_PRIVATE_HEX));
    deps.candidates = ['c1', 'c2', 'c3'];
    const manager: CourierManager = new CourierManager(deps);
    const payload: Uint8Array = messagePayload('m1', 'hello bob');
    const envelopeID: string | null = manager.sealAndDeposit(payload, bobPublic_);
    t.isNotNull(envelopeID, 'a fitting payload seals');
    t.equalNumber(3, deps.directSends.length, 'three couriers received the deposit');
    t.equalNumber(0, manager.pendingDepositCount(), 'nothing stays pending at the target');
    t.equalNumber(3, deps.depositedEvents.length, 'a deposit event fired per courier');
    t.equalString('c1', deps.directSends[0].peerID, 'the first candidate is courier c1');
    t.equalString('c3', deps.directSends[2].peerID, 'the third candidate is courier c3');
    const data: CourierEnvelopeWireData | null = CourierEnvelopeWire.decode(deps.directSends[0].wire);
    t.isNotNull(data, 'the deposited wire decodes');
    if (data !== null) {
      t.equalBytes(CourierRecipientTag.compute(bobPublic_, NOW), data.recipientTag,
        'the tag addresses the recipient static key');
      t.equalNumber(CourierConstants.COPY_BUDGET_INITIAL, data.copyBudget,
        'a fresh deposit carries the initial budget');
      const opened: NoiseXSealOpenResult = NoiseXSeal.open(data.ciphertext,
        hexToBytes(BOB_PRIVATE_HEX), null);
      t.equalBytes(payload, opened.payload, 'the recipient decrypts the exact payload');
      t.equalBytes(alicePublic(), opened.senderStaticPublicKey,
        'the sender identity is authenticated inside the ciphertext');
    }
  }

  // Deposit: retrying completes to 3 couriers without double deposits.
  {
    const deps: FakeCourierDeps = new FakeCourierDeps(hexToBytes(ALICE_PRIVATE_HEX));
    deps.candidates = ['c1'];
    const manager: CourierManager = new CourierManager(deps);
    const envelopeID: string | null =
      manager.sealAndDeposit(messagePayload('m2', 'retry'), bobPublic_);
    t.isNotNull(envelopeID, 'the deposit is accepted with one courier');
    t.equalNumber(1, deps.directSends.length, 'only the connected courier got a copy');
    t.equalNumber(1, manager.pendingDepositCount(), 'the deposit stays pending');
    deps.candidates = ['c1', 'c2', 'c3'];
    const sent: number = manager.retryPendingDeposits();
    t.equalNumber(2, sent, 'the retry deposits the two missing copies');
    t.equalNumber(3, deps.directSends.length, 'three sends in total');
    t.equalNumber(0, manager.pendingDepositCount(), 'the retry clears the pending entry');
    let toC1: number = 0;
    for (let i: number = 0; i < deps.directSends.length; i++) {
      if (deps.directSends[i].peerID === 'c1') {
        toC1 += 1;
      }
    }
    t.equalNumber(1, toC1, 'courier c1 is never handed the same envelope twice');
  }

  // Deposit: failed and throwing links do not count; the retry heals them.
  {
    const deps: FakeCourierDeps = new FakeCourierDeps(hexToBytes(ALICE_PRIVATE_HEX));
    deps.candidates = ['c1', 'c2', 'c3', 'c4'];
    deps.failSendTo.add('c2');
    deps.throwSendTo.add('c3');
    const manager: CourierManager = new CourierManager(deps);
    manager.sealAndDeposit(messagePayload('m3', 'flaky'), bobPublic_);
    t.equalNumber(2, deps.directSends.length, 'only the healthy links carried the deposit');
    t.equalNumber(1, manager.pendingDepositCount(), 'a 2-of-3 deposit stays pending');
    deps.failSendTo.delete('c2');
    deps.throwSendTo.delete('c3');
    const sent: number = manager.retryPendingDeposits();
    t.equalNumber(1, sent, 'the retry completes the third courier');
    t.equalNumber(3, deps.directSends.length, 'three healthy sends in total');
    t.equalNumber(0, manager.pendingDepositCount(), 'nothing stays pending');
  }

  // Deposit: payload bounds (96-byte Noise X overhead, 16 KiB cap).
  {
    const deps: FakeCourierDeps = new FakeCourierDeps(hexToBytes(ALICE_PRIVATE_HEX));
    deps.candidates = ['c1'];
    const manager: CourierManager = new CourierManager(deps);
    const empty: string | null = manager.sealAndDeposit(new Uint8Array(0), bobPublic_);
    t.isNull(empty, 'an empty payload is rejected');
    const oversize: string | null =
      manager.sealAndDeposit(new Uint8Array(16289), bobPublic_);
    t.isNull(oversize, 'a payload whose seal exceeds 16 KiB is rejected');
    t.equalNumber(0, deps.directSends.length, 'no courier saw the rejected payloads');
    t.equalNumber(0, manager.pendingDepositCount(), 'no pending entry was created');
    const boundary: string | null =
      manager.sealAndDeposit(new Uint8Array(16288), bobPublic_);
    t.isNotNull(boundary, 'a payload sealing to exactly 16 KiB is accepted');
    t.equalNumber(1, deps.directSends.length, 'the boundary payload was deposited');
  }

  // Deposit: the 24h lifetime also bounds pending deposits.
  {
    const deps: FakeCourierDeps = new FakeCourierDeps(hexToBytes(ALICE_PRIVATE_HEX));
    deps.candidates = [];
    const manager: CourierManager = new CourierManager(deps);
    const envelopeID: string | null =
      manager.sealAndDeposit(messagePayload('m4', 'stale'), bobPublic_);
    t.isNotNull(envelopeID, 'a deposit with no couriers stays pending');
    t.equalNumber(1, manager.pendingDepositCount(), 'the deposit is pending');
    deps.now += CourierConstants.ENVELOPE_TTL_MS;
    deps.candidates = ['c1'];
    const sent: number = manager.retryPendingDeposits();
    t.equalNumber(0, sent, 'an expired pending deposit is never sent');
    t.equalNumber(0, manager.pendingDepositCount(), 'the expired pending deposit is swept');
    t.equalNumber(0, deps.directSends.length, 'no courier saw the expired deposit');
  }

  // Carry pool: admission tiers and fail-closed trust.
  {
    const carrier: FakeCourierDeps = new FakeCourierDeps(hexToBytes(CAROL_PRIVATE_HEX));
    const carrierManager: CourierManager = new CourierManager(carrier);
    const wire: Uint8Array = makeWire(bobPublic_, carrier.now, 4, 1);
    t.isFalse(carrierManager.receiveEnvelope('stranger', wire),
      'a peer without a verified announce cannot deposit');
    t.equalNumber(0, carrierManager.poolSize(), 'the pool stays empty');
    carrier.favorites.add('alice');
    t.isTrue(carrierManager.receiveEnvelope('alice', wire),
      'a mutual favorite deposits into the pool');
    t.equalNumber(1, carrierManager.poolSize(), 'the envelope is carried');
    const snapshot: CourierPoolSnapshot | null = carrier.persistence.snapshot;
    t.isNotNull(snapshot, 'the pool is persisted');
    t.equalNumber(1, snapshot === null ? -1 : snapshot.entries.length,
      'one entry is persisted');
    t.equalNumber(CourierEnvelopeTier.FAVORITE, snapshot === null ? -1 : snapshot.entries[0].tier,
      'the favorite tier is persisted');
    carrier.verified.add('v1');
    const wire2: Uint8Array = makeWire(bobPublic_, carrier.now, 4, 2);
    t.isTrue(carrierManager.receiveEnvelope('v1', wire2),
      'an announce-verified peer deposits into the pool');
    const snapshot2: CourierPoolSnapshot | null = carrier.persistence.snapshot;
    t.equalNumber(CourierEnvelopeTier.VERIFIED,
      snapshot2 === null ? -1 : snapshot2.entries[1].tier,
      'the verified tier is persisted');
  }

  // Carry pool: per-depositor quotas 5 favorite / 2 verified.
  {
    const carrier: FakeCourierDeps = new FakeCourierDeps(hexToBytes(CAROL_PRIVATE_HEX));
    carrier.favorites.add('alice');
    carrier.verified.add('v1');
    carrier.verified.add('v2');
    const carrierManager: CourierManager = new CourierManager(carrier);
    let seed: number = 1;
    for (let i: number = 0; i < CourierConstants.QUOTA_MUTUAL_FAVORITE; i++) {
      carrier.now += 1000;
      t.isTrue(carrierManager.receiveEnvelope('alice', makeWire(bobPublic_, carrier.now, 4, seed)),
        'favorite deposit ' + i + ' is accepted');
      seed += 1;
    }
    t.isFalse(carrierManager.receiveEnvelope('alice', makeWire(bobPublic_, carrier.now, 4, seed)),
      'the sixth favorite deposit is over quota');
    const verifiedWire1: Uint8Array = makeWire(bobPublic_, carrier.now, 4, 101);
    const verifiedWire2: Uint8Array = makeWire(bobPublic_, carrier.now, 4, 102);
    t.isTrue(carrierManager.receiveEnvelope('v1', verifiedWire1), 'verified deposit 1 is accepted');
    t.isTrue(carrierManager.receiveEnvelope('v1', verifiedWire2), 'verified deposit 2 is accepted');
    t.isFalse(carrierManager.receiveEnvelope('v1', makeWire(bobPublic_, carrier.now, 4, 103)),
      'the third verified deposit is over quota');
    t.isTrue(carrierManager.receiveEnvelope('v2', makeWire(bobPublic_, carrier.now, 4, 201)),
      'another verified depositor has its own quota');
    t.equalNumber(8, carrierManager.poolSize(), '5 favorite + 2 + 1 verified are carried');
  }

  // Carry pool: re-offers are idempotent and only raise the budget.
  {
    const carrier: FakeCourierDeps = new FakeCourierDeps(hexToBytes(CAROL_PRIVATE_HEX));
    carrier.favorites.add('alice');
    const carrierManager: CourierManager = new CourierManager(carrier);
    const wire: Uint8Array = makeWire(bobPublic_, carrier.now, 4, 1);
    t.isTrue(carrierManager.receiveEnvelope('alice', wire), 'the envelope is accepted');
    t.isTrue(carrierManager.receiveEnvelope('alice', wire), 'a re-offer is idempotent');
    t.equalNumber(1, carrierManager.poolSize(), 'the envelope is carried exactly once');
    const raised: Uint8Array = makeWire(bobPublic_, carrier.now, 6, 1);
    t.isTrue(carrierManager.receiveEnvelope('alice', raised), 'a raised budget is merged');
    t.equalNumber(1, carrierManager.poolSize(), 'the merge does not duplicate the envelope');
    const snapshot: CourierPoolSnapshot | null = carrier.persistence.snapshot;
    t.equalNumber(6, snapshot === null ? -1 : decodedBudget(snapshot.entries[0].wireBytes),
      'the carried budget rose to 6');
  }

  // Carry pool: the 20 verified-tier bound recycles the oldest verified.
  {
    const carrier: FakeCourierDeps = new FakeCourierDeps(hexToBytes(CAROL_PRIVATE_HEX));
    const carrierManager: CourierManager = new CourierManager(carrier);
    let seed: number = 1;
    const firstWire: Uint8Array = makeWire(bobPublic_, carrier.now, 4, seed);
    for (let d: number = 0; d < 10; d++) {
      carrier.verified.add('v' + d);
      for (let k: number = 0; k < 2; k++) {
        carrier.now += 1000;
        t.isTrue(carrierManager.receiveEnvelope('v' + d, makeWire(bobPublic_, carrier.now, 4, seed)),
          'verified deposit v' + d + '-' + k + ' is accepted');
        seed += 1;
      }
    }
    t.equalNumber(20, carrierManager.poolSize(), '20 verified envelopes fill the usable slots');
    carrier.verified.add('v10');
    t.isTrue(carrierManager.receiveEnvelope('v10', makeWire(bobPublic_, carrier.now, 4, seed)),
      'the 21st verified deposit is admitted by eviction');
    t.equalNumber(20, carrierManager.poolSize(), 'the verified bound holds at 20');
    t.equalNumber(-1, carrierManager.carriedEnvelopeIDs().indexOf(wireEnvelopeID(firstWire)),
      'the oldest verified envelope was evicted');
    carrier.favorites.add('alice');
    t.isTrue(carrierManager.receiveEnvelope('alice', makeWire(bobPublic_, carrier.now, 4, 900)),
      'favorite mail is not counted against the 20 verified slots');
    t.equalNumber(21, carrierManager.poolSize(), 'the favorite deposit grows the pool to 21');
  }

  // Carry pool: the 40-slot bound evicts the oldest verified, favorites
  // are never victims, and an all-favorite full pool rejects.
  {
    const carrier: FakeCourierDeps = new FakeCourierDeps(hexToBytes(CAROL_PRIVATE_HEX));
    const carrierManager: CourierManager = new CourierManager(carrier);
    let seed: number = 1;
    const firstVerifiedWire: Uint8Array = makeWire(bobPublic_, carrier.now, 4, seed);
    for (let d: number = 0; d < 10; d++) {
      carrier.verified.add('v' + d);
      for (let k: number = 0; k < 2; k++) {
        carrier.now += 1000;
        t.isTrue(carrierManager.receiveEnvelope('v' + d, makeWire(bobPublic_, carrier.now, 4, seed)),
          'verified deposit v' + d + '-' + k + ' is accepted');
        seed += 1;
      }
    }
    const firstFavoriteWire: Uint8Array = makeWire(bobPublic_, carrier.now + 500, 4, seed);
    for (let d: number = 0; d < 4; d++) {
      carrier.favorites.add('f' + d);
      for (let k: number = 0; k < CourierConstants.QUOTA_MUTUAL_FAVORITE; k++) {
        carrier.now += 1000;
        t.isTrue(carrierManager.receiveEnvelope('f' + d, makeWire(bobPublic_, carrier.now, 4, seed)),
          'favorite deposit f' + d + '-' + k + ' is accepted');
        seed += 1;
      }
    }
    t.equalNumber(40, carrierManager.poolSize(), 'the pool is full at 40 envelopes');
    carrier.favorites.add('f4');
    t.isTrue(carrierManager.receiveEnvelope('f4', makeWire(bobPublic_, carrier.now, 4, seed)),
      'a favorite deposit at a full pool evicts the oldest verified');
    t.equalNumber(40, carrierManager.poolSize(), 'the pool holds at 40');
    t.equalNumber(-1, carrierManager.carriedEnvelopeIDs().indexOf(wireEnvelopeID(firstVerifiedWire)),
      'the oldest verified envelope was evicted for the favorite mail');
    t.isTrue(carrierManager.carriedEnvelopeIDs().indexOf(wireEnvelopeID(firstFavoriteWire)) >= 0,
      'the oldest favorite envelope survives');

    const favoriteOnly: FakeCourierDeps = new FakeCourierDeps(hexToBytes(CAROL_PRIVATE_HEX));
    const favoriteOnlyManager: CourierManager = new CourierManager(favoriteOnly);
    let favSeed: number = 1;
    for (let d: number = 0; d < 8; d++) {
      favoriteOnly.favorites.add('f' + d);
      for (let k: number = 0; k < CourierConstants.QUOTA_MUTUAL_FAVORITE; k++) {
        favoriteOnly.now += 1000;
        t.isTrue(favoriteOnlyManager.receiveEnvelope('f' + d,
          makeWire(bobPublic_, favoriteOnly.now, 4, favSeed)),
          'favorite-only deposit f' + d + '-' + k + ' is accepted');
        favSeed += 1;
      }
    }
    t.equalNumber(40, favoriteOnlyManager.poolSize(), 'an all-favorite pool fills to 40');
    favoriteOnly.favorites.add('f8');
    t.isFalse(favoriteOnlyManager.receiveEnvelope('f8',
      makeWire(bobPublic_, favoriteOnly.now, 4, favSeed)),
      'an all-favorite full pool rejects new mail rather than evicting favorites');
    t.equalNumber(40, favoriteOnlyManager.poolSize(), 'no favorite was evicted');
  }

  // Handover, direct announce: deliver over the active link and remove.
  {
    const carrier: FakeCourierDeps = new FakeCourierDeps(hexToBytes(CAROL_PRIVATE_HEX));
    carrier.favorites.add('alice');
    const carrierManager: CourierManager = new CourierManager(carrier);
    const wire: Uint8Array = makeWire(bobPublic_, carrier.now, 4, 1);
    t.isTrue(carrierManager.receiveEnvelope('alice', wire), 'the envelope is carried');
    const delivered: number = carrierManager.onDirectAnnounce('bob', bobPublic_);
    t.equalNumber(1, delivered, 'the direct announce delivers one envelope');
    t.equalNumber(1, carrier.directSends.length, 'the delivery went over the active link');
    t.equalString('bob', carrier.directSends[0].peerID, 'the recipient is the link target');
    t.equalNumber(0, carrierManager.poolSize(), 'the delivered envelope is removed');
    t.equalNumber(1, carrier.handoverEvents.length, 'a handover event fired');
    t.equalNumber(0, carrierManager.onDirectAnnounce('bob', carolPublic()),
      'a non-matching static key delivers nothing');
    const wire2: Uint8Array = makeWire(bobPublic_, carrier.now, 4, 2);
    t.isTrue(carrierManager.receiveEnvelope('alice', wire2), 'a second envelope is carried');
    carrier.failSendTo.add('bob');
    t.equalNumber(0, carrierManager.onDirectAnnounce('bob', bobPublic_),
      'a failed link delivery reports zero');
    t.equalNumber(1, carrierManager.poolSize(), 'the envelope survives a failed delivery');
    carrier.failSendTo.delete('bob');
    t.equalNumber(1, carrierManager.onDirectAnnounce('bob', bobPublic_),
      'the retry after the link heals delivers');
    t.equalNumber(0, carrierManager.poolSize(), 'the pool is empty after the handover');
    const yesterdayWire: Uint8Array =
      makeWire(bobPublic_, carrier.now - CourierConstants.UTC_DAY_MS + 1000, 4, 3);
    t.isTrue(carrierManager.receiveEnvelope('alice', yesterdayWire),
      'an envelope tagged on the previous UTC day is still carried');
    t.equalNumber(1, carrierManager.onDirectAnnounce('bob', bobPublic_),
      'a previous-day tag still matches within the 24h envelope life');
  }

  // Handover, relayed announce: one throttled targeted-flood copy, the
  // original stays; a failed flood does not consume the throttle.
  {
    const carrier: FakeCourierDeps = new FakeCourierDeps(hexToBytes(CAROL_PRIVATE_HEX));
    carrier.favorites.add('alice');
    const carrierManager: CourierManager = new CourierManager(carrier);
    const wire: Uint8Array = makeWire(bobPublic_, carrier.now, 4, 1);
    t.isTrue(carrierManager.receiveEnvelope('alice', wire), 'the envelope is carried');
    t.equalNumber(1, carrierManager.onRelayedAnnounce('bob', bobPublic_),
      'the relayed announce floods one copy');
    t.equalNumber(1, carrier.floods.length, 'one targeted-flood copy was sent');
    t.equalNumber(1, carrierManager.poolSize(), 'the original envelope is kept');
    t.equalNumber(0, carrierManager.onRelayedAnnounce('bob', bobPublic_),
      'a second relayed announce within 10 minutes is throttled');
    t.equalNumber(1, carrier.floods.length, 'no second copy was flooded');
    carrier.now += CourierConstants.RELAYED_ANNOUNCE_THROTTLE_MS;
    t.equalNumber(1, carrierManager.onRelayedAnnounce('bob', bobPublic_),
      'the throttle window opens after 10 minutes');
    t.equalNumber(2, carrier.floods.length, 'the second copy was flooded');
    t.equalNumber(1, carrierManager.poolSize(), 'the original is still carried');
    t.equalNumber(0, carrierManager.onRelayedAnnounce('bob', carolPublic()),
      'a non-matching relayed announce floods nothing');
    carrier.now += CourierConstants.RELAYED_ANNOUNCE_THROTTLE_MS;
    carrier.failFlood = true;
    t.equalNumber(0, carrierManager.onRelayedAnnounce('bob', bobPublic_),
      'a failed flood reports zero');
    carrier.failFlood = false;
    t.equalNumber(1, carrierManager.onRelayedAnnounce('bob', bobPublic_),
      'a failed flood did not consume the throttle');
  }

  // Spray-and-wait: half the remaining budget per courier, at most once
  // per courier, with rollback on a failed link.
  {
    const carrier: FakeCourierDeps = new FakeCourierDeps(hexToBytes(CAROL_PRIVATE_HEX));
    carrier.favorites.add('alice');
    const carrierManager: CourierManager = new CourierManager(carrier);
    const wire: Uint8Array = makeWire(bobPublic_, carrier.now, 4, 1);
    t.isTrue(carrierManager.receiveEnvelope('alice', wire), 'the envelope is carried');
    t.equalNumber(1, carrierManager.sprayTo('courierX'), 'the first spray hands one envelope');
    t.equalString('courierX', carrier.directSends[carrier.directSends.length - 1].peerID,
      'the spray went to courierX');
    t.equalNumber(2, decodedBudget(carrier.directSends[carrier.directSends.length - 1].wire),
      'budget 4 hands 2');
    t.equalNumber(2, decodedBudget(carrier.persistence.snapshot === null
      ? new Uint8Array(0) : carrier.persistence.snapshot.entries[0].wireBytes),
      'the carried budget dropped to 2');
    t.equalNumber(0, carrierManager.sprayTo('courierX'),
      'the same courier is never sprayed twice');
    t.equalNumber(1, carrierManager.sprayTo('courierY'), 'a second courier is sprayed');
    t.equalNumber(1, decodedBudget(carrier.directSends[carrier.directSends.length - 1].wire),
      'budget 2 hands 1');
    t.equalNumber(0, carrierManager.sprayTo('courierZ'),
      'a remaining budget of 1 hands nothing');
    t.equalNumber(1, decodedBudget(carrier.persistence.snapshot === null
      ? new Uint8Array(0) : carrier.persistence.snapshot.entries[0].wireBytes),
      'the last copy is kept');

    const rollback: FakeCourierDeps = new FakeCourierDeps(hexToBytes(CAROL_PRIVATE_HEX));
    rollback.favorites.add('alice');
    const rollbackManager: CourierManager = new CourierManager(rollback);
    t.isTrue(rollbackManager.receiveEnvelope('alice', makeWire(bobPublic_, rollback.now, 4, 1)),
      'the rollback envelope is carried');
    rollback.failSendTo.add('courierE');
    t.equalNumber(0, rollbackManager.sprayTo('courierE'), 'the failed spray hands nothing');
    t.equalNumber(4, decodedBudget(rollback.persistence.snapshot === null
      ? new Uint8Array(0) : rollback.persistence.snapshot.entries[0].wireBytes),
      'the failed spray rolled the budget back to 4');
    rollback.failSendTo.delete('courierE');
    t.equalNumber(1, rollbackManager.sprayTo('courierE'), 'the healed link is sprayed');
    t.equalNumber(2, decodedBudget(rollback.persistence.snapshot === null
      ? new Uint8Array(0) : rollback.persistence.snapshot.entries[0].wireBytes),
      'the successful spray halves the budget');

    const drained: FakeCourierDeps = new FakeCourierDeps(hexToBytes(CAROL_PRIVATE_HEX));
    drained.favorites.add('alice');
    const drainedManager: CourierManager = new CourierManager(drained);
    t.isTrue(drainedManager.receiveEnvelope('alice', makeWire(bobPublic_, drained.now, 0, 1)),
      'a zero-budget envelope is carried');
    t.equalNumber(0, drainedManager.sprayTo('courierX'),
      'a zero-budget envelope sprays nothing');
  }

  // Recipient side: tag match, decrypt, blocked-sender decrypt-discard
  // and message-ID dedupe (spec US17 acceptance scenario 3 and L234).
  {
    const bobDeps: FakeCourierDeps = new FakeCourierDeps(hexToBytes(BOB_PRIVATE_HEX));
    const bobManager: CourierManager = new CourierManager(bobDeps);
    const payload: Uint8Array = messagePayload('m1', 'hello from alice');
    const ciphertext: Uint8Array = NoiseXSeal.seal(payload, hexToBytes(ALICE_PRIVATE_HEX),
      bobPublic_, fixedEphemeral, null);
    const wire: Uint8Array = CourierEnvelopeWire.encode(ciphertext,
      CourierRecipientTag.compute(bobPublic_, NOW), NOW, 4);
    const result: CourierOpenedMail = bobManager.receiveSealedMail(wire);
    t.equalNumber(CourierOpenStatus.OPENED, result.status, 'the addressee opens the mail');
    t.equalString('m1', result.messageID === null ? '' : result.messageID,
      'the message ID is parsed from the payload');
    t.equalBytes(payload, result.payload, 'the decrypted payload is returned');
    t.equalBytes(alicePublic(),
      result.senderStaticPublicKey === null ? new Uint8Array(0) : result.senderStaticPublicKey,
      'the sender static key is authenticated');
    t.equalNumber(1, bobDeps.openedEvents.length, 'a mail-opened event fired');

    const notOurs: Uint8Array = NoiseXSeal.seal(payload, hexToBytes(ALICE_PRIVATE_HEX),
      carolPublic(), fixedEphemeral, null);
    const notOursWire: Uint8Array = CourierEnvelopeWire.encode(notOurs,
      CourierRecipientTag.compute(carolPublic(), NOW), NOW, 4);
    t.equalNumber(CourierOpenStatus.NOT_ADDRESSED,
      bobManager.receiveSealedMail(notOursWire).status,
      'an envelope tagged for someone else is not opened');
    t.equalNumber(1, bobDeps.openedEvents.length, 'no event fired for foreign mail');

    bobDeps.blockedSenderHexes.add(ByteUtils.bytesToHex(alicePublic()));
    const blockedResult: CourierOpenedMail = bobManager.receiveSealedMail(wire);
    t.equalNumber(CourierOpenStatus.BLOCKED, blockedResult.status,
      'a blocked sender is discarded after decryption');
    t.equalNumber(1, bobDeps.openedEvents.length, 'blocked mail fires no opened event');

    bobDeps.blockedSenderHexes.clear();
    bobDeps.seenMessageIDs.add('m1');
    const duplicateResult: CourierOpenedMail = bobManager.receiveSealedMail(wire);
    t.equalNumber(CourierOpenStatus.DUPLICATE, duplicateResult.status,
      'an already-seen message ID is reported as a duplicate');
    t.equalString('m1', duplicateResult.messageID === null ? '' : duplicateResult.messageID,
      'the duplicate carries the message ID');
    t.equalNumber(1, bobDeps.openedEvents.length, 'duplicates fire no opened event');

    t.equalNumber(CourierOpenStatus.MALFORMED,
      bobManager.receiveSealedMail(ByteUtils.utf8Encode('garbage')).status,
      'undecodable wire is malformed');
  }

  // Persistence: carried mail, budgets, spray history, throttles and
  // quotas survive a restart via the encrypted store facade.
  {
    const carrier: FakeCourierDeps = new FakeCourierDeps(hexToBytes(CAROL_PRIVATE_HEX));
    carrier.favorites.add('alice');
    carrier.verified.add('v1');
    const carrierManager: CourierManager = new CourierManager(carrier);
    t.isTrue(carrierManager.receiveEnvelope('alice', makeWire(bobPublic_, carrier.now, 4, 1)),
      'alice mail is carried');
    t.equalNumber(1, carrierManager.sprayTo('courierX'), 'the mail was sprayed once');
    t.isTrue(carrierManager.receiveEnvelope('v1', makeWire(bobPublic_, carrier.now, 4, 2)),
      'verified mail is carried');
    t.equalNumber(1, carrierManager.sprayTo('courierX'),
      'the verified mail was sprayed to courierX too');
    t.equalNumber(2, carrierManager.onRelayedAnnounce('bob', bobPublic_),
      'both envelopes were flooded toward bob');
    carrier.now += 1000;
    t.isTrue(carrier.persistence.saveCount > 0, 'the pool was persisted');

    const restored: FakeCourierDeps = new FakeCourierDeps(hexToBytes(CAROL_PRIVATE_HEX));
    restored.now = carrier.now;
    restored.favorites.add('alice');
    restored.verified.add('v1');
    restored.persistence.snapshot = carrier.persistence.snapshot;
    const restoredManager: CourierManager = new CourierManager(restored);
    restoredManager.initialize();
    t.equalNumber(2, restoredManager.poolSize(), 'both envelopes were restored');
    t.equalNumber(2, decodedBudget(restored.persistence.snapshot === null
      ? new Uint8Array(0) : restored.persistence.snapshot.entries[0].wireBytes),
      'the sprayed budget of 2 was restored');
    t.equalNumber(0, restoredManager.sprayTo('courierX'),
      'the spray history was restored');
    t.equalNumber(2, restoredManager.sprayTo('courierY'),
      'both envelopes still spray to a new courier');
    t.equalNumber(0, restoredManager.onRelayedAnnounce('bob', bobPublic_),
      'the relayed-announce throttle was restored');
    restored.now += CourierConstants.RELAYED_ANNOUNCE_THROTTLE_MS;
    t.equalNumber(2, restoredManager.onRelayedAnnounce('bob', bobPublic_),
      'the throttle opens after the window');
    let seed: number = 11;
    for (let i: number = 0; i < CourierConstants.QUOTA_MUTUAL_FAVORITE - 1; i++) {
      t.isTrue(restoredManager.receiveEnvelope('alice', makeWire(bobPublic_, restored.now, 4, seed)),
        'restored favorite deposit ' + i + ' is accepted');
      seed += 1;
    }
    t.isFalse(restoredManager.receiveEnvelope('alice', makeWire(bobPublic_, restored.now, 4, seed)),
      'the restored favorite quota of 5 still binds');
    t.isTrue(restoredManager.receiveEnvelope('v1', makeWire(bobPublic_, restored.now, 4, 301)),
      'the second verified deposit fits the restored quota');
    t.isFalse(restoredManager.receiveEnvelope('v1', makeWire(bobPublic_, restored.now, 4, 302)),
      'the restored verified quota of 2 still binds');
  }

  // Lifetime: carried envelopes expire at 24h and are swept; expired
  // wire is rejected at admission.
  {
    const carrier: FakeCourierDeps = new FakeCourierDeps(hexToBytes(CAROL_PRIVATE_HEX));
    carrier.favorites.add('alice');
    const carrierManager: CourierManager = new CourierManager(carrier);
    t.isTrue(carrierManager.receiveEnvelope('alice', makeWire(bobPublic_, carrier.now, 4, 1)),
      'a fresh envelope is carried');
    t.isFalse(carrierManager.receiveEnvelope('alice',
      makeWire(bobPublic_, carrier.now - CourierConstants.ENVELOPE_TTL_MS - 1, 4, 2)),
      'wire older than the 24h lifetime is rejected at admission');
    carrier.now += CourierConstants.ENVELOPE_TTL_MS + 1;
    t.equalNumber(1, carrierManager.sweepExpired(), 'the sweep drops the expired envelope');
    t.equalNumber(0, carrierManager.poolSize(), 'the pool is empty after the sweep');
    t.equalNumber(0, carrier.persistence.snapshot === null ? -1
      : carrier.persistence.snapshot.entries.length, 'the emptied pool is persisted');
  }
}
