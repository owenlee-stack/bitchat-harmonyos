/**
 * IRC-style command processing (US6, T039) - port of bitchat-android
 * ui/CommandProcessor.kt.
 *
 * T039 scope: /join /j, /msg /m, /who /w, /clear, /block, /unblock,
 * /channels, /hug, /slap, the unknown-command fallback and the command /
 * @mention autocomplete. /pay, /pass, /save, /transfer and the geohash
 * location-channel branches arrive with their own phases and are
 * deliberately absent. Notice strings and dispatch semantics mirror the
 * Android handler exactly (the task adds /who as an alias of /w, which
 * Android dispatches under /w only).
 *
 * Pure ArkTS kernel: every side effect (system notices, sends, chat /
 * channel / block operations, peer lookups) rides the
 * CommandProcessorDelegate, so the dispatch semantics run in the host
 * contract harness. The caller routes any input starting with "/" here and
 * sends everything else as plain chat text.
 */
import { CommandSuggestion } from './CommandSuggestion';

export { CommandSuggestion } from './CommandSuggestion';

/** Side-effect seams of the command kernel (implemented by ChatViewModel). */
export interface CommandProcessorDelegate {
  /** Local nickname (null while unset, rendered as "someone" in actions). */
  getNickname(): string | null;

  /** Nicknames of the transport-connected peers (/w), self excluded. */
  getConnectedPeerNicknames(): string[];

  /** Nicknames of all known peers (@mention candidates), self excluded. */
  getKnownPeerNicknames(): string[];

  /** Resolve a nickname to its peer ID (exact match, null when unknown). */
  getPeerIdForNickname(nickname: string): string | null;

  /** Nickname of a peer, falling back to the peer ID itself. */
  getPeerNickname(peerId: string): string;

  /** Open private conversation ID, null when the public chat is showing. */
  getSelectedPrivateChatPeer(): string | null;

  /** Joined channel the composer writes to, null on the main timeline. */
  getCurrentChannel(): string | null;

  /** Add a local "system" notice line to the public timeline. */
  addPublicNotice(content: string): void;

  /** /clear in an open private chat: drop its visible history. */
  clearPrivateMessages(peerId: string): void;

  /** /clear inside a channel: drop the channel's visible history. */
  clearChannelMessages(channel: string): void;

  /** /clear on the main timeline: drop every public timeline entry. */
  clearPublicTimeline(): void;

  isPeerBlocked(peerId: string): boolean;

  blockPeer(peerId: string): boolean;

  unblockPeer(peerId: string): boolean;

  /** Summary line for /block without arguments. */
  listBlockedUsers(): string;

  /** Join (or create) a channel; false refuses the join (T048 wiring). */
  joinChannel(channel: string, password: string | null): boolean;

  getJoinedChannels(): string[];

  /** Open the private chat with one peer (blocked peers are refused). */
  startPrivateChat(peerId: string): boolean;

  /** Send one private message into an explicit conversation. */
  sendPrivateTextToConversation(conversationId: string, content: string): boolean;

  /** Send one public message on the current timeline. */
  sendPublicText(content: string): void;
}

export class CommandProcessor {
  private static readonly BASE_COMMANDS: CommandSuggestion[] = [
    new CommandSuggestion('/block', [], '[nickname]', 'block or list blocked peers'),
    new CommandSuggestion('/channels', [], null, 'show all discovered channels'),
    new CommandSuggestion('/clear', [], null, 'clear chat messages'),
    new CommandSuggestion('/hug', [], '<nickname>', 'send someone a warm hug'),
    new CommandSuggestion('/j', ['/join'], '<channel>', 'join or create a channel'),
    new CommandSuggestion('/m', ['/msg'], '<nickname> [message]', 'send private message'),
    new CommandSuggestion('/slap', [], '<nickname>', 'slap someone with a trout'),
    new CommandSuggestion('/unblock', [], '<nickname>', 'unblock a peer'),
    new CommandSuggestion('/w', ['/who'], null, "see who's online")
  ];

  private readonly delegate: CommandProcessorDelegate;

  constructor(delegate: CommandProcessorDelegate) {
    this.delegate = delegate;
  }

  /**
   * Dispatch one composer input. Returns true when the input was a command
   * (handled, field should clear); false when it is plain chat text.
   */
  processCommand(command: string): boolean {
    if (!command.startsWith('/')) {
      return false;
    }
    const parts: string[] = command.split(' ');
    const cmd: string = parts[0].toLowerCase();
    if (cmd === '/j' || cmd === '/join') {
      this.handleJoinCommand(parts);
    } else if (cmd === '/m' || cmd === '/msg') {
      this.handleMessageCommand(parts);
    } else if (cmd === '/w' || cmd === '/who') {
      this.handleWhoCommand();
    } else if (cmd === '/clear') {
      this.handleClearCommand();
    } else if (cmd === '/block') {
      this.handleBlockCommand(parts);
    } else if (cmd === '/unblock') {
      this.handleUnblockCommand(parts);
    } else if (cmd === '/hug') {
      this.handleActionCommand(parts, 'gives', 'a warm hug 🫂');
    } else if (cmd === '/slap') {
      this.handleActionCommand(parts, 'slaps', 'around a bit with a large trout 🐟');
    } else if (cmd === '/channels') {
      this.handleChannelsCommand();
    } else {
      this.delegate.addPublicNotice('unknown command: ' + cmd +
        '. type / to see available commands.');
    }
    return true;
  }

  // ------------------------------------------------------------------
  // Command autocomplete
  // ------------------------------------------------------------------

  /** Suggestions for the current composer input (empty list hides the popup). */
  getCommandSuggestions(input: string): CommandSuggestion[] {
    if (!input.startsWith('/')) {
      return [];
    }
    const query: string = input.toLowerCase();
    const filtered: CommandSuggestion[] = [];
    for (let i: number = 0; i < CommandProcessor.BASE_COMMANDS.length; i++) {
      const suggestion: CommandSuggestion = CommandProcessor.BASE_COMMANDS[i];
      if (suggestion.command.startsWith(query) ||
        CommandProcessor.matchesAlias(suggestion, query)) {
        filtered.push(suggestion);
      }
    }
    filtered.sort(CommandProcessor.compareSuggestions);
    return filtered;
  }

  /** Replacement composer text after one suggestion is picked. */
  selectCommandSuggestion(suggestion: CommandSuggestion): string {
    return suggestion.command + ' ';
  }

  // ------------------------------------------------------------------
  // Mention autocomplete
  // ------------------------------------------------------------------

  /** Nickname suggestions for the trailing @word (empty list hides). */
  getMentionSuggestions(input: string): string[] {
    const atIndex: number = input.lastIndexOf('@');
    if (atIndex === -1) {
      return [];
    }
    const textAfterAt: string = input.substring(atIndex + 1);
    if (textAfterAt.indexOf(' ') >= 0) {
      return [];
    }
    return CommandProcessor.filterMentionCandidates(
      this.delegate.getKnownPeerNicknames(), textAfterAt);
  }

  /**
   * Keep mention autocomplete useful: a bare `anon` label has not announced
   * a username and is not actionable, `anon#abcd` only adds a transport
   * disambiguator, while `anon1234`, `anonymous` or `anonracer` are real
   * announced usernames (Android ChatUIUtils.isUnannouncedNickname).
   */
  static isUnannouncedNickname(displayName: string): boolean {
    const trimmed: string = displayName.trim();
    const hashIndex: number = trimmed.indexOf('#');
    const base: string = hashIndex >= 0 ? trimmed.substring(0, hashIndex) : trimmed;
    return base.toLowerCase() === 'anon';
  }

  /**
   * Android filterMentionCandidates: trim, drop empty and unannounced
   * names, prefix-match case-insensitively, deduplicate case-insensitively
   * (first occurrence wins), sort case-insensitively.
   */
  static filterMentionCandidates(candidates: string[], query: string): string[] {
    const loweredQuery: string = query.toLowerCase();
    const seen: Set<string> = new Set();
    const result: string[] = [];
    for (let i: number = 0; i < candidates.length; i++) {
      const trimmed: string = candidates[i].trim();
      if (trimmed.length === 0 || CommandProcessor.isUnannouncedNickname(trimmed)) {
        continue;
      }
      if (!trimmed.toLowerCase().startsWith(loweredQuery)) {
        continue;
      }
      const key: string = trimmed.toLowerCase();
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      result.push(trimmed);
    }
    result.sort(CommandProcessor.compareCaseInsensitive);
    return result;
  }

  /** Replacement composer text after one mention is picked. */
  selectMentionSuggestion(nickname: string, currentText: string): string {
    const atIndex: number = currentText.lastIndexOf('@');
    if (atIndex === -1) {
      return currentText + '@' + nickname + ' ';
    }
    return currentText.substring(0, atIndex) + '@' + nickname + ' ';
  }

  // ------------------------------------------------------------------
  // Handlers (Android CommandProcessor.kt semantics)
  // ------------------------------------------------------------------

  private handleJoinCommand(parts: string[]): void {
    if (parts.length > 1) {
      const channelName: string = parts[1];
      const channel: string = channelName.startsWith('#') ? channelName : '#' + channelName;
      const password: string | null = parts.length > 2 ? parts[2] : null;
      const success: boolean = this.delegate.joinChannel(channel, password);
      if (success) {
        this.delegate.addPublicNotice('joined channel ' + channel);
      }
    } else {
      this.delegate.addPublicNotice('usage: /join <channel>');
    }
  }

  private handleMessageCommand(parts: string[]): void {
    if (parts.length > 1) {
      const targetName: string = CommandProcessor.stripLeadingAt(parts[1]);
      const peerId: string | null = this.delegate.getPeerIdForNickname(targetName);
      if (peerId === null) {
        this.delegate.addPublicNotice("user '" + targetName +
          "' not found. they may be offline or using a different nickname.");
        return;
      }
      if (this.delegate.isPeerBlocked(peerId)) {
        this.delegate.addPublicNotice('cannot start chat with ' +
          this.delegate.getPeerNickname(peerId) + ': user is blocked.');
        return;
      }
      const success: boolean = this.delegate.startPrivateChat(peerId);
      if (success) {
        if (parts.length > 2) {
          const messageContent: string = parts.slice(2).join(' ');
          this.delegate.sendPrivateTextToConversation(peerId, messageContent);
        } else {
          this.delegate.addPublicNotice('started private chat with ' + targetName);
        }
      }
    } else {
      this.delegate.addPublicNotice('usage: /msg <nickname> [message]');
    }
  }

  private handleWhoCommand(): void {
    const nicknames: string[] = this.delegate.getConnectedPeerNicknames();
    if (nicknames.length === 0) {
      this.delegate.addPublicNotice('no one else is around right now.');
    } else {
      this.delegate.addPublicNotice('online users: ' + nicknames.join(', '));
    }
  }

  private handleClearCommand(): void {
    const selected: string | null = this.delegate.getSelectedPrivateChatPeer();
    if (selected !== null) {
      this.delegate.clearPrivateMessages(selected);
      return;
    }
    const channel: string | null = this.delegate.getCurrentChannel();
    if (channel !== null) {
      this.delegate.clearChannelMessages(channel);
      return;
    }
    this.delegate.clearPublicTimeline();
  }

  private handleBlockCommand(parts: string[]): void {
    if (parts.length > 1) {
      const targetName: string = CommandProcessor.stripLeadingAt(parts[1]);
      const peerId: string | null = this.delegate.getPeerIdForNickname(targetName);
      if (peerId === null) {
        this.delegate.addPublicNotice("user '" + targetName + "' not found");
        return;
      }
      if (this.delegate.blockPeer(peerId)) {
        this.delegate.addPublicNotice('blocked user ' + this.delegate.getPeerNickname(peerId));
      }
    } else {
      this.delegate.addPublicNotice(this.delegate.listBlockedUsers());
    }
  }

  private handleUnblockCommand(parts: string[]): void {
    if (parts.length > 1) {
      const targetName: string = CommandProcessor.stripLeadingAt(parts[1]);
      const peerId: string | null = this.delegate.getPeerIdForNickname(targetName);
      if (peerId === null) {
        this.delegate.addPublicNotice("user '" + targetName + "' not found");
        return;
      }
      if (!this.delegate.isPeerBlocked(peerId)) {
        this.delegate.addPublicNotice("user '" + targetName + "' is not blocked");
        return;
      }
      if (this.delegate.unblockPeer(peerId)) {
        this.delegate.addPublicNotice('unblocked user ' + this.delegate.getPeerNickname(peerId));
      }
    } else {
      this.delegate.addPublicNotice('usage: /unblock <nickname>');
    }
  }

  private handleActionCommand(parts: string[], verb: string, actionObject: string): void {
    if (parts.length > 1) {
      const targetName: string = CommandProcessor.stripLeadingAt(parts[1]);
      const nickname: string | null = this.delegate.getNickname();
      const actionMessage: string = '* ' + (nickname !== null ? nickname : 'someone') +
        ' ' + verb + ' ' + targetName + ' ' + actionObject + ' *';
      const selected: string | null = this.delegate.getSelectedPrivateChatPeer();
      if (selected !== null) {
        if (this.delegate.isPeerBlocked(selected)) {
          this.delegate.addPublicNotice('cannot send message to ' +
            this.delegate.getPeerNickname(selected) + ': user is blocked.');
          return;
        }
        this.delegate.sendPrivateTextToConversation(selected, actionMessage);
      } else {
        this.delegate.sendPublicText(actionMessage);
      }
    } else {
      this.delegate.addPublicNotice('usage: /' + parts[0].substring(1) + ' <nickname>');
    }
  }

  private handleChannelsCommand(): void {
    const channels: string[] = this.delegate.getJoinedChannels();
    if (channels.length === 0) {
      this.delegate.addPublicNotice('no channels joined');
    } else {
      this.delegate.addPublicNotice('joined channels: ' + channels.join(', '));
    }
  }

  // ------------------------------------------------------------------
  // Internals
  // ------------------------------------------------------------------

  private static stripLeadingAt(token: string): string {
    return token.startsWith('@') ? token.substring(1) : token;
  }

  private static matchesAlias(suggestion: CommandSuggestion, query: string): boolean {
    for (let i: number = 0; i < suggestion.aliases.length; i++) {
      if (suggestion.aliases[i].startsWith(query)) {
        return true;
      }
    }
    return false;
  }

  private static compareSuggestions(a: CommandSuggestion, b: CommandSuggestion): number {
    return a.command < b.command ? -1 : (a.command > b.command ? 1 : 0);
  }

  private static compareCaseInsensitive(a: string, b: string): number {
    const loweredA: string = a.toLowerCase();
    const loweredB: string = b.toLowerCase();
    return loweredA < loweredB ? -1 : (loweredA > loweredB ? 1 : 0);
  }
}
