/**
 * Service-layer to ViewModel event bus (one-directional).
 * Services emit, the UI layer subscribes. The bus itself is pure logic so it
 * works identically on the main thread, in taskpool workers and in local tests.
 */

export class BcEventPayload {
  readonly eventName: string;

  constructor(eventName: string) {
    this.eventName = eventName;
  }
}

export type BcEventListener = (payload: BcEventPayload) => void;

/** Canonical service -> UI event names (plan.md D8: services emit, UI subscribes). */
export class BcEvents {
  /** A peer's presence/material changed (upsert semantics). */
  static readonly PEER_UPDATED: string = 'peer-updated';
  /** A peer left the peer table (eviction or explicit removal). */
  static readonly PEER_REMOVED: string = 'peer-removed';
  /** A Noise X sealed envelope was deposited with a courier (US17). */
  static readonly COURIER_DEPOSITED: string = 'courier-deposited';
  /** A carried sealed envelope reached its recipient (US17). */
  static readonly COURIER_DELIVERED: string = 'courier-delivered';
}

/** Payload of the `peer-updated` event (upsert one network member row). */
export class PeerUpdatedPayload extends BcEventPayload {
  readonly peerId: string;
  readonly nickname: string;
  /** Wall-clock ms of the last verified contact driving the reachable window. */
  readonly lastSeenMs: number;

  constructor(peerId: string, nickname: string, lastSeenMs: number) {
    super(BcEvents.PEER_UPDATED);
    this.peerId = peerId;
    this.nickname = nickname;
    this.lastSeenMs = lastSeenMs;
  }
}

/** Payload of the `peer-removed` event (drop one network member row). */
export class PeerRemovedPayload extends BcEventPayload {
  readonly peerId: string;

  constructor(peerId: string) {
    super(BcEvents.PEER_REMOVED);
    this.peerId = peerId;
  }
}

/** Payload of the `courier-deposited` event (one sealed envelope handed to a courier, US17). */
export class CourierDepositedPayload extends BcEventPayload {
  readonly envelopeID: string;
  readonly courierPeerID: string;

  constructor(envelopeID: string, courierPeerID: string) {
    super(BcEvents.COURIER_DEPOSITED);
    this.envelopeID = envelopeID;
    this.courierPeerID = courierPeerID;
  }
}

/** Payload of the `courier-delivered` event (a carried envelope reached its recipient, US17). */
export class CourierDeliveredPayload extends BcEventPayload {
  readonly envelopeID: string;
  readonly recipientPeerID: string;

  constructor(envelopeID: string, recipientPeerID: string) {
    super(BcEvents.COURIER_DELIVERED);
    this.envelopeID = envelopeID;
    this.recipientPeerID = recipientPeerID;
  }
}

export class EventBus {
  private static listeners: Map<string, BcEventListener[]> = new Map<string, BcEventListener[]>();

  static on(name: string, listener: BcEventListener): void {
    let list: BcEventListener[] | undefined = EventBus.listeners.get(name);
    if (list === undefined) {
      list = [];
      EventBus.listeners.set(name, list);
    }
    list.push(listener);
  }

  static off(name: string, listener: BcEventListener): void {
    const list: BcEventListener[] | undefined = EventBus.listeners.get(name);
    if (list === undefined) {
      return;
    }
    const idx: number = list.indexOf(listener);
    if (idx >= 0) {
      list.splice(idx, 1);
    }
    if (list.length === 0) {
      EventBus.listeners.delete(name);
    }
  }

  static emit(name: string, payload: BcEventPayload): void {
    const list: BcEventListener[] | undefined = EventBus.listeners.get(name);
    if (list === undefined) {
      return;
    }
    // Copy so listeners can unsubscribe while the event dispatches.
    const snapshot: BcEventListener[] = list.slice(0);
    for (let i: number = 0; i < snapshot.length; i++) {
      snapshot[i](payload);
    }
  }

  static listenerCount(name: string): number {
    const list: BcEventListener[] | undefined = EventBus.listeners.get(name);
    return list === undefined ? 0 : list.length;
  }

  static clear(): void {
    EventBus.listeners.clear();
  }
}
