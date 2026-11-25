/**
 * Private media transfer v1 - ports bitchat-android:
 *  - PrivateMediaSecurity.kt (PrivateMediaSecurityController)
 *  - PrivateMediaTransfer.kt (preparer, PreparedPrivateMediaTransfer)
 *  - TransferProgressManager.kt (transfer progress events)
 *  - the pending-intent / legacy-consent state machine of
 *    ui/MediaSendingManager.kt (the UI-only file reading and local echo
 *    stay in the wiring layer).
 *
 * Security-critical rules preserved verbatim from Android:
 *  - A prepared transfer is single-use, including after a failed commit.
 *  - Private media is never broadcast: the packet is always directed at
 *    the recipient, either Noise-encrypted inside payload type 0x20 or,
 *    after explicit one-shot consent, a signed bare FILE_TRANSFER 0x22
 *    that the UI must clearly label as not end-to-end encrypted.
 *  - Build, route, sign, and fragment exactly once before commit; the
 *    file content alone may not exceed the bytes carried by every
 *    possible fragment (256 x 469 = 120064 bytes). The UI-level
 *    10,350,592-byte pre-check (MediaFileStore.isWithinTransferQuota)
 *    remains a separate, earlier admission.
 *  - Announcements alone can never create a private-media pin; only an
 *    authenticated peer state proof pins durably (PeerStateManager).
 *
 * Pure ArkTS (no @kit imports) so the decision semantics run in the
 * host contract harness; the device wiring injects the Noise session
 * table, the packet signer, the fragmenter, and the scheduler.
 */
import { BitchatPacket, MessageType } from '../../model/BitchatPacket';
import { BitchatFilePacket } from '../../model/FragmentModels';
import {
  AuthenticatedPeerState,
  NoisePayload,
  NoisePayloadType,
  PeerCapabilities,
} from '../../model/IdentityModels';
import { FragmentationConstants } from '../../common/ProtocolConstants';
import { AuthenticatedNoiseSession } from '../noise/NoiseSessionManager';
import { PeerStateStatus } from '../mesh/PeerStateManager';

/** How the one admitted private-media packet travels on the mesh. */
export enum PrivateMediaWireMode {
  /** Noise-encrypted BitchatFilePacket inside NoisePayload type 0x20. */
  ENCRYPTED_NOISE_0X20 = 0,
  /** Signed directed bare FILE_TRANSFER (0x22) after explicit consent. */
  SIGNED_DIRECTED_RAW_0X22 = 1,
}

/** Progress event for one transferId, mirroring TransferProgressManager.kt. */
export class TransferProgressEvent {
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

/**
 * Fan-out for transfer progress events. Android emits on a SharedFlow;
 * here listeners are invoked synchronously and a throwing listener never
 * breaks the others.
 */
export class TransferProgressManager {
  private listeners: Array<(event: TransferProgressEvent) => void> = [];

  addListener(listener: (event: TransferProgressEvent) => void): void {
    this.listeners.push(listener);
  }

  removeListener(listener: (event: TransferProgressEvent) => void): void {
    const next: Array<(event: TransferProgressEvent) => void> = [];
    for (let i: number = 0; i < this.listeners.length; i++) {
      if (this.listeners[i] !== listener) {
        next.push(this.listeners[i]);
      }
    }
    this.listeners = next;
  }

  start(id: string, total: number): void {
    this.emit(id, 0, total, false, false);
  }

  progress(id: string, sent: number, total: number): void {
    this.emit(id, sent, total, sent >= total, false);
  }

  complete(id: string, total: number): void {
    this.emit(id, total, total, true, false);
  }

  fail(id: string): void {
    this.emit(id, 0, 0, true, true);
  }

  private emit(id: string, sent: number, total: number,
    done: boolean, failed: boolean): void {
    const event: TransferProgressEvent =
      new TransferProgressEvent(id, sent, total, done, failed);
    const snapshot: Array<(event: TransferProgressEvent) => void> =
      this.listeners.slice();
    for (let i: number = 0; i < snapshot.length; i++) {
      try {
        snapshot[i](event);
      } catch (e) {
        // A broken observer must not block progress for everyone else.
      }
    }
  }
}

/**
 * A fully built, routed, signed, and fragmented private-media transfer.
 * A prepared transfer is single-use, including after a failed commit.
 */
export class PreparedPrivateMediaTransfer {
  readonly transferId: string;
  readonly wireMode: PrivateMediaWireMode;
  private readonly commitAction: () => boolean;
  private committed: boolean = false;

  constructor(transferId: string, wireMode: PrivateMediaWireMode,
    commitAction: () => boolean) {
    this.transferId = transferId;
    this.wireMode = wireMode;
    this.commitAction = commitAction;
  }

  commit(): boolean {
    if (this.committed) {
      return false;
    }
    this.committed = true;
    return this.commitAction();
  }
}

/** Outcome of the security policy consulted before any packet is built. */
export enum PrivateMediaPolicyKind {
  ENCRYPTED = 0,
  REQUIRES_LEGACY_CONSENT = 1,
  NEEDS_HANDSHAKE = 2,
  AWAITING_PEER_STATE = 3,
  BLOCKED = 4,
}

export class PrivateMediaPolicyDecision {
  readonly kind: PrivateMediaPolicyKind;
  readonly authenticatedSession: AuthenticatedNoiseSession | null;
  readonly reason: string | null;

  private constructor(kind: PrivateMediaPolicyKind,
    authenticatedSession: AuthenticatedNoiseSession | null,
    reason: string | null) {
    this.kind = kind;
    this.authenticatedSession = authenticatedSession;
    this.reason = reason;
  }

  static encrypted(session: AuthenticatedNoiseSession): PrivateMediaPolicyDecision {
    return new PrivateMediaPolicyDecision(PrivateMediaPolicyKind.ENCRYPTED, session, null);
  }

  static requiresLegacyConsent(): PrivateMediaPolicyDecision {
    return new PrivateMediaPolicyDecision(PrivateMediaPolicyKind.REQUIRES_LEGACY_CONSENT, null, null);
  }

  static needsHandshake(): PrivateMediaPolicyDecision {
    return new PrivateMediaPolicyDecision(PrivateMediaPolicyKind.NEEDS_HANDSHAKE, null, null);
  }

  static awaitingPeerState(): PrivateMediaPolicyDecision {
    return new PrivateMediaPolicyDecision(PrivateMediaPolicyKind.AWAITING_PEER_STATE, null, null);
  }

  static blocked(reason: string): PrivateMediaPolicyDecision {
    return new PrivateMediaPolicyDecision(PrivateMediaPolicyKind.BLOCKED, null, reason);
  }
}

/** Result of one private-media Noise encryption attempt. */
export enum PrivateMediaEncryptionOutcome {
  SUCCESS = 0,
  GENERATION_CHANGED = 1,
  FAILED = 2,
}

export class PrivateMediaEncryptionResult {
  readonly outcome: PrivateMediaEncryptionOutcome;
  readonly ciphertext: Uint8Array | null;

  private constructor(outcome: PrivateMediaEncryptionOutcome,
    ciphertext: Uint8Array | null) {
    this.outcome = outcome;
    this.ciphertext = ciphertext;
  }

  static success(ciphertext: Uint8Array): PrivateMediaEncryptionResult {
    return new PrivateMediaEncryptionResult(PrivateMediaEncryptionOutcome.SUCCESS, ciphertext);
  }

  static generationChanged(): PrivateMediaEncryptionResult {
    return new PrivateMediaEncryptionResult(PrivateMediaEncryptionOutcome.GENERATION_CHANGED, null);
  }

  static failed(): PrivateMediaEncryptionResult {
    return new PrivateMediaEncryptionResult(PrivateMediaEncryptionOutcome.FAILED, null);
  }
}

/** Injected dependencies of PrivateMediaSecurityController. */
export interface PrivateMediaSecurityDeps {
  authenticatedSessionProvider: (peerID: string) => AuthenticatedNoiseSession | null;
  peerStateStatusProvider: (peerID: string,
    authenticatedSession: AuthenticatedNoiseSession) => PeerStateStatus;
  provenStateProvider: (peerID: string,
    authenticatedSession: AuthenticatedNoiseSession) => AuthenticatedPeerState | null;
  isPrivateMediaPinned: (peerID: string) => boolean;
}

/**
 * Binds an advertised private-media capability to a live Noise remote-static
 * key and honors the HSTS-style pin stored by that key's SHA-256
 * fingerprint. Announcements alone can never create a pin.
 */
export class PrivateMediaSecurityController {
  private readonly deps: PrivateMediaSecurityDeps;

  constructor(deps: PrivateMediaSecurityDeps) {
    this.deps = deps;
  }

  sendPolicy(peerID: string): PrivateMediaPolicyDecision {
    const authenticatedSession: AuthenticatedNoiseSession | null =
      this.deps.authenticatedSessionProvider(peerID);
    if (authenticatedSession === null ||
      authenticatedSession.getRemoteStaticKey().length !== 32 ||
      authenticatedSession.getSessionToken().length !== 32) {
      return PrivateMediaPolicyDecision.needsHandshake();
    }

    const status: PeerStateStatus =
      this.deps.peerStateStatusProvider(peerID, authenticatedSession);
    if (status === PeerStateStatus.AWAITING) {
      return PrivateMediaPolicyDecision.awaitingPeerState();
    }
    if (status === PeerStateStatus.PROVEN) {
      const proven: AuthenticatedPeerState | null =
        this.deps.provenStateProvider(peerID, authenticatedSession);
      if (proven !== null &&
        proven.capabilities.contains(PeerCapabilities.PRIVATE_MEDIA)) {
        return PrivateMediaPolicyDecision.encrypted(authenticatedSession);
      }
      if (this.deps.isPrivateMediaPinned(peerID)) {
        return PrivateMediaPolicyDecision.blocked(
          'Encrypted private media was previously pinned, but this session proved no support; send blocked');
      }
      return PrivateMediaPolicyDecision.requiresLegacyConsent();
    }
    if (status === PeerStateStatus.MISSING) {
      // A live crypto session can become visible just before its authenticated
      // callback installs the coordinator generation. Never treat that gap as
      // a watchdog timeout.
      return PrivateMediaPolicyDecision.awaitingPeerState();
    }
    // PeerStateStatus.TIMED_OUT
    if (this.deps.isPrivateMediaPinned(peerID)) {
      return PrivateMediaPolicyDecision.blocked(
        'Encrypted private media was previously pinned, but this session did not provide authenticated peer state');
    }
    // A Noise-capable old client that does not know 0x21 may use explicit
    // one-shot legacy consent after the five-second generation watchdog.
    return PrivateMediaPolicyDecision.requiresLegacyConsent();
  }
}

/** The exact final packet set admitted to the mesh for one transfer. */
export class BuiltPrivateMediaTransfer {
  readonly packet: BitchatPacket;
  readonly fragments: BitchatPacket[];
  readonly wireMode: PrivateMediaWireMode;

  constructor(packet: BitchatPacket, fragments: BitchatPacket[],
    wireMode: PrivateMediaWireMode) {
    this.packet = packet;
    this.fragments = fragments;
    this.wireMode = wireMode;
  }
}

/** Public outcome of preparing one private-media send. */
export enum PrivateMediaPreparationKind {
  READY = 0,
  REQUIRES_LEGACY_CONSENT = 1,
  NEEDS_HANDSHAKE = 2,
  AWAITING_PEER_STATE = 3,
  REJECTED = 4,
}

export class PrivateMediaPreparation {
  readonly kind: PrivateMediaPreparationKind;
  readonly transfer: PreparedPrivateMediaTransfer | null;
  readonly built: BuiltPrivateMediaTransfer | null;
  readonly warning: string | null;
  readonly reason: string | null;

  private constructor(kind: PrivateMediaPreparationKind,
    transfer: PreparedPrivateMediaTransfer | null,
    built: BuiltPrivateMediaTransfer | null,
    warning: string | null,
    reason: string | null) {
    this.kind = kind;
    this.transfer = transfer;
    this.built = built;
    this.warning = warning;
    this.reason = reason;
  }

  static ready(transfer: PreparedPrivateMediaTransfer,
    built: BuiltPrivateMediaTransfer): PrivateMediaPreparation {
    return new PrivateMediaPreparation(PrivateMediaPreparationKind.READY,
      transfer, built, null, null);
  }

  static requiresLegacyConsent(warning: string): PrivateMediaPreparation {
    return new PrivateMediaPreparation(PrivateMediaPreparationKind.REQUIRES_LEGACY_CONSENT,
      null, null, warning, null);
  }

  static needsHandshake(): PrivateMediaPreparation {
    return new PrivateMediaPreparation(PrivateMediaPreparationKind.NEEDS_HANDSHAKE,
      null, null, null, null);
  }

  static awaitingPeerState(): PrivateMediaPreparation {
    return new PrivateMediaPreparation(PrivateMediaPreparationKind.AWAITING_PEER_STATE,
      null, null, null, null);
  }

  static rejected(reason: string): PrivateMediaPreparation {
    return new PrivateMediaPreparation(PrivateMediaPreparationKind.REJECTED,
      null, null, null, reason);
  }
}

/** Injected dependencies of PrivateMediaTransferPreparer. */
export interface PrivateMediaTransferPreparerDeps {
  senderID: Uint8Array;
  ttl: number;
  policyProvider: (recipientPeerID: string) => PrivateMediaPolicyDecision;
  encrypt: (plaintext: Uint8Array, recipientPeerID: string,
    authenticatedSession: AuthenticatedNoiseSession) => PrivateMediaEncryptionResult;
  /** Applies the available route and produces a 64-byte-signed packet. */
  finalizeRoutedAndSigned: (packet: BitchatPacket) => BitchatPacket | null;
  fragment: (packet: BitchatPacket, maxFragments: number) => BitchatPacket[];
  /** Dispatches the admitted fragments; runs at most once per transfer. */
  commitPrepared: (transferId: string, built: BuiltPrivateMediaTransfer) => boolean;
  now: () => number;
}

/**
 * Builds, routes, signs, and fragments exactly once before UI local echo.
 * Mirrors PrivateMediaTransferPreparer.kt, including the single retry when
 * the Noise generation changes between policy lookup and encryption.
 */
export class PrivateMediaTransferPreparer {
  private readonly deps: PrivateMediaTransferPreparerDeps;

  constructor(deps: PrivateMediaTransferPreparerDeps) {
    this.deps = deps;
  }

  prepare(recipientPeerID: string, recipientID: Uint8Array,
    file: BitchatFilePacket, transferId: string,
    allowLegacyFallback: boolean): PrivateMediaPreparation {
    return this.prepareWithGenerationRetries(recipientPeerID, recipientID,
      file, transferId, allowLegacyFallback, 1);
  }

  private prepareWithGenerationRetries(recipientPeerID: string,
    recipientID: Uint8Array, file: BitchatFilePacket, transferId: string,
    allowLegacyFallback: boolean,
    generationRetriesRemaining: number): PrivateMediaPreparation {
    const maxPrivateFragments: number = FragmentationConstants.MAX_FRAGMENTS_PER_ID;
    const absolutePayloadUpperBound: number =
      maxPrivateFragments * FragmentationConstants.MAX_FRAGMENT_SIZE;
    // The file content alone cannot exceed the total bytes carried by every
    // possible fragment. Reject before TLV encoding, encryption, signing,
    // and packet serialization make additional full-size copies.
    if (file.content.length > absolutePayloadUpperBound) {
      return PrivateMediaPreparation.rejected(
        'File exceeds the private-media v1 limit of 256 final mesh fragments');
    }

    const policy: PrivateMediaPolicyDecision = this.deps.policyProvider(recipientPeerID);
    let mode: PrivateMediaWireMode;
    if (policy.kind === PrivateMediaPolicyKind.ENCRYPTED) {
      mode = PrivateMediaWireMode.ENCRYPTED_NOISE_0X20;
    } else if (policy.kind === PrivateMediaPolicyKind.REQUIRES_LEGACY_CONSENT) {
      if (!allowLegacyFallback) {
        return PrivateMediaPreparation.requiresLegacyConsent(
          'This older client cannot receive encrypted private media. ' +
            'Sending this one file will expose its contents to mesh relays, ' +
            'although the directed packet will still be signed.');
      }
      mode = PrivateMediaWireMode.SIGNED_DIRECTED_RAW_0X22;
    } else if (policy.kind === PrivateMediaPolicyKind.NEEDS_HANDSHAKE) {
      return PrivateMediaPreparation.needsHandshake();
    } else if (policy.kind === PrivateMediaPolicyKind.AWAITING_PEER_STATE) {
      return PrivateMediaPreparation.awaitingPeerState();
    } else {
      const blockedReason: string = policy.reason ?? 'Private media send was blocked';
      return PrivateMediaPreparation.rejected(blockedReason);
    }

    const filePayload: Uint8Array | null = file.encode();
    if (filePayload === null) {
      return PrivateMediaPreparation.rejected('Failed to encode private media');
    }

    let packet: BitchatPacket;
    if (mode === PrivateMediaWireMode.ENCRYPTED_NOISE_0X20) {
      const session: AuthenticatedNoiseSession | null = policy.authenticatedSession;
      if (session === null) {
        return PrivateMediaPreparation.rejected(
          'The authenticated Noise session could not encrypt this file');
      }
      const plaintext: Uint8Array =
        new NoisePayload(NoisePayloadType.FILE_TRANSFER, filePayload).encode();
      let encryption: PrivateMediaEncryptionResult;
      try {
        encryption = this.deps.encrypt(plaintext, recipientPeerID, session);
      } catch (e) {
        encryption = PrivateMediaEncryptionResult.failed();
      }
      if (encryption.outcome === PrivateMediaEncryptionOutcome.GENERATION_CHANGED) {
        if (generationRetriesRemaining > 0) {
          return this.prepareWithGenerationRetries(recipientPeerID, recipientID,
            file, transferId, allowLegacyFallback, generationRetriesRemaining - 1);
        }
        return PrivateMediaPreparation.awaitingPeerState();
      }
      const ciphertext: Uint8Array | null = encryption.ciphertext;
      if (encryption.outcome !== PrivateMediaEncryptionOutcome.SUCCESS ||
        ciphertext === null) {
        return PrivateMediaPreparation.rejected(
          'The authenticated Noise session could not encrypt this file');
      }
      packet = new BitchatPacket(
        ciphertext.length > 0xFFFF ? 2 : 1,
        MessageType.NOISE_ENCRYPTED,
        new Uint8Array(this.deps.senderID),
        new Uint8Array(recipientID),
        this.deps.now(),
        ciphertext,
        null,
        this.deps.ttl,
        null);
    } else {
      packet = new BitchatPacket(
        2,
        MessageType.FILE_TRANSFER,
        new Uint8Array(this.deps.senderID),
        new Uint8Array(recipientID),
        this.deps.now(),
        filePayload,
        null,
        this.deps.ttl,
        null);
    }

    const finalized: BitchatPacket | null = this.deps.finalizeRoutedAndSigned(packet);
    if (finalized === null) {
      return PrivateMediaPreparation.rejected(
        mode === PrivateMediaWireMode.SIGNED_DIRECTED_RAW_0X22
          ? 'Could not sign the legacy private-media packet; nothing was sent'
          : 'Could not sign the encrypted private-media packet; nothing was sent');
    }
    if (finalized.signature === null || finalized.signature.length !== 64) {
      return PrivateMediaPreparation.rejected(
        'Could not produce a valid Ed25519 private-media signature; nothing was sent');
    }

    const fragments: BitchatPacket[] =
      this.deps.fragment(finalized, maxPrivateFragments);
    if (fragments.length === 0 || fragments.length > maxPrivateFragments) {
      return PrivateMediaPreparation.rejected(
        'File exceeds the private-media v1 limit of 256 final mesh fragments');
    }

    const built: BuiltPrivateMediaTransfer =
      new BuiltPrivateMediaTransfer(finalized, fragments, mode);
    const commitAction = (): boolean => this.deps.commitPrepared(transferId, built);
    const transfer: PreparedPrivateMediaTransfer =
      new PreparedPrivateMediaTransfer(transferId, mode, commitAction);
    return PrivateMediaPreparation.ready(transfer, built);
  }
}

/** One-shot consent request shown before any legacy 0x22 send. */
export class LegacyPrivateMediaConsentRequest {
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

/** A first-send intent retained while session setup is in flight. */
export class PrivateMediaSendIntent {
  readonly requestId: string;
  readonly conversationID: string;
  readonly recipientMeshPeerID: string;
  readonly filePacket: BitchatFilePacket;
  readonly filePath: string;
  /** BitchatMessageType passthrough for the wiring layer's local echo. */
  readonly messageType: number;
  readonly transferId: string;
  readonly allowLegacyFallback: boolean;

  constructor(requestId: string, conversationID: string,
    recipientMeshPeerID: string, filePacket: BitchatFilePacket,
    filePath: string, messageType: number, transferId: string,
    allowLegacyFallback: boolean) {
    this.requestId = requestId;
    this.conversationID = conversationID;
    this.recipientMeshPeerID = recipientMeshPeerID;
    this.filePacket = filePacket;
    this.filePath = filePath;
    this.messageType = messageType;
    this.transferId = transferId;
    this.allowLegacyFallback = allowLegacyFallback;
  }
}

/** A consent prompt held open until approved, cancelled, or replaced. */
class PendingPrivateMediaConsent {
  readonly request: LegacyPrivateMediaConsentRequest;
  readonly conversationID: string;
  readonly recipientMeshPeerID: string;
  readonly filePacket: BitchatFilePacket;
  readonly filePath: string;
  readonly messageType: number;
  readonly transferId: string;

  constructor(request: LegacyPrivateMediaConsentRequest,
    conversationID: string, recipientMeshPeerID: string,
    filePacket: BitchatFilePacket, filePath: string,
    messageType: number, transferId: string) {
    this.request = request;
    this.conversationID = conversationID;
    this.recipientMeshPeerID = recipientMeshPeerID;
    this.filePacket = filePacket;
    this.filePath = filePath;
    this.messageType = messageType;
    this.transferId = transferId;
  }
}

/** Injected dependencies of PrivateMediaSendIntentManager. */
export interface PrivateMediaSendIntentDeps {
  prepareFilePrivate: (recipientPeerID: string, file: BitchatFilePacket,
    transferId: string, allowLegacyFallback: boolean) => PrivateMediaPreparation;
  initiateNoiseHandshake: (recipientMeshPeerID: string) => void;
  nicknameFor: (recipientMeshPeerID: string) => string | null;
  addSystemMessage: (conversationID: string, text: string) => void;
  /** Local echo plus commit for an admitted transfer. */
  onReady: (preparation: PrivateMediaPreparation,
    intent: PrivateMediaSendIntent) => void;
  schedule: (delayMs: number, action: () => void) => void;
  randomId: () => string;
}

/**
 * Pending-intent and legacy-consent state machine of
 * MediaSendingManager.kt: at most one automatic private-media send may be
 * pending; NeedsHandshake / AwaitingPeerState retain the first-send intent
 * for up to 15 seconds; legacy consent is consumed exactly once and a
 * re-run of policy may upgrade the send to encrypted.
 */
export class PrivateMediaSendIntentManager {
  static readonly PENDING_TIMEOUT_MS: number = 15000;

  private readonly deps: PrivateMediaSendIntentDeps;
  private pendingConsent: PendingPrivateMediaConsent | null = null;
  private pendingIntent: PrivateMediaSendIntent | null = null;
  private evaluatingRequestId: string | null = null;
  private retryRequestedFor: string | null = null;
  private timeoutStartedFor: string | null = null;
  private consentRequest: LegacyPrivateMediaConsentRequest | null = null;

  constructor(deps: PrivateMediaSendIntentDeps) {
    this.deps = deps;
  }

  /** The consent prompt currently shown, if any (binds the UI dialog). */
  currentConsentRequest(): LegacyPrivateMediaConsentRequest | null {
    return this.consentRequest;
  }

  submitPrivateMedia(recipientMeshPeerID: string, conversationID: string,
    filePacket: BitchatFilePacket, filePath: string, messageType: number,
    transferId: string): void {
    const intent: PrivateMediaSendIntent = new PrivateMediaSendIntent(
      this.deps.randomId(), conversationID, recipientMeshPeerID,
      filePacket, filePath, messageType, transferId, false);
    if (!this.reservePending(intent)) {
      this.deps.addSystemMessage(conversationID,
        'Private media was not sent because another secure media send is still pending.');
      return;
    }
    this.evaluateIntent(intent);
  }

  /**
   * Consume consent exactly once, then re-run policy and final-packet
   * admission. A capability pin appearing while the dialog was open
   * upgrades this send to encrypted rather than forcing the legacy path.
   */
  approveLegacyPrivateMedia(requestId: string): void {
    const consumed: PendingPrivateMediaConsent | null =
      this.consumePendingConsent(requestId);
    if (consumed === null) {
      return;
    }
    const intent: PrivateMediaSendIntent = new PrivateMediaSendIntent(
      this.deps.randomId(), consumed.conversationID,
      consumed.recipientMeshPeerID, consumed.filePacket, consumed.filePath,
      consumed.messageType, consumed.transferId, true);
    if (!this.reservePending(intent)) {
      this.deps.addSystemMessage(consumed.conversationID,
        'Private media was not sent because another secure media send is still pending.');
      return;
    }
    this.evaluateIntent(intent);
  }

  cancelLegacyPrivateMedia(requestId: string): void {
    this.consumePendingConsent(requestId);
  }

  clearPendingPrivateMediaConsent(): void {
    this.pendingConsent = null;
    this.pendingIntent = null;
    this.evaluatingRequestId = null;
    this.retryRequestedFor = null;
    this.timeoutStartedFor = null;
    this.consentRequest = null;
  }

  /** Retry the exact first-send intent after peer-state proof or watchdog resolution. */
  retryPendingPrivateMedia(peerID: string): void {
    const pending: PrivateMediaSendIntent | null = this.pendingIntent;
    if (pending === null || pending.recipientMeshPeerID !== peerID) {
      return;
    }
    this.evaluateIntent(pending);
  }

  private evaluateIntent(pending: PrivateMediaSendIntent): void {
    if (this.pendingIntent === null ||
      this.pendingIntent.requestId !== pending.requestId) {
      return;
    }
    if (this.evaluatingRequestId === pending.requestId) {
      this.retryRequestedFor = pending.requestId;
      return;
    }
    this.evaluatingRequestId = pending.requestId;
    let rerun: boolean = true;
    while (rerun) {
      let preparation: PrivateMediaPreparation;
      try {
        preparation = this.deps.prepareFilePrivate(pending.recipientMeshPeerID,
          pending.filePacket, pending.transferId, pending.allowLegacyFallback);
      } catch (e) {
        let reason: string = 'Secure private-media preparation failed';
        if (e instanceof Error && e.message !== '') {
          reason = e.message;
        }
        preparation = PrivateMediaPreparation.rejected(reason);
      }

      const stillCurrent: boolean = this.pendingIntent !== null &&
        this.pendingIntent.requestId === pending.requestId;
      if (stillCurrent) {
        this.handlePreparation(preparation, pending);
      }

      if (this.evaluatingRequestId === pending.requestId) {
        this.evaluatingRequestId = null;
      }
      let requested: boolean = false;
      if (this.retryRequestedFor === pending.requestId) {
        requested = this.pendingIntent !== null &&
          this.pendingIntent.requestId === pending.requestId;
        this.retryRequestedFor = null;
        if (requested) {
          this.evaluatingRequestId = pending.requestId;
        }
      }
      rerun = requested;
    }
  }

  private handlePreparation(preparation: PrivateMediaPreparation,
    pending: PrivateMediaSendIntent): void {
    if (preparation.kind === PrivateMediaPreparationKind.READY) {
      this.clearPendingFor(pending.requestId);
      this.deps.onReady(preparation, pending);
      return;
    }
    if (preparation.kind === PrivateMediaPreparationKind.REQUIRES_LEGACY_CONSENT) {
      this.clearPendingFor(pending.requestId);
      if (pending.allowLegacyFallback) {
        // Legacy consent was consumed but policy still requested consent.
        this.deps.addSystemMessage(pending.conversationID,
          'Private media was not sent because its security policy changed.');
        return;
      }
      let nickname: string | null = null;
      try {
        nickname = this.deps.nicknameFor(pending.recipientMeshPeerID);
      } catch (e) {
        nickname = null;
      }
      const fallback: string = pending.recipientMeshPeerID.length > 8
        ? pending.recipientMeshPeerID.substring(0, 8)
        : pending.recipientMeshPeerID;
      const displayName: string = nickname !== null && nickname !== ''
        ? nickname : fallback;
      const request: LegacyPrivateMediaConsentRequest =
        new LegacyPrivateMediaConsentRequest(this.deps.randomId(),
          displayName, pending.filePacket.fileName,
          preparation.warning ?? '');
      if (this.pendingConsent !== null) {
        // A legacy private-media consent prompt is already pending.
        return;
      }
      this.pendingConsent = new PendingPrivateMediaConsent(request,
        pending.conversationID, pending.recipientMeshPeerID,
        pending.filePacket, pending.filePath, pending.messageType,
        pending.transferId);
      this.consentRequest = request;
      return;
    }
    if (preparation.kind === PrivateMediaPreparationKind.NEEDS_HANDSHAKE) {
      this.ensurePendingTimeout(pending);
      try {
        this.deps.initiateNoiseHandshake(pending.recipientMeshPeerID);
      } catch (e) {
        // Could not initiate the private-media Noise handshake; the
        // retained intent and its timeout still apply.
      }
      return;
    }
    if (preparation.kind === PrivateMediaPreparationKind.AWAITING_PEER_STATE) {
      this.ensurePendingTimeout(pending);
      return;
    }
    // PrivateMediaPreparationKind.REJECTED
    this.clearPendingFor(pending.requestId);
    const reason: string = preparation.reason ??
      'Secure private-media preparation failed';
    this.deps.addSystemMessage(pending.conversationID,
      `Private media was not sent: ${reason}`);
  }

  private ensurePendingTimeout(pending: PrivateMediaSendIntent): void {
    if (this.pendingIntent === null ||
      this.pendingIntent.requestId !== pending.requestId) {
      return;
    }
    if (this.timeoutStartedFor === pending.requestId) {
      return;
    }
    this.timeoutStartedFor = pending.requestId;
    const requestId: string = pending.requestId;
    const conversationID: string = pending.conversationID;
    this.deps.schedule(PrivateMediaSendIntentManager.PENDING_TIMEOUT_MS,
      (): void => {
        const current: PrivateMediaSendIntent | null = this.pendingIntent;
        if (current === null || current.requestId !== requestId) {
          return;
        }
        this.pendingIntent = null;
        if (this.retryRequestedFor === requestId) {
          this.retryRequestedFor = null;
        }
        if (this.timeoutStartedFor === requestId) {
          this.timeoutStartedFor = null;
        }
        this.deps.addSystemMessage(conversationID,
          'Private media was not sent because secure session setup timed out.');
      });
  }

  private reservePending(intent: PrivateMediaSendIntent): boolean {
    if (this.pendingIntent !== null) {
      return false;
    }
    this.pendingIntent = intent;
    return true;
  }

  private clearPendingFor(requestId: string): void {
    if (this.pendingIntent !== null &&
      this.pendingIntent.requestId === requestId) {
      this.pendingIntent = null;
    }
    if (this.retryRequestedFor === requestId) {
      this.retryRequestedFor = null;
    }
    if (this.timeoutStartedFor === requestId) {
      this.timeoutStartedFor = null;
    }
  }

  private consumePendingConsent(requestId: string): PendingPrivateMediaConsent | null {
    const pending: PendingPrivateMediaConsent | null = this.pendingConsent;
    if (pending === null || pending.request.requestId !== requestId) {
      return null;
    }
    this.pendingConsent = null;
    this.consentRequest = null;
    return pending;
  }
}
