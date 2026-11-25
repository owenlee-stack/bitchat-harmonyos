/**
 * Contract tests for the T024 announcement layer (FR-008):
 * - GossipTlv golden vectors ([type=0x04][len][value], <=10 unique neighbors,
 *   lenient hex parsing, TLV scanning, trailing-bytes tolerance)
 * - PeerManager presence lifecycle (reachable 60s window, stale 180s
 *   eviction, SecurityGateDelegate key lookups, delegate notifications)
 * All times are injected explicitly so no timers run on the host.
 */
import { ContractAssert } from './ContractAssert';
import { GossipTlv } from '../../main/ets/service/mesh/GossipTlv';
import { PeerManager } from '../../main/ets/service/mesh/PeerManager';
import { PeerManagerDelegate } from '../../main/ets/service/mesh/PeerManager';
import { IdentityAnnouncement, PeerCapabilities } from '../../main/ets/model/IdentityModels';

function filledArray(length: number, seed: number): Uint8Array {
  const out: Uint8Array = new Uint8Array(length);
  for (let i: number = 0; i < length; i++) {
    out[i] = (seed + i) & 0xFF;
  }
  return out;
}

function must<T>(value: T | null, label: string): T {
  if (value === null) {
    throw new Error('unexpected null: ' + label);
  }
  return value;
}

export function runAnnounceContractTests(t: ContractAssert): void {
  // ------------------------------------------------------------------
  // GossipTlv.encodeNeighbors golden vector (FR-008 TLV 0x04).
  // ------------------------------------------------------------------
  const golden: Uint8Array = GossipTlv.encodeNeighbors(['0011223344556677']);
  t.equalNumber(10, golden.length, 'single neighbor TLV is 2 + 8 bytes');
  t.equalBytes(new Uint8Array([0x04, 0x08, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]),
    golden, 'single neighbor golden vector');

  // Empty list still emits the TLV with zero length (Android layout).
  t.equalBytes(new Uint8Array([0x04, 0x00]), GossipTlv.encodeNeighbors([]),
    'empty neighbor list emits [0x04][0x00]');

  // Duplicates collapse; cap at 10 neighbors (12 unique ids -> 10*8 = 80 bytes).
  const deduped: Uint8Array = GossipTlv.encodeNeighbors(['0011223344556677', '0011223344556677']);
  t.equalNumber(10, deduped.length, 'duplicate neighbor ids collapse');
  const ids: string[] = [];
  for (let i: number = 0; i < 12; i++) {
    ids.push('000000000000000' + i.toString(16));
  }
  const capped: Uint8Array = GossipTlv.encodeNeighbors(ids);
  t.equalNumber(82, capped.length, '12 ids capped to 10 neighbors (2 + 80 bytes)');
  t.equalNumber(80, capped[1], 'capped value length byte is 80');
  const cappedNeighbors: string[] =
    must(GossipTlv.decodeNeighborsFromAnnouncementPayload(capped), 'capped neighbors');
  t.equalNumber(10, cappedNeighbors.length, 'exactly 10 neighbors kept');
  t.equalString('0000000000000009', cappedNeighbors[9], 'first 10 ids kept in order');

  // Lenient parsing: invalid digits become 0, ids truncate to 8 bytes, hex is
  // case-insensitive (Android parser semantics).
  t.equalBytes(new Uint8Array([0x04, 0x08, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]),
    GossipTlv.encodeNeighbors(['00112233445566778899']), 'oversized id truncates to 8 bytes');
  t.equalBytes(new Uint8Array([0x04, 0x08, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11]),
    GossipTlv.encodeNeighbors(['AABBCCDDEEFF0011']), 'uppercase hex accepted');
  t.equalBytes(new Uint8Array([0x04, 0x08, 0, 0, 0, 0, 0, 0, 0, 0]),
    GossipTlv.encodeNeighbors(['zz']), 'invalid hex digits parse as zero bytes');

  // ------------------------------------------------------------------
  // GossipTlv.decodeNeighborsFromAnnouncementPayload scanning.
  // ------------------------------------------------------------------
  const noiseKey: Uint8Array = filledArray(32, 1);
  const signingKey: Uint8Array = filledArray(32, 0x41);
  const announcement: IdentityAnnouncement =
    IdentityAnnouncement.forLocalPeer('alice', noiseKey, signingKey);
  const encoded: Uint8Array = must(announcement.encode(), 'announcement encode');

  // Absent TLV 0x04 -> null.
  t.isNull(GossipTlv.decodeNeighborsFromAnnouncementPayload(encoded),
    'announcement without neighbors TLV decodes to null');

  // Appended after the announcement TLVs: scanning past other TLVs finds it.
  const appended: Uint8Array = new Uint8Array(encoded.length + 10);
  appended.set(encoded, 0);
  appended.set(GossipTlv.encodeNeighbors(['0011223344556677']), encoded.length);
  const scanned: string[] =
    must(GossipTlv.decodeNeighborsFromAnnouncementPayload(appended), 'appended neighbors');
  t.equalNumber(1, scanned.length, 'one neighbor decoded from appended TLV');
  t.equalString('0011223344556677', scanned[0], 'neighbor id round-trips');

  // Manual payload: [0x01][len 3][abc][0x04][len 10][8 id bytes][2 trailing]
  // - the two trailing value bytes are ignored (trailing-bytes tolerance).
  const manual: Uint8Array = new Uint8Array([
    0x01, 0x03, 0x61, 0x62, 0x63,
    0x04, 0x0A, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0xDE, 0xAD
  ]);
  const trailing: string[] =
    must(GossipTlv.decodeNeighborsFromAnnouncementPayload(manual), 'manual payload neighbors');
  t.equalNumber(1, trailing.length, 'trailing partial bytes ignored');
  t.equalString('0011223344556677', trailing[0], 'neighbor id from manual payload');

  // Partial peer ID (value shorter than 8 bytes) -> present but empty list.
  const partial: Uint8Array = new Uint8Array([0x04, 0x04, 0x00, 0x11, 0x22, 0x33]);
  const partialNeighbors: string[] =
    must(GossipTlv.decodeNeighborsFromAnnouncementPayload(partial), 'partial-id neighbors');
  t.equalNumber(0, partialNeighbors.length, 'partial id yields no neighbors');

  // ------------------------------------------------------------------
  // PeerManager lifecycle.
  // ------------------------------------------------------------------
  class CountingDelegate implements PeerManagerDelegate {
    updatedCount: number = 0;
    removedPeerIds: string[] = [];

    onPeerListUpdated(peerIds: string[]): void {
      this.updatedCount += 1;
    }

    onPeerRemoved(peerId: string): void {
      this.removedPeerIds.push(peerId);
    }
  }

  const delegate: CountingDelegate = new CountingDelegate();
  const manager: PeerManager = new PeerManager(delegate);
  const peerId: string = '0011223344556677';

  // Unknown sentinel peer IDs never enter the table.
  t.isFalse(manager.updateFromVerifiedAnnouncement('unknown', announcement, null, 1000),
    'unknown sentinel peer rejected');

  // New verified peer.
  t.isTrue(manager.updateFromVerifiedAnnouncement(peerId, announcement, null, 1000),
    'first announcement creates a new peer');
  t.equalNumber(1, delegate.updatedCount, 'peer list update notified once');
  t.isTrue(manager.isPeerVerified(peerId), 'peer is verified');
  t.equalString('alice', must(manager.getPeerNickname(peerId), 'nickname'), 'nickname learned');

  // Re-announcement without changes is not a new peer and stays silent.
  t.isFalse(manager.updateFromVerifiedAnnouncement(peerId, announcement, null, 2000),
    'unchanged announcement is not a new peer');
  t.equalNumber(1, delegate.updatedCount, 'unchanged announcement notifies nothing');

  // SecurityGateDelegate key lookups learn from the announcement.
  t.equalBytes(signingKey, must(manager.getPeerSigningKey(peerId), 'peer signing key'),
    'signing key learned');
  t.equalBytes(noiseKey, must(manager.getPeerNoiseKey(peerId), 'peer noise key'),
    'noise key learned');
  t.isNull(manager.getAuthenticatedSigningKey(noiseKey),
    'phase 1 has no Noise-authenticated signing key');
  t.isNull(manager.getPeerSigningKey('ffffffffffffffff'), 'unknown peer has no signing key');

  // Capabilities from the signed announce are retained.
  const info = must(manager.getPeerInfo(peerId), 'peer info');
  t.equalNumber(PeerCapabilities.PRIVATE_MEDIA.rawValue,
    must(info.capabilities, 'peer capabilities').rawValue, 'capabilities learned from announcement');

  // Reachable window: 60s boundary (lastSeenMs = 2000 after second update).
  t.isTrue(manager.isPeerReachable(peerId, 2000 + 59999), 'reachable at 59999ms');
  t.isFalse(manager.isPeerReachable(peerId, 2000 + 60000), 'unreachable at 60000ms');
  t.isFalse(manager.isPeerReachable('ffffffffffffffff', 2000), 'unknown peer never reachable');

  // Touch extends the reachable window.
  manager.touchPeer(peerId, 30000);
  t.isTrue(manager.isPeerReachable(peerId, 30000 + 59999), 'touch extends reachability');

  // Stale cleanup: 180s boundary (lastSeenMs = 30000).
  manager.cleanupStalePeers(30000 + 180000);
  t.isTrue(manager.isPeerVerified(peerId), 'peer kept at exactly 180s');
  manager.cleanupStalePeers(30000 + 180001);
  t.isFalse(manager.isPeerVerified(peerId), 'peer evicted past 180s');
  t.equalNumber(1, delegate.removedPeerIds.length, 'removal notified');
  t.equalString(peerId, delegate.removedPeerIds[0], 'removed peer id notified');
  t.equalNumber(2, delegate.updatedCount, 'eviction notifies peer list');
  t.isNull(manager.getPeerSigningKey(peerId), 'evicted peer has no signing key');

  // Nickname change re-notifies; direct neighbors are stored and cleared.
  const bobAnnouncement: IdentityAnnouncement =
    IdentityAnnouncement.forLocalPeer('bob', noiseKey, signingKey);
  t.isTrue(manager.updateFromVerifiedAnnouncement(peerId, bobAnnouncement, ['9988776655443322'], 40000),
    're-learned peer is new again after eviction');
  t.equalNumber(3, delegate.updatedCount, 'nickname change notifies peer list');
  const relearned = must(manager.getPeerInfo(peerId), 'relearned peer info');
  t.equalNumber(1, relearned.directNeighbors.length, 'direct neighbors stored');
  t.equalString('9988776655443322', relearned.directNeighbors[0], 'direct neighbor id stored');
  manager.updateFromVerifiedAnnouncement(peerId, bobAnnouncement, null, 41000);
  t.equalNumber(0, must(manager.getPeerInfo(peerId), 'peer info after clear').directNeighbors.length,
    'absent neighbors TLV clears the list');

  // Verified id list is sorted.
  manager.updateFromVerifiedAnnouncement('ffffffffffffffff',
    IdentityAnnouncement.forLocalPeer('carol', noiseKey, signingKey), null, 42000);
  const verified: string[] = manager.getVerifiedPeerIds();
  t.equalNumber(2, verified.length, 'two verified peers');
  t.equalString('0011223344556677', verified[0], 'verified ids sorted (first)');
  t.equalString('ffffffffffffffff', verified[1], 'verified ids sorted (second)');

  // clearAllPeers empties the table.
  manager.clearAllPeers();
  t.equalNumber(0, manager.getPeerCount(), 'clearAllPeers empties the table');
  t.equalNumber(0, manager.getVerifiedPeerIds().length, 'no verified peers after clear');
}
