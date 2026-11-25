/**
 * GCS filter golden tests. Port of bitchat-android GCSFilterTest.kt and
 * GCSFilterParameterTest.kt, including a java.util.Random (48-bit LCG) port so
 * the Random(42).nextBytes ID sequences reproduce bit-for-bit.
 */
import { GCSFilter, GcsFilterParams } from '../../main/ets/service/sync/GCSFilter';
import { ContractAssert } from './ContractAssert';

/**
 * java.util.Random: 48-bit LCG with multiplier 0x5DEECE66D and increment 0xB.
 * The 48-bit state is held as two 24-bit limbs so every intermediate product
 * stays inside the double-precision exact-integer range.
 */
class JavaRandom {
  private static readonly MULT_HI: number = 0x5DE; // 0x5DEECE66D >> 24
  private static readonly MULT_LO: number = 0xECE66D; // 0x5DEECE66D & 0xFFFFFF
  private static readonly TWO24: number = 0x1000000;

  private hi: number; // high 24 bits of the 48-bit seed
  private lo: number; // low 24 bits

  constructor(seed: number) {
    const scrambled: number = seed ^ 0x5DEECE66D;
    this.lo = scrambled % JavaRandom.TWO24;
    this.hi = Math.floor(scrambled / JavaRandom.TWO24) % JavaRandom.TWO24;
  }

  /** seed = (seed * 0x5DEECE66D + 0xB) mod 2^48. */
  private step(): void {
    const a: number = this.hi * JavaRandom.MULT_LO + this.lo * JavaRandom.MULT_HI;
    const low: number = this.lo * JavaRandom.MULT_LO + 0xB;
    const newLo: number = low % JavaRandom.TWO24;
    const newHi: number = (a + Math.floor(low / JavaRandom.TWO24)) % JavaRandom.TWO24;
    this.lo = newLo;
    this.hi = newHi;
  }

  /** Java nextBytes: 4 bytes per nextInt(), low byte first. */
  nextBytes(bytes: Uint8Array): void {
    let i: number = 0;
    while (i < bytes.length) {
      this.step();
      // nextInt() = the top 32 bits of the 48-bit seed.
      const v: number = this.hi * 256 + Math.floor(this.lo / 65536);
      const n: number = Math.min(bytes.length - i, 4);
      for (let k: number = 0; k < n; k++) {
        bytes[i] = (v >>> (8 * k)) & 0xFF;
        i += 1;
      }
    }
  }
}

function gcsRandomIds(count: number): Uint8Array[] {
  const random: JavaRandom = new JavaRandom(42);
  const ids: Uint8Array[] = [];
  for (let i: number = 0; i < count; i++) {
    const bytes: Uint8Array = new Uint8Array(16);
    random.nextBytes(bytes);
    ids.push(bytes);
  }
  return ids;
}

export function runGcsFilterContractTests(t: ContractAssert): void {
  // testGCSFilterBasic
  {
    const ids: Uint8Array[] = gcsRandomIds(20);
    const params: GcsFilterParams = GCSFilter.buildFilter(ids, 400, 0.01);
    const sorted: number[] = GCSFilter.decodeToSortedSet(params.p, params.m, params.data);
    for (let i: number = 0; i < ids.length; i++) {
      const v: number = GCSFilter.h64modM(ids[i], params.m);
      const nonZeroV: number = v === 0 ? 1 : v;
      t.isTrue(GCSFilter.contains(sorted, nonZeroV), 'filter should contain all encoded IDs');
    }
  }

  // testGCSFilterWithTrimming
  {
    const ids: Uint8Array[] = gcsRandomIds(50);
    const maxBytes: number = 20;
    const params: GcsFilterParams = GCSFilter.buildFilter(ids, maxBytes, 0.01);
    t.isTrue(params.data.length <= maxBytes, 'params data size should be <= maxBytes');

    const sorted: number[] = GCSFilter.decodeToSortedSet(params.p, params.m, params.data);
    const trimmedN: number = Math.floor(params.m / Math.pow(2, params.p));
    t.isTrue(trimmedN > 0, 'at least some elements should have been encoded');

    for (let i: number = 0; i < trimmedN && i < ids.length; i++) {
      const v: number = GCSFilter.h64modM(ids[i], params.m);
      const nonZeroV: number = v === 0 ? 1 : v;
      t.isTrue(GCSFilter.contains(sorted, nonZeroV), 'retained ID should be found in filter');
    }
  }

  // testGCSFilterHandlesCollisionsAndZeroBucket
  {
    const ids: Uint8Array[] = gcsRandomIds(200);
    const params: GcsFilterParams = GCSFilter.buildFilter(ids, 100, 0.05);
    const sorted: number[] = GCSFilter.decodeToSortedSet(params.p, params.m, params.data);

    let foundCount: number = 0;
    for (let i: number = 0; i < ids.length; i++) {
      const v: number = GCSFilter.h64modM(ids[i], params.m);
      const nonZeroV: number = v === 0 ? 1 : v;
      if (GCSFilter.contains(sorted, nonZeroV)) {
        foundCount += 1;
      }
    }
    t.isTrue(foundCount > 0, 'should decode and find elements after deduplication');
  }
}

export function runGcsFilterParameterContractTests(t: ContractAssert): void {
  const ids: Uint8Array[] = gcsRandomIds(20);

  // a filter round-trips with the parameters it was built with
  {
    const params: GcsFilterParams = GCSFilter.buildFilter(ids, 400, 0.01);
    const decoded: number[] = GCSFilter.decodeToSortedSet(params.p, params.m, params.data);

    t.isTrue(decoded.length > 0, 'expected a non-empty decode');
    for (let i: number = 0; i < decoded.length; i++) {
      t.isTrue(decoded[i] >= 1 && decoded[i] < params.m, 'values must stay in range');
      if (i > 0) {
        t.isTrue(decoded[i - 1] <= decoded[i], 'decoded set must be sorted');
      }
    }
  }

  // an out-of-range p decodes to nothing rather than to garbage
  {
    const params: GcsFilterParams = GCSFilter.buildFilter(ids, 400, 0.01);
    const badP: number[] = [0, 33, 64, 200, 255];
    for (let i: number = 0; i < badP.length; i++) {
      const decoded: number[] = GCSFilter.decodeToSortedSet(badP[i], params.m, params.data);
      t.isTrue(decoded.length === 0, 'p=' + badP[i] + ' should decode to nothing');
    }
  }

  // a degenerate m decodes to nothing
  {
    const params: GcsFilterParams = GCSFilter.buildFilter(ids, 400, 0.01);
    t.isTrue(GCSFilter.decodeToSortedSet(params.p, 0, params.data).length === 0,
      'm=0 should decode to nothing');
    t.isTrue(GCSFilter.decodeToSortedSet(params.p, 1, params.data).length === 0,
      'm=1 should decode to nothing');
  }
}
