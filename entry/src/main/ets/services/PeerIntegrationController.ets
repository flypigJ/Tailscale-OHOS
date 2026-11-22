import { common, Want } from '@kit.AbilityKit';
import { BusinessError, systemDateTime } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import {
  AccountDiagnosticsGateway,
  AccountDiagnosticsRequestGuard
} from './AccountDiagnosticsGateway';
import {
  FileTransferPreferences,
  LocalSendPortOverride
} from './FileTransferPreferences';
import { HosPlayerLauncher } from './HosPlayerLauncher';
import {
  DiscoveredMediaService,
  HosPlayerLaunchRequest,
  MediaProbeResult
} from './MediaIntegrationModels';
import { MediaServiceProbeService } from './MediaServiceProbeService';
import { MoonlightLauncher } from './MoonlightLauncher';
import { PeerPathService } from './PeerPathService';
import { buildStreamProfile } from './StreamProfileBuilder';
import {
  MoonlightLaunchRequest,
  PeerPathResult,
  StreamLaunchProfile,
  SunshineProbeResult
} from './StreamingModels';
import { SunshineProbeService } from './SunshineProbeService';
import { VpnCommandGateway } from './VpnCommandGateway';
import {
  LOCAL_SEND_REFRESH_REQUEST_FILE_NAME,
  LOCAL_SEND_REFRESH_RESPONSE_FILE_NAME,
  LocalSendRefreshRequest,
  LocalSendRefreshResponse,
  PeerSummary
} from '@tailscale/common';

// Native refresh has a 15-second budget; allow its following peer snapshot
// to finish before a later UI refresh can replace the command/response files.
const LOCAL_SEND_REFRESH_TIMEOUT_MS: number = 25000;
export const DEFAULT_LOCAL_SEND_PORT: number = 53317;

export interface LocalSendAppTarget {
  bundleName: string;
  moduleName: string;
  abilityName: string;
}

export const LOCAL_SEND_APP_TARGETS: LocalSendAppTarget[] = [
  {
    bundleName: 'cn.biandangroup.bcshare',
    moduleName: 'entry',
    abilityName: 'EntryAbility'
  }
];

export interface DeviceStreamingState {
  peerKey: string;
  sunshine: SunshineProbeResult;
  path: PeerPathResult;
  checking: boolean;
  launching: boolean;
}

export interface DeviceMediaState {
  peerKey: string;
  result: MediaProbeResult;
  checking: boolean;
  launching: boolean;
}

export interface MediaProbeSelfTestResult {
  state: string;
  cases: number;
  errorMessage?: string;
}

export interface RemoteStreamLaunchIntent {
  peerKey: string;
  host: string;
  generation: number;
  navigationRevision: number;
  fromDetail: boolean;
  detailPresentationId: number;
  probeRequestId: number;
  launchRequested: boolean;
}

export type PeerIntegrationToastKey =
  | 'transfer_tailscale_network_not_connected'
  | 'transfer_remote_port_invalid'
  | 'transfer_remote_port_saved'
  | 'transfer_localsend_open_failed'
  | 'peer_service_connect_and_online_toast'
  | 'stream_connect_required_toast'
  | 'stream_target_offline_toast'
  | 'stream_sunshine_probe_error_toast'
  | 'stream_path_probe_timeout_toast'
  | 'stream_sunshine_timeout_toast'
  | 'stream_sunshine_unavailable_toast'
  | 'stream_sunshine_failed_toast'
  | 'stream_target_unreachable_toast'
  | 'stream_moonlight_open_failed_toast'
  | 'hosplayer_open_failed_toast'
  | 'hosplayer_unsafe_endpoint_toast'
  | 'hosplayer_import_link_failed_toast';

export type MediaSelfTestStatusKind = 'running' | 'passed' | 'failed_export' | 'unavailable';

export function selectPrimaryTailscaleAddress(addresses: string[]): string {
  const ipv4Address: string | undefined = addresses.find((address: string) =>
    !address.includes(':'));
  if (ipv4Address !== undefined) {
    return ipv4Address;
  }
  return addresses.length > 0 ? addresses[0] : '';
}

export function isPeerSunshineCandidate(peer: PeerSummary): boolean {
  if (!peer.online || peer.addresses.length === 0) {
    return false;
  }
  const os: string = peer.os.toLowerCase();
  return os.includes('windows') || os.includes('linux') || os.includes('macos') || os.includes('darwin');
}

export function formatPeerDisplayName(name: string): string {
  const cleaned: string = name.replace(/[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, '');
  if (!cleaned.toLowerCase().endsWith('.ts.net')) {
    return cleaned;
  }
  const firstDot: number = cleaned.indexOf('.');
  return firstDot > 0 ? cleaned.substring(0, firstDot) : cleaned;
}

export interface PeerIntegrationDependencies {
  vpnCommandGateway?: VpnCommandGateway;
  accountDiagnosticsGateway?: AccountDiagnosticsGateway;
  diagnosticMediaRequestGuard?: AccountDiagnosticsRequestGuard;
  sunshineProbeService?: SunshineProbeService;
  peerPathService?: PeerPathService;
  moonlightLauncher?: MoonlightLauncher;
  mediaServiceProbeService?: MediaServiceProbeService;
  hosPlayerLauncher?: HosPlayerLauncher;
  getMonotonicUptimeMs?: () => number;
}

export interface PeerIntegrationHost {
  getAbilityContext: () => common.UIAbilityContext;
  getFilesDir: () => string;
  getLifecycleGeneration: () => number;
  getNavigationRevision: () => number;
  getTrafficSession: () => number;
  isAppShellReady: () => boolean;
  isRemoteStreamAppInForeground: () => boolean;
  setRemoteStreamAppInForeground: (inForeground: boolean) => void;
  isAppLockRequired: () => boolean;
  isAppLockAuthenticating: () => boolean;
  isConnected: () => boolean;

  getPeers: () => PeerSummary[];
  peerEffectivelyOnline: (peer: PeerSummary) => boolean;
  getSelectedPeerKey: () => string;
  isDeviceDetailVisible: () => boolean;
  setDeviceDetailVisible: (visible: boolean) => void;
  getDeviceDetailPresentationId: () => number;
  isDeviceDetailServiceRefreshInFlight: () => boolean;
  setDeviceDetailServiceRefreshInFlight: (inFlight: boolean) => void;
  isTransferProtocolRefreshing: () => boolean;
  setTransferProtocolRefreshing: (refreshing: boolean) => void;

  getStreamingStates: () => DeviceStreamingState[];
  setStreamingStates: (states: DeviceStreamingState[]) => void;
  getMediaStates: () => DeviceMediaState[];
  setMediaStates: (states: DeviceMediaState[]) => void;
  isFakeMediaServiceOnline: () => boolean;
  getFakeJellyfinName: () => string;

  isMediaSelfTestInProgress: () => boolean;
  setMediaSelfTestInProgress: (inProgress: boolean) => void;
  setMediaSelfTestStatusKind: (kind: MediaSelfTestStatusKind) => void;

  getLocalSendPortOverrides: () => LocalSendPortOverride[];
  setLocalSendPortOverrides: (overrides: LocalSendPortOverride[]) => void;
  getRemotePortPeerKey: () => string;
  getRemotePortInput: () => string;
  setRemotePortEditorVisible: (visible: boolean) => void;
  setTaildropFocusedTargetKey: (key: string) => void;
  getTaildropFocusedTargetKey: () => string;

  refreshBackendStatus: () => Promise<void>;
  refreshPeerSnapshot: () => void;
  refreshTaildropSnapshot: (connected?: boolean) => void;
  logServiceStatusIfChanged: () => void;
  scheduleLifecycleTask: (task: () => void, delayMs: number) => number;
  showPeerIntegrationToast: (key: PeerIntegrationToastKey) => void;
  showDerpStreamConfirmationDialog: (
    peer: PeerSummary,
    state: DeviceStreamingState,
    intent: RemoteStreamLaunchIntent
  ) => void;
  showMoonlightRequiredDialog: (hostAddress: string) => void;
  copyHosPlayerPrototypeText: (prototypeLink: string) => void;
  recordDiagnosticEvent: (event: string, phase: string, code?: number) => void;
  recordFeatureDiagnosticEvent: (event: string, phase: string, code?: number) => void;
}

/**
 * Deep module owning peer service discovery (`SunshineProbeService`,
 * `MediaServiceProbeService`, `PeerPathService`), LocalSend refresh IPC &
 * explicit ability launch, Moonlight remote-stream launch state machine, and
 * HosPlayer media launch / offline self-test behind `PeerIntegrationHost`.
 */
export class PeerIntegrationController {
  private readonly host: PeerIntegrationHost;
  readonly vpnCommandGateway: VpnCommandGateway;
  readonly accountDiagnosticsGateway: AccountDiagnosticsGateway;
  readonly diagnosticMediaRequestGuard: AccountDiagnosticsRequestGuard;
  private readonly getMonotonicUptimeMsFn: () => number;

  sunshineProbeService?: SunshineProbeService;
  peerPathService?: PeerPathService;
  moonlightLauncher?: MoonlightLauncher;
  mediaServiceProbeService?: MediaServiceProbeService;
  hosPlayerLauncher?: HosPlayerLauncher;

  readonly streamingRequestIds: Map<string, number> = new Map();
  readonly mediaRequestIds: Map<string, number> = new Map();
  readonly peerServiceRefreshInFlight: Set<string> = new Set();
  readonly peerServiceRefreshOwners: Map<string, number> = new Map();
  readonly autoSunshineFailureCounts: Map<string, number> = new Map();
  readonly autoMediaFailureCounts: Map<string, number> = new Map();
  readonly autoProbedPeerSessions: Map<string, number> = new Map();

  peerProbeRequestSequence: number = 0;
  localSendRefreshRequestId: number = 0;
  localSendRefreshPromise?: Promise<void>;
  deviceDetailServiceRefreshRequestId: number = 0;
  homeLatencyRefreshInFlight: boolean = false;
  transferProtocolRefreshInFlight: boolean = false;
  transferProtocolManualRefreshQueued: boolean = false;
  remoteStreamLaunchIntent?: RemoteStreamLaunchIntent;

  constructor(host: PeerIntegrationHost, deps?: PeerIntegrationDependencies) {
    this.host = host;
    this.vpnCommandGateway = deps?.vpnCommandGateway ?? new VpnCommandGateway();
    this.accountDiagnosticsGateway = deps?.accountDiagnosticsGateway ?? new AccountDiagnosticsGateway();
    this.diagnosticMediaRequestGuard = deps?.diagnosticMediaRequestGuard ??
      new AccountDiagnosticsRequestGuard();
    this.sunshineProbeService = deps?.sunshineProbeService;
    this.peerPathService = deps?.peerPathService;
    this.moonlightLauncher = deps?.moonlightLauncher;
    this.mediaServiceProbeService = deps?.mediaServiceProbeService;
    this.hosPlayerLauncher = deps?.hosPlayerLauncher;
    this.getMonotonicUptimeMsFn = deps?.getMonotonicUptimeMs ??
      ((): number => systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false));
  }

  // --- Lifecycle & Peer Directory Transitions ---

  resetOnAppear(): void {
    this.diagnosticMediaRequestGuard.invalidate();
  }

  teardownOnDisappear(): void {
    this.diagnosticMediaRequestGuard.invalidate();
    this.streamingRequestIds.clear();
    this.mediaRequestIds.clear();
    this.peerServiceRefreshInFlight.clear();
    this.peerServiceRefreshOwners.clear();
    this.autoSunshineFailureCounts.clear();
    this.autoMediaFailureCounts.clear();
    this.host.getStreamingStates().forEach((state: DeviceStreamingState) => {
      this.sunshineProbeService?.cancel(state.peerKey);
      this.peerPathService?.cancel(state.peerKey);
    });
    this.host.getMediaStates().forEach((state: DeviceMediaState) => {
      this.mediaServiceProbeService?.cancel(state.peerKey);
    });
  }

  invalidatePeerPresence(peerKey: string): void {
    this.sunshineProbeService?.cancel(peerKey);
    this.peerPathService?.cancel(peerKey);
    this.mediaServiceProbeService?.cancel(peerKey);
    this.sunshineProbeService?.clearCache(peerKey);
    this.peerPathService?.clearCache(peerKey);
    this.mediaServiceProbeService?.clearCache(peerKey);
    this.streamingRequestIds.delete(peerKey);
    this.mediaRequestIds.delete(peerKey);
    this.peerServiceRefreshOwners.delete(peerKey);
    this.peerServiceRefreshInFlight.delete(peerKey);
    this.autoProbedPeerSessions.delete(peerKey);
    this.autoSunshineFailureCounts.delete(peerKey);
    this.autoMediaFailureCounts.delete(peerKey);
  }

  pruneOfflineServiceStates(mergedPeers: PeerSummary[]): void {
    this.host.setStreamingStates(this.host.getStreamingStates().filter((state: DeviceStreamingState) => {
      const peer: PeerSummary | undefined =
        mergedPeers.find((item: PeerSummary) => item.key === state.peerKey);
      return peer !== undefined && peer.online;
    }));
    this.host.setMediaStates(this.host.getMediaStates().filter((state: DeviceMediaState) => {
      const peer: PeerSummary | undefined =
        mergedPeers.find((item: PeerSummary) => item.key === state.peerKey);
      return peer !== undefined && peer.online;
    }));
  }

  ensureStreamingServices(): void {
    if (this.sunshineProbeService !== undefined && this.peerPathService !== undefined &&
      this.moonlightLauncher !== undefined) {
      return;
    }
    const context: common.UIAbilityContext = this.host.getAbilityContext();
    this.sunshineProbeService = new SunshineProbeService(context);
    this.peerPathService = new PeerPathService(context);
    this.moonlightLauncher = new MoonlightLauncher(context);
  }

  ensureMediaServices(): void {
    if (this.mediaServiceProbeService !== undefined && this.hosPlayerLauncher !== undefined) {
      return;
    }
    const context: common.UIAbilityContext = this.host.getAbilityContext();
    this.mediaServiceProbeService = new MediaServiceProbeService(context);
    this.hosPlayerLauncher = new HosPlayerLauncher(context);
  }

  private nextPeerProbeRequestId(): number {
    return ++this.peerProbeRequestSequence;
  }

  // --- LocalSend Refresh IPC, Port Overrides & Explicit Launch ---

  refreshTransferProtocolStatus(manual: boolean = true): void {
    if (!this.host.isAppShellReady()) {
      return;
    }
    if (this.transferProtocolRefreshInFlight) {
      if (manual) {
        this.transferProtocolManualRefreshQueued = true;
        this.host.setTransferProtocolRefreshing(true);
      }
      return;
    }
    this.host.refreshPeerSnapshot();
    this.transferProtocolRefreshInFlight = true;
    if (manual) {
      this.host.setTransferProtocolRefreshing(true);
    }
    const generation: number = this.host.getLifecycleGeneration();
    this.requestLocalSendRefresh().finally(() => {
      if (generation === this.host.getLifecycleGeneration() && this.host.isAppShellReady()) {
        this.host.refreshPeerSnapshot();
        if (!this.host.isConnected()) {
          void this.host.refreshBackendStatus();
        }
      }
      this.transferProtocolRefreshInFlight = false;
      if (this.transferProtocolManualRefreshQueued &&
        generation === this.host.getLifecycleGeneration() &&
        this.host.isAppShellReady()) {
        this.transferProtocolManualRefreshQueued = false;
        this.refreshTransferProtocolStatus(true);
        return;
      }
      if (manual) {
        this.host.setTransferProtocolRefreshing(false);
      }
    });
  }

  handleTransferProtocolRefreshClick(): void {
    if (!this.host.isConnected()) {
      this.host.showPeerIntegrationToast('transfer_tailscale_network_not_connected');
      return;
    }
    this.refreshTransferProtocolStatus(true);
  }

  async requestLocalSendRefresh(): Promise<void> {
    if (this.localSendRefreshPromise !== undefined) {
      await this.localSendRefreshPromise;
      return;
    }
    const refresh: Promise<void> = this.performLocalSendRefresh();
    this.localSendRefreshPromise = refresh;
    try {
      await refresh;
    } finally {
      if (this.localSendRefreshPromise === refresh) {
        this.localSendRefreshPromise = undefined;
      }
    }
  }

  async performLocalSendRefresh(): Promise<void> {
    if (!this.host.isConnected()) {
      await this.host.refreshBackendStatus();
      return;
    }
    let startedAt: number = 0;
    try {
      startedAt = this.getMonotonicUptimeMsFn();
    } catch (_error) {
      // Do not dispatch a request whose wait budget cannot be measured.
      return;
    }
    const withinDeadline = (): boolean => {
      try {
        return this.getMonotonicUptimeMsFn() - startedAt < LOCAL_SEND_REFRESH_TIMEOUT_MS;
      } catch (_error) {
        return false;
      }
    };
    const filesDir: string = this.host.getFilesDir();
    const requestId: number = Math.max(Date.now(), this.localSendRefreshRequestId + 1);
    this.localSendRefreshRequestId = requestId;
    const responsePath: string = `${filesDir}/${LOCAL_SEND_REFRESH_RESPONSE_FILE_NAME}`;
    this.vpnCommandGateway.writeCommandFile(filesDir, LOCAL_SEND_REFRESH_RESPONSE_FILE_NAME, '');
    const requestPayload: LocalSendRefreshRequest = { requestId: requestId };
    this.vpnCommandGateway.writeCommandFile(
      filesDir,
      LOCAL_SEND_REFRESH_REQUEST_FILE_NAME,
      JSON.stringify(requestPayload)
    );
    while (this.host.isAppShellReady() && this.host.isConnected() && withinDeadline()) {
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 150));
      if (!this.host.isAppShellReady() || !this.host.isConnected() || !withinDeadline()) {
        break;
      }
      try {
        if (!fileIo.accessSync(responsePath)) {
          continue;
        }
        const responseText: string = fileIo.readTextSync(responsePath).trim();
        if (responseText.length === 0) {
          continue;
        }
        const response: LocalSendRefreshResponse = JSON.parse(responseText) as LocalSendRefreshResponse;
        if (response.requestId !== requestId) {
          continue;
        }
        this.vpnCommandGateway.writeCommandFile(filesDir, LOCAL_SEND_REFRESH_RESPONSE_FILE_NAME, '');
        this.host.refreshPeerSnapshot();
        return;
      } catch (_error) {
        // The Extension may be replacing the response file. Retry briefly.
      }
    }
    this.vpnCommandGateway.writeCommandFile(filesDir, LOCAL_SEND_REFRESH_REQUEST_FILE_NAME, '');
  }

  localSendPortOverrideForPeer(peerKey: string): number | undefined {
    return this.host.getLocalSendPortOverrides().find((item: LocalSendPortOverride) =>
      item.peerKey === peerKey)?.port;
  }

  localSendPortForPeer(peer: PeerSummary): number {
    const override: number | undefined = this.localSendPortOverrideForPeer(peer.key);
    if (override !== undefined) {
      return override;
    }
    const reportedPort: number | undefined = peer.localSend?.port;
    if (reportedPort !== undefined && Number.isInteger(reportedPort) &&
      reportedPort >= 1 && reportedPort <= 65535) {
      return reportedPort;
    }
    return DEFAULT_LOCAL_SEND_PORT;
  }

  saveRemotePortOverride(): void {
    const port: number = Number(this.host.getRemotePortInput().trim());
    const targetKey: string = this.host.getRemotePortPeerKey();
    const peer: PeerSummary | undefined = this.host.getPeers().find(
      (item: PeerSummary) => item.key === targetKey);
    if (peer === undefined || !Number.isInteger(port) || port < 1 || port > 65535) {
      this.host.showPeerIntegrationToast('transfer_remote_port_invalid');
      return;
    }
    const nextOverrides: LocalSendPortOverride[] = this.host.getLocalSendPortOverrides()
      .filter((item: LocalSendPortOverride) => item.peerKey !== peer.key);
    const updatedOverride: LocalSendPortOverride = { peerKey: peer.key, port: port };
    nextOverrides.push(updatedOverride);
    this.host.setLocalSendPortOverrides(nextOverrides);
    FileTransferPreferences.saveLocalSendPortOverride(
      this.host.getAbilityContext(),
      peer.key,
      port
    ).catch(() => {
      // The in-memory value still applies for this session when persistence fails.
    });
    this.host.setRemotePortEditorVisible(false);
    this.host.showPeerIntegrationToast('transfer_remote_port_saved');
  }

  openLocalSendFromDevice(peer: PeerSummary): void {
    this.host.setTaildropFocusedTargetKey(peer.key);
    this.host.setDeviceDetailVisible(false);
    this.host.scheduleLifecycleTask(() => {
      void this.launchLocalSendApp();
      this.host.scheduleLifecycleTask(() => {
        if (this.host.getTaildropFocusedTargetKey() === peer.key) {
          this.host.setTaildropFocusedTargetKey('');
        }
      }, 2600);
    }, 120);
  }

  async launchLocalSendApp(): Promise<void> {
    const context: common.UIAbilityContext = this.host.getAbilityContext();
    const target: LocalSendAppTarget = LOCAL_SEND_APP_TARGETS[0];
    const want: Want = {
      bundleName: target.bundleName,
      moduleName: target.moduleName,
      abilityName: target.abilityName
    };
    this.host.recordFeatureDiagnosticEvent('localsend_launch_attempt', 'explicit_want');
    try {
      await context.startAbility(want);
      this.host.recordFeatureDiagnosticEvent('localsend_launch_success', 'explicit_want');
      return;
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      this.host.recordFeatureDiagnosticEvent(
        'localsend_launch_failed',
        'explicit_want',
        businessError.code ?? -1
      );
    }
    this.host.showPeerIntegrationToast('transfer_localsend_open_failed');
  }

  // --- Peer Service Probing, Home Latency & Manual Sheet Refresh ---

  invalidateDeviceDetailServiceRefresh(): void {
    this.deviceDetailServiceRefreshRequestId++;
    this.host.setDeviceDetailServiceRefreshInFlight(false);
  }

  isCurrentDeviceDetailServiceRefresh(
    peerKey: string,
    requestId: number,
    generation: number
  ): boolean {
    const peer: PeerSummary | undefined = this.host.getPeers().find(
      (current: PeerSummary) => current.key === peerKey);
    return this.host.isDeviceDetailServiceRefreshInFlight() &&
      this.deviceDetailServiceRefreshRequestId === requestId &&
      this.host.getLifecycleGeneration() === generation &&
      this.host.isAppShellReady() && this.host.isDeviceDetailVisible() &&
      this.host.getSelectedPeerKey() === peerKey &&
      !this.host.isAppLockRequired() && !this.host.isAppLockAuthenticating() &&
      this.host.isConnected() && peer !== undefined &&
      this.host.peerEffectivelyOnline(peer);
  }

  async waitForPeerServiceRefresh(
    peerKey: string,
    requestId: number,
    generation: number,
    timeoutMs: number = 6000
  ): Promise<void> {
    const startedAt: number = this.getMonotonicUptimeMsFn();
    while (this.peerServiceRefreshInFlight.has(peerKey) &&
      this.isCurrentDeviceDetailServiceRefresh(peerKey, requestId, generation) &&
      this.getMonotonicUptimeMsFn() - startedAt < timeoutMs) {
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 100));
    }
  }

  async refreshSelectedPeerServicesManually(peerKey: string): Promise<void> {
    if (this.host.isDeviceDetailServiceRefreshInFlight() || !this.host.isAppShellReady() ||
      !this.host.isDeviceDetailVisible() || this.host.getSelectedPeerKey() !== peerKey ||
      this.host.isAppLockRequired() || this.host.isAppLockAuthenticating()) {
      return;
    }
    const initialPeer: PeerSummary | undefined = this.host.getPeers().find(
      (peer: PeerSummary) => peer.key === peerKey);
    if (initialPeer === undefined || !this.host.isConnected() ||
      !this.host.peerEffectivelyOnline(initialPeer)) {
      return;
    }
    const generation: number = this.host.getLifecycleGeneration();
    const requestId: number = ++this.deviceDetailServiceRefreshRequestId;
    const startedAt: number = this.getMonotonicUptimeMsFn();
    this.host.setDeviceDetailServiceRefreshInFlight(true);
    try {
      try {
        this.host.refreshTaildropSnapshot(true);
      } catch (_error) {}
      if (!this.peerServiceRefreshInFlight.has(peerKey)) {
        this.refreshPeerServices(initialPeer, true);
      }
      await Promise.all([
        this.waitForPeerServiceRefresh(peerKey, requestId, generation),
        this.requestLocalSendRefresh()
      ]).then((): void => {});
      if (this.isCurrentDeviceDetailServiceRefresh(peerKey, requestId, generation)) {
        this.host.refreshPeerSnapshot();
        this.host.refreshTaildropSnapshot(true);
      }
    } finally {
      try {
        if (this.deviceDetailServiceRefreshRequestId === requestId) {
          const remainingMs: number = 220 - (this.getMonotonicUptimeMsFn() - startedAt);
          if (remainingMs > 0) {
            await new Promise<void>((resolve: () => void) => setTimeout(resolve, remainingMs));
          }
        }
      } finally {
        if (this.deviceDetailServiceRefreshRequestId === requestId) {
          this.host.setDeviceDetailServiceRefreshInFlight(false);
        }
      }
    }
  }

  refreshHomeLatency(): void {
    this.host.refreshPeerSnapshot();
    if (this.homeLatencyRefreshInFlight || !this.host.isConnected() ||
      !this.host.isRemoteStreamAppInForeground()) {
      return;
    }
    this.ensureStreamingServices();
    const onlinePeers: PeerSummary[] = this.host.getPeers().filter((peer: PeerSummary) =>
      peer.online && peer.addresses.length > 0);
    if (onlinePeers.length === 0) {
      return;
    }
    this.homeLatencyRefreshInFlight = true;
    const generation: number = this.host.getLifecycleGeneration();
    const session: number = this.host.getTrafficSession();
    Promise.all(onlinePeers.map((peer: PeerSummary) =>
      this.peerPathService!.probe(peer.key, true, true).then((path: PeerPathResult) => {
        const currentPeer: PeerSummary | undefined = this.host.getPeers().find(
          (item: PeerSummary) => item.key === peer.key);
        if (!this.host.isAppShellReady() || !this.host.isConnected() ||
          generation !== this.host.getLifecycleGeneration() ||
          session !== this.host.getTrafficSession() ||
          currentPeer === undefined || !currentPeer.online ||
          path.errorMessage === 'cancelled') {
          return;
        }
        this.updateStreamingState(
          peer.key,
          this.copyStreamingState(this.streamingState(peer.key), undefined, path, false)
        );
      }))).finally(() => {
      this.homeLatencyRefreshInFlight = false;
    });
  }

  refreshPeerServices(peer: PeerSummary, manual: boolean = true): void {
    const previousStreaming: DeviceStreamingState = this.streamingState(peer.key);
    const previousMedia: DeviceMediaState = this.mediaState(peer.key);
    if (this.peerServiceRefreshInFlight.has(peer.key)) {
      return;
    }
    if (!this.host.isConnected() || !this.host.peerEffectivelyOnline(peer) ||
      peer.addresses.length === 0) {
      if (!manual) {
        return;
      }
      this.host.showPeerIntegrationToast('peer_service_connect_and_online_toast');
      return;
    }
    this.ensureStreamingServices();
    this.ensureMediaServices();
    const requestId: number = this.nextPeerProbeRequestId();
    const requestedAt: number = Date.now();
    const sunshineCandidate: boolean = isPeerSunshineCandidate(peer);
    this.peerServiceRefreshInFlight.add(peer.key);
    this.peerServiceRefreshOwners.set(peer.key, requestId);
    this.streamingRequestIds.set(peer.key, requestId);
    this.mediaRequestIds.set(peer.key, requestId);
    if (manual) {
      this.updateStreamingState(
        peer.key,
        this.copyStreamingState(previousStreaming, previousStreaming.sunshine, previousStreaming.path, true)
      );
      const checkingResult: MediaProbeResult = {
        state: 'checking',
        checkedAt: requestedAt,
        services: previousMedia.result.services
      };
      const checkingMediaState: DeviceMediaState = {
        peerKey: peer.key,
        result: checkingResult,
        checking: true,
        launching: previousMedia.launching
      };
      this.updateMediaState(peer.key, checkingMediaState);
    }
    const sunshineProbe: Promise<SunshineProbeResult> = sunshineCandidate ?
      this.sunshineProbeService!.probe(peer.key, selectPrimaryTailscaleAddress(peer.addresses), true, true) :
      Promise.resolve(previousStreaming.sunshine);
    Promise.all([
      sunshineProbe,
      this.mediaServiceProbeService!.probe(peer.key, true, true),
      this.peerPathService!.probe(peer.key, true, true)
    ]).then((results: [SunshineProbeResult, MediaProbeResult, PeerPathResult]) => {
      const currentPeer: PeerSummary | undefined = this.host.getPeers().find(
        (item: PeerSummary) => item.key === peer.key && item.online);
      if (this.peerServiceRefreshOwners.get(peer.key) !== requestId ||
        currentPeer === undefined || !this.host.isConnected()) {
        return;
      }
      const sunshine: SunshineProbeResult = results[0];
      const mediaResult: MediaProbeResult = results[1];
      const path: PeerPathResult = results[2];
      if (this.streamingRequestIds.get(peer.key) === requestId) {
        let visibleSunshine: SunshineProbeResult = sunshine;
        if (!manual) {
          if (sunshine.state === 'available') {
            this.autoSunshineFailureCounts.delete(peer.key);
          } else if (previousStreaming.sunshine.state === 'available') {
            const failureCount: number = (this.autoSunshineFailureCounts.get(peer.key) ?? 0) + 1;
            this.autoSunshineFailureCounts.set(peer.key, failureCount);
            if (failureCount < 3) {
              visibleSunshine = previousStreaming.sunshine;
            }
          }
        } else {
          this.autoSunshineFailureCounts.delete(peer.key);
        }
        this.updateStreamingState(
          peer.key,
          this.copyStreamingState(this.streamingState(peer.key), visibleSunshine, path, false)
        );
        this.host.recordDiagnosticEvent('peer_path_result', path.type);
        this.host.recordDiagnosticEvent(
          sunshine.state === 'available' ? 'sunshine_probe_success' :
            sunshine.state === 'timeout' ? 'sunshine_probe_timeout' : 'sunshine_probe_failed',
          sunshine.state
        );
      }
      if (this.mediaRequestIds.get(peer.key) === requestId) {
        let visibleMedia: MediaProbeResult = mediaResult;
        if (!manual) {
          if (mediaResult.services.length > 0) {
            this.autoMediaFailureCounts.delete(peer.key);
          } else if (previousMedia.result.services.length > 0) {
            const failureCount: number = (this.autoMediaFailureCounts.get(peer.key) ?? 0) + 1;
            this.autoMediaFailureCounts.set(peer.key, failureCount);
            if (failureCount < 3) {
              visibleMedia = previousMedia.result;
            }
          }
        } else {
          this.autoMediaFailureCounts.delete(peer.key);
        }
        const completedMedia: DeviceMediaState = {
          peerKey: peer.key,
          result: visibleMedia,
          checking: false,
          launching: false
        };
        this.updateMediaState(peer.key, completedMedia);
        this.host.recordDiagnosticEvent(
          mediaResult.services.length > 0 ? 'media_probe_success' : 'media_probe_no_service',
          path.type
        );
      }
    }).catch(() => {
      if (this.peerServiceRefreshOwners.get(peer.key) !== requestId || !this.host.isConnected() ||
        !this.host.getPeers().some((current: PeerSummary) => current.key === peer.key && current.online)) {
        return;
      }
      if (manual && this.streamingRequestIds.get(peer.key) === requestId) {
        const failedSunshine: SunshineProbeResult = {
          state: 'error',
          checkedAt: Date.now(),
          errorMessage: 'probe_failed'
        };
        const failedPath: PeerPathResult = {
          type: 'unknown',
          checkedAt: Date.now(),
          errorMessage: 'probe_failed'
        };
        this.updateStreamingState(
          peer.key,
          this.copyStreamingState(
            this.streamingState(peer.key),
            sunshineCandidate ? failedSunshine : previousStreaming.sunshine,
            failedPath,
            false
          )
        );
      }
      if (manual && this.mediaRequestIds.get(peer.key) === requestId) {
        const failedMediaResult: MediaProbeResult = {
          state: 'error',
          checkedAt: Date.now(),
          services: [],
          errorMessage: 'probe_failed'
        };
        const failedMediaState: DeviceMediaState = {
          peerKey: peer.key,
          result: failedMediaResult,
          checking: false,
          launching: false
        };
        this.updateMediaState(peer.key, failedMediaState);
      }
      if (this.streamingRequestIds.get(peer.key) === requestId ||
        this.mediaRequestIds.get(peer.key) === requestId) {
        this.host.recordDiagnosticEvent('peer_service_refresh_failed', 'exception');
      }
    }).finally(() => {
      if (this.peerServiceRefreshOwners.get(peer.key) !== requestId) {
        return;
      }
      if (manual && this.streamingRequestIds.get(peer.key) === requestId) {
        const currentStreaming: DeviceStreamingState = this.streamingState(peer.key);
        if (currentStreaming.checking) {
          this.updateStreamingState(
            peer.key,
            this.copyStreamingState(currentStreaming, undefined, undefined, false)
          );
        }
      }
      if (manual && this.mediaRequestIds.get(peer.key) === requestId) {
        const currentMedia: DeviceMediaState = this.mediaState(peer.key);
        if (currentMedia.checking) {
          const clearedMedia: DeviceMediaState = {
            peerKey: peer.key,
            result: currentMedia.result,
            checking: false,
            launching: currentMedia.launching
          };
          this.updateMediaState(peer.key, clearedMedia);
        }
      }
      this.peerServiceRefreshOwners.delete(peer.key);
      this.peerServiceRefreshInFlight.delete(peer.key);
    });
    this.host.recordDiagnosticEvent('peer_service_refresh_start', 'requested');
  }

  autoProbeConnectedPeerServices(force: boolean = false): void {
    if (!this.host.isConnected() || !this.host.isRemoteStreamAppInForeground()) {
      return;
    }
    const session: number = Math.max(1, this.host.getTrafficSession());
    this.host.getPeers().filter((peer: PeerSummary) => peer.online && peer.addresses.length > 0)
      .forEach((peer: PeerSummary) => {
        if (this.peerServiceRefreshInFlight.has(peer.key)) {
          return;
        }
        if (!force && this.autoProbedPeerSessions.get(peer.key) === session) {
          return;
        }
        this.autoProbedPeerSessions.set(peer.key, session);
        this.refreshPeerServices(peer, false);
      });
  }

  // --- Streaming & Media State Projections ---

  streamingState(peerKey: string): DeviceStreamingState {
    const existing: DeviceStreamingState | undefined = this.host.getStreamingStates().find(
      (state: DeviceStreamingState) => state.peerKey === peerKey);
    if (existing !== undefined) {
      return existing;
    }
    const defaultSunshine: SunshineProbeResult = { state: 'unknown', checkedAt: 0 };
    const defaultPath: PeerPathResult = { type: 'unknown', checkedAt: 0 };
    const defaultState: DeviceStreamingState = {
      peerKey: peerKey,
      sunshine: defaultSunshine,
      path: defaultPath,
      checking: false,
      launching: false
    };
    return defaultState;
  }

  copyStreamingState(
    state: DeviceStreamingState,
    sunshine?: SunshineProbeResult,
    path?: PeerPathResult,
    checking?: boolean,
    launching?: boolean
  ): DeviceStreamingState {
    const copied: DeviceStreamingState = {
      peerKey: state.peerKey,
      sunshine: sunshine === undefined ? state.sunshine : sunshine,
      path: path === undefined ? state.path : path,
      checking: checking === undefined ? state.checking : checking,
      launching: launching === undefined ? state.launching : launching
    };
    return copied;
  }

  updateStreamingState(peerKey: string, update: DeviceStreamingState): void {
    const currentStates: DeviceStreamingState[] = this.host.getStreamingStates();
    const index: number = currentStates.findIndex(
      (state: DeviceStreamingState) => state.peerKey === peerKey);
    if (index < 0) {
      this.host.setStreamingStates(currentStates.concat(update));
      this.host.logServiceStatusIfChanged();
      return;
    }
    const next: DeviceStreamingState[] = currentStates.slice();
    next[index] = update.path.checkedAt < next[index].path.checkedAt ?
      this.copyStreamingState(update, undefined, next[index].path) :
      update;
    this.host.setStreamingStates(next);
    this.host.logServiceStatusIfChanged();
  }

  resetStreamingStatesForDisconnect(): void {
    this.invalidateRemoteStreamLaunch();
    this.invalidateDeviceDetailServiceRefresh();
    this.streamingRequestIds.clear();
    this.mediaRequestIds.clear();
    this.peerServiceRefreshInFlight.clear();
    this.peerServiceRefreshOwners.clear();
    this.autoSunshineFailureCounts.clear();
    this.autoMediaFailureCounts.clear();
    this.autoProbedPeerSessions.clear();
    this.sunshineProbeService?.clearCache();
    this.peerPathService?.clearCache();
    this.mediaServiceProbeService?.clearCache();
    this.host.setStreamingStates(this.host.getStreamingStates().map(
      (state: DeviceStreamingState): DeviceStreamingState => {
        const disconnectedSunshine: SunshineProbeResult = {
          state: 'unknown',
          checkedAt: Date.now(),
          errorMessage: 'mesh_disconnected'
        };
        const disconnectedPath: PeerPathResult = {
          type: 'unknown',
          checkedAt: Date.now(),
          errorMessage: 'mesh_disconnected'
        };
        return this.copyStreamingState(
          state,
          disconnectedSunshine,
          disconnectedPath,
          false,
          false
        );
      }));
    this.host.setMediaStates(this.host.getMediaStates().map(
      (state: DeviceMediaState): DeviceMediaState => {
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
      }));
  }

  mediaState(peerKey: string): DeviceMediaState {
    if (this.host.isFakeMediaServiceOnline()) {
      const peer: PeerSummary | undefined = this.host.getPeers().find(
        (item: PeerSummary) => item.key === peerKey);
      const host: string = peer === undefined ? '100.64.0.1' :
        selectPrimaryTailscaleAddress(peer.addresses);
      const fakeService: DiscoveredMediaService = {
        type: 'jellyfin',
        name: this.host.getFakeJellyfinName(),
        url: `http://${host.length > 0 ? host : '100.64.0.1'}:8096`,
        latencyMs: 1
      };
      const fakeResult: MediaProbeResult = {
        state: 'available',
        checkedAt: Date.now(),
        services: [fakeService]
      };
      const fakeState: DeviceMediaState = {
        peerKey: peerKey,
        result: fakeResult,
        checking: false,
        launching: false
      };
      return fakeState;
    }
    const existing: DeviceMediaState | undefined = this.host.getMediaStates().find(
      (state: DeviceMediaState) => state.peerKey === peerKey);
    if (existing !== undefined) {
      return existing;
    }
    const defaultResult: MediaProbeResult = { state: 'unknown', checkedAt: 0, services: [] };
    const defaultState: DeviceMediaState = {
      peerKey: peerKey,
      result: defaultResult,
      checking: false,
      launching: false
    };
    return defaultState;
  }

  mediaServiceNames(peerKey: string): string {
    return this.mediaState(peerKey).result.services.map((service: DiscoveredMediaService) => {
      if (service.type === 'jellyfin') return 'Jellyfin';
      if (service.type === 'emby') return 'Emby';
      if (service.type === 'plex') return 'Plex';
      if (service.type === 'webdav') return 'WebDAV';
      return 'SMB';
    }).join(' · ');
  }

  peerServiceBadgesVisible(peer: PeerSummary): boolean {
    const sunshineState: string = this.streamingState(peer.key).sunshine.state;
    return sunshineState === 'checking' || sunshineState === 'available' ||
      this.mediaState(peer.key).checking || this.mediaServiceNames(peer.key).length > 0;
  }

  updateMediaState(peerKey: string, update: DeviceMediaState): void {
    const currentStates: DeviceMediaState[] = this.host.getMediaStates();
    const index: number = currentStates.findIndex(
      (state: DeviceMediaState) => state.peerKey === peerKey);
    if (index < 0) {
      this.host.setMediaStates(currentStates.concat(update));
      this.host.logServiceStatusIfChanged();
      return;
    }
    const next: DeviceMediaState[] = currentStates.slice();
    next[index] = update;
    this.host.setMediaStates(next);
    this.host.logServiceStatusIfChanged();
  }

  detectMediaForPeer(peer: PeerSummary, force: boolean): void {
    if (!this.host.peerEffectivelyOnline(peer) || peer.addresses.length === 0 ||
      !this.host.isConnected()) {
      this.host.showPeerIntegrationToast('peer_service_connect_and_online_toast');
      return;
    }
    this.ensureMediaServices();
    this.ensureStreamingServices();
    const requestId: number = this.nextPeerProbeRequestId();
    this.mediaRequestIds.set(peer.key, requestId);
    const previous: DeviceMediaState = this.mediaState(peer.key);
    const checkingResult: MediaProbeResult = {
      state: 'checking',
      checkedAt: Date.now(),
      services: previous.result.services
    };
    const checkingState: DeviceMediaState = {
      peerKey: peer.key,
      result: checkingResult,
      checking: true,
      launching: previous.launching
    };
    this.updateMediaState(peer.key, checkingState);
    this.host.recordDiagnosticEvent('media_probe_start', 'requested');
    Promise.all([
      this.mediaServiceProbeService!.probe(peer.key, true, force),
      this.peerPathService!.probe(peer.key, true, force)
    ]).then((results: [MediaProbeResult, PeerPathResult]) => {
      if (this.mediaRequestIds.get(peer.key) !== requestId || !this.host.isConnected()) {
        return;
      }
      const currentPeer: PeerSummary | undefined = this.host.getPeers().find(
        (item: PeerSummary) => item.key === peer.key && item.online);
      if (currentPeer === undefined) {
        return;
      }
      const mediaResult: MediaProbeResult = results[0];
      const path: PeerPathResult = results[1];
      const streamState: DeviceStreamingState = this.streamingState(peer.key);
      this.updateStreamingState(
        peer.key,
        this.copyStreamingState(streamState, undefined, path, false, false)
      );
      const completedState: DeviceMediaState = {
        peerKey: peer.key,
        result: mediaResult,
        checking: false,
        launching: false
      };
      this.updateMediaState(peer.key, completedState);
      this.host.recordDiagnosticEvent(
        mediaResult.services.length > 0 ? 'media_probe_success' : 'media_probe_no_service',
        path.type
      );
      mediaResult.services.forEach((service: DiscoveredMediaService) => {
        this.host.recordDiagnosticEvent('media_service_detected', service.type);
      });
    }).catch(() => {
      if (this.mediaRequestIds.get(peer.key) !== requestId) {
        return;
      }
      const failedResult: MediaProbeResult = {
        state: 'error',
        checkedAt: Date.now(),
        services: [],
        errorMessage: 'probe_failed'
      };
      const failedState: DeviceMediaState = {
        peerKey: peer.key,
        result: failedResult,
        checking: false,
        launching: false
      };
      this.updateMediaState(peer.key, failedState);
      this.host.recordDiagnosticEvent('media_probe_failed', 'exception');
    });
  }

  detectStreamingForPeer(peer: PeerSummary, force: boolean): void {
    if (!isPeerSunshineCandidate(peer) || !this.host.isConnected()) {
      return;
    }
    this.ensureStreamingServices();
    const requestId: number = this.nextPeerProbeRequestId();
    this.streamingRequestIds.set(peer.key, requestId);
    const previous: DeviceStreamingState = this.streamingState(peer.key);
    const sunshineAge: number = Date.now() - previous.sunshine.checkedAt;
    const reuseSunshine: boolean = !force && previous.sunshine.state === 'available' &&
      sunshineAge >= 0 && sunshineAge < 60000;
    const checkingPath: PeerPathResult = {
      type: previous.path.type,
      latencyMs: previous.path.latencyMs,
      relayRegion: previous.path.relayRegion,
      checkedAt: Date.now(),
      errorMessage: previous.path.errorMessage
    };
    const checkingSunshine: SunshineProbeResult = { state: 'checking', checkedAt: Date.now() };
    this.updateStreamingState(
      peer.key,
      this.copyStreamingState(
        previous,
        reuseSunshine ? previous.sunshine : checkingSunshine,
        checkingPath,
        true
      )
    );
    const host: string = selectPrimaryTailscaleAddress(peer.addresses);
    Promise.all([
      reuseSunshine ? Promise.resolve(previous.sunshine) :
        this.sunshineProbeService!.probe(peer.key, host, true, force),
      this.peerPathService!.probe(peer.key, true, force)
    ]).then((results: [SunshineProbeResult, PeerPathResult]) => {
      const sunshine: SunshineProbeResult = results[0];
      const path: PeerPathResult = results[1];
      const currentPeer: PeerSummary | undefined = this.host.getPeers().find(
        (item: PeerSummary) => item.key === peer.key);
      if (this.streamingRequestIds.get(peer.key) !== requestId ||
        currentPeer === undefined || !currentPeer.online || !this.host.isConnected()) {
        return;
      }
      const current: DeviceStreamingState = this.streamingState(peer.key);
      this.updateStreamingState(peer.key, this.copyStreamingState(current, sunshine, path, false));
      this.host.recordDiagnosticEvent(
        sunshine.state === 'available' ? 'sunshine_probe_success' :
          sunshine.state === 'timeout' ? 'sunshine_probe_timeout' : 'sunshine_probe_failed',
        sunshine.errorMessage ?? sunshine.state
      );
      this.host.recordDiagnosticEvent('peer_path_result', path.type);
    }).catch(() => {
      if (this.streamingRequestIds.get(peer.key) !== requestId) {
        return;
      }
      const current: DeviceStreamingState = this.streamingState(peer.key);
      const failedSunshine: SunshineProbeResult = {
        state: 'error',
        checkedAt: Date.now(),
        errorMessage: 'probe_failed'
      };
      const failedPath: PeerPathResult = {
        type: 'unknown',
        checkedAt: Date.now(),
        errorMessage: 'probe_failed'
      };
      this.updateStreamingState(
        peer.key,
        this.copyStreamingState(current, failedSunshine, failedPath, false)
      );
      this.host.recordDiagnosticEvent('sunshine_probe_failed', 'exception');
    });
    this.host.recordDiagnosticEvent('sunshine_probe_start', 'requested');
    this.host.recordDiagnosticEvent('peer_path_probe_start', 'requested');
  }

  // --- Remote Stream Launch (Moonlight) ---

  streamReachable(state: DeviceStreamingState): boolean {
    return state.path.type !== 'unreachable';
  }

  isCurrentRemoteStreamLaunch(intent: RemoteStreamLaunchIntent): boolean {
    const peer: PeerSummary | undefined = this.host.getPeers().find(
      (item: PeerSummary) => item.key === intent.peerKey);
    return this.remoteStreamLaunchIntent === intent &&
      this.host.isAppShellReady() &&
      this.host.isRemoteStreamAppInForeground() &&
      this.host.getLifecycleGeneration() === intent.generation &&
      this.host.getNavigationRevision() === intent.navigationRevision &&
      !this.host.isAppLockRequired() &&
      !this.host.isAppLockAuthenticating() &&
      this.host.isConnected() &&
      peer !== undefined &&
      this.host.peerEffectivelyOnline(peer) &&
      selectPrimaryTailscaleAddress(peer.addresses) === intent.host &&
      this.streamingRequestIds.get(intent.peerKey) === intent.probeRequestId &&
      (!intent.fromDetail || (this.host.isDeviceDetailVisible() &&
        this.host.getSelectedPeerKey() === intent.peerKey &&
        this.host.getDeviceDetailPresentationId() === intent.detailPresentationId));
  }

  finishRemoteStreamLaunch(intent: RemoteStreamLaunchIntent): void {
    if (this.remoteStreamLaunchIntent !== intent) {
      return;
    }
    this.remoteStreamLaunchIntent = undefined;
    this.updateStreamingState(
      intent.peerKey,
      this.copyStreamingState(this.streamingState(intent.peerKey), undefined, undefined, undefined, false)
    );
  }

  invalidateRemoteStreamLaunch(): void {
    if (this.remoteStreamLaunchIntent !== undefined) {
      this.finishRemoteStreamLaunch(this.remoteStreamLaunchIntent);
    }
  }

  handleRemoteStreamAppBackground(): void {
    this.host.setRemoteStreamAppInForeground(false);
    this.invalidateRemoteStreamLaunch();
  }

  launchRemoteStream(peer: PeerSummary): void {
    if (!this.host.isAppShellReady() || !this.host.isRemoteStreamAppInForeground() ||
      this.host.isAppLockRequired() || this.host.isAppLockAuthenticating()) {
      return;
    }
    if (!this.host.isConnected()) {
      this.host.showPeerIntegrationToast('stream_connect_required_toast');
      return;
    }
    const currentPeer: PeerSummary | undefined = this.host.getPeers().find(
      (item: PeerSummary) => item.key === peer.key);
    if (currentPeer === undefined || !this.host.peerEffectivelyOnline(currentPeer)) {
      this.host.showPeerIntegrationToast('stream_target_offline_toast');
      return;
    }
    const host: string = selectPrimaryTailscaleAddress(currentPeer.addresses);
    if (host.length === 0) {
      return;
    }
    if (this.remoteStreamLaunchIntent !== undefined &&
      !this.isCurrentRemoteStreamLaunch(this.remoteStreamLaunchIntent)) {
      this.invalidateRemoteStreamLaunch();
    }
    const state: DeviceStreamingState = this.streamingState(peer.key);
    if (state.launching) {
      return;
    }
    let launchStartedAt: number = 0;
    try {
      launchStartedAt = this.getMonotonicUptimeMsFn();
    } catch (_error) {
      return;
    }
    this.invalidateRemoteStreamLaunch();
    const intent: RemoteStreamLaunchIntent = {
      peerKey: peer.key,
      host: host,
      generation: this.host.getLifecycleGeneration(),
      navigationRevision: this.host.getNavigationRevision(),
      fromDetail: this.host.isDeviceDetailVisible(),
      detailPresentationId: this.host.getDeviceDetailPresentationId(),
      probeRequestId: 0,
      launchRequested: false
    };
    this.remoteStreamLaunchIntent = intent;
    this.updateStreamingState(
      peer.key,
      this.copyStreamingState(state, undefined, undefined, undefined, true)
    );
    try {
      this.detectStreamingForPeer(currentPeer, false);
      intent.probeRequestId = this.streamingRequestIds.get(peer.key) ?? 0;
    } catch (_error) {
      this.finishRemoteStreamLaunch(intent);
      this.host.showPeerIntegrationToast('stream_sunshine_probe_error_toast');
      return;
    }
    const waitForProbe = (): void => {
      if (!this.isCurrentRemoteStreamLaunch(intent)) {
        this.finishRemoteStreamLaunch(intent);
        return;
      }
      try {
        if (this.getMonotonicUptimeMsFn() - launchStartedAt >= 5000) {
          this.finishRemoteStreamLaunch(intent);
          this.host.showPeerIntegrationToast(
            this.streamingState(peer.key).sunshine.state === 'available' ?
              'stream_path_probe_timeout_toast' :
              'stream_sunshine_timeout_toast'
          );
          return;
        }
      } catch (_error) {
        this.finishRemoteStreamLaunch(intent);
        return;
      }
      const latest: DeviceStreamingState = this.streamingState(peer.key);
      if (latest.checking) {
        this.host.scheduleLifecycleTask(waitForProbe, 120);
        return;
      }
      try {
        this.completeStreamLaunch(currentPeer, latest, intent);
      } catch (_error) {
        this.finishRemoteStreamLaunch(intent);
        this.host.showPeerIntegrationToast('stream_moonlight_open_failed_toast');
      }
    };
    this.host.scheduleLifecycleTask(waitForProbe, 0);
  }

  completeStreamLaunch(
    peer: PeerSummary,
    state: DeviceStreamingState,
    intent: RemoteStreamLaunchIntent
  ): void {
    if (!this.isCurrentRemoteStreamLaunch(intent)) {
      this.finishRemoteStreamLaunch(intent);
      return;
    }
    if (state.sunshine.state !== 'available') {
      this.finishRemoteStreamLaunch(intent);
      this.host.showPeerIntegrationToast(
        state.sunshine.state === 'timeout' ? 'stream_sunshine_timeout_toast' :
          state.sunshine.state === 'unavailable' ? 'stream_sunshine_unavailable_toast' :
            'stream_sunshine_failed_toast'
      );
      return;
    }
    if (!this.streamReachable(state)) {
      this.finishRemoteStreamLaunch(intent);
      this.host.showPeerIntegrationToast('stream_target_unreachable_toast');
      return;
    }
    if (state.path.type === 'derp') {
      this.host.showDerpStreamConfirmationDialog(peer, state, intent);
      return;
    }
    this.openMoonlight(peer, state, false, intent);
  }

  async queryMoonlightAvailability(): Promise<boolean> {
    this.ensureStreamingServices();
    return this.moonlightLauncher!.isAvailable();
  }

  openMoonlight(
    peer: PeerSummary,
    state: DeviceStreamingState,
    useOriginalProfile: boolean,
    intent: RemoteStreamLaunchIntent
  ): void {
    if (!this.isCurrentRemoteStreamLaunch(intent)) {
      this.finishRemoteStreamLaunch(intent);
      return;
    }
    if (intent.launchRequested) {
      return;
    }
    intent.launchRequested = true;
    const host: string = intent.host;
    this.host.recordDiagnosticEvent('moonlight_launch_attempt', state.path.type);
    this.queryMoonlightAvailability().then((available: boolean) => {
      if (!this.isCurrentRemoteStreamLaunch(intent)) {
        this.finishRemoteStreamLaunch(intent);
        return;
      }
      if (!available) {
        this.finishRemoteStreamLaunch(intent);
        this.host.showMoonlightRequiredDialog(host);
        return;
      }
      const originalProfile: StreamLaunchProfile = { profileName: 'default', allowUserOverride: true };
      const profile: StreamLaunchProfile = useOriginalProfile ?
        originalProfile : buildStreamProfile(state.path);
      const currentPeer: PeerSummary = this.host.getPeers().find(
        (item: PeerSummary) => item.key === intent.peerKey) ?? peer;
      const launchRequest: MoonlightLaunchRequest = {
        protocolVersion: 1,
        action: 'openHost',
        source: 'MeshArc',
        host: host,
        displayName: currentPeer.name,
        dnsName: currentPeer.name,
        pathType: state.path.type,
        relayRegion: state.path.relayRegion,
        latencyMs: state.path.latencyMs,
        streamProfile: profile,
        adaptiveBitrate: !useOriginalProfile
      };
      return this.moonlightLauncher!.launch(launchRequest).then(() => {
        this.finishRemoteStreamLaunch(intent);
        this.host.recordDiagnosticEvent('moonlight_launch_success', state.path.type);
      });
    }).catch(() => {
      if (this.isCurrentRemoteStreamLaunch(intent)) {
        this.host.recordDiagnosticEvent('moonlight_launch_failed', state.path.type);
        this.host.showPeerIntegrationToast('stream_moonlight_open_failed_toast');
      }
      this.finishRemoteStreamLaunch(intent);
    });
  }

  // --- Media Launch (HosPlayer) & Self-Test ---

  launchMediaForPeer(peer: PeerSummary): void {
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

  hosPlayerServerName(peer: PeerSummary, service: DiscoveredMediaService): string {
    const peerName: string = formatPeerDisplayName(peer.name).trim();
    const serviceName: string = service.name.trim();
    if (serviceName.length === 0 || peerName.toLowerCase() === serviceName.toLowerCase()) {
      return peerName;
    }
    if (peerName.length === 0) {
      return serviceName;
    }
    return `${peerName} · ${serviceName}`;
  }

  openHosPlayer(peer: PeerSummary, service: DiscoveredMediaService): void {
    this.ensureMediaServices();
    const state: DeviceMediaState = this.mediaState(peer.key);
    const launchingState: DeviceMediaState = {
      peerKey: peer.key,
      result: state.result,
      checking: false,
      launching: true
    };
    this.updateMediaState(peer.key, launchingState);
    this.host.recordFeatureDiagnosticEvent('hosplayer_launch_attempt', service.type);
    try {
      const request: HosPlayerLaunchRequest = {
        protocolVersion: 1,
        type: service.type,
        endpoint: service.url,
        name: this.hosPlayerServerName(peer, service)
      };
      this.hosPlayerLauncher!.launch(request).then(() => {
        const doneState: DeviceMediaState = {
          peerKey: peer.key,
          result: this.mediaState(peer.key).result,
          checking: false,
          launching: false
        };
        this.updateMediaState(peer.key, doneState);
        this.host.recordFeatureDiagnosticEvent('hosplayer_launch_success', service.type);
      }).catch(() => {
        const failedState: DeviceMediaState = {
          peerKey: peer.key,
          result: this.mediaState(peer.key).result,
          checking: false,
          launching: false
        };
        this.updateMediaState(peer.key, failedState);
        this.host.recordFeatureDiagnosticEvent('hosplayer_launch_failed', service.type);
        this.host.showPeerIntegrationToast('hosplayer_open_failed_toast');
      });
    } catch (_error) {
      const rejectedState: DeviceMediaState = {
        peerKey: peer.key,
        result: state.result,
        checking: false,
        launching: false
      };
      this.updateMediaState(peer.key, rejectedState);
      this.host.recordFeatureDiagnosticEvent('hosplayer_contract_rejected', service.type);
      this.host.showPeerIntegrationToast('hosplayer_unsafe_endpoint_toast');
    }
  }

  runMediaIntegrationSelfTest(): void {
    if (this.host.isMediaSelfTestInProgress()) {
      return;
    }
    this.ensureMediaServices();
    this.host.setMediaSelfTestInProgress(true);
    this.host.setMediaSelfTestStatusKind('running');
    this.host.recordFeatureDiagnosticEvent('media_self_test_started', 'offline');
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
      this.host.setMediaSelfTestStatusKind(passed ? 'passed' : 'failed_export');
      this.host.recordFeatureDiagnosticEvent(
        passed ? 'media_self_test_passed' : 'media_self_test_failed',
        'offline'
      );
    }).catch(() => {
      if (!this.diagnosticMediaRequestGuard.isCurrent(requestGeneration)) {
        return;
      }
      this.host.setMediaSelfTestStatusKind('unavailable');
      this.host.recordFeatureDiagnosticEvent('media_self_test_failed', 'native_bridge');
    }).finally(() => {
      if (this.diagnosticMediaRequestGuard.isCurrent(requestGeneration)) {
        this.host.setMediaSelfTestInProgress(false);
      }
    });
  }

  copyHosPlayerPrototype(): void {
    this.ensureMediaServices();
    try {
      const result: string = this.hosPlayerLauncher!.runOfflineSelfTest();
      const separator: number = result.indexOf(' | ');
      if (separator < 0) {
        throw new Error('prototype_unavailable');
      }
      this.host.copyHosPlayerPrototypeText(result.substring(separator + 3));
      this.host.recordFeatureDiagnosticEvent('hosplayer_contract_copied', 'offline');
    } catch (_error) {
      this.host.showPeerIntegrationToast('hosplayer_import_link_failed_toast');
      this.host.recordFeatureDiagnosticEvent('hosplayer_contract_failed', 'offline');
    }
  }
}
