import nativeBridge from 'libtailscale_ohos.so';
import { common } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { media } from '@kit.MediaKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { createLocalTextPasteData } from './AppShellIntentAdapter';
import { RecoverableCachePaths } from './RecoverableCachePaths';
import { TaildropContentGateway } from './TaildropContentGateway';
import {
  TaildropNotificationActionRequest,
  TaildropReceiveGateway,
  TaildropReceiveRequest,
  TaildropReceiveResult
} from './TaildropReceiveGateway';
import { PreparedTaildropFile, TaildropSendGateway } from './TaildropSendGateway';
import {
  IMAGE_FILE_EXTENSIONS,
  TAILDROP_CANCEL_REQUEST_FILE_NAME,
  TAILDROP_HISTORY_FILE_NAME,
  TAILDROP_HISTORY_MEDIA_DIR_NAME,
  TAILDROP_INBOX_DIR_NAME,
  TAILDROP_INBOX_SNAPSHOT_FILE_NAME,
  TAILDROP_RECEIVE_REQUEST_FILE_NAME,
  TAILDROP_RECEIVE_RESPONSE_FILE_NAME,
  TAILDROP_SEND_REQUEST_FILE_NAME,
  TAILDROP_TARGETS_FILE_NAME,
  TAILDROP_TEXT_CLIPBOARD_MAX_BYTES,
  TaildropCancelRequest,
  TaildropSendFile,
  TaildropSendRequest,
  TaildropSnapshot,
  TaildropTargetSummary,
  TaildropTransferRecord,
  TaildropTransferSummary,
  TaildropWaitingFileSummary,
  VIDEO_FILE_EXTENSIONS,
  classifyFileContentKind,
  emptyTaildropTransfer,
  extractFileExtension
} from '@tailscale/common';

const TAILDROP_SNAPSHOT_FRESH_MS: number = 10000;
const TAILDROP_CACHE_RETENTION_MS: number = 7 * 24 * 60 * 60 * 1000;
const TAILDROP_CACHE_EXPIRATION_CHECK_INTERVAL_MS: number = 60 * 60 * 1000;
const TAILDROP_THUMBNAIL_EDGE_PX: number = 128;
const TAILDROP_THUMBNAIL_JPEG_QUALITY: number = 72;
const TAILDROP_HISTORY_LIMIT: number = 10;
const TAILDROP_MAX_FILE_SELECTION: number = 10;
const TAILDROP_MAX_MEDIA_SELECTION: number = 100;
const TAILDROP_RECEIVE_BACKEND_TIMEOUT_MS: number = 45000;
const TAILDROP_SAVE_TIMEOUT_MS: number = 60000;
const TAILDROP_PENDING_DELETE_RETRY_MS: number = 5000;
const TAILDROP_MEDIA_MIN_TIMESTAMP_MS: number = 946684800000;
const TAILDROP_MEDIA_MAX_FUTURE_MS: number = 24 * 60 * 60 * 1000;
const TAILDROP_MEDIA_MAX_DURATION_MS: number = 24 * 60 * 60 * 1000;

export interface TaildropMediaPreview {
  requestId: number;
  name: string;
  size: number;
  path: string;
  thumbnailPath: string;
  mediaType: photoAccessHelper.PhotoType;
}

export interface TaildropCachedFile {
  requestId: number;
  name: string;
  size: number;
  path: string;
}

export interface PersistedTaildropHistory {
  records: TaildropTransferRecord[];
}

export interface PersistedTaildropInbox {
  files: TaildropWaitingFileSummary[];
  inboxReason: string;
  mediaPreviews?: TaildropMediaPreview[];
  cachedFiles?: TaildropCachedFile[];
  pendingDeletes?: TaildropWaitingFileSummary[];
}

export type TaildropToastKey =
  | 'settings_clear_cache_busy'
  | 'settings_all_local_files_cleared'
  | 'settings_cache_cleared'
  | 'settings_all_local_files_clear_failed'
  | 'settings_clear_cache_failed'
  | 'transfer_send_completed'
  | 'transfer_send_target_unavailable'
  | 'transfer_admin_disabled_title'
  | 'transfer_send_disconnected'
  | 'transfer_send_cancelled'
  | 'transfer_send_permission_denied'
  | 'transfer_send_no_space'
  | 'transfer_send_file_unavailable'
  | 'transfer_send_file_changed'
  | 'transfer_busy_message'
  | 'transfer_send_backend_unavailable'
  | 'transfer_send_interrupted'
  | 'transfer_send_failed'
  | 'transfer_history_cleared'
  | 'transfer_connect_first_title'
  | 'transfer_file_selection_failed'
  | 'transfer_file_copy_failed'
  | 'transfer_cancel_failed'
  | 'transfer_retry_choose_content'
  | 'transfer_receive_failed'
  | 'transfer_receive_picker_failed'
  | 'transfer_discard_completed'
  | 'transfer_cache_cleared'
  | 'transfer_clear_cache_failed'
  | 'transfer_save_timeout'
  | 'transfer_media_ready_to_save'
  | 'transfer_media_save_failed'
  | 'transfer_image_saved'
  | 'transfer_text_copied'
  | 'transfer_receive_completed'
  | 'transfer_receive_unavailable'
  | 'transfer_receive_no_space'
  | 'transfer_discard_failed'
  | 'transfer_receive_delete_failed'
  | 'transfer_gallery_failed'
  | 'transfer_text_copy_failed';

export function emptyTaildropReceive(): TaildropReceiveResult {
  const empty: TaildropReceiveResult = {
    requestId: 0,
    action: '',
    state: 'idle',
    reason: '',
    name: '',
    size: 0,
    path: ''
  };
  return empty;
}

export function sanitizeTaildropDisplayText(value: string): string {
  return value.replace(/[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, '');
}

export function sanitizeTaildropFileName(name: string, index: number): string {
  let sanitized: string = sanitizeTaildropDisplayText(name)
    .replace(/[\\/]/g, '_')
    .trim();
  if (sanitized.length === 0 || sanitized === '.' || sanitized === '..') {
    sanitized = `file-${index + 1}`;
  }
  if (sanitized.length > 180) {
    sanitized = sanitized.substring(0, 180);
  }
  return sanitized;
}

export function formatTaildropTransferDuration(seconds: number): string {
  const safeSeconds: number = Math.max(0, Math.round(seconds));
  if (safeSeconds < 60) {
    return `${safeSeconds}s`;
  }
  const minutes: number = Math.floor(safeSeconds / 60);
  const remainingSeconds: number = safeSeconds % 60;
  if (minutes < 60) {
    return `${minutes}m ${remainingSeconds.toString().padStart(2, '0')}s`;
  }
  const hours: number = Math.floor(minutes / 60);
  const remainingMinutes: number = minutes % 60;
  return `${hours}h ${remainingMinutes.toString().padStart(2, '0')}m`;
}

export function formatTaildropRecordTitle(record: TaildropTransferRecord): string {
  const fileName: string = sanitizeTaildropDisplayText(record.fileName).trim();
  const targetName: string = sanitizeTaildropDisplayText(record.targetName);
  if (fileName.length > 0) {
    return record.fileCount > 1 ? fileName + ' (' + record.fileCount + ' files)' : fileName;
  }
  return record.direction === 'send' ? targetName : 'Received file';
}

export function formatTaildropRecordDescription(
  record: TaildropTransferRecord,
  formattedSize: string
): string {
  const targetName: string = sanitizeTaildropDisplayText(record.targetName);
  if (record.direction === 'send' && record.fileCount <= 1 && targetName.length > 0) {
    return `${formattedSize} · ${targetName}`;
  }
  return record.fileCount > 1 ? record.fileCount + ' files · ' + formattedSize + ' · ' + targetName :
    formattedSize + (record.direction === 'send' && targetName.length > 0 ? ' · ' + targetName : '');
}

export interface TaildropSessionDependencies {
  taildropSendGateway?: TaildropSendGateway;
  taildropReceiveGateway?: TaildropReceiveGateway;
  taildropContentGateway?: TaildropContentGateway;
  backendTaildropReceiveAsync?: (requestJson: string) => Promise<string>;
}

export interface TaildropSessionHost {
  getAbilityContext: () => common.UIAbilityContext;
  getFilesDir: () => string;
  getCacheDir: () => string;
  getServerFilesRoot: () => string;
  getLifecycleGeneration: () => number;
  getControlServerEpoch: () => number;
  isAppShellReady: () => boolean;
  isSecurityPreferencesReady: () => boolean;
  isAppLockRequired: () => boolean;
  isAppLockAuthenticating: () => boolean;
  isSecurityCoverActive: () => boolean;
  isConnected: () => boolean;
  getBackendStatus: () => string;
  isDiagnosticReportInProgress: () => boolean;

  getTaildropState: () => string;
  setTaildropState: (state: string) => void;
  getTaildropReason: () => string;
  setTaildropReason: (reason: string) => void;
  getTaildropTargets: () => TaildropTargetSummary[];
  setTaildropTargets: (targets: TaildropTargetSummary[]) => void;
  getTaildropWaitingFiles: () => TaildropWaitingFileSummary[];
  setTaildropWaitingFiles: (files: TaildropWaitingFileSummary[]) => void;
  getTaildropInboxReason: () => string;
  setTaildropInboxReason: (reason: string) => void;
  getTaildropTransfer: () => TaildropTransferSummary;
  setTaildropTransfer: (transfer: TaildropTransferSummary) => void;
  getTaildropReceive: () => TaildropReceiveResult;
  setTaildropReceive: (receive: TaildropReceiveResult) => void;
  getTaildropMediaPreviews: () => TaildropMediaPreview[];
  setTaildropMediaPreviews: (previews: TaildropMediaPreview[]) => void;
  getTaildropCachedFiles: () => TaildropCachedFile[];
  setTaildropCachedFiles: (files: TaildropCachedFile[]) => void;
  getTaildropHistory: () => TaildropTransferRecord[];
  setTaildropHistory: (records: TaildropTransferRecord[]) => void;
  isTaildropPreparing: () => boolean;
  setTaildropPreparing: (preparing: boolean) => void;
  isTaildropReceiveInProgress: () => boolean;
  setTaildropReceiveInProgress: (inProgress: boolean) => void;
  isTaildropMediaSaveInProgress: () => boolean;
  setTaildropMediaSaveInProgress: (inProgress: boolean) => void;
  isTaildropTextEditorVisible: () => boolean;
  setTaildropTextEditorVisible: (visible: boolean) => void;
  isTaildropTextPreviewVisible: () => boolean;
  setTaildropTextPreviewVisible: (visible: boolean) => void;
  getTaildropTextInput: () => string;
  setTaildropTextInput: (input: string) => void;
  setTaildropTextInputCanSend: (canSend: boolean) => void;
  getTaildropReceivedText: () => string;
  setTaildropReceivedText: (text: string) => void;
  getTaildropTransferRate: () => number;
  setTaildropTransferRate: (rate: number) => void;
  getTaildropTransferEtaSeconds: () => number;
  setTaildropTransferEtaSeconds: (seconds: number) => void;
  isTaildropCancelPending: () => boolean;
  setTaildropCancelPending: (pending: boolean) => void;
  isTaildropPreviewCachePresent: () => boolean;
  setTaildropPreviewCachePresent: (present: boolean) => void;
  getMissingTaildropPreviewPaths: () => string[];
  setMissingTaildropPreviewPaths: (paths: string[]) => void;
  isCacheClearInProgress: () => boolean;
  setCacheClearInProgress: (inProgress: boolean) => void;
  setTaildropPickerOpen?: (open: boolean) => void;

  getTaildropNotificationAction: () => string;
  clearTaildropNotificationAction: () => void;
  scheduleExternalTabNavigation: (tabIndex: number) => void;
  scrollTransferToTop: () => void;
  onCacheContentsChanged: () => void;
  refreshCacheSize: (showLoading?: boolean) => void;
  scheduleLifecycleTask: (task: () => void, delayMs: number) => number;
  showTaildropToast: (key: TaildropToastKey) => void;
  recordDiagnosticEvent: (event: string, phase: string, code?: number) => void;
}

/**
 * Deep module consolidating `TaildropSendGateway`, `TaildropReceiveGateway`,
 * `TaildropContentGateway`, `nativeBridge.backendTaildropReceiveAsync`, file/cache
 * retention & async cleanup, ImageKit/MediaKit thumbnail generation, MediaLibrary
 * gallery save & mtime restoration, and DocumentViewPicker staging/export behind
 * `TaildropSessionHost`.
 */
export class TaildropSessionController {
  private readonly host: TaildropSessionHost;
  readonly taildropSendGateway: TaildropSendGateway;
  readonly taildropReceiveGateway: TaildropReceiveGateway;
  readonly taildropContentGateway: TaildropContentGateway;
  private readonly backendTaildropReceiveAsyncFn: (requestJson: string) => Promise<string>;

  taildropPreviewAvailabilityRevision: number = 0;
  nextTaildropSendRequestId: number = 0;
  cacheClearRequestedFromSettings: boolean = false;
  taildropCacheExpirationCheckedAtMs: number = 0;
  taildropNotificationActionInFlight?: TaildropNotificationActionRequest;
  taildropNotificationActionRetryScheduled: boolean = false;
  lastHandledTaildropRequestId: number = 0;
  taildropRequestSubmittedAtMs: number = 0;
  taildropProgressSampleRequestId: number = 0;
  taildropProgressSampleBytes: number = 0;
  taildropProgressSampleMs: number = 0;
  taildropReceiveResponseInFlight: boolean = false;
  taildropReceiveStateStartedAtMs: number = 0;
  taildropReceiveDestinationUri: string = '';
  taildropReceiveExpectedSize: number = 0;
  taildropReceiveMediaType?: photoAccessHelper.PhotoType;
  taildropReceivePreviewPath: string = '';
  taildropReceiveThumbnailPath: string = '';
  taildropReceiveStrategy: string = 'none';
  taildropPendingDeletes: TaildropWaitingFileSummary[] = [];
  taildropPendingDeleteRetryAtMs: number = 0;
  taildropAutoPrefetchKey: string = '';
  taildropAutoPrefetchFailedKeys: string[] = [];
  taildropPendingTextPreview?: TaildropWaitingFileSummary;
  taildropPendingMediaSave?: TaildropWaitingFileSummary;
  taildropPickerOpen: boolean = false;
  taildropTextTarget?: TaildropTargetSummary;

  constructor(host: TaildropSessionHost, deps?: TaildropSessionDependencies) {
    this.host = host;
    this.taildropSendGateway = deps?.taildropSendGateway ?? new TaildropSendGateway();
    this.taildropReceiveGateway = deps?.taildropReceiveGateway ?? new TaildropReceiveGateway();
    this.taildropContentGateway = deps?.taildropContentGateway ?? new TaildropContentGateway();
    this.backendTaildropReceiveAsyncFn = deps?.backendTaildropReceiveAsync ??
      ((requestJson: string): Promise<string> => nativeBridge.backendTaildropReceiveAsync(requestJson));
  }

  private setTaildropPickerOpen(open: boolean): void {
    this.taildropPickerOpen = open;
    if (this.host.setTaildropPickerOpen !== undefined) {
      this.host.setTaildropPickerOpen(open);
    }
  }

  private writePrivateTextFile(path: string, content: string): boolean {
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(
        path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC
      );
      fileIo.writeSync(file.fd, content);
      return true;
    } catch (_error) {
      return false;
    } finally {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (_error) {
          // The descriptor may already be closed after a platform write failure.
        }
      }
    }
  }

  private writeAtomicTaildropRequest(path: string, requestId: number, content: string): boolean {
    const temporaryPath: string = `${path}.${requestId}.tmp`;
    if (!this.writePrivateTextFile(temporaryPath, content)) {
      return false;
    }
    try {
      fileIo.renameSync(temporaryPath, path);
      return true;
    } catch (_error) {
      try {
        if (fileIo.accessSync(temporaryPath)) {
          fileIo.unlinkSync(temporaryPath);
        }
      } catch (_cleanupError) {
        // Extension startup cleanup removes any remaining temporary file.
      }
      return false;
    }
  }

  private writeAtomicPrivateTextFile(path: string, content: string): boolean {
    const temporaryPath: string = `${path}.tmp`;
    if (!this.writePrivateTextFile(temporaryPath, content)) {
      return false;
    }
    try {
      fileIo.renameSync(temporaryPath, path);
      return true;
    } catch (_error) {
      try {
        if (fileIo.accessSync(temporaryPath)) {
          fileIo.unlinkSync(temporaryPath);
        }
      } catch (_cleanupError) {
        // A later persistence update replaces the temporary snapshot.
      }
      return false;
    }
  }

  // --- Paths & Predicates ---

  taildropSnapshotFilePath(): string {
    return `${this.host.getFilesDir()}/${TAILDROP_TARGETS_FILE_NAME}`;
  }

  taildropHistoryPath(): string {
    return `${this.host.getServerFilesRoot()}/${TAILDROP_HISTORY_FILE_NAME}`;
  }

  taildropInboxSnapshotPath(): string {
    return `${this.host.getServerFilesRoot()}/${TAILDROP_INBOX_SNAPSHOT_FILE_NAME}`;
  }

  taildropHistoryMediaRoot(): string {
    return `${this.host.getServerFilesRoot()}/${TAILDROP_HISTORY_MEDIA_DIR_NAME}`;
  }

  taildropOutboxRoot(): string {
    return RecoverableCachePaths.taildropOutboxRoot(this.host.getAbilityContext());
  }

  taildropSendRequestPath(): string {
    return `${this.host.getFilesDir()}/${TAILDROP_SEND_REQUEST_FILE_NAME}`;
  }

  taildropCancelRequestPath(): string {
    return `${this.host.getFilesDir()}/${TAILDROP_CANCEL_REQUEST_FILE_NAME}`;
  }

  taildropInboxRoot(): string {
    return `${this.host.getServerFilesRoot()}/${TAILDROP_INBOX_DIR_NAME}`;
  }

  taildropReceiveRequestPath(): string {
    return `${this.host.getFilesDir()}/${TAILDROP_RECEIVE_REQUEST_FILE_NAME}`;
  }

  taildropReceiveResponsePath(): string {
    return `${this.host.getFilesDir()}/${TAILDROP_RECEIVE_RESPONSE_FILE_NAME}`;
  }

  appCacheRoots(): string[] {
    const filesDir: string = this.host.getFilesDir();
    return [
      this.host.getCacheDir(),
      `${filesDir}/${TAILDROP_INBOX_DIR_NAME}`,
      `${filesDir}/${TAILDROP_HISTORY_MEDIA_DIR_NAME}`
    ];
  }

  shouldPollHealthFast(): boolean {
    const receive: TaildropReceiveResult = this.host.getTaildropReceive();
    return this.host.isTaildropReceiveInProgress() &&
      receive.state !== 'awaiting_gallery_save' &&
      receive.state !== 'awaiting_text_preview';
  }

  resetForControlServerSwitch(): void {
    this.taildropContentGateway.beginRecovery();
    this.taildropPreviewAvailabilityRevision = (this.taildropPreviewAvailabilityRevision ?? 0) + 1;
    this.host.setTaildropState('disconnected');
    this.host.setTaildropTargets([]);
    this.host.setTaildropWaitingFiles([]);
    this.host.setTaildropPreviewCachePresent(false);
    this.host.setMissingTaildropPreviewPaths([]);
    this.host.setTaildropMediaPreviews([]);
    this.host.setTaildropCachedFiles([]);
    this.host.setTaildropHistory([]);
    this.taildropPendingDeletes = [];
    this.host.setTaildropInboxReason('');
    this.taildropAutoPrefetchKey = '';
    this.lastHandledTaildropRequestId = 0;
    this.host.setTaildropTransfer(emptyTaildropTransfer());
    this.host.setTaildropReceive(emptyTaildropReceive());
    this.host.setTaildropReceivedText('');
    this.host.setTaildropTextPreviewVisible(false);
    this.taildropPendingTextPreview = undefined;
    this.taildropPendingMediaSave = undefined;
  }

  reloadStorageForActiveIdentity(): void {
    this.loadTaildropHistory();
    this.loadPersistedTaildropInbox();
  }

  taildropWaitingFilesSize(): number {
    let size: number = 0;
    this.host.getTaildropWaitingFiles().forEach((file: TaildropWaitingFileSummary) => {
      size += Math.max(0, file.size);
    });
    return size;
  }

  taildropCacheClearInProgress(): boolean {
    return this.host.isTaildropReceiveInProgress() && this.taildropReceiveStrategy === 'clear';
  }

  cacheClearActive(): boolean {
    return this.host.isCacheClearInProgress() || this.taildropCacheClearInProgress();
  }

  cacheClearBlocked(): boolean {
    const transfer: TaildropTransferSummary = this.host.getTaildropTransfer();
    return this.cacheClearActive() || this.host.isDiagnosticReportInProgress() ||
      this.host.isTaildropPreparing() || this.host.isTaildropReceiveInProgress() ||
      transfer.state === 'queued' || transfer.state === 'sending';
  }

  taildropPreviewCacheAvailable(): boolean {
    return this.host.isTaildropPreviewCachePresent();
  }

  taildropSendActive(): boolean {
    const transfer: TaildropTransferSummary = this.host.getTaildropTransfer();
    return this.taildropPickerOpen || this.host.isTaildropPreparing() ||
      transfer.state === 'queued' || transfer.state === 'sending';
  }

  taildropContentChoiceEnabled(): boolean {
    const transfer: TaildropTransferSummary = this.host.getTaildropTransfer();
    return !this.host.isTaildropPreparing() && transfer.state !== 'queued' &&
      transfer.state !== 'sending' &&
      (!this.taildropPickerOpen || this.host.isTaildropTextEditorVisible());
  }

  taildropTextEditorMatches(target: TaildropTargetSummary): boolean {
    return this.host.isTaildropTextEditorVisible() && this.taildropTextTarget !== undefined &&
      this.taildropTextTarget.key === target.key;
  }

  closeTaildropTextEditor(): void {
    this.host.setTaildropTextEditorVisible(false);
    this.setTaildropPickerOpen(false);
    this.taildropTextTarget = undefined;
  }

  onTaildropTextEditorVisibilityChanged(): void {
    if (!this.host.isTaildropTextEditorVisible()) {
      this.setTaildropPickerOpen(false);
      this.taildropTextTarget = undefined;
      this.host.setTaildropTextInputCanSend(false);
    }
  }

  // --- Cache Retention, Availability & Storage Cleanup ---

  cleanupExpiredCacheEntry(path: string, cutoffMs: number): boolean {
    try {
      const stat: fileIo.Stat = fileIo.statSync(path);
      if (stat.isFile()) {
        if (stat.mtime > 0 && stat.mtime * 1000 <= cutoffMs) {
          fileIo.unlinkSync(path);
          return true;
        }
        return false;
      }
      if (!stat.isDirectory()) {
        return false;
      }
      let changed: boolean = false;
      fileIo.listFileSync(path).forEach((name: string) => {
        if (this.cleanupExpiredCacheEntry(`${path}/${name}`, cutoffMs)) {
          changed = true;
        }
      });
      if (fileIo.listFileSync(path).length === 0 && stat.mtime > 0 && stat.mtime * 1000 <= cutoffMs) {
        fileIo.rmdirSync(path);
        return true;
      }
      return changed;
    } catch (_error) {
      return false;
    }
  }

  cleanupExpiredCacheDirectory(path: string, cutoffMs: number): boolean {
    if (!fileIo.accessSync(path)) {
      return false;
    }
    let changed: boolean = false;
    fileIo.listFileSync(path).forEach((name: string) => {
      if (this.cleanupExpiredCacheEntry(`${path}/${name}`, cutoffMs)) {
        changed = true;
      }
    });
    return changed;
  }

  taildropPreviewCachePaths(): string[] {
    const paths: string[] = this.host.getTaildropMediaPreviews()
      .map((preview: TaildropMediaPreview) => preview.thumbnailPath);
    if (this.taildropReceiveThumbnailPath.length > 0) {
      paths.push(this.taildropReceiveThumbnailPath);
    }
    const uniquePaths: string[] = [];
    paths.forEach((path: string) => {
      if (path.length > 0 && !uniquePaths.includes(path)) {
        uniquePaths.push(path);
      }
    });
    return uniquePaths;
  }

  cleanupExpiredTaildropPreviewCache(cutoffMs: number): boolean {
    if (this.host.isTaildropReceiveInProgress()) {
      return false;
    }
    let changed: boolean = false;
    this.taildropPreviewCachePaths().forEach((path: string) => {
      try {
        if (!fileIo.accessSync(path)) {
          return;
        }
        const stat: fileIo.Stat = fileIo.statSync(path);
        const modifiedMs: number = stat.mtime * 1000;
        if (stat.isFile() && Number.isFinite(modifiedMs) && modifiedMs > 0 && modifiedMs <= cutoffMs) {
          fileIo.unlinkSync(path);
          changed = true;
        }
      } catch (_error) {
        // Cache expiration is best-effort and must not interrupt file transfer.
      }
    });
    return changed;
  }

  maybeExpireTaildropCache(): void {
    const nowMs: number = Date.now();
    if (this.taildropCacheExpirationCheckedAtMs > 0 &&
      nowMs - this.taildropCacheExpirationCheckedAtMs < TAILDROP_CACHE_EXPIRATION_CHECK_INTERVAL_MS) {
      return;
    }
    this.taildropCacheExpirationCheckedAtMs = nowMs;
    const cutoffMs: number = nowMs - TAILDROP_CACHE_RETENTION_MS;
    let removedAny: boolean = false;
    try {
      removedAny = this.cleanupExpiredCacheDirectory(this.host.getCacheDir(), cutoffMs) || removedAny;
      removedAny = this.cleanupExpiredCacheDirectory(this.taildropHistoryMediaRoot(), cutoffMs) || removedAny;
      removedAny = this.cleanupExpiredTaildropPreviewCache(cutoffMs) || removedAny;
    } catch (_error) {
      // Cache retention is best-effort and must not interrupt file transfer.
    }

    const currentPreviews: TaildropMediaPreview[] = this.host.getTaildropMediaPreviews();
    const currentCachedFiles: TaildropCachedFile[] = this.host.getTaildropCachedFiles();
    const validPreviews: TaildropMediaPreview[] = currentPreviews.filter(
      (preview: TaildropMediaPreview) => this.validTaildropMediaPreview(preview));
    const validCachedFiles: TaildropCachedFile[] = currentCachedFiles.filter(
      (cached: TaildropCachedFile) => this.validTaildropCachedFile(cached));
    const metadataChanged: boolean = JSON.stringify(validPreviews) !==
      JSON.stringify(currentPreviews) || JSON.stringify(validCachedFiles) !==
      JSON.stringify(currentCachedFiles);
    if (metadataChanged) {
      this.host.setTaildropMediaPreviews(validPreviews);
      this.host.setTaildropCachedFiles(validCachedFiles);
      this.persistTaildropInbox();
      removedAny = true;
    }
    if (removedAny) {
      this.host.onCacheContentsChanged();
    }
  }

  async checkFileAccessibleAsync(path: string): Promise<boolean> {
    if (path.length === 0) {
      return false;
    }
    try {
      if (typeof fileIo.access === 'function') {
        return await fileIo.access(path);
      }
      return fileIo.accessSync(path);
    } catch (_error) {
      return false;
    }
  }

  refreshTaildropPreviewAvailabilityAsync(): void {
    const generation: number = this.host.getLifecycleGeneration();
    const revision: number = (this.taildropPreviewAvailabilityRevision ?? 0) + 1;
    this.taildropPreviewAvailabilityRevision = revision;
    const cachePaths: string[] = this.taildropPreviewCachePaths();
    const renderCandidates: string[] = [];
    this.host.getTaildropMediaPreviews().forEach((preview: TaildropMediaPreview) => {
      if (preview.thumbnailPath.length > 0 && !renderCandidates.includes(preview.thumbnailPath)) {
        renderCandidates.push(preview.thumbnailPath);
      }
      if (preview.path.length > 0 && !renderCandidates.includes(preview.path)) {
        renderCandidates.push(preview.path);
      }
    });
    this.host.getTaildropHistory().forEach((record: TaildropTransferRecord) => {
      if (record.previewPath.length > 0 && !renderCandidates.includes(record.previewPath)) {
        renderCandidates.push(record.previewPath);
      }
    });
    if (this.taildropReceiveThumbnailPath.length > 0 &&
      !renderCandidates.includes(this.taildropReceiveThumbnailPath)) {
      renderCandidates.push(this.taildropReceiveThumbnailPath);
    }
    void (async (): Promise<void> => {
      let anyCachePresent: boolean = false;
      for (let index: number = 0; index < cachePaths.length; index++) {
        if (await this.checkFileAccessibleAsync(cachePaths[index])) {
          anyCachePresent = true;
          break;
        }
      }
      const missing: string[] = [];
      for (let index: number = 0; index < renderCandidates.length; index++) {
        const candidate: string = renderCandidates[index];
        if (!await this.checkFileAccessibleAsync(candidate)) {
          missing.push(candidate);
        }
      }
      if (generation !== this.host.getLifecycleGeneration() ||
        revision !== this.taildropPreviewAvailabilityRevision) {
        return;
      }
      this.host.setTaildropPreviewCachePresent(anyCachePresent);
      if (JSON.stringify(this.host.getMissingTaildropPreviewPaths()) !== JSON.stringify(missing)) {
        this.host.setMissingTaildropPreviewPaths(missing);
      }
    })();
  }

  removeCacheEntry(path: string): boolean {
    try {
      const stat: fileIo.Stat = fileIo.statSync(path);
      if (stat.isFile()) {
        fileIo.unlinkSync(path);
        return true;
      }
      if (!stat.isDirectory()) {
        return false;
      }
      let succeeded: boolean = true;
      fileIo.listFileSync(path).forEach((name: string) => {
        if (!this.removeCacheEntry(`${path}/${name}`)) {
          succeeded = false;
        }
      });
      if (succeeded) {
        fileIo.rmdirSync(path);
      }
      return succeeded;
    } catch (_error) {
      return false;
    }
  }

  async removeCacheEntryAsync(path: string): Promise<boolean> {
    if (typeof fileIo.stat !== 'function' || typeof fileIo.unlink !== 'function' ||
      typeof fileIo.listFile !== 'function' || typeof fileIo.rmdir !== 'function') {
      return this.removeCacheEntry(path);
    }
    try {
      const stat: fileIo.Stat = await fileIo.stat(path);
      if (stat.isFile()) {
        await fileIo.unlink(path);
        return true;
      }
      if (!stat.isDirectory()) {
        return false;
      }
      let succeeded: boolean = true;
      const entries: string[] = await fileIo.listFile(path);
      for (let index: number = 0; index < entries.length; index++) {
        if (!await this.removeCacheEntryAsync(`${path}/${entries[index]}`)) {
          succeeded = false;
        }
      }
      if (succeeded) {
        await fileIo.rmdir(path);
      }
      return succeeded;
    } catch (_error) {
      return false;
    }
  }

  async clearAppCacheEntriesAsync(): Promise<boolean> {
    let succeeded: boolean = true;
    try {
      const roots: string[] = this.appCacheRoots();
      for (let rootIndex: number = 0; rootIndex < roots.length; rootIndex++) {
        const root: string = roots[rootIndex];
        if (!await this.checkFileAccessibleAsync(root)) {
          continue;
        }
        const names: string[] = typeof fileIo.listFile === 'function' ?
          await fileIo.listFile(root) : fileIo.listFileSync(root);
        for (let index: number = 0; index < names.length; index++) {
          if (!await this.removeCacheEntryAsync(`${root}/${names[index]}`)) {
            succeeded = false;
          }
        }
      }
    } catch (_error) {
      succeeded = false;
    }
    return succeeded;
  }

  clearAppCacheEntries(): boolean {
    let succeeded: boolean = true;
    try {
      this.appCacheRoots().forEach((root: string) => {
        if (!fileIo.accessSync(root)) {
          return;
        }
        fileIo.listFileSync(root).forEach((name: string) => {
          if (!this.removeCacheEntry(`${root}/${name}`)) {
            succeeded = false;
          }
        });
      });
    } catch (_error) {
      succeeded = false;
    }
    return succeeded;
  }

  clearTaildropPreviewCacheEntries(): boolean {
    let succeeded: boolean = true;
    this.taildropPreviewCachePaths().forEach((path: string) => {
      try {
        if (fileIo.accessSync(path) && !this.removeCacheEntry(path)) {
          succeeded = false;
        }
      } catch (_error) {
        succeeded = false;
      }
    });
    return succeeded;
  }

  async clearTaildropPreviewCacheEntriesAsync(): Promise<boolean> {
    let succeeded: boolean = true;
    const paths: string[] = this.taildropPreviewCachePaths();
    for (let index: number = 0; index < paths.length; index++) {
      const path: string = paths[index];
      try {
        if (await this.checkFileAccessibleAsync(path) && !await this.removeCacheEntryAsync(path)) {
          succeeded = false;
        }
      } catch (_error) {
        succeeded = false;
      }
    }
    return succeeded;
  }

  async clearTemporaryStorageEntriesAsync(): Promise<boolean> {
    let succeeded: boolean = true;
    try {
      succeeded = await this.clearTaildropPreviewCacheEntriesAsync() && succeeded;
      const roots: string[] = [this.host.getCacheDir(), this.taildropHistoryMediaRoot()];
      for (let rootIndex: number = 0; rootIndex < roots.length; rootIndex++) {
        const root: string = roots[rootIndex];
        if (!await this.checkFileAccessibleAsync(root)) {
          continue;
        }
        const names: string[] = typeof fileIo.listFile === 'function' ?
          await fileIo.listFile(root) : fileIo.listFileSync(root);
        for (let index: number = 0; index < names.length; index++) {
          if (!await this.removeCacheEntryAsync(`${root}/${names[index]}`)) {
            succeeded = false;
          }
        }
      }
    } catch (_error) {
      succeeded = false;
    }
    return succeeded;
  }

  clearAppCache(): void {
    if (this.cacheClearBlocked()) {
      this.host.showTaildropToast('settings_clear_cache_busy');
      return;
    }
    this.cacheClearRequestedFromSettings = true;
    this.host.setCacheClearInProgress(true);
    const generation: number = this.host.getLifecycleGeneration();
    const serverEpoch: number = this.host.getControlServerEpoch();
    this.host.scheduleLifecycleTask(() => {
      void this.clearAppCacheEntriesAsync().then((succeeded: boolean) => {
        if (generation !== this.host.getLifecycleGeneration() ||
          serverEpoch !== this.host.getControlServerEpoch()) {
          this.host.setCacheClearInProgress(false);
          return;
        }
        this.taildropPreviewAvailabilityRevision = (this.taildropPreviewAvailabilityRevision ?? 0) + 1;
        this.host.setTaildropPreviewCachePresent(false);
        this.host.setMissingTaildropPreviewPaths([]);
        this.host.setTaildropMediaPreviews([]);
        this.host.setTaildropCachedFiles([]);
        this.taildropAutoPrefetchFailedKeys = [];
        this.taildropAutoPrefetchKey = '';
        const clearedHistory: TaildropTransferRecord[] = this.host.getTaildropHistory().map(
          (record: TaildropTransferRecord): TaildropTransferRecord => {
            record.previewPath = '';
            return record;
          });
        this.host.setTaildropHistory(clearedHistory);
        this.persistTaildropHistory();
        const waitingFiles: TaildropWaitingFileSummary[] = this.host.getTaildropWaitingFiles();
        if (succeeded && waitingFiles.length > 0 && this.host.getTaildropState() === 'ready') {
          this.cacheClearRequestedFromSettings = true;
          if (this.requestTaildropInboxCacheClear()) {
            return;
          }
          this.finishSettingsCacheClear(false);
          return;
        } else if (succeeded && this.host.getTaildropState() !== 'ready') {
          this.queueTaildropPendingDeletes(waitingFiles);
          this.clearTaildropInboxViewState();
        }
        this.finishSettingsCacheClear(succeeded);
      });
    }, 0);
  }

  clearTemporaryStorage(): void {
    if (this.cacheClearBlocked()) {
      this.host.showTaildropToast('settings_clear_cache_busy');
      return;
    }
    this.cacheClearRequestedFromSettings = false;
    this.host.setCacheClearInProgress(true);
    const generation: number = this.host.getLifecycleGeneration();
    const serverEpoch: number = this.host.getControlServerEpoch();
    this.host.scheduleLifecycleTask(() => {
      void this.clearTemporaryStorageEntriesAsync().then((succeeded: boolean) => {
        if (generation !== this.host.getLifecycleGeneration() ||
          serverEpoch !== this.host.getControlServerEpoch()) {
          this.host.setCacheClearInProgress(false);
          return;
        }
        this.taildropPreviewAvailabilityRevision = (this.taildropPreviewAvailabilityRevision ?? 0) + 1;
        this.host.setTaildropPreviewCachePresent(false);
        this.host.setMissingTaildropPreviewPaths([]);
        const updatedPreviews: TaildropMediaPreview[] = this.host.getTaildropMediaPreviews().map(
          (preview: TaildropMediaPreview): TaildropMediaPreview => {
            preview.thumbnailPath = '';
            return preview;
          });
        this.host.setTaildropMediaPreviews(updatedPreviews);
        this.taildropReceiveThumbnailPath = '';
        this.taildropAutoPrefetchFailedKeys = [];
        this.taildropAutoPrefetchKey = '';
        const updatedHistory: TaildropTransferRecord[] = this.host.getTaildropHistory().map(
          (record: TaildropTransferRecord): TaildropTransferRecord => {
            record.previewPath = '';
            return record;
          });
        this.host.setTaildropHistory(updatedHistory);
        this.persistTaildropHistory();
        this.finishSettingsCacheClear(succeeded);
        this.host.refreshCacheSize(false);
      });
    }, 0);
  }

  clearTaildropInboxViewState(): void {
    this.host.setTaildropMediaPreviews([]);
    this.host.setTaildropCachedFiles([]);
    this.taildropAutoPrefetchFailedKeys = [];
    this.taildropAutoPrefetchKey = '';
    this.host.setTaildropWaitingFiles([]);
    this.host.setTaildropInboxReason('');
    this.persistTaildropInbox();
  }

  finishSettingsCacheClear(succeeded: boolean): void {
    const clearedAllLocalFiles: boolean = this.cacheClearRequestedFromSettings;
    this.cacheClearRequestedFromSettings = false;
    this.host.setCacheClearInProgress(false);
    this.host.refreshCacheSize(false);
    this.host.showTaildropToast(succeeded ? (clearedAllLocalFiles ?
      'settings_all_local_files_cleared' : 'settings_cache_cleared') :
      (clearedAllLocalFiles ? 'settings_all_local_files_clear_failed' :
        'settings_clear_cache_failed'));
  }

  // --- Snapshot, Progress & Transfer State ---

  hasCachedTaildropReceiveFile(): boolean {
    const receive: TaildropReceiveResult = this.host.getTaildropReceive();
    return this.host.getTaildropCachedFiles().some((cached: TaildropCachedFile) =>
      cached.requestId === receive.requestId && cached.name === receive.name &&
      cached.size === receive.size && cached.path === receive.path &&
      this.validTaildropCachedFile(cached));
  }

  canContinueTaildropReceiveOffline(): boolean {
    if (!this.host.isTaildropReceiveInProgress()) {
      return false;
    }
    const receive: TaildropReceiveResult = this.host.getTaildropReceive();
    if (this.taildropReceiveStrategy === 'media' &&
      (receive.state === 'awaiting_gallery_save' || receive.state === 'saving_gallery')) {
      return true;
    }
    if ((this.taildropReceiveStrategy === 'text-preview' &&
      (receive.state === 'awaiting_text_preview' || receive.state === 'copying_text')) ||
      (this.taildropReceiveStrategy === 'file' &&
        (receive.state === 'selecting_destination' || receive.state === 'exporting'))) {
      return this.hasCachedTaildropReceiveFile();
    }
    return false;
  }

  resetTaildropSnapshot(): void {
    this.host.setTaildropState('disconnected');
    this.host.setTaildropReason('');
    this.host.setTaildropTargets([]);
    this.taildropAutoPrefetchKey = '';
    this.taildropPendingTextPreview = undefined;
    this.taildropPendingMediaSave = undefined;
    const receive: TaildropReceiveResult = this.host.getTaildropReceive();
    if (this.host.isTaildropReceiveInProgress() && !this.canContinueTaildropReceiveOffline()) {
      if (receive.state === 'awaiting_gallery_save' || receive.state === 'awaiting_text_preview') {
        this.resetTaildropReceiveOperation();
      } else {
        this.failTaildropReceive('disconnected');
      }
    }
    const transfer: TaildropTransferSummary = this.host.getTaildropTransfer();
    if (transfer.state === 'queued' || transfer.state === 'sending') {
      this.applyTaildropTransfer(this.taildropTransferFailure(transfer, 'disconnected'));
    }
  }

  validTaildropTransfer(transfer: TaildropTransferSummary): boolean {
    if (transfer.state !== 'idle' && transfer.state !== 'queued' && transfer.state !== 'sending' &&
      transfer.state !== 'completed' && transfer.state !== 'failed') {
      return false;
    }
    return transfer.requestId >= 0 && transfer.fileIndex >= 0 && transfer.fileCount >= 0 &&
      transfer.fileBytes >= 0 && transfer.fileSize >= 0 && transfer.bytesSent >= 0 &&
      transfer.totalBytes >= 0;
  }

  taildropTransferFailure(transfer: TaildropTransferSummary, reason: string): TaildropTransferSummary {
    const failed: TaildropTransferSummary = {
      requestId: transfer.requestId,
      state: 'failed',
      reason: reason,
      targetKey: transfer.targetKey,
      targetName: transfer.targetName,
      fileName: transfer.fileName,
      fileIndex: transfer.fileIndex,
      fileCount: transfer.fileCount,
      fileBytes: transfer.fileBytes,
      fileSize: transfer.fileSize,
      bytesSent: transfer.bytesSent,
      totalBytes: transfer.totalBytes,
      previewPath: transfer.previewPath ?? '',
      completedAtMs: Date.now()
    };
    return failed;
  }

  taildropFailureToastKey(reason: string): TaildropToastKey {
    switch (reason) {
      case 'target_unavailable':
      case 'target_offline':
        return 'transfer_send_target_unavailable';
      case 'admin_disabled':
        return 'transfer_admin_disabled_title';
      case 'disconnected':
        return 'transfer_send_disconnected';
      case 'cancelled':
        return 'transfer_send_cancelled';
      case 'permission_denied':
        return 'transfer_send_permission_denied';
      case 'no_space':
        return 'transfer_send_no_space';
      case 'file_unavailable':
        return 'transfer_send_file_unavailable';
      case 'file_changed':
        return 'transfer_send_file_changed';
      case 'busy':
        return 'transfer_busy_message';
      case 'backend_unavailable':
      case 'extension_error':
        return 'transfer_send_backend_unavailable';
      case 'timeout':
      case 'network_interrupted':
        return 'transfer_send_interrupted';
      default:
        return 'transfer_send_failed';
    }
  }

  taildropReceiveFailureToastKey(reason: string): TaildropToastKey {
    const receive: TaildropReceiveResult = this.host.getTaildropReceive();
    if (receive.action === 'clear' || reason === 'clear_failed') {
      return 'transfer_clear_cache_failed';
    }
    if (reason === 'file_unavailable') {
      return 'transfer_receive_unavailable';
    }
    if (reason === 'no_space') {
      return 'transfer_receive_no_space';
    }
    if (reason === 'timeout') {
      return 'transfer_save_timeout';
    }
    if (reason === 'delete_failed') {
      return this.taildropReceiveStrategy === 'discard' ?
        'transfer_discard_failed' : 'transfer_receive_delete_failed';
    }
    if (reason === 'discard_failed') {
      return 'transfer_discard_failed';
    }
    if (reason === 'export_failed' && this.taildropReceiveStrategy === 'image') {
      return 'transfer_gallery_failed';
    }
    if (reason === 'export_failed' && this.taildropReceiveStrategy === 'text') {
      return 'transfer_text_copy_failed';
    }
    return 'transfer_receive_failed';
  }

  resetTaildropProgressEstimate(): void {
    this.host.setTaildropTransferRate(0);
    this.host.setTaildropTransferEtaSeconds(0);
    this.taildropProgressSampleRequestId = 0;
    this.taildropProgressSampleBytes = 0;
    this.taildropProgressSampleMs = 0;
  }

  updateTaildropProgressEstimate(transfer: TaildropTransferSummary): void {
    const active: boolean = transfer.state === 'queued' || transfer.state === 'sending';
    if (!active || transfer.requestId <= 0 || transfer.totalBytes <= 0) {
      this.resetTaildropProgressEstimate();
      return;
    }
    const nowMs: number = Date.now();
    if (transfer.requestId !== this.taildropProgressSampleRequestId ||
      transfer.bytesSent < this.taildropProgressSampleBytes || this.taildropProgressSampleMs <= 0) {
      this.taildropProgressSampleRequestId = transfer.requestId;
      this.taildropProgressSampleBytes = transfer.bytesSent;
      this.taildropProgressSampleMs = nowMs;
      this.host.setTaildropTransferRate(0);
      this.host.setTaildropTransferEtaSeconds(0);
      return;
    }
    const elapsedMs: number = nowMs - this.taildropProgressSampleMs;
    if (elapsedMs < 500) {
      return;
    }
    const byteDelta: number = transfer.bytesSent - this.taildropProgressSampleBytes;
    if (byteDelta <= 0) {
      if (elapsedMs >= 3000) {
        this.host.setTaildropTransferRate(0);
        this.host.setTaildropTransferEtaSeconds(0);
        this.taildropProgressSampleMs = nowMs;
      }
      return;
    }
    const measuredRate: number = Math.round(byteDelta * 1000 / elapsedMs);
    const currentRate: number = this.host.getTaildropTransferRate();
    const nextRate: number = currentRate > 0 ?
      Math.round(currentRate * 0.55 + measuredRate * 0.45) : measuredRate;
    const remainingBytes: number = Math.max(0, transfer.totalBytes - transfer.bytesSent);
    const nextEta: number = nextRate > 0 ? Math.ceil(remainingBytes / nextRate) : 0;
    this.host.setTaildropTransferRate(nextRate);
    this.host.setTaildropTransferEtaSeconds(nextEta);
    this.taildropProgressSampleBytes = transfer.bytesSent;
    this.taildropProgressSampleMs = nowMs;
  }

  applyTaildropTransfer(transfer: TaildropTransferSummary): void {
    if (!this.validTaildropTransfer(transfer)) {
      return;
    }
    const currentTransfer: TaildropTransferSummary = this.host.getTaildropTransfer();
    if (transfer.state === 'idle' &&
      (currentTransfer.state === 'queued' || currentTransfer.state === 'sending') &&
      Date.now() - this.taildropRequestSubmittedAtMs < 5000) {
      return;
    }
    if (transfer.state === 'idle' && currentTransfer.state === 'queued' &&
      Date.now() - this.taildropRequestSubmittedAtMs >= 5000) {
      this.applyTaildropTransfer(this.taildropTransferFailure(currentTransfer, 'extension_error'));
      return;
    }
    if (transfer.requestId === currentTransfer.requestId) {
      if (typeof transfer.previewPath !== 'string') {
        transfer.previewPath = '';
      }
      if (transfer.targetName.length === 0) {
        transfer.targetName = currentTransfer.targetName;
      }
      if (transfer.fileName.length === 0) {
        transfer.fileName = currentTransfer.fileName;
      }
      if ((transfer.previewPath ?? '').length === 0) {
        transfer.previewPath = currentTransfer.previewPath ?? '';
      }
    } else if (typeof transfer.previewPath !== 'string') {
      transfer.previewPath = '';
    }
    this.updateTaildropProgressEstimate(transfer);
    this.host.setTaildropTransfer(transfer);
    if (transfer.state === 'completed' || transfer.state === 'failed' || transfer.state === 'idle') {
      this.host.setTaildropCancelPending(false);
    }
    if ((transfer.state === 'completed' || transfer.state === 'failed') && transfer.requestId > 0 &&
      transfer.requestId !== this.lastHandledTaildropRequestId) {
      this.lastHandledTaildropRequestId = transfer.requestId;
      const target: TaildropTargetSummary | undefined = this.host.getTaildropTargets().find(
        (item: TaildropTargetSummary) => item.key === transfer.targetKey);
      const targetName: string = transfer.targetName.length > 0 ? transfer.targetName :
        (target === undefined ? 'Tailscale' : target.name);
      const record: TaildropTransferRecord = {
        requestId: transfer.requestId,
        direction: 'send',
        state: transfer.state,
        reason: transfer.reason,
        targetKey: transfer.targetKey,
        targetName: targetName,
        fileName: transfer.fileName,
        fileCount: transfer.fileCount,
        totalBytes: transfer.totalBytes,
        previewPath: transfer.previewPath ?? '',
        completedAtMs: transfer.completedAtMs > 0 ? transfer.completedAtMs : Date.now()
      };
      const nextHistory: TaildropTransferRecord[] = [record]
        .concat(this.host.getTaildropHistory())
        .slice(0, TAILDROP_HISTORY_LIMIT);
      this.host.setTaildropHistory(nextHistory);
      this.persistTaildropHistory();
      this.host.showTaildropToast(transfer.state === 'completed' ?
        'transfer_send_completed' : this.taildropFailureToastKey(transfer.reason));
    }
  }

  applyTaildropInboxSnapshot(
    snapshot: TaildropSnapshot,
    connected: boolean,
    authoritativeInbox: boolean
  ): void {
    const validTargets: TaildropTargetSummary[] = snapshot.targets.filter(
      (target: TaildropTargetSummary) => /^peer-[a-f0-9]{16}$/.test(target.key) && target.name.length > 0);
    const snapshotReceivedAtMs: number = Date.now();
    const currentWaiting: TaildropWaitingFileSummary[] = this.host.getTaildropWaitingFiles();
    const validWaitingFiles: TaildropWaitingFileSummary[] = this.sortTaildropWaitingFiles(
      snapshot.waitingFiles.filter((file: TaildropWaitingFileSummary) =>
        this.isTaildropWaitingFileShapeValid(file)).map(
        (file: TaildropWaitingFileSummary, index: number): TaildropWaitingFileSummary => {
          const existing: TaildropWaitingFileSummary | undefined = currentWaiting.find(
            (candidate: TaildropWaitingFileSummary) =>
              candidate.name === file.name && candidate.size === file.size);
          const receivedAtMs: number = existing !== undefined ? existing.receivedAtMs :
            this.taildropWaitingFileTimestamp(file, snapshotReceivedAtMs - index);
          const summary: TaildropWaitingFileSummary = {
            name: file.name,
            size: file.size,
            receivedAtMs: receivedAtMs
          };
          return summary;
        }));
    this.host.setTaildropState(snapshot.state);
    this.host.setTaildropReason(snapshot.reason);
    if (JSON.stringify(this.host.getTaildropTargets()) !== JSON.stringify(validTargets)) {
      this.host.setTaildropTargets(validTargets);
    }
    const inboxIsAuthoritative: boolean = authoritativeInbox && snapshot.state === 'ready' &&
      snapshot.inboxReason.length === 0;
    if (inboxIsAuthoritative) {
      const pendingDeletesChanged: boolean = this.reconcileTaildropPendingDeletes(validWaitingFiles);
      const displayedWaitingFiles: TaildropWaitingFileSummary[] = validWaitingFiles.filter(
        (file: TaildropWaitingFileSummary) => !this.isTaildropPendingDelete(file));
      const waitingFilesChanged: boolean = JSON.stringify(this.host.getTaildropWaitingFiles()) !==
        JSON.stringify(displayedWaitingFiles);
      if (waitingFilesChanged) {
        this.host.setTaildropWaitingFiles(displayedWaitingFiles);
        this.host.onCacheContentsChanged();
      }
      this.host.setTaildropInboxReason('');
      if (waitingFilesChanged || pendingDeletesChanged) {
        this.persistTaildropInbox();
      }
    } else {
      this.host.setTaildropInboxReason(snapshot.inboxReason);
    }
    this.applyTaildropTransfer(snapshot.transfer);
    if (inboxIsAuthoritative) {
      this.submitNextTaildropPendingDelete();
      this.prefetchTaildropInboxFiles(this.host.getTaildropWaitingFiles(), connected);
    }
  }

  applyBackendTaildropSnapshot(snapshot: TaildropSnapshot): void {
    if (this.host.isConnected() || snapshot === undefined ||
      (snapshot.state !== 'ready' && snapshot.state !== 'disabled' && snapshot.state !== 'unavailable')) {
      return;
    }
    this.applyTaildropInboxSnapshot(snapshot, false, true);
  }

  refreshTaildropSnapshot(connected: boolean = this.host.isConnected()): void {
    if (!connected || !this.host.isConnected()) {
      return;
    }
    try {
      this.maybeExpireTaildropCache();
      const path: string = this.taildropSnapshotFilePath();
      if (!fileIo.accessSync(path)) {
        this.host.setTaildropState('loading');
        return;
      }
      const snapshot: TaildropSnapshot = JSON.parse(fileIo.readTextSync(path)) as TaildropSnapshot;
      if (snapshot === null || typeof snapshot !== 'object' || Array.isArray(snapshot) ||
        typeof snapshot.state !== 'string' || !Array.isArray(snapshot.targets) ||
        !Array.isArray(snapshot.waitingFiles) || snapshot.transfer === null ||
        typeof snapshot.transfer !== 'object' || Array.isArray(snapshot.transfer)) {
        return;
      }
      const updatedAtMs: number = snapshot.updatedAtMs === undefined ? 0 : snapshot.updatedAtMs;
      const ageMs: number = Date.now() - updatedAtMs;
      if (updatedAtMs <= 0 || ageMs < 0 || ageMs > TAILDROP_SNAPSHOT_FRESH_MS) {
        this.host.setTaildropState('loading');
        return;
      }
      if (snapshot.state !== 'ready' && snapshot.state !== 'disabled' &&
        snapshot.state !== 'unavailable' && snapshot.state !== 'loading') {
        this.host.setTaildropState('unavailable');
        this.host.setTaildropReason('invalid_snapshot');
        this.host.setTaildropTargets([]);
        return;
      }
      this.applyTaildropInboxSnapshot(snapshot, connected, connected);
    } catch (_error) {
      // The Extension may be replacing the snapshot file. Keep the previous valid result.
    }
  }

  // --- Media Previews, Thumbnails & Persisted History/Inbox ---

  taildropFileExtension(name: string): string {
    return extractFileExtension(name);
  }

  taildropFileTitle(name: string): string {
    const dotIndex: number = name.lastIndexOf('.');
    return dotIndex > 0 ? name.substring(0, dotIndex) : name;
  }

  taildropGalleryAssetTitle(name: string): string {
    let title: string = this.taildropFileTitle(sanitizeTaildropFileName(name, 0))
      .replace(/[\\/:*?"'`<>|{}\[\]]/g, '_').trim();
    if (title.length === 0 || title === '.' || title === '..') {
      title = 'received_image';
    }
    return title.length > 180 ? title.substring(0, 180) : title;
  }

  taildropContentKind(file: TaildropWaitingFileSummary): string {
    return classifyFileContentKind(file.name, file.size, TAILDROP_TEXT_CLIPBOARD_MAX_BYTES);
  }

  resolveTaildropMediaType(name: string): photoAccessHelper.PhotoType | undefined {
    const extension: string = this.taildropFileExtension(name);
    if (IMAGE_FILE_EXTENSIONS.includes(extension)) {
      return photoAccessHelper.PhotoType.IMAGE;
    }
    if (VIDEO_FILE_EXTENSIONS.includes(extension)) {
      return photoAccessHelper.PhotoType.VIDEO;
    }
    return undefined;
  }

  taildropReceiveMatches(file: TaildropWaitingFileSummary): boolean {
    return this.host.isTaildropReceiveInProgress() && this.host.getTaildropReceive().name === file.name;
  }

  taildropReceiveRowLoading(file: TaildropWaitingFileSummary): boolean {
    if (!this.taildropReceiveMatches(file)) {
      return false;
    }
    if (this.taildropReceiveStrategy === 'media-prefetch') {
      return false;
    }
    const receive: TaildropReceiveResult = this.host.getTaildropReceive();
    return this.host.isTaildropMediaSaveInProgress() ||
      (receive.state !== 'awaiting_gallery_save' && receive.state !== 'awaiting_text_preview');
  }

  taildropPreparedMediaSaveEnabled(file: TaildropWaitingFileSummary): boolean {
    if (this.findTaildropMediaPreview(file) === undefined || this.taildropSendActive() ||
      (this.taildropReceiveMatches(file) && this.host.isTaildropMediaSaveInProgress())) {
      return false;
    }
    const receive: TaildropReceiveResult = this.host.getTaildropReceive();
    if (!this.host.isTaildropReceiveInProgress() || this.taildropReceiveStrategy === 'media-prefetch' ||
      this.taildropReceiveStrategy === 'file-prefetch' || receive.state === 'awaiting_text_preview') {
      return true;
    }
    return this.taildropReceiveMatches(file) && receive.state === 'awaiting_gallery_save';
  }

  taildropTextPreviewLoading(file: TaildropWaitingFileSummary): boolean {
    return this.taildropReceiveMatches(file) &&
      this.taildropReceiveStrategy === 'text-preview' &&
      this.host.getTaildropReceive().state !== 'awaiting_text_preview';
  }

  findTaildropMediaPreview(file: TaildropWaitingFileSummary): TaildropMediaPreview | undefined {
    return this.host.getTaildropMediaPreviews().find((preview: TaildropMediaPreview) =>
      preview.name === file.name && preview.size === file.size);
  }

  findTaildropCachedFile(file: TaildropWaitingFileSummary): TaildropCachedFile | undefined {
    return this.host.getTaildropCachedFiles().find((cached: TaildropCachedFile) =>
      cached.name === file.name && cached.size === file.size &&
      this.validTaildropCachedFile(cached));
  }

  taildropPreviewUri(path: string): string {
    return this.taildropContentGateway.previewUri(
      path,
      (candidate: string): boolean => candidate.length > 0 &&
        !this.host.getMissingTaildropPreviewPaths().includes(candidate),
      (candidate: string): string => fileUri.getUriFromPath(candidate)
    );
  }

  validTaildropMediaPreview(preview: TaildropMediaPreview): boolean {
    const mediaType: photoAccessHelper.PhotoType | undefined = this.resolveTaildropMediaType(preview.name);
    if (mediaType === undefined || preview.mediaType !== mediaType || preview.path.length === 0) {
      return false;
    }
    try {
      const stat: fileIo.Stat = fileIo.statSync(preview.path);
      if (!stat.isFile() || stat.size !== preview.size) {
        return false;
      }
    } catch (_error) {
      return false;
    }
    const hasValidThumbnail: boolean = preview.thumbnailPath.length > 0 &&
      this.taildropPreviewUri(preview.thumbnailPath).length > 0;
    return mediaType === photoAccessHelper.PhotoType.IMAGE ||
      mediaType === photoAccessHelper.PhotoType.VIDEO || hasValidThumbnail;
  }

  validTaildropCachedFile(cached: TaildropCachedFile): boolean {
    if (cached.path.length === 0) {
      return false;
    }
    try {
      const stat: fileIo.Stat = fileIo.statSync(cached.path);
      return stat.isFile() && stat.size === cached.size;
    } catch (_error) {
      return false;
    }
  }

  taildropWaitingFilePreviewUri(file: TaildropWaitingFileSummary): string {
    if (this.resolveTaildropMediaType(file.name) === undefined) {
      return '';
    }
    const preview: TaildropMediaPreview | undefined = this.findTaildropMediaPreview(file);
    if (preview === undefined) {
      return '';
    }
    const thumbnailUri: string = this.taildropPreviewUri(preview.thumbnailPath);
    if (thumbnailUri.length > 0) {
      return thumbnailUri;
    }
    return preview.mediaType === photoAccessHelper.PhotoType.IMAGE ?
      this.taildropPreviewUri(preview.path) : '';
  }

  taildropHistoryPreviewUri(record: TaildropTransferRecord): string {
    if (record.fileCount !== 1) {
      return '';
    }
    return this.taildropPreviewUri(record.previewPath);
  }

  private taildropWaitingFileKey(file: TaildropWaitingFileSummary): string {
    return `${file.name}:${file.size}`;
  }

  private isTaildropWaitingFileShapeValid(file: TaildropWaitingFileSummary): boolean {
    return file.name.length > 0 && file.name.length <= 255 && file.name !== '.' && file.name !== '..' &&
      !file.name.includes('/') && !file.name.includes('\\') && file.size >= 0;
  }

  private taildropWaitingFileTimestamp(file: TaildropWaitingFileSummary, fallbackMs: number): number {
    return Number.isFinite(file.receivedAtMs) && file.receivedAtMs > 0 ?
      Math.floor(file.receivedAtMs) : Math.max(1, fallbackMs);
  }

  private sortTaildropWaitingFiles(files: TaildropWaitingFileSummary[]): TaildropWaitingFileSummary[] {
    return files.slice().sort((left: TaildropWaitingFileSummary, right: TaildropWaitingFileSummary) => {
      if (left.receivedAtMs !== right.receivedAtMs) {
        return right.receivedAtMs - left.receivedAtMs;
      }
      return left.name.toLowerCase() < right.name.toLowerCase() ? -1 :
        left.name.toLowerCase() > right.name.toLowerCase() ? 1 : left.size - right.size;
    });
  }

  private isValidTaildropWaitingFile(file: TaildropWaitingFileSummary): boolean {
    return this.isTaildropWaitingFileShapeValid(file) && Number.isFinite(file.receivedAtMs) &&
      file.receivedAtMs > 0;
  }

  private isTaildropPendingDelete(file: TaildropWaitingFileSummary): boolean {
    return this.taildropPendingDeletes.some((pending: TaildropWaitingFileSummary) =>
      pending.name === file.name && pending.size === file.size);
  }

  queueTaildropPendingDelete(file: TaildropWaitingFileSummary): void {
    if (!this.isValidTaildropWaitingFile(file)) {
      return;
    }
    const remaining: TaildropWaitingFileSummary[] = this.taildropPendingDeletes.filter(
      (pending: TaildropWaitingFileSummary) => pending.name !== file.name);
    const queued: TaildropWaitingFileSummary = {
      name: file.name,
      size: file.size,
      receivedAtMs: file.receivedAtMs
    };
    this.taildropPendingDeletes = remaining.concat([queued]);
    this.taildropPendingDeleteRetryAtMs = 0;
  }

  queueTaildropPendingDeletes(files: TaildropWaitingFileSummary[]): void {
    files.forEach((file: TaildropWaitingFileSummary) => this.queueTaildropPendingDelete(file));
  }

  reconcileTaildropPendingDeletes(files: TaildropWaitingFileSummary[]): boolean {
    const reconciled: TaildropWaitingFileSummary[] = this.taildropPendingDeletes.filter(
      (pending: TaildropWaitingFileSummary) => files.some((file: TaildropWaitingFileSummary) =>
        file.name === pending.name && file.size === pending.size));
    const changed: boolean = JSON.stringify(reconciled) !== JSON.stringify(this.taildropPendingDeletes);
    if (changed) {
      this.taildropPendingDeletes = reconciled;
      if (reconciled.length === 0) {
        this.taildropPendingDeleteRetryAtMs = 0;
      }
    }
    return changed;
  }

  removeTaildropMediaPreview(name: string, size: number, deleteFile: boolean): void {
    const current: TaildropMediaPreview[] = this.host.getTaildropMediaPreviews();
    const removed: TaildropMediaPreview[] = current.filter(
      (preview: TaildropMediaPreview) => preview.name === name && preview.size === size);
    if (deleteFile) {
      removed.forEach((preview: TaildropMediaPreview) => {
        [preview.path, preview.thumbnailPath].forEach((path: string) => {
          if (path.length === 0) {
            return;
          }
          try {
            if (fileIo.accessSync(path)) {
              fileIo.unlinkSync(path);
            }
          } catch (_error) {
            // Cache cleanup is retried when the whole inbox cache is cleared.
          }
        });
      });
    }
    this.host.setTaildropMediaPreviews(current.filter(
      (preview: TaildropMediaPreview) => preview.name !== name || preview.size !== size));
    if (deleteFile && removed.length > 0) {
      this.host.onCacheContentsChanged();
    }
  }

  removeTaildropCachedFile(name: string, size: number, deleteFile: boolean): void {
    const current: TaildropCachedFile[] = this.host.getTaildropCachedFiles();
    const removed: TaildropCachedFile[] = current.filter(
      (cached: TaildropCachedFile) => cached.name === name && cached.size === size);
    if (deleteFile) {
      removed.forEach((cached: TaildropCachedFile) => {
        try {
          if (fileIo.accessSync(cached.path)) {
            fileIo.unlinkSync(cached.path);
          }
        } catch (_error) {
          // A later full inbox-cache cleanup can retry an inaccessible file.
        }
      });
    }
    this.host.setTaildropCachedFiles(current.filter(
      (cached: TaildropCachedFile) => cached.name !== name || cached.size !== size));
    if (deleteFile && removed.length > 0) {
      this.host.onCacheContentsChanged();
    }
  }

  reconcileTaildropMediaPreviews(files: TaildropWaitingFileSummary[]): void {
    const currentPreviews: TaildropMediaPreview[] = this.host.getTaildropMediaPreviews();
    const stale: TaildropMediaPreview[] = currentPreviews.filter(
      (preview: TaildropMediaPreview) => !files.some((file: TaildropWaitingFileSummary) =>
        file.name === preview.name && file.size === preview.size));
    stale.forEach((preview: TaildropMediaPreview) => {
      [preview.path, preview.thumbnailPath].forEach((path: string) => {
        if (path.length === 0) {
          return;
        }
        try {
          if (fileIo.accessSync(path)) {
            fileIo.unlinkSync(path);
          }
        } catch (_error) {
          // The next inbox-cache cleanup can remove an inaccessible stale file.
        }
      });
    });
    const validPreviews: TaildropMediaPreview[] = currentPreviews.filter(
      (preview: TaildropMediaPreview) => files.some((file: TaildropWaitingFileSummary) =>
        file.name === preview.name && file.size === preview.size) &&
        this.validTaildropMediaPreview(preview));
    const previewsChanged: boolean = JSON.stringify(currentPreviews) !== JSON.stringify(validPreviews);
    if (previewsChanged) {
      this.host.setTaildropMediaPreviews(validPreviews);
    }
    const currentCachedFiles: TaildropCachedFile[] = this.host.getTaildropCachedFiles();
    const staleCachedFiles: TaildropCachedFile[] = currentCachedFiles.filter(
      (cached: TaildropCachedFile) => !files.some((file: TaildropWaitingFileSummary) =>
        file.name === cached.name && file.size === cached.size));
    staleCachedFiles.forEach((cached: TaildropCachedFile) => {
      try {
        if (fileIo.accessSync(cached.path)) {
          fileIo.unlinkSync(cached.path);
        }
      } catch (_error) {
        // A later full inbox-cache cleanup can retry an inaccessible file.
      }
    });
    const validCachedFiles: TaildropCachedFile[] = currentCachedFiles.filter(
      (cached: TaildropCachedFile) => files.some((file: TaildropWaitingFileSummary) =>
        file.name === cached.name && file.size === cached.size) &&
      this.validTaildropCachedFile(cached));
    const cachedFilesChanged: boolean =
      JSON.stringify(currentCachedFiles) !== JSON.stringify(validCachedFiles);
    if (cachedFilesChanged) {
      this.host.setTaildropCachedFiles(validCachedFiles);
    }
    if (stale.length > 0 || staleCachedFiles.length > 0) {
      this.host.onCacheContentsChanged();
    }
    if (previewsChanged || cachedFilesChanged || stale.length > 0 || staleCachedFiles.length > 0) {
      this.persistTaildropInbox();
    }
    this.taildropAutoPrefetchFailedKeys = this.taildropAutoPrefetchFailedKeys.filter(
      (key: string) => files.some((file: TaildropWaitingFileSummary) =>
        this.taildropWaitingFileKey(file) === key));
  }

  prefetchTaildropInboxFiles(
    files: TaildropWaitingFileSummary[],
    connected: boolean = this.host.isConnected()
  ): void {
    if (connected && this.host.getTaildropState() === 'ready' &&
      this.host.getTaildropInboxReason().length === 0) {
      this.reconcileTaildropMediaPreviews(files);
    }
    if (this.taildropAutoPrefetchKey.length > 0 &&
      !files.some((file: TaildropWaitingFileSummary) =>
        this.taildropWaitingFileKey(file) === this.taildropAutoPrefetchKey)) {
      this.taildropAutoPrefetchKey = '';
    }
    const transfer: TaildropTransferSummary = this.host.getTaildropTransfer();
    if ((!connected && !this.host.getBackendStatus().includes('state=Running')) ||
      this.host.getTaildropState() !== 'ready' || this.host.isTaildropReceiveInProgress() ||
      this.taildropPickerOpen || this.host.isTaildropPreparing() || transfer.state === 'queued' ||
      transfer.state === 'sending' || this.taildropAutoPrefetchKey.length > 0) {
      return;
    }
    const mediaFile: TaildropWaitingFileSummary | undefined = files.find(
      (file: TaildropWaitingFileSummary) =>
        this.resolveTaildropMediaType(file.name) !== undefined &&
        this.findTaildropMediaPreview(file) === undefined &&
        !this.taildropAutoPrefetchFailedKeys.includes(this.taildropWaitingFileKey(file)));
    if (mediaFile !== undefined) {
      const mediaType: photoAccessHelper.PhotoType | undefined =
        this.resolveTaildropMediaType(mediaFile.name);
      if (mediaType !== undefined) {
        this.taildropAutoPrefetchKey = this.taildropWaitingFileKey(mediaFile);
        try {
          this.submitTaildropReceiveStage(mediaFile, mediaType, 'media-prefetch', '');
        } catch (_error) {
          this.failTaildropMediaPrefetch('extension_error');
        }
        return;
      }
    }
    const uncachedFile: TaildropWaitingFileSummary | undefined = files.find(
      (file: TaildropWaitingFileSummary) =>
        this.resolveTaildropMediaType(file.name) === undefined &&
        this.findTaildropCachedFile(file) === undefined &&
        !this.taildropAutoPrefetchFailedKeys.includes(this.taildropWaitingFileKey(file)));
    if (uncachedFile === undefined) {
      return;
    }
    this.taildropAutoPrefetchKey = this.taildropWaitingFileKey(uncachedFile);
    try {
      this.submitTaildropReceiveStage(uncachedFile, undefined, 'file-prefetch', '');
    } catch (_error) {
      this.failTaildropMediaPrefetch('extension_error');
    }
  }

  async createTaildropHistoryPreview(
    sourcePath: string,
    name: string,
    requestId: number
  ): Promise<string> {
    const mediaType: photoAccessHelper.PhotoType | undefined = this.resolveTaildropMediaType(name);
    if (mediaType === undefined || sourcePath.length === 0) {
      return '';
    }
    const root: string = this.taildropHistoryMediaRoot();
    const destination: string = `${root}/receive-${requestId}-thumb.jpg`;
    return this.createTaildropMediaThumbnail(mediaType, sourcePath, destination);
  }

  async createTaildropMediaThumbnail(
    mediaType: photoAccessHelper.PhotoType,
    sourcePath: string,
    destination: string
  ): Promise<string> {
    return mediaType === photoAccessHelper.PhotoType.IMAGE ?
      this.createTaildropThumbnail(sourcePath, destination) :
      this.createTaildropVideoThumbnail(sourcePath, destination);
  }

  private prepareTaildropThumbnailDestination(destination: string): void {
    const separator: number = destination.lastIndexOf('/');
    if (separator > 0) {
      const parent: string = destination.substring(0, separator);
      if (!fileIo.accessSync(parent)) {
        try {
          fileIo.mkdirSync(parent, true);
        } catch (error) {
          const businessError: BusinessError = error as BusinessError;
          if (businessError.code !== 13900015) {
            throw new Error(businessError.message);
          }
        }
      }
    }
    if (fileIo.accessSync(destination)) {
      fileIo.unlinkSync(destination);
    }
  }

  private async writeTaildropThumbnail(
    pixelMap: image.PixelMap,
    destination: string
  ): Promise<string> {
    let imagePacker: image.ImagePacker | undefined = undefined;
    let destinationFile: fileIo.File | undefined = undefined;
    try {
      this.prepareTaildropThumbnailDestination(destination);
      imagePacker = image.createImagePacker();
      const packOpts: image.PackingOption = {
        format: 'image/jpeg',
        quality: TAILDROP_THUMBNAIL_JPEG_QUALITY
      };
      const packed: ArrayBuffer = await imagePacker.packToData(pixelMap, packOpts);
      if (packed.byteLength <= 0) {
        return '';
      }
      destinationFile = fileIo.openSync(
        destination,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC
      );
      const written: number = fileIo.writeSync(destinationFile.fd, packed);
      fileIo.closeSync(destinationFile);
      destinationFile = undefined;
      const stat: fileIo.Stat = fileIo.statSync(destination);
      if (!stat.isFile() || stat.size !== written || written !== packed.byteLength) {
        fileIo.unlinkSync(destination);
        return '';
      }
      this.host.onCacheContentsChanged();
      return destination;
    } catch (error) {
      try {
        if (fileIo.accessSync(destination)) {
          fileIo.unlinkSync(destination);
        }
      } catch (_cleanupError) {
      }
      throw new Error((error as BusinessError).message);
    } finally {
      if (destinationFile !== undefined) {
        try {
          fileIo.closeSync(destinationFile);
        } catch (_error) {
        }
      }
      if (imagePacker !== undefined) {
        try {
          await imagePacker.release();
        } catch (_error) {
        }
      }
    }
  }

  async createTaildropThumbnail(sourcePath: string, destination: string): Promise<string> {
    let sourceFile: fileIo.File | undefined = undefined;
    let imageSource: image.ImageSource | undefined = undefined;
    let pixelMap: image.PixelMap | undefined = undefined;
    try {
      sourceFile = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
      imageSource = image.createImageSource(sourceFile.fd);
      const imageInfo: image.ImageInfo = await imageSource.getImageInfo();
      if (imageInfo.size.width <= 0 || imageInfo.size.height <= 0) {
        return '';
      }
      let width: number = TAILDROP_THUMBNAIL_EDGE_PX;
      let height: number = TAILDROP_THUMBNAIL_EDGE_PX;
      if (imageInfo.size.width >= imageInfo.size.height) {
        height = Math.max(1, Math.round(
          TAILDROP_THUMBNAIL_EDGE_PX * imageInfo.size.height / imageInfo.size.width));
      } else {
        width = Math.max(1, Math.round(
          TAILDROP_THUMBNAIL_EDGE_PX * imageInfo.size.width / imageInfo.size.height));
      }
      const desiredSize: image.Size = { width: width, height: height };
      const decodingOpts: image.DecodingOptions = { index: 0, desiredSize: desiredSize };
      pixelMap = await imageSource.createPixelMap(decodingOpts);
      return await this.writeTaildropThumbnail(pixelMap, destination);
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      this.host.recordDiagnosticEvent(
        'taildrop_thumbnail_failed', 'imagekit', businessError.code ?? -1);
      try {
        if (fileIo.accessSync(destination)) {
          fileIo.unlinkSync(destination);
        }
      } catch (_cleanupError) {
      }
      return '';
    } finally {
      if (pixelMap !== undefined) {
        try {
          await pixelMap.release();
        } catch (_error) {
        }
      }
      if (imageSource !== undefined) {
        try {
          await imageSource.release();
        } catch (_error) {
        }
      }
      if (sourceFile !== undefined) {
        try {
          fileIo.closeSync(sourceFile);
        } catch (_error) {
        }
      }
    }
  }

  withMediaTimeout<T>(operation: Promise<T>, timeoutMs: number): Promise<T> {
    if (typeof setTimeout !== 'function') {
      return operation;
    }
    operation.catch((): void => {});
    let timerId: number = -1;
    const timeoutPromise: Promise<T> = new Promise<T>(
      (_resolve: (value: T) => void, reject: (reason?: Error) => void) => {
        timerId = setTimeout((): void => {
          timerId = -1;
          reject(new Error('media_timeout'));
        }, timeoutMs);
      });
    return Promise.race<T>([operation, timeoutPromise]).finally((): void => {
      if (timerId >= 0 && typeof clearTimeout === 'function') {
        clearTimeout(timerId);
        timerId = -1;
      }
    });
  }

  async createTaildropVideoThumbnail(sourcePath: string, destination: string): Promise<string> {
    let sourceFile: fileIo.File | undefined = undefined;
    let extractor: media.AVMetadataExtractor | undefined = undefined;
    let pixelMap: image.PixelMap | undefined = undefined;
    try {
      sourceFile = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(sourceFile.fd);
      extractor = await this.withMediaTimeout<media.AVMetadataExtractor>(
        media.createAVMetadataExtractor(), 5000);
      const fdSrc: media.AVFileDescriptor = { fd: sourceFile.fd, offset: 0, length: stat.size };
      extractor.fdSrc = fdSrc;
      const metadata: media.AVMetadata = await this.withMediaTimeout<media.AVMetadata>(
        extractor.fetchMetadata(), 5000);
      const sourceWidth: number = metadata.videoWidth === undefined ? 0 : Number(metadata.videoWidth);
      const sourceHeight: number = metadata.videoHeight === undefined ? 0 : Number(metadata.videoHeight);
      let width: number = TAILDROP_THUMBNAIL_EDGE_PX;
      let height: number = TAILDROP_THUMBNAIL_EDGE_PX;
      if (sourceWidth > 0 && sourceHeight > 0 && Number.isFinite(sourceWidth) && Number.isFinite(sourceHeight)) {
        if (sourceWidth >= sourceHeight) {
          height = Math.max(1, Math.round(TAILDROP_THUMBNAIL_EDGE_PX * sourceHeight / sourceWidth));
        } else {
          width = Math.max(1, Math.round(TAILDROP_THUMBNAIL_EDGE_PX * sourceWidth / sourceHeight));
        }
      }
      const durationMs: number = metadata.duration === undefined ? 0 : Number(metadata.duration);
      const frameTimeUs: number = Number.isFinite(durationMs) && durationMs > 0 ?
        Math.min(1000000, Math.round(durationMs * 250)) : 0;
      const frameParam: media.PixelMapParams = { width: width, height: height };
      const framePromise: Promise<image.PixelMap> = extractor.fetchFrameByTime(
        frameTimeUs,
        media.AVImageQueryOptions.AV_IMAGE_QUERY_CLOSEST_SYNC,
        frameParam
      );
      pixelMap = await this.withMediaTimeout<image.PixelMap>(framePromise, 5000);
      return await this.writeTaildropThumbnail(pixelMap, destination);
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      this.host.recordDiagnosticEvent('taildrop_thumbnail_failed', 'video', businessError.code ?? -1);
      try {
        if (fileIo.accessSync(destination)) {
          fileIo.unlinkSync(destination);
        }
      } catch (_cleanupError) {
      }
      return '';
    } finally {
      if (pixelMap !== undefined) {
        try {
          await this.withMediaTimeout<void>(pixelMap.release(), 1500);
        } catch (_error) {
        }
      }
      if (extractor !== undefined) {
        try {
          await this.withMediaTimeout<void>(extractor.release(), 1500);
        } catch (_error) {
        }
      }
      if (sourceFile !== undefined) {
        try {
          fileIo.closeSync(sourceFile);
        } catch (_error) {
        }
      }
    }
  }

  private hydrateTaildropVideoPreview(preview: TaildropMediaPreview): void {
    const serverEpoch: number = this.host.getControlServerEpoch();
    const destination: string = `${this.taildropInboxRoot()}/${preview.requestId}-thumb.jpg`;
    this.createTaildropVideoThumbnail(preview.path, destination).then((thumbnailPath: string) => {
      if (serverEpoch !== this.host.getControlServerEpoch() || thumbnailPath.length === 0) {
        return;
      }
      const stillWaiting: boolean = this.host.getTaildropWaitingFiles().some(
        (file: TaildropWaitingFileSummary) => file.name === preview.name && file.size === preview.size);
      if (!stillWaiting) {
        try {
          if (fileIo.accessSync(thumbnailPath)) {
            fileIo.unlinkSync(thumbnailPath);
          }
        } catch (_error) {
        }
        return;
      }
      const hydrated: TaildropMediaPreview = {
        requestId: preview.requestId,
        name: preview.name,
        size: preview.size,
        path: preview.path,
        thumbnailPath: thumbnailPath,
        mediaType: photoAccessHelper.PhotoType.VIDEO
      };
      if (!this.validTaildropMediaPreview(hydrated)) {
        return;
      }
      this.host.setTaildropMediaPreviews(this.host.getTaildropMediaPreviews().filter(
        (candidate: TaildropMediaPreview) =>
          candidate.name !== hydrated.name || candidate.size !== hydrated.size).concat([hydrated]));
      this.host.setTaildropCachedFiles(this.host.getTaildropCachedFiles().filter(
        (cached: TaildropCachedFile) => cached.name !== hydrated.name || cached.size !== hydrated.size));
      this.persistTaildropInbox();
      this.host.onCacheContentsChanged();
    }).catch(() => {
      // The normal media prefetch path retries thumbnail generation when connected.
    });
  }

  cleanupTaildropHistoryMedia(): void {
    const root: string = this.taildropHistoryMediaRoot();
    try {
      if (!fileIo.accessSync(root)) {
        return;
      }
      const referenced: Set<string> = new Set<string>(this.host.getTaildropHistory()
        .map((record: TaildropTransferRecord) => record.previewPath)
        .filter((path: string) => path.length > 0));
      let removedAny: boolean = false;
      fileIo.listFileSync(root).forEach((name: string) => {
        const path: string = `${root}/${name}`;
        if (!referenced.has(path)) {
          try {
            fileIo.unlinkSync(path);
            removedAny = true;
          } catch (_error) {
            // A later history write retries stale preview cleanup.
          }
        }
      });
      if (removedAny) {
        this.host.onCacheContentsChanged();
      }
    } catch (_error) {
      // Preview cleanup is best effort and must not affect transfer history.
    }
  }

  validTaildropHistoryRecord(record: TaildropTransferRecord): boolean {
    return record.requestId > 0 && (record.direction === 'send' || record.direction === 'receive') &&
      (record.state === 'completed' || record.state === 'failed') && record.fileCount > 0 &&
      record.totalBytes >= 0 && record.completedAtMs > 0 && record.fileName.length <= 255;
  }

  loadTaildropHistory(): void {
    try {
      const path: string = this.taildropHistoryPath();
      if (!fileIo.accessSync(path)) {
        return;
      }
      const records: TaildropTransferRecord[] | undefined = this.taildropContentGateway.loadHistory(
        fileIo.readTextSync(path),
        TAILDROP_HISTORY_LIMIT,
        (record: TaildropTransferRecord): boolean => this.validTaildropHistoryRecord(record)
      );
      if (records === undefined) {
        throw new Error('Taildrop history is invalid.');
      }
      this.host.setTaildropHistory(records);
      this.cleanupTaildropHistoryMedia();
      this.refreshTaildropPreviewAvailabilityAsync();
      records.forEach((record: TaildropTransferRecord) => {
        if (record.direction === 'send') {
          this.lastHandledTaildropRequestId = Math.max(this.lastHandledTaildropRequestId, record.requestId);
        }
      });
    } catch (_error) {
      this.host.setTaildropHistory([]);
    }
  }

  persistTaildropHistory(): void {
    const path: string = this.taildropHistoryPath();
    const temporaryPath: string = `${path}.tmp`;
    const persisted: PersistedTaildropHistory = {
      records: this.host.getTaildropHistory().slice(0, TAILDROP_HISTORY_LIMIT)
    };
    if (!this.writePrivateTextFile(temporaryPath, JSON.stringify(persisted))) {
      return;
    }
    try {
      fileIo.renameSync(temporaryPath, path);
      this.cleanupTaildropHistoryMedia();
      this.refreshTaildropPreviewAvailabilityAsync();
    } catch (_error) {
      try {
        if (fileIo.accessSync(temporaryPath)) {
          fileIo.unlinkSync(temporaryPath);
        }
      } catch (_cleanupError) {
        // History persistence is retried after the next completed transfer.
      }
    }
  }

  clearTaildropHistory(): void {
    this.host.setTaildropHistory([]);
    const path: string = this.taildropHistoryPath();
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (_error) {
      const emptyHistory: PersistedTaildropHistory = { records: [] };
      this.writePrivateTextFile(path, JSON.stringify(emptyHistory));
    }
    this.cleanupTaildropHistoryMedia();
    this.refreshTaildropPreviewAvailabilityAsync();
    this.host.showTaildropToast('transfer_history_cleared');
  }

  loadPersistedTaildropInbox(): void {
    const recoveryGeneration: number = this.taildropContentGateway.beginRecovery();
    try {
      const path: string = this.taildropInboxSnapshotPath();
      if (!fileIo.accessSync(path)) {
        return;
      }
      const persisted: PersistedTaildropInbox | undefined = this.taildropContentGateway.parseSnapshot(
        fileIo.readTextSync(path));
      if (persisted === undefined || !this.taildropContentGateway.isCurrentRecovery(recoveryGeneration)) {
        return;
      }
      const pendingDeletes: TaildropWaitingFileSummary[] = persisted.pendingDeletes === undefined ?
        [] : persisted.pendingDeletes;
      const persistedAtMs: number = Date.now();
      this.taildropPendingDeletes = pendingDeletes.filter(
        (file: TaildropWaitingFileSummary) => this.isTaildropWaitingFileShapeValid(file))
        .map((file: TaildropWaitingFileSummary, index: number): TaildropWaitingFileSummary => {
          const item: TaildropWaitingFileSummary = {
            name: file.name,
            size: file.size,
            receivedAtMs: this.taildropWaitingFileTimestamp(file, persistedAtMs - index)
          };
          return item;
        })
        .filter((file: TaildropWaitingFileSummary, index: number, files: TaildropWaitingFileSummary[]) =>
          files.findIndex((candidate: TaildropWaitingFileSummary) => candidate.name === file.name) === index);
      const restoredWaitingFiles: TaildropWaitingFileSummary[] = this.sortTaildropWaitingFiles(
        persisted.files.filter(
          (file: TaildropWaitingFileSummary) => this.isTaildropWaitingFileShapeValid(file))
          .map((file: TaildropWaitingFileSummary, index: number): TaildropWaitingFileSummary => {
            const item: TaildropWaitingFileSummary = {
              name: file.name,
              size: file.size,
              receivedAtMs: this.taildropWaitingFileTimestamp(file, persistedAtMs - index)
            };
            return item;
          })
          .filter((file: TaildropWaitingFileSummary) => !this.isTaildropPendingDelete(file)));
      this.host.setTaildropWaitingFiles(restoredWaitingFiles);
      this.host.setTaildropInboxReason(persisted.inboxReason);
      const mediaPreviews: TaildropMediaPreview[] =
        persisted.mediaPreviews === undefined ? [] : persisted.mediaPreviews;
      const normalizedMediaPreviews: TaildropMediaPreview[] = [];
      const videoPreviewsToHydrate: TaildropMediaPreview[] = [];
      mediaPreviews.forEach((preview: TaildropMediaPreview) => {
        const normalizedPath: string | undefined = this.normalizeTaildropMediaPath(
          preview.name, preview.size, preview.path);
        if (normalizedPath === undefined) {
          return;
        }
        const normalizedPreview: TaildropMediaPreview = {
          requestId: preview.requestId,
          name: preview.name,
          size: preview.size,
          path: normalizedPath,
          thumbnailPath: preview.thumbnailPath,
          mediaType: preview.mediaType
        };
        const stillWaiting: boolean = restoredWaitingFiles.some(
          (file: TaildropWaitingFileSummary) =>
            file.name === normalizedPreview.name && file.size === normalizedPreview.size);
        if (stillWaiting && this.validTaildropMediaPreview(normalizedPreview)) {
          normalizedMediaPreviews.push(normalizedPreview);
          if (normalizedPreview.mediaType === photoAccessHelper.PhotoType.VIDEO &&
            this.taildropPreviewUri(normalizedPreview.thumbnailPath).length === 0) {
            videoPreviewsToHydrate.push(normalizedPreview);
          }
        } else if (normalizedPreview.mediaType === photoAccessHelper.PhotoType.VIDEO && stillWaiting) {
          videoPreviewsToHydrate.push(normalizedPreview);
        }
      });
      this.host.setTaildropMediaPreviews(normalizedMediaPreviews);
      let persistedInboxChanged: boolean =
        JSON.stringify(persisted.files) !== JSON.stringify(restoredWaitingFiles) ||
        JSON.stringify(pendingDeletes) !== JSON.stringify(this.taildropPendingDeletes) ||
        JSON.stringify(mediaPreviews) !== JSON.stringify(normalizedMediaPreviews);
      const cachedFiles: TaildropCachedFile[] =
        persisted.cachedFiles === undefined ? [] : persisted.cachedFiles;
      let restoredCachedFiles: TaildropCachedFile[] = this.taildropContentGateway.restoreCachedFiles(
        cachedFiles,
        restoredWaitingFiles,
        (cached: TaildropCachedFile): boolean => this.validTaildropCachedFile(cached)
      );
      this.host.setTaildropCachedFiles(restoredCachedFiles);
      persistedInboxChanged = persistedInboxChanged ||
        JSON.stringify(cachedFiles) !== JSON.stringify(restoredCachedFiles);
      const promotedMedia: TaildropMediaPreview[] = [];
      restoredCachedFiles.forEach((cached: TaildropCachedFile) => {
        const mediaType: photoAccessHelper.PhotoType | undefined =
          this.resolveTaildropMediaType(cached.name);
        if (mediaType !== undefined &&
          !this.host.getTaildropMediaPreviews().some((preview: TaildropMediaPreview) =>
            preview.name === cached.name && preview.size === cached.size)) {
          const normalizedPath: string | undefined = this.normalizeTaildropMediaPath(
            cached.name, cached.size, cached.path);
          if (normalizedPath === undefined) {
            return;
          }
          const promoted: TaildropMediaPreview = {
            requestId: cached.requestId,
            name: cached.name,
            size: cached.size,
            path: normalizedPath,
            thumbnailPath: '',
            mediaType: mediaType
          };
          promotedMedia.push(promoted);
        }
      });
      if (promotedMedia.length > 0) {
        this.host.setTaildropMediaPreviews(this.host.getTaildropMediaPreviews().concat(promotedMedia));
        restoredCachedFiles = restoredCachedFiles.filter((cached: TaildropCachedFile) =>
          !promotedMedia.some((preview: TaildropMediaPreview) =>
            preview.requestId === cached.requestId && preview.name === cached.name &&
            preview.size === cached.size));
        this.host.setTaildropCachedFiles(restoredCachedFiles);
        persistedInboxChanged = true;
        promotedMedia.filter((preview: TaildropMediaPreview) =>
          preview.mediaType === photoAccessHelper.PhotoType.VIDEO).forEach(
          (preview: TaildropMediaPreview) => videoPreviewsToHydrate.push(preview));
      }
      if (persistedInboxChanged) {
        this.persistTaildropInbox();
      }
      this.refreshTaildropPreviewAvailabilityAsync();
      videoPreviewsToHydrate.forEach((preview: TaildropMediaPreview) =>
        this.hydrateTaildropVideoPreview(preview));
    } catch (_error) {
      if (!this.taildropContentGateway.isCurrentRecovery(recoveryGeneration)) {
        return;
      }
      this.host.setTaildropWaitingFiles([]);
      this.host.setTaildropInboxReason('');
      this.host.setTaildropMediaPreviews([]);
      this.host.setTaildropCachedFiles([]);
      this.taildropPendingDeletes = [];
    }
  }

  persistTaildropInbox(): void {
    const persisted: PersistedTaildropInbox = {
      files: this.host.getTaildropWaitingFiles(),
      inboxReason: this.host.getTaildropInboxReason(),
      mediaPreviews: this.host.getTaildropMediaPreviews(),
      cachedFiles: this.host.getTaildropCachedFiles(),
      pendingDeletes: this.taildropPendingDeletes
    };
    this.writeAtomicPrivateTextFile(this.taildropInboxSnapshotPath(), JSON.stringify(persisted));
  }

  // --- Outgoing Send Staging, Pickers & Cancellation ---

  private writeTaildropSendRequest(request: TaildropSendRequest): boolean {
    return this.writeAtomicTaildropRequest(
      this.taildropSendRequestPath(),
      request.requestId,
      JSON.stringify(request)
    );
  }

  async prepareTaildropFiles(uris: string[], requestId: number): Promise<TaildropSendFile[]> {
    const generation: number = this.host.getLifecycleGeneration();
    const historyMediaRoot: string = this.taildropHistoryMediaRoot();
    const prepared: TaildropSendFile[] = await this.taildropSendGateway.prepareFiles(
      uris,
      this.taildropOutboxRoot(),
      requestId,
      (name: string, index: number): string => sanitizeTaildropFileName(name, index),
      async (name: string, destination: string, previewRequestId: number): Promise<string> => {
        const mediaType: photoAccessHelper.PhotoType | undefined = this.resolveTaildropMediaType(name);
        return mediaType === undefined ? '' : await this.createTaildropMediaThumbnail(
          mediaType, destination, `${historyMediaRoot}/${previewRequestId}-thumb.jpg`);
      },
      (): boolean => generation === this.host.getLifecycleGeneration() &&
        this.host.isAppShellReady() && this.host.isConnected() &&
        !this.host.isAppLockRequired() && !this.host.isAppLockAuthenticating()
    );
    if (generation === this.host.getLifecycleGeneration()) {
      this.host.onCacheContentsChanged();
    }
    return prepared;
  }

  cleanupPreparedTaildropFiles(files: TaildropSendFile[]): void {
    const preparedFiles: PreparedTaildropFile[] = files.map(
      (file: TaildropSendFile): PreparedTaildropFile => {
        const prepared: PreparedTaildropFile = {
          path: file.path,
          name: file.name,
          size: file.size,
          previewPath: file.previewPath ?? ''
        };
        return prepared;
      });
    this.taildropSendGateway.cleanup(preparedFiles);
    this.host.onCacheContentsChanged();
  }

  interruptTaildropPrefetch(): void {
    if (this.host.isTaildropReceiveInProgress() &&
      (this.taildropReceiveStrategy === 'media-prefetch' ||
        this.taildropReceiveStrategy === 'file-prefetch')) {
      this.taildropAutoPrefetchKey = '';
      this.resetTaildropReceiveOperation();
    }
  }

  ensureTaildropSendAvailable(target: TaildropTargetSummary): boolean {
    if (!this.host.isConnected() || this.host.getTaildropState() !== 'ready') {
      this.host.showTaildropToast('transfer_connect_first_title');
      return false;
    }
    if (!target.online) {
      this.host.showTaildropToast('transfer_send_target_unavailable');
      return false;
    }
    this.interruptTaildropPrefetch();
    if (this.taildropSendActive()) {
      this.host.showTaildropToast('transfer_busy_message');
      return false;
    }
    return true;
  }

  handleTaildropSelectionFailure(): void {
    this.setTaildropPickerOpen(false);
    this.host.setTaildropPreparing(false);
    this.host.showTaildropToast('transfer_file_selection_failed');
  }

  chooseTaildropDocuments(target: TaildropTargetSummary): void {
    if (this.host.isTaildropTextEditorVisible()) {
      this.closeTaildropTextEditor();
    }
    if (!this.ensureTaildropSendAvailable(target)) {
      return;
    }
    this.selectTaildropDocuments(target).catch(() => {
      this.handleTaildropSelectionFailure();
    });
  }

  chooseTaildropPhotos(target: TaildropTargetSummary): void {
    if (this.host.isTaildropTextEditorVisible()) {
      this.closeTaildropTextEditor();
    }
    if (!this.ensureTaildropSendAvailable(target)) {
      return;
    }
    this.selectTaildropMedia(target).catch(() => {
      this.handleTaildropSelectionFailure();
    });
  }

  chooseTaildropText(target: TaildropTargetSummary): void {
    if (this.taildropTextEditorMatches(target)) {
      this.closeTaildropTextEditor();
      return;
    }
    if (this.host.isTaildropTextEditorVisible()) {
      this.closeTaildropTextEditor();
    }
    if (!this.ensureTaildropSendAvailable(target)) {
      return;
    }
    this.host.setTaildropTextInput('');
    this.host.setTaildropTextInputCanSend(false);
    this.taildropTextTarget = target;
    this.setTaildropPickerOpen(true);
    this.host.setTaildropTextEditorVisible(true);
  }

  async selectTaildropDocuments(target: TaildropTargetSummary): Promise<void> {
    if (!target.online || !this.host.isConnected() || this.host.getTaildropState() !== 'ready' ||
      this.taildropSendActive()) {
      return;
    }
    this.setTaildropPickerOpen(true);
    const documentPicker = new picker.DocumentViewPicker(this.host.getAbilityContext());
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = TAILDROP_MAX_FILE_SELECTION;
    let uris: string[] = [];
    try {
      uris = await documentPicker.select(options);
    } finally {
      this.setTaildropPickerOpen(false);
    }
    if (uris.length > 0) {
      await this.queueTaildropFiles(target, uris);
    }
  }

  async selectTaildropMedia(target: TaildropTargetSummary): Promise<void> {
    if (!target.online || !this.host.isConnected() || this.host.getTaildropState() !== 'ready' ||
      this.taildropSendActive()) {
      return;
    }
    this.setTaildropPickerOpen(true);
    const mediaPicker = new photoAccessHelper.PhotoViewPicker();
    const options = new photoAccessHelper.PhotoSelectOptions();
    options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE;
    options.maxSelectNumber = TAILDROP_MAX_MEDIA_SELECTION;
    options.isSearchSupported = true;
    options.isPhotoTakingSupported = true;
    let uris: string[] = [];
    try {
      const result: photoAccessHelper.PhotoSelectResult = await mediaPicker.select(options);
      uris = result.photoUris;
    } finally {
      this.setTaildropPickerOpen(false);
    }
    if (uris.length > 0) {
      await this.queueTaildropFiles(target, uris);
    }
  }

  sendTaildropText(): void {
    const target: TaildropTargetSummary | undefined = this.taildropTextTarget;
    const text: string = this.host.getTaildropTextInput();
    if (target === undefined || text.trim().length === 0) {
      return;
    }
    this.host.setTaildropTextEditorVisible(false);
    this.setTaildropPickerOpen(false);
    this.queueTaildropText(target, text).catch(() => {
      this.handleTaildropSelectionFailure();
    });
  }

  async queueTaildropText(target: TaildropTargetSummary, text: string): Promise<void> {
    const path: string = `${this.host.getCacheDir()}/taildrop-text-${Date.now()}.txt`;
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(
        path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC
      );
      fileIo.writeSync(file.fd, text);
      fileIo.closeSync(file);
      file = undefined;
      await this.queueTaildropFiles(target, [fileUri.getUriFromPath(path)]);
    } finally {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (_closeError) {
        }
      }
      try {
        if (fileIo.accessSync(path)) {
          fileIo.unlinkSync(path);
        }
      } catch (_cleanupError) {
      }
    }
  }

  async queueTaildropFiles(target: TaildropTargetSummary, uris: string[]): Promise<boolean> {
    const transfer: TaildropTransferSummary = this.host.getTaildropTransfer();
    if (!this.host.isAppShellReady() || this.host.isAppLockRequired() ||
      this.host.isAppLockAuthenticating() || uris.length === 0 ||
      uris.length > TAILDROP_MAX_MEDIA_SELECTION || !target.online || !this.host.isConnected() ||
      this.host.getTaildropState() !== 'ready' || this.host.isTaildropPreparing() ||
      transfer.state === 'queued' || transfer.state === 'sending' ||
      this.host.isTaildropReceiveInProgress()) {
      return false;
    }
    this.host.setTaildropPreparing(true);
    const generation: number = this.host.getLifecycleGeneration();
    this.nextTaildropSendRequestId = Math.max(Date.now(), this.nextTaildropSendRequestId + 1);
    const requestId: number = this.nextTaildropSendRequestId;
    let files: TaildropSendFile[] = [];
    try {
      files = await this.prepareTaildropFiles(uris.slice(0, TAILDROP_MAX_MEDIA_SELECTION), requestId);
      if (generation !== this.host.getLifecycleGeneration() || !this.host.isAppShellReady() ||
        this.host.isAppLockRequired() || this.host.isAppLockAuthenticating() ||
        !this.host.isConnected() || this.host.getTaildropState() !== 'ready' ||
        this.host.isTaildropReceiveInProgress() ||
        !this.host.getTaildropTargets().some((peer: TaildropTargetSummary) => peer.key === target.key && peer.online)) {
        this.cleanupPreparedTaildropFiles(files);
        return false;
      }
      let totalBytes: number = 0;
      files.forEach((file: TaildropSendFile) => {
        totalBytes += file.size;
      });
      if (files.length === 0 || !Number.isSafeInteger(totalBytes)) {
        throw new Error('Invalid transfer size.');
      }
      const request: TaildropSendRequest = {
        requestId: requestId,
        targetKey: target.key,
        outboxRoot: this.taildropOutboxRoot(),
        files: files
      };
      const queuedTransfer: TaildropTransferSummary = {
        requestId: requestId,
        state: 'queued',
        reason: '',
        targetKey: target.key,
        targetName: target.name,
        fileName: '',
        fileIndex: 0,
        fileCount: files.length,
        fileBytes: 0,
        fileSize: 0,
        bytesSent: 0,
        totalBytes: totalBytes,
        previewPath: files.length === 1 ? (files[0].previewPath ?? '') : '',
        completedAtMs: 0
      };
      this.host.setTaildropTransfer(queuedTransfer);
      this.resetTaildropProgressEstimate();
      this.taildropRequestSubmittedAtMs = Date.now();
      if (!this.writeTaildropSendRequest(request)) {
        this.cleanupPreparedTaildropFiles(files);
        const failed: TaildropTransferSummary = this.taildropTransferFailure(
          queuedTransfer, 'extension_error');
        this.host.setTaildropPreparing(false);
        this.applyTaildropTransfer(failed);
        return false;
      }
      this.host.recordDiagnosticEvent('taildrop_send_queued', 'transfer');
      this.host.setTaildropPreparing(false);
      return true;
    } catch (_error) {
      this.cleanupPreparedTaildropFiles(files);
      if (generation === this.host.getLifecycleGeneration() && this.host.isAppShellReady()) {
        this.host.showTaildropToast('transfer_file_copy_failed');
      }
      return false;
    } finally {
      if (generation === this.host.getLifecycleGeneration()) {
        this.host.setTaildropPreparing(false);
      }
    }
  }

  cancelTaildropSend(): void {
    const transfer: TaildropTransferSummary = this.host.getTaildropTransfer();
    if (this.host.isTaildropCancelPending() || transfer.requestId <= 0 ||
      (transfer.state !== 'queued' && transfer.state !== 'sending')) {
      return;
    }
    const request: TaildropCancelRequest = { requestId: transfer.requestId };
    if (!this.writeAtomicTaildropRequest(
      this.taildropCancelRequestPath(),
      request.requestId,
      JSON.stringify(request)
    )) {
      this.host.showTaildropToast('transfer_cancel_failed');
      return;
    }
    this.host.setTaildropCancelPending(true);
    this.host.recordDiagnosticEvent('taildrop_send_cancel_requested', 'transfer');
  }

  retryTaildropSend(record: TaildropTransferRecord): void {
    if (record.direction !== 'send' || record.state !== 'failed' || this.taildropSendActive()) {
      return;
    }
    const target: TaildropTargetSummary | undefined = this.host.getTaildropTargets().find(
      (item: TaildropTargetSummary) => item.key === record.targetKey && item.online);
    if (target === undefined) {
      this.host.showTaildropToast('transfer_send_target_unavailable');
      return;
    }
    this.host.scrollTransferToTop();
    this.host.showTaildropToast('transfer_retry_choose_content');
  }

  // --- Notification Actions, Receive, Gallery Save & Text Preview ---

  onTaildropNotificationAction(): void {
    if (!this.host.isAppShellReady() || !this.host.isSecurityPreferencesReady() ||
      this.host.isAppLockRequired()) {
      return;
    }
    const rawAction: string = this.host.getTaildropNotificationAction();
    if (rawAction.length === 0) {
      return;
    }
    const request: TaildropNotificationActionRequest | undefined =
      this.taildropReceiveGateway.parseNotificationAction(rawAction);
    if (request === undefined) {
      this.host.clearTaildropNotificationAction();
      return;
    }
    this.host.scheduleExternalTabNavigation(1);
    if (request.action !== 'save' || request.receivedAtMs <= 0) {
      this.host.clearTaildropNotificationAction();
      return;
    }
    const file: TaildropWaitingFileSummary | undefined = this.host.getTaildropWaitingFiles().find(
      (candidate: TaildropWaitingFileSummary) =>
        candidate.name === request.fileName && candidate.size === request.size &&
          candidate.receivedAtMs === request.receivedAtMs);
    if (file !== undefined) {
      if (!this.taildropReceiveGateway.claimNotificationAction(request)) {
        this.host.clearTaildropNotificationAction();
        return;
      }
      this.taildropNotificationActionInFlight = request;
      this.host.clearTaildropNotificationAction();
      this.taildropNotificationActionRetryScheduled = false;
      this.saveTaildropFileFromNotification(file);
    } else if (!this.taildropNotificationActionRetryScheduled) {
      this.taildropNotificationActionRetryScheduled = true;
      this.host.scheduleLifecycleTask(() => {
        this.taildropNotificationActionRetryScheduled = false;
        this.onTaildropNotificationAction();
      }, 800);
    }
  }

  saveTaildropFileFromNotification(file: TaildropWaitingFileSummary): void {
    if (this.taildropSendActive() || this.host.isTaildropReceiveInProgress()) {
      this.host.showTaildropToast('transfer_busy_message');
      this.releaseTaildropNotificationActionClaim();
      return;
    }
    const kind: string = this.taildropContentKind(file);
    if (kind === 'text') {
      const cached: TaildropCachedFile | undefined = this.findTaildropCachedFile(file);
      if (cached !== undefined) {
        void this.showCachedTaildropTextPreview(cached).then((shown: boolean) => {
          if (shown) {
            this.copyTaildropTextPreview();
          } else {
            this.releaseTaildropNotificationActionClaim();
          }
        });
      } else {
        this.startTaildropReceive(file);
      }
      return;
    }
    if (kind === 'image' || kind === 'video') {
      const preview: TaildropMediaPreview | undefined = this.findTaildropMediaPreview(file);
      if (preview !== undefined) {
        this.releaseTaildropNotificationActionClaim();
        this.host.showTaildropToast('transfer_media_ready_to_save');
      } else {
        this.releaseTaildropNotificationActionClaim();
        this.startTaildropReceive(file);
      }
      return;
    }
    this.startPreparedTaildropFileSave(file);
  }

  releaseTaildropNotificationActionClaim(): void {
    this.taildropReceiveGateway.releaseNotificationAction(this.taildropNotificationActionInFlight);
    this.taildropNotificationActionInFlight = undefined;
  }

  startTaildropReceive(file: TaildropWaitingFileSummary): void {
    const receive: TaildropReceiveResult = this.host.getTaildropReceive();
    if (this.host.isTaildropReceiveInProgress() && receive.name !== file.name &&
      receive.state === 'awaiting_gallery_save') {
      this.resetTaildropReceiveOperation();
      this.taildropAutoPrefetchKey = '';
    }
    if (this.host.getTaildropState() !== 'ready' || this.taildropSendActive() ||
      this.host.isTaildropReceiveInProgress()) {
      return;
    }
    try {
      this.routeTaildropReceive(file);
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      this.host.recordDiagnosticEvent('taildrop_receive_submit_failed', 'transfer', businessError.code ?? -1);
      this.resetTaildropReceiveOperation();
      this.host.showTaildropToast('transfer_receive_failed');
    }
  }

  startTaildropTextPreview(file: TaildropWaitingFileSummary): void {
    if (this.taildropContentKind(file) !== 'text') {
      return;
    }
    const receive: TaildropReceiveResult = this.host.getTaildropReceive();
    if (this.host.isTaildropReceiveInProgress() && receive.name !== file.name &&
      receive.state === 'awaiting_gallery_save') {
      this.resetTaildropReceiveOperation();
      this.taildropAutoPrefetchKey = '';
    }
    if (this.host.isTaildropReceiveInProgress()) {
      const currentReceive: TaildropReceiveResult = this.host.getTaildropReceive();
      if (currentReceive.name === file.name && currentReceive.state === 'awaiting_text_preview') {
        return;
      }
      this.taildropPendingTextPreview = file;
      if (currentReceive.state === 'awaiting_text_preview') {
        this.resetTaildropReceiveOperation();
        this.resumePendingTaildropAction();
      }
      return;
    }
    if (this.taildropSendActive()) {
      this.host.showTaildropToast('transfer_busy_message');
      return;
    }
    const cached: TaildropCachedFile | undefined = this.findTaildropCachedFile(file);
    if (cached !== undefined) {
      void this.showCachedTaildropTextPreview(cached);
      return;
    }
    if (this.host.getTaildropState() !== 'ready') {
      this.host.showTaildropToast('transfer_connect_first_title');
      return;
    }
    try {
      this.submitTaildropReceiveStage(file, undefined, 'text-preview', '');
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      this.host.recordDiagnosticEvent('taildrop_text_preview_submit_failed', 'transfer', businessError.code ?? -1);
      this.resetTaildropReceiveOperation();
      this.host.showTaildropToast('transfer_receive_failed');
    }
  }

  async showCachedTaildropTextPreview(cached: TaildropCachedFile): Promise<boolean> {
    const generation: number = this.host.getLifecycleGeneration();
    const serverEpoch: number = this.host.getControlServerEpoch();
    const result: TaildropReceiveResult = {
      requestId: cached.requestId,
      action: 'stage',
      state: 'awaiting_text_preview',
      reason: '',
      name: cached.name,
      size: cached.size,
      path: cached.path
    };
    const content: string | undefined = await this.readTaildropTextPreview(result);
    if (generation !== this.host.getLifecycleGeneration() ||
      serverEpoch !== this.host.getControlServerEpoch() ||
      this.host.isSecurityCoverActive()) {
      return false;
    }
    if (content === undefined) {
      this.removeTaildropCachedFile(cached.name, cached.size, true);
      this.persistTaildropInbox();
      this.host.showTaildropToast('transfer_receive_failed');
      return false;
    }
    this.taildropReceiveStrategy = 'text-preview';
    this.taildropReceiveExpectedSize = cached.size;
    this.host.setTaildropReceiveInProgress(true);
    this.taildropReceiveStateStartedAtMs = 0;
    this.host.setTaildropReceive(result);
    this.host.setTaildropReceivedText(content);
    return true;
  }

  resumePendingTaildropAction(): boolean {
    if (this.host.isTaildropReceiveInProgress()) {
      return false;
    }
    const pendingMediaSave: TaildropWaitingFileSummary | undefined = this.taildropPendingMediaSave;
    this.taildropPendingMediaSave = undefined;
    if (pendingMediaSave !== undefined && this.findTaildropMediaPreview(pendingMediaSave) !== undefined) {
      this.startPreparedTaildropMediaSave(pendingMediaSave);
      return true;
    }
    const pending: TaildropWaitingFileSummary | undefined = this.taildropPendingTextPreview;
    this.taildropPendingTextPreview = undefined;
    if (pending !== undefined) {
      this.startTaildropTextPreview(pending);
      return true;
    }
    return false;
  }

  private routeTaildropReceive(file: TaildropWaitingFileSummary): void {
    if (this.taildropContentKind(file) === 'text') {
      this.submitTaildropReceiveStage(file, undefined, 'text', '');
      return;
    }
    const mediaType: photoAccessHelper.PhotoType | undefined = this.resolveTaildropMediaType(file.name);
    if (mediaType !== undefined) {
      this.submitTaildropReceiveStage(file, mediaType, 'media', '');
      return;
    }
    this.submitTaildropReceiveStage(file, undefined, 'file', '');
  }

  async selectTaildropReceiveDestination(result: TaildropReceiveResult): Promise<string> {
    this.setTaildropPickerOpen(true);
    const documentPicker = new picker.DocumentViewPicker(this.host.getAbilityContext());
    const options = new picker.DocumentSaveOptions();
    options.newFileNames = [sanitizeTaildropFileName(result.name, 0)];
    let uris: string[] = [];
    try {
      uris = await documentPicker.save(options);
    } catch (_error) {
      this.host.showTaildropToast('transfer_receive_picker_failed');
    } finally {
      this.setTaildropPickerOpen(false);
    }
    return uris.length > 0 ? uris[0] : '';
  }

  private useDirectTaildropBackend(): boolean {
    return !this.host.isConnected() && this.host.getBackendStatus().includes('state=Running');
  }

  private isCurrentTaildropReceiveRequest(request: TaildropReceiveRequest): boolean {
    const receive: TaildropReceiveResult = this.host.getTaildropReceive();
    return this.host.isTaildropReceiveInProgress() && receive.requestId === request.requestId &&
      receive.action === request.action;
  }

  dispatchTaildropReceiveRequest(request: TaildropReceiveRequest): boolean {
    if (!this.useDirectTaildropBackend()) {
      return this.writeAtomicTaildropRequest(
        this.taildropReceiveRequestPath(),
        request.requestId,
        JSON.stringify(request)
      );
    }
    this.taildropReceiveResponseInFlight = true;
    try {
      this.backendTaildropReceiveAsyncFn(JSON.stringify(request))
        .then((resultText: string) => {
          if (!this.isCurrentTaildropReceiveRequest(request)) {
            return;
          }
          let result: TaildropReceiveResult;
          try {
            result = JSON.parse(resultText) as TaildropReceiveResult;
          } catch (_error) {
            this.failTaildropReceive('invalid_result');
            return;
          }
          if (!this.taildropReceiveGateway.matchesResponse(this.host.getTaildropReceive(), result)) {
            this.failTaildropReceive('invalid_result');
            return;
          }
          return this.handleTaildropReceiveResult(result)
            .catch(() => this.failTaildropReceive('export_failed'));
        })
        .catch(() => {
          if (this.isCurrentTaildropReceiveRequest(request)) {
            this.failTaildropReceive('backend_unavailable');
          }
        })
        .finally(() => {
          const receive: TaildropReceiveResult = this.host.getTaildropReceive();
          if (!this.host.isTaildropReceiveInProgress() ||
            (receive.requestId === request.requestId && receive.action === request.action)) {
            this.taildropReceiveResponseInFlight = false;
          }
        });
    } catch (_error) {
      this.taildropReceiveResponseInFlight = false;
      this.failTaildropReceive('backend_unavailable');
    }
    return true;
  }

  submitTaildropReceiveStage(
    file: TaildropWaitingFileSummary,
    mediaType?: photoAccessHelper.PhotoType,
    strategy: string = 'file',
    destinationUri: string = ''
  ): void {
    if (this.host.getTaildropState() !== 'ready' || this.taildropSendActive()) {
      return;
    }
    const requestId: number = Date.now();
    const inboxRoot: string = this.taildropInboxRoot();
    if (!this.ensureTaildropDirectory(inboxRoot)) {
      this.host.recordDiagnosticEvent('taildrop_receive_inbox_unavailable', 'transfer');
      this.host.showTaildropToast('transfer_receive_failed');
      return;
    }
    this.host.setTaildropReceiveInProgress(true);
    const request: TaildropReceiveRequest = this.taildropReceiveGateway.createStageRequest(
      requestId, file.name, inboxRoot);
    this.taildropReceiveStrategy = strategy;
    this.taildropReceiveDestinationUri = destinationUri;
    this.taildropReceiveExpectedSize = file.size;
    this.taildropReceiveMediaType = mediaType;
    const receive: TaildropReceiveResult = {
      requestId: requestId,
      action: 'stage',
      state: 'requesting',
      reason: '',
      name: file.name,
      size: file.size,
      path: request.path
    };
    this.host.setTaildropReceive(receive);
    this.taildropReceiveStateStartedAtMs = Date.now();
    this.writePrivateTextFile(this.taildropReceiveResponsePath(), '');
    if (!this.dispatchTaildropReceiveRequest(request)) {
      this.failTaildropReceive('extension_error');
      return;
    }
    this.host.recordDiagnosticEvent(
      mediaType === undefined ? 'taildrop_receive_queued' : 'taildrop_media_receive_queued',
      'transfer'
    );
  }

  ensureTaildropDirectory(path: string): boolean {
    try {
      if (!fileIo.accessSync(path)) {
        fileIo.mkdirSync(path, true);
      }
      return fileIo.accessSync(path) && fileIo.statSync(path).isDirectory();
    } catch (_error) {
      try {
        return fileIo.accessSync(path) && fileIo.statSync(path).isDirectory();
      } catch (_verificationError) {
        return false;
      }
    }
  }

  discardTaildropFile(file: TaildropWaitingFileSummary): void {
    if (this.taildropSendActive() || this.host.isTaildropReceiveInProgress()) {
      return;
    }
    if (this.host.getTaildropState() !== 'ready') {
      this.queueTaildropPendingDelete(file);
      this.removeTaildropMediaPreview(file.name, file.size, true);
      this.removeTaildropCachedFile(file.name, file.size, true);
      this.host.setTaildropWaitingFiles(this.host.getTaildropWaitingFiles().filter(
        (waitingFile: TaildropWaitingFileSummary) =>
          waitingFile.name !== file.name || waitingFile.size !== file.size));
      this.persistTaildropInbox();
      this.host.onCacheContentsChanged();
      this.host.showTaildropToast('transfer_discard_completed');
      return;
    }
    const requestId: number = Date.now();
    const request: TaildropReceiveRequest = {
      requestId: requestId,
      action: 'delete',
      name: file.name,
      inboxRoot: '',
      path: ''
    };
    this.taildropReceiveStrategy = 'discard';
    this.taildropReceiveDestinationUri = '';
    this.taildropReceiveExpectedSize = 0;
    this.host.setTaildropReceiveInProgress(true);
    const receive: TaildropReceiveResult = {
      requestId: requestId,
      action: 'delete',
      state: 'deleting',
      reason: '',
      name: file.name,
      size: file.size,
      path: ''
    };
    this.host.setTaildropReceive(receive);
    this.taildropReceiveStateStartedAtMs = Date.now();
    this.writePrivateTextFile(this.taildropReceiveResponsePath(), '');
    if (!this.dispatchTaildropReceiveRequest(request)) {
      this.failTaildropReceive('discard_failed');
      return;
    }
    this.host.recordDiagnosticEvent('taildrop_receive_discard_requested', 'transfer');
  }

  clearTaildropInboxCache(): void {
    if (this.taildropSendActive() || this.host.isTaildropReceiveInProgress()) {
      return;
    }
    if (this.host.getTaildropState() !== 'ready') {
      this.queueTaildropPendingDeletes(this.host.getTaildropWaitingFiles());
      const succeeded: boolean = this.clearLocalTaildropInboxCache();
      if (succeeded) {
        this.clearTaildropInboxViewState();
      }
      this.host.onCacheContentsChanged();
      this.host.showTaildropToast(succeeded ? 'transfer_cache_cleared' : 'transfer_clear_cache_failed');
      return;
    }
    this.requestTaildropInboxCacheClear();
  }

  requestTaildropInboxCacheClear(): boolean {
    const requestId: number = Date.now();
    const request: TaildropReceiveRequest = {
      requestId: requestId,
      action: 'clear',
      name: '',
      inboxRoot: '',
      path: ''
    };
    this.taildropReceiveStrategy = 'clear';
    this.host.setTaildropReceiveInProgress(true);
    const receive: TaildropReceiveResult = {
      requestId: requestId,
      action: 'clear',
      state: 'requesting',
      reason: '',
      name: '',
      size: 0,
      path: ''
    };
    this.host.setTaildropReceive(receive);
    this.taildropReceiveStateStartedAtMs = Date.now();
    this.writePrivateTextFile(this.taildropReceiveResponsePath(), '');
    if (!this.dispatchTaildropReceiveRequest(request)) {
      this.host.recordDiagnosticEvent('taildrop_receive_failed', 'clear_failed');
      this.resetTaildropReceiveOperation();
      if (!this.cacheClearRequestedFromSettings) {
        this.host.showTaildropToast('transfer_clear_cache_failed');
      }
      return false;
    }
    this.host.recordDiagnosticEvent('taildrop_receive_cache_clear_requested', 'transfer');
    return true;
  }

  checkTaildropReceiveTimeout(): void {
    if (!this.host.isTaildropReceiveInProgress()) {
      return;
    }
    const receive: TaildropReceiveResult = this.host.getTaildropReceive();
    if (receive.requestId <= 0) {
      this.host.recordDiagnosticEvent('taildrop_receive_invalid_busy_state', 'timeout');
      this.resetTaildropReceiveOperation();
      this.host.showTaildropToast('transfer_save_timeout');
      return;
    }
    if (receive.state === 'awaiting_gallery_save' || receive.state === 'awaiting_text_preview') {
      return;
    }
    if (this.taildropReceiveStateStartedAtMs <= 0) {
      this.taildropReceiveStateStartedAtMs = Date.now();
      return;
    }
    const timeoutMs: number = receive.state === 'requesting' || receive.state === 'deleting' ?
      TAILDROP_RECEIVE_BACKEND_TIMEOUT_MS : TAILDROP_SAVE_TIMEOUT_MS;
    if (Date.now() - this.taildropReceiveStateStartedAtMs < timeoutMs) {
      return;
    }
    this.host.recordDiagnosticEvent('taildrop_receive_timeout', receive.state);
    if (this.taildropReceiveStrategy === 'media-prefetch') {
      this.failTaildropMediaPrefetch('timeout');
      return;
    }
    if (receive.state === 'saving_gallery' &&
      this.taildropReceiveMediaType !== undefined && receive.path.length > 0) {
      this.host.setTaildropMediaSaveInProgress(false);
      this.setTaildropPickerOpen(false);
      this.taildropReceiveResponseInFlight = false;
      const restoredReceive: TaildropReceiveResult = {
        requestId: receive.requestId,
        action: 'stage',
        state: 'awaiting_gallery_save',
        reason: '',
        name: receive.name,
        size: receive.size,
        path: receive.path
      };
      this.host.setTaildropReceive(restoredReceive);
      this.taildropReceiveStateStartedAtMs = 0;
      this.host.showTaildropToast('transfer_save_timeout');
      return;
    }
    if (receive.state === 'deleting') {
      if (this.taildropReceiveStrategy === 'pending-delete') {
        this.deferTaildropPendingDelete('timeout');
      } else if (this.taildropReceiveStrategy === 'discard') {
        this.completeTaildropDiscard(true);
      } else {
        this.completeTaildropReceive(true);
      }
      return;
    }
    this.failTaildropReceive('timeout');
  }

  processTaildropReceiveResponse(): void {
    if (!this.host.isTaildropReceiveInProgress() || this.taildropReceiveResponseInFlight) {
      return;
    }
    try {
      const path: string = this.taildropReceiveResponsePath();
      if (!fileIo.accessSync(path)) {
        return;
      }
      const responseText: string = fileIo.readTextSync(path).trim();
      if (responseText.length === 0) {
        return;
      }
      const result: TaildropReceiveResult = JSON.parse(responseText) as TaildropReceiveResult;
      if (!this.taildropReceiveGateway.matchesResponse(this.host.getTaildropReceive(), result)) {
        this.writePrivateTextFile(path, '');
        return;
      }
      this.writePrivateTextFile(path, '');
      this.taildropReceiveResponseInFlight = true;
      this.handleTaildropReceiveResult(result)
        .catch(() => this.failTaildropReceive('export_failed'))
        .finally(() => {
          this.taildropReceiveResponseInFlight = false;
        });
    } catch (_error) {
      // The Extension may be atomically replacing the response. Retry next poll.
    }
  }

  async handleTaildropReceiveResult(result: TaildropReceiveResult): Promise<void> {
    if (result.state === 'failed') {
      if (this.taildropReceiveStrategy === 'pending-delete') {
        if (result.reason === 'file_unavailable') {
          this.completeTaildropPendingDelete();
        } else {
          this.deferTaildropPendingDelete(result.reason);
        }
        return;
      }
      if (result.action === 'delete') {
        this.host.recordDiagnosticEvent('taildrop_receive_delete_deferred', result.reason);
        if (this.taildropReceiveStrategy === 'discard') {
          this.completeTaildropDiscard(true);
        } else {
          this.completeTaildropReceive(true);
        }
        return;
      }
      this.failTaildropReceive(result.reason);
      return;
    }
    if (result.action === 'stage' && result.state === 'staged') {
      if (this.taildropReceiveStrategy === 'media-prefetch') {
        const mediaType: photoAccessHelper.PhotoType | undefined = this.taildropReceiveMediaType;
        const mediaPath: string | undefined = this.prepareTaildropMediaForSave(result);
        if (mediaType === undefined || mediaPath === undefined) {
          this.failTaildropMediaPrefetch('export_failed');
          return;
        }
        const thumbnailPath: string = await this.createTaildropMediaThumbnail(
          mediaType, mediaPath, `${this.taildropInboxRoot()}/${result.requestId}-thumb.jpg`);
        if (thumbnailPath.length === 0) {
          this.host.recordDiagnosticEvent(
            'taildrop_thumbnail_unavailable',
            mediaType === photoAccessHelper.PhotoType.IMAGE ? 'image' : 'video'
          );
        }
        this.removeTaildropMediaPreview(result.name, result.size, true);
        this.removeTaildropCachedFile(result.name, result.size, true);
        const preview: TaildropMediaPreview = {
          requestId: result.requestId,
          name: result.name,
          size: result.size,
          path: mediaPath,
          thumbnailPath: thumbnailPath,
          mediaType: mediaType
        };
        if (!this.validTaildropMediaPreview(preview)) {
          this.failTaildropMediaPrefetch('export_failed');
          return;
        }
        this.host.setTaildropMediaPreviews(this.host.getTaildropMediaPreviews().concat([preview]));
        this.taildropAutoPrefetchKey = '';
        this.persistTaildropInbox();
        this.host.onCacheContentsChanged();
        this.host.recordDiagnosticEvent('taildrop_media_preview_ready', result.name);
        this.resetTaildropReceiveOperation();
        if (!this.resumePendingTaildropAction()) {
          this.prefetchTaildropInboxFiles(this.host.getTaildropWaitingFiles());
        }
        return;
      }
      if (this.taildropReceiveStrategy === 'file-prefetch') {
        const cached: TaildropCachedFile = {
          requestId: result.requestId,
          name: result.name,
          size: result.size,
          path: result.path
        };
        if (!this.validTaildropCachedFile(cached)) {
          this.failTaildropMediaPrefetch('export_failed');
          return;
        }
        this.removeTaildropCachedFile(result.name, result.size, true);
        this.host.setTaildropCachedFiles(this.host.getTaildropCachedFiles().concat([cached]));
        this.taildropAutoPrefetchKey = '';
        this.persistTaildropInbox();
        this.host.onCacheContentsChanged();
        this.host.recordDiagnosticEvent('taildrop_file_cache_ready', result.name);
        this.resetTaildropReceiveOperation();
        if (!this.resumePendingTaildropAction()) {
          this.prefetchTaildropInboxFiles(this.host.getTaildropWaitingFiles());
        }
        return;
      }
      if (this.taildropReceiveMediaType !== undefined) {
        const mediaPath: string | undefined = this.prepareTaildropMediaForSave(result);
        if (mediaPath === undefined) {
          this.failTaildropReceive('export_failed');
          return;
        }
        this.taildropReceiveThumbnailPath = await this.createTaildropMediaThumbnail(
          this.taildropReceiveMediaType,
          mediaPath,
          `${this.taildropInboxRoot()}/${result.requestId}-active-thumb.jpg`
        );
        this.host.onCacheContentsChanged();
        const readyReceive: TaildropReceiveResult = {
          requestId: result.requestId,
          action: 'stage',
          state: 'awaiting_gallery_save',
          reason: '',
          name: result.name,
          size: result.size,
          path: mediaPath
        };
        this.host.setTaildropReceive(readyReceive);
        this.taildropReceiveStateStartedAtMs = 0;
        this.host.recordDiagnosticEvent('taildrop_media_ready_for_save', 'transfer');
        this.host.showTaildropToast('transfer_media_ready_to_save');
        return;
      }
      if (this.taildropReceiveStrategy === 'text-preview') {
        const generation: number = this.host.getLifecycleGeneration();
        const content: string | undefined = await this.readTaildropTextPreview(result);
        if (generation !== this.host.getLifecycleGeneration() ||
          this.host.getTaildropReceive().requestId !== result.requestId) {
          return;
        }
        if (content === undefined) {
          this.failTaildropReceive('export_failed');
          return;
        }
        const previewReceive: TaildropReceiveResult = {
          requestId: result.requestId,
          action: 'stage',
          state: 'awaiting_text_preview',
          reason: '',
          name: result.name,
          size: result.size,
          path: result.path
        };
        this.host.setTaildropReceive(previewReceive);
        this.host.setTaildropReceivedText(content);
        this.taildropReceiveStateStartedAtMs = 0;
        this.host.setTaildropTextPreviewVisible(false);
        this.host.recordDiagnosticEvent('taildrop_text_preview_ready', 'transfer');
        return;
      }
      const exportingReceive: TaildropReceiveResult = {
        requestId: result.requestId,
        action: 'stage',
        state: 'exporting',
        reason: '',
        name: result.name,
        size: result.size,
        path: result.path
      };
      this.host.setTaildropReceive(exportingReceive);
      this.taildropReceiveStateStartedAtMs = Date.now();
      if (this.taildropReceiveStrategy === 'file') {
        const destinationUri: string = await this.selectTaildropReceiveDestination(result);
        if (!this.isCurrentTaildropReceive(result.requestId, 'stage', 'exporting')) {
          return;
        }
        if (destinationUri.length === 0) {
          this.resetTaildropReceiveOperation();
          return;
        }
        this.taildropReceiveDestinationUri = destinationUri;
      }
      const handled: boolean = await this.handleTaildropStagedFile(result);
      if (!this.isCurrentTaildropReceive(result.requestId, 'stage', 'exporting')) {
        return;
      }
      if (!handled) {
        this.failTaildropReceive('export_failed');
        return;
      }
      this.requestTaildropReceiveDelete(result.requestId, result.name, result.size);
      return;
    }
    if (result.action === 'delete' && result.state === 'completed') {
      if (this.taildropReceiveStrategy === 'pending-delete') {
        this.completeTaildropPendingDelete();
      } else if (this.taildropReceiveStrategy === 'discard') {
        this.completeTaildropDiscard();
      } else {
        this.completeTaildropReceive();
      }
      return;
    }
    if (result.action === 'clear' && result.state === 'completed') {
      if (!this.clearLocalTaildropInboxCache()) {
        this.failTaildropReceive('clear_failed');
        return;
      }
      const requestedFromSettings: boolean = this.cacheClearRequestedFromSettings;
      this.taildropPendingDeletes = [];
      this.taildropPendingDeleteRetryAtMs = 0;
      this.clearTaildropInboxViewState();
      this.host.recordDiagnosticEvent('taildrop_receive_cache_cleared', 'transfer');
      this.resetTaildropReceiveOperation();
      if (requestedFromSettings) {
        this.finishSettingsCacheClear(true);
      } else {
        this.host.onCacheContentsChanged();
        this.host.showTaildropToast('transfer_cache_cleared');
      }
      return;
    }
    this.failTaildropReceive('invalid_result');
  }

  isCurrentTaildropReceive(requestId: number, action: string, state: string): boolean {
    const receive: TaildropReceiveResult = this.host.getTaildropReceive();
    return this.host.isTaildropReceiveInProgress() && receive.requestId === requestId &&
      receive.action === action && receive.state === state;
  }

  private prepareTaildropMediaForSave(result: TaildropReceiveResult): string | undefined {
    return this.normalizeTaildropMediaPath(result.name, result.size, result.path);
  }

  normalizeTaildropMediaPath(name: string, size: number, sourcePath: string): string | undefined {
    if (name.length === 0 || name.length > 255 || name === '.' || name === '..' ||
      name.includes('/') || name.includes('\\') || name.includes('\u0000')) {
      return undefined;
    }
    const mediaPath: string = `${this.taildropInboxRoot()}/${name}`;
    try {
      const sourceStat: fileIo.Stat = fileIo.statSync(sourcePath);
      if (!sourceStat.isFile() || sourceStat.size !== size) {
        return undefined;
      }
      if (sourcePath === mediaPath) {
        return mediaPath;
      }
      if (fileIo.accessSync(mediaPath)) {
        fileIo.unlinkSync(mediaPath);
      }
      fileIo.renameSync(sourcePath, mediaPath);
      const stat: fileIo.Stat = fileIo.statSync(mediaPath);
      if (!stat.isFile() || stat.size !== size) {
        fileIo.unlinkSync(mediaPath);
        return undefined;
      }
      return mediaPath;
    } catch (_error) {
      return undefined;
    }
  }

  requestTaildropReceiveDelete(requestId: number, name: string, size: number): void {
    if (!this.taildropReceiveGateway.claimRemoteDelete(requestId, name)) {
      return;
    }
    const deleteRequest: TaildropReceiveRequest =
      this.taildropReceiveGateway.createDeleteRequest(requestId, name);
    const deletingReceive: TaildropReceiveResult = {
      requestId: requestId,
      action: 'delete',
      state: 'deleting',
      reason: '',
      name: name,
      size: size,
      path: ''
    };
    this.host.setTaildropReceive(deletingReceive);
    this.taildropReceiveStateStartedAtMs = Date.now();
    if (!this.dispatchTaildropReceiveRequest(deleteRequest)) {
      this.host.recordDiagnosticEvent('taildrop_receive_delete_deferred', 'request_unavailable');
      if (this.taildropReceiveStrategy === 'discard') {
        this.completeTaildropDiscard(true);
      } else {
        this.completeTaildropReceive(true);
      }
    }
  }

  submitNextTaildropPendingDelete(): void {
    if (this.host.getTaildropState() !== 'ready' || this.host.getTaildropInboxReason().length > 0 ||
      this.taildropPendingDeletes.length === 0 || this.host.isTaildropReceiveInProgress() ||
      this.taildropReceiveResponseInFlight || this.taildropSendActive() ||
      Date.now() < this.taildropPendingDeleteRetryAtMs) {
      return;
    }
    const pending: TaildropWaitingFileSummary = this.taildropPendingDeletes[0];
    const requestId: number = Date.now();
    const request: TaildropReceiveRequest =
      this.taildropReceiveGateway.createDeleteRequest(requestId, pending.name);
    this.taildropReceiveStrategy = 'pending-delete';
    this.taildropReceiveExpectedSize = pending.size;
    this.host.setTaildropReceiveInProgress(true);
    const deletingReceive: TaildropReceiveResult = {
      requestId: requestId,
      action: 'delete',
      state: 'deleting',
      reason: '',
      name: pending.name,
      size: pending.size,
      path: ''
    };
    this.host.setTaildropReceive(deletingReceive);
    this.taildropReceiveStateStartedAtMs = Date.now();
    this.writePrivateTextFile(this.taildropReceiveResponsePath(), '');
    if (!this.dispatchTaildropReceiveRequest(request)) {
      this.deferTaildropPendingDelete('request_unavailable');
      return;
    }
    this.host.recordDiagnosticEvent('taildrop_pending_delete_requested', 'reconnect');
  }

  completeTaildropPendingDelete(): void {
    const receive: TaildropReceiveResult = this.host.getTaildropReceive();
    const deletedName: string = receive.name;
    const deletedSize: number = receive.size;
    this.taildropPendingDeletes = this.taildropPendingDeletes.filter(
      (pending: TaildropWaitingFileSummary) =>
        pending.name !== deletedName || pending.size !== deletedSize);
    this.taildropPendingDeleteRetryAtMs = 0;
    this.persistTaildropInbox();
    this.host.recordDiagnosticEvent('taildrop_pending_delete_completed', 'reconnect');
    this.resetTaildropReceiveOperation();
    this.host.scheduleLifecycleTask(() => this.submitNextTaildropPendingDelete(), 0);
  }

  deferTaildropPendingDelete(reason: string): void {
    this.host.recordDiagnosticEvent('taildrop_pending_delete_deferred', reason);
    this.taildropPendingDeleteRetryAtMs = Date.now() + TAILDROP_PENDING_DELETE_RETRY_MS;
    this.resetTaildropReceiveOperation();
  }

  handlePreparedTaildropMediaSaveClick(file: TaildropWaitingFileSummary): void {
    const preview: TaildropMediaPreview | undefined = this.findTaildropMediaPreview(file);
    if (preview === undefined) {
      return;
    }
    this.interruptTaildropPrefetch();
    if (this.host.isTaildropReceiveInProgress()) {
      const receive: TaildropReceiveResult = this.host.getTaildropReceive();
      if (receive.name === file.name && receive.state === 'awaiting_gallery_save') {
        this.startTaildropMediaSave();
        return;
      }
      if (receive.state === 'awaiting_text_preview') {
        this.resetTaildropReceiveOperation();
        this.startPreparedTaildropMediaSave(file);
        return;
      }
      this.taildropPendingMediaSave = file;
      this.host.recordDiagnosticEvent('taildrop_media_save_queued', 'transfer');
      return;
    }
    this.startPreparedTaildropMediaSave(file);
  }

  startPreparedTaildropFileSave(file: TaildropWaitingFileSummary): void {
    const cached: TaildropCachedFile | undefined = this.findTaildropCachedFile(file);
    if (cached === undefined) {
      if (this.host.getTaildropState() !== 'ready') {
        this.host.showTaildropToast('transfer_connect_first_title');
        this.releaseTaildropNotificationActionClaim();
      } else {
        this.startTaildropReceive(file);
      }
      return;
    }
    if (this.taildropSendActive() || this.host.isTaildropReceiveInProgress()) {
      this.host.showTaildropToast('transfer_busy_message');
      this.releaseTaildropNotificationActionClaim();
      return;
    }
    this.taildropReceiveStrategy = 'file';
    this.taildropReceiveExpectedSize = cached.size;
    this.host.setTaildropReceiveInProgress(true);
    const selectingReceive: TaildropReceiveResult = {
      requestId: cached.requestId,
      action: 'stage',
      state: 'selecting_destination',
      reason: '',
      name: cached.name,
      size: cached.size,
      path: cached.path
    };
    this.host.setTaildropReceive(selectingReceive);
    this.selectTaildropReceiveDestination(selectingReceive).then((destinationUri: string) => {
      if (!this.isCurrentTaildropReceive(cached.requestId, 'stage', 'selecting_destination')) {
        return;
      }
      if (destinationUri.length === 0) {
        this.resetTaildropReceiveOperation();
        return;
      }
      this.taildropReceiveDestinationUri = destinationUri;
      const exportingReceive: TaildropReceiveResult = {
        requestId: cached.requestId,
        action: 'stage',
        state: 'exporting',
        reason: '',
        name: cached.name,
        size: cached.size,
        path: cached.path
      };
      this.host.setTaildropReceive(exportingReceive);
      this.copyTaildropStagedFile(cached.path, destinationUri, cached.size).then((saved: boolean) => {
        if (!this.isCurrentTaildropReceive(cached.requestId, 'stage', 'exporting')) {
          return;
        }
        if (!saved) {
          this.failTaildropReceive('export_failed');
          return;
        }
        if (this.host.getTaildropState() === 'ready') {
          this.requestTaildropReceiveDelete(cached.requestId, cached.name, cached.size);
        } else {
          this.completeTaildropReceive(true);
        }
      }).catch(() => this.failTaildropReceive('export_failed'));
    }).catch(() => this.failTaildropReceive('export_failed'));
  }

  startPreparedTaildropMediaSave(file: TaildropWaitingFileSummary): void {
    const preview: TaildropMediaPreview | undefined = this.findTaildropMediaPreview(file);
    if (preview === undefined || this.host.isTaildropReceiveInProgress()) {
      this.releaseTaildropNotificationActionClaim();
      return;
    }
    this.taildropReceiveStrategy = 'media';
    this.taildropReceiveDestinationUri = '';
    this.taildropReceiveExpectedSize = preview.size;
    this.taildropReceiveMediaType = preview.mediaType;
    this.taildropReceiveThumbnailPath = preview.thumbnailPath;
    this.host.setTaildropReceiveInProgress(true);
    const awaitingSaveReceive: TaildropReceiveResult = {
      requestId: preview.requestId,
      action: 'stage',
      state: 'awaiting_gallery_save',
      reason: '',
      name: preview.name,
      size: preview.size,
      path: preview.path
    };
    this.host.setTaildropReceive(awaitingSaveReceive);
    this.taildropReceiveStateStartedAtMs = 0;
    this.startTaildropMediaSave();
  }

  startTaildropMediaSave(): void {
    if (this.host.isTaildropMediaSaveInProgress() ||
      this.host.getTaildropReceive().state !== 'awaiting_gallery_save') {
      return;
    }
    this.host.setTaildropMediaSaveInProgress(true);
    this.saveTaildropMediaToGallery().then((saved: boolean) => {
      if (!saved) {
        this.restoreTaildropMediaSaveAfterFailure(false);
      }
    }).catch((error: BusinessError) => {
      const mediaKind: string = this.taildropReceiveMediaType === photoAccessHelper.PhotoType.VIDEO ?
        'video' : 'image';
      const extension: string = this.taildropFileExtension(this.host.getTaildropReceive().name);
      this.host.recordDiagnosticEvent(
        'taildrop_media_save_failed',
        extension.length > 0 ? `${mediaKind}_${extension}` : mediaKind,
        error.code ?? -1
      );
      this.restoreTaildropMediaSaveAfterFailure(true);
    }).finally(() => {
      this.host.setTaildropMediaSaveInProgress(false);
    });
  }

  private restoreTaildropMediaSaveAfterFailure(showFailure: boolean): void {
    const receive: TaildropReceiveResult = this.host.getTaildropReceive();
    if (!this.host.isTaildropMediaSaveInProgress() || receive.state !== 'saving_gallery' ||
      receive.path.length === 0) {
      return;
    }
    const restored: TaildropReceiveResult = {
      requestId: receive.requestId,
      action: 'stage',
      state: 'awaiting_gallery_save',
      reason: '',
      name: receive.name,
      size: receive.size,
      path: receive.path
    };
    this.host.setTaildropReceive(restored);
    if (showFailure) {
      this.host.showTaildropToast('transfer_media_save_failed');
    }
  }

  validTaildropMediaTimestamp(timestampMs: number): boolean {
    return Number.isFinite(timestampMs) && timestampMs >= TAILDROP_MEDIA_MIN_TIMESTAMP_MS &&
      timestampMs <= Date.now() + TAILDROP_MEDIA_MAX_FUTURE_MS;
  }

  taildropLocalDateTimestamp(
    year: number,
    month: number,
    day: number,
    hour: number,
    minute: number,
    second: number
  ): number | undefined {
    const date: Date = new Date(year, month - 1, day, hour, minute, second, 0);
    const timestampMs: number = date.getTime();
    if (!this.validTaildropMediaTimestamp(timestampMs) || date.getFullYear() !== year ||
      date.getMonth() !== month - 1 || date.getDate() !== day || date.getHours() !== hour ||
      date.getMinutes() !== minute || date.getSeconds() !== second) {
      return undefined;
    }
    return timestampMs;
  }

  parseTaildropMediaDateTime(value: string): number | undefined {
    const normalized: string = value.trim();
    const localMatch: RegExpMatchArray | null = normalized.match(
      /^(\d{4})[-/]?(\d{2})[-/]?(\d{2})[ T]?(\d{2}):?(\d{2}):?(\d{2})/);
    if (localMatch !== null) {
      const timestampMs: number | undefined = this.taildropLocalDateTimestamp(
        Number(localMatch[1]), Number(localMatch[2]), Number(localMatch[3]),
        Number(localMatch[4]), Number(localMatch[5]), Number(localMatch[6]));
      if (timestampMs !== undefined) {
        return timestampMs;
      }
    }
    const parsedTimestampMs: number = Date.parse(normalized);
    return this.validTaildropMediaTimestamp(parsedTimestampMs) ? parsedTimestampMs : undefined;
  }

  taildropMediaTimestampFromName(name: string): number | undefined {
    const extensionIndex: number = name.lastIndexOf('.');
    const baseName: string = extensionIndex > 0 ? name.substring(0, extensionIndex) : name;
    const epochMatch: RegExpMatchArray | null = baseName.match(/(\d{13})(?:[^0-9]|$)/);
    if (epochMatch !== null) {
      const epochTimestampMs: number = Number(epochMatch[1]);
      if (this.validTaildropMediaTimestamp(epochTimestampMs)) {
        return epochTimestampMs;
      }
    }
    const compactMatch: RegExpMatchArray | null = baseName.match(
      /(\d{4})(\d{2})(\d{2})[_-](\d{2})(\d{2})(\d{2})(?:[^0-9]|$)/);
    if (compactMatch === null) {
      return undefined;
    }
    return this.taildropLocalDateTimestamp(
      Number(compactMatch[1]), Number(compactMatch[2]), Number(compactMatch[3]),
      Number(compactMatch[4]), Number(compactMatch[5]), Number(compactMatch[6]));
  }

  async restoreTaildropVideoMtime(
    name: string,
    path: string,
    size: number
  ): Promise<number | undefined> {
    let sourceFile: fileIo.File | undefined = undefined;
    let extractor: media.AVMetadataExtractor | undefined = undefined;
    try {
      sourceFile = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      extractor = await this.withMediaTimeout<media.AVMetadataExtractor>(
        media.createAVMetadataExtractor(), 5000);
      const fdSrc: media.AVFileDescriptor = { fd: sourceFile.fd, offset: 0, length: size };
      extractor.fdSrc = fdSrc;
      const metadata: media.AVMetadata = await this.withMediaTimeout<media.AVMetadata>(
        extractor.fetchMetadata(), 5000);
      let timestampFromName: boolean = false;
      let timestampMs: number | undefined = metadata.dateTimeFormat === undefined ? undefined :
        this.parseTaildropMediaDateTime(metadata.dateTimeFormat);
      if (timestampMs === undefined && metadata.dateTime !== undefined) {
        timestampMs = this.parseTaildropMediaDateTime(metadata.dateTime);
      }
      if (timestampMs === undefined) {
        timestampMs = this.taildropMediaTimestampFromName(name);
        timestampFromName = timestampMs !== undefined;
      }
      if (timestampMs === undefined) {
        return undefined;
      }
      const durationMs: number = metadata.duration === undefined ? 0 : Number(metadata.duration);
      if (timestampFromName && Number.isFinite(durationMs) && durationMs > 0 &&
        durationMs <= TAILDROP_MEDIA_MAX_DURATION_MS &&
        this.validTaildropMediaTimestamp(timestampMs + durationMs)) {
        timestampMs += durationMs;
      }
      fileIo.utimes(path, timestampMs);
      const mtimeSec: number = fileIo.statSync(path).mtime;
      return Number.isFinite(mtimeSec) && mtimeSec > 0 ? mtimeSec * 1000 : undefined;
    } catch (_error) {
      return undefined;
    } finally {
      if (extractor !== undefined) {
        try {
          await this.withMediaTimeout<void>(extractor.release(), 1500);
        } catch (_error) {
        }
      }
      if (sourceFile !== undefined) {
        try {
          fileIo.closeSync(sourceFile);
        } catch (_error) {
        }
      }
    }
  }

  async saveTaildropMediaToGallery(): Promise<boolean> {
    const mediaType: photoAccessHelper.PhotoType | undefined = this.taildropReceiveMediaType;
    const staged: TaildropReceiveResult = this.host.getTaildropReceive();
    const extension: string = this.taildropFileExtension(staged.name);
    if (mediaType === undefined || extension.length === 0 ||
      staged.state !== 'awaiting_gallery_save' || staged.path.length === 0) {
      return false;
    }
    let stat: fileIo.Stat;
    try {
      stat = fileIo.statSync(staged.path);
    } catch (_error) {
      this.failTaildropReceive('export_failed');
      return false;
    }
    if (!stat.isFile() || stat.size !== staged.size) {
      this.failTaildropReceive('export_failed');
      return false;
    }
    const savingReceive: TaildropReceiveResult = {
      requestId: staged.requestId,
      action: 'stage',
      state: 'saving_gallery',
      reason: '',
      name: staged.name,
      size: staged.size,
      path: staged.path
    };
    this.host.setTaildropReceive(savingReceive);
    this.taildropReceiveStateStartedAtMs = Date.now();
    const phAccessHelper = photoAccessHelper.getPhotoAccessHelper(this.host.getAbilityContext());
    let restoredMtimeMs: number | undefined = undefined;
    if (mediaType === photoAccessHelper.PhotoType.VIDEO) {
      restoredMtimeMs = await this.restoreTaildropVideoMtime(staged.name, staged.path, staged.size);
    }
    const config: photoAccessHelper.PhotoCreationConfig = {
      title: this.taildropGalleryAssetTitle(staged.name),
      fileNameExtension: extension,
      photoType: mediaType
    };
    let destinationUri: string = '';
    try {
      const sourceUri: string = fileUri.getUriFromPath(staged.path);
      const destinationUris: string[] = await phAccessHelper.showAssetsCreationDialog(
        [sourceUri], [config]);
      destinationUri = destinationUris.length > 0 ? destinationUris[0] : '';
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      this.host.recordDiagnosticEvent(
        'taildrop_media_asset_create_failed',
        'creation_dialog',
        businessError.code ?? -1
      );
    }
    if (destinationUri.length === 0) {
      return false;
    }
    this.taildropReceiveDestinationUri = destinationUri;
    const copied: boolean = await this.copyTaildropStagedFile(staged.path, destinationUri, staged.size);
    if (!copied) {
      return false;
    }
    if (restoredMtimeMs !== undefined) {
      this.host.recordDiagnosticEvent('taildrop_media_mtime_restored', 'video');
    }
    if (!this.isCurrentTaildropReceive(staged.requestId, 'stage', 'saving_gallery')) {
      return false;
    }
    this.taildropReceivePreviewPath = await this.createTaildropHistoryPreview(
      staged.path, staged.name, staged.requestId);
    this.removeTaildropMediaPreview(staged.name, staged.size, true);
    try {
      if (fileIo.accessSync(staged.path)) {
        fileIo.unlinkSync(staged.path);
      }
    } catch (_error) {
      // The receive operation reset retries cleanup after the remote inbox entry is deleted.
    }
    this.host.recordDiagnosticEvent('taildrop_media_saved_to_gallery', 'transfer');
    if (this.host.getTaildropState() === 'ready') {
      this.requestTaildropReceiveDelete(staged.requestId, staged.name, staged.size);
    } else {
      this.completeTaildropReceive(true);
    }
    return true;
  }

  clearLocalTaildropInboxCache(): boolean {
    const root: string = this.taildropInboxRoot();
    try {
      if (!fileIo.accessSync(root)) {
        return true;
      }
      let cleared: boolean = true;
      fileIo.listFileSync(root).forEach((name: string) => {
        const path: string = `${root}/${name}`;
        try {
          const stat: fileIo.Stat = fileIo.statSync(path);
          if (stat.isFile()) {
            fileIo.unlinkSync(path);
          } else {
            cleared = false;
          }
        } catch (_error) {
          cleared = false;
        }
      });
      this.host.onCacheContentsChanged();
      return cleared;
    } catch (_error) {
      return false;
    }
  }

  async handleTaildropStagedFile(result: TaildropReceiveResult): Promise<boolean> {
    let handled: boolean = false;
    if (result.size === this.taildropReceiveExpectedSize) {
      if (this.taildropReceiveStrategy === 'image') {
        handled = await this.exportTaildropImageToGallery(result);
      } else if (this.taildropReceiveStrategy === 'text') {
        handled = await this.copyTaildropTextToClipboard(result);
      } else {
        handled = await this.exportTaildropReceivedFile(result);
      }
    }
    try {
      if (result.path.length > 0 && fileIo.accessSync(result.path)) {
        fileIo.unlinkSync(result.path);
      }
    } catch (_error) {
      // Extension startup cleanup removes any staged export left behind.
    }
    return handled;
  }

  async exportTaildropImageToGallery(result: TaildropReceiveResult): Promise<boolean> {
    const extension: string = this.taildropFileExtension(result.name);
    const mediaType: photoAccessHelper.PhotoType | undefined = this.resolveTaildropMediaType(result.name);
    if (mediaType === undefined) {
      return false;
    }
    try {
      const helper = photoAccessHelper.getPhotoAccessHelper(this.host.getAbilityContext());
      const config: photoAccessHelper.PhotoCreationConfig = {
        title: this.taildropGalleryAssetTitle(result.name),
        fileNameExtension: extension,
        photoType: mediaType
      };
      const configs: photoAccessHelper.PhotoCreationConfig[] = [config];
      const sourceUri: string = fileUri.getUriFromPath(result.path);
      const destinationUris: string[] = await helper.showAssetsCreationDialog([sourceUri], configs);
      if (destinationUris.length === 0) {
        return false;
      }
      this.taildropReceiveDestinationUri = destinationUris[0];
      return await this.copyTaildropStagedFile(result.path, destinationUris[0], result.size);
    } catch (_error) {
      return false;
    }
  }

  async copyTaildropTextToClipboard(result: TaildropReceiveResult): Promise<boolean> {
    if (this.host.isSecurityCoverActive()) {
      return false;
    }
    if (result.size > TAILDROP_TEXT_CLIPBOARD_MAX_BYTES || result.path.length === 0) {
      return false;
    }
    try {
      const stat: fileIo.Stat = typeof fileIo.stat === 'function' ?
        await fileIo.stat(result.path) : fileIo.statSync(result.path);
      if (!stat.isFile() || stat.size > TAILDROP_TEXT_CLIPBOARD_MAX_BYTES) {
        return false;
      }
      const content: string = typeof fileIo.readText === 'function' ?
        await fileIo.readText(result.path) : fileIo.readTextSync(result.path);
      if (this.host.isSecurityCoverActive()) {
        return false;
      }
      const data: pasteboard.PasteData = createLocalTextPasteData(content);
      await pasteboard.getSystemPasteboard().setData(data);
      return true;
    } catch (_error) {
      return false;
    }
  }

  openTaildropExportDestination(destinationUri: string): fileIo.File {
    try {
      return fileIo.openSync(destinationUri, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    } catch (_error) {
      return fileIo.openSync(
        destinationUri,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
      );
    }
  }

  async copyTaildropStagedFile(
    sourcePath: string,
    destinationUri: string,
    expectedSize: number
  ): Promise<boolean> {
    let source: fileIo.File | undefined = undefined;
    let destination: fileIo.File | undefined = undefined;
    let verifier: fileIo.File | undefined = undefined;
    let copied: boolean = false;
    try {
      if (destinationUri.length === 0) {
        copied = false;
      } else {
        source = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
        destination = this.openTaildropExportDestination(destinationUri);
        await fileIo.copyFile(source.fd, destination.fd);
        fileIo.closeSync(source);
        source = undefined;
        fileIo.closeSync(destination);
        destination = undefined;
        verifier = fileIo.openSync(destinationUri, fileIo.OpenMode.READ_ONLY);
        const stat: fileIo.Stat = fileIo.statSync(verifier.fd);
        copied = stat.isFile() && stat.size === expectedSize;
      }
    } catch (_error) {
      copied = false;
    }
    if (source !== undefined) {
      try {
        fileIo.closeSync(source);
      } catch (_error) {
        copied = false;
      }
    }
    if (destination !== undefined) {
      try {
        fileIo.closeSync(destination);
      } catch (_error) {
        copied = false;
      }
    }
    if (verifier !== undefined) {
      try {
        fileIo.closeSync(verifier);
      } catch (_error) {
        copied = false;
      }
    }
    if (!copied && destinationUri.length > 0) {
      try {
        fileIo.unlinkSync(destinationUri);
      } catch (_error) {
        // The system provider may not allow deleting a failed export URI.
      }
    }
    return copied;
  }

  async exportTaildropReceivedFile(result: TaildropReceiveResult): Promise<boolean> {
    return await this.copyTaildropStagedFile(
      result.path,
      this.taildropReceiveDestinationUri,
      result.size
    );
  }

  private addTaildropReceiveRecord(state: string, reason: string): void {
    const receive: TaildropReceiveResult = this.host.getTaildropReceive();
    const record: TaildropTransferRecord = {
      requestId: receive.requestId,
      direction: 'receive',
      state: state,
      reason: reason,
      targetKey: '',
      targetName: '',
      fileName: receive.name,
      fileCount: 1,
      totalBytes: receive.size > 0 ? receive.size : this.taildropReceiveExpectedSize,
      previewPath: this.taildropReceivePreviewPath,
      completedAtMs: Date.now()
    };
    this.host.setTaildropHistory(
      [record].concat(this.host.getTaildropHistory()).slice(0, TAILDROP_HISTORY_LIMIT)
    );
    this.persistTaildropHistory();
  }

  completeTaildropReceive(queueBackendDelete: boolean = false): void {
    const receive: TaildropReceiveResult = this.host.getTaildropReceive();
    const receivedName: string = receive.name;
    const receivedSize: number = receive.size;
    const receiveStrategy: string = this.taildropReceiveStrategy;
    const waitingFiles: TaildropWaitingFileSummary[] = this.host.getTaildropWaitingFiles();
    if (queueBackendDelete) {
      const receivedFile: TaildropWaitingFileSummary | undefined = waitingFiles.find(
        (file: TaildropWaitingFileSummary) => file.name === receivedName && file.size === receivedSize);
      const fallbackPending: TaildropWaitingFileSummary = {
        name: receivedName,
        size: receivedSize,
        receivedAtMs: Date.now()
      };
      this.queueTaildropPendingDelete(receivedFile === undefined ? fallbackPending : receivedFile);
    }
    this.addTaildropReceiveRecord('completed', '');
    this.removeTaildropMediaPreview(receivedName, receivedSize, true);
    this.removeTaildropCachedFile(receivedName, receivedSize, true);
    this.host.setTaildropWaitingFiles(waitingFiles.filter(
      (file: TaildropWaitingFileSummary) => file.name !== receivedName || file.size !== receivedSize));
    this.persistTaildropInbox();
    this.host.recordDiagnosticEvent('taildrop_receive_completed', 'transfer');
    if (receiveStrategy === 'image' ||
      (receiveStrategy === 'media' && this.taildropReceiveMediaType === photoAccessHelper.PhotoType.IMAGE)) {
      this.host.showTaildropToast('transfer_image_saved');
    } else if (receiveStrategy === 'text' || receiveStrategy === 'text-preview') {
      this.host.showTaildropToast('transfer_text_copied');
    } else {
      this.host.showTaildropToast('transfer_receive_completed');
    }
    this.resetTaildropReceiveOperation();
    this.resumePendingTaildropAction();
    this.host.onCacheContentsChanged();
  }

  completeTaildropDiscard(queueBackendDelete: boolean = false): void {
    const receive: TaildropReceiveResult = this.host.getTaildropReceive();
    const discardedName: string = receive.name;
    const discardedSize: number = receive.size;
    const waitingFiles: TaildropWaitingFileSummary[] = this.host.getTaildropWaitingFiles();
    if (queueBackendDelete) {
      const discardedFile: TaildropWaitingFileSummary | undefined = waitingFiles.find(
        (file: TaildropWaitingFileSummary) => file.name === discardedName && file.size === discardedSize);
      const fallbackPending: TaildropWaitingFileSummary = {
        name: discardedName,
        size: discardedSize,
        receivedAtMs: Date.now()
      };
      this.queueTaildropPendingDelete(discardedFile === undefined ? fallbackPending : discardedFile);
    }
    this.removeTaildropMediaPreview(discardedName, discardedSize, true);
    this.removeTaildropCachedFile(discardedName, discardedSize, true);
    this.host.setTaildropWaitingFiles(waitingFiles.filter(
      (file: TaildropWaitingFileSummary) => file.name !== discardedName || file.size !== discardedSize));
    this.persistTaildropInbox();
    this.host.recordDiagnosticEvent('taildrop_receive_discarded', 'transfer');
    this.host.showTaildropToast('transfer_discard_completed');
    this.resetTaildropReceiveOperation();
    this.resumePendingTaildropAction();
    this.host.onCacheContentsChanged();
  }

  failTaildropReceive(reason: string): void {
    if (this.taildropReceiveStrategy === 'pending-delete') {
      this.deferTaildropPendingDelete(reason);
      return;
    }
    const receive: TaildropReceiveResult = this.host.getTaildropReceive();
    if (receive.action === 'delete') {
      this.host.recordDiagnosticEvent('taildrop_receive_delete_deferred', reason);
      if (this.taildropReceiveStrategy === 'discard') {
        this.completeTaildropDiscard(true);
      } else {
        this.completeTaildropReceive(true);
      }
      return;
    }
    if (this.taildropReceiveStrategy === 'media-prefetch' ||
      this.taildropReceiveStrategy === 'file-prefetch') {
      this.failTaildropMediaPrefetch(reason);
      return;
    }
    const settingsCacheClearFailed: boolean =
      this.cacheClearRequestedFromSettings && receive.action === 'clear';
    if (receive.requestId > 0 && receive.action !== 'clear') {
      this.addTaildropReceiveRecord('failed', reason);
    }
    this.host.recordDiagnosticEvent('taildrop_receive_failed', reason);
    if (!settingsCacheClearFailed) {
      this.host.showTaildropToast(this.taildropReceiveFailureToastKey(reason));
    }
    this.resetTaildropReceiveOperation();
    this.resumePendingTaildropAction();
    if (settingsCacheClearFailed) {
      this.finishSettingsCacheClear(false);
    }
  }

  failTaildropMediaPrefetch(reason: string): void {
    const key: string = this.taildropAutoPrefetchKey;
    if (key.length > 0 && !this.taildropAutoPrefetchFailedKeys.includes(key)) {
      this.taildropAutoPrefetchFailedKeys = this.taildropAutoPrefetchFailedKeys.concat([key]);
    }
    this.host.recordDiagnosticEvent('taildrop_media_preview_failed', reason);
    this.taildropAutoPrefetchKey = '';
    this.resetTaildropReceiveOperation();
    this.resumePendingTaildropAction();
  }

  resetTaildropReceiveOperation(): void {
    this.releaseTaildropNotificationActionClaim();
    const receivePath: string = this.host.getTaildropReceive().path;
    const receiveThumbnailPath: string = this.taildropReceiveThumbnailPath;
    const previews: TaildropMediaPreview[] = this.host.getTaildropMediaPreviews();
    const cachedFiles: TaildropCachedFile[] = this.host.getTaildropCachedFiles();
    const pathIsCachedPreview: boolean = previews.some(
      (preview: TaildropMediaPreview) => preview.path === receivePath) ||
      cachedFiles.some((cached: TaildropCachedFile) => cached.path === receivePath);
    const thumbnailIsCachedPreview: boolean = previews.some(
      (preview: TaildropMediaPreview) => preview.thumbnailPath === receiveThumbnailPath);
    if (receivePath.length > 0 && !pathIsCachedPreview) {
      try {
        if (fileIo.accessSync(receivePath)) {
          fileIo.unlinkSync(receivePath);
        }
      } catch (_error) {
        // Extension startup cleanup removes any staged export left behind.
      }
    }
    if (receiveThumbnailPath.length > 0 && !thumbnailIsCachedPreview) {
      try {
        if (fileIo.accessSync(receiveThumbnailPath)) {
          fileIo.unlinkSync(receiveThumbnailPath);
          this.host.onCacheContentsChanged();
        }
      } catch (_error) {
        // A later inbox-cache cleanup removes an inaccessible temporary thumbnail.
      }
    }
    this.host.setTaildropReceiveInProgress(false);
    this.taildropReceiveResponseInFlight = false;
    this.host.setTaildropMediaSaveInProgress(false);
    this.setTaildropPickerOpen(false);
    this.taildropReceiveStateStartedAtMs = 0;
    this.taildropReceiveDestinationUri = '';
    this.taildropReceiveExpectedSize = 0;
    this.taildropReceiveMediaType = undefined;
    this.taildropReceivePreviewPath = '';
    this.taildropReceiveThumbnailPath = '';
    this.taildropReceiveStrategy = 'none';
    this.host.setTaildropReceive(emptyTaildropReceive());
    this.host.setTaildropReceivedText('');
    this.host.setTaildropTextPreviewVisible(false);
  }

  async readTaildropTextPreview(result: TaildropReceiveResult): Promise<string | undefined> {
    if (result.size > TAILDROP_TEXT_CLIPBOARD_MAX_BYTES || result.path.length === 0) {
      return undefined;
    }
    try {
      const stat: fileIo.Stat = typeof fileIo.stat === 'function' ?
        await fileIo.stat(result.path) : fileIo.statSync(result.path);
      if (!stat.isFile() || stat.size !== result.size || stat.size > TAILDROP_TEXT_CLIPBOARD_MAX_BYTES) {
        return undefined;
      }
      return typeof fileIo.readText === 'function' ?
        await fileIo.readText(result.path) : fileIo.readTextSync(result.path);
    } catch (_error) {
      return undefined;
    }
  }

  collapseTaildropTextPreview(): void {
    if (this.host.getTaildropReceive().state !== 'awaiting_text_preview') {
      return;
    }
    this.resetTaildropReceiveOperation();
  }

  copyTaildropTextPreview(): void {
    if (this.host.isSecurityCoverActive()) {
      this.releaseTaildropNotificationActionClaim();
      return;
    }
    const staged: TaildropReceiveResult = this.host.getTaildropReceive();
    if (staged.state !== 'awaiting_text_preview') {
      this.releaseTaildropNotificationActionClaim();
      return;
    }
    const copyingReceive: TaildropReceiveResult = {
      requestId: staged.requestId,
      action: 'stage',
      state: 'copying_text',
      reason: '',
      name: staged.name,
      size: staged.size,
      path: staged.path
    };
    this.host.setTaildropReceive(copyingReceive);
    this.taildropReceiveStateStartedAtMs = Date.now();
    this.host.setTaildropTextPreviewVisible(false);
    const data: pasteboard.PasteData = createLocalTextPasteData(this.host.getTaildropReceivedText());
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      if (!this.isCurrentTaildropReceive(staged.requestId, 'stage', 'copying_text')) {
        return;
      }
      if (this.host.getTaildropState() === 'ready') {
        this.requestTaildropReceiveDelete(staged.requestId, staged.name, staged.size);
      } else {
        this.completeTaildropReceive(true);
      }
    }).catch(() => {
      if (!this.isCurrentTaildropReceive(staged.requestId, 'stage', 'copying_text')) {
        return;
      }
      const restoredReceive: TaildropReceiveResult = {
        requestId: staged.requestId,
        action: 'stage',
        state: 'awaiting_text_preview',
        reason: '',
        name: staged.name,
        size: staged.size,
        path: staged.path
      };
      this.host.setTaildropReceive(restoredReceive);
      this.taildropReceiveStateStartedAtMs = 0;
      this.host.setTaildropTextPreviewVisible(true);
      this.host.showTaildropToast('transfer_text_copy_failed');
    });
  }
}
