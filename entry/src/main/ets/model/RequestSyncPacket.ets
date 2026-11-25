/**
 * REQUEST_SYNC payload model - mirrors bitchat-android RequestSyncPacket.kt:
 * TLV (type, length16 BE, value) with types
 *  - 0x01: P (uint8) - Golomb-Rice parameter
 *  - 0x02: M (uint32 BE) - hash range (N * 2^P)
 *  - 0x03: data (opaque) - Golomb-Rice bitstream bytes
 * Receiver-side hard cap: data over SyncConstants.MAX_ACCEPT_FILTER_BYTES
 * fails decode (DoS guard, also enforced by GCS parameter checks).
 */
import { SyncConstants } from '../common/ProtocolConstants';

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
    const m32: number = Math.min(this.m, 0xFFFFFFFF);
    const out: Uint8Array =
      new Uint8Array(3 + 1 + 3 + 4 + 3 + this.data.length);
    // P
    out[0] = 0x01;
    out[1] = 0x00;
    out[2] = 0x01;
    out[3] = this.p & 0xFF;
    // M (uint32 BE)
    out[4] = 0x02;
    out[5] = 0x00;
    out[6] = 0x04;
    out[7] = (m32 >>> 24) & 0xFF;
    out[8] = (m32 >>> 16) & 0xFF;
    out[9] = (m32 >>> 8) & 0xFF;
    out[10] = m32 & 0xFF;
    // data
    out[11] = 0x03;
    out[12] = (this.data.length >>> 8) & 0xFF;
    out[13] = this.data.length & 0xFF;
    out.set(this.data, 14);
    return out;
  }

  static decode(data: Uint8Array): RequestSyncPacket | null {
    let offset: number = 0;
    let p: number = -1;
    let m: number = -1;
    let payload: Uint8Array | null = null;
    while (offset + 3 <= data.length) {
      const type: number = data[offset] & 0xFF;
      const length: number = ((data[offset + 1] & 0xFF) << 8) | (data[offset + 2] & 0xFF);
      offset += 3;
      if (offset + length > data.length) {
        return null;
      }
      const value: Uint8Array = data.slice(offset, offset + length);
      offset += length;
      if (type === 0x01 && length === 1) {
        p = value[0] & 0xFF;
      } else if (type === 0x02 && length === 4) {
        m = ((value[0] & 0xFF) * 16777216) + ((value[1] & 0xFF) << 16) +
          ((value[2] & 0xFF) << 8) + (value[3] & 0xFF);
      } else if (type === 0x03) {
        if (value.length > SyncConstants.MAX_ACCEPT_FILTER_BYTES) {
          return null;
        }
        payload = value;
      }
    }
    if (p < 1 || m <= 0 || payload === null) {
      return null;
    }
    return new RequestSyncPacket(p, m, payload);
  }
}
