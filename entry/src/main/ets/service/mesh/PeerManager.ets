/**
 * Peer table and presence lifecycle (US2, T024).
 *
 * Mirrors bitchat-android PeerManager.kt: tracks verified peers learned from
 * signature-verified ANNOUNCE packets, implements the SecurityGateDelegate
 * key lookups (signing/Noise keys learned from announcements), and enforces
 * the FR-008 presence windows: a verified contact keeps the peer reachable
 * for MeshConstants.PEER_REACHABLE_WINDOW_MS (60s); a peer with no contact
 * for MeshConstants.STALE_PEER_TIMEOUT_MS (180s) is evicted by the periodic
 * cleanup sweep (interval MeshConstants.PEER_CLEANUP_INTERVAL_MS, 60s).
 *
 * Deliberately free of device imports so the lifecycle is contract-testable
 * on the host. getAuthenticatedSigningKey returns null in phase 1: no peer
 * state is Noise-authenticated yet (the authenticated binding lands with the
 * Noise session manager), so the SecurityGate keeps its
 * announcement-key-learning semantics.
 */
import { IdentityAnnouncement, PeerCapabilities } from '../../model/IdentityModels';
import { MeshConstants } from '../../common/ProtocolConstants';
import { SecurityGateDelegate } from './SecurityGate';

export interface PeerManagerDelegate {
  onPeerListUpdated(peerIds: string[]): void;
  onPeerRemoved(peerId: string): void;
}

export class PeerInfo {
  readonly id: string;
  nickname: string;
  noisePublicKey: Uint8Array | null;
  signingPublicKey: Uint8Array | null;
  isVerified: boolean;
  lastSeenMs: number;
  /** Capability state from the signature-verified announce; null = signed old-format announce omitted TLV 0x05. */
  capabilities: PeerCapabilities | null;
  /** Direct neighbors gossiped in the peer's announce TLV 0x04 (empty when absent). */
  directNeighbors: string[];

  constructor(id: string, nickname: string, lastSeenMs: number) {
    this.id = id;
    this.nickname = nickname;
    this.noisePublicKey = null;
    this.signingPublicKey = null;
    this.isVerified = false;
    this.lastSeenMs = lastSeenMs;
    this.capabilities = null;
    this.directNeighbors = [];
  }
}

export class PeerManager implements SecurityGateDelegate {
  private readonly peers: Map<string, PeerInfo> = new Map();
  private readonly delegate: PeerManagerDelegate | null;
  private cleanupTimer: number = -1;

  constructor(delegate: PeerManagerDelegate | null) {
    this.delegate = delegate;
  }

  /** Start the periodic stale-peer cleanup sweep (60s interval). */
  start(): void {
    if (this.cleanupTimer >= 0) {
      return;
    }
    this.cleanupTimer = setInterval(() => {
      this.cleanupStalePeers();
    }, MeshConstants.PEER_CLEANUP_INTERVAL_MS);
  }

  stop(): void {
    if (this.cleanupTimer >= 0) {
      clearInterval(this.cleanupTimer);
      this.cleanupTimer = -1;
    }
  }

  /**
   * Apply a signature-verified announcement to the peer table. A null
   * capabilities value is meaningful (old-format signed announce); a null
   * directNeighbors value means the announce carried no TLV 0x04. Returns
   * true when this created a new verified peer.
   */
  updateFromVerifiedAnnouncement(peerId: string, announcement: IdentityAnnouncement,
    directNeighbors: string[] | null, nowMs: number): boolean {
    if (peerId === 'unknown') {
      return false;
    }
    const existing: PeerInfo | undefined = this.peers.get(peerId);
    const isNew: boolean = existing === undefined;
    let nicknameChanged: boolean = false;
    let noiseKeyChanged: boolean = false;
    let signingKeyChanged: boolean = false;
    let capabilitiesChanged: boolean = false;
    let neighborsChanged: boolean = false;
    if (existing !== undefined) {
      nicknameChanged = existing.nickname !== announcement.nickname;
      noiseKeyChanged = existing.noisePublicKey === null ||
        !PeerManager.bytesEqual(existing.noisePublicKey, announcement.noisePublicKey);
      signingKeyChanged = existing.signingPublicKey === null ||
        !PeerManager.bytesEqual(existing.signingPublicKey, announcement.signingPublicKey);
      capabilitiesChanged = !PeerCapabilities.equals(existing.capabilities, announcement.capabilities);
      neighborsChanged = !PeerManager.stringListsEqual(existing.directNeighbors,
        directNeighbors === null ? [] : directNeighbors);
    }
    let peer: PeerInfo;
    if (existing === undefined) {
      peer = new PeerInfo(peerId, announcement.nickname, nowMs);
    } else {
      peer = existing;
    }
    peer.nickname = announcement.nickname;
    peer.noisePublicKey = announcement.noisePublicKey.slice();
    peer.signingPublicKey = announcement.signingPublicKey.slice();
    peer.isVerified = true;
    peer.lastSeenMs = nowMs;
    peer.capabilities = announcement.capabilities;
    peer.directNeighbors = directNeighbors === null ? [] : directNeighbors.slice();
    this.peers.set(peerId, peer);
    if (isNew || nicknameChanged || noiseKeyChanged || signingKeyChanged || capabilitiesChanged ||
      neighborsChanged) {
      this.notifyPeerListUpdated();
    }
    return isNew;
  }

  /** Refresh the contact timestamp for a known peer (keeps reachable fresh). */
  touchPeer(peerId: string, nowMs: number): void {
    const peer: PeerInfo | undefined = this.peers.get(peerId);
    if (peer !== undefined) {
      peer.lastSeenMs = nowMs;
    }
  }

  /** Remove peers not contacted within the stale timeout (180s). */
  cleanupStalePeers(nowMs: number = Date.now()): void {
    const stale: string[] = [];
    this.peers.forEach((peer: PeerInfo): void => {
      if (nowMs - peer.lastSeenMs > MeshConstants.STALE_PEER_TIMEOUT_MS) {
        stale.push(peer.id);
      }
    });
    for (let i: number = 0; i < stale.length; i++) {
      this.removePeer(stale[i]);
    }
  }

  removePeer(peerId: string): void {
    const removed: PeerInfo | undefined = this.peers.get(peerId);
    if (removed === undefined) {
      return;
    }
    this.peers.delete(peerId);
    if (this.delegate !== null) {
      this.delegate.onPeerRemoved(peerId);
      this.delegate.onPeerListUpdated(this.getVerifiedPeerIds());
    }
  }

  clearAllPeers(): void {
    this.peers.clear();
    this.notifyPeerListUpdated();
  }

  isPeerVerified(peerId: string): boolean {
    const peer: PeerInfo | undefined = this.peers.get(peerId);
    return peer !== undefined && peer.isVerified;
  }

  /** True while the last verified contact is within the reachable window (60s). */
  isPeerReachable(peerId: string, nowMs: number = Date.now()): boolean {
    const peer: PeerInfo | undefined = this.peers.get(peerId);
    if (peer === undefined) {
      return false;
    }
    return nowMs - peer.lastSeenMs < MeshConstants.PEER_REACHABLE_WINDOW_MS;
  }

  getPeerInfo(peerId: string): PeerInfo | null {
    const peer: PeerInfo | undefined = this.peers.get(peerId);
    return peer === undefined ? null : peer;
  }

  getPeerNickname(peerId: string): string | null {
    const peer: PeerInfo | undefined = this.peers.get(peerId);
    return peer === undefined ? null : peer.nickname;
  }

  getVerifiedPeerIds(): string[] {
    const ids: string[] = [];
    this.peers.forEach((peer: PeerInfo): void => {
      if (peer.isVerified) {
        ids.push(peer.id);
      }
    });
    return ids.sort();
  }

  getPeerCount(): number {
    return this.peers.size;
  }

  // ------------------------------------------------------------------
  // SecurityGateDelegate
  // ------------------------------------------------------------------

  getPeerSigningKey(peerID: string): Uint8Array | null {
    const peer: PeerInfo | undefined = this.peers.get(peerID);
    if (peer === undefined || peer.signingPublicKey === null) {
      return null;
    }
    return peer.signingPublicKey;
  }

  getPeerNoiseKey(peerID: string): Uint8Array | null {
    const peer: PeerInfo | undefined = this.peers.get(peerID);
    if (peer === undefined || peer.noisePublicKey === null) {
      return null;
    }
    return peer.noisePublicKey;
  }

  getAuthenticatedSigningKey(noisePublicKey: Uint8Array): Uint8Array | null {
    // Phase 1: no Noise-authenticated peer state exists yet, so no signing
    // key is bound to an authenticated static key. The SecurityGate keeps
    // its announcement-key-learning/replacement semantics.
    return null;
  }

  // ------------------------------------------------------------------
  // Internals
  // ------------------------------------------------------------------

  private notifyPeerListUpdated(): void {
    if (this.delegate !== null) {
      this.delegate.onPeerListUpdated(this.getVerifiedPeerIds());
    }
  }

  private static bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (let i: number = 0; i < a.length; i++) {
      if (a[i] !== b[i]) {
        return false;
      }
    }
    return true;
  }

  private static stringListsEqual(a: string[], b: string[]): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (let i: number = 0; i < a.length; i++) {
      if (a[i] !== b[i]) {
        return false;
      }
    }
    return true;
  }
}
