/**
 * Media file storage (US10, T050; Android FileUtils/ImageUtils parity).
 *
 * Owns every app-sandbox media path used by private media v1:
 *  - incoming files land under cacheDir (images/... for image MIME, files/...
 *    otherwise) so the system can reclaim them under storage pressure -
 *    the Android issue #592 storage-exhaustion defense: cacheDir, never
 *    filesDir, for untrusted incoming bytes;
 *  - outgoing images are downscaled (max 512px, JPEG 85) with the EXIF
 *    orientation baked in before sending (Android ImageUtils parity);
 *  - the transfer quota (MediaConstants.MAX_FILE_SIZE_BYTES, 10MiB minus
 *    132KiB of TLV/envelope overhead) is enforced here so every send path
 *    shares one bound;
 *  - panic wipe sweeps the media directories (clearAllMedia) and
 *    conversation deletion only removes files proven unreferenced, and
 *    only inside the sandbox roots (deleteConversationMedia /
 *    deleteStoredMediaPaths with canonical-path containment).
 */
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { MediaConstants } from '../common/ProtocolConstants';
import { BitchatMessageType } from '../model/BitchatMessage';

const DOMAIN = 0x0000;
const TAG = 'MediaFileStore';

/** filesDir subdirectories swept by panic cleanup (Android parity). */
const FILES_DIR_SUBDIRS: string[] = ['files/incoming', 'files/outgoing',
  'images/incoming', 'images/outgoing', 'voicenotes'];
/** cacheDir subdirectories swept by panic cleanup (Android parity). */
const CACHE_DIR_SUBDIRS: string[] = ['files/incoming', 'images/incoming', 'staging'];

const FILENAME_SANITIZE_REGEX = /[^A-Za-z0-9._-]/g;
/** Uniqueness attempts before the fallback path gives up. */
const MAX_NAME_ATTEMPTS = 1000;
/** Outgoing image cap (longest edge, px); Android ImageUtils parity. */
const IMAGE_OUTGOING_MAX_DIM = 512;
/** Outgoing JPEG quality [0..100]; Android ImageUtils parity. */
const IMAGE_OUTGOING_JPEG_QUALITY = 85;

export class MediaFileStore {
  private static instance: MediaFileStore | null = null;
  /** App sandbox filesDir ('/data/storage/el2/base/els'). */
  private filesRoot: string = '';
  /** App sandbox cacheDir; incoming media lives here (issue #592 defense). */
  private cacheRoot: string = '';

  static getInstance(): MediaFileStore {
    if (MediaFileStore.instance === null) {
      MediaFileStore.instance = new MediaFileStore();
    }
    return MediaFileStore.instance;
  }

  private constructor() {
  }

  /** Capture the sandbox roots; idempotent, safe to re-call. */
  init(context: common.Context): void {
    this.filesRoot = context.filesDir;
    this.cacheRoot = context.cacheDir;
  }

  /** One shared send-side bound: the encoded file must fit one payload. */
  isWithinTransferQuota(sizeBytes: number): boolean {
    return sizeBytes > 0 && sizeBytes <= MediaConstants.MAX_FILE_SIZE_BYTES;
  }

  /**
   * Save one received file into cacheDir and return its absolute path.
   * Images land in images/incoming, everything else in files/incoming;
   * names are sanitized and uniquified ('name (1).ext'); a write failure
   * falls back to the cacheDir root (Android saveIncomingFile parity).
   */
  saveIncomingFile(fileName: string, fileSize: number, mimeType: string,
    content: Uint8Array): string | null {
    if (this.cacheRoot === '' || content.length === 0) {
      return null;
    }
    const lowerMime: string = mimeType.toLowerCase();
    const isImage: boolean = lowerMime.startsWith('image/');
    const subDir: string = isImage ? 'images/incoming' : 'files/incoming';
    let dir: string = '';
    try {
      dir = this.ensureDirectory(this.cacheRoot, subDir);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'create incoming dir failed: %{public}s', err.message);
      return null;
    }
    const rawBase: string = fileName !== '' ? fileName : (isImage ? 'img' : 'file');
    const baseName: string = rawBase.replace(FILENAME_SANITIZE_REGEX, '_');
    const ext: string = MediaFileStore.extensionForMime(lowerMime, isImage);
    let safeName: string = baseName.indexOf('.') >= 0 ? baseName : baseName + ext;
    let attempt: number = 1;
    while (fileIo.accessSync(MediaFileStore.joinPath(dir, safeName)) &&
      attempt < MAX_NAME_ATTEMPTS) {
      safeName = MediaFileStore.uniquifyName(safeName, attempt);
      attempt++;
    }
    try {
      const target: string = MediaFileStore.joinPath(dir, safeName);
      this.writeBytes(target, content);
      return target;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'save incoming file failed: %{public}s', err.message);
      // Fallback: cacheDir root with the same uniqueness loop.
      try {
        let fallback: string = safeName;
        let idx: number = 1;
        while (fileIo.accessSync(MediaFileStore.joinPath(this.cacheRoot, fallback)) &&
          idx < MAX_NAME_ATTEMPTS) {
          fallback = MediaFileStore.uniquifyName(fallback, idx);
          idx++;
        }
        const fallbackTarget: string = MediaFileStore.joinPath(this.cacheRoot, fallback);
        this.writeBytes(fallbackTarget, content);
        return fallbackTarget;
      } catch (e2) {
        const err2 = e2 as BusinessError;
        hilog.error(DOMAIN, TAG, 'save incoming fallback failed: %{public}s', err2.message);
        return null;
      }
    }
  }

  /**
   * Downscale one image for sending (max longest edge 512px, JPEG 85) and
   * return the staged outgoing path under filesDir/images/outgoing. The
   * EXIF orientation is baked into the re-encode so receivers render the
   * photo upright regardless of their EXIF support (Android ImageUtils
   * downscaleAndSaveToAppFiles parity). Returns null on decode failure.
   */
  async downscaleImageForSending(sourcePath: string): Promise<string | null> {
    if (this.filesRoot === '') {
      return null;
    }
    let source: image.ImageSource | null = null;
    let pixelMap: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      source = image.createImageSource(sourcePath);
      // EXIF orientation: bake the camera rotation into the outgoing JPEG.
      let degrees: number = 0;
      try {
        const orientation: string =
          source.getImagePropertySync(image.PropertyKey.ORIENTATION);
        degrees = MediaFileStore.exifOrientationToDegrees(orientation);
      } catch (e) {
        degrees = 0;
      }
      const decodingOptions: image.DecodingOptions = { rotate: degrees };
      pixelMap = await source.createPixelMap(decodingOptions);
      const info: image.ImageInfo = await pixelMap.getImageInfo();
      const width: number = info.size.width;
      const height: number = info.size.height;
      if (width <= 0 || height <= 0) {
        return null;
      }
      const scale: number = Math.max(Math.max(width, height) / IMAGE_OUTGOING_MAX_DIM, 1);
      const newWidth: number = Math.max(Math.floor(width / scale), 1);
      const newHeight: number = Math.max(Math.floor(height / scale), 1);
      if (scale > 1) {
        await pixelMap.scale(newWidth / width, newHeight / height);
      }
      packer = image.createImagePacker();
      const packingOptions: image.PackingOption =
        { format: 'image/jpeg', quality: IMAGE_OUTGOING_JPEG_QUALITY };
      const packed: ArrayBuffer = await packer.packToData(pixelMap, packingOptions);
      const dir: string = this.ensureDirectory(this.filesRoot, 'images/outgoing');
      const target: string =
        MediaFileStore.joinPath(dir, 'img_' + Date.now() + '.jpg');
      this.writeBytes(target, new Uint8Array(packed));
      return target;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'downscale image failed: %{public}s', err.message);
      return null;
    } finally {
      if (packer !== null) {
        packer.release();
      }
      if (pixelMap !== null) {
        pixelMap.release();
      }
      if (source !== null) {
        source.release();
      }
    }
  }

  /**
   * Save one outgoing (non-image) file under filesDir/files/outgoing so
   * the local echo bubble keeps a stable sandbox path (T053). Names are
   * sanitized and uniquified like incoming saves; null on failure.
   */
  saveOutgoingFile(fileName: string, content: Uint8Array): string | null {
    if (this.filesRoot === '' || content.length === 0) {
      return null;
    }
    let dir: string = '';
    try {
      dir = this.ensureDirectory(this.filesRoot, 'files/outgoing');
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'create outgoing dir failed: %{public}s', err.message);
      return null;
    }
    const rawBase: string = fileName !== '' ? fileName : 'file';
    const baseName: string = rawBase.replace(FILENAME_SANITIZE_REGEX, '_');
    let safeName: string = baseName.indexOf('.') >= 0 ? baseName : baseName + '.bin';
    let attempt: number = 1;
    try {
      while (fileIo.accessSync(MediaFileStore.joinPath(dir, safeName)) &&
        attempt < MAX_NAME_ATTEMPTS) {
        safeName = MediaFileStore.uniquifyName(safeName, attempt);
        attempt++;
      }
      const target: string = MediaFileStore.joinPath(dir, safeName);
      this.writeBytes(target, content);
      return target;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'save outgoing file failed: %{public}s', err.message);
      return null;
    }
  }

  /**
   * Stage raw picked-file bytes under cacheDir/staging so image decoders
   * and senders always read from a real sandbox file (picker URIs are not
   * guaranteed to be accepted by createImageSource). Null on failure.
   */
  stageTempFile(fileName: string, content: Uint8Array): string | null {
    if (this.cacheRoot === '' || content.length === 0) {
      return null;
    }
    try {
      const dir: string = this.ensureDirectory(this.cacheRoot, 'staging');
      const rawBase: string = fileName !== '' ? fileName : 'file';
      const baseName: string = rawBase.replace(FILENAME_SANITIZE_REGEX, '_');
      const target: string = MediaFileStore.joinPath(dir,
        'stage_' + Date.now() + '_' + baseName);
      this.writeBytes(target, content);
      return target;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'stage temp file failed: %{public}s', err.message);
      return null;
    }
  }

  /** Delete one staging file; missing files and failures are ignored. */
  deleteTempFile(path: string): void {
    if (path === '') {
      return;
    }
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (e) {
      // Staging cleanup is best-effort; the panic sweep removes the rest.
    }
  }

  /**
   * Panic wipe: delete every media directory under filesDir and cacheDir,
   * then the whole cacheDir as a catch-all (Android clearAllMedia parity).
   * Returns true only when every removal succeeded.
   */
  clearAllMedia(): boolean {
    if (this.filesRoot === '' || this.cacheRoot === '') {
      return false;
    }
    let cleared: boolean = true;
    for (let i: number = 0; i < FILES_DIR_SUBDIRS.length; i++) {
      cleared = this.removeDirectory(
        MediaFileStore.joinPath(this.filesRoot, FILES_DIR_SUBDIRS[i])) && cleared;
    }
    for (let i: number = 0; i < CACHE_DIR_SUBDIRS.length; i++) {
      cleared = this.removeDirectory(
        MediaFileStore.joinPath(this.cacheRoot, CACHE_DIR_SUBDIRS[i])) && cleared;
    }
    cleared = this.removeDirectory(this.cacheRoot) && cleared;
    // Recreate the cache root so later saves have their base directory.
    if (!fileIo.accessSync(this.cacheRoot)) {
      try {
        fileIo.mkdirSync(this.cacheRoot, true);
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(DOMAIN, TAG, 'recreate cache dir failed: %{public}s', err.message);
        cleared = false;
      }
    }
    return cleared;
  }

  /**
   * Delete app-owned media referenced only by the removed conversation.
   * Paths are canonicalized ('.'/'..' collapsed) and must stay inside the
   * sandbox roots; files still referenced by retained messages survive
   * (Android deleteConversationMedia parity).
   */
  deleteConversationMedia(deletedPaths: string[], retainedPaths: string[]): void {
    const retained: Set<string> = new Set<string>();
    for (let i: number = 0; i < retainedPaths.length; i++) {
      const normalized: string | null = MediaFileStore.normalizeAbsolutePath(retainedPaths[i]);
      if (normalized !== null) {
        retained.add(normalized);
      }
    }
    const seen: Set<string> = new Set<string>();
    for (let i: number = 0; i < deletedPaths.length; i++) {
      const normalized: string | null = MediaFileStore.normalizeAbsolutePath(deletedPaths[i]);
      if (normalized === null || seen.has(normalized) || retained.has(normalized) ||
        !this.isInsideSandboxRoots(normalized)) {
        continue;
      }
      seen.add(normalized);
      this.deleteFileIfPresent(normalized);
    }
  }

  /**
   * Delete paths proven unreferenced by the conversation database; the
   * same sandbox-root boundary prevents malformed metadata from turning
   * this into arbitrary-file deletion (Android deleteStoredMediaPaths
   * parity).
   */
  deleteStoredMediaPaths(paths: string[]): void {
    this.deleteConversationMedia(paths, []);
  }

  /** "1.5 MB"-style display (Android formatFileSize parity). */
  static formatFileSize(bytes: number): string {
    const units: string[] = ['B', 'KB', 'MB', 'GB'];
    let size: number = bytes;
    let unitIndex: number = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024.0;
      unitIndex++;
    }
    return size.toFixed(1) + ' ' + units[unitIndex];
  }

  /** Image/audio/file bubble classification (Android messageTypeForMime). */
  static messageTypeForMime(mime: string): BitchatMessageType {
    const lower: string = mime.toLowerCase();
    if (lower.startsWith('image/')) {
      return BitchatMessageType.IMAGE;
    }
    if (lower.startsWith('audio/')) {
      return BitchatMessageType.AUDIO;
    }
    return BitchatMessageType.FILE;
  }

  /**
   * EXIF orientation tag to clockwise degrees. Accepts the numeric form
   * ('1'..'8') and the textual form ('Top-left', 'Right-top', ...);
   * mirror-only tags stay unrotated (Android orientationToDegrees parity:
   * 3 -> 180, 5/6 -> 90, 7/8 -> 270, everything else -> 0).
   */
  static exifOrientationToDegrees(orientation: string): number {
    const trimmed: string = orientation.trim();
    if (trimmed === '3' || trimmed === 'Bottom-right') {
      return 180;
    }
    if (trimmed === '5' || trimmed === '6' || trimmed === 'Left-top' ||
      trimmed === 'Right-top') {
      return 90;
    }
    if (trimmed === '7' || trimmed === '8' || trimmed === 'Right-bottom' ||
      trimmed === 'Left-bottom') {
      return 270;
    }
    return 0;
  }

  // ------------------------------------------------------------------
  // Internals
  // ------------------------------------------------------------------

  /** Create root/subDir (recursive) when missing; returns the directory. */
  private ensureDirectory(root: string, subDir: string): string {
    const dir: string = MediaFileStore.joinPath(root, subDir);
    if (!fileIo.accessSync(dir)) {
      fileIo.mkdirSync(dir, true);
    }
    return dir;
  }

  /** Overwrite one file with the exact content bytes. */
  private writeBytes(path: string, content: Uint8Array): void {
    const out: ArrayBuffer = new ArrayBuffer(content.byteLength);
    const view: Uint8Array = new Uint8Array(out);
    view.set(content);
    const file: fileIo.File = fileIo.openSync(path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, out);
    } finally {
      fileIo.closeSync(file);
    }
  }

  /** Remove one directory tree; a missing directory counts as cleared. */
  private removeDirectory(path: string): boolean {
    if (!fileIo.accessSync(path)) {
      return true;
    }
    try {
      fileIo.rmdirSync(path);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'remove media dir failed: %{public}s', err.message);
      return false;
    }
  }

  /** Delete one file when present; directories and misses are no-ops. */
  private deleteFileIfPresent(path: string): void {
    try {
      const stat: fileIo.Stat = fileIo.statSync(path);
      if (!stat.isDirectory()) {
        fileIo.unlinkSync(path);
      }
    } catch (e) {
      // Missing file: nothing to delete (Android runCatching parity).
    }
  }

  /** True when the canonical path stays inside filesDir or cacheDir. */
  private isInsideSandboxRoots(normalizedPath: string): boolean {
    const candidates: string[] = [this.filesRoot, this.cacheRoot];
    for (let i: number = 0; i < candidates.length; i++) {
      const root: string | null = MediaFileStore.normalizeAbsolutePath(candidates[i]);
      if (root === null) {
        continue;
      }
      if (normalizedPath === root || normalizedPath.startsWith(root + '/')) {
        return true;
      }
    }
    return false;
  }

  private static joinPath(base: string, child: string): string {
    return base.endsWith('/') ? base + child : base + '/' + child;
  }

  /** 'name.ext' -> 'name (idx).ext'; no extension -> 'name (idx)'. */
  private static uniquifyName(name: string, idx: number): string {
    const dot: number = name.lastIndexOf('.');
    if (dot > 0) {
      return name.substring(0, dot) + ' (' + idx + ')' + name.substring(dot);
    }
    return name + ' (' + idx + ')';
  }

  private static extensionForMime(lowerMime: string, isImage: boolean): string {
    if (lowerMime === 'image/jpeg' || lowerMime === 'image/jpg') {
      return '.jpg';
    }
    if (lowerMime === 'image/png') {
      return '.png';
    }
    if (lowerMime === 'image/webp') {
      return '.webp';
    }
    if (lowerMime === 'application/pdf') {
      return '.pdf';
    }
    if (lowerMime === 'text/plain') {
      return '.txt';
    }
    return isImage ? '.jpg' : '.bin';
  }

  /**
   * Canonicalize one absolute path ('.' and '..' resolved, empty segments
   * dropped); non-absolute paths are rejected. Stand-in for the Android
   * canonicalFile traversal defense.
   */
  private static normalizeAbsolutePath(path: string): string | null {
    const trimmed: string = path.trim();
    if (!trimmed.startsWith('/')) {
      return null;
    }
    const segments: string[] = trimmed.split('/');
    const stack: string[] = [];
    for (let i: number = 0; i < segments.length; i++) {
      const segment: string = segments[i];
      if (segment === '' || segment === '.') {
        continue;
      }
      if (segment === '..') {
        if (stack.length > 0) {
          stack.pop();
        }
        continue;
      }
      stack.push(segment);
    }
    return '/' + stack.join('/');
  }
}
