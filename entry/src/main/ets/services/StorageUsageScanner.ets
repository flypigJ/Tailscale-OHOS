import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';

export interface StorageUsage {
  appData: number;
  received: number;
  temporary: number;
}

/** Serial asynchronous IO keeps directory traversal off the UI event loop. */
export class StorageUsageScanner {
  static async directorySize(root: string, isCurrent: () => boolean): Promise<number> {
    const pending: string[] = [root];
    let bytes: number = 0;
    while (pending.length > 0 && isCurrent()) {
      const path: string = pending.pop()!;
      try {
        const stat: fileIo.Stat = await fileIo.lstat(path);
        if (!isCurrent()) break;
        if (stat.isFile()) {
          bytes += Math.max(0, stat.size);
        } else if (stat.isDirectory()) {
          const names: string[] = await fileIo.listFile(path);
          if (!isCurrent()) break;
          for (const name of names) pending.push(`${path}/${name}`);
        }
        // Do not follow symlinks out of the app's storage or into a cycle.
      } catch (error) {
        // Only a concurrently removed file can be safely omitted from a complete total.
        const failure: BusinessError = error as BusinessError;
        if (failure.code !== 13900002) throw new Error(`storage_scan_io_${failure.code}`);
      }
    }
    return bytes;
  }

  static async measure(filesDir: string, cacheDir: string, receivedNames: string[],
    isCurrent: () => boolean): Promise<StorageUsage> {
    const result: StorageUsage = { appData: 0, received: 0, temporary: 0 };
    const names: string[] = await fileIo.listFile(filesDir);
    for (const name of names) {
      if (!isCurrent()) return result;
      const bytes: number = await StorageUsageScanner.directorySize(`${filesDir}/${name}`, isCurrent);
      if (receivedNames.includes(name)) result.received += bytes;
      else result.appData += bytes;
    }
    if (isCurrent()) result.temporary = await StorageUsageScanner.directorySize(cacheDir, isCurrent);
    return result;
  }
}
