import { fileIo } from '@kit.CoreFileKit';

export interface PreparedTaildropFile { path: string; name: string; size: number; previewPath: string; }
export type TaildropPreviewFactory = (name: string, path: string, requestId: number) => Promise<string>;

const PRIVATE_SANDBOX_BASE_PREFIXES: string[] = [
  '/data/storage/el1/base',
  '/data/storage/el2/base',
  '/data/storage/el3/base',
  '/data/storage/el4/base',
  '/data/storage/el5/base'
];

/** M5 owner for send-side copied-file preparation and cleanup. */
export class TaildropSendGateway {
  async prepareFiles(uris: string[], outboxRoot: string, requestId: number,
    sanitizeName: (name: string, index: number) => string,
    previewFactory: TaildropPreviewFactory,
    active: () => boolean = (): boolean => true): Promise<PreparedTaildropFile[]> {
    if (uris.length === 0 || uris.length > 100 || !Number.isSafeInteger(requestId) || requestId <= 0) {
      throw new Error('Invalid Taildrop staging request.');
    }
    const requestDir: string = `${outboxRoot}/${requestId}`;
    if (await fileIo.access(requestDir)) {
      throw new Error('Taildrop cache request directory already exists.');
    }
    await fileIo.mkdir(requestDir, true);
    const prepared: PreparedTaildropFile[] = [];
    try {
      for (let index: number = 0; index < uris.length; index++) {
        let source: fileIo.File | undefined = undefined;
        try {
          if (!active()) { throw new Error('Staging cancelled.'); }
          source = await fileIo.open(uris[index], fileIo.OpenMode.READ_ONLY);
          const resolvedPath: string = typeof source.path === 'string' ?
            source.path.replace(/\\/g, '/').toLowerCase() : '';
          if (TaildropSendGateway.isPrivateSandboxSourcePath(resolvedPath)) {
            throw new Error('Selected item resolves inside private application storage.');
          }
          const stat: fileIo.Stat = await fileIo.stat(source.fd);
          if ((typeof stat.isSymbolicLink === 'function' && stat.isSymbolicLink()) ||
            !stat.isFile() || !Number.isSafeInteger(stat.size) || stat.size < 0) {
            throw new Error('Selected item is not a regular file.');
          }
          if (!active()) { throw new Error('Staging cancelled.'); }
          const name: string = sanitizeName(source.name, index);
          const destination: string = `${requestDir}/${index}.taildrop`;
          if (await fileIo.access(destination)) { throw new Error('Taildrop cache destination already exists.'); }
          await fileIo.copyFile(source.fd, destination);
          const copied: fileIo.Stat = await fileIo.lstat(destination);
          if (!copied.isFile() || copied.size !== stat.size) { throw new Error('Copied Taildrop file failed verification.'); }
          if (!active()) { throw new Error('Staging cancelled.'); }
          let previewPath: string = '';
          if (uris.length === 1) {
            // A corrupt/unsupported thumbnail must not reject an otherwise valid file.
            try { previewPath = await previewFactory(name, destination, requestId); } catch (_error) {}
          }
          const item: PreparedTaildropFile = {
            path: destination,
            name: name,
            size: copied.size,
            previewPath: previewPath
          };
          prepared.push(item);
          if (!active()) { throw new Error('Staging cancelled.'); }
        } finally { if (source !== undefined) { try { await fileIo.close(source); } catch (_error) {} } }
      }
      return prepared;
    } catch (_error) {
      TaildropSendGateway.cleanupRequestDirectory(requestDir, prepared);
      throw new Error('Taildrop cache staging failed.');
    }
  }

  private static isPrivateSandboxSourcePath(resolvedPath: string): boolean {
    if (resolvedPath.length === 0) {
      return false;
    }
    if (resolvedPath.includes('/io.github.tailscaleohos/') ||
      resolvedPath.endsWith('/io.github.tailscaleohos') ||
      resolvedPath.includes('tailscaled.state')) {
      return true;
    }
    for (let i: number = 0; i < PRIVATE_SANDBOX_BASE_PREFIXES.length; i++) {
      const prefix: string = PRIVATE_SANDBOX_BASE_PREFIXES[i];
      if (resolvedPath === prefix || resolvedPath.startsWith(`${prefix}/`)) {
        return true;
      }
    }
    return false;
  }

  cleanup(files: PreparedTaildropFile[]): void {
    files.forEach((file: PreparedTaildropFile) => {
      try { if (fileIo.accessSync(file.path)) { fileIo.unlinkSync(file.path); } } catch (_error) {}
      if (file.previewPath.length > 0) { try { if (fileIo.accessSync(file.previewPath)) { fileIo.unlinkSync(file.previewPath); } } catch (_error) {} }
    });
    if (files.length > 0) { try { fileIo.rmdirSync(files[0].path.substring(0, files[0].path.lastIndexOf('/'))); } catch (_error) {} }
  }

  private static cleanupRequestDirectory(requestDir: string, files: PreparedTaildropFile[]): void {
    files.forEach((file: PreparedTaildropFile) => {
      try { if (fileIo.accessSync(file.path)) { fileIo.unlinkSync(file.path); } } catch (_error) {}
      if (file.previewPath.length > 0) { try { if (fileIo.accessSync(file.previewPath)) { fileIo.unlinkSync(file.previewPath); } } catch (_error) {} }
    });
    try {
      if (fileIo.accessSync(requestDir)) {
        fileIo.listFileSync(requestDir).forEach((name: string) => {
          try {
            const path: string = `${requestDir}/${name}`;
            if (fileIo.statSync(path).isFile()) { fileIo.unlinkSync(path); }
          } catch (_error) {}
        });
        fileIo.rmdirSync(requestDir);
      }
    } catch (_error) {
      // This is a new, non-authoritative cache directory. A later cache cleanup can retry.
    }
  }
}
