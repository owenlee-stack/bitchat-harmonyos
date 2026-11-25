/**
 * Shared dialog helpers (T044): panic-wipe confirmation dialog and result
 * toast; channel password prompt (T049, US9).
 *
 * The About screen's triple-tap logo (AboutView) calls showPanicConfirm;
 * confirming runs ChatViewModel.panicWipeAllData (the staged wipe from
 * T043) and surfaces the outcome as a toast, mirroring Android's
 * ChatScreen panic flow. Dialog/toast strings are verbatim Android
 * strings.xml parity targets; the wipe itself also posts the persistent
 * system notice into the public timeline (T043).
 *
 * The channel password prompt (T049) is a ComponentContent dialog: the
 * ChatPage host opens it through promptAction.openCustomDialog whenever
 * ChatState.showPasswordPrompt arms (joining a password-protected
 * channel), mirroring Android's PasswordPromptDialog (verbatim strings).
 */
import { UIContext } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { PanicWipeResult } from '../service/identity/IdentityManager';

const DOMAIN = 0x0000;
const TAG = 'CommonDialogs';

/** Verbatim Android strings.xml parity targets. */
const PANIC_CONFIRM_TITLE = 'Wipe all data?';
const PANIC_CONFIRM_BODY =
  'This permanently deletes your identity, keys, messages, and media on this device and creates a new identity. It can\'t be undone.';
const PANIC_CONFIRM_ACTION = 'Wipe';
const PANIC_CANCEL_ACTION = 'Cancel';
const PANIC_TOAST_COMPLETED = 'all data wiped — new identity created';
const PANIC_TOAST_INCOMPLETE =
  'wipe incomplete — some data may remain. triple-tap the logo to try again.';
/** Long enough for the two-line incomplete message. */
const PANIC_TOAST_DURATION_MS = 3500;

/** Channel password prompt strings (Android strings.xml parity, T049). */
const PASSWORD_PROMPT_TITLE = 'Enter Channel Password';
const PASSWORD_PROMPT_LABEL = 'Password';
const PASSWORD_PROMPT_JOIN = 'Join';
const PASSWORD_PROMPT_CANCEL = 'Cancel';

/**
 * Parameters handed to the password prompt through ComponentContent; the
 * host (ChatPage) supplies the callbacks so the dialog itself stays
 * state-free apart from the input field.
 */
export class PasswordPromptDialogParams {
  /** '#tag' channel the join is pending for. */
  readonly channel: string;
  /** Join tapped with the entered password. */
  readonly onJoin: (password: string) => void;
  /** Cancel tapped. */
  readonly onCancel: () => void;

  constructor(channel: string, onJoin: (password: string) => void,
    onCancel: () => void) {
    this.channel = channel;
    this.onJoin = onJoin;
    this.onCancel = onCancel;
  }
}

/** ComponentContent entry builder (T049 password prompt). */
@Builder
export function PasswordPromptDialogBuilder(params: PasswordPromptDialogParams) {
  PasswordPromptDialogContent({ dialogParams: params })
}

@ComponentV2
struct PasswordPromptDialogContent {
  @Param dialogParams: PasswordPromptDialogParams =
    new PasswordPromptDialogParams('', (): void => {
    }, (): void => {
    });
  @Local password: string = '';

  build() {
    Column({ space: 16 }) {
      Text(PASSWORD_PROMPT_TITLE)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
      Text('Channel ' + this.dialogParams.channel +
        ' is password protected. Enter the password to join.')
        .fontSize(14)
        .fontColor('#B0BEC5')
        .textAlign(TextAlign.Center)
      TextInput({ placeholder: PASSWORD_PROMPT_LABEL, text: this.password })
        .type(InputType.Password)
        .backgroundColor('#222222')
        .fontColor('#FFFFFF')
        .placeholderColor('#666666')
        .onChange((value: string) => {
          this.password = value;
        })
      Row({ space: 12 }) {
        Button(PASSWORD_PROMPT_CANCEL)
          .layoutWeight(1)
          .backgroundColor('#333333')
          .onClick(() => {
            this.dialogParams.onCancel();
          })
        Button(PASSWORD_PROMPT_JOIN)
          .layoutWeight(1)
          .enabled(this.password.trim().length > 0)
          .backgroundColor('#2E7D32')
          .onClick(() => {
            this.dialogParams.onJoin(this.password);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 24, bottom: 24 })
    .backgroundColor('#1A1A1A')
    .borderRadius(16)
  }
}

export class CommonDialogs {
  /**
   * Panic-wipe confirmation dialog (Android ChatScreen
   * showPanicConfirmation parity): destructive action highlighted,
   * cancel placed left.
   */
  static showPanicConfirm(uiContext: UIContext): void {
    uiContext.showAlertDialog({
      title: PANIC_CONFIRM_TITLE,
      message: PANIC_CONFIRM_BODY,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      buttons: [
        {
          value: PANIC_CANCEL_ACTION,
          action: (): void => {
          }
        },
        {
          value: PANIC_CONFIRM_ACTION,
          style: DialogButtonStyle.HIGHLIGHT,
          action: (): void => {
            CommonDialogs.runPanicWipe(uiContext);
          }
        }
      ]
    });
  }

  /** Short-lived result feedback; the timeline notice persists (T043). */
  static showResultToast(uiContext: UIContext, message: string): void {
    try {
      uiContext.getPromptAction().showToast({
        message: message,
        duration: PANIC_TOAST_DURATION_MS
      });
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'Show result toast failed: %{public}s', err.message);
    }
  }

  private static runPanicWipe(uiContext: UIContext): void {
    ChatViewModel.getInstance().panicWipeAllData()
      .then((result: PanicWipeResult | null): void => {
        if (result === null) {
          // Another wipe is already running; the UI ignores the tap.
          return;
        }
        CommonDialogs.showResultToast(uiContext,
          result.completed ? PANIC_TOAST_COMPLETED : PANIC_TOAST_INCOMPLETE);
      })
      .catch((error: BusinessError): void => {
        hilog.error(DOMAIN, TAG, 'Panic wipe failed: %{public}s', JSON.stringify(error));
      });
  }
}
