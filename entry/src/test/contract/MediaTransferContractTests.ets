/**
 * Private media transfer contract tests (US10, T052): the send-policy
 * matrix (PrivateMediaSecurityController parity with Android
 * PrivateMediaSecurity.kt), the preparer's build/route/sign/fragment
 * admission (encrypted 0x20 path with the single Noise-generation retry,
 * legacy signed 0x22 path after explicit consent, the 256-fragment
 * absolute payload bound, single-use commit), transfer progress events,
 * and the pending-intent / legacy-consent state machine (15s first-send
 * intent retention, consent consumed exactly once, re-entrancy rerun).
 *
 * Every device dependency (Noise sessions, signer, fragmenter, scheduler)
 * is stubbed, so the suite runs synchronously on the host harness.
 */
import { ContractAssert } from './ContractAssert';
import { PrivateMediaSecurityDeps } from '../../main/ets/service/media/MediaTransferManager';
import { PrivateMediaTransferPreparerDeps } from '../../main/ets/service/media/MediaTransferManager';
import { PrivateMediaSendIntentDeps } from '../../main/ets/service/media/MediaTransferManager';
import {
  BuiltPrivateMediaTransfer,
  PrivateMediaEncryptionResult,
  PrivateMediaPolicyDecision,
  PrivateMediaPolicyKind,
  PrivateMediaPreparation,
  PrivateMediaPreparationKind,
  PrivateMediaSecurityController,
  PrivateMediaSendIntent,
  PrivateMediaSendIntentManager,
  PrivateMediaTransferPreparer,
  PrivateMediaWireMode,
  PreparedPrivateMediaTransfer,
  TransferProgressEvent,
  TransferProgressManager,
} from '../../main/ets/service/media/MediaTransferManager';
import { BitchatFilePacket } from '../../main/ets/model/FragmentModels';
import { BitchatPacket, MessageType } from '../../main/ets/model/BitchatPacket';
import { AuthenticatedPeerState, NoisePayload, NoisePayloadType, PeerCapabilities } from '../../main/ets/model/IdentityModels';
import { AuthenticatedNoiseSession } from '../../main/ets/service/noise/NoiseSessionManager';
import { PeerStateStatus } from '../../main/ets/service/mesh/PeerStateManager';

function mediaFilled(length: number, value: number): Uint8Array {
  const out: Uint8Array = new Uint8Array(length);
  for (let i: number = 0; i < length; i++) {
    out[i] = value;
  }
  return out;
}

function mediaDummyPacket(): BitchatPacket {
  return new BitchatPacket(1, MessageType.NOISE_ENCRYPTED, mediaFilled(8, 0x01),
    mediaFilled(8, 0x02), 1, new Uint8Array([0x20, 0x00]), mediaFilled(64, 0x0A), 7, null);
}

/** Manually-fired scheduler: captures tasks and their delays. */
class MediaFakeScheduler {
  private readonly tasks: Array<() => void> = [];
  scheduledCount: number = 0;
  lastDelayMs: number = -1;

  schedule(delayMs: number, task: () => void): void {
    this.scheduledCount += 1;
    this.lastDelayMs = delayMs;
    this.tasks.push(task);
  }

  fireAll(): void {
    const snapshot: Array<() => void> = this.tasks.slice();
    this.tasks.length = 0;
    for (let i: number = 0; i < snapshot.length; i++) {
      snapshot[i]();
    }
  }
}

/** Stubs every preparer dependency; records every side effect. */
class PreparerRig {
  policy: PrivateMediaPolicyDecision =
    PrivateMediaPolicyDecision.needsHandshake();
  policyCalls: number = 0;
  encryptResults: PrivateMediaEncryptionResult[] = [];
  encryptCalls: number = 0;
  encryptThrow: boolean = false;
  lastPlaintext: Uint8Array | null = null;
  lastSession: AuthenticatedNoiseSession | null = null;
  finalizeSigns: boolean = true;
  finalizeSignatureLength: number = 64;
  fragmentCount: number = 1;
  fragmentShouldEmpty: boolean = false;
  lastFragmentMax: number = -1;
  commitCalls: number = 0;
  commitResult: boolean = true;
  lastCommitTransferId: string = '';
  lastCommitBuilt: BuiltPrivateMediaTransfer | null = null;
  nowValue: number = 1700000000000;
  senderID: Uint8Array = mediaFilled(8, 0x5A);
  ttl: number = 7;

  build(): PrivateMediaTransferPreparer {
    const deps: PrivateMediaTransferPreparerDeps = {
      senderID: this.senderID,
      ttl: this.ttl,
      policyProvider: (recipientPeerID: string): PrivateMediaPolicyDecision => {
        this.policyCalls += 1;
        return this.policy;
      },
      encrypt: (plaintext: Uint8Array, recipientPeerID: string,
        authenticatedSession: AuthenticatedNoiseSession): PrivateMediaEncryptionResult => {
        this.encryptCalls += 1;
        this.lastPlaintext = plaintext;
        this.lastSession = authenticatedSession;
        if (this.encryptThrow) {
          throw new Error('noise encryption exploded');
        }
        const index: number = this.encryptCalls - 1;
        if (index < this.encryptResults.length) {
          return this.encryptResults[index];
        }
        return PrivateMediaEncryptionResult.failed();
      },
      finalizeRoutedAndSigned: (packet: BitchatPacket): BitchatPacket | null => {
        if (!this.finalizeSigns) {
          return null;
        }
        packet.signature = mediaFilled(this.finalizeSignatureLength, 0x0B);
        return packet;
      },
      fragment: (packet: BitchatPacket, maxFragments: number): BitchatPacket[] => {
        this.lastFragmentMax = maxFragments;
        if (this.fragmentShouldEmpty) {
          return [];
        }
        const out: BitchatPacket[] = [];
        for (let i: number = 0; i < this.fragmentCount; i++) {
          out.push(packet);
        }
        return out;
      },
      commitPrepared: (transferId: string,
        built: BuiltPrivateMediaTransfer): boolean => {
        this.commitCalls += 1;
        this.lastCommitTransferId = transferId;
        this.lastCommitBuilt = built;
        return this.commitResult;
      },
      now: (): number => this.nowValue
    };
    return new PrivateMediaTransferPreparer(deps);
  }
}

/** Stubs the security controller's peer-state/session lookups. */
class SecurityRig {
  session: AuthenticatedNoiseSession | null =
    new AuthenticatedNoiseSession(mediaFilled(32, 0x33), mediaFilled(32, 0x71));
  status: PeerStateStatus = PeerStateStatus.MISSING;
  provenState: AuthenticatedPeerState | null = null;
  pinned: boolean = false;

  controller(): PrivateMediaSecurityController {
    const deps: PrivateMediaSecurityDeps = {
      authenticatedSessionProvider: (peerID: string): AuthenticatedNoiseSession | null => {
        return this.session;
      },
      peerStateStatusProvider: (peerID: string,
        authenticatedSession: AuthenticatedNoiseSession): PeerStateStatus => {
        return this.status;
      },
      provenStateProvider: (peerID: string,
        authenticatedSession: AuthenticatedNoiseSession): AuthenticatedPeerState | null => {
        return this.provenState;
      },
      isPrivateMediaPinned: (peerID: string): boolean => {
        return this.pinned;
      }
    };
    return new PrivateMediaSecurityController(deps);
  }
}

/** Stubs the intent manager's mesh/UI dependencies. */
class IntentRig {
  readonly scheduler: MediaFakeScheduler = new MediaFakeScheduler();
  preparations: PrivateMediaPreparation[] = [];
  prepareCalls: number = 0;
  allowFallbackByCall: boolean[] = [];
  handshakes: string[] = [];
  onHandshake: ((peerID: string) => void) | null = null;
  systemMessages: string[] = [];
  readyCount: number = 0;
  lastReadyPreparation: PrivateMediaPreparation | null = null;
  nicknames: Map<string, string> = new Map();
  private nextId: number = 1;
  readonly manager: PrivateMediaSendIntentManager;

  constructor() {
    const deps: PrivateMediaSendIntentDeps = {
      prepareFilePrivate: (recipientPeerID: string, file: BitchatFilePacket,
        transferId: string,
        allowLegacyFallback: boolean): PrivateMediaPreparation => {
        this.prepareCalls += 1;
        this.allowFallbackByCall.push(allowLegacyFallback);
        const index: number = this.prepareCalls - 1;
        if (index < this.preparations.length) {
          return this.preparations[index];
        }
        return PrivateMediaPreparation.needsHandshake();
      },
      initiateNoiseHandshake: (recipientMeshPeerID: string): void => {
        this.handshakes.push(recipientMeshPeerID);
        if (this.onHandshake !== null) {
          this.onHandshake(recipientMeshPeerID);
        }
      },
      nicknameFor: (recipientMeshPeerID: string): string | null => {
        return this.nicknames.get(recipientMeshPeerID) ?? null;
      },
      addSystemMessage: (conversationID: string, text: string): void => {
        this.systemMessages.push(conversationID + '|' + text);
      },
      onReady: (preparation: PrivateMediaPreparation,
        intent: PrivateMediaSendIntent): void => {
        this.readyCount += 1;
        this.lastReadyPreparation = preparation;
      },
      schedule: (delayMs: number, action: () => void): void => {
        this.scheduler.schedule(delayMs, action);
      },
      randomId: (): string => {
        const id: string = 'id-' + this.nextId;
        this.nextId += 1;
        return id;
      }
    };
    this.manager = new PrivateMediaSendIntentManager(deps);
  }
}

function mediaReadyPreparation(transferId: string): PrivateMediaPreparation {
  const packet: BitchatPacket = mediaDummyPacket();
  const built: BuiltPrivateMediaTransfer = new BuiltPrivateMediaTransfer(
    packet, [packet], PrivateMediaWireMode.ENCRYPTED_NOISE_0X20);
  const transfer: PreparedPrivateMediaTransfer = new PreparedPrivateMediaTransfer(
    transferId, PrivateMediaWireMode.ENCRYPTED_NOISE_0X20, (): boolean => true);
  return PrivateMediaPreparation.ready(transfer, built);
}

export function runMediaTransferContractTests(t: ContractAssert): void {
  const session: AuthenticatedNoiseSession =
    new AuthenticatedNoiseSession(mediaFilled(32, 0x33), mediaFilled(32, 0x71));
  const recipientID: Uint8Array = mediaFilled(8, 0x2B);
  const file: BitchatFilePacket =
    new BitchatFilePacket('pic.jpg', 3, 'image/jpeg', new Uint8Array([1, 2, 3]));
  const filePayload: Uint8Array | null = file.encode();
  t.isNotNull(filePayload, 'test file encodes');

  // ------------------------------------------------------------------
  // Transfer progress events
  // ------------------------------------------------------------------
  {
    const progress: TransferProgressManager = new TransferProgressManager();
    const events: TransferProgressEvent[] = [];
    const recorder = (event: TransferProgressEvent): void => {
      events.push(event);
    };
    progress.addListener(recorder);
    let boomCount: number = 0;
    progress.addListener((_event: TransferProgressEvent): void => {
      boomCount += 1;
      throw new Error('broken observer');
    });
    progress.start('tid', 10);
    progress.progress('tid', 5, 10);
    progress.progress('tid', 10, 10);
    progress.complete('tid', 10);
    progress.fail('tid2');
    t.equalNumber(5, events.length, 'one event per progress call');
    t.equalNumber(0, events[0].sent, 'start begins at zero');
    t.isFalse(events[0].completed, 'start is not completed');
    t.isFalse(events[1].completed, 'partial progress is not completed');
    t.isTrue(events[2].completed, 'sent >= total completes progress');
    t.isTrue(events[3].completed, 'complete is completed');
    t.isTrue(events[4].failed, 'fail marks the transfer failed');
    t.equalNumber(5, boomCount, 'broken observer still invoked');
    progress.removeListener(recorder);
    progress.start('tid3', 1);
    t.equalNumber(5, events.length, 'removed listener receives nothing');
  }

  // ------------------------------------------------------------------
  // PreparedPrivateMediaTransfer is single-use, even after failed commit
  // ------------------------------------------------------------------
  {
    let commits: number = 0;
    const ok: PreparedPrivateMediaTransfer = new PreparedPrivateMediaTransfer(
      't1', PrivateMediaWireMode.ENCRYPTED_NOISE_0X20, (): boolean => {
        commits += 1;
        return true;
      });
    t.isTrue(ok.commit(), 'first commit succeeds');
    t.isFalse(ok.commit(), 'second commit is refused');
    t.equalNumber(1, commits, 'commit action ran exactly once');

    let failingCommits: number = 0;
    const failing: PreparedPrivateMediaTransfer = new PreparedPrivateMediaTransfer(
      't2', PrivateMediaWireMode.SIGNED_DIRECTED_RAW_0X22, (): boolean => {
        failingCommits += 1;
        return false;
      });
    t.isFalse(failing.commit(), 'failing commit reports failure');
    t.isFalse(failing.commit(), 'failed transfer cannot be retried');
    t.equalNumber(1, failingCommits, 'failed commit action ran exactly once');
  }

  // ------------------------------------------------------------------
  // Send-policy matrix (PrivateMediaSecurityController)
  // ------------------------------------------------------------------
  {
    const rig: SecurityRig = new SecurityRig();

    rig.session = null;
    t.equalNumber(PrivateMediaPolicyKind.NEEDS_HANDSHAKE,
      rig.controller().sendPolicy('peer-a').kind, 'no session needs handshake');
    rig.session = new AuthenticatedNoiseSession(mediaFilled(31, 0x33), mediaFilled(32, 0x71));
    t.equalNumber(PrivateMediaPolicyKind.NEEDS_HANDSHAKE,
      rig.controller().sendPolicy('peer-a').kind, 'short remote static key needs handshake');
    rig.session = new AuthenticatedNoiseSession(mediaFilled(32, 0x33), mediaFilled(31, 0x71));
    t.equalNumber(PrivateMediaPolicyKind.NEEDS_HANDSHAKE,
      rig.controller().sendPolicy('peer-a').kind, 'short session token needs handshake');

    rig.session = session;
    rig.status = PeerStateStatus.AWAITING;
    t.equalNumber(PrivateMediaPolicyKind.AWAITING_PEER_STATE,
      rig.controller().sendPolicy('peer-a').kind, 'awaiting generation is awaiting peer state');
    rig.status = PeerStateStatus.MISSING;
    t.equalNumber(PrivateMediaPolicyKind.AWAITING_PEER_STATE,
      rig.controller().sendPolicy('peer-a').kind,
      'missing generation gap is never treated as timeout');

    rig.status = PeerStateStatus.PROVEN;
    rig.provenState =
      new AuthenticatedPeerState(PeerCapabilities.PRIVATE_MEDIA, mediaFilled(32, 0x44));
    const encrypted: PrivateMediaPolicyDecision = rig.controller().sendPolicy('peer-a');
    t.equalNumber(PrivateMediaPolicyKind.ENCRYPTED, encrypted.kind,
      'proven private-media capability sends encrypted');
    t.isNotNull(encrypted.authenticatedSession, 'encrypted decision carries the session');
    if (encrypted.authenticatedSession !== null) {
      t.isTrue(session.equals(encrypted.authenticatedSession),
        'encrypted decision carries the live session');
    }

    rig.provenState =
      new AuthenticatedPeerState(PeerCapabilities.NONE, mediaFilled(32, 0x44));
    t.equalNumber(PrivateMediaPolicyKind.REQUIRES_LEGACY_CONSENT,
      rig.controller().sendPolicy('peer-a').kind,
      'proven without capability asks for legacy consent');
    rig.pinned = true;
    const blockedProven: PrivateMediaPolicyDecision = rig.controller().sendPolicy('peer-a');
    t.equalNumber(PrivateMediaPolicyKind.BLOCKED, blockedProven.kind,
      'pin plus proven non-support blocks the send');
    t.equalString('Encrypted private media was previously pinned, but this session proved no support; send blocked',
      blockedProven.reason ?? '', 'blocked proven reason is exact');

    rig.status = PeerStateStatus.TIMED_OUT;
    rig.pinned = false;
    t.equalNumber(PrivateMediaPolicyKind.REQUIRES_LEGACY_CONSENT,
      rig.controller().sendPolicy('peer-a').kind,
      'timed out without pin asks for legacy consent');
    rig.pinned = true;
    const blockedTimedOut: PrivateMediaPolicyDecision = rig.controller().sendPolicy('peer-a');
    t.equalNumber(PrivateMediaPolicyKind.BLOCKED, blockedTimedOut.kind,
      'pin plus watchdog timeout blocks the send');
    t.equalString('Encrypted private media was previously pinned, but this session did not provide authenticated peer state',
      blockedTimedOut.reason ?? '', 'blocked timeout reason is exact');
  }

  // ------------------------------------------------------------------
  // Preparer: encrypted 0x20 path
  // ------------------------------------------------------------------
  {
    const rig: PreparerRig = new PreparerRig();
    rig.policy = PrivateMediaPolicyDecision.encrypted(session);
    rig.encryptResults = [PrivateMediaEncryptionResult.success(new Uint8Array([0xAA, 0xBB]))];
    const preparation: PrivateMediaPreparation =
      rig.build().prepare('peer-a', recipientID, file, 'tid-1', false);
    t.equalNumber(PrivateMediaPreparationKind.READY, preparation.kind,
      'encrypted policy prepares a transfer');
    t.isNotNull(preparation.built, 'ready preparation carries the built packet');
    t.isNotNull(preparation.transfer, 'ready preparation carries the transfer handle');
    if (preparation.built !== null && preparation.transfer !== null) {
      const packet: BitchatPacket = preparation.built.packet;
      t.equalNumber(MessageType.NOISE_ENCRYPTED, packet.type,
        'encrypted private media rides NOISE_ENCRYPTED');
      t.equalNumber(PrivateMediaWireMode.ENCRYPTED_NOISE_0X20, preparation.built.wireMode,
        'wire mode is encrypted 0x20');
      t.equalNumber(1, packet.version, 'small ciphertext keeps version 1');
      t.equalNumber(rig.nowValue, packet.timestamp, 'packet timestamp uses injected clock');
      t.equalNumber(rig.ttl, packet.ttl, 'packet ttl is injected');
      t.equalBytes(rig.senderID, packet.senderId, 'sender id is copied from deps');
      t.equalBytes(recipientID, packet.recipientId ?? new Uint8Array(0),
        'packet is directed at the recipient');
      t.isFalse(BitchatPacket.isBroadcastRecipient(packet.recipientId),
        'private media is never broadcast');
      t.equalBytes(new Uint8Array([0xAA, 0xBB]), packet.payload,
        'payload is the session ciphertext');
      t.equalNumber(64, packet.signature?.length ?? 0,
        'finalized packet carries a 64-byte signature');
      t.equalNumber(1, preparation.built.fragments.length, 'one admitted fragment');
      t.equalNumber(256, rig.lastFragmentMax, 'fragmenter cap is 256');
      t.equalString('tid-1', preparation.transfer.transferId, 'transfer id is preserved');
      if (filePayload !== null) {
        const expectedPlaintext: Uint8Array =
          new NoisePayload(NoisePayloadType.FILE_TRANSFER, filePayload).encode();
        t.equalBytes(expectedPlaintext, rig.lastPlaintext ?? new Uint8Array(0),
          'encrypted payload wraps the file TLV in NoisePayload 0x20');
      }
      t.isTrue(session.equals(rig.lastSession ?? session),
        'encrypt received the authenticated session');
    }
  }

  {
    const rig: PreparerRig = new PreparerRig();
    rig.policy = PrivateMediaPolicyDecision.encrypted(session);
    rig.encryptResults = [PrivateMediaEncryptionResult.success(mediaFilled(70000, 0xCC))];
    const preparation: PrivateMediaPreparation =
      rig.build().prepare('peer-a', recipientID, file, 'tid-2', false);
    t.equalNumber(PrivateMediaPreparationKind.READY, preparation.kind, 'large ciphertext prepares');
    if (preparation.built !== null) {
      t.equalNumber(2, preparation.built.packet.version,
        'ciphertext above 0xFFFF uses packet version 2');
    }
  }

  {
    // One retry when the Noise generation changes between policy and encrypt.
    const rig: PreparerRig = new PreparerRig();
    rig.policy = PrivateMediaPolicyDecision.encrypted(session);
    rig.encryptResults = [
      PrivateMediaEncryptionResult.generationChanged(),
      PrivateMediaEncryptionResult.success(new Uint8Array([0x01])),
    ];
    const preparation: PrivateMediaPreparation =
      rig.build().prepare('peer-a', recipientID, file, 'tid-3', false);
    t.equalNumber(PrivateMediaPreparationKind.READY, preparation.kind,
      'generation change retries once');
    t.equalNumber(2, rig.encryptCalls, 'retry re-encrypts exactly once');
    t.equalNumber(2, rig.policyCalls, 'retry re-runs the policy lookup');
  }

  {
    const rig: PreparerRig = new PreparerRig();
    rig.policy = PrivateMediaPolicyDecision.encrypted(session);
    rig.encryptResults = [
      PrivateMediaEncryptionResult.generationChanged(),
      PrivateMediaEncryptionResult.generationChanged(),
    ];
    const preparation: PrivateMediaPreparation =
      rig.build().prepare('peer-a', recipientID, file, 'tid-4', false);
    t.equalNumber(PrivateMediaPreparationKind.AWAITING_PEER_STATE, preparation.kind,
      'persistent generation change awaits peer state');
  }

  {
    const rig: PreparerRig = new PreparerRig();
    rig.policy = PrivateMediaPolicyDecision.encrypted(session);
    rig.encryptThrow = true;
    const preparation: PrivateMediaPreparation =
      rig.build().prepare('peer-a', recipientID, file, 'tid-5', false);
    t.equalNumber(PrivateMediaPreparationKind.REJECTED, preparation.kind,
      'throwing encrypt rejects the send');
    t.equalString('The authenticated Noise session could not encrypt this file',
      preparation.reason ?? '', 'encrypt failure reason is exact');
  }

  {
    const rig: PreparerRig = new PreparerRig();
    rig.policy = PrivateMediaPolicyDecision.encrypted(session);
    const oversize: BitchatFilePacket =
      new BitchatFilePacket('big.bin', 120065, 'application/octet-stream',
        mediaFilled(120065, 0x09));
    const preparation: PrivateMediaPreparation =
      rig.build().prepare('peer-a', recipientID, oversize, 'tid-6', false);
    t.equalNumber(PrivateMediaPreparationKind.REJECTED, preparation.kind,
      'content above 256 x 469 bytes is rejected');
    t.equalString('File exceeds the private-media v1 limit of 256 final mesh fragments',
      preparation.reason ?? '', 'fragment-limit reason is exact');
    t.equalNumber(0, rig.policyCalls,
      'oversize rejection happens before any policy lookup');
    t.equalNumber(0, rig.encryptCalls, 'oversize rejection never encrypts');
  }

  {
    // TLV encoding failure (mime longer than the 2-byte TLV length).
    const rig: PreparerRig = new PreparerRig();
    rig.policy = PrivateMediaPolicyDecision.encrypted(session);
    let longMime: string = '';
    for (let i: number = 0; i < 70000; i++) {
      longMime += 'x';
    }
    const unencodable: BitchatFilePacket =
      new BitchatFilePacket('f.bin', 1, longMime, new Uint8Array([1]));
    const preparation: PrivateMediaPreparation =
      rig.build().prepare('peer-a', recipientID, unencodable, 'tid-7', false);
    t.equalNumber(PrivateMediaPreparationKind.REJECTED, preparation.kind,
      'unencodable file is rejected');
    t.equalString('Failed to encode private media', preparation.reason ?? '',
      'encode failure reason is exact');
  }

  {
    const rig: PreparerRig = new PreparerRig();
    rig.policy = PrivateMediaPolicyDecision.encrypted(session);
    rig.encryptResults = [PrivateMediaEncryptionResult.success(new Uint8Array([0x01]))];
    rig.finalizeSigns = false;
    const preparation: PrivateMediaPreparation =
      rig.build().prepare('peer-a', recipientID, file, 'tid-8', false);
    t.equalNumber(PrivateMediaPreparationKind.REJECTED, preparation.kind,
      'unsigned packet is rejected');
    t.equalString('Could not sign the encrypted private-media packet; nothing was sent',
      preparation.reason ?? '', 'encrypted sign failure reason is exact');
  }

  {
    const rig: PreparerRig = new PreparerRig();
    rig.policy = PrivateMediaPolicyDecision.encrypted(session);
    rig.encryptResults = [PrivateMediaEncryptionResult.success(new Uint8Array([0x01]))];
    rig.finalizeSignatureLength = 63;
    const preparation: PrivateMediaPreparation =
      rig.build().prepare('peer-a', recipientID, file, 'tid-9', false);
    t.equalNumber(PrivateMediaPreparationKind.REJECTED, preparation.kind,
      'non-64-byte signature is rejected');
    t.equalString('Could not produce a valid Ed25519 private-media signature; nothing was sent',
      preparation.reason ?? '', 'ed25519 admission reason is exact');
  }

  {
    const rig: PreparerRig = new PreparerRig();
    rig.policy = PrivateMediaPolicyDecision.encrypted(session);
    rig.encryptResults = [PrivateMediaEncryptionResult.success(new Uint8Array([0x01]))];
    rig.fragmentShouldEmpty = true;
    const empty: PrivateMediaPreparation =
      rig.build().prepare('peer-a', recipientID, file, 'tid-10', false);
    t.equalNumber(PrivateMediaPreparationKind.REJECTED, empty.kind,
      'empty fragment set is rejected');
    t.equalString('File exceeds the private-media v1 limit of 256 final mesh fragments',
      empty.reason ?? '', 'empty fragment reason is exact');

    const rig2: PreparerRig = new PreparerRig();
    rig2.policy = PrivateMediaPolicyDecision.encrypted(session);
    rig2.encryptResults = [PrivateMediaEncryptionResult.success(new Uint8Array([0x01]))];
    rig2.fragmentCount = 257;
    const tooMany: PrivateMediaPreparation =
      rig2.build().prepare('peer-a', recipientID, file, 'tid-11', false);
    t.equalNumber(PrivateMediaPreparationKind.REJECTED, tooMany.kind,
      'more than 256 fragments is rejected');
    t.equalString('File exceeds the private-media v1 limit of 256 final mesh fragments',
      tooMany.reason ?? '', 'over-fragment reason is exact');
  }

  {
    // Commit dispatches the admitted fragments exactly once.
    const rig: PreparerRig = new PreparerRig();
    rig.policy = PrivateMediaPolicyDecision.encrypted(session);
    rig.encryptResults = [PrivateMediaEncryptionResult.success(new Uint8Array([0xEE]))];
    const preparation: PrivateMediaPreparation =
      rig.build().prepare('peer-a', recipientID, file, 'tid-12', false);
    t.equalNumber(PrivateMediaPreparationKind.READY, preparation.kind, 'commit rig prepares');
    if (preparation.transfer !== null) {
      t.isTrue(preparation.transfer.commit(), 'commit dispatches and reports success');
      t.isFalse(preparation.transfer.commit(), 'second commit is refused');
      t.equalNumber(1, rig.commitCalls, 'commitPrepared ran exactly once');
      t.equalString('tid-12', rig.lastCommitTransferId, 'commit carries the transfer id');
      t.isNotNull(rig.lastCommitBuilt, 'commit carries the built transfer');

      rig.commitResult = false;
      rig.encryptResults.push(PrivateMediaEncryptionResult.success(new Uint8Array([0xEF])));
      const failedPrep: PrivateMediaPreparation =
        rig.build().prepare('peer-a', recipientID, file, 'tid-13', false);
      if (failedPrep.transfer !== null) {
        t.isFalse(failedPrep.transfer.commit(), 'failed commit reports failure');
        t.isFalse(failedPrep.transfer.commit(), 'failed commit is not retried');
      }
      t.equalNumber(2, rig.commitCalls, 'failed commit action ran exactly once');
    }
  }

  // ------------------------------------------------------------------
  // Preparer: legacy signed 0x22 path after explicit consent
  // ------------------------------------------------------------------
  {
    const rig: PreparerRig = new PreparerRig();
    rig.policy = PrivateMediaPolicyDecision.requiresLegacyConsent();
    const preparation: PrivateMediaPreparation =
      rig.build().prepare('peer-a', recipientID, file, 'tid-14', true);
    t.equalNumber(PrivateMediaPreparationKind.READY, preparation.kind,
      'consented legacy fallback prepares');
    if (preparation.built !== null) {
      const packet: BitchatPacket = preparation.built.packet;
      t.equalNumber(PrivateMediaWireMode.SIGNED_DIRECTED_RAW_0X22,
        preparation.built.wireMode, 'wire mode is signed raw 0x22');
      t.equalNumber(MessageType.FILE_TRANSFER, packet.type,
        'legacy private media rides FILE_TRANSFER');
      t.equalNumber(2, packet.version, 'legacy packet uses version 2');
      t.isFalse(BitchatPacket.isBroadcastRecipient(packet.recipientId),
        'legacy fallback is still directed, never broadcast');
      t.equalNumber(64, packet.signature?.length ?? 0,
        'legacy packet is signed');
      if (filePayload !== null) {
        t.equalBytes(filePayload, packet.payload,
          'legacy payload is the unencrypted file TLV');
      }
    }
    t.equalNumber(0, rig.encryptCalls, 'legacy path never encrypts');
  }

  {
    const rig: PreparerRig = new PreparerRig();
    rig.policy = PrivateMediaPolicyDecision.requiresLegacyConsent();
    const preparation: PrivateMediaPreparation =
      rig.build().prepare('peer-a', recipientID, file, 'tid-15', false);
    t.equalNumber(PrivateMediaPreparationKind.REQUIRES_LEGACY_CONSENT, preparation.kind,
      'without consent the send stops at the consent gate');
    t.equalString('This older client cannot receive encrypted private media. ' +
      'Sending this one file will expose its contents to mesh relays, ' +
      'although the directed packet will still be signed.',
      preparation.warning ?? '', 'legacy consent warning is exact');
    t.equalNumber(0, rig.encryptCalls, 'consent gate never encrypts');
  }

  {
    const rig: PreparerRig = new PreparerRig();
    rig.policy = PrivateMediaPolicyDecision.requiresLegacyConsent();
    rig.finalizeSigns = false;
    const preparation: PrivateMediaPreparation =
      rig.build().prepare('peer-a', recipientID, file, 'tid-16', true);
    t.equalNumber(PrivateMediaPreparationKind.REJECTED, preparation.kind,
      'unsigned legacy packet is rejected');
    t.equalString('Could not sign the legacy private-media packet; nothing was sent',
      preparation.reason ?? '', 'legacy sign failure reason is exact');
  }

  {
    const rig: PreparerRig = new PreparerRig();
    rig.policy = PrivateMediaPolicyDecision.needsHandshake();
    t.equalNumber(PrivateMediaPreparationKind.NEEDS_HANDSHAKE,
      rig.build().prepare('peer-a', recipientID, file, 'tid-17', false).kind,
      'needs-handshake policy passes through');

    rig.policy = PrivateMediaPolicyDecision.awaitingPeerState();
    t.equalNumber(PrivateMediaPreparationKind.AWAITING_PEER_STATE,
      rig.build().prepare('peer-a', recipientID, file, 'tid-18', false).kind,
      'awaiting-peer-state policy passes through');

    rig.policy = PrivateMediaPolicyDecision.blocked('nope');
    const blocked: PrivateMediaPreparation =
      rig.build().prepare('peer-a', recipientID, file, 'tid-19', false);
    t.equalNumber(PrivateMediaPreparationKind.REJECTED, blocked.kind,
      'blocked policy rejects');
    t.equalString('nope', blocked.reason ?? '', 'blocked reason is carried through');
  }

  // ------------------------------------------------------------------
  // Pending-intent / legacy-consent state machine
  // ------------------------------------------------------------------
  {
    // NeedsHandshake retains the first-send intent with a 15s timeout.
    const rig: IntentRig = new IntentRig();
    rig.preparations = [
      PrivateMediaPreparation.needsHandshake(),
      mediaReadyPreparation('tid-20'),
    ];
    rig.manager.submitPrivateMedia('peer-a', 'conv-a', file, '/cache/pic.jpg', 2, 'tid-20');
    t.equalNumber(1, rig.prepareCalls, 'submit prepares once');
    t.equalNumber(1, rig.handshakes.length, 'needs-handshake initiates the handshake');
    t.equalNumber(1, rig.scheduler.scheduledCount, 'intent timeout scheduled');
    t.equalNumber(PrivateMediaSendIntentManager.PENDING_TIMEOUT_MS, rig.scheduler.lastDelayMs,
      'intent timeout is 15 seconds');
    t.equalNumber(0, rig.readyCount, 'nothing is committed while awaiting the handshake');

    rig.manager.retryPendingPrivateMedia('peer-b');
    t.equalNumber(1, rig.prepareCalls, 'retry for another peer is ignored');

    rig.manager.retryPendingPrivateMedia('peer-a');
    t.equalNumber(2, rig.prepareCalls, 'retry re-runs preparation');
    t.equalNumber(1, rig.readyCount, 'ready preparation reaches onReady');
    t.isFalse(rig.allowFallbackByCall[1], 'retry keeps legacy fallback off');
    t.isNull(rig.manager.currentConsentRequest(), 'no consent prompt on the encrypted path');
  }

  {
    // The 15s watchdog expires the retained intent exactly once.
    const rig: IntentRig = new IntentRig();
    rig.preparations = [PrivateMediaPreparation.needsHandshake()];
    rig.manager.submitPrivateMedia('peer-a', 'conv-a', file, '/cache/pic.jpg', 2, 'tid-21');
    rig.scheduler.fireAll();
    t.equalNumber(1, rig.systemMessages.length, 'timeout posts one system message');
    t.equalString('conv-a|Private media was not sent because secure session setup timed out.',
      rig.systemMessages[0], 'timeout message is exact');
    rig.manager.retryPendingPrivateMedia('peer-a');
    t.equalNumber(1, rig.prepareCalls, 'expired intent no longer retries');
  }

  {
    // Legacy consent is requested, consumed exactly once, and upgraded
    // through a fresh policy run with fallback enabled.
    const rig: IntentRig = new IntentRig();
    rig.nicknames.set('peer-a', 'Alice');
    rig.preparations = [
      PrivateMediaPreparation.requiresLegacyConsent('old client warning'),
      mediaReadyPreparation('tid-22'),
    ];
    rig.manager.submitPrivateMedia('peer-a', 'conv-a', file, '/cache/pic.jpg', 2, 'tid-22');
    const request = rig.manager.currentConsentRequest();
    t.isNotNull(request, 'consent gate exposes the request to the UI');
    if (request !== null) {
      t.equalString('Alice', request.recipientNickname, 'consent shows the peer nickname');
      t.equalString('pic.jpg', request.fileName, 'consent shows the file name');
      t.equalString('old client warning', request.warning, 'consent shows the warning');
    }

    rig.manager.approveLegacyPrivateMedia('wrong-id');
    t.equalNumber(1, rig.prepareCalls, 'approving a foreign request id is a no-op');
    t.isNotNull(rig.manager.currentConsentRequest(), 'wrong approval keeps the prompt open');

    rig.manager.approveLegacyPrivateMedia(request?.requestId ?? '');
    t.equalNumber(2, rig.prepareCalls, 'approval re-runs preparation');
    t.isTrue(rig.allowFallbackByCall[1], 'approval enables legacy fallback');
    t.equalNumber(1, rig.readyCount, 'consented send reaches onReady');
    t.isNull(rig.manager.currentConsentRequest(), 'approval consumes the consent prompt');
  }

  {
    // Nickname falls back to the 8-char peer id prefix.
    const rig: IntentRig = new IntentRig();
    rig.preparations = [PrivateMediaPreparation.requiresLegacyConsent('w')];
    rig.manager.submitPrivateMedia('peer-abcdefgh', 'conv-a', file, '/cache/pic.jpg', 2, 'tid-23');
    const request = rig.manager.currentConsentRequest();
    t.isNotNull(request, 'fallback consent request exists');
    if (request !== null) {
      t.equalString('peer-abc', request.recipientNickname,
        'nickname falls back to the 8-char peer prefix');
    }
  }

  {
    // Cancelling the consent prompt drops the pending send.
    const rig: IntentRig = new IntentRig();
    rig.preparations = [PrivateMediaPreparation.requiresLegacyConsent('w')];
    rig.manager.submitPrivateMedia('peer-a', 'conv-a', file, '/cache/pic.jpg', 2, 'tid-24');
    const request = rig.manager.currentConsentRequest();
    t.isNotNull(request, 'consent prompt shown');
    if (request !== null) {
      rig.manager.cancelLegacyPrivateMedia(request.requestId);
    }
    t.isNull(rig.manager.currentConsentRequest(), 'cancel closes the prompt');
    if (request !== null) {
      rig.manager.approveLegacyPrivateMedia(request.requestId);
    }
    t.equalNumber(1, rig.prepareCalls, 'approval after cancel is a no-op');
  }

  {
    // Consumed consent that still hits the consent gate aborts.
    const rig: IntentRig = new IntentRig();
    rig.preparations = [
      PrivateMediaPreparation.requiresLegacyConsent('w1'),
      PrivateMediaPreparation.requiresLegacyConsent('w2'),
    ];
    rig.manager.submitPrivateMedia('peer-a', 'conv-a', file, '/cache/pic.jpg', 2, 'tid-25');
    const request = rig.manager.currentConsentRequest();
    t.isNotNull(request, 'first consent prompt shown');
    if (request !== null) {
      rig.manager.approveLegacyPrivateMedia(request.requestId);
    }
    t.equalNumber(0, rig.readyCount, 'policy change aborts before commit');
    t.equalNumber(1, rig.systemMessages.length, 'policy change posts one message');
    t.equalString('conv-a|Private media was not sent because its security policy changed.',
      rig.systemMessages[0], 'policy change message is exact');
  }

  {
    // Only one automatic private-media send may be pending at a time.
    const rig: IntentRig = new IntentRig();
    rig.preparations = [PrivateMediaPreparation.needsHandshake()];
    rig.manager.submitPrivateMedia('peer-a', 'conv-a', file, '/cache/pic.jpg', 2, 'tid-26');
    rig.manager.submitPrivateMedia('peer-b', 'conv-b', file, '/cache/pic.jpg', 2, 'tid-27');
    t.equalNumber(1, rig.prepareCalls, 'second submit does not prepare');
    t.equalNumber(1, rig.systemMessages.length, 'second submit posts one message');
    t.equalString('conv-b|Private media was not sent because another secure media send is still pending.',
      rig.systemMessages[0], 'single-pending message is exact');
  }

  {
    // Rejections surface the reason and free the pending slot.
    const rig: IntentRig = new IntentRig();
    rig.preparations = [PrivateMediaPreparation.rejected('boom')];
    rig.manager.submitPrivateMedia('peer-a', 'conv-a', file, '/cache/pic.jpg', 2, 'tid-28');
    t.equalNumber(1, rig.systemMessages.length, 'rejection posts one message');
    t.equalString('conv-a|Private media was not sent: boom',
      rig.systemMessages[0], 'rejection message carries the reason');
    rig.preparations.push(mediaReadyPreparation('tid-29'));
    rig.manager.submitPrivateMedia('peer-a', 'conv-a', file, '/cache/pic.jpg', 2, 'tid-29');
    t.equalNumber(1, rig.readyCount, 'pending slot is free after rejection');
  }

  {
    // A prepare exception becomes a rejection with its message.
    const messages: string[] = [];
    const deps: PrivateMediaSendIntentDeps = {
      prepareFilePrivate: (recipientPeerID: string, filePacket: BitchatFilePacket,
        transferId: string,
        allowLegacyFallback: boolean): PrivateMediaPreparation => {
        throw new Error('mesh exploded');
      },
      initiateNoiseHandshake: (recipientMeshPeerID: string): void => {
      },
      nicknameFor: (recipientMeshPeerID: string): string | null => {
        return null;
      },
      addSystemMessage: (conversationID: string, text: string): void => {
        messages.push(conversationID + '|' + text);
      },
      onReady: (preparation: PrivateMediaPreparation,
        intent: PrivateMediaSendIntent): void => {
      },
      schedule: (delayMs: number, action: () => void): void => {
      },
      randomId: (): string => 'fixed-id'
    };
    const manager: PrivateMediaSendIntentManager = new PrivateMediaSendIntentManager(deps);
    manager.submitPrivateMedia('peer-a', 'conv-a', file, '/cache/pic.jpg', 2, 'tid-30');
    t.equalNumber(1, messages.length, 'exception posts one message');
    t.equalString('conv-a|Private media was not sent: mesh exploded',
      messages[0], 'exception message is surfaced');
  }

  {
    // Re-entrant retry during evaluation reruns the loop without recursion.
    const rig: IntentRig = new IntentRig();
    rig.preparations = [
      PrivateMediaPreparation.needsHandshake(),
      mediaReadyPreparation('tid-31'),
    ];
    rig.onHandshake = (peerID: string): void => {
      rig.manager.retryPendingPrivateMedia(peerID);
    };
    rig.manager.submitPrivateMedia('peer-a', 'conv-a', file, '/cache/pic.jpg', 2, 'tid-31');
    t.equalNumber(2, rig.prepareCalls, 're-entrant retry reran preparation');
    t.equalNumber(1, rig.handshakes.length, 'handshake initiated once');
    t.equalNumber(1, rig.readyCount, 'rerun reached onReady exactly once');
    t.equalNumber(1, rig.scheduler.scheduledCount, 'timeout scheduled once per intent');
  }

  {
    // clearPendingPrivateMediaConsent wipes every pending slot.
    const rig: IntentRig = new IntentRig();
    rig.preparations = [PrivateMediaPreparation.needsHandshake()];
    rig.manager.submitPrivateMedia('peer-a', 'conv-a', file, '/cache/pic.jpg', 2, 'tid-32');
    rig.manager.clearPendingPrivateMediaConsent();
    rig.manager.retryPendingPrivateMedia('peer-a');
    t.equalNumber(1, rig.prepareCalls, 'cleared intent no longer retries');
    rig.scheduler.fireAll();
    t.equalNumber(0, rig.systemMessages.length,
      'cleared intent posts no timeout message');
  }
}
