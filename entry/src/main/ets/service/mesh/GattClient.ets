/**
 * GATT client / BLE central role (US2, T022).
 *
 * Mirrors bitchat-android BluetoothGattClientManager: scans for advertisers
 * carrying the mesh service UUID, reports discoveries (with the stable peerID
 * extracted from the scan-response service data) to the transport
 * coordinator, and on request connects a client link with the Android
 * sequencing: connect -> MTU 517 negotiation -> service discovery -> enable
 * CCCD notifications -> link ready. Packets from the server arrive via
 * 'BLECharacteristicChange'; uplink goes through writeCharacteristicValue
 * (acknowledged write, payload bounded by MTU-3; fragmentation is owned by
 * the coordinator).
 *
 * Retry/backoff policy for dropped links lives in the coordinator
 * (BleMeshService) so client and server roles share one connection ledger.
 */
import { ble, access, constant } from '@kit.ConnectivityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GattConstants } from '../../common/ProtocolConstants';
import { ByteUtils } from '../../common/ByteUtils';
import { BitchatPacket } from '../../model/BitchatPacket';
import { BinaryProtocol } from '../protocol/BinaryProtocol';

const DOMAIN = 0x0000;
const TAG = 'GattClient';

/** Android parity: requestMtu(517) after the link comes up. */
const REQUESTED_MTU = 517;
/** Fallback when the stack never reports an MTU change. */
const MTU_FALLBACK_MS = 2000;
/** Delay before closing a disconnected client handle (Android: 500ms). */
const CLOSE_DELAY_MS = 500;
/** Minimum spacing between scan starts (Android scan rate limit). */
const SCAN_START_RATE_LIMIT_MS = 5000;

/** A single client-role connection to a mesh GATT server. */
export class ClientLink {
  readonly deviceId: string;
  readonly peerId: string | null;
  readonly linkId: string;
  readonly gattClient: ble.GattClientDevice;
  characteristic: ble.BLECharacteristic | null;
  mtu: number;
  ready: boolean;

  constructor(deviceId: string, peerId: string | null, linkId: string,
    gattClient: ble.GattClientDevice) {
    this.deviceId = deviceId;
    this.peerId = peerId;
    this.linkId = linkId;
    this.gattClient = gattClient;
    this.characteristic = null;
    this.mtu = 23;
    this.ready = false;
  }
}

/** Client-role events surfaced to the transport coordinator. */
export interface GattClientDelegate {
  /** An advertiser carrying the mesh service UUID was discovered. */
  onPeerDiscovered(deviceId: string, rssi: number, peerId: string | null): void;

  /** A requested link finished MTU + service discovery + CCCD setup. */
  onPeerConnected(deviceId: string, linkId: string): void;

  /** A link dropped (or failed to establish). */
  onPeerDisconnected(deviceId: string, linkId: string): void;

  /** A mesh packet arrived from a connected server. */
  onPacketReceived(packet: BitchatPacket, peerId: string, deviceId: string, linkId: string): void;
}

export class GattClient {
  private readonly delegate: GattClientDelegate | null;

  private readonly links: Map<string, ClientLink> = new Map();
  private readonly connecting: Set<string> = new Set();
  private scanning: boolean = false;
  private lastScanStartMs: number = 0;
  private scanRestartTimer: number = -1;

  constructor(delegate: GattClientDelegate | null) {
    this.delegate = delegate;
  }

  isScanning(): boolean {
    return this.scanning;
  }

  getConnectedDeviceCount(): number {
    return this.links.size;
  }

  getLink(deviceId: string): ClientLink | null {
    const link: ClientLink | undefined = this.links.get(deviceId);
    return link === undefined ? null : link;
  }

  /** Start scanning for mesh advertisers (idempotent, rate-limited). */
  startScanning(): void {
    if (this.scanning) {
      return;
    }
    if (!GattClient.isBluetoothReady()) {
      hilog.warn(DOMAIN, TAG, '%{public}s', 'scan skipped: bluetooth off or unsupported');
      return;
    }
    const now: number = Date.now();
    const sinceLastStart: number = now - this.lastScanStartMs;
    if (sinceLastStart < SCAN_START_RATE_LIMIT_MS) {
      if (this.scanRestartTimer < 0) {
        const waitMs: number = SCAN_START_RATE_LIMIT_MS - sinceLastStart;
        this.scanRestartTimer = setTimeout(() => {
          this.scanRestartTimer = -1;
          this.startScanning();
        }, waitMs);
      }
      return;
    }
    try {
      ble.on('BLEDeviceFind', (results: Array<ble.ScanResult>) => {
        this.handleScanResults(results);
      });
      const filter: ble.ScanFilter = {
        serviceUuid: GattConstants.SERVICE_UUID
      };
      ble.startBLEScan([filter]);
      this.lastScanStartMs = now;
      this.scanning = true;
      hilog.info(DOMAIN, TAG, '%{public}s', 'scan started');
    } catch (e) {
      ble.off('BLEDeviceFind');
      hilog.error(DOMAIN, TAG, 'scan start failed: %{public}s', JSON.stringify(e));
    }
  }

  stopScanning(): void {
    if (this.scanRestartTimer >= 0) {
      clearTimeout(this.scanRestartTimer);
      this.scanRestartTimer = -1;
    }
    if (!this.scanning) {
      return;
    }
    try {
      ble.stopBLEScan();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'scan stop failed: %{public}s', JSON.stringify(e));
    }
    ble.off('BLEDeviceFind');
    this.scanning = false;
    hilog.info(DOMAIN, TAG, '%{public}s', 'scan stopped');
  }

  /**
   * Connect to a discovered advertiser as GATT client. Ignored when a link
   * or connection attempt already exists for the device.
   */
  connectDevice(deviceId: string, peerId: string | null): boolean {
    if (this.links.has(deviceId) || this.connecting.has(deviceId)) {
      return false;
    }
    try {
      const gattClient: ble.GattClientDevice = ble.createGattClientDevice(deviceId);
      const linkId: string = util.generateRandomUUID();
      const link: ClientLink = new ClientLink(deviceId, peerId, linkId, gattClient);
      this.subscribeLinkEvents(link);
      this.connecting.add(deviceId);
      gattClient.connect();
      hilog.info(DOMAIN, TAG, 'connecting to %{public}s', deviceId);
      return true;
    } catch (e) {
      this.connecting.delete(deviceId);
      hilog.error(DOMAIN, TAG, 'connect to %{public}s failed: %{public}s',
        deviceId, JSON.stringify(e));
      return false;
    }
  }

  /** Client-initiated disconnect. */
  disconnectDevice(deviceId: string): void {
    const link: ClientLink | null = this.getLink(deviceId);
    if (link !== null) {
      try {
        link.gattClient.disconnect();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'disconnect %{public}s failed: %{public}s',
          deviceId, JSON.stringify(e));
      }
      return;
    }
    if (this.connecting.has(deviceId)) {
      this.connecting.delete(deviceId);
      try {
        const gattClient: ble.GattClientDevice = ble.createGattClientDevice(deviceId);
        gattClient.disconnect();
        gattClient.close();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'abort connecting %{public}s failed: %{public}s',
          deviceId, JSON.stringify(e));
      }
    }
  }

  /**
   * Uplink write on an established link. Returns false when the link is not
   * ready or the payload exceeds MTU-3 (the coordinator fragments).
   */
  sendToDevice(deviceId: string, data: Uint8Array): boolean {
    const link: ClientLink | null = this.getLink(deviceId);
    if (link === null || link.characteristic === null || !link.ready) {
      return false;
    }
    if (data.length > link.mtu - 3) {
      hilog.warn(DOMAIN, TAG, 'drop write to %{public}s: %{public}d > MTU-3 %{public}d',
        deviceId, data.length, link.mtu - 3);
      return false;
    }
    const bytes: Uint8Array = data.slice();
    const writeCharacteristic: ble.BLECharacteristic = {
      serviceUuid: link.characteristic.serviceUuid,
      characteristicUuid: link.characteristic.characteristicUuid,
      characteristicValue: bytes.buffer,
      descriptors: link.characteristic.descriptors
    };
    try {
      link.gattClient.writeCharacteristicValue(writeCharacteristic, ble.GattWriteType.WRITE,
        (err: BusinessError) => {
          if (err) {
            hilog.warn(DOMAIN, TAG, 'write to %{public}s failed: %{public}s',
              deviceId, JSON.stringify(err));
          }
        });
      return true;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'write to %{public}s threw: %{public}s',
        deviceId, JSON.stringify(e));
      return false;
    }
  }

  /** Decisive teardown: scan off, every link disconnected and closed. */
  stop(): void {
    this.stopScanning();
    const deviceIds: string[] = [];
    this.links.forEach((link: ClientLink) => {
      deviceIds.push(link.deviceId);
    });
    for (let i = 0; i < deviceIds.length; i++) {
      this.disconnectDevice(deviceIds[i]);
    }
    const connectingIds: string[] = [];
    this.connecting.forEach((deviceId: string) => {
      connectingIds.push(deviceId);
    });
    for (let i = 0; i < connectingIds.length; i++) {
      this.disconnectDevice(connectingIds[i]);
    }
    this.links.clear();
    this.connecting.clear();
  }

  // ------------------------------------------------------------------
  // Internals
  // ------------------------------------------------------------------

  private static isBluetoothReady(): boolean {
    try {
      const state: access.BluetoothState = access.getState();
      return state === access.BluetoothState.STATE_ON ||
        state === access.BluetoothState.STATE_BLE_ON;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'getState failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  private handleScanResults(results: Array<ble.ScanResult>): void {
    for (let i = 0; i < results.length; i++) {
      const result: ble.ScanResult = results[i];
      const hasOurService: boolean = GattClient.resultHasService(result);
      if (!hasOurService) {
        continue;
      }
      const peerId: string | null = GattClient.extractPeerId(result);
      if (this.delegate !== null) {
        this.delegate.onPeerDiscovered(result.deviceId, result.rssi, peerId);
      }
    }
  }

  private static resultHasService(result: ble.ScanResult): boolean {
    const uuids: string[] | undefined = result.serviceUuids;
    if (uuids !== undefined) {
      for (let i = 0; i < uuids.length; i++) {
        if (uuids[i].toUpperCase() === GattConstants.SERVICE_UUID) {
          return true;
        }
      }
    }
    const dataMap: Map<string, Uint8Array> | undefined = result.serviceDataMap;
    if (dataMap !== undefined) {
      let found: boolean = false;
      dataMap.forEach((value: Uint8Array, key: string) => {
        if (key.toUpperCase() === GattConstants.SERVICE_UUID) {
          found = true;
        }
      });
      if (found) {
        return true;
      }
    }
    return false;
  }

  private static extractPeerId(result: ble.ScanResult): string | null {
    const dataMap: Map<string, Uint8Array> | undefined = result.serviceDataMap;
    if (dataMap === undefined) {
      return null;
    }
    const candidates: Uint8Array[] = [];
    dataMap.forEach((value: Uint8Array, key: string): void => {
      if (key.toUpperCase() === GattConstants.SERVICE_UUID && value.length >= 8) {
        candidates.push(value);
      }
    });
    if (candidates.length === 0) {
      return null;
    }
    return ByteUtils.bytesToHex(candidates[0].slice(0, 8));
  }

  private subscribeLinkEvents(link: ClientLink): void {
    const gattClient: ble.GattClientDevice = link.gattClient;
    gattClient.on('BLEConnectionStateChange', (state: ble.BLEConnectionChangeState) => {
      this.handleLinkConnectionState(link, state);
    });
    gattClient.on('BLEMtuChange', (mtu: number) => {
      this.handleLinkMtuChange(link, mtu);
    });
    gattClient.on('BLECharacteristicChange', (characteristic: ble.BLECharacteristic) => {
      this.handleLinkCharacteristicChange(link, characteristic);
    });
  }

  private handleLinkConnectionState(link: ClientLink, state: ble.BLEConnectionChangeState): void {
    if (state.state === constant.ProfileConnectionState.STATE_CONNECTED) {
      hilog.info(DOMAIN, TAG, 'link up: %{public}s', link.deviceId);
      // Android sequencing: negotiate MTU first, discover services after.
      try {
        link.gattClient.setBLEMtuSize(REQUESTED_MTU);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'MTU request failed for %{public}s: %{public}s',
          link.deviceId, JSON.stringify(e));
        this.disconnectDevice(link.deviceId);
        return;
      }
      // Some stacks never emit BLEMtuChange; proceed with defaults after a
      // grace period so the link cannot wedge in discovery-less limbo.
      setTimeout(() => {
        this.handleLinkMtuChange(link, link.mtu);
      }, MTU_FALLBACK_MS);
    } else if (state.state === constant.ProfileConnectionState.STATE_DISCONNECTED) {
      const wasRegistered: boolean = this.links.delete(link.deviceId);
      this.connecting.delete(link.deviceId);
      hilog.info(DOMAIN, TAG, 'link down: %{public}s (registered=%{public}d)',
        link.deviceId, wasRegistered ? 1 : 0);
      if (this.delegate !== null) {
        this.delegate.onPeerDisconnected(link.deviceId, link.linkId);
      }
      const gattClient: ble.GattClientDevice = link.gattClient;
      setTimeout(() => {
        try {
          gattClient.close();
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'close %{public}s failed: %{public}s',
            link.deviceId, JSON.stringify(e));
        }
      }, CLOSE_DELAY_MS);
    }
  }

  private handleLinkMtuChange(link: ClientLink, mtu: number): void {
    // Deduplicates the real BLEMtuChange event against the fallback timer:
    // only the first arrival registers the link and starts discovery.
    if (!this.connecting.has(link.deviceId) || this.links.has(link.deviceId)) {
      return;
    }
    link.mtu = mtu > 23 ? mtu : 23;
    this.links.set(link.deviceId, link);
    this.discoverLinkServices(link);
  }

  private async discoverLinkServices(link: ClientLink): Promise<void> {
    try {
      const services: Array<ble.GattService> = await link.gattClient.getServices();
      let meshCharacteristic: ble.BLECharacteristic | null = null;
      for (let i = 0; i < services.length; i++) {
        const service: ble.GattService = services[i];
        if (service.serviceUuid.toUpperCase() !== GattConstants.SERVICE_UUID) {
          continue;
        }
        for (let j = 0; j < service.characteristics.length; j++) {
          const characteristic: ble.BLECharacteristic = service.characteristics[j];
          if (characteristic.characteristicUuid.toUpperCase() === GattConstants.CHARACTERISTIC_UUID) {
            meshCharacteristic = characteristic;
            break;
          }
        }
        break;
      }
      if (meshCharacteristic === null) {
        hilog.warn(DOMAIN, TAG, 'mesh service/characteristic missing on %{public}s',
          link.deviceId);
        this.disconnectDevice(link.deviceId);
        return;
      }
      link.characteristic = meshCharacteristic;
      await link.gattClient.setCharacteristicChangeNotification(meshCharacteristic, true);
      link.ready = true;
      this.connecting.delete(link.deviceId);
      hilog.info(DOMAIN, TAG, 'link ready: %{public}s (mtu=%{public}d)', link.deviceId, link.mtu);
      if (this.delegate !== null) {
        this.delegate.onPeerConnected(link.deviceId, link.linkId);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'service discovery failed for %{public}s: %{public}s',
        link.deviceId, JSON.stringify(e));
      this.disconnectDevice(link.deviceId);
    }
  }

  private handleLinkCharacteristicChange(link: ClientLink,
    characteristic: ble.BLECharacteristic): void {
    if (characteristic.characteristicUuid.toUpperCase() !== GattConstants.CHARACTERISTIC_UUID) {
      return;
    }
    const packet: BitchatPacket | null =
      BinaryProtocol.decode(new Uint8Array(characteristic.characteristicValue));
    if (packet === null) {
      hilog.debug(DOMAIN, TAG, 'unparseable packet from %{public}s, size=%{public}d',
        link.deviceId, characteristic.characteristicValue.byteLength);
      return;
    }
    if (this.delegate !== null) {
      const peerId: string = ByteUtils.bytesToHex(packet.senderId);
      this.delegate.onPacketReceived(packet, peerId, link.deviceId, link.linkId);
    }
  }
}
