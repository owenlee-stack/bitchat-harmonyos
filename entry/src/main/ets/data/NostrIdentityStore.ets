/**
 * Persistent Nostr identity (US12, T060; Android NostrIdentityBridge
 * parity).
 *
 * The 32-byte secp256k1 private key is stored as a raw secret in the
 * system Asset Store under the alias below (owner-only, never synced,
 * wiped by SecureKeyStore.panicWipe together with every other app
 * secret). getOrCreate shares the in-flight creation Promise so
 * concurrent callers cannot mint two identities, and a corrupt stored
 * key is discarded and regenerated instead of surfacing.
 *
 * clearCache only drops the in-memory copy (panic path); the persisted
 * key is removed by the SecureKeyStore panic wipe that always follows.
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ByteUtils } from '../common/ByteUtils';
import { NostrIdentity } from '../service/nostr/NostrIdentity';
import { NostrRandomSource } from '../service/nostr/NostrRandomSource';
import { SecureKeyStore } from './SecureKeyStore';

const DOMAIN = 0x0000;
const STORE_TAG = 'NostrIdentityStore';
const KEY_ALIAS = 'nostr_private_key_v1';

/** Crypto-secure NostrRandomSource backed by the device CSPRNG. */
export class DeviceNostrRandomSource implements NostrRandomSource {
  nextBytes(count: number): Uint8Array {
    return cryptoFramework.createRandom().generateRandomSync(count).data;
  }

  nextInt(bound: number): number {
    if (bound <= 0) {
      throw new Error('bound must be positive');
    }
    // 4-byte rejection sampling avoids modulo bias.
    const limit: number = Math.floor(0x100000000 / bound) * bound;
    while (true) {
      const bytes: Uint8Array = this.nextBytes(4);
      let value: number = 0;
      for (let i: number = 0; i < 4; i++) {
        value = value * 256 + (bytes[i] & 0xFF);
      }
      if (value < limit) {
        return value % bound;
      }
    }
  }
}

export class NostrIdentityStore {
  private static instance: NostrIdentityStore | null = null;
  private cached: NostrIdentity | null = null;
  private creationPromise: Promise<NostrIdentity> | null = null;

  static getInstance(): NostrIdentityStore {
    if (NostrIdentityStore.instance === null) {
      NostrIdentityStore.instance = new NostrIdentityStore();
    }
    return NostrIdentityStore.instance;
  }

  /** Load the persisted identity or generate and persist a fresh one. */
  async getOrCreate(): Promise<NostrIdentity> {
    if (this.cached !== null) {
      return this.cached;
    }
    if (this.creationPromise === null) {
      this.creationPromise = this.loadOrCreate();
      this.creationPromise.catch((): void => {
        this.creationPromise = null;
      });
    }
    return this.creationPromise;
  }

  /** Drop the in-memory copy (panic path; persisted key goes via panicWipe). */
  clearCache(): void {
    this.cached = null;
    this.creationPromise = null;
  }

  private async loadOrCreate(): Promise<NostrIdentity> {
    const store: SecureKeyStore = SecureKeyStore.getInstance();
    const existing: Uint8Array | null = await store.getKey(KEY_ALIAS);
    if (existing !== null && existing.length === 32) {
      try {
        const identity: NostrIdentity =
          NostrIdentity.fromPrivateKey(ByteUtils.bytesToHex(existing), Date.now());
        this.cached = identity;
        return identity;
      } catch (e) {
        hilog.warn(DOMAIN, STORE_TAG, '%{public}s',
          'corrupt nostr private key; regenerating');
        await store.removeKey(KEY_ALIAS);
      }
    }
    const identity: NostrIdentity =
      NostrIdentity.generate(new DeviceNostrRandomSource(), Date.now());
    await store.putKey(KEY_ALIAS, ByteUtils.hexToBytes(identity.privateKeyHex));
    this.cached = identity;
    return identity;
  }
}
