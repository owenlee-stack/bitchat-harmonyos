/**
 * Bech32 encoding/decoding for Nostr (npub/nsec).
 * Mirrors bitchat-android Bech32.kt byte-for-byte, including the strict
 * padding checks that reject non-canonical encodings.
 */

/** Result of a successful Bech32 decode: human-readable part + payload bytes. */
export class Bech32Result {
  readonly hrp: string;
  readonly data: Uint8Array;

  constructor(hrp: string, data: Uint8Array) {
    this.hrp = hrp;
    this.data = data;
  }
}

export class Bech32 {
  private static readonly CHARSET: string = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
  private static readonly GENERATOR: number[] = [
    0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3
  ];

  /** Encode data with HRP (Human Readable Part). */
  static encode(hrp: string, data: Uint8Array): string {
    if (hrp.length < 1 || hrp.length > 83) {
      throw new Error('Invalid HRP length');
    }
    const input: number[] = [];
    for (let i: number = 0; i < data.length; i++) {
      input.push(data[i] & 0xFF);
    }
    const values: number[] = Bech32.convertBits(input, 8, 5, true);
    const checksum: number[] = Bech32.createChecksum(hrp, values);
    let out: string = hrp + '1';
    for (let i: number = 0; i < values.length; i++) {
      out += Bech32.CHARSET.charAt(values[i]);
    }
    for (let i: number = 0; i < checksum.length; i++) {
      out += Bech32.CHARSET.charAt(checksum[i]);
    }
    return out;
  }

  /** Decode a bech32 string; throws on invalid input. */
  static decode(bech32String: string): Bech32Result {
    const separatorIndex: number = bech32String.lastIndexOf('1');
    if (separatorIndex < 1 || separatorIndex > 83) {
      throw new Error('Invalid HRP length or missing separator');
    }
    const hrp: string = bech32String.substring(0, separatorIndex);
    const dataString: string = bech32String.substring(separatorIndex + 1);

    for (let i: number = 0; i < hrp.length; i++) {
      if (hrp.charCodeAt(i) >= 128) {
        throw new Error('Invalid HRP characters');
      }
    }

    const values: number[] = [];
    for (let i: number = 0; i < dataString.length; i++) {
      const index: number = Bech32.CHARSET.indexOf(dataString.charAt(i));
      if (index < 0) {
        throw new Error('Invalid character: ' + dataString.charAt(i));
      }
      values.push(index);
    }

    if (values.length < 6) {
      throw new Error('Data too short');
    }
    const payloadValues: number[] = values.slice(0, values.length - 6);
    const checksum: number[] = values.slice(values.length - 6);
    const expectedChecksum: number[] = Bech32.createChecksum(hrp, payloadValues);
    for (let i: number = 0; i < 6; i++) {
      if (checksum[i] !== expectedChecksum[i]) {
        throw new Error('Invalid checksum');
      }
    }

    const bytesInt: number[] = Bech32.convertBits(payloadValues, 5, 8, false);
    const bytes: Uint8Array = new Uint8Array(bytesInt.length);
    for (let i: number = 0; i < bytesInt.length; i++) {
      bytes[i] = bytesInt[i] & 0xFF;
    }
    return new Bech32Result(hrp, bytes);
  }

  private static convertBits(data: number[], fromBits: number, toBits: number, pad: boolean): number[] {
    let acc: number = 0;
    let bits: number = 0;
    const result: number[] = [];
    const maxv: number = (1 << toBits) - 1;

    for (let i: number = 0; i < data.length; i++) {
      acc = ((acc << fromBits) | data[i]) >>> 0;
      bits += fromBits;
      while (bits >= toBits) {
        bits -= toBits;
        result.push((acc >>> bits) & maxv);
      }
    }

    if (pad && bits > 0) {
      result.push((acc << (toBits - bits)) & maxv);
    } else if (!pad) {
      if (bits >= fromBits) {
        throw new Error('Excess padding');
      }
      if (((acc << (toBits - bits)) & maxv) !== 0) {
        throw new Error('Nonzero padding');
      }
    }

    return result;
  }

  private static createChecksum(hrp: string, values: number[]): number[] {
    const checksumValues: number[] = Bech32.hrpExpand(hrp);
    for (let i: number = 0; i < values.length; i++) {
      checksumValues.push(values[i]);
    }
    for (let i: number = 0; i < 6; i++) {
      checksumValues.push(0);
    }
    const polymod: number = Bech32.polymod(checksumValues) ^ 1;

    const checksum: number[] = [];
    for (let i: number = 0; i < 6; i++) {
      checksum.push((polymod >>> (5 * (5 - i))) & 31);
    }
    return checksum;
  }

  private static hrpExpand(hrp: string): number[] {
    const result: number[] = [];
    for (let i: number = 0; i < hrp.length; i++) {
      result.push(hrp.charCodeAt(i) >>> 5);
    }
    result.push(0);
    for (let i: number = 0; i < hrp.length; i++) {
      result.push(hrp.charCodeAt(i) & 31);
    }
    return result;
  }

  private static polymod(values: number[]): number {
    let chk: number = 1;
    for (let i: number = 0; i < values.length; i++) {
      const b: number = chk >>> 25;
      chk = (((chk & 0x1ffffff) << 5) ^ values[i]) >>> 0;
      for (let j: number = 0; j < 5; j++) {
        if (((b >>> j) & 1) === 1) {
          chk = (chk ^ Bech32.GENERATOR[j]) >>> 0;
        }
      }
    }
    return chk;
  }
}
