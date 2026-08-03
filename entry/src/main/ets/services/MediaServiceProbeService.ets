import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import {
  DiscoveredMediaService,
  MediaProbeResult,
  MediaProbeState,
  MediaServiceType
} from './MediaIntegrationModels';

const REQUEST_FILE: string = 'media-service-probe-request.json';
const RESPONSE_FILE: string = 'media-service-probe-response.json';
const AVAILABLE_CACHE_TTL_MS: number = 5 * 60 * 1000;
const NEGATIVE_CACHE_TTL_MS: number = 60 * 1000;
const TIMEOUT_MS: number = 5500;

interface MediaProbeResponse {
  requestId: number;
  result: string;
}

interface NativeMediaService {
  type: string;
  name: string;
  url: string;
  version?: string;
  latencyMs?: number;
}

interface NativeMediaProbeResult {
  state: string;
  checkedAt?: number;
  services?: NativeMediaService[];
  errorMessage?: string;
}

export class MediaServiceProbeService {
  private readonly cache: Map<string, MediaProbeResult> = new Map();
  private readonly requestIds: Map<string, number> = new Map();
  private readonly context: common.UIAbilityContext;
  private queue: Promise<void> = Promise.resolve();

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  clearCache(peerKey?: string): void {
    if (peerKey === undefined) {
      this.cache.clear();
      return;
    }
    this.cache.delete(peerKey);
  }

  cancel(peerKey: string): void {
    this.requestIds.set(peerKey, (this.requestIds.get(peerKey) ?? 0) + 1);
  }

  async probe(peerKey: string, vpnConnected: boolean, force: boolean = false): Promise<MediaProbeResult> {
    return this.enqueue(() => this.probeInternal(peerKey, vpnConnected, force));
  }

  private async probeInternal(peerKey: string, vpnConnected: boolean,
    force: boolean): Promise<MediaProbeResult> {
    const cached: MediaProbeResult | undefined = this.cache.get(peerKey);
    if (!force && cached !== undefined && Date.now() - cached.checkedAt < this.cacheTtl(cached)) {
      return cached;
    }
    if (!vpnConnected) {
      return this.emptyResult('unknown', 'mesh_disconnected');
    }
    const requestGeneration: number = (this.requestIds.get(peerKey) ?? 0) + 1;
    this.requestIds.set(peerKey, requestGeneration);
    const resultText: string = await this.requestThroughVpnExtension(peerKey, Date.now());
    if (this.requestIds.get(peerKey) !== requestGeneration) {
      return this.emptyResult('unknown', 'cancelled');
    }
    const parsed: MediaProbeResult = this.parse(resultText);
    this.cache.set(peerKey, parsed);
    return parsed;
  }

  private enqueue(task: () => Promise<MediaProbeResult>): Promise<MediaProbeResult> {
    let release: () => void = () => {};
    const previous: Promise<void> = this.queue;
    this.queue = new Promise<void>((resolve: () => void) => { release = resolve; });
    return previous.then(task).finally(() => release());
  }

  private cacheTtl(result: MediaProbeResult): number {
    return result.state === 'available' ? AVAILABLE_CACHE_TTL_MS : NEGATIVE_CACHE_TTL_MS;
  }

  private async requestThroughVpnExtension(peerKey: string, requestId: number): Promise<string> {
    const responsePath: string = `${this.context.filesDir}/${RESPONSE_FILE}`;
    const requestPath: string = `${this.context.filesDir}/${REQUEST_FILE}`;
    try {
      this.writeText(responsePath, '');
      if (!this.writeText(requestPath, JSON.stringify({ requestId: requestId, peerKey: peerKey }))) {
        return '{"state":"error","services":[],"errorMessage":"extension_error"}';
      }
      const startedAt: number = Date.now();
      while (Date.now() - startedAt < TIMEOUT_MS) {
        await new Promise<void>((resolve: () => void) => setTimeout(resolve, 150));
        if (!fileIo.accessSync(responsePath)) {
          continue;
        }
        const responseText: string = fileIo.readTextSync(responsePath).trim();
        if (responseText.length === 0) {
          continue;
        }
        const response: MediaProbeResponse = JSON.parse(responseText) as MediaProbeResponse;
        if (response.requestId !== requestId) {
          continue;
        }
        this.writeText(responsePath, '');
        return response.result;
      }
      return '{"state":"timeout","services":[],"errorMessage":"timeout"}';
    } catch (_error) {
      return '{"state":"error","services":[],"errorMessage":"extension_error"}';
    }
  }

  private parse(text: string): MediaProbeResult {
    try {
      const nativeResult: NativeMediaProbeResult = JSON.parse(text) as NativeMediaProbeResult;
      const state: MediaProbeState = this.parseState(nativeResult.state);
      const services: DiscoveredMediaService[] = [];
      (nativeResult.services ?? []).forEach((item: NativeMediaService) => {
        const type: MediaServiceType | undefined = this.parseType(item.type);
        if (type === undefined || !this.safeServerUrl(item.url)) {
          return;
        }
        services.push({
          type: type,
          name: item.name.trim().length > 0 ? item.name.trim() : this.typeLabel(type),
          url: item.url,
          version: item.version,
          latencyMs: item.latencyMs
        });
      });
      return {
        state: services.length > 0 ? 'available' : state,
        checkedAt: nativeResult.checkedAt ?? Date.now(),
        services: services,
        errorMessage: nativeResult.errorMessage
      };
    } catch (_error) {
      return this.emptyResult('error', 'invalid_result');
    }
  }

  private parseState(value: string): MediaProbeState {
    if (value === 'available' || value === 'unavailable' || value === 'timeout' || value === 'error') {
      return value;
    }
    return 'error';
  }

  private parseType(value: string): MediaServiceType | undefined {
    if (value === 'jellyfin' || value === 'emby' || value === 'plex' ||
      value === 'webdav' || value === 'smb') {
      return value;
    }
    return undefined;
  }

  private typeLabel(type: MediaServiceType): string {
    if (type === 'jellyfin') return 'Jellyfin';
    if (type === 'emby') return 'Emby';
    if (type === 'plex') return 'Plex';
    if (type === 'webdav') return 'WebDAV';
    return 'SMB';
  }

  private safeServerUrl(value: string): boolean {
    const normalized: string = value.trim().toLowerCase();
    return (normalized.startsWith('http://') || normalized.startsWith('https://')) &&
      !/^https?:\/\/[^/]*@/i.test(value) && value.length <= 2048;
  }

  private emptyResult(state: MediaProbeState, errorMessage: string): MediaProbeResult {
    return { state: state, checkedAt: Date.now(), services: [], errorMessage: errorMessage };
  }

  private writeText(path: string, content: string): boolean {
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
        try { fileIo.closeSync(file); } catch (_error) {}
      }
    }
  }
}
