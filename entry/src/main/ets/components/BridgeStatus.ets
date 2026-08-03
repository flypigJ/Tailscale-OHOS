import nativeBridge from 'libtailscale_ohos.so';
import { bundleManager, common, CompletionHandlerForAbilityStartCallback, Want } from '@kit.AbilityKit';
import { BusinessError, deviceInfo, pasteboard } from '@kit.BasicServicesKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { LengthMetrics } from '@kit.ArkUI';
import { media } from '@kit.MediaKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import {
  DiagnosticReportInput,
  DiagnosticReportResult
} from '../services/DiagnosticReportService';
import {
  AccountDiagnosticsGateway,
  AccountDiagnosticsRequestGuard,
  NativeBridgeDiagnosticStatus
} from '../services/AccountDiagnosticsGateway';
import { DeviceNameService } from '../services/DeviceNameService';
import {
  HomeReadOnlyGateway,
  HomeReadOnlyRequestGuard,
  HomeTrafficStatus,
  parseHomeTrafficStatus
} from '../services/HomeReadOnlyGateway';
import {
  VpnCommandGateway,
  VpnCommandState,
  VpnCommandStateMachine,
  VpnCoreCommand
} from '../services/VpnCommandGateway';
import {
  NetworkSettingKey,
  NetworkSettingsGateway,
  NetworkSettingsUpdateQueue,
  PendingNetworkSettingsUpdate
} from '../services/NetworkSettingsGateway';
import { TaildropSendGateway } from '../services/TaildropSendGateway';
import { TaildropContentGateway } from '../services/TaildropContentGateway';
import {
  TaildropNotificationActionRequest,
  TaildropReceiveGateway,
  TaildropReceiveRequest,
  TaildropReceiveResult
} from '../services/TaildropReceiveGateway';
import { APP_FOREGROUND_EVENT } from '../services/AppLifecycleEvents';
import { SunshineProbeService } from '../services/SunshineProbeService';
import { PeerPathService } from '../services/PeerPathService';
import { MoonlightLauncher } from '../services/MoonlightLauncher';
import { buildStreamProfile } from '../services/StreamProfileBuilder';
import { PeerPathResult, StreamLaunchProfile, SunshineProbeResult } from '../services/StreamingModels';
import { HosPlayerLauncher } from '../services/HosPlayerLauncher';
import {
  DiscoveredMediaService,
  HosPlayerLaunchRequest,
  MediaProbeResult
} from '../services/MediaIntegrationModels';
import { MediaServiceProbeService } from '../services/MediaServiceProbeService';
import { SunshineStatusBadge } from './SunshineStatusBadge';
import { MediaStatusBadge } from './MediaStatusBadge';
import { DeviceConnectionInfoPanel } from './DeviceConnectionInfoPanel';
import { DeviceActionButtons } from './DeviceActionButtons';
import { CompactConnectedHomeHeader } from './CompactConnectedHomeHeader';
import { ConnectionDetailsSheet } from './ConnectionDetailsSheet';
import { MotionTokens } from './MotionTokens';
import { HomeConnectionSection } from './HomeConnectionSection';
import { LegacyConnectedHomeHeader } from './LegacyConnectedHomeHeader';
import { ConnectedHomeLayoutMode, DEFAULT_CONNECTED_HOME_LAYOUT } from './HomeLayoutConfig';
import {
  HomeContentLayout,
  ResponsiveLayout,
  ResponsiveNavigationMode,
  SettingsContentLayout,
  TransferContentLayout
} from './ResponsiveLayout';
import {
  BlurStrategy,
  DividerMode,
  HdsNavigation,
  HdsNavigationTitleMode,
  HdsTabs,
  HdsTabsController,
  ScrollEffectType,
  hdsEffect,
  hdsMaterial
} from '@kit.UIDesignKit';
import {
  ControlServerSettings,
  DEFAULT_CONTROL_SERVER_URL
} from '../services/ControlServerConfig';
import {
  SettingsPreferencesGateway,
  SettingsRequestGuard
} from '../services/SettingsPreferencesGateway';
import { DiagnosticPrivacy } from '../services/DiagnosticPrivacy';
import { RecoverableCachePaths } from '../services/RecoverableCachePaths';

const MIN_CONNECTION_LOADING_MS: number = 250;
const CONNECTION_START_FRAME_DELAY_MS: number = 32;
const CONNECTION_POLL_INTERVAL_MS: number = 250;
const BACKEND_READINESS_POLL_INTERVAL_MS: number = 250;
const CACHE_SIZE_POLL_INTERVAL_MS: number = 500;
const VPN_HEARTBEAT_FRESH_MS: number = 5000;
const VPN_HEARTBEAT_CONFIRM_TIMEOUT_MS: number = 2500;
const VPN_CONNECTED_GRACE_MS: number = 8000;
const FILE_WATCH_CLOSE_WRITE: number = 0x8;
const FAST_RECONNECT_TTL_MS: number = 15000;
const VPN_STOP_POLL_INTERVAL_MS: number = 50;
const VPN_STOP_POLL_MAX_ATTEMPTS: number = 150;
const VPN_BACKEND_HANDOFF_REQUEST_FILE_NAME: string = 'vpn-backend-handoff-request.json';
const VPN_BACKEND_HANDOFF_RESPONSE_FILE_NAME: string = 'vpn-backend-handoff-response.json';
const TAILDROP_SEND_REQUEST_FILE_NAME: string = 'taildrop-send-request.json';
const TAILDROP_TARGETS_FILE_NAME: string = 'taildrop-targets.json';
const TAILDROP_CANCEL_REQUEST_FILE_NAME: string = 'taildrop-cancel-request.json';
const TAILDROP_INBOX_DIR_NAME: string = 'taildrop-inbox-export';
const TAILDROP_RECEIVE_REQUEST_FILE_NAME: string = 'taildrop-receive-request.json';
const TAILDROP_RECEIVE_RESPONSE_FILE_NAME: string = 'taildrop-receive-response.json';
const TAILDROP_HISTORY_FILE_NAME: string = 'taildrop-history.json';
const TAILDROP_INBOX_SNAPSHOT_FILE_NAME: string = 'taildrop-inbox-snapshot.json';
const TAILDROP_HISTORY_MEDIA_DIR_NAME: string = 'taildrop-history-media';
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
const TAILDROP_TEXT_CLIPBOARD_MAX_BYTES: number = 1024 * 1024;
const TAILDROP_IMAGE_EXTENSIONS: string[] = [
  'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'dng'
];
const TAILDROP_VIDEO_EXTENSIONS: string[] = [
  'mp4', 'mov', 'm4v', '3gp', '3g2', 'mkv', 'webm'
];
const TAILDROP_TEXT_EXTENSIONS: string[] = [
  'txt', 'md', 'markdown', 'csv', 'tsv', 'json', 'json5', 'xml', 'yaml', 'yml', 'log',
  'ini', 'conf', 'cfg', 'properties', 'env', 'sql', 'sh', 'ps1', 'bat', 'cmd', 'py',
  'js', 'ts', 'ets', 'css', 'html', 'htm', 'java', 'kt', 'go', 'rs', 'c', 'cc', 'cpp',
  'h', 'hpp'
];
const VPN_PEERS_FILE_NAME: string = 'vpn-peers.json';
const VPN_STOP_REQUEST_FILE_NAME: string = 'vpn-stop-request.json';
const VPN_STOP_RESPONSE_FILE_NAME: string = 'vpn-stop-response.json';
const VPN_CONNECT_CONFIG_FILE_NAME: string = 'vpn-connect-config.json';
const WELCOME_ACKNOWLEDGED_FILE_NAME: string = 'welcome-acknowledged';
const FEEDBACK_EMAIL: string = 'zzx15821178583@gmail.com';

interface ExitNodeChoice {
  id: string;
  name: string;
  online: boolean;
  selected: boolean;
}

interface PeerSummary {
  key: string;
  name: string;
  os: string;
  osVersion?: string;
  deviceModel: string;
  deviceType: string;
  addresses: string[];
  online: boolean;
  exitNode: boolean;
  keyExpired: boolean;
  keyExpiryUnixMs: number;
}

interface NetworkSettings {
  routeAll: boolean;
  exitNodeAllowLANAccess: boolean;
}

interface TrafficSample {
  downloadBytesPerSecond: number;
  uploadBytesPerSecond: number;
}

interface VpnBackendHandoffRequest {
  requestId: number;
}

class BrowserStartParameters {
  uri: string;

  constructor(uri: string) {
    this.uri = uri;
  }
}

class SecureLoginAbilityStartCallback {
  completionHandler?: CompletionHandlerForAbilityStartCallback;
  private readonly errorHandler: (code: number, name: string, message: string) => void;

  constructor(errorHandler: (code: number, name: string, message: string) => void) {
    this.errorHandler = errorHandler;
  }

  onError(code: number, name: string, message: string): void {
    this.errorHandler(code, name, message);
  }
}

interface VpnBackendHandoffResponse {
  requestId: number;
  status: string;
}

interface DeviceStreamingState {
  peerKey: string;
  sunshine: SunshineProbeResult;
  path: PeerPathResult;
  checking: boolean;
  launching: boolean;
}

interface DeviceMediaState {
  peerKey: string;
  result: MediaProbeResult;
  checking: boolean;
  launching: boolean;
}

interface MediaProbeSelfTestResult {
  state: string;
  cases: number;
  errorMessage?: string;
}

interface AccountSummary {
  displayName: string;
  loginName: string;
  profilePicURL: string;
  tailnetName: string;
  deviceName: string;
  addresses: string[];
  needsApproval: boolean;
  keyExpired: boolean;
  keyExpiryUnixMs: number;
}

interface TaildropTargetSummary {
  key: string;
  name: string;
  os: string;
  osVersion?: string;
  deviceModel: string;
  deviceType: string;
  online: boolean;
}

interface TaildropSnapshot {
  state: string;
  reason: string;
  targets: TaildropTargetSummary[];
  waitingFiles: TaildropWaitingFileSummary[];
  inboxReason: string;
  transfer: TaildropTransferSummary;
  updatedAtMs?: number;
}

interface TaildropWaitingFileSummary {
  name: string;
  size: number;
  receivedAtMs: number;
}

interface TaildropTransferSummary {
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
  previewPath: string;
  completedAtMs: number;
}

interface TaildropSendFile {
  path: string;
  name: string;
  size: number;
  previewPath: string;
}

interface TaildropSendRequest {
  requestId: number;
  targetKey: string;
  outboxRoot: string;
  files: TaildropSendFile[];
}

interface TaildropCancelRequest {
  requestId: number;
}

interface TaildropMediaPreview {
  requestId: number;
  name: string;
  size: number;
  path: string;
  thumbnailPath: string;
  mediaType: photoAccessHelper.PhotoType;
}

interface TaildropCachedFile {
  requestId: number;
  name: string;
  size: number;
  path: string;
}

interface TaildropTransferRecord {
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

interface PersistedTaildropHistory {
  records: TaildropTransferRecord[];
}

interface PersistedTaildropInbox {
  files: TaildropWaitingFileSummary[];
  inboxReason: string;
  mediaPreviews?: TaildropMediaPreview[];
  cachedFiles?: TaildropCachedFile[];
  pendingDeletes?: TaildropWaitingFileSummary[];
}

interface PersistedPeerSnapshot {
  peers: PeerSummary[];
  updatedAtMs: number;
}

interface VpnStopRequest {
  requestId: number;
}

interface VpnStopResponse {
  requestId: number;
  status: string;
}

interface BackendSnapshot {
  status: string;
  exitNodes: ExitNodeChoice[];
  peers: PeerSummary[];
  networkSettings: NetworkSettings;
  account: AccountSummary;
  taildrop: TaildropSnapshot;
}

function emptyTaildropTransfer(): TaildropTransferSummary {
  return {
    requestId: 0, state: 'idle', reason: '', targetKey: '', targetName: '', fileName: '',
    fileIndex: 0, fileCount: 0, fileBytes: 0, fileSize: 0, bytesSent: 0, totalBytes: 0,
    previewPath: '', completedAtMs: 0
  };
}

function emptyTaildropReceive(): TaildropReceiveResult {
  return {
    requestId: 0, action: '', state: 'idle', reason: '', name: '', size: 0, path: ''
  };
}

class PeerDataSource implements IDataSource {
  private data: PeerSummary[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.data.length;
  }

  getData(index: number): PeerSummary {
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

  replaceAll(peers: PeerSummary[]): void {
    this.data = [...peers];
    this.listeners.forEach((listener: DataChangeListener) => listener.onDataReloaded());
  }
}

@Component
export struct BridgeStatus {
  @State nativeStatus: string = 'Go Bridge Pending';
  @State engineStatus: string = 'Tailscale Engine Pending';
  @State backendStatus: string = 'Tailscale Backend Stopped';
  @State loginHandoffStatus: string = 'Secure Login Pending';
  @State controlProbeStatus: string = 'Control TLS Probe Pending';
  @State vpnStatus: string = 'HarmonyOS VPN Extension Stopped';
  @State exitNodes: ExitNodeChoice[] = [];
  @State peers: PeerSummary[] = [];
  @State networkSettings: NetworkSettings = {
    routeAll: true,
    exitNodeAllowLANAccess: false
  };
  @State networkSettingStatus: string = '';
  @State accountSummary: AccountSummary = {
    displayName: '',
    loginName: '',
    profilePicURL: '',
    tailnetName: '',
    deviceName: '',
    addresses: [],
    needsApproval: false,
    keyExpired: false,
    keyExpiryUnixMs: 0
  };
  @State avatarLoadFailed: boolean = false;
  @State appVersion: string = '0.9.1';
  @State tailscaleVersion: string = '—';
  @State exitNodeStatus: string = '未使用出口节点';
  @State logoutStatus: string = '';
  @State diagnosticsUnlocked: boolean = false;
  @State diagnosticsExpanded: boolean = false;
  @State diagnosticReportStatus: string = '';
  @State diagnosticReportInProgress: boolean = false;
  @State trafficDownloadBytes: number = 0;
  @State trafficUploadBytes: number = 0;
  @State trafficDownloadRate: number = 0;
  @State trafficUploadRate: number = 0;
  @State trafficSamples: TrafficSample[] = [];
  @State streamingStates: DeviceStreamingState[] = [];
  @State mediaStates: DeviceMediaState[] = [];
  @State mediaSelfTestStatus: string = '';
  @State mediaSelfTestInProgress: boolean = false;
  @State fakeMediaServiceOnline: boolean = false;
  @State taildropState: string = 'disconnected';
  @State taildropReason: string = '';
  @State taildropTargets: TaildropTargetSummary[] = [];
  @State taildropWaitingFiles: TaildropWaitingFileSummary[] = [];
  @State taildropInboxReason: string = '';
  @State taildropTransfer: TaildropTransferSummary = emptyTaildropTransfer();
  @State taildropReceive: TaildropReceiveResult = emptyTaildropReceive();
  @State taildropMediaPreviews: TaildropMediaPreview[] = [];
  @State taildropCachedFiles: TaildropCachedFile[] = [];
  @State taildropHistory: TaildropTransferRecord[] = [];
  @State taildropPreparing: boolean = false;
  @State taildropReceiveInProgress: boolean = false;
  @State taildropMediaSaveInProgress: boolean = false;
  @State @Watch('onTaildropTextEditorVisibilityChanged') taildropTextEditorVisible: boolean = false;
  @State taildropTextPreviewVisible: boolean = false;
  @State taildropTextInput: string = '';
  @State taildropTextInputCanSend: boolean = false;
  @State controlServerInputFocused: boolean = false;
  @State taildropReceivedText: string = '';
  @State taildropTransferRate: number = 0;
  @State taildropTransferEtaSeconds: number = 0;
  @State taildropCancelPending: boolean = false;
  @State loginInProgress: boolean = false;
  @State loginPrompt: ResourceStr = '';
  @State connectInProgress: boolean = false;
  @State exitNodeUpdateInProgress: boolean = false;
  @State routeAllUpdateInProgress: boolean = false;
  @State exitNodeLanUpdateInProgress: boolean = false;
  @State disconnectInProgress: boolean = false;
  @State backendReady: boolean = false;
  @State backendInitializationVisible: boolean = false;
  @State devicesLoading: boolean = true;
  @State hasAuthenticatedSession: boolean = false;
  @State currentTab: number = 0;
  @State activeTab: number = 0;
  @StorageLink('taildropOpenInbox') @Watch('onTaildropOpenInbox') taildropOpenInbox: number = 0;
  @StorageLink('taildropNotificationAction') @Watch('onTaildropNotificationAction')
  taildropNotificationAction: string = '';
  @State controlServerURL: string = DEFAULT_CONTROL_SERVER_URL;
  @State controlServerInput: string = DEFAULT_CONTROL_SERVER_URL;
  @State controlServerConfirmed: boolean = false;
  @State controlServerStatus: string = '';
  @State controlServerEditorVisible: boolean = true;
  @State controlServerTipMessage: string = '';
  @State diagnosticActionStatus: string = '';
  @State diagnosticActionInProgress: boolean = false;
  @State glowLevel: number = 3;
  @State connectedHomeLayoutMode: ConnectedHomeLayoutMode = DEFAULT_CONNECTED_HOME_LAYOUT;
  @State cacheSizeBytes: number = 0;
  @State cacheSizeLoading: boolean = true;
  @State cacheClearInProgress: boolean = false;
  @State connectionDetailsVisible: boolean = false;
  @State homeTitleCompact: boolean = false;
  @State layoutWidth: number = 360;
  @State layoutHeight: number = 640;
  @State selectedPeerKey: string = '';
  @State expandedPeerKeys: string[] = [];
  private connectionPollTimer: number = -1;
  private connectionStatusWatcher?: fileIo.Watcher;
  private connectionCompletionTimer: number = -1;
  private connectionStartedAtMs: number = 0;
  private backendReadinessPollTimer: number = -1;
  private backendRestartDeferred: boolean = false;
  private vpnBackendWasRunningBeforeConnect: boolean = false;
  private vpnBackendHandoffInFlight: boolean = false;
  private vpnFailedExtensionRecoveryInFlight: boolean = false;
  private cachedVpnConnectConfig: string = '';
  private cachedVpnConnectConfigAtMs: number = 0;
  private healthPollTimer: number = -1;
  private loginPollTimer: number = -1;
  private homeScroller: Scroller = new Scroller();
  private transferScroller: Scroller = new Scroller();
  private transferScrollAnchorY: number = 0;
  private transferScrollRestoreTimer: number = -1;
  private settingsScroller: Scroller = new Scroller();
  private settingsScrollAnchorY: number = 0;
  private settingsScrollRestoreTimer: number = -1;
  private homePeerScroller: Scroller = new Scroller();
  private homePeerScrollAnchorIndex: number = 0;
  private tabsController: HdsTabsController = new HdsTabsController();
  private diagnosticsTapCount: number = 0;
  private diagnosticsLastTapMs: number = 0;
  private lifecycleTimers: number[] = [];
  private lifecycleGeneration: number = 0;
  private appShellReady: boolean = false;
  private externalTabNavigationTimer: number = -1;
  private pendingExternalTabIndex: number = -1;
  private cacheRefreshScheduled: boolean = false;
  private cacheSizeRefreshInFlight: boolean = false;
  private cacheSizeRefreshTimer: number = -1;
  private cacheSizePollTimer: number = -1;
  private cacheClearRequestedFromSettings: boolean = false;
  private taildropCacheExpirationCheckedAtMs: number = 0;
  private refreshInFlight: boolean = false;
  private backendRestartPromise: Promise<void> | undefined = undefined;
  private homeReadOnlyGateway: HomeReadOnlyGateway = new HomeReadOnlyGateway();
  private homeReadOnlyRequestGuard: HomeReadOnlyRequestGuard = new HomeReadOnlyRequestGuard();
  private settingsPreferencesGateway: SettingsPreferencesGateway = new SettingsPreferencesGateway();
  private settingsRequestGuard: SettingsRequestGuard = new SettingsRequestGuard();
  private accountDiagnosticsGateway: AccountDiagnosticsGateway = new AccountDiagnosticsGateway();
  private accountRequestGuard: AccountDiagnosticsRequestGuard =
    new AccountDiagnosticsRequestGuard();
  private diagnosticProbeRequestGuard: AccountDiagnosticsRequestGuard =
    new AccountDiagnosticsRequestGuard();
  private diagnosticReportRequestGuard: AccountDiagnosticsRequestGuard =
    new AccountDiagnosticsRequestGuard();
  private diagnosticMediaRequestGuard: AccountDiagnosticsRequestGuard =
    new AccountDiagnosticsRequestGuard();
  private diagnosticActionRequestGuard: AccountDiagnosticsRequestGuard =
    new AccountDiagnosticsRequestGuard();
  private logoutInProgress: boolean = false;
  private vpnCommandGateway: VpnCommandGateway = new VpnCommandGateway();
  private vpnCommandStateMachine: VpnCommandStateMachine = new VpnCommandStateMachine();
  private networkSettingsGateway: NetworkSettingsGateway = new NetworkSettingsGateway();
  private taildropSendGateway: TaildropSendGateway = new TaildropSendGateway();
  private taildropContentGateway: TaildropContentGateway = new TaildropContentGateway();
  private taildropReceiveGateway: TaildropReceiveGateway = new TaildropReceiveGateway();
  private taildropNotificationActionInFlight?: TaildropNotificationActionRequest;
  private exitNodeUpdateQueue: NetworkSettingsUpdateQueue = new NetworkSettingsUpdateQueue();
  private routeAllUpdateQueue: NetworkSettingsUpdateQueue = new NetworkSettingsUpdateQueue();
  private exitNodeLanUpdateQueue: NetworkSettingsUpdateQueue = new NetworkSettingsUpdateQueue();
  private connectCommandId: number = 0;
  private loginCommandId: number = 0;
  private disconnectCommandId: number = 0;
  private exitNodeUpdatePromise: Promise<void> | undefined = undefined;
  private routeAllUpdatePromise: Promise<void> | undefined = undefined;
  private exitNodeLanUpdatePromise: Promise<void> | undefined = undefined;
  private vpnConflictDialogVisible: boolean = false;
  private welcomeDialogVisible: boolean = false;
  private trafficSession: number = 0;
  private trafficLastHeartbeatMs: number = 0;
  private trafficLastDownloadBytes: number = 0;
  private trafficLastUploadBytes: number = 0;
  private lastConfirmedVpnStatus: string = '';
  private lastConfirmedVpnHeartbeatMs: number = 0;
  private vpnStatusGraceActive: boolean = false;
  private vpnHeartbeatObservationStartedAtMs: number = 0;
  private vpnHeartbeatBaselineMs: number = 0;
  private vpnHeartbeatConfirmed: boolean = false;
  private vpnStopPollTimer: number = -1;
  private vpnStopRequestId: number = 0;
  private peerSnapshotSignature: string = '';
  private lastHandledTaildropRequestId: number = 0;
  private taildropRequestSubmittedAtMs: number = 0;
  private taildropProgressSampleRequestId: number = 0;
  private taildropProgressSampleBytes: number = 0;
  private taildropProgressSampleMs: number = 0;
  private taildropReceiveResponseInFlight: boolean = false;
  private taildropReceiveStateStartedAtMs: number = 0;
  private taildropReceiveDestinationUri: string = '';
  private taildropReceiveExpectedSize: number = 0;
  private taildropReceiveMediaType?: photoAccessHelper.PhotoType;
  private taildropReceivePreviewPath: string = '';
  private taildropReceiveThumbnailPath: string = '';
  private taildropReceiveStrategy: string = 'none';
  private taildropPendingDeletes: TaildropWaitingFileSummary[] = [];
  private taildropPendingDeleteRetryAtMs: number = 0;
  private taildropAutoPrefetchKey: string = '';
  private taildropAutoPrefetchFailedKeys: string[] = [];
  private taildropPendingTextPreview?: TaildropWaitingFileSummary;
  private taildropPendingMediaSave?: TaildropWaitingFileSummary;
  private taildropNotificationActionRetryScheduled: boolean = false;
  private taildropPickerOpen: boolean = false;
  private taildropTextTarget?: TaildropTargetSummary;
  private peerDataSource: PeerDataSource = new PeerDataSource();
  private sunshineProbeService?: SunshineProbeService;
  private peerPathService?: PeerPathService;
  private moonlightLauncher?: MoonlightLauncher;
  private mediaServiceProbeService?: MediaServiceProbeService;
  private hosPlayerLauncher?: HosPlayerLauncher;
  private streamingRequestIds: Map<string, number> = new Map();
  private mediaRequestIds: Map<string, number> = new Map();
  private autoProbedPeerSessions: Map<string, number> = new Map();
  private appForegroundListener: () => void = () => this.handleAppForeground();

  private applyPeers(peers: PeerSummary[]): void {
    this.peers = peers;
    this.peerDataSource.replaceAll(peers);
    const onlineKeys: string[] = peers.filter((peer: PeerSummary) => peer.online)
      .map((peer: PeerSummary) => peer.key);
    this.expandedPeerKeys = this.expandedPeerKeys.filter((key: string) => onlineKeys.includes(key));
    this.streamingStates = this.streamingStates.filter((state: DeviceStreamingState) => {
      const peer: PeerSummary | undefined = peers.find((item: PeerSummary) => item.key === state.peerKey);
      if (peer === undefined || !peer.online) {
        this.sunshineProbeService?.cancel(state.peerKey);
        this.peerPathService?.cancel(state.peerKey);
        return false;
      }
      return true;
    });
    this.mediaStates = this.mediaStates.filter((state: DeviceMediaState) => {
      const peer: PeerSummary | undefined = peers.find((item: PeerSummary) => item.key === state.peerKey);
      if (peer === undefined || !peer.online) {
        this.mediaServiceProbeService?.cancel(state.peerKey);
        return false;
      }
      return true;
    });
    if (this.selectedPeerKey.length > 0 && !peers.some((peer: PeerSummary) =>
      peer.key === this.selectedPeerKey)) {
      this.selectedPeerKey = peers.length > 0 ? peers[0].key : '';
    } else if (this.selectedPeerKey.length === 0 && peers.length > 0) {
      this.selectedPeerKey = peers[0].key;
    }
    if (this.isConnected()) {
      this.scheduleLifecycleTask(() => this.autoProbeConnectedPeerServices(), 50);
    }
  }

  aboutToAppear(): void {
    this.lifecycleGeneration++;
    this.appShellReady = true;
    this.homeReadOnlyRequestGuard.invalidate();
    this.accountRequestGuard.invalidate();
    this.diagnosticProbeRequestGuard.invalidate();
    this.diagnosticReportRequestGuard.invalidate();
    this.diagnosticMediaRequestGuard.invalidate();
    this.diagnosticActionRequestGuard.invalidate();
    this.vpnCommandStateMachine.invalidateLifecycle();
    this.onTaildropOpenInbox();
    this.onTaildropNotificationAction();
    this.lastConfirmedVpnStatus = '';
    this.lastConfirmedVpnHeartbeatMs = 0;
    this.vpnStatusGraceActive = false;
    this.vpnHeartbeatObservationStartedAtMs = Date.now();
    this.vpnHeartbeatBaselineMs = 0;
    this.vpnHeartbeatConfirmed = false;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.eventHub.on(APP_FOREGROUND_EVENT, this.appForegroundListener);
    this.loadGlowLevel();
    this.fakeMediaServiceOnline = false;
    this.loadSettingsPreferences(context);
    this.refreshCacheSize();
    this.resetDiagnosticsMode();
    this.backendReady = false;
    this.devicesLoading = true;
    this.verifyNativeBridge();
    this.loadAppVersion();
    this.loadTaildropHistory();
    this.loadPersistedTaildropInbox();
    this.maybeExpireTaildropCache();
    this.scheduleLifecycleTask(() => this.showWelcomeDialogIfNeeded(), 350);
    this.recordDiagnosticEvent('ui_opened', 'lifecycle');
    const vpnIsLive: boolean = this.refreshVpnProbeStatus();
    if (!this.controlServerConfirmed) {
      this.backendStatus = 'Tailscale Backend Stopped | control server not configured';
      this.backendReady = true;
      this.backendInitializationVisible = false;
      this.devicesLoading = false;
      if (vpnIsLive) {
        this.vpnCommandGateway.stopVpnExtension(this.vpnWant()).catch(() => {
          // The extension also refuses to restore its backend without a confirmed server.
        });
      }
      this.scheduleLifecycleTask(() => this.showControlServerTip(), 800);
    } else if (!vpnIsLive) {
      this.startBackend();
      this.scheduleLifecycleTask(() => this.refreshBackendStatus(), 1500);
    } else {
      this.backendReady = true;
      this.backendInitializationVisible = false;
      this.devicesLoading = false;
      this.hasAuthenticatedSession = true;
    }
    // Recheck after the heartbeat freshness window. This covers an extension
    // process that was killed just before the UI appeared (for example during
    // an application update) while its last heartbeat still looked current.
    this.scheduleLifecycleTask(() => {
      if (this.controlServerConfirmed && !this.refreshVpnProbeStatus()) {
        this.refreshOrRecoverBackend(this.lifecycleGeneration);
      }
    }, 6000);
    this.startHealthPolling();
  }

  aboutToDisappear(): void {
    this.lifecycleGeneration++;
    this.appShellReady = false;
    this.externalTabNavigationTimer = -1;
    this.pendingExternalTabIndex = -1;
    this.transferScrollRestoreTimer = -1;
    this.settingsScrollRestoreTimer = -1;
    this.homeReadOnlyRequestGuard.invalidate();
    this.settingsRequestGuard.invalidate();
    this.accountRequestGuard.invalidate();
    this.diagnosticProbeRequestGuard.invalidate();
    this.diagnosticReportRequestGuard.invalidate();
    this.diagnosticMediaRequestGuard.invalidate();
    this.diagnosticActionRequestGuard.invalidate();
    this.vpnCommandStateMachine.invalidateLifecycle();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.eventHub.off(APP_FOREGROUND_EVENT, this.appForegroundListener);
    this.vpnConflictDialogVisible = false;
    this.welcomeDialogVisible = false;
    this.stopConnectionPolling();
    this.clearConnectionCompletionTimer();
    this.stopBackendReadinessPolling();
    this.stopHealthPolling();
    this.stopLoginPolling();
    this.stopCacheSizePolling();
    this.streamingRequestIds.clear();
    this.mediaRequestIds.clear();
    this.streamingStates.forEach((state: DeviceStreamingState) => {
      this.sunshineProbeService?.cancel(state.peerKey);
      this.peerPathService?.cancel(state.peerKey);
    });
    this.mediaStates.forEach((state: DeviceMediaState) => {
      this.mediaServiceProbeService?.cancel(state.peerKey);
    });
    this.stopVpnStopPolling();
    this.clearLifecycleTimers();
    this.resetDiagnosticsMode();
  }

  private handleAppForeground(): void {
    const generation: number = this.lifecycleGeneration;
    const vpnIsLive: boolean = this.refreshVpnProbeStatus();
    this.maybeExpireTaildropCache();
    this.startHealthPolling();
    if (this.activeTab === 2) {
      this.startCacheSizePolling();
    }
    if (!this.controlServerConfirmed) {
      return;
    }
    if (!vpnIsLive) {
      this.refreshOrRecoverBackend(generation);
      return;
    }
    // The VPN Extension runs in a separate process and keeps writing peer
    // snapshots while the UI is suspended. Read once immediately on return,
    // then recheck after its next one-second snapshot so admin-console changes
    // are reflected without restarting the application.
    this.scheduleLifecycleTask(() => this.refreshVpnProbeStatus(), 1200);
  }

  private scheduleLifecycleTask(task: () => void, delayMs: number): number {
    const generation: number = this.lifecycleGeneration;
    const timer: number = setTimeout(() => {
      if (generation === this.lifecycleGeneration) {
        task();
      }
    }, delayMs);
    this.lifecycleTimers.push(timer);
    return timer;
  }

  private clearLifecycleTimers(): void {
    this.lifecycleTimers.forEach((timer: number) => clearTimeout(timer));
    this.lifecycleTimers = [];
  }

  private loadAppVersion(): void {
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
      .then((info: bundleManager.BundleInfo) => {
        this.appVersion = info.versionName;
      })
      .catch(() => {
        // Keep the packaged fallback when bundle metadata is temporarily unavailable.
      });
  }

  private loadSettingsPreferences(context: common.UIAbilityContext): void {
    const settings: ControlServerSettings = this.settingsPreferencesGateway.loadControlServer(context);
    this.controlServerURL = settings.controlURL;
    this.controlServerInput = settings.controlURL;
    this.controlServerConfirmed = settings.confirmed;
    this.controlServerEditorVisible = !settings.confirmed;
    this.controlServerTipMessage = context.resourceManager.getStringSync(
      $r('app.string.control_server_first_run_tip').id);
    this.controlServerStatus = '';
    const requestGeneration: number = this.settingsRequestGuard.begin();
    this.settingsPreferencesGateway.loadConnectedHomeLayout(context)
      .then((mode: ConnectedHomeLayoutMode) => {
        if (this.settingsRequestGuard.isCurrent(requestGeneration)) {
          this.connectedHomeLayoutMode = mode;
        }
      })
      .catch(() => {
        // HomeLayoutPreferences retains the existing default on storage failure.
      });
  }

  private welcomeAcknowledgedPath(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return `${context.filesDir}/${WELCOME_ACKNOWLEDGED_FILE_NAME}`;
  }

  private showWelcomeDialogIfNeeded(): void {
    if (this.welcomeDialogVisible) {
      return;
    }
    const markerPath: string = this.welcomeAcknowledgedPath();
    try {
      if (fileIo.accessSync(markerPath)) {
        return;
      }
    } catch (_error) {
      // A missing marker means this is the first acknowledged launch.
    }
    this.welcomeDialogVisible = true;
    this.getUIContext().showAlertDialog({
      title: $r('app.string.welcome_dialog_title'),
      message: $r('app.string.welcome_dialog_message'),
      autoCancel: false,
      secondaryButton: {
        value: $r('app.string.welcome_dialog_action'),
        action: () => {
          this.writePrivateTextFile(markerPath, 'acknowledged');
          this.welcomeDialogVisible = false;
          this.recordDiagnosticEvent('welcome_dialog_acknowledged', 'first_run');
        }
      }
    });
    this.recordDiagnosticEvent('welcome_dialog_shown', 'first_run');
  }

  private openFeedbackEmail(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.openLink(`mailto:${FEEDBACK_EMAIL}`, { appLinkingOnly: false })
      .then(() => this.recordDiagnosticEvent('feedback_email_opened', 'about'))
      .catch(() => this.showToast($r('app.string.feedback_open_failed')));
  }

  private showControlServerTip(): void {
    if (this.controlServerConfirmed) {
      return;
    }
    this.showToast(this.controlServerTipMessage);
    this.recordDiagnosticEvent('control_server_tip_shown', 'first_run');
  }

  private openControlServerSettings(): void {
    this.navigateToTab(2);
    this.showToast($r('app.string.control_server_required_to_connect'));
  }

  private navigateToTab(index: number): void {
    this.activeTab = index;
    this.updateCacheSizePolling(index);
    if (this.currentTab === index) {
      return;
    }
    // Keep the controlled HdsTabs index in sync as well as asking its
    // controller to switch. On a cold external Want the controller may not
    // have bound yet, while the state value is applied on the first render.
    this.currentTab = index;
    this.tabsController.changeIndex(index);
  }

  private scheduleExternalTabNavigation(index: number): void {
    if (!this.appShellReady) {
      return;
    }
    this.pendingExternalTabIndex = index;
    if (this.externalTabNavigationTimer >= 0) {
      return;
    }
    // AppStorage can be populated before HdsTabs binds its controller on a
    // cold start. Route after the first shell frame without recreating a tab.
    this.externalTabNavigationTimer = this.scheduleLifecycleTask(() => {
      this.externalTabNavigationTimer = -1;
      const targetIndex: number = this.pendingExternalTabIndex;
      this.pendingExternalTabIndex = -1;
      if (targetIndex >= 0) {
        this.navigateToTab(targetIndex);
      }
    }, 32);
  }

  private onTaildropOpenInbox(): void {
    if (this.taildropOpenInbox > 0) {
      this.scheduleExternalTabNavigation(1);
    }
  }

  private onTaildropNotificationAction(): void {
    const request: TaildropNotificationActionRequest | undefined =
      this.taildropReceiveGateway.parseNotificationAction(this.taildropNotificationAction);
    if (request === undefined) {
      return;
    }
    this.scheduleExternalTabNavigation(1);
    if (request.action !== 'save') {
      AppStorage.setOrCreate('taildropNotificationAction', '');
      return;
    }
    const file: TaildropWaitingFileSummary | undefined = this.taildropWaitingFiles.find(
      (candidate: TaildropWaitingFileSummary) =>
        candidate.name === request.fileName && candidate.size === request.size &&
          (request.receivedAtMs < 0 || candidate.receivedAtMs === request.receivedAtMs));
    if (file !== undefined) {
      if (!this.taildropReceiveGateway.claimNotificationAction(request)) {
        AppStorage.setOrCreate('taildropNotificationAction', '');
        return;
      }
      this.taildropNotificationActionInFlight = request;
      AppStorage.setOrCreate('taildropNotificationAction', '');
      this.taildropNotificationActionRetryScheduled = false;
      this.saveTaildropFileFromNotification(file);
    } else if (!this.taildropNotificationActionRetryScheduled) {
      this.taildropNotificationActionRetryScheduled = true;
      this.scheduleLifecycleTask(() => {
        this.taildropNotificationActionRetryScheduled = false;
        this.onTaildropNotificationAction();
      }, 800);
    }
  }

  private saveTaildropFileFromNotification(file: TaildropWaitingFileSummary): void {
    if (this.taildropSendActive() || this.taildropReceiveInProgress) {
      this.showToast($r('app.string.transfer_busy_message'));
      this.releaseTaildropNotificationActionClaim();
      return;
    }
    const kind: string = this.taildropContentKind(file);
    if (kind === 'text') {
      const cached: TaildropCachedFile | undefined = this.findTaildropCachedFile(file);
      if (cached !== undefined) {
        if (this.showCachedTaildropTextPreview(cached)) {
          this.copyTaildropTextPreview();
        } else {
          this.releaseTaildropNotificationActionClaim();
        }
      } else {
        this.startTaildropReceive(file);
      }
      return;
    }
    if (kind === 'image' || kind === 'video') {
      const preview: TaildropMediaPreview | undefined = this.findTaildropMediaPreview(file);
      if (preview !== undefined) {
        this.releaseTaildropNotificationActionClaim();
        this.showToast($r('app.string.transfer_media_ready_to_save'));
      } else {
        this.releaseTaildropNotificationActionClaim();
        this.startTaildropReceive(file);
      }
      return;
    }
    this.startPreparedTaildropFileSave(file);
  }

  private toggleControlServerEditor(): void {
    const visible: boolean = !this.controlServerEditorVisible;
    this.controlServerEditorVisible = visible;
    this.recordDiagnosticEvent(visible ? 'control_server_editor_opened' :
      'control_server_editor_closed', 'account');
  }

  private saveControlServer(): void {
    if (this.isConnected() || this.isConnecting()) {
      this.controlServerStatus = 'disconnect';
      this.recordDiagnosticEvent('control_server_confirm_blocked', 'connected');
      return;
    }
    const normalized: string = this.settingsPreferencesGateway.normalizeControlServer(this.controlServerInput);
    if (normalized.length === 0) {
      this.controlServerStatus = 'invalid';
      this.recordDiagnosticEvent('control_server_confirm_failed', 'invalid');
      return;
    }
    if (this.settingsPreferencesGateway.requiresHttpControlServerRisk({
      controlURL: this.controlServerURL,
      confirmed: this.controlServerConfirmed,
      updatedAtMs: 0
    }, normalized)) {
      this.confirmHttpControlServerRisk(normalized);
      return;
    }
    this.persistControlServer(normalized);
  }

  private confirmHttpControlServerRisk(normalized: string): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.control_server_http_risk_title'),
      message: $r('app.string.control_server_http_risk_message'),
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.control_server_http_risk_cancel'),
        action: () => this.recordDiagnosticEvent('control_server_http_risk_cancelled', 'confirmation')
      },
      secondaryButton: {
        value: $r('app.string.control_server_http_risk_confirm'),
        fontColor: $r('app.color.status_warning'),
        action: () => this.persistControlServer(normalized)
      }
    });
    this.recordDiagnosticEvent('control_server_http_risk_shown', 'confirmation');
  }

  private persistControlServer(normalized: string): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const settings: ControlServerSettings | undefined =
      this.settingsPreferencesGateway.confirmControlServer(context, normalized);
    if (settings === undefined) {
      this.controlServerStatus = 'failed';
      this.recordDiagnosticEvent('control_server_confirm_failed', 'storage');
      return;
    }
    const changed: boolean = !this.controlServerConfirmed || this.controlServerURL !== settings.controlURL;
    this.controlServerURL = settings.controlURL;
    this.controlServerInput = settings.controlURL;
    this.controlServerConfirmed = true;
    this.controlServerStatus = 'saved';
    this.recordDiagnosticEvent('control_server_confirmed',
      settings.controlURL === DEFAULT_CONTROL_SERVER_URL ? 'official' : 'custom');
    this.controlServerEditorVisible = false;
    if (changed) {
      const completionGeneration: number = this.settingsRequestGuard.begin();
      this.backendReady = false;
      this.backendInitializationVisible = true;
      this.devicesLoading = true;
      // A first-run confirmation has no backend to stop. Avoid adding a
      // needless async stop/start window before the first login request.
      const stopPromise: Promise<string> = this.backendStatus.includes('control server not configured') ?
        Promise.resolve('OK | backend already stopped') : this.vpnCommandGateway.stopBackend();
      const restartPromise: Promise<void> = stopPromise
        .catch(() => 'FAILED | backend stop')
        .then(() => {
          if (!this.settingsRequestGuard.isCurrent(completionGeneration)) {
            return;
          }
          this.startBackend();
          this.scheduleLifecycleTask(() => this.refreshBackendStatus(), 1500);
        });
      this.backendRestartPromise = restartPromise;
      restartPromise.then(() => {
        if (this.backendRestartPromise === restartPromise) {
          this.backendRestartPromise = undefined;
        }
      }, () => {
        if (this.backendRestartPromise === restartPromise) {
          this.backendRestartPromise = undefined;
        }
      });
    }
  }

  private controlServerStatusText(): ResourceStr {
    switch (this.controlServerStatus) {
      case 'saved':
        return $r('app.string.control_server_saved');
      case 'disconnect':
        return $r('app.string.control_server_disconnect_first');
      case 'failed':
        return $r('app.string.control_server_save_failed');
      default:
        return $r('app.string.control_server_invalid');
    }
  }

  private verifyNativeBridge(): void {
    const status: NativeBridgeDiagnosticStatus = this.accountDiagnosticsGateway.inspectNativeBridge();
    this.nativeStatus = status.nativeStatus;
    if (status.tailscaleVersion.length > 0) {
      this.tailscaleVersion = status.tailscaleVersion;
    }
  }

  private async probeUserspaceEngine(): Promise<void> {
    const requestGeneration: number = this.diagnosticProbeRequestGuard.begin();
    const result: string = await this.accountDiagnosticsGateway.probeEngine();
    if (this.diagnosticProbeRequestGuard.isCurrent(requestGeneration)) {
      this.engineStatus = result;
    }
  }

  private startBackend(showInitialization: boolean = true): void {
    this.backendRestartDeferred = false;
    if (!this.controlServerConfirmed) {
      this.backendStatus = 'Tailscale Backend Stopped | control server not configured';
      this.backendReady = true;
      this.backendInitializationVisible = false;
      this.devicesLoading = false;
      return;
    }
    this.peerSnapshotSignature = '';
    this.backendReady = false;
    this.backendInitializationVisible = showInitialization;
    this.devicesLoading = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.recordDiagnosticEvent('backend_start_requested', showInitialization ? 'visible' : 'silent');
      this.backendStatus = this.vpnCommandGateway.startBackend(
        `${context.filesDir}/tailscale`, this.deviceModel(), this.harmonyOSHostinfoVersion(), this.controlServerURL);
      this.startBackendReadinessPolling();
    } catch (error) {
      this.recordDiagnosticEvent('backend_start_failed', 'start');
      this.backendStatus = DiagnosticPrivacy.formatNativeFailure('Tailscale Backend Failed', error);
      this.backendReady = true;
      this.backendInitializationVisible = false;
      this.devicesLoading = false;
    }
  }

  private deviceModel(): string {
    return DeviceNameService.model();
  }

  private harmonyOSVersion(): string {
    const majorVersion: number = Number(deviceInfo.majorVersion);
    const seniorVersion: number = Number(deviceInfo.seniorVersion);
    if (majorVersion > 0) {
      return `${majorVersion}.${Math.max(0, seniorVersion)}`;
    }
    const osFullName: string = deviceInfo.osFullName.trim();
    const fullNameMatch: RegExpMatchArray | null = osFullName.match(/(\d+)\.(\d+)/);
    if (fullNameMatch !== null) {
      return `${fullNameMatch[1]}.${fullNameMatch[2]}`;
    }
    const displayVersion: string = deviceInfo.displayVersion.trim();
    const displayMatch: RegExpMatchArray | null = displayVersion.match(/(\d+)\.(\d+)/);
    if (displayMatch !== null) {
      return `${displayMatch[1]}.${displayMatch[2]}`;
    }
    return displayVersion.length > 0 ? displayVersion : '—';
  }

  private harmonyOSHostinfoVersion(): string {
    const candidates: string[] = [deviceInfo.osFullName.trim(), deviceInfo.displayVersion.trim()];
    for (let index: number = 0; index < candidates.length; index++) {
      const match: RegExpMatchArray | null = candidates[index].match(
        /(?:harmonyos|openharmony)?[\s_-]*(\d+)\.(\d+)/i);
      if (match !== null) {
        return `${match[1]}.${match[2]}`;
      }
    }
    const compactVersion: string = this.harmonyOSVersion();
    return compactVersion;
  }

  private async refreshBackendStatus(): Promise<void> {
    if (!this.controlServerConfirmed) {
      this.backendStatus = 'Tailscale Backend Stopped | control server not configured';
      this.backendReady = true;
      this.backendInitializationVisible = false;
      this.devicesLoading = false;
      return;
    }
    if (this.refreshInFlight) {
      return;
    }
    const generation: number = this.lifecycleGeneration;
    const homeReadGeneration: number = this.homeReadOnlyRequestGuard.begin();
    this.refreshInFlight = true;
    try {
      const snapshot: BackendSnapshot = await this.homeReadOnlyGateway.readBackendSnapshot<BackendSnapshot>();
      if (generation !== this.lifecycleGeneration || !this.homeReadOnlyRequestGuard.isCurrent(homeReadGeneration)) {
        return;
      }
      this.backendStatus = snapshot.status;
      if (!this.isConnected()) {
        this.applyBackendTaildropSnapshot(snapshot.taildrop);
      }
      if (this.backendStatus.includes('state=Running')) {
        this.backendReady = true;
        this.backendInitializationVisible = false;
        this.devicesLoading = false;
        this.hasAuthenticatedSession = true;
        if (!this.exitNodeUpdateInProgress) {
          this.exitNodes = snapshot.exitNodes;
        }
        this.applyPeers(snapshot.peers);
        if (!this.routeAllUpdateInProgress && !this.exitNodeLanUpdateInProgress) {
          this.networkSettings = snapshot.networkSettings;
        }
        this.applyAccountSummary(snapshot.account);
        this.completeSecureLoginAfterAuthentication();
      } else if (snapshot.account.needsApproval || this.backendStatus.includes('NeedsMachineAuth')) {
        this.backendReady = true;
        this.backendInitializationVisible = false;
        this.devicesLoading = false;
        this.hasAuthenticatedSession = true;
        this.exitNodes = [];
        this.applyPeers([]);
        this.applyAccountSummary(snapshot.account);
        this.completeSecureLoginAfterAuthentication();
      } else if (this.needsLogin()) {
        this.backendReady = true;
        this.backendInitializationVisible = false;
        this.devicesLoading = false;
        this.hasAuthenticatedSession = false;
        this.applyPeers([]);
        this.exitNodes = [];
        this.applyAccountSummary(snapshot.account);
      } else if (this.backendStatus.startsWith('FAILED')) {
        this.backendReady = true;
        this.backendInitializationVisible = false;
        this.devicesLoading = false;
      }
    } catch (error) {
      if (generation !== this.lifecycleGeneration || !this.homeReadOnlyRequestGuard.isCurrent(homeReadGeneration)) {
        return;
      }
      this.backendStatus = DiagnosticPrivacy.formatNativeFailure('Tailscale Backend Failed', error);
      this.backendReady = true;
      this.backendInitializationVisible = false;
      this.devicesLoading = false;
    } finally {
      this.refreshInFlight = false;
    }
  }

  private refreshExitNodes(): void {
    try {
      const choicesText: string = this.networkSettingsGateway.readExitNodes();
      this.exitNodes = JSON.parse(choicesText) as ExitNodeChoice[];
      const selected: ExitNodeChoice | undefined = this.exitNodes.find(
        (choice: ExitNodeChoice) => choice.selected);
      this.exitNodeStatus = selected === undefined ? '未使用出口节点' : `已选择：${selected.name}`;
    } catch (_error) {
      this.exitNodes = [];
      this.exitNodeStatus = '出口节点列表暂不可用';
    }
  }

  private queueExitNodeUpdate(id: string): void {
    this.exitNodeUpdateQueue.enqueue(id);
    this.exitNodeUpdateInProgress = true;
    if (this.exitNodeUpdatePromise === undefined) {
      this.exitNodeUpdatePromise = this.drainExitNodeUpdates();
    }
  }

  private async drainExitNodeUpdates(): Promise<void> {
    while (true) {
      const update: PendingNetworkSettingsUpdate | undefined = this.exitNodeUpdateQueue.beginNext();
      if (update === undefined) {
        break;
      }
      try {
        const status: string = await this.networkSettingsGateway.writeExitNode(update.value);
        if (this.exitNodeUpdateQueue.isCurrent(update.generation)) {
          this.exitNodeStatus = status;
          if (!status.startsWith('FAILED')) {
            this.refreshExitNodes();
            this.refreshBackendStatus();
          }
        }
      } catch (_error) {
        if (this.exitNodeUpdateQueue.isCurrent(update.generation)) {
          this.exitNodeStatus = 'FAILED | exit node | update unavailable';
        }
      } finally {
        this.exitNodeUpdateQueue.finish();
      }
    }
    this.exitNodeUpdateInProgress = false;
    this.exitNodeUpdatePromise = undefined;
  }

  private refreshNetworkSettings(): void {
    try {
      const settingsText: string = this.networkSettingsGateway.readNetworkSettings();
      this.networkSettings = JSON.parse(settingsText) as NetworkSettings;
    } catch (_error) {
      this.networkSettingStatus = 'FAILED | network setting | unavailable';
    }
  }

  private queueNetworkSettingUpdate(key: NetworkSettingKey, enabled: boolean): void {
    const queue: NetworkSettingsUpdateQueue = key === 'routeAll' ?
      this.routeAllUpdateQueue : this.exitNodeLanUpdateQueue;
    queue.enqueue(enabled ? 'true' : 'false');
    if (key === 'routeAll') {
      this.routeAllUpdateInProgress = true;
      if (this.routeAllUpdatePromise === undefined) {
        this.routeAllUpdatePromise = this.drainNetworkSettingUpdates(key, queue);
      }
      return;
    }
    this.exitNodeLanUpdateInProgress = true;
    if (this.exitNodeLanUpdatePromise === undefined) {
      this.exitNodeLanUpdatePromise = this.drainNetworkSettingUpdates(key, queue);
    }
  }

  private async drainNetworkSettingUpdates(key: NetworkSettingKey,
    queue: NetworkSettingsUpdateQueue): Promise<void> {
    while (true) {
      const update: PendingNetworkSettingsUpdate | undefined = queue.beginNext();
      if (update === undefined) {
        break;
      }
      try {
        const status: string = await this.networkSettingsGateway.writeNetworkSetting(key,
          update.value === 'true');
        if (queue.isCurrent(update.generation)) {
          this.networkSettingStatus = status;
          if (!status.startsWith('FAILED')) {
            this.refreshBackendStatus();
          }
        }
      } catch (_error) {
        if (queue.isCurrent(update.generation)) {
          this.networkSettingStatus = 'FAILED | network setting | update unavailable';
        }
      } finally {
        queue.finish();
      }
    }
    if (key === 'routeAll') {
      this.routeAllUpdateInProgress = false;
      this.routeAllUpdatePromise = undefined;
    } else {
      this.exitNodeLanUpdateInProgress = false;
      this.exitNodeLanUpdatePromise = undefined;
    }
    if (!this.routeAllUpdateInProgress && !this.exitNodeLanUpdateInProgress) {
      this.refreshNetworkSettings();
    }
  }

  private openSecureLogin(): void {
    if (this.loginInProgress || !this.controlServerConfirmed) {
      if (!this.controlServerConfirmed) {
        this.openControlServerSettings();
      }
      return;
    }
    this.loginPrompt = $r('app.string.login_loading');
    this.loginInProgress = true;
    this.loginCommandId = this.vpnCommandStateMachine.begin(VpnCoreCommand.LOGIN);
    if (this.loginCommandId === 0) {
      this.loginInProgress = false;
      this.loginPrompt = '';
      return;
    }
    this.loginHandoffStatus = 'Preparing secure login';
    this.stopLoginPolling();
    const restartPromise: Promise<void> | undefined = this.backendRestartPromise;
    if (restartPromise !== undefined) {
      // Control-server confirmation may still be finishing its stop/start
      // transition. Queue the login poll behind it so the first tap cannot
      // race the native backend lifecycle.
      const commandId: number = this.loginCommandId;
      restartPromise.then(() => {
        if (this.vpnCommandStateMachine.isActive(commandId)) {
          this.scheduleSecureLoginPoll(commandId, 150);
        }
      }, () => {
        this.finishSecureLogin(commandId, 'FAILED | backend restart');
      });
      return;
    }
    if (this.backendNeedsStart()) {
      this.startBackend(false);
    }
    // Keep one visible frame for the in-button LoadingProgress before a fast
    // handoff switches the foreground application to the system browser.
    const commandId: number = this.loginCommandId;
    this.scheduleSecureLoginPoll(commandId, 150);
  }

  private scheduleSecureLoginPoll(commandId: number, delayMs: number): void {
    this.loginPollTimer = setTimeout(() => this.pollSecureLogin(0, commandId), delayMs);
  }

  private finishSecureLogin(commandId: number, status: string): void {
    if (!this.vpnCommandStateMachine.isActive(commandId)) {
      return;
    }
    this.loginHandoffStatus = status;
    this.loginInProgress = false;
    this.loginPrompt = '';
    this.vpnCommandStateMachine.complete(commandId, VpnCommandState.NEEDS_LOGIN);
  }

  private completeSecureLoginAfterAuthentication(): void {
    if (!this.loginInProgress || this.loginHandoffStatus !== 'Secure login page opened' ||
      !this.vpnCommandStateMachine.isActive(this.loginCommandId)) {
      return;
    }
    this.loginInProgress = false;
    this.loginPrompt = '';
    this.loginHandoffStatus = 'Secure Login Pending';
    this.vpnCommandStateMachine.complete(this.loginCommandId, VpnCommandState.RUNNING);
  }

  private backendNeedsStart(): boolean {
    return !this.backendReady || this.backendStatus.includes('Stopped') ||
      this.backendStatus.includes('not started') || this.backendStatus.startsWith('FAILED');
  }

  private async openSecureLoginBrowser(context: common.UIAbilityContext,
    authUrl: string): Promise<void> {
    // Type-based launch gives the system browser resolver an explicit target
    // and reports failures through the AbilityStartCallback on real devices.
    try {
      await new Promise<void>((resolve, reject) => {
        const completionHandler: CompletionHandlerForAbilityStartCallback =
          new CompletionHandlerForAbilityStartCallback();
        completionHandler.onRequestSuccess = (_name: string): void => resolve();
        completionHandler.onRequestFailure = (_name: string, failureCode: number, _failureMessage: string): void => {
            this.recordDiagnosticEvent('secure_login_browser_type_failed', 'handoff', failureCode);
            reject(new Error('browser type start failed'));
        };
        const callback: SecureLoginAbilityStartCallback = new SecureLoginAbilityStartCallback(
          (code: number, _name: string, _message: string): void => {
          this.recordDiagnosticEvent('secure_login_browser_type_error', 'handoff', code);
          reject(new Error('browser type start error'));
          }
        );
        callback.completionHandler = completionHandler;
        const browserParameters: BrowserStartParameters = new BrowserStartParameters(authUrl);
        context.startAbilityByType('browser', browserParameters as Object as Record<string, Object>,
          callback as common.AbilityStartCallback)
          .then(() => resolve(), () => reject(new Error('browser type start rejected')));
      });
      return;
    } catch (_error) {
      this.recordDiagnosticEvent('secure_login_browser_type_fallback', 'handoff');
    }

    // Keep the explicit URL Want as a compatibility fallback for devices
    // whose browser resolver does not expose the type-based operation.
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: authUrl,
      entities: ['entity.system.browsable']
    };
    await context.startAbility(want);
  }

  private async pollSecureLogin(attempt: number, commandId: number): Promise<void> {
    if (!this.vpnCommandStateMachine.isActive(commandId)) {
      return;
    }
    try {
      const authUrl: string = await this.vpnCommandGateway.requestLoginUrl();
      if (!this.vpnCommandStateMachine.isActive(commandId)) {
        return;
      }
      const backendStillStarting: boolean = authUrl.startsWith('PENDING') ||
        authUrl === 'FAILED | login URL | backend not ready' ||
        authUrl === 'FAILED | login URL | status unavailable' ||
        authUrl === 'FAILED | login URL | interactive login request';
      if (backendStillStarting) {
        if (attempt >= 60) {
          this.finishSecureLogin(commandId, 'FAILED | login URL | timed out');
          return;
        }
        if (attempt > 0 && attempt % 10 === 0) {
          this.refreshBackendStatus();
          if (this.backendNeedsStart()) {
            this.startBackend(false);
          }
        }
        this.loginPollTimer = setTimeout(() => this.pollSecureLogin(attempt + 1, commandId), 400);
        return;
      }
      if (!authUrl.startsWith('https://') && !authUrl.startsWith('http://')) {
        this.finishSecureLogin(commandId, authUrl.startsWith('FAILED') ? authUrl :
          'FAILED | login URL | rejected unexpected origin');
        return;
      }
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.loginHandoffStatus = 'Opening secure login in system browser';
      this.loginPrompt = $r('app.string.login_browser_prompt');
      this.openSecureLoginBrowser(context, authUrl)
        .then(() => {
          if (!this.vpnCommandStateMachine.isActive(commandId)) {
            return;
          }
          this.recordDiagnosticEvent('secure_login_browser_opened', 'handoff');
          this.loginHandoffStatus = 'Secure login page opened';
          this.refreshBackendStatus();
        })
        .catch(() => {
          if (!this.vpnCommandStateMachine.isActive(commandId)) {
            return;
          }
          this.recordDiagnosticEvent('secure_login_browser_failed', 'handoff');
          this.finishSecureLogin(commandId, 'FAILED | secure browser handoff');
        });
    } catch (error) {
      if (!this.vpnCommandStateMachine.isActive(commandId)) {
        return;
      }
      this.recordDiagnosticEvent('secure_login_browser_failed', 'handoff');
      this.finishSecureLogin(commandId,
        DiagnosticPrivacy.formatNativeFailure('FAILED | secure browser handoff', error));
    }
  }

  private stopLoginPolling(): void {
    if (this.loginPollTimer >= 0) {
      clearTimeout(this.loginPollTimer);
      this.loginPollTimer = -1;
    }
  }

  private runControlProbe(): void {
    if (!this.controlServerConfirmed || this.controlServerURL !== DEFAULT_CONTROL_SERVER_URL) {
      this.controlProbeStatus = 'SKIPPED | Control TLS probe | official backend not selected';
      this.recordDiagnosticEvent('control_probe_skipped', 'backend_selection');
      return;
    }
    try {
      this.controlProbeStatus = this.accountDiagnosticsGateway.probeControl();
    } catch (error) {
      this.controlProbeStatus = DiagnosticPrivacy.formatNativeFailure('Control TLS Probe Failed', error);
    }
  }

  private vpnWant(): Want {
    return {
      bundleName: 'io.github.tailscaleohos',
      abilityName: 'TailscaleVpnExtensionAbility'
    };
  }

  private stageVpnConnectConfig(config: string): boolean {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return this.vpnCommandGateway.stageConnectConfig(context.filesDir,
      VPN_CONNECT_CONFIG_FILE_NAME, config);
  }

  private cacheVpnReconnectConfig(): boolean {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const handoff = this.vpnCommandGateway.readConnectConfig(context.filesDir,
        VPN_CONNECT_CONFIG_FILE_NAME);
      if (handoff === undefined) {
        return false;
      }
      const ageMs: number = Date.now() - handoff.createdAtMs;
      if (handoff.createdAtMs <= 0 || ageMs < 0 || ageMs > FAST_RECONNECT_TTL_MS ||
        handoff.config.length === 0 || handoff.config.length > 8192 || handoff.config.startsWith('FAILED')) {
        return false;
      }
      this.cachedVpnConnectConfig = handoff.config;
      this.cachedVpnConnectConfigAtMs = handoff.createdAtMs;
      return true;
    } catch (_error) {
      return false;
    }
  }

  private tryFastReconnect(commandId: number): boolean {
    const ageMs: number = Date.now() - this.cachedVpnConnectConfigAtMs;
    if (!this.backendRestartDeferred || this.cachedVpnConnectConfig.length === 0 ||
      ageMs < 0 || ageMs > FAST_RECONNECT_TTL_MS) {
      return false;
    }
    if (!this.stageVpnConnectConfig(this.cachedVpnConnectConfig)) {
      this.recordDiagnosticEvent('fast_reconnect_failed', 'persistence');
      return false;
    }
    this.backendRestartDeferred = false;
    this.recordDiagnosticEvent('fast_reconnect_used', 'cached_config');
    this.requestVpnExtensionStart(commandId);
    return true;
  }

  private deferBackendRestart(): boolean {
    if (!this.cacheVpnReconnectConfig()) {
      return false;
    }
    this.backendRestartDeferred = true;
    this.backendReady = true;
    this.backendInitializationVisible = false;
    this.devicesLoading = false;
    this.recordDiagnosticEvent('backend_restart_deferred', 'fast_reconnect_window');
    this.scheduleLifecycleTask(() => {
      if (!this.backendRestartDeferred || this.isConnected() || this.isConnecting() ||
        this.disconnectInProgress) {
        return;
      }
      this.backendRestartDeferred = false;
      this.recordDiagnosticEvent('backend_restart_deferred_completed', 'timeout');
      this.startBackend(false);
    }, FAST_RECONNECT_TTL_MS);
    return true;
  }

  private startBackendReadinessPolling(): void {
    this.stopBackendReadinessPolling();
    this.scheduleBackendReadinessPoll(this.lifecycleGeneration, 0);
  }

  private scheduleBackendReadinessPoll(generation: number, delayMs: number): void {
    this.backendReadinessPollTimer = setTimeout(() => {
      if (generation !== this.lifecycleGeneration || this.isConnected()) {
        return;
      }
      this.refreshBackendStatus().finally(() => {
        if (generation !== this.lifecycleGeneration || this.backendReady ||
          this.backendStatus.startsWith('FAILED') || this.backendStatus.startsWith('STOPPED')) {
          this.stopBackendReadinessPolling();
          return;
        }
        this.scheduleBackendReadinessPoll(generation, BACKEND_READINESS_POLL_INTERVAL_MS);
      });
    }, delayMs);
  }

  private stopBackendReadinessPolling(): void {
    if (this.backendReadinessPollTimer >= 0) {
      clearTimeout(this.backendReadinessPollTimer);
      this.backendReadinessPollTimer = -1;
    }
  }

  private beginVpnConnection(): void {
    if (!this.controlServerConfirmed) {
      this.openControlServerSettings();
      return;
    }
    if (this.connectInProgress || this.disconnectInProgress || this.isConnecting()) {
      return;
    }
    this.connectCommandId = this.vpnCommandStateMachine.begin(VpnCoreCommand.CONNECT);
    if (this.connectCommandId === 0) {
      return;
    }
    this.setConnectInProgress(true);
    void this.beginVpnConnectionAfterExitNodeUpdate();
  }

  private async beginVpnConnectionAfterExitNodeUpdate(): Promise<void> {
    const commandId: number = this.connectCommandId;
    const exitNodeUpdate: Promise<void> | undefined = this.exitNodeUpdatePromise;
    if (exitNodeUpdate !== undefined) {
      await exitNodeUpdate;
    }
    const routeAllUpdate: Promise<void> | undefined = this.routeAllUpdatePromise;
    if (routeAllUpdate !== undefined) {
      await routeAllUpdate;
    }
    const exitNodeLanUpdate: Promise<void> | undefined = this.exitNodeLanUpdatePromise;
    if (exitNodeLanUpdate !== undefined) {
      await exitNodeLanUpdate;
    }
    if (!this.connectInProgress || !this.controlServerConfirmed || !this.vpnCommandStateMachine.isActive(commandId)) {
      return;
    }
    if (this.exitNodeStatus.startsWith('FAILED')) {
      this.setConnectInProgress(false);
      return;
    }
    this.clearConnectionCompletionTimer();
    this.connectionStartedAtMs = Date.now();
    try {
      this.vpnBackendWasRunningBeforeConnect = this.vpnCommandGateway.backendStatus().includes('state=Running');
    } catch (_error) {
      this.vpnBackendWasRunningBeforeConnect = this.backendStatus.includes('state=Running');
    }
    this.recordDiagnosticEvent('connect_requested', 'preflight');
    // Leave one rendering frame for the loading state before native/VPN calls.
    this.scheduleLifecycleTask(() => this.startVpnProbe(commandId), CONNECTION_START_FRAME_DELAY_MS);
  }

  private async startVpnProbe(commandId: number): Promise<void> {
    if (!this.vpnCommandStateMachine.isActive(commandId)) {
      return;
    }
    try {
      if (this.tryFastReconnect(commandId)) {
        return;
      }
      const backendConfig: string = await this.backendVpnConfigWithRecovery(commandId);
      if (!this.vpnCommandStateMachine.isActive(commandId)) {
        return;
      }
      if (backendConfig.startsWith('FAILED')) {
        this.recordDiagnosticEvent('vpn_preflight_failed', 'backend_config');
        this.vpnStatus = 'Sign in to Tailscale before connecting';
        this.clearConnectionCompletionTimer();
        this.setConnectInProgress(false);
        this.vpnCommandStateMachine.complete(commandId, VpnCommandState.NEEDS_LOGIN);
        return;
      }
      if (this.stageVpnConnectConfig(backendConfig)) {
        this.recordDiagnosticEvent('vpn_config_handoff_staged', 'preflight');
      } else {
        this.recordDiagnosticEvent('vpn_config_handoff_failed', 'persistence');
        this.vpnStatus = 'FAILED | VPN preflight | config handoff unavailable';
        this.clearConnectionCompletionTimer();
        this.setConnectInProgress(false);
        this.vpnCommandStateMachine.complete(commandId, VpnCommandState.STOPPED);
        return;
      }
      this.requestVpnExtensionStart(commandId);
    } catch (_error) {
      this.recordDiagnosticEvent('vpn_preflight_failed', 'exception');
      this.vpnStatus = 'FAILED | VPN preflight | backend unavailable';
      this.clearConnectionCompletionTimer();
      this.setConnectInProgress(false);
      this.vpnCommandStateMachine.complete(commandId, VpnCommandState.STOPPED);
    }
  }

  private async backendVpnConfigWithRecovery(commandId: number): Promise<string> {
    let backendConfig: string = await this.vpnCommandGateway.requestVpnConfig();
    if (!backendConfig.startsWith('FAILED')) {
      return backendConfig;
    }
    this.recordDiagnosticEvent('backend_recovery_requested', 'connect_preflight');
    this.startBackend(false);
    for (let attempt: number = 0; attempt < 20; attempt++) {
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 500));
      if (!this.connectInProgress || !this.controlServerConfirmed || !this.vpnCommandStateMachine.isActive(commandId)) {
        return backendConfig;
      }
      backendConfig = await this.vpnCommandGateway.requestVpnConfig();
      if (!backendConfig.startsWith('FAILED')) {
        this.recordDiagnosticEvent('backend_recovery_completed', 'connect_preflight');
        return backendConfig;
      }
    }
    this.recordDiagnosticEvent('backend_recovery_failed', 'connect_preflight');
    return backendConfig;
  }

  private applyAccountSummary(account: AccountSummary): void {
    this.accountSummary = {
      displayName: account.displayName,
      loginName: account.loginName,
      profilePicURL: account.profilePicURL,
      tailnetName: account.tailnetName,
      deviceName: DeviceNameService.withoutHuaweiBrand(
        account.deviceName.length > 0 ? account.deviceName : this.deviceModel()),
      addresses: account.addresses,
      needsApproval: account.needsApproval,
      keyExpired: account.keyExpired,
      keyExpiryUnixMs: account.keyExpiryUnixMs
    };
    this.avatarLoadFailed = false;
  }

  private requestVpnExtensionStart(commandId: number): void {
    this.clearVpnBackendHandoffFiles();
    this.vpnStatus = 'Requesting HarmonyOS VPN authorization';
    this.vpnCommandGateway.startVpnExtension(this.vpnWant())
      .then(() => {
        if (!this.vpnCommandStateMachine.isActive(commandId)) {
          return;
        }
        this.recordDiagnosticEvent('vpn_start_requested', 'system');
        this.vpnStatus = 'HarmonyOS VPN Extension start requested';
        this.startConnectionPolling();
      })
      .catch((error: BusinessError) => {
        if (!this.vpnCommandStateMachine.isActive(commandId)) {
          return;
        }
        this.recordDiagnosticEvent('vpn_start_failed', 'system', error.code);
        this.vpnStatus = `FAILED | VPN start | code=${error.code}`;
        this.clearConnectionCompletionTimer();
        this.setConnectInProgress(false);
        this.vpnCommandStateMachine.complete(commandId, VpnCommandState.STOPPED);
      });
  }

  private stopVpnProbe(): void {
    if (this.disconnectInProgress) {
      return;
    }
    this.lastConfirmedVpnStatus = '';
    this.lastConfirmedVpnHeartbeatMs = 0;
    this.vpnStatusGraceActive = false;
    this.clearConnectionCompletionTimer();
    this.setConnectInProgress(false);
    this.vpnCommandStateMachine.complete(this.connectCommandId, VpnCommandState.STOPPED);
    this.disconnectCommandId = this.vpnCommandStateMachine.begin(VpnCoreCommand.DISCONNECT);
    if (this.disconnectCommandId === 0) {
      return;
    }
    this.disconnectInProgress = true;
    this.recordDiagnosticEvent('disconnect_requested', 'user');
    this.stopVpnStopPolling();
    this.vpnStopRequestId = Date.now();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.vpnCommandGateway.writeCommandFile(context.filesDir, VPN_STOP_RESPONSE_FILE_NAME, '');
    const request: VpnStopRequest = { requestId: this.vpnStopRequestId };
    if (!this.vpnCommandGateway.writeCommandFile(context.filesDir, VPN_STOP_REQUEST_FILE_NAME,
      JSON.stringify(request))) {
      this.finishVpnExtensionStop(this.disconnectCommandId);
      return;
    }
    this.pollVpnStopResponse(0, this.disconnectCommandId);
  }

  private pollVpnStopResponse(attempt: number, commandId: number): void {
    if (!this.disconnectInProgress || !this.vpnCommandStateMachine.isActive(commandId)) {
      return;
    }
    if (attempt >= VPN_STOP_POLL_MAX_ATTEMPTS) {
      this.recordDiagnosticEvent('vpn_backend_stop_timeout', 'disconnect');
      this.vpnCommandStateMachine.timeout(commandId);
      this.finishVpnExtensionStop(commandId);
      return;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const responseText = this.vpnCommandGateway.readCommandFile(context.filesDir,
        VPN_STOP_RESPONSE_FILE_NAME);
      if (responseText !== undefined && responseText.trim().length > 0) {
        const response: VpnStopResponse = JSON.parse(responseText) as VpnStopResponse;
        if (response.requestId === this.vpnStopRequestId) {
          this.vpnCommandGateway.writeCommandFile(context.filesDir, VPN_STOP_RESPONSE_FILE_NAME, '');
          this.backendStatus = response.status;
          this.finishVpnExtensionStop(commandId);
          return;
        }
      }
    } catch (_error) {
      // The Extension may be replacing the response file. Retry briefly before
      // falling back to the lifecycle stop, whose onDestroy path also closes it.
    }
    this.vpnStopPollTimer = setTimeout(() => {
      this.pollVpnStopResponse(attempt + 1, commandId);
    }, VPN_STOP_POLL_INTERVAL_MS);
  }

  private stopVpnStopPolling(): void {
    if (this.vpnStopPollTimer >= 0) {
      clearTimeout(this.vpnStopPollTimer);
      this.vpnStopPollTimer = -1;
    }
  }

  private finishVpnExtensionStop(commandId: number): void {
    this.stopVpnStopPolling();
    this.vpnCommandGateway.stopVpnExtension(this.vpnWant())
      .then(() => {
        if (!this.vpnCommandStateMachine.isActive(commandId) &&
          this.vpnCommandStateMachine.currentState() !== VpnCommandState.TIMED_OUT) {
          this.disconnectInProgress = false;
          return;
        }
        this.recordDiagnosticEvent('disconnect_completed', 'system');
        this.vpnStatus = 'HarmonyOS VPN Extension stopped';
        this.disconnectInProgress = false;
        this.homeTitleCompact = false;
        this.vpnCommandStateMachine.complete(commandId, VpnCommandState.STOPPED);
        this.stopConnectionPolling();
        if (!this.deferBackendRestart()) {
          this.startBackend(false);
          this.scheduleLifecycleTask(() => this.refreshBackendStatus(), 1500);
        }
      })
      .catch((error: BusinessError) => {
        if (!this.vpnCommandStateMachine.isActive(commandId) &&
          this.vpnCommandStateMachine.currentState() !== VpnCommandState.TIMED_OUT) {
          this.disconnectInProgress = false;
          return;
        }
        this.recordDiagnosticEvent('disconnect_failed', 'system', error.code);
        this.vpnStatus = `FAILED | VPN stop | code=${error.code}`;
        this.disconnectInProgress = false;
        this.homeTitleCompact = false;
        this.vpnCommandStateMachine.complete(commandId, VpnCommandState.STOPPED);
      });
  }

  private confirmLogout(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.logout_confirm_title'),
      message: $r('app.string.logout_confirm_message'),
      autoCancel: true,
      backgroundColor: $r('sys.color.comp_background_primary'),
      primaryButton: {
        value: $r('app.string.cancel_action'),
        action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.logout_action'),
        fontColor: $r('app.color.status_error'),
        action: () => this.logout()
      }
    });
  }

  private async logout(): Promise<void> {
    if (this.logoutInProgress) {
      return;
    }
    this.logoutInProgress = true;
    const requestGeneration: number = this.accountRequestGuard.begin();
    try {
      const status: string = await this.accountDiagnosticsGateway.logout();
      if (!this.accountRequestGuard.isCurrent(requestGeneration)) {
        return;
      }
      this.logoutStatus = status;
      if (!this.logoutStatus.startsWith('FAILED')) {
        this.loginInProgress = false;
        this.loginPrompt = '';
        this.hasAuthenticatedSession = false;
        this.stopLoginPolling();
        this.applyPeers([]);
        this.exitNodes = [];
        this.exitNodeStatus = '未使用出口节点';
        this.loginHandoffStatus = 'Secure Login Pending';
        this.scheduleLifecycleTask(() => this.refreshBackendStatus(), 500);
      }
    } catch (_error) {
      if (!this.accountRequestGuard.isCurrent(requestGeneration)) {
        return;
      }
      this.logoutStatus = 'FAILED | logout | unavailable';
    } finally {
      if (this.accountRequestGuard.isCurrent(requestGeneration)) {
        this.logoutInProgress = false;
      }
    }
  }

  private resetTrafficMetrics(): void {
    this.trafficSession = 0;
    this.trafficLastHeartbeatMs = 0;
    this.trafficLastDownloadBytes = 0;
    this.trafficLastUploadBytes = 0;
    this.trafficDownloadBytes = 0;
    this.trafficUploadBytes = 0;
    this.trafficDownloadRate = 0;
    this.trafficUploadRate = 0;
    this.trafficSamples = [];
  }

  private updateTrafficMetrics(status: string, heartbeatMs: number): void {
    if (!status.includes('state=Running')) {
      return;
    }
    const traffic: HomeTrafficStatus = parseHomeTrafficStatus(status);
    const session: number = traffic.session;
    const uploadBytes: number = traffic.uploadBytes;
    const downloadBytes: number = traffic.downloadBytes;
    if (session <= 0 || heartbeatMs <= 0) {
      return;
    }
    if (session !== this.trafficSession || heartbeatMs <= this.trafficLastHeartbeatMs) {
      if (session !== this.trafficSession) {
        this.trafficSession = session;
        this.trafficLastHeartbeatMs = heartbeatMs;
        this.trafficLastDownloadBytes = downloadBytes;
        this.trafficLastUploadBytes = uploadBytes;
        this.trafficDownloadBytes = downloadBytes;
        this.trafficUploadBytes = uploadBytes;
        this.trafficDownloadRate = 0;
        this.trafficUploadRate = 0;
        this.trafficSamples = [{ downloadBytesPerSecond: 0, uploadBytesPerSecond: 0 }];
      }
      return;
    }
    const elapsedMs: number = heartbeatMs - this.trafficLastHeartbeatMs;
    if (elapsedMs <= 0) {
      return;
    }
    const downloadDelta: number = downloadBytes >= this.trafficLastDownloadBytes ?
      downloadBytes - this.trafficLastDownloadBytes : 0;
    const uploadDelta: number = uploadBytes >= this.trafficLastUploadBytes ?
      uploadBytes - this.trafficLastUploadBytes : 0;
    this.trafficDownloadRate = Math.round(downloadDelta * 1000 / elapsedMs);
    this.trafficUploadRate = Math.round(uploadDelta * 1000 / elapsedMs);
    this.trafficDownloadBytes = downloadBytes;
    this.trafficUploadBytes = uploadBytes;
    this.trafficLastHeartbeatMs = heartbeatMs;
    this.trafficLastDownloadBytes = downloadBytes;
    this.trafficLastUploadBytes = uploadBytes;
    const nextSamples: TrafficSample[] = this.trafficSamples.concat({
      downloadBytesPerSecond: this.trafficDownloadRate,
      uploadBytesPerSecond: this.trafficUploadRate
    });
    this.trafficSamples = nextSamples.length > 60 ? nextSamples.slice(nextSamples.length - 60) : nextSamples;
  }

  private formatTrafficBytes(value: number, perSecond: boolean = false): string {
    const suffix: string = perSecond ? '/s' : '';
    if (value < 1024) {
      return `${Math.max(0, Math.round(value))} B${suffix}`;
    }
    if (value < 1024 * 1024) {
      return `${(value / 1024).toFixed(value >= 10240 ? 1 : 2)} KB${suffix}`;
    }
    if (value < 1024 * 1024 * 1024) {
      return `${(value / (1024 * 1024)).toFixed(value >= 10 * 1024 * 1024 ? 1 : 2)} MB${suffix}`;
    }
    return `${(value / (1024 * 1024 * 1024)).toFixed(2)} GB${suffix}`;
  }

  private cacheSizeLabel(): ResourceStr {
    if (this.cacheClearActive()) {
      return $r('app.string.settings_cache_clearing');
    }
    if (this.cacheSizeLoading) {
      return $r('app.string.settings_cache_calculating');
    }
    return this.formatTrafficBytes(this.cacheSizeBytes);
  }

  private cacheDirectorySize(path: string): number {
    if (!fileIo.accessSync(path)) {
      return 0;
    }
    const stat: fileIo.Stat = fileIo.statSync(path);
    if (stat.isFile()) {
      return stat.size;
    }
    if (!stat.isDirectory()) {
      return 0;
    }
    let size: number = 0;
    fileIo.listFileSync(path).forEach((name: string) => {
      size += this.cacheDirectorySize(`${path}/${name}`);
    });
    return size;
  }

  private appCacheRoots(context: common.UIAbilityContext): string[] {
    return [
      context.cacheDir,
      `${context.filesDir}/${TAILDROP_INBOX_DIR_NAME}`,
      `${context.filesDir}/${TAILDROP_HISTORY_MEDIA_DIR_NAME}`
    ];
  }

  private cleanupExpiredCacheEntry(path: string, cutoffMs: number): boolean {
    try {
      const stat: fileIo.Stat = fileIo.statSync(path);
      if (stat.isFile()) {
        if (stat.mtime > 0 && stat.mtime <= cutoffMs) {
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
      if (fileIo.listFileSync(path).length === 0 && stat.mtime > 0 && stat.mtime <= cutoffMs) {
        fileIo.rmdirSync(path);
        return true;
      }
      return changed;
    } catch (_error) {
      return false;
    }
  }

  private cleanupExpiredCacheDirectory(path: string, cutoffMs: number): boolean {
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

  private maybeExpireTaildropCache(): void {
    const nowMs: number = Date.now();
    if (this.taildropCacheExpirationCheckedAtMs > 0 &&
      nowMs - this.taildropCacheExpirationCheckedAtMs < TAILDROP_CACHE_EXPIRATION_CHECK_INTERVAL_MS) {
      return;
    }
    this.taildropCacheExpirationCheckedAtMs = nowMs;
    const cutoffMs: number = nowMs - TAILDROP_CACHE_RETENTION_MS;
    let removedAny: boolean = false;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      removedAny = this.cleanupExpiredCacheDirectory(context.cacheDir, cutoffMs) || removedAny;
      removedAny = this.cleanupExpiredCacheDirectory(this.taildropInboxRoot(), cutoffMs) || removedAny;
      removedAny = this.cleanupExpiredCacheDirectory(this.taildropHistoryMediaRoot(), cutoffMs) || removedAny;
    } catch (_error) {
      // Cache retention is best-effort and must not interrupt file transfer.
    }

    const validPreviews: TaildropMediaPreview[] = this.taildropMediaPreviews.filter(
      (preview: TaildropMediaPreview) => this.validTaildropMediaPreview(preview));
    const validCachedFiles: TaildropCachedFile[] = this.taildropCachedFiles.filter(
      (cached: TaildropCachedFile) => this.validTaildropCachedFile(cached));
    const metadataChanged: boolean = JSON.stringify(validPreviews) !==
      JSON.stringify(this.taildropMediaPreviews) || JSON.stringify(validCachedFiles) !==
      JSON.stringify(this.taildropCachedFiles);
    if (metadataChanged) {
      this.taildropMediaPreviews = validPreviews;
      this.taildropCachedFiles = validCachedFiles;
      this.persistTaildropInbox();
      removedAny = true;
    }
    if (removedAny) {
      this.notifyCacheContentsChanged();
    }
  }

  private taildropWaitingFilesSize(): number {
    let size: number = 0;
    this.taildropWaitingFiles.forEach((file: TaildropWaitingFileSummary) => {
      size += Math.max(0, file.size);
    });
    return size;
  }

  private taildropCacheClearInProgress(): boolean {
    return this.taildropReceiveInProgress && this.taildropReceiveStrategy === 'clear';
  }

  private cacheClearActive(): boolean {
    return this.cacheClearInProgress || this.taildropCacheClearInProgress();
  }

  private notifyCacheContentsChanged(): void {
    if (this.activeTab !== 2 || this.cacheClearInProgress || this.cacheRefreshScheduled) {
      return;
    }
    this.cacheRefreshScheduled = true;
    this.scheduleLifecycleTask(() => {
      this.cacheRefreshScheduled = false;
      this.refreshCacheSize(false);
    }, 80);
  }

  private refreshCacheSize(showLoading: boolean = true): void {
    if (this.cacheClearInProgress || this.cacheSizeRefreshInFlight) {
      return;
    }
    if (showLoading) {
      this.cacheSizeLoading = true;
    }
    this.cacheSizeRefreshInFlight = true;
    const generation: number = this.lifecycleGeneration;
    this.cacheSizeRefreshTimer = setTimeout(() => {
      this.cacheSizeRefreshTimer = -1;
      if (generation !== this.lifecycleGeneration) {
        this.cacheSizeRefreshInFlight = false;
        return;
      }
      try {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        let totalSize: number = 0;
        this.appCacheRoots(context).forEach((path: string) => {
          totalSize += this.cacheDirectorySize(path);
        });
        totalSize += this.taildropWaitingFilesSize();
        if (this.cacheSizeBytes !== totalSize) {
          this.cacheSizeBytes = totalSize;
        }
      } catch (_error) {
        this.cacheSizeBytes = 0;
      } finally {
        this.cacheSizeRefreshInFlight = false;
        this.cacheSizeLoading = false;
      }
    }, 0);
  }

  private startCacheSizePolling(): void {
    if (this.cacheSizePollTimer >= 0) {
      this.refreshCacheSize(false);
      return;
    }
    this.refreshCacheSize();
    this.cacheSizePollTimer = setInterval(() => {
      if (this.activeTab === 2) {
        this.refreshCacheSize(false);
      }
    }, CACHE_SIZE_POLL_INTERVAL_MS);
  }

  private stopCacheSizePolling(): void {
    if (this.cacheSizePollTimer >= 0) {
      clearInterval(this.cacheSizePollTimer);
      this.cacheSizePollTimer = -1;
    }
    if (this.cacheSizeRefreshTimer >= 0) {
      clearTimeout(this.cacheSizeRefreshTimer);
      this.cacheSizeRefreshTimer = -1;
      this.cacheSizeRefreshInFlight = false;
    }
  }

  private updateCacheSizePolling(index: number): void {
    if (index === 2) {
      this.startCacheSizePolling();
    } else {
      this.stopCacheSizePolling();
    }
  }

  private cacheClearBlocked(): boolean {
    return this.cacheClearActive() || this.diagnosticReportInProgress ||
      this.taildropPreparing || this.taildropReceiveInProgress ||
      this.taildropTransfer.state === 'queued' || this.taildropTransfer.state === 'sending';
  }

  private cacheClearEnabled(): boolean {
    return !this.cacheSizeLoading && this.cacheSizeBytes > 0 && !this.cacheClearBlocked();
  }

  private removeCacheEntry(path: string): boolean {
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

  private confirmClearAppCache(): void {
    if (!this.cacheClearEnabled()) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: $r('app.string.settings_clear_cache_confirm_title'),
      message: $r('app.string.settings_clear_cache_confirm_message'),
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.cancel_action'),
        action: () => {
          // Keep the current cache untouched.
        }
      },
      secondaryButton: {
        value: $r('app.string.settings_clear_cache_action'),
        fontColor: $r('sys.color.font_emphasize'),
        action: () => this.clearAppCache()
      }
    });
  }

  private clearAppCache(): void {
    if (this.cacheClearBlocked()) {
      this.showToast($r('app.string.settings_clear_cache_busy'));
      return;
    }
    this.cacheClearInProgress = true;
    this.scheduleLifecycleTask(() => {
      const succeeded: boolean = this.clearAppCacheEntries();
      this.taildropMediaPreviews = [];
      this.taildropCachedFiles = [];
      this.taildropAutoPrefetchFailedKeys = [];
      this.taildropAutoPrefetchKey = '';
      this.taildropHistory = this.taildropHistory.map((record: TaildropTransferRecord) => {
        record.previewPath = '';
        return record;
      });
      this.persistTaildropHistory();
      if (succeeded && this.taildropWaitingFiles.length > 0 && this.taildropState === 'ready') {
        this.cacheClearRequestedFromSettings = true;
        if (this.requestTaildropInboxCacheClear()) {
          return;
        }
        this.cacheClearRequestedFromSettings = false;
        this.finishSettingsCacheClear(false);
        return;
      } else if (succeeded && this.taildropState !== 'ready') {
        this.queueTaildropPendingDeletes(this.taildropWaitingFiles);
        this.clearTaildropInboxViewState();
      }
      this.finishSettingsCacheClear(succeeded);
    }, 0);
  }

  private clearAppCacheEntries(): boolean {
    let succeeded: boolean = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.appCacheRoots(context).forEach((root: string) => {
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

  private clearTaildropInboxViewState(): void {
    this.taildropMediaPreviews = [];
    this.taildropCachedFiles = [];
    this.taildropAutoPrefetchFailedKeys = [];
    this.taildropAutoPrefetchKey = '';
    this.taildropWaitingFiles = [];
    this.taildropInboxReason = '';
    this.persistTaildropInbox();
  }

  private finishSettingsCacheClear(succeeded: boolean): void {
    this.cacheClearRequestedFromSettings = false;
    this.cacheClearInProgress = false;
    this.refreshCacheSize(false);
    this.showToast(succeeded ? $r('app.string.settings_cache_cleared') :
      $r('app.string.settings_clear_cache_failed'));
  }

  private trafficChartWidth(): number {
    return Math.max(220, Math.min(760, this.layoutWidth - this.contentMargin() * 2 - 32));
  }

  private maximumTrafficRate(): number {
    let maximum: number = 1024;
    this.trafficSamples.forEach((sample: TrafficSample) => {
      maximum = Math.max(maximum, sample.downloadBytesPerSecond, sample.uploadBytesPerSecond);
    });
    return maximum;
  }

  private trafficChartPoints(download: boolean, height: number = 68): Array<Array<number>> {
    const width: number = this.trafficChartWidth();
    if (this.trafficSamples.length === 0) {
      return [[0, height - 4], [width, height - 4]];
    }
    const maximum: number = this.maximumTrafficRate();
    const step: number = width / 59;
    const startX: number = width - step * (this.trafficSamples.length - 1);
    const points: Array<Array<number>> = [];
    this.trafficSamples.forEach((sample: TrafficSample, index: number) => {
      const rate: number = download ? sample.downloadBytesPerSecond : sample.uploadBytesPerSecond;
      const y: number = height - 4 - Math.min(1, rate / maximum) * (height - 8);
      points.push([startX + index * step, y]);
    });
    if (points.length === 1) {
      points.unshift([Math.max(0, startX - step), points[0][1]]);
    }
    return points;
  }

  private refreshVpnProbeStatus(): boolean {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const statusPath: string = `${context.filesDir}/vpn-probe-status.txt`;
      if (!fileIo.accessSync(statusPath)) {
        if (this.preserveConfirmedVpnStatus('', 0)) {
          return true;
        }
        this.vpnStatus = 'HarmonyOS VPN Extension Stopped';
        return false;
      }
      const persistedStatus: string = fileIo.readTextSync(statusPath).trim();
      const heartbeatMatch: RegExpMatchArray | null = persistedStatus.match(/heartbeatMs=(\d+)/);
      const heartbeatMs: number = heartbeatMatch === null ? 0 : Number(heartbeatMatch[1]);
      const heartbeatAgeMs: number = Date.now() - heartbeatMs;
      const heartbeatIsFresh: boolean = heartbeatMs > 0 && heartbeatAgeMs >= 0 &&
        heartbeatAgeMs <= VPN_HEARTBEAT_FRESH_MS;
      const visibleStatus: string = persistedStatus.replace(/\s*\|\s*heartbeatMs=\d+/, '');
      this.processVpnBackendHandoffRequest(context.filesDir, visibleStatus);
      let extensionIsLive: boolean = heartbeatIsFresh && !visibleStatus.includes('destroyed');
      if (extensionIsLive && !this.vpnHeartbeatConfirmed) {
        if (this.vpnHeartbeatBaselineMs <= 0) {
          this.vpnHeartbeatBaselineMs = heartbeatMs;
        }
        const heartbeatAdvanced: boolean = heartbeatMs > this.vpnHeartbeatBaselineMs ||
          heartbeatMs >= this.vpnHeartbeatObservationStartedAtMs;
        if (heartbeatAdvanced) {
          this.vpnHeartbeatConfirmed = true;
        } else if (Date.now() - this.vpnHeartbeatObservationStartedAtMs <=
          VPN_HEARTBEAT_CONFIRM_TIMEOUT_MS) {
          // A recent persisted Running state is not proof that the Extension
          // survived a process crash. Wait for one post-launch heartbeat
          // advance before exposing it as connected.
          this.vpnStatus = 'HarmonyOS VPN Extension starting verification';
          return true;
        } else {
          extensionIsLive = false;
        }
      }
      if (extensionIsLive && visibleStatus.includes('state=Running') &&
        visibleStatus.includes('tun=true')) {
        if (this.vpnStatusGraceActive) {
          this.recordDiagnosticEvent('vpn_status_grace_recovered', 'heartbeat');
          this.vpnStatusGraceActive = false;
        }
        this.lastConfirmedVpnStatus = visibleStatus;
        this.lastConfirmedVpnHeartbeatMs = heartbeatMs;
      } else if (this.preserveConfirmedVpnStatus(visibleStatus, heartbeatMs)) {
        return true;
      }
      if (extensionIsLive) {
        this.updateTrafficMetrics(visibleStatus, heartbeatMs);
        if (visibleStatus.includes('state=Running')) {
          this.refreshPeerSnapshot();
        }
        this.refreshTaildropSnapshot(extensionIsLive && visibleStatus.includes('state=Running') &&
          visibleStatus.includes('tun=true'));
        this.checkTaildropReceiveTimeout();
        this.processTaildropReceiveResponse();
      } else {
        this.resetTrafficMetrics();
        this.resetTaildropSnapshot();
        this.resetStreamingStatesForDisconnect();
      }
      const shouldPromptVpnConflict: boolean = extensionIsLive && this.connectInProgress &&
        visibleStatus.includes(`code=2203002`);
      const shouldRecoverFailedExtension: boolean = extensionIsLive && !shouldPromptVpnConflict &&
        this.controlServerConfirmed && visibleStatus.startsWith('FAILED');
      if (extensionIsLive && visibleStatus.includes('state=Running') && this.connectInProgress) {
        const remainingMs: number = MIN_CONNECTION_LOADING_MS -
          (Date.now() - this.connectionStartedAtMs);
        if (remainingMs > 0) {
          if (this.connectionCompletionTimer < 0) {
            this.connectionCompletionTimer = setTimeout(() => {
              this.commitConnectedStatus(visibleStatus);
            }, remainingMs);
          }
          return extensionIsLive;
        }
        this.commitConnectedStatus(visibleStatus);
        return extensionIsLive;
      }
      this.vpnStatus = !extensionIsLive && visibleStatus.includes('tun=true') ?
        'HarmonyOS VPN Extension Stopped (previous session ended)' : visibleStatus;
      this.syncHomeTitleCompact(this.connectedHomeLayoutActive());
      if (!visibleStatus.includes('state=Running')) {
        this.resetStreamingStatesForDisconnect();
      }
      if (extensionIsLive &&
        (visibleStatus.includes('state=Running') || visibleStatus.startsWith('FAILED'))) {
        this.clearConnectionCompletionTimer();
        this.setConnectInProgress(false);
      }
      if (shouldPromptVpnConflict) {
        this.showVpnConflictDialog();
      } else if (shouldRecoverFailedExtension) {
        this.recoverFailedVpnExtension(visibleStatus);
      }
      return extensionIsLive;
    } catch (error) {
      if (this.preserveConfirmedVpnStatus('', 0)) {
        return true;
      }
      const businessError = error as BusinessError;
      this.vpnStatus = `FAILED | VPN status file | code=${businessError.code}`;
      return false;
    }
  }

  private clearVpnBackendHandoffFiles(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.vpnCommandGateway.writeCommandFile(context.filesDir, VPN_BACKEND_HANDOFF_REQUEST_FILE_NAME, '');
    this.vpnCommandGateway.writeCommandFile(context.filesDir, VPN_BACKEND_HANDOFF_RESPONSE_FILE_NAME, '');
  }

  private processVpnBackendHandoffRequest(filesDir: string, visibleStatus: string): void {
    const commandId: number = this.connectCommandId;
    if (!this.connectInProgress || !this.vpnCommandStateMachine.isActive(commandId) ||
      this.vpnBackendHandoffInFlight ||
      !visibleStatus.includes('backend handoff pending')) {
      return;
    }
    try {
      const requestText = this.vpnCommandGateway.readCommandFile(filesDir,
        VPN_BACKEND_HANDOFF_REQUEST_FILE_NAME);
      if (requestText === undefined || requestText.trim().length === 0) {
        return;
      }
      this.vpnCommandGateway.writeCommandFile(filesDir, VPN_BACKEND_HANDOFF_REQUEST_FILE_NAME, '');
      const request: VpnBackendHandoffRequest = JSON.parse(requestText) as VpnBackendHandoffRequest;
      if (request.requestId <= 0) {
        return;
      }
      this.vpnBackendHandoffInFlight = true;
      this.vpnCommandGateway.stopBackend()
        .then((status: string) => {
          if (!this.vpnCommandStateMachine.isActive(commandId)) {
            return;
          }
          this.backendStatus = status;
          this.recordDiagnosticEvent(status.startsWith('OK') ?
            'vpn_backend_handoff_stopped' : 'vpn_backend_handoff_stop_failed', 'vpn_handoff');
          const response: VpnBackendHandoffResponse = { requestId: request.requestId, status: status };
          this.vpnCommandGateway.writeCommandFile(filesDir, VPN_BACKEND_HANDOFF_RESPONSE_FILE_NAME,
            JSON.stringify(response));
        })
        .catch(() => {
          if (!this.vpnCommandStateMachine.isActive(commandId)) {
            return;
          }
          const response: VpnBackendHandoffResponse = {
            requestId: request.requestId,
            status: 'FAILED | backend handoff | stop unavailable'
          };
          this.vpnCommandGateway.writeCommandFile(filesDir, VPN_BACKEND_HANDOFF_RESPONSE_FILE_NAME,
            JSON.stringify(response));
          this.recordDiagnosticEvent('vpn_backend_handoff_stop_failed', 'vpn_handoff');
        })
        .finally(() => {
          this.vpnBackendHandoffInFlight = false;
        });
    } catch (_error) {
      this.vpnCommandGateway.writeCommandFile(filesDir, VPN_BACKEND_HANDOFF_REQUEST_FILE_NAME, '');
    }
  }

  private recoverFailedVpnExtension(failedStatus: string): void {
    if (this.vpnFailedExtensionRecoveryInFlight || this.disconnectInProgress ||
      this.vpnConflictDialogVisible) {
      return;
    }
    this.vpnFailedExtensionRecoveryInFlight = true;
    this.clearVpnBackendHandoffFiles();
    this.recordDiagnosticEvent('vpn_failed_extension_stop_requested', 'recovery');
    const generation: number = this.vpnCommandStateMachine.currentLifecycleGeneration();
    this.vpnCommandGateway.stopVpnExtension(this.vpnWant())
      .then(() => {
        if (generation !== this.vpnCommandStateMachine.currentLifecycleGeneration()) {
          return;
        }
        this.recordDiagnosticEvent('vpn_failed_extension_stopped', 'recovery');
        this.vpnStatus = failedStatus;
        this.startBackend(false);
        this.scheduleLifecycleTask(() => this.refreshBackendStatus(), 1500);
      })
      .catch((error: BusinessError) => {
        if (generation !== this.vpnCommandStateMachine.currentLifecycleGeneration()) {
          return;
        }
        this.recordDiagnosticEvent('vpn_failed_extension_stop_failed', 'recovery', error.code);
      })
      .finally(() => {
        this.vpnFailedExtensionRecoveryInFlight = false;
      });
  }

  private preserveConfirmedVpnStatus(status: string, heartbeatMs: number): boolean {
    if (this.disconnectInProgress || this.lastConfirmedVpnStatus.length === 0 ||
      this.lastConfirmedVpnHeartbeatMs <= 0) {
      return false;
    }
    const confirmedAgeMs: number = Date.now() - this.lastConfirmedVpnHeartbeatMs;
    if (confirmedAgeMs < 0 || confirmedAgeMs > VPN_CONNECTED_GRACE_MS) {
      if (this.vpnStatusGraceActive) {
        this.recordDiagnosticEvent('vpn_status_grace_expired', 'heartbeat');
        this.vpnStatusGraceActive = false;
      }
      return false;
    }
    const normalizedStatus: string = status.toLowerCase();
    const explicitStop: boolean = normalizedStatus.includes('destroyed') ||
      normalizedStatus.includes('disconnect') || normalizedStatus.includes('stopped') ||
      normalizedStatus.startsWith('failed');
    const heartbeatUnavailable: boolean = heartbeatMs <= 0 ||
      Date.now() - heartbeatMs > VPN_HEARTBEAT_FRESH_MS;
    const liveTunTransition: boolean = status.includes('backend starting') ||
      (status.includes('tun=true') &&
        (status.includes('state=NoState') || status.includes('state=Starting')));
    if (explicitStop || (!heartbeatUnavailable && !liveTunTransition)) {
      return false;
    }
    if (!this.vpnStatusGraceActive) {
      this.vpnStatusGraceActive = true;
      this.recordDiagnosticEvent('vpn_status_grace_started',
        liveTunTransition ? 'tun_transition' : 'heartbeat');
    }
    this.vpnStatus = this.lastConfirmedVpnStatus;
    return true;
  }

  private startConnectionPolling(): void {
    this.stopConnectionPolling();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const statusPath: string = `${context.filesDir}/vpn-probe-status.txt`;
    try {
      if (fileIo.accessSync(statusPath)) {
        this.connectionStatusWatcher = fileIo.createWatcher(statusPath, FILE_WATCH_CLOSE_WRITE, () => {
          this.handleConnectionStatusUpdate();
        });
        this.connectionStatusWatcher.start();
      }
    } catch (_error) {
      this.connectionStatusWatcher = undefined;
    }
    this.connectionPollTimer = setInterval(() => {
      this.handleConnectionStatusUpdate();
    }, CONNECTION_POLL_INTERVAL_MS);
  }

  private handleConnectionStatusUpdate(): void {
    this.refreshVpnProbeStatus();
    if (this.vpnStatus.includes('state=Running') || this.vpnStatus.startsWith('FAILED')) {
      this.stopConnectionPolling();
    }
  }

  private stopConnectionPolling(): void {
    if (this.connectionPollTimer >= 0) {
      clearInterval(this.connectionPollTimer);
      this.connectionPollTimer = -1;
    }
    if (this.connectionStatusWatcher !== undefined) {
      try {
        this.connectionStatusWatcher.stop();
      } catch (_error) {
        // The watcher may already have stopped with the Extension process.
      }
      this.connectionStatusWatcher = undefined;
    }
  }

  private clearConnectionCompletionTimer(): void {
    if (this.connectionCompletionTimer >= 0) {
      clearTimeout(this.connectionCompletionTimer);
      this.connectionCompletionTimer = -1;
    }
  }

  private commitConnectedStatus(status: string): void {
    this.clearConnectionCompletionTimer();
    this.vpnStatus = status;
    this.setConnectInProgress(false);
    this.vpnCommandStateMachine.complete(this.connectCommandId, VpnCommandState.RUNNING);
    this.homeTitleCompact = true;
    this.scheduleLifecycleTask(() => this.autoProbeConnectedPeerServices(), 50);
    this.stopConnectionPolling();
  }

  private syncHomeTitleCompact(compact: boolean): void {
    if (this.homeTitleCompact === compact) {
      return;
    }
    this.homeTitleCompact = compact;
  }

  private taildropSnapshotFilePath(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return `${context.filesDir}/${TAILDROP_TARGETS_FILE_NAME}`;
  }

  private peerSnapshotFilePath(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return `${context.filesDir}/${VPN_PEERS_FILE_NAME}`;
  }

  private refreshPeerSnapshot(): void {
    try {
      const path: string = this.peerSnapshotFilePath();
      if (!fileIo.accessSync(path)) {
        return;
      }
      const snapshot: PersistedPeerSnapshot = JSON.parse(
        fileIo.readTextSync(path)) as PersistedPeerSnapshot;
      const ageMs: number = Date.now() - snapshot.updatedAtMs;
      if (snapshot.updatedAtMs <= 0 || ageMs < 0 || ageMs > 5000) {
        return;
      }
      const validPeers: PeerSummary[] = snapshot.peers.filter(
        (peer: PeerSummary) => /^peer-[a-f0-9]{16}$/.test(peer.key) && peer.name.length > 0);
      const signature: string = JSON.stringify(validPeers);
      if (signature === this.peerSnapshotSignature) {
        return;
      }
      this.peerSnapshotSignature = signature;
      this.applyPeers(validPeers);
      this.devicesLoading = false;
    } catch (_error) {
      // The Extension may be replacing the snapshot file. Retry on the next
      // one-second health poll without discarding the last valid device list.
    }
  }

  private hasCachedTaildropReceiveFile(): boolean {
    const receive: TaildropReceiveResult = this.taildropReceive;
    return this.taildropCachedFiles.some((cached: TaildropCachedFile) =>
      cached.requestId === receive.requestId && cached.name === receive.name &&
      cached.size === receive.size && cached.path === receive.path &&
      this.validTaildropCachedFile(cached));
  }

  private canContinueTaildropReceiveOffline(): boolean {
    if (!this.taildropReceiveInProgress) {
      return false;
    }
    if (this.taildropReceiveStrategy === 'media' &&
      (this.taildropReceive.state === 'awaiting_gallery_save' ||
        this.taildropReceive.state === 'saving_gallery')) {
      return true;
    }
    if ((this.taildropReceiveStrategy === 'text-preview' &&
      (this.taildropReceive.state === 'awaiting_text_preview' ||
        this.taildropReceive.state === 'copying_text')) ||
      (this.taildropReceiveStrategy === 'file' &&
        (this.taildropReceive.state === 'selecting_destination' ||
          this.taildropReceive.state === 'exporting'))) {
      return this.hasCachedTaildropReceiveFile();
    }
    return false;
  }

  private resetTaildropSnapshot(): void {
    this.taildropState = 'disconnected';
    this.taildropReason = '';
    this.taildropTargets = [];
    this.taildropAutoPrefetchKey = '';
    this.taildropPendingTextPreview = undefined;
    this.taildropPendingMediaSave = undefined;
    if (this.taildropReceiveInProgress && !this.canContinueTaildropReceiveOffline()) {
      if (this.taildropReceive.state === 'awaiting_gallery_save' ||
        this.taildropReceive.state === 'awaiting_text_preview') {
        this.resetTaildropReceiveOperation();
      } else {
        this.failTaildropReceive('disconnected');
      }
    }
    if (this.taildropTransfer.state === 'queued' || this.taildropTransfer.state === 'sending') {
      this.applyTaildropTransfer(this.taildropTransferFailure(this.taildropTransfer, 'disconnected'));
    }
  }

  private validTaildropTransfer(transfer: TaildropTransferSummary): boolean {
    if (transfer.state !== 'idle' && transfer.state !== 'queued' && transfer.state !== 'sending' &&
      transfer.state !== 'completed' && transfer.state !== 'failed') {
      return false;
    }
    return transfer.requestId >= 0 && transfer.fileIndex >= 0 && transfer.fileCount >= 0 &&
      transfer.fileBytes >= 0 && transfer.fileSize >= 0 && transfer.bytesSent >= 0 &&
      transfer.totalBytes >= 0;
  }

  private taildropTransferFailure(
    transfer: TaildropTransferSummary, reason: string
  ): TaildropTransferSummary {
    return {
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
      previewPath: transfer.previewPath,
      completedAtMs: Date.now()
    };
  }

  private taildropFailureMessage(reason: string): ResourceStr {
    switch (reason) {
      case 'target_unavailable':
      case 'target_offline':
        return $r('app.string.transfer_send_target_unavailable');
      case 'admin_disabled':
        return $r('app.string.transfer_admin_disabled_title');
      case 'disconnected':
        return $r('app.string.transfer_send_disconnected');
      case 'cancelled':
        return $r('app.string.transfer_send_cancelled');
      case 'permission_denied':
        return $r('app.string.transfer_send_permission_denied');
      case 'no_space':
        return $r('app.string.transfer_send_no_space');
      case 'file_unavailable':
        return $r('app.string.transfer_send_file_unavailable');
      case 'file_changed':
        return $r('app.string.transfer_send_file_changed');
      case 'busy':
        return $r('app.string.transfer_busy_message');
      case 'backend_unavailable':
      case 'extension_error':
        return $r('app.string.transfer_send_backend_unavailable');
      case 'timeout':
      case 'network_interrupted':
        return $r('app.string.transfer_send_interrupted');
      default:
        return $r('app.string.transfer_send_failed');
    }
  }

  private applyTaildropTransfer(transfer: TaildropTransferSummary): void {
    if (!this.validTaildropTransfer(transfer)) {
      return;
    }
    if (transfer.state === 'idle' &&
      (this.taildropTransfer.state === 'queued' || this.taildropTransfer.state === 'sending') &&
      Date.now() - this.taildropRequestSubmittedAtMs < 5000) {
      return;
    }
    if (transfer.state === 'idle' && this.taildropTransfer.state === 'queued' &&
      Date.now() - this.taildropRequestSubmittedAtMs >= 5000) {
      this.applyTaildropTransfer(this.taildropTransferFailure(
        this.taildropTransfer, 'extension_error'));
      return;
    }
    if (transfer.requestId === this.taildropTransfer.requestId) {
      if (typeof transfer.previewPath !== 'string') {
        transfer.previewPath = '';
      }
      if (transfer.targetName.length === 0) {
        transfer.targetName = this.taildropTransfer.targetName;
      }
      if (transfer.fileName.length === 0) {
        transfer.fileName = this.taildropTransfer.fileName;
      }
      if (transfer.previewPath.length === 0) {
        transfer.previewPath = this.taildropTransfer.previewPath;
      }
    } else if (typeof transfer.previewPath !== 'string') {
      transfer.previewPath = '';
    }
    this.updateTaildropProgressEstimate(transfer);
    this.taildropTransfer = transfer;
    if (transfer.state === 'completed' || transfer.state === 'failed' || transfer.state === 'idle') {
      this.taildropCancelPending = false;
    }
    if ((transfer.state === 'completed' || transfer.state === 'failed') && transfer.requestId > 0 &&
      transfer.requestId !== this.lastHandledTaildropRequestId) {
      this.lastHandledTaildropRequestId = transfer.requestId;
      const target: TaildropTargetSummary | undefined = this.displayedTaildropTargets().find(
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
        previewPath: transfer.previewPath,
        completedAtMs: transfer.completedAtMs > 0 ? transfer.completedAtMs : Date.now()
      };
      this.taildropHistory = [record].concat(this.taildropHistory).slice(0, TAILDROP_HISTORY_LIMIT);
      this.persistTaildropHistory();
      this.showToast(transfer.state === 'completed' ?
        $r('app.string.transfer_send_completed') : this.taildropFailureMessage(transfer.reason));
    }
  }

  private applyTaildropInboxSnapshot(
    snapshot: TaildropSnapshot, connected: boolean, authoritativeInbox: boolean
  ): void {
    const validTargets: TaildropTargetSummary[] = snapshot.targets.filter(
      (target: TaildropTargetSummary) => /^peer-[a-f0-9]{16}$/.test(target.key) && target.name.length > 0);
    const snapshotReceivedAtMs: number = Date.now();
    const validWaitingFiles: TaildropWaitingFileSummary[] = this.sortTaildropWaitingFiles(
      snapshot.waitingFiles.filter((file: TaildropWaitingFileSummary) =>
        this.isTaildropWaitingFileShapeValid(file)).map(
        (file: TaildropWaitingFileSummary, index: number): TaildropWaitingFileSummary => {
          const existing: TaildropWaitingFileSummary | undefined = this.taildropWaitingFiles.find(
            (candidate: TaildropWaitingFileSummary) =>
              candidate.name === file.name && candidate.size === file.size);
          const receivedAtMs: number = existing !== undefined ? existing.receivedAtMs :
            this.taildropWaitingFileTimestamp(file, snapshotReceivedAtMs - index);
          return { name: file.name, size: file.size, receivedAtMs: receivedAtMs };
        }));
    this.taildropState = snapshot.state;
    this.taildropReason = snapshot.reason;
    if (JSON.stringify(this.taildropTargets) !== JSON.stringify(validTargets)) {
      this.taildropTargets = validTargets;
    }
    const inboxIsAuthoritative: boolean = authoritativeInbox && snapshot.state === 'ready' &&
      snapshot.inboxReason.length === 0;
    if (inboxIsAuthoritative) {
      const pendingDeletesChanged: boolean = this.reconcileTaildropPendingDeletes(validWaitingFiles);
      const displayedWaitingFiles: TaildropWaitingFileSummary[] = validWaitingFiles.filter(
        (file: TaildropWaitingFileSummary) => !this.isTaildropPendingDelete(file));
      const waitingFilesChanged: boolean = JSON.stringify(this.taildropWaitingFiles) !==
        JSON.stringify(displayedWaitingFiles);
      if (waitingFilesChanged) {
        this.taildropWaitingFiles = displayedWaitingFiles;
        this.notifyCacheContentsChanged();
      }
      this.taildropInboxReason = '';
      if (waitingFilesChanged || pendingDeletesChanged) {
        this.persistTaildropInbox();
      }
    } else {
      this.taildropInboxReason = snapshot.inboxReason;
    }
    this.applyTaildropTransfer(snapshot.transfer);
    if (inboxIsAuthoritative) {
      this.submitNextTaildropPendingDelete();
      this.prefetchTaildropInboxFiles(this.taildropWaitingFiles, connected);
    }
  }

  private applyBackendTaildropSnapshot(snapshot: TaildropSnapshot): void {
    if (this.isConnected() || snapshot === undefined ||
      (snapshot.state !== 'ready' && snapshot.state !== 'disabled' && snapshot.state !== 'unavailable')) {
      return;
    }
    this.applyTaildropInboxSnapshot(snapshot, false, true);
  }

  private refreshTaildropSnapshot(connected: boolean = this.isConnected()): void {
    try {
      this.maybeExpireTaildropCache();
      const path: string = this.taildropSnapshotFilePath();
      if (!fileIo.accessSync(path)) {
        this.taildropState = 'loading';
        return;
      }
      const snapshot: TaildropSnapshot = JSON.parse(fileIo.readTextSync(path)) as TaildropSnapshot;
      const updatedAtMs: number = snapshot.updatedAtMs === undefined ? 0 : snapshot.updatedAtMs;
      const ageMs: number = Date.now() - updatedAtMs;
      if (updatedAtMs <= 0 || ageMs < 0 || ageMs > 5000) {
        this.taildropState = 'loading';
        return;
      }
      if (snapshot.state !== 'ready' && snapshot.state !== 'disabled' &&
        snapshot.state !== 'unavailable' && snapshot.state !== 'loading') {
        this.taildropState = 'unavailable';
        this.taildropReason = 'invalid_snapshot';
        this.taildropTargets = [];
        return;
      }
      this.applyTaildropInboxSnapshot(snapshot, connected, connected);
    } catch (_error) {
      // The Extension may be replacing the snapshot file. Keep the previous
      // valid result and retry on the next one-second health poll.
    }
  }

  private startHealthPolling(): void {
    this.stopHealthPolling();
    this.scheduleHealthPoll(this.lifecycleGeneration);
  }

  private scheduleHealthPoll(generation: number): void {
    this.healthPollTimer = setTimeout(() => {
      if (generation !== this.lifecycleGeneration) {
        return;
      }
      const vpnIsLive: boolean = this.refreshVpnProbeStatus();
      const refresh: Promise<void> = vpnIsLive ? Promise.resolve() : this.refreshOrRecoverBackend(generation);
      refresh.finally(() => {
        if (generation === this.lifecycleGeneration) {
          this.scheduleHealthPoll(generation);
        }
      });
    }, this.taildropReceiveInProgress &&
      this.taildropReceive.state !== 'awaiting_gallery_save' &&
      this.taildropReceive.state !== 'awaiting_text_preview' ? 120 : 1000);
  }

  private async refreshOrRecoverBackend(generation: number): Promise<void> {
    // The UI backend is intentionally stopped immediately before launching the
    // VPN extension. Do not mistake that short handoff window for a killed
    // extension and start a second backend against the same state directory.
    if (this.connectInProgress || this.disconnectInProgress || this.backendRestartDeferred ||
      this.vpnFailedExtensionRecoveryInFlight) {
      return;
    }
    await this.refreshBackendStatus();
    if (generation !== this.lifecycleGeneration || !this.controlServerConfirmed ||
      !this.backendStatus.startsWith('STOPPED')) {
      return;
    }
    this.recordDiagnosticEvent('backend_recovery_requested', 'vpn_process_lost');
    this.startBackend(false);
  }

  private stopHealthPolling(): void {
    if (this.healthPollTimer >= 0) {
      clearTimeout(this.healthPollTimer);
      this.healthPollTimer = -1;
    }
  }

  private isConnected(): boolean {
    return this.vpnStatus.includes('state=Running');
  }

  private isConnecting(): boolean {
    return this.connectInProgress ||
      this.vpnStatus.includes('start requested') ||
      this.vpnStatus.includes('authorization') ||
      this.vpnStatus.includes('starting');
  }

  private needsLogin(): boolean {
    return this.backendStatus.includes('NeedsLogin') ||
      this.backendStatus.includes('loginURLReady=true');
  }

  private hasConnectionProblem(): boolean {
    return this.vpnStatus.startsWith('FAILED') || this.backendStatus.startsWith('FAILED');
  }

  private isAuthenticated(): boolean {
    return this.hasAuthenticatedSession;
  }

  private isBackendLoading(): boolean {
    return this.backendInitializationVisible && !this.backendReady && !this.hasConnectionProblem();
  }

  private recordDiagnosticEvent(event: string, phase: string, code: number = 0): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.accountDiagnosticsGateway.recordEvent(context, event, phase, code);
    } catch (_error) {
      // Diagnostic events are best-effort and must not alter app behavior.
    }
  }

  private async generateDiagnosticReport(): Promise<void> {
    if (this.diagnosticReportInProgress) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const requestGeneration: number = this.diagnosticReportRequestGuard.begin();
    this.diagnosticReportInProgress = true;
    this.diagnosticReportStatus = context.resourceManager.getStringSync(
      $r('app.string.diagnostic_report_generating').id);
    this.recordDiagnosticEvent('diagnostic_report_requested', 'generate');
    const input: DiagnosticReportInput = {
      appVersion: this.appVersion,
      tailscaleVersion: this.tailscaleVersion,
      nativeStatus: this.nativeStatus,
      engineStatus: this.engineStatus,
      backendStatus: this.backendStatus,
      vpnStatus: this.vpnStatus,
      peerCount: this.peers.length,
      onlinePeerCount: this.onlinePeerCount(),
      exitNodeCount: this.exitNodes.length,
      exitNodeSelected: this.exitNodes.some((choice: ExitNodeChoice) => choice.selected),
      addressCount: this.accountSummary.addresses.length,
      signedIn: this.isAuthenticated(),
      routeAll: this.networkSettings.routeAll,
      exitNodeAllowLANAccess: this.networkSettings.exitNodeAllowLANAccess
    };
    try {
      const result: DiagnosticReportResult = await this.accountDiagnosticsGateway.generateReport(context, input);
      if (!this.diagnosticReportRequestGuard.isCurrent(requestGeneration)) {
        return;
      }
      const sizeKb: number = Math.max(1, Math.ceil(result.size / 1024));
      this.diagnosticReportStatus = `${result.fileName} (${sizeKb} KB)`;
      this.recordDiagnosticEvent('diagnostic_report_generated', 'share');
      await this.accountDiagnosticsGateway.shareReport(context, result);
      if (!this.diagnosticReportRequestGuard.isCurrent(requestGeneration)) {
        return;
      }
      this.recordDiagnosticEvent('diagnostic_share_opened', 'system');
    } catch (error) {
      if (!this.diagnosticReportRequestGuard.isCurrent(requestGeneration)) {
        return;
      }
      const businessError = error as BusinessError;
      this.recordDiagnosticEvent('diagnostic_report_failed', 'generate', businessError.code ?? -1);
      this.diagnosticReportStatus = context.resourceManager.getStringSync(
        $r('app.string.diagnostic_report_failed').id);
    } finally {
      if (this.diagnosticReportRequestGuard.isCurrent(requestGeneration)) {
        this.diagnosticReportInProgress = false;
      }
    }
  }

  private showVpnConflictDialog(): void {
    if (this.vpnConflictDialogVisible) {
      return;
    }
    this.vpnConflictDialogVisible = true;
    this.recordDiagnosticEvent('vpn_conflict_detected', 'connect', 2203002);
    this.clearConnectionCompletionTimer();
    this.stopConnectionPolling();
    this.setConnectInProgress(false);
    this.clearVpnBackendHandoffFiles();
    this.vpnStatus = 'Stopping this app VPN after system VPN conflict';
    this.recordDiagnosticEvent('vpn_conflict_self_disconnect_requested', 'cleanup');
    this.vpnCommandGateway.stopVpnExtension(this.vpnWant())
      .then(() => this.finishVpnConflictCleanup())
      .catch((error: BusinessError) => {
        this.recordDiagnosticEvent('vpn_conflict_self_disconnect_failed', 'cleanup', error.code);
        this.finishVpnConflictCleanup();
      });
  }

  private finishVpnConflictCleanup(): void {
    if (!this.vpnConflictDialogVisible) {
      return;
    }
    this.vpnStatus = 'HarmonyOS VPN Extension stopped';
    this.recordDiagnosticEvent('vpn_conflict_self_disconnect_completed', 'cleanup');
    this.scheduleLifecycleTask(() => this.openVpnConflictDialog(), 300);
  }

  private openVpnConflictDialog(): void {
    if (!this.vpnConflictDialogVisible) {
      return;
    }
    try {
      this.getUIContext().showAlertDialog({
        title: $r('app.string.vpn_conflict_title'),
        message: $r('app.string.vpn_conflict_message'),
        autoCancel: false,
        primaryButton: {
          value: $r('app.string.vpn_conflict_confirm_action'),
          action: () => this.acknowledgeVpnConflict()
        }
      });
    } catch (_error) {
      this.vpnConflictDialogVisible = false;
      this.finishVpnConflictCancellation(!this.vpnBackendWasRunningBeforeConnect);
    }
  }

  private acknowledgeVpnConflict(): void {
    const restoreBackend: boolean = !this.vpnBackendWasRunningBeforeConnect;
    this.vpnConflictDialogVisible = false;
    this.vpnStatus = 'HarmonyOS VPN Extension stopped';
    this.recordDiagnosticEvent('vpn_conflict_acknowledged', 'dialog');
    this.stopConnectionPolling();
    this.recordDiagnosticEvent('vpn_conflict_confirm_disconnect_requested', 'cleanup');
    this.vpnCommandGateway.stopVpnExtension(this.vpnWant())
      .then(() => {
        this.recordDiagnosticEvent('vpn_conflict_confirm_disconnect_completed', 'cleanup');
        this.finishVpnConflictCancellation(restoreBackend);
      })
      .catch((error: BusinessError) => {
        this.recordDiagnosticEvent('vpn_conflict_confirm_disconnect_failed', 'cleanup', error.code);
        this.finishVpnConflictCancellation(restoreBackend);
      });
  }

  private finishVpnConflictCancellation(restoreBackend: boolean): void {
    if (!restoreBackend) {
      this.refreshBackendStatus();
      return;
    }
    this.startBackend(false);
    this.scheduleLifecycleTask(() => this.refreshBackendStatus(), 1500);
  }

  private setConnectInProgress(inProgress: boolean): void {
    // Loading state must enter the component tree synchronously. Animating the
    // surrounding panel is handled by its modifier; delaying this assignment
    // can otherwise let a fast native failure skip the progress frame.
    this.connectInProgress = inProgress;
  }

  private onlinePeerCount(): number {
    return this.peers.filter((peer: PeerSummary) => peer.online).length;
  }

  private peerDeviceIcon(deviceType: string): Resource {
    if (deviceType === 'tablet') {
      return $r('app.media.device_tablet');
    }
    if (deviceType === 'phone' || deviceType === 'foldable') {
      return $r('app.media.device_phone');
    }
    return $r('app.media.device_laptop');
  }

  private localDeviceIcon(): Resource {
    return this.peerDeviceIcon(deviceInfo.deviceType);
  }

  private nodeNameSlug(value: string): string {
    return value.split('.')[0]
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '');
  }

  private localDeviceName(): string {
    const sourceName: string = this.accountSummary.deviceName.length > 0 ?
      this.accountSummary.deviceName : this.deviceModel();
    const withoutMagicDns: string = sourceName
      .replace(/(?:[.\s_-]*magicdns)(?:[.\s_-].*)?$/i, '')
      .trim();
    let nodeName: string = this.nodeNameSlug(
      withoutMagicDns.length > 0 ? withoutMagicDns : this.deviceModel());
    const brandName: string = this.nodeNameSlug(deviceInfo.brand);
    if (brandName.length > 0 && nodeName.startsWith(`${brandName}-`)) {
      nodeName = nodeName.substring(brandName.length + 1);
    }
    return nodeName.length > 0 ? nodeName : sourceName;
  }

  private displayOsName(os: string): string {
    switch (os.trim().toLowerCase()) {
      case 'android':
        return 'Android';
      case 'windows':
        return 'Windows';
      case 'linux':
        return 'Linux';
      case 'macos':
      case 'darwin':
        return 'macOS';
      case 'ios':
        return 'iOS';
      case 'chromeos':
        return 'ChromeOS';
      case 'freebsd':
        return 'FreeBSD';
      case 'harmonyos':
      case 'openharmony':
        return 'HarmonyOS';
      default:
        return os;
    }
  }

  private formattedOsDescription(os: string, osVersion?: string): string {
    const osName: string = os.length > 0 ? this.displayOsName(os) : '';
    const rawVersion: string = osVersion === undefined ? '' : osVersion.trim();
    if (rawVersion.length === 0) {
      return osName;
    }
    if (osName.length === 0) {
      return rawVersion;
    }

    const lowerVersion: string = rawVersion.toLowerCase();
    if (osName === 'Windows') {
      const windowsBuildMatch: RegExpMatchArray | null = rawVersion.match(
        /^(?:windows\s+)?10\.0\.(\d+)/i);
      if (windowsBuildMatch !== null) {
        return Number(windowsBuildMatch[1]) >= 22000 ? 'Windows 11' : 'Windows 10';
      }
      if (lowerVersion.startsWith('windows ')) {
        return rawVersion;
      }
    }
    if (osName === 'HarmonyOS') {
      const harmonyVersionMatch: RegExpMatchArray | null = rawVersion.match(
        /^(?:harmonyos|openharmony)[\s_-]*(\d+)\.(\d+)/i);
      if (harmonyVersionMatch !== null) {
        return `HarmonyOS ${harmonyVersionMatch[1]}.${harmonyVersionMatch[2]}`;
      }
      const numericVersionMatch: RegExpMatchArray | null = rawVersion.match(/^(\d+)\.(\d+)/);
      if (numericVersionMatch !== null) {
        return `HarmonyOS ${numericVersionMatch[1]}.${numericVersionMatch[2]}`;
      }
      if (lowerVersion.startsWith('harmonyos ')) {
        return rawVersion;
      }
      return 'HarmonyOS';
    }
    if (lowerVersion.startsWith(`${osName.toLowerCase()} `)) {
      return rawVersion;
    }
    return `${osName} ${rawVersion}`;
  }

  private peerDeviceDescription(peer: PeerSummary): string {
    const description: string = this.formattedOsDescription(peer.os, peer.osVersion);
    if (description.length > 0) {
      return description;
    }
    return peer.deviceModel;
  }

  private taildropOnlineTargetCount(): number {
    return this.displayedTaildropTargets().filter((target: TaildropTargetSummary) => target.online).length;
  }

  private displayedTaildropTargets(): TaildropTargetSummary[] {
    if (this.isConnected()) {
      return this.taildropTargets;
    }
    // Taildrop target discovery only runs inside the connected VPN backend.
    // While disconnected, mirror the same peer snapshot rendered on Home so
    // the disabled transfer list never diverges from the device list.
    return this.peers.map((peer: PeerSummary): TaildropTargetSummary => {
      return {
        key: peer.key,
        name: this.peerDisplayName(peer.name),
        os: peer.os,
        osVersion: peer.osVersion,
        deviceModel: peer.deviceModel,
        deviceType: peer.deviceType,
        online: peer.online
      };
    });
  }

  private taildropTargetDescription(target: TaildropTargetSummary): string {
    const description: string = this.formattedOsDescription(target.os, target.osVersion);
    if (description.length > 0) {
      return description;
    }
    if (target.deviceModel.length > 0) {
      return target.deviceModel;
    }
    return 'Tailscale';
  }

  private primaryTailscaleAddress(addresses: string[]): string {
    const ipv4Address: string | undefined = addresses.find((address: string) =>
      !address.includes(':'));
    if (ipv4Address !== undefined) {
      return ipv4Address;
    }
    return addresses.length > 0 ? addresses[0] : '';
  }

  private peerDisplayName(name: string): string {
    if (!name.toLowerCase().endsWith('.ts.net')) {
      return name;
    }
    const firstDot: number = name.indexOf('.');
    return firstDot > 0 ? name.substring(0, firstDot) : name;
  }

  private deviceNeedsApproval(): boolean {
    return this.accountSummary.needsApproval || this.backendStatus.includes('NeedsMachineAuth');
  }

  private keyExpiresSoon(expiryUnixMs: number): boolean {
    const remainingMs: number = expiryUnixMs - Date.now();
    return remainingMs > 0 && remainingMs <= 7 * 24 * 60 * 60 * 1000;
  }

  private keyExpiryDays(expiryUnixMs: number): number {
    return Math.max(1, Math.ceil((expiryUnixMs - Date.now()) / (24 * 60 * 60 * 1000)));
  }

  private keyExpiryLabel(keyExpired: boolean, expiryUnixMs: number): ResourceStr {
    if (keyExpired) {
      return $r('app.string.device_key_expired');
    }
    return $r('app.string.device_key_expiring', this.keyExpiryDays(expiryUnixMs));
  }

  private connectionTitle(): ResourceStr {
    if (!this.controlServerConfirmed) {
      return $r('app.string.connection_server_required');
    }
    if (this.isBackendLoading()) {
      return $r('app.string.connection_starting');
    }
    if (this.isConnected()) {
      return $r('app.string.connection_connected');
    }
    if (this.deviceNeedsApproval()) {
      return $r('app.string.connection_approval_required');
    }
    if (this.accountSummary.keyExpired) {
      return $r('app.string.connection_key_expired');
    }
    if (this.isConnecting()) {
      return $r('app.string.connection_connecting');
    }
    if (this.hasConnectionProblem()) {
      return $r('app.string.connection_problem');
    }
    if (this.needsLogin()) {
      return $r('app.string.connection_login_required');
    }
    return $r('app.string.connection_disconnected');
  }

  private connectionDescription(): ResourceStr {
    if (!this.controlServerConfirmed) {
      return $r('app.string.description_server_required');
    }
    if (this.isBackendLoading()) {
      return $r('app.string.description_starting');
    }
    if (this.isConnected()) {
      return $r('app.string.description_connected');
    }
    if (this.deviceNeedsApproval()) {
      return $r('app.string.description_approval_required');
    }
    if (this.accountSummary.keyExpired) {
      return $r('app.string.description_key_expired');
    }
    if (this.isConnecting()) {
      return $r('app.string.description_connecting');
    }
    if (this.needsLogin()) {
      return $r('app.string.description_login_required');
    }
    if (this.hasConnectionProblem()) {
      if (this.vpnStatus.includes('code=2203002')) {
        return $r('app.string.description_vpn_conflict_problem');
      }
      if (this.backendStatus.includes('tls-error') || this.backendStatus.includes('x509')) {
        return $r('app.string.description_tls_problem');
      }
      if (this.backendStatus.includes('network-timeout') ||
        this.backendStatus.includes('connection-error') || this.backendStatus.includes('netUp=false')) {
        return $r('app.string.description_network_problem');
      }
      if (this.vpnStatus.includes('VPN start') || this.vpnStatus.includes('authorization')) {
        return $r('app.string.description_vpn_permission_problem');
      }
      if (this.vpnStatus.includes('status file')) {
        return $r('app.string.description_status_problem');
      }
      return $r('app.string.description_problem');
    }
    return $r('app.string.description_disconnected');
  }

  private connectionColor(): ResourceColor {
    if (this.isConnected()) {
      return $r('app.color.status_success');
    }
    if (this.isConnecting()) {
      return $r('app.color.status_warning');
    }
    if (this.hasConnectionProblem()) {
      return $r('app.color.status_error');
    }
    return $r('app.color.status_neutral');
  }

  private glowFilePath(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return `${context.filesDir}/ui-glow-level-v2`;
  }

  private resetDiagnosticsMode(): void {
    this.diagnosticsUnlocked = false;
    this.diagnosticsExpanded = false;
    this.diagnosticsTapCount = 0;
    this.diagnosticsLastTapMs = 0;
  }

  private unlockDiagnostics(): void {
    this.diagnosticsUnlocked = true;
    this.diagnosticsExpanded = true;
  }

  private showToast(message: ResourceStr): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message });
    } catch (_error) {
      // Toast is immediate feedback only; failure must not block the gesture.
    }
  }

  private onAppVersionTap(): void {
    if (this.diagnosticsUnlocked) {
      this.showToast($r('app.string.diagnostics_unlocked_toast'));
      return;
    }
    const nowMs: number = Date.now();
    if (nowMs - this.diagnosticsLastTapMs > 1500) {
      this.diagnosticsTapCount = 0;
    }
    this.diagnosticsLastTapMs = nowMs;
    this.diagnosticsTapCount += 1;
    if (this.diagnosticsTapCount >= 5) {
      this.diagnosticsTapCount = 0;
      this.unlockDiagnostics();
      this.showToast($r('app.string.diagnostics_unlocked_toast'));
      this.scheduleLifecycleTask(() => {
        this.settingsScroller.scrollBy(0, 100000);
      }, 80);
      return;
    }
    const remainingCount: number = 5 - this.diagnosticsTapCount;
    this.showToast(`再点击${remainingCount}次即可进入工程诊断`);
  }

  private loadGlowLevel(): void {
    try {
      const path: string = this.glowFilePath();
      if (!fileIo.accessSync(path)) {
        return;
      }
      const level: number = Number(fileIo.readTextSync(path));
      if (level >= 0 && level <= 3) {
        this.glowLevel = level;
      }
    } catch (_error) {
      this.glowLevel = 3;
    }
  }

  private setGlowLevel(level: number): void {
    if (level < 0 || level > 3) {
      return;
    }
    this.glowLevel = level;
    try {
      const file = fileIo.openSync(this.glowFilePath(),
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, level.toString());
      fileIo.closeSync(file);
    } catch (_error) {
      // Visual preferences are best-effort and never affect VPN behavior.
    }
  }

  private glowRadius(): number {
    return this.glowLevel === 0 ? 28 : (this.glowLevel === 1 ? 18 : 10);
  }

  private glowColor(): ResourceColor {
    return $r('sys.color.comp_background_emphasize');
  }

  private glowSurface(): ResourceColor {
    return $r('sys.color.comp_background_tertiary');
  }

  private glowLightColor(): ResourceColor {
    return $r('sys.color.comp_background_emphasize');
  }

  private glowSaturation(): number {
    return this.glowLevel === 0 ? 1.38 : (this.glowLevel === 1 ? 1.2 : 1.05);
  }

  private glowBrightness(): number {
    return this.glowLevel === 0 ? 1.12 : (this.glowLevel === 1 ? 1.07 : 1.02);
  }

  private glowMaterialLevel(): hdsMaterial.MaterialLevel {
    if (this.glowLevel === 0) {
      return hdsMaterial.MaterialLevel.EXQUISITE;
    }
    if (this.glowLevel === 1) {
      return hdsMaterial.MaterialLevel.GENTLE;
    }
    if (this.glowLevel === 2) {
      return hdsMaterial.MaterialLevel.SMOOTH;
    }
    return hdsMaterial.MaterialLevel.ADAPTIVE;
  }

  private immersivePressEffect(): VisualEffect {
    return new hdsEffect.HdsEffectBuilder()
      .pointLight({
        sourceType: hdsEffect.PointLightSourceType.SOFT,
        illuminatedType: hdsEffect.PointLightIlluminatedType.DEFAULT_FEATHERING_BORDER,
        options: {
          color: this.glowLightColor(),
          intensity: 0.42,
          height: 48,
          bloom: 0.16
        }
      })
      .pressShadow(hdsEffect.PressShadowType.BLEND_GRADIENT)
      .buildEffect();
  }

  private glowLevelLabel(): ResourceStr {
    if (this.glowLevel === 0) {
      return $r('app.string.glow_exquisite');
    }
    if (this.glowLevel === 1) {
      return $r('app.string.glow_gentle');
    }
    if (this.glowLevel === 2) {
      return $r('app.string.glow_smooth');
    }
    return $r('app.string.glow_adaptive');
  }

  private isWideNavigation(): boolean {
    return ResponsiveLayout.homeNavigationMode(this.layoutWidth, this.layoutHeight) ===
      ResponsiveNavigationMode.SIDE;
  }

  private isExpandedLayout(): boolean {
    return ResponsiveLayout.homeContentLayout(this.layoutWidth) === HomeContentLayout.MASTER_DETAIL;
  }

  private isTransferSplitLayout(): boolean {
    return ResponsiveLayout.transferContentLayout(this.layoutWidth) === TransferContentLayout.SPLIT;
  }

  private isSettingsTwoColumnLayout(): boolean {
    return ResponsiveLayout.settingsContentLayout(this.layoutWidth) === SettingsContentLayout.TWO_COLUMN;
  }

  private readTransferScrollOffset(): number {
    try {
      const offset: OffsetResult = this.transferScroller.currentOffset();
      return Number.isFinite(offset.yOffset) ? Math.max(0, offset.yOffset) : this.transferScrollAnchorY;
    } catch (_error) {
      return this.transferScrollAnchorY;
    }
  }

  private scheduleTransferScrollRestore(): void {
    if (this.transferScrollRestoreTimer >= 0) {
      return;
    }
    this.transferScrollRestoreTimer = this.scheduleLifecycleTask(() => {
      this.transferScrollRestoreTimer = -1;
      this.restoreTransferScrollAnchor();
    }, 32);
  }

  private restoreTransferScrollAnchor(): void {
    const currentOffsetY: number = this.readTransferScrollOffset();
    const deltaY: number = this.transferScrollAnchorY - currentOffsetY;
    if (!Number.isFinite(deltaY) || Math.abs(deltaY) < 1) {
      return;
    }
    try {
      this.transferScroller.scrollBy(0, deltaY);
    } catch (_error) {
      // A Transfer page that is not currently bound keeps the anchor for its next layout pass.
    }
  }

  private readSettingsScrollOffset(): number {
    try {
      const offset: OffsetResult = this.settingsScroller.currentOffset();
      return Number.isFinite(offset.yOffset) ? Math.max(0, offset.yOffset) : this.settingsScrollAnchorY;
    } catch (_error) {
      return this.settingsScrollAnchorY;
    }
  }

  private scheduleSettingsScrollRestore(): void {
    if (this.settingsScrollRestoreTimer >= 0) {
      return;
    }
    this.settingsScrollRestoreTimer = this.scheduleLifecycleTask(() => {
      this.settingsScrollRestoreTimer = -1;
      this.restoreSettingsScrollAnchor();
    }, 32);
  }

  private restoreSettingsScrollAnchor(): void {
    const currentOffsetY: number = this.readSettingsScrollOffset();
    const deltaY: number = this.settingsScrollAnchorY - currentOffsetY;
    if (!Number.isFinite(deltaY) || Math.abs(deltaY) < 1) {
      return;
    }
    try {
      this.settingsScroller.scrollBy(0, deltaY);
    } catch (_error) {
      // A Settings page that is not currently bound keeps the anchor for its next layout pass.
    }
  }

  private updateLayoutMetrics(newValue: Area): void {
    const wasWideNavigation: boolean = this.isWideNavigation();
    const wasExpandedLayout: boolean = this.isExpandedLayout();
    const wasTransferSplitLayout: boolean = this.isTransferSplitLayout();
    const wasSettingsTwoColumnLayout: boolean = this.isSettingsTwoColumnLayout();
    const nextWidth: number = Math.max(0, Number(newValue.width));
    const nextHeight: number = Math.max(0, Number(newValue.height));
    const nextTransferSplitLayout: boolean =
      ResponsiveLayout.transferContentLayout(nextWidth) === TransferContentLayout.SPLIT;
    const nextSettingsTwoColumnLayout: boolean =
      ResponsiveLayout.settingsContentLayout(nextWidth) === SettingsContentLayout.TWO_COLUMN;
    const transferSplitLayoutChanged: boolean = wasTransferSplitLayout !== nextTransferSplitLayout;
    const settingsTwoColumnLayoutChanged: boolean =
      wasSettingsTwoColumnLayout !== nextSettingsTwoColumnLayout;
    if (transferSplitLayoutChanged) {
      this.transferScrollAnchorY = this.readTransferScrollOffset();
    }
    if (settingsTwoColumnLayoutChanged) {
      this.settingsScrollAnchorY = this.readSettingsScrollOffset();
    }
    this.layoutWidth = nextWidth;
    this.layoutHeight = nextHeight;
    if (wasWideNavigation !== this.isWideNavigation() || wasExpandedLayout !== this.isExpandedLayout()) {
      this.scheduleLifecycleTask(() => this.restoreHomePeerScrollAnchor(), 32);
    }
    if (transferSplitLayoutChanged) {
      this.scheduleTransferScrollRestore();
    }
    if (settingsTwoColumnLayoutChanged) {
      this.scheduleSettingsScrollRestore();
    }
  }

  private recordHomePeerScrollAnchor(startIndex: number): void {
    this.homePeerScrollAnchorIndex = Math.max(0, startIndex);
  }

  private restoreHomePeerScrollAnchor(): void {
    if (this.peers.length === 0) {
      return;
    }
    const lastIndex: number = this.peers.length;
    this.homePeerScroller.scrollToIndex(Math.min(this.homePeerScrollAnchorIndex, lastIndex));
  }

  private pageMargin(): number {
    return ResponsiveLayout.pageMargin(this.layoutWidth);
  }

  private contentMargin(): number {
    return this.pageMargin() + 8;
  }

  private pageBottomInset(): number {
    return 120;
  }

  private groupBackground(): ResourceColor {
    return $r('sys.color.comp_background_primary');
  }

  private isPeerNameExpanded(peerKey: string): boolean {
    return this.expandedPeerKeys.includes(peerKey);
  }

  private togglePeerName(peerKey: string): void {
    if (this.isPeerNameExpanded(peerKey)) {
      this.expandedPeerKeys = this.expandedPeerKeys.filter((key: string) => key !== peerKey);
      return;
    }
    this.expandedPeerKeys = this.expandedPeerKeys.concat(peerKey);
  }

  private setConnectedHomeLayoutMode(mode: ConnectedHomeLayoutMode): void {
    if (this.connectedHomeLayoutMode === mode) {
      return;
    }
    this.connectedHomeLayoutMode = mode;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.settingsPreferencesGateway.saveConnectedHomeLayout(context, mode).catch(() => {
      // The layout is still changed for this session when persistence is unavailable.
    });
  }

  private connectedHomeLayoutActive(): boolean {
    return this.isConnected() || this.disconnectInProgress ||
      (this.isConnecting() && this.trafficSession > 0);
  }

  private selectedExitNodeName(): string {
    const selected: ExitNodeChoice | undefined = this.exitNodes.find(
      (choice: ExitNodeChoice) => choice.selected);
    return selected === undefined ? '' : selected.name;
  }

  private connectedDurationLabel(): string {
    if (this.connectionStartedAtMs <= 0) {
      return '\u521A\u521A\u8FDE\u63A5';
    }
    const elapsedSeconds: number = Math.max(0, Math.floor((Date.now() - this.connectionStartedAtMs) / 1000));
    const hours: number = Math.floor(elapsedSeconds / 3600);
    const minutes: number = Math.floor((elapsedSeconds % 3600) / 60);
    const seconds: number = elapsedSeconds % 60;
    if (hours > 0) {
      return `${hours} \u5C0F\u65F6 ${minutes} \u5206\u949F`;
    }
    if (minutes > 0) {
      return `${minutes} \u5206\u949F ${seconds} \u79D2`;
    }
    return `${seconds} 秒`;
  }

  private openConnectionDetails(): void {
    if (this.connectedHomeLayoutActive()) {
      this.connectionDetailsVisible = true;
    }
  }

  private showExitNodeConnectionHint(): void {
    this.showToast($r('app.string.exit_node_disconnect_first'));
  }

  private togglePeer(peer: PeerSummary): void {
    if (!peer.online && !this.isPeerNameExpanded(peer.key)) {
      return;
    }
    const opening: boolean = !this.isPeerNameExpanded(peer.key);
    this.getUIContext()?.animateTo({ duration: MotionTokens.EXPAND, curve: Curve.EaseInOut }, () => {
      this.togglePeerName(peer.key);
    });
    if (opening && this.isSunshineCandidate(peer)) {
      this.detectStreamingForPeer(peer, false);
    }
  }

  private refreshPeerServices(peer: PeerSummary): void {
    const previousStreaming: DeviceStreamingState = this.streamingState(peer.key);
    const previousMedia: DeviceMediaState = this.mediaState(peer.key);
    if (previousStreaming.checking || previousMedia.checking) {
      return;
    }
    if (!this.isConnected() || !peer.online || peer.addresses.length === 0) {
      this.showToast('请先连接 MeshArc，并确认目标设备在线。');
      return;
    }
    this.ensureStreamingServices();
    this.ensureMediaServices();
    const requestId: number = Date.now();
    const sunshineCandidate: boolean = this.isSunshineCandidate(peer);
    this.streamingRequestIds.set(peer.key, requestId);
    this.mediaRequestIds.set(peer.key, requestId);
    this.updateStreamingState(peer.key, this.copyStreamingState(previousStreaming,
      sunshineCandidate ? { state: 'checking', checkedAt: requestId } : previousStreaming.sunshine,
      previousStreaming.path, true));
    this.updateMediaState(peer.key, {
      peerKey: peer.key,
      result: {
        state: 'checking',
        checkedAt: requestId,
        services: previousMedia.result.services
      },
      checking: true,
      launching: previousMedia.launching
    });
    const sunshineProbe: Promise<SunshineProbeResult> = sunshineCandidate ?
      this.sunshineProbeService!.probe(peer.key, this.primaryTailscaleAddress(peer.addresses), true, true) :
      Promise.resolve(previousStreaming.sunshine);
    Promise.all([
      sunshineProbe,
      this.mediaServiceProbeService!.probe(peer.key, true, true),
      this.peerPathService!.probe(peer.key, true, true)
    ]).then((results: [SunshineProbeResult, MediaProbeResult, PeerPathResult]) => {
      const currentPeer: PeerSummary | undefined = this.peers.find(
        (item: PeerSummary) => item.key === peer.key && item.online);
      if (this.streamingRequestIds.get(peer.key) !== requestId ||
        this.mediaRequestIds.get(peer.key) !== requestId || currentPeer === undefined || !this.isConnected()) {
        return;
      }
      const sunshine: SunshineProbeResult = results[0];
      const media: MediaProbeResult = results[1];
      const path: PeerPathResult = results[2];
      this.updateStreamingState(peer.key,
        this.copyStreamingState(this.streamingState(peer.key), sunshine, path, false));
      this.updateMediaState(peer.key, {
        peerKey: peer.key,
        result: media,
        checking: false,
        launching: false
      });
      this.recordDiagnosticEvent('peer_path_result', path.type);
      this.recordDiagnosticEvent(sunshine.state === 'available' ? 'sunshine_probe_success' :
        sunshine.state === 'timeout' ? 'sunshine_probe_timeout' : 'sunshine_probe_failed', sunshine.state);
      this.recordDiagnosticEvent(media.services.length > 0 ?
        'media_probe_success' : 'media_probe_no_service', path.type);
    }).catch(() => {
      if (this.streamingRequestIds.get(peer.key) !== requestId ||
        this.mediaRequestIds.get(peer.key) !== requestId) {
        return;
      }
      this.updateStreamingState(peer.key, this.copyStreamingState(this.streamingState(peer.key),
        sunshineCandidate ? { state: 'error', checkedAt: Date.now(), errorMessage: 'probe_failed' } :
          previousStreaming.sunshine,
        { type: 'unknown', checkedAt: Date.now(), errorMessage: 'probe_failed' }, false));
      this.updateMediaState(peer.key, {
        peerKey: peer.key,
        result: {
          state: 'error',
          checkedAt: Date.now(),
          services: [],
          errorMessage: 'probe_failed'
        },
        checking: false,
        launching: false
      });
      this.recordDiagnosticEvent('peer_service_refresh_failed', 'exception');
    });
    this.recordDiagnosticEvent('peer_service_refresh_start', 'requested');
  }

  private autoProbeConnectedPeerServices(): void {
    if (!this.isConnected()) {
      return;
    }
    const session: number = Math.max(1, this.trafficSession);
    this.peers.filter((peer: PeerSummary) => peer.online && peer.addresses.length > 0)
      .forEach((peer: PeerSummary) => {
        if (this.autoProbedPeerSessions.get(peer.key) === session) {
          return;
        }
        this.autoProbedPeerSessions.set(peer.key, session);
        if (this.isSunshineCandidate(peer)) {
          this.detectStreamingForPeer(peer, false);
        }
        this.detectMediaForPeer(peer, false);
      });
  }

  private isSunshineCandidate(peer: PeerSummary): boolean {
    if (!peer.online || peer.addresses.length === 0) {
      return false;
    }
    const os: string = peer.os.toLowerCase();
    return os.includes('windows') || os.includes('linux') || os.includes('macos') || os.includes('darwin');
  }

  private streamingState(peerKey: string): DeviceStreamingState {
    const existing: DeviceStreamingState | undefined = this.streamingStates.find(
      (state: DeviceStreamingState) => state.peerKey === peerKey);
    if (existing !== undefined) {
      return existing;
    }
    return {
      peerKey: peerKey,
      sunshine: { state: 'unknown', checkedAt: 0 },
      path: { type: 'unknown', checkedAt: 0 },
      checking: false,
      launching: false
    };
  }

  private copyStreamingState(state: DeviceStreamingState, sunshine?: SunshineProbeResult,
    path?: PeerPathResult, checking?: boolean, launching?: boolean): DeviceStreamingState {
    return {
      peerKey: state.peerKey,
      sunshine: sunshine === undefined ? state.sunshine : sunshine,
      path: path === undefined ? state.path : path,
      checking: checking === undefined ? state.checking : checking,
      launching: launching === undefined ? state.launching : launching
    };
  }

  private updateStreamingState(peerKey: string, update: DeviceStreamingState): void {
    const index: number = this.streamingStates.findIndex(
      (state: DeviceStreamingState) => state.peerKey === peerKey);
    if (index < 0) {
      this.streamingStates = this.streamingStates.concat(update);
      return;
    }
    const next: DeviceStreamingState[] = this.streamingStates.slice();
    next[index] = update;
    this.streamingStates = next;
  }

  private resetStreamingStatesForDisconnect(): void {
    this.streamingRequestIds.clear();
    this.mediaRequestIds.clear();
    this.autoProbedPeerSessions.clear();
    this.sunshineProbeService?.clearCache();
    this.peerPathService?.clearCache();
    this.mediaServiceProbeService?.clearCache();
    this.streamingStates = this.streamingStates.map((state: DeviceStreamingState) =>
      this.copyStreamingState(state,
        { state: 'unknown', checkedAt: Date.now(), errorMessage: 'mesh_disconnected' },
        { type: 'unknown', checkedAt: Date.now(), errorMessage: 'mesh_disconnected' }, false, false));
    this.mediaStates = this.mediaStates.map((state: DeviceMediaState): DeviceMediaState => {
      const result: MediaProbeResult = {
        state: 'unknown',
        checkedAt: Date.now(),
        services: [],
        errorMessage: 'mesh_disconnected'
      };
      const updated: DeviceMediaState = {
        peerKey: state.peerKey,
        result: result,
        checking: false,
        launching: false
      };
      return updated;
    });
  }

  private ensureStreamingServices(): void {
    if (this.sunshineProbeService !== undefined && this.peerPathService !== undefined &&
      this.moonlightLauncher !== undefined) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.sunshineProbeService = new SunshineProbeService(context);
    this.peerPathService = new PeerPathService(context);
    this.moonlightLauncher = new MoonlightLauncher(context);
  }

  private ensureMediaServices(): void {
    if (this.mediaServiceProbeService !== undefined && this.hosPlayerLauncher !== undefined) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.mediaServiceProbeService = new MediaServiceProbeService(context);
    this.hosPlayerLauncher = new HosPlayerLauncher(context);
  }

  private mediaState(peerKey: string): DeviceMediaState {
    if (this.fakeMediaServiceOnline) {
      const peer: PeerSummary | undefined = this.peers.find((item: PeerSummary) => item.key === peerKey);
      const host: string = peer === undefined ? '100.64.0.1' :
        this.primaryTailscaleAddress(peer.addresses);
      return {
        peerKey: peerKey,
        result: {
          state: 'available',
          checkedAt: Date.now(),
          services: [{
            type: 'jellyfin',
            name: 'Jellyfin（工程伪装）',
            url: `http://${host.length > 0 ? host : '100.64.0.1'}:8096`,
            latencyMs: 1
          }]
        },
        checking: false,
        launching: false
      };
    }
    const existing: DeviceMediaState | undefined = this.mediaStates.find(
      (state: DeviceMediaState) => state.peerKey === peerKey);
    if (existing !== undefined) {
      return existing;
    }
    return {
      peerKey: peerKey,
      result: { state: 'unknown', checkedAt: 0, services: [] },
      checking: false,
      launching: false
    };
  }

  private mediaServiceNames(peerKey: string): string {
    return this.mediaState(peerKey).result.services.map((service: DiscoveredMediaService) => {
      if (service.type === 'jellyfin') return 'Jellyfin';
      if (service.type === 'emby') return 'Emby';
      if (service.type === 'plex') return 'Plex';
      if (service.type === 'webdav') return 'WebDAV';
      return 'SMB';
    }).join(' · ');
  }

  private peerServiceBadgesVisible(peer: PeerSummary): boolean {
    const sunshineState: string = this.streamingState(peer.key).sunshine.state;
    return sunshineState === 'checking' || sunshineState === 'available' ||
      this.mediaState(peer.key).checking || this.mediaServiceNames(peer.key).length > 0;
  }

  private updateMediaState(peerKey: string, update: DeviceMediaState): void {
    const index: number = this.mediaStates.findIndex(
      (state: DeviceMediaState) => state.peerKey === peerKey);
    if (index < 0) {
      this.mediaStates = this.mediaStates.concat(update);
      return;
    }
    const next: DeviceMediaState[] = this.mediaStates.slice();
    next[index] = update;
    this.mediaStates = next;
  }

  private detectMediaForPeer(peer: PeerSummary, force: boolean): void {
    if (!peer.online || peer.addresses.length === 0 || !this.isConnected()) {
      this.showToast('请先连接 MeshArc，并确认目标设备在线。');
      return;
    }
    this.ensureMediaServices();
    this.ensureStreamingServices();
    const requestId: number = Date.now();
    this.mediaRequestIds.set(peer.key, requestId);
    const previous: DeviceMediaState = this.mediaState(peer.key);
    this.updateMediaState(peer.key, {
      peerKey: peer.key,
      result: {
        state: 'checking',
        checkedAt: Date.now(),
        services: previous.result.services
      },
      checking: true,
      launching: previous.launching
    });
    this.recordDiagnosticEvent('media_probe_start', 'requested');
    Promise.all([
      this.mediaServiceProbeService!.probe(peer.key, true, force),
      this.peerPathService!.probe(peer.key, true, force)
    ]).then((results: [MediaProbeResult, PeerPathResult]) => {
      if (this.mediaRequestIds.get(peer.key) !== requestId || !this.isConnected()) {
        return;
      }
      const currentPeer: PeerSummary | undefined = this.peers.find(
        (item: PeerSummary) => item.key === peer.key && item.online);
      if (currentPeer === undefined) {
        return;
      }
      const mediaResult: MediaProbeResult = results[0];
      const path: PeerPathResult = results[1];
      const streamState: DeviceStreamingState = this.streamingState(peer.key);
      this.updateStreamingState(peer.key,
        this.copyStreamingState(streamState, undefined, path, false, false));
      this.updateMediaState(peer.key, {
        peerKey: peer.key,
        result: mediaResult,
        checking: false,
        launching: false
      });
      this.recordDiagnosticEvent(mediaResult.services.length > 0 ?
        'media_probe_success' : 'media_probe_no_service', path.type);
      mediaResult.services.forEach((service: DiscoveredMediaService) => {
        this.recordDiagnosticEvent('media_service_detected', service.type);
      });
    }).catch(() => {
      if (this.mediaRequestIds.get(peer.key) !== requestId) {
        return;
      }
      this.updateMediaState(peer.key, {
        peerKey: peer.key,
        result: {
          state: 'error',
          checkedAt: Date.now(),
          services: [],
          errorMessage: 'probe_failed'
        },
        checking: false,
        launching: false
      });
      this.recordDiagnosticEvent('media_probe_failed', 'exception');
    });
  }

  private detectStreamingForPeer(peer: PeerSummary, force: boolean): void {
    if (!this.isSunshineCandidate(peer) || !this.isConnected()) {
      return;
    }
    this.ensureStreamingServices();
    const requestId: number = Date.now();
    this.streamingRequestIds.set(peer.key, requestId);
    const previous: DeviceStreamingState = this.streamingState(peer.key);
    const checkingPath: PeerPathResult = {
      type: previous.path.type,
      latencyMs: previous.path.latencyMs,
      relayRegion: previous.path.relayRegion,
      checkedAt: Date.now(),
      errorMessage: previous.path.errorMessage
    };
    this.updateStreamingState(peer.key, this.copyStreamingState(previous,
      { state: 'checking', checkedAt: Date.now() }, checkingPath, true));
    const host: string = this.primaryTailscaleAddress(peer.addresses);
    Promise.all([
      this.sunshineProbeService!.probe(peer.key, host, true, force),
      this.peerPathService!.probe(peer.key, true, force)
    ]).then((results: [SunshineProbeResult, PeerPathResult]) => {
      const sunshine: SunshineProbeResult = results[0];
      const path: PeerPathResult = results[1];
      const currentPeer: PeerSummary | undefined = this.peers.find((item: PeerSummary) => item.key === peer.key);
      if (this.streamingRequestIds.get(peer.key) !== requestId || currentPeer === undefined || !currentPeer.online ||
        !this.isConnected()) {
        return;
      }
      const current: DeviceStreamingState = this.streamingState(peer.key);
      this.updateStreamingState(peer.key, this.copyStreamingState(current, sunshine, path, false));
      this.recordDiagnosticEvent(sunshine.state === 'available' ? 'sunshine_probe_success' :
        sunshine.state === 'timeout' ? 'sunshine_probe_timeout' : 'sunshine_probe_failed', sunshine.state);
      this.recordDiagnosticEvent('peer_path_result', path.type);
    }).catch(() => {
      if (this.streamingRequestIds.get(peer.key) !== requestId) {
        return;
      }
      const current: DeviceStreamingState = this.streamingState(peer.key);
      this.updateStreamingState(peer.key, this.copyStreamingState(current,
        { state: 'error', checkedAt: Date.now(), errorMessage: 'probe_failed' },
        { type: 'unknown', checkedAt: Date.now(), errorMessage: 'probe_failed' }, false));
      this.recordDiagnosticEvent('sunshine_probe_failed', 'exception');
    });
    this.recordDiagnosticEvent('sunshine_probe_start', 'requested');
    this.recordDiagnosticEvent('peer_path_probe_start', 'requested');
  }

  private streamReachable(state: DeviceStreamingState): boolean {
    return state.path.type !== 'unreachable';
  }

  private launchRemoteStream(peer: PeerSummary): void {
    if (!this.isConnected()) {
      this.showToast('请先连接 MeshArc，再使用远程串流。');
      return;
    }
    if (!peer.online) {
      this.showToast('目标设备当前离线。');
      return;
    }
    const state: DeviceStreamingState = this.streamingState(peer.key);
    if (state.launching) {
      return;
    }
    this.updateStreamingState(peer.key, this.copyStreamingState(state, undefined, undefined, undefined, true));
    this.detectStreamingForPeer(peer, true);
    const probeRequestId: number = this.streamingRequestIds.get(peer.key) ?? 0;
    const launchStartedAt: number = Date.now();
    const generation: number = this.lifecycleGeneration;
    const waitForProbe = (): void => {
      if (generation !== this.lifecycleGeneration || !this.isConnected() ||
        this.streamingRequestIds.get(peer.key) !== probeRequestId) {
        return;
      }
      const latest: DeviceStreamingState = this.streamingState(peer.key);
      if (latest.checking) {
        if (!this.isConnected() || Date.now() - launchStartedAt > 5000) {
          this.updateStreamingState(peer.key, this.copyStreamingState(latest, undefined, undefined, false, false));
          this.showToast('Sunshine 检测超时，请检查目标电脑防火墙或网络状态。');
          return;
        }
        setTimeout(waitForProbe, 120);
        return;
      }
      this.completeStreamLaunch(peer, latest);
    };
    setTimeout(waitForProbe, 0);
  }

  private completeStreamLaunch(peer: PeerSummary, state: DeviceStreamingState): void {
    if (state.sunshine.state !== 'available') {
      this.updateStreamingState(peer.key, this.copyStreamingState(state, undefined, undefined, undefined, false));
      this.showToast(state.sunshine.state === 'timeout' ? 'Sunshine 检测超时，请检查目标电脑防火墙或网络状态。' :
        '未检测到可用的 Sunshine 服务，请确认电脑已启动 Sunshine。');
      return;
    }
    if (!this.streamReachable(state)) {
      this.updateStreamingState(peer.key, this.copyStreamingState(state, undefined, undefined, undefined, false));
      this.showToast('当前无法访问目标设备。');
      return;
    }
    if (state.path.type === 'derp') {
      this.showDerpStreamConfirmation(peer, state);
      return;
    }
    this.openMoonlight(peer, state, false);
  }

  private showDerpStreamConfirmation(peer: PeerSummary, state: DeviceStreamingState): void {
    this.getUIContext().showAlertDialog({
      title: '当前通过 DERP 中继连接',
      message: '中继连接可能导致延迟升高或画面卡顿。MeshArc 将建议 MoonlightOH 使用较低码率。',
      autoCancel: true,
      primaryButton: { value: '使用兼容配置', action: () => this.openMoonlight(peer, state, false) },
      secondaryButton: { value: '使用原有配置', action: () => this.openMoonlight(peer, state, true) }
    });
  }

  private openMoonlight(peer: PeerSummary, state: DeviceStreamingState, useOriginalProfile: boolean): void {
    this.ensureStreamingServices();
    const host: string = this.primaryTailscaleAddress(peer.addresses);
    this.recordDiagnosticEvent('moonlight_launch_attempt', state.path.type);
    this.moonlightLauncher!.isAvailable().then((available: boolean) => {
      if (!available) {
        this.updateStreamingState(peer.key, this.copyStreamingState(this.streamingState(peer.key),
          undefined, undefined, undefined, false));
        this.getUIContext().showAlertDialog({
          title: '需要 MoonlightOH',
          message: 'MeshArc 使用 MoonlightOH 连接 Sunshine 串流服务。',
          autoCancel: true,
          primaryButton: { value: '取消', action: () => {} },
          secondaryButton: { value: '复制主机地址', action: () => this.copyDeviceValue(host, $r('app.string.peer_ip_copied')) }
        });
        return;
      }
      const originalProfile: StreamLaunchProfile = { profileName: 'default', allowUserOverride: true };
      const profile = useOriginalProfile ? originalProfile : buildStreamProfile(state.path);
      return this.moonlightLauncher!.launch({
        protocolVersion: 1,
        action: 'openHost',
        source: 'MeshArc',
        host: host,
        displayName: peer.name,
        dnsName: peer.name,
        pathType: state.path.type,
        relayRegion: state.path.relayRegion,
        latencyMs: state.path.latencyMs,
        streamProfile: profile
      }).then(() => {
        this.updateStreamingState(peer.key, this.copyStreamingState(this.streamingState(peer.key),
          undefined, undefined, undefined, false));
        this.recordDiagnosticEvent('moonlight_launch_success', state.path.type);
      });
    }).catch(() => {
      this.updateStreamingState(peer.key, this.copyStreamingState(this.streamingState(peer.key),
        undefined, undefined, undefined, false));
      this.recordDiagnosticEvent('moonlight_launch_failed', state.path.type);
      this.showToast('无法打开 MoonlightOH，请稍后重试。');
    });
  }

  private launchMediaForPeer(peer: PeerSummary): void {
    const state: DeviceMediaState = this.mediaState(peer.key);
    if (state.checking || state.launching) {
      return;
    }
    if (state.result.services.length === 0) {
      this.detectMediaForPeer(peer, true);
      return;
    }
    const service: DiscoveredMediaService = state.result.services[0];
    this.openHosPlayer(peer, service);
  }

  private openHosPlayer(peer: PeerSummary, service: DiscoveredMediaService): void {
    this.ensureMediaServices();
    const state: DeviceMediaState = this.mediaState(peer.key);
    const path: PeerPathResult = this.streamingState(peer.key).path;
    this.updateMediaState(peer.key, {
      peerKey: peer.key,
      result: state.result,
      checking: false,
      launching: true
    });
    this.recordDiagnosticEvent('hosplayer_launch_attempt', service.type);
    try {
      const request: HosPlayerLaunchRequest = {
        protocolVersion: 1,
        action: 'add',
        type: service.type,
        url: service.url,
        name: `${this.peerDisplayName(peer.name)} · ${service.name}`,
        network: 'tailnet',
        route: path.type,
        source: 'mesharc'
      };
      const prototypeUri: string = this.hosPlayerLauncher!.buildUri(request);
      if (!this.hosPlayerLauncher!.isEnabled()) {
        this.updateMediaState(peer.key, {
          peerKey: peer.key,
          result: state.result,
          checking: false,
          launching: false
        });
        this.recordDiagnosticEvent('hosplayer_contract_previewed', service.type);
        this.getUIContext().showAlertDialog({
          title: 'HosPlayer 联动协议原型',
          message: `已识别 ${service.name}。当前原型会传递服务类型、服务器地址、设备名称和网络路径；` +
            '不包含用户名、密码或访问令牌。等待 HosPlayer 发布正式接收协议后即可直接拉起。',
          autoCancel: true,
          primaryButton: { value: '关闭', action: () => {} },
          secondaryButton: {
            value: '复制参数链接',
            action: () => this.copyPlainText(prototypeUri, 'HosPlayer 参数原型已复制')
          }
        });
        return;
      }
      this.hosPlayerLauncher!.launch(request).then(() => {
        this.updateMediaState(peer.key, {
          peerKey: peer.key,
          result: this.mediaState(peer.key).result,
          checking: false,
          launching: false
        });
        this.recordDiagnosticEvent('hosplayer_launch_success', service.type);
      }).catch(() => {
        this.updateMediaState(peer.key, {
          peerKey: peer.key,
          result: this.mediaState(peer.key).result,
          checking: false,
          launching: false
        });
        this.recordDiagnosticEvent('hosplayer_launch_failed', service.type);
        this.showToast('无法打开 HosPlayer，请稍后重试。');
      });
    } catch (_error) {
      this.updateMediaState(peer.key, {
        peerKey: peer.key,
        result: state.result,
        checking: false,
        launching: false
      });
      this.recordDiagnosticEvent('hosplayer_contract_rejected', service.type);
      this.showToast('服务器地址不符合安全传参规则。');
    }
  }

  private copyPlainText(value: string, successMessage: string): void {
    const data: pasteboard.PasteData = pasteboard.createData(
      pasteboard.MIMETYPE_TEXT_PLAIN, value);
    pasteboard.getSystemPasteboard().setData(data)
      .then(() => this.showToast(successMessage))
      .catch(() => this.showToast($r('app.string.device_copy_failed')));
  }

  private runMediaIntegrationSelfTest(): void {
    if (this.mediaSelfTestInProgress) {
      return;
    }
    this.ensureMediaServices();
    this.mediaSelfTestInProgress = true;
    this.mediaSelfTestStatus = '正在运行离线测试…';
    this.recordDiagnosticEvent('media_self_test_started', 'offline');
    const requestGeneration: number = this.diagnosticMediaRequestGuard.begin();
    this.accountDiagnosticsGateway.runMediaProbeSelfTest().then((resultText: string) => {
      if (!this.diagnosticMediaRequestGuard.isCurrent(requestGeneration)) {
        return;
      }
      const nativeResult: MediaProbeSelfTestResult =
        JSON.parse(resultText) as MediaProbeSelfTestResult;
      const contractResult: string = this.hosPlayerLauncher!.runOfflineSelfTest();
      const passed: boolean = nativeResult.state === 'passed' &&
        nativeResult.cases === 4 && contractResult.startsWith('PASS');
      this.mediaSelfTestStatus = passed ?
        'PASS · 媒体服务识别 4/4 · HosPlayer 参数协议通过' :
        'FAILED · 请导出诊断报告并检查媒体联动日志';
      this.recordDiagnosticEvent(passed ? 'media_self_test_passed' :
        'media_self_test_failed', 'offline');
    }).catch(() => {
      if (!this.diagnosticMediaRequestGuard.isCurrent(requestGeneration)) {
        return;
      }
      this.mediaSelfTestStatus = 'FAILED · 无法运行媒体服务离线测试';
      this.recordDiagnosticEvent('media_self_test_failed', 'native_bridge');
    }).finally(() => {
      if (this.diagnosticMediaRequestGuard.isCurrent(requestGeneration)) {
        this.mediaSelfTestInProgress = false;
      }
    });
  }

  private copyHosPlayerPrototype(): void {
    this.ensureMediaServices();
    try {
      const result: string = this.hosPlayerLauncher!.runOfflineSelfTest();
      const separator: number = result.indexOf(' | ');
      if (separator < 0) {
        throw new Error('prototype_unavailable');
      }
      this.copyPlainText(result.substring(separator + 3), 'HosPlayer 参数原型已复制');
      this.recordDiagnosticEvent('hosplayer_contract_copied', 'offline');
    } catch (_error) {
      this.showToast('无法生成 HosPlayer 参数原型。');
      this.recordDiagnosticEvent('hosplayer_contract_failed', 'offline');
    }
  }

  private copyDeviceValue(value: string, successMessage: ResourceStr): void {
    if (value.length === 0) {
      this.showToast($r('app.string.device_copy_unavailable'));
      return;
    }
    const data: pasteboard.PasteData = pasteboard.createData(
      pasteboard.MIMETYPE_TEXT_PLAIN, value);
    pasteboard.getSystemPasteboard().setData(data)
      .then(() => this.showToast(successMessage))
      .catch(() => this.showToast($r('app.string.device_copy_failed')));
  }

  private writePrivateTextFile(path: string, content: string): boolean {
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
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

  private taildropTransferProgress(): number {
    if (this.taildropTransfer.totalBytes <= 0) {
      return this.taildropTransfer.state === 'completed' ? 100 : 0;
    }
    return Math.max(0, Math.min(100,
      Math.round(this.taildropTransfer.bytesSent * 100 / this.taildropTransfer.totalBytes)));
  }

  private resetTaildropProgressEstimate(): void {
    this.taildropTransferRate = 0;
    this.taildropTransferEtaSeconds = 0;
    this.taildropProgressSampleRequestId = 0;
    this.taildropProgressSampleBytes = 0;
    this.taildropProgressSampleMs = 0;
  }

  private updateTaildropProgressEstimate(transfer: TaildropTransferSummary): void {
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
      this.taildropTransferRate = 0;
      this.taildropTransferEtaSeconds = 0;
      return;
    }
    const elapsedMs: number = nowMs - this.taildropProgressSampleMs;
    if (elapsedMs < 500) {
      return;
    }
    const byteDelta: number = transfer.bytesSent - this.taildropProgressSampleBytes;
    if (byteDelta <= 0) {
      if (elapsedMs >= 3000) {
        this.taildropTransferRate = 0;
        this.taildropTransferEtaSeconds = 0;
        this.taildropProgressSampleMs = nowMs;
      }
      return;
    }
    const measuredRate: number = Math.round(byteDelta * 1000 / elapsedMs);
    this.taildropTransferRate = this.taildropTransferRate > 0 ?
      Math.round(this.taildropTransferRate * 0.55 + measuredRate * 0.45) : measuredRate;
    const remainingBytes: number = Math.max(0, transfer.totalBytes - transfer.bytesSent);
    this.taildropTransferEtaSeconds = this.taildropTransferRate > 0 ?
      Math.ceil(remainingBytes / this.taildropTransferRate) : 0;
    this.taildropProgressSampleBytes = transfer.bytesSent;
    this.taildropProgressSampleMs = nowMs;
  }

  private formatTransferDuration(seconds: number): string {
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

  private taildropTransferSpeedText(): ResourceStr {
    if (this.taildropPreparing || this.taildropTransfer.state === 'queued') {
      return $r('app.string.transfer_waiting_for_backend');
    }
    if (this.taildropTransferRate <= 0 || this.taildropTransferEtaSeconds <= 0) {
      return $r('app.string.transfer_calculating_speed');
    }
    return $r('app.string.transfer_speed_eta',
      this.formatTrafficBytes(this.taildropTransferRate, true),
      this.formatTransferDuration(this.taildropTransferEtaSeconds));
  }

  private taildropFileExtension(name: string): string {
    const dotIndex: number = name.lastIndexOf('.');
    if (dotIndex < 0 || dotIndex === name.length - 1) {
      return '';
    }
    return name.substring(dotIndex + 1).toLowerCase();
  }

  private taildropFileTitle(name: string): string {
    const dotIndex: number = name.lastIndexOf('.');
    return dotIndex > 0 ? name.substring(0, dotIndex) : name;
  }

  private taildropGalleryAssetTitle(name: string): string {
    let title: string = this.taildropFileTitle(this.sanitizeTaildropFileName(name, 0))
      .replace(/[\\/:*?"'`<>|{}\[\]]/g, '_').trim();
    if (title.length === 0 || title === '.' || title === '..') {
      title = 'received_image';
    }
    return title.length > 180 ? title.substring(0, 180) : title;
  }

  private taildropContentKind(file: TaildropWaitingFileSummary): string {
    const extension: string = this.taildropFileExtension(file.name);
    if (TAILDROP_IMAGE_EXTENSIONS.includes(extension)) {
      return 'image';
    }
    if (TAILDROP_VIDEO_EXTENSIONS.includes(extension)) {
      return 'video';
    }
    if (file.size <= TAILDROP_TEXT_CLIPBOARD_MAX_BYTES && TAILDROP_TEXT_EXTENSIONS.includes(extension)) {
      return 'text';
    }
    return 'file';
  }

  private taildropInboxKey(file: TaildropWaitingFileSummary): string {
    return `${file.name}\n${file.size}`;
  }

  private taildropContentKindText(file: TaildropWaitingFileSummary): ResourceStr {
    const kind: string = this.taildropContentKind(file);
    if (kind === 'image') {
      return $r('app.string.transfer_content_image');
    }
    if (kind === 'video') {
      return $r('app.string.transfer_content_video');
    }
    if (kind === 'text') {
      return $r('app.string.transfer_content_text');
    }
    return $r('app.string.transfer_content_file');
  }

  private taildropFileSymbol(name: string): Resource {
    const extension: string = this.taildropFileExtension(name);
    if (TAILDROP_IMAGE_EXTENSIONS.includes(extension)) {
      return $r('sys.symbol.picture');
    }
    if (TAILDROP_VIDEO_EXTENSIONS.includes(extension)) {
      return $r('sys.symbol.video');
    }
    if (TAILDROP_TEXT_EXTENSIONS.includes(extension)) {
      return $r('sys.symbol.doc_plaintext');
    }
    if (extension === 'pdf') {
      return $r('sys.symbol.pdf_doc');
    }
    if (['zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz'].includes(extension)) {
      return $r('sys.symbol.doc_zipper');
    }
    if (extension === 'hap' || extension === 'hsp' || extension === 'har' ||
      extension === 'app' || extension === 'apk') {
      return $r('sys.symbol.archivebox');
    }
    return $r('sys.symbol.doc');
  }

  private taildropFileIconColor(name: string): ResourceColor {
    const extension: string = this.taildropFileExtension(name);
    if (extension === 'pdf' || ['mp3', 'm4a', 'wav', 'flac', 'aac', 'ogg', 'opus'].includes(extension) ||
      TAILDROP_IMAGE_EXTENSIONS.includes(extension) || TAILDROP_VIDEO_EXTENSIONS.includes(extension)) {
      return $r('app.color.transfer_file_icon_red');
    }
    if (['zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz'].includes(extension)) {
      return $r('app.color.transfer_file_icon_yellow');
    }
    if (extension === 'hap' || extension === 'hsp' || extension === 'har' ||
      extension === 'app' || extension === 'apk') {
      return $r('app.color.transfer_file_icon_neutral');
    }
    return $r('app.color.transfer_file_icon_blue');
  }

  private taildropReceiveMatches(file: TaildropWaitingFileSummary): boolean {
    return this.taildropReceiveInProgress && this.taildropReceive.name === file.name;
  }

  private taildropReceiveRowLoading(file: TaildropWaitingFileSummary): boolean {
    if (!this.taildropReceiveMatches(file)) {
      return false;
    }
    if (this.taildropReceiveStrategy === 'media-prefetch') {
      return false;
    }
    return this.taildropMediaSaveInProgress ||
      (this.taildropReceive.state !== 'awaiting_gallery_save' &&
        this.taildropReceive.state !== 'awaiting_text_preview');
  }

  private taildropPreparedMediaSaveEnabled(file: TaildropWaitingFileSummary): boolean {
    if (this.findTaildropMediaPreview(file) === undefined || this.taildropSendActive() ||
      (this.taildropReceiveMatches(file) && this.taildropMediaSaveInProgress)) {
      return false;
    }
    if (!this.taildropReceiveInProgress || this.taildropReceiveStrategy === 'media-prefetch' ||
      this.taildropReceiveStrategy === 'file-prefetch' ||
      this.taildropReceive.state === 'awaiting_text_preview') {
      return true;
    }
    return this.taildropReceiveMatches(file) &&
      this.taildropReceive.state === 'awaiting_gallery_save';
  }

  private taildropTextPreviewLoading(file: TaildropWaitingFileSummary): boolean {
    return this.taildropReceiveMatches(file) &&
      this.taildropReceiveStrategy === 'text-preview' &&
      this.taildropReceive.state !== 'awaiting_text_preview';
  }

  private findTaildropMediaPreview(
    file: TaildropWaitingFileSummary
  ): TaildropMediaPreview | undefined {
    return this.taildropMediaPreviews.find((preview: TaildropMediaPreview) =>
      preview.name === file.name && preview.size === file.size);
  }

  private findTaildropCachedFile(
    file: TaildropWaitingFileSummary
  ): TaildropCachedFile | undefined {
    return this.taildropCachedFiles.find((cached: TaildropCachedFile) =>
      cached.name === file.name && cached.size === file.size &&
      this.validTaildropCachedFile(cached));
  }

  private validTaildropMediaPreview(preview: TaildropMediaPreview): boolean {
    const mediaType: photoAccessHelper.PhotoType | undefined =
      this.resolveTaildropMediaType(preview.name);
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
    // Keep a locally staged image usable when its derived JPEG thumbnail was
    // lost during an offline transition or cache cleanup. The source file is
    // still a valid preview fallback and, more importantly, is the bytes used
    // by the offline save action.
    return mediaType === photoAccessHelper.PhotoType.IMAGE ||
      mediaType === photoAccessHelper.PhotoType.VIDEO || hasValidThumbnail;
  }

  private validTaildropCachedFile(cached: TaildropCachedFile): boolean {
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

  private taildropWaitingFilePreviewUri(file: TaildropWaitingFileSummary): string {
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

  private taildropHistoryPreviewUri(record: TaildropTransferRecord): string {
    if (record.fileCount !== 1 || this.resolveTaildropMediaType(record.fileName) === undefined) {
      return '';
    }
    return this.taildropPreviewUri(record.previewPath);
  }

  private taildropTransferStatusText(record: TaildropTransferRecord): ResourceStr {
    if (record.state === 'completed') {
      return record.direction === 'receive' ? $r('app.string.transfer_received_status') :
        $r('app.string.transfer_sent_status');
    }
    return $r('app.string.transfer_failed_status');
  }

  private taildropTransferStatusColor(record: TaildropTransferRecord): ResourceColor {
    if (record.state === 'completed') {
      return $r('app.color.status_success');
    }
    if (record.state === 'failed') {
      return $r('app.color.status_error');
    }
    return $r('sys.color.icon_emphasize');
  }

  private taildropTransferRecordTitle(record: TaildropTransferRecord): string {
    const fileName: string = record.fileName.trim();
    if (fileName.length > 0) {
      return record.fileCount > 1 ? fileName + ' (' + record.fileCount + ' files)' : fileName;
    }
    return record.direction === 'send' ? record.targetName : 'Received file';
  }

  private taildropTransferRecordDescription(record: TaildropTransferRecord): string {
    const size: string = this.formatTrafficBytes(record.totalBytes);
    if (record.direction === 'send' && record.fileCount <= 1 && record.targetName.length > 0) {
      return `${size} · ${record.targetName}`;
    }
    return record.fileCount > 1 ? record.fileCount + ' files · ' + size + ' · ' + record.targetName :
      size + (record.direction === 'send' && record.targetName.length > 0 ? ' · ' + record.targetName : '');
  }

  private taildropHistoryPath(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return `${context.filesDir}/${TAILDROP_HISTORY_FILE_NAME}`;
  }

  private taildropInboxSnapshotPath(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return `${context.filesDir}/${TAILDROP_INBOX_SNAPSHOT_FILE_NAME}`;
  }

  private taildropHistoryMediaRoot(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return `${context.filesDir}/${TAILDROP_HISTORY_MEDIA_DIR_NAME}`;
  }

  private taildropPreviewUri(path: string): string {
    return this.taildropContentGateway.previewUri(path,
      (candidate: string): boolean => fileIo.accessSync(candidate),
      (candidate: string): string => fileUri.getUriFromPath(candidate));
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

  private queueTaildropPendingDelete(file: TaildropWaitingFileSummary): void {
    if (!this.isValidTaildropWaitingFile(file)) {
      return;
    }
    const remaining: TaildropWaitingFileSummary[] = this.taildropPendingDeletes.filter(
      (pending: TaildropWaitingFileSummary) => pending.name !== file.name);
    this.taildropPendingDeletes = remaining.concat([{
      name: file.name, size: file.size, receivedAtMs: file.receivedAtMs
    }]);
    this.taildropPendingDeleteRetryAtMs = 0;
  }

  private queueTaildropPendingDeletes(files: TaildropWaitingFileSummary[]): void {
    files.forEach((file: TaildropWaitingFileSummary) => this.queueTaildropPendingDelete(file));
  }

  private reconcileTaildropPendingDeletes(files: TaildropWaitingFileSummary[]): boolean {
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

  private removeTaildropMediaPreview(name: string, size: number, deleteFile: boolean): void {
    const removed: TaildropMediaPreview[] = this.taildropMediaPreviews.filter(
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
    this.taildropMediaPreviews = this.taildropMediaPreviews.filter(
      (preview: TaildropMediaPreview) => preview.name !== name || preview.size !== size);
    if (deleteFile && removed.length > 0) {
      this.notifyCacheContentsChanged();
    }
  }

  private removeTaildropCachedFile(name: string, size: number, deleteFile: boolean): void {
    const removed: TaildropCachedFile[] = this.taildropCachedFiles.filter(
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
    this.taildropCachedFiles = this.taildropCachedFiles.filter(
      (cached: TaildropCachedFile) => cached.name !== name || cached.size !== size);
    if (deleteFile && removed.length > 0) {
      this.notifyCacheContentsChanged();
    }
  }

  private reconcileTaildropMediaPreviews(files: TaildropWaitingFileSummary[]): void {
    const stale: TaildropMediaPreview[] = this.taildropMediaPreviews.filter(
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
    const validPreviews: TaildropMediaPreview[] = this.taildropMediaPreviews.filter(
      (preview: TaildropMediaPreview) => files.some((file: TaildropWaitingFileSummary) =>
        file.name === preview.name && file.size === preview.size) &&
        this.validTaildropMediaPreview(preview));
    const previewsChanged: boolean =
      JSON.stringify(this.taildropMediaPreviews) !== JSON.stringify(validPreviews);
    if (previewsChanged) {
      this.taildropMediaPreviews = validPreviews;
    }
    const staleCachedFiles: TaildropCachedFile[] = this.taildropCachedFiles.filter(
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
    const validCachedFiles: TaildropCachedFile[] = this.taildropCachedFiles.filter(
      (cached: TaildropCachedFile) => files.some((file: TaildropWaitingFileSummary) =>
        file.name === cached.name && file.size === cached.size) &&
      this.validTaildropCachedFile(cached));
    const cachedFilesChanged: boolean =
      JSON.stringify(this.taildropCachedFiles) !== JSON.stringify(validCachedFiles);
    if (cachedFilesChanged) {
      this.taildropCachedFiles = validCachedFiles;
    }
    if (stale.length > 0 || staleCachedFiles.length > 0) {
      this.notifyCacheContentsChanged();
    }
    if (previewsChanged || cachedFilesChanged || stale.length > 0 || staleCachedFiles.length > 0) {
      this.persistTaildropInbox();
    }
    this.taildropAutoPrefetchFailedKeys = this.taildropAutoPrefetchFailedKeys.filter(
      (key: string) => files.some((file: TaildropWaitingFileSummary) =>
        this.taildropWaitingFileKey(file) === key));
  }

  private prefetchTaildropInboxFiles(files: TaildropWaitingFileSummary[], connected: boolean = this.isConnected()): void {
    // Only a ready snapshot with an empty inbox error is authoritative. An
    // unavailable/disconnected snapshot can contain no files even though the
    // local staged media is still valid and must remain saveable offline.
    if (connected && this.taildropState === 'ready' && this.taildropInboxReason.length === 0) {
      this.reconcileTaildropMediaPreviews(files);
    }
    if (this.taildropAutoPrefetchKey.length > 0 &&
      !files.some((file: TaildropWaitingFileSummary) =>
        this.taildropWaitingFileKey(file) === this.taildropAutoPrefetchKey)) {
      this.taildropAutoPrefetchKey = '';
    }
    if ((!connected && !this.backendStatus.includes('state=Running')) ||
      this.taildropState !== 'ready' || this.taildropReceiveInProgress ||
      this.taildropPickerOpen || this.taildropPreparing || this.taildropTransfer.state === 'queued' ||
      this.taildropTransfer.state === 'sending' || this.taildropAutoPrefetchKey.length > 0) {
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

  private async createTaildropHistoryPreview(
    sourcePath: string, name: string, requestId: number
  ): Promise<string> {
    const mediaType: photoAccessHelper.PhotoType | undefined = this.resolveTaildropMediaType(name);
    if (mediaType === undefined || sourcePath.length === 0) {
      return '';
    }
    const root: string = this.taildropHistoryMediaRoot();
    const destination: string = `${root}/receive-${requestId}-thumb.jpg`;
    return this.createTaildropMediaThumbnail(mediaType, sourcePath, destination);
  }

  private async createTaildropMediaThumbnail(
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
      const packed: ArrayBuffer = await imagePacker.packToData(pixelMap, {
        format: 'image/jpeg',
        quality: TAILDROP_THUMBNAIL_JPEG_QUALITY
      });
      if (packed.byteLength <= 0) {
        return '';
      }
      destinationFile = fileIo.openSync(destination,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      const written: number = fileIo.writeSync(destinationFile.fd, packed);
      fileIo.closeSync(destinationFile);
      destinationFile = undefined;
      const stat: fileIo.Stat = fileIo.statSync(destination);
      if (!stat.isFile() || stat.size !== written || written !== packed.byteLength) {
        fileIo.unlinkSync(destination);
        return '';
      }
      this.notifyCacheContentsChanged();
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

  private async createTaildropThumbnail(sourcePath: string, destination: string): Promise<string> {
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
      pixelMap = await imageSource.createPixelMap({
        index: 0,
        desiredSize: { width: width, height: height }
      });
      return await this.writeTaildropThumbnail(pixelMap, destination);
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      this.recordDiagnosticEvent(
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

  private async createTaildropVideoThumbnail(
    sourcePath: string,
    destination: string
  ): Promise<string> {
    let sourceFile: fileIo.File | undefined = undefined;
    let extractor: media.AVMetadataExtractor | undefined = undefined;
    let pixelMap: image.PixelMap | undefined = undefined;
    try {
      sourceFile = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(sourceFile.fd);
      extractor = await media.createAVMetadataExtractor();
      extractor.fdSrc = { fd: sourceFile.fd, offset: 0, length: stat.size };
      const metadata: media.AVMetadata = await extractor.fetchMetadata();
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
      pixelMap = await extractor.fetchFrameByTime(
        frameTimeUs,
        media.AVImageQueryOptions.AV_IMAGE_QUERY_CLOSEST_SYNC,
        { width: width, height: height });
      return await this.writeTaildropThumbnail(pixelMap, destination);
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      this.recordDiagnosticEvent(
        'taildrop_thumbnail_failed', 'video', businessError.code ?? -1);
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
      if (extractor !== undefined) {
        try {
          await extractor.release();
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
    const destination: string = `${this.taildropInboxRoot()}/${preview.requestId}-thumb.jpg`;
    this.createTaildropVideoThumbnail(preview.path, destination).then((thumbnailPath: string) => {
      if (thumbnailPath.length === 0) {
        return;
      }
      const stillWaiting: boolean = this.taildropWaitingFiles.some(
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
      this.taildropMediaPreviews = this.taildropMediaPreviews.filter(
        (candidate: TaildropMediaPreview) =>
          candidate.name !== hydrated.name || candidate.size !== hydrated.size).concat([hydrated]);
      this.taildropCachedFiles = this.taildropCachedFiles.filter(
        (cached: TaildropCachedFile) => cached.name !== hydrated.name || cached.size !== hydrated.size);
      this.persistTaildropInbox();
      this.notifyCacheContentsChanged();
    }).catch(() => {
      // The normal media prefetch path retries thumbnail generation when connected.
    });
  }

  private cleanupTaildropHistoryMedia(): void {
    const root: string = this.taildropHistoryMediaRoot();
    try {
      if (!fileIo.accessSync(root)) {
        return;
      }
      const referenced: Set<string> = new Set<string>(this.taildropHistory
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
        this.notifyCacheContentsChanged();
      }
    } catch (_error) {
      // Preview cleanup is best effort and must not affect transfer history.
    }
  }

  private validTaildropHistoryRecord(record: TaildropTransferRecord): boolean {
    return record.requestId > 0 && (record.direction === 'send' || record.direction === 'receive') &&
      (record.state === 'completed' || record.state === 'failed') && record.fileCount > 0 &&
      record.totalBytes >= 0 && record.completedAtMs > 0 && record.fileName.length <= 255;
  }

  private loadTaildropHistory(): void {
    try {
      const path: string = this.taildropHistoryPath();
      if (!fileIo.accessSync(path)) {
        return;
      }
      const records: TaildropTransferRecord[] | undefined = this.taildropContentGateway.loadHistory(
        fileIo.readTextSync(path), TAILDROP_HISTORY_LIMIT,
        (record: TaildropTransferRecord): boolean => this.validTaildropHistoryRecord(record));
      if (records === undefined) {
        throw new Error('Taildrop history is invalid.');
      }
      this.taildropHistory = records;
      this.cleanupTaildropHistoryMedia();
      records.forEach((record: TaildropTransferRecord) => {
        if (record.direction === 'send') {
          this.lastHandledTaildropRequestId = Math.max(this.lastHandledTaildropRequestId, record.requestId);
        }
      });
    } catch (_error) {
      this.taildropHistory = [];
    }
  }

  private persistTaildropHistory(): void {
    const path: string = this.taildropHistoryPath();
    const temporaryPath: string = `${path}.tmp`;
    const persisted: PersistedTaildropHistory = {
      records: this.taildropHistory.slice(0, TAILDROP_HISTORY_LIMIT)
    };
    if (!this.writePrivateTextFile(temporaryPath, JSON.stringify(persisted))) {
      return;
    }
    try {
      fileIo.renameSync(temporaryPath, path);
      this.cleanupTaildropHistoryMedia();
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

  private clearTaildropHistory(): void {
    this.taildropHistory = [];
    const path: string = this.taildropHistoryPath();
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (_error) {
      this.writePrivateTextFile(path, JSON.stringify({ records: [] } as PersistedTaildropHistory));
    }
    this.cleanupTaildropHistoryMedia();
    this.showToast($r('app.string.transfer_history_cleared'));
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

  private taildropOutboxRoot(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return RecoverableCachePaths.taildropOutboxRoot(context);
  }

  private taildropSendRequestPath(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return `${context.filesDir}/${TAILDROP_SEND_REQUEST_FILE_NAME}`;
  }

  private taildropCancelRequestPath(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return `${context.filesDir}/${TAILDROP_CANCEL_REQUEST_FILE_NAME}`;
  }

  private taildropInboxRoot(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return `${context.filesDir}/${TAILDROP_INBOX_DIR_NAME}`;
  }

  private taildropReceiveRequestPath(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return `${context.filesDir}/${TAILDROP_RECEIVE_REQUEST_FILE_NAME}`;
  }

  private taildropReceiveResponsePath(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return `${context.filesDir}/${TAILDROP_RECEIVE_RESPONSE_FILE_NAME}`;
  }

  private taildropSendActive(): boolean {
    return this.taildropPickerOpen || this.taildropPreparing || this.taildropTransfer.state === 'queued' ||
      this.taildropTransfer.state === 'sending';
  }

  private taildropContentChoiceEnabled(): boolean {
    return !this.taildropPreparing && this.taildropTransfer.state !== 'queued' &&
      this.taildropTransfer.state !== 'sending' &&
      (!this.taildropPickerOpen || this.taildropTextEditorVisible);
  }

  private taildropTextEditorMatches(target: TaildropTargetSummary): boolean {
    return this.taildropTextEditorVisible && this.taildropTextTarget !== undefined &&
      this.taildropTextTarget.key === target.key;
  }

  private closeTaildropTextEditor(): void {
    this.taildropTextEditorVisible = false;
    this.taildropPickerOpen = false;
    this.taildropTextTarget = undefined;
  }

  private interruptTaildropPrefetch(): void {
    if (this.taildropReceiveInProgress &&
      (this.taildropReceiveStrategy === 'media-prefetch' ||
        this.taildropReceiveStrategy === 'file-prefetch')) {
      this.taildropAutoPrefetchKey = '';
      this.resetTaildropReceiveOperation();
    }
  }

  private loadPersistedTaildropInbox(): void {
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
        .map((file: TaildropWaitingFileSummary, index: number): TaildropWaitingFileSummary => ({
          name: file.name,
          size: file.size,
          receivedAtMs: this.taildropWaitingFileTimestamp(file, persistedAtMs - index)
        }))
        .filter((file: TaildropWaitingFileSummary, index: number, files: TaildropWaitingFileSummary[]) =>
          files.findIndex((candidate: TaildropWaitingFileSummary) => candidate.name === file.name) === index);
      this.taildropWaitingFiles = this.sortTaildropWaitingFiles(persisted.files.filter(
        (file: TaildropWaitingFileSummary) => this.isTaildropWaitingFileShapeValid(file))
        .map((file: TaildropWaitingFileSummary, index: number): TaildropWaitingFileSummary => ({
          name: file.name,
          size: file.size,
          receivedAtMs: this.taildropWaitingFileTimestamp(file, persistedAtMs - index)
        }))
        .filter((file: TaildropWaitingFileSummary) => !this.isTaildropPendingDelete(file)));
      this.taildropInboxReason = persisted.inboxReason;
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
        const stillWaiting: boolean = this.taildropWaitingFiles.some(
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
      this.taildropMediaPreviews = normalizedMediaPreviews;
      let persistedInboxChanged: boolean =
        JSON.stringify(persisted.files) !== JSON.stringify(this.taildropWaitingFiles) ||
        JSON.stringify(pendingDeletes) !== JSON.stringify(this.taildropPendingDeletes) ||
        JSON.stringify(mediaPreviews) !== JSON.stringify(normalizedMediaPreviews);
      const cachedFiles: TaildropCachedFile[] =
        persisted.cachedFiles === undefined ? [] : persisted.cachedFiles;
      this.taildropCachedFiles = this.taildropContentGateway.restoreCachedFiles(
        cachedFiles, this.taildropWaitingFiles,
        (cached: TaildropCachedFile): boolean => this.validTaildropCachedFile(cached));
      persistedInboxChanged = persistedInboxChanged ||
        JSON.stringify(cachedFiles) !== JSON.stringify(this.taildropCachedFiles);
      const promotedMedia: TaildropMediaPreview[] = [];
      this.taildropCachedFiles.forEach((cached: TaildropCachedFile) => {
        const mediaType: photoAccessHelper.PhotoType | undefined =
          this.resolveTaildropMediaType(cached.name);
        if (mediaType !== undefined &&
          !this.taildropMediaPreviews.some((preview: TaildropMediaPreview) =>
            preview.name === cached.name && preview.size === cached.size)) {
          const normalizedPath: string | undefined = this.normalizeTaildropMediaPath(
            cached.name, cached.size, cached.path);
          if (normalizedPath === undefined) {
            return;
          }
          promotedMedia.push({
            requestId: cached.requestId,
            name: cached.name,
            size: cached.size,
            path: normalizedPath,
            thumbnailPath: '',
            mediaType: mediaType
          });
        }
      });
      if (promotedMedia.length > 0) {
        this.taildropMediaPreviews = this.taildropMediaPreviews.concat(promotedMedia);
        this.taildropCachedFiles = this.taildropCachedFiles.filter((cached: TaildropCachedFile) =>
          !promotedMedia.some((preview: TaildropMediaPreview) =>
            preview.requestId === cached.requestId && preview.name === cached.name &&
            preview.size === cached.size));
        persistedInboxChanged = true;
        promotedMedia.filter((preview: TaildropMediaPreview) =>
          preview.mediaType === photoAccessHelper.PhotoType.VIDEO).forEach(
            (preview: TaildropMediaPreview) => videoPreviewsToHydrate.push(preview));
      }
      if (persistedInboxChanged) {
        this.persistTaildropInbox();
      }
      videoPreviewsToHydrate.forEach((preview: TaildropMediaPreview) =>
        this.hydrateTaildropVideoPreview(preview));
    } catch (_error) {
      if (!this.taildropContentGateway.isCurrentRecovery(recoveryGeneration)) {
        return;
      }
      this.taildropWaitingFiles = [];
      this.taildropInboxReason = '';
      this.taildropMediaPreviews = [];
      this.taildropCachedFiles = [];
      this.taildropPendingDeletes = [];
    }
  }

  private persistTaildropInbox(): void {
    const persisted: PersistedTaildropInbox = {
      files: this.taildropWaitingFiles,
      inboxReason: this.taildropInboxReason,
      mediaPreviews: this.taildropMediaPreviews,
      cachedFiles: this.taildropCachedFiles,
      pendingDeletes: this.taildropPendingDeletes
    };
    this.writeAtomicPrivateTextFile(this.taildropInboxSnapshotPath(), JSON.stringify(persisted));
  }

  private writeTaildropSendRequest(request: TaildropSendRequest): boolean {
    const requestPath: string = this.taildropSendRequestPath();
    return this.writeAtomicTaildropRequest(requestPath, request.requestId, JSON.stringify(request));
  }

  private sanitizeTaildropFileName(name: string, index: number): string {
    let sanitized: string = name.replace(/[\\/\u0000]/g, '_').trim();
    if (sanitized.length === 0 || sanitized === '.' || sanitized === '..') {
      sanitized = `file-${index + 1}`;
    }
    if (sanitized.length > 180) {
      sanitized = sanitized.substring(0, 180);
    }
    return sanitized;
  }

  private async prepareTaildropFiles(uris: string[], requestId: number): Promise<TaildropSendFile[]> {
    const historyMediaRoot: string = this.taildropHistoryMediaRoot();
    const prepared: TaildropSendFile[] = await this.taildropSendGateway.prepareFiles(
      uris, this.taildropOutboxRoot(), requestId,
      (name: string, index: number): string => this.sanitizeTaildropFileName(name, index),
      async (name: string, destination: string, previewRequestId: number): Promise<string> => {
        const mediaType: photoAccessHelper.PhotoType | undefined = this.resolveTaildropMediaType(name);
        return mediaType === undefined ? '' : await this.createTaildropMediaThumbnail(
          mediaType, destination, `${historyMediaRoot}/${previewRequestId}-thumb.jpg`);
      });
    this.notifyCacheContentsChanged();
    return prepared;
  }

  private cleanupPreparedTaildropFiles(files: TaildropSendFile[]): void {
    this.taildropSendGateway.cleanup(files);
    this.notifyCacheContentsChanged();
  }

  private chooseTaildropDocuments(target: TaildropTargetSummary): void {
    if (this.taildropTextEditorVisible) {
      this.closeTaildropTextEditor();
    }
    if (!this.ensureTaildropSendAvailable(target)) {
      return;
    }
    this.selectTaildropDocuments(target).catch(() => {
      this.handleTaildropSelectionFailure();
    });
  }

  private chooseTaildropPhotos(target: TaildropTargetSummary): void {
    if (this.taildropTextEditorVisible) {
      this.closeTaildropTextEditor();
    }
    if (!this.ensureTaildropSendAvailable(target)) {
      return;
    }
    this.selectTaildropMedia(target).catch(() => {
      this.handleTaildropSelectionFailure();
    });
  }

  private chooseTaildropText(target: TaildropTargetSummary): void {
    if (this.taildropTextEditorMatches(target)) {
      this.closeTaildropTextEditor();
      return;
    }
    if (this.taildropTextEditorVisible) {
      this.closeTaildropTextEditor();
    }
    if (!this.ensureTaildropSendAvailable(target)) {
      return;
    }
    this.taildropTextInput = '';
    this.taildropTextInputCanSend = false;
    this.taildropTextTarget = target;
    this.taildropPickerOpen = true;
    this.taildropTextEditorVisible = true;
  }

  private ensureTaildropSendAvailable(target: TaildropTargetSummary): boolean {
    if (!this.isConnected() || this.taildropState !== 'ready') {
      this.showToast($r('app.string.transfer_connect_first_title'));
      return false;
    }
    if (!target.online) {
      this.showToast($r('app.string.transfer_send_target_unavailable'));
      return false;
    }
    this.interruptTaildropPrefetch();
    if (this.taildropSendActive()) {
      this.showToast($r('app.string.transfer_busy_message'));
      return false;
    }
    return true;
  }

  private handleTaildropSelectionFailure(): void {
    this.taildropPickerOpen = false;
    this.taildropPreparing = false;
    this.showToast($r('app.string.transfer_file_selection_failed'));
  }

  private async selectTaildropDocuments(target: TaildropTargetSummary): Promise<void> {
    if (!target.online || !this.isConnected() || this.taildropState !== 'ready' ||
      this.taildropSendActive()) {
      return;
    }
    this.taildropPickerOpen = true;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const documentPicker = new picker.DocumentViewPicker(context);
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = TAILDROP_MAX_FILE_SELECTION;
    let uris: string[] = [];
    try {
      uris = await documentPicker.select(options);
    } finally {
      this.taildropPickerOpen = false;
    }
    if (uris.length > 0) {
      await this.queueTaildropFiles(target, uris);
    }
  }

  private async selectTaildropMedia(target: TaildropTargetSummary): Promise<void> {
    if (!target.online || !this.isConnected() || this.taildropState !== 'ready' ||
      this.taildropSendActive()) {
      return;
    }
    this.taildropPickerOpen = true;
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
      this.taildropPickerOpen = false;
    }
    if (uris.length > 0) {
      await this.queueTaildropFiles(target, uris);
    }
  }

  private onTaildropTextEditorVisibilityChanged(): void {
    if (!this.taildropTextEditorVisible) {
      this.taildropPickerOpen = false;
      this.taildropTextTarget = undefined;
      this.taildropTextInputCanSend = false;
    }
  }

  private sendTaildropText(): void {
    const target: TaildropTargetSummary | undefined = this.taildropTextTarget;
    const text: string = this.taildropTextInput;
    if (target === undefined || text.trim().length === 0) {
      return;
    }
    this.taildropTextEditorVisible = false;
    this.taildropPickerOpen = false;
    this.queueTaildropText(target, text).catch(() => {
      this.handleTaildropSelectionFailure();
    });
  }

  private async queueTaildropText(target: TaildropTargetSummary, text: string): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const path: string = `${context.cacheDir}/taildrop-text-${Date.now()}.txt`;
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
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

  private async queueTaildropFiles(target: TaildropTargetSummary, uris: string[]): Promise<void> {
    if (!target.online || !this.isConnected() || this.taildropState !== 'ready' ||
      this.taildropPreparing || this.taildropTransfer.state === 'queued' ||
      this.taildropTransfer.state === 'sending' || this.taildropReceiveInProgress) {
      return;
    }
    this.taildropPreparing = true;
    const requestId: number = Date.now();
    let files: TaildropSendFile[] = [];
    try {
      files = await this.prepareTaildropFiles(uris.slice(0, TAILDROP_MAX_MEDIA_SELECTION), requestId);
      let totalBytes: number = 0;
      files.forEach((file: TaildropSendFile) => {
        totalBytes += file.size;
      });
      const request: TaildropSendRequest = {
        requestId: requestId,
        targetKey: target.key,
        outboxRoot: this.taildropOutboxRoot(),
        files: files
      };
      this.taildropTransfer = {
        requestId: requestId, state: 'queued', reason: '', targetKey: target.key,
        targetName: target.name, fileName: '', fileIndex: 0, fileCount: files.length,
        fileBytes: 0, fileSize: 0, bytesSent: 0, totalBytes: totalBytes,
        previewPath: files.length === 1 ? files[0].previewPath : '', completedAtMs: 0
      };
      this.resetTaildropProgressEstimate();
      this.taildropRequestSubmittedAtMs = Date.now();
      if (!this.writeTaildropSendRequest(request)) {
        this.cleanupPreparedTaildropFiles(files);
        const failed: TaildropTransferSummary = this.taildropTransferFailure(
          this.taildropTransfer, 'extension_error');
        this.taildropPreparing = false;
        this.applyTaildropTransfer(failed);
        return;
      }
      this.recordDiagnosticEvent('taildrop_send_queued', 'transfer');
      this.taildropPreparing = false;
    } catch (_error) {
      this.cleanupPreparedTaildropFiles(files);
      this.taildropPreparing = false;
      this.showToast($r('app.string.transfer_file_copy_failed'));
    }
  }

  private cancelTaildropSend(): void {
    if (this.taildropCancelPending || this.taildropTransfer.requestId <= 0 ||
      (this.taildropTransfer.state !== 'queued' && this.taildropTransfer.state !== 'sending')) {
      return;
    }
    const request: TaildropCancelRequest = { requestId: this.taildropTransfer.requestId };
    if (!this.writeAtomicTaildropRequest(this.taildropCancelRequestPath(), request.requestId,
      JSON.stringify(request))) {
      this.showToast($r('app.string.transfer_cancel_failed'));
      return;
    }
    this.taildropCancelPending = true;
    this.recordDiagnosticEvent('taildrop_send_cancel_requested', 'transfer');
  }

  private retryTaildropSend(record: TaildropTransferRecord): void {
    if (record.direction !== 'send' || record.state !== 'failed' || this.taildropSendActive()) {
      return;
    }
    const target: TaildropTargetSummary | undefined = this.displayedTaildropTargets().find(
      (item: TaildropTargetSummary) => item.key === record.targetKey && item.online);
    if (target === undefined) {
      this.showToast($r('app.string.transfer_send_target_unavailable'));
      return;
    }
    this.transferScroller.scrollEdge(Edge.Top);
    this.showToast($r('app.string.transfer_retry_choose_content'));
  }

  private startTaildropReceive(file: TaildropWaitingFileSummary): void {
    if (this.taildropReceiveInProgress && this.taildropReceive.name !== file.name &&
      this.taildropReceive.state === 'awaiting_gallery_save') {
      this.resetTaildropReceiveOperation();
      this.taildropAutoPrefetchKey = '';
    }
    if (this.taildropState !== 'ready' || this.taildropSendActive() ||
      this.taildropReceiveInProgress) {
      return;
    }
    try {
      this.routeTaildropReceive(file);
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      this.recordDiagnosticEvent('taildrop_receive_submit_failed', 'transfer', businessError.code ?? -1);
      this.resetTaildropReceiveOperation();
      this.showToast($r('app.string.transfer_receive_failed'));
    }
  }

  private startTaildropTextPreview(file: TaildropWaitingFileSummary): void {
    if (this.taildropContentKind(file) !== 'text') {
      return;
    }
    if (this.taildropReceiveInProgress && this.taildropReceive.name !== file.name &&
      this.taildropReceive.state === 'awaiting_gallery_save') {
      this.resetTaildropReceiveOperation();
      this.taildropAutoPrefetchKey = '';
    }
    if (this.taildropReceiveInProgress) {
      if (this.taildropReceive.name === file.name &&
        this.taildropReceive.state === 'awaiting_text_preview') {
        return;
      }
      this.taildropPendingTextPreview = file;
      if (this.taildropReceive.state === 'awaiting_text_preview') {
        this.resetTaildropReceiveOperation();
        this.resumePendingTaildropAction();
      }
      return;
    }
    if (this.taildropSendActive()) {
      this.showToast($r('app.string.transfer_busy_message'));
      return;
    }
    const cached: TaildropCachedFile | undefined = this.findTaildropCachedFile(file);
    if (cached !== undefined) {
      this.showCachedTaildropTextPreview(cached);
      return;
    }
    if (this.taildropState !== 'ready') {
      this.showToast($r('app.string.transfer_connect_first_title'));
      return;
    }
    try {
      this.submitTaildropReceiveStage(file, undefined, 'text-preview', '');
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      this.recordDiagnosticEvent('taildrop_text_preview_submit_failed', 'transfer', businessError.code ?? -1);
      this.resetTaildropReceiveOperation();
      this.showToast($r('app.string.transfer_receive_failed'));
    }
  }

  private showCachedTaildropTextPreview(cached: TaildropCachedFile): boolean {
    const result: TaildropReceiveResult = {
      requestId: cached.requestId,
      action: 'stage',
      state: 'awaiting_text_preview',
      reason: '',
      name: cached.name,
      size: cached.size,
      path: cached.path
    };
    const content: string | undefined = this.readTaildropTextPreview(result);
    if (content === undefined) {
      this.removeTaildropCachedFile(cached.name, cached.size, true);
      this.persistTaildropInbox();
      this.showToast($r('app.string.transfer_receive_failed'));
      return false;
    }
    this.taildropReceiveStrategy = 'text-preview';
    this.taildropReceiveExpectedSize = cached.size;
    this.taildropReceiveInProgress = true;
    this.taildropReceiveStateStartedAtMs = 0;
    this.taildropReceive = result;
    this.taildropReceivedText = content;
    return true;
  }

  private resumePendingTaildropAction(): boolean {
    if (this.taildropReceiveInProgress) {
      return false;
    }
    const pendingMediaSave: TaildropWaitingFileSummary | undefined =
      this.taildropPendingMediaSave;
    this.taildropPendingMediaSave = undefined;
    if (pendingMediaSave !== undefined &&
      this.findTaildropMediaPreview(pendingMediaSave) !== undefined) {
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

  private resolveTaildropMediaType(name: string): photoAccessHelper.PhotoType | undefined {
    const extension: string = this.taildropFileExtension(name);
    if (TAILDROP_IMAGE_EXTENSIONS.includes(extension)) {
      return photoAccessHelper.PhotoType.IMAGE;
    }
    if (TAILDROP_VIDEO_EXTENSIONS.includes(extension)) {
      return photoAccessHelper.PhotoType.VIDEO;
    }
    return undefined;
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

  private async selectTaildropReceiveDestination(result: TaildropReceiveResult): Promise<string> {
    this.taildropPickerOpen = true;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const documentPicker = new picker.DocumentViewPicker(context);
    const options = new picker.DocumentSaveOptions();
    options.newFileNames = [this.sanitizeTaildropFileName(result.name, 0)];
    let uris: string[] = [];
    try {
      uris = await documentPicker.save(options);
    } catch (_error) {
      this.showToast($r('app.string.transfer_receive_picker_failed'));
    } finally {
      this.taildropPickerOpen = false;
    }
    return uris.length > 0 ? uris[0] : '';
  }

  private useDirectTaildropBackend(): boolean {
    return !this.isConnected() && this.backendStatus.includes('state=Running');
  }

  private isCurrentTaildropReceiveRequest(request: TaildropReceiveRequest): boolean {
    return this.taildropReceiveInProgress && this.taildropReceive.requestId === request.requestId &&
      this.taildropReceive.action === request.action;
  }

  private dispatchTaildropReceiveRequest(request: TaildropReceiveRequest): boolean {
    if (!this.useDirectTaildropBackend()) {
      return this.writeAtomicTaildropRequest(this.taildropReceiveRequestPath(), request.requestId,
        JSON.stringify(request));
    }
    this.taildropReceiveResponseInFlight = true;
    try {
      nativeBridge.backendTaildropReceiveAsync(JSON.stringify(request))
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
          if (!this.taildropReceiveGateway.matchesResponse(this.taildropReceive, result)) {
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
          if (!this.taildropReceiveInProgress ||
            (this.taildropReceive.requestId === request.requestId &&
              this.taildropReceive.action === request.action)) {
            this.taildropReceiveResponseInFlight = false;
          }
        });
    } catch (_error) {
      this.taildropReceiveResponseInFlight = false;
      this.failTaildropReceive('backend_unavailable');
    }
    return true;
  }

  private submitTaildropReceiveStage(
    file: TaildropWaitingFileSummary,
    mediaType?: photoAccessHelper.PhotoType,
    strategy: string = 'file',
    destinationUri: string = ''
  ): void {
    if (this.taildropState !== 'ready' || this.taildropSendActive()) {
      return;
    }
    const requestId: number = Date.now();
    const inboxRoot: string = this.taildropInboxRoot();
    if (!this.ensureTaildropDirectory(inboxRoot)) {
      this.recordDiagnosticEvent('taildrop_receive_inbox_unavailable', 'transfer');
      this.showToast($r('app.string.transfer_receive_failed'));
      return;
    }
    this.taildropReceiveInProgress = true;
    const request: TaildropReceiveRequest = this.taildropReceiveGateway.createStageRequest(
      requestId, file.name, inboxRoot);
    this.taildropReceiveStrategy = strategy;
    this.taildropReceiveDestinationUri = destinationUri;
    this.taildropReceiveExpectedSize = file.size;
    this.taildropReceiveMediaType = mediaType;
    this.taildropReceive = {
      requestId: requestId, action: 'stage', state: 'requesting', reason: '', name: file.name,
      size: file.size, path: request.path
    };
    this.taildropReceiveStateStartedAtMs = Date.now();
    this.writePrivateTextFile(this.taildropReceiveResponsePath(), '');
    if (!this.dispatchTaildropReceiveRequest(request)) {
      this.failTaildropReceive('extension_error');
      return;
    }
    this.recordDiagnosticEvent(mediaType === undefined ? 'taildrop_receive_queued' :
      'taildrop_media_receive_queued', 'transfer');
  }

  private ensureTaildropDirectory(path: string): boolean {
    try {
      if (!fileIo.accessSync(path)) {
        fileIo.mkdirSync(path, true);
      }
      return fileIo.accessSync(path) && fileIo.statSync(path).isDirectory();
    } catch (_error) {
      try {
        // mkdirSync may report 13900015 when another operation already created
        // the directory. Treat an existing directory as a successful outcome.
        return fileIo.accessSync(path) && fileIo.statSync(path).isDirectory();
      } catch (_verificationError) {
        return false;
      }
    }
  }

  private confirmDiscardTaildropFile(file: TaildropWaitingFileSummary): void {
    if (this.taildropSendActive()) {
      this.showToast($r('app.string.transfer_busy_message'));
      return;
    }
    this.getUIContext().showAlertDialog({
      title: $r('app.string.transfer_discard_confirm_title'),
      message: $r('app.string.transfer_discard_confirm_message', file.name),
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.cancel_action'),
        action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.transfer_discard_action'),
        fontColor: $r('app.color.status_error'),
        action: () => this.discardTaildropFile(file)
      }
    });
  }

  private discardTaildropFile(file: TaildropWaitingFileSummary): void {
    if (this.taildropSendActive() || this.taildropReceiveInProgress) {
      return;
    }
    if (this.taildropState !== 'ready') {
      this.queueTaildropPendingDelete(file);
      this.removeTaildropMediaPreview(file.name, file.size, true);
      this.removeTaildropCachedFile(file.name, file.size, true);
      this.taildropWaitingFiles = this.taildropWaitingFiles.filter(
        (waitingFile: TaildropWaitingFileSummary) =>
          waitingFile.name !== file.name || waitingFile.size !== file.size);
      this.persistTaildropInbox();
      this.notifyCacheContentsChanged();
      this.showToast($r('app.string.transfer_discard_completed'));
      return;
    }
    const requestId: number = Date.now();
    const request: TaildropReceiveRequest = {
      requestId: requestId, action: 'delete', name: file.name, inboxRoot: '', path: ''
    };
    this.taildropReceiveStrategy = 'discard';
    this.taildropReceiveDestinationUri = '';
    this.taildropReceiveExpectedSize = 0;
    this.taildropReceiveInProgress = true;
    this.taildropReceive = {
      requestId: requestId, action: 'delete', state: 'deleting', reason: '', name: file.name,
      size: file.size, path: ''
    };
    this.taildropReceiveStateStartedAtMs = Date.now();
    this.writePrivateTextFile(this.taildropReceiveResponsePath(), '');
    if (!this.dispatchTaildropReceiveRequest(request)) {
      this.failTaildropReceive('discard_failed');
      return;
    }
    this.recordDiagnosticEvent('taildrop_receive_discard_requested', 'transfer');
  }

  private confirmClearTaildropInboxCache(): void {
    if (this.taildropSendActive()) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: $r('app.string.transfer_clear_cache_confirm_title'),
      message: $r('app.string.transfer_clear_cache_confirm_message'),
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.cancel_action'),
        action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.transfer_clear_cache_action'),
        fontColor: $r('app.color.status_error'),
        action: () => this.clearTaildropInboxCache()
      }
    });
  }

  private clearTaildropInboxCache(): void {
    if (this.taildropSendActive() || this.taildropReceiveInProgress) {
      return;
    }
    if (this.taildropState !== 'ready') {
      this.queueTaildropPendingDeletes(this.taildropWaitingFiles);
      const succeeded: boolean = this.clearLocalTaildropInboxCache();
      if (succeeded) {
        this.clearTaildropInboxViewState();
      }
      this.notifyCacheContentsChanged();
      this.showToast(succeeded ? $r('app.string.transfer_cache_cleared') :
        $r('app.string.transfer_clear_cache_failed'));
      return;
    }
    this.requestTaildropInboxCacheClear();
  }

  private requestTaildropInboxCacheClear(): boolean {
    const requestId: number = Date.now();
    const request: TaildropReceiveRequest = {
      requestId: requestId, action: 'clear', name: '', inboxRoot: '', path: ''
    };
    this.taildropReceiveStrategy = 'clear';
    this.taildropReceiveInProgress = true;
    this.taildropReceive = {
      requestId: requestId, action: 'clear', state: 'requesting', reason: '', name: '', size: 0, path: ''
    };
    this.taildropReceiveStateStartedAtMs = Date.now();
    this.writePrivateTextFile(this.taildropReceiveResponsePath(), '');
    if (!this.dispatchTaildropReceiveRequest(request)) {
      this.recordDiagnosticEvent('taildrop_receive_failed', 'clear_failed');
      this.resetTaildropReceiveOperation();
      if (!this.cacheClearRequestedFromSettings) {
        this.showToast($r('app.string.transfer_clear_cache_failed'));
      }
      return false;
    }
    this.recordDiagnosticEvent('taildrop_receive_cache_clear_requested', 'transfer');
    return true;
  }

  private checkTaildropReceiveTimeout(): void {
    if (!this.taildropReceiveInProgress) {
      return;
    }
    if (this.taildropReceive.requestId <= 0) {
      this.recordDiagnosticEvent('taildrop_receive_invalid_busy_state', 'timeout');
      this.resetTaildropReceiveOperation();
      this.showToast($r('app.string.transfer_save_timeout'));
      return;
    }
    if (this.taildropReceive.state === 'awaiting_gallery_save' ||
      this.taildropReceive.state === 'awaiting_text_preview') {
      return;
    }
    if (this.taildropReceiveStateStartedAtMs <= 0) {
      this.taildropReceiveStateStartedAtMs = Date.now();
      return;
    }
    const timeoutMs: number = this.taildropReceive.state === 'requesting' ||
      this.taildropReceive.state === 'deleting' ?
      TAILDROP_RECEIVE_BACKEND_TIMEOUT_MS : TAILDROP_SAVE_TIMEOUT_MS;
    if (Date.now() - this.taildropReceiveStateStartedAtMs < timeoutMs) {
      return;
    }
    this.recordDiagnosticEvent('taildrop_receive_timeout', this.taildropReceive.state);
    if (this.taildropReceiveStrategy === 'media-prefetch') {
      this.failTaildropMediaPrefetch('timeout');
      return;
    }
    if (this.taildropReceive.state === 'saving_gallery' &&
      this.taildropReceiveMediaType !== undefined && this.taildropReceive.path.length > 0) {
      this.taildropMediaSaveInProgress = false;
      this.taildropPickerOpen = false;
      this.taildropReceiveResponseInFlight = false;
      this.taildropReceive = {
        requestId: this.taildropReceive.requestId, action: 'stage', state: 'awaiting_gallery_save',
        reason: '', name: this.taildropReceive.name, size: this.taildropReceive.size,
        path: this.taildropReceive.path
      };
      this.taildropReceiveStateStartedAtMs = 0;
      this.showToast($r('app.string.transfer_save_timeout'));
      return;
    }
    if (this.taildropReceive.state === 'deleting') {
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

  private processTaildropReceiveResponse(): void {
    if (!this.taildropReceiveInProgress || this.taildropReceiveResponseInFlight) {
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
      if (!this.taildropReceiveGateway.matchesResponse(this.taildropReceive, result)) {
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

  private async handleTaildropReceiveResult(result: TaildropReceiveResult): Promise<void> {
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
        this.recordDiagnosticEvent('taildrop_receive_delete_deferred', result.reason);
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
          // The staged source is the durable offline copy. A decoder failure
          // must not discard it just because the derived thumbnail is absent.
          this.recordDiagnosticEvent('taildrop_thumbnail_unavailable',
            mediaType === photoAccessHelper.PhotoType.IMAGE ? 'image' : 'video');
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
        this.taildropMediaPreviews = this.taildropMediaPreviews.concat([preview]);
        this.taildropAutoPrefetchKey = '';
        this.persistTaildropInbox();
        this.notifyCacheContentsChanged();
        this.recordDiagnosticEvent('taildrop_media_preview_ready', result.name);
        this.resetTaildropReceiveOperation();
        if (!this.resumePendingTaildropAction()) {
          this.prefetchTaildropInboxFiles(this.taildropWaitingFiles);
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
        this.taildropCachedFiles = this.taildropCachedFiles.concat([cached]);
        this.taildropAutoPrefetchKey = '';
        this.persistTaildropInbox();
        this.notifyCacheContentsChanged();
        this.recordDiagnosticEvent('taildrop_file_cache_ready', result.name);
        this.resetTaildropReceiveOperation();
        if (!this.resumePendingTaildropAction()) {
          this.prefetchTaildropInboxFiles(this.taildropWaitingFiles);
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
          `${this.taildropInboxRoot()}/${result.requestId}-active-thumb.jpg`);
        this.taildropReceive = {
          requestId: result.requestId, action: 'stage', state: 'awaiting_gallery_save', reason: '',
          name: result.name, size: result.size, path: mediaPath
        };
        this.taildropReceiveStateStartedAtMs = 0;
        this.recordDiagnosticEvent('taildrop_media_ready_for_save', 'transfer');
        this.showToast($r('app.string.transfer_media_ready_to_save'));
        return;
      }
      if (this.taildropReceiveStrategy === 'text-preview') {
        const content: string | undefined = this.readTaildropTextPreview(result);
        if (content === undefined) {
          this.failTaildropReceive('export_failed');
          return;
        }
        this.taildropReceive = {
          requestId: result.requestId, action: 'stage', state: 'awaiting_text_preview', reason: '',
          name: result.name, size: result.size, path: result.path
        };
        this.taildropReceivedText = content;
        this.taildropReceiveStateStartedAtMs = 0;
        this.taildropTextPreviewVisible = false;
        this.recordDiagnosticEvent('taildrop_text_preview_ready', 'transfer');
        return;
      }
      this.taildropReceive = {
        requestId: result.requestId, action: 'stage', state: 'exporting', reason: '', name: result.name,
        size: result.size, path: result.path
      };
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
      this.recordDiagnosticEvent('taildrop_receive_cache_cleared', 'transfer');
      this.resetTaildropReceiveOperation();
      if (requestedFromSettings) {
        this.finishSettingsCacheClear(true);
      } else {
        this.notifyCacheContentsChanged();
        this.showToast($r('app.string.transfer_cache_cleared'));
      }
      return;
    }
    this.failTaildropReceive('invalid_result');
  }

  private isCurrentTaildropReceive(requestId: number, action: string, state: string): boolean {
    return this.taildropReceiveInProgress && this.taildropReceive.requestId === requestId &&
      this.taildropReceive.action === action && this.taildropReceive.state === state;
  }

  private prepareTaildropMediaForSave(result: TaildropReceiveResult): string | undefined {
    return this.normalizeTaildropMediaPath(result.name, result.size, result.path);
  }

  private normalizeTaildropMediaPath(
    name: string,
    size: number,
    sourcePath: string
  ): string | undefined {
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

  private requestTaildropReceiveDelete(requestId: number, name: string, size: number): void {
    if (!this.taildropReceiveGateway.claimRemoteDelete(requestId, name)) {
      return;
    }
    const deleteRequest: TaildropReceiveRequest = this.taildropReceiveGateway.createDeleteRequest(requestId, name);
    this.taildropReceive = {
      requestId: requestId, action: 'delete', state: 'deleting', reason: '', name: name,
      size: size, path: ''
    };
    this.taildropReceiveStateStartedAtMs = Date.now();
    if (!this.dispatchTaildropReceiveRequest(deleteRequest)) {
      this.recordDiagnosticEvent('taildrop_receive_delete_deferred', 'request_unavailable');
      if (this.taildropReceiveStrategy === 'discard') {
        this.completeTaildropDiscard(true);
      } else {
        this.completeTaildropReceive(true);
      }
    }
  }

  private submitNextTaildropPendingDelete(): void {
    if (this.taildropState !== 'ready' || this.taildropInboxReason.length > 0 ||
      this.taildropPendingDeletes.length === 0 || this.taildropReceiveInProgress ||
      this.taildropReceiveResponseInFlight || this.taildropSendActive() ||
      Date.now() < this.taildropPendingDeleteRetryAtMs) {
      return;
    }
    const pending: TaildropWaitingFileSummary = this.taildropPendingDeletes[0];
    const requestId: number = Date.now();
    const request: TaildropReceiveRequest = this.taildropReceiveGateway.createDeleteRequest(requestId, pending.name);
    this.taildropReceiveStrategy = 'pending-delete';
    this.taildropReceiveExpectedSize = pending.size;
    this.taildropReceiveInProgress = true;
    this.taildropReceive = {
      requestId: requestId, action: 'delete', state: 'deleting', reason: '', name: pending.name,
      size: pending.size, path: ''
    };
    this.taildropReceiveStateStartedAtMs = Date.now();
    this.writePrivateTextFile(this.taildropReceiveResponsePath(), '');
    if (!this.dispatchTaildropReceiveRequest(request)) {
      this.deferTaildropPendingDelete('request_unavailable');
      return;
    }
    this.recordDiagnosticEvent('taildrop_pending_delete_requested', 'reconnect');
  }

  private completeTaildropPendingDelete(): void {
    const deletedName: string = this.taildropReceive.name;
    const deletedSize: number = this.taildropReceive.size;
    this.taildropPendingDeletes = this.taildropPendingDeletes.filter(
      (pending: TaildropWaitingFileSummary) =>
        pending.name !== deletedName || pending.size !== deletedSize);
    this.taildropPendingDeleteRetryAtMs = 0;
    this.persistTaildropInbox();
    this.recordDiagnosticEvent('taildrop_pending_delete_completed', 'reconnect');
    this.resetTaildropReceiveOperation();
    this.scheduleLifecycleTask(() => this.submitNextTaildropPendingDelete(), 0);
  }

  private deferTaildropPendingDelete(reason: string): void {
    this.recordDiagnosticEvent('taildrop_pending_delete_deferred', reason);
    this.taildropPendingDeleteRetryAtMs = Date.now() + TAILDROP_PENDING_DELETE_RETRY_MS;
    this.resetTaildropReceiveOperation();
  }

  private handlePreparedTaildropMediaSaveClick(file: TaildropWaitingFileSummary): void {
    const preview: TaildropMediaPreview | undefined = this.findTaildropMediaPreview(file);
    if (preview === undefined) {
      return;
    }
    this.interruptTaildropPrefetch();
    if (this.taildropReceiveInProgress) {
      if (this.taildropReceive.name === file.name &&
        this.taildropReceive.state === 'awaiting_gallery_save') {
        this.startTaildropMediaSave();
        return;
      }
      if (this.taildropReceive.state === 'awaiting_text_preview') {
        this.resetTaildropReceiveOperation();
        this.startPreparedTaildropMediaSave(file);
        return;
      }
      this.taildropPendingMediaSave = file;
      this.recordDiagnosticEvent('taildrop_media_save_queued', 'transfer');
      return;
    }
    this.startPreparedTaildropMediaSave(file);
  }

  private startPreparedTaildropFileSave(file: TaildropWaitingFileSummary): void {
    const cached: TaildropCachedFile | undefined = this.findTaildropCachedFile(file);
    if (cached === undefined) {
      if (this.taildropState !== 'ready') {
        this.showToast($r('app.string.transfer_connect_first_title'));
        this.releaseTaildropNotificationActionClaim();
      } else {
        this.startTaildropReceive(file);
      }
      return;
    }
    if (this.taildropSendActive() || this.taildropReceiveInProgress) {
      this.showToast($r('app.string.transfer_busy_message'));
      this.releaseTaildropNotificationActionClaim();
      return;
    }
    this.taildropReceiveStrategy = 'file';
    this.taildropReceiveExpectedSize = cached.size;
    this.taildropReceiveInProgress = true;
    this.taildropReceive = {
      requestId: cached.requestId,
      action: 'stage',
      state: 'selecting_destination',
      reason: '',
      name: cached.name,
      size: cached.size,
      path: cached.path
    };
    this.selectTaildropReceiveDestination(this.taildropReceive).then((destinationUri: string) => {
      if (!this.isCurrentTaildropReceive(cached.requestId, 'stage', 'selecting_destination')) {
        return;
      }
      if (destinationUri.length === 0) {
        this.resetTaildropReceiveOperation();
        return;
      }
      this.taildropReceiveDestinationUri = destinationUri;
      this.taildropReceive = {
        requestId: cached.requestId,
        action: 'stage',
        state: 'exporting',
        reason: '',
        name: cached.name,
        size: cached.size,
        path: cached.path
      };
      this.copyTaildropStagedFile(cached.path, destinationUri, cached.size).then((saved: boolean) => {
        if (!this.isCurrentTaildropReceive(cached.requestId, 'stage', 'exporting')) {
          return;
        }
        if (!saved) {
          this.failTaildropReceive('export_failed');
          return;
        }
        if (this.taildropState === 'ready') {
          this.requestTaildropReceiveDelete(cached.requestId, cached.name, cached.size);
        } else {
          this.completeTaildropReceive(true);
        }
      }).catch(() => this.failTaildropReceive('export_failed'));
    }).catch(() => this.failTaildropReceive('export_failed'));
  }

  private startPreparedTaildropMediaSave(file: TaildropWaitingFileSummary): void {
    const preview: TaildropMediaPreview | undefined = this.findTaildropMediaPreview(file);
    if (preview === undefined || this.taildropReceiveInProgress) {
      this.releaseTaildropNotificationActionClaim();
      return;
    }
    this.taildropReceiveStrategy = 'media';
    this.taildropReceiveDestinationUri = '';
    this.taildropReceiveExpectedSize = preview.size;
    this.taildropReceiveMediaType = preview.mediaType;
    this.taildropReceiveThumbnailPath = preview.thumbnailPath;
    this.taildropReceiveInProgress = true;
    this.taildropReceive = {
      requestId: preview.requestId,
      action: 'stage',
      state: 'awaiting_gallery_save',
      reason: '',
      name: preview.name,
      size: preview.size,
      path: preview.path
    };
    this.taildropReceiveStateStartedAtMs = 0;
    this.startTaildropMediaSave();
  }

  private startTaildropMediaSave(): void {
    if (this.taildropMediaSaveInProgress || this.taildropReceive.state !== 'awaiting_gallery_save') {
      return;
    }
    this.taildropMediaSaveInProgress = true;
    this.saveTaildropMediaToGallery().then((saved: boolean) => {
      if (!saved) {
        this.restoreTaildropMediaSaveAfterFailure(false);
      }
    }).catch((error: BusinessError) => {
      const mediaKind: string = this.taildropReceiveMediaType === photoAccessHelper.PhotoType.VIDEO ?
        'video' : 'image';
      const extension: string = this.taildropFileExtension(this.taildropReceive.name);
      this.recordDiagnosticEvent('taildrop_media_save_failed',
        extension.length > 0 ? `${mediaKind}_${extension}` : mediaKind, error.code ?? -1);
      this.restoreTaildropMediaSaveAfterFailure(true);
    }).finally(() => {
      this.taildropMediaSaveInProgress = false;
    });
  }

  private restoreTaildropMediaSaveAfterFailure(showFailure: boolean): void {
    if (!this.taildropMediaSaveInProgress || this.taildropReceive.state !== 'saving_gallery' ||
      this.taildropReceive.path.length === 0) {
      return;
    }
    this.taildropReceive = {
      requestId: this.taildropReceive.requestId,
      action: 'stage',
      state: 'awaiting_gallery_save',
      reason: '',
      name: this.taildropReceive.name,
      size: this.taildropReceive.size,
      path: this.taildropReceive.path
    };
    if (showFailure) {
      this.showToast($r('app.string.transfer_media_save_failed'));
    }
  }

  private validTaildropMediaTimestamp(timestampMs: number): boolean {
    return Number.isFinite(timestampMs) && timestampMs >= TAILDROP_MEDIA_MIN_TIMESTAMP_MS &&
      timestampMs <= Date.now() + TAILDROP_MEDIA_MAX_FUTURE_MS;
  }

  private taildropLocalDateTimestamp(
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

  private parseTaildropMediaDateTime(value: string): number | undefined {
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

  private taildropMediaTimestampFromName(name: string): number | undefined {
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

  private async restoreTaildropVideoMtime(
    name: string,
    path: string,
    size: number
  ): Promise<number | undefined> {
    let sourceFile: fileIo.File | undefined = undefined;
    let extractor: media.AVMetadataExtractor | undefined = undefined;
    try {
      sourceFile = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      extractor = await media.createAVMetadataExtractor();
      extractor.fdSrc = { fd: sourceFile.fd, offset: 0, length: size };
      const metadata: media.AVMetadata = await extractor.fetchMetadata();
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
      return fileIo.statSync(path).mtime;
    } catch (_error) {
      return undefined;
    } finally {
      if (extractor !== undefined) {
        try {
          await extractor.release();
        } catch (_error) {
          // Metadata extraction failure must not prevent saving the original bytes.
        }
      }
      if (sourceFile !== undefined) {
        try {
          fileIo.closeSync(sourceFile);
        } catch (_error) {
          // The descriptor may already be closed after a media service failure.
        }
      }
    }
  }

  private async saveTaildropMediaToGallery(): Promise<boolean> {
    const mediaType: photoAccessHelper.PhotoType | undefined = this.taildropReceiveMediaType;
    const staged: TaildropReceiveResult = this.taildropReceive;
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
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.taildropReceive = {
      requestId: staged.requestId, action: 'stage', state: 'saving_gallery', reason: '',
      name: staged.name, size: staged.size, path: staged.path
    };
    this.taildropReceiveStateStartedAtMs = Date.now();
    const phAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
    let restoredMtimeMs: number | undefined = undefined;
    if (mediaType === photoAccessHelper.PhotoType.VIDEO) {
      restoredMtimeMs = await this.restoreTaildropVideoMtime(staged.name, staged.path, staged.size);
    }
    const config: photoAccessHelper.PhotoCreationConfig = {
      title: this.taildropGalleryAssetTitle(staged.name),
      fileNameExtension: extension,
      photoType: mediaType
    };
    // The creation dialog both asks for permission and saves the source URI.
    // Keep this as the only media-library flow so a media tap cannot trigger
    // a second permission dialog or save the same asset twice.
    let destinationUri: string = '';
    try {
      const sourceUri: string = fileUri.getUriFromPath(staged.path);
      const destinationUris: string[] = await phAccessHelper.showAssetsCreationDialog(
        [sourceUri], [config]);
      destinationUri = destinationUris.length > 0 ? destinationUris[0] : '';
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      this.recordDiagnosticEvent('taildrop_media_asset_create_failed', 'creation_dialog',
        businessError.code ?? -1);
    }
    if (destinationUri.length === 0) {
      return false;
    }
    this.taildropReceiveDestinationUri = destinationUri;
    if (restoredMtimeMs !== undefined) {
      this.recordDiagnosticEvent('taildrop_media_mtime_restored', 'video');
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
    this.recordDiagnosticEvent('taildrop_media_saved_to_gallery', 'transfer');
    if (this.taildropState === 'ready') {
      this.requestTaildropReceiveDelete(staged.requestId, staged.name, staged.size);
    } else {
      this.completeTaildropReceive(true);
    }
    return true;
  }

  private clearLocalTaildropInboxCache(): boolean {
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
      this.notifyCacheContentsChanged();
      return cleared;
    } catch (_error) {
      return false;
    }
  }

  private async handleTaildropStagedFile(result: TaildropReceiveResult): Promise<boolean> {
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

  private async exportTaildropImageToGallery(result: TaildropReceiveResult): Promise<boolean> {
    const extension: string = this.taildropFileExtension(result.name);
    const mediaType: photoAccessHelper.PhotoType | undefined = this.resolveTaildropMediaType(result.name);
    if (mediaType === undefined) {
      return false;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const helper = photoAccessHelper.getPhotoAccessHelper(context);
      const configs: photoAccessHelper.PhotoCreationConfig[] = [{
        title: this.taildropGalleryAssetTitle(result.name),
        fileNameExtension: extension,
        photoType: mediaType
      }];
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

  private async copyTaildropTextToClipboard(result: TaildropReceiveResult): Promise<boolean> {
    if (result.size > TAILDROP_TEXT_CLIPBOARD_MAX_BYTES) {
      return false;
    }
    try {
      const content: string = fileIo.readTextSync(result.path);
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, content);
      await pasteboard.getSystemPasteboard().setData(data);
      return true;
    } catch (_error) {
      return false;
    }
  }

  private openTaildropExportDestination(destinationUri: string): fileIo.File {
    try {
      // Media-library assets returned by PhotoAccessHelper already exist. Do
      // not ask the provider to create them again; opening for write/truncate
      // preserves the URI grant returned by the save operation.
      return fileIo.openSync(destinationUri, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    } catch (_error) {
      // DocumentViewPicker providers may require the CREATE-capable mode.
      return fileIo.openSync(destinationUri,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    }
  }

  private async copyTaildropStagedFile(sourcePath: string, destinationUri: string,
    expectedSize: number): Promise<boolean> {
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

  private async exportTaildropReceivedFile(result: TaildropReceiveResult): Promise<boolean> {
    return await this.copyTaildropStagedFile(result.path, this.taildropReceiveDestinationUri, result.size);
  }

  private addTaildropReceiveRecord(state: string, reason: string): void {
    const record: TaildropTransferRecord = {
      requestId: this.taildropReceive.requestId,
      direction: 'receive',
      state: state,
      reason: reason,
      targetKey: '',
      targetName: '',
      fileName: this.taildropReceive.name,
      fileCount: 1,
      totalBytes: this.taildropReceive.size > 0 ? this.taildropReceive.size : this.taildropReceiveExpectedSize,
      previewPath: this.taildropReceivePreviewPath,
      completedAtMs: Date.now()
    };
    this.taildropHistory = [record].concat(this.taildropHistory).slice(0, TAILDROP_HISTORY_LIMIT);
    this.persistTaildropHistory();
  }

  private completeTaildropReceive(queueBackendDelete: boolean = false): void {
    const receivedName: string = this.taildropReceive.name;
    const receivedSize: number = this.taildropReceive.size;
    const receiveStrategy: string = this.taildropReceiveStrategy;
    if (queueBackendDelete) {
      const receivedFile: TaildropWaitingFileSummary | undefined = this.taildropWaitingFiles.find(
        (file: TaildropWaitingFileSummary) => file.name === receivedName && file.size === receivedSize);
      this.queueTaildropPendingDelete(receivedFile === undefined ? {
        name: receivedName, size: receivedSize, receivedAtMs: Date.now()
      } : receivedFile);
    }
    this.addTaildropReceiveRecord('completed', '');
    this.removeTaildropMediaPreview(receivedName, receivedSize, true);
    this.removeTaildropCachedFile(receivedName, receivedSize, true);
    this.taildropWaitingFiles = this.taildropWaitingFiles.filter(
      (file: TaildropWaitingFileSummary) => file.name !== receivedName || file.size !== receivedSize);
    this.persistTaildropInbox();
    this.recordDiagnosticEvent('taildrop_receive_completed', 'transfer');
    if (receiveStrategy === 'image' ||
      (receiveStrategy === 'media' && this.taildropReceiveMediaType === photoAccessHelper.PhotoType.IMAGE)) {
      this.showToast($r('app.string.transfer_image_saved'));
    } else if (receiveStrategy === 'text' || receiveStrategy === 'text-preview') {
      this.showToast($r('app.string.transfer_text_copied'));
    } else {
      this.showToast($r('app.string.transfer_receive_completed'));
    }
    this.resetTaildropReceiveOperation();
    this.resumePendingTaildropAction();
    this.notifyCacheContentsChanged();
  }

  private completeTaildropDiscard(queueBackendDelete: boolean = false): void {
    const discardedName: string = this.taildropReceive.name;
    const discardedSize: number = this.taildropReceive.size;
    if (queueBackendDelete) {
      const discardedFile: TaildropWaitingFileSummary | undefined = this.taildropWaitingFiles.find(
        (file: TaildropWaitingFileSummary) => file.name === discardedName && file.size === discardedSize);
      this.queueTaildropPendingDelete(discardedFile === undefined ? {
        name: discardedName, size: discardedSize, receivedAtMs: Date.now()
      } : discardedFile);
    }
    this.removeTaildropMediaPreview(discardedName, discardedSize, true);
    this.removeTaildropCachedFile(discardedName, discardedSize, true);
    this.taildropWaitingFiles = this.taildropWaitingFiles.filter(
      (file: TaildropWaitingFileSummary) => file.name !== discardedName || file.size !== discardedSize);
    this.persistTaildropInbox();
    this.recordDiagnosticEvent('taildrop_receive_discarded', 'transfer');
    this.showToast($r('app.string.transfer_discard_completed'));
    this.resetTaildropReceiveOperation();
    this.resumePendingTaildropAction();
    this.notifyCacheContentsChanged();
  }

  private failTaildropReceive(reason: string): void {
    if (this.taildropReceiveStrategy === 'pending-delete') {
      this.deferTaildropPendingDelete(reason);
      return;
    }
    if (this.taildropReceive.action === 'delete') {
      this.recordDiagnosticEvent('taildrop_receive_delete_deferred', reason);
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
      this.cacheClearRequestedFromSettings && this.taildropReceive.action === 'clear';
    if (this.taildropReceive.requestId > 0 && this.taildropReceive.action !== 'clear') {
      this.addTaildropReceiveRecord('failed', reason);
    }
    this.recordDiagnosticEvent('taildrop_receive_failed', reason);
    if (!settingsCacheClearFailed) {
      this.showToast(this.taildropReceiveFailureMessage(reason));
    }
    this.resetTaildropReceiveOperation();
    this.resumePendingTaildropAction();
    if (settingsCacheClearFailed) {
      this.finishSettingsCacheClear(false);
    }
  }

  private failTaildropMediaPrefetch(reason: string): void {
    const key: string = this.taildropAutoPrefetchKey;
    if (key.length > 0 && !this.taildropAutoPrefetchFailedKeys.includes(key)) {
      this.taildropAutoPrefetchFailedKeys = this.taildropAutoPrefetchFailedKeys.concat([key]);
    }
    this.recordDiagnosticEvent('taildrop_media_preview_failed', reason);
    this.taildropAutoPrefetchKey = '';
    this.resetTaildropReceiveOperation();
    this.resumePendingTaildropAction();
  }

  private resetTaildropReceiveOperation(): void {
    this.releaseTaildropNotificationActionClaim();
    const receivePath: string = this.taildropReceive.path;
    const receiveThumbnailPath: string = this.taildropReceiveThumbnailPath;
    const pathIsCachedPreview: boolean = this.taildropMediaPreviews.some(
      (preview: TaildropMediaPreview) => preview.path === receivePath) ||
      this.taildropCachedFiles.some((cached: TaildropCachedFile) => cached.path === receivePath);
    const thumbnailIsCachedPreview: boolean = this.taildropMediaPreviews.some(
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
          this.notifyCacheContentsChanged();
        }
      } catch (_error) {
        // A later inbox-cache cleanup removes an inaccessible temporary thumbnail.
      }
    }
    this.taildropReceiveInProgress = false;
    this.taildropReceiveResponseInFlight = false;
    this.taildropMediaSaveInProgress = false;
    this.taildropPickerOpen = false;
    this.taildropReceiveStateStartedAtMs = 0;
    this.taildropReceiveDestinationUri = '';
    this.taildropReceiveExpectedSize = 0;
    this.taildropReceiveMediaType = undefined;
    this.taildropReceivePreviewPath = '';
    this.taildropReceiveThumbnailPath = '';
    this.taildropReceiveStrategy = 'none';
    this.taildropReceive = emptyTaildropReceive();
    this.taildropReceivedText = '';
    this.taildropTextPreviewVisible = false;
  }

  private taildropReceiveFailureMessage(reason: string): ResourceStr {
    if (this.taildropReceive.action === 'clear' || reason === 'clear_failed') {
      return $r('app.string.transfer_clear_cache_failed');
    }
    if (reason === 'file_unavailable') {
      return $r('app.string.transfer_receive_unavailable');
    }
    if (reason === 'no_space') {
      return $r('app.string.transfer_receive_no_space');
    }
    if (reason === 'timeout') {
      return $r('app.string.transfer_save_timeout');
    }
    if (reason === 'delete_failed') {
      return this.taildropReceiveStrategy === 'discard' ?
        $r('app.string.transfer_discard_failed') : $r('app.string.transfer_receive_delete_failed');
    }
    if (reason === 'discard_failed') {
      return $r('app.string.transfer_discard_failed');
    }
    if (reason === 'export_failed' && this.taildropReceiveStrategy === 'image') {
      return $r('app.string.transfer_gallery_failed');
    }
    if (reason === 'export_failed' && this.taildropReceiveStrategy === 'text') {
      return $r('app.string.transfer_text_copy_failed');
    }
    return $r('app.string.transfer_receive_failed');
  }

  private secondaryBackground(): ResourceColor {
    return $r('sys.color.comp_background_tertiary');
  }

  private accountInitial(): string {
    const source: string = this.accountSummary.displayName.length > 0 ?
      this.accountSummary.displayName : this.accountSummary.loginName;
    return source.length > 0 ? source.substring(0, 1).toUpperCase() : 'T';
  }

  @Builder
  private SectionHeader(title: ResourceStr, description?: ResourceStr) {
    Column({ space: 2 }) {
      Text(title)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
      if (description !== undefined) {
        Text(description)
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .lineHeight(18)
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private SettingsGroupHeader(title: ResourceStr) {
    Text(title)
      .fontSize(15)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.font_primary'))
      .width('100%')
      .padding({ top: 8, bottom: 2 })
  }

  @Builder
  private ButtonContent(label: ResourceStr, primary: boolean, loading: boolean,
    destructive: boolean = false) {
    Row({ space: 8 }) {
      if (loading) {
        LoadingProgress()
          .width(20)
          .height(20)
          .color(primary ? $r('sys.color.font_on_primary') : $r('sys.color.icon_primary'))
      }
      Text(label)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(primary ? $r('sys.color.font_on_primary') :
          (destructive ? $r('app.color.status_error') : $r('sys.color.font_primary')))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(20)
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
  }

  @Builder
  private StandardActionButton(label: ResourceStr, nodeId: string, primary: boolean,
    enabled: boolean, action: () => void, loading: boolean = false,
    destructive: boolean = false) {
    Button({
      type: ButtonType.ROUNDED_RECTANGLE,
      stateEffect: true,
      buttonStyle: primary ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL,
      controlSize: ControlSize.NORMAL
    }) {
      this.ButtonContent(label, primary, loading, destructive)
    }
      .id(nodeId)
      .width('100%')
      .height(44)
      .opacity(enabled ? 1 : 0.4)
      .enabled(enabled)
      .onClick(action)
  }

  private connectionActionNodeId(): string {
    if (!this.controlServerConfirmed) {
      return 'control-server-setup';
    }
    if (this.isConnected()) {
      return 'vpn-stop';
    }
    if (this.isBackendLoading()) {
      return 'backend-starting';
    }
    if (this.needsLogin()) {
      return 'account-login';
    }
    return 'vpn-connect';
  }

  private connectionActionLoading(): boolean {
    return this.isBackendLoading() || this.isConnecting() || this.loginInProgress ||
      this.disconnectInProgress;
  }

  private connectionActionEnabled(): boolean {
    return !this.connectionActionLoading() && !this.deviceNeedsApproval();
  }

  private connectionActionBackground(): ResourceColor {
    return this.isConnected() ? '#415FEB' : this.secondaryBackground();
  }

  private connectionActionForeground(): ResourceColor {
    if (this.isConnected()) {
      return $r('sys.color.font_on_primary');
    }
    if (this.connectionActionLoading()) {
      return $r('app.color.status_warning');
    }
    return $r('app.color.status_neutral');
  }

  private runConnectionAction(): void {
    if (!this.controlServerConfirmed) {
      this.openControlServerSettings();
    } else if (this.isConnected()) {
      this.stopVpnProbe();
    } else if (this.needsLogin()) {
      this.openSecureLogin();
    } else {
      this.beginVpnConnection();
    }
  }

  @Builder
  private ConnectionCircleButton() {
    Button({
      type: ButtonType.Circle,
      stateEffect: true,
      buttonStyle: ButtonStyleMode.TEXTUAL,
      controlSize: ControlSize.NORMAL
    }) {
      if (this.connectionActionLoading()) {
        LoadingProgress()
          .width(19)
          .height(19)
          .color(this.connectionActionForeground())
      } else {
        Image($r('app.media.connection_filled'))
          .width(19)
          .height(19)
          .fillColor(this.connectionActionForeground())
      }
    }
    .id(this.connectionActionNodeId())
    .width(42)
    .height(42)
    .backgroundColor(this.connectionActionBackground())
    .border({ width: 1, color: $r('sys.color.comp_divider') })
    .enabled(this.connectionActionEnabled())
    .opacity(this.connectionActionEnabled() ? 1 : 0.65)
    .accessibilityText(this.isConnected() ?
      $r('app.string.action_disconnect') : $r('app.string.action_connect'))
    .onClick(() => this.runConnectionAction())
  }

  @Builder
  private TrafficChart() {
    Stack({ alignContent: Alignment.Center }) {
      Divider()
        .width('100%')
        .color($r('sys.color.comp_divider'))
      Polyline({ width: this.trafficChartWidth(), height: 68 })
        .points(this.trafficChartPoints(true))
        .fill(Color.Transparent)
        .stroke($r('sys.color.icon_emphasize'))
        .strokeWidth(2)
        .strokeLineCap(LineCapStyle.Round)
        .strokeLineJoin(LineJoinStyle.Round)
      Polyline({ width: this.trafficChartWidth(), height: 68 })
        .points(this.trafficChartPoints(false))
        .fill(Color.Transparent)
        .stroke($r('app.color.traffic_upload'))
        .strokeWidth(2)
        .strokeLineCap(LineCapStyle.Round)
        .strokeLineJoin(LineJoinStyle.Round)
    }
    .id('traffic-chart')
    .width('100%')
    .height(68)
    .clip(true)
    .backgroundColor(this.secondaryBackground())
    .borderRadius(12)
  }

  @Builder
  private TrafficChartBackdrop() {
    Stack({ alignContent: Alignment.Center }) {
      Polyline({ width: this.trafficChartWidth(), height: 42 })
        .points(this.trafficChartPoints(true, 42))
        .fill(Color.Transparent)
        .stroke($r('sys.color.icon_emphasize'))
        .strokeWidth(2)
        .strokeLineCap(LineCapStyle.Round)
        .strokeLineJoin(LineJoinStyle.Round)
        .opacity(0.20)
      Polyline({ width: this.trafficChartWidth(), height: 42 })
        .points(this.trafficChartPoints(false, 42))
        .fill(Color.Transparent)
        .stroke($r('app.color.traffic_upload'))
        .strokeWidth(2)
        .strokeLineCap(LineCapStyle.Round)
        .strokeLineJoin(LineJoinStyle.Round)
        .opacity(0.18)
    }
    .width('100%')
    .height(42)
    .clip(true)
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  private TrafficSummary() {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text($r('app.string.traffic_download'))
            .fontSize(11)
            .fontColor($r('sys.color.font_secondary'))
          Text(`↓ ${this.formatTrafficBytes(this.trafficDownloadBytes)}`)
            .id('traffic-download-total')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
          Text(this.formatTrafficBytes(this.trafficDownloadRate, true))
            .fontSize(11)
            .fontColor($r('sys.color.icon_emphasize'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Column({ space: 2 }) {
          Text($r('app.string.traffic_upload'))
            .fontSize(11)
            .fontColor($r('sys.color.font_secondary'))
          Text(`↑ ${this.formatTrafficBytes(this.trafficUploadBytes)}`)
            .id('traffic-upload-total')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
          Text(this.formatTrafficBytes(this.trafficUploadRate, true))
            .fontSize(11)
            .fontColor($r('app.color.traffic_upload'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      this.TrafficChart()
    }
    .width('100%')
  }

  @Builder
  private AnimatedTrafficSummary() {
    if (this.isConnected()) {
      Column() {
        this.TrafficSummary()
      }
      .width('100%')
      .transition(
        TransitionEffect.asymmetric(
          TransitionEffect.OPACITY.animation({ duration: MotionTokens.EXPAND, curve: Curve.EaseOut })
            .combine(TransitionEffect.translate({ y: -10 })),
          TransitionEffect.OPACITY.animation({ duration: MotionTokens.FAST, curve: Curve.EaseIn })
            .combine(TransitionEffect.translate({ y: -6 }))
        )
      )
    }
  }

  @Builder
  private ConnectionPanel() {
    Column() {
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text(this.connectionTitle())
            .id('smoke-title')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .width('100%')
          Text(this.connectionDescription())
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .lineHeight(17)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        this.ConnectionCircleButton()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      this.AnimatedTrafficSummary()
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
  }

  @Builder
  private InactiveHomeHeader() {
    this.CompactHomeHeader(false)
  }

  @Builder
  private LegacyConnectedHeader() {
    LegacyConnectedHomeHeader({
      connectionPanel: (): void => { this.ConnectionPanel(); },
      exitNodePanel: (): void => { this.ExitNodePanel(); }
    })
  }

  @Builder
  private CompactConnectedHeader() {
    this.CompactHomeHeader(true)
  }

  private compactConnectionDescription(connected: boolean): ResourceStr {
    if (!connected) {
      return this.connectionDescription();
    }
    const tailnetName: string = this.accountSummary.tailnetName;
    const tailscaleAddress: string = this.primaryTailscaleAddress(this.accountSummary.addresses);
    if (tailnetName.length === 0) {
      return tailscaleAddress;
    }
    return tailscaleAddress.length === 0 ? tailnetName : `${tailnetName} \u00B7 ${tailscaleAddress}`;
  }

  private compactExitNodeLabel(connected: boolean): ResourceStr {
    const selectedName: string = this.selectedExitNodeName();
    if (!connected) {
      return this.selectedExitNodeLabel();
    }
    return selectedName.length > 0 ? selectedName :
      '\u672A\u4F7F\u7528 \u00B7 \u65AD\u5F00\u540E\u53EF\u66F4\u6539';
  }

  @Builder
  private CompactHomeHeader(connected: boolean) {
    CompactConnectedHomeHeader({
      statusTitle: this.connectionTitle(),
      statusDescription: this.compactConnectionDescription(connected),
      statusColor: this.connectionColor(),
      downloadRate: this.formatTrafficBytes(this.trafficDownloadRate, true),
      uploadRate: this.formatTrafficBytes(this.trafficUploadRate, true),
      showTraffic: connected,
      exitNodeLabel: this.compactExitNodeLabel(connected),
      exitNodeEditable: !connected,
      exitNodeEnabled: this.isAuthenticated() && this.exitNodes.length > 0 &&
        !this.isConnected() && !this.isConnecting() && !this.connectInProgress && !this.exitNodeUpdateInProgress,
      exitNodeOptions: this.exitNodeSelectOptions(),
      exitNodeSelectedIndex: this.selectedExitNodeIndex(),
      onDetails: (): void => { this.openConnectionDetails(); },
      onExitNodeInfo: (): void => { this.showExitNodeConnectionHint(); },
      onExitNodeSelect: (index: number): void => { this.onExitNodeSelect(index); },
      connectionButton: (): void => { this.ConnectionCircleButton(); },
      trafficBackdrop: (): void => { this.TrafficChartBackdrop(); }
    })
  }

  @Builder
  private HomeConnectionHeader() {
    HomeConnectionSection({
      connected: this.connectedHomeLayoutActive(),
      layoutMode: this.connectedHomeLayoutMode,
      inactiveHeader: (): void => { this.InactiveHomeHeader(); },
      legacyHeader: (): void => { this.LegacyConnectedHeader(); },
      compactHeader: (): void => { this.CompactConnectedHeader(); }
    })
  }

  @Builder
  private ConnectionDetailsContent() {
    ConnectionDetailsSheet({
      tailnetName: this.accountSummary.tailnetName,
      deviceName: this.localDeviceName(),
      tailscaleAddress: this.primaryTailscaleAddress(this.accountSummary.addresses),
      duration: this.connectedDurationLabel(),
      downloadRate: this.formatTrafficBytes(this.trafficDownloadRate, true),
      uploadRate: this.formatTrafficBytes(this.trafficUploadRate, true),
      downloadTotal: this.formatTrafficBytes(this.trafficDownloadBytes),
      uploadTotal: this.formatTrafficBytes(this.trafficUploadBytes),
      exitNodeName: this.selectedExitNodeName()
    })
  }

  @Builder
  private NetworkSettingsPanel() {
    Column({ space: 0 }) {
      Row() {
        Column({ space: 2 }) {
          Text($r('app.string.setting_subnet_routes'))
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
          Text($r('app.string.setting_subnet_routes_description'))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.networkSettings.routeAll })
          .id('route-all-toggle')
          .enabled(!this.isConnected() && this.isAuthenticated() && !this.routeAllUpdateInProgress)
          .opacity(!this.isConnected() && this.isAuthenticated() && !this.routeAllUpdateInProgress ? 1 : 0.4)
          .onChange((enabled: boolean) => this.queueNetworkSettingUpdate('routeAll', enabled))
      }
      .width('100%')
      .constraintSize({ minHeight: 56 })
      .padding({ top: 6, bottom: 6 })

      Divider().color($r('sys.color.comp_divider'))

      Row() {
        Column({ space: 2 }) {
          Text($r('app.string.setting_exit_node_lan'))
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
          Text($r('app.string.setting_exit_node_lan_description'))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(2)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.networkSettings.exitNodeAllowLANAccess })
          .id('exit-node-lan-toggle')
          .enabled(!this.isConnected() && this.isAuthenticated() && !this.exitNodeLanUpdateInProgress)
          .opacity(!this.isConnected() && this.isAuthenticated() && !this.exitNodeLanUpdateInProgress ? 1 : 0.4)
          .onChange((enabled: boolean) =>
            this.queueNetworkSettingUpdate('exitNodeAllowLANAccess', enabled))
      }
      .width('100%')
      .constraintSize({ minHeight: 62 })
      .padding({ top: 6, bottom: 6 })

      if (this.networkSettingStatus.startsWith('FAILED')) {
        Text($r('app.string.network_setting_failed'))
          .id('network-setting-status')
          .fontSize(12)
          .fontColor($r('app.color.status_error'))
          .width('100%')
          .padding({ top: 8 })
      }
    }
    .id('network-settings-panel')
    .width('100%')
    .padding(14)
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
    .animation({ duration: 260, curve: Curve.EaseInOut })
  }

  private selectableExitNodes(): ExitNodeChoice[] {
    return this.exitNodes.filter((choice: ExitNodeChoice) => choice.online || choice.selected);
  }

  private exitNodeSelectOptions(): SelectOption[] {
    const options: SelectOption[] = [{ value: $r('app.string.exit_node_none') }];
    this.selectableExitNodes().forEach((choice: ExitNodeChoice) => {
      options.push({ value: choice.name });
    });
    return options;
  }

  private selectedExitNodeIndex(): number {
    const choices: ExitNodeChoice[] = this.selectableExitNodes();
    const selectedIndex: number = choices.findIndex((choice: ExitNodeChoice) => choice.selected);
    return selectedIndex < 0 ? 0 : selectedIndex + 1;
  }

  private selectedExitNodeLabel(): ResourceStr {
    if (!this.isAuthenticated()) {
      return $r('app.string.setting_unavailable');
    }
    if (this.exitNodes.length === 0) {
      return $r('app.string.exit_node_empty');
    }
    const selected: ExitNodeChoice | undefined = this.exitNodes.find(
      (choice: ExitNodeChoice) => choice.selected);
    return selected === undefined ? $r('app.string.exit_node_none') : selected.name;
  }

  private onExitNodeSelect(index: number): void {
    if (index === 0) {
      this.queueExitNodeUpdate('');
      return;
    }
    const choices: ExitNodeChoice[] = this.selectableExitNodes();
    if (index - 1 < choices.length) {
      this.queueExitNodeUpdate(choices[index - 1].id);
    }
  }

  @Builder
  private ExitNodePanel() {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text($r('app.string.exit_node_title'))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Text(this.isConnected() ? $r('app.string.exit_node_disconnect_first') :
          $r('app.string.exit_node_description'))
          .fontSize(11)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Select(this.exitNodeSelectOptions())
        .id('legacy-exit-node-status')
        .selected(this.selectedExitNodeIndex())
        .value(this.selectedExitNodeLabel())
        .controlSize(ControlSize.NORMAL)
        .font({ size: 12 })
        .optionFont({ size: 12 })
        .selectedOptionFont({ size: 12 })
        .menuBackgroundColor(this.glowSurface())
        .menuBackgroundBlurStyle(BlurStyle.COMPONENT_REGULAR)
        .constraintSize({ minWidth: 104, maxWidth: this.layoutWidth >= 600 ? 240 : 144 })
        .enabled(this.isAuthenticated() && this.exitNodes.length > 0 &&
          !this.isConnected() && !this.isConnecting() && !this.connectInProgress && !this.exitNodeUpdateInProgress)
        .opacity(this.isAuthenticated() && this.exitNodes.length > 0 &&
          !this.isConnected() && !this.isConnecting() && !this.connectInProgress && !this.exitNodeUpdateInProgress ? 1 : 0.55)
        .onSelect((index: number) => this.onExitNodeSelect(index))
    }
    .width('100%')
    .constraintSize({ minHeight: 68 })
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .backgroundColor(this.groupBackground())
    .borderRadius(14)
    .animation({ duration: 260, curve: Curve.EaseInOut })
  }

  @Builder
  private DevicesLoadingPanel() {
    Column({ space: 12 }) {
      this.SectionHeader($r('app.string.devices_title'), $r('app.string.action_starting'))
      Column({ space: 10 }) {
        LoadingProgress()
          .id('devices-loading')
          .width(28)
          .height(28)
          .color($r('sys.color.icon_emphasize'))
        Text($r('app.string.action_starting'))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .width('100%')
      .constraintSize({ minHeight: 112 })
    }
    .width('100%')
    .height('100%')
    .constraintSize({ minHeight: 200 })
    .padding(16)
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
  }

  @Builder
  private DevicesSignedOutPanel() {
    Column({ space: 12 }) {
      this.SectionHeader($r('app.string.devices_title'), '')
      Column() {
        Text($r('app.string.account_profile_unavailable'))
          .fontSize(14)
          .fontColor($r('sys.color.font_secondary'))
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .width('100%')
      .constraintSize({ minHeight: 112 })
    }
    .width('100%')
    .height('100%')
    .constraintSize({ minHeight: 200 })
    .padding(16)
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
  }

  @Builder
  private DeviceStatusNotice(label: ResourceStr, error: boolean) {
    Text(label)
      .fontSize(10)
      .fontWeight(FontWeight.Medium)
      .fontColor(error ? $r('app.color.status_error') : $r('app.color.status_warning'))
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .padding({ left: 7, right: 7, top: 2, bottom: 2 })
      .borderRadius(9)
      .backgroundColor(error ? '#14B42318' : '#14B54708')
  }

  @Builder
  private LocalDeviceRow() {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.Center }) {
        Image(this.localDeviceIcon())
          .width(19)
          .height(19)
          .objectFit(ImageFit.Contain)
          .fillColor($r('sys.color.icon_primary'))
        Row()
          .width(8)
          .height(8)
          .borderRadius(4)
          .border({ width: 2, color: this.groupBackground() })
          .backgroundColor(this.connectionColor())
          .position({ x: 21, y: 21 })
      }
      .width(36)
      .height(36)
      .borderRadius(11)
      .backgroundColor(this.secondaryBackground())

      Column({ space: 1 }) {
        Row({ space: 6 }) {
          Text(this.localDeviceName())
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .wordBreak(WordBreak.BREAK_ALL)
            .layoutWeight(1)
          Text($r('app.string.local_device_badge'))
            .fontSize(9)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_secondary'))
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .borderRadius(7)
            .backgroundColor(this.secondaryBackground())
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        Row({ space: 5 }) {
          Text(this.connectionTitle())
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
          Text('· HarmonyOS ' + this.harmonyOSVersion())
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
        }
        .width('100%')
        if (this.accountSummary.addresses.length > 0) {
          Text(this.primaryTailscaleAddress(this.accountSummary.addresses))
            .fontSize(11)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .width('100%')
        }
        if (this.deviceNeedsApproval() || this.accountSummary.keyExpired ||
          this.keyExpiresSoon(this.accountSummary.keyExpiryUnixMs)) {
          Row({ space: 5 }) {
            if (this.deviceNeedsApproval()) {
              this.DeviceStatusNotice($r('app.string.device_approval_required'), false)
            }
            if (this.accountSummary.keyExpired ||
              this.keyExpiresSoon(this.accountSummary.keyExpiryUnixMs)) {
              this.DeviceStatusNotice(this.keyExpiryLabel(this.accountSummary.keyExpired,
                this.accountSummary.keyExpiryUnixMs), this.accountSummary.keyExpired)
            }
          }
          .width('100%')
          .margin({ top: 3 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .constraintSize({ minHeight: 52 })
    .padding({ top: 6, right: 12, bottom: 6 })
  }

  @Builder
  private PeerActionSegment(label: ResourceStr, nodeId: string, enabled: boolean,
    loading: boolean, action: () => void) {
    Button({
      type: ButtonType.Normal,
      stateEffect: true,
      buttonStyle: ButtonStyleMode.TEXTUAL,
      controlSize: ControlSize.SMALL
    }) {
      Row({ space: 4 }) {
        if (loading) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color($r('app.color.status_warning'))
        }
        Text(label)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')
    }
    .id(nodeId)
    .layoutWeight(1)
    .height(36)
    .padding({ left: 6, right: 6 })
    .borderRadius(0)
    .backgroundColor(Color.Transparent)
    .enabled(enabled)
    .opacity(enabled ? 1 : 0.42)
    .onClick(action)
  }

  @Builder
  private PeerDeviceRow(peer: PeerSummary) {
    Column({ space: 0 }) {
      Divider().color($r('sys.color.comp_divider'))
      Row({ space: 10 }) {
        Stack({ alignContent: Alignment.Center }) {
          Image(this.peerDeviceIcon(peer.deviceType))
            .width(19)
            .height(19)
            .objectFit(ImageFit.Contain)
            .fillColor($r('sys.color.icon_primary'))
          Row()
            .width(8)
            .height(8)
            .borderRadius(4)
            .border({ width: 2, color: this.groupBackground() })
            .backgroundColor(peer.online ? $r('app.color.status_success') :
              $r('app.color.status_offline'))
            .position({ x: 21, y: 21 })
        }
        .width(36)
        .height(36)
        .borderRadius(11)
        .backgroundColor(this.secondaryBackground())
        Column({ space: 1 }) {
          Text(this.peerDisplayName(peer.name))
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Row({ space: 5 }) {
            Text(peer.online ? $r('app.string.peer_online') : $r('app.string.peer_offline'))
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
            if (this.peerDeviceDescription(peer).length > 0) {
              Text('· ' + this.peerDeviceDescription(peer))
                .fontSize(12)
                .fontColor($r('sys.color.font_secondary'))
            }
            if (peer.exitNode) {
              Text($r('app.string.peer_exit_node'))
                .fontSize(12)
                .fontColor($r('sys.color.font_secondary'))
            }
          }
          .width('100%')
          if (peer.addresses.length > 0) {
            Text(this.primaryTailscaleAddress(peer.addresses))
              .fontSize(11)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(1)
              .width('100%')
          }
          if (this.peerServiceBadgesVisible(peer)) {
            Row({ space: 5 }) {
              SunshineStatusBadge({ state: this.streamingState(peer.key).sunshine.state })
              MediaStatusBadge({
                state: this.mediaState(peer.key).result.state,
                serviceNames: this.mediaServiceNames(peer.key)
              })
            }
            .width('100%')
            .margin({ top: 3 })
          }
          if (peer.keyExpired || this.keyExpiresSoon(peer.keyExpiryUnixMs)) {
            Row() {
              this.DeviceStatusNotice(this.keyExpiryLabel(peer.keyExpired,
                peer.keyExpiryUnixMs), peer.keyExpired)
            }
            .width('100%')
            .margin({ top: 3 })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(18)
          .fontColor([$r('sys.color.icon_secondary')])
          .rotate({ angle: this.isPeerNameExpanded(peer.key) ? 180 : 0 })
          .animation({ duration: 260, curve: Curve.EaseInOut })
      }
      .width('100%')
      .constraintSize({ minHeight: 52 })
      .padding({ top: 6, right: 12, bottom: 6 })
      .onClick(() => this.togglePeer(peer))
      if (this.isPeerNameExpanded(peer.key)) {
        Column({ space: 8 }) {
          if (peer.online && peer.addresses.length > 0) {
            DeviceConnectionInfoPanel({
              path: this.streamingState(peer.key).path,
              sunshine: this.streamingState(peer.key).sunshine,
              media: this.mediaState(peer.key).result,
              checking: this.streamingState(peer.key).checking,
              refreshing: this.streamingState(peer.key).checking || this.mediaState(peer.key).checking,
              onRefresh: () => this.refreshPeerServices(peer)
            })
            DeviceActionButtons({
              sunshineState: this.streamingState(peer.key).sunshine.state,
              reachable: this.streamReachable(this.streamingState(peer.key)),
              meshConnected: this.isConnected(),
              peerOnline: peer.online,
              ipAvailable: peer.addresses.length > 0,
              launching: this.streamingState(peer.key).launching,
              showStreaming: this.isSunshineCandidate(peer),
              mediaState: this.mediaState(peer.key).result.state,
              mediaCount: this.mediaState(peer.key).result.services.length,
              mediaChecking: this.mediaState(peer.key).checking,
              mediaLaunching: this.mediaState(peer.key).launching,
              onStream: () => this.launchRemoteStream(peer),
              onDetectMedia: () => this.detectMediaForPeer(peer, true),
              onMedia: () => this.launchMediaForPeer(peer),
              onCopyIp: () => this.copyDeviceValue(this.primaryTailscaleAddress(peer.addresses),
                $r('app.string.peer_ip_copied'))
            })
          } else {
            Row({ space: 0 }) {
              this.PeerActionSegment($r('app.string.peer_copy_ip'), 'peer-copy-ip-' + peer.key,
                peer.addresses.length > 0, false,
                () => this.copyDeviceValue(this.primaryTailscaleAddress(peer.addresses),
                  $r('app.string.peer_ip_copied')))
            }
            .width('100%').height(36).alignItems(VerticalAlign.Center)
            .backgroundColor($r('app.color.action_copy_surface'))
            .border({ width: 1, color: $r('app.color.action_copy_border') })
            .borderRadius(18).clip(true)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 46, right: 12, bottom: 10 })
        .transition(TransitionEffect.IDENTITY)
      }
    }
    .width('100%')
    .clip(true)
  }

  @Builder
  private PeerSelectionRow(peer: PeerSummary) {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.Center }) {
        Image(this.peerDeviceIcon(peer.deviceType))
          .width(18)
          .height(18)
          .objectFit(ImageFit.Contain)
          .fillColor($r('sys.color.icon_primary'))
        Row()
          .width(8)
          .height(8)
          .borderRadius(4)
          .border({ width: 2, color: this.groupBackground() })
          .backgroundColor(peer.online ? $r('app.color.status_success') :
            $r('app.color.status_offline'))
          .position({ x: 20, y: 20 })
      }
      .width(34)
      .height(34)
      .borderRadius(10)
      .backgroundColor(this.secondaryBackground())
      Column({ space: 2 }) {
        Text(this.peerDisplayName(peer.name))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(peer.addresses.length > 0 ? this.primaryTailscaleAddress(peer.addresses) :
          (peer.online ? $r('app.string.peer_online') : $r('app.string.peer_offline')))
          .fontSize(11)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 10, right: 10, top: 7, bottom: 7 })
    .borderRadius(12)
    .backgroundColor(this.selectedPeerKey === peer.key ? this.secondaryBackground() : Color.Transparent)
    .onClick(() => {
      this.selectedPeerKey = peer.key;
    })
  }

  @Builder
  private ExpandedPeerDetailPanel(peer: PeerSummary) {
    Column({ space: 12 }) {
      Column({ space: 4 }) {
        Text(this.peerDisplayName(peer.name))
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(peer.online ? $r('app.string.peer_online') : $r('app.string.peer_offline'))
          .fontSize(13)
          .fontColor(peer.online ? $r('app.color.status_success') : $r('app.color.status_offline'))
        Text(peer.addresses.length > 0 ? this.primaryTailscaleAddress(peer.addresses) : '')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.peerDeviceDescription(peer) + (peer.deviceModel.length > 0 ? ' · ' + peer.deviceModel : ''))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .width('100%')
      if (peer.online && peer.addresses.length > 0) {
        DeviceConnectionInfoPanel({
          path: this.streamingState(peer.key).path,
          sunshine: this.streamingState(peer.key).sunshine,
          media: this.mediaState(peer.key).result,
          checking: this.streamingState(peer.key).checking,
          refreshing: this.streamingState(peer.key).checking || this.mediaState(peer.key).checking,
          onRefresh: () => this.refreshPeerServices(peer)
        })
        DeviceActionButtons({
          sunshineState: this.streamingState(peer.key).sunshine.state,
          reachable: this.streamReachable(this.streamingState(peer.key)),
          meshConnected: this.isConnected(),
          peerOnline: peer.online,
          ipAvailable: peer.addresses.length > 0,
          launching: this.streamingState(peer.key).launching,
          showStreaming: this.isSunshineCandidate(peer),
          mediaState: this.mediaState(peer.key).result.state,
          mediaCount: this.mediaState(peer.key).result.services.length,
          mediaChecking: this.mediaState(peer.key).checking,
          mediaLaunching: this.mediaState(peer.key).launching,
          onStream: () => this.launchRemoteStream(peer),
          onDetectMedia: () => this.detectMediaForPeer(peer, true),
          onMedia: () => this.launchMediaForPeer(peer),
          onCopyIp: () => this.copyDeviceValue(this.primaryTailscaleAddress(peer.addresses),
            $r('app.string.peer_ip_copied'))
        })
      } else {
        Text($r('app.string.peer_offline'))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .padding(12)
          .backgroundColor(this.secondaryBackground())
          .borderRadius(12)
        Row() {
          this.PeerActionSegment($r('app.string.peer_copy_ip'), 'peer-detail-copy-ip-' + peer.key,
            peer.addresses.length > 0, false,
            () => this.copyDeviceValue(this.primaryTailscaleAddress(peer.addresses),
              $r('app.string.peer_ip_copied')))
        }
        .width('100%')
        .height(36)
        .backgroundColor($r('app.color.action_copy_surface'))
        .border({ width: 1, color: $r('app.color.action_copy_border') })
        .borderRadius(18)
        .clip(true)
      }
    }
    .width('100%')
    .padding(20)
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
  }

  @Builder
  private DevicesPanel() {
    if (this.isExpandedLayout()) {
      Row({ space: 16 }) {
        Column({ space: 8 }) {
          this.SectionHeader($r('app.string.devices_title'),
            $r('app.string.devices_count', this.onlinePeerCount() + (this.isConnected() ? 1 : 0),
              this.peers.length + 1))
          List({ scroller: this.homePeerScroller }) {
            ListItem() {
              this.LocalDeviceRow()
            }
            LazyForEach(this.peerDataSource, (peer: PeerSummary) => {
              ListItem() {
                this.PeerSelectionRow(peer)
              }
            }, (peer: PeerSummary) => peer.key)
          }
          .width('100%')
          .layoutWeight(1)
          .edgeEffect(EdgeEffect.Spring)
          .scrollBar(this.peers.length + 1 > 5 ? BarState.Auto : BarState.Off)
          .scrollBarWidth(3)
          .cachedCount(5)
          .onScrollIndex((start: number, _end: number) => this.recordHomePeerScrollAnchor(start))
        }
        .width(ResponsiveLayout.MASTER_PANEL_WIDTH)
        .height('100%')
        .padding({ left: 12, right: 8, top: 14, bottom: 10 })
        .backgroundColor(this.groupBackground())
        .borderRadius(16)
        .clip(true)
        Column() {
          if (this.selectedPeerKey.length > 0) {
            ForEach(this.peers, (peer: PeerSummary) => {
              if (peer.key === this.selectedPeerKey) {
                this.ExpandedPeerDetailPanel(peer)
              }
            }, (peer: PeerSummary) => peer.key)
          } else {
            Text($r('app.string.transfer_no_targets_description'))
              .fontSize(14)
              .fontColor($r('sys.color.font_secondary'))
              .textAlign(TextAlign.Center)
              .width('100%')
              .padding(24)
              .backgroundColor(this.groupBackground())
              .borderRadius(16)
          }
        }
        .layoutWeight(1)
        .height('100%')
        .justifyContent(FlexAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .constraintSize({ minHeight: 260 })
      .animation({ duration: 260, curve: Curve.EaseInOut })
      .id('home-master-detail')
    } else {
      Column({ space: 0 }) {
        this.SectionHeader($r('app.string.devices_title'),
          $r('app.string.devices_count', this.onlinePeerCount() + (this.isConnected() ? 1 : 0),
            this.peers.length + 1))
        Text('')
          .id('peer-summary')
          .height(4)
          .fontSize(1)
          .accessibilityLevel('no')
        List({ scroller: this.homePeerScroller }) {
          ListItem() {
            this.LocalDeviceRow()
          }
          LazyForEach(this.peerDataSource, (peer: PeerSummary) => {
            ListItem() {
              this.PeerDeviceRow(peer)
            }
          // Keep the peer identity stable. PeerDataSource emits onDataChange for
          // online/address changes so a status refresh does not tear down a ListItem.
          }, (peer: PeerSummary) => peer.key)
        }
        .width('100%')
        .layoutWeight(1)
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(this.peers.length + 1 > 3 ? BarState.Auto : BarState.Off)
        .scrollBarWidth(3)
        .cachedCount(5)
        .onScrollIndex((start: number, _end: number) => this.recordHomePeerScrollAnchor(start))
      }
      .width('100%')
      .height('100%')
      .constraintSize({ minHeight: 160 })
      .padding({ left: 16, right: 4, top: 14, bottom: 16 })
      .backgroundColor(this.groupBackground())
      .borderRadius(16)
      .clip(true)
      .id('home-single-column')
    }
  }

  @Builder
  private HomeLayoutSettingsPanel() {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Text('主页连接布局')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Select([{ value: '紧凑布局' }, { value: '经典布局' }])
        .id('connected-home-layout-select')
        .selected(this.connectedHomeLayoutMode === ConnectedHomeLayoutMode.COMPACT ? 0 : 1)
        .value(this.connectedHomeLayoutMode === ConnectedHomeLayoutMode.COMPACT ? '紧凑布局' : '经典布局')
        .font({ size: 12 })
        .optionFont({ size: 12 })
        .menuBackgroundColor(this.glowSurface())
        .menuBackgroundBlurStyle(BlurStyle.COMPONENT_REGULAR)
        .controlSize(ControlSize.SMALL)
        .constraintSize({ minWidth: 100, maxWidth: 116 })
        .onSelect((index: number) => this.setConnectedHomeLayoutMode(index === 0 ?
          ConnectedHomeLayoutMode.COMPACT : ConnectedHomeLayoutMode.LEGACY))
    }
    .id('connected-home-layout-settings')
    .width('100%')
    .constraintSize({ minHeight: 50 })
    .padding(12)
  }

  @Builder
  private GlowSettingsPanel() {
    Row({ space: 10 }) {
      Text($r('app.string.glow_title'))
        .id('settings-page-title')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Select([
        { value: $r('app.string.glow_exquisite') },
        { value: $r('app.string.glow_gentle') },
        { value: $r('app.string.glow_smooth') },
        { value: $r('app.string.glow_adaptive') }
      ])
        .id('glow-select')
        .selected(this.glowLevel)
        .value(this.glowLevelLabel())
        .font({ size: 12 })
        .optionFont({ size: 12 })
        .menuBackgroundColor(this.glowSurface())
        .menuBackgroundBlurStyle(BlurStyle.COMPONENT_REGULAR)
        .controlSize(ControlSize.SMALL)
        .constraintSize({ minWidth: 100, maxWidth: 144 })
        .onSelect((index: number, _value?: string) => this.setGlowLevel(index))
    }
    .id('glow-settings')
    .width('100%')
    .constraintSize({ minHeight: 50 })
    .padding(12)
  }

  @Builder
  private AppearanceSettingsPanel() {
    Column({ space: 0 }) {
      this.GlowSettingsPanel()
      Divider()
        .color($r('sys.color.comp_divider'))
        .margin({ left: 12, right: 12 })
      this.HomeLayoutSettingsPanel()
    }
    .id('appearance-settings')
    .width('100%')
    .backgroundColor(this.groupBackground())
    .borderRadius(12)
    .clip(true)
  }

  @Builder
  private CacheSettingsPanel() {
    Column({ space: 0 }) {
      Row({ space: 10 }) {
        Text($r('app.string.settings_cache_title'))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text($r('app.string.settings_cache_description'))
          .fontSize(11)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Blank()
          .layoutWeight(1)

        Text(this.cacheSizeLabel())
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)

        Text($r('app.string.settings_clear_cache_action'))
          .id('settings-clear-cache')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_emphasize'))
          .opacity(this.cacheClearEnabled() ? 1 : 0.42)
          .onClick(() => this.confirmClearAppCache())
      }
      .width('100%')
      .constraintSize({ minHeight: 50 })
      .padding(12)
    }
    .id('cache-settings')
    .width('100%')
    .backgroundColor(this.groupBackground())
    .borderRadius(12)
    .clip(true)
  }

  @Builder
  private AccountPanel() {
    Column({ space: 6 }) {
      if (this.controlServerEditorVisible) {
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Text($r('app.string.control_server_title'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1)
          Text(this.controlServerConfirmed ? $r('app.string.control_server_confirmed') :
            $r('app.string.control_server_not_confirmed'))
            .fontSize(11)
            .fontColor(this.controlServerConfirmed ? $r('app.color.status_success') :
              $r('app.color.status_warning'))
        }
        Text($r('app.string.control_server_description'))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .lineHeight(17)
          .width('100%')
        TextInput({
          text: this.controlServerInput,
          placeholder: DEFAULT_CONTROL_SERVER_URL
        })
          .id('control-server-input')
          .width('100%')
          .height(42)
          .padding({ left: 12, right: 12 })
          .fontSize(13)
          .fontColor($r('sys.color.font_primary'))
          .placeholderColor($r('sys.color.font_secondary'))
          .backgroundColor(this.glowSurface())
          .backgroundEffect({
            radius: this.glowRadius(),
            saturation: this.glowSaturation(),
            brightness: this.glowBrightness(),
            color: this.glowSurface(),
            adaptiveColor: AdaptiveColor.DEFAULT
          }, { disableSystemAdaptation: false })
          .visualEffect(this.immersivePressEffect())
          .border({
            width: 1,
            color: this.controlServerInputFocused ?
              $r('sys.color.comp_background_emphasize') : $r('sys.color.comp_divider')
          })
          .borderRadius(12)
          .shadow({
            radius: this.controlServerInputFocused ? 8 : 0,
            color: this.glowColor(),
            offsetY: this.controlServerInputFocused ? 2 : 0
          })
          .scale({
            x: this.controlServerInputFocused ? 1.004 : 1,
            y: this.controlServerInputFocused ? 1.004 : 1
          })
          .animation({ duration: 220, curve: Curve.EaseOut })
          .selectionMenuHidden(false)
          .enabled(!this.isConnected() && !this.isConnecting())
          .onFocus(() => {
            this.controlServerInputFocused = true;
          })
          .onBlur(() => {
            this.controlServerInputFocused = false;
          })
          .onChange((value: string) => {
            this.controlServerInput = value;
            this.controlServerStatus = '';
          })
        Button($r('app.string.control_server_save'), {
          type: ButtonType.ROUNDED_RECTANGLE,
          stateEffect: true,
          buttonStyle: ButtonStyleMode.NORMAL,
          controlSize: ControlSize.NORMAL
        })
          .id('control-server-save')
          .width('100%')
          .visualEffect(this.immersivePressEffect())
          .enabled(!this.isConnected() && !this.isConnecting())
          .onClick(() => this.saveControlServer())
        if (this.controlServerStatus.length > 0) {
          Text(this.controlServerStatusText())
            .fontSize(12)
            .fontColor(this.controlServerStatus === 'saved' ? $r('app.color.status_success') :
              $r('app.color.status_error'))
            .width('100%')
        }
        Divider().color($r('sys.color.comp_divider'))
      }
      .width('100%')
      .transition(
        TransitionEffect.asymmetric(
          TransitionEffect.OPACITY.animation({ duration: MotionTokens.PAGE, curve: Curve.EaseOut })
            .combine(TransitionEffect.translate({ y: -12 })),
          TransitionEffect.OPACITY.animation({ duration: MotionTokens.FAST, curve: Curve.EaseIn })
            .combine(TransitionEffect.translate({ y: -8 }))
        )
      )
      }

      if (!this.isAuthenticated()) {
        Row({ space: 12 }) {
          Stack() {
            Image($r('app.media.tab_home'))
              .width(28)
              .height(28)
              .fillColor($r('sys.color.icon_secondary'))
          }
          .width(48)
          .height(48)
          .borderRadius(24)
          .backgroundColor(this.secondaryBackground())
          Text($r('app.string.account_profile_unavailable'))
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .layoutWeight(1)
        }
        .width('100%')
        Row({ space: 8 }) {
          if (this.controlServerConfirmed) {
            Button({
              type: ButtonType.Normal,
              stateEffect: true
            }) {
              this.ButtonContent(this.loginInProgress ? this.loginPrompt :
                $r('app.string.action_login'), !this.loginInProgress, this.loginInProgress)
            }
              .id('account-login')
              .height(48)
              .layoutWeight(1)
              .borderRadius(24)
              .backgroundColor(this.loginInProgress ? this.secondaryBackground() :
                $r('app.color.account_action_primary'))
              .opacity(1)
              .enabled(!this.loginInProgress)
              .onClick(() => this.openSecureLogin())
          } else {
            Row() {
              Text($r('app.string.action_login'))
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary'))
            }
            .id('account-login-disabled')
            .height(48)
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .borderRadius(24)
            .backgroundColor(this.secondaryBackground())
          }

          if (this.controlServerConfirmed) {
            Button({
              type: ButtonType.Circle,
              stateEffect: true,
              buttonStyle: ButtonStyleMode.NORMAL,
              controlSize: ControlSize.NORMAL
            }) {
              Image($r('app.media.edit'))
                .width(20)
                .height(20)
                .fillColor($r('sys.color.icon_primary'))
              }
              .id('control-server-edit')
              .backgroundColor(Color.Transparent)
              .border({
                width: 1,
                color: $r('sys.color.comp_divider'),
                radius: 24
              })
              .width(48)
              .height(48)
              .onClick(() => this.toggleControlServerEditor())
          }
        }
        .width('100%')
        if (this.loginHandoffStatus.startsWith('FAILED')) {
          Text(this.loginHandoffStatus)
            .id('login-handoff-status')
            .fontSize(12)
            .fontColor(this.loginHandoffStatus.startsWith('FAILED') ?
              $r('app.color.status_error') : $r('sys.color.font_secondary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      } else {
        Row({ space: 10 }) {
          Stack() {
            if (this.accountSummary.profilePicURL.length > 0 && !this.avatarLoadFailed) {
              Image(this.accountSummary.profilePicURL)
                .id('account-avatar')
                .width(40)
                .height(40)
                .borderRadius(20)
                .objectFit(ImageFit.Cover)
                .onError(() => {
                  this.avatarLoadFailed = true;
                })
            } else {
              Text(this.accountInitial())
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_emphasize'))
            }
          }
          .width(40)
          .height(40)
          .borderRadius(20)
          .backgroundColor(this.secondaryBackground())

          Column({ space: 2 }) {
            Text(this.accountSummary.displayName)
              .id('account-display-name')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(this.accountSummary.loginName)
              .id('account-login-name')
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')

        Divider().color($r('sys.color.comp_divider'))
        this.AccountDetailRow($r('app.string.account_tailnet'),
          this.accountSummary.tailnetName, 'account-tailnet')
        this.AccountDetailRow($r('app.string.account_device'),
          this.localDeviceName(), 'account-device')

        if (!this.isConnected()) {
          Text($r('app.string.logout_description'))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
          Button({
            type: ButtonType.Normal,
            stateEffect: true
          }) {
            Text($r('app.string.logout_action'))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.account_action_destructive'))
          }
            .id('logout-open')
            .width('100%')
            .height(40)
            .borderRadius(20)
            .backgroundColor(Color.Transparent)
            .border({
              width: 1,
              color: $r('sys.color.comp_divider'),
              radius: 20
            })
            .onClick(() => this.confirmLogout())
        }
      }

      if (this.logoutStatus.startsWith('FAILED')) {
        Text($r('app.string.logout_failed'))
          .id('logout-status')
          .fontSize(12)
          .fontColor($r('app.color.status_error'))
          .width('100%')
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.groupBackground())
    .borderRadius(14)
  }

  @Builder
  private AccountDetailRow(label: ResourceStr, value: string, nodeId: string,
    action?: () => void) {
    Row({ space: 12 }) {
      Text(label)
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
      Text(value.length > 0 ? value : '—')
        .id(nodeId)
        .fontSize(13)
        .fontColor($r('sys.color.font_primary'))
        .textAlign(TextAlign.End)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .constraintSize({ minHeight: 34 })
    .onClick(() => {
      if (action !== undefined) {
        action();
      }
    })
  }

  @Builder
  private AppVersionActionRow() {
    Button({
      type: ButtonType.Normal,
      stateEffect: true,
      buttonStyle: ButtonStyleMode.TEXTUAL,
      controlSize: ControlSize.NORMAL
    }) {
      Row({ space: 12 }) {
        Text($r('app.string.app_version_label'))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
        Text(this.appVersion)
          .id('app-version')
          .fontSize(13)
          .fontColor($r('sys.color.font_primary'))
          .textAlign(TextAlign.End)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
    }
    .id('app-version-action')
    .width('100%')
    .height(40)
    .padding(0)
    .borderRadius(12)
    .backgroundColor(Color.Transparent)
    .onClick(() => this.onAppVersionTap())
  }

  @Builder
  private VersionPanel() {
    Column({ space: 0 }) {
      this.AppVersionActionRow()
      Divider().color($r('sys.color.comp_divider'))
      this.AccountDetailRow($r('app.string.tailscale_version_label'),
        this.tailscaleVersion, 'tailscale-version')
      Divider().color($r('sys.color.comp_divider'))
      this.AccountDetailRow($r('app.string.feedback_label'), FEEDBACK_EMAIL,
        'feedback-email', () => this.openFeedbackEmail())
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.groupBackground())
    .borderRadius(14)
  }

  @Builder
  private DiagnosticStatus(title: ResourceStr | string, value: string, nodeId: string) {
    Column({ space: 2 }) {
      Text(title)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_secondary'))
        .width('100%')
      Text(value)
        .id(nodeId)
        .fontSize(14)
        .fontColor(value.startsWith('FAILED') ?
          $r('app.color.status_error') : $r('sys.color.font_primary'))
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(20)
        .width('100%')
    }
    .width('100%')
    .padding({ top: 7, bottom: 7 })
  }

  @Builder
  private DiagnosticSectionHeader(title: ResourceStr | string, description: ResourceStr | string) {
    Column({ space: 4 }) {
      Text(title)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
      Text(description)
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
        .lineHeight(20)
        .width('100%')
    }
    .width('100%')
    .padding({ top: 3, bottom: 3 })
  }

  @Builder
  private DiagnosticsStatusPanel() {
    Column({ space: 0 }) {
      this.DiagnosticStatus('Go Bridge', this.nativeStatus, 'smoke-go-status')
      Divider().color($r('sys.color.comp_divider'))
      this.DiagnosticStatus('Tailscale Engine', this.engineStatus, 'engine-status')
      Divider().color($r('sys.color.comp_divider'))
      this.DiagnosticStatus($r('app.string.diagnostic_control_plane_status_title'),
        this.backendStatus, 'backend-status')
      Divider().color($r('sys.color.comp_divider'))
      this.DiagnosticStatus($r('app.string.diagnostic_vpn_extension_status_title'),
        this.vpnStatus, 'vpn-status')
    }
    .width('100%')
  }

  @Builder
  private DiagnosticsProbePanel() {
    Column({ space: 10 }) {
      this.DiagnosticSectionHeader($r('app.string.diagnostic_probe_title'),
        $r('app.string.diagnostic_probe_description'))
      this.StandardActionButton($r('app.string.diagnostic_refresh_status_action'),
        'backend-refresh', false, true, () => {
          this.verifyNativeBridge();
          this.refreshBackendStatus();
          this.refreshVpnProbeStatus();
        })
      this.StandardActionButton($r('app.string.diagnostic_probe_engine_action'),
        'engine-probe', false, true, () => this.probeUserspaceEngine())
      this.StandardActionButton($r('app.string.diagnostic_probe_control_tls_action'),
        'control-probe', false,
        this.controlServerConfirmed && this.controlServerURL === DEFAULT_CONTROL_SERVER_URL,
        () => this.runControlProbe())
    }
    .width('100%')
  }

  @Builder
  private DiagnosticsDangerousPanel() {
    Column({ space: 8 }) {
      this.DiagnosticSectionHeader($r('app.string.diagnostic_dangerous_title'),
        $r('app.string.diagnostic_dangerous_description'))
      this.StandardActionButton($r('app.string.diagnostic_reset_first_run_action'),
        'diagnostic-reset-first-run', false, !this.diagnosticActionInProgress,
        () => this.confirmResetFirstRun(), false, true)
      this.StandardActionButton($r('app.string.diagnostic_force_vpn_stop_action'),
        'diagnostic-force-vpn-stop', false, !this.diagnosticActionInProgress,
        () => this.forceStopSystemVpn(), false, true)
      this.StandardActionButton($r('app.string.diagnostic_simulate_crash_action'),
        'diagnostic-simulate-crash', false, !this.diagnosticActionInProgress,
        () => this.confirmSimulateAppCrash(), false, true)
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text($r('app.string.diagnostic_fake_media_online_title'))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
          Text($r('app.string.diagnostic_fake_media_online_description'))
            .fontSize(11)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(2)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.fakeMediaServiceOnline })
          .id('diagnostic-fake-media-online')
          .onChange((enabled: boolean) => {
            this.fakeMediaServiceOnline = enabled;
          })
      }
      .width('100%')
      .padding({ top: 6, bottom: 6 })
      if (this.diagnosticActionStatus.length > 0) {
        this.DiagnosticStatus($r('app.string.diagnostic_action_status'),
          this.diagnosticActionStatus, 'diagnostic-action-status')
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.diagnostic_danger_surface'))
    .borderRadius(12)
  }

  @Builder
  private DiagnosticsMediaPanel() {
    Column({ space: 8 }) {
      this.DiagnosticSectionHeader($r('app.string.diagnostic_media_integration_title'),
        $r('app.string.diagnostic_media_integration_description'))
      this.StandardActionButton($r('app.string.diagnostic_media_self_test_action'),
        'diagnostic-media-self-test', false, !this.mediaSelfTestInProgress,
        () => this.runMediaIntegrationSelfTest(), this.mediaSelfTestInProgress)
      this.StandardActionButton($r('app.string.diagnostic_hosplayer_copy_action'),
        'diagnostic-hosplayer-contract', false, !this.mediaSelfTestInProgress,
        () => this.copyHosPlayerPrototype())
      if (this.mediaSelfTestStatus.length > 0) {
        this.DiagnosticStatus($r('app.string.diagnostic_media_self_test_status'),
          this.mediaSelfTestStatus, 'diagnostic-media-self-test-status')
      }
    }
    .width('100%')
  }

  @Builder
  private DiagnosticsReportPanel() {
    Column({ space: 8 }) {
      this.DiagnosticSectionHeader($r('app.string.diagnostic_report_title'),
        $r('app.string.diagnostic_report_description'))
      if (this.diagnosticReportStatus.length > 0) {
        this.DiagnosticStatus($r('app.string.diagnostic_report_title'),
          this.diagnosticReportStatus, 'diagnostic-report-status')
      }
      this.StandardActionButton($r('app.string.diagnostic_report_action'),
        'diagnostic-report-generate', true, !this.diagnosticReportInProgress,
        () => this.generateDiagnosticReport(), this.diagnosticReportInProgress)
    }
    .width('100%')
  }

  @Builder
  private DiagnosticsActionsPanel() {
    Column({ space: 12 }) {
      this.DiagnosticsProbePanel()
      Divider().color($r('sys.color.comp_divider'))
      this.DiagnosticsDangerousPanel()
      Divider().color($r('sys.color.comp_divider'))
      this.DiagnosticsMediaPanel()
      Divider().color($r('sys.color.comp_divider'))
      this.DiagnosticsReportPanel()
    }
    .width('100%')
  }

  @Builder
  private DiagnosticsPanel() {
    Column() {
      if (this.isSettingsTwoColumnLayout()) {
        Row({ space: 16 }) {
          Column() {
            this.DiagnosticsStatusPanel()
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Column() {
            this.DiagnosticsActionsPanel()
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      } else {
        Column({ space: 12 }) {
          this.DiagnosticsStatusPanel()
          Divider().color($r('sys.color.comp_divider'))
          this.DiagnosticsActionsPanel()
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 16 })
  }

  @Builder
  private DiagnosticsDisclosure() {
    Column({ space: 0 }) {
      Button({
        type: ButtonType.Normal,
        stateEffect: true,
        buttonStyle: ButtonStyleMode.TEXTUAL,
        controlSize: ControlSize.NORMAL
      }) {
        Row({ space: 12 }) {
          Column({ space: 2 }) {
            Text($r('app.string.diagnostics_title'))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
              .width('100%')
            Text($r('app.string.diagnostics_description'))
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(20)
            .fontColor([$r('sys.color.icon_secondary')])
            .rotate({ angle: this.diagnosticsExpanded ? 180 : 0 })
            .animation({ duration: 220, curve: Curve.EaseInOut })
        }
        .width('100%')
        .padding({ left: 4, right: 4 })
      }
      .id('diagnostics-disclosure')
      .width('100%')
      .height(56)
      .borderRadius(12)
      .onClick(() => {
        this.diagnosticsExpanded = !this.diagnosticsExpanded;
      })

      if (this.diagnosticsExpanded) {
        Column({ space: 0 }) {
          Divider()
            .color($r('sys.color.comp_divider'))
            .margin({ left: 16, right: 16 })
          this.DiagnosticsPanel()
        }
        .width('100%')
        .transition(
          TransitionEffect.asymmetric(
            TransitionEffect.OPACITY.animation({ duration: MotionTokens.EXPAND, curve: Curve.EaseOut })
              .combine(TransitionEffect.translate({ y: -8 })),
            TransitionEffect.OPACITY.animation({ duration: MotionTokens.FAST, curve: Curve.EaseIn })
              .combine(TransitionEffect.translate({ y: -6 }))
          )
        )
      }
    }
    .width('100%')
    .padding({ left: 10, right: 10 })
    .backgroundColor(this.groupBackground())
    .borderRadius(14)
    .margin({ top: 10 })
  }

  @Builder
  private HomeContent() {
    Scroll(this.homeScroller) {
      Column() {
        Column({ space: 12 }) {
          this.HomeConnectionHeader()
          if (this.isBackendLoading() || this.devicesLoading) {
            Column() {
              this.DevicesLoadingPanel()
            }
            .width('100%')
            .layoutWeight(1)
            .transition(
              TransitionEffect.OPACITY.animation({ duration: MotionTokens.NORMAL, curve: Curve.EaseOut })
                .combine(TransitionEffect.translate({ y: 12 }))
            )
          } else if (!this.isAuthenticated()) {
            Column() {
              this.DevicesSignedOutPanel()
            }
            .width('100%')
            .layoutWeight(1)
            .transition(
              TransitionEffect.OPACITY.animation({ duration: MotionTokens.NORMAL, curve: Curve.EaseOut })
                .combine(TransitionEffect.translate({ y: 12 }))
            )
          } else {
            Column() {
              this.DevicesPanel()
            }
            .width('100%')
            .layoutWeight(1)
            .transition(
              TransitionEffect.OPACITY.animation({ duration: MotionTokens.NORMAL, curve: Curve.EaseOut })
                .combine(TransitionEffect.translate({ y: 12 }))
            )
          }
        }
        .width('100%')
        .layoutWeight(1)
        .constraintSize({ maxWidth: ResponsiveLayout.EXPANDED_CONTENT_MAX_WIDTH })
        .padding({
          left: this.contentMargin(),
          right: this.contentMargin(),
          top: 8
        })
        .alignItems(HorizontalAlign.Center)

        Blank()
          .width('100%')
          .height(this.pageBottomInset())
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Auto)
    .scrollBarWidth(4)
    .align(Alignment.TopStart)
  }

  @Builder
  private TaildropTargetRow(target: TaildropTargetSummary) {
    Column({ space: 0 }) {
      Row({ space: 12 }) {
        Stack() {
          Image(this.peerDeviceIcon(target.deviceType))
            .width(22)
            .height(22)
            .fillColor(target.online ? $r('sys.color.icon_primary') :
              $r('sys.color.icon_secondary'))
        }
        .width(38)
        .height(38)
        .borderRadius(12)
        .backgroundColor(this.secondaryBackground())

        Column({ space: 2 }) {
          Text(target.name)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.taildropTargetDescription(target))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (!target.online) {
          Text($r('app.string.peer_offline'))
            .fontSize(11)
            .fontColor($r('sys.color.font_secondary'))
        }
      }
      .width('100%')
      .constraintSize({ minHeight: 54 })
      .padding({ left: 12, right: 12 })
      if (target.online) {
        Row() {
          this.TaildropFileMediaCapsule(target)
        }
        .width('100%')
        .padding({ left: 12, right: 12, bottom: 8 })
      }
      if (this.taildropTextEditorVisible && this.taildropTextTarget !== undefined &&
        this.taildropTextTarget.key === target.key) {
        this.TaildropTextEditorSheet()
      }
    }
    .id('taildrop-target-' + target.key)
    .width('100%')
    .opacity(target.online ? 1 : 0.42)
    .animation({ duration: 260, curve: Curve.EaseInOut })
  }

  @Builder
  private TaildropFileMediaCapsule(target: TaildropTargetSummary) {
    Row({ space: 0 }) {
      this.PeerActionSegment($r('app.string.transfer_file_action'),
        'taildrop-file-' + target.key, target.online && this.taildropContentChoiceEnabled(), false,
        () => this.chooseTaildropDocuments(target))
      Divider()
        .vertical(true)
        .height(18)
        .color($r('sys.color.comp_divider'))
      this.PeerActionSegment($r('app.string.transfer_photo_action'),
        'taildrop-media-' + target.key, target.online && this.taildropContentChoiceEnabled(), false,
        () => this.chooseTaildropPhotos(target))
      Divider()
        .vertical(true)
        .height(18)
        .color($r('sys.color.comp_divider'))
      this.PeerActionSegment($r('app.string.transfer_text_action'),
        'taildrop-text-' + target.key, target.online && this.taildropContentChoiceEnabled(), false,
        () => this.chooseTaildropText(target))
    }
    .width('100%')
    .height(36)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.secondaryBackground())
    .borderRadius(18)
    .clip(true)
  }

  @Builder
  private TaildropTargetsPanel() {
    Column({ space: 0 }) {
      ForEach(this.displayedTaildropTargets(), (target: TaildropTargetSummary, index: number) => {
        if (index > 0) {
          Divider()
            .color($r('sys.color.comp_divider'))
        }
        this.TaildropTargetRow(target)
      // ForEach also retains children with stable keys. A target's stable peer
      // key alone therefore cannot reflect a live online/offline transition.
      }, (target: TaildropTargetSummary) => JSON.stringify(target))
    }
    .id('taildrop-targets-panel')
    .width('100%')
    .padding({ top: 4, bottom: 4 })
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
  }

  @Builder
  private TaildropTargetsEmptyPanel() {
    Text(!this.isConnected() ? $r('app.string.transfer_connect_first_description') :
      this.taildropState === 'disabled' ? $r('app.string.transfer_admin_disabled_description') :
        $r('app.string.transfer_no_targets_description'))
      .fontSize(12)
      .fontColor($r('sys.color.font_secondary'))
      .lineHeight(18)
      .textAlign(TextAlign.Center)
      .width('100%')
      .padding({ left: 20, right: 20, top: 20, bottom: 20 })
      .backgroundColor(this.groupBackground())
      .borderRadius(16)
  }

  @Builder
  private TaildropTextEditorSheet() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      TextArea({
        text: $$this.taildropTextInput,
        placeholder: $r('app.string.transfer_text_placeholder')
      })
        .width('100%')
        .height(156)
        .padding({ left: 12, right: 12, top: 12, bottom: 54 })
        .fontSize(14)
        .fontColor($r('sys.color.font_primary'))
        .placeholderColor($r('sys.color.font_secondary'))
        .backgroundColor(this.groupBackground())
        .borderWidth(0)
        .borderRadius(10)
        .selectionMenuHidden(false)
        .onChange((value: string) => {
          this.taildropTextInput = value;
          this.taildropTextInputCanSend = value.trim().length > 0;
        })

      Row({ space: 8 }) {
        this.TaildropTextEditorAction($r('sys.symbol.xmark'), true, () => {
          this.closeTaildropTextEditor();
        })
        this.TaildropTextEditorAction($r('sys.symbol.checkmark'), false, () => this.sendTaildropText())
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .padding({ right: 10, bottom: 10 })
      .zIndex(1)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 4, bottom: 12 })
  }

  @Builder
  private TaildropTextEditorAction(icon: Resource, cancelAction: boolean, action: () => void) {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      SymbolGlyph(icon)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor([$r('sys.color.icon_primary')])
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
    }
    .width(36)
    .height(36)
    .padding(0)
    .backgroundColor(this.secondaryBackground())
    .enabled(cancelAction || this.taildropTextInputCanSend)
    .opacity(cancelAction || this.taildropTextInputCanSend ? 1 : 0.42)
    .accessibilityText(cancelAction ? $r('app.string.cancel_action') : $r('app.string.transfer_send_action'))
    .onClick(action)
  }

  @Builder
  private TaildropActiveSendPanel() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Stack({ alignContent: Alignment.Center }) {
          if (this.taildropPreparing || this.taildropTransfer.state === 'queued') {
            LoadingProgress()
              .width(20)
              .height(20)
              .color($r('sys.color.icon_emphasize'))
          } else {
            SymbolGlyph(this.taildropFileSymbol(this.taildropTransfer.fileName))
              .fontSize(28)
              .fontColor([this.taildropFileIconColor(this.taildropTransfer.fileName)])
          }
        }
        .width(44)
        .height(44)
        .borderRadius(12)
        .backgroundColor(this.secondaryBackground())
        Column({ space: 2 }) {
          Text(this.taildropPreparing ? $r('app.string.transfer_preparing') :
            $r('app.string.transfer_sending_to', this.taildropTransfer.targetName))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .width('100%')
          if (this.taildropTransfer.fileName.length > 0) {
            Text(this.taildropTransfer.fileName)
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (this.taildropTransfer.state === 'queued' || this.taildropTransfer.state === 'sending') {
          Button(this.taildropCancelPending ? $r('app.string.transfer_cancelling') :
            $r('app.string.cancel_action'))
            .fontSize(12)
            .height(32)
            .backgroundColor(this.secondaryBackground())
            .fontColor($r('sys.color.font_primary'))
            .visualEffect(this.immersivePressEffect())
            .enabled(!this.taildropCancelPending)
            .opacity(this.taildropCancelPending ? 0.6 : 1)
            .onClick(() => this.cancelTaildropSend())
        }
      }
      .width('100%')
      Progress({ value: this.taildropTransferProgress(), total: 100, type: ProgressType.Linear })
        .width('100%')
        .height(5)
        .color($r('sys.color.icon_emphasize'))
      Row() {
        Text(`${this.taildropTransferProgress()}%`)
          .fontSize(11)
          .fontColor($r('sys.color.font_secondary'))
        Blank()
        Text(`${this.formatTrafficBytes(this.taildropTransfer.bytesSent)} / ` +
          `${this.formatTrafficBytes(this.taildropTransfer.totalBytes)}`)
          .fontSize(11)
          .fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
      Text(this.taildropTransferSpeedText())
        .fontSize(11)
        .fontColor($r('sys.color.font_secondary'))
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    .backgroundColor(this.groupBackground())
    .border({ width: 1, color: $r('sys.color.comp_divider'), radius: 16 })
    .transition(
      TransitionEffect.asymmetric(
        TransitionEffect.OPACITY.animation({ duration: MotionTokens.NORMAL, curve: Curve.EaseOut })
          .combine(TransitionEffect.translate({ y: -10 })),
        TransitionEffect.OPACITY.animation({ duration: MotionTokens.FAST, curve: Curve.EaseIn })
          .combine(TransitionEffect.translate({ y: -6 }))
      )
    )
  }

  @Builder
  private TaildropWaitingFileRow(file: TaildropWaitingFileSummary) {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        if (this.taildropWaitingFilePreviewUri(file).length > 0) {
          Image(this.taildropWaitingFilePreviewUri(file))
            .width(40)
            .height(40)
            .borderRadius(10)
            .objectFit(ImageFit.Cover)
        } else {
          SymbolGlyph(this.taildropFileSymbol(file.name))
            .fontSize(28)
            .fontColor([this.taildropFileIconColor(file.name)])
        }
      }
      .width(44)
      .height(44)
      Column({ space: 2 }) {
        Text(file.name)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .onClick(() => {
            if (this.taildropContentKind(file) === 'text') {
              this.startTaildropTextPreview(file);
            }
          })
          Row({ space: 6 }) {
            Text(this.taildropContentKindText(file))
              .fontSize(12)
              .fontColor(this.taildropFileIconColor(file.name))
            Text(this.formatTrafficBytes(file.size))
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.taildropReceiveRowLoading(file) && this.taildropContentKind(file) !== 'text') {
        LoadingProgress()
          .width(20)
          .height(20)
          .color($r('sys.color.icon_emphasize'))
      } else if (this.resolveTaildropMediaType(file.name) !== undefined) {
        Row({ space: 8 }) {
          Button({
            type: ButtonType.Circle,
            stateEffect: true,
            buttonStyle: ButtonStyleMode.TEXTUAL
          }) {
            SymbolGlyph($r('sys.symbol.save'))
              .fontSize(18)
              .fontColor([$r('sys.color.icon_primary')])
          }
            .width(40)
            .height(40)
            .padding(0)
            .backgroundColor(this.groupBackground())
            .borderWidth(0)
            .accessibilityText($r('app.string.transfer_save_action'))
            .enabled(this.taildropPreparedMediaSaveEnabled(file))
            .onClick(() => {
              this.handlePreparedTaildropMediaSaveClick(file);
            })
          Button({
            type: ButtonType.Circle,
            stateEffect: true,
            buttonStyle: ButtonStyleMode.TEXTUAL
          }) {
            SymbolGlyph($r('sys.symbol.trash'))
              .fontSize(18)
              .fontColor([$r('app.color.status_error')])
          }
            .width(32)
            .height(32)
            .padding(0)
            .backgroundColor(this.groupBackground())
            .borderWidth(0)
            .accessibilityText($r('app.string.transfer_discard_action'))
            .enabled(!this.taildropReceiveInProgress)
            .onClick(() => {
              if (!this.taildropReceiveInProgress) {
                this.confirmDiscardTaildropFile(file);
              }
            })
        }
      } else {
        Row({ space: 12 }) {
          if (this.taildropContentKind(file) === 'text') {
            Button({
              type: ButtonType.Circle,
              stateEffect: true,
              buttonStyle: ButtonStyleMode.TEXTUAL
            }) {
              if (this.taildropTextPreviewLoading(file)) {
                LoadingProgress()
                  .width(18)
                  .height(18)
                  .color($r('sys.color.icon_primary'))
              } else {
                SymbolGlyph(this.taildropReceiveMatches(file) &&
                  this.taildropReceive.state === 'awaiting_text_preview' ?
                  $r('sys.symbol.eye_slash') : $r('sys.symbol.eye'))
                  .fontSize(18)
                  .fontColor([$r('sys.color.icon_primary')])
              }
            }
              .width(32)
              .height(32)
              .padding(0)
              .backgroundColor(this.groupBackground())
              .borderWidth(0)
              .enabled(!this.taildropTextPreviewLoading(file))
              .accessibilityText(this.taildropReceiveMatches(file) &&
                this.taildropReceive.state === 'awaiting_text_preview' ?
                $r('app.string.transfer_collapse_action') :
                $r('app.string.transfer_preview_action'))
              .onClick(() => {
                if (this.taildropReceiveMatches(file) &&
                  this.taildropReceive.state === 'awaiting_text_preview') {
                  this.collapseTaildropTextPreview();
                } else {
                  this.startTaildropTextPreview(file);
                }
              })
          }
          Button({
            type: ButtonType.Circle,
            stateEffect: true,
            buttonStyle: ButtonStyleMode.TEXTUAL
          }) {
            SymbolGlyph(this.taildropContentKind(file) === 'text' ?
              $r('sys.symbol.text_clipboard') : $r('sys.symbol.save'))
              .fontSize(18)
              .fontColor([$r('sys.color.icon_primary')])
          }
            .width(32)
            .height(32)
            .padding(0)
            .backgroundColor(this.groupBackground())
            .borderWidth(0)
            .accessibilityText(this.taildropReceiveMatches(file) &&
              this.taildropReceive.state === 'awaiting_text_preview' ?
              $r('app.string.transfer_copy_text_action') :
              (this.taildropContentKind(file) === 'text' ?
                $r('app.string.transfer_copy_text_action') :
                $r('app.string.transfer_save_action')))
            .onClick(() => {
              if (this.taildropReceiveMatches(file) &&
                this.taildropReceive.state === 'awaiting_text_preview') {
                this.copyTaildropTextPreview();
                return;
              }
              if (this.taildropSendActive() || this.taildropReceiveInProgress) {
                this.showToast($r('app.string.transfer_busy_message'));
                return;
              }
              if (this.taildropContentKind(file) === 'text') {
                const cachedText: TaildropCachedFile | undefined =
                  this.findTaildropCachedFile(file);
                if (cachedText !== undefined) {
                  this.showCachedTaildropTextPreview(cachedText);
                  this.copyTaildropTextPreview();
                  return;
                }
              } else {
                const cachedFile: TaildropCachedFile | undefined =
                  this.findTaildropCachedFile(file);
                if (cachedFile !== undefined) {
                  this.startPreparedTaildropFileSave(file);
                  return;
                }
              }
              if (this.taildropState !== 'ready') {
                this.showToast($r('app.string.transfer_connect_first_title'));
                return;
              }
              this.startTaildropReceive(file);
            })
          Button({
            type: ButtonType.Circle,
            stateEffect: true,
            buttonStyle: ButtonStyleMode.TEXTUAL
          }) {
            SymbolGlyph($r('sys.symbol.trash'))
              .fontSize(18)
              .fontColor([$r('app.color.status_error')])
          }
            .width(32)
            .height(32)
            .padding(0)
            .backgroundColor(this.groupBackground())
            .borderWidth(0)
            .accessibilityText($r('app.string.transfer_discard_action'))
            .onClick(() => {
              this.confirmDiscardTaildropFile(file);
            })
        }
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 66 })
    .padding({ left: 12, right: 12, top: 7, bottom: 7 })
    .opacity(this.taildropSendActive() && !this.taildropReceiveMatches(file) ? 0.62 : 1)
  }

  @Builder
  private TaildropInboxPanel() {
    Column({ space: 0 }) {
      ForEach(this.taildropWaitingFiles, (file: TaildropWaitingFileSummary, index: number) => {
        if (index > 0) {
          Divider()
            .color($r('sys.color.comp_divider'))
            .margin({ left: 54 })
        }
        this.TaildropWaitingFileRow(file)
        if (this.taildropReceiveMatches(file) &&
          this.taildropReceive.state === 'awaiting_text_preview' &&
          this.taildropReceivedText.length > 0) {
          this.TaildropInlineTextPreview()
        }
      }, (file: TaildropWaitingFileSummary) => JSON.stringify(file))
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
  }

  @Builder
  private TaildropHistoryThumbnail(record: TaildropTransferRecord) {
    Stack({ alignContent: Alignment.Center }) {
      if (this.taildropHistoryPreviewUri(record).length > 0) {
        Image(this.taildropHistoryPreviewUri(record))
          .width(40)
          .height(40)
          .borderRadius(10)
          .objectFit(ImageFit.Cover)
      } else {
        SymbolGlyph(this.taildropFileSymbol(record.fileName))
          .fontSize(28)
          .fontColor([this.taildropFileIconColor(record.fileName)])
      }
    }
    .width(44)
    .height(44)
    .backgroundColor(this.secondaryBackground())
    .borderRadius(12)
  }

  private readTaildropTextPreview(result: TaildropReceiveResult): string | undefined {
    if (result.size > TAILDROP_TEXT_CLIPBOARD_MAX_BYTES || result.path.length === 0) {
      return undefined;
    }
    try {
      const stat: fileIo.Stat = fileIo.statSync(result.path);
      if (!stat.isFile() || stat.size !== result.size) {
        return undefined;
      }
      return fileIo.readTextSync(result.path);
    } catch (_error) {
      return undefined;
    }
  }

  private collapseTaildropTextPreview(): void {
    if (this.taildropReceive.state !== 'awaiting_text_preview') {
      return;
    }
    this.resetTaildropReceiveOperation();
  }

  private copyTaildropTextPreview(): void {
    if (this.taildropReceive.state !== 'awaiting_text_preview') {
      this.releaseTaildropNotificationActionClaim();
      return;
    }
    const staged: TaildropReceiveResult = this.taildropReceive;
    this.taildropReceive = {
      requestId: staged.requestId, action: 'stage', state: 'copying_text', reason: '',
      name: staged.name, size: staged.size, path: staged.path
    };
    this.taildropReceiveStateStartedAtMs = Date.now();
    this.taildropTextPreviewVisible = false;
    const data: pasteboard.PasteData = pasteboard.createData(
      pasteboard.MIMETYPE_TEXT_PLAIN, this.taildropReceivedText);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      if (!this.isCurrentTaildropReceive(staged.requestId, 'stage', 'copying_text')) {
        return;
      }
      if (this.taildropState === 'ready') {
        this.requestTaildropReceiveDelete(staged.requestId, staged.name, staged.size);
      } else {
        this.completeTaildropReceive(true);
      }
    }).catch(() => {
      if (!this.isCurrentTaildropReceive(staged.requestId, 'stage', 'copying_text')) {
        return;
      }
      this.taildropReceive = {
        requestId: staged.requestId, action: 'stage', state: 'awaiting_text_preview', reason: '',
        name: staged.name, size: staged.size, path: staged.path
      };
      this.taildropReceiveStateStartedAtMs = 0;
      this.taildropTextPreviewVisible = true;
      this.showToast($r('app.string.transfer_text_copy_failed'));
    });
  }

  private releaseTaildropNotificationActionClaim(): void {
    this.taildropReceiveGateway.releaseNotificationAction(this.taildropNotificationActionInFlight);
    this.taildropNotificationActionInFlight = undefined;
  }

  @Builder
  private TaildropHistoryRow(record: TaildropTransferRecord) {
    Row({ space: 12 }) {
      Stack() {
        this.TaildropHistoryThumbnail(record)
      }
      .width(44)
      .height(44)
      .borderRadius(10)
      .clip(true)
      Column({ space: 2 }) {
        Text(this.taildropTransferRecordTitle(record))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.taildropTransferRecordDescription(record))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Column({ space: 2 }) {
        Text(this.taildropTransferStatusText(record))
          .fontSize(11)
          .fontColor(this.taildropTransferStatusColor(record))
        if (record.direction === 'send' && record.state === 'failed') {
          Text($r('app.string.transfer_retry_action'))
            .fontSize(11)
            .fontColor($r('sys.color.icon_emphasize'))
        }
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .constraintSize({ minHeight: 66 })
    .padding({ left: 12, right: 12, top: 7, bottom: 7 })
    .onClick(() => this.retryTaildropSend(record))
  }

  @Builder
  private TaildropHistoryPanel() {
    Column({ space: 0 }) {
      ForEach(this.taildropHistory, (record: TaildropTransferRecord, index: number) => {
        if (index > 0) {
          Divider()
            .color($r('sys.color.comp_divider'))
            .margin({ left: 54 })
        }
        this.TaildropHistoryRow(record)
      }, (record: TaildropTransferRecord) => `${record.direction}-${record.requestId}`)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
  }

  @Builder
  private TransferEmptyPanel() {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.doc'))
        .fontSize(30)
        .fontColor([$r('sys.color.icon_secondary')])
      Text($r('app.string.transfer_empty_title'))
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
      Text($r('app.string.transfer_empty_description'))
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
        .textAlign(TextAlign.Center)
        .lineHeight(18)
        .constraintSize({ maxWidth: 360 })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 28, bottom: 28 })
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
  }

  @Builder
  private TaildropInlineTextPreview() {
    Column() {
      Scroll() {
        Text(this.taildropReceivedText)
          .fontSize(14)
          .fontColor($r('sys.color.font_primary'))
          .lineHeight(21)
          .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: 220 })
      .padding(12)
      .backgroundColor(this.secondaryBackground())
      .borderRadius(12)
    }
    .width('100%')
    .padding({ left: 56, right: 12, bottom: 12 })
    .transition(
      TransitionEffect.asymmetric(
        TransitionEffect.OPACITY.animation({ duration: 220, curve: Curve.EaseOut })
          .combine(TransitionEffect.translate({ y: -6 })),
        TransitionEffect.OPACITY.animation({ duration: 160, curve: Curve.EaseIn })
          .combine(TransitionEffect.translate({ y: -4 }))
      )
    )
  }

  @Builder
  private TaildropConnectionNotice() {
    Column({ space: 4 }) {
      Text($r('app.string.transfer_connect_first_title'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
      Text($r('app.string.transfer_connect_first_description'))
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
        .lineHeight(18)
        .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.groupBackground())
    .border({
      width: 1,
      color: $r('sys.color.comp_divider')
    })
    .borderRadius(16)
    .transition(
      TransitionEffect.asymmetric(
        TransitionEffect.OPACITY.animation({ duration: MotionTokens.NORMAL, curve: Curve.EaseOut })
          .combine(TransitionEffect.translate({ y: -8 })),
        TransitionEffect.OPACITY.animation({ duration: MotionTokens.FAST, curve: Curve.EaseIn })
          .combine(TransitionEffect.translate({ y: -6 }))
      )
    )
  }

  @Builder
  private TaildropTargetsSection() {
    Column({ space: 8 }) {
      Column({ space: 2 }) {
        Text($r('app.string.transfer_targets_title'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
        Text($r('app.string.transfer_targets_ready_title', this.taildropOnlineTargetCount()))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
      }
      .id('transfer-page-title')
      .width('100%')
      .padding({ left: 4, top: 8, bottom: 2 })
      if (this.displayedTaildropTargets().length > 0) {
        this.TaildropTargetsPanel()
      } else {
        this.TaildropTargetsEmptyPanel()
      }
    }
    .width('100%')
  }

  @Builder
  private TaildropActivitySections() {
    Column({ space: 14 }) {
      Column({ space: 8 }) {
        Row() {
          Text($r('app.string.transfer_inbox_title'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
          Blank()
          Text($r('app.string.transfer_clear_cache_action'))
            .fontSize(12)
            .fontColor($r('sys.color.icon_emphasize'))
            .opacity(!this.taildropSendActive() && !this.taildropReceiveInProgress ? 1 : 0.42)
            .onClick(() => {
              if (!this.taildropSendActive() && !this.taildropReceiveInProgress) {
                this.confirmClearTaildropInboxCache();
              }
            })
        }
        .width('100%')
        .padding({ left: 4, right: 4, top: 8, bottom: 2 })
        .alignItems(VerticalAlign.Center)
        if (this.taildropWaitingFiles.length > 0) {
          this.TaildropInboxPanel()
        } else {
          Text(this.taildropInboxReason.length > 0 ?
            $r('app.string.transfer_inbox_unavailable') : $r('app.string.transfer_inbox_empty'))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .textAlign(TextAlign.Center)
            .width('100%')
            .padding({ left: 20, right: 20, top: 18, bottom: 18 })
            .backgroundColor(this.groupBackground())
            .borderRadius(16)
        }
      }
      .width('100%')
      Column({ space: 8 }) {
        Row() {
          Text($r('app.string.transfer_history_title'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
          Blank()
          Text($r('app.string.transfer_clear_history_action'))
            .fontSize(12)
            .fontColor($r('sys.color.icon_emphasize'))
            .opacity(this.taildropHistory.length > 0 ? 1 : 0.45)
            .onClick(() => {
              if (this.taildropHistory.length > 0) {
                this.clearTaildropHistory();
              }
            })
        }
        .width('100%')
        .padding({ left: 4, right: 4, top: 8, bottom: 2 })
        .alignItems(VerticalAlign.Center)
        if (this.taildropHistory.length > 0) {
          this.TaildropHistoryPanel()
        } else {
          this.TransferEmptyPanel()
        }
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  private TransferContent() {
    Scroll(this.transferScroller) {
      Column({ space: 14 }) {
        if (!this.isConnected()) {
          this.TaildropConnectionNotice()
        }
        if (this.taildropPreparing || this.taildropTransfer.state === 'queued' ||
          this.taildropTransfer.state === 'sending') {
          this.TaildropActiveSendPanel()
        }
        if (this.isTransferSplitLayout()) {
          Row({ space: 18 }) {
            Column() {
              this.TaildropTargetsSection()
            }
              .layoutWeight(5)
            Column() {
              this.TaildropActivitySections()
            }
              .layoutWeight(7)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .id('transfer-split-layout')
        } else {
          Column({ space: 14 }) {
            this.TaildropTargetsSection()
            this.TaildropActivitySections()
          }
          .width('100%')
          .id('transfer-single-column')
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: ResponsiveLayout.EXPANDED_CONTENT_MAX_WIDTH })
      .padding({
        left: this.contentMargin(),
        right: this.contentMargin(),
        top: 0,
        bottom: this.pageBottomInset()
      })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Auto)
    .scrollBarWidth(4)
    .align(Alignment.TopStart)
  }

  @Builder
  private SettingsContent() {
    Scroll(this.settingsScroller) {
      Column() {
        GridRow({
          columns: { xs: 2, sm: 4, md: 8, lg: 12 },
          gutter: { x: 12, y: 5 }
        }) {
          GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
            Column({ space: 5 }) {
              this.SettingsGroupHeader($r('app.string.account_title'))
              this.AccountPanel()
            }
            .width('100%')
            .id('settings-account-section')
          }
          GridCol({ span: { xs: 2, sm: 4, md: this.isSettingsTwoColumnLayout() ? 4 : 8,
            lg: this.isSettingsTwoColumnLayout() ? 6 : 12 } }) {
            Column({ space: 5 }) {
              this.SettingsGroupHeader($r('app.string.settings_title'))
              this.NetworkSettingsPanel()
            }
            .width('100%')
            .id('settings-network-section')
          }
          GridCol({ span: { xs: 2, sm: 4, md: this.isSettingsTwoColumnLayout() ? 4 : 8,
            lg: this.isSettingsTwoColumnLayout() ? 6 : 12 } }) {
            Column({ space: 5 }) {
              this.SettingsGroupHeader($r('app.string.settings_appearance_title'))
              this.AppearanceSettingsPanel()
            }
            .width('100%')
            .id('settings-appearance-section')
          }
          GridCol({ span: { xs: 2, sm: 4, md: this.isSettingsTwoColumnLayout() ? 4 : 8,
            lg: this.isSettingsTwoColumnLayout() ? 6 : 12 } }) {
            Column({ space: 5 }) {
              this.SettingsGroupHeader($r('app.string.settings_storage_title'))
              this.CacheSettingsPanel()
            }
            .width('100%')
            .id('settings-storage-section')
          }
          GridCol({ span: { xs: 2, sm: 4, md: this.isSettingsTwoColumnLayout() ? 4 : 8,
            lg: this.isSettingsTwoColumnLayout() ? 6 : 12 } }) {
            Column({ space: 5 }) {
              this.SettingsGroupHeader($r('app.string.about_title'))
              this.VersionPanel()
            }
            .width('100%')
            .id('settings-about-section')
          }
          if (this.diagnosticsUnlocked) {
            GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
              Column() {
                this.DiagnosticsDisclosure()
              }
              .width('100%')
              .id('settings-diagnostics-section')
            }
          }
        }
        .width('100%')
        .constraintSize({ maxWidth: ResponsiveLayout.SETTINGS_CONTENT_MAX_WIDTH })
        .id(this.isSettingsTwoColumnLayout() ? 'settings-two-column' : 'settings-single-column')
      }
      .width('100%')
      .constraintSize({ maxWidth: ResponsiveLayout.SETTINGS_CONTENT_MAX_WIDTH + 64 })
      .padding({
        left: this.contentMargin(),
        right: this.contentMargin(),
        top: 24,
        bottom: this.pageBottomInset()
      })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Auto)
    .scrollBarWidth(4)
  }

  @Builder
  private HomeTitleTopInset() {
    Blank()
      .width('100%')
      .height(this.homeTitleCompact ? 12 : 0)
      .animation({ duration: MotionTokens.NORMAL, curve: Curve.EaseInOut })
  }

  @Builder
  private HomePage() {
    HdsNavigation() {
      this.HomeContent()
    }
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      padding: {
        start: LengthMetrics.vp(this.contentMargin()),
        end: LengthMetrics.vp(this.contentMargin())
      },
      style: {
        blurStrategy: BlurStrategy.ENABLE,
        thermoCtrl: true,
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR,
          blurEffectiveStartOffset: LengthMetrics.vp(0),
          blurEffectiveEndOffset: LengthMetrics.vp(20)
        },
        originalStyle: {
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            }
          }
        },
        scrollEffectStyle: {
          backgroundStyle: {
            backgroundColor: $r('sys.color.background_secondary'),
            blurRadius: 24,
            maskExtraHeight: 40.0
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            }
          }
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: this.glowMaterialLevel()
        }
      },
      content: {
        stackBuilder: (): void => this.HomeTitleTopInset(),
        title: {
          mainTitle: $r('app.string.app_title'),
          subTitle: this.homeTitleCompact ? '' : $r('app.string.app_tagline')
        }
      }
    })
    .titleMode(this.homeTitleCompact ? HdsNavigationTitleMode.MINI : HdsNavigationTitleMode.FULL)
    .bindToScrollable([this.homeScroller])
    .hideBackButton(true)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
    .id('hds-navigation-home')
    .backgroundColor($r('sys.color.background_secondary'))
  }

  @Builder
  private SettingsPage() {
    HdsNavigation() {
      this.SettingsContent()
    }
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      padding: {
        start: LengthMetrics.vp(this.contentMargin()),
        end: LengthMetrics.vp(this.contentMargin())
      },
      style: {
        blurStrategy: BlurStrategy.ENABLE,
        thermoCtrl: true,
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR,
          blurEffectiveStartOffset: LengthMetrics.vp(0),
          blurEffectiveEndOffset: LengthMetrics.vp(20)
        },
        originalStyle: {
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            }
          }
        },
        scrollEffectStyle: {
          backgroundStyle: {
            backgroundColor: $r('sys.color.background_secondary'),
            blurRadius: 24,
            maskExtraHeight: 40.0
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            }
          }
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: this.glowMaterialLevel()
        }
      },
      content: {
        title: {
          mainTitle: $r('app.string.tab_settings'),
          subTitle: $r('app.string.settings_subtitle')
        }
      }
    })
    .titleMode(HdsNavigationTitleMode.FULL)
    .bindToScrollable([this.settingsScroller])
    .hideBackButton(true)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
    .id('hds-navigation-settings')
    .backgroundColor($r('sys.color.background_secondary'))
  }

  @Builder
  private TransferPage() {
    HdsNavigation() {
      this.TransferContent()
    }
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      padding: {
        start: LengthMetrics.vp(this.contentMargin()),
        end: LengthMetrics.vp(this.contentMargin())
      },
      style: {
        blurStrategy: BlurStrategy.ENABLE,
        thermoCtrl: true,
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR,
          blurEffectiveStartOffset: LengthMetrics.vp(0),
          blurEffectiveEndOffset: LengthMetrics.vp(20)
        },
        originalStyle: {
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            }
          }
        },
        scrollEffectStyle: {
          backgroundStyle: {
            backgroundColor: $r('sys.color.background_secondary'),
            blurRadius: 24,
            maskExtraHeight: 40.0
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            }
          }
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: this.glowMaterialLevel()
        }
      },
      content: {
        title: {
          mainTitle: $r('app.string.tab_transfer'),
          subTitle: $r('app.string.transfer_subtitle')
        }
      }
    })
    .titleMode(HdsNavigationTitleMode.FREE)
    .bindToScrollable([this.transferScroller])
    .hideBackButton(true)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
    .id('hds-navigation-transfer')
    .backgroundColor($r('sys.color.background_secondary'))
  }

  @Builder
  private HomeTabBar() {
    Column({ space: 2 }) {
      Image($r('app.media.tab_home'))
        .width(24)
        .height(24)
        .fillColor(this.activeTab === 0 ? $r('sys.color.icon_emphasize') :
          $r('sys.color.icon_secondary'))
      Text($r('app.string.tab_home'))
        .fontSize(10)
        .fontColor(this.activeTab === 0 ? $r('sys.color.font_emphasize') :
          $r('sys.color.font_secondary'))
        .maxLines(1)
    }
    .id('tab-home')
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private TransferTabBar() {
    Column({ space: 2 }) {
      Image($r('app.media.tab_transfer'))
        .width(24)
        .height(24)
        .fillColor(this.activeTab === 1 ? $r('sys.color.icon_emphasize') :
          $r('sys.color.icon_secondary'))
      Text($r('app.string.tab_transfer'))
        .fontSize(10)
        .fontColor(this.activeTab === 1 ? $r('sys.color.font_emphasize') :
          $r('sys.color.font_secondary'))
        .maxLines(1)
    }
    .id('tab-transfer')
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private SettingsTabBar() {
    Column({ space: 2 }) {
      Image($r('app.media.tab_settings'))
        .width(24)
        .height(24)
        .fillColor(this.activeTab === 2 ? $r('sys.color.icon_emphasize') :
          $r('sys.color.icon_secondary'))
      Text($r('app.string.tab_settings'))
        .fontSize(10)
        .fontColor(this.activeTab === 2 ? $r('sys.color.font_emphasize') :
          $r('sys.color.font_secondary'))
        .maxLines(1)
    }
    .id('tab-settings')
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private MobileTabs() {
    HdsTabs({
      barPosition: BarPosition.End,
      index: this.currentTab,
      controller: this.tabsController
    }) {
      TabContent() {
        this.HomePage()
      }
      .tabBar(this.HomeTabBar())

      TabContent() {
        this.TransferPage()
      }
      .tabBar(this.TransferTabBar())

      TabContent() {
        this.SettingsPage()
      }
      .tabBar(this.SettingsTabBar())
    }
    .vertical(false)
    .scrollable(true)
    .animationDuration(MotionTokens.PAGE)
    .barMode(BarMode.Fixed)
    .barHeight(56)
    .barOverlap(true)
    .barBackgroundColor(Color.Transparent)
    .barFloatingStyle({
      barSideMargin: 16,
      barBottomMargin: 40,
      gradientMask: {
        maskColor: $r('sys.color.background_secondary'),
        maskHeight: 48
      },
      lightColor: this.glowLightColor(),
      barOpacity: 0.96,
      thermoCtrl: true,
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: this.glowMaterialLevel()
      }
    })
    .divider({ mode: DividerMode.NONE })
    .onSelected((index: number) => {
      this.activeTab = index;
      this.updateCacheSizePolling(index);
      // HdsTabs emits onSelected when the swipe transition starts and
      // onChange after it completes. Writing the controlled index here makes
      // the component jump straight to the destination and cancels the
      // interactive page animation.
    })
    .onChange((index: number) => {
      this.currentTab = index;
      this.activeTab = index;
      this.updateCacheSizePolling(index);
    })
    .width('100%')
    .height('100%')
  }

  private confirmResetFirstRun(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.diagnostic_reset_first_run_confirm_title'),
      message: $r('app.string.diagnostic_reset_first_run_confirm_message'),
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.cancel_action'),
        action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.diagnostic_reset_first_run_action'),
        fontColor: $r('app.color.status_error'),
        action: () => this.resetFirstRunState()
      }
    });
  }

  private async resetFirstRunState(): Promise<void> {
    if (this.diagnosticActionInProgress) {
      return;
    }
    this.diagnosticActionInProgress = true;
    this.diagnosticActionStatus = '';
    this.recordDiagnosticEvent('diagnostic_first_run_reset_requested', 'diagnostics');
    const requestGeneration: number = this.diagnosticActionRequestGuard.begin();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      try {
        await this.vpnCommandGateway.stopVpnExtension(this.vpnWant());
      } catch (_vpnError) {
        // A stopped extension is already in the desired state.
      }
      if (!this.diagnosticActionRequestGuard.isCurrent(requestGeneration)) {
        return;
      }
      try {
        await this.vpnCommandGateway.stopBackend();
      } catch (_backendError) {
        // Continue with cleanup when no in-process backend exists.
      }
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 300));
      if (!this.diagnosticActionRequestGuard.isCurrent(requestGeneration)) {
        return;
      }
      if (!this.settingsPreferencesGateway.resetControlServer(context)) {
        throw new Error('first-run reset failed');
      }
      if (!this.accountDiagnosticsGateway.clearWelcomeAcknowledgement(context)) {
        throw new Error('welcome acknowledgement reset failed');
      }
      const settings: ControlServerSettings = this.settingsPreferencesGateway.unconfiguredControlServer();
      this.controlServerURL = settings.controlURL;
      this.controlServerInput = settings.controlURL;
      this.controlServerConfirmed = settings.confirmed;
      this.controlServerStatus = '';
      this.controlServerEditorVisible = true;
      this.backendStatus = 'Tailscale Backend Stopped | control server not configured';
      this.vpnStatus = 'HarmonyOS VPN Extension stopped';
      this.backendReady = true;
      this.backendInitializationVisible = false;
      this.devicesLoading = false;
      this.hasAuthenticatedSession = false;
      this.loginInProgress = false;
      this.loginPrompt = '';
      this.loginHandoffStatus = 'Secure Login Pending';
      this.applyPeers([]);
      this.exitNodes = [];
      this.applyAccountSummary({
        displayName: '', loginName: '', profilePicURL: '', tailnetName: '', deviceName: '', addresses: [],
        needsApproval: false, keyExpired: false, keyExpiryUnixMs: 0
      });
      this.diagnosticActionStatus = context.resourceManager.getStringSync(
        $r('app.string.diagnostic_reset_first_run_completed').id);
      this.recordDiagnosticEvent('diagnostic_first_run_reset_completed', 'diagnostics');
      this.navigateToTab(0);
      this.scheduleLifecycleTask(() => this.showWelcomeDialogIfNeeded(), 350);
      this.scheduleLifecycleTask(() => this.showControlServerTip(), 700);
    } catch (_error) {
      if (!this.diagnosticActionRequestGuard.isCurrent(requestGeneration)) {
        return;
      }
      this.diagnosticActionStatus = context.resourceManager.getStringSync(
        $r('app.string.diagnostic_reset_first_run_failed').id);
      this.recordDiagnosticEvent('diagnostic_first_run_reset_failed', 'diagnostics');
    } finally {
      if (this.diagnosticActionRequestGuard.isCurrent(requestGeneration)) {
        this.diagnosticActionInProgress = false;
      }
    }
  }

  private async forceStopSystemVpn(): Promise<void> {
    if (this.diagnosticActionInProgress) {
      return;
    }
    this.diagnosticActionInProgress = true;
    this.diagnosticActionStatus = '';
    this.recordDiagnosticEvent('diagnostic_vpn_cut_requested', 'diagnostics');
    const requestGeneration: number = this.diagnosticActionRequestGuard.begin();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      await this.vpnCommandGateway.stopVpnExtension(this.vpnWant());
      if (!this.diagnosticActionRequestGuard.isCurrent(requestGeneration)) {
        return;
      }
      this.stopConnectionPolling();
      this.clearConnectionCompletionTimer();
      this.connectInProgress = false;
      this.disconnectInProgress = false;
      this.vpnStatus = 'HarmonyOS VPN Extension stopped manually';
      this.diagnosticActionStatus = context.resourceManager.getStringSync(
        $r('app.string.diagnostic_force_vpn_stop_completed').id);
      this.recordDiagnosticEvent('diagnostic_vpn_cut_completed', 'diagnostics');
      if (this.controlServerConfirmed) {
        this.scheduleLifecycleTask(() => {
          this.startBackend(false);
          this.scheduleLifecycleTask(() => this.refreshBackendStatus(), 1500);
        }, 500);
      }
    } catch (error) {
      if (!this.diagnosticActionRequestGuard.isCurrent(requestGeneration)) {
        return;
      }
      const businessError = error as BusinessError;
      this.diagnosticActionStatus = context.resourceManager.getStringSync(
        $r('app.string.diagnostic_force_vpn_stop_failed').id);
      this.recordDiagnosticEvent('diagnostic_vpn_cut_failed', 'diagnostics', businessError.code ?? -1);
    } finally {
      if (this.diagnosticActionRequestGuard.isCurrent(requestGeneration)) {
        this.diagnosticActionInProgress = false;
      }
    }
  }

  private confirmSimulateAppCrash(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.diagnostic_simulate_crash_confirm_title'),
      message: $r('app.string.diagnostic_simulate_crash_confirm_message'),
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.cancel_action'),
        action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.diagnostic_simulate_crash_action'),
        fontColor: $r('app.color.status_error'),
        action: () => this.simulateAppCrash()
      }
    });
  }

  private async simulateAppCrash(): Promise<void> {
    if (this.diagnosticActionInProgress) {
      return;
    }
    this.diagnosticActionInProgress = true;
    this.diagnosticActionStatus = '';
    this.recordDiagnosticEvent('diagnostic_crash_simulation_requested', 'diagnostics');
    const requestGeneration: number = this.diagnosticActionRequestGuard.begin();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      await this.vpnCommandGateway.stopVpnExtension(this.vpnWant());
      if (!this.diagnosticActionRequestGuard.isCurrent(requestGeneration)) {
        return;
      }
      this.stopConnectionPolling();
      this.clearConnectionCompletionTimer();
      const staleStatus: string =
        'OK | state=Running | loginURLReady=false | tailscaleIPs=1 | tun=true | ' +
        'tunRead=1 | tunWrite=1 | tunReadErrors=0 | tunWriteErrors=0 | ' +
        `phase=diagnostic-crash-simulation | heartbeatMs=${Date.now()}`;
      if (!this.accountDiagnosticsGateway.stageCrashProbeStatus(context, staleStatus)) {
        throw new Error('could not stage stale VPN status');
      }
      this.recordDiagnosticEvent('diagnostic_crash_simulation_staged', 'abort');
      this.accountDiagnosticsGateway.abortProcessAfter(120);
    } catch (_error) {
      if (!this.diagnosticActionRequestGuard.isCurrent(requestGeneration)) {
        return;
      }
      this.diagnosticActionStatus = context.resourceManager.getStringSync(
        $r('app.string.diagnostic_simulate_crash_failed').id);
      this.recordDiagnosticEvent('diagnostic_crash_simulation_failed', 'diagnostics');
      if (this.diagnosticActionRequestGuard.isCurrent(requestGeneration)) {
        this.diagnosticActionInProgress = false;
      }
    }
  }

  @Builder
  private WideTabs() {
    HdsTabs({
      barPosition: BarPosition.Start,
      index: this.currentTab,
      controller: this.tabsController
    }) {
      TabContent() {
        this.HomePage()
      }
      .tabBar(new BottomTabBarStyle($r('app.media.tab_home'), $r('app.string.tab_home'))
        .id('tab-home')
        .labelStyle({
          unselectedColor: $r('sys.color.font_secondary'),
          selectedColor: $r('sys.color.font_emphasize')
        })
        .iconStyle({
          unselectedColor: $r('sys.color.icon_secondary'),
          selectedColor: $r('sys.color.icon_emphasize')
        }))

      TabContent() {
        this.TransferPage()
      }
      .tabBar(new BottomTabBarStyle($r('app.media.tab_transfer'), $r('app.string.tab_transfer'))
        .id('tab-transfer')
        .labelStyle({
          unselectedColor: $r('sys.color.font_secondary'),
          selectedColor: $r('sys.color.font_emphasize')
        })
        .iconStyle({
          unselectedColor: $r('sys.color.icon_secondary'),
          selectedColor: $r('sys.color.icon_emphasize')
        }))

      TabContent() {
        this.SettingsPage()
      }
      .tabBar(new BottomTabBarStyle($r('app.media.tab_settings'), $r('app.string.tab_settings'))
        .id('tab-settings')
        .labelStyle({
          unselectedColor: $r('sys.color.font_secondary'),
          selectedColor: $r('sys.color.font_emphasize')
        })
        .iconStyle({
          unselectedColor: $r('sys.color.icon_secondary'),
          selectedColor: $r('sys.color.icon_emphasize')
        }))
    }
    .vertical(true)
    .scrollable(false)
    .animationDuration(MotionTokens.PAGE)
    .barMode(BarMode.Fixed)
    .barWidth(96)
    .barOverlap(false)
    .barBackgroundColor($r('sys.color.comp_background_primary'))
    .divider({ mode: DividerMode.NONE })
    .onChange((index: number) => {
      this.currentTab = index;
      this.activeTab = index;
      this.updateCacheSizePolling(index);
    })
    .width('100%')
    .height('100%')
  }

  build() {
    Stack() {
      Column() {
        this.MobileTabs()
      }
      .width('100%')
      .height('100%')
      .transition(TransitionEffect.OPACITY.animation({ duration: MotionTokens.FAST, curve: Curve.EaseOut }))
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
    .id('shell-hds-navigation-safe-area')
    .onAreaChange((_oldValue: Area, newValue: Area) => this.updateLayoutMetrics(newValue))
    .bindSheet($$this.connectionDetailsVisible, this.ConnectionDetailsContent(), {
      height: '68%',
      detents: ['68%', SheetSize.LARGE],
      preferType: SheetType.BOTTOM,
      scrollSizeMode: ScrollSizeMode.CONTINUOUS,
      dragBar: true,
      showClose: true,
      title: { title: '连接详情' }
    })
  }
}
