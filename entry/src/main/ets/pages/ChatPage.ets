/**
 * Main page (US3, T030; private chat T036; notification deep link T046):
 * Navigation host for the chat surfaces.
 *
 * The Navigation stack anchors pushed sub-screens: PrivateChatView rides the
 * system route table (router_map, name 'privateChat') so conversations push
 * with their conversation-ID param; the home content is a three-tab layout:
 * private conversations (ConversationListView), the public broadcast
 * timeline (PublicChatView) and the mesh member list (PeerNetworkView, the
 * entry point for new private chats). Starting here boots the mesh
 * composition root (ChatViewModel.start) - transport, announce scheduler,
 * packet processor, relay, topology, gossip sync, Noise sessions and the
 * private-message router.
 *
 * T046: tapping a message notification routes back here. The dispatcher
 * stores the route (cold start / onNewWant) and onPageShow consumes it -
 * a private-message notification opens that conversation, a mention
 * notification switches to the public-chat tab.
 *
 * T049: ChatPage hosts the channel password prompt. Joining a
 * password-protected channel arms ChatState.showPasswordPrompt; the
 * monitor opens a ComponentContent dialog (promptAction.openCustomDialog)
 * with the PasswordPromptDialogBuilder content, and closing the dialog
 * (Join / Cancel / outside tap) disarms the prompt state again.
 */
import { ComponentContent, UIContext } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatState } from '../viewmodel/ChatState';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { ConversationListView } from '../views/ConversationListView';
import { PublicChatView } from '../views/PublicChatView';
import { PeerNetworkView } from '../views/PeerNetworkView';
import { PasswordPromptDialogBuilder, PasswordPromptDialogParams } from '../components/CommonDialogs';
import { MessageNotificationDispatcher, PendingNotificationRoute,
  NOTIFY_ROUTE_PRIVATE, NOTIFY_ROUTE_PUBLIC } from '../common/MessageNotificationDispatcher';
import { GeohashPickerResult } from '../service/globe/GeohashPickerResult';

const DOMAIN = 0x0000;
const TAG = 'ChatPage';

@Entry
@ComponentV2
struct ChatPage {
  pathStack: NavPathStack = new NavPathStack();
  @Local chatState: ChatState = ChatViewModel.getInstance().state;
  /** Visible home tab; notification deep links switch it (T046). */
  @Local activeTabIndex: number = 0;
  /** Live password prompt dialog; null while closed (T049). */
  private passwordDialog: ComponentContent<PasswordPromptDialogParams> | null = null;

  aboutToAppear(): void {
    ChatViewModel.getInstance().start();
  }

  onPageShow(): void {
    this.consumePendingNotificationRoute();
    this.consumeGeohashPickerResult();
  }

  /**
   * Globe picker handoff (US13, T068): the picker parks the selected
   * geohash in GeohashPickerResult before routing back; consuming it
   * marks the channel globe-joined (teleport tag) and joins it, which
   * pushes the location destination through the state monitor.
   */
  private consumeGeohashPickerResult(): void {
    const joined: string = GeohashPickerResult.takeJoinedGeohash();
    if (joined === '') {
      return;
    }
    const viewModel: ChatViewModel = ChatViewModel.getInstance();
    viewModel.markGeohashTeleported(joined);
    viewModel.joinGeohashChannel(joined);
  }

  /**
   * Channel password prompt host (T049): the armed flag opens the dialog,
   * the disarmed flag (join accepted, panic wipe) closes it.
   */
  @Monitor('chatState.showPasswordPrompt')
  onPasswordPromptChanged(): void {
    if (this.chatState.showPasswordPrompt) {
      this.openPasswordDialog();
    } else {
      this.closePasswordDialog();
    }
  }

  private openPasswordDialog(): void {
    if (this.passwordDialog !== null) {
      return;
    }
    const uiContext: UIContext = this.getUIContext();
    const params: PasswordPromptDialogParams = new PasswordPromptDialogParams(
      this.chatState.passwordPromptChannel,
      (password: string): void => {
        // Android parity: the dialog closes regardless of the join result;
        // a wrong password only leaves the public-timeline notice.
        ChatViewModel.getInstance()
          .joinChannel(this.chatState.passwordPromptChannel, password);
        this.closePasswordDialog();
      },
      (): void => {
        ChatViewModel.getInstance().dismissPasswordPrompt();
        this.closePasswordDialog();
      });
    const content: ComponentContent<PasswordPromptDialogParams> =
      new ComponentContent<PasswordPromptDialogParams>(
        uiContext, wrapBuilder(PasswordPromptDialogBuilder), params);
    this.passwordDialog = content;
    uiContext.getPromptAction().openCustomDialog(content, {
      autoCancel: true,
      alignment: DialogAlignment.Center,
      onDidDisappear: (): void => {
        this.passwordDialog = null;
        ChatViewModel.getInstance().dismissPasswordPrompt();
      }
    })
      .catch((error: BusinessError): void => {
        this.passwordDialog = null;
        hilog.error(DOMAIN, TAG, 'open password dialog failed: %{public}s', error.message);
      });
  }

  private closePasswordDialog(): void {
    const dialog: ComponentContent<PasswordPromptDialogParams> | null = this.passwordDialog;
    if (dialog === null) {
      return;
    }
    this.passwordDialog = null;
    this.getUIContext().getPromptAction().closeCustomDialog(dialog)
      .catch((error: BusinessError): void => {
        hilog.error(DOMAIN, TAG, 'close password dialog failed: %{public}s', error.message);
      });
  }

  /** Notification deep link (T046): jump to the routed conversation/tab. */
  private consumePendingNotificationRoute(): void {
    const route: PendingNotificationRoute | null =
      MessageNotificationDispatcher.getInstance().takePendingRoute();
    if (route === null) {
      return;
    }
    if (route.target === NOTIFY_ROUTE_PRIVATE && route.conversationId !== '') {
      ChatViewModel.getInstance()
        .startPrivateChatWithPeer(route.conversationId, route.senderNickname)
        .then((): void => {
          this.pathStack.pushPathByName('privateChat', route.conversationId);
        });
    } else if (route.target === NOTIFY_ROUTE_PUBLIC) {
      this.activeTabIndex = 1;
    }
  }

  build() {
    Navigation(this.pathStack) {
      Tabs({ barPosition: BarPosition.End, index: this.activeTabIndex!! }) {
        TabContent() {
          ConversationListView({ pathStack: this.pathStack })
        }
        .tabBar('浼氳瘽')
        TabContent() {
          PublicChatView({ chatState: this.chatState, pathStack: this.pathStack })
        }
        .tabBar('鍏叡鑱婂ぉ')
        TabContent() {
          PeerNetworkView({ pathStack: this.pathStack })
        }
        .tabBar('缃戠粶鎴愬憳')
      }
      .scrollable(true)
      .barWidth('100%')
      .barHeight(56)
      .vertical(false)
      .onChange((index: number): void => {
        this.activeTabIndex = index;
        ChatViewModel.getInstance().setPublicChatActive(index === 1);
      })
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .backgroundColor('#111111')
  }
}
