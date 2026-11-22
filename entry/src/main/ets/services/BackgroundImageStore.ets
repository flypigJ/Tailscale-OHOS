import { fileIo, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';

/** Owns imported copies only. Picker originals and legacy saved URIs stay outside this store. */
export class BackgroundImageStore {
  private static readonly DIRECTORY: string = 'ui-backgrounds-v1';
  private static readonly MAX_BYTES: number = 64 * 1024 * 1024;
  private static readonly MAX_PIXELS: number = 100000000;
  private static nextCandidate: number = 0;

  static async importImage(filesDir: string, uri: string): Promise<string> {
    const directory: string = BackgroundImageStore.directory(filesDir);
    let sourceFile: fileIo.File | undefined = undefined;
    let imageSource: image.ImageSource | undefined = undefined;
    let pixelMap: image.PixelMap | undefined = undefined;
    let candidate: string = '';
    let completed: boolean = false;
    try {
      sourceFile = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      const sourceStat: fileIo.Stat = await fileIo.stat(sourceFile.fd);
      if (!sourceStat.isFile() || !Number.isFinite(sourceStat.size) || sourceStat.size <= 0 ||
        sourceStat.size > BackgroundImageStore.MAX_BYTES) {
        throw new Error('background_image_size_invalid');
      }
      imageSource = image.createImageSource(sourceFile.fd);
      if (imageSource === undefined) {
        throw new Error('background_image_invalid');
      }
      const info: image.ImageInfo = await imageSource.getImageInfo();
      if (!Number.isInteger(info.size.width) || !Number.isInteger(info.size.height) ||
        info.size.width <= 0 || info.size.height <= 0 ||
        info.size.width * info.size.height > BackgroundImageStore.MAX_PIXELS) {
        throw new Error('background_image_dimensions_invalid');
      }
      // Decode a small frame as well as reading the header, without allocating the full image.
      const scale: number = Math.min(1, 64 / Math.max(info.size.width, info.size.height));
      pixelMap = await imageSource.createPixelMap({
        index: 0,
        desiredSize: {
          width: Math.max(1, Math.round(info.size.width * scale)),
          height: Math.max(1, Math.round(info.size.height * scale))
        }
      });
      if (!fileIo.accessSync(directory)) {
        fileIo.mkdirSync(directory, true);
      }
      candidate = BackgroundImageStore.allocateCandidate(directory);
      await fileIo.copyFile(sourceFile.fd, candidate);
      const copiedStat: fileIo.Stat = await fileIo.stat(candidate);
      if (!copiedStat.isFile() || copiedStat.size !== sourceStat.size) {
        throw new Error('background_image_copy_incomplete');
      }
      const managedUri: string = fileUri.getUriFromPath(candidate);
      completed = true;
      return managedUri;
    } finally {
      if (pixelMap !== undefined) {
        try { await pixelMap.release(); } catch (_error) {}
      }
      if (imageSource !== undefined) {
        try { await imageSource.release(); } catch (_error) {}
      }
      if (sourceFile !== undefined) {
        try { fileIo.closeSync(sourceFile); } catch (_error) {}
      }
      if (!completed && candidate.length > 0) {
        try { fileIo.unlinkSync(candidate); } catch (_error) {}
      }
    }
  }

  static isManaged(filesDir: string, uri: string): boolean {
    return BackgroundImageStore.managedPath(filesDir, uri).length > 0;
  }

  static removeManaged(filesDir: string, uri: string): void {
    const path: string = BackgroundImageStore.managedPath(filesDir, uri);
    if (path.length > 0) {
      try { fileIo.unlinkSync(path); } catch (_error) {}
    }
  }

  private static directory(filesDir: string): string {
    const root: string = filesDir.replace(/\/+$/, '');
    if (!root.startsWith('/') || root.length < 2 || root.includes('\\') || root.includes('\u0000') ||
      root.split('/').some((part: string) => part === '.' || part === '..')) {
      throw new Error('background_image_directory_invalid');
    }
    return `${root}/${BackgroundImageStore.DIRECTORY}`;
  }

  private static allocateCandidate(directory: string): string {
    for (let attempt: number = 0; attempt < 1000; attempt++) {
      BackgroundImageStore.nextCandidate++;
      const name: string = `background-${Date.now().toString(36)}-${BackgroundImageStore.nextCandidate.toString(36)}.img`;
      const path: string = `${directory}/${name}`;
      if (!fileIo.accessSync(path)) {
        return path;
      }
    }
    throw new Error('background_image_candidate_unavailable');
  }

  private static managedPath(filesDir: string, uri: string): string {
    try {
      if (!uri.startsWith('file://')) return '';
      const path: string = new fileUri.FileUri(uri).path;
      const prefix: string = `${BackgroundImageStore.directory(filesDir)}/`;
      if (!path.startsWith(prefix) || uri !== fileUri.getUriFromPath(path)) return '';
      const name: string = path.slice(prefix.length);
      return /^background-[0-9a-z]+-[0-9a-z]+\.img$/.test(name) ? path : '';
    } catch (_error) {
      return '';
    }
  }
}
