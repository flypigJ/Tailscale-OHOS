export interface TaildropContentFile {
  name: string;
  size: number;
}

export interface TaildropContentCacheEntry extends TaildropContentFile {
  requestId: number;
  path: string;
}

export interface TaildropContentHistoryRecord {
  requestId: number;
  direction: string;
  state: string;
  reason: string;
  targetKey: string;
  targetName: string;
  fileName: string;
  fileCount: number;
  totalBytes: number;
  previewPath: string;
  completedAtMs: number;
}

export interface TaildropContentHistory {
  records?: TaildropContentHistoryRecord[];
}

/** M6B owner for read-only Taildrop previews, history, cache, and restart recovery. */
export class TaildropContentGateway {
  private recoveryGeneration: number = 0;

  beginRecovery(): number {
    this.recoveryGeneration++;
    return this.recoveryGeneration;
  }

  isCurrentRecovery(generation: number): boolean {
    return generation === this.recoveryGeneration;
  }

  parseSnapshot<T>(content: string): T | undefined {
    try {
      return JSON.parse(content) as T;
    } catch (_error) {
      return undefined;
    }
  }

  loadHistory(content: string, limit: number,
    isValid: (record: TaildropContentHistoryRecord) => boolean): TaildropContentHistoryRecord[] | undefined {
    const persisted: TaildropContentHistory | undefined = this.parseSnapshot<TaildropContentHistory>(content);
    if (persisted === undefined || !Array.isArray(persisted.records)) {
      return undefined;
    }
    return persisted.records.filter(isValid).map((record: TaildropContentHistoryRecord): TaildropContentHistoryRecord => {
      if (typeof record.previewPath !== 'string') {
        record.previewPath = '';
      }
      return record;
    }).slice(0, limit);
  }

  previewUri(path: string, exists: (path: string) => boolean, toUri: (path: string) => string): string {
    if (path.length === 0) {
      return '';
    }
    try {
      return exists(path) ? toUri(path) : '';
    } catch (_error) {
      return '';
    }
  }

  restoreCachedFiles(cachedFiles: TaildropContentCacheEntry[], waitingFiles: TaildropContentFile[],
    isAvailable: (cached: TaildropContentCacheEntry) => boolean): TaildropContentCacheEntry[] {
    return cachedFiles.filter((cached: TaildropContentCacheEntry) => waitingFiles.some((file: TaildropContentFile) =>
      file.name === cached.name && file.size === cached.size) && isAvailable(cached));
  }
}
