import nativeBridge from 'libtailscale_ohos.so';

export interface DnsSystemPlan {
  schemaVersion: number;
  session: string;
  revision: number;
  state: string;
  dnsAddresses: string[];
  searchDomains: string[];
}

interface DnsRuntimeRequest {
  operation: string;
  sequence: number;
  enabled: boolean;
  session: string;
  resolvers: string[];
  customResolvers?: string[];
  searchDomains?: string[];
}

export class DnsRuntimeService {
  private static sequence: number = 0;

  static async stage(enabled: boolean, resolvers: string[], customResolvers: string[] = [],
    searchDomains: string[] = []): Promise<void> {
    DnsRuntimeService.sequence = Math.max(Date.now(), DnsRuntimeService.sequence + 1);
    const request: DnsRuntimeRequest = { operation: 'stage', sequence: DnsRuntimeService.sequence,
      enabled: enabled, session: '', resolvers: resolvers,
      customResolvers: customResolvers, searchDomains: searchDomains };
    const result: string = await nativeBridge.backendDnsRuntimeAsync(JSON.stringify(request));
    if (!result.startsWith('OK')) throw new Error('DNS startup unavailable');
  }

  static async update(session: string, resolvers: string[]): Promise<void> {
    const request: DnsRuntimeRequest = { operation: 'update', sequence: 0,
      enabled: true, session: session, resolvers: resolvers };
    const result: string = await nativeBridge.backendDnsRuntimeAsync(JSON.stringify(request));
    if (!result.startsWith('OK')) throw new Error('DNS update unavailable');
  }

  static async read(): Promise<DnsSystemPlan> {
    const text: string = await nativeBridge.backendDnsRuntimeAsync('{"operation":"snapshot"}');
    if (text.length > 100 * 1024) throw new Error('DNS plan capacity exceeded');
    const plan: DnsSystemPlan = JSON.parse(text) as DnsSystemPlan;
    if (!plan || plan.schemaVersion !== 1 || typeof plan.session !== 'string' ||
      !/^[A-Za-z0-9]{16,64}$/.test(plan.session) || !Number.isSafeInteger(plan.revision) ||
      !Array.isArray(plan.dnsAddresses) || plan.dnsAddresses.length > 64 ||
      !plan.dnsAddresses.every((address: string) => typeof address === 'string' && address.length > 0 && address.length <= 128) ||
      !Array.isArray(plan.searchDomains) || plan.searchDomains.length > 256 ||
      !plan.searchDomains.every((domain: string) => typeof domain === 'string' && domain.length > 0 && domain.length <= 253)) {
      throw new Error('Invalid DNS system plan');
    }
    return plan;
  }

  static sameConfiguration(left: DnsSystemPlan, right: DnsSystemPlan): boolean {
    return JSON.stringify(left.dnsAddresses) === JSON.stringify(right.dnsAddresses) &&
      JSON.stringify(left.searchDomains) === JSON.stringify(right.searchDomains);
  }
}
