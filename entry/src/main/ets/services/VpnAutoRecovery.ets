import { fileIo } from '@kit.CoreFileKit';
import { connection, vpnExtension } from '@kit.NetworkKit';
import { AtomicFileStore } from './AtomicFileStore';

export interface VpnConnectionIntent {
  desired: boolean;
  requestedAtMs: number;
  connectedAtMs: number;
}

/** An explicit user intent, not a persisted copy of the connected indicator. */
export class VpnAutoRecovery {
  private intent: VpnConnectionIntent = { desired: false, requestedAtMs: 0, connectedAtMs: 0 };
  private missingSinceMs: number = 0;
  private stableSinceMs: number = 0;
  private nextAttemptMs: number = 0;
  private attempts: number = 0;
  // Keep the native observer alive for the UI process. Unsubscribe callbacks
  // without repeatedly collecting and recreating the native binding.
  private static authorizationObserver?: vpnExtension.VpnObserver;
  private static authorizationOwner?: VpnAutoRecovery;
  private observerGeneration: number = 0;

  restore(filesDir: string): void {
    try {
      const path: string = `${filesDir}/vpn-connect-intent.json`;
      if (fileIo.statSync(path).size > 1024) return;
      const value: VpnConnectionIntent = JSON.parse(fileIo.readTextSync(path)) as VpnConnectionIntent;
      if (value.desired === true && Number.isSafeInteger(value.requestedAtMs) &&
        value.requestedAtMs > 0 && value.requestedAtMs <= Date.now() &&
        Number.isSafeInteger(value.connectedAtMs) && value.connectedAtMs >= value.requestedAtMs &&
        value.connectedAtMs <= Date.now()) {
        this.intent = value;
      }
    } catch (_error) { /* Missing/invalid intent never opts the user in. */ }
  }

  static permitsStart(filesDir: string, token: number): boolean {
    try {
      const path: string = `${filesDir}/vpn-connect-intent.json`;
      if (fileIo.statSync(path).size > 1024) return false;
      const value: VpnConnectionIntent = JSON.parse(fileIo.readTextSync(path)) as VpnConnectionIntent;
      return value.desired === true && value.requestedAtMs === token && token > 0 && token <= Date.now();
    } catch (_error) { return false; }
  }

  request(now: number): void {
    this.cancel();
    this.intent = { desired: true, requestedAtMs: Math.max(now, this.intent.requestedAtMs + 1), connectedAtMs: 0 };
  }

  cancel(): void {
    this.stopObservingAuthorization();
    this.intent.desired = false;
    this.intent.connectedAtMs = 0;
    this.missingSinceMs = 0;
    this.stableSinceMs = 0;
    this.nextAttemptMs = 0;
    this.attempts = 0;
  }

  token(): number { return this.intent.requestedAtMs; }
  wanted(): boolean { return this.intent.desired; }
  armed(): boolean { return this.intent.desired && this.intent.connectedAtMs > 0; }
  current(token: number): boolean { return this.intent.desired && token === this.intent.requestedAtMs; }

  save(filesDir: string): boolean {
    const path: string = `${filesDir}/vpn-connect-intent.json`;
    return AtomicFileStore.writeAtomic(path, JSON.stringify(this.intent), {
      owner: 'vpn-intent',
      fsync: false
    });
  }

  connected(heartbeatMs: number, now: number): boolean {
    if (!this.wanted() || heartbeatMs < this.intent.requestedAtMs || heartbeatMs > now) return false;
    const changed: boolean = this.intent.connectedAtMs === 0;
    if (changed) this.intent.connectedAtMs = heartbeatMs;
    this.missingSinceMs = 0;
    if (this.stableSinceMs === 0) this.stableSinceMs = now;
    // A flapping tunnel must not reset its retry budget on a single heartbeat.
    if (now - this.stableSinceMs >= 30000) { this.attempts = 0; this.nextAttemptMs = 0; }
    return changed;
  }

  takeAttempt(heartbeatMs: number, systemVpnAbsent: boolean, now: number): boolean {
    this.stableSinceMs = 0;
    if (!this.wanted() || this.intent.connectedAtMs === 0 || !systemVpnAbsent ||
      heartbeatMs > now || (heartbeatMs > 0 && now - heartbeatMs < 15000)) {
      this.missingSinceMs = 0;
      return false;
    }
    if (this.missingSinceMs === 0) this.missingSinceMs = now;
    if (now - this.missingSinceMs < 15000 || now < this.nextAttemptMs || this.attempts >= 5) return false;
    const delays: number[] = [15000, 30000, 60000, 120000, 300000];
    this.attempts++;
    this.nextAttemptMs = now + delays[Math.min(this.attempts, delays.length - 1)];
    return true;
  }

  /** Unknown capability queries are not evidence of a dead VPN. Never stop a
   * healthy extension just because ArkTS or a status file was delayed. */
  static async systemVpnAbsent(): Promise<boolean> {
    const inspect = async (): Promise<boolean> => {
      const nets: connection.NetHandle[] = await connection.getAllNets();
      if (nets.length === 0 || nets.length > 32) return false;
      for (const net of nets) {
        const caps: connection.NetCapabilities = await connection.getNetCapabilities(net);
        if (caps.bearerTypes.length === 0 ||
          caps.bearerTypes.includes(connection.NetBearType.BEARER_VPN)) return false;
      }
      return true;
    };
    let timer: number = -1;
    try {
      return await Promise.race([inspect(), new Promise<boolean>((resolve: (value: boolean) => void) => {
        timer = setTimeout(() => resolve(false), 2000);
      })]);
    } catch (_error) { return false; }
    finally { if (timer >= 0) clearTimeout(timer); }
  }

  watchAuthorization(onDenied: () => void): void {
    this.stopObservingAuthorization();
    const generation: number = this.observerGeneration;
    try {
      if (VpnAutoRecovery.authorizationObserver === undefined) {
        VpnAutoRecovery.authorizationObserver = vpnExtension.createVpnObserver();
      }
      const observer: vpnExtension.VpnObserver = VpnAutoRecovery.authorizationObserver;
      VpnAutoRecovery.authorizationOwner?.stopObservingAuthorization();
      VpnAutoRecovery.authorizationOwner = this;
      observer.onAuthorizationResult((allowed: boolean): void => {
        if (VpnAutoRecovery.authorizationOwner === this && generation === this.observerGeneration && !allowed) onDenied();
      });
    } catch (_error) {
      if (VpnAutoRecovery.authorizationOwner === this) VpnAutoRecovery.authorizationOwner = undefined;
      // System authorization still gates the start API.
    }
  }

  stopObservingAuthorization(): void {
    this.observerGeneration++;
    if (VpnAutoRecovery.authorizationOwner !== this) return;
    VpnAutoRecovery.authorizationOwner = undefined;
    try { VpnAutoRecovery.authorizationObserver?.offAuthorizationResult(); } catch (_error) {}
  }
}
