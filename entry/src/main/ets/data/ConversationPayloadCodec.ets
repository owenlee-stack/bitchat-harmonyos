/**
 * Binary codec for the encrypted private-message payload stored in the
 * conversation database (US4, port of the payload half of bitchat-android
 * ConversationRepository.kt).
 *
 * Android serializes the sensitive message fields as JSON inside the
 * AES-GCM payload_ciphertext column. The HarmonyOS port uses a compact
 * binary TLV record instead - an intentional divergence: the payload is
 * local-only at-rest ciphertext sealed by SecureKeyStore, never crosses
 * clients, and a binary record avoids JSON.parse type-normalization in
 * strict ArkTS. The Android JSON keys map to TLV tags 1:1.
 *
 * Record layout:
 *   [1B version = 0x01]
 *   then, per present field: [1B tag][2B length BE][field bytes]
 * Unknown tags are skipped on decode (forward compatibility).
 *
 * The message ID is carried inside the encrypted payload so GCM
 * authentication binds the ciphertext to its owning row: a payload
 * transplanted onto another message fails decodeAndVerify even without
 * per-row AES-GCM associated data (SecureKeyStore binds a constant AAD).
 */

import { ByteUtils, ByteReader, ByteWriter } from '../common/ByteUtils';

/** Sensitive message fields stored inside the encrypted payload. */
export class StoredMessagePayload {
  messageID: string = '';
  sender: string = '';
  content: string = '';
  originalSender: string | null = null;
  recipientNickname: string | null = null;
  senderPeerId: string | null = null;
  mentions: string[] | null = null;
  channel: string | null = null;
  encryptedContent: Uint8Array | null = null;
  deliveryText: string | null = null;
  senderNostrPubkey: string | null = null;
  /** US10 media metadata (optional TLVs; defaults keep old rows valid). */
  messageTypeValue: number = 0;
  transferId: string = '';
  notEndToEndEncrypted: boolean = false;
}

export class ConversationPayloadCodec {
  private static readonly VERSION: number = 0x01;
  private static readonly MAX_FIELD_BYTES: number = 0xFFFF;

  private static readonly TAG_MESSAGE_ID: number = 0x01;
  private static readonly TAG_SENDER: number = 0x02;
  private static readonly TAG_CONTENT: number = 0x03;
  private static readonly TAG_ORIGINAL_SENDER: number = 0x04;
  private static readonly TAG_RECIPIENT_NICKNAME: number = 0x05;
  private static readonly TAG_SENDER_PEER_ID: number = 0x06;
  private static readonly TAG_MENTIONS: number = 0x07;
  private static readonly TAG_CHANNEL: number = 0x08;
  private static readonly TAG_ENCRYPTED_CONTENT: number = 0x09;
  private static readonly TAG_DELIVERY_TEXT: number = 0x0A;
  private static readonly TAG_SENDER_NOSTR_PUBKEY: number = 0x0B;
  private static readonly TAG_MESSAGE_TYPE: number = 0x0C;
  private static readonly TAG_TRANSFER_ID: number = 0x0D;
  private static readonly TAG_NOT_END_TO_END_ENCRYPTED: number = 0x0E;

  static encode(payload: StoredMessagePayload): Uint8Array {
    const writer: ByteWriter = new ByteWriter(256);
    writer.putByte(ConversationPayloadCodec.VERSION);
    ConversationPayloadCodec.putTlvString(writer,
      ConversationPayloadCodec.TAG_MESSAGE_ID, payload.messageID);
    ConversationPayloadCodec.putTlvString(writer,
      ConversationPayloadCodec.TAG_SENDER, payload.sender);
    ConversationPayloadCodec.putTlvString(writer,
      ConversationPayloadCodec.TAG_CONTENT, payload.content);
    if (payload.originalSender !== null) {
      ConversationPayloadCodec.putTlvString(writer,
        ConversationPayloadCodec.TAG_ORIGINAL_SENDER, payload.originalSender);
    }
    if (payload.recipientNickname !== null) {
      ConversationPayloadCodec.putTlvString(writer,
        ConversationPayloadCodec.TAG_RECIPIENT_NICKNAME, payload.recipientNickname);
    }
    if (payload.senderPeerId !== null) {
      ConversationPayloadCodec.putTlvString(writer,
        ConversationPayloadCodec.TAG_SENDER_PEER_ID, payload.senderPeerId);
    }
    if (payload.mentions !== null) {
      const body: ByteWriter = new ByteWriter(16);
      body.putU16BE(payload.mentions.length);
      for (let i = 0; i < payload.mentions.length; i++) {
        const mentionBytes: Uint8Array = ByteUtils.utf8Encode(payload.mentions[i]);
        if (mentionBytes.length > 0xFF) {
          throw new Error('Conversation payload mention is too large');
        }
        body.putByte(mentionBytes.length);
        body.putBytes(mentionBytes);
      }
      ConversationPayloadCodec.putTlvBytes(writer,
        ConversationPayloadCodec.TAG_MENTIONS, body.toUint8Array());
    }
    if (payload.channel !== null) {
      ConversationPayloadCodec.putTlvString(writer,
        ConversationPayloadCodec.TAG_CHANNEL, payload.channel);
    }
    if (payload.encryptedContent !== null) {
      ConversationPayloadCodec.putTlvBytes(writer,
        ConversationPayloadCodec.TAG_ENCRYPTED_CONTENT, payload.encryptedContent);
    }
    if (payload.deliveryText !== null) {
      ConversationPayloadCodec.putTlvString(writer,
        ConversationPayloadCodec.TAG_DELIVERY_TEXT, payload.deliveryText);
    }
    if (payload.senderNostrPubkey !== null) {
      ConversationPayloadCodec.putTlvString(writer,
        ConversationPayloadCodec.TAG_SENDER_NOSTR_PUBKEY, payload.senderNostrPubkey);
    }
    if (payload.messageTypeValue !== 0) {
      writer.putByte(ConversationPayloadCodec.TAG_MESSAGE_TYPE);
      writer.putU16BE(1);
      writer.putByte(payload.messageTypeValue & 0xFF);
    }
    if (payload.transferId !== '') {
      ConversationPayloadCodec.putTlvString(writer,
        ConversationPayloadCodec.TAG_TRANSFER_ID, payload.transferId);
    }
    if (payload.notEndToEndEncrypted) {
      writer.putByte(ConversationPayloadCodec.TAG_NOT_END_TO_END_ENCRYPTED);
      writer.putU16BE(1);
      writer.putByte(1);
    }
    return writer.toUint8Array();
  }

  /** Decode a payload record; throws on malformed or truncated input. */
  static decode(data: Uint8Array): StoredMessagePayload {
    if (data.length < 1) {
      throw new Error('Conversation payload is empty');
    }
    const reader: ByteReader = new ByteReader(data);
    const version: number = reader.getByte();
    if (version !== ConversationPayloadCodec.VERSION) {
      throw new Error('Unsupported conversation payload version');
    }
    const payload: StoredMessagePayload = new StoredMessagePayload();
    let sawMessageID: boolean = false;
    let sawSender: boolean = false;
    let sawContent: boolean = false;
    while (reader.hasRemaining()) {
      const tag: number = reader.getByte();
      const length: number = reader.getU16BE();
      const bytes: Uint8Array = reader.getBytes(length);
      if (tag === ConversationPayloadCodec.TAG_MESSAGE_ID) {
        payload.messageID = ByteUtils.utf8Decode(bytes);
        sawMessageID = true;
      } else if (tag === ConversationPayloadCodec.TAG_SENDER) {
        payload.sender = ByteUtils.utf8Decode(bytes);
        sawSender = true;
      } else if (tag === ConversationPayloadCodec.TAG_CONTENT) {
        payload.content = ByteUtils.utf8Decode(bytes);
        sawContent = true;
      } else if (tag === ConversationPayloadCodec.TAG_ORIGINAL_SENDER) {
        payload.originalSender = ByteUtils.utf8Decode(bytes);
      } else if (tag === ConversationPayloadCodec.TAG_RECIPIENT_NICKNAME) {
        payload.recipientNickname = ByteUtils.utf8Decode(bytes);
      } else if (tag === ConversationPayloadCodec.TAG_SENDER_PEER_ID) {
        payload.senderPeerId = ByteUtils.utf8Decode(bytes);
      } else if (tag === ConversationPayloadCodec.TAG_MENTIONS) {
        payload.mentions = ConversationPayloadCodec.decodeMentions(bytes);
      } else if (tag === ConversationPayloadCodec.TAG_CHANNEL) {
        payload.channel = ByteUtils.utf8Decode(bytes);
      } else if (tag === ConversationPayloadCodec.TAG_ENCRYPTED_CONTENT) {
        payload.encryptedContent = bytes;
      } else if (tag === ConversationPayloadCodec.TAG_DELIVERY_TEXT) {
        payload.deliveryText = ByteUtils.utf8Decode(bytes);
      } else if (tag === ConversationPayloadCodec.TAG_SENDER_NOSTR_PUBKEY) {
        payload.senderNostrPubkey = ByteUtils.utf8Decode(bytes);
      } else if (tag === ConversationPayloadCodec.TAG_MESSAGE_TYPE && length === 1) {
        payload.messageTypeValue = bytes[0] & 0xFF;
      } else if (tag === ConversationPayloadCodec.TAG_TRANSFER_ID) {
        payload.transferId = ByteUtils.utf8Decode(bytes);
      } else if (tag === ConversationPayloadCodec.TAG_NOT_END_TO_END_ENCRYPTED &&
        length === 1) {
        payload.notEndToEndEncrypted = (bytes[0] & 0xFF) !== 0;
      }
      // Unknown tags are skipped (already consumed above).
    }
    if (!sawMessageID || !sawSender || !sawContent) {
      throw new Error('Conversation payload is missing required fields');
    }
    return payload;
  }

  /**
   * Decode and check that the payload belongs to the given message ID -
   * the at-rest analog of the Android per-message AES-GCM associated data
   * ("message:$id"): a ciphertext copied between rows is rejected.
   */
  static decodeAndVerify(data: Uint8Array, expectedMessageID: string): StoredMessagePayload {
    const payload: StoredMessagePayload = ConversationPayloadCodec.decode(data);
    if (payload.messageID !== expectedMessageID) {
      throw new Error('Conversation payload does not match its message ID');
    }
    return payload;
  }

  private static decodeMentions(bytes: Uint8Array): string[] {
    const reader: ByteReader = new ByteReader(bytes);
    const count: number = reader.getU16BE();
    const mentions: string[] = [];
    for (let i = 0; i < count; i++) {
      const length: number = reader.getByte();
      mentions.push(ByteUtils.utf8Decode(reader.getBytes(length)));
    }
    return mentions;
  }

  private static putTlvString(writer: ByteWriter, tag: number, value: string): void {
    ConversationPayloadCodec.putTlvBytes(writer, tag, ByteUtils.utf8Encode(value));
  }

  private static putTlvBytes(writer: ByteWriter, tag: number, bytes: Uint8Array): void {
    if (bytes.length > ConversationPayloadCodec.MAX_FIELD_BYTES) {
      throw new Error('Conversation payload field is too large');
    }
    writer.putByte(tag);
    writer.putU16BE(bytes.length);
    writer.putBytes(bytes);
  }
}
