/**
 * Nostr identity (secp256k1 keypair + npub), immutable.
 *
 * Mirrors bitchat-android NostrIdentity.kt (the data class, not the
 * Android-context bridge): generate() derives from injected randomness,
 * fromPrivateKey() validates and derives, npub is the bech32 "npub"
 * encoding of the 32-byte x-only public key. Divergence: Android's
 * BouncyCastle key generator samples d uniformly in [1, n-1]; the port
 * reduces 32 random bytes mod n (never zero), matching the gift-wrap
 * ephemeral-key derivation both clients already share. Pure ArkTS: no
 * @ohos/@kit imports, host-runnable by the contract-test harness.
 */
import { ByteUtils } from '../../common/ByteUtils';
import { Bech32 } from './Bech32';
import { NostrEvent } from './NostrEvent';
import { NostrRandomSource } from './NostrRandomSource';
import { Secp256k1 } from './Secp256k1';

export class NostrIdentity {
  readonly privateKeyHex: string;
  readonly publicKeyHex: string;
  readonly npub: string;
  readonly createdAtMs: number;

  constructor(privateKeyHex: string, publicKeyHex: string, npub: string, createdAtMs: number) {
    this.privateKeyHex = privateKeyHex;
    this.publicKeyHex = publicKeyHex;
    this.npub = npub;
    this.createdAtMs = createdAtMs;
  }

  /** Generate a new identity from injected randomness. */
  static generate(random: NostrRandomSource, nowMs: number): NostrIdentity {
    const privateKeyHex: string =
      Secp256k1.privateKeyFromRandomBytes(random.nextBytes(32));
    const publicKeyHex: string = Secp256k1.derivePublicKey(privateKeyHex);
    const npub: string = Bech32.encode('npub', ByteUtils.hexToBytes(publicKeyHex));
    return new NostrIdentity(privateKeyHex, publicKeyHex, npub, nowMs);
  }

  /** Create from an existing private key; throws when invalid. */
  static fromPrivateKey(privateKeyHex: string, nowMs: number): NostrIdentity {
    if (!Secp256k1.isValidPrivateKey(privateKeyHex)) {
      throw new Error('Invalid private key');
    }
    const publicKeyHex: string = Secp256k1.derivePublicKey(privateKeyHex);
    const npub: string = Bech32.encode('npub', ByteUtils.hexToBytes(publicKeyHex));
    return new NostrIdentity(privateKeyHex, publicKeyHex, npub, nowMs);
  }

  /** Sign a Nostr event with this identity's private key. */
  signEvent(event: NostrEvent, random: NostrRandomSource): NostrEvent {
    return event.sign(this.privateKeyHex, random);
  }

  /** Short display format: first8...last8. */
  getShortNpub(): string {
    if (this.npub.length > 16) {
      return this.npub.substring(0, 8) + '...' + this.npub.substring(this.npub.length - 8);
    }
    return this.npub;
  }
}
