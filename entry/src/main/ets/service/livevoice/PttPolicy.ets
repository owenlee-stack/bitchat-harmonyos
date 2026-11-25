/**
 * PTT interaction policy (US14, T070), pure ArkTS: the timing decisions
 * of the push-to-talk gesture and the receive-side amplitude proxy,
 * mirroring bitchat-android:
 *  - VoiceInputComponents.kt HoldToRecordMs (220 ms): a press shorter
 *    than this never starts a capture (stray-tap guard);
 *  - LiveVoiceCapture.kt MIN_VALID_DURATION_MS (600 ms): a capture
 *    released before 600 ms is discarded instead of sent (spec US14
 *    "shortest 600ms");
 *  - MaxRecordingMs (10 s): the capture auto-stops;
 *  - AAC-LC 16 kHz 16 kbps carries ~128 payload bytes per 1024-sample
 *    access unit; the average access-unit size of one received frame
 *    batch is a usable loudness proxy for the scrolling waveform
 *    (louder speech -> more bits), since ArkTS has no AAC decoder.
 *
 * No @kit import: this module is host-runnable and contract-tested.
 */

/** Press-and-hold intent threshold before a capture starts (ms). */
export const PTT_HOLD_THRESHOLD_MS = 220;

/** Captures released earlier than this are discarded (ms, spec US14). */
export const PTT_MIN_CAPTURE_MS = 600;

/** Hard cap on one capture (ms); the poll loop auto-stops past it. */
export const PTT_MAX_CAPTURE_MS = 10000;

/** AAC-LC 16 kHz 16 kbps reference access-unit payload size (bytes). */
export const LIVE_FRAME_REFERENCE_BYTES = 128;

/** Verdict of releasing the PTT key after a capture started. */
export enum PttReleaseKind {
  /** Keep the capture and send it. */
  SEND,
  /** Shorter than PTT_MIN_CAPTURE_MS: discard without sending. */
  TOO_SHORT
}

/** True once the press has been held long enough to start capturing. */
export function pttHoldReached(pressDurationMs: number): boolean {
  return pressDurationMs >= PTT_HOLD_THRESHOLD_MS;
}

/** SEND once the capture ran at least PTT_MIN_CAPTURE_MS, else TOO_SHORT. */
export function pttReleaseKind(captureDurationMs: number): PttReleaseKind {
  if (captureDurationMs >= PTT_MIN_CAPTURE_MS) {
    return PttReleaseKind.SEND;
  }
  return PttReleaseKind.TOO_SHORT;
}

/** True once the capture ran past the 10 s cap and must auto-stop. */
export function pttAutoStopReached(captureDurationMs: number): boolean {
  return captureDurationMs >= PTT_MAX_CAPTURE_MS;
}

/**
 * Receive-side loudness proxy of one ordered frame batch: the average
 * AAC access-unit payload size mapped onto [0,1] against the 16 kbps
 * reference (silence compresses far below 128 B, loud speech above it).
 */
export function liveFrameAmplitudeNorm(avgFrameBytes: number): number {
  if (avgFrameBytes <= 0) {
    return 0;
  }
  const norm: number = avgFrameBytes / (2 * LIVE_FRAME_REFERENCE_BYTES);
  return Math.min(Math.max(norm, 0), 1);
}
