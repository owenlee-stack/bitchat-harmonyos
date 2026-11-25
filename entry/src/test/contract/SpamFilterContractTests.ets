/**
 * Port of bitchat-android SpamFilterTest.kt: the token-bucket admission
 * semantics (burst/refill/backfill replay/clamping), the repetition
 * detectors (self-similarity, own-history, cross-user, disguises), the link
 * counter, the tuning/config roundtrip, and the debug-bypass flagging.
 *
 * The Android test drives the filter with an injected clock; here the same
 * fake clock is injected so the whole suite runs on the host contract
 * harness. Timings and expected verdict sequences mirror the Android test
 * exactly.
 */
import { ContractAssert } from './ContractAssert';
import {
  SpamFilter,
  SpamVerdict,
  spamVerdictIsSpam,
  SpamFilterConfig,
  SpamTuning,
  TokenBucketConfig,
  RepetitionDetector,
  AlignmentResult,
  LinkCounter
} from '../../main/ets/service/mesh/SpamFilter';
import { BitchatMessage } from '../../main/ets/model/BitchatMessage';

/** Deterministic PRNG standing in for Kotlin Random(seed). */
class SeededRandom {
  private state: number;

  constructor(seed: number) {
    this.state = seed >>> 0;
  }

  nextInt(bound: number): number {
    this.state = (this.state + 0x6D2B79F5) >>> 0;
    let z: number = this.state;
    z = Math.imul(z ^ (z >>> 15), z | 1);
    z ^= z + Math.imul(z ^ (z >>> 7), z | 61);
    return ((z ^ (z >>> 14)) >>> 0) % bound;
  }
}

/** Fake clock + send() helper mirroring the Android test fixture. */
class FilterHarness {
  private now: number = 1000000000;
  private nextId: number = 0;
  private readonly random: SeededRandom = new SeededRandom(7);
  readonly filter: SpamFilter;

  constructor() {
    this.filter = new SpamFilter(null, (): number => this.now);
  }

  /** Unrelated synthetic words, so only the rule under test can fire. */
  prose(length: number = 40): string {
    let out: string = '';
    while (out.length < length) {
      if (out.length > 0) {
        out += ' ';
      }
      const wordLength: number = 2 + this.random.nextInt(6);
      for (let i: number = 0; i < wordLength; i++) {
        out += String.fromCharCode(97 + this.random.nextInt(26));
      }
    }
    return out.substring(0, length);
  }

  randomLetter(): string {
    return String.fromCharCode(97 + this.random.nextInt(26));
  }

  send(content: string | null = null, sender: string = 'alice',
    timestampMs: number | null = null, id: string | null = null): SpamVerdict {
    const actualContent: string = content === null ? this.prose() : content;
    const actualTime: number = timestampMs === null ? this.now : timestampMs;
    if (id === null) {
      const verdict: SpamVerdict = this.filter.check(sender, 'm' + this.nextId, actualContent, actualTime);
      this.nextId += 1;
      return verdict;
    }
    return this.filter.check(sender, id, actualContent, actualTime);
  }

  advanceSeconds(seconds: number): void {
    this.now += seconds * 1000;
  }

  getNow(): number {
    return this.now;
  }
}

/** A disguise case: the same text a reader sees, written to defeat plain comparison. */
class DisguiseCase {
  readonly label: string;
  readonly text: string;

  constructor(label: string, text: string) {
    this.label = label;
    this.text = text;
  }
}

function repeatString(unit: string, count: number): string {
  let out: string = '';
  for (let i: number = 0; i < count; i++) {
    out += unit;
  }
  return out;
}

function isAsciiLetter(ch: string): boolean {
  return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z');
}

function buildDisguises(base: string): DisguiseCase[] {
  const cases: DisguiseCase[] = [];
  const invisibles: string[] = ['\u200C', '\u200D', '\u2060', '\u00AD', '\u200E'];

  let zeroWidth: string = '';
  for (let i: number = 0; i < base.length; i++) {
    zeroWidth += base.charAt(i) + '\u200B';
  }
  cases.push(new DisguiseCase('zero-width spaces', zeroWidth));

  let mixed: string = '';
  for (let i: number = 0; i < base.length; i++) {
    mixed += base.charAt(i) + invisibles[i % 5];
  }
  cases.push(new DisguiseCase('mixed invisible characters', mixed));

  let accented: string = '';
  for (let i: number = 0; i < base.length; i++) {
    const ch: string = base.charAt(i);
    accented += isAsciiLetter(ch) ? ch + '\u0301' : ch;
  }
  cases.push(new DisguiseCase('an accent on every letter', accented));

  let mathBold: string = '';
  for (let i: number = 0; i < base.length; i++) {
    const ch: string = base.charAt(i);
    if (ch >= 'a' && ch <= 'z') {
      mathBold += String.fromCodePoint(0x1D41A + (ch.charCodeAt(0) - 97));
    } else if (ch >= 'A' && ch <= 'Z') {
      mathBold += String.fromCodePoint(0x1D400 + (ch.charCodeAt(0) - 65));
    } else {
      mathBold += ch;
    }
  }
  cases.push(new DisguiseCase('math bold letters', mathBold));

  let fullwidth: string = '';
  for (let i: number = 0; i < base.length; i++) {
    const ch: string = base.charAt(i);
    fullwidth += (ch >= '!' && ch <= '~') ? String.fromCharCode(ch.charCodeAt(0) + 0xFEE0) : ch;
  }
  cases.push(new DisguiseCase('fullwidth letters', fullwidth));

  let nbsp: string = '';
  for (let i: number = 0; i < base.length; i++) {
    nbsp += base.charAt(i) === ' ' ? '\u00A0' : base.charAt(i);
  }
  cases.push(new DisguiseCase('non-breaking spaces', nbsp));

  return cases;
}

function expectVerdicts(t: ContractAssert, expected: SpamVerdict[], actual: SpamVerdict[], label: string): void {
  t.equalNumber(expected.length, actual.length, label + ': count');
  for (let i: number = 0; i < expected.length && i < actual.length; i++) {
    t.equalNumber(expected[i], actual[i], label + '[' + i + ']');
  }
}

function expectSamePoints(t: ContractAssert, expected: number[], actual: number[], label: string): void {
  t.equalNumber(expected.length, actual.length, label + ': length');
  for (let i: number = 0; i < expected.length && i < actual.length; i++) {
    t.equalNumber(expected[i], actual[i], label + '[' + i + ']');
  }
}

export function runSpamFilterContractTests(t: ContractAssert): void {
  // spamVerdictIsSpam mirrors the Android SpamVerdict.isSpam property.
  {
    t.isTrue(spamVerdictIsSpam(SpamVerdict.MESSAGE_RATE), 'MESSAGE_RATE is spam');
    t.isTrue(spamVerdictIsSpam(SpamVerdict.REPEATED_ACROSS_USERS), 'REPEATED_ACROSS_USERS is spam');
    t.isFalse(spamVerdictIsSpam(SpamVerdict.ALLOWED), 'ALLOWED is not spam');
  }

  // Sixth message in a burst is shown and seventh is hidden.
  {
    const h: FilterHarness = new FilterHarness();
    const verdicts: SpamVerdict[] = [];
    for (let i: number = 0; i < 7; i++) {
      verdicts.push(h.send());
    }
    expectVerdicts(t, [SpamVerdict.ALLOWED, SpamVerdict.ALLOWED, SpamVerdict.ALLOWED,
      SpamVerdict.ALLOWED, SpamVerdict.ALLOWED, SpamVerdict.ALLOWED, SpamVerdict.MESSAGE_RATE],
      verdicts, 'burst of 7');
  }

  // Message budget refills one token every ten seconds.
  {
    const h: FilterHarness = new FilterHarness();
    for (let i: number = 0; i < 6; i++) {
      h.send();
    }
    h.advanceSeconds(9);
    t.equalNumber(SpamVerdict.MESSAGE_RATE, h.send(), 'after 9s still hidden');
    h.advanceSeconds(1);
    t.equalNumber(SpamVerdict.ALLOWED, h.send(), 'after 10s allowed again');
    t.equalNumber(SpamVerdict.MESSAGE_RATE, h.send(), 'immediately hidden again');
  }

  // Hidden messages do not drain the budget of a flooding sender.
  {
    const h: FilterHarness = new FilterHarness();
    let shown: number = 0;
    for (let i: number = 0; i < 120; i++) {
      if (h.send() === SpamVerdict.ALLOWED) {
        shown += 1;
      }
      h.advanceSeconds(1);
    }
    // A burst of 6, then one every 10 seconds for the remaining two minutes.
    t.equalNumber(6 + 11, shown, 'burst of 6 plus 11 refilled');
  }

  // Character budget allows twelve hundred characters per minute.
  {
    const h: FilterHarness = new FilterHarness();
    t.equalNumber(SpamVerdict.ALLOWED, h.send(h.prose(600)), 'first 600 characters allowed');
    t.equalNumber(SpamVerdict.ALLOWED, h.send(h.prose(600)), 'another 600 characters allowed');
    t.equalNumber(SpamVerdict.CHARACTER_RATE, h.send(h.prose(20)), 'overdraw hidden');
    h.advanceSeconds(2);
    t.equalNumber(SpamVerdict.ALLOWED, h.send(h.prose(20)), 'refilled after 2s');
  }

  // Message longer than the character budget is hidden.
  {
    const h: FilterHarness = new FilterHarness();
    t.equalNumber(SpamVerdict.CHARACTER_RATE, h.send(h.prose(1201)), '1201 characters hidden');
  }

  // Characters are counted as code points.
  {
    const h: FilterHarness = new FilterHarness();
    let sentence: string = '';
    for (let i: number = 0; i < 1200; i++) {
      sentence += (i % 3 === 0) ? String.fromCodePoint(0x1F600) : h.randomLetter();
    }
    t.equalNumber(SpamVerdict.ALLOWED, h.send(sentence), '1200 code points with emoji allowed');
  }

  // Third link within a minute is hidden.
  {
    const h: FilterHarness = new FilterHarness();
    t.equalNumber(SpamVerdict.ALLOWED, h.send('see https://example.org/a for details'), 'first link allowed');
    t.equalNumber(SpamVerdict.ALLOWED, h.send('mirror at www.example.net too'), 'second link allowed');
    t.equalNumber(SpamVerdict.LINK_RATE, h.send('and example.com/promo as well'), 'third link hidden');
    t.equalNumber(SpamVerdict.ALLOWED, h.send('no link in this one at all'), 'no link allowed');
    h.advanceSeconds(30);
    t.equalNumber(SpamVerdict.ALLOWED, h.send('ok one more https://example.org/b'), 'link budget refilled');
  }

  // Message with three links is hidden even for a fresh sender.
  {
    const h: FilterHarness = new FilterHarness();
    t.equalNumber(SpamVerdict.LINK_RATE,
      h.send('https://alpha.example/one and bravo.example plus www.charlie.example/three'),
      'three links in one message hidden');
  }

  // Link counter ignores email addresses and abbreviations.
  {
    t.equalNumber(0, LinkCounter.count('mail me at someone@example.com e.g. today'),
      'email address is not a link');
    t.equalNumber(0, LinkCounter.count('pi is 3.14, version v1.2.3'),
      'numbers and dots are not links');
    t.equalNumber(3, LinkCounter.count('https://a.example/x, www.b.example and c.example.'),
      'three links counted');
  }

  // Third copy of a message within ten minutes is hidden.
  {
    const h: FilterHarness = new FilterHarness();
    const text: string = 'anyone near the north gate tonight?';
    t.equalNumber(SpamVerdict.ALLOWED, h.send(text), 'first copy allowed');
    h.advanceSeconds(60);
    t.equalNumber(SpamVerdict.ALLOWED, h.send(text), 'second copy allowed');
    h.advanceSeconds(60);
    t.equalNumber(SpamVerdict.REPEATED_MESSAGE, h.send(text), 'third copy hidden');
  }

  // Near copies with a changing suffix count as repeats.
  {
    const h: FilterHarness = new FilterHarness();
    t.equalNumber(SpamVerdict.ALLOWED, h.send('FREE SATS at the link below 101'), 'suffix 101 allowed');
    h.advanceSeconds(20);
    t.equalNumber(SpamVerdict.ALLOWED, h.send('free sats at the link below 202'), 'suffix 202 allowed');
    h.advanceSeconds(20);
    t.equalNumber(SpamVerdict.REPEATED_MESSAGE, h.send('free  sats at the link below 303'), 'suffix 303 hidden');
  }

  // Repeats spread beyond the history window are allowed.
  {
    const h: FilterHarness = new FilterHarness();
    const text: string = 'good morning everyone, coffee anyone?';
    h.send(text);
    h.advanceSeconds(11 * 60);
    h.send(text);
    h.advanceSeconds(11 * 60);
    t.equalNumber(SpamVerdict.ALLOWED, h.send(text), 'copies beyond the window allowed');
  }

  // Short replies may repeat freely.
  {
    const h: FilterHarness = new FilterHarness();
    for (let i: number = 0; i < 5; i++) {
      t.equalNumber(SpamVerdict.ALLOWED, h.send('lol yes'), 'short reply ' + i);
      h.advanceSeconds(10);
    }
  }

  // Message repeating a character is hidden.
  {
    const h: FilterHarness = new FilterHarness();
    t.equalNumber(SpamVerdict.REPEATED_CHARACTERS, h.send(repeatString('A', 40)), 'AAAA hidden');
    t.equalNumber(SpamVerdict.REPEATED_CHARACTERS, h.send('hey ' + repeatString('!', 60)), 'hey!!!! hidden');
  }

  // Message repeating a phrase is hidden.
  {
    const h: FilterHarness = new FilterHarness();
    t.equalNumber(SpamVerdict.REPEATED_CHARACTERS, h.send(repeatString('buy now ', 6)), 'buy now x6 hidden');
  }

  // Ordinary long sentence is not mistaken for repetition.
  {
    const h: FilterHarness = new FilterHarness();
    const text: string =
      'The market by the old bridge opens at nine, bring cash because the card reader is flaky.';
    t.isTrue(RepetitionDetector.selfSimilarity(RepetitionDetector.normalize(text, 1000)) < 0.3,
      'ordinary sentence self-similarity below 0.3');
    t.equalNumber(SpamVerdict.ALLOWED, h.send(text), 'ordinary sentence allowed');
  }

  // Senders have independent budgets.
  {
    const h: FilterHarness = new FilterHarness();
    for (let i: number = 0; i < 6; i++) {
      h.send();
    }
    t.equalNumber(SpamVerdict.MESSAGE_RATE, h.send(), 'alice exhausted');
    t.equalNumber(SpamVerdict.ALLOWED, h.send(null, 'bob'), 'bob has a fresh budget');
  }

  // Same message ID arriving twice is judged once.
  {
    const h: FilterHarness = new FilterHarness();
    for (let i: number = 0; i < 5; i++) {
      h.send();
    }
    t.equalNumber(SpamVerdict.ALLOWED, h.send(null, 'alice', null, 'dup'), 'first dup judged');
    t.equalNumber(SpamVerdict.ALLOWED, h.send(null, 'alice', null, 'dup'), 'second dup cached');
    t.equalNumber(SpamVerdict.MESSAGE_RATE, h.send(), 'seventh distinct message hidden');
  }

  // Backfilled history delivered newest first is shown.
  {
    const h: FilterHarness = new FilterHarness();
    const verdicts: SpamVerdict[] = [];
    for (let minutesAgo: number = 0; minutesAgo < 10; minutesAgo++) {
      verdicts.push(h.send(null, 'alice', h.getNow() - minutesAgo * 60000));
    }
    expectVerdicts(t, [SpamVerdict.ALLOWED, SpamVerdict.ALLOWED, SpamVerdict.ALLOWED,
      SpamVerdict.ALLOWED, SpamVerdict.ALLOWED, SpamVerdict.ALLOWED, SpamVerdict.ALLOWED,
      SpamVerdict.ALLOWED, SpamVerdict.ALLOWED, SpamVerdict.ALLOWED],
      verdicts, 'backfill newest first all shown');
  }

  // Backfilled burst is still rate limited on its own timestamps.
  {
    const h: FilterHarness = new FilterHarness();
    const start: number = h.getNow() - 5 * 60000;
    let allowed: number = 0;
    for (let i: number = 0; i < 10; i++) {
      if (h.send(null, 'alice', start + i * 1000) === SpamVerdict.ALLOWED) {
        allowed += 1;
      }
    }
    t.equalNumber(6, allowed, 'burst of 10 over 10s: 6 shown');
  }

  // Backfill cannot be squeezed in between already shown messages.
  {
    const h: FilterHarness = new FilterHarness();
    for (let i: number = 0; i < 6; i++) {
      h.send(null, 'alice', h.getNow() - 60000);
    }
    t.equalNumber(SpamVerdict.MESSAGE_RATE, h.send(null, 'alice', h.getNow() - 61000),
      'pre-burst timestamp overdraws the bucket');
  }

  // Timestamps older than the backdate window are clamped.
  {
    const h: FilterHarness = new FilterHarness();
    let allowed: number = 0;
    for (let i: number = 0; i < 10; i++) {
      if (h.send(null, 'alice', h.getNow() - (10 - i) * 86400000) === SpamVerdict.ALLOWED) {
        allowed += 1;
      }
    }
    t.equalNumber(6, allowed, 'day-spread fake timestamps clamped: 6 shown');
  }

  // Future timestamps are clamped to now.
  {
    const h: FilterHarness = new FilterHarness();
    let allowed: number = 0;
    for (let i: number = 0; i < 10; i++) {
      if (h.send(null, 'alice', h.getNow() + i * 60000) === SpamVerdict.ALLOWED) {
        allowed += 1;
      }
    }
    t.equalNumber(6, allowed, 'future timestamps clamped: 6 shown');
  }

  // Disabled filter allows everything.
  {
    const h: FilterHarness = new FilterHarness();
    h.filter.enabled = false;
    for (let i: number = 0; i < 20; i++) {
      t.equalNumber(SpamVerdict.ALLOWED, h.send(repeatString('A', 40)), 'disabled filter allows ' + i);
    }
  }

  // Limits are configurable.
  {
    const h: FilterHarness = new FilterHarness();
    const strict: SpamFilter = new SpamFilter(
      new SpamFilterConfig(new TokenBucketConfig(2.0, 1.0)), (): number => h.getNow());
    t.equalNumber(SpamVerdict.ALLOWED, strict.check('a', '1', h.prose(), h.getNow()), 'strict 1 allowed');
    t.equalNumber(SpamVerdict.ALLOWED, strict.check('a', '2', h.prose(), h.getNow()), 'strict 2 allowed');
    t.equalNumber(SpamVerdict.MESSAGE_RATE, strict.check('a', '3', h.prose(), h.getNow()), 'strict 3 hidden');
    h.advanceSeconds(1);
    t.equalNumber(SpamVerdict.ALLOWED, strict.check('a', '4', h.prose(), h.getNow()), 'strict refilled');
  }

  // Debug bypass shows spam and records why it would be hidden.
  {
    const h: FilterHarness = new FilterHarness();
    h.filter.debugBypass = true;
    for (let i: number = 1; i <= 7; i++) {
      const message: BitchatMessage = new BitchatMessage('flooder', 'hi ' + i, h.getNow());
      message.id = 'b' + i;
      const hidden: boolean = h.filter.shouldHide(message, 'flooder');
      t.isFalse(hidden, 'debug bypass shows message ' + i);
    }
    t.equalNumber(1, h.filter.flaggedCount(), 'exactly one flagged verdict');
    const flagged: SpamVerdict | null = h.filter.getFlaggedVerdict('b7');
    t.isNotNull(flagged, 'b7 is flagged');
    t.equalNumber(SpamVerdict.MESSAGE_RATE, flagged === null ? SpamVerdict.ALLOWED : flagged,
      'b7 flagged as MESSAGE_RATE');
  }

  // Spam is hidden without the debug bypass.
  {
    const h: FilterHarness = new FilterHarness();
    const hiddenResults: boolean[] = [];
    for (let i: number = 1; i <= 7; i++) {
      const message: BitchatMessage = new BitchatMessage('flooder', 'hi ' + i, h.getNow());
      message.id = 'h' + i;
      hiddenResults.push(h.filter.shouldHide(message, 'flooder'));
    }
    t.equalNumber(7, hiddenResults.length, 'seven messages checked');
    for (let i: number = 0; i < 6; i++) {
      t.isFalse(hiddenResults[i], 'message ' + (i + 1) + ' shown');
    }
    t.isTrue(hiddenResults[6], 'seventh message hidden');
    t.equalNumber(0, h.filter.flaggedCount(), 'nothing flagged without bypass');
  }

  // Changing limits starts every sender with a full budget.
  {
    const h: FilterHarness = new FilterHarness();
    for (let i: number = 0; i < 6; i++) {
      h.send();
    }
    t.equalNumber(SpamVerdict.MESSAGE_RATE, h.send(), 'default budget exhausted');

    const d: SpamTuning = SpamTuning.DEFAULT;
    h.filter.setConfig(new SpamTuning(10, d.secondsPerMessage, d.charactersPerMinute,
      d.linksPerMinute, d.allowedRepeats, d.crossUserAllowedRepeats, d.crossUserMinLength,
      d.repeatSimilarityPercent, d.repeatWindowMinutes, d.selfMatchPercent,
      d.selfMatchMinLength).toConfig());

    for (let i: number = 0; i < 10; i++) {
      t.equalNumber(SpamVerdict.ALLOWED, h.send(), 'new budget allows ' + i);
    }
    t.equalNumber(SpamVerdict.MESSAGE_RATE, h.send(), 'new budget exhausted at 11');
  }

  // Default tuning matches the code defaults.
  {
    t.isTrue(SpamFilterConfig.equals(SpamTuning.DEFAULT.toConfig(), new SpamFilterConfig()),
      'DEFAULT tuning roundtrips to the code defaults');
    const d: SpamTuning = SpamTuning.DEFAULT;
    const changed: SpamTuning = new SpamTuning(d.messageBurst, d.secondsPerMessage,
      d.charactersPerMinute, 5, d.allowedRepeats, d.crossUserAllowedRepeats, d.crossUserMinLength,
      d.repeatSimilarityPercent, d.repeatWindowMinutes, d.selfMatchPercent, d.selfMatchMinLength);
    t.isFalse(SpamFilterConfig.equals(changed.toConfig(), new SpamFilterConfig()),
      'changed tuning differs from the defaults');
    t.isTrue(SpamTuning.equals(SpamTuning.fromConfig(new SpamFilterConfig()), SpamTuning.DEFAULT),
      'fromConfig of defaults equals DEFAULT');
  }

  // Same text from many throwaway identities is hidden after three copies.
  {
    const h: FilterHarness = new FilterHarness();
    const text: string = 'Free sats for everyone at freesats dot example';
    const verdicts: SpamVerdict[] = [];
    for (let i: number = 1; i <= 6; i++) {
      verdicts.push(h.send(text, 'npub' + i));
    }
    expectVerdicts(t, [SpamVerdict.ALLOWED, SpamVerdict.ALLOWED, SpamVerdict.ALLOWED,
      SpamVerdict.REPEATED_ACROSS_USERS, SpamVerdict.REPEATED_ACROSS_USERS,
      SpamVerdict.REPEATED_ACROSS_USERS], verdicts, 'throwaway identities');
  }

  // Near copies with small changes from different identities are hidden.
  {
    const h: FilterHarness = new FilterHarness();
    const variants: string[] = [
      'Free sats for everyone, claim yours now',
      'free sats for everyone, claim yours now 1',
      'Free sats for everyone!! claim yours now',
      'free sats 4 everyone, claim yours now',
      'free  sats for everyone, claim yours now 55'
    ];
    const verdicts: SpamVerdict[] = [];
    for (let i: number = 0; i < variants.length; i++) {
      verdicts.push(h.send(variants[i], 'npub' + i));
    }
    expectVerdicts(t, [SpamVerdict.ALLOWED, SpamVerdict.ALLOWED, SpamVerdict.ALLOWED,
      SpamVerdict.ALLOWED, SpamVerdict.REPEATED_ACROSS_USERS], verdicts, 'small edits across identities');
  }

  // Short common replies from many users are not compared.
  {
    const h: FilterHarness = new FilterHarness();
    for (let i: number = 0; i < 8; i++) {
      t.equalNumber(SpamVerdict.ALLOWED, h.send('good morning!', 'user' + i),
        'short reply from user ' + i);
    }
  }

  // Different messages on the same topic from many users are allowed.
  {
    const h: FilterHarness = new FilterHarness();
    const messages: string[] = [
      'is the bakery on the corner still open?',
      'the bakery closes at eight I think',
      'bakery was still open when I walked by',
      'anyone know if the bakery has bread left?',
      'the corner bakery is open until eight'
    ];
    for (let i: number = 0; i < messages.length; i++) {
      t.equalNumber(SpamVerdict.ALLOWED, h.send(messages[i], 'user' + i),
        'same-topic message ' + i);
    }
  }

  // Copies from other users outside the window do not count.
  {
    const h: FilterHarness = new FilterHarness();
    const text: string = 'anyone up for chess at the tables later?';
    for (let i: number = 0; i < 3; i++) {
      h.send(text, 'user' + i);
      h.advanceSeconds(4 * 60);
    }
    t.equalNumber(SpamVerdict.ALLOWED, h.send(text, 'late'),
      'only copies inside the window count');
  }

  // A sender's own copies do not count toward the cross-user limit.
  {
    const h: FilterHarness = new FilterHarness();
    const text: string = 'anyone near the north gate tonight?';
    h.send(text, 'alice');
    h.advanceSeconds(60);
    h.send(text, 'alice');
    t.equalNumber(SpamVerdict.ALLOWED, h.send(text, 'bob'), 'bob allowed after alice repeats');
    t.equalNumber(SpamVerdict.REPEATED_ACROSS_USERS, h.send(text, 'carol'), 'carol hidden');
  }

  // Best alignment reports where the texts line up.
  {
    const a: number[] = RepetitionDetector.normalize('xx hello world', 1000);
    const b: number[] = RepetitionDetector.normalize('hello world', 1000);
    const alignment: AlignmentResult = RepetitionDetector.align(a, b, 3, 3);
    t.equalNumber(3, alignment.peaks[0].shift, 'first peak shift is 3');
    t.equalNumber(11, alignment.matches, 'alignment matches 11');
  }

  // An inserted character does not break the match.
  {
    const a: number[] = RepetitionDetector.normalize('free sats for everyone, claim yours now', 1000);
    const b: number[] = RepetitionDetector.normalize('free sats for everyone!!, claim yours now', 1000);
    t.isTrue(RepetitionDetector.align(a, b, 1, 3).score < 0.8, 'single peak below threshold');
    t.isTrue(RepetitionDetector.align(a, b, 3, 3).score > 0.9, 'three peaks above threshold');
  }

  // Unrelated sentences stay far below the near-copy threshold.
  {
    const a: number[] = RepetitionDetector.normalize('the bakery closes at eight I think', 1000);
    const b: number[] = RepetitionDetector.normalize('the corner bakery is open until eight', 1000);
    t.isTrue(RepetitionDetector.align(a, b, 3, 3).score < 0.6, 'unrelated sentences below 0.6');
  }

  // Normalization folds disguises to the text a reader sees.
  {
    const base: string = 'Free sats for everyone, claim yours now';
    const plain: number[] = RepetitionDetector.normalize(base, 1000);
    const cases: DisguiseCase[] = buildDisguises(base);
    t.equalNumber(6, cases.length, 'six disguise cases');
    for (let i: number = 0; i < cases.length; i++) {
      expectSamePoints(t, plain, RepetitionDetector.normalize(cases[i].text, 1000),
        'disguise ' + cases[i].label);
    }
  }

  // Disguised copies from other users are still caught.
  {
    const base: string = 'Free sats for everyone, claim yours now';
    const cases: DisguiseCase[] = buildDisguises(base);
    for (let i: number = 0; i < cases.length; i++) {
      const fresh: SpamFilter = new SpamFilter(null, (): number => 1000000000);
      fresh.check('npub0', cases[i].label + '-0', base, 1000000000);
      fresh.check('npub1', cases[i].label + '-1', base, 1000000000);
      fresh.check('npub2', cases[i].label + '-2', base, 1000000000);
      t.equalNumber(SpamVerdict.REPEATED_ACROSS_USERS,
        fresh.check('npub9', cases[i].label + '-x', cases[i].text, 1000000000),
        'disguised cross-user caught: ' + cases[i].label);
    }
  }

  // Disguised copies from the same user are still caught.
  {
    const base: string = 'Free sats for everyone, claim yours now';
    const cases: DisguiseCase[] = buildDisguises(base);
    for (let i: number = 0; i < cases.length; i++) {
      const fresh: SpamFilter = new SpamFilter(null, (): number => 1000000000);
      fresh.check('alice', cases[i].label + '-1', base, 1000000000);
      fresh.check('alice', cases[i].label + '-2', base, 1000000000);
      t.equalNumber(SpamVerdict.REPEATED_MESSAGE,
        fresh.check('alice', cases[i].label + '-3', cases[i].text, 1000000000),
        'disguised same-user caught: ' + cases[i].label);
    }
  }

  // Invisible characters cannot break up a repeated character run.
  {
    const h: FilterHarness = new FilterHarness();
    t.equalNumber(SpamVerdict.REPEATED_CHARACTERS, h.send(repeatString('A\u200B', 40)),
      'zero-width-broken run hidden');
  }

  // Ordinary text with accents and other scripts is still allowed.
  {
    const h: FilterHarness = new FilterHarness();
    const messages: string[] = [
      'Ti\u1EBFng Vi\u1EC7t c\u00F3 d\u1EA5u, ch\u00FAng t\u00F4i \u0111ang \u1EDF qu\u00E1n c\u00E0 ph\u00EA g\u1EA7n ch\u1EE3',
      '\u0915\u094D\u092F\u093E \u0915\u094B\u0908 \u092A\u093E\u0938 \u092E\u0947\u0902 \u091A\u093E\u092F \u0915\u0940 \u0926\u0941\u0915\u093E\u0928 \u091C\u093E\u0928\u0924\u093E \u0939\u0948? \u092E\u0948\u0902 \u0938\u094D\u091F\u0947\u0936\u0928 \u0915\u0947 \u092A\u093E\u0938 \u0939\u0942\u0901',
      'Caf\u00E9 au lait, cr\u00E8me br\u00FBl\u00E9e, s\'il vous pla\u00EEt',
      '\u5BB6\u65CF\u3068\u4E00\u7DD2\u306B\u99C5\u306E\u8FD1\u304F\u306E\u30AB\u30D5\u30A7\u306B\u3044\u307E\u3059\u3001\u8AB0\u304B\u6765\u307E\u3059\u304B'
    ];
    for (let i: number = 0; i < messages.length; i++) {
      t.equalNumber(SpamVerdict.ALLOWED, h.send(messages[i], 'user' + i),
        'accented script message ' + i);
    }
  }

  // Different sentences in another script are not mistaken for copies.
  {
    const h: FilterHarness = new FilterHarness();
    t.equalNumber(SpamVerdict.ALLOWED, h.send(
      '\u0915\u094D\u092F\u093E \u0915\u094B\u0908 \u092A\u093E\u0938 \u092E\u0947\u0902 \u091A\u093E\u092F \u0915\u0940 \u0926\u0941\u0915\u093E\u0928 \u091C\u093E\u0928\u0924\u093E \u0939\u0948?', 'a'),
      'hindi question 1');
    t.equalNumber(SpamVerdict.ALLOWED, h.send(
      '\u092E\u0948\u0902 \u0938\u094D\u091F\u0947\u0936\u0928 \u0915\u0947 \u092A\u093E\u0938 \u0939\u0942\u0901, \u092C\u093E\u0930\u093F\u0936 \u0939\u094B \u0930\u0939\u0940 \u0939\u0948', 'b'),
      'hindi statement 2');
    t.equalNumber(SpamVerdict.ALLOWED, h.send(
      '\u0906\u091C \u092C\u093E\u091C\u093C\u093E\u0930 \u0915\u093F\u0924\u0928\u0947 \u092C\u091C\u0947 \u092C\u0902\u0926 \u0939\u094B\u0917\u093E?', 'c'),
      'hindi question 3');
    t.equalNumber(SpamVerdict.ALLOWED, h.send(
      '\u0915\u094D\u092F\u093E \u0915\u093F\u0938\u0940 \u0915\u0947 \u092A\u093E\u0938 \u091B\u093E\u0924\u093E \u0939\u0948 \u091C\u094B \u092E\u0948\u0902 \u0932\u0947 \u0938\u0915\u0942\u0901?', 'd'),
      'hindi question 4');
  }

  // Shared static helpers for sender keys (consumed by T038 wiring).
  {
    const message: BitchatMessage = new BitchatMessage('system', 'notice', 1000000000);
    message.id = 'local-1';
    t.isTrue(SpamFilter.isLocalNotice(message), 'local notice has no peer ID');
    message.senderPeerId = 'peer-1';
    t.isFalse(SpamFilter.isLocalNotice(message), 'wire message is not a local notice');
    t.equalString('mesh:peer-1', SpamFilter.meshSenderKey(message), 'mesh key prefers the peer ID');
    const anonymous: BitchatMessage = new BitchatMessage('nickname', 'hello', 1000000000);
    t.equalString('mesh:nickname', SpamFilter.meshSenderKey(anonymous), 'mesh key falls back to nickname');
    t.equalString('nostr:abcd1234', SpamFilter.nostrSenderKey('ABCD1234'), 'nostr key lowercases');
  }
}
