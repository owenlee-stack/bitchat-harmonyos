/**
 * Channel chat destination (T049, US9): one joined '#tag' channel.
 *
 * Pushed through the system route table (router_map, name 'channelChat')
 * right after ChatViewModel.joinChannel selects the channel. The view
 * captures the channel tag on mount and renders its per-channel timeline
 * (ChatState.channelMessages) with sender grouping, a composer routed
 * through ChatViewModel.sendChannelMessage (plain channels carry the
 * channel field on the wire; password-protected channels encrypt the
 * content with the derived channel key) and a leave button that drops
 * membership (Android leaveChannel parity). Back navigation keeps the
 * membership and only returns the composer target to the main timeline.
 */
import { ChatEntry, ChatState } from '../viewmodel/ChatState';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { MessageInput } from '../components/MessageInput';
import { MessageBubble } from '../components/MessageBubble';
import { LazyListDataSource } from '../components/LazyListDataSource';

/**
 * Same-sender messages within this window collapse into one group
 * (Android MessageGrouping.GROUPING_WINDOW_MS parity: 5 minutes).
 */
const GROUPING_WINDOW_MS = 5 * 60 * 1000;

const MAX_CHANNEL_INPUT_LENGTH = 500;
/** Defer so the List lays the new row out before scrolling. */
const SCROLL_DEFER_MS = 50;

/** Render model: one channel timeline entry plus its grouping decision. */
class ChannelRow {
  readonly entry: ChatEntry;
  readonly showSender: boolean;

  constructor(entry: ChatEntry, showSender: boolean) {
    this.entry = entry;
    this.showSender = showSender;
  }
}

@Builder
export function ChannelChatViewBuilder() {
  ChannelChatView()
}

@ComponentV2
export struct ChannelChatView {
  @Local chatState: ChatState = ChatViewModel.getInstance().state;
  @Local inputText: string = '';
  /** Channel tag captured on mount ('#tag'); the destination's identity. */
  private viewingChannel: string = '';
  private scroller: Scroller = new Scroller();
  private scrollTimer: number = -1;
  private navPathStack: NavPathStack = new NavPathStack();
  /** T079: lazy rows keep the 60fps stream on long timelines (SC-007). */
  private dataSource: LazyListDataSource<ChannelRow> = new LazyListDataSource<ChannelRow>();

  @Computed
  get rows(): ChannelRow[] {
    const timeline: ChatEntry[] | undefined =
      this.chatState.channelMessages.get(this.viewingChannel);
    return ChannelChatView.buildRows(timeline !== undefined ? timeline : []);
  }

  @Monitor('chatState.channelMessages')
  onMessagesChanged(): void {
    this.dataSource.reload(this.rows);
    this.scheduleScrollToBottom();
  }

  aboutToAppear(): void {
    this.viewingChannel = this.chatState.currentChannel;
    this.dataSource.reload(this.rows);
    this.scheduleScrollToBottom();
  }

  aboutToDisappear(): void {
    if (this.scrollTimer >= 0) {
      clearTimeout(this.scrollTimer);
      this.scrollTimer = -1;
    }
    // Back navigation keeps the membership; only the composer target
    // returns to the main timeline (Android parity). A channel switched
    // underneath (join while covered) stays selected.
    if (this.chatState.currentChannel === this.viewingChannel) {
      ChatViewModel.getInstance().closeChannelView();
    }
  }

  build() {
    NavDestination() {
      Column() {
        if (this.rows.length === 0) {
          Column({ space: 8 }) {
            Text('此频道还没有消息')
              .fontSize(15)
              .fontColor('#888888')
            Text('发送第一条频道消息，已加入的成员将收到')
              .fontSize(12)
              .fontColor('#666666')
              .textAlign(TextAlign.Center)
          }
          .justifyContent(FlexAlign.Center)
          .layoutWeight(1)
        } else {
          List({ scroller: this.scroller, space: 2 }) {
            LazyForEach(this.dataSource, (row: ChannelRow) => {
              ListItem() {
                this.messageRow(row)
              }
            }, (row: ChannelRow) => row.entry.idHex)
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)
          .padding({ top: 4, bottom: 4 })
        }

        MessageInput({
          inputText: this.inputText!!,
          placeholder: '频道消息…',
          maxInputLength: MAX_CHANNEL_INPUT_LENGTH,
          sending: this.chatState.sending,
          sendButtonColor: '#2E7D32',
          onSendText: (): void => {
            this.sendChannel();
          }
        })
      }
      .width('100%')
      .height('100%')
    }
    .title(this.destinationTitle())
    .menus([{ value: 'Leave', action: (): void => {
      this.leaveCurrentChannel();
    } }])
    .onReady((ctx: NavDestinationContext) => {
      this.navPathStack = ctx.pathStack;
    })
  }

  private destinationTitle(): string {
    return this.viewingChannel === '' ? '频道' : this.viewingChannel;
  }

  @Builder
  private messageRow(row: ChannelRow) {
    MessageBubble({
      content: row.entry.content,
      isMine: row.entry.isMine,
      isSystem: false,
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

  private async sendChannel(): Promise<void> {
    const text: string = this.inputText;
    if (text.trim().length === 0 || this.viewingChannel === '') {
      return;
    }
    // IRC commands (T039) work inside a channel too (/clear et al).
    if (text.startsWith('/')) {
      if (ChatViewModel.getInstance().processCommandInput(text)) {
        this.inputText = '';
        this.dismissSuggestionPopups();
      }
      return;
    }
    const accepted: boolean = await ChatViewModel.getInstance()
      .sendChannelMessage(text, this.viewingChannel);
    if (accepted) {
      this.inputText = '';
      this.dismissSuggestionPopups();
    }
  }

  /** Leave button: drop membership, then pop back to the public timeline. */
  private leaveCurrentChannel(): void {
    ChatViewModel.getInstance().leaveChannel(this.viewingChannel);
    this.navPathStack.pop();
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

  private static buildRows(messages: ChatEntry[]): ChannelRow[] {
    const rows: ChannelRow[] = [];
    for (let i: number = 0; i < messages.length; i++) {
      const entry: ChatEntry = messages[i];
      let showSender: boolean = true;
      if (i > 0) {
        const previous: ChatEntry = messages[i - 1];
        showSender = previous.senderPeerId !== entry.senderPeerId ||
          entry.timestampMs - previous.timestampMs > GROUPING_WINDOW_MS;
      }
      rows.push(new ChannelRow(entry, showSender));
    }
    return rows;
  }
}
