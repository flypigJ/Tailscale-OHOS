import { AccountProfiles } from './AccountProfiles';
import { AtomicFileStore, AtomicWriteOptions } from './AtomicFileStore';
import { ControlServerConfig } from './ControlServerConfig';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { media } from '@kit.MediaKit';
import { TaildriveEntry, isImageEntry, isVideoEntry } from '@tailscale/common';

const THUMBNAIL_EDGE_PX: number = 160;
const THUMBNAIL_QUALITY: number = 76;
const ORIGIN_FILE_NAME: string = '.origin.json';
const ORIGIN_SCHEMA_VERSION: number = 1;
const MAX_ORIGIN_BYTES: number = 4096;
const VIDEO_METADATA_TIMEOUT_MS: number = 5000;
const VIDEO_RELEASE_TIMEOUT_MS: number = 1500;
const UNSAFE_PREVIEW_NAME_CHARS: RegExp =
  /[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g;

interface PersistedPreviewOrigin {
  schemaVersion?: number;
  remotePath?: string;
  size?: number;
  modifiedAtMs?: number;
  etag?: string;
}

export interface TaildriveCachedPreview {
  path: string;
  thumbnailPath: string;
}

/** Owns private remote-file preview downloads and their derived thumbnails. */
export class TaildrivePreviewGateway {
  private readonly thumbnailRequests: Map<string, Promise<string>> = new Map<string, Promise<string>>();

  root(context: common.Context): string {
    const controlURL: string = ControlServerConfig.load(context.filesDir).controlURL;
    return `${AccountProfiles.cacheRoot(context.filesDir, context.cacheDir, controlURL,
      AccountProfiles.current(context.filesDir, controlURL).activeId)}/taildrive-previews`;
  }

  cachedPreview(context: common.Context, entry: TaildriveEntry): TaildriveCachedPreview | undefined {
    const path: string = this.previewPath(context, entry);
    try {
      const stat: fileIo.Stat = fileIo.statSync(path);
      if (!stat.isFile() || (entry.size > 0 && stat.size !== entry.size) ||
        !this.isOriginFreshForEntry(path, entry)) {
        return undefined;
      }
      const thumbnailPath: string = this.thumbnailPath(path);
      return {
        path: path,
        thumbnailPath: this.validFile(thumbnailPath) ? thumbnailPath : ''
      };
    } catch (_error) {
      return undefined;
    }
  }

  async cachedPreviewAsync(context: common.Context, entry: TaildriveEntry): Promise<TaildriveCachedPreview | undefined> {
    const path: string = this.previewPath(context, entry);
    try {
      const stat: fileIo.Stat = await fileIo.stat(path);
      if (!stat.isFile() || (entry.size > 0 && stat.size !== entry.size) ||
        !await this.isOriginFreshForEntryAsync(path, entry)) {
        return undefined;
      }
      const thumbnailPath: string = this.thumbnailPath(path);
      let thumbnailValid: boolean = false;
      try {
        const thumbnailStat: fileIo.Stat = await fileIo.stat(thumbnailPath);
        thumbnailValid = thumbnailStat.isFile() && thumbnailStat.size > 0;
      } catch (_error) {}
      return { path: path, thumbnailPath: thumbnailValid ? thumbnailPath : '' };
    } catch (_error) {
      return undefined;
    }
  }

  prepareDownload(context: common.Context, entry: TaildriveEntry): string {
    const path: string = this.previewPath(context, entry);
    const thumbnailPath: string = this.thumbnailPath(path);
    this.prepareDestination(path);
    this.writeBucketOrigin(path, entry);
    this.removeIfPresent(thumbnailPath);
    return path;
  }

  purgeProtectedPreviews(context: common.Context, protectedFolderPaths: string[]): void {
    if (!Array.isArray(protectedFolderPaths) || protectedFolderPaths.length === 0) {
      return;
    }
    const normalizedFolders: string[] = [];
    protectedFolderPaths.forEach((rawPath: string) => {
      if (typeof rawPath !== 'string') {
        return;
      }
      const normalized: string = this.normalizeRemotePath(rawPath);
      if (normalized.length > 1 && normalized.startsWith('/') && !normalizedFolders.includes(normalized)) {
        normalizedFolders.push(normalized);
      }
    });
    if (normalizedFolders.length === 0) {
      return;
    }
    let previewRoot: string = '';
    try {
      previewRoot = this.root(context);
    } catch (_error) {
      return;
    }
    if (previewRoot.length === 0) {
      return;
    }
    try {
      if (typeof fileIo.accessSync === 'function' && !fileIo.accessSync(previewRoot)) {
        return;
      }
    } catch (_error) {
      return;
    }
    let buckets: string[] = [];
    try {
      buckets = fileIo.listFileSync(previewRoot);
    } catch (_error) {
      return;
    }
    buckets.forEach((bucketName: string) => {
      if (bucketName.length === 0 || bucketName === '.' || bucketName === '..' || bucketName.includes('/')) {
        return;
      }
      const bucketPath: string = `${previewRoot}/${bucketName}`;
      try {
        const stat: fileIo.Stat = typeof fileIo.lstatSync === 'function' ?
          fileIo.lstatSync(bucketPath) : fileIo.statSync(bucketPath);
        if (typeof stat.isSymbolicLink === 'function' && stat.isSymbolicLink()) {
          fileIo.unlinkSync(bucketPath);
          return;
        }
        if (!stat.isDirectory()) {
          if (bucketName.endsWith('.tmp')) {
            fileIo.unlinkSync(bucketPath);
          }
          return;
        }
      } catch (_statError) {
        return;
      }
      if (this.shouldPurgeBucket(bucketPath, normalizedFolders)) {
        this.purgeBucketDirectory(bucketPath);
      }
    });
  }

  async createThumbnail(context: common.Context, entry: TaildriveEntry, sourcePath: string): Promise<string> {
    const existing: Promise<string> | undefined = this.thumbnailRequests.get(sourcePath);
    if (existing !== undefined) return existing;
    const request: Promise<string> = this.createThumbnailFile(entry, sourcePath);
    this.thumbnailRequests.set(sourcePath, request);
    try {
      return await request;
    } finally {
      this.thumbnailRequests.delete(sourcePath);
    }
  }

  private async createThumbnailFile(entry: TaildriveEntry, sourcePath: string): Promise<string> {
    if (!this.isImage(entry) && !this.isVideo(entry)) {
      return '';
    }
    const destination: string = this.thumbnailPath(sourcePath);
    if (this.validFile(destination)) {
      return destination;
    }
    try {
      return this.isImage(entry) ?
        await this.createImageThumbnail(sourcePath, destination) :
        await this.createVideoThumbnail(sourcePath, destination);
    } catch (_error) {
      this.removeIfPresent(destination);
      return '';
    }
  }

  private previewPath(context: common.Context, entry: TaildriveEntry): string {
    // Keep cache keys in directories so the opened file retains its remote name.
    return `${this.root(context)}/${this.cacheKey(entry)}/${this.safeName(entry.name)}`;
  }

  private thumbnailPath(sourcePath: string): string {
    return `${sourcePath}.thumb.jpg`;
  }

  private cacheKey(entry: TaildriveEntry): string {
    const value: string = `${entry.path}\n${entry.name}`;
    let hash: number = 2166136261;
    for (let index: number = 0; index < value.length; index++) {
      hash ^= value.charCodeAt(index);
      hash = Math.imul(hash, 16777619);
    }
    return (hash >>> 0).toString(16);
  }

  private safeName(name: string): string {
    const stripped: string = name.replace(UNSAFE_PREVIEW_NAME_CHARS, '');
    const slash: number = Math.max(stripped.lastIndexOf('/'), stripped.lastIndexOf('\\'));
    const base: string = slash >= 0 ? stripped.substring(slash + 1) : stripped;
    const value: string = base.replace(/[\\/:*?"<>|]/g, '_').trim();
    return value.length > 0 && value !== '.' && value !== '..' ? value : 'remote-file';
  }

  private normalizeRemotePath(remotePath: string): string {
    const normalized: string = remotePath.trim().replace(/\/+$/, '');
    return normalized.length > 0 ? normalized : '/';
  }

  private writeBucketOrigin(filePath: string, entry: TaildriveEntry): void {
    const separator: number = filePath.lastIndexOf('/');
    if (separator <= 0) {
      return;
    }
    const bucketDir: string = filePath.substring(0, separator);
    const payload: PersistedPreviewOrigin = {
      schemaVersion: ORIGIN_SCHEMA_VERSION,
      remotePath: this.normalizeRemotePath(entry.path),
      size: Number.isFinite(entry.size) && entry.size >= 0 ? entry.size : 0,
      modifiedAtMs: Number.isFinite(entry.modifiedAtMs) && entry.modifiedAtMs > 0 ? entry.modifiedAtMs : 0,
      etag: typeof entry.etag === 'string' ? entry.etag : ''
    };
    const options: AtomicWriteOptions = {
      owner: 'td-origin',
      fsync: false,
      maxBytes: MAX_ORIGIN_BYTES
    };
    AtomicFileStore.writeAtomic(`${bucketDir}/${ORIGIN_FILE_NAME}`, JSON.stringify(payload), options);
  }

  private validateOriginTextForEntry(raw: string | undefined, entry: TaildriveEntry): boolean {
    if (raw === undefined || raw.trim().length === 0) {
      return false;
    }
    try {
      const parsed: PersistedPreviewOrigin = JSON.parse(raw) as PersistedPreviewOrigin;
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed) ||
        parsed.schemaVersion !== ORIGIN_SCHEMA_VERSION ||
        typeof parsed.remotePath !== 'string' || !parsed.remotePath.startsWith('/')) {
        return false;
      }
      if (this.normalizeRemotePath(parsed.remotePath) !== this.normalizeRemotePath(entry.path)) {
        return false;
      }
      if (typeof entry.etag === 'string' && entry.etag.length > 0 &&
        typeof parsed.etag === 'string' && parsed.etag.length > 0 &&
        parsed.etag !== entry.etag) {
        return false;
      }
      if (Number.isFinite(entry.modifiedAtMs) && entry.modifiedAtMs > 0 &&
        typeof parsed.modifiedAtMs === 'number' && parsed.modifiedAtMs > 0 &&
        parsed.modifiedAtMs !== entry.modifiedAtMs) {
        return false;
      }
      return true;
    } catch (_error) {
      return false;
    }
  }

  private isOriginFreshForEntry(filePath: string, entry: TaildriveEntry): boolean {
    const separator: number = filePath.lastIndexOf('/');
    if (separator <= 0) {
      return false;
    }
    const originPath: string = `${filePath.substring(0, separator)}/${ORIGIN_FILE_NAME}`;
    const raw: string | undefined = AtomicFileStore.readTextBounded(originPath, MAX_ORIGIN_BYTES);
    return this.validateOriginTextForEntry(raw, entry);
  }

  private async isOriginFreshForEntryAsync(filePath: string, entry: TaildriveEntry): Promise<boolean> {
    const separator: number = filePath.lastIndexOf('/');
    if (separator <= 0) {
      return false;
    }
    const originPath: string = `${filePath.substring(0, separator)}/${ORIGIN_FILE_NAME}`;
    if (typeof fileIo.stat === 'function' && typeof fileIo.readText === 'function') {
      try {
        const originStat: fileIo.Stat = await fileIo.stat(originPath);
        if (!originStat.isFile() || originStat.size <= 0 || originStat.size > MAX_ORIGIN_BYTES) {
          return false;
        }
        const raw: string = await fileIo.readText(originPath);
        return this.validateOriginTextForEntry(raw, entry);
      } catch (_error) {
        return false;
      }
    }
    return this.isOriginFreshForEntry(filePath, entry);
  }

  private shouldPurgeBucket(bucketPath: string, normalizedFolders: string[]): boolean {
    const originPathFile: string = `${bucketPath}/${ORIGIN_FILE_NAME}`;
    const raw: string | undefined = AtomicFileStore.readTextBounded(originPathFile, MAX_ORIGIN_BYTES);
    if (raw === undefined || raw.trim().length === 0) {
      return true;
    }
    try {
      const parsed: PersistedPreviewOrigin = JSON.parse(raw) as PersistedPreviewOrigin;
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed) ||
        parsed.schemaVersion !== ORIGIN_SCHEMA_VERSION ||
        typeof parsed.remotePath !== 'string' || !parsed.remotePath.startsWith('/')) {
        return true;
      }
      const originRemotePath: string = this.normalizeRemotePath(parsed.remotePath);
      return normalizedFolders.some((folder: string) =>
        originRemotePath === folder || originRemotePath.startsWith(`${folder}/`));
    } catch (_error) {
      return true;
    }
  }

  private purgeBucketDirectory(bucketPath: string): void {
    try {
      const children: string[] = fileIo.listFileSync(bucketPath);
      children.forEach((childName: string) => {
        if (childName.length === 0 || childName === '.' || childName === '..' || childName.includes('/')) {
          return;
        }
        const childPath: string = `${bucketPath}/${childName}`;
        try {
          const stat: fileIo.Stat = typeof fileIo.lstatSync === 'function' ?
            fileIo.lstatSync(childPath) : fileIo.statSync(childPath);
          if (typeof stat.isSymbolicLink === 'function' && stat.isSymbolicLink()) {
            fileIo.unlinkSync(childPath);
          } else if (stat.isDirectory()) {
            this.purgeBucketDirectory(childPath);
          } else {
            fileIo.unlinkSync(childPath);
          }
        } catch (_childError) {
        }
      });
    } catch (_listError) {
    }
    try {
      fileIo.rmdirSync(bucketPath);
    } catch (_rmdirError) {
    }
  }

  private validFile(path: string): boolean {
    try {
      const stat: fileIo.Stat = fileIo.statSync(path);
      return stat.isFile() && stat.size > 0;
    } catch (_error) {
      return false;
    }
  }

  private removeIfPresent(path: string): void {
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (_error) {
    }
  }

  private isImage(entry: TaildriveEntry): boolean {
    return isImageEntry(entry.name, entry.contentType);
  }

  private isVideo(entry: TaildriveEntry): boolean {
    return isVideoEntry(entry.name, entry.contentType);
  }

  private prepareDestination(destination: string): void {
    const separator: number = destination.lastIndexOf('/');
    if (separator > 0) {
      const parent: string = destination.substring(0, separator);
      if (!fileIo.accessSync(parent)) {
        fileIo.mkdirSync(parent, true);
      }
    }
    this.removeIfPresent(destination);
  }

  private async writeThumbnail(pixelMap: image.PixelMap, destination: string): Promise<string> {
    let packer: image.ImagePacker | undefined = undefined;
    let destinationFile: fileIo.File | undefined = undefined;
    try {
      this.prepareDestination(destination);
      packer = image.createImagePacker();
      const packed: ArrayBuffer = await packer.packToData(pixelMap, {
        format: 'image/jpeg',
        quality: THUMBNAIL_QUALITY
      });
      if (packed.byteLength <= 0) {
        return '';
      }
      destinationFile = fileIo.openSync(destination,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      const written: number = fileIo.writeSync(destinationFile.fd, packed);
      fileIo.closeSync(destinationFile);
      destinationFile = undefined;
      return written === packed.byteLength && this.validFile(destination) ? destination : '';
    } catch (_error) {
      this.removeIfPresent(destination);
      return '';
    } finally {
      if (destinationFile !== undefined) {
        try {
          fileIo.closeSync(destinationFile);
        } catch (_error) {
        }
      }
      if (packer !== undefined) {
        try {
          await packer.release();
        } catch (_error) {
        }
      }
    }
  }

  private async createImageThumbnail(sourcePath: string, destination: string): Promise<string> {
    let sourceFile: fileIo.File | undefined = undefined;
    let imageSource: image.ImageSource | undefined = undefined;
    let pixelMap: image.PixelMap | undefined = undefined;
    try {
      sourceFile = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
      imageSource = image.createImageSource(sourceFile.fd);
      const info: image.ImageInfo = await imageSource.getImageInfo();
      if (info.size.width <= 0 || info.size.height <= 0) {
        return '';
      }
      let width: number = THUMBNAIL_EDGE_PX;
      let height: number = THUMBNAIL_EDGE_PX;
      if (info.size.width >= info.size.height) {
        height = Math.max(1, Math.round(THUMBNAIL_EDGE_PX * info.size.height / info.size.width));
      } else {
        width = Math.max(1, Math.round(THUMBNAIL_EDGE_PX * info.size.width / info.size.height));
      }
      pixelMap = await imageSource.createPixelMap({
        index: 0,
        desiredSize: { width: width, height: height }
      });
      return await this.writeThumbnail(pixelMap, destination);
    } catch (_error) {
      this.removeIfPresent(destination);
      return '';
    } finally {
      if (pixelMap !== undefined) {
        try {
          await pixelMap.release();
        } catch (_error) {
        }
      }
      if (imageSource !== undefined) {
        try {
          await imageSource.release();
        } catch (_error) {
        }
      }
      if (sourceFile !== undefined) {
        try {
          fileIo.closeSync(sourceFile);
        } catch (_error) {
        }
      }
    }
  }

  private withTimeout<T>(operation: Promise<T>, timeoutMs: number, label: string): Promise<T> {
    if (typeof setTimeout !== 'function') {
      return operation;
    }
    operation.catch((): void => {});
    let timerId: number = -1;
    const timeoutPromise: Promise<T> = new Promise<T>(
      (_resolve: (value: T) => void, reject: (reason?: Error) => void) => {
        timerId = setTimeout((): void => {
          timerId = -1;
          reject(new Error(`${label}_timeout`));
        }, timeoutMs);
      });
    return Promise.race<T>([operation, timeoutPromise]).finally((): void => {
      if (timerId >= 0 && typeof clearTimeout === 'function') {
        clearTimeout(timerId);
        timerId = -1;
      }
    });
  }

  private async createVideoThumbnail(sourcePath: string, destination: string): Promise<string> {
    let sourceFile: fileIo.File | undefined = undefined;
    let extractor: media.AVMetadataExtractor | undefined = undefined;
    let pixelMap: image.PixelMap | undefined = undefined;
    try {
      sourceFile = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(sourceFile.fd);
      extractor = await this.withTimeout<media.AVMetadataExtractor>(
        media.createAVMetadataExtractor(), VIDEO_METADATA_TIMEOUT_MS, 'create_extractor');
      extractor.fdSrc = { fd: sourceFile.fd, offset: 0, length: stat.size };
      const metadata: media.AVMetadata = await this.withTimeout<media.AVMetadata>(
        extractor.fetchMetadata(), VIDEO_METADATA_TIMEOUT_MS, 'fetch_metadata');
      const sourceWidth: number = metadata.videoWidth === undefined ? 0 : Number(metadata.videoWidth);
      const sourceHeight: number = metadata.videoHeight === undefined ? 0 : Number(metadata.videoHeight);
      let width: number = THUMBNAIL_EDGE_PX;
      let height: number = THUMBNAIL_EDGE_PX;
      if (sourceWidth > 0 && sourceHeight > 0 && Number.isFinite(sourceWidth) && Number.isFinite(sourceHeight)) {
        if (sourceWidth >= sourceHeight) {
          height = Math.max(1, Math.round(THUMBNAIL_EDGE_PX * sourceHeight / sourceWidth));
        } else {
          width = Math.max(1, Math.round(THUMBNAIL_EDGE_PX * sourceWidth / sourceHeight));
        }
      }
      const durationMs: number = metadata.duration === undefined ? 0 : Number(metadata.duration);
      const frameTimeUs: number = Number.isFinite(durationMs) && durationMs > 0 ?
        Math.min(1000000, Math.round(durationMs * 250)) : 0;
      pixelMap = await this.withTimeout<image.PixelMap>(
        extractor.fetchFrameByTime(
          frameTimeUs,
          media.AVImageQueryOptions.AV_IMAGE_QUERY_CLOSEST_SYNC,
          { width: width, height: height }),
        VIDEO_METADATA_TIMEOUT_MS,
        'fetch_frame');
      return await this.writeThumbnail(pixelMap, destination);
    } catch (_error) {
      this.removeIfPresent(destination);
      return '';
    } finally {
      if (pixelMap !== undefined) {
        try {
          await this.withTimeout<void>(pixelMap.release(), VIDEO_RELEASE_TIMEOUT_MS, 'release_pixelmap');
        } catch (_error) {
        }
      }
      if (extractor !== undefined) {
        try {
          await this.withTimeout<void>(extractor.release(), VIDEO_RELEASE_TIMEOUT_MS, 'release_extractor');
        } catch (_error) {
        }
      }
      if (sourceFile !== undefined) {
        try {
          fileIo.closeSync(sourceFile);
        } catch (_error) {
        }
      }
    }
  }
}
