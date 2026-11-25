/**
 * Shared composer input bar (US6, T040) with the command / @mention
 * autocomplete suggestion lists.
 *
 * The component is presentational: it renders the TextInput plus the two
 * suggestion popups backed by the ChatViewModel suggestion state (T039
 * ChatState fields) and reports a send through onSendText. The composer
 * text is two-way bound to the parent (@Param + @Event via the `!!`
 * sugar), so the parent keeps full control of clearing the field after
 * an accepted send; because a programmatic clear does not run onChange,
 * the parent dismisses the popups via ChatViewModel.clearSuggestionPopups
 * (parity with the Android ChatScreen send path).
 */
import { ChatState } from '../viewmodel/ChatState';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { CommandSuggestion } from '../viewmodel/CommandSuggestion';

/** Command popup cap; longer lists scroll inside the List. */
const COMMAND_POPUP_MAX_HEIGHT = 220;
/** Mention popup cap; longer lists scroll inside the List. */
const MENTION_POPUP_MAX_HEIGHT = 180;

@ComponentV2
export struct MessageInput {
  /** Composer text (two-way bound from the parent via `!!`). */
  @Param inputText: string = '';
  @Event $inputText: (val: string) => void = (val: string) => {};
  @Param placeholder: string = '';
  @Param maxInputLength: number = 500;
  /** True while the outgoing message is being built/sent. */
  @Param sending: boolean = false;
  @Param sendButtonColor: string = '#2E7D32';
  /** Parent send handler; '/' command routing stays with the parent. */
  @Event onSendText: () => void = (): void => {};
  @Local chatState: ChatState = ChatViewModel.getInstance().state;

  build() {
    Column() {
      if (this.chatState.showCommandSuggestions) {
        this.commandSuggestionList()
      }
      if (this.chatState.showMentionSuggestions) {
        this.mentionSuggestionList()
      }
      Row({ space: 8 }) {
        TextInput({ placeholder: this.placeholder, text: this.inputText })
          .layoutWeight(1)
          .maxLength(this.maxInputLength)
          .backgroundColor('#222222')
          .fontColor('#FFFFFF')
          .placeholderColor('#666666')
          .onChange((value: string) => {
            this.$inputText(value);
            ChatViewModel.getInstance().updateCommandSuggestions(value);
            ChatViewModel.getInstance().updateMentionSuggestions(value);
          })
        Button(this.sending ? '发送中' : '发送')
          .enabled(!this.sending && this.inputText.trim().length > 0)
          .backgroundColor(this.sendButtonColor)
          .onClick(() => {
            this.onSendText();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 12 })
  }

  @Builder
  private commandSuggestionList() {
    List() {
      ForEach(this.chatState.commandSuggestions, (suggestion: CommandSuggestion) => {
        ListItem() {
          Row({ space: 8 }) {
            Text(MessageInput.commandLabelOf(suggestion))
              .fontSize(13)
              .fontColor('#81C784')
            Text(suggestion.description)
              .fontSize(11)
              .fontColor('#999999')
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .onClick(() => {
            this.applyCommandSuggestion(suggestion);
          })
        }
      }, (suggestion: CommandSuggestion) => suggestion.command)
    }
    .width('100%')
    .constraintSize({ maxHeight: COMMAND_POPUP_MAX_HEIGHT })
    .scrollBar(BarState.Off)
    .backgroundColor('#1A1A1A')
    .borderRadius(8)
    .padding({ top: 4, bottom: 4 })
    .margin({ bottom: 6 })
  }

  @Builder
  private mentionSuggestionList() {
    List() {
      ForEach(this.chatState.mentionSuggestions, (nickname: string) => {
        ListItem() {
          Row({ space: 6 }) {
            Text('@')
              .fontSize(13)
              .fontColor('#64B5F6')
            Text(nickname)
              .fontSize(13)
              .fontColor('#FFFFFF')
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .onClick(() => {
            this.applyMentionSuggestion(nickname);
          })
        }
      }, (nickname: string) => nickname)
    }
    .width('100%')
    .constraintSize({ maxHeight: MENTION_POPUP_MAX_HEIGHT })
    .scrollBar(BarState.Off)
    .backgroundColor('#1A1A1A')
    .borderRadius(8)
    .padding({ top: 4, bottom: 4 })
    .margin({ bottom: 6 })
  }

  private applyCommandSuggestion(suggestion: CommandSuggestion): void {
    const replaced: string = ChatViewModel.getInstance().selectCommandSuggestion(suggestion);
    this.$inputText(replaced);
    ChatViewModel.getInstance().clearSuggestionPopups();
  }

  private applyMentionSuggestion(nickname: string): void {
    const replaced: string =
      ChatViewModel.getInstance().selectMentionSuggestion(nickname, this.inputText);
    this.$inputText(replaced);
    ChatViewModel.getInstance().clearSuggestionPopups();
  }

  private static commandLabelOf(suggestion: CommandSuggestion): string {
    if (suggestion.argsHint === null) {
      return suggestion.command;
    }
    return suggestion.command + ' ' + suggestion.argsHint;
  }
}
