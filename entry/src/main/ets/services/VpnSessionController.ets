import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { AccountProfile, AccountProfiles, ServerAccountProfiles } from './AccountProfiles';
import { AuthKeyLogin } from './AuthKeyLogin';
import { ControlServerSettings, DEFAULT_CONTROL_SERVER_URL } from './ControlServerConfig';
import { ControlServerPreset, ControlServerPresetCatalog, ControlServerPresets } from './ControlServerPresets';
import { DeviceNameService } from './DeviceNameService';
import { DiagnosticPrivacy } from './DiagnosticPrivacy';
import {
  HomeReadOnlyGateway,
  HomeReadOnlyRequestGuard,
  HomeTrafficStatus,
  parseHomeTrafficStatus
} from './HomeReadOnlyGateway';
import {
  NetworkSettingKey,
  NetworkSettingsGateway,
  NetworkSettingsUpdateQueue,
  PendingNetworkSettingsUpdate
} from './NetworkSettingsGateway';
import { SettingsPreferencesGateway } from './SettingsPreferencesGateway';
import { VpnAutoRecovery } from './VpnAutoRecovery';
import {
  VpnCommandGateway,
  VpnCommandState,
  VpnCommandStateMachine,
  VpnConnectConfigHandoff,
  VpnCoreCommand
} from './VpnCommandGateway';
import {
  AccountSummary,
  ExitNodeChoice,
  LocalSendStatus,
  MeshArcReceiverStatus,
  NetworkSettings,
  PeerSummary,
  PersistedPeerSnapshot,
  TAILDRIVE_CONTROL_REQUEST_FILE_NAME,
  TAILDRIVE_CONTROL_RESPONSE_FILE_NAME,
  TAILDRIVE_MANUAL_TRANSFER_REQUEST_FILE_NAME,
  TAILDRIVE_MANUAL_TRANSFER_RESPONSE_FILE_NAME,
  TAILDRIVE_QUERY_REQUEST_FILE_NAME,
  TAILDRIVE_QUERY_RESPONSE_FILE_NAME,
  TAILDRIVE_TRANSFER_REQUEST_FILE_NAME,
  TAILDRIVE_TRANSFER_RESPONSE_FILE_NAME,
  TAILDROP_CANCEL_REQUEST_FILE_NAME,
  TAILDROP_RECEIVE_REQUEST_FILE_NAME,
  TAILDROP_RECEIVE_RESPONSE_FILE_NAME,
  TAILDROP_SEND_REQUEST_FILE_NAME,
  TAILDROP_TARGETS_FILE_NAME,
  TaildropSnapshot,
  VPN_BACKEND_HANDOFF_REQUEST_FILE_NAME,
  VPN_BACKEND_HANDOFF_RESPONSE_FILE_NAME,
  VPN_CONNECT_CONFIG_FILE_NAME,
  VPN_PEERS_FILE_NAME,
  VPN_PROBE_STATUS_FILE_NAME,
  VPN_STOP_REQUEST_FILE_NAME,
  VPN_STOP_RESPONSE_FILE_NAME,
  VpnBackendHandoffRequest,
  VpnBackendHandoffResponse,
  VpnStopRequest,
  VpnStopResponse,
  emptyMeshArcReceiverStatus
} from '@tailscale/common';

const MIN_CONNECTION_LOADING_MS: number = 250;
const CONNECTION_START_FRAME_DELAY_MS: number = 32;
const CONNECTION_POLL_INTERVAL_MS: number = 250;
const BACKEND_READINESS_POLL_INTERVAL_MS: number = 250;
const VPN_HEARTBEAT_FRESH_MS: number = 5000;
const VPN_HEARTBEAT_CONFIRM_TIMEOUT_MS: number = 2500;
const VPN_CONNECTED_GRACE_MS: number = 8000;
const FILE_WATCH_CLOSE_WRITE: number = 0x8;
const FAST_RECONNECT_TTL_MS: number = 15000;
const VPN_STOP_POLL_INTERVAL_MS: number = 50;
const VPN_STOP_POLL_MAX_ATTEMPTS: number = 150;

export interface VpnTrafficSample {
  downloadBytesPerSecond: number;
  uploadBytesPerSecond: number;
}

export interface VpnBackendSnapshot {
  status: string;
  exitNodes: ExitNodeChoice[];
  peers: PeerSummary[];
  networkSettings: NetworkSettings;
  account: AccountSummary;
  taildrop: TaildropSnapshot;
}

export type VpnLoginPromptKind = '' | 'login_loading' | 'login_browser_prompt' | 'auth_key_loading';

export function sanitizeVpnDiagnosticToken(value: string, fallback: string = 'unknown'): string {
  const normalized: string = value.trim().toLowerCase().replace(/[^a-z0-9_.-]+/g, '_');
  if (normalized.length === 0) {
    return fallback;
  }
  return normalized.substring(0, Math.min(normalized.length, 48));
}

export function sanitizeVpnDiagnosticCount(value: number): number {
  return Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
}

export function mergePeerWithLocalSend(
  incoming: PeerSummary,
  current: PeerSummary | undefined
): PeerSummary {
  const incomingStatus: LocalSendStatus | undefined = incoming.localSend;
  const currentStatus: LocalSendStatus | undefined = current?.localSend;
  if (currentStatus === undefined) {
    return incoming;
  }
  if (incomingStatus === undefined || (currentStatus.checkedAtMs ?? 0) > (incomingStatus.checkedAtMs ?? 0)) {
    const merged: PeerSummary = {
      key: incoming.key,
      name: incoming.name,
      os: incoming.os,
      osVersion: incoming.osVersion,
      deviceModel: incoming.deviceModel,
      deviceType: incoming.deviceType,
      addresses: incoming.addresses,
      online: incoming.online,
      exitNode: incoming.exitNode,
      keyExpired: incoming.keyExpired,
      keyExpiryUnixMs: incoming.keyExpiryUnixMs,
      localSend: currentStatus
    };
    return merged;
  }
  return incoming;
}

export interface VpnSessionDependencies {
  vpnCommandGateway?: VpnCommandGateway;
  homeReadOnlyGateway?: HomeReadOnlyGateway;
  networkSettingsGateway?: NetworkSettingsGateway;
  settingsPreferencesGateway?: SettingsPreferencesGateway;
  vpnCommandStateMachine?: VpnCommandStateMachine;
  homeReadOnlyRequestGuard?: HomeReadOnlyRequestGuard;
  vpnAutoRecovery?: VpnAutoRecovery;
  systemVpnAbsent?: () => Promise<boolean>;
}

export interface VpnSessionHost {
  getFilesDir: () => string;
  getCacheDir: () => string;
  getLifecycleGeneration: () => number;
  isAppShellReady: () => boolean;
  isAppLockRequired: () => boolean;
  isLogoutInProgress: () => boolean;
  isDiagnosticActionInProgress: () => boolean;
  isCacheClearInProgress: () => boolean;
  isTaildropSendActive: () => boolean;
  isTaildropReceiveInProgress: () => boolean;
  isTaildropMediaSaveInProgress: () => boolean;
  shouldPollHealthFast: () => boolean;

  getBackendStatus: () => string;
  setBackendStatus: (status: string) => void;
  getVpnStatus: () => string;
  setVpnStatus: (status: string) => void;
  isBackendReady: () => boolean;
  setBackendReady: (ready: boolean) => void;
  isBackendInitializationVisible: () => boolean;
  setBackendInitializationVisible: (visible: boolean) => void;
  setDevicesLoading: (loading: boolean) => void;
  hasAuthenticatedSession: () => boolean;
  setHasAuthenticatedSession: (authenticated: boolean) => void;

  isConnectInProgress: () => boolean;
  setConnectInProgressState: (inProgress: boolean) => void;
  isDisconnectInProgress: () => boolean;
  setDisconnectInProgress: (inProgress: boolean) => void;
  isLoginInProgress: () => boolean;
  setLoginInProgress: (inProgress: boolean) => void;
  getLoginHandoffStatus: () => string;
  setLoginHandoffStatus: (status: string) => void;
  setLoginPromptKind: (kind: VpnLoginPromptKind) => void;

  isAuthKeyLoginVisible: () => boolean;
  setAuthKeyLoginVisible: (visible: boolean) => void;
  getAuthKeyInput: () => string;
  setAuthKeyInput: (input: string) => void;
  getAuthKeyStatus: () => string;
  setAuthKeyStatus: (status: string) => void;

  isControlServerConfirmed: () => boolean;
  setControlServerConfirmed: (confirmed: boolean) => void;
  getControlServerURL: () => string;
  setControlServerURL: (url: string) => void;
  setControlServerInput: (input: string) => void;
  setControlServerStatus: (status: string) => void;
  setControlServerEditorVisible: (visible: boolean) => void;
  setControlServerPresets: (presets: ControlServerPreset[]) => void;
  isControlServerSwitching: () => boolean;
  setControlServerSwitching: (switching: boolean) => void;

  getAccountProfileId: () => string;
  setAccountProfileId: (id: string) => void;
  getAccountProfiles: () => AccountProfile[];
  setAccountProfiles: (profiles: AccountProfile[]) => void;
  setAccountProfileStatus: (status: string) => void;

  getPeers: () => PeerSummary[];
  onPeersUpdated: (mergedPeers: PeerSummary[]) => void;
  onPeerPresenceInvalidated: (peerKey: string) => void;
  setMeshArcReceiver: (status: MeshArcReceiverStatus) => void;
  setAccountSummary: (summary: AccountSummary) => void;
  setAvatarLoadFailed: (failed: boolean) => void;

  getExitNodes: () => ExitNodeChoice[];
  setExitNodes: (choices: ExitNodeChoice[]) => void;
  isExitNodeUpdateInProgress: () => boolean;
  setExitNodeUpdateInProgress: (inProgress: boolean) => void;
  isExitNodeStatusFailed: () => boolean;
  setExitNodeNoneStatus: () => void;
  setExitNodeSelectedStatus: (name: string) => void;
  setExitNodeUnavailableStatus: () => void;
  setExitNodeRawStatus: (status: string) => void;

  getNetworkSettings: () => NetworkSettings;
  setNetworkSettings: (settings: NetworkSettings) => void;
  setNetworkSettingStatus: (status: string) => void;
  isRouteAllUpdateInProgress: () => boolean;
  setRouteAllUpdateInProgress: (inProgress: boolean) => void;
  isExitNodeLanUpdateInProgress: () => boolean;
  setExitNodeLanUpdateInProgress: (inProgress: boolean) => void;

  setTrafficDownloadBytes: (bytes: number) => void;
  setTrafficUploadBytes: (bytes: number) => void;
  setTrafficDownloadRate: (rate: number) => void;
  setTrafficUploadRate: (rate: number) => void;
  getTrafficSamples: () => VpnTrafficSample[];
  setTrafficSamples: (samples: VpnTrafficSample[]) => void;

  isVpnConflictDialogVisible: () => boolean;
  setVpnConflictDialogVisible: (visible: boolean) => void;
  showVpnConflictAlertDialog: () => void;
  syncHomeTitleCompact: (compact: boolean) => void;
  setHomeTitleCompact: (compact: boolean) => void;
  setBackendRestartDeferred?: (deferred: boolean) => void;

  deviceModel: () => string;
  harmonyOSHostinfoVersion: () => string;
  openControlServerSettings: () => void;
  openSecureLoginBrowser: (authUrl: string) => Promise<void>;
  confirmControlServerSelection: (normalizedUrl: string) => ControlServerSettings | undefined;
  invalidateAccountGuard: () => void;
  clearControlServerShellState: () => void;
  reloadTaildropStorageForActiveIdentity: () => void;
  resetTaildropSnapshot: () => void;
  applyBackendTaildropSnapshot: (snapshot: TaildropSnapshot) => void;
  onLiveExtensionTick: () => void;
  resetStreamingStatesForDisconnect: () => void;
  autoProbeConnectedPeerServices: () => void;
  syncOfflinePeerStatusRefreshPolling: () => void;
  syncWindowPrivacyMode: () => void;
  logServiceStatusIfChanged: () => void;
  scheduleLifecycleTask: (task: () => void, delayMs: number) => number;
  recordDiagnosticEvent: (event: string, phase: string, code?: number) => void;
}

/**
 * Deep module owning VPN connection/disconnection/login/auth-key lifecycle,
 * `VpnCommandStateMachine`, backend handoff & auto-recovery, `fileIo.Watcher`
 * status observation, peer directory snapshot validation, and exit-node /
 * network-settings update queues behind `VpnSessionHost`.
 */
export class VpnSessionController {
  private readonly host: VpnSessionHost;
  readonly vpnCommandGateway: VpnCommandGateway;
  readonly homeReadOnlyGateway: HomeReadOnlyGateway;
  readonly networkSettingsGateway: NetworkSettingsGateway;
  readonly vpnCommandStateMachine: VpnCommandStateMachine;
  readonly homeReadOnlyRequestGuard: HomeReadOnlyRequestGuard;
  readonly vpnAutoRecovery: VpnAutoRecovery;
  private readonly systemVpnAbsentFn: () => Promise<boolean>;
  private readonly exitNodeUpdateQueue: NetworkSettingsUpdateQueue = new NetworkSettingsUpdateQueue();
  private readonly routeAllUpdateQueue: NetworkSettingsUpdateQueue = new NetworkSettingsUpdateQueue();
  private readonly exitNodeLanUpdateQueue: NetworkSettingsUpdateQueue = new NetworkSettingsUpdateQueue();

  private connectionStatusWatcher?: fileIo.Watcher;
  connectionPollTimer: number = -1;
  connectionCompletionTimer: number = -1;
  connectionStartedAtMs: number = 0;
  backendReadinessPollTimer: number = -1;
  backendRestartDeferred: boolean = false;
  vpnBackendWasRunningBeforeConnect: boolean = false;
  vpnBackendHandoffInFlight: boolean = false;
  vpnFailedExtensionRecoveryInFlight: boolean = false;
  cachedVpnConnectConfig: string = '';
  cachedVpnConnectConfigAtMs: number = 0;
  healthPollTimer: number = -1;
  loginPollTimer: number = -1;
  refreshInFlight: boolean = false;
  backendRestartPromise: Promise<void> | undefined = undefined;
  vpnAutoRecoveryInFlight: boolean = false;
  vpnAutoRecoveryCommandId: number = 0;
  vpnAutoRecoveryStartedAtMs: number = 0;
  connectCommandId: number = 0;
  loginCommandId: number = 0;
  disconnectCommandId: number = 0;
  exitNodeUpdatePromise: Promise<void> | undefined = undefined;
  routeAllUpdatePromise: Promise<void> | undefined = undefined;
  exitNodeLanUpdatePromise: Promise<void> | undefined = undefined;
  trafficSession: number = 0;
  trafficLastHeartbeatMs: number = 0;
  trafficLastDownloadBytes: number = 0;
  trafficLastUploadBytes: number = 0;
  lastConfirmedVpnStatus: string = '';
  lastConfirmedVpnHeartbeatMs: number = 0;
  vpnStatusGraceActive: boolean = false;
  vpnHeartbeatObservationStartedAtMs: number = 0;
  vpnHeartbeatBaselineMs: number = 0;
  vpnHeartbeatConfirmed: boolean = false;
  vpnStopPollTimer: number = -1;
  vpnStopRequestId: number = 0;
  peerSnapshotSignature: string = '';
  emptyPeerSnapshotSinceMs: number = 0;

  constructor(host: VpnSessionHost, deps?: VpnSessionDependencies) {
    this.host = host;
    this.vpnCommandGateway = deps?.vpnCommandGateway ?? new VpnCommandGateway();
    this.homeReadOnlyGateway = deps?.homeReadOnlyGateway ?? new HomeReadOnlyGateway();
    this.networkSettingsGateway = deps?.networkSettingsGateway ?? new NetworkSettingsGateway();
    this.vpnCommandStateMachine = deps?.vpnCommandStateMachine ?? new VpnCommandStateMachine();
    this.homeReadOnlyRequestGuard = deps?.homeReadOnlyRequestGuard ?? new HomeReadOnlyRequestGuard();
    this.vpnAutoRecovery = deps?.vpnAutoRecovery ?? new VpnAutoRecovery();
    this.systemVpnAbsentFn = deps?.systemVpnAbsent ?? ((): Promise<boolean> => VpnAutoRecovery.systemVpnAbsent());
  }

  // --- Lifecycle & State Predicates ---

  resetOnAppear(filesDir: string): void {
    this.homeReadOnlyRequestGuard.invalidate();
    this.vpnCommandStateMachine.invalidateLifecycle();
    this.lastConfirmedVpnStatus = '';
    this.lastConfirmedVpnHeartbeatMs = 0;
    this.vpnStatusGraceActive = false;
    this.vpnHeartbeatObservationStartedAtMs = Date.now();
    this.vpnHeartbeatBaselineMs = 0;
    this.vpnHeartbeatConfirmed = false;
    this.vpnAutoRecovery.restore(filesDir);
  }

  teardownOnDisappear(): void {
    this.cancelVpnAutoRecovery();
    this.homeReadOnlyRequestGuard.invalidate();
    this.vpnCommandStateMachine.invalidateLifecycle();
    this.stopConnectionPolling();
    this.clearConnectionCompletionTimer();
    this.stopBackendReadinessPolling();
    this.stopHealthPolling();
    this.stopLoginPolling();
    this.stopVpnStopPolling();
  }

  invalidateHomeReadGuard(): void {
    this.homeReadOnlyRequestGuard.invalidate();
  }

  setBackendRestartDeferred(deferred: boolean): void {
    this.backendRestartDeferred = deferred;
    if (this.host.setBackendRestartDeferred !== undefined) {
      this.host.setBackendRestartDeferred(deferred);
    }
  }

  isConnected(): boolean {
    return this.host.getVpnStatus().includes('state=Running');
  }

  isConnecting(): boolean {
    const status: string = this.host.getVpnStatus();
    return this.host.isConnectInProgress() ||
      status.includes('start requested') ||
      status.includes('authorization') ||
      status.includes('starting');
  }

  needsLogin(): boolean {
    const status: string = this.host.getBackendStatus();
    return status.includes('NeedsLogin') || status.includes('loginURLReady=true');
  }

  hasConnectionProblem(): boolean {
    return this.host.getVpnStatus().startsWith('FAILED') ||
      this.host.getBackendStatus().startsWith('FAILED');
  }

  isBackendLoading(): boolean {
    return this.host.isBackendInitializationVisible() &&
      !this.host.isBackendReady() && !this.hasConnectionProblem();
  }

  connectedHomeLayoutActive(): boolean {
    return this.isConnected() || this.host.isDisconnectInProgress() ||
      (this.isConnecting() && this.trafficSession > 0);
  }

  vpnOwnsBackendSnapshot(): boolean {
    // The UI engine is stopped during handoff. Its empty/NeedsLogin snapshot
    // must not replace the authenticated directory owned by the extension.
    return this.host.isControlServerSwitching() || this.host.isConnectInProgress() ||
      this.host.isDisconnectInProgress() || this.isConnecting() ||
      this.isConnected() || this.backendRestartDeferred;
  }

  backendNeedsStart(): boolean {
    const status: string = this.host.getBackendStatus();
    return !this.host.isBackendReady() || status.includes('Stopped') ||
      status.includes('not started') || status.startsWith('FAILED');
  }

  canSwitchControlServer(): boolean {
    return !this.host.isControlServerSwitching() && this.backendRestartPromise === undefined &&
      !this.backendRestartDeferred && !this.vpnFailedExtensionRecoveryInFlight &&
      !this.isConnected() && !this.isConnecting() &&
      !this.host.isDisconnectInProgress() && !this.host.isLoginInProgress() &&
      !this.host.isLogoutInProgress() && !this.host.isRouteAllUpdateInProgress() &&
      !this.host.isExitNodeUpdateInProgress() && !this.host.isExitNodeLanUpdateInProgress() &&
      !this.host.isTaildropSendActive() && !this.host.isTaildropReceiveInProgress() &&
      !this.host.isTaildropMediaSaveInProgress() &&
      !this.host.isCacheClearInProgress() && !this.host.isDiagnosticActionInProgress();
  }

  // --- Control Server & Account Profile Switching ---

  persistControlServer(normalized: string): void {
    if (!this.canSwitchControlServer()) {
      this.host.setControlServerStatus('disconnect');
      return;
    }
    this.host.setControlServerSwitching(true);
    const task: Promise<void> = this.switchControlServer(normalized);
    this.backendRestartPromise = task;
    task.finally(() => {
      if (this.backendRestartPromise === task) {
        this.backendRestartPromise = undefined;
      }
      this.host.setControlServerSwitching(false);
    });
  }

  async switchControlServer(normalized: string): Promise<void> {
    const generation: number = this.host.getLifecycleGeneration();
    let stopped: boolean = false;
    try {
      const filesDir: string = this.host.getFilesDir();
      const cacheDir: string = this.host.getCacheDir();
      const catalog: ControlServerPresetCatalog | undefined =
        ControlServerPresets.ensure(filesDir, normalized);
      if (catalog === undefined) {
        throw new Error('Preset save failed');
      }
      this.host.setControlServerPresets(catalog.servers);
      if (this.host.isControlServerConfirmed() && this.host.getControlServerURL() === normalized) {
        this.host.setControlServerEditorVisible(false);
        this.host.setControlServerStatus('saved');
        return;
      }
      this.cancelVpnAutoRecovery();
      this.homeReadOnlyRequestGuard.invalidate();
      this.host.invalidateAccountGuard();
      this.stopBackendReadinessPolling();
      const status: string = await this.vpnCommandGateway.stopBackend();
      if (!status.startsWith('OK')) {
        throw new Error('Previous backend stop failed');
      }
      stopped = true;
      if (generation !== this.host.getLifecycleGeneration()) {
        return;
      }
      // Prepare new paths before committing the selection. Old files stay untouched.
      const profiles: ServerAccountProfiles = AccountProfiles.ensure(filesDir, normalized);
      AccountProfiles.cacheRoot(filesDir, filesDir, normalized, profiles.activeId);
      AccountProfiles.cacheRoot(filesDir, cacheDir, normalized, profiles.activeId);
      const settings: ControlServerSettings | undefined =
        this.host.confirmControlServerSelection(normalized);
      if (settings === undefined) {
        throw new Error('Active server save failed');
      }
      this.host.setControlServerURL(settings.controlURL);
      this.host.setControlServerInput(settings.controlURL);
      this.host.setControlServerConfirmed(true);
      this.host.setAccountProfileId(profiles.activeId);
      this.host.setAccountProfiles(profiles.profiles);
      this.host.setAccountProfileStatus('');
      this.host.clearControlServerShellState();
      this.host.reloadTaildropStorageForActiveIdentity();
      this.host.setControlServerStatus('saved');
      this.host.setControlServerEditorVisible(false);
      this.startBackend(true, true);
      this.host.scheduleLifecycleTask(() => this.refreshBackendStatus(), 1500);
      this.host.recordDiagnosticEvent('control_server_confirmed',
        settings.controlURL === DEFAULT_CONTROL_SERVER_URL ? 'official' : 'custom');
    } catch (_error) {
      if (generation !== this.host.getLifecycleGeneration()) {
        return;
      }
      this.host.setControlServerStatus('failed');
      // Failed stop/save retains the old active server and its identity.
      if (stopped) {
        this.startBackend(false, true);
      }
      this.host.recordDiagnosticEvent('control_server_confirm_failed', 'switch');
    }
  }

  clearControlServerIpcFiles(filesDir: string): void {
    this.homeReadOnlyRequestGuard.invalidate();
    this.stopLoginPolling();
    this.cachedVpnConnectConfig = '';
    this.cachedVpnConnectConfigAtMs = 0;
    this.setBackendRestartDeferred(false);
    this.clearVpnBackendHandoffFiles(filesDir);
    this.vpnCommandGateway.writeCommandFile(filesDir, VPN_CONNECT_CONFIG_FILE_NAME, '');
    this.vpnCommandGateway.writeCommandFile(filesDir, VPN_PROBE_STATUS_FILE_NAME, 'HarmonyOS VPN Extension stopped');
    const staleFiles: string[] = [
      VPN_PEERS_FILE_NAME, TAILDROP_TARGETS_FILE_NAME,
      TAILDROP_RECEIVE_RESPONSE_FILE_NAME, TAILDROP_RECEIVE_REQUEST_FILE_NAME,
      TAILDROP_SEND_REQUEST_FILE_NAME, TAILDROP_CANCEL_REQUEST_FILE_NAME,
      TAILDRIVE_QUERY_REQUEST_FILE_NAME, TAILDRIVE_QUERY_RESPONSE_FILE_NAME,
      TAILDRIVE_TRANSFER_REQUEST_FILE_NAME, TAILDRIVE_TRANSFER_RESPONSE_FILE_NAME,
      TAILDRIVE_MANUAL_TRANSFER_REQUEST_FILE_NAME, TAILDRIVE_MANUAL_TRANSFER_RESPONSE_FILE_NAME,
      TAILDRIVE_CONTROL_REQUEST_FILE_NAME, TAILDRIVE_CONTROL_RESPONSE_FILE_NAME
    ];
    staleFiles.forEach((name: string) => this.vpnCommandGateway.writeCommandFile(filesDir, name, ''));
    this.peerSnapshotSignature = '';
    this.emptyPeerSnapshotSinceMs = 0;
  }

  persistAccountProfile(id: string, create: boolean = false): void {
    if (!this.canSwitchControlServer() || !this.host.isControlServerConfirmed() ||
      (!create && id === this.host.getAccountProfileId())) {
      return;
    }
    this.host.setControlServerSwitching(true);
    this.host.setAccountProfileStatus('');
    const task: Promise<void> = this.switchAccountProfile(id, create);
    this.backendRestartPromise = task;
    task.finally(() => {
      if (this.backendRestartPromise === task) {
        this.backendRestartPromise = undefined;
      }
      this.host.setControlServerSwitching(false);
    });
  }

  async switchAccountProfile(id: string, create: boolean): Promise<void> {
    const generation: number = this.host.getLifecycleGeneration();
    const serverURL: string = this.host.getControlServerURL();
    let stopped: boolean = false;
    try {
      const filesDir: string = this.host.getFilesDir();
      const cacheDir: string = this.host.getCacheDir();
      const target: string = create ? AccountProfiles.add(filesDir, serverURL) : id;
      const before: ServerAccountProfiles = AccountProfiles.current(filesDir, serverURL);
      this.host.setAccountProfiles(before.profiles);
      AccountProfiles.stateRoot(filesDir, serverURL, target);
      this.cancelVpnAutoRecovery();
      this.homeReadOnlyRequestGuard.invalidate();
      this.host.invalidateAccountGuard();
      this.stopBackendReadinessPolling();
      const status: string = await this.vpnCommandGateway.stopBackend();
      if (!status.startsWith('OK')) {
        throw new Error('Previous account stop failed');
      }
      stopped = true;
      if (generation !== this.host.getLifecycleGeneration()) {
        return;
      }
      AccountProfiles.cacheRoot(filesDir, filesDir, serverURL, target);
      AccountProfiles.cacheRoot(filesDir, cacheDir, serverURL, target);
      const selected: ServerAccountProfiles = AccountProfiles.select(filesDir, serverURL, target);
      this.host.setAccountProfileId(selected.activeId);
      this.host.setAccountProfiles(selected.profiles);
      this.host.clearControlServerShellState();
      this.host.reloadTaildropStorageForActiveIdentity();
      this.startBackend(true, true);
      this.host.setAccountProfileStatus(this.host.getBackendStatus().startsWith('FAILED') ? 'failed' : '');
      this.host.scheduleLifecycleTask(() => this.refreshBackendStatus(), 1500);
      this.host.recordDiagnosticEvent('account_profile_switched', create ? 'new' : 'existing');
    } catch (_error) {
      if (generation !== this.host.getLifecycleGeneration()) {
        return;
      }
      this.host.setAccountProfileStatus('failed');
      if (stopped) {
        this.startBackend(false, true);
      }
      this.host.recordDiagnosticEvent('account_profile_switch_failed', 'switch');
    }
  }

  stopWaitingForAccountLogin(): void {
    if (!this.host.isLoginInProgress() ||
      this.host.getLoginHandoffStatus() !== 'Secure login page opened') {
      return;
    }
    this.stopLoginPolling();
    this.homeReadOnlyRequestGuard.invalidate();
    this.finishSecureLogin(this.loginCommandId, 'Secure Login Pending');
  }

  // --- Backend Startup, Snapshot & Peer Directory ---

  startBackend(showInitialization: boolean = true, serverSwitchOwner: boolean = false): void {
    if (this.host.isControlServerSwitching() && !serverSwitchOwner) {
      return;
    }
    this.setBackendRestartDeferred(false);
    if (!this.host.isControlServerConfirmed()) {
      this.host.setBackendStatus('Tailscale Backend Stopped | control server not configured');
      this.host.setBackendReady(true);
      this.host.setBackendInitializationVisible(false);
      this.host.setDevicesLoading(false);
      return;
    }
    this.peerSnapshotSignature = '';
    this.host.setBackendReady(false);
    this.host.setBackendInitializationVisible(showInitialization);
    this.host.setDevicesLoading(true);
    try {
      const filesDir: string = this.host.getFilesDir();
      const controlUrl: string = this.host.getControlServerURL();
      const profileId: string = this.host.getAccountProfileId();
      this.host.recordDiagnosticEvent('backend_start_requested', showInitialization ? 'visible' : 'silent');
      const status: string = this.vpnCommandGateway.startBackend(
        AccountProfiles.stateRoot(filesDir, controlUrl, profileId),
        this.host.deviceModel(),
        this.host.harmonyOSHostinfoVersion(),
        controlUrl
      );
      this.host.setBackendStatus(status);
      this.startBackendReadinessPolling();
    } catch (error) {
      this.host.recordDiagnosticEvent('backend_start_failed', 'start');
      this.host.setBackendStatus(DiagnosticPrivacy.formatNativeFailure('Tailscale Backend Failed', error));
      this.host.setBackendReady(true);
      this.host.setBackendInitializationVisible(false);
      this.host.setDevicesLoading(false);
    }
  }

  async refreshBackendStatus(): Promise<void> {
    if (this.vpnOwnsBackendSnapshot()) {
      return;
    }
    if (!this.host.isControlServerConfirmed()) {
      this.host.setBackendStatus('Tailscale Backend Stopped | control server not configured');
      this.host.setBackendReady(true);
      this.host.setBackendInitializationVisible(false);
      this.host.setDevicesLoading(false);
      return;
    }
    if (this.refreshInFlight) {
      return;
    }
    const generation: number = this.host.getLifecycleGeneration();
    const homeReadGeneration: number = this.homeReadOnlyRequestGuard.begin();
    this.refreshInFlight = true;
    try {
      const snapshot: VpnBackendSnapshot =
        await this.homeReadOnlyGateway.readBackendSnapshot<VpnBackendSnapshot>();
      if (generation !== this.host.getLifecycleGeneration() ||
        !this.homeReadOnlyRequestGuard.isCurrent(homeReadGeneration) ||
        this.vpnOwnsBackendSnapshot()) {
        return;
      }
      this.host.setBackendStatus(snapshot.status);
      if (!this.isConnected()) {
        this.host.applyBackendTaildropSnapshot(snapshot.taildrop);
      }
      if (snapshot.status.includes('state=Running')) {
        if (this.host.getAuthKeyStatus() === 'needs_approval') {
          this.host.setAuthKeyStatus('authenticated');
        }
        this.host.setBackendReady(true);
        this.host.setBackendInitializationVisible(false);
        this.host.setDevicesLoading(false);
        this.host.setHasAuthenticatedSession(true);
        if (!this.host.isExitNodeUpdateInProgress()) {
          this.host.setExitNodes(snapshot.exitNodes);
        }
        this.applyPeers(snapshot.peers);
        if (!this.host.isRouteAllUpdateInProgress() && !this.host.isExitNodeLanUpdateInProgress()) {
          this.host.setNetworkSettings(snapshot.networkSettings);
        }
        this.applyAccountSummary(snapshot.account);
        this.completeSecureLoginAfterAuthentication();
      } else if (snapshot.account.needsApproval || snapshot.status.includes('NeedsMachineAuth')) {
        this.host.setBackendReady(true);
        this.host.setBackendInitializationVisible(false);
        this.host.setDevicesLoading(false);
        this.host.setHasAuthenticatedSession(true);
        this.host.setExitNodes([]);
        this.applyPeers([]);
        this.applyAccountSummary(snapshot.account);
        this.completeSecureLoginAfterAuthentication();
      } else if (this.needsLogin()) {
        this.host.setBackendReady(true);
        this.host.setBackendInitializationVisible(false);
        this.host.setDevicesLoading(false);
        this.host.setHasAuthenticatedSession(false);
        this.clearCachedPeerDirectory();
        this.applyPeers([]);
        this.host.setExitNodes([]);
        this.applyAccountSummary(snapshot.account);
      } else if (snapshot.status.startsWith('FAILED')) {
        this.host.setBackendReady(true);
        this.host.setBackendInitializationVisible(false);
        this.host.setDevicesLoading(false);
      }
    } catch (error) {
      if (generation !== this.host.getLifecycleGeneration() ||
        !this.homeReadOnlyRequestGuard.isCurrent(homeReadGeneration) ||
        this.vpnOwnsBackendSnapshot()) {
        return;
      }
      this.host.setBackendStatus(DiagnosticPrivacy.formatNativeFailure('Tailscale Backend Failed', error));
      this.host.setBackendReady(true);
      this.host.setBackendInitializationVisible(false);
      this.host.setDevicesLoading(false);
    } finally {
      this.refreshInFlight = false;
    }
  }

  applyAccountSummary(account: AccountSummary): void {
    const normalizedSummary: AccountSummary = {
      displayName: account.displayName,
      loginName: account.loginName,
      profilePicURL: account.profilePicURL,
      tailnetName: account.tailnetName,
      deviceName: DeviceNameService.withoutHuaweiBrand(
        account.deviceName.length > 0 ? account.deviceName : this.host.deviceModel()),
      addresses: account.addresses,
      needsApproval: account.needsApproval,
      keyExpired: account.keyExpired,
      keyExpiryUnixMs: account.keyExpiryUnixMs
    };
    this.host.setAccountSummary(normalizedSummary);
    this.host.setAvatarLoadFailed(false);
    if (account.loginName.length > 0 && !this.host.isControlServerSwitching()) {
      try {
        const state: ServerAccountProfiles = AccountProfiles.setLabel(
          this.host.getFilesDir(),
          this.host.getControlServerURL(),
          this.host.getAccountProfileId(),
          account.loginName
        );
        if (JSON.stringify(this.host.getAccountProfiles()) !== JSON.stringify(state.profiles)) {
          this.host.setAccountProfiles(state.profiles);
        }
      } catch (_error) {
        // Display metadata failure must not invalidate a signed-in account.
      }
    }
  }

  mergePeers(peers: PeerSummary[]): PeerSummary[] {
    const existing: PeerSummary[] = this.host.getPeers();
    return peers.map((peer: PeerSummary) =>
      mergePeerWithLocalSend(peer, existing.find((current: PeerSummary) => current.key === peer.key)));
  }

  applyPeers(peers: PeerSummary[]): void {
    const existingPeers: PeerSummary[] = this.host.getPeers();
    if (peers.length === 0 && existingPeers.length > 0 &&
      (this.host.isConnectInProgress() || this.host.isDisconnectInProgress() || this.isConnecting())) {
      return;
    }
    if (peers.length === 0 && existingPeers.length > 0 &&
      this.host.hasAuthenticatedSession() && this.isConnected()) {
      const now: number = Date.now();
      if (this.emptyPeerSnapshotSinceMs <= 0 || now < this.emptyPeerSnapshotSinceMs) {
        this.emptyPeerSnapshotSinceMs = now;
      }
      if (now - this.emptyPeerSnapshotSinceMs < 5000) {
        return;
      }
    } else {
      this.emptyPeerSnapshotSinceMs = 0;
    }
    const mergedPeers: PeerSummary[] = this.mergePeers(peers);
    existingPeers.forEach((previous: PeerSummary) => {
      const current: PeerSummary | undefined =
        mergedPeers.find((peer: PeerSummary) => peer.key === previous.key);
      if (current !== undefined && current.online === previous.online) {
        return;
      }
      this.host.onPeerPresenceInvalidated(previous.key);
    });
    this.host.onPeersUpdated(mergedPeers);
    if (this.isConnected()) {
      this.host.scheduleLifecycleTask(() => this.host.autoProbeConnectedPeerServices(), 50);
    }
  }

  clearCachedPeerDirectory(): void {
    try {
      this.vpnCommandGateway.writeCommandFile(this.host.getFilesDir(), VPN_PEERS_FILE_NAME, '');
    } catch (_error) {}
  }

  refreshPeerSnapshot(allowCachedDirectory: boolean = false): void {
    const connected: boolean = this.isConnected();
    if (!connected && !allowCachedDirectory) {
      return;
    }
    try {
      const path: string = `${this.host.getFilesDir()}/${VPN_PEERS_FILE_NAME}`;
      if (!fileIo.accessSync(path)) {
        return;
      }
      const snapshot: PersistedPeerSnapshot = JSON.parse(
        fileIo.readTextSync(path)) as PersistedPeerSnapshot;
      if (snapshot === null || typeof snapshot !== 'object' || Array.isArray(snapshot) ||
        !Array.isArray(snapshot.peers) || typeof snapshot.updatedAtMs !== 'number' ||
        !Number.isFinite(snapshot.updatedAtMs)) {
        return;
      }
      const ageMs: number = Date.now() - snapshot.updatedAtMs;
      if (snapshot.updatedAtMs <= 0 || ageMs < 0 || (connected && ageMs > 5000)) {
        return;
      }
      const validPeers: PeerSummary[] = snapshot.peers.filter(
        (peer: PeerSummary) => peer !== null && typeof peer === 'object' &&
          typeof peer.key === 'string' && typeof peer.name === 'string' &&
          /^peer-[a-f0-9]{16}$/.test(peer.key) && peer.name.length > 0);
      if (!connected) {
        validPeers.forEach((peer: PeerSummary): void => {
          peer.online = false;
          const offlineStatus: LocalSendStatus = { state: 'offline' };
          peer.localSend = offlineStatus;
        });
      }
      const receiver: MeshArcReceiverStatus = snapshot.meshArcReceiver ?? emptyMeshArcReceiverStatus();
      const normalizedReceiver: MeshArcReceiverStatus = {
        state: sanitizeVpnDiagnosticToken(receiver.state, 'unknown'),
        protocol: sanitizeVpnDiagnosticToken(receiver.protocol ?? '', 'unknown'),
        httpStatus: Number.isFinite(receiver.httpStatus) ? receiver.httpStatus : 0,
        sent: sanitizeVpnDiagnosticCount(receiver.sent),
        registered: sanitizeVpnDiagnosticCount(receiver.registered),
        checkedAtMs: sanitizeVpnDiagnosticCount(receiver.checkedAtMs ?? 0)
      };
      const signature: string = `${connected}|${JSON.stringify(validPeers)}|${JSON.stringify(normalizedReceiver)}|${JSON.stringify(snapshot.account)}`;
      if (signature === this.peerSnapshotSignature) {
        if (validPeers.length > 0) {
          this.emptyPeerSnapshotSinceMs = 0;
        }
        this.host.logServiceStatusIfChanged();
        return;
      }
      if (snapshot.account !== undefined && snapshot.account.loginName.length > 0) {
        this.applyAccountSummary(snapshot.account);
        this.host.setHasAuthenticatedSession(true);
      }
      this.host.setMeshArcReceiver(normalizedReceiver);
      this.applyPeers(validPeers);
      if (validPeers.length > 0 || this.host.getPeers().length === 0) {
        this.peerSnapshotSignature = signature;
      }
      this.host.syncOfflinePeerStatusRefreshPolling();
      this.host.setDevicesLoading(false);
      this.host.logServiceStatusIfChanged();
    } catch (_error) {
      // The Extension may be replacing the snapshot file. Retry on the next poll.
    }
  }

  // --- Probe Status, Watcher, Handoff & Auto-Recovery ---

  refreshVpnProbeStatus(): boolean {
    try {
      const filesDir: string = this.host.getFilesDir();
      const statusPath: string = `${filesDir}/${VPN_PROBE_STATUS_FILE_NAME}`;
      if (!fileIo.accessSync(statusPath)) {
        if (this.preserveConfirmedVpnStatus('', 0)) {
          return true;
        }
        if (this.isConnected()) {
          this.host.resetTaildropSnapshot();
        }
        this.host.setVpnStatus('HarmonyOS VPN Extension Stopped');
        return false;
      }
      const persistedStatus: string = fileIo.readTextSync(statusPath).trim();
      const heartbeatMatch: RegExpMatchArray | null = persistedStatus.match(/heartbeatMs=(\d+)/);
      const heartbeatMs: number = heartbeatMatch === null ? 0 : Number(heartbeatMatch[1]);
      const heartbeatAgeMs: number = Date.now() - heartbeatMs;
      const heartbeatIsFresh: boolean = heartbeatMs > 0 && heartbeatAgeMs >= 0 &&
        heartbeatAgeMs <= VPN_HEARTBEAT_FRESH_MS;
      const visibleStatus: string = persistedStatus.replace(/\s*\|\s*heartbeatMs=\d+/, '');
      this.processVpnBackendHandoffRequest(filesDir, visibleStatus, heartbeatIsFresh);
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
          this.host.setVpnStatus('HarmonyOS VPN Extension starting verification');
          return true;
        } else {
          extensionIsLive = false;
        }
      }
      if (extensionIsLive && visibleStatus.includes('state=Running') &&
        visibleStatus.includes('tun=true')) {
        if (this.vpnStatusGraceActive) {
          this.host.recordDiagnosticEvent('vpn_status_grace_recovered', 'heartbeat');
          this.vpnStatusGraceActive = false;
        }
        if (this.vpnAutoRecovery.connected(heartbeatMs, Date.now())) {
          this.vpnAutoRecovery.save(filesDir);
        }
        this.lastConfirmedVpnStatus = visibleStatus;
        this.lastConfirmedVpnHeartbeatMs = heartbeatMs;
      } else if (this.preserveConfirmedVpnStatus(visibleStatus, heartbeatMs)) {
        return true;
      }
      if (extensionIsLive) {
        this.updateTrafficMetrics(visibleStatus, heartbeatMs);
        this.host.onLiveExtensionTick();
      } else {
        this.resetTrafficMetrics();
        if (this.isConnected()) {
          this.host.resetTaildropSnapshot();
        }
        this.host.resetStreamingStatesForDisconnect();
      }
      const shouldPromptVpnConflict: boolean = extensionIsLive && this.host.isConnectInProgress() &&
        visibleStatus.includes('code=2203002');
      const shouldRecoverFailedExtension: boolean = extensionIsLive && !shouldPromptVpnConflict &&
        this.host.isControlServerConfirmed() && visibleStatus.startsWith('FAILED');
      if (extensionIsLive && visibleStatus.includes('state=Running') && this.host.isConnectInProgress()) {
        const remainingMs: number = MIN_CONNECTION_LOADING_MS -
          (Date.now() - this.connectionStartedAtMs);
        if (remainingMs > 0) {
          if (this.connectionCompletionTimer < 0) {
            const commandId: number = this.connectCommandId;
            this.connectionCompletionTimer = setTimeout(() => {
              if (!this.vpnCommandStateMachine.isActive(commandId)) {
                return;
              }
              this.commitConnectedStatus(visibleStatus);
            }, remainingMs);
          }
          return extensionIsLive;
        }
        this.commitConnectedStatus(visibleStatus);
        return extensionIsLive;
      }
      this.host.setVpnStatus(!extensionIsLive && visibleStatus.includes('tun=true') ?
        'HarmonyOS VPN Extension Stopped (previous session ended)' : visibleStatus);
      this.host.syncHomeTitleCompact(this.connectedHomeLayoutActive());
      if (!visibleStatus.includes('state=Running')) {
        this.host.resetStreamingStatesForDisconnect();
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
      if (this.isConnected()) {
        this.host.resetTaildropSnapshot();
      }
      const businessError: BusinessError = error as BusinessError;
      this.host.setVpnStatus(`FAILED | VPN status file | code=${businessError.code}`);
      return false;
    }
  }

  clearVpnBackendHandoffFiles(filesDir?: string): void {
    const dir: string = filesDir ?? this.host.getFilesDir();
    this.vpnCommandGateway.writeCommandFile(dir, VPN_BACKEND_HANDOFF_REQUEST_FILE_NAME, '');
    this.vpnCommandGateway.writeCommandFile(dir, VPN_BACKEND_HANDOFF_RESPONSE_FILE_NAME, '');
  }

  processVpnBackendHandoffRequest(
    filesDir: string,
    visibleStatus: string,
    heartbeatIsFresh: boolean = true
  ): void {
    if (!heartbeatIsFresh || this.host.isDisconnectInProgress() || this.host.isLogoutInProgress() ||
      this.host.isControlServerSwitching() || this.vpnBackendHandoffInFlight ||
      !visibleStatus.includes('backend handoff pending')) {
      return;
    }
    try {
      const requestText: string | undefined = this.vpnCommandGateway.readCommandFile(
        filesDir,
        VPN_BACKEND_HANDOFF_REQUEST_FILE_NAME
      );
      if (requestText === undefined || requestText.trim().length === 0) {
        return;
      }
      this.vpnCommandGateway.writeCommandFile(filesDir, VPN_BACKEND_HANDOFF_REQUEST_FILE_NAME, '');
      const request: VpnBackendHandoffRequest = JSON.parse(requestText) as VpnBackendHandoffRequest;
      if (request.requestId <= 0) {
        return;
      }
      const generation: number = this.host.getLifecycleGeneration();
      this.vpnBackendHandoffInFlight = true;
      this.vpnCommandGateway.stopBackend()
        .then((status: string) => {
          if (generation !== this.host.getLifecycleGeneration()) {
            return;
          }
          this.host.setBackendStatus(status);
          this.host.recordDiagnosticEvent(status.startsWith('OK') ?
            'vpn_backend_handoff_stopped' : 'vpn_backend_handoff_stop_failed', 'vpn_handoff');
          const response: VpnBackendHandoffResponse = { requestId: request.requestId, status: status };
          this.vpnCommandGateway.writeCommandFile(
            filesDir,
            VPN_BACKEND_HANDOFF_RESPONSE_FILE_NAME,
            JSON.stringify(response)
          );
        })
        .catch(() => {
          if (generation !== this.host.getLifecycleGeneration()) {
            return;
          }
          const response: VpnBackendHandoffResponse = {
            requestId: request.requestId,
            status: 'FAILED | backend handoff | stop unavailable'
          };
          this.vpnCommandGateway.writeCommandFile(
            filesDir,
            VPN_BACKEND_HANDOFF_RESPONSE_FILE_NAME,
            JSON.stringify(response)
          );
          this.host.recordDiagnosticEvent('vpn_backend_handoff_stop_failed', 'vpn_handoff');
        })
        .finally(() => {
          this.vpnBackendHandoffInFlight = false;
        });
    } catch (_error) {
      this.vpnCommandGateway.writeCommandFile(filesDir, VPN_BACKEND_HANDOFF_REQUEST_FILE_NAME, '');
    }
  }

  recoverFailedVpnExtension(failedStatus: string): void {
    if (this.vpnFailedExtensionRecoveryInFlight || this.host.isDisconnectInProgress() ||
      this.host.isVpnConflictDialogVisible()) {
      return;
    }
    this.vpnCommandStateMachine.complete(this.connectCommandId, VpnCommandState.STOPPED);
    this.vpnFailedExtensionRecoveryInFlight = true;
    this.clearVpnBackendHandoffFiles();
    this.host.recordDiagnosticEvent('vpn_failed_extension_stop_requested', 'recovery');
    const generation: number = this.vpnCommandStateMachine.currentLifecycleGeneration();
    this.vpnCommandGateway.stopVpnExtension(this.vpnWant())
      .then(() => {
        if (generation !== this.vpnCommandStateMachine.currentLifecycleGeneration()) {
          return;
        }
        this.host.recordDiagnosticEvent('vpn_failed_extension_stopped', 'recovery');
        this.host.setVpnStatus(failedStatus);
        this.startBackend(false);
        this.host.scheduleLifecycleTask(() => this.refreshBackendStatus(), 1500);
      })
      .catch((error: BusinessError) => {
        if (generation !== this.vpnCommandStateMachine.currentLifecycleGeneration()) {
          return;
        }
        this.host.recordDiagnosticEvent('vpn_failed_extension_stop_failed', 'recovery', error.code);
      })
      .finally(() => {
        this.vpnFailedExtensionRecoveryInFlight = false;
      });
  }

  preserveConfirmedVpnStatus(status: string, heartbeatMs: number): boolean {
    if (status.startsWith('VPN DNS restarting')) {
      return false;
    }
    if (this.host.isDisconnectInProgress() || this.lastConfirmedVpnStatus.length === 0 ||
      this.lastConfirmedVpnHeartbeatMs <= 0) {
      return false;
    }
    const confirmedAgeMs: number = Date.now() - this.lastConfirmedVpnHeartbeatMs;
    if (confirmedAgeMs < 0 || confirmedAgeMs > VPN_CONNECTED_GRACE_MS) {
      if (this.vpnStatusGraceActive) {
        this.host.recordDiagnosticEvent('vpn_status_grace_expired', 'heartbeat');
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
      this.host.recordDiagnosticEvent('vpn_status_grace_started',
        liveTunTransition ? 'tun_transition' : 'heartbeat');
    }
    this.host.setVpnStatus(this.lastConfirmedVpnStatus);
    return true;
  }

  startConnectionPolling(): void {
    this.stopConnectionPolling();
    const statusPath: string = `${this.host.getFilesDir()}/${VPN_PROBE_STATUS_FILE_NAME}`;
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

  handleConnectionStatusUpdate(): void {
    this.refreshVpnProbeStatus();
    const status: string = this.host.getVpnStatus();
    if (status.includes('state=Running') || status.startsWith('FAILED')) {
      this.stopConnectionPolling();
    }
  }

  stopConnectionPolling(): void {
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

  clearConnectionCompletionTimer(): void {
    if (this.connectionCompletionTimer >= 0) {
      clearTimeout(this.connectionCompletionTimer);
      this.connectionCompletionTimer = -1;
    }
  }

  commitConnectedStatus(status: string): void {
    this.vpnAutoRecoveryCommandId = 0;
    this.vpnAutoRecovery.stopObservingAuthorization();
    this.clearConnectionCompletionTimer();
    this.host.setVpnStatus(status);
    this.setConnectInProgress(false);
    this.vpnCommandStateMachine.complete(this.connectCommandId, VpnCommandState.RUNNING);
    this.host.setHomeTitleCompact(true);
    this.host.scheduleLifecycleTask(() => this.host.autoProbeConnectedPeerServices(), 50);
    this.stopConnectionPolling();
  }

  startHealthPolling(): void {
    this.stopHealthPolling();
    this.scheduleHealthPoll(this.host.getLifecycleGeneration());
  }

  scheduleHealthPoll(generation: number): void {
    this.healthPollTimer = setTimeout(() => {
      if (generation !== this.host.getLifecycleGeneration()) {
        return;
      }
      const vpnIsLive: boolean = this.refreshVpnProbeStatus();
      if (!vpnIsLive && this.vpnAutoRecoveryCommandId > 0 &&
        this.vpnCommandStateMachine.isActive(this.vpnAutoRecoveryCommandId) &&
        Date.now() - this.vpnAutoRecoveryStartedAtMs > 90000) {
        this.vpnCommandStateMachine.timeout(this.vpnAutoRecoveryCommandId);
        this.cancelVpnAutoRecovery();
        this.setConnectInProgress(false);
        this.clearConnectionCompletionTimer();
        this.host.recordDiagnosticEvent('vpn_auto_reconnect_timeout', 'recovery');
      }
      const refresh: Promise<void> = vpnIsLive ? Promise.resolve() : this.refreshOrRecoverBackend(generation);
      refresh.finally(() => {
        if (generation === this.host.getLifecycleGeneration()) {
          this.scheduleHealthPoll(generation);
        }
      });
    }, this.host.shouldPollHealthFast() ? 120 : 1000);
  }

  stopHealthPolling(): void {
    if (this.healthPollTimer >= 0) {
      clearTimeout(this.healthPollTimer);
      this.healthPollTimer = -1;
    }
  }

  async refreshOrRecoverBackend(generation: number): Promise<void> {
    if (this.host.isControlServerSwitching()) {
      return;
    }
    if (this.host.isConnectInProgress() || this.host.isDisconnectInProgress() ||
      this.backendRestartDeferred || this.vpnFailedExtensionRecoveryInFlight ||
      this.vpnBackendHandoffInFlight || this.refreshVpnProbeStatus()) {
      return;
    }
    if (await this.maybeAutoReconnectVpn(generation)) {
      return;
    }
    await this.refreshBackendStatus();
    if (generation !== this.host.getLifecycleGeneration() || !this.host.isControlServerConfirmed() ||
      this.host.isConnectInProgress() || this.host.isDisconnectInProgress() ||
      this.backendRestartDeferred || this.vpnFailedExtensionRecoveryInFlight ||
      this.vpnBackendHandoffInFlight || this.refreshVpnProbeStatus() ||
      !this.host.getBackendStatus().startsWith('STOPPED')) {
      return;
    }
    this.host.recordDiagnosticEvent('backend_recovery_requested', 'vpn_process_lost');
    this.startBackend(false);
  }

  cancelVpnAutoRecovery(): void {
    this.vpnCommandStateMachine.complete(this.connectCommandId, VpnCommandState.STOPPED);
    this.vpnAutoRecovery.cancel();
    this.vpnAutoRecoveryCommandId = 0;
    this.cachedVpnConnectConfig = '';
    this.cachedVpnConnectConfigAtMs = 0;
    try {
      this.vpnAutoRecovery.save(this.host.getFilesDir());
    } catch (_error) {}
  }

  async maybeAutoReconnectVpn(generation: number): Promise<boolean> {
    if (!this.vpnAutoRecovery.wanted()) {
      return false;
    }
    if (!this.vpnAutoRecovery.armed()) {
      this.cancelVpnAutoRecovery();
      return false;
    }
    if (this.vpnAutoRecoveryInFlight || !this.host.isAppShellReady() ||
      !this.host.hasAuthenticatedSession() || this.host.isConnectInProgress() ||
      this.host.isDisconnectInProgress() || this.host.isLoginInProgress() ||
      this.host.isLogoutInProgress() || this.host.isDiagnosticActionInProgress() ||
      this.vpnFailedExtensionRecoveryInFlight) {
      return true;
    }
    const token: number = this.vpnAutoRecovery.token();
    this.vpnAutoRecoveryInFlight = true;
    try {
      const absent: boolean = await this.systemVpnAbsentFn();
      if (generation !== this.host.getLifecycleGeneration() || !this.host.isAppShellReady() ||
        !this.vpnAutoRecovery.current(token) || !this.host.isControlServerConfirmed() ||
        this.host.isConnectInProgress() || this.host.isDisconnectInProgress() ||
        this.refreshVpnProbeStatus()) {
        return true;
      }
      if (this.vpnAutoRecovery.takeAttempt(this.lastConfirmedVpnHeartbeatMs, absent, Date.now())) {
        this.host.recordDiagnosticEvent('vpn_auto_reconnect_requested', 'recovery');
        this.beginVpnConnection(true);
      }
    } finally {
      this.vpnAutoRecoveryInFlight = false;
    }
    return true;
  }

  // --- Connect, Fast-Reconnect, Disconnect & Conflict ---

  vpnWant(): Want {
    const want: Want = {
      bundleName: 'io.github.tailscaleohos',
      abilityName: 'TailscaleVpnExtensionAbility'
    };
    return want;
  }

  async stopVpnExtensionDirect(): Promise<void> {
    await this.vpnCommandGateway.stopVpnExtension(this.vpnWant());
  }

  async stopBackendDirect(): Promise<string> {
    return await this.vpnCommandGateway.stopBackend();
  }

  stageVpnConnectConfig(config: string): boolean {
    const staged: boolean = this.vpnCommandGateway.stageConnectConfig(
      this.host.getFilesDir(),
      VPN_CONNECT_CONFIG_FILE_NAME,
      config
    );
    if (staged && config.length > 0 && !config.startsWith('FAILED')) {
      this.cachedVpnConnectConfig = config;
      this.cachedVpnConnectConfigAtMs = Date.now();
    }
    return staged;
  }

  cacheVpnReconnectConfig(): boolean {
    try {
      const handoff: VpnConnectConfigHandoff | undefined = this.vpnCommandGateway.readConnectConfig(
        this.host.getFilesDir(),
        VPN_CONNECT_CONFIG_FILE_NAME
      );
      if (handoff === undefined) {
        return false;
      }
      const ageMs: number = Date.now() - handoff.createdAtMs;
      if (handoff.createdAtMs <= 0 || ageMs < 0 || ageMs > FAST_RECONNECT_TTL_MS ||
        handoff.config.length === 0 || handoff.config.length > 8192 ||
        handoff.config.startsWith('FAILED')) {
        return false;
      }
      this.cachedVpnConnectConfig = handoff.config;
      this.cachedVpnConnectConfigAtMs = handoff.createdAtMs;
      return true;
    } catch (_error) {
      return false;
    }
  }

  tryFastReconnect(commandId: number): boolean {
    const ageMs: number = Date.now() - this.cachedVpnConnectConfigAtMs;
    if (this.backendRestartDeferred && this.cachedVpnConnectConfig.length > 0 &&
      ageMs >= 0 && ageMs <= FAST_RECONNECT_TTL_MS) {
      if (!this.stageVpnConnectConfig(this.cachedVpnConnectConfig)) {
        this.host.recordDiagnosticEvent('fast_reconnect_failed', 'persistence');
        return false;
      }
      this.setBackendRestartDeferred(false);
      this.host.recordDiagnosticEvent('fast_reconnect_used', 'cached_config');
      this.requestVpnExtensionStart(commandId);
      return true;
    }
    if (this.vpnAutoRecoveryCommandId === commandId && commandId > 0 &&
      !this.vpnBackendWasRunningBeforeConnect && this.host.hasAuthenticatedSession() &&
      this.host.isControlServerConfirmed()) {
      if (this.cachedVpnConnectConfig.length > 0 &&
        !this.cachedVpnConnectConfig.startsWith('FAILED')) {
        this.stageVpnConnectConfig(this.cachedVpnConnectConfig);
      }
      this.host.recordDiagnosticEvent('fast_reconnect_used', 'auto_recovery');
      this.requestVpnExtensionStart(commandId);
      return true;
    }
    return false;
  }

  deferBackendRestart(): boolean {
    if (!this.cacheVpnReconnectConfig()) {
      return false;
    }
    this.setBackendRestartDeferred(true);
    this.host.setBackendReady(true);
    this.host.setBackendInitializationVisible(false);
    this.host.setDevicesLoading(false);
    this.host.recordDiagnosticEvent('backend_restart_deferred', 'fast_reconnect_window');
    this.host.scheduleLifecycleTask(() => {
      if (!this.backendRestartDeferred || this.isConnected() || this.isConnecting() ||
        this.host.isDisconnectInProgress()) {
        return;
      }
      this.setBackendRestartDeferred(false);
      this.host.recordDiagnosticEvent('backend_restart_deferred_completed', 'timeout');
      this.startBackend(false);
    }, FAST_RECONNECT_TTL_MS);
    return true;
  }

  startBackendReadinessPolling(): void {
    this.stopBackendReadinessPolling();
    this.scheduleBackendReadinessPoll(this.host.getLifecycleGeneration(), 0);
  }

  scheduleBackendReadinessPoll(generation: number, delayMs: number): void {
    this.backendReadinessPollTimer = setTimeout(() => {
      if (generation !== this.host.getLifecycleGeneration() || this.isConnected()) {
        return;
      }
      this.refreshBackendStatus().finally(() => {
        const status: string = this.host.getBackendStatus();
        if (generation !== this.host.getLifecycleGeneration() || this.host.isBackendReady() ||
          status.startsWith('FAILED') || status.startsWith('STOPPED')) {
          this.stopBackendReadinessPolling();
          return;
        }
        this.scheduleBackendReadinessPoll(generation, BACKEND_READINESS_POLL_INTERVAL_MS);
      });
    }, delayMs);
  }

  stopBackendReadinessPolling(): void {
    if (this.backendReadinessPollTimer >= 0) {
      clearTimeout(this.backendReadinessPollTimer);
      this.backendReadinessPollTimer = -1;
    }
  }

  setConnectInProgress(inProgress: boolean): void {
    if (inProgress) {
      this.homeReadOnlyRequestGuard.invalidate();
    }
    this.host.setConnectInProgressState(inProgress);
  }

  beginVpnConnection(automatic: boolean = false): void {
    if (!this.host.isControlServerConfirmed()) {
      this.host.openControlServerSettings();
      return;
    }
    if (this.host.isConnectInProgress() || this.host.isDisconnectInProgress() || this.isConnecting()) {
      return;
    }
    this.connectCommandId = this.vpnCommandStateMachine.begin(VpnCoreCommand.CONNECT);
    if (this.connectCommandId === 0) {
      return;
    }
    if (!automatic) {
      this.vpnAutoRecovery.request(Date.now());
      if (!this.vpnAutoRecovery.save(this.host.getFilesDir())) {
        this.vpnAutoRecovery.cancel();
        this.vpnCommandStateMachine.complete(this.connectCommandId, VpnCommandState.STOPPED);
        this.host.setVpnStatus('FAILED | VPN intent | persistence unavailable');
        return;
      }
      this.vpnAutoRecoveryCommandId = 0;
    } else {
      this.vpnAutoRecoveryCommandId = this.connectCommandId;
      this.vpnAutoRecoveryStartedAtMs = Date.now();
    }
    this.setConnectInProgress(true);
    void this.beginVpnConnectionAfterExitNodeUpdate();
  }

  async beginVpnConnectionAfterExitNodeUpdate(): Promise<void> {
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
    if (!this.host.isConnectInProgress() || !this.host.isControlServerConfirmed() ||
      !this.vpnCommandStateMachine.isActive(commandId)) {
      return;
    }
    if (this.host.isExitNodeStatusFailed()) {
      this.setConnectInProgress(false);
      return;
    }
    this.clearConnectionCompletionTimer();
    this.connectionStartedAtMs = Date.now();
    try {
      const status: string = await this.vpnCommandGateway.backendStatusAsync();
      if (!this.vpnCommandStateMachine.isActive(commandId)) {
        return;
      }
      this.vpnBackendWasRunningBeforeConnect = status.includes('state=Running');
    } catch (_error) {
      this.vpnBackendWasRunningBeforeConnect = this.host.getBackendStatus().includes('state=Running');
    }
    if (!this.vpnCommandStateMachine.isActive(commandId)) {
      return;
    }
    this.host.recordDiagnosticEvent('connect_requested', 'preflight');
    this.host.scheduleLifecycleTask(() => this.startVpnProbe(commandId), CONNECTION_START_FRAME_DELAY_MS);
  }

  async startVpnProbe(commandId: number): Promise<void> {
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
        this.host.recordDiagnosticEvent('vpn_preflight_failed', 'backend_config');
        this.cancelVpnAutoRecovery();
        this.host.setVpnStatus('Sign in to Tailscale before connecting');
        this.clearConnectionCompletionTimer();
        this.setConnectInProgress(false);
        this.vpnCommandStateMachine.complete(commandId, VpnCommandState.NEEDS_LOGIN);
        return;
      }
      if (this.stageVpnConnectConfig(backendConfig)) {
        this.host.recordDiagnosticEvent('vpn_config_handoff_staged', 'preflight');
      } else {
        this.host.recordDiagnosticEvent('vpn_config_handoff_failed', 'persistence');
        this.host.setVpnStatus('FAILED | VPN preflight | config handoff unavailable');
        this.clearConnectionCompletionTimer();
        this.setConnectInProgress(false);
        this.vpnCommandStateMachine.complete(commandId, VpnCommandState.STOPPED);
        return;
      }
      this.requestVpnExtensionStart(commandId);
    } catch (_error) {
      if (!this.vpnCommandStateMachine.isActive(commandId)) {
        return;
      }
      this.host.recordDiagnosticEvent('vpn_preflight_failed', 'exception');
      this.host.setVpnStatus('FAILED | VPN preflight | backend unavailable');
      this.clearConnectionCompletionTimer();
      this.setConnectInProgress(false);
      this.vpnCommandStateMachine.complete(commandId, VpnCommandState.STOPPED);
    }
  }

  async backendVpnConfigWithRecovery(commandId: number): Promise<string> {
    let backendConfig: string = await this.vpnCommandGateway.requestVpnConfig();
    if (!backendConfig.startsWith('FAILED')) {
      return backendConfig;
    }
    this.host.recordDiagnosticEvent('backend_recovery_requested', 'connect_preflight');
    this.startBackend(false);
    for (let attempt: number = 0; attempt < 20; attempt++) {
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 500));
      if (!this.host.isConnectInProgress() || !this.host.isControlServerConfirmed() ||
        !this.vpnCommandStateMachine.isActive(commandId)) {
        return backendConfig;
      }
      backendConfig = await this.vpnCommandGateway.requestVpnConfig();
      if (!backendConfig.startsWith('FAILED')) {
        this.host.recordDiagnosticEvent('backend_recovery_completed', 'connect_preflight');
        return backendConfig;
      }
    }
    this.host.recordDiagnosticEvent('backend_recovery_failed', 'connect_preflight');
    return backendConfig;
  }

  requestVpnExtensionStart(commandId: number): void {
    this.vpnAutoRecovery.watchAuthorization(() => {
      if (!this.vpnCommandStateMachine.isActive(commandId)) {
        return;
      }
      this.cancelVpnAutoRecovery();
      this.vpnCommandStateMachine.complete(commandId, VpnCommandState.STOPPED);
      this.setConnectInProgress(false);
      this.host.setVpnStatus('FAILED | VPN authorization declined');
      this.host.recordDiagnosticEvent('vpn_authorization_declined', 'system');
    });
    this.clearVpnBackendHandoffFiles();
    this.host.setVpnStatus('Requesting HarmonyOS VPN authorization');
    const want: Want = this.vpnWant();
    const params: Record<string, Object> = { 'mesharcIntentMs': this.vpnAutoRecovery.token() };
    want.parameters = params;
    this.vpnCommandGateway.startVpnExtension(want)
      .then(() => {
        if (!this.vpnCommandStateMachine.isActive(commandId)) {
          return;
        }
        this.host.recordDiagnosticEvent('vpn_start_requested', 'system');
        this.host.setVpnStatus('HarmonyOS VPN Extension start requested');
        this.startConnectionPolling();
      })
      .catch((error: BusinessError) => {
        if (!this.vpnCommandStateMachine.isActive(commandId)) {
          return;
        }
        if (error.code === 201 || error.code === 2203001 ||
          this.vpnAutoRecoveryCommandId !== commandId) {
          this.cancelVpnAutoRecovery();
        }
        this.host.recordDiagnosticEvent('vpn_start_failed', 'system', error.code);
        this.host.setVpnStatus(`FAILED | VPN start | code=${error.code}`);
        this.clearConnectionCompletionTimer();
        this.setConnectInProgress(false);
        this.vpnCommandStateMachine.complete(commandId, VpnCommandState.STOPPED);
      });
  }

  stopVpnProbe(): void {
    this.cancelVpnAutoRecovery();
    if (this.host.isDisconnectInProgress()) {
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
    this.host.setDisconnectInProgress(true);
    this.host.recordDiagnosticEvent('disconnect_requested', 'user');
    this.stopVpnStopPolling();
    this.vpnStopRequestId = Date.now();
    const filesDir: string = this.host.getFilesDir();
    this.vpnCommandGateway.writeCommandFile(filesDir, VPN_STOP_RESPONSE_FILE_NAME, '');
    const request: VpnStopRequest = { requestId: this.vpnStopRequestId };
    if (!this.vpnCommandGateway.writeCommandFile(
      filesDir,
      VPN_STOP_REQUEST_FILE_NAME,
      JSON.stringify(request)
    )) {
      this.finishVpnExtensionStop(this.disconnectCommandId);
      return;
    }
    this.pollVpnStopResponse(0, this.disconnectCommandId);
  }

  pollVpnStopResponse(attempt: number, commandId: number): void {
    if (!this.host.isDisconnectInProgress() || !this.vpnCommandStateMachine.isActive(commandId)) {
      return;
    }
    if (attempt >= VPN_STOP_POLL_MAX_ATTEMPTS) {
      this.host.recordDiagnosticEvent('vpn_backend_stop_timeout', 'disconnect');
      this.vpnCommandStateMachine.timeout(commandId);
      this.finishVpnExtensionStop(commandId);
      return;
    }
    try {
      const filesDir: string = this.host.getFilesDir();
      const responseText: string | undefined = this.vpnCommandGateway.readCommandFile(
        filesDir,
        VPN_STOP_RESPONSE_FILE_NAME
      );
      if (responseText !== undefined && responseText.trim().length > 0) {
        const response: VpnStopResponse = JSON.parse(responseText) as VpnStopResponse;
        if (response.requestId === this.vpnStopRequestId) {
          this.vpnCommandGateway.writeCommandFile(filesDir, VPN_STOP_RESPONSE_FILE_NAME, '');
          this.host.setBackendStatus(response.status);
          this.finishVpnExtensionStop(commandId);
          return;
        }
      }
    } catch (_error) {
      // The Extension may be replacing the response file. Retry briefly.
    }
    this.vpnStopPollTimer = setTimeout(() => {
      this.pollVpnStopResponse(attempt + 1, commandId);
    }, VPN_STOP_POLL_INTERVAL_MS);
  }

  stopVpnStopPolling(): void {
    if (this.vpnStopPollTimer >= 0) {
      clearTimeout(this.vpnStopPollTimer);
      this.vpnStopPollTimer = -1;
    }
  }

  finishVpnExtensionStop(commandId: number): void {
    this.stopVpnStopPolling();
    this.vpnCommandGateway.stopVpnExtension(this.vpnWant())
      .then(() => {
        if (!this.vpnCommandStateMachine.isActive(commandId) &&
          this.vpnCommandStateMachine.currentState() !== VpnCommandState.TIMED_OUT) {
          this.host.setDisconnectInProgress(false);
          return;
        }
        this.host.recordDiagnosticEvent('disconnect_completed', 'system');
        if (this.isConnected()) {
          this.host.resetTaildropSnapshot();
        }
        this.host.setVpnStatus('HarmonyOS VPN Extension stopped');
        this.host.setDisconnectInProgress(false);
        this.host.setHomeTitleCompact(false);
        this.vpnCommandStateMachine.complete(commandId, VpnCommandState.STOPPED);
        this.stopConnectionPolling();
        if (!this.deferBackendRestart()) {
          this.startBackend(false);
          this.host.scheduleLifecycleTask(() => this.refreshBackendStatus(), 1500);
        }
      })
      .catch((error: BusinessError) => {
        if (!this.vpnCommandStateMachine.isActive(commandId) &&
          this.vpnCommandStateMachine.currentState() !== VpnCommandState.TIMED_OUT) {
          this.host.setDisconnectInProgress(false);
          return;
        }
        this.host.recordDiagnosticEvent('disconnect_failed', 'system', error.code);
        if (this.isConnected()) {
          this.host.resetTaildropSnapshot();
        }
        this.host.setVpnStatus(`FAILED | VPN stop | code=${error.code}`);
        this.host.setDisconnectInProgress(false);
        this.host.setHomeTitleCompact(false);
        this.vpnCommandStateMachine.complete(commandId, VpnCommandState.STOPPED);
      });
  }

  showVpnConflictDialog(): void {
    this.cancelVpnAutoRecovery();
    if (this.host.isVpnConflictDialogVisible()) {
      return;
    }
    this.host.setVpnConflictDialogVisible(true);
    this.host.recordDiagnosticEvent('vpn_conflict_detected', 'connect', 2203002);
    this.clearConnectionCompletionTimer();
    this.stopConnectionPolling();
    this.setConnectInProgress(false);
    this.vpnCommandStateMachine.complete(this.connectCommandId, VpnCommandState.STOPPED);
    this.clearVpnBackendHandoffFiles();
    this.host.setVpnStatus('Stopping this app VPN after system VPN conflict');
    this.host.recordDiagnosticEvent('vpn_conflict_self_disconnect_requested', 'cleanup');
    this.vpnCommandGateway.stopVpnExtension(this.vpnWant())
      .then(() => this.finishVpnConflictCleanup())
      .catch((error: BusinessError) => {
        this.host.recordDiagnosticEvent('vpn_conflict_self_disconnect_failed', 'cleanup', error.code);
        this.finishVpnConflictCleanup();
      });
  }

  finishVpnConflictCleanup(): void {
    if (!this.host.isVpnConflictDialogVisible()) {
      return;
    }
    this.host.setVpnStatus('HarmonyOS VPN Extension stopped');
    this.host.recordDiagnosticEvent('vpn_conflict_self_disconnect_completed', 'cleanup');
    this.host.scheduleLifecycleTask(() => this.host.showVpnConflictAlertDialog(), 300);
  }

  acknowledgeVpnConflict(): void {
    const restoreBackend: boolean = !this.vpnBackendWasRunningBeforeConnect;
    this.host.setVpnConflictDialogVisible(false);
    this.host.setVpnStatus('HarmonyOS VPN Extension stopped');
    this.host.recordDiagnosticEvent('vpn_conflict_acknowledged', 'dialog');
    this.stopConnectionPolling();
    this.host.recordDiagnosticEvent('vpn_conflict_confirm_disconnect_requested', 'cleanup');
    this.vpnCommandGateway.stopVpnExtension(this.vpnWant())
      .then(() => {
        this.host.recordDiagnosticEvent('vpn_conflict_confirm_disconnect_completed', 'cleanup');
        this.finishVpnConflictCancellation(restoreBackend);
      })
      .catch((error: BusinessError) => {
        this.host.recordDiagnosticEvent('vpn_conflict_confirm_disconnect_failed', 'cleanup', error.code);
        this.finishVpnConflictCancellation(restoreBackend);
      });
  }

  finishVpnConflictCancellation(restoreBackend: boolean): void {
    if (!restoreBackend) {
      this.refreshBackendStatus();
      return;
    }
    this.startBackend(false);
    this.host.scheduleLifecycleTask(() => this.refreshBackendStatus(), 1500);
  }

  // --- Secure Login & Auth-Key Login ---

  openSecureLogin(): void {
    if (this.host.isControlServerSwitching()) {
      return;
    }
    if (this.host.isLoginInProgress() || !this.host.isControlServerConfirmed()) {
      if (!this.host.isControlServerConfirmed()) {
        this.host.openControlServerSettings();
      }
      return;
    }
    this.host.setAuthKeyInput('');
    this.host.setAuthKeyLoginVisible(false);
    this.host.setAuthKeyStatus('');
    this.host.setLoginPromptKind('login_loading');
    this.host.setLoginInProgress(true);
    this.loginCommandId = this.vpnCommandStateMachine.begin(VpnCoreCommand.LOGIN);
    if (this.loginCommandId === 0) {
      this.host.setLoginInProgress(false);
      this.host.setLoginPromptKind('');
      return;
    }
    this.host.setLoginHandoffStatus('Preparing secure login');
    this.stopLoginPolling();
    const restartPromise: Promise<void> | undefined = this.backendRestartPromise;
    if (restartPromise !== undefined) {
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
    const commandId: number = this.loginCommandId;
    this.scheduleSecureLoginPoll(commandId, 150);
  }

  scheduleSecureLoginPoll(commandId: number, delayMs: number): void {
    this.loginPollTimer = setTimeout(() => this.pollSecureLogin(0, commandId), delayMs);
  }

  async pollSecureLogin(attempt: number, commandId: number): Promise<void> {
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
      this.host.setLoginHandoffStatus('Opening secure login in system browser');
      this.host.setLoginPromptKind('login_browser_prompt');
      this.host.openSecureLoginBrowser(authUrl)
        .then(() => {
          if (!this.vpnCommandStateMachine.isActive(commandId)) {
            return;
          }
          this.host.recordDiagnosticEvent('secure_login_browser_opened', 'handoff');
          this.host.setLoginHandoffStatus('Secure login page opened');
          this.refreshBackendStatus();
        })
        .catch(() => {
          if (!this.vpnCommandStateMachine.isActive(commandId)) {
            return;
          }
          this.host.recordDiagnosticEvent('secure_login_browser_failed', 'handoff');
          this.finishSecureLogin(commandId, 'FAILED | secure browser handoff');
        });
    } catch (error) {
      if (!this.vpnCommandStateMachine.isActive(commandId)) {
        return;
      }
      this.host.recordDiagnosticEvent('secure_login_browser_failed', 'handoff');
      this.finishSecureLogin(
        commandId,
        DiagnosticPrivacy.formatNativeFailure('FAILED | secure browser handoff', error)
      );
    }
  }

  stopLoginPolling(): void {
    if (this.loginPollTimer >= 0) {
      clearTimeout(this.loginPollTimer);
      this.loginPollTimer = -1;
    }
  }

  finishSecureLogin(commandId: number, status: string): void {
    if (!this.vpnCommandStateMachine.isActive(commandId)) {
      return;
    }
    this.host.setLoginHandoffStatus(status);
    this.host.setLoginInProgress(false);
    this.host.setLoginPromptKind('');
    this.vpnCommandStateMachine.complete(commandId, VpnCommandState.NEEDS_LOGIN);
  }

  completeSecureLoginAfterAuthentication(): void {
    if (!this.host.isLoginInProgress() ||
      this.host.getLoginHandoffStatus() !== 'Secure login page opened' ||
      !this.vpnCommandStateMachine.isActive(this.loginCommandId)) {
      return;
    }
    this.host.setLoginInProgress(false);
    this.host.setLoginPromptKind('');
    this.host.setLoginHandoffStatus('Secure Login Pending');
    this.vpnCommandStateMachine.complete(this.loginCommandId, VpnCommandState.RUNNING);
  }

  toggleAuthKeyLogin(): void {
    if (this.host.isControlServerSwitching()) {
      return;
    }
    if (this.host.isLoginInProgress() || this.host.hasAuthenticatedSession() ||
      this.host.isAppLockRequired()) {
      return;
    }
    if (!this.host.isControlServerConfirmed()) {
      this.host.openControlServerSettings();
      return;
    }
    this.host.setAuthKeyInput('');
    this.host.setAuthKeyStatus('');
    this.host.setAuthKeyLoginVisible(!this.host.isAuthKeyLoginVisible());
    this.host.syncWindowPrivacyMode();
  }

  async waitForAuthKeyBackend(commandId: number): Promise<boolean> {
    const restart: Promise<void> | undefined = this.backendRestartPromise;
    if (restart !== undefined) {
      await restart;
    } else if (this.backendNeedsStart()) {
      this.startBackend(false);
    }
    for (let attempt: number = 0; attempt < 40; attempt++) {
      if (!this.vpnCommandStateMachine.isActive(commandId) || this.host.isAppLockRequired()) {
        return false;
      }
      const status: string = await this.vpnCommandGateway.backendStatusAsync();
      if (status.includes('state=NeedsLogin')) {
        return true;
      }
      if (status.startsWith('FAILED') || status.includes('state=Running') ||
        status.includes('state=NeedsMachineAuth')) {
        return false;
      }
      await new Promise<void>((resolve) => { setTimeout(resolve, 250); });
    }
    return false;
  }

  async submitAuthKeyLogin(): Promise<void> {
    if (this.host.isControlServerSwitching()) {
      return;
    }
    if (this.host.isLoginInProgress() || !this.host.isControlServerConfirmed() ||
      this.host.hasAuthenticatedSession() || this.host.isAppLockRequired()) {
      return;
    }
    const validation: string = AuthKeyLogin.validationError(
      this.host.getAuthKeyInput(),
      this.host.getControlServerURL() !== DEFAULT_CONTROL_SERVER_URL
    );
    if (validation.length > 0) {
      this.host.setAuthKeyStatus(validation);
      return;
    }
    const commandId: number = this.vpnCommandStateMachine.begin(VpnCoreCommand.LOGIN);
    if (commandId === 0) {
      return;
    }
    let authKey: string = this.host.getAuthKeyInput().trim();
    this.host.setAuthKeyInput('');
    this.loginCommandId = commandId;
    this.host.setLoginInProgress(true);
    this.host.setLoginPromptKind('auth_key_loading');
    this.host.setAuthKeyStatus('loading');
    this.host.setLoginHandoffStatus('Auth key login pending');
    this.stopLoginPolling();
    let authenticated: boolean = false;
    try {
      const ready: boolean = await this.waitForAuthKeyBackend(commandId);
      if (!this.vpnCommandStateMachine.isActive(commandId)) {
        return;
      }
      if (!ready || this.host.isAppLockRequired()) {
        this.host.setAuthKeyStatus('backend_not_ready');
        return;
      }
      const request: Promise<string> = this.vpnCommandGateway.loginWithAuthKey(authKey);
      authKey = '';
      const result: string = await request;
      if (!this.vpnCommandStateMachine.isActive(commandId)) {
        return;
      }
      authenticated = result === 'OK | auth key | authenticated' ||
        result === 'OK | auth key | needs_approval';
      if (authenticated) {
        this.host.setAuthKeyStatus(result.endsWith('needs_approval') ? 'needs_approval' : 'authenticated');
        this.host.setAuthKeyLoginVisible(false);
        this.host.syncWindowPrivacyMode();
        await this.refreshBackendStatus();
      } else {
        this.host.setAuthKeyStatus(result === 'FAILED | auth key | timeout' ? 'timeout' :
          result === 'FAILED | auth key | rejected' ? 'rejected' : 'failed');
      }
    } catch (_error) {
      if (this.vpnCommandStateMachine.isActive(commandId)) {
        this.host.setAuthKeyStatus('failed');
      }
    } finally {
      authKey = '';
      if (this.vpnCommandStateMachine.isActive(commandId)) {
        this.host.setLoginInProgress(false);
        this.host.setLoginPromptKind('');
        this.vpnCommandStateMachine.complete(
          commandId,
          authenticated ? VpnCommandState.RUNNING : VpnCommandState.NEEDS_LOGIN
        );
      }
    }
  }

  // --- Exit Nodes & Network Settings ---

  refreshExitNodes(): void {
    try {
      const choicesText: string = this.networkSettingsGateway.readExitNodes();
      const parsed: ExitNodeChoice[] = JSON.parse(choicesText) as ExitNodeChoice[];
      if (!Array.isArray(parsed)) {
        throw new Error('Exit node choices payload is not an array.');
      }
      this.host.setExitNodes(parsed);
      const selected: ExitNodeChoice | undefined = parsed.find(
        (choice: ExitNodeChoice) => choice.selected);
      if (selected === undefined) {
        this.host.setExitNodeNoneStatus();
      } else {
        this.host.setExitNodeSelectedStatus(selected.name);
      }
    } catch (_error) {
      this.host.setExitNodes([]);
      this.host.setExitNodeUnavailableStatus();
    }
  }

  queueExitNodeUpdate(id: string): void {
    this.exitNodeUpdateQueue.enqueue(id);
    this.host.setExitNodeUpdateInProgress(true);
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
          this.host.setExitNodeRawStatus(status);
          if (!status.startsWith('FAILED')) {
            this.cachedVpnConnectConfig = '';
            this.cachedVpnConnectConfigAtMs = 0;
            this.refreshExitNodes();
            this.refreshBackendStatus();
          }
        }
      } catch (_error) {
        if (this.exitNodeUpdateQueue.isCurrent(update.generation)) {
          this.host.setExitNodeRawStatus('FAILED | exit node | update unavailable');
        }
      } finally {
        this.exitNodeUpdateQueue.finish();
      }
    }
    this.host.setExitNodeUpdateInProgress(false);
    this.exitNodeUpdatePromise = undefined;
  }

  refreshNetworkSettings(): void {
    try {
      const settingsText: string = this.networkSettingsGateway.readNetworkSettings();
      const parsed: NetworkSettings = JSON.parse(settingsText) as NetworkSettings;
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
        throw new Error('Network settings payload is invalid.');
      }
      this.host.setNetworkSettings(parsed);
    } catch (_error) {
      this.host.setNetworkSettingStatus('FAILED | network setting | unavailable');
    }
  }

  toggleNetworkSetting(key: NetworkSettingKey): void {
    const current: NetworkSettings = this.host.getNetworkSettings();
    const enabled: boolean = key === 'routeAll' ?
      !current.routeAll : !current.exitNodeAllowLANAccess;
    this.queueNetworkSettingUpdate(key, enabled);
  }

  queueNetworkSettingUpdate(key: NetworkSettingKey, enabled: boolean): void {
    const current: NetworkSettings = this.host.getNetworkSettings();
    const nextSettings: NetworkSettings = key === 'routeAll' ?
      { routeAll: enabled, exitNodeAllowLANAccess: current.exitNodeAllowLANAccess } :
      { routeAll: current.routeAll, exitNodeAllowLANAccess: enabled };
    this.host.setNetworkSettings(nextSettings);
    const queue: NetworkSettingsUpdateQueue = key === 'routeAll' ?
      this.routeAllUpdateQueue : this.exitNodeLanUpdateQueue;
    queue.enqueue(enabled ? 'true' : 'false');
    if (key === 'routeAll') {
      this.host.setRouteAllUpdateInProgress(true);
      if (this.routeAllUpdatePromise === undefined) {
        this.routeAllUpdatePromise = this.drainNetworkSettingUpdates(key, queue);
      }
      return;
    }
    this.host.setExitNodeLanUpdateInProgress(true);
    if (this.exitNodeLanUpdatePromise === undefined) {
      this.exitNodeLanUpdatePromise = this.drainNetworkSettingUpdates(key, queue);
    }
  }

  private async drainNetworkSettingUpdates(
    key: NetworkSettingKey,
    queue: NetworkSettingsUpdateQueue
  ): Promise<void> {
    while (true) {
      const update: PendingNetworkSettingsUpdate | undefined = queue.beginNext();
      if (update === undefined) {
        break;
      }
      try {
        const status: string = await this.networkSettingsGateway.writeNetworkSetting(
          key,
          update.value === 'true'
        );
        if (queue.isCurrent(update.generation)) {
          this.host.setNetworkSettingStatus(status);
          if (!status.startsWith('FAILED')) {
            this.cachedVpnConnectConfig = '';
            this.cachedVpnConnectConfigAtMs = 0;
            this.refreshBackendStatus();
          }
        }
      } catch (_error) {
        if (queue.isCurrent(update.generation)) {
          this.host.setNetworkSettingStatus('FAILED | network setting | update unavailable');
        }
      } finally {
        queue.finish();
      }
    }
    if (key === 'routeAll') {
      this.host.setRouteAllUpdateInProgress(false);
      this.routeAllUpdatePromise = undefined;
    } else {
      this.host.setExitNodeLanUpdateInProgress(false);
      this.exitNodeLanUpdatePromise = undefined;
    }
    if (!this.host.isRouteAllUpdateInProgress() && !this.host.isExitNodeLanUpdateInProgress()) {
      this.refreshNetworkSettings();
    }
  }

  // --- Traffic Metrics ---

  resetTrafficMetrics(): void {
    this.trafficSession = 0;
    this.trafficLastHeartbeatMs = 0;
    this.trafficLastDownloadBytes = 0;
    this.trafficLastUploadBytes = 0;
    this.host.setTrafficDownloadBytes(0);
    this.host.setTrafficUploadBytes(0);
    this.host.setTrafficDownloadRate(0);
    this.host.setTrafficUploadRate(0);
    this.host.setTrafficSamples([]);
  }

  updateTrafficMetrics(status: string, heartbeatMs: number): void {
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
        this.connectionStartedAtMs = session;
        this.trafficLastHeartbeatMs = heartbeatMs;
        this.trafficLastDownloadBytes = downloadBytes;
        this.trafficLastUploadBytes = uploadBytes;
        this.host.setTrafficDownloadBytes(downloadBytes);
        this.host.setTrafficUploadBytes(uploadBytes);
        this.host.setTrafficDownloadRate(0);
        this.host.setTrafficUploadRate(0);
        const initialSample: VpnTrafficSample = { downloadBytesPerSecond: 0, uploadBytesPerSecond: 0 };
        this.host.setTrafficSamples([initialSample]);
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
    const downloadRate: number = Math.round(downloadDelta * 1000 / elapsedMs);
    const uploadRate: number = Math.round(uploadDelta * 1000 / elapsedMs);
    this.host.setTrafficDownloadRate(downloadRate);
    this.host.setTrafficUploadRate(uploadRate);
    this.host.setTrafficDownloadBytes(downloadBytes);
    this.host.setTrafficUploadBytes(uploadBytes);
    this.trafficLastHeartbeatMs = heartbeatMs;
    this.trafficLastDownloadBytes = downloadBytes;
    this.trafficLastUploadBytes = uploadBytes;
    const newSample: VpnTrafficSample = {
      downloadBytesPerSecond: downloadRate,
      uploadBytesPerSecond: uploadRate
    };
    const nextSamples: VpnTrafficSample[] = this.host.getTrafficSamples().concat(newSample);
    this.host.setTrafficSamples(
      nextSamples.length > 60 ? nextSamples.slice(nextSamples.length - 60) : nextSamples
    );
  }
}
