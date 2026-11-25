/**
 * Port of the payload half of bitchat-android
 * ConversationRepositoryTest.kt / ConversationDatabaseTest.kt (US4):
 * the sensitive message fields that ride inside the AES-GCM
 * payload_ciphertext column must survive a codec roundtrip losslessly,
 * distinguish null from empty, reject tampering, and skip unknown
 * forward-compatibility tags.
 *
 * The HarmonyOS codec replaces Android's JSON document with a binary TLV
 * record (strict-ArkTS JSON.parse normalization hazard; the payload is
 * local-only at-rest ciphertext sealed by SecureKeyStore), so these tests
 * pin the record format: version byte, tag-order determinism,
 * required-field enforcement, and the message-ID binding that stands in
 * for Android's per-message GCM associated data ("message:$id") - a
 * ciphertext transplanted onto another row must fail decodeAndVerify.
 */
import { ContractAssert } from './ContractAssert';
import { ByteWriter } from '../../main/ets/common/ByteUtils';
import {
  ConversationPayloadCodec,
  StoredMessagePayload
} from '../../main/ets/data/ConversationPayloadCodec';

function fullPayload(): StoredMessagePayload {
  const payload: StoredMessagePayload = new StoredMessagePayload();
  payload.messageID = 'msg-1234';
  payload.sender = 'alice ✓ 送信者';
  payload.content = 'hello world — 你好 𝄞';
  payload.originalSender = 'bob-relay';
  payload.recipientNickname = 'alice';
  payload.senderPeerId = 'aaaabbbbccccdddd';
  payload.mentions = ['@alice', '@bob', '@carol'];
  payload.channel = 'general';
  payload.encryptedContent =
    new Uint8Array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]);
  payload.deliveryText = 'delivered to alice';
  payload.senderNostrPubkey = 'npub1qqr0y2u3v4w5x6y7z8';
  return payload;
}

/** Local helpers so negative tests stay independent of encode(). */
class ConversationPayloadCodecTestHelper {
  static payloadOf(messageID: string, sender: string, content: string): StoredMessagePayload {
    const payload: StoredMessagePayload = new StoredMessagePayload();
    payload.messageID = messageID;
    payload.sender = sender;
    payload.content = content;
    return payload;
  }

  static ascii(value: string): Uint8Array {
    const out: Uint8Array = new Uint8Array(value.length);
    for (let i: number = 0; i < value.length; i++) {
      out[i] = value.charCodeAt(i) & 0xFF;
    }
    return out;
  }

  /** Hand-built record with only the required fields, no dependence on encode(). */
  static requiredOnlyRecord(messageID: string, sender: string, content: string): Uint8Array {
    const writer: ByteWriter = new ByteWriter(64);
    writer.putByte(0x01);
    writer.putByte(0x01);
    writer.putU16BE(messageID.length);
    writer.putBytes(ConversationPayloadCodecTestHelper.ascii(messageID));
    writer.putByte(0x02);
    writer.putU16BE(sender.length);
    writer.putBytes(ConversationPayloadCodecTestHelper.ascii(sender));
    writer.putByte(0x03);
    writer.putU16BE(content.length);
    writer.putBytes(ConversationPayloadCodecTestHelper.ascii(content));
    return writer.toUint8Array();
  }
}

function assertPayloadEquals(t: ContractAssert, expected: StoredMessagePayload,
  actual: StoredMessagePayload): void {
  t.equalString(expected.messageID, actual.messageID, 'messageID roundtrips');
  t.equalString(expected.sender, actual.sender, 'sender roundtrips');
  t.equalString(expected.content, actual.content, 'content roundtrips');
  t.equalString(expected.originalSender ?? '<null>', actual.originalSender ?? '<null>',
    'originalSender roundtrips');
  t.equalString(expected.recipientNickname ?? '<null>', actual.recipientNickname ?? '<null>',
    'recipientNickname roundtrips');
  t.equalString(expected.senderPeerId ?? '<null>', actual.senderPeerId ?? '<null>',
    'senderPeerId roundtrips');
  t.equalString(expected.channel ?? '<null>', actual.channel ?? '<null>',
    'channel roundtrips');
  t.equalString(expected.deliveryText ?? '<null>', actual.deliveryText ?? '<null>',
    'deliveryText roundtrips');
  t.equalString(expected.senderNostrPubkey ?? '<null>',
    actual.senderNostrPubkey ?? '<null>', 'senderNostrPubkey roundtrips');
  t.equalNumber(expected.mentions === null ? -1 : expected.mentions.length,
    actual.mentions === null ? -1 : actual.mentions.length, 'mentions cardinality matches');
  if (expected.mentions !== null && actual.mentions !== null) {
    for (let i: number = 0; i < expected.mentions.length; i++) {
      t.equalString(expected.mentions[i], actual.mentions[i], 'mention ' + i + ' roundtrips');
    }
  }
  const expectedCipher: Uint8Array | null = expected.encryptedContent;
  const actualCipher: Uint8Array | null = actual.encryptedContent;
  t.equalNumber(expectedCipher === null ? -1 : expectedCipher.length,
    actualCipher === null ? -1 : actualCipher.length, 'encryptedContent cardinality matches');
  if (expectedCipher !== null && actualCipher !== null) {
    t.equalBytes(expectedCipher, actualCipher, 'encryptedContent roundtrips');
  }
}

export function runConversationPayloadCodecContractTests(t: ContractAssert): void {
  // A fully populated payload roundtrips losslessly (unicode, mentions, bytes).
  {
    const payload: StoredMessagePayload = fullPayload();
    const decoded: StoredMessagePayload =
      ConversationPayloadCodec.decode(ConversationPayloadCodec.encode(payload));
    assertPayloadEquals(t, payload, decoded);
  }

  // Encoding is deterministic (stable tag order) for the same input.
  {
    const payload: StoredMessagePayload = fullPayload();
    t.equalBytes(ConversationPayloadCodec.encode(payload),
      ConversationPayloadCodec.encode(payload), 'encoding is deterministic');
  }

  // Null and empty-string optionals are distinguished.
  {
    const withNull: StoredMessagePayload =
      ConversationPayloadCodecTestHelper.payloadOf('msg-n', 'sender', 'content');
    const decodedNull: StoredMessagePayload =
      ConversationPayloadCodec.decode(ConversationPayloadCodec.encode(withNull));
    t.isNull(decodedNull.originalSender, 'absent optional decodes as null');
    t.isNull(decodedNull.mentions, 'absent mentions decode as null');
    t.isNull(decodedNull.encryptedContent, 'absent encryptedContent decodes as null');

    const withEmpty: StoredMessagePayload =
      ConversationPayloadCodecTestHelper.payloadOf('msg-e', 'sender', 'content');
    withEmpty.originalSender = '';
    withEmpty.recipientNickname = '';
    withEmpty.senderPeerId = '';
    withEmpty.channel = '';
    withEmpty.deliveryText = '';
    withEmpty.senderNostrPubkey = '';
    const decodedEmpty: StoredMessagePayload =
      ConversationPayloadCodec.decode(ConversationPayloadCodec.encode(withEmpty));
    t.equalString('', decodedEmpty.originalSender ?? '<null>',
      'empty originalSender does not collapse to null');
    t.equalString('', decodedEmpty.recipientNickname ?? '<null>',
      'empty nickname does not collapse to null');
    t.equalString('', decodedEmpty.senderPeerId ?? '<null>',
      'empty peer id does not collapse to null');
    t.equalString('', decodedEmpty.channel ?? '<null>',
      'empty channel does not collapse to null');
    t.equalString('', decodedEmpty.deliveryText ?? '<null>',
      'empty delivery text does not collapse to null');
    t.equalString('', decodedEmpty.senderNostrPubkey ?? '<null>',
      'empty pubkey does not collapse to null');
  }

  // An empty mentions list stays an empty list, distinct from null.
  {
    const payload: StoredMessagePayload =
      ConversationPayloadCodecTestHelper.payloadOf('msg-m', 'sender', 'content');
    payload.mentions = [];
    const decoded: StoredMessagePayload =
      ConversationPayloadCodec.decode(ConversationPayloadCodec.encode(payload));
    t.isNotNull(decoded.mentions, 'empty mentions decode as a list');
    if (decoded.mentions !== null) {
      t.equalNumber(0, decoded.mentions.length, 'empty mentions list stays empty');
    }
  }

  // A required-only record decodes with all optionals null.
  {
    const decoded: StoredMessagePayload = ConversationPayloadCodec.decode(
      ConversationPayloadCodecTestHelper.requiredOnlyRecord('msg-r', 'alice', 'hi'));
    t.equalString('msg-r', decoded.messageID, 'required-only messageID decodes');
    t.equalString('alice', decoded.sender, 'required-only sender decodes');
    t.equalString('hi', decoded.content, 'required-only content decodes');
    t.isNull(decoded.channel, 'required-only channel is null');
  }

  // decodeAndVerify accepts the matching message ID and rejects a transplant.
  {
    const payload: StoredMessagePayload = fullPayload();
    const encoded: Uint8Array = ConversationPayloadCodec.encode(payload);
    const verified: StoredMessagePayload =
      ConversationPayloadCodec.decodeAndVerify(encoded, 'msg-1234');
    t.equalString('msg-1234', verified.messageID, 'matching ID verifies');
    t.throws((): void => {
      ConversationPayloadCodec.decodeAndVerify(encoded, 'msg-other');
    }, 'a payload transplanted onto another message ID is rejected');
  }

  // Unknown tags are skipped (forward compatibility).
  {
    const payload: StoredMessagePayload = fullPayload();
    const encoded: Uint8Array = ConversationPayloadCodec.encode(payload);
    const writer: ByteWriter = new ByteWriter(encoded.length + 8);
    writer.putByte(encoded[0]);
    writer.putByte(0x7F);
    writer.putU16BE(2);
    writer.putBytes(ConversationPayloadCodecTestHelper.ascii('zz'));
    writer.putBytes(encoded.subarray(1));
    const decoded: StoredMessagePayload =
      ConversationPayloadCodec.decode(writer.toUint8Array());
    assertPayloadEquals(t, payload, decoded);
  }

  // Truncated and empty records are rejected.
  {
    const encoded: Uint8Array = ConversationPayloadCodec.encode(fullPayload());
    t.throws((): void => {
      ConversationPayloadCodec.decode(encoded.subarray(0, encoded.length - 1));
    }, 'a record truncated by one byte is rejected');
    t.throws((): void => {
      ConversationPayloadCodec.decode(encoded.subarray(0, 3));
    }, 'a record truncated mid-header is rejected');
    t.throws((): void => {
      ConversationPayloadCodec.decode(new Uint8Array(0));
    }, 'an empty record is rejected');
  }

  // Unsupported versions and missing required fields are rejected.
  {
    const encoded: Uint8Array = ConversationPayloadCodec.encode(fullPayload());
    const badVersion: Uint8Array = encoded.slice(0);
    badVersion[0] = 0x02;
    t.throws((): void => {
      ConversationPayloadCodec.decode(badVersion);
    }, 'an unsupported version byte is rejected');

    const writer: ByteWriter = new ByteWriter(16);
    writer.putByte(0x01);
    writer.putByte(0x01);
    writer.putU16BE(4);
    writer.putBytes(ConversationPayloadCodecTestHelper.ascii('msg1'));
    t.throws((): void => {
      ConversationPayloadCodec.decode(writer.toUint8Array());
    }, 'a record missing sender and content is rejected');
  }

  // Mentions containing empty strings roundtrip.
  {
    const payload: StoredMessagePayload =
      ConversationPayloadCodecTestHelper.payloadOf('msg-x', 'sender', 'content');
    payload.mentions = ['', '@b'];
    const decoded: StoredMessagePayload =
      ConversationPayloadCodec.decode(ConversationPayloadCodec.encode(payload));
    t.isNotNull(decoded.mentions, 'mentions decode');
    if (decoded.mentions !== null) {
      t.equalNumber(2, decoded.mentions.length, 'mention count roundtrips');
      t.equalString('', decoded.mentions[0], 'empty mention stays empty');
      t.equalString('@b', decoded.mentions[1], 'second mention roundtrips');
    }
  }
}
