/**
 * Nostr relay wire protocol, mirroring bitchat-android NostrRequest.kt:
 * EVENT / REQ / CLOSE request messages serialized by the request Gson
 * (disableHtmlEscaping), and the EVENT / EOSE / OK / NOTICE / Unknown
 * response parse. The response event parse is deliberately LENIENT
 * (parseEventFromJson parity: missing fields fall back to "" / 0 / []
 * / null sig) and therefore different from the strict
 * NostrEvent.parse used for gift-wrap unwrapping. Pure ArkTS: no
 * @ohos/@kit imports, host-runnable by the contract-test harness.
 */
import { NostrEvent } from './NostrEvent';
import { NostrFilter } from './NostrFilter';

export enum NostrResponseType {
  EVENT = 0,
  EOSE = 1,
  OK = 2,
  NOTICE = 3,
  UNKNOWN = 4
}

export class NostrResponse {
  readonly type: NostrResponseType;
  readonly subscriptionId: string | null;
  readonly event: NostrEvent | null;
  readonly eventId: string | null;
  readonly accepted: boolean | null;
  readonly message: string | null;
  /** The raw message text (Android Unknown carries the re-serialized array; we keep the input). */
  readonly raw: string;

  constructor(type: NostrResponseType, subscriptionId: string | null,
    event: NostrEvent | null, eventId: string | null, accepted: boolean | null,
    message: string | null, raw: string) {
    this.type = type;
    this.subscriptionId = subscriptionId;
    this.event = event;
    this.eventId = eventId;
    this.accepted = accepted;
    this.message = message;
    this.raw = raw;
  }
}

export class NostrRequest {
  private static readonly INTEGER_PATTERN: RegExp = /^[+-]?\d+$/;

  /** ["EVENT",event] wire message (request Gson: disableHtmlEscaping). */
  static eventMessage(event: NostrEvent): string {
    return '["EVENT",' + event.toWireJsonString() + ']';
  }

  /** ["REQ",subscriptionId,filter] wire message. */
  static subscribeMessage(subscriptionId: string, filter: NostrFilter): string {
    return '["REQ","' + NostrEvent.jsonString(subscriptionId, false) + '",' +
      filter.toJsonString() + ']';
  }

  /** ["CLOSE",subscriptionId] wire message. */
  static closeMessage(subscriptionId: string): string {
    return '["CLOSE","' + NostrEvent.jsonString(subscriptionId, false) + '"]';
  }

  /**
   * Parse a relay response (NostrResponse.fromJsonArray parity). Any
   * structural anomaly that would make the Android Gson accessors
   * throw lands on Unknown rather than failing the caller.
   */
  static parseResponse(message: string): NostrResponse {
    let parsed: Object;
    try {
      parsed = JSON.parse(message) as Object;
    } catch (e) {
      return NostrRequest.unknown(message);
    }
    if (typeof parsed !== 'object' || parsed === null || !Array.isArray(parsed)) {
      return NostrRequest.unknown(message);
    }
    const arr: Object[] = parsed as Object[];
    if (arr.length === 0) {
      return NostrRequest.unknown(message);
    }
    const typeStr: string | null = NostrRequest.primitiveToString(arr[0]);
    if (typeStr === null) {
      return NostrRequest.unknown(message);
    }
    if (typeStr === 'EVENT') {
      return NostrRequest.parseEventResponse(arr, message);
    }
    if (typeStr === 'EOSE') {
      if (arr.length < 2) {
        return NostrRequest.unknown(message);
      }
      const subscriptionId: string | null = NostrRequest.primitiveToString(arr[1]);
      if (subscriptionId === null) {
        return NostrRequest.unknown(message);
      }
      return new NostrResponse(NostrResponseType.EOSE, subscriptionId, null,
        null, null, null, message);
    }
    if (typeStr === 'OK') {
      if (arr.length < 3) {
        return NostrRequest.unknown(message);
      }
      const eventId: string | null = NostrRequest.primitiveToString(arr[1]);
      const accepted: boolean = NostrRequest.primitiveToBoolean(arr[2]);
      if (eventId === null) {
        return NostrRequest.unknown(message);
      }
      let detail: string | null = null;
      if (arr.length >= 4) {
        detail = NostrRequest.primitiveToString(arr[3]);
        if (detail === null) {
          return NostrRequest.unknown(message);
        }
      }
      return new NostrResponse(NostrResponseType.OK, null, null, eventId,
        accepted, detail, message);
    }
    if (typeStr === 'NOTICE') {
      if (arr.length < 2) {
        return NostrRequest.unknown(message);
      }
      const notice: string | null = NostrRequest.primitiveToString(arr[1]);
      if (notice === null) {
        return NostrRequest.unknown(message);
      }
      return new NostrResponse(NostrResponseType.NOTICE, null, null, null,
        null, notice, message);
    }
    return NostrRequest.unknown(message);
  }

  private static parseEventResponse(arr: Object[], message: string): NostrResponse {
    if (arr.length < 3) {
      return NostrRequest.unknown(message);
    }
    const subscriptionId: string | null = NostrRequest.primitiveToString(arr[1]);
    if (subscriptionId === null) {
      return NostrRequest.unknown(message);
    }
    const eventObj: Object = arr[2];
    if (typeof eventObj !== 'object' || eventObj === null || Array.isArray(eventObj)) {
      return NostrRequest.unknown(message);
    }
    const event: NostrEvent | null =
      NostrRequest.parseResponseEvent(eventObj as Record<string, Object>);
    if (event === null) {
      return NostrRequest.unknown(message);
    }
    return new NostrResponse(NostrResponseType.EVENT, subscriptionId, event,
      null, null, null, message);
  }

  /**
   * Lenient event parse (parseEventFromJson parity): missing fields
   * default to "" / 0 / [] / null sig; an explicit JSON null or an
   * incompatible scalar aborts to null (the Android accessors throw
   * and the whole response becomes Unknown).
   */
  private static parseResponseEvent(raw: Record<string, Object>): NostrEvent | null {
    const id: string | null = NostrRequest.lenientStringField(raw, 'id', '');
    if (id === null) {
      return null;
    }
    const pubkey: string | null = NostrRequest.lenientStringField(raw, 'pubkey', '');
    if (pubkey === null) {
      return null;
    }
    const content: string | null = NostrRequest.lenientStringField(raw, 'content', '');
    if (content === null) {
      return null;
    }
    const createdAt: number | null = NostrRequest.lenientIntField(raw, 'created_at');
    if (createdAt === null) {
      return null;
    }
    const kind: number | null = NostrRequest.lenientIntField(raw, 'kind');
    if (kind === null) {
      return null;
    }
    const tags: string[][] | null = NostrRequest.lenientTagsField(raw);
    if (tags === null) {
      return null;
    }
    const sig: string | null | undefined =
      NostrRequest.lenientOptionalStringField(raw, 'sig');
    if (sig === undefined) {
      return null;
    }
    return new NostrEvent(id, pubkey, createdAt, kind, tags, content, sig);
  }

  private static lenientStringField(raw: Record<string, Object>, field: string,
    missingDefault: string): string | null {
    const value: Object | undefined = raw[field];
    if (value === undefined) {
      return missingDefault;
    }
    return NostrRequest.primitiveToString(value);
  }

  private static lenientOptionalStringField(raw: Record<string, Object>,
    field: string): string | null | undefined {
    const value: Object | undefined = raw[field];
    if (value === undefined) {
      // Missing field: Android's ?. leaves the sig null.
      return null;
    }
    if (value === null) {
      // Explicit JSON null: JsonNull.asString throws, so the response
      // becomes Unknown.
      return undefined;
    }
    return NostrRequest.primitiveToString(value);
  }

  private static lenientIntField(raw: Record<string, Object>, field: string): number | null {
    const value: Object | undefined = raw[field];
    if (value === undefined) {
      return 0;
    }
    if (typeof value === 'number') {
      return Math.trunc(value);
    }
    // Gson: getAsInt parses the string form via Integer.parseInt, so
    // a non-integer string throws and the response becomes Unknown.
    if (typeof value === 'string' && NostrRequest.INTEGER_PATTERN.test(value)) {
      const parsed: number = Number(value);
      if (!Number.isNaN(parsed)) {
        return Math.trunc(parsed);
      }
    }
    return null;
  }

  private static lenientTagsField(raw: Record<string, Object>): string[][] | null {
    const value: Object | undefined = raw['tags'];
    if (value === undefined) {
      return [];
    }
    if (typeof value !== 'object' || value === null || !Array.isArray(value)) {
      // .asJsonArray throws on a non-array tags value.
      return null;
    }
    const rawTags: Object[] = value as Object[];
    const out: string[][] = [];
    for (let i: number = 0; i < rawTags.length; i++) {
      const rawTag: Object = rawTags[i];
      if (typeof rawTag !== 'object' || rawTag === null || !Array.isArray(rawTag)) {
        // Non-array element -> empty tag.
        out.push([]);
        continue;
      }
      const rawItems: Object[] = rawTag as Object[];
      const tag: string[] = [];
      let anomaly: boolean = false;
      for (let j: number = 0; j < rawItems.length; j++) {
        const item: Object = rawItems[j];
        const itemStr: string | null = NostrRequest.primitiveToString(item);
        if (itemStr === null) {
          // Inner anomaly -> whole tags list empties.
          anomaly = true;
          break;
        }
        tag.push(itemStr);
      }
      if (anomaly) {
        return [];
      }
      out.push(tag);
    }
    return out;
  }

  /** Gson JsonPrimitive.getAsString: primitives coerce, objects/null fail. */
  private static primitiveToString(value: Object): string | null {
    if (typeof value === 'string') {
      return value;
    }
    if (typeof value === 'number') {
      return value.toString();
    }
    if (typeof value === 'boolean') {
      return value ? 'true' : 'false';
    }
    return null;
  }

  /** Gson getAsBoolean: Boolean.parseBoolean over the string form (case-insensitive). */
  private static primitiveToBoolean(value: Object): boolean {
    if (typeof value === 'boolean') {
      return value;
    }
    const asString: string | null = NostrRequest.primitiveToString(value);
    if (asString === null) {
      return false;
    }
    return asString.toLowerCase() === 'true';
  }

  private static unknown(message: string): NostrResponse {
    return new NostrResponse(NostrResponseType.UNKNOWN, null, null, null,
      null, null, message);
  }
}
