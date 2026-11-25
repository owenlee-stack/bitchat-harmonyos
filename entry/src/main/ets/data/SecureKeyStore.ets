/**
 * Secure storage facade (D3).
 *
 * Identity secrets (Noise static key, Ed25519 signing key, device seed) are
 * stored in the system Asset Store: OS-level encryption, owner-only access,
 * never synced (SYNC_TYPE NEVER) and never part of app backups (on top of the
 * deny-by-default backup_config.json asserted by BackupExclusionContract).
 *
 * Derived app data (outbox ciphertext, carried mail, history caches,
 * conversation payloads) is sealed with a non-exportable AES-256-GCM key held
 * inside HUKS. Envelope layout, version 1:
 *   [1B version = 0x01][12B nonce][ciphertext][16B GCM tag]
 *
 * Panic surface: panicWipe() removes every app-owned Asset Store entry and
 * deletes the HUKS key. The T043 orchestrator invokes it as the
 * "clear cryptographic data" stage and reports system_panic_incomplete if it
 * fails.
 */
import { asset } from '@kit.AssetStoreKit';
import { huks } from '@kit.UniversalKeystoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ByteUtils } from '../common/ByteUtils';

const DOMAIN = 0x0000;
const STORE_TAG = 'SecureKeyStore';

const HUKS_KEY_ALIAS = 'bitchat_app_aes256_gcm_v1';
const AEAD_VERSION = 0x01;
const NONCE_LENGTH = 12;
const GCM_TAG_LENGTH = 16;
const CHUNK_SIZE = 64 * 1024;
const ASSET_NOT_FOUND = 24000002;
const ASSET_PAGE_SIZE = 40;
/** HUKS GCM mandates authenticated data; a fixed constant binds blobs to this facade. */
const AEAD_AAD: Uint8Array = ByteUtils.utf8Encode('bitchat-harmonyos/aead/v1');

/** Thrown by SecureKeyStore so callers can inspect the underlying SDK error code. */
export class SecureStoreError extends Error {
  readonly code: number;

  constructor(code: number, message: string) {
    super(message);
    this.name = 'SecureStoreError';
    this.code = code;
  }
}

export class SecureKeyStore {
  private static instance: SecureKeyStore | null = null;
  private keyEnsurePromise: Promise<void> | null = null;

  static getInstance(): SecureKeyStore {
    if (SecureKeyStore.instance === null) {
      SecureKeyStore.instance = new SecureKeyStore();
    }
    return SecureKeyStore.instance;
  }

  // ------------------------------------------------------------------
  // Asset Store: identity secrets
  // ------------------------------------------------------------------

  /** Upsert a secret under an app-unique alias (update-then-add; never synced). */
  async putKey(alias: string, secret: Uint8Array): Promise<void> {
    const aliasBytes: Uint8Array = ByteUtils.utf8Encode(alias);
    const updateQuery: asset.AssetMap = new Map();
    updateQuery.set(asset.Tag.ALIAS, aliasBytes);
    const updateAttrs: asset.AssetMap = new Map();
    updateAttrs.set(asset.Tag.SECRET, secret);
    try {
      await asset.update(updateQuery, updateAttrs);
      return;
    } catch (e) {
      const err = e as BusinessError;
      if (err.code !== ASSET_NOT_FOUND) {
        throw new SecureStoreError(err.code, err.message);
      }
    }
    const addAttrs: asset.AssetMap = new Map();
    addAttrs.set(asset.Tag.ALIAS, aliasBytes);
    addAttrs.set(asset.Tag.SECRET, secret);
    addAttrs.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    await asset.add(addAttrs);
  }

  /** Read a stored secret; null when absent. */
  async getKey(alias: string): Promise<Uint8Array | null> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, ByteUtils.utf8Encode(alias));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const result: Array<asset.AssetMap> = await asset.query(query);
      if (result.length === 0) {
        return null;
      }
      const value: asset.Value | undefined = result[0].get(asset.Tag.SECRET);
      if (value === undefined || typeof value === 'boolean' || typeof value === 'number') {
        return null;
      }
      return value;
    } catch (e) {
      const err = e as BusinessError;
      if (err.code === ASSET_NOT_FOUND) {
        return null;
      }
      throw new SecureStoreError(err.code, err.message);
    }
  }

  /** Existence probe without decrypting the secret (RETURN_TYPE ATTRIBUTES). */
  async hasKey(alias: string): Promise<boolean> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, ByteUtils.utf8Encode(alias));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ATTRIBUTES);
    try {
      const result: Array<asset.AssetMap> = await asset.query(query);
      return result.length > 0;
    } catch (e) {
      const err = e as BusinessError;
      if (err.code === ASSET_NOT_FOUND) {
        return false;
      }
      throw new SecureStoreError(err.code, err.message);
    }
  }

  /** Idempotent removal of a single secret. */
  async removeKey(alias: string): Promise<void> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, ByteUtils.utf8Encode(alias));
    try {
      await asset.remove(query);
    } catch (e) {
      const err = e as BusinessError;
      if (err.code !== ASSET_NOT_FOUND) {
        throw new SecureStoreError(err.code, err.message);
      }
    }
  }

  /** Panic stage: remove every Asset Store entry owned by this app. */
  async removeAllKeys(): Promise<void> {
    let offset: number = 1;
    while (true) {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ATTRIBUTES);
      query.set(asset.Tag.RETURN_LIMIT, ASSET_PAGE_SIZE);
      query.set(asset.Tag.RETURN_OFFSET, offset);
      const result: Array<asset.AssetMap> = await asset.query(query);
      for (let i = 0; i < result.length; i++) {
        const aliasValue: asset.Value | undefined = result[i].get(asset.Tag.ALIAS);
        if (aliasValue === undefined || typeof aliasValue === 'boolean' ||
          typeof aliasValue === 'number') {
          continue;
        }
        const removeQuery: asset.AssetMap = new Map();
        removeQuery.set(asset.Tag.ALIAS, aliasValue);
        await asset.remove(removeQuery);
      }
      if (result.length < ASSET_PAGE_SIZE) {
        break;
      }
      offset += ASSET_PAGE_SIZE;
    }
  }

  // ------------------------------------------------------------------
  // HUKS: derived-data AES-256-GCM
  // ------------------------------------------------------------------

  private ensureDerivedKey(): Promise<void> {
    if (this.keyEnsurePromise === null) {
      this.keyEnsurePromise = this.doEnsureDerivedKey();
      this.keyEnsurePromise.catch(() => {
        this.keyEnsurePromise = null;
      });
    }
    return this.keyEnsurePromise;
  }

  private async doEnsureDerivedKey(): Promise<void> {
    const opts: huks.HuksOptions = { properties: [] };
    const exists: boolean = await huks.hasKeyItem(HUKS_KEY_ALIAS, opts);
    if (!exists) {
      const genProps: huks.HuksParam[] = [
        {
          tag: huks.HuksTag.HUKS_TAG_ALGORITHM,
          value: huks.HuksKeyAlg.HUKS_ALG_AES
        },
        {
          tag: huks.HuksTag.HUKS_TAG_KEY_SIZE,
          value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256
        },
        {
          tag: huks.HuksTag.HUKS_TAG_PURPOSE,
          value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT |
            huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT
        }
      ];
      await huks.generateKeyItem(HUKS_KEY_ALIAS, { properties: genProps });
    }
  }

  /** Delete the HUKS AES-GCM key (idempotent). */
  async removeDerivedKey(): Promise<void> {
    const opts: huks.HuksOptions = { properties: [] };
    const exists: boolean = await huks.hasKeyItem(HUKS_KEY_ALIAS, opts);
    if (exists) {
      await huks.deleteKeyItem(HUKS_KEY_ALIAS, opts);
    }
    this.keyEnsurePromise = null;
  }

  /**
   * Seal bytes with the HUKS AES-256-GCM key.
   * Output: [version][nonce 12][ciphertext][tag 16].
   */
  async encryptData(plain: Uint8Array): Promise<Uint8Array> {
    await this.ensureDerivedKey();
    const nonce: Uint8Array = cryptoFramework.createRandom()
      .generateRandomSync(NONCE_LENGTH).data;
    const props: huks.HuksParam[] = this.encryptProps(nonce);
    const session: huks.HuksSessionHandle = await huks.initSession(
      HUKS_KEY_ALIAS, { properties: props });
    const parts: Uint8Array[] = [];
    let offset: number = 0;
    while (plain.length - offset > CHUNK_SIZE) {
      const chunk: Uint8Array = plain.subarray(offset, offset + CHUNK_SIZE);
      const updated: huks.HuksReturnResult = await huks.updateSession(
        session.handle, { properties: props, inData: chunk });
      if (updated.outData !== undefined) {
        parts.push(updated.outData);
      }
      offset += CHUNK_SIZE;
    }
    const tail: Uint8Array = plain.subarray(offset);
    const finished: huks.HuksReturnResult = await huks.finishSession(
      session.handle, { properties: props, inData: tail });
    if (finished.outData !== undefined) {
      parts.push(finished.outData);
    }
    const body: Uint8Array = SecureKeyStore.concat(parts);
    const out: Uint8Array = new Uint8Array(1 + NONCE_LENGTH + body.length);
    out[0] = AEAD_VERSION;
    out.set(nonce, 1);
    out.set(body, 1 + NONCE_LENGTH);
    return out;
  }

  /** Open a version-1 envelope produced by encryptData; throws on tamper. */
  async decryptData(blob: Uint8Array): Promise<Uint8Array> {
    const headerLength: number = 1 + NONCE_LENGTH;
    if (blob.length < headerLength + GCM_TAG_LENGTH) {
      throw new Error('Invalid encrypted blob');
    }
    if ((blob[0] & 0xFF) !== AEAD_VERSION) {
      throw new Error('Unsupported AEAD envelope version');
    }
    const nonce: Uint8Array = blob.subarray(1, headerLength);
    const body: Uint8Array = blob.subarray(headerLength);
    const tag: Uint8Array = body.subarray(body.length - GCM_TAG_LENGTH);
    const cipher: Uint8Array = body.subarray(0, body.length - GCM_TAG_LENGTH);
    await this.ensureDerivedKey();
    const props: huks.HuksParam[] = this.decryptProps(nonce, tag);
    const session: huks.HuksSessionHandle = await huks.initSession(
      HUKS_KEY_ALIAS, { properties: props });
    const parts: Uint8Array[] = [];
    let offset: number = 0;
    while (cipher.length - offset > CHUNK_SIZE) {
      const chunk: Uint8Array = cipher.subarray(offset, offset + CHUNK_SIZE);
      const updated: huks.HuksReturnResult = await huks.updateSession(
        session.handle, { properties: props, inData: chunk });
      if (updated.outData !== undefined) {
        parts.push(updated.outData);
      }
      offset += CHUNK_SIZE;
    }
    const tail: Uint8Array = cipher.subarray(offset);
    const finished: huks.HuksReturnResult = await huks.finishSession(
      session.handle, { properties: props, inData: tail });
    if (finished.outData !== undefined) {
      parts.push(finished.outData);
    }
    return SecureKeyStore.concat(parts);
  }

  /** Encrypt plain bytes and write the envelope to destPath atomically enough for caches. */
  async encryptFile(plain: Uint8Array, destPath: string): Promise<void> {
    const envelope: Uint8Array = await this.encryptData(plain);
    SecureKeyStore.writeWholeFile(destPath, envelope);
  }

  /** Read srcPath and open its envelope. */
  async decryptFile(srcPath: string): Promise<Uint8Array> {
    const envelope: Uint8Array = SecureKeyStore.readWholeFile(srcPath);
    return this.decryptData(envelope);
  }

  /** Panic stage "clear cryptographic data": wipe Asset entries + HUKS key. */
  async panicWipe(): Promise<void> {
    await this.removeAllKeys();
    await this.removeDerivedKey();
    hilog.warn(DOMAIN, STORE_TAG, '%{public}s', 'secure key store wiped');
  }

  // ------------------------------------------------------------------
  // Internals
  // ------------------------------------------------------------------

  private encryptProps(nonce: Uint8Array): huks.HuksParam[] {
    return [
      {
        tag: huks.HuksTag.HUKS_TAG_ALGORITHM,
        value: huks.HuksKeyAlg.HUKS_ALG_AES
      },
      {
        tag: huks.HuksTag.HUKS_TAG_KEY_SIZE,
        value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256
      },
      {
        tag: huks.HuksTag.HUKS_TAG_PURPOSE,
        value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT
      },
      {
        tag: huks.HuksTag.HUKS_TAG_PADDING,
        value: huks.HuksKeyPadding.HUKS_PADDING_NONE
      },
      {
        tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE,
        value: huks.HuksCipherMode.HUKS_MODE_GCM
      },
      {
        tag: huks.HuksTag.HUKS_TAG_NONCE,
        value: nonce
      },
      {
        tag: huks.HuksTag.HUKS_TAG_ASSOCIATED_DATA,
        value: AEAD_AAD
      }
    ];
  }

  private decryptProps(nonce: Uint8Array, tag: Uint8Array): huks.HuksParam[] {
    return [
      {
        tag: huks.HuksTag.HUKS_TAG_ALGORITHM,
        value: huks.HuksKeyAlg.HUKS_ALG_AES
      },
      {
        tag: huks.HuksTag.HUKS_TAG_KEY_SIZE,
        value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256
      },
      {
        tag: huks.HuksTag.HUKS_TAG_PURPOSE,
        value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT
      },
      {
        tag: huks.HuksTag.HUKS_TAG_PADDING,
        value: huks.HuksKeyPadding.HUKS_PADDING_NONE
      },
      {
        tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE,
        value: huks.HuksCipherMode.HUKS_MODE_GCM
      },
      {
        tag: huks.HuksTag.HUKS_TAG_NONCE,
        value: nonce
      },
      {
        tag: huks.HuksTag.HUKS_TAG_ASSOCIATED_DATA,
        value: AEAD_AAD
      },
      {
        tag: huks.HuksTag.HUKS_TAG_AE_TAG,
        value: tag
      }
    ];
  }

  private static concat(parts: Uint8Array[]): Uint8Array {
    let total: number = 0;
    for (let i = 0; i < parts.length; i++) {
      total += parts[i].length;
    }
    const out: Uint8Array = new Uint8Array(total);
    let pos: number = 0;
    for (let i = 0; i < parts.length; i++) {
      out.set(parts[i], pos);
      pos += parts[i].length;
    }
    return out;
  }

  private static readWholeFile(path: string): Uint8Array {
    const stat: fileIo.Stat = fileIo.statSync(path);
    const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const size: number = stat.size;
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      if (size > 0) {
        fileIo.readSync(file.fd, buffer);
      }
      return new Uint8Array(buffer);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private static writeWholeFile(path: string, data: Uint8Array): void {
    const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE |
      fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      if (data.byteLength > 0) {
        fileIo.writeSync(file.fd, SecureKeyStore.toExactBuffer(data));
      }
    } finally {
      fileIo.closeSync(file);
    }
  }

  private static toExactBuffer(data: Uint8Array): ArrayBuffer {
    if (data.byteOffset === 0 && data.byteLength === data.buffer.byteLength) {
      return data.buffer;
    }
    const buffer: ArrayBuffer = new ArrayBuffer(data.byteLength);
    const view: Uint8Array = new Uint8Array(buffer);
    view.set(data, 0);
    return buffer;
  }
}
