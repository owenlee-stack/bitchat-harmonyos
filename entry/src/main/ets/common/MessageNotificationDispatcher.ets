/**
 * Message notification dispatcher (US8, T046): NotificationKit publishing
 * for incoming private messages and public-chat mentions.
 *
 * Android NotificationManager / MeshDelegateHandler parity:
 *  - Private messages notify unless the app is foregrounded AND that
 *    conversation is on screen; pending messages group per conversation
 *    (same notification id republished as an update), title
 *    'nickname (N messages)', text 'content (+N more)'.
 *  - Public mentions notify unless the app is foregrounded AND the public
 *    chat is on screen; one stable notification id, titles
 *    'Mentioned in Mesh Chat' / 'N mentions in Mesh Chat'.
 *  - Tapping a notification reopens the ability with want.parameters
 *    ('notify_route', 'conversation_id', 'sender_nickname'); the
 *    dispatcher stores the route (cold start + onNewWant) and ChatPage
 *    consumes it in onPageShow to jump to the conversation.
 *  - Opening a conversation clears its notifications; the panic wipe
 *    clears everything.
 *
 * Init'd with the UIAbilityContext from EntryAbility.onCreate (the
 * SettingsPreferences.init pattern) so the view model can drive it
 * without importing the ability module (no import cycle).
 */
import { common, Want, wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { notificationManager } from '@kit.NotificationKit';

const DOMAIN = 0x0000;
const TAG = 'MsgNotifyDispatcher';

/** Route target carried in notification want.parameters. */
export const NOTIFY_ROUTE_PRIVATE = 'private';
/** Route target carried in notification want.parameters. */
export const NOTIFY_ROUTE_PUBLIC = 'public';

/** Stable id for the mesh-mention notification. */
const MESH_MENTION_NOTIFICATION_ID = 4000;
/** First id handed out to per-conversation notifications. */
const FIRST_CONVERSATION_NOTIFICATION_ID = 100;
/** Pending messages kept per conversation before the list stops growing. */
const MAX_PENDING_PER_CONVERSATION = 25;

/** One not-yet-notified-read message buffered for grouping. */
class PendingMessage {
  readonly content: string;
  readonly nickname: string;

  constructor(content: string, nickname: string) {
    this.content = content;
    this.nickname = nickname;
  }
}

/** Deep-link route parsed from a notification want; consumed by ChatPage. */
export class PendingNotificationRoute {
  readonly target: string;
  readonly conversationId: string;
  readonly senderNickname: string;

  constructor(target: string, conversationId: string, senderNickname: string) {
    this.target = target;
    this.conversationId = conversationId;
    this.senderNickname = senderNickname;
  }
}

export class MessageNotificationDispatcher {
  private static instance: MessageNotificationDispatcher | null = null;
  private context: common.UIAbilityContext | null = null;
  private appInBackground: boolean = false;
  private pendingRoute: PendingNotificationRoute | null = null;
  private pendingByConversation: Map<string, PendingMessage[]> = new Map();
  private pendingMentions: PendingMessage[] = [];
  private conversationNotificationIds: Map<string, number> = new Map();
  private nextConversationNotificationId: number = FIRST_CONVERSATION_NOTIFICATION_ID;

  static getInstance(): MessageNotificationDispatcher {
    if (MessageNotificationDispatcher.instance === null) {
      MessageNotificationDispatcher.instance = new MessageNotificationDispatcher();
    }
    return MessageNotificationDispatcher.instance;
  }

  /** Capture the ability context once at process start. */
  init(context: common.UIAbilityContext): void {
    this.context = context;
  }

  /** Foreground/background switch from the ability lifecycle. */
  setAppBackground(inBackground: boolean): void {
    this.appInBackground = inBackground;
  }

  /**
   * Parse a launch want (cold start in onCreate, warm start in onNewWant)
   * and remember the notification deep-link route for ChatPage.onPageShow.
   */
  handleWant(want: Want): void {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined) {
      return;
    }
    const target: Object | undefined = params['notify_route'];
    if (typeof target !== 'string') {
      return;
    }
    const conversationId: Object | undefined = params['conversation_id'];
    const senderNickname: Object | undefined = params['sender_nickname'];
    this.pendingRoute = new PendingNotificationRoute(target,
      typeof conversationId === 'string' ? conversationId : '',
      typeof senderNickname === 'string' ? senderNickname : '');
  }

  /** Hand the pending notification route to ChatPage (one-shot). */
  takePendingRoute(): PendingNotificationRoute | null {
    const route: PendingNotificationRoute | null = this.pendingRoute;
    this.pendingRoute = null;
    return route;
  }

  /** Group + publish one incoming private message notification. */
  notifyPrivateMessage(conversationId: string, senderNickname: string,
    content: string, isViewingConversation: boolean): void {
    if (conversationId === '') {
      return;
    }
    // Suppress only when the app is foregrounded AND the chat is on screen.
    if (!this.appInBackground && isViewingConversation) {
      return;
    }
    const list: PendingMessage[] = this.pendingByConversation.get(conversationId) ?? [];
    list.push(new PendingMessage(content, senderNickname));
    if (list.length > MAX_PENDING_PER_CONVERSATION) {
      list.splice(0, list.length - MAX_PENDING_PER_CONVERSATION);
    }
    this.pendingByConversation.set(conversationId, list);
    this.publishConversationNotification(conversationId);
  }

  /** Group + publish one public-chat mention notification. */
  notifyMeshMention(senderNickname: string, content: string,
    isViewingPublicChat: boolean): void {
    if (!this.appInBackground && isViewingPublicChat) {
      return;
    }
    this.pendingMentions.push(new PendingMessage(content, senderNickname));
    if (this.pendingMentions.length > MAX_PENDING_PER_CONVERSATION) {
      this.pendingMentions.splice(0, this.pendingMentions.length - MAX_PENDING_PER_CONVERSATION);
    }
    this.publishMentionNotification();
  }

  /** Opening a conversation retires its pending group and notification. */
  clearPrivateNotifications(conversationId: string): void {
    if (this.pendingByConversation.delete(conversationId)) {
      const id: number | undefined = this.conversationNotificationIds.get(conversationId);
      if (id !== undefined) {
        this.cancelById(id);
      }
    }
  }

  /** Viewing the public chat retires the mention notification. */
  clearMentionNotifications(): void {
    if (this.pendingMentions.length === 0) {
      return;
    }
    this.pendingMentions = [];
    this.cancelById(MESH_MENTION_NOTIFICATION_ID);
  }

  /** Panic-wipe stage: retire every message notification. */
  clearAll(): void {
    this.pendingByConversation.clear();
    this.pendingMentions = [];
    const ids: number[] = [];
    this.conversationNotificationIds.forEach((id: number): void => {
      ids.push(id);
    });
    this.conversationNotificationIds.clear();
    for (let i: number = 0; i < ids.length; i++) {
      this.cancelById(ids[i]);
    }
    this.cancelById(MESH_MENTION_NOTIFICATION_ID);
  }

  private conversationNotificationIdFor(conversationId: string): number {
    const existing: number | undefined = this.conversationNotificationIds.get(conversationId);
    if (existing !== undefined) {
      return existing;
    }
    const id: number = this.nextConversationNotificationId;
    this.nextConversationNotificationId++;
    this.conversationNotificationIds.set(conversationId, id);
    return id;
  }

  private publishConversationNotification(conversationId: string): void {
    const list: PendingMessage[] | undefined = this.pendingByConversation.get(conversationId);
    if (list === undefined || list.length === 0) {
      return;
    }
    const count: number = list.length;
    const latest: PendingMessage = list[count - 1];
    const title: string = count === 1
      ? latest.nickname
      : `${latest.nickname} (${count} messages)`;
    const text: string = count === 1
      ? latest.content
      : `${latest.content} (+${count - 1} more)`;
    const want: Want = this.routeWant(NOTIFY_ROUTE_PRIVATE, conversationId, latest.nickname);
    this.publishNotification(this.conversationNotificationIdFor(conversationId),
      title, text, want);
  }

  private publishMentionNotification(): void {
    const count: number = this.pendingMentions.length;
    if (count === 0) {
      return;
    }
    const latest: PendingMessage = this.pendingMentions[count - 1];
    // Android notification_mesh_mention_title_singular/_plural parity.
    const title: string = count === 1
      ? 'Mentioned in Mesh Chat'
      : `${count} mentions in Mesh Chat`;
    const want: Want = this.routeWant(NOTIFY_ROUTE_PUBLIC, '', '');
    this.publishNotification(MESH_MENTION_NOTIFICATION_ID, title, latest.content, want);
  }

  private routeWant(target: string, conversationId: string,
    senderNickname: string): Want {
    const parameters: Record<string, Object> = {
      'notify_route': target,
      'conversation_id': conversationId,
      'sender_nickname': senderNickname
    };
    const context: common.UIAbilityContext | null = this.context;
    return {
      bundleName: context !== null ? context.abilityInfo.bundleName : '',
      abilityName: 'EntryAbility',
      parameters: parameters
    };
  }

  private publishNotification(id: number, title: string, text: string,
    want: Want): void {
    if (this.context === null) {
      return;
    }
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [want],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    wantAgent.getWantAgent(wantAgentInfo).then((agent: WantAgent): void => {
      const request: notificationManager.NotificationRequest = {
        id: id,
        notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: text,
            additionalText: 'The sidegroup chat'
          }
        },
        wantAgent: agent
      };
      notificationManager.publish(request)
        .catch((error: BusinessError): void => {
          hilog.error(DOMAIN, TAG, 'publish notification failed: %{public}s',
            JSON.stringify(error));
        });
    }).catch((error: BusinessError): void => {
      hilog.error(DOMAIN, TAG, 'getWantAgent failed: %{public}s', JSON.stringify(error));
    });
  }

  private cancelById(id: number): void {
    notificationManager.cancel(id)
      .catch((error: BusinessError): void => {
        hilog.error(DOMAIN, TAG, 'cancel notification failed: %{public}s',
          JSON.stringify(error));
      });
  }
}
