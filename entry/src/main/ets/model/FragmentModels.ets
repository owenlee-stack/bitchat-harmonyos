/**
 * Fragment, sync-request and file-transfer payload models.
 * Mirrors bitchat-android FragmentPayload.kt, RequestSyncPacket.kt and
 * BitchatFilePacket.kt byte-for-byte (iOS-compatible formats).
 */
import { ByteUtils, ByteWriter } from '../common/ByteUtils';
import { SyncConstants } from '../common/ProtocolConstants';

/**
 * Fragment payload structure (matching iOS):
 * - 8 bytes: Fragment ID (random bytes)
 * - 2 bytes: Index (big-endian)
 * - 2 bytes: Total count (big-endian)
 * - 1 byte: Original message type
 * - Variable: Fragment data
 */
export class FragmentPayload {
  static readonly HEADER_SIZE: number = 13;
  static readonly FRAGMENT_ID_SIZE: number = 8;

  readonly fragmentID: Uint8Array;
  readonly index: number;
  readonly total: number;
  readonly originalType: number;
  readonly data: Uint8Array;

  constructor(fragmentID: Uint8Array, index: number, total: number,
    originalType: number, data: Uint8Array) {
    this.fragmentID = fragmentID;
    this.index = index;
    this.total = total;
    this.originalType = originalType;
    this.data = data;
  }

  encode(): Uint8Array {
    if (this.index < 0 || this.index > 0xFFFF) {
      throw new Error('Fragment index would truncate UInt16: ' + this.index);
    }
    if (this.total < 1 || this.total > 0xFFFF) {
      throw new Error('Fragment total would truncate UInt16: ' + this.total);
    }
    if (this.index >= this.total) {
      throw new Error('Fragment index ' + this.index + ' must be below total ' + this.total);
    }
    if (this.fragmentID.length < FragmentPayload.FRAGMENT_ID_SIZE) {
      throw new Error('Fragment ID must be at least 8 bytes');
    }
    const out: Uint8Array = new Uint8Array(FragmentPayload.HEADER_SIZE + this.data.length);
    out.set(this.fragmentID.subarray(0, FragmentPayload.FRAGMENT_ID_SIZE), 0);
    out[8] = (this.index >>> 8) & 0xFF;
    out[9] = this.index & 0xFF;
    out[10] = (this.total >>> 8) & 0xFF;
    out[11] = this.total & 0xFF;
    out[12] = this.originalType & 0xFF;
    if (this.data.length > 0) {
      out.set(this.data, FragmentPayload.HEADER_SIZE);
    }
    return out;
  }

  isValid(): boolean {
    return this.fragmentID.length === FragmentPayload.FRAGMENT_ID_SIZE &&
      this.index >= 0 &&
      this.total > 0 &&
      this.index < this.total &&
      this.data.length > 0;
  }

  getFragmentIDString(): string {
    return ByteUtils.bytesToHex(this.fragmentID);
  }

  static decode(payloadData: Uint8Array): FragmentPayload | null {
    if (payloadData.length < FragmentPayload.HEADER_SIZE) {
      return null;
    }
    try {
      const fragmentID: Uint8Array = payloadData.slice(0, FragmentPayload.FRAGMENT_ID_SIZE);
      const index: number = ((payloadData[8] & 0xFF) << 8) | (payloadData[9] & 0xFF);
      const total: number = ((payloadData[10] & 0xFF) << 8) | (payloadData[11] & 0xFF);
      const originalType: number = payloadData[12] & 0xFF;
      const data: Uint8Array = payloadData.length > FragmentPayload.HEADER_SIZE
        ? payloadData.slice(FragmentPayload.HEADER_SIZE)
        : new Uint8Array(0);
      return new FragmentPayload(fragmentID, index, total, originalType, data);
    } catch (e) {
      return null;
    }
  }

  /** Random 8-byte fragment ID (identifier only, not a secret). */
  static generateFragmentID(): Uint8Array {
    const id: Uint8Array = new Uint8Array(FragmentPayload.FRAGMENT_ID_SIZE);
    for (let i: number = 0; i < id.length; i++) {
      id[i] = Math.floor(Math.random() * 256);
    }
    return id;
  }

  static equals(a: FragmentPayload, b: FragmentPayload): boolean {
    if (!ByteUtils.equals(a.fragmentID, b.fragmentID) || a.index !== b.index ||
      a.total !== b.total || a.originalType !== b.originalType) {
      return false;
    }
    return ByteUtils.equals(a.data, b.data);
  }
}

/**
 * REQUEST_SYNC payload using GCS (Golomb-Coded Set) parameters.
 * TLV (type, length16, value), types:
 *  - 0x01: P (uint8) - Golomb-Rice parameter
 *  - 0x02: M (uint32, big-endian) - hash range (N * 2^P)
 *  - 0x03: data (opaque) - GR bitstream bytes
 */
export class RequestSyncPacket {
  readonly p: number;
  readonly m: number;
  readonly data: Uint8Array;

  constructor(p: number, m: number, data: Uint8Array) {
    this.p = p;
    this.m = m;
    this.data = data;
  }

  encode(): Uint8Array {
    const writer: ByteWriter = new ByteWriter(16 + this.data.length);
    // P
    writer.putByte(0x01);
    writer.putU16BE(1);
    writer.putByte(this.p & 0xFF);
    // M (uint32)
    const m32: number = this.m > 0xFFFFFFFF ? 0xFFFFFFFF : this.m;
    writer.putByte(0x02);
    writer.putU16BE(4);
    writer.putU32BE(m32 >>> 0);
    // data
    writer.putByte(0x03);
    writer.putU16BE(this.data.length);
    writer.putBytes(this.data);
    return writer.toUint8Array();
  }

  static decode(data: Uint8Array): RequestSyncPacket | null {
    let off: number = 0;
    let p: number | null = null;
    let m: number | null = null;
    let payload: Uint8Array | null = null;
    while (off + 3 <= data.length) {
      const t: number = data[off] & 0xFF;
      off += 1;
      const len: number = ((data[off] & 0xFF) << 8) | (data[off + 1] & 0xFF);
      off += 2;
      if (off + len > data.length) {
        return null;
      }
      const v: Uint8Array = data.slice(off, off + len);
      off += len;
      if (t === 0x01) {
        if (len === 1) {
          p = v[0] & 0xFF;
        }
      } else if (t === 0x02) {
        if (len === 4) {
          m = ((v[0] & 0xFF) * 0x1000000) + ((v[1] & 0xFF) << 16) +
            ((v[2] & 0xFF) << 8) + (v[3] & 0xFF);
        }
      } else if (t === 0x03) {
        if (v.length > SyncConstants.MAX_ACCEPT_FILTER_BYTES) {
          return null;
        }
        payload = v;
      }
    }
    if (p === null || m === null || payload === null) {
      return null;
    }
    if (p < 1 || m <= 0) {
      return null;
    }
    return new RequestSyncPacket(p, m, payload);
  }

  static equals(a: RequestSyncPacket, b: RequestSyncPacket): boolean {
    return a.p === b.p && a.m === b.m && ByteUtils.equals(a.data, b.data);
  }
}

/**
 * BitchatFilePacket: TLV-encoded file transfer payload for BLE mesh.
 * TLVs (2-byte big-endian lengths, CONTENT uses a 4-byte length):
 *  - 0x01: filename (UTF-8)
 *  - 0x02: file size (4 bytes, UInt32)
 *  - 0x03: mime type (UTF-8)
 *  - 0x04: content (bytes)
 * Unknown TLV types are skipped, not rejected (forward compatibility).
 */
export class BitchatFilePacket {
  readonly fileName: string;
  readonly fileSize: number;
  readonly mimeType: string;
  readonly content: Uint8Array;

  constructor(fileName: string, fileSize: number, mimeType: string, content: Uint8Array) {
    this.fileName = fileName;
    this.fileSize = fileSize;
    this.mimeType = mimeType;
    this.content = content;
  }

  encode(): Uint8Array | null {
    try {
      const nameBytes: Uint8Array = ByteUtils.utf8Encode(this.fileName);
      const mimeBytes: Uint8Array = ByteUtils.utf8Encode(this.mimeType);
      if (nameBytes.length > 0xFFFF || mimeBytes.length > 0xFFFF) {
        return null;
      }
      const writer: ByteWriter = new ByteWriter(nameBytes.length + mimeBytes.length +
        this.content.length + 24);
      // FILE_NAME
      writer.putByte(0x01);
      writer.putU16BE(nameBytes.length);
      writer.putBytes(nameBytes);
      // FILE_SIZE (4 bytes)
      writer.putByte(0x02);
      writer.putU16BE(4);
      writer.putU32BE((this.fileSize % 0x100000000) >>> 0);
      // MIME_TYPE
      writer.putByte(0x03);
      writer.putU16BE(mimeBytes.length);
      writer.putBytes(mimeBytes);
      // CONTENT (single TLV with 4-byte length)
      writer.putByte(0x04);
      writer.putU32BE(this.content.length);
      writer.putBytes(this.content);
      return writer.toUint8Array();
    } catch (e) {
      return null;
    }
  }

  static decode(data: Uint8Array): BitchatFilePacket | null {
    let off: number = 0;
    let name: string | null = null;
    let size: number | null = null;
    let mime: string | null = null;
    let contentBytes: Uint8Array | null = null;
    while (off < data.length) {
      // Every TLV needs at least a type and a 2-byte length; reject a
      // truncated trailing header instead of silently accepting it.
      if (data.length - off < 3) {
        return null;
      }
      const t: number = data[off] & 0xFF;
      off += 1;
      let len: number;
      if (t === 0x04) {
        if (off + 4 > data.length) {
          return null;
        }
        len = ((data[off] & 0xFF) * 0x1000000) + ((data[off + 1] & 0xFF) << 16) +
          ((data[off + 2] & 0xFF) << 8) + (data[off + 3] & 0xFF);
        off += 4;
      } else {
        if (off + 2 > data.length) {
          return null;
        }
        len = ((data[off] & 0xFF) << 8) | (data[off + 1] & 0xFF);
        off += 2;
      }
      if (len < 0 || off + len > data.length) {
        return null;
      }
      if (t !== 0x01 && t !== 0x02 && t !== 0x03 && t !== 0x04) {
        // Unknown tag: advance past the value without copying it.
        off += len;
        continue;
      }
      const value: Uint8Array = data.slice(off, off + len);
      off += len;
      if (t === 0x01) {
        name = ByteUtils.utf8Decode(value);
      } else if (t === 0x02) {
        if (len !== 4) {
          return null;
        }
        size = ((value[0] & 0xFF) * 0x1000000) + ((value[1] & 0xFF) << 16) +
          ((value[2] & 0xFF) << 8) + (value[3] & 0xFF);
      } else if (t === 0x03) {
        mime = ByteUtils.utf8Decode(value);
      } else {
        if (contentBytes === null) {
          contentBytes = value;
        } else {
          contentBytes = ByteUtils.concat(contentBytes, value);
        }
      }
    }
    if (name === null || contentBytes === null) {
      return null;
    }
    const s: number = size === null ? contentBytes.length : size;
    const m: string = mime === null ? 'application/octet-stream' : mime;
    return new BitchatFilePacket(name, s, m, contentBytes);
  }
}
