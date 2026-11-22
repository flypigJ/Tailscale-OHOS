/** Framework-free Taildrive cross-process RPC and remote directory contracts. */

export interface TaildriveExtensionRequest {
  requestId: number;
  operation: string;
  payload: string;
}

export interface TaildriveEntry {
  name: string;
  path: string;
  kind: string;
  size: number;
  modifiedAtMs: number;
  contentType?: string;
  etag?: string;
}

export interface TaildriveListResult {
  state: string;
  path: string;
  entries: TaildriveEntry[];
  reason: string;
}

export interface TaildriveStatResult {
  state: string;
  entry: TaildriveEntry;
  reason: string;
}

export interface TaildriveMutationRequest {
  operation: string;
  path: string;
  newPath?: string;
  overwrite?: boolean;
}

export interface TaildriveMutationResult {
  state: string;
  operation: string;
  path: string;
  newPath: string;
  reason: string;
}

export interface TaildriveTransferRequest {
  requestId: number;
  remotePath: string;
  localRoot: string;
  localPath: string;
  sourceModifiedAtMs?: number;
  overwrite?: boolean;
}

export interface TaildriveTransferSnapshot {
  requestId: number;
  direction: string;
  state: string;
  reason: string;
  remotePath: string;
  localPath: string;
  fileName: string;
  bytes: number;
  totalBytes: number;
  startedAtMs: number;
  completedAtMs: number;
}

export interface PreparedTaildriveFile {
  path: string;
  requestDir: string;
  name: string;
  size: number;
  modifiedAtMs: number;
}
