import nativeBridge from 'libtailscale_ohos.so';
import { bundleManager, common, Want } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { BusinessError, deviceInfo, pasteboard } from '@kit.BasicServicesKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { LengthMetrics } from '@kit.ArkUI';
import { DiagnosticEventStore } from '../services/DiagnosticEventStore';
import {
  DiagnosticReportInput,
  DiagnosticReportResult,
  DiagnosticReportService
} from '../services/DiagnosticReportService';
import { DeviceNameService } from '../services/DeviceNameService';
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
  ControlServerConfig,
  ControlServerSettings,
  DEFAULT_CONTROL_SERVER_URL
} from '../services/ControlServerConfig';

const MIN_CONNECTION_LOADING_MS: number = 1400;
const VPN_REPLACE_APPROVAL_FILE_NAME: string = 'vpn-replace-approved';
const PEER_CONNECTIVITY_REQUEST_FILE_NAME: string = 'peer-connectivity-request.json';
const PEER_CONNECTIVITY_RESPONSE_FILE_NAME: string = 'peer-connectivity-response.json';
const TAILDROP_OUTBOX_DIR_NAME: string = 'taildrop-outbox';
const TAILDROP_SEND_REQUEST_FILE_NAME: string = 'taildrop-send-request.json';
const TAILDROP_TARGETS_FILE_NAME: string = 'taildrop-targets.json';
const TAILDROP_CANCEL_REQUEST_FILE_NAME: string = 'taildrop-cancel-request.json';
const TAILDROP_INBOX_DIR_NAME: string = 'taildrop-inbox-export';
const TAILDROP_RECEIVE_REQUEST_FILE_NAME: string = 'taildrop-receive-request.json';
const TAILDROP_RECEIVE_RESPONSE_FILE_NAME: string = 'taildrop-receive-response.json';
const TAILDROP_HISTORY_FILE_NAME: string = 'taildrop-history.json';
const TAILDROP_HISTORY_LIMIT: number = 10;
const VPN_PEERS_FILE_NAME: string = 'vpn-peers.json';
const VPN_STOP_REQUEST_FILE_NAME: string = 'vpn-stop-request.json';
const VPN_STOP_RESPONSE_FILE_NAME: string = 'vpn-stop-response.json';

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
  corpDNS: boolean;
  exitNodeAllowLANAccess: boolean;
}

interface TrafficSample {
  downloadBytesPerSecond: number;
  uploadBytesPerSecond: number;
}

interface PeerConnectivityRequest {
  requestId: number;
  peerKey: string;
}

interface PeerConnectivityResponse {
  requestId: number;
  result: string;
}

interface PeerConnectivityResult {
  state: string;
  reason: string;
  sent: number;
  received: number;
  lossPercent: number;
  minLatencyMs: number;
  avgLatencyMs: number;
  maxLatencyMs: number;
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
  updatedAtMs: number;
}

interface TaildropWaitingFileSummary {
  name: string;
  size: number;
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
  completedAtMs: number;
}

interface TaildropSendFile {
  path: string;
  name: string;
  size: number;
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

interface TaildropReceiveRequest {
  requestId: number;
  action: string;
  name: string;
  inboxRoot: string;
  path: string;
}

interface TaildropReceiveResult {
  requestId: number;
  action: string;
  state: string;
  reason: string;
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
  completedAtMs: number;
}

interface PersistedTaildropHistory {
  records: TaildropTransferRecord[];
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

interface ControlServerTipStateChange {
  isVisible: boolean;
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
    completedAtMs: 0
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
  @State magicDNSProbeStatus: string = 'MagicDNS Probe Pending';
  @State exitNodes: ExitNodeChoice[] = [];
  @State peers: PeerSummary[] = [];
  @State networkSettings: NetworkSettings = {
    routeAll: true,
    corpDNS: true,
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
  @State appVersion: string = '0.8.31';
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
  @State peerConnectivityKey: string = '';
  @State peerConnectivityInProgress: boolean = false;
  @State peerConnectivityResult: PeerConnectivityResult = {
    state: '', reason: '', sent: 0, received: 0, lossPercent: 0,
    minLatencyMs: 0, avgLatencyMs: 0, maxLatencyMs: 0
  };
  @State taildropState: string = 'disconnected';
  @State taildropReason: string = '';
  @State taildropTargets: TaildropTargetSummary[] = [];
  @State taildropWaitingFiles: TaildropWaitingFileSummary[] = [];
  @State taildropInboxReason: string = '';
  @State taildropTransfer: TaildropTransferSummary = emptyTaildropTransfer();
  @State taildropReceive: TaildropReceiveResult = emptyTaildropReceive();
  @State taildropHistory: TaildropTransferRecord[] = [];
  @State taildropPreparing: boolean = false;
  @State taildropReceiveInProgress: boolean = false;
  @State loginInProgress: boolean = false;
  @State connectInProgress: boolean = false;
  @State disconnectInProgress: boolean = false;
  @State backendReady: boolean = false;
  @State backendInitializationVisible: boolean = false;
  @State devicesLoading: boolean = true;
  @State hasAuthenticatedSession: boolean = false;
  @State currentTab: number = 0;
  @State controlServerURL: string = DEFAULT_CONTROL_SERVER_URL;
  @State controlServerInput: string = DEFAULT_CONTROL_SERVER_URL;
  @State controlServerConfirmed: boolean = false;
  @State controlServerStatus: string = '';
  @State controlServerEditorVisible: boolean = true;
  @State controlServerTipVisible: boolean = false;
  @State controlServerTipMessage: string = '';
  @State diagnosticActionStatus: string = '';
  @State diagnosticActionInProgress: boolean = false;
  @State glowLevel: number = 3;
  @State layoutWidth: number = 360;
  @State expandedPeerKeys: string[] = [];
  private connectionPollTimer: number = -1;
  private connectionCompletionTimer: number = -1;
  private connectionStartedAtMs: number = 0;
  private healthPollTimer: number = -1;
  private loginPollTimer: number = -1;
  private magicDNSProbeUrl: string = '';
  private transferScroller: Scroller = new Scroller();
  private settingsScroller: Scroller = new Scroller();
  private tabsController: HdsTabsController = new HdsTabsController();
  private diagnosticsTapCount: number = 0;
  private diagnosticsLastTapMs: number = 0;
  private lifecycleTimers: number[] = [];
  private lifecycleGeneration: number = 0;
  private refreshInFlight: boolean = false;
  private vpnConflictDialogVisible: boolean = false;
  private trafficSession: number = 0;
  private trafficLastHeartbeatMs: number = 0;
  private trafficLastDownloadBytes: number = 0;
  private trafficLastUploadBytes: number = 0;
  private peerConnectivityPollTimer: number = -1;
  private peerConnectivityRequestId: number = 0;
  private vpnStopPollTimer: number = -1;
  private vpnStopRequestId: number = 0;
  private peerSnapshotSignature: string = '';
  private lastHandledTaildropRequestId: number = 0;
  private taildropRequestSubmittedAtMs: number = 0;
  private taildropReceiveResponseInFlight: boolean = false;
  private taildropReceiveDestinationUri: string = '';
  private taildropReceiveExpectedSize: number = 0;
  private taildropPickerOpen: boolean = false;
  private peerDataSource: PeerDataSource = new PeerDataSource();

  private applyPeers(peers: PeerSummary[]): void {
    this.peers = peers;
    this.peerDataSource.replaceAll(peers);
  }

  aboutToAppear(): void {
    this.lifecycleGeneration++;
    this.loadGlowLevel();
    this.resetDiagnosticsMode();
    this.backendReady = false;
    this.devicesLoading = true;
    this.verifyNativeBridge();
    this.loadAppVersion();
    this.loadTaildropHistory();
    this.loadControlServerSettings();
    this.recordDiagnosticEvent('ui_opened', 'lifecycle');
    const vpnIsLive: boolean = this.refreshVpnProbeStatus();
    if (!this.controlServerConfirmed) {
      this.backendStatus = 'Tailscale Backend Stopped | control server not configured';
      this.backendReady = true;
      this.backendInitializationVisible = false;
      this.devicesLoading = false;
      if (vpnIsLive) {
        vpnExtension.stopVpnExtensionAbility(this.vpnWant()).catch(() => {
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
    this.vpnConflictDialogVisible = false;
    this.controlServerTipVisible = false;
    this.stopConnectionPolling();
    this.clearConnectionCompletionTimer();
    this.stopHealthPolling();
    this.stopLoginPolling();
    this.stopPeerConnectivityPolling();
    this.stopVpnStopPolling();
    this.peerConnectivityInProgress = false;
    this.clearLifecycleTimers();
    this.resetDiagnosticsMode();
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

  private loadControlServerSettings(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const settings: ControlServerSettings = ControlServerConfig.load(context.filesDir);
    this.controlServerURL = settings.controlURL;
    this.controlServerInput = settings.controlURL;
    this.controlServerConfirmed = settings.confirmed;
    this.controlServerEditorVisible = !settings.confirmed;
    this.controlServerTipMessage = context.resourceManager.getStringSync(
      $r('app.string.control_server_first_run_tip').id);
    this.controlServerStatus = '';
  }

  private showControlServerTip(): void {
    if (this.controlServerConfirmed || this.controlServerTipVisible) {
      return;
    }
    this.controlServerTipVisible = true;
    this.recordDiagnosticEvent('control_server_tip_shown', 'first_run');
  }

  private openControlServerSettings(): void {
    this.controlServerTipVisible = false;
    this.navigateToTab(2);
    this.showToast($r('app.string.control_server_required_to_connect'));
  }

  private navigateToTab(index: number): void {
    if (this.currentTab === index) {
      return;
    }
    this.tabsController.changeIndex(index);
  }

  private toggleControlServerEditor(): void {
    const visible: boolean = !this.controlServerEditorVisible;
    this.getUIContext().animateTo({ duration: 320, curve: Curve.EaseInOut }, () => {
      this.controlServerEditorVisible = visible;
    });
    this.recordDiagnosticEvent(visible ? 'control_server_editor_opened' :
      'control_server_editor_closed', 'account');
  }

  private saveControlServer(): void {
    if (this.isConnected() || this.isConnecting()) {
      this.controlServerStatus = 'disconnect';
      this.recordDiagnosticEvent('control_server_confirm_blocked', 'connected');
      return;
    }
    const normalized: string = ControlServerConfig.normalize(this.controlServerInput);
    if (normalized.length === 0) {
      this.controlServerStatus = 'invalid';
      this.recordDiagnosticEvent('control_server_confirm_failed', 'invalid');
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const settings: ControlServerSettings | undefined =
      ControlServerConfig.save(context.filesDir, normalized);
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
    this.controlServerTipVisible = false;
    this.recordDiagnosticEvent('control_server_confirmed',
      settings.controlURL === DEFAULT_CONTROL_SERVER_URL ? 'official' : 'custom');
    this.getUIContext().animateTo({ duration: 320, curve: Curve.EaseInOut }, () => {
      this.controlServerEditorVisible = false;
    });
    if (changed) {
      this.backendReady = false;
      this.backendInitializationVisible = true;
      this.devicesLoading = true;
      nativeBridge.backendStopAsync()
        .catch(() => 'FAILED | backend stop')
        .finally(() => {
          this.startBackend();
          this.scheduleLifecycleTask(() => this.refreshBackendStatus(), 1500);
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
    try {
      this.nativeStatus = nativeBridge.hello();
      this.tailscaleVersion = nativeBridge.tailscaleVersion();
    } catch (error) {
      this.nativeStatus = `Go Bridge Failed: ${JSON.stringify(error)}`;
    }
  }

  private async probeUserspaceEngine(): Promise<void> {
    try {
      this.engineStatus = await nativeBridge.probeEngineAsync();
    } catch (error) {
      this.engineStatus = `Tailscale Engine Failed: ${JSON.stringify(error)}`;
    }
  }

  private startBackend(showInitialization: boolean = true): void {
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
      this.backendStatus = nativeBridge.backendStart(
        `${context.filesDir}/tailscale`, this.deviceModel(), this.controlServerURL);
    } catch (error) {
      this.recordDiagnosticEvent('backend_start_failed', 'start');
      this.backendStatus = `Tailscale Backend Failed: ${JSON.stringify(error)}`;
      this.backendReady = true;
      this.backendInitializationVisible = false;
      this.devicesLoading = false;
    }
  }

  private deviceModel(): string {
    return DeviceNameService.model();
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
    this.refreshInFlight = true;
    try {
      const snapshotText: string = await nativeBridge.backendSnapshot();
      if (generation !== this.lifecycleGeneration) {
        return;
      }
      const snapshot: BackendSnapshot = JSON.parse(snapshotText) as BackendSnapshot;
      this.backendStatus = snapshot.status;
      if (this.backendStatus.includes('state=Running')) {
        this.backendReady = true;
        this.backendInitializationVisible = false;
        this.devicesLoading = false;
        this.hasAuthenticatedSession = true;
        this.exitNodes = snapshot.exitNodes;
        this.applyPeers(snapshot.peers);
        this.networkSettings = snapshot.networkSettings;
        this.applyAccountSummary(snapshot.account);
      } else if (snapshot.account.needsApproval || this.backendStatus.includes('NeedsMachineAuth')) {
        this.backendReady = true;
        this.backendInitializationVisible = false;
        this.devicesLoading = false;
        this.hasAuthenticatedSession = true;
        this.exitNodes = [];
        this.applyPeers([]);
        this.applyAccountSummary(snapshot.account);
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
      if (generation !== this.lifecycleGeneration) {
        return;
      }
      this.backendStatus = `Tailscale Backend Failed: ${JSON.stringify(error)}`;
      this.backendReady = true;
      this.backendInitializationVisible = false;
      this.devicesLoading = false;
    } finally {
      this.refreshInFlight = false;
    }
  }

  private refreshExitNodes(): void {
    try {
      const choicesText: string = nativeBridge.backendExitNodes();
      this.exitNodes = JSON.parse(choicesText) as ExitNodeChoice[];
      const selected: ExitNodeChoice | undefined = this.exitNodes.find(
        (choice: ExitNodeChoice) => choice.selected);
      this.exitNodeStatus = selected === undefined ? '未使用出口节点' : `已选择：${selected.name}`;
    } catch (_error) {
      this.exitNodes = [];
      this.exitNodeStatus = '出口节点列表暂不可用';
    }
  }

  private async setExitNode(id: string): Promise<void> {
    try {
      this.exitNodeStatus = await nativeBridge.backendSetExitNodeAsync(id);
      if (!this.exitNodeStatus.startsWith('FAILED')) {
        this.refreshBackendStatus();
      }
    } catch (_error) {
      this.exitNodeStatus = 'FAILED | exit node | update unavailable';
    }
  }

  private refreshPeers(): void {
    try {
      const peersText: string = nativeBridge.backendPeers();
      this.applyPeers(JSON.parse(peersText) as PeerSummary[]);
    } catch (_error) {
      this.applyPeers([]);
    }
    this.devicesLoading = false;
  }

  private refreshAccount(): void {
    try {
      const accountText: string = nativeBridge.backendAccount();
      const backendAccount: AccountSummary = JSON.parse(accountText) as AccountSummary;
      this.accountSummary = {
        displayName: backendAccount.displayName,
        loginName: backendAccount.loginName,
        profilePicURL: backendAccount.profilePicURL,
        tailnetName: backendAccount.tailnetName,
        deviceName: DeviceNameService.withoutHuaweiBrand(
          backendAccount.deviceName.length > 0 ? backendAccount.deviceName : this.deviceModel()),
        addresses: backendAccount.addresses,
        needsApproval: backendAccount.needsApproval,
        keyExpired: backendAccount.keyExpired,
        keyExpiryUnixMs: backendAccount.keyExpiryUnixMs
      };
      this.avatarLoadFailed = false;
    } catch (_error) {
      this.accountSummary = {
        displayName: '', loginName: '', profilePicURL: '', tailnetName: '', deviceName: '', addresses: [],
        needsApproval: false, keyExpired: false, keyExpiryUnixMs: 0
      };
      this.avatarLoadFailed = false;
    }
  }

  private refreshNetworkSettings(): void {
    try {
      const settingsText: string = nativeBridge.backendNetworkSettings();
      this.networkSettings = JSON.parse(settingsText) as NetworkSettings;
    } catch (_error) {
      this.networkSettingStatus = 'FAILED | network setting | unavailable';
    }
  }

  private async setNetworkSetting(key: string, enabled: boolean): Promise<void> {
    try {
      this.networkSettingStatus = await nativeBridge.backendSetNetworkSettingAsync(key, enabled);
      if (!this.networkSettingStatus.startsWith('FAILED')) {
        this.refreshBackendStatus();
      }
    } catch (_error) {
      this.networkSettingStatus = 'FAILED | network setting | update unavailable';
    }
  }

  private openSecureLogin(): void {
    if (this.loginInProgress || !this.controlServerConfirmed) {
      if (!this.controlServerConfirmed) {
        this.openControlServerSettings();
      }
      return;
    }
    this.loginInProgress = true;
    this.loginHandoffStatus = 'Preparing secure login';
    this.stopLoginPolling();
    // Keep one visible frame for the in-button LoadingProgress before a fast
    // handoff switches the foreground application to the system browser.
    this.loginPollTimer = setTimeout(() => this.pollSecureLogin(0), 600);
  }

  private async pollSecureLogin(attempt: number): Promise<void> {
    try {
      const authUrl: string = await nativeBridge.backendAuthURLAsync();
      if (authUrl.startsWith('PENDING')) {
        if (attempt >= 24) {
          this.loginHandoffStatus = 'FAILED | login URL | timed out';
          this.loginInProgress = false;
          return;
        }
        this.loginPollTimer = setTimeout(() => this.pollSecureLogin(attempt + 1), 400);
        return;
      }
      if (!authUrl.startsWith('https://') && !authUrl.startsWith('http://')) {
        this.loginHandoffStatus = authUrl.startsWith('FAILED') ? authUrl :
          'FAILED | login URL | rejected unexpected origin';
        this.loginInProgress = false;
        return;
      }
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.loginHandoffStatus = 'Opening secure login in system browser';
      context.openLink(authUrl, { appLinkingOnly: false })
        .then(() => {
          this.loginHandoffStatus = 'Secure login page opened';
          this.loginInProgress = false;
        })
        .catch(() => {
          this.loginHandoffStatus = 'FAILED | secure browser handoff';
          this.loginInProgress = false;
        });
    } catch (error) {
      this.loginHandoffStatus = `FAILED | secure browser handoff | ${JSON.stringify(error)}`;
      this.loginInProgress = false;
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
      this.controlProbeStatus = nativeBridge.controlProbe();
    } catch (error) {
      this.controlProbeStatus = `Control TLS Probe Failed: ${JSON.stringify(error)}`;
    }
  }

  private vpnWant(): Want {
    return {
      bundleName: 'io.github.tailscaleohos',
      abilityName: 'TailscaleVpnExtensionAbility'
    };
  }

  private beginVpnConnection(): void {
    if (!this.controlServerConfirmed) {
      this.openControlServerSettings();
      return;
    }
    if (this.connectInProgress || this.isConnecting()) {
      return;
    }
    this.clearConnectionCompletionTimer();
    this.connectionStartedAtMs = Date.now();
    this.recordDiagnosticEvent('connect_requested', 'preflight');
    this.setConnectInProgress(true);
    // Let the button render its loading state before the native/VPN calls.
    this.scheduleLifecycleTask(() => this.startVpnProbe(), 300);
  }

  private async startVpnProbe(): Promise<void> {
    try {
      const backendConfig: string = await this.backendVpnConfigWithRecovery();
      if (backendConfig.startsWith('FAILED')) {
        this.recordDiagnosticEvent('vpn_preflight_failed', 'backend_config');
        this.vpnStatus = 'Sign in to Tailscale before connecting';
        this.clearConnectionCompletionTimer();
        this.setConnectInProgress(false);
        return;
      }
      const magicDNSProbeUrl: string = await nativeBridge.backendMagicDNSProbeURLAsync();
      if (magicDNSProbeUrl.startsWith('http://')) {
        this.magicDNSProbeUrl = magicDNSProbeUrl;
        this.magicDNSProbeStatus = 'MagicDNS identity-redacted probe ready';
      } else {
        this.magicDNSProbeUrl = '';
        this.magicDNSProbeStatus = magicDNSProbeUrl;
      }
      this.backendStatus = await nativeBridge.backendStopAsync();
      this.requestVpnExtensionStart();
    } catch (_error) {
      this.recordDiagnosticEvent('vpn_preflight_failed', 'exception');
      this.vpnStatus = 'FAILED | VPN preflight | backend unavailable';
      this.clearConnectionCompletionTimer();
      this.setConnectInProgress(false);
    }
  }

  private async backendVpnConfigWithRecovery(): Promise<string> {
    let backendConfig: string = await nativeBridge.backendVpnConfigAsync();
    if (!backendConfig.startsWith('FAILED')) {
      return backendConfig;
    }
    this.recordDiagnosticEvent('backend_recovery_requested', 'connect_preflight');
    this.startBackend(false);
    for (let attempt: number = 0; attempt < 20; attempt++) {
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 500));
      if (!this.connectInProgress || !this.controlServerConfirmed) {
        return backendConfig;
      }
      backendConfig = await nativeBridge.backendVpnConfigAsync();
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

  private requestVpnExtensionStart(): void {
    this.vpnStatus = 'Requesting HarmonyOS VPN authorization';
    vpnExtension.startVpnExtensionAbility(this.vpnWant())
      .then(() => {
        this.recordDiagnosticEvent('vpn_start_requested', 'system');
        this.vpnStatus = 'HarmonyOS VPN Extension start requested';
        this.startConnectionPolling();
      })
      .catch((error: BusinessError) => {
        this.recordDiagnosticEvent('vpn_start_failed', 'system', error.code);
        this.vpnStatus = `FAILED | VPN start | code=${error.code}`;
        this.clearConnectionCompletionTimer();
        this.setConnectInProgress(false);
      });
  }

  private runMagicDNSProbe(): void {
    if (!this.magicDNSProbeUrl.startsWith('http://')) {
      this.magicDNSProbeStatus = 'SKIPPED | MagicDNS probe | no in-memory target';
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.magicDNSProbeStatus = 'Opening identity-redacted MagicDNS probe';
    context.openLink(this.magicDNSProbeUrl, { appLinkingOnly: false })
      .then(() => {
        this.magicDNSProbeStatus = 'MagicDNS browser probe opened';
      })
      .catch(() => {
        this.magicDNSProbeStatus = 'FAILED | MagicDNS browser probe';
      });
  }

  private stopVpnProbe(): void {
    if (this.disconnectInProgress) {
      return;
    }
    this.clearConnectionCompletionTimer();
    this.setConnectInProgress(false);
    this.disconnectInProgress = true;
    this.recordDiagnosticEvent('disconnect_requested', 'user');
    this.stopVpnStopPolling();
    this.vpnStopRequestId = Date.now();
    const responsePath: string = this.vpnStopFilePath(VPN_STOP_RESPONSE_FILE_NAME);
    this.writePrivateTextFile(responsePath, '');
    const request: VpnStopRequest = { requestId: this.vpnStopRequestId };
    const requestPath: string = this.vpnStopFilePath(VPN_STOP_REQUEST_FILE_NAME);
    if (!this.writePrivateTextFile(requestPath, JSON.stringify(request))) {
      this.finishVpnExtensionStop();
      return;
    }
    this.pollVpnStopResponse(0);
  }

  private vpnStopFilePath(fileName: string): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return `${context.filesDir}/${fileName}`;
  }

  private pollVpnStopResponse(attempt: number): void {
    if (!this.disconnectInProgress) {
      return;
    }
    if (attempt >= 50) {
      this.recordDiagnosticEvent('vpn_backend_stop_timeout', 'disconnect');
      this.finishVpnExtensionStop();
      return;
    }
    const responsePath: string = this.vpnStopFilePath(VPN_STOP_RESPONSE_FILE_NAME);
    try {
      if (fileIo.accessSync(responsePath)) {
        const responseText: string = fileIo.readTextSync(responsePath).trim();
        if (responseText.length > 0) {
          const response: VpnStopResponse = JSON.parse(responseText) as VpnStopResponse;
          if (response.requestId === this.vpnStopRequestId) {
            this.writePrivateTextFile(responsePath, '');
            this.backendStatus = response.status;
            this.finishVpnExtensionStop();
            return;
          }
        }
      }
    } catch (_error) {
      // The Extension may be replacing the response file. Retry briefly before
      // falling back to the lifecycle stop, whose onDestroy path also closes it.
    }
    this.vpnStopPollTimer = setTimeout(() => {
      this.pollVpnStopResponse(attempt + 1);
    }, 150);
  }

  private stopVpnStopPolling(): void {
    if (this.vpnStopPollTimer >= 0) {
      clearTimeout(this.vpnStopPollTimer);
      this.vpnStopPollTimer = -1;
    }
  }

  private finishVpnExtensionStop(): void {
    this.stopVpnStopPolling();
    vpnExtension.stopVpnExtensionAbility(this.vpnWant())
      .then(() => {
        this.recordDiagnosticEvent('disconnect_completed', 'system');
        this.vpnStatus = 'HarmonyOS VPN Extension stopped';
        this.disconnectInProgress = false;
        this.stopConnectionPolling();
        this.startBackend(false);
        this.scheduleLifecycleTask(() => this.refreshBackendStatus(), 1500);
      })
      .catch((error: BusinessError) => {
        this.recordDiagnosticEvent('disconnect_failed', 'system', error.code);
        this.vpnStatus = `FAILED | VPN stop | code=${error.code}`;
        this.disconnectInProgress = false;
      });
  }

  private confirmLogout(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.logout_confirm_title'),
      message: $r('app.string.logout_confirm_message'),
      autoCancel: true,
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
    try {
      this.logoutStatus = await nativeBridge.backendLogoutAsync();
      if (!this.logoutStatus.startsWith('FAILED')) {
        this.loginInProgress = false;
        this.hasAuthenticatedSession = false;
        this.stopLoginPolling();
        this.applyPeers([]);
        this.exitNodes = [];
        this.exitNodeStatus = '未使用出口节点';
        this.loginHandoffStatus = 'Secure Login Pending';
        this.scheduleLifecycleTask(() => this.refreshBackendStatus(), 500);
      }
    } catch (_error) {
      this.logoutStatus = 'FAILED | logout | unavailable';
    }
  }

  private statusNumber(status: string, key: string): number {
    const match: RegExpMatchArray | null = status.match(new RegExp(`(?:^|\\|\\s*)${key}=(\\d+)`));
    return match === null ? 0 : Number(match[1]);
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
    const session: number = this.statusNumber(status, 'trafficSession');
    const uploadBytes: number = this.statusNumber(status, 'txBytes');
    const downloadBytes: number = this.statusNumber(status, 'rxBytes');
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

  private trafficChartPoints(download: boolean): Array<Array<number>> {
    const width: number = this.trafficChartWidth();
    const height: number = 68;
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
        this.vpnStatus = 'HarmonyOS VPN Extension Stopped';
        return false;
      }
      const persistedStatus: string = fileIo.readTextSync(statusPath);
      const heartbeatMatch: RegExpMatchArray | null = persistedStatus.match(/heartbeatMs=(\d+)/);
      const heartbeatMs: number = heartbeatMatch === null ? 0 : Number(heartbeatMatch[1]);
      const heartbeatAgeMs: number = Date.now() - heartbeatMs;
      const heartbeatIsFresh: boolean = heartbeatMs > 0 && heartbeatAgeMs >= 0 && heartbeatAgeMs <= 5000;
      const visibleStatus: string = persistedStatus.replace(/\s*\|\s*heartbeatMs=\d+/, '');
      const extensionIsLive: boolean = heartbeatIsFresh && !visibleStatus.includes('destroyed');
      if (extensionIsLive) {
        this.updateTrafficMetrics(visibleStatus, heartbeatMs);
        if (visibleStatus.includes('state=Running')) {
          this.refreshPeerSnapshot();
        }
        this.refreshTaildropSnapshot();
        this.processTaildropReceiveResponse();
      } else {
        this.resetTrafficMetrics();
        this.resetTaildropSnapshot();
      }
      const shouldPromptVpnConflict: boolean = extensionIsLive && this.connectInProgress &&
        visibleStatus.includes(`code=2203002`);
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
      if (extensionIsLive &&
        (visibleStatus.includes('state=Running') || visibleStatus.startsWith('FAILED'))) {
        this.clearConnectionCompletionTimer();
        this.setConnectInProgress(false);
      }
      if (shouldPromptVpnConflict) {
        this.showVpnConflictDialog();
      }
      return extensionIsLive;
    } catch (error) {
      const businessError = error as BusinessError;
      this.vpnStatus = `FAILED | VPN status file | code=${businessError.code}`;
      return false;
    }
  }

  private startConnectionPolling(): void {
    this.stopConnectionPolling();
    this.connectionPollTimer = setInterval(() => {
      this.refreshVpnProbeStatus();
      if (this.vpnStatus.includes('state=Running') || this.vpnStatus.startsWith('FAILED')) {
        this.stopConnectionPolling();
      }
    }, 1000);
  }

  private stopConnectionPolling(): void {
    if (this.connectionPollTimer >= 0) {
      clearInterval(this.connectionPollTimer);
      this.connectionPollTimer = -1;
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
    // Keep every completion path in one explicit transaction. The traffic panel
    // also animates height, opacity, and position so the expansion stays visible.
    this.getUIContext().animateTo({ duration: 500, curve: Curve.EaseInOut }, () => {
      this.vpnStatus = status;
      this.setConnectInProgress(false);
    });
    this.stopConnectionPolling();
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

  private resetTaildropSnapshot(): void {
    this.taildropState = 'disconnected';
    this.taildropReason = '';
    this.taildropTargets = [];
    this.taildropWaitingFiles = [];
    this.taildropInboxReason = '';
    if (this.taildropReceiveInProgress) {
      this.failTaildropReceive('disconnected');
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
      if (transfer.targetName.length === 0) {
        transfer.targetName = this.taildropTransfer.targetName;
      }
      if (transfer.fileName.length === 0) {
        transfer.fileName = this.taildropTransfer.fileName;
      }
    }
    this.taildropTransfer = transfer;
    if ((transfer.state === 'completed' || transfer.state === 'failed') && transfer.requestId > 0 &&
      transfer.requestId !== this.lastHandledTaildropRequestId) {
      this.lastHandledTaildropRequestId = transfer.requestId;
      const target: TaildropTargetSummary | undefined = this.taildropTargets.find(
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
        completedAtMs: transfer.completedAtMs > 0 ? transfer.completedAtMs : Date.now()
      };
      this.taildropHistory = [record].concat(this.taildropHistory).slice(0, TAILDROP_HISTORY_LIMIT);
      this.persistTaildropHistory();
      this.showToast(transfer.state === 'completed' ?
        $r('app.string.transfer_send_completed') : this.taildropFailureMessage(transfer.reason));
    }
  }

  private refreshTaildropSnapshot(): void {
    try {
      const path: string = this.taildropSnapshotFilePath();
      if (!fileIo.accessSync(path)) {
        this.taildropState = 'loading';
        return;
      }
      const snapshot: TaildropSnapshot = JSON.parse(fileIo.readTextSync(path)) as TaildropSnapshot;
      const ageMs: number = Date.now() - snapshot.updatedAtMs;
      if (snapshot.updatedAtMs <= 0 || ageMs < 0 || ageMs > 5000) {
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
      const validTargets: TaildropTargetSummary[] = snapshot.targets.filter(
        (target: TaildropTargetSummary) => /^peer-[a-f0-9]{16}$/.test(target.key) && target.name.length > 0);
      const validWaitingFiles: TaildropWaitingFileSummary[] = snapshot.waitingFiles.filter(
        (file: TaildropWaitingFileSummary) => file.name.length > 0 && file.name.length <= 255 &&
          !file.name.includes('/') && !file.name.includes('\\') && file.size >= 0);
      this.taildropState = snapshot.state;
      this.taildropReason = snapshot.reason;
      this.taildropTargets = validTargets;
      this.taildropWaitingFiles = validWaitingFiles;
      this.taildropInboxReason = snapshot.inboxReason;
      this.applyTaildropTransfer(snapshot.transfer);
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
    }, 1000);
  }

  private async refreshOrRecoverBackend(generation: number): Promise<void> {
    // The UI backend is intentionally stopped immediately before launching the
    // VPN extension. Do not mistake that short handoff window for a killed
    // extension and start a second backend against the same state directory.
    if (this.connectInProgress || this.disconnectInProgress) {
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

  private vpnReplaceApprovalFilePath(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return `${context.filesDir}/${VPN_REPLACE_APPROVAL_FILE_NAME}`;
  }

  private writeVpnReplaceApproval(): boolean {
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(this.vpnReplaceApprovalFilePath(),
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, Date.now().toString());
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

  private recordDiagnosticEvent(event: string, phase: string, code: number = 0): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      DiagnosticEventStore.record(context.filesDir, 'ui', event, phase, code);
    } catch (_error) {
      // Diagnostic events are best-effort and must not alter app behavior.
    }
  }

  private async generateDiagnosticReport(): Promise<void> {
    if (this.diagnosticReportInProgress) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
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
      magicDNSStatus: this.magicDNSProbeStatus,
      peerCount: this.peers.length,
      onlinePeerCount: this.onlinePeerCount(),
      exitNodeCount: this.exitNodes.length,
      exitNodeSelected: this.exitNodes.some((choice: ExitNodeChoice) => choice.selected),
      addressCount: this.accountSummary.addresses.length,
      signedIn: this.isAuthenticated(),
      routeAll: this.networkSettings.routeAll,
      corpDNS: this.networkSettings.corpDNS,
      exitNodeAllowLANAccess: this.networkSettings.exitNodeAllowLANAccess
    };
    try {
      const result: DiagnosticReportResult = await DiagnosticReportService.generate(context, input);
      const sizeKb: number = Math.max(1, Math.ceil(result.size / 1024));
      this.diagnosticReportStatus = `${result.fileName} (${sizeKb} KB)`;
      this.recordDiagnosticEvent('diagnostic_report_generated', 'share');
      await DiagnosticReportService.share(context, result);
      this.recordDiagnosticEvent('diagnostic_share_opened', 'system');
    } catch (error) {
      const businessError = error as BusinessError;
      this.recordDiagnosticEvent('diagnostic_report_failed', 'generate', businessError.code ?? -1);
      this.diagnosticReportStatus = context.resourceManager.getStringSync(
        $r('app.string.diagnostic_report_failed').id);
    } finally {
      this.diagnosticReportInProgress = false;
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
    try {
      this.getUIContext().showAlertDialog({
        title: $r('app.string.vpn_conflict_title'),
        message: $r('app.string.vpn_conflict_message'),
        autoCancel: false,
        primaryButton: {
          value: $r('app.string.cancel_action'),
          action: () => this.cancelVpnReplacement()
        },
        secondaryButton: {
          value: $r('app.string.continue_action'),
          action: () => this.confirmVpnReplacement()
        }
      });
    } catch (_error) {
      this.vpnConflictDialogVisible = false;
      this.cancelVpnReplacement();
    }
  }

  private cancelVpnReplacement(): void {
    this.vpnConflictDialogVisible = false;
    this.vpnStatus = 'HarmonyOS VPN Extension stopped';
    this.recordDiagnosticEvent('vpn_replacement_cancelled', 'dialog');
    this.stopConnectionPolling();
    vpnExtension.stopVpnExtensionAbility(this.vpnWant())
      .then(() => {
        this.startBackend(false);
        this.scheduleLifecycleTask(() => this.refreshBackendStatus(), 1500);
      })
      .catch(() => {
        this.startBackend(false);
        this.scheduleLifecycleTask(() => this.refreshBackendStatus(), 1500);
      });
  }

  private confirmVpnReplacement(): void {
    this.vpnConflictDialogVisible = false;
    this.recordDiagnosticEvent('vpn_replacement_confirmed', 'dialog');
    if (!this.writeVpnReplaceApproval()) {
      this.vpnStatus = 'FAILED | VPN replacement approval | status unavailable';
      this.startBackend(false);
      this.scheduleLifecycleTask(() => this.refreshBackendStatus(), 1500);
      return;
    }
    this.clearConnectionCompletionTimer();
    this.connectionStartedAtMs = Date.now();
    this.recordDiagnosticEvent('vpn_replacement_restart_requested', 'system');
    this.setConnectInProgress(true);
    this.vpnStatus = 'Disconnecting existing VPN connection';
    vpnExtension.stopVpnExtensionAbility(this.vpnWant())
      .then(() => {
        this.scheduleLifecycleTask(() => this.requestVpnExtensionStart(), 300);
      })
      .catch(() => {
        this.scheduleLifecycleTask(() => this.requestVpnExtensionStart(), 300);
      });
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
    let nodeName: string = this.nodeNameSlug(sourceName);
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

  private peerDeviceDescription(peer: PeerSummary): string {
    return peer.os.length > 0 ? this.displayOsName(peer.os) : peer.deviceModel;
  }

  private taildropOnlineTargetCount(): number {
    return this.taildropTargets.filter((target: TaildropTargetSummary) => target.online).length;
  }

  private taildropTargetDescription(target: TaildropTargetSummary): string {
    if (target.os.length > 0) {
      return this.displayOsName(target.os);
    }
    if (target.deviceModel.length > 0) {
      return target.deviceModel;
    }
    return 'Tailscale';
  }

  private taildropStatusTitle(): ResourceStr {
    if (!this.isConnected()) {
      return $r('app.string.transfer_connect_first_title');
    }
    if (this.taildropState === 'loading') {
      return $r('app.string.transfer_detecting_title');
    }
    if (this.taildropState === 'disabled') {
      return $r('app.string.transfer_admin_disabled_title');
    }
    if (this.taildropState !== 'ready') {
      return $r('app.string.transfer_unavailable_title');
    }
    return $r('app.string.transfer_targets_ready_title', this.taildropOnlineTargetCount());
  }

  private taildropStatusDescription(): ResourceStr {
    if (!this.isConnected()) {
      return $r('app.string.transfer_connect_first_description');
    }
    if (this.taildropState === 'loading') {
      return $r('app.string.transfer_detecting_description');
    }
    if (this.taildropState === 'disabled') {
      return $r('app.string.transfer_admin_disabled_description');
    }
    if (this.taildropState !== 'ready') {
      return $r('app.string.transfer_unavailable_description');
    }
    if (this.taildropTargets.length === 0) {
      return $r('app.string.transfer_no_targets_description');
    }
    return $r('app.string.transfer_targets_ready_description');
  }

  private primaryTailscaleAddress(addresses: string[]): string {
    const ipv4Address: string | undefined = addresses.find((address: string) =>
      !address.includes(':'));
    if (ipv4Address !== undefined) {
      return ipv4Address;
    }
    return addresses.length > 0 ? addresses[0] : '';
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

  private settingsStatusText(): string {
    return this.isConnected() ? this.vpnStatus : this.backendStatus;
  }

  private routeSettingState(): ResourceStr {
    const status: string = this.settingsStatusText();
    if (!status.includes('routeAll=')) {
      return $r('app.string.setting_unavailable');
    }
    return status.includes('routeAll=true') ? $r('app.string.setting_enabled') :
      $r('app.string.setting_disabled');
  }

  private magicDNSSettingState(): ResourceStr {
    const status: string = this.settingsStatusText();
    if (!status.includes('corpDNS=')) {
      return $r('app.string.setting_unavailable');
    }
    return status.includes('corpDNS=true') ? $r('app.string.setting_enabled') :
      $r('app.string.setting_disabled');
  }

  private exitNodeLANSettingState(): ResourceStr {
    const status: string = this.settingsStatusText();
    if (!status.includes('exitNodeLAN=')) {
      return $r('app.string.setting_unavailable');
    }
    return status.includes('exitNodeLAN=true') ? $r('app.string.setting_enabled') :
      $r('app.string.setting_disabled');
  }

  private exitNodeSettingState(): ResourceStr {
    const status: string = this.settingsStatusText();
    if (!status.includes('exitNode=')) {
      return $r('app.string.setting_unavailable');
    }
    return status.includes('exitNode=true') ? $r('app.string.setting_enabled') :
      $r('app.string.setting_disabled');
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
    this.diagnosticsExpanded = false;
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
      this.showToast('您已进入工程模式');
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
      this.showToast('您已进入工程模式');
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

  private glowMaskColor(): ResourceColor {
    return $r('sys.color.background_primary');
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

  private glowLevelDescription(): ResourceStr {
    if (this.glowLevel === 0) {
      return $r('app.string.glow_exquisite_description');
    }
    if (this.glowLevel === 1) {
      return $r('app.string.glow_gentle_description');
    }
    if (this.glowLevel === 2) {
      return $r('app.string.glow_smooth_description');
    }
    return $r('app.string.glow_adaptive_description');
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
    return this.layoutWidth >= 840;
  }

  private pageMargin(): number {
    if (this.layoutWidth >= 840) {
      return 32;
    }
    if (this.layoutWidth >= 600) {
      return 24;
    }
    return 16;
  }

  private contentMargin(): number {
    return this.pageMargin() + 8;
  }

  private pageBottomInset(): number {
    return this.isWideNavigation() ? 32 : 120;
  }

  private groupBackground(): ResourceColor {
    return $r('sys.color.comp_background_primary');
  }

  private isPeerNameExpanded(peerKey: string): boolean {
    return this.expandedPeerKeys.includes(peerKey);
  }

  private togglePeerName(peerKey: string): void {
    this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseInOut }, () => {
      if (this.isPeerNameExpanded(peerKey)) {
        this.expandedPeerKeys = this.expandedPeerKeys.filter((key: string) => key !== peerKey);
        return;
      }
      this.expandedPeerKeys = this.expandedPeerKeys.concat(peerKey);
    });
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

  private peerConnectivityFilePath(fileName: string): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return `${context.filesDir}/${fileName}`;
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

  private taildropTransferStatusText(record: TaildropTransferRecord): ResourceStr {
    if (record.state === 'completed') {
      return record.direction === 'receive' ? $r('app.string.transfer_received_status') :
        $r('app.string.transfer_sent_status');
    }
    return $r('app.string.transfer_failed_status');
  }

  private taildropTransferRecordTitle(record: TaildropTransferRecord): string {
    if (record.direction === 'receive') {
      return record.fileName;
    }
    return record.targetName;
  }

  private taildropTransferRecordDescription(record: TaildropTransferRecord): string {
    const size: string = this.formatTrafficBytes(record.totalBytes);
    if (record.direction === 'receive') {
      return size;
    }
    return record.fileCount > 1 ? `${record.fileCount} files · ${size}` : size;
  }

  private taildropHistoryPath(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return `${context.filesDir}/${TAILDROP_HISTORY_FILE_NAME}`;
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
      const persisted: PersistedTaildropHistory = JSON.parse(fileIo.readTextSync(path)) as PersistedTaildropHistory;
      const records: TaildropTransferRecord[] = persisted.records.filter(
        (record: TaildropTransferRecord) => this.validTaildropHistoryRecord(record))
        .slice(0, TAILDROP_HISTORY_LIMIT);
      this.taildropHistory = records;
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

  private taildropOutboxRoot(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return `${context.filesDir}/${TAILDROP_OUTBOX_DIR_NAME}`;
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
      this.taildropTransfer.state === 'sending' || this.taildropReceiveInProgress;
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
    const root: string = this.taildropOutboxRoot();
    const requestDir: string = `${root}/${requestId}`;
    fileIo.mkdirSync(requestDir, true);
    const prepared: TaildropSendFile[] = [];
    for (let index: number = 0; index < uris.length; index++) {
      let source: fileIo.File | undefined = undefined;
      try {
        source = fileIo.openSync(uris[index], fileIo.OpenMode.READ_ONLY);
        const stat: fileIo.Stat = fileIo.statSync(source.fd);
        if (!stat.isFile() || stat.size < 0) {
          throw new Error('Selected item is not a regular file.');
        }
        const name: string = this.sanitizeTaildropFileName(source.name, index);
        const destination: string = `${requestDir}/${index}.taildrop`;
        await fileIo.copyFile(source.fd, destination);
        const copiedStat: fileIo.Stat = fileIo.statSync(destination);
        if (!copiedStat.isFile() || copiedStat.size !== stat.size) {
          throw new Error('Copied Taildrop file failed verification.');
        }
        prepared.push({ path: destination, name: name, size: copiedStat.size });
      } finally {
        if (source !== undefined) {
          try {
            fileIo.closeSync(source);
          } catch (_error) {
            // The picker descriptor may already be closed after a copy failure.
          }
        }
      }
    }
    return prepared;
  }

  private cleanupPreparedTaildropFiles(files: TaildropSendFile[]): void {
    files.forEach((file: TaildropSendFile) => {
      try {
        if (fileIo.accessSync(file.path)) {
          fileIo.unlinkSync(file.path);
        }
      } catch (_error) {
        // Extension startup cleanup handles any remaining outbox file.
      }
    });
    if (files.length > 0) {
      const requestDir: string = files[0].path.substring(0, files[0].path.lastIndexOf('/'));
      try {
        fileIo.rmdirSync(requestDir);
      } catch (_error) {
        // The directory may still contain a file whose cleanup failed.
      }
    }
  }

  private startTaildropSelection(target: TaildropTargetSummary): void {
    this.selectTaildropFiles(target).catch(() => {
      this.taildropPickerOpen = false;
      this.taildropPreparing = false;
      this.showToast($r('app.string.transfer_file_selection_failed'));
    });
  }

  private async selectTaildropFiles(target: TaildropTargetSummary): Promise<void> {
    if (!target.online || !this.isConnected() || this.taildropState !== 'ready' ||
      this.taildropSendActive()) {
      return;
    }
    this.taildropPickerOpen = true;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const documentPicker = new picker.DocumentViewPicker(context);
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 10;
    let uris: string[] = [];
    try {
      uris = await documentPicker.select(options);
    } finally {
      this.taildropPickerOpen = false;
    }
    if (uris.length === 0) {
      return;
    }
    this.taildropPreparing = true;
    const requestId: number = Date.now();
    let files: TaildropSendFile[] = [];
    try {
      files = await this.prepareTaildropFiles(uris.slice(0, 10), requestId);
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
        fileBytes: 0, fileSize: 0, bytesSent: 0, totalBytes: totalBytes, completedAtMs: 0
      };
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
    if (this.taildropTransfer.requestId <= 0 ||
      (this.taildropTransfer.state !== 'queued' && this.taildropTransfer.state !== 'sending')) {
      return;
    }
    const request: TaildropCancelRequest = { requestId: this.taildropTransfer.requestId };
    if (!this.writeAtomicTaildropRequest(this.taildropCancelRequestPath(), request.requestId,
      JSON.stringify(request))) {
      this.showToast($r('app.string.transfer_cancel_failed'));
      return;
    }
    this.recordDiagnosticEvent('taildrop_send_cancel_requested', 'transfer');
  }

  private retryTaildropSend(record: TaildropTransferRecord): void {
    if (record.direction !== 'send' || record.state !== 'failed' || this.taildropSendActive()) {
      return;
    }
    const target: TaildropTargetSummary | undefined = this.taildropTargets.find(
      (item: TaildropTargetSummary) => item.key === record.targetKey && item.online);
    if (target === undefined) {
      this.showToast($r('app.string.transfer_send_target_unavailable'));
      return;
    }
    this.startTaildropSelection(target);
  }

  private startTaildropReceive(file: TaildropWaitingFileSummary): void {
    this.selectTaildropReceiveDestination(file).catch(() => {
      this.failTaildropReceive('export_failed');
    });
  }

  private async selectTaildropReceiveDestination(file: TaildropWaitingFileSummary): Promise<void> {
    if (!this.isConnected() || this.taildropState !== 'ready' || this.taildropSendActive()) {
      return;
    }
    this.taildropReceiveInProgress = true;
    this.taildropReceive = {
      requestId: 0, action: 'stage', state: 'selecting', reason: '', name: file.name,
      size: file.size, path: ''
    };
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const documentPicker = new picker.DocumentViewPicker(context);
    const options = new picker.DocumentSaveOptions();
    options.newFileNames = [file.name];
    let uris: string[] = [];
    try {
      uris = await documentPicker.save(options);
    } catch (_error) {
      this.resetTaildropReceiveOperation();
      this.showToast($r('app.string.transfer_receive_picker_failed'));
      return;
    }
    if (uris.length === 0) {
      this.resetTaildropReceiveOperation();
      return;
    }
    const requestId: number = Date.now();
    const inboxRoot: string = this.taildropInboxRoot();
    fileIo.mkdirSync(inboxRoot, true);
    const request: TaildropReceiveRequest = {
      requestId: requestId,
      action: 'stage',
      name: file.name,
      inboxRoot: inboxRoot,
      path: `${inboxRoot}/${requestId}.taildrop`
    };
    this.taildropReceiveDestinationUri = uris[0];
    this.taildropReceiveExpectedSize = file.size;
    this.taildropReceive = {
      requestId: requestId, action: 'stage', state: 'requesting', reason: '', name: file.name,
      size: file.size, path: request.path
    };
    this.writePrivateTextFile(this.taildropReceiveResponsePath(), '');
    if (!this.writeAtomicTaildropRequest(this.taildropReceiveRequestPath(), requestId, JSON.stringify(request))) {
      this.failTaildropReceive('extension_error');
      return;
    }
    this.recordDiagnosticEvent('taildrop_receive_queued', 'transfer');
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
    if (!this.isConnected() || this.taildropState !== 'ready' || this.taildropSendActive()) {
      return;
    }
    const requestId: number = Date.now();
    const request: TaildropReceiveRequest = {
      requestId: requestId, action: 'clear', name: '', inboxRoot: '', path: ''
    };
    this.taildropReceiveInProgress = true;
    this.taildropReceive = {
      requestId: requestId, action: 'clear', state: 'requesting', reason: '', name: '', size: 0, path: ''
    };
    this.writePrivateTextFile(this.taildropReceiveResponsePath(), '');
    if (!this.writeAtomicTaildropRequest(this.taildropReceiveRequestPath(), requestId, JSON.stringify(request))) {
      this.failTaildropReceive('clear_failed');
      return;
    }
    this.recordDiagnosticEvent('taildrop_receive_cache_clear_requested', 'transfer');
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
      if (result.requestId !== this.taildropReceive.requestId || result.action !== this.taildropReceive.action) {
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
      this.failTaildropReceive(result.reason);
      return;
    }
    if (result.action === 'stage' && result.state === 'staged') {
      this.taildropReceive = {
        requestId: result.requestId, action: 'stage', state: 'exporting', reason: '', name: result.name,
        size: result.size, path: result.path
      };
      const copied: boolean = await this.exportTaildropReceivedFile(result);
      if (!copied) {
        this.failTaildropReceive('export_failed');
        return;
      }
      const deleteRequest: TaildropReceiveRequest = {
        requestId: result.requestId, action: 'delete', name: result.name, inboxRoot: '', path: ''
      };
      this.taildropReceive = {
        requestId: result.requestId, action: 'delete', state: 'deleting', reason: '', name: result.name,
        size: result.size, path: ''
      };
      if (!this.writeAtomicTaildropRequest(this.taildropReceiveRequestPath(), result.requestId,
        JSON.stringify(deleteRequest))) {
        this.failTaildropReceive('delete_failed');
      }
      return;
    }
    if (result.action === 'delete' && result.state === 'completed') {
      this.completeTaildropReceive();
      return;
    }
    if (result.action === 'clear' && result.state === 'completed') {
      if (!this.clearLocalTaildropInboxCache()) {
        this.failTaildropReceive('clear_failed');
        return;
      }
      this.taildropWaitingFiles = [];
      this.taildropInboxReason = '';
      this.recordDiagnosticEvent('taildrop_receive_cache_cleared', 'transfer');
      this.showToast($r('app.string.transfer_cache_cleared'));
      this.resetTaildropReceiveOperation();
      return;
    }
    this.failTaildropReceive('invalid_result');
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
      return cleared;
    } catch (_error) {
      return false;
    }
  }

  private async exportTaildropReceivedFile(result: TaildropReceiveResult): Promise<boolean> {
    let destination: fileIo.File | undefined = undefined;
    let copied: boolean = false;
    try {
      if (this.taildropReceiveDestinationUri.length === 0 || result.size !== this.taildropReceiveExpectedSize) {
        copied = false;
      } else {
        destination = fileIo.openSync(this.taildropReceiveDestinationUri,
          fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        await fileIo.copyFile(result.path, destination.fd);
        copied = fileIo.statSync(destination.fd).size === result.size;
      }
    } catch (_error) {
      copied = false;
    }
    if (destination !== undefined) {
      try {
        fileIo.closeSync(destination);
      } catch (_error) {
        copied = false;
      }
    }
    if (!copied && this.taildropReceiveDestinationUri.length > 0) {
      try {
        fileIo.unlinkSync(this.taildropReceiveDestinationUri);
      } catch (_error) {
        // The system provider may not allow deleting a failed export URI.
      }
    }
    try {
      if (result.path.length > 0 && fileIo.accessSync(result.path)) {
        fileIo.unlinkSync(result.path);
      }
    } catch (_error) {
      // Extension startup cleanup removes any staged export left behind.
    }
    return copied;
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
      completedAtMs: Date.now()
    };
    this.taildropHistory = [record].concat(this.taildropHistory).slice(0, TAILDROP_HISTORY_LIMIT);
    this.persistTaildropHistory();
  }

  private completeTaildropReceive(): void {
    const receivedName: string = this.taildropReceive.name;
    this.addTaildropReceiveRecord('completed', '');
    this.taildropWaitingFiles = this.taildropWaitingFiles.filter(
      (file: TaildropWaitingFileSummary) => file.name !== receivedName);
    this.recordDiagnosticEvent('taildrop_receive_completed', 'transfer');
    this.showToast($r('app.string.transfer_receive_completed'));
    this.resetTaildropReceiveOperation();
  }

  private failTaildropReceive(reason: string): void {
    if (this.taildropReceive.requestId > 0 && this.taildropReceive.action !== 'clear') {
      this.addTaildropReceiveRecord('failed', reason);
    }
    this.recordDiagnosticEvent('taildrop_receive_failed', reason);
    this.showToast(this.taildropReceiveFailureMessage(reason));
    this.resetTaildropReceiveOperation();
  }

  private resetTaildropReceiveOperation(): void {
    if (this.taildropReceive.path.length > 0) {
      try {
        if (fileIo.accessSync(this.taildropReceive.path)) {
          fileIo.unlinkSync(this.taildropReceive.path);
        }
      } catch (_error) {
        // Extension startup cleanup removes any staged export left behind.
      }
    }
    this.taildropReceiveInProgress = false;
    this.taildropReceiveDestinationUri = '';
    this.taildropReceiveExpectedSize = 0;
    this.taildropReceive = emptyTaildropReceive();
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
    if (reason === 'delete_failed') {
      return $r('app.string.transfer_receive_delete_failed');
    }
    return $r('app.string.transfer_receive_failed');
  }

  private emptyPeerConnectivityResult(reason: string = ''): PeerConnectivityResult {
    return {
      state: reason.length > 0 ? 'failed' : '', reason: reason,
      sent: 0, received: 0, lossPercent: 0,
      minLatencyMs: 0, avgLatencyMs: 0, maxLatencyMs: 0
    };
  }

  private parsePeerConnectivityResult(resultText: string): PeerConnectivityResult {
    try {
      const result: PeerConnectivityResult = JSON.parse(resultText) as PeerConnectivityResult;
      if (result.state === 'reachable' || result.state === 'degraded' ||
        result.state === 'failed' || result.state === 'skipped') {
        return result;
      }
    } catch (_error) {
      // Fall through to the sanitized invalid-result state.
    }
    return this.emptyPeerConnectivityResult('invalid_result');
  }

  private finishPeerConnectivity(result: PeerConnectivityResult): void {
    this.peerConnectivityResult = result;
    this.peerConnectivityInProgress = false;
    this.stopPeerConnectivityPolling();
    this.recordDiagnosticEvent('peer_connectivity_completed', result.state);
  }

  private startPeerConnectivity(peer: PeerSummary): void {
    if (this.peerConnectivityInProgress || !peer.online) {
      return;
    }
    this.stopPeerConnectivityPolling();
    this.peerConnectivityKey = peer.key;
    this.peerConnectivityResult = this.emptyPeerConnectivityResult();
    this.peerConnectivityInProgress = true;
    this.peerConnectivityRequestId = Date.now();
    this.recordDiagnosticEvent('peer_connectivity_requested', this.isConnected() ? 'vpn' : 'ui');
    if (!this.isConnected()) {
      nativeBridge.backendPeerConnectivityAsync(peer.key)
        .then((resultText: string) => {
          this.finishPeerConnectivity(this.parsePeerConnectivityResult(resultText));
        })
        .catch(() => {
          this.finishPeerConnectivity(this.emptyPeerConnectivityResult('backend_unavailable'));
        });
      return;
    }
    const responsePath: string = this.peerConnectivityFilePath(PEER_CONNECTIVITY_RESPONSE_FILE_NAME);
    this.writePrivateTextFile(responsePath, '');
    const request: PeerConnectivityRequest = {
      requestId: this.peerConnectivityRequestId,
      peerKey: peer.key
    };
    const requestPath: string = this.peerConnectivityFilePath(PEER_CONNECTIVITY_REQUEST_FILE_NAME);
    if (!this.writePrivateTextFile(requestPath, JSON.stringify(request))) {
      this.finishPeerConnectivity(this.emptyPeerConnectivityResult('extension_error'));
      return;
    }
    this.pollPeerConnectivityResponse(0);
  }

  private pollPeerConnectivityResponse(attempt: number): void {
    if (!this.peerConnectivityInProgress) {
      return;
    }
    if (attempt >= 50) {
      this.finishPeerConnectivity(this.emptyPeerConnectivityResult('timeout'));
      return;
    }
    const responsePath: string = this.peerConnectivityFilePath(PEER_CONNECTIVITY_RESPONSE_FILE_NAME);
    try {
      if (fileIo.accessSync(responsePath)) {
        const responseText: string = fileIo.readTextSync(responsePath).trim();
        if (responseText.length > 0) {
          const response: PeerConnectivityResponse = JSON.parse(responseText) as PeerConnectivityResponse;
          if (response.requestId === this.peerConnectivityRequestId) {
            this.writePrivateTextFile(responsePath, '');
            this.finishPeerConnectivity(this.parsePeerConnectivityResult(response.result));
            return;
          }
        }
      }
    } catch (_error) {
      // The extension may be replacing the response file; retry within the timeout.
    }
    this.peerConnectivityPollTimer = setTimeout(() => {
      this.pollPeerConnectivityResponse(attempt + 1);
    }, 300);
  }

  private stopPeerConnectivityPolling(): void {
    if (this.peerConnectivityPollTimer >= 0) {
      clearTimeout(this.peerConnectivityPollTimer);
      this.peerConnectivityPollTimer = -1;
    }
  }

  private peerConnectivityReason(reason: string): ResourceStr {
    if (reason === 'peer_offline') {
      return $r('app.string.peer_connectivity_offline');
    }
    if (reason === 'no_address') {
      return $r('app.string.peer_connectivity_no_address');
    }
    if (reason === 'no_response' || reason === 'timeout') {
      return $r('app.string.peer_connectivity_no_response');
    }
    return $r('app.string.peer_connectivity_unavailable');
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
  private ButtonContent(label: ResourceStr, primary: boolean, loading: boolean) {
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
        .fontColor(primary ? $r('sys.color.font_on_primary') : $r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
  }

  @Builder
  private ConnectButtonContent() {
    Stack({ alignContent: Alignment.Center }) {
      Text($r('app.string.action_connect'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_on_primary'))
        .opacity(this.connectInProgress || this.isConnecting() ? 0 : 1)
      if (this.connectInProgress || this.isConnecting()) {
        Row({ space: 8 }) {
          LoadingProgress()
            .id('vpn-start-loading')
            .width(20)
            .height(20)
            .color($r('sys.color.font_on_primary'))
          Text($r('app.string.action_connecting'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_on_primary'))
        }
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
  }

  @Builder
  private LoginButtonContent() {
    Stack({ alignContent: Alignment.Center }) {
      Text($r('app.string.action_login'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_on_primary'))
        .opacity(this.loginInProgress ? 0 : 1)
      if (this.loginInProgress) {
        Row({ space: 8 }) {
          LoadingProgress()
            .id('login-open-loading')
            .width(20)
            .height(20)
            .color($r('sys.color.font_on_primary'))
          Text($r('app.string.action_login'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_on_primary'))
        }
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
  }

  @Builder
  private ConnectButton() {
    Button({
      type: ButtonType.ROUNDED_RECTANGLE,
      stateEffect: true,
      buttonStyle: ButtonStyleMode.EMPHASIZED,
      controlSize: ControlSize.NORMAL
    }) {
      this.ConnectButtonContent()
    }
      .id('vpn-start')
      .width('100%')
      .height(52)
      .enabled(!this.connectInProgress && !this.isConnecting())
      .onClick(() => this.beginVpnConnection())
  }

  @Builder
  private LoginButton() {
    Button({
      type: ButtonType.ROUNDED_RECTANGLE,
      stateEffect: true,
      buttonStyle: ButtonStyleMode.EMPHASIZED,
      controlSize: ControlSize.NORMAL
    }) {
      this.LoginButtonContent()
    }
      .id('login-open')
      .width('100%')
      .height(52)
      .enabled(!this.loginInProgress)
      .onClick(() => this.openSecureLogin())
  }

  @Builder
  private ImmersiveButton(label: ResourceStr, nodeId: string, primary: boolean,
    enabled: boolean, action: () => void, loading: boolean = false) {
    if (this.glowLevel === 3) {
      Button({
        type: ButtonType.ROUNDED_RECTANGLE,
        stateEffect: true,
        buttonStyle: primary ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL,
        controlSize: ControlSize.NORMAL
      }) {
        this.ButtonContent(label, primary, loading)
      }
        .id(nodeId)
        .width('100%')
        .height(52)
        .visualEffect(new hdsEffect.HdsEffectBuilder()
          .pressShadow(hdsEffect.PressShadowType.BLEND_WHITE)
          .buildEffect())
        .opacity(enabled ? 1 : 0.4)
        .enabled(enabled)
        .onClick(action)
    } else {
      Button({
        type: ButtonType.ROUNDED_RECTANGLE,
        stateEffect: true,
        buttonStyle: primary ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL,
        controlSize: ControlSize.NORMAL
      }) {
        this.ButtonContent(label, primary, loading)
      }
        .id(nodeId)
        .width('100%')
        .height(52)
        .backgroundEffect({
          radius: this.glowRadius(),
          saturation: this.glowSaturation(),
          brightness: this.glowBrightness(),
          color: primary ? $r('sys.color.comp_background_emphasize') : this.glowSurface(),
          adaptiveColor: AdaptiveColor.DEFAULT
        }, { disableSystemAdaptation: false })
        .visualEffect(new hdsEffect.HdsEffectBuilder()
          .pressShadow(hdsEffect.PressShadowType.BLEND_WHITE)
          .buildEffect())
        .shadow({
          radius: this.glowLevel === 0 ? 12 : (this.glowLevel === 1 ? 8 : 4),
          color: this.glowColor(),
          offsetY: 3
        })
        .opacity(enabled ? 1 : 0.4)
        .enabled(enabled)
        .onClick(action)
    }
  }

  @Builder
  private StandardActionButton(label: ResourceStr, nodeId: string, primary: boolean,
    enabled: boolean, action: () => void, loading: boolean = false) {
    Button({
      type: ButtonType.ROUNDED_RECTANGLE,
      stateEffect: true,
      buttonStyle: primary ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL,
      controlSize: ControlSize.NORMAL
    }) {
      this.ButtonContent(label, primary, loading)
    }
      .id(nodeId)
      .width('100%')
      .height(48)
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
    return this.isConnected() ? $r('sys.color.comp_background_emphasize') : this.secondaryBackground();
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
      buttonStyle: ButtonStyleMode.NORMAL,
      controlSize: ControlSize.NORMAL
    }) {
      if (this.connectionActionLoading()) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(this.connectionActionForeground())
      } else {
        Image($r('app.media.connection_filled'))
          .width(22)
          .height(22)
          .fillColor(this.connectionActionForeground())
      }
    }
    .id(this.connectionActionNodeId())
    .width(48)
    .height(48)
    .backgroundColor(this.connectionActionBackground())
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
        .stroke('#8B5CF6')
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
            .fontColor('#8B5CF6')
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
    Column() {
      this.TrafficSummary()
    }
    .width('100%')
    .height(this.isConnected() ? 132 : 0)
    .opacity(this.isConnected() ? 1 : 0)
    .translate({ y: this.isConnected() ? 0 : -10 })
    .clip(true)
    .animation({ duration: 500, curve: Curve.EaseInOut })
  }

  @Builder
  private ConnectionPanel() {
    Column({ space: 12 }) {
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
    .animation({ duration: 500, curve: Curve.EaseInOut })
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
          .enabled(!this.isConnected() && this.isAuthenticated())
          .opacity(!this.isConnected() && this.isAuthenticated() ? 1 : 0.4)
          .onChange((enabled: boolean) => this.setNetworkSetting('routeAll', enabled))
      }
      .width('100%')
      .constraintSize({ minHeight: 56 })
      .padding({ top: 6, bottom: 6 })

      Divider().color($r('sys.color.comp_divider'))

      Row() {
        Column({ space: 2 }) {
          Text($r('app.string.setting_magicdns'))
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
          Text($r('app.string.setting_magicdns_description'))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.networkSettings.corpDNS })
          .id('tailscale-dns-toggle')
          .enabled(!this.isConnected() && this.isAuthenticated())
          .opacity(!this.isConnected() && this.isAuthenticated() ? 1 : 0.4)
          .onChange((enabled: boolean) => this.setNetworkSetting('corpDNS', enabled))
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
          .enabled(!this.isConnected() && this.isAuthenticated())
          .opacity(!this.isConnected() && this.isAuthenticated() ? 1 : 0.4)
          .onChange((enabled: boolean) =>
            this.setNetworkSetting('exitNodeAllowLANAccess', enabled))
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

  @Builder
  private ExitNodeChoiceButton(label: ResourceStr, nodeId: string, selected: boolean,
    enabled: boolean, action: () => void) {
    Button() {
      Row({ space: 12 }) {
        Text(label)
          .fontSize(14)
          .fontColor(enabled ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Start)
        if (selected) {
          SymbolGlyph($r('sys.symbol.checkmark_circle'))
            .fontSize(22)
            .fontColor([$r('sys.color.icon_emphasize')])
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
    }
    .id(nodeId)
    .width('100%')
    .height(52)
    .type(ButtonType.Normal)
    .borderRadius(20)
    .backgroundColor(selected ? '#14126BFF' : this.secondaryBackground())
    .backgroundEffect({
      radius: this.glowRadius(),
      saturation: this.glowSaturation(),
      brightness: this.glowBrightness(),
      color: this.glowSurface(),
      adaptiveColor: AdaptiveColor.DEFAULT
    }, { disableSystemAdaptation: false })
    .visualEffect(new hdsEffect.HdsEffectBuilder()
      .pressShadow(hdsEffect.PressShadowType.BLEND_WHITE)
      .buildEffect())
    .enabled(enabled)
    .opacity(enabled ? 1 : 0.45)
    .stateEffect(true)
    .onClick(action)
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
      this.setExitNode('');
      return;
    }
    const choices: ExitNodeChoice[] = this.selectableExitNodes();
    if (index - 1 < choices.length) {
      this.setExitNode(choices[index - 1].id);
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
        .id('exit-node-status')
        .selected(this.selectedExitNodeIndex())
        .value(this.selectedExitNodeLabel())
        .controlSize(ControlSize.NORMAL)
        .font({ size: 12 })
        .optionFont({ size: 12 })
        .selectedOptionFont({ size: 12 })
        .constraintSize({ minWidth: 104, maxWidth: this.layoutWidth >= 600 ? 240 : 144 })
        .enabled(this.isAuthenticated() && this.exitNodes.length > 0 &&
          !this.isConnected() && !this.isConnecting() && !this.connectInProgress)
        .opacity(this.isAuthenticated() && this.exitNodes.length > 0 &&
          !this.isConnected() && !this.isConnecting() && !this.connectInProgress ? 1 : 0.55)
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
    }
    .width('100%')
    .layoutWeight(1)
    .constraintSize({ minHeight: 160 })
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
    }
    .width('100%')
    .layoutWeight(1)
    .constraintSize({ minHeight: 160 })
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
      Stack({ alignContent: Alignment.BottomEnd }) {
        Image(this.localDeviceIcon())
          .width(22)
          .height(22)
          .fillColor($r('sys.color.icon_primary'))
        Row()
          .width(8)
          .height(8)
          .borderRadius(4)
          .border({ width: 2, color: this.groupBackground() })
          .backgroundColor(this.connectionColor())
      }
      .width(36)
      .height(36)
      .padding(7)
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
          Text('· HarmonyOS')
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
        Stack({ alignContent: Alignment.BottomEnd }) {
          Image(this.peerDeviceIcon(peer.deviceType))
            .width(22)
            .height(22)
            .fillColor($r('sys.color.icon_primary'))
          Row()
            .width(8)
            .height(8)
            .borderRadius(4)
            .border({ width: 2, color: this.groupBackground() })
            .backgroundColor(peer.online ? $r('app.color.status_success') :
              $r('app.color.status_offline'))
        }
        .width(36)
        .height(36)
        .padding(7)
        .borderRadius(11)
        .backgroundColor(this.secondaryBackground())
        Column({ space: 1 }) {
          Text(peer.name)
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
            .maxLines(this.isPeerNameExpanded(peer.key) ? 6 : 2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .wordBreak(WordBreak.BREAK_ALL)
            .width('100%')
            .onClick(() => this.togglePeerName(peer.key))
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
          .onClick(() => this.togglePeerName(peer.key))
      }
      .width('100%')
      .constraintSize({ minHeight: 52 })
      .padding({ top: 6, right: 12, bottom: 6 })
      if (this.isPeerNameExpanded(peer.key)) {
        Column({ space: 8 }) {
          Row({ space: 0 }) {
            this.PeerActionSegment(
              this.peerConnectivityInProgress && this.peerConnectivityKey === peer.key ?
                $r('app.string.peer_connectivity_testing') :
                $r('app.string.peer_connectivity_action'),
              'peer-connectivity-' + peer.key,
              peer.online && !this.peerConnectivityInProgress,
              this.peerConnectivityInProgress && this.peerConnectivityKey === peer.key,
              () => this.startPeerConnectivity(peer))
            Divider()
              .vertical(true)
              .height(18)
              .color($r('sys.color.comp_divider'))
            this.PeerActionSegment($r('app.string.peer_copy_dns'), 'peer-copy-dns-' + peer.key,
              peer.name.length > 0, false,
              () => this.copyDeviceValue(peer.name, $r('app.string.peer_dns_copied')))
            Divider()
              .vertical(true)
              .height(18)
              .color($r('sys.color.comp_divider'))
            this.PeerActionSegment($r('app.string.peer_copy_ip'), 'peer-copy-ip-' + peer.key,
              peer.addresses.length > 0, false,
              () => this.copyDeviceValue(this.primaryTailscaleAddress(peer.addresses),
                $r('app.string.peer_ip_copied')))
          }
          .width('100%')
          .height(36)
          .alignItems(VerticalAlign.Center)
          .backgroundColor(this.secondaryBackground())
          .borderRadius(18)
          .clip(true)

          if (this.peerConnectivityKey === peer.key && !this.peerConnectivityInProgress &&
            this.peerConnectivityResult.state.length > 0) {
            if (this.peerConnectivityResult.state === 'reachable' ||
              this.peerConnectivityResult.state === 'degraded') {
              Text($r('app.string.peer_connectivity_summary',
                this.peerConnectivityResult.received, this.peerConnectivityResult.sent,
                this.peerConnectivityResult.avgLatencyMs, this.peerConnectivityResult.lossPercent))
                .id('peer-connectivity-result-success')
                .fontSize(12)
                .fontColor(this.peerConnectivityResult.state === 'reachable' ?
                  $r('app.color.status_success') : $r('sys.color.font_secondary'))
                .width('100%')
              Text($r('app.string.peer_connectivity_latency_range',
                this.peerConnectivityResult.minLatencyMs, this.peerConnectivityResult.maxLatencyMs))
                .fontSize(11)
                .fontColor($r('sys.color.font_secondary'))
                .width('100%')
            } else {
              Text(this.peerConnectivityReason(this.peerConnectivityResult.reason))
                .id('peer-connectivity-result-error')
                .fontSize(12)
                .fontColor(this.peerConnectivityResult.state === 'failed' ?
                  $r('app.color.status_error') : $r('sys.color.font_secondary'))
                .width('100%')
            }
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 46, right: 12, bottom: 10 })
      }
    }
    .width('100%')
  }

  @Builder
  private DevicesPanel() {
    Column({ space: 0 }) {
      this.SectionHeader($r('app.string.devices_title'),
        $r('app.string.devices_count', this.onlinePeerCount() + (this.isConnected() ? 1 : 0),
          this.peers.length + 1))
      Text('')
        .id('peer-summary')
        .height(4)
        .fontSize(1)
        .accessibilityLevel('no')
      List() {
        ListItem() {
          this.LocalDeviceRow()
        }
        LazyForEach(this.peerDataSource, (peer: PeerSummary) => {
          ListItem() {
            this.PeerDeviceRow(peer)
          }
        // onDataReloaded reuses the original child whenever its key is unchanged.
        // Include the rendered peer snapshot so live online/key/route changes
        // replace only the affected row instead of leaving its old object cached.
        }, (peer: PeerSummary) => JSON.stringify(peer))
      }
      .width('100%')
      .layoutWeight(1)
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(this.peers.length + 1 > 3 ? BarState.Auto : BarState.Off)
      .scrollBarWidth(3)
      .cachedCount(5)
    }
    .width('100%')
    .layoutWeight(1)
    .constraintSize({ minHeight: 160 })
    .padding({ left: 16, right: 4, top: 14, bottom: 10 })
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
    .clip(true)
    .animation({ duration: 260, curve: Curve.EaseInOut })
  }

  @Builder
  private GlowSettingsPanel() {
    Row({ space: 10 }) {
      Text($r('app.string.glow_title'))
        .id('settings-page-title')
        .fontSize(14)
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
        .controlSize(ControlSize.NORMAL)
        .constraintSize({ minWidth: 112, maxWidth: 160 })
        .onSelect((index: number, _value?: string) => this.setGlowLevel(index))
    }
    .id('glow-settings')
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding(14)
    .backgroundColor(this.groupBackground())
    .borderRadius(14)
  }

  @Builder
  private AccountPanel() {
    Column({ space: 8 }) {
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
          .fontSize(13)
          .enabled(!this.isConnected() && !this.isConnecting())
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
      .constraintSize({ maxHeight: this.controlServerEditorVisible ? 360 : 0 })
      .opacity(this.controlServerEditorVisible ? 1 : 0)
      .clip(true)
      .animation({ duration: 320, curve: Curve.EaseInOut })

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
              type: ButtonType.Capsule,
              stateEffect: true,
              buttonStyle: ButtonStyleMode.EMPHASIZED,
              controlSize: ControlSize.NORMAL
            }) {
              this.ButtonContent($r('app.string.action_login'), true, this.loginInProgress)
            }
              .id('account-login')
              .height(48)
              .layoutWeight(1)
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
              .width(48)
              .height(48)
              .visualEffect(new hdsEffect.HdsEffectBuilder()
                .pressShadow(hdsEffect.PressShadowType.BLEND_WHITE)
                .buildEffect())
              .onClick(() => this.toggleControlServerEditor())
          }
        }
        .width('100%')
      } else {
        Row({ space: 12 }) {
          Stack() {
            if (this.accountSummary.profilePicURL.length > 0 && !this.avatarLoadFailed) {
              Image(this.accountSummary.profilePicURL)
                .id('account-avatar')
                .width(48)
                .height(48)
                .borderRadius(24)
                .objectFit(ImageFit.Cover)
                .onError(() => {
                  this.avatarLoadFailed = true;
                })
            } else {
              Text(this.accountInitial())
                .fontSize(22)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_emphasize'))
            }
          }
          .width(48)
          .height(48)
          .borderRadius(24)
          .backgroundColor(this.secondaryBackground())

          Column({ space: 2 }) {
            Text(this.accountSummary.displayName)
              .id('account-display-name')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(this.accountSummary.loginName)
              .id('account-login-name')
              .fontSize(13)
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
          this.accountSummary.deviceName, 'account-device')

        if (!this.isConnected()) {
          Text($r('app.string.logout_description'))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
          Button($r('app.string.logout_action'), {
            type: ButtonType.ROUNDED_RECTANGLE,
            stateEffect: true,
            buttonStyle: ButtonStyleMode.NORMAL,
            controlSize: ControlSize.NORMAL,
            role: ButtonRole.ERROR
          })
            .id('logout-open')
            .width('100%')
            .visualEffect(new hdsEffect.HdsEffectBuilder()
              .pressShadow(hdsEffect.PressShadowType.BLEND_WHITE)
              .buildEffect())
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
    .padding(14)
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
    .constraintSize({ minHeight: 38 })
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
    .onClick(() => this.onAppVersionTap())
  }

  @Builder
  private VersionPanel() {
    Column({ space: 0 }) {
      this.AppVersionActionRow()
      this.AccountDetailRow($r('app.string.tailscale_version_label'),
        this.tailscaleVersion, 'tailscale-version')
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
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
        .width('100%')
      Text(value)
        .id(nodeId)
        .fontSize(13)
        .fontColor(value.startsWith('FAILED') ?
          $r('app.color.status_error') : $r('sys.color.font_primary'))
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }

  @Builder
  private DiagnosticsPanel() {
    Column({ space: 8 }) {
      this.DiagnosticStatus('Go Bridge', this.nativeStatus, 'smoke-go-status')
      Divider().color($r('sys.color.comp_divider'))
      this.DiagnosticStatus('Tailscale Engine', this.engineStatus, 'engine-status')
      Divider().color($r('sys.color.comp_divider'))
      this.DiagnosticStatus('Control Plane', this.backendStatus, 'backend-status')
      Divider().color($r('sys.color.comp_divider'))
      this.DiagnosticStatus('VPN Extension', this.vpnStatus, 'vpn-status')
      Divider().color($r('sys.color.comp_divider'))
      this.DiagnosticStatus('MagicDNS', this.magicDNSProbeStatus, 'magicdns-status')

      this.StandardActionButton('Refresh status', 'backend-refresh', false, true, () => {
        this.verifyNativeBridge();
        this.refreshBackendStatus();
        this.refreshVpnProbeStatus();
      })
      this.StandardActionButton('Probe engine', 'engine-probe', false, true,
        () => this.probeUserspaceEngine())
      this.StandardActionButton('Probe control TLS', 'control-probe', false,
        this.controlServerConfirmed && this.controlServerURL === DEFAULT_CONTROL_SERVER_URL,
        () => this.runControlProbe())
      this.StandardActionButton('Open MagicDNS probe', 'magicdns-probe', false,
        this.magicDNSProbeUrl.startsWith('http://'), () => this.runMagicDNSProbe())
      Divider().color($r('sys.color.comp_divider'))
      Text($r('app.string.diagnostic_first_run_tools_description'))
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
        .lineHeight(18)
        .width('100%')
      this.StandardActionButton($r('app.string.diagnostic_reset_first_run_action'),
        'diagnostic-reset-first-run', false, !this.diagnosticActionInProgress,
        () => this.confirmResetFirstRun())
      this.StandardActionButton($r('app.string.diagnostic_force_vpn_stop_action'),
        'diagnostic-force-vpn-stop', false, !this.diagnosticActionInProgress,
        () => this.forceStopSystemVpn())
      if (this.diagnosticActionStatus.length > 0) {
        this.DiagnosticStatus($r('app.string.diagnostic_action_status'),
          this.diagnosticActionStatus, 'diagnostic-action-status')
      }
      Divider().color($r('sys.color.comp_divider'))
      Text($r('app.string.diagnostic_report_description'))
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
        .lineHeight(18)
        .width('100%')
      if (this.diagnosticReportStatus.length > 0) {
        this.DiagnosticStatus($r('app.string.diagnostic_report_title'),
          this.diagnosticReportStatus, 'diagnostic-report-status')
      }
      this.StandardActionButton($r('app.string.diagnostic_report_action'),
        'diagnostic-report-generate', true, !this.diagnosticReportInProgress,
        () => this.generateDiagnosticReport(), this.diagnosticReportInProgress)
    }
    .width('100%')
    .padding({ left: 14, right: 14, bottom: 14 })
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
        this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseInOut }, () => {
          this.diagnosticsExpanded = !this.diagnosticsExpanded;
        });
      })

      if (this.diagnosticsExpanded) {
        Divider()
          .color($r('sys.color.comp_divider'))
          .margin({ left: 16, right: 16 })
        this.DiagnosticsPanel()
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
    Column({ space: 12 }) {
      this.ConnectionPanel()
      this.ExitNodePanel()
      if (this.isBackendLoading() || this.devicesLoading) {
        this.DevicesLoadingPanel()
      } else if (!this.isAuthenticated()) {
        this.DevicesSignedOutPanel()
      } else {
        this.DevicesPanel()
      }
    }
    .width('100%')
    .height('100%')
    .constraintSize({ maxWidth: 1200 })
    .padding({
      left: this.contentMargin(),
      right: this.contentMargin(),
      top: 8,
      bottom: this.pageBottomInset()
    })
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('sys.color.background_secondary'))
  }

  @Builder
  private TransferOverviewPanel() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.doc'))
            .fontSize(26)
            .fontColor([$r('sys.color.icon_emphasize')])
        }
        .width(44)
        .height(44)
        .borderRadius(14)
        .backgroundColor($r('sys.color.comp_background_tertiary'))

        Column({ space: 3 }) {
          Text($r('app.string.transfer_taildrop_title'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .width('100%')
          Text($r('app.string.transfer_taildrop_description'))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .lineHeight(18)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Divider()
        .color($r('sys.color.comp_divider'))

      Row({ space: 10 }) {
        if (this.isConnected() && this.taildropState === 'ready') {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(18)
            .fontColor([$r('sys.color.icon_emphasize')])
        } else {
          SymbolGlyph($r('sys.symbol.clock'))
            .fontSize(18)
            .fontColor([$r('sys.color.icon_secondary')])
        }
        Column({ space: 2 }) {
          Text(this.taildropStatusTitle())
            .id('taildrop-status-title')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .width('100%')
          Text(this.taildropStatusDescription())
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .lineHeight(18)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
  }

  @Builder
  private TaildropTargetRow(target: TaildropTargetSummary) {
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

      Text(target.online ? $r('app.string.transfer_send_action') : $r('app.string.peer_offline'))
        .fontSize(11)
        .fontColor(target.online ? $r('app.color.status_success') :
          $r('sys.color.font_secondary'))
    }
    .id('taildrop-target-' + target.key)
    .width('100%')
    .constraintSize({ minHeight: 54 })
    .padding({ left: 12, right: 12 })
    .opacity(target.online && !this.taildropSendActive() ? 1 : 0.62)
    .onClick(() => {
      if (target.online && !this.taildropSendActive()) {
        this.startTaildropSelection(target);
      }
    })
  }

  @Builder
  private TaildropTargetsPanel() {
    Column({ space: 0 }) {
      ForEach(this.taildropTargets, (target: TaildropTargetSummary, index: number) => {
        if (index > 0) {
          Divider()
            .color($r('sys.color.comp_divider'))
            .margin({ left: 62 })
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
    Text(this.taildropState === 'disabled' ?
      $r('app.string.transfer_admin_disabled_description') :
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
  private TaildropActiveSendPanel() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        if (this.taildropPreparing || this.taildropTransfer.state === 'queued') {
          LoadingProgress()
            .width(20)
            .height(20)
            .color($r('sys.color.icon_emphasize'))
        } else {
          SymbolGlyph($r('sys.symbol.doc'))
            .fontSize(20)
            .fontColor([$r('sys.color.icon_emphasize')])
        }
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
          Button($r('app.string.cancel_action'))
            .fontSize(12)
            .height(32)
            .backgroundColor(this.secondaryBackground())
            .fontColor($r('sys.color.font_primary'))
            .onClick(() => this.cancelTaildropSend())
        }
      }
      .width('100%')
      Progress({ value: this.taildropTransferProgress(), total: 100, type: ProgressType.Linear })
        .width('100%')
        .height(4)
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
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
  }

  @Builder
  private TaildropActiveReceivePanel() {
    Row({ space: 10 }) {
      LoadingProgress()
        .width(20)
        .height(20)
        .color($r('sys.color.icon_emphasize'))
      Column({ space: 2 }) {
        Text(this.taildropReceive.action === 'clear' ?
          $r('app.string.transfer_clearing_cache') : $r('app.string.transfer_receiving_file'))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
        if (this.taildropReceive.name.length > 0) {
          Text(this.taildropReceive.name)
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
  }

  @Builder
  private TaildropWaitingFileRow(file: TaildropWaitingFileSummary) {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.doc'))
        .fontSize(22)
        .fontColor([$r('sys.color.icon_emphasize')])
      Column({ space: 2 }) {
        Text(file.name)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.formatTrafficBytes(file.size))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text($r('app.string.transfer_save_action'))
        .fontSize(12)
        .fontColor($r('sys.color.icon_emphasize'))
    }
    .width('100%')
    .constraintSize({ minHeight: 54 })
    .padding({ left: 12, right: 12 })
    .opacity(this.taildropSendActive() ? 0.62 : 1)
    .onClick(() => {
      if (!this.taildropSendActive()) {
        this.startTaildropReceive(file);
      }
    })
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
      }, (file: TaildropWaitingFileSummary) => JSON.stringify(file))
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
  }

  @Builder
  private TaildropHistoryRow(record: TaildropTransferRecord) {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.doc'))
        .fontSize(21)
        .fontColor([record.state === 'completed' ? $r('sys.color.icon_emphasize') :
          $r('sys.color.icon_secondary')])
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
          .fontColor(record.state === 'completed' ? $r('app.color.status_success') :
            $r('sys.color.font_secondary'))
        if (record.direction === 'send' && record.state === 'failed') {
          Text($r('app.string.transfer_retry_action'))
            .fontSize(11)
            .fontColor($r('sys.color.icon_emphasize'))
        }
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .constraintSize({ minHeight: 58 })
    .padding({ left: 12, right: 12 })
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
  private TransferContent() {
    Scroll(this.transferScroller) {
      Column({ space: 14 }) {
        this.TransferOverviewPanel()
        if (this.taildropPreparing || this.taildropTransfer.state === 'queued' ||
          this.taildropTransfer.state === 'sending') {
          this.TaildropActiveSendPanel()
        }
        if (this.taildropReceiveInProgress) {
          this.TaildropActiveReceivePanel()
        }
        if (this.isConnected() && (this.taildropState === 'ready' || this.taildropState === 'disabled')) {
          Column({ space: 8 }) {
            Text($r('app.string.transfer_targets_title'))
              .id('transfer-page-title')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
              .padding({ left: 4 })
            if (this.taildropTargets.length > 0) {
              this.TaildropTargetsPanel()
            } else {
              this.TaildropTargetsEmptyPanel()
            }
          }
          .width('100%')
          if (this.taildropState === 'ready') {
            Column({ space: 8 }) {
              Row() {
                Text($r('app.string.transfer_inbox_title'))
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('sys.color.font_secondary'))
                Blank()
                Text($r('app.string.transfer_clear_cache_action'))
                  .fontSize(12)
                  .fontColor($r('sys.color.icon_emphasize'))
                  .opacity(this.taildropSendActive() ? 0.45 : 1)
                  .onClick(() => this.confirmClearTaildropInboxCache())
              }
              .width('100%')
              .padding({ left: 4, right: 4 })
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
          }
        }
        Column({ space: 8 }) {
          Row() {
            Text($r('app.string.transfer_history_title'))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_secondary'))
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
          .padding({ left: 4, right: 4 })
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
      .constraintSize({ maxWidth: 1200 })
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
    .backgroundColor($r('sys.color.background_secondary'))
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Auto)
    .scrollBarWidth(4)
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
            this.SettingsGroupHeader($r('app.string.account_title'))
          }
          GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
            this.AccountPanel()
          }
          GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
            this.SettingsGroupHeader($r('app.string.settings_title'))
          }
          GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
            this.NetworkSettingsPanel()
          }
          GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
            this.SettingsGroupHeader($r('app.string.settings_appearance_title'))
          }
          GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
            this.GlowSettingsPanel()
          }
          GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
            this.SettingsGroupHeader($r('app.string.about_title'))
          }
          GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
            this.VersionPanel()
          }
          if (this.diagnosticsUnlocked) {
            GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
              this.DiagnosticsDisclosure()
            }
          }
        }
        .width('100%')
        .constraintSize({ maxWidth: 1200 })
      }
      .width('100%')
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
    .backgroundColor($r('sys.color.background_secondary'))
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Auto)
    .scrollBarWidth(4)
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
        title: {
          mainTitle: $r('app.string.app_title'),
          subTitle: $r('app.string.app_tagline')
        }
      }
    })
    .titleMode(HdsNavigationTitleMode.FULL)
    .hideBackButton(true)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
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
    .titleMode(HdsNavigationTitleMode.FREE)
    .bindToScrollable([this.settingsScroller])
    .hideBackButton(true)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
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
    .backgroundColor($r('sys.color.background_secondary'))
  }

  @Builder
  private SettingsTabBar() {
    Column({ space: 2 }) {
      Image($r('app.media.tab_settings'))
        .width(24)
        .height(24)
        .fillColor(this.currentTab === 2 ? $r('sys.color.icon_emphasize') :
          $r('sys.color.icon_secondary'))
      Text($r('app.string.tab_settings'))
        .fontSize(10)
        .fontColor(this.currentTab === 2 ? $r('sys.color.font_emphasize') :
          $r('sys.color.font_secondary'))
        .maxLines(1)
    }
    .id('tab-settings')
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .bindPopup(this.controlServerTipVisible, {
      message: this.controlServerTipMessage,
      placement: Placement.Top,
      enableArrow: true,
      autoCancel: true,
      mask: false,
      width: 252,
      popupColor: this.glowSurface(),
      backgroundBlurStyle: BlurStyle.COMPONENT_REGULAR,
      onStateChange: (event: ControlServerTipStateChange) => {
        if (!event.isVisible && this.controlServerTipVisible) {
          this.controlServerTipVisible = false;
          this.recordDiagnosticEvent('control_server_tip_dismissed', 'message');
        }
      }
    })
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
      .tabBar(this.SettingsTabBar())
    }
    .vertical(false)
    .scrollable(true)
    .animationDuration(320)
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
      // HdsTabs emits onSelected when the swipe transition starts and
      // onChange after it completes. Writing the controlled index here makes
      // the component jump straight to the destination and cancels the
      // interactive page animation.
      if (index === 2 && this.controlServerTipVisible) {
        this.controlServerTipVisible = false;
        this.recordDiagnosticEvent('control_server_tip_dismissed', 'settings_opened');
      }
    })
    .onChange((index: number) => {
      this.currentTab = index;
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
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      try {
        await vpnExtension.stopVpnExtensionAbility(this.vpnWant());
      } catch (_vpnError) {
        // A stopped extension is already in the desired state.
      }
      try {
        await nativeBridge.backendStopAsync();
      } catch (_backendError) {
        // Continue with cleanup when no in-process backend exists.
      }
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 300));
      if (!ControlServerConfig.reset(context.filesDir)) {
        throw new Error('first-run reset failed');
      }
      this.controlServerURL = DEFAULT_CONTROL_SERVER_URL;
      this.controlServerInput = DEFAULT_CONTROL_SERVER_URL;
      this.controlServerConfirmed = false;
      this.controlServerStatus = '';
      this.controlServerEditorVisible = true;
      this.controlServerTipVisible = false;
      this.backendStatus = 'Tailscale Backend Stopped | control server not configured';
      this.vpnStatus = 'HarmonyOS VPN Extension stopped';
      this.backendReady = true;
      this.backendInitializationVisible = false;
      this.devicesLoading = false;
      this.hasAuthenticatedSession = false;
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
      this.scheduleLifecycleTask(() => this.showControlServerTip(), 700);
    } catch (_error) {
      this.diagnosticActionStatus = context.resourceManager.getStringSync(
        $r('app.string.diagnostic_reset_first_run_failed').id);
      this.recordDiagnosticEvent('diagnostic_first_run_reset_failed', 'diagnostics');
    } finally {
      this.diagnosticActionInProgress = false;
    }
  }

  private async forceStopSystemVpn(): Promise<void> {
    if (this.diagnosticActionInProgress) {
      return;
    }
    this.diagnosticActionInProgress = true;
    this.diagnosticActionStatus = '';
    this.recordDiagnosticEvent('diagnostic_vpn_cut_requested', 'diagnostics');
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      await vpnExtension.stopVpnExtensionAbility(this.vpnWant());
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
      const businessError = error as BusinessError;
      this.diagnosticActionStatus = context.resourceManager.getStringSync(
        $r('app.string.diagnostic_force_vpn_stop_failed').id);
      this.recordDiagnosticEvent('diagnostic_vpn_cut_failed', 'diagnostics', businessError.code ?? -1);
    } finally {
      this.diagnosticActionInProgress = false;
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
    .animationDuration(280)
    .barMode(BarMode.Fixed)
    .barWidth(96)
    .barOverlap(false)
    .barBackgroundColor($r('sys.color.comp_background_primary'))
    .divider({ mode: DividerMode.NONE })
    .onChange((index: number) => {
      this.currentTab = index;
    })
    .width('100%')
    .height('100%')
  }

  build() {
    Stack() {
      if (this.isWideNavigation()) {
        this.WideTabs()
      } else {
        this.MobileTabs()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      this.layoutWidth = Number(newValue.width);
    })
  }
}
