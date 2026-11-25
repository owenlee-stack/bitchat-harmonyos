/**
 * Assertion surface shared by the golden-vector contract test modules under
 * entry/src/test/contract. The host runner (run-contract-tests.mjs) supplies
 * the implementation; the interface stays free of any framework import so the
 * same test files compile under ArkTS strict rules and run on Node.
 */
export interface ContractAssert {
  isTrue(condition: boolean, label: string): void;
  isFalse(condition: boolean, label: string): void;
  equalNumber(expected: number, actual: number, label: string): void;
  equalString(expected: string, actual: string, label: string): void;
  equalBytes(expected: Uint8Array, actual: Uint8Array, label: string): void;
  isNull<T>(value: T | null, label: string): void;
  isNotNull<T>(value: T | null, label: string): void;
  throws(action: () => void, label: string): void;
}
