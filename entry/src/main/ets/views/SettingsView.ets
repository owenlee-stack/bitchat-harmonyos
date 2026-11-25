/**
 * Settings destination (T042): theme + chat UI mode switches, plus the
 * SOCKS proxy parameterization section (T072, US15).
 *
 * Pushed through the system route table (router_map, name 'settings') from
 * the public chat header. Sections mirror the Android settings surface:
 *  - 外观主题: system / light / dark, applied instantly through
 *    SettingsPreferences (ApplicationContext.setColorMode dark/light resource
 *    switch) and persisted via PreferenceStore,
 *  - 聊天界面风格: bubbles (classic messenger) vs terminal (Matrix-style
 *    flat monospace stream), applied instantly to the shared ChatState so
 *    both chat surfaces re-render, and persisted the same way,
 *  - 网络代理: OFF (direct Nostr relays) vs a custom SOCKS proxy
 *    (host + port, Android default port 9060). A custom proxy is applied
 *    to NostrRelayManager and suppresses every direct relay connection
 *    (开启后禁止直连, fail-closed), reserving the Arti/Tor integration
 *    point assessed in spec/bitchat-harmonyos/notes-arti-port.md.
 */
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatState } from '../viewmodel/ChatState';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { SettingsPreferences, ThemePreference } from '../data/SettingsPreferences';
import { NostrRelayManager } from '../service/nostr/NostrRelayManager';
import { SocksProxyMode, socksProxyHostValid, socksProxyPortOrDefault,
  socksProxyPortValid, SOCKS_PROXY_DEFAULT_PORT } from '../service/nostr/SocksProxyPolicy';

const DOMAIN = 0x0000;
const TAG = 'SettingsView';

@Builder
export function SettingsViewBuilder() {
  SettingsView()
}

@ComponentV2
export struct SettingsView {
  @Local chatState: ChatState = ChatViewModel.getInstance().state;
  @Local theme: ThemePreference = SettingsPreferences.getInstance().getThemePreference();
  @Local socksMode: SocksProxyMode = SettingsPreferences.getInstance().getSocksProxyMode();
  @Local socksHost: string = SettingsPreferences.getInstance().getSocksProxyHost();
  @Local socksPortText: string = '';
  @Local socksHint: string = '';
  private pathStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    this.socksPortText = String(SettingsPreferences.getInstance().getSocksProxyPort());
  }

  build() {
    NavDestination() {
      Column({ space: 24 }) {
        this.themeSection()
        this.uiModeSection()
        this.proxySection()
        this.aboutSection()
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 20, right: 20, top: 8 })
    }
    .title('设置')
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }

  @Builder
  private themeSection() {
    Column({ space: 2 }) {
      Text('外观主题')
        .fontSize(13)
        .fontColor('#888888')
      this.themeOption(ThemePreference.SYSTEM, '跟随系统')
      this.themeOption(ThemePreference.LIGHT, '浅色')
      this.themeOption(ThemePreference.DARK, '深色')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private themeOption(theme: ThemePreference, label: string) {
    Row() {
      Text(label)
        .fontSize(16)
        .fontColor('#FFFFFF')
      Blank()
      if (this.theme === theme) {
        Text('已选')
          .fontSize(12)
          .fontColor('#4CAF50')
      }
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .onClick(() => {
      this.selectTheme(theme);
    })
  }

  @Builder
  private uiModeSection() {
    Column({ space: 2 }) {
      Text('聊天界面风格')
        .fontSize(13)
        .fontColor('#888888')
      this.uiModeOption(true, '气泡模式', '经典即时通讯布局，自己的消息靠右，他人靠左')
      this.uiModeOption(false, '终端模式', 'Matrix 风格：扁平左对齐等宽字体流')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private uiModeOption(bubbles: boolean, label: string, description: string) {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text(label)
          .fontSize(16)
          .fontColor('#FFFFFF')
        Text(description)
          .fontSize(12)
          .fontColor('#888888')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (this.chatState.bubblesMode === bubbles) {
        Text('已选')
          .fontSize(12)
          .fontColor('#4CAF50')
      }
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .onClick(() => {
      this.selectUiMode(bubbles);
    })
  }

  /** SOCKS proxy parameterization (T072, US15). */
  @Builder
  private proxySection() {
    Column({ space: 2 }) {
      Text('网络代理')
        .fontSize(13)
        .fontColor('#888888')
      this.proxyModeOption(SocksProxyMode.OFF, '关闭（直连）',
        'Nostr 中继直连收发')
      this.proxyModeOption(SocksProxyMode.CUSTOM, '自定义 SOCKS 代理',
        '预留 Arti/Tor 接入，默认端口 9060；开启后禁止直连')
      if (this.socksMode === SocksProxyMode.CUSTOM) {
        Row({ space: 10 }) {
          Column({ space: 4 }) {
            Text('主机')
              .fontSize(11)
              .fontColor('#777777')
            TextInput({ text: this.socksHost, placeholder: '127.0.0.1' })
              .fontSize(14)
              .fontColor('#FFFFFF')
              .placeholderColor('#777777')
              .backgroundColor('#1D1D1D')
              .borderRadius(10)
              .border({ width: 1, color: '#3A3A3A' })
              .layoutWeight(1)
              .onChange((value: string) => {
                this.onSocksHostChange(value);
              })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Column({ space: 4 }) {
            Text('端口')
              .fontSize(11)
              .fontColor('#777777')
            TextInput({ text: this.socksPortText, placeholder: '9060' })
              .fontSize(14)
              .fontColor('#FFFFFF')
              .placeholderColor('#777777')
              .backgroundColor('#1D1D1D')
              .borderRadius(10)
              .border({ width: 1, color: '#3A3A3A' })
              .width(96)
              .type(InputType.Number)
              .onChange((value: string) => {
                this.onSocksPortChange(value);
              })
          }
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ top: 6 })
        Text('开启后 Nostr 中继直连被禁用，流量仅经代理收发')
          .fontSize(11)
          .fontColor('#777777')
        if (this.socksHint !== '') {
          Text(this.socksHint)
            .fontSize(11)
            .fontColor('#E57373')
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private proxyModeOption(mode: SocksProxyMode, label: string, description: string) {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text(label)
          .fontSize(16)
          .fontColor('#FFFFFF')
        Text(description)
          .fontSize(12)
          .fontColor('#888888')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (this.socksMode === mode) {
        Text('已选')
          .fontSize(12)
          .fontColor('#4CAF50')
      }
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .onClick(() => {
      this.selectSocksMode(mode);
    })
  }

  /** About / panic-trigger entry (T044). */
  @Builder
  private aboutSection() {
    Column({ space: 2 }) {
      Text('关于')
        .fontSize(13)
        .fontColor('#888888')
      Row() {
        Text('关于 bitchat')
          .fontSize(16)
          .fontColor('#FFFFFF')
        Blank()
        Text('›')
          .fontSize(18)
          .fontColor('#777777')
      }
      .width('100%')
      .padding({ top: 12, bottom: 12 })
      .onClick(() => {
        this.pathStack.pushPathByName('about', '');
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private selectTheme(theme: ThemePreference): void {
    if (this.theme === theme) {
      return;
    }
    this.theme = theme;
    SettingsPreferences.getInstance().setThemePreference(theme)
      .catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'Persist theme failed: %{public}s', JSON.stringify(error));
      });
  }

  private selectUiMode(bubbles: boolean): void {
    if (this.chatState.bubblesMode === bubbles) {
      return;
    }
    // Instant: the shared @Trace state re-renders both chat surfaces.
    ChatViewModel.getInstance().setBubblesMode(bubbles);
    SettingsPreferences.getInstance().setChatUiMode(bubbles)
      .catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'Persist chat UI mode failed: %{public}s', JSON.stringify(error));
      });
  }

  /** T072: OFF restores direct relays; CUSTOM requires a usable host. */
  private selectSocksMode(mode: SocksProxyMode): void {
    if (this.socksMode === mode) {
      return;
    }
    if (mode === SocksProxyMode.CUSTOM) {
      if (!socksProxyHostValid(this.socksHost)) {
        this.socksHint = '请先填写代理主机（如 127.0.0.1）';
        return;
      }
      this.socksPortText = String(socksProxyPortOrDefault(this.parseSocksPort()));
      this.socksHint = '';
    } else {
      this.socksHint = '';
    }
    this.socksMode = mode;
    this.persistAndApplySocksProxy();
  }

  private onSocksHostChange(value: string): void {
    this.socksHost = value;
    if (this.socksMode !== SocksProxyMode.CUSTOM) {
      return;
    }
    if (!socksProxyHostValid(value)) {
      // Fail-closed: keep the last applied suppression in place.
      this.socksHint = '代理主机不能为空；直连保持禁用';
      return;
    }
    this.socksHint = '';
    this.persistAndApplySocksProxy();
  }

  private onSocksPortChange(value: string): void {
    this.socksPortText = value;
    if (this.socksMode !== SocksProxyMode.CUSTOM || !socksProxyHostValid(this.socksHost)) {
      return;
    }
    if (!socksProxyPortValid(this.parseSocksPort())) {
      this.socksHint = '端口无效，将回退默认 9060';
    } else {
      this.socksHint = '';
    }
    this.persistAndApplySocksProxy();
  }

  /** Persist the pick and apply it to the relay transport instantly. */
  private persistAndApplySocksProxy(): void {
    const port: number = socksProxyPortOrDefault(this.parseSocksPort());
    SettingsPreferences.getInstance()
      .setSocksProxy(this.socksMode, this.socksHost, port)
      .catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'Persist socks proxy failed: %{public}s', JSON.stringify(error));
      });
    NostrRelayManager.shared.applySocksProxy(this.socksMode, this.socksHost, port);
  }

  private parseSocksPort(): number {
    const parsed: number = Number.parseInt(this.socksPortText);
    if (Number.isNaN(parsed)) {
      return SOCKS_PROXY_DEFAULT_PORT;
    }
    return parsed;
  }
}
