import { common } from '@kit.AbilityKit';
import {
  ConnectionPathType,
  PEER_CONNECTIVITY_REQUEST_FILE_NAME,
  PEER_CONNECTIVITY_RESPONSE_FILE_NAME,
  PeerPathResult
} from '@tailscale/common';
import { PeerProbeCoordinator, PeerProbeRunOptions, PeerRpcRequestPayload, VpnExtensionRpcChannel, VpnRpcRequestOptions, VpnRpcResult } from './VpnExtensionRpcChannel';

const CACHE_TTL_MS: number = 25000;
// Native discovery has a shared ten-second budget including status lookup.
const TIMEOUT_MS: number = 12000;
const TRANSIENT_CACHE_TTL_MS: number = 3000;

interface NativePeerPathResult {
  state: string;
  reason: string;
  pathType?: string;
  latencyMs?: number;
  relayRegion?: string;
}

export class PeerPathService {
  private readonly cache: Map<string, PeerPathResult> = new Map<string, PeerPathResult>();
  private readonly coordinator: PeerProbeCoordinator<PeerPathResult> = new PeerProbeCoordinator<PeerPathResult>(this.cache);
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

  async probe(peerKey: string, vpnConnected: boolean, force: boolean = false): Promise<PeerPathResult> {
    const runOptions: PeerProbeRunOptions<PeerPathResult> = {
      checkedAt: (cached: PeerPathResult): number => cached.checkedAt,
      cacheTtl: (cached: PeerPathResult): number =>
        cached.type === 'direct' ? CACHE_TTL_MS : TRANSIENT_CACHE_TTL_MS,
      cancelledResult: (): PeerPathResult => {
        const result: PeerPathResult = { type: 'unknown', checkedAt: Date.now(), errorMessage: 'cancelled' };
        return result;
      },
      disconnectedResult: (): PeerPathResult => {
        const result: PeerPathResult = { type: 'unknown', checkedAt: Date.now(), errorMessage: 'mesh_disconnected' };
        return result;
      },
      performRpc: (targetPeerKey: string, requestId: number): Promise<string> =>
        this.requestThroughVpnExtension(targetPeerKey, requestId),
      parseResult: (resultText: string): PeerPathResult => this.parse(resultText)
    };
    return this.coordinator.runProbe(peerKey, vpnConnected, force, runOptions);
  }

  private async requestThroughVpnExtension(peerKey: string, requestId: number): Promise<string> {
    const payload: PeerRpcRequestPayload = { requestId: requestId, peerKey: peerKey };
    const rpcOptions: VpnRpcRequestOptions = {
      filesDir: this.context.filesDir,
      requestFile: PEER_CONNECTIVITY_REQUEST_FILE_NAME,
      responseFile: PEER_CONNECTIVITY_RESPONSE_FILE_NAME,
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
      return '{"state":"failed","reason":"timeout"}';
    }
    return '{"state":"failed","reason":"extension_error"}';
  }

  private parse(text: string): PeerPathResult {
    try {
      const result: NativePeerPathResult = JSON.parse(text) as NativePeerPathResult;
      const checkedAt: number = Date.now();
      if (result.state !== 'reachable' && result.state !== 'degraded') {
        const unreachable: boolean = result.reason === 'no_response' || result.reason === 'peer_offline' ||
          result.reason === 'peer_not_found';
        return {
          type: unreachable ? 'unreachable' : 'unknown',
          checkedAt: checkedAt,
          errorMessage: result.reason
        };
      }
      return {
        type: this.pathType(result.pathType),
        latencyMs: result.latencyMs,
        relayRegion: result.relayRegion,
        checkedAt: checkedAt
      };
    } catch (_error) {
      return { type: 'unknown', checkedAt: Date.now(), errorMessage: 'invalid_result' };
    }
  }

  private pathType(value?: string): ConnectionPathType {
    if (value === 'direct' || value === 'peerRelay' || value === 'derp' || value === 'unreachable') {
      return value;
    }
    return 'unknown';
  }
}
