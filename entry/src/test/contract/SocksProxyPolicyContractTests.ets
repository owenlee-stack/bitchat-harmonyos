/**
 * Contract tests for the SOCKS proxy parameterization policy (US15, T072):
 *  - the 9060 default port (Android AppConstants.Tor.DEFAULT_SOCKS_PORT
 *    parity),
 *  - host/port validation and the invalid-port fallback,
 *  - the resolved 'host:port' Arti integration address,
 *  - the fail-closed direct-connection gate: only OFF allows direct
 *    relay connections; CUSTOM suppresses them even while the address
 *    is still unusable (Android OkHttpProvider parity, 开启后禁止直连),
 *  - the persisted preference name round-trip (unknown names fall back
 *    to OFF).
 */
import { ContractAssert } from './ContractAssert';
import { SOCKS_PROXY_DEFAULT_PORT, SocksProxyMode,
  socksDirectConnectionsAllowed, socksProxyAddress, socksProxyHostValid,
  socksProxyModeFromName, socksProxyPortOrDefault, socksProxyPortValid }
  from '../../main/ets/service/nostr/SocksProxyPolicy';

export function runSocksProxyPolicyContractTests(t: ContractAssert): void {
  testDefaultPort(t);
  testHostValidation(t);
  testPortValidation(t);
  testAddress(t);
  testDirectGate(t);
  testModeRoundTrip(t);
}

function testDefaultPort(t: ContractAssert): void {
  t.equalNumber(9060, SOCKS_PROXY_DEFAULT_PORT,
    'default SOCKS port must stay at the Android 9060 parity');
}

function testHostValidation(t: ContractAssert): void {
  t.isTrue(socksProxyHostValid('127.0.0.1'), 'a loopback host is usable');
  t.isTrue(socksProxyHostValid('localhost'), 'a hostname is usable');
  t.isTrue(socksProxyHostValid(' 10.0.0.8 '), 'surrounding whitespace is trimmed away');
  t.isFalse(socksProxyHostValid(''), 'an empty host is unusable');
  t.isFalse(socksProxyHostValid('   '), 'a whitespace-only host is unusable');
}

function testPortValidation(t: ContractAssert): void {
  t.isTrue(socksProxyPortValid(1), 'the lowest TCP port is usable');
  t.isTrue(socksProxyPortValid(9060), 'the default port is usable');
  t.isTrue(socksProxyPortValid(65535), 'the highest TCP port is usable');
  t.isFalse(socksProxyPortValid(0), 'port 0 is not a usable proxy port');
  t.isFalse(socksProxyPortValid(-1), 'negative ports are unusable');
  t.isFalse(socksProxyPortValid(65536), 'one past the TCP range is unusable');
  t.isFalse(socksProxyPortValid(9060.5), 'fractional ports are unusable');
  t.isFalse(socksProxyPortValid(NaN), 'NaN ports are unusable');
}

function testAddress(t: ContractAssert): void {
  t.equalString('127.0.0.1:9060',
    socksProxyAddress(SocksProxyMode.CUSTOM, '127.0.0.1', 9060) ?? '',
    'a custom proxy resolves its host:port address');
  t.equalString('localhost:1080',
    socksProxyAddress(SocksProxyMode.CUSTOM, 'localhost', 1080) ?? '',
    'a non-default port rides along');
  t.equalString('10.0.0.8:9060',
    socksProxyAddress(SocksProxyMode.CUSTOM, ' 10.0.0.8 ', 9060) ?? '',
    'the host is trimmed in the resolved address');
  t.isNull(socksProxyAddress(SocksProxyMode.OFF, '127.0.0.1', 9060),
    'OFF never resolves a proxy address');
  t.isNull(socksProxyAddress(SocksProxyMode.CUSTOM, '', 9060),
    'an empty host resolves no address');
  t.isNull(socksProxyAddress(SocksProxyMode.CUSTOM, '127.0.0.1', 0),
    'an invalid port resolves no address');
}

function testDirectGate(t: ContractAssert): void {
  t.isTrue(socksDirectConnectionsAllowed(SocksProxyMode.OFF),
    'OFF allows direct relay connections');
  t.isFalse(socksDirectConnectionsAllowed(SocksProxyMode.CUSTOM),
    'CUSTOM suppresses direct relay connections (开启后禁止直连)');
  // Fail-closed: suppression does not depend on the address being
  // usable yet -- an unusable address must not silently re-enable
  // direct connections (Android OkHttpProvider parity).
  t.isNull(socksProxyAddress(SocksProxyMode.CUSTOM, '', 9060),
    'CUSTOM with an empty host has no address');
  t.isFalse(socksDirectConnectionsAllowed(SocksProxyMode.CUSTOM),
    'and still forbids direct connections');
}

function testModeRoundTrip(t: ContractAssert): void {
  t.equalString('Off', SocksProxyMode.OFF, 'OFF persists as the Off preference');
  t.equalString('Custom', SocksProxyMode.CUSTOM, 'CUSTOM persists as the Custom preference');
  t.isTrue(socksProxyModeFromName('Custom') === SocksProxyMode.CUSTOM,
    'the Custom preference maps back onto CUSTOM');
  t.isTrue(socksProxyModeFromName('Off') === SocksProxyMode.OFF,
    'the Off preference maps back onto OFF');
  t.isTrue(socksProxyModeFromName('garbage') === SocksProxyMode.OFF,
    'unknown preference names fall back to OFF');
}
