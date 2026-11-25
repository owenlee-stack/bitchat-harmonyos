/**
 * Nostr event structure following NIP-01, immutable.
 *
 * Mirrors bitchat-android NostrEvent.kt: the id is the SHA-256 of the
 * compact JSON serialization [0,pubkey,created_at,kind,tags,content]
 * (Gson with disableHtmlEscaping), signatures are BIP-340 Schnorr over
 * the raw id bytes, and toJsonString uses Gson defaults (HTML-safe
 * escapes, "created_at" key, null sig omitted). Pure ArkTS: no
 * @ohos/@kit imports, host-runnable by the contract-test harness.
 */
import { ByteUtils } from '../../common/ByteUtils';
import { Secp256k1 } from './Secp256k1';
import { NostrRandomSource } from './NostrRandomSource';

/** Nostr event kinds (bitchat-android NostrKind). */
export class NostrKind {
  static readonly METADATA: number = 0;
  static readonly TEXT_NOTE: number = 1;
  static readonly SEAL: number = 13;
  static readonly DIRECT_MESSAGE: number = 14;
  static readonly FILE_MESSAGE: number = 15;
  static readonly GIFT_WRAP: number = 1059;
  static readonly EPHEMERAL_EVENT: number = 20000;
  static readonly GEOHASH_PRESENCE: number = 20001;
}

export class NostrEvent {
  readonly id: string;
  readonly pubkey: string;
  readonly createdAt: number;
  readonly kind: number;
  readonly tags: string[][];
  readonly content: string;
  readonly sig: string | null;

  constructor(id: string, pubkey: string, createdAt: number, kind: number,
    tags: string[][], content: string, sig: string | null) {
    this.id = id;
    this.pubkey = pubkey;
    this.createdAt = createdAt;
    this.kind = kind;
    this.tags = tags;
    this.content = content;
    this.sig = sig;
  }

  /** Compute the NIP-01 event id (SHA-256 hex of the canonical serialization). */
  computeEventIdHex(): string {
    const serialized: string = NostrEvent.serializeForId(
      this.pubkey, this.createdAt, this.kind, this.tags, this.content);
    return ByteUtils.sha256Hex(ByteUtils.utf8Encode(serialized));
  }

  /**
   * Sign with BIP-340 Schnorr; the aux randomness is drawn from the
   * injected source so contract tests stay deterministic. Returns a new
   * signed event (id and sig set).
   */
  sign(privateKeyHex: string, random: NostrRandomSource): NostrEvent {
    const eventId: string = this.computeEventIdHex();
    const signature: string =
      Secp256k1.schnorrSign(ByteUtils.hexToBytes(eventId), privateKeyHex, random.nextBytes(32));
    return new NostrEvent(eventId, this.pubkey, this.createdAt, this.kind,
      this.tags, this.content, signature);
  }

  /** Validate the event signature using BIP-340 Schnorr verification. */
  isValidSignature(): boolean {
    if (this.sig === null || this.id.length === 0 || this.pubkey.length === 0) {
      return false;
    }
    const calculatedId: string = this.computeEventIdHex();
    if (calculatedId !== this.id) {
      return false;
    }
    return Secp256k1.schnorrVerify(ByteUtils.hexToBytes(this.id), this.sig, this.pubkey);
  }

  /** Validate event structure and signature (Android isValid parity). */
  isValid(): boolean {
    if (this.pubkey.length === 0 || this.content.length === 0) {
      return false;
    }
    if (this.createdAt <= 0 || this.kind < 0) {
      return false;
    }
    if (!Secp256k1.isValidXOnlyPublicKey(this.pubkey)) {
      return false;
    }
    return this.isValidSignature();
  }

  /** Gson-default JSON: HTML-safe escapes, "created_at" key, null sig omitted. */
  toJsonString(): string {
    return NostrEvent.buildJsonString(this, true);
  }

  /**
   * Wire (request) JSON: same field order and created_at key as
   * toJsonString but serialized with the request Gson's
   * disableHtmlEscaping, so <, >, &, =, and ' stay raw on the wire.
   */
  toWireJsonString(): string {
    return NostrEvent.buildJsonString(this, false);
  }

  private static buildJsonString(event: NostrEvent, htmlSafe: boolean): string {
    let out: string = '{"id":"' + NostrEvent.jsonString(event.id, htmlSafe) +
      '","pubkey":"' + NostrEvent.jsonString(event.pubkey, htmlSafe) +
      '","created_at":' + event.createdAt.toString() +
      ',"kind":' + event.kind.toString() +
      ',"tags":' + NostrEvent.jsonTags(event.tags, htmlSafe) +
      ',"content":"' + NostrEvent.jsonString(event.content, htmlSafe) + '"';
    if (event.sig !== null) {
      out += ',"sig":"' + NostrEvent.jsonString(event.sig, htmlSafe) + '"';
    }
    out += '}';
    return out;
  }

  /**
   * Parse an event JSON object (Android unwrapGiftWrap/openSeal
   * semantics). Invalid JSON, a non-object root, an explicit JSON null
   * field, a non-array "tags" value, or structurally impossible scalars
   * return null; missing optional fields fall back to the Gson field
   * defaults Android relies on ("" / 0 / null / empty tags); a
   * non-array tag element parses as an empty tag, and a non-scalar tag
   * item empties the whole tag list. Divergence: numeric strings where
   * Gson would coerce ("123" for created_at) are treated as parse
   * failures; relays always send native JSON numbers.
   */
  static parse(jsonText: string): NostrEvent | null {
    let raw: Record<string, Object> | null = null;
    try {
      raw = JSON.parse(jsonText) as Record<string, Object>;
    } catch (e) {
      return null;
    }
    if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
      return null;
    }
    // An explicit JSON null makes the Gson .asString/.asInt access
    // throw on Android, failing the whole unwrap.
    if (raw['id'] === null || raw['pubkey'] === null || raw['created_at'] === null ||
      raw['kind'] === null || raw['tags'] === null || raw['content'] === null ||
      raw['sig'] === null) {
      return null;
    }
    const id: string | null = NostrEvent.parseStringField(raw, 'id');
    if (id === null) {
      return null;
    }
    const pubkey: string | null = NostrEvent.parseStringField(raw, 'pubkey');
    if (pubkey === null) {
      return null;
    }
    const content: string | null = NostrEvent.parseStringField(raw, 'content');
    if (content === null) {
      return null;
    }
    const sig: string | null | undefined =
      NostrEvent.parseOptionalStringField(raw, 'sig');
    if (sig === undefined) {
      return null;
    }
    const createdAt: number | null = NostrEvent.parseNumberField(raw, 'created_at');
    if (createdAt === null) {
      return null;
    }
    const kind: number | null = NostrEvent.parseNumberField(raw, 'kind');
    if (kind === null) {
      return null;
    }
    const tags: string[][] | null = NostrEvent.parseTags(raw);
    if (tags === null) {
      return null;
    }
    return new NostrEvent(id, pubkey, createdAt, kind, tags, content, sig);
  }

  /** Canonical NIP-01 id serialization (Gson with disableHtmlEscaping). */
  static serializeForId(pubkey: string, createdAt: number, kind: number,
    tags: string[][], content: string): string {
    return '[0,"' + NostrEvent.jsonString(pubkey, false) + '",' +
      createdAt.toString() + ',' + kind.toString() + ',' +
      NostrEvent.jsonTags(tags, false) +
      ',"' + NostrEvent.jsonString(content, false) + '"]';
  }

  /** Gson JSON string escaping. htmlSafe adds the <, >, &, =, ' escapes. */
  static jsonString(value: string, htmlSafe: boolean): string {
    let out: string = '';
    for (let i: number = 0; i < value.length; i++) {
      const ch: string = value.charAt(i);
      const code: number = value.charCodeAt(i);
      if (ch === '"') {
        out += '\\"';
      } else if (ch === '\\') {
        out += '\\\\';
      } else if (ch === '\n') {
        out += '\\n';
      } else if (ch === '\r') {
        out += '\\r';
      } else if (ch === '\t') {
        out += '\\t';
      } else if (ch === '\b') {
        out += '\\b';
      } else if (ch === '\f') {
        out += '\\f';
      } else if (code < 0x20 || code === 0x2028 || code === 0x2029) {
        out += '\\u' + NostrEvent.hex4Lower(code);
      } else if (htmlSafe && ch === '<') {
        out += '\\u003c';
      } else if (htmlSafe && ch === '>') {
        out += '\\u003e';
      } else if (htmlSafe && ch === '&') {
        out += '\\u0026';
      } else if (htmlSafe && ch === '=') {
        out += '\\u003d';
      } else if (htmlSafe && ch === '\'') {
        out += '\\u0027';
      } else {
        out += ch;
      }
    }
    return out;
  }

  private static jsonTags(tags: string[][], htmlSafe: boolean): string {
    let out: string = '[';
    for (let i: number = 0; i < tags.length; i++) {
      if (i > 0) {
        out += ',';
      }
      const tag: string[] = tags[i];
      out += '[';
      for (let j: number = 0; j < tag.length; j++) {
        if (j > 0) {
          out += ',';
        }
        out += '"' + NostrEvent.jsonString(tag[j], htmlSafe) + '"';
      }
      out += ']';
    }
    out += ']';
    return out;
  }

  private static hex4Lower(code: number): string {
    const digits: string = '0123456789abcdef';
    return digits.charAt((code >>> 12) & 0xF) + digits.charAt((code >>> 8) & 0xF) +
      digits.charAt((code >>> 4) & 0xF) + digits.charAt(code & 0xF);
  }

  private static parseStringField(raw: Record<string, Object>, field: string): string | null {
    const value: Object | undefined = raw[field];
    if (value === undefined) {
      return '';
    }
    if (typeof value === 'string') {
      return value;
    }
    if (typeof value === 'number') {
      return NostrEvent.numberToString(value);
    }
    if (typeof value === 'boolean') {
      return value ? 'true' : 'false';
    }
    return null;
  }

  private static parseOptionalStringField(raw: Record<string, Object>,
    field: string): string | null | undefined {
    const value: Object | undefined = raw[field];
    if (value === undefined || value === null) {
      return null;
    }
    if (typeof value === 'string') {
      return value;
    }
    if (typeof value === 'number') {
      return NostrEvent.numberToString(value);
    }
    if (typeof value === 'boolean') {
      return value ? 'true' : 'false';
    }
    return undefined;
  }

  private static parseNumberField(raw: Record<string, Object>,
    field: string): number | null {
    const value: Object | undefined = raw[field];
    if (value === undefined) {
      return 0;
    }
    if (typeof value === 'number') {
      return Math.trunc(value);
    }
    // Documented divergence: numeric strings where Gson would coerce
    // ("123" for created_at) are treated as parse failures; relays
    // always send native JSON numbers.
    return null;
  }

  private static parseTags(raw: Record<string, Object>): string[][] | null {
    const value: Object | undefined = raw['tags'];
    if (value === undefined) {
      return [];
    }
    if (typeof value !== 'object' || value === null || !Array.isArray(value)) {
      return null;
    }
    const rawTags: Object[] = value as Object[];
    const out: string[][] = [];
    for (let i: number = 0; i < rawTags.length; i++) {
      const rawTag: Object = rawTags[i];
      if (typeof rawTag !== 'object' || rawTag === null || !Array.isArray(rawTag)) {
        // Android parseTagsFromJson: non-array element -> empty tag.
        out.push([]);
        continue;
      }
      const rawItems: Object[] = rawTag as Object[];
      const tag: string[] = [];
      for (let j: number = 0; j < rawItems.length; j++) {
        const item: Object = rawItems[j];
        if (typeof item === 'string') {
          tag.push(item);
        } else if (typeof item === 'number') {
          tag.push(NostrEvent.numberToString(item));
        } else if (typeof item === 'boolean') {
          tag.push(item ? 'true' : 'false');
        } else {
          // Android parseTagsFromJson: inner anomaly -> empty tag list.
          return [];
        }
      }
      out.push(tag);
    }
    return out;
  }

  private static numberToString(value: number): string {
    return value.toString();
  }
}
