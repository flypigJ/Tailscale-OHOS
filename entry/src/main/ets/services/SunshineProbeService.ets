import { common } from '@kit.AbilityKit';
import {
  SUNSHINE_PROBE_REQUEST_FILE_NAME,
  SUNSHINE_PROBE_RESPONSE_FILE_NAME
} from '@tailscale/common';
import { SunshineProbeResult } from './StreamingModels';
import { PeerProbeCoordinator, PeerProbeRunOptions, PeerRpcRequestPayload, VpnExtensionRpcChannel, VpnRpcRequestOptions, VpnRpcResult } from './VpnExtensionRpcChannel';

const AVAILABLE_CACHE_TTL_MS: number = 60000;
const NEGATIVE_CACHE_TTL_MS: number = 25000;
const TIMEOUT_MS: number = 3500;

interface NativeSunshineProbeResult {
  state: string;
  checkedAt?: number;
  latencyMs?: number;
  serverName?: string;
  serverVersion?: string;
  errorMessage?: string;
}

export class SunshineProbeService {
  private readonly cache: Map<string, SunshineProbeResult> = new Map<string, SunshineProbeResult>();
  private readonly coordinator: PeerProbeCoordinator<SunshineProbeResult> = new PeerProbeCoordinator<SunshineProbeResult>(this.cache);
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

  async probe(peerKey: string, host: string, vpnConnected: boolean,
    force: boolean = false): Promise<SunshineProbeResult> {
    const runOptions: PeerProbeRunOptions<SunshineProbeResult> = {
      checkedAt: (cached: SunshineProbeResult): number => cached.checkedAt,
      cacheTtl: (cached: SunshineProbeResult): number => this.cacheTtl(cached),
      cancelledResult: (): SunshineProbeResult => {
        const result: SunshineProbeResult = { state: 'unknown', checkedAt: Date.now(), errorMessage: 'cancelled' };
        return result;
      },
      disconnectedResult: (): SunshineProbeResult => {
        const result: SunshineProbeResult = { state: 'unknown', checkedAt: Date.now(), errorMessage: 'mesh_disconnected' };
        return result;
      },
      performRpc: (targetPeerKey: string, requestId: number): Promise<string> =>
        this.requestThroughVpnExtension(targetPeerKey, requestId),
      parseResult: (resultText: string): SunshineProbeResult => this.parse(resultText)
    };
    return this.coordinator.runProbe(peerKey, vpnConnected && host.length > 0, force, runOptions);
  }

  private cacheTtl(result: SunshineProbeResult): number {
    return result.state === 'available' ? AVAILABLE_CACHE_TTL_MS : NEGATIVE_CACHE_TTL_MS;
  }

  private async requestThroughVpnExtension(peerKey: string, requestId: number): Promise<string> {
    const payload: PeerRpcRequestPayload = { requestId: requestId, peerKey: peerKey };
    const rpcOptions: VpnRpcRequestOptions = {
      filesDir: this.context.filesDir,
      requestFile: SUNSHINE_PROBE_REQUEST_FILE_NAME,
      responseFile: SUNSHINE_PROBE_RESPONSE_FILE_NAME,
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
      return '{"state":"timeout","errorMessage":"timeout"}';
    }
    return '{"state":"error","errorMessage":"extension_error"}';
  }

  private parse(text: string): SunshineProbeResult {
    try {
      const result: NativeSunshineProbeResult = JSON.parse(text) as NativeSunshineProbeResult;
      const state: string = result.state;
      if (state === 'available' || state === 'unavailable' || state === 'timeout' || state === 'error') {
        return {
          state: state,
          checkedAt: result.checkedAt ?? Date.now(),
          latencyMs: result.latencyMs,
          serverName: result.serverName,
          serverVersion: result.serverVersion,
          errorMessage: result.errorMessage
        };
      }
    } catch (_error) {}
    return { state: 'error', checkedAt: Date.now(), errorMessage: 'invalid_result' };
  }
}
