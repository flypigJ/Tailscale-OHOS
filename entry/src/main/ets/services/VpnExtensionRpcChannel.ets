import { fileIo } from '@kit.CoreFileKit';
import { systemDateTime } from '@kit.BasicServicesKit';
import { VPN_PROBE_STATUS_FILE_NAME } from '@tailscale/common';
import { AtomicFileStore, AtomicWriteOptions } from './AtomicFileStore';

const DEFAULT_MAX_RESPONSE_BYTES: number = 512 * 1024;
const DEFAULT_MAX_REQUEST_BYTES: number = 64 * 1024;
const MAX_OWNERSHIP_CHECK_BYTES: number = 128 * 1024;
const HEARTBEAT_CHECK_MIN_TIMEOUT_MS: number = 15000;
const HEARTBEAT_STALE_THRESHOLD_MS: number = 20000;
const VPN_STATUS_MAX_BYTES: number = 8192;

export type VpnRpcStatus =
  'ok' | 'timeout' | 'write_failed' | 'aborted' | 'heartbeat_lost' | 'clock_error';

export interface VpnRpcResult {
  status: VpnRpcStatus;
  result: string;
  reason?: string;
}

export interface VpnRpcRequestOptions {
  filesDir: string;
  requestFile: string;
  responseFile: string;
  requestId: number;
  requestJson: string;
  timeoutMs: number;
  pollIntervalMs: number;
  useMonotonicClock: boolean;
  maxResponseBytes?: number;
  checkVpnHeartbeat?: boolean;
  shouldAbort?: () => string;
  writeFile?: (path: string, content: string) => boolean;
}

export interface PeerRpcRequestPayload {
  requestId: number;
  peerKey: string;
}

export interface VpnRpcResponsePayload {
  requestId: number;
  result: string;
}

export interface VpnRawRpcEnvelope {
  requestId: number;
  rawText: string;
  parseError?: boolean;
}

export interface PeerProbeRunOptions<T> {
  checkedAt: (cached: T) => number;
  cacheTtl: (cached: T) => number;
  cancelledResult: () => T;
  disconnectedResult: () => T;
  performRpc: (peerKey: string, requestId: number) => Promise<string>;
  parseResult: (rawResult: string) => T;
}

interface RawRpcEnvelopeCandidate {
  requestId?: number;
}

interface RawRpcResponseCandidate {
  requestId?: number;
  result?: string;
}

interface InFlightProbeEntry<T> {
  generation: number;
  promise: Promise<T>;
}

/**
 * Atomic file-backed cross-process RPC client between the UI process and
 * TailscaleVpnExtensionAbility. Eliminates partial O_TRUNC JSON observations
 * and fast-fails long transfers when the VPN Extension heartbeat disappears.
 */
export class VpnExtensionRpcChannel {
  static async request(options: VpnRpcRequestOptions): Promise<VpnRpcResult> {
    const requestPath: string = `${options.filesDir}/${options.requestFile}`;
    const responsePath: string = `${options.filesDir}/${options.responseFile}`;
    const maxResponseBytes: number = options.maxResponseBytes ?? DEFAULT_MAX_RESPONSE_BYTES;
    try {
      VpnExtensionRpcChannel.clearIpcFile(responsePath, options.writeFile);
      if (!VpnExtensionRpcChannel.writeIpcFile(requestPath, options.requestJson, 'rpc-req', options.writeFile)) {
        const writeFailure: VpnRpcResult = { status: 'write_failed', result: '', reason: 'write_failed' };
        return writeFailure;
      }
      let startedAt: number = 0;
      try {
        startedAt = VpnExtensionRpcChannel.readClockMs(options.useMonotonicClock);
      } catch (_clockInitError) {
        const clockError: VpnRpcResult = { status: 'clock_error', result: '', reason: 'clock_error' };
        return clockError;
      }
      while (VpnExtensionRpcChannel.readClockMs(options.useMonotonicClock) - startedAt < options.timeoutMs) {
        await new Promise<void>((resolve: () => void) => setTimeout(resolve, options.pollIntervalMs));
        if (options.shouldAbort !== undefined) {
          let abortReason: string = '';
          try {
            abortReason = options.shouldAbort();
          } catch (_abortCheckError) {
            abortReason = 'aborted';
          }
          if (abortReason.length > 0) {
            const abortedResult: VpnRpcResult = { status: 'aborted', result: '', reason: abortReason };
            return abortedResult;
          }
        }
        if (VpnExtensionRpcChannel.readClockMs(options.useMonotonicClock) - startedAt >= options.timeoutMs) {
          break;
        }
        if (options.checkVpnHeartbeat === true && options.timeoutMs >= HEARTBEAT_CHECK_MIN_TIMEOUT_MS &&
          VpnExtensionRpcChannel.isVpnHeartbeatLost(options.filesDir)) {
          VpnExtensionRpcChannel.clearRequestIfOwned(requestPath, options.requestId, options.writeFile);
          const heartbeatLost: VpnRpcResult = {
            status: 'heartbeat_lost',
            result: '',
            reason: 'vpn_heartbeat_lost'
          };
          return heartbeatLost;
        }
        const rawResponse: string | undefined = VpnExtensionRpcChannel.readBoundedText(
          responsePath, maxResponseBytes);
        if (rawResponse === undefined) {
          continue;
        }
        const trimmedResponse: string = rawResponse.trim();
        if (trimmedResponse.length === 0) {
          continue;
        }
        try {
          const parsed: RawRpcResponseCandidate = JSON.parse(trimmedResponse) as RawRpcResponseCandidate;
          if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed) ||
            parsed.requestId !== options.requestId || typeof parsed.result !== 'string') {
            continue;
          }
          VpnExtensionRpcChannel.clearIpcFile(responsePath, options.writeFile);
          VpnExtensionRpcChannel.clearRequestIfOwned(requestPath, options.requestId, options.writeFile);
          const okResult: VpnRpcResult = { status: 'ok', result: parsed.result };
          return okResult;
        } catch (_transientParseError) {
          continue;
        }
      }
      VpnExtensionRpcChannel.clearRequestIfOwned(requestPath, options.requestId, options.writeFile);
      const timeoutResult: VpnRpcResult = { status: 'timeout', result: '', reason: 'timeout' };
      return timeoutResult;
    } catch (_unexpectedError) {
      const errorResult: VpnRpcResult = { status: 'clock_error', result: '', reason: 'extension_error' };
      return errorResult;
    }
  }

  static readBoundedText(path: string, maxBytes: number): string | undefined {
    try {
      if (typeof fileIo.accessSync === 'function' && !fileIo.accessSync(path)) {
        return undefined;
      }
      if (typeof fileIo.statSync === 'function') {
        return AtomicFileStore.readTextBounded(path, maxBytes);
      }
      const text: string = fileIo.readTextSync(path);
      if (AtomicFileStore.utf8ByteLength(text) > maxBytes) {
        return undefined;
      }
      return text;
    } catch (_error) {
      return undefined;
    }
  }

  static unlinkBestEffort(path: string): void {
    try {
      if (typeof fileIo.accessSync === 'function' && !fileIo.accessSync(path)) {
        return;
      }
      if (typeof fileIo.unlinkSync === 'function') {
        fileIo.unlinkSync(path);
        return;
      }
      const unlinkFallbackOpts: AtomicWriteOptions = { owner: 'rpc-unlink', fsync: false };
      AtomicFileStore.writeAtomic(path, '', unlinkFallbackOpts);
    } catch (_error) {
    }
  }

  private static clearRequestIfOwned(path: string, expectedRequestId: number,
    writeFile?: (targetPath: string, content: string) => boolean): void {
    const rawCurrent: string | undefined = VpnExtensionRpcChannel.readBoundedText(
      path, MAX_OWNERSHIP_CHECK_BYTES);
    if (rawCurrent !== undefined) {
      const trimmedCurrent: string = rawCurrent.trim();
      if (trimmedCurrent.length > 0) {
        try {
          const candidate: RawRpcEnvelopeCandidate = JSON.parse(trimmedCurrent) as RawRpcEnvelopeCandidate;
          if (candidate !== null && typeof candidate === 'object' && !Array.isArray(candidate) &&
            typeof candidate.requestId === 'number' && candidate.requestId !== expectedRequestId) {
            return;
          }
        } catch (_parseError) {
        }
      }
    }
    VpnExtensionRpcChannel.clearIpcFile(path, writeFile);
  }

  private static clearIpcFile(path: string,
    writeFile?: (targetPath: string, content: string) => boolean): void {
    if (writeFile !== undefined) {
      try {
        writeFile(path, '');
      } catch (_writeError) {
      }
      return;
    }
    const clearOpts: AtomicWriteOptions = { owner: 'rpc-clear', fsync: false };
    AtomicFileStore.writeAtomic(path, '', clearOpts);
  }

  private static writeIpcFile(path: string, content: string, owner: string,
    writeFile?: (targetPath: string, text: string) => boolean): boolean {
    if (writeFile !== undefined) {
      try {
        return writeFile(path, content);
      } catch (_writeError) {
        return false;
      }
    }
    const writeOpts: AtomicWriteOptions = { owner: owner, fsync: false };
    return AtomicFileStore.writeAtomic(path, content, writeOpts);
  }

  private static readClockMs(useMonotonicClock: boolean): number {
    if (useMonotonicClock) {
      return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false);
    }
    return Date.now();
  }

  private static isVpnHeartbeatLost(filesDir: string): boolean {
    const statusPath: string = `${filesDir}/${VPN_PROBE_STATUS_FILE_NAME}`;
    const rawStatus: string | undefined = VpnExtensionRpcChannel.readBoundedText(
      statusPath, VPN_STATUS_MAX_BYTES);
    if (rawStatus === undefined) {
      return false;
    }
    const trimmed: string = rawStatus.trim();
    if (trimmed.length === 0) {
      return false;
    }
    const normalizedLower: string = trimmed.toLowerCase();
    if (trimmed.startsWith('FAILED') || trimmed.includes('state=Stopped') ||
      trimmed.startsWith('VPN extension destroyed') || trimmed.startsWith('VPN disconnected') ||
      normalizedLower.startsWith('harmonyos vpn extension stopped')) {
      return true;
    }
    const match: RegExpMatchArray | null = trimmed.match(/\bheartbeatMs=(\d+)\b/);
    if (match === null) {
      return false;
    }
    const heartbeatMs: number = Number(match[1]);
    const nowMs: number = Date.now();
    if (!Number.isSafeInteger(heartbeatMs) || heartbeatMs <= 0 || !Number.isFinite(nowMs)) {
      return false;
    }
    return nowMs - heartbeatMs > HEARTBEAT_STALE_THRESHOLD_MS;
  }
}

/**
 * Server-side RPC consumer and atomic responder for TailscaleVpnExtensionAbility.
 * Deduplicates incoming requests by requestId in memory rather than truncating
 * request files in place, preventing a newer atomic rename from being wiped out.
 */
export class VpnExtensionRpcServer {
  private readonly lastConsumedRequestIds: Map<string, number> = new Map<string, number>();

  resetAll(filesDir: string, fileNames: string[]): void {
    this.lastConsumedRequestIds.clear();
    for (const fileName of fileNames) {
      const cleanName: string = fileName.trim();
      if (cleanName.length === 0 || cleanName.includes('/')) {
        continue;
      }
      VpnExtensionRpcChannel.unlinkBestEffort(`${filesDir}/${cleanName}`);
      AtomicFileStore.cleanupTempSiblings(filesDir, cleanName);
    }
  }

  peekRawRequest(filesDir: string, requestFile: string,
    maxBytes: number = DEFAULT_MAX_REQUEST_BYTES): VpnRawRpcEnvelope | undefined {
    const requestPath: string = `${filesDir}/${requestFile}`;
    let rawText: string | undefined = undefined;
    try {
      if (typeof fileIo.accessSync === 'function' && !fileIo.accessSync(requestPath)) {
        this.lastConsumedRequestIds.delete(requestFile);
        return undefined;
      }
      if (typeof fileIo.statSync === 'function') {
        const size: number = fileIo.statSync(requestPath).size;
        if (!Number.isSafeInteger(size) || size < 0 || size > maxBytes) {
          VpnExtensionRpcChannel.unlinkBestEffort(requestPath);
          this.lastConsumedRequestIds.delete(requestFile);
          const oversizedError: VpnRawRpcEnvelope = { requestId: 0, rawText: '', parseError: true };
          return oversizedError;
        }
        if (size === 0) {
          this.lastConsumedRequestIds.delete(requestFile);
          return undefined;
        }
      }
      rawText = fileIo.readTextSync(requestPath);
      if (AtomicFileStore.utf8ByteLength(rawText) > maxBytes) {
        VpnExtensionRpcChannel.unlinkBestEffort(requestPath);
        this.lastConsumedRequestIds.delete(requestFile);
        const limitError: VpnRawRpcEnvelope = { requestId: 0, rawText: '', parseError: true };
        return limitError;
      }
    } catch (_ioError) {
      return undefined;
    }
    const trimmed: string = rawText.trim();
    if (trimmed.length === 0) {
      this.lastConsumedRequestIds.delete(requestFile);
      return undefined;
    }
    let parsed: RawRpcEnvelopeCandidate;
    try {
      parsed = JSON.parse(trimmed) as RawRpcEnvelopeCandidate;
    } catch (_parseError) {
      VpnExtensionRpcChannel.unlinkBestEffort(requestPath);
      this.lastConsumedRequestIds.delete(requestFile);
      const malformedError: VpnRawRpcEnvelope = { requestId: 0, rawText: '', parseError: true };
      return malformedError;
    }
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      VpnExtensionRpcChannel.unlinkBestEffort(requestPath);
      this.lastConsumedRequestIds.delete(requestFile);
      const nonObjectError: VpnRawRpcEnvelope = { requestId: 0, rawText: '', parseError: true };
      return nonObjectError;
    }
    if (typeof parsed.requestId !== 'number' || !Number.isSafeInteger(parsed.requestId) ||
      parsed.requestId <= 0) {
      VpnExtensionRpcChannel.unlinkBestEffort(requestPath);
      this.lastConsumedRequestIds.delete(requestFile);
      const invalidIdEnvelope: VpnRawRpcEnvelope = { requestId: 0, rawText: trimmed };
      return invalidIdEnvelope;
    }
    if (this.lastConsumedRequestIds.get(requestFile) === parsed.requestId) {
      return undefined;
    }
    this.lastConsumedRequestIds.set(requestFile, parsed.requestId);
    const envelope: VpnRawRpcEnvelope = { requestId: parsed.requestId, rawText: trimmed };
    return envelope;
  }

  writeResponse(filesDir: string, responseFile: string, requestId: number, result: string): boolean {
    const payload: VpnRpcResponsePayload = { requestId: requestId, result: result };
    const writeOpts: AtomicWriteOptions = { owner: 'rpc-resp', fsync: false };
    return AtomicFileStore.writeAtomic(
      `${filesDir}/${responseFile}`,
      JSON.stringify(payload),
      writeOpts
    );
  }
}

/**
 * Shared probe FIFO serializer, generation-based cancellation, monotonic requestId
 * allocator, and non-forced in-flight request coalescer for peer probe services.
 */
export class PeerProbeCoordinator<T> {
  private readonly cache: Map<string, T>;
  private readonly requestIds: Map<string, number> = new Map<string, number>();
  private readonly inFlight: Map<string, InFlightProbeEntry<T>> = new Map<string, InFlightProbeEntry<T>>();
  private queue: Promise<void> = Promise.resolve();
  private lastExtensionRequestId: number = 0;

  constructor(cache: Map<string, T>) {
    this.cache = cache;
  }

  clearCache(peerKey?: string): void {
    if (peerKey === undefined) {
      this.cache.clear();
      this.inFlight.clear();
      this.requestIds.forEach((_generation: number, key: string) => this.cancel(key));
      return;
    }
    this.cache.delete(peerKey);
    this.cancel(peerKey);
  }

  cancel(peerKey: string): void {
    this.inFlight.delete(peerKey);
    this.requestIds.set(peerKey, (this.requestIds.get(peerKey) ?? 0) + 1);
  }

  nextExtensionRequestId(): number {
    this.lastExtensionRequestId = Math.max(Date.now(), this.lastExtensionRequestId + 1);
    return this.lastExtensionRequestId;
  }

  runProbe(peerKey: string, eligibleForCache: boolean, force: boolean,
    options: PeerProbeRunOptions<T>): Promise<T> {
    // Cancellation belongs to enqueue time; ordinary FIFO jobs share the epoch.
    const generation: number = this.requestIds.get(peerKey) ?? 0;
    this.requestIds.set(peerKey, generation);
    if (eligibleForCache && !force) {
      const existing: InFlightProbeEntry<T> | undefined = this.inFlight.get(peerKey);
      if (existing !== undefined && existing.generation === generation) {
        return existing.promise;
      }
    }
    const taskPromise: Promise<T> = this.enqueue((): Promise<T> =>
      this.executeProbe(peerKey, eligibleForCache, force, generation, options));
    if (eligibleForCache && !force) {
      const entry: InFlightProbeEntry<T> = { generation: generation, promise: taskPromise };
      this.inFlight.set(peerKey, entry);
      const clearInFlight = (): void => {
        const current: InFlightProbeEntry<T> | undefined = this.inFlight.get(peerKey);
        if (current !== undefined && current.promise === taskPromise) {
          this.inFlight.delete(peerKey);
        }
      };
      taskPromise.then((): void => clearInFlight(), (): void => clearInFlight());
    }
    return taskPromise;
  }

  private async executeProbe(peerKey: string, eligibleForCache: boolean, force: boolean,
    requestGeneration: number, options: PeerProbeRunOptions<T>): Promise<T> {
    if (this.requestIds.get(peerKey) !== requestGeneration) {
      return options.cancelledResult();
    }
    if (!eligibleForCache) {
      this.cache.delete(peerKey);
      return options.disconnectedResult();
    }
    const cached: T | undefined = this.cache.get(peerKey);
    if (!force && cached !== undefined) {
      const age: number = Date.now() - options.checkedAt(cached);
      if (age >= 0 && age < options.cacheTtl(cached)) {
        return cached;
      }
    }
    const resultText: string = await options.performRpc(peerKey, this.nextExtensionRequestId());
    if (this.requestIds.get(peerKey) !== requestGeneration) {
      return options.cancelledResult();
    }
    const parsed: T = options.parseResult(resultText);
    this.cache.set(peerKey, parsed);
    return parsed;
  }

  private enqueue(task: () => Promise<T>): Promise<T> {
    let release: () => void = () => {};
    const previous: Promise<void> = this.queue;
    this.queue = new Promise<void>((resolve: () => void) => { release = resolve; });
    return previous.then(task).finally(() => release());
  }
}
