/**
 * Contract tests for the US14 PTT interaction policy (T070):
 * - the 220 ms hold threshold (stray-tap guard, Android
 *   VoiceInputComponents.kt HoldToRecordMs parity),
 * - the 600 ms minimum capture (spec US14 "最短 600ms"; a release before
 *   it discards the capture instead of sending),
 * - the 10 s auto-stop cap,
 * - the receive-side loudness proxy (avg AAC access-unit bytes mapped
 *   onto [0,1] against the 16 kbps reference, clamped at both ends).
 */
import { ContractAssert } from './ContractAssert';
import { LIVE_FRAME_REFERENCE_BYTES, liveFrameAmplitudeNorm,
  PTT_HOLD_THRESHOLD_MS, PTT_MAX_CAPTURE_MS, PTT_MIN_CAPTURE_MS,
  PttReleaseKind, pttAutoStopReached, pttHoldReached,
  pttReleaseKind } from '../../main/ets/service/livevoice/PttPolicy';

export function runPttPolicyContractTests(t: ContractAssert): void {
  testHoldThreshold(t);
  testReleaseKind(t);
  testAutoStop(t);
  testAmplitudeProxy(t);
}

function testHoldThreshold(t: ContractAssert): void {
  t.equalNumber(220, PTT_HOLD_THRESHOLD_MS,
    'hold threshold must stay at the Android HoldToRecordMs (220 ms)');
  t.isFalse(pttHoldReached(0), 'an instant tap must not arm a capture');
  t.isFalse(pttHoldReached(219), 'one ms under the threshold must not arm');
  t.isTrue(pttHoldReached(220), 'exactly 220 ms held arms the capture');
  t.isTrue(pttHoldReached(2000), 'a long hold arms the capture');
}

function testReleaseKind(t: ContractAssert): void {
  t.equalNumber(600, PTT_MIN_CAPTURE_MS,
    'minimum capture must stay at the spec US14 600 ms');
  t.equalNumber(PttReleaseKind.TOO_SHORT, pttReleaseKind(0),
    'an empty capture is too short');
  t.equalNumber(PttReleaseKind.TOO_SHORT, pttReleaseKind(599),
    '599 ms is under the minimum: discard');
  t.equalNumber(PttReleaseKind.SEND, pttReleaseKind(600),
    '600 ms meets the minimum: send');
  t.equalNumber(PttReleaseKind.SEND, pttReleaseKind(9500),
    'a long capture sends');
}

function testAutoStop(t: ContractAssert): void {
  t.equalNumber(10000, PTT_MAX_CAPTURE_MS, '10 s auto-stop cap');
  t.isFalse(pttAutoStopReached(9999), 'one ms under the cap keeps capturing');
  t.isTrue(pttAutoStopReached(10000), 'exactly 10 s auto-stops');
  t.isTrue(pttAutoStopReached(60000), 'past the cap auto-stops');
  t.isFalse(pttAutoStopReached(0), 'a fresh capture does not auto-stop');
}

function testAmplitudeProxy(t: ContractAssert): void {
  t.equalNumber(128, LIVE_FRAME_REFERENCE_BYTES,
    'AAC-LC 16 kHz 16 kbps reference access unit is 128 bytes');
  t.equalNumber(0, liveFrameAmplitudeNorm(0), 'no bytes means silence');
  t.equalNumber(0, liveFrameAmplitudeNorm(-5), 'negative input clamps to 0');
  t.equalNumber(0.25, liveFrameAmplitudeNorm(64),
    'half the reference maps to 0.25');
  t.equalNumber(0.5, liveFrameAmplitudeNorm(128),
    'the reference bit-rate maps to 0.5');
  t.equalNumber(1, liveFrameAmplitudeNorm(256),
    'twice the reference saturates at 1');
  t.equalNumber(1, liveFrameAmplitudeNorm(1024),
    'loud speech clamps at 1');
}
