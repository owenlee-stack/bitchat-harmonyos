/**
 * Ingress packet processor (US3, T026) - mirrors bitchat-android
 * PacketProcessor.kt (FR-015: per-peer serialized ordered processing with
 * overload protection).
 *
 * D4 concurrency model: transport callbacks only enqueue; processing runs in
 * deferred drain chains decoupled from the GATT receive callback. The same
 * peer always hashes to the same logical worker slot (ProcessorConstants.
 * WORKER_COUNT), so packets from one peer are handled strictly in FIFO order
 * while different slots drain independently. Admission is bounded per slot
 * (QUEUE_CAPACITY, drop the newest packet) and globally by pending payload
 * bytes (MAX_PENDING_PAYLOAD_BYTES); dropped packets are counted. Ingress
 * is also bounded per type by the PacketPayloadLimits receive ceilings
 * (T038): an oversized payload is dropped before it can occupy the budget
 * or reach any handler.
 *
 * Deliberately free of device imports so the queue/admission/dispatch
 * semantics run in the host contract harness. The defer scheduler is
 * injectable: the device wires a setTimeout-based defer, tests a
 * synchronous/collected one. Handler delegates stay synchronous because the
 * protocol kernel (SecurityGate/FragmentManager/announce decode) is
 * synchronous; async crypto hides behind the injected sync verifier (T023
 * decision). A bad packet is caught per item so it can neither kill a slot's
 * serialization chain nor bypass its ordering.
 */
import { BitchatPacket, MessageType, messageTypeFromValue } from '../../model/BitchatPacket';
import { ProcessorConstants } from '../../common/ProtocolConstants';
import { PacketPayloadLimits } from '../protocol/PacketPayloadLimits';

/** An incoming packet plus its transport provenance (Android RoutedPacket). */
export class RoutedPacket {
  readonly packet: BitchatPacket;
  /** Sender peer ID (16 lowercase hex) as identified by the transport. */
  readonly peerID: string;
  /** Address of the direct relaying hop when routed, else null. */
  readonly relayAddress: Uint8Array | null;
  /** Transport link the packet arrived on, else null. */
  readonly ingressLinkID: string | null;

  constructor(packet: BitchatPacket, peerID: string, relayAddress: Uint8Array | null,
    ingressLinkID: string | null) {
    this.packet = packet;
    this.peerID = peerID;
    this.relayAddress = relayAddress;
    this.ingressLinkID = ingressLinkID;
  }
}

export interface PacketProcessorDelegate {
  /** SecurityGate-backed validation (dedup/replay/signature). */
  validatePacketSecurity(packet: BitchatPacket, peerID: string): boolean;

  /** True when the packet's recipient addresses this device (private types). */
  isPacketAddressedToMe(packet: BitchatPacket): boolean;

  /** Apply a verified announce; false marks the packet invalid. */
  handleAnnounce(routed: RoutedPacket): boolean;

  /** Public MESSAGE / FILE_TRANSFER routing into the timeline. */
  handleMessage(routed: RoutedPacket): void;

  /** Voice frame handling; false when invalid so it does not prove liveness. */
  handleVoiceFrame(routed: RoutedPacket): boolean;

  /** LEAVE application (presence eviction). */
  handleLeave(routed: RoutedPacket): void;

  /** Fragment reassembly; returns the completed packet when the set is done. */
  handleFragment(packet: BitchatPacket): BitchatPacket | null;

  /** Noise XX handshake initiation. */
  handleNoiseHandshake(routed: RoutedPacket): boolean;

  /** Noise encrypted transport decryption; false when undecryptable. */
  handleNoiseEncrypted(routed: RoutedPacket): boolean;

  /** REQUEST_SYNC handling (gossip negotiation). */
  handleRequestSync(routed: RoutedPacket): void;

  /** Refresh the peer's last-seen contact timestamp (reachable window). */
  updatePeerLastSeen(peerID: string): void;

  /** Relay hook (T027 PacketRelay decisions ride this). */
  relayPacket(routed: RoutedPacket): void;
}

class QueuedPacket {
  readonly routed: RoutedPacket;
  readonly payloadBytes: number;

  constructor(routed: RoutedPacket, payloadBytes: number) {
    this.routed = routed;
    this.payloadBytes = payloadBytes;
  }
}

class WorkerSlot {
  readonly index: number;
  queue: QueuedPacket[] = [];
  draining: boolean = false;

  constructor(index: number) {
    this.index = index;
  }
}

export class PacketProcessor {
  private readonly delegate: PacketProcessorDelegate;
  private readonly defer: (task: () => void) => void;
  private readonly slots: WorkerSlot[] = [];
  private pendingPayloadBytes: number = 0;
  private droppedPackets: number = 0;
  /** Packets admitted into a slot queue (T079: drop-rate denominator). */
  private acceptedPackets: number = 0;
  private running: boolean = true;

  constructor(delegate: PacketProcessorDelegate,
    defer: (task: () => void) => void = (task: () => void): void => {
      setTimeout(task, 0);
    }) {
    this.delegate = delegate;
    this.defer = defer;
    for (let i: number = 0; i < ProcessorConstants.WORKER_COUNT; i++) {
      this.slots.push(new WorkerSlot(i));
    }
  }

  /**
   * Enqueue one incoming packet. Never processes inline and never blocks:
   * under overload the newest packet is dropped and counted. The same peer
   * always lands in the same FIFO slot.
   */
  processPacket(routed: RoutedPacket): void {
    if (!this.running) {
      return;
    }
    const payloadBytes: number = routed.packet.payload.length;
    if (payloadBytes > PacketPayloadLimits.maxPayloadBytes(routed.packet.type)) {
      // T038: per-type receive ceiling at ingress. An oversized payload is
      // protocol-violating junk (every compliant sender is bounded by the
      // same caps): it is dropped and counted before it can occupy the
      // global budget or reach any handler.
      this.droppedPackets += 1;
      return;
    }
    if (this.pendingPayloadBytes + payloadBytes > ProcessorConstants.MAX_PENDING_PAYLOAD_BYTES) {
      this.droppedPackets += 1;
      return;
    }
    const slot: WorkerSlot = this.slots[PacketProcessor.slotIndexForPeer(routed.peerID)];
    if (slot.queue.length >= ProcessorConstants.QUEUE_CAPACITY) {
      this.droppedPackets += 1;
      return;
    }
    this.pendingPayloadBytes += payloadBytes;
    this.acceptedPackets += 1;
    slot.queue.push(new QueuedPacket(routed, payloadBytes));
    if (!slot.draining) {
      slot.draining = true;
      this.defer(() => {
        this.drainSlot(slot);
      });
    }
  }

  /** Deterministic peer -> slot mapping (Java String.hashCode semantics). */
  static slotIndexForPeer(peerID: string): number {
    let hash: number = 0;
    for (let i: number = 0; i < peerID.length; i++) {
      hash = Math.imul(hash, 31) + peerID.charCodeAt(i) | 0;
    }
    return (hash & 0x7FFFFFFF) % ProcessorConstants.WORKER_COUNT;
  }

  getDroppedPacketCount(): number {
    return this.droppedPackets;
  }

  getAcceptedPacketCount(): number {
    return this.acceptedPackets;
  }

  /**
   * Admission drop rate = dropped / (dropped + accepted), 0..1 with no
   * traffic reported as 0 (T079: the SC-006 queue-drop budget is <1%).
   */
  getDropRate(): number {
    const total: number = this.droppedPackets + this.acceptedPackets;
    if (total === 0) {
      return 0;
    }
    return this.droppedPackets / total;
  }

  getPendingPacketCount(): number {
    let count: number = 0;
    for (let i: number = 0; i < this.slots.length; i++) {
      count += this.slots[i].queue.length;
    }
    return count;
  }

  getPendingPayloadBytes(): number {
    return this.pendingPayloadBytes;
  }

  getDebugInfo(): string {
    return '=== Packet Processor Debug Info ===\n' +
      'Running: ' + this.running + '\n' +
      'Worker Slots: ' + ProcessorConstants.WORKER_COUNT + '\n' +
      'Pending Packets: ' + this.getPendingPacketCount() + '\n' +
      'Pending Payload Bytes: ' + this.pendingPayloadBytes + '\n' +
      'Accepted Packets: ' + this.acceptedPackets + '\n' +
      'Dropped Packets: ' + this.droppedPackets + '\n' +
      'Drop Rate: ' + this.getDropRate().toFixed(4);
  }

  /** Stop the processor and discard all queued packets. */
  shutdown(): void {
    this.running = false;
    for (let i: number = 0; i < this.slots.length; i++) {
      this.slots[i].queue = [];
      this.slots[i].draining = false;
    }
    this.pendingPayloadBytes = 0;
  }

  /**
   * Core protocol dispatch (same order as the Android/iOS handler): security
   * validation, per-type dispatch, then liveness update + relay hook for
   * every packet that stayed valid.
   */
  private handleReceivedPacket(routed: RoutedPacket): void {
    const packet: BitchatPacket = routed.packet;
    const peerID: string = routed.peerID;

    if (!this.delegate.validatePacketSecurity(packet, peerID)) {
      return;
    }

    let validPacket: boolean = true;
    const messageType: MessageType | null = messageTypeFromValue(packet.type);
    if (messageType === MessageType.ANNOUNCE) {
      validPacket = this.delegate.handleAnnounce(routed);
    } else if (messageType === MessageType.MESSAGE || messageType === MessageType.FILE_TRANSFER) {
      this.delegate.handleMessage(routed);
    } else if (messageType === MessageType.VOICE_FRAME) {
      validPacket = this.delegate.handleVoiceFrame(routed);
    } else if (messageType === MessageType.LEAVE) {
      this.delegate.handleLeave(routed);
    } else if (messageType === MessageType.FRAGMENT) {
      this.handleFragment(routed);
    } else if (messageType === MessageType.REQUEST_SYNC) {
      this.delegate.handleRequestSync(routed);
    } else if (this.delegate.isPacketAddressedToMe(packet)) {
      // Private packet types require an address check; packets not addressed
      // to us take no handler and only the transit relay path below applies.
      if (messageType === MessageType.NOISE_HANDSHAKE) {
        validPacket = this.delegate.handleNoiseHandshake(routed);
      } else if (messageType === MessageType.NOISE_ENCRYPTED) {
        validPacket = this.delegate.handleNoiseEncrypted(routed);
      } else {
        validPacket = false;
      }
    }

    if (validPacket) {
      this.delegate.updatePeerLastSeen(peerID);
      this.delegate.relayPacket(routed);
    }
  }

  /** Reassemble fragments; the completed packet re-enters the same pipeline. */
  private handleFragment(routed: RoutedPacket): void {
    const reassembled: BitchatPacket | null = this.delegate.handleFragment(routed.packet);
    if (reassembled !== null) {
      this.handleReceivedPacket(new RoutedPacket(reassembled, routed.peerID,
        routed.relayAddress, routed.ingressLinkID));
    }
  }

  private drainSlot(slot: WorkerSlot): void {
    while (slot.queue.length > 0) {
      const shifted: QueuedPacket | undefined = slot.queue.shift();
      if (shifted === undefined) {
        break;
      }
      try {
        this.handleReceivedPacket(shifted.routed);
      } catch (e) {
        // A bad packet cannot kill the slot's serialization chain.
      } finally {
        this.pendingPayloadBytes -= shifted.payloadBytes;
      }
    }
    slot.draining = false;
  }
}
