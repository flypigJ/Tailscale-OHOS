import { AccountProfiles } from '../services/AccountProfiles';
import { VpnAutoRecovery } from '../services/VpnAutoRecovery';
import { PathDiagnosticService } from '../services/PathDiagnosticService';
import { Want } from '@kit.AbilityKit';
import { DnsSettings, DnsSettingsStore } from '../services/DnsSettings';
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { rpc } from '@kit.IPCKit';
import { fileIo } from '@kit.CoreFileKit';
import nativeBridge from 'libtailscale_ohos.so';
import { RuntimeDiagnosticService } from '../services/RuntimeDiagnosticService';
import { DiagnosticEventContext, DiagnosticEventStore } from '../services/DiagnosticEventStore';
import { DiagnosticPrivacy } from '../services/DiagnosticPrivacy';
import { RecoverableCachePaths } from '../services/RecoverableCachePaths';
import {
  clearTaildropProgress,
  publishTaildropProgress,
  publishTaildropSavePrompt,
  TaildropNotificationFile
} from '../services/TaildropNotificationService';
import { ControlServerConfig, ControlServerSettings } from '../services/ControlServerConfig';
import { ControlServerPresets } from '../services/ControlServerPresets';
import { DeviceNameService } from '../services/DeviceNameService';
import { VpnNetworkMonitor } from '../services/VpnNetworkMonitor';
import { VpnDnsObserver, VpnDnsObservationSummary } from '../services/VpnDnsObserver';
import { TailnetDnsPreferences } from '../services/TailnetDnsPreferences';
import { PhysicalDnsService, PhysicalDnsSnapshot } from '../services/PhysicalDnsService';
import { DnsRuntimeService, DnsSystemPlan } from '../services/DnsRuntimeService';
import BuildProfile from 'BuildProfile';
import { DnsRebuildPolicy } from '../services/DnsRebuildPolicy';
import { VpnExtensionRpcServer, VpnRawRpcEnvelope } from '../services/VpnExtensionRpcChannel';
import {
  AccountSummary,
  DnsSystemStatus,
  LOCAL_SEND_REFRESH_REQUEST_FILE_NAME,
  LOCAL_SEND_REFRESH_RESPONSE_FILE_NAME,
  LocalSendRefreshRequest,
  LocalSendRefreshResponse,
  LocalSendStatus,
  MEDIA_SERVICE_PROBE_REQUEST_FILE_NAME,
  MEDIA_SERVICE_PROBE_RESPONSE_FILE_NAME,
  MeshArcReceiverStatus,
  PEER_CONNECTIVITY_REQUEST_FILE_NAME,
  PEER_CONNECTIVITY_RESPONSE_FILE_NAME,
  PeerSummary,
  PersistedPeerSnapshot,
  PersistedTaildropSnapshot,
  RPC_CHANNEL_FILE_NAMES,
  SUNSHINE_PROBE_REQUEST_FILE_NAME,
  SUNSHINE_PROBE_RESPONSE_FILE_NAME,
  TAILDRIVE_CONTROL_REQUEST_FILE_NAME,
  TAILDRIVE_CONTROL_RESPONSE_FILE_NAME,
  TAILDRIVE_MANUAL_TRANSFER_REQUEST_FILE_NAME,
  TAILDRIVE_MANUAL_TRANSFER_RESPONSE_FILE_NAME,
  TAILDRIVE_QUERY_REQUEST_FILE_NAME,
  TAILDRIVE_QUERY_RESPONSE_FILE_NAME,
  TAILDRIVE_TRANSFER_REQUEST_FILE_NAME,
  TAILDRIVE_TRANSFER_RESPONSE_FILE_NAME,
  TAILDROP_CANCEL_REQUEST_FILE_NAME,
  TAILDROP_INBOX_DIR_NAME,
  TAILDROP_INBOX_SNAPSHOT_FILE_NAME,
  TAILDROP_RECEIVE_REQUEST_FILE_NAME,
  TAILDROP_RECEIVE_RESPONSE_FILE_NAME,
  TAILDROP_SEND_REQUEST_FILE_NAME,
  TAILDROP_TARGETS_FILE_NAME,
  TaildriveExtensionRequest,
  TaildropCancelRequest,
  TaildropIncomingFileSummary,
  TaildropReceiveRequest,
  TaildropReceiveResult,
  TaildropSendFile,
  TaildropSendRequest,
  TaildropSnapshot,
  TaildropTargetSummary,
  TaildropTransferSummary,
  TaildropWaitingFileSummary,
  VPN_BACKEND_HANDOFF_REQUEST_FILE_NAME,
  VPN_BACKEND_HANDOFF_RESPONSE_FILE_NAME,
  VPN_CONFIG_SUMMARY_FILE_NAME,
  VPN_CONNECT_CONFIG_FILE_NAME,
  VPN_PEERS_FILE_NAME,
  VPN_PROBE_STATUS_FILE_NAME,
  VPN_REPLACE_APPROVAL_FILE_NAME,
  VPN_STOP_REQUEST_FILE_NAME,
  VPN_STOP_RESPONSE_FILE_NAME,
  VpnBackendHandoffRequest,
  VpnBackendHandoffResponse,
  VpnConnectConfigHandoff,
  VpnStopRequest,
  VpnStopResponse,
  emptyMeshArcReceiverStatus,
  emptyTaildropTransfer
} from '@tailscale/common';

const DOMAIN = 0x0000;
const TAG = 'TailscaleVpn';
const BUNDLE_NAME = 'io.github.tailscaleohos';
const VPN_EXISTS_ERROR_CODE: number = 2203002;
const VPN_DESTROY_SETTLE_MS: number = 300;
const VPN_REPLACE_APPROVAL_POLL_INTERVAL_MS: number = 200;
const VPN_REPLACE_CREATE_MAX_ATTEMPTS: number = 6;
const VPN_REPLACE_CREATE_RETRY_MS: number = 500;
const VPN_REPLACE_APPROVAL_TTL_MS: number = 10000;
const VPN_BACKEND_HANDOFF_POLL_INTERVAL_MS: number = 100;
const VPN_BACKEND_HANDOFF_MAX_ATTEMPTS: number = 150;
const TAILDRIVE_REQUEST_MAX_BYTES: number = 131072;
const TAILDROP_CACHE_RETENTION_MS: number = 7 * 24 * 60 * 60 * 1000;
const VPN_CONNECT_CONFIG_TTL_MS: number = 15000;
const VPN_BACKEND_STATUS_POLL_INTERVAL_MS: number = 100;
const VPN_BACKEND_STATUS_MAX_ATTEMPTS: number = 150;
const FILE_WATCH_CLOSE_WRITE: number = 0x8;

interface PeerSnapshotSignaturePayload {
  peers: PeerSummary[];
  meshArcReceiver: MeshArcReceiverStatus;
  account?: AccountSummary;
}

interface DnsDiagnosticRequest {
  requestId: number;
  createdMs: number;
  peerKey: string;
}

interface DnsDiagnosticReply {
  requestId: number;
  result: string;
}

interface PersistedTaildropMediaPreview {
  path: string;
  thumbnailPath: string;
}

interface PersistedTaildropCachedFile {
  path: string;
}

interface PersistedTaildropInboxCache {
  mediaPreviews?: PersistedTaildropMediaPreview[];
  cachedFiles?: PersistedTaildropCachedFile[];
}

interface BackendHealthSnapshot {
  status: string;
  peers: PeerSummary[];
  account?: AccountSummary;
  taildrop: TaildropSnapshot;
  meshArcReceiver: MeshArcReceiverStatus;
}

interface PeerConnectivityRequest {
  requestId: number;
  peerKey: string;
}

interface SunshineProbeRequest {
  requestId: number;
  peerKey: string;
}

interface MediaServiceProbeRequest {
  requestId: number;
  peerKey: string;
}

interface TaildriveOperationResultSummary {
  state: string;
  reason?: string;
}

interface DebugDnsRebuildRequest {
  requestId: number;
  createdMs: number;
}

interface DebugDnsRebuildReply {
  requestId: number;
  completed: boolean;
  sessionChanged: boolean;
  sameConfiguration: boolean;
  running: boolean;
  statusCode: number;
  tunPresent: boolean;
  failed: boolean;
  conflict: boolean;
  handoffFailed: boolean;
  dnsUnavailable: boolean;
  backendTimeout: boolean;
}

export default class TailscaleVpnExtensionAbility extends VpnExtensionAbility {
  // Created on the first bind and kept alive for the life of the Extension.
  private bindStub: rpc.RemoteObject | undefined = undefined;

  /**
   * The UI process binds this Extension (VpnBackgroundTaskManager.bindVpnExtension)
   * so that the system records an app process as connected to it: an unbound
   * Extension sits in the lowest low-memory-kill tier (oom_score_adj 500, 300 once
   * bound). The returned object carries no calls, but returning a valid
   * RemoteObject is required so the framework does not terminate the Extension.
   */
  onConnect(_want: Want): rpc.RemoteObject {
    if (this.bindStub === undefined) {
      this.bindStub = new rpc.RemoteObject('io.github.tailscaleohos.vpn.bind');
    }
    if (!this.destroying) {
      this.recordDiagnosticEvent('vpn_extension_bound', 'lifecycle');
    }
    return this.bindStub;
  }

  private serverProfileId: string = '';
  private serverStateRoot: string = '';
  private serverProfileToken: string = '';
  private serverControlURL: string = '';

  private dnsSystemPlan?: DnsSystemPlan;
  private dnsBaseFingerprint: string = '';
  private dnsBaseRefreshInFlight: boolean = false;
  private nextDnsBaseRefreshMs: number = 0;
  private dnsDiagnosticInFlight: boolean = false;
  private lastDnsDiagnosticRequest: number = 0;
  private lastDebugDnsRebuildRequest: number = 0;
  private dnsRebuildInFlight: boolean = false;
  private dnsInternalRebuild: boolean = false;
  private dnsRecoverWithoutTailnetDns: boolean = false;
  private dnsSystemApplied: boolean = false;
  private backendHandoffCompleted: boolean = false;
  private rpcChannelsInitialized: boolean = false;
  private rpcServer?: VpnExtensionRpcServer;
  private readonly dnsRebuildPolicy: DnsRebuildPolicy = new DnsRebuildPolicy();
  private dnsObserver: VpnDnsObserver = new VpnDnsObserver(
    (): Promise<string> => nativeBridge.backendDnsConfigAsync(), (summary: VpnDnsObservationSummary): void => {
      this.writeAtomicTextFile(`${this.context.filesDir}/vpn-dns-observation.json`, JSON.stringify(summary));
    }, (): boolean => this.dnsSystemApplied);
  private vpnConnection?: vpnExtension.VpnConnection;
  private tunFd: number = -1;
  private customDnsActive: boolean = false;
  private statusTimer: number = -1;
  private taildropRequestTimer: number = -1;
  private taildropIncomingTimer: number = -1;
  private taildropIncomingDelayMs: number = 0;
  private lastTaildropSnapshotSignature: string = '';
  private lastTaildropSnapshotWriteMs: number = 0;
  private lastPeerSnapshotSignature: string = '';
  private lastPeerSnapshotWriteMs: number = 0;
  private statusUpdateInFlight: boolean = false;
  private peerSnapshotInFlight: boolean = false;
  private peerSnapshotRequestId: number = 0;
  private taildropIncomingSnapshotInFlight: boolean = false;
  private currentVisibleStatus: string = 'VPN extension lifecycle entered';
  private backendStopWatcher?: fileIo.Watcher;
  private peerConnectivityInFlight: boolean = false;
  private sunshineProbeInFlight: boolean = false;
  private mediaServiceProbeInFlight: boolean = false;
  private localSendRefreshInFlight: boolean = false;
  private taildropSendInFlight: boolean = false;
  private taildropCancelInFlight: boolean = false;
  private taildropReceiveInFlight: boolean = false;
  private taildriveQueryInFlight: boolean = false;
  private taildriveTransferInFlight: boolean = false;
  private taildriveManualTransferInFlight: boolean = false;
  private taildriveControlInFlight: boolean = false;
  private backendStopInFlight: boolean = false;
  private backendRestartPromise?: Promise<string>;
  private nativeStopPromise?: Promise<string>;
  private destroying: boolean = false;
  private pathDiagnosticProtection: number = -1;
  private pathDiagnosticProtectionCode: number = 0;
  private explicitStopRequested: boolean = false;
  private lastBackendRuntimeState: number = -1;
  private snapshotUnavailable: boolean = false;
  private lastDiagnosticFailure: string = '';
  private lastDiagnosticFailureAtMs: number = 0;
  private networkMonitor: VpnNetworkMonitor = new VpnNetworkMonitor((event: string, code: number,
    context?: DiagnosticEventContext): void => {
    this.recordDiagnosticEvent(event, 'network', code, context);
    PathDiagnosticService.recordHost(this.pathDiagnosticProtection, context?.networkStage ?? -1,
      context?.networkGeneration ?? -1, context?.networkRevision ?? -1, code, this.pathDiagnosticProtectionCode);
  });
  private taildropInboxNotificationInitialized: boolean = false;
  private notifiedTaildropInboxKeys: string[] = [];
  private taildropProgressNotificationVisible: boolean = false;
  private latestTaildropSnapshot: TaildropSnapshot = {
    state: 'loading', reason: '', targets: [], incomingFiles: [], waitingFiles: [], inboxReason: '',
    transfer: emptyTaildropTransfer()
  };

  private startupIntentMs: number = 0;

  private startupIntentAllowed(): boolean {
    if (this.startupIntentMs !== 0 && !VpnAutoRecovery.permitsStart(this.context.filesDir, this.startupIntentMs)) return false;
    if (this.serverProfileToken.length === 0) return true;
    try {
      return ControlServerConfig.load(this.context.filesDir).controlURL === this.serverControlURL &&
        AccountProfiles.token(this.context.filesDir, this.serverControlURL) === this.serverProfileToken;
    } catch (_error) { return false; }
  }

  private readonly runtimeDiagnostic: RuntimeDiagnosticService = new RuntimeDiagnosticService();

  onCreate(want: Want): void {
    if (want.parameters?.mesharcBindOnly === true) {
      this.destroying = true;
      vpnExtension.stopVpnExtensionAbility(want).catch(() => {});
      return;
    }
    this.runtimeDiagnostic.start(this.context.filesDir, 'vpn');
    const token = want.parameters?.mesharcIntentMs;
    this.startupIntentMs = typeof token === 'number' ? token : 0;
    if (!this.startupIntentAllowed()) {
      this.destroying = true;
      // An authorization dialog can complete after cancellation or a newer
      // user request. That old start must never create a TUN.
      vpnExtension.stopVpnExtensionAbility(want).catch(() => {});
      return;
    }
    this.serverControlURL = ControlServerConfig.load(this.context.filesDir).controlURL;
    if (ControlServerPresets.ensure(this.context.filesDir, this.serverControlURL) === undefined) {
      this.writeStatus('FAILED | VPN cache scope unavailable');
      return;
    }
    try {
      this.serverProfileId = AccountProfiles.current(this.context.filesDir, this.serverControlURL).activeId;
      this.serverProfileToken = AccountProfiles.token(this.context.filesDir, this.serverControlURL);
      this.serverStateRoot = AccountProfiles.stateRoot(this.context.filesDir, this.serverControlURL, this.serverProfileId);
    } catch (_error) {
      this.writeStatus('FAILED | VPN account scope unavailable');
      return;
    }
    this.recordDiagnosticEvent('vpn_extension_created', 'lifecycle');
    this.lastTaildropSnapshotSignature = '';
    this.lastTaildropSnapshotWriteMs = 0;
    this.lastPeerSnapshotSignature = '';
    this.lastPeerSnapshotWriteMs = 0;
    this.writePeerSnapshot([], emptyMeshArcReceiverStatus());
    this.cleanupStaleTaildropOutbox();
    this.cleanupStaleTaildropInbox();
    this.writeTextFile(`${this.context.filesDir}/${TAILDROP_SEND_REQUEST_FILE_NAME}`, '');
    this.writeTextFile(`${this.context.filesDir}/${TAILDROP_CANCEL_REQUEST_FILE_NAME}`, '');
    this.writeTextFile(`${this.context.filesDir}/${TAILDROP_RECEIVE_REQUEST_FILE_NAME}`, '');
    this.writeTextFile(`${this.context.filesDir}/${TAILDROP_RECEIVE_RESPONSE_FILE_NAME}`, '');
    this.resetRpcChannels();
    // A previous extension process can be killed before consuming a graceful
    // stop request. Never let that stale request stop a newly created session.
    this.writeTextFile(`${this.context.filesDir}/${VPN_STOP_REQUEST_FILE_NAME}`, '');
    this.writeTextFile(`${this.context.filesDir}/${VPN_STOP_RESPONSE_FILE_NAME}`, '');
    this.writeTextFile(`${this.context.filesDir}/${VPN_BACKEND_HANDOFF_REQUEST_FILE_NAME}`, '');
    this.writeTextFile(`${this.context.filesDir}/${VPN_BACKEND_HANDOFF_RESPONSE_FILE_NAME}`, '');
    this.writeTextFile(`${this.context.filesDir}/${LOCAL_SEND_REFRESH_REQUEST_FILE_NAME}`, '');
    this.writeTextFile(`${this.context.filesDir}/${LOCAL_SEND_REFRESH_RESPONSE_FILE_NAME}`, '');
    this.startBackendStopWatcher();
    this.writeTextFile(`${this.context.filesDir}/${VPN_CONFIG_SUMMARY_FILE_NAME}`, '');
    this.writeTaildropSnapshot({
      state: 'loading', reason: '', targets: [], incomingFiles: [], waitingFiles: [], inboxReason: '',
      transfer: emptyTaildropTransfer()
    });
    this.writeStatus('VPN extension lifecycle entered');
    hilog.info(DOMAIN, TAG, 'VPN extension created. ability=%{public}s', want.abilityName ?? '');
    try {
      this.vpnConnection = vpnExtension.createVpnConnection(this.context);
      this.writeStatus('VPN connection object created');
      this.createProbeTun().catch((error: BusinessError) => {
        if (this.destroying) {
          return;
        }
        const errorCode: number = error.code ?? -1;
        this.recordDiagnosticEvent('vpn_create_failed', 'extension', errorCode);
        this.writeStatus(`FAILED | VPN extension startup | code=${errorCode}`);
        hilog.error(DOMAIN, TAG, 'VPN extension startup failed. code=%{public}d', errorCode);
      });
    } catch (error) {
      const businessError = error as BusinessError;
      this.writeStatus(`FAILED | VPN connection object | code=${businessError.code ?? -1}`);
      hilog.error(DOMAIN, TAG, 'VPN connection initialization failed. code=%{public}d',
        businessError.code ?? -1);
    }
  }

  private async createProbeTun(): Promise<void> {
    if (this.vpnConnection === undefined || (this.destroying || this.explicitStopRequested || this.backendStopInFlight || !this.startupIntentAllowed())) {
      return;
    }
    const resetHandoffFlag: boolean = Date.now() < 0;
    this.backendHandoffCompleted = resetHandoffFlag;
    const startupConnection: vpnExtension.VpnConnection = this.vpnConnection;
    const controlSettings: ControlServerSettings = ControlServerConfig.load(this.context.filesDir);
    if (controlSettings.controlURL !== this.serverControlURL ||
      AccountProfiles.token(this.context.filesDir, this.serverControlURL) !== this.serverProfileToken) {
      throw new Error('VPN account changed');
    }
    if (ControlServerPresets.ensure(this.context.filesDir, this.serverControlURL) === undefined) {
      throw new Error('Control server cache scope unavailable');
    }
    if (!controlSettings.confirmed) {
      this.writeStatus('FAILED | VPN backend | control server not configured');
      this.recordDiagnosticEvent('vpn_control_server_missing', 'preflight');
      return;
    }

    // Until login is complete, use a documentation-only route that cannot
    // intercept normal device traffic. Once the persistent backend is Running,
    // replace it with the assigned Tailscale addresses and tailnet ranges.
    let backendReady: boolean = false;
    let config: vpnExtension.VpnConfig = {
      addresses: [{
        address: { address: '192.0.2.1', family: 1 },
        prefixLength: 32
      }],
      routes: [{
        interface: 'vpn-tun',
        destination: {
          address: { address: '192.0.2.0', family: 1 },
          prefixLength: 24
        },
        gateway: { address: '0.0.0.0', family: 1 },
        hasGateway: false,
        isDefaultRoute: false
      }],
      mtu: 1280,
      isIPv4Accepted: true,
      isIPv6Accepted: false,
      isBlocking: false,
      trustedApplications: [BUNDLE_NAME]
    };
    // HarmonyOS starts a VPN Extension in its own application process. The
    // UI process may have already authenticated, but its in-memory Go backend
    // is not shared with this process. Restore the backend from the persistent
    // state directory here and wait until the assigned addresses are ready.
    const acceptTailnetDns: boolean = !this.dnsRecoverWithoutTailnetDns &&
      TailnetDnsPreferences.enabled(this.context.filesDir);
    const loadedCustomDns: DnsSettings = DnsSettingsStore.load(this.context.filesDir);
    const customDnsEnabled: boolean = !this.dnsRecoverWithoutTailnetDns && loadedCustomDns.enabled;
    let useTailnetDns: boolean = acceptTailnetDns || customDnsEnabled;
    this.customDnsActive = customDnsEnabled;
    let dnsDegradedZeroPhysical: boolean = false;
    let dnsBootstrapHandoff: boolean = false;
    let backendConfigText: string = '';
    try {
      const physical: PhysicalDnsSnapshot | undefined = acceptTailnetDns && !customDnsEnabled ?
        await PhysicalDnsService.read() : undefined;
      if (await this.stopCancelledStartup(startupConnection)) return;
      if (acceptTailnetDns && !customDnsEnabled && (physical === undefined || physical.resolvers.length === 0)) {
        useTailnetDns = false;
        dnsDegradedZeroPhysical = true;
        const emptyPhysicalFallback: PhysicalDnsSnapshot = { networkId: 0, resolvers: [] };
        const resolvedPhysical: PhysicalDnsSnapshot = physical ?? emptyPhysicalFallback;
        this.dnsBaseFingerprint = JSON.stringify(resolvedPhysical);
        await DnsRuntimeService.stage(false, [], [], []);
        if (await this.stopCancelledStartup(startupConnection)) return;
        this.dnsSystemPlan = undefined;
        backendConfigText = await this.restoreBackendVpnConfig();
      } else {
        await DnsRuntimeService.stage(acceptTailnetDns, physical?.resolvers ?? [],
          customDnsEnabled ? DnsSettingsStore.upstreams(loadedCustomDns) : [],
          customDnsEnabled ? loadedCustomDns.searchDomains : []);
        if (await this.stopCancelledStartup(startupConnection)) return;
        if (useTailnetDns) {
          const handoff: string = this.dnsInternalRebuild ? 'OK' : await this.requestUiBackendHandoff();
          if (await this.stopCancelledStartup(startupConnection)) return;
          if (!handoff.startsWith('OK')) throw new Error('DNS identity handoff unavailable');
          dnsBootstrapHandoff = true;
          this.nativeStopPromise = undefined;
          const started: string = nativeBridge.backendStart(this.serverStateRoot,
            this.deviceModel(), this.harmonyOSHostinfoVersion(), controlSettings.controlURL);
          const status: string = await this.waitForVpnBackend(started);
          if (await this.stopCancelledStartup(startupConnection)) return;
          if (!status.includes('state=Running')) throw new Error('DNS bootstrap unavailable');
          this.dnsSystemPlan = await this.waitForDnsSystemPlan();
          if (await this.stopCancelledStartup(startupConnection)) return;
          this.dnsBaseFingerprint = JSON.stringify(physical);
          backendConfigText = await nativeBridge.backendVpnConfigAsync();
        } else {
          this.dnsSystemPlan = undefined;
          backendConfigText = await this.restoreBackendVpnConfig();
        }
      }
    } catch (_error) {
      if (await this.stopCancelledStartup(startupConnection)) return;
      await this.finishDestroyedBackend(startupConnection);
      this.dnsSystemPlan = undefined;
      this.writeDnsSystemStatus('unavailable', false);
      this.writeStatus('FAILED | VPN DNS | startup unavailable');
      return;
    }
    if (await this.stopCancelledStartup(startupConnection)) {
      return;
    }
    if (backendConfigText.startsWith('FAILED | backend handoff')) {
      this.writeDnsSystemStatus('stopped', false);
      this.writeStatus(backendConfigText);
      return;
    }
    if (!backendConfigText.startsWith('FAILED')) {
      const configParts: string[] = backendConfigText.split('|');
      if (configParts.length >= 2 && configParts[0].length > 0) {
        const addresses: vpnExtension.LinkAddress[] = [{
          address: { address: configParts[0], family: 1 },
          prefixLength: 32
        }];
        const routes: vpnExtension.RouteInfo[] = [{
          interface: 'vpn-tun',
          destination: {
            address: { address: '100.64.0.0', family: 1 },
            prefixLength: 10
          },
          gateway: { address: '0.0.0.0', family: 1 },
          hasGateway: false,
          isDefaultRoute: false
        }];
        if (configParts[1].length > 0) {
          addresses.push({
            address: { address: configParts[1], family: 2 },
            prefixLength: 128
          });
          routes.push({
            interface: 'vpn-tun',
            destination: {
              address: { address: 'fd7a:115c:a1e0::', family: 2 },
              prefixLength: 48
            },
            gateway: { address: '', family: 2 },
            hasGateway: false,
            isDefaultRoute: false
          });
        }
        if (configParts.length >= 3 && configParts[2].length > 0) {
          const dynamicRoutes: string[] = configParts[2].split(',');
          for (const routeText of dynamicRoutes) {
            const prefixParts: string[] = routeText.split('/');
            if (prefixParts.length !== 2) {
              continue;
            }
            const family: number = prefixParts[0].includes(':') ? 2 : 1;
            const prefixLength: number = Number(prefixParts[1]);
            routes.push({
              interface: 'vpn-tun',
              destination: {
                address: { address: prefixParts[0], family: family },
                prefixLength: prefixLength
              },
              gateway: { address: family === 2 ? '' : '0.0.0.0', family: family },
              hasGateway: false,
              isDefaultRoute: prefixLength === 0
            });
          }
        }
        config = {
          addresses: addresses,
          routes: routes,
          dnsAddresses: [],
          searchDomains: [],
          mtu: 1280,
          isIPv4Accepted: true,
          isIPv6Accepted: configParts[1].length > 0,
          isInternal: true,
          isBlocking: false,
          blockedApplications: [BUNDLE_NAME]
        };
        backendReady = true;
      }
    }

    try {
      if (this.dnsSystemPlan !== undefined) {
        config.dnsAddresses = this.dnsSystemPlan.dnsAddresses.slice();
        config.searchDomains = this.dnsSystemPlan.searchDomains.slice();
      }
      const initialDnsState: string = useTailnetDns ? 'pending' :
        ((dnsDegradedZeroPhysical || this.dnsRecoverWithoutTailnetDns) ? 'unavailable' : 'disabled');
      this.writeDnsSystemStatus(initialDnsState, false);
      this.writeVpnConfigSummary(config);
      this.writeStatus('VPN probe TUN creation pending');
      this.tunFd = await this.createTunWithConflictReplacement(config);
      if (await this.stopCancelledStartup(startupConnection)) return;
      if (this.tunFd < 0) {
        return;
      }
      this.recordDiagnosticEvent('vpn_tun_created', 'create');
      const probeStatus: string = nativeBridge.tunFdProbe(this.tunFd);
      if (backendReady && probeStatus.startsWith('OK')) {
        try {
          await this.vpnConnection.protectProcessNet();
          this.pathDiagnosticProtection = 1;
          this.pathDiagnosticProtectionCode = 0;
          this.recordDiagnosticEvent('vpn_process_protected', 'network');
        } catch (error) {
          this.pathDiagnosticProtection = 2;
          this.pathDiagnosticProtectionCode = (error as BusinessError).code ?? -1;
          // blockedApplications already excludes this bundle; keep it as the
          // compatibility fallback when process-wide protection is unavailable.
          this.recordDiagnosticEvent('vpn_process_protect_failed', 'network', (error as BusinessError).code ?? -1);
        }
        if (await this.stopCancelledStartup(startupConnection)) {
          return;
        }
        const handoffStatus: string = (dnsBootstrapHandoff || Boolean(this.backendHandoffCompleted) ||
          Boolean(this.dnsInternalRebuild)) ? 'OK' : await this.requestUiBackendHandoff();
        if (await this.stopCancelledStartup(startupConnection)) {
          return;
        }
        if (!handoffStatus.startsWith('OK')) {
          this.writeStatus(handoffStatus);
          await this.destroyProbeTun();
          return;
        }
        this.writeStatus('VPN interface established | backend starting');
        this.nativeStopPromise = undefined;
        const restart: Promise<string> = nativeBridge.backendRestartWithTunAsync(
          this.serverStateRoot, this.deviceModel(), this.harmonyOSHostinfoVersion(),
          controlSettings.controlURL, this.tunFd);
        this.backendRestartPromise = restart;
        const restartStatus: string = await restart;
        if (await this.stopCancelledStartup(startupConnection)) return;
        const finalStatus: string = await this.waitForVpnBackend(restartStatus);
        if (await this.stopCancelledStartup(startupConnection)) {
          return;
        }
        this.writeStatus(finalStatus);
        if (finalStatus.includes('state=Running')) {
          if (useTailnetDns && this.dnsSystemPlan !== undefined) {
            const expected: DnsSystemPlan = this.dnsSystemPlan;
            const actual: DnsSystemPlan = await this.waitForDnsSystemPlan();
            if (await this.stopCancelledStartup(startupConnection)) return;
            if (actual.session === expected.session || !DnsRuntimeService.sameConfiguration(expected, actual)) {
              throw new Error('DNS system plan changed during startup');
            }
            this.dnsSystemPlan = actual;
            this.writeDnsSystemStatus('applied', true);
          }
          this.recordDiagnosticEvent('vpn_connected', 'backend');
          // An optional peer probe must not delay the connection heartbeat.
          this.startStatusUpdates();
          this.networkMonitor.start();
          const peerStatus: string = await nativeBridge.backendPeerProbeAsync();
          if (await this.stopCancelledStartup(startupConnection)) {
            return;
          }
          this.writePeerStatus(peerStatus);
        }
      } else {
        const backendState: string = backendConfigText.startsWith('FAILED') ?
          backendConfigText : 'FAILED | VPN config | invalid address payload';
        this.writeStatus(`${probeStatus} | ${backendState}`);
      }
      hilog.info(DOMAIN, TAG, 'VPN probe TUN created. bridge=%{public}s', probeStatus);
    } catch (error) {
      if (await this.stopCancelledStartup(startupConnection)) return;
      if (useTailnetDns) {
        await this.finishDestroyedBackend(startupConnection);
        this.dnsSystemPlan = undefined;
        this.writeDnsSystemStatus('unavailable', false);
      }
      const businessError = error as BusinessError;
      const errorCode: number = businessError.code ?? -1;
      if (errorCode === VPN_EXISTS_ERROR_CODE) {
        this.recordDiagnosticEvent('vpn_conflict', 'create', errorCode);
        this.writeStatus(`FAILED | VPN conflict | code=${VPN_EXISTS_ERROR_CODE}`);
      } else {
        this.recordDiagnosticEvent('vpn_create_failed', 'create', errorCode);
        this.writeStatus(`FAILED | VPN probe TUN | code=${errorCode}`);
      }
      hilog.error(DOMAIN, TAG, 'VPN probe TUN creation failed. code=%{public}d',
        errorCode);
    }
  }

  private async waitForDnsSystemPlan(): Promise<DnsSystemPlan> {
    for (let attempt: number = 0; attempt < 40; attempt++) {
      if (this.destroying || this.explicitStopRequested || this.backendStopInFlight || !this.startupIntentAllowed()) {
        throw new Error('DNS startup cancelled');
      }
      const plan: DnsSystemPlan = await DnsRuntimeService.read();
      if (plan.state === 'ready' && plan.revision > 0 && plan.dnsAddresses.length > 0) return plan;
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 100));
    }
    throw new Error('DNS plan unavailable');
  }

  private writeDnsSystemStatus(state: string, applied: boolean): void {
    const systemApplied: boolean = applied && (this.dnsSystemPlan?.dnsAddresses.length ?? 0) > 0;
    const changed: boolean = this.dnsSystemApplied !== systemApplied;
    this.dnsSystemApplied = systemApplied;
    const status: DnsSystemStatus = { schemaVersion: 1, state: state,
      systemDnsApplied: systemApplied,
      dnsAddressCount: this.dnsSystemPlan?.dnsAddresses.length ?? 0,
      searchDomainCount: this.dnsSystemPlan?.searchDomains.length ?? 0 };
    this.writeAtomicTextFile(`${this.context.filesDir}/vpn-dns-system-status.json`, JSON.stringify(status));
    if (changed && this.dnsObserver !== undefined && typeof this.dnsObserver.republish === 'function') {
      this.dnsObserver.republish();
    }
  }

  private async refreshPhysicalDnsBase(): Promise<void> {
    const expected: DnsSystemPlan | undefined = this.dnsSystemPlan;
    if (expected === undefined || this.destroying || this.explicitStopRequested || this.backendStopInFlight ||
      this.dnsBaseRefreshInFlight || Date.now() < this.nextDnsBaseRefreshMs) return;
    this.dnsBaseRefreshInFlight = true;
    this.nextDnsBaseRefreshMs = Date.now() + 5000;
    try {
      const emptyPhysical: PhysicalDnsSnapshot = { networkId: 0, resolvers: [] };
      const physical: PhysicalDnsSnapshot = this.customDnsActive ?
        emptyPhysical : await PhysicalDnsService.read();
      if (this.destroying || this.explicitStopRequested || this.backendStopInFlight ||
        this.dnsSystemPlan?.session !== expected.session) return;
      const fingerprint: string = JSON.stringify(physical);
      if (!this.customDnsActive && physical.resolvers.length === 0) {
        this.dnsBaseFingerprint = fingerprint;
        this.writeDnsSystemStatus('unavailable', true);
        return;
      }
      const baseChanged: boolean = !this.customDnsActive && fingerprint !== this.dnsBaseFingerprint;
      if (baseChanged) {
        await DnsRuntimeService.update(expected.session, physical.resolvers);
      }
      if (this.destroying || this.explicitStopRequested || this.backendStopInFlight ||
        this.dnsSystemPlan?.session !== expected.session) return;
      if (baseChanged) this.recordDiagnosticEvent('vpn_dns_base_updated', 'dns', physical.resolvers.length);
      const actual: DnsSystemPlan = await DnsRuntimeService.read();
      if (this.destroying || this.explicitStopRequested || this.backendStopInFlight ||
        this.dnsSystemPlan?.session !== expected.session || actual.session !== expected.session) return;
      if (actual.state !== 'ready') {
        this.writeDnsSystemStatus('unavailable', true);
        return;
      }
      if (!DnsRuntimeService.sameConfiguration(expected, actual)) {
        await this.rebuildDnsVpn(actual);
        return;
      }
      this.dnsSystemPlan = actual;
      this.dnsBaseFingerprint = fingerprint;
      this.writeDnsSystemStatus('applied', true);
    } catch (_error) {
      if (!this.destroying && !this.explicitStopRequested && !this.backendStopInFlight &&
        this.dnsSystemPlan?.session === expected.session) this.writeDnsSystemStatus('unavailable', true);
    } finally { this.dnsBaseRefreshInFlight = false; }
  }

  private dnsActiveTransferInFlight(): boolean {
    return Boolean(this.taildropSendInFlight || this.taildropReceiveInFlight ||
      this.taildriveTransferInFlight || this.taildriveManualTransferInFlight);
  }

  private dnsRequestsDrained(): boolean {
    return !this.statusUpdateInFlight && !this.peerSnapshotInFlight && !this.taildropIncomingSnapshotInFlight &&
      !this.peerConnectivityInFlight && !this.sunshineProbeInFlight && !this.mediaServiceProbeInFlight &&
      !this.localSendRefreshInFlight && !this.taildropSendInFlight && !this.taildropCancelInFlight &&
      !this.taildropReceiveInFlight && !this.taildriveQueryInFlight && !this.taildriveTransferInFlight &&
      !this.taildriveManualTransferInFlight && !this.taildriveControlInFlight && !this.dnsDiagnosticInFlight;
  }

  private async rebuildDnsVpn(plan: DnsSystemPlan): Promise<void> {
    if (this.dnsRebuildInFlight || this.destroying || this.explicitStopRequested || this.backendStopInFlight ||
      !this.startupIntentAllowed()) {
      this.writeDnsSystemStatus('reconnect_required', true);
      return;
    }
    if (this.dnsActiveTransferInFlight()) {
      this.nextDnsBaseRefreshMs = 0;
      this.writeDnsSystemStatus('reconfiguring', true);
      return;
    }
    const key: string = JSON.stringify([plan.dnsAddresses, plan.searchDomains]);
    if (!this.dnsRebuildPolicy.begin(key, Date.now())) {
      this.writeDnsSystemStatus('reconnect_required', true);
      return;
    }
    this.dnsRebuildInFlight = true;
    let ownsStopFlag: boolean = false;
    let succeeded: boolean = false;
    const connection: vpnExtension.VpnConnection | undefined = this.vpnConnection;
    try {
      const deadline: number = Date.now() + 5000;
      while (!this.dnsRequestsDrained() && Date.now() < deadline && !this.destroying &&
        !this.explicitStopRequested && this.startupIntentAllowed()) {
        await new Promise<void>((resolve: () => void) => setTimeout(resolve, 50));
      }
      if (this.destroying || this.explicitStopRequested || !this.startupIntentAllowed()) {
        await this.finishDestroyedBackend(connection);
        if (this.vpnConnection === connection) { this.vpnConnection = undefined; this.tunFd = -1; }
        this.dnsSystemPlan = undefined;
        this.writeDnsSystemStatus('stopped', false);
        this.writeStatus('VPN disconnected | DNS transition cancelled');
        return;
      }
      if (!this.dnsRequestsDrained()) {
        this.writeDnsSystemStatus('reconnect_required', true);
        return;
      }
      this.dnsInternalRebuild = true;
      this.backendStopInFlight = true;
      ownsStopFlag = true;
      this.writeStatus('VPN DNS restarting');
      this.networkMonitor.stop();
      this.dnsObserver.stop();
      await PathDiagnosticService.shutdown(this.context.filesDir);
      if (this.destroying || this.explicitStopRequested || !this.startupIntentAllowed()) {
        this.backendStopInFlight = false;
        ownsStopFlag = false;
        await this.finishDestroyedBackend(connection);
        if (this.vpnConnection === connection) { this.vpnConnection = undefined; this.tunFd = -1; }
        this.dnsSystemPlan = undefined;
        this.writeDnsSystemStatus('stopped', false);
        this.writeStatus('VPN disconnected | DNS transition cancelled');
        return;
      }
      if (connection !== undefined) await connection.destroy();
      if (this.vpnConnection === connection) { this.vpnConnection = undefined; this.tunFd = -1; }
      this.dnsSystemPlan = undefined;
      this.writeDnsSystemStatus('reconfiguring', false);
      await this.stopNativeBackend();
      this.backendStopInFlight = false;
      ownsStopFlag = false;
      if (this.destroying || this.explicitStopRequested || !this.startupIntentAllowed()) {
        this.writeStatus('VPN disconnected | DNS transition cancelled');
        return;
      }
      if (this.processBackendStopRequest()) return;
      this.nativeStopPromise = undefined;
      this.backendRestartPromise = undefined;
      // The repository's replacement flow recreates a VPN through the same
      // connection after destroy. Retain that SDK owner during DNS transitions.
      this.vpnConnection = connection ?? vpnExtension.createVpnConnection(this.context);
      await this.createProbeTun();
      succeeded = !this.destroying && !this.explicitStopRequested && this.startupIntentAllowed() &&
        this.dnsSystemPlan !== undefined && this.tunFd >= 0 &&
        this.currentVisibleStatus.includes('state=Running') &&
        this.currentVisibleStatus.includes('tun=true');
      if (!succeeded && !this.destroying && !this.explicitStopRequested && !this.startupIntentAllowed()) {
        const cancelledConnection: vpnExtension.VpnConnection | undefined = this.vpnConnection ?? connection;
        await this.finishDestroyedBackend(cancelledConnection);
        if (this.vpnConnection === cancelledConnection) { this.vpnConnection = undefined; this.tunFd = -1; }
        this.dnsSystemPlan = undefined;
        this.writeDnsSystemStatus('stopped', false);
        this.writeStatus('VPN disconnected | DNS transition cancelled');
        return;
      }
      if (!succeeded && !this.destroying && !this.explicitStopRequested && this.startupIntentAllowed()) {
        const failedAttemptConnection: vpnExtension.VpnConnection | undefined = this.vpnConnection ?? connection;
        await this.finishDestroyedBackend(failedAttemptConnection);
        if (this.vpnConnection === failedAttemptConnection) { this.vpnConnection = undefined; this.tunFd = -1; }
        this.dnsSystemPlan = undefined;
        if (!this.dnsRecoverWithoutTailnetDns && !this.destroying &&
          !this.explicitStopRequested && this.startupIntentAllowed()) {
          this.dnsRecoverWithoutTailnetDns = true;
          try {
            this.nativeStopPromise = undefined;
            this.backendRestartPromise = undefined;
            this.vpnConnection = connection ?? vpnExtension.createVpnConnection(this.context);
            await this.createProbeTun();
          } finally {
            this.dnsRecoverWithoutTailnetDns = false;
          }
          const fallbackRunning: boolean = !this.destroying && !this.explicitStopRequested &&
            this.startupIntentAllowed() && this.tunFd >= 0 &&
            this.currentVisibleStatus.includes('state=Running') &&
            this.currentVisibleStatus.includes('tun=true');
          if (fallbackRunning) {
            this.writeDnsSystemStatus('unavailable', false);
            return;
          }
        }
        if (!this.startupIntentAllowed()) {
          const cancelledFallbackConn: vpnExtension.VpnConnection | undefined = this.vpnConnection ?? connection;
          await this.finishDestroyedBackend(cancelledFallbackConn);
          if (this.vpnConnection === cancelledFallbackConn) { this.vpnConnection = undefined; this.tunFd = -1; }
          this.dnsSystemPlan = undefined;
          this.writeDnsSystemStatus('stopped', false);
          this.writeStatus('VPN disconnected | DNS transition cancelled');
          return;
        }
        throw new Error('DNS transition did not establish a running TUN');
      }
    } catch (_error) {
      if (!this.destroying && !this.explicitStopRequested) {
        const cleanupConnection: vpnExtension.VpnConnection | undefined = this.vpnConnection ?? connection;
        await this.finishDestroyedBackend(cleanupConnection);
        if (this.vpnConnection === cleanupConnection) { this.vpnConnection = undefined; this.tunFd = -1; }
        this.dnsSystemPlan = undefined;
        this.writeDnsSystemStatus('unavailable', false);
        this.writeStatus('FAILED | VPN DNS | reconfiguration unavailable');
      }
    } finally {
      if (ownsStopFlag) this.backendStopInFlight = false;
      this.dnsInternalRebuild = false;
      this.dnsRebuildInFlight = false;
      this.dnsRebuildPolicy.finish(succeeded);
    }
  }

  private async stopCancelledStartup(connection: vpnExtension.VpnConnection): Promise<boolean> {
    if (this.destroying || this.explicitStopRequested || this.backendStopInFlight) return true;
    if (this.startupIntentAllowed()) return false;
    this.explicitStopRequested = true;
    this.dnsObserver.stop();
    this.dnsSystemPlan = undefined;
    this.writeDnsSystemStatus('stopped', false);
    this.tunFd = -1;
    // Capture this instance's connection. Release its TUN immediately, then
    // wait for any already queued native restart before stopping that backend.
    await this.finishDestroyedBackend(connection);
    this.writeStatus('VPN disconnected | cancelled startup');
    vpnExtension.stopVpnExtensionAbility({ bundleName: BUNDLE_NAME,
      abilityName: 'TailscaleVpnExtensionAbility' }).catch(() => {});
    return true;
  }

  private async createTunWithConflictReplacement(config: vpnExtension.VpnConfig): Promise<number> {
    const connection: vpnExtension.VpnConnection | undefined = this.vpnConnection;
    if (connection === undefined) {
      return -1;
    }
    try {
      return await connection.create(config);
    } catch (error) {
      const businessError = error as BusinessError;
      const errorCode: number = businessError.code ?? -1;
      if (errorCode !== VPN_EXISTS_ERROR_CODE) {
        this.recordDiagnosticEvent('vpn_create_failed', 'create', errorCode);
        this.writeStatus(`FAILED | VPN probe TUN | code=${errorCode}`);
        hilog.error(DOMAIN, TAG, 'VPN probe TUN creation failed. code=%{public}d', errorCode);
        return -1;
      }
      this.recordDiagnosticEvent('vpn_conflict', 'create', VPN_EXISTS_ERROR_CODE);
      this.writeStatus(`FAILED | VPN conflict | code=${VPN_EXISTS_ERROR_CODE}`);
    }

    while (!this.destroying) {
      if (this.consumeVpnReplaceApproval()) {
        return await this.replaceExistingVpn(connection, config);
      }
      await this.waitForVpnTransition(VPN_REPLACE_APPROVAL_POLL_INTERVAL_MS);
      if (!this.destroying) {
        // Refresh the heartbeat while the modal is waiting for the user.
        this.writeStatus(`FAILED | VPN conflict | code=${VPN_EXISTS_ERROR_CODE}`);
      }
    }
    return -1;
  }

  private async replaceExistingVpn(connection: vpnExtension.VpnConnection,
    config: vpnExtension.VpnConfig): Promise<number> {
    this.recordDiagnosticEvent('vpn_replacement_approved', 'destroy_existing');
    for (let attempt: number = 0; attempt < VPN_REPLACE_CREATE_MAX_ATTEMPTS; attempt++) {
      this.writeStatus('Disconnecting existing VPN connection');
      try {
        this.recordDiagnosticEvent('vpn_tun_destroy_started', 'replace');
        await connection.destroy();
        this.recordDiagnosticEvent('vpn_existing_destroyed', 'replace');
      } catch (error) {
        const businessError = error as BusinessError;
        this.recordDiagnosticEvent('vpn_existing_destroy_failed', 'replace', businessError.code ?? -1);
      }
      await this.waitForVpnTransition(VPN_DESTROY_SETTLE_MS + attempt * VPN_REPLACE_CREATE_RETRY_MS);
      if (this.destroying) {
        return -1;
      }
      try {
        return await connection.create(config);
      } catch (error) {
        const businessError = error as BusinessError;
        const errorCode: number = businessError.code ?? -1;
        if (errorCode !== VPN_EXISTS_ERROR_CODE) {
          this.recordDiagnosticEvent('vpn_create_failed', 'replace', errorCode);
          this.writeStatus(`FAILED | VPN probe TUN | code=${errorCode}`);
          hilog.error(DOMAIN, TAG, 'VPN replacement failed. code=%{public}d', errorCode);
          return -1;
        }
        this.recordDiagnosticEvent('vpn_replace_retry', 'create', attempt + 1);
      }
    }
    this.recordDiagnosticEvent('vpn_create_failed', 'replace', VPN_EXISTS_ERROR_CODE);
    this.writeStatus(`FAILED | VPN conflict | code=${VPN_EXISTS_ERROR_CODE}`);
    return -1;
  }

  private async requestUiBackendHandoff(): Promise<string> {
    if (this.destroying) {
      return 'FAILED | backend handoff | extension stopped';
    }
    const requestId: number = Date.now();
    const requestPath: string = `${this.context.filesDir}/${VPN_BACKEND_HANDOFF_REQUEST_FILE_NAME}`;
    const responsePath: string = `${this.context.filesDir}/${VPN_BACKEND_HANDOFF_RESPONSE_FILE_NAME}`;
    const request: VpnBackendHandoffRequest = { requestId: requestId };
    this.writeAtomicTextFile(responsePath, '');
    if (!this.writeAtomicTextFile(requestPath, JSON.stringify(request))) {
      this.recordDiagnosticEvent('vpn_backend_handoff_request_failed', 'vpn_handoff');
      return 'FAILED | backend handoff | request unavailable';
    }
    this.writeStatus('VPN interface established | backend handoff pending');
    for (let attempt: number = 0; attempt < VPN_BACKEND_HANDOFF_MAX_ATTEMPTS; attempt++) {
      if (this.destroying) {
        return 'FAILED | backend handoff | extension stopped';
      }
      try {
        if (fileIo.accessSync(responsePath)) {
          const responseText: string = fileIo.readTextSync(responsePath).trim();
          if (responseText.length > 0) {
            const response: VpnBackendHandoffResponse = JSON.parse(responseText) as VpnBackendHandoffResponse;
            if (response.requestId === requestId) {
              this.writeAtomicTextFile(responsePath, '');
              return response.status;
            }
          }
        }
      } catch (_error) {
        // The UI may be replacing the response file while the backend stops.
      }
      await this.waitForVpnTransition(VPN_BACKEND_HANDOFF_POLL_INTERVAL_MS);
    }
    this.recordDiagnosticEvent('vpn_backend_handoff_timeout', 'vpn_handoff');
    return 'FAILED | backend handoff | stop timeout';
  }

  private async waitForVpnTransition(delayMs: number): Promise<void> {
    await new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, delayMs);
    });
  }

  private async destroyProbeTun(): Promise<void> {
    this.dnsObserver.stop();
    this.dnsSystemPlan = undefined;
    this.writeDnsSystemStatus('stopped', false);
    const connection: vpnExtension.VpnConnection | undefined = this.vpnConnection;
    this.tunFd = -1;
    if (connection === undefined) {
      return;
    }
    try {
      await connection.destroy();
    } catch (error) {
      this.recordDiagnosticEvent('vpn_tun_destroy_failed', 'cleanup', (error as BusinessError).code ?? -1);
    }
  }

  private writeVpnConfigSummary(config: vpnExtension.VpnConfig): void {
    const addresses: vpnExtension.LinkAddress[] = config.addresses ?? [];
    const routes: vpnExtension.RouteInfo[] = config.routes ?? [];
    const hasIPv4Address: boolean = addresses.some((address: vpnExtension.LinkAddress) =>
      address.address.family === 1);
    const hasIPv6Address: boolean = addresses.some((address: vpnExtension.LinkAddress) =>
      address.address.family === 2);
    const hasTailnetIPv4: boolean = routes.some((route: vpnExtension.RouteInfo) =>
      route.destination.address.address === '100.64.0.0' && route.destination.prefixLength === 10);
    const hasTailnetIPv6: boolean = routes.some((route: vpnExtension.RouteInfo) =>
      route.destination.address.address === 'fd7a:115c:a1e0::' && route.destination.prefixLength === 48);
    const hasDefaultIPv4: boolean = routes.some((route: vpnExtension.RouteInfo) =>
      route.destination.address.address === '0.0.0.0' && route.destination.prefixLength === 0 &&
      route.isDefaultRoute);
    const hasDefaultIPv6: boolean = routes.some((route: vpnExtension.RouteInfo) =>
      route.destination.address.address === '::' && route.destination.prefixLength === 0 &&
      route.isDefaultRoute);
    this.writeTextFile(`${this.context.filesDir}/${VPN_CONFIG_SUMMARY_FILE_NAME}`,
      `addressCount=${addresses.length} | routeCount=${routes.length} | ` +
      `hasIPv4Address=${hasIPv4Address} | hasIPv6Address=${hasIPv6Address} | ` +
      `hasTailnetIPv4=${hasTailnetIPv4} | hasTailnetIPv6=${hasTailnetIPv6} | ` +
      `hasDefaultIPv4=${hasDefaultIPv4} | hasDefaultIPv6=${hasDefaultIPv6} | ` +
      `dnsCount=${config.dnsAddresses?.length ?? 0} | searchDomainCount=${config.searchDomains?.length ?? 0} | ` +
      `ipv4Accepted=${config.isIPv4Accepted} | ipv6Accepted=${config.isIPv6Accepted} | ` +
      `mtu=${config.mtu}`);
  }

  private vpnReplaceApprovalFilePath(): string {
    return `${this.context.filesDir}/${VPN_REPLACE_APPROVAL_FILE_NAME}`;
  }

  private consumeVpnReplaceApproval(): boolean {
    try {
      const path: string = this.vpnReplaceApprovalFilePath();
      if (!fileIo.accessSync(path)) {
        return false;
      }
      const approvedAtMs: number = Number(fileIo.readTextSync(path).trim());
      this.writeTextFile(path, '');
      const approvalAgeMs: number = Date.now() - approvedAtMs;
      return approvedAtMs > 0 && approvalAgeMs >= 0 && approvalAgeMs <= VPN_REPLACE_APPROVAL_TTL_MS;
    } catch (_error) {
      return false;
    }
  }

  private async restoreBackendVpnConfig(): Promise<string> {
    if (this.destroying || this.explicitStopRequested || this.backendStopInFlight || !this.startupIntentAllowed()) {
      return 'FAILED | VPN config | extension stopped';
    }
    const stateDir: string = this.serverStateRoot;
    const controlSettings: ControlServerSettings = ControlServerConfig.load(this.context.filesDir);
    if (!controlSettings.confirmed) {
      return 'FAILED | VPN config | control server not configured';
    }
    const handedOffConfig: string = this.consumeVpnConnectConfig();
    if (handedOffConfig.length > 0) {
      this.recordDiagnosticEvent('vpn_config_handoff_used', 'preflight');
      return handedOffConfig;
    }
    this.recordDiagnosticEvent('vpn_config_handoff_fallback', 'backend_restore');
    if (!this.dnsInternalRebuild) {
      const handoffStatus: string = await this.requestUiBackendHandoff();
      if (this.destroying || this.explicitStopRequested || this.backendStopInFlight || !this.startupIntentAllowed()) {
        return 'FAILED | VPN config | extension stopped';
      }
      if (!handoffStatus.startsWith('OK')) {
        return handoffStatus;
      }
      this.backendHandoffCompleted = true;
    }
    const hostVersion: string = typeof this.harmonyOSHostinfoVersion === 'function' ?
      this.harmonyOSHostinfoVersion() : this.harmonyOSVersion();
    this.nativeStopPromise = undefined;
    nativeBridge.backendStart(
      stateDir, this.deviceModel(), hostVersion, controlSettings.controlURL);
    let configStatus: string = 'FAILED | VPN config | backend restore timeout';
    for (let attempt: number = 0; attempt < 60; attempt++) {
      if (this.destroying || this.explicitStopRequested || this.backendStopInFlight || !this.startupIntentAllowed()) {
        return 'FAILED | VPN config | extension stopped';
      }
      configStatus = await nativeBridge.backendVpnConfigAsync();
      if (this.destroying || this.explicitStopRequested || this.backendStopInFlight || !this.startupIntentAllowed()) return 'FAILED | VPN config | extension stopped';
      if (!configStatus.startsWith('FAILED')) {
        return configStatus;
      }
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, 250);
      });
    }
    return configStatus;
  }

  private consumeVpnConnectConfig(): string {
    const path: string = `${this.context.filesDir}/${VPN_CONNECT_CONFIG_FILE_NAME}`;
    try {
      if (!fileIo.accessSync(path)) {
        return '';
      }
      const text: string = fileIo.readTextSync(path);
      try {
        fileIo.unlinkSync(path);
      } catch (_unlinkError) {
        this.writeTextFile(path, '');
      }
      const handoff: VpnConnectConfigHandoff = JSON.parse(text) as VpnConnectConfigHandoff;
      const ageMs: number = Date.now() - handoff.createdAtMs;
      if (handoff.createdAtMs <= 0 || ageMs < 0 || ageMs > VPN_CONNECT_CONFIG_TTL_MS ||
        handoff.config.length === 0 || handoff.config.length > 8192 || handoff.config.startsWith('FAILED')) {
        return '';
      }
      return handoff.config;
    } catch (_error) {
      return '';
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

  private async waitForVpnBackend(initialStatus: string): Promise<string> {
    if (this.destroying || this.explicitStopRequested || this.backendStopInFlight) {
      return 'FAILED | VPN backend | extension stopped';
    }
    if (initialStatus.startsWith('FAILED')) {
      return initialStatus;
    }
    let backendStatus: string = initialStatus;
    let visibleStatus: string = '';
    for (let attempt: number = 0; attempt < VPN_BACKEND_STATUS_MAX_ATTEMPTS; attempt++) {
      if (this.destroying || this.explicitStopRequested || this.backendStopInFlight) {
        return 'FAILED | VPN backend | extension stopped';
      }
      const snapshotText: string = await nativeBridge.backendPeerSnapshot();
      if (this.destroying || this.explicitStopRequested || this.backendStopInFlight) {
        return 'FAILED | VPN backend | extension stopped';
      }
      const snapshot: BackendHealthSnapshot = JSON.parse(snapshotText) as BackendHealthSnapshot;
      this.backendSnapshotMs = Date.now();
      backendStatus = snapshot.status;
      if (backendStatus.includes('state=Running')) {
        this.writePeerSnapshot(snapshot.peers, snapshot.meshArcReceiver, snapshot.account);
      }
      if (backendStatus !== visibleStatus) {
        visibleStatus = backendStatus;
        this.writeStatus(backendStatus);
      }
      if (backendStatus.includes('state=Running') || backendStatus.startsWith('FAILED')) {
        return backendStatus;
      }
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, VPN_BACKEND_STATUS_POLL_INTERVAL_MS);
      });
    }
    return 'FAILED | VPN backend | restart timeout';
  }

  private startStatusUpdates(): void {
    this.peerSnapshotRequestId++;
    this.peerSnapshotInFlight = false;
    this.refreshDeviceSnapshot();
    this.dnsObserver.start();
    PathDiagnosticService.resume();
    if (this.statusTimer >= 0) {
      clearInterval(this.statusTimer);
    }
    if (this.taildropRequestTimer >= 0) {
      clearInterval(this.taildropRequestTimer);
    }
    if (typeof this.clearTaildropIncomingTimer === 'function') {
      this.clearTaildropIncomingTimer();
    } else if (this.taildropIncomingTimer >= 0 && typeof clearTimeout === 'function') {
      clearTimeout(this.taildropIncomingTimer);
      this.taildropIncomingTimer = -1;
    }
    this.resetRpcChannels();
    // Request handling must not wait behind the status snapshot. That snapshot
    // can spend several seconds querying targets and inbox files.
    this.taildropRequestTimer = setInterval(() => {
      if (this.destroying || this.backendStopInFlight || this.dnsRebuildInFlight) {
        return;
      }
      PathDiagnosticService.poll(this.context.filesDir, this.pathDiagnosticProtection, this.pathDiagnosticProtectionCode);
      void this.processDnsDiagnosticRequest();
      void this.processDebugDnsRebuildRequest();
      this.processTaildropSendRequest();
      this.processTaildropCancelRequest();
      this.processTaildropReceiveRequest();
      this.processTaildriveQueryRequest();
      this.processTaildriveTransferRequest();
      this.processTaildriveManualTransferRequest();
      this.processTaildriveControlRequest();
      this.processLocalSendRefreshRequest();
      this.processPeerConnectivityRequest();
      this.processSunshineProbeRequest();
      this.processMediaServiceProbeRequest();
    }, 100);
    // The regular backend snapshot can wait on file-target and inbox queries.
    // Keep receive notifications tied to the IPN-bus state so a fast transfer
    // is visible before the full snapshot finishes.
    this.refreshTaildropIncomingNotification();
    if (this.taildropIncomingTimer < 0 && typeof this.scheduleTaildropIncomingPoll === 'function') {
      this.scheduleTaildropIncomingPoll(250);
    }
    this.statusTimer = setInterval(() => {
      // Keep liveness independent from the full backend snapshot. File-target
      // and inbox queries can occasionally take several seconds, but that does
      // not mean the HarmonyOS VPN connection or its TUN has stopped.
      this.writeCurrentStatusHeartbeat();
      if (this.dnsRebuildInFlight) return;
      this.refreshDeviceSnapshot();
      void this.refreshPhysicalDnsBase();
      if (!this.destroying && !this.backendStopInFlight && !this.explicitStopRequested) {
        void this.dnsObserver.refresh();
      }
      if (this.statusUpdateInFlight || this.backendStopInFlight) {
        return;
      }
      if (this.processBackendStopRequest()) {
        return;
      }
      this.statusUpdateInFlight = true;
      nativeBridge.backendSnapshot()
        .then((snapshotText: string): void => {
          if (this.destroying || this.backendStopInFlight || this.explicitStopRequested) {
            return;
          }
          const snapshot: BackendHealthSnapshot = JSON.parse(snapshotText) as BackendHealthSnapshot;
          this.backendSnapshotMs = Date.now();
          this.writeStatus(snapshot.status);
          const runtimeState: number = DiagnosticPrivacy.runtimeStateCode(snapshot.status);
          if (runtimeState !== this.lastBackendRuntimeState) {
            this.lastBackendRuntimeState = runtimeState;
            this.recordDiagnosticEvent('vpn_backend_state_changed', 'status', runtimeState);
          }
          if (this.snapshotUnavailable) {
            this.snapshotUnavailable = false;
            this.recordDiagnosticEvent('vpn_snapshot_recovered', 'status');
          }
          this.writeTaildropSnapshot(snapshot.taildrop);
          this.processPeerConnectivityRequest();
          this.processMediaServiceProbeRequest();
          this.processTaildropSendRequest();
          this.processTaildropCancelRequest();
          this.processTaildropReceiveRequest();
        })
        .catch((error: BusinessError) => {
          if (this.destroying || this.backendStopInFlight || this.explicitStopRequested) {
            return;
          }
          // Optional snapshot services can fail while the tunnel is healthy.
          // Preserve the last known backend state instead of claiming failure.
          this.snapshotUnavailable = true;
          this.recordDiagnosticEvent('vpn_snapshot_unavailable', 'status', error.code ?? -1);
          this.writeTaildropSnapshot({
            state: 'unavailable', reason: 'query_failed', targets: [],
            incomingFiles: this.latestTaildropSnapshot.incomingFiles,
            waitingFiles: this.latestTaildropSnapshot.waitingFiles,
            inboxReason: 'query_failed',
            transfer: this.latestTaildropSnapshot.transfer
          });
        })
        .finally(() => {
          this.statusUpdateInFlight = false;
        });
    }, 1000);
  }

  private refreshDeviceSnapshot(): void {
    if (this.peerSnapshotInFlight || this.destroying || this.backendStopInFlight ||
      this.explicitStopRequested || this.dnsRebuildInFlight) return;
    const requestId: number = ++this.peerSnapshotRequestId;
    this.peerSnapshotInFlight = true;
    nativeBridge.backendPeerSnapshot().then((text: string): void => {
      if (this.peerSnapshotRequestId !== requestId || this.destroying || this.backendStopInFlight ||
        this.explicitStopRequested || this.dnsRebuildInFlight) return;
      const snapshot: BackendHealthSnapshot = JSON.parse(text) as BackendHealthSnapshot;
      // Never replace a live directory with an empty error/startup projection.
      if (!snapshot.status.includes('state=Running') || !Array.isArray(snapshot.peers)) return;
      this.writePeerSnapshot(snapshot.peers, snapshot.meshArcReceiver, snapshot.account);
    }).catch(() => {
      // Keep the last valid directory; the next independent tick retries.
      if (this.peerSnapshotRequestId === requestId && !this.destroying) {
        this.recordDiagnosticEvent('vpn_peer_snapshot_unavailable', 'status');
      }
    }).finally(() => {
      if (this.peerSnapshotRequestId === requestId) this.peerSnapshotInFlight = false;
    });
  }

  private writePeerStatus(status: string): void {
    this.writeTextFile(`${this.context.filesDir}/vpn-peer-probe-status.txt`, status);
  }

  private async processDnsDiagnosticRequest(): Promise<void> {
    if (!BuildProfile.DEBUG || this.dnsDiagnosticInFlight || this.destroying || this.backendStopInFlight ||
      this.explicitStopRequested) return;
    const path: string = `${this.context.filesDir}/dns-diagnostic-request.json`;
    try {
      if (!fileIo.accessSync(path) || fileIo.statSync(path).size > 2048) return;
      const text: string = fileIo.readTextSync(path);
      if (text.length === 0) return;
      this.writeTextFile(path, '');
      const request: DnsDiagnosticRequest = JSON.parse(text) as DnsDiagnosticRequest;
      if (!Number.isSafeInteger(request.requestId) || request.requestId <= this.lastDnsDiagnosticRequest ||
        !Number.isSafeInteger(request.createdMs) || Date.now() < request.createdMs || Date.now() - request.createdMs > 15000 ||
        typeof request.peerKey !== 'string' || !/^peer-[a-f0-9]{16}$/.test(request.peerKey)) return;
      this.lastDnsDiagnosticRequest = request.requestId;
      this.dnsDiagnosticInFlight = true;
      const result: string = await nativeBridge.backendDnsRuntimeAsync(
        `{"operation":"diagnose","peerKey":"${request.peerKey}"}`);
      if (this.destroying || this.backendStopInFlight || this.explicitStopRequested) return;
      const response: DnsDiagnosticReply = { requestId: request.requestId, result: result };
      this.writeAtomicTextFile(`${this.context.filesDir}/dns-diagnostic-response.json`, JSON.stringify(response));
    } catch (_error) {
      // Debug diagnostics cannot affect normal VPN requests or publish raw failures.
    } finally { this.dnsDiagnosticInFlight = false; }
  }

  // An explicit, expiring command in this Debug application's private sandbox
  // exercises the real rebuild lifecycle without modifying control-plane DNS.
  // It accepts no resolver, suffix, endpoint, or configuration override.
  private async processDebugDnsRebuildRequest(): Promise<void> {
    if (!BuildProfile.DEBUG || this.destroying || this.explicitStopRequested || this.backendStopInFlight ||
      this.dnsRebuildInFlight || this.dnsBaseRefreshInFlight || !this.startupIntentAllowed() ||
      !this.currentVisibleStatus.includes('state=Running')) return;
    const before: DnsSystemPlan | undefined = this.dnsSystemPlan;
    if (before === undefined) return;
    const path: string = `${this.context.filesDir}/dns-debug-rebuild-request.json`;
    try {
      if (!fileIo.accessSync(path) || fileIo.statSync(path).size > 512) return;
      const text: string = fileIo.readTextSync(path);
      if (text.length === 0) return;
      this.writeTextFile(path, '');
      const request: DebugDnsRebuildRequest = JSON.parse(text) as DebugDnsRebuildRequest;
      if (!Number.isSafeInteger(request.requestId) || request.requestId <= this.lastDebugDnsRebuildRequest ||
        !Number.isSafeInteger(request.createdMs) || Date.now() < request.createdMs || Date.now() - request.createdMs > 15000) return;
      this.lastDebugDnsRebuildRequest = request.requestId;
      await this.rebuildDnsVpn(before);
      if (this.destroying || this.explicitStopRequested) return;
      const after: DnsSystemPlan | undefined = this.dnsSystemPlan;
      const response: DebugDnsRebuildReply = {
        requestId: request.requestId,
        completed: after !== undefined && after.session !== before.session,
        sessionChanged: after !== undefined && after.session !== before.session,
        sameConfiguration: after !== undefined && DnsRuntimeService.sameConfiguration(before, after),
        running: this.currentVisibleStatus.includes('state=Running'),
        statusCode: DiagnosticPrivacy.runtimeStateCode(this.currentVisibleStatus),
        tunPresent: this.tunFd >= 0,
        failed: this.currentVisibleStatus.startsWith('FAILED'),
        conflict: this.currentVisibleStatus.includes('2203002'),
        handoffFailed: this.currentVisibleStatus.includes('handoff'),
        dnsUnavailable: this.currentVisibleStatus.includes('DNS |'),
        backendTimeout: this.currentVisibleStatus.includes('restart timeout')
      };
      this.writeAtomicTextFile(`${this.context.filesDir}/dns-debug-rebuild-response.json`, JSON.stringify(response));
    } catch (_error) {
      // No Debug request can inject DNS configuration or expose private names.
    }
  }

  private startBackendStopWatcher(): void {
    const requestPath: string = `${this.context.filesDir}/${VPN_STOP_REQUEST_FILE_NAME}`;
    try {
      this.backendStopWatcher = fileIo.createWatcher(requestPath, FILE_WATCH_CLOSE_WRITE, () => {
        this.processBackendStopRequest();
      });
      this.backendStopWatcher.start();
    } catch (_error) {
      this.backendStopWatcher = undefined;
      // The one-second status loop remains as a compatibility fallback.
    }
  }

  private stopBackendStopWatcher(): void {
    if (this.backendStopWatcher === undefined) {
      return;
    }
    try {
      this.backendStopWatcher.stop();
    } catch (_error) {
      // The watcher may already have stopped with the Extension lifecycle.
    }
    this.backendStopWatcher = undefined;
  }

  private writeTaildropSnapshot(snapshot: TaildropSnapshot): void {
    this.latestTaildropSnapshot = snapshot;
    this.updateTaildropNotifications(snapshot);
    if (Array.isArray(snapshot.incomingFiles) && snapshot.incomingFiles.length > 0 &&
      this.taildropIncomingDelayMs > 250 && typeof this.scheduleTaildropIncomingPoll === 'function') {
      this.scheduleTaildropIncomingPoll(250);
    }
    const signature: string = JSON.stringify(snapshot);
    const nowMs: number = Date.now();
    if (signature === this.lastTaildropSnapshotSignature && nowMs >= this.lastTaildropSnapshotWriteMs &&
      nowMs - this.lastTaildropSnapshotWriteMs < 4000) {
      return;
    }
    const persisted: PersistedTaildropSnapshot = {
      state: snapshot.state,
      reason: snapshot.reason,
      targets: snapshot.targets,
      incomingFiles: snapshot.incomingFiles,
      waitingFiles: snapshot.waitingFiles,
      inboxReason: snapshot.inboxReason,
      transfer: snapshot.transfer,
      updatedAtMs: nowMs
    };
    if (this.writeAtomicTextFile(`${this.context.filesDir}/${TAILDROP_TARGETS_FILE_NAME}`,
      JSON.stringify(persisted)) !== false) {
      this.lastTaildropSnapshotSignature = signature;
      this.lastTaildropSnapshotWriteMs = nowMs;
    }
  }

  private writePeerSnapshot(peers: PeerSummary[], meshArcReceiver: MeshArcReceiverStatus,
    account?: AccountSummary): void {
    const signaturePayload: PeerSnapshotSignaturePayload = {
      peers: peers,
      meshArcReceiver: meshArcReceiver,
      account: account
    };
    const signature: string = JSON.stringify(signaturePayload);
    const nowMs: number = Date.now();
    if (signature === this.lastPeerSnapshotSignature && nowMs >= this.lastPeerSnapshotWriteMs &&
      nowMs - this.lastPeerSnapshotWriteMs < 2500) {
      return;
    }
    const persisted: PersistedPeerSnapshot = {
      peers: peers,
      meshArcReceiver: meshArcReceiver,
      account: account,
      updatedAtMs: nowMs
    };
    if (this.writeAtomicTextFile(`${this.context.filesDir}/${VPN_PEERS_FILE_NAME}`,
      JSON.stringify(persisted)) !== false) {
      this.lastPeerSnapshotSignature = signature;
      this.lastPeerSnapshotWriteMs = nowMs;
    }
  }

  private processLocalSendRefreshRequest(): void {
    if (this.localSendRefreshInFlight || this.destroying || this.backendStopInFlight) {
      return;
    }
    const requestPath: string = `${this.context.filesDir}/${LOCAL_SEND_REFRESH_REQUEST_FILE_NAME}`;
    try {
      if (!fileIo.accessSync(requestPath)) {
        return;
      }
      const requestText: string = fileIo.readTextSync(requestPath).trim();
      if (requestText.length === 0) {
        return;
      }
      this.writeTextFile(requestPath, '');
      const request: LocalSendRefreshRequest = JSON.parse(requestText) as LocalSendRefreshRequest;
      if (request.requestId <= 0) {
        return;
      }
      this.localSendRefreshInFlight = true;
      nativeBridge.backendLocalSendRefreshAsync()
        .then((status: string): Promise<void> => nativeBridge.backendPeerSnapshot()
          .then((snapshotText: string): void => {
            if (this.destroying) {
              return;
            }
            const snapshot: BackendHealthSnapshot = JSON.parse(snapshotText) as BackendHealthSnapshot;
            this.backendSnapshotMs = Date.now();
            this.writePeerSnapshot(snapshot.peers, snapshot.meshArcReceiver, snapshot.account);
            const response: LocalSendRefreshResponse = { requestId: request.requestId, status: status };
            this.writeTextFile(`${this.context.filesDir}/${LOCAL_SEND_REFRESH_RESPONSE_FILE_NAME}`,
              JSON.stringify(response));
          }))
        .catch(() => {
          const response: LocalSendRefreshResponse = {
            requestId: request.requestId,
            status: 'FAILED | LocalSend refresh | extension error'
          };
          this.writeTextFile(`${this.context.filesDir}/${LOCAL_SEND_REFRESH_RESPONSE_FILE_NAME}`,
            JSON.stringify(response));
        })
        .finally(() => {
          this.localSendRefreshInFlight = false;
        });
    } catch (_error) {
      this.writeTextFile(requestPath, '');
    }
  }

  private processBackendStopRequest(): boolean {
    if (this.backendStopInFlight || this.destroying) {
      return false;
    }
    const requestPath: string = `${this.context.filesDir}/${VPN_STOP_REQUEST_FILE_NAME}`;
    try {
      if (!fileIo.accessSync(requestPath)) {
        return false;
      }
      const requestText: string = fileIo.readTextSync(requestPath).trim();
      if (requestText.length === 0) {
        return false;
      }
      this.writeTextFile(requestPath, '');
      const request: VpnStopRequest = JSON.parse(requestText) as VpnStopRequest;
      if (request.requestId <= 0) {
        return false;
      }
      this.backendStopInFlight = true;
      this.stopVpnAndBackend(request);
      return true;
    } catch (_error) {
      this.writeTextFile(requestPath, '');
      return false;
    }
  }

  private async stopVpnAndBackend(request: VpnStopRequest): Promise<void> {
    this.explicitStopRequested = true;
    this.dnsObserver.stop();
    this.dnsSystemPlan = undefined;
    this.writeDnsSystemStatus('stopped', false);
    await PathDiagnosticService.shutdown(this.context.filesDir);
    this.recordDiagnosticEvent('vpn_disconnect_requested', 'user_request');
    this.networkMonitor.stop();
    let status: string = 'FAILED | backend stop | extension error';
    const reconnectConfigPromise: Promise<string> = nativeBridge.backendVpnConfigAsync()
      .catch(() => 'FAILED | VPN config | extension error');
    const connection: vpnExtension.VpnConnection | undefined = this.vpnConnection;
    if (connection !== undefined) {
      try {
        this.recordDiagnosticEvent('vpn_tun_destroy_started', 'disconnect');
        await connection.destroy();
        this.vpnConnection = undefined;
        this.tunFd = -1;
        this.writeStatus('VPN disconnected | backend stopping');
        this.recordDiagnosticEvent('vpn_tun_destroyed', 'disconnect');
      } catch (error) {
        this.recordDiagnosticEvent('vpn_tun_destroy_failed', 'disconnect', (error as BusinessError).code ?? -1);
      }
    }
    const reconnectConfig: string = await reconnectConfigPromise;
    this.stageVpnReconnectConfig(reconnectConfig);
    try {
      status = await this.stopNativeBackend();
      this.recordDiagnosticEvent(status.startsWith('OK') ?
        'vpn_backend_stopped' : 'vpn_backend_stop_failed', 'disconnect',
        status.startsWith('OK') ? 0 : DiagnosticPrivacy.classifyError(status).code || -1);
    } catch (error) {
      this.recordDiagnosticEvent('vpn_backend_stop_failed', 'disconnect', (error as BusinessError).code ?? -1);
    }
    const response: VpnStopResponse = { requestId: request.requestId, status: status };
    this.writeTextFile(`${this.context.filesDir}/${VPN_STOP_RESPONSE_FILE_NAME}`,
      JSON.stringify(response));
    this.backendStopInFlight = false;
  }

  private stopNativeBackend(): Promise<string> {
    if (this.nativeStopPromise === undefined) {
      this.nativeStopPromise = this.finishNativeStop();
    }
    return this.nativeStopPromise;
  }

  private async finishNativeStop(): Promise<string> {
    // A queued restart must finish before stop, otherwise its late completion
    // could recreate a backend after the extension has been destroyed.
    try { await this.backendRestartPromise; } catch (_error) {}
    return await nativeBridge.backendStopAsync();
  }

  private async finishDestroyedBackend(connection: vpnExtension.VpnConnection | undefined): Promise<void> {
    this.recordDiagnosticEvent('vpn_cleanup_started', 'destroy');
    if (connection !== undefined) {
      try {
        // Release the system TUN before waiting for Go's blocking reader to stop.
        this.recordDiagnosticEvent('vpn_tun_destroy_started', 'destroy');
        await connection.destroy();
        this.recordDiagnosticEvent('vpn_tun_destroyed', 'destroy');
      } catch (error) {
        this.recordDiagnosticEvent('vpn_tun_destroy_failed', 'destroy', (error as BusinessError).code ?? -1);
      }
    }
    try {
      const status: string = await this.stopNativeBackend();
      this.recordDiagnosticEvent(status.startsWith('OK') ? 'vpn_backend_stopped' :
        'vpn_backend_stop_failed', 'destroy', status.startsWith('OK') ? 0 :
        DiagnosticPrivacy.classifyError(status).code || -1);
    } catch (error) {
      this.recordDiagnosticEvent('vpn_backend_stop_failed', 'destroy', (error as BusinessError).code ?? -1);
    }
    this.recordDiagnosticEvent('vpn_cleanup_completed', 'destroy');
  }

  private stageVpnReconnectConfig(config: string): void {
    if (config.length === 0 || config.length > 8192 || config.startsWith('FAILED')) {
      this.recordDiagnosticEvent('fast_reconnect_config_failed', 'backend_config');
      return;
    }
    const handoff: VpnConnectConfigHandoff = {
      createdAtMs: Date.now(),
      config: config
    };
    this.writeAtomicTextFile(`${this.context.filesDir}/${VPN_CONNECT_CONFIG_FILE_NAME}`,
      JSON.stringify(handoff));
    this.recordDiagnosticEvent('fast_reconnect_config_staged', 'disconnect');
  }

  private ensureRpcServer(): VpnExtensionRpcServer {
    if (this.rpcServer === undefined) {
      this.rpcServer = new VpnExtensionRpcServer();
    }
    return this.rpcServer;
  }

  private resetRpcChannels(): void {
    if (this.rpcChannelsInitialized || this.dnsInternalRebuild || this.context === undefined) {
      return;
    }
    this.rpcChannelsInitialized = true;
    try {
      this.ensureRpcServer().resetAll(this.context.filesDir, RPC_CHANNEL_FILE_NAMES);
    } catch (_error) {
    }
  }

  private processPeerConnectivityRequest(): void {
    if (this.peerConnectivityInFlight) {
      return;
    }
    const rpcServer: VpnExtensionRpcServer = this.ensureRpcServer();
    const envelope: VpnRawRpcEnvelope | undefined = rpcServer.peekRawRequest(
      this.context.filesDir, PEER_CONNECTIVITY_REQUEST_FILE_NAME);
    if (envelope === undefined || envelope.parseError === true || envelope.requestId <= 0) {
      return;
    }
    try {
      const request: PeerConnectivityRequest = JSON.parse(envelope.rawText) as PeerConnectivityRequest;
      if (request.requestId <= 0 || typeof request.peerKey !== 'string' ||
        !/^peer-[a-f0-9]{16}$/.test(request.peerKey)) {
        return;
      }
      this.peerConnectivityInFlight = true;
      nativeBridge.backendPeerConnectivityAsync(request.peerKey)
        .then((result: string) => {
          rpcServer.writeResponse(this.context.filesDir, PEER_CONNECTIVITY_RESPONSE_FILE_NAME,
            request.requestId, result);
        })
        .catch(() => {
          const failedResult: string = '{"state":"failed","reason":"extension_error",' +
            '"sent":0,"received":0,"lossPercent":0,"minLatencyMs":0,"avgLatencyMs":0,"maxLatencyMs":0}';
          rpcServer.writeResponse(this.context.filesDir, PEER_CONNECTIVITY_RESPONSE_FILE_NAME,
            request.requestId, failedResult);
        })
        .finally(() => {
          this.peerConnectivityInFlight = false;
        });
    } catch (_error) {
    }
  }

  private processSunshineProbeRequest(): void {
    if (this.sunshineProbeInFlight) {
      return;
    }
    const rpcServer: VpnExtensionRpcServer = this.ensureRpcServer();
    const envelope: VpnRawRpcEnvelope | undefined = rpcServer.peekRawRequest(
      this.context.filesDir, SUNSHINE_PROBE_REQUEST_FILE_NAME);
    if (envelope === undefined || envelope.parseError === true || envelope.requestId <= 0) {
      return;
    }
    try {
      const request: SunshineProbeRequest = JSON.parse(envelope.rawText) as SunshineProbeRequest;
      if (request.requestId <= 0 || typeof request.peerKey !== 'string' ||
        !/^peer-[a-f0-9]{16}$/.test(request.peerKey)) {
        return;
      }
      this.sunshineProbeInFlight = true;
      nativeBridge.backendSunshineProbeAsync(request.peerKey)
        .then((result: string) => {
          rpcServer.writeResponse(this.context.filesDir, SUNSHINE_PROBE_RESPONSE_FILE_NAME,
            request.requestId, result);
        })
        .catch(() => {
          rpcServer.writeResponse(this.context.filesDir, SUNSHINE_PROBE_RESPONSE_FILE_NAME,
            request.requestId, '{"state":"error","checkedAt":0,"errorMessage":"extension_error"}');
        })
        .finally(() => {
          this.sunshineProbeInFlight = false;
        });
    } catch (_error) {
    }
  }

  private processMediaServiceProbeRequest(): void {
    if (this.mediaServiceProbeInFlight) {
      return;
    }
    const rpcServer: VpnExtensionRpcServer = this.ensureRpcServer();
    const envelope: VpnRawRpcEnvelope | undefined = rpcServer.peekRawRequest(
      this.context.filesDir, MEDIA_SERVICE_PROBE_REQUEST_FILE_NAME);
    if (envelope === undefined) {
      return;
    }
    if (envelope.parseError === true) {
      this.recordDiagnosticEvent('media_probe_failed', 'request_parse');
      return;
    }
    try {
      const request: MediaServiceProbeRequest = JSON.parse(envelope.rawText) as MediaServiceProbeRequest;
      if (envelope.requestId <= 0 || request.requestId <= 0 || typeof request.peerKey !== 'string' ||
        !/^peer-[a-f0-9]{16}$/.test(request.peerKey)) {
        this.recordDiagnosticEvent('media_probe_rejected', 'invalid_request');
        return;
      }
      this.mediaServiceProbeInFlight = true;
      this.recordDiagnosticEvent('media_probe_started', 'requested');
      hilog.info(DOMAIN, TAG, 'Media service probe started');
      nativeBridge.backendMediaServiceProbeAsync(request.peerKey)
        .then((result: string) => {
          rpcServer.writeResponse(this.context.filesDir, MEDIA_SERVICE_PROBE_RESPONSE_FILE_NAME,
            request.requestId, result);
          const available: boolean = result.includes('"state":"available"');
          this.recordDiagnosticEvent(available ? 'media_probe_available' : 'media_probe_completed',
            available ? 'service_confirmed' : 'no_service');
          hilog.info(DOMAIN, TAG, 'Media service probe completed. available=%{public}s',
            available ? 'true' : 'false');
        })
        .catch(() => {
          rpcServer.writeResponse(this.context.filesDir, MEDIA_SERVICE_PROBE_RESPONSE_FILE_NAME,
            request.requestId,
            '{"state":"error","checkedAt":0,"services":[],"errorMessage":"extension_error"}');
          this.recordDiagnosticEvent('media_probe_failed', 'extension');
          hilog.error(DOMAIN, TAG, 'Media service probe failed');
        })
        .finally(() => {
          this.mediaServiceProbeInFlight = false;
        });
    } catch (_error) {
      this.recordDiagnosticEvent('media_probe_failed', 'request_parse');
    }
  }

  private processTaildriveQueryRequest(): void {
    if (this.taildriveQueryInFlight || this.destroying || this.backendStopInFlight) {
      return;
    }
    const request: TaildriveExtensionRequest | undefined = this.takeTaildriveRequest(
      TAILDRIVE_QUERY_REQUEST_FILE_NAME, ['list', 'stat', 'mutate']);
    if (request === undefined) {
      return;
    }
    this.taildriveQueryInFlight = true;
    let task: Promise<string>;
    if (request.operation === 'list') {
      task = nativeBridge.backendTaildriveListAsync(request.payload);
    } else if (request.operation === 'stat') {
      task = nativeBridge.backendTaildriveStatAsync(request.payload);
    } else {
      task = nativeBridge.backendTaildriveMutateAsync(request.payload);
    }
    this.completeTaildriveRequest(TAILDRIVE_QUERY_RESPONSE_FILE_NAME, request, task,
      () => this.taildriveQueryInFlight = false);
  }

  private processTaildriveTransferRequest(): void {
    if (this.taildriveTransferInFlight || this.destroying || this.backendStopInFlight) {
      return;
    }
    const request: TaildriveExtensionRequest | undefined = this.takeTaildriveRequest(
      TAILDRIVE_TRANSFER_REQUEST_FILE_NAME, ['download', 'upload']);
    if (request === undefined) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'Taildrive transfer accepted. operation=%{public}s requestId=%{public}s',
      request.operation, request.requestId.toString());
    this.taildriveTransferInFlight = true;
    const task: Promise<string> = request.operation === 'download' ?
      nativeBridge.backendTaildriveDownloadAsync(request.payload) :
      nativeBridge.backendTaildriveUploadAsync(request.payload);
    this.completeTaildriveRequest(TAILDRIVE_TRANSFER_RESPONSE_FILE_NAME, request, task,
      () => this.taildriveTransferInFlight = false);
  }

  private processTaildriveManualTransferRequest(): void {
    if (this.taildriveManualTransferInFlight || this.destroying || this.backendStopInFlight) {
      return;
    }
    const request: TaildriveExtensionRequest | undefined = this.takeTaildriveRequest(
      TAILDRIVE_MANUAL_TRANSFER_REQUEST_FILE_NAME, ['download']);
    if (request === undefined) {
      return;
    }
    this.taildriveManualTransferInFlight = true;
    const task: Promise<string> = nativeBridge.backendTaildriveManualDownloadAsync(request.payload);
    this.completeTaildriveRequest(TAILDRIVE_MANUAL_TRANSFER_RESPONSE_FILE_NAME, request, task,
      () => this.taildriveManualTransferInFlight = false);
  }

  private processTaildriveControlRequest(): void {
    if (this.taildriveControlInFlight || this.destroying || this.backendStopInFlight) {
      return;
    }
    const request: TaildriveExtensionRequest | undefined = this.takeTaildriveRequest(
      TAILDRIVE_CONTROL_REQUEST_FILE_NAME, ['snapshot', 'cancel']);
    if (request === undefined) {
      return;
    }
    this.taildriveControlInFlight = true;
    const task: Promise<string> = request.operation === 'snapshot' ?
      nativeBridge.backendTaildriveTransferSnapshotAsync() : nativeBridge.backendTaildriveCancelAsync();
    this.completeTaildriveRequest(TAILDRIVE_CONTROL_RESPONSE_FILE_NAME, request, task,
      () => this.taildriveControlInFlight = false);
  }

  private takeTaildriveRequest(fileName: string,
    allowedOperations: string[]): TaildriveExtensionRequest | undefined {
    const envelope: VpnRawRpcEnvelope | undefined = this.ensureRpcServer().peekRawRequest(
      this.context.filesDir, fileName, TAILDRIVE_REQUEST_MAX_BYTES);
    if (envelope === undefined || envelope.parseError === true || envelope.requestId <= 0) {
      return undefined;
    }
    try {
      const request: TaildriveExtensionRequest = JSON.parse(envelope.rawText) as TaildriveExtensionRequest;
      if (!Number.isSafeInteger(request.requestId) || request.requestId <= 0 ||
        !allowedOperations.includes(request.operation) || typeof request.payload !== 'string' ||
        request.payload.length > 32768) {
        return undefined;
      }
      return request;
    } catch (_error) {
      return undefined;
    }
  }

  private completeTaildriveRequest(responseFileName: string, request: TaildriveExtensionRequest,
    task: Promise<string>, finish: () => void, startedAtMs: number = Date.now()): void {
    const rpcServer: VpnExtensionRpcServer = this.ensureRpcServer();
    task.then((result: string) => {
      let state: string = 'unknown';
      let reason: string = '';
      try {
        const summary: TaildriveOperationResultSummary = JSON.parse(result) as TaildriveOperationResultSummary;
        state = summary.state;
        reason = summary.reason ?? '';
      } catch (_error) {}
      hilog.info(DOMAIN, TAG,
        'Taildrive native task completed. operation=%{public}s requestId=%{public}s state=%{public}s ' +
        'reason=%{public}s durationMs=%{public}s',
        request.operation, request.requestId.toString(), state, reason,
        (Date.now() - startedAtMs).toString());
      const written: boolean = rpcServer.writeResponse(
        this.context.filesDir, responseFileName, request.requestId, result);
      hilog.info(DOMAIN, TAG, 'Taildrive response write. operation=%{public}s written=%{public}s',
        request.operation, written ? 'true' : 'false');
    }).catch(() => {
      hilog.error(DOMAIN, TAG, 'Taildrive native task rejected. operation=%{public}s requestId=%{public}s',
        request.operation, request.requestId.toString());
      rpcServer.writeResponse(
        this.context.filesDir, responseFileName, request.requestId,
        this.taildriveExtensionFailure(request.operation));
    }).finally(() => {
      finish();
      hilog.info(DOMAIN, TAG, 'Taildrive request released. operation=%{public}s', request.operation);
    });
  }

  private taildriveExtensionFailure(operation: string): string {
    if (operation === 'list') {
      return '{"state":"failed","path":"/","entries":[],"reason":"extension_error"}';
    }
    if (operation === 'stat') {
      return '{"state":"failed","entry":{"name":"","path":"","kind":"","size":0,' +
        '"modifiedAtMs":0},"reason":"extension_error"}';
    }
    if (operation === 'mutate') {
      return '{"state":"failed","operation":"","path":"","newPath":"",' +
        '"reason":"extension_error"}';
    }
    return '{"requestId":0,"direction":"","state":"failed","reason":"extension_error",' +
      '"remotePath":"","localPath":"","fileName":"","bytes":0,"totalBytes":0,' +
      '"startedAtMs":0,"completedAtMs":0}';
  }

  private taildropOutboxRoot(): string {
    return RecoverableCachePaths.taildropOutboxRoot(this.context);
  }

  private taildropSendRequestPath(): string {
    return `${this.context.filesDir}/${TAILDROP_SEND_REQUEST_FILE_NAME}`;
  }

  private taildropCancelRequestPath(): string {
    return `${this.context.filesDir}/${TAILDROP_CANCEL_REQUEST_FILE_NAME}`;
  }

  private taildropInboxRoot(): string {
    return `${AccountProfiles.cacheRoot(this.context.filesDir, this.context.filesDir, this.serverControlURL, this.serverProfileId)}/${TAILDROP_INBOX_DIR_NAME}`;
  }

  private taildropReceiveRequestPath(): string {
    return `${this.context.filesDir}/${TAILDROP_RECEIVE_REQUEST_FILE_NAME}`;
  }

  private taildropReceiveResponsePath(): string {
    return `${this.context.filesDir}/${TAILDROP_RECEIVE_RESPONSE_FILE_NAME}`;
  }

  private processTaildropCancelRequest(): void {
    if (this.taildropCancelInFlight) {
      return;
    }
    const requestPath: string = this.taildropCancelRequestPath();
    try {
      if (!fileIo.accessSync(requestPath)) {
        return;
      }
      const requestText: string = fileIo.readTextSync(requestPath).trim();
      if (requestText.length === 0) {
        return;
      }
      this.writeTextFile(requestPath, '');
      const request: TaildropCancelRequest = JSON.parse(requestText) as TaildropCancelRequest;
      if (request.requestId <= 0 || request.requestId !== this.latestTaildropSnapshot.transfer.requestId ||
        (this.latestTaildropSnapshot.transfer.state !== 'queued' &&
          this.latestTaildropSnapshot.transfer.state !== 'sending')) {
        return;
      }
      this.taildropCancelInFlight = true;
      nativeBridge.backendTaildropCancelAsync()
        .then((resultText: string) => {
          const result: TaildropTransferSummary = JSON.parse(resultText) as TaildropTransferSummary;
          if (result.requestId !== request.requestId) {
            this.writeAtomicTextFile(requestPath, JSON.stringify(request));
            return;
          }
          this.persistTaildropTransfer(result);
          this.recordDiagnosticEvent('taildrop_send_cancelled', 'transfer');
        })
        .catch(() => this.recordDiagnosticEvent('taildrop_send_cancel_failed', 'extension_error'))
        .finally(() => {
          this.taildropCancelInFlight = false;
        });
    } catch (_error) {
      this.writeTextFile(requestPath, '');
    }
  }

  private validTaildropReceiveRequest(request: TaildropReceiveRequest): boolean {
    if (request.requestId <= 0 ||
      (request.action !== 'stage' && request.action !== 'delete' && request.action !== 'clear')) {
      return false;
    }
    if (request.action === 'clear') {
      return request.name.length === 0 && request.inboxRoot.length === 0 && request.path.length === 0;
    }
    if (request.name.length === 0 || request.name.length > 255 || request.name.includes('/') ||
      request.name.includes('\\') || request.name === '.' || request.name === '..') {
      return false;
    }
    if (request.action === 'delete') {
      return request.inboxRoot.length === 0 && request.path.length === 0;
    }
    return request.inboxRoot === this.taildropInboxRoot() &&
      request.path === `${this.taildropInboxRoot()}/${request.requestId}.taildrop`;
  }

  private failedTaildropReceive(request: TaildropReceiveRequest, reason: string): TaildropReceiveResult {
    return {
      requestId: request.requestId, action: request.action, state: 'failed', reason: reason,
      name: request.name, size: 0, path: ''
    };
  }

  private validTaildropReceiveResult(request: TaildropReceiveRequest, result: TaildropReceiveResult): boolean {
    if (result.requestId !== request.requestId || result.action !== request.action || result.name !== request.name ||
      (result.state !== 'staged' && result.state !== 'completed' && result.state !== 'failed') || result.size < 0) {
      return false;
    }
    if (result.state === 'staged') {
      return request.action === 'stage' && result.path === request.path;
    }
    return result.state === 'failed' || request.action === 'delete' || request.action === 'clear';
  }

  private processTaildropReceiveRequest(): void {
    if (this.taildropReceiveInFlight) {
      return;
    }
    const requestPath: string = this.taildropReceiveRequestPath();
    try {
      if (!fileIo.accessSync(requestPath)) {
        return;
      }
      const requestText: string = fileIo.readTextSync(requestPath).trim();
      if (requestText.length === 0) {
        return;
      }
      this.writeTextFile(requestPath, '');
      const request: TaildropReceiveRequest = JSON.parse(requestText) as TaildropReceiveRequest;
      if (!this.validTaildropReceiveRequest(request)) {
        this.writeAtomicTextFile(this.taildropReceiveResponsePath(),
          JSON.stringify(this.failedTaildropReceive(request, 'invalid_request')));
        return;
      }
      this.taildropReceiveInFlight = true;
      this.recordDiagnosticEvent(request.action === 'stage' ?
        'taildrop_receive_requested' : request.action === 'clear' ?
          'taildrop_receive_cache_clear_requested' : 'taildrop_receive_delete_requested', 'transfer');
      nativeBridge.backendTaildropReceiveAsync(JSON.stringify(request))
        .then((resultText: string) => {
          const result: TaildropReceiveResult = JSON.parse(resultText) as TaildropReceiveResult;
          const persisted: TaildropReceiveResult = this.validTaildropReceiveResult(request, result) ? result :
            this.failedTaildropReceive(request, 'invalid_result');
          this.writeAtomicTextFile(this.taildropReceiveResponsePath(), JSON.stringify(persisted));
          this.recordDiagnosticEvent(persisted.state === 'failed' ?
            'taildrop_receive_failed' : `taildrop_receive_${persisted.state}`,
          persisted.reason);
        })
        .catch(() => {
          this.writeAtomicTextFile(this.taildropReceiveResponsePath(),
            JSON.stringify(this.failedTaildropReceive(request, 'extension_error')));
          this.recordDiagnosticEvent('taildrop_receive_failed', 'extension_error');
        })
        .finally(() => {
          this.taildropReceiveInFlight = false;
        });
    } catch (_error) {
      this.writeTextFile(requestPath, '');
    }
  }

  private failedTaildropTransfer(requestId: number, reason: string,
    targetKey: string = '', fileCount: number = 0, totalBytes: number = 0): TaildropTransferSummary {
    return {
      requestId: requestId, state: 'failed', reason: reason, targetKey: targetKey,
      targetName: '', fileName: '', fileIndex: 0, fileCount: fileCount,
      fileBytes: 0, fileSize: 0, bytesSent: 0, totalBytes: totalBytes,
      completedAtMs: Date.now()
    };
  }

  private persistTaildropTransfer(transfer: TaildropTransferSummary): void {
    this.writeTaildropSnapshot({
      state: this.latestTaildropSnapshot.state,
      reason: this.latestTaildropSnapshot.reason,
      targets: this.latestTaildropSnapshot.targets,
      incomingFiles: this.latestTaildropSnapshot.incomingFiles,
      waitingFiles: this.latestTaildropSnapshot.waitingFiles,
      inboxReason: this.latestTaildropSnapshot.inboxReason,
      transfer: transfer
    });
  }

  private updateTaildropNotifications(snapshot: TaildropSnapshot): void {
    if (this.destroying || this.explicitStopRequested) { return; }
    this.updateTaildropProgressNotification(snapshot.incomingFiles ?? [], snapshot.waitingFiles);

    if (snapshot.state !== 'ready' || snapshot.inboxReason.length > 0) {
      return;
    }
    const currentKeys: string[] = snapshot.waitingFiles
      .filter((file: TaildropWaitingFileSummary) => this.validTaildropWaitingFile(file))
      .map((file: TaildropWaitingFileSummary) => this.taildropInboxNotificationKey(file));
    if (!this.taildropInboxNotificationInitialized) {
      this.taildropInboxNotificationInitialized = true;
      this.notifiedTaildropInboxKeys = currentKeys;
      return;
    }
    snapshot.waitingFiles.forEach((file: TaildropWaitingFileSummary) => {
      const key: string = this.taildropInboxNotificationKey(file);
      if (!this.validTaildropWaitingFile(file) || this.notifiedTaildropInboxKeys.includes(key)) {
        return;
      }
      this.notifiedTaildropInboxKeys.push(key);
      publishTaildropSavePrompt(this.context, file.name, file.size, file.receivedAtMs);
    });
    this.notifiedTaildropInboxKeys = this.notifiedTaildropInboxKeys.filter(
      (key: string) => currentKeys.includes(key));
  }

  private updateTaildropProgressNotification(incomingFiles: TaildropIncomingFileSummary[],
    waitingFiles: TaildropWaitingFileSummary[]): void {
    const activeFiles: TaildropIncomingFileSummary[] = incomingFiles.filter(
      (file: TaildropIncomingFileSummary) => this.validTaildropIncomingFile(file) &&
        !waitingFiles.some((waiting: TaildropWaitingFileSummary) =>
          waiting.name === file.name && (file.declaredSize < 0 || waiting.size === file.declaredSize)));
    if (activeFiles.length > 0) {
      this.taildropProgressNotificationVisible = true;
      const file: TaildropIncomingFileSummary = activeFiles[0];
      const notificationFile: TaildropNotificationFile = {
        name: file.name,
        declaredSize: file.declaredSize,
        received: file.received,
        startedAtMs: file.startedAtMs
      };
      publishTaildropProgress(this.context, notificationFile);
    } else if (this.taildropProgressNotificationVisible) {
      this.taildropProgressNotificationVisible = false;
      clearTaildropProgress();
    }
  }

  private clearTaildropIncomingTimer(): void {
    if (this.taildropIncomingTimer >= 0) {
      if (typeof clearTimeout === 'function') {
        clearTimeout(this.taildropIncomingTimer);
      }
      this.taildropIncomingTimer = -1;
    }
    this.taildropIncomingDelayMs = 0;
  }

  private scheduleTaildropIncomingPoll(delayMs: number): void {
    if (this.destroying || this.backendStopInFlight || typeof setTimeout !== 'function') {
      return;
    }
    this.clearTaildropIncomingTimer();
    this.taildropIncomingDelayMs = delayMs;
    this.taildropIncomingTimer = setTimeout(() => {
      this.taildropIncomingTimer = -1;
      this.taildropIncomingDelayMs = 0;
      this.refreshTaildropIncomingNotification();
    }, delayMs);
  }

  private refreshTaildropIncomingNotification(): void {
    if (this.destroying || this.backendStopInFlight) {
      return;
    }
    if (this.dnsRebuildInFlight || this.taildropIncomingSnapshotInFlight) {
      if (typeof this.scheduleTaildropIncomingPoll === 'function') {
        this.scheduleTaildropIncomingPoll(this.taildropProgressNotificationVisible ? 250 : 1500);
      }
      return;
    }
    this.taildropIncomingSnapshotInFlight = true;
    let hasActiveIncoming: boolean = false;
    nativeBridge.backendTaildropIncomingSnapshot()
      .then((snapshotText: string) => {
        if (this.destroying) {
          return;
        }
        const incomingFiles: TaildropIncomingFileSummary[] = JSON.parse(snapshotText) as
          TaildropIncomingFileSummary[];
        hasActiveIncoming = Array.isArray(incomingFiles) && incomingFiles.length > 0;
        this.updateTaildropProgressNotification(incomingFiles, this.latestTaildropSnapshot.waitingFiles);
      })
      .catch(() => {
        // The next refresh retries; the full snapshot remains the fallback.
      })
      .finally(() => {
        this.taildropIncomingSnapshotInFlight = false;
        if (!this.destroying && !this.backendStopInFlight &&
          typeof this.scheduleTaildropIncomingPoll === 'function') {
          const nextDelayMs: number =
            (hasActiveIncoming || this.taildropProgressNotificationVisible) ? 250 : 1500;
          this.scheduleTaildropIncomingPoll(nextDelayMs);
        }
      });
  }

  private validTaildropIncomingFile(file: TaildropIncomingFileSummary): boolean {
    return file.name.length > 0 && file.name.length <= 255 && !file.name.includes('/') &&
      !file.name.includes('\\') && file.declaredSize >= -1 && file.received >= 0;
  }

  private validTaildropWaitingFile(file: TaildropWaitingFileSummary): boolean {
    return file.name.length > 0 && file.name.length <= 255 && !file.name.includes('/') &&
      !file.name.includes('\\') && file.size >= 0;
  }

  private taildropInboxNotificationKey(file: TaildropWaitingFileSummary): string {
    return `${file.name}\n${file.size}\n${file.receivedAtMs}`;
  }

  private validTaildropSendRequest(request: TaildropSendRequest): boolean {
    if (request.requestId <= 0 || !/^peer-[a-f0-9]{16}$/.test(request.targetKey) ||
      !RecoverableCachePaths.isTaildropOutboxRoot(this.context, request.outboxRoot) ||
      request.files.length === 0 || request.files.length > 100) {
      return false;
    }
    const rootPrefix: string = `${request.outboxRoot}/`;
    let valid: boolean = true;
    request.files.forEach((file: TaildropSendFile) => {
      if (!valid || file.name.length === 0 || file.name.length > 255 ||
        file.name.includes('/') || file.name.includes('\\') || file.size < 0 ||
        !file.path.startsWith(rootPrefix) || file.path.includes('/../')) {
        valid = false;
        return;
      }
      try {
        const stat: fileIo.Stat = fileIo.lstatSync(file.path);
        if (!stat.isFile() || stat.size !== file.size) {
          valid = false;
        }
      } catch (_error) {
        valid = false;
      }
    });
    return valid;
  }

  private processTaildropSendRequest(): void {
    if (this.taildropSendInFlight) {
      return;
    }
    const requestPath: string = this.taildropSendRequestPath();
    try {
      if (!fileIo.accessSync(requestPath)) {
        return;
      }
      const requestText: string = fileIo.readTextSync(requestPath).trim();
      if (requestText.length === 0) {
        return;
      }
      this.writeTextFile(requestPath, '');
      const request: TaildropSendRequest = JSON.parse(requestText) as TaildropSendRequest;
      if (!this.validTaildropSendRequest(request)) {
        this.persistTaildropTransfer(this.failedTaildropTransfer(
          request.requestId, 'invalid_request', request.targetKey, request.files.length));
        this.cleanupTaildropRequestFiles(request);
        return;
      }
      let totalBytes: number = 0;
      request.files.forEach((file: TaildropSendFile) => {
        totalBytes += file.size;
      });
      this.taildropSendInFlight = true;
      this.persistTaildropTransfer({
        requestId: request.requestId, state: 'queued', reason: '', targetKey: request.targetKey,
        targetName: '', fileName: '', fileIndex: 0, fileCount: request.files.length,
        fileBytes: 0, fileSize: 0, bytesSent: 0, totalBytes: totalBytes, completedAtMs: 0
      });
      this.recordDiagnosticEvent('taildrop_send_requested', 'transfer');
      nativeBridge.backendTaildropSendAsync(JSON.stringify(request))
        .then((resultText: string) => {
          const result: TaildropTransferSummary = JSON.parse(resultText) as TaildropTransferSummary;
          if (result.requestId !== request.requestId ||
            (result.state !== 'completed' && result.state !== 'failed')) {
            this.persistTaildropTransfer(this.failedTaildropTransfer(
              request.requestId, 'invalid_result', request.targetKey, request.files.length, totalBytes));
            this.recordDiagnosticEvent('taildrop_send_failed', 'invalid_result');
            return;
          }
          this.persistTaildropTransfer(result);
          this.recordDiagnosticEvent(result.state === 'completed' ?
            'taildrop_send_completed' : 'taildrop_send_failed', result.reason);
        })
        .catch(() => {
          this.persistTaildropTransfer(this.failedTaildropTransfer(
            request.requestId, 'extension_error', request.targetKey, request.files.length, totalBytes));
          this.recordDiagnosticEvent('taildrop_send_failed', 'extension_error');
        })
        .finally(() => {
          this.cleanupTaildropRequestFiles(request);
          this.taildropSendInFlight = false;
        });
    } catch (_error) {
      this.writeTextFile(requestPath, '');
    }
  }

  private cleanupTaildropRequestFiles(request: TaildropSendRequest): void {
    if (!RecoverableCachePaths.isTaildropOutboxRoot(this.context, request.outboxRoot)) {
      return;
    }
    const rootPrefix: string = `${request.outboxRoot}/`;
    request.files.forEach((file: TaildropSendFile) => {
      if (!file.path.startsWith(rootPrefix)) {
        return;
      }
      try {
        if (fileIo.accessSync(file.path)) {
          fileIo.unlinkSync(file.path);
        }
      } catch (_error) {
        // A failed cleanup is retried when the Extension starts again.
      }
    });
    if (request.files.length > 0) {
      const requestDir: string = request.files[0].path.substring(0,
        request.files[0].path.lastIndexOf('/'));
      if (requestDir.startsWith(rootPrefix)) {
        try {
          fileIo.rmdirSync(requestDir);
        } catch (_error) {
          // The directory may still contain a file whose cleanup failed.
        }
      }
    }
  }

  private cleanupStaleTaildropOutbox(): void {
    const root: string = this.taildropOutboxRoot();
    try {
      fileIo.mkdirSync(root, true);
      fileIo.listFileSync(root).forEach((entry: string) => {
        const requestDir: string = `${root}/${entry}`;
        try {
          const stat: fileIo.Stat = fileIo.statSync(requestDir);
          if (stat.isFile()) {
            fileIo.unlinkSync(requestDir);
            return;
          }
          if (!stat.isDirectory()) {
            return;
          }
          fileIo.listFileSync(requestDir).forEach((name: string) => {
            const path: string = `${requestDir}/${name}`;
            try {
              if (fileIo.statSync(path).isFile()) {
                fileIo.unlinkSync(path);
              }
            } catch (_error) {
              // Continue cleaning the remaining entries.
            }
          });
          fileIo.rmdirSync(requestDir);
        } catch (_error) {
          // Stale cleanup is best-effort and must not block VPN startup.
        }
      });
    } catch (_error) {
      // Outbox creation is retried when the user selects a file.
    }
  }

  private cleanupStaleTaildropInbox(): void {
    const root: string = this.taildropInboxRoot();
    const retainedPaths: string[] = this.retainedTaildropInboxPaths(root);
    const cacheCutoffMs: number = Date.now() - TAILDROP_CACHE_RETENTION_MS;
    try {
      fileIo.mkdirSync(root, true);
      fileIo.listFileSync(root).forEach((name: string) => {
        const path: string = `${root}/${name}`;
        try {
          const stat: fileIo.Stat = fileIo.statSync(path);
          const modifiedMs: number = stat.mtime * 1000;
          if (stat.isFile() && (!retainedPaths.includes(path) ||
            (Number.isFinite(modifiedMs) && modifiedMs > 0 && modifiedMs <= cacheCutoffMs))) {
            fileIo.unlinkSync(path);
          }
        } catch (_error) {
          // Continue cleaning the remaining staged exports.
        }
      });
    } catch (_error) {
      // Inbox staging is created again when the user saves a received file.
    }
  }

  private retainedTaildropInboxPaths(root: string): string[] {
    const retained: string[] = [];
    const snapshotPath: string = `${AccountProfiles.cacheRoot(this.context.filesDir, this.context.filesDir, this.serverControlURL, this.serverProfileId)}/${TAILDROP_INBOX_SNAPSHOT_FILE_NAME}`;
    try {
      if (!fileIo.accessSync(snapshotPath)) {
        return retained;
      }
      const persisted: PersistedTaildropInboxCache = JSON.parse(
        fileIo.readTextSync(snapshotPath)) as PersistedTaildropInboxCache;
      const previews: PersistedTaildropMediaPreview[] = persisted.mediaPreviews === undefined ?
        [] : persisted.mediaPreviews;
      previews.forEach((preview: PersistedTaildropMediaPreview) => {
        this.retainTaildropInboxPath(root, preview.path, retained);
        this.retainTaildropInboxPath(root, preview.thumbnailPath, retained);
      });
      const cachedFiles: PersistedTaildropCachedFile[] = persisted.cachedFiles === undefined ?
        [] : persisted.cachedFiles;
      cachedFiles.forEach((cached: PersistedTaildropCachedFile) =>
        this.retainTaildropInboxPath(root, cached.path, retained));
    } catch (_error) {
      // A malformed snapshot cannot safely claim ownership of an inbox file.
    }
    return retained;
  }

  private retainTaildropInboxPath(root: string, path: string, retained: string[]): void {
    const prefix: string = `${root}/`;
    if (!path.startsWith(prefix)) {
      return;
    }
    const name: string = path.substring(prefix.length);
    if (name.length === 0 || name.includes('/')) {
      return;
    }
    if (!retained.includes(path)) {
      retained.push(path);
    }
  }

  private recordDiagnosticEvent(event: string, phase: string, code: number = 0,
    context?: DiagnosticEventContext): void {
    if (!event.startsWith('vpn_')) {
      DiagnosticEventStore.record(this.context.filesDir, 'vpn', event, phase, code);
      return;
    }
    const failure: boolean = event.includes('failed') || event.includes('timeout') || event.includes('unavailable');
    const signature: string = event + ':' + phase + ':' + code;
    if (failure && signature === this.lastDiagnosticFailure && Date.now() - this.lastDiagnosticFailureAtMs < 30000) {
      return;
    }
    if (failure) {
      this.lastDiagnosticFailure = signature;
      this.lastDiagnosticFailureAtMs = Date.now();
    } else {
      this.lastDiagnosticFailure = '';
    }
    const details: DiagnosticEventContext = context ?? {};
    details.tunActive = this.tunFd >= 0;
    details.shutdownRequested = this.explicitStopRequested;
    DiagnosticEventStore.recordDetailed(this.context.filesDir, 'vpn', event, phase, code, details);
  }

  private backendSnapshotMs: number = 0;

  private writeStatus(status: string): void {
    this.currentVisibleStatus = this.dnsInternalRebuild &&
      !(status.includes('state=Running') && status.includes('tun=true')) &&
      !status.startsWith('FAILED') && !/disconnect|stopped|destroyed/i.test(status) ?
      'VPN DNS restarting' : status;
    this.writeCurrentStatusHeartbeat();
  }

  private writeCurrentStatusHeartbeat(): void {
    this.writeAtomicTextFile(`${this.context.filesDir}/${VPN_PROBE_STATUS_FILE_NAME}`,
      `${this.currentVisibleStatus} | heartbeatMs=${Date.now()} | snapshotMs=${this.backendSnapshotMs}`);
  }

  private writeTextFile(path: string, content: string): boolean {
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, content);
      return true;
    } catch (_error) {
      // Status persistence is best-effort and must never stop VPN startup.
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

  private writeAtomicTextFile(path: string, content: string): boolean {
    const temporaryPath: string = `${path}.tmp`;
    if (!this.writeTextFile(temporaryPath, content)) {
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
        // A later status update retries the snapshot write.
      }
      return false;
    }
  }

  onDestroy(): void {
    // Persist lifecycle entry before any teardown can throw or await.
    this.recordDiagnosticEvent('vpn_destroy_started', this.explicitStopRequested ? 'user_request' : 'system_lifecycle');
    this.destroying = true;
    this.bindStub = undefined;
    this.rpcChannelsInitialized = false;
    this.peerSnapshotRequestId++;
    this.dnsObserver.stop();
    this.dnsSystemPlan = undefined;
    this.writeDnsSystemStatus('stopped', false);
    this.networkMonitor.stop();
    this.recordDiagnosticEvent('vpn_extension_destroyed', this.explicitStopRequested ? 'user_request' : 'system_lifecycle');
    // Stop sampling/network work, but the persistent spool accepts async teardown tails.
    this.runtimeDiagnostic.stop();
    this.stopBackendStopWatcher();
    if (this.statusTimer >= 0) {
      clearInterval(this.statusTimer);
      this.statusTimer = -1;
    }
    if (this.taildropRequestTimer >= 0) {
      clearInterval(this.taildropRequestTimer);
      this.taildropRequestTimer = -1;
    }
    if (typeof this.clearTaildropIncomingTimer === 'function') {
      this.clearTaildropIncomingTimer();
    } else if (this.taildropIncomingTimer >= 0 && typeof clearTimeout === 'function') {
      clearTimeout(this.taildropIncomingTimer);
      this.taildropIncomingTimer = -1;
    }
    const connection = this.vpnConnection;
    this.vpnConnection = undefined;
    this.tunFd = -1;
    void this.finishDestroyedBackend(connection);
    this.lastTaildropSnapshotSignature = '';
    this.lastTaildropSnapshotWriteMs = 0;
    this.lastPeerSnapshotSignature = '';
    this.lastPeerSnapshotWriteMs = 0;
    // Keep the last authenticated peer directory for the disconnected UI.
    // The VPN connection is being torn down, but the cached transfer view
    // still needs the device list until a new live snapshot replaces it.
    const finalTransfer: TaildropTransferSummary = this.latestTaildropSnapshot.transfer.state === 'sending' ||
      this.latestTaildropSnapshot.transfer.state === 'queued' ?
      this.failedTaildropTransfer(this.latestTaildropSnapshot.transfer.requestId, 'disconnected',
        this.latestTaildropSnapshot.transfer.targetKey,
        this.latestTaildropSnapshot.transfer.fileCount,
        this.latestTaildropSnapshot.transfer.totalBytes) : this.latestTaildropSnapshot.transfer;
    this.writeTaildropSnapshot({
      state: 'disconnected', reason: '', targets: [], incomingFiles: [], waitingFiles: [], inboxReason: '',
      transfer: finalTransfer
    });
    this.writeStatus('VPN extension destroyed');
    hilog.info(DOMAIN, TAG, 'VPN extension destroyed');
  }
}
