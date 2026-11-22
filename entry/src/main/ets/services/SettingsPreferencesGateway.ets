import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { AtomicFileStore, AtomicWriteOptions } from './AtomicFileStore';
import {
  ControlServerConfig,
  ControlServerSettings
} from './ControlServerConfig';
import { ConnectedHomeLayoutMode } from '../components/HomeLayoutConfig';
import { HomeLayoutPreferences } from '../components/HomeLayoutPreferences';

export { RequestGuard as SettingsRequestGuard } from '@tailscale/common';

const SETTINGS_WELCOME_ACKNOWLEDGED_FILE: string = 'welcome-acknowledged';
const SETTINGS_UPDATE_CHANGELOG_SEEN_FILE: string = 'update-changelog-seen-version';
const SETTINGS_UPDATE_CHANGELOG_MARKER_PREFIX: string = 'only-on-update:';
const SETTINGS_GLOW_LEVEL_FILE: string = 'ui-glow-level-v2';
const SETTINGS_BACKGROUND_IMAGE_FILE: string = 'ui-background-image-uri-v1';
const SETTINGS_IMMERSIVE_COLOR_FILE: string = 'ui-immersive-color-v1';

export interface AppearanceOverlaySettings {
  backgroundUri: string;
  immersiveColorEnabled: boolean;
}

/**
 * Owns Settings preference, custom control-server, first-run/changelog markers,
 * and appearance overlay persistence behind a single file-system boundary.
 */
export class SettingsPreferencesGateway {
  loadControlServer(context: common.Context): ControlServerSettings {
    return ControlServerConfig.load(context.filesDir);
  }

  normalizeControlServer(rawURL: string): string {
    return ControlServerConfig.normalize(rawURL);
  }

  requiresHttpControlServerRisk(existing: ControlServerSettings, candidate: string): boolean {
    return candidate.startsWith('http://') &&
      (!existing.confirmed || existing.controlURL !== candidate);
  }

  confirmControlServer(context: common.Context, rawURL: string): ControlServerSettings | undefined {
    return ControlServerConfig.save(context.filesDir, rawURL);
  }

  resetControlServer(context: common.Context): boolean {
    return ControlServerConfig.reset(context.filesDir);
  }

  unconfiguredControlServer(): ControlServerSettings {
    return ControlServerConfig.unconfigured();
  }

  async loadConnectedHomeLayout(context: common.Context): Promise<ConnectedHomeLayoutMode> {
    return await HomeLayoutPreferences.load(context);
  }

  async saveConnectedHomeLayout(context: common.Context, mode: ConnectedHomeLayoutMode): Promise<void> {
    await HomeLayoutPreferences.save(context, mode);
  }

  updateChangelogSeenPath(filesDir: string): string {
    return `${filesDir}/${SETTINGS_UPDATE_CHANGELOG_SEEN_FILE}`;
  }

  updateChangelogSeenMarker(versionKey: string): string {
    return `${SETTINGS_UPDATE_CHANGELOG_MARKER_PREFIX}${versionKey}`;
  }

  hasSeenUpdateChangelog(filesDir: string, versionKey: string): boolean {
    try {
      const path: string = this.updateChangelogSeenPath(filesDir);
      // The prefixed marker intentionally invalidates the legacy raw-version
      // marker written by the former "Don't show again" action.
      return fileIo.accessSync(path) &&
        fileIo.readTextSync(path).trim() === this.updateChangelogSeenMarker(versionKey);
    } catch (_error) {
      return false;
    }
  }

  markUpdateChangelogSeen(filesDir: string, versionKey: string): boolean {
    const options: AtomicWriteOptions = { owner: 'changelog', fsync: true };
    return AtomicFileStore.writeAtomic(
      this.updateChangelogSeenPath(filesDir),
      this.updateChangelogSeenMarker(versionKey),
      options
    );
  }

  welcomeAcknowledgedPath(filesDir: string): string {
    return `${filesDir}/${SETTINGS_WELCOME_ACKNOWLEDGED_FILE}`;
  }

  isWelcomeAcknowledged(filesDir: string): boolean {
    try {
      return fileIo.accessSync(this.welcomeAcknowledgedPath(filesDir));
    } catch (_error) {
      return false;
    }
  }

  acknowledgeWelcome(filesDir: string): boolean {
    const options: AtomicWriteOptions = { owner: 'welcome', fsync: true };
    return AtomicFileStore.writeAtomic(
      this.welcomeAcknowledgedPath(filesDir),
      'acknowledged',
      options
    );
  }

  glowFilePath(filesDir: string): string {
    return `${filesDir}/${SETTINGS_GLOW_LEVEL_FILE}`;
  }

  loadGlowLevel(filesDir: string, fallback: number = 3): number {
    try {
      const path: string = this.glowFilePath(filesDir);
      if (!fileIo.accessSync(path)) {
        return fallback;
      }
      const level: number = Number(fileIo.readTextSync(path));
      if (Number.isFinite(level) && level >= 0 && level <= 3) {
        return level;
      }
      return fallback;
    } catch (_error) {
      return fallback;
    }
  }

  saveGlowLevel(filesDir: string, level: number): boolean {
    if (level < 0 || level > 3) {
      return false;
    }
    const options: AtomicWriteOptions = { owner: 'glow', fsync: false };
    if (AtomicFileStore.writeAtomic(this.glowFilePath(filesDir), level.toString(), options)) {
      return true;
    }
    return this.writePrivateTextFile(this.glowFilePath(filesDir), level.toString());
  }

  backgroundImageFilePath(filesDir: string): string {
    return `${filesDir}/${SETTINGS_BACKGROUND_IMAGE_FILE}`;
  }

  immersiveColorFilePath(filesDir: string): string {
    return `${filesDir}/${SETTINGS_IMMERSIVE_COLOR_FILE}`;
  }

  loadAppearanceOverlay(filesDir: string): AppearanceOverlaySettings {
    const defaults: AppearanceOverlaySettings = {
      backgroundUri: '',
      immersiveColorEnabled: false
    };
    try {
      const backgroundPath: string = this.backgroundImageFilePath(filesDir);
      const backgroundUri: string = fileIo.accessSync(backgroundPath) ?
        fileIo.readTextSync(backgroundPath).trim() : '';
      const immersivePath: string = this.immersiveColorFilePath(filesDir);
      const immersiveColorEnabled: boolean = fileIo.accessSync(immersivePath) &&
        fileIo.readTextSync(immersivePath).trim() === '1';
      const loaded: AppearanceOverlaySettings = {
        backgroundUri: backgroundUri,
        immersiveColorEnabled: immersiveColorEnabled
      };
      return loaded;
    } catch (_error) {
      return defaults;
    }
  }

  writeAppearanceFile(path: string, value: string): boolean {
    const options: AtomicWriteOptions = { owner: 'appearance', fsync: true };
    return AtomicFileStore.writeAtomic(path, value, options);
  }

  saveBackgroundImageUri(filesDir: string, uri: string): boolean {
    return this.writeAppearanceFile(this.backgroundImageFilePath(filesDir), uri);
  }

  saveImmersiveColorEnabled(filesDir: string, enabled: boolean): boolean {
    return this.writeAppearanceFile(this.immersiveColorFilePath(filesDir), enabled ? '1' : '0');
  }

  writePrivateTextFile(path: string, content: string): boolean {
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, content);
      return true;
    } catch (_error) {
      return false;
    } finally {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (_error) {
          // The descriptor may already be closed after a platform write failure.
        }
      }
    }
  }
}
