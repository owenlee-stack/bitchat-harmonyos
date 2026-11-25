/**
 * Channel encryption for password-protected channels (US9, T047).
 *
 * Android NoiseChannelEncryption / iOS parity, byte-compatible wire format:
 *
 *   key  = PBKDF2-HmacSHA256(password, salt = utf8(channelName),
 *                            iterations = 100000, keySize = 32)
 *   wire = IV(12) || AES-256-GCM ciphertext || authTag(16)
 *
 * The derivation parameters, wire layout and key commitment (SHA-256 of the
 * raw key bytes, lowercase hex) match the Android/iOS implementations, so
 * clients on any platform that join the same channel with the same password
 * derive the same key and decrypt each other's traffic.
 *
 * Uses the cryptoFramework sync series (Kdf.generateSecretSync,
 * SymKeyGenerator.convertKeySync, Cipher.initSync/doFinalSync,
 * Md.updateSync/digestSync, createRandom().generateRandomSync) so the
 * synchronous mesh pipeline never blocks the UI thread on a Promise (the
 * IdentityManager verifySync precedent). Failures return null / false
 * instead of throwing; callers render a graceful error state.
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ByteUtils } from '../../common/ByteUtils';
import { ChannelCrypto } from '../mesh/ChannelManager';

const DOMAIN = 0x0000;
const TAG = 'ChannelEncryption';

/** Android/iOS PBKDF2_ITERATIONS parity. */
const PBKDF2_ITERATIONS = 100000;
/** Derived AES key length: 256-bit. */
const KEY_LENGTH_BYTES = 32;
/** AES-GCM initialization-vector length (Java AES/GCM default). */
const GCM_IV_LENGTH = 12;
/** AES-GCM authentication-tag length: 128-bit. */
const GCM_TAG_LENGTH = 16;
/** Minimum decryptable wire size: IV + tag. */
const MIN_WIRE_LENGTH = GCM_IV_LENGTH + GCM_TAG_LENGTH;

export class ChannelEncryption implements ChannelCrypto {
  private static instance: ChannelEncryption | null = null;
  /** Derived AES keys per channel (channel name -> 32 raw key bytes). */
  private readonly channelKeys: Map<string, Uint8Array> = new Map();
  /** Channel passwords, kept for rekey operations (Android parity). */
  private readonly channelPasswords: Map<string, string> = new Map();

  static getInstance(): ChannelEncryption {
    if (ChannelEncryption.instance === null) {
      ChannelEncryption.instance = new ChannelEncryption();
    }
    return ChannelEncryption.instance;
  }

  /**
   * Set the password for a channel: derive + store the AES key
   * (Android setChannelPassword parity). Empty names/passwords fail.
   */
  setChannelPassword(password: string, channel: string): boolean {
    if (password === '' || channel === '') {
      return false;
    }
    try {
      const key: Uint8Array = this.deriveChannelKey(password, channel);
      if (key.length !== KEY_LENGTH_BYTES) {
        return false;
      }
      this.channelKeys.set(channel, key);
      this.channelPasswords.set(channel, password);
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'derive channel key failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  /** Forget the key + password (leaving a channel, Android parity). */
  removeChannelPassword(channel: string): void {
    this.channelKeys.delete(channel);
    this.channelPasswords.delete(channel);
  }

  /** True once a password-derived key exists for the channel. */
  hasChannelKey(channel: string): boolean {
    return this.channelKeys.has(channel);
  }

  /** Stored password, or null for keyless channels (rekey/debug parity). */
  getChannelPassword(channel: string): string | null {
    const password: string | undefined = this.channelPasswords.get(channel);
    return password === undefined ? null : password;
  }

  /**
   * Encrypt one channel message: random 12-byte IV, AES-256-GCM, wire =
   * IV || ciphertext || tag(16). Returns null without a channel key.
   */
  encryptChannelMessage(message: string, channel: string): Uint8Array | null {
    const key: Uint8Array | undefined = this.channelKeys.get(channel);
    if (key === undefined) {
      return null;
    }
    try {
      const iv: Uint8Array =
        cryptoFramework.createRandom().generateRandomSync(GCM_IV_LENGTH).data;
      const gcmParams: cryptoFramework.GcmParamsSpec = {
        iv: { data: iv },
        aad: { data: new Uint8Array(0) },
        authTag: { data: new Uint8Array(0) },
        algName: 'GcmParamsSpec'
      };
      const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
      cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE,
        this.convertKeySync(key), gcmParams);
      // doFinalSync output = ciphertext || authTag(16) (GCM), so the wire
      // matches Android: IV prepended, tag riding the tail.
      const output: cryptoFramework.DataBlob =
        cipher.doFinalSync({ data: ByteUtils.utf8Encode(message) });
      return ByteUtils.concat(iv, output.data);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'encrypt channel message failed: %{public}s', JSON.stringify(e));
      return null;
    }
  }

  /**
   * Decrypt one channel message (wire = IV(12) || ciphertext || tag(16)).
   * Returns null on missing key, short data or authentication failure.
   */
  decryptChannelMessage(encryptedData: Uint8Array, channel: string): string | null {
    const key: Uint8Array | undefined = this.channelKeys.get(channel);
    if (key === undefined) {
      return null;
    }
    if (encryptedData.length < MIN_WIRE_LENGTH) {
      return null;
    }
    try {
      const iv: Uint8Array = encryptedData.subarray(0, GCM_IV_LENGTH);
      const authTag: Uint8Array =
        encryptedData.subarray(encryptedData.length - GCM_TAG_LENGTH);
      const ciphertext: Uint8Array =
        encryptedData.subarray(GCM_IV_LENGTH, encryptedData.length - GCM_TAG_LENGTH);
      const gcmParams: cryptoFramework.GcmParamsSpec = {
        iv: { data: iv },
        aad: { data: new Uint8Array(0) },
        authTag: { data: authTag },
        algName: 'GcmParamsSpec'
      };
      const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
      cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE,
        this.convertKeySync(key), gcmParams);
      const plain: cryptoFramework.DataBlob = cipher.doFinalSync({ data: ciphertext });
      return ByteUtils.utf8Decode(plain.data);
    } catch (e) {
      // Wrong password (auth failure), corrupted wire, or crypto error.
      hilog.error(DOMAIN, TAG, 'decrypt channel message failed: %{public}s', JSON.stringify(e));
      return null;
    }
  }

  /**
   * SHA-256 commitment over the raw key bytes (lowercase hex), letting
   * peers verify they derived the same key without revealing it
   * (Android calculateKeyCommitment parity).
   */
  calculateKeyCommitment(channel: string): string | null {
    const key: Uint8Array | undefined = this.channelKeys.get(channel);
    if (key === undefined) {
      return null;
    }
    try {
      const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
      md.updateSync({ data: key });
      return ByteUtils.bytesToHex(md.digestSync().data);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'key commitment failed: %{public}s', JSON.stringify(e));
      return null;
    }
  }

  /** Case-insensitive commitment comparison (Android parity). */
  verifyKeyCommitment(channel: string, commitment: string): boolean {
    const ours: string | null = this.calculateKeyCommitment(channel);
    return ours !== null && ours.toLowerCase() === commitment.toLowerCase();
  }

  /** Channels with a derived key (Android getActiveChannels parity). */
  getActiveChannels(): string[] {
    const channels: string[] = [];
    this.channelKeys.forEach((key: Uint8Array, channel: string): void => {
      channels.push(channel);
    });
    return channels;
  }

  /** Panic-wipe stage: drop every derived key and stored password. */
  clear(): void {
    this.channelKeys.clear();
    this.channelPasswords.clear();
  }

  /**
   * PBKDF2-HmacSHA256 key derivation, parameters identical to the
   * Android/iOS implementations: 100000 iterations, channel-name UTF-8
   * salt, 32-byte (256-bit) AES key.
   */
  private deriveChannelKey(password: string, channel: string): Uint8Array {
    const spec: cryptoFramework.PBKDF2Spec = {
      algName: 'PBKDF2',
      password: password,
      salt: ByteUtils.utf8Encode(channel),
      iterations: PBKDF2_ITERATIONS,
      keySize: KEY_LENGTH_BYTES
    };
    const kdf: cryptoFramework.Kdf = cryptoFramework.createKdf('PBKDF2|SHA256');
    return kdf.generateSecretSync(spec).data;
  }

  private convertKeySync(key: Uint8Array): cryptoFramework.SymKey {
    const generator: cryptoFramework.SymKeyGenerator =
      cryptoFramework.createSymKeyGenerator('AES256');
    return generator.convertKeySync({ data: key });
  }
}
