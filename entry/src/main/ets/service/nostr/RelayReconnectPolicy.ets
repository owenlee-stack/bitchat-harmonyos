/**
 * Reconnect schedule for a Nostr relay socket, mirroring
 * bitchat-android RelayReconnectPolicy.kt.
 *
 * The backoff grows exponentially and then saturates rather than
 * terminating: nothing else brings relays back after the phone loses
 * its data connection, so retrying forever at the ceiling costs one
 * connection attempt per relay per MAX_BACKOFF_INTERVAL_MS while
 * giving up would cost the user every internet DM. Pure ArkTS: no
 * @ohos/@kit imports, host-runnable by the contract-test harness.
 */
import { NostrConstants } from '../../common/ProtocolConstants';

export class RelayReconnectPolicy {
  /**
   * Attempt count past which the interval stops growing; beyond it the
   * schedule pins at the ceiling so a long outage can neither run the
   * counter nor the exponent away.
   */
  static readonly SATURATION_ATTEMPTS: number = NostrConstants.MAX_RECONNECT_ATTEMPTS;

  /** Attempt number to record after a failure at previousAttempts. */
  static nextAttempt(previousAttempts: number): number {
    const clamped: number = previousAttempts < 0 ? 0 : previousAttempts;
    const next: number = clamped + 1;
    return next > RelayReconnectPolicy.SATURATION_ATTEMPTS
      ? RelayReconnectPolicy.SATURATION_ATTEMPTS : next;
  }

  /** Delay before the reconnect for a given attempt number (1-based). */
  static backoffMs(attempt: number): number {
    const step: number = attempt < 1 ? 1 : attempt;
    const exponential: number = NostrConstants.INITIAL_BACKOFF_INTERVAL_MS *
      Math.pow(NostrConstants.BACKOFF_MULTIPLIER, step - 1);
    const capped: number =
      Math.min(exponential, NostrConstants.MAX_BACKOFF_INTERVAL_MS);
    return Math.trunc(capped);
  }
}
