/**
 * Bech32 padding golden tests. Port of bitchat-android Bech32PaddingTest.kt.
 */
import { Bech32, Bech32Result } from '../../main/ets/service/nostr/Bech32';
import { ContractAssert } from './ContractAssert';

function bech32Repeat(value: string, count: number): string {
  let out: string = '';
  for (let i: number = 0; i < count; i++) {
    out += value;
  }
  return out;
}

export function runBech32ContractTests(t: ContractAssert): void {
  // a literal canonical npub decodes to its key
  {
    const npub: string = 'npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqzqujme';
    const decoded: Bech32Result = Bech32.decode(npub);
    t.equalString('npub', decoded.hrp, 'npub hrp');
    t.equalBytes(new Uint8Array(32), decoded.data, 'npub key is 32 zero bytes');
    t.equalString(npub, Bech32.encode('npub', decoded.data), 'npub re-encodes canonically');
  }

  // valid checksum does not permit nonzero discarded padding
  t.throws((): void => {
    Bech32.decode('npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqplkg8xt');
  }, 'nonzero discarded padding should be rejected');

  // a whole extra padding symbol cannot alias an empty payload
  t.throws((): void => {
    Bech32.decode('test1q6j8x73');
  }, 'whole extra padding symbol should be rejected');

  // empty and oversized human readable prefixes are rejected
  t.throws((): void => {
    Bech32.decode('10a06t8');
  }, 'empty hrp should be rejected');
  t.throws((): void => {
    Bech32.decode(bech32Repeat('x', 84) + '1e5y3yu');
  }, '84-char hrp should be rejected');
  t.throws((): void => {
    Bech32.encode('', new Uint8Array(0));
  }, 'encoding an empty hrp should be rejected');
  t.throws((): void => {
    Bech32.encode(bech32Repeat('x', 84), new Uint8Array(0));
  }, 'encoding an 84-char hrp should be rejected');

  // all byte lengths preserve their canonical padding
  for (let length: number = 0; length <= 64; length++) {
    const bytes: Uint8Array = new Uint8Array(length);
    for (let i: number = 0; i < length; i++) {
      bytes[i] = (i * 37) & 0xFF;
    }
    const decoded: Bech32Result = Bech32.decode(Bech32.encode('test', bytes));
    t.equalBytes(bytes, decoded.data, 'length ' + length + ' preserves its canonical padding');
  }
}
