/**
 * secp256k1 elliptic-curve operations for the Nostr protocol kernel:
 * x-only public-key derivation, ECDH with explicit Y-parity lifts (the
 * bitchat NIP-44 variant derives its HKDF input from the compressed
 * 33-byte shared point), and BIP-340 Schnorr signatures with auxiliary
 * randomness. BigInt Jacobian point arithmetic keeps the 256-bit field
 * math exact; the canonical BIP-340 test vectors are enforced by
 * NostrContractTests. Pure ArkTS: no @ohos/@kit imports, host-runnable
 * by the contract-test harness.
 *
 * Divergence from bitchat-android NostrCrypto.kt, intentional: signing
 * uses the BIP-340 nonce derivation (tagged aux/nonce hashes) instead of
 * Android's ad-hoc SHA256(d||m||pub||rand) nonce. Both produce valid
 * BIP-340 signatures, so receivers on every client verify either form;
 * only the signer-side nonce generation differs.
 */
import { ByteUtils } from '../../common/ByteUtils';

/** Affine point; x === null marks the point at infinity. */
class EcPointX {
  readonly x: bigint | null;
  readonly y: bigint;

  constructor(x: bigint | null, y: bigint) {
    this.x = x;
    this.y = y;
  }
}

/** Jacobian point on secp256k1 (curve parameter a = 0). */
class EcPointJ {
  readonly x: bigint;
  readonly y: bigint;
  readonly z: bigint;

  constructor(x: bigint, y: bigint, z: bigint) {
    this.x = x;
    this.y = y;
    this.z = z;
  }
}

export class Secp256k1 {
  static readonly P: bigint = (1n << 256n) - (1n << 32n) - 977n;
  static readonly N: bigint =
    0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141n;
  private static readonly GX: bigint =
    0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798n;
  private static readonly GY: bigint =
    0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8n;

  /** Validate a secp256k1 private key (32-byte hex, 0 < d < n). */
  static isValidPrivateKey(privateKeyHex: string): boolean {
    if (privateKeyHex.length !== 64) {
      return false;
    }
    const bytes: Uint8Array = ByteUtils.hexToBytes(privateKeyHex);
    if (bytes.length !== 32) {
      return false;
    }
    const d: bigint = Secp256k1.bigFromBytes(bytes);
    return d > 0n && d < Secp256k1.N;
  }

  /** Derive the x-only public key (32-byte hex) from a private key. */
  static derivePublicKey(privateKeyHex: string): string {
    const privBytes: Uint8Array = ByteUtils.hexToBytes(privateKeyHex);
    if (privBytes.length !== 32) {
      throw new Error('Private key must be 32 bytes');
    }
    const d: bigint = Secp256k1.bigFromBytes(privBytes);
    if (d === 0n || d >= Secp256k1.N) {
      throw new Error('Invalid private key');
    }
    const pub: EcPointX = Secp256k1.toAffine(Secp256k1.scalarMultG(d));
    if (pub.x === null) {
      throw new Error('Invalid public key point');
    }
    return ByteUtils.bytesToHex(Secp256k1.bytes32FromBig(pub.x));
  }

  /** Check that an x-only public key hex (32 bytes) lifts to a curve point. */
  static isValidXOnlyPublicKey(publicKeyHex: string): boolean {
    if (publicKeyHex.length !== 64) {
      return false;
    }
    const pubBytes: Uint8Array = ByteUtils.hexToBytes(publicKeyHex);
    if (pubBytes.length !== 32) {
      return false;
    }
    const x: bigint = Secp256k1.bigFromBytes(pubBytes);
    if (x >= Secp256k1.P) {
      return false;
    }
    return Secp256k1.liftX(x) !== null;
  }

  /**
   * ECDH shared point, compressed to 33 bytes (0x02/0x03 || x). The x-only
   * peer key is lifted with the requested Y parity; the shared point's own
   * compression prefix reflects its actual parity.
   */
  static ecdhSharedPointCompressed(privateKeyHex: string, publicKeyHex: string,
    preferOddY: boolean): Uint8Array | null {
    const privBytes: Uint8Array = ByteUtils.hexToBytes(privateKeyHex);
    const pubBytes: Uint8Array = ByteUtils.hexToBytes(publicKeyHex);
    if (privBytes.length !== 32 || pubBytes.length !== 32) {
      return null;
    }
    const d: bigint = Secp256k1.bigFromBytes(privBytes);
    if (d === 0n || d >= Secp256k1.N) {
      return null;
    }
    const x: bigint = Secp256k1.bigFromBytes(pubBytes);
    if (x >= Secp256k1.P) {
      return null;
    }
    const c: bigint = Secp256k1.modP(x * x * x + 7n);
    const y: bigint = Secp256k1.modPow(c, (Secp256k1.P + 1n) / 4n, Secp256k1.P);
    if ((y * y) % Secp256k1.P !== c) {
      return null;
    }
    const yIsOdd: boolean = (y % 2n) === 1n;
    let chosenY: bigint = y;
    if (preferOddY !== yIsOdd) {
      chosenY = (Secp256k1.P - y) % Secp256k1.P;
    }
    const shared: EcPointX =
      Secp256k1.toAffine(Secp256k1.scalarMultPoint(d, new EcPointX(x, chosenY)));
    if (shared.x === null) {
      return null;
    }
    const out: Uint8Array = new Uint8Array(33);
    out[0] = (shared.y % 2n) === 0n ? 0x02 : 0x03;
    out.set(Secp256k1.bytes32FromBig(shared.x), 1);
    return out;
  }

  /**
   * BIP-340 Schnorr signature over a 32-byte message hash; returns the
   * 64-byte r||s hex string. Deterministic given the auxiliary randomness.
   */
  static schnorrSign(messageHash: Uint8Array, privateKeyHex: string,
    aux32: Uint8Array): string {
    if (messageHash.length !== 32) {
      throw new Error('Message hash must be 32 bytes');
    }
    if (aux32.length !== 32) {
      throw new Error('Auxiliary randomness must be 32 bytes');
    }
    const privBytes: Uint8Array = ByteUtils.hexToBytes(privateKeyHex);
    if (privBytes.length !== 32) {
      throw new Error('Private key must be 32 bytes');
    }
    const d0: bigint = Secp256k1.bigFromBytes(privBytes);
    if (d0 === 0n || d0 >= Secp256k1.N) {
      throw new Error('Invalid private key');
    }
    const p: EcPointX = Secp256k1.toAffine(Secp256k1.scalarMultG(d0));
    if (p.x === null) {
      throw new Error('Invalid public key point');
    }
    const px: Uint8Array = Secp256k1.bytes32FromBig(p.x);
    const d: bigint = (p.y % 2n) === 0n ? d0 : Secp256k1.N - d0;
    const dBytes: Uint8Array = Secp256k1.bytes32FromBig(d);
    const auxHash: Uint8Array =
      Secp256k1.bytes32FromBig(Secp256k1.bigFromBytes(Secp256k1.taggedHash('BIP0340/aux', aux32)));
    const t: Uint8Array = new Uint8Array(32);
    for (let i: number = 0; i < 32; i++) {
      t[i] = dBytes[i] ^ auxHash[i];
    }
    const rand: Uint8Array = Secp256k1.taggedHash('BIP0340/nonce',
      ByteUtils.concat(t, px, messageHash));
    const k0: bigint = Secp256k1.bigFromBytes(rand) % Secp256k1.N;
    if (k0 === 0n) {
      throw new Error('Schnorr nonce generation failed');
    }
    const rPoint: EcPointX = Secp256k1.toAffine(Secp256k1.scalarMultG(k0));
    if (rPoint.x === null) {
      throw new Error('Invalid nonce point');
    }
    const rx: Uint8Array = Secp256k1.bytes32FromBig(rPoint.x);
    const k: bigint = (rPoint.y % 2n) === 0n ? k0 : Secp256k1.N - k0;
    const e: bigint = Secp256k1.bigFromBytes(Secp256k1.taggedHash('BIP0340/challenge',
      ByteUtils.concat(rx, px, messageHash))) % Secp256k1.N;
    const s: Uint8Array = Secp256k1.bytes32FromBig((k + e * d) % Secp256k1.N);
    return ByteUtils.bytesToHex(ByteUtils.concat(rx, s));
  }

  /** BIP-340 Schnorr verification over a 32-byte message hash. */
  static schnorrVerify(messageHash: Uint8Array, signatureHex: string,
    publicKeyHex: string): boolean {
    if (messageHash.length !== 32) {
      return false;
    }
    const sig: Uint8Array = ByteUtils.hexToBytes(signatureHex);
    if (sig.length !== 64) {
      return false;
    }
    const pubBytes: Uint8Array = ByteUtils.hexToBytes(publicKeyHex);
    if (pubBytes.length !== 32) {
      return false;
    }
    const r: Uint8Array = sig.subarray(0, 32);
    const rBig: bigint = Secp256k1.bigFromBytes(r);
    const sBig: bigint = Secp256k1.bigFromBytes(sig.subarray(32, 64));
    if (rBig >= Secp256k1.P || sBig >= Secp256k1.N) {
      return false;
    }
    const p: EcPointX | null = Secp256k1.liftX(Secp256k1.bigFromBytes(pubBytes));
    if (p === null || p.x === null) {
      return false;
    }
    const e: bigint = Secp256k1.bigFromBytes(Secp256k1.taggedHash('BIP0340/challenge',
      ByteUtils.concat(r, pubBytes, messageHash))) % Secp256k1.N;
    // R = s*G - e*P
    const sg: EcPointJ = Secp256k1.scalarMultG(sBig);
    const ep: EcPointJ = Secp256k1.scalarMultPoint(e, p);
    const negEp: EcPointJ = new EcPointJ(ep.x, Secp256k1.modP(-ep.y), ep.z);
    const candidate: EcPointX = Secp256k1.toAffine(Secp256k1.addJ(sg, negEp));
    if (candidate.x === null) {
      return false;
    }
    if ((candidate.y % 2n) !== 0n) {
      return false;
    }
    return candidate.x === rBig;
  }

  /** BIP-340 tagged hash: sha256(sha256(tag) || sha256(tag) || data). */
  static taggedHash(tag: string, data: Uint8Array): Uint8Array {
    const tagHash: Uint8Array = ByteUtils.sha256(ByteUtils.utf8Encode(tag));
    return ByteUtils.sha256(ByteUtils.concat(tagHash, tagHash, data));
  }

  /** Map 32 random bytes to a valid private key hex (reduced mod n, never zero). */
  static privateKeyFromRandomBytes(rand: Uint8Array): string {
    if (rand.length !== 32) {
      throw new Error('Random seed must be 32 bytes');
    }
    let d: bigint = Secp256k1.bigFromBytes(rand) % Secp256k1.N;
    if (d === 0n) {
      d = 1n;
    }
    return ByteUtils.bytesToHex(Secp256k1.bytes32FromBig(d));
  }

  /** Big-endian bytes to BigInt. */
  static bigFromBytes(bytes: Uint8Array): bigint {
    let v: bigint = 0n;
    for (let i: number = 0; i < bytes.length; i++) {
      v = (v << 8n) | BigInt(bytes[i] & 0xFF);
    }
    return v;
  }

  /** BigInt to exactly 32 big-endian bytes (truncates or zero-pads the high end). */
  static bytes32FromBig(v: bigint): Uint8Array {
    const out: Uint8Array = new Uint8Array(32);
    let x: bigint = v;
    for (let i: number = 31; i >= 0; i--) {
      out[i] = Number(x & 0xFFn);
      x >>= 8n;
    }
    return out;
  }

  private static modP(v: bigint): bigint {
    return ((v % Secp256k1.P) + Secp256k1.P) % Secp256k1.P;
  }

  private static modPow(base: bigint, exp: bigint, mod: bigint): bigint {
    let result: bigint = 1n;
    let b: bigint = ((base % mod) + mod) % mod;
    let e: bigint = exp;
    while (e > 0n) {
      if ((e & 1n) === 1n) {
        result = (result * b) % mod;
      }
      b = (b * b) % mod;
      e >>= 1n;
    }
    return result;
  }

  /** Lift an x coordinate to the curve point with even Y (BIP-340). */
  private static liftX(x: bigint): EcPointX | null {
    if (x >= Secp256k1.P) {
      return null;
    }
    const c: bigint = Secp256k1.modP(x * x * x + 7n);
    const y: bigint = Secp256k1.modPow(c, (Secp256k1.P + 1n) / 4n, Secp256k1.P);
    if ((y * y) % Secp256k1.P !== c) {
      return null;
    }
    if ((y % 2n) === 0n) {
      return new EcPointX(x, y);
    }
    return new EcPointX(x, (Secp256k1.P - y) % Secp256k1.P);
  }

  private static infinityJ(): EcPointJ {
    return new EcPointJ(1n, 1n, 0n);
  }

  private static isInfinityJ(pt: EcPointJ): boolean {
    return pt.z === 0n;
  }

  /** Jacobian doubling (dbl-2007-bl family, a = 0). */
  private static doubleJ(pt: EcPointJ): EcPointJ {
    if (Secp256k1.isInfinityJ(pt) || pt.y === 0n) {
      return Secp256k1.infinityJ();
    }
    const a: bigint = (pt.x * pt.x) % Secp256k1.P;
    const b: bigint = (pt.y * pt.y) % Secp256k1.P;
    const c: bigint = (b * b) % Secp256k1.P;
    const xb: bigint = pt.x + b;
    const d: bigint = Secp256k1.modP(2n * (Secp256k1.modP(xb * xb) - a - c));
    const e: bigint = Secp256k1.modP(3n * a);
    const f: bigint = (e * e) % Secp256k1.P;
    const x3: bigint = Secp256k1.modP(f - 2n * d);
    const y3: bigint = Secp256k1.modP(e * (d - x3) - 8n * c);
    const z3: bigint = Secp256k1.modP(2n * pt.y * pt.z);
    return new EcPointJ(x3, y3, z3);
  }

  /** Jacobian addition (add-2007-bl). */
  private static addJ(p1: EcPointJ, p2: EcPointJ): EcPointJ {
    if (Secp256k1.isInfinityJ(p1)) {
      return p2;
    }
    if (Secp256k1.isInfinityJ(p2)) {
      return p1;
    }
    const z1z1: bigint = (p1.z * p1.z) % Secp256k1.P;
    const z2z2: bigint = (p2.z * p2.z) % Secp256k1.P;
    const u1: bigint = (p1.x * z2z2) % Secp256k1.P;
    const u2: bigint = (p2.x * z1z1) % Secp256k1.P;
    const s1: bigint = Secp256k1.modP(p1.y * p2.z * z2z2);
    const s2: bigint = Secp256k1.modP(p2.y * p1.z * z1z1);
    if (u1 === u2) {
      if (s1 !== s2) {
        return Secp256k1.infinityJ();
      }
      return Secp256k1.doubleJ(p1);
    }
    const h: bigint = Secp256k1.modP(u2 - u1);
    const i: bigint = Secp256k1.modP(4n * h * h);
    const j: bigint = (h * i) % Secp256k1.P;
    const r: bigint = Secp256k1.modP(2n * (s2 - s1));
    const v: bigint = (u1 * i) % Secp256k1.P;
    const x3: bigint = Secp256k1.modP(r * r - j - 2n * v);
    const y3: bigint = Secp256k1.modP(r * (v - x3) - 2n * s1 * j);
    const zSum: bigint = Secp256k1.modP(p1.z + p2.z);
    const z3: bigint = Secp256k1.modP(Secp256k1.modP(zSum * zSum - z1z1 - z2z2) * h);
    return new EcPointJ(x3, y3, z3);
  }

  private static toAffine(pt: EcPointJ): EcPointX {
    if (Secp256k1.isInfinityJ(pt)) {
      return new EcPointX(null, 0n);
    }
    const zInv: bigint = Secp256k1.modPow(pt.z, Secp256k1.P - 2n, Secp256k1.P);
    const zInv2: bigint = (zInv * zInv) % Secp256k1.P;
    const zInv3: bigint = Secp256k1.modP(zInv2 * zInv);
    return new EcPointX(Secp256k1.modP(pt.x * zInv2), Secp256k1.modP(pt.y * zInv3));
  }

  private static scalarMultG(k: bigint): EcPointJ {
    let result: EcPointJ = Secp256k1.infinityJ();
    let addend: EcPointJ = new EcPointJ(Secp256k1.GX, Secp256k1.GY, 1n);
    let e: bigint = k;
    while (e > 0n) {
      if ((e & 1n) === 1n) {
        result = Secp256k1.addJ(result, addend);
      }
      addend = Secp256k1.doubleJ(addend);
      e >>= 1n;
    }
    return result;
  }

  private static scalarMultPoint(k: bigint, p: EcPointX): EcPointJ {
    const px: bigint = p.x === null ? 0n : p.x;
    let result: EcPointJ = Secp256k1.infinityJ();
    let addend: EcPointJ = new EcPointJ(px, p.y, 1n);
    let e: bigint = k;
    while (e > 0n) {
      if ((e & 1n) === 1n) {
        result = Secp256k1.addJ(result, addend);
      }
      addend = Secp256k1.doubleJ(addend);
      e >>= 1n;
    }
    return result;
  }
}
