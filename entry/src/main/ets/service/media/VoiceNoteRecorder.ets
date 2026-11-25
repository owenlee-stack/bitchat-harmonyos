/**
 * Voice-note recorder (US10, T054; Android VoiceRecorder.kt parity).
 *
 * The HarmonyOS SDK has no audio decoder and AVRecorder cannot report a
 * live amplitude, so recording captures raw PCM (AudioCapturer, 8 kHz
 * mono S16LE) and assembles a G.711 mu-law WAV (format tag 7, 8,000 B/s)
 * on stop: a 10-second note stays ~80 KB, inside the private-media
 * receive bound, playable by AVPlayer and byte-parseable for waveforms
 * without any codec (VoiceNoteWaveform).
 *
 * Files land in filesDir/voicenotes/outgoing (panic-swept, Android
 * parity); cancel discards the in-memory capture without writing.
 */
import { audio } from '@kit.AudioKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import EntryAbility from '../../entryability/EntryAbility';
import { buildMulawWav, mulawEncode } from './VoiceNoteWaveform';

const DOMAIN = 0x0000;
const TAG = 'VoiceNoteRecorder';
/** Hard cap on one capture (samples): matches the 10 s UI cap. */
const MAX_CAPTURE_SAMPLES = 80000;

export class VoiceNoteRecorder {
  private capturer: audio.AudioCapturer | null = null;
  /** Signed 16-bit PCM samples captured so far (in-memory only). */
  private pcmSamples: number[] = [];
  private lastAmplitude: number = 0;

  isRecording(): boolean {
    return this.capturer !== null;
  }

  /** Last captured buffer peak magnitude (0..32768), for the visualizer. */
  pollAmplitude(): number {
    return this.lastAmplitude;
  }

  /**
   * Start capturing from the microphone. Resolves false when the
   * capturer cannot be created/started (permission denied, busy mic).
   */
  async start(): Promise<boolean> {
    if (this.capturer !== null) {
      return true;
    }
    const context: common.UIAbilityContext | null = EntryAbility.getUiAbilityContext();
    if (context === null) {
      return false;
    }
    this.pcmSamples = [];
    this.lastAmplitude = 0;
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_8000,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const capturerInfo: audio.AudioCapturerInfo = {
      source: audio.SourceType.SOURCE_TYPE_MIC,
      capturerFlags: 0
    };
    const options: audio.AudioCapturerOptions = {
      streamInfo: streamInfo,
      capturerInfo: capturerInfo
    };
    let created: audio.AudioCapturer | null = null;
    try {
      created = await audio.createAudioCapturer(options);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'create capturer failed: %{public}s', err.message);
      return false;
    }
    const capturer: audio.AudioCapturer = created;
    capturer.on('readData', (buffer: ArrayBuffer): void => {
      this.consumePcmBuffer(buffer);
    });
    try {
      await capturer.start();
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'capturer start failed: %{public}s', err.message);
      this.releaseCapturer(capturer);
      return false;
    }
    this.capturer = capturer;
    return true;
  }

  /**
   * Stop the capture. Returns the written mu-law WAV path, or null when
   * canceled / nothing captured / the write failed.
   */
  async stop(canceled: boolean): Promise<string | null> {
    const capturer: audio.AudioCapturer | null = this.capturer;
    this.capturer = null;
    const samples: number[] = this.pcmSamples;
    this.pcmSamples = [];
    this.lastAmplitude = 0;
    if (capturer !== null) {
      try {
        capturer.off('readData');
      } catch (e) {
        // Listener teardown is best-effort before release.
      }
      try {
        await capturer.stop();
      } catch (e) {
        const err = e as BusinessError;
        hilog.warn(DOMAIN, TAG, 'capturer stop: %{public}s', err.message);
      }
      this.releaseCapturer(capturer);
    }
    if (canceled || samples.length === 0) {
      return null;
    }
    return this.writeMulawWav(samples);
  }

  /** Peak-magnitude track + sample accumulation for one PCM buffer. */
  private consumePcmBuffer(buffer: ArrayBuffer): void {
    if (this.capturer === null || this.pcmSamples.length >= MAX_CAPTURE_SAMPLES) {
      return;
    }
    const view: Int16Array = new Int16Array(buffer);
    let peak: number = 0;
    const room: number = MAX_CAPTURE_SAMPLES - this.pcmSamples.length;
    const count: number = Math.min(view.length, room);
    for (let i: number = 0; i < count; i++) {
      const sample: number = view[i];
      const magnitude: number = sample < 0 ? -sample : sample;
      if (magnitude > peak) {
        peak = magnitude;
      }
      this.pcmSamples.push(sample);
    }
    this.lastAmplitude = peak;
  }

  /** mu-law encode + WAV assemble + write into voicenotes/outgoing. */
  private writeMulawWav(samples: number[]): string | null {
    const context: common.UIAbilityContext | null = EntryAbility.getUiAbilityContext();
    if (context === null) {
      return null;
    }
    try {
      const dir: string = context.filesDir + '/voicenotes/outgoing';
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      const mulaw: Uint8Array = new Uint8Array(samples.length);
      for (let i: number = 0; i < samples.length; i++) {
        mulaw[i] = mulawEncode(samples[i]);
      }
      const wav: Uint8Array = buildMulawWav(mulaw);
      const name: string = 'voice_' + Date.now() + '.wav';
      const target: string = dir + '/' + name;
      const out: ArrayBuffer = new ArrayBuffer(wav.byteLength);
      new Uint8Array(out).set(wav);
      const file: fileIo.File = fileIo.openSync(target,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, out);
      } finally {
        fileIo.closeSync(file);
      }
      return target;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'write wav failed: %{public}s', err.message);
      return null;
    }
  }

  private releaseCapturer(capturer: audio.AudioCapturer): void {
    try {
      capturer.release();
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'capturer release: %{public}s', err.message);
    }
  }
}
