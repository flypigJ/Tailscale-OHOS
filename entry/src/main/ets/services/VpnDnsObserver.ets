// This owner runs only in the VPN Extension. Raw policy remains in memory;
// publishing exposes counts, never resolver addresses or private search domains.
export interface TailnetDnsResolver {
  Addr?: string;
  BootstrapResolution?: string[];
  UseWithExitNode?: boolean;
}

export interface TailnetDnsPolicy {
  Resolvers?: TailnetDnsResolver[];
  FallbackResolvers?: TailnetDnsResolver[];
  Routes?: Record<string, TailnetDnsResolver[] | null>;
  Domains?: string[];
  Proxied?: boolean;
}

export interface TailnetDnsSnapshot {
  schemaVersion: number;
  session: string;
  revision: number;
  state: string;
  config: TailnetDnsPolicy | null;
}

export interface VpnDnsObservationSummary {
  schemaVersion: number;
  state: string;
  revision: number;
  magicDns: boolean;
  resolverCount: number;
  fallbackResolverCount: number;
  splitDomainCount: number;
  searchDomainCount: number;
  systemDnsApplied: boolean;
}

export class VpnDnsObserver {
  private readonly query: () => Promise<string>;
  private readonly publish: (summary: VpnDnsObservationSummary) => void;
  private readonly isSystemDnsApplied?: () => boolean;
  private epoch: number = 0;
  private active: boolean = false;
  private busy: boolean = false;
  private nextPollMs: number = 0;
  private session: string = '';
  private revision: number = 0;
  private snapshotText: string = '';

  constructor(query: () => Promise<string>, publish: (summary: VpnDnsObservationSummary) => void,
    isSystemDnsApplied?: () => boolean) {
    this.query = query;
    this.publish = publish;
    this.isSystemDnsApplied = isSystemDnsApplied;
  }

  start(): void {
    this.epoch++;
    this.active = true;
    this.busy = false;
    this.nextPollMs = 0;
    this.session = '';
    this.revision = 0;
    this.snapshotText = '';
    this.emit('pending');
    void this.refresh();
  }

  stop(): void {
    this.epoch++;
    this.active = false;
    this.busy = false;
    this.session = '';
    this.revision = 0;
    this.snapshotText = '';
    this.emit('stopped');
  }

  // Return a copy; callers cannot mutate the owner's current policy.
  current(): TailnetDnsSnapshot | undefined {
    return this.snapshotText.length > 0 ? JSON.parse(this.snapshotText) as TailnetDnsSnapshot : undefined;
  }

  republish(): void {
    if (this.active && this.snapshotText.length > 0) {
      this.emit('ready');
    }
  }

  async refresh(): Promise<void> {
    if (!this.active || this.busy || Date.now() < this.nextPollMs) return;
    const epoch: number = this.epoch;
    this.busy = true;
    this.nextPollMs = Date.now() + 5000;
    try {
      const text: string = await this.query();
      if (!this.active || epoch !== this.epoch) return;
      if (text.length > 256 * 1024 + 1024) throw new Error('DNS snapshot capacity exceeded');
      const snapshot: TailnetDnsSnapshot = JSON.parse(text) as TailnetDnsSnapshot;
      if (!snapshot || snapshot.schemaVersion !== 1) throw new Error('Invalid DNS snapshot');
      if (snapshot.state === 'stale') return;
      if (typeof snapshot.session !== 'string' || !/^[A-Za-z0-9]{16,64}$/.test(snapshot.session) ||
        !Number.isSafeInteger(snapshot.revision) || snapshot.revision <= 0) {
        throw new Error('DNS session unavailable');
      }
      if (this.session.length > 0 && this.session !== snapshot.session) {
        this.snapshotText = '';
        this.emit('session_changed');
        return;
      }
      if (snapshot.revision < this.revision) return;
      if (snapshot.state !== 'ready' && snapshot.state !== 'unavailable') throw new Error('Invalid DNS state');
      if (snapshot.state === 'ready' && !this.validPolicy(snapshot.config)) throw new Error('Invalid DNS policy');
      this.session = snapshot.session;
      this.revision = snapshot.revision;
      this.snapshotText = snapshot.state === 'ready' ? text : '';
      this.emit(snapshot.state);
    } catch (_error) {
      if (this.active && epoch === this.epoch) {
        this.snapshotText = '';
        this.emit('unavailable');
      }
    } finally {
      if (epoch === this.epoch) this.busy = false;
    }
  }

  private validResolvers(resolvers?: TailnetDnsResolver[]): boolean {
    return resolvers === undefined || (Array.isArray(resolvers) && resolvers.length <= 64 &&
      resolvers.every((resolver: TailnetDnsResolver) => resolver !== null &&
        typeof resolver.Addr === 'string' && resolver.Addr.length > 0 && resolver.Addr.length <= 2048 &&
        (resolver.UseWithExitNode === undefined || typeof resolver.UseWithExitNode === 'boolean') &&
        (resolver.BootstrapResolution === undefined || (Array.isArray(resolver.BootstrapResolution) &&
          resolver.BootstrapResolution.length <= 64 && resolver.BootstrapResolution.every((ip: string) =>
            typeof ip === 'string' && ip.length > 0 && ip.length <= 64)))));
  }

  private validPolicy(policy: TailnetDnsPolicy | null): boolean {
    if (!policy || typeof policy !== 'object' || Array.isArray(policy)) return false;
    if (!this.validResolvers(policy.Resolvers) || !this.validResolvers(policy.FallbackResolvers)) return false;
    if (policy.Proxied !== undefined && typeof policy.Proxied !== 'boolean') return false;
    if (policy.Domains !== undefined && (!Array.isArray(policy.Domains) || policy.Domains.length > 256 ||
      !policy.Domains.every((domain: string) => typeof domain === 'string' && domain.length > 0 && domain.length <= 253))) return false;
    if (policy.Routes !== undefined) {
      if (!policy.Routes || typeof policy.Routes !== 'object' || Array.isArray(policy.Routes)) return false;
      const domains: string[] = Object.keys(policy.Routes);
      if (domains.length > 4096 || !domains.every((domain: string) => domain.length <= 254 &&
        (policy.Routes![domain] === null ||
          (Array.isArray(policy.Routes![domain]) && this.validResolvers(policy.Routes![domain]!))))) return false;
    }
    return true;
  }

  private emit(state: string): void {
    const policy: TailnetDnsPolicy | null | undefined = this.current()?.config;
    let applied: boolean = false;
    if (state === 'ready' && this.isSystemDnsApplied !== undefined) {
      try {
        applied = Boolean(this.isSystemDnsApplied());
      } catch (_error) {
        applied = false;
      }
    }
    const summary: VpnDnsObservationSummary = {
      schemaVersion: 1, state: state, revision: this.revision,
      magicDns: policy?.Proxied ?? false,
      resolverCount: policy?.Resolvers?.length ?? 0,
      fallbackResolverCount: policy?.FallbackResolvers?.length ?? 0,
      splitDomainCount: policy?.Routes ? Object.keys(policy.Routes).length : 0,
      searchDomainCount: policy?.Domains?.length ?? 0,
      systemDnsApplied: applied
    };
    // Observation I/O must never escape into VPN heartbeat or stop handling.
    try { this.publish(summary); } catch (_error) {}
  }
}
