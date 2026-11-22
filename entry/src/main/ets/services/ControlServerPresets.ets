import { fileIo } from '@kit.CoreFileKit';
import { AtomicFileStore } from './AtomicFileStore';
import { ControlServerConfig, DEFAULT_CONTROL_SERVER_URL } from './ControlServerConfig';

export interface ControlServerPreset {
  id: string;
  controlURL: string;
}

export interface ControlServerPresetCatalog {
  schemaVersion: number;
  legacyControlURL: string;
  servers: ControlServerPreset[];
}

/** Additive catalog; existing native identity directories and cache files never move. */
export class ControlServerPresets {
  private static readonly FILE_NAME: string = 'control-server-presets-v1.json';

  static read(filesDir: string): ControlServerPresetCatalog | undefined {
    try {
      const path: string = `${filesDir}/${ControlServerPresets.FILE_NAME}`;
      if (fileIo.statSync(path).size > 131072) return undefined;
      const value: ControlServerPresetCatalog = JSON.parse(fileIo.readTextSync(path)) as ControlServerPresetCatalog;
      if (value === null || value.schemaVersion !== 1 || typeof value.legacyControlURL !== 'string' ||
        !Array.isArray(value.servers) || value.servers.length < 1 || value.servers.length > 32) return undefined;
      const ids: Set<string> = new Set<string>();
      const urls: Set<string> = new Set<string>();
      for (const server of value.servers) {
        if (server === null || typeof server.id !== 'string' || !/^server-[1-9][0-9]*$/.test(server.id) ||
          typeof server.controlURL !== 'string' || ControlServerConfig.normalize(server.controlURL) !== server.controlURL ||
          server.controlURL.length === 0 || ids.has(server.id) || urls.has(server.controlURL)) return undefined;
        ids.add(server.id); urls.add(server.controlURL);
      }
      return urls.has(value.legacyControlURL) ? value : undefined;
    } catch (_error) { return undefined; }
  }

  static ensure(filesDir: string, rawURL: string): ControlServerPresetCatalog | undefined {
    try {
      return ControlServerPresets.ensureCatalog(filesDir, rawURL);
    } catch (_error) { return undefined; }
  }

  private static ensureCatalog(filesDir: string, rawURL: string): ControlServerPresetCatalog | undefined {
    const url: string = ControlServerConfig.normalize(rawURL);
    if (url.length === 0) return undefined;
    const path: string = `${filesDir}/${ControlServerPresets.FILE_NAME}`;
    let catalog: ControlServerPresetCatalog | undefined = ControlServerPresets.read(filesDir);
    if (catalog === undefined) {
      // A damaged catalog must not silently reassign existing cached content.
      if (fileIo.accessSync(path)) return undefined;
      const legacy: string = ControlServerConfig.load(filesDir).controlURL;
      catalog = { schemaVersion: 1, legacyControlURL: legacy,
        servers: [{ id: 'server-1', controlURL: legacy }] };
      if (legacy !== DEFAULT_CONTROL_SERVER_URL) {
        catalog.servers.push({ id: 'server-2', controlURL: DEFAULT_CONTROL_SERVER_URL });
      }
    } else if (catalog.servers.some((server: ControlServerPreset) => server.controlURL === url)) {
      return catalog;
    }
    if (!catalog.servers.some((server: ControlServerPreset) => server.controlURL === url)) {
      if (catalog.servers.length >= 32) return undefined;
      const nextId: number = Math.max(...catalog.servers.map((server: ControlServerPreset) =>
        Number(server.id.substring(7)))) + 1;
      catalog.servers.push({ id: `server-${nextId}`, controlURL: url });
    }
    return ControlServerPresets.write(filesDir, catalog) ? catalog : undefined;
  }

  static root(filesDir: string, baseDir: string, controlURL: string): string {
    const catalog: ControlServerPresetCatalog | undefined = ControlServerPresets.read(filesDir);
    const server: ControlServerPreset | undefined = catalog?.servers.find(
      (item: ControlServerPreset) => item.controlURL === controlURL);
    if (catalog === undefined || server === undefined) {
      // No fallback to another server's old cache if metadata is unavailable.
      throw new Error('Control server cache scope unavailable');
    }
    if (catalog.legacyControlURL === controlURL) return baseDir;
    const root: string = `${baseDir}/control-server-data/${server.id}`;
    if (!fileIo.accessSync(root)) fileIo.mkdirSync(root, true);
    return root;
  }

  private static write(filesDir: string, catalog: ControlServerPresetCatalog): boolean {
    const path: string = `${filesDir}/${ControlServerPresets.FILE_NAME}`;
    return AtomicFileStore.writeAtomic(path, JSON.stringify(catalog), {
      owner: 'presets',
      fsync: true
    });
  }
}
