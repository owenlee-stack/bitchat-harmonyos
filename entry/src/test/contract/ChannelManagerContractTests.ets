/**
 * Channel registry contract tests (US9, T048): channel-tag normalization,
 * the join/create lifecycle, password gating (NEEDS_PASSWORD /
 * WRONG_PASSWORD / derivation on success), membership tracking including
 * the disconnected-member cleanup, creator records, and the panic clear.
 *
 * The crypto is stubbed (ChannelCrypto), so the whole suite runs on the
 * host contract harness; the device-side ChannelEncryption (T047) carries
 * the real PBKDF2/AES-GCM work and is validated by parameter parity.
 */
import { ContractAssert } from './ContractAssert';
import { ChannelCrypto } from '../../main/ets/service/mesh/ChannelManager';
import { ChannelJoinResult, ChannelManager } from '../../main/ets/service/mesh/ChannelManager';

/** Stub crypto: records passwords, fails derivation when told to. */
class StubChannelCrypto implements ChannelCrypto {
  private readonly passwords: Map<string, string> = new Map();
  failDerivation: boolean = false;

  setChannelPassword(password: string, channel: string): boolean {
    if (this.failDerivation || password === '') {
      return false;
    }
    this.passwords.set(channel, password);
    return true;
  }

  hasChannelKey(channel: string): boolean {
    return this.passwords.has(channel);
  }

  removeChannelPassword(channel: string): void {
    this.passwords.delete(channel);
  }

  passwordCount(): number {
    return this.passwords.size;
  }
}

export function runChannelManagerContractTests(t: ContractAssert): void {
  t.equalString('#test', ChannelManager.normalizeChannelName('test'), 'normalize adds hash');
  t.equalString('#test', ChannelManager.normalizeChannelName('#test'), 'normalize keeps hash');
  t.equalString('#test', ChannelManager.normalizeChannelName('  test '), 'normalize trims');
  t.equalString('', ChannelManager.normalizeChannelName('   '), 'normalize empty');

  // Plain join: registry, membership, creator record.
  const crypto: StubChannelCrypto = new StubChannelCrypto();
  const manager: ChannelManager = new ChannelManager(crypto);
  t.equalNumber(ChannelJoinResult.JOINED, manager.joinChannel('dev', null, 'me'),
    'plain join succeeds');
  t.isTrue(manager.isJoined('#dev'), 'joined after join');
  t.isTrue(manager.isChannelCreator('#dev', 'me'), 'joiner becomes creator');
  t.isTrue(manager.isChannelMember('#dev', 'me'), 'joiner is a member');
  t.isFalse(manager.hasChannelKey('#dev'), 'plain channel has no key');

  // Idempotent re-join.
  t.equalNumber(ChannelJoinResult.JOINED, manager.joinChannel('#dev', null, 'me'),
    're-join is idempotent');

  // Sorted joined list.
  manager.joinChannel('alpha', null, 'me');
  const joined: string[] = manager.getJoinedChannelsList();
  t.equalNumber(2, joined.length, 'two channels joined');
  t.equalString('#alpha', joined[0], 'joined list sorted first');
  t.equalString('#dev', joined[1], 'joined list sorted second');

  // Invalid names refuse the join.
  t.equalNumber(ChannelJoinResult.INVALID_NAME, manager.joinChannel('', null, 'me'),
    'empty name refused');
  t.equalNumber(ChannelJoinResult.INVALID_NAME, manager.joinChannel('#', null, 'me'),
    'bare hash refused');

  // Password-protected channel created with a password: key derived, joined.
  t.equalNumber(ChannelJoinResult.JOINED, manager.createChannel('secret', 'pw1', 'creator'),
    'create with password joins');
  t.isTrue(manager.isPasswordProtected('#secret'), 'created channel is protected');
  t.isTrue(manager.hasChannelKey('#secret'), 'created channel key derived');
  t.isTrue(manager.isChannelCreator('#secret', 'creator'), 'creator recorded');

  // Late joiner on another device: the same protected channel joined with
  // the same password derives its own key and lands.
  const lateCrypto: StubChannelCrypto = new StubChannelCrypto();
  const late: ChannelManager = new ChannelManager(lateCrypto);
  t.equalNumber(ChannelJoinResult.JOINED, late.createChannel('room', 'hunter2', 'latecomer'),
    'late joiner with password joins');
  t.isTrue(lateCrypto.hasChannelKey('#room'), 'late joiner derived the key');

  // Password gate: a protected channel re-joined after leaving needs its
  // password back (leave removed the derived key; protection persists).
  const noPassword: StubChannelCrypto = new StubChannelCrypto();
  const gated: ChannelManager = new ChannelManager(noPassword);
  gated.createChannel('gate', 'pw', 'first');
  gated.leaveChannel('gate');
  t.equalNumber(ChannelJoinResult.NEEDS_PASSWORD, gated.joinChannel('#gate', null, 'second'),
    'protected re-join without key needs password');
  // WRONG_PASSWORD is a failed derivation (Android parity: any non-empty
  // password derives a key; a wrong-but-derivable password joins and only
  // shows ciphertext placeholders at decrypt time).
  noPassword.failDerivation = true;
  t.equalNumber(ChannelJoinResult.WRONG_PASSWORD, gated.joinChannel('#gate', 'bad', 'second'),
    'failed derivation refused');
  t.isFalse(gated.isJoined('#gate'), 'failed derivation did not join');
  noPassword.failDerivation = false;
  t.equalNumber(ChannelJoinResult.JOINED, gated.joinChannel('#gate', 'pw', 'second'),
    'correct password joins');
  t.isTrue(noPassword.hasChannelKey('#gate'), 'key derived after correct password');

  // Wrong password at creation time (failing derivation) refuses.
  const failing: StubChannelCrypto = new StubChannelCrypto();
  failing.failDerivation = true;
  const failingManager: ChannelManager = new ChannelManager(failing);
  t.equalNumber(ChannelJoinResult.WRONG_PASSWORD,
    failingManager.createChannel('boom', 'pw', 'me'), 'failed derivation refused');

  // Null crypto: plain channels still work, protected cannot derive.
  const bare: ChannelManager = new ChannelManager(null);
  t.equalNumber(ChannelJoinResult.JOINED, bare.joinChannel('plain', null, 'me'),
    'null crypto plain join works');

  // Leave: membership, creator and key all go.
  const leaveCrypto: StubChannelCrypto = new StubChannelCrypto();
  const leaving: ChannelManager = new ChannelManager(leaveCrypto);
  leaving.createChannel('temp', 'pw', 'me');
  t.isTrue(leaving.leaveChannel('temp'), 'leave succeeds');
  t.isFalse(leaving.isJoined('#temp'), 'left channel not joined');
  t.isFalse(leaveCrypto.hasChannelKey('#temp'), 'key removed on leave');
  t.isFalse(leaving.isChannelCreator('#temp', 'me'), 'creator record removed on leave');
  t.isFalse(leaving.leaveChannel('temp'), 'double leave fails');

  // Membership: add/remove/cleanup of disconnected members.
  const memberCrypto: StubChannelCrypto = new StubChannelCrypto();
  const members: ChannelManager = new ChannelManager(memberCrypto);
  members.joinChannel('crew', null, 'me');
  members.addChannelMember('#crew', 'peerA');
  members.addChannelMember('#crew', 'peerB');
  t.equalNumber(3, members.getChannelMembers('#crew').length, 'three members');
  members.removeChannelMember('#crew', 'peerB');
  t.equalNumber(2, members.getChannelMembers('#crew').length, 'member removed');
  members.cleanupDisconnectedMembers(['peerA'], 'me');
  const remaining: string[] = members.getChannelMembers('#crew');
  t.equalNumber(2, remaining.length, 'self and connected survive cleanup');
  t.isTrue(remaining.indexOf('me') >= 0, 'self kept by cleanup');
  t.isTrue(remaining.indexOf('peerA') >= 0, 'connected kept by cleanup');
  members.cleanupDisconnectedMembers([], 'me');
  t.equalNumber(1, members.getChannelMembers('#crew').length, 'only self after full cleanup');

  // Panic clear: every table empties, keys retire.
  const panicCrypto: StubChannelCrypto = new StubChannelCrypto();
  const panicked: ChannelManager = new ChannelManager(panicCrypto);
  panicked.joinChannel('one', null, 'me');
  panicked.createChannel('two', 'pw', 'me');
  panicked.clearAllChannels();
  t.equalNumber(0, panicked.getJoinedChannelsList().length, 'no channels after panic');
  t.isFalse(panicked.isJoined('#one'), 'plain channel gone after panic');
  t.isFalse(panicCrypto.hasChannelKey('#two'), 'protected key gone after panic');
  t.equalNumber(0, panicked.getChannelMembers('#one').length, 'members gone after panic');
}
