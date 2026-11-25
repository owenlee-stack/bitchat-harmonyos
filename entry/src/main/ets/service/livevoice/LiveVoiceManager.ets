/**
 * Live voice receive manager (US14, T069) - the device half of
 * bitchat-android LiveVoiceManager.kt (FR-028): ordered AAC access units
 * coming out of the pure LiveVoiceAssembler gain a seven-byte ADTS header
 * (AdtsFramer) and stream into `voice_live_<burst>_<peer>_<scope>.aac`
 * under cacheDir/files/incoming; a finished burst renames to
 * `voice_<burst>_<peer>_<scope>.aac` and lands in the finished-burst
 * registry (10 min TTL, cap 32) so the later finalized voice note can be
 * absorbed (T070). Live files never touch filesDir: untrusted incoming
 * bytes stay reclaimable cache (issue #592 defense, MediaFileStore policy).
 *
 * The reassembly quotas/ordering semantics live in LiveVoiceAssembler;
 * capture (AVRecorder), playback and the PTT UI land with T070.
 */
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AdtsFramer } from './VoiceBurstPacket';
import { LiveVoiceAssembler, LiveVoiceAssemblerDelegate, LiveVoiceBurstStats,
  LiveVoiceScope } from './LiveVoiceAssembler';
import { liveFrameAmplitudeNorm } from './PttPolicy';

const DOMAIN = 0x0000;
const TAG = 'LiveVoiceManager';
const FINISHED_TTL_MS: number = 10 * 60 * 1000;
const FINISHED_CAP: number = 32;

/**
 * Live-voice receive events mirrored into ChatState by the ChatViewModel
 * (T070): one talker's burst lifecycle plus a per-frame-batch loudness
 * proxy for the scrolling waveform (ArkTS has no AAC decoder, so the
 * average access-unit size stands in for the amplitude).
 */
export interface LiveVoiceUiListener {
  onLiveVoiceStarted(peerID: string, scope: LiveVoiceScope,
    burstIDHex: string): void;
  onLiveVoiceAmplitude(peerID: string, scope: LiveVoiceScope,
    burstIDHex: string, amplitudeNorm: number): void;
  onLiveVoiceFinished(peerID: string, scope: LiveVoiceScope,
    burstIDHex: string, canceled: boolean): void;
}

/** One finalized live burst awaiting voice-note absorption. */
export class FinishedLiveBurst {
  readonly peerID: string;
  readonly burstIDHex: string;
  readonly scope: LiveVoiceScope;
  /** Absolute path of the finished .aac; '' when persistence was unavailable. */
  readonly path: string;
  readonly finishedAtMs: number;
  readonly expiresAtMs: number;
  readonly frames: number;
  readonly bytes: number;

  constructor(peerID: string, burstIDHex: string, scope: LiveVoiceScope, path: string,
    finishedAtMs: number, expiresAtMs: number, frames: number, bytes: number) {
    this.peerID = peerID;
    this.burstIDHex = burstIDHex;
    this.scope = scope;
    this.path = path;
    this.finishedAtMs = finishedAtMs;
    this.expiresAtMs = expiresAtMs;
    this.frames = frames;
    this.bytes = bytes;
  }
}

export class LiveVoiceManager implements LiveVoiceAssemblerDelegate {
  private static instance: LiveVoiceManager | null = null;
  private cacheRoot: string = '';
  private readonly assembler: LiveVoiceAssembler;
  /** Assembly key -> open live file descriptor. */
  private readonly liveFds: Map<string, number> = new Map<string, number>();
  /** Assembly key -> live file path. */
  private readonly livePaths: Map<string, string> = new Map<string, string>();
  private finishedBursts: FinishedLiveBurst[] = [];
  /** ChatViewModel mirror of the receive pipeline (T070). */
  private uiListener: LiveVoiceUiListener | null = null;

  static getInstance(): LiveVoiceManager {
    if (LiveVoiceManager.instance === null) {
      LiveVoiceManager.instance = new LiveVoiceManager();
    }
    return LiveVoiceManager.instance;
  }

  private constructor() {
    this.assembler = new LiveVoiceAssembler(this);
  }

  /** Capture the sandbox cacheDir; idempotent, safe to re-call. */
  init(context: common.Context): void {
    this.cacheRoot = context.cacheDir;
  }

  /** Ingest one decoded burst frame from either transport scope. */
  handleFrame(peerID: string, scope: LiveVoiceScope, payload: Uint8Array,
    timestampMs: number): boolean {
    return this.assembler.handleFrame(peerID, scope, payload, timestampMs);
  }

  /** Register the UI event mirror (ChatViewModel, T070); null detaches. */
  setUiListener(listener: LiveVoiceUiListener | null): void {
    this.uiListener = listener;
  }

  /** Registry lookup for the absorption path (T070). */
  getFinishedBurst(peerID: string, scope: LiveVoiceScope,
    burstIDHex: string): FinishedLiveBurst | null {
    this.pruneFinished();
    for (let i: number = 0; i < this.finishedBursts.length; i++) {
      const burst: FinishedLiveBurst = this.finishedBursts[i];
      if (burst.peerID === peerID && burst.scope === scope &&
        burst.burstIDHex === burstIDHex) {
        return burst;
      }
    }
    return null;
  }

  /** Remove one finished burst from the registry (absorption consumed it). */
  consumeFinishedBurst(burst: FinishedLiveBurst): void {
    const next: FinishedLiveBurst[] = [];
    for (let i: number = 0; i < this.finishedBursts.length; i++) {
      if (this.finishedBursts[i] !== burst) {
        next.push(this.finishedBursts[i]);
      }
    }
    this.finishedBursts = next;
  }

  /**
   * Tear every assembly down (identity change / logout / panic): the
   * assembler cancels its timers, live files close and delete, the finished
   * registry drops (finished .aac files stay until the media panic sweep).
   */
  reset(): void {
    this.assembler.reset();
    this.liveFds.forEach((fd: number): void => {
      try {
        fileIo.closeSync(fd);
      } catch (e) {
        // Already closed.
      }
    });
    this.liveFds.clear();
    this.livePaths.forEach((path: string): void => {
      try {
        fileIo.unlinkSync(path);
      } catch (e) {
        // Already gone.
      }
    });
    this.livePaths.clear();
    this.finishedBursts = [];
  }

  /** Extract the burst ID from a finalized `voice_<burstID>.m4a` name. */
  static burstIDFromVoiceFileName(fileName: string): string | null {
    if (!fileName.startsWith('voice_')) {
      return null;
    }
    const id: string = fileName.substring('voice_'.length, 'voice_'.length + 16);
    if (id.length !== 16) {
      return null;
    }
    for (let i: number = 0; i < id.length; i++) {
      const digit: number = LiveVoiceManager.hexDigit(id.charAt(i));
      if (digit < 0) {
        return null;
      }
    }
    return id.toLowerCase();
  }

  // ------------------------------------------------------------------
  // LiveVoiceAssemblerDelegate
  // ------------------------------------------------------------------

  onBurstStarted(peerID: string, burstIDHex: string, scope: LiveVoiceScope,
    timestampMs: number): void {
    if (this.uiListener !== null) {
      this.uiListener.onLiveVoiceStarted(peerID, scope, burstIDHex);
    }
    if (this.cacheRoot === '') {
      return;
    }
    const key: string = LiveVoiceManager.assemblyKey(peerID, scope, burstIDHex);
    const dir: string = this.cacheRoot + '/files/incoming';
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      const path: string = dir + '/' + LiveVoiceManager.liveFileName(burstIDHex,
        peerID, scope, true);
      const file: fileIo.File = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      this.liveFds.set(key, file.fd);
      this.livePaths.set(key, path);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'open live voice file failed: %{public}s', err.message);
    }
  }

  onOrderedFrames(peerID: string, burstIDHex: string, scope: LiveVoiceScope,
    frames: Uint8Array[]): void {
    if (this.uiListener !== null && frames.length > 0) {
      let total: number = 0;
      for (let i: number = 0; i < frames.length; i++) {
        total += frames[i].length;
      }
      this.uiListener.onLiveVoiceAmplitude(peerID, scope, burstIDHex,
        liveFrameAmplitudeNorm(total / frames.length));
    }
    const key: string = LiveVoiceManager.assemblyKey(peerID, scope, burstIDHex);
    const fd: number | undefined = this.liveFds.get(key);
    if (fd === undefined) {
      return;
    }
    let totalBytes: number = 0;
    const framed: Uint8Array[] = [];
    for (let i: number = 0; i < frames.length; i++) {
      const adts: Uint8Array | null = AdtsFramer.frame(frames[i]);
      if (adts !== null) {
        framed.push(adts);
        totalBytes += adts.length;
      }
    }
    if (totalBytes === 0) {
      return;
    }
    const out: ArrayBuffer = new ArrayBuffer(totalBytes);
    const view: Uint8Array = new Uint8Array(out);
    let offset: number = 0;
    for (let i: number = 0; i < framed.length; i++) {
      view.set(framed[i], offset);
      offset += framed[i].length;
    }
    try {
      fileIo.writeSync(fd, out);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'write live voice frame failed: %{public}s', err.message);
    }
  }

  onBurstFinished(peerID: string, burstIDHex: string, scope: LiveVoiceScope,
    stats: LiveVoiceBurstStats): void {
    if (this.uiListener !== null) {
      this.uiListener.onLiveVoiceFinished(peerID, scope, burstIDHex, false);
    }
    const key: string = LiveVoiceManager.assemblyKey(peerID, scope, burstIDHex);
    const fd: number | undefined = this.liveFds.get(key);
    const livePath: string | undefined = this.livePaths.get(key);
    this.liveFds.delete(key);
    this.livePaths.delete(key);
    if (fd !== undefined) {
      try {
        fileIo.closeSync(fd);
      } catch (e) {
        // Already closed.
      }
    }
    if (livePath === undefined) {
      return;
    }
    if (stats.frames === 0) {
      try {
        fileIo.unlinkSync(livePath);
      } catch (e) {
        // Already gone.
      }
      return;
    }
    const finishedPath: string = this.cacheRoot + '/files/incoming/' +
      LiveVoiceManager.liveFileName(burstIDHex, peerID, scope, false);
    try {
      fileIo.renameSync(livePath, finishedPath);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'finalize live voice file failed: %{public}s', err.message);
      return;
    }
    const now: number = Date.now();
    this.pruneFinished();
    this.finishedBursts.push(new FinishedLiveBurst(peerID, burstIDHex, scope,
      finishedPath, now, now + FINISHED_TTL_MS, stats.frames, stats.bytes));
  }

  onBurstCanceled(peerID: string, burstIDHex: string, scope: LiveVoiceScope): void {
    if (this.uiListener !== null) {
      this.uiListener.onLiveVoiceFinished(peerID, scope, burstIDHex, true);
    }
    const key: string = LiveVoiceManager.assemblyKey(peerID, scope, burstIDHex);
    const fd: number | undefined = this.liveFds.get(key);
    const livePath: string | undefined = this.livePaths.get(key);
    this.liveFds.delete(key);
    this.livePaths.delete(key);
    if (fd !== undefined) {
      try {
        fileIo.closeSync(fd);
      } catch (e) {
        // Already closed.
      }
    }
    if (livePath !== undefined) {
      try {
        fileIo.unlinkSync(livePath);
      } catch (e) {
        // Already gone.
      }
    }
  }

  private static assemblyKey(peerID: string, scope: LiveVoiceScope,
    burstIDHex: string): string {
    return peerID + '|' + scope + '|' + burstIDHex;
  }

  private static liveFileName(burstIDHex: string, peerID: string,
    scope: LiveVoiceScope, live: boolean): string {
    const prefix: string = live ? 'voice_live_' : 'voice_';
    return prefix + burstIDHex + '_' + peerID + '_' +
      (scope === LiveVoiceScope.DIRECT_MESSAGE ? 'dm' : 'mesh') + '.aac';
  }

  private pruneFinished(): void {
    const now: number = Date.now();
    const kept: FinishedLiveBurst[] = [];
    for (let i: number = 0; i < this.finishedBursts.length; i++) {
      if (this.finishedBursts[i].expiresAtMs > now) {
        kept.push(this.finishedBursts[i]);
      }
    }
    while (kept.length >= FINISHED_CAP) {
      kept.shift();
    }
    this.finishedBursts = kept;
  }

  private static hexDigit(ch: string): number {
    if (ch >= '0' && ch <= '9') {
      return ch.charCodeAt(0) - '0'.charCodeAt(0);
    }
    if (ch >= 'a' && ch <= 'f') {
      return ch.charCodeAt(0) - 'a'.charCodeAt(0) + 10;
    }
    if (ch >= 'A' && ch <= 'F') {
      return ch.charCodeAt(0) - 'A'.charCodeAt(0) + 10;
    }
    return -1;
  }
}
