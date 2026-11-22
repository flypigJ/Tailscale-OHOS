import { BackgroundRunningSettings } from './BackgroundRunningSettings';
import { FeedbackEmailGateway } from '../services/FeedbackEmailGateway';
import { FeedbackEmailTemplate } from '../services/FeedbackEmailTemplate';
import { AccountProfiles, AccountProfile, ServerAccountProfiles } from '../services/AccountProfiles';
import { CrashDiagnosticService } from '../services/CrashDiagnosticService';
import { TailnetDnsPreferences } from '../services/TailnetDnsPreferences';
import { DnsSettings, DnsSettingsStore } from '../services/DnsSettings';
import { PathDiagnosticService } from '../services/PathDiagnosticService';
import { LatestTaskPool } from '../services/LatestTaskPool';
import { StorageUsage, StorageUsageScanner } from '../services/StorageUsageScanner';
import { BackgroundImageStore } from '../services/BackgroundImageStore';
import {
  AppColorMode, DEFAULT_PERSONALIZATION_SETTINGS, PersonalizationPreferences
} from '../services/PersonalizationPreferences';
import { bundleManager, common, CompletionHandlerForAbilityStartCallback, Want } from '@kit.AbilityKit';
import { BusinessError, deviceInfo, pasteboard } from '@kit.BasicServicesKit';
import { LengthMetrics, window } from '@kit.ArkUI';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  DiagnosticReportInput,
  DiagnosticReportResult,
  DiagnosticReportService
} from '../services/DiagnosticReportService';
import {
  AccountDiagnosticsGateway,
  AccountDiagnosticsRequestGuard,
  NativeBridgeDiagnosticStatus
} from '../services/AccountDiagnosticsGateway';
import { DeviceNameService } from '../services/DeviceNameService';
import { NetworkSettingKey } from '../services/NetworkSettingsGateway';
import { SharedFileDraft, SystemShareInbox } from '../services/SystemShareInbox';
import {
  FileTransferPreferences,
  FileTransferTransport,
  LocalSendPortOverride
} from '../services/FileTransferPreferences';
import { TaildriveBrowser } from './TaildriveBrowser';
import { TaildrivePreviewGateway } from '../services/TaildrivePreviewGateway';
import { createLocalTextPasteData } from '../services/AppShellIntentAdapter';
import BuildProfile from 'BuildProfile';
import { TaildropReceiveResult } from '../services/TaildropReceiveGateway';
import { APP_BACKGROUND_EVENT, APP_FOREGROUND_EVENT } from '../services/AppLifecycleEvents';
import { PeerPathResult } from '../services/StreamingModels';
import { DiscoveredMediaService } from '../services/MediaIntegrationModels';
import {
  DeviceMediaState,
  DeviceStreamingState,
  MediaSelfTestStatusKind,
  PeerIntegrationController,
  PeerIntegrationHost,
  PeerIntegrationToastKey,
  RemoteStreamLaunchIntent,
  formatPeerDisplayName,
  isPeerSunshineCandidate,
  selectPrimaryTailscaleAddress
} from '../services/PeerIntegrationController';
import {
  TaildropCachedFile,
  TaildropMediaPreview,
  TaildropSessionController,
  TaildropSessionHost,
  TaildropToastKey,
  emptyTaildropReceive,
  formatTaildropRecordDescription,
  formatTaildropRecordTitle,
  formatTaildropTransferDuration,
  sanitizeTaildropDisplayText
} from '../services/TaildropSessionController';
import {
  VpnLoginPromptKind,
  VpnSessionController,
  VpnSessionHost,
  VpnTrafficSample,
  sanitizeVpnDiagnosticCount,
  sanitizeVpnDiagnosticToken
} from '../services/VpnSessionController';
import { DeviceConnectionInfoPanel } from './DeviceConnectionInfoPanel';
import { DeviceActionButtons } from './DeviceActionButtons';
import { CompactConnectedHomeHeader } from './CompactConnectedHomeHeader';
import { ConnectionDetailsSheet } from './ConnectionDetailsSheet';
import { MotionTokens } from './MotionTokens';
import { UiTokens } from './UiTokens';
import { LightAppearance } from './LightAppearance';
import { DeviceDetailSheet } from './DeviceDetailSheet';
import { NativeSettingsNavigation } from './NativeSettingsNavigation';
import { AccountTextField } from './AccountTextField';
import { ControlServerPresets, ControlServerPreset, ControlServerPresetCatalog } from '../services/ControlServerPresets';
import { FeatureSetupGuide, FeatureSetupDialog } from './FeatureSetupGuide';
import { transferGuideNotice } from '../services/FeatureGuideEntryRules';
import { UpdateChangelogEntry, UpdateChangelogSheet } from './UpdateChangelogSheet';
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
  HdsNavDestination,
  HdsNavDestinationAttribute,
  HdsNavDestinationTitleMode,
  HdsNavigation,
  HdsNavigationAttribute,
  HdsNavigationTitleBarOptions,
  HdsNavigationTitleMode,
  HdsTabs,
  HdsTabsAttribute,
  HdsTabsController,
  ScrollEffectType,
  hdsMaterial
} from '@kit.UIDesignKit';
import {
  ControlServerSettings,
  DEFAULT_CONTROL_SERVER_URL
} from '../services/ControlServerConfig';
import {
  AppearanceOverlaySettings,
  SettingsPreferencesGateway,
  SettingsRequestGuard
} from '../services/SettingsPreferencesGateway';
import { DiagnosticPrivacy } from '../services/DiagnosticPrivacy';
import {
  ReleaseChangelogDefinition,
  RELEASE_CHANGELOG_ENTRIES
} from '../services/ReleaseChangelog';
import {
  DEFAULT_NAVIGATION_BOTTOM_MARGIN,
  DEFAULT_NAVIGATION_HIDDEN,
  DEFAULT_NAVIGATION_ORDER,
  NavigationPreferences,
  NavigationSettings,
  NavigationTabId
} from '../services/NavigationPreferences';
import {
  AnimationPreferences,
  AnimationSettings,
  DEFAULT_ANIMATION_SETTINGS
} from '../services/AnimationPreferences';
import { AppSecurityPreferences, AppSecuritySettings } from '../services/AppSecurityPreferences';
import { AppSecurityAuthenticator } from '../services/AppSecurityAuthenticator';
import { resolveFileIconColorResource, resolveFileIconResource } from '../services/FileIconResolver';
import {
  AccountSummary,
  ExitNodeChoice,
  LocalSendStatus,
  MeshArcReceiverStatus,
  NetworkSettings,
  PeerSummary,
  TAILDROP_HISTORY_MEDIA_DIR_NAME,
  TAILDROP_INBOX_DIR_NAME,
  TaildropSnapshot,
  TaildropTargetSummary,
  TaildropTransferRecord,
  TaildropTransferSummary,
  TaildropWaitingFileSummary,
  emptyMeshArcReceiverStatus,
  emptyTaildropTransfer
} from '@tailscale/common';

interface SettingsCategoryRowData {
  icon: Resource;
  title: ResourceStr;
  summary: ResourceStr;
  rowId: string;
  action: () => void;
}

interface StorageLegendRowData {
  title: ResourceStr;
  bytes: number;
  color: ResourceColor;
}

interface StorageCleanupButtonData {
  title: ResourceStr;
  description: ResourceStr;
  rowId: string;
  enabled: boolean;
  onClick: () => void;
}

const FEATURE_DIAGNOSTIC_LOG_DOMAIN: number = 0x0000;
const FEATURE_DIAGNOSTIC_LOG_TAG: string = 'FeatureDiagnostics';
const CACHE_SIZE_POLL_INTERVAL_MS: number = 30000;
const FAST_REFRESH_INTERVAL_MS: number = 2000;
const OFFLINE_PEER_STATUS_REFRESH_INTERVAL_MS: number = 10000;
const NORMAL_SERVICE_REFRESH_INTERVAL_MS: number = 30000;
const STATUS_CROSS_FADE_MS: number = 180;
const DEFAULT_APP_VERSION_NAME: string = '0.9.10';
const DEFAULT_APP_VERSION_CODE: number = 99000003;
const FEEDBACK_EMAIL: string = 'flypigj@gmail.com';

interface FileTransferCapabilities {
  tailsend: boolean;
  localSend: boolean;
}

type TrafficSample = VpnTrafficSample;

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
  @State appVersion: string = DEFAULT_APP_VERSION_NAME;
  @State appVersionCode: number = DEFAULT_APP_VERSION_CODE;
  @State tailscaleVersion: string = '—';
  @State exitNodeStatus: ResourceStr = $r('app.string.exit_node_status_none');
  @State logoutStatus: string = '';
  @State diagnosticsUnlocked: boolean = false;
  @State diagnosticsExpanded: boolean = false;
  @State diagnosticReportStatus: string = '';
  @State diagnosticReportInProgress: boolean = false;
  @State standaloneDiagnosticsVisible: boolean = false;
  @State tailnetDnsEnabled: boolean = true;
  @State dnsSettingsEnabled: boolean = false;
  @State dnsPrimaryInput: string = '';
  @State dnsSecondaryInput: string = '';
  @State dnsSearchDomainsInput: string = '';
  @State dnsSettingsStatus: string = '';
  @State crashCaptureEnabled: boolean = false;
  @State pathDiagnosticBusy: boolean = false;
  @State pathDiagnosticStatus: string = '';
  @State diagnosticQuickTransferEnabled: boolean = true;
  @State diagnosticServiceMonitoringEnabled: boolean = true;
  @State diagnosticSecurityEnabled: boolean = true;
  @State diagnosticAppearanceEnabled: boolean = true;
  @State diagnosticDeviceListVerificationEnabled: boolean = false;
  @State diagnosticDeviceListLastClicked: string = '';
  @State diagnosticFeatureRefreshInProgress: boolean = false;
  @State diagnosticFeatureRefreshStatus: string = '';
  @State diagnosticSecuritySelfTestInProgress: boolean = false;
  @State diagnosticSecuritySelfTestStatus: string = '';
  @State diagnosticServiceLastRefreshMs: number = 0;
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
  @State meshArcReceiver: MeshArcReceiverStatus = emptyMeshArcReceiverStatus();
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
  @State taildropReceivedText: string = '';
  @State taildropTransferRate: number = 0;
  @State taildropTransferEtaSeconds: number = 0;
  @State taildropCancelPending: boolean = false;
  @State taildropFocusedTargetKey: string = '';
  @State taildropPendingFocusTargetKey: string = '';
  @State fileTransferMethodVisible: boolean = false;
  @State fileTransferMethodPeerKey: string = '';
  @State mediaMethodVisible: boolean = false;
  @State mediaMethodPeerKey: string = '';
  @State transferProtocolRefreshing: boolean = false;
  @State deviceDetailServiceRefreshInFlight: boolean = false;
  @State localSendPortOverrides: LocalSendPortOverride[] = [];
  @State remotePortEditorVisible: boolean = false;
  @State remotePortPeerKey: string = '';
  @State remotePortInput: string = '';
  @State loginInProgress: boolean = false;
  @State @Watch('onSecurityPrivacyStateChanged') authKeyLoginVisible: boolean = false;
  @State authKeyInput: string = '';
  @State authKeyStatus: string = '';
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
  @State private backgroundRunningHighlighted: boolean = false;
  private backgroundRunningReveal: number = 0;
  @State navigationOrder: NavigationTabId[] = [...DEFAULT_NAVIGATION_ORDER];
  @State hiddenNavigationTabs: NavigationTabId[] = [...DEFAULT_NAVIGATION_HIDDEN];
  @State navigationBottomMargin: number = DEFAULT_NAVIGATION_BOTTOM_MARGIN;
  @State navigationDraggingId: string = '';
  @State activeNavigationId: NavigationTabId = 'home';
  @State private filesPageActivated: boolean = false;
  private navigationRevision: number = 0;
  @State meshSendPreferredTransport: string = '';
  @StorageLink('taildropOpenInbox') @Watch('onTaildropOpenInbox') taildropOpenInbox: number = 0;
  @StorageLink('systemShareRevision') @Watch('onSystemShare') systemShareRevision: number = 0;
  @StorageLink('systemShareError') @Watch('onSystemShareError') systemShareError: number = 0;
  @State private sharedFileCount: number = 0;
  @State private sharedFileSummary: string = '';
  @State private sharedFileSending: boolean = false;
  @StorageLink('taildropNotificationAction') @Watch('onTaildropNotificationAction')
  taildropNotificationAction: string = '';
  @State accountProfileId: string = 'default';
  @State accountProfiles: AccountProfile[] = [];
  @State accountProfileStatus: string = '';
  @State controlServerURL: string = DEFAULT_CONTROL_SERVER_URL;
  @State controlServerInput: string = DEFAULT_CONTROL_SERVER_URL;
  @State controlServerConfirmed: boolean = false;
  @State controlServerStatus: string = '';
  @State controlServerEditorVisible: boolean = true;
  @State controlServerPresets: ControlServerPreset[] = [];
  @State controlServerSwitching: boolean = false;
  @State controlServerTipMessage: string = '';
  @State diagnosticActionStatus: string = '';
  @State diagnosticActionInProgress: boolean = false;
  @State glowLevel: number = 3;
  @State animationPreset: number = DEFAULT_ANIMATION_SETTINGS.preset;
  @State animationDuration: number = DEFAULT_ANIMATION_SETTINGS.duration;
  @State animationAmplitude: number = DEFAULT_ANIMATION_SETTINGS.amplitude;
  @State animationDamping: number = DEFAULT_ANIMATION_SETTINGS.damping;
  @State contextGuideVisible: boolean = false;
  @State contextGuideSection: string = '';
  @State contextGuidePresentation: number = 0;
  private contextGuideController?: CustomDialogController;
  @State nativeSettingsVisible: boolean = false;
  @State connectionButtonPressed: boolean = false;
  @State nativeSettingsPage: string = 'background';
  @State settingsDetailActive: boolean = false;
  @State @Watch('onSecurityPrivacyStateChanged') appLockEnabled: boolean = false;
  @State @Watch('onSecurityPrivacyStateChanged') folderLockEnabled: boolean = false;
  @State @Watch('onSecurityPrivacyStateChanged') securityPreferencesReady: boolean = false;
  @StorageLink('taildriveLockedFolderPaths') @Watch('onSecurityPrivacyStateChanged') lockedFolderPaths: string[] = [];
  @State @Watch('onAppLockRequiredChanged') appLockRequired: boolean = false;
  @State appLockAuthenticating: boolean = false;
  @State securitySettingsAuthenticating: boolean = false;
  @State appLockMessage: string = '';
  private windowPrivacySyncSeq: number = 0;
  @State nativeSettingsBackgroundUri: string = '';
  @State backgroundUnavailable: boolean = false;
  @State personalizationColorMode: AppColorMode = DEFAULT_PERSONALIZATION_SETTINGS.colorMode;
  @State backgroundBrightnessValue: number = DEFAULT_PERSONALIZATION_SETTINGS.backgroundBrightness;
  private backgroundSelectionGeneration: number = 0;
  private personalizationSaveTimer: number = -1;
  private personalizationSavePending: boolean = false;
  private navigationSaveQueue: Promise<void> = Promise.resolve();
  private navigationMarginSaveTimer: number = -1;
  @State immersiveColorBackgroundEnabled: boolean = false;
  @State nativeSettingsBackgroundPickerInProgress: boolean = false;
  @State storageUsageReady: boolean = false;
  @State storageScanFailed: boolean = false;
  @State storageRingProgress: number = 0;
  private storageRingPageShown: boolean = false;
  private storageRingAnimationStarted: boolean = false;
  private storageRingGeneration: number = 0;
  @State nativeStorageAppDataBytes: number = 0;
  @State nativeStorageReceivedBytes: number = 0;
  @State nativeStorageTemporaryBytes: number = 0;
  @State connectedHomeLayoutMode: ConnectedHomeLayoutMode = DEFAULT_CONNECTED_HOME_LAYOUT;
  @State cacheSizeBytes: number = 0;
  @State cacheSizeLoading: boolean = true;
  @State cacheClearInProgress: boolean = false;
  @State private taildropPreviewCachePresent: boolean = false;
  @State private missingTaildropPreviewPaths: string[] = [];
  @State @Watch('onConnectionDetailsVisibilityChanged') connectionDetailsVisible: boolean = false;
  @State deviceDetailVisible: boolean = false;
  @State updateChangelogVisible: boolean = false;
  @StorageLink('updateChangelogAction') @Watch('onUpdateChangelogActionRequested') updateChangelogAction: string = '';
  @State homeTitleCompact: boolean = false;
  @State layoutWidth: number = 360;
  @State layoutHeight: number = 640;
  @State selectedPeerKey: string = '';
  @State selectedPeerDetails: PeerSummary[] = [];
  // Keep the sheet title independent from the detail content collection. The
  // native bindSheet title can be created before a ForEach-backed array is
  // populated, leaving the title slot blank even while the body is present.
  @State selectedPeerTitleName: string = '';
  @State selectedPeerTitleDeviceType: string = '';
  @State selectedPeerTitleSystem: string = '';
  @State selectedPeerTitleOnline: boolean = false;
  @State expandedPeerKeys: string[] = [];
  @State taildriveTargetMachineName: string = '';
  @State taildriveTargetRequestId: number = 0;
  private remoteFilesNavigationRequestId: number = 0;
  private connectionDurationTimer: number = -1;
  @State connectionDurationNowMs: number = 0;
  private backendRestartDeferred: boolean = false;
  private serviceRefreshTimer: number = -1;
  private serviceRefreshInFlight: boolean = false;
  private homeLatencyRefreshTimer: number = -1;
  private offlinePeerStatusRefreshTimer: number = -1;
  private deviceDetailRefreshTimer: number = -1;
  private transferProtocolRefreshTimer: number = -1;
  private homeScroller: Scroller = new Scroller();
  private transferScroller: Scroller = new Scroller();
  private filesScroller: Scroller = new Scroller();
  private transferScrollAnchorY: number = 0;
  private transferScrollRestoreTimer: number = -1;
  private settingsScroller: Scroller = new Scroller();
  private settingsAccountDetailScroller: Scroller = new Scroller();
  private settingsNetworkDetailScroller: Scroller = new Scroller();
  private settingsBackgroundRunningDetailScroller: Scroller = new Scroller();
  private settingsAppearanceDetailScroller: Scroller = new Scroller();
  private settingsStorageDetailScroller: Scroller = new Scroller();
  private settingsAboutDetailScroller: Scroller = new Scroller();
  private featureGuideScroller: Scroller = new Scroller();
  private settingsSecurityDetailScroller: Scroller = new Scroller();
  private settingsPathStack: NavPathStack = new NavPathStack();
  private settingsNavigationLockUntilMs: number = 0;
  private animationPreferencesSaveTimer: number = -1;
  private pendingAnimationSettings?: AnimationSettings;
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
  private remoteStreamAppInForeground: boolean = true;
  private deviceDetailPresentationId: number = 0;
  private externalTabNavigationTimer: number = -1;
  private tabChangeRequestId: number = 0;
  private pendingExternalTabIndex: number = -1;
  private cacheRefreshScheduled: boolean = false;
  private cacheSizeRefreshInFlight: boolean = false;
  private cacheSizeRefreshPending: boolean = false;
  private readonly storageScanPool: LatestTaskPool<number> = new LatestTaskPool<number>(1);
  private cacheSizePollTimer: number = -1;
  private settingsPreferencesGateway: SettingsPreferencesGateway = new SettingsPreferencesGateway();
  private settingsRequestGuard: SettingsRequestGuard = new SettingsRequestGuard();
  private accountDiagnosticsGateway: AccountDiagnosticsGateway = new AccountDiagnosticsGateway();
  private accountRequestGuard: AccountDiagnosticsRequestGuard =
    new AccountDiagnosticsRequestGuard();
  private diagnosticProbeRequestGuard: AccountDiagnosticsRequestGuard =
    new AccountDiagnosticsRequestGuard();
  private pathDiagnosticRequestGuard: AccountDiagnosticsRequestGuard = new AccountDiagnosticsRequestGuard();
  private diagnosticReportRequestGuard: AccountDiagnosticsRequestGuard =
    new AccountDiagnosticsRequestGuard();
  private diagnosticActionRequestGuard: AccountDiagnosticsRequestGuard =
    new AccountDiagnosticsRequestGuard();
  private logoutInProgress: boolean = false;
  private vpnConflictDialogVisible: boolean = false;
  private welcomeDialogVisible: boolean = false;
  private appVersionMetadataReady: boolean = false;
  private updateChangelogShowPending: boolean = false;
  private featureServiceLogSignature: string = '';
  private taildropPickerOpen: boolean = false;
  private peerDataSource: PeerDataSource = new PeerDataSource();
  private appForegroundListener: () => void = () => this.handleAppForeground();
  private appBackgroundListener: () => void = () => this.handleAppBackground();

  private abilityContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private readonly vpnSessionHost: VpnSessionHost = {
    getFilesDir: (): string => this.abilityContext().filesDir,
    getCacheDir: (): string => this.abilityContext().cacheDir,
    getLifecycleGeneration: (): number => this.lifecycleGeneration,
    isAppShellReady: (): boolean => this.appShellReady,
    isAppLockRequired: (): boolean => this.appLockRequired,
    isLogoutInProgress: (): boolean => this.logoutInProgress,
    isDiagnosticActionInProgress: (): boolean => this.diagnosticActionInProgress,
    isCacheClearInProgress: (): boolean => this.cacheClearInProgress,
    isTaildropSendActive: (): boolean => this.taildropSendActive(),
    isTaildropReceiveInProgress: (): boolean => this.taildropReceiveInProgress,
    isTaildropMediaSaveInProgress: (): boolean => this.taildropMediaSaveInProgress,
    shouldPollHealthFast: (): boolean => this.taildropSessionController.shouldPollHealthFast(),
    getBackendStatus: (): string => this.backendStatus,
    setBackendStatus: (status: string): void => { this.backendStatus = status; },
    getVpnStatus: (): string => this.vpnStatus,
    setVpnStatus: (status: string): void => { this.vpnStatus = status; },
    isBackendReady: (): boolean => this.backendReady,
    setBackendReady: (ready: boolean): void => { this.backendReady = ready; },
    isBackendInitializationVisible: (): boolean => this.backendInitializationVisible,
    setBackendInitializationVisible: (visible: boolean): void => { this.backendInitializationVisible = visible; },
    setDevicesLoading: (loading: boolean): void => { this.devicesLoading = loading; },
    hasAuthenticatedSession: (): boolean => this.hasAuthenticatedSession,
    setHasAuthenticatedSession: (authenticated: boolean): void => { this.hasAuthenticatedSession = authenticated; },
    isConnectInProgress: (): boolean => this.connectInProgress,
    setConnectInProgressState: (inProgress: boolean): void => { this.connectInProgress = inProgress; },
    isDisconnectInProgress: (): boolean => this.disconnectInProgress,
    setDisconnectInProgress: (inProgress: boolean): void => { this.disconnectInProgress = inProgress; },
    isLoginInProgress: (): boolean => this.loginInProgress,
    setLoginInProgress: (inProgress: boolean): void => { this.loginInProgress = inProgress; },
    getLoginHandoffStatus: (): string => this.loginHandoffStatus,
    setLoginHandoffStatus: (status: string): void => { this.loginHandoffStatus = status; },
    setLoginPromptKind: (kind: VpnLoginPromptKind): void => { this.applyLoginPromptKind(kind); },
    isAuthKeyLoginVisible: (): boolean => this.authKeyLoginVisible,
    setAuthKeyLoginVisible: (visible: boolean): void => { this.authKeyLoginVisible = visible; },
    getAuthKeyInput: (): string => this.authKeyInput,
    setAuthKeyInput: (input: string): void => { this.authKeyInput = input; },
    getAuthKeyStatus: (): string => this.authKeyStatus,
    setAuthKeyStatus: (status: string): void => { this.authKeyStatus = status; },
    isControlServerConfirmed: (): boolean => this.controlServerConfirmed,
    setControlServerConfirmed: (confirmed: boolean): void => { this.controlServerConfirmed = confirmed; },
    getControlServerURL: (): string => this.controlServerURL,
    setControlServerURL: (url: string): void => { this.controlServerURL = url; },
    setControlServerInput: (input: string): void => { this.controlServerInput = input; },
    setControlServerStatus: (status: string): void => { this.controlServerStatus = status; },
    setControlServerEditorVisible: (visible: boolean): void => { this.controlServerEditorVisible = visible; },
    setControlServerPresets: (presets: ControlServerPreset[]): void => { this.controlServerPresets = presets; },
    isControlServerSwitching: (): boolean => this.controlServerSwitching,
    setControlServerSwitching: (switching: boolean): void => { this.controlServerSwitching = switching; },
    getAccountProfileId: (): string => this.accountProfileId,
    setAccountProfileId: (id: string): void => { this.accountProfileId = id; },
    getAccountProfiles: (): AccountProfile[] => this.accountProfiles,
    setAccountProfiles: (profiles: AccountProfile[]): void => { this.accountProfiles = profiles; },
    setAccountProfileStatus: (status: string): void => { this.accountProfileStatus = status; },
    getPeers: (): PeerSummary[] => this.peers,
    onPeersUpdated: (mergedPeers: PeerSummary[]): void => { this.applyMergedPeersToShell(mergedPeers); },
    onPeerPresenceInvalidated: (peerKey: string): void => {
      this.peerIntegrationController.invalidatePeerPresence(peerKey);
    },
    setMeshArcReceiver: (status: MeshArcReceiverStatus): void => { this.meshArcReceiver = status; },
    setAccountSummary: (summary: AccountSummary): void => { this.accountSummary = summary; },
    setAvatarLoadFailed: (failed: boolean): void => { this.avatarLoadFailed = failed; },
    getExitNodes: (): ExitNodeChoice[] => this.exitNodes,
    setExitNodes: (choices: ExitNodeChoice[]): void => { this.exitNodes = choices; },
    isExitNodeUpdateInProgress: (): boolean => this.exitNodeUpdateInProgress,
    setExitNodeUpdateInProgress: (inProgress: boolean): void => { this.exitNodeUpdateInProgress = inProgress; },
    isExitNodeStatusFailed: (): boolean =>
      typeof this.exitNodeStatus === 'string' && this.exitNodeStatus.startsWith('FAILED'),
    setExitNodeNoneStatus: (): void => { this.exitNodeStatus = $r('app.string.exit_node_status_none'); },
    setExitNodeSelectedStatus: (name: string): void => {
      this.exitNodeStatus = $r('app.string.exit_node_selected', name);
    },
    setExitNodeUnavailableStatus: (): void => {
      this.exitNodeStatus = $r('app.string.exit_node_list_unavailable');
    },
    setExitNodeRawStatus: (status: string): void => { this.exitNodeStatus = status; },
    getNetworkSettings: (): NetworkSettings => this.networkSettings,
    setNetworkSettings: (settings: NetworkSettings): void => { this.networkSettings = settings; },
    setNetworkSettingStatus: (status: string): void => { this.networkSettingStatus = status; },
    isRouteAllUpdateInProgress: (): boolean => this.routeAllUpdateInProgress,
    setRouteAllUpdateInProgress: (inProgress: boolean): void => { this.routeAllUpdateInProgress = inProgress; },
    isExitNodeLanUpdateInProgress: (): boolean => this.exitNodeLanUpdateInProgress,
    setExitNodeLanUpdateInProgress: (inProgress: boolean): void => { this.exitNodeLanUpdateInProgress = inProgress; },
    setTrafficDownloadBytes: (bytes: number): void => { this.trafficDownloadBytes = bytes; },
    setTrafficUploadBytes: (bytes: number): void => { this.trafficUploadBytes = bytes; },
    setTrafficDownloadRate: (rate: number): void => { this.trafficDownloadRate = rate; },
    setTrafficUploadRate: (rate: number): void => { this.trafficUploadRate = rate; },
    getTrafficSamples: (): TrafficSample[] => this.trafficSamples,
    setTrafficSamples: (samples: TrafficSample[]): void => { this.trafficSamples = samples; },
    isVpnConflictDialogVisible: (): boolean => this.vpnConflictDialogVisible,
    setVpnConflictDialogVisible: (visible: boolean): void => { this.vpnConflictDialogVisible = visible; },
    showVpnConflictAlertDialog: (): void => { this.openVpnConflictDialog(); },
    syncHomeTitleCompact: (compact: boolean): void => { this.syncHomeTitleCompact(compact); },
    setHomeTitleCompact: (compact: boolean): void => { this.homeTitleCompact = compact; },
    setBackendRestartDeferred: (deferred: boolean): void => { this.backendRestartDeferred = deferred; },
    deviceModel: (): string => this.deviceModel(),
    harmonyOSHostinfoVersion: (): string => this.harmonyOSHostinfoVersion(),
    openControlServerSettings: (): void => { this.openControlServerSettings(); },
    openSecureLoginBrowser: (authUrl: string): Promise<void> =>
      this.openSecureLoginBrowser(this.abilityContext(), authUrl),
    confirmControlServerSelection: (normalizedUrl: string): ControlServerSettings | undefined =>
      this.settingsPreferencesGateway.confirmControlServer(this.abilityContext(), normalizedUrl),
    invalidateAccountGuard: (): void => { this.accountRequestGuard.invalidate(); },
    clearControlServerShellState: (): void => { this.clearControlServerPresentation(); },
    reloadTaildropStorageForActiveIdentity: (): void => {
      this.taildropSessionController.reloadStorageForActiveIdentity();
    },
    resetTaildropSnapshot: (): void => { this.resetTaildropSnapshot(); },
    applyBackendTaildropSnapshot: (snapshot: TaildropSnapshot): void => {
      this.applyBackendTaildropSnapshot(snapshot);
    },
    onLiveExtensionTick: (): void => {
      this.taildropSessionController.checkTaildropReceiveTimeout();
      this.taildropSessionController.processTaildropReceiveResponse();
    },
    resetStreamingStatesForDisconnect: (): void => { this.resetStreamingStatesForDisconnect(); },
    autoProbeConnectedPeerServices: (): void => { this.autoProbeConnectedPeerServices(); },
    syncOfflinePeerStatusRefreshPolling: (): void => { this.syncOfflinePeerStatusRefreshPolling(); },
    syncWindowPrivacyMode: (): void => { this.syncWindowPrivacyMode(); },
    logServiceStatusIfChanged: (): void => { this.logServiceStatusIfChanged(); },
    scheduleLifecycleTask: (task: () => void, delayMs: number): number =>
      this.scheduleLifecycleTask(task, delayMs),
    recordDiagnosticEvent: (event: string, phase: string, code: number = 0): void => {
      this.recordDiagnosticEvent(event, phase, code);
    }
  };

  private readonly vpnSessionController: VpnSessionController = new VpnSessionController(this.vpnSessionHost);

  private readonly taildropSessionHost: TaildropSessionHost = {
    getAbilityContext: (): common.UIAbilityContext => this.abilityContext(),
    getFilesDir: (): string => this.abilityContext().filesDir,
    getCacheDir: (): string => this.abilityContext().cacheDir,
    getServerFilesRoot: (): string => this.serverFilesRoot(),
    getLifecycleGeneration: (): number => this.lifecycleGeneration,
    getControlServerEpoch: (): number => this.controlServerEpoch,
    isAppShellReady: (): boolean => this.appShellReady,
    isSecurityPreferencesReady: (): boolean => this.securityPreferencesReady,
    isAppLockRequired: (): boolean => this.appLockRequired,
    isAppLockAuthenticating: (): boolean => this.appLockAuthenticating,
    isSecurityCoverActive: (): boolean => this.isSecurityCoverActive(),
    isConnected: (): boolean => this.isConnected(),
    getBackendStatus: (): string => this.backendStatus,
    isDiagnosticReportInProgress: (): boolean => this.diagnosticReportInProgress,
    getTaildropState: (): string => this.taildropState,
    setTaildropState: (state: string): void => { this.taildropState = state; },
    getTaildropReason: (): string => this.taildropReason,
    setTaildropReason: (reason: string): void => { this.taildropReason = reason; },
    getTaildropTargets: (): TaildropTargetSummary[] => this.displayedTaildropTargets(),
    setTaildropTargets: (targets: TaildropTargetSummary[]): void => { this.taildropTargets = targets; },
    getTaildropWaitingFiles: (): TaildropWaitingFileSummary[] => this.taildropWaitingFiles,
    setTaildropWaitingFiles: (files: TaildropWaitingFileSummary[]): void => { this.taildropWaitingFiles = files; },
    getTaildropInboxReason: (): string => this.taildropInboxReason,
    setTaildropInboxReason: (reason: string): void => { this.taildropInboxReason = reason; },
    getTaildropTransfer: (): TaildropTransferSummary => this.taildropTransfer,
    setTaildropTransfer: (transfer: TaildropTransferSummary): void => { this.taildropTransfer = transfer; },
    getTaildropReceive: (): TaildropReceiveResult => this.taildropReceive,
    setTaildropReceive: (receive: TaildropReceiveResult): void => { this.taildropReceive = receive; },
    getTaildropMediaPreviews: (): TaildropMediaPreview[] => this.taildropMediaPreviews,
    setTaildropMediaPreviews: (previews: TaildropMediaPreview[]): void => { this.taildropMediaPreviews = previews; },
    getTaildropCachedFiles: (): TaildropCachedFile[] => this.taildropCachedFiles,
    setTaildropCachedFiles: (files: TaildropCachedFile[]): void => { this.taildropCachedFiles = files; },
    getTaildropHistory: (): TaildropTransferRecord[] => this.taildropHistory,
    setTaildropHistory: (records: TaildropTransferRecord[]): void => { this.taildropHistory = records; },
    isTaildropPreparing: (): boolean => this.taildropPreparing,
    setTaildropPreparing: (preparing: boolean): void => { this.taildropPreparing = preparing; },
    isTaildropReceiveInProgress: (): boolean => this.taildropReceiveInProgress,
    setTaildropReceiveInProgress: (inProgress: boolean): void => { this.taildropReceiveInProgress = inProgress; },
    isTaildropMediaSaveInProgress: (): boolean => this.taildropMediaSaveInProgress,
    setTaildropMediaSaveInProgress: (inProgress: boolean): void => { this.taildropMediaSaveInProgress = inProgress; },
    isTaildropTextEditorVisible: (): boolean => this.taildropTextEditorVisible,
    setTaildropTextEditorVisible: (visible: boolean): void => { this.taildropTextEditorVisible = visible; },
    isTaildropTextPreviewVisible: (): boolean => this.taildropTextPreviewVisible,
    setTaildropTextPreviewVisible: (visible: boolean): void => { this.taildropTextPreviewVisible = visible; },
    getTaildropTextInput: (): string => this.taildropTextInput,
    setTaildropTextInput: (input: string): void => { this.taildropTextInput = input; },
    setTaildropTextInputCanSend: (canSend: boolean): void => { this.taildropTextInputCanSend = canSend; },
    getTaildropReceivedText: (): string => this.taildropReceivedText,
    setTaildropReceivedText: (text: string): void => { this.taildropReceivedText = text; },
    getTaildropTransferRate: (): number => this.taildropTransferRate,
    setTaildropTransferRate: (rate: number): void => { this.taildropTransferRate = rate; },
    getTaildropTransferEtaSeconds: (): number => this.taildropTransferEtaSeconds,
    setTaildropTransferEtaSeconds: (seconds: number): void => { this.taildropTransferEtaSeconds = seconds; },
    isTaildropCancelPending: (): boolean => this.taildropCancelPending,
    setTaildropCancelPending: (pending: boolean): void => { this.taildropCancelPending = pending; },
    isTaildropPreviewCachePresent: (): boolean => this.taildropPreviewCachePresent,
    setTaildropPreviewCachePresent: (present: boolean): void => { this.taildropPreviewCachePresent = present; },
    getMissingTaildropPreviewPaths: (): string[] => this.missingTaildropPreviewPaths,
    setMissingTaildropPreviewPaths: (paths: string[]): void => { this.missingTaildropPreviewPaths = paths; },
    isCacheClearInProgress: (): boolean => this.cacheClearInProgress,
    setCacheClearInProgress: (inProgress: boolean): void => { this.cacheClearInProgress = inProgress; },
    setTaildropPickerOpen: (open: boolean): void => { this.taildropPickerOpen = open; },
    getTaildropNotificationAction: (): string => this.taildropNotificationAction,
    clearTaildropNotificationAction: (): void => { AppStorage.setOrCreate('taildropNotificationAction', ''); },
    scheduleExternalTabNavigation: (tabIndex: number): void => { this.scheduleExternalTabNavigation(tabIndex); },
    scrollTransferToTop: (): void => { this.transferScroller.scrollEdge(Edge.Top); },
    onCacheContentsChanged: (): void => { this.notifyCacheContentsChanged(); },
    refreshCacheSize: (showLoading: boolean = false): void => { this.refreshCacheSize(showLoading); },
    scheduleLifecycleTask: (task: () => void, delayMs: number): number =>
      this.scheduleLifecycleTask(task, delayMs),
    showTaildropToast: (key: TaildropToastKey): void => { this.showTaildropToast(key); },
    recordDiagnosticEvent: (event: string, phase: string, code: number = 0): void => {
      this.recordDiagnosticEvent(event, phase, code);
    }
  };

  private readonly taildropSessionController: TaildropSessionController =
    new TaildropSessionController(this.taildropSessionHost);

  private readonly peerIntegrationHost: PeerIntegrationHost = {
    getAbilityContext: (): common.UIAbilityContext => this.abilityContext(),
    getFilesDir: (): string => this.abilityContext().filesDir,
    getLifecycleGeneration: (): number => this.lifecycleGeneration,
    getNavigationRevision: (): number => this.navigationRevision,
    getTrafficSession: (): number => this.vpnSessionController.trafficSession,
    isAppShellReady: (): boolean => this.appShellReady,
    isRemoteStreamAppInForeground: (): boolean => this.remoteStreamAppInForeground,
    setRemoteStreamAppInForeground: (inForeground: boolean): void => {
      this.remoteStreamAppInForeground = inForeground;
    },
    isAppLockRequired: (): boolean => this.appLockRequired,
    isAppLockAuthenticating: (): boolean => this.appLockAuthenticating,
    isConnected: (): boolean => this.isConnected(),
    getPeers: (): PeerSummary[] => this.peers,
    peerEffectivelyOnline: (peer: PeerSummary): boolean => this.peerEffectivelyOnline(peer),
    getSelectedPeerKey: (): string => this.selectedPeerKey,
    isDeviceDetailVisible: (): boolean => this.deviceDetailVisible,
    setDeviceDetailVisible: (visible: boolean): void => { this.deviceDetailVisible = visible; },
    getDeviceDetailPresentationId: (): number => this.deviceDetailPresentationId,
    isDeviceDetailServiceRefreshInFlight: (): boolean => this.deviceDetailServiceRefreshInFlight,
    setDeviceDetailServiceRefreshInFlight: (inFlight: boolean): void => {
      this.deviceDetailServiceRefreshInFlight = inFlight;
    },
    isTransferProtocolRefreshing: (): boolean => this.transferProtocolRefreshing,
    setTransferProtocolRefreshing: (refreshing: boolean): void => {
      this.transferProtocolRefreshing = refreshing;
    },
    getStreamingStates: (): DeviceStreamingState[] => this.streamingStates,
    setStreamingStates: (states: DeviceStreamingState[]): void => { this.streamingStates = states; },
    getMediaStates: (): DeviceMediaState[] => this.mediaStates,
    setMediaStates: (states: DeviceMediaState[]): void => { this.mediaStates = states; },
    isFakeMediaServiceOnline: (): boolean => this.fakeMediaServiceOnline,
    getFakeJellyfinName: (): string =>
      this.resolveResourceString($r('app.string.diagnostic_fake_jellyfin_name')),
    isMediaSelfTestInProgress: (): boolean => this.mediaSelfTestInProgress,
    setMediaSelfTestInProgress: (inProgress: boolean): void => { this.mediaSelfTestInProgress = inProgress; },
    setMediaSelfTestStatusKind: (kind: MediaSelfTestStatusKind): void => {
      this.applyMediaSelfTestStatusKind(kind);
    },
    getLocalSendPortOverrides: (): LocalSendPortOverride[] => this.localSendPortOverrides,
    setLocalSendPortOverrides: (overrides: LocalSendPortOverride[]): void => {
      this.localSendPortOverrides = overrides;
    },
    getRemotePortPeerKey: (): string => this.remotePortPeerKey,
    getRemotePortInput: (): string => this.remotePortInput,
    setRemotePortEditorVisible: (visible: boolean): void => { this.remotePortEditorVisible = visible; },
    setTaildropFocusedTargetKey: (key: string): void => { this.taildropFocusedTargetKey = key; },
    getTaildropFocusedTargetKey: (): string => this.taildropFocusedTargetKey,
    refreshBackendStatus: (): Promise<void> => this.refreshBackendStatus(),
    refreshPeerSnapshot: (): void => { this.refreshPeerSnapshot(); },
    refreshTaildropSnapshot: (connected: boolean = this.isConnected()): void => {
      this.refreshTaildropSnapshot(connected);
    },
    logServiceStatusIfChanged: (): void => { this.logServiceStatusIfChanged(); },
    scheduleLifecycleTask: (task: () => void, delayMs: number): number =>
      this.scheduleLifecycleTask(task, delayMs),
    showPeerIntegrationToast: (key: PeerIntegrationToastKey): void => {
      this.showPeerIntegrationToast(key);
    },
    showDerpStreamConfirmationDialog: (
      peer: PeerSummary,
      state: DeviceStreamingState,
      intent: RemoteStreamLaunchIntent
    ): void => {
      this.showDerpStreamConfirmation(peer, state, intent);
    },
    showMoonlightRequiredDialog: (hostAddress: string): void => {
      this.showMoonlightRequiredAlertDialog(hostAddress);
    },
    copyHosPlayerPrototypeText: (prototypeLink: string): void => {
      this.copyPlainText(prototypeLink, $r('app.string.hosplayer_import_link_copied_toast'));
    },
    recordDiagnosticEvent: (event: string, phase: string, code: number = 0): void => {
      this.recordDiagnosticEvent(event, phase, code);
    },
    recordFeatureDiagnosticEvent: (event: string, phase: string, code: number = 0): void => {
      this.recordFeatureDiagnosticEvent(event, phase, code);
    }
  };

  private readonly peerIntegrationController: PeerIntegrationController =
    new PeerIntegrationController(this.peerIntegrationHost, {
      accountDiagnosticsGateway: this.accountDiagnosticsGateway
    });

  private applyLoginPromptKind(kind: VpnLoginPromptKind): void {
    if (kind === 'login_loading') {
      this.loginPrompt = $r('app.string.login_loading');
    } else if (kind === 'login_browser_prompt') {
      this.loginPrompt = $r('app.string.login_browser_prompt');
    } else if (kind === 'auth_key_loading') {
      this.loginPrompt = $r('app.string.auth_key_loading');
    } else {
      this.loginPrompt = '';
    }
  }

  private applyMediaSelfTestStatusKind(kind: MediaSelfTestStatusKind): void {
    if (kind === 'running') {
      this.mediaSelfTestStatus = this.resolveResourceString($r('app.string.diagnostic_media_self_test_running'));
    } else if (kind === 'passed') {
      this.mediaSelfTestStatus = this.resolveResourceString($r('app.string.diagnostic_media_self_test_passed'));
    } else if (kind === 'failed_export') {
      this.mediaSelfTestStatus = this.resolveResourceString($r('app.string.diagnostic_media_self_test_failed_export'));
    } else {
      this.mediaSelfTestStatus = this.resolveResourceString($r('app.string.diagnostic_media_self_test_unavailable'));
    }
  }

  private resolveTaildropToastResource(key: TaildropToastKey): Resource {
    switch (key) {
      case 'settings_clear_cache_busy':
        return $r('app.string.settings_clear_cache_busy');
      case 'settings_all_local_files_cleared':
        return $r('app.string.settings_all_local_files_cleared');
      case 'settings_cache_cleared':
        return $r('app.string.settings_cache_cleared');
      case 'settings_all_local_files_clear_failed':
        return $r('app.string.settings_all_local_files_clear_failed');
      case 'settings_clear_cache_failed':
        return $r('app.string.settings_clear_cache_failed');
      case 'transfer_send_completed':
        return $r('app.string.transfer_send_completed');
      case 'transfer_send_target_unavailable':
        return $r('app.string.transfer_send_target_unavailable');
      case 'transfer_admin_disabled_title':
        return $r('app.string.transfer_admin_disabled_title');
      case 'transfer_send_disconnected':
        return $r('app.string.transfer_send_disconnected');
      case 'transfer_send_cancelled':
        return $r('app.string.transfer_send_cancelled');
      case 'transfer_send_permission_denied':
        return $r('app.string.transfer_send_permission_denied');
      case 'transfer_send_no_space':
        return $r('app.string.transfer_send_no_space');
      case 'transfer_send_file_unavailable':
        return $r('app.string.transfer_send_file_unavailable');
      case 'transfer_send_file_changed':
        return $r('app.string.transfer_send_file_changed');
      case 'transfer_busy_message':
        return $r('app.string.transfer_busy_message');
      case 'transfer_send_backend_unavailable':
        return $r('app.string.transfer_send_backend_unavailable');
      case 'transfer_send_interrupted':
        return $r('app.string.transfer_send_interrupted');
      case 'transfer_send_failed':
        return $r('app.string.transfer_send_failed');
      case 'transfer_history_cleared':
        return $r('app.string.transfer_history_cleared');
      case 'transfer_connect_first_title':
        return $r('app.string.transfer_connect_first_title');
      case 'transfer_file_selection_failed':
        return $r('app.string.transfer_file_selection_failed');
      case 'transfer_file_copy_failed':
        return $r('app.string.transfer_file_copy_failed');
      case 'transfer_cancel_failed':
        return $r('app.string.transfer_cancel_failed');
      case 'transfer_retry_choose_content':
        return $r('app.string.transfer_retry_choose_content');
      case 'transfer_receive_failed':
        return $r('app.string.transfer_receive_failed');
      case 'transfer_receive_picker_failed':
        return $r('app.string.transfer_receive_picker_failed');
      case 'transfer_discard_completed':
        return $r('app.string.transfer_discard_completed');
      case 'transfer_cache_cleared':
        return $r('app.string.transfer_cache_cleared');
      case 'transfer_clear_cache_failed':
        return $r('app.string.transfer_clear_cache_failed');
      case 'transfer_save_timeout':
        return $r('app.string.transfer_save_timeout');
      case 'transfer_media_ready_to_save':
        return $r('app.string.transfer_media_ready_to_save');
      case 'transfer_media_save_failed':
        return $r('app.string.transfer_media_save_failed');
      case 'transfer_image_saved':
        return $r('app.string.transfer_image_saved');
      case 'transfer_text_copied':
        return $r('app.string.transfer_text_copied');
      case 'transfer_receive_completed':
        return $r('app.string.transfer_receive_completed');
      case 'transfer_receive_unavailable':
        return $r('app.string.transfer_receive_unavailable');
      case 'transfer_receive_no_space':
        return $r('app.string.transfer_receive_no_space');
      case 'transfer_discard_failed':
        return $r('app.string.transfer_discard_failed');
      case 'transfer_receive_delete_failed':
        return $r('app.string.transfer_receive_delete_failed');
      case 'transfer_gallery_failed':
        return $r('app.string.transfer_gallery_failed');
      case 'transfer_text_copy_failed':
        return $r('app.string.transfer_text_copy_failed');
    }
  }

  private showTaildropToast(key: TaildropToastKey): void {
    this.showToast(this.resolveTaildropToastResource(key));
  }

  private resolvePeerIntegrationToastResource(key: PeerIntegrationToastKey): Resource {
    switch (key) {
      case 'transfer_tailscale_network_not_connected':
        return $r('app.string.transfer_tailscale_network_not_connected');
      case 'transfer_remote_port_invalid':
        return $r('app.string.transfer_remote_port_invalid');
      case 'transfer_remote_port_saved':
        return $r('app.string.transfer_remote_port_saved');
      case 'transfer_localsend_open_failed':
        return $r('app.string.transfer_localsend_open_failed');
      case 'peer_service_connect_and_online_toast':
        return $r('app.string.peer_service_connect_and_online_toast');
      case 'stream_connect_required_toast':
        return $r('app.string.stream_connect_required_toast');
      case 'stream_target_offline_toast':
        return $r('app.string.stream_target_offline_toast');
      case 'stream_sunshine_probe_error_toast':
        return $r('app.string.stream_sunshine_probe_error_toast');
      case 'stream_path_probe_timeout_toast':
        return $r('app.string.stream_path_probe_timeout_toast');
      case 'stream_sunshine_timeout_toast':
        return $r('app.string.stream_sunshine_timeout_toast');
      case 'stream_sunshine_unavailable_toast':
        return $r('app.string.stream_sunshine_unavailable_toast');
      case 'stream_sunshine_failed_toast':
        return $r('app.string.stream_sunshine_failed_toast');
      case 'stream_target_unreachable_toast':
        return $r('app.string.stream_target_unreachable_toast');
      case 'stream_moonlight_open_failed_toast':
        return $r('app.string.stream_moonlight_open_failed_toast');
      case 'hosplayer_open_failed_toast':
        return $r('app.string.hosplayer_open_failed_toast');
      case 'hosplayer_unsafe_endpoint_toast':
        return $r('app.string.hosplayer_unsafe_endpoint_toast');
      case 'hosplayer_import_link_failed_toast':
        return $r('app.string.hosplayer_import_link_failed_toast');
    }
  }

  private showPeerIntegrationToast(key: PeerIntegrationToastKey): void {
    this.showToast(this.resolvePeerIntegrationToastResource(key));
  }

  private applyMergedPeersToShell(mergedPeers: PeerSummary[]): void {
    this.peers = mergedPeers;
    this.peerDataSource.replaceAll(mergedPeers);
    this.peerIntegrationController.pruneOfflineServiceStates(mergedPeers);
    if (this.selectedPeerKey.length > 0) {
      const selectedPeer: PeerSummary | undefined = mergedPeers.find((peer: PeerSummary) =>
        peer.key === this.selectedPeerKey);
      if (selectedPeer !== undefined && this.deviceDetailVisible) {
        this.selectedPeerDetails = [selectedPeer];
        this.selectedPeerTitleName = this.peerDisplayName(selectedPeer.name);
        this.selectedPeerTitleDeviceType = selectedPeer.deviceType;
        this.selectedPeerTitleSystem = this.peerDeviceDescription(selectedPeer);
        this.selectedPeerTitleOnline = this.peerEffectivelyOnline(selectedPeer);
      }
      if (selectedPeer === undefined && !this.deviceDetailVisible) {
        this.selectedPeerKey = '';
        this.selectedPeerDetails = [];
        this.selectedPeerTitleName = '';
        this.selectedPeerTitleDeviceType = '';
        this.selectedPeerTitleSystem = '';
        this.selectedPeerTitleOnline = false;
      }
    }
    if (this.selectedPeerKey.length === 0 && mergedPeers.length > 0) {
      this.selectedPeerKey = mergedPeers[0].key;
    }
  }

  private applyPeers(peers: PeerSummary[]): void {
    this.vpnSessionController.applyPeers(peers);
  }

  aboutToAppear(): void {
    this.lifecycleGeneration++;
    this.remoteStreamAppInForeground = true;
    this.taildropPreparing = false;
    this.sharedFileSending = false;
    AppStorage.setOrCreate('taildriveFilesTabActive', this.activeNavigationId === 'files');
    this.appShellReady = true;
    this.standaloneDiagnosticsVisible = false;
    this.diagnosticReportInProgress = false;
    this.pathDiagnosticBusy = false;
    this.connectionDetailsVisible = false;
    this.deviceDetailVisible = false;
    this.selectedPeerTitleName = '';
    this.selectedPeerTitleDeviceType = '';
    this.selectedPeerTitleSystem = '';
    this.selectedPeerTitleOnline = false;
    this.securityPreferencesReady = false;
    this.updateChangelogVisible = false;
    this.updateChangelogShowPending = false;
    this.accountRequestGuard.invalidate();
    this.diagnosticProbeRequestGuard.invalidate();
    this.diagnosticReportRequestGuard.invalidate();
    this.feedbackEmailStatus = '';
    this.pathDiagnosticRequestGuard.invalidate();
    this.diagnosticActionRequestGuard.invalidate();
    this.peerIntegrationController.resetOnAppear();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.vpnSessionController.resetOnAppear(context.filesDir);
    this.onTaildropOpenInbox();
    this.onSystemShare();
    this.onSystemShareError();
    this.onTaildropNotificationAction();
    context.eventHub.on(APP_FOREGROUND_EVENT, this.appForegroundListener);
    this.tailnetDnsEnabled = TailnetDnsPreferences.enabled(context.filesDir);
    const customDns: DnsSettings = DnsSettingsStore.load(context.filesDir);
    this.dnsSettingsEnabled = customDns.enabled;
    this.dnsPrimaryInput = customDns.primary;
    this.dnsSecondaryInput = customDns.secondary;
    this.dnsSearchDomainsInput = DnsSettingsStore.formatSearchDomains(customDns.searchDomains);
    this.dnsSettingsStatus = '';
    context.eventHub.on(APP_BACKGROUND_EVENT, this.appBackgroundListener);
    this.loadGlowLevel();
    this.loadAppearancePreferences();
    this.fakeMediaServiceOnline = false;
    if (typeof this.syncWindowPrivacyMode === 'function') {
      this.syncWindowPrivacyMode();
    }
    this.loadSettingsPreferences(context);
    this.loadSecurityPreferences(context);
    this.loadNavigationPreferences(context);
    this.loadAnimationPreferences(context);
    this.loadFileTransferPreference(context);
    this.refreshCacheSize();
    this.resetDiagnosticsMode();
    this.scheduleLifecycleTask(() => DiagnosticReportService.cleanupCache(context.cacheDir), 0);
    this.backendReady = false;
    this.devicesLoading = true;
    this.verifyNativeBridge();
    this.loadAppVersion();
    this.taildropSessionController.reloadStorageForActiveIdentity();
    this.maybeExpireTaildropCache();
    this.scheduleLifecycleTask(() => this.showUpdateChangelogIfNeeded(), 350);
    this.scheduleLifecycleTask(() => this.showWelcomeDialogIfNeeded(), 350);
    this.recordDiagnosticEvent('ui_opened', 'lifecycle');
    const vpnIsLive: boolean = this.refreshVpnProbeStatus();
    if (this.controlServerConfirmed) this.refreshPeerSnapshot(true);
    if (!this.controlServerConfirmed) {
      this.backendStatus = 'Tailscale Backend Stopped | control server not configured';
      this.backendReady = true;
      this.backendInitializationVisible = false;
      this.devicesLoading = false;
      if (vpnIsLive) {
        this.vpnSessionController.stopVpnExtensionDirect().catch(() => {
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
    this.startServiceRefreshPolling();
    this.syncHomeLatencyRefreshPolling();
    this.syncTransferProtocolRefreshPolling();
  }

  aboutToDisappear(): void {
    this.contextGuideController?.close();
    this.contextGuideController = undefined;
    this.contextGuideVisible = false;
    this.vpnSessionController.teardownOnDisappear();
    this.lifecycleGeneration++;
    AppStorage.setOrCreate('taildriveFilesTabActive', false);
    this.appShellReady = false;
    this.externalTabNavigationTimer = -1;
    this.pendingExternalTabIndex = -1;
    this.transferScrollRestoreTimer = -1;
    this.settingsScrollRestoreTimer = -1;
    this.settingsRequestGuard.invalidate();
    this.accountRequestGuard.invalidate();
    this.diagnosticProbeRequestGuard.invalidate();
    this.diagnosticReportRequestGuard.invalidate();
    this.feedbackEmailStatus = '';
    this.pathDiagnosticRequestGuard.invalidate();
    this.diagnosticActionRequestGuard.invalidate();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.eventHub.off(APP_FOREGROUND_EVENT, this.appForegroundListener);
    context.eventHub.off(APP_BACKGROUND_EVENT, this.appBackgroundListener);
    this.vpnConflictDialogVisible = false;
    this.welcomeDialogVisible = false;
    this.connectionDetailsVisible = false;
    this.deviceDetailVisible = false;
    this.fileTransferMethodVisible = false;
    this.mediaMethodVisible = false;
    this.remotePortEditorVisible = false;
    this.updateChangelogVisible = false;
    this.updateChangelogShowPending = false;
    this.stopConnectionDurationPolling();
    this.stopServiceRefreshPolling();
    this.stopOfflinePeerStatusRefreshPolling();
    this.stopHomeLatencyRefreshPolling();
    this.stopDeviceDetailRefreshPolling();
    this.stopTransferProtocolRefreshPolling();
    this.authKeyInput = '';
    this.authKeyLoginVisible = false;
    if (this.authKeyStatus === 'loading') {
      this.authKeyStatus = '';
      this.loginInProgress = false;
      this.loginPrompt = '';
    }
    this.stopCacheSizePolling();
    this.peerIntegrationController.teardownOnDisappear();
    this.flushAnimationPreferences();
    this.flushPersonalizationPreferences();
    this.flushNavigationMarginPreferences();
    this.clearLifecycleTimers();
    this.resetDiagnosticsMode();
  }

  private handleAppForeground(): void {
    this.remoteStreamAppInForeground = true;
    if (typeof this.syncWindowPrivacyMode === 'function') {
      this.syncWindowPrivacyMode();
    }
    this.requireAppAuthentication();
    const generation: number = this.lifecycleGeneration;
    const vpnIsLive: boolean = this.refreshVpnProbeStatus();
    this.maybeExpireTaildropCache();
    this.startHealthPolling();
    this.startServiceRefreshPolling();
    this.syncHomeLatencyRefreshPolling();
    this.syncOfflinePeerStatusRefreshPolling();
    this.syncTransferProtocolRefreshPolling();
    if (this.connectionDetailsVisible) {
      this.startConnectionDurationPolling();
    }
    if (this.deviceDetailVisible) {
      this.startDeviceDetailRefreshPolling();
    }
    if (this.activeNavigationId === 'settings') {
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

  private handleAppBackground(): void {
    this.handleRemoteStreamAppBackground();
    this.connectionButtonPressed = false;
    this.stopServiceRefreshPolling();
    this.stopOfflinePeerStatusRefreshPolling();
    this.stopHomeLatencyRefreshPolling();
    this.stopTransferProtocolRefreshPolling();
    this.stopConnectionDurationPolling();
    this.stopCacheSizePolling();
    if (!this.connectInProgress && !this.disconnectInProgress && !this.taildropReceiveInProgress &&
      typeof this.stopHealthPolling === 'function') {
      this.stopHealthPolling();
    }
    if (this.deviceDetailRefreshTimer >= 0) {
      clearInterval(this.deviceDetailRefreshTimer);
      this.deviceDetailRefreshTimer = -1;
    }
    this.flushPersonalizationPreferences();
    this.flushNavigationMarginPreferences();
    if (typeof this.flushAnimationPreferences === 'function') {
      this.flushAnimationPreferences();
    }
  }

  private scheduleLifecycleTask(task: () => void, delayMs: number): number {
    const generation: number = this.lifecycleGeneration;
    let fired: boolean = false;
    let timer: number = -1;
    timer = setTimeout(() => {
      fired = true;
      this.lifecycleTimers = this.lifecycleTimers.filter((entry: number) => entry !== timer);
      if (generation === this.lifecycleGeneration) {
        task();
      }
    }, delayMs);
    if (!fired) {
      this.lifecycleTimers.push(timer);
    }
    return timer;
  }

  private clearLifecycleTimers(): void {
    this.lifecycleTimers.forEach((timer: number) => clearTimeout(timer));
    this.lifecycleTimers = [];
  }

  private loadAppVersion(): void {
    this.appVersionMetadataReady = false;
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
      .then((info: bundleManager.BundleInfo) => {
        this.appVersion = info.versionName;
        this.appVersionCode = info.versionCode;
        this.appVersionMetadataReady = true;
        if (this.appShellReady && this.updateChangelogShowPending) {
          this.showUpdateChangelogIfNeeded();
        }
      })
      .catch(() => {
        this.appVersionMetadataReady = true;
        if (this.appShellReady && this.updateChangelogShowPending) {
          this.showUpdateChangelogIfNeeded();
        }
      });
  }

  private updateChangelogVersionKey(): string {
    return `${this.appVersion}:${this.appVersionCode}`;
  }

  private showUpdateChangelogIfNeeded(): void {
    this.updateChangelogShowPending = true;
    if (!this.appShellReady || !this.appVersionMetadataReady || !this.securityPreferencesReady ||
      this.appLockRequired || this.appLockAuthenticating ||
      this.updateChangelogVisible || this.welcomeDialogVisible) {
      return;
    }
    const versionKey: string = this.updateChangelogVersionKey();
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (this.settingsPreferencesGateway.hasSeenUpdateChangelog(context.filesDir, versionKey)) {
        this.updateChangelogShowPending = false;
        return;
      }
    } catch (_error) {
      // A missing or unreadable marker is treated as unseen so the release
      // notes are not silently skipped after an application update.
    }
    this.updateChangelogShowPending = false;
    this.updateChangelogVisible = true;
    this.recordDiagnosticEvent('update_changelog_shown', 'lifecycle');
  }

  private dismissUpdateChangelog(onlyOnUpdate: boolean): void {
    const versionKey: string = this.updateChangelogVersionKey();
    if (onlyOnUpdate) {
      try {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        this.settingsPreferencesGateway.markUpdateChangelogSeen(context.filesDir, versionKey);
      } catch (_error) {}
      this.recordDiagnosticEvent('update_changelog_only_on_update', 'lifecycle');
    } else {
      this.recordDiagnosticEvent('update_changelog_dismissed', 'lifecycle');
    }
    this.updateChangelogShowPending = false;
    this.updateChangelogVisible = false;
  }

  private onUpdateChangelogSheetDisappear(): void {
    if (this.updateChangelogVisible) {
      this.dismissUpdateChangelog(false);
    }
    // The native bindSheet has completed its dismiss animation at this point;
    // only now may the first-run guide claim focus.
    this.scheduleLifecycleTask(() => this.showWelcomeDialogIfNeeded(), 120);
  }

  private onUpdateChangelogActionRequested(): void {
    const action: string = this.updateChangelogAction;
    if (action.length === 0) {
      return;
    }
    this.updateChangelogAction = '';
    this.dismissUpdateChangelog(action === 'only_on_update');
  }

  private isChineseChangelogLocale(): boolean {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const locale: string = context.resourceManager.getConfigurationSync().locale;
      return locale.startsWith('zh');
    } catch (_error) {
      return false;
    }
  }

  private updateChangelogEntries(): UpdateChangelogEntry[] {
    const useChinese: boolean = this.isChineseChangelogLocale();
    return RELEASE_CHANGELOG_ENTRIES.map((entry: ReleaseChangelogDefinition,
      index: number): UpdateChangelogEntry => ({
      // BundleInfo remains the source of truth for what is installed. The
      // Release build gate ensures the first changelog item matches it.
      versionName: index === 0 ? this.appVersion : entry.versionName,
      versionCode: index === 0 ? this.appVersionCode : entry.versionCode,
      releaseDate: useChinese ? entry.releaseDateZh : entry.releaseDateEn,
      changes: useChinese ? entry.changesZh : entry.changesEn,
      current: index === 0
    }));
  }

  private loadSettingsPreferences(context: common.UIAbilityContext): void {
    const settings: ControlServerSettings = this.settingsPreferencesGateway.loadControlServer(context);
    this.controlServerURL = settings.controlURL;
    this.controlServerInput = settings.controlURL;
    this.controlServerConfirmed = settings.confirmed;
    const catalog: ControlServerPresetCatalog | undefined = ControlServerPresets.ensure(context.filesDir, settings.controlURL);
    this.controlServerPresets = catalog?.servers ?? [];
    this.loadAccountProfiles();
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

  private loadSecurityPreferences(context: common.UIAbilityContext): void {
    const generation: number = this.lifecycleGeneration;
    AppSecurityPreferences.load(context).then((settings: AppSecuritySettings) => {
      if (!this.appShellReady || generation !== this.lifecycleGeneration) {
        return;
      }
      this.appLockEnabled = settings.appLockEnabled;
      this.folderLockEnabled = settings.folderLockEnabled;
      AppStorage.setOrCreate('taildriveLockedFolderPaths', settings.lockedFolderPaths);
      this.securityPreferencesReady = true;
      if (typeof this.syncWindowPrivacyMode === 'function') {
        this.syncWindowPrivacyMode();
      }
      this.requireAppAuthentication();
      if (!this.appLockEnabled && !this.appLockRequired &&
        typeof this.resumeDeferredTaildropShellActions === 'function') {
        this.resumeDeferredTaildropShellActions();
      }
      if (this.updateChangelogShowPending) {
        this.showUpdateChangelogIfNeeded();
      }
    }).catch(() => {
      if (!this.appShellReady || generation !== this.lifecycleGeneration) return;
      const defaultFallback: AppSecuritySettings = {
        appLockEnabled: false,
        folderLockEnabled: false,
        lockedFolderPaths: []
      };
      const fallback: AppSecuritySettings = typeof AppSecurityPreferences.loadFallback === 'function' ?
        AppSecurityPreferences.loadFallback(context.filesDir) : defaultFallback;
      this.appLockEnabled = fallback.appLockEnabled;
      this.folderLockEnabled = fallback.folderLockEnabled;
      AppStorage.setOrCreate('taildriveLockedFolderPaths', fallback.lockedFolderPaths);
      this.securityPreferencesReady = true;
      if (typeof this.syncWindowPrivacyMode === 'function') {
        this.syncWindowPrivacyMode();
      }
      if (fallback.appLockEnabled) {
        this.requireAppAuthentication();
      } else if (!this.appLockRequired &&
        typeof this.resumeDeferredTaildropShellActions === 'function') {
        this.resumeDeferredTaildropShellActions();
      }
      if (this.updateChangelogShowPending) {
        this.showUpdateChangelogIfNeeded();
      }
    });
  }

  private resumeDeferredTaildropShellActions(): void {
    if (!this.appShellReady || !this.securityPreferencesReady || this.appLockRequired) {
      return;
    }
    if (typeof this.onTaildropOpenInbox === 'function') {
      this.onTaildropOpenInbox();
    }
    if (typeof this.onTaildropNotificationAction === 'function') {
      this.onTaildropNotificationAction();
    }
  }

  private isSecurityCoverActive(): boolean {
    return !this.securityPreferencesReady || this.appLockRequired;
  }

  private onSecurityPrivacyStateChanged(): void {
    this.syncWindowPrivacyMode();
  }

  private currentWindowPrivacyRequired(filesDir: string): boolean {
    if (!this.securityPreferencesReady) {
      try {
        return typeof AppSecurityPreferences.isPrivacyProtectionArmedSync === 'function' ?
          AppSecurityPreferences.isPrivacyProtectionArmedSync(filesDir) : false;
      } catch (_error) {
        return true;
      }
    }
    const storedPaths: string[] | undefined = typeof AppStorage !== 'undefined' &&
      typeof AppStorage.get === 'function' ?
      AppStorage.get<string[]>('taildriveLockedFolderPaths') : undefined;
    const appStorageLockedCount: number = Array.isArray(storedPaths) ? storedPaths.length : 0;
    const localLockedCount: number = Array.isArray(this.lockedFolderPaths) ? this.lockedFolderPaths.length : 0;
    return this.appLockEnabled || this.folderLockEnabled || localLockedCount > 0 ||
      appStorageLockedCount > 0 || this.appLockRequired || this.authKeyLoginVisible;
  }

  private syncWindowPrivacyMode(): void {
    const nextSeq: number = (typeof this.windowPrivacySyncSeq === 'number' ? this.windowPrivacySyncSeq : 0) + 1;
    this.windowPrivacySyncSeq = nextSeq;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const generation: number = this.lifecycleGeneration;
      window.getLastWindow(context).then((win: window.Window): Promise<void> | void => {
        if (!this.appShellReady || generation !== this.lifecycleGeneration ||
          nextSeq !== this.windowPrivacySyncSeq) {
          return;
        }
        if (win !== undefined && typeof win.setWindowPrivacyMode === 'function') {
          const privacyRequired: boolean = this.currentWindowPrivacyRequired(context.filesDir);
          return win.setWindowPrivacyMode(privacyRequired);
        }
      }).catch(() => {});
    } catch (_error) {
      // Window privacy mode is best-effort when UI context or window is detached.
    }
  }

  private onAppLockRequiredChanged(): void {
    if (typeof this.syncWindowPrivacyMode === 'function') {
      this.syncWindowPrivacyMode();
    }
    if (this.appLockRequired) {
      this.invalidateRemoteStreamLaunch();
      this.authKeyInput = '';
      this.authKeyLoginVisible = false;
      this.deviceDetailVisible = false;
      this.stopDeviceDetailRefreshPolling();
      this.fileTransferMethodVisible = false;
      this.mediaMethodVisible = false;
      this.nativeSettingsVisible = false;
      this.connectionDetailsVisible = false;
    }
    if (!this.appLockRequired && this.appShellReady && this.securityPreferencesReady &&
      typeof this.resumeDeferredTaildropShellActions === 'function') {
      this.resumeDeferredTaildropShellActions();
    }
    // The update-log sheet renders the same lock surface inside its native
    // bindSheet, so it remains protected even above the outer content cover.
    if (!this.appLockRequired && this.appShellReady && this.updateChangelogShowPending) {
      this.scheduleLifecycleTask(() => this.showUpdateChangelogIfNeeded(), 120);
    }
  }

  private requireAppAuthentication(): void {
    if (!this.appLockEnabled || this.appLockAuthenticating || this.securitySettingsAuthenticating) {
      return;
    }
    this.appLockRequired = true;
    this.appLockMessage = '';
    this.scheduleLifecycleTask(() => this.authenticateApplication(), 80);
  }

  private authenticateApplication(): void {
    if (!this.appLockEnabled || !this.appLockRequired || this.appLockAuthenticating ||
      this.securitySettingsAuthenticating) {
      return;
    }
    this.appLockAuthenticating = true;
    this.recordFeatureDiagnosticEvent('app_lock_auth_started', 'foreground');
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const title: string = context.resourceManager.getStringSync(
      $r('app.string.security_app_authentication_title').id);
    AppSecurityAuthenticator.authenticate(title).then((passed: boolean) => {
      this.appLockAuthenticating = false;
      if (!this.appShellReady) {
        return;
      }
      if (passed) {
        this.appLockRequired = false;
        this.appLockMessage = '';
        this.recordFeatureDiagnosticEvent('app_lock_auth_completed', 'passed');
      } else {
        this.appLockMessage = context.resourceManager.getStringSync(
          $r('app.string.security_authentication_failed').id);
        this.recordFeatureDiagnosticEvent('app_lock_auth_completed', 'failed');
      }
    }).catch(() => {
      this.appLockAuthenticating = false;
      this.appLockMessage = context.resourceManager.getStringSync(
        $r('app.string.security_authentication_failed').id);
      this.recordFeatureDiagnosticEvent('app_lock_auth_failed', 'exception');
    });
  }

  private setAppLockEnabled(enabled: boolean): void {
    if (enabled === this.appLockEnabled || this.securitySettingsAuthenticating) {
      return;
    }
    this.updateAppLockEnabled(enabled);
  }

  private async updateAppLockEnabled(enabled: boolean): Promise<void> {
    this.securitySettingsAuthenticating = true;
    const phase: string = enabled ? 'enable' : 'disable';
    this.recordFeatureDiagnosticEvent('app_lock_setting_auth_started', phase);
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const title: string = context.resourceManager.getStringSync(
        $r('app.string.security_settings_authentication_title').id);
      const passed: boolean = await AppSecurityAuthenticator.authenticate(title);
      if (!this.appShellReady || !passed) {
        if (this.appShellReady && !passed) {
          this.showToast($r('app.string.security_authentication_failed'));
          this.recordFeatureDiagnosticEvent('app_lock_setting_auth_completed', 'rejected');
        }
        return;
      }
      await AppSecurityPreferences.saveAppLockEnabled(context, enabled);
      this.appLockEnabled = enabled;
      this.appLockRequired = false;
      this.appLockMessage = '';
      if (typeof this.syncWindowPrivacyMode === 'function') {
        this.syncWindowPrivacyMode();
      }
      this.recordFeatureDiagnosticEvent('app_lock_setting_saved', phase);
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      this.recordFeatureDiagnosticEvent('app_lock_setting_failed', phase, businessError.code ?? -1);
      if (this.appShellReady) {
        this.showToast($r('app.string.security_settings_save_failed'));
      }
    } finally {
      this.securitySettingsAuthenticating = false;
    }
  }

  private setFolderLockEnabled(enabled: boolean): void {
    if (enabled === this.folderLockEnabled || this.securitySettingsAuthenticating) {
      return;
    }
    this.updateFolderLockEnabled(enabled);
  }

  private async updateFolderLockEnabled(enabled: boolean): Promise<void> {
    this.securitySettingsAuthenticating = true;
    const phase: string = enabled ? 'enable' : 'disable';
    this.recordFeatureDiagnosticEvent('folder_lock_setting_auth_started', phase);
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const title: string = context.resourceManager.getStringSync(
        $r('app.string.security_settings_authentication_title').id);
      const passed: boolean = await AppSecurityAuthenticator.authenticate(title);
      if (!this.appShellReady || !passed) {
        if (this.appShellReady && !passed) {
          this.showToast($r('app.string.security_authentication_failed'));
          this.recordFeatureDiagnosticEvent('folder_lock_setting_auth_completed', 'rejected');
        }
        return;
      }
      await AppSecurityPreferences.saveFolderLockEnabled(context, enabled);
      this.folderLockEnabled = enabled;
      if (enabled) {
        try {
          const storedPaths: string[] | undefined = typeof AppStorage !== 'undefined' &&
            typeof AppStorage.get === 'function' ?
            AppStorage.get<string[]>('taildriveLockedFolderPaths') : undefined;
          const lockedPaths: string[] = Array.isArray(storedPaths) && storedPaths.length > 0 ?
            storedPaths : (Array.isArray(this.lockedFolderPaths) ? this.lockedFolderPaths : []);
          if (lockedPaths.length > 0 && typeof TaildrivePreviewGateway === 'function') {
            new TaildrivePreviewGateway().purgeProtectedPreviews(context, lockedPaths);
          }
        } catch (_purgeError) {
          // Best-effort preview purge when enabling folder lock.
        }
      }
      if (typeof this.syncWindowPrivacyMode === 'function') {
        this.syncWindowPrivacyMode();
      }
      this.recordFeatureDiagnosticEvent('folder_lock_setting_saved', phase);
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      this.recordFeatureDiagnosticEvent('folder_lock_setting_failed', phase, businessError.code ?? -1);
      if (this.appShellReady) {
        this.showToast($r('app.string.security_settings_save_failed'));
      }
    } finally {
      this.securitySettingsAuthenticating = false;
    }
  }

  private showWelcomeDialogIfNeeded(): void {
    if (this.welcomeDialogVisible) {
      return;
    }
    if (!this.securityPreferencesReady || this.appLockRequired || this.appLockAuthenticating ||
      this.updateChangelogVisible || this.updateChangelogShowPending) {
      this.scheduleLifecycleTask(() => this.showWelcomeDialogIfNeeded(), 240);
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (this.settingsPreferencesGateway.isWelcomeAcknowledged(context.filesDir)) {
      return;
    }
    this.welcomeDialogVisible = true;
    this.getUIContext().showAlertDialog({
      title: $r('app.string.welcome_dialog_title'),
      message: $r('app.string.welcome_dialog_message'),
      autoCancel: false,
      secondaryButton: {
        value: $r('app.string.welcome_dialog_action'),
        action: () => {
          this.settingsPreferencesGateway.acknowledgeWelcome(context.filesDir);
          this.welcomeDialogVisible = false;
          this.recordDiagnosticEvent('welcome_dialog_acknowledged', 'first_run');
          if (this.updateChangelogShowPending) {
            this.scheduleLifecycleTask(() => this.showUpdateChangelogIfNeeded(), 120);
          }
        }
      }
    });
    this.recordDiagnosticEvent('welcome_dialog_shown', 'first_run');
  }

  private openFeedbackEmail(): void {
    this.generateDiagnosticReport(true);
  }

  private feedbackEmailFailed(requestGeneration: number, code: number): void {
    if (!this.diagnosticReportRequestGuard.isCurrent(requestGeneration) || this.feedbackEmailStatus === 'failed') return;
    this.feedbackEmailStatus = 'failed';
    this.recordDiagnosticEvent('feedback_email_unavailable', 'compose', code);
  }

  private showControlServerTip(): void {
    if (this.controlServerConfirmed) {
      return;
    }
    this.showToast(this.controlServerTipMessage);
    this.recordDiagnosticEvent('control_server_tip_shown', 'first_run');
  }

  private openControlServerSettings(): void {
    this.navigateToTab(3);
    this.showToast($r('app.string.control_server_required_to_connect'));
  }

  private loadNavigationPreferences(context: common.UIAbilityContext): void {
    const generation: number = this.lifecycleGeneration;
    NavigationPreferences.load(context).then((settings: NavigationSettings) => {
      if (!this.appShellReady || generation !== this.lifecycleGeneration) return;
      this.navigationOrder = [...settings.order];
      this.hiddenNavigationTabs = [...settings.hidden];
      this.navigationBottomMargin = settings.bottomMargin;
      this.syncNavigationSelection(this.activeNavigationId, false);
    }).catch(() => {
      if (!this.appShellReady || generation !== this.lifecycleGeneration) return;
      this.navigationOrder = [...DEFAULT_NAVIGATION_ORDER];
      this.hiddenNavigationTabs = [...DEFAULT_NAVIGATION_HIDDEN];
      this.navigationBottomMargin = DEFAULT_NAVIGATION_BOTTOM_MARGIN;
    });
  }

  private loadFileTransferPreference(context: common.UIAbilityContext): void {
    const lifecycleGeneration: number = this.lifecycleGeneration;
    FileTransferPreferences.load(context).then((transport: FileTransferTransport | undefined) => {
      if (this.lifecycleGeneration === lifecycleGeneration && transport !== undefined) {
        this.meshSendPreferredTransport = transport;
      }
    }).catch(() => {
      // MeshSend falls back to capability-based selection when storage is unavailable.
    });
    FileTransferPreferences.loadLocalSendPortOverrides(context).then(
      (overrides: LocalSendPortOverride[]) => {
        if (this.lifecycleGeneration === lifecycleGeneration) {
          this.localSendPortOverrides = overrides;
        }
      }).catch(() => {
        // The default LocalSend port remains available when preference storage is unavailable.
      });
  }

  private visibleNavigationTabs(): NavigationTabId[] {
    return this.navigationOrder.filter((id: NavigationTabId) =>
      id === 'settings' || !this.hiddenNavigationTabs.includes(id));
  }

  private navigationTabAt(index: number): NavigationTabId | undefined {
    const visible: NavigationTabId[] = this.visibleNavigationTabs();
    return index >= 0 && index < visible.length ? visible[index] : undefined;
  }

  private navigationTabIdForLogicalIndex(index: number): NavigationTabId {
    switch (index) {
      case 1: return 'transfer';
      case 2: return 'files';
      case 3: return 'settings';
      default: return 'home';
    }
  }

  private revealBackgroundRunningSetting(): void {
    const request: number = ++this.backgroundRunningReveal;
    this.backgroundRunningHighlighted = false;
    this.settingsPathStack.clear();
    this.navigateToNavigationTab('settings', false);
    this.scheduleLifecycleTask(() => this.scrollToBackgroundRunning(request, 0), 150);
  }

  private scrollToBackgroundRunning(request: number, attempt: number): void {
    if (request !== this.backgroundRunningReveal || this.activeNavigationId !== 'settings' || this.settingsDetailActive) {
      return;
    }
    const ui = this.getUIContext();
    try {
      const geometry = ui.getComponentUtils();
      const viewport = geometry.getRectangleById('settings-root-scroll');
      const row = geometry.getRectangleById('settings-background-running-entry');
      if (viewport.size.height <= 0 || row.size.height <= 0) {
        throw new Error('Settings row has not been laid out');
      }
      const offset: number = ui.px2vp(row.windowOffset.y - viewport.windowOffset.y -
        (viewport.size.height - row.size.height) / 2);
      this.settingsScroller.scrollTo({ xOffset: 0, yOffset: Math.max(0, this.readSettingsScrollOffset() + offset),
        animation: { duration: MotionTokens.duration(220), curve: Curve.EaseOut } });
    } catch (_error) {
      if (attempt < 4) {
        this.scheduleLifecycleTask(() => this.scrollToBackgroundRunning(request, attempt + 1), 100);
      }
      return;
    }
    for (let edge: number = 0; edge < 4; edge++) {
      const highlighted: boolean = edge % 2 === 0;
      this.scheduleLifecycleTask(() => {
        if (request === this.backgroundRunningReveal) {
          ui.animateTo({ duration: MotionTokens.duration(140), curve: Curve.EaseInOut }, () => {
            this.backgroundRunningHighlighted = highlighted && this.activeNavigationId === 'settings' &&
              !this.settingsDetailActive;
          });
        }
      }, 260 + edge * 340);
    }
  }

  private navigateToTab(index: number): void {
    this.navigateToNavigationTab(this.navigationTabIdForLogicalIndex(index), true);
  }

  private navigateToNavigationTab(id: NavigationTabId, revealHidden: boolean): void {
    this.invalidateRemoteStreamLaunch();
    this.navigationRevision++;
    if (revealHidden && this.hiddenNavigationTabs.includes(id)) {
      this.hiddenNavigationTabs = this.hiddenNavigationTabs.filter(
        (candidate: NavigationTabId) => candidate !== id);
      this.saveNavigationPreferences();
    }
    this.syncNavigationSelection(id, true);
  }

  private syncNavigationSelection(preferredId: NavigationTabId, changeController: boolean): void {
    this.tabChangeRequestId++;
    const visible: NavigationTabId[] = this.visibleNavigationTabs();
    if (visible.length === 0) {
      this.hiddenNavigationTabs = [...DEFAULT_NAVIGATION_HIDDEN];
      this.navigationOrder = [...DEFAULT_NAVIGATION_ORDER];
      return;
    }
    const selectedId: NavigationTabId = visible.includes(preferredId) ? preferredId : visible[0];
    const selectedIndex: number = visible.indexOf(selectedId);
    if (selectedId !== this.activeNavigationId) {
      this.invalidateRemoteStreamLaunch();
      this.navigationRevision++;
    }
    this.activeNavigationId = selectedId;
    this.settingsDetailActive = selectedId === 'settings' && this.settingsPathStack.size() > 0;
    this.activeTab = selectedIndex;
    this.publishFilesTabActive(selectedIndex);
    this.updateCacheSizePolling(selectedIndex);
    this.syncHomeLatencyRefreshPolling();
    this.syncTransferProtocolRefreshPolling();
    if (this.currentTab !== selectedIndex) {
      this.currentTab = selectedIndex;
      if (changeController) {
        this.tabsController.changeIndex(selectedIndex);
      }
    }
  }

  private scheduleNavigationTabChange(index: number, committed: boolean): void {
    const id: NavigationTabId | undefined = this.navigationTabAt(index);
    if (id === undefined) {
      return;
    }
    const requestId: number = ++this.tabChangeRequestId;
    // HdsTabs can emit its callbacks while reconciling the controlled index.
    // Apply state changes after that render, and discard superseded callbacks.
    this.scheduleLifecycleTask(() => {
      if (requestId === this.tabChangeRequestId && this.navigationTabAt(index) === id) {
        this.handleNavigationTabChange(index, committed);
      }
    }, 0);
  }

  private handleNavigationTabChange(index: number, committed: boolean): void {
    const id: NavigationTabId | undefined = this.navigationTabAt(index);
    if (id === undefined) {
      return;
    }
    if (id === this.activeNavigationId && index === this.activeTab &&
      (!committed || index === this.currentTab)) {
      return;
    }
    if (id !== this.activeNavigationId) {
      this.invalidateRemoteStreamLaunch();
      this.navigationRevision++;
    }
    this.activeNavigationId = id;
    if (id === 'settings') {
      // A tab swipe is a navigation to the Settings home, not a restore of
      // the previously open second-level settings destination.
      this.settingsPathStack.clear();
      this.settingsDetailActive = false;
    } else {
      this.settingsDetailActive = false;
    }
    this.activeTab = index;
    if (committed && this.currentTab !== index) {
      this.currentTab = index;
    }
    this.publishFilesTabActive(index);
    this.updateCacheSizePolling(index);
    this.syncHomeLatencyRefreshPolling();
    this.syncTransferProtocolRefreshPolling();
  }

  private handleNavigationTabClick(index: number): void {
    if (this.navigationTabAt(index) !== undefined) {
      this.invalidateRemoteStreamLaunch();
      this.navigationRevision++;
    }
  }

  private publishFilesTabActive(index: number): void {
    const active: boolean = this.navigationTabAt(index) === 'files';
    AppStorage.setOrCreate('taildriveFilesTabActive', active);
    if (active) {
      // Keep the existing file browser after its first real selection so that
      // returning from Settings preserves the directory and in-flight actions.
      this.filesPageActivated = true;
    }
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
    if (!this.appShellReady || !this.securityPreferencesReady || this.appLockRequired) {
      return;
    }
    if (this.taildropOpenInbox > 0) {
      AppStorage.setOrCreate('taildropOpenInbox', 0);
      this.scheduleExternalTabNavigation(1);
    }
  }

  private onSystemShare(): void {
    const draft: SharedFileDraft | undefined = SystemShareInbox.first();
    this.sharedFileCount = draft?.uris.length ?? 0;
    this.sharedFileSummary = typeof SystemShareInbox.summarizeFileNames === 'function' ?
      SystemShareInbox.summarizeFileNames(draft) : '';
    if (this.sharedFileCount > 0 && this.appShellReady) {
      this.scheduleExternalTabNavigation(1);
    }
  }

  private onSystemShareError(): void {
    if (this.systemShareError > 0 && this.appShellReady) {
      AppStorage.setOrCreate('systemShareError', 0);
      this.showToast($r('app.string.system_share_invalid'));
    }
  }

  private async sendSharedFiles(target: TaildropTargetSummary): Promise<void> {
    const draft: SharedFileDraft | undefined = SystemShareInbox.first();
    if (draft === undefined || this.sharedFileSending || this.appLockRequired ||
      this.appLockAuthenticating || !this.ensureTaildropSendAvailable(target)) { return; }
    this.sharedFileSending = true;
    const generation: number = this.lifecycleGeneration;
    try {
      if (await this.queueTaildropFiles(target, draft.uris)) {
        SystemShareInbox.remove(draft.id);
      }
    } finally {
      if (generation === this.lifecycleGeneration) { this.sharedFileSending = false; }
    }
  }

  private onTaildropNotificationAction(): void {
    this.taildropSessionController.onTaildropNotificationAction();
  }

  private toggleControlServerEditor(): void {
    const visible: boolean = !this.controlServerEditorVisible;
    this.controlServerEditorVisible = visible;
    this.recordDiagnosticEvent(visible ? 'control_server_editor_opened' :
      'control_server_editor_closed', 'account');
  }

  private saveControlServer(): void {
    if (!this.canSwitchControlServer()) {
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

  private canSwitchControlServer(): boolean {
    return this.vpnSessionController.canSwitchControlServer();
  }

  private selectControlServerPreset(index: number): void {
    if (!this.canSwitchControlServer() || index < 0 || index >= this.controlServerPresets.length) return;
    this.controlServerInput = this.controlServerPresets[index].controlURL;
    this.saveControlServer();
  }

  private controlServerPresetOptions(): SelectOption[] {
    return this.controlServerPresets.map((server: ControlServerPreset): SelectOption => ({
      value: server.controlURL === DEFAULT_CONTROL_SERVER_URL ? 'Tailscale' : server.controlURL
    }));
  }

  private selectedControlServerPreset(): number {
    return Math.max(0, this.controlServerPresets.findIndex(
      (server: ControlServerPreset) => server.controlURL === this.controlServerURL));
  }

  private persistControlServer(normalized: string): void {
    this.vpnSessionController.persistControlServer(normalized);
  }

  private controlServerEpoch: number = 0;

  private clearControlServerPresentation(): void {
    this.controlServerEpoch++;
    this.backendStatus = 'STOPPED';
    this.networkSettings = { routeAll: true, exitNodeAllowLANAccess: false };
    this.networkSettingStatus = '';
    this.accountRequestGuard.invalidate();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.vpnSessionController.clearControlServerIpcFiles(context.filesDir);
    this.vpnStatus = 'HarmonyOS VPN Extension stopped';
    this.hasAuthenticatedSession = false;
    this.deviceDetailVisible = false;
    this.resetStreamingStatesForDisconnect();
    this.applyPeers([]);
    this.exitNodes = [];
    this.authKeyInput = '';
    this.authKeyStatus = '';
    this.authKeyLoginVisible = false;
    this.loginHandoffStatus = 'Secure Login Pending';
    this.applyAccountSummary({ displayName: '', loginName: '', profilePicURL: '', tailnetName: '',
      deviceName: '', addresses: [], needsApproval: false, keyExpired: false, keyExpiryUnixMs: 0 });
    this.taildriveTargetMachineName = '';
    this.taildriveTargetRequestId = 0;
    this.remoteFilesNavigationRequestId++;
    this.fileTransferMethodVisible = false;
    this.mediaMethodVisible = false;
    this.taildropFocusedTargetKey = '';
    this.taildropPendingFocusTargetKey = '';
    this.taildropSessionController.resetForControlServerSwitch();
  }

  private loadAccountProfiles(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const state: ServerAccountProfiles = AccountProfiles.ensure(context.filesDir, this.controlServerURL);
      this.accountProfiles = state.profiles;
      this.accountProfileId = state.activeId;
      this.accountProfileStatus = '';
    } catch (_error) {
      this.accountProfiles = [];
      this.accountProfileId = '';
      this.accountProfileStatus = 'failed';
    }
  }

  private accountProfileLabel(profile: AccountProfile, index: number): string {
    if (profile.label.length > 0) return `${profile.label} · ${index + 1}`;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return context.resourceManager.getStringSync($r('app.string.account_profile_number').id, index + 1);
  }

  private accountProfileOptions(): SelectOption[] {
    return this.accountProfiles.map((profile: AccountProfile, index: number): SelectOption => ({
      value: this.accountProfileLabel(profile, index)
    }));
  }

  private activeAccountProfileLabel(): string {
    const index: number = this.accountProfiles.findIndex((item: AccountProfile) => item.id === this.accountProfileId);
    return index >= 0 ? this.accountProfileLabel(this.accountProfiles[index], index) : '';
  }

  private stopWaitingForAccountLogin(): void {
    this.vpnSessionController.stopWaitingForAccountLogin();
  }

  private persistAccountProfile(id: string, create: boolean = false): void {
    this.vpnSessionController.persistAccountProfile(id, create);
  }

  private serverFilesRoot(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return AccountProfiles.cacheRoot(context.filesDir, context.filesDir, this.controlServerURL, this.accountProfileId);
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

  private startBackend(showInitialization: boolean = true, serverSwitchOwner: boolean = false): void {
    this.vpnSessionController.startBackend(showInitialization, serverSwitchOwner);
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
    await this.vpnSessionController.refreshBackendStatus();
  }

  private refreshExitNodes(): void {
    this.vpnSessionController.refreshExitNodes();
  }

  private queueExitNodeUpdate(id: string): void {
    this.vpnSessionController.queueExitNodeUpdate(id);
  }

  private refreshNetworkSettings(): void {
    this.vpnSessionController.refreshNetworkSettings();
  }

  private toggleTailnetDns(): void {
    if (!this.appShellReady || !this.remoteStreamAppInForeground || !this.securityPreferencesReady ||
      this.isConnected() || this.isConnecting() || !this.isAuthenticated() ||
      this.appLockRequired || this.appLockAuthenticating || this.securitySettingsAuthenticating) return;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const enabled: boolean = !this.tailnetDnsEnabled;
      if (!TailnetDnsPreferences.save(context.filesDir, enabled)) {
        this.showToast($r('app.string.network_setting_failed'));
        return;
      }
      this.tailnetDnsEnabled = enabled;
    } catch (_error) { this.showToast($r('app.string.network_setting_failed')); }
  }

  private canEditCustomDns(): boolean {
    return this.appShellReady && this.remoteStreamAppInForeground && this.securityPreferencesReady &&
      !this.appLockRequired && !this.appLockAuthenticating && !this.securitySettingsAuthenticating &&
      !this.isConnected() && !this.isConnecting() && this.isAuthenticated();
  }

  private saveCustomDns(): void {
    if (!this.canEditCustomDns()) return;
    const primary: string = this.dnsPrimaryInput.trim();
    const secondary: string = this.dnsSecondaryInput.trim();
    if ((this.dnsSettingsEnabled && primary.length === 0) ||
      (primary.length > 0 && !DnsSettingsStore.isValidAddress(primary))) {
      this.dnsSettingsStatus = 'invalid_primary';
      return;
    }
    if (secondary.length > 0 && !DnsSettingsStore.isValidAddress(secondary)) {
      this.dnsSettingsStatus = 'invalid_secondary';
      return;
    }
    const raw: string[] = this.dnsSearchDomainsInput.split(',').map((value: string) => value.trim())
      .filter((value: string) => value.length > 0);
    if (!DnsSettingsStore.isValidSearchDomains(raw)) {
      this.dnsSettingsStatus = 'invalid_domains';
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const saved: DnsSettings | undefined = DnsSettingsStore.save(context.filesDir, {
      enabled: this.dnsSettingsEnabled, primary: primary, secondary: secondary,
      searchDomains: DnsSettingsStore.parseSearchDomains(this.dnsSearchDomainsInput)
    });
    if (saved === undefined) { this.dnsSettingsStatus = 'failed'; return; }
    this.dnsPrimaryInput = saved.primary;
    this.dnsSecondaryInput = saved.secondary;
    this.dnsSearchDomainsInput = DnsSettingsStore.formatSearchDomains(saved.searchDomains);
    this.dnsSettingsStatus = 'saved';
  }

  private customDnsStatusText(): ResourceStr {
    switch (this.dnsSettingsStatus) {
      case 'saved': return $r('app.string.setting_dns_saved');
      case 'invalid_primary': return $r('app.string.setting_dns_invalid_primary');
      case 'invalid_secondary': return $r('app.string.setting_dns_invalid_secondary');
      case 'invalid_domains': return $r('app.string.setting_dns_invalid_search_domains');
      default: return $r('app.string.setting_dns_save_failed');
    }
  }

  private toggleNetworkSetting(key: NetworkSettingKey): void {
    this.vpnSessionController.toggleNetworkSetting(key);
  }

  private openSecureLogin(): void {
    this.vpnSessionController.openSecureLogin();
  }

  private toggleAuthKeyLogin(): void {
    this.vpnSessionController.toggleAuthKeyLogin();
  }

  private async submitAuthKeyLogin(): Promise<void> {
    await this.vpnSessionController.submitAuthKeyLogin();
  }

  private authKeyStatusText(): ResourceStr {
    switch (this.authKeyStatus) {
      case 'empty': return $r('app.string.auth_key_empty');
      case 'invalid': return $r('app.string.auth_key_invalid');
      case 'management_key': return $r('app.string.auth_key_management_key');
      case 'loading': return $r('app.string.auth_key_loading');
      case 'timeout': return $r('app.string.auth_key_timeout');
      case 'rejected': return $r('app.string.auth_key_rejected');
      case 'backend_not_ready': return $r('app.string.auth_key_backend_not_ready');
      case 'authenticated': return $r('app.string.auth_key_success');
      case 'needs_approval': return $r('app.string.auth_key_needs_approval');
      default: return $r('app.string.auth_key_failed');
    }
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

    // Keep openLink and the explicit URL Want as compatibility fallbacks for
    // devices whose type-based browser resolver is unavailable.
    try {
      await context.openLink(authUrl, { appLinkingOnly: false });
      return;
    } catch (_error) {
      this.recordDiagnosticEvent('secure_login_browser_open_link_failed', 'handoff');
    }

    // Compatibility fallback for devices whose openLink resolver is unavailable.
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: authUrl,
      entities: ['entity.system.browsable']
    };
    await context.startAbility(want);
  }

  private stopLoginPolling(): void {
    this.vpnSessionController.stopLoginPolling();
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

  private beginVpnConnection(automatic: boolean = false): void {
    this.vpnSessionController.beginVpnConnection(automatic);
  }

  private applyAccountSummary(account: AccountSummary): void {
    this.vpnSessionController.applyAccountSummary(account);
  }

  private stopVpnProbe(): void {
    this.vpnSessionController.stopVpnProbe();
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
    this.cancelVpnAutoRecovery();
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
        this.clearCachedPeerDirectory();
        this.authKeyStatus = '';
        this.authKeyInput = '';
        this.authKeyLoginVisible = false;
        this.loginInProgress = false;
        this.loginPrompt = '';
        this.hasAuthenticatedSession = false;
        this.stopLoginPolling();
        this.applyPeers([]);
        this.exitNodes = [];
        this.exitNodeStatus = $r('app.string.exit_node_status_none');
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

  private refreshNativeStorageSummary(): void {
    this.refreshCacheSize(false);
  }

  private loadAnimationPreferences(context: common.UIAbilityContext): void {
    const lifecycleGeneration: number = this.lifecycleGeneration;
    AnimationPreferences.load(context).then((settings: AnimationSettings) => {
      if (this.lifecycleGeneration === lifecycleGeneration) {
        this.applyAnimationSettings(settings);
      }
    }).catch(() => {
      if (this.lifecycleGeneration === lifecycleGeneration) {
        this.applyAnimationSettings(AnimationPreferences.apply(DEFAULT_ANIMATION_SETTINGS));
      }
    });
  }

  private applyAnimationSettings(settings: AnimationSettings): void {
    const normalized: AnimationSettings = AnimationPreferences.apply(settings);
    this.animationPreset = normalized.preset;
    this.animationDuration = normalized.duration;
    this.animationAmplitude = normalized.amplitude;
    this.animationDamping = normalized.damping;
  }

  private updateAnimationSettings(settings: AnimationSettings): void {
    this.applyAnimationSettings(settings);
    this.pendingAnimationSettings = AnimationPreferences.current();
    if (this.animationPreferencesSaveTimer >= 0) {
      clearTimeout(this.animationPreferencesSaveTimer);
    }
    this.animationPreferencesSaveTimer = setTimeout(() => this.flushAnimationPreferences(), 180);
  }

  private flushAnimationPreferences(): void {
    if (this.animationPreferencesSaveTimer >= 0) {
      clearTimeout(this.animationPreferencesSaveTimer);
      this.animationPreferencesSaveTimer = -1;
    }
    const settings: AnimationSettings | undefined = this.pendingAnimationSettings;
    this.pendingAnimationSettings = undefined;
    if (settings === undefined) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    AnimationPreferences.save(context, settings).catch(() => {
      // Live motion remains active when preference storage is temporarily unavailable.
    });
  }

  private maybeExpireTaildropCache(): void {
    this.taildropSessionController.maybeExpireTaildropCache();
  }

  private taildropWaitingFilesSize(): number {
    return this.taildropSessionController.taildropWaitingFilesSize();
  }

  private cacheClearActive(): boolean {
    return this.taildropSessionController.cacheClearActive();
  }

  private refreshTaildropPreviewAvailabilityAsync(): void {
    this.taildropSessionController.refreshTaildropPreviewAvailabilityAsync();
  }

  private notifyCacheContentsChanged(): void {
    if (typeof this.refreshTaildropPreviewAvailabilityAsync === 'function') {
      this.refreshTaildropPreviewAvailabilityAsync();
    }
    if (this.activeNavigationId !== 'settings' || this.cacheClearInProgress || this.cacheRefreshScheduled) {
      return;
    }
    this.cacheRefreshScheduled = true;
    this.scheduleLifecycleTask(() => {
      this.cacheRefreshScheduled = false;
      this.refreshCacheSize(false);
    }, 80);
  }

  private refreshCacheSize(showLoading: boolean = true): void {
    if (this.cacheClearInProgress) {
      return;
    }
    if (typeof this.refreshTaildropPreviewAvailabilityAsync === 'function') {
      this.refreshTaildropPreviewAvailabilityAsync();
    }
    if (this.cacheSizeRefreshInFlight) {
      this.cacheSizeRefreshPending = true;
      return;
    }
    if (showLoading) {
      this.cacheSizeLoading = true;
    }
    this.cacheSizeRefreshInFlight = true;
    if (!this.storageUsageReady) this.storageScanFailed = false;
    this.storageScanPool.replace([this.lifecycleGeneration], async (generation: number,
      isCurrent: () => boolean): Promise<void> => {
      try {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const usage: StorageUsage = await StorageUsageScanner.measure(context.filesDir, context.cacheDir,
          [TAILDROP_INBOX_DIR_NAME, TAILDROP_HISTORY_MEDIA_DIR_NAME], isCurrent);
        if (!isCurrent() || generation !== this.lifecycleGeneration) return;
        this.nativeStorageAppDataBytes = usage.appData;
        this.nativeStorageReceivedBytes = usage.received;
        this.nativeStorageTemporaryBytes = usage.temporary;
        this.storageUsageReady = true;
        this.storageScanFailed = false;
        this.startStorageRingAnimation();
        this.cacheSizeBytes = usage.received + usage.temporary + this.taildropWaitingFilesSize();
      } catch (error) {
        if (isCurrent() && generation === this.lifecycleGeneration) this.storageScanFailed = true;
        const failure: BusinessError = error as BusinessError;
        hilog.warn(0x0000, 'MeshArcStorage', 'scan failed code=%{public}d', failure.code ?? -1);
        // Keep the last complete result when storage is temporarily unavailable.
      } finally {
        if (isCurrent()) {
          this.cacheSizeRefreshInFlight = false;
          this.cacheSizeLoading = false;
          if (this.cacheSizeRefreshPending) {
            this.cacheSizeRefreshPending = false;
            this.refreshCacheSize(false);
          }
        }
      }
    });
  }

  private startCacheSizePolling(): void {
    if (!this.appShellReady || this.activeNavigationId !== 'settings' || this.cacheSizePollTimer >= 0) {
      return;
    }
    this.refreshCacheSize();
    this.cacheSizePollTimer = setInterval(() => {
      if (this.appShellReady && this.activeNavigationId === 'settings') {
        this.refreshCacheSize(false);
      }
    }, CACHE_SIZE_POLL_INTERVAL_MS);
  }

  private stopCacheSizePolling(): void {
    if (this.cacheSizePollTimer >= 0) {
      clearInterval(this.cacheSizePollTimer);
      this.cacheSizePollTimer = -1;
    }
    this.storageScanPool.cancel();
    this.cacheSizeRefreshInFlight = false;
    this.cacheSizeRefreshPending = false;
    this.cacheSizeLoading = false;
  }

  private updateCacheSizePolling(index: number): void {
    if (this.navigationTabAt(index) === 'settings') {
      this.startCacheSizePolling();
    } else {
      this.stopCacheSizePolling();
    }
  }

  private cacheClearBlocked(): boolean {
    return this.taildropSessionController.cacheClearBlocked();
  }

  private cacheClearEnabled(): boolean {
    return !this.cacheSizeLoading && this.cacheSizeBytes > 0 && !this.cacheClearBlocked();
  }

  private storageAllLocalFilesClearEnabled(): boolean {
    return (this.nativeStorageReceivedBytes > 0 || this.nativeStorageTemporaryBytes > 0) &&
      !this.cacheClearBlocked();
  }

  private confirmClearAppCache(): void {
    if (!this.storageAllLocalFilesClearEnabled()) {
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
        fontColor: $r('app.color.status_error'),
        action: () => this.clearAppCache()
      }
    });
  }

  private clearAppCache(): void {
    this.taildropSessionController.clearAppCache();
  }

  private taildropPreviewCacheAvailable(): boolean {
    return this.taildropSessionController.taildropPreviewCacheAvailable();
  }

  private clearTemporaryStorage(): void {
    this.taildropSessionController.clearTemporaryStorage();
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
    return this.vpnSessionController.refreshVpnProbeStatus();
  }

  private stopConnectionPolling(): void {
    this.vpnSessionController.stopConnectionPolling();
  }

  private clearConnectionCompletionTimer(): void {
    this.vpnSessionController.clearConnectionCompletionTimer();
  }

  private syncHomeTitleCompact(compact: boolean): void {
    if (this.homeTitleCompact === compact) {
      return;
    }
    this.homeTitleCompact = compact;
  }

  private clearCachedPeerDirectory(): void {
    this.vpnSessionController.clearCachedPeerDirectory();
  }

  private refreshPeerSnapshot(allowCachedDirectory: boolean = false): void {
    this.vpnSessionController.refreshPeerSnapshot(allowCachedDirectory);
  }

  private resetTaildropSnapshot(): void {
    this.taildropSessionController.resetTaildropSnapshot();
  }

  private applyBackendTaildropSnapshot(snapshot: TaildropSnapshot): void {
    this.taildropSessionController.applyBackendTaildropSnapshot(snapshot);
  }

  private refreshTaildropSnapshot(connected: boolean = this.isConnected()): void {
    this.taildropSessionController.refreshTaildropSnapshot(connected);
  }

  private startHealthPolling(): void {
    this.vpnSessionController.startHealthPolling();
  }

  private async refreshOrRecoverBackend(generation: number): Promise<void> {
    await this.vpnSessionController.refreshOrRecoverBackend(generation);
  }

  private cancelVpnAutoRecovery(): void {
    this.vpnSessionController.cancelVpnAutoRecovery();
  }

  private stopHealthPolling(): void {
    this.vpnSessionController.stopHealthPolling();
  }

  private startServiceRefreshPolling(): void {
    this.stopServiceRefreshPolling();
    if (!this.appShellReady || !this.remoteStreamAppInForeground) {
      return;
    }
    this.refreshServiceSnapshots();
    this.serviceRefreshTimer = setInterval(() => {
      if (!this.appShellReady || !this.remoteStreamAppInForeground) {
        this.stopServiceRefreshPolling();
        return;
      }
      this.refreshServiceSnapshots();
    }, NORMAL_SERVICE_REFRESH_INTERVAL_MS);
  }

  private stopServiceRefreshPolling(): void {
    if (this.serviceRefreshTimer >= 0) {
      clearInterval(this.serviceRefreshTimer);
      this.serviceRefreshTimer = -1;
    }
  }

  private syncOfflinePeerStatusRefreshPolling(): void {
    if (this.appShellReady && this.remoteStreamAppInForeground &&
      this.isConnected() && this.offlinePeers().length > 0) {
      this.startOfflinePeerStatusRefreshPolling();
    } else {
      this.stopOfflinePeerStatusRefreshPolling();
    }
  }

  private startOfflinePeerStatusRefreshPolling(): void {
    if (!this.appShellReady || !this.remoteStreamAppInForeground ||
      this.offlinePeerStatusRefreshTimer >= 0) {
      return;
    }
    this.offlinePeerStatusRefreshTimer = setInterval(() => {
      if (!this.appShellReady || !this.remoteStreamAppInForeground ||
        !this.isConnected() || this.offlinePeers().length === 0) {
        this.stopOfflinePeerStatusRefreshPolling();
        return;
      }
      this.refreshPeerSnapshot();
    }, OFFLINE_PEER_STATUS_REFRESH_INTERVAL_MS);
  }

  private stopOfflinePeerStatusRefreshPolling(): void {
    if (this.offlinePeerStatusRefreshTimer >= 0) {
      clearInterval(this.offlinePeerStatusRefreshTimer);
      this.offlinePeerStatusRefreshTimer = -1;
    }
  }

  private refreshServiceSnapshots(): void {
    if (this.serviceRefreshInFlight || !this.remoteStreamAppInForeground) {
      return;
    }
    this.serviceRefreshInFlight = true;
    const generation: number = this.lifecycleGeneration;
    this.refreshPeerSnapshot();
    this.refreshTaildropSnapshot(this.isConnected());
    const localSendRefresh: Promise<void> = this.requestLocalSendRefresh();
    localSendRefresh.finally(() => {
      if (generation === this.lifecycleGeneration && this.appShellReady && this.remoteStreamAppInForeground) {
        this.autoProbeConnectedPeerServices(true);
        this.diagnosticServiceLastRefreshMs = Date.now();
        this.logServiceStatusIfChanged();
      }
      this.serviceRefreshInFlight = false;
    });
  }

  private syncHomeLatencyRefreshPolling(): void {
    if (this.appShellReady && this.remoteStreamAppInForeground && this.activeNavigationId === 'home') {
      this.startHomeLatencyRefreshPolling();
    } else {
      this.stopHomeLatencyRefreshPolling();
    }
  }

  private startHomeLatencyRefreshPolling(): void {
    this.stopHomeLatencyRefreshPolling();
    if (!this.appShellReady || !this.remoteStreamAppInForeground) {
      return;
    }
    this.refreshHomeLatency();
    this.homeLatencyRefreshTimer = setInterval(() => {
      if (!this.appShellReady || !this.remoteStreamAppInForeground || this.activeNavigationId !== 'home') {
        this.stopHomeLatencyRefreshPolling();
        return;
      }
      this.refreshHomeLatency();
    }, FAST_REFRESH_INTERVAL_MS);
  }

  private stopHomeLatencyRefreshPolling(): void {
    if (this.homeLatencyRefreshTimer >= 0) {
      clearInterval(this.homeLatencyRefreshTimer);
      this.homeLatencyRefreshTimer = -1;
    }
  }

  private refreshHomeLatency(): void {
    this.peerIntegrationController.refreshHomeLatency();
  }

  private syncTransferProtocolRefreshPolling(): void {
    if (this.appShellReady && this.remoteStreamAppInForeground && this.activeNavigationId === 'transfer') {
      this.startTransferProtocolRefreshPolling();
    } else {
      this.stopTransferProtocolRefreshPolling();
    }
  }

  private startTransferProtocolRefreshPolling(): void {
    this.stopTransferProtocolRefreshPolling();
    if (!this.appShellReady || !this.remoteStreamAppInForeground) {
      return;
    }
    this.refreshTransferProtocolStatus(false);
    this.transferProtocolRefreshTimer = setInterval(() => {
      if (!this.appShellReady || !this.remoteStreamAppInForeground || this.activeNavigationId !== 'transfer') {
        this.stopTransferProtocolRefreshPolling();
        return;
      }
      this.refreshTransferProtocolStatus(false);
    }, FAST_REFRESH_INTERVAL_MS);
  }

  private stopTransferProtocolRefreshPolling(): void {
    if (this.transferProtocolRefreshTimer >= 0) {
      clearInterval(this.transferProtocolRefreshTimer);
      this.transferProtocolRefreshTimer = -1;
    }
  }

  private refreshTransferProtocolStatus(manual: boolean = true): void {
    this.peerIntegrationController.refreshTransferProtocolStatus(manual);
  }

  private handleTransferProtocolRefreshClick(): void {
    this.peerIntegrationController.handleTransferProtocolRefreshClick();
  }

  private async requestLocalSendRefresh(): Promise<void> {
    await this.peerIntegrationController.requestLocalSendRefresh();
  }

  private isConnected(): boolean {
    return this.vpnSessionController.isConnected();
  }

  private isConnecting(): boolean {
    return this.vpnSessionController.isConnecting();
  }

  private needsLogin(): boolean {
    return this.vpnSessionController.needsLogin();
  }

  private hasConnectionProblem(): boolean {
    return this.vpnSessionController.hasConnectionProblem();
  }

  private isAuthenticated(): boolean {
    return this.hasAuthenticatedSession;
  }

  private isBackendLoading(): boolean {
    return this.vpnSessionController.isBackendLoading();
  }

  private recordDiagnosticEvent(event: string, phase: string, code: number = 0): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.accountDiagnosticsGateway.recordEvent(context, event, phase, code);
    } catch (_error) {
      // Diagnostic events are best-effort and must not alter app behavior.
    }
  }

  @State feedbackEmailStatus: string = '';
  private feedbackEmailGateway: FeedbackEmailGateway = new FeedbackEmailGateway();

  private async generateDiagnosticReport(forEmail: boolean = false): Promise<void> {
    if (this.diagnosticReportInProgress || !this.canUseStandaloneDiagnostics()) {
      return;
    }
    const requestGeneration: number = this.diagnosticReportRequestGuard.begin();
    this.diagnosticReportInProgress = true;
    if (forEmail) this.feedbackEmailStatus = 'preparing';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.diagnosticReportStatus = context.resourceManager.getStringSync(
        $r('app.string.diagnostic_report_generating').id);
      this.recordDiagnosticEvent('diagnostic_report_requested', 'generate');
      if (this.isConnected()) { await PathDiagnosticService.request(context.filesDir, 'snapshot'); }
      if (!this.diagnosticReportRequestGuard.isCurrent(requestGeneration) ||
        !this.canUseStandaloneDiagnostics()) return;
      const input: DiagnosticReportInput = {
        appVersion: this.appVersion,
        appVersionCode: this.appVersionCode,
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
        exitNodeAllowLANAccess: this.networkSettings.exitNodeAllowLANAccess,
        quickTransferDiagnosticsEnabled: this.diagnosticQuickTransferEnabled,
        serviceMonitoringDiagnosticsEnabled: this.diagnosticServiceMonitoringEnabled,
        securityDiagnosticsEnabled: this.diagnosticSecurityEnabled,
        appearanceDiagnosticsEnabled: this.diagnosticAppearanceEnabled,
        localSendAvailableCount: this.localSendStateCount('available'),
        localSendCheckingCount: this.localSendStateCount('checking'),
        localSendUnavailableCount: this.localSendStateCount('unavailable') +
          this.localSendStateCount('offline'),
        meshArcReceiverState: this.meshArcReceiver.state,
        meshArcReceiverProtocol: this.meshArcReceiver.protocol ?? 'unknown',
        meshArcReceiverSentCount: this.meshArcReceiver.sent,
        meshArcReceiverRegisteredCount: this.meshArcReceiver.registered,
        mediaAvailablePeerCount: this.mediaAvailablePeerCount(),
        mediaServiceCount: this.mediaServiceCount(),
        hosPlayerSelfTestState: this.hosPlayerSelfTestState(),
        serviceMonitoringActive: this.serviceRefreshTimer >= 0,
        serviceRefreshInProgress: this.serviceRefreshInFlight || this.diagnosticFeatureRefreshInProgress,
        serviceLastRefreshAgeSeconds: this.diagnosticServiceLastRefreshMs > 0 ?
          Math.max(0, Math.floor((Date.now() - this.diagnosticServiceLastRefreshMs) / 1000)) : 0,
        mediaCheckingPeerCount: this.mediaCheckingPeerCount(),
        sunshineAvailablePeerCount: this.sunshineAvailablePeerCount(),
        sunshineCheckingPeerCount: this.sunshineCheckingPeerCount(),
        taildropState: this.taildropState,
        appLockEnabled: this.appLockEnabled,
        folderLockEnabled: this.folderLockEnabled,
        lockedFolderCount: this.lockedFolderPaths.length,
        appLockRequired: this.appLockRequired,
        securityAuthenticationInProgress: this.appLockAuthenticating ||
          this.securitySettingsAuthenticating || this.diagnosticSecuritySelfTestInProgress,
        customBackgroundEnabled: this.nativeSettingsBackgroundUri.length > 0,
        immersiveColorEnabled: this.immersiveColorBackgroundEnabled,
        glowLevel: this.glowLevel,
        homeLayoutMode: this.connectedHomeLayoutMode,
        visibleNavigationTabCount: this.visibleNavigationTabs().length,
        navigationBottomMargin: this.navigationBottomMargin
      };
      const result: DiagnosticReportResult = await this.accountDiagnosticsGateway.generateReport(context, input);
      if (!this.diagnosticReportRequestGuard.isCurrent(requestGeneration)) {
        return;
      }
      if (!this.canUseStandaloneDiagnostics()) return;
      const sizeKb: number = Math.max(1, Math.ceil(result.size / 1024));
      this.diagnosticReportStatus = `${result.fileName} (${sizeKb} KB)`;
      this.recordDiagnosticEvent('diagnostic_report_generated', 'share');
      if (forEmail) {
        this.recordDiagnosticEvent('feedback_email_handoff', 'template');
        const subject: string = context.resourceManager.getStringSync(
          $r('app.string.feedback_email_subject').id, this.appVersion, this.appVersionCode);
        const body: string = FeedbackEmailTemplate.render(
          context.resourceManager.getStringSync($r('app.string.feedback_email_body').id), result.feedbackContext,
          context.resourceManager.getStringSync($r('app.string.feedback_email_yes').id),
          context.resourceManager.getStringSync($r('app.string.feedback_email_no').id),
          context.resourceManager.getStringSync($r('app.string.feedback_email_unknown').id));
        await this.feedbackEmailGateway.open(context, result, FEEDBACK_EMAIL, subject, body,
          (code: number): void => this.feedbackEmailFailed(requestGeneration, code),
          (stage: string): void => this.recordDiagnosticEvent('feedback_email_handoff', stage));
        if (!this.diagnosticReportRequestGuard.isCurrent(requestGeneration)) return;
        if (this.feedbackEmailStatus !== 'failed') this.feedbackEmailStatus = 'opened';
        this.recordDiagnosticEvent('feedback_email_compose_requested', 'attachment');
      } else {
        await this.accountDiagnosticsGateway.shareReport(context, result);
        if (!this.diagnosticReportRequestGuard.isCurrent(requestGeneration)) return;
        this.recordDiagnosticEvent('diagnostic_share_opened', 'system');
      }
    } catch (error) {
      if (!this.diagnosticReportRequestGuard.isCurrent(requestGeneration)) {
        return;
      }
      const businessError = error as BusinessError;
      if (forEmail) this.feedbackEmailFailed(requestGeneration, businessError?.code ?? -1);
      this.recordDiagnosticEvent('diagnostic_report_failed', 'generate', businessError?.code ?? -1);
      this.diagnosticReportStatus = 'Diagnostic report unavailable';
    } finally {
      if (this.diagnosticReportRequestGuard.isCurrent(requestGeneration)) {
        this.diagnosticReportInProgress = false;
        if (forEmail && this.feedbackEmailStatus === 'preparing') this.feedbackEmailStatus = '';
      }
    }
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
          action: () => this.vpnSessionController.acknowledgeVpnConflict()
        }
      });
    } catch (_error) {
      this.vpnConflictDialogVisible = false;
      this.vpnSessionController.finishVpnConflictCancellation(
        !this.vpnSessionController.vpnBackendWasRunningBeforeConnect
      );
    }
  }

  private onlinePeerCount(): number {
    return this.onlinePeers().length;
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

  private taildropTargetForPeer(peer: PeerSummary): TaildropTargetSummary | undefined {
    return this.displayedTaildropTargets().find((target: TaildropTargetSummary) => target.key === peer.key);
  }

  private taildropTargetAvailableForPeer(peer: PeerSummary): boolean {
    return this.taildropTargetForPeer(peer) !== undefined;
  }

  private taildropTargetOnlineForPeer(peer: PeerSummary): boolean {
    return this.taildropTargetForPeer(peer)?.online === true;
  }

  private taildropTargetReadyForPeer(peer: PeerSummary): boolean {
    return this.isConnected() && this.taildropState === 'ready' &&
      this.taildropTargetOnlineForPeer(peer);
  }

  private localSendAvailableForPeer(peer: PeerSummary): boolean {
    const current: PeerSummary | undefined = this.peers.find((item: PeerSummary) => item.key === peer.key);
    return this.isConnected() && current !== undefined && this.peerEffectivelyOnline(current) &&
      current.localSend?.state === 'available';
  }

  private localSendStatusForPeer(peerKey: string): LocalSendStatus | undefined {
    // A stable ForEach key keeps the detail sheet and its original peer
    // closure mounted. Read the observed directory to receive later probes.
    return this.peers.find((peer: PeerSummary) => peer.key === peerKey)?.localSend;
  }

  private deviceDetailRenderKey(peer: PeerSummary): string {
    // Keep the sheet instance stable while polling updates its @Prop values;
    // changing this key recreates the capsule and replays its transition.
    return peer.key;
  }

  private deviceDetailPeer(peerKey: string): PeerSummary | undefined {
    return this.peers.find((peer: PeerSummary) => peer.key === peerKey);
  }

  private deviceDetailAddress(peerKey: string): string {
    const peer: PeerSummary | undefined = this.deviceDetailPeer(peerKey);
    return peer === undefined ? '' : this.primaryTailscaleAddress(peer.addresses);
  }

  private deviceDetailExitNodeCapable(peerKey: string): boolean {
    return this.deviceDetailPeer(peerKey)?.exitNode === true;
  }

  private deviceDetailSunshineCandidate(peerKey: string): boolean {
    const peer: PeerSummary | undefined = this.deviceDetailPeer(peerKey);
    return peer !== undefined && this.isSunshineCandidate(peer);
  }

  private withCurrentDeviceDetailPeer(peerKey: string, action: (peer: PeerSummary) => void): void {
    if (!this.appShellReady || !this.deviceDetailVisible || this.selectedPeerKey !== peerKey ||
      this.appLockRequired || this.appLockAuthenticating) return;
    const peer: PeerSummary | undefined = this.deviceDetailPeer(peerKey);
    if (peer !== undefined) action(peer);
  }

  private copyDeviceDetailAddress(peerKey: string): void {
    this.withCurrentDeviceDetailPeer(peerKey, (peer: PeerSummary): void => {
      const address: string = this.primaryTailscaleAddress(peer.addresses);
      if (address.length > 0) this.copyDeviceValue(address, $r('app.string.peer_ip_copied'));
    });
  }

  private transferTargetRenderKey(target: TaildropTargetSummary): string {
    const peer: PeerSummary | undefined = this.peerForFileTransferKey(target.key);
    return `${target.key}|taildrop=${this.taildropProtocolState(target)}|device=` +
      `${this.transferTargetDeviceOffline(target) ? 'offline' : 'online'}|localsend=` +
      `${this.localSendProtocolState(peer)}|choices=${this.taildropFileChoicesVisible(target, peer) ? 'media' : 'file'}`;
  }

  private localSendOnlyTargetRenderKey(peer: PeerSummary): string {
    const current: PeerSummary = this.peerForFileTransferKey(peer.key) ?? peer;
    return `${current.key}|device=${this.isConnected() && this.peerEffectivelyOnline(current) ? 'online' : 'offline'}` +
      `|localsend=${this.localSendProtocolState(current)}`;
  }

  private localSendAvailablePeers(): PeerSummary[] {
    return this.peers.filter((peer: PeerSummary) => this.localSendAvailableForPeer(peer));
  }

  private localSendCheckingPeerCount(): number {
    return this.isConnected() ? this.peers.filter((peer: PeerSummary) =>
      this.peerEffectivelyOnline(peer) && peer.localSend?.state === 'checking').length : 0;
  }

  private localSendOnlyPeers(): PeerSummary[] {
    return this.localSendAvailablePeers().filter((peer: PeerSummary) =>
      !this.taildropTargetAvailableForPeer(peer));
  }

  private fileTransferOnlineTargetCount(): number {
    return this.peers.filter((peer: PeerSummary) => {
      const capabilities: FileTransferCapabilities = this.fileTransferCapabilitiesForPeer(peer);
      return capabilities.tailsend || capabilities.localSend;
    }).length;
  }

  private fileTransferCapabilitiesForPeer(peer: PeerSummary): FileTransferCapabilities {
    const capabilities: FileTransferCapabilities = {
      tailsend: this.taildropTargetReadyForPeer(peer),
      localSend: this.localSendAvailableForPeer(peer)
    };
    return capabilities;
  }

  private fileTransferSelectionPeer(): PeerSummary | undefined {
    return this.peers.find((peer: PeerSummary) => peer.key === this.fileTransferMethodPeerKey);
  }

  private peerForFileTransferKey(key: string): PeerSummary | undefined {
    return this.peers.find((peer: PeerSummary) => peer.key === key);
  }

  private fileTransferSelectionPeerName(): string {
    const peer: PeerSummary | undefined = this.fileTransferSelectionPeer();
    return peer === undefined ? '' : this.peerDisplayName(peer.name);
  }

  private mediaMethodSelectionPeer(): PeerSummary | undefined {
    return this.peers.find((peer: PeerSummary) => peer.key === this.mediaMethodPeerKey);
  }

  private mediaMethodSelectionPeerName(): string {
    const peer: PeerSummary | undefined = this.mediaMethodSelectionPeer();
    return peer === undefined ? '' : this.peerDisplayName(peer.name);
  }

  private mediaMethodSelectionService(): DiscoveredMediaService | undefined {
    const peer: PeerSummary | undefined = this.mediaMethodSelectionPeer();
    return peer === undefined ? undefined : this.mediaState(peer.key).result.services[0];
  }

  private openMediaMethodForPeer(peer: PeerSummary): void {
    const state: DeviceMediaState = this.mediaState(peer.key);
    if (state.checking || state.launching) {
      return;
    }
    if (state.result.services.length === 0) {
      this.detectMediaForPeer(peer, true);
      return;
    }
    this.mediaMethodPeerKey = peer.key;
    this.deviceDetailVisible = false;
    this.mediaMethodVisible = true;
  }

  private launchSelectedMediaWithHosPlayer(): void {
    const peer: PeerSummary | undefined = this.mediaMethodSelectionPeer();
    const service: DiscoveredMediaService | undefined = this.mediaMethodSelectionService();
    if (peer === undefined || service === undefined) {
      return;
    }
    this.mediaMethodVisible = false;
    this.openHosPlayer(peer, service);
  }

  private fileTransferSelectionSupports(transport: FileTransferTransport): boolean {
    const peer: PeerSummary | undefined = this.fileTransferSelectionPeer();
    if (peer === undefined) {
      return false;
    }
    const capabilities: FileTransferCapabilities = this.fileTransferCapabilitiesForPeer(peer);
    return transport === 'tailsend' ? capabilities.tailsend : capabilities.localSend;
  }

  private preferredFileTransferTransport(): FileTransferTransport | undefined {
    if (this.meshSendPreferredTransport === 'localsend') {
      return 'localsend';
    }
    if (this.meshSendPreferredTransport === 'tailsend') {
      return 'tailsend';
    }
    return undefined;
  }

  private targetSupportsBothTransfers(key: string): boolean {
    const peer: PeerSummary | undefined = this.peerForFileTransferKey(key);
    if (peer === undefined) {
      return false;
    }
    const capabilities: FileTransferCapabilities = this.fileTransferCapabilitiesForPeer(peer);
    return capabilities.tailsend && capabilities.localSend;
  }

  private openFileTransferMethodForTarget(key: string): void {
    const peer: PeerSummary | undefined = this.peerForFileTransferKey(key);
    if (peer === undefined) {
      return;
    }
    this.fileTransferMethodPeerKey = peer.key;
    this.fileTransferMethodVisible = true;
  }

  private remoteCachedPeers(): PeerSummary[] {
    if (this.isConnected()) {
      return [];
    }
    return this.peers.filter((peer: PeerSummary) => peer.name.length > 0);
  }

  private localSendPortOverrideForPeer(peerKey: string): number | undefined {
    return this.peerIntegrationController.localSendPortOverrideForPeer(peerKey);
  }

  private localSendPortForPeer(peer: PeerSummary): number {
    return this.peerIntegrationController.localSendPortForPeer(peer);
  }

  private remoteCachedPeerDescription(peer: PeerSummary): ResourceStr {
    if (!peer.online) {
      return $r('app.string.peer_offline');
    }
    if (!this.isConnected()) {
      return $r('app.string.transfer_remote_waiting_connection');
    }
    if (!this.peerEffectivelyOnline(peer)) {
      return $r('app.string.peer_offline');
    }
    if (peer.localSend?.state === 'available') {
      return $r('app.string.transfer_remote_localsend_port', this.localSendPortForPeer(peer));
    }
    if (peer.localSend?.state === 'unavailable') {
      return $r('app.string.transfer_remote_service_unavailable_description');
    }
    return $r('app.string.transfer_remote_waiting_description');
  }

  private remoteCachedPeerIsOffline(peer: PeerSummary): boolean {
    return !peer.online || (this.isConnected() && !this.peerEffectivelyOnline(peer));
  }

  private remotePortEditorPeer(): PeerSummary | undefined {
    return this.peerForFileTransferKey(this.remotePortPeerKey);
  }

  private remotePortEditorPeerName(): string {
    const peer: PeerSummary | undefined = this.remotePortEditorPeer();
    return peer === undefined ? '' : this.peerDisplayName(peer.name);
  }

  private openRemotePortEditor(peer: PeerSummary): void {
    this.remotePortPeerKey = peer.key;
    this.remotePortInput = this.localSendPortForPeer(peer).toString();
    this.remotePortEditorVisible = true;
  }

  private saveRemotePortOverride(): void {
    this.peerIntegrationController.saveRemotePortOverride();
  }

  private openRemoteCachedPeer(peer: PeerSummary): void {
    if (peer.localSend?.state === 'available') {
      this.openLocalSendFromDevice(peer);
      return;
    }
    this.showToast(this.remoteCachedPeerDescription(peer));
  }

  private displayedTaildropTargets(): TaildropTargetSummary[] {
    return this.taildropTargets;
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
    return selectPrimaryTailscaleAddress(addresses);
  }

  private peerDisplayName(name: string): string {
    return formatPeerDisplayName(name);
  }

  private deviceDetailMagicDnsName(peerKey: string): string {
    if (!this.tailnetDnsEnabled) return '';
    const peer: PeerSummary | undefined = this.peers.find((item: PeerSummary) => item.key === peerKey);
    const name: string = (peer?.name ?? '').replace(/\.$/, '');
    return name.includes('.') && DnsSettingsStore.isValidSearchDomain(name) &&
      !DnsSettingsStore.isValidAddress(name) ? name : '';
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

  private resetDiagnosticsMode(): void {
    this.diagnosticsUnlocked = false;
    this.diagnosticsExpanded = false;
    this.diagnosticDeviceListVerificationEnabled = false;
    this.diagnosticDeviceListLastClicked = '';
    this.diagnosticsTapCount = 0;
    this.diagnosticsLastTapMs = 0;
  }

  private unlockDiagnostics(): void {
    this.diagnosticsUnlocked = true;
    this.diagnosticsExpanded = true;
    this.recordFeatureDiagnosticEvent('feature_diagnostics_unlocked', 'settings');
  }

  private showToast(message: ResourceStr): void {
    try {
      this.getUIContext().getPromptAction().showToast({
        message: message,
        systemMaterial: LightAppearance.toast(this.glowLevel)
      });
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
    this.showToast($r('app.string.diagnostics_unlock_countdown_toast', remainingCount));
  }

  private openUpdateChangelogFromSettings(): void {
    if (this.updateChangelogVisible || this.appLockRequired || this.appLockAuthenticating) {
      return;
    }
    this.updateChangelogShowPending = false;
    this.updateChangelogVisible = true;
    this.recordDiagnosticEvent('update_changelog_opened', 'settings');
  }

  private loadGlowLevel(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.glowLevel = this.settingsPreferencesGateway.loadGlowLevel(context.filesDir, 3);
    } catch (_error) {
      this.glowLevel = 3;
    }
  }

  private setGlowLevel(level: number): void {
    if (level < 0 || level > 3) {
      return;
    }
    this.glowLevel = level;
    this.recordFeatureDiagnosticEvent('appearance_glow_changed', 'level', level);
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.settingsPreferencesGateway.saveGlowLevel(context.filesDir, level);
    } catch (_error) {
      // Visual preferences are best-effort and never affect VPN behavior.
    }
  }

  private glowRadius(): number {
    return LightAppearance.backgroundRadius(this.glowLevel);
  }

  private glowColor(): ResourceColor {
    return $r('app.color.emphasize');
  }

  private glowSurface(): ResourceColor {
    return $r('sys.color.comp_background_tertiary');
  }

  private glowLightColor(): ResourceColor {
    return Color.White;
  }

  private glowSaturation(): number {
    return LightAppearance.backgroundSaturation(this.glowLevel);
  }

  private glowBrightness(): number {
    return LightAppearance.backgroundBrightness(this.glowLevel);
  }

  private glowMaterialLevel(): hdsMaterial.MaterialLevel {
    return LightAppearance.hdsLevel(this.glowLevel);
  }

  private glowMaterialType(): hdsMaterial.MaterialType {
    return LightAppearance.hdsType(this.glowLevel);
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
    return 90 + this.navigationBottomMargin;
  }

  private groupBackground(): ResourceColor {
    return $r('sys.color.comp_background_primary');
  }

  private onlinePeers(): PeerSummary[] {
    return this.peers.filter((peer: PeerSummary) => this.peerEffectivelyOnline(peer));
  }

  private offlinePeers(): PeerSummary[] {
    return this.peers.filter((peer: PeerSummary) => !this.peerEffectivelyOnline(peer));
  }

  private diagnosticDeviceListPeers(): PeerSummary[] {
    const peers: PeerSummary[] = [];
    for (let index: number = 1; index <= 8; index++) {
      peers.push({
        key: `diagnostic-device-list-${index}`,
        name: `Scroll Test Device ${index}`,
        os: 'HarmonyOS',
        osVersion: '6.0',
        deviceModel: `Verification ${index}`,
        deviceType: index % 3 === 0 ? 'tablet' : (index % 2 === 0 ? 'phone' : 'desktop'),
        addresses: [`100.64.255.${index}`],
        online: false,
        exitNode: false,
        keyExpired: false,
        keyExpiryUnixMs: 0
      });
    }
    return peers;
  }

  private homePeers(): PeerSummary[] {
    if (!this.diagnosticDeviceListVerificationEnabled) {
      return this.peers;
    }
    return this.peers.concat(this.diagnosticDeviceListPeers());
  }

  private homeOnlinePeers(): PeerSummary[] {
    return this.homePeers().filter((peer: PeerSummary) => this.peerEffectivelyOnline(peer));
  }

  private homeOfflinePeers(): PeerSummary[] {
    return this.homePeers().filter((peer: PeerSummary) => !this.peerEffectivelyOnline(peer));
  }

  private isDiagnosticDeviceListPeer(peer: PeerSummary): boolean {
    return peer.key.startsWith('diagnostic-device-list-');
  }

  private setDiagnosticDeviceListVerificationEnabled(enabled: boolean): void {
    this.diagnosticDeviceListVerificationEnabled = enabled;
    this.diagnosticDeviceListLastClicked = '';
    this.recordFeatureDiagnosticEvent('device_list_scroll_verification_changed',
      enabled ? 'enabled' : 'disabled');
  }

  private openDiagnosticDeviceListVerification(): void {
    if (!this.diagnosticDeviceListVerificationEnabled) {
      return;
    }
    this.navigateToNavigationTab('home', true);
    this.scheduleLifecycleTask((): void => this.homeScroller.scrollEdge(Edge.Top), 80);
    this.recordFeatureDiagnosticEvent('device_list_scroll_verification_opened', 'home');
  }

  private openHomePeerDetails(peer: PeerSummary): void {
    if (this.isDiagnosticDeviceListPeer(peer)) {
      this.diagnosticDeviceListLastClicked = this.peerDisplayName(peer.name);
      this.recordFeatureDiagnosticEvent('device_list_scroll_verification_clicked', peer.key);
    }
    this.openPeerDetails(peer);
  }

  private peerEffectivelyOnline(peer: PeerSummary): boolean {
    // Presence comes from the current control-plane snapshot. A failed path
    // probe describes temporary reachability; it must not move an online peer
    // into the offline group or prevent the probes needed for recovery.
    return peer.online;
  }

  private peerPathLabel(peer: PeerSummary): ResourceStr {
    if (!this.peerEffectivelyOnline(peer)) {
      return $r('app.string.peer_offline');
    }
    const path: PeerPathResult = this.streamingState(peer.key).path;
    if (path.type === 'direct') {
      return $r('app.string.device_path_direct', path.latencyMs ?? 0);
    }
    if (path.type === 'peerRelay') {
      return $r('app.string.device_path_peer_relay', path.latencyMs ?? 0);
    }
    if (path.type === 'derp') {
      return $r('app.string.device_path_derp_relay', path.latencyMs ?? 0);
    }
    if (path.type === 'unreachable') {
      return $r('app.string.device_path_unreachable');
    }
    return $r('app.string.peer_online');
  }

  private localDeviceCardStatus(): ResourceStr {
    return this.isConnected()
      ? $r('app.string.connection_connected')
      : $r('app.string.connection_disconnected');
  }

  private peerCardStatus(peer: PeerSummary): ResourceStr {
    if (!this.peerEffectivelyOnline(peer)) {
      return $r('app.string.peer_offline');
    }
    if (!this.isConnected()) {
      return $r('app.string.device_connection_waiting');
    }
    const state: DeviceStreamingState = this.streamingState(peer.key);
    const path: PeerPathResult = state.path;
    if (state.checking || path.checkedAt <= 0) {
      return $r('app.string.device_connection_connecting');
    }
    if (path.type === 'direct') {
      return $r('app.string.device_path_direct', path.latencyMs ?? 0);
    }
    if (path.type === 'peerRelay' || path.type === 'derp') {
      return $r('app.string.device_path_relay', path.latencyMs ?? 0);
    }
    if (path.type === 'unreachable' || (path.errorMessage !== undefined &&
      path.errorMessage.length > 0)) {
      return $r('app.string.connection_recovering');
    }
    return $r('app.string.device_connection_connecting');
  }

  private peerCardStatusKey(peer: PeerSummary): string {
    const state: DeviceStreamingState = this.streamingState(peer.key);
    const path: PeerPathResult = state.path;
    return `${this.isConnected()}|${this.peerEffectivelyOnline(peer)}|${state.checking}|` +
      `${path.type}|${path.latencyMs ?? -1}|${path.errorMessage ?? ''}`;
  }

  @Builder
  private PeerCardStatusText(peer: PeerSummary) {
    Stack({ alignContent: Alignment.End }) {
      ForEach([this.peerCardStatusKey(peer)], (_statusKey: string) => {
        Text(this.peerCardStatus(peer))
          .fontSize(12)
          .fontColor(this.peerEffectivelyOnline(peer) ? $r('sys.color.font_secondary') :
            $r('app.color.status_offline'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.End)
          .width('100%')
          .transition(
            TransitionEffect.asymmetric(
              TransitionEffect.OPACITY.animation({
                duration: MotionTokens.duration(STATUS_CROSS_FADE_MS), curve: MotionTokens.curve()
              }),
              TransitionEffect.OPACITY.animation({
                duration: MotionTokens.duration(STATUS_CROSS_FADE_MS), curve: MotionTokens.curve()
              })
            )
          )
      }, (statusKey: string) => statusKey)
    }
    .width(132)
    .height(20)
    .align(Alignment.End)
  }

  private peerUsesSelectedExitNode(peer: PeerSummary): boolean {
    const selectedName: string = this.selectedExitNodeName().toLowerCase();
    return selectedName.length > 0 && (peer.name.toLowerCase() === selectedName ||
      this.peerDisplayName(peer.name).toLowerCase() === selectedName);
  }

  private selectedPeerTitle(): string {
    const peer: PeerSummary | undefined = this.selectedPeerDetails.length > 0 ?
      this.selectedPeerDetails[0] : this.peers.find(
        (item: PeerSummary) => item.key === this.selectedPeerKey);
    return peer === undefined ? '' : this.peerDisplayName(peer.name);
  }

  private peersWithoutTaildropTarget(): PeerSummary[] {
    return this.peers.filter((peer: PeerSummary) => !this.taildropTargetAvailableForPeer(peer));
  }

  private backgroundImageFilePath(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return this.settingsPreferencesGateway.backgroundImageFilePath(context.filesDir);
  }

  private immersiveColorFilePath(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return this.settingsPreferencesGateway.immersiveColorFilePath(context.filesDir);
  }

  private loadAppearancePreferences(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const settings = PersonalizationPreferences.load(context.filesDir);
    this.personalizationColorMode = settings.colorMode;
    this.backgroundBrightnessValue = settings.backgroundBrightness;
    this.backgroundUnavailable = false;
    const overlay: AppearanceOverlaySettings =
      this.settingsPreferencesGateway.loadAppearanceOverlay(context.filesDir);
    this.nativeSettingsBackgroundUri = overlay.backgroundUri;
    this.immersiveColorBackgroundEnabled = overlay.immersiveColorEnabled;
  }

  private saveAppearanceValue(path: string, value: string): boolean {
    return this.settingsPreferencesGateway.writeAppearanceFile(path, value);
  }

  private queuePersonalizationSave(): void {
    this.personalizationSavePending = true;
    if (this.personalizationSaveTimer >= 0) clearTimeout(this.personalizationSaveTimer);
    this.personalizationSaveTimer = setTimeout(() => this.flushPersonalizationPreferences(), 180);
  }

  private flushPersonalizationPreferences(): void {
    if (this.personalizationSaveTimer >= 0) {
      clearTimeout(this.personalizationSaveTimer);
      this.personalizationSaveTimer = -1;
    }
    if (!this.personalizationSavePending) return;
    this.personalizationSavePending = false;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (PersonalizationPreferences.save(context.filesDir, {
        colorMode: this.personalizationColorMode, backgroundBrightness: this.backgroundBrightnessValue
      })) return;
    } catch (_error) {
      // A window can disappear while an appearance save is being flushed.
    }
    // Keep the latest live choice available for a later explicit/lifecycle retry.
    this.personalizationSavePending = true;
    if (this.appShellReady) this.showToast($r('app.string.personalization_save_failed'));
  }

  private setPersonalizationColorMode(index: number): void {
    const mode: AppColorMode = PersonalizationPreferences.colorModeAtIndex(index);
    if (mode === this.personalizationColorMode) {
      this.flushPersonalizationPreferences();
      return;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      PersonalizationPreferences.applyColorMode(context, mode);
      this.personalizationColorMode = mode;
      this.queuePersonalizationSave();
      this.flushPersonalizationPreferences();
    } catch (_error) {
      this.showToast($r('app.string.personalization_apply_failed'));
    }
  }

  private setBackgroundBrightness(value: number, mode: SliderChangeMode): void {
    if (!Number.isFinite(value)) return;
    this.backgroundBrightnessValue = Math.min(100, Math.max(0, Math.round(value)));
    this.queuePersonalizationSave();
    if (mode === SliderChangeMode.End) this.flushPersonalizationPreferences();
  }

  private setImmersiveColorBackground(enabled: boolean): void {
    this.immersiveColorBackgroundEnabled = enabled;
    if (!this.saveAppearanceValue(this.immersiveColorFilePath(), enabled ? '1' : '0')) {
      this.showToast($r('app.string.personalization_save_failed'));
    }
    this.recordFeatureDiagnosticEvent('appearance_immersive_color_changed', enabled ? 'enabled' : 'disabled');
  }

  private clearNativeSettingsBackground(): void {
    // A clear action also withdraws any earlier picker/import still awaiting a result.
    this.backgroundSelectionGeneration++;
    this.nativeSettingsBackgroundPickerInProgress = false;
    if (!this.saveAppearanceValue(this.backgroundImageFilePath(), '')) {
      this.showToast($r('app.string.personalization_save_failed'));
      return;
    }
    const previous: string = this.nativeSettingsBackgroundUri;
    this.nativeSettingsBackgroundUri = '';
    this.backgroundUnavailable = false;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    BackgroundImageStore.removeManaged(context.filesDir, previous);
    this.recordFeatureDiagnosticEvent('appearance_background_changed', 'cleared');
  }

  private onBackgroundImageLoadError(uri: string): void {
    if (!this.appShellReady || uri !== this.nativeSettingsBackgroundUri || this.backgroundUnavailable) return;
    // Retain the saved choice so a temporary read error never deletes the original.
    this.backgroundUnavailable = true;
    this.showToast($r('app.string.personalization_background_unavailable'));
  }

  private pageCanvasBackground(): ResourceColor {
    return this.appBackgroundActive() ? Color.Transparent : $r('sys.color.background_secondary');
  }

  private settingsDetailCanvasBackground(): ResourceColor {
    // Detail destinations sit above the settings home. They need an opaque
    // canvas so an immersive app background cannot reveal that page beneath.
    return $r('sys.color.background_secondary');
  }

  private appBackgroundActive(): boolean {
    return (this.nativeSettingsBackgroundUri.length > 0 && !this.backgroundUnavailable) ||
      this.immersiveColorBackgroundEnabled;
  }

  private immersiveColorTint(): ResourceColor {
    if (this.taildropSendActive() || this.taildropReceiveInProgress) {
      return $r('app.color.immersive_tint_transfer');
    }
    if (this.isConnecting() || this.connectInProgress || this.disconnectInProgress) {
      return $r('app.color.immersive_tint_transition');
    }
    if (this.isConnected()) {
      return $r('app.color.immersive_tint_connected');
    }
    return $r('app.color.immersive_tint_idle');
  }

  private setConnectedHomeLayoutMode(mode: ConnectedHomeLayoutMode): void {
    if (this.connectedHomeLayoutMode === mode) {
      return;
    }
    this.connectedHomeLayoutMode = mode;
    this.recordFeatureDiagnosticEvent('appearance_home_layout_changed', mode);
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.settingsPreferencesGateway.saveConnectedHomeLayout(context, mode).catch(() => {
      // The layout is still changed for this session when persistence is unavailable.
    });
  }

  private connectedHomeLayoutActive(): boolean {
    return this.vpnSessionController.connectedHomeLayoutActive();
  }

  private selectedExitNodeName(): string {
    const selected: ExitNodeChoice | undefined = this.exitNodes.find(
      (choice: ExitNodeChoice) => choice.selected);
    return selected === undefined ? '' : selected.name;
  }

  private resolveResourceString(resource: Resource, ...args: (string | number)[]): string {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      return context.resourceManager.getStringSync(resource.id, ...args);
    } catch (_error) {
      return '';
    }
  }

  private connectedDurationLabel(): string {
    const startedAtMs: number = this.vpnSessionController.connectionStartedAtMs;
    if (startedAtMs <= 0) {
      return this.resolveResourceString($r('app.string.connection_duration_just_now'));
    }
    const nowMs: number = this.connectionDurationNowMs > 0 ? this.connectionDurationNowMs : Date.now();
    const elapsedSeconds: number = Math.max(0, Math.floor((nowMs - startedAtMs) / 1000));
    const hours: number = Math.floor(elapsedSeconds / 3600);
    const minutes: number = Math.floor((elapsedSeconds % 3600) / 60);
    const seconds: number = elapsedSeconds % 60;
    if (hours > 0) {
      return this.resolveResourceString($r('app.string.connection_duration_hours_minutes'), hours, minutes);
    }
    if (minutes > 0) {
      return this.resolveResourceString($r('app.string.connection_duration_minutes_seconds'), minutes, seconds);
    }
    return this.resolveResourceString($r('app.string.connection_duration_seconds'), seconds);
  }

  private openConnectionDetails(): void {
    if (this.connectedHomeLayoutActive()) {
      this.connectionDetailsVisible = true;
      this.startConnectionDurationPolling();
    }
  }

  private onConnectionDetailsVisibilityChanged(): void {
    if (this.connectionDetailsVisible) {
      this.startConnectionDurationPolling();
    } else {
      this.stopConnectionDurationPolling();
    }
  }

  private startConnectionDurationPolling(): void {
    this.stopConnectionDurationPolling();
    this.connectionDurationNowMs = Date.now();
    this.refreshVpnProbeStatus();
    this.connectionDurationTimer = setInterval(() => {
      if (!this.connectionDetailsVisible) {
        this.stopConnectionDurationPolling();
        return;
      }
      this.connectionDurationNowMs = Date.now();
      this.refreshVpnProbeStatus();
    }, 1000);
  }

  private stopConnectionDurationPolling(): void {
    if (this.connectionDurationTimer >= 0) {
      clearInterval(this.connectionDurationTimer);
      this.connectionDurationTimer = -1;
    }
  }

  private showExitNodeConnectionHint(): void {
    this.showToast($r('app.string.exit_node_disconnect_first'));
  }

  private openPeerDetails(peer: PeerSummary): void {
    this.selectedPeerKey = peer.key;
    this.selectedPeerDetails = [peer];
    this.selectedPeerTitleName = this.peerDisplayName(peer.name);
    this.selectedPeerTitleDeviceType = peer.deviceType;
    this.selectedPeerTitleSystem = this.peerDeviceDescription(peer);
    this.selectedPeerTitleOnline = this.peerEffectivelyOnline(peer);
    this.deviceDetailVisible = true;
    this.startDeviceDetailRefreshPolling();
    if (!this.isConnected() || !this.peerEffectivelyOnline(peer) || peer.addresses.length === 0) {
      return;
    }
    this.refreshPeerServices(peer, false);
  }

  private startDeviceDetailRefreshPolling(): void {
    this.stopDeviceDetailRefreshPolling();
    if (!this.appShellReady || !this.remoteStreamAppInForeground) {
      return;
    }
    // Probe services once when the sheet opens. The fast detail timer below is
    // only for peer/path snapshots; forcing network service probes every four
    // seconds keeps the media queue permanently busy and can starve a manual
    // refresh before it observes the in-flight set becoming empty.
    this.refreshSelectedPeerDetails(true);
    this.deviceDetailRefreshTimer = setInterval(() => {
      if (!this.appShellReady || !this.deviceDetailVisible) {
        this.stopDeviceDetailRefreshPolling();
        return;
      }
      if (!this.remoteStreamAppInForeground) {
        if (this.deviceDetailRefreshTimer >= 0) {
          clearInterval(this.deviceDetailRefreshTimer);
          this.deviceDetailRefreshTimer = -1;
        }
        return;
      }
      this.refreshSelectedPeerDetails(false);
    }, FAST_REFRESH_INTERVAL_MS);
  }

  private stopDeviceDetailRefreshPolling(): void {
    this.deviceDetailPresentationId++;
    this.invalidateRemoteStreamLaunch();
    this.invalidateDeviceDetailServiceRefresh();
    if (this.deviceDetailRefreshTimer >= 0) {
      clearInterval(this.deviceDetailRefreshTimer);
      this.deviceDetailRefreshTimer = -1;
    }
  }

  private invalidateDeviceDetailServiceRefresh(): void {
    this.peerIntegrationController.invalidateDeviceDetailServiceRefresh();
  }

  private refreshSelectedPeerDetails(refreshServices: boolean = false): void {
    this.refreshPeerSnapshot();
    this.refreshTaildropSnapshot(this.isConnected());
    if (!refreshServices || this.deviceDetailServiceRefreshInFlight) {
      return;
    }
    this.requestLocalSendRefresh();
    const peer: PeerSummary | undefined = this.peers.find((candidate: PeerSummary) =>
      candidate.key === this.selectedPeerKey);
    if (peer !== undefined) {
      this.refreshPeerServices(peer, false);
    }
  }

  private async refreshSelectedPeerServicesManually(peerKey: string): Promise<void> {
    await this.peerIntegrationController.refreshSelectedPeerServicesManually(peerKey);
  }

  private async selectNativeSettingsBackground(): Promise<void> {
    if (this.nativeSettingsBackgroundPickerInProgress) return;
    const request: number = ++this.backgroundSelectionGeneration;
    const lifecycle: number = this.lifecycleGeneration;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.nativeSettingsBackgroundPickerInProgress = true;
    try {
      const mediaPicker = new photoAccessHelper.PhotoViewPicker();
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      const result: photoAccessHelper.PhotoSelectResult = await mediaPicker.select(options);
      if (request !== this.backgroundSelectionGeneration || lifecycle !== this.lifecycleGeneration ||
        !this.appShellReady || result.photoUris.length === 0) return;
      const candidate: string = await BackgroundImageStore.importImage(context.filesDir, result.photoUris[0]);
      if (request !== this.backgroundSelectionGeneration || lifecycle !== this.lifecycleGeneration ||
        !this.appShellReady) {
        BackgroundImageStore.removeManaged(context.filesDir, candidate);
        return;
      }
      if (!this.saveAppearanceValue(this.backgroundImageFilePath(), candidate)) {
        BackgroundImageStore.removeManaged(context.filesDir, candidate);
        this.showToast($r('app.string.personalization_save_failed'));
        return;
      }
      const previous: string = this.nativeSettingsBackgroundUri;
      this.nativeSettingsBackgroundUri = candidate;
      this.backgroundUnavailable = false;
      BackgroundImageStore.removeManaged(context.filesDir, previous);
      this.recordFeatureDiagnosticEvent('appearance_background_changed', 'selected');
    } catch (error) {
      if (request !== this.backgroundSelectionGeneration || lifecycle !== this.lifecycleGeneration ||
        !this.appShellReady) return;
      const businessError = error as BusinessError;
      this.recordFeatureDiagnosticEvent('appearance_background_failed', 'selection', businessError.code ?? -1);
      this.showToast($r('app.string.personalization_background_failed'));
    } finally {
      if (request === this.backgroundSelectionGeneration) this.nativeSettingsBackgroundPickerInProgress = false;
    }
  }

  private openRemoteFilesFromDevice(peer: PeerSummary): void {
    if (!this.appShellReady) return;
    const peerKey: string = peer.key;
    const requestId: number = Math.max(Date.now(), this.remoteFilesNavigationRequestId + 1,
      this.taildriveTargetRequestId + 1);
    this.remoteFilesNavigationRequestId = requestId;
    const navigationRevision: number = this.navigationRevision;
    this.deviceDetailVisible = false;
    this.scheduleLifecycleTask(() => {
      if (!this.appShellReady || this.remoteFilesNavigationRequestId !== requestId ||
        this.navigationRevision !== navigationRevision || this.deviceDetailVisible || this.selectedPeerKey !== peerKey) return;
      const current: PeerSummary | undefined = this.deviceDetailPeer(peerKey);
      if (current === undefined) return;
      this.taildriveTargetMachineName = current.name;
      this.taildriveTargetRequestId = requestId;
      this.navigateToTab(2);
    }, 120);
  }

  private openFileTransferFromDevice(peer: PeerSummary): void {
    this.taildropPendingFocusTargetKey = peer.key;
    this.taildropFocusedTargetKey = '';
    this.deviceDetailVisible = false;
    this.scheduleLifecycleTask(() => {
      this.navigateToNavigationTab('transfer', true);
      this.scheduleLifecycleTask(() => {
        if (this.taildropPendingFocusTargetKey !== peer.key) {
          return;
        }
        this.taildropFocusedTargetKey = peer.key;
        this.scheduleLifecycleTask(() => {
          if (this.taildropFocusedTargetKey === peer.key) {
            this.taildropFocusedTargetKey = '';
          }
          if (this.taildropPendingFocusTargetKey === peer.key) {
            this.taildropPendingFocusTargetKey = '';
          }
        }, 1000);
      }, 500);
    }, 120);
  }

  private startFileTransferForPeer(peer: PeerSummary): void {
    const capabilities: FileTransferCapabilities = this.fileTransferCapabilitiesForPeer(peer);
    if (!capabilities.tailsend && !capabilities.localSend) {
      this.deviceDetailVisible = false;
      this.showToast($r('app.string.transfer_no_targets_description'));
      return;
    }
    if (capabilities.tailsend && capabilities.localSend) {
      this.fileTransferMethodPeerKey = peer.key;
      this.deviceDetailVisible = false;
      this.fileTransferMethodVisible = true;
      return;
    }
    if (capabilities.tailsend && !capabilities.localSend) {
      this.dispatchFileTransferTransport(peer, 'tailsend');
      return;
    }
    if (capabilities.localSend && !capabilities.tailsend) {
      this.dispatchFileTransferTransport(peer, 'localsend');
      return;
    }
  }

  private selectFileTransferTransport(transport: FileTransferTransport): void {
    if (!this.fileTransferSelectionSupports(transport)) {
      return;
    }
    this.meshSendPreferredTransport = transport;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    FileTransferPreferences.save(context, transport).catch(() => {
      // The current selection remains active even when preference storage fails.
    });
    this.fileTransferMethodVisible = false;
    const peer: PeerSummary | undefined = this.fileTransferSelectionPeer();
    if (peer !== undefined) {
      this.dispatchFileTransferTransport(peer, transport);
    }
  }

  private dispatchFileTransferTransport(peer: PeerSummary, transport: FileTransferTransport): void {
    if (transport === 'tailsend') {
      this.openTaildropFromDevice(peer);
    } else {
      this.openLocalSendFromDevice(peer);
    }
  }

  private openTaildropFromDevice(peer: PeerSummary): void {
    const target: TaildropTargetSummary | undefined = this.taildropTargetForPeer(peer);
    if (target === undefined) {
      this.showToast($r('app.string.transfer_send_target_unavailable'));
      return;
    }
    this.taildropFocusedTargetKey = peer.key;
    this.deviceDetailVisible = false;
    this.scheduleLifecycleTask(() => {
      this.navigateToTab(1);
      this.scheduleLifecycleTask(() => {
        this.chooseTaildropDocuments(target);
      }, 180);
      this.scheduleLifecycleTask(() => {
        if (this.taildropFocusedTargetKey === peer.key) {
          this.taildropFocusedTargetKey = '';
        }
      }, 2600);
    }, 120);
  }

  private openLocalSendFromDevice(peer: PeerSummary): void {
    this.peerIntegrationController.openLocalSendFromDevice(peer);
  }

  private async launchLocalSendApp(): Promise<void> {
    await this.peerIntegrationController.launchLocalSendApp();
  }

  private refreshPeerServices(peer: PeerSummary, manual: boolean = true): void {
    this.peerIntegrationController.refreshPeerServices(peer, manual);
  }

  private autoProbeConnectedPeerServices(force: boolean = false): void {
    this.peerIntegrationController.autoProbeConnectedPeerServices(force);
  }

  private isSunshineCandidate(peer: PeerSummary): boolean {
    return isPeerSunshineCandidate(peer);
  }

  private streamingState(peerKey: string): DeviceStreamingState {
    return this.peerIntegrationController.streamingState(peerKey);
  }

  private resetStreamingStatesForDisconnect(): void {
    this.peerIntegrationController.resetStreamingStatesForDisconnect();
  }

  private mediaState(peerKey: string): DeviceMediaState {
    return this.peerIntegrationController.mediaState(peerKey);
  }

  private mediaServiceNames(peerKey: string): string {
    return this.peerIntegrationController.mediaServiceNames(peerKey);
  }

  private peerServiceBadgesVisible(peer: PeerSummary): boolean {
    return this.peerIntegrationController.peerServiceBadgesVisible(peer);
  }

  private detectMediaForPeer(peer: PeerSummary, force: boolean): void {
    this.peerIntegrationController.detectMediaForPeer(peer, force);
  }

  private streamReachable(state: DeviceStreamingState): boolean {
    return this.peerIntegrationController.streamReachable(state);
  }

  private invalidateRemoteStreamLaunch(): void {
    this.peerIntegrationController.invalidateRemoteStreamLaunch();
  }

  private handleRemoteStreamAppBackground(): void {
    this.peerIntegrationController.handleRemoteStreamAppBackground();
  }

  private launchRemoteStream(peer: PeerSummary): void {
    this.peerIntegrationController.launchRemoteStream(peer);
  }

  private showDerpStreamConfirmation(peer: PeerSummary, state: DeviceStreamingState,
    intent: RemoteStreamLaunchIntent): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.stream_derp_confirm_title'),
      message: $r('app.string.stream_derp_confirm_message'),
      autoCancel: true,
      onWillDismiss: (action: DismissDialogAction): void => {
        this.peerIntegrationController.finishRemoteStreamLaunch(intent);
        action.dismiss();
      },
      primaryButton: {
        value: $r('app.string.stream_derp_use_compatible_profile'),
        action: () => this.peerIntegrationController.openMoonlight(peer, state, false, intent)
      },
      secondaryButton: {
        value: $r('app.string.stream_derp_use_original_profile'),
        action: () => this.peerIntegrationController.openMoonlight(peer, state, true, intent)
      }
    });
  }

  private showMoonlightRequiredAlertDialog(host: string): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.stream_moonlight_required_title'),
      message: $r('app.string.stream_moonlight_required_message'),
      autoCancel: true,
      primaryButton: { value: $r('app.string.stream_dialog_cancel_action'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.stream_copy_host_address_action'),
        action: () => this.copyDeviceValue(host, $r('app.string.peer_ip_copied'))
      }
    });
  }

  private launchMediaForPeer(peer: PeerSummary): void {
    this.peerIntegrationController.launchMediaForPeer(peer);
  }

  private openHosPlayer(peer: PeerSummary, service: DiscoveredMediaService): void {
    this.peerIntegrationController.openHosPlayer(peer, service);
  }

  private copyPlainText(value: string, successMessage: ResourceStr): void {
    if (typeof this.isSecurityCoverActive === 'function' && this.isSecurityCoverActive()) {
      return;
    }
    const data: pasteboard.PasteData = createLocalTextPasteData(value);
    pasteboard.getSystemPasteboard().setData(data)
      .then(() => this.showToast(successMessage))
      .catch(() => this.showToast($r('app.string.device_copy_failed')));
  }

  private runMediaIntegrationSelfTest(): void {
    this.peerIntegrationController.runMediaIntegrationSelfTest();
  }

  private copyHosPlayerPrototype(): void {
    this.peerIntegrationController.copyHosPlayerPrototype();
  }

  private copyDeviceValue(value: string, successMessage: ResourceStr): void {
    if (typeof this.isSecurityCoverActive === 'function' && this.isSecurityCoverActive()) {
      return;
    }
    if (value.length === 0) {
      this.showToast($r('app.string.device_copy_unavailable'));
      return;
    }
    const data: pasteboard.PasteData = createLocalTextPasteData(value);
    pasteboard.getSystemPasteboard().setData(data)
      .then(() => this.showToast(successMessage))
      .catch(() => this.showToast($r('app.string.device_copy_failed')));
  }

  private taildropTransferProgress(): number {
    if (this.taildropTransfer.totalBytes <= 0) {
      return this.taildropTransfer.state === 'completed' ? 100 : 0;
    }
    return Math.max(0, Math.min(100,
      Math.round(this.taildropTransfer.bytesSent * 100 / this.taildropTransfer.totalBytes)));
  }

  private formatTransferDuration(seconds: number): string {
    return formatTaildropTransferDuration(seconds);
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

  private taildropContentKind(file: TaildropWaitingFileSummary): string {
    return this.taildropSessionController.taildropContentKind(file);
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

  private taildropFileIcon(name: string): Resource {
    return resolveFileIconResource(name);
  }

  @Builder
  private TaildropFileIcon(name: string, size: number) {
    Image(this.taildropFileIcon(name))
      .width(size)
      .height(size)
      .objectFit(ImageFit.Contain)
  }

  private taildropFileIconColor(name: string): ResourceColor {
    return resolveFileIconColorResource(name);
  }

  private resolveTaildropMediaType(name: string): photoAccessHelper.PhotoType | undefined {
    return this.taildropSessionController.resolveTaildropMediaType(name);
  }

  private taildropReceiveMatches(file: TaildropWaitingFileSummary): boolean {
    return this.taildropSessionController.taildropReceiveMatches(file);
  }

  private taildropReceiveRowLoading(file: TaildropWaitingFileSummary): boolean {
    return this.taildropSessionController.taildropReceiveRowLoading(file);
  }

  private taildropPreparedMediaSaveEnabled(file: TaildropWaitingFileSummary): boolean {
    return this.taildropSessionController.taildropPreparedMediaSaveEnabled(file);
  }

  private taildropTextPreviewLoading(file: TaildropWaitingFileSummary): boolean {
    return this.taildropSessionController.taildropTextPreviewLoading(file);
  }

  private findTaildropCachedFile(
    file: TaildropWaitingFileSummary
  ): TaildropCachedFile | undefined {
    return this.taildropSessionController.findTaildropCachedFile(file);
  }

  private taildropWaitingFilePreviewUri(file: TaildropWaitingFileSummary): string {
    return this.taildropSessionController.taildropWaitingFilePreviewUri(file);
  }

  private taildropHistoryPreviewUri(record: TaildropTransferRecord): string {
    return this.taildropSessionController.taildropHistoryPreviewUri(record);
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

  private sanitizeTaildropDisplayText(value: string): string {
    return sanitizeTaildropDisplayText(value);
  }

  private taildropTransferRecordTitle(record: TaildropTransferRecord): string {
    return formatTaildropRecordTitle(record);
  }

  private taildropTransferRecordDescription(record: TaildropTransferRecord): string {
    return formatTaildropRecordDescription(record, this.formatTrafficBytes(record.totalBytes));
  }

  private clearTaildropHistory(): void {
    this.taildropSessionController.clearTaildropHistory();
  }

  private taildropSendActive(): boolean {
    return this.taildropSessionController.taildropSendActive();
  }

  private taildropContentChoiceEnabled(): boolean {
    return this.taildropSessionController.taildropContentChoiceEnabled();
  }

  private taildropTextEditorMatches(target: TaildropTargetSummary): boolean {
    return this.taildropSessionController.taildropTextEditorMatches(target);
  }

  private closeTaildropTextEditor(): void {
    this.taildropSessionController.closeTaildropTextEditor();
  }

  private onTaildropTextEditorVisibilityChanged(): void {
    this.taildropSessionController.onTaildropTextEditorVisibilityChanged();
  }

  private ensureTaildropSendAvailable(target: TaildropTargetSummary): boolean {
    return this.taildropSessionController.ensureTaildropSendAvailable(target);
  }

  private chooseTaildropDocuments(target: TaildropTargetSummary): void {
    this.taildropSessionController.chooseTaildropDocuments(target);
  }

  private chooseTaildropPhotos(target: TaildropTargetSummary): void {
    this.taildropSessionController.chooseTaildropPhotos(target);
  }

  private chooseTaildropText(target: TaildropTargetSummary): void {
    this.taildropSessionController.chooseTaildropText(target);
  }

  private sendTaildropText(): void {
    this.taildropSessionController.sendTaildropText();
  }

  private async queueTaildropFiles(target: TaildropTargetSummary, uris: string[]): Promise<boolean> {
    return await this.taildropSessionController.queueTaildropFiles(target, uris);
  }

  private cancelTaildropSend(): void {
    this.taildropSessionController.cancelTaildropSend();
  }

  private retryTaildropSend(record: TaildropTransferRecord): void {
    this.taildropSessionController.retryTaildropSend(record);
  }

  private startTaildropReceive(file: TaildropWaitingFileSummary): void {
    this.taildropSessionController.startTaildropReceive(file);
  }

  private startTaildropTextPreview(file: TaildropWaitingFileSummary): void {
    this.taildropSessionController.startTaildropTextPreview(file);
  }

  private async showCachedTaildropTextPreview(cached: TaildropCachedFile): Promise<boolean> {
    return await this.taildropSessionController.showCachedTaildropTextPreview(cached);
  }

  private confirmDiscardTaildropFile(file: TaildropWaitingFileSummary): void {
    if (this.taildropSendActive()) {
      this.showToast($r('app.string.transfer_busy_message'));
      return;
    }
    this.getUIContext().showAlertDialog({
      title: $r('app.string.transfer_discard_confirm_title'),
      message: $r('app.string.transfer_discard_confirm_message', this.sanitizeTaildropDisplayText(file.name)),
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.cancel_action'),
        action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.transfer_discard_action'),
        fontColor: $r('app.color.status_error'),
        action: () => this.taildropSessionController.discardTaildropFile(file)
      }
    });
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
        action: () => this.taildropSessionController.clearTaildropInboxCache()
      }
    });
  }

  private handlePreparedTaildropMediaSaveClick(file: TaildropWaitingFileSummary): void {
    this.taildropSessionController.handlePreparedTaildropMediaSaveClick(file);
  }

  private startPreparedTaildropFileSave(file: TaildropWaitingFileSummary): void {
    this.taildropSessionController.startPreparedTaildropFileSave(file);
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
        .fontSize(UiTokens.SECTION_TITLE_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
      if (description !== undefined) {
        Text(description)
          .fontSize(UiTokens.CAPTION_SIZE)
          .fontColor($r('sys.color.font_secondary'))
          .lineHeight(18)
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private SettingsGroupHeader(title: ResourceStr, compactTop: boolean = false) {
    Text(title)
      .fontSize(UiTokens.SECTION_TITLE_SIZE)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.font_primary'))
      .width('100%')
      .padding({ top: compactTop ? 0 : 8, bottom: 2 })
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
      .height(UiTokens.ACTION_HEIGHT)
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
    return !this.controlServerSwitching && !this.connectionActionLoading() && !this.deviceNeedsApproval();
  }

  private connectionActionBackground(): ResourceColor {
    return this.isConnected() ? $r('app.color.account_action_primary') : this.secondaryBackground();
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
    if (this.controlServerSwitching) return;
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
      stateEffect: LightAppearance.nativePress(this.glowLevel),
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
    .visualEffect(LightAppearance.pressEffect(this.glowLevel,
      this.connectionButtonPressed && this.connectionActionEnabled()))
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) this.connectionButtonPressed = true;
      else if (event.type === TouchType.Up || event.type === TouchType.Cancel) this.connectionButtonPressed = false;
    })
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
        .stroke($r('app.color.emphasize'))
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
        .stroke($r('app.color.emphasize'))
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
            .fontColor($r('app.color.emphasize'))
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
          TransitionEffect.OPACITY.animation({ duration: MotionTokens.EXPAND, curve: MotionTokens.curve() })
            .combine(TransitionEffect.translate({ y: MotionTokens.amplitude(-10) })),
          TransitionEffect.OPACITY.animation({ duration: MotionTokens.FAST, curve: MotionTokens.curve() })
            .combine(TransitionEffect.translate({ y: MotionTokens.amplitude(-6) }))
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
    .padding(UiTokens.CARD_PADDING)
    .backgroundColor(this.groupBackground())
    .borderRadius(UiTokens.CARD_RADIUS)
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
    return tailnetName.length > 0 ? tailnetName : this.localDeviceName();
  }

  private compactExitNodeLabel(connected: boolean): ResourceStr {
    const selectedName: string = this.selectedExitNodeName();
    if (!connected) {
      return this.selectedExitNodeLabel();
    }
    return selectedName.length > 0 ? selectedName : $r('app.string.network_sheet_not_used');
  }

  @Builder
  private CompactHomeHeader(connected: boolean) {
    CompactConnectedHomeHeader({
      connected: connected,
      glowLevel: this.glowLevel,
      statusTitle: this.connectionTitle(),
      statusDescription: this.compactConnectionDescription(connected),
      statusColor: this.connectionColor(),
      downloadRate: this.formatTrafficBytes(this.trafficDownloadRate, true),
      uploadRate: this.formatTrafficBytes(this.trafficUploadRate, true),
      showTraffic: connected,
      exitNodeLabel: this.compactExitNodeLabel(connected),
      exitNodeEditable: !connected,
      exitNodeEnabled: this.canEditExitNode(),
      exitNodeOptions: this.exitNodeSelectOptions(),
      exitNodeSelectedIndex: this.selectedExitNodeIndex(),
      onDetails: (): void => { this.openConnectionDetails(); },
      onExitNodeInfo: (): void => {
        if (connected) {
          this.openConnectionDetails();
        } else {
          this.showExitNodeConnectionHint();
        }
      },
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
      inactiveHeader: (): void => { this.CompactHomeHeader(false); },
      legacyHeader: (): void => { this.LegacyConnectedHeader(); },
      compactHeader: (): void => { this.CompactConnectedHeader(); }
    })
  }

  @Builder
  private ConnectionDetailsContent() {
    Stack() {
      ConnectionDetailsSheet({
        tailscaleAddress: this.primaryTailscaleAddress(this.accountSummary.addresses),
        duration: this.connectedDurationLabel(),
        downloadRate: this.formatTrafficBytes(this.trafficDownloadRate, true),
        uploadRate: this.formatTrafficBytes(this.trafficUploadRate, true),
        downloadTotal: this.formatTrafficBytes(this.trafficDownloadBytes),
        uploadTotal: this.formatTrafficBytes(this.trafficUploadBytes),
        exitNodeName: this.selectedExitNodeName(),
        exitNodeAvailableCount: this.exitNodes.filter((choice: ExitNodeChoice) => choice.online).length,
        allowLanAccess: this.networkSettings.exitNodeAllowLANAccess,
        onCopyAddress: (): void => this.copyDeviceValue(
          this.primaryTailscaleAddress(this.accountSummary.addresses),
          $r('app.string.peer_ip_copied'))
      })
      if (this.isSecurityCoverActive()) {
        this.SecurityCoverOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private ConnectionDetailsTitle() {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Image(this.localDeviceIcon())
          .width(22)
          .height(22)
          .objectFit(ImageFit.Contain)
          .fillColor($r('sys.color.icon_primary'))
        Row()
          .width(8)
          .height(8)
          .borderRadius(4)
          .border({ width: 2, color: $r('sys.color.background_secondary') })
          .backgroundColor($r('app.color.status_success'))
          .position({ x: 29, y: 29 })
      }
      .width(44)
      .height(44)
      .borderRadius(12)
      .backgroundColor($r('sys.color.comp_background_tertiary'))

      Column({ space: 3 }) {
        Text(this.localDeviceName())
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row({ space: 7 }) {
          Text(`HarmonyOS ${this.harmonyOSVersion()}`)
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text($r('app.string.connection_connected'))
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private DeviceDetailsContent() {
    Stack() {
      Column() {
        ForEach(this.selectedPeerDetails,
          (peer: PeerSummary) => {
            DeviceDetailSheet({
              online: this.peers.some((current: PeerSummary) => current.key === peer.key && current.online),
              meshConnected: this.isConnected(),
              path: this.streamingState(peer.key).path,
              tailscaleAddress: this.deviceDetailAddress(peer.key),
              magicDnsName: this.deviceDetailMagicDnsName(peer.key),
              exitNodeCapable: this.deviceDetailExitNodeCapable(peer.key),
              servicesChecking: this.streamingState(peer.key).checking || this.mediaState(peer.key).checking,
              glowLevel: this.glowLevel,
              showSunshine: this.deviceDetailSunshineCandidate(peer.key),
              sunshineState: this.streamingState(peer.key).sunshine.state,
              sunshineAvailable: this.streamingState(peer.key).sunshine.state === 'available',
              sunshineLaunching: this.streamingState(peer.key).launching,
              mediaServiceCount: this.mediaState(peer.key).result.services.length,
              mediaProbeState: this.mediaState(peer.key).result.state,
              setupHelpEnabled: this.canOpenContextGuide(),
              mediaServiceNames: this.mediaServiceNames(peer.key),
              mediaLaunching: this.mediaState(peer.key).launching,
              serviceRefreshVisible: this.deviceDetailServiceRefreshInFlight,
              localSendState: this.localSendStatusForPeer(peer.key)?.state ?? 'unknown',
              localSendRefreshing: this.transferProtocolRefreshing,
              localSendAvailable: this.localSendAvailableForPeer(peer),
              taildropAvailable: this.taildropTargetAvailableForPeer(peer),
              taildropOnline: this.taildropTargetOnlineForPeer(peer),
              taildropReady: this.taildropTargetReadyForPeer(peer),
              remoteFilesEnabled: this.isConnected(),
              onRefresh: (): Promise<void> => this.refreshSelectedPeerServicesManually(peer.key),
              onOpenStream: (): void => this.withCurrentDeviceDetailPeer(peer.key,
                (current: PeerSummary): void => this.launchRemoteStream(current)),
              onOpenMedia: (): void => this.withCurrentDeviceDetailPeer(peer.key,
                (current: PeerSummary): void => this.openMediaMethodForPeer(current)),
              onOpenFileTransfer: (): void => this.withCurrentDeviceDetailPeer(peer.key,
                (current: PeerSummary): void => this.openFileTransferFromDevice(current)),
              onOpenRemoteFiles: (): void => this.withCurrentDeviceDetailPeer(peer.key,
                (current: PeerSummary): void => this.openRemoteFilesFromDevice(current)),
              onCopyIp: (): void => this.copyDeviceDetailAddress(peer.key),
              onCopyDns: (): void => this.copyDeviceValue(this.deviceDetailMagicDnsName(peer.key),
                $r('app.string.peer_dns_copied'))
            })
          }, (peer: PeerSummary) => this.deviceDetailRenderKey(peer))
      }
      .width('100%')
      .height('100%')
      .backgroundColor(LightAppearance.supports() ? Color.Transparent : $r('sys.color.background_secondary'))
      if (this.isSecurityCoverActive()) {
        this.SecurityCoverOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private DeviceDetailsTitle() {
    // Keep the title node mounted from the first render. A conditional root
    // is not recreated by the native sheet title slot after it is opened.
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Image(this.peerDeviceIcon(this.selectedPeerTitleDeviceType))
          .width(22)
          .height(22)
          .objectFit(ImageFit.Contain)
          .fillColor($r('sys.color.icon_primary'))
        Row()
          .width(8)
          .height(8)
          .borderRadius(4)
          .border({ width: 2, color: $r('sys.color.background_secondary') })
          .backgroundColor(this.selectedPeerTitleOnline ? $r('app.color.status_success') :
            $r('app.color.status_offline'))
          .position({ x: 29, y: 29 })
      }
      .width(44)
      .height(44)
      .borderRadius(12)
      .backgroundColor($r('sys.color.comp_background_tertiary'))

      Column({ space: 3 }) {
        Text(this.selectedPeerTitleName)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row({ space: 7 }) {
          Text(this.selectedPeerTitleSystem)
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.selectedPeerTitleOnline ? $r('app.string.peer_online') :
            $r('app.string.peer_offline'))
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private HosPlayerMediaMethodRow() {
    Row({ space: 12 }) {
      Image($r('app.media.hosplayer'))
        .width(40)
        .height(40)
        .objectFit(ImageFit.Cover)
        .borderRadius(12)

      Column({ space: 3 }) {
        Text($r('app.string.media_method_hosplayer_title'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
        Text($r('app.string.media_method_hosplayer_description'))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .lineHeight(18)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(UiTokens.ICON_CHEVRON)
        .fontColor([$r('sys.color.icon_secondary')])
    }
    .width('100%')
    .constraintSize({ minHeight: 68 })
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(UiTokens.CARD_RADIUS)
    .onClick(() => this.launchSelectedMediaWithHosPlayer())
  }

  @Builder
  private MediaMethodContent() {
    Stack() {
      Column({ space: 10 }) {
        Text($r('app.string.media_method_message', this.mediaMethodSelectionPeerName()))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .lineHeight(19)
          .width('100%')
          .margin({ bottom: 4 })

        this.HosPlayerMediaMethodRow()
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16, top: 2, bottom: 24 })
      .backgroundColor(LightAppearance.supports() ? Color.Transparent : $r('sys.color.background_secondary'))
      if (this.isSecurityCoverActive()) {
        this.SecurityCoverOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private FileTransferMethodRow(transport: FileTransferTransport, title: ResourceStr,
    description: ResourceStr, enabled: boolean) {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        if (transport === 'localsend') {
          Image($r('app.media.quick_transfer'))
            .width(40)
            .height(40)
            .objectFit(ImageFit.Cover)
            .borderRadius(12)
        } else {
          Image($r('app.media.ic_light_connect'))
            .width(28)
            .height(28)
            .objectFit(ImageFit.Contain)
        }
      }
      .width(40)
      .height(40)
      .borderRadius(12)
      .backgroundColor(transport === 'localsend' ? Color.Transparent :
        $r('sys.color.comp_background_tertiary'))

      Column({ space: 3 }) {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
        Text(description)
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .lineHeight(18)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(UiTokens.ICON_CHEVRON)
        .fontColor([$r('sys.color.icon_secondary')])
    }
    .width('100%')
    .constraintSize({ minHeight: 68 })
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(UiTokens.CARD_RADIUS)
    .enabled(enabled)
    .opacity(enabled ? 1 : 0.48)
    .onClick(() => {
      if (enabled) {
        this.selectFileTransferTransport(transport);
      }
    })
  }

  @Builder
  private FileTransferMethodContent() {
    Stack() {
      Column({ space: 10 }) {
        Text($r('app.string.transfer_method_message', this.fileTransferSelectionPeerName()))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .lineHeight(19)
          .width('100%')
          .margin({ bottom: 4 })

        if (this.fileTransferSelectionSupports('tailsend')) {
          this.FileTransferMethodRow('tailsend',
            $r('app.string.transfer_method_tailsend_title'),
            $r('app.string.transfer_method_tailsend_description'), true)
        }
        if (this.fileTransferSelectionSupports('localsend')) {
          this.FileTransferMethodRow('localsend',
            $r('app.string.transfer_method_localsend_title'),
            $r('app.string.transfer_method_localsend_description'), true)
        }
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16, top: 2, bottom: 24 })
      .backgroundColor(LightAppearance.supports() ? Color.Transparent : $r('sys.color.background_secondary'))
      if (this.isSecurityCoverActive()) {
        this.SecurityCoverOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private NetworkSettingsPanel() {
    Column({ space: 0 }) {
      Row() {
        Column({ space: 2 }) {
          Text($r('app.string.setting_tailnet_dns')).fontSize(14).fontColor($r('sys.color.font_primary'))
          Text($r('app.string.setting_tailnet_dns_description')).fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.tailnetDnsEnabled })
          .id('tailnet-dns-toggle')
          .selectedColor($r('app.color.emphasize'))
          .enabled(!this.isConnected() && !this.isConnecting() && this.isAuthenticated())
          .systemMaterial(LightAppearance.control(this.glowLevel))
          .onClick(() => this.toggleTailnetDns())
      }.width('100%').constraintSize({ minHeight: 62 }).padding({ top: 6, bottom: 6 })
      Divider().color($r('sys.color.comp_divider'))
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
          .selectedColor($r('app.color.emphasize'))
          .enabled(!this.isConnected() && this.isAuthenticated() && !this.routeAllUpdateInProgress)
          .systemMaterial(LightAppearance.control(this.glowLevel))
          .onClick(() => this.toggleNetworkSetting('routeAll'))
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
          .selectedColor($r('app.color.emphasize'))
          .enabled(!this.isConnected() && this.isAuthenticated() && !this.exitNodeLanUpdateInProgress)
          .systemMaterial(LightAppearance.control(this.glowLevel))
          .onClick(() => this.toggleNetworkSetting('exitNodeAllowLANAccess'))
      }
      .width('100%')
      .constraintSize({ minHeight: 62 })
      .padding({ top: 6, bottom: 6 })

      if (this.isConnected()) {
        Text($r('app.string.network_settings_disconnect_first'))
          .id('network-settings-disconnect-hint')
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .padding({ top: 8 })
      }

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
    .padding(UiTokens.CARD_PADDING)
    .backgroundColor(this.groupBackground())
    .borderRadius(UiTokens.CARD_RADIUS)
    .animation({ duration: MotionTokens.EXPAND, curve: MotionTokens.curve() })
  }

  @Builder
  private CustomDnsPanel() {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 3 }) {
          Text($r('app.string.setting_dns_override')).fontSize(14).fontColor($r('sys.color.font_primary'))
          Text($r('app.string.setting_dns_override_description')).fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.dnsSettingsEnabled })
          .id('dns-override-toggle').selectedColor($r('app.color.emphasize'))
          .enabled(this.canEditCustomDns())
          .systemMaterial(LightAppearance.control(this.glowLevel))
          .onChange((enabled: boolean) => {
            if (this.canEditCustomDns()) { this.dnsSettingsEnabled = enabled; this.dnsSettingsStatus = ''; }
          })
      }.width('100%')
      if (this.dnsSettingsEnabled) {
        Text($r('app.string.setting_dns_primary')).fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
        AccountTextField({ value: $dnsPrimaryInput, fieldId: 'dns-primary-input',
          placeholder: $r('app.string.setting_dns_primary_placeholder'), inputEnabled: this.canEditCustomDns(),
          onEdited: () => { this.dnsSettingsStatus = ''; } })
        Text($r('app.string.setting_dns_secondary')).fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
        AccountTextField({ value: $dnsSecondaryInput, fieldId: 'dns-secondary-input',
          placeholder: $r('app.string.setting_dns_secondary_placeholder'), inputEnabled: this.canEditCustomDns(),
          onEdited: () => { this.dnsSettingsStatus = ''; } })
        Text($r('app.string.setting_dns_search_domains')).fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
        AccountTextField({ value: $dnsSearchDomainsInput, fieldId: 'dns-search-domains-input',
          placeholder: $r('app.string.setting_dns_search_domains_placeholder'), inputEnabled: this.canEditCustomDns(),
          onEdited: () => { this.dnsSettingsStatus = ''; } })
      }
      Button($r('app.string.setting_dns_save'))
        .id('dns-settings-save').width('100%').enabled(this.canEditCustomDns())
        .onClick(() => this.saveCustomDns())
      if (this.dnsSettingsStatus.length > 0) {
        Text(this.customDnsStatusText()).id('dns-settings-status').fontSize(12)
          .fontColor(this.dnsSettingsStatus === 'saved' ? $r('app.color.status_success') : $r('app.color.status_error'))
          .width('100%')
      }
      if (this.isConnected() || this.isConnecting()) {
        Text($r('app.string.network_settings_disconnect_first')).fontSize(12)
          .fontColor($r('sys.color.font_secondary')).width('100%')
      }
    }.id('dns-settings-panel').width('100%').padding(14)
      .backgroundColor(this.groupBackground()).borderRadius(16)
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

  private canEditExitNode(): boolean {
    return this.isAuthenticated() && this.exitNodes.length > 0 &&
      !this.isConnected() && !this.isConnecting() && !this.connectInProgress &&
      !this.disconnectInProgress && !this.exitNodeUpdateInProgress &&
      !this.backendRestartDeferred && this.backendReady &&
      this.backendStatus.includes('state=Running');
  }

  private onExitNodeSelect(index: number): void {
    if (!this.canEditExitNode()) { return; }
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
          .fontSize(UiTokens.CAPTION_SIZE)
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
        .constraintSize({ minWidth: 104, maxWidth: this.layoutWidth >= 600 ? 240 : 144 })
        .enabled(this.canEditExitNode())
        .opacity(this.canEditExitNode() ? 1 : 0.55)
        .systemMaterial(LightAppearance.control(this.glowLevel))
        .menuSystemMaterial(LightAppearance.menu(this.glowLevel))
        .onSelect((index: number) => this.onExitNodeSelect(index))
    }
    .width('100%')
    .constraintSize({ minHeight: 68 })
    .padding({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING, top: 12, bottom: 12 })
    .backgroundColor(this.groupBackground())
    .borderRadius(UiTokens.CARD_RADIUS)
    .animation({ duration: MotionTokens.EXPAND, curve: MotionTokens.curve() })
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
          .color($r('app.color.emphasize'))
        Text($r('app.string.action_starting'))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .width('100%')
      .constraintSize({ minHeight: 112 })
    }
    .width('100%')
    .constraintSize({ minHeight: 160 })
    .padding(16)
    .backgroundColor(this.groupBackground())
    .borderRadius(UiTokens.CARD_RADIUS)
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
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .width('100%')
      .constraintSize({ minHeight: 112 })
    }
    .width('100%')
    .constraintSize({ minHeight: 160 })
    .padding(16)
    .backgroundColor(this.groupBackground())
    .borderRadius(UiTokens.CARD_RADIUS)
  }

  @Builder
  private DeviceStatusNotice(label: ResourceStr, error: boolean) {
    Text(label)
      .fontSize(UiTokens.BADGE_SIZE)
      .fontWeight(FontWeight.Medium)
      .fontColor(error ? $r('app.color.status_error') : $r('app.color.status_warning'))
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .padding({ left: UiTokens.BADGE_PADDING_HORIZONTAL, right: UiTokens.BADGE_PADDING_HORIZONTAL,
        top: UiTokens.BADGE_PADDING_VERTICAL, bottom: UiTokens.BADGE_PADDING_VERTICAL })
      .borderRadius(UiTokens.BADGE_RADIUS)
      .backgroundColor(error ? $r('app.color.badge_background_error') : $r('app.color.badge_background_warning'))
  }

  @Builder
  private DeviceGroupLabel(label: ResourceStr) {
    Text(label)
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.font_secondary'))
      .width('100%')
      .padding({ left: 4, top: 4, bottom: 2 })
  }

  @Builder
  private LocalDeviceRow() {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Image(this.localDeviceIcon())
          .width(22)
          .height(22)
          .objectFit(ImageFit.Contain)
          .fillColor($r('sys.color.icon_primary'))
        Row()
          .width(8)
          .height(8)
          .borderRadius(4)
          .border({ width: 2, color: this.groupBackground() })
          .backgroundColor(this.connectionColor())
          .position({ x: 23, y: 23 })
      }
      .width(UiTokens.ICON_LIST_CONTAINER)
      .height(UiTokens.ICON_LIST_CONTAINER)
      .borderRadius(UiTokens.ICON_LIST_CONTAINER_RADIUS)
      .backgroundColor(this.secondaryBackground())

      Column({ space: 3 }) {
        Row({ space: 8 }) {
          Text(this.localDeviceName())
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .wordBreak(WordBreak.BREAK_ALL)
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(UiTokens.ICON_CHEVRON)
            .fontColor([$r('sys.color.icon_secondary')])
        }
        .width('100%')
        Row({ space: 8 }) {
          Text('HarmonyOS ' + this.harmonyOSVersion())
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(this.localDeviceCardStatus())
            .fontSize(12)
            .fontColor(this.isConnected() ? $r('app.color.status_success') :
              $r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(TextAlign.End)
        }
        .width('100%')
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
          .margin({ top: 2 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .constraintSize({ minHeight: 64 })
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor(this.groupBackground())
    .borderRadius(UiTokens.CARD_RADIUS)
    .onClick(() => this.openConnectionDetails())
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
    .onClick(action)
  }

  @Builder
  private PeerDeviceRow(peer: PeerSummary) {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Image(this.peerDeviceIcon(peer.deviceType))
          .width(22)
          .height(22)
          .objectFit(ImageFit.Contain)
          .fillColor(this.peerEffectivelyOnline(peer) ? $r('sys.color.icon_primary') : $r('sys.color.icon_secondary'))
        Row()
          .width(8)
          .height(8)
          .borderRadius(4)
          .border({ width: 2, color: this.groupBackground() })
          .backgroundColor(this.peerEffectivelyOnline(peer) ? $r('app.color.status_success') :
            $r('app.color.status_offline'))
          .position({ x: 23, y: 23 })
      }
      .width(UiTokens.ICON_LIST_CONTAINER)
      .height(UiTokens.ICON_LIST_CONTAINER)
      .borderRadius(UiTokens.ICON_LIST_CONTAINER_RADIUS)
      .backgroundColor(this.secondaryBackground())

      Column({ space: 3 }) {
        Row({ space: 8 }) {
          Text(this.peerDisplayName(peer.name))
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(UiTokens.ICON_CHEVRON)
            .fontColor([$r('sys.color.icon_secondary')])
        }
        .width('100%')
        Row({ space: 8 }) {
          Text(this.peerDeviceDescription(peer))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          this.PeerCardStatusText(peer)
        }
        .width('100%')
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
    }
    .width('100%')
    .constraintSize({ minHeight: 64 })
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor(this.groupBackground())
    .borderRadius(UiTokens.CARD_RADIUS)
    .id('home-peer-' + this.nodeNameSlug(peer.key))
    .onClick(() => this.openHomePeerDetails(peer))
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
          .backgroundColor(this.peerEffectivelyOnline(peer) ? $r('app.color.status_success') :
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
          (this.peerEffectivelyOnline(peer) ? $r('app.string.peer_online') : $r('app.string.peer_offline')))
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
        Text(this.peerEffectivelyOnline(peer) ? $r('app.string.peer_online') : $r('app.string.peer_offline'))
          .fontSize(13)
          .fontColor(this.peerEffectivelyOnline(peer) ? $r('app.color.status_success') :
            $r('app.color.status_offline'))
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
      if (this.peerEffectivelyOnline(peer) && peer.addresses.length > 0) {
        DeviceConnectionInfoPanel({
          path: this.streamingState(peer.key).path,
          sunshine: this.streamingState(peer.key).sunshine,
          media: this.mediaState(peer.key).result,
          localSend: peer.localSend ?? { state: 'unknown' },
          checking: this.streamingState(peer.key).checking,
          refreshing: this.streamingState(peer.key).checking || this.mediaState(peer.key).checking,
          onRefresh: () => this.refreshPeerServices(peer)
        })
        DeviceActionButtons({
          sunshineState: this.streamingState(peer.key).sunshine.state,
          reachable: this.streamReachable(this.streamingState(peer.key)),
          meshConnected: this.isConnected(),
          peerOnline: this.peerEffectivelyOnline(peer),
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
    .borderRadius(UiTokens.CARD_RADIUS)
  }

  @Builder
  private DevicesPanel() {
    Column({ space: 8 }) {
      this.SectionHeader($r('app.string.devices_title'),
        $r('app.string.devices_count', this.homeOnlinePeers().length + (this.isConnected() ? 1 : 0),
          this.homePeers().length + 1))
      Text('')
        .id('peer-summary')
        .height(1)
        .fontSize(1)
        .accessibilityLevel('no')

      this.DeviceGroupLabel($r('app.string.device_group_local'))
      this.LocalDeviceRow()

      if (this.homeOnlinePeers().length > 0) {
        this.DeviceGroupLabel($r('app.string.device_group_online'))
        Column({ space: 8 }) {
          ForEach(this.homeOnlinePeers(), (peer: PeerSummary) => {
            this.PeerDeviceRow(peer)
          }, (peer: PeerSummary) => peer.key)
        }
        .width('100%')
      }

      if (this.homeOfflinePeers().length > 0) {
        this.DeviceGroupLabel($r('app.string.device_group_offline'))
        Column({ space: 8 }) {
          ForEach(this.homeOfflinePeers(), (peer: PeerSummary) => {
            this.PeerDeviceRow(peer)
          }, (peer: PeerSummary) => peer.key)
        }
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .id('home-device-directory')
  }

  @Builder
  private ColorModeSettingsPanel() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text($r('app.string.native_settings_color_mode'))
          .fontSize(UiTokens.BODY_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
        Text($r('app.string.personalization_color_mode_desc'))
          .fontSize(UiTokens.CAPTION_SIZE)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
      }
      .layoutWeight(1)
      Select([
        { value: $r('app.string.native_settings_system_follow') },
        { value: $r('app.string.personalization_color_light') },
        { value: $r('app.string.personalization_color_dark') }
      ])
        .id('personalization-color-mode')
        .selected(PersonalizationPreferences.colorModeIndex(this.personalizationColorMode))
        .value(this.personalizationColorMode === 'light' ? $r('app.string.personalization_color_light') :
          this.personalizationColorMode === 'dark' ? $r('app.string.personalization_color_dark') :
            $r('app.string.native_settings_system_follow'))
        .controlSize(ControlSize.NORMAL)
        .font({ size: UiTokens.BODY_SIZE })
        .constraintSize({ minWidth: 112, maxWidth: 144 })
        .systemMaterial(LightAppearance.control(this.glowLevel))
        .menuSystemMaterial(LightAppearance.menu(this.glowLevel))
        .onSelect((index: number) => this.setPersonalizationColorMode(index))
    }
    .width('100%')
    .padding(UiTokens.CARD_PADDING)
    .backgroundColor(this.groupBackground())
    .borderRadius(UiTokens.CARD_RADIUS)
  }

  @Builder
  private HomeLayoutSettingsPanel() {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Text($r('app.string.personalization_home_layout'))
          .fontSize(UiTokens.BODY_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Text($r('app.string.personalization_home_layout_desc'))
          .fontSize(UiTokens.CAPTION_SIZE)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Select([{ value: $r('app.string.personalization_home_compact') },
        { value: $r('app.string.personalization_home_classic') }])
        .id('connected-home-layout-select')
        .selected(this.connectedHomeLayoutMode === ConnectedHomeLayoutMode.COMPACT ? 0 : 1)
        .value(this.connectedHomeLayoutMode === ConnectedHomeLayoutMode.COMPACT ?
          $r('app.string.personalization_home_compact') : $r('app.string.personalization_home_classic'))
        .font({ size: UiTokens.BODY_SIZE })
        .optionFont({ size: UiTokens.BODY_SIZE })
        .controlSize(ControlSize.NORMAL)
        .constraintSize({ minWidth: 112, maxWidth: 144 })
        .systemMaterial(LightAppearance.control(this.glowLevel))
        .menuSystemMaterial(LightAppearance.menu(this.glowLevel))
        .onSelect((index: number) => this.setConnectedHomeLayoutMode(index === 0 ?
          ConnectedHomeLayoutMode.COMPACT : ConnectedHomeLayoutMode.LEGACY))
    }
    .id('connected-home-layout-settings')
    .width('100%')
    .constraintSize({ minHeight: 50 })
    .padding(UiTokens.CARD_PADDING)
    .backgroundColor(this.groupBackground())
    .borderRadius(UiTokens.CARD_RADIUS)
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
        .controlSize(ControlSize.SMALL)
        .constraintSize({ minWidth: 100, maxWidth: 144 })
        .systemMaterial(LightAppearance.control(this.glowLevel))
        .menuSystemMaterial(LightAppearance.menu(this.glowLevel))
        .onSelect((index: number, _value?: string) => this.setGlowLevel(index))
    }
    .id('glow-settings')
    .width('100%')
    .constraintSize({ minHeight: 50 })
    .padding(12)
  }

  private navigationTabLabel(id: NavigationTabId): ResourceStr {
    switch (id) {
      case 'transfer': return $r('app.string.tab_transfer');
      case 'files': return $r('app.string.tab_files');
      case 'settings': return $r('app.string.tab_settings');
      default: return $r('app.string.tab_home');
    }
  }

  private navigationTabIcon(id: NavigationTabId): Resource {
    switch (id) {
      case 'transfer': return $r('app.media.tab_transfer');
      case 'files': return $r('app.media.tab_files');
      case 'settings': return $r('app.media.tab_settings');
      default: return $r('app.media.tab_home');
    }
  }

  private saveNavigationPreferences(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const settings: NavigationSettings = {
      order: [...this.navigationOrder], hidden: [...this.hiddenNavigationTabs],
      bottomMargin: this.navigationBottomMargin
    };
    this.navigationSaveQueue = this.navigationSaveQueue.catch(() => {}).then(() =>
      NavigationPreferences.save(context, settings)).catch(() => {
      this.showToast($r('app.string.personalization_save_failed'));
    });
  }

  private setNavigationBottomMargin(value: number): void {
    if (!Number.isFinite(value)) return;
    this.navigationBottomMargin = Math.min(100, Math.max(0, Math.round(value)));
    if (this.navigationMarginSaveTimer >= 0) clearTimeout(this.navigationMarginSaveTimer);
    this.navigationMarginSaveTimer = setTimeout(() => this.flushNavigationMarginPreferences(), 180);
  }

  private flushNavigationMarginPreferences(): void {
    if (this.navigationMarginSaveTimer < 0) return;
    clearTimeout(this.navigationMarginSaveTimer);
    this.navigationMarginSaveTimer = -1;
    this.saveNavigationPreferences();
  }

  private setNavigationTabVisible(id: NavigationTabId, visible: boolean): void {
    if (id === 'settings') {
      // Settings is a permanent primary destination and cannot be hidden.
      if (this.hiddenNavigationTabs.includes(id)) {
        this.hiddenNavigationTabs = this.hiddenNavigationTabs.filter(
          (candidate: NavigationTabId) => candidate !== id);
        this.saveNavigationPreferences();
        this.syncNavigationSelection(this.activeNavigationId, true);
      }
      return;
    }
    if (!visible && this.visibleNavigationTabs().length <= 1) {
      this.showToast($r('app.string.navigation_always_one_visible'));
      return;
    }
    if (visible) {
      this.hiddenNavigationTabs = this.hiddenNavigationTabs.filter(
        (candidate: NavigationTabId) => candidate !== id);
    } else if (!this.hiddenNavigationTabs.includes(id)) {
      this.hiddenNavigationTabs = [...this.hiddenNavigationTabs, id];
    }
    this.saveNavigationPreferences();
    this.syncNavigationSelection(this.activeNavigationId, true);
  }

  private moveNavigationTab(id: NavigationTabId, direction: number): void {
    const index: number = this.navigationOrder.indexOf(id);
    const target: number = index + direction;
    this.moveNavigationTabToIndex(index, target);
  }

  private moveNavigationTabToIndex(from: number, to: number): void {
    if (from < 0 || to < 0 || from >= this.navigationOrder.length ||
      to >= this.navigationOrder.length || from === to) {
      return;
    }
    const next: NavigationTabId[] = [...this.navigationOrder];
    const moved: NavigationTabId = next[from];
    next.splice(from, 1);
    next.splice(to, 0, moved);
    this.navigationOrder = next;
    this.saveNavigationPreferences();
    this.syncNavigationSelection(this.activeNavigationId, true);
  }

  private startNavigationTabDrag(index: number): void {
    const id: NavigationTabId | undefined = this.navigationOrder[index];
    this.navigationDraggingId = id === undefined ? '' : id;
  }

  private finishNavigationTabDrag(): void {
    this.navigationDraggingId = '';
  }

  @Builder
  private NavigationSettingsRow(id: NavigationTabId) {
    Row({ space: 8 }) {
      Image(this.navigationTabIcon(id))
        .width(22)
        .height(22)
        .fillColor($r('app.color.emphasize'))
      Text(this.navigationTabLabel(id))
        .fontSize(14)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch,
        isOn: id === 'settings' || !this.hiddenNavigationTabs.includes(id) })
        .id(`navigation-visible-${id}`)
        .selectedColor($r('app.color.emphasize'))
        .enabled(id !== 'settings')
        .systemMaterial(LightAppearance.control(this.glowLevel))
        .onChange((visible: boolean) => this.setNavigationTabVisible(id, visible))
      Column({ space: 4 }) {
        Row()
          .width(22)
          .height(2)
          .borderRadius(1)
          .backgroundColor($r('app.color.emphasize'))
        Row()
          .width(22)
          .height(2)
          .borderRadius(1)
          .backgroundColor($r('app.color.emphasize'))
        Row()
          .width(22)
          .height(2)
          .borderRadius(1)
          .backgroundColor($r('app.color.emphasize'))
      }
        .width(24)
        .height(24)
        .justifyContent(FlexAlign.Center)
        .accessibilityText($r('app.string.navigation_settings_description'))
    }
    .width('100%')
    .constraintSize({ minHeight: 52 })
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  private NavigationSettingsPanel() {
    Column({ space: 0 }) {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text($r('app.string.navigation_settings_title'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .width('100%')
          Text($r('app.string.navigation_settings_description'))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
            .maxLines(2)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ bottom: 6 })
      Divider().color($r('sys.color.comp_divider'))
      List({ space: 0 }) {
        ForEach(this.navigationOrder, (id: NavigationTabId, index: number) => {
          ListItem() {
            Column({ space: 0 }) {
              this.NavigationSettingsRow(id)
              if (index < this.navigationOrder.length - 1) {
                Divider().color($r('sys.color.comp_divider'))
              }
            }
          }
            .zIndex(this.navigationDraggingId === id ? 10 : 0)
        }, (id: NavigationTabId) => id)
          .onMove((from: number, to: number) => this.moveNavigationTabToIndex(from, to), {
            onDragStart: (index: number) => this.startNavigationTabDrag(index),
            onDrop: (_index: number) => this.finishNavigationTabDrag()
          })
      }
        .width('100%')
        .height(this.navigationOrder.length * 52 + Math.max(0, this.navigationOrder.length - 1))
        .scrollBar(BarState.Off)
    }
    .id('navigation-settings-panel')
    .width('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 8 })
    .backgroundColor(this.groupBackground())
    .borderRadius(UiTokens.CARD_RADIUS)
  }

  private openNativeSettingsPage(pageName: string): void {
    this.nativeSettingsPage = pageName === 'animation' ? 'animation' : 'background';
    this.nativeSettingsVisible = true;
  }

  private canOpenContextGuide(): boolean {
    return this.appShellReady && !this.appLockRequired && !this.appLockAuthenticating &&
      !this.securitySettingsAuthenticating && !this.taildropSendActive() && !this.taildropReceiveInProgress &&
      !this.taildropPickerOpen;
  }

  private openContextGuide(section: string): void {
    if (!this.canOpenContextGuide() || this.contextGuideVisible) return;
    this.contextGuideSection = section;
    this.contextGuidePresentation++;
    this.contextGuideVisible = true;
    this.contextGuideController = new CustomDialogController({
      builder: FeatureSetupDialog({ initialSection: this.contextGuideSection,
        presentationId: this.contextGuidePresentation }),
      alignment: DialogAlignment.Center,
      height: '70%',
      autoCancel: true,
      systemMaterial: LightAppearance.dialog(this.glowLevel),
      onDidDisappear: () => { this.contextGuideVisible = false; }
    });
    this.contextGuideController.open();
  }

  @Builder
  private ContextGuideAction(title: ResourceStr, section: string, actionId: string) {
    Button(title, {
      type: ButtonType.ROUNDED_RECTANGLE, stateEffect: true,
      buttonStyle: ButtonStyleMode.TEXTUAL, controlSize: ControlSize.NORMAL
    })
      .fontSize(UiTokens.BODY_SIZE)
      .constraintSize({ minHeight: UiTokens.ACTION_HEIGHT })
      .id(actionId)
      .enabled(this.canOpenContextGuide())
      .onClick(() => this.openContextGuide(section))
  }

  private transferSetupNotice(): string {
    return transferGuideNotice({ connected: this.isConnected(), refreshing: this.transferProtocolRefreshing,
      state: this.taildropState, taildropTargets: this.displayedTaildropTargets().length,
      busy: !this.canOpenContextGuide() });
  }

  private openSettingsDetail(pageName: string): void {
    const now: number = Date.now();
    if (pageName.length === 0 || now < this.settingsNavigationLockUntilMs) {
      return;
    }
    if (pageName === 'storage') {
      this.storageRingGeneration++;
      this.storageRingPageShown = false;
      this.storageRingAnimationStarted = false;
      this.storageRingProgress = 0;
      this.refreshCacheSize(false);
    }
    this.settingsNavigationLockUntilMs = now + MotionTokens.PAGE;
    this.settingsDetailActive = true;
    this.settingsPathStack.pushPath({ name: pageName }, true);
  }

  private settingsStorageTotalBytes(): number {
    return Math.max(0, this.nativeStorageAppDataBytes) + Math.max(0, this.nativeStorageReceivedBytes) +
      Math.max(0, this.nativeStorageTemporaryBytes);
  }

  private featureDiagnosticToken(value: string, fallback: string = 'unknown'): string {
    return sanitizeVpnDiagnosticToken(value, fallback);
  }

  private featureDiagnosticCount(value: number): number {
    return sanitizeVpnDiagnosticCount(value);
  }

  private recordFeatureDiagnosticEvent(event: string, phase: string, code: number = 0): void {
    const safeEvent: string = this.featureDiagnosticToken(event);
    const safePhase: string = this.featureDiagnosticToken(phase);
    const safeCode: number = Number.isFinite(code) ? code : 0;
    hilog.info(FEATURE_DIAGNOSTIC_LOG_DOMAIN, FEATURE_DIAGNOSTIC_LOG_TAG,
      'event=%{public}s phase=%{public}s code=%{public}d', safeEvent, safePhase, safeCode);
    this.recordDiagnosticEvent(safeEvent, safePhase, safeCode);
  }

  private localSendStateCount(state: string): number {
    if (!this.isConnected()) {
      return 0;
    }
    return this.peers.filter((peer: PeerSummary) => this.peerEffectivelyOnline(peer) &&
      (peer.localSend?.state ?? 'unknown') === state).length;
  }

  private mediaAvailablePeerCount(): number {
    return this.mediaStates.filter((state: DeviceMediaState) => state.result.services.length > 0).length;
  }

  private mediaCheckingPeerCount(): number {
    return this.mediaStates.filter((state: DeviceMediaState) => state.checking ||
      state.result.state === 'checking').length;
  }

  private mediaServiceCount(): number {
    let count: number = 0;
    this.mediaStates.forEach((state: DeviceMediaState) => count += state.result.services.length);
    return count;
  }

  private sunshineAvailablePeerCount(): number {
    return this.streamingStates.filter((state: DeviceStreamingState) =>
      state.sunshine.state === 'available').length;
  }

  private sunshineCheckingPeerCount(): number {
    return this.streamingStates.filter((state: DeviceStreamingState) => state.checking ||
      state.sunshine.state === 'checking').length;
  }

  private hosPlayerSelfTestState(): string {
    if (this.mediaSelfTestStatus.startsWith('PASS')) {
      return 'passed';
    }
    if (this.mediaSelfTestStatus.startsWith('FAILED')) {
      return 'failed';
    }
    return this.mediaSelfTestInProgress ? 'running' : 'not_run';
  }

  private logServiceStatusIfChanged(): void {
    const localAvailable: number = this.localSendStateCount('available');
    const localChecking: number = this.localSendStateCount('checking');
    const mediaAvailable: number = this.mediaAvailablePeerCount();
    const mediaServices: number = this.mediaServiceCount();
    const sunshineAvailable: number = this.sunshineAvailablePeerCount();
    const receiverState: string = this.featureDiagnosticToken(this.meshArcReceiver.state);
    const taildropState: string = this.featureDiagnosticToken(this.taildropState);
    const signature: string = `${localAvailable}|${localChecking}|${mediaAvailable}|${mediaServices}|` +
      `${sunshineAvailable}|${receiverState}|${taildropState}`;
    if (signature === this.featureServiceLogSignature) {
      return;
    }
    this.featureServiceLogSignature = signature;
    hilog.info(FEATURE_DIAGNOSTIC_LOG_DOMAIN, FEATURE_DIAGNOSTIC_LOG_TAG,
      'service snapshot localAvailable=%{public}d localChecking=%{public}d mediaPeers=%{public}d ' +
      'mediaServices=%{public}d sunshine=%{public}d receiver=%{public}s taildrop=%{public}s',
      localAvailable, localChecking, mediaAvailable, mediaServices, sunshineAvailable,
      receiverState, taildropState);
    this.recordDiagnosticEvent('service_status_changed', receiverState,
      localAvailable + mediaServices + sunshineAvailable);
  }

  private setDiagnosticFeatureEnabled(feature: string, enabled: boolean): void {
    if (feature === 'quick_transfer') {
      this.diagnosticQuickTransferEnabled = enabled;
    } else if (feature === 'service_monitoring') {
      this.diagnosticServiceMonitoringEnabled = enabled;
    } else if (feature === 'security') {
      this.diagnosticSecurityEnabled = enabled;
    } else if (feature === 'appearance') {
      this.diagnosticAppearanceEnabled = enabled;
    } else {
      return;
    }
    this.recordFeatureDiagnosticEvent('diagnostic_module_changed',
      `${feature}_${enabled ? 'enabled' : 'disabled'}`);
  }

  private diagnosticEnabledModuleCount(): number {
    return (this.diagnosticQuickTransferEnabled ? 1 : 0) +
      (this.diagnosticServiceMonitoringEnabled ? 1 : 0) +
      (this.diagnosticSecurityEnabled ? 1 : 0) +
      (this.diagnosticAppearanceEnabled ? 1 : 0);
  }

  private localSendDiagnosticStatus(): string {
    return `available=${this.localSendStateCount('available')} · ` +
      `checking=${this.localSendStateCount('checking')} · ` +
      `unavailable=${this.localSendStateCount('unavailable') + this.localSendStateCount('offline')}`;
  }

  private meshArcReceiverDiagnosticStatus(): string {
    return `state=${this.featureDiagnosticToken(this.meshArcReceiver.state)} · ` +
      `protocol=${this.featureDiagnosticToken(this.meshArcReceiver.protocol ?? '', 'unknown')} · ` +
      `registered=${this.meshArcReceiver.registered}/${this.meshArcReceiver.sent}`;
  }

  private mediaHosPlayerDiagnosticStatus(): string {
    return `peers=${this.mediaAvailablePeerCount()} · services=${this.mediaServiceCount()} · ` +
      `hosplayer=${this.hosPlayerSelfTestState()}`;
  }

  private serviceMonitorDiagnosticStatus(): string {
    const polling: string = this.serviceRefreshTimer >= 0 ? 'active' : 'stopped';
    if (this.diagnosticServiceLastRefreshMs <= 0) {
      return `polling=${polling} · lastRefresh=never`;
    }
    const ageSeconds: number = Math.max(0,
      Math.floor((Date.now() - this.diagnosticServiceLastRefreshMs) / 1000));
    return `polling=${polling} · lastRefresh=${ageSeconds}s`;
  }

  private mediaMonitorDiagnosticStatus(): string {
    return `availablePeers=${this.mediaAvailablePeerCount()} · checking=${this.mediaCheckingPeerCount()} · ` +
      `services=${this.mediaServiceCount()}`;
  }

  private sunshineMonitorDiagnosticStatus(): string {
    return `available=${this.sunshineAvailablePeerCount()} · checking=${this.sunshineCheckingPeerCount()}`;
  }

  private securityDiagnosticStatus(): string {
    return `appLock=${this.appLockEnabled} · required=${this.appLockRequired} · ` +
      `authenticating=${this.appLockAuthenticating || this.securitySettingsAuthenticating}`;
  }

  private folderSecurityDiagnosticStatus(): string {
    return `folderLock=${this.folderLockEnabled} · lockedFolders=${this.lockedFolderPaths.length}`;
  }

  private appearanceBackgroundDiagnosticStatus(): string {
    return `customBackground=${this.nativeSettingsBackgroundUri.length > 0} · ` +
      `immersiveColor=${this.immersiveColorBackgroundEnabled}`;
  }

  private appearanceLayoutDiagnosticStatus(): string {
    return `glowLevel=${this.glowLevel} · homeLayout=${this.connectedHomeLayoutMode} · ` +
      `visibleTabs=${this.visibleNavigationTabs().length} · bottomMargin=${this.navigationBottomMargin}`;
  }

  private refreshFeatureDiagnostics(): void {
    if (this.diagnosticFeatureRefreshInProgress) {
      return;
    }
    this.diagnosticFeatureRefreshInProgress = true;
    this.diagnosticFeatureRefreshStatus = 'refreshing';
    this.recordFeatureDiagnosticEvent('feature_diagnostics_refresh_started', 'manual');
    const generation: number = this.lifecycleGeneration;
    this.refreshPeerSnapshot();
    this.refreshTaildropSnapshot(this.isConnected());
    this.requestLocalSendRefresh().then(() => {
      if (generation !== this.lifecycleGeneration || !this.appShellReady) {
        return;
      }
      this.refreshPeerSnapshot();
      this.autoProbeConnectedPeerServices(true);
      this.diagnosticServiceLastRefreshMs = Date.now();
      this.diagnosticFeatureRefreshStatus = 'completed · online probes continue in background';
      this.logServiceStatusIfChanged();
      this.recordFeatureDiagnosticEvent('feature_diagnostics_refresh_completed', 'manual',
        this.localSendStateCount('available') + this.mediaServiceCount() +
        this.sunshineAvailablePeerCount());
    }).catch((error: Object) => {
      if (generation !== this.lifecycleGeneration || !this.appShellReady) {
        return;
      }
      const businessError: BusinessError = error as BusinessError;
      this.diagnosticFeatureRefreshStatus = 'failed';
      this.recordFeatureDiagnosticEvent('feature_diagnostics_refresh_failed', 'manual',
        businessError.code ?? -1);
    }).finally(() => {
      if (generation === this.lifecycleGeneration) {
        this.diagnosticFeatureRefreshInProgress = false;
      }
    });
  }

  private runDiagnosticSecuritySelfTest(): void {
    if (this.diagnosticSecuritySelfTestInProgress || this.securitySettingsAuthenticating ||
      this.appLockAuthenticating) {
      return;
    }
    this.diagnosticSecuritySelfTestInProgress = true;
    this.diagnosticSecuritySelfTestStatus = 'waiting for system authentication';
    this.recordFeatureDiagnosticEvent('security_self_test_started', 'system_auth');
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const title: string = context.resourceManager.getStringSync(
      $r('app.string.security_settings_authentication_title').id);
    AppSecurityAuthenticator.authenticate(title).then((passed: boolean) => {
      this.diagnosticSecuritySelfTestStatus = passed ? 'PASS · system authentication completed' :
        'FAILED · system authentication not completed';
      this.recordFeatureDiagnosticEvent(passed ? 'security_self_test_passed' :
        'security_self_test_failed', 'system_auth');
    }).catch((error: Object) => {
      const businessError: BusinessError = error as BusinessError;
      this.diagnosticSecuritySelfTestStatus = 'FAILED · authentication setup error';
      this.recordFeatureDiagnosticEvent('security_self_test_failed', 'exception',
        businessError.code ?? -1);
    }).finally(() => {
      this.diagnosticSecuritySelfTestInProgress = false;
    });
  }

  private storageTotalValueLabel(): string {
    const bytes: number = this.settingsStorageTotalBytes();
    if (bytes >= 1024 * 1024 * 1024) {
      return (bytes / (1024 * 1024 * 1024)).toFixed(1);
    }
    if (bytes >= 1024 * 1024) {
      return (bytes / (1024 * 1024)).toFixed(1);
    }
    if (bytes >= 1024) {
      return (bytes / 1024).toFixed(1);
    }
    return Math.round(bytes).toString();
  }

  private storageTotalUnitLabel(): string {
    const bytes: number = this.settingsStorageTotalBytes();
    if (bytes >= 1024 * 1024 * 1024) {
      return 'GB';
    }
    if (bytes >= 1024 * 1024) {
      return 'MB';
    }
    if (bytes >= 1024) {
      return 'KB';
    }
    return 'B';
  }

  private storageSummaryLabel(): ResourceStr {
    if (!this.storageUsageReady) {
      return this.storageScanFailed ? $r('app.string.settings_storage_read_failed') :
        $r('app.string.settings_cache_calculating');
    }
    return `${this.storageTotalValueLabel()} ${this.storageTotalUnitLabel()}`;
  }

  private startStorageRingAnimation(): void {
    if (!this.storageRingPageShown || !this.storageUsageReady || this.storageRingAnimationStarted) return;
    this.storageRingAnimationStarted = true;
    const generation: number = this.storageRingGeneration;
    // Allow the zero state to render once; refreshing statistics must never replay this animation.
    this.scheduleLifecycleTask(() => {
      if (!this.storageRingPageShown || generation !== this.storageRingGeneration) return;
      this.getUIContext().animateTo({ duration: MotionTokens.duration(700), curve: Curve.EaseOut }, () => {
        this.storageRingProgress = 1;
      });
    }, 32);
  }

  private storageUsagePanelValues(): number[] {
    const values: number[] = [Math.max(0, this.nativeStorageAppDataBytes),
      Math.max(0, this.nativeStorageReceivedBytes), Math.max(0, this.nativeStorageTemporaryBytes)];
    const total: number = values[0] + values[1] + values[2];
    if (total <= 0) return [0, 0, 0];
    const progress: number = Math.min(1, Math.max(0, this.storageRingProgress));
    // Integer hundredths make the final sum exactly 100, including empty categories.
    const last: number = values[2] > 0 ? 2 : values[1] > 0 ? 1 : 0;
    let remaining: number = 10000;
    const percentages: number[] = [0, 0, 0];
    for (let index: number = 0; index <= last; index++) {
      const units: number = index === last ? remaining : Math.floor(values[index] / total * 10000);
      percentages[index] = units / 100 * progress;
      remaining -= units;
    }
    return percentages;
  }

  @Builder
  private NativeAppearanceEntry() {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Row({ space: 12 }) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.picture'))
            .fontSize(UiTokens.ICON_LIST_LEADING)
            .fontColor([$r('app.color.emphasize')])
        }
        .width(UiTokens.ICON_LIST_CONTAINER)
        .height(UiTokens.ICON_LIST_CONTAINER)
        .borderRadius(UiTokens.ICON_LIST_CONTAINER_RADIUS)
        .backgroundColor(this.secondaryBackground())
        Column({ space: 3 }) {
          Text($r('app.string.native_settings_background_material'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(UiTokens.ICON_CHEVRON)
          .fontColor([$r('sys.color.icon_secondary')])
      }
      .width('100%')
      .height('100%')
      .padding({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING })
    }
    .id('native-settings-entry')
    .width('100%')
    .height(64)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .onClick(() => this.openNativeSettingsPage('background'))
  }

  @Builder
  private NativeAnimationEntry() {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Row({ space: 12 }) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(UiTokens.ICON_LIST_LEADING)
            .fontColor([$r('app.color.emphasize')])
        }
        .width(UiTokens.ICON_LIST_CONTAINER)
        .height(UiTokens.ICON_LIST_CONTAINER)
        .borderRadius(UiTokens.ICON_LIST_CONTAINER_RADIUS)
        .backgroundColor(this.secondaryBackground())
        Column({ space: 3 }) {
          Text($r('app.string.native_settings_animation'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(UiTokens.ICON_CHEVRON)
          .fontColor([$r('sys.color.icon_secondary')])
      }
      .width('100%')
      .height('100%')
      .padding({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING })
    }
    .id('native-animation-entry')
    .width('100%')
    .height(64)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .onClick(() => this.openNativeSettingsPage('animation'))
  }

  @Builder
  private NavigationMarginSettingsPanel() {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        Text($r('app.string.personalization_tab_margin'))
          .fontSize(UiTokens.BODY_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
        Text(`${this.navigationBottomMargin} vp`)
          .fontSize(UiTokens.CAPTION_SIZE)
          .fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
      Text($r('app.string.personalization_tab_margin_desc'))
        .fontSize(UiTokens.CAPTION_SIZE)
        .fontColor($r('sys.color.font_secondary'))
        .width('100%')
      Slider({ value: this.navigationBottomMargin, min: 0, max: 100, step: 1 })
        .id('personalization-tab-bottom-margin')
        .width('100%')
        .accessibilityText($r('app.string.personalization_tab_margin'))
        .accessibilityDescription(`${this.navigationBottomMargin} vp`)
        .systemMaterial(LightAppearance.control(this.glowLevel))
        .onChange((value: number) => this.setNavigationBottomMargin(value))
    }
    .width('100%')
    .padding(UiTokens.CARD_PADDING)
    .backgroundColor(this.groupBackground())
    .borderRadius(UiTokens.CARD_RADIUS)
  }

  @Builder
  private AppearanceSettingsPanel() {
    Column({ space: UiTokens.GROUP_GAP }) {
      this.ColorModeSettingsPanel()
      this.HomeLayoutSettingsPanel()
      Column({ space: 0 }) {
        this.NativeAppearanceEntry()
        Divider().color($r('sys.color.comp_divider')).margin({ left: 66, right: 16 })
        this.NativeAnimationEntry()
      }
      .width('100%')
      .backgroundColor(this.groupBackground())
      .borderRadius(UiTokens.CARD_RADIUS)
      .clip(true)
      this.NavigationSettingsPanel()
      this.NavigationMarginSettingsPanel()
    }
    .id('appearance-settings')
    .width('100%')
  }

  @Builder
  private StorageUsageLegendRow($$: StorageLegendRowData): void {
    Row({ space: 12 }) {
      Row()
        .width(10)
        .height(10)
        .borderRadius(5)
        .backgroundColor($$.color)
      Text($$.title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.storageUsageReady ? this.formatTrafficBytes(Math.max(0, $$.bytes)) : '—')
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(1)
    }
      .width('100%')
      .height(60)
      .padding({ left: 14, right: 14 })
  }

  @Builder
  private StorageUsageRing(): void {
    Stack({ alignContent: Alignment.Center }) {
      DataPanel({ values: this.storageUsagePanelValues(), max: 100, type: DataPanelType.Circle })
        .valueColors([$r('app.color.emphasize'), $r('app.color.status_media_available'), $r('app.color.status_warning')])
        .trackBackgroundColor($r('sys.color.comp_background_tertiary'))
        .strokeWidth(20)
        .closeEffect(true)
        .width(244)
        .height(244)

      Column({ space: 8 }) {
        if (this.storageUsageReady) {
        Row({ space: 5 }) {
          Text(this.storageTotalValueLabel())
            .fontSize(48)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'))
          Text(this.storageTotalUnitLabel())
            .fontSize(21)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_secondary'))
        }
        .alignItems(VerticalAlign.Bottom)
        } else {
          Text(this.storageSummaryLabel())
            .fontSize(16).fontColor($r('sys.color.font_secondary'))
        }
        Text($r('app.string.native_settings_storage_total'))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_secondary'))
      }
      .alignItems(HorizontalAlign.Center)
    }
      .width(244)
      .height(244)
  }

  @Builder
  private StorageCleanupButton($$: StorageCleanupButtonData): void {
    Column() {
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        Row({ space: 12 }) {
          Stack({ alignContent: Alignment.Center }) {
            SymbolGlyph($r('sys.symbol.trash'))
              .fontSize(UiTokens.ICON_LIST_LEADING)
              .fontColor([$r('app.color.status_error')])
          }
          .width(UiTokens.ICON_LIST_CONTAINER)
          .height(UiTokens.ICON_LIST_CONTAINER)
          .borderRadius(UiTokens.ICON_LIST_CONTAINER_RADIUS)
          .backgroundColor($r('app.color.badge_background_error'))
          Column({ space: 2 }) {
            Text($$.title)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.status_error'))
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text($$.description)
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
        }
          .width('100%')
          .height('100%')
          .padding({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING })
      }
        .id($$.rowId)
        .width('100%')
        .height(68)
        .padding(0)
        .backgroundColor(Color.Transparent)
        .enabled($$.enabled)
        .onClick($$.onClick)
    }
      .width('100%')
      .backgroundColor(this.groupBackground())
      .borderRadius(UiTokens.CARD_RADIUS)
      .clip(true)
  }

  @Builder
  private CacheSettingsPanel() {
    Column({ space: 6 }) {
      this.StorageUsageRing()

      Column({ space: 0 }) {
        this.StorageUsageLegendRow({ title: $r('app.string.native_settings_storage_app_data'),
            bytes: this.nativeStorageAppDataBytes,
            color: $r('app.color.emphasize') })
        Divider().color($r('sys.color.comp_divider')).margin({ left: 20, right: 20 })
        this.StorageUsageLegendRow({ title: $r('app.string.native_settings_storage_received'),
            bytes: this.nativeStorageReceivedBytes,
            color: $r('app.color.status_media_available') })
        Divider().color($r('sys.color.comp_divider')).margin({ left: 20, right: 20 })
        this.StorageUsageLegendRow({ title: $r('app.string.native_settings_storage_temporary'),
            bytes: this.nativeStorageTemporaryBytes,
            color: $r('app.color.status_warning') })
      }
      .width('100%')
      .backgroundColor(this.groupBackground())
      .borderRadius(UiTokens.CARD_RADIUS)
      .clip(true)

      Column({ space: 8 }) {
        this.StorageCleanupButton({ title: $r('app.string.native_settings_storage_clear_cache'),
            description: $r('app.string.native_settings_storage_clear_cache_description'),
            rowId: 'settings-clear-cache',
            enabled: (this.nativeStorageTemporaryBytes > 0 || this.taildropPreviewCacheAvailable()) &&
            !this.cacheClearBlocked(),
            onClick: () => this.clearTemporaryStorage() })
        this.StorageCleanupButton({ title: $r('app.string.native_settings_storage_clear'),
            description: $r('app.string.native_settings_storage_clear_description'),
            rowId: 'settings-clear-all-local-files',
            enabled: this.storageAllLocalFilesClearEnabled(),
            onClick: () => this.confirmClearAppCache() })
      }
        .width('100%')
    }
    .id('storage-management')
    .width('100%')
    .padding({ top: 12, bottom: 24 })
  }

  @Builder
  private AccountIdentityRow(showOpenButton: boolean): void {
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
            .fontColor($r('app.color.emphasize'))
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

      if (showOpenButton) {
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(UiTokens.ICON_CHEVRON)
            .fontColor([$r('sys.color.icon_secondary')])
        }
          .id('account-open')
          .width(40)
          .height(40)
          .padding(0)
          .backgroundColor(Color.Transparent)
          .accessibilityText($r('app.string.account_open_details'))
          .onClick(() => this.openSettingsDetail('account'))
      }
    }
    .width('100%')
  }

  @Builder
  private AccountPanel() {
    Column({ space: 6 }) {
      if (!this.isAuthenticated() && !this.isConnected() && !this.isConnecting() &&
        !this.connectInProgress && !this.disconnectInProgress) {
      Row({ space: 8 }) {
        Select(this.controlServerPresetOptions())
          .id('control-server-presets')
          .selected(this.selectedControlServerPreset())
          .value(this.controlServerURL === DEFAULT_CONTROL_SERVER_URL ? 'Tailscale' : this.controlServerURL)
          .layoutWeight(1)
          .enabled(this.canSwitchControlServer())
          .systemMaterial(LightAppearance.control(this.glowLevel))
          .menuSystemMaterial(LightAppearance.menu(this.glowLevel))
          .onSelect((index: number) => this.selectControlServerPreset(index))
        Button($r('app.string.control_server_manage'), { type: ButtonType.Normal, buttonStyle: ButtonStyleMode.NORMAL })
          .height(40).fontSize(14)
          .border({ radius: 10, width: 0.5, color: $r('sys.color.comp_divider') })
          .id('control-server-manage')
          .enabled(this.canSwitchControlServer())
          .onClick(() => this.toggleControlServerEditor())
      }
      .width('100%')
      Row({ space: 8 }) {
        Select(this.accountProfileOptions())
          .id('account-profile-select')
          .selected(Math.max(0, this.accountProfiles.findIndex((item: AccountProfile) => item.id === this.accountProfileId)))
          .value(this.activeAccountProfileLabel())
          .layoutWeight(1)
          .enabled(this.canSwitchControlServer() && this.controlServerConfirmed)
          .systemMaterial(LightAppearance.control(this.glowLevel))
          .menuSystemMaterial(LightAppearance.menu(this.glowLevel))
          .onSelect((index: number) => {
            if (index >= 0 && index < this.accountProfiles.length) {
              this.persistAccountProfile(this.accountProfiles[index].id);
            }
          })
        Button($r('app.string.account_profile_add'), { type: ButtonType.Normal, buttonStyle: ButtonStyleMode.NORMAL })
          .height(40).fontSize(14)
          .border({ radius: 10, width: 0.5, color: $r('sys.color.comp_divider') })
          .id('account-profile-add')
          .enabled(this.canSwitchControlServer() && this.controlServerConfirmed && this.accountProfiles.length < 16)
          .onClick(() => this.persistAccountProfile('', true))
      }
      .width('100%')
      }
      if (this.loginInProgress && this.loginHandoffStatus === 'Secure login page opened') {
        Button($r('app.string.account_profile_stop_login'))
          .id('account-profile-stop-login')
          .onClick(() => this.stopWaitingForAccountLogin())
      }
      if (this.accountProfileStatus === 'failed') {
        Text($r('app.string.account_profile_failed'))
          .fontSize(12).fontColor($r('app.color.status_error')).width('100%')
      }
      if (this.controlServerSwitching) {
        Text($r('app.string.control_server_switching'))
          .fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
      }
      if (this.controlServerEditorVisible && !this.isAuthenticated() && !this.isConnected() && !this.isConnecting() &&
        !this.connectInProgress && !this.disconnectInProgress) {
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
        AccountTextField({
          value: $controlServerInput,
          fieldId: 'control-server-input',
          placeholder: DEFAULT_CONTROL_SERVER_URL,
          inputEnabled: this.canSwitchControlServer(),
          onEdited: (): void => { this.controlServerStatus = ''; }
        })
        Button($r('app.string.control_server_save'), {
          type: ButtonType.ROUNDED_RECTANGLE,
          stateEffect: true,
          buttonStyle: ButtonStyleMode.NORMAL,
          controlSize: ControlSize.NORMAL
        })
          .id('control-server-save')
          .width('100%')
          .enabled(this.canSwitchControlServer())
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
          TransitionEffect.OPACITY.animation({ duration: MotionTokens.PAGE, curve: MotionTokens.curve() })
            .combine(TransitionEffect.translate({ y: MotionTokens.amplitude(-12) })),
          TransitionEffect.OPACITY.animation({ duration: MotionTokens.FAST, curve: MotionTokens.curve() })
            .combine(TransitionEffect.translate({ y: MotionTokens.amplitude(-8) }))
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
              .enabled(!this.loginInProgress)
              .onClick(() => this.toggleControlServerEditor())
          }
        }
        .width('100%')
        Button($r('app.string.auth_key_login_action'), {
          type: ButtonType.ROUNDED_RECTANGLE,
          buttonStyle: ButtonStyleMode.NORMAL
        })
          .id('account-auth-key-login')
          .width('100%')
          .height(48)
          .enabled(!this.loginInProgress)
          .onClick(() => this.toggleAuthKeyLogin())
        if (this.authKeyLoginVisible) {
          this.AuthKeyLoginForm()
        }
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
        this.AccountIdentityRow(true)

        Divider().color($r('sys.color.comp_divider'))
        this.AccountDetailRow($r('app.string.account_tailnet'),
          this.accountSummary.tailnetName, 'account-tailnet')
        this.AccountDetailRow($r('app.string.account_device'),
          this.localDeviceName(), 'account-device')
      }

      if (this.authKeyStatus.length > 0) {
        Text(this.authKeyStatusText())
          .id('auth-key-login-status')
          .fontSize(12)
          .fontColor(this.authKeyStatus === 'authenticated' ? $r('app.color.status_success') :
            this.authKeyStatus === 'loading' || this.authKeyStatus === 'needs_approval' ?
              $r('sys.color.font_secondary') : $r('app.color.status_error'))
          .width('100%')
      }

    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.groupBackground())
    .borderRadius(UiTokens.CARD_RADIUS)
  }

  @Builder
  private AuthKeyLoginForm() {
    Column({ space: 12 }) {
      Text($r('app.string.auth_key_description'))
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
        .width('100%')
      Text(this.controlServerURL)
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
        .width('100%')
      AccountTextField({
        value: $authKeyInput,
        fieldId: 'auth-key-input',
        placeholder: $r('app.string.auth_key_placeholder'),
        password: true,
        inputEnabled: !this.loginInProgress,
        onEdited: (): void => { this.authKeyStatus = ''; }
      })
      Text($r('app.string.auth_key_privacy'))
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
        .width('100%')
      Row({ space: 8 }) {
        Button($r('app.string.cancel_action'), { buttonStyle: ButtonStyleMode.NORMAL })
          .layoutWeight(1)
          .enabled(!this.loginInProgress)
          .onClick(() => this.toggleAuthKeyLogin())
        Button(this.loginInProgress ? $r('app.string.auth_key_loading') :
          $r('app.string.auth_key_submit'))
          .id('auth-key-submit')
          .layoutWeight(1)
          .enabled(!this.loginInProgress && this.authKeyInput.trim().length > 0)
          .onClick(() => this.submitAuthKeyLogin())
      }
      .width('100%')
    }
    .width('100%')
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
  private AccountDetailPanel() {
    Column({ space: 8 }) {
      this.AccountIdentityRow(false)
      Divider().color($r('sys.color.comp_divider'))
      this.AccountDetailRow($r('app.string.account_tailnet'),
        this.accountSummary.tailnetName, 'account-detail-tailnet')
      this.AccountDetailRow($r('app.string.account_device'),
        this.localDeviceName(), 'account-detail-device')

      if (this.isConnected()) {
        Text($r('app.string.logout_disconnect_first'))
          .id('logout-disconnect-first')
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
      } else {
        Text($r('app.string.logout_description'))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
        Button({ type: ButtonType.Normal, stateEffect: true }) {
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
          .border({ width: 1, color: $r('sys.color.comp_divider'), radius: 20 })
          .enabled(!this.logoutInProgress)
          .opacity(this.logoutInProgress ? 0.5 : 1)
          .onClick(() => this.confirmLogout())
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
    .padding(16)
    .backgroundColor(this.groupBackground())
    .borderRadius(UiTokens.CARD_RADIUS)
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
  private UpdateChangelogActionRow() {
    Button({
      type: ButtonType.Normal,
      stateEffect: true,
      buttonStyle: ButtonStyleMode.TEXTUAL,
      controlSize: ControlSize.NORMAL
    }) {
      Row({ space: 12 }) {
        Text($r('app.string.update_changelog_title'))
          .fontSize(13)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(UiTokens.ICON_CHEVRON)
          .fontColor([$r('sys.color.icon_secondary')])
      }
      .width('100%')
    }
    .id('update-changelog-settings-action')
    .width('100%')
    .height(40)
    .padding(0)
    .borderRadius(12)
    .backgroundColor(Color.Transparent)
    .onClick(() => this.openUpdateChangelogFromSettings())
  }

  @Builder
  private VersionPanel() {
    Column({ space: 0 }) {
      this.AppVersionActionRow()
      Divider().color($r('sys.color.comp_divider'))
      this.UpdateChangelogActionRow()
      Divider().color($r('sys.color.comp_divider'))
      this.AccountDetailRow($r('app.string.tailscale_version_label'),
        this.tailscaleVersion, 'tailscale-version')
      Divider().color($r('sys.color.comp_divider'))
      this.AccountDetailRow($r('app.string.feedback_email_with_diagnostics'), FEEDBACK_EMAIL,
        'feedback-email', () => this.openFeedbackEmail())
      this.FeedbackEmailStatus()
    }
    .width('100%')
    .padding(UiTokens.CARD_PADDING)
    .backgroundColor(this.groupBackground())
    .borderRadius(UiTokens.CARD_RADIUS)
  }

  @Builder
  private FeedbackEmailStatus() {
    if (this.feedbackEmailStatus.length > 0) {
      Text(this.feedbackEmailStatus === 'preparing' ? $r('app.string.diagnostic_report_generating') :
        this.feedbackEmailStatus === 'failed' ? $r('app.string.feedback_email_attachment_failed') :
        $r('app.string.feedback_email_prepared'))
        .id('feedback-email-status')
        .fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
      if (this.feedbackEmailStatus === 'failed') {
        this.StandardActionButton($r('app.string.diagnostic_report_action'), 'feedback-diagnostic-export',
          false, this.canUseStandaloneDiagnostics() && !this.diagnosticReportInProgress,
          () => this.generateDiagnosticReport())
      }
    }
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
  private DiagnosticOptionRow(title: ResourceStr | string, description: ResourceStr | string,
    enabled: boolean, nodeId: string, onChange: (enabled: boolean) => void) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
        Text(description)
          .fontSize(11)
          .fontColor($r('sys.color.font_secondary'))
          .lineHeight(17)
          .maxLines(3)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: enabled })
        .id(nodeId)
        .selectedColor($r('app.color.emphasize'))
        .systemMaterial(LightAppearance.control(this.glowLevel))
        .onChange(onChange)
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  private DiagnosticsFeatureOptionsPanel() {
    Column({ space: 4 }) {
      this.DiagnosticSectionHeader($r('app.string.diagnostic_feature_options_title'),
        $r('app.string.diagnostic_feature_options_description'))
      this.DiagnosticStatus($r('app.string.diagnostic_enabled_modules_title'),
        `${this.diagnosticEnabledModuleCount()}/4`, 'diagnostic-feature-enabled-count')
      this.DiagnosticOptionRow($r('app.string.diagnostic_quick_transfer_option_title'),
        $r('app.string.diagnostic_quick_transfer_option_description'),
        this.diagnosticQuickTransferEnabled, 'diagnostic-option-quick-transfer',
        (enabled: boolean) => this.setDiagnosticFeatureEnabled('quick_transfer', enabled))
      this.DiagnosticOptionRow($r('app.string.diagnostic_service_monitoring_option_title'),
        $r('app.string.diagnostic_service_monitoring_option_description'),
        this.diagnosticServiceMonitoringEnabled, 'diagnostic-option-service-monitoring',
        (enabled: boolean) => this.setDiagnosticFeatureEnabled('service_monitoring', enabled))
      this.DiagnosticOptionRow($r('app.string.diagnostic_security_option_title'),
        $r('app.string.diagnostic_security_option_description'),
        this.diagnosticSecurityEnabled, 'diagnostic-option-security',
        (enabled: boolean) => this.setDiagnosticFeatureEnabled('security', enabled))
      this.DiagnosticOptionRow($r('app.string.diagnostic_appearance_option_title'),
        $r('app.string.diagnostic_appearance_option_description'),
        this.diagnosticAppearanceEnabled, 'diagnostic-option-appearance',
        (enabled: boolean) => this.setDiagnosticFeatureEnabled('appearance', enabled))
    }
    .width('100%')
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
      if (BuildProfile.DEBUG) {
        this.StandardActionButton($r('app.string.diagnostic_simulate_crash_action'),
          'diagnostic-simulate-crash', false, !this.diagnosticActionInProgress,
          () => this.confirmSimulateAppCrash(), false, true)
      }
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
          .selectedColor($r('app.color.emphasize'))
          .systemMaterial(LightAppearance.control(this.glowLevel))
          .onChange((enabled: boolean) => {
            this.fakeMediaServiceOnline = enabled;
            this.recordFeatureDiagnosticEvent('fake_media_service_changed',
              enabled ? 'enabled' : 'disabled');
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
      this.DiagnosticStatus($r('app.string.diagnostic_localsend_status_title'),
        this.localSendDiagnosticStatus(), 'diagnostic-localsend-status')
      this.DiagnosticStatus($r('app.string.diagnostic_mesharc_receiver_status_title'),
        this.meshArcReceiverDiagnosticStatus(), 'diagnostic-meshlite-receiver-status')
      this.DiagnosticStatus($r('app.string.diagnostic_hosplayer_status_title'),
        this.mediaHosPlayerDiagnosticStatus(), 'diagnostic-hosplayer-status')
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
  private DiagnosticsServiceMonitoringPanel() {
    Column({ space: 8 }) {
      this.DiagnosticSectionHeader($r('app.string.diagnostic_service_monitoring_title'),
        $r('app.string.diagnostic_service_monitoring_description'))
      this.DiagnosticStatus($r('app.string.diagnostic_service_polling_status_title'),
        this.serviceMonitorDiagnosticStatus(), 'diagnostic-service-polling-status')
      this.DiagnosticStatus($r('app.string.diagnostic_media_service_status_title'),
        this.mediaMonitorDiagnosticStatus(), 'diagnostic-media-service-status')
      this.DiagnosticStatus($r('app.string.diagnostic_sunshine_service_status_title'),
        this.sunshineMonitorDiagnosticStatus(), 'diagnostic-sunshine-service-status')
      this.DiagnosticStatus($r('app.string.diagnostic_taildrop_service_status_title'),
        this.featureDiagnosticToken(this.taildropState), 'diagnostic-taildrop-service-status')
      this.StandardActionButton($r('app.string.diagnostic_refresh_feature_services_action'),
        'diagnostic-feature-services-refresh', false, !this.diagnosticFeatureRefreshInProgress,
        () => this.refreshFeatureDiagnostics(), this.diagnosticFeatureRefreshInProgress)
      if (this.diagnosticFeatureRefreshStatus.length > 0) {
        this.DiagnosticStatus($r('app.string.diagnostic_feature_refresh_status_title'),
          this.diagnosticFeatureRefreshStatus, 'diagnostic-feature-refresh-status')
      }
    }
    .width('100%')
  }

  @Builder
  private DiagnosticsSecurityPanel() {
    Column({ space: 8 }) {
      this.DiagnosticSectionHeader($r('app.string.diagnostic_security_title'),
        $r('app.string.diagnostic_security_description'))
      this.DiagnosticStatus($r('app.string.diagnostic_app_lock_status_title'),
        this.securityDiagnosticStatus(), 'diagnostic-app-lock-status')
      this.DiagnosticStatus($r('app.string.diagnostic_folder_lock_status_title'),
        this.folderSecurityDiagnosticStatus(), 'diagnostic-folder-lock-status')
      this.StandardActionButton($r('app.string.diagnostic_security_self_test_action'),
        'diagnostic-security-self-test', false, !this.diagnosticSecuritySelfTestInProgress &&
          !this.securitySettingsAuthenticating && !this.appLockAuthenticating,
        () => this.runDiagnosticSecuritySelfTest(), this.diagnosticSecuritySelfTestInProgress)
      if (this.diagnosticSecuritySelfTestStatus.length > 0) {
        this.DiagnosticStatus($r('app.string.diagnostic_security_self_test_status_title'),
          this.diagnosticSecuritySelfTestStatus, 'diagnostic-security-self-test-status')
      }
    }
    .width('100%')
  }

  @Builder
  private DiagnosticsAppearancePanel() {
    Column({ space: 8 }) {
      this.DiagnosticSectionHeader($r('app.string.diagnostic_appearance_title'),
        $r('app.string.diagnostic_appearance_description'))
      this.DiagnosticStatus($r('app.string.diagnostic_appearance_background_status_title'),
        this.appearanceBackgroundDiagnosticStatus(), 'diagnostic-appearance-background-status')
      this.DiagnosticStatus($r('app.string.diagnostic_appearance_layout_status_title'),
        this.appearanceLayoutDiagnosticStatus(), 'diagnostic-appearance-layout-status')
    }
    .width('100%')
  }

  @Builder
  private DiagnosticsDeviceListVerificationPanel() {
    Column({ space: 8 }) {
      this.DiagnosticSectionHeader($r('app.string.diagnostic_device_list_verification_title'),
        $r('app.string.diagnostic_device_list_verification_description'))
      this.DiagnosticOptionRow($r('app.string.diagnostic_device_list_fixture_title'),
        $r('app.string.diagnostic_device_list_fixture_description'),
        this.diagnosticDeviceListVerificationEnabled, 'diagnostic-device-list-fixture',
        (enabled: boolean) => this.setDiagnosticDeviceListVerificationEnabled(enabled))
      if (this.diagnosticDeviceListVerificationEnabled) {
        this.StandardActionButton($r('app.string.diagnostic_device_list_open_action'),
          'diagnostic-device-list-open', false, true,
          () => this.openDiagnosticDeviceListVerification())
        this.DiagnosticStatus($r('app.string.diagnostic_device_list_last_clicked_title'),
          this.diagnosticDeviceListLastClicked.length > 0 ? this.diagnosticDeviceListLastClicked : '-',
          'diagnostic-device-list-last-clicked')
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


  private async pathDiagnosticAction(action: string): Promise<void> {
    if (this.pathDiagnosticBusy || !this.canUseStandaloneDiagnostics()) return;
    const generation: number = this.pathDiagnosticRequestGuard.begin();
    this.pathDiagnosticBusy = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const result: string = await PathDiagnosticService.request(context.filesDir, action);
      if (this.pathDiagnosticRequestGuard.isCurrent(generation) && this.canUseStandaloneDiagnostics()) {
        this.pathDiagnosticStatus = action + ': ' + result;
      }
    } catch (_error) {
      if (this.pathDiagnosticRequestGuard.isCurrent(generation) && this.canUseStandaloneDiagnostics()) {
        this.pathDiagnosticStatus = action + ': unavailable';
      }
    } finally {
      if (this.pathDiagnosticRequestGuard.isCurrent(generation)) this.pathDiagnosticBusy = false;
    }
  }

  private canUseStandaloneDiagnostics(): boolean {
    return this.appShellReady && this.remoteStreamAppInForeground && this.securityPreferencesReady &&
      !this.appLockRequired && !this.appLockAuthenticating && !this.securitySettingsAuthenticating;
  }

  private openStandaloneDiagnostics(): void {
    if (!this.canUseStandaloneDiagnostics()) return;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.crashCaptureEnabled = CrashDiagnosticService.isEnabled(context.filesDir);
      this.standaloneDiagnosticsVisible = true;
    } catch (_error) { this.showToast($r('app.string.diagnostic_report_failed')); }
  }

  private closeStandaloneDiagnostics(): void {
    this.standaloneDiagnosticsVisible = false;
    this.pathDiagnosticRequestGuard.invalidate();
    this.diagnosticReportRequestGuard.invalidate();
    this.feedbackEmailStatus = '';
    this.pathDiagnosticBusy = false;
    this.diagnosticReportInProgress = false;
  }

  private setStandaloneCrashCapture(enabled: boolean): void {
    if (!this.canUseStandaloneDiagnostics()) return;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (enabled) {
        this.crashCaptureEnabled = CrashDiagnosticService.enable(context.filesDir);
        if (!this.crashCaptureEnabled) this.showToast($r('app.string.diagnostic_report_failed'));
      } else {
        // Revoking capture also cancels sharing a report already being compressed.
        this.diagnosticReportRequestGuard.invalidate();
        this.feedbackEmailStatus = '';
        this.diagnosticReportInProgress = false;
        if (!CrashDiagnosticService.disable(context.filesDir)) {
          this.showToast($r('app.string.standalone_diagnostics_clear_failed'));
        }
        this.crashCaptureEnabled = false;
      }
    } catch (_error) { this.showToast($r('app.string.diagnostic_report_failed')); }
  }

  @Builder
  private StandaloneDiagnosticsContent() {
    Stack() {
      Scroll() {
        Column({ space: 12 }) {
          Text($r('app.string.standalone_diagnostics_description')).fontSize(14)
            .fontColor($r('sys.color.font_secondary')).width('100%')
          Text(this.crashCaptureEnabled ? $r('app.string.standalone_diagnostics_enabled') :
            $r('app.string.standalone_diagnostics_disabled')).fontSize(14).width('100%')
          this.StandardActionButton($r('app.string.standalone_diagnostics_enable'), 'standalone-crash-enable',
            false, this.canUseStandaloneDiagnostics() && !this.crashCaptureEnabled,
            () => this.setStandaloneCrashCapture(true))
          this.StandardActionButton($r('app.string.standalone_diagnostics_clear'), 'standalone-crash-clear',
            false, this.canUseStandaloneDiagnostics(), () => this.setStandaloneCrashCapture(false))
          this.StandardActionButton($r('app.string.diagnostic_report_action'), 'standalone-diagnostic-export',
            true, this.canUseStandaloneDiagnostics() && !this.diagnosticReportInProgress,
            () => this.generateDiagnosticReport(), this.diagnosticReportInProgress)
          this.StandardActionButton($r('app.string.feedback_email_with_diagnostics'), 'standalone-feedback-email',
            false, this.canUseStandaloneDiagnostics() && !this.diagnosticReportInProgress,
            () => this.openFeedbackEmail())
          this.FeedbackEmailStatus()
          if (this.diagnosticReportStatus.length > 0) {
            Text(this.diagnosticReportStatus).fontSize(12).width('100%')
          }
          this.PathDiagnosticPanel()
        }.width('100%').padding(20)
      }.width('100%').height('100%')
      if (this.isSecurityCoverActive()) { this.SecurityCoverOverlay() }
    }.width('100%').height('100%')
  }

  @Builder
  private PathDiagnosticPanel() {
    Column({ space: 8 }) {
      this.DiagnosticSectionHeader($r('app.string.path_diag_title'), $r('app.string.path_diag_description'))
      this.StandardActionButton($r('app.string.path_diag_start'), 'path-diag-start', false,
        this.isConnected() && !this.pathDiagnosticBusy, () => this.pathDiagnosticAction('start'))
      this.StandardActionButton($r('app.string.path_diag_probe'), 'path-diag-probe', false,
        this.isConnected() && !this.pathDiagnosticBusy, () => this.pathDiagnosticAction('probe'))
      this.StandardActionButton($r('app.string.path_diag_stop'), 'path-diag-stop', false,
        this.isConnected() && !this.pathDiagnosticBusy, () => this.pathDiagnosticAction('stop'))
      this.StandardActionButton($r('app.string.path_diag_clear'), 'path-diag-clear', false,
        this.isConnected() && !this.pathDiagnosticBusy, () => this.pathDiagnosticAction('clear'))
      if (this.pathDiagnosticStatus.length > 0) {
        this.DiagnosticStatus($r('app.string.path_diag_title'), this.pathDiagnosticStatus, 'path-diag-status')
      }
    }.width('100%')
  }

  @Builder
  private DiagnosticsActionsPanel() {
    Column({ space: 12 }) {
      this.PathDiagnosticPanel()
      Divider().color($r('sys.color.comp_divider'))
      this.DiagnosticsProbePanel()
      Divider().color($r('sys.color.comp_divider'))
      this.DiagnosticsFeatureOptionsPanel()
      if (this.diagnosticQuickTransferEnabled) {
        Divider().color($r('sys.color.comp_divider'))
        this.DiagnosticsMediaPanel()
      }
      if (this.diagnosticServiceMonitoringEnabled) {
        Divider().color($r('sys.color.comp_divider'))
        this.DiagnosticsServiceMonitoringPanel()
      }
      if (this.diagnosticSecurityEnabled) {
        Divider().color($r('sys.color.comp_divider'))
        this.DiagnosticsSecurityPanel()
      }
      if (this.diagnosticAppearanceEnabled) {
        Divider().color($r('sys.color.comp_divider'))
        this.DiagnosticsAppearancePanel()
      }
      Divider().color($r('sys.color.comp_divider'))
      this.DiagnosticsDeviceListVerificationPanel()
      Divider().color($r('sys.color.comp_divider'))
      this.DiagnosticsDangerousPanel()
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
            .fontSize(UiTokens.ICON_CHEVRON)
            .fontColor([$r('sys.color.icon_secondary')])
            .rotate({ angle: this.diagnosticsExpanded ? 180 : 0 })
            .animation({ duration: MotionTokens.NORMAL, curve: MotionTokens.curve() })
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
            TransitionEffect.OPACITY.animation({ duration: MotionTokens.EXPAND, curve: MotionTokens.curve() })
              .combine(TransitionEffect.translate({ y: MotionTokens.amplitude(-8) })),
            TransitionEffect.OPACITY.animation({ duration: MotionTokens.FAST, curve: MotionTokens.curve() })
              .combine(TransitionEffect.translate({ y: MotionTokens.amplitude(-6) }))
          )
        )
      }
    }
    .width('100%')
    .padding({ left: 10, right: 10 })
    .backgroundColor(this.groupBackground())
    .borderRadius(UiTokens.CARD_RADIUS)
    .margin({ top: 10 })
  }

  @Builder
  private HomeContent() {
    Scroll(this.homeScroller) {
      Column({ space: UiTokens.GROUP_GAP }) {
        Column({ space: 0 }) {
          this.HomeConnectionHeader()
          if (this.connectedHomeLayoutActive()) {
            Button({ type: ButtonType.Normal, stateEffect: true }) {
              Row({ space: 5 }) {
                Text($r('app.string.home_connection_optimization'))
                  .fontSize(11)
                  .fontColor($r('sys.color.font_secondary'))
                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(10)
                  .fontColor([$r('sys.color.icon_secondary')])
              }
              .width('100%')
              .padding({ left: 12, right: 12 })
            }
            .id('home-connection-optimization')
            .width('100%')
            .constraintSize({ minHeight: 24 })
            .borderRadius(8)
            .padding(0)
            .backgroundColor(Color.Transparent)
            .onClick(() => this.revealBackgroundRunningSetting())
          }
        }
        .width('100%')
        if ((this.isBackendLoading() || this.devicesLoading) && this.peers.length === 0 &&
          !this.diagnosticDeviceListVerificationEnabled) {
          Column() {
            this.DevicesLoadingPanel()
          }
          .width('100%')
          .transition(
            TransitionEffect.OPACITY.animation({ duration: MotionTokens.NORMAL, curve: MotionTokens.curve() })
              .combine(TransitionEffect.translate({ y: MotionTokens.amplitude(12) }))
          )
        } else if (!this.isAuthenticated() && !this.diagnosticDeviceListVerificationEnabled) {
          Column() {
            this.DevicesSignedOutPanel()
          }
          .width('100%')
          .transition(
            TransitionEffect.OPACITY.animation({ duration: MotionTokens.NORMAL, curve: MotionTokens.curve() })
              .combine(TransitionEffect.translate({ y: MotionTokens.amplitude(12) }))
          )
        } else {
          Column() {
            this.DevicesPanel()
          }
          .width('100%')
          .transition(
            TransitionEffect.OPACITY.animation({ duration: MotionTokens.NORMAL, curve: MotionTokens.curve() })
              .combine(TransitionEffect.translate({ y: MotionTokens.amplitude(12) }))
          )
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: ResponsiveLayout.EXPANDED_CONTENT_MAX_WIDTH })
      .padding({
        left: this.contentMargin(),
        right: this.contentMargin(),
        top: 8,
        bottom: this.pageBottomInset()
      })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageCanvasBackground())
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Auto)
    .scrollBarWidth(4)
    .align(Alignment.TopStart)
  }

  @Builder
  private TransferProtocolBadge(protocol: string, state: string,
    onOfflineAction: () => void = () => {}) {
    Stack({ alignContent: Alignment.Start }) {
      ForEach([state], (displayState: string) => {
        Text(displayState === 'online' ? $r('app.string.transfer_protocol_online', protocol) :
          (displayState === 'checking' ? $r('app.string.transfer_protocol_checking', protocol) :
            $r('app.string.transfer_protocol_offline', protocol)))
          .fontSize(UiTokens.BADGE_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(displayState === 'online' ? $r('app.color.status_success') :
            (displayState === 'checking' ? $r('app.color.status_warning') :
              $r('sys.color.font_secondary')))
          .padding({ left: UiTokens.BADGE_PADDING_HORIZONTAL, right: UiTokens.BADGE_PADDING_HORIZONTAL,
            top: UiTokens.BADGE_PADDING_VERTICAL, bottom: UiTokens.BADGE_PADDING_VERTICAL })
          .backgroundColor(displayState === 'online' ? $r('app.color.badge_background_available') :
            (displayState === 'checking' ? $r('app.color.badge_background_warning') :
              $r('app.color.badge_background_pending')))
          .borderRadius(UiTokens.BADGE_RADIUS)
          .maxLines(1)
          .transition(
            TransitionEffect.asymmetric(
              TransitionEffect.OPACITY.animation({
                duration: MotionTokens.duration(STATUS_CROSS_FADE_MS), curve: MotionTokens.curve()
              })
                .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 })),
              TransitionEffect.OPACITY.animation({
                duration: MotionTokens.duration(STATUS_CROSS_FADE_MS), curve: MotionTokens.curve()
              })
                .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }))
            )
          )
          .onClick(() => {
            if (displayState === 'offline') {
              onOfflineAction();
            }
          })
      }, (displayState: string) => `${protocol}-${displayState}`)
    }
    .width(protocol === 'Taildrop' ? 78 : 88)
    .height(24)
    .align(Alignment.Start)
  }

  private taildropProtocolState(target: TaildropTargetSummary | undefined): string {
    if (!this.isConnected() || target === undefined || !target.online) {
      return 'offline';
    }
    if (this.taildropState === 'ready') {
      return 'online';
    }
    return this.taildropState === 'loading' ? 'checking' : 'offline';
  }

  private taildropTargetReady(target: TaildropTargetSummary): boolean {
    return this.taildropProtocolState(target) === 'online';
  }

  private localSendProtocolState(peer: PeerSummary | undefined): string {
    const current: PeerSummary | undefined = peer === undefined ? undefined :
      (this.peerForFileTransferKey(peer.key) ?? peer);
    if (!this.isConnected() || current === undefined || !this.peerEffectivelyOnline(current)) {
      return 'offline';
    }
    if (this.transferProtocolRefreshing || current.localSend?.state === 'checking') {
      return 'checking';
    }
    if (current.localSend?.state === 'available') {
      return 'online';
    }
    return 'offline';
  }

  private localSendAvailableForTarget(target: TaildropTargetSummary): boolean {
    const peer: PeerSummary | undefined = this.peerForFileTransferKey(target.key);
    return peer !== undefined && this.localSendAvailableForPeer(peer);
  }

  private transferTargetDeviceOffline(target: TaildropTargetSummary): boolean {
    const peer: PeerSummary | undefined = this.peerForFileTransferKey(target.key);
    return !this.isConnected() || (!this.taildropTargetReady(target) && !target.online &&
      (peer === undefined || !this.peerEffectivelyOnline(peer)));
  }

  @Builder
  private TransferDeviceOfflineBadge() {
    Text($r('app.string.device_detail_device_offline'))
      .fontSize(UiTokens.BADGE_SIZE)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.font_secondary'))
      .padding({ left: UiTokens.BADGE_PADDING_HORIZONTAL, right: UiTokens.BADGE_PADDING_HORIZONTAL,
        top: UiTokens.BADGE_PADDING_VERTICAL, bottom: UiTokens.BADGE_PADDING_VERTICAL })
      .backgroundColor($r('app.color.badge_background_pending'))
      .borderRadius(UiTokens.BADGE_RADIUS)
      .maxLines(1)
  }

  @Builder
  private TransferTargetFocusOverlay(peerKey: string) {
    if (this.taildropFocusedTargetKey === peerKey) {
      Row()
        .width('100%')
        .height('100%')
        .borderRadius(UiTokens.CARD_RADIUS)
        .backgroundColor($r('app.color.surface_subtle'))
        .shadow({ radius: 14, color: $r('app.color.shadow_elevated_soft'), offsetY: 4 })
        .hitTestBehavior(HitTestMode.None)
        .transition(TransitionEffect.OPACITY.animation({
          duration: MotionTokens.duration(180), curve: MotionTokens.curve()
        }))
    }
  }

  private taildropFileChoicesVisible(target: TaildropTargetSummary,
    peer: PeerSummary | undefined): boolean {
    if (!this.taildropTargetReady(target)) {
      return false;
    }
    if (peer === undefined) {
      return true;
    }
    return this.localSendProtocolState(peer) === 'offline';
  }

  @Builder
  private TaildropTargetRow(target: TaildropTargetSummary) {
    Column({ space: 0 }) {
      Row({ space: 12 }) {
        Stack({ alignContent: Alignment.Center }) {
          Image(this.peerDeviceIcon(target.deviceType ?? ''))
            .width(22)
            .height(22)
            .fillColor((this.taildropTargetReady(target) || this.localSendAvailableForTarget(target)) ?
              $r('sys.color.icon_primary') : $r('sys.color.icon_secondary'))
        }
        .width(38)
        .height(38)
        .borderRadius(12)
        .backgroundColor(this.secondaryBackground())

        Column({ space: 2 }) {
          Text(this.peerDisplayName(target.name))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Row({ space: 10 }) {
            if (this.transferTargetDeviceOffline(target)) {
              this.TransferDeviceOfflineBadge()
            } else {
              this.TransferProtocolBadge('Taildrop', this.taildropProtocolState(target))
              this.TransferProtocolBadge('LocalSend',
                this.localSendProtocolState(this.peerForFileTransferKey(target.key)),
                () => {
                  const peer: PeerSummary | undefined = this.peerForFileTransferKey(target.key);
                  if (peer !== undefined) {
                    this.openRemotePortEditor(peer);
                  }
                })
            }
          }
            .width('100%')
            .margin({ top: 5, bottom: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

      }
      .width('100%')
      .constraintSize({ minHeight: 54 })
      .padding({ left: 12, right: 12, top: 7, bottom: 4 })
      if (this.taildropTargetReady(target) || this.localSendAvailableForTarget(target)) {
        Row() {
          if (this.taildropFileChoicesVisible(target, this.peerForFileTransferKey(target.key))) {
            this.TaildropFileMediaCapsule(target, this.peerForFileTransferKey(target.key))
          } else {
            this.TaildropSendFileCapsule(target, this.peerForFileTransferKey(target.key))
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 4, bottom: 12 })
      }
      if (this.taildropTextEditorVisible && this.taildropTextEditorMatches(target)) {
        this.TaildropTextEditorSheet()
      }
      if (this.remotePortEditorVisible && this.remotePortPeerKey === target.key) {
        Column() {
          this.RemotePortEditorPanel()
        }
        .width('100%')
        .padding({ left: 12, right: 12, bottom: 12 })
      }
    }
    .id('taildrop-target-' + target.key)
    .width('100%')
    .overlay(this.TransferTargetFocusOverlay(target.key), { align: Alignment.Center })
    .backgroundColor(Color.Transparent)
    .borderRadius(UiTokens.CARD_RADIUS)
    .opacity((this.taildropTargetReady(target) || this.localSendAvailableForTarget(target)) ? 1 : 0.52)
    .animation({ duration: MotionTokens.EXPAND, curve: MotionTokens.curve() })
  }

  @Builder
  private TaildropFileMediaCapsule(target: TaildropTargetSummary, peer: PeerSummary | undefined) {
    Row({ space: 0 }) {
      this.PeerActionSegment($r('app.string.transfer_file_action'),
        'taildrop-file-' + target.key,
        this.taildropTargetReady(target) && this.taildropContentChoiceEnabled(), false,
        () => this.chooseTaildropDocuments(target))
      Divider()
        .vertical(true)
        .height(18)
        .color($r('sys.color.comp_divider'))
      this.PeerActionSegment($r('app.string.transfer_photo_action'),
        'taildrop-media-' + target.key,
        this.taildropTargetReady(target) && this.taildropContentChoiceEnabled(), false,
        () => this.chooseTaildropPhotos(target))
      Divider()
        .vertical(true)
        .height(18)
        .color($r('sys.color.comp_divider'))
      this.PeerActionSegment($r('app.string.transfer_text_action'),
        'taildrop-text-' + target.key,
        this.taildropTargetReady(target) && this.taildropContentChoiceEnabled(), false,
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
  private TaildropSendFileCapsule(target: TaildropTargetSummary, peer: PeerSummary | undefined) {
    Row({ space: 0 }) {
      this.PeerActionSegment($r('app.string.transfer_send_file_action'),
        'taildrop-send-file-' + target.key,
        (this.taildropTargetReady(target) || (peer !== undefined && this.localSendAvailableForPeer(peer))) &&
          this.taildropContentChoiceEnabled(), false,
        () => {
          if (peer === undefined) {
            this.chooseTaildropDocuments(target);
          } else {
            this.startFileTransferForPeer(peer);
          }
        })
    }
    .width('100%')
    .height(36)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.secondaryBackground())
    .borderRadius(18)
    .clip(true)
  }

  @Builder
  private LocalSendOnlyTargetRow(peer: PeerSummary) {
    Column({ space: 0 }) {
      Row({ space: 12 }) {
        Stack({ alignContent: Alignment.Center }) {
          Image(this.peerDeviceIcon(peer.deviceType))
            .width(22)
            .height(22)
            .fillColor(this.localSendAvailableForPeer(peer) ?
              $r('sys.color.icon_primary') : $r('sys.color.icon_secondary'))
        }
        .width(38)
        .height(38)
        .borderRadius(12)
        .backgroundColor(this.secondaryBackground())

        Column({ space: 2 }) {
          Text(this.peerDisplayName(peer.name))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Row({ space: 10 }) {
            if (!this.isConnected() || !this.peerEffectivelyOnline(peer)) {
              this.TransferDeviceOfflineBadge()
            } else {
              this.TransferProtocolBadge('Taildrop', 'offline')
              this.TransferProtocolBadge('LocalSend', this.localSendProtocolState(peer),
                () => this.openRemotePortEditor(peer))
            }
          }
            .width('100%')
            .margin({ top: 5, bottom: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .constraintSize({ minHeight: 54 })
      .padding({ left: 12, right: 12, top: 7, bottom: 4 })

      if (this.localSendAvailableForPeer(peer)) {
        Row() {
          Row({ space: 0 }) {
            this.PeerActionSegment($r('app.string.transfer_send_file_action'),
              'file-transfer-send-file-' + peer.key,
              this.localSendAvailableForPeer(peer) && this.taildropContentChoiceEnabled(), false,
              () => this.startFileTransferForPeer(peer))
          }
          .width('100%')
          .height(36)
          .alignItems(VerticalAlign.Center)
          .backgroundColor(this.secondaryBackground())
          .borderRadius(18)
          .clip(true)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 4, bottom: 12 })
      }
      if (this.remotePortEditorVisible && this.remotePortPeerKey === peer.key) {
        Column() {
          this.RemotePortEditorPanel()
        }
        .width('100%')
        .padding({ left: 12, right: 12, bottom: 12 })
      }
    }
    .id('file-transfer-target-' + peer.key)
    .width('100%')
    .overlay(this.TransferTargetFocusOverlay(peer.key), { align: Alignment.Center })
    .backgroundColor(Color.Transparent)
    .borderRadius(UiTokens.CARD_RADIUS)
    .opacity(this.localSendAvailableForPeer(peer) ? 1 : 0.52)
    .animation({ duration: MotionTokens.EXPAND, curve: MotionTokens.curve() })
  }

  @Builder
  private RemotePortEditorPanel() {
    Column({ space: 8 }) {
      Text($r('app.string.transfer_remote_port_title'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
      Text($r('app.string.transfer_remote_port_message', this.remotePortEditorPeerName()))
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
        .lineHeight(18)
        .width('100%')
      Row({ space: 8 }) {
        TextInput({
          text: this.remotePortInput,
          placeholder: $r('app.string.transfer_remote_port_placeholder')
        })
          .id('transfer-remote-port-input')
          .layoutWeight(1)
          .height(42)
          .padding({ left: 12, right: 12 })
          .fontSize(15)
          .fontColor($r('sys.color.font_primary'))
          .placeholderColor($r('sys.color.font_secondary'))
          .backgroundColor(this.glowSurface())
          .border({ width: 1, color: $r('sys.color.comp_divider') })
          .borderRadius(12)
          .selectionMenuHidden(false)
          .onChange((value: string) => {
            this.remotePortInput = value.replace(/[^0-9]/g, '');
          })
        Button($r('app.string.cancel_action'), {
          type: ButtonType.ROUNDED_RECTANGLE,
          stateEffect: true,
          buttonStyle: ButtonStyleMode.NORMAL,
          controlSize: ControlSize.SMALL
        })
          .height(42)
          .padding({ left: 10, right: 10 })
          .backgroundColor(this.secondaryBackground())
          .fontColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.remotePortEditorVisible = false;
          })
        Button($r('app.string.transfer_remote_port_save'), {
          type: ButtonType.ROUNDED_RECTANGLE,
          stateEffect: true,
          buttonStyle: ButtonStyleMode.NORMAL,
          controlSize: ControlSize.SMALL
        })
          .height(42)
          .padding({ left: 10, right: 10 })
          .backgroundColor($r('app.color.emphasize'))
          .fontColor($r('sys.color.font_primary'))
          .onClick(() => this.saveRemotePortOverride())
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  private RemoteCachedPeerRow(peer: PeerSummary) {
    Column({ space: 6 }) {
      Row({ space: 12 }) {
        Stack({ alignContent: Alignment.Center }) {
          Image(this.peerDeviceIcon(peer.deviceType))
            .width(22)
            .height(22)
            .fillColor(!this.remoteCachedPeerIsOffline(peer) ? $r('sys.color.icon_primary') :
              $r('sys.color.icon_secondary'))
        }
        .width(38)
        .height(38)
        .borderRadius(12)
        .backgroundColor(this.secondaryBackground())

        Column({ space: 2 }) {
          Row({ space: 6 }) {
            Text(this.peerDisplayName(peer.name))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')
          if (this.remoteCachedPeerIsOffline(peer)) {
            Row({ space: 8 }) {
              Text(this.remoteCachedPeerDescription(peer))
                .fontSize(12)
                .fontColor($r('app.color.status_offline'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              this.TransferDeviceOfflineBadge()
            }
              .width('100%')
          } else {
            Text(this.remoteCachedPeerDescription(peer))
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Row({ space: 10 }) {
              this.TransferProtocolBadge('Taildrop', 'offline')
              this.TransferProtocolBadge('LocalSend', this.localSendProtocolState(peer),
                () => this.openRemotePortEditor(peer))
            }
              .width('100%')
              .margin({ top: 4, bottom: 0 })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

      }
      .width('100%')

      if (this.isConnected() && this.peerEffectivelyOnline(peer)) {
        this.RemoteCachedSendFileCapsule(peer)
      }

      if (this.remotePortEditorVisible && this.remotePortPeerKey === peer.key) {
        Column() {
          this.RemotePortEditorPanel()
        }
        .width('100%')
        .padding({ left: 46, right: 0 })
      }
    }
    .id('remote-device-' + peer.key)
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .overlay(this.TransferTargetFocusOverlay(peer.key), { align: Alignment.Center })
    .backgroundColor(Color.Transparent)
    .borderRadius(12)
  }

  @Builder
  private RemoteCachedDevicesSection() {
    Column({ space: 0 }) {
      ForEach(this.remoteCachedPeers(), (peer: PeerSummary, index: number) => {
        if (index > 0) {
          Divider()
            .color($r('sys.color.comp_divider'))
        }
        this.RemoteCachedPeerRow(peer)
      }, (peer: PeerSummary) => peer.key)
    }
    .id('remote-devices-panel')
    .width('100%')
    .padding({ top: 2, bottom: 2 })
    .backgroundColor(this.groupBackground())
    .borderRadius(UiTokens.CARD_RADIUS)
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
      }, (target: TaildropTargetSummary) => this.transferTargetRenderKey(target))
      ForEach(this.peersWithoutTaildropTarget(), (peer: PeerSummary, index: number) => {
        if (this.displayedTaildropTargets().length > 0 || index > 0) {
          Divider()
            .color($r('sys.color.comp_divider'))
        }
        this.LocalSendOnlyTargetRow(peer)
      }, (peer: PeerSummary) => this.localSendOnlyTargetRenderKey(peer))
    }
    .id('taildrop-targets-panel')
    .width('100%')
    .padding({ top: 4, bottom: 4 })
    .backgroundColor(this.groupBackground())
    .borderRadius(UiTokens.CARD_RADIUS)
  }

  @Builder
  private TaildropTargetsEmptyPanel() {
    Column({ space: 6 }) {
      if (this.transferSetupNotice() === 'loading') {
        LoadingProgress().width(24).height(24)
        Text($r('app.string.transfer_protocol_refreshing')).fontSize(UiTokens.BODY_SIZE)
          .fontColor($r('sys.color.font_secondary'))
      } else {
        Text(!this.isConnected() ? $r('app.string.transfer_connect_first_description') :
          this.transferSetupNotice() === 'disabled' ? $r('app.string.feature_guide_taildrop_disabled') :
            this.transferSetupNotice() === 'error' ? $r('app.string.feature_guide_transfer_error') :
              $r('app.string.transfer_no_targets_description'))
          .fontSize(UiTokens.BODY_SIZE).fontColor($r('sys.color.font_secondary')).lineHeight(20)
          .textAlign(TextAlign.Center).width('100%')
        if (this.transferSetupNotice() === 'connect') {
          Button(this.needsLogin() ? $r('app.string.action_login') : $r('app.string.action_connect'))
            .fontSize(14).id('transfer-connect-action')
            .enabled(this.connectionActionEnabled())
            .onClick(() => this.runConnectionAction())
          this.ContextGuideAction($r('app.string.feature_guide_connect_help'), 'connect', 'transfer-connect-help')
        } else if (this.transferSetupNotice() === 'disabled') {
          this.ContextGuideAction($r('app.string.feature_guide_enable_taildrop'), 'taildrop', 'transfer-enable-taildrop')
        } else if (this.transferSetupNotice() === 'targets') {
          this.ContextGuideAction($r('app.string.feature_guide_target_requirements'), 'taildrop', 'transfer-target-help')
        }
      }
    }
      .width('100%').padding(UiTokens.CARD_PADDING).backgroundColor(this.groupBackground()).borderRadius(UiTokens.CARD_RADIUS)
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
              .color($r('app.color.emphasize'))
          } else {
            this.TaildropFileIcon(this.taildropTransfer.fileName, 32)
          }
        }
        .width(44)
        .height(44)
        .borderRadius(12)
        .backgroundColor(this.secondaryBackground())
        Column({ space: 2 }) {
          Text(this.taildropPreparing ? $r('app.string.transfer_preparing') :
            $r('app.string.transfer_sending_to', this.sanitizeTaildropDisplayText(this.taildropTransfer.targetName)))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .width('100%')
          if (this.taildropTransfer.fileName.length > 0) {
            Text(this.sanitizeTaildropDisplayText(this.taildropTransfer.fileName))
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
              .enabled(!this.taildropCancelPending)
            .opacity(this.taildropCancelPending ? 0.6 : 1)
            .onClick(() => this.cancelTaildropSend())
        }
      }
      .width('100%')
      Progress({ value: this.taildropTransferProgress(), total: 100, type: ProgressType.Linear })
        .width('100%')
        .height(5)
        .color($r('app.color.emphasize'))
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
        TransitionEffect.OPACITY.animation({ duration: MotionTokens.NORMAL, curve: MotionTokens.curve() })
          .combine(TransitionEffect.translate({ y: MotionTokens.amplitude(-10) })),
        TransitionEffect.OPACITY.animation({ duration: MotionTokens.FAST, curve: MotionTokens.curve() })
          .combine(TransitionEffect.translate({ y: MotionTokens.amplitude(-6) }))
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
          this.TaildropFileIcon(file.name, 40)
        }
      }
      .width(44)
      .height(44)
      Column({ space: 2 }) {
        Text(this.sanitizeTaildropDisplayText(file.name))
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
          .color($r('app.color.emphasize'))
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
                  void this.showCachedTaildropTextPreview(cachedText).then((shown: boolean) => {
                    if (shown) {
                      this.copyTaildropTextPreview();
                    }
                  });
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
      }, (file: TaildropWaitingFileSummary) => `${file.name}\n${file.size}\n${file.receivedAtMs}`)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
    .backgroundColor(this.groupBackground())
    .borderRadius(UiTokens.CARD_RADIUS)
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
        this.TaildropFileIcon(record.fileName, 40)
      }
    }
    .width(44)
    .height(44)
    .backgroundColor(this.secondaryBackground())
    .borderRadius(12)
  }

  private collapseTaildropTextPreview(): void {
    this.taildropSessionController.collapseTaildropTextPreview();
  }

  private copyTaildropTextPreview(): void {
    this.taildropSessionController.copyTaildropTextPreview();
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
            .fontColor($r('app.color.emphasize'))
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
    .borderRadius(UiTokens.CARD_RADIUS)
  }

  @Builder
  private TransferEmptyPanel() {
    Text($r('app.string.transfer_empty_title'))
      .fontSize(UiTokens.BODY_SIZE)
      .fontColor($r('sys.color.font_secondary'))
      .textAlign(TextAlign.Center)
    .width('100%')
    .padding(UiTokens.CARD_PADDING)
    .backgroundColor(this.groupBackground())
    .borderRadius(UiTokens.CARD_RADIUS)
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
        TransitionEffect.OPACITY.animation({ duration: MotionTokens.NORMAL, curve: MotionTokens.curve() })
          .combine(TransitionEffect.translate({ y: MotionTokens.amplitude(-6) })),
        TransitionEffect.OPACITY.animation({ duration: MotionTokens.FAST, curve: MotionTokens.curve() })
          .combine(TransitionEffect.translate({ y: MotionTokens.amplitude(-4) }))
      )
    )
  }

  @Builder
  private TaildropConnectionNotice() {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.Center }) {
        Image($r('app.media.ic_light_connect'))
          .width(24)
          .height(24)
          .objectFit(ImageFit.Contain)
      }
      .width(32)
      .height(32)
      .borderRadius(10)
      .backgroundColor(this.secondaryBackground())

      Column({ space: 2 }) {
        Text(this.remoteCachedPeers().length > 0 ?
          $r('app.string.transfer_remote_cached_title') : $r('app.string.transfer_connect_first_title'))
          .fontSize(UiTokens.BODY_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
        Text(this.remoteCachedPeers().length > 0 ?
          $r('app.string.transfer_remote_cached_description') :
          $r('app.string.transfer_connect_first_description'))
          .fontSize(UiTokens.CAPTION_SIZE)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(UiTokens.CARD_PADDING)
    .backgroundColor(this.groupBackground())
    .border({
      width: 1,
      color: $r('sys.color.comp_divider')
    })
    .borderRadius(UiTokens.CARD_RADIUS)
    .transition(
      TransitionEffect.asymmetric(
        TransitionEffect.OPACITY.animation({ duration: MotionTokens.NORMAL, curve: MotionTokens.curve() })
          .combine(TransitionEffect.translate({ y: MotionTokens.amplitude(-8) })),
        TransitionEffect.OPACITY.animation({ duration: MotionTokens.FAST, curve: MotionTokens.curve() })
          .combine(TransitionEffect.translate({ y: MotionTokens.amplitude(-6) }))
      )
    )
  }

  @Builder
  private TransferOverviewPanel() {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Image($r('app.media.ic_light_connect'))
          .width(26)
          .height(26)
          .objectFit(ImageFit.Contain)
      }
      .width(34)
      .height(34)
      .borderRadius(10)
      .backgroundColor(this.secondaryBackground())

      Column({ space: 3 }) {
        Text($r('app.string.transfer_send_files_title'))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 2, bottom: 2 })
  }

  @Builder
  private RemoteCachedSendFileCapsule(peer: PeerSummary) {
    Row({ space: 0 }) {
      this.PeerActionSegment($r('app.string.transfer_send_file_action'),
        'remote-cached-send-file-' + peer.key, false, false,
        () => this.openRemoteCachedPeer(peer))
    }
    .width('100%')
    .height(36)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.secondaryBackground())
    .borderRadius(18)
    .clip(true)
  }

  @Builder
  private TaildropTargetsSection() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text(!this.isConnected() && this.remoteCachedPeers().length > 0 ?
            $r('app.string.transfer_remote_devices_title') : $r('app.string.transfer_targets_title'))
            .fontSize(UiTokens.SECTION_TITLE_SIZE)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .width('100%')
          Text(!this.isConnected() && this.remoteCachedPeers().length > 0 ?
            $r('app.string.transfer_remote_devices_description') :
            $r('app.string.transfer_targets_ready_title', this.fileTransferOnlineTargetCount()))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.ellipsis_circle'))
            .fontSize(UiTokens.ICON_NAV_BAR)
            .fontColor([$r('sys.color.icon_secondary')])
        }
          .width(40)
          .height(40)
          .padding(0)
          .backgroundColor(Color.Transparent)
          .id('transfer-help-menu')
          .accessibilityText($r('app.string.feature_guide_transfer_help'))
          .enabled(this.canOpenContextGuide())
          .bindMenu([{ value: $r('app.string.feature_guide_transfer_help'),
            action: () => this.openContextGuide('transfer') }], {
            systemMaterial: LightAppearance.menu(this.glowLevel)
          })
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          if (this.transferProtocolRefreshing) {
            LoadingProgress()
              .width(UiTokens.ICON_NAV_BAR)
              .height(UiTokens.ICON_NAV_BAR)
              .color($r('app.color.emphasize'))
          } else {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(UiTokens.ICON_NAV_BAR)
              .fontColor([$r('app.color.emphasize')])
          }
        }
        .id('transfer-protocol-refresh')
        .width(40)
        .height(40)
        .padding(0)
        .backgroundColor(Color.Transparent)
        .enabled(!this.transferProtocolRefreshing)
        .opacity(this.transferProtocolRefreshing ? 0.45 : 1)
        .accessibilityText($r('app.string.transfer_protocol_refresh_action'))
        .onClick(() => this.handleTransferProtocolRefreshClick())
      }
      .id('transfer-page-title')
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 4, top: 8, bottom: 2 })
      if (!this.isConnected() && this.remoteCachedPeers().length > 0) {
        this.RemoteCachedDevicesSection()
      } else if (this.displayedTaildropTargets().length > 0 || this.peersWithoutTaildropTarget().length > 0) {
        this.TaildropTargetsPanel()
        if (this.transferSetupNotice() === 'disabled') {
          Text($r('app.string.feature_guide_taildrop_disabled')).fontSize(12)
            .fontColor($r('sys.color.font_secondary')).width('100%')
          this.ContextGuideAction($r('app.string.feature_guide_enable_taildrop'), 'taildrop', 'transfer-disabled-taildrop-help')
        } else if (this.transferSetupNotice() === 'targets') {
          Text($r('app.string.feature_guide_taildrop_no_targets')).fontSize(12)
            .fontColor($r('sys.color.font_secondary')).width('100%')
          this.ContextGuideAction($r('app.string.feature_guide_target_requirements'), 'taildrop', 'transfer-localsend-target-help')
        }
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
            .fontColor($r('app.color.emphasize'))
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
            .borderRadius(UiTokens.CARD_RADIUS)
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
            .fontColor($r('app.color.emphasize'))
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
  private SystemSharePanel() {
    Column({ space: 12 }) {
      Text($r('app.string.system_share_title', this.sharedFileCount))
        .fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
      if (this.sharedFileSummary.length > 0) {
        Text(this.sharedFileSummary)
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .id('system-share-file-names')
      }
      if (!this.isConnected()) {
        Text($r('app.string.transfer_connect_first_description'))
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
        Button(this.needsLogin() ? $r('app.string.action_login') : $r('app.string.action_connect'))
          .id('system-share-connect')
          .enabled(this.connectionActionEnabled())
          .onClick(() => this.runConnectionAction())
      } else {
        Text($r('app.string.system_share_choose_device'))
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
        ForEach(this.displayedTaildropTargets(), (target: TaildropTargetSummary) => {
          Button(this.peerDisplayName(target.name))
            .width('100%').enabled(target.online && !this.sharedFileSending)
            .onClick(() => { this.sendSharedFiles(target); })
        }, (target: TaildropTargetSummary) => this.transferTargetRenderKey(target))
      }
      Button($r('app.string.system_share_cancel'))
        .enabled(!this.sharedFileSending)
        .onClick(() => {
          const draft: SharedFileDraft | undefined = SystemShareInbox.first();
          if (draft !== undefined) { SystemShareInbox.remove(draft.id); }
        })
    }
    .id('system-share-panel')
    .width('100%').padding(16).backgroundColor(this.groupBackground()).borderRadius(UiTokens.CARD_RADIUS)
  }

  @Builder
  private TransferContent() {
    Scroll(this.transferScroller) {
      Column({ space: 10 }) {
        if (this.sharedFileCount > 0) {
          this.SystemSharePanel()
        }
        if (this.sharedFileCount === 0 && !this.isConnected() && this.remoteCachedPeers().length === 0) {
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
    .backgroundColor(this.pageCanvasBackground())
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Auto)
    .scrollBarWidth(4)
    .align(Alignment.TopStart)
  }

  @Builder
  private FilesContent() {
    Column() {
      ForEach([`${this.controlServerURL}|${this.accountProfileId}`], (_server: string) => {
      TaildriveBrowser({
        // Keep the child property directly subscribed to the observable VPN
        // status. A method call here is not tracked reliably while HdsTabs
        // keeps inactive pages alive across the VPN startup transition.
        connected: this.vpnStatus.includes('state=Running'),
        standalone: true,
        bottomInset: this.pageBottomInset(),
        contentScroller: this.filesScroller,
        onShowFeatureGuide: (section: string) => this.openContextGuide(section),
        onRequestConnection: () => this.runConnectionAction(),
        connectionActionText: this.needsLogin() ? $r('app.string.action_login') : $r('app.string.action_connect'),
        connectionActionAvailable: this.connectionActionEnabled(),
        titleBarPadding: this.contentMargin(),
        materialLevel: this.glowMaterialLevel(),
        glowLevel: this.glowLevel,
        transparentBackground: this.appBackgroundActive(),
        targetMachineName: this.taildriveTargetMachineName,
        targetTailnetName: this.accountSummary.tailnetName,
        targetRequestId: this.taildriveTargetRequestId,
        folderLockEnabled: this.folderLockEnabled,
        appLockActive: this.isSecurityCoverActive()
      })
      }, (server: string) => server)
    }
    .width('100%')
    .height('100%')
    .constraintSize({ maxWidth: ResponsiveLayout.EXPANDED_CONTENT_MAX_WIDTH })
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.pageCanvasBackground())
  }

  @Builder
  private NativeSettingsSheetContent() {
    Stack() {
      Column() {
        NativeSettingsNavigation({
          glowLevel: this.glowLevel,
          backgroundImageUri: this.nativeSettingsBackgroundUri,
          backgroundUnavailable: this.backgroundUnavailable,
          backgroundBrightnessValue: this.backgroundBrightnessValue,
          immersiveColorTint: this.immersiveColorTint(),
          onBackgroundImageError: (uri: string) => this.onBackgroundImageLoadError(uri),
          onBackgroundBrightnessChange: (value: number, mode: SliderChangeMode) =>
            this.setBackgroundBrightness(value, mode),
          backgroundPickerInProgress: this.nativeSettingsBackgroundPickerInProgress,
          backgroundClearEnabled: this.nativeSettingsBackgroundUri.length > 0,
          immersiveColorEnabled: this.immersiveColorBackgroundEnabled,
          pageName: this.nativeSettingsPage,
          initialAnimationPreset: this.animationPreset,
          initialAnimationDuration: this.animationDuration,
          initialAnimationAmplitude: this.animationAmplitude,
          initialAnimationDamping: this.animationDamping,
          onGlowLevelChange: (level: number) => this.setGlowLevel(level),
          onSelectBackground: () => {
            this.selectNativeSettingsBackground();
          },
          onClearBackground: () => {
            this.clearNativeSettingsBackground();
          },
          onImmersiveColorChange: (enabled: boolean) => {
            this.setImmersiveColorBackground(enabled);
          },
          onAnimationSettingsChange: (settings: AnimationSettings) =>
            this.updateAnimationSettings(settings),
          onDismiss: () => {
            this.nativeSettingsVisible = false;
          }
        })
      }
        .width('100%')
        .height('100%')
      if (this.isSecurityCoverActive()) {
        this.SecurityCoverOverlay()
      }
    }
      .width('100%')
      .height('100%')
  }

  @Builder
  private SettingsCategoryRow($$: SettingsCategoryRowData) {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Row({ space: 12 }) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($$.icon)
            .fontSize(UiTokens.ICON_LIST_LEADING)
            .fontColor([$r('app.color.emphasize')])
        }
        .width(UiTokens.ICON_LIST_CONTAINER)
        .height(UiTokens.ICON_LIST_CONTAINER)
        .borderRadius(UiTokens.ICON_LIST_CONTAINER_RADIUS)
        .backgroundColor(this.secondaryBackground())

        Text($$.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if ($$.summary !== '') {
          Text($$.summary)
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: this.layoutWidth >= 600 ? 220 : 112 })
        }

        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(UiTokens.ICON_CHEVRON)
          .fontColor([$r('sys.color.icon_secondary')])
      }
      .width('100%')
      .height('100%')
      .padding({ left: UiTokens.CARD_PADDING, right: UiTokens.CARD_PADDING })
    }
    .id($$.rowId)
    .width('100%')
    .height(64)
    .padding(0)
    .borderRadius(10)
    .backgroundColor($$.rowId === 'settings-background-running-entry' && this.backgroundRunningHighlighted ?
      $r('app.color.background_running_highlight') : Color.Transparent)
    .onClick($$.action)
  }

  @Builder
  private SecuritySettingsPanel() {
    Column({ space: 0 }) {
      Row() {
        Column({ space: 2 }) {
          Text($r('app.string.security_app_lock_title'))
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
          Text($r('app.string.security_app_lock_description'))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(2)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.appLockEnabled })
          .id('security-app-lock-toggle')
          .selectedColor($r('app.color.emphasize'))
          .enabled(!this.securitySettingsAuthenticating && !this.appLockAuthenticating)
          .systemMaterial(LightAppearance.control(this.glowLevel))
          .onChange((enabled: boolean) => this.setAppLockEnabled(enabled))
      }
      .width('100%')
      .constraintSize({ minHeight: 66 })
      .padding({ top: 7, bottom: 7 })

      Divider().color($r('sys.color.comp_divider'))

      Row() {
        Column({ space: 2 }) {
          Text($r('app.string.security_folder_lock_title'))
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
          Text($r('app.string.security_folder_lock_description'))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(3)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.folderLockEnabled })
          .id('security-folder-lock-toggle')
          .selectedColor($r('app.color.emphasize'))
          .enabled(!this.securitySettingsAuthenticating && !this.appLockAuthenticating)
          .systemMaterial(LightAppearance.control(this.glowLevel))
          .onChange((enabled: boolean) => this.setFolderLockEnabled(enabled))
      }
      .width('100%')
      .constraintSize({ minHeight: 76 })
      .padding({ top: 7, bottom: 7 })
    }
    .id('security-settings-panel')
    .width('100%')
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
    .backgroundColor(this.groupBackground())
    .borderRadius(UiTokens.CARD_RADIUS)
  }

  @Builder
  private SettingsContent() {
    Scroll(this.settingsScroller) {
      Column({ space: UiTokens.GROUP_GAP }) {
        Column({ space: 5 }) {
          this.SettingsGroupHeader($r('app.string.account_title'), true)
          this.AccountPanel()
        }
        .width('100%')

        Column({ space: 0 }) {
          this.SettingsCategoryRow({ icon: $r('sys.symbol.connection'),
            title: $r('app.string.settings_network_connection_title'),
            summary: this.selectedExitNodeLabel(),
            rowId: 'settings-network-entry',
            action: () => this.openSettingsDetail('network') })
          Divider().color($r('sys.color.comp_divider')).margin({ left: 66, right: 16 })
          this.SettingsCategoryRow({ icon: $r('sys.symbol.clock'),
            title: $r('app.string.background_running_title'),
            summary: $r('app.string.background_running_summary'),
            rowId: 'settings-background-running-entry',
            action: () => this.openSettingsDetail('background-running') })
          Divider().color($r('sys.color.comp_divider')).margin({ left: 66, right: 16 })
          this.SettingsCategoryRow({ icon: $r('sys.symbol.picture'),
            title: $r('app.string.settings_appearance_navigation_title'),
            summary: '',
            rowId: 'settings-appearance-entry',
            action: () => this.openSettingsDetail('appearance') })
          Divider().color($r('sys.color.comp_divider')).margin({ left: 66, right: 16 })
          this.SettingsCategoryRow({ icon: $r('sys.symbol.archivebox'),
            title: $r('app.string.settings_storage_cache_title'),
            summary: this.storageSummaryLabel(),
            rowId: 'settings-storage-entry',
            action: () => this.openSettingsDetail('storage') })
          Divider().color($r('sys.color.comp_divider')).margin({ left: 66, right: 16 })
          this.SettingsCategoryRow({ icon: $r('sys.symbol.lock'),
            title: $r('app.string.settings_security_title'),
            summary: '',
            rowId: 'settings-security-entry',
            action: () => this.openSettingsDetail('security') })
          Divider().color($r('sys.color.comp_divider')).margin({ left: 66, right: 16 })
          this.SettingsCategoryRow({ icon: $r('sys.symbol.info_circle'),
            title: $r('app.string.settings_about_help_title'),
            summary: this.appVersion,
            rowId: 'settings-about-entry',
            action: () => this.openSettingsDetail('about') })
        }
        .id('settings-category-list')
        .width('100%')
        .backgroundColor(this.groupBackground())
        .borderRadius(UiTokens.CARD_RADIUS)
        .clip(true)

        this.SettingsGroupHeader($r('app.string.feature_guide_help_section'))
        Column({ space: 0 }) {
          this.SettingsCategoryRow({ icon: $r('sys.symbol.doc'),
            title: $r('app.string.feature_guide_title'),
            summary: '',
            rowId: 'settings-feature-guide-entry',
            action: () => this.openSettingsDetail('feature-guide') })
        }
        .width('100%')
        .backgroundColor(this.groupBackground())
        .borderRadius(UiTokens.CARD_RADIUS)
        .clip(true)
      }
      .width('100%')
      .constraintSize({ maxWidth: ResponsiveLayout.SETTINGS_CONTENT_MAX_WIDTH })
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
    .backgroundColor(this.pageCanvasBackground())
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Auto)
    .scrollBarWidth(4)
    .align(Alignment.TopStart)
    .id('settings-root-scroll')
  }

  @Builder
  private SettingsAccountDetailContent() {
    Scroll(this.settingsAccountDetailScroller) {
      Column({ space: 0 }) {
        if (this.isAuthenticated()) {
          this.AccountDetailPanel()
        } else {
          this.AccountPanel()
        }
      }
        .width('100%')
        .constraintSize({ maxWidth: ResponsiveLayout.SETTINGS_CONTENT_MAX_WIDTH })
        .padding({ left: this.contentMargin(), right: this.contentMargin(), top: 0,
          bottom: this.pageBottomInset() })
        .justifyContent(FlexAlign.Start)
    }
      .width('100%')
      .height('100%')
      .backgroundColor(this.settingsDetailCanvasBackground())
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Auto)
      .align(Alignment.TopStart)
  }

  @Builder
  private SettingsNetworkDetailContent() {
    Scroll(this.settingsNetworkDetailScroller) {
      Column({ space: 14 }) {
        this.SettingsGroupHeader($r('app.string.settings_network_preferences_title'))
        this.NetworkSettingsPanel()
        this.SettingsGroupHeader($r('app.string.settings_dns_title'))
        this.CustomDnsPanel()
        this.ContextGuideAction($r('app.string.feature_guide_subnet_help'), 'subnet', 'network-subnet-help')
        this.SettingsGroupHeader($r('app.string.exit_node_title'))
        this.ExitNodePanel()
        this.ContextGuideAction(this.exitNodes.length === 0 && this.isAuthenticated() ?
          $r('app.string.feature_guide_exit_empty_help') : $r('app.string.feature_guide_exit_help'),
          'exit', 'network-exit-help')
      }
      .width('100%')
      .constraintSize({ maxWidth: ResponsiveLayout.SETTINGS_CONTENT_MAX_WIDTH })
      .padding({ left: this.contentMargin(), right: this.contentMargin(), top: 0,
        bottom: this.pageBottomInset() })
      .justifyContent(FlexAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.settingsDetailCanvasBackground())
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Auto)
    .align(Alignment.TopStart)
  }

  @Builder
  private SettingsBackgroundRunningDetailContent() {
    BackgroundRunningSettings({
      contentScroller: this.settingsBackgroundRunningDetailScroller,
      contentMargin: this.contentMargin(),
      bottomInset: this.pageBottomInset(),
      glowLevel: this.glowLevel,
      canvasBackground: this.settingsDetailCanvasBackground(),
      groupBackground: this.groupBackground()
    })
  }

  @Builder
  private SettingsAppearanceDetailContent() {
    Scroll(this.settingsAppearanceDetailScroller) {
      Column({ space: 12 }) {
        this.AppearanceSettingsPanel()
      }
      .width('100%')
      .constraintSize({ maxWidth: ResponsiveLayout.SETTINGS_CONTENT_MAX_WIDTH })
      .padding({ left: this.contentMargin(), right: this.contentMargin(), top: 0,
        bottom: this.pageBottomInset() })
      .justifyContent(FlexAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.settingsDetailCanvasBackground())
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Auto)
    .align(Alignment.TopStart)
  }

  @Builder
  private SettingsStorageDetailContent() {
    Scroll(this.settingsStorageDetailScroller) {
      Column() {
        this.CacheSettingsPanel()
      }
      .width('100%')
      .constraintSize({ maxWidth: ResponsiveLayout.SETTINGS_CONTENT_MAX_WIDTH })
      .padding({ left: this.contentMargin(), right: this.contentMargin(), top: 0,
        bottom: this.pageBottomInset() })
      .justifyContent(FlexAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.settingsDetailCanvasBackground())
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Auto)
    .align(Alignment.TopStart)
  }

  @Builder
  private SettingsSecurityDetailContent() {
    Scroll(this.settingsSecurityDetailScroller) {
      Column({ space: 12 }) {
        this.SettingsGroupHeader($r('app.string.settings_security_title'))
        this.SecuritySettingsPanel()
      }
      .width('100%')
      .constraintSize({ maxWidth: ResponsiveLayout.SETTINGS_CONTENT_MAX_WIDTH })
      .padding({ left: this.contentMargin(), right: this.contentMargin(), top: 0,
        bottom: this.pageBottomInset() })
      .justifyContent(FlexAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.settingsDetailCanvasBackground())
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Auto)
    .align(Alignment.TopStart)
  }

  @Builder
  private SettingsAboutDetailContent() {
    Scroll(this.settingsAboutDetailScroller) {
      Column({ space: 12 }) {
        this.VersionPanel()
        if (this.diagnosticsUnlocked) {
          this.DiagnosticsDisclosure()
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: ResponsiveLayout.SETTINGS_CONTENT_MAX_WIDTH })
      .padding({ left: this.contentMargin(), right: this.contentMargin(), top: 0,
        bottom: this.pageBottomInset() })
      .justifyContent(FlexAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.settingsDetailCanvasBackground())
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Auto)
    .align(Alignment.TopStart)
  }

  private settingsDetailTitleBar(title: ResourceStr): HdsNavigationTitleBarOptions {
    return {
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      style: {
        blurStrategy: LightAppearance.blurStrategy(this.glowLevel),
        thermoCtrl: true,
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR
        },
        originalStyle: {
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            },
            menuStyle: {
              iconColor: $r('sys.color.icon_primary'),
              textColor: $r('sys.color.font_primary')
            },
            backIconStyle: {
              iconColor: $r('sys.color.icon_primary')
            }
          }
        },
        scrollEffectStyle: {
          backgroundStyle: {
            backgroundColor: Color.Transparent,
            blurRadius: 24,
            maskExtraHeight: 40.0
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            },
            menuStyle: {
              iconColor: $r('sys.color.icon_primary'),
              textColor: $r('sys.color.font_primary')
            },
            backIconStyle: {
              iconColor: $r('sys.color.icon_primary')
            }
          }
        },
        systemMaterialEffect: {
          materialType: this.glowMaterialType(),
          materialLevel: this.glowMaterialLevel()
        }
      },
      content: { title: { mainTitle: title } }
    };
  }

  @Builder
  private SettingsDetailPageMap(name: string) {
    if (name === 'account') {
      HdsNavDestination() { this.SettingsAccountDetailContent() }
        .titleMode(HdsNavDestinationTitleMode.MINI)
        .bindToScrollable([this.settingsAccountDetailScroller])
        .titleBar(this.settingsDetailTitleBar($r('app.string.account_title')))
        .hideBackButton(false)
        .backgroundColor(this.settingsDetailCanvasBackground())
        .onShown(() => {
          this.settingsDetailActive = true;
        })
        .onWillDisappear(() => {
          this.settingsDetailActive = false;
        })
    } else if (name === 'network') {
      HdsNavDestination() { this.SettingsNetworkDetailContent() }
        .titleMode(HdsNavDestinationTitleMode.MINI)
        .bindToScrollable([this.settingsNetworkDetailScroller])
        .titleBar(this.settingsDetailTitleBar($r('app.string.settings_network_connection_title')))
        .hideBackButton(false)
        .backgroundColor(this.settingsDetailCanvasBackground())
        .onShown(() => {
          this.settingsDetailActive = true;
        })
        .onWillDisappear(() => {
          this.settingsDetailActive = false;
        })
    } else if (name === 'background-running') {
      HdsNavDestination() { this.SettingsBackgroundRunningDetailContent() }
        .titleMode(HdsNavDestinationTitleMode.MINI)
        .bindToScrollable([this.settingsBackgroundRunningDetailScroller])
        .titleBar(this.settingsDetailTitleBar($r('app.string.background_running_title')))
        .hideBackButton(false)
        .backgroundColor(this.settingsDetailCanvasBackground())
        .onShown(() => {
          this.settingsDetailActive = true;
        })
        .onWillDisappear(() => {
          this.settingsDetailActive = false;
        })
    } else if (name === 'appearance') {
      HdsNavDestination() { this.SettingsAppearanceDetailContent() }
        .titleMode(HdsNavDestinationTitleMode.MINI)
        .bindToScrollable([this.settingsAppearanceDetailScroller])
        .titleBar(this.settingsDetailTitleBar($r('app.string.settings_appearance_navigation_title')))
        .hideBackButton(false)
        .backgroundColor(this.settingsDetailCanvasBackground())
        .onShown(() => {
          this.settingsDetailActive = true;
        })
        .onWillDisappear(() => {
          this.settingsDetailActive = false;
        })
    } else if (name === 'storage') {
      HdsNavDestination() { this.SettingsStorageDetailContent() }
        .titleMode(HdsNavDestinationTitleMode.MINI)
        .bindToScrollable([this.settingsStorageDetailScroller])
        .titleBar(this.settingsDetailTitleBar($r('app.string.native_settings_storage')))
        .hideBackButton(false)
        .backgroundColor(this.settingsDetailCanvasBackground())
        .onShown(() => {
          this.settingsDetailActive = true;
          this.storageRingPageShown = true;
          this.startStorageRingAnimation();
        })
        .onWillDisappear(() => {
          this.storageRingPageShown = false;
          this.storageRingAnimationStarted = false;
          this.storageRingGeneration++;
          this.settingsDetailActive = false;
        })
    } else if (name === 'security') {
      HdsNavDestination() { this.SettingsSecurityDetailContent() }
        .titleMode(HdsNavDestinationTitleMode.MINI)
        .bindToScrollable([this.settingsSecurityDetailScroller])
        .titleBar(this.settingsDetailTitleBar($r('app.string.settings_security_title')))
        .hideBackButton(false)
        .backgroundColor(this.settingsDetailCanvasBackground())
        .onShown(() => {
          this.settingsDetailActive = true;
        })
        .onWillDisappear(() => {
          this.settingsDetailActive = false;
        })
    } else if (name === 'feature-guide') {
      HdsNavDestination() {
        FeatureSetupGuide({
          contentScroller: this.featureGuideScroller,
          contentMargin: this.contentMargin(),
          bottomInset: this.pageBottomInset()
        })
      }
        .titleMode(HdsNavDestinationTitleMode.MINI)
        .bindToScrollable([this.featureGuideScroller])
        .titleBar(this.settingsDetailTitleBar($r('app.string.feature_guide_title')))
        .hideBackButton(false)
        .backgroundColor(this.settingsDetailCanvasBackground())
        .onShown(() => {
          this.settingsDetailActive = true;
        })
        .onWillDisappear(() => {
          this.settingsDetailActive = false;
        })
    } else if (name === 'about') {
      HdsNavDestination() { this.SettingsAboutDetailContent() }
        .titleMode(HdsNavDestinationTitleMode.MINI)
        .bindToScrollable([this.settingsAboutDetailScroller])
        .titleBar(this.settingsDetailTitleBar($r('app.string.settings_about_help_title')))
        .hideBackButton(false)
        .backgroundColor(this.settingsDetailCanvasBackground())
        .onShown(() => {
          this.settingsDetailActive = true;
        })
        .onWillDisappear(() => {
          this.settingsDetailActive = false;
        })
    }
  }

  @Builder
  private HomeTitleTopInset() {
    Blank()
      .width('100%')
      .height(this.homeTitleCompact ? 12 : 0)
      .animation({ duration: MotionTokens.NORMAL, curve: MotionTokens.curve() })
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
        blurStrategy: LightAppearance.blurStrategy(this.glowLevel),
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
            backgroundColor: Color.Transparent,
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
          materialType: this.glowMaterialType(),
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
    .backgroundColor(this.pageCanvasBackground())
  }

  @Builder
  private SettingsPage() {
    HdsNavigation(this.settingsPathStack) {
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
        blurStrategy: LightAppearance.blurStrategy(this.glowLevel),
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
            backgroundColor: Color.Transparent,
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
          materialType: this.glowMaterialType(),
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
    .titleMode(HdsNavigationTitleMode.FREE)
    .bindToScrollable([this.settingsScroller])
    .navDestination(this.SettingsDetailPageMap)
    .hideBackButton(true)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
    .id('hds-navigation-settings')
    .backgroundColor(this.pageCanvasBackground())
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
        blurStrategy: LightAppearance.blurStrategy(this.glowLevel),
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
            backgroundColor: Color.Transparent,
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
          materialType: this.glowMaterialType(),
          materialLevel: this.glowMaterialLevel()
        }
      },
      content: {
        title: {
          mainTitle: $r('app.string.tab_transfer'),
          subTitle: $r('app.string.transfer_multi_protocol_subtitle')
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
    .backgroundColor(this.pageCanvasBackground())
  }

  @Builder
  private FilesPage() {
    // HdsTabs may build an inactive neighbor during a transition. Defer the
    // file navigation/title builders until Files has actually been selected.
    if (this.filesPageActivated || this.activeNavigationId === 'files') {
      this.FilesContent()
    }
  }

  @Builder
  private HomeTabBar() {
    Column({ space: 2 }) {
      Image($r('app.media.tab_home'))
        .width(24)
        .height(24)
        .fillColor(this.activeTab === 0 ? $r('app.color.emphasize') :
          $r('sys.color.icon_secondary'))
      Text($r('app.string.tab_home'))
        .fontSize(10)
        .fontColor(this.activeTab === 0 ? $r('app.color.emphasize') :
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
        .fillColor(this.activeTab === 1 ? $r('app.color.emphasize') :
          $r('sys.color.icon_secondary'))
      Text($r('app.string.tab_transfer'))
        .fontSize(10)
        .fontColor(this.activeTab === 1 ? $r('app.color.emphasize') :
          $r('sys.color.font_secondary'))
        .maxLines(1)
    }
    .id('tab-transfer')
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private FilesTabBar() {
    Column({ space: 2 }) {
      Image($r('app.media.tab_files'))
        .width(24)
        .height(24)
        .fillColor(this.activeTab === 2 ? $r('app.color.emphasize') :
          $r('sys.color.icon_secondary'))
      Text($r('app.string.tab_files'))
        .fontSize(10)
        .fontColor(this.activeTab === 2 ? $r('app.color.emphasize') :
          $r('sys.color.font_secondary'))
        .maxLines(1)
    }
    .id('tab-files')
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
        .fillColor(this.activeTab === 3 ? $r('app.color.emphasize') :
          $r('sys.color.icon_secondary'))
      Text($r('app.string.tab_settings'))
        .fontSize(10)
        .fontColor(this.activeTab === 3 ? $r('app.color.emphasize') :
          $r('sys.color.font_secondary'))
        .maxLines(1)
    }
    .id('tab-settings')
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private NavigationPage(id: NavigationTabId) {
    if (id === 'home') {
      this.HomePage()
    } else if (id === 'transfer') {
      this.TransferPage()
    } else if (id === 'files') {
      this.FilesPage()
    } else {
      this.SettingsPage()
    }
  }

  @Builder
  private MobileTabs() {
    HdsTabs({
      barPosition: BarPosition.End,
      index: this.currentTab,
      controller: this.tabsController
    }) {
      ForEach(this.visibleNavigationTabs(), (id: NavigationTabId) => {
        TabContent() {
          this.NavigationPage(id)
        }
        .tabBar(new BottomTabBarStyle(this.navigationTabIcon(id), this.navigationTabLabel(id))
          .id(`tab-${id}`)
          .labelStyle({
            unselectedColor: $r('sys.color.font_secondary'),
            selectedColor: $r('app.color.emphasize')
          })
          .iconStyle({
            unselectedColor: $r('sys.color.icon_secondary'),
            selectedColor: $r('app.color.emphasize')
          }))
      }, (id: NavigationTabId) => id)
    }
    .vertical(false)
    // Keep the settings detail route isolated from the shell's horizontal
    // page gesture. The gesture is restored after the detail route pops.
    .scrollable(!this.settingsDetailActive && !this.deviceDetailVisible)
    .animationDuration(MotionTokens.PAGE)
    .barMode(BarMode.Fixed)
    .barHeight(56)
    .barOverlap(true)
    .barBackgroundColor(Color.Transparent)
    .barFloatingStyle({
      barSideMargin: 36,
      barBottomMargin: this.navigationBottomMargin,
      gradientMask: {
        maskColor: $r('app.color.tab_bar_gradient_mask'),
        maskHeight: 72 + this.navigationBottomMargin
      },
      lightColor: this.glowLightColor(),
      barOpacity: 0.96,
      thermoCtrl: true,
      systemMaterialEffect: {
        materialType: this.glowMaterialType(),
        materialLevel: this.glowMaterialLevel()
      }
    })
    .divider({ mode: DividerMode.NONE })
    .onTabBarClick((index: number) => {
      this.handleNavigationTabClick(index);
    })
    .onSelected((index: number) => {
      this.scheduleNavigationTabChange(index, false);
      // HdsTabs emits onSelected when the swipe transition starts and
      // onChange after it completes. Writing the controlled index here makes
      // the component jump straight to the destination and cancels the
      // interactive page animation.
    })
    .onChange((index: number) => {
      this.scheduleNavigationTabChange(index, true);
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
    this.cancelVpnAutoRecovery();
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
        await this.vpnSessionController.stopVpnExtensionDirect();
      } catch (_vpnError) {
        // A stopped extension is already in the desired state.
      }
      if (!this.diagnosticActionRequestGuard.isCurrent(requestGeneration)) {
        return;
      }
      try {
        await this.vpnSessionController.stopBackendDirect();
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
      this.loadAccountProfiles();
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
    this.cancelVpnAutoRecovery();
    if (this.diagnosticActionInProgress) {
      return;
    }
    this.diagnosticActionInProgress = true;
    this.diagnosticActionStatus = '';
    this.recordDiagnosticEvent('diagnostic_vpn_cut_requested', 'diagnostics');
    const requestGeneration: number = this.diagnosticActionRequestGuard.begin();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      await this.vpnSessionController.stopVpnExtensionDirect();
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
    if (!BuildProfile.DEBUG) {
      return;
    }
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
    if (!BuildProfile.DEBUG) {
      return;
    }
    this.cancelVpnAutoRecovery();
    if (this.diagnosticActionInProgress) {
      return;
    }
    this.diagnosticActionInProgress = true;
    this.diagnosticActionStatus = '';
    this.recordDiagnosticEvent('diagnostic_crash_simulation_requested', 'diagnostics');
    const requestGeneration: number = this.diagnosticActionRequestGuard.begin();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      await this.vpnSessionController.stopVpnExtensionDirect();
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
          selectedColor: $r('app.color.emphasize')
        })
        .iconStyle({
          unselectedColor: $r('sys.color.icon_secondary'),
          selectedColor: $r('app.color.emphasize')
        }))

      TabContent() {
        this.TransferPage()
      }
      .tabBar(new BottomTabBarStyle($r('app.media.tab_transfer'), $r('app.string.tab_transfer'))
        .id('tab-transfer')
        .labelStyle({
          unselectedColor: $r('sys.color.font_secondary'),
          selectedColor: $r('app.color.emphasize')
        })
        .iconStyle({
          unselectedColor: $r('sys.color.icon_secondary'),
          selectedColor: $r('app.color.emphasize')
        }))

      TabContent() {
        this.FilesPage()
      }
      .tabBar(new BottomTabBarStyle($r('app.media.tab_files'), $r('app.string.tab_files'))
        .id('tab-files')
        .labelStyle({
          unselectedColor: $r('sys.color.font_secondary'),
          selectedColor: $r('app.color.emphasize')
        })
        .iconStyle({
          unselectedColor: $r('sys.color.icon_secondary'),
          selectedColor: $r('app.color.emphasize')
        }))

      TabContent() {
        this.SettingsPage()
      }
      .tabBar(new BottomTabBarStyle($r('app.media.tab_settings'), $r('app.string.tab_settings'))
        .id('tab-settings')
        .labelStyle({
          unselectedColor: $r('sys.color.font_secondary'),
          selectedColor: $r('app.color.emphasize')
        })
        .iconStyle({
          unselectedColor: $r('sys.color.icon_secondary'),
          selectedColor: $r('app.color.emphasize')
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
    .onTabBarClick((index: number) => {
      this.handleNavigationTabClick(index);
    })
    .onChange((index: number) => {
      this.scheduleNavigationTabChange(index, true);
    })
    .width('100%')
    .height('100%')
  }

  @Builder
  private UpdateChangelogContent() {
    Stack() {
      UpdateChangelogSheet({
        entries: this.updateChangelogEntries(),
        appName: 'MeshArc',
        materialLevel: this.glowMaterialLevel(),
        glowLevel: this.glowLevel
      })
      if (this.isSecurityCoverActive()) {
        this.SecurityCoverOverlay()
      }
    }
      .width('100%')
      .height('100%')
      .id('update-changelog-sheet-content')
  }

  @Builder
  private SecurityCoverOverlay() {
    if (this.appLockRequired) {
      this.AppLockOverlay()
    } else if (!this.securityPreferencesReady) {
      Column() {}
        .width('100%')
        .height('100%')
        .backgroundColor($r('sys.color.background_secondary'))
        .id('security-startup-cover')
    }
  }

  @Builder
  private AppLockOverlay() {
    if (this.appLockRequired) {
      Column({ space: 14 }) {
        Image($r('app.media.app_lock'))
          .width(48)
          .height(48)
          .objectFit(ImageFit.Contain)
          .id('security-app-lock-icon')
        Text($r('app.string.security_app_locked_title'))
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Text(this.appLockMessage.length > 0 ? this.appLockMessage :
          $r('app.string.security_app_locked_description'))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .textAlign(TextAlign.Center)
          .maxLines(2)
          .width('78%')
        Button($r('app.string.security_unlock_app_action'))
          .id('security-unlock-app-action')
          .enabled(!this.appLockAuthenticating)
          .onClick(() => this.authenticateApplication())
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor($r('sys.color.background_secondary'))
      .id('security-app-lock-overlay')
    }
  }

  @Builder
  private RootSheetHosts() {
    Stack() {
      Row().width(0).height(0).id('standalone-diagnostics-sheet-host')
        .bindSheet($$this.standaloneDiagnosticsVisible, this.StandaloneDiagnosticsContent(), {
          detents: ['80%', SheetSize.LARGE], preferType: SheetType.BOTTOM, mode: SheetMode.OVERLAY,
          dragBar: true, showClose: true, enableOutsideInteractive: false,
          systemMaterial: LightAppearance.sheet(this.glowLevel),
          title: { title: $r('app.string.standalone_diagnostics_title') },
          onDisappear: () => this.closeStandaloneDiagnostics()
        })
      Row()
        .width(0)
        .height(0)
        .id('update-changelog-sheet-host')
        .bindSheet($$this.updateChangelogVisible, this.UpdateChangelogContent(), {
          detents: ['80%'],
          preferType: SheetType.BOTTOM,
          mode: SheetMode.OVERLAY,
          scrollSizeMode: ScrollSizeMode.CONTINUOUS,
          dragBar: true,
          showClose: false,
          enableOutsideInteractive: false,
          systemMaterial: LightAppearance.sheet(this.glowLevel),
          onDisappear: () => {
            this.onUpdateChangelogSheetDisappear();
          }
        })
      Row()
        .width(0)
        .height(0)
        .id('device-detail-sheet-host')
        .bindSheet($$this.deviceDetailVisible, this.DeviceDetailsContent(), {
          detents: ['76%', SheetSize.LARGE],
          preferType: SheetType.BOTTOM,
          mode: SheetMode.OVERLAY,
          scrollSizeMode: ScrollSizeMode.CONTINUOUS,
          dragBar: true,
          showClose: true,
          enableOutsideInteractive: false,
          systemMaterial: LightAppearance.sheet(this.glowLevel),
          title: (): void => { this.DeviceDetailsTitle(); },
          onDisappear: () => {
            this.deviceDetailVisible = false;
            this.stopDeviceDetailRefreshPolling();
          }
        })
      Row()
        .width(0)
        .height(0)
        .id('file-transfer-method-sheet-host')
        .bindSheet($$this.fileTransferMethodVisible, this.FileTransferMethodContent(), {
          detents: ['42%', SheetSize.MEDIUM],
          preferType: SheetType.BOTTOM,
          mode: SheetMode.OVERLAY,
          scrollSizeMode: ScrollSizeMode.CONTINUOUS,
          dragBar: true,
          showClose: true,
          enableOutsideInteractive: false,
          systemMaterial: LightAppearance.sheet(this.glowLevel),
          title: { title: $r('app.string.transfer_method_title') },
          onDisappear: () => {
            this.fileTransferMethodVisible = false;
          }
        })
      Row()
        .width(0)
        .height(0)
        .id('media-method-sheet-host')
        .bindSheet($$this.mediaMethodVisible, this.MediaMethodContent(), {
          detents: ['42%', SheetSize.MEDIUM],
          preferType: SheetType.BOTTOM,
          mode: SheetMode.OVERLAY,
          scrollSizeMode: ScrollSizeMode.CONTINUOUS,
          dragBar: true,
          showClose: true,
          enableOutsideInteractive: false,
          systemMaterial: LightAppearance.sheet(this.glowLevel),
          title: { title: $r('app.string.media_method_title') },
          onDisappear: () => {
            this.mediaMethodVisible = false;
          }
        })
      Row()
        .width(0)
        .height(0)
        .id('native-settings-sheet-host')
        .bindSheet($$this.nativeSettingsVisible, this.NativeSettingsSheetContent(), {
          detents: ['94%', SheetSize.LARGE],
          preferType: SheetType.BOTTOM,
          mode: SheetMode.OVERLAY,
          scrollSizeMode: ScrollSizeMode.CONTINUOUS,
          dragBar: true,
          showClose: false,
          enableOutsideInteractive: false,
          systemMaterial: LightAppearance.sheet(this.glowLevel),
          onDisappear: () => {
            this.nativeSettingsVisible = false;
          }
        })
      Row()
        .width(0)
        .height(0)
        .id('connection-details-sheet-host')
        .bindSheet($$this.connectionDetailsVisible, this.ConnectionDetailsContent(), {
          detents: ['76%', SheetSize.LARGE],
          preferType: SheetType.BOTTOM,
          mode: SheetMode.OVERLAY,
          scrollSizeMode: ScrollSizeMode.CONTINUOUS,
          dragBar: true,
          showClose: true,
          enableOutsideInteractive: false,
          systemMaterial: LightAppearance.sheet(this.glowLevel),
          title: (): void => { this.ConnectionDetailsTitle(); },
          onDisappear: () => {
            this.connectionDetailsVisible = false;
          }
        })
    }
    .width(0)
    .height(0)
    .id('root-sheet-hosts')
  }

  @Builder
  private AppBackgroundImage(uri: string) {
    Image(uri)
      .width('100%')
      .height('100%')
      .objectFit(ImageFit.Cover)
      .opacity(this.immersiveColorBackgroundEnabled ? 0.48 : 0.36)
      .brightness(PersonalizationPreferences.backgroundBrightnessFactor(this.backgroundBrightnessValue))
      .onError(() => this.onBackgroundImageLoadError(uri))
      .id('app-background-image')
  }

  @Builder
  private AppBackgroundLayer() {
    Stack() {
      if (this.nativeSettingsBackgroundUri.length > 0 && !this.backgroundUnavailable) {
        this.AppBackgroundImage(this.nativeSettingsBackgroundUri)
      }
      if (this.immersiveColorBackgroundEnabled) {
        Row()
          .width('100%')
          .height('100%')
          .backgroundColor(this.immersiveColorTint())
          .brightness(PersonalizationPreferences.backgroundBrightnessFactor(this.backgroundBrightnessValue))
          .id('immersive-color-background')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
    .hitTestBehavior(HitTestMode.None)
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      this.AppBackgroundLayer()
      Column() {
        this.MobileTabs()
      }
      .width('100%')
      .margin({ top: 2 })
      .height('100%')
      .transition(TransitionEffect.OPACITY.animation({
        duration: MotionTokens.FAST, curve: MotionTokens.curve()
      }))
      this.RootSheetHosts()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageCanvasBackground())
    .id('shell-hds-navigation-safe-area')
    .onAreaChange((_oldValue: Area, newValue: Area) => this.updateLayoutMetrics(newValue))
    .bindContentCover(this.isSecurityCoverActive(), this.SecurityCoverOverlay(), {
      backgroundColor: $r('sys.color.background_secondary'),
      onWillDismiss: (dismissAction: DismissContentCoverAction) => {
        if (this.isSecurityCoverActive()) {
          return;
        }
        dismissAction.dismiss();
      }
    })
  }
}
