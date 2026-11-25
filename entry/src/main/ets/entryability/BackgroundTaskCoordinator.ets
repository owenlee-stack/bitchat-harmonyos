/**
 * Background keep-alive coordinator (T045, US8): continuous task +
 * persistent mesh notification.
 *
 * Applies for the BLUETOOTH_INTERACTION continuous task
 * (backgroundTaskManager.startBackgroundRunning, permission
 * ohos.permission.KEEP_BACKGROUND_RUNNING, module.json5 backgroundModes)
 * when the mesh composition root starts, and publishes a persistent
 * SERVICE_INFORMATION notification showing the current connected-peer
 * count (Android MeshForegroundService parity: 'Mesh running — N peers',
 * tap reopens the app via wantAgent). Count changes re-publish under the
 * same notification id (update); tearing the mesh down stops the task
 * and cancels the notification.
 *
 * Init'd with the UIAbilityContext from EntryAbility.onCreate (the
 * SettingsPreferences.init pattern) so ChatViewModel can drive it
 * without importing the ability module (no import cycle).
 */
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { notificationManager } from '@kit.NotificationKit';

const DOMAIN = 0x0000;
const TAG = 'BgTaskCoordinator';

/** Android MeshForegroundService.NOTIFICATION_ID parity. */
const MESH_NOTIFICATION_ID = 10001;
/** Notification title: app name (Android app_name parity). */
const NOTIFICATION_TITLE = 'bitchat';
/** Android mesh_service_notification_content parity ('Mesh running — %d peers'). */
function meshNotificationText(connectedCount: number): string {
  return `Mesh running — ${connectedCount} peers`;
}

export class BackgroundTaskCoordinator {
  private static instance: BackgroundTaskCoordinator | null = null;
  private context: common.UIAbilityContext | null = null;
  private running: boolean = false;
  private starting: boolean = false;
  private agent: WantAgent | null = null;
  private lastNotifiedCount: number = -1;

  static getInstance(): BackgroundTaskCoordinator {
    if (BackgroundTaskCoordinator.instance === null) {
      BackgroundTaskCoordinator.instance = new BackgroundTaskCoordinator();
    }
    return BackgroundTaskCoordinator.instance;
  }

  /** Capture the ability context once at process start. */
  init(context: common.UIAbilityContext): void {
    this.context = context;
  }

  /**
   * Apply for the BLUETOOTH_INTERACTION continuous task and publish the
   * persistent count notification. Idempotent: a second call while the
   * task runs only refreshes the notification.
   */
  start(connectedCount: number): void {
    const context: common.UIAbilityContext | null = this.context;
    if (context === null) {
      return;
    }
    if (this.running || this.starting) {
      this.updateNotification(connectedCount);
      return;
    }
    this.starting = true;
    // Tap target for the continuous-task notification and the persistent
    // count notification: reopen this ability.
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: context.abilityInfo.bundleName,
          abilityName: 'EntryAbility'
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    wantAgent.getWantAgent(wantAgentInfo).then((agent: WantAgent): Promise<void> => {
      this.agent = agent;
      return backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.BLUETOOTH_INTERACTION, agent);
    }).then((): void => {
      this.starting = false;
      this.running = true;
      this.publishNotification(connectedCount);
    }).catch((error: BusinessError): void => {
      this.starting = false;
      hilog.error(DOMAIN, TAG, 'startBackgroundRunning failed: %{public}s', JSON.stringify(error));
    });
  }

  /** Refresh the persistent notification when the count changes. */
  updateNotification(connectedCount: number): void {
    if (!this.running || connectedCount === this.lastNotifiedCount) {
      return;
    }
    this.publishNotification(connectedCount);
  }

  /** Release the continuous task and cancel the count notification. */
  stop(): void {
    if (!this.running) {
      return;
    }
    this.running = false;
    this.lastNotifiedCount = -1;
    this.cancelNotification();
    const context: common.UIAbilityContext | null = this.context;
    if (context === null) {
      return;
    }
    backgroundTaskManager.stopBackgroundRunning(context)
      .catch((error: BusinessError): void => {
        hilog.error(DOMAIN, TAG, 'stopBackgroundRunning failed: %{public}s', JSON.stringify(error));
      });
  }

  private publishNotification(connectedCount: number): void {
    this.lastNotifiedCount = connectedCount;
    const request: notificationManager.NotificationRequest = {
      id: MESH_NOTIFICATION_ID,
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: NOTIFICATION_TITLE,
          text: meshNotificationText(connectedCount),
          additionalText: 'The sidegroup chat'
        }
      }
    };
    const agent: WantAgent | null = this.agent;
    if (agent !== null) {
      request.wantAgent = agent;
    }
    notificationManager.publish(request)
      .catch((error: BusinessError): void => {
        // Notification switch off etc.: keep-alive still runs; the
        // continuous task posts its own system notification.
        hilog.error(DOMAIN, TAG, 'publish mesh notification failed: %{public}s', JSON.stringify(error));
      });
  }

  private cancelNotification(): void {
    notificationManager.cancel(MESH_NOTIFICATION_ID)
      .catch((error: BusinessError): void => {
        hilog.error(DOMAIN, TAG, 'cancel mesh notification failed: %{public}s', JSON.stringify(error));
      });
  }
}
