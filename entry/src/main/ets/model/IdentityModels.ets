/**
 * Identity announcement, peer capabilities and Noise payload models.
 * Mirrors bitchat-android IdentityAnnouncement.kt, PeerCapabilities.kt and
 * NoiseEncrypted.kt byte-for-byte (iOS-compatible TLV formats).
 */
import { ByteUtils, ByteWriter } from '../common/ByteUtils';

export enum NoisePayloadType {
  PRIVATE_MESSAGE = 0x01,
  READ_RECEIPT = 0x02,
  DELIVERED = 0x03,
  VOICE_FRAME = 0x08,
  VERIFY_CHALLENGE = 0x10,
  VERIFY_RESPONSE = 0x11,
  FILE_TRANSFER = 0x20,
  PEER_STATE = 0x21,
}

export function noisePayloadTypeFromValue(value: number): NoisePayloadType | null {
  // #1434 prerelease iOS builds briefly emitted private files as 0x09. The
  // alias stays decode-only: encoding always emits the canonical 0x20.
  if (value === 0x09) {
    return NoisePayloadType.FILE_TRANSFER;
  }
  switch (value) {
    case NoisePayloadType.PRIVATE_MESSAGE:
      return NoisePayloadType.PRIVATE_MESSAGE;
    case NoisePayloadType.READ_RECEIPT:
      return NoisePayloadType.READ_RECEIPT;
    case NoisePayloadType.DELIVERED:
      return NoisePayloadType.DELIVERED;
    case NoisePayloadType.VOICE_FRAME:
      return NoisePayloadType.VOICE_FRAME;
    case NoisePayloadType.VERIFY_CHALLENGE:
      return NoisePayloadType.VERIFY_CHALLENGE;
    case NoisePayloadType.VERIFY_RESPONSE:
      return NoisePayloadType.VERIFY_RESPONSE;
    case NoisePayloadType.FILE_TRANSFER:
      return NoisePayloadType.FILE_TRANSFER;
    case NoisePayloadType.PEER_STATE:
      return NoisePayloadType.PEER_STATE;
    default:
      return null;
  }
}

export class NoisePayload {
  readonly type: NoisePayloadType;
  readonly data: Uint8Array;

  constructor(type: NoisePayloadType, data: Uint8Array) {
    this.type = type;
    this.data = data;
  }

  /** Format: [type_byte][payload_data]. */
  encode(): Uint8Array {
    const out: Uint8Array = new Uint8Array(1 + this.data.length);
    out[0] = this.type;
    out.set(this.data, 1);
    return out;
  }

  static decode(data: Uint8Array): NoisePayload | null {
    if (data.length === 0) {
      return null;
    }
    const type: NoisePayloadType | null = noisePayloadTypeFromValue(data[0] & 0xFF);
    if (type === null) {
      return null;
    }
    const payload: Uint8Array = data.length > 1 ? data.slice(1) : new Uint8Array(0);
    return new NoisePayload(type, payload);
  }

  static equals(a: NoisePayload, b: NoisePayload): boolean {
    if (a.type !== b.type) {
      return false;
    }
    return ByteUtils.equals(a.data, b.data);
  }
}

export class PrivateMessagePacket {
  readonly messageID: string;
  readonly content: string;

  constructor(messageID: string, content: string) {
    this.messageID = messageID;
    this.content = content;
  }

  /** TLV format: [00][len][messageID][01][len][content], 1-byte lengths. */
  encode(): Uint8Array | null {
    const idData: Uint8Array = ByteUtils.utf8Encode(this.messageID);
    const contentData: Uint8Array = ByteUtils.utf8Encode(this.content);
    if (idData.length > 255 || contentData.length > 255) {
      return null;
    }
    const writer: ByteWriter = new ByteWriter(idData.length + contentData.length + 8);
    writer.putByte(0x00);
    writer.putByte(idData.length);
    writer.putBytes(idData);
    writer.putByte(0x01);
    writer.putByte(contentData.length);
    writer.putBytes(contentData);
    return writer.toUint8Array();
  }

  static decode(data: Uint8Array): PrivateMessagePacket | null {
    let offset: number = 0;
    let messageID: string | null = null;
    let content: string | null = null;
    while (offset + 2 <= data.length) {
      const t: number = data[offset] & 0xFF;
      if (t !== 0x00 && t !== 0x01) {
        return null;
      }
      offset += 1;
      const length: number = data[offset] & 0xFF;
      offset += 1;
      if (offset + length > data.length) {
        return null;
      }
      const value: Uint8Array = data.slice(offset, offset + length);
      offset += length;
      if (t === 0x00) {
        messageID = ByteUtils.utf8Decode(value);
      } else {
        content = ByteUtils.utf8Decode(value);
      }
    }
    if (messageID === null || content === null) {
      return null;
    }
    return new PrivateMessagePacket(messageID, content);
  }

  static equals(a: PrivateMessagePacket, b: PrivateMessagePacket): boolean {
    return a.messageID === b.messageID && a.content === b.content;
  }
}

export class ReadReceipt {
  readonly originalMessageID: string;
  readonly readerPeerID: string | null;

  constructor(originalMessageID: string, readerPeerID: string | null) {
    this.originalMessageID = originalMessageID;
    this.readerPeerID = readerPeerID;
  }
}

/**
 * Feature bits advertised in IdentityAnnouncement TLV 0x05: a minimal
 * little-endian bitfield that always contains at least one byte. Unknown bits
 * in the low 64 bits are kept so decode/re-encode does not erase capabilities
 * added by newer clients.
 */
export class PeerCapabilities {
  readonly rawValue: number;

  constructor(rawValue: number) {
    this.rawValue = rawValue;
  }

  contains(capability: PeerCapabilities): boolean {
    // Exact bit test that also works for raw values beyond the 32-bit range.
    let cap: number = capability.rawValue;
    let raw: number = this.rawValue;
    while (cap > 0) {
      const capBit: number = cap % 2;
      if (capBit === 1) {
        if (raw % 2 !== 1) {
          return false;
        }
      }
      cap = Math.floor(cap / 2);
      raw = Math.floor(raw / 2);
    }
    return true;
  }

  encoded(): Uint8Array {
    const bytes: number[] = [];
    let remaining: number = this.rawValue;
    do {
      bytes.push(remaining % 256);
      remaining = Math.floor(remaining / 256);
    } while (remaining !== 0);
    const out: Uint8Array = new Uint8Array(bytes.length);
    for (let i: number = 0; i < bytes.length; i++) {
      out[i] = bytes[i];
    }
    return out;
  }

  /** Decode the low 64 bits; ignore future extension bytes (iOS behavior). */
  static decode(data: Uint8Array): PeerCapabilities {
    let rawValue: number = 0;
    const n: number = Math.min(data.length, 8);
    for (let i: number = 0; i < n; i++) {
      rawValue += (data[i] & 0xFF) * Math.pow(256, i);
    }
    return new PeerCapabilities(rawValue);
  }

  static readonly NONE: PeerCapabilities = new PeerCapabilities(0);
  static readonly PREKEYS: PeerCapabilities = new PeerCapabilities(1);
  static readonly WIFI_BULK: PeerCapabilities = new PeerCapabilities(2);
  static readonly GATEWAY: PeerCapabilities = new PeerCapabilities(4);
  static readonly GROUPS: PeerCapabilities = new PeerCapabilities(8);
  static readonly BOARD: PeerCapabilities = new PeerCapabilities(16);
  static readonly VOUCH: PeerCapabilities = new PeerCapabilities(32);
  static readonly MESH_DIAGNOSTICS: PeerCapabilities = new PeerCapabilities(64);
  static readonly BRIDGE: PeerCapabilities = new PeerCapabilities(128);
  /** Noise-encrypted private BitchatFilePacket using payload type 0x20. */
  static readonly PRIVATE_MEDIA: PeerCapabilities = new PeerCapabilities(256);
  static readonly PRIVATE_MEDIA_RECEIPTS: PeerCapabilities = new PeerCapabilities(512);
  /** Reserved by iOS; decode it but do not advertise or act on it. */
  static readonly NON_DESTRUCTIVE_NOISE_REPLACEMENT: PeerCapabilities = new PeerCapabilities(1024);
  /** Capabilities implemented by this build. */
  static readonly LOCAL_SUPPORTED: PeerCapabilities = PeerCapabilities.PRIVATE_MEDIA;

  static equals(a: PeerCapabilities | null, b: PeerCapabilities | null): boolean {
    if ((a === null) !== (b === null)) {
      return false;
    }
    if (a === null || b === null) {
      return true;
    }
    return a.rawValue === b.rawValue;
  }
}

/** An announcement TLV not understood by this build, retained verbatim. */
export class UnknownAnnouncementTLV {
  readonly type: number;
  readonly value: Uint8Array;

  constructor(type: number, value: Uint8Array) {
    if (type < 0 || type > 0xFF) {
      throw new Error('TLV type must fit in one byte');
    }
    this.type = type;
    this.value = value;
  }
}

/**
 * Identity announcement with TLV encoding, compatible with the iOS
 * AnnouncementPacket TLV format.
 */
export class IdentityAnnouncement {
  readonly nickname: string;
  readonly noisePublicKey: Uint8Array;
  readonly signingPublicKey: Uint8Array;
  readonly capabilities: PeerCapabilities | null;
  readonly unknownTLVs: UnknownAnnouncementTLV[];

  constructor(nickname: string, noisePublicKey: Uint8Array, signingPublicKey: Uint8Array,
    capabilities: PeerCapabilities | null, unknownTLVs: UnknownAnnouncementTLV[]) {
    this.nickname = nickname;
    this.noisePublicKey = noisePublicKey;
    this.signingPublicKey = signingPublicKey;
    this.capabilities = capabilities;
    this.unknownTLVs = unknownTLVs;
  }

  /** TLV order: nickname(0x01), noise key(0x02), signing key(0x03), capabilities(0x05), extensions. */
  encode(): Uint8Array | null {
    const nicknameData: Uint8Array = ByteUtils.utf8Encode(this.nickname);
    if (nicknameData.length > 255 || this.noisePublicKey.length > 255 ||
      this.signingPublicKey.length > 255) {
      return null;
    }
    for (let i: number = 0; i < this.unknownTLVs.length; i++) {
      if (this.unknownTLVs[i].value.length > 255) {
        return null;
      }
    }
    const writer: ByteWriter = new ByteWriter(nicknameData.length + this.noisePublicKey.length +
      this.signingPublicKey.length + 16);
    writer.putByte(0x01);
    writer.putByte(nicknameData.length);
    writer.putBytes(nicknameData);
    writer.putByte(0x02);
    writer.putByte(this.noisePublicKey.length);
    writer.putBytes(this.noisePublicKey);
    writer.putByte(0x03);
    writer.putByte(this.signingPublicKey.length);
    writer.putBytes(this.signingPublicKey);
    if (this.capabilities !== null) {
      const capabilityBytes: Uint8Array = this.capabilities.encoded();
      writer.putByte(0x05);
      writer.putByte(capabilityBytes.length);
      writer.putBytes(capabilityBytes);
    }
    for (let i: number = 0; i < this.unknownTLVs.length; i++) {
      writer.putByte(this.unknownTLVs[i].type);
      writer.putByte(this.unknownTLVs[i].value.length);
      writer.putBytes(this.unknownTLVs[i].value);
    }
    return writer.toUint8Array();
  }

  static decode(data: Uint8Array): IdentityAnnouncement | null {
    let offset: number = 0;
    let nickname: string | null = null;
    let noisePublicKey: Uint8Array | null = null;
    let signingPublicKey: Uint8Array | null = null;
    let capabilities: PeerCapabilities | null = null;
    const unknownTLVs: UnknownAnnouncementTLV[] = [];
    while (offset + 2 <= data.length) {
      const typeValue: number = data[offset] & 0xFF;
      offset += 1;
      const length: number = data[offset] & 0xFF;
      offset += 1;
      if (offset + length > data.length) {
        return null;
      }
      const value: Uint8Array = data.slice(offset, offset + length);
      offset += length;
      if (typeValue === 0x01) {
        nickname = ByteUtils.utf8Decode(value);
      } else if (typeValue === 0x02) {
        noisePublicKey = value;
      } else if (typeValue === 0x03) {
        signingPublicKey = value;
      } else if (typeValue === 0x05) {
        capabilities = PeerCapabilities.decode(value);
      } else {
        unknownTLVs.push(new UnknownAnnouncementTLV(typeValue, value));
      }
    }
    if (nickname === null || noisePublicKey === null || signingPublicKey === null) {
      return null;
    }
    return new IdentityAnnouncement(nickname, noisePublicKey, signingPublicKey, capabilities, unknownTLVs);
  }

  /** Construct the announcement emitted by this build. */
  static forLocalPeer(nickname: string, noisePublicKey: Uint8Array,
    signingPublicKey: Uint8Array): IdentityAnnouncement {
    return new IdentityAnnouncement(nickname, noisePublicKey, signingPublicKey,
      PeerCapabilities.LOCAL_SUPPORTED, []);
  }

  static equals(a: IdentityAnnouncement, b: IdentityAnnouncement): boolean {
    if (a.nickname !== b.nickname) {
      return false;
    }
    if (!ByteUtils.equals(a.noisePublicKey, b.noisePublicKey)) {
      return false;
    }
    if (!ByteUtils.equals(a.signingPublicKey, b.signingPublicKey)) {
      return false;
    }
    if (!PeerCapabilities.equals(a.capabilities, b.capabilities)) {
      return false;
    }
    if (a.unknownTLVs.length !== b.unknownTLVs.length) {
      return false;
    }
    for (let i: number = 0; i < a.unknownTLVs.length; i++) {
      if (a.unknownTLVs[i].type !== b.unknownTLVs[i].type ||
        !ByteUtils.equals(a.unknownTLVs[i].value, b.unknownTLVs[i].value)) {
        return false;
      }
    }
    return true;
  }
}

/**
 * Canonical payload carried inside Noise payload type 0x21 (US10; Android
 * AuthenticatedPeerState.kt parity).
 *
 * Wire format:
 * `[version=0x01][type=0x01][len=1...8][minimal LE capabilities]`
 * `[type=0x02][len=32][Ed25519 public key]`
 *
 * Unknown TLVs are skipped. Both known fields must occur exactly once.
 */
export class AuthenticatedPeerState {
  static readonly VERSION: number = 0x01;
  private static readonly CAPABILITIES_TLV: number = 0x01;
  private static readonly SIGNING_PUBLIC_KEY_TLV: number = 0x02;
  static readonly SIGNING_PUBLIC_KEY_SIZE: number = 32;

  readonly capabilities: PeerCapabilities;
  readonly signingPublicKey: Uint8Array;

  constructor(capabilities: PeerCapabilities, signingPublicKey: Uint8Array) {
    if (signingPublicKey.length !== AuthenticatedPeerState.SIGNING_PUBLIC_KEY_SIZE) {
      throw new Error('Ed25519 public key must be 32 bytes');
    }
    this.capabilities = capabilities;
    this.signingPublicKey = new Uint8Array(signingPublicKey);
  }

  encode(): Uint8Array {
    const capabilityBytes: Uint8Array = this.capabilities.encoded();
    const writer: ByteWriter = new ByteWriter(1 + 2 + capabilityBytes.length +
      2 + this.signingPublicKey.length);
    writer.putByte(AuthenticatedPeerState.VERSION);
    writer.putByte(AuthenticatedPeerState.CAPABILITIES_TLV);
    writer.putByte(capabilityBytes.length);
    writer.putBytes(capabilityBytes);
    writer.putByte(AuthenticatedPeerState.SIGNING_PUBLIC_KEY_TLV);
    writer.putByte(AuthenticatedPeerState.SIGNING_PUBLIC_KEY_SIZE);
    writer.putBytes(this.signingPublicKey);
    return writer.toUint8Array();
  }

  static decode(data: Uint8Array): AuthenticatedPeerState | null {
    if (data.length === 0 || (data[0] & 0xFF) !== AuthenticatedPeerState.VERSION) {
      return null;
    }
    let offset: number = 1;
    let capabilities: PeerCapabilities | null = null;
    let signingPublicKey: Uint8Array | null = null;
    while (offset < data.length) {
      if (offset + 2 > data.length) {
        return null;
      }
      const type: number = data[offset] & 0xFF;
      const length: number = data[offset + 1] & 0xFF;
      offset += 2;
      if (offset + length > data.length) {
        return null;
      }
      const value: Uint8Array = data.slice(offset, offset + length);
      offset += length;
      if (type === AuthenticatedPeerState.CAPABILITIES_TLV) {
        if (capabilities !== null || length < 1 || length > 8) {
          return null;
        }
        const decoded: PeerCapabilities = PeerCapabilities.decode(value);
        // A non-minimal (non-canonical) encoding is rejected outright.
        if (!ByteUtils.equals(decoded.encoded(), value)) {
          return null;
        }
        capabilities = decoded;
      } else if (type === AuthenticatedPeerState.SIGNING_PUBLIC_KEY_TLV) {
        if (signingPublicKey !== null || length !== AuthenticatedPeerState.SIGNING_PUBLIC_KEY_SIZE) {
          return null;
        }
        signingPublicKey = value;
      }
    }
    if (capabilities === null || signingPublicKey === null) {
      return null;
    }
    return new AuthenticatedPeerState(capabilities, signingPublicKey);
  }

  static equals(a: AuthenticatedPeerState, b: AuthenticatedPeerState): boolean {
    if (!PeerCapabilities.equals(a.capabilities, b.capabilities)) {
      return false;
    }
    return ByteUtils.equals(a.signingPublicKey, b.signingPublicKey);
  }
}
