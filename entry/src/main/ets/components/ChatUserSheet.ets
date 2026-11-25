/**
 * Chat user sheet (US11, T057; Android ChatUserSheet parity).
 *
 * Opens over the private chat (bindContentCover) and surfaces the
 * identity-level actions of the open conversation: 收藏 toggle (with the
 * mutual-favorite status), 屏蔽 toggle and the QR identity-verification
 * entry (已验证 badge / 取消验证). All state reads go through
 * ChatViewModel, whose @Trace fingerprint mirrors drive the re-render;
 * the block list is sheet-local because only this sheet toggles it.
 */
import { ChatState } from '../viewmodel/ChatState';
import { ChatViewModel } from '../viewmodel/ChatViewModel';

@ComponentV2
export struct ChatUserSheet {
  @Param conversationId: string = '';
  @Event onClose: () => void = (): void => {};
  @Event onRequestVerification: () => void = (): void => {};
  @Local chatState: ChatState = ChatViewModel.getInstance().state;
  /** Block list mirror: only this sheet toggles it while it is open. */
  @Local blocked: boolean = false;

  @Computed
  get peerName(): string {
    return this.conversationId === '' ? '' :
      ChatViewModel.getInstance().getConversationDisplayName(this.conversationId);
  }

  @Computed
  get favorited(): boolean {
    return this.conversationId !== '' &&
      ChatViewModel.getInstance().isConversationFavorited(this.conversationId);
  }

  @Computed
  get peerFavoritedUs(): boolean {
    return this.conversationId !== '' &&
      ChatViewModel.getInstance().hasPeerFavoritedUs(this.conversationId);
  }

  @Computed
  get verified(): boolean {
    return this.conversationId !== '' &&
      ChatViewModel.getInstance().isConversationVerified(this.conversationId);
  }

  @Computed
  get fingerprintText(): string {
    if (this.conversationId === '') {
      return '';
    }
    const fingerprint: string | null =
      ChatViewModel.getInstance().getConversationFingerprint(this.conversationId);
    return fingerprint === null ? '' : fingerprint.substring(0, 16) + '…';
  }

  aboutToAppear(): void {
    this.blocked = this.conversationId !== '' &&
      ChatViewModel.getInstance().isPeerBlocked(this.conversationId);
  }

  build() {
    Column({ space: 0 }) {
      Row({ space: 10 }) {
        Text(this.peerName)
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.verified) {
          Text('已验证')
            .fontSize(11)
            .fontColor('#81C784')
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(8)
            .backgroundColor('#1B3A22')
        }
        Text('关闭')
          .fontSize(14)
          .fontColor('#64B5F6')
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 12 })

      Text('对端指纹 ' + this.fingerprintText)
        .fontSize(12)
        .fontColor('#8D949B')
        .fontFamily('monospace')
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 12 })

      this.actionRow('收藏', this.favoriteActionLabel(), this.favoriteActionColor(),
        (): void => {
          ChatViewModel.getInstance().toggleFavorite(this.conversationId);
        })
      Text(this.favoriteStatusText())
        .fontSize(12)
        .fontColor('#8D949B')
        .width('100%')
        .padding({ left: 20, right: 20, top: 4, bottom: 10 })

      this.actionRow('屏蔽', this.blockActionLabel(), this.blockActionColor(),
        (): void => {
          const viewModel: ChatViewModel = ChatViewModel.getInstance();
          if (this.blocked) {
            viewModel.unblockPeer(this.conversationId);
          } else {
            viewModel.blockPeer(this.conversationId);
          }
          this.blocked = !this.blocked;
        })
      Text(this.blockedHintText())
        .fontSize(12)
        .fontColor('#8D949B')
        .width('100%')
        .padding({ left: 20, right: 20, top: 4, bottom: 10 })

      this.actionRow('身份验证', this.verifyActionLabel(), '#1565C0', (): void => {
        this.onRequestVerification();
      })
      Text(this.verifyHintText())
        .fontSize(12)
        .fontColor('#8D949B')
        .width('100%')
        .padding({ left: 20, right: 20, top: 4, bottom: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#121212')
  }

  @Builder
  private actionRow(label: string, actionLabel: string, actionColor: string,
    onAction: () => void) {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(15)
        .fontColor('#E0E0E0')
        .layoutWeight(1)
      Button(actionLabel)
        .fontSize(14)
        .backgroundColor(actionColor)
        .onClick(() => {
          onAction();
        })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 6, bottom: 6 })
  }

  private favoriteStatusText(): string {
    if (this.favorited && this.peerFavoritedUs) {
      return '相互收藏';
    }
    if (this.favorited) {
      return '已收藏';
    }
    if (this.peerFavoritedUs) {
      return '对方收藏了你';
    }
    return '尚未收藏';
  }

  private favoriteActionLabel(): string {
    return this.favorited ? '取消收藏' : '收藏';
  }

  private favoriteActionColor(): string {
    return this.favorited ? '#B45309' : '#2E7D32';
  }

  private blockActionLabel(): string {
    return this.blocked ? '解除屏蔽' : '屏蔽';
  }

  private blockActionColor(): string {
    return this.blocked ? '#2E7D32' : '#B45309';
  }

  private blockedHintText(): string {
    return this.blocked ? '屏蔽后将忽略此对端的公开与私聊消息' : '';
  }

  private verifyActionLabel(): string {
    return this.verified ? '重新验证' : '验证身份';
  }

  private verifyHintText(): string {
    return this.verified ? '已通过扫码验证此对端的 Noise 静态密钥指纹' :
      '双方互扫二维码验证对方身份，防止中间人替换密钥';
  }
}
