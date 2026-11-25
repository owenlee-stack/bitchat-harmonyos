/**
 * Contract tests for the T039 IRC command kernel (US6):
 * - dispatch surface, alias handling (/j //join, /m //msg, /w //who) and
 *   case-insensitive commands; notice strings match Android
 *   ui/CommandProcessor.kt exactly
 * - /clear context routing (private -> channel -> public timeline)
 * - block/unblock bookkeeping, not-found / not-blocked / blocked-send notices
 * - /hug //slap action messages in public and private contexts
 * - command autocomplete (primary + alias prefix match, sorted) and
 *   @mention autocomplete (trim, unannounced-anon filter, case-insensitive
 *   dedup + sort) with selection replacement
 * All side effects ride a recording delegate; no device APIs.
 */
import { ContractAssert } from './ContractAssert';
import { CommandProcessor } from '../../main/ets/viewmodel/CommandProcessor';
import { CommandProcessorDelegate } from '../../main/ets/viewmodel/CommandProcessor';
import { CommandSuggestion } from '../../main/ets/viewmodel/CommandSuggestion';

class RecordingDelegate implements CommandProcessorDelegate {
  notices: string[] = [];
  publicSent: string[] = [];
  privatePeers: string[] = [];
  privateContents: string[] = [];
  startedChats: string[] = [];
  clearedPublic: boolean = false;
  clearedPrivate: string[] = [];
  clearedChannels: string[] = [];
  joinedChannels: string[] = [];
  joinPasswords: (string | null)[] = [];
  joinResult: boolean = true;
  blocked: Set<string> = new Set();
  nickname: string | null = 'bob';
  connectedNicknames: string[] = [];
  knownNicknames: string[] = [];
  nicknameToPeer: Map<string, string> = new Map();
  peerNicknames: Map<string, string> = new Map();
  selectedPrivate: string | null = null;
  currentChannel: string | null = null;

  getNickname(): string | null {
    return this.nickname;
  }

  getConnectedPeerNicknames(): string[] {
    return this.connectedNicknames;
  }

  getKnownPeerNicknames(): string[] {
    return this.knownNicknames;
  }

  getPeerIdForNickname(nickname: string): string | null {
    const peerId: string | undefined = this.nicknameToPeer.get(nickname);
    return peerId === undefined ? null : peerId;
  }

  getPeerNickname(peerId: string): string {
    const nickname: string | undefined = this.peerNicknames.get(peerId);
    return nickname === undefined ? peerId : nickname;
  }

  getSelectedPrivateChatPeer(): string | null {
    return this.selectedPrivate;
  }

  getCurrentChannel(): string | null {
    return this.currentChannel;
  }

  addPublicNotice(content: string): void {
    this.notices.push(content);
  }

  clearPrivateMessages(peerId: string): void {
    this.clearedPrivate.push(peerId);
  }

  clearChannelMessages(channel: string): void {
    this.clearedChannels.push(channel);
  }

  clearPublicTimeline(): void {
    this.clearedPublic = true;
  }

  isPeerBlocked(peerId: string): boolean {
    return this.blocked.has(peerId);
  }

  blockPeer(peerId: string): boolean {
    this.blocked.add(peerId);
    return true;
  }

  unblockPeer(peerId: string): boolean {
    this.blocked.delete(peerId);
    return true;
  }

  listBlockedUsers(): string {
    return this.blocked.size === 0 ? 'no blocked users' :
      'blocked users: ' + this.blocked.size + ' fingerprints';
  }

  joinChannel(channel: string, password: string | null): boolean {
    this.joinPasswords.push(password);
    if (this.joinResult) {
      this.joinedChannels.push(channel);
    }
    return this.joinResult;
  }

  getJoinedChannels(): string[] {
    return this.joinedChannels;
  }

  startPrivateChat(peerId: string): boolean {
    if (this.blocked.has(peerId)) {
      return false;
    }
    this.startedChats.push(peerId);
    return true;
  }

  sendPrivateTextToConversation(conversationId: string, content: string): boolean {
    this.privatePeers.push(conversationId);
    this.privateContents.push(content);
    return true;
  }

  sendPublicText(content: string): void {
    this.publicSent.push(content);
  }
}

export function runCommandProcessorContractTests(t: ContractAssert): void {
  const delegate: RecordingDelegate = new RecordingDelegate();
  const processor: CommandProcessor = new CommandProcessor(delegate);
  const lastNotice: () => string = (): string => {
    return delegate.notices[delegate.notices.length - 1];
  };

  // ------------------------------------------------------------------
  // Dispatch surface.
  // ------------------------------------------------------------------
  t.isFalse(processor.processCommand('hello world'), 'plain text is not a command');
  t.equalNumber(0, delegate.notices.length, 'plain text triggers no notice');

  // ------------------------------------------------------------------
  // /join //j: hash prefixing, password pass-through, usage, refusal.
  // ------------------------------------------------------------------
  t.isTrue(processor.processCommand('/j channel-1'), '/j returns true');
  t.equalString('joined channel #channel-1', lastNotice(), '/j prefixes the hash');
  t.equalString('#channel-1', delegate.joinedChannels[0], 'channel registered with #');
  t.isNull(delegate.joinPasswords[0], '/j without password passes null');

  t.isTrue(processor.processCommand('/JOIN #elsewhere secret'), '/JOIN upper case dispatches');
  t.equalString('joined channel #elsewhere', lastNotice(), '/JOIN success notice');
  t.equalString('#elsewhere', delegate.joinedChannels[1], 'explicit # kept once');
  t.equalString('secret', delegate.joinPasswords[1], 'third token is the password');

  delegate.joinResult = false;
  t.isTrue(processor.processCommand('/join denied'), 'refused join still consumed the command');
  t.equalNumber(2, delegate.notices.length, 'refused join emits no success notice');
  delegate.joinResult = true;

  t.isTrue(processor.processCommand('/join'), 'argument-less /join returns true');
  t.equalString('usage: /join <channel>', lastNotice(), '/join usage notice');

  // ------------------------------------------------------------------
  // /msg //m: resolve, start, send, not-found, usage, blocked.
  // ------------------------------------------------------------------
  delegate.nicknameToPeer.set('alice', '0011223344556677');
  delegate.peerNicknames.set('0011223344556677', 'alice');
  t.isTrue(processor.processCommand('/msg alice'), '/msg opens the chat');
  t.equalString('0011223344556677', delegate.startedChats[0], '/msg resolved the nickname');
  t.equalString('started private chat with alice', lastNotice(), '/msg start notice');

  t.isTrue(processor.processCommand('/m @alice hello there'), '/m with message sends');
  t.equalString('0011223344556677', delegate.privatePeers[0], '/m targets the resolved peer');
  t.equalString('hello there', delegate.privateContents[0], '/m joins the remaining words');

  t.isTrue(processor.processCommand('/msg ghost'), 'unknown target still consumed');
  t.equalString("user 'ghost' not found. they may be offline or using a different nickname.",
    lastNotice(), '/msg unknown target notice');

  t.isTrue(processor.processCommand('/msg'), 'argument-less /msg returns true');
  t.equalString('usage: /msg <nickname> [message]', lastNotice(), '/msg usage notice');

  delegate.blocked.add('0011223344556677');
  t.isTrue(processor.processCommand('/msg alice'), 'blocked target still consumed');
  t.equalString('cannot start chat with alice: user is blocked.', lastNotice(),
    'blocked /msg notice');
  t.equalNumber(2, delegate.startedChats.length, 'blocked /msg starts no chat');
  t.equalNumber(1, delegate.privatePeers.length, 'blocked /msg sends nothing');

  // ------------------------------------------------------------------
  // /w //who.
  // ------------------------------------------------------------------
  t.isTrue(processor.processCommand('/w'), '/w returns true');
  t.equalString('no one else is around right now.', lastNotice(), '/w empty notice');
  delegate.connectedNicknames = ['alice', 'carol'];
  t.isTrue(processor.processCommand('/who'), '/who alias returns true');
  t.equalString('online users: alice, carol', lastNotice(), '/who lists nicknames');

  // ------------------------------------------------------------------
  // /clear routing: private first, then channel, then public timeline.
  // ------------------------------------------------------------------
  delegate.selectedPrivate = '0011223344556677';
  t.isTrue(processor.processCommand('/clear'), '/clear in private returns true');
  t.equalString('0011223344556677', delegate.clearedPrivate[0], '/clear clears the private chat');
  t.isFalse(delegate.clearedPublic, '/clear in private leaves the timeline');
  delegate.selectedPrivate = null;
  delegate.currentChannel = '#room';
  t.isTrue(processor.processCommand('/clear'), '/clear in channel returns true');
  t.equalString('#room', delegate.clearedChannels[0], '/clear clears the channel');
  t.isFalse(delegate.clearedPublic, '/clear in channel leaves the timeline');
  delegate.currentChannel = null;
  t.isTrue(processor.processCommand('/clear'), '/clear on main returns true');
  t.isTrue(delegate.clearedPublic, '/clear clears the public timeline');

  // ------------------------------------------------------------------
  // /block //unblock: bookkeeping and notices.
  // ------------------------------------------------------------------
  delegate.nicknameToPeer.set('carol', 'aabbccddeeff0011');
  delegate.peerNicknames.set('aabbccddeeff0011', 'carol');
  t.isTrue(processor.processCommand('/block carol'), '/block returns true');
  t.isTrue(delegate.blocked.has('aabbccddeeff0011'), '/block blocked the resolved peer');
  t.equalString('blocked user carol', lastNotice(), '/block success notice');

  t.isTrue(processor.processCommand('/block'), '/block listing returns true');
  t.equalString('blocked users: 2 fingerprints', lastNotice(), '/block lists the block count');

  t.isTrue(processor.processCommand('/block ghost'), '/block unknown returns true');
  t.equalString("user 'ghost' not found", lastNotice(), '/block unknown notice');

  t.isTrue(processor.processCommand('/unblock carol'), '/unblock returns true');
  t.isFalse(delegate.blocked.has('aabbccddeeff0011'), '/unblock removed the block');
  t.equalString('unblocked user carol', lastNotice(), '/unblock success notice');

  t.isTrue(processor.processCommand('/unblock carol'), '/unblock again returns true');
  t.equalString("user 'carol' is not blocked", lastNotice(), 'not-blocked notice');

  t.isTrue(processor.processCommand('/unblock'), 'argument-less /unblock returns true');
  t.equalString('usage: /unblock <nickname>', lastNotice(), '/unblock usage notice');

  // ------------------------------------------------------------------
  // /hug //slap: action strings, contexts, usage.
  // ------------------------------------------------------------------
  t.isTrue(processor.processCommand('/hug carol'), '/hug returns true');
  t.equalString('* bob gives carol a warm hug 🫂 *', delegate.publicSent[0],
    '/hug action message on the public timeline');

  t.isTrue(processor.processCommand('/slap @carol'), '/slap strips the @');
  t.equalString('* bob slaps carol around a bit with a large trout 🐟 *', delegate.publicSent[1],
    '/slap action message');

  delegate.nickname = null;
  t.isTrue(processor.processCommand('/hug carol'), '/hug with unset nickname returns true');
  t.equalString('* someone gives carol a warm hug 🫂 *', delegate.publicSent[2],
    'unset nickname renders as someone');
  delegate.nickname = 'bob';

  delegate.selectedPrivate = '0011223344556677';
  t.isTrue(processor.processCommand('/hug carol'), '/hug into blocked private chat consumed');
  t.equalString('cannot send message to alice: user is blocked.', lastNotice(),
    'blocked private action notice');
  delegate.selectedPrivate = 'aabbccddeeff0011';
  t.isTrue(processor.processCommand('/hug carol'), '/hug in private chat returns true');
  t.equalString('* bob gives carol a warm hug 🫂 *', delegate.privateContents[1],
    '/hug routes through the private send');
  delegate.selectedPrivate = null;

  t.isTrue(processor.processCommand('/hug'), 'argument-less /hug returns true');
  t.equalString('usage: /hug <nickname>', lastNotice(), '/hug usage notice');
  t.isTrue(processor.processCommand('/slap'), 'argument-less /slap returns true');
  t.equalString('usage: /slap <nickname>', lastNotice(), '/slap usage notice');

  // ------------------------------------------------------------------
  // /channels and the unknown-command fallback.
  // ------------------------------------------------------------------
  t.isTrue(processor.processCommand('/channels'), '/channels returns true');
  t.equalString('joined channels: #channel-1, #elsewhere', lastNotice(),
    '/channels lists the registry');

  t.isTrue(processor.processCommand('/wtfjoin now'), 'unknown command consumed');
  t.equalString('unknown command: /wtfjoin. type / to see available commands.', lastNotice(),
    'unknown command notice');

  const fresh: RecordingDelegate = new RecordingDelegate();
  const freshProcessor: CommandProcessor = new CommandProcessor(fresh);
  t.isTrue(freshProcessor.processCommand('/channels'), '/channels on empty registry');
  t.equalString('no channels joined', fresh.notices[0], '/channels empty notice');

  // ------------------------------------------------------------------
  // Command autocomplete.
  // ------------------------------------------------------------------
  const all: CommandSuggestion[] = processor.getCommandSuggestions('/');
  t.equalNumber(9, all.length, '"/" lists every base command');
  t.equalString('/block', all[0].command, 'suggestions sorted by command');
  t.equalString('/w', all[8].command, 'suggestions sorted tail');

  const joinSuggestion: CommandSuggestion[] = processor.getCommandSuggestions('/join');
  t.equalNumber(1, joinSuggestion.length, '"/join" matches only /j (via alias)');
  t.equalString('/j', joinSuggestion[0].command, '/join resolves to the /j command');

  t.equalNumber(2, processor.getCommandSuggestions('/c').length,
    '"/c" matches /channels + /clear');
  t.equalNumber(0, processor.getCommandSuggestions('hello').length,
    'non-command input hides the popup');
  t.equalNumber(0, processor.getCommandSuggestions('/zzz').length,
    'unmatched input hides the popup');
  t.equalString('/j ', processor.selectCommandSuggestion(joinSuggestion[0]),
    'selection replaces the input with the command');

  // ------------------------------------------------------------------
  // Mention autocomplete.
  // ------------------------------------------------------------------
  t.isTrue(CommandProcessor.isUnannouncedNickname('anon'), 'bare anon is unannounced');
  t.isTrue(CommandProcessor.isUnannouncedNickname('Anon#abcd'),
    'transport-suffixed anon is unannounced');
  t.isFalse(CommandProcessor.isUnannouncedNickname('anon1234'), 'anon1234 is announced');
  t.isFalse(CommandProcessor.isUnannouncedNickname('anonymous'), 'anonymous is announced');

  const filtered: string[] = CommandProcessor.filterMentionCandidates(
    ['  bob ', 'ANON', 'anon#1234', 'anon1234', 'Alice', 'alice', '  ', 'Bob'], 'a');
  t.equalString('Alice,anon1234', filtered.join(','),
    'mention filter trims, drops anon, dedupes case-insensitively, sorts');

  t.equalString('carol,Caroline',
    CommandProcessor.filterMentionCandidates(['carol', 'Caroline'], 'CAR').join(','),
    'mention query matches case-insensitively');

  delegate.knownNicknames = ['alice', 'bob', 'carol'];
  t.equalString('alice', processor.getMentionSuggestions('@a').join(','),
    'trailing @word filters candidates');
  t.equalString('alice,bob,carol', processor.getMentionSuggestions('hi @').join(','),
    'bare @ lists every candidate');
  t.equalNumber(0, processor.getMentionSuggestions('hello').length,
    'input without @ hides mention popup');
  t.equalNumber(0, processor.getMentionSuggestions('@a b').length,
    'space after @ hides mention popup');
  t.equalString('hi @alice ', processor.selectMentionSuggestion('alice', 'hi @al'),
    'selection replaces the partial mention');
  t.equalString('hello@alice ', processor.selectMentionSuggestion('alice', 'hello'),
    'selection without @ appends the mention');
}
