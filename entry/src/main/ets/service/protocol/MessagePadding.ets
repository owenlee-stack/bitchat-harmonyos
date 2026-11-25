/**
 * Privacy-preserving padding utilities - exact same as iOS version.
 * Provides traffic analysis resistance by normalizing message sizes.
 * Mirrors bitchat-android MessagePadding.kt.
 */

export class MessagePadding {
  private static readonly BLOCK_SIZES: number[] = [256, 512, 1024, 2048];

  /** Find the smallest standard block that fits dataSize + AEAD overhead. */
  static optimalBlockSize(dataSize: number): number {
    const totalSize: number = dataSize + 16;
    for (let i: number = 0; i < MessagePadding.BLOCK_SIZES.length; i++) {
      if (totalSize <= MessagePadding.BLOCK_SIZES[i]) {
        return MessagePadding.BLOCK_SIZES[i];
      }
    }
    // For very large messages, just use the original size (fragmented anyway).
    return dataSize;
  }

  /** PKCS#7-style padding to reach the target size (iOS compatible). */
  static pad(data: Uint8Array, targetSize: number): Uint8Array {
    if (data.length >= targetSize) {
      return data;
    }
    const paddingNeeded: number = targetSize - data.length;
    // Constrain to 255 to fit a single-byte pad length marker.
    if (paddingNeeded <= 0 || paddingNeeded > 255) {
      return data;
    }
    const result: Uint8Array = new Uint8Array(targetSize);
    result.set(data, 0);
    for (let i: number = data.length; i < targetSize; i++) {
      result[i] = paddingNeeded;
    }
    return result;
  }

  /** Strict PKCS#7 validation; invalid padding returns the original data. */
  static unpad(data: Uint8Array): Uint8Array {
    if (data.length === 0) {
      return data;
    }
    const last: number = data[data.length - 1];
    const paddingLength: number = last & 0xFF;
    if (paddingLength <= 0 || paddingLength > data.length) {
      return data;
    }
    const start: number = data.length - paddingLength;
    for (let i: number = start; i < data.length; i++) {
      if (data[i] !== last) {
        return data;
      }
    }
    return data.slice(0, start);
  }
}
