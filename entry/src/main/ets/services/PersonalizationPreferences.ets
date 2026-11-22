import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { AtomicFileStore } from './AtomicFileStore';

export type AppColorMode = 'system' | 'light' | 'dark';

export interface PersonalizationSettings {
  colorMode: AppColorMode;
  backgroundBrightness: number;
}

export const DEFAULT_PERSONALIZATION_SETTINGS: PersonalizationSettings = {
  colorMode: 'system',
  backgroundBrightness: 52
};

/** Independent appearance preferences; existing background, material and navigation stores stay intact. */
export class PersonalizationPreferences {
  private static readonly FILE_NAME: string = 'ui-personalization-v1.json';

  static defaults(): PersonalizationSettings {
    return {
      colorMode: DEFAULT_PERSONALIZATION_SETTINGS.colorMode,
      backgroundBrightness: DEFAULT_PERSONALIZATION_SETTINGS.backgroundBrightness
    };
  }

  static load(filesDir: string): PersonalizationSettings {
    try {
      const parsed: PersonalizationSettings = JSON.parse(
        fileIo.readTextSync(PersonalizationPreferences.path(filesDir))) as PersonalizationSettings;
      return PersonalizationPreferences.normalize(parsed);
    } catch (_error) {
      return PersonalizationPreferences.defaults();
    }
  }

  static save(filesDir: string, settings: PersonalizationSettings): boolean {
    if (filesDir.trim().length === 0) {
      return false;
    }
    const path: string = PersonalizationPreferences.path(filesDir);
    return AtomicFileStore.writeAtomic(path,
      JSON.stringify(PersonalizationPreferences.normalize(settings)), {
        owner: 'personalization',
        fsync: true
      });
  }

  /** The caller must invoke this on the main thread after its window and page have loaded. */
  static applyColorMode(context: common.UIAbilityContext, mode: AppColorMode): void {
    const normalized: AppColorMode = PersonalizationPreferences.normalizeMode(mode);
    const colorMode: ConfigurationConstant.ColorMode = normalized === 'light' ?
      ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT : normalized === 'dark' ?
        ConfigurationConstant.ColorMode.COLOR_MODE_DARK : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    context.getApplicationContext().setColorMode(colorMode);
  }

  static colorModeIndex(mode: AppColorMode): number {
    const normalized: AppColorMode = PersonalizationPreferences.normalizeMode(mode);
    return normalized === 'light' ? 1 : normalized === 'dark' ? 2 : 0;
  }

  static colorModeAtIndex(index: number): AppColorMode {
    return index === 1 ? 'light' : index === 2 ? 'dark' : 'system';
  }

  static backgroundBrightnessFactor(value: number): number {
    return 0.48 + PersonalizationPreferences.normalizeBrightness(value) / 100;
  }

  private static normalize(settings: PersonalizationSettings): PersonalizationSettings {
    if (settings === undefined || settings === null || typeof settings !== 'object' || Array.isArray(settings)) {
      return PersonalizationPreferences.defaults();
    }
    return {
      colorMode: PersonalizationPreferences.normalizeMode(settings.colorMode),
      backgroundBrightness: PersonalizationPreferences.normalizeBrightness(settings.backgroundBrightness)
    };
  }

  private static normalizeMode(mode: AppColorMode): AppColorMode {
    return mode === 'light' || mode === 'dark' ? mode : 'system';
  }

  private static normalizeBrightness(value: number): number {
    if (typeof value !== 'number' || !Number.isFinite(value)) {
      return DEFAULT_PERSONALIZATION_SETTINGS.backgroundBrightness;
    }
    return Math.min(100, Math.max(0, Math.round(value)));
  }

  private static path(filesDir: string): string {
    return filesDir.endsWith('/') ? filesDir + PersonalizationPreferences.FILE_NAME :
      filesDir + '/' + PersonalizationPreferences.FILE_NAME;
  }
}
