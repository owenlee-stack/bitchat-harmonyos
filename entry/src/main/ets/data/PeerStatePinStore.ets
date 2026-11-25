/**
 * Durable pin store for the 0x21 authenticated peer-state exchange
 * (US10, T051/T053; Android PeerStatePinStore parity).
 *
 * One file per authenticated static-key fingerprint under
 * filesDir/peerstates/, holding the hex of the AuthenticatedPeerState
 * wire encoding. The PeerStateManager contract requires the pin to be
 * durable BEFORE the replacement Ed key is published, and its store
 * interface is synchronous, so writes use the fileIo sync series
 * (small fixed-size records; the UI thread is never blocked long).
 *
 * Panic wipe clears the whole directory together with the media sweep.
 */
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AuthenticatedPeerState, PeerCapabilities } from '../model/IdentityModels';
import { PeerStateStore } from '../service/mesh/PeerStateManager';
import { ByteUtils } from '../common/ByteUtils';

const DOMAIN = 0x0000;
const TAG = 'PeerStatePinStore';

/** filesDir subdirectory holding one '<fingerprint>.hex' per pin. */
const PIN_DIR = 'peerstates';

export class PeerStatePinStore implements PeerStateStore {
  private static instance: PeerStatePinStore | null = null;
  private filesRoot: string = '';

  static getInstance(): PeerStatePinStore {
    if (PeerStatePinStore.instance === null) {
      PeerStatePinStore.instance = new PeerStatePinStore();
    }
    return PeerStatePinStore.instance;
  }

  private constructor() {
  }

  /** Capture the sandbox root; idempotent, safe to re-call. */
  init(context: common.Context): void {
    this.filesRoot = context.filesDir;
  }

  load(fingerprint: string): AuthenticatedPeerState | null {
    const path: string = this.pathFor(fingerprint);
    if (!fileIo.accessSync(path)) {
      return null;
    }
    try {
      const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        const stat: fileIo.Stat = fileIo.statSync(file.fd);
        const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
        const read: number = fileIo.readSync(file.fd, buffer);
        const hex: string = ByteUtils.utf8Decode(new Uint8Array(buffer.slice(0, read)));
        const bytes: Uint8Array = ByteUtils.hexToBytes(hex);
        if (bytes.length === 0) {
          return null;
        }
        return AuthenticatedPeerState.decode(bytes);
      } finally {
        fileIo.closeSync(file);
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'load pin failed: %{public}s', err.message);
      return null;
    }
  }

  persist(fingerprint: string, state: AuthenticatedPeerState,
    onCommitted: () => void): boolean {
    if (this.filesRoot === '') {
      return false;
    }
    const encoded: Uint8Array = state.encode();
    const hex: string = ByteUtils.bytesToHex(encoded);
    const dir: string = PeerStatePinStore.joinPath(this.filesRoot, PIN_DIR);
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      const out: ArrayBuffer = new ArrayBuffer(hex.length);
      const view: Uint8Array = new Uint8Array(out);
      view.set(ByteUtils.utf8Encode(hex));
      const file: fileIo.File = fileIo.openSync(this.pathFor(fingerprint),
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, out);
      } finally {
        fileIo.closeSync(file);
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'persist pin failed: %{public}s', err.message);
      return false;
    }
    // Durable: publish the replacement Ed key only after the write landed.
    onCommitted();
    return true;
  }

  isPrivateMediaPinned(fingerprint: string): boolean {
    const state: AuthenticatedPeerState | null = this.load(fingerprint);
    return state !== null && state.capabilities.contains(PeerCapabilities.PRIVATE_MEDIA);
  }

  /** Panic wipe: drop every stored pin. */
  clearAll(): boolean {
    if (this.filesRoot === '') {
      return true;
    }
    const dir: string = PeerStatePinStore.joinPath(this.filesRoot, PIN_DIR);
    if (!fileIo.accessSync(dir)) {
      return true;
    }
    try {
      fileIo.rmdirSync(dir);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'clear pins failed: %{public}s', err.message);
      return false;
    }
  }

  private pathFor(fingerprint: string): string {
    return PeerStatePinStore.joinPath(
      PeerStatePinStore.joinPath(this.filesRoot, PIN_DIR),
      fingerprint.toLowerCase() + '.hex');
  }

  private static joinPath(base: string, child: string): string {
    return base.endsWith('/') ? base + child : base + '/' + child;
  }
}
