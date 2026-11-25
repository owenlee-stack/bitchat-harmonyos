/**
 * Voice-note waveform kernel (US10, T054), pure ArkTS: the HarmonyOS SDK
 * exposes no audio decoder, so bitchat records voice notes as G.711 mu-law
 * WAV (8 kHz mono, 8,000 B/s - a 10 s note is ~80 KB, inside the
 * 120,064-byte private-media receive bound). That keeps every waveform
 * computation pure byte math:
 *  - CCITT G.711 mu-law codec (the canonical Sun Microsystems g711.c
 *    tables/algorithm also used by FFmpeg and every WAV player);
 *  - RIFF/WAV writer and chunk-walking parser for the format-7 (mu-law)
 *    files this app produces;
 *  - Android Waveform.kt parity helpers: normalizeAmplitudeSample
 *    (ln(1+a)/ln(1+32768)) and resampleWave (linear interpolation),
 *    both shared by the recording visualizer and the bubble renderer.
 *
 * No @kit import: this module is host-runnable and contract-tested.
 */

/** Voice-note capture rate (Hz); mu-law is defined at 8 kHz. */
export const VOICE_NOTE_SAMPLE_RATE = 8000;
/** Waveform bins per voice note (Android AudioWaveformExtractor parity). */
export const WAVEFORM_BINS = 120;
/** Mu-law segment lower bound after bias (decode: ((m<<3)+132)<<s). */
const MULAW_BIAS = 132;

/**
 * CCITT G.711 mu-law encode: signed 16-bit PCM -> 8-bit mu-law byte.
 * Exact inverse of the universal g711.c ulaw2linear decode table used
 * by every WAV player (bias 132, no 14-bit pre-shift): silence is
 * 0xFF, positive full scale 0x80, negative full scale 0x00, and the
 * round-trip error stays inside one segment step (<= 1024 at the top
 * segment, <= 4 at the bottom).
 */
export function mulawEncode(sample: number): number {
  let mask: number = 0xFF;
  let magnitude: number = sample;
  if (magnitude < 0) {
    mask = 0x7F;
    magnitude = -magnitude;
  }
  if (magnitude > 32767) {
    magnitude = 32767;
  }
  const biased: number = magnitude + MULAW_BIAS;
  let segment: number = 0;
  while (segment < 7 && (biased >> (segment + 1)) >= MULAW_BIAS) {
    segment++;
  }
  // biased in [260<<s, 264<<s) falls into the gap between the decode
  // grids of segment s (top 252<<s) and s+1 (bottom 132<<(s+1)): the
  // nearest reconstruction is 132<<(s+1), so step up one segment and
  // clamp the mantissa at 0.
  if (segment < 7 && (biased >> segment) >= MULAW_BIAS + 128) {
    segment++;
  }
  let quantized: number = ((biased >> segment) - MULAW_BIAS) >> 3;
  if (quantized < 0) {
    quantized = 0;
  } else if (quantized > 15) {
    quantized = 15;
  }
  const code: number = (segment << 4) | quantized;
  return (code ^ mask) & 0xFF;
}

/** CCITT G.711 mu-law decode: 8-bit mu-law byte -> signed 16-bit PCM. */
export function mulawDecode(uValue: number): number {
  const ulaw: number = (~uValue) & 0xFF;
  const magnitude: number = (((ulaw & 0x0F) << 3) + MULAW_BIAS) << ((ulaw & 0x70) >> 4);
  return (ulaw & 0x80) !== 0 ? MULAW_BIAS - magnitude : magnitude - MULAW_BIAS;
}

function writeAscii(bytes: Uint8Array, offset: number, text: string): void {
  for (let i: number = 0; i < text.length; i++) {
    bytes[offset + i] = text.charCodeAt(i);
  }
}

function writeUint16(bytes: Uint8Array, offset: number, value: number): void {
  bytes[offset] = value & 0xFF;
  bytes[offset + 1] = (value >> 8) & 0xFF;
}

function writeUint32(bytes: Uint8Array, offset: number, value: number): void {
  bytes[offset] = value & 0xFF;
  bytes[offset + 1] = (value >> 8) & 0xFF;
  bytes[offset + 2] = (value >> 16) & 0xFF;
  bytes[offset + 3] = (value >> 24) & 0xFF;
}

function readUint16(bytes: Uint8Array, offset: number): number {
  return bytes[offset] | (bytes[offset + 1] << 8);
}

function readUint32(bytes: Uint8Array, offset: number): number {
  return (bytes[offset] | (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)) >>> 0;
}

function asciiAt(bytes: Uint8Array, offset: number): string {
  let out: string = '';
  for (let i: number = 0; i < 4; i++) {
    out += String.fromCharCode(bytes[offset + i]);
  }
  return out;
}

/**
 * Assemble one complete format-7 (mu-law) WAV file: 44-byte RIFF header
 * (8000 Hz, mono, 8-bit) followed by the mu-law sample bytes.
 */
export function buildMulawWav(mulawSamples: Uint8Array): Uint8Array {
  const dataLength: number = mulawSamples.length;
  const out: Uint8Array = new Uint8Array(44 + dataLength);
  writeAscii(out, 0, 'RIFF');
  writeUint32(out, 4, 36 + dataLength);
  writeAscii(out, 8, 'WAVE');
  writeAscii(out, 12, 'fmt ');
  writeUint32(out, 16, 16);
  writeUint16(out, 20, 7);
  writeUint16(out, 22, 1);
  writeUint32(out, 24, VOICE_NOTE_SAMPLE_RATE);
  writeUint32(out, 28, VOICE_NOTE_SAMPLE_RATE);
  writeUint16(out, 32, 1);
  writeUint16(out, 34, 8);
  writeAscii(out, 36, 'data');
  writeUint32(out, 40, dataLength);
  out.set(mulawSamples, 44);
  return out;
}

/** Parsed facts of one WAV file (format-7 files only, T054). */
export class WavInfo {
  readonly formatTag: number;
  readonly channels: number;
  readonly sampleRate: number;
  readonly dataOffset: number;
  readonly dataLength: number;

  constructor(formatTag: number, channels: number, sampleRate: number,
    dataOffset: number, dataLength: number) {
    this.formatTag = formatTag;
    this.channels = channels;
    this.sampleRate = sampleRate;
    this.dataOffset = dataOffset;
    this.dataLength = dataLength;
  }

  /** Whole-file duration in milliseconds (0 for empty/unknown data). */
  durationMs(): number {
    const bytesPerSecond: number = this.sampleRate * this.channels;
    if (bytesPerSecond <= 0 || this.dataLength <= 0) {
      return 0;
    }
    return Math.floor(this.dataLength * 1000 / bytesPerSecond);
  }
}

/**
 * Walk the RIFF chunks of one WAV file and return its format facts.
 * Unknown chunk types are skipped by their size field (RIFF is a
 * chunk-walking format; 'LIST'/'fact'/extra 'fmt ' tails must not
 * misalign the 'data' lookup). Null when the bytes are not a WAV.
 */
export function parseWavInfo(bytes: Uint8Array): WavInfo | null {
  if (bytes.length < 44 || asciiAt(bytes, 0) !== 'RIFF' ||
    asciiAt(bytes, 8) !== 'WAVE') {
    return null;
  }
  let formatTag: number = -1;
  let channels: number = 0;
  let sampleRate: number = 0;
  let dataOffset: number = -1;
  let dataLength: number = 0;
  let offset: number = 12;
  while (offset + 8 <= bytes.length) {
    const chunkId: string = asciiAt(bytes, offset);
    const chunkSize: number = readUint32(bytes, offset + 4);
    const bodyStart: number = offset + 8;
    if (chunkId === 'fmt ' && chunkSize >= 16 && bodyStart + 16 <= bytes.length) {
      formatTag = readUint16(bytes, bodyStart);
      channels = readUint16(bytes, bodyStart + 2);
      sampleRate = readUint32(bytes, bodyStart + 4);
    } else if (chunkId === 'data') {
      dataOffset = bodyStart;
      dataLength = Math.min(chunkSize, bytes.length - bodyStart);
      break;
    }
    offset = bodyStart + chunkSize + (chunkSize % 2);
  }
  if (formatTag < 0 || dataOffset < 0) {
    return null;
  }
  return new WavInfo(formatTag, channels, sampleRate, dataOffset, dataLength);
}

/**
 * Extract the normalized waveform bins of one mu-law WAV file
 * (Android AudioWaveformExtractor parity): decode each mu-law byte,
 * bucket peak magnitudes into `bins` time slices, then max-normalize
 * so the loudest bin reaches 1.0. Null when the bytes are not a
 * format-7 WAV (M4A/AAC notes from Android peers have no ArkTS
 * decoder; their bubbles render without a waveform).
 */
export function parseMulawWavWaveform(bytes: Uint8Array,
  bins: number): number[] | null {
  const info: WavInfo | null = parseWavInfo(bytes);
  if (info === null || info.formatTag !== 7 || info.dataLength <= 0 ||
    bins <= 0) {
    return null;
  }
  const out: number[] = [];
  const peaks: number[] = [];
  for (let i: number = 0; i < bins; i++) {
    out.push(0);
    peaks.push(0);
  }
  for (let i: number = 0; i < info.dataLength; i++) {
    const decoded: number = mulawDecode(bytes[info.dataOffset + i]);
    const magnitude: number = decoded < 0 ? -decoded : decoded;
    const bin: number = Math.min(Math.floor(i * bins / info.dataLength), bins - 1);
    if (magnitude > peaks[bin]) {
      peaks[bin] = magnitude;
    }
  }
  let maxPeak: number = 0;
  for (let i: number = 0; i < bins; i++) {
    if (peaks[i] > maxPeak) {
      maxPeak = peaks[i];
    }
  }
  if (maxPeak <= 0) {
    maxPeak = 1;
  }
  for (let i: number = 0; i < bins; i++) {
    out[i] = Math.min(peaks[i] / maxPeak, 1);
  }
  return out;
}

/** ln(1+a)/ln(1+32768), clamped to [0,1] (Waveform.kt parity). */
export function normalizeAmplitudeSample(amp: number): number {
  const clamped: number = Math.max(0, amp);
  const norm: number = Math.log(1 + clamped) / Math.log(1 + 32768);
  return Math.min(Math.max(norm, 0), 1);
}

/**
 * Linear-interpolation resample of a [0,1] waveform onto `target` bins
 * (Waveform.kt resampleWave parity: identity when sizes match, zeros
 * for an empty input, clamped interpolation otherwise).
 */
export function resampleWave(values: number[], target: number): number[] {
  const out: number[] = [];
  if (values.length === 0 || target <= 0) {
    for (let i: number = 0; i < Math.max(target, 0); i++) {
      out.push(0);
    }
    return out;
  }
  if (target === 1) {
    out.push(values[0]);
    return out;
  }
  const step: number = (values.length - 1) / (target - 1);
  let x: number = 0;
  for (let i: number = 0; i < target; i++) {
    const index: number = Math.floor(x);
    const fraction: number = x - index;
    const a: number = values[index];
    const b: number = values[Math.min(values.length - 1, index + 1)];
    out.push(Math.min(Math.max(a + (b - a) * fraction, 0), 1));
    x += step;
  }
  return out;
}
