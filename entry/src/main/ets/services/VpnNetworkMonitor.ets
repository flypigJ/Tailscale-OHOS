import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import nativeBridge from 'libtailscale_ohos.so';
import { DiagnosticEventContext } from './DiagnosticEventStore';

const SETTLE_MS: number = 750;
const MIN_REBIND_MS: number = 3000;
const RETRY_MS: number = 5000;
const HEALTH_CHECK_MS: number = 30000;

interface PhysicalNetwork {
  interfaceName: string;
  fingerprint: string;
  bearer: string;
  bearerMask: number;
  capabilityMask: number;
  mtu: number;
  addressFamilyMask: number;
}

// PR #11 introduced the host-to-Go network change bridge. Keep it in the VPN
// process so UI backgrounding does not disconnect the callback. A revision is
// retained until applied, including events received during an awaited rebind.
export class VpnNetworkMonitor {
  private active: boolean = false;
  private generation: number = 0;
  private revision: number = 0;
  private appliedRevision: number = 0;
  private inFlight: boolean = false;
  private timer: number = -1;
  private healthTimer: number = -1;
  private nextRebindAtMs: number = 0;
  private fingerprint: string = '';
  private sampleSignature: string = '';
  private netConnection?: connection.NetConnection;
  private registering: boolean = false;
  private stage: number = 0;
  private rebindErrorCode: number = -1;
  private lastFailureSignature: string = '';
  private lastFailureAtMs: number = 0;
  private readonly record: (event: string, code: number, context?: DiagnosticEventContext) => void;

  constructor(record: (event: string, code: number, context?: DiagnosticEventContext) => void) {
    this.record = record;
  }

  start(): void {
    if (this.active) {
      return;
    }
    this.active = true;
    this.generation++;
    this.fingerprint = '';
    this.sampleSignature = '';
    this.changed();
    // System callbacks can be missed while suspended. Resample the default
    // physical network periodically without rebinding unchanged connections.
    this.healthTimer = setInterval(() => this.changed(), HEALTH_CHECK_MS);
  }

  stop(): void {
    this.active = false;
    this.generation++;
    if (this.healthTimer >= 0) {
      clearInterval(this.healthTimer);
      this.healthTimer = -1;
    }
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    const monitor: connection.NetConnection | undefined = this.netConnection;
    this.netConnection = undefined;
    if (monitor !== undefined) {
      this.unregister(monitor);
    }
  }

  private unregister(monitor: connection.NetConnection): void {
    try {
      monitor.unregister((error: BusinessError) => {
        if (error) {
          this.recordEvent('vpn_network_monitor_stop_failed', error.code ?? -1, 7);
        }
      });
    } catch (error) {
      this.recordEvent('vpn_network_monitor_stop_failed', (error as BusinessError).code ?? -1, 7);
    }
  }

  private register(): void {
    if (this.netConnection !== undefined || this.registering) {
      return;
    }
    const generation: number = this.generation;
    const monitor: connection.NetConnection = connection.createNetConnection();
    const changed = (event: string): void => {
      if (this.active && this.generation === generation) {
        this.changed();
        this.recordEvent('vpn_network_callback_' + event, 0, 0);
      }
    };
    monitor.on('netAvailable', () => changed('available'));
    monitor.on('netLost', () => changed('lost'));
    monitor.on('netUnavailable', () => changed('unavailable'));
    monitor.on('netCapabilitiesChange', () => changed('capabilities'));
    monitor.on('netConnectionPropertiesChange', () => changed('properties'));
    this.registering = true;
    try {
      monitor.register((error: BusinessError): void => {
        this.registering = false;
        if (!this.active || this.generation !== generation) {
          this.unregister(monitor);
          return;
        }
        if (error) {
          this.recordEvent('vpn_network_monitor_failed', error.code ?? -1, 6, 0, RETRY_MS);
          this.schedule(RETRY_MS);
          return;
        }
        this.netConnection = monitor;
        this.recordEvent('vpn_network_monitor_started', 0, 6);
        this.changed();
      });
    } catch (error) {
      this.registering = false;
      throw error as Error;
    }
  }

  private changed(): void {
    if (!this.active) {
      return;
    }
    this.revision++;
    this.schedule(SETTLE_MS);
  }

  private schedule(delayMs: number): void {
    if (!this.active || this.timer >= 0) {
      return;
    }
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.refresh();
    }, Math.max(delayMs, this.nextRebindAtMs - Date.now()));
  }

  private async readDefaultNetwork(): Promise<PhysicalNetwork> {
    // getDefaultNet excludes VPN networks. Never select an interface by name
    // priority or from whichever bearer happened to send the latest callback.
    this.stage = 1;
    const net: connection.NetHandle = await connection.getDefaultNet();
    if (net.netId === 0) {
      return { interfaceName: '', fingerprint: 'offline', bearer: 'offline',
        bearerMask: 0, capabilityMask: 0, mtu: 0, addressFamilyMask: 0 };
    }
    this.stage = 2;
    const props: connection.ConnectionProperties = await connection.getConnectionProperties(net);
    this.stage = 3;
    const capabilities: connection.NetCapabilities = await connection.getNetCapabilities(net);
    this.stage = 4;
    const current: connection.NetHandle = await connection.getDefaultNet();
    if (net.netId !== current.netId || props.interfaceName.length === 0) {
      throw new Error('default network changed while sampling');
    }
    const addresses: string[] = (props.linkAddresses ?? []).map((link: connection.LinkAddress) =>
      `${link.address.address}/${link.prefixLength}`).sort();
    const dns: string[] = (props.dnses ?? []).map((address: connection.NetAddress) => address.address).sort();
    const bearer: string = capabilities.bearerTypes.includes(connection.NetBearType.BEARER_CELLULAR) ?
      'cellular' : capabilities.bearerTypes.includes(connection.NetBearType.BEARER_WIFI) ? 'wifi' : 'other';
    const bearers: number[] = capabilities.bearerTypes.slice().sort((left: number, right: number): number => left - right);
    const bearerMask: number = VpnNetworkMonitor.mask(bearers);
    const capabilityMask: number = VpnNetworkMonitor.mask(capabilities.networkCap ?? []);
    const mtu: number = Number.isSafeInteger(props.mtu) ? props.mtu : -1;
    let addressFamilyMask: number = 0;
    for (const address of addresses) addressFamilyMask |= address.includes(':') ? 2 : 1;
    // Kept in memory only: endpoint addresses and DNS are never diagnostic text.
    return {
      interfaceName: props.interfaceName,
      bearer: bearer,
      bearerMask: bearerMask, capabilityMask: capabilityMask, mtu: mtu, addressFamilyMask: addressFamilyMask,
      fingerprint: `${net.netId}|${props.interfaceName}|${addresses.join(',')}|${dns.join(',')}|${bearers.join(',')}|${mtu}`
    };
  }

  private async refresh(): Promise<void> {
    if (!this.active || this.inFlight) {
      return;
    }
    this.inFlight = true;
    const generation: number = this.generation;
    const revision: number = this.revision;
    const startedAtMs: number = Date.now();
    let retry: boolean = false;
    try {
      this.stage = 6;
      this.register();
      const network: PhysicalNetwork = await this.readDefaultNetwork();
      if (!this.active || generation !== this.generation || revision !== this.revision) {
        return;
      }
      const sample: string = `${network.fingerprint}|${network.capabilityMask}`;
      if (sample !== this.sampleSignature) {
        this.sampleSignature = sample;
        this.recordEvent('vpn_network_sample_bearer_mask', network.bearerMask, 4);
        this.recordEvent('vpn_network_sample_capability_mask', network.capabilityMask, 4);
        this.recordEvent('vpn_network_sample_mtu', network.mtu, 4);
        this.recordEvent('vpn_network_sample_ip_families', network.addressFamilyMask, 4);
      }
      if (network.fingerprint !== this.fingerprint) {
        this.nextRebindAtMs = Date.now() + MIN_REBIND_MS;
        this.stage = 5;
        this.rebindErrorCode = -1;
        this.recordEvent('vpn_network_rebind_started_' + network.bearer, 0, 5);
        const result: string = await nativeBridge.backendNetworkChangedAsync(network.interfaceName);
        if (!this.active || generation !== this.generation) {
          return;
        }
        if (!result.startsWith('OK')) {
          const code: RegExpMatchArray | null = result.match(/(?:code|errno)\s*[=:]\s*(-?\d+)/i);
          if (code !== null && Number.isSafeInteger(Number(code[1]))) {
            this.rebindErrorCode = Number(code[1]);
          }
          throw new Error('network rebind failed');
        }
        this.fingerprint = network.fingerprint;
        this.recordEvent(network.interfaceName.length === 0 ? 'vpn_network_offline' :
          'vpn_network_rebound_' + network.bearer, 0, this.stage, Date.now() - startedAtMs);
      }
      this.appliedRevision = revision;
    } catch (error) {
      if (this.active && generation === this.generation && revision === this.revision) {
        this.recordEvent('vpn_network_refresh_failed', (error as BusinessError).code ??
          (this.stage === 5 ? this.rebindErrorCode : -1), this.stage, Date.now() - startedAtMs, RETRY_MS);
        retry = true;
      }
    } finally {
      this.inFlight = false;
      // A timer may have fired while the native worker was pending. Replay the
      // latest revision instead of losing the final Wi-Fi/cellular transition.
      if (this.active && (retry || this.netConnection === undefined || this.revision !== this.appliedRevision)) {
        this.schedule(retry || this.netConnection === undefined ? RETRY_MS : SETTLE_MS);
      }
    }
  }

  private recordEvent(event: string, code: number, stage: number,
    operationDurationMs: number = 0, retryDelayMs: number = 0): void {
    const failure: boolean = event.includes('failed');
    const signature: string = event + ':' + code + ':' + stage;
    if (failure && signature === this.lastFailureSignature && Date.now() - this.lastFailureAtMs < 30000) {
      return;
    }
    if (failure) {
      this.lastFailureSignature = signature;
      this.lastFailureAtMs = Date.now();
    } else {
      this.lastFailureSignature = '';
    }
    try {
      this.record(event, code, {
        networkGeneration: this.generation, networkRevision: this.revision,
        appliedRevision: this.appliedRevision, networkInFlight: this.inFlight,
        networkStage: stage, operationDurationMs: operationDurationMs, retryDelayMs: retryDelayMs
      });
    } catch (_error) {}
  }

  private static mask(values: number[]): number {
    let result: number = 0;
    for (const value of values) {
      if (Number.isInteger(value) && value >= 0 && value < 31) result |= 1 << value;
    }
    return result;
  }
}
