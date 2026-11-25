/**
 * QR verification helpers (US11, T056; Android VerificationService.kt parity).
 *
 * Pure ArkTS: the Ed25519 engine, the Noise static key and the random
 * source are injected by the caller (VerificationSigner / verifier
 * callbacks), so the schema, canonical signing layout, freshness window
 * and challenge/response TLV formats stay host-testable and the wire
 * contract is pinned by contract vectors.
 *
 * Wire formats:
 *  - Deep link: bitchat://verify?v&noise&sign&npub&nick&ts&nonce&sig
 *  - Canonical signing bytes: 1-byte length-prefixed fields
 *    [context][v][noiseKeyHex][signKeyHex][npub][nickname][ts][nonceB64]
 *  - Challenge TLV: [01][len][noiseKeyHex][02][len][nonceA]
 *  - Response TLV:  [01][len][noiseKeyHex][02][len][nonceA][03][len][sig]
 *  - Response signing message:
 *    [RESPONSE_CONTEXT][len][noiseKeyHex][nonceA raw]
 */
import { ByteUtils, ByteWriter } from '../../common/ByteUtils';

export const VERIFICATION_CONTEXT: string = 'bitchat-verify-v1';
export const VERIFICATION_RESPONSE_CONTEXT: string = 'bitchat-verify-resp-v1';
/** Freshness tolerance for a scanned QR, both directions (AppConstants parity). */
export const QR_MAX_AGE_SECONDS: number = 300;
/** A rebuilt "my QR" reuses the cached string for this long (Android parity). */
export const QR_CACHE_MS: number = 60_000;
/** Challenge nonce length (plan.md: nonce 16B). */
export const VERIFY_NONCE_LENGTH: number = 16;

/** Ed25519 + identity source injected by the production caller. */
export interface VerificationSigner {
  getStaticPublicKey(): Uint8Array;
  getSigningPublicKey(): Uint8Array;
  sign(data: Uint8Array): Uint8Array | null;
}

/** Signature verification callback (IdentityManager.verifySync at runtime). */
export type SignatureVerifier = (signature: Uint8Array, data: Uint8Array,
  publicKey: Uint8Array) => boolean;

/** Random nonce source (cryptoFramework.createRandom at runtime). */
export type NonceFactory = () => Uint8Array;

/** The scanned/built QR payload (Android VerificationQR parity). */
export class VerificationQR {
  readonly v: number;
  readonly noiseKeyHex: string;
  readonly signKeyHex: string;
  readonly npub: string | null;
  readonly nickname: string;
  readonly ts: number;
  readonly nonceB64: string;
  readonly sigHex: string;

  constructor(v: number, noiseKeyHex: string, signKeyHex: string, npub: string | null,
    nickname: string, ts: number, nonceB64: string, sigHex: string) {
    this.v = v;
    this.noiseKeyHex = noiseKeyHex;
    this.signKeyHex = signKeyHex;
    this.npub = npub;
    this.nickname = nickname;
    this.ts = ts;
    this.nonceB64 = nonceB64;
    this.sigHex = sigHex;
  }

  /** Length-prefixed canonical bytes covered by the Ed25519 signature. */
  canonicalBytes(): Uint8Array {
    const fields: string[] = [
      VERIFICATION_CONTEXT,
      this.v.toString(),
      this.noiseKeyHex.toLowerCase(),
      this.signKeyHex.toLowerCase(),
      this.npub !== null ? this.npub : '',
      this.nickname,
      this.ts.toString(),
      this.nonceB64
    ];
    let total: number = 0;
    const encoded: Uint8Array[] = [];
    for (let i: number = 0; i < fields.length; i++) {
      const data: Uint8Array = ByteUtils.utf8Encode(fields[i]);
      const clipped: Uint8Array = data.length > 255 ? data.subarray(0, 255) : data;
      encoded.push(clipped);
      total += 1 + clipped.length;
    }
    const writer: ByteWriter = new ByteWriter(total);
    for (let i: number = 0; i < encoded.length; i++) {
      writer.putByte(encoded[i].length);
      writer.putBytes(encoded[i]);
    }
    return writer.toUint8Array();
  }

  toUrlString(): string {
    let out: string = 'bitchat://verify?v=' + encodeURIComponent(this.v.toString());
    out += '&noise=' + encodeURIComponent(this.noiseKeyHex);
    out += '&sign=' + encodeURIComponent(this.signKeyHex);
    out += '&nick=' + encodeURIComponent(this.nickname);
    out += '&ts=' + encodeURIComponent(this.ts.toString());
    out += '&nonce=' + encodeURIComponent(this.nonceB64);
    out += '&sig=' + encodeURIComponent(this.sigHex);
    if (this.npub !== null) {
      out += '&npub=' + encodeURIComponent(this.npub);
    }
    return out;
  }

  static fromUrlString(urlString: string): VerificationQR | null {
    const prefix: string = 'bitchat://verify';
    if (!urlString.startsWith(prefix)) {
      return null;
    }
    let query: string = urlString.substring(prefix.length);
    if (query.startsWith('/')) {
      return null;
    }
    if (query.startsWith('?')) {
      query = query.substring(1);
    } else if (query.length > 0) {
      // Something other than the query string follows the host.
      return null;
    }
    const params: Map<string, string> = new Map<string, string>();
    const pairs: string[] = query.split('&');
    for (let i: number = 0; i < pairs.length; i++) {
      if (pairs[i] === '') {
        continue;
      }
      const eq: number = pairs[i].indexOf('=');
      if (eq < 0) {
        return null;
      }
      const key: string = pairs[i].substring(0, eq);
      let value: string = '';
      try {
        value = decodeURIComponent(pairs[i].substring(eq + 1));
      } catch (e) {
        return null;
      }
      // First occurrence wins (Android Uri.getQueryParameter parity).
      if (!params.has(key)) {
        params.set(key, value);
      }
    }
    const required: string[] = ['v', 'noise', 'sign', 'nick', 'ts', 'nonce', 'sig'];
    for (let i: number = 0; i < required.length; i++) {
      if (!params.has(required[i])) {
        return null;
      }
    }
    const v: number = Number(params.get('v'));
    const ts: number = Number(params.get('ts'));
    if (!Number.isInteger(v) || !Number.isInteger(ts)) {
      return null;
    }
    const npub: string | undefined = params.get('npub');
    return new VerificationQR(v, params.get('noise') as string, params.get('sign') as string,
      npub !== undefined ? npub : null, params.get('nick') as string, ts,
      params.get('nonce') as string, params.get('sig') as string);
  }

  static equals(a: VerificationQR, b: VerificationQR): boolean {
    return a.v === b.v && a.noiseKeyHex === b.noiseKeyHex &&
      a.signKeyHex === b.signKeyHex && a.npub === b.npub &&
      a.nickname === b.nickname && a.ts === b.ts &&
      a.nonceB64 === b.nonceB64 && a.sigHex === b.sigHex;
  }
}

/** Parsed verify challenge: target Noise key hex + nonce A. */
export class VerifyChallenge {
  readonly noiseKeyHex: string;
  readonly nonceA: Uint8Array;

  constructor(noiseKeyHex: string, nonceA: Uint8Array) {
    this.noiseKeyHex = noiseKeyHex;
    this.nonceA = new Uint8Array(nonceA);
  }
}

/** Parsed verify response: Noise key hex + nonce A + signature. */
export class VerifyResponse {
  readonly noiseKeyHex: string;
  readonly nonceA: Uint8Array;
  readonly signature: Uint8Array;

  constructor(noiseKeyHex: string, nonceA: Uint8Array, signature: Uint8Array) {
    this.noiseKeyHex = noiseKeyHex;
    this.nonceA = new Uint8Array(nonceA);
    this.signature = new Uint8Array(signature);
  }
}

export class VerificationService {
  private static cachedNickname: string = '';
  private static cachedNpub: string | null = null;
  private static cachedAtMs: number = 0;
  private static cachedValue: string = '';

  /**
   * Build the signed "my QR" deep link for this identity; the same
   * nickname/npub reuses the cached string for QR_CACHE_MS.
   */
  static buildMyQRString(signer: VerificationSigner, nickname: string, npub: string | null,
    nowMs: number, nonceFactory: NonceFactory): string | null {
    if (VerificationService.cachedAtMs > 0 &&
      VerificationService.cachedNickname === nickname &&
      VerificationService.cachedNpub === npub &&
      nowMs - VerificationService.cachedAtMs < QR_CACHE_MS) {
      return VerificationService.cachedValue;
    }
    const noiseKey: string = ByteUtils.bytesToHex(signer.getStaticPublicKey());
    const signKey: string = ByteUtils.bytesToHex(signer.getSigningPublicKey());
    const ts: number = Math.floor(nowMs / 1000);
    const nonce: Uint8Array = nonceFactory();
    if (nonce.length === 0) {
      return null;
    }
    const nonceB64: string = ByteUtils.base64UrlEncode(nonce);
    const payload: VerificationQR = new VerificationQR(1, noiseKey, signKey, npub,
      nickname, ts, nonceB64, '');
    const signature: Uint8Array | null = signer.sign(payload.canonicalBytes());
    if (signature === null) {
      return null;
    }
    const signed: VerificationQR = new VerificationQR(1, noiseKey, signKey, npub,
      nickname, ts, nonceB64, ByteUtils.bytesToHex(signature));
    const out: string = signed.toUrlString();
    VerificationService.cachedNickname = nickname;
    VerificationService.cachedNpub = npub;
    VerificationService.cachedAtMs = nowMs;
    VerificationService.cachedValue = out;
    return out;
  }

  /** Forget the cached QR (nickname change, panic). */
  static clearQrCache(): void {
    VerificationService.cachedAtMs = 0;
    VerificationService.cachedValue = '';
    VerificationService.cachedNickname = '';
    VerificationService.cachedNpub = null;
  }

  /**
   * Verify a scanned QR deep link: strict schema, freshness in both
   * directions (QR_MAX_AGE_SECONDS default) and Ed25519 over the
   * canonical bytes with the embedded signing key.
   */
  static verifyScannedQR(urlString: string, nowMs: number, verifier: SignatureVerifier,
    maxAgeSeconds: number = QR_MAX_AGE_SECONDS): VerificationQR | null {
    const qr: VerificationQR | null = VerificationQR.fromUrlString(urlString);
    if (qr === null) {
      return null;
    }
    const now: number = Math.floor(nowMs / 1000);
    if (VerificationService.verificationTimestampSkewSeconds(now, qr.ts) > maxAgeSeconds) {
      return null;
    }
    const sig: Uint8Array | null = ByteUtils.hexToBytes(qr.sigHex);
    const signKey: Uint8Array | null = ByteUtils.hexToBytes(qr.signKeyHex);
    if (sig === null || sig.length === 0 || signKey === null || signKey.length === 0) {
      return null;
    }
    return verifier(sig, qr.canonicalBytes(), signKey) ? qr : null;
  }

  /** Challenge TLV: [01][len][noiseKeyHex][02][len][nonceA]. */
  static buildVerifyChallenge(noiseKeyHex: string, nonceA: Uint8Array): Uint8Array {
    const noiseData: Uint8Array = ByteUtils.utf8Encode(noiseKeyHex);
    const noiseClipped: Uint8Array = noiseData.length > 255
      ? noiseData.subarray(0, 255) : noiseData;
    const nonceClipped: Uint8Array = nonceA.length > 255
      ? nonceA.subarray(0, 255) : nonceA;
    const writer: ByteWriter = new ByteWriter(2 + noiseClipped.length +
      2 + nonceClipped.length);
    writer.putByte(0x01);
    writer.putByte(noiseClipped.length);
    writer.putBytes(noiseClipped);
    writer.putByte(0x02);
    writer.putByte(nonceClipped.length);
    writer.putBytes(nonceClipped);
    return writer.toUint8Array();
  }

  /**
   * Response TLV: [01][len][noiseKeyHex][02][len][nonceA][03][len][sig];
   * the signature covers [RESPONSE_CONTEXT][len][noiseKeyHex][nonceA raw].
   */
  static buildVerifyResponse(signer: VerificationSigner, noiseKeyHex: string,
    nonceA: Uint8Array): Uint8Array | null {
    const noiseData: Uint8Array = ByteUtils.utf8Encode(noiseKeyHex);
    const noiseClipped: Uint8Array = noiseData.length > 255
      ? noiseData.subarray(0, 255) : noiseData;
    const msg: ByteWriter = new ByteWriter(
      ByteUtils.utf8Encode(VERIFICATION_RESPONSE_CONTEXT).length +
      1 + noiseClipped.length + nonceA.length);
    msg.putBytes(ByteUtils.utf8Encode(VERIFICATION_RESPONSE_CONTEXT));
    msg.putByte(noiseClipped.length);
    msg.putBytes(noiseClipped);
    msg.putBytes(nonceA);
    const sig: Uint8Array | null = signer.sign(msg.toUint8Array());
    if (sig === null) {
      return null;
    }
    const noiseClipped2: Uint8Array = noiseData.length > 255
      ? noiseData.subarray(0, 255) : noiseData;
    const nonceClipped: Uint8Array = nonceA.length > 255
      ? nonceA.subarray(0, 255) : nonceA;
    const sigClipped: Uint8Array = sig.length > 255 ? sig.subarray(0, 255) : sig;
    const writer: ByteWriter = new ByteWriter(2 + noiseClipped2.length +
      2 + nonceClipped.length + 2 + sigClipped.length);
    writer.putByte(0x01);
    writer.putByte(noiseClipped2.length);
    writer.putBytes(noiseClipped2);
    writer.putByte(0x02);
    writer.putByte(nonceClipped.length);
    writer.putBytes(nonceClipped);
    writer.putByte(0x03);
    writer.putByte(sigClipped.length);
    writer.putBytes(sigClipped);
    return writer.toUint8Array();
  }

  static parseVerifyChallenge(data: Uint8Array): VerifyChallenge | null {
    let offset: number = 0;
    if (offset + 2 > data.length || (data[offset] & 0xFF) !== 0x01) {
      return null;
    }
    const noiseLength: number = data[offset + 1] & 0xFF;
    offset += 2;
    if (offset + noiseLength > data.length) {
      return null;
    }
    const noise: string = ByteUtils.utf8Decode(data.subarray(offset, offset + noiseLength));
    offset += noiseLength;
    if (offset + 2 > data.length || (data[offset] & 0xFF) !== 0x02) {
      return null;
    }
    const nonceLength: number = data[offset + 1] & 0xFF;
    offset += 2;
    if (offset + nonceLength > data.length) {
      return null;
    }
    const nonce: Uint8Array = data.slice(offset, offset + nonceLength);
    return new VerifyChallenge(noise, nonce);
  }

  static parseVerifyResponse(data: Uint8Array): VerifyResponse | null {
    let offset: number = 0;
    if (offset + 2 > data.length || (data[offset] & 0xFF) !== 0x01) {
      return null;
    }
    const noiseLength: number = data[offset + 1] & 0xFF;
    offset += 2;
    if (offset + noiseLength > data.length) {
      return null;
    }
    const noise: string = ByteUtils.utf8Decode(data.subarray(offset, offset + noiseLength));
    offset += noiseLength;
    if (offset + 2 > data.length || (data[offset] & 0xFF) !== 0x02) {
      return null;
    }
    const nonceLength: number = data[offset + 1] & 0xFF;
    offset += 2;
    if (offset + nonceLength > data.length) {
      return null;
    }
    const nonce: Uint8Array = data.slice(offset, offset + nonceLength);
    offset += nonceLength;
    if (offset + 2 > data.length || (data[offset] & 0xFF) !== 0x03) {
      return null;
    }
    const sigLength: number = data[offset + 1] & 0xFF;
    offset += 2;
    if (offset + sigLength > data.length) {
      return null;
    }
    const sig: Uint8Array = data.slice(offset, offset + sigLength);
    return new VerifyResponse(noise, nonce, sig);
  }

  /** Verify a parsed response signature against the claimed signer key. */
  static verifyResponseSignature(noiseKeyHex: string, nonceA: Uint8Array,
    signature: Uint8Array, signerPublicKeyHex: string,
    verifier: SignatureVerifier): boolean {
    const noiseData: Uint8Array = ByteUtils.utf8Encode(noiseKeyHex);
    const noiseClipped: Uint8Array = noiseData.length > 255
      ? noiseData.subarray(0, 255) : noiseData;
    const msg: ByteWriter = new ByteWriter(
      ByteUtils.utf8Encode(VERIFICATION_RESPONSE_CONTEXT).length +
      1 + noiseClipped.length + nonceA.length);
    msg.putBytes(ByteUtils.utf8Encode(VERIFICATION_RESPONSE_CONTEXT));
    msg.putByte(noiseClipped.length);
    msg.putBytes(noiseClipped);
    msg.putBytes(nonceA);
    const signerKey: Uint8Array | null = ByteUtils.hexToBytes(signerPublicKeyHex);
    if (signerKey === null || signerKey.length === 0) {
      return false;
    }
    return verifier(signature, msg.toUint8Array(), signerKey);
  }

  /**
   * Absolute age in seconds between now and the QR timestamp. Extreme
   * differences (non-finite or beyond the safe integer range, e.g. a
   * hostile huge ts) saturate instead of wrapping into an accepted age
   * (Android verificationTimestampSkewSeconds parity).
   */
  static verificationTimestampSkewSeconds(nowSeconds: number,
    qrTimestampSeconds: number): number {
    const difference: number = Math.abs(nowSeconds - qrTimestampSeconds);
    if (!Number.isFinite(difference) || difference > Number.MAX_SAFE_INTEGER) {
      return Number.MAX_SAFE_INTEGER;
    }
    return difference;
  }
}
