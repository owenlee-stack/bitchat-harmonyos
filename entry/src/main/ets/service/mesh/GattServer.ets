/**
 * GATT server / BLE peripheral role (US2, T021).
 *
 * Mirrors bitchat-android BluetoothGattServerManager: hosts the mesh service
 * (GattConstants UUIDs, identical to Android/iOS), accepts client writes on
 * the mesh characteristic (uplink), pushes packets downstream via
 * notifications once the client enabled the CCCD, and advertises the service
 * with the first 8 bytes of our peerID as scan-response service data so
 * scanners can deduplicate us even when the MAC rotates.
 *
 * Connection management: the server enforces MeshConstants.MAX_CONNECTIONS
 * by disconnecting newly arriving clients once the limit is reached; retry /
 * grace / cleanup windows live in the client role (GattClient) and the
 * transport coordinator (BleMeshService).
 */
import { ble, access, constant } from '@kit.ConnectivityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GattConstants, MeshConstants } from '../../common/ProtocolConstants';
import { ByteUtils } from '../../common/ByteUtils';
import { BitchatPacket } from '../../model/BitchatPacket';
import { BinaryProtocol } from '../protocol/BinaryProtocol';

const DOMAIN = 0x0000;
const TAG = 'GattServer';

/** Server-role events surfaced to the transport coordinator. */
export interface GattServerDelegate {
  /** A mesh packet arrived from a connected client. */
  onPacketReceived(packet: BitchatPacket, peerId: string, deviceId: string, linkId: string): void;

  /** A client established the GATT connection. */
  onPeerConnected(deviceId: string, linkId: string): void;

  /** A client connection dropped (or was refused). */
  onPeerDisconnected(deviceId: string, linkId: string): void;
}

export class GattServer {
  private readonly myPeerId: string;
  private readonly delegate: GattServerDelegate | null;

  private server: ble.GattServer | null = null;
  private readonly serverLinkIds: Map<string, string> = new Map();
  private readonly subscribedDevices: Set<string> = new Set();
  private active: boolean = false;
  private advertising: boolean = false;

  constructor(myPeerId: string, delegate: GattServerDelegate | null) {
    this.myPeerId = myPeerId;
    this.delegate = delegate;
  }

  isActive(): boolean {
    return this.active;
  }

  getConnectedDeviceCount(): number {
    return this.serverLinkIds.size;
  }

  getLinkId(deviceId: string): string | null {
    const linkId: string | undefined = this.serverLinkIds.get(deviceId);
    return linkId === undefined ? null : linkId;
  }

  /** True when the client enabled notifications on the mesh characteristic. */
  isSubscribed(deviceId: string): boolean {
    return this.subscribedDevices.has(deviceId);
  }

  /**
   * Start the GATT server and advertising. Returns false (and stays stopped)
   * when Bluetooth is off or the BLE capability is unavailable.
   */
  start(): boolean {
    if (this.active) {
      return true;
    }
    if (!GattServer.isBluetoothReady()) {
      hilog.warn(DOMAIN, TAG, '%{public}s', 'start skipped: bluetooth off or unsupported');
      return false;
    }
    try {
      const server: ble.GattServer = ble.createGattServer();
      server.addService(GattServer.buildMeshService());
      this.server = server;
      this.subscribeServerEvents(server);
      this.startAdvertising();
      this.active = true;
      hilog.info(DOMAIN, TAG, 'gatt server started, advertising=%{public}d', this.advertising ? 1 : 0);
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'start failed: %{public}s', JSON.stringify(e));
      this.releaseServer();
      return false;
    }
  }

  /** Idempotent stop: advertising off, listeners off, server closed. */
  stop(): void {
    if (!this.active && this.server === null) {
      return;
    }
    this.active = false;
    this.stopAdvertising();
    this.releaseServer();
    hilog.info(DOMAIN, TAG, '%{public}s', 'gatt server stopped');
  }

  /** Server-initiated disconnect (connection-limit enforcement, shutdown). */
  disconnectDevice(deviceId: string): void {
    if (this.server === null) {
      return;
    }
    try {
      this.server.disconnect(deviceId);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'disconnect %{public}s failed: %{public}s',
        deviceId, JSON.stringify(e));
    }
  }

  /**
   * Push a packet downstream via notification. Only reaches clients that
   * enabled the CCCD; value size is bounded by the negotiated MTU.
   */
  sendToDevice(deviceId: string, data: Uint8Array): boolean {
    if (!this.active || this.server === null || !this.subscribedDevices.has(deviceId)) {
      return false;
    }
    const bytes: Uint8Array = data.slice();
    const notifyCharacteristic: ble.NotifyCharacteristic = {
      serviceUuid: GattConstants.SERVICE_UUID,
      characteristicUuid: GattConstants.CHARACTERISTIC_UUID,
      characteristicValue: bytes.buffer,
      confirm: false
    };
    try {
      this.server.notifyCharacteristicChanged(deviceId, notifyCharacteristic,
        (err: BusinessError) => {
          if (err) {
            hilog.warn(DOMAIN, TAG, 'notify to %{public}s failed: %{public}s',
              deviceId, JSON.stringify(err));
          }
        });
      return true;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'notify to %{public}s threw: %{public}s',
        deviceId, JSON.stringify(e));
      return false;
    }
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

  private static buildMeshService(): ble.GattService {
    // CCCD (00002902-...) with notifications disabled by default.
    const cccdValue: ArrayBuffer = new ArrayBuffer(2);
    const descriptor: ble.BLEDescriptor = {
      serviceUuid: GattConstants.SERVICE_UUID,
      characteristicUuid: GattConstants.CHARACTERISTIC_UUID,
      descriptorUuid: GattConstants.DESCRIPTOR_UUID,
      descriptorValue: cccdValue
    };
    const characteristic: ble.BLECharacteristic = {
      serviceUuid: GattConstants.SERVICE_UUID,
      characteristicUuid: GattConstants.CHARACTERISTIC_UUID,
      characteristicValue: new ArrayBuffer(1),
      descriptors: [descriptor],
      properties: {
        write: true,
        writeNoResponse: true,
        read: true,
        notify: true,
        indicate: false,
        broadcast: false
      }
    };
    const service: ble.GattService = {
      serviceUuid: GattConstants.SERVICE_UUID,
      isPrimary: true,
      characteristics: [characteristic],
      includeServices: []
    };
    return service;
  }

  private subscribeServerEvents(server: ble.GattServer): void {
    server.on('connectionStateChange', (state: ble.BLEConnectionChangeState) => {
      this.handleConnectionState(state);
    });
    server.on('characteristicWrite', (request: ble.CharacteristicWriteRequest) => {
      this.handleCharacteristicWrite(request);
    });
    server.on('characteristicRead', (request: ble.CharacteristicReadRequest) => {
      this.handleCharacteristicRead(request);
    });
    server.on('descriptorWrite', (request: ble.DescriptorWriteRequest) => {
      this.handleDescriptorWrite(request);
    });
    server.on('descriptorRead', (request: ble.DescriptorReadRequest) => {
      this.handleDescriptorRead(request);
    });
  }

  private handleConnectionState(state: ble.BLEConnectionChangeState): void {
    if (!this.active) {
      return;
    }
    const deviceId: string = state.deviceId;
    if (state.state === constant.ProfileConnectionState.STATE_CONNECTED) {
      if (this.serverLinkIds.size >= MeshConstants.MAX_CONNECTIONS) {
        hilog.warn(DOMAIN, TAG, 'refusing %{public}s: max connections reached', deviceId);
        this.disconnectDevice(deviceId);
        return;
      }
      const linkId: string = util.generateRandomUUID();
      this.serverLinkIds.set(deviceId, linkId);
      hilog.info(DOMAIN, TAG, 'client connected: %{public}s', deviceId);
      if (this.delegate !== null) {
        this.delegate.onPeerConnected(deviceId, linkId);
      }
    } else if (state.state === constant.ProfileConnectionState.STATE_DISCONNECTED) {
      const linkId: string | null = this.getLinkId(deviceId);
      this.serverLinkIds.delete(deviceId);
      this.subscribedDevices.delete(deviceId);
      hilog.info(DOMAIN, TAG, 'client disconnected: %{public}s', deviceId);
      if (this.delegate !== null) {
        this.delegate.onPeerDisconnected(deviceId, linkId === null ? '' : linkId);
      }
    }
  }

  private handleCharacteristicWrite(request: ble.CharacteristicWriteRequest): void {
    if (!this.active) {
      return;
    }
    const deviceId: string = request.deviceId;
    const needRsp: boolean = request.needRsp;
    if (request.characteristicUuid !== GattConstants.CHARACTERISTIC_UUID) {
      this.respond(deviceId, request.transId, needRsp, 1, request.offset);
      return;
    }
    const linkId: string | null = this.getLinkId(deviceId);
    if (linkId === null) {
      hilog.debug(DOMAIN, TAG, 'dropping packet from stale connection %{public}s', deviceId);
      this.respond(deviceId, request.transId, needRsp, 1, request.offset);
      return;
    }
    if (request.isPrepared) {
      // Long/prepared writes are not part of the mesh wire format; the
      // client negotiates an MTU that fits a whole packet instead.
      hilog.warn(DOMAIN, TAG, 'prepared write from %{public}s rejected', deviceId);
      this.respond(deviceId, request.transId, needRsp, 1, request.offset);
      return;
    }
    const packet: BitchatPacket | null = BinaryProtocol.decode(new Uint8Array(request.value));
    if (packet !== null && this.delegate !== null) {
      const peerId: string = ByteUtils.bytesToHex(packet.senderId);
      this.delegate.onPacketReceived(packet, peerId, deviceId, linkId);
    } else if (packet === null) {
      hilog.debug(DOMAIN, TAG, 'unparseable packet from %{public}s, size=%{public}d',
        deviceId, request.value.byteLength);
    }
    // Android responds GATT_SUCCESS even when parsing failed; match that so
    // the client link never stalls on a malformed frame.
    this.respond(deviceId, request.transId, needRsp, 0, request.offset);
  }

  private handleCharacteristicRead(request: ble.CharacteristicReadRequest): void {
    if (!this.active) {
      return;
    }
    this.respond(request.deviceId, request.transId, true, 0, request.offset);
  }

  private handleDescriptorWrite(request: ble.DescriptorWriteRequest): void {
    if (!this.active) {
      return;
    }
    const deviceId: string = request.deviceId;
    if (request.descriptorUuid === GattConstants.DESCRIPTOR_UUID) {
      const value: Uint8Array = new Uint8Array(request.value);
      if (value.length > 0 && (value[0] & 0x01) !== 0) {
        this.subscribedDevices.add(deviceId);
        hilog.info(DOMAIN, TAG, 'client subscribed: %{public}s', deviceId);
      } else {
        this.subscribedDevices.delete(deviceId);
      }
    }
    this.respond(deviceId, request.transId, request.needRsp, 0, request.offset);
  }

  private handleDescriptorRead(request: ble.DescriptorReadRequest): void {
    if (!this.active) {
      return;
    }
    this.respond(request.deviceId, request.transId, true, 0, request.offset);
  }

  private respond(deviceId: string, transId: number, needRsp: boolean,
    status: number, offset: number): void {
    if (!needRsp || this.server === null) {
      return;
    }
    const response: ble.ServerResponse = {
      deviceId: deviceId,
      transId: transId,
      status: status,
      offset: offset,
      value: new ArrayBuffer(0)
    };
    try {
      this.server.sendResponse(response);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'sendResponse failed: %{public}s', JSON.stringify(e));
    }
  }

  private startAdvertising(): void {
    try {
      const setting: ble.AdvertiseSetting = {
        interval: 400,
        txPower: 1,
        connectable: true,
        isExtended: false
      };
      const advData: ble.AdvertiseData = {
        serviceUuids: [GattConstants.SERVICE_UUID],
        manufactureData: [],
        serviceData: []
      };
      const advResponse: ble.AdvertiseData = {
        serviceUuids: [],
        manufactureData: [],
        serviceData: [GattServer.buildPeerIdServiceData(this.myPeerId)]
      };
      ble.startAdvertising(setting, advData, advResponse);
      this.advertising = true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'startAdvertising failed: %{public}s', JSON.stringify(e));
    }
  }

  private static buildPeerIdServiceData(myPeerId: string): ble.ServiceData {
    // First 8 bytes of the peerID hex string; empty on malformed input so
    // advertising still works (discovery by service UUID alone).
    let peerIdBytes: Uint8Array = new Uint8Array(0);
    try {
      peerIdBytes = ByteUtils.hexToBytes(myPeerId).slice(0, 8);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'peerId service data unavailable: %{public}s', JSON.stringify(e));
    }
    const serviceData: ble.ServiceData = {
      serviceUuid: GattConstants.SERVICE_UUID,
      serviceValue: peerIdBytes.buffer
    };
    return serviceData;
  }

  private stopAdvertising(): void {
    if (!this.advertising) {
      return;
    }
    try {
      ble.stopAdvertising();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'stopAdvertising failed: %{public}s', JSON.stringify(e));
    }
    this.advertising = false;
  }

  private releaseServer(): void {
    if (this.server !== null) {
      try {
        this.server.off('connectionStateChange');
        this.server.off('characteristicWrite');
        this.server.off('characteristicRead');
        this.server.off('descriptorWrite');
        this.server.off('descriptorRead');
        this.server.removeService(GattConstants.SERVICE_UUID);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'server teardown partial failure: %{public}s', JSON.stringify(e));
      }
      try {
        this.server.close();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'server close failed: %{public}s', JSON.stringify(e));
      }
      this.server = null;
    }
    this.serverLinkIds.clear();
    this.subscribedDevices.clear();
  }
}
