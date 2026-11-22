import { common } from '@kit.AbilityKit';
import {
  MEDIA_SERVICE_PROBE_REQUEST_FILE_NAME,
  MEDIA_SERVICE_PROBE_RESPONSE_FILE_NAME
} from '@tailscale/common';
import { DiscoveredMediaService, MediaProbeResult, MediaProbeState, MediaServiceType } from './MediaIntegrationModels';
import { PeerProbeCoordinator, PeerProbeRunOptions, PeerRpcRequestPayload, VpnExtensionRpcChannel, VpnRpcRequestOptions, VpnRpcResult } from './VpnExtensionRpcChannel';

const AVAILABLE_CACHE_TTL_MS: number = 5 * 60 * 1000;
const NEGATIVE_CACHE_TTL_MS: number = 60 * 1000;
// The native probe runs its three default-port checks concurrently under a
// 2.5-second deadline. Leave a small IPC margin without holding the entire
// device-details refresh spinner for the old 5.5-second worst case.
const TIMEOUT_MS: number = 4000;

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
  private readonly cache: Map<string, MediaProbeResult> = new Map<string, MediaProbeResult>();
  private readonly coordinator: PeerProbeCoordinator<MediaProbeResult> = new PeerProbeCoordinator<MediaProbeResult>(this.cache);
  private readonly context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  clearCache(peerKey?: string): void {
    this.coordinator.clearCache(peerKey);
  }

  cancel(peerKey: string): void {
    this.coordinator.cancel(peerKey);
  }

  async probe(peerKey: string, vpnConnected: boolean, force: boolean = false): Promise<MediaProbeResult> {
    const runOptions: PeerProbeRunOptions<MediaProbeResult> = {
      checkedAt: (cached: MediaProbeResult): number => cached.checkedAt,
      cacheTtl: (cached: MediaProbeResult): number => this.cacheTtl(cached),
      cancelledResult: (): MediaProbeResult => this.emptyResult('unknown', 'cancelled'),
      disconnectedResult: (): MediaProbeResult => this.emptyResult('unknown', 'mesh_disconnected'),
      performRpc: (targetPeerKey: string, requestId: number): Promise<string> =>
        this.requestThroughVpnExtension(targetPeerKey, requestId),
      parseResult: (resultText: string): MediaProbeResult => this.parse(resultText)
    };
    return this.coordinator.runProbe(peerKey, vpnConnected, force, runOptions);
  }

  private cacheTtl(result: MediaProbeResult): number {
    return result.state === 'available' ? AVAILABLE_CACHE_TTL_MS : NEGATIVE_CACHE_TTL_MS;
  }

  private async requestThroughVpnExtension(peerKey: string, requestId: number): Promise<string> {
    const payload: PeerRpcRequestPayload = { requestId: requestId, peerKey: peerKey };
    const rpcOptions: VpnRpcRequestOptions = {
      filesDir: this.context.filesDir,
      requestFile: MEDIA_SERVICE_PROBE_REQUEST_FILE_NAME,
      responseFile: MEDIA_SERVICE_PROBE_RESPONSE_FILE_NAME,
      requestId: requestId,
      requestJson: JSON.stringify(payload),
      timeoutMs: TIMEOUT_MS,
      pollIntervalMs: 150,
      useMonotonicClock: true
    };
    const rpc: VpnRpcResult = await VpnExtensionRpcChannel.request(rpcOptions);
    if (rpc.status === 'ok') {
      return rpc.result;
    }
    if (rpc.status === 'timeout') {
      return '{"state":"timeout","services":[],"errorMessage":"timeout"}';
    }
    return '{"state":"error","services":[],"errorMessage":"extension_error"}';
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
}
