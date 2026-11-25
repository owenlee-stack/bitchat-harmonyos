/**
 * Contract tests for the T028 announce-topology source routing (FR-033):
 * - shallow topology from ANNOUNCE neighbor TLV 0x04 with 60s freshness
 *   (boundary inclusive, stale edges unroutable, prune drops them)
 * - bidirectional confirmation required for the 2-hop route me -> X -> target
 * - direct targets need no route; unknown targets fall back to flooding (null)
 * - deterministic intermediate choice (lowest peer ID) among candidates
 * - TLV-less announces never clobber an existing claim
 * - Android-relay next-hop resolution: my-id lookup, following hop, recipient
 *   fallback after the last intermediate, duplicate-hop loop guard
 */
import { ContractAssert } from './ContractAssert';
import { TopologyMap } from '../../main/ets/service/mesh/TopologyMap';
import { GossipTlv } from '../../main/ets/service/mesh/GossipTlv';
import { ByteUtils } from '../../main/ets/common/ByteUtils';

function claimPayloadFor(peerIds: string[]): Uint8Array {
  return GossipTlv.encodeNeighbors(peerIds);
}

export function runTopologyMapContractTests(t: ContractAssert): void {
  const myPeerID: string = '0011223344556677';
  const peerA: string = 'aabbccddeeff0011';
  const peerB: string = 'bbbbcccddeeeff00';
  const peerT: string = '0123456789abcdef';

  // ------------------------------------------------------------------
  // Direct target needs no route; unknown target falls back to flooding.
  // ------------------------------------------------------------------
  const map0: TopologyMap = new TopologyMap(myPeerID);
  map0.recordDirectLink(peerA, 1000);
  t.isTrue(map0.isDirectNeighbor(peerA, 2000), 'recorded link is a direct neighbor');
  const directRoute: Uint8Array[] | null = map0.computeSourceRoute(peerA, 2000);
  t.isNotNull(directRoute, 'direct target yields a route object');
  if (directRoute !== null) {
    t.equalNumber(0, directRoute.length, 'direct target needs no route hops');
  }
  t.isNull(map0.computeSourceRoute(peerT, 2000), 'unknown target falls back to flooding');
  const selfRoute: Uint8Array[] | null = map0.computeSourceRoute(myPeerID, 2000);
  t.isNotNull(selfRoute, 'self target yields a route object');
  if (selfRoute !== null) {
    t.equalNumber(0, selfRoute.length, 'self target needs no route');
  }

  // ------------------------------------------------------------------
  // Bidirectionally confirmed 2-hop route: me -> A -> T.
  // ------------------------------------------------------------------
  const base: number = 10000;
  const map: TopologyMap = new TopologyMap(myPeerID);
  map.recordDirectLink(peerA, base);
  map.onAnnouncePayload(peerA, claimPayloadFor([peerT]), base);
  map.onAnnouncePayload(peerT, claimPayloadFor([peerA]), base);
  t.equalString(peerT, map.getClaimedNeighbors(peerA, base).join(','),
    'A freshly claims T');
  t.equalString(peerA, map.getClaimedNeighbors(peerT, base).join(','),
    'T freshly claims A');
  const route: Uint8Array[] | null = map.computeSourceRoute(peerT, base + 100);
  t.isNotNull(route, 'confirmed 2-hop path yields a source route');
  if (route !== null) {
    t.equalNumber(2, route.length, 'source route is [myId, intermediate]');
    t.equalString(myPeerID, ByteUtils.bytesToHex(route[0]), 'route starts at my ID');
    t.equalString(peerA, ByteUtils.bytesToHex(route[1]), 'route runs through the intermediate');
  }

  // ------------------------------------------------------------------
  // One-sided claims are not confirmed: flood fallback.
  // ------------------------------------------------------------------
  const oneSided: TopologyMap = new TopologyMap(myPeerID);
  oneSided.recordDirectLink(peerA, base);
  oneSided.onAnnouncePayload(peerA, claimPayloadFor([peerT]), base);
  t.isNull(oneSided.computeSourceRoute(peerT, base + 100),
    'target must claim the intermediate back');

  // ------------------------------------------------------------------
  // Freshness: 60s inclusive boundary, stale claims and links unroutable.
  // ------------------------------------------------------------------
  t.isNotNull(map.computeSourceRoute(peerT, base + 60000),
    'edge stays fresh at exactly 60s');
  t.isNull(map.computeSourceRoute(peerT, base + 60001),
    'edge is stale past 60s');
  const staleLink: TopologyMap = new TopologyMap(myPeerID);
  staleLink.recordDirectLink(peerA, base);
  staleLink.onAnnouncePayload(peerA, claimPayloadFor([peerT]), base);
  staleLink.onAnnouncePayload(peerT, claimPayloadFor([peerA]), base);
  // Refresh claims but leave the direct link stale: intermediate must stay
  // connected to me.
  staleLink.onAnnouncePayload(peerA, claimPayloadFor([peerT]), base + 60000);
  staleLink.onAnnouncePayload(peerT, claimPayloadFor([peerA]), base + 60000);
  t.isNull(staleLink.computeSourceRoute(peerT, base + 60001),
    'stale direct link cannot serve as intermediate');
  t.equalNumber(0, map.getClaimedNeighbors(peerA, base + 60001).length,
    'stale claim lists no neighbors');

  // ------------------------------------------------------------------
  // TLV-less announce never clobbers an existing claim.
  // ------------------------------------------------------------------
  const noTlvPayload: Uint8Array = new Uint8Array([0x05, 0x00]); // unrelated TLV
  map.onAnnouncePayload(peerA, noTlvPayload, base + 200);
  t.equalString(peerT, map.getClaimedNeighbors(peerA, base + 300).join(','),
    'claim survives a TLV-less announce');

  // ------------------------------------------------------------------
  // Deterministic intermediate: lowest peer ID among candidates.
  // ------------------------------------------------------------------
  const multi: TopologyMap = new TopologyMap(myPeerID);
  multi.recordDirectLink(peerA, base);
  multi.recordDirectLink(peerB, base);
  multi.onAnnouncePayload(peerA, claimPayloadFor([peerT]), base);
  multi.onAnnouncePayload(peerB, claimPayloadFor([peerT]), base);
  multi.onAnnouncePayload(peerT, claimPayloadFor([peerA, peerB]), base);
  const multiRoute: Uint8Array[] | null = multi.computeSourceRoute(peerT, base + 100);
  t.isNotNull(multiRoute, 'multiple confirmed candidates still route');
  if (multiRoute !== null) {
    t.equalString(peerA, ByteUtils.bytesToHex(multiRoute[1]),
      'lowest peer ID wins the intermediate slot');
  }

  // removeDirectLink drops the edge entirely.
  multi.removeDirectLink(peerA);
  t.isFalse(multi.isDirectNeighbor(peerA, base + 100), 'removed link is no longer direct');

  // ------------------------------------------------------------------
  // prune drops stale claims and links.
  // ------------------------------------------------------------------
  t.equalNumber(1, multi.getDirectLinkCount(base + 100), 'one fresh link remains after removal');
  multi.recordDirectLink(peerA, base + 100); // restore A
  const later: number = base + 60001;
  t.equalNumber(3, multi.getClaimedPeerCount(later - 1), 'claims fresh before prune boundary');
  multi.prune(later);
  t.equalNumber(0, multi.getClaimedPeerCount(later), 'prune drops stale claims');
  t.equalNumber(1, multi.getDirectLinkCount(later), 'prune drops stale links, refreshed one survives');

  // ------------------------------------------------------------------
  // Next-hop resolution (Android source-route relay semantics).
  // ------------------------------------------------------------------
  const myIdBytes: Uint8Array = ByteUtils.hexToBytes(myPeerID);
  const aBytes: Uint8Array = ByteUtils.hexToBytes(peerA);
  const tBytes: Uint8Array = ByteUtils.hexToBytes(peerT);
  const routeBytes: Uint8Array[] = [myIdBytes, aBytes];

  // Sender-side: after me comes the intermediate A.
  const senderHop: string | null = TopologyMap.resolveNextHop(routeBytes, myPeerID, tBytes);
  t.isNotNull(senderHop, 'sender resolves a next hop');
  if (senderHop !== null) {
    t.equalString(peerA, senderHop, 'sender resolves the intermediate as next hop');
  }
  // Intermediate A is last in route: fall back to the recipient T.
  const lastHop: string | null = TopologyMap.resolveNextHop(routeBytes, peerA, tBytes);
  t.isNotNull(lastHop, 'last intermediate resolves a next hop');
  if (lastHop !== null) {
    t.equalString(peerT, lastHop, 'last intermediate falls back to the recipient');
  }
  // Explicit following hop when the route continues.
  const longRoute: Uint8Array[] = [myIdBytes, aBytes, tBytes];
  const midHop: string | null = TopologyMap.resolveNextHop(longRoute, peerA, tBytes);
  t.isNotNull(midHop, 'route-internal node resolves a next hop');
  if (midHop !== null) {
    t.equalString(peerT, midHop, 'route-internal hop preferred over the recipient');
  }
  // Not our route.
  t.isNull(TopologyMap.resolveNextHop(routeBytes, peerB, tBytes),
    'a node absent from the route has no next hop');
  // Last intermediate with a broadcast recipient cannot resolve.
  t.isNull(TopologyMap.resolveNextHop(routeBytes, peerA, null),
    'last intermediate without recipient falls back to flooding');

  // Duplicate-hop loop guard.
  t.isTrue(TopologyMap.hasDuplicateHops([aBytes, aBytes]), 'duplicate hops detected');
  t.isFalse(TopologyMap.hasDuplicateHops([myIdBytes, aBytes]), 'distinct hops pass');
  t.isFalse(TopologyMap.hasDuplicateHops([]), 'empty route has no duplicates');
}
