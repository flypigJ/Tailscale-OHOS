import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { SunshineProbeResult } from './StreamingModels';

const REQUEST_FILE: string = 'sunshine-probe-request.json';
const RESPONSE_FILE: string = 'sunshine-probe-response.json';
const AVAILABLE_CACHE_TTL_MS: number = 60000;
const NEGATIVE_CACHE_TTL_MS: number = 25000;
const TIMEOUT_MS: number = 3500;

interface SunshineProbeResponse {
  requestId: number;
  result: string;
}

interface NativeSunshineProbeResult {
  state: string;
  checkedAt?: number;
  latencyMs?: number;
  serverName?: string;
  serverVersion?: string;
  errorMessage?: string;
}

export class SunshineProbeService {
  private readonly cache: Map<string, SunshineProbeResult> = new Map();
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

  async probe(peerKey: string, host: string, vpnConnected: boolean,
    force: boolean = false): Promise<SunshineProbeResult> {
    return this.enqueue(() => this.probeInternal(peerKey, host, vpnConnected, force));
  }

  private async probeInternal(peerKey: string, host: string, vpnConnected: boolean,
    force: boolean): Promise<SunshineProbeResult> {
    const cached: SunshineProbeResult | undefined = this.cache.get(peerKey);
    if (!force && cached !== undefined && Date.now() - cached.checkedAt < this.cacheTtl(cached)) {
      return cached;
    }
    if (!vpnConnected || host.length === 0) {
      return { state: 'unknown', checkedAt: Date.now(), errorMessage: 'mesh_disconnected' };
    }
    const requestGeneration: number = (this.requestIds.get(peerKey) ?? 0) + 1;
    this.requestIds.set(peerKey, requestGeneration);
    const resultText: string = await this.requestThroughVpnExtension(peerKey, Date.now());
    if (this.requestIds.get(peerKey) !== requestGeneration) {
      return { state: 'unknown', checkedAt: Date.now(), errorMessage: 'cancelled' };
    }
    const parsed: SunshineProbeResult = this.parse(resultText);
    this.cache.set(peerKey, parsed);
    return parsed;
  }

  private enqueue(task: () => Promise<SunshineProbeResult>): Promise<SunshineProbeResult> {
    let release: () => void = () => {};
    const previous: Promise<void> = this.queue;
    this.queue = new Promise<void>((resolve: () => void) => { release = resolve; });
    return previous.then(task).finally(() => release());
  }

  private cacheTtl(result: SunshineProbeResult): number {
    return result.state === 'available' ? AVAILABLE_CACHE_TTL_MS : NEGATIVE_CACHE_TTL_MS;
  }

  private async requestThroughVpnExtension(peerKey: string, requestId: number): Promise<string> {
    const responsePath: string = `${this.context.filesDir}/${RESPONSE_FILE}`;
    const requestPath: string = `${this.context.filesDir}/${REQUEST_FILE}`;
    try {
      this.writeText(responsePath, '');
      if (!this.writeText(requestPath, JSON.stringify({ requestId: requestId, peerKey: peerKey }))) {
        return '{"state":"error","errorMessage":"extension_error"}';
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
        const response: SunshineProbeResponse = JSON.parse(responseText) as SunshineProbeResponse;
        if (response.requestId !== requestId) {
          continue;
        }
        this.writeText(responsePath, '');
        return response.result;
      }
      return '{"state":"timeout","errorMessage":"timeout"}';
    } catch (_error) {
      return '{"state":"error","errorMessage":"extension_error"}';
    }
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

  private writeText(path: string, content: string): boolean {
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
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
