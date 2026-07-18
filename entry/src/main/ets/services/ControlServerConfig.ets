import { fileIo } from '@kit.CoreFileKit';

export const DEFAULT_CONTROL_SERVER_URL: string = 'https://controlplane.tailscale.com';

export interface ControlServerSettings {
  controlURL: string;
  confirmed: boolean;
  updatedAtMs: number;
}

export class ControlServerConfig {
  private static readonly FILE_NAME: string = 'control-server.json';

  static unconfigured(): ControlServerSettings {
    return {
      controlURL: DEFAULT_CONTROL_SERVER_URL,
      confirmed: false,
      updatedAtMs: 0
    };
  }

  static normalize(rawURL: string): string {
    const trimmed: string = rawURL.trim();
    if (trimmed.length === 0 || trimmed.length > 2048 ||
      (!trimmed.startsWith('https://') && !trimmed.startsWith('http://'))) {
      return '';
    }
    const schemeSeparator: number = trimmed.indexOf('://');
    const remainder: string = trimmed.substring(schemeSeparator + 3);
    if (remainder.length === 0 || remainder.startsWith('/') || remainder.includes('@') ||
      remainder.includes('?') || remainder.includes('#') || remainder.includes(' ')) {
      return '';
    }
    const authorityEnd: number = remainder.indexOf('/');
    const authority: string = authorityEnd >= 0 ? remainder.substring(0, authorityEnd) : remainder;
    if (authority.length === 0) {
      return '';
    }
    let normalized: string = trimmed;
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  static load(filesDir: string): ControlServerSettings {
    const path: string = ControlServerConfig.path(filesDir);
    try {
      if (!fileIo.accessSync(path)) {
        return ControlServerConfig.unconfigured();
      }
      const parsed: ControlServerSettings = JSON.parse(fileIo.readTextSync(path)) as ControlServerSettings;
      const normalized: string = ControlServerConfig.normalize(parsed.controlURL);
      if (!parsed.confirmed || normalized.length === 0) {
        return ControlServerConfig.unconfigured();
      }
      return {
        controlURL: normalized,
        confirmed: true,
        updatedAtMs: parsed.updatedAtMs > 0 ? parsed.updatedAtMs : 0
      };
    } catch (_error) {
      return ControlServerConfig.unconfigured();
    }
  }

  static save(filesDir: string, rawURL: string): ControlServerSettings | undefined {
    const normalized: string = ControlServerConfig.normalize(rawURL);
    if (normalized.length === 0) {
      return undefined;
    }
    const settings: ControlServerSettings = {
      controlURL: normalized,
      confirmed: true,
      updatedAtMs: Date.now()
    };
    const path: string = ControlServerConfig.path(filesDir);
    const temporaryPath: string = `${path}.${settings.updatedAtMs}.tmp`;
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(temporaryPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, JSON.stringify(settings));
      fileIo.closeSync(file);
      file = undefined;
      fileIo.renameSync(temporaryPath, path);
      return settings;
    } catch (_error) {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (_closeError) {
        }
      }
      try {
        if (fileIo.accessSync(temporaryPath)) {
          fileIo.unlinkSync(temporaryPath);
        }
      } catch (_cleanupError) {
      }
      return undefined;
    }
  }

  static reset(filesDir: string): boolean {
    let succeeded: boolean = true;
    const configPath: string = ControlServerConfig.path(filesDir);
    try {
      if (fileIo.accessSync(configPath)) {
        fileIo.unlinkSync(configPath);
      }
    } catch (_error) {
      succeeded = false;
    }
    try {
      ControlServerConfig.removeTree(`${filesDir}/tailscale`);
    } catch (_error) {
      succeeded = false;
    }
    return succeeded;
  }

  private static removeTree(path: string): void {
    if (!fileIo.accessSync(path)) {
      return;
    }
    const stat: fileIo.Stat = fileIo.statSync(path);
    if (stat.isFile()) {
      fileIo.unlinkSync(path);
      return;
    }
    if (!stat.isDirectory()) {
      return;
    }
    fileIo.listFileSync(path).forEach((name: string) => {
      ControlServerConfig.removeTree(`${path}/${name}`);
    });
    fileIo.rmdirSync(path);
  }

  private static path(filesDir: string): string {
    return `${filesDir}/${ControlServerConfig.FILE_NAME}`;
  }
}
