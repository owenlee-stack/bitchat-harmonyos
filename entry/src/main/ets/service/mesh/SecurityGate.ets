/**
 * Mesh packet security gate: duplicate detection, replay protection and
 * mandatory signature verification - mirrors bitchat-android SecurityManager.kt.
 *
 * The Ed25519 verifier is injected so this file stays free of device crypto
 * dependencies (the cryptoFramework-backed implementation lands with the Noise
 * layer). Noise handshake handling is likewise deferred to the Noise session
 * manager.
 */
import { BitchatPacket, MessageType, messageTypeFromValue } from '../../model/BitchatPacket';
import { IdentityAnnouncement } from '../../model/IdentityModels';
import { PacketIdUtil } from '../sync/PacketIdUtil';
import { AnnouncementIdentityValidator } from './AnnouncementIdentityValidator';
import { SecurityConstants, PkTtl } from '../../common/ProtocolConstants';
import { ByteUtils } from '../../common/ByteUtils';
import { BinaryProtocol } from '../protocol/BinaryProtocol';

export interface SecurityGateDelegate {
  /** Signing key learned for this peer from a verified announcement. */
  getPeerSigningKey(peerID: string): Uint8Array | null;

  /** Noise static key learned for this peer. */
  getPeerNoiseKey(peerID: string): Uint8Array | null;

  /** Persisted signing key bound to an authenticated Noise static key. */
  getAuthenticatedSigningKey(noisePublicKey: Uint8Array): Uint8Array | null;
}

export class SecurityGate {
  private readonly myPeerID: string;
  private readonly verifyEd25519: (signature: Uint8Array, data: Uint8Array, publicKey: Uint8Array) => boolean;
  private readonly delegate: SecurityGateDelegate | null;

  private processedMessages: Set<string> = new Set();
  private messageTimestamps: Map<string, number> = new Map();

  constructor(myPeerID: string,
    verifyEd25519: (signature: Uint8Array, data: Uint8Array, publicKey: Uint8Array) => boolean,
    delegate: SecurityGateDelegate | null) {
    this.myPeerID = myPeerID;
    this.verifyEd25519 = verifyEd25519;
    this.delegate = delegate;
  }

  /**
   * Validate packet security (timestamp freshness for LEAVE, replay attacks,
   * duplicates, signatures). Only authenticated packets are recorded, so an
   * attacker-controlled invalid packet cannot poison duplicate detection for a
   * later legitimate packet with the same timestamp and payload.
   */
  validatePacket(packet: BitchatPacket, peerID: string, nowMs: number = Date.now()): boolean {
    // Skip validation for our own packets.
    if (peerID === this.myPeerID) {
      return false;
    }

    const currentTime: number = Math.floor(nowMs);
    const messageType: MessageType | null = messageTypeFromValue(packet.type);

    // LEAVE mutates presence immediately and cannot be safely replayed after
    // the in-memory duplicate cache expires (or after an app restart). Bound
    // it to the same five-minute security window used for duplicate retention
    // while tolerating symmetric clock skew.
    if (messageType === MessageType.LEAVE) {
      const now: number = Math.max(currentTime, 0);
      const clockSkew: number = packet.timestamp >= now ? packet.timestamp - now : now - packet.timestamp;
      if (clockSkew > SecurityConstants.MESSAGE_TIMEOUT_MS) {
        return false;
      }
    }

    // Duplicate detection.
    const messageID: string = this.generateMessageID(packet, peerID);
    if (this.processedMessages.has(messageID)) {
      // ANNOUNCE exception: allow if it looks like a direct neighbor (max
      // TTL). This ensures we observe the same peer on a new direct transport
      // connection, while still dropping looped/relayed duplicates.
      const isFreshAnnounce: boolean = messageType === MessageType.ANNOUNCE &&
        packet.ttl >= PkTtl.MESSAGE_TTL_HOPS;
      if (!isFreshAnnounce) {
        return false;
      }
    }

    // Enforce mandatory signature verification.
    if (!this.verifyPacketSignature(packet, peerID, currentTime)) {
      return false;
    }

    this.processedMessages.add(messageID);
    this.messageTimestamps.set(messageID, currentTime);
    return true;
  }

  /**
   * Verify a packet signature against the signing key learned from the peer's
   * verified announcement. Signatures cover the canonical packet, not only its
   * payload; otherwise routing and recipient fields could be changed without
   * invalidating the signature.
   */
  verifySignature(packet: BitchatPacket, peerID: string, nowMs: number = Date.now()): boolean {
    return this.verifyPacketSignature(packet, peerID, Math.floor(nowMs));
  }

  private verifyPacketSignature(packet: BitchatPacket, peerID: string, nowMs: number): boolean {
    const messageType: MessageType | null = messageTypeFromValue(packet.type);
    if (messageType === null) {
      // Unknown relayable types are not in the signed set.
      return true;
    }
    // Public packets that mutate identity, presence, or user-visible state
    // must prove the signing key learned from a verified announcement. LEAVE
    // is included so an attacker cannot evict a claimed peer or amplify a
    // forged departure through relay.
    const isSignedType: boolean = messageType === MessageType.ANNOUNCE ||
      messageType === MessageType.MESSAGE ||
      messageType === MessageType.FILE_TRANSFER ||
      messageType === MessageType.VOICE_FRAME ||
      messageType === MessageType.LEAVE;
    if (!isSignedType) {
      return true;
    }

    if (messageType === MessageType.ANNOUNCE) {
      const announcement: IdentityAnnouncement | null =
        AnnouncementIdentityValidator.verify(packet, peerID, nowMs, this.verifyEd25519);
      if (announcement === null) {
        return false;
      }
      if (this.delegate !== null) {
        const persistedSigningKey: Uint8Array | null =
          this.delegate.getAuthenticatedSigningKey(announcement.noisePublicKey);
        if (persistedSigningKey !== null &&
          !ByteUtils.equals(persistedSigningKey, announcement.signingPublicKey)) {
          return false;
        }
        const existingNoiseKey: Uint8Array | null = this.delegate.getPeerNoiseKey(peerID);
        if (existingNoiseKey !== null &&
          !ByteUtils.equals(existingNoiseKey, announcement.noisePublicKey)) {
          // Reject ANNOUNCE Noise-key replacement.
          return false;
        }
        const existingSigningKey: Uint8Array | null = this.delegate.getPeerSigningKey(peerID);
        if (existingSigningKey !== null &&
          !ByteUtils.equals(existingSigningKey, announcement.signingPublicKey)) {
          // Reject ANNOUNCE signing-key replacement without authenticated
          // peer state.
          return false;
        }
      }
      return true;
    }

    // 1. Mandatory signature check.
    if (packet.signature === null) {
      return false;
    }

    // 2. Signing public key from the verified announcement.
    if (this.delegate === null) {
      return false;
    }
    const signingPublicKey: Uint8Array | null = this.delegate.getPeerSigningKey(peerID);
    if (signingPublicKey === null) {
      // No key means we cannot verify; reject packets from unknown peers
      // unless it is an announce (handled above).
      return false;
    }

    // 3. Canonical data.
    const packetDataForSigning: Uint8Array | null = BinaryProtocol.toBinaryDataForSigning(packet);
    if (packetDataForSigning === null) {
      return false;
    }

    // 4. Verify signature.
    return this.verifyEd25519(packet.signature, packetDataForSigning, signingPublicKey);
  }

  /** Deduplicates by peer and a hash of type, sender, timestamp and payload. */
  private generateMessageID(packet: BitchatPacket, peerID: string): string {
    return peerID + '-' + PacketIdUtil.computeIdHex(packet);
  }

  /**
   * Expire processed messages older than the five-minute window and evict by
   * capacity. The mesh service owns the periodic timer.
   */
  cleanupOldData(nowMs: number = Date.now()): void {
    const cutoffTime: number = Math.floor(nowMs) - SecurityConstants.MESSAGE_TIMEOUT_MS;

    const expired: string[] = [];
    this.messageTimestamps.forEach((timestamp: number, messageID: string): void => {
      if (timestamp < cutoffTime) {
        expired.push(messageID);
      }
    });
    for (let i: number = 0; i < expired.length; i++) {
      this.messageTimestamps.delete(expired[i]);
      this.processedMessages.delete(expired[i]);
    }

    if (this.processedMessages.size > SecurityConstants.MAX_PROCESSED_MESSAGES) {
      const excess: number = this.processedMessages.size - SecurityConstants.MAX_PROCESSED_MESSAGES;
      const toRemove: string[] = [];
      let collected: number = 0;
      this.processedMessages.forEach((messageID: string): void => {
        if (collected < excess) {
          toRemove.push(messageID);
          collected += 1;
        }
      });
      for (let i: number = 0; i < toRemove.length; i++) {
        this.processedMessages.delete(toRemove[i]);
        this.messageTimestamps.delete(toRemove[i]);
      }
    }
  }

  /** Clear all security data. */
  clearAllData(): void {
    this.processedMessages.clear();
    this.messageTimestamps.clear();
  }

  getDebugInfo(): string {
    return '=== Security Gate Debug Info ===\n' +
      'Processed Messages: ' + this.processedMessages.size + '\n' +
      'Message Timestamps: ' + this.messageTimestamps.size;
  }
}
