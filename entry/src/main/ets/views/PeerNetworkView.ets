/**
 * Network member list view (US2, T025).
 *
 * Renders the verified peers discovered via the BLE mesh announce layer:
 * nickname, 16-hex peerID and presence. Data flows one-directionally from
 * the service layer through the EventBus (`peer-updated` / `peer-removed`,
 * plan.md D8); the view never calls service internals. Presence follows the
 * FR-008 windows: online while the last verified contact is within
 * MeshConstants.PEER_REACHABLE_WINDOW_MS (60s), rows pruned after
 * MeshConstants.STALE_PEER_TIMEOUT_MS (180s); a 5s tick recomputes the
 * badges so entries age out without further events.
 */
import { BcEventPayload, BcEventListener, BcEvents, EventBus, PeerRemovedPayload,
  PeerUpdatedPayload } from '../common/EventBus';
import { MeshConstants } from '../common/ProtocolConstants';
import { ChatViewModel } from '../viewmodel/ChatViewModel';

/** Presence recompute cadence; 60s window granularity stays coarse. */
const PRESENCE_TICK_MS = 5000;

/** Flat row model; rebuilt (not mutated in place) so @Local assignment refreshes. */
class PeerRow {
  readonly peerId: string;
  readonly nickname: string;
  readonly lastSeenMs: number;
  readonly online: boolean;
  readonly statusText: string;
  readonly statusColor: string;

  constructor(peerId: string, nickname: string, lastSeenMs: number, nowMs: number) {
    this.peerId = peerId;
    this.nickname = nickname;
    this.lastSeenMs = lastSeenMs;
    this.online = nowMs - lastSeenMs < MeshConstants.PEER_REACHABLE_WINDOW_MS;
    this.statusText = this.online ? '在线' : '离线';
    this.statusColor = this.online ? '#4CAF50' : '#777777';
  }
}

@ComponentV2
export struct PeerNetworkView {
  @Local peers: PeerRow[] = [];
  @Param pathStack: NavPathStack = new NavPathStack();
  private tickTimer: number = -1;
  private readonly eventListener: BcEventListener = (payload: BcEventPayload): void => {
    if (payload instanceof PeerUpdatedPayload) {
      this.applyPeerUpdate(payload.peerId, payload.nickname, payload.lastSeenMs);
    } else if (payload instanceof PeerRemovedPayload) {
      this.applyPeerRemoval(payload.peerId);
    }
  };

  aboutToAppear(): void {
    EventBus.on(BcEvents.PEER_UPDATED, this.eventListener);
    EventBus.on(BcEvents.PEER_REMOVED, this.eventListener);
    this.tickTimer = setInterval(() => {
      this.refreshPresence();
    }, PRESENCE_TICK_MS);
  }

  aboutToDisappear(): void {
    EventBus.off(BcEvents.PEER_UPDATED, this.eventListener);
    EventBus.off(BcEvents.PEER_REMOVED, this.eventListener);
    if (this.tickTimer >= 0) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text('网络成员')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
        Blank()
        Text(`${this.peers.length} 台设备`)
          .fontSize(12)
          .fontColor('#888888')
      }
      .width('100%')

      if (this.peers.length === 0) {
        Column({ space: 8 }) {
          Text('未发现附近设备')
            .fontSize(14)
            .fontColor('#888888')
          Text('保持蓝牙开启，附近设备将自动出现在这里')
            .fontSize(12)
            .fontColor('#666666')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .padding({ top: 48 })
      } else {
        List({ space: 0 }) {
          ForEach(this.peers, (row: PeerRow) => {
            ListItem() {
              this.peerRow(row)
            }
          }, (row: PeerRow) => row.peerId)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20 })
  }

  @Builder
  private peerRow(row: PeerRow) {
    Row({ space: 12 }) {
      Circle({ width: 10, height: 10 })
        .fill(row.statusColor)
      Column({ space: 2 }) {
        Text(row.nickname)
          .fontSize(16)
          .fontColor('#FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(row.peerId)
          .fontSize(12)
          .fontColor('#888888')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Blank()
      Column({ space: 2 }) {
        Text(row.statusText)
          .fontSize(12)
          .fontColor(row.statusColor)
        Text('私聊 ›')
          .fontSize(12)
          .fontColor('#64B5F6')
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .onClick(() => {
      this.openPrivateChat(row);
    })
  }

  /** Tap a member: open the (Noise-encrypted) private conversation (T036). */
  private async openPrivateChat(row: PeerRow): Promise<void> {
    await ChatViewModel.getInstance().startPrivateChatWithPeer(row.peerId, row.nickname);
    this.pathStack.pushPathByName('privateChat', row.peerId);
  }

  /** Upsert one member row from a `peer-updated` event. */
  private applyPeerUpdate(peerId: string, nickname: string, lastSeenMs: number): void {
    const nowMs: number = Date.now();
    const next: PeerRow[] = this.peers.slice();
    let found: boolean = false;
    for (let i: number = 0; i < next.length; i++) {
      if (next[i].peerId === peerId) {
        next[i] = new PeerRow(peerId, nickname, lastSeenMs, nowMs);
        found = true;
        break;
      }
    }
    if (!found) {
      next.push(new PeerRow(peerId, nickname, lastSeenMs, nowMs));
    }
    next.sort(PeerNetworkView.compareRows);
    this.peers = next;
  }

  /** Drop one member row from a `peer-removed` event. */
  private applyPeerRemoval(peerId: string): void {
    const next: PeerRow[] = [];
    for (let i: number = 0; i < this.peers.length; i++) {
      if (this.peers[i].peerId !== peerId) {
        next.push(this.peers[i]);
      }
    }
    this.peers = next;
  }

  /** Recompute presence badges and prune rows past the stale timeout. */
  private refreshPresence(): void {
    const nowMs: number = Date.now();
    let changed: boolean = false;
    const next: PeerRow[] = [];
    for (let i: number = 0; i < this.peers.length; i++) {
      const row: PeerRow = this.peers[i];
      if (nowMs - row.lastSeenMs > MeshConstants.STALE_PEER_TIMEOUT_MS) {
        changed = true;
        continue;
      }
      if (row.online !== nowMs - row.lastSeenMs < MeshConstants.PEER_REACHABLE_WINDOW_MS) {
        next.push(new PeerRow(row.peerId, row.nickname, row.lastSeenMs, nowMs));
        changed = true;
      } else {
        next.push(row);
      }
    }
    if (changed) {
      next.sort(PeerNetworkView.compareRows);
      this.peers = next;
    }
  }

  /** Online rows first, then nickname, then peerID (deterministic order). */
  private static compareRows(a: PeerRow, b: PeerRow): number {
    if (a.online !== b.online) {
      return a.online ? -1 : 1;
    }
    if (a.nickname !== b.nickname) {
      return a.nickname < b.nickname ? -1 : 1;
    }
    if (a.peerId !== b.peerId) {
      return a.peerId < b.peerId ? -1 : 1;
    }
    return 0;
  }
}
