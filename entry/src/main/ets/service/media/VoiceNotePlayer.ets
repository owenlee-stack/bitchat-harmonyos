/**
 * Voice-note player (US10, T054; Android VoiceNotePlayer.kt parity).
 *
 * One shared AVPlayer instance so a single voice note plays at a time
 * (tapping a new bubble stops the previous one). Local files are opened
 * as fds and addressed with 'fd://<fd>'; the fd stays open until the
 * player is released. Non-WAV notes (M4A from Android peers) play
 * through the same path - AVPlayer decodes them natively.
 *
 * The wrapper reports progress (position/duration/playing) and
 * completion through VoiceNotePlaybackListener so ChatViewModel can
 * mirror it into ChatState for the MediaBubble waveform tinting.
 */
import { media } from '@kit.MediaKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN = 0x0000;
const TAG = 'VoiceNotePlayer';

/** Playback events mirrored into ChatState by ChatViewModel (T054). */
export interface VoiceNotePlaybackListener {
  onVoiceNoteProgress(path: string, positionMs: number, durationMs: number,
    playing: boolean): void;
  onVoiceNoteFinished(path: string): void;
  onVoiceNoteError(path: string): void;
}

export class VoiceNotePlayer {
  private player: media.AVPlayer | null = null;
  private openedFile: fileIo.File | null = null;
  private currentPath: string = '';
  private listener: VoiceNotePlaybackListener | null = null;
  private releasing: boolean = false;

  setListener(listener: VoiceNotePlaybackListener): void {
    this.listener = listener;
  }

  /** Path currently loaded ('' when idle). */
  getActivePath(): string {
    return this.currentPath;
  }

  /** True while a note is loaded and not yet released. */
  hasActivePlayback(): boolean {
    return this.player !== null && !this.releasing;
  }

  /**
   * Start playing one local file. Any previous playback is released
   * first; a failure notifies onVoiceNoteError and leaves the player
   * idle.
   */
  async play(path: string): Promise<void> {
    await this.release();
    let opened: fileIo.File | null = null;
    try {
      opened = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'open note failed: %{public}s', err.message);
      this.notifyError(path);
      return;
    }
    let created: media.AVPlayer | null = null;
    try {
      created = await media.createAVPlayer();
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'create player failed: %{public}s', err.message);
      this.closeOpened(opened);
      this.notifyError(path);
      return;
    }
    const player: media.AVPlayer = created;
    this.player = player;
    this.openedFile = opened;
    this.currentPath = path;
    this.releasing = false;
    player.on('timeUpdate', (time: number): void => {
      if (this.player === player && !this.releasing) {
        this.notifyProgress(time, player.duration, true);
      }
    });
    player.on('stateChange', (state: media.AVPlayerState,
      reason: media.StateChangeReason): void => {
      this.onPlayerState(player, path, state);
    });
    player.on('error', (error: BusinessError): void => {
      hilog.error(DOMAIN, TAG, 'player error %{public}d: %{public}s',
        error.code, error.message);
      void this.release();
      this.notifyError(path);
    });
    player.url = 'fd://' + opened.fd;
  }

  /** Pause the active playback (no-op when idle). */
  pause(): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null || this.releasing) {
      return;
    }
    try {
      player.pause();
      this.notifyProgress(player.currentTime, player.duration, false);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'pause failed: %{public}s', err.message);
    }
  }

  /** Resume the paused active playback (no-op when idle). */
  resume(): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null || this.releasing) {
      return;
    }
    try {
      player.play();
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'play failed: %{public}s', err.message);
    }
  }

  /** Seek the active playback to [0,1] of its duration. */
  seekFraction(fraction: number): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null || this.releasing) {
      return;
    }
    const clamped: number = Math.min(Math.max(fraction, 0), 1);
    const duration: number = player.duration > 0 ? player.duration : 0;
    try {
      player.seek(Math.floor(clamped * duration));
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'seek failed: %{public}s', err.message);
    }
  }

  /** Release the player and the held fd; safe to re-call. */
  async release(): Promise<void> {
    const player: media.AVPlayer | null = this.player;
    const opened: fileIo.File | null = this.openedFile;
    this.player = null;
    this.openedFile = null;
    this.currentPath = '';
    this.releasing = false;
    if (player !== null) {
      try {
        await player.release();
      } catch (e) {
        const err = e as BusinessError;
        hilog.warn(DOMAIN, TAG, 'release player: %{public}s', err.message);
      }
    }
    this.closeOpened(opened);
  }

  private onPlayerState(player: media.AVPlayer, path: string,
    state: media.AVPlayerState): void {
    if (this.player !== player || this.releasing) {
      return;
    }
    if (state === 'initialized') {
      player.prepare().catch((error: BusinessError): void => {
        hilog.error(DOMAIN, TAG, 'prepare failed: %{public}s', error.message);
      });
      return;
    }
    if (state === 'prepared') {
      player.play().catch((error: BusinessError): void => {
        hilog.error(DOMAIN, TAG, 'play failed: %{public}s', error.message);
      });
      return;
    }
    if (state === 'completed') {
      this.notifyProgress(player.duration, player.duration, false);
      const listener: VoiceNotePlaybackListener | null = this.listener;
      if (listener !== null) {
        listener.onVoiceNoteFinished(path);
      }
      void this.release();
    }
  }

  private notifyProgress(positionMs: number, durationMs: number,
    playing: boolean): void {
    const listener: VoiceNotePlaybackListener | null = this.listener;
    if (listener === null || this.currentPath === '') {
      return;
    }
    listener.onVoiceNoteProgress(this.currentPath, positionMs, durationMs,
      playing);
  }

  private notifyError(path: string): void {
    const listener: VoiceNotePlaybackListener | null = this.listener;
    if (listener !== null) {
      listener.onVoiceNoteError(path);
    }
  }

  private closeOpened(opened: fileIo.File | null): void {
    if (opened === null) {
      return;
    }
    try {
      fileIo.closeSync(opened);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'close fd: %{public}s', err.message);
    }
  }
}
