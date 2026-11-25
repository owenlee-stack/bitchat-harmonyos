/**
 * Typed facade over @ohos.data.preferences (D9).
 *
 * All lightweight app state flows through this single file so the panic-wipe
 * orchestrator (T043) can clear every preference in one stage via clearAll();
 * nothing persisted here escapes the panic manifest. Callers must init() with
 * an ability context before first use.
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const STORE_TAG = 'PreferenceStore';
const PREFS_NAME = 'bitchat_prefs';

export class PreferenceStore {
  private static instance: PreferenceStore | null = null;
  private prefs: preferences.Preferences | null = null;
  private initPromise: Promise<void> | null = null;

  static getInstance(): PreferenceStore {
    if (PreferenceStore.instance === null) {
      PreferenceStore.instance = new PreferenceStore();
    }
    return PreferenceStore.instance;
  }

  /** Idempotent; concurrent calls share one load. */
  init(context: common.Context): Promise<void> {
    if (this.initPromise === null) {
      this.initPromise = preferences.getPreferences(context, PREFS_NAME)
        .then((loaded: preferences.Preferences) => {
          this.prefs = loaded;
        });
    }
    return this.initPromise;
  }

  private async ready(): Promise<preferences.Preferences> {
    if (this.prefs === null) {
      throw new Error('PreferenceStore not initialized');
    }
    return this.prefs;
  }

  async getBoolean(key: string, defaultValue: boolean): Promise<boolean> {
    const prefs = await this.ready();
    const value: preferences.ValueType = prefs.getSync(key, defaultValue);
    return typeof value === 'boolean' ? value : defaultValue;
  }

  async setBoolean(key: string, value: boolean): Promise<void> {
    const prefs = await this.ready();
    prefs.putSync(key, value);
    await prefs.flush();
  }

  async getNumber(key: string, defaultValue: number): Promise<number> {
    const prefs = await this.ready();
    const value: preferences.ValueType = prefs.getSync(key, defaultValue);
    return typeof value === 'number' ? value : defaultValue;
  }

  async setNumber(key: string, value: number): Promise<void> {
    const prefs = await this.ready();
    prefs.putSync(key, value);
    await prefs.flush();
  }

  async getString(key: string, defaultValue: string): Promise<string> {
    const prefs = await this.ready();
    const value: preferences.ValueType = prefs.getSync(key, defaultValue);
    return typeof value === 'string' ? value : defaultValue;
  }

  async setString(key: string, value: string): Promise<void> {
    const prefs = await this.ready();
    prefs.putSync(key, value);
    await prefs.flush();
  }

  async has(key: string): Promise<boolean> {
    const prefs = await this.ready();
    return prefs.hasSync(key);
  }

  async remove(key: string): Promise<void> {
    const prefs = await this.ready();
    prefs.deleteSync(key);
    await prefs.flush();
  }

  /** Panic stage: clear every managed preference and commit to disk. */
  async clearAll(): Promise<void> {
    const prefs = await this.ready();
    prefs.clearSync();
    await prefs.flush();
    hilog.warn(DOMAIN, STORE_TAG, '%{public}s', 'preferences wiped');
  }
}
