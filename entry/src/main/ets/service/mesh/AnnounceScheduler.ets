/**
 * Event-driven ANNOUNCE scheduler (US2, T024).
 *
 * Mirrors the bitchat announcement cadence (FR-008): announcements are
 * event-driven - an immediate announce when a peer link establishes or when
 * our identity material changes - plus a background cadence that broadcasts
 * every 4s while isolated (no connected peers) and backs off to 15-30s with
 * jitter once links exist. Each announce is the iOS-compatible signed TLV
 * payload (IdentityAnnouncement: nickname 0x01 / Noise key 0x02 / Ed25519
 * key 0x03 / capabilities 0x05) with the gossip TLV 0x04 appended when we
 * have direct neighbors, TTL = PkTtl.MESSAGE_TTL_HOPS, Ed25519 signature
 * over the canonical packet.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BitchatPacket, MessageType } from '../../model/BitchatPacket';
import { IdentityAnnouncement } from '../../model/IdentityModels';
import { PkTtl } from '../../common/ProtocolConstants';
import { ByteUtils } from '../../common/ByteUtils';
import { BinaryProtocol } from '../protocol/BinaryProtocol';
import { GossipTlv } from './GossipTlv';

const DOMAIN = 0x0000;
const TAG = 'AnnounceScheduler';

/** Isolated cadence: broadcast every 4s (FR-008). */
const ISOLATED_INTERVAL_MS = 4000;
/** Connected cadence: 15s base + up to 15s jitter (FR-008). */
const CONNECTED_BASE_INTERVAL_MS = 15000;
const CONNECTED_JITTER_MS = 15000;

/** Identity material and broadcast sink injected by the mesh facade. */
export interface AnnounceSchedulerDelegate {
  getNickname(): string;
  getNoisePublicKey(): Uint8Array | null;
  getSigningPublicKey(): Uint8Array | null;
  /** Ed25519 signature over the packet's canonical signing preimage. */
  signAnnouncementData(data: Uint8Array): Promise<Uint8Array | null>;
  /** Direct-neighbor peerIDs for the gossip TLV 0x04 (may be empty). */
  getDirectNeighborPeerIds(): string[];
  /** Broadcast a fully built announce packet over the active transport(s). */
  broadcastAnnouncePacket(packet: BitchatPacket): boolean;
  /** True while at least one peer link is established. */
  hasConnectedPeers(): boolean;
}

export class AnnounceScheduler {
  private readonly myPeerId: string;
  private readonly delegate: AnnounceSchedulerDelegate;

  private running: boolean = false;
  private timerId: number = -1;
  private building: boolean = false;

  constructor(myPeerId: string, delegate: AnnounceSchedulerDelegate) {
    this.myPeerId = myPeerId;
    this.delegate = delegate;
  }

  isRunning(): boolean {
    return this.running;
  }

  start(): void {
    if (this.running) {
      return;
    }
    this.running = true;
    this.scheduleNextAnnounce();
    hilog.info(DOMAIN, TAG, '%{public}s', 'announce scheduler started');
  }

  stop(): void {
    if (!this.running) {
      return;
    }
    this.running = false;
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
    hilog.info(DOMAIN, TAG, '%{public}s', 'announce scheduler stopped');
  }

  /** Event-driven: a peer link just established; announce immediately. */
  onPeerConnected(): void {
    if (!this.running) {
      return;
    }
    this.sendAnnounceNow();
    this.scheduleNextAnnounce();
  }

  /** Event-driven: a link dropped; recompute the cadence. */
  onPeerDisconnected(): void {
    if (!this.running) {
      return;
    }
    this.scheduleNextAnnounce();
  }

  /** Event-driven: nickname or key material changed; announce immediately. */
  onIdentityChanged(): void {
    if (!this.running) {
      return;
    }
    this.sendAnnounceNow();
    this.scheduleNextAnnounce();
  }

  /** Build, sign and broadcast one ANNOUNCE packet. */
  async sendAnnounceNow(): Promise<void> {
    if (this.building) {
      return;
    }
    this.building = true;
    try {
      const nickname: string = this.delegate.getNickname();
      const noisePublicKey: Uint8Array | null = this.delegate.getNoisePublicKey();
      const signingPublicKey: Uint8Array | null = this.delegate.getSigningPublicKey();
      if (noisePublicKey === null || signingPublicKey === null) {
        hilog.warn(DOMAIN, TAG, '%{public}s', 'identity keys unavailable, announce skipped');
        return;
      }
      const announcement: IdentityAnnouncement =
        IdentityAnnouncement.forLocalPeer(nickname, noisePublicKey, signingPublicKey);
      const encoded: Uint8Array | null = announcement.encode();
      if (encoded === null) {
        hilog.warn(DOMAIN, TAG, '%{public}s', 'announcement TLV encode failed');
        return;
      }
      let payload: Uint8Array = encoded;
      const neighbors: string[] = this.delegate.getDirectNeighborPeerIds();
      if (neighbors.length > 0) {
        payload = ByteUtils.concat(payload, GossipTlv.encodeNeighbors(neighbors));
      }
      const packet: BitchatPacket = new BitchatPacket(1, MessageType.ANNOUNCE,
        ByteUtils.hexToBytes(this.myPeerId), null, Date.now(), payload, null,
        PkTtl.MESSAGE_TTL_HOPS, null);
      const dataToSign: Uint8Array | null = BinaryProtocol.toBinaryDataForSigning(packet);
      if (dataToSign !== null) {
        const signature: Uint8Array | null = await this.delegate.signAnnouncementData(dataToSign);
        if (signature !== null) {
          packet.signature = signature;
        }
      }
      this.delegate.broadcastAnnouncePacket(packet);
    } finally {
      this.building = false;
    }
  }

  // ------------------------------------------------------------------
  // Internals
  // ------------------------------------------------------------------

  private scheduleNextAnnounce(): void {
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
    if (!this.running) {
      return;
    }
    const interval: number = this.delegate.hasConnectedPeers()
      ? CONNECTED_BASE_INTERVAL_MS + Math.floor(Math.random() * CONNECTED_JITTER_MS)
      : ISOLATED_INTERVAL_MS;
    this.timerId = setTimeout(() => {
      this.timerId = -1;
      if (!this.running) {
        return;
      }
      this.sendAnnounceNow();
      this.scheduleNextAnnounce();
    }, interval);
  }
}
