/** Framework-free Taildrop cross-process snapshot, transfer, receive, and history contracts. */

export interface TaildropTargetSummary {
  key: string;
  name: string;
  os: string;
  osVersion?: string;
  deviceModel: string;
  deviceType?: string;
  online: boolean;
}

export interface TaildropWaitingFileSummary {
  name: string;
  size: number;
  receivedAtMs: number;
}

export interface TaildropIncomingFileSummary {
  name: string;
  declaredSize: number;
  received: number;
  startedAtMs: number;
}

export interface TaildropTransferSummary {
  requestId: number;
  state: string;
  reason: string;
  targetKey: string;
  targetName: string;
  fileName: string;
  fileIndex: number;
  fileCount: number;
  fileBytes: number;
  fileSize: number;
  bytesSent: number;
  totalBytes: number;
  previewPath?: string;
  completedAtMs: number;
}

export interface TaildropSnapshot {
  state: string;
  reason: string;
  targets: TaildropTargetSummary[];
  incomingFiles?: TaildropIncomingFileSummary[];
  waitingFiles: TaildropWaitingFileSummary[];
  inboxReason: string;
  transfer: TaildropTransferSummary;
  updatedAtMs?: number;
}

export interface PersistedTaildropSnapshot extends TaildropSnapshot {
  updatedAtMs: number;
}

export interface TaildropSendFile {
  path: string;
  name: string;
  size: number;
  previewPath?: string;
}

export interface TaildropSendRequest {
  requestId: number;
  targetKey: string;
  outboxRoot: string;
  files: TaildropSendFile[];
}

export interface TaildropCancelRequest {
  requestId: number;
}

export interface TaildropReceiveRequest {
  requestId: number;
  action: string;
  name: string;
  inboxRoot: string;
  path: string;
}

export interface TaildropReceiveResult {
  requestId: number;
  action: string;
  state: string;
  reason: string;
  name: string;
  size: number;
  path: string;
}

export interface TaildropTransferRecord {
  requestId: number;
  direction: string;
  state: string;
  reason: string;
  targetKey: string;
  targetName: string;
  fileName: string;
  fileCount: number;
  totalBytes: number;
  previewPath: string;
  completedAtMs: number;
}

export function emptyTaildropTransfer(): TaildropTransferSummary {
  const summary: TaildropTransferSummary = {
    requestId: 0,
    state: 'idle',
    reason: '',
    targetKey: '',
    targetName: '',
    fileName: '',
    fileIndex: 0,
    fileCount: 0,
    fileBytes: 0,
    fileSize: 0,
    bytesSent: 0,
    totalBytes: 0,
    previewPath: '',
    completedAtMs: 0
  };
  return summary;
}
