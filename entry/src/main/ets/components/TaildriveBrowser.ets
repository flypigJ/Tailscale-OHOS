import { ControlServerConfig } from '../services/ControlServerConfig';
import { AccountProfiles } from '../services/AccountProfiles';
import { LightAppearance } from './LightAppearance';
import { common, Want, wantConstant } from '@kit.AbilityKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { pasteboard } from '@kit.BasicServicesKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { vibrator } from '@kit.SensorServiceKit';
import { systemShare } from '@kit.ShareKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LengthMetrics, SymbolGlyphModifier, uiMaterial } from '@kit.ArkUI';
import {
  BlurStrategy,
  DividerShowType,
  HdsNavigation,
  HdsNavigationAttribute,
  HdsNavigationTitleMode,
  IconStyleMode,
  TextStyleMode,
  hdsMaterial
} from '@kit.UIDesignKit';
import {
  PreparedTaildriveFile,
  TaildriveEntry,
  TaildriveListResult,
  TaildriveMutationRequest,
  TaildriveMutationResult,
  TaildriveStatResult,
  TaildriveTransferRequest,
  TaildriveTransferSnapshot,
  extractFileExtension
} from '@tailscale/common';
import { TaildriveGateway } from '../services/TaildriveGateway';
import { resolveFileIconResource } from '../services/FileIconResolver';
import {
  TaildriveConfirmationPrompt,
  TaildriveGroupedBucket,
  TaildriveSessionController,
  TaildriveSessionHost,
  emptyTaildriveEntry,
  idleTaildriveTransfer,
  localTaildriveFileSnapshot,
  sanitizeTaildriveLocalName,
  snapshotTaildriveEntry,
  taildrivePathDepth
} from '../services/TaildriveSessionController';
import {
  clearTaildriveProgress,
  publishTaildriveCompletion,
  publishTaildriveProgress,
  TaildriveNotificationTransfer
} from '../services/TaildriveNotificationService';
import {
  TaildriveCachedPreview,
  TaildrivePreviewGateway
} from '../services/TaildrivePreviewGateway';
import { AppSecurityAuthenticator } from '../services/AppSecurityAuthenticator';
import { AppSecurityPreferences } from '../services/AppSecurityPreferences';
import { createLocalTextPasteData } from '../services/AppShellIntentAdapter';
import { APP_BACKGROUND_EVENT, APP_FOREGROUND_EVENT } from '../services/AppLifecycleEvents';
import { DiagnosticEventStore } from '../services/DiagnosticEventStore';
import { MotionTokens } from './MotionTokens';
import { UiTokens } from './UiTokens';
import { taildriveGuideNotice } from '../services/FeatureGuideEntryRules';
import { LatestTaskPool } from '../services/LatestTaskPool';

interface TaildriveEntryGroup {
  key: string;
  title: ResourceStr;
  entries: TaildriveEntry[];
}

interface TaildriveListItemModel {
  key: string;
  header: boolean;
  title: ResourceStr;
  entry: TaildriveEntry;
}

interface TaildriveThumbnailModel {
  remotePath: string;
  uri: string;
}

interface TaildriveSelectionActionData {
  icon: Resource;
  label: ResourceStr;
  isEnabled: boolean;
  destructive: boolean;
  actionId: string;
  action: () => void;
}

interface TaildriveSelectionMoreData {
  isEnabled: boolean;
  actionId: string;
  action: () => void;
}

interface TaildriveDetailActionData {
  icon: Resource;
  label: ResourceStr;
  isEnabled: boolean;
  destructive: boolean;
  actionId: string;
  action: () => void;
}

interface TaildriveSharePreparedFile {
  entry: TaildriveEntry;
  localPath: string;
}

const TAILDRIVE_AUTO_PREVIEW_LIMIT_BYTES: number = 5 * 1024 * 1024;
const TAILDRIVE_REFRESH_INTERVAL_MS: number = 30000;
const TAILDRIVE_LOG_DOMAIN: number = 0x0000;
const TAILDRIVE_LOG_TAG: string = 'TaildrivePreview';
const TAILDRIVE_SECURITY_LOG_TAG: string = 'TaildriveSecurity';
const TAILDRIVE_TOOLBAR_HEIGHT: number = 52;
const TAILDRIVE_SELECTION_TOOLBAR_HEIGHT: number = 48;
const TAILDRIVE_TOOLBAR_SIDE_MARGIN: number = 36;

class TaildriveListDataSource implements IDataSource {
  private data: TaildriveListItemModel[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.data.length;
  }

  getData(index: number): TaildriveListItemModel {
    return this.data[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  replaceAll(items: TaildriveListItemModel[]): void {
    this.data = [...items];
    this.listeners.forEach((listener: DataChangeListener) => listener.onDataReloaded());
  }
}

@Component
export struct TaildriveBrowser {
  @Prop @Watch('onConnectedChanged') connected: boolean = false;
  @Prop standalone: boolean = false;
  @Prop bottomInset: number = 0;
  @Prop titleBarPadding: number = 16;
  @Prop materialLevel: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.ADAPTIVE;
  @Prop glowLevel: number = 3;
  @Prop transparentBackground: boolean = false;
  @Prop targetMachineName: string = '';
  @Prop targetTailnetName: string = '';
  @Prop @Watch('onFolderLockEnabledChanged') folderLockEnabled: boolean = false;
  @Prop @Watch('onAppLockActiveChanged') appLockActive: boolean = false;
  @StorageLink('taildriveLockedFolderPaths') @Watch('onLockedFolderPathsChanged') lockedFolderPaths: string[] = [];
  @Prop @Watch('onTargetRequestChanged') targetRequestId: number = 0;
  @StorageLink('taildriveFilesTabActive') @Watch('onFilesTabActiveChanged') private filesTabActive: boolean = false;
  @StorageLink('taildriveBackRequest') @Watch('onBackRequestChanged') backRequest: number = 0;
  @State @Watch('onPathChanged') private path: string = '/';
  @State private entries: TaildriveEntry[] = [];
  @State private loading: boolean = false;
  @State private pullRefreshing: boolean = false;
  @State private busy: boolean = false;
  @State private previewDownloading: boolean = false;
  @State private manualDownloadCount: number = 0;
  @State private reason: string = '';
  @State private status: string = '';
  @State private searchQuery: string = '';
  @State private sortMode: string = 'modified';
  @State private sortDescending: boolean = true;
  @State private groupMode: string = 'date';
  @State private sortDraftMode: string = 'modified';
  @State private sortDraftDescending: boolean = true;
  @State private groupDraftMode: string = 'date';
  @State @Watch('onSortSheetVisibilityChanged') private sortSheetVisible: boolean = false;
  @State private searchVisible: boolean = false;
  @State private selectionMode: boolean = false;
  @State private dragSelecting: boolean = false;
  @State private selectedPaths: string[] = [];
  @State private viewMode: string = 'list';
  @State private retryAvailable: boolean = false;
  @State private editorVisible: boolean = false;
  @State private editorSubmitInFlight: boolean = false;
  @State private editorName: string = '';
  @State private editorOperation: string = 'mkdir';
  @State private editorPath: string = '';
  @State private folderDialogVisible: boolean = false;
  @State private folderSubmitInFlight: boolean = false;
  @State @Watch('onPreviewDownloadVisibilityChanged') private previewDownloadVisible: boolean = false;
  @State private previewDownloadEntry: TaildriveEntry = emptyTaildriveEntry();
  @State private detailsVisible: boolean = false;
  @State private detailsLoading: boolean = false;
  @State private detailsReason: string = '';
  @State private detailEntry: TaildriveEntry = emptyTaildriveEntry();
  @State private moveVisible: boolean = false;
  @State private moveOperation: string = 'move';
  @State private moveTargetCount: number = 0;
  @State private moveLoading: boolean = false;
  @State private moveSubmitInFlight: boolean = false;
  @State private moveReason: string = '';
  @State @Watch('onMovePathChanged') private movePath: string = '/';
  @State private moveRoot: string = '/';
  @State private moveEntries: TaildriveEntry[] = [];
  @State private transfer: TaildriveTransferSnapshot = idleTaildriveTransfer();
  @State private thumbnails: TaildriveThumbnailModel[] = [];
  @State private cachedEntries: TaildriveEntry[] = [];
  @State private downloadedEntries: TaildriveEntry[] = [];

  private readonly gateway: TaildriveGateway = new TaildriveGateway();
  private readonly previewGateway: TaildrivePreviewGateway = new TaildrivePreviewGateway();
  private readonly listDataSource: TaildriveListDataSource = new TaildriveListDataSource();
  onShowFeatureGuide: (section: string) => void = (_section: string) => {};
  onRequestConnection: () => void = () => {};
  @Prop connectionActionText: ResourceStr = '';
  @Prop connectionActionAvailable: boolean = false;
  @State private lastListedPath: string = '';
  contentScroller: Scroller = new Scroller();
  private breadcrumbScroller: Scroller = new Scroller();
  private movePathScroller: Scroller = new Scroller();
  private nextTransferRequestId: number = Date.now();
  private previewRequestId: number = 0;
  private previewGeneration: number = 0;
  private activePreviewPath: string = '';
  private transferTimer: number = -1;
  private transferPollInFlight: boolean = false;
  private statusTimer: number = -1;
  private refreshTimer: number = -1;
  private browserVisible: boolean = false;
  private appInForeground: boolean = true;
  private lastNotifiedProgress: number = -1;
  private retryDownloadEntry: TaildriveEntry | undefined = undefined;
  private retryPreviewEntry: TaildriveEntry | undefined = undefined;
  @State private fileActionGeneration: number = 0;
  private dragViewportWidth: number = 0;
  private dragViewportHeight: number = 0;
  private dragPointerLocalX: number = 0;
  private dragPointerLocalY: number = 0;
  private dragAutoScrollTimer: number = -1;
  private dragAutoScrollStepVp: number = 0;
  private lastDragVibrateAtMs: number = 0;
  private readonly thumbnailPool: LatestTaskPool<TaildriveEntry> = new LatestTaskPool<TaildriveEntry>(2);
  @State private folderAccessGrants: string[] = [];
  private folderAccessAuthenticationInFlight: boolean = false;
  private folderPolicyAuthenticationInFlight: boolean = false;
  private securityResumeTimer: number = -1;
  private uiTimers: number[] = [];
  private manualDownloadInFlight: boolean = false;
  private appForegroundListener: () => void = () => this.handleAppForeground();
  private appBackgroundListener: () => void = () => this.handleAppBackground();
  private readonly sessionHost: TaildriveSessionHost = {
    isConnected: (): boolean => this.connected,
    isStandalone: (): boolean => this.standalone,
    isFilesTabActive: (): boolean => this.filesTabActive,
    isBrowserVisible: (): boolean => this.browserVisible,
    isAppInForeground: (): boolean => this.appInForeground,
    setAppInForeground: (value: boolean): void => { this.appInForeground = value; },
    isAppLockActive: (): boolean => this.appLockActive,
    isFolderLockEnabled: (): boolean => this.folderLockEnabled,
    getLockedFolderPaths: (): string[] => this.lockedFolderPaths,
    setLockedFolderPaths: (paths: string[]): void => {
      AppStorage.setOrCreate('taildriveLockedFolderPaths', paths);
    },
    getFolderAccessGrants: (): string[] => this.folderAccessGrants,
    setFolderAccessGrants: (grants: string[]): void => { this.folderAccessGrants = grants; },
    isFolderAccessAuthInFlight: (): boolean => this.folderAccessAuthenticationInFlight,
    setFolderAccessAuthInFlight: (value: boolean): void => {
      this.folderAccessAuthenticationInFlight = value;
    },
    isFolderPolicyAuthInFlight: (): boolean => this.folderPolicyAuthenticationInFlight,
    setFolderPolicyAuthInFlight: (value: boolean): void => {
      this.folderPolicyAuthenticationInFlight = value;
    },

    getTargetMachineName: (): string => this.targetMachineName,
    getTargetTailnetName: (): string => this.targetTailnetName,
    getTargetRequestId: (): number => this.targetRequestId,

    getPath: (): string => this.path,
    setPath: (path: string): void => { this.path = path; },
    getEntries: (): TaildriveEntry[] => this.entries,
    setEntries: (entries: TaildriveEntry[]): void => { this.entries = entries; },
    getLastListedPath: (): string => this.lastListedPath,
    setLastListedPath: (path: string): void => { this.lastListedPath = path; },
    isLoading: (): boolean => this.loading,
    setLoading: (value: boolean): void => { this.loading = value; },
    isPullRefreshing: (): boolean => this.pullRefreshing,
    setPullRefreshing: (value: boolean): void => { this.pullRefreshing = value; },
    isBusy: (): boolean => this.busy,
    setBusy: (value: boolean): void => { this.busy = value; },
    getReason: (): string => this.reason,
    setReason: (reason: string): void => { this.reason = reason; },
    getStatus: (): string => this.status,
    setStatus: (status: string): void => { this.status = status; },
    showTransientStatus: (status: string): void => { this.showTransientStatus(status); },
    isRetryAvailable: (): boolean => this.retryAvailable,
    setRetryAvailable: (value: boolean): void => { this.retryAvailable = value; },

    getSearchQuery: (): string => this.searchQuery,
    setSearchQuery: (query: string): void => { this.searchQuery = query; },
    isSearchVisible: (): boolean => this.searchVisible,
    setSearchVisibleRaw: (visible: boolean): void => { this.searchVisible = visible; },
    dismissSearchAnimated: (): void => { this.setSearchVisible(false); },
    getSortMode: (): string => this.sortMode,
    isSortDescending: (): boolean => this.sortDescending,
    getGroupMode: (): string => this.groupMode,

    isSelectionMode: (): boolean => this.selectionMode,
    setSelectionMode: (value: boolean): void => { this.selectionMode = value; },
    isDragSelecting: (): boolean => this.dragSelecting,
    setDragSelecting: (value: boolean): void => { this.dragSelecting = value; },
    getSelectedPaths: (): string[] => this.selectedPaths,
    setSelectedPaths: (paths: string[]): void => { this.selectedPaths = paths; },

    getFileActionGeneration: (): number => this.fileActionGeneration,
    setFileActionGeneration: (value: number): void => { this.fileActionGeneration = value; },

    isEditorVisible: (): boolean => this.editorVisible,
    setEditorVisible: (visible: boolean): void => { this.editorVisible = visible; },
    isEditorSubmitInFlight: (): boolean => this.editorSubmitInFlight,
    setEditorSubmitInFlight: (value: boolean): void => { this.editorSubmitInFlight = value; },
    getEditorName: (): string => this.editorName,
    setEditorName: (name: string): void => { this.editorName = name; },
    getEditorOperation: (): string => this.editorOperation,
    setEditorOperation: (operation: string): void => { this.editorOperation = operation; },
    getEditorPath: (): string => this.editorPath,
    setEditorPath: (path: string): void => { this.editorPath = path; },

    isFolderDialogVisible: (): boolean => this.folderDialogVisible,
    setFolderDialogVisible: (visible: boolean): void => { this.folderDialogVisible = visible; },
    isFolderSubmitInFlight: (): boolean => this.folderSubmitInFlight,
    setFolderSubmitInFlight: (value: boolean): void => { this.folderSubmitInFlight = value; },

    isPreviewDownloadVisible: (): boolean => this.previewDownloadVisible,
    setPreviewDownloadVisible: (visible: boolean): void => { this.previewDownloadVisible = visible; },
    getPreviewDownloadEntry: (): TaildriveEntry => this.previewDownloadEntry,

    isDetailsVisible: (): boolean => this.detailsVisible,
    setDetailsVisible: (visible: boolean): void => { this.detailsVisible = visible; },
    isDetailsLoading: (): boolean => this.detailsLoading,
    setDetailsLoading: (value: boolean): void => { this.detailsLoading = value; },
    getDetailsReason: (): string => this.detailsReason,
    setDetailsReason: (reason: string): void => { this.detailsReason = reason; },
    getDetailEntry: (): TaildriveEntry => this.detailEntry,
    setDetailEntry: (entry: TaildriveEntry): void => { this.detailEntry = entry; },

    isMoveVisible: (): boolean => this.moveVisible,
    setMoveVisible: (visible: boolean): void => { this.moveVisible = visible; },
    getMoveOperation: (): string => this.moveOperation,
    setMoveOperation: (operation: string): void => { this.moveOperation = operation; },
    getMoveTargetCount: (): number => this.moveTargetCount,
    setMoveTargetCount: (count: number): void => { this.moveTargetCount = count; },
    isMoveLoading: (): boolean => this.moveLoading,
    setMoveLoading: (value: boolean): void => { this.moveLoading = value; },
    isMoveSubmitInFlight: (): boolean => this.moveSubmitInFlight,
    setMoveSubmitInFlight: (value: boolean): void => { this.moveSubmitInFlight = value; },
    getMoveReason: (): string => this.moveReason,
    setMoveReason: (reason: string): void => { this.moveReason = reason; },
    getMovePath: (): string => this.movePath,
    setMovePath: (path: string): void => { this.movePath = path; },
    setMoveRoot: (root: string): void => { this.moveRoot = root; },
    getMoveEntries: (): TaildriveEntry[] => this.moveEntries,
    setMoveEntries: (entries: TaildriveEntry[]): void => { this.moveEntries = entries; },

    isSortSheetVisible: (): boolean => this.sortSheetVisible,
    setSortSheetVisible: (visible: boolean): void => { this.sortSheetVisible = visible; },
    closeSortPanel: (): void => { this.closeSortPanel(); },

    setTransfer: (snapshot: TaildriveTransferSnapshot): void => { this.transfer = snapshot; },
    getCachedEntries: (): TaildriveEntry[] => this.cachedEntries,
    setCachedEntries: (entries: TaildriveEntry[]): void => { this.cachedEntries = entries; },
    getDownloadedEntries: (): TaildriveEntry[] => this.downloadedEntries,
    setDownloadedEntries: (entries: TaildriveEntry[]): void => { this.downloadedEntries = entries; },
    hasGatewayCachedPreview: (entry: TaildriveEntry): boolean =>
      this.previewGateway.cachedPreview(this.context(), entry) !== undefined,
    clearPreviewThumbnails: (): void => { this.thumbnails = []; },
    filterProtectedThumbnails: (matchesProtected: (remotePath: string) => boolean): void => {
      this.thumbnails = this.thumbnails.filter(
        (item: TaildriveThumbnailModel) => !matchesProtected(item.remotePath)
      );
    },
    purgeGatewayPreviewCaches: (normalizedTargets: string[]): void => {
      this.previewGateway.purgeProtectedPreviews(this.context(), normalizedTargets);
    },
    cancelThumbnailPool: (): void => { this.thumbnailPool.cancel(); },

    applyListResult: (result: TaildriveListResult, fallbackPath: string): void => {
      this.applyListResult(result, fallbackPath);
    },
    rebuildListDataSource: (): void => { this.rebuildListDataSource(); },
    updateBackState: (): void => { this.updateBackState(); },
    publishUiBackState: (): void => { this.publishUiBackState(); },
    startRefreshPolling: (): void => { this.startRefreshPolling(); },
    stopRefreshPolling: (): void => { this.stopRefreshPolling(); },
    startTransferPolling: (): void => { this.startTransferPolling(); },
    stopTransferPolling: (): void => { this.stopTransferPolling(); },
    stopDragAutoScroll: (): void => { this.stopDragAutoScroll(); },
    scheduleSecurityResume: (delayMs: number): void => {
      this.clearSecurityResumeTimer();
      this.securityResumeTimer = setTimeout((): void => {
        this.securityResumeTimer = -1;
        this.sessionController.onSecurityResumeTimerFired();
      }, delayMs);
    },
    clearSecurityResumeTimer: (): void => { this.clearSecurityResumeTimer(); },
    delayIndicator: (ms: number): Promise<void> =>
      new Promise<void>((resolve: () => void) => { setTimeout(resolve, ms); }),
    vibrateTouch: (strong: boolean = false): void => { this.vibrateTouch(strong); },
    vibrateDragStep: (): void => { this.vibrateDragStep(); },
    localizedNewFolderName: (): string => this.localizedNewFolderName(),
    showConfirmationPrompt: (prompt: TaildriveConfirmationPrompt): void => {
      this.showConfirmationPrompt(prompt);
    },
    pickUploadDocumentUris: (): Promise<string[]> => this.pickUploadDocumentUris(),
    stagingRoot: (): string => this.stagingRoot(),
    ensureStagingDirectory: (root: string): void => { fileIo.mkdirSync(root, true); },
    authenticateFolderAccess: (): Promise<boolean> => {
      const title: string = this.context().resourceManager.getStringSync(
        $r('app.string.security_folder_authentication_title').id
      );
      return AppSecurityAuthenticator.authenticate(title);
    },
    authenticateFolderPolicy: (): Promise<boolean> => {
      const title: string = this.context().resourceManager.getStringSync(
        $r('app.string.security_settings_authentication_title').id
      );
      return AppSecurityAuthenticator.authenticate(title);
    },
    saveLockedFolderPaths: (paths: string[]): Promise<void> =>
      AppSecurityPreferences.saveLockedFolderPaths(this.context(), paths),
    recordSecurityDiagnostic: (event: string, phase: string, code: number = 0): void => {
      this.recordSecurityDiagnostic(event, phase, code);
    },
    logTargetOpen: (route: string, durationMs: number): void => {
      hilog.info(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG,
        'target open completed. route=%{public}s durationMs=%{public}s',
        route, durationMs.toString());
    },
    publishTransferCompletion: (fileName: string, success: boolean): Promise<void> =>
      publishTaildriveCompletion(this.context(), fileName, success),
    clearTransferProgress: (): Promise<void> => clearTaildriveProgress(),
    retryDownload: (entry: TaildriveEntry): Promise<void> => this.download(entry),
    retryPreviewDownload: (entry: TaildriveEntry): Promise<void> => this.downloadForPreview(entry),

    gatewayList: (path: string): Promise<TaildriveListResult> => this.gateway.list(path),
    gatewayStat: (path: string): Promise<TaildriveStatResult> => this.gateway.stat(path),
    gatewayMutate: (request: TaildriveMutationRequest): Promise<TaildriveMutationResult> =>
      this.gateway.mutate(request),
    gatewayUpload: (request: TaildriveTransferRequest): Promise<TaildriveTransferSnapshot> =>
      this.gateway.upload(request),
    gatewayStageUpload: (uri: string, root: string, requestId: number): Promise<PreparedTaildriveFile> =>
      this.gateway.stageUpload(uri, root, requestId),
    gatewayCleanupStaged: (file: PreparedTaildriveFile): void => {
      this.gateway.cleanupStaged(file);
    }
  };
  private readonly sessionController: TaildriveSessionController =
    new TaildriveSessionController(this.sessionHost);

  aboutToAppear(): void {
    const session: TaildriveSessionController = this.sessionController;
    this.browserVisible = true;
    this.appInForeground = true;
    session.refreshGeneration++;
    try {
      this.gateway.configure(this.context());
      this.gateway.cleanupStaleStaging(this.stagingRoot());
    } catch (_error) {
      // Missing scope metadata must never expose another server's staging.
    }
    this.context().eventHub.on(APP_FOREGROUND_EVENT, this.appForegroundListener);
    this.context().eventHub.on(APP_BACKGROUND_EVENT, this.appBackgroundListener);
    this.thumbnails = [];
    this.updateBackState();
    if (!this.connected) {
      return;
    }
    if (this.targetRequestId > 0 && this.targetMachineName.length > 0) {
      session.requestTargetMachineOpen();
    } else if (this.filesTabActive) {
      session.refresh();
    }
    if (this.filesTabActive) {
      this.startRefreshPolling();
    }
  }

  aboutToDisappear(): void {
    const session: TaildriveSessionController = this.sessionController;
    this.fileActionGeneration++;
    this.browserVisible = false;
    this.thumbnailPool.cancel();
    session.refreshGeneration++;
    session.refreshPending = false;
    this.pullRefreshing = false;
    this.context().eventHub.off(APP_FOREGROUND_EVENT, this.appForegroundListener);
    this.context().eventHub.off(APP_BACKGROUND_EVENT, this.appBackgroundListener);
    this.clearSecurityResumeTimer();
    this.folderAccessGrants = [];
    session.protectedFolderResumePending = false;
    this.cancelPreviewDownload();
    this.finishDragSelection();
    this.stopTransferPolling();
    this.stopRefreshPolling();
    this.clearStatusTimer();
    this.clearUiTimers();
    clearTaildriveProgress();
    AppStorage.setOrCreate('taildriveUiBackActive', false);
  }

  private onConnectedChanged(): void {
    this.sessionController.onConnectedChanged();
  }

  private onTargetRequestChanged(): void {
    this.sessionController.onTargetRequestChanged();
  }

  private onFilesTabActiveChanged(): void {
    this.sessionController.onFilesTabActiveChanged();
  }

  private onFolderLockEnabledChanged(): void {
    this.sessionController.onFolderLockEnabledChanged();
  }

  private onLockedFolderPathsChanged(): void {
    this.sessionController.onLockedFolderPathsChanged();
  }

  private onAppLockActiveChanged(): void {
    this.sessionController.onAppLockActiveChanged();
  }

  private handleAppBackground(): void {
    this.sessionController.handleAppBackground();
  }

  private handleAppForeground(): void {
    this.sessionController.handleAppForeground();
  }

  private clearSecurityResumeTimer(): void {
    if (this.securityResumeTimer >= 0) {
      clearTimeout(this.securityResumeTimer);
      this.securityResumeTimer = -1;
    }
  }

  private onBackRequestChanged(): void {
    this.sessionController.onBackRequestChanged(this.backRequest);
  }

  private onSortSheetVisibilityChanged(): void {
    this.publishUiBackState();
  }

  private onPreviewDownloadVisibilityChanged(): void {
    this.publishUiBackState();
  }

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private vibrateTouch(strong: boolean = false): void {
    vibrator.startVibration({
      type: 'preset',
      effectId: strong ? vibrator.HapticFeedback.EFFECT_HARD : vibrator.HapticFeedback.EFFECT_SOFT
    }, { usage: 'touch' }).catch((): void => {});
  }

  private vibrateDragStep(): void {
    const now: number = Date.now();
    if (now - this.lastDragVibrateAtMs < 28) {
      return;
    }
    this.lastDragVibrateAtMs = now;
    vibrator.startVibration({
      type: 'preset',
      effectId: vibrator.HapticFeedback.EFFECT_SHARP
    }, { usage: 'touch' }).catch((): void => {
      this.vibrateTouch(false);
    });
  }

  private clearStatusTimer(): void {
    if (this.statusTimer >= 0) {
      clearTimeout(this.statusTimer);
      this.statusTimer = -1;
    }
  }

  private scheduleUiTimer(task: () => void, delayMs: number): number {
    if (typeof setTimeout !== 'function') {
      return -1;
    }
    let fired: boolean = false;
    let timer: number = -1;
    timer = setTimeout((): void => {
      fired = true;
      this.uiTimers = this.uiTimers.filter((entry: number) => entry !== timer);
      if (this.browserVisible) {
        task();
      }
    }, delayMs);
    if (!fired && timer >= 0) {
      this.uiTimers.push(timer);
    }
    return timer;
  }

  private clearUiTimers(): void {
    if (typeof clearTimeout === 'function') {
      this.uiTimers.forEach((timer: number) => clearTimeout(timer));
    }
    this.uiTimers = [];
  }

  private showTransientStatus(status: string): void {
    this.clearStatusTimer();
    this.status = status;
    this.statusTimer = setTimeout((): void => {
      if (this.status === status && !this.retryAvailable) {
        this.status = '';
      }
      this.statusTimer = -1;
    }, 5000);
  }

  private stagingRoot(): string {
    const context = this.context();
    const controlURL: string = ControlServerConfig.load(context.filesDir).controlURL;
    return `${AccountProfiles.cacheRoot(context.filesDir, context.cacheDir, controlURL,
      AccountProfiles.current(context.filesDir, controlURL).activeId)}/taildrive-staging`;
  }

  private applyListResult(result: TaildriveListResult, fallbackPath: string): void {
    this.path = result.path.length > 0 ? result.path : fallbackPath;
    this.entries = result.entries;
    this.lastListedPath = this.path;
    this.refreshThumbnails(result.entries);
    this.updateBackState();
    this.selectedPaths = this.selectedPaths.filter((path: string) =>
      result.entries.some((entry: TaildriveEntry) => entry.path === path));
    this.rebuildListDataSource();
    this.reason = '';
  }

  private async refresh(minimumIndicatorMs: number = 0, silent: boolean = false): Promise<void> {
    await this.sessionController.refresh(minimumIndicatorMs, silent);
  }

  private async pullRefresh(): Promise<void> {
    await this.sessionController.pullRefresh();
  }

  private async openEntry(entry: TaildriveEntry): Promise<void> {
    if (!this.connected) {
      return;
    }
    if (this.selectionMode) {
      if (this.dragSelecting || Date.now() < this.sessionController.dragSuppressClickUntilMs) {
        return;
      }
      this.toggleEntrySelection(entry);
      return;
    }
    if (entry.kind === 'directory') {
      if (this.busy) {
        return;
      }
      if (!await this.ensureFolderAccess(entry.path)) {
        return;
      }
      this.path = entry.path;
      this.updateBackState();
      this.searchQuery = '';
      this.searchVisible = false;
      this.exitSelectionMode();
      this.publishUiBackState();
      await this.refresh();
      return;
    }
    await this.openFileForPreview(entry);
  }

  private canShowSetupHelp(): boolean {
    return !this.busy && !this.previewDownloading && this.manualDownloadCount === 0 &&
      !this.appLockActive && !this.folderAccessAuthenticationInFlight && !this.folderPolicyAuthenticationInFlight &&
      !this.previewDownloadVisible && this.hasFolderAccess(this.path);
  }

  private showSetupHelp(section: string = 'taildrive'): void {
    if (this.canShowSetupHelp()) this.onShowFeatureGuide(section);
  }

  private setupHelpNotice(): string {
    const session: TaildriveSessionController = this.sessionController;
    return taildriveGuideNotice({ connected: this.connected,
      loading: this.loading || session.refreshInFlight || session.targetOpenInFlight,
      busy: !this.canShowSetupHelp(), locked: this.appLockActive, reason: this.reason,
      listFailure: session.retryKind === 'refresh' || session.retryKind === 'target',
      path: this.path, listedPath: this.lastListedPath,
      entryCount: this.entries.length, search: this.searchQuery });
  }

  @Builder
  private SetupHelpAction(title: ResourceStr, actionId: string, section: string = 'taildrive') {
    Button(title, { buttonStyle: ButtonStyleMode.TEXTUAL, controlSize: ControlSize.NORMAL })
      .fontSize(UiTokens.BODY_SIZE)
      .constraintSize({ minHeight: UiTokens.ACTION_HEIGHT }).id(actionId)
      .enabled(this.canShowSetupHelp())
      .onClick(() => this.showSetupHelp(section))
  }

  private isFolderDirectlyLocked(remotePath: string): boolean {
    return this.sessionController.isFolderDirectlyLocked(remotePath);
  }

  private hasFolderAccess(remotePath: string): boolean {
    return this.sessionController.hasFolderAccess(remotePath);
  }

  private isSheetBlockedBySecurity(targetPath: string = this.path): boolean {
    return this.sessionController.isSheetBlockedBySecurity(targetPath);
  }

  private isEditorSheetBlockedBySecurity(): boolean {
    return this.sessionController.isEditorSheetBlockedBySecurity();
  }

  private isMoveSheetBlockedBySecurity(): boolean {
    return this.sessionController.isMoveSheetBlockedBySecurity();
  }

  private async ensureFolderAccess(remotePath: string): Promise<boolean> {
    return await this.sessionController.ensureFolderAccess(remotePath);
  }

  private toggleFolderLock(entry: TaildriveEntry): void {
    this.sessionController.toggleFolderLock(entry);
  }

  private canChangeFolderLock(entry: TaildriveEntry): boolean {
    return this.sessionController.canChangeFolderLock(entry);
  }

  private recordSecurityDiagnostic(event: string, phase: string, code: number = 0): void {
    hilog.info(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_SECURITY_LOG_TAG,
      'event=%{public}s phase=%{public}s code=%{public}d', event, phase, code);
    try {
      DiagnosticEventStore.record(this.context().filesDir, 'ui', event, phase, code);
    } catch (_error) {
      // Security diagnostics are best-effort and never block folder access.
    }
  }

  private async openFileForPreview(entry: TaildriveEntry): Promise<void> {
    if (!await this.ensureFolderAccess(entry.path)) {
      return;
    }
    // A new preview supersedes an unfinished preview download. This does not
    // touch manual exports, which use a separate transfer channel.
    await this.cancelPreviewDownload();
    const cached: TaildriveCachedPreview | undefined =
      this.previewGateway.cachedPreview(this.context(), entry);
    hilog.info(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG,
      'open requested. cached=%{public}s size=%{public}d',
      cached === undefined ? 'false' : 'true', entry.size);
    if (cached !== undefined) {
      if (cached.thumbnailPath.length > 0) {
        this.setThumbnail(entry, cached.thumbnailPath);
      }
      // The external preview ability may keep its Promise pending until it
      // exits. It must not keep this file-row action pending either.
      this.openSystemPreview(entry, cached.path).catch(() => {});
      return;
    }
    if (entry.size >= 0 && entry.size < TAILDRIVE_AUTO_PREVIEW_LIMIT_BYTES) {
      await this.downloadForPreview(entry, true);
      return;
    }
    this.promptPreviewDownload(entry);
  }

  private promptPreviewDownload(entry: TaildriveEntry): void {
    this.previewDownloadEntry = entry;
    this.previewDownloadVisible = true;
  }

  private confirmPreviewDownload(): void {
    const entry: TaildriveEntry = this.previewDownloadEntry;
    this.previewDownloadVisible = false;
    this.downloadForPreview(entry, true);
  }

  private async downloadForPreview(entry: TaildriveEntry,
    openAfterDownload: boolean = true): Promise<void> {
    if (!this.connected) {
      hilog.warn(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG, 'download skipped before cleanup: disconnected');
      return;
    }
    if (!await this.ensureFolderAccess(entry.path)) {
      return;
    }
    hilog.info(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG, 'download cleanup started');
    await this.cancelPreviewDownload();
    hilog.info(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG, 'download cleanup returned');
    if (!this.connected) {
      hilog.warn(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG, 'download skipped after cleanup: disconnected');
      return;
    }
    const generation: number = ++this.previewGeneration;
    const requestId: number = this.newTransferRequestId();
    this.activePreviewPath = entry.path;
    this.cachedEntries = this.cachedEntries.filter((candidate: TaildriveEntry) => candidate.path !== entry.path);
    let root: string = '';
    let localPath: string = '';
    try {
      hilog.info(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG, 'download destination preparation started');
      root = this.previewGateway.root(this.context());
      localPath = this.previewGateway.prepareDownload(this.context(), entry);
      hilog.info(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG, 'download destination preparation completed');
    } catch (_error) {
      hilog.error(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG, 'download destination preparation failed');
      this.activePreviewPath = '';
      this.status = 'preview_download_failed';
      this.retryPreviewEntry = entry;
      this.setRetry('preview');
      return;
    }
    this.previewRequestId = requestId;
    this.previewDownloading = true;
    this.status = 'preview_downloading';
    this.clearRetry();
    this.startTransferPolling();
    hilog.info(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG,
      'download requested. requestId=%{public}s', requestId.toString());
    let downloadCompleted: boolean = false;
    try {
      const result: TaildriveTransferSnapshot = await this.gateway.download({
        requestId: requestId,
        remotePath: entry.path,
        localRoot: root,
        localPath: localPath
      });
      if (generation !== this.previewGeneration) {
        return;
      }
      this.transfer = result;
      hilog.info(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG,
        'download response. requestId=%{public}s state=%{public}s reason=%{public}s',
        requestId.toString(), result.state, result.reason);
      if (result.state !== 'completed') {
        this.status = result.reason.length > 0 ? result.reason : 'preview_download_failed';
        this.retryPreviewEntry = entry;
        this.setRetry('preview');
        return;
      }
      downloadCompleted = true;
    } catch (_error) {
      hilog.error(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG,
        'download threw. requestId=%{public}s', requestId.toString());
      if (generation === this.previewGeneration) {
        this.status = 'preview_download_failed';
        this.retryPreviewEntry = entry;
        this.setRetry('preview');
      }
    } finally {
      if (generation === this.previewGeneration) {
        this.previewRequestId = 0;
        this.previewDownloading = false;
        this.activePreviewPath = '';
        this.stopTransferPolling();
        clearTaildriveProgress().catch(() => {});
      }
    }

    if (generation !== this.previewGeneration) {
      return;
    }
    if (!downloadCompleted) {
      publishTaildriveCompletion(this.context(), entry.name, false).catch(() => {});
      return;
    }

    this.showTransientStatus('preview_download_completed');
    this.markCachedEntry(entry);
    this.refreshThumbnails(this.entries);
    publishTaildriveCompletion(this.context(), entry.name, true).catch(() => {});

    if (openAfterDownload) {
      // Do not await the external preview ability. Some system previewers keep
      // startAbility pending until the preview page returns.
      this.openSystemPreview(entry, localPath).catch(() => {});
    }
  }

  private newTransferRequestId(): number {
    this.nextTransferRequestId++;
    return this.nextTransferRequestId;
  }

  /**
   * Cancels only the active preview transfer. Manual exports use a separate
   * native request channel and are intentionally left running.
   */
  private async cancelPreviewDownload(): Promise<void> {
    if (this.previewRequestId <= 0) {
      return;
    }
    this.previewGeneration++;
    this.previewRequestId = 0;
    this.previewDownloading = false;
    this.activePreviewPath = '';
    this.stopTransferPolling();
    if (this.status === 'preview_downloading' || this.status === 'share_downloading') {
      this.status = '';
    }
    if (this.sessionController.retryKind === 'preview') {
      this.clearRetry();
    }
    clearTaildriveProgress().catch(() => {});
    // Cancellation shares the control channel with progress snapshots. Never
    // hold a later file click behind an old or slow control response.
    this.gateway.cancel().catch(() => {
      // The transfer may already have completed while the cancel request was queued.
    });
  }

  private async openSystemPreview(entry: TaildriveEntry, localPath: string): Promise<void> {
    const uri: string = fileUri.getUriFromPath(localPath);
    const type: string = this.contentTypeForEntry(entry);
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: uri,
      type: type,
      flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
    };
    try {
      hilog.info(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG, 'system preview startAbility requested');
      await this.context().startAbility(want);
      hilog.info(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG, 'system preview startAbility returned');
      return;
    } catch (_error) {
      hilog.warn(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG, 'system preview startAbility failed');
      // Some releases do not route file URIs through startAbility. Keep the
      // browser handoff as a compatibility fallback after the authorized path.
    }
    try {
      await this.context().openLink(uri, { appLinkingOnly: false });
      hilog.info(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG, 'system preview openLink returned');
    } catch (_error) {
      hilog.error(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG, 'system preview openLink failed');
      this.status = 'preview_failed';
    }
  }

  private goUp(): void {
    this.sessionController.goUp();
  }

  private async pickUploadDocumentUris(): Promise<string[]> {
    const documentPicker = new picker.DocumentViewPicker(this.context());
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    return await documentPicker.select(options);
  }

  private showConfirmationPrompt(prompt: TaildriveConfirmationPrompt): void {
    const isDelete: boolean = prompt.kind === 'delete_single' || prompt.kind === 'delete_selected';
    const title: Resource = isDelete ?
      $r('app.string.taildrive_delete_title') : $r('app.string.taildrive_overwrite_title');
    const message: ResourceStr = prompt.kind === 'delete_selected' ?
      $r('app.string.taildrive_delete_selected_message', prompt.selectedCount) : prompt.itemName;
    const confirmLabel: Resource = isDelete ?
      $r('app.string.taildrive_delete_action') : $r('app.string.taildrive_replace_action');
    this.getUIContext().showAlertDialog({
      title: title,
      message: message,
      autoCancel: prompt.autoCancel,
      cancel: () => { prompt.onDismiss(); },
      onDidDisappear: () => { prompt.onDismiss(); },
      primaryButton: {
        value: $r('app.string.cancel_action'),
        action: () => { prompt.onCancel(); }
      },
      secondaryButton: {
        value: confirmLabel,
        fontColor: $r('app.color.status_error'),
        action: () => { prompt.onConfirm(); }
      }
    });
  }

  private async selectUpload(): Promise<void> {
    await this.sessionController.selectUpload();
  }

  private async download(entry: TaildriveEntry): Promise<void> {
    if (!this.connected || entry.kind !== 'file' || this.manualDownloadInFlight || this.manualDownloadCount > 0) {
      return;
    }
    this.manualDownloadInFlight = true;
    let requestDir: string = '';
    let countIncremented: boolean = false;
    try {
      if (!await this.ensureFolderAccess(entry.path)) {
        return;
      }
      const requestId: number = this.newTransferRequestId();
      const root: string = this.stagingRoot();
      requestDir = `${root}/${requestId}`;
      const localPath: string = `${requestDir}/download.taildrive`;
      this.manualDownloadCount++;
      countIncremented = true;
      this.status = 'downloading';
      this.clearRetry();
      fileIo.mkdirSync(root, true);
      fileIo.mkdirSync(requestDir, true);
      const result: TaildriveTransferSnapshot = await this.gateway.download({
        requestId: requestId,
        remotePath: entry.path,
        localRoot: root,
        localPath: localPath
      }, true);
      if (result.state !== 'completed') {
        this.status = result.reason.length > 0 ? result.reason : 'download_failed';
        this.retryDownloadEntry = entry;
        this.setRetry('download');
        await publishTaildriveCompletion(this.context(), entry.name, false);
        return;
      }
      const documentPicker = new picker.DocumentViewPicker(this.context());
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [this.safeLocalName(entry.name)];
      const destinations: string[] = await documentPicker.save(options);
      if (destinations.length === 0) {
        this.status = 'export_cancelled';
        return;
      }
      const exported: boolean = await this.gateway.exportFile(localPath, destinations[0], result.bytes);
      if (exported) {
        this.markDownloadedEntry(entry);
        this.showTransientStatus('download_completed');
      } else {
        this.status = 'export_failed';
      }
      if (exported) {
        await publishTaildriveCompletion(this.context(), entry.name, true);
      } else {
        this.retryDownloadEntry = entry;
        this.setRetry('download');
        await publishTaildriveCompletion(this.context(), entry.name, false);
      }
    } catch (_error) {
      if (countIncremented) {
        this.status = 'download_failed';
        this.retryDownloadEntry = entry;
        this.setRetry('download');
        await publishTaildriveCompletion(this.context(), entry.name, false);
      } else {
        this.status = 'folder_authentication_failed';
      }
    } finally {
      if (requestDir.length > 0) {
        this.cleanupDirectory(requestDir);
      }
      if (countIncremented) {
        this.manualDownloadCount = Math.max(0, this.manualDownloadCount - 1);
      }
      this.manualDownloadInFlight = false;
    }
  }

  private createFolder(): void {
    this.sessionController.createFolder();
  }

  private localizedNewFolderName(): string {
    try {
      return this.context().resourceManager.getStringSync($r('app.string.taildrive_new_folder_default_name').id);
    } catch (_error) {
      return 'New folder';
    }
  }

  private closeFolderDialog(): void {
    this.sessionController.closeFolderDialog();
  }

  private async submitFolderDialog(): Promise<void> {
    await this.sessionController.submitFolderDialog();
  }

  private folderDialogContextCurrent(): boolean {
    return this.sessionController.folderDialogContextCurrent();
  }

  private renameEntry(entry: TaildriveEntry): void {
    this.sessionController.renameEntry(entry);
  }

  private confirmDelete(entry: TaildriveEntry): void {
    this.sessionController.confirmDelete(entry);
  }

  private confirmDeleteSelected(): void {
    this.sessionController.confirmDeleteSelected();
  }

  private async submitEditor(): Promise<void> {
    await this.sessionController.submitEditor();
  }

  private editorContextCurrent(): boolean {
    return this.sessionController.editorContextCurrent();
  }

  private snapshotFileEntry(entry: TaildriveEntry): TaildriveEntry {
    return snapshotTaildriveEntry(entry);
  }

  private async showDetails(entry: TaildriveEntry): Promise<void> {
    await this.sessionController.showDetails(entry);
  }

  private detailsContextCurrent(): boolean {
    return this.sessionController.detailsContextCurrent();
  }

  private closeDetails(): void {
    this.sessionController.closeDetails();
  }

  private takeDetailEntry(): TaildriveEntry | undefined {
    return this.sessionController.takeDetailEntry();
  }

  private async openMovePicker(entry: TaildriveEntry): Promise<void> {
    await this.sessionController.openMovePicker(entry);
  }

  private async openDestinationPickerForEntries(entries: TaildriveEntry[], operation: string): Promise<void> {
    await this.sessionController.openDestinationPickerForEntries(entries, operation);
  }

  private async openCopySelectedPicker(): Promise<void> {
    await this.sessionController.openCopySelectedPicker();
  }

  private async openMoveSelectedPicker(): Promise<void> {
    await this.sessionController.openMoveSelectedPicker();
  }

  private async loadMoveDirectory(): Promise<void> {
    await this.sessionController.loadMoveDirectory();
  }

  private moveContextCurrent(): boolean {
    return this.sessionController.moveContextCurrent();
  }

  private closeMovePicker(): void {
    this.sessionController.closeMovePicker();
  }

  private moveGoUp(): void {
    this.sessionController.moveGoUp();
  }

  private openMoveDirectory(entry: TaildriveEntry): void {
    this.sessionController.openMoveDirectory(entry);
  }

  private moveDestinationEntries(): TaildriveEntry[] {
    return this.sessionController.moveDestinationEntries();
  }

  private async confirmMove(): Promise<void> {
    await this.sessionController.confirmMove();
  }

  private async retryLastOperation(): Promise<void> {
    await this.sessionController.retryLastOperation();
  }

  private setRetry(kind: string): void {
    this.sessionController.setRetry(kind, this.retryDownloadEntry, this.retryPreviewEntry);
  }

  private clearRetry(): void {
    this.retryPreviewEntry = undefined;
    this.sessionController.clearRetry();
  }

  private startTransferPolling(): void {
    this.stopTransferPolling();
    this.lastNotifiedProgress = -1;
    this.transferTimer = setInterval(() => {
      if (this.transferPollInFlight) {
        return;
      }
      this.transferPollInFlight = true;
      this.gateway.transferSnapshot().then((snapshot: TaildriveTransferSnapshot) => {
        this.transfer = snapshot;
        const progress: number = snapshot.totalBytes > 0 ?
          Math.floor(snapshot.bytes * 100 / snapshot.totalBytes) : 0;
        if ((snapshot.state === 'queued' || snapshot.state === 'transferring') &&
          (this.lastNotifiedProgress < 0 || progress >= this.lastNotifiedProgress + 5)) {
          this.lastNotifiedProgress = progress;
          const notificationTransfer: TaildriveNotificationTransfer = {
            direction: snapshot.direction,
            fileName: snapshot.fileName,
            bytes: snapshot.bytes,
            totalBytes: snapshot.totalBytes
          };
          publishTaildriveProgress(this.context(), notificationTransfer);
        }
      }).catch(() => {}).finally(() => {
        this.transferPollInFlight = false;
      });
    }, 400);
  }

  private stopTransferPolling(): void {
    if (this.transferTimer >= 0) {
      clearInterval(this.transferTimer);
      this.transferTimer = -1;
    }
  }

  private cancelVisibleTransfer(): void {
    if (this.previewDownloading) {
      this.cancelPreviewDownload();
      return;
    }
    this.gateway.cancel().catch(() => {});
  }

  private refreshThumbnails(entries: TaildriveEntry[]): void {
    this.thumbnails = [];
    this.cachedEntries = [];
    const requestPath: string = this.path;
    const context: common.UIAbilityContext = this.context();
    this.thumbnailPool.replace(entries, async (entry: TaildriveEntry,
      isCurrent: () => boolean): Promise<void> => {
      const canApply: () => boolean = () => isCurrent() && this.appInForeground && this.browserVisible && this.connected &&
        !this.appLockActive && (!this.standalone || this.filesTabActive) && this.path === requestPath &&
        this.hasFolderAccess(requestPath) && entry.path !== this.activePreviewPath;
      if (entry.kind !== 'file' || !canApply()) return;
      const cached: TaildriveCachedPreview | undefined = await this.previewGateway.cachedPreviewAsync(context, entry);
      if (cached === undefined || !canApply()) return;
      this.cachedEntries = [...this.cachedEntries, localTaildriveFileSnapshot(entry)];
      const thumbnailPath: string = cached.thumbnailPath.length > 0 ? cached.thumbnailPath :
        await this.previewGateway.createThumbnail(context, entry, cached.path);
      if (thumbnailPath.length > 0 && canApply()) this.setThumbnail(entry, thumbnailPath);
    });
  }

  private localFileStatus(entry: TaildriveEntry): string {
    return this.sessionController.localFileStatus(entry);
  }

  private markCachedEntry(entry: TaildriveEntry): void {
    this.sessionController.markCachedEntry(entry);
  }

  private markDownloadedEntry(entry: TaildriveEntry): void {
    this.sessionController.markDownloadedEntry(entry);
  }

  private thumbnailUri(entry: TaildriveEntry): string {
    const thumbnail: TaildriveThumbnailModel | undefined = this.thumbnails.find(
      (candidate: TaildriveThumbnailModel) => candidate.remotePath === entry.path);
    if (thumbnail === undefined || thumbnail.uri.length === 0) {
      return '';
    }
    try {
      return fileUri.getUriFromPath(thumbnail.uri);
    } catch (_error) {
      return '';
    }
  }

  private setThumbnail(entry: TaildriveEntry, thumbnailPath: string): void {
    const nextThumbnail: TaildriveThumbnailModel = { remotePath: entry.path, uri: thumbnailPath };
    this.thumbnails = [
      ...this.thumbnails.filter((candidate: TaildriveThumbnailModel) =>
        candidate.remotePath !== entry.path),
      nextThumbnail
    ];
  }

  private onPathChanged(): void {
    this.sessionController.onPathChanged();
  }

  private previewTypeText(entry: TaildriveEntry): string {
    const contentType: string = (entry.contentType ?? '').trim();
    if (contentType.length > 0) {
      return contentType;
    }
    const extension: string = this.fileExtension(entry.name);
    return extension.length > 0 ? extension.toUpperCase() : 'FILE';
  }

  private contentTypeForEntry(entry: TaildriveEntry): string {
    if ((entry.contentType ?? '').length > 0) {
      return entry.contentType as string;
    }
    const extension: string = this.fileExtension(entry.name);
    switch (extension) {
      case 'jpg':
      case 'jpeg': return 'image/jpeg';
      case 'png': return 'image/png';
      case 'gif': return 'image/gif';
      case 'webp': return 'image/webp';
      case 'bmp': return 'image/bmp';
      case 'heic': return 'image/heic';
      case 'heif': return 'image/heif';
      case 'mp4':
      case 'm4v': return 'video/mp4';
      case 'mkv': return 'video/x-matroska';
      case 'mov': return 'video/quicktime';
      case 'avi': return 'video/x-msvideo';
      case 'webm': return 'video/webm';
      case 'pdf': return 'application/pdf';
      case 'txt': return 'text/plain';
      case 'json': return 'application/json';
      case 'zip': return 'application/zip';
      default: return 'application/octet-stream';
    }
  }

  private displayEntries(): TaildriveEntry[] {
    return this.sessionController.displayEntries();
  }

  private hiddenSelectedCount(): number {
    return this.sessionController.hiddenSelectedCount();
  }

  private chooseSortMode(mode: string): void {
    if (this.sortDraftMode !== mode) {
      this.sortDraftMode = mode;
      this.sortDraftDescending = mode !== 'name';
    }
  }

  private chooseGroupMode(mode: string): void {
    this.groupDraftMode = mode;
  }

  private openSortPanel(): void {
    this.sortDraftMode = this.sortMode;
    this.sortDraftDescending = this.sortDescending;
    this.groupDraftMode = this.groupMode;
    this.sortSheetVisible = true;
    this.publishUiBackState();
  }

  private closeSortPanel(): void {
    this.sortSheetVisible = false;
    this.publishUiBackState();
  }

  private confirmSortPanel(): void {
    this.sortMode = this.sortDraftMode;
    this.sortDescending = this.sortDraftDescending;
    this.groupMode = this.groupDraftMode;
    this.rebuildListDataSource();
    this.closeSortPanel();
  }

  private cycleSortMode(): void {
    this.sortMode = this.sortMode === 'name' ? 'modified' : this.sortMode === 'modified' ? 'size' : 'name';
    this.sortDescending = this.sortMode !== 'name';
    this.rebuildListDataSource();
  }

  private sortModeText(): ResourceStr {
    if (this.sortMode === 'modified') return $r('app.string.taildrive_sort_modified');
    if (this.sortMode === 'size') return $r('app.string.taildrive_sort_size');
    return $r('app.string.taildrive_sort_name');
  }

  private groupedEntries(): TaildriveEntryGroup[] {
    return this.sessionController.groupedEntryBuckets().map((bucket: TaildriveGroupedBucket): TaildriveEntryGroup => {
      const group: TaildriveEntryGroup = {
        key: bucket.key,
        title: bucket.key === 'all' ? '' : this.groupTitle(bucket.key),
        entries: bucket.entries
      };
      return group;
    });
  }

  private listItems(): TaildriveListItemModel[] {
    const items: TaildriveListItemModel[] = [];
    this.groupedEntries().forEach((group: TaildriveEntryGroup) => {
      if (group.key !== 'all') {
        items.push({
          key: `header-${group.key}`,
          header: true,
          title: group.title,
          entry: emptyTaildriveEntry()
        });
      }
      group.entries.forEach((entry: TaildriveEntry) => items.push({
        key: entry.path,
        header: false,
        title: '',
        entry: entry
      }));
    });
    return items;
  }

  private rebuildListDataSource(): void {
    this.listDataSource.replaceAll(this.listItems());
  }

  private groupTitle(key: string): ResourceStr {
    switch (key) {
      case 'folder': return $r('app.string.taildrive_group_folders');
      case 'image': return $r('app.string.taildrive_group_images');
      case 'video': return $r('app.string.taildrive_group_videos');
      case 'document': return $r('app.string.taildrive_group_documents');
      case 'archive': return $r('app.string.taildrive_group_archives');
      case 'today': return $r('app.string.taildrive_group_today');
      case 'yesterday': return $r('app.string.taildrive_group_yesterday');
      case 'week': return $r('app.string.taildrive_group_this_week');
      case 'earlier': return $r('app.string.taildrive_group_earlier');
      case 'unknown': return $r('app.string.taildrive_group_unknown_date');
      default: return $r('app.string.taildrive_group_other');
    }
  }

  private toggleSelectionMode(): void {
    this.sessionController.toggleSelectionMode();
  }

  private exitSelectionMode(): void {
    this.sessionController.exitSelectionMode();
  }

  private toggleEntrySelection(entry: TaildriveEntry): void {
    this.sessionController.toggleEntrySelection(entry);
  }

  private resolveFlatEntryIndexForListIndex(listIndex: number): number {
    return this.sessionController.resolveFlatEntryIndexForListIndex(
      listIndex,
      this.listDataSource.totalCount(),
      (cursor: number): boolean => this.listDataSource.getData(cursor).header
    );
  }

  private beginDragSelectionAtIndex(flatIndex: number): boolean {
    return this.sessionController.beginDragSelectionAtIndex(flatIndex);
  }

  private updateDragSelectionToIndex(flatIndex: number): boolean {
    return this.sessionController.updateDragSelectionToIndex(flatIndex);
  }

  private stopDragAutoScroll(): void {
    if (this.dragAutoScrollTimer >= 0) {
      clearInterval(this.dragAutoScrollTimer);
      this.dragAutoScrollTimer = -1;
    }
    this.dragAutoScrollStepVp = 0;
  }

  private finishDragSelection(): void {
    this.sessionController.finishDragSelection();
  }

  private gestureLocalPoint(event: GestureEvent): number[] | undefined {
    const fingers: FingerInfo[] = event.fingerList;
    if (!Array.isArray(fingers) || fingers.length === 0) {
      return undefined;
    }
    for (let index: number = 0; index < fingers.length; index++) {
      const finger: FingerInfo | undefined = fingers[index];
      if (finger !== undefined && Number.isFinite(finger.localX) && Number.isFinite(finger.localY)) {
        return [finger.localX, finger.localY];
      }
    }
    return undefined;
  }

  private hitTestDragFlatIndex(localX: number, localY: number, allowGapProbe: boolean): number {
    const maxX: number = Math.max(12, (this.dragViewportWidth > 0 ? this.dragViewportWidth : 340) - 12);
    const maxY: number = Math.max(8, (this.dragViewportHeight > 0 ? this.dragViewportHeight : 600) - 8);
    const x: number = Math.min(maxX, Math.max(12, localX));
    const y: number = Math.min(maxY, Math.max(8, localY));
    try {
      const listIndex: number = this.contentScroller.getItemIndex(x, y);
      if (listIndex >= 0) {
        return this.resolveFlatEntryIndexForListIndex(listIndex);
      }
      if (allowGapProbe) {
        const probeIndex: number = this.contentScroller.getItemIndex(x, Math.max(8, y - 14));
        if (probeIndex >= 0) {
          return this.resolveFlatEntryIndexForListIndex(probeIndex);
        }
      }
    } catch (_error) {
      return -1;
    }
    return -1;
  }

  private startDragSelectionFromGesture(event: GestureEvent): void {
    const point: number[] | undefined = this.gestureLocalPoint(event);
    if (point === undefined) {
      return;
    }
    this.dragPointerLocalX = point[0];
    this.dragPointerLocalY = point[1];
    const flatIndex: number = this.hitTestDragFlatIndex(point[0], point[1], false);
    this.beginDragSelectionAtIndex(flatIndex);
  }

  private moveDragSelectionFromGesture(event: GestureEvent): void {
    if (!this.dragSelecting) {
      return;
    }
    const point: number[] | undefined = this.gestureLocalPoint(event);
    if (point === undefined) {
      return;
    }
    this.dragPointerLocalX = point[0];
    this.dragPointerLocalY = point[1];
    const flatIndex: number = this.hitTestDragFlatIndex(point[0], point[1], true);
    if (flatIndex >= 0) {
      this.updateDragSelectionToIndex(flatIndex);
    }
    this.updateDragAutoScroll(point[1]);
  }

  private updateDragAutoScroll(localY: number): void {
    const viewportH: number = this.dragViewportHeight > 0 ? this.dragViewportHeight : 600;
    const bottomLimit: number = Math.max(120, viewportH - this.fileToolbarHeight() - 72);
    let step: number = 0;
    if (localY < 64) {
      step = -Math.min(18, Math.max(4, Math.round((64 - localY) * 0.28)));
    } else if (localY > bottomLimit) {
      step = Math.min(18, Math.max(4, Math.round((localY - bottomLimit) * 0.28)));
    } else {
      this.stopDragAutoScroll();
      return;
    }
    this.dragAutoScrollStepVp = step;
    if (this.dragAutoScrollTimer < 0) {
      this.dragAutoScrollTimer = setInterval((): void => {
        if (!this.dragSelecting || !this.selectionMode) {
          this.stopDragAutoScroll();
          return;
        }
        try {
          this.contentScroller.scrollBy(0, this.dragAutoScrollStepVp);
        } catch (_error) {}
        const idx: number = this.hitTestDragFlatIndex(this.dragPointerLocalX, this.dragPointerLocalY, true);
        if (idx >= 0) {
          this.updateDragSelectionToIndex(idx);
        }
      }, 32);
    }
  }

  private selectedTotalBytes(): number {
    return this.sessionController.selectedTotalBytes();
  }

  private allVisibleEntriesSelected(): boolean {
    return this.sessionController.allVisibleEntriesSelected();
  }

  private toggleSelectAll(): void {
    this.sessionController.toggleSelectAll();
  }

  private selectFromContextMenu(entry: TaildriveEntry): void {
    this.sessionController.selectFromContextMenu(entry);
  }

  private isSelected(entry: TaildriveEntry): boolean {
    return this.sessionController.isSelected(entry);
  }

  private selectedEntries(): TaildriveEntry[] {
    return this.sessionController.selectedEntries();
  }

  private selectedEntry(): TaildriveEntry | undefined {
    return this.sessionController.selectedEntry();
  }

  private showSelectedDetails(): void {
    const entry: TaildriveEntry | undefined = this.selectedEntry();
    if (entry !== undefined) {
      this.showDetails(entry);
    }
  }

  private groupModeText(): ResourceStr {
    if (this.groupMode === 'type') return $r('app.string.taildrive_group_by_type');
    if (this.groupMode === 'date') return $r('app.string.taildrive_group_by_date');
    return $r('app.string.taildrive_group_none');
  }

  private canModifyCurrentPath(): boolean {
    return this.sessionController.canModifyCurrentPath();
  }

  private safeLocalName(name: string): string {
    return sanitizeTaildriveLocalName(name);
  }

  private cleanupDirectory(directory: string): void {
    try {
      if (!fileIo.accessSync(directory)) {
        return;
      }
      fileIo.listFileSync(directory).forEach((name: string) => {
        try { fileIo.unlinkSync(`${directory}/${name}`); } catch (_error) {}
      });
      fileIo.rmdirSync(directory);
    } catch (_error) {
      // Cache recovery removes stale request directories on the next visit.
    }
  }

  private formatSize(size: number): string {
    if (size < 1024) return `${size} B`;
    if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`;
    if (size < 1024 * 1024 * 1024) return `${(size / (1024 * 1024)).toFixed(1)} MB`;
    return `${(size / (1024 * 1024 * 1024)).toFixed(1)} GB`;
  }

  private formatModified(modifiedAtMs: number): string {
    if (modifiedAtMs <= 0) {
      return '-';
    }
    try {
      return new Date(modifiedAtMs).toLocaleString();
    } catch (_error) {
      return '-';
    }
  }

  private formatListDate(modifiedAtMs: number): string {
    if (modifiedAtMs <= 0) {
      return '';
    }
    const date: Date = new Date(modifiedAtMs);
    const month: string = `${date.getMonth() + 1}`.padStart(2, '0');
    const day: string = `${date.getDate()}`.padStart(2, '0');
    return `${date.getFullYear()}/${month}/${day}`;
  }

  private fileExtension(name: string): string {
    return extractFileExtension(name);
  }

  private remotePathDepth(remotePath: string): number {
    return taildrivePathDepth(remotePath);
  }

  private isWindowsDriveDirectory(entry: TaildriveEntry): boolean {
    const kind: string = entry.kind.trim().toLowerCase();
    const contentType: string = (entry.contentType ?? '').trim().toLowerCase();
    if (['drive', 'disk', 'volume', 'drive_root', 'disk_root', 'filesystem_root'].includes(kind) ||
      ['application/x-drive', 'application/x-disk', 'inode/drive', 'inode/volume',
        'inode/mount-point'].includes(contentType)) {
      return true;
    }
    return /^[A-Za-z]:[\\/]?$/.test(entry.name.trim());
  }

  private specialFolderKind(name: string): string {
    switch (name.trim().toLowerCase()) {
      case '桌面':
      case 'desktop': return 'desktop';
      case '下载':
      case 'download':
      case 'downloads': return 'download';
      case '文档':
      case '文稿':
      case 'document':
      case 'documents':
      case 'docs': return 'document';
      case '图片':
      case '照片':
      case 'picture':
      case 'pictures':
      case 'photo':
      case 'photos':
      case 'image':
      case 'images': return 'picture';
      case '音乐':
      case 'music':
      case 'audio': return 'music';
      case '视频':
      case '影片':
      case 'video':
      case 'videos':
      case 'movie':
      case 'movies': return 'video';
      default: return '';
    }
  }

  private directoryIcon(entry: TaildriveEntry): Resource {
    const depth: number = this.remotePathDepth(entry.path);
    if (depth === 1) {
      return $r('app.media.ic_user');
    }
    if (depth === 2) {
      return $r('app.media.ic_network');
    }
    if (depth >= 3) {
      if (this.isWindowsDriveDirectory(entry)) {
        return $r('app.media.ic_disk_filled');
      }
      switch (this.specialFolderKind(entry.name)) {
        case 'desktop': return $r('app.media.taildrive_folder_desktop');
        case 'download': return $r('app.media.taildrive_folder_download');
        case 'document': return $r('app.media.taildrive_folder_document');
        case 'picture': return $r('app.media.taildrive_folder_picture');
        case 'music': return $r('app.media.taildrive_folder_music');
        case 'video': return $r('app.media.taildrive_folder_video');
      }
    }
    return $r('app.media.taildrive_file_folder');
  }

  private fileIcon(entry: TaildriveEntry): Resource {
    if (entry.kind === 'directory') {
      return this.directoryIcon(entry);
    }
    return resolveFileIconResource(entry.name);
  }

  private directoryKindText(entry: TaildriveEntry): ResourceStr {
    const depth: number = this.remotePathDepth(entry.path);
    if (depth === 1) return $r('app.string.taildrive_type_tailnet');
    if (depth === 2) return $r('app.string.taildrive_type_device');
    if (depth === 3) return $r('app.string.taildrive_type_share');
    return $r('app.string.taildrive_type_folder');
  }

  private breadcrumbText(): string {
    const segments: string[] = this.displayPath().split('/').filter((segment: string) => segment.length > 0);
    if (segments.length === 0) {
      return 'Taildrive';
    }
    const visible: string[] = segments.length > 3 ? segments.slice(segments.length - 3) : segments;
    return `Taildrive  ›  ${visible.join('  ›  ')}`;
  }

  private sanitizeDisplayLabel(value: string): string {
    return this.sessionController.sanitizeDisplayLabel(value);
  }

  private breadcrumbSegments(): string[] {
    return this.sessionController.pathSegments(this.path);
  }

  private navigateToBreadcrumb(index: number): void {
    this.sessionController.navigateToBreadcrumb(index);
  }

  private onMovePathChanged(): void {
    this.scheduleUiTimer((): void => {
      this.movePathScroller.scrollEdge(Edge.End);
    }, 40);
  }

  private moveBreadcrumbSegments(): string[] {
    return this.sessionController.pathSegments(this.movePath);
  }

  private navigateToMoveBreadcrumb(index: number): void {
    this.sessionController.navigateToMoveBreadcrumb(index);
  }

  private displayPath(value: string = this.path): string {
    return this.sessionController.displayPath(value);
  }

  private updateBackState(): void {
    AppStorage.setOrCreate('taildriveCurrentPath', this.path);
    this.publishUiBackState();
    this.scheduleUiTimer((): void => {
      this.breadcrumbScroller.scrollEdge(Edge.End);
    }, 40);
  }

  private publishUiBackState(): void {
    AppStorage.setOrCreate('taildriveUiBackActive',
      this.selectionMode || this.searchVisible || this.sortSheetVisible || this.folderDialogVisible ||
      this.previewDownloadVisible);
  }

  private refreshWithFeedback(): void {
    if (this.busy || this.loading || this.appLockActive) {
      return;
    }
    this.vibrateTouch();
    this.refresh(450);
  }

  private setSearchVisible(visible: boolean): void {
    this.getUIContext().animateTo({
      duration: MotionTokens.NORMAL, curve: MotionTokens.curve()
    }, (): void => {
      this.searchVisible = visible;
      if (!visible) {
        this.searchQuery = '';
        this.rebuildListDataSource();
      }
      this.publishUiBackState();
    });
  }

  private updateSearchQuery(value: string): void {
    this.searchQuery = value;
    this.rebuildListDataSource();
  }

  private commitSearch(): void {
    this.searchQuery = this.searchQuery.trim();
    this.rebuildListDataSource();
    this.contentScroller.scrollEdge(Edge.Top);
  }

  private toggleViewMode(): void {
    this.getUIContext().animateTo({
      duration: MotionTokens.NORMAL, curve: MotionTokens.curve()
    }, (): void => {
      this.viewMode = this.viewMode === 'list' ? 'grid' : 'list';
    });
  }

  private transferProgress(): string {
    if (this.transfer.totalBytes <= 0) {
      return '';
    }
    const percent: number = Math.min(100, Math.floor(this.transfer.bytes * 100 / this.transfer.totalBytes));
    return `${percent}%`;
  }

  private statusText(): ResourceStr {
    return this.statusCodeText(this.hasListFailure() ? this.reason : this.status);
  }

  private hasListFailure(): boolean {
    return this.sessionController.hasListFailure();
  }

  private showRetainedListNotice(): boolean {
    return this.sessionController.showRetainedListNotice();
  }

  private statusCodeText(status: string): ResourceStr {
    switch (status) {
      case 'file_selection_failed': return $r('app.string.taildrive_status_select_failed');
      case 'preparing_upload': return $r('app.string.taildrive_status_preparing_upload');
      case 'authorizing_file_operation': return $r('app.string.taildrive_status_authorizing_operation');
      case 'list_failed': return $r('app.string.taildrive_list_failed');
      case 'uploading': return $r('app.string.taildrive_status_uploading');
      case 'upload_completed': return $r('app.string.taildrive_status_upload_completed');
      case 'upload_failed': return $r('app.string.taildrive_status_upload_failed');
      case 'downloading': return $r('app.string.taildrive_status_downloading');
      case 'preview_downloading': return $r('app.string.taildrive_status_preview_downloading');
      case 'preview_download_completed': return $r('app.string.taildrive_status_preview_download_completed');
      case 'preview_download_failed': return $r('app.string.taildrive_status_preview_download_failed');
      case 'preview_failed': return $r('app.string.taildrive_status_preview_failed');
      case 'paths_copied': return $r('app.string.taildrive_status_paths_copied');
      case 'copy_failed': return $r('app.string.taildrive_status_copy_failed');
      case 'copying': return $r('app.string.taildrive_status_copying');
      case 'copy_completed': return $r('app.string.taildrive_status_copy_completed');
      case 'share_downloading': return $r('app.string.taildrive_status_share_downloading');
      case 'share_download_failed': return $r('app.string.taildrive_status_share_download_failed');
      case 'share_failed': return $r('app.string.taildrive_status_share_failed');
      case 'select_one_for_details': return $r('app.string.taildrive_status_select_one_for_details');
      case 'export_cancelled': return $r('app.string.taildrive_status_export_cancelled');
      case 'download_completed': return $r('app.string.taildrive_status_download_completed');
      case 'export_failed': return $r('app.string.taildrive_status_export_failed');
      case 'deleting': return $r('app.string.taildrive_status_deleting');
      case 'delete_completed': return $r('app.string.taildrive_status_delete_completed');
      case 'delete_failed': return $r('app.string.taildrive_status_delete_failed');
      case 'creating_folder': return $r('app.string.taildrive_status_creating_folder');
      case 'renaming': return $r('app.string.taildrive_status_renaming');
      case 'moving': return $r('app.string.taildrive_status_moving');
      case 'move_completed': return $r('app.string.taildrive_status_move_completed');
      case 'mutation_completed': return $r('app.string.taildrive_status_mutation_completed');
      case 'mutation_failed': return $r('app.string.taildrive_status_mutation_failed');
      case 'invalid_name': return $r('app.string.taildrive_status_invalid_name');
      case 'same_location': return $r('app.string.taildrive_status_same_location');
      case 'target_not_found': return $r('app.string.taildrive_status_target_not_found');
      case 'folder_authentication_failed': return $r('app.string.security_authentication_failed');
      case 'security_settings_save_failed': return $r('app.string.security_settings_save_failed');
      case 'permission_denied': return $r('app.string.taildrive_status_permission_denied');
      case 'not_found': return $r('app.string.taildrive_status_not_found');
      case 'already_exists':
      case 'file_exists': return $r('app.string.taildrive_status_already_exists');
      case 'backend_unavailable': return $r('app.string.taildrive_status_backend_unavailable');
      case 'busy': return $r('app.string.taildrive_status_busy');
      case 'cancelled': return $r('app.string.taildrive_status_cancelled');
      case 'timeout': return $r('app.string.taildrive_status_timeout');
      case 'no_space': return $r('app.string.taildrive_status_no_space');
      case 'remote_unavailable': return $r('app.string.taildrive_status_remote_unavailable');
      case 'network_interrupted': return $r('app.string.taildrive_status_network_interrupted');
      case 'file_unavailable': return $r('app.string.taildrive_status_file_unavailable');
      case 'download_failed':
      case 'transfer_failed': return $r('app.string.taildrive_status_transfer_failed');
      default: return status;
    }
  }

  @Builder
  private FolderDialog() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 0 }) {
        Text($r('app.string.taildrive_new_folder_title'))
          .fontSize(UiTokens.TITLE_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 24, bottom: 18 })
        TextInput({ text: this.editorName, placeholder: $r('app.string.taildrive_name_placeholder') })
          .width('100%')
          .height(48)
          .fontSize(17)
          .selectAll(true)
          .defaultFocus(true)
          .enterKeyType(EnterKeyType.Done)
          .backgroundColor(Color.Transparent)
          .id('taildrive-folder-dialog-input')
          .enabled(!this.folderSubmitInFlight)
          .onChange((value: string) => this.editorName = value)
          .onSubmit(() => this.submitFolderDialog())
        if (!this.folderDialogContextCurrent()) {
          Text($r('app.string.taildrive_folder_context_changed'))
            .fontSize(13)
            .lineHeight(19)
            .fontColor($r('app.color.status_warning'))
            .width('100%')
            .padding({ bottom: 12 })
            .id('taildrive-folder-context-changed')
        }
        Divider()
          .color($r('sys.color.comp_divider'))
        Row() {
          Button($r('app.string.cancel_action'), {
            buttonStyle: ButtonStyleMode.TEXTUAL, controlSize: ControlSize.NORMAL
          })
            .fontSize(UiTokens.BODY_SIZE)
            .layoutWeight(1)
            .height(UiTokens.ACTION_HEIGHT)
            .onClick(() => this.closeFolderDialog())
          Divider()
            .vertical(true)
            .height(34)
            .color($r('sys.color.comp_divider'))
          Button($r('app.string.confirm_action'), {
            buttonStyle: ButtonStyleMode.TEXTUAL, controlSize: ControlSize.NORMAL
          })
            .fontSize(UiTokens.BODY_SIZE)
            .layoutWeight(1)
            .height(UiTokens.ACTION_HEIGHT)
            .id('taildrive-folder-dialog-confirm')
            .enabled(!this.folderSubmitInFlight && !this.busy && this.folderDialogContextCurrent())
            .onClick(() => this.submitFolderDialog())
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('90%')
      .padding({ left: 24, right: 24 })
      .backgroundColor($r('sys.color.comp_background_primary'))
      .borderRadius(28)
      .shadow({ radius: 28, color: $r('app.color.shadow_elevated_soft'), offsetY: 8 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.scrim_modal_overlay'))
    .id('taildrive-folder-dialog')
    .transition(TransitionEffect.OPACITY.animation({
      duration: MotionTokens.duration(180), curve: MotionTokens.curve()
    }))
  }

  @Builder
  private SheetSecurityShield() {
    Column() {}
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.background_secondary'))
      .id('taildrive-sheet-security-shield')
  }

  @Builder
  private EditorSheet() {
    Stack() {
      Column({ space: UiTokens.GROUP_GAP }) {
        Text(this.editorOperation === 'mkdir' ? $r('app.string.taildrive_new_folder_title') :
          $r('app.string.taildrive_rename_title'))
          .fontSize(UiTokens.TITLE_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
        TextInput({ text: this.editorName, placeholder: $r('app.string.taildrive_name_placeholder') })
          .width('100%')
          .height(44)
          .enterKeyType(EnterKeyType.Done)
          .id('taildrive-editor-input')
          .enabled(!this.editorSubmitInFlight)
          .onChange((value: string) => this.editorName = value)
          .onSubmit(() => this.submitEditor())
        if (!this.editorContextCurrent()) {
          Text($r('app.string.taildrive_rename_context_changed'))
            .fontSize(13)
            .lineHeight(19)
            .fontColor($r('app.color.status_warning'))
            .width('100%')
            .id('taildrive-rename-context-changed')
        }
        Row({ space: UiTokens.GROUP_GAP }) {
          Button($r('app.string.cancel_action'), {
            buttonStyle: ButtonStyleMode.NORMAL, controlSize: ControlSize.NORMAL
          })
            .fontSize(UiTokens.BODY_SIZE)
            .fontColor($r('sys.color.font_primary'))
            .backgroundColor($r('sys.color.comp_background_primary'))
            .layoutWeight(1)
            .height(UiTokens.ACTION_HEIGHT)
            .onClick(() => this.editorVisible = false)
          Button($r('app.string.confirm_action'), {
            buttonStyle: ButtonStyleMode.EMPHASIZED, controlSize: ControlSize.NORMAL
          })
            .fontSize(UiTokens.BODY_SIZE)
            .layoutWeight(1)
            .height(UiTokens.ACTION_HEIGHT)
            .id('taildrive-editor-confirm')
            .enabled(!this.editorSubmitInFlight && !this.busy && this.editorContextCurrent())
            .onClick(() => this.submitEditor())
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: UiTokens.PAGE_PADDING, right: UiTokens.PAGE_PADDING, top: 16, bottom: 24 })
      if (this.isSheetBlockedBySecurity(this.sessionController.editorTargetPath()) ||
        this.isEditorSheetBlockedBySecurity()) {
        this.SheetSecurityShield()
      }
    }
    .width('100%')
    .height('100%')
  }

  private localStatusLabel(entry: TaildriveEntry): ResourceStr {
    const status: string = this.localFileStatus(entry);
    if (status === 'cached') {
      return $r('app.string.taildrive_cached_file');
    }
    if (status === 'downloaded') {
      return $r('app.string.taildrive_downloaded_file');
    }
    return '';
  }

  @Builder
  private DetailQuickAction($$: TaildriveDetailActionData) {
    Column() {
      Button({ type: ButtonType.ROUNDED_RECTANGLE, stateEffect: true }) {
        Column({ space: 6 }) {
          SymbolGlyph($$.icon)
            .fontSize(UiTokens.ICON_NAV_BAR)
            .fontColor([$$.destructive && $$.isEnabled ? $r('app.color.status_error') : $r('sys.color.icon_primary')])
          Text($$.label)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor($$.destructive && $$.isEnabled ? $r('app.color.status_error') : $r('sys.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
      .id($$.actionId)
      .width('100%')
      .height('100%')
      .padding({ left: 6, right: 6 })
      .borderRadius(14)
      .backgroundColor(Color.Transparent)
      .enabled($$.isEnabled)
      .onClick($$.action)
    }
    .layoutWeight(1)
    .height(60)
    .borderRadius(14)
    .backgroundColor($r('sys.color.comp_background_tertiary'))
  }

  @Builder
  private DetailsSheet() {
    Stack() {
      Scroll() {
        Column({ space: UiTokens.GROUP_GAP }) {
          if (!this.detailsContextCurrent()) {
            Column({ space: 8 }) {
              Text($r('app.string.taildrive_details_context_changed'))
                .fontSize(13)
                .lineHeight(19)
                .fontColor($r('app.color.status_warning'))
                .width('100%')
                .id('taildrive-details-context-changed')
            }
            .width('100%')
            .padding(UiTokens.CARD_PADDING)
            .backgroundColor($r('sys.color.comp_background_primary'))
            .borderRadius(UiTokens.CARD_RADIUS)
          } else if (this.detailsLoading) {
            Column({ space: 10 }) {
              LoadingProgress().width(28).height(28).id('taildrive-details-loading')
              Text($r('app.string.taildrive_loading'))
                .fontSize(13)
                .fontColor($r('sys.color.font_secondary'))
            }
            .width('100%')
            .padding({ top: 32, bottom: 32 })
            .alignItems(HorizontalAlign.Center)
          } else {
            Column({ space: 10 }) {
              Row({ space: 12 }) {
                this.EntryIcon(this.detailEntry, 48)
                Column({ space: 4 }) {
                  Text(this.sanitizeDisplayLabel(this.detailEntry.name))
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('sys.color.font_primary'))
                    .width('100%')
                    .wordBreak(WordBreak.BREAK_ALL)
                    .copyOption(CopyOptions.LocalDevice)
                    .id('taildrive-details-name')
                  Row({ space: 6 }) {
                    Text(this.detailEntry.kind === 'directory' ? this.directoryKindText(this.detailEntry) :
                      this.previewTypeText(this.detailEntry))
                      .fontSize(12)
                      .fontColor($r('sys.color.font_secondary'))
                      .maxLines(1)
                    if (this.detailEntry.kind === 'file') {
                      Text('·')
                        .fontSize(12)
                        .fontColor($r('sys.color.font_secondary'))
                      Text(this.formatSize(this.detailEntry.size))
                        .fontSize(12)
                        .fontColor($r('sys.color.font_secondary'))
                        .maxLines(1)
                    }
                  }
                  .width('100%')
                  if (this.localFileStatus(this.detailEntry).length > 0) {
                    Row({ space: 4 }) {
                      this.LocalFileStatus(this.detailEntry, 13)
                      Text(this.localStatusLabel(this.detailEntry))
                        .fontSize(11)
                        .fontColor($r('sys.color.font_secondary'))
                        .maxLines(1)
                    }
                    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                    .backgroundColor($r('sys.color.comp_background_tertiary'))
                    .borderRadius(10)
                  }
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              if (this.detailsReason.length > 0) {
                Text(this.statusCodeText(this.detailsReason))
                  .fontSize(12)
                  .fontColor($r('app.color.status_error'))
                  .width('100%')
                  .id('taildrive-details-error')
              }
            }
            .width('100%')
            .padding(UiTokens.CARD_PADDING)
            .backgroundColor($r('sys.color.comp_background_primary'))
            .borderRadius(UiTokens.CARD_RADIUS)

            Text($r('app.string.taildrive_details_quick_actions'))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
              .padding({ left: 4, top: 4 })
            Column({ space: 8 }) {
              Row({ space: 8 }) {
                if (this.detailEntry.kind === 'file') {
                  this.DetailQuickAction({
                    icon: $r('sys.symbol.download'),
                    label: $r('app.string.taildrive_download_action'),
                    isEnabled: !this.busy,
                    destructive: false,
                    actionId: 'taildrive-details-download',
                    action: () => {
                      const entry: TaildriveEntry | undefined = this.takeDetailEntry();
                      if (entry === undefined) return;
                      this.download(entry);
                    }
                  })
                  this.DetailQuickAction({
                    icon: $r('sys.symbol.share'),
                    label: $r('app.string.taildrive_share_action'),
                    isEnabled: !this.busy && !this.previewDownloading,
                    destructive: false,
                    actionId: 'taildrive-details-share',
                    action: () => {
                      const entry: TaildriveEntry | undefined = this.takeDetailEntry();
                      if (entry === undefined) return;
                      this.shareEntries([entry]);
                    }
                  })
                }
                this.DetailQuickAction({
                  icon: $r('sys.symbol.link'),
                  label: $r('app.string.taildrive_copy_path_action'),
                  isEnabled: true,
                  destructive: false,
                  actionId: 'taildrive-details-copy-path',
                  action: () => {
                    const entry: TaildriveEntry | undefined = this.takeDetailEntry();
                    if (entry === undefined) return;
                    this.copyEntryPath(entry);
                  }
                })
              }
              .width('100%')
              if (this.canModifyCurrentPath()) {
                Row({ space: 8 }) {
                  this.DetailQuickAction({
                    icon: $r('sys.symbol.doc_text_on_doc_text'),
                    label: $r('app.string.taildrive_copy_action'),
                    isEnabled: !this.busy,
                    destructive: false,
                    actionId: 'taildrive-details-copy',
                    action: () => {
                      const entry: TaildriveEntry | undefined = this.takeDetailEntry();
                      if (entry === undefined) return;
                      this.openDestinationPickerForEntries([entry], 'copy');
                    }
                  })
                  this.DetailQuickAction({
                    icon: $r('sys.symbol.arrow_right_folder_circle'),
                    label: $r('app.string.taildrive_move_action'),
                    isEnabled: !this.busy,
                    destructive: false,
                    actionId: 'taildrive-details-move',
                    action: () => {
                      const entry: TaildriveEntry | undefined = this.takeDetailEntry();
                      if (entry === undefined) return;
                      this.openMovePicker(entry);
                    }
                  })
                  this.DetailQuickAction({
                    icon: $r('sys.symbol.square_and_pencil'),
                    label: $r('app.string.taildrive_rename_action'),
                    isEnabled: !this.busy,
                    destructive: false,
                    actionId: 'taildrive-details-rename',
                    action: () => {
                      const entry: TaildriveEntry | undefined = this.takeDetailEntry();
                      if (entry === undefined) return;
                      this.renameEntry(entry);
                    }
                  })
                  this.DetailQuickAction({
                    icon: $r('sys.symbol.trash'),
                    label: $r('app.string.taildrive_delete_action'),
                    isEnabled: !this.busy,
                    destructive: true,
                    actionId: 'taildrive-details-delete',
                    action: () => {
                      const entry: TaildriveEntry | undefined = this.takeDetailEntry();
                      if (entry === undefined) return;
                      this.confirmDelete(entry);
                    }
                  })
                }
                .width('100%')
              }
            }
            .width('100%')
            .padding(10)
            .backgroundColor($r('sys.color.comp_background_primary'))
            .borderRadius(UiTokens.CARD_RADIUS)

            Text($r('app.string.taildrive_details_info_section'))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
              .padding({ left: 4, top: 4 })
            Column({ space: 0 }) {
              this.DetailRow($r('app.string.taildrive_details_type'),
                this.detailEntry.kind === 'directory' ? $r('app.string.taildrive_type_folder') :
                  $r('app.string.taildrive_type_file'))
              if (this.detailEntry.kind === 'file') {
                Divider()
                  .color($r('sys.color.comp_divider'))
                  .margin({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING })
                this.DetailRow($r('app.string.taildrive_details_size'), this.formatSize(this.detailEntry.size))
              }
              Divider()
                .color($r('sys.color.comp_divider'))
                .margin({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING })
              this.DetailRow($r('app.string.taildrive_details_modified'),
                this.formatModified(this.detailEntry.modifiedAtMs))
              Divider()
                .color($r('sys.color.comp_divider'))
                .margin({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING })
              this.DetailRow($r('app.string.taildrive_details_path'), this.displayPath(this.detailEntry.path))
              if (this.detailEntry.contentType !== undefined && this.detailEntry.contentType.length > 0) {
                Divider()
                  .color($r('sys.color.comp_divider'))
                  .margin({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING })
                this.DetailRow($r('app.string.taildrive_details_content_type'), this.detailEntry.contentType)
              }
              if (this.localFileStatus(this.detailEntry).length > 0) {
                Divider()
                  .color($r('sys.color.comp_divider'))
                  .margin({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING })
                this.DetailRow($r('app.string.taildrive_details_local_status'), this.localStatusLabel(this.detailEntry))
              }
            }
            .width('100%')
            .backgroundColor($r('sys.color.comp_background_primary'))
            .borderRadius(UiTokens.CARD_RADIUS)
          }
        }
        .width('100%')
        .padding({ left: UiTokens.PAGE_PADDING, right: UiTokens.PAGE_PADDING, top: 4, bottom: 24 })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.TopStart)
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)
      .nestedScroll({
        scrollForward: NestedScrollMode.SELF_FIRST,
        scrollBackward: NestedScrollMode.SELF_FIRST
      })
      .backgroundColor(LightAppearance.supports() ? Color.Transparent : $r('sys.color.background_secondary'))
      .id('taildrive-details-sheet')
      if (this.isSheetBlockedBySecurity(this.detailEntry.path.length > 0 ? this.detailEntry.path : this.path)) {
        this.SheetSecurityShield()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private PreviewDownloadSheet() {
    Stack() {
      Column({ space: 16 }) {
        Text($r('app.string.taildrive_preview_download_title'))
          .fontSize(UiTokens.TITLE_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
        Column({ space: 8 }) {
          Text(this.sanitizeDisplayLabel(this.previewDownloadEntry.name))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 8 }) {
            Text(this.previewTypeText(this.previewDownloadEntry))
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.formatSize(this.previewDownloadEntry.size))
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
          }
          .width('100%')
        }
        .width('100%')
        .padding(UiTokens.CARD_PADDING)
        .backgroundColor($r('app.color.surface_subtle'))
        .borderRadius(UiTokens.CARD_RADIUS)
        Text($r('app.string.taildrive_preview_download_hint'))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .lineHeight(20)
          .width('100%')
        Row({ space: 12 }) {
          Button($r('app.string.cancel_action'), {
            buttonStyle: ButtonStyleMode.NORMAL, controlSize: ControlSize.NORMAL
          })
            .fontSize(UiTokens.BODY_SIZE)
            .fontColor($r('sys.color.font_primary'))
            .backgroundColor($r('sys.color.comp_background_primary'))
            .layoutWeight(1)
            .height(UiTokens.ACTION_HEIGHT)
            .onClick(() => this.previewDownloadVisible = false)
          Button($r('app.string.taildrive_preview_download_action'), {
            buttonStyle: ButtonStyleMode.EMPHASIZED, controlSize: ControlSize.NORMAL
          })
            .fontSize(UiTokens.BODY_SIZE)
            .layoutWeight(1)
            .height(UiTokens.ACTION_HEIGHT)
            .id('taildrive-preview-download-confirm')
            .onClick(() => this.confirmPreviewDownload())
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: UiTokens.PAGE_PADDING, right: UiTokens.PAGE_PADDING, top: 16, bottom: 24 })
      .id('taildrive-preview-download-sheet')
      if (this.isSheetBlockedBySecurity(this.previewDownloadEntry.path.length > 0 ?
        this.previewDownloadEntry.path : this.path)) {
        this.SheetSecurityShield()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private DetailRow(label: ResourceStr, value: ResourceStr) {
    Row({ space: 12 }) {
      Text(label)
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
        .width(88)
      Text(value)
        .fontSize(13)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
        .textAlign(TextAlign.Start)
        .wordBreak(WordBreak.BREAK_ALL)
        .copyOption(CopyOptions.LocalDevice)
    }
    .width('100%')
    .padding({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING, top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  private MoveSheet() {
    Stack() {
      Column({ space: UiTokens.GROUP_GAP }) {
        Row({ space: 8 }) {
          if (this.movePath !== '/') {
            Column() {
              Button({ type: ButtonType.Circle, stateEffect: true }) {
                SymbolGlyph($r('sys.symbol.chevron_left'))
                  .fontSize(16)
                  .fontColor([$r('sys.color.icon_primary')])
              }
              .width(36)
              .height(36)
              .backgroundColor(Color.Transparent)
              .enabled(this.moveContextCurrent() && !this.busy && !this.moveLoading && !this.moveSubmitInFlight)
              .accessibilityText($r('app.string.taildrive_up_action'))
              .id('taildrive-move-up')
              .onClick(() => this.moveGoUp())
            }
            .width(36)
            .height(36)
            .borderRadius(18)
            .backgroundColor($r('sys.color.comp_background_primary'))
          }
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.folder'))
              .fontSize(15)
              .fontColor([$r('sys.color.icon_secondary')])
            Scroll(this.movePathScroller) {
              Row({ space: 4 }) {
                Text('Taildrive')
                  .fontSize(13)
                  .fontWeight(this.movePath === '/' ? FontWeight.Medium : FontWeight.Regular)
                  .fontColor(this.movePath === '/' ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
                  .maxLines(1)
                  .id('taildrive-move-breadcrumb-root')
                  .onClick(() => this.navigateToMoveBreadcrumb(-1))
                ForEach(this.moveBreadcrumbSegments(), (segment: string, index: number) => {
                  Text('›')
                    .fontSize(14)
                    .fontColor($r('sys.color.icon_secondary'))
                  Text(segment)
                    .fontSize(13)
                    .fontWeight(index === this.moveBreadcrumbSegments().length - 1 ? FontWeight.Medium : FontWeight.Regular)
                    .fontColor(index === this.moveBreadcrumbSegments().length - 1 ?
                      $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
                    .maxLines(1)
                    .id(`taildrive-move-breadcrumb-${index}`)
                    .onClick(() => this.navigateToMoveBreadcrumb(index))
                }, (segment: string, index: number) => `${index}-${segment}`)
              }
            }
            .layoutWeight(1)
            .align(Alignment.Start)
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.None)
            .id('taildrive-move-path')
            .onAppear((): void => {
              this.scheduleUiTimer((): void => {
                this.movePathScroller.scrollEdge(Edge.End);
              }, 40);
            })
          }
          .height(36)
          .layoutWeight(1)
          .padding({ left: 12, right: 12 })
          .alignItems(VerticalAlign.Center)
          .backgroundColor($r('sys.color.comp_background_primary'))
          .borderRadius(18)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        Scroll() {
          Column({ space: UiTokens.GROUP_GAP }) {
            if (this.moveContextCurrent() && !this.moveLoading && this.moveReason.length === 0 &&
              this.remotePathDepth(this.movePath) < 3) {
              Text($r('app.string.taildrive_move_select_share_hint'))
                .fontSize(12)
                .fontColor($r('sys.color.font_secondary'))
                .width('100%')
                .padding({ left: 4, right: 4 })
                .id('taildrive-move-share-hint')
            }
            if (!this.moveContextCurrent()) {
              Text($r('app.string.taildrive_move_context_changed'))
                .fontSize(13)
                .lineHeight(19)
                .fontColor($r('app.color.status_warning'))
                .width('100%')
                .padding(UiTokens.CARD_PADDING)
                .backgroundColor($r('sys.color.comp_background_primary'))
                .borderRadius(UiTokens.CARD_RADIUS)
                .id('taildrive-move-context-changed')
            } else if (this.moveLoading) {
              Column() {
                LoadingProgress().width(24).height(24).id('taildrive-move-loading')
              }
              .width('100%')
              .padding({ top: 24, bottom: 24 })
              .alignItems(HorizontalAlign.Center)
            } else if (this.moveReason.length > 0) {
              Column({ space: 8 }) {
                Text(this.statusCodeText(this.moveReason))
                  .fontSize(13)
                  .fontColor($r('app.color.status_warning'))
                  .width('100%')
                  .id('taildrive-move-error')
                Button($r('app.string.taildrive_refresh_action'), {
                  buttonStyle: ButtonStyleMode.TEXTUAL, controlSize: ControlSize.NORMAL
                })
                  .fontSize(UiTokens.BODY_SIZE)
                  .constraintSize({ minHeight: UiTokens.ACTION_HEIGHT })
                  .enabled(!this.moveSubmitInFlight && !this.busy)
                  .id('taildrive-move-retry')
                  .onClick(() => this.loadMoveDirectory())
              }
              .width('100%')
              .padding(UiTokens.CARD_PADDING)
              .backgroundColor($r('sys.color.comp_background_primary'))
              .borderRadius(UiTokens.CARD_RADIUS)
              .alignItems(HorizontalAlign.Start)
            } else if (this.moveDestinationEntries().length === 0) {
              Row() {
                Text($r('app.string.taildrive_move_no_subfolders'))
                  .fontSize(13)
                  .fontColor($r('sys.color.font_secondary'))
                  .width('100%')
                  .textAlign(TextAlign.Center)
              }
              .width('100%')
              .padding(UiTokens.CARD_PADDING)
              .backgroundColor($r('sys.color.comp_background_primary'))
              .borderRadius(12)
            } else {
              Column({ space: 8 }) {
                ForEach(this.moveDestinationEntries(), (entry: TaildriveEntry) => {
                  Row({ space: 8 }) {
                    this.EntryIcon(entry, 20)
                    Text(this.sanitizeDisplayLabel(entry.name))
                      .fontSize(14)
                      .fontColor($r('sys.color.font_primary'))
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    SymbolGlyph($r('sys.symbol.chevron_right'))
                      .fontSize(UiTokens.ICON_CHEVRON)
                      .fontColor([$r('sys.color.icon_secondary')])
                  }
                  .width('100%')
                  .padding(12)
                  .backgroundColor($r('sys.color.comp_background_primary'))
                  .borderRadius(12)
                  .constraintSize({ minHeight: 46 })
                  .enabled(!this.moveSubmitInFlight && !this.busy)
                  .id(`taildrive-move-entry-${entry.name}`)
                  .onClick(() => this.openMoveDirectory(entry))
                }, (entry: TaildriveEntry) => entry.path)
              }
              .width('100%')
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.TopStart)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .scrollBar(BarState.Off)
        .nestedScroll({
          scrollForward: NestedScrollMode.SELF_FIRST,
          scrollBackward: NestedScrollMode.SELF_FIRST
        })
        .id('taildrive-move-content-scroll')
        Row({ space: UiTokens.GROUP_GAP }) {
          Button($r('app.string.cancel_action'), {
            buttonStyle: ButtonStyleMode.NORMAL, controlSize: ControlSize.NORMAL
          })
            .fontSize(UiTokens.BODY_SIZE)
            .fontColor($r('sys.color.font_primary'))
            .backgroundColor($r('sys.color.comp_background_primary'))
            .layoutWeight(1)
            .height(UiTokens.ACTION_HEIGHT)
            .id('taildrive-move-cancel')
            .onClick(() => this.closeMovePicker())
          Button(this.moveOperation === 'copy' ? $r('app.string.taildrive_copy_here_action') :
            $r('app.string.taildrive_move_here_action'), {
            buttonStyle: ButtonStyleMode.EMPHASIZED, controlSize: ControlSize.NORMAL
          })
            .fontSize(UiTokens.BODY_SIZE)
            .layoutWeight(1)
            .height(UiTokens.ACTION_HEIGHT)
            .id('taildrive-move-confirm')
            .enabled(this.sessionController.canConfirmMove())
            .onClick(() => this.confirmMove())
        }
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .padding({ left: UiTokens.PAGE_PADDING, right: UiTokens.PAGE_PADDING, top: 4, bottom: 24 })
      .backgroundColor(LightAppearance.supports() ? Color.Transparent : $r('sys.color.background_secondary'))
      if (this.isSheetBlockedBySecurity(this.movePath) || this.isMoveSheetBlockedBySecurity()) {
        this.SheetSecurityShield()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private LegacyBrowserContent() {
    Column({ space: 10 }) {
      if (!this.standalone) {
        Row() {
          SymbolGlyph($r('sys.symbol.folder'))
            .fontSize(20)
            .fontColor([$r('app.color.emphasize')])
          Text($r('app.string.taildrive_title'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .margin({ left: 8 })
          Blank()
          Text($r('app.string.taildrive_refresh_action'))
            .fontSize(12)
            .fontColor($r('app.color.emphasize'))
            .opacity(this.loading || !this.connected ? 0.45 : 1)
            .id('taildrive-inline-refresh')
            .onClick(() => this.refresh())
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        Text($r('app.string.taildrive_subtitle'))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
      }
      if (!this.connected) {
        Text($r('app.string.taildrive_connect_first'))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .padding(14)
          .backgroundColor($r('app.color.surface_subtle'))
          .borderRadius(12)
      } else {
        Row({ space: 8 }) {
          Text($r('app.string.taildrive_up_action'))
            .fontSize(12)
            .fontColor(this.path === '/' || this.busy ? $r('sys.color.font_secondary') :
              $r('app.color.emphasize'))
            .onClick(() => this.goUp())
          Text(this.displayPath())
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .id('taildrive-legacy-path')
          if (this.standalone) {
            Text($r('app.string.taildrive_refresh_action'))
              .fontSize(12)
              .fontColor($r('app.color.emphasize'))
              .opacity(this.loading || this.busy ? 0.45 : 1)
              .id('taildrive-legacy-refresh')
              .onClick(() => this.refresh())
          }
          if (this.canModifyCurrentPath()) {
            Text($r('app.string.taildrive_new_folder_action'))
              .fontSize(12)
              .fontColor(this.busy ? $r('sys.color.font_secondary') : $r('app.color.emphasize'))
              .onClick(() => this.createFolder())
            Text($r('app.string.taildrive_upload_action'))
              .fontSize(12)
              .fontColor(this.busy ? $r('sys.color.font_secondary') : $r('app.color.emphasize'))
              .onClick(() => this.selectUpload())
          }
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
        Row({ space: 8 }) {
          TextInput({ text: this.searchQuery, placeholder: $r('app.string.taildrive_search_placeholder') })
            .height(36)
            .layoutWeight(1)
            .fontSize(12)
            .id('taildrive-legacy-search')
            .onChange((value: string) => this.searchQuery = value)
          Text(this.sortModeText())
            .fontSize(11)
            .fontColor($r('app.color.emphasize'))
            .padding({ left: 10, right: 10, top: 9, bottom: 9 })
            .backgroundColor($r('app.color.surface_subtle'))
            .borderRadius(10)
            .onClick(() => this.cycleSortMode())
        }
        .width('100%')
        if (this.loading) {
          LoadingProgress().width(24).height(24).margin({ top: 18, bottom: 18 })
        } else if (this.displayEntries().length === 0) {
          Text(this.reason.length > 0 ? this.statusCodeText(this.reason) : $r('app.string.taildrive_empty'))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 24, bottom: 24 })
            .id('taildrive-legacy-list-state')
        } else {
          ForEach(this.displayEntries(), (entry: TaildriveEntry) => {
            Column({ space: 7 }) {
              Row({ space: 8 }) {
                this.EntryIcon(entry, 18)
                Column({ space: 2 }) {
                  Text(this.sanitizeDisplayLabel(entry.name))
                    .fontSize(13)
                    .fontColor($r('sys.color.font_primary'))
                    .width('100%')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(entry.kind === 'file' ?
                    `${this.formatSize(entry.size)} · ${this.formatModified(entry.modifiedAtMs)}` :
                    this.formatModified(entry.modifiedAtMs))
                    .fontSize(10)
                    .fontColor($r('sys.color.font_secondary'))
                    .width('100%')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .layoutWeight(1)
              }
              .width('100%')
              .onClick(() => this.openEntry(entry))
              Row({ space: 14 }) {
                Text($r('app.string.taildrive_details_action'))
                  .fontSize(11)
                  .fontColor($r('app.color.emphasize'))
                  .onClick(() => this.showDetails(entry))
                if (entry.kind === 'file') {
                  Text($r('app.string.taildrive_download_action'))
                    .fontSize(11)
                    .fontColor($r('app.color.emphasize'))
                    .onClick(() => this.download(entry))
                }
                if (this.canModifyCurrentPath()) {
                  Text($r('app.string.taildrive_rename_action'))
                    .fontSize(11)
                    .fontColor(this.busy ? $r('sys.color.font_secondary') : $r('app.color.emphasize'))
                    .onClick(() => this.renameEntry(entry))
                  Text($r('app.string.taildrive_move_action'))
                    .fontSize(11)
                    .fontColor(this.busy ? $r('sys.color.font_secondary') : $r('app.color.emphasize'))
                    .onClick(() => this.openMovePicker(entry))
                  Text($r('app.string.taildrive_delete_action'))
                    .fontSize(11)
                    .fontColor(this.busy ? $r('sys.color.font_secondary') : $r('app.color.status_error'))
                    .onClick(() => this.confirmDelete(entry))
                }
              }
              .width('100%')
              .justifyContent(FlexAlign.End)
            }
            .width('100%')
            .padding({ left: 10, right: 10, top: 10, bottom: 9 })
            .backgroundColor($r('app.color.surface_subtle'))
            .borderRadius(10)
            .id(`taildrive-legacy-entry-${entry.name}`)
          }, (entry: TaildriveEntry) => entry.path)
        }
        if ((this.busy || this.previewDownloading) &&
          (this.transfer.state === 'queued' || this.transfer.state === 'transferring')) {
          Row({ space: 8 }) {
            LoadingProgress().width(16).height(16)
            Text(this.transfer.fileName.length > 0 ? this.transfer.fileName :
              $r('app.string.taildrive_transfer_in_progress'))
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .layoutWeight(1)
            Text(this.transferProgress())
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
            Text($r('app.string.cancel_action'))
              .fontSize(12)
              .fontColor($r('app.color.status_error'))
              .onClick(() => this.cancelVisibleTransfer())
          }
          .width('100%')
        }
      }
      if (this.status.length > 0 || this.retryAvailable) {
        Row({ space: 10 }) {
          if (this.status.length > 0 || this.hasListFailure()) {
            Text(this.statusText())
              .fontSize(11)
              .fontColor($r('sys.color.font_secondary'))
              .layoutWeight(1)
          } else {
            Blank().layoutWeight(1)
          }
          if (this.retryAvailable) {
            Text($r('app.string.taildrive_retry_action'))
              .fontSize(11)
              .fontColor($r('app.color.emphasize'))
              .height(44)
              .padding({ left: 12, right: 12 })
              .enabled(!this.loading && !this.busy && !this.appLockActive)
              .onClick(() => this.retryLastOperation())
          }
        }
        .width('100%')
        if (this.showRetainedListNotice()) {
          Text($r('app.string.taildrive_retained_list_notice'))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
        }
      }
    }
    .width('100%')
    .padding(this.standalone ? 0 : 14)
    .backgroundColor(this.standalone ? Color.Transparent : $r('app.color.surface_subtle'))
    .borderRadius(this.standalone ? 0 : 16)
    .id('taildrive-legacy-browser')
  }

  private startRefreshPolling(): void {
    this.stopRefreshPolling();
    if (!this.appInForeground || !this.browserVisible || !this.connected || this.appLockActive ||
      (this.standalone && !this.filesTabActive)) {
      return;
    }
    this.refreshTimer = setInterval(() => {
      if (!this.connected || this.loading || this.busy) {
        return;
      }
      this.refresh(0, true);
    }, TAILDRIVE_REFRESH_INTERVAL_MS);
  }

  private stopRefreshPolling(): void {
    if (this.refreshTimer >= 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
  }

  @Builder
  private EntryIcon(entry: TaildriveEntry, size: number) {
    Stack({ alignContent: Alignment.BottomEnd }) {
      if (entry.kind !== 'directory' && this.thumbnailUri(entry).length > 0) {
        Image(this.thumbnailUri(entry))
          .width(size)
          .height(size)
          .objectFit(ImageFit.Cover)
          .borderRadius(12)
          .clip(true)
      } else {
        Image(this.fileIcon(entry))
          .width(size)
          .height(size)
          .objectFit(ImageFit.Contain)
      }
      if (this.viewMode === 'grid' && !this.selectionMode && this.localFileStatus(entry).length > 0) {
        Row() {
          this.LocalFileStatus(entry, 13)
        }
        .width(19)
        .height(19)
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('sys.color.comp_background_primary'))
        .borderRadius(10)
        .hitTestBehavior(HitTestMode.Transparent)
      }
    }
    .width(size)
    .height(size)
  }

  @Builder
  private LocalFileStatus(entry: TaildriveEntry, size: number) {
    if (this.localFileStatus(entry).length > 0) {
      SymbolGlyph(this.localFileStatus(entry) === 'cached' ? $r('sys.symbol.arrow_down_circle') :
        $r('sys.symbol.arrow_down_circle_badge_checkmark'))
        .fontSize(size)
        .fontColor([$r('sys.color.icon_secondary')])
        .accessibilityLevel('yes')
        .accessibilityText(this.localFileStatus(entry) === 'cached' ? $r('app.string.taildrive_cached_file') :
          $r('app.string.taildrive_downloaded_file'))
        .hitTestBehavior(HitTestMode.Transparent)
        .id(`taildrive-local-status-${entry.name}`)
    }
  }

  @Builder
  private EntryMetadata(entry: TaildriveEntry) {
    Row({ space: 0 }) {
      if (this.formatListDate(entry.modifiedAtMs).length > 0) {
        Text(this.formatListDate(entry.modifiedAtMs))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
        Text(' - ')
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
      }
      if (entry.kind === 'directory') {
        Text(this.directoryKindText(entry))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
      } else {
        Text(this.formatSize(entry.size))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
      }
    }
    .width('100%')
  }

  @Builder
  private SelectionMark(entry: TaildriveEntry) {
    Row() {
      if (this.isSelected(entry)) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(13)
          .fontColor([$r('app.color.selection_foreground')])
      }
    }
    .width(22)
    .height(22)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.isSelected(entry) ? $r('app.color.selection_background') : Color.Transparent)
    .border({
      width: 1.5,
      color: this.isSelected(entry) ? $r('app.color.selection_background') : $r('sys.color.icon_secondary')
    })
    .borderRadius(11)
    .id(`taildrive-selection-mark-${entry.name}`)
    .onClick(() => {
      if (!this.dragSelecting && Date.now() >= this.sessionController.dragSuppressClickUntilMs) {
        this.toggleEntrySelection(entry);
      }
    })
  }

  @Builder
  private EntryContextPreview(entry: TaildriveEntry) {
    Row({ space: 12 }) {
      this.EntryIcon(entry, 46)
      Column({ space: 3 }) {
        Text(this.sanitizeDisplayLabel(entry.name))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        this.EntryMetadata(entry)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width(300)
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(22)
  }

  @Builder
  private EntryContextMenu(entry: TaildriveEntry) {
    Menu() {
      if (entry.kind === 'file') {
        MenuItem({ content: $r('app.string.taildrive_download_action') })
          .onClick(() => this.download(entry))
        MenuItem({ content: $r('app.string.taildrive_share_action') })
          .onClick(() => this.shareEntries([entry]))
      }
      MenuItem({ content: $r('app.string.taildrive_multi_select_action') })
        .onClick(() => this.selectFromContextMenu(entry))
      if (this.folderLockEnabled && this.canChangeFolderLock(entry)) {
        MenuItem({ content: this.isFolderDirectlyLocked(entry.path) ?
          $r('app.string.security_unlock_folder_action') : $r('app.string.security_lock_folder_action') })
          .onClick(() => this.toggleFolderLock(entry))
      }
      if (this.canModifyCurrentPath()) {
        MenuItem({ content: $r('app.string.taildrive_copy_action') })
          .onClick(() => this.openDestinationPickerForEntries([entry], 'copy'))
        MenuItem({ content: $r('app.string.taildrive_move_action') })
          .onClick(() => this.openMovePicker(entry))
        MenuItem({ content: $r('app.string.taildrive_rename_action') })
          .onClick(() => this.renameEntry(entry))
      }
      MenuItem({ content: $r('app.string.taildrive_details_action') })
        .onClick(() => this.showDetails(entry))
      if (this.canModifyCurrentPath()) {
        MenuItem({ content: $r('app.string.taildrive_delete_action') })
          .onClick(() => this.confirmDelete(entry))
      }
    }
    .width(280)
  }

  @Builder
  private FileListRow(entry: TaildriveEntry) {
    Column({ space: 0 }) {
      Row({ space: 8 }) {
        Row({ space: 10 }) {
          this.EntryIcon(entry, 36)
          Column({ space: 2 }) {
            Text(this.sanitizeDisplayLabel(entry.name))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
              .width('100%')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            this.EntryMetadata(entry)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          if (!this.selectionMode) {
            this.LocalFileStatus(entry, 17)
          }
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)
        .id(`taildrive-entry-${entry.name}`)
        .onClick(() => this.openEntry(entry))
        if (this.selectionMode) {
          this.SelectionMark(entry)
        } else if (entry.kind === 'directory') {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(UiTokens.ICON_CHEVRON)
            .fontColor([$r('sys.color.icon_secondary')])
            .onClick(() => this.openEntry(entry))
        }
      }
      .width('100%')
      .constraintSize({ minHeight: 54 })
      .padding({ left: 2, right: 10, top: 3, bottom: 3 })
      Divider()
        .color($r('app.color.divider_subtle'))
        .margin({ left: 46 })
    }
    .width('100%')
    .bindContextMenu(this.EntryContextMenu(entry), ResponseType.LongPress, {
      preview: this.EntryContextPreview(entry),
      previewBorderRadius: 22,
      borderRadius: 22,
      systemMaterial: LightAppearance.menu(this.glowLevel),
      onAppear: (): void => this.vibrateTouch(true)
    })
  }

  @Builder
  private FileGridCell(entry: TaildriveEntry) {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column({ space: 2 }) {
        this.EntryIcon(entry, 42)
        Text(this.sanitizeDisplayLabel(entry.name))
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
        Text(entry.kind === 'file' ? this.formatSize(entry.size) : this.formatListDate(entry.modifiedAtMs))
          .fontSize(9)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
      }
      .width('100%')
      .padding({ left: 3, right: 3, top: 5, bottom: 4 })
      .alignItems(HorizontalAlign.Center)
      if (this.selectionMode) {
        this.SelectionMark(entry)
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 82 })
    .backgroundColor(Color.Transparent)
    .borderRadius(10)
    .onClick(() => this.openEntry(entry))
    .bindContextMenu(this.EntryContextMenu(entry), ResponseType.LongPress, {
      preview: this.EntryContextPreview(entry),
      previewBorderRadius: 22,
      borderRadius: 22,
      systemMaterial: LightAppearance.menu(this.glowLevel),
      onAppear: (): void => this.vibrateTouch(true)
    })
    .id(`taildrive-entry-${entry.name}`)
  }

  @Builder
  private EntryGroups() {
    Column({ space: 4 }) {
      ForEach(this.groupedEntries(), (group: TaildriveEntryGroup) => {
        if (group.key !== 'all') {
          Text(group.title)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
            .padding({ left: 4, top: 12, bottom: 4 })
        }
        if (this.viewMode === 'list') {
          Column({ space: 0 }) {
            ForEach(group.entries, (entry: TaildriveEntry) => {
              this.FileListRow(entry)
            }, (entry: TaildriveEntry) => entry.path)
          }
          .width('100%')
        } else {
          GridRow({
            columns: { xs: 2, sm: 3, md: 4, lg: 5 },
            gutter: { x: 12, y: 12 }
          }) {
            ForEach(group.entries, (entry: TaildriveEntry) => {
              GridCol({ span: 1 }) {
                this.FileGridCell(entry)
              }
            }, (entry: TaildriveEntry) => entry.path)
          }
          .width('100%')
        }
      }, (group: TaildriveEntryGroup) => group.key)
    }
    .width('100%')
  }

  @Builder
  private RefreshableEntryViewport() {
    Refresh({ refreshing: $$this.pullRefreshing }) {
      this.StandaloneEntryViewport()
    }
    .width('100%')
    .height('100%')
    .layoutWeight(1)
    .pullToRefresh(this.connected && !this.busy && !this.appLockActive && this.hasFolderAccess(this.path) &&
      !this.dragSelecting)
    .onRefreshing(() => {
      this.pullRefresh();
    })
    .id('taildrive-pull-refresh')
  }

  @Builder
  private StandaloneEntryViewport() {
    if (this.loading && this.entries.length === 0) {
      Column({ space: 10 }) {
        LoadingProgress().width(28).height(28)
        Text($r('app.string.taildrive_loading'))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    } else if (this.displayEntries().length === 0) {
      Scroll(this.contentScroller) {
        Column({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.folder'))
            .fontSize(42)
            .fontColor([$r('sys.color.icon_secondary')])
          Text(this.reason.length > 0 ? this.statusCodeText(this.reason) :
            this.searchQuery.trim().length > 0 ? $r('app.string.feature_guide_search_empty') :
              this.setupHelpNotice() === 'share' ? $r('app.string.feature_guide_no_shares') : $r('app.string.taildrive_empty'))
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .textAlign(TextAlign.Center)
            .lineHeight(20)
          if (this.searchQuery.trim().length > 0) {
            Button($r('app.string.feature_guide_clear_search'), {
              buttonStyle: ButtonStyleMode.TEXTUAL, controlSize: ControlSize.NORMAL
            })
              .fontSize(UiTokens.BODY_SIZE)
              .constraintSize({ minHeight: UiTokens.ACTION_HEIGHT })
              .id('taildrive-clear-empty-search')
              .onClick(() => { this.searchQuery = ''; this.rebuildListDataSource(); })
          } else if (this.setupHelpNotice() === 'share') {
            this.SetupHelpAction($r('app.string.feature_guide_share_help'), 'taildrive-share-help')
          } else if (this.setupHelpNotice() === 'permission') {
            this.SetupHelpAction($r('app.string.feature_guide_permission_help'), 'taildrive-permission-help')
          }
          if (this.reason.length > 0 && this.retryAvailable &&
            (this.sessionController.retryKind === 'refresh' || this.sessionController.retryKind === 'target')) {
            Button($r('app.string.taildrive_refresh_action'), {
              buttonStyle: ButtonStyleMode.TEXTUAL, controlSize: ControlSize.NORMAL
            })
              .fontSize(UiTokens.BODY_SIZE)
              .constraintSize({ minHeight: UiTokens.ACTION_HEIGHT })
              .id('taildrive-empty-retry')
              .enabled(!this.loading && !this.busy)
              .onClick(() => this.retryLastOperation())
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .id('taildrive-list-state')
    } else if (this.viewMode === 'list') {
      List({ scroller: this.contentScroller, space: 0 }) {
        LazyForEach(this.listDataSource, (item: TaildriveListItemModel) => {
          ListItem() {
            if (item.header) {
              Text(item.title)
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_secondary'))
                .width('100%')
                .padding({ left: 4, top: 8, bottom: 4 })
            } else {
              this.FileListRow(item.entry)
            }
          }
        }, (item: TaildriveListItemModel) => item.key)
      }
      .width('100%')
      .height('100%')
      .cachedCount(12)
      .contentEndOffset(this.bottomInset + 86)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .scrollBar(BarState.Auto)
      .scrollBarWidth(3)
      .enableScrollInteraction(!this.dragSelecting)
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        this.dragViewportWidth = Number(newValue.width) || 0;
        this.dragViewportHeight = Number(newValue.height) || 0;
      })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.finishDragSelection();
        }
      })
      .onGestureJudgeBegin((gestureInfo: GestureInfo, _event: BaseGestureEvent): GestureJudgeResult => {
        if (gestureInfo.tag === 'taildrive-drag-select' &&
          (!this.selectionMode || !this.connected || this.busy || this.loading)) {
          return GestureJudgeResult.REJECT;
        }
        return GestureJudgeResult.CONTINUE;
      })
      .priorityGesture(
        GestureGroup(
          GestureMode.Sequence,
          LongPressGesture({ repeat: false, duration: 220 })
            .tag('taildrive-drag-select')
            .onAction((event: GestureEvent) => {
              this.startDragSelectionFromGesture(event);
            }),
          PanGesture({ fingers: 1, direction: PanDirection.All, distance: 1 })
            .onActionStart((event: GestureEvent) => {
              this.moveDragSelectionFromGesture(event);
            })
            .onActionUpdate((event: GestureEvent) => {
              this.moveDragSelectionFromGesture(event);
            })
            .onActionEnd(() => {
              this.finishDragSelection();
            })
            .onActionCancel(() => {
              this.finishDragSelection();
            })
        )
          .onCancel(() => {
            this.finishDragSelection();
          })
      )
      .id('taildrive-list-view')
      .transition(TransitionEffect.OPACITY.animation({
        duration: MotionTokens.duration(180), curve: MotionTokens.curve()
      }))
    } else {
      Grid(this.contentScroller) {
        LazyForEach(this.listDataSource, (item: TaildriveListItemModel) => {
          if (item.header) {
            GridItem() {
              Text(item.title)
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_secondary'))
                .width('100%')
                .padding({ left: 2, top: 6, bottom: 2 })
            }
            .columnStart(0)
            .columnEnd(3)
          } else {
            GridItem() {
              this.FileGridCell(item.entry)
            }
          }
        }, (item: TaildriveListItemModel) => item.key)
      }
      .columnsTemplate('1fr 1fr 1fr 1fr')
      .columnsGap(4)
      .rowsGap(4)
      .width('100%')
      .height('100%')
      .cachedCount(16)
      .contentEndOffset(this.bottomInset + 86)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .scrollBar(BarState.Auto)
      .scrollBarWidth(3)
      .enableScrollInteraction(!this.dragSelecting)
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        this.dragViewportWidth = Number(newValue.width) || 0;
        this.dragViewportHeight = Number(newValue.height) || 0;
      })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.finishDragSelection();
        }
      })
      .onGestureJudgeBegin((gestureInfo: GestureInfo, _event: BaseGestureEvent): GestureJudgeResult => {
        if (gestureInfo.tag === 'taildrive-drag-select' &&
          (!this.selectionMode || !this.connected || this.busy || this.loading)) {
          return GestureJudgeResult.REJECT;
        }
        return GestureJudgeResult.CONTINUE;
      })
      .priorityGesture(
        GestureGroup(
          GestureMode.Sequence,
          LongPressGesture({ repeat: false, duration: 220 })
            .tag('taildrive-drag-select')
            .onAction((event: GestureEvent) => {
              this.startDragSelectionFromGesture(event);
            }),
          PanGesture({ fingers: 1, direction: PanDirection.All, distance: 1 })
            .onActionStart((event: GestureEvent) => {
              this.moveDragSelectionFromGesture(event);
            })
            .onActionUpdate((event: GestureEvent) => {
              this.moveDragSelectionFromGesture(event);
            })
            .onActionEnd(() => {
              this.finishDragSelection();
            })
            .onActionCancel(() => {
              this.finishDragSelection();
            })
        )
          .onCancel(() => {
            this.finishDragSelection();
          })
      )
      .id('taildrive-grid-view')
      .transition(TransitionEffect.OPACITY.animation({
        duration: MotionTokens.duration(180), curve: MotionTokens.curve()
      }))
    }
  }

  @Builder
  private SearchField() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(20)
        .fontColor([$r('sys.color.icon_secondary')])
      TextInput({ text: this.searchQuery, placeholder: $r('app.string.taildrive_search_placeholder') })
        .height(44)
        .layoutWeight(1)
        .fontSize(14)
        .backgroundColor(Color.Transparent)
        .enterKeyType(EnterKeyType.Search)
        .id('taildrive-search')
        .onChange((value: string) => this.updateSearchQuery(value))
        .onSubmit(() => this.commitSearch())
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(16)
        .fontColor([$r('sys.color.icon_secondary')])
        .onClick(() => {
          this.searchQuery = '';
          this.rebuildListDataSource();
        })
    }
    .layoutWeight(1)
    .height(46)
    .padding({ left: 14, right: 14 })
    .backgroundColor($r('sys.color.comp_background_tertiary'))
    .border({ width: 1, color: $r('sys.color.comp_divider') })
    .borderRadius(23)
    .transition(TransitionEffect.OPACITY.animation({
      duration: MotionTokens.duration(180), curve: MotionTokens.curve()
    }))
  }

  @Builder
  private SortModeChoice(label: ResourceStr, mode: string, controlId: string) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontWeight(this.sortDraftMode === mode ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.sortDraftMode === mode ? $r('app.color.emphasize') :
          $r('sys.color.font_primary'))
        .layoutWeight(1)
      if (this.sortDraftMode === mode) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(18)
          .fontColor([$r('app.color.emphasize')])
          .id(`${controlId}-selected`)
      }
    }
    .width('100%')
    .height(48)
    .padding({ left: 8, right: 8 })
    .backgroundColor(this.sortDraftMode === mode ? $r('sys.color.comp_background_tertiary') : Color.Transparent)
    .borderRadius(12)
    .id(controlId)
    .onClick(() => this.chooseSortMode(mode))
  }

  @Builder
  private GroupModeChoice(label: ResourceStr, mode: string, controlId: string) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontWeight(this.groupDraftMode === mode ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.groupDraftMode === mode ? $r('app.color.emphasize') :
          $r('sys.color.font_primary'))
        .layoutWeight(1)
      if (this.groupDraftMode === mode) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(18)
          .fontColor([$r('app.color.emphasize')])
          .id(`${controlId}-selected`)
      }
    }
    .width('100%')
    .height(48)
    .padding({ left: 8, right: 8 })
    .backgroundColor(this.groupDraftMode === mode ? $r('sys.color.comp_background_tertiary') : Color.Transparent)
    .borderRadius(12)
    .id(controlId)
    .onClick(() => this.chooseGroupMode(mode))
  }

  @Builder
  private SortSheet() {
    Stack() {
      Scroll() {
        Column({ space: 0 }) {
          Text($r('app.string.taildrive_sort_section'))
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
            .padding({ top: 4, bottom: 6 })
          this.SortModeChoice($r('app.string.taildrive_sort_name'), 'name', 'taildrive-sort-name')
          Divider().color($r('sys.color.comp_divider'))
          this.SortModeChoice($r('app.string.taildrive_sort_modified'), 'modified', 'taildrive-sort-modified')
          Divider().color($r('sys.color.comp_divider'))
          this.SortModeChoice($r('app.string.taildrive_sort_size'), 'size', 'taildrive-sort-size')
          Text($r('app.string.taildrive_sort_direction_section'))
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
            .padding({ top: 18, bottom: 6 })
          Row() {
            Text($r('app.string.taildrive_sort_ascending'))
              .fontSize(15)
              .fontColor($r('sys.color.font_primary'))
              .layoutWeight(1)
            if (!this.sortDraftDescending) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(18)
                .fontColor([$r('app.color.emphasize')])
            }
          }
          .width('100%')
          .height(48)
          .padding({ left: 8, right: 8 })
          .onClick(() => this.sortDraftDescending = false)
          Divider().color($r('sys.color.comp_divider'))
          Row() {
            Text($r('app.string.taildrive_sort_descending'))
              .fontSize(15)
              .fontColor($r('sys.color.font_primary'))
              .layoutWeight(1)
            if (this.sortDraftDescending) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(18)
                .fontColor([$r('app.color.emphasize')])
            }
          }
          .width('100%')
          .height(48)
          .padding({ left: 8, right: 8 })
          .onClick(() => this.sortDraftDescending = true)
          Text($r('app.string.taildrive_group_section'))
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
            .padding({ top: 18, bottom: 6 })
          this.GroupModeChoice($r('app.string.taildrive_group_none'), 'none', 'taildrive-group-none')
          Divider().color($r('sys.color.comp_divider'))
          this.GroupModeChoice($r('app.string.taildrive_group_by_type'), 'type', 'taildrive-group-type')
          Divider().color($r('sys.color.comp_divider'))
          this.GroupModeChoice($r('app.string.taildrive_group_by_date'), 'date', 'taildrive-group-date')
          Button($r('app.string.confirm_action'), {
            buttonStyle: ButtonStyleMode.EMPHASIZED, controlSize: ControlSize.NORMAL
          })
            .fontSize(UiTokens.BODY_SIZE)
            .width('100%')
            .height(UiTokens.ACTION_HEIGHT)
            .margin({ top: 20, bottom: 12 })
            .id('taildrive-sort-confirm')
            .onClick(() => this.confirmSortPanel())
        }
        .width('100%')
        .padding({ left: UiTokens.PAGE_PADDING, right: UiTokens.PAGE_PADDING, bottom: UiTokens.GROUP_GAP })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.TopStart)
      .scrollBar(BarState.Auto)
      .nestedScroll({
        scrollForward: NestedScrollMode.PARENT_FIRST,
        scrollBackward: NestedScrollMode.SELF_FIRST
      })
      .id('taildrive-sort-panel')
      if (this.isSheetBlockedBySecurity()) {
        this.SheetSecurityShield()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private SheetHosts() {
    Stack() {
      Row()
        .width(0)
        .height(0)
        .id('taildrive-editor-sheet-host')
        .bindSheet($$this.editorVisible, this.EditorSheet(), {
          height: '31%',
          preferType: SheetType.BOTTOM,
          mode: SheetMode.OVERLAY,
          dragBar: true,
          showClose: true,
          enableOutsideInteractive: false,
          systemMaterial: LightAppearance.sheet(this.glowLevel),
          onDisappear: () => {
            this.editorVisible = false;
          }
        })
      Row()
        .width(0)
        .height(0)
        .id('taildrive-details-sheet-host')
        .bindSheet($$this.detailsVisible, this.DetailsSheet(), {
          detents: ['66%', '86%'],
          preferType: SheetType.BOTTOM,
          mode: SheetMode.OVERLAY,
          scrollSizeMode: ScrollSizeMode.CONTINUOUS,
          dragBar: true,
          showClose: true,
          enableOutsideInteractive: false,
          systemMaterial: LightAppearance.sheet(this.glowLevel),
          title: { title: $r('app.string.taildrive_details_title') },
          onDisappear: () => {
            this.closeDetails();
          }
        })
      Row()
        .width(0)
        .height(0)
        .id('taildrive-preview-download-sheet-host')
        .bindSheet($$this.previewDownloadVisible, this.PreviewDownloadSheet(), {
          height: '38%',
          preferType: SheetType.BOTTOM,
          mode: SheetMode.OVERLAY,
          dragBar: true,
          showClose: true,
          enableOutsideInteractive: false,
          systemMaterial: LightAppearance.sheet(this.glowLevel),
          onDisappear: () => {
            this.previewDownloadVisible = false;
          }
        })
      Row()
        .width(0)
        .height(0)
        .id('taildrive-move-sheet-host')
        .bindSheet($$this.moveVisible, this.MoveSheet(), {
          detents: ['62%', '82%'],
          preferType: SheetType.BOTTOM,
          mode: SheetMode.OVERLAY,
          scrollSizeMode: ScrollSizeMode.CONTINUOUS,
          dragBar: true,
          showClose: true,
          enableOutsideInteractive: false,
          systemMaterial: LightAppearance.sheet(this.glowLevel),
          title: this.moveTargetCount > 1 ? {
            title: this.moveOperation === 'copy' ? $r('app.string.taildrive_copy_to_title') :
              $r('app.string.taildrive_move_title'),
            subtitle: $r('app.string.taildrive_selected_count', this.moveTargetCount)
          } : {
            title: this.moveOperation === 'copy' ? $r('app.string.taildrive_copy_to_title') :
              $r('app.string.taildrive_move_title')
          },
          onDisappear: () => {
            this.closeMovePicker();
          }
        })
      Row()
        .width(0)
        .height(0)
        .id('taildrive-sort-sheet-host')
        .bindSheet($$this.sortSheetVisible, this.SortSheet(), {
          detents: ['58%', '72%'],
          preferType: SheetType.BOTTOM,
          mode: SheetMode.OVERLAY,
          scrollSizeMode: ScrollSizeMode.CONTINUOUS,
          dragBar: true,
          showClose: true,
          enableOutsideInteractive: false,
          systemMaterial: LightAppearance.sheet(this.glowLevel),
          title: { title: $r('app.string.taildrive_sort_group_title') },
          onDisappear: () => {
            this.sortSheetVisible = false;
          }
        })
    }
    .width(0)
    .height(0)
    .id('taildrive-sheet-hosts')
  }

  @Builder
  private SelectionSearchSummary() {
    if (this.selectionMode && this.searchVisible) {
      Row({ space: 10 }) {
        Text(this.hiddenSelectedCount() > 0 ?
          $r('app.string.taildrive_selected_search_scope', this.selectedEntries().length, this.hiddenSelectedCount()) :
          $r('app.string.taildrive_selected_count', this.selectedEntries().length))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .layoutWeight(1)
          .id('taildrive-selection-search-count')
        Text(this.allVisibleEntriesSelected() ? $r('app.string.taildrive_deselect_all_action') :
          $r('app.string.taildrive_select_all_action'))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .constraintSize({ minWidth: 64, minHeight: 44 })
          .padding({ left: 12, right: 12 })
          .textAlign(TextAlign.Center)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .borderRadius(22)
          .id('taildrive-select-search-results')
          .accessibilityText(this.allVisibleEntriesSelected() ?
            $r('app.string.taildrive_deselect_search_results') : $r('app.string.taildrive_select_search_results'))
          .enabled(!this.busy && this.displayEntries().length > 0)
          .onClick(() => this.toggleSelectAll())
      }
      .width('100%')
    }
  }

  @Builder
  private TopControls() {
    Row({ space: 6 }) {
      if (this.searchVisible) {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(18)
            .fontColor([$r('sys.color.icon_primary')])
        }
        .width(38)
        .height(38)
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .borderRadius(19)
        .id('taildrive-search-back')
        .onClick(() => this.setSearchVisible(false))
        this.SearchField()
      } else if (this.selectionMode) {
        Row() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(22)
            .fontColor([$r('sys.color.icon_primary')])
        }
        .width(48)
        .height(48)
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .border({ width: 1, color: $r('sys.color.comp_divider') })
        .borderRadius(24)
        .id('taildrive-selection-close')
        .onClick(() => this.exitSelectionMode())
        Column({ space: 1 }) {
          Text(this.selectedPaths.length === 0 ? $r('app.string.taildrive_selection_empty') :
            $r('app.string.taildrive_selected_count', this.selectedPaths.length))
            .fontSize(23)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.selectedPaths.length > 0) {
            Text($r('app.string.taildrive_selected_total', this.formatSize(this.selectedTotalBytes())))
              .fontSize(15)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(1)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text(this.allVisibleEntriesSelected() ? $r('app.string.taildrive_deselect_all_action') :
          $r('app.string.taildrive_select_all_action'))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .height(44)
          .padding({ left: 17, right: 17 })
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .border({ width: 1, color: $r('sys.color.comp_divider') })
          .borderRadius(22)
          .id('taildrive-select-all')
          .onClick(() => this.toggleSelectAll())
      }
    }
    .width('100%')
    .height(54)
    .animation({ duration: MotionTokens.NORMAL, curve: MotionTokens.curve() })
  }

  @Builder
  private BreadcrumbTrail() {
    Scroll(this.breadcrumbScroller) {
      Row({ space: 4 }) {
        Text('Taildrive')
          .fontSize(13)
          .fontColor(this.path === '/' ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
          .maxLines(1)
          .id('taildrive-breadcrumb-root')
          .onClick(() => this.navigateToBreadcrumb(-1))
        ForEach(this.breadcrumbSegments(), (segment: string, index: number) => {
          Text('›')
            .fontSize(15)
            .fontColor($r('sys.color.icon_secondary'))
          Text(segment)
            .fontSize(13)
            .fontColor(index === this.breadcrumbSegments().length - 1 ?
              $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
            .maxLines(1)
            .id(`taildrive-breadcrumb-${index}`)
            .onClick(() => this.navigateToBreadcrumb(index))
        }, (segment: string, index: number) => `${index}-${segment}`)
      }
    }
    .layoutWeight(1)
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.None)
    .id('taildrive-path')
  }

  @Builder
  private PathBar() {
    Row({ space: 6 }) {
      if (this.path !== '/') {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(15)
            .fontColor([$r('sys.color.icon_primary')])
            .id('taildrive-back-icon')
        }
        .width(34)
        .height(34)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Color.Transparent)
        .borderRadius(17)
        .systemMaterial(LightAppearance.toolbarButton(this.glowLevel))
        .id('taildrive-back')
        .accessibilityText($r('app.string.taildrive_up_action'))
        .enabled(!this.busy && !this.appLockActive)
        .onClick(() => this.goUp())
      }
      Row({ space: 2 }) {
        this.BreadcrumbTrail()
        Row() {
          if (this.loading) {
            LoadingProgress()
              .width(15)
              .height(15)
              .id('taildrive-refresh-loading')
          } else {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(15)
              .fontColor([$r('sys.color.icon_secondary')])
          }
        }
        .width(30)
        .height(30)
        .justifyContent(FlexAlign.Center)
        .opacity(this.busy || this.appLockActive ? 0.45 : 1)
        .id('taildrive-refresh')
        .accessibilityText($r('app.string.taildrive_refresh_action'))
        .enabled(!this.busy && !this.loading && !this.appLockActive)
        .onClick(() => this.refreshWithFeedback())
      }
      .height(34)
      .layoutWeight(1)
      .padding({ left: 12, right: 3 })
      .backgroundColor(Color.Transparent)
      .borderRadius(17)
      .systemMaterial(LightAppearance.toolbarButton(this.glowLevel))
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private NavigationPathBar() {
    Column() {
      if (this.connected) {
        this.PathBar()
      }
    }
    .width('100%')
    .height(40)
    .justifyContent(FlexAlign.Center)
    .padding({ left: this.titleBarPadding, right: this.titleBarPadding, bottom: 4 })
    .id('taildrive-navigation-path-bar')
  }

  private isTransferBannerVisible(): boolean {
    return (this.busy || this.previewDownloading) &&
      (this.transfer.state === 'queued' || this.transfer.state === 'transferring');
  }

  private isOperationBannerVisible(): boolean {
    return !this.isTransferBannerVisible() && (this.status.length > 0 || this.retryAvailable);
  }

  private floatingCapsuleSideMargin(): number {
    return this.standalone ? Math.max(0, TAILDRIVE_TOOLBAR_SIDE_MARGIN - this.titleBarPadding) : 0;
  }

  @Builder
  private TransferStatus() {
    Row({ space: 10 }) {
      LoadingProgress()
        .width(18)
        .height(18)
        .color($r('app.color.emphasize'))
      Column({ space: 1 }) {
        Text(this.transfer.fileName.length > 0 ? this.transfer.fileName :
          $r('app.string.taildrive_transfer_in_progress'))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.status.length > 0 ? this.statusText() : $r('app.string.taildrive_transfer_in_progress'))
          .fontSize(11)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.transferProgress().length > 0) {
        Text(this.transferProgress())
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.emphasize'))
      }
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(14)
          .fontColor([$r('sys.color.icon_primary')])
      }
      .width(30)
      .height(30)
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .accessibilityText($r('app.string.cancel_action'))
      .id('taildrive-transfer-cancel')
      .onClick(() => this.cancelVisibleTransfer())
    }
    .width(this.standalone ? `calc(100% - ${this.floatingCapsuleSideMargin() * 2}vp)` : '100%')
    .constraintSize({ minHeight: 50 })
    .padding({ left: 16, right: 10, top: 7, bottom: 7 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.standalone ? Color.Transparent : $r('sys.color.comp_background_primary'))
    .backgroundBlurStyle(this.standalone ? BlurStyle.COMPONENT_THICK : BlurStyle.NONE)
    .border({ width: this.standalone ? 1 : 0, color: $r('sys.color.comp_divider') })
    .shadow({
      radius: this.standalone ? 20 : 0,
      color: this.standalone ? $r('app.color.shadow_floating_capsule') : Color.Transparent,
      offsetY: this.standalone ? 6 : 0
    })
    .borderRadius(25)
  }

  @Builder
  private OperationStatus() {
    Column({ space: 4 }) {
      Row({ space: 10 }) {
        if (this.status.length > 0 || this.hasListFailure()) {
          Text(this.statusText())
            .fontSize(13)
            .lineHeight(18)
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1)
        } else {
          Blank().layoutWeight(1)
        }
        if (this.retryAvailable) {
          Button($r('app.string.taildrive_retry_action'), {
            buttonStyle: ButtonStyleMode.TEXTUAL, controlSize: ControlSize.SMALL
          })
            .fontSize(13)
            .height(32)
            .enabled(!this.loading && !this.busy && !this.appLockActive)
            .id('taildrive-operation-retry')
            .onClick(() => this.retryLastOperation())
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      if (this.showRetainedListNotice()) {
        Text($r('app.string.taildrive_retained_list_notice'))
          .fontSize(12)
          .lineHeight(18)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .id('taildrive-retained-list-notice')
      }
      if ((this.status === 'permission_denied' || this.reason === 'permission_denied') && this.canShowSetupHelp()) {
        this.SetupHelpAction($r('app.string.feature_guide_permission_help'), 'taildrive-operation-permission-help')
      }
    }
    .width(this.standalone ? `calc(100% - ${this.floatingCapsuleSideMargin() * 2}vp)` : '100%')
    .padding({ left: 16, right: 14, top: 9, bottom: 9 })
    .backgroundColor(this.standalone ? Color.Transparent : $r('sys.color.comp_background_primary'))
    .backgroundBlurStyle(this.standalone ? BlurStyle.COMPONENT_THICK : BlurStyle.NONE)
    .border({ width: this.standalone ? 1 : 0, color: $r('sys.color.comp_divider') })
    .shadow({
      radius: this.standalone ? 20 : 0,
      color: this.standalone ? $r('app.color.shadow_floating_capsule') : Color.Transparent,
      offsetY: this.standalone ? 6 : 0
    })
    .borderRadius(22)
  }

  private saveSelectedEntry(): void {
    const entry: TaildriveEntry | undefined = this.selectedEntry();
    if (entry === undefined || entry.kind !== 'file') {
      this.status = 'select_one_for_details';
      return;
    }
    this.download(entry);
  }

  private copyEntryPath(entry: TaildriveEntry): void {
    if (this.appLockActive || !this.hasFolderAccess(this.path) || !this.hasFolderAccess(entry.path)) {
      return;
    }
    const data: pasteboard.PasteData = createLocalTextPasteData(entry.path);
    pasteboard.getSystemPasteboard().setData(data)
      .then(() => this.showTransientStatus('paths_copied'))
      .catch(() => this.status = 'copy_failed');
  }

  private canShareSelected(): boolean {
    if (this.busy || this.previewDownloading) {
      return false;
    }
    const selected: TaildriveEntry[] = this.selectedEntries();
    return selected.length > 0 && selected.every((entry: TaildriveEntry) => entry.kind === 'file');
  }

  private shareUtdForEntry(entry: TaildriveEntry): string {
    const extension: string = this.fileExtension(entry.name);
    if (extension.length > 0) {
      try {
        const utd: string = uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(`.${extension}`);
        if (utd !== undefined && utd.length > 0) {
          return utd;
        }
      } catch (_error) {}
    }
    return uniformTypeDescriptor.UniformDataType.FILE;
  }

  private async shareSelectedEntries(): Promise<void> {
    const selected: TaildriveEntry[] = this.selectedEntries();
    if (selected.length === 0) {
      this.status = 'file_unavailable';
      return;
    }
    if (!selected.every((entry: TaildriveEntry) => entry.kind === 'file')) {
      this.status = 'file_unavailable';
      return;
    }
    await this.shareEntries(selected);
  }

  private async shareEntries(entries: TaildriveEntry[]): Promise<void> {
    const targets: TaildriveEntry[] = entries
      .filter((entry: TaildriveEntry) => entry.kind === 'file')
      .map((entry: TaildriveEntry) => this.snapshotFileEntry(entry));
    if (!this.connected || this.busy || this.previewDownloading || targets.length === 0) {
      return;
    }
    for (let index: number = 0; index < targets.length; index++) {
      if (!await this.ensureFolderAccess(targets[index].path)) {
        return;
      }
    }
    await this.cancelPreviewDownload();
    if (!this.connected) {
      return;
    }
    const generation: number = ++this.previewGeneration;
    const prepared: Array<TaildriveSharePreparedFile> = [];
    let downloadedAny: boolean = false;
    let pollingStarted: boolean = false;
    try {
      for (let index: number = 0; index < targets.length; index++) {
        const entry: TaildriveEntry = targets[index];
        let cached: TaildriveCachedPreview | undefined = this.previewGateway.cachedPreview(this.context(), entry);
        if (cached === undefined) {
          let root: string = '';
          let localPath: string = '';
          try {
            root = this.previewGateway.root(this.context());
            localPath = this.previewGateway.prepareDownload(this.context(), entry);
          } catch (_error) {
            if (generation === this.previewGeneration) {
              this.status = 'share_download_failed';
            }
            return;
          }
          const requestId: number = this.newTransferRequestId();
          this.activePreviewPath = entry.path;
          this.cachedEntries = this.cachedEntries.filter((candidate: TaildriveEntry) => candidate.path !== entry.path);
          this.previewRequestId = requestId;
          this.previewDownloading = true;
          this.status = 'share_downloading';
          this.clearRetry();
          if (!pollingStarted) {
            this.startTransferPolling();
            pollingStarted = true;
          }
          downloadedAny = true;
          const result: TaildriveTransferSnapshot = await this.gateway.download({
            requestId: requestId,
            remotePath: entry.path,
            localRoot: root,
            localPath: localPath
          });
          if (generation !== this.previewGeneration) {
            return;
          }
          this.transfer = result;
          if (result.state !== 'completed') {
            this.status = result.reason.length > 0 ? result.reason : 'share_download_failed';
            return;
          }
          this.markCachedEntry(entry);
          cached = this.previewGateway.cachedPreview(this.context(), entry);
          if (cached === undefined) {
            this.status = 'share_download_failed';
            return;
          }
        }
        prepared.push({ entry: entry, localPath: cached.path });
      }
    } catch (_error) {
      if (generation === this.previewGeneration) {
        this.status = 'share_download_failed';
      }
      return;
    } finally {
      if (generation === this.previewGeneration) {
        this.previewRequestId = 0;
        this.previewDownloading = false;
        this.activePreviewPath = '';
        if (pollingStarted) {
          this.stopTransferPolling();
          clearTaildriveProgress().catch(() => {});
        }
      }
    }
    if (generation !== this.previewGeneration || !this.connected || !this.browserVisible ||
      this.appLockActive || prepared.length === 0) {
      return;
    }
    if (this.status === 'share_downloading') {
      this.status = '';
    }
    if (downloadedAny) {
      this.refreshThumbnails(this.entries);
    }
    try {
      const records: Array<systemShare.SharedRecord> = prepared.map(
        (item: TaildriveSharePreparedFile): systemShare.SharedRecord => {
          const record: systemShare.SharedRecord = {
            utd: this.shareUtdForEntry(item.entry),
            uri: fileUri.getUriFromPath(item.localPath),
            title: item.entry.name
          };
          return record;
        }
      );
      const sharedData: systemShare.SharedData = new systemShare.SharedData(records[0]);
      for (let index: number = 1; index < records.length; index++) {
        sharedData.addRecord(records[index]);
      }
      const controller: systemShare.ShareController = new systemShare.ShareController(sharedData);
      await controller.show(this.context(), {
        previewMode: systemShare.SharePreviewMode.DEFAULT,
        selectionMode: records.length > 1 ? systemShare.SelectionMode.BATCH : systemShare.SelectionMode.SINGLE
      });
    } catch (_error) {
      this.status = 'share_failed';
    }
  }

  private showMoreSelected(): void {
    const selected: TaildriveEntry[] = this.selectedEntries();
    if (selected.length !== 1) {
      return;
    }
    this.showDetails(selected[0]);
  }

  @Builder
  private SelectionAction($$: TaildriveSelectionActionData) {
    Button({ type: ButtonType.ROUNDED_RECTANGLE, stateEffect: true }) {
      Column({ space: 2 }) {
        SymbolGlyph($$.icon)
          .fontSize(UiTokens.ICON_INLINE_ACTION)
          .fontColor([$$.destructive && $$.isEnabled ? $r('app.color.status_error') : $r('sys.color.icon_primary')])
        Text($$.label)
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor($$.destructive && $$.isEnabled ? $r('app.color.status_error') : $r('sys.color.font_primary'))
          .maxLines(1)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
    .id($$.actionId)
    .layoutWeight(1)
    .height(44)
    .padding({ left: 4, right: 4 })
    .borderRadius(22)
    .backgroundColor(Color.Transparent)
    .enabled($$.isEnabled)
    .onClick($$.action)
  }

  @Builder
  private SelectionMoreAction($$: TaildriveSelectionMoreData) {
    Button({ type: ButtonType.ROUNDED_RECTANGLE, stateEffect: true }) {
      Column({ space: 2 }) {
        SymbolGlyph($r('sys.symbol.ellipsis_circle'))
          .fontSize(UiTokens.ICON_INLINE_ACTION)
          .fontColor([$r('sys.color.icon_primary')])
        Text($r('app.string.taildrive_more_action'))
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
    .id($$.actionId)
    .layoutWeight(1)
    .height(44)
    .padding({ left: 4, right: 4 })
    .borderRadius(22)
    .backgroundColor(Color.Transparent)
    .enabled($$.isEnabled)
    .onClick($$.action)
  }

  @Builder
  private NormalBottomToolbar() {
    Row({ space: 6 }) {
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.folder_badge_plus'))
          .fontSize(22)
          .fontColor([$r('sys.color.icon_primary')])
      }
      .width(42)
      .height(42)
      .backgroundColor(Color.Transparent)
      .borderRadius(21)
      .systemMaterial(LightAppearance.toolbarButton(this.glowLevel))
      .enabled(this.canModifyCurrentPath() && !this.busy)
      .id('taildrive-new-folder')
      .accessibilityText($r('app.string.taildrive_new_folder_action'))
      .onClick(() => this.createFolder())
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.doc_text_badge_arrow_up'))
          .fontSize(22)
          .fontColor([$r('sys.color.icon_primary')])
      }
      .width(42)
      .height(42)
      .backgroundColor(Color.Transparent)
      .borderRadius(21)
      .systemMaterial(LightAppearance.toolbarButton(this.glowLevel))
      .enabled(this.canModifyCurrentPath() && !this.busy)
      .id('taildrive-upload')
      .accessibilityText($r('app.string.taildrive_upload_action'))
      .onClick(() => this.selectUpload())
      Button({ type: ButtonType.ROUNDED_RECTANGLE, stateEffect: true }) {
        Row({ space: 7 }) {
          SymbolGlyph($r('sys.symbol.sort'))
            .fontSize(18)
            .fontColor([$r('sys.color.icon_primary')])
          Text(this.sortModeText())
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
      .layoutWeight(1)
      .height(42)
      .padding({ left: 10, right: 10 })
      .backgroundColor(Color.Transparent)
      .borderRadius(21)
      .systemMaterial(LightAppearance.toolbarButton(this.glowLevel))
      .id('taildrive-sort')
      .accessibilityText($r('app.string.taildrive_sort_group_title'))
      .onClick(() => this.openSortPanel())
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph(this.viewMode === 'list' ? $r('sys.symbol.square_grid_2x2') : $r('sys.symbol.list_bullet'))
          .fontSize(22)
          .fontColor([$r('sys.color.icon_primary')])
      }
      .width(42)
      .height(42)
      .backgroundColor(Color.Transparent)
      .borderRadius(21)
      .systemMaterial(LightAppearance.toolbarButton(this.glowLevel))
      .id('taildrive-view-toggle')
      .accessibilityText(this.viewMode === 'list' ? $r('app.string.taildrive_grid_view_action') :
        $r('app.string.taildrive_list_view_action'))
      .onClick(() => this.toggleViewMode())
    }
    .width(`calc(100% - ${TAILDRIVE_TOOLBAR_SIDE_MARGIN * 2}vp)`)
    .height(TAILDRIVE_TOOLBAR_HEIGHT)
    .justifyContent(FlexAlign.SpaceBetween)
    .margin({
      left: TAILDRIVE_TOOLBAR_SIDE_MARGIN,
      right: TAILDRIVE_TOOLBAR_SIDE_MARGIN,
      bottom: this.standalone ? Math.max(0, this.bottomInset - 16) : 14
    })
  }

  @Builder
  private SelectionBottomToolbar() {
    Row({ space: 2 }) {
      this.SelectionAction({
        icon: $r('sys.symbol.share'),
        label: $r('app.string.taildrive_share_action'),
        isEnabled: this.canShareSelected(),
        destructive: false,
        actionId: 'taildrive-selection-share',
        action: () => this.shareSelectedEntries()
      })
      this.SelectionAction({
        icon: $r('sys.symbol.doc_text_on_doc_text'),
        label: $r('app.string.taildrive_copy_action'),
        isEnabled: this.selectedEntries().length > 0 && !this.busy && this.canModifyCurrentPath(),
        destructive: false,
        actionId: 'taildrive-selection-copy',
        action: () => this.openCopySelectedPicker()
      })
      this.SelectionAction({
        icon: $r('sys.symbol.arrow_right_folder_circle'),
        label: $r('app.string.taildrive_move_action'),
        isEnabled: this.selectedEntries().length > 0 && !this.busy && this.canModifyCurrentPath(),
        destructive: false,
        actionId: 'taildrive-selection-move',
        action: () => this.openMoveSelectedPicker()
      })
      this.SelectionAction({
        icon: $r('sys.symbol.trash'),
        label: $r('app.string.taildrive_delete_action'),
        isEnabled: this.selectedEntries().length > 0 && !this.busy && this.canModifyCurrentPath(),
        destructive: true,
        actionId: 'taildrive-selection-delete',
        action: () => this.confirmDeleteSelected()
      })
      this.SelectionMoreAction({
        isEnabled: this.selectedEntries().length === 1 && !this.busy,
        actionId: 'taildrive-selection-more',
        action: () => this.showMoreSelected()
      })
    }
    .width(`calc(100% - ${TAILDRIVE_TOOLBAR_SIDE_MARGIN * 2}vp)`)
    .height(TAILDRIVE_SELECTION_TOOLBAR_HEIGHT)
    .padding({ left: 4, right: 4 })
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.SpaceEvenly)
    .backgroundColor(Color.Transparent)
    .borderRadius(TAILDRIVE_SELECTION_TOOLBAR_HEIGHT / 2)
    .systemMaterial(LightAppearance.toolbarGroup(this.glowLevel))
    .margin({
      left: TAILDRIVE_TOOLBAR_SIDE_MARGIN,
      right: TAILDRIVE_TOOLBAR_SIDE_MARGIN,
      bottom: this.standalone ? Math.max(0, this.bottomInset - 16) : 16
    })
  }

  @Builder
  private BottomToolbar() {
    if (this.selectionMode) {
      this.SelectionBottomToolbar()
    } else {
      this.NormalBottomToolbar()
    }
  }

  private fileToolbarHeight(): number {
    if (!this.connected) {
      return 0;
    }
    const toolbarHeight: number = this.selectionMode ? TAILDRIVE_SELECTION_TOOLBAR_HEIGHT :
      TAILDRIVE_TOOLBAR_HEIGHT;
    return toolbarHeight + Math.max(0, this.bottomInset - 16);
  }

  @Builder
  private FileToolbarHost() {
    Column() {
      if (this.connected) {
        this.BottomToolbar()
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .backgroundColor(Color.Transparent)
    .accessibilityLevel('no')
    .id('taildrive-material-toolbar')
  }

  @Builder
  private StandaloneNavigation() {
    HdsNavigation() {
      this.StandaloneBrowser()
    }
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      padding: {
        start: LengthMetrics.vp(this.titleBarPadding),
        end: LengthMetrics.vp(this.titleBarPadding)
      },
      style: {
        blurStrategy: LightAppearance.blurStrategy(this.glowLevel),
        originalStyle: {
          backgroundStyle: {
            backgroundColor: Color.Transparent
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            },
            menuStyle: {
              iconColor: $r('sys.color.icon_primary'),
              textColor: $r('sys.color.font_primary')
            }
          }
        },
        systemMaterialEffect: {
          materialType: LightAppearance.hdsType(this.glowLevel),
          materialLevel: LightAppearance.hdsLevel(this.glowLevel)
        }
      },
      content: {
        divider: { showType: DividerShowType.OFF },
        bottomBuilder: this.connected && !this.selectionMode && !this.searchVisible ? {
          builder: (): void => { this.NavigationPathBar(); },
          height: 40
        } : undefined,
        title: {
          mainTitle: this.selectionMode ?
            (this.selectedPaths.length === 0 ? $r('app.string.taildrive_selection_empty') :
              $r('app.string.taildrive_selected_count', this.selectedPaths.length)) :
            $r('app.string.tab_files'),
          subTitle: this.selectionMode ?
            (this.selectedPaths.length > 0 ?
              $r('app.string.taildrive_selected_total', this.formatSize(this.selectedTotalBytes())) :
              $r('app.string.taildrive_subtitle')) :
            $r('app.string.taildrive_subtitle')
        },
        menu: {
          maxCount: 2,
          value: this.searchVisible ? [] : this.selectionMode ? [
            {
              content: {
                label: this.allVisibleEntriesSelected() ? $r('app.string.taildrive_deselect_all_action') :
                  $r('app.string.taildrive_select_all_action'),
                type: TextStyleMode.NORMAL,
                isEnabled: this.displayEntries().length > 0,
                componentId: 'taildrive-select-all',
                action: () => this.toggleSelectAll()
              }
            },
            {
              content: {
                label: $r('app.string.native_settings_close'),
                icon: new SymbolGlyphModifier($r('sys.symbol.xmark'))
                  .fontColor([$r('sys.color.icon_primary')]),
                type: IconStyleMode.SMALL,
                isEnabled: true,
                componentId: 'taildrive-selection-close',
                action: () => this.exitSelectionMode()
              }
            }
          ] : !this.connected ? [{
            content: {
              label: $r('app.string.feature_guide_connect_help'),
              type: TextStyleMode.NORMAL,
              isEnabled: this.canShowSetupHelp(),
              componentId: 'taildrive-connection-help-menu',
              action: () => this.showSetupHelp('connect')
            }
          }] : [
            {
              content: {
                label: $r('app.string.taildrive_multi_select_action'),
                type: TextStyleMode.NORMAL,
                isEnabled: true,
                componentId: 'taildrive-multi-select',
                action: () => this.toggleSelectionMode()
              }
            },
            {
              content: {
                label: $r('app.string.taildrive_search_action'),
                icon: new SymbolGlyphModifier($r('sys.symbol.magnifyingglass'))
                  .fontColor([$r('sys.color.icon_primary')]),
                isEnabled: true,
                componentId: 'taildrive-search-trigger',
                action: () => this.setSearchVisible(true)
              }
            },
            {
              content: {
                label: $r('app.string.feature_guide_taildrive_help'),
                type: TextStyleMode.NORMAL,
                isEnabled: this.canShowSetupHelp(),
                componentId: 'taildrive-setup-help-menu',
                action: () => this.showSetupHelp()
              }
            }
          ]
        }
      }
    })
    // Use the compact native title bar and leave extra space below the status bar.
    .titleMode(HdsNavigationTitleMode.MINI)
    .bindToScrollable([this.contentScroller])
    .hideBackButton(true)
    .mode(NavigationMode.Stack)
    .padding({ top: 16 })
    .width('100%')
    .height('100%')
    .id('hds-navigation-files')
    .backgroundColor(this.transparentBackground ? Color.Transparent :
      $r('sys.color.background_secondary'))
  }

  @Builder
  private StandaloneBrowser() {
    Tabs({ barPosition: BarPosition.End }) {
      TabContent() {
        Column({ space: 6 }) {
          if (this.connected) {
            if (this.searchVisible) {
              this.TopControls()
            }
            this.SelectionSearchSummary()
            Stack() {
              this.RefreshableEntryViewport()
              if (this.isTransferBannerVisible() || this.isOperationBannerVisible()) {
                Column({ space: 6 }) {
                  if (this.isTransferBannerVisible()) {
                    this.TransferStatus()
                  } else if (this.isOperationBannerVisible()) {
                    this.OperationStatus()
                  }
                }
                .width('100%')
                .alignItems(HorizontalAlign.Center)
                .hitTestBehavior(HitTestMode.Transparent)
                .margin({ bottom: this.fileToolbarHeight() + 8 })
                .id('taildrive-floating-status-host')
              }
            }
            .width('100%')
            .layoutWeight(1)
            .alignContent(Alignment.Bottom)
          } else {
            Column({ space: 10 }) {
              SymbolGlyph($r('sys.symbol.folder'))
                .fontSize(42)
                .fontColor([$r('sys.color.icon_secondary')])
              Text($r('app.string.taildrive_connect_first'))
                .fontSize(14)
                .fontColor($r('sys.color.font_secondary'))
                .textAlign(TextAlign.Center)
              Button(this.connectionActionText, {
                buttonStyle: ButtonStyleMode.EMPHASIZED, controlSize: ControlSize.NORMAL
              })
                .fontSize(UiTokens.BODY_SIZE).id('taildrive-connect-action')
                .constraintSize({ minHeight: UiTokens.ACTION_HEIGHT })
                .enabled(this.connectionActionAvailable && !this.appLockActive)
                .onClick(() => this.onRequestConnection())
              this.SetupHelpAction($r('app.string.feature_guide_connect_help'), 'taildrive-connect-help', 'connect')
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          }
        }
        .width('100%')
        .height('100%')
        .padding({ left: this.titleBarPadding, right: this.titleBarPadding })
      }
      .tabBar(this.FileToolbarHost)
    }
    .vertical(false)
    .scrollable(false)
    .barMode(BarMode.Fixed)
    .barOverlap(true)
    .barHeight(this.fileToolbarHeight(), true)
    .barBackgroundColor(Color.Transparent)
    .barBackgroundBlurStyle(BlurStyle.NONE)
    .animationDuration(0)
    .width('100%')
    .height('100%')
    .id('taildrive-browser')
  }

  @Builder
  private BrowserContent() {
    Column({ space: 12 }) {
      if (!this.standalone) {
        Row() {
          SymbolGlyph($r('sys.symbol.folder'))
            .fontSize(20)
            .fontColor([$r('app.color.emphasize')])
          Text($r('app.string.taildrive_title'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .margin({ left: 8 })
        }
        .width('100%')
      } else if (this.connected) {
        this.TopControls()
      }
      if (!this.connected) {
        Column({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.folder'))
            .fontSize(42)
            .fontColor([$r('sys.color.icon_secondary')])
          Text($r('app.string.taildrive_connect_first'))
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .padding({ top: 42, bottom: 42 })
      } else {
        this.PathBar()
        if (this.searchVisible) {
          this.SearchField()
        }
        this.SelectionSearchSummary()
        if (this.loading) {
          Column({ space: 10 }) {
            LoadingProgress().width(28).height(28)
            Text($r('app.string.taildrive_loading'))
              .fontSize(13)
              .fontColor($r('sys.color.font_secondary'))
          }
          .width('100%')
          .padding({ top: 48, bottom: 48 })
        } else if (this.displayEntries().length === 0) {
          Column({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.folder'))
              .fontSize(42)
              .fontColor([$r('sys.color.icon_secondary')])
            Text(this.reason.length > 0 ? this.statusCodeText(this.reason) : $r('app.string.taildrive_empty'))
              .fontSize(13)
              .fontColor($r('sys.color.font_secondary'))
              .textAlign(TextAlign.Center)
              .lineHeight(20)
          }
          .width('100%')
          .padding({ left: 24, right: 24, top: 48, bottom: 48 })
          .id('taildrive-inline-list-state')
        } else {
          this.EntryGroups()
        }
        if (this.isTransferBannerVisible()) {
          this.TransferStatus()
        }
      }
      if (this.isOperationBannerVisible()) {
        this.OperationStatus()
      }
    }
    .width('100%')
    .padding({
      top: this.standalone ? 8 : 14,
      bottom: this.standalone ? this.bottomInset + 82 : 14
    })
    .id('taildrive-inline-browser')
  }

  build() {
    if (this.standalone) {
      Stack({ alignContent: Alignment.Bottom }) {
        this.StandaloneNavigation()
        if (this.folderDialogVisible) {
          this.FolderDialog()
        }
        this.SheetHosts()
      }
      .width('100%')
      .height('100%')
    } else {
      Column() {
        this.BrowserContent()
        this.SheetHosts()
      }
      .width('100%')
      .backgroundColor($r('app.color.surface_subtle'))
      .borderRadius(16)
    }
  }
}
