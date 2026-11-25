/**
 * Nostr transport contract tests (US12, T060): Android
 * NostrTransport.kt / NostrEmbeddedBitChat.kt parity.
 *
 *  - Embedded "bitchat1:" round trips: private message (packet fields +
 *    PrivateMessagePacket TLV), recipient-addressed acks (DELIVERED /
 *    READ_RECEIPT), no-recipient acks with a randomized sender ID and
 *    a null recipient, and the decode failure matrix (wrong prefix,
 *    invalid base64, undecodable binary);
 *  - normalizeRecipientPeerID: mesh IDs pass lowercased, 64-hex Noise
 *    keys resolve to the fingerprint-truncated mesh peer ID, anything
 *    else is returned verbatim;
 *  - Transport end-to-end: sendPrivateMessage publishes exactly one
 *    kind-1059 gift wrap that the recipient decrypts into the embedded
 *    packet (message ID + content intact, sender = our identity);
 *  - Failure paths: no identity, unknown recipient pubkey, and a
 *    missing stored peer ID all refuse the send (Android parity);
 *  - sendFavoriteNotification embeds a FavoriteControlMessage carrying
 *    our npub;
 *  - Receipt pacing: DELIVERED acks publish immediately, READ receipts
 *    go through the 350ms throttle (first immediate, subsequent ones
 *    queued behind the cooldown, cleanup drops the queue).
 */
import { ContractAssert } from './ContractAssert';
import { ByteUtils } from '../../main/ets/common/ByteUtils';
import { NoisePayloadType, PrivateMessagePacket } from '../../main/ets/model/IdentityModels';
import { MessageType } from '../../main/ets/model/BitchatPacket';
import { FavoriteControlMessage } from '../../main/ets/model/FavoriteModels';
import { ContactIdentityResolver } from '../../main/ets/service/identity/ContactIdentityResolver';
import { EMBEDDED_BITCHAT_PREFIX, EmbeddedBitChatMessage, NostrEmbeddedBitChat } from '../../main/ets/service/nostr/NostrEmbeddedBitChat';
import { NostrEvent, NostrKind } from '../../main/ets/service/nostr/NostrEvent';
import { NostrIdentity } from '../../main/ets/service/nostr/NostrIdentity';
import { DecryptedPrivateMessage, NostrProtocol } from '../../main/ets/service/nostr/NostrProtocol';
import { NostrRandomSource } from '../../main/ets/service/nostr/NostrRandomSource';
import { NostrTransport } from '../../main/ets/service/nostr/NostrTransport';
import { NostrTransportDeps } from '../../main/ets/service/nostr/NostrTransport';

const NT_ALICE_SEC: string =
  'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef';
const NT_BOB_SEC: string =
  'c90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b14e5c9';
const NT_PEER_A: string = 'aaaabbbbccccdddd';
const NT_PEER_B: string = '1111222233334444';
const NT_NOW_MS: number = 1737000000000;
const NT_NOISE_KEY_HEX: string = 'abcd'.repeat(16);

/** Lehmer-RNG random source for behavioral (non-golden) tests. */
class NtCountingRandom implements NostrRandomSource {
  private state: number;

  constructor(seed: number) {
    this.state = seed % 0x7FFFFFFF;
  }

  private advance(): number {
    this.state = (this.state * 48271) % 0x7FFFFFFF;
    return this.state;
  }

  nextBytes(count: number): Uint8Array {
    const out: Uint8Array = new Uint8Array(count);
    for (let i: number = 0; i < count; i++) {
      out[i] = this.advance() & 0xFF;
    }
    return out;
  }

  nextInt(bound: number): number {
    return this.advance() % bound;
  }
}

/** Recording scheduler double for the throttle. */
class NtScheduler {
  delays: number[] = [];
  tasks: (() => void)[] = [];

  readonly schedule: (delayMs: number, task: () => void) => void =
    (delayMs: number, task: () => void): void => {
      this.delays.push(delayMs);
      this.tasks.push(task);
    };

  runLast(): void {
    if (this.tasks.length === 0) {
      return;
    }
    this.tasks[this.tasks.length - 1]();
  }
}

/** Recording dependency rig standing in for the device wiring. */
class NtTransportRig implements NostrTransportDeps {
  published: NostrEvent[] = [];
  identityValue: NostrIdentity | null = null;
  senderPeerIdValue: string = NT_PEER_A;
  randomValue: NostrRandomSource = new NtCountingRandom(1);
  nowValue: number = NT_NOW_MS;
  schedulerValue: NtScheduler = new NtScheduler();
  private readonly peerToPubkey: Map<string, string> = new Map();
  private readonly pubkeyToPeer: Map<string, string> = new Map();

  mapRecipient(peerID: string, identity: NostrIdentity): void {
    this.peerToPubkey.set(peerID, identity.publicKeyHex);
    this.pubkeyToPeer.set(identity.publicKeyHex, peerID);
  }

  peerToPubkeyOnly(peerID: string, identity: NostrIdentity): void {
    this.peerToPubkey.set(peerID, identity.publicKeyHex);
  }

  pubkeyToPeerOverride(pubkey: string, peerID: string): void {
    this.pubkeyToPeer.set(pubkey, peerID);
  }

  senderPeerID(): string {
    return this.senderPeerIdValue;
  }

  currentIdentity(): NostrIdentity | null {
    return this.identityValue;
  }

  resolveNostrPubkey(peerID: string): string | null {
    const value: string | undefined = this.peerToPubkey.get(peerID);
    return value !== undefined ? value : null;
  }

  findPeerIDForNostrPubkey(npubOrHex: string): string | null {
    const value: string | undefined = this.pubkeyToPeer.get(npubOrHex);
    return value !== undefined ? value : null;
  }

  random(): NostrRandomSource {
    return this.randomValue;
  }

  now(): number {
    return this.nowValue;
  }

  publish(events: NostrEvent[]): void {
    for (let i: number = 0; i < events.length; i++) {
      this.published.push(events[i]);
    }
  }

  schedule(delayMs: number, task: () => void): number {
    this.schedulerValue.schedule(delayMs, task);
    return this.schedulerValue.tasks.length;
  }
}

/** Unwrap one published gift wrap into its embedded BitChat packet. */
function ntUnwrapEmbedded(wrap: NostrEvent,
  recipient: NostrIdentity): EmbeddedBitChatMessage {
  const decrypted: DecryptedPrivateMessage | null =
    NostrProtocol.decryptPrivateMessage(wrap, recipient);
  if (decrypted === null) {
    throw new Error('published gift wrap is not decryptable by the recipient');
  }
  const embedded: EmbeddedBitChatMessage | null =
    NostrEmbeddedBitChat.decodeEmbedded(decrypted.content);
  if (embedded === null) {
    throw new Error('published content is not an embedded BitChat packet');
  }
  return embedded;
}

function ntBytesDiffer(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) {
    return true;
  }
  for (let i: number = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return true;
    }
  }
  return false;
}

export function runNostrTransportContractTests(t: ContractAssert): void {
  // Embedded private message round trip: prefix, packet fields, TLV.
  {
    const content: string | null = NostrEmbeddedBitChat.encodePMForNostr(
      'hello over nostr', 'msg-nt-1', NT_PEER_B, NT_PEER_A, NT_NOW_MS);
    if (content === null) {
      throw new Error('embedded PM encode failed');
    }
    t.isTrue(content.startsWith(EMBEDDED_BITCHAT_PREFIX),
      'the embedded PM carries the bitchat1: prefix');
    const embedded: EmbeddedBitChatMessage | null =
      NostrEmbeddedBitChat.decodeEmbedded(content);
    if (embedded === null) {
      throw new Error('embedded PM decode failed');
    }
    t.equalNumber(1, embedded.packet.version, 'the embedded packet is v1');
    t.equalNumber(MessageType.NOISE_ENCRYPTED, embedded.packet.type,
      'the embedded packet is NOISE_ENCRYPTED');
    t.equalNumber(NT_NOW_MS, embedded.packet.timestamp,
      'the embedded packet keeps the wall clock');
    t.equalBytes(ByteUtils.hexToBytes(NT_PEER_A), embedded.packet.senderId,
      'the embedded sender ID is our mesh peer ID');
    const recipientId: Uint8Array | null = embedded.packet.recipientId;
    if (recipientId === null) {
      throw new Error('embedded PM recipient missing');
    }
    t.equalBytes(ByteUtils.hexToBytes(NT_PEER_B), recipientId,
      'the embedded recipient is the peer');
    t.equalNumber(NoisePayloadType.PRIVATE_MESSAGE, embedded.payload.type,
      'the embedded payload is a private message');
    const pm: PrivateMessagePacket | null =
      PrivateMessagePacket.decode(embedded.payload.data);
    if (pm === null) {
      throw new Error('embedded PM TLV decode failed');
    }
    t.equalString('msg-nt-1', pm.messageID, 'the message ID round trips');
    t.equalString('hello over nostr', pm.content, 'the content round trips');
  }

  // Recipient-addressed acks: DELIVERED and READ_RECEIPT round trips;
  // other payload types are refused.
  {
    const delivered: string | null = NostrEmbeddedBitChat.encodeAckForNostr(
      NoisePayloadType.DELIVERED, 'ack-d1', NT_PEER_B, NT_PEER_A, NT_NOW_MS);
    if (delivered === null) {
      throw new Error('delivered ack encode failed');
    }
    const embeddedDelivered: EmbeddedBitChatMessage | null =
      NostrEmbeddedBitChat.decodeEmbedded(delivered);
    if (embeddedDelivered === null) {
      throw new Error('delivered ack decode failed');
    }
    t.equalNumber(NoisePayloadType.DELIVERED, embeddedDelivered.payload.type,
      'the DELIVERED ack keeps its type');
    t.equalString('ack-d1', ByteUtils.utf8Decode(embeddedDelivered.payload.data),
      'the DELIVERED ack carries the message ID');

    const read: string | null = NostrEmbeddedBitChat.encodeAckForNostr(
      NoisePayloadType.READ_RECEIPT, 'ack-r1', NT_PEER_B, NT_PEER_A, NT_NOW_MS);
    if (read === null) {
      throw new Error('read ack encode failed');
    }
    const embeddedRead: EmbeddedBitChatMessage | null =
      NostrEmbeddedBitChat.decodeEmbedded(read);
    if (embeddedRead === null) {
      throw new Error('read ack decode failed');
    }
    t.equalNumber(NoisePayloadType.READ_RECEIPT, embeddedRead.payload.type,
      'the READ_RECEIPT ack keeps its type');
    t.equalString('ack-r1', ByteUtils.utf8Decode(embeddedRead.payload.data),
      'the READ_RECEIPT ack carries the message ID');

    t.isNull(NostrEmbeddedBitChat.encodeAckForNostr(
      NoisePayloadType.PRIVATE_MESSAGE, 'x', NT_PEER_B, NT_PEER_A, NT_NOW_MS),
      'a private-message payload is not an ack');
    t.isNull(NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(
      NoisePayloadType.PEER_STATE, 'x', new NtCountingRandom(1), NT_NOW_MS),
      'a peer-state payload is not an ack');
  }

  // No-recipient acks: null recipient, fresh random sender ID per envelope.
  {
    const first: string | null = NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(
      NoisePayloadType.DELIVERED, 'ack-nr', new NtCountingRandom(1), NT_NOW_MS);
    const second: string | null = NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(
      NoisePayloadType.DELIVERED, 'ack-nr', new NtCountingRandom(2), NT_NOW_MS);
    if (first === null || second === null) {
      throw new Error('no-recipient ack encode failed');
    }
    const embeddedFirst: EmbeddedBitChatMessage | null =
      NostrEmbeddedBitChat.decodeEmbedded(first);
    const embeddedSecond: EmbeddedBitChatMessage | null =
      NostrEmbeddedBitChat.decodeEmbedded(second);
    if (embeddedFirst === null || embeddedSecond === null) {
      throw new Error('no-recipient ack decode failed');
    }
    t.isNull(embeddedFirst.packet.recipientId,
      'the no-recipient ack embeds no recipient');
    t.equalNumber(8, embeddedFirst.packet.senderId.length,
      'the no-recipient sender ID stays 8 bytes');
    t.isTrue(ntBytesDiffer(embeddedFirst.packet.senderId, embeddedSecond.packet.senderId),
      'the sender ID is fresh random per envelope');
    t.equalNumber(NoisePayloadType.DELIVERED, embeddedFirst.payload.type,
      'the no-recipient ack keeps its type');
    t.equalString('ack-nr', ByteUtils.utf8Decode(embeddedFirst.payload.data),
      'the no-recipient ack carries the message ID');
  }

  // decodeEmbedded failure matrix: wrong prefix, invalid base64, garbage.
  {
    t.isNull(NostrEmbeddedBitChat.decodeEmbedded('nostr1:AAAA'),
      'a wrong prefix is rejected');
    t.isNull(NostrEmbeddedBitChat.decodeEmbedded('bitchat1:!!!not-base64!!!'),
      'invalid base64 is rejected');
    t.isNull(NostrEmbeddedBitChat.decodeEmbedded('bitchat1:' +
      ByteUtils.base64UrlEncode(new Uint8Array([0x01, 0x02, 0x03]))),
      'undecodable binary is rejected');
  }

  // normalizeRecipientPeerID: mesh lowercased, Noise key derived, else verbatim.
  {
    t.equalString('aaaabbbbccccdddd',
      NostrEmbeddedBitChat.normalizeRecipientPeerID('AAAABBBBCCCCDDDD'),
      'a mesh peer ID passes lowercased');
    const expectedDerived: string =
      ByteUtils.sha256Hex(ByteUtils.hexToBytes(NT_NOISE_KEY_HEX)).substring(0, 16);
    t.equalString(expectedDerived,
      NostrEmbeddedBitChat.normalizeRecipientPeerID(NT_NOISE_KEY_HEX),
      'a Noise key hex resolves to the fingerprint-truncated mesh peer ID');
    t.equalString('not-hex!',
      NostrEmbeddedBitChat.normalizeRecipientPeerID('not-hex!'),
      'anything else is returned verbatim');
  }

  // Transport end-to-end: one kind-1059 gift wrap, decryptable, intact.
  {
    const rig: NtTransportRig = new NtTransportRig();
    const alice: NostrIdentity = NostrIdentity.fromPrivateKey(NT_ALICE_SEC, NT_NOW_MS);
    const bob: NostrIdentity = NostrIdentity.fromPrivateKey(NT_BOB_SEC, NT_NOW_MS);
    rig.identityValue = alice;
    rig.mapRecipient(NT_PEER_B, bob);
    const transport: NostrTransport = new NostrTransport(rig);

    const ok: boolean = transport.sendPrivateMessage('e2e hello', NT_PEER_B, 'msg-e2e-1');
    t.isTrue(ok, 'the private send succeeds');
    t.equalNumber(1, rig.published.length, 'exactly one gift wrap is published');
    const wrap: NostrEvent = rig.published[0];
    t.equalNumber(NostrKind.GIFT_WRAP, wrap.kind, 'the envelope is a kind-1059 gift wrap');
    t.equalString(bob.publicKeyHex, wrap.tags[0][1], 'the p-tag targets the recipient');
    t.isTrue(wrap.isValidSignature(), 'the gift wrap carries a valid signature');
    t.isTrue(wrap.pubkey !== alice.publicKeyHex,
      'the gift wrap hides the sender behind a fresh wrap key');
    const embedded: EmbeddedBitChatMessage = ntUnwrapEmbedded(wrap, bob);
    t.equalNumber(NoisePayloadType.PRIVATE_MESSAGE, embedded.payload.type,
      'the decrypted payload is a private message');
    const pm: PrivateMessagePacket | null =
      PrivateMessagePacket.decode(embedded.payload.data);
    if (pm === null) {
      throw new Error('end-to-end PM TLV decode failed');
    }
    t.equalString('msg-e2e-1', pm.messageID, 'the message ID survives the wrap');
    t.equalString('e2e hello', pm.content, 'the content survives the wrap');
    const decrypted: DecryptedPrivateMessage | null =
      NostrProtocol.decryptPrivateMessage(wrap, bob);
    if (decrypted === null) {
      throw new Error('end-to-end decrypt failed');
    }
    t.equalString(alice.publicKeyHex, decrypted.senderPubkey,
      'the rumor signer is our Nostr identity');
  }

  // Failure paths: no identity, unknown pubkey, missing stored peer ID.
  {
    const bob: NostrIdentity = NostrIdentity.fromPrivateKey(NT_BOB_SEC, NT_NOW_MS);

    const noIdentity: NtTransportRig = new NtTransportRig();
    noIdentity.mapRecipient(NT_PEER_B, bob);
    const transportNoIdentity: NostrTransport = new NostrTransport(noIdentity);
    t.isFalse(transportNoIdentity.sendPrivateMessage('x', NT_PEER_B, 'm1'),
      'a missing identity refuses the send');
    t.equalNumber(0, noIdentity.published.length, 'nothing is published');

    const alice: NostrIdentity = NostrIdentity.fromPrivateKey(NT_ALICE_SEC, NT_NOW_MS);
    const unknownPubkey: NtTransportRig = new NtTransportRig();
    unknownPubkey.identityValue = alice;
    const transportUnknown: NostrTransport = new NostrTransport(unknownPubkey);
    t.isFalse(transportUnknown.sendPrivateMessage('x', NT_PEER_B, 'm2'),
      'an unknown recipient pubkey refuses the send');
    t.equalNumber(0, unknownPubkey.published.length, 'nothing is published');

    const noStoredPeer: NtTransportRig = new NtTransportRig();
    noStoredPeer.identityValue = alice;
    noStoredPeer.peerToPubkeyOnly(NT_PEER_B, bob);
    const transportNoPeer: NostrTransport = new NostrTransport(noStoredPeer);
    t.isFalse(transportNoPeer.sendPrivateMessage('x', NT_PEER_B, 'm3'),
      'a missing stored peer ID refuses the send (Android parity)');
    t.equalNumber(0, noStoredPeer.published.length, 'nothing is published');

    const emptyStoredPeer: NtTransportRig = new NtTransportRig();
    emptyStoredPeer.identityValue = alice;
    emptyStoredPeer.mapRecipient(NT_PEER_B, bob);
    emptyStoredPeer.pubkeyToPeerOverride(bob.publicKeyHex, '');
    const transportEmptyPeer: NostrTransport = new NostrTransport(emptyStoredPeer);
    t.isFalse(transportEmptyPeer.sendPrivateMessage('x', NT_PEER_B, 'm4'),
      'an empty stored peer ID refuses the send');
    t.equalNumber(0, emptyStoredPeer.published.length, 'nothing is published');
  }

  // Favorite notifications embed a FavoriteControlMessage with our npub.
  {
    const rig: NtTransportRig = new NtTransportRig();
    const alice: NostrIdentity = NostrIdentity.fromPrivateKey(NT_ALICE_SEC, NT_NOW_MS);
    const bob: NostrIdentity = NostrIdentity.fromPrivateKey(NT_BOB_SEC, NT_NOW_MS);
    rig.identityValue = alice;
    rig.mapRecipient(NT_PEER_B, bob);
    const transport: NostrTransport = new NostrTransport(rig);

    const ok: boolean = transport.sendFavoriteNotification(NT_PEER_B, true);
    t.isTrue(ok, 'the favorite notification sends');
    t.equalNumber(1, rig.published.length, 'one gift wrap is published');
    const embedded: EmbeddedBitChatMessage = ntUnwrapEmbedded(rig.published[0], bob);
    t.equalNumber(NoisePayloadType.PRIVATE_MESSAGE, embedded.payload.type,
      'the favorite notice rides a private-message payload');
    const pm: PrivateMessagePacket | null =
      PrivateMessagePacket.decode(embedded.payload.data);
    if (pm === null) {
      throw new Error('favorite notice TLV decode failed');
    }
    const notice: FavoriteControlMessage | null =
      FavoriteControlMessage.parse(pm.content);
    if (notice === null) {
      throw new Error('favorite notice parse failed');
    }
    t.isTrue(notice.isFavorite, 'the favorite flag round trips');
    t.equalString(alice.npub, notice.npub, 'our npub rides the notice');
  }

  // Receipt pacing: DELIVERED immediate, READ through the 350ms throttle.
  {
    const rig: NtTransportRig = new NtTransportRig();
    const alice: NostrIdentity = NostrIdentity.fromPrivateKey(NT_ALICE_SEC, NT_NOW_MS);
    const bob: NostrIdentity = NostrIdentity.fromPrivateKey(NT_BOB_SEC, NT_NOW_MS);
    rig.identityValue = alice;
    rig.mapRecipient(NT_PEER_B, bob);
    const transport: NostrTransport = new NostrTransport(rig);

    t.isTrue(transport.sendDeliveryAck('ack-now', NT_PEER_B),
      'the delivery ack sends');
    t.equalNumber(1, rig.published.length, 'the delivery ack publishes immediately');
    const ackEmbedded: EmbeddedBitChatMessage = ntUnwrapEmbedded(rig.published[0], bob);
    t.equalNumber(NoisePayloadType.DELIVERED, ackEmbedded.payload.type,
      'the immediate ack is a DELIVERED receipt');
    t.equalString('ack-now', ByteUtils.utf8Decode(ackEmbedded.payload.data),
      'the immediate ack carries the message ID');

    transport.sendReadReceipt('ack-throttled', NT_PEER_B);
    t.equalNumber(2, rig.published.length, 'the first read receipt sends immediately');
    t.equalNumber(0, transport.pendingReadReceiptCount(), 'the throttle queue is empty');
    t.equalNumber(1, rig.schedulerValue.tasks.length, 'the 350ms cooldown is scheduled');
    t.equalNumber(350, rig.schedulerValue.delays[0],
      'the cooldown matches the Android read-ack interval');
    const readEmbedded: EmbeddedBitChatMessage = ntUnwrapEmbedded(rig.published[1], bob);
    t.equalNumber(NoisePayloadType.READ_RECEIPT, readEmbedded.payload.type,
      'the throttled receipt is a READ receipt');
    t.equalString('ack-throttled', ByteUtils.utf8Decode(readEmbedded.payload.data),
      'the throttled receipt carries the message ID');

    transport.sendReadReceipt('ack-queued', NT_PEER_B);
    t.equalNumber(2, rig.published.length,
      'a second receipt inside the cooldown waits');
    t.equalNumber(1, transport.pendingReadReceiptCount(),
      'the second receipt is queued behind the cooldown');

    transport.cleanup();
    t.equalNumber(0, transport.pendingReadReceiptCount(),
      'cleanup drops the queued receipts');
    rig.schedulerValue.runLast();
    t.equalNumber(2, rig.published.length, 'a cleaned queue never emits');
  }
}
