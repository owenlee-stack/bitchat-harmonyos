/**
 * Device identity manager (US1, plan.md service contract).
 *
 * Owns the two long-term key pairs created on first launch:
 *  - Noise static X25519 key pair (32-byte raw keys; public via pure-ArkTS
 *    Curve25519, matching noise-java generation semantics),
 *  - Ed25519 signing key pair (cryptoFramework, raw 32-byte keys stored after
 *    DER unwrap so wire formats stay identical to Android/iOS).
 *
 * Wire identity: peerID = SHA-256(noiseStaticPublic)[0..8] hex (16 chars,
 * NoisePeerIdentity.derivePeerID); fingerprint = full SHA-256 hex of the same
 * key. Keys persist through SecureKeyStore (Asset Store, D3); the nickname
 * (<= UiConstants.MAX_NICKNAME_LENGTH chars, default anon<1000-9999>) persists
 * through PreferenceStore, mirroring Android DataManager.loadNickname.
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ByteUtils } from '../../common/ByteUtils';
import { UiConstants } from '../../common/ProtocolConstants';
import { Curve25519 } from '../noise/Curve25519';
import { NoisePeerIdentity } from '../noise/NoisePeerIdentity';
import { SecureKeyStore } from '../../data/SecureKeyStore';
import { PreferenceStore } from '../../data/PreferenceStore';

const DOMAIN = 0x0000;
const STORE_TAG = 'IdentityManager';

const KEY_ALIAS_NOISE_PRIVATE = 'bitchat.identity.noise_static_private';
const KEY_ALIAS_NOISE_PUBLIC = 'bitchat.identity.noise_static_public';
const KEY_ALIAS_SIGNING_PRIVATE = 'bitchat.identity.signing_private';
const KEY_ALIAS_SIGNING_PUBLIC = 'bitchat.identity.signing_public';
const NICKNAME_PREF_KEY = 'nickname';
const RAW_KEY_LENGTH = 32;
/** Random.nextInt(1000, 9999) equivalent: 1000..9998 inclusive. */
const ANON_MIN = 1000;
const ANON_RANGE = 8999;

/** One panic-wipe stage (T043; order matches Android performPanicClearAllData). */
export enum PanicWipeStage {
  STOP_SERVICES = 'stop_services',
  CLEAR_PRIVATE_MEDIA_CONSENT = 'clear_private_media_consent',
  STOP_ADMISSION = 'stop_admission',
  DELETE_CONVERSATION_STORE = 'delete_conversation_store',
  CLEAR_UI_STATE = 'clear_ui_state',
  CLEAR_DEDUP_AND_OUTBOX = 'clear_dedup_and_outbox',
  CLEAR_SPAM_FILTER = 'clear_spam_filter',
  CLEAR_CRYPTO_DATA = 'clear_crypto_data',
  CLEAR_NOTIFICATIONS = 'clear_notifications',
  DELETE_MEDIA = 'delete_media',
  CLEAR_NOSTR_GEOHASH = 'clear_nostr_geohash',
  CLEAR_FAVORITES = 'clear_favorites',
  RESET_NICKNAME = 'reset_nickname',
  REBUILD_IDENTITY = 'rebuild_identity'
}

/** Confirmation of one panic-wipe stage. */
export class PanicWipeStageResult {
  readonly stage: PanicWipeStage;
  readonly success: boolean;

  constructor(stage: PanicWipeStage, success: boolean) {
    this.stage = stage;
    this.success = success;
  }
}

/** Panic-wipe outcome: per-stage confirmations plus the rebuilt identity. */
export class PanicWipeResult {
  /** Every stage in execution order; REBUILD_IDENTITY is absent when the
   * conversation database could not prove its wipe (services stay down). */
  readonly stages: PanicWipeStageResult[];
  /** True only when every stage confirmed its wipe. */
  readonly completed: boolean;
  /** True when the conversation database wipe failed: the success message is
   * a security assurance, so privacy wins over availability and the mesh is
   * not restarted. */
  readonly criticalFailure: boolean;
  readonly oldPeerId: string;
  readonly newPeerId: string;

  constructor(stages: PanicWipeStageResult[], completed: boolean, criticalFailure: boolean,
    oldPeerId: string, newPeerId: string) {
    this.stages = stages;
    this.completed = completed;
    this.criticalFailure = criticalFailure;
    this.oldPeerId = oldPeerId;
    this.newPeerId = newPeerId;
  }
}

/**
 * Service-side panic stages the identity orchestrator cannot reach on its
 * own (mesh graph, stores, filters). Implemented by ChatViewModel; stubs
 * (media, notifications, Nostr/geohash, favorites) stay confirmed no-ops
 * until their phases land.
 */
export interface PanicWipeDelegate {
  panicStopServices(): boolean;
  panicClearPrivateMediaConsent(): boolean;
  panicStopAdmission(): boolean;
  panicDeleteConversationStore(): Promise<boolean>;
  panicClearUiState(): Promise<boolean>;
  panicClearDedupAndOutbox(): boolean;
  panicClearSpamFilter(): boolean;
  panicClearNotifications(): boolean;
  panicDeleteMedia(): boolean;
  panicClearNostrGeohash(): boolean;
  panicClearFavorites(): boolean;
  panicResetNickname(): Promise<boolean>;
  panicRestartMesh(): Promise<boolean>;
}

/** PKCS#8 v2 header for a raw Ed25519 seed: 302e020100300506032b657e04220420. */
const ED25519_PKCS8_PREFIX: number[] = [
  0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x7e, 0x04, 0x22, 0x04, 0x20
];
/** X.509 SubjectPublicKeyInfo header for a raw Ed25519 public key: 302a300506032b657e032100. */
const ED25519_SPKI_PREFIX: number[] = [
  0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x7e, 0x03, 0x21, 0x00
];

export class IdentityManager {
  private static instance: IdentityManager | null = null;

  private noisePrivateKey: Uint8Array = new Uint8Array(0);
  private noisePublicKey: Uint8Array = new Uint8Array(0);
  private signingPrivateKey: Uint8Array = new Uint8Array(0);
  private signingPublicKey: Uint8Array = new Uint8Array(0);
  private initialized: boolean = false;
  private initPromise: Promise<void> | null = null;

  static getInstance(): IdentityManager {
    if (IdentityManager.instance === null) {
      IdentityManager.instance = new IdentityManager();
    }
    return IdentityManager.instance;
  }

  /** Idempotent; concurrent calls share one load-or-generate pass. */
  initialize(): Promise<void> {
    if (this.initPromise === null) {
      this.initPromise = this.doInitialize();
    }
    return this.initPromise;
  }

  isInitialized(): boolean {
    return this.initialized;
  }

  /** 16 lowercase hex chars: SHA-256(noise static public)[0..8]. */
  getPeerId(): string {
    this.assertInitialized();
    const peerId: string | null = NoisePeerIdentity.derivePeerID(this.noisePublicKey);
    if (peerId === null) {
      throw new Error('Corrupt Noise static key');
    }
    return peerId;
  }

  /** Full SHA-256 hex fingerprint of the Noise static public key. */
  getIdentityFingerprint(): string {
    this.assertInitialized();
    return ByteUtils.bytesToHex(ByteUtils.sha256(this.noisePublicKey));
  }

  getStaticPublicKey(): Uint8Array {
    this.assertInitialized();
    return this.noisePublicKey.slice();
  }

  getStaticPrivateKey(): Uint8Array {
    this.assertInitialized();
    return this.noisePrivateKey.slice();
  }

  getSigningPublicKey(): Uint8Array {
    this.assertInitialized();
    return this.signingPublicKey.slice();
  }

  /** Load the nickname, generating and persisting anon<1000-9999> on first read. */
  async getNickname(): Promise<string> {
    const prefs = PreferenceStore.getInstance();
    const saved: string = await prefs.getString(NICKNAME_PREF_KEY, '');
    if (saved !== '') {
      return saved;
    }
    const generated: string = 'anon' + (ANON_MIN + Math.floor(Math.random() * ANON_RANGE));
    await prefs.setString(NICKNAME_PREF_KEY, generated);
    return generated;
  }

  /** Rejects blank or over-length nicknames; returns false without persisting. */
  async setNickname(nickname: string): Promise<boolean> {
    const trimmed: string = nickname.trim();
    if (trimmed.length === 0 || trimmed.length > UiConstants.MAX_NICKNAME_LENGTH) {
      return false;
    }
    await PreferenceStore.getInstance().setString(NICKNAME_PREF_KEY, trimmed);
    return true;
  }

  /** Ed25519 signature over data with the persistent signing key; null on failure. */
  async sign(data: Uint8Array): Promise<Uint8Array | null> {
    this.assertInitialized();
    try {
      const generator = cryptoFramework.createAsyKeyGenerator('Ed25519');
      const keyPair: cryptoFramework.KeyPair = await generator.convertKey(
        IdentityManager.dataBlob(IdentityManager.spkiWrap(this.signingPublicKey)),
        IdentityManager.dataBlob(IdentityManager.pkcs8Wrap(this.signingPrivateKey)));
      const signer = cryptoFramework.createSign('Ed25519');
      await signer.init(keyPair.priKey);
      const signature = await signer.sign(IdentityManager.dataBlob(data));
      return signature.data;
    } catch (e) {
      hilog.error(DOMAIN, STORE_TAG, 'sign failed: %{public}s', JSON.stringify(e));
      return null;
    }
  }

  /** Ed25519 verification of a raw 32-byte public key; false on any failure. */
  async verify(signature: Uint8Array, data: Uint8Array, publicKey: Uint8Array): Promise<boolean> {
    if (publicKey.length !== RAW_KEY_LENGTH) {
      return false;
    }
    try {
      const generator = cryptoFramework.createAsyKeyGenerator('Ed25519');
      const keyPair: cryptoFramework.KeyPair = await generator.convertKey(
        IdentityManager.dataBlob(IdentityManager.spkiWrap(publicKey)), null);
      const verifier = cryptoFramework.createVerify('Ed25519');
      await verifier.init(keyPair.pubKey);
      return await verifier.verify(IdentityManager.dataBlob(data),
        IdentityManager.dataBlob(signature));
    } catch (e) {
      hilog.error(DOMAIN, STORE_TAG, 'verify failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  /**
   * Synchronous Ed25519 signature over data with the persistent signing
   * key (cryptoFramework sync series, API 12+). Feeds the synchronous
   * private-media preparation path, where the packet must be finalized
   * and signed inside one prepare call; null on any failure.
   */
  signSync(data: Uint8Array): Uint8Array | null {
    this.assertInitialized();
    try {
      const generator = cryptoFramework.createAsyKeyGenerator('Ed25519');
      const keyPair: cryptoFramework.KeyPair = generator.convertKeySync(
        IdentityManager.dataBlob(IdentityManager.spkiWrap(this.signingPublicKey)),
        IdentityManager.dataBlob(IdentityManager.pkcs8Wrap(this.signingPrivateKey)));
      const signer = cryptoFramework.createSign('Ed25519');
      signer.initSync(keyPair.priKey);
      return signer.signSync(IdentityManager.dataBlob(data)).data;
    } catch (e) {
      hilog.error(DOMAIN, STORE_TAG, 'signSync failed: %{public}s', JSON.stringify(e));
      return null;
    }
  }

  /**
   * Synchronous Ed25519 verification for the packet-processing hot path
   * (cryptoFramework sync series, API 12+); false on any failure.
   */
  verifySync(signature: Uint8Array, data: Uint8Array, publicKey: Uint8Array): boolean {
    if (publicKey.length !== RAW_KEY_LENGTH) {
      return false;
    }
    try {
      const generator = cryptoFramework.createAsyKeyGenerator('Ed25519');
      const keyPair: cryptoFramework.KeyPair = generator.convertKeySync(
        IdentityManager.dataBlob(IdentityManager.spkiWrap(publicKey)), null);
      const verifier = cryptoFramework.createVerify('Ed25519');
      verifier.initSync(keyPair.pubKey);
      return verifier.verifySync(IdentityManager.dataBlob(data),
        IdentityManager.dataBlob(signature));
    } catch (e) {
      return false;
    }
  }

  // ------------------------------------------------------------------
  // Panic wipe (T043)
  // ------------------------------------------------------------------

  /**
   * Staged emergency wipe (Android performPanicClearAllData parity):
   * stop services -> clear private-media consent -> stop admission ->
   * drop the conversation database -> clear UI state -> clear dedup/outbox
   * -> reset the spam filter -> wipe cryptographic data -> clear
   * notifications -> delete media -> clear Nostr/geohash -> clear
   * favorites -> reset the nickname (anon<1000-9999>) -> rebuild the
   * identity and restart the mesh.
   *
   * Every stage reports its own confirmation; `completed` requires all of
   * them. A failed conversation-database wipe is critical: privacy wins
   * over availability, so the mesh stays down and the result reports
   * criticalFailure (the UI shows system_panic_incomplete).
   */
  async panicWipe(delegate: PanicWipeDelegate): Promise<PanicWipeResult> {
    hilog.warn(DOMAIN, STORE_TAG, '%{public}s', 'PANIC MODE ACTIVATED - wiping all data');
    const stages: PanicWipeStageResult[] = [];
    const oldPeerId: string = this.initialized ? this.getPeerId() : '';
    let wipeComplete = true;

    if (!IdentityManager.runStage(stages, PanicWipeStage.STOP_SERVICES,
      (): boolean => delegate.panicStopServices())) {
      wipeComplete = false;
    }
    if (!IdentityManager.runStage(stages, PanicWipeStage.CLEAR_PRIVATE_MEDIA_CONSENT,
      (): boolean => delegate.panicClearPrivateMediaConsent())) {
      wipeComplete = false;
    }
    if (!IdentityManager.runStage(stages, PanicWipeStage.STOP_ADMISSION,
      (): boolean => delegate.panicStopAdmission())) {
      wipeComplete = false;
    }
    const conversationsCleared: boolean =
      await IdentityManager.runAsyncStage(stages, PanicWipeStage.DELETE_CONVERSATION_STORE,
        (): Promise<boolean> => delegate.panicDeleteConversationStore());
    if (!conversationsCleared) {
      wipeComplete = false;
    }
    if (!await IdentityManager.runAsyncStage(stages, PanicWipeStage.CLEAR_UI_STATE,
      (): Promise<boolean> => delegate.panicClearUiState())) {
      wipeComplete = false;
    }
    if (!IdentityManager.runStage(stages, PanicWipeStage.CLEAR_DEDUP_AND_OUTBOX,
      (): boolean => delegate.panicClearDedupAndOutbox())) {
      wipeComplete = false;
    }
    if (!IdentityManager.runStage(stages, PanicWipeStage.CLEAR_SPAM_FILTER,
      (): boolean => delegate.panicClearSpamFilter())) {
      wipeComplete = false;
    }
    if (!await IdentityManager.runAsyncStage(stages, PanicWipeStage.CLEAR_CRYPTO_DATA,
      (): Promise<boolean> => this.clearAllCryptographicData())) {
      wipeComplete = false;
    }
    if (!IdentityManager.runStage(stages, PanicWipeStage.CLEAR_NOTIFICATIONS,
      (): boolean => delegate.panicClearNotifications())) {
      wipeComplete = false;
    }
    if (!IdentityManager.runStage(stages, PanicWipeStage.DELETE_MEDIA,
      (): boolean => delegate.panicDeleteMedia())) {
      wipeComplete = false;
    }
    if (!IdentityManager.runStage(stages, PanicWipeStage.CLEAR_NOSTR_GEOHASH,
      (): boolean => delegate.panicClearNostrGeohash())) {
      wipeComplete = false;
    }
    if (!IdentityManager.runStage(stages, PanicWipeStage.CLEAR_FAVORITES,
      (): boolean => delegate.panicClearFavorites())) {
      wipeComplete = false;
    }
    if (!await IdentityManager.runAsyncStage(stages, PanicWipeStage.RESET_NICKNAME,
      (): Promise<boolean> => delegate.panicResetNickname())) {
      wipeComplete = false;
    }

    if (!conversationsCleared) {
      // Privacy wins over availability: keep private-message admission and
      // transports stopped if the database could not prove its wipe.
      hilog.error(DOMAIN, STORE_TAG, '%{public}s',
        'PANIC MODE INCOMPLETE - conversation database wipe failed');
      return new PanicWipeResult(stages, false, true, oldPeerId, '');
    }

    // Rebuild the identity: the secure key store is empty, so initialize()
    // generates fresh keys (new peer ID); then the delegate restarts the
    // mesh services with the new identity.
    let newPeerId: string = '';
    let rebuildOk: boolean = false;
    try {
      await this.initialize();
      newPeerId = this.getPeerId();
      rebuildOk = await delegate.panicRestartMesh();
    } catch (e) {
      hilog.error(DOMAIN, STORE_TAG, 'identity rebuild failed: %{public}s', JSON.stringify(e));
      rebuildOk = false;
    }
    stages.push(new PanicWipeStageResult(PanicWipeStage.REBUILD_IDENTITY, rebuildOk));
    if (!rebuildOk) {
      wipeComplete = false;
    }

    if (wipeComplete) {
      hilog.warn(DOMAIN, STORE_TAG, 'PANIC MODE COMPLETED - new identity: %{public}s', newPeerId);
    } else {
      hilog.error(DOMAIN, STORE_TAG, '%{public}s',
        'PANIC MODE INCOMPLETE - a wipe stage did not confirm');
    }
    return new PanicWipeResult(stages, wipeComplete, false, oldPeerId, newPeerId);
  }

  // ------------------------------------------------------------------
  // Internals
  // ------------------------------------------------------------------

  /** Panic stage "clear cryptographic data": Asset entries + HUKS key + memory. */
  private async clearAllCryptographicData(): Promise<boolean> {
    try {
      await SecureKeyStore.getInstance().panicWipe();
    } catch (e) {
      hilog.error(DOMAIN, STORE_TAG, 'crypto wipe failed: %{public}s', JSON.stringify(e));
      return false;
    }
    this.noisePrivateKey = new Uint8Array(0);
    this.noisePublicKey = new Uint8Array(0);
    this.signingPrivateKey = new Uint8Array(0);
    this.signingPublicKey = new Uint8Array(0);
    this.initialized = false;
    this.initPromise = null;
    return true;
  }

  /** Run one synchronous stage; a throw counts as failure, never aborts the wipe. */
  private static runStage(stages: PanicWipeStageResult[], stage: PanicWipeStage,
    action: () => boolean): boolean {
    let success: boolean = false;
    try {
      success = action();
    } catch (e) {
      hilog.error(DOMAIN, STORE_TAG, 'panic stage %{public}s failed: %{public}s',
        stage, JSON.stringify(e));
    }
    stages.push(new PanicWipeStageResult(stage, success));
    return success;
  }

  /** Run one asynchronous stage; a throw counts as failure, never aborts the wipe. */
  private static async runAsyncStage(stages: PanicWipeStageResult[], stage: PanicWipeStage,
    action: () => Promise<boolean>): Promise<boolean> {
    let success: boolean = false;
    try {
      success = await action();
    } catch (e) {
      hilog.error(DOMAIN, STORE_TAG, 'panic stage %{public}s failed: %{public}s',
        stage, JSON.stringify(e));
    }
    stages.push(new PanicWipeStageResult(stage, success));
    return success;
  }

  private async doInitialize(): Promise<void> {
    const store = SecureKeyStore.getInstance();

    let noisePrivate: Uint8Array | null = await store.getKey(KEY_ALIAS_NOISE_PRIVATE);
    let noisePublic: Uint8Array | null = await store.getKey(KEY_ALIAS_NOISE_PUBLIC);
    if (noisePrivate === null || noisePublic === null ||
      noisePrivate.length !== RAW_KEY_LENGTH || noisePublic.length !== RAW_KEY_LENGTH) {
      noisePrivate = cryptoFramework.createRandom().generateRandomSync(RAW_KEY_LENGTH).data;
      noisePublic = Curve25519.publicKeyFromPrivateKey(noisePrivate);
      await store.putKey(KEY_ALIAS_NOISE_PRIVATE, noisePrivate);
      await store.putKey(KEY_ALIAS_NOISE_PUBLIC, noisePublic);
    }

    let signingPrivate: Uint8Array | null = await store.getKey(KEY_ALIAS_SIGNING_PRIVATE);
    let signingPublic: Uint8Array | null = await store.getKey(KEY_ALIAS_SIGNING_PUBLIC);
    if (signingPrivate === null || signingPublic === null ||
      signingPrivate.length !== RAW_KEY_LENGTH || signingPublic.length !== RAW_KEY_LENGTH) {
      const generated: cryptoFramework.KeyPair =
        await cryptoFramework.createAsyKeyGenerator('Ed25519').generateKeyPair();
      signingPrivate = IdentityManager.rawFromPkcs8(generated.priKey.getEncoded().data);
      signingPublic = IdentityManager.rawFromSpki(generated.pubKey.getEncoded().data);
      await store.putKey(KEY_ALIAS_SIGNING_PRIVATE, signingPrivate);
      await store.putKey(KEY_ALIAS_SIGNING_PUBLIC, signingPublic);
    }

    this.noisePrivateKey = noisePrivate;
    this.noisePublicKey = noisePublic;
    this.signingPrivateKey = signingPrivate;
    this.signingPublicKey = signingPublic;
    this.initialized = true;
    hilog.info(DOMAIN, STORE_TAG, 'identity ready, peerId=%{public}s', this.getPeerId());
  }

  private assertInitialized(): void {
    if (!this.initialized) {
      throw new Error('IdentityManager not initialized');
    }
  }

  private static dataBlob(data: Uint8Array): cryptoFramework.DataBlob {
    const blob: cryptoFramework.DataBlob = { data: data };
    return blob;
  }

  private static spkiWrap(rawPublicKey: Uint8Array): Uint8Array {
    const out: Uint8Array = new Uint8Array(ED25519_SPKI_PREFIX.length + rawPublicKey.length);
    for (let i = 0; i < ED25519_SPKI_PREFIX.length; i++) {
      out[i] = ED25519_SPKI_PREFIX[i];
    }
    out.set(rawPublicKey, ED25519_SPKI_PREFIX.length);
    return out;
  }

  private static pkcs8Wrap(rawPrivateKey: Uint8Array): Uint8Array {
    const out: Uint8Array = new Uint8Array(ED25519_PKCS8_PREFIX.length + rawPrivateKey.length);
    for (let i = 0; i < ED25519_PKCS8_PREFIX.length; i++) {
      out[i] = ED25519_PKCS8_PREFIX[i];
    }
    out.set(rawPrivateKey, ED25519_PKCS8_PREFIX.length);
    return out;
  }

  private static rawFromSpki(der: Uint8Array): Uint8Array {
    return IdentityManager.rawFromDer(der, ED25519_SPKI_PREFIX);
  }

  private static rawFromPkcs8(der: Uint8Array): Uint8Array {
    return IdentityManager.rawFromDer(der, ED25519_PKCS8_PREFIX);
  }

  private static rawFromDer(der: Uint8Array, prefix: number[]): Uint8Array {
    if (der.length !== prefix.length + RAW_KEY_LENGTH) {
      throw new Error('Unexpected Ed25519 DER length');
    }
    for (let i = 0; i < prefix.length; i++) {
      if ((der[i] & 0xFF) !== prefix[i]) {
        throw new Error('Unexpected Ed25519 DER header');
      }
    }
    return der.slice(prefix.length);
  }
}
