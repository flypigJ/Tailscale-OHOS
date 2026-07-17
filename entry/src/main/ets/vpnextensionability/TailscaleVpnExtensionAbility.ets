import { Want } from '@kit.AbilityKit';
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import nativeBridge from 'libtailscale_ohos.so';
import { DiagnosticEventStore } from '../services/DiagnosticEventStore';

const DOMAIN = 0x0000;
const TAG = 'TailscaleVpn';
const BUNDLE_NAME = 'io.github.tailscaleohos';
const VPN_EXISTS_ERROR_CODE: number = 2203002;
const VPN_DESTROY_SETTLE_MS: number = 300;
const VPN_ID_FILE_NAME: string = 'tailscale-vpn-id';
const VPN_REPLACE_APPROVAL_FILE_NAME: string = 'vpn-replace-approved';
const VPN_REPLACE_APPROVAL_TTL_MS: number = 10000;
const PEER_CONNECTIVITY_REQUEST_FILE_NAME: string = 'peer-connectivity-request.json';
const PEER_CONNECTIVITY_RESPONSE_FILE_NAME: string = 'peer-connectivity-response.json';
const TAILDROP_TARGETS_FILE_NAME: string = 'taildrop-targets.json';
const VPN_PEERS_FILE_NAME: string = 'vpn-peers.json';
const VPN_STOP_REQUEST_FILE_NAME: string = 'vpn-stop-request.json';
const VPN_STOP_RESPONSE_FILE_NAME: string = 'vpn-stop-response.json';

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

export default class TailscaleVpnExtensionAbility extends VpnExtensionAbility {
  private vpnConnection?: vpnExtension.VpnConnection;
  private tunFd: number = -1;
  private statusTimer: number = -1;
  private statusUpdateInFlight: boolean = false;
  private activeVpnId: string = '';
  private peerConnectivityInFlight: boolean = false;
  private backendStopInFlight: boolean = false;
  private destroying: boolean = false;

  onCreate(want: Want): void {
    this.recordDiagnosticEvent('vpn_extension_created', 'lifecycle');
    this.writePeerSnapshot([]);
    this.writeTaildropSnapshot({ state: 'loading', reason: '', targets: [] });
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
        this.clearOwnedVpnId();
        await this.waitForVpnDestroy();
      }
      const vpnId: string = await this.vpnConnection.generateVpnId();
      if (vpnId.length === 0) {
        this.recordDiagnosticEvent('vpn_id_failed', 'create');
        this.writeStatus('FAILED | VPN ID generation | empty identifier');
        return;
      }
      config.vpnId = vpnId;
      this.writeStatus('VPN probe TUN creation pending');
      this.tunFd = await this.vpnConnection.create(config);
      this.recordDiagnosticEvent('vpn_tun_created', 'create');
      this.activeVpnId = vpnId;
      this.writeOwnedVpnId(vpnId);
      const probeStatus: string = nativeBridge.tunFdProbe(this.tunFd);
      if (backendReady && probeStatus.startsWith('OK')) {
        const restartStatus: string = nativeBridge.backendRestartWithTun(
          `${this.context.filesDir}/tailscale`, this.deviceModel(), this.tunFd);
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
        this.activeVpnId = '';
        this.clearOwnedVpnId();
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

  private vpnIdFilePath(): string {
    return `${this.context.filesDir}/${VPN_ID_FILE_NAME}`;
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

  private writeOwnedVpnId(vpnId: string): void {
    this.writeTextFile(this.vpnIdFilePath(), vpnId);
  }

  private clearOwnedVpnId(): void {
    this.writeOwnedVpnId('');
  }

  private async restoreBackendVpnConfig(): Promise<string> {
    const stateDir: string = `${this.context.filesDir}/tailscale`;
    nativeBridge.backendStart(stateDir, this.deviceModel());
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

  private deviceModel(): string {
    const marketName: string = deviceInfo.marketName.trim();
    if (marketName.length > 0 && marketName !== 'default') {
      return marketName;
    }
    return deviceInfo.productModel.trim();
  }

  private async waitForVpnBackend(initialStatus: string): Promise<string> {
    if (initialStatus.startsWith('FAILED')) {
      return initialStatus;
    }
    let backendStatus: string = initialStatus;
    for (let attempt: number = 0; attempt < 60; attempt++) {
      const snapshotText: string = await nativeBridge.backendSnapshot();
      backendStatus = (JSON.parse(snapshotText) as BackendHealthSnapshot).status;
      if (backendStatus.includes('state=Running') || backendStatus.startsWith('FAILED')) {
        return backendStatus;
      }
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, 250);
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
        })
        .catch(() => {
          if (this.destroying) {
            return;
          }
          this.writeStatus('FAILED | VPN backend | status unavailable');
          this.writeTaildropSnapshot({ state: 'unavailable', reason: 'query_failed', targets: [] });
        })
        .finally(() => {
          this.statusUpdateInFlight = false;
        });
    }, 1000);
  }

  private writePeerStatus(status: string): void {
    this.writeTextFile(`${this.context.filesDir}/vpn-peer-probe-status.txt`, status);
  }

  private writeTaildropSnapshot(snapshot: TaildropSnapshot): void {
    const persisted: PersistedTaildropSnapshot = {
      state: snapshot.state,
      reason: snapshot.reason,
      targets: snapshot.targets,
      updatedAtMs: Date.now()
    };
    this.writeTextFile(`${this.context.filesDir}/${TAILDROP_TARGETS_FILE_NAME}`,
      JSON.stringify(persisted));
  }

  private writePeerSnapshot(peers: PeerSummary[]): void {
    const persisted: PersistedPeerSnapshot = {
      peers: peers,
      updatedAtMs: Date.now()
    };
    this.writeTextFile(`${this.context.filesDir}/${VPN_PEERS_FILE_NAME}`,
      JSON.stringify(persisted));
  }

  private processBackendStopRequest(): boolean {
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
      nativeBridge.backendStopAsync()
        .then((status: string) => {
          const response: VpnStopResponse = { requestId: request.requestId, status: status };
          this.writeTextFile(`${this.context.filesDir}/${VPN_STOP_RESPONSE_FILE_NAME}`,
            JSON.stringify(response));
          this.recordDiagnosticEvent(status.startsWith('OK') ?
            'vpn_backend_stopped' : 'vpn_backend_stop_failed', 'disconnect');
        })
        .catch(() => {
          const response: VpnStopResponse = {
            requestId: request.requestId,
            status: 'FAILED | backend stop | extension error'
          };
          this.writeTextFile(`${this.context.filesDir}/${VPN_STOP_RESPONSE_FILE_NAME}`,
            JSON.stringify(response));
          this.recordDiagnosticEvent('vpn_backend_stop_failed', 'disconnect');
        })
        .finally(() => {
          this.backendStopInFlight = false;
        });
      return true;
    } catch (_error) {
      this.writeTextFile(requestPath, '');
      return false;
    }
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

  private recordDiagnosticEvent(event: string, phase: string, code: number = 0): void {
    DiagnosticEventStore.record(this.context.filesDir, 'vpn', event, phase, code);
  }

  private writeStatus(status: string): void {
    this.writeTextFile(`${this.context.filesDir}/vpn-probe-status.txt`,
      `${status} | heartbeatMs=${Date.now()}`);
  }

  private writeTextFile(path: string, content: string): void {
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, content);
    } catch (_error) {
      // Status persistence is best-effort and must never stop VPN startup.
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

  onDestroy(): void {
    this.destroying = true;
    this.recordDiagnosticEvent('vpn_extension_destroyed', 'lifecycle');
    if (this.statusTimer >= 0) {
      clearInterval(this.statusTimer);
      this.statusTimer = -1;
    }
    const connection = this.vpnConnection;
    const vpnId: string = this.activeVpnId;
    this.vpnConnection = undefined;
    this.activeVpnId = '';
    this.tunFd = -1;
    try {
      const backendStopStatus: string = nativeBridge.backendStop();
      this.recordDiagnosticEvent(backendStopStatus.startsWith('OK') ?
        'vpn_backend_stopped' : 'vpn_backend_stop_failed', 'destroy');
    } catch (_error) {
      this.recordDiagnosticEvent('vpn_backend_stop_failed', 'destroy');
    }
    this.writePeerSnapshot([]);
    this.writeTaildropSnapshot({ state: 'disconnected', reason: '', targets: [] });
    this.writeStatus('VPN extension destroyed');
    if (connection !== undefined && vpnId.length > 0) {
      try {
        const destroyPromise: Promise<void> = connection.destroy(vpnId);
        destroyPromise
          .then(() => this.clearOwnedVpnId())
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
