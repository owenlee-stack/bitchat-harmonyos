/**
 * Voice-note waveform contract tests (US10, T054): the pure mu-law /
 * WAV / resample kernel of VoiceNoteWaveform.ets against golden
 * vectors:
 *  - CCITT G.711 mu-law encode/decode (bias-132 16-bit convention, the
 *    exact inverse of the universal g711.c ulaw2linear table:
 *    0 -> 0xFF, +max -> 0x80, -max -> 0x00; 0xFF -> 0, 0x00 -> -32124,
 *    0x80 -> +32124, 0x7F -> 0);
 *  - the RIFF header layout the recorder writes (RIFF size, fmt tag 7,
 *    8 kHz mono 8-bit, byteRate 8000) and the chunk-walking parser
 *    (skips unknown chunks, tolerates odd-size padding, computes
 *    durationMs from the data chunk);
 *  - parseMulawWavWaveform bucketing/normalization and its format gate
 *    (format 1 PCM or non-WAV bytes -> null, empty data -> null);
 *  - Android Waveform.kt parity: normalizeAmplitudeSample
 *    (ln(1+a)/ln(1+32768), negatives clamp to 0) and resampleWave
 *    (empty -> zeros, identity, expansion and shrink interpolation).
 */
import { ContractAssert } from './ContractAssert';
import {
  buildMulawWav,
  mulawDecode,
  mulawEncode,
  normalizeAmplitudeSample,
  parseMulawWavWaveform,
  parseWavInfo,
  resampleWave
} from '../../main/ets/service/media/VoiceNoteWaveform';

export function runVoiceNoteWaveformContractTests(t: ContractAssert): void {
  voiceMulawCodec(t);
  voiceWavLayout(t);
  voiceWavParser(t);
  voiceWaveformExtraction(t);
  voiceAmplitudeNormalization(t);
  voiceWaveResampling(t);
}

function voiceMulawCodec(t: ContractAssert): void {
  // Universal g711.c golden vectors (bias-132 16-bit convention).
  t.equalNumber(0xFF, mulawEncode(0), 'mulaw encode of silence');
  t.equalNumber(0x80, mulawEncode(32767), 'mulaw encode of positive max');
  t.equalNumber(0x00, mulawEncode(-32768), 'mulaw encode of negative max');
  t.equalNumber(0, mulawDecode(0xFF), 'mulaw decode of 0xFF');
  t.equalNumber(-32124, mulawDecode(0x00), 'mulaw decode of 0x00');
  t.equalNumber(32124, mulawDecode(0x80), 'mulaw decode of 0x80');
  t.equalNumber(0, mulawDecode(0x7F), 'mulaw decode of 0x7F');
  t.equalNumber(0, mulawDecode(mulawEncode(0)), 'silence round trip');
  // Encode stays inside one byte for every tested extreme.
  for (let sample = -32768; sample <= 32767; sample += 4096) {
    const encoded: number = mulawEncode(sample);
    t.isTrue(encoded >= 0 && encoded <= 255, 'mulaw encode byte range');
    const decoded: number = mulawDecode(encoded);
    // mu-law quantization error stays inside one segment step (~1/64 of range).
    t.isTrue(Math.abs(decoded - sample) <= 1024,
      'mulaw round-trip error bound at ' + sample);
  }
}

function voiceWavLayout(t: ContractAssert): void {
  // Ten mu-law bytes -> a 54-byte WAV with the exact header layout.
  const payload: Uint8Array = new Uint8Array(10);
  for (let i: number = 0; i < payload.length; i++) {
    payload[i] = 0xFF ^ i;
  }
  const wav: Uint8Array = buildMulawWav(payload);
  t.equalNumber(54, wav.length, 'wav total length');
  t.equalString('RIFF', ascii4(wav, 0), 'wav RIFF magic');
  t.equalNumber(46, leU32(wav, 4), 'wav RIFF chunk size');
  t.equalString('WAVE', ascii4(wav, 8), 'wav WAVE magic');
  t.equalString('fmt ', ascii4(wav, 12), 'wav fmt chunk id');
  t.equalNumber(16, leU32(wav, 16), 'wav fmt chunk size');
  t.equalNumber(7, leU16(wav, 20), 'wav format tag 7 (mu-law)');
  t.equalNumber(1, leU16(wav, 22), 'wav mono channel count');
  t.equalNumber(8000, leU32(wav, 24), 'wav 8 kHz sample rate');
  t.equalNumber(8000, leU32(wav, 28), 'wav 8000 B/s byte rate');
  t.equalNumber(1, leU16(wav, 32), 'wav block align 1');
  t.equalNumber(8, leU16(wav, 34), 'wav 8 bits per sample');
  t.equalString('data', ascii4(wav, 36), 'wav data chunk id');
  t.equalNumber(10, leU32(wav, 40), 'wav data chunk size');
  for (let i: number = 0; i < 10; i++) {
    t.equalNumber(payload[i], wav[44 + i], 'wav payload byte ' + i);
  }
  // A 10-second note (80,000 samples) stays far below the
  // 120,064-byte private-media receive bound.
  const tenSeconds: Uint8Array = buildMulawWav(new Uint8Array(80000));
  t.isTrue(tenSeconds.length <= 120064,
    '10s mu-law note inside the mesh receive bound');
}

function voiceWavParser(t: ContractAssert): void {
  const payload: Uint8Array = new Uint8Array(16);
  for (let i: number = 0; i < payload.length; i++) {
    payload[i] = mulawEncode(i * 1000);
  }
  const wav: Uint8Array = buildMulawWav(payload);
  const info = parseWavInfo(wav);
  t.isNotNull(info, 'parse wav info');
  if (info !== null) {
    t.equalNumber(7, info.formatTag, 'parsed format tag');
    t.equalNumber(1, info.channels, 'parsed channels');
    t.equalNumber(8000, info.sampleRate, 'parsed sample rate');
    t.equalNumber(44, info.dataOffset, 'parsed data offset');
    t.equalNumber(16, info.dataLength, 'parsed data length');
    t.equalNumber(2, info.durationMs(), '16 mu-law bytes = 2 ms');
  }
  // Unknown chunks between fmt and data are skipped by size, odd-size
  // chunks include their pad byte (RIFF chunk-walking contract).
  const withList: Uint8Array = new Uint8Array(wav.length + 12);
  withList.set(wav.subarray(0, 36), 0);
  withList[36] = 0x4C;
  withList[37] = 0x49;
  withList[38] = 0x53;
  withList[39] = 0x54;
  withList[40] = 0x03;
  withList[41] = 0x00;
  withList[42] = 0x00;
  withList[43] = 0x00;
  withList[44] = 0x49;
  withList[45] = 0x4E;
  withList[46] = 0x46;
  withList[47] = 0x4F;
  withList[48] = 0x41;
  withList.set(wav.subarray(36), 48);
  const listed = parseWavInfo(withList);
  t.isNotNull(listed, 'parse wav with LIST chunk');
  if (listed !== null) {
    t.equalNumber(7, listed.formatTag, 'LIST wav format tag');
    t.equalNumber(44 + 12, listed.dataOffset, 'LIST wav data offset');
    t.equalNumber(16, listed.dataLength, 'LIST wav data length');
  }
  // Non-WAV bytes are rejected.
  t.isNull(parseWavInfo(new Uint8Array(64)), 'non-wav bytes rejected');
  t.isNull(parseWavInfo(wav.subarray(0, 20)), 'truncated wav rejected');
}

function voiceWaveformExtraction(t: ContractAssert): void {
  // First half silent (0xFF), second half loud: two bins split
  // at the midpoint, max-normalized so the loud bin is exactly 1.
  const samples: Uint8Array = new Uint8Array(800);
  for (let i: number = 0; i < samples.length; i++) {
    samples[i] = i < 400 ? mulawEncode(0) : mulawEncode(30000);
  }
  const wav: Uint8Array = buildMulawWav(samples);
  const bins = parseMulawWavWaveform(wav, 2);
  t.isNotNull(bins, 'waveform bins extracted');
  if (bins !== null) {
    t.equalNumber(2, bins.length, 'waveform bin count');
    t.equalNumber(0, bins[0], 'silent half stays zero');
    t.isTrue(bins[1] > 0.9 && bins[1] <= 1,
      'loud half normalized near 1 (got ' + bins[1] + ')');
  }
  // A single loud sample among silence still yields its own lit bin.
  const sparse: Uint8Array = new Uint8Array(80);
  for (let i: number = 0; i < sparse.length; i++) {
    sparse[i] = mulawEncode(0);
  }
  sparse[40] = mulawEncode(20000);
  const sparseBins = parseMulawWavWaveform(buildMulawWav(sparse), 4);
  t.isNotNull(sparseBins, 'sparse waveform extracted');
  if (sparseBins !== null) {
    t.equalNumber(0, sparseBins[0], 'sparse first quarter silent');
    t.equalNumber(1, sparseBins[2], 'sparse hit bin normalized to 1');
    t.equalNumber(0, sparseBins[3], 'sparse last quarter silent');
  }
  // Format gate: PCM (tag 1) and non-WAV bytes have no ArkTS decoder.
  const pcmWav: Uint8Array = buildMulawWav(new Uint8Array(64));
  pcmWav[20] = 1;
  pcmWav[21] = 0;
  t.isNull(parseMulawWavWaveform(pcmWav, 4), 'PCM wav rejected by waveform gate');
  t.isNull(parseMulawWavWaveform(new Uint8Array(128), 4),
    'non-wav bytes rejected by waveform gate');
  t.isNull(parseMulawWavWaveform(buildMulawWav(new Uint8Array(0)), 4),
    'empty data rejected');
  t.isNull(parseMulawWavWaveform(wav, 0), 'zero bins rejected');
}

function voiceAmplitudeNormalization(t: ContractAssert): void {
  t.equalNumber(0, normalizeAmplitudeSample(0), 'amplitude 0 normalized');
  t.equalNumber(1, normalizeAmplitudeSample(32768), 'amplitude 32768 normalized');
  t.equalNumber(0, normalizeAmplitudeSample(-1000), 'negative amplitude clamped');
  t.isTrue(normalizeAmplitudeSample(1000) > 0.6 && normalizeAmplitudeSample(1000) < 0.7,
    'amplitude 1000 ln-scaled (got ' + normalizeAmplitudeSample(1000) + ')');
  t.isTrue(normalizeAmplitudeSample(40000) <= 1,
    'over-range amplitude clamped to 1');
}

function voiceWaveResampling(t: ContractAssert): void {
  // Empty input -> all zeros of the requested size.
  const empty: number[] = resampleWave([], 3);
  t.equalNumber(3, empty.length, 'resample empty length');
  t.equalNumber(0, empty[0] + empty[1] + empty[2], 'resample empty zeros');
  t.equalNumber(0, resampleWave([], 0).length, 'resample empty zero target');
  // Identity when sizes match.
  const same: number[] = [0.1, 0.9, 0.5];
  const identity: number[] = resampleWave(same, 3);
  t.equalNumber(3, identity.length, 'resample identity length');
  t.equalNumber(0.1, identity[0], 'resample identity first');
  t.equalNumber(0.9, identity[1], 'resample identity middle');
  t.equalNumber(0.5, identity[2], 'resample identity last');
  // Shrink: [0, 1] onto 3 bins is linear interpolation.
  const expanded: number[] = resampleWave([0, 1], 3);
  t.equalNumber(0, expanded[0], 'resample expand first');
  t.equalNumber(0.5, expanded[1], 'resample expand midpoint');
  t.equalNumber(1, expanded[2], 'resample expand last');
  // Expand: uniform values stay uniform.
  const flat: number[] = resampleWave([0.25, 0.25, 0.25, 0.25], 2);
  t.equalNumber(0.25, flat[0], 'resample shrink flat first');
  t.equalNumber(0.25, flat[1], 'resample shrink flat last');
  // Single-bin target keeps the leading value.
  t.equalNumber(0.4, resampleWave([0.4, 0.8], 1)[0], 'resample single bin');
  // Values stay clamped inside [0,1].
  const clamped: number[] = resampleWave([0, 1, 0], 5);
  for (let i: number = 0; i < clamped.length; i++) {
    t.isTrue(clamped[i] >= 0 && clamped[i] <= 1, 'resample clamp bin ' + i);
  }
  // The 80 ms amplitude poll of a 10 s recording fills 120 bins exactly.
  t.equalNumber(120, resampleWave(new Array<number>(125).fill(0.5), 120).length,
    'recording history resampled to 120 bins');
}

function ascii4(bytes: Uint8Array, offset: number): string {
  let out: string = '';
  for (let i: number = 0; i < 4; i++) {
    out += String.fromCharCode(bytes[offset + i]);
  }
  return out;
}

function leU16(bytes: Uint8Array, offset: number): number {
  return bytes[offset] | (bytes[offset + 1] << 8);
}

function leU32(bytes: Uint8Array, offset: number): number {
  return (bytes[offset] | (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)) >>> 0;
}
