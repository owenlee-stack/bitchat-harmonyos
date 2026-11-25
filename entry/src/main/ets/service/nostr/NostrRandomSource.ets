/**
 * Randomness source for the Nostr protocol kernel.
 *
 * Production code injects a crypto-secure implementation; the contract
 * tests inject a scripted source so every envelope (NIP-44 nonce, seal
 * and gift-wrap timestamps, ephemeral gift-wrap key, Schnorr aux) becomes
 * deterministic and golden-verifiable. Pure ArkTS interface: no
 * @ohos/@kit imports, host-runnable by the contract-test harness.
 */
export interface NostrRandomSource {
  /** Returns `count` cryptographically secure random bytes. */
  nextBytes(count: number): Uint8Array;

  /** Returns a uniformly random integer in [0, bound); bound must be > 0. */
  nextInt(bound: number): number;
}
