/**
 * Conversation list view (T036): persisted private conversations with
 * unread badges, newest activity first.
 *
 * 多别名归一: rows are keyed by the canonical conversation ID (mesh peer
 * ID); alias-keyed origins (Noise static key hex, later npub) resolve into
 * the same row through ChatViewModel.canonicalConversationId. Tapping a row
 * pushes the PrivateChatView destination through the system route table.
 */
import { ChatState, PrivateConversationSummary } from '../viewmodel/ChatState';
import { ChatViewModel } from '../viewmodel/ChatViewModel';

@ComponentV2
export struct ConversationListView {
  @Local chatState: ChatState = ChatViewModel.getInstance().state;
  @Param pathStack: NavPathStack = new NavPathStack();

  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text('会话')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
        Blank()
        if (this.chatState.privateConversations.length > 0) {
          Text(`${this.chatState.privateConversations.length} 个会话`)
            .fontSize(12)
            .fontColor('#888888')
        }
      }
      .width('100%')

      if (this.chatState.privateConversations.length === 0) {
        Column({ space: 8 }) {
          Text('暂无私聊会话')
            .fontSize(14)
            .fontColor('#888888')
          Text('从"网络成员"标签选择一位成员，开始端到端加密私聊')
            .fontSize(12)
            .fontColor('#666666')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .padding({ top: 48 })
      } else {
        List({ space: 0 }) {
          ForEach(this.chatState.privateConversations, (summary: PrivateConversationSummary) => {
            ListItem() {
              this.conversationRow(summary)
            }
          }, (summary: PrivateConversationSummary) => summary.conversationID)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20 })
  }

  @Builder
  private conversationRow(summary: PrivateConversationSummary) {
    Row({ space: 12 }) {
      Text(summary.displayName.length > 0 ? summary.displayName.substring(0, 1) : '?')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .textAlign(TextAlign.Center)
        .width(44)
        .height(44)
        .borderRadius(22)
        .backgroundColor('#37474F')
      Column({ space: 3 }) {
        Text(summary.displayName)
          .fontSize(16)
          .fontColor('#FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(summary.lastMessagePreview)
          .fontSize(13)
          .fontColor('#888888')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Column({ space: 6 }) {
        Text(ConversationListView.formatListTime(summary.lastMessageTimestampMs))
          .fontSize(11)
          .fontColor('#888888')
        if (summary.unreadCount > 0) {
          Text(summary.unreadCount > 99 ? '99+' : `${summary.unreadCount}`)
            .fontSize(11)
            .fontColor('#FFFFFF')
            .textAlign(TextAlign.Center)
            .minFontSize(9)
            .maxFontSize(11)
            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
            .borderRadius(10)
            .backgroundColor('#E53935')
        }
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .onClick(() => {
      this.openConversation(summary);
    })
  }

  /** Open the conversation first, then push the destination (T036). */
  private async openConversation(summary: PrivateConversationSummary): Promise<void> {
    await ChatViewModel.getInstance().openPrivateConversation(
      ChatViewModel.getInstance().canonicalConversationId(summary.conversationID));
    this.pathStack.pushPathByName('privateChat',
      ChatViewModel.getInstance().canonicalConversationId(summary.conversationID));
  }

  /** Same-day rows show HH:mm, older rows show M月d日. */
  private static formatListTime(timestampMs: number): string {
    const date: Date = new Date(timestampMs);
    const now: Date = new Date();
    if (date.getFullYear() === now.getFullYear() &&
      date.getMonth() === now.getMonth() && date.getDate() === now.getDate()) {
      return ConversationListView.pad2(date.getHours()) + ':' +
        ConversationListView.pad2(date.getMinutes());
    }
    return (date.getMonth() + 1) + '月' + date.getDate() + '日';
  }

  private static pad2(value: number): string {
    return value < 10 ? '0' + value : '' + value;
  }
}
