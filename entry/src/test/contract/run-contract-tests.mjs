#!/usr/bin/env node
/**
 * Host runner for the bitchat golden-vector contract tests.
 *
 * devecocli has no unit-test runner, so the pure-ArkTS contract modules under
 * entry/src/test/contract are staged into a temp directory as .ts (relative
 * import specifiers rewritten with explicit .ts extensions, directory
 * structure mirrored) and executed with `node --experimental-transform-types`.
 * The protocol kernel under entry/src/main/ets is deliberately free of
 * @ohos/@kit imports, so it runs on Node unchanged.
 *
 * Also performs the host-side backup-exclusion contract check: HarmonyOS
 * backup_config.json must be deny-by-default (the analog of Android's
 * BackupExclusionContractTest invariant over data extraction rules).
 */
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const entryDir = path.resolve(scriptDir, '..', '..', '..');
const mainEtsDir = path.join(entryDir, 'src', 'main', 'ets');
const contractDir = scriptDir;
const backupConfigPath = path.join(entryDir, 'src', 'main', 'resources', 'base', 'profile', 'backup_config.json');

const stageRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'bitchat-contract-'));
let failures = 0;

function rewriteImports(content) {
  // Pure interfaces (ContractAssert, PeerManagerDelegate,
  // SecurityGateDelegate, PacketProcessorDelegate, PacketRelayDelegate,
  // GossipSyncDelegate, GossipSyncConfig, CachedPacketEntry,
  // MessageRouterDelegate, CommandProcessorDelegate, NostrRandomSource):
  // Node's transform keeps value imports, so they must become
  // `import type` to survive ESM linking.
  let out = content.replace(
    /import\s+\{(\s*(?:ContractAssert|PeerManagerDelegate|SecurityGateDelegate|PacketProcessorDelegate|PacketRelayDelegate|GossipSyncDelegate|GossipSyncConfig|CachedPacketEntry|MessageRouterDelegate|CommandProcessorDelegate|ChannelCrypto|PeerStateStore|PeerStateManagerDeps|PrivateMediaSecurityDeps|PrivateMediaTransferPreparerDeps|PrivateMediaSendIntentDeps|VerificationSigner|NostrRandomSource|NostrTransportDeps|CourierPersistence|CourierManagerDeps|StoreForwardManagerDeps|LiveVoiceAssemblerDelegate)\s*)\}\s+from/g,
    'import type {$1} from');
  return out.replace(/(from\s+['"])(\.\.?\/[^'"]+)(['"])/g, (match, head, specifier, tail) => {
    if (specifier.endsWith('.ts')) {
      return match;
    }
    return `${head}${specifier}.ts${tail}`;
  });
}

function stageFile(src, destRel) {
  const content = fs.readFileSync(src, 'utf8');
  // Only real import statements exclude a file; doc comments may mention kits.
  if (/^[ \t]*import[^\n]*['"]@(kit|ohos)\./m.test(content)) {
    console.warn(`SKIP ${path.relative(entryDir, src)}: imports device APIs, not host-runnable`);
    return false;
  }
  const dest = path.join(stageRoot, destRel);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.writeFileSync(dest, rewriteImports(content));
  return true;
}

function stageTree(dir, destRel) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const src = path.join(dir, entry.name);
    const rel = `${destRel}/${entry.name}`;
    if (entry.isDirectory()) {
      stageTree(src, rel);
    } else if (entry.name.endsWith('.ets')) {
      stageFile(src, rel.replace(/\.ets$/, '.ts'));
    }
  }
}

stageTree(path.join(mainEtsDir, 'common'), 'main/ets/common');
stageTree(path.join(mainEtsDir, 'model'), 'main/ets/model');
stageTree(path.join(mainEtsDir, 'service'), 'main/ets/service');
stageTree(path.join(mainEtsDir, 'data'), 'main/ets/data');

// T039: the pure command kernel lives under viewmodel; stage only the
// host-runnable files. ChatState / ChatViewModel carry state-management
// decorators and kit imports and stay device-side.
stageFile(path.join(mainEtsDir, 'viewmodel', 'CommandProcessor.ets'), 'main/ets/viewmodel/CommandProcessor.ts');
stageFile(path.join(mainEtsDir, 'viewmodel', 'CommandSuggestion.ets'), 'main/ets/viewmodel/CommandSuggestion.ts');

for (const name of fs.readdirSync(contractDir)) {
  if (name.endsWith('.ets')) {
    stageFile(path.join(contractDir, name), `test/contract/${name.replace(/\.ets$/, '.ts')}`);
  }
}

fs.writeFileSync(path.join(stageRoot, 'package.json'), JSON.stringify({ type: 'module' }));

const runnerSource = `
import type { ContractAssert } from './test/contract/ContractAssert.ts';
import { runWireContractTests } from './test/contract/WireContractTests.ts';
import { runPacketPayloadLimitsContractTests } from './test/contract/PacketPayloadLimitsContractTests.ts';
import { runGcsFilterContractTests, runGcsFilterParameterContractTests } from './test/contract/GcsFilterContractTests.ts';
import { runBech32ContractTests } from './test/contract/Bech32ContractTests.ts';
import { runNoisePrimitivesContractTests } from './test/contract/NoisePrimitivesContractTests.ts';
import { runNoiseSessionContractTests } from './test/contract/NoiseSessionContractTests.ts';
import { runNoiseSessionManagerContractTests } from './test/contract/NoiseSessionManagerContractTests.ts';
import { runNoiseXSealContractTests } from './test/contract/NoiseXSealContractTests.ts';
import { runAnnounceContractTests } from './test/contract/AnnounceContractTests.ts';
import { runPacketProcessorContractTests } from './test/contract/PacketProcessorContractTests.ts';
import { runPacketRelayContractTests } from './test/contract/PacketRelayContractTests.ts';
import { runTopologyMapContractTests } from './test/contract/TopologyMapContractTests.ts';
import { runGossipSyncContractTests } from './test/contract/GossipSyncContractTests.ts';
import { runMessageRouterContractTests } from './test/contract/MessageRouterContractTests.ts';
import { runConversationPayloadCodecContractTests } from './test/contract/ConversationPayloadCodecContractTests.ts';
import { runSpamFilterContractTests } from './test/contract/SpamFilterContractTests.ts';
import { runCommandProcessorContractTests } from './test/contract/CommandProcessorContractTests.ts';
import { runChannelManagerContractTests } from './test/contract/ChannelManagerContractTests.ts';
import { runPeerStateManagerContractTests } from './test/contract/PeerStateManagerContractTests.ts';
import { runMediaTransferContractTests } from './test/contract/MediaTransferContractTests.ts';
import { runVoiceNoteWaveformContractTests } from './test/contract/VoiceNoteWaveformContractTests.ts';
import { runVerificationContractTests } from './test/contract/VerificationContractTests.ts';
import { runNostrContractTests } from './test/contract/NostrContractTests.ts';
import { runNostrRelayContractTests } from './test/contract/NostrRelayContractTests.ts';
import { runNostrTransportContractTests } from './test/contract/NostrTransportContractTests.ts';
import { runCourierModelsContractTests } from './test/contract/CourierModelsContractTests.ts';
import { runCourierManagerContractTests } from './test/contract/CourierManagerContractTests.ts';
import { runStoreForwardManagerContractTests } from './test/contract/StoreForwardManagerContractTests.ts';
import { runGeohashServiceContractTests } from './test/contract/GeohashServiceContractTests.ts';
import { runGeohashChannelsContractTests } from './test/contract/GeohashChannelsContractTests.ts';
import { runGlobeKernelContractTests } from './test/contract/GlobeKernelContractTests.ts';
import { runLiveVoiceContractTests } from './test/contract/LiveVoiceContractTests.ts';
import { runPttPolicyContractTests } from './test/contract/PttPolicyContractTests.ts';
import { runSocksProxyPolicyContractTests } from './test/contract/SocksProxyPolicyContractTests.ts';

class NodeAssert implements ContractAssert {
  private hex(bytes: Uint8Array): string {
    let out = '';
    for (let i = 0; i < bytes.length; i++) {
      out += bytes[i].toString(16).padStart(2, '0');
    }
    return out;
  }

  private fail(message: string): never {
    throw new Error(message);
  }

  isTrue(condition: boolean, label: string): void {
    if (!condition) {
      this.fail('expected true: ' + label);
    }
  }

  isFalse(condition: boolean, label: string): void {
    if (condition) {
      this.fail('expected false: ' + label);
    }
  }

  equalNumber(expected: number, actual: number, label: string): void {
    if (expected !== actual) {
      this.fail(label + ': expected ' + expected + ', got ' + actual);
    }
  }

  equalString(expected: string, actual: string, label: string): void {
    if (expected !== actual) {
      this.fail(label + ': expected "' + expected + '", got "' + actual + '"');
    }
  }

  equalBytes(expected: Uint8Array, actual: Uint8Array, label: string): void {
    if (expected.length !== actual.length) {
      this.fail(label + ': expected ' + expected.length + ' bytes, got ' + actual.length +
        ' (expected ' + this.hex(expected) + ', got ' + this.hex(actual) + ')');
    }
    for (let i = 0; i < expected.length; i++) {
      if (expected[i] !== actual[i]) {
        this.fail(label + ': differs at byte ' + i +
          ' (expected ' + this.hex(expected) + ', got ' + this.hex(actual) + ')');
      }
    }
  }

  isNull<T>(value: T | null, label: string): void {
    if (value !== null) {
      this.fail('expected null: ' + label);
    }
  }

  isNotNull<T>(value: T | null, label: string): void {
    if (value === null) {
      this.fail('expected non-null: ' + label);
    }
  }

  throws(action: () => void, label: string): void {
    try {
      action();
    } catch (e) {
      return;
    }
    this.fail('expected throw: ' + label);
  }
}

interface TestCase {
  name: string;
  fn: (t: ContractAssert) => void;
}

const t = new NodeAssert();
const tests: TestCase[] = [
  { name: 'WireContractTests', fn: runWireContractTests },
  { name: 'PacketPayloadLimitsContractTests', fn: runPacketPayloadLimitsContractTests },
  { name: 'GcsFilterContractTests', fn: runGcsFilterContractTests },
  { name: 'GcsFilterParameterContractTests', fn: runGcsFilterParameterContractTests },
  { name: 'Bech32ContractTests', fn: runBech32ContractTests },
  { name: 'NoisePrimitivesContractTests', fn: runNoisePrimitivesContractTests },
  { name: 'NoiseSessionContractTests', fn: runNoiseSessionContractTests },
  { name: 'NoiseSessionManagerContractTests', fn: runNoiseSessionManagerContractTests },
  { name: 'NoiseXSealContractTests', fn: runNoiseXSealContractTests },
  { name: 'AnnounceContractTests', fn: runAnnounceContractTests },
  { name: 'PacketProcessorContractTests', fn: runPacketProcessorContractTests },
  { name: 'PacketRelayContractTests', fn: runPacketRelayContractTests },
  { name: 'TopologyMapContractTests', fn: runTopologyMapContractTests },
  { name: 'GossipSyncContractTests', fn: runGossipSyncContractTests },
  { name: 'MessageRouterContractTests', fn: runMessageRouterContractTests },
  { name: 'ConversationPayloadCodecContractTests', fn: runConversationPayloadCodecContractTests },
  { name: 'SpamFilterContractTests', fn: runSpamFilterContractTests },
  { name: 'CommandProcessorContractTests', fn: runCommandProcessorContractTests },
  { name: 'ChannelManagerContractTests', fn: runChannelManagerContractTests },
  { name: 'PeerStateManagerContractTests', fn: runPeerStateManagerContractTests },
  { name: 'MediaTransferContractTests', fn: runMediaTransferContractTests },
  { name: 'VoiceNoteWaveformContractTests', fn: runVoiceNoteWaveformContractTests },
  { name: 'VerificationContractTests', fn: runVerificationContractTests },
  { name: 'NostrContractTests', fn: runNostrContractTests },
  { name: 'NostrRelayContractTests', fn: runNostrRelayContractTests },
  { name: 'NostrTransportContractTests', fn: runNostrTransportContractTests },
  { name: 'CourierModelsContractTests', fn: runCourierModelsContractTests },
  { name: 'CourierManagerContractTests', fn: runCourierManagerContractTests },
  { name: 'StoreForwardManagerContractTests', fn: runStoreForwardManagerContractTests },
  { name: 'GeohashServiceContractTests', fn: runGeohashServiceContractTests },
  { name: 'GeohashChannelsContractTests', fn: runGeohashChannelsContractTests },
  { name: 'GlobeKernelContractTests', fn: runGlobeKernelContractTests },
  { name: 'LiveVoiceContractTests', fn: runLiveVoiceContractTests },
  { name: 'PttPolicyContractTests', fn: runPttPolicyContractTests },
  { name: 'SocksProxyPolicyContractTests', fn: runSocksProxyPolicyContractTests }
];

let passed = 0;
let failed = 0;
for (const test of tests) {
  try {
    test.fn(t);
    passed += 1;
    console.log('PASS ' + test.name);
  } catch (e) {
    failed += 1;
    console.log('FAIL ' + test.name + ': ' + (e instanceof Error ? e.message : String(e)));
  }
}
console.log(passed + ' passed, ' + failed + ' failed');
if (failed > 0) {
  process.exitCode = 1;
}
`;
fs.writeFileSync(path.join(stageRoot, 'runner.ts'), runnerSource);

// Host-side backup exclusion contract: deny-by-default.
let backupOk = false;
try {
  const config = JSON.parse(fs.readFileSync(backupConfigPath, 'utf8'));
  if (config.allowToBackupRestore === false) {
    backupOk = true;
    console.log('PASS BackupExclusionContract (backup_config.json is deny-by-default)');
  } else {
    console.log('FAIL BackupExclusionContract: backup_config.json must set allowToBackupRestore=false (deny-by-default)');
  }
} catch (e) {
  console.log('FAIL BackupExclusionContract: cannot read backup_config.json: ' + (e instanceof Error ? e.message : String(e)));
}
if (!backupOk) {
  failures += 1;
}

const result = spawnSync(process.execPath, ['--experimental-transform-types', 'runner.ts'], {
  cwd: stageRoot,
  stdio: 'inherit',
  encoding: 'utf8'
});

if (result.error) {
  console.log('FAIL contract runner could not start node: ' + result.error.message);
  failures += 1;
} else if (result.status !== 0) {
  failures += 1;
}

if (failures === 0) {
  fs.rmSync(stageRoot, { recursive: true, force: true });
} else {
  console.log('staged sources kept for debugging: ' + stageRoot);
}

process.exitCode = failures === 0 ? 0 : 1;
