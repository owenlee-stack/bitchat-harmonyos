/**
 * Mesh transport abstraction (US2, T023) - the plan.md "Transport" contract:
 * start/stop, send(packet, recipient?), events onPacketReceived /
 * onPeerConnected / onPeerDisconnected.
 *
 * Phase 1 ships the BLE implementation (BleMeshService); TransportRegistry
 * reserves the registration point for Wi-Fi Aware and future transports.
 */
import { BitchatPacket } from '../../model/BitchatPacket';

/** Events every transport surfaces to its owner. */
export interface TransportDelegate {
  /** A validated mesh packet arrived (fragments already reassembled). */
  onPacketReceived(packet: BitchatPacket, peerId: string, deviceId: string, linkId: string): void;

  /** A link finished establishing (peerId null until the first packet). */
  onPeerConnected(peerId: string | null, deviceId: string, linkId: string): void;

  /** A link dropped or failed to establish. */
  onPeerDisconnected(peerId: string | null, deviceId: string, linkId: string): void;
}

/** Link-layer transport contract; implemented by BleMeshService (BLE). */
export interface Transport {
  start(): boolean;
  stop(): void;
  send(packet: BitchatPacket, recipientPeerId?: string): boolean;
}

/** Named transport registry; the future Wi-Fi Aware transport registers here. */
export class TransportRegistry {
  private static readonly transports: Map<string, Transport> = new Map();

  static register(name: string, transport: Transport): void {
    TransportRegistry.transports.set(name, transport);
  }

  static unregister(name: string): void {
    TransportRegistry.transports.delete(name);
  }

  static get(name: string): Transport | null {
    const transport: Transport | undefined = TransportRegistry.transports.get(name);
    return transport === undefined ? null : transport;
  }
}
