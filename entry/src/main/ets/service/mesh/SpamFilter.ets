/**
 * Application-layer spam filtering for public chat
 * (port of bitchat-android spam package: SpamFilter.kt, SpamFilterConfig.kt,
 * TokenBucketSchedule.kt, RepetitionDetector.kt, LinkCounter.kt, SpamTuning.kt).
 *
 * Each sender gets three token buckets (messages 6/10s, characters 1200/min,
 * links 2/min) evaluated on message time, plus three repetition checks: a
 * message that repeats itself internally, a near-copy of the sender's own
 * recent history, and a near-copy of what *other* senders posted recently.
 * Hidden messages never spend tokens, but they do enter the repetition
 * history so a spammer cannot cycle the same text. Verdicts are remembered
 * by message ID, so the same message arriving over BLE and Wi-Fi Aware is
 * judged once and counted once.
 *
 * Pure ArkTS (no device APIs) so the contract harness runs it on the host.
 */
import { BitchatMessage, BitchatMessageType } from '../../model/BitchatMessage';

export enum SpamVerdict {
  ALLOWED = 0,
  MESSAGE_RATE = 1,
  CHARACTER_RATE = 2,
  LINK_RATE = 3,
  REPEATED_MESSAGE = 4,
  REPEATED_ACROSS_USERS = 5,
  REPEATED_CHARACTERS = 6
}

/** True when the verdict means the message must be kept out of the chat. */
export function spamVerdictIsSpam(verdict: SpamVerdict): boolean {
  return verdict !== SpamVerdict.ALLOWED;
}

export class TokenBucketConfig {
  readonly capacity: number;
  readonly refillPerSecond: number;

  constructor(capacity: number, refillPerSecond: number) {
    this.capacity = capacity;
    this.refillPerSecond = refillPerSecond;
  }
}

export class RepetitionConfig {
  readonly minRepeatedCharactersLength: number;
  readonly repeatedCharactersThreshold: number;
  readonly minRepeatedMessageLength: number;
  readonly repeatedMessageSimilarity: number;
  readonly allowedRepeats: number;
  readonly crossUserAllowedRepeats: number;
  readonly crossUserMinLength: number;
  readonly crossUserHistorySize: number;
  readonly historySize: number;
  readonly historyWindowMs: number;
  readonly maxAnalyzedLength: number;
  readonly maxComparedLength: number;
  readonly maxAlignmentPeaks: number;
  readonly minPeakRun: number;
  readonly minSharedTrigrams: number;

  constructor(minRepeatedCharactersLength: number = 32,
    repeatedCharactersThreshold: number = 0.85,
    minRepeatedMessageLength: number = 10,
    repeatedMessageSimilarity: number = 0.8,
    allowedRepeats: number = 1,
    crossUserAllowedRepeats: number = 2,
    crossUserMinLength: number = 16,
    crossUserHistorySize: number = 200,
    historySize: number = 10,
    historyWindowMs: number = 10 * 60 * 1000,
    maxAnalyzedLength: number = 1000,
    maxComparedLength: number = 280,
    maxAlignmentPeaks: number = 3,
    minPeakRun: number = 3,
    minSharedTrigrams: number = 0.25) {
    this.minRepeatedCharactersLength = minRepeatedCharactersLength;
    this.repeatedCharactersThreshold = repeatedCharactersThreshold;
    this.minRepeatedMessageLength = minRepeatedMessageLength;
    this.repeatedMessageSimilarity = repeatedMessageSimilarity;
    this.allowedRepeats = allowedRepeats;
    this.crossUserAllowedRepeats = crossUserAllowedRepeats;
    this.crossUserMinLength = crossUserMinLength;
    this.crossUserHistorySize = crossUserHistorySize;
    this.historySize = historySize;
    this.historyWindowMs = historyWindowMs;
    this.maxAnalyzedLength = maxAnalyzedLength;
    this.maxComparedLength = maxComparedLength;
    this.maxAlignmentPeaks = maxAlignmentPeaks;
    this.minPeakRun = minPeakRun;
    this.minSharedTrigrams = minSharedTrigrams;
  }
}

export class SpamFilterConfig {
  readonly messageBucket: TokenBucketConfig;
  readonly characterBucket: TokenBucketConfig;
  readonly linkBucket: TokenBucketConfig;
  readonly repetition: RepetitionConfig;
  readonly maxBackdateMs: number;
  readonly maxTrackedSenders: number;
  readonly maxRememberedVerdicts: number;

  constructor(messageBucket: TokenBucketConfig = new TokenBucketConfig(6.0, 1.0 / 10.0),
    characterBucket: TokenBucketConfig = new TokenBucketConfig(1200.0, 1200.0 / 60.0),
    linkBucket: TokenBucketConfig = new TokenBucketConfig(2.0, 2.0 / 60.0),
    repetition: RepetitionConfig = new RepetitionConfig(),
    maxBackdateMs: number = 60 * 60 * 1000,
    maxTrackedSenders: number = 1000,
    maxRememberedVerdicts: number = 4000) {
    this.messageBucket = messageBucket;
    this.characterBucket = characterBucket;
    this.linkBucket = linkBucket;
    this.repetition = repetition;
    this.maxBackdateMs = maxBackdateMs;
    this.maxTrackedSenders = maxTrackedSenders;
    this.maxRememberedVerdicts = maxRememberedVerdicts;
  }

  static equals(a: SpamFilterConfig, b: SpamFilterConfig): boolean {
    if (a.messageBucket.capacity !== b.messageBucket.capacity ||
      a.messageBucket.refillPerSecond !== b.messageBucket.refillPerSecond ||
      a.characterBucket.capacity !== b.characterBucket.capacity ||
      a.characterBucket.refillPerSecond !== b.characterBucket.refillPerSecond ||
      a.linkBucket.capacity !== b.linkBucket.capacity ||
      a.linkBucket.refillPerSecond !== b.linkBucket.refillPerSecond ||
      a.maxBackdateMs !== b.maxBackdateMs ||
      a.maxTrackedSenders !== b.maxTrackedSenders ||
      a.maxRememberedVerdicts !== b.maxRememberedVerdicts) {
      return false;
    }
    const ra: RepetitionConfig = a.repetition;
    const rb: RepetitionConfig = b.repetition;
    return ra.minRepeatedCharactersLength === rb.minRepeatedCharactersLength &&
      ra.repeatedCharactersThreshold === rb.repeatedCharactersThreshold &&
      ra.minRepeatedMessageLength === rb.minRepeatedMessageLength &&
      ra.repeatedMessageSimilarity === rb.repeatedMessageSimilarity &&
      ra.allowedRepeats === rb.allowedRepeats &&
      ra.crossUserAllowedRepeats === rb.crossUserAllowedRepeats &&
      ra.crossUserMinLength === rb.crossUserMinLength &&
      ra.crossUserHistorySize === rb.crossUserHistorySize &&
      ra.historySize === rb.historySize &&
      ra.historyWindowMs === rb.historyWindowMs &&
      ra.maxAnalyzedLength === rb.maxAnalyzedLength &&
      ra.maxComparedLength === rb.maxComparedLength &&
      ra.maxAlignmentPeaks === rb.maxAlignmentPeaks &&
      ra.minPeakRun === rb.minPeakRun &&
      ra.minSharedTrigrams === rb.minSharedTrigrams;
  }
}

/**
 * The SpamFilterConfig knobs exposed in debug settings, in whole units that
 * suit sliders. DEFAULT matches the code defaults in SpamFilterConfig.
 */
export class SpamTuning {
  readonly messageBurst: number;
  readonly secondsPerMessage: number;
  readonly charactersPerMinute: number;
  readonly linksPerMinute: number;
  readonly allowedRepeats: number;
  readonly crossUserAllowedRepeats: number;
  readonly crossUserMinLength: number;
  readonly repeatSimilarityPercent: number;
  readonly repeatWindowMinutes: number;
  readonly selfMatchPercent: number;
  readonly selfMatchMinLength: number;

  constructor(messageBurst: number, secondsPerMessage: number, charactersPerMinute: number,
    linksPerMinute: number, allowedRepeats: number, crossUserAllowedRepeats: number,
    crossUserMinLength: number, repeatSimilarityPercent: number, repeatWindowMinutes: number,
    selfMatchPercent: number, selfMatchMinLength: number) {
    this.messageBurst = messageBurst;
    this.secondsPerMessage = secondsPerMessage;
    this.charactersPerMinute = charactersPerMinute;
    this.linksPerMinute = linksPerMinute;
    this.allowedRepeats = allowedRepeats;
    this.crossUserAllowedRepeats = crossUserAllowedRepeats;
    this.crossUserMinLength = crossUserMinLength;
    this.repeatSimilarityPercent = repeatSimilarityPercent;
    this.repeatWindowMinutes = repeatWindowMinutes;
    this.selfMatchPercent = selfMatchPercent;
    this.selfMatchMinLength = selfMatchMinLength;
  }

  toConfig(): SpamFilterConfig {
    const base: SpamFilterConfig = new SpamFilterConfig();
    const seconds: number = this.secondsPerMessage >= 1 ? this.secondsPerMessage : 1;
    const messageBucket: TokenBucketConfig = new TokenBucketConfig(this.messageBurst, 1.0 / seconds);
    const characterBucket: TokenBucketConfig =
      new TokenBucketConfig(this.charactersPerMinute, this.charactersPerMinute / 60.0);
    const linkBucket: TokenBucketConfig = new TokenBucketConfig(this.linksPerMinute, this.linksPerMinute / 60.0);
    const repetition: RepetitionConfig = new RepetitionConfig(
      this.selfMatchMinLength,
      this.selfMatchPercent / 100.0,
      base.repetition.minRepeatedMessageLength,
      this.repeatSimilarityPercent / 100.0,
      this.allowedRepeats,
      this.crossUserAllowedRepeats,
      this.crossUserMinLength,
      base.repetition.crossUserHistorySize,
      base.repetition.historySize,
      this.repeatWindowMinutes * 60 * 1000,
      base.repetition.maxAnalyzedLength,
      base.repetition.maxComparedLength,
      base.repetition.maxAlignmentPeaks,
      base.repetition.minPeakRun,
      base.repetition.minSharedTrigrams);
    return new SpamFilterConfig(messageBucket, characterBucket, linkBucket, repetition,
      base.maxBackdateMs, base.maxTrackedSenders, base.maxRememberedVerdicts);
  }

  static fromConfig(config: SpamFilterConfig): SpamTuning {
    return new SpamTuning(
      config.messageBucket.capacity,
      Math.round(1.0 / config.messageBucket.refillPerSecond),
      config.characterBucket.capacity,
      config.linkBucket.capacity,
      config.repetition.allowedRepeats,
      config.repetition.crossUserAllowedRepeats,
      config.repetition.crossUserMinLength,
      Math.round(config.repetition.repeatedMessageSimilarity * 100),
      Math.floor(config.repetition.historyWindowMs / 60000),
      Math.round(config.repetition.repeatedCharactersThreshold * 100),
      config.repetition.minRepeatedCharactersLength);
  }

  static readonly DEFAULT: SpamTuning = SpamTuning.fromConfig(new SpamFilterConfig());

  static equals(a: SpamTuning, b: SpamTuning): boolean {
    return a.messageBurst === b.messageBurst &&
      a.secondsPerMessage === b.secondsPerMessage &&
      a.charactersPerMinute === b.charactersPerMinute &&
      a.linksPerMinute === b.linksPerMinute &&
      a.allowedRepeats === b.allowedRepeats &&
      a.crossUserAllowedRepeats === b.crossUserAllowedRepeats &&
      a.crossUserMinLength === b.crossUserMinLength &&
      a.repeatSimilarityPercent === b.repeatSimilarityPercent &&
      a.repeatWindowMinutes === b.repeatWindowMinutes &&
      a.selfMatchPercent === b.selfMatchPercent &&
      a.selfMatchMinLength === b.selfMatchMinLength;
  }
}

/** Counts links the way the chat linkifies them (Android LinkCounter). */
export class LinkCounter {
  private static readonly LINK: RegExp = new RegExp(
    '(?<![\\w@.\\-])(?:https?://[^\\s<>]+|www\\.[^\\s<>]+|' +
    '[a-z0-9\\-]+(?:\\.[a-z0-9\\-]+)*\\.[a-z]{2,}(?:/[^\\s<>]*)?)(?![\\w@])', 'gi');

  static count(text: string): number {
    const matches: RegExpMatchArray | null = text.match(LinkCounter.LINK);
    if (matches === null) {
      return 0;
    }
    return matches.length;
  }
}

/** One diagonal of the cross-correlation: `b[j]` lined up under `a[j + shift]`. */
export class AlignmentPeak {
  readonly shift: number;
  readonly matches: number;

  constructor(shift: number, matches: number) {
    this.shift = shift;
    this.matches = matches;
  }
}

/** How two texts line up: the peaks used and the share of the longer text they cover. */
export class AlignmentResult {
  readonly peaks: AlignmentPeak[];
  readonly matches: number;
  readonly score: number;

  constructor(peaks: AlignmentPeak[], matches: number, score: number) {
    this.peaks = peaks;
    this.matches = matches;
    this.score = score;
  }
}

/**
 * Character autocorrelation measures for repeated-content spam
 * (port of Android RepetitionDetector). Text is compared as Unicode code
 * points after normalize, so case, spacing, look-alike letters, accents and
 * invisible characters don't hide a repeat.
 */
export class RepetitionDetector {
  private static readonly MARK_RANGES: number[][] = [
    [0x0300, 0x036F], [0x0483, 0x0489], [0x0591, 0x05BD], [0x05BF, 0x05BF], [0x05C1, 0x05C2],
    [0x05C4, 0x05C5], [0x05C7, 0x05C7], [0x0610, 0x061A], [0x064B, 0x065F], [0x0670, 0x0670],
    [0x06D6, 0x06DC], [0x06DF, 0x06E4], [0x06E7, 0x06E8], [0x06EA, 0x06ED], [0x0711, 0x0711],
    [0x0730, 0x074A], [0x07A6, 0x07B0], [0x07EB, 0x07F3], [0x0816, 0x0819], [0x081B, 0x0823],
    [0x0825, 0x0827], [0x0829, 0x082D], [0x0859, 0x085B], [0x08D3, 0x08E1], [0x08E3, 0x0903],
    [0x093A, 0x093C], [0x093E, 0x094F], [0x0951, 0x0957], [0x0962, 0x0963], [0x0981, 0x0981],
    [0x09BC, 0x09BC], [0x09BE, 0x09CD], [0x09D7, 0x09D7], [0x09E2, 0x09E3], [0x09FE, 0x09FE],
    [0x0A01, 0x0A02], [0x0A3C, 0x0A3C], [0x0A41, 0x0A51], [0x0A70, 0x0A71], [0x0A75, 0x0A75],
    [0x0A81, 0x0A82], [0x0ABC, 0x0ACD], [0x0AE2, 0x0AE3], [0x0AFA, 0x0AFF], [0x0B01, 0x0B01],
    [0x0B3C, 0x0B3C], [0x0B3E, 0x0B4F], [0x0B55, 0x0B57], [0x0B62, 0x0B63], [0x0B82, 0x0B82],
    [0x0BBE, 0x0BCD], [0x0BD7, 0x0BD7], [0x0C00, 0x0C04], [0x0C3E, 0x0C56], [0x0C62, 0x0C63],
    [0x0C81, 0x0C81], [0x0CBC, 0x0CBD], [0x0CBE, 0x0CCF], [0x0CE2, 0x0CE3], [0x0D00, 0x0D03],
    [0x0D3B, 0x0D3D], [0x0D3E, 0x0D4F], [0x0D62, 0x0D63], [0x0D81, 0x0D81], [0x0DCA, 0x0DCF],
    [0x0DD2, 0x0DDF], [0x0DF2, 0x0DF3], [0x0E31, 0x0E31], [0x0E34, 0x0E3A], [0x0E47, 0x0E4E],
    [0x0EB1, 0x0EB1], [0x0EB4, 0x0EBC], [0x0EC8, 0x0ECD], [0x0F18, 0x0F19], [0x0F35, 0x0F35],
    [0x0F37, 0x0F37], [0x0F39, 0x0F39], [0x0F3E, 0x0F3F], [0x0F71, 0x0F84], [0x0F86, 0x0F87],
    [0x0F8D, 0x0F97], [0x0F99, 0x0FBC], [0x0FC6, 0x0FC6], [0x102B, 0x103E], [0x1056, 0x1059],
    [0x105E, 0x1060], [0x1062, 0x1064], [0x1067, 0x106D], [0x1071, 0x1074], [0x1082, 0x108D],
    [0x108F, 0x108F], [0x109A, 0x109D], [0x135D, 0x135F], [0x1712, 0x1714], [0x1732, 0x1734],
    [0x1752, 0x1753], [0x1772, 0x1773], [0x17B4, 0x17D3], [0x17DD, 0x17DD], [0x180B, 0x180D],
    [0x180F, 0x180F], [0x1885, 0x1886], [0x18A9, 0x18A9], [0x1920, 0x193B], [0x1A17, 0x1A1B],
    [0x1A55, 0x1A5E], [0x1A60, 0x1A7C], [0x1A7F, 0x1A89], [0x1A8F, 0x1A99], [0x1AB0, 0x1AFF],
    [0x1B00, 0x1B04], [0x1B34, 0x1B44], [0x1B6B, 0x1B73], [0x1B80, 0x1B82], [0x1BA1, 0x1BAD],
    [0x1BE6, 0x1BF3], [0x1C24, 0x1C37], [0x1CD0, 0x1CD2], [0x1CD4, 0x1CE8], [0x1CED, 0x1CED],
    [0x1CF2, 0x1CF4], [0x1CF7, 0x1CF9], [0x1DC0, 0x1DFF], [0x20D0, 0x20F0], [0x2CEF, 0x2CF1],
    [0x2D7F, 0x2D7F], [0x2DE0, 0x2DFF], [0x302A, 0x302F], [0x3099, 0x309A], [0xA66F, 0xA672],
    [0xA674, 0xA67D], [0xA69E, 0xA69F], [0xA6F0, 0xA6F1], [0xA802, 0xA802], [0xA806, 0xA806],
    [0xA80B, 0xA80B], [0xA823, 0xA827], [0xA880, 0xA881], [0xA8B4, 0xA8C5], [0xA8E0, 0xA8F1],
    [0xA8FF, 0xA8FF], [0xA926, 0xA92D], [0xA947, 0xA953], [0xA980, 0xA983], [0xA9B3, 0xA9C0],
    [0xA9E5, 0xA9E5], [0xAA29, 0xAA36], [0xAA43, 0xAA43], [0xAA4C, 0xAA4D], [0xAA7B, 0xAA7D],
    [0xAAB0, 0xAAB0], [0xAAB2, 0xAAB4], [0xAAB7, 0xAAB8], [0xAABE, 0xAABF], [0xAAC1, 0xAAC1],
    [0xAAEB, 0xAAEF], [0xAAF5, 0xAAF6], [0xABE3, 0xABEA], [0xABEC, 0xABED], [0xFB1E, 0xFB1E],
    [0xFE00, 0xFE0F], [0xFE20, 0xFE2F]
  ];

  private static readonly FORMAT_RANGES: number[][] = [
    [0x00AD, 0x00AD], [0x0600, 0x0605], [0x061C, 0x061C], [0x06DD, 0x06DD], [0x070F, 0x070F],
    [0x08E2, 0x08E2], [0x180E, 0x180E], [0x200B, 0x200F], [0x202A, 0x202E], [0x2060, 0x2064],
    [0x2066, 0x206F], [0xFEFF, 0xFEFF], [0xFFF9, 0xFFFB], [0x110BD, 0x110BD], [0x110CD, 0x110CD],
    [0x13430, 0x13438], [0x1BCA0, 0x1BCA3], [0x1D173, 0x1D17A], [0xE0001, 0xE0001], [0xE0020, 0xE007F]
  ];

  /**
   * Folds a message to what a reader sees, for comparison only (never for
   * display): NFKD turns fullwidth and math-styled letters into plain ones
   * and splits off accents, then combining marks and invisible characters
   * are dropped, whitespace runs become one space and the result is
   * lowercased and capped to maxLength code points.
   */
  static normalize(text: string, maxLength: number): number[] {
    const head: string = text.length > maxLength * 4 ? text.substring(0, maxLength * 4) : text;
    const decomposed: string = head.normalize('NFKD');
    const limit: number = Math.min(maxLength, decomposed.length);
    const out: number[] = [];
    let pendingSpace: boolean = false;
    let offset: number = 0;
    while (offset < decomposed.length && out.length < limit) {
      const point: number = RepetitionDetector.pointAt(decomposed, offset);
      offset += point > 0xFFFF ? 2 : 1;
      if (RepetitionDetector.isMarkPoint(point) || RepetitionDetector.isInvisiblePoint(point)) {
        continue;
      }
      if (RepetitionDetector.isWhitespacePoint(point)) {
        pendingSpace = out.length > 0;
        continue;
      }
      if (pendingSpace && out.length < limit - 1) {
        out.push(32);
      }
      pendingSpace = false;
      out.push(RepetitionDetector.lowerPoint(point));
    }
    return out;
  }

  /**
   * Highest autocorrelation of text with itself over shifts 1..n/2: the
   * fraction of overlapping positions where text[i] == text[i + lag].
   */
  static selfSimilarity(text: number[]): number {
    const n: number = text.length;
    let best: number = 0;
    for (let lag: number = 1; lag <= Math.floor(n / 2); lag++) {
      const overlap: number = n - lag;
      let matches: number = 0;
      for (let i: number = 0; i < overlap; i++) {
        if (text[i] === text[i + lag]) {
          matches += 1;
        }
      }
      const score: number = matches / overlap;
      if (score > best) {
        best = score;
      }
    }
    return best;
  }

  static crossSimilarity(a: number[], b: number[], maxPeaks: number, minRun: number): number {
    return RepetitionDetector.align(a, b, maxPeaks, minRun).score;
  }

  /**
   * Cross-correlation of two texts that tolerates small edits. The first
   * peak is the classic correlation maximum; up to maxPeaks - 1 further
   * peaks add matches from other shifts, counting only runs of at least
   * minRun consecutive characters, and no character of either text is used
   * twice. The score is the matched characters over the longer length.
   */
  static align(a: number[], b: number[], maxPeaks: number, minRun: number): AlignmentResult {
    if (a.length === 0 || b.length === 0) {
      return new AlignmentResult([], 0, 0);
    }
    const usedA: boolean[] = [];
    const usedB: boolean[] = [];
    for (let i: number = 0; i < a.length; i++) {
      usedA.push(false);
    }
    for (let i: number = 0; i < b.length; i++) {
      usedB.push(false);
    }
    const peaks: AlignmentPeak[] = [];
    let total: number = 0;
    while (peaks.length < maxPeaks) {
      const run: number = peaks.length === 0 ? 1 : minRun;
      let bestGain: number = 0;
      let bestShift: number = 0;
      for (let shift: number = -(b.length - 1); shift < a.length; shift++) {
        const from: number = Math.max(0, -shift);
        const to: number = Math.min(b.length, a.length - shift);
        if (to - from <= bestGain) {
          continue;
        }
        const gain: number = RepetitionDetector.runMatches(a, b, shift, from, to, usedA, usedB, run, false);
        if (gain > bestGain) {
          bestGain = gain;
          bestShift = shift;
        }
      }
      if (bestGain < run) {
        break;
      }
      const from: number = Math.max(0, -bestShift);
      const to: number = Math.min(b.length, a.length - bestShift);
      RepetitionDetector.runMatches(a, b, bestShift, from, to, usedA, usedB, run, true);
      peaks.push(new AlignmentPeak(bestShift, bestGain));
      total += bestGain;
    }
    return new AlignmentResult(peaks, total, total / Math.max(a.length, b.length));
  }

  /** Unused matches at shift that sit in runs of at least minRun; mark claims them. */
  private static runMatches(a: number[], b: number[], shift: number, from: number, to: number,
    usedA: boolean[], usedB: boolean[], minRun: number, mark: boolean): number {
    let gain: number = 0;
    let runStart: number = -1;
    for (let j: number = from; j <= to; j++) {
      const hit: boolean = j < to && !usedB[j] && !usedA[j + shift] && a[j + shift] === b[j];
      if (hit) {
        if (runStart < 0) {
          runStart = j;
        }
      } else if (runStart >= 0) {
        const length: number = j - runStart;
        if (length >= minRun) {
          gain += length;
          if (mark) {
            for (let k: number = runStart; k < j; k++) {
              usedB[k] = true;
              usedA[k + shift] = true;
            }
          }
        }
        runStart = -1;
      }
    }
    return gain;
  }

  /** Distinct character trigrams as sorted hashes, for a cheap pre-check before align. */
  static trigrams(text: number[]): number[] {
    if (text.length < 3) {
      return [];
    }
    const seen: Set<number> = new Set();
    for (let i: number = 0; i + 2 < text.length; i++) {
      seen.add((text[i] * 31 + text[i + 1]) * 31 + text[i + 2]);
    }
    const out: number[] = [];
    for (const value of seen) {
      out.push(value);
    }
    out.sort((x: number, y: number): number => x - y);
    return out;
  }

  /**
   * Shared trigrams over the larger trigram set. Near-copies share most of
   * theirs, unrelated texts few, so pairs below a low bar can skip the
   * quadratic align. Texts too short to have trigrams always pass.
   */
  static trigramOverlap(a: number[], b: number[]): number {
    if (a.length === 0 || b.length === 0) {
      return 1.0;
    }
    let i: number = 0;
    let j: number = 0;
    let shared: number = 0;
    while (i < a.length && j < b.length) {
      if (a[i] === b[j]) {
        shared += 1;
        i += 1;
        j += 1;
      } else if (a[i] < b[j]) {
        i += 1;
      } else {
        j += 1;
      }
    }
    return shared / Math.max(a.length, b.length);
  }

  /** codePointAt with the loop-guard-verified offset narrowed to a number. */
  private static pointAt(text: string, offset: number): number {
    const point: number | undefined = text.codePointAt(offset);
    return point === undefined ? 0 : point;
  }

  private static lowerPoint(point: number): number {
    if (point >= 65 && point <= 90) {
      return point + 32;
    }
    const lowered: string = String.fromCodePoint(point).toLowerCase();
    if (lowered.length <= 2) {
      const first: number = RepetitionDetector.pointAt(lowered, 0);
      const width: number = first > 0xFFFF ? 2 : 1;
      if (width === lowered.length) {
        return first;
      }
    }
    return point;
  }

  private static isWhitespacePoint(point: number): boolean {
    if (point === 0x20 || (point >= 0x09 && point <= 0x0D) || (point >= 0x1C && point <= 0x1F)) {
      return true;
    }
    if (point === 0x85 || point === 0xA0 || point === 0x1680) {
      return true;
    }
    if (point >= 0x2000 && point <= 0x200A) {
      return true;
    }
    return point === 0x2028 || point === 0x2029 || point === 0x202F || point === 0x205F || point === 0x3000;
  }

  private static isMarkPoint(point: number): boolean {
    for (let i: number = 0; i < RepetitionDetector.MARK_RANGES.length; i++) {
      if (point >= RepetitionDetector.MARK_RANGES[i][0] && point <= RepetitionDetector.MARK_RANGES[i][1]) {
        return true;
      }
    }
    return false;
  }

  private static isInvisiblePoint(point: number): boolean {
    for (let i: number = 0; i < RepetitionDetector.FORMAT_RANGES.length; i++) {
      if (point >= RepetitionDetector.FORMAT_RANGES[i][0] && point <= RepetitionDetector.FORMAT_RANGES[i][1]) {
        return true;
      }
    }
    return (point <= 0x1F || (point >= 0x7F && point <= 0x9F)) &&
      !RepetitionDetector.isWhitespacePoint(point);
  }
}

/** A message prepared for comparison: its leading characters and their trigrams. */
class Fingerprint {
  readonly timeMs: number;
  readonly text: number[];
  readonly trigrams: number[];

  constructor(timeMs: number, text: number[], trigrams: number[]) {
    this.timeMs = timeMs;
    this.text = text;
    this.trigrams = trigrams;
  }
}

class SharedTextEntry {
  readonly senderKey: string;
  readonly fingerprint: Fingerprint;

  constructor(senderKey: string, fingerprint: Fingerprint) {
    this.senderKey = senderKey;
    this.fingerprint = fingerprint;
  }
}

class SenderState {
  readonly rate: TokenBucketSchedule;
  readonly history: Fingerprint[] = [];

  constructor(config: SpamFilterConfig) {
    this.rate = new TokenBucketSchedule(
      [config.messageBucket, config.characterBucket, config.linkBucket]);
  }
}

class ScheduleEntry {
  readonly timeMs: number;
  readonly costs: number[];

  constructor(timeMs: number, costs: number[]) {
    this.timeMs = timeMs;
    this.costs = costs;
  }
}

/**
 * A set of token buckets for one sender, evaluated on message time instead
 * of arrival order (port of Android TokenBucketSchedule).
 *
 * Relay backfill and mesh sync hand over a sender's recent history in one
 * burst, often newest first, so a plain arrival-time bucket would hide an
 * ordinary conversation. Instead each admitted message stays on a timeline,
 * and a candidate is admitted only if replaying every bucket over the
 * timeline with the candidate inserted never runs dry. Rejected messages
 * cost nothing. Entries older than the backdate window are folded into a
 * checkpoint, and nothing can be inserted before the checkpoint.
 */
export class TokenBucketSchedule {
  private readonly buckets: TokenBucketConfig[];
  private entries: ScheduleEntry[] = [];
  private checkpointMs: number | null = null;
  private readonly checkpointTokens: number[];

  constructor(buckets: TokenBucketConfig[]) {
    this.buckets = buckets;
    this.checkpointTokens = [];
    for (let i: number = 0; i < buckets.length; i++) {
      this.checkpointTokens.push(buckets[i].capacity);
    }
  }

  /**
   * Admits and records the message when every bucket can pay costs at
   * timeMs. Returns -1 on success, otherwise the index of the first bucket
   * that ran dry.
   */
  tryAdmit(timeMs: number, costs: number[]): number {
    const time: number = this.checkpointMs !== null ? Math.max(this.checkpointMs, timeMs) : timeMs;
    let insertAt: number = this.entries.length;
    while (insertAt > 0 && this.entries[insertAt - 1].timeMs > time) {
      insertAt -= 1;
    }
    const candidate: ScheduleEntry = new ScheduleEntry(time, costs);
    const tokens: number[] = this.checkpointTokens.slice(0);
    let lastMs: number | null = this.checkpointMs;
    for (let i: number = 0; i <= this.entries.length; i++) {
      let entry: ScheduleEntry;
      if (i < insertAt) {
        entry = this.entries[i];
      } else if (i === insertAt) {
        entry = candidate;
      } else {
        entry = this.entries[i - 1];
      }
      this.refill(tokens, lastMs, entry.timeMs);
      lastMs = entry.timeMs;
      for (let b: number = 0; b < this.buckets.length; b++) {
        tokens[b] -= entry.costs[b];
        if (tokens[b] < -1e-9) {
          return b;
        }
      }
    }
    this.entries.splice(insertAt, 0, candidate);
    return -1;
  }

  /** Folds entries before cutoffMs into the checkpoint. */
  prune(cutoffMs: number): void {
    let folded: number = 0;
    while (folded < this.entries.length && this.entries[folded].timeMs < cutoffMs) {
      const entry: ScheduleEntry = this.entries[folded];
      this.refill(this.checkpointTokens, this.checkpointMs, entry.timeMs);
      for (let b: number = 0; b < this.buckets.length; b++) {
        this.checkpointTokens[b] -= entry.costs[b];
      }
      this.checkpointMs = entry.timeMs;
      folded += 1;
    }
    if (folded > 0) {
      this.entries.splice(0, folded);
    }
  }

  private refill(tokens: number[], fromMs: number | null, toMs: number): void {
    if (fromMs === null || toMs <= fromMs) {
      return;
    }
    const seconds: number = (toMs - fromMs) / 1000.0;
    for (let b: number = 0; b < this.buckets.length; b++) {
      tokens[b] = Math.min(this.buckets[b].capacity, tokens[b] + seconds * this.buckets[b].refillPerSecond);
    }
  }
}

/**
 * Decides whether an incoming public message should be hidden
 * (port of Android SpamFilter).
 */
export class SpamFilter {
  private static readonly MAX_FLAGGED: number = 500;

  enabled: boolean = true;
  debugBypass: boolean = false;

  private configValue: SpamFilterConfig;
  private readonly clock: () => number;
  private readonly senders: Map<string, SenderState> = new Map();
  private recentTexts: SharedTextEntry[] = [];
  private readonly verdicts: Map<string, SpamVerdict> = new Map();
  private readonly flagged: Map<string, SpamVerdict> = new Map();

  /** Process-wide filter shared by every transport and geohash handler. */
  static readonly shared: SpamFilter = new SpamFilter();

  constructor(config: SpamFilterConfig | null = null, clock: (() => number) | null = null) {
    this.configValue = config === null ? new SpamFilterConfig() : config;
    this.clock = clock === null ? (): number => Date.now() : clock;
  }

  /** Returns true when message must be kept out of the chat. With debugBypass
   * on, spam is let through and recorded in the flagged verdicts instead. */
  shouldHide(message: BitchatMessage, senderKey: string): boolean {
    const verdict: SpamVerdict = this.checkMessage(message, senderKey);
    if (verdict === SpamVerdict.ALLOWED) {
      return false;
    }
    if (!this.debugBypass) {
      return true;
    }
    const existing: SpamVerdict | undefined = this.flagged.get(message.id);
    if (existing !== verdict) {
      this.flagged.set(message.id, verdict);
      while (this.flagged.size > SpamFilter.MAX_FLAGGED) {
        this.forgetOldestFlagged();
      }
    }
    return false;
  }

  /** Checks a received message; senderKey must identify the author stably within a transport. */
  checkMessage(message: BitchatMessage, senderKey: string): SpamVerdict {
    return this.check(senderKey, message.id, message.content, message.timestamp,
      message.type === BitchatMessageType.MESSAGE);
  }

  check(senderKey: string, messageId: string, content: string, timestampMs: number,
    isText: boolean = true): SpamVerdict {
    if (!this.enabled) {
      return SpamVerdict.ALLOWED;
    }
    const cached: SpamVerdict | undefined = this.verdicts.get(messageId);
    if (cached !== undefined) {
      return cached;
    }
    const now: number = this.clock();
    const oldestTrusted: number = now - this.configValue.maxBackdateMs;
    let time: number = timestampMs;
    if (time < oldestTrusted) {
      time = oldestTrusted;
    }
    if (time > now) {
      time = now;
    }
    const state: SenderState = this.getSenderState(senderKey);
    state.rate.prune(oldestTrusted);

    const repetition: RepetitionConfig = this.configValue.repetition;
    const text: number[] | null = isText
      ? RepetitionDetector.normalize(content, repetition.maxAnalyzedLength) : null;
    const fingerprint: Fingerprint | null = text === null ? null : this.buildFingerprint(text, time);
    let verdict: SpamVerdict;
    if (text !== null && fingerprint !== null && this.hasRepeatedCharacters(text)) {
      verdict = SpamVerdict.REPEATED_CHARACTERS;
    } else if (text !== null && fingerprint !== null && this.repeatsHistory(state, text.length, fingerprint)) {
      verdict = SpamVerdict.REPEATED_MESSAGE;
    } else if (text !== null && fingerprint !== null && this.repeatsOtherSenders(senderKey, text.length, fingerprint)) {
      verdict = SpamVerdict.REPEATED_ACROSS_USERS;
    } else {
      verdict = this.admitRate(state, content, time, isText);
    }

    if (text !== null && fingerprint !== null) {
      state.history.push(fingerprint);
      while (state.history.length > repetition.historySize) {
        state.history.shift();
      }
      if (text.length >= repetition.crossUserMinLength) {
        this.recentTexts.push(new SharedTextEntry(senderKey, fingerprint));
        while (this.recentTexts.length > repetition.crossUserHistorySize) {
          this.recentTexts.shift();
        }
      }
    }
    this.verdicts.set(messageId, verdict);
    while (this.verdicts.size > this.configValue.maxRememberedVerdicts) {
      this.forgetOldestVerdict();
    }
    return verdict;
  }

  /** Changing the limits forgets every sender, so new budgets start full. */
  setConfig(config: SpamFilterConfig): void {
    this.configValue = config;
    this.senders.clear();
    this.verdicts.clear();
    this.recentTexts = [];
  }

  /** Forgets all senders, e.g. when the filter is toggled or the app is wiped. */
  reset(): void {
    this.senders.clear();
    this.verdicts.clear();
    this.recentTexts = [];
    this.flagged.clear();
  }

  /** Verdict of a spam message shown because of debugBypass, or null. */
  getFlaggedVerdict(messageId: string): SpamVerdict | null {
    const verdict: SpamVerdict | undefined = this.flagged.get(messageId);
    return verdict === undefined ? null : verdict;
  }

  flaggedCount(): number {
    return this.flagged.size;
  }

  private getSenderState(senderKey: string): SenderState {
    const existing: SenderState | undefined = this.senders.get(senderKey);
    if (existing !== undefined) {
      this.senders.delete(senderKey);
      this.senders.set(senderKey, existing);
      return existing;
    }
    const created: SenderState = new SenderState(this.configValue);
    this.senders.set(senderKey, created);
    while (this.senders.size > this.configValue.maxTrackedSenders) {
      this.forgetLeastRecentlyUsedSender();
    }
    return created;
  }

  private forgetLeastRecentlyUsedSender(): void {
    for (const key of this.senders.keys()) {
      this.senders.delete(key);
      return;
    }
  }

  private forgetOldestVerdict(): void {
    for (const key of this.verdicts.keys()) {
      this.verdicts.delete(key);
      return;
    }
  }

  private forgetOldestFlagged(): void {
    for (const key of this.flagged.keys()) {
      this.flagged.delete(key);
      return;
    }
  }

  private hasRepeatedCharacters(text: number[]): boolean {
    const repetition: RepetitionConfig = this.configValue.repetition;
    return text.length >= repetition.minRepeatedCharactersLength &&
      RepetitionDetector.selfSimilarity(text) >= repetition.repeatedCharactersThreshold;
  }

  private buildFingerprint(text: number[], timeMs: number): Fingerprint {
    const max: number = this.configValue.repetition.maxComparedLength;
    const compared: number[] = text.length > max ? text.slice(0, max) : text;
    return new Fingerprint(timeMs, compared, RepetitionDetector.trigrams(compared));
  }

  private repeatsHistory(state: SenderState, length: number, message: Fingerprint): boolean {
    const repetition: RepetitionConfig = this.configValue.repetition;
    if (length < repetition.minRepeatedMessageLength) {
      return false;
    }
    let copies: number = 0;
    for (let i: number = 0; i < state.history.length; i++) {
      if (this.isNearCopy(state.history[i], message)) {
        copies += 1;
      }
    }
    return copies > repetition.allowedRepeats;
  }

  private repeatsOtherSenders(senderKey: string, length: number, message: Fingerprint): boolean {
    const repetition: RepetitionConfig = this.configValue.repetition;
    if (length < repetition.crossUserMinLength) {
      return false;
    }
    let copies: number = 0;
    for (let i: number = 0; i < this.recentTexts.length; i++) {
      const entry: SharedTextEntry = this.recentTexts[i];
      if (entry.senderKey === senderKey || !this.isNearCopy(entry.fingerprint, message)) {
        continue;
      }
      copies += 1;
      if (copies > repetition.crossUserAllowedRepeats) {
        return true;
      }
    }
    return false;
  }

  private isNearCopy(earlier: Fingerprint, message: Fingerprint): boolean {
    const repetition: RepetitionConfig = this.configValue.repetition;
    return Math.abs(earlier.timeMs - message.timeMs) <= repetition.historyWindowMs &&
      this.lengthsCanMatch(earlier.text.length, message.text.length) &&
      RepetitionDetector.trigramOverlap(earlier.trigrams, message.trigrams) >= repetition.minSharedTrigrams &&
      RepetitionDetector.crossSimilarity(earlier.text, message.text,
        repetition.maxAlignmentPeaks, repetition.minPeakRun) >= repetition.repeatedMessageSimilarity;
  }

  // Cross-similarity is bounded by shorter/longer, so skip pairs that can never reach it.
  private lengthsCanMatch(a: number, b: number): boolean {
    return Math.min(a, b) / Math.max(a, b) >= this.configValue.repetition.repeatedMessageSimilarity;
  }

  private admitRate(state: SenderState, content: string, timeMs: number, isText: boolean): SpamVerdict {
    const characters: number = isText ? SpamFilter.codePointCount(content) : 0;
    const links: number = isText ? LinkCounter.count(content) : 0;
    const result: number = state.rate.tryAdmit(timeMs, [1, characters, links]);
    if (result === -1) {
      return SpamVerdict.ALLOWED;
    }
    if (result === 0) {
      return SpamVerdict.MESSAGE_RATE;
    }
    if (result === 1) {
      return SpamVerdict.CHARACTER_RATE;
    }
    return SpamVerdict.LINK_RATE;
  }

  /** codePointAt with the loop-guard-verified offset narrowed to a number. */
  private static pointAt(text: string, offset: number): number {
    const point: number | undefined = text.codePointAt(offset);
    return point === undefined ? 0 : point;
  }

  private static codePointCount(text: string): number {
    let count: number = 0;
    let offset: number = 0;
    while (offset < text.length) {
      offset += SpamFilter.pointAt(text, offset) > 0xFFFF ? 2 : 1;
      count += 1;
    }
    return count;
  }

  /**
   * True for notices this device generated itself, such as "X favorited
   * you". Every message read off the wire carries the sender's peer ID;
   * only local notices have none.
   */
  static isLocalNotice(message: BitchatMessage): boolean {
    return message.senderPeerId === null && message.sender === 'system';
  }

  /** Key for public mesh and mesh channel messages. */
  static meshSenderKey(message: BitchatMessage): string {
    return 'mesh:' + (message.senderPeerId === null ? message.sender : message.senderPeerId);
  }

  /** Key for geohash messages, by the sender's per-geohash Nostr pubkey. */
  static nostrSenderKey(pubkeyHex: string): string {
    return 'nostr:' + pubkeyHex.toLowerCase();
  }
}
