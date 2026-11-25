/**
 * Contact identity normalization helpers (US11, T055;
 * Android ContactIdentityResolver.kt parity).
 *
 * The app addresses one contact through several aliases: the 16-hex mesh
 * peer ID, the 64-hex Noise static public key, a SHA-256 fingerprint over
 * that key, or a bech32 npub. Every service that resolves an alias to a
 * canonical identity funnels through this class so the matching rules stay
 * in one place and stay testable on the host.
 */
import { ByteUtils } from '../../common/ByteUtils';
import { Bech32, Bech32Result } from '../nostr/Bech32';

/** Pure helper class; static-only, never instantiated. */
export class ContactIdentityResolver {
  private static readonly CONTACT_PREFIX: string = 'contact_';
  private static readonly NOSTR_ALIAS_PREFIXES: string[] = ['nostr_', 'nostr:'];

  static isMeshPeerId(value: string): boolean {
    return ContactIdentityResolver.isHexStringOfLength(value, 16);
  }

  static isNoiseKeyHex(value: string): boolean {
    return ContactIdentityResolver.isHexStringOfLength(value, 64);
  }

  static isNostrAlias(value: string): boolean {
    for (let i: number = 0; i < ContactIdentityResolver.NOSTR_ALIAS_PREFIXES.length; i++) {
      if (value.startsWith(ContactIdentityResolver.NOSTR_ALIAS_PREFIXES[i])) {
        return true;
      }
    }
    return false;
  }

  /** Lowercase hex of the Noise static public key. */
  static noiseKeyHex(noisePublicKey: Uint8Array): string {
    return ByteUtils.bytesToHex(noisePublicKey).toLowerCase();
  }

  /** SHA-256 hex fingerprint of the Noise static public key. */
  static fingerprintHex(noisePublicKey: Uint8Array): string {
    return ByteUtils.sha256Hex(noisePublicKey).toLowerCase();
  }

  static isContactConversationId(value: string): boolean {
    if (!value.startsWith(ContactIdentityResolver.CONTACT_PREFIX)) {
      return false;
    }
    return ContactIdentityResolver.isHexStringOfLength(
      value.substring(ContactIdentityResolver.CONTACT_PREFIX.length), 64);
  }

  static fingerprintFromContactConversationId(value: string): string | null {
    if (!ContactIdentityResolver.isContactConversationId(value)) {
      return null;
    }
    return value.substring(ContactIdentityResolver.CONTACT_PREFIX.length).toLowerCase();
  }

  /** Mesh peer ID: fingerprint hex truncated to 16 chars. */
  static peerIdForNoiseKey(noisePublicKey: Uint8Array): string {
    return ContactIdentityResolver.fingerprintHex(noisePublicKey).substring(0, 16);
  }

  static peerIdForNoiseKeyHex(noiseKeyHex: string): string | null {
    const bytes: Uint8Array | null = ContactIdentityResolver.bytesFromHex(noiseKeyHex);
    if (bytes === null || bytes.length !== 32) {
      return null;
    }
    return ContactIdentityResolver.peerIdForNoiseKey(bytes);
  }

  /** Strict hex decode: even length, hex digits only; null on violation. */
  static bytesFromHex(hex: string): Uint8Array | null {
    const clean: string = hex.trim();
    if (clean.length === 0 || clean.length % 2 !== 0) {
      return null;
    }
    for (let i: number = 0; i < clean.length; i++) {
      const code: number = clean.charCodeAt(i);
      const isDigit: boolean = code >= 48 && code <= 57;
      const isLower: boolean = code >= 97 && code <= 102;
      const isUpper: boolean = code >= 65 && code <= 70;
      if (!isDigit && !isLower && !isUpper) {
        return null;
      }
    }
    return ByteUtils.hexToBytes(clean);
  }

  /**
   * Canonical Nostr pubkey hex for an npub or raw-hex input; null when the
   * value is neither. npub decode failures are swallowed (Android parity).
   */
  static nostrPubkeyHex(value: string): string | null {
    const clean: string = value.trim();
    if (clean.toLowerCase().startsWith('npub1')) {
      try {
        const decoded: Bech32Result = Bech32.decode(clean.toLowerCase());
        if (decoded.hrp === 'npub' && decoded.data.length === 32) {
          return ByteUtils.bytesToHex(decoded.data).toLowerCase();
        }
        return null;
      } catch (e) {
        return null;
      }
    }
    if (!ContactIdentityResolver.isNoiseKeyHex(clean)) {
      return null;
    }
    return clean.toLowerCase();
  }

  /** bech32 npub for a 32-byte pubkey hex; null on wrong length/bad hex. */
  static npubFromHex(hex: string): string | null {
    const bytes: Uint8Array | null = ContactIdentityResolver.bytesFromHex(hex);
    if (bytes === null || bytes.length !== 32) {
      return null;
    }
    try {
      return Bech32.encode('npub', bytes);
    } catch (e) {
      return null;
    }
  }

  static nostrAliasForPubkey(value: string): string | null {
    const hex: string | null = ContactIdentityResolver.nostrPubkeyHex(value);
    return hex === null ? null : 'nostr_' + hex.substring(0, 16);
  }

  private static isHexStringOfLength(value: string, length: number): boolean {
    if (value.length !== length) {
      return false;
    }
    for (let i: number = 0; i < value.length; i++) {
      const code: number = value.charCodeAt(i);
      const isDigit: boolean = code >= 48 && code <= 57;
      const isLower: boolean = code >= 97 && code <= 102;
      const isUpper: boolean = code >= 65 && code <= 70;
      if (!isDigit && !isLower && !isUpper) {
        return false;
      }
    }
    return true;
  }
}
