/**
 * Public chat timeline view (US3, T031).
 *
 * Renders the public broadcast timeline from the shared ChatState (plan.md
 * D8: the view model owns the state, views only read it). Messages group
 * visually by sender and a 3-minute gap; the composer signs and broadcasts
 * through ChatViewModel.sendPublicMessage, which feeds the PacketRelay /
 * TopologyMap / gossip pipeline. The list auto-scrolls to the newest entry
 * whenever the timeline is reassigned.
 *
 * US14 (T070): a public-mesh live PTT burst from a peer renders as the
 * green 正在说话 strip above the composer.
 */
import { ChatEntry, ChatState, LiveVoiceIncomingState } from '../viewmodel/ChatState';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { MessageInput } from '../components/MessageInput';
import { MessageBubble } from '../components/MessageBubble';
import { RealtimeWaveform } from '../components/RealtimeWaveform';
import { LazyListDataSource } from '../components/LazyListDataSource';
import { MessageNotificationDispatcher } from '../common/MessageNotificationDispatcher';
import { LocationChannelsSheet } from './LocationChannelsSheet';

/**
 * Same-sender messages within this window collapse into one group
 * (Android MessageGrouping.GROUPING_WINDOW_MS parity: 5 minutes).
 */
const GROUPING_WINDOW_MS = 5 * 60 * 1000;
const MAX_PUBLIC_INPUT_LENGTH = 500;
/** Defer so the List lays the new row out before scrolling. */
const SCROLL_DEFER_MS = 50;

/** Render model: one timeline entry plus its grouping decision. */
class ChatRow {
  readonly entry: ChatEntry;
  readonly showSender: boolean;
  readonly isSystem: boolean;

  constructor(entry: ChatEntry, showSender: boolean, isSystem: boolean) {
    this.entry = entry;
    this.showSender = showSender;
    this.isSystem = isSystem;
  }
}

@ComponentV2
export struct PublicChatView {
  @Param chatState: ChatState = new ChatState();
  @Param pathStack: NavPathStack = new NavPathStack();
  @Local inputText: string = '';
  /** Location channels sheet (US13, T068): globe entry cover. */
  @Local showLocationChannelsSheet: boolean = false;
  private scroller: Scroller = new Scroller();
  private scrollTimer: number = -1;
  /** T079: lazy rows keep the 60fps stream on long timelines (SC-007). */
  private dataSource: LazyListDataSource<ChatRow> = new LazyListDataSource<ChatRow>();

  @Computed
  get rows(): ChatRow[] {
    return PublicChatView.buildRows(this.chatState.messages);
  }

  @Monitor('chatState.messages')
  onMessagesChanged(): void {
    this.dataSource.reload(this.rows);
    this.scheduleScrollToBottom();
  }

  /**
   * Joining a channel selects it (T049): push the channel destination;
   * leaving / closing clears the tag and never pushes.
   */
  @Monitor('chatState.currentChannel')
  onCurrentChannelChanged(): void {
    const channel: string = this.chatState.currentChannel;
    if (channel !== '') {
      this.pathStack.pushPathByName('channelChat', channel);
    }
  }

  /**
   * Selecting a geohash location channel (US13, T068) pushes the
   * location destination and dismisses the channels sheet; closing the
   * view clears the selection and never pushes.
   */
  @Monitor('chatState.currentGeohashChannel')
  onCurrentGeohashChannelChanged(): void {
    const geohash: string = this.chatState.currentGeohashChannel;
    if (geohash !== '') {
      this.showLocationChannelsSheet = false;
      this.pathStack.pushPathByName('locationChannel', geohash);
    }
  }

  aboutToAppear(): void {
    // Viewing the public chat retires the mention notification (T046).
    MessageNotificationDispatcher.getInstance().clearMentionNotifications();
    this.dataSource.reload(this.rows);
    this.scheduleScrollToBottom();
  }

  aboutToDisappear(): void {
    if (this.scrollTimer >= 0) {
      clearTimeout(this.scrollTimer);
      this.scrollTimer = -1;
    }
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Text('公共频道')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
        Blank()
        if (this.chatState.serviceRunning) {
          if (this.chatState.connectedCount > 0) {
            Text(`${this.chatState.connectedCount} 台已连接`)
              .fontSize(12)
              .fontColor('#4CAF50')
          } else {
            Text('未连接')
              .fontSize(12)
              .fontColor('#777777')
          }
        } else {
          Text('网络启动中…')
            .fontSize(12)
            .fontColor('#777777')
        }
        Text('位置')
          .fontSize(13)
          .fontColor('#4FC3F7')
          .padding({ left: 8, top: 4, bottom: 4 })
          .onClick(() => {
            this.showLocationChannelsSheet = true;
          })
        Text('设置')
          .fontSize(13)
          .fontColor('#B0BEC5')
          .padding({ left: 8, top: 4, bottom: 4 })
          .onClick(() => {
            this.pathStack.pushPathByName('settings', '');
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 12, bottom: 8 })

      if (this.rows.length === 0) {
        Column({ space: 8 }) {
          Text('暂无消息')
            .fontSize(15)
            .fontColor('#888888')
          Text('发送一条广播，附近设备将收到并继续中继')
            .fontSize(12)
            .fontColor('#666666')
            .textAlign(TextAlign.Center)
        }
        .justifyContent(FlexAlign.Center)
        .layoutWeight(1)
      } else {
        List({ scroller: this.scroller, space: 2 }) {
          LazyForEach(this.dataSource, (row: ChatRow) => {
            ListItem() {
              this.messageRow(row)
            }
          }, (row: ChatRow) => row.entry.idHex)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .padding({ top: 4, bottom: 4 })
      }

      if (this.chatState.liveVoiceIncoming !== null &&
        !this.chatState.liveVoiceIncoming.directMessage) {
        this.incomingLiveStrip()
      }

      MessageInput({
        inputText: this.inputText!!,
        placeholder: '广播消息…',
        maxInputLength: MAX_PUBLIC_INPUT_LENGTH,
        sending: this.chatState.sending,
        sendButtonColor: '#2E7D32',
        onSendText: (): void => {
          this.sendPublic();
        }
      })
    }
    .width('100%')
    .height('100%')
    .bindContentCover(this.showLocationChannelsSheet, this.locationSheetBuilder(), {
      modalTransition: ModalTransition.DEFAULT,
      onDisappear: (): void => {
        this.showLocationChannelsSheet = false;
      }
    })
  }

  /** Location channels sheet cover (US13, T068). */
  @Builder
  private locationSheetBuilder() {
    LocationChannelsSheet({
      onClose: (): void => {
        this.showLocationChannelsSheet = false;
      }
    })
  }

  /** Incoming public-mesh live PTT strip (US14, T070). */
  @Builder
  private incomingLiveStrip() {
    Row({ space: 10 }) {
      Circle({ width: 10, height: 10 })
        .fill('#81C784')
      Text(this.incomingNickname() + ' 正在说话')
        .fontSize(12)
        .fontColor('#81C784')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '40%' })
      RealtimeWaveform({
        samples: this.incomingSamples(),
        fillColor: '#81C784'
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, top: 6, bottom: 6 })
  }

  /** Display name of the incoming live talker (T070). */
  private incomingNickname(): string {
    const incoming: LiveVoiceIncomingState | null =
      this.chatState.liveVoiceIncoming;
    return incoming === null ? '' : incoming.nickname;
  }

  /** Scrolling-waveform samples of the incoming live burst (T070). */
  private incomingSamples(): number[] {
    const incoming: LiveVoiceIncomingState | null =
      this.chatState.liveVoiceIncoming;
    return incoming === null ? [] : incoming.samples;
  }

  @Builder
  private messageRow(row: ChatRow) {
    MessageBubble({
      content: row.entry.content,
      isMine: row.entry.isMine,
      isSystem: row.isSystem,
      showSender: row.showSender,
      senderName: row.entry.nickname,
      timestampMs: row.entry.timestampMs,
      bubblesMode: this.chatState.bubblesMode,
      mineBackgroundColor: '#2E7D32',
      othersBackgroundColor: '#2A2A2A'
    })
  }

  /** Suggestion popups linger when the field is cleared in code (no onChange). */
  private dismissSuggestionPopups(): void {
    ChatViewModel.getInstance().clearSuggestionPopups();
  }

  private async sendPublic(): Promise<void> {
    const text: string = this.inputText;
    if (text.trim().length === 0) {
      return;
    }
    // IRC commands (T039) take precedence over a plain broadcast.
    if (text.startsWith('/')) {
      if (ChatViewModel.getInstance().processCommandInput(text)) {
        this.inputText = '';
        this.dismissSuggestionPopups();
      }
      return;
    }
    const accepted: boolean = await ChatViewModel.getInstance().sendPublicMessage(text);
    if (accepted) {
      this.inputText = '';
      this.dismissSuggestionPopups();
    }
  }

  private scheduleScrollToBottom(): void {
    if (this.scrollTimer >= 0) {
      clearTimeout(this.scrollTimer);
    }
    this.scrollTimer = setTimeout(() => {
      this.scrollTimer = -1;
      this.scroller.scrollEdge(Edge.Bottom);
    }, SCROLL_DEFER_MS);
  }

  private static buildRows(messages: ChatEntry[]): ChatRow[] {
    const rows: ChatRow[] = [];
    for (let i: number = 0; i < messages.length; i++) {
      const entry: ChatEntry = messages[i];
      const isSystem: boolean = PublicChatView.isSystemEntry(entry);
      let showSender: boolean = true;
      if (i > 0) {
        const previous: ChatEntry = messages[i - 1];
        // Android MessageGrouping.shouldGroup parity: system lines never
        // group in either direction, then same sender within the window.
        showSender = isSystem || PublicChatView.isSystemEntry(previous) ||
          previous.senderPeerId !== entry.senderPeerId ||
          entry.timestampMs - previous.timestampMs > GROUPING_WINDOW_MS;
      }
      rows.push(new ChatRow(entry, showSender, isSystem));
    }
    return rows;
  }

  /** System notices ('system' sender, no peer ID) are narration lines. */
  private static isSystemEntry(entry: ChatEntry): boolean {
    return entry.senderPeerId === '' && entry.nickname === 'system';
  }
}
