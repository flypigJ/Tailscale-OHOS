import { PathDiagnosticService } from './PathDiagnosticService';
import { CrashDiagnosticService } from './CrashDiagnosticService';
import { RuntimeDiagnosticService } from './RuntimeDiagnosticService';
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
  appVersionCode?: number;
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
  quickTransferDiagnosticsEnabled: boolean;
  serviceMonitoringDiagnosticsEnabled: boolean;
  securityDiagnosticsEnabled: boolean;
  appearanceDiagnosticsEnabled: boolean;
  localSendAvailableCount: number;
  localSendCheckingCount: number;
  localSendUnavailableCount: number;
  meshArcReceiverState: string;
  meshArcReceiverProtocol: string;
  meshArcReceiverSentCount: number;
  meshArcReceiverRegisteredCount: number;
  mediaAvailablePeerCount: number;
  mediaServiceCount: number;
  hosPlayerSelfTestState: string;
  serviceMonitoringActive: boolean;
  serviceRefreshInProgress: boolean;
  serviceLastRefreshAgeSeconds: number;
  mediaCheckingPeerCount: number;
  sunshineAvailablePeerCount: number;
  sunshineCheckingPeerCount: number;
  taildropState: string;
  appLockEnabled: boolean;
  folderLockEnabled: boolean;
  lockedFolderCount: number;
  appLockRequired: boolean;
  securityAuthenticationInProgress: boolean;
  customBackgroundEnabled: boolean;
  immersiveColorEnabled: boolean;
  glowLevel: number;
  homeLayoutMode: string;
  visibleNavigationTabCount: number;
  navigationBottomMargin: number;
}

export interface DiagnosticReportResult {
  path: string;
  fileName: string;
  size: number;
  feedbackContext?: DiagnosticFeedbackContext;
}

// A small allowlist from the exact redacted snapshot used to generate the ZIP.
// This is transient handoff metadata, not a new persisted report format.
export interface DiagnosticFeedbackContext {
  appVersion: string;
  appVersionCode: number;
  tailscaleVersion: string;
  model: string;
  system: string;
  sdkApiVersion: number;
  generatedAt: string;
  signedIn: boolean;
  exitNodeSelected: boolean;
  acceptSubnetRoutes: boolean;
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
  appVersionCode: number;
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
  dnsCount: number;
  searchDomainCount: number;
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

interface DiagnosticFeatureSelection {
  quickTransferHosPlayer: boolean;
  serviceMonitoring: boolean;
  security: boolean;
  appearance: boolean;
}

interface DiagnosticQuickTransferHosPlayer {
  included: boolean;
  localSendAvailableCount: number;
  localSendCheckingCount: number;
  localSendUnavailableCount: number;
  meshArcReceiverState: string;
  meshArcReceiverProtocol: string;
  meshArcReceiverSentCount: number;
  meshArcReceiverRegisteredCount: number;
  mediaAvailablePeerCount: number;
  mediaServiceCount: number;
  hosPlayerSelfTestState: string;
}

interface DiagnosticServiceMonitoring {
  included: boolean;
  pollingActive: boolean;
  refreshInProgress: boolean;
  lastRefreshAgeSeconds: number;
  mediaCheckingPeerCount: number;
  sunshineAvailablePeerCount: number;
  sunshineCheckingPeerCount: number;
  taildropState: string;
}

interface DiagnosticSecurity {
  included: boolean;
  appLockEnabled: boolean;
  folderLockEnabled: boolean;
  lockedFolderCount: number;
  appLockRequired: boolean;
  authenticationInProgress: boolean;
}

interface DiagnosticAppearance {
  included: boolean;
  customBackgroundEnabled: boolean;
  immersiveColorEnabled: boolean;
  glowLevel: number;
  homeLayoutMode: string;
  visibleNavigationTabCount: number;
  navigationBottomMargin: number;
}

interface DiagnosticFeatures {
  selection: DiagnosticFeatureSelection;
  quickTransferHosPlayer: DiagnosticQuickTransferHosPlayer;
  serviceMonitoring: DiagnosticServiceMonitoring;
  security: DiagnosticSecurity;
  appearance: DiagnosticAppearance;
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
  features: DiagnosticFeatures;
  events: DiagnosticEvent[];
  privacy: DiagnosticReportPrivacy;
}

export class DiagnosticReportService {
  static cleanupCache(cacheDir: string): void {
    DiagnosticReportService.cleanupExpiredReports(cacheDir);
  }

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
    const pathTrace: string = `${workDir}/path-diagnostic.json`;
    const crashTrace: string = `${workDir}/crash-diagnostic.json`;
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
      DiagnosticReportService.writeTextFile(pathTrace, PathDiagnosticService.exportSnapshot(context.filesDir));
      DiagnosticReportService.writeTextFile(crashTrace, CrashDiagnosticService.exportSnapshot(context.filesDir));
      const runtimeFiles: string[] = RuntimeDiagnosticService.exportFiles(context.filesDir, workDir);
      await zlib.compressFiles([summaryPath, jsonPath, pathTrace, crashTrace, ...runtimeFiles], zipPath, {
        level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION
      });
      DiagnosticReportService.removeWorkDirectory(workDir, summaryPath, jsonPath, pathTrace, crashTrace);
      return {
        path: zipPath,
        fileName: fileName,
        size: fileIo.statSync(zipPath).size,
        feedbackContext: {
          appVersion: report.application.appVersion,
          appVersionCode: report.application.appVersionCode,
          tailscaleVersion: report.application.tailscaleVersion,
          model: report.device.model,
          system: `${report.device.osFullName} / ${report.device.displayVersion}`,
          sdkApiVersion: report.device.sdkApiVersion,
          generatedAt: report.generatedAt,
          signedIn: report.network.signedIn,
          exitNodeSelected: report.network.exitNodeSelected,
          acceptSubnetRoutes: report.network.acceptSubnetRoutes
        }
      };
    } catch (error) {
      DiagnosticReportService.removeWorkDirectory(workDir, summaryPath, jsonPath, pathTrace, crashTrace);
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
      schemaVersion: 3,
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
        appVersionCode: DiagnosticReportService.nonNegative(input.appVersionCode ?? 0),
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
      features: DiagnosticReportService.buildFeatures(input),
      events: DiagnosticEventStore.load(filesDir),
      privacy: {
        rawHiLogIncluded: false,
        rawBackendSnapshotIncluded: false,
        identityFieldsIncluded: false,
        networkAddressesIncluded: false
      }
    };
  }

  private static buildFeatures(input: DiagnosticReportInput): DiagnosticFeatures {
    const quick: boolean = input.quickTransferDiagnosticsEnabled;
    const monitoring: boolean = input.serviceMonitoringDiagnosticsEnabled;
    const security: boolean = input.securityDiagnosticsEnabled;
    const appearance: boolean = input.appearanceDiagnosticsEnabled;
    return {
      selection: {
        quickTransferHosPlayer: quick,
        serviceMonitoring: monitoring,
        security: security,
        appearance: appearance
      },
      quickTransferHosPlayer: {
        included: quick,
        localSendAvailableCount: quick ? DiagnosticReportService.nonNegative(input.localSendAvailableCount) : 0,
        localSendCheckingCount: quick ? DiagnosticReportService.nonNegative(input.localSendCheckingCount) : 0,
        localSendUnavailableCount: quick ? DiagnosticReportService.nonNegative(input.localSendUnavailableCount) : 0,
        meshArcReceiverState: quick ? DiagnosticReportService.safeToken(input.meshArcReceiverState, 'unknown') : 'excluded',
        meshArcReceiverProtocol: quick ? DiagnosticReportService.safeToken(input.meshArcReceiverProtocol, 'unknown') : 'excluded',
        meshArcReceiverSentCount: quick ? DiagnosticReportService.nonNegative(input.meshArcReceiverSentCount) : 0,
        meshArcReceiverRegisteredCount: quick ?
          DiagnosticReportService.nonNegative(input.meshArcReceiverRegisteredCount) : 0,
        mediaAvailablePeerCount: quick ? DiagnosticReportService.nonNegative(input.mediaAvailablePeerCount) : 0,
        mediaServiceCount: quick ? DiagnosticReportService.nonNegative(input.mediaServiceCount) : 0,
        hosPlayerSelfTestState: quick ?
          DiagnosticReportService.safeToken(input.hosPlayerSelfTestState, 'not_run') : 'excluded'
      },
      serviceMonitoring: {
        included: monitoring,
        pollingActive: monitoring && input.serviceMonitoringActive,
        refreshInProgress: monitoring && input.serviceRefreshInProgress,
        lastRefreshAgeSeconds: monitoring ?
          DiagnosticReportService.nonNegative(input.serviceLastRefreshAgeSeconds) : 0,
        mediaCheckingPeerCount: monitoring ?
          DiagnosticReportService.nonNegative(input.mediaCheckingPeerCount) : 0,
        sunshineAvailablePeerCount: monitoring ?
          DiagnosticReportService.nonNegative(input.sunshineAvailablePeerCount) : 0,
        sunshineCheckingPeerCount: monitoring ?
          DiagnosticReportService.nonNegative(input.sunshineCheckingPeerCount) : 0,
        taildropState: monitoring ? DiagnosticReportService.safeToken(input.taildropState, 'unknown') : 'excluded'
      },
      security: {
        included: security,
        appLockEnabled: security && input.appLockEnabled,
        folderLockEnabled: security && input.folderLockEnabled,
        lockedFolderCount: security ? DiagnosticReportService.nonNegative(input.lockedFolderCount) : 0,
        appLockRequired: security && input.appLockRequired,
        authenticationInProgress: security && input.securityAuthenticationInProgress
      },
      appearance: {
        included: appearance,
        customBackgroundEnabled: appearance && input.customBackgroundEnabled,
        immersiveColorEnabled: appearance && input.immersiveColorEnabled,
        glowLevel: appearance ? DiagnosticReportService.bounded(input.glowLevel, 0, 3) : 0,
        homeLayoutMode: appearance ? DiagnosticReportService.safeToken(input.homeLayoutMode, 'unknown') : 'excluded',
        visibleNavigationTabCount: appearance ?
          DiagnosticReportService.nonNegative(input.visibleNavigationTabCount) : 0,
        navigationBottomMargin: appearance ?
          DiagnosticReportService.bounded(input.navigationBottomMargin, 0, 128) : 0
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
      dnsCount: 0,
      searchDomainCount: 0,
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
        dnsCount: DiagnosticReportService.statusNumber(summary, 'dnsCount'),
        searchDomainCount: DiagnosticReportService.statusNumber(summary, 'searchDomainCount'),
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
    const lifecycleEvents: DiagnosticEvent[] = report.events.filter((event: DiagnosticEvent) =>
      event.event.startsWith('vpn_') || event.event.startsWith('background_') || event.event.startsWith('backend_'));
    const recentEvents: DiagnosticEvent[] = (lifecycleEvents.length > 0 ? lifecycleEvents : report.events).slice(-50);
    while (recentEvents.length > 0 && recentEvents[0].phase.startsWith('context.')) {
      recentEvents.shift();
    }
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
      `App version code: ${report.application.appVersionCode || 'unknown'}`,
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
      `DNS servers submitted: ${report.vpnConfig.dnsCount}`,
      `DNS search domains submitted: ${report.vpnConfig.searchDomainCount}`,
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
      'Recent lifecycle events (UTC; context.* entries contain numeric values, not error codes)',
      'VPN, background and backend events take priority here; all retained events remain in report.json.',
      'Runtime state: 0=unknown, 1=running, 2=stopped, 3=starting, 4=authentication required',
      'vpn_backend_state_changed uses the runtime-state value, not an error code.',
      'System lifecycle teardown is observed lifecycle, not proof of an OS process kill.',
      'Network stage: 1=default network, 2=properties, 3=capabilities, 4=sample validation,',
      '5=native rebind, 6=monitor registration, 7=monitor teardown',
      ...recentEvents.map((event: DiagnosticEvent) =>
        new Date(event.timestampMs).toISOString() + ' [' + event.source + '] ' + event.event + ' ' +
        event.phase + (event.phase.startsWith('context.') ? ' value=' : ' code=') + event.code),
      '',
      'Feature diagnostics selection',
      `Quick Transfer and HosPlayer: ${report.features.selection.quickTransferHosPlayer}`,
      `Service monitoring: ${report.features.selection.serviceMonitoring}`,
      `Security: ${report.features.selection.security}`,
      `Appearance: ${report.features.selection.appearance}`,
      '',
      'Quick Transfer and HosPlayer (redacted counts and state only)',
      `Included: ${report.features.quickTransferHosPlayer.included}`,
      `LocalSend: ${report.features.quickTransferHosPlayer.localSendAvailableCount} available / ` +
        `${report.features.quickTransferHosPlayer.localSendCheckingCount} checking / ` +
        `${report.features.quickTransferHosPlayer.localSendUnavailableCount} unavailable`,
      `MeshArc receiver: ${report.features.quickTransferHosPlayer.meshArcReceiverState} / ` +
        `${report.features.quickTransferHosPlayer.meshArcReceiverProtocol}`,
      `Receiver delivery: ${report.features.quickTransferHosPlayer.meshArcReceiverRegisteredCount} registered / ` +
        `${report.features.quickTransferHosPlayer.meshArcReceiverSentCount} sent`,
      `Media: ${report.features.quickTransferHosPlayer.mediaAvailablePeerCount} peers / ` +
        `${report.features.quickTransferHosPlayer.mediaServiceCount} services`,
      `HosPlayer self-test: ${report.features.quickTransferHosPlayer.hosPlayerSelfTestState}`,
      '',
      'Online service monitoring',
      `Included: ${report.features.serviceMonitoring.included}`,
      `Polling active: ${report.features.serviceMonitoring.pollingActive}`,
      `Refresh in progress: ${report.features.serviceMonitoring.refreshInProgress}`,
      `Last refresh age: ${report.features.serviceMonitoring.lastRefreshAgeSeconds} seconds`,
      `Media checking: ${report.features.serviceMonitoring.mediaCheckingPeerCount}`,
      `Sunshine: ${report.features.serviceMonitoring.sunshineAvailablePeerCount} available / ` +
        `${report.features.serviceMonitoring.sunshineCheckingPeerCount} checking`,
      `Taildrop: ${report.features.serviceMonitoring.taildropState}`,
      '',
      'Application security',
      `Included: ${report.features.security.included}`,
      `App lock enabled: ${report.features.security.appLockEnabled}`,
      `Security folder enabled: ${report.features.security.folderLockEnabled}`,
      `Locked folder count: ${report.features.security.lockedFolderCount}`,
      `App lock required: ${report.features.security.appLockRequired}`,
      `Authentication in progress: ${report.features.security.authenticationInProgress}`,
      '',
      'Appearance',
      `Included: ${report.features.appearance.included}`,
      `Custom background configured: ${report.features.appearance.customBackgroundEnabled}`,
      `Immersive color enabled: ${report.features.appearance.immersiveColorEnabled}`,
      `Glow level: ${report.features.appearance.glowLevel}`,
      `Home layout: ${report.features.appearance.homeLayoutMode}`,
      `Visible navigation tabs: ${report.features.appearance.visibleNavigationTabCount}`,
      `Navigation bottom margin: ${report.features.appearance.navigationBottomMargin}`,
      '',
      'Path diagnostics: see path-diagnostic.json (opt-in; unavailable means not captured).',
      'Runtime recorder (v2): automatic, local rolling 16 MiB total (five-minute UI/VPN heartbeat; manual local export only; network upload removed).',
      'See runtime-ui-*.ndjson and runtime-vpn-*.ndjson. Relaunch after an exit to collect system termination events.',
      'A missing destruction callback or heartbeat gap alone cannot prove a system kill.',
      'Crash diagnostics: see crash-diagnostic.json (temporary opt-in; strict code frames only).',
      'UDP write success does not establish kernel egress or remote receipt.',
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

  private static bounded(value: number, minimum: number, maximum: number): number {
    if (!Number.isFinite(value)) {
      return minimum;
    }
    return Math.min(maximum, Math.max(minimum, Math.floor(value)));
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
      if (fileIo.writeSync(file.fd, content) !== DiagnosticPrivacy.utf8ByteLength(content)) {
        throw new Error('Diagnostic report short write');
      }
    } finally {
      if (file !== undefined) {
        fileIo.closeSync(file);
      }
    }
  }

  private static cleanupExpiredReports(cacheDir: string): void {
    let names: string[] = [];
    try { names = fileIo.listFileSync(cacheDir); } catch (_error) { return; }
    for (const name of names) {
      const archive: boolean = name.startsWith(REPORT_PREFIX) && name.endsWith('.zip');
      const workDirectory: boolean = /^diagnostic-report-\d{8}-\d{6}-\d{3}$/.test(name);
      if (!archive && !workDirectory) continue;
      const path: string = `${cacheDir}/${name}`;
      try {
        const stat: fileIo.Stat = fileIo.lstatSync(path);
        if (stat.isSymbolicLink()) continue;
        // SDK Stat.mtime is seconds; preserve unknown or future timestamps.
        const modifiedMs: number = stat.mtime * 1000;
        const ageMs: number = Date.now() - modifiedMs;
        if (!Number.isFinite(modifiedMs) || modifiedMs <= 0 || ageMs <= REPORT_RETENTION_MS) continue;
        if (archive && stat.isFile()) {
          fileIo.unlinkSync(path);
        } else if (workDirectory && stat.isDirectory()) {
          DiagnosticReportService.cleanupOrphanWorkDirectory(path);
        }
      } catch (_error) {
        // A stale or inaccessible item must not prevent cleanup of later items.
      }
    }
  }

  private static cleanupOrphanWorkDirectory(workDir: string): void {
    for (const name of ['summary.txt', 'report.json', 'path-diagnostic.json', 'crash-diagnostic.json',
      ...RuntimeDiagnosticService.fileNames()]) {
      const path: string = `${workDir}/${name}`;
      try {
        const stat: fileIo.Stat = fileIo.lstatSync(path);
        if (!stat.isSymbolicLink() && stat.isFile()) fileIo.unlinkSync(path);
      } catch (_error) {
        // Retry known files on a later cleanup; never follow links or unknown entries.
      }
    }
    // rmdirSync is recursive on HarmonyOS. Keep the directory shell rather than
    // risk removing unknown or concurrently created contents.
  }

  private static removeWorkDirectory(workDir: string, summaryPath: string, jsonPath: string,
    pathTrace?: string, crashTrace?: string): void {
    try {
      for (const name of RuntimeDiagnosticService.fileNames()) {
        const path: string = `${workDir}/${name}`;
        if (fileIo.accessSync(path)) fileIo.unlinkSync(path);
      }
      if (pathTrace !== undefined && fileIo.accessSync(pathTrace)) { fileIo.unlinkSync(pathTrace); }
      if (crashTrace !== undefined && fileIo.accessSync(crashTrace)) { fileIo.unlinkSync(crashTrace); }
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
