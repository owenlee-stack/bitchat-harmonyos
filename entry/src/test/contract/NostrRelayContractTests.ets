/**
 * Nostr relay client contract tests (US12, T059): Android
 * NostrFilter / NostrRequest / NostrEventDeduplicator /
 * NostrPendingEventQueue / NostrTransport read-ack throttle parity,
 * plus the NostrEvent wire (disableHtmlEscaping) JSON variant used by
 * the relay wire format and the T059 constants pinned in
 * tasks.md (backoff 1s->300s x2 max 10, ACK 350ms, dedup 10,000,
 * subscription validation 30s).
 *
 *  - NostrFilter: giftWrapsFor wire golden (kind 1059, #p, limit 100,
 *    ms->s since), FilterSerializer field-order golden with
 *    html-unsafe escaping, matches() accept/reject matrix;
 *  - NostrRequest: ["EVENT",event] / ["REQ",id,filter] / ["CLOSE",id]
 *    wire goldens (html-unsafe event JSON, created_at key);
 *  - NostrResponse parse: EVENT/EOSE/OK/NOTICE/Unknown matrix with the
 *    lenient parseEventFromJson defaults (missing -> ""/0/[]/null),
 *    explicit-JSON-null rejection, malformed root/array rejection;
 *  - NostrEventDeduplicator: LRU eviction at capacity, recency
 *    refresh, statistics, clear;
 *  - NostrPendingEventQueue: relay-set dedupe, blank filtering,
 *    capacity drop-oldest, pendingForRelay, markDelivered;
 *  - NostrReadAckThrottle: 350ms-paced drain with a scripted
 *    scheduler, one ack per interval, FIFO order.
 */
import { ContractAssert } from './ContractAssert';
import { NostrConstants } from '../../main/ets/common/ProtocolConstants';
import { NostrEvent } from '../../main/ets/service/nostr/NostrEvent';
import { NostrFilter } from '../../main/ets/service/nostr/NostrFilter';
import { NostrRequest, NostrResponse, NostrResponseType } from '../../main/ets/service/nostr/NostrRequest';
import { DeduplicationStats, NostrEventDeduplicator } from '../../main/ets/service/nostr/NostrEventDeduplicator';
import { NostrPendingDelivery, NostrPendingEventQueue } from '../../main/ets/service/nostr/NostrPendingEventQueue';
import { NostrReadAckItem, NostrReadAckThrottle } from '../../main/ets/service/nostr/NostrReadAckThrottle';

const PEER_PUBKEY: string =
  '25d1dff95ecb5b2ceb9f7f0badb0b04acf5c8e12f4d2f59b5a9d7f4c4b3b3a0d';
const OTHER_PUBKEY: string =
  'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';

class ScheduledAction {
  delayMs: number;
  action: () => void;

  constructor(delayMs: number, action: () => void) {
    this.delayMs = delayMs;
    this.action = action;
  }
}

/** Fake scheduler recording timers for manual firing. */
class ScriptedScheduler {
  readonly actions: ScheduledAction[] = [];

  schedule(delayMs: number, action: () => void): void {
    this.actions.push(new ScheduledAction(delayMs, action));
  }

  fireNext(): void {
    const first: ScheduledAction | undefined = this.actions.shift();
    if (first !== undefined) {
      first.action();
    }
  }
}

export function runNostrRelayContractTests(t: ContractAssert): void {
  nostrFilterGiftWrapsFor(t);
  nostrFilterSerializationOrder(t);
  nostrFilterMatchesMatrix(t);
  nostrRequestWireMessages(t);
  nostrEventWireJsonHtmlUnsafe(t);
  nostrResponseParseMatrix(t);
  nostrEventDeduplicatorLru(t);
  nostrPendingEventQueue(t);
  nostrReadAckThrottle(t);
  relayManagerConstants(t);
}

function testEvent(content: string): NostrEvent {
  return new NostrEvent(
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    1700000000, 1059, [['p', PEER_PUBKEY]], content,
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc');
}

function nostrFilterGiftWrapsFor(t: ContractAssert): void {
  const withSince: NostrFilter = NostrFilter.giftWrapsFor(PEER_PUBKEY, 172800000);
  t.equalString('{"kinds":[1059],"since":172800,"limit":100,"#p":["' + PEER_PUBKEY + '"]}',
    withSince.toJsonString(), 'giftWrapsFor wire JSON with 48h since');
  const withoutSince: NostrFilter = NostrFilter.giftWrapsFor(PEER_PUBKEY, null);
  t.equalString('{"kinds":[1059],"limit":100,"#p":["' + PEER_PUBKEY + '"]}',
    withoutSince.toJsonString(), 'giftWrapsFor wire JSON without since');
}

function nostrFilterSerializationOrder(t: ContractAssert): void {
  const tags: Map<string, string[]> = new Map<string, string[]>();
  tags.set('p', [PEER_PUBKEY]);
  tags.set('g', ['ezs42']);
  const filter: NostrFilter = new NostrFilter(['id"x'], ['auth<y'], [1059], 5, 10, 100, tags);
  t.equalString(
    '{"ids":["id\\"x"],"authors":["auth<y"],"kinds":[1059],"since":5,"until":10,"limit":100' +
    ',"#p":["' + PEER_PUBKEY + '"],"#g":["ezs42"]}',
    filter.toJsonString(), 'FilterSerializer field order with html-unsafe escaping');
}

function nostrFilterMatchesMatrix(t: ContractAssert): void {
  const tags: Map<string, string[]> = new Map<string, string[]>();
  tags.set('p', [PEER_PUBKEY]);
  const filter: NostrFilter = new NostrFilter(null, null, [1059], 1699999999,
    1700000001, 100, tags);
  const event: NostrEvent = testEvent('payload');
  t.isTrue(filter.matches(event), 'gift-wrap filter accepts its event');
  // Wrong kind.
  const wrongKind: NostrEvent = new NostrEvent(event.id, event.pubkey,
    event.createdAt, 1, event.tags, event.content, event.sig);
  t.isFalse(filter.matches(wrongKind), 'filter rejects wrong kind');
  // Wrong #p tag.
  const wrongP: NostrEvent = new NostrEvent(event.id, event.pubkey,
    event.createdAt, 1059, [['p', OTHER_PUBKEY]], event.content, event.sig);
  t.isFalse(filter.matches(wrongP), 'filter rejects wrong p tag');
  // No p tag at all.
  const noTag: NostrEvent = new NostrEvent(event.id, event.pubkey,
    event.createdAt, 1059, [], event.content, event.sig);
  t.isFalse(filter.matches(noTag), 'filter rejects missing p tag');
  // Time bounds.
  const tooOld: NostrEvent = new NostrEvent(event.id, event.pubkey,
    1699999998, 1059, event.tags, event.content, event.sig);
  t.isFalse(filter.matches(tooOld), 'filter rejects before since');
  const tooNew: NostrEvent = new NostrEvent(event.id, event.pubkey,
    1700000002, 1059, event.tags, event.content, event.sig);
  t.isFalse(filter.matches(tooNew), 'filter rejects after until');
  // ids / authors.
  const idFilter: NostrFilter = new NostrFilter([event.id], null, null,
    null, null, null, null);
  t.isTrue(idFilter.matches(event), 'ids filter accepts its id');
  const otherIdFilter: NostrFilter = new NostrFilter(['zz'], null, null,
    null, null, null, null);
  t.isFalse(otherIdFilter.matches(event), 'ids filter rejects other id');
  const authorFilter: NostrFilter = new NostrFilter(null, [event.pubkey], null,
    null, null, null, null);
  t.isTrue(authorFilter.matches(event), 'authors filter accepts its author');
  // Empty-filter (all nulls) matches everything.
  const empty: NostrFilter = new NostrFilter(null, null, null, null, null, null, null);
  t.isTrue(empty.matches(event), 'empty filter accepts anything');
}

function nostrRequestWireMessages(t: ContractAssert): void {
  const event: NostrEvent = testEvent('hi');
  t.equalString('["EVENT",' + event.toWireJsonString() + ']',
    NostrRequest.eventMessage(event), 'EVENT wire message');
  const filter: NostrFilter = NostrFilter.giftWrapsFor(PEER_PUBKEY, 172800000);
  t.equalString('["REQ","sub-1",' + filter.toJsonString() + ']',
    NostrRequest.subscribeMessage('sub-1', filter), 'REQ wire message');
  t.equalString('["CLOSE","sub-1"]', NostrRequest.closeMessage('sub-1'),
    'CLOSE wire message');
  // Subscription IDs are JSON-escaped on the wire.
  t.equalString('["CLOSE","sub\\"1"]', NostrRequest.closeMessage('sub"1'),
    'CLOSE escapes the subscription id');
}

function nostrEventWireJsonHtmlUnsafe(t: ContractAssert): void {
  const event: NostrEvent = testEvent("a<b> & 'q'");
  const wire: string = event.toWireJsonString();
  t.isTrue(wire.includes('a<b> & \'q\''), 'wire JSON keeps <, &, \' raw');
  t.isFalse(wire.includes('\\u003c'), 'wire JSON has no html escapes');
  t.isTrue(wire.includes('"created_at":1700000000'), 'wire JSON uses created_at key');
  const htmlSafe: string = event.toJsonString();
  t.isTrue(htmlSafe.includes('a\\u003cb\\u003e \\u0026 \\u0027q\\u0027'),
    'toJsonString stays html-safe');
}

function nostrResponseParseMatrix(t: ContractAssert): void {
  // EVENT with a full event object.
  const eventResponse: NostrResponse = NostrRequest.parseResponse(
    '["EVENT","sub-1",{"id":"aa","pubkey":"bb","created_at":1700000000,"kind":1059,' +
    '"tags":[["p","cc"]],"content":"hello","sig":"dd"}]');
  t.equalNumber(NostrResponseType.EVENT, eventResponse.type, 'EVENT type');
  t.isNotNull(eventResponse.subscriptionId, 'EVENT subscription id present');
  if (eventResponse.subscriptionId !== null) {
    t.equalString('sub-1', eventResponse.subscriptionId, 'EVENT subscription id');
  }
  const parsedEvent: NostrEvent | null = eventResponse.event;
  t.isNotNull(parsedEvent, 'EVENT event present');
  if (parsedEvent !== null) {
    t.equalString('aa', parsedEvent.id, 'EVENT event id');
    t.equalNumber(1059, parsedEvent.kind, 'EVENT event kind');
    t.equalString('hello', parsedEvent.content, 'EVENT event content');
    t.isNotNull(parsedEvent.sig, 'EVENT event sig present');
    if (parsedEvent.sig !== null) {
      t.equalString('dd', parsedEvent.sig, 'EVENT event sig');
    }
  }
  // Lenient defaults: missing fields -> ""/0/[]/null sig.
  const lenient: NostrResponse = NostrRequest.parseResponse(
    '["EVENT","s",{"id":"aa"}]');
  t.equalNumber(NostrResponseType.EVENT, lenient.type, 'lenient EVENT type');
  const lenientEvent: NostrEvent | null = lenient.event;
  t.isNotNull(lenientEvent, 'lenient EVENT event present');
  if (lenientEvent !== null) {
    t.equalString('', lenientEvent.pubkey, 'missing pubkey defaults to empty');
    t.equalNumber(0, lenientEvent.createdAt, 'missing created_at defaults to 0');
    t.equalNumber(0, lenientEvent.kind, 'missing kind defaults to 0');
    t.equalNumber(0, lenientEvent.tags.length, 'missing tags default to empty');
    t.isNull(lenientEvent.sig, 'missing sig defaults to null');
  }
  // Explicit JSON null fails the Gson accessors -> Unknown.
  t.equalNumber(NostrResponseType.UNKNOWN,
    NostrRequest.parseResponse('["EVENT","s",{"id":null}]').type,
    'explicit null id becomes Unknown');
  t.equalNumber(NostrResponseType.UNKNOWN,
    NostrRequest.parseResponse('["EVENT","s",{"id":"aa","sig":null}]').type,
    'explicit null sig becomes Unknown');
  // Short EVENT array and non-object event -> Unknown.
  t.equalNumber(NostrResponseType.UNKNOWN,
    NostrRequest.parseResponse('["EVENT","s"]').type, 'short EVENT becomes Unknown');
  t.equalNumber(NostrResponseType.UNKNOWN,
    NostrRequest.parseResponse('["EVENT","s","str"]').type,
    'non-object event becomes Unknown');
  // EOSE.
  const eose: NostrResponse = NostrRequest.parseResponse('["EOSE","sub-1"]');
  t.equalNumber(NostrResponseType.EOSE, eose.type, 'EOSE type');
  t.isNotNull(eose.subscriptionId, 'EOSE subscription id present');
  if (eose.subscriptionId !== null) {
    t.equalString('sub-1', eose.subscriptionId, 'EOSE subscription id');
  }
  t.equalNumber(NostrResponseType.UNKNOWN,
    NostrRequest.parseResponse('["EOSE"]').type, 'short EOSE becomes Unknown');
  // OK with and without message.
  const ok: NostrResponse = NostrRequest.parseResponse(
    '["OK","aa",true,"accepted"]');
  t.equalNumber(NostrResponseType.OK, ok.type, 'OK type');
  t.isNotNull(ok.eventId, 'OK event id present');
  if (ok.eventId !== null) {
    t.equalString('aa', ok.eventId, 'OK event id');
  }
  t.isNotNull(ok.accepted, 'OK accepted present');
  if (ok.accepted !== null) {
    t.isTrue(ok.accepted, 'OK accepted');
  }
  t.isNotNull(ok.message, 'OK message present');
  if (ok.message !== null) {
    t.equalString('accepted', ok.message, 'OK message');
  }
  const okBare: NostrResponse = NostrRequest.parseResponse('["OK","aa",false]');
  t.isNotNull(okBare.accepted, 'OK rejected present');
  if (okBare.accepted !== null) {
    t.isFalse(okBare.accepted, 'OK rejected');
  }
  t.isNull(okBare.message, 'OK message defaults to null');
  // NOTICE.
  const notice: NostrResponse = NostrRequest.parseResponse(
    '["NOTICE","rate limited"]');
  t.equalNumber(NostrResponseType.NOTICE, notice.type, 'NOTICE type');
  t.isNotNull(notice.message, 'NOTICE message present');
  if (notice.message !== null) {
    t.equalString('rate limited', notice.message, 'NOTICE message');
  }
  // Unknown type, non-array root, empty array, malformed JSON.
  t.equalNumber(NostrResponseType.UNKNOWN,
    NostrRequest.parseResponse('["WHATEVER","x"]').type, 'unknown type label');
  t.equalNumber(NostrResponseType.UNKNOWN,
    NostrRequest.parseResponse('{"a":1}').type, 'non-array root becomes Unknown');
  t.equalNumber(NostrResponseType.UNKNOWN,
    NostrRequest.parseResponse('[]').type, 'empty array becomes Unknown');
  t.equalNumber(NostrResponseType.UNKNOWN,
    NostrRequest.parseResponse('not json').type, 'malformed JSON becomes Unknown');
}

function nostrEventDeduplicatorLru(t: ContractAssert): void {
  const dedup: NostrEventDeduplicator = new NostrEventDeduplicator(3);
  t.isFalse(dedup.isDuplicate('a'), 'first a is new');
  t.isFalse(dedup.isDuplicate('b'), 'b is new');
  t.isFalse(dedup.isDuplicate('c'), 'c is new');
  // Recency refresh: order becomes b,c,a.
  t.isTrue(dedup.isDuplicate('a'), 'second a is duplicate');
  // d evicts the least-recent b; order c,a,d.
  t.isFalse(dedup.isDuplicate('d'), 'd is new and evicts b');
  // b is back and new; it evicts c; order a,d,b.
  t.isFalse(dedup.isDuplicate('b'), 'b was evicted and is new again');
  t.isTrue(dedup.contains('a'), 'a survived both evictions');
  t.isTrue(dedup.contains('d'), 'd survived both evictions');
  t.isFalse(dedup.contains('c'), 'c was evicted');
  t.equalNumber(3, dedup.size(), 'size is bounded by capacity');
  const stats: DeduplicationStats = dedup.getStats();
  t.equalNumber(3, stats.capacity, 'stats capacity');
  t.equalNumber(3, stats.currentSize, 'stats current size');
  t.equalNumber(6, stats.totalChecks, 'stats total checks');
  t.equalNumber(1, stats.duplicateCount, 'stats duplicate count');
  t.equalNumber(2, stats.evictionCount, 'stats eviction count');
  t.isTrue(stats.hitRate > 0.16 && stats.hitRate < 0.17, 'stats hit rate');
  dedup.clear();
  t.equalNumber(0, dedup.size(), 'clear empties the cache');
  t.isFalse(dedup.isDuplicate('a'), 'cleared id is new again');
  const cleared: DeduplicationStats = dedup.getStats();
  t.equalNumber(1, cleared.totalChecks, 'clear resets statistics');
}

function nostrPendingEventQueue(t: ContractAssert): void {
  t.throws((): void => {
    const bad: NostrPendingEventQueue = new NostrPendingEventQueue(0);
  }, 'zero capacity throws');
  const queue: NostrPendingEventQueue = new NostrPendingEventQueue(2);
  const eventA: NostrEvent = testEvent('a');
  const eventB: NostrEvent = testEvent('b');
  const eventC: NostrEvent = testEvent('c');
  // Blank URLs are filtered; an all-blank set refuses to enqueue.
  t.isNull(queue.enqueue(eventA, ['  ', '']),
    'all-blank relay set returns null');
  const idA: number | null = queue.enqueue(eventA, ['wss://r1', 'wss://r1', 'wss://r2']);
  t.isNotNull(idA, 'enqueue returns a queue id');
  t.equalNumber(1, queue.size(), 'one entry queued');
  t.equalNumber(1, queue.pendingForRelay('wss://r1').length,
    'one delivery pending for r1');
  // markDelivered removes the entry once every relay is served.
  if (idA !== null) {
    queue.markDelivered(idA, 'wss://r1');
  }
  t.equalNumber(1, queue.size(), 'entry survives one relay delivered');
  if (idA !== null) {
    queue.markDelivered(idA, 'wss://r2');
  }
  t.equalNumber(0, queue.size(), 'entry drops after all relays served');
  // Capacity 2 drops the oldest entry.
  queue.enqueue(eventA, ['wss://r1']);
  queue.enqueue(eventB, ['wss://r1']);
  queue.enqueue(eventC, ['wss://r1']);
  t.equalNumber(2, queue.size(), 'capacity bound holds');
  const deliveries: NostrPendingDelivery[] = queue.pendingForRelay('wss://r1');
  t.equalNumber(2, deliveries.length, 'two deliveries pending');
  t.equalString('b', deliveries[0].event.content, 'oldest surviving entry is b');
  t.equalString('c', deliveries[1].event.content, 'newest entry is c');
  // pendingForRelay only returns entries targeting that relay.
  queue.enqueue(eventA, ['wss://r9']);
  t.equalNumber(1, queue.pendingForRelay('wss://r9').length,
    'r9 sees only its own delivery');
  queue.clear();
  t.equalNumber(0, queue.size(), 'clear empties the queue');
}

function nostrReadAckThrottle(t: ContractAssert): void {
  const sent: NostrReadAckItem[] = [];
  const scheduler: ScriptedScheduler = new ScriptedScheduler();
  const throttle: NostrReadAckThrottle = NostrReadAckThrottle.atDefaultInterval(
    (item: NostrReadAckItem): void => {
      sent.push(item);
    },
    (delayMs: number, action: () => void): void => {
      scheduler.schedule(delayMs, action);
    });
  throttle.enqueue('m1', 'peerA');
  throttle.enqueue('m2', 'peerA');
  throttle.enqueue('m3', 'peerB');
  // First ack goes out immediately; the rest wait for the interval.
  t.equalNumber(1, sent.length, 'first read ack sent immediately');
  t.equalString('m1', sent[0].messageId, 'first ack is m1');
  t.equalNumber(2, throttle.pendingCount(), 'two acks still queued');
  t.equalNumber(1, scheduler.actions.length, 'one timer scheduled');
  t.equalNumber(350, scheduler.actions[0].delayMs,
    'timer is the 350ms read-ack interval');
  scheduler.fireNext();
  t.equalNumber(2, sent.length, 'second ack after one interval');
  t.equalString('m2', sent[1].messageId, 'second ack is m2 (FIFO)');
  scheduler.fireNext();
  t.equalNumber(3, sent.length, 'third ack after two intervals');
  t.equalString('peerB', sent[2].peerId, 'third ack carries its peer');
  t.equalNumber(0, throttle.pendingCount(), 'queue drained');
  scheduler.fireNext();
  t.equalNumber(3, sent.length, 'no further acks once drained');
}

function relayManagerConstants(t: ContractAssert): void {
  t.equalNumber(1000, NostrConstants.INITIAL_BACKOFF_INTERVAL_MS, 'initial backoff 1s');
  t.equalNumber(300000, NostrConstants.MAX_BACKOFF_INTERVAL_MS, 'max backoff 300s');
  t.equalNumber(2, NostrConstants.BACKOFF_MULTIPLIER, 'backoff multiplier x2');
  t.equalNumber(10, NostrConstants.MAX_RECONNECT_ATTEMPTS, 'max 10 reconnect attempts');
  t.equalNumber(350, NostrConstants.READ_ACK_INTERVAL_MS, 'read ack 350ms');
  t.equalNumber(10000, NostrConstants.DEFAULT_DEDUP_CAPACITY, 'dedup capacity 10000');
  t.equalNumber(30000, NostrConstants.SUBSCRIPTION_VALIDATION_INTERVAL_MS,
    'subscription validation 30s');
}
