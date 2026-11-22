import { AccountProfiles } from './AccountProfiles';
import { AtomicFileStore, AtomicWriteOptions } from './AtomicFileStore';
import { ControlServerConfig } from './ControlServerConfig';
import { VpnExtensionRpcChannel, VpnRpcRequestOptions, VpnRpcResult } from './VpnExtensionRpcChannel';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import {
  PreparedTaildriveFile,
  TAILDRIVE_CONTROL_REQUEST_FILE_NAME,
  TAILDRIVE_CONTROL_RESPONSE_FILE_NAME,
  TAILDRIVE_MANUAL_TRANSFER_REQUEST_FILE_NAME,
  TAILDRIVE_MANUAL_TRANSFER_RESPONSE_FILE_NAME,
  TAILDRIVE_QUERY_REQUEST_FILE_NAME,
  TAILDRIVE_QUERY_RESPONSE_FILE_NAME,
  TAILDRIVE_TRANSFER_REQUEST_FILE_NAME,
  TAILDRIVE_TRANSFER_RESPONSE_FILE_NAME,
  TaildriveEntry,
  TaildriveExtensionRequest,
  TaildriveListResult,
  TaildriveMutationRequest,
  TaildriveMutationResult,
  TaildriveStatResult,
  TaildriveTransferRequest,
  TaildriveTransferSnapshot
} from '@tailscale/common';

export {
  PreparedTaildriveFile,
  TaildriveEntry,
  TaildriveExtensionRequest,
  TaildriveListResult,
  TaildriveMutationRequest,
  TaildriveMutationResult,
  TaildriveStatResult,
  TaildriveTransferRequest,
  TaildriveTransferSnapshot
} from '@tailscale/common';

// A cold remote directory query first performs a bounded native TSMP warm-up
// (up to 5 s), then retains the existing 20 s WebDAV request limit.
const TAILDRIVE_QUERY_TIMEOUT_MS: number = 32000;
const TAILDRIVE_MUTATION_TIMEOUT_MS: number = 35000;
const TAILDRIVE_TRANSFER_TIMEOUT_MS: number = 30 * 60 * 1000 + 10000;
const TAILDRIVE_CONTROL_TIMEOUT_MS: number = 5000;

interface TaildrivePathPayload {
  path: string;
}

/** Owns the Taildrive request protocol and app-private staging copies. */
export class TaildriveGateway {
  private context?: common.UIAbilityContext;
  private nextRequestId: number = Date.now();
  private configurationGeneration: number = 0;
  private profileToken: string = '';
  private serverToken: number = 0;
  private serverURL: string = "";
  private queryQueue: Promise<void> = Promise.resolve();
  private transferQueue: Promise<void> = Promise.resolve();
  private manualTransferQueue: Promise<void> = Promise.resolve();
  private controlQueue: Promise<void> = Promise.resolve();
  private activeStagedDirs: Set<string> = new Set<string>();

  configure(context: common.UIAbilityContext): void {
    this.configurationGeneration++;
    this.context = context;
    const settings = ControlServerConfig.load(context.filesDir);
    this.serverToken = settings.updatedAtMs;
    this.serverURL = settings.controlURL;
    this.profileToken = AccountProfiles.token(context.filesDir, settings.controlURL);
  }

  private ownsServer(): boolean {
    if (this.context === undefined) return false;
    const settings = ControlServerConfig.load(this.context.filesDir);
    try {
      return settings.controlURL === this.serverURL && settings.updatedAtMs === this.serverToken &&
        AccountProfiles.token(this.context.filesDir, settings.controlURL) === this.profileToken;
    } catch (_error) { return false; }
  }

  async list(path: string): Promise<TaildriveListResult> {
    const queryPayload: TaildrivePathPayload = { path: path };
    const text: string = await this.requestThroughVpnExtension('query', 'list',
      JSON.stringify(queryPayload), TAILDRIVE_QUERY_TIMEOUT_MS);
    return this.parseList(text);
  }

  async stat(path: string): Promise<TaildriveStatResult> {
    const queryPayload: TaildrivePathPayload = { path: path };
    const text: string = await this.requestThroughVpnExtension('query', 'stat',
      JSON.stringify(queryPayload), TAILDRIVE_QUERY_TIMEOUT_MS);
    return this.parseStat(text);
  }

  async mutate(request: TaildriveMutationRequest): Promise<TaildriveMutationResult> {
    const text: string = await this.requestThroughVpnExtension('query', 'mutate',
      JSON.stringify(request), TAILDRIVE_MUTATION_TIMEOUT_MS);
    return this.parseMutation(text);
  }

  async download(request: TaildriveTransferRequest, manual: boolean = false): Promise<TaildriveTransferSnapshot> {
    const channel: string = manual ? 'manualTransfer' : 'transfer';
    const text: string = await this.requestThroughVpnExtension(channel, 'download',
      JSON.stringify(request), TAILDRIVE_TRANSFER_TIMEOUT_MS);
    return this.parseTransfer(text);
  }

  async upload(request: TaildriveTransferRequest): Promise<TaildriveTransferSnapshot> {
    const text: string = await this.requestThroughVpnExtension('transfer', 'upload',
      JSON.stringify(request), TAILDRIVE_TRANSFER_TIMEOUT_MS);
    return this.parseTransfer(text);
  }

  async transferSnapshot(): Promise<TaildriveTransferSnapshot> {
    const text: string = await this.requestThroughVpnExtension('control', 'snapshot', '',
      TAILDRIVE_CONTROL_TIMEOUT_MS);
    return this.parseTransfer(text);
  }

  async cancel(): Promise<TaildriveTransferSnapshot> {
    const text: string = await this.requestThroughVpnExtension('control', 'cancel', '',
      TAILDRIVE_CONTROL_TIMEOUT_MS);
    return this.parseTransfer(text);
  }

  private async requestThroughVpnExtension(channel: string, operation: string,
    payload: string, timeoutMs: number): Promise<string> {
    const generation: number = this.configurationGeneration;
    return this.enqueue(channel, () => {
      if (generation !== this.configurationGeneration) throw new Error('Taildrive account changed');
      return this.performVpnExtensionRequest(channel, operation, payload, timeoutMs);
    });
  }

  private enqueue(channel: string, task: () => Promise<string>): Promise<string> {
    let release: () => void = () => {};
    let previous: Promise<void>;
    const next: Promise<void> = new Promise<void>((resolve: () => void) => { release = resolve; });
    if (channel === 'transfer') {
      previous = this.transferQueue;
      this.transferQueue = next;
    } else if (channel === 'manualTransfer') {
      previous = this.manualTransferQueue;
      this.manualTransferQueue = next;
    } else if (channel === 'control') {
      previous = this.controlQueue;
      this.controlQueue = next;
    } else {
      previous = this.queryQueue;
      this.queryQueue = next;
    }
    return previous.then(task).finally(() => release());
  }

  private async performVpnExtensionRequest(channel: string, operation: string,
    payload: string, timeoutMs: number): Promise<string> {
    if (this.context === undefined || !this.ownsServer()) {
      throw new Error('Taildrive VPN Extension channel is not configured.');
    }
    const generation: number = this.configurationGeneration;
    this.nextRequestId = Math.max(Date.now(), this.nextRequestId + 1);
    const requestId: number = this.nextRequestId;
    const requestFileName: string = this.requestFile(channel);
    const responseFileName: string = this.responseFile(channel);
    const request: TaildriveExtensionRequest = {
      requestId: requestId,
      operation: operation,
      payload: payload
    };
    const requestJson: string = JSON.stringify(request);
    const shouldAbort = (): string =>
      (generation !== this.configurationGeneration || !this.ownsServer()) ? 'Taildrive server changed' : '';
    const writeFile = (path: string, content: string): boolean => this.writeText(path, content);
    const rpcOptions: VpnRpcRequestOptions = {
      filesDir: this.context.filesDir,
      requestFile: requestFileName,
      responseFile: responseFileName,
      requestId: requestId,
      requestJson: requestJson,
      timeoutMs: timeoutMs,
      pollIntervalMs: 100,
      useMonotonicClock: false,
      checkVpnHeartbeat: timeoutMs >= 15000,
      shouldAbort: shouldAbort,
      writeFile: writeFile
    };
    const rpcResult: VpnRpcResult = await VpnExtensionRpcChannel.request(rpcOptions);
    if (rpcResult.status === 'ok') {
      return rpcResult.result;
    }
    if (rpcResult.status === 'write_failed') {
      throw new Error('Taildrive VPN Extension request failed.');
    }
    if (rpcResult.status === 'aborted') {
      throw new Error(rpcResult.reason ?? 'Taildrive server changed');
    }
    if (rpcResult.status === 'heartbeat_lost') {
      throw new Error('Taildrive VPN Extension heartbeat lost (vpn_heartbeat_lost).');
    }
    throw new Error('Taildrive VPN Extension request timed out.');
  }

  private requestFile(channel: string): string {
    if (channel === 'transfer') {
      return TAILDRIVE_TRANSFER_REQUEST_FILE_NAME;
    }
    if (channel === 'manualTransfer') {
      return TAILDRIVE_MANUAL_TRANSFER_REQUEST_FILE_NAME;
    }
    if (channel === 'control') {
      return TAILDRIVE_CONTROL_REQUEST_FILE_NAME;
    }
    return TAILDRIVE_QUERY_REQUEST_FILE_NAME;
  }

  private responseFile(channel: string): string {
    if (channel === 'transfer') {
      return TAILDRIVE_TRANSFER_RESPONSE_FILE_NAME;
    }
    if (channel === 'manualTransfer') {
      return TAILDRIVE_MANUAL_TRANSFER_RESPONSE_FILE_NAME;
    }
    if (channel === 'control') {
      return TAILDRIVE_CONTROL_RESPONSE_FILE_NAME;
    }
    return TAILDRIVE_QUERY_RESPONSE_FILE_NAME;
  }

  private writeText(path: string, content: string): boolean {
    const writeOpts: AtomicWriteOptions = { owner: 'taildrive-ipc', fsync: false };
    return AtomicFileStore.writeAtomic(path, content, writeOpts);
  }

  async stageUpload(uri: string, root: string, requestId: number): Promise<PreparedTaildriveFile> {
    const requestDir: string = `${root}/${requestId}`;
    if (fileIo.accessSync(requestDir)) {
      throw new Error('Taildrive staging request already exists.');
    }
    fileIo.mkdirSync(requestDir, true);
    this.activeStagedDirs.add(requestDir);
    let source: fileIo.File | undefined = undefined;
    try {
      source = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(source.fd);
      if (!stat.isFile() || stat.size < 0) {
        throw new Error('Selected item is not a regular file.');
      }
      const modifiedAtMs: number = Number.isFinite(stat.mtime) && stat.mtime > 0 ? stat.mtime * 1000 : 0;
      const destination: string = `${requestDir}/upload.taildrive`;
      await fileIo.copyFile(source.fd, destination);
      if (modifiedAtMs > 0) {
        fileIo.utimes(destination, modifiedAtMs);
      }
      const copied: fileIo.Stat = fileIo.lstatSync(destination);
      if (!copied.isFile() || copied.size !== stat.size) {
        throw new Error('Taildrive staging verification failed.');
      }
      return {
        path: destination,
        requestDir: requestDir,
        name: source.name,
        size: copied.size,
        modifiedAtMs: modifiedAtMs
      };
    } catch (_error) {
      this.cleanupStagedDirectory(requestDir);
      throw new Error('Taildrive file staging failed.');
    } finally {
      if (source !== undefined) {
        try {
          fileIo.closeSync(source);
        } catch (_error) {
          // The provider may close the descriptor after a failed copy.
        }
      }
    }
  }

  cleanupStaged(file: PreparedTaildriveFile): void {
    this.cleanupStagedDirectory(file.requestDir);
  }

  cleanupStaleStaging(root: string, maxAgeMs: number = 24 * 60 * 60 * 1000): void {
    try {
      if (!fileIo.accessSync(root)) {
        return;
      }
      const cutoffMs: number = Date.now() - maxAgeMs;
      fileIo.listFileSync(root).forEach((name: string) => {
        const requestDir: string = `${root}/${name}`;
        if (this.activeStagedDirs.has(requestDir)) {
          return;
        }
        try {
          const stat: fileIo.Stat = fileIo.statSync(requestDir);
          const modifiedMs: number = stat.mtime * 1000;
          if (stat.isDirectory() && Number.isFinite(modifiedMs) && modifiedMs > 0 && modifiedMs <= cutoffMs) {
            this.cleanupStagedDirectory(requestDir);
          }
        } catch (_error) {
          // Another cleanup pass may have already removed the request directory.
        }
      });
    } catch (_error) {
      // Cache recovery is best-effort and never blocks remote file access.
    }
  }

  async exportFile(sourcePath: string, destinationUri: string, expectedSize: number): Promise<boolean> {
    if (destinationUri.length === 0) {
      return false;
    }
    let source: fileIo.File | undefined = undefined;
    let destination: fileIo.File | undefined = undefined;
    let verifier: fileIo.File | undefined = undefined;
    let copied: boolean = false;
    try {
      source = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
      destination = this.openExportDestination(destinationUri);
      await fileIo.copyFile(source.fd, destination.fd);
      fileIo.closeSync(source);
      source = undefined;
      fileIo.closeSync(destination);
      destination = undefined;
      verifier = fileIo.openSync(destinationUri, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(verifier.fd);
      copied = stat.isFile() && stat.size === expectedSize;
    } catch (_error) {
      copied = false;
    }
    if (source !== undefined) {
      try { fileIo.closeSync(source); } catch (_error) { copied = false; }
    }
    if (destination !== undefined) {
      try { fileIo.closeSync(destination); } catch (_error) { copied = false; }
    }
    if (verifier !== undefined) {
      try { fileIo.closeSync(verifier); } catch (_error) { copied = false; }
    }
    if (!copied) {
      try { fileIo.unlinkSync(destinationUri); } catch (_error) {
        // A provider may not allow deletion of a failed export URI.
      }
    }
    return copied;
  }

  private openExportDestination(uri: string): fileIo.File {
    try {
      return fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    } catch (_error) {
      return fileIo.openSync(uri,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    }
  }

  private cleanupStagedDirectory(requestDir: string): void {
    this.activeStagedDirs.delete(requestDir);
    try {
      if (!fileIo.accessSync(requestDir)) {
        return;
      }
      fileIo.listFileSync(requestDir).forEach((name: string) => {
        try {
          const itemPath: string = `${requestDir}/${name}`;
          if (fileIo.statSync(itemPath).isFile()) {
            fileIo.unlinkSync(itemPath);
          }
        } catch (_error) {
          // Best-effort cleanup; cache cleanup can retry later.
        }
      });
      fileIo.rmdirSync(requestDir);
    } catch (_error) {
      // Best-effort cleanup; the Go side never treats the staging cache as authoritative.
    }
  }

  private parseList(text: string): TaildriveListResult {
    try {
      const value: TaildriveListResult = JSON.parse(text) as TaildriveListResult;
      if (value === null || typeof value !== 'object' || Array.isArray(value) ||
        typeof value.state !== 'string' || typeof value.path !== 'string' ||
        (value.reason !== undefined && typeof value.reason !== 'string')) {
        throw new Error('Invalid Taildrive list');
      }
      // Go encodes a nil slice as null on early error paths.
      if (value.entries === null) {
        value.entries = [];
      }
      if (!Array.isArray(value.entries) ||
        !value.entries.every((entry: TaildriveEntry) => this.validEntry(entry))) {
        throw new Error('Invalid Taildrive entries');
      }
      value.reason = value.reason ?? '';
      return value;
    } catch (_error) {
      return { state: 'failed', path: '/', entries: [], reason: 'invalid_result' };
    }
  }

  private parseStat(text: string): TaildriveStatResult {
    try {
      const value: TaildriveStatResult = JSON.parse(text) as TaildriveStatResult;
      if (value === null || typeof value !== 'object' || Array.isArray(value) ||
        typeof value.state !== 'string' || !this.validEntry(value.entry) ||
        (value.reason !== undefined && typeof value.reason !== 'string')) {
        throw new Error('Invalid Taildrive stat');
      }
      value.reason = value.reason ?? '';
      return value;
    } catch (_error) {
      return {
        state: 'failed',
        entry: { name: '', path: '', kind: '', size: 0, modifiedAtMs: 0 },
        reason: 'invalid_result'
      };
    }
  }

  private parseMutation(text: string): TaildriveMutationResult {
    try {
      const value: TaildriveMutationResult = JSON.parse(text) as TaildriveMutationResult;
      if (value === null || typeof value !== 'object' || Array.isArray(value) ||
        typeof value.state !== 'string' || typeof value.operation !== 'string' ||
        typeof value.path !== 'string' ||
        (value.newPath !== undefined && typeof value.newPath !== 'string') ||
        (value.reason !== undefined && typeof value.reason !== 'string')) {
        throw new Error('Invalid Taildrive mutation');
      }
      value.newPath = value.newPath ?? '';
      value.reason = value.reason ?? '';
      return value;
    } catch (_error) {
      return { state: 'failed', operation: '', path: '', newPath: '', reason: 'invalid_result' };
    }
  }

  private parseTransfer(text: string): TaildriveTransferSnapshot {
    try {
      const value: TaildriveTransferSnapshot = JSON.parse(text) as TaildriveTransferSnapshot;
      if (value === null || typeof value !== 'object' || Array.isArray(value) ||
        typeof value.state !== 'string' || typeof value.reason !== 'string' ||
        typeof value.direction !== 'string' || typeof value.remotePath !== 'string' ||
        typeof value.localPath !== 'string' || typeof value.fileName !== 'string' ||
        !Number.isFinite(value.requestId) || !Number.isFinite(value.bytes) ||
        !Number.isFinite(value.totalBytes) || !Number.isFinite(value.startedAtMs) ||
        !Number.isFinite(value.completedAtMs)) {
        throw new Error('Invalid Taildrive transfer');
      }
      return value;
    } catch (_error) {
      return {
        requestId: 0, direction: '', state: 'failed', reason: 'invalid_result',
        remotePath: '', localPath: '', fileName: '', bytes: 0, totalBytes: 0,
        startedAtMs: 0, completedAtMs: 0
      };
    }
  }

  private validEntry(value: TaildriveEntry): boolean {
    return value !== null && value !== undefined && typeof value === 'object' && !Array.isArray(value) &&
      typeof value.name === 'string' && typeof value.path === 'string' && typeof value.kind === 'string' &&
      Number.isFinite(value.size) && Number.isFinite(value.modifiedAtMs) &&
      (value.contentType === undefined || typeof value.contentType === 'string') &&
      (value.etag === undefined || typeof value.etag === 'string');
  }
}
