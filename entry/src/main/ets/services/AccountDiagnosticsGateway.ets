import { process as appProcess } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import nativeBridge from 'libtailscale_ohos.so';
import BuildProfile from 'BuildProfile';
import { DiagnosticEventStore } from './DiagnosticEventStore';
import {
  DiagnosticReportInput,
  DiagnosticReportResult,
  DiagnosticReportService
} from './DiagnosticReportService';
import { HomeReadOnlyGateway } from './HomeReadOnlyGateway';
import { DiagnosticPrivacy } from './DiagnosticPrivacy';
import { VPN_PROBE_STATUS_FILE_NAME } from '@tailscale/common';

export { RequestGuard as AccountDiagnosticsRequestGuard } from '@tailscale/common';

const WELCOME_ACKNOWLEDGED_FILE_NAME: string = 'welcome-acknowledged';

export interface NativeBridgeDiagnosticStatus {
  nativeStatus: string;
  tailscaleVersion: string;
}

/** Owns the M8B Account and Diagnostics Native/file boundary. */
export class AccountDiagnosticsGateway {
  private readonly homeReadOnlyGateway: HomeReadOnlyGateway = new HomeReadOnlyGateway();

  readAccount<T>(): T {
    return this.homeReadOnlyGateway.readAccount<T>();
  }

  async logout(): Promise<string> {
    return await nativeBridge.backendLogoutAsync();
  }

  inspectNativeBridge(): NativeBridgeDiagnosticStatus {
    try {
      return {
        nativeStatus: nativeBridge.hello(),
        tailscaleVersion: nativeBridge.tailscaleVersion()
      };
    } catch (error) {
      return { nativeStatus: DiagnosticPrivacy.formatNativeFailure('Go Bridge Failed', error), tailscaleVersion: '' };
    }
  }

  async probeEngine(): Promise<string> {
    try {
      return await nativeBridge.probeEngineAsync();
    } catch (error) {
      return DiagnosticPrivacy.formatNativeFailure('Tailscale Engine Failed', error);
    }
  }

  probeControl(): string {
    try {
      return nativeBridge.controlProbe();
    } catch (error) {
      return DiagnosticPrivacy.formatNativeFailure('Control TLS Probe Failed', error);
    }
  }

  async runMediaProbeSelfTest(): Promise<string> {
    return await nativeBridge.mediaProbeSelfTestAsync();
  }

  recordEvent(context: common.Context, event: string, phase: string, code: number = 0): void {
    DiagnosticEventStore.record(context.filesDir, 'ui', event, phase, code);
  }

  async generateReport(context: common.UIAbilityContext,
    input: DiagnosticReportInput): Promise<DiagnosticReportResult> {
    return await DiagnosticReportService.generate(context, input);
  }

  async shareReport(context: common.UIAbilityContext, result: DiagnosticReportResult): Promise<void> {
    await DiagnosticReportService.share(context, result);
  }

  clearWelcomeAcknowledgement(context: common.Context): boolean {
    try {
      const path: string = `${context.filesDir}/${WELCOME_ACKNOWLEDGED_FILE_NAME}`;
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
      return true;
    } catch (_error) {
      return false;
    }
  }

  stageCrashProbeStatus(context: common.Context, status: string): boolean {
    if (!BuildProfile.DEBUG) {
      return false;
    }
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(`${context.filesDir}/${VPN_PROBE_STATUS_FILE_NAME}`,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, status);
      return true;
    } catch (_error) {
      return false;
    } finally {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (_closeError) {
        }
      }
    }
  }

  abortProcessAfter(delayMs: number): void {
    if (!BuildProfile.DEBUG) {
      return;
    }
    setTimeout(() => appProcess.abort(), delayMs);
  }
}
