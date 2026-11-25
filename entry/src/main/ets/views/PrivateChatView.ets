/**
 * Private chat destination (T036): one Noise-encrypted 1:1 conversation.
 *
 * Pushed through the system route table (router_map, name 'privateChat').
 * The pusher (ConversationListView / PeerNetworkView) opens the
 * conversation in the ChatViewModel before pushing, so this destination
 * only renders the @Trace private-chat state. Messages render like the
 * public timeline (grouping by sender + gap) with the delivery-receipt ladder under outgoing bubbles (发送中/已送达/已读/
 * 发送失败); the composer routes through ChatViewModel.sendPrivateText,
 * which persists as SENDING and hands off to the MessageRouter.
 *
 * US10 (T053): media rows (image/file/voice) render as MediaBubble with
 * transfer progress bound to ChatState.mediaProgress; 图片/文件 pickers
 * feed ChatViewModel.sendPrivateMediaFromPicker; a legacy-0x22 consent
 * cover binds to ChatState.pendingLegacyConsent (plan.md D12 disclosure).
 *
 * US10 (T054): 语音 starts one microphone capture (microphone permission
 * via abilityAccessCtrl first); voice bubbles carry waveform,
 * playback fraction and duration through to MediaBubble.
 *
 * US14 (T070): the 语音 entry is a hold-to-talk key (PttButton): a
 * deliberate 220 ms hold arms the capture, release sends (600 ms
 * minimum, slide-up cancels) and the strip shows the elapsed time plus
 * the scrolling waveform (RealtimeWaveform). An incoming live burst
 * from the peer renders as the green 正在说话 strip.
 */
import { picker } from '@kit.CoreFileKit';
import { abilityAccessCtrl, PermissionRequestResult } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatState, LiveVoiceIncomingState, PrivateMessageEntry } from '../viewmodel/ChatState';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { BitchatMessageType, DeliveryStatusKind } from '../model/BitchatMessage';
import { MessageInput } from '../components/MessageInput';
import { MessageBubble } from '../components/MessageBubble';
import { MediaBubble } from '../components/MediaBubble';
import { PttButton } from '../components/PttButton';
import { RealtimeWaveform } from '../components/RealtimeWaveform';
import { LazyListDataSource } from '../components/LazyListDataSource';
import { ChatUserSheet } from '../components/ChatUserSheet';
import { VerificationSheet } from '../components/VerificationSheet';

const DOMAIN = 0x0000;
const TAG = 'PrivateChatView';

/**
 * Same-sender messages within this window collapse into one group
 * (Android MessageGrouping.GROUPING_WINDOW_MS parity: 5 minutes).
 */
const GROUPING_WINDOW_MS = 5 * 60 * 1000;

/** Input cap (chars); the byte cap is re-checked at send (TLV 1-byte length). */
const MAX_PRIVATE_INPUT_LENGTH = 255;

/** Defer so the List lays the new row out before scrolling. */
const SCROLL_DEFER_MS = 50;

/** Render model: one message entry plus its grouping decision. */
class PrivateRow {
  readonly entry: PrivateMessageEntry;
  readonly showSender: boolean;

  constructor(entry: PrivateMessageEntry, showSender: boolean) {
    this.entry = entry;
    this.showSender = showSender;
  }
}

@Builder
export function PrivateChatViewBuilder() {
  PrivateChatView()
}

@ComponentV2
export struct PrivateChatView {
  @Local chatState: ChatState = ChatViewModel.getInstance().state;
  @Local inputText: string = '';
  /** Identity-level sheets of the open conversation (US11, T057). */
  @Local showUserSheet: boolean = false;
  @Local showVerificationSheet: boolean = false;
  private scroller: Scroller = new Scroller();
  private scrollTimer: number = -1;
  /** T079: lazy rows keep the 60fps stream on long timelines (SC-007). */
  private dataSource: LazyListDataSource<PrivateRow> = new LazyListDataSource<PrivateRow>();

  @Computed
  get rows(): PrivateRow[] {
    return PrivateChatView.buildRows(this.chatState.privateMessages);
  }

  /** Verified mark of the open conversation (US11 header badge). */
  @Computed
  get peerVerified(): boolean {
    const conversationId: string = this.chatState.selectedConversationId;
    return conversationId !== '' &&
      ChatViewModel.getInstance().isConversationVerified(conversationId);
  }

  /** Every image path of the open conversation (fullscreen swipe set). */
  @Computed
  get imagePaths(): string[] {
    const paths: string[] = [];
    const entries: PrivateMessageEntry[] = this.chatState.privateMessages;
    for (let i: number = 0; i < entries.length; i++) {
      if (entries[i].messageType === BitchatMessageType.IMAGE &&
        entries[i].content !== '' && paths.indexOf(entries[i].content) < 0) {
        paths.push(entries[i].content);
      }
    }
    return paths;
  }

  @Monitor('chatState.privateMessages')
  onMessagesChanged(): void {
    this.dataSource.reload(this.rows);
    this.scheduleScrollToBottom();
  }

  aboutToAppear(): void {
    this.dataSource.reload(this.rows);
    this.scheduleScrollToBottom();
  }

  /** The destination was popped: release the open-conversation state. */
  aboutToDisappear(): void {
    if (this.scrollTimer >= 0) {
      clearTimeout(this.scrollTimer);
      this.scrollTimer = -1;
    }
    ChatViewModel.getInstance().closePrivateConversation();
  }

  build() {
    NavDestination() {
      Column() {
        this.peerHeaderBar()

        if (this.rows.length === 0) {
          Column({ space: 8 }) {
            Text('还没有消息')
              .fontSize(15)
              .fontColor('#888888')
            Text('发送的第一条消息将通过 Noise 端到端加密传输')
              .fontSize(12)
              .fontColor('#666666')
              .textAlign(TextAlign.Center)
          }
          .justifyContent(FlexAlign.Center)
          .layoutWeight(1)
        } else {
          List({ scroller: this.scroller, space: 2 }) {
            LazyForEach(this.dataSource, (row: PrivateRow) => {
              ListItem() {
                this.messageRow(row)
              }
            }, (row: PrivateRow) => row.entry.messageID)
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)
          .padding({ top: 4, bottom: 4 })
        }

        if (this.chatState.liveVoiceIncoming !== null &&
          this.chatState.liveVoiceIncoming.directMessage) {
          this.incomingLiveStrip()
        }

        if (this.chatState.voiceRecording) {
          this.recordingStrip()
        }
        // Always mounted: the PTT key survives the strip swap so the
        // release gesture always lands on it (T070).
        this.attachmentBar()

        MessageInput({
          inputText: this.inputText!!,
          placeholder: '加密消息…',
          maxInputLength: MAX_PRIVATE_INPUT_LENGTH,
          sending: this.chatState.privateSending,
          sendButtonColor: '#1565C0',
          onSendText: (): void => {
            this.sendPrivate();
          }
        })
      }
      .width('100%')
      .height('100%')
      .bindContentCover(this.chatState.pendingLegacyConsent !== null,
        this.consentCoverBuilder(), {
        modalTransition: ModalTransition.DEFAULT
      })
    }
    .title(this.destinationTitle())
    .bindContentCover(this.showUserSheet || this.showVerificationSheet,
      this.identitySheetBuilder(), {
      modalTransition: ModalTransition.DEFAULT
    })
  }

  /** Peer identity bar (US11, T057): name + 已验证 badge, opens ChatUserSheet. */
  @Builder
  private peerHeaderBar() {
    Row({ space: 8 }) {
      Text(this.destinationTitle())
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#E0E0E0')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '62%' })
      if (this.peerVerified) {
        Text('已验证')
          .fontSize(10)
          .fontColor('#81C784')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(6)
          .backgroundColor('#1B3A22')
      }
      Blank()
      Text('›')
        .fontSize(20)
        .fontColor('#64B5F6')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .border({ width: { bottom: 1 }, color: '#262626' })
    .onClick(() => {
      this.showUserSheet = true;
    })
  }

  /** Identity sheets (US11): verification sheet takes precedence. */
  @Builder
  private identitySheetBuilder() {
    if (this.showVerificationSheet) {
      VerificationSheet({
        conversationId: this.chatState.selectedConversationId,
        onClose: (): void => {
          this.showVerificationSheet = false;
        }
      })
    } else {
      ChatUserSheet({
        conversationId: this.chatState.selectedConversationId,
        onClose: (): void => {
          this.showUserSheet = false;
        },
        onRequestVerification: (): void => {
          this.showVerificationSheet = true;
        }
      })
    }
  }

  /** 图片/文件 entry points + the hold-to-talk key (T070). */
  @Builder
  private attachmentBar() {
    Row({ space: 16 }) {
      Text('图片')
        .fontSize(13)
        .fontColor('#64B5F6')
        .padding({ top: 6, bottom: 6 })
        .onClick(() => {
          this.pickImage();
        })
      Text('文件')
        .fontSize(13)
        .fontColor('#64B5F6')
        .padding({ top: 6, bottom: 6 })
        .onClick(() => {
          this.pickFile();
        })
      PttButton({
        recording: this.chatState.voiceRecording,
        onCaptureStart: (): void => {
          void this.startVoiceRecording();
        },
        onCaptureFinish: (): void => {
          void ChatViewModel.getInstance().stopVoiceRecordingAndSend();
        },
        onCaptureCancel: (): void => {
          void ChatViewModel.getInstance().cancelVoiceRecording();
        }
      })
    }
    .width('100%')
    .justifyContent(FlexAlign.End)
    .padding({ left: 16, right: 16 })
  }

  /** PTT capture strip (T070): elapsed + scrolling waveform + hint. */
  @Builder
  private recordingStrip() {
    Row({ space: 10 }) {
      Circle({ width: 10, height: 10 })
        .fill('#E57373')
      Text(PrivateChatView.formatDurationMs(this.chatState.voiceRecordingElapsedMs))
        .fontSize(13)
        .fontColor('#E57373')
        .fontFamily('monospace')
        .width(38)
      RealtimeWaveform({
        samples: this.chatState.voiceRecordingWaveform,
        fillColor: '#E57373'
      })
      Text('松开发送 · 上滑取消')
        .fontSize(11)
        .fontColor('#999999')
      Button('取消')
        .fontSize(13)
        .padding({ left: 12, right: 12 })
        .backgroundColor('#455A64')
        .onClick(() => {
          void ChatViewModel.getInstance().cancelVoiceRecording();
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, top: 6, bottom: 6 })
  }

  /** Incoming live PTT strip (T070): talker + scrolling waveform. */
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

  /** Legacy-0x22 plaintext-fallback disclosure (plan.md D12). */
  @Builder
  private consentCoverBuilder() {
    Column({ space: 14 }) {
      Text('发送未加密文件？')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFB300')
      Text(this.consentWarningText())
        .fontSize(14)
        .fontColor('#CCCCCC')
      Text('接收方：' + this.consentRecipientText() + ' · 文件：' +
        this.consentFileNameText())
        .fontSize(12)
        .fontColor('#999999')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Row({ space: 12 }) {
        Button('取消')
          .fontSize(14)
          .backgroundColor('#455A64')
          .layoutWeight(1)
          .onClick(() => {
            ChatViewModel.getInstance().cancelLegacyMediaConsent();
          })
        Button('仍要发送')
          .fontSize(14)
          .backgroundColor('#B45309')
          .layoutWeight(1)
          .onClick(() => {
            ChatViewModel.getInstance().approveLegacyMediaConsent();
          })
      }
      .width('100%')
    }
    .padding(24)
    .borderRadius(16)
    .backgroundColor('#1C1C1E')
    .width('86%')
    .constraintSize({ maxHeight: '70%' })
  }

  private consentWarningText(): string {
    const prompt = this.chatState.pendingLegacyConsent;
    return prompt === null ? '' : prompt.warning;
  }

  private consentRecipientText(): string {
    const prompt = this.chatState.pendingLegacyConsent;
    return prompt === null ? '' : prompt.recipientNickname;
  }

  private consentFileNameText(): string {
    const prompt = this.chatState.pendingLegacyConsent;
    return prompt === null ? '' : prompt.fileName;
  }

  private destinationTitle(): string {
    const conversationID: string = this.chatState.selectedConversationId;
    if (conversationID === '') {
      return '私聊';
    }
    return ChatViewModel.getInstance().getConversationDisplayName(conversationID);
  }

  @Builder
  private messageRow(row: PrivateRow) {
    if (PrivateChatView.isSystemRow(row.entry)) {
      Text(row.entry.content)
        .fontSize(12)
        .fontColor('#8A8A8A')
        .textAlign(TextAlign.Center)
        .padding({ top: 2, bottom: 2 })
    } else if (row.entry.messageType === BitchatMessageType.MESSAGE) {
      MessageBubble({
        content: row.entry.content,
        isMine: row.entry.isMine,
        isSystem: false,
        showSender: row.showSender,
        senderName: row.entry.senderNickname,
        timestampMs: row.entry.timestampMs,
        bubblesMode: this.chatState.bubblesMode,
        mineBackgroundColor: '#1565C0',
        othersBackgroundColor: '#2A2A2A'
      })
    } else {
      MediaBubble({
        mediaType: row.entry.messageType,
        content: row.entry.content,
        isMine: row.entry.isMine,
        showSender: row.showSender,
        senderName: row.entry.senderNickname,
        timestampMs: row.entry.timestampMs,
        bubblesMode: this.chatState.bubblesMode,
        progressPercent: this.progressPercentOf(row.entry),
        transferFailed: this.transferFailedOf(row.entry),
        notEndToEndEncrypted: row.entry.notEndToEndEncrypted,
        imagePaths: this.imagePaths,
        imageIndex: this.imageIndexOf(row.entry),
        mineBackgroundColor: '#1565C0',
        othersBackgroundColor: '#2A2A2A',
        waveform: this.audioWaveformOf(row.entry),
        isPlaying: this.audioPlayingOf(row.entry),
        playbackFraction: this.audioFractionOf(row.entry),
        durationText: this.audioDurationTextOf(row.entry),
        onTogglePlay: (): void => {
          ChatViewModel.getInstance().toggleVoiceNotePlayback(row.entry.content);
        },
        onSeekWaveform: (fraction: number): void => {
          ChatViewModel.getInstance().seekVoiceNote(fraction);
        }
      })
    }
    if (row.entry.isMine) {
      Text(PrivateChatView.statusTextOf(row.entry.deliveryStatus))
        .fontSize(10)
        .fontColor(PrivateChatView.statusColorOf(row.entry.deliveryStatus))
        .alignSelf(ItemAlign.End)
    }
  }

  /** Outgoing transfer progress bound through ChatState.mediaProgress. */
  private progressPercentOf(entry: PrivateMessageEntry): number {
    if (!entry.isMine || entry.transferId === '') {
      return -1;
    }
    const progress = this.chatState.mediaProgress.get(entry.transferId);
    if (progress === undefined) {
      return -1;
    }
    if (progress.completed) {
      return -1;
    }
    if (progress.failed) {
      return 0;
    }
    if (progress.total <= 0) {
      return 0;
    }
    return Math.min(Math.floor(progress.sent * 100 / progress.total), 99);
  }

  private transferFailedOf(entry: PrivateMessageEntry): boolean {
    if (!entry.isMine || entry.transferId === '') {
      return false;
    }
    const progress = this.chatState.mediaProgress.get(entry.transferId);
    return progress !== undefined && progress.failed;
  }

  private imageIndexOf(entry: PrivateMessageEntry): number {
    return this.imagePaths.indexOf(entry.content);
  }

  /** Normalized waveform bins of one voice note ([] when undecodable). */
  private audioWaveformOf(entry: PrivateMessageEntry): number[] {
    if (entry.messageType !== BitchatMessageType.AUDIO || entry.content === '') {
      return [];
    }
    return ChatViewModel.getInstance().getVoiceWaveform(entry.content);
  }

  /** True while this note is the one currently playing (T054). */
  private audioPlayingOf(entry: PrivateMessageEntry): boolean {
    const playback = this.chatState.voicePlayback;
    return playback !== null && playback.path === entry.content &&
      playback.playing;
  }

  /** Playback position as [0,1] of the note duration (T054). */
  private audioFractionOf(entry: PrivateMessageEntry): number {
    const playback = this.chatState.voicePlayback;
    if (playback === null || playback.path !== entry.content ||
      playback.durationMs <= 0) {
      return 0;
    }
    return Math.min(Math.max(playback.positionMs / playback.durationMs, 0), 1);
  }

  /** 'm:ss / m:ss' while playing, else the whole-note duration (T054). */
  private audioDurationTextOf(entry: PrivateMessageEntry): string {
    const playback = this.chatState.voicePlayback;
    if (playback !== null && playback.path === entry.content &&
      playback.durationMs > 0) {
      return PrivateChatView.formatDurationMs(playback.positionMs) + ' / ' +
        PrivateChatView.formatDurationMs(playback.durationMs);
    }
    const durationMs: number =
      ChatViewModel.getInstance().getVoiceNoteDurationMs(entry.content);
    return durationMs > 0 ? PrivateChatView.formatDurationMs(durationMs) : '';
  }

  /** Microphone gate: request the runtime permission, then start. */
  private async startVoiceRecording(): Promise<void> {
    if (!(await this.ensureMicrophonePermission())) {
      hilog.warn(DOMAIN, TAG, 'microphone permission not granted');
      return;
    }
    const started: boolean =
      await ChatViewModel.getInstance().startVoiceRecording();
    if (!started) {
      hilog.warn(DOMAIN, TAG, 'voice recording failed to start');
    }
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

  private async ensureMicrophonePermission(): Promise<boolean> {
    try {
      const atManager: abilityAccessCtrl.AtManager =
        abilityAccessCtrl.createAtManager();
      const result: PermissionRequestResult =
        await atManager.requestPermissionsFromUser(getContext(this),
          ['ohos.permission.MICROPHONE']);
      for (let i = 0; i < result.authResults.length; i++) {
        if (result.authResults[i] === 0) {
          return true;
        }
      }
      return false;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'mic permission request failed: %{public}s',
        JSON.stringify(e));
      return false;
    }
  }

  /** m:ss (minutes unpadded, seconds zero-padded). */
  private static formatDurationMs(durationMs: number): string {
    const totalSeconds: number = Math.floor(Math.max(0, durationMs) / 1000);
    const minutes: number = Math.floor(totalSeconds / 60);
    const seconds: number = totalSeconds % 60;
    return minutes + ':' + (seconds < 10 ? '0' + seconds : '' + seconds);
  }

  /** Policy/system rows created by addPrivateSystemMessage render flat. */
  private static isSystemRow(entry: PrivateMessageEntry): boolean {
    return !entry.isMine && entry.senderNickname === '' &&
      entry.messageType === BitchatMessageType.MESSAGE;
  }

  /** Suggestion popups linger when the field is cleared in code (no onChange). */
  private dismissSuggestionPopups(): void {
    ChatViewModel.getInstance().clearSuggestionPopups();
  }

  private async sendPrivate(): Promise<void> {
    const text: string = this.inputText;
    if (text.trim().length === 0) {
      return;
    }
    // IRC commands (T039) work inside a private chat too (/clear et al).
    if (text.startsWith('/')) {
      if (ChatViewModel.getInstance().processCommandInput(text)) {
        this.inputText = '';
        this.dismissSuggestionPopups();
      }
      return;
    }
    const accepted: boolean = await ChatViewModel.getInstance().sendPrivateText(text);
    if (accepted) {
      this.inputText = '';
      this.dismissSuggestionPopups();
    }
  }

  private pickImage(): void {
    try {
      const photoPicker: picker.PhotoViewPicker = new picker.PhotoViewPicker();
      const options: picker.PhotoSelectOptions = new picker.PhotoSelectOptions();
      options.MIMEType = picker.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      photoPicker.select(options).then((result: picker.PhotoSelectResult) => {
        if (result.photoUris.length === 0) {
          return;
        }
        const uri: string = result.photoUris[0];
        ChatViewModel.getInstance().sendPrivateMediaFromPicker(uri,
          PrivateChatView.displayNameFromUri(uri), true);
      }).catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'photo picker failed: %{public}s', JSON.stringify(error));
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'photo picker throw: %{public}s', JSON.stringify(e));
    }
  }

  private pickFile(): void {
    try {
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      documentPicker.select(options).then((uris: Array<string>) => {
        if (uris.length === 0) {
          return;
        }
        const uri: string = uris[0];
        ChatViewModel.getInstance().sendPrivateMediaFromPicker(uri,
          PrivateChatView.displayNameFromUri(uri),
          PrivateChatView.uriLooksLikeImage(uri));
      }).catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'document picker failed: %{public}s', JSON.stringify(error));
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'document picker throw: %{public}s', JSON.stringify(e));
    }
  }

  private static displayNameFromUri(uri: string): string {
    const withoutQuery: string = uri.split('?')[0];
    const slash: number = withoutQuery.lastIndexOf('/');
    const name: string = slash >= 0 ? withoutQuery.substring(slash + 1) : withoutQuery;
    return decodeURIComponent(name);
  }

  private static uriLooksLikeImage(uri: string): boolean {
    const lower: string = uri.toLowerCase();
    return lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.png') ||
      lower.endsWith('.gif') || lower.endsWith('.webp') || lower.endsWith('.bmp') ||
      lower.endsWith('.heic');
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

  private static buildRows(entries: PrivateMessageEntry[]): PrivateRow[] {
    const rows: PrivateRow[] = [];
    for (let i: number = 0; i < entries.length; i++) {
      const entry: PrivateMessageEntry = entries[i];
      let showSender: boolean = true;
      if (i > 0) {
        const previous: PrivateMessageEntry = entries[i - 1];
        showSender = previous.isMine !== entry.isMine ||
          entry.timestampMs - previous.timestampMs > GROUPING_WINDOW_MS;
      }
      rows.push(new PrivateRow(entry, showSender));
    }
    return rows;
  }

  /** Delivery-receipt ladder shown under outgoing bubbles. */
  private static statusTextOf(status: DeliveryStatusKind): string {
    switch (status) {
      case DeliveryStatusKind.SENDING:
        return '发送中';
      case DeliveryStatusKind.SENT:
        return '已发送';
      case DeliveryStatusKind.DELIVERED:
        return '已送达';
      case DeliveryStatusKind.READ:
        return '已读';
      case DeliveryStatusKind.FAILED:
        return '发送失败';
      case DeliveryStatusKind.PARTIALLY_DELIVERED:
        return '部分送达';
      default:
        return '';
    }
  }

  private static statusColorOf(status: DeliveryStatusKind): string {
    if (status === DeliveryStatusKind.READ) {
      return '#64B5F6';
    }
    if (status === DeliveryStatusKind.DELIVERED) {
      return '#81C784';
    }
    if (status === DeliveryStatusKind.FAILED) {
      return '#E57373';
    }
    return '#999999';
  }
}
