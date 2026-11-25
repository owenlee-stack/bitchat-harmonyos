/**
 * Media message bubbles (US10, T053): image / file / voice variants of
 * the private-chat transcript row, Android ui/media parity:
 *  - ImageMessageItem.kt / FullScreenImageViewer.kt: rendered thumbnail
 *    opens a fullscreen swipe viewer over every image of the open
 *    conversation (counter, close, save-to-user-file via DocumentViewPicker);
 *  - FileMessageItem.kt / FileViewerDialog.kt: file card with a
 *    type-tinted badge and an info sheet (name / size / type / save);
 *  - AudioMessageItem.kt: voice-note bubble with a play/pause control,
 *    a tappable waveform (tint up to the played position; tap-to-seek)
 *    and a duration label (T054 recorder/player wiring);
 *  - sending progress overlay (TransferProgressManager events) and the
 *    legacy 0x22 disclosure tag ('非端到端加密') that plan.md D12 requires
 *    on every plaintext fallback send.
 *
 * Dual-mode like MessageBubble (T041): messenger bubbles (default) vs
 * terminal/Matrix flat lines.
 */
import { fileIo, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { BitchatMessageType } from '../model/BitchatMessage';
import { MediaFileStore } from '../data/MediaFileStore';
import { resampleWave } from '../service/media/VoiceNoteWaveform';
import EntryAbility from '../entryability/EntryAbility';

const DOMAIN = 0x0000;
const TAG = 'MediaBubble';

/** Waveform bars inside an audio bubble (T054). */
const AUDIO_BUBBLE_BARS = 40;

/** Waveform row width: 40 bars of 3 vp + 39 gaps of 2 vp (T054). */
const AUDIO_BUBBLE_WAVEFORM_WIDTH = 40 * 3 + 39 * 2;

/** Waveform bar height range in vp (T054). */
const AUDIO_MIN_BAR_VP = 2;
const AUDIO_MAX_BAR_VP = 28;

/** Unplayed waveform bar color (T054). */
const AUDIO_BAR_IDLE_COLOR = '#64748B';

/** Played waveform bar color (T054). */
const AUDIO_BAR_PLAYED_COLOR = '#64B5F6';

/** Display metadata of one media file, resolved from its sandbox path. */
class MediaMeta {
  readonly exists: boolean;
  readonly fileName: string;
  readonly sizeText: string;

  constructor(exists: boolean, fileName: string, sizeText: string) {
    this.exists = exists;
    this.fileName = fileName;
    this.sizeText = sizeText;
  }
}

/** One rendered waveform bar: fixed height plus played tint (T054). */
class AudioBar {
  readonly heightVp: number;
  readonly played: boolean;

  constructor(heightVp: number, played: boolean) {
    this.heightVp = heightVp;
    this.played = played;
  }
}

@ComponentV2
export struct MediaBubble {
  /** Which bubble variant to render. */
  @Param mediaType: BitchatMessageType = BitchatMessageType.MESSAGE;
  /** Sandbox file path rendered by the bubble. */
  @Param content: string = '';
  @Param isMine: boolean = false;
  @Param showSender: boolean = true;
  @Param senderName: string = '';
  @Param timestampMs: number = 0;
  @Param bubblesMode: boolean = true;
  /** -1 = idle; 0..100 = in-flight percent (TransferProgressManager). */
  @Param progressPercent: number = -1;
  @Param transferFailed: boolean = false;
  /** Legacy 0x22 plaintext send: the UI must label it clearly (D12). */
  @Param notEndToEndEncrypted: boolean = false;
  /** Every image path of the open conversation (fullscreen swipe set). */
  @Param imagePaths: string[] = [];
  /** Index of this bubble's image inside imagePaths. */
  @Param imageIndex: number = 0;
  /** Bubble fill for own messages (context accent: private blue). */
  @Param mineBackgroundColor: string = '#1565C0';
  @Param othersBackgroundColor: string = '#2A2A2A';
  /** Parsed waveform bins of the note (empty when undecodable, T054). */
  @Param waveform: number[] = [];
  /** True while this note is the one currently playing (T054). */
  @Param isPlaying: boolean = false;
  /** Playback position as [0,1] of duration, for bar tinting (T054). */
  @Param playbackFraction: number = 0;
  /** Whole-note duration text (m:ss); '' while unknown (T054). */
  @Param durationText: string = '';
  /** Play/pause toggle raised on the control circle (T054). */
  @Event onTogglePlay: () => void = (): void => {};
  /** Waveform tap seek; fraction is [0,1] of the note duration (T054). */
  @Event onSeekWaveform: (fraction: number) => void =
    (fraction: number): void => {};

  @Local viewerOpen: boolean = false;
  @Local fileSheetOpen: boolean = false;
  @Local viewerIndex: number = 0;
  @Local saveHint: string = '';

  @Computed
  get meta(): MediaMeta {
    if (this.content === '') {
      return new MediaMeta(false, '', '');
    }
    try {
      const stat: fileIo.Stat = fileIo.statSync(this.content);
      const slash: number = this.content.lastIndexOf('/');
      const name: string = slash >= 0 ? this.content.substring(slash + 1) : this.content;
      return new MediaMeta(!stat.isDirectory(), name,
        MediaFileStore.formatFileSize(stat.size));
    } catch (e) {
      const slash: number = this.content.lastIndexOf('/');
      const name: string = slash >= 0 ? this.content.substring(slash + 1) : this.content;
      return new MediaMeta(false, name, '');
    }
  }

  /**
   * Waveform bars with played tint (T054). Rebuilt whenever the bins or
   * the playback fraction move so the ForEach keys carry the tint; an
   * empty waveform (M4A from Android peers) renders as a flat line.
   */
  @Computed
  get bars(): AudioBar[] {
    const raw: number[] = resampleWave(this.waveform, AUDIO_BUBBLE_BARS);
    const clampedFraction: number =
      Math.min(Math.max(this.playbackFraction, 0), 1);
    const playedCount: number = Math.round(clampedFraction * raw.length);
    const out: AudioBar[] = [];
    for (let i: number = 0; i < raw.length; i++) {
      const clamped: number = Math.min(Math.max(raw[i], 0), 1);
      const heightVp: number = AUDIO_MIN_BAR_VP +
        Math.round(clamped * (AUDIO_MAX_BAR_VP - AUDIO_MIN_BAR_VP));
      out.push(new AudioBar(heightVp, i < playedCount));
    }
    return out;
  }

  build() {
    Column({ space: 3 }) {
      if (this.bubblesMode) {
        this.bubbleLayout()
      } else {
        this.terminalLayout()
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  /** Messenger rendering: own right with a tail, others left with a header. */
  @Builder
  private bubbleLayout() {
    Column({ space: 3 }) {
      if (this.showSender && !this.isMine) {
        Row({ space: 6 }) {
          Text(this.senderName)
            .fontSize(12)
            .fontColor('#B0BEC5')
          Text(MediaBubble.formatTime(this.timestampMs))
            .fontSize(10)
            .fontColor('#757575')
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
      }
      Column({ space: 4 }) {
        if (this.mediaType === BitchatMessageType.IMAGE) {
          this.imageContent()
        } else if (this.mediaType === BitchatMessageType.AUDIO) {
          this.audioContent()
        } else {
          this.fileContent()
        }
        if (this.notEndToEndEncrypted) {
          Text('非端到端加密 · 明文回退发送')
            .fontSize(10)
            .fontColor('#FFB300')
        }
        if (this.progressPercent >= 0 && this.progressPercent < 100) {
          Row({ space: 6 }) {
            Progress({ value: this.progressPercent, total: 100,
              type: ProgressType.Linear })
              .color(this.transferFailed ? '#E57373' : '#64B5F6')
              .layoutWeight(1)
            Text(this.transferFailed ? '发送失败' : this.progressPercent + '%')
              .fontSize(10)
              .fontColor(this.transferFailed ? '#E57373' : '#999999')
          }
          .constraintSize({ maxWidth: 220 })
        }
        Row({ space: 6 }) {
          Text(MediaBubble.formatTime(this.timestampMs))
            .fontSize(10)
            .fontColor('#999999')
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
      }
      .padding(8)
      .borderRadius({
        topLeft: 12,
        topRight: 12,
        bottomLeft: this.isMine ? 12 : 4,
        bottomRight: this.isMine ? 4 : 12
      })
      .backgroundColor(this.isMine ? this.mineBackgroundColor : this.othersBackgroundColor)
      .constraintSize({ maxWidth: '78%' })
      .alignSelf(this.isMine ? ItemAlign.End : ItemAlign.Start)
      .bindContentCover(this.viewerOpen, this.imageViewerBuilder(), {
        modalTransition: ModalTransition.DEFAULT,
        onDisappear: (): void => {
          this.viewerOpen = false;
        }
      })
      .bindContentCover(this.fileSheetOpen, this.fileSheetBuilder(), {
        modalTransition: ModalTransition.DEFAULT,
        onDisappear: (): void => {
          this.fileSheetOpen = false;
        }
      })
    }
    .width('100%')
  }

  /** Terminal/Matrix rendering: flat monospace header, full-width card. */
  @Builder
  private terminalLayout() {
    Column({ space: 2 }) {
      Row({ space: 6 }) {
        Text(MediaBubble.formatTime(this.timestampMs))
          .fontSize(12)
          .fontColor('#757575')
          .fontFamily('monospace')
        Text(this.senderName)
          .fontSize(12)
          .fontColor(this.isMine ? '#90CAF9' : '#B0BEC5')
          .fontFamily('monospace')
      }
      .width('100%')
      Row() {
        Column({ space: 4 }) {
          if (this.mediaType === BitchatMessageType.IMAGE) {
            this.imageContent()
          } else if (this.mediaType === BitchatMessageType.AUDIO) {
            this.audioContent()
          } else {
            this.fileContent()
          }
          if (this.notEndToEndEncrypted) {
            Text('非端到端加密 · 明文回退发送')
              .fontSize(10)
              .fontColor('#FFB300')
              .fontFamily('monospace')
          }
          if (this.progressPercent >= 0 && this.progressPercent < 100) {
            Text(this.transferFailed ? 'xfer failed' : 'sending ' + this.progressPercent + '%')
              .fontSize(11)
              .fontColor(this.transferFailed ? '#E57373' : '#64B5F6')
              .fontFamily('monospace')
          }
        }
        .padding(8)
        .borderRadius(8)
        .backgroundColor('#1E1E1E')
      }
      .width('100%')
      .justifyContent(this.isMine ? FlexAlign.End : FlexAlign.Start)
    }
    .width('100%')
  }

  /** Image bubble: thumbnail that opens the fullscreen swipe viewer. */
  @Builder
  private imageContent() {
    if (this.meta.exists) {
      Image('file://' + this.content)
        .width(200)
        .height(150)
        .objectFit(ImageFit.Cover)
        .borderRadius(8)
        .onClick(() => {
          this.viewerIndex = this.imageIndex;
          this.viewerOpen = true;
        })
    } else {
      Text('图片不可用')
        .fontSize(12)
        .fontColor('#B0BEC5')
    }
  }

  /** File bubble: type-tinted card with name/size and an info sheet. */
  @Builder
  private fileContent() {
    Row({ space: 10 }) {
      Text(MediaBubble.badgeTextFor(this.meta.fileName))
        .fontSize(11)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .textAlign(TextAlign.Center)
        .width(44)
        .height(44)
        .borderRadius(10)
        .backgroundColor(MediaBubble.badgeColorFor(this.meta.fileName))
      Column({ space: 2 }) {
        Text(this.meta.exists ? this.meta.fileName : '文件不可用')
          .fontSize(14)
          .fontColor('#FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 180 })
        if (this.meta.exists) {
          Text(this.meta.sizeText)
            .fontSize(11)
            .fontColor('#B0BEC5')
        }
      }
      .alignItems(HorizontalAlign.Start)
    }
    .onClick(() => {
      if (this.meta.exists) {
        this.saveHint = '';
        this.fileSheetOpen = true;
      }
    })
  }

  /** Voice bubble: play/pause control, waveform bars, duration (T054). */
  @Builder
  private audioContent() {
    if (!this.meta.exists) {
      Text('语音不可用')
        .fontSize(13)
        .fontColor('#B0BEC5')
    } else {
      Row({ space: 10 }) {
        Stack() {
          Circle({ width: 34, height: 34 })
            .fill(this.isPlaying ? AUDIO_BAR_PLAYED_COLOR : '#0D47A1')
          if (this.isPlaying) {
            Row({ space: 5 }) {
              Rect()
                .width(4)
                .height(14)
                .radius(1)
                .fill(Color.White)
              Rect()
                .width(4)
                .height(14)
                .radius(1)
                .fill(Color.White)
            }
          } else {
            Path()
              .commands('M15 11 L24 17 L15 23 Z')
              .fill(Color.White)
              .width(34)
              .height(34)
          }
        }
        .width(34)
        .height(34)
        .onClick(() => {
          this.onTogglePlay();
        })
        Column({ space: 4 }) {
          Row({ space: 2 }) {
            ForEach(this.bars, (bar: AudioBar) => {
              Rect()
                .width(3)
                .height(bar.heightVp)
                .radius(1.5)
                .fill(bar.played ? AUDIO_BAR_PLAYED_COLOR : AUDIO_BAR_IDLE_COLOR)
            }, (bar: AudioBar, index: number) =>
              index + '_' + bar.heightVp + (bar.played ? 'p' : 'u'))
          }
          .height(AUDIO_MAX_BAR_VP)
          .alignItems(VerticalAlign.Center)
          .onClick((event: ClickEvent) => {
            this.onSeekWaveform(event.x / AUDIO_BUBBLE_WAVEFORM_WIDTH);
          })
          if (this.durationText !== '') {
            Text(this.durationText)
              .fontSize(11)
              .fontColor('#B0BEC5')
          }
        }
        .alignItems(HorizontalAlign.Start)
      }
    }
  }

  /** Fullscreen swipe viewer over every conversation image (Android parity). */
  @Builder
  private imageViewerBuilder() {
    Stack({ alignContent: Alignment.Top }) {
      Swiper() {
        ForEach(this.imagePaths, (path: string) => {
          Column() {
            if (MediaBubble.pathExists(path)) {
              Image('file://' + path)
                .objectFit(ImageFit.Contain)
                .layoutWeight(1)
                .width('100%')
            } else {
              Column() {
                Text('图片不可用')
                  .fontSize(14)
                  .fontColor('#FFFFFF')
              }
              .justifyContent(FlexAlign.Center)
              .layoutWeight(1)
              .width('100%')
            }
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        }, (path: string) => path)
      }
      .index(this.viewerIndex)
      .indicator(this.imagePaths.length > 1)
      .loop(false)
      .onChange((index: number) => {
        this.viewerIndex = index;
      })
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Black)

      Row() {
        if (this.imagePaths.length > 1) {
          Text((this.viewerIndex + 1) + ' / ' + this.imagePaths.length)
            .fontSize(14)
            .fontColor(Color.White)
            .textAlign(TextAlign.Center)
            .padding({ left: 12, right: 12, top: 4, bottom: 4 })
            .backgroundColor('#66000000')
            .borderRadius(12)
            .layoutWeight(1)
        } else {
          Blank()
            .layoutWeight(1)
        }
        Button('关闭')
          .fontSize(13)
          .fontColor(Color.White)
          .backgroundColor('#66000000')
          .borderRadius(18)
          .onClick(() => {
            this.viewerOpen = false;
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 40 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
  }

  /** Received-file info sheet with a save-to-user-file action. */
  @Builder
  private fileSheetBuilder() {
    Column({ space: 14 }) {
      Text('收到文件')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor('#64B5F6')
      Column({ space: 6 }) {
        Row({ space: 6 }) {
          Text('名称')
            .fontSize(13)
            .fontColor('#999999')
          Text(this.meta.fileName)
            .fontSize(13)
            .fontColor('#FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        Row({ space: 6 }) {
          Text('大小')
            .fontSize(13)
            .fontColor('#999999')
          Text(this.meta.sizeText)
            .fontSize(13)
            .fontColor('#FFFFFF')
        }
        .width('100%')
        Row({ space: 6 }) {
          Text('路径')
            .fontSize(13)
            .fontColor('#999999')
          Text(this.content)
            .fontSize(11)
            .fontColor('#B0BEC5')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      if (this.saveHint !== '') {
        Text(this.saveHint)
          .fontSize(12)
          .fontColor('#81C784')
      }
      Row({ space: 12 }) {
        Button('保存')
          .fontSize(14)
          .backgroundColor('#1565C0')
          .layoutWeight(1)
          .onClick(() => {
            this.saveToUserFile();
          })
        Button('关闭')
          .fontSize(14)
          .backgroundColor('#455A64')
          .layoutWeight(1)
          .onClick(() => {
            this.fileSheetOpen = false;
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

  /** Save the sandbox file through the system save picker. */
  private saveToUserFile(): void {
    const context: common.UIAbilityContext | null = EntryAbility.getUiAbilityContext();
    if (context === null) {
      this.saveHint = '保存失败';
      return;
    }
    try {
      const savePicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = [this.meta.fileName];
      savePicker.save(options).then((uris: Array<string>) => {
        if (uris.length === 0) {
          return;
        }
        const saved: boolean = MediaBubble.copyFile(this.content, uris[0]);
        this.saveHint = saved ? '已保存' : '保存失败';
      }).catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'save picker failed: %{public}s', JSON.stringify(error));
        this.saveHint = '保存失败';
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'save picker throw: %{public}s', JSON.stringify(e));
      this.saveHint = '保存失败';
    }
  }

  private static copyFile(sourcePath: string, destUri: string): boolean {
    try {
      const source: fileIo.File = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
      try {
        const stat: fileIo.Stat = fileIo.statSync(source.fd);
        const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
        fileIo.readSync(source.fd, buffer);
        const dest: fileIo.File = fileIo.openSync(destUri,
          fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
        try {
          fileIo.writeSync(dest.fd, buffer);
        } finally {
          fileIo.closeSync(dest);
        }
      } finally {
        fileIo.closeSync(source);
      }
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'copy to user file failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  private static pathExists(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch (e) {
      return false;
    }
  }

  private static badgeTextFor(fileName: string): string {
    const dot: number = fileName.lastIndexOf('.');
    const ext: string = dot >= 0 ? fileName.substring(dot + 1).toLowerCase() : '';
    if (ext.length > 0 && ext.length <= 4) {
      return ext.toUpperCase();
    }
    return 'FILE';
  }

  private static badgeColorFor(fileName: string): string {
    const dot: number = fileName.lastIndexOf('.');
    const ext: string = dot >= 0 ? fileName.substring(dot + 1).toLowerCase() : '';
    if (ext === 'pdf') {
      return '#DC2626';
    }
    if (ext === 'doc' || ext === 'docx') {
      return '#1D4ED8';
    }
    if (ext === 'xls' || ext === 'xlsx') {
      return '#059669';
    }
    if (ext === 'ppt' || ext === 'pptx') {
      return '#EA580C';
    }
    if (ext === 'txt' || ext === 'json' || ext === 'xml') {
      return '#7C3AED';
    }
    if (ext === 'jpg' || ext === 'jpeg' || ext === 'png' || ext === 'gif' ||
      ext === 'webp') {
      return '#2563EB';
    }
    if (ext === 'mp3' || ext === 'wav' || ext === 'm4a') {
      return '#EA580C';
    }
    if (ext === 'mp4' || ext === 'avi' || ext === 'mov') {
      return '#DC2626';
    }
    if (ext === 'zip' || ext === 'rar' || ext === '7z') {
      return '#7C2D12';
    }
    return '#6B7280';
  }

  private static formatTime(timestampMs: number): string {
    const date: Date = new Date(timestampMs);
    return MediaBubble.pad2(date.getHours()) + ':' + MediaBubble.pad2(date.getMinutes());
  }

  private static pad2(value: number): string {
    return value < 10 ? '0' + value : '' + value;
  }
}
