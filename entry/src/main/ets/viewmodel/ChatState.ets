/**
 * Chat UI state container (US3, T030; private chat state T036).
 *
 * plan.md D8: services -> ViewModel -> state -> views, one-directional.
 * ChatViewModel is the only writer; views read through @ComponentV2
 * bindings, so the timeline mutates by reassignment of the @Trace
 * `messages` array (rebuild-don't-mutate, same policy as T025 rows).
 * Entries themselves are immutable value objects.
 */
import { BitchatMessageType, DeliveryStatusKind } from '../model/BitchatMessage';
import { CommandSuggestion } from './CommandSuggestion';

/** One immutable public-timeline entry (rendered row). */
export class ChatEntry {
  /** 16-byte packet-ID hex; timeline dedup key (PacketIdUtil). */
  readonly idHex: string;
  readonly senderPeerId: string;
  readonly nickname: string;
  readonly content: string;
  readonly timestampMs: number;
  readonly isMine: boolean;

  constructor(idHex: string, senderPeerId: string, nickname: string, content: string,
    timestampMs: number, isMine: boolean) {
    this.idHex = idHex;
    this.senderPeerId = senderPeerId;
    this.nickname = nickname;
    this.content = content;
    this.timestampMs = timestampMs;
    this.isMine = isMine;
  }
}

/** One immutable private-message row (PrivateChatView rendering, T036). */
export class PrivateMessageEntry {
  readonly messageID: string;
  readonly isMine: boolean;
  readonly senderNickname: string;
  readonly content: string;
  readonly timestampMs: number;
  readonly deliveryStatus: DeliveryStatusKind;
  readonly isRead: boolean;
  /** Bubble variant: text (default) vs image/file/audio media (T053). */
  readonly messageType: BitchatMessageType;
  /** Outgoing media transfer progress binding (T053); '' for text. */
  readonly transferId: string;
  /** Legacy 0x22 plaintext fallback send: UI must label it clearly (T053). */
  readonly notEndToEndEncrypted: boolean;

  constructor(messageID: string, isMine: boolean, senderNickname: string, content: string,
    timestampMs: number, deliveryStatus: DeliveryStatusKind, isRead: boolean,
    messageType: BitchatMessageType = BitchatMessageType.MESSAGE,
    transferId: string = '', notEndToEndEncrypted: boolean = false) {
    this.messageID = messageID;
    this.isMine = isMine;
    this.senderNickname = senderNickname;
    this.content = content;
    this.timestampMs = timestampMs;
    this.deliveryStatus = deliveryStatus;
    this.isRead = isRead;
    this.messageType = messageType;
    this.transferId = transferId;
    this.notEndToEndEncrypted = notEndToEndEncrypted;
  }
}

/** Live progress of one outgoing media transfer (T053, progress events). */
export class MediaTransferProgress {
  readonly transferId: string;
  readonly sent: number;
  readonly total: number;
  readonly completed: boolean;
  readonly failed: boolean;

  constructor(transferId: string, sent: number, total: number,
    completed: boolean, failed: boolean) {
    this.transferId = transferId;
    this.sent = sent;
    this.total = total;
    this.completed = completed;
    this.failed = failed;
  }
}

/** Legacy private-media consent prompt bound to the open dialog (T053). */
export class LegacyConsentPrompt {
  readonly requestId: string;
  readonly recipientNickname: string;
  readonly fileName: string;
  readonly warning: string;

  constructor(requestId: string, recipientNickname: string,
    fileName: string, warning: string) {
    this.requestId = requestId;
    this.recipientNickname = recipientNickname;
    this.fileName = fileName;
    this.warning = warning;
  }
}

/** Active voice-note playback position (US10, T054). */
export class VoicePlaybackState {
  /** Local file path of the note being played. */
  readonly path: string;
  readonly positionMs: number;
  readonly durationMs: number;
  readonly playing: boolean;

  constructor(path: string, positionMs: number, durationMs: number,
    playing: boolean) {
    this.path = path;
    this.positionMs = positionMs;
    this.durationMs = durationMs;
    this.playing = playing;
  }
}

/** Live PTT burst being received right now (US14, T070). */
export class LiveVoiceIncomingState {
  readonly peerID: string;
  /** Display name of the talker (conversation name or mesh nickname). */
  readonly nickname: string;
  /** True when the burst rides the Noise-encrypted DM scope. */
  readonly directMessage: boolean;
  /** Scrolling-waveform samples, normalized [0,1], oldest first. */
  readonly samples: number[];

  constructor(peerID: string, nickname: string, directMessage: boolean,
    samples: number[]) {
    this.peerID = peerID;
    this.nickname = nickname;
    this.directMessage = directMessage;
    this.samples = samples;
  }
}

/** One conversation row in the conversation list (T036). */
export class PrivateConversationSummary {
  readonly conversationID: string;
  readonly displayName: string;
  readonly lastMessagePreview: string;
  readonly lastMessageTimestampMs: number;
  readonly unreadCount: number;

  constructor(conversationID: string, displayName: string, lastMessagePreview: string,
    lastMessageTimestampMs: number, unreadCount: number) {
    this.conversationID = conversationID;
    this.displayName = displayName;
    this.lastMessagePreview = lastMessagePreview;
    this.lastMessageTimestampMs = lastMessageTimestampMs;
    this.unreadCount = unreadCount;
  }
}

/** @ObservedV2 state root published by ChatViewModel. */
@ObservedV2
export class ChatState {
  /** Public broadcast timeline, ordered by timestamp (oldest first). */
  @Trace messages: ChatEntry[] = [];
  @Trace nickname: string = '';
  @Trace peerId: string = '';
  /** Number of established transport links (GATT connections). */
  @Trace connectedCount: number = 0;
  /** True while an outgoing broadcast is being built/signed/sent. */
  @Trace sending: boolean = false;
  /** True once the mesh stack finished starting. */
  @Trace serviceRunning: boolean = false;
  /** Private conversations, newest activity first (T036). */
  @Trace privateConversations: PrivateConversationSummary[] = [];
  /** Messages of the currently open private conversation, oldest first. */
  @Trace privateMessages: PrivateMessageEntry[] = [];
  /** Open private conversation ID (mesh peer ID); empty when none. */
  @Trace selectedConversationId: string = '';
  /** True while an outgoing private message is being built/sent. */
  @Trace privateSending: boolean = false;
  /** Command autocomplete popup (T039; rendered by T040 MessageInput). */
  @Trace showCommandSuggestions: boolean = false;
  @Trace commandSuggestions: CommandSuggestion[] = [];
  /** Mention autocomplete popup (T039; rendered by T040 MessageInput). */
  @Trace showMentionSuggestions: boolean = false;
  @Trace mentionSuggestions: string[] = [];
  /** Chat surface mode (T041): true = messenger bubbles, false = terminal/Matrix lines. */
  @Trace bubblesMode: boolean = true;
  /** Channel tag the composer targets; '' = main public timeline (T048). */
  @Trace currentChannel: string = '';
  /** Channel awaiting password entry (T048 registry; the dialog is T049). */
  @Trace passwordPromptChannel: string = '';
  @Trace showPasswordPrompt: boolean = false;
  /** Per-channel timelines keyed by the '#tag' channel (T049). */
  @Trace channelMessages: Map<string, ChatEntry[]> = new Map<string, ChatEntry[]>();
  /** Outgoing private-media transfer progress keyed by transferId (T053). */
  @Trace mediaProgress: Map<string, MediaTransferProgress> =
    new Map<string, MediaTransferProgress>();
  /** Legacy private-media consent prompt awaiting the user (T053). */
  @Trace pendingLegacyConsent: LegacyConsentPrompt | null = null;
  /** True while the microphone is capturing an outgoing voice note (T054). */
  @Trace voiceRecording: boolean = false;
  /** Recording elapsed time; also drives the 10 s auto-stop (T054). */
  @Trace voiceRecordingElapsedMs: number = 0;
  /** Last polled capture amplitude, normalized to [0,1] (T054). */
  @Trace voiceRecordingAmplitude: number = 0;
  /** Live recording visualizer samples, normalized [0,1] (T054). */
  @Trace voiceRecordingWaveform: number[] = [];
  /** Active voice-note playback (T054); null while idle. */
  @Trace voicePlayback: VoicePlaybackState | null = null;
  /** Live PTT burst arriving from a peer (US14, T070); null while idle. */
  @Trace liveVoiceIncoming: LiveVoiceIncomingState | null = null;
  /** Verified identity fingerprints, sha256 hex of the peer Noise static key (US11). */
  @Trace verifiedFingerprints: Set<string> = new Set<string>();
  /** Fingerprints we favorited (US11; mirror of the FavoritesStore). */
  @Trace favoritedFingerprints: Set<string> = new Set<string>();
  /** Fingerprints of peers who favorited us (US11; mirror of the FavoritesStore). */
  @Trace peerFavoritedUsFingerprints: Set<string> = new Set<string>();
  /** Peer whose QR-verification handshake is in flight ('' = none, US11). */
  @Trace verificationPendingPeerId: string = '';
  /** Open geohash location channel; '' when none (US13, T068). */
  @Trace currentGeohashChannel: string = '';
  /** Per-geohash location-channel timelines, oldest first (US13, T068). */
  @Trace geohashMessages: Map<string, ChatEntry[]> = new Map<string, ChatEntry[]>();
  /** Live participant counts per geohash, 1 h presence window (US13, T068). */
  @Trace geohashParticipantCounts: Map<string, number> =
    new Map<string, number>();
  /** Bookmarked geohash channels, newest first; mirror of GeohashBookmarksStore (US13). */
  @Trace geohashBookmarks: string[] = [];
}
