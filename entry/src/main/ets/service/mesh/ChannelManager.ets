/**
 * Channel registry, membership and password gating (US9, T048; Android
 * ChannelManager parity).
 *
 * Owns the process-wide channel tables:
 *  - joined channels ('#name' tags) and password-protected channels,
 *  - per-channel member sets (peer IDs seen in the channel / connected),
 *  - channel creators (the joiner of a fresh plain channel, Android
 *    dataManager.addChannelCreator parity),
 * and drives the password gate: joining a password-protected channel
 * without a derived key needs a password (NEEDS_PASSWORD), a wrong
 * password fails derivation (WRONG_PASSWORD), a correct one derives the
 * PBKDF2+AES-GCM channel key through the injected ChannelCrypto (the
 * ChannelEncryption singleton on the device side, T047).
 *
 * Deliberately pure ArkTS (no @kit imports) so the channel contract tests
 * run on the host harness with a stubbed crypto; the crypto interface is
 * implemented by service/noise/ChannelEncryption (T047).
 */

/** Crypto operations the registry needs; ChannelEncryption implements it. */
export interface ChannelCrypto {
  /** Derive + store the PBKDF2 channel key; false on empty/failed input. */
  setChannelPassword(password: string, channel: string): boolean;
  /** True once a password-derived key exists for the channel. */
  hasChannelKey(channel: string): boolean;
  /** Forget the derived key (leaving a channel). */
  removeChannelPassword(channel: string): void;
}

/** Outcome of a channel join/create attempt (drives notices + prompts). */
export enum ChannelJoinResult {
  JOINED = 0,
  NEEDS_PASSWORD = 1,
  WRONG_PASSWORD = 2,
  INVALID_NAME = 3
}

export class ChannelManager {
  private readonly joinedChannels: Set<string> = new Set();
  private readonly passwordProtectedChannels: Set<string> = new Set();
  /** Channel members per channel tag (peer IDs). */
  private readonly channelMembers: Map<string, Set<string>> = new Map();
  /** Channel creator per channel tag (Android dataManager parity). */
  private readonly channelCreators: Map<string, string> = new Map();
  private readonly crypto: ChannelCrypto | null;

  constructor(crypto: ChannelCrypto | null) {
    this.crypto = crypto;
  }

  /** Normalize to a '#name' tag; '' when the name carries nothing. */
  static normalizeChannelName(name: string): string {
    const trimmed: string = name.trim();
    if (trimmed === '') {
      return '';
    }
    return trimmed.startsWith('#') ? trimmed : '#' + trimmed;
  }

  /**
   * Create a channel: optionally register it as password-protected (the
   * password derives the channel key immediately), record the creator and
   * join (Android joinChannel new-channel branch parity).
   */
  createChannel(channel: string, password: string | null,
    creatorPeerId: string): ChannelJoinResult {
    const tag: string = ChannelManager.normalizeChannelName(channel);
    if (tag === '' || tag === '#') {
      return ChannelJoinResult.INVALID_NAME;
    }
    if (password !== null && password !== '') {
      if (this.crypto === null || !this.crypto.setChannelPassword(password, tag)) {
        return ChannelJoinResult.WRONG_PASSWORD;
      }
      this.passwordProtectedChannels.add(tag);
      if (!this.channelCreators.has(tag)) {
        this.channelCreators.set(tag, creatorPeerId);
      }
    }
    return this.joinChannel(tag, null, creatorPeerId);
  }

  /**
   * Join (or return to) a channel. Password gating: a protected channel
   * without a derived key needs a password before the join lands; a wrong
   * password (failed derivation) refuses the join (Android parity).
   */
  joinChannel(channel: string, password: string | null,
    myPeerId: string): ChannelJoinResult {
    const tag: string = ChannelManager.normalizeChannelName(channel);
    if (tag === '' || tag === '#') {
      return ChannelJoinResult.INVALID_NAME;
    }
    if (this.joinedChannels.has(tag)) {
      // Already joined: protected channels still gate on a derived key.
      if (this.passwordProtectedChannels.has(tag) && !this.hasChannelKey(tag)) {
        if (password !== null) {
          return this.deriveForProtected(tag, password)
            ? ChannelJoinResult.JOINED : ChannelJoinResult.WRONG_PASSWORD;
        }
        return ChannelJoinResult.NEEDS_PASSWORD;
      }
      return ChannelJoinResult.JOINED;
    }
    if (this.passwordProtectedChannels.has(tag) && !this.hasChannelKey(tag)) {
      if (password === null) {
        return ChannelJoinResult.NEEDS_PASSWORD;
      }
      if (!this.deriveForProtected(tag, password)) {
        return ChannelJoinResult.WRONG_PASSWORD;
      }
    }
    this.joinedChannels.add(tag);
    this.addChannelMember(tag, myPeerId);
    // Android parity: joining a fresh plain channel makes us its creator.
    if (!this.passwordProtectedChannels.has(tag) && !this.channelCreators.has(tag)) {
      this.channelCreators.set(tag, myPeerId);
    }
    return ChannelJoinResult.JOINED;
  }

  /** Leave a channel: membership, creator record and key all go (Android parity). */
  leaveChannel(channel: string): boolean {
    const tag: string = ChannelManager.normalizeChannelName(channel);
    if (!this.joinedChannels.delete(tag)) {
      return false;
    }
    this.channelMembers.delete(tag);
    this.channelCreators.delete(tag);
    if (this.crypto !== null) {
      this.crypto.removeChannelPassword(tag);
    }
    return true;
  }

  isJoined(channel: string): boolean {
    return this.joinedChannels.has(ChannelManager.normalizeChannelName(channel));
  }

  /** Joined channel tags, sorted (Android getJoinedChannelsList parity). */
  getJoinedChannelsList(): string[] {
    const channels: string[] = [];
    this.joinedChannels.forEach((channel: string): void => {
      channels.push(channel);
    });
    return channels.sort();
  }

  isPasswordProtected(channel: string): boolean {
    return this.passwordProtectedChannels.has(ChannelManager.normalizeChannelName(channel));
  }

  /** True once the channel key is derived (decryption possible). */
  hasChannelKey(channel: string): boolean {
    const tag: string = ChannelManager.normalizeChannelName(channel);
    return this.crypto !== null && this.crypto.hasChannelKey(tag);
  }

  isChannelCreator(channel: string, peerId: string): boolean {
    const creator: string | undefined =
      this.channelCreators.get(ChannelManager.normalizeChannelName(channel));
    return creator === peerId;
  }

  addChannelMember(channel: string, peerId: string): void {
    if (peerId === '') {
      return;
    }
    const tag: string = ChannelManager.normalizeChannelName(channel);
    const members: Set<string> | undefined = this.channelMembers.get(tag);
    if (members !== undefined) {
      members.add(peerId);
    } else {
      const fresh: Set<string> = new Set();
      fresh.add(peerId);
      this.channelMembers.set(tag, fresh);
    }
  }

  removeChannelMember(channel: string, peerId: string): void {
    const tag: string = ChannelManager.normalizeChannelName(channel);
    const members: Set<string> | undefined = this.channelMembers.get(tag);
    if (members !== undefined) {
      members.delete(peerId);
    }
  }

  isChannelMember(channel: string, peerId: string): boolean {
    const members: Set<string> | undefined =
      this.channelMembers.get(ChannelManager.normalizeChannelName(channel));
    return members !== undefined && members.has(peerId);
  }

  /** Member peer IDs of one channel (sorted for stable output). */
  getChannelMembers(channel: string): string[] {
    const members: Set<string> | undefined =
      this.channelMembers.get(ChannelManager.normalizeChannelName(channel));
    const out: string[] = [];
    if (members !== undefined) {
      members.forEach((peerId: string): void => {
        out.push(peerId);
      });
    }
    return out.sort();
  }

  /**
   * Drop members that are neither connected nor us across every channel
   * (Android cleanupDisconnectedMembers parity; the roster refresh calls it).
   */
  cleanupDisconnectedMembers(connectedPeers: string[], myPeerId: string): void {
    const connected: Set<string> = new Set();
    for (let i: number = 0; i < connectedPeers.length; i++) {
      connected.add(connectedPeers[i]);
    }
    this.channelMembers.forEach((members: Set<string>, tag: string): void => {
      members.forEach((peerId: string): void => {
        if (peerId !== myPeerId && !connected.has(peerId)) {
          members.delete(peerId);
        }
      });
    });
  }

  /** Panic wipe: drop every table, key and creator record. */
  clearAllChannels(): void {
    if (this.crypto !== null) {
      const crypto: ChannelCrypto = this.crypto;
      // Derived keys live in the crypto singleton; retire them first.
      this.passwordProtectedChannels.forEach((tag: string): void => {
        crypto.removeChannelPassword(tag);
      });
    }
    this.joinedChannels.clear();
    this.passwordProtectedChannels.clear();
    this.channelMembers.clear();
    this.channelCreators.clear();
  }

  private deriveForProtected(tag: string, password: string): boolean {
    if (this.crypto === null) {
      return false;
    }
    return this.crypto.setChannelPassword(password, tag);
  }
}
