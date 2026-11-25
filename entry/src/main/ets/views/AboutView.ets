/**
 * About / panic-trigger screen (T044): the HarmonyOS analogue of the
 * Android AboutSheet.
 *
 * Pushed through the system route table (router_map, name 'about') from
 * the settings page. The hero logo carries the panic trigger: three taps
 * within the Android BitChatBrandButton.MultiClickThreshold window open
 * the CommonDialogs confirmation; confirming wipes everything (T043) and
 * toasts the outcome while the persistent system notice lands in the
 * public timeline. The remaining sections mirror the Android about
 * content (features, how-to, panic mode) with translated strings.
 */
import { CommonDialogs } from '../components/CommonDialogs';

/** Android BitChatBrandButton.MultiClickThreshold parity (ms). */
const MULTI_CLICK_THRESHOLD_MS = 300;
const APP_VERSION = '1.0.0';
/** Android tagline verbatim (brand copy stays untranslated). */
const APP_TAGLINE = 'The sidegroup chat';

@Builder
export function AboutViewBuilder() {
  AboutView()
}

@ComponentV2
export struct AboutView {
  private tapCount: number = 0;
  private tapResetTimer: number = -1;

  aboutToDisappear(): void {
    if (this.tapResetTimer >= 0) {
      clearTimeout(this.tapResetTimer);
      this.tapResetTimer = -1;
    }
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 24 }) {
          this.hero()
          this.featuresSection()
          this.howToUseSection()
          this.panicSection()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 20, right: 20, top: 12, bottom: 32 })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .title('关于')
  }

  /** Centered app identity: logo (panic trigger), wordmark, tagline. */
  @Builder
  private hero() {
    Column({ space: 10 }) {
      Text('b')
        .fontSize(38)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .textAlign(TextAlign.Center)
        .width(64)
        .height(64)
        .borderRadius(32)
        .backgroundColor('#4CAF50')
        .onClick(() => {
          this.onLogoTap();
        })
      Text('bitchat')
        .fontSize(32)
        .fontWeight(FontWeight.Bold)
        .fontColor('#4CAF50')
      Text(APP_TAGLINE)
        .fontSize(14)
        .fontColor('#B0BEC5')
      Text(`v${APP_VERSION}`)
        .fontSize(12)
        .fontColor('#777777')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .margin({ top: 8 })
  }

  /** App capability rows (Android AboutFeatureCard parity). */
  @Builder
  private featuresSection() {
    Column({ space: 2 }) {
      Text('特性')
        .fontSize(13)
        .fontColor('#888888')
      this.featureRow('离线通信', '通过蓝牙 mesh 聊天，无需互联网和服务器。消息经附近设备中继以扩展范围。')
      this.featureRow('端到端加密', '私聊消息已加密。频道消息公开。')
      this.featureRow('本地频道', 'Geohash 频道连接附近的人，通过公共中继扩展 mesh。')
      this.featureRow('无追踪', '无服务器、无账号、无数据收集。')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private featureRow(title: string, description: string) {
    Column({ space: 3 }) {
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
      Text(description)
        .fontSize(12)
        .fontColor('#888888')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 10, bottom: 10 })
  }

  /** Usage cheat-sheet (Android AboutHowToUseSection parity). */
  @Builder
  private howToUseSection() {
    Column({ space: 2 }) {
      Text('使用方法')
        .fontSize(13)
        .fontColor('#888888')
      this.instructionRow('点击昵称即可修改昵称')
      this.instructionRow('点击频道名切换频道')
      this.instructionRow('点击成员图标查看频道成员')
      this.instructionRow('收藏频道以保留在列表中')
      this.instructionRow('输入 @ 提及某人')
      this.instructionRow('输入 / 查看可用命令')
      this.instructionRow('三连击 logo 清除所有数据')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private instructionRow(text: string) {
    Row({ space: 8 }) {
      Text('·')
        .fontSize(15)
        .fontColor('#4CAF50')
      Text(text)
        .fontSize(14)
        .fontColor('#DDDDDD')
    }
    .width('100%')
    .padding({ top: 7, bottom: 7 })
  }

  /** Emergency wipe explanation (Android about_emergency_title parity). */
  @Builder
  private panicSection() {
    Column({ space: 3 }) {
      Text('紧急擦除')
        .fontSize(13)
        .fontColor('#888888')
      Text('三连击 logo 立即清除所有数据。')
        .fontSize(14)
        .fontColor('#DDDDDD')
        .padding({ top: 7, bottom: 7 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * Multi-tap detector (Android BitChatBrandButton parity): three taps
   * within the threshold fire the trigger; the counter resets otherwise.
   */
  private onLogoTap(): void {
    if (this.tapResetTimer >= 0) {
      clearTimeout(this.tapResetTimer);
    }
    this.tapCount += 1;
    if (this.tapCount >= 3) {
      this.tapCount = 0;
      this.tapResetTimer = -1;
      CommonDialogs.showPanicConfirm(this.getUIContext());
      return;
    }
    this.tapResetTimer = setTimeout(() => {
      this.tapResetTimer = -1;
      this.tapCount = 0;
    }, MULTI_CLICK_THRESHOLD_MS);
  }
}
