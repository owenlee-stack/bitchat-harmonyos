/**
 * Chat view model and mesh composition root (US3, T030).
 *
 * plan.md D8: services emit, the UI layer subscribes. This class wires the
 * full US3 pipeline once per process and publishes one @ObservedV2
 * ChatState to the views:
 *
 *  - ingress: BleMeshService (transport) hands decoded packets raw to the
 *    RoutedPacket pipeline (peerID = original packet sender, matching the
 *    GATT-layer derivation and the Android BluetoothMeshService wiring);
 *    PacketProcessor worker slots (D4) run SecurityGate validation and the
 *    per-type handlers:
 *      ANNOUNCE -> PeerManager table + TopologyMap claim (TLV 0x04) +
 *                  gossip cache; a new peer triggers a directed initial
 *                  sync (FR-009),
 *      MESSAGE  -> spam admission (T038 SpamFilter, hidden floods get no
 *                  timeline row) then public timeline + gossip cache,
 *      REQUEST_SYNC -> GossipSyncManager.handleRequestSync,
 *      LEAVE    -> peer eviction + topology/gossip cleanup,
 *    then liveness update + PacketRelay.considereRelay (TTL clamp, split
 *    horizon, subset fan-out - FR-004).
 *  - egress: sendPublicMessage builds the BitchatMessage wire payload,
 *    signs the canonical packet with the persistent Ed25519 key and
 *    broadcasts it with full TTL; AnnounceScheduler keeps presence alive
 *    (FR-008); GossipSyncManager runs the ~15s reconciliation loop
 *    (FR-009).
 *
 * The SecurityGate verifier rides IdentityManager.verifySync (cryptoFramework
 * sync series) so the synchronous pipeline never blocks the UI thread on a
 * Promise. REQUEST_SYNC stays unsigned on the wire, matching the signed-set
 * definition in SecurityGate.
 *
 * Private chat (T036): NOISE_HANDSHAKE / NOISE_ENCRYPTED dispatch feeds the
 * NoiseSessionManager (XX, peer-ID bound) and the MessageRouter (direct mesh
 * send with an Outbox fallback); PRIVATE_MESSAGE payloads persist through
 * the ConversationStore and publish into the @Trace private-chat state,
 * DELIVERED acks and READ_RECEIPTs advance the outgoing status ladder, and
 * incoming messages are acknowledged per the iOS wire format.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BcEvents, EventBus, PeerRemovedPayload, PeerUpdatedPayload } from '../common/EventBus';
import { ByteUtils } from '../common/ByteUtils';
import { FragmentationConstants, PkTtl, SecurityConstants, SyncConstants } from '../common/ProtocolConstants';
import { BitchatMessage, BitchatMessageType, DeliveryStatusKind } from '../model/BitchatMessage';
import { BitchatPacket, MessageType, messageTypeFromValue,
  specialRecipientBroadcast } from '../model/BitchatPacket';
import { BitchatFilePacket } from '../model/FragmentModels';
import { AuthenticatedPeerState, IdentityAnnouncement, NoisePayload, NoisePayloadType,
  PeerCapabilities, PrivateMessagePacket } from '../model/IdentityModels';
import { RequestSyncPacket } from '../model/RequestSyncPacket';
import { AnnounceScheduler, AnnounceSchedulerDelegate } from '../service/mesh/AnnounceScheduler';
import { BleMeshService } from '../service/mesh/BleMeshService';
import { FragmentManager } from '../service/mesh/FragmentManager';
import { GossipTlv } from '../service/mesh/GossipTlv';
import { PacketProcessor, PacketProcessorDelegate, RoutedPacket } from '../service/mesh/PacketProcessor';
import { PacketRelay, PacketRelayDelegate } from '../service/mesh/PacketRelay';
import { PeerInfo, PeerManager, PeerManagerDelegate } from '../service/mesh/PeerManager';
import { SecurityGate } from '../service/mesh/SecurityGate';
import { SpamFilter } from '../service/mesh/SpamFilter';
import { TopologyMap } from '../service/mesh/TopologyMap';
import { TransportDelegate } from '../service/mesh/Transport';
import { NoiseSessionManager, NoiseHandshakeProcessingResult,
  AuthenticatedNoiseSession, NoiseDecryptionResult } from '../service/noise/NoiseSessionManager';
import { FinishedLiveBurst, LiveVoiceManager, LiveVoiceUiListener } from '../service/livevoice/LiveVoiceManager';
import { LiveVoiceScope } from '../service/livevoice/LiveVoiceAssembler';
import { PeerStateManager, PeerStateStatus } from '../service/mesh/PeerStateManager';
import {
  BuiltPrivateMediaTransfer,
  LegacyPrivateMediaConsentRequest,
  PreparedPrivateMediaTransfer,
  PrivateMediaEncryptionResult,
  PrivateMediaPolicyDecision,
  PrivateMediaPreparation,
  PrivateMediaSendIntent,
  PrivateMediaSendIntentManager,
  PrivateMediaSecurityController,
  PrivateMediaTransferPreparer,
  PrivateMediaWireMode,
  TransferProgressEvent,
  TransferProgressManager,
} from '../service/media/MediaTransferManager';
import { VoiceNotePlaybackListener, VoiceNotePlayer } from '../service/media/VoiceNotePlayer';
import { VoiceNoteRecorder } from '../service/media/VoiceNoteRecorder';
import {
  normalizeAmplitudeSample,
  parseMulawWavWaveform,
  resampleWave,
  VOICE_NOTE_SAMPLE_RATE,
  WAVEFORM_BINS,
} from '../service/media/VoiceNoteWaveform';
import { MessageRouter, MessageRouterDelegate, RouteResult } from '../service/routing/MessageRouter';
import { Outbox } from '../service/routing/Outbox';
import { GossipSyncConfig, GossipSyncDelegate, GossipSyncManager } from '../service/sync/GossipSyncManager';
import { PacketIdUtil } from '../service/sync/PacketIdUtil';
import { BinaryProtocol } from '../service/protocol/BinaryProtocol';
import { IdentityManager, PanicWipeDelegate, PanicWipeResult } from '../service/identity/IdentityManager';
import { BackgroundTaskCoordinator } from '../entryability/BackgroundTaskCoordinator';
import { MessageNotificationDispatcher } from '../common/MessageNotificationDispatcher';
import { ChannelEncryption } from '../service/noise/ChannelEncryption';
import { ChannelJoinResult, ChannelManager } from '../service/mesh/ChannelManager';
import { ConversationStore, PersistedConversationSnapshot } from '../data/ConversationStore';
import { PreferenceStore } from '../data/PreferenceStore';
import { MediaFileStore } from '../data/MediaFileStore';
import { PeerStatePinStore } from '../data/PeerStatePinStore';
import { FavoritesChangeListener, FavoritesStore } from '../data/FavoritesStore';
import { FavoriteControlMessage, FavoriteRelationship } from '../model/FavoriteModels';
import { ContactIdentityResolver } from '../service/identity/ContactIdentityResolver';
import { NostrEmbeddedBitChat, EmbeddedBitChatMessage } from '../service/nostr/NostrEmbeddedBitChat';
import { NostrEvent, NostrKind } from '../service/nostr/NostrEvent';
import { GeohashChannelLevel, GeohashLevels, GeohashPowSettings,
  GeohashService } from '../service/nostr/GeohashService';
import { GeohashBookmarkToggle, GeohashChannels,
  GeohashEventRouter } from '../service/nostr/GeohashChannels';
import { GeohashBookmarksStore } from '../data/GeohashBookmarksStore';
import { SecureKeyStore } from '../data/SecureKeyStore';
import { NostrFilter } from '../service/nostr/NostrFilter';
import { NostrIdentity } from '../service/nostr/NostrIdentity';
import { NostrProtocol, DecryptedPrivateMessage } from '../service/nostr/NostrProtocol';
import { NostrRelayManager } from '../service/nostr/NostrRelayManager';
import { NostrTransport } from '../service/nostr/NostrTransport';
import { NostrRandomSource } from '../service/nostr/NostrRandomSource';
import { NostrIdentityStore, DeviceNostrRandomSource } from '../data/NostrIdentityStore';
import { SignatureVerifier, VerificationQR, VerificationService, VerificationSigner,
  NonceFactory, VerifyChallenge, VerifyResponse,
  VERIFY_NONCE_LENGTH } from '../service/identity/VerificationService';
import { ChatEntry, ChatState, LegacyConsentPrompt, LiveVoiceIncomingState,
  MediaTransferProgress, PrivateConversationSummary, PrivateMessageEntry,
  VoicePlaybackState } from './ChatState';
import { CommandProcessor, CommandProcessorDelegate, CommandSuggestion } from './CommandProcessor';

const DOMAIN = 0x0000;
const TAG = 'ChatViewModel';

/** Timeline retention (entries); mirrors the sync cache bound. */
const TIMELINE_CAPACITY = 1000;

/** Per-channel timeline retention (entries); Android MAX_RETAINED parity. */
const CHANNEL_TIMELINE_CAPACITY = 1000;

/** Row shown when a password-channel message fails to decrypt (T049). */
const CHANNEL_ENCRYPTED_PLACEHOLDER = '[encrypted message]';

/** Consecutive decrypt failures before the Noise session resets (Android parity). */
const MAX_CONSECUTIVE_DECRYPT_FAILURES = 3;

/** Character class that extends a mention word past the nickname (T046). */
const MENTION_BOUNDARY_REGEX = /[A-Za-z0-9_]/;

/** PrivateMessagePacket TLV uses 1-byte lengths: content caps at 255 bytes. */
const PRIVATE_CONTENT_MAX_BYTES = 255;

/** Voice-note cap (T054): auto-stop the capture after 10 s (Android parity). */
const VOICE_NOTE_MAX_MS = 10000;

/** Recording visualizer poll (T054); Android 80 ms amplitude-poll parity. */
const VOICE_NOTE_POLL_MS = 80;

/** Live bars of the recording strip (T054). */
const VOICE_RECORDING_STRIP_BARS = 32;

/** Live-voice incoming strip bars (US14, T070). */
const LIVE_VOICE_STRIP_BARS = 48;

/** Live-voice incoming amplitude history cap (US14, T070; Android 240 bars). */
const LIVE_VOICE_HISTORY_CAP = 240;

/** Panic-wipe outcome notices (Android R.string parity, T043). */
const PANIC_COMPLETED_NOTICE = 'all data wiped — new identity created';
const PANIC_INCOMPLETE_NOTICE =
  'wipe incomplete — some data may remain. triple-tap the logo to try again.';

/** PreferenceStore key of the persisted verified-fingerprint JSON array (US11). */
const VERIFIED_FINGERPRINTS_KEY = 'verified_fingerprints';

/** NIP-17 gift-wrap subscription id for account DMs (US12, T060). */
const NOSTR_DM_SUBSCRIPTION_ID = 'bitchat-dm-giftwraps';

/** Inbound gift-wrap age bound: 48h + 15min (Android parity, US12). */
const NOSTR_GIFT_WRAP_MAX_AGE_SECONDS = 173700;

/** Inbound gift-wrap lookback of the DM subscription: 48h (US12). */
const NOSTR_SUBSCRIPTION_LOOKBACK_MS = 48 * 60 * 60 * 1000;

/** Seen gift-wrap event-ID LRU capacity (Android parity 2000, US12). */
const NOSTR_SEEN_EVENT_LRU = 2000;

/** Geohash location-channel relay subscription id prefix (US13, T068). */
const GEOHASH_SUBSCRIPTION_PREFIX = 'bitchat-geohash-';
/** Asset alias of the persistent geohash device seed (US13, T068). */
const GEOHASH_DEVICE_SEED_ALIAS = 'geohash_device_seed_v1';
/** Geohash device seed length in bytes (Android NostrIdentity 32B). */
const GEOHASH_DEVICE_SEED_BYTES = 32;
/** Seen inbound geohash event ids, insertion-ordered LRU (US13). */
const GEOHASH_SEEN_EVENT_LRU = 1000;
/** Per-channel geohash timeline capacity (US13). */
const GEOHASH_TIMELINE_CAPACITY = 500;

/** Ed25519 + Noise identity exposed to the pure VerificationService (US11). */
class IdentityVerificationSigner implements VerificationSigner {
  getStaticPublicKey(): Uint8Array {
    return IdentityManager.getInstance().getStaticPublicKey();
  }

  getSigningPublicKey(): Uint8Array {
    return IdentityManager.getInstance().getSigningPublicKey();
  }

  sign(data: Uint8Array): Uint8Array | null {
    return IdentityManager.getInstance().signSync(data);
  }
}

/** One in-flight QR verification on the scanner side (US11). */
class PendingVerification {
  readonly noiseKeyHex: string;
  readonly signKeyHex: string;
  readonly npub: string | null;
  readonly nonceA: Uint8Array;

  constructor(noiseKeyHex: string, signKeyHex: string, npub: string | null,
    nonceA: Uint8Array) {
    this.noiseKeyHex = noiseKeyHex;
    this.signKeyHex = signKeyHex;
    this.npub = npub;
    this.nonceA = new Uint8Array(nonceA);
  }
}

/** Fully wired service graph; built once identity is available. */
class MeshGraph {
  readonly myPeerId: string;
  readonly transport: BleMeshService;
  readonly securityGate: SecurityGate;
  readonly receiveFragments: FragmentManager;
  readonly peerManager: PeerManager;
  readonly topologyMap: TopologyMap;
  readonly packetProcessor: PacketProcessor;
  readonly packetRelay: PacketRelay;
  readonly gossipSync: GossipSyncManager;
  readonly announceScheduler: AnnounceScheduler;
  readonly noiseSessions: NoiseSessionManager;
  readonly outbox: Outbox;
  readonly messageRouter: MessageRouter;
  readonly peerStateManager: PeerStateManager;
  readonly mediaSecurity: PrivateMediaSecurityController;
  readonly mediaPreparer: PrivateMediaTransferPreparer;
  readonly mediaIntents: PrivateMediaSendIntentManager;
  readonly mediaProgress: TransferProgressManager;

  constructor(myPeerId: string, transport: BleMeshService, securityGate: SecurityGate,
    receiveFragments: FragmentManager, peerManager: PeerManager, topologyMap: TopologyMap,
    packetProcessor: PacketProcessor, packetRelay: PacketRelay, gossipSync: GossipSyncManager,
    announceScheduler: AnnounceScheduler, noiseSessions: NoiseSessionManager,
    outbox: Outbox, messageRouter: MessageRouter, peerStateManager: PeerStateManager,
    mediaSecurity: PrivateMediaSecurityController,
    mediaPreparer: PrivateMediaTransferPreparer,
    mediaIntents: PrivateMediaSendIntentManager,
    mediaProgress: TransferProgressManager) {
    this.myPeerId = myPeerId;
    this.transport = transport;
    this.securityGate = securityGate;
    this.receiveFragments = receiveFragments;
    this.peerManager = peerManager;
    this.topologyMap = topologyMap;
    this.packetProcessor = packetProcessor;
    this.packetRelay = packetRelay;
    this.gossipSync = gossipSync;
    this.announceScheduler = announceScheduler;
    this.noiseSessions = noiseSessions;
    this.outbox = outbox;
    this.messageRouter = messageRouter;
    this.peerStateManager = peerStateManager;
    this.mediaSecurity = mediaSecurity;
    this.mediaPreparer = mediaPreparer;
    this.mediaIntents = mediaIntents;
    this.mediaProgress = mediaProgress;
  }
}

export class ChatViewModel implements TransportDelegate, PacketProcessorDelegate,
  GossipSyncDelegate, GossipSyncConfig, AnnounceSchedulerDelegate, PeerManagerDelegate,
  PacketRelayDelegate, MessageRouterDelegate, CommandProcessorDelegate, PanicWipeDelegate,
  VoiceNotePlaybackListener, FavoritesChangeListener, LiveVoiceUiListener {
  private static instance: ChatViewModel | null = null;
  /** Ed25519/Noise identity adapter for the pure VerificationService (US11). */
  private static readonly identitySigner: IdentityVerificationSigner =
    new IdentityVerificationSigner();

  readonly state: ChatState = new ChatState();

  private graph: MeshGraph | null = null;
  private startPromise: Promise<void> | null = null;
  private nickname: string = '';
  private timelineIds: Set<string> = new Set();
  /** Packet-ID dedup sets per '#tag' channel (T049). */
  private channelTimelineIds: Map<string, Set<string>> = new Map<string, Set<string>>();
  private securityCleanupTimer: number = -1;
  private fragmentCleanupTimer: number = -1;
  /** Display names per conversation, keyed by the canonical conversation ID. */
  private conversationDisplayNames: Map<string, string> = new Map();
  /** Alias keys (Noise static key hex, later npub) -> canonical conversation ID. */
  private noiseKeyAliasToConversation: Map<string, string> = new Map();
  /** Ed25519 keys proven by an authenticated 0x21 peer state, by peer ID. */
  private authenticatedSigningKeys: Map<string, Uint8Array> = new Map();
  /** Incoming message IDs a READ_RECEIPT was already sent for. */
  private sentReadReceipts: Set<string> = new Set();
  private consecutiveDecryptFailures: Map<string, number> = new Map();
  /** IRC command kernel (T039); this view model is its delegate. */
  private readonly commandProcessor: CommandProcessor = new CommandProcessor(this);
  /** Peers blocked via /block (peer-ID level until identity fingerprints). */
  private readonly blockedPeerIds: Set<string> = new Set();
  /** Channel registry: join/membership/password gating (T048, US9). */
  private readonly channelManager: ChannelManager =
    new ChannelManager(ChannelEncryption.getInstance());
  /** Voice-note recorder (T054); one capture at a time. */
  private readonly voiceRecorder: VoiceNoteRecorder = new VoiceNoteRecorder();
  /** Shared voice-note player (T054); one note plays at a time. */
  private readonly voicePlayer: VoiceNotePlayer = new VoiceNotePlayer();
  /** 80 ms recording state poll timer (T054). */
  private voiceRecordingTimer: number = -1;
  /** Normalized amplitude history of the running capture (T054). */
  private recordingAmplitudeHistory: number[] = [];
  /** Burst key of the incoming live voice mirrored into the state (T070). */
  private liveVoiceUiKey: string = '';
  /** Normalized amplitude history of the tracked incoming burst (T070). */
  private liveVoiceAmplitudeHistory: number[] = [];
  /** Parsed waveform per note path (T054; empty for undecodable notes). */
  private voiceWaveformCache: Map<string, number[]> = new Map();
  /** Reentry guard: a second panic trigger while one wipe runs is ignored. */
  private panicWipeInProgress: boolean = false;
  /** True while the public-chat tab is the visible home tab (T046). */
  private publicChatActive: boolean = false;
  /** In-flight QR verifications on the scanner side, by peer ID (US11). */
  private pendingVerifications: Map<string, PendingVerification> =
    new Map<string, PendingVerification>();
  /** Scanned QRs waiting for the Noise session, by peer ID (US11). */
  private pendingQrIntents: Map<string, VerificationQR> =
    new Map<string, VerificationQR>();
  /** Nostr transport (US12, T060); assembled in doStart. */
  private nostrTransport: NostrTransport | null = null;
  /** Current Nostr identity (US12, T060); set once the store loads it. */
  private currentNostrIdentity: NostrIdentity | null = null;
  /** Device CSPRNG adapter for the Nostr kernel (US12, T060). */
  private readonly deviceNostrRandom: DeviceNostrRandomSource = new DeviceNostrRandomSource();
  /** Seen inbound gift-wrap event IDs, insertion-ordered for the LRU (US12). */
  private seenNostrEventIds: string[] = [];
  /** Set mirror of seenNostrEventIds (US12). */
  private seenNostrEventIdSet: Set<string> = new Set<string>();
  /** Geohash location-channel kernel (US13, T068); lazy, seed-backed. */
  private geohashService: GeohashService | null = null;
  /** One-shot geohash kernel creation guard (US13). */
  private geohashServicePromise: Promise<GeohashService | null> | null = null;
  /** Joined geohash channels, one relay subscription each (US13). */
  private readonly joinedGeohashChannels: Set<string> = new Set<string>();
  /** Channels joined through the globe picker (t/teleport tag, US13). */
  private readonly teleportedGeohashes: Set<string> = new Set<string>();
  /** Seen inbound geohash event ids, insertion-ordered LRU (US13). */
  private seenGeohashEventIds: string[] = [];
  /** Set mirror of seenGeohashEventIds (US13). */
  private seenGeohashEventIdSet: Set<string> = new Set<string>();
  /** Last sighting (ms) per geohash channel and participant pubkey (US13). */
  private geohashPresence: Map<string, Map<string, number>> = new Map();
  /** Per-geohash timeline dedup sets (US13). */
  private geohashTimelineIds: Map<string, Set<string>> = new Map();

  constructor() {
    this.voicePlayer.setListener(this);
    // Live-voice receive mirror (US14, T070): burst lifecycle events of
    // LiveVoiceManager flow into the @Trace state for the incoming strip
    // and the finished-burst auto-play.
    LiveVoiceManager.getInstance().setUiListener(this);
    // Favorites mirror (US11): keep the @Trace fingerprint sets in sync with
    // every store change (own toggle, inbound notice, panic clear).
    FavoritesStore.getInstance().addListener(this);
  }

  static getInstance(): ChatViewModel {
    if (ChatViewModel.instance === null) {
      ChatViewModel.instance = new ChatViewModel();
    }
    return ChatViewModel.instance;
  }

  /** Idempotent; concurrent callers share one wiring pass. Never rejects. */
  start(): Promise<void> {
    if (this.startPromise === null) {
      this.startPromise = this.doStart();
    }
    return this.startPromise;
  }

  /** Tear the mesh down (identity change / logout flows). */
  stop(): void {
    // Voice capture/playback must not outlive the graph teardown.
    this.teardownVoiceNotes();
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    if (this.securityCleanupTimer >= 0) {
      clearInterval(this.securityCleanupTimer);
      this.securityCleanupTimer = -1;
    }
    if (this.fragmentCleanupTimer >= 0) {
      clearInterval(this.fragmentCleanupTimer);
      this.fragmentCleanupTimer = -1;
    }
    graph.gossipSync.stop();
    graph.announceScheduler.stop();
    graph.peerManager.stop();
    graph.packetRelay.shutdown();
    graph.packetProcessor.shutdown();
    graph.messageRouter.stopOutboxScheduler();
    graph.noiseSessions.shutdown();
    graph.transport.stop();
    // Drop any retained media intent / legacy consent before the graph dies.
    graph.mediaIntents.clearPendingPrivateMediaConsent();
    this.state.pendingLegacyConsent = null;
    this.state.mediaProgress = new Map<string, MediaTransferProgress>();
    this.graph = null;
    this.startPromise = null;
    this.state.serviceRunning = false;
    this.state.connectedCount = 0;
    BackgroundTaskCoordinator.getInstance().stop();
  }

  /**
   * Build and broadcast one signed public MESSAGE (T031 send path). The
   * message enters the local timeline even while isolated (local history);
   * returns true when it was accepted into the timeline.
   */
  async sendPublicMessage(content: string): Promise<boolean> {
    const graph: MeshGraph | null = this.graph;
    const text: string = content.trim();
    if (graph === null || text.length === 0) {
      return false;
    }
    this.state.sending = true;
    try {
      const message: BitchatMessage = new BitchatMessage(this.nickname, text, Date.now());
      message.senderPeerId = graph.myPeerId;
      const payload: Uint8Array | null = message.toBinaryPayload();
      if (payload === null) {
        return false;
      }
      const packet: BitchatPacket = new BitchatPacket(1, MessageType.MESSAGE,
        ByteUtils.hexToBytes(graph.myPeerId), null, message.timestamp, payload, null,
        PkTtl.MESSAGE_TTL_HOPS, null);
      const dataToSign: Uint8Array | null = BinaryProtocol.toBinaryDataForSigning(packet);
      if (dataToSign !== null) {
        const signature: Uint8Array | null = await IdentityManager.getInstance().sign(dataToSign);
        if (signature !== null) {
          packet.signature = signature;
        }
      }
      const accepted: boolean = this.appendTimeline(packet, message, this.nickname, true);
      graph.gossipSync.onPublicPacketSeen(packet);
      if (accepted) {
        graph.transport.send(packet);
      }
      return accepted;
    } finally {
      this.state.sending = false;
    }
  }

  // ------------------------------------------------------------------
  // TransportDelegate
  // ------------------------------------------------------------------

  onPacketReceived(packet: BitchatPacket, peerId: string, deviceId: string, linkId: string): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    // Full-TTL ANNOUNCE marks a direct-neighbor contact (relayed copies
    // arrive with TTL-1 or less); mirror of the SecurityGate's
    // fresh-announce duplicate exception.
    const messageType: MessageType | null = messageTypeFromValue(packet.type);
    if (messageType === MessageType.ANNOUNCE && packet.ttl >= PkTtl.MESSAGE_TTL_HOPS) {
      graph.topologyMap.recordDirectLink(peerId, Date.now());
    }
    graph.packetProcessor.processPacket(new RoutedPacket(packet, peerId, null, linkId));
  }

  onPeerConnected(peerId: string | null, deviceId: string, linkId: string): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    if (peerId !== null) {
      graph.topologyMap.recordDirectLink(peerId, Date.now());
      graph.gossipSync.scheduleInitialSyncToPeer(peerId);
    }
    graph.announceScheduler.onPeerConnected();
    this.state.connectedCount = graph.transport.getConnectedDeviceCount();
    BackgroundTaskCoordinator.getInstance().updateNotification(this.state.connectedCount);
  }

  onPeerDisconnected(peerId: string | null, deviceId: string, linkId: string): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    if (peerId !== null) {
      graph.topologyMap.removeDirectLink(peerId);
    }
    graph.announceScheduler.onPeerDisconnected();
    this.state.connectedCount = graph.transport.getConnectedDeviceCount();
    BackgroundTaskCoordinator.getInstance().updateNotification(this.state.connectedCount);
  }

  // ------------------------------------------------------------------
  // PacketProcessorDelegate
  // ------------------------------------------------------------------

  validatePacketSecurity(packet: BitchatPacket, peerID: string): boolean {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return false;
    }
    return graph.securityGate.validatePacket(packet, peerID);
  }

  isPacketAddressedToMe(packet: BitchatPacket): boolean {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return false;
    }
    return graph.packetRelay.isPacketAddressedToMe(packet);
  }

  handleAnnounce(routed: RoutedPacket): boolean {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return false;
    }
    const announcement: IdentityAnnouncement | null =
      IdentityAnnouncement.decode(routed.packet.payload);
    if (announcement === null) {
      return false;
    }
    const now: number = Date.now();
    const neighbors: string[] | null =
      GossipTlv.decodeNeighborsFromAnnouncementPayload(routed.packet.payload);
    const isNew: boolean = graph.peerManager.updateFromVerifiedAnnouncement(routed.peerID,
      announcement, neighbors, now);
    graph.topologyMap.onAnnouncePayload(routed.peerID, routed.packet.payload, now);
    graph.gossipSync.onPublicPacketSeen(routed.packet);
    if (isNew) {
      // New network member: offer it our public history (FR-009).
      graph.gossipSync.scheduleInitialSyncToPeer(routed.peerID);
    }
    return true;
  }

  handleMessage(routed: RoutedPacket): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    const packet: BitchatPacket = routed.packet;
    // Legacy signed directed FILE_TRANSFER 0x22 (US10): the security gate
    // already verified the signature; the plaintext BitchatFilePacket goes
    // straight to the private-media receive path with the disclosure tag.
    if (packet.type === MessageType.FILE_TRANSFER) {
      this.handleIncomingDirectedFileTransfer(routed);
      return;
    }
    const message: BitchatMessage | null = BitchatMessage.fromBinaryPayload(packet.payload);
    if (message === null || message.isPrivate) {
      return;
    }
    // Encrypted payloads are channel traffic (T049); everything else
    // encrypted on the public packet type is not renderable here.
    if (message.isEncrypted && message.channel === null) {
      return;
    }
    const isBroadcast: boolean = packet.recipientId === null ||
      BitchatPacket.isBroadcastRecipient(packet.recipientId);
    if (!isBroadcast) {
      return;
    }
    // Gossip history records every public packet even when the spam filter
    // hides it: the transport-level cache is independent of UI admission
    // (Android keeps relaying and caching hidden floods).
    graph.gossipSync.onPublicPacketSeen(packet);
    // /block: a blocked peer's broadcast gets no timeline row (T039).
    if (this.blockedPeerIds.has(routed.peerID)) {
      return;
    }
    // Spam admission (T038, mirrors Android IncomingMessageAdmission): a
    // hidden flood/repeat gets no timeline row and no UI callback, while the
    // packet itself already proved liveness and stays relayed.
    if (!SpamFilter.isLocalNotice(message) &&
      SpamFilter.shared.shouldHide(message, SpamFilter.meshSenderKey(message))) {
      return;
    }
    const knownNickname: string | null = graph.peerManager.getPeerNickname(routed.peerID);
    const display: string = knownNickname !== null ? knownNickname : message.sender;
    // Channel traffic routes into its per-channel timeline (T049; Android
    // IncomingMessageAdmission order: private -> spam -> channel -> public).
    if (message.channel !== null) {
      this.handleIncomingChannelMessage(routed, message, message.channel, display);
      return;
    }
    const accepted: boolean = this.appendTimeline(packet, message, display, false);
    // Mention notification (T046): only fresh timeline rows from other
    // peers trigger a mention notification.
    if (accepted && routed.peerID !== graph.myPeerId && this.isMentionToMe(message.content)) {
      MessageNotificationDispatcher.getInstance().notifyMeshMention(display,
        message.content, this.publicChatActive);
    }
  }

  /**
   * Ephemeral public push-to-talk frame (US14, T069): mirror of the Android
   * MessageHandler.handlePublicVoiceFrame admission chain - own frames short
   * -circuit, non-broadcast recipients and stale/future timestamps (>30s
   * skew) drop silently, and only verified peers reach the assembler.
   */
  handleVoiceFrame(routed: RoutedPacket): boolean {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return false;
    }
    if (routed.peerID === graph.myPeerId) {
      return true;
    }
    if (routed.packet.recipientId !== null &&
      !BitchatPacket.isBroadcastRecipient(routed.packet.recipientId)) {
      return false;
    }
    const ageMs: number = Date.now() - routed.packet.timestamp;
    if (ageMs < -30000 || ageMs > 30000) {
      return false;
    }
    if (!graph.peerManager.isPeerVerified(routed.peerID)) {
      return false;
    }
    return LiveVoiceManager.getInstance().handleFrame(routed.peerID,
      LiveVoiceScope.PUBLIC_MESH, routed.packet.payload, routed.packet.timestamp);
  }

  handleLeave(routed: RoutedPacket): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    graph.peerManager.removePeer(routed.peerID);
    graph.topologyMap.removeDirectLink(routed.peerID);
    graph.gossipSync.removeAnnouncementForPeer(routed.peerID);
  }

  handleFragment(packet: BitchatPacket): BitchatPacket | null {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return null;
    }
    return graph.receiveFragments.handleFragment(packet);
  }

  /**
   * Noise XX handshake message (T036): feed the session manager, reply with
   * the next handshake message when the manager produced one. The manager
   * enforces the peer-ID/static-key binding before anything is evicted.
   */
  handleNoiseHandshake(routed: RoutedPacket): boolean {
    const graph: MeshGraph | null = this.graph;
    if (graph === null || routed.packet.payload.length === 0 ||
      routed.peerID === graph.myPeerId) {
      return false;
    }
    try {
      const result: NoiseHandshakeProcessingResult =
        graph.noiseSessions.processHandshakeMessageWithResult(routed.peerID,
          routed.packet.payload);
      const response: Uint8Array | null = result.getResponse();
      if (response !== null) {
        this.sendNoisePacket(MessageType.NOISE_HANDSHAKE, response, routed.peerID);
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  /**
   * Noise-encrypted transport (T036): decrypt, then dispatch the
   * NoisePayload - PRIVATE_MESSAGE persists + publishes + DELIVERED ack,
   * DELIVERED / READ_RECEIPT advance the outgoing message status ladder.
   */
  handleNoiseEncrypted(routed: RoutedPacket): boolean {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return false;
    }
    if (routed.peerID === graph.myPeerId) {
      return true;
    }
    let decrypted: NoiseDecryptionResult;
    try {
      decrypted = graph.noiseSessions.decryptWithSession(routed.packet.payload, routed.peerID);
    } catch (e) {
      this.registerDecryptFailure(routed.peerID);
      return false;
    }
    this.consecutiveDecryptFailures.delete(routed.peerID);
    const plaintext: Uint8Array = decrypted.getPlaintext();
    const payload: NoisePayload | null = NoisePayload.decode(plaintext);
    if (payload === null) {
      return true;
    }
    if (payload.type === NoisePayloadType.PRIVATE_MESSAGE) {
      this.handleIncomingPrivateMessage(routed, payload.data);
    } else if (payload.type === NoisePayloadType.DELIVERED) {
      this.applyDeliveryTransition(ByteUtils.utf8Decode(payload.data),
        DeliveryStatusKind.DELIVERED);
    } else if (payload.type === NoisePayloadType.READ_RECEIPT) {
      this.applyDeliveryTransition(ByteUtils.utf8Decode(payload.data),
        DeliveryStatusKind.READ);
    } else if (payload.type === NoisePayloadType.FILE_TRANSFER) {
      this.handleIncomingPrivateMedia(routed, payload.data);
    } else if (payload.type === NoisePayloadType.VOICE_FRAME) {
      // Live PTT over Noise (US14, T069): DM-scope frame straight into the
      // assembler; the session already authenticated the sender.
      LiveVoiceManager.getInstance().handleFrame(routed.peerID,
        LiveVoiceScope.DIRECT_MESSAGE, payload.data, routed.packet.timestamp);
    } else if (payload.type === NoisePayloadType.PEER_STATE) {
      this.handleIncomingPeerState(routed, payload.data, decrypted.getAuthenticatedSession());
    } else if (payload.type === NoisePayloadType.VERIFY_CHALLENGE) {
      this.handleVerifyChallenge(routed, payload.data);
    } else if (payload.type === NoisePayloadType.VERIFY_RESPONSE) {
      this.handleVerifyResponse(routed, payload.data);
    }
    return true;
  }

  handleRequestSync(routed: RoutedPacket): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    const request: RequestSyncPacket | null = RequestSyncPacket.decode(routed.packet.payload);
    if (request === null) {
      return;
    }
    graph.gossipSync.handleRequestSync(routed.peerID, request);
  }

  updatePeerLastSeen(peerID: string): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    graph.peerManager.touchPeer(peerID, Date.now());
  }

  relayPacket(routed: RoutedPacket): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    graph.packetRelay.considerRelay(routed);
  }

  // ------------------------------------------------------------------
  // GossipSyncDelegate
  // ------------------------------------------------------------------

  sendPacket(packet: BitchatPacket): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    graph.transport.send(packet);
  }

  sendPacketToPeer(peerID: string, packet: BitchatPacket): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    graph.transport.send(packet, peerID);
  }

  signPacketForBroadcast(packet: BitchatPacket): BitchatPacket {
    // REQUEST_SYNC is outside the SecurityGate signed set; no signature.
    return packet;
  }

  // ------------------------------------------------------------------
  // GossipSyncConfig
  // ------------------------------------------------------------------

  seenCapacity(): number {
    return SyncConstants.CACHE_CAPACITY;
  }

  gcsMaxBytes(): number {
    return SyncConstants.DEFAULT_FILTER_BYTES;
  }

  gcsTargetFpr(): number {
    return SyncConstants.DEFAULT_FPR_PERCENT / 100.0;
  }

  // ------------------------------------------------------------------
  // AnnounceSchedulerDelegate
  // ------------------------------------------------------------------

  getNickname(): string {
    return this.nickname;
  }

  getNoisePublicKey(): Uint8Array | null {
    return IdentityManager.getInstance().getStaticPublicKey();
  }

  getSigningPublicKey(): Uint8Array | null {
    return IdentityManager.getInstance().getSigningPublicKey();
  }

  async signAnnouncementData(data: Uint8Array): Promise<Uint8Array | null> {
    return IdentityManager.getInstance().sign(data);
  }

  getDirectNeighborPeerIds(): string[] {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return [];
    }
    return graph.transport.getConnectedPeerIds();
  }

  broadcastAnnouncePacket(packet: BitchatPacket): boolean {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return false;
    }
    const sent: boolean = graph.transport.send(packet);
    graph.gossipSync.onPublicPacketSeen(packet);
    return sent;
  }

  hasConnectedPeers(): boolean {
    const graph: MeshGraph | null = this.graph;
    return graph !== null && graph.transport.getConnectedDeviceCount() > 0;
  }

  // ------------------------------------------------------------------
  // PeerManagerDelegate
  // ------------------------------------------------------------------

  onPeerListUpdated(peerIds: string[]): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    for (let i: number = 0; i < peerIds.length; i++) {
      const info: PeerInfo | null = graph.peerManager.getPeerInfo(peerIds[i]);
      if (info !== null) {
        EventBus.emit(BcEvents.PEER_UPDATED,
          new PeerUpdatedPayload(info.id, info.nickname, info.lastSeenMs));
      }
    }
  }

  onPeerRemoved(peerId: string): void {
    EventBus.emit(BcEvents.PEER_REMOVED, new PeerRemovedPayload(peerId));
  }

  // ------------------------------------------------------------------
  // PacketRelayDelegate
  // ------------------------------------------------------------------

  getConnectedLinkIds(): string[] {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return [];
    }
    return graph.transport.getConnectedLinkIds();
  }

  sendOnLink(linkId: string, packet: BitchatPacket): boolean {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return false;
    }
    return graph.transport.sendOnLink(linkId, packet);
  }

  // ------------------------------------------------------------------
  // Private chat (T036)
  // ------------------------------------------------------------------

  /**
   * Entry from the peer list: remember the display name, warm the Noise
   * session when the peer is reachable, then open the conversation.
   */
  async startPrivateChatWithPeer(peerID: string, nickname: string): Promise<void> {
    const graph: MeshGraph | null = this.graph;
    if (graph === null || peerID === '' || peerID === graph.myPeerId) {
      return;
    }
    const known: string | null = graph.peerManager.getPeerNickname(peerID);
    if (nickname !== '') {
      this.conversationDisplayNames.set(peerID, nickname);
    } else if (known !== null) {
      this.conversationDisplayNames.set(peerID, known);
    }
    if (graph.transport.getConnectedPeerIds().indexOf(peerID) >= 0 &&
      !graph.noiseSessions.hasEstablishedSession(peerID)) {
      this.initiateNoiseHandshake(peerID);
    }
    await this.openPrivateConversation(peerID);
  }

  /** Load one conversation into the open-chat state, mark it read, send receipts. */
  async openPrivateConversation(conversationID: string): Promise<void> {
    const graph: MeshGraph | null = this.graph;
    if (graph === null || conversationID === '') {
      return;
    }
    this.state.selectedConversationId = conversationID;
    // Opening the conversation retires its unread notification group (T046).
    MessageNotificationDispatcher.getInstance().clearPrivateNotifications(conversationID);
    try {
      const snapshot: PersistedConversationSnapshot =
        await ConversationStore.getInstance().loadConversation(conversationID);
      const messages: BitchatMessage[] | undefined =
        snapshot.messagesByConversation.get(conversationID);
      const history: BitchatMessage[] = messages === undefined ? [] : messages;
      const entries: PrivateMessageEntry[] = [];
      for (let i: number = 0; i < history.length; i++) {
        const message: BitchatMessage = history[i];
        entries.push(this.toPrivateEntry(message, graph.myPeerId,
          snapshot.readMessageIDs.has(message.id)));
      }
      this.state.privateMessages = entries;
      for (let i: number = 0; i < entries.length; i++) {
        const entry: PrivateMessageEntry = entries[i];
        if (!entry.isMine && !entry.isRead && !this.sentReadReceipts.has(entry.messageID)) {
          this.sentReadReceipts.add(entry.messageID);
          this.sendNoiseReceipt(NoisePayloadType.READ_RECEIPT, entry.messageID,
            conversationID);
        }
      }
      await ConversationStore.getInstance().setConversationRead(conversationID, true);
      await this.refreshConversationSummaries();
    } catch (e) {
      // Render the conversation empty rather than blocking the chat.
      this.state.privateMessages = [];
    }
  }

  /** Close the open private chat (destination popped). */
  closePrivateConversation(): void {
    this.state.selectedConversationId = '';
    this.state.privateMessages = [];
  }

  /** Display name for a private conversation (multi-alias entries share it). */
  getConversationDisplayName(conversationID: string): string {
    const graph: MeshGraph | null = this.graph;
    const known: string | undefined = this.conversationDisplayNames.get(conversationID);
    if (known !== undefined) {
      return known;
    }
    if (graph !== null) {
      const nickname: string | null = graph.peerManager.getPeerNickname(conversationID);
      if (nickname !== null) {
        return nickname;
      }
    }
    return conversationID;
  }

  /**
   * Resolve an alias key (mesh peer ID, Noise static key hex, later npub) to
   * the canonical conversation ID (plan.md Conversation.aliasKeys: the peer
   * ID is canonical at US4; aliases registered on session establishment).
   */
  canonicalConversationId(aliasKey: string): string {
    const mapped: string | undefined = this.noiseKeyAliasToConversation.get(aliasKey);
    return mapped !== undefined ? mapped : aliasKey;
  }

  async sendPrivateText(content: string): Promise<boolean> {
    return this.doSendPrivateText(this.state.selectedConversationId, content);
  }

  /**
   * Build, persist and route one private message (T036 send path): the
   * message is stored as SENDING, enters the open conversation and is handed
   * to the MessageRouter, which sends it directly over the established Noise
   * session or queues it in the outbox for later delivery. The explicit
   * conversation ID lets the command kernel (/msg, /hug, /slap) target a
   * conversation that is not the currently open one.
   */
  private async doSendPrivateText(conversationID: string, content: string): Promise<boolean> {
    const graph: MeshGraph | null = this.graph;
    const text: string = content.trim();
    if (graph === null || text.length === 0 || conversationID === '' ||
      ByteUtils.utf8Encode(text).length > PRIVATE_CONTENT_MAX_BYTES) {
      return false;
    }
    this.state.privateSending = true;
    try {
      const messageID: string = util.generateRandomUUID();
      const message: BitchatMessage = new BitchatMessage(this.nickname, text, Date.now());
      message.id = messageID;
      message.isPrivate = true;
      message.senderPeerId = graph.myPeerId;
      message.recipientNickname = this.getConversationDisplayName(conversationID);
      message.deliveryStatus = DeliveryStatusKind.SENDING;
      await ConversationStore.getInstance().appendMessage(conversationID, message, true);
      this.state.privateMessages = this.state.privateMessages.concat([
        this.toPrivateEntry(message, graph.myPeerId, true)]);
      const routeResult: RouteResult = graph.messageRouter.sendPrivate(text, conversationID,
        message.recipientNickname ?? '', messageID);
      if (routeResult === RouteResult.NOSTR) {
        // US12 (T060): sent straight over Nostr - no mesh hop, no outbox
        // stay - so it counts as SENT immediately.
        this.applyDeliveryTransition(messageID, DeliveryStatusKind.SENT);
      }
      this.refreshConversationSummaries();
      return true;
    } finally {
      this.state.privateSending = false;
    }
  }

  // ------------------------------------------------------------------
  // CommandProcessorDelegate + composer suggestion plumbing (T039)
  // ------------------------------------------------------------------

  /** Try one composer input as an IRC command; true when it was one. */
  processCommandInput(text: string): boolean {
    return this.commandProcessor.processCommand(text);
  }

  updateCommandSuggestions(input: string): void {
    const suggestions: CommandSuggestion[] = this.commandProcessor.getCommandSuggestions(input);
    this.state.commandSuggestions = suggestions;
    this.state.showCommandSuggestions = suggestions.length > 0;
  }

  updateMentionSuggestions(input: string): void {
    const suggestions: string[] = this.commandProcessor.getMentionSuggestions(input);
    this.state.mentionSuggestions = suggestions;
    this.state.showMentionSuggestions = suggestions.length > 0;
  }

  selectCommandSuggestion(suggestion: CommandSuggestion): string {
    return this.commandProcessor.selectCommandSuggestion(suggestion);
  }

  /** Home-tab switch from ChatPage: drives mention suppression (T046). */
  setPublicChatActive(active: boolean): void {
    this.publicChatActive = active;
  }

  /**
   * Android checkForMeshMention parity: a '@nickname' hit is a mention only
   * when the following character does not extend the nickname word.
   */
  private isMentionToMe(content: string): boolean {
    const nickname: string = this.nickname;
    if (nickname === '') {
      return false;
    }
    const needle: string = ('@' + nickname).toLowerCase();
    const haystack: string = content.toLowerCase();
    let from: number = 0;
    while (from + needle.length <= haystack.length) {
      const idx: number = haystack.indexOf(needle, from);
      if (idx < 0) {
        return false;
      }
      const end: number = idx + needle.length;
      if (end >= haystack.length || !MENTION_BOUNDARY_REGEX.test(haystack.charAt(end))) {
        return true;
      }
      from = idx + 1;
    }
    return false;
  }

  selectMentionSuggestion(nickname: string, currentText: string): string {
    return this.commandProcessor.selectMentionSuggestion(nickname, currentText);
  }

  /** Hide both autocomplete popups (field cleared in code, no onChange). */
  clearSuggestionPopups(): void {
    this.state.showCommandSuggestions = false;
    this.state.commandSuggestions = [];
    this.state.showMentionSuggestions = false;
    this.state.mentionSuggestions = [];
  }

  /** Switch the chat surface between bubbles and terminal modes (T041). */
  setBubblesMode(bubbles: boolean): void {
    this.state.bubblesMode = bubbles;
  }

  // ------------------------------------------------------------------
  // PanicWipeDelegate + emergency-wipe entry point (T043)
  // ------------------------------------------------------------------

  /**
   * Panic entry point for the trigger UI (T044): run the staged wipe
   * (IdentityManager.panicWipe), then surface the outcome as a system
   * notice. Returns null while another wipe is already running.
   */
  async panicWipeAllData(): Promise<PanicWipeResult | null> {
    if (this.panicWipeInProgress) {
      return null;
    }
    this.panicWipeInProgress = true;
    try {
      const result: PanicWipeResult =
        await IdentityManager.getInstance().panicWipe(this);
      this.addPublicNotice(result.completed ? PANIC_COMPLETED_NOTICE : PANIC_INCOMPLETE_NOTICE);
      return result;
    } finally {
      this.panicWipeInProgress = false;
    }
  }

  panicStopServices(): boolean {
    this.stop();
    return this.graph === null && !this.state.serviceRunning;
  }

  panicClearPrivateMediaConsent(): boolean {
    // Private-media consent arrives with the media-transfer phase; a
    // confirmed no-op until then (Android clearPendingPrivateMediaConsent).
    return true;
  }

  panicStopAdmission(): boolean {
    // stop() gates every inbound path on graph === null, so message
    // admission is already rejected until the fresh identity is ready.
    return this.graph === null;
  }

  async panicDeleteConversationStore(): Promise<boolean> {
    return ConversationStore.getInstance().dropAll();
  }

  async panicClearUiState(): Promise<boolean> {
    const state: ChatState = this.state;
    state.messages = [];
    state.privateConversations = [];
    state.privateMessages = [];
    state.selectedConversationId = '';
    state.sending = false;
    state.privateSending = false;
    this.clearSuggestionPopups();
    this.conversationDisplayNames.clear();
    this.noiseKeyAliasToConversation.clear();
    this.blockedPeerIds.clear();
    this.channelManager.clearAllChannels();
    state.channelMessages = new Map<string, ChatEntry[]>();
    this.channelTimelineIds.clear();
    state.currentChannel = '';
    state.passwordPromptChannel = '';
    state.showPasswordPrompt = false;
    // Favorites/verification mirrors (US11): the preference wipe below also
    // removes the persisted verified-fingerprint array.
    state.verifiedFingerprints = new Set<string>();
    state.favoritedFingerprints = new Set<string>();
    state.peerFavoritedUsFingerprints = new Set<string>();
    state.verificationPendingPeerId = '';
    this.consecutiveDecryptFailures.clear();
    try {
      // The panic manifest: every preference (nickname, settings, spam
      // toggles, onboarding flag) rides PreferenceStore (D9).
      await PreferenceStore.getInstance().clearAll();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'panic preference wipe failed: %{public}s', JSON.stringify(e));
      return false;
    }
    return true;
  }

  panicClearDedupAndOutbox(): boolean {
    this.timelineIds.clear();
    this.sentReadReceipts.clear();
    const graph: MeshGraph | null = this.graph;
    if (graph !== null) {
      graph.outbox.clearAll();
    }
    return true;
  }

  panicClearSpamFilter(): boolean {
    SpamFilter.shared.reset();
    return true;
  }

  panicClearNotifications(): boolean {
    // Panic wipe (T046): retire every message notification.
    MessageNotificationDispatcher.getInstance().clearAll();
    return true;
  }

  panicDeleteMedia(): boolean {
    // Panic wipe (T050/T054): an in-flight capture or a playing note
    // must not outlive the sweep of every media directory (incoming
    // cache, outgoing staging, voice notes) plus the pinned 0x21 peer
    // states (T053); both must be evaluated, no short-circuit.
    this.teardownVoiceNotes();
    // Live PTT assemblies (US14, T069) must drop before the cache sweep so
    // half-written burst files cannot linger as orphaned handles.
    LiveVoiceManager.getInstance().reset();
    const mediaCleared: boolean = MediaFileStore.getInstance().clearAllMedia();
    const pinsCleared: boolean = PeerStatePinStore.getInstance().clearAll();
    return mediaCleared && pinsCleared;
  }

  panicClearNostrGeohash(): boolean {
    // Panic stage CLEAR_NOSTR_GEOHASH (US12, T060): drop the in-memory
    // Nostr identity, the inbound-DM dedup LRU, the queued read receipts
    // and all relay state (subscriptions, dedup cache, sockets). The
    // persisted key goes via the SecureKeyStore panic wipe that always
    // follows; the transport itself is stateless and stays reusable.
    NostrIdentityStore.getInstance().clearCache();
    this.currentNostrIdentity = null;
    this.seenNostrEventIds = [];
    this.seenNostrEventIdSet = new Set<string>();
    if (this.nostrTransport !== null) {
      this.nostrTransport.cleanup();
    }
    NostrRelayManager.shared.clearAllOnPanic();
    // US13 (T068): drop the geohash kernel (the persisted seed goes
    // with the SecureKeyStore panic wipe below), the per-channel relay
    // subscriptions, the seen-id / presence / timeline caches and the
    // bookmark mirror (the persisted copy goes with the PreferenceStore
    // clearAll stage).
    this.geohashService = null;
    this.geohashServicePromise = null;
    this.joinedGeohashChannels.clear();
    this.teleportedGeohashes.clear();
    this.seenGeohashEventIds = [];
    this.seenGeohashEventIdSet = new Set<string>();
    this.geohashPresence = new Map<string, Map<string, number>>();
    this.geohashTimelineIds = new Map<string, Set<string>>();
    this.state.currentGeohashChannel = '';
    this.state.geohashMessages = new Map<string, ChatEntry[]>();
    this.state.geohashParticipantCounts = new Map<string, number>();
    this.state.geohashBookmarks = [];
    GeohashBookmarksStore.getInstance().clearCache();
    return true;
  }

  panicClearFavorites(): boolean {
    // Panic stage CLEAR_FAVORITES (US11): drop every favorite relationship,
    // the peerID->npub index, the cached QR and any in-flight verification.
    VerificationService.clearQrCache();
    this.pendingVerifications.clear();
    this.pendingQrIntents.clear();
    this.state.verificationPendingPeerId = '';
    return FavoritesStore.getInstance().clearAllFavorites();
  }

  async panicResetNickname(): Promise<boolean> {
    // anon<1000-9999> (Android Random.nextInt(1000, 9999) parity: 1000..9998).
    const generated: string = 'anon' + (1000 + Math.floor(Math.random() * 8999));
    const saved: boolean = await IdentityManager.getInstance().setNickname(generated);
    if (saved) {
      this.nickname = generated;
      this.state.nickname = generated;
    }
    return saved;
  }

  async panicRestartMesh(): Promise<boolean> {
    // start() re-runs initialize() (fresh keys -> new peer ID) and rebuilds
    // the whole service graph with the new identity.
    await this.start();
    return this.state.serviceRunning;
  }

  getConnectedPeerNicknames(): string[] {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return [];
    }
    const connected: string[] = graph.transport.getConnectedPeerIds();
    const nicknames: string[] = [];
    for (let i: number = 0; i < connected.length; i++) {
      if (connected[i] === graph.myPeerId) {
        continue;
      }
      const nickname: string | null = graph.peerManager.getPeerNickname(connected[i]);
      nicknames.push(nickname !== null ? nickname : connected[i]);
    }
    return nicknames;
  }

  getKnownPeerNicknames(): string[] {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return [];
    }
    const known: string[] = graph.peerManager.getVerifiedPeerIds();
    const nicknames: string[] = [];
    for (let i: number = 0; i < known.length; i++) {
      if (known[i] === graph.myPeerId) {
        continue;
      }
      const nickname: string | null = graph.peerManager.getPeerNickname(known[i]);
      if (nickname !== null) {
        nicknames.push(nickname);
      }
    }
    return nicknames;
  }

  getPeerIdForNickname(nickname: string): string | null {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return null;
    }
    const known: string[] = graph.peerManager.getVerifiedPeerIds();
    for (let i: number = 0; i < known.length; i++) {
      if (graph.peerManager.getPeerNickname(known[i]) === nickname) {
        return known[i];
      }
    }
    return null;
  }

  getPeerNickname(peerId: string): string {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return peerId;
    }
    const nickname: string | null = graph.peerManager.getPeerNickname(peerId);
    return nickname !== null ? nickname : peerId;
  }

  getSelectedPrivateChatPeer(): string | null {
    return this.state.selectedConversationId === '' ? null : this.state.selectedConversationId;
  }

  getCurrentChannel(): string | null {
    // Joined-channel timelines arrive with T049; until then the composer
    // writes to the main timeline whenever no channel is selected.
    return this.state.currentChannel !== '' ? this.state.currentChannel : null;
  }

  addPublicNotice(content: string): void {
    const entry: ChatEntry = new ChatEntry(util.generateRandomUUID(), '', 'system',
      content, Date.now(), false);
    let next: ChatEntry[] = this.state.messages.concat([entry]);
    next.sort(ChatViewModel.compareEntries);
    if (next.length > TIMELINE_CAPACITY) {
      next = next.slice(next.length - TIMELINE_CAPACITY);
    }
    this.state.messages = next;
  }

  clearPrivateMessages(peerId: string): void {
    // Android parity: the history disappears but the chat stays selected;
    // a later message repopulates the conversation.
    if (this.state.selectedConversationId === peerId) {
      this.state.privateMessages = [];
    }
  }

  clearChannelMessages(channel: string): void {
    // /clear while a channel is selected drops that channel's timeline
    // (T049; CommandProcessor routes here via getCurrentChannel).
    const tag: string = ChannelManager.normalizeChannelName(channel);
    this.state.channelMessages.delete(tag);
    this.channelTimelineIds.delete(tag);
  }

  clearPublicTimeline(): void {
    this.state.messages = [];
    this.timelineIds = new Set();
  }

  isPeerBlocked(peerId: string): boolean {
    return this.blockedPeerIds.has(peerId);
  }

  blockPeer(peerId: string): boolean {
    this.blockedPeerIds.add(peerId);
    return true;
  }

  unblockPeer(peerId: string): boolean {
    this.blockedPeerIds.delete(peerId);
    return true;
  }

  listBlockedUsers(): string {
    const count: number = this.blockedPeerIds.size;
    return count === 0 ? 'no blocked users' : 'blocked users: ' + count + ' fingerprints';
  }

  joinChannel(channel: string, password: string | null): boolean {
    // Channel registry + password gating (T048, US9; Android ChannelManager
    // parity): NEEDS_PASSWORD arms the prompt (dialog in T049), a failed
    // derivation (wrong password) refuses the join.
    const graph: MeshGraph | null = this.graph;
    const myPeerId: string = graph !== null ? graph.myPeerId : '';
    const result: ChannelJoinResult =
      this.channelManager.joinChannel(channel, password, myPeerId);
    if (result === ChannelJoinResult.JOINED) {
      this.state.currentChannel = ChannelManager.normalizeChannelName(channel);
      this.state.passwordPromptChannel = '';
      this.state.showPasswordPrompt = false;
      return true;
    }
    if (result === ChannelJoinResult.NEEDS_PASSWORD) {
      this.state.passwordPromptChannel = ChannelManager.normalizeChannelName(channel);
      this.state.showPasswordPrompt = true;
      return false;
    }
    if (result === ChannelJoinResult.WRONG_PASSWORD) {
      this.state.passwordPromptChannel = ChannelManager.normalizeChannelName(channel);
      this.state.showPasswordPrompt = true;
      this.addPublicNotice('wrong password for ' +
        ChannelManager.normalizeChannelName(channel));
      return false;
    }
    return false;
  }

  getJoinedChannels(): string[] {
    return this.channelManager.getJoinedChannelsList();
  }

  startPrivateChat(peerId: string): boolean {
    if (this.blockedPeerIds.has(peerId)) {
      return false;
    }
    // Fire-and-forget: the sync prefix selects the conversation before the
    // first await, the history load continues asynchronously.
    this.openPrivateConversation(peerId);
    return true;
  }

  sendPrivateTextToConversation(conversationId: string, content: string): boolean {
    // Fire-and-forget; the async path persists, publishes and routes.
    this.doSendPrivateText(conversationId, content);
    return true;
  }

  sendPublicText(content: string): void {
    // Fire-and-forget; the async path signs and broadcasts.
    this.sendPublicMessage(content);
  }

  // ------------------------------------------------------------------
  // MessageRouterDelegate
  // ------------------------------------------------------------------

  isConnected(peerID: string): boolean {
    const graph: MeshGraph | null = this.graph;
    return graph !== null && graph.transport.getConnectedPeerIds().indexOf(peerID) >= 0;
  }

  hasEstablishedSession(peerID: string): boolean {
    const graph: MeshGraph | null = this.graph;
    return graph !== null && graph.noiseSessions.hasEstablishedSession(peerID);
  }

  /**
   * Direct mesh send for one private message: PrivateMessagePacket TLV ->
   * NoisePayload(PRIVATE_MESSAGE) -> Noise-encrypted NOISE_ENCRYPTED packet
   * (unsigned like Android/iOS; the signed set excludes the Noise types).
   * Throws on failure so the router falls through to the outbox.
   */
  sendPrivateMessage(content: string, toPeerID: string, recipientNickname: string,
    messageID: string | null): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null || content === '' || toPeerID === '') {
      throw new Error('private send unavailable');
    }
    const finalMessageID: string = messageID !== null ? messageID : util.generateRandomUUID();
    const tlv: Uint8Array | null = new PrivateMessagePacket(finalMessageID, content).encode();
    if (tlv === null) {
      throw new Error('private message encode failed');
    }
    const encrypted: Uint8Array = graph.noiseSessions.encrypt(
      new NoisePayload(NoisePayloadType.PRIVATE_MESSAGE, tlv).encode(), toPeerID);
    if (!this.sendNoisePacket(MessageType.NOISE_ENCRYPTED, encrypted, toPeerID)) {
      throw new Error('transport send failed');
    }
  }

  /** Send Noise XX message 1 (or a replacement handshake) to one peer. */
  initiateNoiseHandshake(peerID: string): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    try {
      const handshakeData: Uint8Array | null = graph.noiseSessions.initiateHandshake(peerID);
      if (handshakeData !== null) {
        this.sendNoisePacket(MessageType.NOISE_HANDSHAKE, handshakeData, peerID);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'noise handshake initiation failed: %{public}s',
        JSON.stringify(e));
    }
  }

  /** Whether this contact can receive Nostr private messages now (US12). */
  canSendViaNostr(peerID: string): boolean {
    const relationship: FavoriteRelationship | null =
      FavoritesStore.getInstance().getFavoriteStatus(peerID);
    if (relationship === null || !relationship.isMutual()) {
      return false;
    }
    const npub: string | null = relationship.peerNostrPublicKey;
    return npub !== null && npub !== '';
  }

  /** Send one private message over Nostr (US12); false when it failed. */
  sendPrivateMessageViaNostr(content: string, targetPeerID: string,
    recipientNickname: string, messageID: string): boolean {
    const transport: NostrTransport | null = this.nostrTransport;
    if (transport === null) {
      return false;
    }
    return transport.sendPrivateMessage(content, targetPeerID, messageID);
  }

  /**
   * Whether a Noise X courier envelope can reach this contact now (US17).
   * The device-side courier wiring (CourierManager on the mesh stack)
   * reports capability here; until then the courier tier stays dormant.
   */
  canSendViaCourier(peerID: string): boolean {
    return false;
  }

  /** Seal and deposit one private message with connected couriers (US17); false when unavailable. */
  sendPrivateMessageViaCourier(content: string, targetPeerID: string,
    recipientNickname: string, messageID: string): boolean {
    return false;
  }

  /** A new qualified courier connected (US17): pending deposits retry via the courier wiring. */
  retryCourierDeposits(): void {
  }

  // ------------------------------------------------------------------
  // Internals
  // ------------------------------------------------------------------

  private async doStart(): Promise<void> {
    try {
      const identity: IdentityManager = IdentityManager.getInstance();
      await identity.initialize();
      const myPeerId: string = identity.getPeerId();
      this.nickname = await identity.getNickname();
      const peerManager: PeerManager = new PeerManager(this);
      const securityGate: SecurityGate = new SecurityGate(myPeerId,
        (signature: Uint8Array, data: Uint8Array, publicKey: Uint8Array): boolean => {
          return identity.verifySync(signature, data, publicKey);
        }, peerManager);
      const transport: BleMeshService = new BleMeshService(myPeerId, this);
      const noiseSessions: NoiseSessionManager = new NoiseSessionManager(
        identity.getStaticPrivateKey(), identity.getStaticPublicKey(), myPeerId,
        (): Uint8Array => cryptoFramework.createRandom().generateRandomSync(32).data,
        (delayMs: number, task: () => void): number => setTimeout(task, delayMs),
        (handle: number): void => clearTimeout(handle));
      const outbox: Outbox = new Outbox();
      const messageRouter: MessageRouter = new MessageRouter(this, outbox,
        (delayMs: number, task: () => void): number => setTimeout(task, delayMs),
        (handle: number): void => clearTimeout(handle));
      // US12 Nostr transport (T060): resolves recipients through the
      // favorites index, embeds "bitchat1:" packets, gift-wraps them and
      // hands the events to the relay manager; the gift-wrap DM
      // subscription starts at the end of doStart. Built once; a panic
      // restart keeps the instance (it is stateless besides the throttle).
      if (this.nostrTransport === null) {
        this.nostrTransport = new NostrTransport({
          senderPeerID: (): string => {
            const current: MeshGraph | null = this.graph;
            return current !== null ? current.myPeerId : '';
          },
          currentIdentity: (): NostrIdentity | null => this.currentNostrIdentity,
          resolveNostrPubkey: (peerID: string): string | null => {
            const store: FavoritesStore = FavoritesStore.getInstance();
            const indexed: string | null = store.findNostrPubkeyForPeerID(peerID);
            if (indexed !== null) {
              return indexed;
            }
            const relationship: FavoriteRelationship | null =
              store.getFavoriteStatus(peerID);
            return relationship !== null ? relationship.peerNostrPublicKey : null;
          },
          findPeerIDForNostrPubkey: (npubOrHex: string): string | null => {
            return FavoritesStore.getInstance().findPeerIDForNostrPubkey(npubOrHex);
          },
          random: (): NostrRandomSource => this.deviceNostrRandom,
          now: (): number => Date.now(),
          publish: (events: NostrEvent[]): void => {
            const shared: NostrRelayManager = NostrRelayManager.shared;
            for (let i: number = 0; i < events.length; i++) {
              NostrRelayManager.registerPendingGiftWrap(events[i].id);
              shared.sendEvent(events[i], null);
            }
          },
          schedule: (delayMs: number, task: () => void): number => setTimeout(task, delayMs)
        });
      }
      // US10 media stack (T053): 0x21 peer-state coordinator, the private-
      // media security controller, the build-route-sign-fragment preparer,
      // and the pending-intent / legacy-consent state machine.
      const peerStateManager: PeerStateManager = new PeerStateManager({
        authenticatedSessionProvider: (peerID: string): AuthenticatedNoiseSession | null => {
          return noiseSessions.getAuthenticatedSession(peerID);
        },
        withAuthenticatedSession: (peerID: string,
          expectedSession: AuthenticatedNoiseSession,
          action: () => boolean): boolean => {
          return noiseSessions.withAuthenticatedSession(peerID, expectedSession, action);
        },
        store: PeerStatePinStore.getInstance(),
        localStateProvider: (): AuthenticatedPeerState => {
          return new AuthenticatedPeerState(PeerCapabilities.LOCAL_SUPPORTED,
            identity.getSigningPublicKey());
        },
        applyAuthenticatedState: (peerID: string, authenticatedNoisePublicKey: Uint8Array,
          state: AuthenticatedPeerState): void => {
          // The authenticated Ed25519 key replaces the announced one for
          // future signature checks (full gate integration arrives with the
          // identity-fingerprint phase); record it now so the pin published
          // after persistence stays observable.
          this.authenticatedSigningKeys.set(peerID, state.signingPublicKey.slice());
        },
        sendState: (peerID: string, state: AuthenticatedPeerState,
          session: AuthenticatedNoiseSession): boolean => {
          const plaintext: Uint8Array =
            new NoisePayload(NoisePayloadType.PEER_STATE, state.encode()).encode();
          try {
            const encrypted: Uint8Array =
              noiseSessions.encryptForSession(plaintext, peerID, session);
            return this.sendNoisePacket(MessageType.NOISE_ENCRYPTED, encrypted, peerID);
          } catch (e) {
            return false;
          }
        },
        onResolution: (peerID: string): void => {
          // PROVEN or TIMED_OUT: a retained private-media send re-runs its
          // policy lookup (Android retryPendingPrivateMedia parity).
          const current: MeshGraph | null = this.graph;
          if (current !== null) {
            current.mediaIntents.retryPendingPrivateMedia(peerID);
          }
        },
        proofTimeoutMs: PeerStateManager.PROOF_TIMEOUT_MS,
        schedule: (delayMs: number, task: () => void): number => setTimeout(task, delayMs),
        cancel: (handle: number): void => clearTimeout(handle)
      });
      const mediaSecurity: PrivateMediaSecurityController = new PrivateMediaSecurityController({
        authenticatedSessionProvider: (peerID: string): AuthenticatedNoiseSession | null => {
          return noiseSessions.getAuthenticatedSession(peerID);
        },
        peerStateStatusProvider: (peerID: string,
          authenticatedSession: AuthenticatedNoiseSession): PeerStateStatus => {
          return peerStateManager.status(peerID, authenticatedSession);
        },
        provenStateProvider: (peerID: string,
          authenticatedSession: AuthenticatedNoiseSession): AuthenticatedPeerState | null => {
          return peerStateManager.provenState(peerID, authenticatedSession);
        },
        isPrivateMediaPinned: (peerID: string): boolean => {
          return peerStateManager.isPrivateMediaPinned(peerID);
        }
      });
      const mediaProgress: TransferProgressManager = new TransferProgressManager();
      mediaProgress.addListener((event: TransferProgressEvent): void => {
        this.state.mediaProgress.set(event.transferId, new MediaTransferProgress(
          event.transferId, event.sent, event.total, event.completed, event.failed));
      });
      const mediaPreparer: PrivateMediaTransferPreparer = new PrivateMediaTransferPreparer({
        senderID: ByteUtils.hexToBytes(myPeerId),
        ttl: PkTtl.MESSAGE_TTL_HOPS,
        policyProvider: (recipientPeerID: string): PrivateMediaPolicyDecision => {
          return mediaSecurity.sendPolicy(recipientPeerID);
        },
        encrypt: (plaintext: Uint8Array, recipientPeerID: string,
          authenticatedSession: AuthenticatedNoiseSession) => {
          try {
            const ciphertext: Uint8Array = noiseSessions.encryptForSession(
              plaintext, recipientPeerID, authenticatedSession);
            return PrivateMediaEncryptionResult.success(ciphertext);
          } catch (e) {
            if (e instanceof Error && e.message === 'Noise session generation changed') {
              return PrivateMediaEncryptionResult.generationChanged();
            }
            return PrivateMediaEncryptionResult.failed();
          }
        },
        finalizeRoutedAndSigned: (packet: BitchatPacket): BitchatPacket | null => {
          const dataToSign: Uint8Array | null = BinaryProtocol.toBinaryDataForSigning(packet);
          if (dataToSign === null) {
            return null;
          }
          const signature: Uint8Array | null =
            IdentityManager.getInstance().signSync(dataToSign);
          if (signature === null) {
            return null;
          }
          packet.signature = signature;
          return packet;
        },
        fragment: (packet: BitchatPacket, maxFragments: number): BitchatPacket[] => {
          return new FragmentManager().createFragments(packet, maxFragments);
        },
        commitPrepared: (transferId: string,
          built: BuiltPrivateMediaTransfer): boolean => {
          return this.dispatchPrivateMediaFragments(transferId, built);
        },
        now: (): number => Date.now()
      });
      const mediaIntents: PrivateMediaSendIntentManager = new PrivateMediaSendIntentManager({
        prepareFilePrivate: (recipientPeerID: string, file: BitchatFilePacket,
          transferId: string, allowLegacyFallback: boolean): PrivateMediaPreparation => {
          return mediaPreparer.prepare(recipientPeerID,
            ByteUtils.hexToBytes(recipientPeerID), file, transferId, allowLegacyFallback);
        },
        initiateNoiseHandshake: (recipientMeshPeerID: string): void => {
          this.initiateNoiseHandshake(recipientMeshPeerID);
        },
        nicknameFor: (recipientMeshPeerID: string): string | null => {
          const display: string = this.getConversationDisplayName(recipientMeshPeerID);
          return display === recipientMeshPeerID ? null : display;
        },
        addSystemMessage: (conversationID: string, text: string): void => {
          this.addPrivateSystemMessage(conversationID, text);
        },
        onReady: (preparation: PrivateMediaPreparation,
          intent: PrivateMediaSendIntent): void => {
          this.commitPrivateMediaEcho(preparation, intent);
        },
        schedule: (delayMs: number, action: () => void): void => {
          setTimeout(action, delayMs);
        },
        randomId: (): string => util.generateRandomUUID()
      });
      const graph: MeshGraph = new MeshGraph(myPeerId, transport, securityGate,
        new FragmentManager(), peerManager, new TopologyMap(myPeerId),
        new PacketProcessor(this), new PacketRelay(myPeerId, this),
        new GossipSyncManager(myPeerId, this, this), new AnnounceScheduler(myPeerId, this),
        noiseSessions, outbox, messageRouter, peerStateManager, mediaSecurity,
        mediaPreparer, mediaIntents, mediaProgress);
      this.graph = graph;
      // Noise session established: register the static-key alias (multi-alias
      // normalization groundwork) and flush anything the outbox queued for
      // this peer while the session was still pending.
      noiseSessions.onSessionEstablished =
        (peerID: string, remoteStaticKey: Uint8Array): void => {
          this.noiseKeyAliasToConversation.set(ByteUtils.bytesToHex(remoteStaticKey), peerID);
          messageRouter.onSessionEstablished(peerID);
          // 0x21 exchange (T053): every authenticated generation/rekey gets
          // its own peer-state coordinator entry and watchdog.
          const authenticated: AuthenticatedNoiseSession | null =
            noiseSessions.getAuthenticatedSession(peerID);
          if (authenticated !== null) {
            peerStateManager.onSessionAuthenticated(peerID,
              authenticated.getRemoteStaticKey(), authenticated.getSessionToken());
          }
          // QR verification (US11): a scanned QR that waited for this
          // session now fires its 0x10 challenge.
          const pendingQr: VerificationQR | undefined = this.pendingQrIntents.get(peerID);
          if (pendingQr !== undefined) {
            this.pendingQrIntents.delete(peerID);
            this.sendVerifyChallengeNow(peerID, pendingQr);
          }
        };
      messageRouter.onMessageExpired = (messageID: string): void => {
        this.markPrivateMessageFailed(messageID);
      };
      this.state.peerId = myPeerId;
      this.state.nickname = this.nickname;
      graph.transport.start();
      graph.peerManager.start();
      graph.announceScheduler.start();
      graph.gossipSync.start();
      graph.gossipSync.scheduleInitialSync();
      await this.refreshConversationSummaries();
      this.securityCleanupTimer = setInterval(() => {
        graph.securityGate.cleanupOldData();
      }, SecurityConstants.CLEANUP_INTERVAL_MS);
      this.fragmentCleanupTimer = setInterval(() => {
        graph.receiveFragments.cleanupOldFragments();
      }, FragmentationConstants.CLEANUP_INTERVAL_MS);
      this.state.serviceRunning = true;
      this.state.connectedCount = graph.transport.getConnectedDeviceCount();
      // US8 (T045): keep the process alive with a BLUETOOTH_INTERACTION
      // continuous task and mirror the count into the persistent
      // notification while the mesh runs.
      BackgroundTaskCoordinator.getInstance().start(this.state.connectedCount);
      // US11 favorites/verification: mirror the store and restore the
      // persisted verified fingerprints before the first render.
      try {
        await FavoritesStore.getInstance().ready();
      } catch (e) {
        // Favorites stay empty; any later change re-mirrors.
      }
      this.refreshFavoritesMirror();
      await this.loadVerifiedFingerprints();
      // US12 Nostr private messages (T060): load the persistent identity,
      // connect the relays and subscribe to our gift-wrap DMs in the
      // background; failures are logged and leave the mesh path untouched.
      this.startNostrPrivateMessaging();
      // US13 (T068): mirror the persisted geohash channel bookmarks
      // before the location-channel sheet first renders.
      this.loadGeohashBookmarks();
      hilog.info(DOMAIN, TAG, 'mesh started, peerId=%{public}s', myPeerId);
    } catch (e) {
      // Allow a later retry (e.g. transient key store failure).
      this.startPromise = null;
      hilog.error(DOMAIN, TAG, 'mesh start failed: %{public}s', JSON.stringify(e));
    }
  }

  /** Insert one entry into the timeline (packet-ID dedup, oldest trimmed). */
  private appendTimeline(packet: BitchatPacket, message: BitchatMessage, nickname: string,
    isMine: boolean): boolean {
    const idHex: string = PacketIdUtil.computeIdHex(packet);
    if (this.timelineIds.has(idHex)) {
      return false;
    }
    this.timelineIds.add(idHex);
    const senderPeerId: string = message.senderPeerId !== null
      ? message.senderPeerId : ByteUtils.bytesToHex(packet.senderId);
    const entry: ChatEntry = new ChatEntry(idHex, senderPeerId, nickname, message.content,
      message.timestamp, isMine);
    let next: ChatEntry[] = this.state.messages.concat([entry]);
    next.sort(ChatViewModel.compareEntries);
    if (next.length > TIMELINE_CAPACITY) {
      next = next.slice(next.length - TIMELINE_CAPACITY);
    }
    if (this.timelineIds.size > TIMELINE_CAPACITY * 2) {
      const retained: Set<string> = new Set();
      for (let i: number = 0; i < next.length; i++) {
        retained.add(next[i].idHex);
      }
      this.timelineIds = retained;
    }
    this.state.messages = next;
    return true;
  }

  private static compareEntries(a: ChatEntry, b: ChatEntry): number {
    if (a.timestampMs !== b.timestampMs) {
      return a.timestampMs - b.timestampMs;
    }
    return a.idHex < b.idHex ? -1 : (a.idHex > b.idHex ? 1 : 0);
  }

  // ------------------------------------------------------------------
  // Channel internals (T049, US9)
  // ------------------------------------------------------------------

  /**
   * Build and broadcast one channel MESSAGE (T049). Plain channels set the
   * channel field only; password-protected channels encrypt the content
   * through the derived PBKDF2+AES-GCM channel key (isEncrypted +
   * encryptedContent on the wire) while the local timeline row keeps the
   * plaintext for display.
   */
  async sendChannelMessage(content: string, channel: string): Promise<boolean> {
    const graph: MeshGraph | null = this.graph;
    const text: string = content.trim();
    const tag: string = ChannelManager.normalizeChannelName(channel);
    if (graph === null || text.length === 0 || !this.channelManager.isJoined(tag)) {
      return false;
    }
    this.state.sending = true;
    try {
      const message: BitchatMessage = new BitchatMessage(this.nickname, text, Date.now());
      message.senderPeerId = graph.myPeerId;
      message.channel = tag;
      if (this.channelManager.isPasswordProtected(tag)) {
        const cipher: Uint8Array | null =
          ChannelEncryption.getInstance().encryptChannelMessage(text, tag);
        if (cipher === null) {
          return false;
        }
        message.isEncrypted = true;
        message.encryptedContent = cipher;
      }
      const payload: Uint8Array | null = message.toBinaryPayload();
      if (payload === null) {
        return false;
      }
      const packet: BitchatPacket = new BitchatPacket(1, MessageType.MESSAGE,
        ByteUtils.hexToBytes(graph.myPeerId), null, message.timestamp, payload, null,
        PkTtl.MESSAGE_TTL_HOPS, null);
      const dataToSign: Uint8Array | null = BinaryProtocol.toBinaryDataForSigning(packet);
      if (dataToSign !== null) {
        const signature: Uint8Array | null = await IdentityManager.getInstance().sign(dataToSign);
        if (signature !== null) {
          packet.signature = signature;
        }
      }
      const idHex: string = PacketIdUtil.computeIdHex(packet);
      const accepted: boolean = this.appendChannelTimeline(idHex, graph.myPeerId,
        this.nickname, text, message.timestamp, true, tag);
      graph.gossipSync.onPublicPacketSeen(packet);
      if (accepted) {
        graph.transport.send(packet);
      }
      return accepted;
    } finally {
      this.state.sending = false;
    }
  }

  /** Receive one channel MESSAGE: decrypt or placeholder, then file it. */
  private handleIncomingChannelMessage(routed: RoutedPacket, message: BitchatMessage,
    channel: string, display: string): void {
    let content: string = message.content;
    if (message.isEncrypted) {
      const cipher: Uint8Array | null = message.encryptedContent;
      const plain: string | null = cipher !== null
        ? ChannelEncryption.getInstance().decryptChannelMessage(cipher, channel)
        : null;
      content = plain !== null ? plain : CHANNEL_ENCRYPTED_PLACEHOLDER;
    }
    const senderPeerId: string = message.senderPeerId !== null
      ? message.senderPeerId : ByteUtils.bytesToHex(routed.packet.senderId);
    const idHex: string = PacketIdUtil.computeIdHex(routed.packet);
    this.appendChannelTimeline(idHex, senderPeerId, display, content,
      message.timestamp, false, channel);
    this.channelManager.addChannelMember(channel, routed.peerID);
  }

  /** Insert one entry into a channel timeline (per-channel dedup + trim). */
  private appendChannelTimeline(idHex: string, senderPeerId: string, nickname: string,
    content: string, timestampMs: number, isMine: boolean, channel: string): boolean {
    let ids: Set<string> | undefined = this.channelTimelineIds.get(channel);
    if (ids === undefined) {
      ids = new Set<string>();
      this.channelTimelineIds.set(channel, ids);
    }
    if (ids.has(idHex)) {
      return false;
    }
    ids.add(idHex);
    const entry: ChatEntry = new ChatEntry(idHex, senderPeerId, nickname, content,
      timestampMs, isMine);
    const existing: ChatEntry[] | undefined = this.state.channelMessages.get(channel);
    let next: ChatEntry[] = existing !== undefined ? existing.concat([entry]) : [entry];
    next.sort(ChatViewModel.compareEntries);
    if (next.length > CHANNEL_TIMELINE_CAPACITY) {
      next = next.slice(next.length - CHANNEL_TIMELINE_CAPACITY);
    }
    if (ids.size > CHANNEL_TIMELINE_CAPACITY * 2) {
      const retained: Set<string> = new Set<string>();
      for (let i: number = 0; i < next.length; i++) {
        retained.add(next[i].idHex);
      }
      this.channelTimelineIds.set(channel, retained);
    }
    this.state.channelMessages.set(channel, next);
    return true;
  }

  /**
   * Leave a channel: membership, creator record and derived key all go
   * (T049 leave button; Android leaveChannel parity). The channel timeline
   * is kept so rejoining restores history.
   */
  leaveChannel(channel: string): boolean {
    const tag: string = ChannelManager.normalizeChannelName(channel);
    const left: boolean = this.channelManager.leaveChannel(tag);
    if (this.state.currentChannel === tag) {
      this.state.currentChannel = '';
    }
    return left;
  }

  /**
   * The channel destination closed (back navigation): the composer target
   * returns to the main timeline but membership is kept (Android parity).
   */
  closeChannelView(): void {
    if (this.state.currentChannel !== '') {
      this.state.currentChannel = '';
    }
  }

  /** Password prompt dismissed (cancel / outside tap / dialog closed). */
  dismissPasswordPrompt(): void {
    this.state.showPasswordPrompt = false;
    this.state.passwordPromptChannel = '';
  }

  // ------------------------------------------------------------------
  // US13 geohash location channels (T068)
  // ------------------------------------------------------------------

  /**
   * Join one geohash location channel (US13): create the geohash kernel
   * with the persisted device seed on first use, connect the relays,
   * open a kind 20000+20001 subscription filtered by the #g tag (1h
   * lookback), publish one presence heartbeat when the level allows
   * broadcasts (REGION/PROVINCE/CITY) and surface the channel as the
   * open one. Idempotent: re-joining a joined channel only re-selects
   * it.
   */
  async joinGeohashChannel(rawGeohash: string): Promise<boolean> {
    const geohash: string = GeohashChannels.normalize(rawGeohash);
    if (!GeohashChannels.isValid(geohash)) {
      return false;
    }
    const service: GeohashService | null = await this.ensureGeohashService();
    if (service === null) {
      return false;
    }
    const shared: NostrRelayManager = NostrRelayManager.shared;
    shared.connect();
    if (!this.joinedGeohashChannels.has(geohash)) {
      const tagFilters: Map<string, string[]> = new Map<string, string[]>();
      tagFilters.set('g', [geohash]);
      const filter: NostrFilter = new NostrFilter(null, null,
        [NostrKind.EPHEMERAL_EVENT, NostrKind.GEOHASH_PRESENCE],
        Math.floor(GeohashService.presenceFilterSinceMs(Date.now()) / 1000),
        null, 100, tagFilters);
      shared.subscribe(filter, ChatViewModel.geohashSubscriptionId(geohash),
        (event: NostrEvent): void => {
          this.handleIncomingGeohashEvent(event);
        }, null, NostrRelayManager.OWNER_BACKGROUND, false);
      this.joinedGeohashChannels.add(geohash);
      // One presence heartbeat on join (privacy: only the coarse levels).
      const level: GeohashChannelLevel = GeohashLevels.levelForLength(geohash.length);
      if (service.presenceBroadcastAllowed(level)) {
        try {
          const presence: NostrEvent = service.createPresenceEvent(geohash);
          this.markGeohashEventSeen(presence.id);
          shared.sendEvent(presence, null);
        } catch (e) {
          // Presence is best-effort; the channel works without it.
        }
      }
    }
    this.state.currentGeohashChannel = geohash;
    return true;
  }

  /**
   * Leave one geohash channel (US13): CLOSE the relay subscription and
   * drop the in-memory presence / timeline state; bookmarks and the
   * persisted state are kept.
   */
  leaveGeohashChannel(rawGeohash: string): void {
    const geohash: string = GeohashChannels.normalize(rawGeohash);
    if (geohash === '') {
      return;
    }
    if (this.joinedGeohashChannels.has(geohash)) {
      NostrRelayManager.shared.unsubscribe(ChatViewModel.geohashSubscriptionId(geohash));
      this.joinedGeohashChannels.delete(geohash);
    }
    this.geohashPresence.delete(geohash);
    this.geohashTimelineIds.delete(geohash);
    this.state.geohashMessages.delete(geohash);
    this.state.geohashParticipantCounts.delete(geohash);
    if (this.state.currentGeohashChannel === geohash) {
      this.state.currentGeohashChannel = '';
    }
  }

  /**
   * The location-channel destination closed (back navigation): the open
   * channel clears but the subscription, presence and history stay
   * (Android closeChannelView parity).
   */
  closeGeohashChannelView(): void {
    if (this.state.currentGeohashChannel !== '') {
      this.state.currentGeohashChannel = '';
    }
  }

  /**
   * Send one message into the open geohash location channel (US13): a
   * kind 20000 ephemeral chat event (g/n tags, t/teleport for
   * globe-joined channels) with a local echo whose event id is marked
   * seen first, so the relay echo never duplicates the row.
   */
  async sendGeohashChannelMessage(content: string): Promise<boolean> {
    const geohash: string = this.state.currentGeohashChannel;
    const text: string = content.trim();
    if (geohash === '' || text.length === 0) {
      return false;
    }
    const service: GeohashService | null = await this.ensureGeohashService();
    if (service === null) {
      return false;
    }
    this.state.sending = true;
    try {
      const event: NostrEvent = service.createChatEvent(text, geohash,
        this.nickname, this.teleportedGeohashes.has(geohash),
        GeohashPowSettings.defaults());
      const entry: ChatEntry = new ChatEntry(event.id,
        service.deriveIdentity(geohash).publicKeyHex, this.nickname, text,
        event.createdAt * 1000, true);
      this.appendGeohashTimeline(geohash, entry);
      this.markGeohashEventSeen(event.id);
      NostrRelayManager.shared.sendEvent(event, null);
      return true;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'geohash channel send failed: %{public}s',
        JSON.stringify(e));
      return false;
    } finally {
      this.state.sending = false;
    }
  }

  /** Toggle the bookmark of one geohash channel (US13); true = added. */
  async toggleGeohashBookmark(rawGeohash: string): Promise<boolean> {
    const geohash: string = GeohashChannels.normalize(rawGeohash);
    if (!GeohashChannels.isValid(geohash)) {
      return false;
    }
    const result: GeohashBookmarkToggle =
      await GeohashBookmarksStore.getInstance().toggle(geohash);
    this.state.geohashBookmarks = GeohashBookmarksStore.getInstance().getList();
    return result.added;
  }

  /** Whether one geohash channel is bookmarked (US13). */
  isGeohashBookmarked(rawGeohash: string): boolean {
    const geohash: string = GeohashChannels.normalize(rawGeohash);
    if (geohash === '') {
      return false;
    }
    return this.state.geohashBookmarks.indexOf(geohash) >= 0;
  }

  /** Mark one channel as globe-joined (t/teleport tag on sends, US13). */
  markGeohashTeleported(rawGeohash: string): void {
    const geohash: string = GeohashChannels.normalize(rawGeohash);
    if (geohash !== '') {
      this.teleportedGeohashes.add(geohash);
    }
  }

  /** Mirror the persisted bookmarks into the state (start(), US13). */
  async loadGeohashBookmarks(): Promise<void> {
    try {
      const list: string[] = await GeohashBookmarksStore.getInstance().ensureLoaded();
      this.state.geohashBookmarks = list.slice(0);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'load geohash bookmarks failed: %{public}s',
        JSON.stringify(e));
    }
  }

  /** Load-or-create the geohash kernel with the persisted seed (US13). */
  private ensureGeohashService(): Promise<GeohashService | null> {
    if (this.geohashService !== null) {
      return Promise.resolve(this.geohashService);
    }
    if (this.geohashServicePromise === null) {
      this.geohashServicePromise = this.doEnsureGeohashService();
    }
    return this.geohashServicePromise;
  }

  private async doEnsureGeohashService(): Promise<GeohashService | null> {
    try {
      const store: SecureKeyStore = SecureKeyStore.getInstance();
      let seed: Uint8Array | null = null;
      try {
        seed = await store.getKey(GEOHASH_DEVICE_SEED_ALIAS);
      } catch (e) {
        seed = null;
      }
      if (seed === null) {
        seed = this.deviceNostrRandom.nextBytes(GEOHASH_DEVICE_SEED_BYTES);
        await store.putKey(GEOHASH_DEVICE_SEED_ALIAS, seed);
      }
      const service: GeohashService = new GeohashService((): number => Date.now(),
        this.deviceNostrRandom, seed);
      this.geohashService = service;
      return service;
    } catch (e) {
      this.geohashServicePromise = null;
      hilog.warn(DOMAIN, TAG, 'geohash service init failed: %{public}s',
        JSON.stringify(e));
      return null;
    }
  }

  /** Relay subscription id of one geohash channel (US13). */
  private static geohashSubscriptionId(geohash: string): string {
    return GEOHASH_SUBSCRIPTION_PREFIX + geohash;
  }

  /** Dedup inbound geohash events (insertion-ordered LRU). True = seen. */
  private markGeohashEventSeen(eventId: string): boolean {
    if (this.seenGeohashEventIdSet.has(eventId)) {
      return true;
    }
    this.seenGeohashEventIdSet.add(eventId);
    this.seenGeohashEventIds.push(eventId);
    if (this.seenGeohashEventIds.length > GEOHASH_SEEN_EVENT_LRU) {
      const evicted: string | undefined = this.seenGeohashEventIds.shift();
      if (evicted !== undefined) {
        this.seenGeohashEventIdSet.delete(evicted);
      }
    }
    return false;
  }

  /**
   * Route one inbound geohash event (US13): accept only events of a
   * joined channel, dedup by event id, drop anything older than the 1h
   * presence window, then refresh presence (kind 20001 and chat both
   * prove it) and file chat text (kind 20000) into the timeline.
   */
  private handleIncomingGeohashEvent(event: NostrEvent): void {
    try {
      const chatGeohash: string | null = GeohashEventRouter.chatGeohash(event);
      const geohash: string = chatGeohash !== null
        ? chatGeohash
        : (GeohashEventRouter.presenceGeohash(event) ?? '');
      if (geohash === '' || !this.joinedGeohashChannels.has(geohash)) {
        return;
      }
      if (this.markGeohashEventSeen(event.id)) {
        return;
      }
      const nowMs: number = Date.now();
      if (nowMs - event.createdAt * 1000 > GeohashService.PRESENCE_LOOKBACK_MS) {
        return;
      }
      this.recordGeohashPresence(geohash, event.pubkey, nowMs);
      if (chatGeohash !== null) {
        const nickname: string = GeohashEventRouter.nicknameOf(event);
        const entry: ChatEntry = new ChatEntry(event.id, event.pubkey,
          nickname !== '' ? nickname : 'anon', event.content,
          event.createdAt * 1000, false);
        this.appendGeohashTimeline(geohash, entry);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'geohash event handling failed: %{public}s',
        JSON.stringify(e));
    }
  }

  /** Record one presence sighting and refresh the live count (US13). */
  private recordGeohashPresence(geohash: string, pubkey: string, nowMs: number): void {
    let channel: Map<string, number> | undefined = this.geohashPresence.get(geohash);
    if (channel === undefined) {
      channel = new Map<string, number>();
      this.geohashPresence.set(geohash, channel);
    }
    channel.set(pubkey, nowMs);
    // Prune the 1h window and publish the count (self excluded: own
    // events are deduped at send time and never reach this path).
    const expired: string[] = [];
    let count: number = 0;
    channel.forEach((seenAt: number, key: string) => {
      if (nowMs - seenAt > GeohashService.PRESENCE_LOOKBACK_MS) {
        expired.push(key);
      } else {
        count += 1;
      }
    });
    for (let i: number = 0; i < expired.length; i++) {
      channel.delete(expired[i]);
    }
    this.state.geohashParticipantCounts.set(geohash, count);
  }

  /** Insert one entry into a geohash timeline (dedup + trim, US13). */
  private appendGeohashTimeline(geohash: string, entry: ChatEntry): boolean {
    let ids: Set<string> | undefined = this.geohashTimelineIds.get(geohash);
    if (ids === undefined) {
      ids = new Set<string>();
      this.geohashTimelineIds.set(geohash, ids);
    }
    if (ids.has(entry.idHex)) {
      return false;
    }
    ids.add(entry.idHex);
    const existing: ChatEntry[] | undefined = this.state.geohashMessages.get(geohash);
    let next: ChatEntry[] = existing !== undefined ? existing.concat([entry]) : [entry];
    next.sort(ChatViewModel.compareEntries);
    if (next.length > GEOHASH_TIMELINE_CAPACITY) {
      next = next.slice(next.length - GEOHASH_TIMELINE_CAPACITY);
    }
    this.state.geohashMessages.set(geohash, next);
    return true;
  }

  // ------------------------------------------------------------------
  // Private-chat internals
  // ------------------------------------------------------------------

  /** Build and broadcast one addressed Noise packet (unsigned, Android/iOS parity). */
  private sendNoisePacket(type: MessageType, payload: Uint8Array,
    recipientPeerID: string): boolean {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return false;
    }
    const packet: BitchatPacket = new BitchatPacket(1, type,
      ByteUtils.hexToBytes(graph.myPeerId), ByteUtils.hexToBytes(recipientPeerID),
      Date.now(), payload, null, PkTtl.MESSAGE_TTL_HOPS, null);
    return graph.transport.send(packet);
  }

  /**
   * Live PTT egress (US14, T069), mirror of MeshCore.sendVoiceFrame: a null
   * recipient broadcasts one signed VOICE_FRAME (SecurityGate signed set),
   * a DM peer requires an established Noise session and rides the unsigned
   * NOISE_ENCRYPTED transport like every other private payload.
   */
  sendVoiceFrame(recipientPeerID: string | null, payload: Uint8Array): boolean {
    const graph: MeshGraph | null = this.graph;
    if (graph === null || payload.length === 0) {
      return false;
    }
    if (recipientPeerID === null) {
      const packet: BitchatPacket = new BitchatPacket(1, MessageType.VOICE_FRAME,
        ByteUtils.hexToBytes(graph.myPeerId), specialRecipientBroadcast(), Date.now(),
        payload, null, PkTtl.MESSAGE_TTL_HOPS, null);
      const dataToSign: Uint8Array | null = BinaryProtocol.toBinaryDataForSigning(packet);
      if (dataToSign !== null) {
        const signature: Uint8Array | null = IdentityManager.getInstance().signSync(dataToSign);
        if (signature !== null) {
          packet.signature = signature;
        }
      }
      return graph.transport.send(packet);
    }
    if (!graph.noiseSessions.hasEstablishedSession(recipientPeerID)) {
      return false;
    }
    try {
      const encrypted: Uint8Array = graph.noiseSessions.encrypt(
        new NoisePayload(NoisePayloadType.VOICE_FRAME, payload).encode(), recipientPeerID);
      return this.sendNoisePacket(MessageType.NOISE_ENCRYPTED, encrypted, recipientPeerID);
    } catch (e) {
      return false;
    }
  }

  /** DELIVERED / READ_RECEIPT: [type][messageID utf8], Noise-encrypted back. */
  private sendNoiseReceipt(type: NoisePayloadType, messageID: string, peerID: string): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    try {
      const encrypted: Uint8Array = graph.noiseSessions.encrypt(
        new NoisePayload(type, ByteUtils.utf8Encode(messageID)).encode(), peerID);
      this.sendNoisePacket(MessageType.NOISE_ENCRYPTED, encrypted, peerID);
    } catch (e) {
      // Receipts are best-effort; the peer re-requests on next contact.
    }
  }

  /** PRIVATE_MESSAGE: persist, publish and acknowledge delivery (iOS parity). */
  private handleIncomingPrivateMessage(routed: RoutedPacket, data: Uint8Array): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    const privateMessage: PrivateMessagePacket | null = PrivateMessagePacket.decode(data);
    if (privateMessage === null) {
      return;
    }
    // Favorite notice (US11): intercepted before any persistence, display
    // or acknowledgment (Android MessageHandler parity).
    const favoriteNotice: FavoriteControlMessage | null =
      FavoriteControlMessage.parse(privateMessage.content);
    if (favoriteNotice !== null) {
      this.handleIncomingFavoriteNotice(routed, favoriteNotice);
      return;
    }
    const conversationID: string = routed.peerID;
    // /block: a blocked peer's private message is dropped entirely (T039).
    if (this.blockedPeerIds.has(conversationID)) {
      return;
    }
    const isOpen: boolean = this.state.selectedConversationId === conversationID;
    // Preserve the source packet timestamp (Android MessageHandler parity).
    const message: BitchatMessage = new BitchatMessage(
      this.getConversationDisplayName(conversationID), privateMessage.content,
      routed.packet.timestamp);
    message.id = privateMessage.messageID;
    message.isPrivate = true;
    message.recipientNickname = this.nickname;
    message.senderPeerId = conversationID;
    // New-message notification (T046): grouped per conversation, suppressed
    // only while the app is foregrounded with this chat on screen.
    MessageNotificationDispatcher.getInstance().notifyPrivateMessage(
      conversationID, message.sender, privateMessage.content, isOpen);
    ConversationStore.getInstance().appendMessage(conversationID, message, isOpen)
      .then((): void => {
        this.publishPrivateMessage(message, graph.myPeerId, isOpen);
      })
      .catch((): void => {
        // Continue in memory when the store fails; history is not fatal.
        this.publishPrivateMessage(message, graph.myPeerId, isOpen);
      });
    this.sendNoiseReceipt(NoisePayloadType.DELIVERED, privateMessage.messageID,
      conversationID);
    if (isOpen) {
      this.sentReadReceipts.add(privateMessage.messageID);
      this.sendNoiseReceipt(NoisePayloadType.READ_RECEIPT, privateMessage.messageID,
        conversationID);
    }
  }

  /** Surface one stored incoming message in the open chat and the list. */
  private publishPrivateMessage(message: BitchatMessage, myPeerId: string,
    wasOpen: boolean): void {
    if (wasOpen) {
      this.state.privateMessages = this.state.privateMessages.concat([
        this.toPrivateEntry(message, myPeerId, true)]);
    }
    this.bumpConversationSummary(message.senderPeerId ?? '', message, !wasOpen);
  }

  // ------------------------------------------------------------------
  // US11 favorites + QR identity verification
  // ------------------------------------------------------------------

  /** Ed25519 verifier for the pure VerificationService (cryptoFramework sync). */
  private static readonly signatureVerifier: SignatureVerifier =
    (signature: Uint8Array, data: Uint8Array, publicKey: Uint8Array): boolean => {
      return IdentityManager.getInstance().verifySync(signature, data, publicKey);
    };

  /** 16-byte challenge nonce source (plan.md: nonce 16B). */
  private static readonly nonceFactory: NonceFactory = (): Uint8Array => {
    return cryptoFramework.createRandom().generateRandomSync(VERIFY_NONCE_LENGTH).data;
  };

  /** Toggle our-favorite for one conversation, then notify the peer (US11). */
  toggleFavorite(conversationID: string): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null || conversationID === '' || conversationID === graph.myPeerId) {
      return;
    }
    const noiseKey: Uint8Array | null = this.noiseKeyForConversation(conversationID);
    if (noiseKey === null) {
      return;
    }
    const store: FavoritesStore = FavoritesStore.getInstance();
    const current: FavoriteRelationship | null = store.getFavoriteStatusForNoiseKey(noiseKey);
    const newFavorite: boolean = current === null ? true : !current.isFavorite;
    const displayName: string = this.getConversationDisplayName(conversationID);
    store.updateFavoriteStatus(noiseKey, displayName, newFavorite);
    this.refreshFavoritesMirror();
    // Notify the peer inside a normal private message, only over an
    // established session (Android sendFavoriteNotification parity).
    if (graph.noiseSessions.hasEstablishedSession(conversationID)) {
      try {
        this.sendPrivateMessage(FavoriteControlMessage.encode(newFavorite, null),
          conversationID, displayName, null);
      } catch (e) {
        // Best-effort notice; the stored relationship stays authoritative.
      }
    }
    // US12 (T060): repeat the notice over Nostr when the transport is up
    // (best-effort, not gated on canSendViaNostr; Android parity).
    const nostrTransport: NostrTransport | null = this.nostrTransport;
    if (nostrTransport !== null) {
      try {
        nostrTransport.sendFavoriteNotification(conversationID, newFavorite);
      } catch (e) {
        // Best-effort notice; the stored relationship stays authoritative.
      }
    }
  }

  /** True when we favorited this conversation's identity (US11). */
  isConversationFavorited(conversationID: string): boolean {
    const fingerprint: string | null = this.conversationFingerprint(conversationID);
    return fingerprint !== null && this.state.favoritedFingerprints.has(fingerprint);
  }

  /** True when this conversation's identity favorited us (US11). */
  hasPeerFavoritedUs(conversationID: string): boolean {
    const fingerprint: string | null = this.conversationFingerprint(conversationID);
    return fingerprint !== null && this.state.peerFavoritedUsFingerprints.has(fingerprint);
  }

  /** True when both sides favorited each other (US11). */
  isFavoriteMutual(conversationID: string): boolean {
    return this.isConversationFavorited(conversationID) &&
      this.hasPeerFavoritedUs(conversationID);
  }

  /** True when this conversation's identity passed QR verification (US11). */
  isConversationVerified(conversationID: string): boolean {
    const fingerprint: string | null = this.conversationFingerprint(conversationID);
    return fingerprint !== null && this.state.verifiedFingerprints.has(fingerprint);
  }

  /** SHA-256 fingerprint hex of the conversation's Noise key (display, US11). */
  getConversationFingerprint(conversationID: string): string | null {
    return this.conversationFingerprint(conversationID);
  }

  /** Signed "my QR" deep link; cached for QR_CACHE_MS (US11). */
  buildMyVerificationQR(): string | null {
    return VerificationService.buildMyQRString(ChatViewModel.identitySigner,
      this.nickname, null, Date.now(), ChatViewModel.nonceFactory);
  }

  /**
   * A scanned peer QR (US11): verify the signature + freshness, match the
   * Noise key to a known peer, then fire the 0x10 challenge (directly or
   * once the session establishes). Returns true when the handshake started.
   */
  beginQRVerification(scannedUrl: string): boolean {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return false;
    }
    const qr: VerificationQR | null = VerificationService.verifyScannedQR(
      scannedUrl, Date.now(), ChatViewModel.signatureVerifier);
    if (qr === null) {
      return false;
    }
    const peerID: string | null = this.findPeerIDForNoiseKeyHex(qr.noiseKeyHex);
    if (peerID === null) {
      return false;
    }
    this.state.verificationPendingPeerId = peerID;
    if (graph.noiseSessions.hasEstablishedSession(peerID)) {
      this.sendVerifyChallengeNow(peerID, qr);
    } else {
      this.pendingQrIntents.set(peerID, qr);
      this.initiateNoiseHandshake(peerID);
    }
    return true;
  }

  /** Remove the verified mark of one conversation (VerificationSheet unverify). */
  unverifyConversation(conversationID: string): void {
    const fingerprint: string | null = this.conversationFingerprint(conversationID);
    if (fingerprint === null) {
      return;
    }
    const next: Set<string> = new Set<string>(this.state.verifiedFingerprints);
    next.delete(fingerprint);
    this.state.verifiedFingerprints = next;
    this.persistVerifiedFingerprints();
  }

  // ------------------------------------------------------------------
  // FavoritesChangeListener (US11)
  // ------------------------------------------------------------------

  onFavoriteChanged(noiseKeyHex: string): void {
    this.refreshFavoritesMirror();
    // US12 (T060): a gained or lost Nostr pubkey can unlock queued
    // private messages; flush under the noise key and the stored peer ID.
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    graph.messageRouter.flushOutboxFor(noiseKeyHex);
    const peerID: string | null = this.findPeerIDForNoiseKeyHex(noiseKeyHex);
    if (peerID !== null) {
      graph.messageRouter.flushOutboxFor(peerID);
    }
  }

  onAllCleared(): void {
    this.state.favoritedFingerprints = new Set<string>();
    this.state.peerFavoritedUsFingerprints = new Set<string>();
  }

  // ------------------------------------------------------------------
  // US11 internals
  // ------------------------------------------------------------------

  /** Rebuild the @Trace fingerprint mirrors from the FavoritesStore. */
  private refreshFavoritesMirror(): void {
    const favorited: Set<string> = new Set<string>();
    const peerFavoritedUs: Set<string> = new Set<string>();
    const relationships: FavoriteRelationship[] =
      FavoritesStore.getInstance().getAllRelationships();
    for (let i: number = 0; i < relationships.length; i++) {
      const fingerprint: string =
        ContactIdentityResolver.fingerprintHex(relationships[i].peerNoisePublicKey);
      if (relationships[i].isFavorite) {
        favorited.add(fingerprint);
      }
      if (relationships[i].theyFavoritedUs) {
        peerFavoritedUs.add(fingerprint);
      }
    }
    this.state.favoritedFingerprints = favorited;
    this.state.peerFavoritedUsFingerprints = peerFavoritedUs;
  }

  /** Resolve the peer Noise static key behind any conversation alias (US11). */
  private noiseKeyForConversation(conversationID: string): Uint8Array | null {
    const graph: MeshGraph | null = this.graph;
    if (graph !== null) {
      const info: PeerInfo | null = graph.peerManager.getPeerInfo(conversationID);
      if (info !== null && info.noisePublicKey !== null) {
        return info.noisePublicKey;
      }
      const session: AuthenticatedNoiseSession | null =
        graph.noiseSessions.getAuthenticatedSession(conversationID);
      if (session !== null) {
        return session.getRemoteStaticKey();
      }
    }
    if (ContactIdentityResolver.isNoiseKeyHex(conversationID)) {
      return ContactIdentityResolver.bytesFromHex(conversationID);
    }
    const relationship: FavoriteRelationship | null =
      FavoritesStore.getInstance().getFavoriteStatus(conversationID);
    return relationship !== null ? relationship.peerNoisePublicKey : null;
  }

  /** Fingerprint of the conversation identity; null when unresolvable (US11). */
  private conversationFingerprint(conversationID: string): string | null {
    const fromContact: string | null =
      ContactIdentityResolver.fingerprintFromContactConversationId(conversationID);
    if (fromContact !== null) {
      return fromContact;
    }
    const noiseKey: Uint8Array | null = this.noiseKeyForConversation(conversationID);
    return noiseKey === null ? null : ContactIdentityResolver.fingerprintHex(noiseKey);
  }

  /** Restore the persisted verified-fingerprint array (US11). */
  private async loadVerifiedFingerprints(): Promise<void> {
    try {
      const raw: string = await PreferenceStore.getInstance()
        .getString(VERIFIED_FINGERPRINTS_KEY, '');
      if (raw === '') {
        return;
      }
      let parsed: string[] | null = null;
      try {
        parsed = JSON.parse(raw) as string[];
      } catch (e) {
        return;
      }
      if (parsed === null || !Array.isArray(parsed)) {
        return;
      }
      const restored: Set<string> = new Set<string>();
      for (let i: number = 0; i < parsed.length; i++) {
        if (typeof parsed[i] === 'string' && parsed[i] !== '') {
          restored.add(parsed[i]);
        }
      }
      this.state.verifiedFingerprints = restored;
    } catch (e) {
      // Verified marks are lost, not fatal; a re-scan restores them.
    }
  }

  private persistVerifiedFingerprints(): void {
    const fingerprints: string[] = Array.from(this.state.verifiedFingerprints);
    PreferenceStore.getInstance()
      .setString(VERIFIED_FINGERPRINTS_KEY, JSON.stringify(fingerprints))
      .catch((): void => {
        hilog.warn(DOMAIN, TAG, '%{public}s', 'persist verified fingerprints failed');
      });
  }

  /**
   * Inbound favorite notice (US11): flip "they favorited us" for the
   * authenticated session's Noise key and record any npub mapping.
   */
  private handleIncomingFavoriteNotice(routed: RoutedPacket,
    notice: FavoriteControlMessage): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    const noiseKey: Uint8Array | null = this.noiseKeyForConversation(routed.peerID);
    if (noiseKey === null) {
      return;
    }
    const store: FavoritesStore = FavoritesStore.getInstance();
    store.updatePeerFavoritedUs(noiseKey, notice.isFavorite);
    if (notice.npub !== null) {
      store.updateNostrPublicKey(noiseKey, notice.npub);
      store.updateNostrPublicKeyForPeerID(routed.peerID, notice.npub);
    }
  }

  // ------------------------------------------------------------------
  // US12 Nostr private messages (T060)
  // ------------------------------------------------------------------

  /**
   * Load/create the persistent Nostr identity, connect the relays and
   * subscribe to our NIP-17 gift wraps (48h lookback). Failures are
   * logged and leave the mesh path untouched; re-running after a panic
   * restart is idempotent (same subscription id, cached identity).
   */
  private async startNostrPrivateMessaging(): Promise<void> {
    try {
      const identity: NostrIdentity =
        await NostrIdentityStore.getInstance().getOrCreate();
      this.currentNostrIdentity = identity;
      const shared: NostrRelayManager = NostrRelayManager.shared;
      shared.connect();
      const filter: NostrFilter = NostrFilter.giftWrapsFor(identity.publicKeyHex,
        Date.now() - NOSTR_SUBSCRIPTION_LOOKBACK_MS);
      shared.subscribe(filter, NOSTR_DM_SUBSCRIPTION_ID,
        (event: NostrEvent): void => {
          this.handleIncomingNostrGiftWrap(event);
        }, null, NostrRelayManager.OWNER_BACKGROUND, false);
      hilog.info(DOMAIN, TAG, 'nostr private messaging started, npub=%{public}s',
        identity.npub);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'nostr private messaging start failed: %{public}s',
        JSON.stringify(e));
    }
  }

  /** Dedup inbound gift-wrap events (insertion-ordered LRU). True = seen. */
  private markNostrEventSeen(eventId: string): boolean {
    if (this.seenNostrEventIdSet.has(eventId)) {
      return true;
    }
    this.seenNostrEventIdSet.add(eventId);
    this.seenNostrEventIds.push(eventId);
    if (this.seenNostrEventIds.length > NOSTR_SEEN_EVENT_LRU) {
      const evicted: string | undefined = this.seenNostrEventIds.shift();
      if (evicted !== undefined) {
        this.seenNostrEventIdSet.delete(evicted);
      }
    }
    return false;
  }

  /**
   * Inbound NIP-17 gift wrap (US12): dedup + age check, unwrap, decode
   * the "bitchat1:" packet and dispatch by Noise payload type (private
   * message / favorite notice via the PM path, DELIVERED / READ receipts
   * onto the status ladder). Every inbound gift wrap is acked with the
   * no-recipient (geohash) variants (Android NostrDirectMessageHandler
   * parity); senders without a favorite relationship are dropped.
   */
  private handleIncomingNostrGiftWrap(event: NostrEvent): void {
    try {
      if (this.markNostrEventSeen(event.id)) {
        return;
      }
      const nowSeconds: number = Math.floor(Date.now() / 1000);
      if (nowSeconds - event.createdAt > NOSTR_GIFT_WRAP_MAX_AGE_SECONDS) {
        return;
      }
      const identity: NostrIdentity | null = this.currentNostrIdentity;
      if (identity === null) {
        return;
      }
      const decrypted: DecryptedPrivateMessage | null =
        NostrProtocol.decryptPrivateMessage(event, identity);
      if (decrypted === null) {
        return;
      }
      const embedded: EmbeddedBitChatMessage | null =
        NostrEmbeddedBitChat.decodeEmbedded(decrypted.content);
      if (embedded === null) {
        return;
      }
      const senderPubkey: string = decrypted.senderPubkey.toLowerCase();
      const noiseKey: Uint8Array | null =
        FavoritesStore.getInstance().findNoiseKey(senderPubkey);
      if (noiseKey === null) {
        return;
      }
      const conversationID: string = ContactIdentityResolver.peerIdForNoiseKey(noiseKey);
      const payload: NoisePayload = embedded.payload;
      if (payload.type === NoisePayloadType.PRIVATE_MESSAGE) {
        this.handleIncomingNostrPrivateMessage(payload.data, conversationID,
          senderPubkey, decrypted.createdAt);
      } else if (payload.type === NoisePayloadType.DELIVERED) {
        this.applyDeliveryTransition(ByteUtils.utf8Decode(payload.data),
          DeliveryStatusKind.DELIVERED);
      } else if (payload.type === NoisePayloadType.READ_RECEIPT) {
        this.applyDeliveryTransition(ByteUtils.utf8Decode(payload.data),
          DeliveryStatusKind.READ);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'nostr gift wrap handling failed: %{public}s',
        JSON.stringify(e));
    }
  }

  /**
   * Inbound private message over Nostr (US12): favorite notices are
   * intercepted before any persistence, blocked peers are dropped, then
   * the message is notified, persisted and published with the rumor
   * timestamp, and acked (DELIVERED always, READ when the conversation
   * is open) via the no-recipient variants.
   */
  private handleIncomingNostrPrivateMessage(data: Uint8Array, conversationID: string,
    senderPubkey: string, createdAtSeconds: number): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    const privateMessage: PrivateMessagePacket | null = PrivateMessagePacket.decode(data);
    if (privateMessage === null) {
      return;
    }
    const favoriteNotice: FavoriteControlMessage | null =
      FavoriteControlMessage.parse(privateMessage.content);
    if (favoriteNotice !== null) {
      this.handleIncomingNostrFavoriteNotice(favoriteNotice, senderPubkey,
        privateMessage.messageID);
      return;
    }
    if (this.blockedPeerIds.has(conversationID)) {
      return;
    }
    const isOpen: boolean = this.state.selectedConversationId === conversationID;
    const message: BitchatMessage = new BitchatMessage(
      this.getConversationDisplayName(conversationID), privateMessage.content,
      createdAtSeconds * 1000);
    message.id = privateMessage.messageID;
    message.isPrivate = true;
    message.recipientNickname = this.nickname;
    message.senderPeerId = conversationID;
    message.senderNostrPubkey = senderPubkey;
    MessageNotificationDispatcher.getInstance().notifyPrivateMessage(
      conversationID, message.sender, privateMessage.content, isOpen);
    ConversationStore.getInstance().appendMessage(conversationID, message, isOpen)
      .then((): void => {
        this.publishPrivateMessage(message, graph.myPeerId, isOpen);
      })
      .catch((): void => {
        // Continue in memory when the store fails; history is not fatal.
        this.publishPrivateMessage(message, graph.myPeerId, isOpen);
      });
    const transport: NostrTransport | null = this.nostrTransport;
    if (transport !== null) {
      transport.sendDeliveryAckNoRecipient(privateMessage.messageID, senderPubkey);
      if (isOpen) {
        this.sentReadReceipts.add(privateMessage.messageID);
        transport.sendReadReceiptNoRecipient(privateMessage.messageID, senderPubkey);
      }
    }
  }

  /** Inbound favorite notice over Nostr (US12): update the store + ack. */
  private handleIncomingNostrFavoriteNotice(notice: FavoriteControlMessage,
    senderPubkey: string, messageID: string): void {
    const store: FavoritesStore = FavoritesStore.getInstance();
    const noiseKey: Uint8Array | null = store.findNoiseKey(senderPubkey);
    if (noiseKey === null) {
      return;
    }
    store.updatePeerFavoritedUs(noiseKey, notice.isFavorite);
    if (notice.npub !== null) {
      store.updateNostrPublicKey(noiseKey, notice.npub);
      store.updateNostrPublicKeyForPeerID(
        ContactIdentityResolver.peerIdForNoiseKey(noiseKey), notice.npub);
    }
    const transport: NostrTransport | null = this.nostrTransport;
    if (transport !== null) {
      transport.sendDeliveryAckNoRecipient(messageID, senderPubkey);
    }
  }

  /** 0x10 VERIFY_CHALLENGE (US11): auto-respond when it targets our key. */
  private handleVerifyChallenge(routed: RoutedPacket, data: Uint8Array): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    const challenge: VerifyChallenge | null = VerificationService.parseVerifyChallenge(data);
    if (challenge === null) {
      return;
    }
    const myNoiseHex: string = ContactIdentityResolver.noiseKeyHex(
      IdentityManager.getInstance().getStaticPublicKey());
    if (challenge.noiseKeyHex.trim().toLowerCase() !== myNoiseHex) {
      return;
    }
    const response: Uint8Array | null = VerificationService.buildVerifyResponse(
      ChatViewModel.identitySigner, challenge.noiseKeyHex, challenge.nonceA);
    if (response === null) {
      return;
    }
    try {
      const encrypted: Uint8Array = graph.noiseSessions.encrypt(
        new NoisePayload(NoisePayloadType.VERIFY_RESPONSE, response).encode(),
        routed.peerID);
      this.sendNoisePacket(MessageType.NOISE_ENCRYPTED, encrypted, routed.peerID);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'verify response send failed: %{public}s',
        JSON.stringify(e));
    }
  }

  /** 0x11 VERIFY_RESPONSE (US11): verify + mark the scanner-side identity. */
  private handleVerifyResponse(routed: RoutedPacket, data: Uint8Array): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    const pending: PendingVerification | undefined =
      this.pendingVerifications.get(routed.peerID);
    if (pending === undefined) {
      return;
    }
    const response: VerifyResponse | null = VerificationService.parseVerifyResponse(data);
    if (response === null) {
      return;
    }
    if (response.noiseKeyHex.trim().toLowerCase() !== pending.noiseKeyHex.toLowerCase()) {
      return;
    }
    if (!ByteUtils.equals(response.nonceA, pending.nonceA)) {
      return;
    }
    const verified: boolean = VerificationService.verifyResponseSignature(
      response.noiseKeyHex, response.nonceA, response.signature,
      pending.signKeyHex, ChatViewModel.signatureVerifier);
    if (!verified) {
      return;
    }
    this.pendingVerifications.delete(routed.peerID);
    if (this.state.verificationPendingPeerId === routed.peerID) {
      this.state.verificationPendingPeerId = '';
    }
    const noiseKey: Uint8Array | null =
      ContactIdentityResolver.bytesFromHex(pending.noiseKeyHex);
    if (noiseKey === null) {
      return;
    }
    const fingerprint: string = ContactIdentityResolver.fingerprintHex(noiseKey);
    const next: Set<string> = new Set<string>(this.state.verifiedFingerprints);
    next.add(fingerprint);
    this.state.verifiedFingerprints = next;
    this.persistVerifiedFingerprints();
    if (pending.npub !== null) {
      FavoritesStore.getInstance().updateNostrPublicKey(noiseKey, pending.npub);
      FavoritesStore.getInstance().updateNostrPublicKeyForPeerID(routed.peerID,
        pending.npub);
    }
    hilog.info(DOMAIN, TAG, 'peer verified via QR: %{public}s', fingerprint);
  }

  /** Fire the 0x10 challenge over the established session (US11). */
  private sendVerifyChallengeNow(peerID: string, qr: VerificationQR): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null || !graph.noiseSessions.hasEstablishedSession(peerID)) {
      return;
    }
    const nonceA: Uint8Array = ChatViewModel.nonceFactory();
    const challenge: Uint8Array = VerificationService.buildVerifyChallenge(
      qr.noiseKeyHex, nonceA);
    try {
      const encrypted: Uint8Array = graph.noiseSessions.encrypt(
        new NoisePayload(NoisePayloadType.VERIFY_CHALLENGE, challenge).encode(),
        peerID);
      this.sendNoisePacket(MessageType.NOISE_ENCRYPTED, encrypted, peerID);
      this.pendingVerifications.set(peerID,
        new PendingVerification(qr.noiseKeyHex, qr.signKeyHex, qr.npub, nonceA));
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'verify challenge send failed: %{public}s',
        JSON.stringify(e));
    }
  }

  /** Match a QR's Noise key hex to a connected/known peer ID (US11). */
  private findPeerIDForNoiseKeyHex(targetHex: string): string | null {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return null;
    }
    const target: string = targetHex.trim().toLowerCase();
    const candidates: string[] = graph.transport.getConnectedPeerIds()
      .concat(graph.peerManager.getVerifiedPeerIds());
    const seen: Set<string> = new Set<string>();
    for (let i: number = 0; i < candidates.length; i++) {
      const peerID: string = candidates[i];
      if (seen.has(peerID) || peerID === graph.myPeerId) {
        continue;
      }
      seen.add(peerID);
      const info: PeerInfo | null = graph.peerManager.getPeerInfo(peerID);
      if (info !== null && info.noisePublicKey !== null &&
        ContactIdentityResolver.noiseKeyHex(info.noisePublicKey) === target) {
        return peerID;
      }
      const session: AuthenticatedNoiseSession | null =
        graph.noiseSessions.getAuthenticatedSession(peerID);
      if (session !== null &&
        ContactIdentityResolver.noiseKeyHex(session.getRemoteStaticKey()) === target) {
        return peerID;
      }
    }
    // Not announced/connected: fall back to the derived mesh peer ID when
    // a Noise session already runs under it.
    const derived: string | null = ContactIdentityResolver.peerIdForNoiseKeyHex(target);
    if (derived !== null && graph.noiseSessions.hasEstablishedSession(derived)) {
      return derived;
    }
    return null;
  }

  // ------------------------------------------------------------------
  // US10 private media (T053)
  // ------------------------------------------------------------------

  /** Picker entry: read the picked file, stage it, submit a secure send. */
  sendPrivateMediaFromPicker(uri: string, displayName: string, isImage: boolean): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    const conversationID: string = this.state.selectedConversationId;
    if (conversationID === '' || this.blockedPeerIds.has(conversationID)) {
      return;
    }
    let raw: Uint8Array = new Uint8Array(0);
    try {
      raw = ChatViewModel.readAllBytes(uri);
    } catch (e) {
      raw = new Uint8Array(0);
    }
    if (raw.length === 0) {
      this.addPrivateSystemMessage(conversationID, '无法读取所选文件');
      return;
    }
    if (!MediaFileStore.getInstance().isWithinTransferQuota(raw.length)) {
      this.addPrivateSystemMessage(conversationID, '文件超出私有媒体大小上限');
      return;
    }
    if (isImage) {
      this.prepareImageMediaForSending(conversationID, displayName, raw);
      return;
    }
    const persistedPath: string | null =
      MediaFileStore.getInstance().saveOutgoingFile(displayName, raw);
    if (persistedPath === null) {
      this.addPrivateSystemMessage(conversationID, '无法保存所选文件');
      return;
    }
    this.submitPrivateMediaFile(conversationID, displayName,
      ChatViewModel.mimeForFileName(displayName), raw, persistedPath);
  }

  /** Image branch: stage, downscale (EXIF-baked), then submit the JPEG. */
  private async prepareImageMediaForSending(conversationID: string, fileName: string,
    raw: Uint8Array): Promise<void> {
    const store: MediaFileStore = MediaFileStore.getInstance();
    const stagedPath: string | null = store.stageTempFile(fileName, raw);
    if (stagedPath === null) {
      this.addPrivateSystemMessage(conversationID, '无法读取所选图片');
      return;
    }
    let outPath: string | null = null;
    try {
      outPath = await store.downscaleImageForSending(stagedPath);
    } catch (e) {
      outPath = null;
    }
    store.deleteTempFile(stagedPath);
    if (outPath === null) {
      this.addPrivateSystemMessage(conversationID, '无法处理所选图片');
      return;
    }
    let content: Uint8Array = new Uint8Array(0);
    try {
      content = ChatViewModel.readAllBytes(outPath);
    } catch (e) {
      content = new Uint8Array(0);
    }
    if (content.length === 0) {
      this.addPrivateSystemMessage(conversationID, '无法处理所选图片');
      return;
    }
    if (!store.isWithinTransferQuota(content.length)) {
      this.addPrivateSystemMessage(conversationID, '文件超出私有媒体大小上限');
      return;
    }
    this.submitPrivateMediaFile(conversationID, fileName, 'image/jpeg',
      content, outPath);
  }

  /** Encode + hash, then hand the file to the intent manager (single slot). */
  private submitPrivateMediaFile(conversationID: string, fileName: string,
    mimeType: string, content: Uint8Array, persistedPath: string): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    const filePacket: BitchatFilePacket =
      new BitchatFilePacket(fileName, content.length, mimeType, content);
    const encoded: Uint8Array | null = filePacket.encode();
    if (encoded === null) {
      this.addPrivateSystemMessage(conversationID, '无法编码所选文件');
      return;
    }
    const transferId: string = ByteUtils.sha256Hex(encoded);
    graph.mediaIntents.submitPrivateMedia(conversationID, conversationID,
      filePacket, persistedPath, MediaFileStore.messageTypeForMime(mimeType),
      transferId);
    this.syncConsentPrompt();
  }

  /** The receiver-side content bound checked before any disk write. */
  private static exceedsPrivateMediaReceiveBound(sizeBytes: number): boolean {
    const bound: number = FragmentationConstants.MAX_FRAGMENTS_PER_ID *
      FragmentationConstants.MAX_FRAGMENT_SIZE;
    return sizeBytes <= 0 || sizeBytes > bound;
  }

  /** Noise 0x20 FILE_TRANSFER: verify, save to cacheDir, publish + ack. */
  private handleIncomingPrivateMedia(routed: RoutedPacket, data: Uint8Array): void {
    const filePacket: BitchatFilePacket | null = BitchatFilePacket.decode(data);
    if (filePacket === null) {
      return;
    }
    this.publishIncomingPrivateMedia(routed, filePacket, false);
  }

  /** Legacy signed directed 0x22 FILE_TRANSFER (SecurityGate pre-verified). */
  private handleIncomingDirectedFileTransfer(routed: RoutedPacket): void {
    const filePacket: BitchatFilePacket | null =
      BitchatFilePacket.decode(routed.packet.payload);
    if (filePacket === null) {
      return;
    }
    this.publishIncomingPrivateMedia(routed, filePacket, true);
  }

  /**
   * Shared receive path: bound-check BEFORE saveIncomingFile, persist +
   * publish the media row, then DELIVERED (+READ when open) receipts.
   * Legacy rows carry the non-end-to-end-encrypted tag and get no receipt
   * (an older client cannot decode Noise payloads).
   */
  private publishIncomingPrivateMedia(routed: RoutedPacket,
    filePacket: BitchatFilePacket, legacy: boolean): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    const conversationID: string = routed.peerID;
    if (conversationID === graph.myPeerId ||
      this.blockedPeerIds.has(conversationID)) {
      return;
    }
    if (ChatViewModel.exceedsPrivateMediaReceiveBound(filePacket.content.length)) {
      return;
    }
    const savedPath: string | null = MediaFileStore.getInstance().saveIncomingFile(
      filePacket.fileName, filePacket.fileSize, filePacket.mimeType,
      filePacket.content);
    if (savedPath === null) {
      return;
    }
    const isOpen: boolean = this.state.selectedConversationId === conversationID;
    const message: BitchatMessage = new BitchatMessage(
      this.getConversationDisplayName(conversationID), savedPath,
      routed.packet.timestamp);
    message.id = util.generateRandomUUID();
    message.type = MediaFileStore.messageTypeForMime(filePacket.mimeType);
    message.isPrivate = true;
    message.recipientNickname = this.nickname;
    message.senderPeerId = conversationID;
    message.notEndToEndEncrypted = legacy;
    MessageNotificationDispatcher.getInstance().notifyPrivateMessage(
      conversationID, message.sender,
      ChatViewModel.mediaPreviewText(message.type, filePacket.fileName), isOpen);
    ConversationStore.getInstance().appendMessage(conversationID, message, isOpen)
      .then((): void => {
        this.publishPrivateMessage(message, graph.myPeerId, isOpen);
      })
      .catch((): void => {
        this.publishPrivateMessage(message, graph.myPeerId, isOpen);
      });
    if (legacy) {
      return;
    }
    this.sendNoiseReceipt(NoisePayloadType.DELIVERED, message.id, conversationID);
    if (isOpen) {
      this.sentReadReceipts.add(message.id);
      this.sendNoiseReceipt(NoisePayloadType.READ_RECEIPT, message.id, conversationID);
    }
  }

  /** Noise 0x21 PEER_STATE: feed the 0x21 coordinator's proof path. */
  private handleIncomingPeerState(routed: RoutedPacket, data: Uint8Array,
    session: AuthenticatedNoiseSession): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    const state: AuthenticatedPeerState | null = AuthenticatedPeerState.decode(data);
    if (state === null) {
      return;
    }
    const accepted: boolean =
      graph.peerStateManager.receive(routed.peerID, state, session);
    if (accepted) {
      this.syncConsentPrompt();
    }
  }

  /** Dispatch every prepared fragment; drive the progress UI events. */
  private dispatchPrivateMediaFragments(transferId: string,
    built: BuiltPrivateMediaTransfer): boolean {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return false;
    }
    const recipientId: Uint8Array | null = built.packet.recipientId;
    if (recipientId === null) {
      // Private media must never fall back to a broadcast route.
      return false;
    }
    const recipientHex: string = ByteUtils.bytesToHex(recipientId);
    const total: number = built.fragments.length;
    graph.mediaProgress.start(transferId, total);
    let sent: number = 0;
    for (let i: number = 0; i < built.fragments.length; i++) {
      const delivered: boolean = graph.transport.send(built.fragments[i], recipientHex);
      if (delivered) {
        sent++;
        graph.mediaProgress.progress(transferId, sent, total);
      }
    }
    if (sent === total) {
      graph.mediaProgress.complete(transferId, total);
      return true;
    }
    graph.mediaProgress.fail(transferId);
    return false;
  }

  /**
   * Intent manager onReady: commit (build-route-sign-fragment dispatch)
   * first, then persist + publish the local echo with the transfer id and,
   * for legacy 0x22, the non-end-to-end-encrypted tag.
   */
  private commitPrivateMediaEcho(preparation: PrivateMediaPreparation,
    intent: PrivateMediaSendIntent): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    const transfer: PreparedPrivateMediaTransfer | null = preparation.transfer;
    if (transfer === null) {
      return;
    }
    const committed: boolean = transfer.commit();
    const built: BuiltPrivateMediaTransfer | null = preparation.built;
    const echo: BitchatMessage = new BitchatMessage(this.nickname, intent.filePath,
      Date.now());
    echo.id = intent.transferId;
    echo.type = ChatViewModel.bitchatMessageTypeFromNumber(intent.messageType);
    echo.isPrivate = true;
    echo.recipientNickname =
      this.getConversationDisplayName(intent.conversationID);
    echo.senderPeerId = graph.myPeerId;
    echo.deliveryStatus = committed ? DeliveryStatusKind.SENT : DeliveryStatusKind.FAILED;
    echo.transferId = intent.transferId;
    echo.notEndToEndEncrypted = built !== null &&
      built.wireMode === PrivateMediaWireMode.SIGNED_DIRECTED_RAW_0X22;
    const isOpen: boolean =
      this.state.selectedConversationId === intent.conversationID;
    ConversationStore.getInstance().appendMessage(intent.conversationID, echo, isOpen)
      .then((): void => {
        this.publishPrivateMessage(echo, graph.myPeerId, isOpen);
      })
      .catch((): void => {
        this.publishPrivateMessage(echo, graph.myPeerId, isOpen);
      });
    this.syncConsentPrompt();
  }

  /** System row for policy/consent/timeout outcomes (persisted + shown). */
  addPrivateSystemMessage(conversationID: string, text: string): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null || conversationID === '') {
      return;
    }
    const system: BitchatMessage = new BitchatMessage('', text, Date.now());
    system.id = util.generateRandomUUID();
    system.isPrivate = true;
    system.senderPeerId = conversationID;
    const isOpen: boolean = this.state.selectedConversationId === conversationID;
    ConversationStore.getInstance().appendMessage(conversationID, system, isOpen)
      .then((): void => {
        this.publishPrivateMessage(system, graph.myPeerId, isOpen);
      })
      .catch((): void => {
        this.publishPrivateMessage(system, graph.myPeerId, isOpen);
      });
    this.syncConsentPrompt();
  }

  /** Mirror the intent manager's consent request into the UI state. */
  syncConsentPrompt(): void {
    const graph: MeshGraph | null = this.graph;
    const request: LegacyPrivateMediaConsentRequest | null =
      graph === null ? null : graph.mediaIntents.currentConsentRequest();
    if (request === null) {
      this.state.pendingLegacyConsent = null;
      return;
    }
    const current: LegacyConsentPrompt | null = this.state.pendingLegacyConsent;
    if (current !== null && current.requestId === request.requestId) {
      return;
    }
    this.state.pendingLegacyConsent = new LegacyConsentPrompt(request.requestId,
      request.recipientNickname, request.fileName, request.warning);
  }

  /** User accepted the legacy disclosure; re-run policy with fallback. */
  approveLegacyMediaConsent(): void {
    const graph: MeshGraph | null = this.graph;
    const prompt: LegacyConsentPrompt | null = this.state.pendingLegacyConsent;
    if (graph === null || prompt === null) {
      return;
    }
    graph.mediaIntents.approveLegacyPrivateMedia(prompt.requestId);
    this.syncConsentPrompt();
  }

  /** User declined the legacy disclosure; drop the pending consent. */
  cancelLegacyMediaConsent(): void {
    const graph: MeshGraph | null = this.graph;
    const prompt: LegacyConsentPrompt | null = this.state.pendingLegacyConsent;
    if (graph === null || prompt === null) {
      return;
    }
    graph.mediaIntents.cancelLegacyPrivateMedia(prompt.requestId);
    this.state.pendingLegacyConsent = null;
  }

  // ------------------------------------------------------------------
  // US10 voice notes (T054)
  // ------------------------------------------------------------------

  /** Begin one microphone capture (tap-to-toggle UI; 80 ms visualizer). */
  async startVoiceRecording(): Promise<boolean> {
    if (this.state.voiceRecording) {
      return true;
    }
    if (this.graph === null) {
      return false;
    }
    const started: boolean = await this.voiceRecorder.start();
    if (!started) {
      return false;
    }
    this.recordingAmplitudeHistory = [];
    this.state.voiceRecording = true;
    this.state.voiceRecordingElapsedMs = 0;
    this.state.voiceRecordingAmplitude = 0;
    this.state.voiceRecordingWaveform = [];
    this.voiceRecordingTimer = setInterval((): void => {
      this.pollRecordingState();
    }, VOICE_NOTE_POLL_MS);
    return true;
  }

  /** Stop the capture and hand the mu-law WAV to the private-media pipeline. */
  async stopVoiceRecordingAndSend(): Promise<void> {
    if (!this.state.voiceRecording) {
      return;
    }
    this.stopRecordingTimer();
    this.state.voiceRecording = false;
    const conversationID: string = this.state.selectedConversationId;
    const recordedPath: string | null = await this.voiceRecorder.stop(false);
    this.resetRecordingState();
    if (recordedPath === null) {
      return;
    }
    this.sendVoiceNoteFile(conversationID, recordedPath);
  }

  /** Discard the running capture without sending anything. */
  async cancelVoiceRecording(): Promise<void> {
    if (!this.state.voiceRecording) {
      return;
    }
    this.stopRecordingTimer();
    this.state.voiceRecording = false;
    await this.voiceRecorder.stop(true);
    this.resetRecordingState();
  }

  /** Play/pause one voice note; a second bubble replaces the first. */
  toggleVoiceNotePlayback(path: string): void {
    if (this.voicePlayer.getActivePath() === path &&
      this.voicePlayer.hasActivePlayback()) {
      const playback: VoicePlaybackState | null = this.state.voicePlayback;
      if (playback !== null && playback.playing) {
        this.voicePlayer.pause();
      } else {
        this.voicePlayer.resume();
      }
      return;
    }
    this.state.voicePlayback = null;
    void this.voicePlayer.play(path);
  }

  /** Seek the playing note to [0,1] of its duration (waveform tap). */
  seekVoiceNote(fraction: number): void {
    this.voicePlayer.seekFraction(fraction);
  }

  /** Whole-note duration (ms) of one local 8 kHz mu-law WAV; 0 unknown. */
  getVoiceNoteDurationMs(path: string): number {
    const playback: VoicePlaybackState | null = this.state.voicePlayback;
    if (playback !== null && playback.path === path && playback.durationMs > 0) {
      return playback.durationMs;
    }
    if (!path.toLowerCase().endsWith('.wav')) {
      // M4A/AAC notes from Android peers report duration only once played.
      return 0;
    }
    try {
      const stat: fileIo.Stat = fileIo.statSync(path);
      if (stat.size <= 44) {
        return 0;
      }
      return Math.floor((stat.size - 44) * 1000 / VOICE_NOTE_SAMPLE_RATE);
    } catch (e) {
      return 0;
    }
  }

  /** Normalized 120-bin waveform of one local note (cached; [] unknown). */
  getVoiceWaveform(path: string): number[] {
    const cached: number[] | undefined = this.voiceWaveformCache.get(path);
    if (cached !== undefined) {
      return cached;
    }
    let bytes: Uint8Array = new Uint8Array(0);
    try {
      bytes = ChatViewModel.readAllBytes(path);
    } catch (e) {
      bytes = new Uint8Array(0);
    }
    const bins: number[] | null = bytes.length === 0 ? null :
      parseMulawWavWaveform(bytes, WAVEFORM_BINS);
    const waveform: number[] = bins === null ? [] : bins;
    this.voiceWaveformCache.set(path, waveform);
    return waveform;
  }

  // ------------------------------------------------------------------
  // VoiceNotePlaybackListener (T054)
  // ------------------------------------------------------------------

  onVoiceNoteProgress(path: string, positionMs: number, durationMs: number,
    playing: boolean): void {
    this.state.voicePlayback = new VoicePlaybackState(path, positionMs,
      durationMs, playing);
  }

  onVoiceNoteFinished(path: string): void {
    const playback: VoicePlaybackState | null = this.state.voicePlayback;
    if (playback !== null && playback.path === path) {
      // Park the bubble at its end position; the player released itself.
      this.state.voicePlayback = new VoicePlaybackState(path,
        playback.durationMs, playback.durationMs, false);
    }
  }

  onVoiceNoteError(path: string): void {
    const playback: VoicePlaybackState | null = this.state.voicePlayback;
    if (playback !== null && playback.path === path) {
      this.state.voicePlayback = null;
    }
  }

  // ------------------------------------------------------------------
  // LiveVoiceUiListener (US14, T070)
  // ------------------------------------------------------------------

  /** One peer's burst started: begin tracking it in the incoming strip. */
  onLiveVoiceStarted(peerID: string, scope: LiveVoiceScope,
    burstIDHex: string): void {
    this.liveVoiceUiKey = ChatViewModel.liveVoiceKey(peerID, scope, burstIDHex);
    this.liveVoiceAmplitudeHistory = [];
    this.state.liveVoiceIncoming = new LiveVoiceIncomingState(peerID,
      this.liveVoiceNicknameOf(peerID, scope),
      scope === LiveVoiceScope.DIRECT_MESSAGE, []);
  }

  /** Per-frame-batch loudness proxy appended to the scrolling waveform. */
  onLiveVoiceAmplitude(peerID: string, scope: LiveVoiceScope,
    burstIDHex: string, amplitudeNorm: number): void {
    if (this.liveVoiceUiKey !==
      ChatViewModel.liveVoiceKey(peerID, scope, burstIDHex)) {
      return;
    }
    this.liveVoiceAmplitudeHistory.push(Math.min(Math.max(amplitudeNorm, 0), 1));
    while (this.liveVoiceAmplitudeHistory.length > LIVE_VOICE_HISTORY_CAP) {
      this.liveVoiceAmplitudeHistory.shift();
    }
    this.state.liveVoiceIncoming = new LiveVoiceIncomingState(peerID,
      this.liveVoiceNicknameOf(peerID, scope),
      scope === LiveVoiceScope.DIRECT_MESSAGE,
      resampleWave(this.liveVoiceAmplitudeHistory, LIVE_VOICE_STRIP_BARS));
  }

  /** Burst ended: clear the strip and auto-play the finalized .aac. */
  onLiveVoiceFinished(peerID: string, scope: LiveVoiceScope,
    burstIDHex: string, canceled: boolean): void {
    if (this.liveVoiceUiKey ===
      ChatViewModel.liveVoiceKey(peerID, scope, burstIDHex)) {
      this.liveVoiceUiKey = '';
      this.liveVoiceAmplitudeHistory = [];
      this.state.liveVoiceIncoming = null;
    }
    if (canceled) {
      return;
    }
    const manager: LiveVoiceManager = LiveVoiceManager.getInstance();
    const burst: FinishedLiveBurst | null =
      manager.getFinishedBurst(peerID, scope, burstIDHex);
    if (burst === null) {
      return;
    }
    manager.consumeFinishedBurst(burst);
    if (burst.path !== '') {
      void this.voicePlayer.play(burst.path);
    }
  }

  private liveVoiceNicknameOf(peerID: string, scope: LiveVoiceScope): string {
    if (scope === LiveVoiceScope.DIRECT_MESSAGE) {
      return this.getConversationDisplayName(peerID);
    }
    const graph: MeshGraph | null = this.graph;
    const nickname: string | null = graph === null ?
      null : graph.peerManager.getPeerNickname(peerID);
    return nickname === null || nickname === '' ? peerID : nickname;
  }

  private static liveVoiceKey(peerID: string, scope: LiveVoiceScope,
    burstIDHex: string): string {
    return peerID + '|' + scope + '|' + burstIDHex;
  }

  private pollRecordingState(): void {
    if (!this.state.voiceRecording) {
      return;
    }
    const elapsed: number = this.state.voiceRecordingElapsedMs + VOICE_NOTE_POLL_MS;
    const normalized: number =
      normalizeAmplitudeSample(this.voiceRecorder.pollAmplitude());
    this.recordingAmplitudeHistory.push(normalized);
    this.state.voiceRecordingElapsedMs = elapsed;
    this.state.voiceRecordingAmplitude = normalized;
    this.state.voiceRecordingWaveform =
      resampleWave(this.recordingAmplitudeHistory, VOICE_RECORDING_STRIP_BARS);
    if (elapsed >= VOICE_NOTE_MAX_MS) {
      void this.stopVoiceRecordingAndSend();
    }
  }

  /** Read the finished recording and submit it as a private audio send. */
  private sendVoiceNoteFile(conversationID: string, recordedPath: string): void {
    if (this.graph === null || conversationID === '' ||
      this.blockedPeerIds.has(conversationID)) {
      return;
    }
    let bytes: Uint8Array = new Uint8Array(0);
    try {
      bytes = ChatViewModel.readAllBytes(recordedPath);
    } catch (e) {
      bytes = new Uint8Array(0);
    }
    if (bytes.length === 0) {
      this.addPrivateSystemMessage(conversationID, '无法读取所选文件');
      return;
    }
    if (!MediaFileStore.getInstance().isWithinTransferQuota(bytes.length)) {
      this.addPrivateSystemMessage(conversationID, '文件超出私有媒体大小上限');
      return;
    }
    const slash: number = recordedPath.lastIndexOf('/');
    const fileName: string = slash >= 0 ?
      recordedPath.substring(slash + 1) : recordedPath;
    this.submitPrivateMediaFile(conversationID, fileName, 'audio/wav',
      bytes, recordedPath);
  }

  private stopRecordingTimer(): void {
    if (this.voiceRecordingTimer >= 0) {
      clearInterval(this.voiceRecordingTimer);
      this.voiceRecordingTimer = -1;
    }
  }

  private resetRecordingState(): void {
    this.recordingAmplitudeHistory = [];
    this.state.voiceRecordingElapsedMs = 0;
    this.state.voiceRecordingAmplitude = 0;
    this.state.voiceRecordingWaveform = [];
  }

  /** Cancel capture + stop playback; shared by stop() and the panic wipe. */
  private teardownVoiceNotes(): void {
    this.stopRecordingTimer();
    this.state.voiceRecording = false;
    void this.voiceRecorder.stop(true);
    this.resetRecordingState();
    void this.voicePlayer.release();
    this.state.voicePlayback = null;
    this.voiceWaveformCache.clear();
    this.liveVoiceUiKey = '';
    this.liveVoiceAmplitudeHistory = [];
    this.state.liveVoiceIncoming = null;
  }

  private static readAllBytes(uri: string): Uint8Array {
    const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      return new Uint8Array(buffer);
    } finally {
      fileIo.closeSync(file);
    }
  }

  /** Minimal extension -> MIME mapping for picked files. */
  private static mimeForFileName(fileName: string): string {
    const lower: string = fileName.toLowerCase();
    const dot: number = lower.lastIndexOf('.');
    const ext: string = dot >= 0 ? lower.substring(dot + 1) : '';
    if (ext === 'jpg' || ext === 'jpeg') {
      return 'image/jpeg';
    }
    if (ext === 'png') {
      return 'image/png';
    }
    if (ext === 'gif') {
      return 'image/gif';
    }
    if (ext === 'webp') {
      return 'image/webp';
    }
    if (ext === 'bmp') {
      return 'image/bmp';
    }
    if (ext === 'mp3') {
      return 'audio/mpeg';
    }
    if (ext === 'wav') {
      return 'audio/wav';
    }
    if (ext === 'm4a') {
      return 'audio/mp4';
    }
    if (ext === 'aac') {
      return 'audio/aac';
    }
    if (ext === 'ogg') {
      return 'audio/ogg';
    }
    if (ext === 'opus') {
      return 'audio/opus';
    }
    if (ext === 'amr') {
      return 'audio/amr';
    }
    if (ext === 'pdf') {
      return 'application/pdf';
    }
    if (ext === 'txt') {
      return 'text/plain';
    }
    return 'application/octet-stream';
  }

  private static bitchatMessageTypeFromNumber(value: number): BitchatMessageType {
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

  private static mediaPreviewText(type: BitchatMessageType,
    fileName: string): string {
    if (type === BitchatMessageType.IMAGE) {
      return '[图片]';
    }
    if (type === BitchatMessageType.AUDIO) {
      return '[语音]';
    }
    if (type === BitchatMessageType.FILE) {
      return '[文件] ' + fileName;
    }
    return '[媒体]';
  }

  /** After repeated decrypt failures the session is stale; reset and re-handshake. */
  private registerDecryptFailure(peerID: string): void {
    const graph: MeshGraph | null = this.graph;
    if (graph === null || peerID === '' || peerID === graph.myPeerId) {
      return;
    }
    const failures: number = (this.consecutiveDecryptFailures.get(peerID) ?? 0) + 1;
    if (failures >= MAX_CONSECUTIVE_DECRYPT_FAILURES) {
      this.consecutiveDecryptFailures.delete(peerID);
      graph.noiseSessions.removeSession(peerID);
      this.initiateNoiseHandshake(peerID);
    } else {
      this.consecutiveDecryptFailures.set(peerID, failures);
    }
  }

  /** Queued message expired / exhausted retries: mark it FAILED. */
  private markPrivateMessageFailed(messageID: string): void {
    this.applyDeliveryTransition(messageID, DeliveryStatusKind.FAILED);
  }

  /** Persist + publish one delivery transition (ladder enforced by the store). */
  private applyDeliveryTransition(messageID: string, status: DeliveryStatusKind): void {
    ConversationStore.getInstance().updateDeliveryStatus(messageID, status, '')
      .then((): void => {
        const next: PrivateMessageEntry[] = this.state.privateMessages.slice();
        for (let i: number = 0; i < next.length; i++) {
          if (next[i].messageID === messageID) {
            if (ChatViewModel.mayApplyStatus(status, next[i].deliveryStatus)) {
              next[i] = new PrivateMessageEntry(next[i].messageID, next[i].isMine,
                next[i].senderNickname, next[i].content, next[i].timestampMs, status,
                next[i].isRead, next[i].messageType, next[i].transferId,
                next[i].notEndToEndEncrypted);
              this.state.privateMessages = next;
            }
            break;
          }
        }
      })
      .catch((): void => {
        // Status transitions are cosmetic when the store fails.
      });
  }

  /** Same replacement rule as the store ladder (FAILED may not follow DELIVERED/READ). */
  private static mayApplyStatus(next: DeliveryStatusKind,
    existing: DeliveryStatusKind): boolean {
    if (next === DeliveryStatusKind.FAILED) {
      return existing !== DeliveryStatusKind.DELIVERED &&
        existing !== DeliveryStatusKind.READ;
    }
    if (existing === DeliveryStatusKind.FAILED) {
      return true;
    }
    return ChatViewModel.deliveryPriority(next) >= ChatViewModel.deliveryPriority(existing);
  }

  private static deliveryPriority(status: DeliveryStatusKind): number {
    switch (status) {
      case DeliveryStatusKind.SENDING:
        return 1;
      case DeliveryStatusKind.SENT:
        return 2;
      case DeliveryStatusKind.PARTIALLY_DELIVERED:
        return 3;
      case DeliveryStatusKind.DELIVERED:
        return 4;
      case DeliveryStatusKind.READ:
        return 5;
      default:
        return 0;
    }
  }

  private toPrivateEntry(message: BitchatMessage, myPeerId: string,
    isRead: boolean): PrivateMessageEntry {
    return new PrivateMessageEntry(message.id, message.senderPeerId === myPeerId,
      message.sender, message.content, message.timestamp, message.deliveryStatus, isRead,
      message.type, message.transferId, message.notEndToEndEncrypted);
  }

  /** Insert/update the conversation row for a new private message. */
  private bumpConversationSummary(conversationID: string, message: BitchatMessage,
    incrementUnread: boolean): void {
    if (conversationID === '') {
      return;
    }
    const next: PrivateConversationSummary[] = this.state.privateConversations.slice();
    let found: boolean = false;
    for (let i: number = 0; i < next.length; i++) {
      if (next[i].conversationID === conversationID) {
        next[i] = new PrivateConversationSummary(conversationID, next[i].displayName,
          message.content, message.timestamp,
          next[i].unreadCount + (incrementUnread ? 1 : 0));
        found = true;
        break;
      }
    }
    if (!found) {
      next.push(new PrivateConversationSummary(conversationID,
        this.getConversationDisplayName(conversationID), message.content,
        message.timestamp, incrementUnread ? 1 : 0));
    }
    next.sort(ChatViewModel.compareConversationSummaries);
    this.state.privateConversations = next;
  }

  /** Rebuild the conversation list from the persisted latest-message snapshot. */
  private async refreshConversationSummaries(): Promise<void> {
    const graph: MeshGraph | null = this.graph;
    if (graph === null) {
      return;
    }
    try {
      const snapshot: PersistedConversationSnapshot =
        await ConversationStore.getInstance().loadInitialSnapshot();
      const summaries: PrivateConversationSummary[] = [];
      snapshot.messagesByConversation.forEach((messages: BitchatMessage[],
        conversationID: string) => {
        if (messages.length === 0) {
          return;
        }
        let latest: BitchatMessage = messages[0];
        let lastIncoming: BitchatMessage | null = null;
        for (let i: number = 0; i < messages.length; i++) {
          if (messages[i].timestamp > latest.timestamp) {
            latest = messages[i];
          }
          if (messages[i].senderPeerId !== graph.myPeerId) {
            lastIncoming = messages[i];
          }
        }
        let display: string = this.getConversationDisplayName(conversationID);
        if (display === conversationID && lastIncoming !== null) {
          // Fall back to the sender nickname recorded with the message.
          display = lastIncoming.sender;
        }
        summaries.push(new PrivateConversationSummary(conversationID, display,
          latest.content, latest.timestamp,
          snapshot.unreadCounts.get(conversationID) ?? 0));
      });
      summaries.sort(ChatViewModel.compareConversationSummaries);
      this.state.privateConversations = summaries;
    } catch (e) {
      // Keep the current list on store failures.
    }
  }

  /** Newest activity first, then conversation ID (deterministic order). */
  private static compareConversationSummaries(a: PrivateConversationSummary,
    b: PrivateConversationSummary): number {
    if (a.lastMessageTimestampMs !== b.lastMessageTimestampMs) {
      return b.lastMessageTimestampMs - a.lastMessageTimestampMs;
    }
    return a.conversationID < b.conversationID ? -1 :
      (a.conversationID > b.conversationID ? 1 : 0);
  }
}
