/**
 * Nostr relay client, mirroring bitchat-android NostrRelayManager.kt
 * for the private-messaging path: persistent WebSocket connections to
 * the four default relays, exponential reconnect backoff
 * (RelayReconnectPolicy: 1s..300s x2 saturating at 10 attempts), a
 * 10,000-entry LRU event deduplicator, a bounded (500) per-relay
 * pending-delivery queue flushed on reconnect, subscription recovery
 * on reconnect, and a 30s subscription consistency validation loop.
 * Geohash-scoped relaying and the live-location privacy gate are
 * Android-only features and stay out of this port. Device-side: uses
 * @ohos.net.webSocket via @kit.NetworkKit (excluded from the
 * host-runnable contract harness; the pure logic it composes lives in
 * NostrFilter / NostrRequest / NostrEventDeduplicator /
 * NostrPendingEventQueue / RelayReconnectPolicy and is contract
 * tested there).
 */
import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { NostrConstants } from '../../common/ProtocolConstants';
import { NostrEvent } from './NostrEvent';
import { NostrFilter } from './NostrFilter';
import { NostrRequest, NostrResponse, NostrResponseType } from './NostrRequest';
import { DeduplicationStats, NostrEventDeduplicator } from './NostrEventDeduplicator';
import { NostrPendingDelivery, NostrPendingEventQueue } from './NostrPendingEventQueue';
import { NostrRelayCatalog } from './NostrRelayCatalog';
import { RelayReconnectPolicy } from './RelayReconnectPolicy';
import { SocksProxyMode, socksDirectConnectionsAllowed, socksProxyAddress,
  socksProxyPortOrDefault, SOCKS_PROXY_DEFAULT_PORT } from './SocksProxyPolicy';

const DOMAIN = 0x0000;
const TAG = 'NostrRelayManager';

/** Per-relay connection state surfaced to the UI (Relay data class parity). */
export class NostrRelayState {
  readonly url: string;
  isConnected: boolean = false;
  lastError: string | null = null;
  lastConnectedAt: number | null = null;
  messagesSent: number = 0;
  messagesReceived: number = 0;
  reconnectAttempts: number = 0;
  lastDisconnectedAt: number | null = null;
  nextReconnectTime: number | null = null;

  constructor(url: string) {
    this.url = url;
  }
}

/** An active subscription maintained across reconnections (SubscriptionInfo parity). */
export class NostrSubscriptionInfo {
  readonly id: string;
  readonly filter: NostrFilter;
  readonly handler: (event: NostrEvent) => void;
  /** Null means all relays. */
  readonly targetRelayUrls: string[] | null;
  readonly createdAt: number;
  readonly owner: string;
  /** Deliver matches straight to the handler, bypassing the shared deduplicator. */
  readonly observeOnly: boolean;

  constructor(id: string, filter: NostrFilter, handler: (event: NostrEvent) => void,
    targetRelayUrls: string[] | null, createdAt: number, owner: string,
    observeOnly: boolean) {
    this.id = id;
    this.filter = filter;
    this.handler = handler;
    this.targetRelayUrls = targetRelayUrls;
    this.createdAt = createdAt;
    this.owner = owner;
    this.observeOnly = observeOnly;
  }
}

export class NostrRelayManager {
  static readonly shared: NostrRelayManager = new NostrRelayManager();
  static readonly OWNER_LEGACY: string = 'legacy';
  static readonly OWNER_BACKGROUND: string = 'background';

  private static readonly MAX_QUEUED_EVENTS: number = 500;
  private static readonly pendingGiftWrapIds: Set<string> = new Set<string>();

  private readonly relayStates: NostrRelayState[] = [];
  private readonly connections: Map<string, webSocket.WebSocket> = new Map();
  private readonly reconnectTimers: Map<string, number> = new Map();
  /** Relay URL -> subscription IDs active on that socket. */
  private readonly subscriptions: Map<string, Set<string>> = new Map();
  /** Subscription ID -> info that must survive reconnects. */
  private readonly activeSubscriptions: Map<string, NostrSubscriptionInfo> = new Map();
  private readonly messageHandlers: Map<string, (event: NostrEvent) => void> = new Map();
  private readonly eventDeduplicator: NostrEventDeduplicator = new NostrEventDeduplicator();
  private readonly messageQueue: NostrPendingEventQueue =
    new NostrPendingEventQueue(NostrRelayManager.MAX_QUEUED_EVENTS);
  private desiredConnected: boolean = false;
  private validationTimer: number | null = null;
  private socksProxyModeValue: SocksProxyMode = SocksProxyMode.OFF;
  private socksProxyHostValue: string = '';
  private socksProxyPortValue: number = SOCKS_PROXY_DEFAULT_PORT;

  /** Track gift wraps we initiated for rejection logging. */
  static registerPendingGiftWrap(id: string): void {
    NostrRelayManager.pendingGiftWrapIds.add(id);
  }

  private constructor() {
    const defaults: string[] = NostrRelayCatalog.DEFAULT_RELAYS;
    for (let i: number = 0; i < defaults.length; i++) {
      this.relayStates.push(new NostrRelayState(defaults[i]));
    }
  }

  /** Connect to all default relays and start subscription validation. */
  connect(): void {
    this.desiredConnected = true;
    hilog.info(DOMAIN, TAG, 'connecting to %{public}d Nostr relays', this.relayStates.length);
    for (let i: number = 0; i < this.relayStates.length; i++) {
      this.connectToRelay(this.relayStates[i].url);
    }
    this.startSubscriptionValidation();
  }

  /**
   * Disconnect from all relays. Logical subscriptions are preserved so
   * a later connect() re-establishes them (controlled reset parity).
   */
  disconnect(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'disconnecting from all Nostr relays');
    this.desiredConnected = false;
    this.stopSubscriptionValidation();
    this.reconnectTimers.forEach((timerId: number, url: string) => {
      clearTimeout(timerId);
    });
    this.reconnectTimers.clear();
    this.connections.forEach((socket: webSocket.WebSocket, url: string) => {
      socket.close((err: BusinessError) => {
        if (err) {
          hilog.warn(DOMAIN, TAG, 'close failed for %{public}s: %{public}s',
            url, JSON.stringify(err));
        }
      });
    });
    this.connections.clear();
    this.subscriptions.clear();
    for (let i: number = 0; i < this.relayStates.length; i++) {
      this.relayStates[i].isConnected = false;
      this.relayStates[i].nextReconnectTime = null;
    }
  }

  /** Publish an event to the given relays (all tracked relays when null). */
  sendEvent(event: NostrEvent, relayUrls: string[] | null): void {
    const allUrls: string[] = [];
    if (relayUrls === null) {
      for (let i: number = 0; i < this.relayStates.length; i++) {
        allUrls.push(this.relayStates[i].url);
      }
    } else {
      for (let i: number = 0; i < relayUrls.length; i++) {
        allUrls.push(relayUrls[i]);
      }
    }
    const seen: Set<string> = new Set<string>();
    const targets: string[] = [];
    for (let i: number = 0; i < allUrls.length; i++) {
      const url: string = allUrls[i];
      if (url.trim().length > 0 && !seen.has(url)) {
        seen.add(url);
        targets.push(url);
      }
    }
    if (targets.length === 0) {
      return;
    }
    const queueId: number | null = this.messageQueue.enqueue(event, targets);
    if (queueId === null) {
      return;
    }
    for (let i: number = 0; i < targets.length; i++) {
      const relayUrl: string = targets[i];
      const socket: webSocket.WebSocket | undefined = this.connections.get(relayUrl);
      if (socket !== undefined) {
        this.sendToRelay(event, socket, relayUrl, queueId);
      }
    }
  }

  /**
   * Subscribe to events matching the filter; the subscription is
   * automatically re-established on reconnection.
   */
  subscribe(filter: NostrFilter, id: string, handler: (event: NostrEvent) => void,
    targetRelayUrls: string[] | null, owner: string, observeOnly: boolean): string {
    const info: NostrSubscriptionInfo = new NostrSubscriptionInfo(id, filter, handler,
      targetRelayUrls, Date.now(), owner, observeOnly);
    this.activeSubscriptions.set(id, info);
    this.messageHandlers.set(id, handler);
    this.sendSubscriptionToRelays(info);
    return id;
  }

  /** Unsubscribe and CLOSE on every relay carrying the subscription. */
  unsubscribe(id: string): void {
    const info: NostrSubscriptionInfo | undefined = this.activeSubscriptions.get(id);
    this.activeSubscriptions.delete(id);
    this.messageHandlers.delete(id);
    if (info === undefined) {
      return;
    }
    const message: string = NostrRequest.closeMessage(id);
    this.connections.forEach((socket: webSocket.WebSocket, relayUrl: string) => {
      const subsOnRelay: Set<string> | undefined = this.subscriptions.get(relayUrl);
      if (subsOnRelay !== undefined && subsOnRelay.has(id)) {
        socket.send(message, (err: BusinessError) => {
          if (err) {
            hilog.error(DOMAIN, TAG, 'failed to unsubscribe from relay: %{public}s',
              JSON.stringify(err));
          }
        });
        subsOnRelay.delete(id);
      }
    });
  }

  /** Unsubscribe every subscription owned by the given owner. */
  unsubscribeOwner(owner: string): void {
    const ids: string[] = [];
    this.activeSubscriptions.forEach((info: NostrSubscriptionInfo, id: string) => {
      if (info.owner === owner) {
        ids.push(id);
      }
    });
    for (let i: number = 0; i < ids.length; i++) {
      this.unsubscribe(ids[i]);
    }
  }

  /** Controlled reset: sockets drop, subscription bookkeeping survives. */
  resetAllConnections(): void {
    const shouldReconnect: boolean = this.desiredConnected;
    this.disconnect();
    for (let i: number = 0; i < this.relayStates.length; i++) {
      this.relayStates[i].reconnectAttempts = 0;
      this.relayStates[i].nextReconnectTime = null;
      this.relayStates[i].lastError = null;
    }
    if (shouldReconnect) {
      this.connect();
    }
  }

  /** Force re-establishment of all subscriptions on connected relays. */
  reestablishAllSubscriptions(): void {
    this.connections.forEach((socket: webSocket.WebSocket, relayUrl: string) => {
      this.restoreSubscriptionsForRelay(relayUrl, socket);
    });
  }

  /**
   * SOCKS proxy parameterization (US15, T072): apply the persisted
   * OFF/custom choice to the relay transport, mirroring the Android
   * OkHttpProvider route decision. CUSTOM suppresses every direct relay
   * connection fail-closed (开启后禁止直连) and tears down any live
   * direct sockets; the resolved 'host:port' address is the reserved
   * Arti integration point for the phase-3 native port. OFF restores
   * direct relay connections.
   */
  applySocksProxy(mode: SocksProxyMode, host: string, port: number): void {
    const previouslyAllowed: boolean =
      socksDirectConnectionsAllowed(this.socksProxyModeValue);
    this.socksProxyModeValue = mode;
    this.socksProxyHostValue = host;
    this.socksProxyPortValue = socksProxyPortOrDefault(port);
    const allowed: boolean = socksDirectConnectionsAllowed(mode);
    hilog.info(DOMAIN, TAG, 'socks proxy mode=%{public}s directAllowed=%{public}s',
      mode, allowed ? 'true' : 'false');
    if (previouslyAllowed && !allowed) {
      this.suppressDirectConnections();
    } else if (!previouslyAllowed && allowed && this.desiredConnected) {
      this.connect();
    }
  }

  /** Resolved proxy address ('host:port'), or null while OFF/invalid. */
  getSocksProxyAddress(): string | null {
    return socksProxyAddress(this.socksProxyModeValue, this.socksProxyHostValue,
      this.socksProxyPortValue);
  }

  /** True while CUSTOM mode suppresses direct relay connections. */
  isDirectConnectionsSuppressed(): boolean {
    return !socksDirectConnectionsAllowed(this.socksProxyModeValue);
  }

  /** Clear subscription tracking and queued messages for panic/reset flows. */
  clearAllSubscriptions(): void {
    this.activeSubscriptions.clear();
    this.messageHandlers.clear();
    this.subscriptions.clear();
    this.messageQueue.clear();
    hilog.info(DOMAIN, TAG, '%{public}s', 'cleared all Nostr subscriptions and routing caches');
  }

  /** Panic mode: subscriptions, dedup cache, queue and connections. */
  clearAllOnPanic(): void {
    const wasConnected: boolean = this.desiredConnected;
    this.clearAllSubscriptions();
    this.clearDeduplicationCache();
    this.disconnect();
    if (wasConnected) {
      this.desiredConnected = true;
    }
    hilog.warn(DOMAIN, TAG, '%{public}s',
      'cleared NostrRelayManager subscriptions, cache, and connections for panic mode');
  }

  getRelayStatuses(): NostrRelayState[] {
    const out: NostrRelayState[] = [];
    for (let i: number = 0; i < this.relayStates.length; i++) {
      out.push(this.relayStates[i]);
    }
    return out;
  }

  getDeduplicationStats(): DeduplicationStats {
    return this.eventDeduplicator.getStats();
  }

  clearDeduplicationCache(): void {
    this.eventDeduplicator.clear();
  }

  getActiveSubscriptionCount(): number {
    return this.activeSubscriptions.size;
  }

  // --- Internals ---

  private connectToRelay(url: string): void {
    if (!this.desiredConnected || this.connections.has(url)) {
      return;
    }
    if (this.isDirectConnectionsSuppressed()) {
      // Fail-closed: a custom SOCKS proxy forbids direct relay
      // connections even before the proxied transport exists (US15).
      hilog.info(DOMAIN, TAG,
        'direct relay connection suppressed by socks proxy mode: %{public}s', url);
      const suppressedState: NostrRelayState | null = this.findRelayState(url);
      if (suppressedState !== null) {
        suppressedState.lastError = 'socks proxy enabled: direct connections suppressed';
        suppressedState.nextReconnectTime = null;
      }
      return;
    }
    const socket: webSocket.WebSocket = webSocket.createWebSocket();
    this.connections.set(url, socket);
    socket.on('open', (err: BusinessError, value: Object) => {
      this.handleOpen(url, socket);
    });
    socket.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
      if (typeof value === 'string') {
        this.handleMessage(value, url);
      }
    });
    socket.on('close', (err: BusinessError, value: webSocket.CloseResult) => {
      hilog.info(DOMAIN, TAG, 'relay %{public}s closed: %{public}d %{public}s',
        url, value.code, value.reason);
      this.handleDisconnection(url, socket, 'closed: ' + value.code + ' ' + value.reason);
    });
    socket.on('error', (err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'relay %{public}s error: %{public}s', url, JSON.stringify(err));
      this.handleDisconnection(url, socket, err.message);
    });
    socket.connect(url, (err: BusinessError, value: boolean) => {
      if (err) {
        hilog.error(DOMAIN, TAG, 'connect failed for %{public}s: %{public}s',
          url, JSON.stringify(err));
        this.handleDisconnection(url, socket, err.message);
      }
    });
  }

  private handleOpen(url: string, socket: webSocket.WebSocket): void {
    if (!this.desiredConnected || this.connections.get(url) !== socket) {
      socket.close((err: BusinessError) => {
        // Empty: stale socket; close result is irrelevant.
      });
      return;
    }
    const timerId: number | undefined = this.reconnectTimers.get(url);
    if (timerId !== undefined) {
      clearTimeout(timerId);
      this.reconnectTimers.delete(url);
    }
    this.updateRelayStatus(url, true, null);
    this.restoreSubscriptionsForRelay(url, socket);
    // Flush only events still pending for this relay.
    const deliveries: NostrPendingDelivery[] = this.messageQueue.pendingForRelay(url);
    for (let i: number = 0; i < deliveries.length; i++) {
      const delivery: NostrPendingDelivery = deliveries[i];
      this.sendToRelay(delivery.event, socket, url, delivery.queueId);
    }
  }

  private sendToRelay(event: NostrEvent, socket: webSocket.WebSocket,
    relayUrl: string, queueId: number): void {
    const message: string = NostrRequest.eventMessage(event);
    socket.send(message, (err: BusinessError) => {
      if (err) {
        hilog.error(DOMAIN, TAG, 'failed to send event to %{public}s: %{public}s',
          relayUrl, JSON.stringify(err));
        return;
      }
      const state: NostrRelayState | null = this.findRelayState(relayUrl);
      if (state !== null) {
        state.messagesSent += 1;
      }
      this.messageQueue.markDelivered(queueId, relayUrl);
    });
  }

  private sendSubscriptionToRelays(info: NostrSubscriptionInfo): void {
    const message: string = NostrRequest.subscribeMessage(info.id, info.filter);
    const targetRelays: string[] = [];
    if (info.targetRelayUrls !== null) {
      for (let i: number = 0; i < info.targetRelayUrls.length; i++) {
        targetRelays.push(info.targetRelayUrls[i]);
      }
    } else {
      this.connections.forEach((socket: webSocket.WebSocket, relayUrl: string) => {
        targetRelays.push(relayUrl);
      });
    }
    if (targetRelays.length === 0) {
      hilog.warn(DOMAIN, TAG, '%{public}s',
        'no relay connections available for subscription, will retry on reconnection');
      return;
    }
    for (let i: number = 0; i < targetRelays.length; i++) {
      const relayUrl: string = targetRelays[i];
      const socket: webSocket.WebSocket | undefined = this.connections.get(relayUrl);
      if (socket === undefined) {
        continue;
      }
      socket.send(message, (err: BusinessError) => {
        if (err) {
          hilog.warn(DOMAIN, TAG, 'failed to send subscription to %{public}s: %{public}s',
            relayUrl, JSON.stringify(err));
          return;
        }
        let subsOnRelay: Set<string> | undefined = this.subscriptions.get(relayUrl);
        if (subsOnRelay === undefined) {
          subsOnRelay = new Set<string>();
          this.subscriptions.set(relayUrl, subsOnRelay);
        }
        subsOnRelay.add(info.id);
      });
    }
  }

  private restoreSubscriptionsForRelay(relayUrl: string,
    socket: webSocket.WebSocket): void {
    this.activeSubscriptions.forEach((info: NostrSubscriptionInfo, id: string) => {
      const targetsAll: boolean = info.targetRelayUrls === null;
      let targetsThis: boolean = false;
      if (info.targetRelayUrls !== null) {
        for (let i: number = 0; i < info.targetRelayUrls.length; i++) {
          if (info.targetRelayUrls[i] === relayUrl) {
            targetsThis = true;
            break;
          }
        }
      }
      if (!targetsAll && !targetsThis) {
        return;
      }
      const message: string = NostrRequest.subscribeMessage(id, info.filter);
      socket.send(message, (err: BusinessError) => {
        if (err) {
          hilog.warn(DOMAIN, TAG, 'failed to restore subscription on %{public}s: %{public}s',
            relayUrl, JSON.stringify(err));
          return;
        }
        let subsOnRelay: Set<string> | undefined = this.subscriptions.get(relayUrl);
        if (subsOnRelay === undefined) {
          subsOnRelay = new Set<string>();
          this.subscriptions.set(relayUrl, subsOnRelay);
        }
        subsOnRelay.add(id);
      });
    });
  }

  private handleMessage(text: string, relayUrl: string): void {
    let response: NostrResponse;
    try {
      response = NostrRequest.parseResponse(text);
    } catch (e) {
      // T080 log sanitization: never log the raw relay text; a malformed
      // message can still carry someone's content into hilog.
      hilog.warn(DOMAIN, TAG,
        'failed to parse relay message from %{public}s, len=%{public}d',
        relayUrl, text.length);
      return;
    }
    if (response.type === NostrResponseType.EVENT) {
      const event: NostrEvent | null = response.event;
      const subscriptionId: string | null = response.subscriptionId;
      if (event === null || subscriptionId === null) {
        return;
      }
      const state: NostrRelayState | null = this.findRelayState(relayUrl);
      if (state !== null) {
        state.messagesReceived += 1;
      }
      const info: NostrSubscriptionInfo | undefined =
        this.activeSubscriptions.get(subscriptionId);
      if (info === undefined) {
        return;
      }
      // Client-side filter enforcement: a relay must not route events
      // into the wrong subscription.
      let matches: boolean = true;
      try {
        matches = info.filter.matches(event);
      } catch (e) {
        matches = true;
      }
      if (!matches) {
        return;
      }
      if (info.observeOnly) {
        const observeHandler: ((event: NostrEvent) => void) | undefined =
          this.messageHandlers.get(subscriptionId);
        if (observeHandler !== undefined) {
          observeHandler(event);
        }
        return;
      }
      if (this.eventDeduplicator.isDuplicate(event.id)) {
        return;
      }
      const handler: ((event: NostrEvent) => void) | undefined =
        this.messageHandlers.get(subscriptionId);
      if (handler === undefined) {
        hilog.warn(DOMAIN, TAG, 'no handler for Nostr subscription %{public}s',
          subscriptionId);
        return;
      }
      handler(event);
      return;
    }
    if (response.type === NostrResponseType.OK) {
      const eventId: string | null = response.eventId;
      if (eventId !== null) {
        NostrRelayManager.pendingGiftWrapIds.delete(eventId);
      }
      if (response.accepted !== null && !response.accepted) {
        hilog.error(DOMAIN, TAG, 'event rejected by relay: %{public}s',
          response.message !== null ? response.message : 'no reason');
      }
      return;
    }
    // EOSE / NOTICE / UNKNOWN: no action needed.
  }

  /** Ignore callbacks from intentionally closed or replaced sockets. */
  private handleDisconnection(url: string, socket: webSocket.WebSocket,
    error: string): void {
    if (this.connections.get(url) !== socket) {
      return;
    }
    this.connections.delete(url);
    this.subscriptions.delete(url);
    this.updateRelayStatus(url, false, error);
    if (!this.desiredConnected) {
      return;
    }
    const state: NostrRelayState | null = this.findRelayState(url);
    if (state === null) {
      return;
    }
    state.reconnectAttempts = RelayReconnectPolicy.nextAttempt(state.reconnectAttempts);
    const backoffInterval: number = RelayReconnectPolicy.backoffMs(state.reconnectAttempts);
    state.nextReconnectTime = Date.now() + backoffInterval;
    hilog.debug(DOMAIN, TAG, 'scheduling Nostr relay reconnection in %{public}d ms',
      backoffInterval);
    const existingTimer: number | undefined = this.reconnectTimers.get(url);
    if (existingTimer !== undefined) {
      clearTimeout(existingTimer);
    }
    const timerId: number = setTimeout((): void => {
      this.reconnectTimers.delete(url);
      if (this.desiredConnected) {
        this.connectToRelay(url);
      }
    }, backoffInterval);
    this.reconnectTimers.set(url, timerId);
  }

  private startSubscriptionValidation(): void {
    this.stopSubscriptionValidation();
    this.validationTimer = setInterval((): void => {
      this.validateAndRepairSubscriptions();
    }, NostrConstants.SUBSCRIPTION_VALIDATION_INTERVAL_MS);
  }

  private stopSubscriptionValidation(): void {
    if (this.validationTimer !== null) {
      clearInterval(this.validationTimer);
      this.validationTimer = null;
    }
  }

  private validateAndRepairSubscriptions(): void {
    this.connections.forEach((socket: webSocket.WebSocket, relayUrl: string) => {
      const subsOnRelay: Set<string> | undefined = this.subscriptions.get(relayUrl);
      let needsRepair: boolean = false;
      this.activeSubscriptions.forEach((info: NostrSubscriptionInfo, id: string) => {
        const targetsAll: boolean = info.targetRelayUrls === null;
        let targetsThis: boolean = false;
        if (info.targetRelayUrls !== null) {
          for (let i: number = 0; i < info.targetRelayUrls.length; i++) {
            if (info.targetRelayUrls[i] === relayUrl) {
              targetsThis = true;
              break;
            }
          }
        }
        const expected: boolean = targetsAll || targetsThis;
        const present: boolean = subsOnRelay !== undefined && subsOnRelay.has(id);
        if (expected && !present) {
          needsRepair = true;
        }
      });
      if (needsRepair) {
        hilog.info(DOMAIN, TAG, '%{public}s', 'auto-repairing missing Nostr subscriptions');
        this.restoreSubscriptionsForRelay(relayUrl, socket);
      }
    });
  }

  private updateRelayStatus(url: string, isConnected: boolean, error: string | null): void {
    const state: NostrRelayState | null = this.findRelayState(url);
    if (state === null) {
      return;
    }
    state.isConnected = isConnected;
    state.lastError = error;
    if (isConnected) {
      state.lastConnectedAt = Date.now();
      state.reconnectAttempts = 0;
      state.nextReconnectTime = null;
    } else {
      state.lastDisconnectedAt = Date.now();
    }
  }

  private findRelayState(url: string): NostrRelayState | null {
    for (let i: number = 0; i < this.relayStates.length; i++) {
      if (this.relayStates[i].url === url) {
        return this.relayStates[i];
      }
    }
    return null;
  }

  /**
   * Tear down every direct relay socket and reconnect schedule while a
   * custom SOCKS proxy is active. Logical subscriptions and the bounded
   * pending queue survive so the future proxied transport (Arti)
   * re-establishes them; only direct connections are forbidden.
   */
  private suppressDirectConnections(): void {
    hilog.info(DOMAIN, TAG, '%{public}s',
      'suppressing direct Nostr relay connections (socks proxy mode)');
    this.stopSubscriptionValidation();
    this.reconnectTimers.forEach((timerId: number, url: string) => {
      clearTimeout(timerId);
    });
    this.reconnectTimers.clear();
    this.connections.forEach((socket: webSocket.WebSocket, url: string) => {
      socket.close((err: BusinessError) => {
        if (err) {
          hilog.warn(DOMAIN, TAG, 'close failed for %{public}s: %{public}s',
            url, JSON.stringify(err));
        }
      });
    });
    this.connections.clear();
    this.subscriptions.clear();
    for (let i: number = 0; i < this.relayStates.length; i++) {
      this.relayStates[i].isConnected = false;
      this.relayStates[i].nextReconnectTime = null;
      this.relayStates[i].lastError = 'socks proxy enabled: direct connections suppressed';
    }
  }
}

/** Opaque subscription IDs (Android: "sub-" + UUID). */
export function generateNostrSubscriptionId(): string {
  return 'sub-' + util.generateRandomUUID(false);
}
