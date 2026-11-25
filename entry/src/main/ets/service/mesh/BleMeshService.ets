/**
 * BLE transport coordinator (US2, T023).
 *
 * Mirrors bitchat-android BluetoothConnectionManager: composes the GATT
 * server (peripheral) and client (central) roles behind the Transport
 * abstraction, keeps one connection ledger across both roles, learns the
 * stable peerID per device address, drives scan-discovery -> connect with
 * the retry policy from MeshConstants (5s delay / 3 attempts / max 8
 * connections), and integrates the send chain:
 *
 * - send: FragmentManager.createFragments -> BinaryProtocol.encode (BLE
 *   padding policy: only Noise frames are padded) -> targeted or fan-out
 *   delivery over every link.
 * - receive: decoded packets are handed raw to the TransportDelegate with
 *   their link provenance. Ingress processing (security validation,
 *   reassembly, announce/message handling, relay decisions) is owned by the
 *   PacketProcessor pipeline (T026, D4) in the composition root, not the
 *   transport - the GATT callback only routes.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GattServer, GattServerDelegate } from './GattServer';
import { GattClient, GattClientDelegate, ClientLink } from './GattClient';
import { FragmentManager } from './FragmentManager';
import { Transport, TransportDelegate } from './Transport';
import { BinaryProtocol } from '../protocol/BinaryProtocol';
import { BitchatPacket, MessageType } from '../../model/BitchatPacket';
import { MeshConstants } from '../../common/ProtocolConstants';

const DOMAIN = 0x0000;
const TAG = 'BleMeshService';

/** One GATT-level link in the coordinator's ledger, either role. */
class MeshLinkEntry {
  readonly deviceId: string;
  readonly linkId: string;
  readonly connectedAtMs: number;
  peerId: string | null;

  constructor(deviceId: string, linkId: string, connectedAtMs: number) {
    this.deviceId = deviceId;
    this.linkId = linkId;
    this.connectedAtMs = connectedAtMs;
    this.peerId = null;
  }
}

/** Client-connect retry state per discovered device. */
class ConnectAttempt {
  attempts: number;
  nextAttemptAtMs: number;

  constructor(attempts: number, nextAttemptAtMs: number) {
    this.attempts = attempts;
    this.nextAttemptAtMs = nextAttemptAtMs;
  }
}

export class BleMeshService implements Transport, GattServerDelegate, GattClientDelegate {
  private readonly myPeerId: string;
  private readonly delegate: TransportDelegate | null;

  private readonly gattServer: GattServer;
  private readonly gattClient: GattClient;
  private readonly fragmentManager: FragmentManager;

  /** Connection ledger across both roles, keyed by deviceId. */
  private readonly links: Map<string, MeshLinkEntry> = new Map();
  /** device address -> stable peerID learned on the current link generation. */
  private readonly devicePeerMap: Map<string, string> = new Map();
  /** Client-connect retry ledger (5s / 3 attempts). */
  private readonly connectAttempts: Map<string, ConnectAttempt> = new Map();

  private active: boolean = false;

  constructor(myPeerId: string, delegate: TransportDelegate | null) {
    this.myPeerId = myPeerId;
    this.delegate = delegate;
    this.fragmentManager = new FragmentManager();
    this.gattServer = new GattServer(myPeerId, this);
    this.gattClient = new GattClient(this);
  }

  isActive(): boolean {
    return this.active;
  }

  getConnectedDeviceCount(): number {
    return this.links.size;
  }

  isPeerConnected(peerId: string): boolean {
    let found: boolean = false;
    this.links.forEach((entry: MeshLinkEntry): void => {
      if (entry.peerId === peerId) {
        found = true;
      }
    });
    return found;
  }

  getPeerIdForDevice(deviceId: string): string | null {
    const entry: MeshLinkEntry | undefined = this.links.get(deviceId);
    if (entry !== undefined && entry.peerId !== null) {
      return entry.peerId;
    }
    const mapped: string | undefined = this.devicePeerMap.get(deviceId);
    return mapped === undefined ? null : mapped;
  }

  // ------------------------------------------------------------------
  // Transport
  // ------------------------------------------------------------------

  start(): boolean {
    if (this.active) {
      return true;
    }
    this.active = true;
    if (!this.gattServer.start()) {
      this.active = false;
      return false;
    }
    this.gattClient.startScanning();
    hilog.info(DOMAIN, TAG, '%{public}s', 'ble mesh service started');
    return true;
  }

  stop(): void {
    if (!this.active) {
      return;
    }
    this.active = false;
    this.gattClient.stop();
    this.gattServer.stop();
    this.links.clear();
    this.devicePeerMap.clear();
    this.connectAttempts.clear();
    hilog.info(DOMAIN, TAG, '%{public}s', 'ble mesh service stopped');
  }

  /**
   * Send a packet: fragment to fit BLE limits, encode each fragment with the
   * iOS-compatible padding policy (only Noise frames padded), then deliver
   * to the recipient's links (targeted) or to every link (broadcast).
   */
  send(packet: BitchatPacket, recipientPeerId?: string): boolean {
    if (!this.active) {
      return false;
    }
    const fragments: BitchatPacket[] = this.fragmentManager.createFragments(packet);
    if (fragments.length === 0) {
      return false;
    }
    const recipient: string | null = recipientPeerId === undefined ? null : recipientPeerId;
    const targets: string[] = this.resolveTargets(recipient);
    if (targets.length === 0) {
      return false;
    }
    let anySent: boolean = false;
    for (let i: number = 0; i < fragments.length; i++) {
      const fragment: BitchatPacket = fragments[i];
      const encoded: Uint8Array | null =
        BinaryProtocol.encode(fragment, BleMeshService.shouldPadForBle(fragment.type));
      if (encoded === null) {
        continue;
      }
      for (let j: number = 0; j < targets.length; j++) {
        if (this.sendRawToDevice(targets[j], encoded)) {
          anySent = true;
        }
      }
    }
    return anySent;
  }

  // ------------------------------------------------------------------
  // GattServerDelegate / GattClientDelegate
  // ------------------------------------------------------------------

  onPeerDiscovered(deviceId: string, rssi: number, peerId: string | null): void {
    if (!this.active) {
      return;
    }
    if (this.links.has(deviceId)) {
      return;
    }
    if (this.links.size >= MeshConstants.MAX_CONNECTIONS) {
      return;
    }
    if (peerId !== null && this.isPeerConnected(peerId)) {
      return;
    }
    const now: number = Date.now();
    const attempt: ConnectAttempt | undefined = this.connectAttempts.get(deviceId);
    if (attempt !== undefined) {
      if (attempt.attempts >= MeshConstants.MAX_CONNECTION_ATTEMPTS) {
        return;
      }
      if (now < attempt.nextAttemptAtMs) {
        return;
      }
    }
    if (this.gattClient.connectDevice(deviceId, peerId)) {
      const attempts: number = attempt === undefined ? 1 : attempt.attempts + 1;
      this.connectAttempts.set(deviceId,
        new ConnectAttempt(attempts, now + MeshConstants.CONNECTION_RETRY_DELAY_MS));
    }
  }

  onPeerConnected(deviceId: string, linkId: string): void {
    const previous: MeshLinkEntry | undefined = this.links.get(deviceId);
    if (previous !== undefined && previous.linkId === linkId) {
      return;
    }
    // Client-role links already know the peerID from the scan response;
    // server-role links stay null until the first packet.
    let peerId: string | null = null;
    const clientLink: ClientLink | null = this.gattClient.getLink(deviceId);
    if (clientLink !== null && clientLink.linkId === linkId) {
      peerId = clientLink.peerId;
    }
    const entry: MeshLinkEntry = new MeshLinkEntry(deviceId, linkId, Date.now());
    entry.peerId = peerId;
    this.links.set(deviceId, entry);
    if (peerId !== null) {
      this.devicePeerMap.set(deviceId, peerId);
    }
    this.connectAttempts.delete(deviceId);
    hilog.info(DOMAIN, TAG, 'link established: %{public}s', deviceId);
    if (this.delegate !== null) {
      this.delegate.onPeerConnected(peerId, deviceId, linkId);
    }
  }

  onPeerDisconnected(deviceId: string, linkId: string): void {
    const entry: MeshLinkEntry | undefined = this.links.get(deviceId);
    if (entry === undefined) {
      return;
    }
    if (entry.linkId !== linkId) {
      // Stale event from a replaced link generation.
      return;
    }
    this.links.delete(deviceId);
    this.devicePeerMap.delete(deviceId);
    hilog.info(DOMAIN, TAG, 'link dropped: %{public}s', deviceId);
    if (this.delegate !== null) {
      this.delegate.onPeerDisconnected(entry.peerId, deviceId, linkId);
    }
  }

  /** IDs of all currently connected transport links (either GATT role). */
  getConnectedLinkIds(): string[] {
    const ids: string[] = [];
    this.links.forEach((entry: MeshLinkEntry): void => {
      ids.push(entry.linkId);
    });
    return ids;
  }

  /** PeerIDs of connected links whose identity is already learned. */
  getConnectedPeerIds(): string[] {
    const ids: string[] = [];
    this.links.forEach((entry: MeshLinkEntry): void => {
      if (entry.peerId !== null) {
        ids.push(entry.peerId);
      }
    });
    return ids;
  }

  /** Relay a packet out on exactly one link (PacketRelayDelegate, T027). */
  sendOnLink(linkId: string, packet: BitchatPacket): boolean {
    if (!this.active) {
      return false;
    }
    const deviceId: string | null = this.findDeviceIdByLinkId(linkId);
    if (deviceId === null) {
      return false;
    }
    const fragments: BitchatPacket[] = this.fragmentManager.createFragments(packet);
    if (fragments.length === 0) {
      return false;
    }
    let sent: boolean = false;
    for (let i: number = 0; i < fragments.length; i++) {
      const encoded: Uint8Array | null =
        BinaryProtocol.encode(fragments[i], BleMeshService.shouldPadForBle(fragments[i].type));
      if (encoded === null) {
        continue;
      }
      if (this.sendRawToDevice(deviceId, encoded)) {
        sent = true;
      }
    }
    return sent;
  }

  /**
   * A decoded mesh packet arrived (GATT callback). Raw handoff to the
   * TransportDelegate with link provenance - the PacketProcessor pipeline
   * in the composition root owns validation, reassembly and dispatch.
   */
  onPacketReceived(packet: BitchatPacket, peerId: string, deviceId: string, linkId: string): void {
    if (peerId === this.myPeerId) {
      return;
    }
    const entry: MeshLinkEntry | undefined = this.links.get(deviceId);
    if (entry !== undefined && entry.linkId === linkId && entry.peerId === null) {
      entry.peerId = peerId;
      this.devicePeerMap.set(deviceId, peerId);
    }
    if (this.delegate !== null) {
      this.delegate.onPacketReceived(packet, peerId, deviceId, linkId);
    }
  }

  // ------------------------------------------------------------------
  // Internals
  // ------------------------------------------------------------------

  private findDeviceIdByLinkId(linkId: string): string | null {
    let found: string | null = null;
    this.links.forEach((entry: MeshLinkEntry): void => {
      if (found === null && entry.linkId === linkId) {
        found = entry.deviceId;
      }
    });
    return found;
  }

  /**
   * iOS-compatible BLE padding policy: only Noise frames are padded over BLE
   * (Android BLEPacketPaddingPolicy / iOS BLEOutboundPacketPolicy).
   */
  private static shouldPadForBle(type: number): boolean {
    return type === MessageType.NOISE_ENCRYPTED || type === MessageType.NOISE_HANDSHAKE;
  }

  private resolveTargets(recipientPeerId: string | null): string[] {
    const targets: string[] = [];
    if (recipientPeerId !== null) {
      this.devicePeerMap.forEach((peerId: string, deviceId: string): void => {
        if (peerId === recipientPeerId) {
          targets.push(deviceId);
        }
      });
      return targets;
    }
    this.links.forEach((entry: MeshLinkEntry): void => {
      targets.push(entry.deviceId);
    });
    return targets;
  }

  private sendRawToDevice(deviceId: string, data: Uint8Array): boolean {
    // Server path first (notification to subscribed clients), then the
    // client path (acknowledged write); each role self-checks readiness.
    if (this.gattServer.sendToDevice(deviceId, data)) {
      return true;
    }
    return this.gattClient.sendToDevice(deviceId, data);
  }
}
