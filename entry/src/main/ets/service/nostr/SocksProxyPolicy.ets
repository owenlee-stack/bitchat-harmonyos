/**
 * SOCKS proxy parameterization policy (US15, T072), pure ArkTS: the
 * OFF/custom proxy decision the Nostr transport obeys, reserving the
 * integration point for the phase-3 Arti (Tor-in-Rust) native port
 * (spec/bitchat-harmonyos/notes-arti-port.md).
 *
 * Android parity:
 *  - AppConstants.Tor.DEFAULT_SOCKS_PORT (9060): the default SOCKS port
 *    a custom proxy pre-fills;
 *  - OkHttpProvider.baseBuilderForCurrentProxy: as soon as Tor mode is
 *    ON -- even before bootstrap completes -- every client is built
 *    through the SOCKS address so no direct connection can occur
 *    (开启后禁止直连, fail-closed even when the address itself is
 *    still unusable or invalid).
 *
 * No @kit import: this module is host-runnable and contract-tested.
 */

/** Default SOCKS proxy port (Android DEFAULT_SOCKS_PORT parity). */
export const SOCKS_PROXY_DEFAULT_PORT = 9060;

/** Lowest assignable TCP port. */
export const SOCKS_PROXY_MIN_PORT = 1;

/** Highest assignable TCP port. */
export const SOCKS_PROXY_MAX_PORT = 65535;

/** User-facing proxy selection: off (direct) or a custom SOCKS proxy. */
export enum SocksProxyMode {
  OFF = 'Off',
  CUSTOM = 'Custom'
}

/** A host is usable when it is non-empty after trimming. */
export function socksProxyHostValid(host: string): boolean {
  return host.trim().length > 0;
}

/** A port is usable when it is an integer within the TCP range. */
export function socksProxyPortValid(port: number): boolean {
  if (Number.isNaN(port) || Math.floor(port) !== port) {
    return false;
  }
  return port >= SOCKS_PROXY_MIN_PORT && port <= SOCKS_PROXY_MAX_PORT;
}

/** Normalize an entered port: invalid input falls back to the default. */
export function socksProxyPortOrDefault(port: number): number {
  return socksProxyPortValid(port) ? port : SOCKS_PROXY_DEFAULT_PORT;
}

/**
 * Resolved 'host:port' proxy address, or null when the mode is OFF or
 * the custom inputs are not usable. The address is the reserved Arti
 * transport endpoint; a null address never re-enables direct
 * connections (use socksDirectConnectionsAllowed for the gate).
 */
export function socksProxyAddress(mode: SocksProxyMode, host: string,
  port: number): string | null {
  if (mode !== SocksProxyMode.CUSTOM) {
    return null;
  }
  if (!socksProxyHostValid(host) || !socksProxyPortValid(port)) {
    return null;
  }
  return host.trim() + ':' + port;
}

/**
 * Direct-connection gate: only OFF allows direct relay connections.
 * CUSTOM suppresses them fail-closed (Android OkHttpProvider parity),
 * regardless of whether the proxy address is usable yet.
 */
export function socksDirectConnectionsAllowed(mode: SocksProxyMode): boolean {
  return mode === SocksProxyMode.OFF;
}

/** Map a persisted preference name back onto the mode (unknown -> OFF). */
export function socksProxyModeFromName(name: string): SocksProxyMode {
  return name === 'Custom' ? SocksProxyMode.CUSTOM : SocksProxyMode.OFF;
}
