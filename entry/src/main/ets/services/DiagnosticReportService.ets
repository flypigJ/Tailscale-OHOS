import { common } from '@kit.AbilityKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { deviceInfo, zlib } from '@kit.BasicServicesKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { systemShare } from '@kit.ShareKit';
import { DiagnosticEvent, DiagnosticEventStore } from './DiagnosticEventStore';

const REPORT_PREFIX: string = 'TailscaleOHOS-Diagnostic-';
const REPORT_RETENTION_MS: number = 24 * 60 * 60 * 1000;

export interface DiagnosticReportInput {
  appVersion: string;
  tailscaleVersion: string;
  nativeStatus: string;
  engineStatus: string;
  backendStatus: string;
  vpnStatus: string;
  magicDNSStatus: string;
  peerCount: number;
  onlinePeerCount: number;
  exitNodeCount: number;
  exitNodeSelected: boolean;
  addressCount: number;
  signedIn: boolean;
  routeAll: boolean;
  corpDNS: boolean;
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
  useTailscaleDNS: boolean;
  exitNodeAllowLANAccess: boolean;
}

interface DiagnosticStatusSet {
  nativeBridge: DiagnosticCheck;
  engine: DiagnosticCheck;
  backend: DiagnosticCheck;
  vpnExtension: DiagnosticCheck;
  magicDNS: DiagnosticCheck;
}

interface DiagnosticPrivacy {
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
  events: DiagnosticEvent[];
  privacy: DiagnosticPrivacy;
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
      DiagnosticReportService.writeTextFile(summaryPath, DiagnosticReportService.buildSummary(report));
      DiagnosticReportService.writeTextFile(jsonPath, JSON.stringify(report, undefined, 2));
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
      if (fileIo.accessSync(zipPath)) {
        try {
          fileIo.unlinkSync(zipPath);
        } catch (_cleanupError) {
          // A partial archive is never shared, even if cleanup is delayed by the file service.
        }
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
      schemaVersion: 1,
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
        useTailscaleDNS: input.corpDNS,
        exitNodeAllowLANAccess: input.exitNodeAllowLANAccess
      },
      status: {
        nativeBridge: DiagnosticReportService.classifyStatus(input.nativeStatus),
        engine: DiagnosticReportService.classifyStatus(input.engineStatus),
        backend: DiagnosticReportService.classifyStatus(input.backendStatus),
        vpnExtension: DiagnosticReportService.classifyStatus(input.vpnStatus),
        magicDNS: DiagnosticReportService.classifyStatus(input.magicDNSStatus)
      },
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
      `MagicDNS: ${report.status.magicDNS.state}`,
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
