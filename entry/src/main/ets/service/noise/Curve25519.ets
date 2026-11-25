/**
 * X25519 function evaluation over Curve25519 (RFC 7748).
 *
 * BigInt-based Montgomery ladder with the same observable semantics as the
 * vendored noise-java Curve25519.java: the private scalar is clamped inside
 * the evaluation (low three bits cleared, bit 254 forced, bit 255 ignored)
 * and public inputs are reduced modulo 2^255 - 19 before use. Pure ArkTS:
 * no @ohos/@kit imports, host-runnable by the contract-test harness.
 *
 * Not constant-time (BigInt ladder uses branches for the conditional swap);
 * see spec/bitchat-harmonyos/notes-crypto.md for the D1 assessment.
 */
export class Curve25519 {
  private static readonly P: bigint = (1n << 255n) - 19n;
  private static readonly A24: bigint = 121665n;

  /**
   * Evaluates Curve25519.
   *
   * @param result Buffer to place the 32-byte result into.
   * @param offset Offset into the result buffer.
   * @param privateKey The 32-byte private key to use in the evaluation.
   * @param publicKey The 32-byte public key to use in the evaluation, or
   * null if the base point of the curve should be used.
   */
  static eval(result: Uint8Array, offset: number, privateKey: Uint8Array, publicKey: Uint8Array | null): void {
    const p: bigint = Curve25519.P;
    const a24: bigint = Curve25519.A24;
    let k: bigint = Curve25519.bytesToBigIntLittleEndian(privateKey, 0, 32);
    k &= (1n << 255n) - 8n;
    k |= 1n << 254n;
    let x1: bigint = publicKey !== null
      ? Curve25519.bytesToBigIntLittleEndian(publicKey, 0, 32) % p
      : 9n;
    let x2: bigint = 1n;
    let z2: bigint = 0n;
    let x3: bigint = x1;
    let z3: bigint = 1n;
    let swap: number = 0;
    for (let t: number = 254; t >= 0; t--) {
      const kt: number = Number((k >> BigInt(t)) & 1n);
      swap ^= kt;
      if (swap === 1) {
        let tmp: bigint = x2;
        x2 = x3;
        x3 = tmp;
        tmp = z2;
        z2 = z3;
        z3 = tmp;
      }
      swap = kt;
      const a: bigint = (x2 + z2) % p;
      const aa: bigint = (a * a) % p;
      const b: bigint = (x2 - z2 + p) % p;
      const bb: bigint = (b * b) % p;
      const e: bigint = (aa - bb + p) % p;
      const c: bigint = (x3 + z3) % p;
      const d: bigint = (x3 - z3 + p) % p;
      const da: bigint = (d * a) % p;
      const cb: bigint = (c * b) % p;
      const sum: bigint = (da + cb) % p;
      const diff: bigint = (da - cb + p) % p;
      x3 = (sum * sum) % p;
      z3 = ((diff * diff) % p * x1) % p;
      x2 = (aa * bb) % p;
      z2 = (e * ((a24 * e) % p + aa)) % p;
    }
    if (swap === 1) {
      let tmp: bigint = x2;
      x2 = x3;
      x3 = tmp;
      tmp = z2;
      z2 = z3;
      z3 = tmp;
    }
    const z2Inverse: bigint = Curve25519.powMod(z2, p - 2n, p);
    let res: bigint = (x2 * z2Inverse) % p;
    for (let i: number = 0; i < 32; i++) {
      result[offset + i] = Number(res & 0xFFn);
      res >>= 8n;
    }
  }

  /** Derives the 32-byte public key for a 32-byte private key (base point 9). */
  static publicKeyFromPrivateKey(privateKey: Uint8Array): Uint8Array {
    const out: Uint8Array = new Uint8Array(32);
    Curve25519.eval(out, 0, privateKey, null);
    return out;
  }

  /** Computes the 32-byte X25519 shared secret. */
  static sharedSecret(privateKey: Uint8Array, publicKey: Uint8Array): Uint8Array {
    const out: Uint8Array = new Uint8Array(32);
    Curve25519.eval(out, 0, privateKey, publicKey);
    return out;
  }

  private static bytesToBigIntLittleEndian(bytes: Uint8Array, offset: number, length: number): bigint {
    let v: bigint = 0n;
    for (let i: number = length - 1; i >= 0; i--) {
      v = (v << 8n) | BigInt(bytes[offset + i] & 0xFF);
    }
    return v;
  }

  private static powMod(base: bigint, exponent: bigint, modulus: bigint): bigint {
    let result: bigint = 1n;
    let b: bigint = base % modulus;
    let e: bigint = exponent;
    while (e > 0n) {
      if ((e & 1n) === 1n) {
        result = (result * b) % modulus;
      }
      b = (b * b) % modulus;
      e >>= 1n;
    }
    return result;
  }
}
