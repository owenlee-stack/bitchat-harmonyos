/**
 * Push-to-talk key (US14, T070; Android VoiceInputComponents.kt
 * VoiceRecordButton parity): the capture arms only after a deliberate
 * 220 ms hold (stray taps do nothing), ends on release and discards
 * captures shorter than 600 ms (spec US14 minimum) or when the finger
 * slides up out of the key (slide-to-cancel). The 10 s auto-stop stays
 * with the ChatViewModel poll loop (T054).
 *
 * The key must stay mounted while the recording strip is visible, so
 * the release always lands on it even after the surrounding layout
 * changed (Android ArmDelayMs guards the same swap hazard); tearing the
 * key down mid-capture cancels it (aboutToDisappear).
 */
import { PttReleaseKind, PTT_HOLD_THRESHOLD_MS, pttReleaseKind } from '../service/livevoice/PttPolicy';

/** Finger travel (vp) that arms slide-to-cancel while capturing. */
const CANCEL_SLIDE_VP = 100;

@ComponentV2
export struct PttButton {
  /** True while the ChatViewModel capture runs (visual state only). */
  @Param recording: boolean = false;
  @Param idleLabel: string = '按住说话';
  @Param recordingLabel: string = '松开发送';
  @Param cancelArmedLabel: string = '松开取消';
  /** Fired once the 220 ms hold threshold elapsed with the finger down. */
  @Event onCaptureStart: () => void = (): void => {};
  /** Release after at least 600 ms without sliding up: send. */
  @Event onCaptureFinish: () => void = (): void => {};
  /** Slide-up release, sub-600 ms release or teardown: discard. */
  @Event onCaptureCancel: () => void = (): void => {};

  @Local pressed: boolean = false;
  @Local cancelArmed: boolean = false;
  private holdTimer: number = -1;
  private capturing: boolean = false;
  private captureStartAtMs: number = 0;
  private downYVp: number = 0;

  build() {
    Text(this.labelOf())
      .fontSize(13)
      .fontColor(this.labelColorOf())
      .padding({ top: 6, bottom: 6 })
      .onTouch((event: TouchEvent) => {
        this.onTouchEvent(event);
      })
  }

  aboutToDisappear(): void {
    this.clearHoldTimer();
    if (this.capturing) {
      this.capturing = false;
      this.cancelArmed = false;
      this.pressed = false;
      this.onCaptureCancel();
    }
  }

  private onTouchEvent(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.pressed = true;
      this.cancelArmed = false;
      this.downYVp = PttButton.firstTouchY(event);
      this.clearHoldTimer();
      this.holdTimer = setTimeout(() => {
        this.beginCapture();
      }, PTT_HOLD_THRESHOLD_MS);
      return;
    }
    if (event.type === TouchType.Move) {
      if (this.capturing) {
        this.cancelArmed =
          PttButton.firstTouchY(event) - this.downYVp <= -CANCEL_SLIDE_VP;
      }
      return;
    }
    if (event.type === TouchType.Up) {
      this.pressed = false;
      this.clearHoldTimer();
      if (this.capturing) {
        this.capturing = false;
        const elapsedMs: number = Date.now() - this.captureStartAtMs;
        const discard: boolean = this.cancelArmed ||
          pttReleaseKind(elapsedMs) === PttReleaseKind.TOO_SHORT;
        this.cancelArmed = false;
        if (discard) {
          this.onCaptureCancel();
        } else {
          this.onCaptureFinish();
        }
      }
      return;
    }
    if (event.type === TouchType.Cancel) {
      this.pressed = false;
      this.clearHoldTimer();
      if (this.capturing) {
        this.capturing = false;
        this.cancelArmed = false;
        this.onCaptureCancel();
      }
    }
  }

  private beginCapture(): void {
    this.holdTimer = -1;
    if (!this.pressed || this.capturing) {
      return;
    }
    this.capturing = true;
    this.captureStartAtMs = Date.now();
    this.onCaptureStart();
  }

  private clearHoldTimer(): void {
    if (this.holdTimer >= 0) {
      clearTimeout(this.holdTimer);
      this.holdTimer = -1;
    }
  }

  private labelOf(): string {
    if (this.cancelArmed) {
      return this.cancelArmedLabel;
    }
    if (this.recording || this.capturing) {
      return this.recordingLabel;
    }
    return this.idleLabel;
  }

  private labelColorOf(): string {
    if (this.cancelArmed || this.recording || this.capturing) {
      return '#E57373';
    }
    return '#64B5F6';
  }

  /** Y coordinate (vp) of the first changed touch; 0 when absent. */
  private static firstTouchY(event: TouchEvent): number {
    const touches: TouchObject[] = event.changedTouches;
    if (touches.length === 0) {
      return 0;
    }
    return touches[0].y;
  }
}
