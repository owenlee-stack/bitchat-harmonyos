/**
 * Location channels sheet (US13, T068).
 *
 * HarmonyOS port of the Android LocationChannelsSheet: the public-chat
 * entry surface for geohash location channels, opened from the
 * PublicChatView header. Rows: the currently open channel, the
 * persisted bookmarks (star to keep, ✕ to drop), a manual geohash
 * input and the globe picker jump. Selecting a channel goes through
 * ChatViewModel.joinGeohashChannel; PublicChatView watches the
 * selection and pushes the 'locationChannel' destination.
 */
import { router } from '@kit.ArkUI';
import { ChatState } from '../viewmodel/ChatState';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { GeohashLevels } from '../service/nostr/GeohashService';
import { GeohashChannels } from '../service/nostr/GeohashChannels';

const SHEET_BG = '#161616';
const SURFACE = '#1D1D1D';
const SURFACE_BORDER = '#3A3A3A';
const TEXT_PRIMARY = '#FFFFFF';
const TEXT_SECONDARY = '#9E9E9E';
const TEXT_TERTIARY = '#777777';
const ACCENT = '#0288D1';
const MAX_MANUAL_GEOHASH_LENGTH = 12;

@ComponentV2
export struct LocationChannelsSheet {
  @Local chatState: ChatState = ChatViewModel.getInstance().state;
  @Local manualGeohash: string = '';
  @Local manualError: string = '';
  /** Close callback (the hosting cover's onDisappear fallback). */
  @Event onClose: () => void = (): void => {
  };

  build() {
    Column({ space: 14 }) {
      Row() {
        Text('位置频道')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(TEXT_PRIMARY)
          .layoutWeight(1)
        Text('✕')
          .fontSize(16)
          .fontColor(TEXT_SECONDARY)
          .padding({ left: 10, top: 4, bottom: 4 })
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')

      Scroll() {
        Column({ space: 14 }) {
          this.currentChannelRow()
          this.bookmarksSection()
          this.manualEntrySection()
          this.globeSection()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 18, bottom: 18 })
    .backgroundColor(SHEET_BG)
  }

  @Builder
  private currentChannelRow() {
    if (this.chatState.currentGeohashChannel !== '') {
      Column({ space: 4 }) {
        Text('当前频道')
          .fontSize(11)
          .fontColor(TEXT_TERTIARY)
        this.channelCard(this.chatState.currentGeohashChannel, false, true)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  private bookmarksSection() {
    Column({ space: 4 }) {
      Text('收藏的频道')
        .fontSize(11)
        .fontColor(TEXT_TERTIARY)
      if (this.chatState.geohashBookmarks.length === 0) {
        Text('暂无收藏，进入频道后点 ☆ 收藏')
          .fontSize(12)
          .fontColor(TEXT_TERTIARY)
          .padding({ top: 6, bottom: 6 })
      } else {
        ForEach(this.chatState.geohashBookmarks, (geohash: string) => {
          this.channelCard(geohash, true, geohash === this.chatState.currentGeohashChannel)
        }, (geohash: string) => geohash)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private manualEntrySection() {
    Column({ space: 4 }) {
      Text('按 geohash 进入')
        .fontSize(11)
        .fontColor(TEXT_TERTIARY)
      Row({ space: 8 }) {
        TextInput({
          text: this.manualGeohash!!,
          placeholder: '例如 sxu9wr（1-12 位 base32）'
        })
          .fontSize(14)
          .fontColor(TEXT_PRIMARY)
          .placeholderColor(TEXT_TERTIARY)
          .backgroundColor(SURFACE)
          .borderRadius(12)
          .border({ width: 1, color: SURFACE_BORDER })
          .maxLength(MAX_MANUAL_GEOHASH_LENGTH)
          .layoutWeight(1)
          .onChange((value: string) => {
            this.manualGeohash = value;
            this.manualError = '';
          })
        Button('进入')
          .fontSize(14)
          .fontColor(TEXT_PRIMARY)
          .height(40)
          .borderRadius(12)
          .padding({ left: 16, right: 16 })
          .backgroundColor(ACCENT)
          .onClick(() => {
            this.joinManual();
          })
      }
      .width('100%')
      if (this.manualError !== '') {
        Text(this.manualError)
          .fontSize(11)
          .fontColor('#E57373')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private globeSection() {
    Column({ space: 4 }) {
      Text('地球仪')
        .fontSize(11)
        .fontColor(TEXT_TERTIARY)
      Row({ space: 10 }) {
        Text('🌍')
          .fontSize(22)
        Column({ space: 2 }) {
          Text('打开地球仪选择频道')
            .fontSize(14)
            .fontColor(TEXT_PRIMARY)
          Text('旋转地球，点选任意位置网格进入')
            .fontSize(11)
            .fontColor(TEXT_SECONDARY)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text('›')
          .fontSize(20)
          .fontColor(TEXT_SECONDARY)
      }
      .width('100%')
      .padding(14)
      .borderRadius(14)
      .backgroundColor(SURFACE)
      .border({ width: 1, color: SURFACE_BORDER })
      .onClick(() => {
        this.openGlobePicker();
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** One selectable channel row; bookmarked rows carry a ✕ removal. */
  @Builder
  private channelCard(geohash: string, withRemove: boolean, isCurrent: boolean) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(`#${geohash}`)
          .fontSize(15)
          .fontColor(isCurrent ? ACCENT : TEXT_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(LocationChannelsSheet.channelSubtitle(geohash))
          .fontSize(11)
          .fontColor(TEXT_SECONDARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (withRemove) {
        Text('✕')
          .fontSize(13)
          .fontColor(TEXT_TERTIARY)
          .padding({ left: 8, top: 6, bottom: 6 })
          .onClick(() => {
            this.removeBookmark(geohash);
          })
      }
      Text('›')
        .fontSize(18)
        .fontColor(TEXT_SECONDARY)
    }
    .width('100%')
    .padding(14)
    .borderRadius(14)
    .backgroundColor(SURFACE)
    .border({
      width: 1,
      color: isCurrent ? ACCENT : SURFACE_BORDER
    })
    .onClick(() => {
      this.openChannel(geohash);
    })
  }

  private static channelSubtitle(geohash: string): string {
    const level: string = GeohashLevels.displayName(
      GeohashLevels.levelForLength(geohash.length)).toLowerCase();
    const coverage: string = GeohashChannels.coverageString(geohash.length);
    return `${level} · ${coverage}`;
  }

  private openChannel(geohash: string): void {
    ChatViewModel.getInstance().joinGeohashChannel(geohash)
      .then((joined: boolean): void => {
        if (joined) {
          this.onClose();
        }
      });
  }

  private async removeBookmark(geohash: string): Promise<void> {
    await ChatViewModel.getInstance().toggleGeohashBookmark(geohash);
  }

  private async joinManual(): Promise<void> {
    const geohash: string = GeohashChannels.normalize(this.manualGeohash);
    if (!GeohashChannels.isValid(geohash)) {
      this.manualError = '无效的 geohash';
      return;
    }
    const joined: boolean =
      await ChatViewModel.getInstance().joinGeohashChannel(geohash);
    if (joined) {
      this.manualGeohash = '';
      this.manualError = '';
      this.onClose();
    } else {
      this.manualError = '加入失败，请重试';
    }
  }

  private openGlobePicker(): void {
    router.pushUrl({ url: 'pages/GeohashPickerPage' });
  }
}
