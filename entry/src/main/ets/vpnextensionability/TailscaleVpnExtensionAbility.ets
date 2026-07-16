import { Want } from '@kit.AbilityKit';
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import nativeBridge from 'libtailscale_ohos.so';

const DOMAIN = 0x0000;
const TAG = 'TailscaleVpn';
const BUNDLE_NAME = 'io.github.tailscaleohos';

interface BackendHealthSnapshot {
  status: string;
}

export default class TailscaleVpnExtensionAbility extends VpnExtensionAbility {
  private vpnConnection?: vpnExtension.VpnConnection;
  private tunFd: number = -1;
  private statusTimer: number = -1;
  private statusUpdateInFlight: boolean = false;

  onCreate(want: Want): void {
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

    // A development reinstall can terminate the prior extension before its
    // asynchronous onDestroy cleanup finishes. destroy() is scoped to this
    // application's VPN connection and makes startup idempotent.
    this.writeStatus('Removing stale application VPN instance');
    try {
      await this.vpnConnection.destroy();
    } catch (_cleanupError) {
      // No existing connection is also a valid clean state.
    }

    try {
      this.writeStatus('VPN probe TUN creation pending');
      this.tunFd = await this.vpnConnection.create(config);
      const probeStatus: string = nativeBridge.tunFdProbe(this.tunFd);
      if (backendReady && probeStatus.startsWith('OK')) {
        const restartStatus: string = nativeBridge.backendRestartWithTun(
          `${this.context.filesDir}/tailscale`, this.deviceModel(), this.tunFd);
        const finalStatus: string = await this.waitForVpnBackend(restartStatus);
        this.writeStatus(finalStatus);
        if (finalStatus.includes('state=Running')) {
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
      this.writeStatus(`FAILED | VPN probe TUN | code=${businessError.code ?? -1}`);
      hilog.error(DOMAIN, TAG, 'VPN probe TUN creation failed. code=%{public}d',
        businessError.code ?? -1);
    }
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
      if (this.statusUpdateInFlight) {
        return;
      }
      this.statusUpdateInFlight = true;
      nativeBridge.backendSnapshot()
        .then((snapshotText: string) => {
          const snapshot: BackendHealthSnapshot = JSON.parse(snapshotText) as BackendHealthSnapshot;
          this.writeStatus(snapshot.status);
        })
        .catch(() => {
          this.writeStatus('FAILED | VPN backend | status unavailable');
        })
        .finally(() => {
          this.statusUpdateInFlight = false;
        });
    }, 1000);
  }

  private writePeerStatus(status: string): void {
    this.writeTextFile(`${this.context.filesDir}/vpn-peer-probe-status.txt`, status);
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
    if (this.statusTimer >= 0) {
      clearInterval(this.statusTimer);
      this.statusTimer = -1;
    }
    const connection = this.vpnConnection;
    this.vpnConnection = undefined;
    this.tunFd = -1;
    this.writeStatus('VPN extension destroyed');
    if (connection !== undefined) {
      connection.destroy().catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'VPN destroy failed. code=%{public}d', error.code);
      });
    }
    hilog.info(DOMAIN, TAG, 'VPN extension destroyed');
  }
}
