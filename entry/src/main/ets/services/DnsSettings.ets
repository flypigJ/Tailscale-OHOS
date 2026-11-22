import { fileIo } from '@kit.CoreFileKit';
import { AtomicFileStore } from './AtomicFileStore';

/**
 * Explicit local default upstreams, adapted from awayings' PR #21.
 * The engine combines these with Tailnet split/MagicDNS policy and compiles
 * the sole platform DNS plan; this store never writes VpnConfig directly.
 */
export interface DnsSettings {
  schemaVersion?: number;
  enabled: boolean;
  primary: string;
  secondary: string;
  searchDomains: string[];
}

export const MAX_DNS_SEARCH_DOMAINS: number = 8;
const MAX_DNS_ADDRESS_LENGTH: number = 45;
const MAX_DNS_SEARCH_DOMAIN_LENGTH: number = 253;
const MAX_DNS_LABEL_LENGTH: number = 63;

/** Persists and validates the user's custom DNS settings. */
export class DnsSettingsStore {
  private static readonly FILE_NAME: string = 'dns-settings.json';

  static defaults(): DnsSettings {
    return {
      schemaVersion: 1,
      enabled: false,
      primary: '',
      secondary: '',
      searchDomains: []
    };
  }

  static load(filesDir: string): DnsSettings {
    const path: string = DnsSettingsStore.path(filesDir);
    try {
      if (!fileIo.accessSync(path)) {
        return DnsSettingsStore.defaults();
      }
      if (fileIo.statSync(path).size > 8192) throw new Error('DNS settings capacity');
      const parsed: DnsSettings = JSON.parse(fileIo.readTextSync(path)) as DnsSettings;
      const normalized: DnsSettings | undefined = DnsSettingsStore.normalize(parsed);
      return normalized ?? DnsSettingsStore.defaults();
    } catch (_error) {
      return DnsSettingsStore.defaults();
    }
  }

  /**
   * Returns undefined when the persisted payload is structurally invalid. A
   * saved-but-disabled configuration keeps its addresses so re-enabling it from
   * the UI restores the previous values.
   */
  static normalize(raw: DnsSettings | undefined): DnsSettings | undefined {
    if (raw === undefined || raw === null ||
      (raw.schemaVersion !== undefined && raw.schemaVersion !== 1) || typeof raw.enabled !== 'boolean') {
      return undefined;
    }
    const enabled: boolean = raw.enabled === true;
    const primary: string = typeof raw.primary === 'string' ? raw.primary.trim() : '';
    const secondary: string = typeof raw.secondary === 'string' ? raw.secondary.trim() : '';
    if (primary.length > 0 && !DnsSettingsStore.isValidAddress(primary)) {
      return undefined;
    }
    if (secondary.length > 0 && !DnsSettingsStore.isValidAddress(secondary)) {
      return undefined;
    }
    if (enabled && primary.length === 0) {
      return undefined;
    }
    if (raw.searchDomains !== undefined && (!Array.isArray(raw.searchDomains) ||
      !raw.searchDomains.every((domain: string) => typeof domain === 'string') ||
      !DnsSettingsStore.isValidSearchDomains(raw.searchDomains))) return undefined;
    return {
      schemaVersion: 1,
      enabled: enabled,
      primary: primary,
      secondary: secondary,
      searchDomains: DnsSettingsStore.normalizeSearchDomains(raw.searchDomains)
    };
  }

  static save(filesDir: string, settings: DnsSettings): DnsSettings | undefined {
    const normalized: DnsSettings | undefined = DnsSettingsStore.normalize(settings);
    if (normalized === undefined) {
      return undefined;
    }
    const path: string = DnsSettingsStore.path(filesDir);
    return AtomicFileStore.writeAtomic(path, JSON.stringify(normalized), {
      owner: 'dns',
      fsync: true
    }) ? normalized : undefined;
  }

  static parseSearchDomains(raw: string): string[] {
    const values: string[] = raw.split(',');
    const domains: string[] = [];
    for (const value of values) {
      const normalized: string = DnsSettingsStore.normalizeSearchDomain(value);
      if (normalized.length > 0 && !domains.includes(normalized)) {
        domains.push(normalized);
      }
    }
    return domains.slice(0, MAX_DNS_SEARCH_DOMAINS);
  }

  static formatSearchDomains(domains: string[]): string {
    return domains.join(', ');
  }

  static isValidSearchDomains(domains: string[]): boolean {
    if (domains.length > MAX_DNS_SEARCH_DOMAINS) {
      return false;
    }
    for (const domain of domains) {
      if (!DnsSettingsStore.isValidSearchDomain(domain)) {
        return false;
      }
    }
    return true;
  }

  static isValidAddress(raw: string): boolean {
    const value: string = raw.trim();
    if (value.length === 0 || value.length > MAX_DNS_ADDRESS_LENGTH) {
      return false;
    }
    if (DnsSettingsStore.isIPv4(value)) {
      const octets: number[] = value.split('.').map((part: string) => Number(part));
      return octets[0] !== 0 && octets[0] !== 127 && octets[0] < 224 &&
        value !== '100.100.100.100' && value !== '169.254.0.0' &&
        !(octets[0] === 169 && octets[1] === 254);
    }
    const groups: number[] | undefined = DnsSettingsStore.ipv6Groups(value);
    if (groups === undefined) return false;
    if (groups[0] === 0xff00 || (groups[0] & 0xff00) === 0xff00 ||
      (groups[0] & 0xffc0) === 0xfe80) return false;
    if (groups.slice(0, 6).every((group: number) => group === 0) ||
      (groups.slice(0, 5).every((group: number) => group === 0) && groups[5] === 0xffff)) return false;
    return groups.join(',') !== [0xfd7a, 0x115c, 0xa1e0, 0, 0, 0, 0, 0x53].join(',');
  }

  static isValidSearchDomain(raw: string): boolean {
    return DnsSettingsStore.normalizeSearchDomain(raw).length > 0;
  }

  private static normalizeSearchDomains(raw: string[] | undefined): string[] {
    if (raw === undefined || raw === null || !Array.isArray(raw)) {
      return [];
    }
    const domains: string[] = [];
    for (const value of raw) {
      if (typeof value !== 'string') {
        continue;
      }
      const normalized: string = DnsSettingsStore.normalizeSearchDomain(value);
      if (normalized.length > 0 && !domains.includes(normalized)) {
        domains.push(normalized);
      }
      if (domains.length === MAX_DNS_SEARCH_DOMAINS) {
        break;
      }
    }
    return domains;
  }

  private static normalizeSearchDomain(raw: string): string {
    let value: string = raw.trim().toLowerCase();
    while (value.startsWith('.')) {
      value = value.substring(1);
    }
    while (value.endsWith('.')) {
      value = value.substring(0, value.length - 1);
    }
    if (value.length === 0 || value.length > MAX_DNS_SEARCH_DOMAIN_LENGTH) {
      return '';
    }
    const labels: string[] = value.split('.');
    for (const label of labels) {
      if (label.length === 0 || label.length > MAX_DNS_LABEL_LENGTH) {
        return '';
      }
      if (label.startsWith('-') || label.endsWith('-')) {
        return '';
      }
      for (let index: number = 0; index < label.length; index++) {
        const code: number = label.charCodeAt(index);
        const isDigit: boolean = code >= 48 && code <= 57;
        const isLower: boolean = code >= 97 && code <= 122;
        if (!isDigit && !isLower && code !== 45) {
          return '';
        }
      }
    }
    return value;
  }

  private static isIPv4(value: string): boolean {
    const parts: string[] = value.split('.');
    if (parts.length !== 4) {
      return false;
    }
    for (const part of parts) {
      if (part.length === 0 || part.length > 3) {
        return false;
      }
      for (let index: number = 0; index < part.length; index++) {
        const code: number = part.charCodeAt(index);
        if (code < 48 || code > 57) {
          return false;
        }
      }
      if (part.length > 1 && part.charCodeAt(0) === 48) {
        return false;
      }
      const octet: number = Number(part);
      if (octet > 255) {
        return false;
      }
    }
    return true;
  }

  // Parse the complete address so an embedded IPv4 tail cannot precede ::.
  private static ipv6Groups(raw: string): number[] | undefined {
    let value: string = raw.toLowerCase();
    if (!value.includes(':') || /[^0-9a-f:.]/.test(value)) return undefined;
    if (value.includes('.')) {
      const split: number = value.lastIndexOf(':');
      const tail: string = value.substring(split + 1);
      if (!DnsSettingsStore.isIPv4(tail)) return undefined;
      const bytes: number[] = tail.split('.').map((part: string) => Number(part));
      value = value.substring(0, split + 1) + ((bytes[0] << 8) | bytes[1]).toString(16) +
        ':' + ((bytes[2] << 8) | bytes[3]).toString(16);
    }
    const halves: string[] = value.split('::');
    if (halves.length > 2) return undefined;
    const left: string[] = halves[0].length > 0 ? halves[0].split(':') : [];
    const right: string[] = halves.length === 2 && halves[1].length > 0 ? halves[1].split(':') : [];
    if (![...left, ...right].every((part: string) => /^[0-9a-f]{1,4}$/.test(part))) return undefined;
    const count: number = left.length + right.length;
    if ((halves.length === 1 && count !== 8) || (halves.length === 2 && count >= 8)) return undefined;
    const zeros: number[] = [];
    for (let i: number = count; i < 8; i++) zeros.push(0);
    return [...left.map((part: string) => parseInt(part, 16)), ...zeros,
      ...right.map((part: string) => parseInt(part, 16))];
  }

  // The engine reaches upstreams through its dialer, independently of the
  // TUN's address families. It always projects Quad100 to the platform.
  static upstreams(settings: DnsSettings): string[] {
    if (!settings.enabled) return [];
    const values: string[] = [settings.primary, settings.secondary].filter((value: string) => value.length > 0);
    return values.filter((value: string, index: number) => values.indexOf(value) === index);
  }

  private static path(filesDir: string): string {
    return `${filesDir}/${DnsSettingsStore.FILE_NAME}`;
  }
}
