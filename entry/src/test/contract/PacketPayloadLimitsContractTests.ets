/**
 * Golden vectors for the per-type payload admission rules.
 * Port of bitchat-android PacketPayloadLimitsWireContractTest.kt.
 *
 * Every frame is literal wire bytes with a real raw-DEFLATE body (zlib level 9,
 * window bits -15, over an all-zero payload), decoded through the production
 * decompressor. Sender 1011121314151617, timestamp 0x0102030405060708, TTL 7,
 * flags IS_COMPRESSED, no padding.
 */
import { ByteUtils } from '../../main/ets/common/ByteUtils';
import { BitchatPacket, MessageType } from '../../main/ets/model/BitchatPacket';
import { BinaryProtocol } from '../../main/ets/service/protocol/BinaryProtocol';
import { ContractAssert } from './ContractAssert';

const ANNOUNCE_4096: string =
  '0101070102030405060708040016101112131415161710' +
    '00edc1010d000000c2a0f74f6d0f0714000000f06e';
const ANNOUNCE_4097: string =
  '0101070102030405060708040016101112131415161710' +
    '01edc1010d000000c2a0f74f6d0f0714000000706f';

// Header, sender, 4-byte original size, then the 143-byte deflate body.
const MESSAGE_131072: string =
  '020207010203040506070804000000931011121314151617' +
    '00020000' +
    'edc13101000000c2a0f54fed610da0' + limitsRepeat('00', 127) + '6e';
const MESSAGE_131073: string =
  '020207010203040506070804000000931011121314151617' +
    '00020001' +
    'edc13101000000c2a0f54fed630ca0' + limitsRepeat('00', 127) + '6e';
const FILE_TRANSFER_131073: string =
  '022207010203040506070804000000931011121314151617' +
    '00020001' +
    'edc13101000000c2a0f54fed630ca0' + limitsRepeat('00', 127) + '6e';

const FILE_TRANSFER_RATIO_2065: string =
  '022207010203040506070804000000061011121314151617' +
    '00000811' +
    '0300';

function limitsHex(value: string): Uint8Array {
  return ByteUtils.hexToBytes(value);
}

function limitsRepeat(value: string, count: number): string {
  let out: string = '';
  for (let i: number = 0; i < count; i++) {
    out += value;
  }
  return out;
}

function limitsZeroes(count: number): Uint8Array {
  return new Uint8Array(count);
}

export function runPacketPayloadLimitsContractTests(t: ContractAssert): void {
  // v1 announce inflating to exactly 4 KiB is accepted
  {
    const packet: BitchatPacket | null = BinaryProtocol.decode(limitsHex(ANNOUNCE_4096));
    t.isNotNull<BitchatPacket>(packet, 'v1 announce 4 KiB should be accepted');
    if (packet === null) {
      return;
    }
    t.equalNumber(MessageType.ANNOUNCE, packet.type, 'announce type byte');
    t.equalBytes(limitsZeroes(4096), packet.payload, 'announce 4 KiB payload is all zeroes');
  }

  // v1 announce inflating one byte past 4 KiB is rejected
  t.isNull<BitchatPacket>(BinaryProtocol.decode(limitsHex(ANNOUNCE_4097)),
    'v1 announce one byte past 4 KiB should be rejected');

  // v2 public message inflating to exactly 128 KiB is accepted
  {
    const packet: BitchatPacket | null = BinaryProtocol.decode(limitsHex(MESSAGE_131072));
    t.isNotNull<BitchatPacket>(packet, 'v2 public message 128 KiB should be accepted');
    if (packet === null) {
      return;
    }
    t.equalNumber(MessageType.MESSAGE, packet.type, 'message type byte');
    t.equalBytes(limitsZeroes(131072), packet.payload, 'message 128 KiB payload is all zeroes');
  }

  // v2 public message inflating one byte past 128 KiB is rejected
  t.isNull<BitchatPacket>(BinaryProtocol.decode(limitsHex(MESSAGE_131073)),
    'v2 public message one byte past 128 KiB should be rejected');

  // file transfer keeps the framed-file ceiling for the same body
  {
    const packet: BitchatPacket | null = BinaryProtocol.decode(limitsHex(FILE_TRANSFER_131073));
    t.isNotNull<BitchatPacket>(packet, 'file transfer 131073 bytes should be accepted');
    if (packet === null) {
      return;
    }
    t.equalNumber(MessageType.FILE_TRANSFER, packet.type, 'file transfer type byte');
    t.equalBytes(limitsZeroes(131073), packet.payload, 'file transfer 131073-byte payload is all zeroes');
  }

  // declaration beyond 1032 to 1 is rejected before inflating
  t.isNull<BitchatPacket>(BinaryProtocol.decode(limitsHex(FILE_TRANSFER_RATIO_2065)),
    'declaration beyond 1032 to 1 should be rejected before inflating');
}
