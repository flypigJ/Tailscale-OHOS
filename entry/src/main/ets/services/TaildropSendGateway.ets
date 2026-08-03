import { fileIo } from '@kit.CoreFileKit';

export interface PreparedTaildropFile { path: string; name: string; size: number; previewPath: string; }
export type TaildropPreviewFactory = (name: string, path: string, requestId: number) => Promise<string>;

/** M5 owner for send-side copied-file preparation and cleanup. */
export class TaildropSendGateway {
  async prepareFiles(uris: string[], outboxRoot: string, requestId: number,
    sanitizeName: (name: string, index: number) => string,
    previewFactory: TaildropPreviewFactory): Promise<PreparedTaildropFile[]> {
    const requestDir: string = `${outboxRoot}/${requestId}`;
    if (fileIo.accessSync(requestDir)) {
      throw new Error('Taildrop cache request directory already exists.');
    }
    fileIo.mkdirSync(requestDir, true);
    const prepared: PreparedTaildropFile[] = [];
    try {
      for (let index: number = 0; index < uris.length; index++) {
        let source: fileIo.File | undefined = undefined;
        try {
          source = fileIo.openSync(uris[index], fileIo.OpenMode.READ_ONLY);
          const stat: fileIo.Stat = fileIo.statSync(source.fd);
          if (!stat.isFile() || stat.size < 0) { throw new Error('Selected item is not a regular file.'); }
          const name: string = sanitizeName(source.name, index);
          const destination: string = `${requestDir}/${index}.taildrop`;
          if (fileIo.accessSync(destination)) { throw new Error('Taildrop cache destination already exists.'); }
          await fileIo.copyFile(source.fd, destination);
          const copied: fileIo.Stat = fileIo.lstatSync(destination);
          if (!copied.isFile() || copied.size !== stat.size) { throw new Error('Copied Taildrop file failed verification.'); }
          const previewPath: string = uris.length === 1 ? await previewFactory(name, destination, requestId) : '';
          prepared.push({ path: destination, name: name, size: copied.size, previewPath: previewPath });
        } finally { if (source !== undefined) { try { fileIo.closeSync(source); } catch (_error) {} } }
      }
      return prepared;
    } catch (_error) {
      TaildropSendGateway.cleanupRequestDirectory(requestDir, prepared);
      throw new Error('Taildrop cache staging failed.');
    }
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
