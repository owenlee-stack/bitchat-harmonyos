/**
 * Nostr subscription filter, mirroring bitchat-android NostrFilter.kt
 * and its FilterSerializer: JSON field order ids, authors, kinds,
 * since, until, limit, then "#"-prefixed tag filters, serialized with
 * the request Gson's disableHtmlEscaping. giftWrapsFor is the NIP-17
 * private-message subscription (kind 1059, #p recipient tag, limit
 * 100, millisecond-since converted to seconds). matches() enforces
 * the filter client-side so a misbehaving relay cannot route events
 * into the wrong subscription. Pure ArkTS: no @ohos/@kit imports,
 * host-runnable by the contract-test harness.
 */
import { NostrEvent, NostrKind } from './NostrEvent';

export class NostrFilter {
  readonly ids: string[] | null;
  readonly authors: string[] | null;
  readonly kinds: number[] | null;
  readonly since: number | null;
  readonly until: number | null;
  readonly limit: number | null;
  /** Tag filters keyed by single-letter tag name ("p", "e", "g"), insertion-ordered. */
  readonly tagFilters: Map<string, string[]> | null;

  constructor(ids: string[] | null, authors: string[] | null, kinds: number[] | null,
    since: number | null, until: number | null, limit: number | null,
    tagFilters: Map<string, string[]> | null) {
    this.ids = ids;
    this.authors = authors;
    this.kinds = kinds;
    this.since = since;
    this.until = until;
    this.limit = limit;
    this.tagFilters = tagFilters;
  }

  /** NIP-17 gift-wrap subscription: kind 1059 tagged to the recipient. */
  static giftWrapsFor(pubkey: string, sinceMs: number | null): NostrFilter {
    const tagFilters: Map<string, string[]> = new Map<string, string[]>();
    tagFilters.set('p', [pubkey]);
    return new NostrFilter(null, null, [NostrKind.GIFT_WRAP],
      sinceMs === null ? null : Math.trunc(sinceMs / 1000), null, 100, tagFilters);
  }

  /** FilterSerializer JSON (request Gson: disableHtmlEscaping). */
  toJsonString(): string {
    let out: string = '{';
    let first: boolean = true;
    if (this.ids !== null) {
      out += '"ids":' + NostrFilter.stringArrayJson(this.ids);
      first = false;
    }
    if (this.authors !== null) {
      out += (first ? '' : ',') + '"authors":' + NostrFilter.stringArrayJson(this.authors);
      first = false;
    }
    if (this.kinds !== null) {
      out += (first ? '' : ',') + '"kinds":' + NostrFilter.numberArrayJson(this.kinds);
      first = false;
    }
    if (this.since !== null) {
      out += (first ? '' : ',') + '"since":' + this.since.toString();
      first = false;
    }
    if (this.until !== null) {
      out += (first ? '' : ',') + '"until":' + this.until.toString();
      first = false;
    }
    if (this.limit !== null) {
      out += (first ? '' : ',') + '"limit":' + this.limit.toString();
      first = false;
    }
    if (this.tagFilters !== null) {
      this.tagFilters.forEach((values: string[], tag: string) => {
        out += (first ? '' : ',') + '"#' + tag + '":' + NostrFilter.stringArrayJson(values);
        first = false;
      });
    }
    out += '}';
    return out;
  }

  /** Client-side filter enforcement (NostrFilter.matches parity). */
  matches(event: NostrEvent): boolean {
    if (this.ids !== null && !this.ids.includes(event.id)) {
      return false;
    }
    if (this.authors !== null && !this.authors.includes(event.pubkey)) {
      return false;
    }
    if (this.kinds !== null && !this.kinds.includes(event.kind)) {
      return false;
    }
    if (this.since !== null && event.createdAt < this.since) {
      return false;
    }
    if (this.until !== null && event.createdAt > this.until) {
      return false;
    }
    if (this.tagFilters !== null) {
      let allMatch: boolean = true;
      this.tagFilters.forEach((requiredValues: string[], tagName: string) => {
        let hasMatch: boolean = false;
        for (let i: number = 0; i < event.tags.length; i++) {
          const tag: string[] = event.tags[i];
          if (tag.length === 0 || tag[0] !== tagName) {
            continue;
          }
          if (tag.length > 1 && requiredValues.includes(tag[1])) {
            hasMatch = true;
            break;
          }
        }
        if (!hasMatch) {
          allMatch = false;
        }
      });
      if (!allMatch) {
        return false;
      }
    }
    return true;
  }

  private static stringArrayJson(values: string[]): string {
    let out: string = '[';
    for (let i: number = 0; i < values.length; i++) {
      if (i > 0) {
        out += ',';
      }
      out += '"' + NostrEvent.jsonString(values[i], false) + '"';
    }
    return out + ']';
  }

  private static numberArrayJson(values: number[]): string {
    let out: string = '[';
    for (let i: number = 0; i < values.length; i++) {
      if (i > 0) {
        out += ',';
      }
      out += values[i].toString();
    }
    return out + ']';
  }
}
