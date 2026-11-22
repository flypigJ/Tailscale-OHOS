import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { AtomicFileStore, AtomicWriteOptions } from './AtomicFileStore';

export interface AppSecuritySettings {
  appLockEnabled: boolean;
  folderLockEnabled: boolean;
  lockedFolderPaths: string[];
}

interface PersistedSecuritySentinel {
  schemaVersion?: number;
  appLockEnabled?: boolean;
  folderLockEnabled?: boolean;
  lockedFolderPaths?: string[];
}

const STORE_NAME: string = 'mesh_arc_security';
const APP_LOCK_ENABLED_KEY: string = 'app_lock_enabled';
const FOLDER_LOCK_ENABLED_KEY: string = 'folder_lock_enabled';
const LOCKED_FOLDER_PATHS_KEY: string = 'locked_folder_paths';
const SENTINEL_FILE_NAME: string = 'app-security-armed-v1.json';
const SENTINEL_SCHEMA_VERSION: number = 1;
const MAX_SENTINEL_BYTES: number = 16384;

/** Stores only lock policy and Taildrive paths. System authentication data never enters app storage. */
export class AppSecurityPreferences {
  static async load(context: common.Context): Promise<AppSecuritySettings> {
    const filesDir: string = AppSecurityPreferences.filesDirOf(context);
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      const settings: AppSecuritySettings = AppSecurityPreferences.readStoreSettings(store);
      if (filesDir.length > 0 &&
        (settings.appLockEnabled || settings.folderLockEnabled || settings.lockedFolderPaths.length > 0)) {
        AppSecurityPreferences.syncSentinelBestEffort(filesDir, settings);
      }
      return settings;
    } catch (_error) {
      return AppSecurityPreferences.loadFallback(filesDir);
    }
  }

  static loadFallback(filesDir: string): AppSecuritySettings {
    const sentinelPath: string = AppSecurityPreferences.sentinelPathOf(filesDir);
    if (sentinelPath.length === 0 || typeof fileIo.accessSync !== 'function') {
      return AppSecurityPreferences.defaults();
    }
    let exists: boolean = false;
    try {
      exists = fileIo.accessSync(sentinelPath);
    } catch (_accessError) {
      return AppSecurityPreferences.defaults();
    }
    if (!exists) {
      return AppSecurityPreferences.defaults();
    }
    try {
      const raw: string | undefined = AtomicFileStore.readTextBoundedOrThrow(sentinelPath, MAX_SENTINEL_BYTES);
      if (raw === undefined || raw.trim().length === 0) {
        return AppSecurityPreferences.failClosed();
      }
      const parsed: PersistedSecuritySentinel = JSON.parse(raw) as PersistedSecuritySentinel;
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed) ||
        parsed.schemaVersion !== SENTINEL_SCHEMA_VERSION ||
        typeof parsed.appLockEnabled !== 'boolean' ||
        typeof parsed.folderLockEnabled !== 'boolean' ||
        !Array.isArray(parsed.lockedFolderPaths) ||
        !parsed.lockedFolderPaths.every((item: string) =>
          typeof item === 'string' && AppSecurityPreferences.isValidPathEntry(item))) {
        return AppSecurityPreferences.failClosed();
      }
      return {
        appLockEnabled: parsed.appLockEnabled,
        folderLockEnabled: parsed.folderLockEnabled,
        lockedFolderPaths: AppSecurityPreferences.normalizePathList(parsed.lockedFolderPaths)
      };
    } catch (_error) {
      return AppSecurityPreferences.failClosed();
    }
  }

  static isPrivacyProtectionArmedSync(filesDir: string): boolean {
    const fallback: AppSecuritySettings = AppSecurityPreferences.loadFallback(filesDir);
    return fallback.appLockEnabled || fallback.folderLockEnabled || fallback.lockedFolderPaths.length > 0;
  }

  static async saveAppLockEnabled(context: common.Context, enabled: boolean): Promise<void> {
    const store = await preferences.getPreferences(context, STORE_NAME);
    store.putSync(APP_LOCK_ENABLED_KEY, enabled);
    await store.flush();
    AppSecurityPreferences.writeSentinelOrThrow(
      AppSecurityPreferences.filesDirOf(context),
      AppSecurityPreferences.readStoreSettings(store)
    );
  }

  static async saveFolderLockEnabled(context: common.Context, enabled: boolean): Promise<void> {
    const store = await preferences.getPreferences(context, STORE_NAME);
    store.putSync(FOLDER_LOCK_ENABLED_KEY, enabled);
    await store.flush();
    AppSecurityPreferences.writeSentinelOrThrow(
      AppSecurityPreferences.filesDirOf(context),
      AppSecurityPreferences.readStoreSettings(store)
    );
  }

  static async saveLockedFolderPaths(context: common.Context, paths: string[]): Promise<void> {
    const store = await preferences.getPreferences(context, STORE_NAME);
    store.putSync(LOCKED_FOLDER_PATHS_KEY, JSON.stringify(AppSecurityPreferences.normalizePathList(paths)));
    await store.flush();
    AppSecurityPreferences.writeSentinelOrThrow(
      AppSecurityPreferences.filesDirOf(context),
      AppSecurityPreferences.readStoreSettings(store)
    );
  }

  private static filesDirOf(context: common.Context): string {
    return context !== undefined && typeof context.filesDir === 'string' ? context.filesDir.trim() : '';
  }

  private static sentinelPathOf(filesDir: string): string {
    const cleanDir: string = typeof filesDir === 'string' ? filesDir.trim().replace(/\/+$/, '') : '';
    return cleanDir.length > 0 ? `${cleanDir}/${SENTINEL_FILE_NAME}` : '';
  }

  private static readStoreSettings(store: preferences.Preferences): AppSecuritySettings {
    const settings: AppSecuritySettings = {
      appLockEnabled: store.getSync(APP_LOCK_ENABLED_KEY, false) as boolean,
      folderLockEnabled: store.getSync(FOLDER_LOCK_ENABLED_KEY, false) as boolean,
      lockedFolderPaths: AppSecurityPreferences.normalizePaths(
        store.getSync(LOCKED_FOLDER_PATHS_KEY, '[]') as string)
    };
    return settings;
  }

  private static serializeSentinel(settings: AppSecuritySettings): string {
    const payload: PersistedSecuritySentinel = {
      schemaVersion: SENTINEL_SCHEMA_VERSION,
      appLockEnabled: settings.appLockEnabled,
      folderLockEnabled: settings.folderLockEnabled,
      lockedFolderPaths: AppSecurityPreferences.normalizePathList(settings.lockedFolderPaths)
    };
    return JSON.stringify(payload);
  }

  private static sentinelWriteOptions(): AtomicWriteOptions {
    const options: AtomicWriteOptions = {
      owner: 'security',
      fsync: true,
      maxBytes: MAX_SENTINEL_BYTES
    };
    return options;
  }

  private static writeSentinelOrThrow(filesDir: string, settings: AppSecuritySettings): void {
    const sentinelPath: string = AppSecurityPreferences.sentinelPathOf(filesDir);
    if (sentinelPath.length === 0) {
      return;
    }
    AtomicFileStore.writeAtomicOrThrow(
      sentinelPath,
      AppSecurityPreferences.serializeSentinel(settings),
      AppSecurityPreferences.sentinelWriteOptions()
    );
  }

  private static syncSentinelBestEffort(filesDir: string, settings: AppSecuritySettings): void {
    const sentinelPath: string = AppSecurityPreferences.sentinelPathOf(filesDir);
    if (sentinelPath.length === 0) {
      return;
    }
    AtomicFileStore.writeAtomic(
      sentinelPath,
      AppSecurityPreferences.serializeSentinel(settings),
      AppSecurityPreferences.sentinelWriteOptions()
    );
  }

  private static defaults(): AppSecuritySettings {
    const unlocked: AppSecuritySettings = {
      appLockEnabled: false,
      folderLockEnabled: false,
      lockedFolderPaths: []
    };
    return unlocked;
  }

  private static failClosed(): AppSecuritySettings {
    const locked: AppSecuritySettings = {
      appLockEnabled: true,
      folderLockEnabled: true,
      lockedFolderPaths: []
    };
    return locked;
  }

  private static isValidPathEntry(path: string): boolean {
    const trimmed: string = path.trim().replace(/\/+$/, '');
    return trimmed.length > 1 && trimmed.startsWith('/');
  }

  private static normalizePaths(value: string): string[] {
    try {
      const parsed: string[] = JSON.parse(value) as string[];
      return Array.isArray(parsed) ? AppSecurityPreferences.normalizePathList(parsed) : [];
    } catch (_error) {
      return [];
    }
  }

  private static normalizePathList(paths: string[]): string[] {
    const candidates: string[] = [];
    paths.forEach((path: string) => {
      const value: string = path.trim().replace(/\/+$/, '');
      if (value.length > 1 && value.startsWith('/') && !candidates.includes(value)) {
        candidates.push(value);
      }
    });
    candidates.sort((left: string, right: string) => left.length - right.length);
    const normalized: string[] = [];
    candidates.forEach((value: string) => {
      if (!normalized.some((parent: string) => value === parent || value.startsWith(`${parent}/`))) {
        normalized.push(value);
      }
    });
    return normalized;
  }
}
