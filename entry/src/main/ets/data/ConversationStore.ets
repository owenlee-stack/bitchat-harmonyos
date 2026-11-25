/**
 * Private-conversation persistence (US4) - port of bitchat-android
 * ConversationRepository.kt / ConversationDatabase at the US4 scope:
 * a RelationalStore database whose message payload column holds only
 * AES-256-GCM ciphertext (SecureKeyStore HUKS key), with bounded
 * retention (1000 messages per conversation, 20000 total), deleted-message
 * tombstones so pruned/deleted history is not resurrected by re-delivery,
 * and a panic dropAll() used by the T043 wipe orchestrator.
 *
 * Divergences from the Android source, all intentional and scoped:
 *  - "single worker serial writes" (plan.md D8) is realized as one
 *    serialized async queue: every store operation runs strictly after the
 *    previous one, matching Android's single-thread dispatcher, because
 *    HarmonyOS RelationalStore operations are already dispatched off the
 *    caller thread and the RDB FAQ documents that a separate worker adds
 *    process isolation rather than throughput
 *  - no explicit SQL transactions: HarmonyOS async RDB plus manual
 *    begin/commit is documented as loss-prone, the serial queue provides
 *    the ordering guarantee, and a half-applied prune/tombstone is
 *    harmless (the next pass completes it)
 *  - no conversation_aliases / message_attachments tables yet: multi-alias
 *    merge needs ContactDirectory (later story), media attachments need
 *    the US8 media pipeline; both are additive migrations when they land
 *  - rows whose payload fails to decrypt (key wiped, corruption) are
 *    skipped with a warning instead of failing the whole load
 *  - BitchatMessage.timestampRaw is a wire-format cache and is not
 *    persisted; it is rebuilt from the wire when the message travels again
 *  - delivery_at is stored for Delivered/Read statuses; the model carries
 *    no delivery timestamp, so updates stamp the moment of the transition
 *
 * Retention limits mirror Android exactly: MAX_MESSAGES_PER_CONVERSATION
 * (1000), MAX_MESSAGES_TOTAL (20000), a prune pass every 64 writes and
 * prune batches of 256, always preferring to retire read messages before
 * unread ones and never the newest message of a conversation.
 */
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  BitchatMessage,
  BitchatMessageType,
  DeliveryStatusKind
} from '../model/BitchatMessage';
import { SecureKeyStore } from './SecureKeyStore';
import {
  ConversationPayloadCodec,
  StoredMessagePayload
} from './ConversationPayloadCodec';

const DOMAIN = 0x0000;
const STORE_TAG = 'ConversationStore';
const DATABASE_NAME = 'private_conversations.db';

const SQL_CREATE_CONVERSATIONS: string =
  'CREATE TABLE IF NOT EXISTS conversations (' +
  'conversation_id TEXT PRIMARY KEY NOT NULL, ' +
  'created_at INTEGER NOT NULL, ' +
  'updated_at INTEGER NOT NULL)';
const SQL_CREATE_PRIVATE_MESSAGES: string =
  'CREATE TABLE IF NOT EXISTS private_messages (' +
  'arrival_sequence INTEGER PRIMARY KEY AUTOINCREMENT, ' +
  'message_id TEXT UNIQUE NOT NULL, ' +
  'conversation_id TEXT NOT NULL, ' +
  'message_type INTEGER NOT NULL, ' +
  'sent_at INTEGER NOT NULL, ' +
  'received_at INTEGER NOT NULL, ' +
  'is_relay INTEGER NOT NULL, ' +
  'is_private INTEGER NOT NULL, ' +
  'is_encrypted INTEGER NOT NULL, ' +
  'delivery_type INTEGER NOT NULL, ' +
  'delivery_at INTEGER, ' +
  'is_read INTEGER NOT NULL DEFAULT 0, ' +
  'payload_ciphertext BLOB NOT NULL)';
const SQL_CREATE_DELETED: string =
  'CREATE TABLE IF NOT EXISTS deleted_private_messages (' +
  'message_id TEXT PRIMARY KEY NOT NULL, ' +
  'deleted_at INTEGER NOT NULL)';

/** Snapshot returned by the load methods (Android PersistedConversationSnapshot at US4 scope). */
export class PersistedConversationSnapshot {
  readonly messagesByConversation: Map<string, BitchatMessage[]> = new Map();
  readonly readMessageIDs: Set<string> = new Set();
  readonly deletedMessageIDs: Set<string> = new Set();
  readonly arrivalOrder: string[] = [];
  readonly unreadCounts: Map<string, number> = new Map();
  readonly receivedAtByMessageID: Map<string, number> = new Map();
}

export class ConversationStore {
  private static instance: ConversationStore | null = null;
  private static readonly MAX_MESSAGES_PER_CONVERSATION: number = 1000;
  private static readonly MAX_MESSAGES_TOTAL: number = 20000;
  private static readonly PRUNE_INTERVAL: number = 64;
  private static readonly PRUNE_BATCH_SIZE: number = 256;

  private readonly secure: SecureKeyStore;
  private context: common.Context | null = null;
  private initPromise: Promise<void> | null = null;
  private store: relationalStore.RdbStore | null = null;
  private queueTail: Promise<void> = Promise.resolve();
  private writesSinceGlobalPrune: number = 0;

  static getInstance(): ConversationStore {
    if (ConversationStore.instance === null) {
      ConversationStore.instance = new ConversationStore();
    }
    return ConversationStore.instance;
  }

  private constructor() {
    this.secure = SecureKeyStore.getInstance();
  }

  /** Idempotent; concurrent calls share one open. Call with an ability context before first use. */
  init(context: common.Context): Promise<void> {
    if (this.initPromise === null) {
      this.context = context;
      this.initPromise = this.doInit();
      this.initPromise.catch(() => {
        this.initPromise = null;
      });
    }
    return this.initPromise;
  }

  // ------------------------------------------------------------------
  // Public API - every operation runs on the serialized write queue
  // ------------------------------------------------------------------

  /**
   * Insert a private message (dedup by message ID; tombstoned IDs are
   * never resurrected). Returns whether a new row was inserted.
   */
  appendMessage(conversationID: string, message: BitchatMessage,
    isRead: boolean): Promise<boolean> {
    return this.enqueue((): Promise<boolean> =>
      this.doAppend(conversationID, message, isRead));
  }

  /** Persist a delivery/receipt transition under the Android priority ladder. */
  updateDeliveryStatus(messageID: string, status: DeliveryStatusKind,
    detail: string): Promise<void> {
    return this.enqueue((): Promise<void> =>
      this.doUpdateDeliveryStatus(messageID, status, detail));
  }

  /** Mark one stored message as read. */
  markRead(messageID: string): Promise<void> {
    return this.enqueue((): Promise<void> => this.doMarkRead(messageID));
  }

  /**
   * Mark a whole conversation read (or mark only its latest message
   * unread); returns the affected message ID when marking unread.
   */
  setConversationRead(conversationID: string, isRead: boolean): Promise<string | null> {
    return this.enqueue((): Promise<string | null> =>
      this.doSetConversationRead(conversationID, isRead));
  }

  /** Delete a conversation and tombstone its messages against re-delivery. */
  deleteConversation(conversationID: string): Promise<void> {
    return this.enqueue((): Promise<void> => this.doDeleteConversation(conversationID));
  }

  /** Delete one message and tombstone it against re-delivery. */
  deleteMessage(messageID: string): Promise<void> {
    return this.enqueue((): Promise<void> => this.doDeleteMessage(messageID));
  }

  /** Latest message per conversation plus tombstones and unread counts (cold start). */
  loadInitialSnapshot(): Promise<PersistedConversationSnapshot> {
    return this.enqueue((): Promise<PersistedConversationSnapshot> =>
      this.doLoadInitialSnapshot());
  }

  /** Full history of one conversation plus tombstones and unread counts. */
  loadConversation(conversationID: string): Promise<PersistedConversationSnapshot> {
    return this.enqueue((): Promise<PersistedConversationSnapshot> =>
      this.doLoadConversation(conversationID));
  }

  /** Enforce the retention limits immediately (normally done every 64 writes). */
  pruneToRetentionLimits(): Promise<void> {
    return this.enqueue((): Promise<void> => this.doPruneToRetentionLimits());
  }

  /**
   * Panic stage "delete the conversation database": drain the queue, wipe
   * every row and reset the arrival sequence. On failure the database file
   * is destroyed as a last resort (the ciphertext is already unopenable
   * once the HUKS key is wiped) and false is returned so the orchestrator
   * reports system_panic_incomplete.
   */
  dropAll(): Promise<boolean> {
    return this.enqueue((): Promise<boolean> => this.doDropAll());
  }

  // ------------------------------------------------------------------
  // Initialization
  // ------------------------------------------------------------------

  private async doInit(): Promise<void> {
    const context: common.Context | null = this.context;
    if (context === null) {
      throw new Error('ConversationStore.init requires a context');
    }
    const config: relationalStore.StoreConfig = {
      name: DATABASE_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store: relationalStore.RdbStore =
      await relationalStore.getRdbStore(context, config);
    await store.executeSql(SQL_CREATE_CONVERSATIONS);
    await store.executeSql(SQL_CREATE_PRIVATE_MESSAGES);
    await store.executeSql(SQL_CREATE_DELETED);
    await store.executeSql('CREATE INDEX IF NOT EXISTS ' +
      'idx_private_messages_conversation_arrival ' +
      'ON private_messages(conversation_id, arrival_sequence)');
    await store.executeSql('CREATE INDEX IF NOT EXISTS ' +
      'idx_private_messages_read_arrival ' +
      'ON private_messages(is_read, arrival_sequence)');
    await store.executeSql('CREATE INDEX IF NOT EXISTS ' +
      'idx_deleted_private_messages_time ' +
      'ON deleted_private_messages(deleted_at)');
    this.store = store;
  }

  private rdb(): relationalStore.RdbStore {
    const store: relationalStore.RdbStore | null = this.store;
    if (store === null) {
      throw new Error('ConversationStore is not initialized');
    }
    return store;
  }

  /** Serialize an operation after every previously queued one. */
  private enqueue<T>(task: () => Promise<T>): Promise<T> {
    const run: Promise<T> = this.queueTail.then(task, task);
    this.queueTail = run.then((): void => {
    }, (): void => {
    });
    return run;
  }

  // ------------------------------------------------------------------
  // Append
  // ------------------------------------------------------------------

  private async doAppend(conversationID: string, message: BitchatMessage,
    isRead: boolean): Promise<boolean> {
    const store: relationalStore.RdbStore = this.rdb();
    const normalized: string = conversationID.trim();
    if (normalized === '' || message.id === '') {
      return false;
    }
    const now: number = Date.now();
    if (await this.isTombstoned(store, message.id)) {
      return false;
    }
    await this.ensureConversation(store, normalized, now);
    let inserted: boolean = false;
    if (!(await this.messageExists(store, message.id))) {
      const cipher: Uint8Array =
        await this.secure.encryptData(ConversationStore.encodePayload(message));
      await store.executeSql(
        'INSERT INTO private_messages (message_id, conversation_id, message_type, ' +
        'sent_at, received_at, is_relay, is_private, is_encrypted, delivery_type, ' +
        'delivery_at, is_read, payload_ciphertext) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [message.id, normalized, message.type, message.timestamp, now,
          message.isRelay ? 1 : 0, message.isPrivate ? 1 : 0,
          message.isEncrypted ? 1 : 0, message.deliveryStatus,
          ConversationStore.deliveryAtOf(message, now), isRead ? 1 : 0, cipher]);
      inserted = true;
    } else if (isRead) {
      await store.executeSql(
        'UPDATE private_messages SET is_read = 1 WHERE message_id = ? AND is_read = 0',
        [message.id]);
    }
    await store.executeSql('UPDATE conversations SET updated_at = ? WHERE conversation_id = ?',
      [now, normalized]);
    await this.pruneConversation(store, normalized, now);
    this.writesSinceGlobalPrune += 1;
    if (this.writesSinceGlobalPrune >= ConversationStore.PRUNE_INTERVAL) {
      this.writesSinceGlobalPrune = 0;
      await this.doPruneToRetentionLimits();
    }
    return inserted;
  }

  private async ensureConversation(store: relationalStore.RdbStore,
    conversationID: string, now: number): Promise<void> {
    await store.executeSql(
      'INSERT OR IGNORE INTO conversations (conversation_id, created_at, updated_at) ' +
      'VALUES (?, ?, ?)', [conversationID, now, now]);
  }

  // ------------------------------------------------------------------
  // Delivery status and read state
  // ------------------------------------------------------------------

  private async doUpdateDeliveryStatus(messageID: string, status: DeliveryStatusKind,
    detail: string): Promise<void> {
    const store: relationalStore.RdbStore = this.rdb();
    const rs: relationalStore.ResultSet = await store.querySql(
      'SELECT delivery_type, payload_ciphertext FROM private_messages WHERE message_id = ?',
      [messageID]);
    let existingType: number = -1;
    let cipher: Uint8Array | null = null;
    if (rs.goToNextRow()) {
      existingType = rs.getLong(rs.getColumnIndex('delivery_type'));
      cipher = rs.getBlob(rs.getColumnIndex('payload_ciphertext'));
    }
    rs.close();
    if (cipher === null) {
      return;
    }
    const existing: DeliveryStatusKind =
      ConversationStore.deliveryKindFromInt(existingType);
    if (!ConversationStore.mayReplaceStatus(status, existing)) {
      return;
    }
    const payload: StoredMessagePayload = ConversationPayloadCodec.decodeAndVerify(
      await this.secure.decryptData(cipher), messageID);
    payload.deliveryText = detail === '' ? null : detail;
    const newCipher: Uint8Array = await this.secure.encryptData(
      ConversationPayloadCodec.encode(payload));
    const now: number = Date.now();
    if (status === DeliveryStatusKind.DELIVERED || status === DeliveryStatusKind.READ) {
      await store.executeSql(
        'UPDATE private_messages SET delivery_type = ?, delivery_at = ?, ' +
        'payload_ciphertext = ? WHERE message_id = ?',
        [status, now, newCipher, messageID]);
    } else {
      await store.executeSql(
        'UPDATE private_messages SET delivery_type = ?, payload_ciphertext = ? ' +
        'WHERE message_id = ?', [status, newCipher, messageID]);
    }
  }

  private async doMarkRead(messageID: string): Promise<void> {
    const store: relationalStore.RdbStore = this.rdb();
    await store.executeSql(
      'UPDATE private_messages SET is_read = 1 WHERE message_id = ?', [messageID]);
  }

  private async doSetConversationRead(conversationID: string,
    isRead: boolean): Promise<string | null> {
    const store: relationalStore.RdbStore = this.rdb();
    if (isRead) {
      await store.executeSql(
        'UPDATE private_messages SET is_read = 1 WHERE conversation_id = ?',
        [conversationID]);
      return null;
    }
    const rs: relationalStore.ResultSet = await store.querySql(
      'SELECT message_id FROM private_messages WHERE conversation_id = ? ' +
      'ORDER BY arrival_sequence DESC LIMIT 1', [conversationID]);
    let latestMessageID: string | null = null;
    if (rs.goToNextRow()) {
      latestMessageID = rs.getString(rs.getColumnIndex('message_id'));
    }
    rs.close();
    if (latestMessageID !== null) {
      await store.executeSql(
        'UPDATE private_messages SET is_read = 0 WHERE message_id = ?', [latestMessageID]);
    }
    return latestMessageID;
  }

  // ------------------------------------------------------------------
  // Deletion
  // ------------------------------------------------------------------

  private async doDeleteConversation(conversationID: string): Promise<void> {
    const store: relationalStore.RdbStore = this.rdb();
    const now: number = Date.now();
    const rs: relationalStore.ResultSet = await store.querySql(
      'SELECT message_id FROM private_messages WHERE conversation_id = ?', [conversationID]);
    const messageIDs: string[] = [];
    while (rs.goToNextRow()) {
      messageIDs.push(rs.getString(rs.getColumnIndex('message_id')));
    }
    rs.close();
    for (let i = 0; i < messageIDs.length; i++) {
      await this.tombstone(store, messageIDs[i], now);
    }
    await store.executeSql('DELETE FROM private_messages WHERE conversation_id = ?',
      [conversationID]);
    await store.executeSql('DELETE FROM conversations WHERE conversation_id = ?',
      [conversationID]);
    await this.pruneDeletedIDs(store);
  }

  private async doDeleteMessage(messageID: string): Promise<void> {
    const store: relationalStore.RdbStore = this.rdb();
    const now: number = Date.now();
    await this.tombstone(store, messageID, now);
    await store.executeSql('DELETE FROM private_messages WHERE message_id = ?', [messageID]);
    await store.executeSql('DELETE FROM conversations WHERE NOT EXISTS (' +
      'SELECT 1 FROM private_messages ' +
      'WHERE private_messages.conversation_id = conversations.conversation_id)');
    await this.pruneDeletedIDs(store);
  }

  private async tombstone(store: relationalStore.RdbStore, messageID: string,
    deletedAt: number): Promise<void> {
    await store.executeSql(
      'INSERT OR REPLACE INTO deleted_private_messages (message_id, deleted_at) VALUES (?, ?)',
      [messageID, deletedAt]);
  }

  private async pruneDeletedIDs(store: relationalStore.RdbStore): Promise<void> {
    const count: number = await this.longForQuery(store,
      'SELECT COUNT(*) FROM deleted_private_messages', []);
    const excess: number = count - ConversationStore.MAX_MESSAGES_TOTAL;
    if (excess <= 0) {
      return;
    }
    await store.executeSql('DELETE FROM deleted_private_messages WHERE message_id IN (' +
      'SELECT message_id FROM deleted_private_messages ORDER BY deleted_at ASC LIMIT ?)',
      [excess]);
  }

  // ------------------------------------------------------------------
  // Retention
  // ------------------------------------------------------------------

  private async pruneConversation(store: relationalStore.RdbStore,
    conversationID: string, now: number): Promise<void> {
    const count: number = await this.longForQuery(store,
      'SELECT COUNT(*) FROM private_messages WHERE conversation_id = ?', [conversationID]);
    const excess: number = count - ConversationStore.MAX_MESSAGES_PER_CONVERSATION;
    if (excess <= 0) {
      return;
    }
    const rs: relationalStore.ResultSet = await store.querySql(
      'SELECT message_id FROM private_messages WHERE conversation_id = ? ' +
      'AND arrival_sequence < (SELECT MAX(arrival_sequence) FROM private_messages ' +
      'WHERE conversation_id = ?) ORDER BY is_read DESC, arrival_sequence ASC LIMIT ?',
      [conversationID, conversationID, excess]);
    const ids: string[] = [];
    while (rs.goToNextRow()) {
      ids.push(rs.getString(rs.getColumnIndex('message_id')));
    }
    rs.close();
    for (let i = 0; i < ids.length; i++) {
      await this.tombstone(store, ids[i], now);
      await store.executeSql('DELETE FROM private_messages WHERE message_id = ?', [ids[i]]);
    }
    await this.pruneDeletedIDs(store);
  }

  private async doPruneToRetentionLimits(): Promise<void> {
    const store: relationalStore.RdbStore = this.rdb();
    const now: number = Date.now();
    const conversationRS: relationalStore.ResultSet = await store.querySql(
      'SELECT conversation_id FROM conversations');
    const conversationIDs: string[] = [];
    while (conversationRS.goToNextRow()) {
      conversationIDs.push(conversationRS.getString(
        conversationRS.getColumnIndex('conversation_id')));
    }
    conversationRS.close();
    for (let i = 0; i < conversationIDs.length; i++) {
      await this.pruneConversation(store, conversationIDs[i], now);
    }
    while (true) {
      const count: number = await this.longForQuery(store,
        'SELECT COUNT(*) FROM private_messages', []);
      if (count <= ConversationStore.MAX_MESSAGES_TOTAL) {
        break;
      }
      const candidateLimit: number = Math.min(count - ConversationStore.MAX_MESSAGES_TOTAL,
        ConversationStore.PRUNE_BATCH_SIZE);
      const candidates: string[] = await this.pruneCandidates(store, candidateLimit);
      if (candidates.length === 0) {
        break;
      }
      for (let i = 0; i < candidates.length; i++) {
        await this.tombstone(store, candidates[i], now);
        await store.executeSql('DELETE FROM private_messages WHERE message_id = ?',
          [candidates[i]]);
      }
      await store.executeSql('DELETE FROM conversations WHERE NOT EXISTS (' +
        'SELECT 1 FROM private_messages ' +
        'WHERE private_messages.conversation_id = conversations.conversation_id)');
      await this.pruneDeletedIDs(store);
    }
  }

  /**
   * Android's four-step candidate ladder: prefer read messages that are not
   * the newest of their conversation, then any non-newest, then read
   * messages, then anything.
   */
  private async pruneCandidates(store: relationalStore.RdbStore,
    limit: number): Promise<string[]> {
    const queries: string[] = [
      'SELECT message_id FROM private_messages AS candidate ' +
      'WHERE candidate.is_read = 1 AND EXISTS (SELECT 1 FROM private_messages AS newer ' +
      'WHERE newer.conversation_id = candidate.conversation_id ' +
      'AND newer.arrival_sequence > candidate.arrival_sequence) ' +
      'ORDER BY candidate.arrival_sequence ASC LIMIT ?',
      'SELECT message_id FROM private_messages AS candidate ' +
      'WHERE EXISTS (SELECT 1 FROM private_messages AS newer ' +
      'WHERE newer.conversation_id = candidate.conversation_id ' +
      'AND newer.arrival_sequence > candidate.arrival_sequence) ' +
      'ORDER BY candidate.arrival_sequence ASC LIMIT ?',
      'SELECT message_id FROM private_messages AS candidate ' +
      'WHERE candidate.is_read = 1 ORDER BY candidate.arrival_sequence ASC LIMIT ?',
      'SELECT message_id FROM private_messages AS candidate ' +
      'ORDER BY candidate.arrival_sequence ASC LIMIT ?'
    ];
    for (let step = 0; step < queries.length; step++) {
      const rs: relationalStore.ResultSet = await store.querySql(queries[step], [limit]);
      const ids: string[] = [];
      while (rs.goToNextRow()) {
        ids.push(rs.getString(rs.getColumnIndex('message_id')));
      }
      rs.close();
      if (ids.length > 0) {
        return ids;
      }
    }
    return [];
  }

  // ------------------------------------------------------------------
  // Loads
  // ------------------------------------------------------------------

  private async doLoadInitialSnapshot(): Promise<PersistedConversationSnapshot> {
    const store: relationalStore.RdbStore = this.rdb();
    const snapshot: PersistedConversationSnapshot = new PersistedConversationSnapshot();
    const rs: relationalStore.ResultSet = await store.querySql(
      ConversationStore.MESSAGE_SELECT +
      ' WHERE arrival_sequence IN (SELECT MAX(arrival_sequence) ' +
      'FROM private_messages GROUP BY conversation_id) ORDER BY arrival_sequence ASC');
    await this.readRows(rs, snapshot);
    await this.attachTombstones(store, snapshot);
    await this.attachUnreadCounts(store, snapshot);
    return snapshot;
  }

  private async doLoadConversation(conversationID: string): Promise<PersistedConversationSnapshot> {
    const store: relationalStore.RdbStore = this.rdb();
    const snapshot: PersistedConversationSnapshot = new PersistedConversationSnapshot();
    const rs: relationalStore.ResultSet = await store.querySql(
      ConversationStore.MESSAGE_SELECT + ' WHERE conversation_id = ? ' +
      'ORDER BY arrival_sequence ASC', [conversationID]);
    await this.readRows(rs, snapshot);
    await this.attachTombstones(store, snapshot);
    await this.attachUnreadCounts(store, snapshot);
    return snapshot;
  }

  private static readonly MESSAGE_SELECT: string =
    'SELECT message_id, conversation_id, message_type, sent_at, received_at, ' +
    'is_relay, is_private, is_encrypted, delivery_type, is_read, payload_ciphertext ' +
    'FROM private_messages';

  private async readRows(rs: relationalStore.ResultSet,
    snapshot: PersistedConversationSnapshot): Promise<void> {
    const secure: SecureKeyStore = this.secure;
    while (rs.goToNextRow()) {
      const messageID: string = rs.getString(rs.getColumnIndex('message_id'));
      const conversationID: string = rs.getString(rs.getColumnIndex('conversation_id'));
      const cipher: Uint8Array = rs.getBlob(rs.getColumnIndex('payload_ciphertext'));
      const receivedAt: number = rs.getLong(rs.getColumnIndex('received_at'));
      const isRead: boolean = rs.getLong(rs.getColumnIndex('is_read')) !== 0;
      let payload: StoredMessagePayload;
      try {
        payload = ConversationPayloadCodec.decodeAndVerify(
          await secure.decryptData(cipher), messageID);
      } catch (e) {
        // Undecryptable row (wiped key or corruption): skip rather than
        // lose the whole history.
        hilog.warn(DOMAIN, STORE_TAG,
          'skipping unreadable conversation message %{public}s', messageID);
        continue;
      }
      const message: BitchatMessage = ConversationStore.payloadToMessage(rs, payload);
      const list: BitchatMessage[] | undefined =
        snapshot.messagesByConversation.get(conversationID);
      if (list === undefined) {
        snapshot.messagesByConversation.set(conversationID, [message]);
      } else {
        list.push(message);
      }
      snapshot.arrivalOrder.push(messageID);
      snapshot.receivedAtByMessageID.set(messageID, receivedAt);
      if (isRead) {
        snapshot.readMessageIDs.add(messageID);
      }
    }
    rs.close();
  }

  private async attachTombstones(store: relationalStore.RdbStore,
    snapshot: PersistedConversationSnapshot): Promise<void> {
    const rs: relationalStore.ResultSet = await store.querySql(
      'SELECT message_id FROM deleted_private_messages ORDER BY deleted_at ASC');
    while (rs.goToNextRow()) {
      snapshot.deletedMessageIDs.add(rs.getString(rs.getColumnIndex('message_id')));
    }
    rs.close();
  }

  private async attachUnreadCounts(store: relationalStore.RdbStore,
    snapshot: PersistedConversationSnapshot): Promise<void> {
    const rs: relationalStore.ResultSet = await store.querySql(
      'SELECT conversation_id, COUNT(*) FROM private_messages ' +
      'WHERE is_read = 0 GROUP BY conversation_id');
    while (rs.goToNextRow()) {
      const conversationID: string = rs.getString(rs.getColumnIndex('conversation_id'));
      if (!snapshot.unreadCounts.has(conversationID)) {
        snapshot.unreadCounts.set(conversationID, rs.getLong(1));
      }
    }
    rs.close();
  }

  // ------------------------------------------------------------------
  // Panic
  // ------------------------------------------------------------------

  private async doDropAll(): Promise<boolean> {
    const store: relationalStore.RdbStore = this.rdb();
    try {
      await store.executeSql('DELETE FROM private_messages');
      await store.executeSql('DELETE FROM conversations');
      await store.executeSql('DELETE FROM deleted_private_messages');
      await store.executeSql("DELETE FROM sqlite_sequence WHERE name = 'private_messages'");
      this.writesSinceGlobalPrune = 0;
      hilog.warn(DOMAIN, STORE_TAG, '%{public}s', 'conversation store wiped');
      return true;
    } catch (e) {
      hilog.error(DOMAIN, STORE_TAG,
        'dropAll failed, destroying database file: %{public}s', `${e}`);
      await this.destroyStorage();
      return false;
    }
  }

  /** Last-resort panic cleanup: close and delete the database file. */
  private async destroyStorage(): Promise<void> {
    try {
      await this.rdb().close();
    } catch (e) {
      // Already closed or broken - the file deletion below still runs.
    }
    this.store = null;
    this.initPromise = null;
    const context: common.Context | null = this.context;
    if (context !== null) {
      try {
        await relationalStore.deleteRdbStore(context, DATABASE_NAME);
      } catch (e) {
        hilog.error(DOMAIN, STORE_TAG, 'deleteRdbStore failed: %{public}s', `${e}`);
      }
    }
  }

  // ------------------------------------------------------------------
  // Payload <-> model mapping
  // ------------------------------------------------------------------

  private static encodePayload(message: BitchatMessage): Uint8Array {
    const payload: StoredMessagePayload = new StoredMessagePayload();
    payload.messageID = message.id;
    payload.sender = message.sender;
    payload.content = message.content;
    payload.originalSender = message.originalSender;
    payload.recipientNickname = message.recipientNickname;
    payload.senderPeerId = message.senderPeerId;
    payload.mentions = message.mentions === null ? null : message.mentions.slice(0);
    payload.channel = message.channel;
    payload.encryptedContent =
      message.encryptedContent === null ? null : message.encryptedContent.slice(0);
    payload.deliveryText = message.deliveryStatusDetail === '' ?
      null : message.deliveryStatusDetail;
    payload.senderNostrPubkey = message.senderNostrPubkey;
    payload.transferId = message.transferId;
    payload.notEndToEndEncrypted = message.notEndToEndEncrypted;
    return ConversationPayloadCodec.encode(payload);
  }

  private static payloadToMessage(rs: relationalStore.ResultSet,
    payload: StoredMessagePayload): BitchatMessage {
    const sentAt: number = rs.getLong(rs.getColumnIndex('sent_at'));
    const message: BitchatMessage = new BitchatMessage(payload.sender, payload.content, sentAt);
    message.id = payload.messageID;
    message.type = ConversationStore.typeFromInt(rs.getLong(
      rs.getColumnIndex('message_type')));
    message.isRelay = rs.getLong(rs.getColumnIndex('is_relay')) !== 0;
    message.originalSender = payload.originalSender;
    message.isPrivate = rs.getLong(rs.getColumnIndex('is_private')) !== 0;
    message.recipientNickname = payload.recipientNickname;
    message.senderPeerId = payload.senderPeerId;
    message.mentions = payload.mentions === null ? null : payload.mentions.slice(0);
    message.channel = payload.channel;
    message.encryptedContent =
      payload.encryptedContent === null ? null : payload.encryptedContent.slice(0);
    message.isEncrypted = rs.getLong(rs.getColumnIndex('is_encrypted')) !== 0;
    message.deliveryStatus = ConversationStore.deliveryKindFromInt(rs.getLong(
      rs.getColumnIndex('delivery_type')));
    message.deliveryStatusDetail = payload.deliveryText === null ? '' : payload.deliveryText;
    message.senderNostrPubkey = payload.senderNostrPubkey;
    message.transferId = payload.transferId;
    message.notEndToEndEncrypted = payload.notEndToEndEncrypted;
    return message;
  }

  // ------------------------------------------------------------------
  // Delivery-status ladder (Android statusPriority/mayReplace)
  // ------------------------------------------------------------------

  private static priorityOf(status: DeliveryStatusKind): number {
    if (status === DeliveryStatusKind.FAILED) {
      return 0;
    }
    if (status === DeliveryStatusKind.SENDING) {
      return 1;
    }
    if (status === DeliveryStatusKind.SENT) {
      return 2;
    }
    if (status === DeliveryStatusKind.PARTIALLY_DELIVERED) {
      return 3;
    }
    if (status === DeliveryStatusKind.DELIVERED) {
      return 4;
    }
    return 5;
  }

  private static mayReplaceStatus(next: DeliveryStatusKind,
    existing: DeliveryStatusKind): boolean {
    if (next === DeliveryStatusKind.FAILED) {
      return existing !== DeliveryStatusKind.DELIVERED &&
        existing !== DeliveryStatusKind.READ;
    }
    if (existing === DeliveryStatusKind.FAILED) {
      return true;
    }
    return ConversationStore.priorityOf(next) >= ConversationStore.priorityOf(existing);
  }

  private static deliveryAtOf(message: BitchatMessage, now: number): number | null {
    if (message.deliveryStatus === DeliveryStatusKind.DELIVERED ||
      message.deliveryStatus === DeliveryStatusKind.READ) {
      return now;
    }
    return null;
  }

  /** Map a stored integer back to a message type, defaulting like Android's getOrElse. */
  private static typeFromInt(value: number): BitchatMessageType {
    if (value === BitchatMessageType.AUDIO) {
      return BitchatMessageType.AUDIO;
    }
    if (value === BitchatMessageType.IMAGE) {
      return BitchatMessageType.IMAGE;
    }
    if (value === BitchatMessageType.FILE) {
      return BitchatMessageType.FILE;
    }
    return BitchatMessageType.MESSAGE;
  }

  /** Map a stored delivery type back to its kind (unknown values fall back to SENDING). */
  private static deliveryKindFromInt(value: number): DeliveryStatusKind {
    if (value === DeliveryStatusKind.SENDING) {
      return DeliveryStatusKind.SENDING;
    }
    if (value === DeliveryStatusKind.SENT) {
      return DeliveryStatusKind.SENT;
    }
    if (value === DeliveryStatusKind.DELIVERED) {
      return DeliveryStatusKind.DELIVERED;
    }
    if (value === DeliveryStatusKind.READ) {
      return DeliveryStatusKind.READ;
    }
    if (value === DeliveryStatusKind.FAILED) {
      return DeliveryStatusKind.FAILED;
    }
    if (value === DeliveryStatusKind.PARTIALLY_DELIVERED) {
      return DeliveryStatusKind.PARTIALLY_DELIVERED;
    }
    return DeliveryStatusKind.SENDING;
  }

  // ------------------------------------------------------------------
  // Small query helpers
  // ------------------------------------------------------------------

  private async isTombstoned(store: relationalStore.RdbStore,
    messageID: string): Promise<boolean> {
    return await this.longForQuery(store,
      'SELECT COUNT(*) FROM deleted_private_messages WHERE message_id = ?',
      [messageID]) > 0;
  }

  private async messageExists(store: relationalStore.RdbStore,
    messageID: string): Promise<boolean> {
    return await this.longForQuery(store,
      'SELECT COUNT(*) FROM private_messages WHERE message_id = ?', [messageID]) > 0;
  }

  private async longForQuery(store: relationalStore.RdbStore, sql: string,
    bindArgs: Array<relationalStore.ValueType>): Promise<number> {
    const rs: relationalStore.ResultSet = await store.querySql(sql, bindArgs);
    let value: number = 0;
    if (rs.goToNextRow()) {
      value = rs.getLong(0);
    }
    rs.close();
    return value;
  }
}
