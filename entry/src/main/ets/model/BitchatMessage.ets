/**
 * Chat message model with the binary payload wire format
 * (mirrors bitchat-android BitchatMessage.kt byte-for-byte).
 */
import { ByteUtils, ByteReader, ByteWriter } from '../common/ByteUtils';

export enum BitchatMessageType {
  MESSAGE = 0,
  AUDIO = 1,
  IMAGE = 2,
  FILE = 3,
}

export enum DeliveryStatusKind {
  SENDING = 0,
  SENT = 1,
  DELIVERED = 2,
  READ = 3,
  FAILED = 4,
  PARTIALLY_DELIVERED = 5,
}

export class BitchatMessage {
  id: string;
  sender: string;
  content: string;
  type: BitchatMessageType;
  timestamp: number;
  /** Exact 8-byte wire form of `timestamp` (see BitchatPacket.timestampRaw). */
  timestampRaw: Uint8Array | null;
  isRelay: boolean;
  originalSender: string | null;
  isPrivate: boolean;
  recipientNickname: string | null;
  senderPeerId: string | null;
  mentions: string[] | null;
  channel: string | null;
  encryptedContent: Uint8Array | null;
  isEncrypted: boolean;
  deliveryStatus: DeliveryStatusKind;
  deliveryStatusDetail: string;
  senderNostrPubkey: string | null;
  /** US10: sent/received via the signed legacy 0x22 path, not Noise (UI tag). */
  notEndToEndEncrypted: boolean;
  /** US10: outgoing private-media transfer id, for progress binding. */
  transferId: string;

  constructor(sender: string, content: string, timestamp: number) {
    this.id = '';
    this.sender = sender;
    this.content = content;
    this.type = BitchatMessageType.MESSAGE;
    this.timestamp = timestamp;
    this.timestampRaw = null;
    this.isRelay = false;
    this.originalSender = null;
    this.isPrivate = false;
    this.recipientNickname = null;
    this.senderPeerId = null;
    this.mentions = null;
    this.channel = null;
    this.encryptedContent = null;
    this.isEncrypted = false;
    this.deliveryStatus = DeliveryStatusKind.SENDING;
    this.deliveryStatusDetail = '';
    this.senderNostrPubkey = null;
    this.notEndToEndEncrypted = false;
    this.transferId = '';
  }

  static copyOf(other: BitchatMessage): BitchatMessage {
    const msg: BitchatMessage = new BitchatMessage(other.sender, other.content, other.timestamp);
    msg.id = other.id;
    msg.type = other.type;
    msg.timestampRaw = other.timestampRaw === null ? null : other.timestampRaw.slice(0);
    msg.isRelay = other.isRelay;
    msg.originalSender = other.originalSender;
    msg.isPrivate = other.isPrivate;
    msg.recipientNickname = other.recipientNickname;
    msg.senderPeerId = other.senderPeerId;
    msg.mentions = other.mentions === null ? null : other.mentions.slice(0);
    msg.channel = other.channel;
    msg.encryptedContent = other.encryptedContent === null ? null : other.encryptedContent.slice(0);
    msg.isEncrypted = other.isEncrypted;
    msg.deliveryStatus = other.deliveryStatus;
    msg.deliveryStatusDetail = other.deliveryStatusDetail;
    msg.senderNostrPubkey = other.senderNostrPubkey;
    msg.notEndToEndEncrypted = other.notEndToEndEncrypted;
    msg.transferId = other.transferId;
    return msg;
  }

  toBinaryPayload(): Uint8Array | null {
    try {
      const writer: ByteWriter = new ByteWriter(256);

      let flags: number = 0;
      if (this.isRelay) {
        flags |= 0x01;
      }
      if (this.isPrivate) {
        flags |= 0x02;
      }
      if (this.originalSender !== null) {
        flags |= 0x04;
      }
      if (this.recipientNickname !== null) {
        flags |= 0x08;
      }
      if (this.senderPeerId !== null) {
        flags |= 0x10;
      }
      if (this.mentions !== null && this.mentions.length > 0) {
        flags |= 0x20;
      }
      if (this.channel !== null) {
        flags |= 0x40;
      }
      if (this.isEncrypted) {
        flags |= 0x80;
      }
      writer.putByte(flags);
      if (this.timestampRaw !== null) {
        writer.putBytes(this.timestampRaw);
      } else {
        writer.putU64BE(this.timestamp);
      }

      const idBytes: Uint8Array = ByteUtils.utf8Encode(this.id);
      writer.putByte(Math.min(idBytes.length, 255));
      writer.putBytes(idBytes.subarray(0, Math.min(idBytes.length, 255)));

      const senderBytes: Uint8Array = ByteUtils.utf8Encode(this.sender);
      writer.putByte(Math.min(senderBytes.length, 255));
      writer.putBytes(senderBytes.subarray(0, Math.min(senderBytes.length, 255)));

      if (this.isEncrypted && this.encryptedContent !== null) {
        const cipher: Uint8Array = this.encryptedContent;
        const length: number = Math.min(cipher.length, 65535);
        writer.putU16BE(length);
        writer.putBytes(cipher.subarray(0, length));
      } else {
        const contentBytes: Uint8Array = ByteUtils.utf8Encode(this.content);
        const length: number = Math.min(contentBytes.length, 65535);
        writer.putU16BE(length);
        writer.putBytes(contentBytes.subarray(0, length));
      }

      if (this.originalSender !== null) {
        const origBytes: Uint8Array = ByteUtils.utf8Encode(this.originalSender);
        writer.putByte(Math.min(origBytes.length, 255));
        writer.putBytes(origBytes.subarray(0, Math.min(origBytes.length, 255)));
      }
      if (this.recipientNickname !== null) {
        const recipBytes: Uint8Array = ByteUtils.utf8Encode(this.recipientNickname);
        writer.putByte(Math.min(recipBytes.length, 255));
        writer.putBytes(recipBytes.subarray(0, Math.min(recipBytes.length, 255)));
      }
      if (this.senderPeerId !== null) {
        const peerBytes: Uint8Array = ByteUtils.utf8Encode(this.senderPeerId);
        writer.putByte(Math.min(peerBytes.length, 255));
        writer.putBytes(peerBytes.subarray(0, Math.min(peerBytes.length, 255)));
      }
      if (this.mentions !== null) {
        const capped: string[] = this.mentions.slice(0, 255);
        writer.putByte(capped.length);
        for (let i: number = 0; i < capped.length; i++) {
          const mentionBytes: Uint8Array = ByteUtils.utf8Encode(capped[i]);
          writer.putByte(Math.min(mentionBytes.length, 255));
          writer.putBytes(mentionBytes.subarray(0, Math.min(mentionBytes.length, 255)));
        }
      }
      if (this.channel !== null) {
        const channelBytes: Uint8Array = ByteUtils.utf8Encode(this.channel);
        writer.putByte(Math.min(channelBytes.length, 255));
        writer.putBytes(channelBytes.subarray(0, Math.min(channelBytes.length, 255)));
      }
      return writer.toUint8Array();
    } catch (e) {
      return null;
    }
  }

  static fromBinaryPayload(data: Uint8Array): BitchatMessage | null {
    try {
      if (data.length < 13) {
        return null;
      }
      const reader: ByteReader = new ByteReader(data);
      const flags: number = reader.getByte();
      const isRelay: boolean = (flags & 0x01) !== 0;
      const isPrivate: boolean = (flags & 0x02) !== 0;
      const hasOriginalSender: boolean = (flags & 0x04) !== 0;
      const hasRecipientNickname: boolean = (flags & 0x08) !== 0;
      const hasSenderPeerId: boolean = (flags & 0x10) !== 0;
      const hasMentions: boolean = (flags & 0x20) !== 0;
      const hasChannel: boolean = (flags & 0x40) !== 0;
      const isEncrypted: boolean = (flags & 0x80) !== 0;

      const timestampRaw: Uint8Array = reader.getU64Bytes();
      const timestamp: number = ByteUtils.u64BytesToNumber(timestampRaw);

      const idLength: number = reader.getByte();
      if (reader.remaining() < idLength) {
        return null;
      }
      const id: string = ByteUtils.utf8Decode(reader.getBytes(idLength));

      const senderLength: number = reader.getByte();
      if (reader.remaining() < senderLength) {
        return null;
      }
      const sender: string = ByteUtils.utf8Decode(reader.getBytes(senderLength));

      const contentLength: number = reader.getU16BE();
      if (reader.remaining() < contentLength) {
        return null;
      }

      let content: string = '';
      let encryptedContent: Uint8Array | null = null;
      if (isEncrypted) {
        encryptedContent = reader.getBytes(contentLength);
      } else {
        content = ByteUtils.utf8Decode(reader.getBytes(contentLength));
      }

      const originalSender: string | null = hasOriginalSender && reader.hasRemaining()
        ? BitchatMessage.readLengthPrefixedString(reader) : null;
      const recipientNickname: string | null = hasRecipientNickname && reader.hasRemaining()
        ? BitchatMessage.readLengthPrefixedString(reader) : null;
      const senderPeerId: string | null = hasSenderPeerId && reader.hasRemaining()
        ? BitchatMessage.readLengthPrefixedString(reader) : null;

      let mentions: string[] | null = null;
      if (hasMentions && reader.hasRemaining()) {
        const mentionCount: number = reader.getByte();
        const mentionList: string[] = [];
        for (let i: number = 0; i < mentionCount; i++) {
          if (!reader.hasRemaining()) {
            break;
          }
          const mention: string | null = BitchatMessage.readLengthPrefixedString(reader);
          if (mention !== null) {
            mentionList.push(mention);
          }
        }
        if (mentionList.length > 0) {
          mentions = mentionList;
        }
      }

      const channel: string | null = hasChannel && reader.hasRemaining()
        ? BitchatMessage.readLengthPrefixedString(reader) : null;

      const message: BitchatMessage = new BitchatMessage(sender, content, timestamp);
      message.id = id;
      message.timestampRaw = timestampRaw;
      message.isRelay = isRelay;
      message.originalSender = originalSender;
      message.isPrivate = isPrivate;
      message.recipientNickname = recipientNickname;
      message.senderPeerId = senderPeerId;
      message.mentions = mentions;
      message.channel = channel;
      message.encryptedContent = encryptedContent;
      message.isEncrypted = isEncrypted;
      return message;
    } catch (e) {
      return null;
    }
  }

  private static readLengthPrefixedString(reader: ByteReader): string | null {
    if (!reader.hasRemaining()) {
      return null;
    }
    const length: number = reader.getByte();
    if (reader.remaining() < length) {
      return null;
    }
    return ByteUtils.utf8Decode(reader.getBytes(length));
  }

  static equals(a: BitchatMessage, b: BitchatMessage): boolean {
    if (a.id !== b.id || a.sender !== b.sender || a.content !== b.content || a.timestamp !== b.timestamp) {
      return false;
    }
    if (a.timestampRaw !== null && b.timestampRaw !== null &&
      !ByteUtils.equals(a.timestampRaw, b.timestampRaw)) {
      return false;
    }
    if (a.type !== b.type || a.isRelay !== b.isRelay || a.isPrivate !== b.isPrivate ||
      a.isEncrypted !== b.isEncrypted) {
      return false;
    }
    if (a.originalSender !== b.originalSender || a.recipientNickname !== b.recipientNickname ||
      a.senderPeerId !== b.senderPeerId || a.channel !== b.channel) {
      return false;
    }
    if ((a.mentions === null) !== (b.mentions === null)) {
      return false;
    }
    if (a.mentions !== null && b.mentions !== null) {
      if (a.mentions.length !== b.mentions.length) {
        return false;
      }
      for (let i: number = 0; i < a.mentions.length; i++) {
        if (a.mentions[i] !== b.mentions[i]) {
          return false;
        }
      }
    }
    if ((a.encryptedContent === null) !== (b.encryptedContent === null)) {
      return false;
    }
    if (a.encryptedContent !== null && b.encryptedContent !== null) {
      return ByteUtils.equals(a.encryptedContent, b.encryptedContent);
    }
    return true;
  }
}
