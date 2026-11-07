import { fileIo } from '@kit.CoreFileKit';

/**
 * App-level DNS override for the HarmonyOS VPN configuration.
 *
 * HarmonyOS applies VpnConfig.dnsAddresses to apps proxied by the VPN, so a
 * single primary/secondary pair covers the common "use my own resolver" case
 * without intercepting DNS packets inside the tunnel.
 */
export interface DnsSettings {
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
    if (raw === undefined || raw === null) {
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
    return {
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
    const temporaryPath: string = `${path}.${Date.now()}.tmp`;
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(temporaryPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, JSON.stringify(normalized));
      fileIo.closeSync(file);
      file = undefined;
      fileIo.renameSync(temporaryPath, path);
      return normalized;
    } catch (_error) {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (_closeError) {
        }
      }
      try {
        if (fileIo.accessSync(temporaryPath)) {
          fileIo.unlinkSync(temporaryPath);
        }
      } catch (_cleanupError) {
      }
      return undefined;
    }
  }

  /**
   * Filters DNS servers by the address families accepted by the VPN config.
   * An IPv6 resolver is only useful when the tunnel also has an IPv6 address.
   */
  static vpnDnsAddresses(settings: DnsSettings, ipv6Accepted: boolean): string[] {
    if (!settings.enabled) {
      return [];
    }
    const addresses: string[] = [];
    DnsSettingsStore.appendAddress(settings.primary, ipv6Accepted, addresses);
    DnsSettingsStore.appendAddress(settings.secondary, ipv6Accepted, addresses);
    return addresses;
  }

  static vpnSearchDomains(settings: DnsSettings): string[] {
    return settings.enabled ? settings.searchDomains.slice() : [];
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
    return DnsSettingsStore.isIPv4(value) || DnsSettingsStore.isIPv6(value);
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

  private static appendAddress(address: string, ipv6Accepted: boolean,
    addresses: string[]): void {
    if (address.length === 0 || addresses.includes(address)) {
      return;
    }
    const isIPv6: boolean = address.includes(':');
    if (isIPv6 && !ipv6Accepted) {
      return;
    }
    addresses.push(address);
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

  private static isIPv6(value: string): boolean {
    if (!value.includes(':') || value.includes('%') || value.includes('[') || value.includes(']')) {
      return false;
    }
    const compressionIndex: number = value.indexOf('::');
    if (compressionIndex >= 0 && value.indexOf('::', compressionIndex + 2) >= 0) {
      return false;
    }
    let left: string = value;
    let right: string = '';
    let compressed: boolean = false;
    if (compressionIndex >= 0) {
      compressed = true;
      left = value.substring(0, compressionIndex);
      right = value.substring(compressionIndex + 2);
    }
    const leftGroups: number = DnsSettingsStore.countIPv6Groups(left);
    const rightGroups: number = DnsSettingsStore.countIPv6Groups(right);
    if (leftGroups < 0 || rightGroups < 0) {
      return false;
    }
    if (compressed) {
      return leftGroups + rightGroups < 8;
    }
    return leftGroups === 8;
  }

  /**
   * Returns the number of 16-bit groups in a colon-separated IPv6 fragment, or
   * -1 when a group is malformed. An embedded IPv4 tail counts as two groups.
   */
  private static countIPv6Groups(fragment: string): number {
    if (fragment.length === 0) {
      return 0;
    }
    const groups: string[] = fragment.split(':');
    let count: number = 0;
    for (let index: number = 0; index < groups.length; index++) {
      const group: string = groups[index];
      if (group.length === 0) {
        return -1;
      }
      if (group.includes('.')) {
        if (index !== groups.length - 1 || !DnsSettingsStore.isIPv4(group)) {
          return -1;
        }
        count += 2;
        continue;
      }
      if (group.length > 4) {
        return -1;
      }
      for (let charIndex: number = 0; charIndex < group.length; charIndex++) {
        const code: number = group.charCodeAt(charIndex);
        const isDigit: boolean = code >= 48 && code <= 57;
        const isHexLower: boolean = code >= 97 && code <= 102;
        const isHexUpper: boolean = code >= 65 && code <= 70;
        if (!isDigit && !isHexLower && !isHexUpper) {
          return -1;
        }
      }
      count++;
    }
    return count;
  }

  private static path(filesDir: string): string {
    return `${filesDir}/${DnsSettingsStore.FILE_NAME}`;
  }
}
