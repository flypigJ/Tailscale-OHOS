import nativeBridge from 'libtailscale_ohos.so';

export type NetworkSettingKey = 'routeAll' | 'exitNodeAllowLANAccess';

export interface PendingNetworkSettingsUpdate {
  generation: number;
  value: string;
}

/**
 * Keeps one setting's writes serialized while retaining only the latest user
 * choice. A completion is authoritative only when its generation is current.
 */
export class NetworkSettingsUpdateQueue {
  private nextGeneration: number = 1;
  private currentGeneration: number = 0;
  private pending: PendingNetworkSettingsUpdate | undefined = undefined;
  private active: boolean = false;

  enqueue(value: string): number {
    const generation: number = this.nextGeneration++;
    this.currentGeneration = generation;
    this.pending = { generation: generation, value: value };
    return generation;
  }

  beginNext(): PendingNetworkSettingsUpdate | undefined {
    if (this.active || this.pending === undefined) {
      return undefined;
    }
    const update: PendingNetworkSettingsUpdate = this.pending;
    this.pending = undefined;
    this.active = true;
    return update;
  }

  finish(): void {
    this.active = false;
  }

  hasPending(): boolean {
    return this.pending !== undefined;
  }

  isCurrent(generation: number): boolean {
    return generation > 0 && generation === this.currentGeneration;
  }
}

/** Owns the M4B Exit Node and network-setting Native boundary. */
export class NetworkSettingsGateway {
  readExitNodes(): string {
    return nativeBridge.backendExitNodes();
  }

  async writeExitNode(id: string): Promise<string> {
    return await nativeBridge.backendSetExitNodeAsync(id);
  }

  readNetworkSettings(): string {
    return nativeBridge.backendNetworkSettings();
  }

  async writeNetworkSetting(key: NetworkSettingKey, enabled: boolean): Promise<string> {
    return await nativeBridge.backendSetNetworkSettingAsync(key, enabled);
  }
}
