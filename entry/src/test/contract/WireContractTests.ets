/**
 * Golden wire vectors for formats that a from-scratch client must reproduce.
 * Port of bitchat-android ClientRewriteWireContractTest.kt.
 *
 * These assertions deliberately compare literal bytes rather than relying only
 * on encode/decode round trips, which can hide matching bugs in both methods.
 */
import { ByteUtils } from '../../main/ets/common/ByteUtils';
import { BitchatPacket, MessageType } from '../../main/ets/model/BitchatPacket';
import { BitchatMessage } from '../../main/ets/model/BitchatMessage';
import {
  NoisePayload,
  NoisePayloadType,
  PrivateMessagePacket,
  IdentityAnnouncement,
  PeerCapabilities,
  UnknownAnnouncementTLV
} from '../../main/ets/model/IdentityModels';
import { FragmentPayload, RequestSyncPacket, BitchatFilePacket } from '../../main/ets/model/FragmentModels';
import { BinaryProtocol } from '../../main/ets/service/protocol/BinaryProtocol';
import { ContractAssert } from './ContractAssert';

function wireHex(value: string): Uint8Array {
  return ByteUtils.hexToBytes(value);
}

function wireBytesOf(value: number, count: number): Uint8Array {
  const out: Uint8Array = new Uint8Array(count);
  for (let i: number = 0; i < count; i++) {
    out[i] = value & 0xFF;
  }
  return out;
}

function wireContainsBytes(haystack: Uint8Array, needle: Uint8Array): boolean {
  if (needle.length === 0) {
    return true;
  }
  for (let i: number = 0; i + needle.length <= haystack.length; i++) {
    let match: boolean = true;
    for (let j: number = 0; j < needle.length; j++) {
      if (haystack[i + j] !== needle[j]) {
        match = false;
        break;
      }
    }
    if (match) {
      return true;
    }
  }
  return false;
}

export function runWireContractTests(t: ContractAssert): void {
  // v1 packet matches canonical unpadded bytes
  {
    const tsRaw: Uint8Array = wireHex('0102030405060708');
    const packet: BitchatPacket = new BitchatPacket(1, MessageType.MESSAGE,
      wireHex('1011121314151617'), null, ByteUtils.u64BytesToNumber(tsRaw),
      wireHex('aabbcc'), null, 7, null);
    packet.timestampRaw = tsRaw;

    const encoded: Uint8Array | null = BinaryProtocol.encode(packet, false);
    t.isNotNull<Uint8Array>(encoded, 'v1 encode should succeed');
    if (encoded === null) {
      return;
    }
    t.equalBytes(wireHex('01020701020304050607080000031011121314151617aabbcc'),
      encoded, 'v1 canonical unpadded bytes');
    const decoded: BitchatPacket | null = BinaryProtocol.decode(encoded);
    t.isNotNull<BitchatPacket>(decoded, 'v1 decode should succeed');
    if (decoded === null) {
      return;
    }
    t.isTrue(BitchatPacket.equals(packet, decoded), 'v1 round trip equals');
  }

  // v2 routed signed packet matches canonical section order
  {
    const signature: Uint8Array = wireBytesOf(0x5a, 64);
    const route: Uint8Array[] = [wireHex('2122232425262728'), wireHex('3132333435363738')];
    const packet: BitchatPacket = new BitchatPacket(2, MessageType.NOISE_ENCRYPTED,
      wireHex('0102030405060708'), wireHex('1112131415161718'), 42, wireHex('dead'),
      signature, 5, route);

    const encoded: Uint8Array | null = BinaryProtocol.encode(packet, false);
    t.isNotNull<Uint8Array>(encoded, 'v2 encode should succeed');
    if (encoded === null) {
      return;
    }
    const expected: Uint8Array = ByteUtils.concat(
      wireHex('021105000000000000002a0b00000002' +
        '0102030405060708' +
        '1112131415161718' +
        '02' +
        '2122232425262728' +
        '3132333435363738' +
        'dead'),
      signature);
    t.equalBytes(expected, encoded, 'v2 canonical section order');
    const decoded: BitchatPacket | null = BinaryProtocol.decode(encoded);
    t.isNotNull<BitchatPacket>(decoded, 'v2 decode should succeed');
    if (decoded === null) {
      return;
    }
    t.isTrue(BitchatPacket.equals(packet, decoded), 'v2 round trip equals');
  }

  // minimal chat message matches canonical binary payload
  {
    const tsRaw: Uint8Array = wireHex('0102030405060708');
    const message: BitchatMessage = new BitchatMessage('bob', 'hi', ByteUtils.u64BytesToNumber(tsRaw));
    message.id = 'id';
    message.timestampRaw = tsRaw;

    const encoded: Uint8Array | null = message.toBinaryPayload();
    t.isNotNull<Uint8Array>(encoded, 'minimal message encode should succeed');
    if (encoded === null) {
      return;
    }
    t.equalBytes(wireHex('00010203040506070802696403626f6200026869'),
      encoded, 'minimal chat message canonical bytes');
    const decoded: BitchatMessage | null = BitchatMessage.fromBinaryPayload(encoded);
    t.isNotNull<BitchatMessage>(decoded, 'minimal message decode should succeed');
    if (decoded === null) {
      return;
    }
    t.isTrue(BitchatMessage.equals(message, decoded), 'minimal message round trip equals');
  }

  // chat message optional fields use flags and UTF-8 byte lengths
  {
    const message: BitchatMessage = new BitchatMessage('é', 'hello', 42);
    message.id = 'm';
    message.isRelay = true;
    message.originalSender = 'o';
    message.isPrivate = true;
    message.recipientNickname = 'r';
    message.senderPeerId = 'p';
    message.mentions = ['a', 'β'];
    message.channel = 'c';

    const encoded: Uint8Array | null = message.toBinaryPayload();
    t.isNotNull<Uint8Array>(encoded, 'optional fields encode should succeed');
    if (encoded === null) {
      return;
    }
    t.equalBytes(wireHex('7f000000000000002a' +
      '016d' +
      '02c3a9' +
      '000568656c6c6f' +
      '016f' +
      '0172' +
      '0170' +
      '02' +
      '0161' +
      '02ceb2' +
      '0163'),
      encoded, 'optional fields canonical bytes');
    const decoded: BitchatMessage | null = BitchatMessage.fromBinaryPayload(encoded);
    t.isNotNull<BitchatMessage>(decoded, 'optional fields decode should succeed');
    if (decoded === null) {
      return;
    }
    t.isTrue(BitchatMessage.equals(message, decoded), 'optional fields round trip equals');
  }

  // encrypted chat payload carries ciphertext instead of placeholder content
  {
    const message: BitchatMessage = new BitchatMessage('alice', 'must-not-be-on-wire', 1);
    message.id = 'e';
    message.encryptedContent = wireHex('000102ff');
    message.isEncrypted = true;
    message.isPrivate = true;

    const encoded: Uint8Array | null = message.toBinaryPayload();
    t.isNotNull<Uint8Array>(encoded, 'encrypted message encode should succeed');
    if (encoded === null) {
      return;
    }
    const decoded: BitchatMessage | null = BitchatMessage.fromBinaryPayload(encoded);
    t.isNotNull<BitchatMessage>(decoded, 'encrypted message decode should succeed');
    if (decoded === null) {
      return;
    }
    t.equalString('', decoded.content, 'encrypted decoded content is empty');
    t.equalBytes(wireHex('000102ff'),
      decoded.encryptedContent === null ? new Uint8Array(0) : decoded.encryptedContent,
      'ciphertext preserved');
    t.isTrue(decoded.isEncrypted, 'decoded is encrypted');
    t.isTrue(decoded.isPrivate, 'decoded is private');
    t.isFalse(wireContainsBytes(encoded, ByteUtils.utf8Encode('must-not-be-on-wire')),
      'plaintext never appears on the wire');
  }

  // private message and Noise envelopes match deployed type bytes
  {
    const privateMessage: PrivateMessagePacket = new PrivateMessagePacket('m1', 'hi');
    const pmBytes: Uint8Array | null = privateMessage.encode();
    t.isNotNull<Uint8Array>(pmBytes, 'private message encode should succeed');
    if (pmBytes === null) {
      return;
    }
    t.equalBytes(wireHex('00026d3101026869'), pmBytes, 'private message canonical bytes');
    const pmDecoded: PrivateMessagePacket | null = PrivateMessagePacket.decode(pmBytes);
    t.isNotNull<PrivateMessagePacket>(pmDecoded, 'private message decode should succeed');
    if (pmDecoded === null) {
      return;
    }
    t.isTrue(PrivateMessagePacket.equals(privateMessage, pmDecoded), 'private message round trip equals');

    const noise: NoisePayload = new NoisePayload(NoisePayloadType.PRIVATE_MESSAGE, pmBytes);
    t.equalBytes(wireHex('0100026d3101026869'), noise.encode(), 'noise envelope canonical bytes');
    const aliased: NoisePayload | null = NoisePayload.decode(wireHex('09cafe'));
    t.isNotNull<NoisePayload>(aliased, 'noise 0x09 alias should decode');
    if (aliased === null) {
      return;
    }
    t.equalNumber(NoisePayloadType.FILE_TRANSFER, aliased.type, '0x09 aliases FILE_TRANSFER');
    t.equalBytes(wireHex('20cafe'), aliased.encode(), 'alias re-encodes to canonical 0x20');
  }

  // fragment payload matches the thirteen byte iOS header
  {
    const fragment: FragmentPayload = new FragmentPayload(wireHex('0001020304050607'),
      1, 3, MessageType.MESSAGE, wireHex('aabb'));
    const wire: Uint8Array = fragment.encode();
    t.equalBytes(wireHex('00010203040506070001000302aabb'), wire, 'fragment 13-byte iOS header');
    const decoded: FragmentPayload | null = FragmentPayload.decode(wire);
    t.isNotNull<FragmentPayload>(decoded, 'fragment decode should succeed');
    if (decoded === null) {
      return;
    }
    t.isTrue(FragmentPayload.equals(fragment, decoded), 'fragment round trip equals');
    t.isTrue(fragment.isValid(), 'fragment is valid');
  }

  // sync request matches canonical TLV bytes and skips extensions
  {
    const request: RequestSyncPacket = new RequestSyncPacket(19, 0x01020304, wireHex('aabb'));
    const wire: Uint8Array = request.encode();
    t.equalBytes(wireHex('0100011302000401020304030002aabb'), wire, 'sync request canonical TLV bytes');

    const decoded: RequestSyncPacket | null = RequestSyncPacket.decode(wire);
    t.isNotNull<RequestSyncPacket>(decoded, 'sync request decode should succeed');
    if (decoded === null) {
      return;
    }
    t.equalNumber(request.p, decoded.p, 'sync request p');
    t.equalNumber(request.m, decoded.m, 'sync request m');
    t.equalBytes(request.data, decoded.data, 'sync request data');

    const withExtension: Uint8Array = ByteUtils.concat(wireHex('7f0002cafe'), wire);
    const decodedExt: RequestSyncPacket | null = RequestSyncPacket.decode(withExtension);
    t.isNotNull<RequestSyncPacket>(decodedExt, 'sync request decode with extension should succeed');
    if (decodedExt === null) {
      return;
    }
    t.equalNumber(request.p, decodedExt.p, 'sync request p (with extension)');
    t.equalNumber(request.m, decodedExt.m, 'sync request m (with extension)');
    t.equalBytes(request.data, decodedExt.data, 'sync request data (with extension)');
  }

  // identity announcement matches canonical TLV order and preserves extensions
  {
    const announcement: IdentityAnnouncement = new IdentityAnnouncement('bob',
      wireBytesOf(0x11, 32), wireBytesOf(0x22, 32), PeerCapabilities.PRIVATE_MEDIA,
      [new UnknownAnnouncementTLV(0x7f, wireHex('cafe'))]);

    const encoded: Uint8Array | null = announcement.encode();
    t.isNotNull<Uint8Array>(encoded, 'announcement encode should succeed');
    if (encoded === null) {
      return;
    }
    const expected: Uint8Array = ByteUtils.concat(
      wireHex('0103626f620220'), wireBytesOf(0x11, 32),
      wireHex('0320'), wireBytesOf(0x22, 32),
      wireHex('050200017f02cafe'));
    t.equalBytes(expected, encoded, 'announcement canonical TLV order');
    const decoded: IdentityAnnouncement | null = IdentityAnnouncement.decode(encoded);
    t.isNotNull<IdentityAnnouncement>(decoded, 'announcement decode should succeed');
    if (decoded === null) {
      return;
    }
    t.isTrue(IdentityAnnouncement.equals(announcement, decoded), 'announcement round trip equals');
  }

  // file transfer matches deployed mixed-width TLV vector
  {
    const packet: BitchatFilePacket = new BitchatFilePacket('a', 2, 'm', wireHex('dead'));
    const encoded: Uint8Array | null = packet.encode();
    t.isNotNull<Uint8Array>(encoded, 'file packet encode should succeed');
    if (encoded === null) {
      return;
    }
    t.equalBytes(wireHex('01000161020004000000020300016d0400000002dead'),
      encoded, 'file transfer mixed-width TLV vector');

    const decoded: BitchatFilePacket | null = BitchatFilePacket.decode(encoded);
    t.isNotNull<BitchatFilePacket>(decoded, 'file packet decode should succeed');
    if (decoded === null) {
      return;
    }
    t.equalString(packet.fileName, decoded.fileName, 'file name');
    t.equalNumber(packet.fileSize, decoded.fileSize, 'file size');
    t.equalString(packet.mimeType, decoded.mimeType, 'mime type');
    t.equalBytes(packet.content, decoded.content, 'file content');
  }

  // required message prefixes reject every truncation
  {
    const message: BitchatMessage = new BitchatMessage('bob', 'hello', 1);
    message.id = 'id';
    const wire: Uint8Array | null = message.toBinaryPayload();
    t.isNotNull<Uint8Array>(wire, 'prefix source encode should succeed');
    if (wire === null) {
      return;
    }
    for (let length: number = 0; length < wire.length; length++) {
      const prefix: Uint8Array = wire.slice(0, length);
      t.isNull<BitchatMessage>(BitchatMessage.fromBinaryPayload(prefix),
        'accepted required message prefix of ' + length + '/' + wire.length + ' bytes');
    }
    t.isNotNull<BitchatMessage>(BitchatMessage.fromBinaryPayload(wire),
      'full required message should decode');
  }

  // TLV decoders reject missing required fields and truncated values
  {
    t.isNull<PrivateMessagePacket>(PrivateMessagePacket.decode(wireHex('00026d31')),
      'private message missing content rejected');
    t.isNull<PrivateMessagePacket>(PrivateMessagePacket.decode(wireHex('00026d3101036869')),
      'private message truncated value rejected');
    t.isNull<RequestSyncPacket>(RequestSyncPacket.decode(wireHex('0100011302000401020304')),
      'sync request missing data rejected');
    t.isNull<IdentityAnnouncement>(IdentityAnnouncement.decode(wireHex('0103626f62022011')),
      'announcement truncated value rejected');
    t.isNull<BitchatFilePacket>(BitchatFilePacket.decode(wireHex('010001610400000002de')),
      'file packet truncated value rejected');
    t.isNull<FragmentPayload>(FragmentPayload.decode(new Uint8Array(FragmentPayload.HEADER_SIZE - 1)),
      'fragment header truncated rejected');
  }
}
