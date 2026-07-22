import { Want } from '@kit.AbilityKit';
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import nativeBridge from 'libtailscale_ohos.so';
import { DiagnosticEventStore } from '../services/DiagnosticEventStore';
import { ControlServerConfig, ControlServerSettings } from '../services/ControlServerConfig';
import { DeviceNameService } from '../services/DeviceNameService';

const DOMAIN = 0x0000;
const TAG = 'TailscaleVpn';
const BUNDLE_NAME = 'io.github.tailscaleohos';
const VPN_EXISTS_ERROR_CODE: number = 2203002;
const VPN_DESTROY_SETTLE_MS: number = 300;
const VPN_REPLACE_APPROVAL_FILE_NAME: string = 'vpn-replace-approved';
const VPN_REPLACE_APPROVAL_TTL_MS: number = 10000;
const PEER_CONNECTIVITY_REQUEST_FILE_NAME: string = 'peer-connectivity-request.json';
const PEER_CONNECTIVITY_RESPONSE_FILE_NAME: string = 'peer-connectivity-response.json';
const TAILDROP_OUTBOX_DIR_NAME: string = 'taildrop-outbox';
const TAILDROP_SEND_REQUEST_FILE_NAME: string = 'taildrop-send-request.json';
const TAILDROP_TARGETS_FILE_NAME: string = 'taildrop-targets.json';
const TAILDROP_CANCEL_REQUEST_FILE_NAME: string = 'taildrop-cancel-request.json';
const TAILDROP_INBOX_DIR_NAME: string = 'taildrop-inbox-export';
const TAILDROP_RECEIVE_REQUEST_FILE_NAME: string = 'taildrop-receive-request.json';
const TAILDROP_RECEIVE_RESPONSE_FILE_NAME: string = 'taildrop-receive-response.json';
const VPN_PEERS_FILE_NAME: string = 'vpn-peers.json';
const VPN_STOP_REQUEST_FILE_NAME: string = 'vpn-stop-request.json';
const VPN_STOP_RESPONSE_FILE_NAME: string = 'vpn-stop-response.json';
const VPN_CONFIG_SUMMARY_FILE_NAME: string = 'vpn-config-summary.txt';
const VPN_CONNECT_CONFIG_FILE_NAME: string = 'vpn-connect-config.json';
const VPN_CONNECT_CONFIG_TTL_MS: number = 15000;
const VPN_BACKEND_STATUS_POLL_INTERVAL_MS: number = 100;
const VPN_BACKEND_STATUS_MAX_ATTEMPTS: number = 150;
const FILE_WATCH_CLOSE_WRITE: number = 0x8;

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

interface VpnConnectConfigHandoff {
  createdAtMs: number;
  config: string;
}

interface TaildropTargetSummary {
  key: string;
  name: string;
  os: string;
  deviceModel: string;
  online: boolean;
}

interface TaildropSnapshot {
  state: string;
  reason: string;
  targets: TaildropTargetSummary[];
  waitingFiles: TaildropWaitingFileSummary[];
  inboxReason: string;
  transfer: TaildropTransferSummary;
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

interface PersistedTaildropSnapshot extends TaildropSnapshot {
  updatedAtMs: number;
}

interface BackendHealthSnapshot {
  status: string;
  peers: PeerSummary[];
  taildrop: TaildropSnapshot;
}

interface PeerConnectivityRequest {
  requestId: number;
  peerKey: string;
}

interface PeerConnectivityResponse {
  requestId: number;
  result: string;
}

function emptyTaildropTransfer(): TaildropTransferSummary {
  return {
    requestId: 0, state: 'idle', reason: '', targetKey: '', targetName: '', fileName: '',
    fileIndex: 0, fileCount: 0, fileBytes: 0, fileSize: 0, bytesSent: 0, totalBytes: 0,
    completedAtMs: 0
  };
}

export default class TailscaleVpnExtensionAbility extends VpnExtensionAbility {
  private vpnConnection?: vpnExtension.VpnConnection;
  private tunFd: number = -1;
  private statusTimer: number = -1;
  private statusUpdateInFlight: boolean = false;
  private backendStopWatcher?: fileIo.Watcher;
  private peerConnectivityInFlight: boolean = false;
  private taildropSendInFlight: boolean = false;
  private taildropCancelInFlight: boolean = false;
  private taildropReceiveInFlight: boolean = false;
  private backendStopInFlight: boolean = false;
  private destroying: boolean = false;
  private latestTaildropSnapshot: TaildropSnapshot = {
    state: 'loading', reason: '', targets: [], waitingFiles: [], inboxReason: '',
    transfer: emptyTaildropTransfer()
  };

  onCreate(want: Want): void {
    this.recordDiagnosticEvent('vpn_extension_created', 'lifecycle');
    this.writePeerSnapshot([]);
    this.cleanupStaleTaildropOutbox();
    this.cleanupStaleTaildropInbox();
    this.writeTextFile(`${this.context.filesDir}/${TAILDROP_SEND_REQUEST_FILE_NAME}`, '');
    this.writeTextFile(`${this.context.filesDir}/${TAILDROP_CANCEL_REQUEST_FILE_NAME}`, '');
    this.writeTextFile(`${this.context.filesDir}/${TAILDROP_RECEIVE_REQUEST_FILE_NAME}`, '');
    this.writeTextFile(`${this.context.filesDir}/${TAILDROP_RECEIVE_RESPONSE_FILE_NAME}`, '');
    // A previous extension process can be killed before consuming a graceful
    // stop request. Never let that stale request stop a newly created session.
    this.writeTextFile(`${this.context.filesDir}/${VPN_STOP_REQUEST_FILE_NAME}`, '');
    this.writeTextFile(`${this.context.filesDir}/${VPN_STOP_RESPONSE_FILE_NAME}`, '');
    this.startBackendStopWatcher();
    this.writeTextFile(`${this.context.filesDir}/${VPN_CONFIG_SUMMARY_FILE_NAME}`, '');
    this.writeTaildropSnapshot({
      state: 'loading', reason: '', targets: [], waitingFiles: [], inboxReason: '',
      transfer: emptyTaildropTransfer()
    });
    this.writeStatus('VPN extension lifecycle entered');
    hilog.info(DOMAIN, TAG, 'VPN extension created. ability=%{public}s', want.abilityName ?? '');
    try {
      this.vpnConnection = vpnExtension.createVpnConnection(this.context);
      this.writeStatus('VPN connection object created');
      this.createProbeTun();
    } catch (error) {
      const businessError = error as BusinessError;
      this.writeStatus(`FAILED | VPN connection object | code=${businessError.code ?? -1}`);
      hilog.error(DOMAIN, TAG, 'VPN connection initialization failed. code=%{public}d',
        businessError.code ?? -1);
    }
  }

  private async createProbeTun(): Promise<void> {
    if (this.vpnConnection === undefined) {
      return;
    }
    const controlSettings: ControlServerSettings = ControlServerConfig.load(this.context.filesDir);
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
    const backendConfigText: string = await this.restoreBackendVpnConfig();
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
            gateway: { address: '::', family: 2 },
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
              gateway: { address: family === 2 ? '::' : '0.0.0.0', family: family },
              hasGateway: false,
              isDefaultRoute: prefixLength === 0
            });
          }
        }
        const useTailscaleDNS: boolean = configParts.length >= 4 && configParts[3] === 'true';
        config = {
          addresses: addresses,
          routes: routes,
          dnsAddresses: useTailscaleDNS ? ['100.100.100.100'] : [],
          mtu: 1280,
          isIPv4Accepted: true,
          isIPv6Accepted: configParts[1].length > 0,
          isBlocking: false,
          blockedApplications: [BUNDLE_NAME]
        };
        backendReady = true;
      }
    }

    try {
      if (this.consumeVpnReplaceApproval()) {
        this.recordDiagnosticEvent('vpn_replacement_approved', 'destroy_existing');
        this.writeStatus('Disconnecting existing VPN connection');
        await this.vpnConnection.destroy();
        await this.waitForVpnDestroy();
      }
      this.writeVpnConfigSummary(config);
      this.writeStatus('VPN probe TUN creation pending');
      this.tunFd = await this.vpnConnection.create(config);
      this.recordDiagnosticEvent('vpn_tun_created', 'create');
      const probeStatus: string = nativeBridge.tunFdProbe(this.tunFd);
      if (backendReady && probeStatus.startsWith('OK')) {
        this.writeStatus('VPN interface established | backend starting');
        try {
          await this.vpnConnection.protectProcessNet();
          this.recordDiagnosticEvent('vpn_process_protected', 'network');
        } catch (_error) {
          // blockedApplications already excludes this bundle; keep it as the
          // compatibility fallback when process-wide protection is unavailable.
          this.recordDiagnosticEvent('vpn_process_protect_failed', 'network');
        }
        const restartStatus: string = nativeBridge.backendRestartWithTun(
          `${this.context.filesDir}/tailscale`, this.deviceModel(), controlSettings.controlURL, this.tunFd);
        const finalStatus: string = await this.waitForVpnBackend(restartStatus);
        this.writeStatus(finalStatus);
        if (finalStatus.includes('state=Running')) {
          this.recordDiagnosticEvent('vpn_connected', 'backend');
          await nativeBridge.backendArmMagicDNSProbeAsync();
          this.writePeerStatus(await nativeBridge.backendPeerProbeAsync());
          this.startStatusUpdates();
        }
      } else {
        const backendState: string = backendConfigText.startsWith('FAILED') ?
          backendConfigText : 'FAILED | VPN config | invalid address payload';
        this.writeStatus(`${probeStatus} | ${backendState}`);
      }
      hilog.info(DOMAIN, TAG, 'VPN probe TUN created. bridge=%{public}s', probeStatus);
    } catch (error) {
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

  private async waitForVpnDestroy(): Promise<void> {
    await new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, VPN_DESTROY_SETTLE_MS);
    });
  }

  private writeVpnConfigSummary(config: vpnExtension.VpnConfig): void {
    const routes: vpnExtension.RouteInfo[] = config.routes ?? [];
    const hasDefaultIPv4: boolean = routes.some((route: vpnExtension.RouteInfo) =>
      route.destination.address.address === '0.0.0.0' && route.destination.prefixLength === 0 &&
      route.isDefaultRoute);
    const hasDefaultIPv6: boolean = routes.some((route: vpnExtension.RouteInfo) =>
      route.destination.address.address === '::' && route.destination.prefixLength === 0 &&
      route.isDefaultRoute);
    this.writeTextFile(`${this.context.filesDir}/${VPN_CONFIG_SUMMARY_FILE_NAME}`,
      `routes=${routes.length} | defaultIPv4=${hasDefaultIPv4} | defaultIPv6=${hasDefaultIPv6}`);
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
    const stateDir: string = `${this.context.filesDir}/tailscale`;
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
    nativeBridge.backendStart(
      stateDir, this.deviceModel(), this.harmonyOSVersion(), controlSettings.controlURL);
    let configStatus: string = 'FAILED | VPN config | backend restore timeout';
    for (let attempt: number = 0; attempt < 60; attempt++) {
      configStatus = nativeBridge.backendVpnConfig();
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
    const displayVersion: string = deviceInfo.displayVersion.trim();
    const versionMatch: RegExpMatchArray | null = displayVersion.match(/(\d+)\.(\d+)/);
    if (versionMatch !== null) {
      return `${versionMatch[1]}.${versionMatch[2]}`;
    }
    if (deviceInfo.majorVersion > 0) {
      return `${deviceInfo.majorVersion}.${Math.max(0, deviceInfo.seniorVersion)}`;
    }
    return displayVersion.length > 0 ? displayVersion : '—';
  }

  private async waitForVpnBackend(initialStatus: string): Promise<string> {
    if (initialStatus.startsWith('FAILED')) {
      return initialStatus;
    }
    let backendStatus: string = initialStatus;
    let visibleStatus: string = '';
    for (let attempt: number = 0; attempt < VPN_BACKEND_STATUS_MAX_ATTEMPTS; attempt++) {
      const snapshotText: string = await nativeBridge.backendSnapshot();
      backendStatus = (JSON.parse(snapshotText) as BackendHealthSnapshot).status;
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
    if (this.statusTimer >= 0) {
      clearInterval(this.statusTimer);
    }
    this.statusTimer = setInterval(() => {
      if (this.statusUpdateInFlight || this.backendStopInFlight) {
        return;
      }
      if (this.processBackendStopRequest()) {
        return;
      }
      this.statusUpdateInFlight = true;
      nativeBridge.backendSnapshot()
        .then((snapshotText: string) => {
          if (this.destroying) {
            return;
          }
          const snapshot: BackendHealthSnapshot = JSON.parse(snapshotText) as BackendHealthSnapshot;
          this.writeStatus(snapshot.status);
          this.writePeerSnapshot(snapshot.peers);
          this.writeTaildropSnapshot(snapshot.taildrop);
          this.processPeerConnectivityRequest();
          this.processTaildropSendRequest();
          this.processTaildropCancelRequest();
          this.processTaildropReceiveRequest();
        })
        .catch(() => {
          if (this.destroying) {
            return;
          }
          this.writeStatus('FAILED | VPN backend | status unavailable');
          this.writeTaildropSnapshot({
            state: 'unavailable', reason: 'query_failed', targets: [],
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

  private writePeerStatus(status: string): void {
    this.writeTextFile(`${this.context.filesDir}/vpn-peer-probe-status.txt`, status);
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
    const persisted: PersistedTaildropSnapshot = {
      state: snapshot.state,
      reason: snapshot.reason,
      targets: snapshot.targets,
      waitingFiles: snapshot.waitingFiles,
      inboxReason: snapshot.inboxReason,
      transfer: snapshot.transfer,
      updatedAtMs: Date.now()
    };
    this.writeAtomicTextFile(`${this.context.filesDir}/${TAILDROP_TARGETS_FILE_NAME}`,
      JSON.stringify(persisted));
  }

  private writePeerSnapshot(peers: PeerSummary[]): void {
    const persisted: PersistedPeerSnapshot = {
      peers: peers,
      updatedAtMs: Date.now()
    };
    this.writeAtomicTextFile(`${this.context.filesDir}/${VPN_PEERS_FILE_NAME}`,
      JSON.stringify(persisted));
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
    let status: string = 'FAILED | backend stop | extension error';
    const reconnectConfigPromise: Promise<string> = nativeBridge.backendVpnConfigAsync()
      .catch(() => 'FAILED | VPN config | extension error');
    const connection: vpnExtension.VpnConnection | undefined = this.vpnConnection;
    if (connection !== undefined) {
      try {
        await connection.destroy();
        this.vpnConnection = undefined;
        this.tunFd = -1;
        this.writeStatus('VPN disconnected | backend stopping');
        this.recordDiagnosticEvent('vpn_tun_destroyed', 'disconnect');
      } catch (_error) {
        this.recordDiagnosticEvent('vpn_tun_destroy_failed', 'disconnect');
      }
    }
    const reconnectConfig: string = await reconnectConfigPromise;
    this.stageVpnReconnectConfig(reconnectConfig);
    try {
      status = await nativeBridge.backendStopAsync();
      this.recordDiagnosticEvent(status.startsWith('OK') ?
        'vpn_backend_stopped' : 'vpn_backend_stop_failed', 'disconnect');
    } catch (_error) {
      this.recordDiagnosticEvent('vpn_backend_stop_failed', 'disconnect');
    }
    const response: VpnStopResponse = { requestId: request.requestId, status: status };
    this.writeTextFile(`${this.context.filesDir}/${VPN_STOP_RESPONSE_FILE_NAME}`,
      JSON.stringify(response));
    this.backendStopInFlight = false;
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

  private peerConnectivityRequestPath(): string {
    return `${this.context.filesDir}/${PEER_CONNECTIVITY_REQUEST_FILE_NAME}`;
  }

  private peerConnectivityResponsePath(): string {
    return `${this.context.filesDir}/${PEER_CONNECTIVITY_RESPONSE_FILE_NAME}`;
  }

  private processPeerConnectivityRequest(): void {
    if (this.peerConnectivityInFlight) {
      return;
    }
    const requestPath: string = this.peerConnectivityRequestPath();
    try {
      if (!fileIo.accessSync(requestPath)) {
        return;
      }
      const requestText: string = fileIo.readTextSync(requestPath).trim();
      if (requestText.length === 0) {
        return;
      }
      this.writeTextFile(requestPath, '');
      const request: PeerConnectivityRequest = JSON.parse(requestText) as PeerConnectivityRequest;
      if (request.requestId <= 0 || !/^peer-[a-f0-9]{16}$/.test(request.peerKey)) {
        return;
      }
      this.peerConnectivityInFlight = true;
      nativeBridge.backendPeerConnectivityAsync(request.peerKey)
        .then((result: string) => {
          const response: PeerConnectivityResponse = { requestId: request.requestId, result: result };
          this.writeTextFile(this.peerConnectivityResponsePath(), JSON.stringify(response));
        })
        .catch(() => {
          const failedResult: string = '{"state":"failed","reason":"extension_error",' +
            '"sent":0,"received":0,"lossPercent":0,"minLatencyMs":0,"avgLatencyMs":0,"maxLatencyMs":0}';
          const response: PeerConnectivityResponse = {
            requestId: request.requestId,
            result: failedResult
          };
          this.writeTextFile(this.peerConnectivityResponsePath(), JSON.stringify(response));
        })
        .finally(() => {
          this.peerConnectivityInFlight = false;
        });
    } catch (_error) {
      this.writeTextFile(requestPath, '');
    }
  }

  private taildropOutboxRoot(): string {
    return `${this.context.filesDir}/${TAILDROP_OUTBOX_DIR_NAME}`;
  }

  private taildropSendRequestPath(): string {
    return `${this.context.filesDir}/${TAILDROP_SEND_REQUEST_FILE_NAME}`;
  }

  private taildropCancelRequestPath(): string {
    return `${this.context.filesDir}/${TAILDROP_CANCEL_REQUEST_FILE_NAME}`;
  }

  private taildropInboxRoot(): string {
    return `${this.context.filesDir}/${TAILDROP_INBOX_DIR_NAME}`;
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
      waitingFiles: this.latestTaildropSnapshot.waitingFiles,
      inboxReason: this.latestTaildropSnapshot.inboxReason,
      transfer: transfer
    });
  }

  private validTaildropSendRequest(request: TaildropSendRequest): boolean {
    if (request.requestId <= 0 || !/^peer-[a-f0-9]{16}$/.test(request.targetKey) ||
      request.outboxRoot !== this.taildropOutboxRoot() ||
      request.files.length === 0 || request.files.length > 10) {
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
        const stat: fileIo.Stat = fileIo.statSync(file.path);
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
    const rootPrefix: string = `${this.taildropOutboxRoot()}/`;
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
    try {
      fileIo.mkdirSync(root, true);
      fileIo.listFileSync(root).forEach((name: string) => {
        const path: string = `${root}/${name}`;
        try {
          if (fileIo.statSync(path).isFile()) {
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

  private recordDiagnosticEvent(event: string, phase: string, code: number = 0): void {
    DiagnosticEventStore.record(this.context.filesDir, 'vpn', event, phase, code);
  }

  private writeStatus(status: string): void {
    this.writeTextFile(`${this.context.filesDir}/vpn-probe-status.txt`,
      `${status} | heartbeatMs=${Date.now()}`);
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

  private writeAtomicTextFile(path: string, content: string): void {
    const temporaryPath: string = `${path}.tmp`;
    if (!this.writeTextFile(temporaryPath, content)) {
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
        // A later status update retries the snapshot write.
      }
    }
  }

  onDestroy(): void {
    this.destroying = true;
    this.recordDiagnosticEvent('vpn_extension_destroyed', 'lifecycle');
    this.stopBackendStopWatcher();
    if (this.statusTimer >= 0) {
      clearInterval(this.statusTimer);
      this.statusTimer = -1;
    }
    const connection = this.vpnConnection;
    this.vpnConnection = undefined;
    this.tunFd = -1;
    try {
      const backendStopStatus: string = nativeBridge.backendStop();
      this.recordDiagnosticEvent(backendStopStatus.startsWith('OK') ?
        'vpn_backend_stopped' : 'vpn_backend_stop_failed', 'destroy');
    } catch (_error) {
      this.recordDiagnosticEvent('vpn_backend_stop_failed', 'destroy');
    }
    this.writePeerSnapshot([]);
    const finalTransfer: TaildropTransferSummary = this.latestTaildropSnapshot.transfer.state === 'sending' ||
      this.latestTaildropSnapshot.transfer.state === 'queued' ?
      this.failedTaildropTransfer(this.latestTaildropSnapshot.transfer.requestId, 'disconnected',
        this.latestTaildropSnapshot.transfer.targetKey,
        this.latestTaildropSnapshot.transfer.fileCount,
        this.latestTaildropSnapshot.transfer.totalBytes) : this.latestTaildropSnapshot.transfer;
    this.writeTaildropSnapshot({
      state: 'disconnected', reason: '', targets: [], waitingFiles: [], inboxReason: '',
      transfer: finalTransfer
    });
    this.writeStatus('VPN extension destroyed');
    if (connection !== undefined) {
      try {
        const destroyPromise: Promise<void> = connection.destroy();
        destroyPromise
          .catch((error: BusinessError) => {
            hilog.error(DOMAIN, TAG, 'VPN destroy failed. code=%{public}d', error.code);
          });
      } catch (error) {
        const businessError = error as BusinessError;
        hilog.error(DOMAIN, TAG, 'VPN destroy failed. code=%{public}d', businessError.code ?? -1);
      }
    }
    hilog.info(DOMAIN, TAG, 'VPN extension destroyed');
  }
}
