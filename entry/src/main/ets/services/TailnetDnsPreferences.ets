import { fileIo } from '@kit.CoreFileKit';
import { AtomicFileStore } from './AtomicFileStore';

interface TailnetDnsPreferenceRecord {
  schemaVersion: number;
  enabled: boolean;
}

// An app-level preference, independent of account stores and existing network preferences.
// DNS policy itself is never persisted here and is always obtained from the active backend.
export class TailnetDnsPreferences {
  private static readonly FILE_NAME: string = 'tailnet-dns-preferences-v1.json';

  static enabled(filesDir: string): boolean {
    try {
      const path: string = `${filesDir}/${TailnetDnsPreferences.FILE_NAME}`;
      if (!fileIo.accessSync(path)) return true;
      if (fileIo.statSync(path).size > 1024) return false;
      const value: TailnetDnsPreferenceRecord = JSON.parse(fileIo.readTextSync(path)) as TailnetDnsPreferenceRecord;
      return value !== null && value.schemaVersion === 1 && value.enabled === true;
    } catch (_error) { return false; }
  }

  static save(filesDir: string, enabled: boolean): boolean {
    if (filesDir.trim().length === 0) return false;
    const path: string = `${filesDir}/${TailnetDnsPreferences.FILE_NAME}`;
    const record: TailnetDnsPreferenceRecord = { schemaVersion: 1, enabled: enabled };
    return AtomicFileStore.writeAtomic(path, JSON.stringify(record), {
      owner: 'tailnet-dns',
      fsync: true
    });
  }
}
