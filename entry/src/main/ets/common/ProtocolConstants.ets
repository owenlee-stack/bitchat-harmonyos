/**
 * Centralized protocol constants - mirrors bitchat-android AppConstants.kt.
 * Values are wire-visible and must not drift from the Android/iOS clients.
 */
export class PkTtl {
  static readonly MESSAGE_TTL_HOPS: number = 7;
  static readonly SYNC_TTL_HOPS: number = 0;
}

export class MeshConstants {
  static readonly STALE_PEER_TIMEOUT_MS: number = 180000;
  static readonly PEER_CLEANUP_INTERVAL_MS: number = 60000;
  static readonly PEER_DISCONNECT_GRACE_MS: number = 10000;
  static readonly PEER_REACHABLE_WINDOW_MS: number = 60000;

  static readonly CONNECTION_RETRY_DELAY_MS: number = 5000;
  static readonly MAX_CONNECTION_ATTEMPTS: number = 3;
  static readonly CONNECTION_CLEANUP_DELAY_MS: number = 500;
  static readonly CONNECTION_CLEANUP_INTERVAL_MS: number = 30000;
  static readonly BROADCAST_CLEANUP_DELAY_MS: number = 500;
  static readonly MAX_CONNECTIONS: number = 8;
}

/** Ingress admission bounds - mirrors bitchat-android PacketProcessor.kt. */
export class ProcessorConstants {
  /** Logical worker slots; a peer always hashes to the same slot. */
  static readonly WORKER_COUNT: number = 16;
  /** Per-slot FIFO capacity; the newest packet is dropped when full. */
  static readonly QUEUE_CAPACITY: number = 64;
  /** Global pending payload budget across all slots. */
  static readonly MAX_PENDING_PAYLOAD_BYTES: number = 8 * 1024 * 1024;
}

export class GattConstants {
  static readonly SERVICE_UUID: string = 'F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C';
  static readonly CHARACTERISTIC_UUID: string = 'A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D';
  static readonly DESCRIPTOR_UUID: string = '00002902-0000-1000-8000-00805f9b34fb';
}

export class FragmentationConstants {
  static readonly FRAGMENT_SIZE_THRESHOLD: number = 512;
  static readonly MAX_FRAGMENT_SIZE: number = 469;
  static readonly FRAGMENT_TIMEOUT_MS: number = 30000;
  static readonly CLEANUP_INTERVAL_MS: number = 10000;
  static readonly MAX_FRAGMENTS_PER_ID: number = 256;
  static readonly MAX_FRAGMENT_TOTAL_BYTES: number = 1048576;
  static readonly MAX_ACTIVE_FRAGMENT_SETS: number = 64;
  static readonly MAX_GLOBAL_FRAGMENT_TOTAL_BYTES: number = 4 * 1048576;
  static readonly FRAGMENT_HEADER_SIZE: number = 13;
}

export class SecurityConstants {
  static readonly MESSAGE_TIMEOUT_MS: number = 300000;
  static readonly CLEANUP_INTERVAL_MS: number = 300000;
  static readonly MAX_PROCESSED_MESSAGES: number = 10000;
  static readonly MAX_PROCESSED_KEY_EXCHANGES: number = 1000;
  static readonly KEY_EXCHANGE_DEDUP_TIMEOUT_MS: number = 60000;
  static readonly ANNOUNCE_MAX_CLOCK_SKEW_MS: number = 10 * 60 * 1000;
}

export class NoiseConstants {
  static readonly REKEY_TIME_LIMIT_MS: number = 3600000;
  static readonly REKEY_MESSAGE_LIMIT_ENCRYPTION: number = 1000;
  static readonly REKEY_MESSAGE_LIMIT_SESSION: number = 10000;
  static readonly MAX_PAYLOAD_SIZE_BYTES: number = 256;
  static readonly HIGH_NONCE_WARNING_THRESHOLD: number = 1000000000;
  static readonly REPLAY_WINDOW_BITS: number = 1024;
}

export class WireConstants {
  static readonly COMPRESSION_THRESHOLD_BYTES: number = 100;
  static readonly MAX_PAYLOAD_LENGTH: number = 10485760;
  static readonly HEADER_SIZE_V1: number = 14;
  static readonly HEADER_SIZE_V2: number = 16;
  static readonly SENDER_ID_SIZE: number = 8;
  static readonly RECIPIENT_ID_SIZE: number = 8;
  static readonly SIGNATURE_SIZE: number = 64;
  static readonly MAX_DEFLATE_RATIO: number = 1032;
}

export class StoreForwardConstants {
  static readonly MESSAGE_CACHE_TIMEOUT_MS: number = 43200000;
  static readonly MAX_CACHED_MESSAGES: number = 100;
  static readonly MAX_CACHED_MESSAGES_FAVORITES: number = 1000;
  static readonly CLEANUP_INTERVAL_MS: number = 600000;
  /** Delay between cached messages replayed to a peer that just came online. */
  static readonly REPLAY_INTERVAL_MS: number = 10;
}

/** Courier sealed-mail system (whitepaper §6.2, spec FR-034, plan D11). */
export class CourierConstants {
  /** iOS wire type for a courier envelope packet (PACKET_PAYLOAD_LIMITS 0x04). */
  static readonly ENVELOPE_WIRE_TYPE: number = 0x04;
  /** Sealed-envelope ciphertext bound (16 KiB, FR-034). */
  static readonly ENVELOPE_MAX_BYTES: number = 16384;
  /** Envelope lifetime (24h). */
  static readonly ENVELOPE_TTL_MS: number = 86400000;
  /** Rotation recipient tag size in bytes. */
  static readonly RECIPIENT_TAG_SIZE: number = 16;
  /** Initial spray-and-wait copy budget. */
  static readonly COPY_BUDGET_INITIAL: number = 4;
  /** Maximum copy budget an envelope may carry. */
  static readonly COPY_BUDGET_MAX: number = 8;
  /** Envelope-pool slot count. */
  static readonly POOL_SLOTS: number = 40;
  /** Usable pool slots before eviction starts. */
  static readonly POOL_USABLE_SLOTS: number = 20;
  /** Per-depositor trust quota for mutual favorites. */
  static readonly QUOTA_MUTUAL_FAVORITE: number = 5;
  /** Per-depositor trust quota for a verified announce. */
  static readonly QUOTA_VERIFIED: number = 2;
  /** Retry deposits until this many couriers carry the mail. */
  static readonly DEPOSIT_COURIER_TARGET: number = 3;
  /** Directed-flood duplicate throttle for relayed announces, per envelope. */
  static readonly RELAYED_ANNOUNCE_THROTTLE_MS: number = 600000;
  /** UTC day length for recipient-tag rotation. */
  static readonly UTC_DAY_MS: number = 86400000;
}

export class SyncConstants {
  static readonly DEFAULT_FILTER_BYTES: number = 256;
  /** Percent; divide by 100 for the GCS target false-positive rate. */
  static readonly DEFAULT_FPR_PERCENT: number = 1.0;
  static readonly MAX_ACCEPT_FILTER_BYTES: number = 1024;
  static readonly SYNC_PERIOD_MS: number = 15000;
  static readonly HISTORY_WINDOW_MS: number = 6 * 3600 * 1000;
  static readonly CACHE_CAPACITY: number = 1000;
  /** New-peer triggered initial sync delay (Android scheduleInitialSync). */
  static readonly INITIAL_SYNC_DELAY_MS: number = 5000;
}

export class NostrConstants {
  static readonly INITIAL_BACKOFF_INTERVAL_MS: number = 1000;
  static readonly MAX_BACKOFF_INTERVAL_MS: number = 300000;
  static readonly BACKOFF_MULTIPLIER: number = 2.0;
  static readonly MAX_RECONNECT_ATTEMPTS: number = 10;
  static readonly READ_ACK_INTERVAL_MS: number = 350;
  static readonly DEFAULT_DEDUP_CAPACITY: number = 10000;
  static readonly SUBSCRIPTION_VALIDATION_INTERVAL_MS: number = 30000;
}

export class TorConstants {
  static readonly DEFAULT_SOCKS_PORT: number = 9060;
}

export class UiConstants {
  static readonly MAX_NICKNAME_LENGTH: number = 15;
  static readonly MESSAGE_DEDUP_TIMEOUT_MS: number = 30000;
  static readonly SYSTEM_EVENT_DEDUP_TIMEOUT_MS: number = 5000;
}

export class MediaConstants {
  static readonly MAX_FILE_SIZE_BYTES: number = 10 * 1024 * 1024 - 132 * 1024;
  static readonly MAX_FILE_TRANSFER_FRAGMENTS: number = 256;
}

export class RouterConstants {
  static readonly OUTBOX_TICK_MS: number = 2000;
  static readonly OUTBOX_MESSAGE_TTL_MS: number = 86400000;
  static readonly OUTBOX_MAX_PER_PEER: number = 100;
  static readonly HANDSHAKE_RETRY_BACKOFF_MS: number[] = [5000, 15000, 30000, 60000];
}

export class ServicesConstants {
  static readonly SEEN_MESSAGE_MAX_IDS: number = 10000;
}

export class RelayConstants {
  static readonly JITTER_MIN_MS: number = 10;
  static readonly JITTER_MAX_MS: number = 220;
  static readonly DENSE_LINK_THRESHOLD: number = 6;
  static readonly DENSE_TTL_CAP: number = 5;
  /** At or below this link count relays forward at full remaining depth. */
  static readonly THIN_LINK_THRESHOLD: number = 2;
  /** Dense graphs widen the jitter span by this factor (FR-004: wider when dense). */
  static readonly DENSE_JITTER_MULTIPLIER: number = 2.0;
}

export class TopologyConstants {
  /** Announce-claimed edges stay routable for at most this long (FR-033). */
  static readonly EDGE_FRESHNESS_MS: number = 60000;
  /** Maximum source-route length in peer-ID hops (v2 wire limit: 1-byte count). */
  static readonly MAX_ROUTE_HOPS: number = 255;
}
