/**
 * Geohash location-channel destination (US13, T068): one open channel.
 *
 * Pushed through the system route table (router_map, name
 * 'locationChannel') when ChatViewModel.joinGeohashChannel selects the
 * channel. The view captures the geohash on mount and renders its
 * timeline (ChatState.geohashMessages) with sender grouping, a channel
 * subtitle (level, cell coverage, offline place name from the bundled
 * gazetteer, live participant count), a bookmark toggle and a composer
 * routed through ChatViewModel.sendGeohashChannelMessage (kind 20000
 * ephemeral events over the relays). Back navigation keeps the
 * subscription and only closes the view; the Leave menu drops it.
 */
import { util } from '@kit.ArkTS';
import { ChatEntry, ChatState } from '../viewmodel/ChatState';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { MessageInput } from '../components/MessageInput';
import { MessageBubble } from '../components/MessageBubble';
import { LazyListDataSource } from '../components/LazyListDataSource';
import { GeohashLevels } from '../service/nostr/GeohashService';
import { GeohashChannels, GeohashPlaceResolver } from '../service/nostr/GeohashChannels';
import { GlobeCity, GlobeWorldData } from '../service/globe/GlobeWorldData';

/**
 * Same-sender messages within this window collapse into one group
 * (Android MessageGrouping.GROUPING_WINDOW_MS parity: 5 minutes).
 */
const GROUPING_WINDOW_MS = 5 * 60 * 1000;

const MAX_LOCATION_INPUT_LENGTH = 500;
/** Defer so the List lays the new row out before scrolling. */
const SCROLL_DEFER_MS = 50;

/** Render model: one location-channel timeline entry plus grouping. */
class LocationRow {
  readonly entry: ChatEntry;
  readonly showSender: boolean;

  constructor(entry: ChatEntry, showSender: boolean) {
    this.entry = entry;
    this.showSender = showSender;
  }
}

@Builder
export function LocationChannelViewBuilder() {
  LocationChannelView()
}

@ComponentV2
export struct LocationChannelView {
  @Local chatState: ChatState = ChatViewModel.getInstance().state;
  @Local inputText: string = '';
  /** Offline place name of the channel ('' until the gazetteer loads). */
  @Local placeLabel: string = '';
  /** Geohash captured on mount; the destination's identity. */
  private viewingGeohash: string = '';
  private cities: GlobeCity[] = [];
  private citiesLoaded: boolean = false;
  private scroller: Scroller = new Scroller();
  private scrollTimer: number = -1;
  private navPathStack: NavPathStack = new NavPathStack();
  /** T079: lazy rows keep the 60fps stream on long timelines (SC-007). */
  private dataSource: LazyListDataSource<LocationRow> = new LazyListDataSource<LocationRow>();

  @Computed
  get rows(): LocationRow[] {
    const timeline: ChatEntry[] | undefined =
      this.chatState.geohashMessages.get(this.viewingGeohash);
    return LocationChannelView.buildRows(timeline !== undefined ? timeline : []);
  }

  @Computed
  get participantCount(): number {
    const count: number | undefined =
      this.chatState.geohashParticipantCounts.get(this.viewingGeohash);
    return count !== undefined ? count : 0;
  }

  @Computed
  get bookmarked(): boolean {
    return ChatViewModel.getInstance().isGeohashBookmarked(this.viewingGeohash);
  }

  @Monitor('chatState.geohashMessages')
  onMessagesChanged(): void {
    this.dataSource.reload(this.rows);
    this.scheduleScrollToBottom();
  }

  aboutToAppear(): void {
    this.viewingGeohash = this.chatState.currentGeohashChannel;
    this.dataSource.reload(this.rows);
    this.scheduleScrollToBottom();
    this.loadCities();
  }

  aboutToDisappear(): void {
    if (this.scrollTimer >= 0) {
      clearTimeout(this.scrollTimer);
      this.scrollTimer = -1;
    }
    // Back navigation keeps the subscription, presence and history;
    // only the open-channel selection clears (Android parity).
    if (this.chatState.currentGeohashChannel === this.viewingGeohash) {
      ChatViewModel.getInstance().closeGeohashChannelView();
    }
  }

  build() {
    NavDestination() {
      Column() {
        this.headerBar()
        if (this.rows.length === 0) {
          Column({ space: 8 }) {
            Text('此位置频道还没有消息')
              .fontSize(15)
              .fontColor('#888888')
            Text('发送第一条消息，同频道的设备将收到')
              .fontSize(12)
              .fontColor('#666666')
              .textAlign(TextAlign.Center)
          }
          .justifyContent(FlexAlign.Center)
          .layoutWeight(1)
        } else {
          List({ scroller: this.scroller, space: 2 }) {
            LazyForEach(this.dataSource, (row: LocationRow) => {
              ListItem() {
                this.messageRow(row)
              }
            }, (row: LocationRow) => row.entry.idHex)
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)
          .padding({ top: 4, bottom: 4 })
        }

        MessageInput({
          inputText: this.inputText!!,
          placeholder: '位置频道消息…',
          maxInputLength: MAX_LOCATION_INPUT_LENGTH,
          sending: this.chatState.sending,
          sendButtonColor: '#0288D1',
          onSendText: (): void => {
            this.sendLocationMessage();
          }
        })
      }
      .width('100%')
      .height('100%')
    }
    .title(this.viewingGeohash === '' ? '位置频道' : '#' + this.viewingGeohash)
    .menus([{ value: '离开', action: (): void => {
      this.leaveCurrentChannel();
    } }])
    .onReady((ctx: NavDestinationContext) => {
      this.navPathStack = ctx.pathStack;
    })
  }

  /** Channel subtitle: level, coverage, place name and live count. */
  private subtitleLine(): string {
    if (this.viewingGeohash === '') {
      return '';
    }
    const level: string = GeohashLevels.displayName(
      GeohashLevels.levelForLength(this.viewingGeohash.length)).toLowerCase();
    const coverage: string =
      GeohashChannels.coverageString(this.viewingGeohash.length);
    const place: string = this.placeLabel !== '' ? ' · ' + this.placeLabel : '';
    return `${level} · ${coverage}${place} · ${this.participantCount} 人在线`;
  }

  private async loadCities(): Promise<void> {
    if (this.citiesLoaded || this.viewingGeohash === '') {
      return;
    }
    this.citiesLoaded = true;
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        return;
      }
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      const bytes: Uint8Array =
        await context.resourceManager.getRawFileContent('world_cities.geojson');
      this.cities = GlobeWorldData.parseCities(decoder.decodeToString(bytes));
    } catch (e) {
      this.cities = [];
    }
    this.placeLabel =
      GeohashPlaceResolver.placeLabel(this.cities, this.viewingGeohash);
  }

  @Builder
  private headerBar() {
    Row({ space: 10 }) {
      Text(this.subtitleLine())
        .fontSize(12)
        .fontColor('#9E9E9E')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(this.bookmarked ? '★ 已收藏' : '☆ 收藏')
        .fontSize(12)
        .fontColor(this.bookmarked ? '#FFC107' : '#9E9E9E')
        .padding({ left: 8, top: 4, bottom: 4 })
        .onClick(() => {
          this.toggleBookmark();
        })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 6, bottom: 6 })
    .border({ width: { bottom: 1 }, color: '#262626' })
  }

  @Builder
  private messageRow(row: LocationRow) {
    MessageBubble({
      content: row.entry.content,
      isMine: row.entry.isMine,
      isSystem: false,
      showSender: row.showSender,
      senderName: row.entry.nickname,
      timestampMs: row.entry.timestampMs,
      bubblesMode: this.chatState.bubblesMode,
      mineBackgroundColor: '#0288D1',
      othersBackgroundColor: '#2A2A2A'
    })
  }

  /** Suggestion popups linger when the field is cleared in code (no onChange). */
  private dismissSuggestionPopups(): void {
    ChatViewModel.getInstance().clearSuggestionPopups();
  }

  private async sendLocationMessage(): Promise<void> {
    const text: string = this.inputText;
    if (text.trim().length === 0) {
      return;
    }
    const accepted: boolean = await ChatViewModel.getInstance()
      .sendGeohashChannelMessage(text);
    if (accepted) {
      this.inputText = '';
      this.dismissSuggestionPopups();
    }
  }

  /** Star button: toggle the bookmark of the open channel. */
  private async toggleBookmark(): Promise<void> {
    await ChatViewModel.getInstance().toggleGeohashBookmark(this.viewingGeohash);
  }

  /** Leave menu: drop the subscription and pop back. */
  private leaveCurrentChannel(): void {
    ChatViewModel.getInstance().leaveGeohashChannel(this.viewingGeohash);
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

  private static buildRows(messages: ChatEntry[]): LocationRow[] {
    const rows: LocationRow[] = [];
    for (let i: number = 0; i < messages.length; i++) {
      const entry: ChatEntry = messages[i];
      let showSender: boolean = true;
      if (i > 0) {
        const previous: ChatEntry = messages[i - 1];
        showSender = previous.senderPeerId !== entry.senderPeerId ||
          entry.timestampMs - previous.timestampMs > GROUPING_WINDOW_MS;
      }
      rows.push(new LocationRow(entry, showSender));
    }
    return rows;
  }
}
