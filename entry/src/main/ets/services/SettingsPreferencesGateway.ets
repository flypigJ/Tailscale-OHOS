import { common } from '@kit.AbilityKit';
import {
  ControlServerConfig,
  ControlServerSettings
} from './ControlServerConfig';
import { ConnectedHomeLayoutMode } from '../components/HomeLayoutConfig';
import { HomeLayoutPreferences } from '../components/HomeLayoutPreferences';

/** Rejects stale Settings work after repeated entry or feature-host teardown. */
export class SettingsRequestGuard {
  private generation: number = 0;

  begin(): number {
    this.generation++;
    return this.generation;
  }

  invalidate(): void {
    this.generation++;
  }

  isCurrent(generation: number): boolean {
    return generation > 0 && generation === this.generation;
  }
}

/** Owns the M8A Settings preference and custom control-server persistence boundary. */
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
}
