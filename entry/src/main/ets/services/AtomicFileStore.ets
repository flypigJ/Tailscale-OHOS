import { fileIo } from '@kit.CoreFileKit';

export interface AtomicWriteOptions {
  owner?: string;
  fsync?: boolean;
  allowPartialWrite?: boolean;
  maxBytes?: number;
}

/**
 * Unified atomic text persistence over HarmonyOS CoreFileKit.
 * Guarantees UTF-8 byte-accurate writes, optional fsync durability,
 * descriptor closure prior to rename, and orphan temp cleanup on failure.
 */
export class AtomicFileStore {
  private static sequence: number = 0;

  static utf8ByteLength(text: string): number {
    let bytes: number = 0;
    for (let index: number = 0; index < text.length; index++) {
      const code: number = text.charCodeAt(index);
      if (code <= 0x7F) {
        bytes += 1;
      } else if (code <= 0x7FF) {
        bytes += 2;
      } else if (code >= 0xD800 && code <= 0xDBFF) {
        if (index + 1 < text.length) {
          const low: number = text.charCodeAt(index + 1);
          if (low >= 0xDC00 && low <= 0xDFFF) {
            bytes += 4;
            index++;
            continue;
          }
        }
        bytes += 3;
      } else if (code >= 0xDC00 && code <= 0xDFFF) {
        bytes += 3;
      } else {
        bytes += 3;
      }
    }
    return bytes;
  }

  static encodeUtf8(text: string): Uint8Array {
    const out: Uint8Array = new Uint8Array(AtomicFileStore.utf8ByteLength(text));
    let pos: number = 0;
    for (let index: number = 0; index < text.length; index++) {
      const code: number = text.charCodeAt(index);
      if (code <= 0x7F) {
        out[pos++] = code;
      } else if (code <= 0x7FF) {
        out[pos++] = 0xC0 | (code >> 6);
        out[pos++] = 0x80 | (code & 0x3F);
      } else if (code >= 0xD800 && code <= 0xDBFF) {
        if (index + 1 < text.length) {
          const low: number = text.charCodeAt(index + 1);
          if (low >= 0xDC00 && low <= 0xDFFF) {
            const codePoint: number = 0x10000 + (((code - 0xD800) << 10) | (low - 0xDC00));
            out[pos++] = 0xF0 | (codePoint >> 18);
            out[pos++] = 0x80 | ((codePoint >> 12) & 0x3F);
            out[pos++] = 0x80 | ((codePoint >> 6) & 0x3F);
            out[pos++] = 0x80 | (codePoint & 0x3F);
            index++;
            continue;
          }
        }
        out[pos++] = 0xEF;
        out[pos++] = 0xBF;
        out[pos++] = 0xBD;
      } else if (code >= 0xDC00 && code <= 0xDFFF) {
        out[pos++] = 0xEF;
        out[pos++] = 0xBF;
        out[pos++] = 0xBD;
      } else {
        out[pos++] = 0xE0 | (code >> 12);
        out[pos++] = 0x80 | ((code >> 6) & 0x3F);
        out[pos++] = 0x80 | (code & 0x3F);
      }
    }
    return out;
  }

  static decodeUtf8(bytes: Uint8Array): string {
    const parts: string[] = [];
    let chunk: string = '';
    let index: number = 0;
    const length: number = bytes.length;
    while (index < length) {
      const b0: number = bytes[index];
      if (b0 <= 0x7F) {
        chunk += String.fromCharCode(b0);
        index += 1;
      } else if ((b0 & 0xE0) === 0xC0 && b0 >= 0xC2 && index + 1 < length) {
        const b1: number = bytes[index + 1];
        if ((b1 & 0xC0) === 0x80) {
          chunk += String.fromCharCode(((b0 & 0x1F) << 6) | (b1 & 0x3F));
          index += 2;
        } else {
          chunk += '\uFFFD';
          index += 1;
        }
      } else if ((b0 & 0xF0) === 0xE0 && index + 2 < length) {
        const b1: number = bytes[index + 1];
        const b2: number = bytes[index + 2];
        if ((b1 & 0xC0) === 0x80 && (b2 & 0xC0) === 0x80) {
          const codePoint: number = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F);
          if (codePoint >= 0x800 && (codePoint < 0xD800 || codePoint > 0xDFFF)) {
            chunk += String.fromCharCode(codePoint);
            index += 3;
          } else {
            chunk += '\uFFFD';
            index += 1;
          }
        } else {
          chunk += '\uFFFD';
          index += 1;
        }
      } else if ((b0 & 0xF8) === 0xF0 && b0 <= 0xF4 && index + 3 < length) {
        const b1: number = bytes[index + 1];
        const b2: number = bytes[index + 2];
        const b3: number = bytes[index + 3];
        if ((b1 & 0xC0) === 0x80 && (b2 & 0xC0) === 0x80 && (b3 & 0xC0) === 0x80) {
          const codePoint: number = ((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12) |
            ((b2 & 0x3F) << 6) | (b3 & 0x3F);
          if (codePoint >= 0x10000 && codePoint <= 0x10FFFF) {
            const adjusted: number = codePoint - 0x10000;
            chunk += String.fromCharCode(0xD800 + (adjusted >> 10), 0xDC00 + (adjusted & 0x3FF));
            index += 4;
          } else {
            chunk += '\uFFFD';
            index += 1;
          }
        } else {
          chunk += '\uFFFD';
          index += 1;
        }
      } else {
        chunk += '\uFFFD';
        index += 1;
      }
      if (chunk.length >= 4096) {
        parts.push(chunk);
        chunk = '';
      }
    }
    if (chunk.length > 0) {
      parts.push(chunk);
    }
    return parts.join('');
  }

  static writeAtomicOrThrow(targetPath: string, content: string, options?: AtomicWriteOptions): void {
    if (targetPath.trim().length === 0) {
      throw new Error('atomic_invalid_path');
    }
    const utf8Bytes: Uint8Array = AtomicFileStore.encodeUtf8(content);
    if (options?.maxBytes !== undefined) {
      if (!Number.isSafeInteger(options.maxBytes) || options.maxBytes < 0 ||
        utf8Bytes.length > options.maxBytes) {
        throw new Error('atomic_file_limit');
      }
    }
    const tempPath: string = AtomicFileStore.nextTempPath(targetPath, options?.owner);
    let file: fileIo.File | undefined = undefined;
    let tempCreated: boolean = false;
    let committed: boolean = false;
    try {
      file = fileIo.openSync(tempPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      tempCreated = true;
      if (options?.allowPartialWrite === true) {
        let offset: number = 0;
        while (offset < utf8Bytes.length) {
          let count: number = 0;
          if (offset === 0) {
            count = fileIo.writeSync(file.fd, content);
          } else {
            const tail: Uint8Array = utf8Bytes.subarray(offset);
            if ((tail[0] & 0xC0) !== 0x80) {
              count = fileIo.writeSync(file.fd, AtomicFileStore.decodeUtf8(tail));
            } else {
              const rawChunk: ArrayBuffer = new ArrayBuffer(tail.length);
              new Uint8Array(rawChunk).set(tail);
              count = fileIo.writeSync(file.fd, rawChunk);
            }
          }
          const remaining: number = utf8Bytes.length - offset;
          if (!Number.isSafeInteger(count) || count <= 0 || count > remaining) {
            throw new Error('atomic_short_write');
          }
          offset += count;
        }
      } else {
        const written: number = fileIo.writeSync(file.fd, content);
        if (!Number.isSafeInteger(written) || written !== utf8Bytes.length) {
          throw new Error('atomic_short_write');
        }
      }
      if (options?.fsync !== false) {
        fileIo.fsyncSync(file.fd);
      }
      fileIo.closeSync(file);
      file = undefined;
      fileIo.renameSync(tempPath, targetPath);
      committed = true;
    } finally {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (_closeError) {
        }
      }
      if (!committed && tempCreated) {
        if (typeof fileIo.unlinkSync === 'function') {
          try {
            fileIo.unlinkSync(tempPath);
          } catch (_cleanupError) {
          }
        }
      }
    }
  }

  static writeAtomic(targetPath: string, content: string, options?: AtomicWriteOptions): boolean {
    try {
      AtomicFileStore.writeAtomicOrThrow(targetPath, content, options);
      return true;
    } catch (_error) {
      return false;
    }
  }

  static readTextBoundedOrThrow(targetPath: string, maxBytes: number): string | undefined {
    if (targetPath.trim().length === 0) {
      throw new Error('atomic_invalid_path');
    }
    if (!Number.isSafeInteger(maxBytes) || maxBytes < 0) {
      throw new Error('atomic_file_limit');
    }
    if (typeof fileIo.accessSync === 'function' && !fileIo.accessSync(targetPath)) {
      return undefined;
    }
    const size: number = fileIo.statSync(targetPath).size;
    if (!Number.isSafeInteger(size) || size < 0 || size > maxBytes) {
      throw new Error('atomic_file_limit');
    }
    const text: string = fileIo.readTextSync(targetPath);
    if (AtomicFileStore.utf8ByteLength(text) > maxBytes) {
      throw new Error('atomic_file_limit');
    }
    return text;
  }

  static readTextBounded(targetPath: string, maxBytes: number): string | undefined {
    try {
      return AtomicFileStore.readTextBoundedOrThrow(targetPath, maxBytes);
    } catch (_error) {
      return undefined;
    }
  }

  static cleanupTempSiblings(dirPath: string, fileName: string): boolean {
    const baseDir: string = AtomicFileStore.trimTrailingSlashes(dirPath.trim());
    const cleanName: string = fileName.trim();
    if (baseDir.length === 0 || cleanName.length === 0 || cleanName.includes('/')) {
      return false;
    }
    const legacyName: string = `${cleanName}.tmp`;
    let succeeded: boolean = AtomicFileStore.unlinkIfPresent(`${baseDir}/${legacyName}`);
    if (typeof fileIo.listFileSync === 'function') {
      let entries: string[] = [];
      try {
        entries = fileIo.listFileSync(baseDir);
      } catch (_listError) {
        return succeeded;
      }
      const prefix: string = `${cleanName}.`;
      for (const entry of entries) {
        if (entry !== legacyName && entry.startsWith(prefix) && entry.endsWith('.tmp')) {
          if (!AtomicFileStore.unlinkIfPresent(`${baseDir}/${entry}`)) {
            succeeded = false;
          }
        }
      }
    }
    return succeeded;
  }

  private static sanitizeOwner(raw?: string): string {
    if (raw === undefined) {
      return 'atomic';
    }
    const cleaned: string = raw.replace(/[^A-Za-z0-9_-]+/g, '');
    return cleaned.length > 0 ? cleaned.substring(0, 32) : 'atomic';
  }

  private static nextTempPath(targetPath: string, rawOwner?: string): string {
    const owner: string = AtomicFileStore.sanitizeOwner(rawOwner);
    const nowMs: number = Date.now();
    const timestamp: number = Number.isFinite(nowMs) && nowMs >= 0 ? Math.floor(nowMs) : 0;
    if (AtomicFileStore.sequence >= 9007199254740000) {
      AtomicFileStore.sequence = 0;
    }
    const seq: number = ++AtomicFileStore.sequence;
    return `${targetPath}.${owner}.${timestamp}.${seq}.tmp`;
  }

  private static trimTrailingSlashes(path: string): string {
    let end: number = path.length;
    while (end > 1 && path.charCodeAt(end - 1) === 47) {
      end--;
    }
    return path.substring(0, end);
  }

  private static unlinkIfPresent(path: string): boolean {
    try {
      if (typeof fileIo.accessSync === 'function' && !fileIo.accessSync(path)) {
        return true;
      }
      if (typeof fileIo.unlinkSync === 'function') {
        fileIo.unlinkSync(path);
      }
      return true;
    } catch (_error) {
      return false;
    }
  }
}
