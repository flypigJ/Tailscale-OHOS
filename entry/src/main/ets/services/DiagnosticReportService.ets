import { common } from '@kit.AbilityKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { deviceInfo, zlib } from '@kit.BasicServicesKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { systemShare } from '@kit.ShareKit';
import { DiagnosticEvent, DiagnosticEventStore } from './DiagnosticEventStore';
import { DiagnosticPrivacy } from './DiagnosticPrivacy';

const REPORT_PREFIX: string = 'TailscaleOHOS-Diagnostic-';
const REPORT_RETENTION_MS: number = 24 * 60 * 60 * 1000;
const VPN_CONFIG_SUMMARY_FILE_NAME: string = 'vpn-config-summary.txt';

export interface DiagnosticReportInput {
  appVersion: string;
  tailscaleVersion: string;
  nativeStatus: string;
  engineStatus: string;
  backendStatus: string;
  vpnStatus: string;
  peerCount: number;
  onlinePeerCount: number;
  exitNodeCount: number;
  exitNodeSelected: boolean;
  addressCount: number;
  signedIn: boolean;
  routeAll: boolean;
  exitNodeAllowLANAccess: boolean;
}

export interface DiagnosticReportResult {
  path: string;
  fileName: string;
  size: number;
}

interface DiagnosticCheck {
  state: string;
  code: number;
}

interface DiagnosticDevice {
  brand: string;
  model: string;
  productModel: string;
  deviceType: string;
  osFullName: string;
  displayVersion: string;
  sdkApiVersion: number;
  buildVersion: number;
}

interface DiagnosticApplication {
  appVersion: string;
  tailscaleVersion: string;
}

interface DiagnosticNetwork {
  signedIn: boolean;
  peerCount: number;
  onlinePeerCount: number;
  exitNodeCount: number;
  exitNodeSelected: boolean;
  assignedAddressCount: number;
  acceptSubnetRoutes: boolean;
  exitNodeAllowLANAccess: boolean;
}

interface DiagnosticStatusSet {
  nativeBridge: DiagnosticCheck;
  engine: DiagnosticCheck;
  backend: DiagnosticCheck;
  vpnExtension: DiagnosticCheck;
}

interface DiagnosticVpnConfig {
  available: boolean;
  addressCount: number;
  routeCount: number;
  hasIPv4Address: boolean;
  hasIPv6Address: boolean;
  hasTailnetIPv4: boolean;
  hasTailnetIPv6: boolean;
  hasDefaultIPv4: boolean;
  hasDefaultIPv6: boolean;
  ipv4Accepted: boolean;
  ipv6Accepted: boolean;
  mtu: number;
}

interface DiagnosticTunCounters {
  available: boolean;
  session: number;
  systemToEnginePackets: number;
  systemToEngineBytes: number;
  engineToSystemPackets: number;
  engineToSystemBytes: number;
  readErrors: number;
  writeErrors: number;
}

interface DiagnosticReportPrivacy {
  rawHiLogIncluded: boolean;
  rawBackendSnapshotIncluded: boolean;
  identityFieldsIncluded: boolean;
  networkAddressesIncluded: boolean;
}

interface DiagnosticReport {
  schemaVersion: number;
  generatedAt: string;
  device: DiagnosticDevice;
  application: DiagnosticApplication;
  network: DiagnosticNetwork;
  status: DiagnosticStatusSet;
  vpnConfig: DiagnosticVpnConfig;
  tunCounters: DiagnosticTunCounters;
  events: DiagnosticEvent[];
  privacy: DiagnosticReportPrivacy;
}

export class DiagnosticReportService {
  static async generate(context: common.UIAbilityContext,
    input: DiagnosticReportInput): Promise<DiagnosticReportResult> {
    DiagnosticReportService.cleanupExpiredReports(context.cacheDir);
    const generatedAt: Date = new Date();
    const stamp: string = DiagnosticReportService.fileStamp(generatedAt);
    const fileName: string = `${REPORT_PREFIX}${stamp}.zip`;
    const zipPath: string = `${context.cacheDir}/${fileName}`;
    const workDir: string = `${context.cacheDir}/diagnostic-report-${stamp}`;
    const summaryPath: string = `${workDir}/summary.txt`;
    const jsonPath: string = `${workDir}/report.json`;
    try {
      fileIo.mkdirSync(workDir, true);
      const report: DiagnosticReport = DiagnosticReportService.buildReport(context.filesDir, generatedAt, input);
      const summary: string = DiagnosticReportService.buildSummary(report);
      const reportJson: string = JSON.stringify(report, undefined, 2);
      if (DiagnosticPrivacy.exceedsByteLimit(summary, DiagnosticPrivacy.MAX_REPORT_SUMMARY_BYTES) ||
        DiagnosticPrivacy.exceedsByteLimit(reportJson, DiagnosticPrivacy.MAX_REPORT_JSON_BYTES)) {
        throw new Error('Diagnostic report capacity exceeded');
      }
      DiagnosticReportService.writeTextFile(summaryPath, summary);
      DiagnosticReportService.writeTextFile(jsonPath, reportJson);
      await zlib.compressFiles([summaryPath, jsonPath], zipPath, {
        level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION
      });
      DiagnosticReportService.removeWorkDirectory(workDir, summaryPath, jsonPath);
      return {
        path: zipPath,
        fileName: fileName,
        size: fileIo.statSync(zipPath).size
      };
    } catch (error) {
      DiagnosticReportService.removeWorkDirectory(workDir, summaryPath, jsonPath);
      try {
        if (fileIo.accessSync(zipPath)) {
          fileIo.unlinkSync(zipPath);
        }
      } catch (_cleanupError) {
        // A partial archive is never shared, even if cleanup is delayed by the file service.
      }
      throw new Error('Diagnostic report generation failed');
    }
  }

  static async share(context: common.UIAbilityContext, result: DiagnosticReportResult): Promise<void> {
    const sharedData: systemShare.SharedData = new systemShare.SharedData({
      utd: uniformTypeDescriptor.UniformDataType.FILE,
      uri: fileUri.getUriFromPath(result.path),
      title: result.fileName
    });
    const controller: systemShare.ShareController = new systemShare.ShareController(sharedData);
    await controller.show(context, {
      previewMode: systemShare.SharePreviewMode.DEFAULT,
      selectionMode: systemShare.SelectionMode.SINGLE
    });
  }

  private static buildReport(filesDir: string, generatedAt: Date,
    input: DiagnosticReportInput): DiagnosticReport {
    const model: string = DiagnosticReportService.deviceModel();
    return {
      schemaVersion: 2,
      generatedAt: generatedAt.toISOString(),
      device: {
        brand: DiagnosticReportService.safeLabel(deviceInfo.brand, 'unknown'),
        model: model,
        productModel: DiagnosticReportService.safeLabel(deviceInfo.productModel, model),
        deviceType: DiagnosticReportService.safeToken(deviceInfo.deviceType, 'unknown'),
        osFullName: DiagnosticReportService.safeLabel(deviceInfo.osFullName, 'unknown'),
        displayVersion: DiagnosticReportService.safeLabel(deviceInfo.displayVersion, 'unknown'),
        sdkApiVersion: deviceInfo.sdkApiVersion,
        buildVersion: deviceInfo.buildVersion
      },
      application: {
        appVersion: DiagnosticReportService.safeVersion(input.appVersion),
        tailscaleVersion: DiagnosticReportService.safeVersion(input.tailscaleVersion)
      },
      network: {
        signedIn: input.signedIn,
        peerCount: DiagnosticReportService.nonNegative(input.peerCount),
        onlinePeerCount: DiagnosticReportService.nonNegative(input.onlinePeerCount),
        exitNodeCount: DiagnosticReportService.nonNegative(input.exitNodeCount),
        exitNodeSelected: input.exitNodeSelected,
        assignedAddressCount: DiagnosticReportService.nonNegative(input.addressCount),
        acceptSubnetRoutes: input.routeAll,
        exitNodeAllowLANAccess: input.exitNodeAllowLANAccess
      },
      status: {
        nativeBridge: DiagnosticReportService.classifyStatus(input.nativeStatus),
        engine: DiagnosticReportService.classifyStatus(input.engineStatus),
        backend: DiagnosticReportService.classifyStatus(input.backendStatus),
        vpnExtension: DiagnosticReportService.classifyStatus(input.vpnStatus)
      },
      vpnConfig: DiagnosticReportService.readVpnConfig(filesDir),
      tunCounters: DiagnosticReportService.readTunCounters(input.vpnStatus),
      events: DiagnosticEventStore.load(filesDir),
      privacy: {
        rawHiLogIncluded: false,
        rawBackendSnapshotIncluded: false,
        identityFieldsIncluded: false,
        networkAddressesIncluded: false
      }
    };
  }

  private static classifyStatus(value: string): DiagnosticCheck {
    const normalized: string = value.toLowerCase();
    let state: string = 'unknown';
    if (normalized.includes('failed')) {
      state = 'failed';
    } else if (normalized.includes('state=running') || normalized.startsWith('ok')) {
      state = 'running';
    } else if (normalized.includes('needslogin') || normalized.includes('sign in')) {
      state = 'needs_login';
    } else if (normalized.includes('stopped') || normalized.includes('destroyed')) {
      state = 'stopped';
    } else if (normalized.includes('pending') || normalized.includes('starting') ||
      normalized.includes('requesting') || normalized.includes('initializ')) {
      state = 'pending';
    } else if (normalized.includes('ready') || normalized.includes('opened') ||
      normalized.includes('created')) {
      state = 'ready';
    }
    const codeMatch: RegExpMatchArray | null = value.match(/code=(-?\d+)/i);
    return {
      state: state,
      code: codeMatch === null ? 0 : Number(codeMatch[1])
    };
  }

  private static readVpnConfig(filesDir: string): DiagnosticVpnConfig {
    const unavailable: DiagnosticVpnConfig = {
      available: false,
      addressCount: 0,
      routeCount: 0,
      hasIPv4Address: false,
      hasIPv6Address: false,
      hasTailnetIPv4: false,
      hasTailnetIPv6: false,
      hasDefaultIPv4: false,
      hasDefaultIPv6: false,
      ipv4Accepted: false,
      ipv6Accepted: false,
      mtu: 0
    };
    try {
      const path: string = `${filesDir}/${VPN_CONFIG_SUMMARY_FILE_NAME}`;
      if (!fileIo.accessSync(path)) {
        return unavailable;
      }
      const summary: string = fileIo.readTextSync(path);
      if (summary.trim().length === 0) {
        return unavailable;
      }
      return {
        available: true,
        addressCount: DiagnosticReportService.statusNumber(summary, 'addressCount'),
        routeCount: DiagnosticReportService.statusNumber(summary, 'routeCount'),
        hasIPv4Address: DiagnosticReportService.statusBoolean(summary, 'hasIPv4Address'),
        hasIPv6Address: DiagnosticReportService.statusBoolean(summary, 'hasIPv6Address'),
        hasTailnetIPv4: DiagnosticReportService.statusBoolean(summary, 'hasTailnetIPv4'),
        hasTailnetIPv6: DiagnosticReportService.statusBoolean(summary, 'hasTailnetIPv6'),
        hasDefaultIPv4: DiagnosticReportService.statusBoolean(summary, 'hasDefaultIPv4'),
        hasDefaultIPv6: DiagnosticReportService.statusBoolean(summary, 'hasDefaultIPv6'),
        ipv4Accepted: DiagnosticReportService.statusBoolean(summary, 'ipv4Accepted'),
        ipv6Accepted: DiagnosticReportService.statusBoolean(summary, 'ipv6Accepted'),
        mtu: DiagnosticReportService.statusNumber(summary, 'mtu')
      };
    } catch (_error) {
      return unavailable;
    }
  }

  private static readTunCounters(status: string): DiagnosticTunCounters {
    return {
      available: DiagnosticReportService.hasStatusKey(status, 'trafficSession'),
      session: DiagnosticReportService.statusNumber(status, 'trafficSession'),
      systemToEnginePackets: DiagnosticReportService.statusNumber(status, 'tunRead'),
      systemToEngineBytes: DiagnosticReportService.statusNumber(status, 'txBytes'),
      engineToSystemPackets: DiagnosticReportService.statusNumber(status, 'tunWrite'),
      engineToSystemBytes: DiagnosticReportService.statusNumber(status, 'rxBytes'),
      readErrors: DiagnosticReportService.statusNumber(status, 'tunReadErrors'),
      writeErrors: DiagnosticReportService.statusNumber(status, 'tunWriteErrors')
    };
  }

  private static hasStatusKey(status: string, key: string): boolean {
    return new RegExp(`(?:^|\\|\\s*)${key}=`).test(status);
  }

  private static statusNumber(status: string, key: string): number {
    const match: RegExpMatchArray | null = status.match(
      new RegExp(`(?:^|\\|\\s*)${key}=(\\d+)`));
    return match === null ? 0 : DiagnosticReportService.nonNegative(Number(match[1]));
  }

  private static statusBoolean(status: string, key: string): boolean {
    const match: RegExpMatchArray | null = status.match(
      new RegExp(`(?:^|\\|\\s*)${key}=(true|false)`));
    return match !== null && match[1] === 'true';
  }

  private static buildSummary(report: DiagnosticReport): string {
    const lines: string[] = [
      'Tailscale OHOS Diagnostic Report',
      `Generated: ${report.generatedAt}`,
      '',
      'Device',
      `Brand: ${report.device.brand}`,
      `Model: ${report.device.model}`,
      `Product model: ${report.device.productModel}`,
      `Type: ${report.device.deviceType}`,
      `System: ${report.device.osFullName}`,
      `Display version: ${report.device.displayVersion}`,
      `API: ${report.device.sdkApiVersion}`,
      '',
      'Application',
      `App version: ${report.application.appVersion}`,
      `Tailscale core: ${report.application.tailscaleVersion}`,
      '',
      'Connection summary',
      `Signed in: ${report.network.signedIn}`,
      `Peers: ${report.network.onlinePeerCount} online / ${report.network.peerCount} total`,
      `Exit nodes available: ${report.network.exitNodeCount}`,
      `Exit node selected: ${report.network.exitNodeSelected}`,
      `Assigned address count: ${report.network.assignedAddressCount}`,
      `Backend: ${report.status.backend.state}`,
      `VPN extension: ${report.status.vpnExtension.state}`,
      '',
      'Submitted VPN configuration (addresses redacted)',
      `Available: ${report.vpnConfig.available}`,
      `Addresses: ${report.vpnConfig.addressCount}`,
      `Routes: ${report.vpnConfig.routeCount}`,
      `IPv4 address present: ${report.vpnConfig.hasIPv4Address}`,
      `IPv6 address present: ${report.vpnConfig.hasIPv6Address}`,
      `Tailnet IPv4 route submitted: ${report.vpnConfig.hasTailnetIPv4}`,
      `Tailnet IPv6 route submitted: ${report.vpnConfig.hasTailnetIPv6}`,
      `Default IPv4 route submitted: ${report.vpnConfig.hasDefaultIPv4}`,
      `Default IPv6 route submitted: ${report.vpnConfig.hasDefaultIPv6}`,
      `IPv4 accepted: ${report.vpnConfig.ipv4Accepted}`,
      `IPv6 accepted: ${report.vpnConfig.ipv6Accepted}`,
      `MTU: ${report.vpnConfig.mtu}`,
      '',
      'TUN data path counters',
      `Available: ${report.tunCounters.available}`,
      `Session: ${report.tunCounters.session}`,
      `System to engine: ${report.tunCounters.systemToEnginePackets} packets / ` +
        `${report.tunCounters.systemToEngineBytes} bytes`,
      `Engine to system: ${report.tunCounters.engineToSystemPackets} packets / ` +
        `${report.tunCounters.engineToSystemBytes} bytes`,
      `Read errors: ${report.tunCounters.readErrors}`,
      `Write errors: ${report.tunCounters.writeErrors}`,
      `Structured events: ${report.events.length}`,
      '',
      'Privacy',
      'This archive excludes raw HiLog, raw backend snapshots, authentication data, account identity,',
      'tailnet/device/peer names, network addresses, endpoints, and absolute application paths.'
    ];
    return lines.join('\n');
  }

  private static deviceModel(): string {
    const marketName: string = deviceInfo.marketName.trim();
    if (marketName.length > 0 && marketName !== 'default') {
      return DiagnosticReportService.safeLabel(marketName, 'unknown');
    }
    return DiagnosticReportService.safeLabel(deviceInfo.productModel, 'unknown');
  }

  private static safeVersion(value: string): string {
    const normalized: string = value.trim().replace(/[^a-zA-Z0-9.+_()-]+/g, '_');
    return normalized.length > 96 ? normalized.substring(0, 96) : normalized;
  }

  private static safeToken(value: string, fallback: string): string {
    const normalized: string = value.trim().toLowerCase().replace(/[^a-z0-9_.-]+/g, '_');
    return normalized.length === 0 ? fallback : normalized.substring(0, Math.min(normalized.length, 48));
  }

  private static safeLabel(value: string, fallback: string): string {
    const normalized: string = value.trim().replace(/[\r\n\t]+/g, ' ');
    if (normalized.length === 0) {
      return fallback;
    }
    return normalized.length > 96 ? normalized.substring(0, 96) : normalized;
  }

  private static nonNegative(value: number): number {
    return Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
  }

  private static fileStamp(value: Date): string {
    return `${value.getFullYear()}${DiagnosticReportService.pad(value.getMonth() + 1)}` +
      `${DiagnosticReportService.pad(value.getDate())}-` +
      `${DiagnosticReportService.pad(value.getHours())}${DiagnosticReportService.pad(value.getMinutes())}` +
      `${DiagnosticReportService.pad(value.getSeconds())}-` +
      `${value.getMilliseconds().toString().padStart(3, '0')}`;
  }

  private static pad(value: number): string {
    return value.toString().padStart(2, '0');
  }

  private static writeTextFile(path: string, content: string): void {
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, content);
    } finally {
      if (file !== undefined) {
        fileIo.closeSync(file);
      }
    }
  }

  private static cleanupExpiredReports(cacheDir: string): void {
    try {
      fileIo.listFileSync(cacheDir).forEach((name: string) => {
        if (!name.startsWith(REPORT_PREFIX) || !name.endsWith('.zip')) {
          return;
        }
        const path: string = `${cacheDir}/${name}`;
        const ageMs: number = Date.now() - fileIo.statSync(path).mtime;
        if (ageMs > REPORT_RETENTION_MS) {
          fileIo.unlinkSync(path);
        }
      });
    } catch (_error) {
      // Cache retention is best-effort and does not block a new report.
    }
  }

  private static removeWorkDirectory(workDir: string, summaryPath: string, jsonPath: string): void {
    try {
      if (fileIo.accessSync(summaryPath)) {
        fileIo.unlinkSync(summaryPath);
      }
      if (fileIo.accessSync(jsonPath)) {
        fileIo.unlinkSync(jsonPath);
      }
      if (fileIo.accessSync(workDir)) {
        fileIo.rmdirSync(workDir);
      }
    } catch (_error) {
      // Temporary files contain the same redacted payload and remain inside the private cache.
    }
  }
}
