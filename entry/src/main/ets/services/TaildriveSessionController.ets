import {
  PreparedTaildriveFile,
  TaildriveEntry,
  TaildriveListResult,
  TaildriveMutationRequest,
  TaildriveMutationResult,
  TaildriveStatResult,
  TaildriveTransferRequest,
  TaildriveTransferSnapshot,
  extractFileExtension,
  isImageEntry,
  isVideoEntry
} from '@tailscale/common';

const UNSAFE_NAME_CONTROL_CHARS: RegExp =
  /[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/;
const UNSAFE_NAME_CONTROL_CHARS_GLOBAL: RegExp =
  /[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g;

export type TaildriveConfirmationKind =
  'delete_single' | 'delete_selected' | 'overwrite_mutation' | 'overwrite_upload';

export interface TaildriveConfirmationPrompt {
  kind: TaildriveConfirmationKind;
  itemName: string;
  selectedCount: number;
  autoCancel: boolean;
  onCancel: () => void;
  onDismiss: () => void;
  onConfirm: () => void;
}

export interface TaildriveGroupedBucket {
  key: string;
  entries: TaildriveEntry[];
}

export function emptyTaildriveEntry(): TaildriveEntry {
  return { name: '', path: '', kind: '', size: 0, modifiedAtMs: 0 };
}

export function idleTaildriveTransfer(): TaildriveTransferSnapshot {
  return {
    requestId: 0,
    direction: '',
    state: 'idle',
    reason: '',
    remotePath: '',
    localPath: '',
    fileName: '',
    bytes: 0,
    totalBytes: 0,
    startedAtMs: 0,
    completedAtMs: 0
  };
}

export function snapshotTaildriveEntry(entry: TaildriveEntry): TaildriveEntry {
  return {
    name: entry.name,
    path: entry.path,
    kind: entry.kind,
    size: entry.size,
    modifiedAtMs: entry.modifiedAtMs,
    contentType: entry.contentType,
    etag: entry.etag
  };
}

export function localTaildriveFileSnapshot(entry: TaildriveEntry): TaildriveEntry {
  return {
    name: entry.name,
    path: entry.path,
    kind: entry.kind,
    size: entry.size,
    modifiedAtMs: entry.modifiedAtMs
  };
}

export function matchesLocalTaildriveFile(candidate: TaildriveEntry, entry: TaildriveEntry): boolean {
  return candidate.kind === 'file' && entry.kind === 'file' && candidate.path === entry.path &&
    candidate.name === entry.name && candidate.size === entry.size &&
    candidate.modifiedAtMs === entry.modifiedAtMs;
}

export function normalizeTaildriveFolderPath(remotePath: string): string {
  const normalized: string = remotePath.trim().replace(/\/+$/, '');
  return normalized.length > 0 ? normalized : '/';
}

export function taildrivePathDepth(remotePath: string): number {
  return remotePath.split('/').filter((segment: string) => segment.length > 0).length;
}

export function taildrivePathIsWithin(remotePath: string, folderPath: string): boolean {
  const normalizedPath: string = normalizeTaildriveFolderPath(remotePath);
  const normalizedFolder: string = normalizeTaildriveFolderPath(folderPath);
  return normalizedPath === normalizedFolder || normalizedPath.startsWith(`${normalizedFolder}/`);
}

export function taildriveParentPath(remotePath: string): string {
  const slash: number = remotePath.lastIndexOf('/');
  return slash <= 0 ? '/' : remotePath.substring(0, slash);
}

export function taildriveJoinPath(parent: string, name: string): string {
  const encoded: string = encodeURIComponent(name);
  return parent === '/' ? `/${encoded}` : `${parent}/${encoded}`;
}

export function taildrivePathName(remotePath: string): string {
  const slash: number = remotePath.lastIndexOf('/');
  const encoded: string = slash >= 0 ? remotePath.substring(slash + 1) : remotePath;
  try {
    return decodeURIComponent(encoded);
  } catch (_error) {
    return encoded;
  }
}

export function taildriveShareRoot(remotePath: string): string {
  const segments: string[] = remotePath.split('/').filter((segment: string) => segment.length > 0);
  return segments.length >= 3 ?
    `/${segments[0]}/${segments[1]}/${segments[2]}` : taildriveParentPath(remotePath);
}

export function isValidTaildriveName(name: string): boolean {
  return name.length > 0 && name.length <= 255 && name !== '.' && name !== '..' &&
    !name.includes('/') && !name.includes('\\') &&
    !UNSAFE_NAME_CONTROL_CHARS.test(name);
}

export function sanitizeTaildriveLocalName(name: string): string {
  let value: string = name.replace(UNSAFE_NAME_CONTROL_CHARS_GLOBAL, '');
  const slash: number = Math.max(value.lastIndexOf('/'), value.lastIndexOf('\\'));
  if (slash >= 0) {
    value = value.substring(slash + 1);
  }
  value = value.replace(/[\\/:*?"<>|]/g, '_').trim();
  if (value === '.' || value === '..') {
    return 'download';
  }
  return value.length > 0 ? value : 'download';
}

export function sanitizeTaildriveRemoteName(name: string): string {
  const value: string = sanitizeTaildriveLocalName(name);
  return value.length > 0 ? value : `upload-${Date.now()}`;
}

export function sanitizeTaildriveDisplayLabel(value: string): string {
  return value.replace(UNSAFE_NAME_CONTROL_CHARS_GLOBAL, '');
}

export function decodeTaildriveDisplayPath(value: string): string {
  try {
    return sanitizeTaildriveDisplayLabel(decodeURIComponent(value));
  } catch (_error) {
    return sanitizeTaildriveDisplayLabel(value);
  }
}

export function taildrivePathSegments(rawPath: string): string[] {
  return rawPath.split('/').filter((segment: string) => segment.length > 0).map((segment: string) => {
    try {
      return sanitizeTaildriveDisplayLabel(decodeURIComponent(segment));
    } catch (_error) {
      return sanitizeTaildriveDisplayLabel(segment);
    }
  });
}

export function buildTaildriveSegmentPath(rawPath: string, index: number): string {
  const rawSegments: string[] = rawPath.split('/').filter((segment: string) => segment.length > 0);
  let result: string = '/';
  for (let cursor: number = 0; cursor <= index && cursor < rawSegments.length; cursor++) {
    result = result === '/' ? `/${rawSegments[cursor]}` : `${result}/${rawSegments[cursor]}`;
  }
  return result;
}

export function computeTaildriveDragSelectedPaths(
  flatEntries: TaildriveEntry[],
  baseSelectedPaths: string[],
  anchorIndex: number,
  currentIndex: number,
  selectTarget: boolean
): string[] {
  if (flatEntries.length === 0 || anchorIndex < 0 || anchorIndex >= flatEntries.length ||
    currentIndex < 0 || currentIndex >= flatEntries.length) {
    return [...baseSelectedPaths];
  }
  const start: number = Math.max(0, Math.min(anchorIndex, currentIndex));
  const end: number = Math.min(flatEntries.length - 1, Math.max(anchorIndex, currentIndex));
  const rangePaths: string[] = [];
  for (let index: number = start; index <= end; index++) {
    rangePaths.push(flatEntries[index].path);
  }
  if (selectTarget) {
    const next: string[] = [...baseSelectedPaths];
    for (let index: number = 0; index < rangePaths.length; index++) {
      if (!next.includes(rangePaths[index])) {
        next.push(rangePaths[index]);
      }
    }
    return next;
  }
  return baseSelectedPaths.filter((path: string) => !rangePaths.includes(path));
}

export interface TaildriveSessionHost {
  isConnected: () => boolean;
  isStandalone: () => boolean;
  isFilesTabActive: () => boolean;
  isBrowserVisible: () => boolean;
  isAppInForeground: () => boolean;
  setAppInForeground: (value: boolean) => void;
  isAppLockActive: () => boolean;
  isFolderLockEnabled: () => boolean;
  getLockedFolderPaths: () => string[];
  setLockedFolderPaths: (paths: string[]) => void;
  getFolderAccessGrants: () => string[];
  setFolderAccessGrants: (grants: string[]) => void;
  isFolderAccessAuthInFlight: () => boolean;
  setFolderAccessAuthInFlight: (value: boolean) => void;
  isFolderPolicyAuthInFlight: () => boolean;
  setFolderPolicyAuthInFlight: (value: boolean) => void;

  getTargetMachineName: () => string;
  getTargetTailnetName: () => string;
  getTargetRequestId: () => number;

  getPath: () => string;
  setPath: (path: string) => void;
  getEntries: () => TaildriveEntry[];
  setEntries: (entries: TaildriveEntry[]) => void;
  getLastListedPath: () => string;
  setLastListedPath: (path: string) => void;
  isLoading: () => boolean;
  setLoading: (value: boolean) => void;
  isPullRefreshing: () => boolean;
  setPullRefreshing: (value: boolean) => void;
  isBusy: () => boolean;
  setBusy: (value: boolean) => void;
  getReason: () => string;
  setReason: (reason: string) => void;
  getStatus: () => string;
  setStatus: (status: string) => void;
  showTransientStatus: (status: string) => void;
  isRetryAvailable: () => boolean;
  setRetryAvailable: (value: boolean) => void;

  getSearchQuery: () => string;
  setSearchQuery: (query: string) => void;
  isSearchVisible: () => boolean;
  setSearchVisibleRaw: (visible: boolean) => void;
  dismissSearchAnimated: () => void;
  getSortMode: () => string;
  isSortDescending: () => boolean;
  getGroupMode: () => string;

  isSelectionMode: () => boolean;
  setSelectionMode: (value: boolean) => void;
  isDragSelecting: () => boolean;
  setDragSelecting: (value: boolean) => void;
  getSelectedPaths: () => string[];
  setSelectedPaths: (paths: string[]) => void;

  getFileActionGeneration: () => number;
  setFileActionGeneration: (value: number) => void;

  isEditorVisible: () => boolean;
  setEditorVisible: (visible: boolean) => void;
  isEditorSubmitInFlight: () => boolean;
  setEditorSubmitInFlight: (value: boolean) => void;
  getEditorName: () => string;
  setEditorName: (name: string) => void;
  getEditorOperation: () => string;
  setEditorOperation: (operation: string) => void;
  getEditorPath: () => string;
  setEditorPath: (path: string) => void;

  isFolderDialogVisible: () => boolean;
  setFolderDialogVisible: (visible: boolean) => void;
  isFolderSubmitInFlight: () => boolean;
  setFolderSubmitInFlight: (value: boolean) => void;

  isPreviewDownloadVisible: () => boolean;
  setPreviewDownloadVisible: (visible: boolean) => void;
  getPreviewDownloadEntry: () => TaildriveEntry;

  isDetailsVisible: () => boolean;
  setDetailsVisible: (visible: boolean) => void;
  isDetailsLoading: () => boolean;
  setDetailsLoading: (value: boolean) => void;
  getDetailsReason: () => string;
  setDetailsReason: (reason: string) => void;
  getDetailEntry: () => TaildriveEntry;
  setDetailEntry: (entry: TaildriveEntry) => void;

  isMoveVisible: () => boolean;
  setMoveVisible: (visible: boolean) => void;
  getMoveOperation: () => string;
  setMoveOperation: (operation: string) => void;
  getMoveTargetCount: () => number;
  setMoveTargetCount: (count: number) => void;
  isMoveLoading: () => boolean;
  setMoveLoading: (value: boolean) => void;
  isMoveSubmitInFlight: () => boolean;
  setMoveSubmitInFlight: (value: boolean) => void;
  getMoveReason: () => string;
  setMoveReason: (reason: string) => void;
  getMovePath: () => string;
  setMovePath: (path: string) => void;
  setMoveRoot: (root: string) => void;
  getMoveEntries: () => TaildriveEntry[];
  setMoveEntries: (entries: TaildriveEntry[]) => void;

  isSortSheetVisible: () => boolean;
  setSortSheetVisible: (visible: boolean) => void;
  closeSortPanel: () => void;

  setTransfer: (snapshot: TaildriveTransferSnapshot) => void;
  getCachedEntries: () => TaildriveEntry[];
  setCachedEntries: (entries: TaildriveEntry[]) => void;
  getDownloadedEntries: () => TaildriveEntry[];
  setDownloadedEntries: (entries: TaildriveEntry[]) => void;
  hasGatewayCachedPreview: (entry: TaildriveEntry) => boolean;
  clearPreviewThumbnails: () => void;
  filterProtectedThumbnails: (matchesProtected: (remotePath: string) => boolean) => void;
  purgeGatewayPreviewCaches: (normalizedTargets: string[]) => void;
  cancelThumbnailPool: () => void;

  applyListResult: (result: TaildriveListResult, fallbackPath: string) => void;
  rebuildListDataSource: () => void;
  updateBackState: () => void;
  publishUiBackState: () => void;
  startRefreshPolling: () => void;
  stopRefreshPolling: () => void;
  startTransferPolling: () => void;
  stopTransferPolling: () => void;
  stopDragAutoScroll: () => void;
  scheduleSecurityResume: (delayMs: number) => void;
  clearSecurityResumeTimer: () => void;
  delayIndicator: (ms: number) => Promise<void>;
  vibrateTouch: (strong?: boolean) => void;
  vibrateDragStep: () => void;
  localizedNewFolderName: () => string;
  showConfirmationPrompt: (prompt: TaildriveConfirmationPrompt) => void;
  pickUploadDocumentUris: () => Promise<string[]>;
  stagingRoot: () => string;
  ensureStagingDirectory: (root: string) => void;
  authenticateFolderAccess: () => Promise<boolean>;
  authenticateFolderPolicy: () => Promise<boolean>;
  saveLockedFolderPaths: (paths: string[]) => Promise<void>;
  recordSecurityDiagnostic: (event: string, phase: string, code?: number) => void;
  logTargetOpen: (route: string, durationMs: number) => void;
  publishTransferCompletion: (fileName: string, success: boolean) => Promise<void>;
  clearTransferProgress: () => Promise<void>;
  retryDownload: (entry: TaildriveEntry) => Promise<void>;
  retryPreviewDownload: (entry: TaildriveEntry) => Promise<void>;

  gatewayList: (path: string) => Promise<TaildriveListResult>;
  gatewayStat: (path: string) => Promise<TaildriveStatResult>;
  gatewayMutate: (request: TaildriveMutationRequest) => Promise<TaildriveMutationResult>;
  gatewayUpload: (request: TaildriveTransferRequest) => Promise<TaildriveTransferSnapshot>;
  gatewayStageUpload: (uri: string, root: string, requestId: number) => Promise<PreparedTaildriveFile>;
  gatewayCleanupStaged: (file: PreparedTaildriveFile) => void;
}

/**
 * Framework-free deep module owning Taildrive directory navigation, folder-lock
 * security policy, search/sort/grouping/selection, and dialog/sheet/write-dispatch
 * state machines behind the narrow `TaildriveSessionHost` seam.
 */
export class TaildriveSessionController {
  private readonly host: TaildriveSessionHost;

  editorDirectory: string = '';
  editorGeneration: number = 0;
  folderDialogPath: string = '';
  folderDialogGeneration: number = 0;
  detailsRequestId: number = 0;
  detailsDirectory: string = '';
  detailsGeneration: number = 0;
  moveRequestId: number = 0;
  moveListGeneration: number = 0;
  moveDirectory: string = '';
  moveGeneration: number = 0;
  movingEntry: TaildriveEntry | undefined = undefined;
  movingEntries: TaildriveEntry[] = [];
  refreshInFlight: boolean = false;
  refreshPending: boolean = false;
  refreshGeneration: number = 0;
  targetOpenInFlight: boolean = false;
  lastTargetRequestId: number = 0;
  retryKind: string = '';
  retryDownloadEntry: TaildriveEntry | undefined = undefined;
  retryPreviewEntry: TaildriveEntry | undefined = undefined;
  retryMutation: TaildriveMutationRequest | undefined = undefined;
  retryMutationWorkingStatus: string = 'mutation_failed';
  retryMutationCompletedStatus: string = 'mutation_completed';
  pendingUpload: PreparedTaildriveFile | undefined = undefined;
  pendingUploadPath: string = '';
  uploadSelectionInFlight: boolean = false;
  fileConfirmationId: number = 0;
  protectedFolderResumePending: boolean = false;
  protectedFolderResumeInFlight: boolean = false;
  lastBackRequest: number = 0;
  dragAnchorFlatIndex: number = -1;
  dragLastFlatIndex: number = -1;
  dragSelectTargetState: boolean = true;
  dragBaseSelectedPaths: string[] = [];
  dragSuppressClickUntilMs: number = 0;

  constructor(host: TaildriveSessionHost) {
    this.host = host;
  }

  // --- Path & Share Hierarchy Algebra ---

  folderPathSegments(remotePath: string): number {
    return taildrivePathDepth(remotePath);
  }

  normalizeFolderPath(remotePath: string): string {
    return normalizeTaildriveFolderPath(remotePath);
  }

  pathIsWithin(remotePath: string, folderPath: string): boolean {
    return taildrivePathIsWithin(remotePath, folderPath);
  }

  parentPath(remotePath: string): string {
    return taildriveParentPath(remotePath);
  }

  joinPath(parent: string, name: string): string {
    return taildriveJoinPath(parent, name);
  }

  pathName(remotePath: string): string {
    return taildrivePathName(remotePath);
  }

  shareRoot(remotePath: string): string {
    return taildriveShareRoot(remotePath);
  }

  validName(name: string): boolean {
    return isValidTaildriveName(name);
  }

  safeLocalName(name: string): string {
    return sanitizeTaildriveLocalName(name);
  }

  safeRemoteName(name: string): string {
    return sanitizeTaildriveRemoteName(name);
  }

  sanitizeDisplayLabel(value: string): string {
    return sanitizeTaildriveDisplayLabel(value);
  }

  displayPath(value?: string): string {
    return decodeTaildriveDisplayPath(value ?? this.host.getPath());
  }

  pathSegments(rawPath: string): string[] {
    return taildrivePathSegments(rawPath);
  }

  buildSegmentPath(rawPath: string, index: number): string {
    return buildTaildriveSegmentPath(rawPath, index);
  }

  canModifyCurrentPath(): boolean {
    return taildrivePathDepth(this.host.getPath()) >= 3;
  }

  snapshotFileEntry(entry: TaildriveEntry): TaildriveEntry {
    return snapshotTaildriveEntry(entry);
  }

  suggestNewFolderName(baseOverride?: string): string {
    const baseName: string = baseOverride ?? this.host.localizedNewFolderName();
    const existingNames: string[] = this.host.getEntries().map(
      (entry: TaildriveEntry) => entry.name.toLowerCase()
    );
    if (!existingNames.includes(baseName.toLowerCase())) {
      return baseName;
    }
    let suffix: number = 2;
    while (existingNames.includes(`${baseName} (${suffix})`.toLowerCase())) {
      suffix++;
    }
    return `${baseName} (${suffix})`;
  }

  suggestCopyTargetName(entry: TaildriveEntry, destination: string, reservedLower: string[]): string {
    if (this.parentPath(entry.path) !== destination) {
      reservedLower.push(entry.name.toLowerCase());
      return entry.name;
    }
    const dotIndex: number = entry.kind === 'file' ? entry.name.lastIndexOf('.') : -1;
    const stem: string = dotIndex > 0 ? entry.name.substring(0, dotIndex) : entry.name;
    const extension: string = dotIndex > 0 ? entry.name.substring(dotIndex) : '';
    let suffix: number = 2;
    let candidate: string = `${stem} (${suffix})${extension}`;
    while (reservedLower.includes(candidate.toLowerCase())) {
      suffix++;
      candidate = `${stem} (${suffix})${extension}`;
    }
    reservedLower.push(candidate.toLowerCase());
    return candidate;
  }

  // --- Folder Lock & Sheet Security Policy ---

  // /tailnet/device is the first lockable path. Tailnet names remain navigation-only.
  canLockFolder(entry: TaildriveEntry): boolean {
    return entry.kind === 'directory' && this.folderPathSegments(entry.path) >= 2;
  }

  isFolderDirectlyLocked(remotePath: string): boolean {
    const normalized: string = this.normalizeFolderPath(remotePath);
    return this.host.getLockedFolderPaths().some((path: string) =>
      this.normalizeFolderPath(path) === normalized);
  }

  canChangeFolderLock(entry: TaildriveEntry): boolean {
    if (!this.canLockFolder(entry)) {
      return false;
    }
    const protectedRoot: string = this.protectedFolderRoot(entry.path);
    return protectedRoot.length === 0 || this.isFolderDirectlyLocked(entry.path);
  }

  protectedFolderRoot(remotePath: string): string {
    if (!this.host.isFolderLockEnabled()) {
      return '';
    }
    const matching: string[] = this.host.getLockedFolderPaths()
      .map((path: string) => this.normalizeFolderPath(path))
      .filter((path: string) => this.pathIsWithin(remotePath, path));
    matching.sort((left: string, right: string) => right.length - left.length);
    return matching.length > 0 ? matching[0] : '';
  }

  protectedFolderRootsTouching(remotePath: string): string[] {
    if (!this.host.isFolderLockEnabled()) {
      return [];
    }
    const normalized: string = this.normalizeFolderPath(remotePath);
    return this.host.getLockedFolderPaths()
      .map((path: string) => this.normalizeFolderPath(path))
      .filter((path: string, index: number, paths: string[]) =>
        paths.indexOf(path) === index &&
        (this.pathIsWithin(normalized, path) || this.pathIsWithin(path, normalized)));
  }

  hasFolderAccess(remotePath: string): boolean {
    const protectedRoot: string = this.protectedFolderRoot(remotePath);
    return protectedRoot.length === 0 || this.host.getFolderAccessGrants().includes(protectedRoot);
  }

  hasMutationSourceAccess(remotePath: string): boolean {
    if (remotePath.trim().length === 0) {
      return true;
    }
    if (!this.hasFolderAccess(remotePath)) {
      return false;
    }
    const grants: string[] = this.host.getFolderAccessGrants();
    return this.protectedFolderRootsTouching(remotePath)
      .every((root: string) => grants.includes(root));
  }

  isSheetBlockedBySecurity(targetPath?: string): boolean {
    const currentPath: string = this.host.getPath();
    const resolvedTarget: string = targetPath ?? currentPath;
    return this.host.isAppLockActive() || !this.hasFolderAccess(currentPath) ||
      !this.hasFolderAccess(resolvedTarget);
  }

  editorTargetPath(): string {
    const editorPath: string = this.host.getEditorPath();
    if (editorPath.length > 0) {
      return editorPath;
    }
    return this.editorDirectory.length > 0 ? this.editorDirectory : this.host.getPath();
  }

  isEditorSheetBlockedBySecurity(): boolean {
    const targetPath: string = this.editorTargetPath();
    if (this.isSheetBlockedBySecurity(targetPath)) {
      return true;
    }
    const editorPath: string = this.host.getEditorPath();
    return this.host.getEditorOperation() === 'rename' && editorPath.length > 0 &&
      !this.hasMutationSourceAccess(editorPath);
  }

  isMoveSheetBlockedBySecurity(): boolean {
    if (this.isSheetBlockedBySecurity(this.host.getMovePath())) {
      return true;
    }
    if (this.movingEntry !== undefined && !this.hasMutationSourceAccess(this.movingEntry.path)) {
      return true;
    }
    return Array.isArray(this.movingEntries) &&
      this.movingEntries.some((entry: TaildriveEntry) => !this.hasMutationSourceAccess(entry.path));
  }

  closeSecurityBlockedOverlaySheets(): void {
    const currentPath: string = this.host.getPath();
    if (this.host.isAppLockActive() || !this.hasFolderAccess(currentPath)) {
      this.closeAllOverlaySheets();
      return;
    }
    let closedAny: boolean = false;
    if (this.host.isEditorVisible() && this.isEditorSheetBlockedBySecurity()) {
      this.host.setEditorVisible(false);
      closedAny = true;
    }
    const detailPath: string = this.host.getDetailEntry().path;
    if (this.host.isDetailsVisible() &&
      this.isSheetBlockedBySecurity(detailPath.length > 0 ? detailPath : currentPath)) {
      this.closeDetails();
      closedAny = true;
    }
    const previewPath: string = this.host.getPreviewDownloadEntry().path;
    if (this.host.isPreviewDownloadVisible() &&
      this.isSheetBlockedBySecurity(previewPath.length > 0 ? previewPath : currentPath)) {
      this.host.setPreviewDownloadVisible(false);
      closedAny = true;
    }
    if (this.host.isMoveVisible() && this.isMoveSheetBlockedBySecurity()) {
      this.closeMovePicker();
      closedAny = true;
    }
    if (this.host.isFolderDialogVisible() &&
      !this.hasFolderAccess(this.folderDialogPath.length > 0 ? this.folderDialogPath : currentPath)) {
      this.host.setFolderDialogVisible(false);
      closedAny = true;
    }
    if (closedAny) {
      this.host.publishUiBackState();
    }
  }

  closeAllOverlaySheets(): void {
    this.host.setEditorVisible(false);
    if (this.host.isDetailsVisible()) {
      this.closeDetails();
    }
    this.host.setPreviewDownloadVisible(false);
    if (this.host.isMoveVisible()) {
      this.closeMovePicker();
    }
    this.host.setSortSheetVisible(false);
    this.host.setFolderDialogVisible(false);
    this.host.publishUiBackState();
  }

  blockProtectedFolderContent(): void {
    this.protectedFolderResumePending = true;
    this.host.setEntries([]);
    this.host.clearPreviewThumbnails();
    this.host.setCachedEntries([]);
    this.host.cancelThumbnailPool();
    this.closeAllOverlaySheets();
    this.exitSelectionMode();
    this.host.rebuildListDataSource();
  }

  purgeProtectedPreviewCaches(folderPaths: string[]): void {
    if (!Array.isArray(folderPaths) || folderPaths.length === 0) {
      return;
    }
    const normalizedTargets: string[] = folderPaths
      .map((folder: string) => this.normalizeFolderPath(folder))
      .filter((folder: string) => folder !== '/');
    if (normalizedTargets.length === 0) {
      return;
    }
    const matchesProtected = (remotePath: string): boolean =>
      normalizedTargets.some((folder: string) => this.pathIsWithin(remotePath, folder));
    this.host.filterProtectedThumbnails(matchesProtected);
    const cached: TaildriveEntry[] = this.host.getCachedEntries();
    if (Array.isArray(cached)) {
      this.host.setCachedEntries(cached.filter((item: TaildriveEntry) => !matchesProtected(item.path)));
    }
    try {
      this.host.purgeGatewayPreviewCaches(normalizedTargets);
    } catch (_error) {
      // Cache eviction is best-effort and never blocks lock enforcement.
    }
  }

  async resumeProtectedFolderAccess(): Promise<void> {
    if (!this.host.isConnected() || !this.host.isFilesTabActive() || this.host.isAppLockActive() ||
      !this.protectedFolderResumePending || this.protectedFolderResumeInFlight) {
      return;
    }
    this.protectedFolderResumeInFlight = true;
    try {
      const currentPath: string = this.host.getPath();
      const protectedRoot: string = this.protectedFolderRoot(currentPath);
      if (protectedRoot.length === 0) {
        this.protectedFolderResumePending = false;
        await this.refresh();
        return;
      }
      const passed: boolean = await this.ensureFolderAccess(currentPath);
      if (passed) {
        this.protectedFolderResumePending = false;
        await this.refresh();
        return;
      }
      this.protectedFolderResumePending = false;
      this.host.setPath(this.parentPath(protectedRoot));
      this.host.updateBackState();
      await this.refresh();
    } finally {
      this.protectedFolderResumeInFlight = false;
    }
  }

  async ensureFolderAccess(remotePath: string): Promise<boolean> {
    const protectedRoot: string = this.protectedFolderRoot(remotePath);
    if (protectedRoot.length === 0 || this.host.getFolderAccessGrants().includes(protectedRoot)) {
      return true;
    }
    if (this.host.isFolderAccessAuthInFlight()) {
      return false;
    }
    this.host.setFolderAccessAuthInFlight(true);
    this.host.recordSecurityDiagnostic('folder_access_auth_started', 'protected_folder');
    try {
      const passed: boolean = await this.host.authenticateFolderAccess();
      if (passed) {
        this.host.setFolderAccessGrants([...this.host.getFolderAccessGrants(), protectedRoot]);
        this.host.recordSecurityDiagnostic('folder_access_auth_completed', 'passed');
      } else {
        this.host.showTransientStatus('folder_authentication_failed');
        this.host.recordSecurityDiagnostic('folder_access_auth_completed', 'failed');
      }
      return passed;
    } finally {
      this.host.setFolderAccessAuthInFlight(false);
    }
  }

  async ensureProtectedMutationAccess(remotePath: string): Promise<boolean> {
    const protectedRoots: string[] = this.protectedFolderRootsTouching(remotePath);
    for (let index: number = 0; index < protectedRoots.length; index++) {
      if (!await this.ensureFolderAccess(protectedRoots[index])) {
        return false;
      }
    }
    return true;
  }

  async ensureMutationRequestAccess(request: TaildriveMutationRequest): Promise<boolean> {
    if (!await this.ensureProtectedMutationAccess(request.path)) {
      return false;
    }
    if (request.newPath === undefined) {
      return true;
    }
    return await this.ensureFolderAccess(request.newPath);
  }

  normalizeLockedFolderList(paths: string[]): string[] {
    const normalized: string[] = [];
    paths.map((path: string) => this.normalizeFolderPath(path))
      .filter((path: string) => path !== '/')
      .sort((left: string, right: string) => left.length - right.length)
      .forEach((path: string) => {
        if (!normalized.some((parent: string) => this.pathIsWithin(path, parent))) {
          normalized.push(path);
        }
      });
    return normalized;
  }

  async reconcileLockedFoldersAfterMutation(request: TaildriveMutationRequest): Promise<boolean> {
    const sourcePath: string = this.normalizeFolderPath(request.path);
    const currentLocked: string[] = this.host.getLockedFolderPaths();
    let next: string[] = [...currentLocked];
    if (request.operation === 'delete') {
      next = next.filter((path: string) => !this.pathIsWithin(path, sourcePath));
    } else if ((request.operation === 'rename' || request.operation === 'move') &&
      request.newPath !== undefined) {
      const targetPath: string = this.normalizeFolderPath(request.newPath);
      next = next.map((path: string) => {
        const normalizedPath: string = this.normalizeFolderPath(path);
        if (!this.pathIsWithin(normalizedPath, sourcePath)) {
          return normalizedPath;
        }
        return `${targetPath}${normalizedPath.substring(sourcePath.length)}`;
      });
    } else {
      return true;
    }
    next = this.normalizeLockedFolderList(next);
    const current: string[] = this.normalizeLockedFolderList(currentLocked);
    if (JSON.stringify(next) === JSON.stringify(current)) {
      return true;
    }
    try {
      await this.host.saveLockedFolderPaths(next);
      this.host.setLockedFolderPaths(next);
      if (this.host.isFolderLockEnabled() && next.length > 0) {
        this.purgeProtectedPreviewCaches(next);
      }
      this.host.recordSecurityDiagnostic('folder_policy_reconciled', request.operation, next.length);
      return true;
    } catch (_error) {
      // Keep the current session aligned with the already-completed remote mutation.
      this.host.setLockedFolderPaths(next);
      if (this.host.isFolderLockEnabled() && next.length > 0) {
        this.purgeProtectedPreviewCaches(next);
      }
      this.host.recordSecurityDiagnostic('folder_policy_reconcile_failed', request.operation, next.length);
      return false;
    }
  }

  toggleFolderLock(entry: TaildriveEntry): void {
    if (!this.canChangeFolderLock(entry) || this.host.isFolderPolicyAuthInFlight()) {
      return;
    }
    this.updateFolderLock(entry);
  }

  async updateFolderLock(entry: TaildriveEntry): Promise<void> {
    this.host.setFolderPolicyAuthInFlight(true);
    const normalized: string = this.normalizeFolderPath(entry.path);
    const operation: string = this.isFolderDirectlyLocked(normalized) ? 'unlock' : 'lock';
    this.host.recordSecurityDiagnostic('folder_policy_auth_started', operation);
    try {
      const passed: boolean = await this.host.authenticateFolderPolicy();
      if (!passed) {
        this.host.showTransientStatus('folder_authentication_failed');
        this.host.recordSecurityDiagnostic('folder_policy_auth_completed', 'failed');
        return;
      }
      const existing: string[] = this.host.getLockedFolderPaths();
      const next: string[] = this.isFolderDirectlyLocked(normalized) ?
        existing.filter((path: string) => this.normalizeFolderPath(path) !== normalized) :
        [...existing, normalized];
      await this.host.saveLockedFolderPaths(next);
      this.host.setLockedFolderPaths(next);
      this.host.setFolderAccessGrants([]);
      if (operation === 'lock') {
        this.purgeProtectedPreviewCaches([normalized]);
      }
      this.closeSecurityBlockedOverlaySheets();
      if (this.host.isFolderLockEnabled() && this.protectedFolderRoot(this.host.getPath()).length > 0) {
        this.blockProtectedFolderContent();
      }
      this.host.recordSecurityDiagnostic('folder_policy_changed', operation, next.length);
    } catch (_error) {
      this.host.recordSecurityDiagnostic('folder_policy_change_failed', operation);
      this.host.showTransientStatus('security_settings_save_failed');
    } finally {
      this.host.setFolderPolicyAuthInFlight(false);
    }
  }

  // --- Lifecycle & Watch Transitions ---

  private incrementActionGeneration(): void {
    this.host.setFileActionGeneration(this.host.getFileActionGeneration() + 1);
  }

  onConnectedChanged(): void {
    this.incrementActionGeneration();
    this.host.cancelThumbnailPool();
    this.refreshGeneration++;
    if (this.host.isConnected()) {
      if (this.host.getTargetRequestId() > this.lastTargetRequestId &&
        this.host.getTargetMachineName().length > 0) {
        this.requestTargetMachineOpen();
      } else if (this.host.isFilesTabActive()) {
        this.refresh();
      }
      if (this.host.isFilesTabActive()) {
        this.host.startRefreshPolling();
      }
    } else {
      this.host.stopRefreshPolling();
      this.host.setFolderAccessGrants([]);
      this.protectedFolderResumePending = false;
      this.host.setEntries([]);
      this.host.setLastListedPath('');
      this.host.setLoading(false);
      this.host.setSearchVisibleRaw(false);
      this.closeAllOverlaySheets();
      this.exitSelectionMode();
      this.host.setReason('backend_unavailable');
      this.host.setStatus('');
    }
  }

  onTargetRequestChanged(): void {
    this.refreshGeneration++;
    if (this.host.isConnected() && this.host.getTargetRequestId() > 0 &&
      this.host.getTargetMachineName().length > 0) {
      this.requestTargetMachineOpen();
    }
  }

  onFilesTabActiveChanged(): void {
    this.refreshGeneration++;
    if (!this.host.isFilesTabActive()) {
      this.incrementActionGeneration();
      this.host.cancelThumbnailPool();
      this.host.stopRefreshPolling();
      this.host.setFolderAccessGrants([]);
      this.closeSecurityBlockedOverlaySheets();
      if (this.protectedFolderRoot(this.host.getPath()).length > 0) {
        this.blockProtectedFolderContent();
      }
      return;
    }
    if (!this.host.isConnected()) {
      return;
    }
    this.host.startRefreshPolling();
    if (this.protectedFolderResumePending || !this.hasFolderAccess(this.host.getPath())) {
      this.resumeProtectedFolderAccess();
      return;
    }
    if (this.targetOpenInFlight) {
      return;
    }
    if (this.host.getTargetRequestId() > this.lastTargetRequestId &&
      this.host.getTargetMachineName().length > 0) {
      this.requestTargetMachineOpen();
    } else {
      this.refresh();
    }
  }

  onFolderLockEnabledChanged(): void {
    this.incrementActionGeneration();
    this.refreshGeneration++;
    this.host.setFolderAccessGrants([]);
    if (!this.host.isFolderLockEnabled()) {
      this.protectedFolderResumePending = false;
      if (this.host.isFilesTabActive() && this.host.isConnected()) {
        this.refresh();
      }
      return;
    }
    this.closeSecurityBlockedOverlaySheets();
    const lockedPaths: string[] = this.host.getLockedFolderPaths();
    if (lockedPaths.length > 0) {
      this.purgeProtectedPreviewCaches(lockedPaths);
    }
    if (this.protectedFolderRoot(this.host.getPath()).length > 0) {
      this.blockProtectedFolderContent();
      if (this.host.isFilesTabActive()) {
        this.resumeProtectedFolderAccess();
      }
    }
  }

  onLockedFolderPathsChanged(): void {
    this.incrementActionGeneration();
    this.refreshGeneration++;
    this.host.setFolderAccessGrants([]);
    if (this.host.isFolderLockEnabled()) {
      this.closeSecurityBlockedOverlaySheets();
      const lockedPaths: string[] = this.host.getLockedFolderPaths();
      if (lockedPaths.length > 0) {
        this.purgeProtectedPreviewCaches(lockedPaths);
      }
      if (this.protectedFolderRoot(this.host.getPath()).length > 0) {
        this.blockProtectedFolderContent();
      }
    }
  }

  onAppLockActiveChanged(): void {
    this.refreshGeneration++;
    if (this.host.isAppLockActive()) {
      this.incrementActionGeneration();
      this.host.cancelThumbnailPool();
      this.host.stopRefreshPolling();
      this.host.setPullRefreshing(false);
      this.closeAllOverlaySheets();
    } else if (this.host.isAppInForeground() && this.host.isBrowserVisible() &&
      this.host.isConnected() && this.host.isFilesTabActive()) {
      this.host.startRefreshPolling();
      if (this.host.getTargetRequestId() > this.lastTargetRequestId &&
        this.host.getTargetMachineName().length > 0) {
        this.requestTargetMachineOpen();
      } else {
        this.refresh();
      }
    }
    if (this.host.isAppInForeground() && !this.host.isAppLockActive() &&
      this.protectedFolderResumePending && this.host.isFilesTabActive()) {
      this.resumeProtectedFolderAccess();
    }
  }

  handleAppBackground(): void {
    this.host.setAppInForeground(false);
    this.refreshGeneration++;
    this.refreshPending = false;
    this.host.setPullRefreshing(false);
    this.host.cancelThumbnailPool();
    this.host.stopRefreshPolling();
    this.host.clearSecurityResumeTimer();
    if (this.host.isFolderLockEnabled()) {
      this.host.setFolderAccessGrants([]);
      this.closeSecurityBlockedOverlaySheets();
    }
  }

  handleAppForeground(): void {
    this.host.setAppInForeground(true);
    this.host.setFolderAccessGrants([]);
    this.closeSecurityBlockedOverlaySheets();
    if (!this.host.isBrowserVisible() || !this.host.isConnected() ||
      (this.host.isStandalone() && !this.host.isFilesTabActive())) {
      return;
    }
    this.host.startRefreshPolling();
    if (!this.host.isFolderLockEnabled() || this.protectedFolderRoot(this.host.getPath()).length === 0) {
      // Coalesce with a request still completing from the previous foreground.
      if (this.host.getTargetRequestId() > this.lastTargetRequestId &&
        this.host.getTargetMachineName().length > 0) {
        this.requestTargetMachineOpen();
      } else {
        this.refresh();
      }
      return;
    }
    this.blockProtectedFolderContent();
    this.host.scheduleSecurityResume(250);
  }

  onSecurityResumeTimerFired(): void {
    if (this.host.isAppInForeground() && this.host.isBrowserVisible() &&
      this.host.isFilesTabActive() && !this.host.isAppLockActive()) {
      this.resumeProtectedFolderAccess();
    }
  }

  onBackRequestChanged(backRequest: number): void {
    if (backRequest <= this.lastBackRequest) {
      return;
    }
    this.lastBackRequest = backRequest;
    if (this.host.isFolderDialogVisible()) {
      this.closeFolderDialog();
    } else if (this.host.isPreviewDownloadVisible()) {
      this.host.setPreviewDownloadVisible(false);
    } else if (this.host.isSortSheetVisible()) {
      this.host.closeSortPanel();
    } else if (this.host.isSelectionMode()) {
      this.exitSelectionMode();
    } else if (this.host.isSearchVisible()) {
      this.host.dismissSearchAnimated();
    } else if (this.host.getPath() !== '/') {
      this.goUp();
    }
  }

  onPathChanged(): void {
    this.incrementActionGeneration();
    this.refreshGeneration++;
    if (this.targetOpenInFlight) {
      // Manual navigation supersedes any pending target route.
      this.lastTargetRequestId = this.host.getTargetRequestId();
    }
    this.host.cancelThumbnailPool();
    this.host.clearPreviewThumbnails();
    this.host.setCachedEntries([]);
    if (this.host.getLastListedPath() !== this.host.getPath()) {
      this.host.setEntries([]);
      this.host.setLastListedPath('');
      this.host.setSelectedPaths([]);
      this.host.rebuildListDataSource();
    }
  }

  // --- Target Machine Navigation & Directory Refresh ---

  canApplyTarget(requestId: number, generation: number): boolean {
    return requestId > 0 && requestId === this.host.getTargetRequestId() &&
      generation === this.refreshGeneration &&
      this.host.isAppInForeground() && this.host.isBrowserVisible() &&
      this.host.isConnected() && !this.host.isAppLockActive() &&
      (!this.host.isStandalone() || this.host.isFilesTabActive());
  }

  requestTargetMachineOpen(): void {
    const requestId: number = this.host.getTargetRequestId();
    if (!this.canApplyTarget(requestId, this.refreshGeneration) || this.host.isBusy() ||
      requestId <= this.lastTargetRequestId || this.host.getTargetMachineName().length === 0) {
      return;
    }
    if (this.host.isLoading() || this.refreshInFlight || this.targetOpenInFlight) {
      return;
    }
    this.openTargetMachine(requestId);
  }

  async openTargetMachine(requestId: number): Promise<void> {
    const generation: number = this.refreshGeneration;
    if (!this.canApplyTarget(requestId, generation) || this.host.isBusy() ||
      this.targetOpenInFlight || this.refreshInFlight) {
      return;
    }
    const isCurrent: () => boolean = () => this.canApplyTarget(requestId, generation);
    const machineName: string = this.host.getTargetMachineName();
    const tailnetName: string = this.host.getTargetTailnetName();
    const startedAtMs: number = Date.now();
    // A suspended request stays outstanding until a current result or explicit authentication refusal.
    this.lastTargetRequestId = Math.min(this.lastTargetRequestId, requestId - 1);
    this.targetOpenInFlight = true;
    this.host.setLoading(true);
    this.host.setReason('');
    this.host.setStatus('');
    try {
      const directPath: string = this.directTargetMachinePath();
      if (directPath.length > 0) {
        if (!await this.ensureFolderAccess(directPath)) {
          if (requestId === this.host.getTargetRequestId()) {
            this.lastTargetRequestId = requestId;
          }
          return;
        }
        if (!isCurrent() || !this.hasFolderAccess(directPath)) {
          return;
        }
        const direct: TaildriveListResult = await this.host.gatewayList(directPath);
        if (!isCurrent() || !this.hasFolderAccess(directPath)) {
          return;
        }
        if (direct.state === 'ready') {
          this.lastTargetRequestId = requestId;
          this.host.applyListResult(direct, directPath);
          this.clearRetry();
          this.host.logTargetOpen('direct', Date.now() - startedAtMs);
          return;
        }
      }
      const root: TaildriveListResult = await this.host.gatewayList('/');
      if (!isCurrent()) {
        return;
      }
      if (root.state !== 'ready') {
        this.lastTargetRequestId = requestId;
        this.host.setReason(root.reason.length > 0 ? root.reason : 'list_failed');
        this.setRetry('target');
        return;
      }
      let targetPath: string = '';
      const tailnets: TaildriveEntry[] = root.entries.filter((entry: TaildriveEntry) =>
        entry.kind === 'directory');
      tailnets.sort((left: TaildriveEntry, right: TaildriveEntry) =>
        this.tailnetMatchPriority(right.name, tailnetName) -
        this.tailnetMatchPriority(left.name, tailnetName));
      for (let index: number = 0; index < tailnets.length && targetPath.length === 0; index++) {
        const tailnet: TaildriveEntry = tailnets[index];
        const machines: TaildriveListResult = await this.host.gatewayList(tailnet.path);
        if (!isCurrent()) {
          return;
        }
        if (machines.state !== 'ready') {
          continue;
        }
        const target: TaildriveEntry | undefined = machines.entries.find((entry: TaildriveEntry) =>
          entry.kind === 'directory' && this.machineNamesMatch(entry.name, machineName));
        if (target !== undefined) {
          targetPath = target.path;
        }
      }
      if (targetPath.length === 0) {
        this.lastTargetRequestId = requestId;
        this.host.applyListResult(root, '/');
        this.host.setStatus('target_not_found');
        this.clearRetry();
        return;
      }
      if (!await this.ensureFolderAccess(targetPath)) {
        if (requestId === this.host.getTargetRequestId()) {
          this.lastTargetRequestId = requestId;
        }
        return;
      }
      if (!isCurrent() || !this.hasFolderAccess(targetPath)) {
        return;
      }
      const target: TaildriveListResult = await this.host.gatewayList(targetPath);
      if (!isCurrent() || !this.hasFolderAccess(targetPath)) {
        return;
      }
      this.lastTargetRequestId = requestId;
      if (target.state !== 'ready') {
        this.host.setPath(targetPath);
        this.host.updateBackState();
        this.host.setReason(target.reason.length > 0 ? target.reason : 'list_failed');
        this.setRetry('target');
        return;
      }
      this.host.applyListResult(target, targetPath);
      this.clearRetry();
      this.host.logTargetOpen('fallback', Date.now() - startedAtMs);
    } catch (_error) {
      if (isCurrent()) {
        this.lastTargetRequestId = requestId;
        this.host.setReason('backend_unavailable');
        this.setRetry('target');
      }
    } finally {
      this.host.setLoading(false);
      this.targetOpenInFlight = false;
      if (this.host.getTargetRequestId() > this.lastTargetRequestId) {
        this.requestTargetMachineOpen();
      } else if (this.refreshPending) {
        this.refreshPending = false;
        this.refresh();
      }
    }
  }

  directTargetMachinePath(): string {
    const tailnetName: string = this.host.getTargetTailnetName().trim();
    const normalizedMachine: string = this.normalizedMachineName(this.host.getTargetMachineName());
    const machineName: string = normalizedMachine.split('.')[0];
    if (!this.validName(tailnetName) || !this.validName(machineName)) {
      return '';
    }
    return this.joinPath(this.joinPath('/', tailnetName), machineName);
  }

  tailnetMatchPriority(name: string, tailnetName?: string): number {
    const targetTailnet: string = tailnetName ?? this.host.getTargetTailnetName();
    return name.trim().toLowerCase() === targetTailnet.trim().toLowerCase() ? 1 : 0;
  }

  machineNamesMatch(left: string, right: string): boolean {
    const leftName: string = this.normalizedMachineName(left);
    const rightName: string = this.normalizedMachineName(right);
    return leftName === rightName || leftName.split('.')[0] === rightName.split('.')[0];
  }

  normalizedMachineName(value: string): string {
    let name: string = value.trim().toLowerCase();
    while (name.endsWith('.')) {
      name = name.substring(0, name.length - 1);
    }
    return name;
  }

  canApplyRefresh(requestPath: string, generation: number): boolean {
    return this.host.isAppInForeground() && this.host.isBrowserVisible() &&
      this.host.isConnected() && !this.host.isAppLockActive() &&
      (!this.host.isStandalone() || this.host.isFilesTabActive()) &&
      generation === this.refreshGeneration &&
      requestPath === this.host.getPath() && this.hasFolderAccess(requestPath);
  }

  async refresh(minimumIndicatorMs: number = 0, silent: boolean = false): Promise<void> {
    if (!this.host.isAppInForeground() || !this.host.isConnected() ||
      !this.host.isBrowserVisible() || this.host.isAppLockActive() ||
      (this.host.isStandalone() && !this.host.isFilesTabActive())) {
      return;
    }
    if (this.refreshInFlight || this.targetOpenInFlight) {
      if (!silent) {
        this.refreshPending = true;
      }
      return;
    }
    const requestPath: string = this.host.getPath();
    if (!this.hasFolderAccess(requestPath)) {
      this.blockProtectedFolderContent();
      return;
    }
    const startedAtMs: number = Date.now();
    const generation: number = this.refreshGeneration;
    this.refreshInFlight = true;
    if (!silent) {
      this.host.setLoading(true);
    }
    this.host.setReason('');
    try {
      const result: TaildriveListResult = await this.host.gatewayList(requestPath);
      if (!this.canApplyRefresh(requestPath, generation)) {
        return;
      }
      if (result.state === 'ready') {
        this.host.applyListResult(result, requestPath);
        if (this.retryKind === 'refresh') {
          this.clearRetry();
        }
      } else {
        this.host.setReason(result.reason.length > 0 ? result.reason : 'list_failed');
        this.setRetry('refresh');
      }
    } catch (_error) {
      if (this.canApplyRefresh(requestPath, generation)) {
        this.host.setReason('backend_unavailable');
        this.setRetry('refresh');
      }
    } finally {
      const remainingIndicatorMs: number = minimumIndicatorMs - (Date.now() - startedAtMs);
      if (remainingIndicatorMs > 0) {
        await this.host.delayIndicator(remainingIndicatorMs);
      }
      if (!silent) {
        this.host.setLoading(false);
      }
      this.refreshInFlight = false;
      const needsAnotherRefresh: boolean = this.refreshPending || this.host.getPath() !== requestPath;
      this.refreshPending = false;
      if (this.host.isAppInForeground() && this.host.isBrowserVisible() &&
        this.host.isConnected() && !this.host.isAppLockActive() &&
        (!this.host.isStandalone() || this.host.isFilesTabActive())) {
        if (this.host.getTargetRequestId() > this.lastTargetRequestId &&
          this.host.getTargetMachineName().length > 0) {
          this.requestTargetMachineOpen();
        } else if (needsAnotherRefresh) {
          this.refresh();
        }
      }
    }
  }

  async pullRefresh(): Promise<void> {
    try {
      if (!this.host.isConnected() || !this.host.isBrowserVisible() || this.host.isBusy() ||
        this.host.isAppLockActive() || this.refreshInFlight || this.targetOpenInFlight ||
        !this.hasFolderAccess(this.host.getPath())) {
        return;
      }
      this.host.setPullRefreshing(true);
      this.host.vibrateTouch(false);
      await this.refresh(450);
    } catch (_error) {
      this.host.setReason('backend_unavailable');
      this.setRetry('refresh');
    } finally {
      this.host.setPullRefreshing(false);
    }
  }

  goUp(): void {
    const currentPath: string = this.host.getPath();
    if (currentPath === '/' || this.host.isBusy()) {
      return;
    }
    this.host.setPath(this.parentPath(currentPath));
    this.host.updateBackState();
    this.host.setSearchQuery('');
    this.host.setSearchVisibleRaw(false);
    this.exitSelectionMode();
    this.host.publishUiBackState();
    this.refresh();
  }

  navigateToBreadcrumb(index: number): void {
    if (this.host.isBusy()) {
      return;
    }
    this.host.vibrateTouch(false);
    const currentPath: string = this.host.getPath();
    this.host.setPath(index < 0 ? '/' : this.buildSegmentPath(currentPath, index));
    this.host.setSearchQuery('');
    this.host.setSearchVisibleRaw(false);
    this.exitSelectionMode();
    this.host.updateBackState();
    this.refresh();
  }

  // --- Search, Sort, Grouping, Local File Status & Multi-Selection ---

  matchesSearchQuery(entry: TaildriveEntry, query: string): boolean {
    return query.length === 0 || entry.name.toLowerCase().includes(query);
  }

  displayEntries(): TaildriveEntry[] {
    const query: string = this.host.getSearchQuery().trim().toLowerCase();
    const sortMode: string = this.host.getSortMode();
    const sortDescending: boolean = this.host.isSortDescending();
    const filtered: TaildriveEntry[] = this.host.getEntries().filter((entry: TaildriveEntry) =>
      this.matchesSearchQuery(entry, query));
    return filtered.sort((left: TaildriveEntry, right: TaildriveEntry): number => {
      if (left.kind !== right.kind) {
        return left.kind === 'directory' ? -1 : 1;
      }
      let result: number = 0;
      if (sortMode === 'modified' && left.modifiedAtMs !== right.modifiedAtMs) {
        result = left.modifiedAtMs - right.modifiedAtMs;
      } else if (sortMode === 'size' && left.size !== right.size) {
        result = left.size - right.size;
      } else {
        result = left.name.toLowerCase().localeCompare(right.name.toLowerCase());
      }
      return sortDescending ? -result : result;
    });
  }

  typeGroupKey(entry: TaildriveEntry): string {
    if (entry.kind === 'directory') {
      return 'folder';
    }
    if (isImageEntry(entry.name)) {
      return 'image';
    }
    if (isVideoEntry(entry.name)) {
      return 'video';
    }
    const extension: string = extractFileExtension(entry.name);
    if (['txt', 'md', 'json', 'jsonl', 'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'csv'].includes(extension)) {
      return 'document';
    }
    if (['zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'hap', 'hsp', 'har', 'app', 'apk'].includes(extension)) {
      return 'archive';
    }
    return 'other';
  }

  dateGroupKey(entry: TaildriveEntry): string {
    if (entry.modifiedAtMs <= 0) {
      return 'unknown';
    }
    const now: Date = new Date();
    const startToday: number = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    if (entry.modifiedAtMs >= startToday) {
      return 'today';
    }
    if (entry.modifiedAtMs >= startToday - 24 * 60 * 60 * 1000) {
      return 'yesterday';
    }
    if (entry.modifiedAtMs >= startToday - 7 * 24 * 60 * 60 * 1000) {
      return 'week';
    }
    return 'earlier';
  }

  groupedEntryBuckets(): TaildriveGroupedBucket[] {
    const entries: TaildriveEntry[] = this.displayEntries();
    const groupMode: string = this.host.getGroupMode();
    if (groupMode === 'none') {
      const single: TaildriveGroupedBucket = { key: 'all', entries: entries };
      return [single];
    }
    const keys: string[] = groupMode === 'type' ?
      ['folder', 'image', 'video', 'document', 'archive', 'other'] :
      ['today', 'yesterday', 'week', 'earlier', 'unknown'];
    const groups: TaildriveGroupedBucket[] = [];
    keys.forEach((key: string) => {
      const grouped: TaildriveEntry[] = entries.filter((entry: TaildriveEntry) =>
        (groupMode === 'type' ? this.typeGroupKey(entry) : this.dateGroupKey(entry)) === key);
      if (grouped.length > 0) {
        const bucket: TaildriveGroupedBucket = { key: key, entries: grouped };
        groups.push(bucket);
      }
    });
    return groups;
  }

  flattenedGroupedEntries(): TaildriveEntry[] {
    const entries: TaildriveEntry[] = [];
    this.groupedEntryBuckets().forEach((group: TaildriveGroupedBucket) => {
      group.entries.forEach((entry: TaildriveEntry) => entries.push(entry));
    });
    return entries;
  }

  hiddenSelectedCount(): number {
    const query: string = this.host.getSearchQuery().trim().toLowerCase();
    return this.selectedEntries().filter(
      (entry: TaildriveEntry) => !this.matchesSearchQuery(entry, query)
    ).length;
  }

  isSelected(entry: TaildriveEntry): boolean {
    return this.host.getSelectedPaths().includes(entry.path);
  }

  selectedEntries(): TaildriveEntry[] {
    const selectedPaths: string[] = this.host.getSelectedPaths();
    return this.host.getEntries().filter((entry: TaildriveEntry) => selectedPaths.includes(entry.path));
  }

  selectedEntry(): TaildriveEntry | undefined {
    const selected: TaildriveEntry[] = this.selectedEntries();
    return selected.length === 1 ? selected[0] : undefined;
  }

  selectedTotalBytes(): number {
    let total: number = 0;
    this.selectedEntries().forEach((entry: TaildriveEntry) => {
      total += Math.max(0, entry.size);
    });
    return total;
  }

  allVisibleEntriesSelected(): boolean {
    const visible: TaildriveEntry[] = this.displayEntries();
    return visible.length > 0 && visible.every((entry: TaildriveEntry) => this.isSelected(entry));
  }

  toggleSelectionMode(): void {
    this.host.vibrateTouch(false);
    if (this.host.isSelectionMode()) {
      this.exitSelectionMode();
      return;
    }
    this.host.setSelectionMode(true);
    this.host.setSelectedPaths([]);
    this.host.rebuildListDataSource();
    this.host.publishUiBackState();
  }

  exitSelectionMode(): void {
    this.finishDragSelection();
    this.host.setSelectionMode(false);
    this.host.setSelectedPaths([]);
    this.host.rebuildListDataSource();
    this.host.publishUiBackState();
  }

  toggleEntrySelection(entry: TaildriveEntry): void {
    if (this.host.isDragSelecting()) {
      return;
    }
    this.host.vibrateTouch(false);
    const current: string[] = this.host.getSelectedPaths();
    if (current.includes(entry.path)) {
      this.host.setSelectedPaths(current.filter((path: string) => path !== entry.path));
    } else {
      this.host.setSelectedPaths([...current, entry.path]);
    }
    this.host.rebuildListDataSource();
  }

  toggleSelectAll(): void {
    this.host.vibrateTouch(false);
    const visible: TaildriveEntry[] = this.displayEntries();
    if (visible.length === 0) {
      return;
    }
    const current: string[] = this.host.getSelectedPaths();
    if (this.allVisibleEntriesSelected()) {
      const visiblePaths: string[] = visible.map((entry: TaildriveEntry) => entry.path);
      this.host.setSelectedPaths(current.filter((path: string) => !visiblePaths.includes(path)));
    } else {
      const selected: string[] = [...current];
      visible.forEach((entry: TaildriveEntry) => {
        if (!selected.includes(entry.path)) {
          selected.push(entry.path);
        }
      });
      this.host.setSelectedPaths(selected);
    }
    this.host.rebuildListDataSource();
  }

  selectFromContextMenu(entry: TaildriveEntry): void {
    this.host.vibrateTouch(false);
    if (!this.host.isSelectionMode()) {
      this.host.setSelectionMode(true);
      this.host.setSelectedPaths([]);
      this.host.publishUiBackState();
    }
    const current: string[] = this.host.getSelectedPaths();
    if (!current.includes(entry.path)) {
      this.host.setSelectedPaths([...current, entry.path]);
    }
    this.host.rebuildListDataSource();
  }

  computeDragSelectedPaths(
    flatEntries: TaildriveEntry[],
    baseSelectedPaths: string[],
    anchorIndex: number,
    currentIndex: number,
    selectTarget: boolean
  ): string[] {
    return computeTaildriveDragSelectedPaths(
      flatEntries, baseSelectedPaths, anchorIndex, currentIndex, selectTarget
    );
  }

  resolveFlatEntryIndexForListIndex(
    listIndex: number,
    totalCount: number,
    isHeaderAt: (index: number) => boolean
  ): number {
    if (listIndex < 0 || listIndex >= totalCount || isHeaderAt(listIndex)) {
      return -1;
    }
    let flatIndex: number = 0;
    for (let cursor: number = 0; cursor < listIndex; cursor++) {
      if (!isHeaderAt(cursor)) {
        flatIndex++;
      }
    }
    return flatIndex;
  }

  beginDragSelectionAtIndex(flatIndex: number): boolean {
    if (!this.host.isSelectionMode() || !this.host.isConnected() ||
      this.host.isBusy() || this.host.isLoading()) {
      return false;
    }
    const flatEntries: TaildriveEntry[] = this.flattenedGroupedEntries();
    if (flatIndex < 0 || flatIndex >= flatEntries.length) {
      return false;
    }
    this.host.stopDragAutoScroll();
    this.host.setDragSelecting(true);
    this.dragAnchorFlatIndex = flatIndex;
    this.dragLastFlatIndex = flatIndex;
    this.dragBaseSelectedPaths = [...this.host.getSelectedPaths()];
    this.dragSelectTargetState = !this.dragBaseSelectedPaths.includes(flatEntries[flatIndex].path);
    this.host.setSelectedPaths(this.computeDragSelectedPaths(
      flatEntries, this.dragBaseSelectedPaths, this.dragAnchorFlatIndex, flatIndex, this.dragSelectTargetState
    ));
    this.host.vibrateTouch(true);
    return true;
  }

  updateDragSelectionToIndex(flatIndex: number): boolean {
    if (!this.host.isDragSelecting() || !this.host.isSelectionMode()) {
      return false;
    }
    const flatEntries: TaildriveEntry[] = this.flattenedGroupedEntries();
    if (flatIndex < 0 || flatIndex >= flatEntries.length || flatIndex === this.dragLastFlatIndex) {
      return false;
    }
    this.dragLastFlatIndex = flatIndex;
    this.host.setSelectedPaths(this.computeDragSelectedPaths(
      flatEntries, this.dragBaseSelectedPaths, this.dragAnchorFlatIndex, flatIndex, this.dragSelectTargetState
    ));
    this.host.vibrateDragStep();
    return true;
  }

  finishDragSelection(): void {
    this.host.stopDragAutoScroll();
    if (!this.host.isDragSelecting()) {
      return;
    }
    this.host.setDragSelecting(false);
    this.dragAnchorFlatIndex = -1;
    this.dragLastFlatIndex = -1;
    this.dragBaseSelectedPaths = [];
    this.dragSuppressClickUntilMs = Date.now() + 320;
    this.host.rebuildListDataSource();
  }

  localFileSnapshot(entry: TaildriveEntry): TaildriveEntry {
    return localTaildriveFileSnapshot(entry);
  }

  matchesLocalFile(candidate: TaildriveEntry, entry: TaildriveEntry): boolean {
    return matchesLocalTaildriveFile(candidate, entry);
  }

  localFileStatus(entry: TaildriveEntry): string {
    if (entry.kind !== 'file') {
      return '';
    }
    if (this.host.getCachedEntries().some(
      (candidate: TaildriveEntry) => matchesLocalTaildriveFile(candidate, entry)
    )) {
      return 'cached';
    }
    return this.host.getDownloadedEntries().some(
      (candidate: TaildriveEntry) => matchesLocalTaildriveFile(candidate, entry)
    ) ? 'downloaded' : '';
  }

  markCachedEntry(entry: TaildriveEntry): void {
    if (!this.host.hasGatewayCachedPreview(entry)) {
      return;
    }
    const existing: TaildriveEntry[] = this.host.getCachedEntries();
    this.host.setCachedEntries([
      ...existing.filter((candidate: TaildriveEntry) => candidate.path !== entry.path),
      localTaildriveFileSnapshot(entry)
    ]);
  }

  markDownloadedEntry(entry: TaildriveEntry): void {
    const existing: TaildriveEntry[] = this.host.getDownloadedEntries();
    this.host.setDownloadedEntries([
      ...existing.filter((candidate: TaildriveEntry) => candidate.path !== entry.path),
      localTaildriveFileSnapshot(entry)
    ]);
  }

  // --- Folder Dialog, Rename Editor, Details, Move/Copy Picker & Confirmations ---

  createFolder(): void {
    if (!this.host.isConnected() || this.host.isBusy() ||
      this.host.isFolderSubmitInFlight() || !this.canModifyCurrentPath()) {
      return;
    }
    this.host.setEditorOperation('mkdir');
    this.host.setEditorPath('');
    this.host.setEditorName(this.suggestNewFolderName());
    this.folderDialogPath = this.host.getPath();
    this.folderDialogGeneration = this.host.getFileActionGeneration();
    this.host.setFolderDialogVisible(true);
    this.host.publishUiBackState();
  }

  closeFolderDialog(): void {
    this.host.setFolderDialogVisible(false);
    this.host.setEditorName('');
    this.host.publishUiBackState();
  }

  folderDialogContextCurrent(directory?: string, generation?: number): boolean {
    const dir: string = directory ?? this.folderDialogPath;
    const gen: number = generation ?? this.folderDialogGeneration;
    return this.host.isFolderDialogVisible() && dir === this.host.getPath() &&
      gen === this.host.getFileActionGeneration() &&
      this.host.isConnected() && this.host.isBrowserVisible() && !this.host.isAppLockActive() &&
      (!this.host.isStandalone() || this.host.isFilesTabActive());
  }

  async submitFolderDialog(): Promise<void> {
    if (!this.host.isFolderDialogVisible() || this.host.isFolderSubmitInFlight() || this.host.isBusy()) {
      return;
    }
    const directory: string = this.folderDialogPath;
    const generation: number = this.folderDialogGeneration;
    if (!this.folderDialogContextCurrent(directory, generation)) {
      return;
    }
    const name: string = this.host.getEditorName().trim();
    if (!this.validName(name)) {
      this.host.setStatus('invalid_name');
      return;
    }
    this.host.setFolderSubmitInFlight(true);
    try {
      if (!await this.ensureFolderAccess(directory) ||
        !this.folderDialogContextCurrent(directory, generation) || this.host.isBusy()) {
        return;
      }
      this.host.setFolderDialogVisible(false);
      this.host.setEditorName('');
      this.host.publishUiBackState();
      const mkdirRequest: TaildriveMutationRequest = {
        operation: 'mkdir',
        path: this.joinPath(directory, name)
      };
      await this.executeMutation(mkdirRequest, 'creating_folder', 'mutation_completed');
    } finally {
      this.host.setFolderSubmitInFlight(false);
    }
  }

  renameEntry(entry: TaildriveEntry): void {
    if (!this.host.isConnected() || this.host.isBusy() ||
      this.host.isEditorSubmitInFlight() || !this.canModifyCurrentPath()) {
      return;
    }
    this.host.setEditorOperation('rename');
    this.host.setEditorPath(entry.path);
    this.host.setEditorName(entry.name);
    this.editorDirectory = this.host.getPath();
    this.editorGeneration = this.host.getFileActionGeneration();
    this.host.setEditorVisible(true);
  }

  editorContextCurrent(directory?: string, generation?: number): boolean {
    const dir: string = directory ?? this.editorDirectory;
    const gen: number = generation ?? this.editorGeneration;
    return this.host.isEditorVisible() && dir === this.host.getPath() &&
      gen === this.host.getFileActionGeneration() &&
      this.host.isConnected() && this.host.isBrowserVisible() && !this.host.isAppLockActive() &&
      (!this.host.isStandalone() || this.host.isFilesTabActive());
  }

  async submitEditor(): Promise<void> {
    if (!this.host.isEditorVisible() || this.host.isEditorSubmitInFlight() ||
      this.host.isBusy() || !this.editorContextCurrent()) {
      return;
    }
    const name: string = this.host.getEditorName().trim();
    if (!this.validName(name)) {
      this.host.setStatus('invalid_name');
      return;
    }
    const operation: string = this.host.getEditorOperation();
    const sourcePath: string = this.host.getEditorPath();
    const directory: string = this.editorDirectory;
    const generation: number = this.editorGeneration;
    const protectedPath: string = operation === 'mkdir' ? directory : sourcePath;
    this.host.setEditorSubmitInFlight(true);
    try {
      if (!await this.ensureProtectedMutationAccess(protectedPath) ||
        !this.editorContextCurrent(directory, generation) || this.host.isBusy() ||
        this.host.getEditorPath() !== sourcePath || this.host.getEditorOperation() !== operation) {
        return;
      }
      const targetPath: string = operation === 'mkdir' ?
        this.joinPath(directory, name) : this.joinPath(this.parentPath(sourcePath), name);
      const mkdirRequest: TaildriveMutationRequest = { operation: 'mkdir', path: targetPath };
      const renameRequest: TaildriveMutationRequest = {
        operation: 'rename',
        path: sourcePath,
        newPath: targetPath
      };
      const request: TaildriveMutationRequest = operation === 'mkdir' ? mkdirRequest : renameRequest;
      this.host.setEditorVisible(false);
      await this.executeMutation(
        request,
        operation === 'mkdir' ? 'creating_folder' : 'renaming',
        'mutation_completed'
      );
    } finally {
      this.host.setEditorSubmitInFlight(false);
    }
  }

  canUseDetailsContext(directory: string, generation: number): boolean {
    return directory === this.host.getPath() && generation === this.host.getFileActionGeneration() &&
      this.host.isConnected() && this.host.isBrowserVisible() && !this.host.isAppLockActive() &&
      (!this.host.isStandalone() || this.host.isFilesTabActive());
  }

  detailsContextCurrent(requestId?: number): boolean {
    const expectedId: number = requestId ?? this.detailsRequestId;
    return this.host.isDetailsVisible() && expectedId === this.detailsRequestId &&
      this.canUseDetailsContext(this.detailsDirectory, this.detailsGeneration);
  }

  closeDetails(): void {
    this.host.setDetailsVisible(false);
    this.detailsRequestId++;
    this.host.setDetailsLoading(false);
    this.host.setDetailsReason('');
    this.host.setDetailEntry(emptyTaildriveEntry());
  }

  takeDetailEntry(): TaildriveEntry | undefined {
    const entry: TaildriveEntry = this.host.getDetailEntry();
    if (!this.detailsContextCurrent() || this.host.isDetailsLoading() ||
      this.host.isBusy() || entry.path.length === 0) {
      return undefined;
    }
    this.closeDetails();
    return entry;
  }

  async showDetails(entry: TaildriveEntry): Promise<void> {
    const directory: string = this.host.getPath();
    const generation: number = this.host.getFileActionGeneration();
    if (!this.canUseDetailsContext(directory, generation)) {
      return;
    }
    this.closeDetails();
    const requestId: number = this.detailsRequestId;
    if (!await this.ensureFolderAccess(entry.path) || requestId !== this.detailsRequestId ||
      !this.canUseDetailsContext(directory, generation)) {
      return;
    }
    this.detailsDirectory = directory;
    this.detailsGeneration = generation;
    this.host.setDetailEntry(entry);
    this.host.setDetailsVisible(true);
    this.host.setDetailsLoading(true);
    this.host.setDetailsReason('');
    try {
      const result: TaildriveStatResult = await this.host.gatewayStat(entry.path);
      if (!this.detailsContextCurrent(requestId)) {
        return;
      }
      if (result.state === 'ready') {
        this.host.setDetailEntry(result.entry);
      } else {
        this.host.setDetailsReason(result.reason.length > 0 ? result.reason : 'file_unavailable');
      }
    } catch (_error) {
      if (this.detailsContextCurrent(requestId)) {
        this.host.setDetailsReason('backend_unavailable');
      }
    } finally {
      if (this.detailsContextCurrent(requestId)) {
        this.host.setDetailsLoading(false);
      }
    }
  }

  canUseMoveContext(directory: string, generation: number): boolean {
    return directory === this.host.getPath() && generation === this.host.getFileActionGeneration() &&
      this.host.isConnected() && this.host.isBrowserVisible() && !this.host.isAppLockActive() &&
      (!this.host.isStandalone() || this.host.isFilesTabActive());
  }

  moveContextCurrent(requestId?: number): boolean {
    const expectedId: number = requestId ?? this.moveRequestId;
    return this.host.isMoveVisible() && expectedId === this.moveRequestId &&
      this.canUseMoveContext(this.moveDirectory, this.moveGeneration);
  }

  canApplyMoveList(requestId: number, generation: number, directory: string): boolean {
    return this.moveContextCurrent(requestId) && generation === this.moveListGeneration &&
      directory === this.host.getMovePath();
  }

  moveSubmissionCurrent(requestId: number, sourcePath: string, destination: string): boolean {
    return this.moveContextCurrent(requestId) && !this.host.isBusy() && !this.host.isMoveLoading() &&
      this.host.getMoveReason().length === 0 &&
      this.movingEntry !== undefined && this.movingEntry.path === sourcePath &&
      this.host.getMovePath() === destination && this.validMoveDestination(destination);
  }

  canConfirmMove(): boolean {
    return !this.host.isMoveSubmitInFlight() && this.movingEntry !== undefined &&
      this.moveSubmissionCurrent(this.moveRequestId, this.movingEntry.path, this.host.getMovePath());
  }

  closeMovePicker(): void {
    this.host.setMoveVisible(false);
    this.host.setMoveOperation('move');
    this.host.setMoveTargetCount(0);
    this.moveRequestId++;
    this.moveListGeneration++;
    this.host.setMoveLoading(false);
    this.host.setMoveEntries([]);
    this.host.setMoveReason('');
    this.movingEntry = undefined;
    this.movingEntries = [];
  }

  async openMovePicker(entry: TaildriveEntry): Promise<void> {
    if (!this.host.isConnected() || this.host.isBusy() ||
      this.host.isMoveSubmitInFlight() || !this.canModifyCurrentPath()) {
      return;
    }
    if (this.host.isMoveVisible()) {
      this.closeMovePicker();
    }
    const requestId: number = ++this.moveRequestId;
    const directory: string = this.host.getPath();
    const generation: number = this.host.getFileActionGeneration();
    if (!this.canUseMoveContext(directory, generation) ||
      !await this.ensureProtectedMutationAccess(entry.path) || requestId !== this.moveRequestId ||
      !this.canUseMoveContext(directory, generation) || this.host.isBusy() || this.host.isMoveSubmitInFlight()) {
      return;
    }
    this.moveDirectory = directory;
    this.moveGeneration = generation;
    this.host.setMoveOperation('move');
    this.host.setMoveTargetCount(1);
    this.movingEntry = entry;
    this.movingEntries = [entry];
    this.host.setMoveRoot('/');
    this.host.setMovePath(this.validMoveDestination(directory) ? directory : this.shareRoot(entry.path));
    this.host.setMoveVisible(true);
    await this.loadMoveDirectory();
  }

  async openDestinationPickerForEntries(entries: TaildriveEntry[], operation: string): Promise<void> {
    const targets: TaildriveEntry[] = entries.map((item: TaildriveEntry) => snapshotTaildriveEntry(item));
    if (!this.host.isConnected() || this.host.isBusy() ||
      this.host.isMoveSubmitInFlight() || !this.canModifyCurrentPath() || targets.length === 0) {
      return;
    }
    if (this.host.isMoveVisible()) {
      this.closeMovePicker();
    }
    const requestId: number = ++this.moveRequestId;
    const directory: string = this.host.getPath();
    const generation: number = this.host.getFileActionGeneration();
    if (!this.canUseMoveContext(directory, generation)) {
      return;
    }
    for (let index: number = 0; index < targets.length; index++) {
      if (!await this.ensureProtectedMutationAccess(targets[index].path) || requestId !== this.moveRequestId ||
        !this.canUseMoveContext(directory, generation) || this.host.isBusy() || this.host.isMoveSubmitInFlight()) {
        return;
      }
    }
    this.moveDirectory = directory;
    this.moveGeneration = generation;
    this.host.setMoveOperation(operation === 'copy' ? 'copy' : 'move');
    this.host.setMoveTargetCount(targets.length);
    this.movingEntry = targets[0];
    this.movingEntries = targets;
    this.host.setMoveRoot('/');
    this.host.setMovePath(this.validMoveDestination(directory) ? directory : this.shareRoot(targets[0].path));
    this.host.setMoveVisible(true);
    await this.loadMoveDirectory();
  }

  async openCopySelectedPicker(): Promise<void> {
    await this.openDestinationPickerForEntries(this.selectedEntries(), 'copy');
  }

  async openMoveSelectedPicker(): Promise<void> {
    await this.openDestinationPickerForEntries(this.selectedEntries(), 'move');
  }

  async loadMoveDirectory(): Promise<void> {
    if (!this.moveContextCurrent() || this.host.isMoveSubmitInFlight()) {
      return;
    }
    const requestId: number = this.moveRequestId;
    const generation: number = ++this.moveListGeneration;
    const directory: string = this.host.getMovePath();
    this.host.setMoveLoading(true);
    this.host.setMoveEntries([]);
    this.host.setMoveReason('');
    try {
      if (!await this.ensureFolderAccess(directory)) {
        if (this.canApplyMoveList(requestId, generation, directory)) {
          this.host.setMoveReason('folder_authentication_failed');
        }
        return;
      }
      if (!this.canApplyMoveList(requestId, generation, directory)) {
        return;
      }
      const result: TaildriveListResult = await this.host.gatewayList(directory);
      if (!this.canApplyMoveList(requestId, generation, directory)) {
        return;
      }
      this.host.setMoveEntries(result.state === 'ready' ? result.entries : []);
      if (result.state !== 'ready') {
        this.host.setMoveReason(result.reason.length > 0 ? result.reason : 'list_failed');
      }
    } catch (_error) {
      if (this.canApplyMoveList(requestId, generation, directory)) {
        this.host.setMoveEntries([]);
        this.host.setMoveReason('backend_unavailable');
      }
    } finally {
      if (this.canApplyMoveList(requestId, generation, directory)) {
        this.host.setMoveLoading(false);
      }
    }
  }

  moveGoUp(): void {
    const movePath: string = this.host.getMovePath();
    if (!this.moveContextCurrent() || this.host.isBusy() || this.host.isMoveSubmitInFlight() ||
      movePath === '/' || this.host.isMoveLoading()) {
      return;
    }
    const parent: string = this.parentPath(movePath);
    this.host.setMovePath(parent.length === 0 ? '/' : parent);
    this.loadMoveDirectory();
  }

  openMoveDirectory(entry: TaildriveEntry): void {
    const targets: TaildriveEntry[] = this.activeMoveTargets();
    if (!this.moveContextCurrent() || this.host.isBusy() || this.host.isMoveLoading() ||
      this.host.isMoveSubmitInFlight() || entry.kind !== 'directory' || targets.length === 0 ||
      !targets.every((target: TaildriveEntry) =>
        entry.path !== target.path && !entry.path.startsWith(`${target.path}/`))) {
      return;
    }
    this.host.setMovePath(entry.path);
    this.loadMoveDirectory();
  }

  navigateToMoveBreadcrumb(index: number): void {
    if (!this.moveContextCurrent() || this.host.isBusy() ||
      this.host.isMoveLoading() || this.host.isMoveSubmitInFlight()) {
      return;
    }
    const currentMovePath: string = this.host.getMovePath();
    const nextPath: string = index < 0 ? '/' : this.buildSegmentPath(currentMovePath, index);
    if (nextPath === currentMovePath) {
      return;
    }
    this.host.vibrateTouch(false);
    this.host.setMovePath(nextPath);
    this.loadMoveDirectory();
  }

  private activeMoveTargets(): TaildriveEntry[] {
    if (this.movingEntries !== undefined && this.movingEntries.length > 0) {
      return this.movingEntries;
    }
    return this.movingEntry !== undefined ? [this.movingEntry] : [];
  }

  validMoveDestination(path: string): boolean {
    const targets: TaildriveEntry[] = this.activeMoveTargets();
    if (targets.length === 0) {
      return false;
    }
    if (taildrivePathDepth(path) < 3) {
      return false;
    }
    return targets.every((entry: TaildriveEntry) =>
      path !== entry.path && !path.startsWith(`${entry.path}/`));
  }

  moveDestinationEntries(): TaildriveEntry[] {
    const targets: TaildriveEntry[] = this.activeMoveTargets();
    if (targets.length === 0) {
      return [];
    }
    return this.host.getMoveEntries().filter((entry: TaildriveEntry) =>
      entry.kind === 'directory' && targets.every((target: TaildriveEntry) =>
        entry.path !== target.path && !entry.path.startsWith(`${target.path}/`)));
  }

  async confirmMove(): Promise<void> {
    if (this.host.getMoveOperation() === 'copy' ||
      (this.movingEntries !== undefined && this.movingEntries.length > 1)) {
      await this.confirmBatchDestinationTransfer();
      return;
    }
    const destination: string = this.host.getMovePath();
    if (this.movingEntry === undefined || this.host.isMoveSubmitInFlight() ||
      !this.moveSubmissionCurrent(this.moveRequestId, this.movingEntry.path, destination)) {
      return;
    }
    if (this.parentPath(this.movingEntry.path) === destination) {
      this.host.setStatus('same_location');
      this.closeMovePicker();
      return;
    }
    const requestId: number = this.moveRequestId;
    const sourcePath: string = this.movingEntry.path;
    const name: string = this.movingEntry.name;
    this.host.setMoveSubmitInFlight(true);
    try {
      if (!await this.ensureProtectedMutationAccess(sourcePath) ||
        !this.moveSubmissionCurrent(requestId, sourcePath, destination)) {
        return;
      }
      if (!await this.ensureFolderAccess(destination) ||
        !this.moveSubmissionCurrent(requestId, sourcePath, destination)) {
        return;
      }
      const request: TaildriveMutationRequest = {
        operation: 'move',
        path: sourcePath,
        newPath: this.joinPath(destination, name)
      };
      this.closeMovePicker();
      await this.executeMutation(request, 'moving', 'move_completed');
    } finally {
      this.host.setMoveSubmitInFlight(false);
    }
  }

  async confirmBatchDestinationTransfer(): Promise<void> {
    const targets: TaildriveEntry[] = this.activeMoveTargets();
    const operation: string = this.host.getMoveOperation() === 'copy' ? 'copy' : 'move';
    const requestId: number = this.moveRequestId;
    const destination: string = this.host.getMovePath();
    if (targets.length === 0 || this.host.isMoveSubmitInFlight() ||
      !this.moveSubmissionCurrent(requestId, targets[0].path, destination)) {
      return;
    }
    if (operation === 'move' &&
      targets.every((entry: TaildriveEntry) => this.parentPath(entry.path) === destination)) {
      this.host.setStatus('same_location');
      this.closeMovePicker();
      return;
    }
    this.host.setMoveSubmitInFlight(true);
    try {
      for (let index: number = 0; index < targets.length; index++) {
        if (!await this.ensureProtectedMutationAccess(targets[index].path) ||
          !this.moveSubmissionCurrent(requestId, targets[0].path, destination)) {
          return;
        }
      }
      if (!await this.ensureFolderAccess(destination) ||
        !this.moveSubmissionCurrent(requestId, targets[0].path, destination)) {
        return;
      }
      const reservedLower: string[] = this.host.getMoveEntries().map(
        (entry: TaildriveEntry) => entry.name.toLowerCase()
      );
      const mutations: TaildriveMutationRequest[] = [];
      targets.forEach((entry: TaildriveEntry) => {
        if (operation === 'move' && this.parentPath(entry.path) === destination) {
          return;
        }
        const targetName: string = operation === 'copy' ?
          this.suggestCopyTargetName(entry, destination, reservedLower) : entry.name;
        const mutation: TaildriveMutationRequest = {
          operation: operation,
          path: entry.path,
          newPath: this.joinPath(destination, targetName)
        };
        mutations.push(mutation);
      });
      this.closeMovePicker();
      if (mutations.length === 0) {
        return;
      }
      const workingStatus: string = operation === 'copy' ? 'copying' : 'moving';
      const completedStatus: string = operation === 'copy' ? 'copy_completed' : 'move_completed';
      if (mutations.length === 1) {
        await this.executeMutation(mutations[0], workingStatus, completedStatus);
        return;
      }
      const directory: string = this.host.getPath();
      const generation: number = this.host.getFileActionGeneration();
      if (!this.beginWriteAuthorization()) {
        return;
      }
      let dispatched: boolean = false;
      try {
        for (let index: number = 0; index < mutations.length; index++) {
          if (!this.completeWriteAuthorization(
            await this.ensureMutationRequestAccess(mutations[index]), directory, generation)) {
            return;
          }
        }
        this.host.setStatus(workingStatus);
        this.clearRetry();
        dispatched = true;
        let lockPolicySaved: boolean = true;
        for (let index: number = 0; index < mutations.length; index++) {
          const result: TaildriveMutationResult = await this.host.gatewayMutate(mutations[index]);
          if (result.state !== 'completed') {
            this.host.setStatus(result.reason.length > 0 ? result.reason : 'mutation_failed');
            await this.refresh();
            return;
          }
          if (operation === 'move') {
            lockPolicySaved = await this.reconcileLockedFoldersAfterMutation(mutations[index]) && lockPolicySaved;
          }
        }
        this.host.showTransientStatus(lockPolicySaved ? completedStatus : 'security_settings_save_failed');
        if (this.host.isSelectionMode()) {
          this.exitSelectionMode();
        }
        await this.refresh();
      } catch (_error) {
        if (!dispatched) {
          this.completeWriteAuthorization(false, directory, generation);
          return;
        }
        this.host.setStatus('mutation_failed');
        await this.refresh();
      } finally {
        this.host.setBusy(false);
      }
    } finally {
      this.host.setMoveSubmitInFlight(false);
    }
  }

  // --- Confirmation & Write / Upload Dispatch ---

  canUseUploadSelection(uploadDirectory: string, generation: number): boolean {
    return generation === this.host.getFileActionGeneration() &&
      this.host.isBrowserVisible() && this.host.isConnected() &&
      !this.host.isAppLockActive() && this.host.getPath() === uploadDirectory &&
      (!this.host.isStandalone() || this.host.isFilesTabActive());
  }

  canUseWriteContext(directory: string, generation: number): boolean {
    return directory === this.host.getPath() && generation === this.host.getFileActionGeneration() &&
      this.host.isConnected() && this.host.isBrowserVisible() && !this.host.isAppLockActive() &&
      (!this.host.isStandalone() || this.host.isFilesTabActive());
  }

  beginWriteAuthorization(): boolean {
    if (this.host.isBusy() ||
      !this.canUseWriteContext(this.host.getPath(), this.host.getFileActionGeneration())) {
      return false;
    }
    this.host.setBusy(true);
    this.host.setStatus('authorizing_file_operation');
    return true;
  }

  completeWriteAuthorization(allowed: boolean, directory: string, generation: number): boolean {
    const current: boolean = this.canUseWriteContext(directory, generation);
    if (allowed && current) {
      return true;
    }
    if (this.host.getStatus() === 'authorizing_file_operation') {
      this.host.setStatus(current ? 'folder_authentication_failed' : '');
    }
    return false;
  }

  dismissFileConfirmation(requestId: number): boolean {
    if (requestId !== this.fileConfirmationId) {
      return false;
    }
    this.fileConfirmationId++;
    return true;
  }

  acceptFileConfirmation(requestId: number, directory: string, generation: number): boolean {
    return this.dismissFileConfirmation(requestId) && !this.host.isBusy() &&
      this.canUseWriteContext(directory, generation);
  }

  confirmDelete(entry: TaildriveEntry): void {
    const directory: string = this.host.getPath();
    const generation: number = this.host.getFileActionGeneration();
    if (this.host.isBusy() || !this.canModifyCurrentPath() || !this.canUseWriteContext(directory, generation)) {
      return;
    }
    const target: TaildriveEntry = snapshotTaildriveEntry(entry);
    const requestId: number = ++this.fileConfirmationId;
    const prompt: TaildriveConfirmationPrompt = {
      kind: 'delete_single',
      itemName: target.name,
      selectedCount: 1,
      autoCancel: true,
      onCancel: () => { this.dismissFileConfirmation(requestId); },
      onDismiss: () => { this.dismissFileConfirmation(requestId); },
      onConfirm: () => {
        if (this.acceptFileConfirmation(requestId, directory, generation)) {
          this.deleteEntry(target);
        }
      }
    };
    this.host.showConfirmationPrompt(prompt);
  }

  async deleteEntry(entry: TaildriveEntry): Promise<void> {
    const deleteRequest: TaildriveMutationRequest = { operation: 'delete', path: entry.path };
    await this.executeMutation(deleteRequest, 'deleting', 'delete_completed');
  }

  confirmDeleteSelected(): void {
    const selected: TaildriveEntry[] = this.selectedEntries().map(
      (entry: TaildriveEntry) => snapshotTaildriveEntry(entry)
    );
    const directory: string = this.host.getPath();
    const generation: number = this.host.getFileActionGeneration();
    if (selected.length === 0 || this.host.isBusy() || !this.canModifyCurrentPath() ||
      !this.canUseWriteContext(directory, generation)) {
      return;
    }
    const requestId: number = ++this.fileConfirmationId;
    const prompt: TaildriveConfirmationPrompt = {
      kind: 'delete_selected',
      itemName: '',
      selectedCount: selected.length,
      autoCancel: true,
      onCancel: () => { this.dismissFileConfirmation(requestId); },
      onDismiss: () => { this.dismissFileConfirmation(requestId); },
      onConfirm: () => {
        if (this.acceptFileConfirmation(requestId, directory, generation)) {
          this.deleteSelectedEntries(selected);
        }
      }
    };
    this.host.showConfirmationPrompt(prompt);
  }

  promptMutationOverwrite(
    request: TaildriveMutationRequest,
    workingStatus: string,
    completedStatus: string
  ): void {
    const directory: string = this.host.getPath();
    const generation: number = this.host.getFileActionGeneration();
    if (!this.canUseWriteContext(directory, generation)) {
      return;
    }
    const operation: string = request.operation;
    const path: string = request.path;
    const targetPath: string | undefined = request.newPath;
    const requestId: number = ++this.fileConfirmationId;
    const prompt: TaildriveConfirmationPrompt = {
      kind: 'overwrite_mutation',
      itemName: targetPath === undefined ? '' : this.pathName(targetPath),
      selectedCount: 1,
      autoCancel: false,
      onCancel: () => { this.dismissFileConfirmation(requestId); },
      onDismiss: () => { this.dismissFileConfirmation(requestId); },
      onConfirm: () => {
        if (this.acceptFileConfirmation(requestId, directory, generation)) {
          const overwriteRequest: TaildriveMutationRequest = {
            operation: operation,
            path: path,
            newPath: targetPath,
            overwrite: true
          };
          this.executeMutation(overwriteRequest, workingStatus, completedStatus);
        }
      }
    };
    this.host.showConfirmationPrompt(prompt);
  }

  promptUploadOverwrite(fileName: string): void {
    const staged: PreparedTaildriveFile | undefined = this.pendingUpload;
    const targetPath: string = this.pendingUploadPath;
    const directory: string = this.host.getPath();
    const generation: number = this.host.getFileActionGeneration();
    if (staged === undefined || targetPath.length === 0 || !this.canUseWriteContext(directory, generation)) {
      return;
    }
    const requestId: number = ++this.fileConfirmationId;
    const prompt: TaildriveConfirmationPrompt = {
      kind: 'overwrite_upload',
      itemName: fileName,
      selectedCount: 1,
      autoCancel: false,
      onCancel: () => {
        if (this.dismissFileConfirmation(requestId) &&
          this.pendingUpload === staged && this.pendingUploadPath === targetPath) {
          this.discardPendingUpload();
        }
      },
      onDismiss: () => { this.dismissFileConfirmation(requestId); },
      onConfirm: () => {
        if (this.acceptFileConfirmation(requestId, directory, generation) &&
          this.pendingUpload === staged && this.pendingUploadPath === targetPath) {
          this.executeUpload(true);
        }
      }
    };
    this.host.showConfirmationPrompt(prompt);
  }

  discardPendingUpload(): void {
    if (this.pendingUpload !== undefined) {
      this.host.gatewayCleanupStaged(this.pendingUpload);
    }
    this.pendingUpload = undefined;
    this.pendingUploadPath = '';
    if (this.retryKind === 'upload') {
      this.clearRetry();
    }
  }

  async selectUpload(): Promise<void> {
    if (!this.host.isConnected() || this.host.isBusy() ||
      this.uploadSelectionInFlight || !this.canModifyCurrentPath()) {
      return;
    }
    const uploadDirectory: string = this.host.getPath();
    const generation: number = this.host.getFileActionGeneration();
    let ownsBusyState: boolean = false;
    this.uploadSelectionInFlight = true;
    try {
      if (!await this.ensureFolderAccess(uploadDirectory) ||
        !this.canUseUploadSelection(uploadDirectory, generation) || this.host.isBusy()) {
        return;
      }
      let uris: string[] = [];
      try {
        uris = await this.host.pickUploadDocumentUris();
      } catch (_error) {
        if (this.canUseUploadSelection(uploadDirectory, generation)) {
          this.host.setStatus('file_selection_failed');
        }
        return;
      }
      if (uris.length === 0 || !this.canUseUploadSelection(uploadDirectory, generation) || this.host.isBusy()) {
        return;
      }
      this.discardPendingUpload();
      this.host.setBusy(true);
      ownsBusyState = true;
      this.host.setStatus('preparing_upload');
      const requestId: number = Date.now();
      const stagingRoot: string = this.host.stagingRoot();
      this.host.ensureStagingDirectory(stagingRoot);
      const staged: PreparedTaildriveFile = await this.host.gatewayStageUpload(uris[0], stagingRoot, requestId);
      if (!this.canUseUploadSelection(uploadDirectory, generation)) {
        this.host.gatewayCleanupStaged(staged);
        return;
      }
      this.pendingUpload = staged;
      this.pendingUploadPath = this.joinPath(uploadDirectory, this.safeRemoteName(staged.name));
      this.host.setBusy(false);
      ownsBusyState = false;
      await this.executeUpload(false);
    } catch (_error) {
      if (this.canUseUploadSelection(uploadDirectory, generation)) {
        this.host.setStatus('upload_failed');
        this.clearRetry();
      }
    } finally {
      if (ownsBusyState) {
        this.host.setBusy(false);
      }
      if (this.host.getStatus() === 'preparing_upload') {
        this.host.setStatus('');
      }
      this.uploadSelectionInFlight = false;
    }
  }

  async executeUpload(overwrite: boolean): Promise<void> {
    if (this.host.isBusy()) {
      return;
    }
    if (this.pendingUpload === undefined || this.pendingUploadPath.length === 0) {
      this.host.setStatus('file_unavailable');
      this.clearRetry();
      return;
    }
    const staged: PreparedTaildriveFile = this.pendingUpload;
    const remotePath: string = this.pendingUploadPath;
    const localPath: string = staged.path;
    const modifiedAtMs: number = staged.modifiedAtMs;
    const directory: string = this.host.getPath();
    const generation: number = this.host.getFileActionGeneration();
    if (!this.beginWriteAuthorization()) {
      return;
    }
    let dispatched: boolean = false;
    try {
      if (!this.completeWriteAuthorization(await this.ensureFolderAccess(remotePath), directory, generation)) {
        return;
      }
      this.host.setStatus('uploading');
      this.clearRetry();
      this.host.startTransferPolling();
      dispatched = true;
      const uploadRequest: TaildriveTransferRequest = {
        requestId: Date.now(),
        remotePath: remotePath,
        localRoot: this.host.stagingRoot(),
        localPath: localPath,
        sourceModifiedAtMs: modifiedAtMs,
        overwrite: overwrite
      };
      const result: TaildriveTransferSnapshot = await this.host.gatewayUpload(uploadRequest);
      this.host.setTransfer(result);
      if (result.state === 'completed') {
        this.host.showTransientStatus('upload_completed');
        await this.host.publishTransferCompletion(staged.name, true);
        this.discardPendingUpload();
        await this.refresh();
      } else if ((result.reason === 'already_exists' || result.reason === 'file_exists') && !overwrite) {
        this.host.setStatus(result.reason);
        if (this.canUseWriteContext(directory, generation)) {
          this.promptUploadOverwrite(staged.name);
        }
      } else {
        this.host.setStatus(result.reason.length > 0 ? result.reason : 'upload_failed');
        this.setRetry('upload');
        await this.host.publishTransferCompletion(staged.name, false);
      }
    } catch (_error) {
      if (!dispatched) {
        this.completeWriteAuthorization(false, directory, generation);
        return;
      }
      this.host.setStatus('upload_failed');
      this.setRetry('upload');
      await this.host.publishTransferCompletion(staged.name, false);
    } finally {
      this.host.setBusy(false);
      if (dispatched) {
        this.host.stopTransferPolling();
        await this.host.clearTransferProgress();
      }
    }
  }

  async deleteSelectedEntries(selected: TaildriveEntry[]): Promise<void> {
    const paths: string[] = selected.map((entry: TaildriveEntry) => entry.path);
    if (paths.length === 0) {
      return;
    }
    const directory: string = this.host.getPath();
    const generation: number = this.host.getFileActionGeneration();
    if (!this.beginWriteAuthorization()) {
      return;
    }
    let dispatched: boolean = false;
    let deletedCount: number = 0;
    try {
      for (let index: number = 0; index < paths.length; index++) {
        if (!this.completeWriteAuthorization(
          await this.ensureProtectedMutationAccess(paths[index]), directory, generation)) {
          return;
        }
      }
      this.host.setStatus('deleting');
      this.clearRetry();
      dispatched = true;
      let lockPolicySaved: boolean = true;
      for (let index: number = 0; index < paths.length; index++) {
        const deleteRequest: TaildriveMutationRequest = {
          operation: 'delete',
          path: paths[index]
        };
        const result: TaildriveMutationResult = await this.host.gatewayMutate(deleteRequest);
        if (result.state !== 'completed') {
          const failureStatus: string = result.reason.length > 0 ? result.reason : 'delete_failed';
          if (deletedCount > 0) {
            this.exitSelectionMode();
            await this.refresh();
          }
          this.host.setStatus(failureStatus);
          return;
        }
        deletedCount++;
        lockPolicySaved = await this.reconcileLockedFoldersAfterMutation(deleteRequest) && lockPolicySaved;
      }
      this.host.showTransientStatus(lockPolicySaved ? 'delete_completed' : 'security_settings_save_failed');
      this.exitSelectionMode();
      await this.refresh();
    } catch (_error) {
      if (!dispatched) {
        this.completeWriteAuthorization(false, directory, generation);
        return;
      }
      const failureStatus: string = 'delete_failed';
      if (deletedCount > 0) {
        this.exitSelectionMode();
        try {
          await this.refresh();
        } catch (_refreshError) {
        }
      }
      this.host.setStatus(failureStatus);
    } finally {
      this.host.setBusy(false);
    }
  }

  async executeMutation(
    request: TaildriveMutationRequest,
    workingStatus: string,
    completedStatus: string
  ): Promise<void> {
    const mutation: TaildriveMutationRequest = {
      operation: request.operation,
      path: request.path,
      newPath: request.newPath,
      overwrite: request.overwrite
    };
    const directory: string = this.host.getPath();
    const generation: number = this.host.getFileActionGeneration();
    if (!this.beginWriteAuthorization()) {
      return;
    }
    let dispatched: boolean = false;
    try {
      if (!this.completeWriteAuthorization(
        await this.ensureMutationRequestAccess(mutation), directory, generation)) {
        return;
      }
      this.host.setStatus(workingStatus);
      this.clearRetry();
      dispatched = true;
      const result: TaildriveMutationResult = await this.host.gatewayMutate(mutation);
      if (result.state === 'completed') {
        const lockPolicySaved: boolean = await this.reconcileLockedFoldersAfterMutation(mutation);
        this.host.showTransientStatus(lockPolicySaved ? completedStatus : 'security_settings_save_failed');
        this.retryMutation = undefined;
        if (this.host.isSelectionMode()) {
          this.exitSelectionMode();
        }
        await this.refresh();
      } else if ((result.reason === 'already_exists' || result.reason === 'file_exists') &&
        mutation.newPath !== undefined && mutation.overwrite !== true) {
        this.host.setStatus(result.reason);
        if (this.canUseWriteContext(directory, generation)) {
          this.promptMutationOverwrite(mutation, workingStatus, completedStatus);
        }
      } else {
        this.host.setStatus(result.reason.length > 0 ? result.reason : 'mutation_failed');
        this.retryMutation = mutation;
        this.retryMutationWorkingStatus = workingStatus;
        this.retryMutationCompletedStatus = completedStatus;
        this.setRetry('mutation');
      }
    } catch (_error) {
      if (!dispatched) {
        this.completeWriteAuthorization(false, directory, generation);
        return;
      }
      this.host.setStatus(mutation.operation === 'delete' ? 'delete_failed' : 'mutation_failed');
      this.retryMutation = mutation;
      this.retryMutationWorkingStatus = workingStatus;
      this.retryMutationCompletedStatus = completedStatus;
      this.setRetry('mutation');
    } finally {
      this.host.setBusy(false);
    }
  }

  // --- Retry & Banner Status ---

  setRetry(
    kind: string,
    downloadEntry?: TaildriveEntry,
    previewEntry?: TaildriveEntry
  ): void {
    if (downloadEntry !== undefined) {
      this.retryDownloadEntry = downloadEntry;
    }
    if (previewEntry !== undefined) {
      this.retryPreviewEntry = previewEntry;
    }
    this.retryKind = kind;
    this.host.setRetryAvailable(true);
  }

  clearRetry(): void {
    this.retryKind = '';
    this.host.setRetryAvailable(false);
    this.retryPreviewEntry = undefined;
  }

  hasListFailure(): boolean {
    return this.host.isRetryAvailable() && this.host.getReason().length > 0 &&
      (this.retryKind === 'refresh' || this.retryKind === 'target');
  }

  showRetainedListNotice(): boolean {
    return this.hasListFailure() && this.host.getEntries().length > 0 &&
      this.host.getLastListedPath() === this.host.getPath();
  }

  async retryLastOperation(): Promise<void> {
    if (this.host.isBusy() || !this.host.isConnected()) {
      return;
    }
    if (this.retryKind === 'refresh') {
      await this.refresh();
    } else if (this.retryKind === 'target') {
      await this.openTargetMachine(this.host.getTargetRequestId());
    } else if (this.retryKind === 'upload') {
      await this.executeUpload(false);
    } else if (this.retryKind === 'download' && this.retryDownloadEntry !== undefined) {
      await this.host.retryDownload(this.retryDownloadEntry);
    } else if (this.retryKind === 'preview' && this.retryPreviewEntry !== undefined) {
      await this.host.retryPreviewDownload(this.retryPreviewEntry);
    } else if (this.retryKind === 'mutation' && this.retryMutation !== undefined) {
      const request: TaildriveMutationRequest = this.retryMutation;
      await this.executeMutation(request, this.retryMutationWorkingStatus, this.retryMutationCompletedStatus);
    }
  }
}
