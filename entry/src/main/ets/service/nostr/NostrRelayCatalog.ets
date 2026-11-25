/**
 * Relay catalog for the Nostr transport, mirroring the constants
 * scattered across bitchat-android NostrRelayManager.kt (the four
 * default relays) and NostrClient.kt / NostrDirectMessageHandler.kt
 * (the 48h gift-wrap subscription lookback and the 48h+15min message
 * acceptance bound). The geohash-scoped relay-directory CSV ships as a
 * rawfile asset (resources/rawfile/nostr_relays.csv) and is consumed
 * by the geohash feature; private messaging uses the defaults below.
 * Pure ArkTS: no @ohos/@kit imports, host-runnable by the
 * contract-test harness.
 */
export class NostrRelayCatalog {
  /** Default relays, identical to Android/iOS (all wss://). */
  static readonly DEFAULT_RELAYS: string[] = [
    'wss://relay.damus.io',
    'wss://relay.primal.net',
    'wss://offchain.pub',
    'wss://nostr21.com'
  ];

  /** Gift-wrap subscription lookback: 48 hours (aligned with NIP-17 randomization). */
  static readonly GIFT_WRAP_LOOKBACK_MS: number = 172800000;

  /** Geohash presence subscription lookback: 1 hour. */
  static readonly PRESENCE_LOOKBACK_MS: number = 3600000;

  /** Inbound message acceptance bound: 48 hours + 15 minutes, in seconds. */
  static readonly MAX_MESSAGE_AGE_SECONDS: number = 173700;
}
