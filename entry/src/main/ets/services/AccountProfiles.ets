import { fileIo } from '@kit.CoreFileKit';
import { AtomicFileStore } from './AtomicFileStore';
import { ControlServerConfig } from './ControlServerConfig';
import { ControlServerPresets, ControlServerPreset } from './ControlServerPresets';

export interface AccountProfile {
  id: string;
  label: string;
}

export interface ServerAccountProfiles {
  controlURL: string;
  activeId: string;
  revision: number;
  nextId: number;
  profiles: AccountProfile[];
}

interface AccountProfileCatalog {
  schemaVersion: number;
  servers: ServerAccountProfiles[];
}

/** App account slots. Native identity and preferences remain opaque in their own directories. */
export class AccountProfiles {
  private static readonly FILE_NAME: string = 'account-profiles-v1.json';

  private static initial(controlURL: string): ServerAccountProfiles {
    return { controlURL, activeId: 'default', revision: 0, nextId: 1,
      profiles: [{ id: 'default', label: '' }] };
  }

  private static read(filesDir: string): AccountProfileCatalog {
    const path: string = `${filesDir}/${AccountProfiles.FILE_NAME}`;
    if (!fileIo.accessSync(path)) return { schemaVersion: 1, servers: [] };
    if (fileIo.statSync(path).size > 262144) throw new Error('Account catalog too large');
    const value: AccountProfileCatalog = JSON.parse(fileIo.readTextSync(path)) as AccountProfileCatalog;
    if (value === null || value.schemaVersion !== 1 || !Array.isArray(value.servers) ||
      value.servers.length > 32) throw new Error('Invalid account catalog');
    const urls: Set<string> = new Set<string>();
    for (const server of value.servers) {
      if (server === null || typeof server.controlURL !== 'string' || server.controlURL.length === 0 ||
        ControlServerConfig.normalize(server.controlURL) !== server.controlURL || urls.has(server.controlURL) ||
        !Number.isSafeInteger(server.revision) || server.revision < 0 ||
        !Number.isSafeInteger(server.nextId) || server.nextId < 1 ||
        !Array.isArray(server.profiles) || server.profiles.length < 1 || server.profiles.length > 16) {
        throw new Error('Invalid account server');
      }
      urls.add(server.controlURL);
      const ids: Set<string> = new Set<string>();
      for (const profile of server.profiles) {
        if (profile === null || typeof profile.id !== 'string' ||
          (profile.id !== 'default' && !/^profile-[1-9][0-9]*$/.test(profile.id)) ||
          typeof profile.label !== 'string' || profile.label.length > 128 || ids.has(profile.id)) {
          throw new Error('Invalid account profile');
        }
        if (profile.id !== 'default') {
          const id: number = Number(profile.id.substring(8));
          if (!Number.isSafeInteger(id) || id >= server.nextId) throw new Error('Invalid account sequence');
        }
        ids.add(profile.id);
      }
      if (!ids.has('default') || !ids.has(server.activeId)) throw new Error('Missing active account');
    }
    return value;
  }

  static current(filesDir: string, controlURL: string): ServerAccountProfiles {
    return AccountProfiles.read(filesDir).servers.find(
      (server: ServerAccountProfiles) => server.controlURL === controlURL) ?? AccountProfiles.initial(controlURL);
  }

  static ensure(filesDir: string, controlURL: string): ServerAccountProfiles {
    const catalog: AccountProfileCatalog = AccountProfiles.read(filesDir);
    const existing: ServerAccountProfiles | undefined = catalog.servers.find(
      (server: ServerAccountProfiles) => server.controlURL === controlURL);
    if (existing !== undefined) return existing;
    AccountProfiles.server(filesDir, controlURL);
    if (catalog.servers.length >= 32) throw new Error('Account server limit');
    const value: ServerAccountProfiles = AccountProfiles.initial(controlURL);
    catalog.servers.push(value);
    AccountProfiles.write(filesDir, catalog);
    return value;
  }

  static add(filesDir: string, controlURL: string): string {
    AccountProfiles.ensure(filesDir, controlURL);
    const catalog: AccountProfileCatalog = AccountProfiles.read(filesDir);
    const server: ServerAccountProfiles = AccountProfiles.requireServer(catalog, controlURL);
    if (server.profiles.length >= 16) throw new Error('Account profile limit');
    const id: string = `profile-${server.nextId++}`;
    server.profiles.push({ id, label: '' });
    AccountProfiles.write(filesDir, catalog);
    return id;
  }

  static select(filesDir: string, controlURL: string, id: string): ServerAccountProfiles {
    const catalog: AccountProfileCatalog = AccountProfiles.read(filesDir);
    const server: ServerAccountProfiles = AccountProfiles.requireServer(catalog, controlURL);
    if (!server.profiles.some((profile: AccountProfile) => profile.id === id)) throw new Error('Unknown account');
    if (server.activeId === id) return server;
    server.activeId = id;
    server.revision = Math.max(server.revision + 1, Date.now());
    AccountProfiles.write(filesDir, catalog);
    return server;
  }

  static setLabel(filesDir: string, controlURL: string, id: string, label: string): ServerAccountProfiles {
    const catalog: AccountProfileCatalog = AccountProfiles.read(filesDir);
    const server: ServerAccountProfiles = AccountProfiles.requireServer(catalog, controlURL);
    const profile: AccountProfile | undefined = server.profiles.find((item: AccountProfile) => item.id === id);
    if (profile === undefined || server.activeId !== id) throw new Error('Account changed');
    const value: string = label.trim().substring(0, 128);
    if (value.length > 0 && profile.label !== value) {
      profile.label = value;
      AccountProfiles.write(filesDir, catalog);
    }
    return server;
  }

  static token(filesDir: string, controlURL: string): string {
    const server: ServerAccountProfiles = AccountProfiles.current(filesDir, controlURL);
    return `${server.activeId}:${server.revision}`;
  }

  static stateRoot(filesDir: string, controlURL: string, id: string): string {
    AccountProfiles.requireProfile(filesDir, controlURL, id);
    const server: ControlServerPreset = AccountProfiles.server(filesDir, controlURL);
    return id === 'default' ? `${filesDir}/tailscale` : `${filesDir}/tailscale/account-profiles/${server.id}/${id}`;
  }

  static cacheRoot(filesDir: string, baseDir: string, controlURL: string, id: string): string {
    AccountProfiles.requireProfile(filesDir, controlURL, id);
    const serverRoot: string = ControlServerPresets.root(filesDir, baseDir, controlURL);
    if (id === 'default') return serverRoot;
    const root: string = `${serverRoot}/account-profiles/${id}`;
    if (!fileIo.accessSync(root)) fileIo.mkdirSync(root, true);
    return root;
  }

  private static requireProfile(filesDir: string, controlURL: string, id: string): void {
    if (!AccountProfiles.current(filesDir, controlURL).profiles.some((item: AccountProfile) => item.id === id)) {
      throw new Error('Account scope unavailable');
    }
  }

  private static server(filesDir: string, controlURL: string): ControlServerPreset {
    const server: ControlServerPreset | undefined = ControlServerPresets.read(filesDir)?.servers.find(
      (item: ControlServerPreset) => item.controlURL === controlURL);
    if (server === undefined) throw new Error('Server scope unavailable');
    return server;
  }

  private static requireServer(catalog: AccountProfileCatalog, controlURL: string): ServerAccountProfiles {
    const server: ServerAccountProfiles | undefined = catalog.servers.find(
      (item: ServerAccountProfiles) => item.controlURL === controlURL);
    if (server === undefined) throw new Error('Account server unavailable');
    return server;
  }

  private static write(filesDir: string, catalog: AccountProfileCatalog): void {
    const path: string = `${filesDir}/${AccountProfiles.FILE_NAME}`;
    AtomicFileStore.writeAtomicOrThrow(path, JSON.stringify(catalog), {
      owner: 'account',
      fsync: true
    });
  }
}
