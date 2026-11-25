/*
 * Entry ability / startup chain (T020).
 *
 * onWindowStageCreate stays synchronous and delegates to an async
 * bootstrap (T079: independent inits run concurrently so the critical
 * path approaches the slowest store, not the sum of all stores):
 *  1. PreferenceStore.init (single prefs load, shared by all later
 *     callers) starts together with ConversationStore.init (private-chat
 *     persistence, T036) and IdentityManager.initialize (idempotent
 *     load-or-generate of the Noise static + Ed25519 signing pairs),
 *  2. PreferenceStore-backed loads follow the store (SpamFilterPreferences
 *     for the persisted spam toggles, T038; SettingsPreferences for the
 *     appearance/theme, T042),
 *  3. first-launch branch: onboarded ? 'pages/Index' : 'pages/OnboardingPage',
 *  4. windowStage.loadContent with the resolved landing page; its
 *     callback logs the ColdStartReady delta for the SC-007 budget.
 *
 * Service-singleton wiring beyond identity/storage happens in later phases
 * (BLE mesh, announce scheduler) and will hook into this same bootstrap.
 */
import { AbilityConstant, common, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { PreferenceStore } from '../data/PreferenceStore';
import { ConversationStore } from '../data/ConversationStore';
import { SettingsPreferences } from '../data/SettingsPreferences';
import { MediaFileStore } from '../data/MediaFileStore';
import { LiveVoiceManager } from '../service/livevoice/LiveVoiceManager';
import { PeerStatePinStore } from '../data/PeerStatePinStore';
import { FavoritesStore } from '../data/FavoritesStore';
import { IdentityManager } from '../service/identity/IdentityManager';
import { SpamFilterPreferences } from '../service/mesh/SpamFilterPreferences';
import { NostrRelayManager } from '../service/nostr/NostrRelayManager';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { BackgroundTaskCoordinator } from './BackgroundTaskCoordinator';
import { MessageNotificationDispatcher } from '../common/MessageNotificationDispatcher';

const DOMAIN = 0x0000;
const TAG = 'EntryAbility';

const ONBOARDING_COMPLETED_KEY = 'onboarding_completed';
const PAGE_MAIN = 'pages/ChatPage';
const PAGE_ONBOARDING = 'pages/OnboardingPage';

export default class EntryAbility extends UIAbility {
  /** Ability context for UI-side calls (openLink, T041); set in onCreate. */
  private static uiAbilityContext: common.UIAbilityContext | null = null;

  /**
   * Cold-start clock origin (T079, SC-007): onCreate timestamp; the
   * loadContent callback logs the delta so acceptance can grep
   * ColdStartReady against the 5000 ms budget.
   */
  private static bootStartMs: number = 0;

  /** Nullable getter: callers render a graceful no-op before onCreate completes. */
  static getUiAbilityContext(): common.UIAbilityContext | null {
    return EntryAbility.uiAbilityContext;
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    EntryAbility.bootStartMs = Date.now();
    EntryAbility.uiAbilityContext = this.context;
    // Continuous task + persistent mesh notification (T045) context.
    BackgroundTaskCoordinator.getInstance().init(this.context);
    // Message notification dispatcher (T046): context for wantAgent wants,
    // plus the cold-start deep link when launched from a notification.
    MessageNotificationDispatcher.getInstance().init(this.context);
    MessageNotificationDispatcher.getInstance().handleWant(want);
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  /** Warm start (singleton launch): a notification tap re-routes here (T046). */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    MessageNotificationDispatcher.getInstance().handleWant(want);
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onNewWant');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');
    this.bootstrap(windowStage);
  }

  /**
   * T079 (SC-007 cold start <= 5 s): the three independent singletons -
   * preferences, private-chat store, identity (HUKS) - start together and
   * only the PreferenceStore-backed loads wait for the preferences store;
   * the wall clock approaches the slowest init instead of their sum.
   */
  private async bootstrap(windowStage: window.WindowStage): Promise<void> {
    const prefsReady: Promise<void> = EntryAbility.logOnInitFailure(
      PreferenceStore.getInstance().init(this.context), 'PreferenceStore init failed');
    const conversationReady: Promise<void> = EntryAbility.logOnInitFailure(
      ConversationStore.getInstance().init(this.context), 'ConversationStore init failed');
    const identityReady: Promise<void> = EntryAbility.logOnInitFailure(
      IdentityManager.getInstance().initialize(), 'Identity init failed');
    await prefsReady;

    // Spam filter toggles (T038) and appearance settings (T042) both ride
    // the typed PreferenceStore facade, so they start after the store and
    // run concurrently with each other.
    const spamReady: Promise<void> = EntryAbility.logOnInitFailure(
      SpamFilterPreferences.getInstance().init(), 'SpamFilterPreferences init failed');
    const settingsReady: Promise<void> = EntryAbility.logOnInitFailure(
      SettingsPreferences.getInstance().init(this.context), 'SettingsPreferences init failed');
    await spamReady;
    await settingsReady;

    ChatViewModel.getInstance()
      .setBubblesMode(SettingsPreferences.getInstance().isBubblesMode());

    // SOCKS proxy parameterization (T072, US15): apply the persisted
    // OFF/custom choice to the Nostr relay transport before any relay
    // connection is attempted; a custom proxy suppresses direct
    // connections fail-closed (开启后禁止直连) and reserves the Arti
    // integration point.
    NostrRelayManager.shared.applySocksProxy(
      SettingsPreferences.getInstance().getSocksProxyMode(),
      SettingsPreferences.getInstance().getSocksProxyHost(),
      SettingsPreferences.getInstance().getSocksProxyPort());

    // Media sandbox roots (T050): capture filesDir/cacheDir before any
    // media save/panic sweep runs.
    try {
      MediaFileStore.getInstance().init(this.context);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'MediaFileStore init failed: %{public}s', JSON.stringify(e));
    }

    // Live voice receive root (US14, T069): capture cacheDir before any
    // push-to-talk burst starts streaming ADTS into files/incoming.
    try {
      LiveVoiceManager.getInstance().init(this.context);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'LiveVoiceManager init failed: %{public}s', JSON.stringify(e));
    }

    // Authenticated peer-state pin store (T053): capture filesDir before
    // any 0x21 exchange persists a pin.
    try {
      PeerStatePinStore.getInstance().init(this.context);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'PeerStatePinStore init failed: %{public}s', JSON.stringify(e));
    }

    // Encrypted favorites documents (US11): capture filesDir and load the
    // relationships + peerID->npub index before any page renders.
    try {
      FavoritesStore.getInstance().init(this.context);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'FavoritesStore init failed: %{public}s', JSON.stringify(e));
    }

    let onboarded: boolean = false;
    try {
      onboarded = await PreferenceStore.getInstance().getBoolean(ONBOARDING_COMPLETED_KEY, false);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'Read onboarding flag failed: %{public}s', JSON.stringify(e));
    }

    await conversationReady;
    await identityReady;

    const landing: string = onboarded ? PAGE_MAIN : PAGE_ONBOARDING;
    windowStage.loadContent(landing, (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG,
        'ColdStartReady: %{public}d ms (SC-007 budget 5000) landing=%{public}s',
        Date.now() - EntryAbility.bootStartMs, landing);
    });
  }

  /**
   * Log-and-swallow wrapper so concurrently started inits never surface as
   * unhandled rejections while the bootstrap awaits its dependency order.
   */
  private static logOnInitFailure(init: Promise<void>, message: string): Promise<void> {
    return init.catch((e: BusinessError): void => {
      hilog.error(DOMAIN, TAG, '%{public}s: %{public}s', message, JSON.stringify(e));
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Foregrounded chats render on screen: private/mention notifications
    // resume their viewing-aware suppression (T046).
    MessageNotificationDispatcher.getInstance().setAppBackground(false);
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Backgrounded: incoming private messages / mentions notify (T046).
    MessageNotificationDispatcher.getInstance().setAppBackground(true);
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
  }
}
