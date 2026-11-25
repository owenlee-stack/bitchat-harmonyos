/**
 * First-launch onboarding flow (US1).
 *
 * Step 1 explains the three permissions the app relies on (Bluetooth mesh,
 * location for nearby features, notifications for message alerts) and requests
 * the runtime-granted ones; Bluetooth itself is a normal-grade permission
 * granted at install time on HarmonyOS, so it only needs the explanation.
 * Step 2 (restricted-mode notice) appears when the user denied location and
 * allows continuing with limited functionality (spec acceptance 2).
 * Step 3 collects the nickname (<= UiConstants.MAX_NICKNAME_LENGTH chars),
 * seals the generated identity and flips the onboarding_completed flag before
 * routing to the main page.
 */
import { abilityAccessCtrl, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { UiConstants } from '../common/ProtocolConstants';
import { IdentityManager } from '../service/identity/IdentityManager';
import { PreferenceStore } from '../data/PreferenceStore';

const DOMAIN = 0x0000;
const PAGE_TAG = 'OnboardingPage';

const ONBOARDING_COMPLETED_KEY = 'onboarding_completed';
const LOCATION_PERMISSIONS: Permissions[] = [
  'ohos.permission.LOCATION',
  'ohos.permission.APPROXIMATELY_LOCATION'
];

const STEP_EXPLAIN: number = 0;
const STEP_RESTRICTED: number = 1;
const STEP_NICKNAME: number = 2;

@Entry
@Component
struct OnboardingPage {
  @State private step: number = STEP_EXPLAIN;
  @State private nicknameInput: string = '';
  @State private busy: boolean = false;
  @State private errorMessage: string = '';
  private locationGranted: boolean = false;

  build() {
    Column({ space: 20 }) {
      Text('bitchat')
        .fontSize(32)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 80 })
      if (this.step === STEP_EXPLAIN) {
        this.explainBody()
      } else if (this.step === STEP_RESTRICTED) {
        this.restrictedBody()
      } else {
        this.nicknameBody()
      }
      Blank()
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24 })
    .backgroundColor('#111111')
  }

  @Builder
  private explainBody() {
    Column({ space: 16 }) {
      Text('开始之前')
        .fontSize(22)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
      Column({ space: 12 }) {
        Text('• 蓝牙：构建附近 mesh 网络（安装即已授权）')
        Text('• 位置：附近功能与地理频道（需要授权）')
        Text('• 通知：新消息提醒（可选择跳过）')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      Button(this.busy ? '正在请求授权…' : '授权并继续')
        .enabled(!this.busy)
        .width('100%')
        .margin({ top: 24 })
        .onClick(() => {
          this.requestPermissions();
        })
    }
    .width('100%')
  }

  @Builder
  private restrictedBody() {
    Column({ space: 16 }) {
      Text('受限模式')
        .fontSize(22)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFB300')
      Text('未授予位置权限，部分附近功能不可用。你可以在系统设置中重新授权后恢复完整功能。')
        .fontSize(16)
        .fontColor('#CCCCCC')
        .textAlign(TextAlign.Start)
        .width('100%')
      Button('重新授权')
        .enabled(!this.busy)
        .width('100%')
        .margin({ top: 16 })
        .onClick(() => {
          this.requestPermissions();
        })
      Button('继续使用')
        .enabled(!this.busy)
        .width('100%')
        .backgroundColor('#333333')
        .onClick(() => {
          this.step = STEP_NICKNAME;
        })
    }
    .width('100%')
  }

  @Builder
  private nicknameBody() {
    Column({ space: 16 }) {
      Text('选择昵称')
        .fontSize(22)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
      Text('无需注册账号，昵称将随公告广播给附近设备。')
        .fontSize(14)
        .fontColor('#999999')
        .width('100%')
        .textAlign(TextAlign.Start)
      TextInput({ placeholder: '昵称（最多 15 字符）', text: this.nicknameInput })
        .maxLength(UiConstants.MAX_NICKNAME_LENGTH)
        .onChange((value: string) => {
          this.nicknameInput = value;
        })
      Text(`${this.nicknameInput.length}/${UiConstants.MAX_NICKNAME_LENGTH}`)
        .fontSize(12)
        .fontColor('#888888')
        .width('100%')
        .textAlign(TextAlign.End)
      if (this.errorMessage !== '') {
        Text(this.errorMessage)
          .fontSize(14)
          .fontColor('#E53935')
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      Button(this.busy ? '正在初始化…' : '开始使用')
        .enabled(!this.busy && this.nicknameInput.trim().length > 0)
        .width('100%')
        .margin({ top: 8 })
        .onClick(() => {
          this.completeOnboarding();
        })
    }
    .width('100%')
  }

  private async requestPermissions(): Promise<void> {
    this.busy = true;
    this.locationGranted = false;
    const context = this.getUIContext().getHostContext();
    if (context !== undefined) {
      try {
        const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
        const result: PermissionRequestResult =
          await atManager.requestPermissionsFromUser(context, LOCATION_PERMISSIONS);
        this.locationGranted = this.allGranted(result.authResults);
      } catch (e) {
        hilog.warn(DOMAIN, PAGE_TAG, 'location permission request failed: %{public}s',
          JSON.stringify(e));
      }
    }
    try {
      let notificationEnabled: boolean = await notificationManager.isNotificationEnabled();
      if (!notificationEnabled) {
        await notificationManager.requestEnableNotification();
        notificationEnabled = await notificationManager.isNotificationEnabled();
      }
    } catch (e) {
      hilog.warn(DOMAIN, PAGE_TAG, 'notification authorization failed: %{public}s',
        JSON.stringify(e));
    }
    this.busy = false;
    this.step = this.locationGranted ? STEP_NICKNAME : STEP_RESTRICTED;
  }

  private async completeOnboarding(): Promise<void> {
    const nickname: string = this.nicknameInput.trim();
    if (nickname.length === 0 || nickname.length > UiConstants.MAX_NICKNAME_LENGTH) {
      this.errorMessage = '昵称不能为空且不超过 15 字符';
      return;
    }
    this.busy = true;
    this.errorMessage = '';
    try {
      await IdentityManager.getInstance().initialize();
      const accepted: boolean = await IdentityManager.getInstance().setNickname(nickname);
      if (!accepted) {
        this.errorMessage = '昵称无效，请重新输入';
        this.busy = false;
        return;
      }
      await PreferenceStore.getInstance().setBoolean(ONBOARDING_COMPLETED_KEY, true);
      router.replaceUrl({ url: 'pages/ChatPage' });
    } catch (e) {
      this.errorMessage = '初始化失败，请重试';
      this.busy = false;
      hilog.error(DOMAIN, PAGE_TAG, 'onboarding failed: %{public}s', JSON.stringify(e));
    }
  }

  private allGranted(authResults: number[]): boolean {
    if (authResults.length === 0) {
      return false;
    }
    for (let i = 0; i < authResults.length; i++) {
      if (authResults[i] !== 0) {
        return false;
      }
    }
    return true;
  }
}
