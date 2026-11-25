/**
 * Persists the user's on/off choice for SpamFilter.shared (on by default),
 * plus the debug settings: tuned limits and the bypass that marks spam
 * instead of hiding it (T038; port of Android spam/SpamFilterPreferences,
 * key names kept identical so a future settings/debug UI matches 1:1).
 *
 * All values ride the typed PreferenceStore facade (D9) so the panic-wipe
 * orchestrator clears them with every other preference. Persistence is
 * best-effort: a failed write never blocks the live filter toggle.
 */
import { PreferenceStore } from '../../data/PreferenceStore';
import { SpamFilter, SpamTuning } from './SpamFilter';

const KEY_ENABLED = 'spam_filter_enabled';
const KEY_DEBUG_BYPASS = 'spam_filter_debug_bypass';
const KEY_MESSAGE_BURST = 'spam_filter_message_burst';
const KEY_SECONDS_PER_MESSAGE = 'spam_filter_seconds_per_message';
const KEY_CHARACTERS_PER_MINUTE = 'spam_filter_characters_per_minute';
const KEY_LINKS_PER_MINUTE = 'spam_filter_links_per_minute';
const KEY_ALLOWED_REPEATS = 'spam_filter_allowed_repeats';
const KEY_CROSS_USER_ALLOWED_REPEATS = 'spam_filter_cross_user_allowed_repeats';
const KEY_CROSS_USER_MIN_LENGTH = 'spam_filter_cross_user_min_length';
const KEY_REPEAT_SIMILARITY = 'spam_filter_repeat_similarity';
const KEY_REPEAT_WINDOW_MINUTES = 'spam_filter_repeat_window_minutes';
const KEY_SELF_MATCH_THRESHOLD = 'spam_filter_self_match_threshold';
const KEY_SELF_MATCH_MIN_LENGTH = 'spam_filter_self_match_min_length';

export class SpamFilterPreferences {
  private static instance: SpamFilterPreferences | null = null;

  private initialized: boolean = false;
  private enabledValue: boolean = true;
  private debugBypassValue: boolean = false;
  private tuningValue: SpamTuning = SpamTuning.DEFAULT;

  static getInstance(): SpamFilterPreferences {
    if (SpamFilterPreferences.instance === null) {
      SpamFilterPreferences.instance = new SpamFilterPreferences();
    }
    return SpamFilterPreferences.instance;
  }

  /**
   * Idempotent; concurrent calls redo the read harmlessly. Loads the
   * persisted state and applies it to SpamFilter.shared.
   */
  async init(): Promise<void> {
    const store: PreferenceStore = PreferenceStore.getInstance();
    const defaults: SpamTuning = SpamTuning.DEFAULT;
    this.enabledValue = await store.getBoolean(KEY_ENABLED, true);
    this.debugBypassValue = await store.getBoolean(KEY_DEBUG_BYPASS, false);
    this.tuningValue = new SpamTuning(
      await store.getNumber(KEY_MESSAGE_BURST, defaults.messageBurst),
      await store.getNumber(KEY_SECONDS_PER_MESSAGE, defaults.secondsPerMessage),
      await store.getNumber(KEY_CHARACTERS_PER_MINUTE, defaults.charactersPerMinute),
      await store.getNumber(KEY_LINKS_PER_MINUTE, defaults.linksPerMinute),
      await store.getNumber(KEY_ALLOWED_REPEATS, defaults.allowedRepeats),
      await store.getNumber(KEY_CROSS_USER_ALLOWED_REPEATS, defaults.crossUserAllowedRepeats),
      await store.getNumber(KEY_CROSS_USER_MIN_LENGTH, defaults.crossUserMinLength),
      await store.getNumber(KEY_REPEAT_SIMILARITY, defaults.repeatSimilarityPercent),
      await store.getNumber(KEY_REPEAT_WINDOW_MINUTES, defaults.repeatWindowMinutes),
      await store.getNumber(KEY_SELF_MATCH_THRESHOLD, defaults.selfMatchPercent),
      await store.getNumber(KEY_SELF_MATCH_MIN_LENGTH, defaults.selfMatchMinLength));
    SpamFilter.shared.enabled = this.enabledValue;
    SpamFilter.shared.debugBypass = this.debugBypassValue;
    SpamFilter.shared.setConfig(this.tuningValue.toConfig());
    this.initialized = true;
  }

  isInitialized(): boolean {
    return this.initialized;
  }

  getEnabled(): boolean {
    return this.enabledValue;
  }

  getDebugBypass(): boolean {
    return this.debugBypassValue;
  }

  getTuning(): SpamTuning {
    return this.tuningValue;
  }

  async setEnabled(enabled: boolean): Promise<void> {
    if (this.enabledValue === enabled) {
      return;
    }
    try {
      await PreferenceStore.getInstance().setBoolean(KEY_ENABLED, enabled);
    } catch (e) {
      // Best-effort persistence; the live filter still follows the toggle.
    }
    this.enabledValue = enabled;
    SpamFilter.shared.enabled = enabled;
    // Start from a clean slate so budgets don't carry over from before the
    // toggle (Android parity).
    SpamFilter.shared.reset();
  }

  async setDebugBypass(enabled: boolean): Promise<void> {
    if (this.debugBypassValue === enabled) {
      return;
    }
    try {
      await PreferenceStore.getInstance().setBoolean(KEY_DEBUG_BYPASS, enabled);
    } catch (e) {
      // Best-effort persistence; the live filter still follows the toggle.
    }
    this.debugBypassValue = enabled;
    SpamFilter.shared.debugBypass = enabled;
  }

  async setTuning(tuning: SpamTuning): Promise<void> {
    if (SpamTuning.equals(this.tuningValue, tuning)) {
      return;
    }
    try {
      const store: PreferenceStore = PreferenceStore.getInstance();
      await store.setNumber(KEY_MESSAGE_BURST, tuning.messageBurst);
      await store.setNumber(KEY_SECONDS_PER_MESSAGE, tuning.secondsPerMessage);
      await store.setNumber(KEY_CHARACTERS_PER_MINUTE, tuning.charactersPerMinute);
      await store.setNumber(KEY_LINKS_PER_MINUTE, tuning.linksPerMinute);
      await store.setNumber(KEY_ALLOWED_REPEATS, tuning.allowedRepeats);
      await store.setNumber(KEY_CROSS_USER_ALLOWED_REPEATS, tuning.crossUserAllowedRepeats);
      await store.setNumber(KEY_CROSS_USER_MIN_LENGTH, tuning.crossUserMinLength);
      await store.setNumber(KEY_REPEAT_SIMILARITY, tuning.repeatSimilarityPercent);
      await store.setNumber(KEY_REPEAT_WINDOW_MINUTES, tuning.repeatWindowMinutes);
      await store.setNumber(KEY_SELF_MATCH_THRESHOLD, tuning.selfMatchPercent);
      await store.setNumber(KEY_SELF_MATCH_MIN_LENGTH, tuning.selfMatchMinLength);
    } catch (e) {
      // Best-effort persistence; the live config still follows the tuning.
    }
    this.tuningValue = tuning;
    SpamFilter.shared.setConfig(tuning.toConfig());
  }
}
