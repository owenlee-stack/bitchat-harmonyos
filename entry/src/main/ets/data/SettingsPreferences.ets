/**
 * Persisted appearance settings (T042): theme preference (system/light/dark)
 * and chat UI mode (bubbles/terminal).
 *
 * Port of the Android ThemePreference.kt + theme/ChatUiMode.kt managers: key
 * names and stored value strings kept identical ('theme_preference':
 * 'System'/'Light'/'Dark'; 'chat_ui_mode': 'Bubbles'/'Matrix'). All values
 * ride the typed PreferenceStore facade (D9) so the panic-wipe orchestrator
 * clears them with every other preference.
 *
 * The theme applies immediately through ApplicationContext.setColorMode (the
 * dark/light resource qualifier switch; 'system' removes the override). The
 * chat UI mode is a plain persisted flag; callers (bootstrap, SettingsView)
 * apply it to the ChatState so the data layer never imports view models.
 *
 * SOCKS proxy parameterization (T072, US15): the OFF/custom mode, host and
 * port (Android 9060 default) persist the same way ('socks_proxy_mode':
 * 'Off'/'Custom'; 'socks_proxy_host': free-form; 'socks_proxy_port':
 * number). Bootstrap applies the loaded choice to NostrRelayManager before
 * any relay connection is attempted.
 */
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { PreferenceStore } from './PreferenceStore';
import { SocksProxyMode, socksProxyModeFromName, socksProxyPortValid,
  SOCKS_PROXY_DEFAULT_PORT } from '../service/nostr/SocksProxyPolicy';

const KEY_THEME = 'theme_preference';
const KEY_CHAT_UI_MODE = 'chat_ui_mode';
const KEY_SOCKS_PROXY_MODE = 'socks_proxy_mode';
const KEY_SOCKS_PROXY_HOST = 'socks_proxy_host';
const KEY_SOCKS_PROXY_PORT = 'socks_proxy_port';

/** App theme preference (Android ThemePreference parity). */
export enum ThemePreference {
  SYSTEM = 'System',
  LIGHT = 'Light',
  DARK = 'Dark'
}

export class SettingsPreferences {
  private static instance: SettingsPreferences | null = null;

  private themeValue: ThemePreference = ThemePreference.SYSTEM;
  private bubblesModeValue: boolean = true;
  private socksProxyModeValue: SocksProxyMode = SocksProxyMode.OFF;
  private socksProxyHostValue: string = '';
  private socksProxyPortValue: number = SOCKS_PROXY_DEFAULT_PORT;
  private appContext: common.ApplicationContext | null = null;

  static getInstance(): SettingsPreferences {
    if (SettingsPreferences.instance === null) {
      SettingsPreferences.instance = new SettingsPreferences();
    }
    return SettingsPreferences.instance;
  }

  /** Idempotent; loads and applies the persisted appearance settings. */
  async init(context: common.Context): Promise<void> {
    this.appContext = context.getApplicationContext();
    const store: PreferenceStore = PreferenceStore.getInstance();
    this.themeValue = SettingsPreferences.themeFromName(await store.getString(KEY_THEME, 'System'));
    this.bubblesModeValue = (await store.getString(KEY_CHAT_UI_MODE, 'Bubbles')) !== 'Matrix';
    // SOCKS proxy parameterization (T072, US15): OFF/custom choice with
    // the Android 9060 default port; all keys ride PreferenceStore so
    // the panic wipe clears them with every other preference.
    this.socksProxyModeValue =
      socksProxyModeFromName(await store.getString(KEY_SOCKS_PROXY_MODE, 'Off'));
    this.socksProxyHostValue = await store.getString(KEY_SOCKS_PROXY_HOST, '');
    const storedPort: number =
      await store.getNumber(KEY_SOCKS_PROXY_PORT, SOCKS_PROXY_DEFAULT_PORT);
    this.socksProxyPortValue =
      socksProxyPortValid(storedPort) ? storedPort : SOCKS_PROXY_DEFAULT_PORT;
    this.applyTheme();
  }

  getThemePreference(): ThemePreference {
    return this.themeValue;
  }

  isBubblesMode(): boolean {
    return this.bubblesModeValue;
  }

  async setThemePreference(theme: ThemePreference): Promise<void> {
    if (this.themeValue === theme) {
      return;
    }
    try {
      await PreferenceStore.getInstance().setString(KEY_THEME, theme);
    } catch (e) {
      // Best-effort persistence; the live color mode still follows the pick.
    }
    this.themeValue = theme;
    this.applyTheme();
  }

  async setChatUiMode(bubbles: boolean): Promise<void> {
    if (this.bubblesModeValue === bubbles) {
      return;
    }
    try {
      await PreferenceStore.getInstance().setString(KEY_CHAT_UI_MODE, bubbles ? 'Bubbles' : 'Matrix');
    } catch (e) {
      // Best-effort persistence; the live chat surface still follows the pick.
    }
    this.bubblesModeValue = bubbles;
  }

  getSocksProxyMode(): SocksProxyMode {
    return this.socksProxyModeValue;
  }

  getSocksProxyHost(): string {
    return this.socksProxyHostValue;
  }

  getSocksProxyPort(): number {
    return this.socksProxyPortValue;
  }

  /**
   * Persist the SOCKS proxy selection (T072): OFF restores direct relay
   * connections; CUSTOM carries host/port with the 9060 default port
   * and suppresses direct connections once applied by the caller.
   */
  async setSocksProxy(mode: SocksProxyMode, host: string, port: number): Promise<void> {
    const normalizedPort: number =
      socksProxyPortValid(port) ? port : SOCKS_PROXY_DEFAULT_PORT;
    try {
      const store: PreferenceStore = PreferenceStore.getInstance();
      await store.setString(KEY_SOCKS_PROXY_MODE, mode);
      await store.setString(KEY_SOCKS_PROXY_HOST, host);
      await store.setNumber(KEY_SOCKS_PROXY_PORT, normalizedPort);
    } catch (e) {
      // Best-effort persistence; the live transport still follows the pick.
    }
    this.socksProxyModeValue = mode;
    this.socksProxyHostValue = host;
    this.socksProxyPortValue = normalizedPort;
  }

  /** Dark/light resource qualifier switch; 'system' unsets the override. */
  private applyTheme(): void {
    const context: common.ApplicationContext | null = this.appContext;
    if (context === null) {
      return;
    }
    const mode: ConfigurationConstant.ColorMode = this.themeValue === ThemePreference.DARK ?
      ConfigurationConstant.ColorMode.COLOR_MODE_DARK :
      (this.themeValue === ThemePreference.LIGHT ?
        ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT :
        ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    try {
      context.setColorMode(mode);
    } catch (e) {
      // Best-effort theme switch; the preference itself is already persisted.
    }
  }

  private static themeFromName(name: string): ThemePreference {
    if (name === 'Dark') {
      return ThemePreference.DARK;
    }
    if (name === 'Light') {
      return ThemePreference.LIGHT;
    }
    return ThemePreference.SYSTEM;
  }
}
