import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { StoragePaths } from './StoragePaths';
import { DiagnosticPrivacy } from './DiagnosticPrivacy';

const DOMAIN: number = 0x0000;
const TAG: string = 'VpnBackgroundTask';
const BUNDLE_NAME: string = 'io.github.tailscaleohos';
const ENTRY_ABILITY_NAME: string = 'EntryAbility';
const VPN_STATUS_FRESH_MS: number = 15000;
const START_RETRY_INTERVAL_MS: number = 250;
const START_RETRY_LIMIT: number = 20;
const HEALTH_CHECK_INTERVAL_MS: number = 5000;

export class VpnBackgroundTaskManager {
  private isBackground: boolean = false;
  private isStarted: boolean = false;
  private startInFlight: boolean = false;
  private stopInFlight: boolean = false;
  private listenerRegistered: boolean = false;
  private lifecycleGeneration: number = 0;
  private retryTimer: number = -1;
  private healthTimer: number = -1;

  private readonly cancelCallback =
    (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
      this.isStarted = false;
      this.startInFlight = false;
      this.stopHealthCheck();
      hilog.info(DOMAIN, TAG,
        'VPN background task cancelled by system. id=%{public}d reason=%{public}d',
        info.id, info.reason);
    };

  register(): void {
    if (this.listenerRegistered) {
      return;
    }
    try {
      backgroundTaskManager.on('continuousTaskCancel', this.cancelCallback);
      this.listenerRegistered = true;
    } catch (error) {
      const businessError = error as BusinessError;
      hilog.warn(DOMAIN, TAG,
        'Failed to register continuous-task cancellation listener. code=%{public}d',
        businessError.code ?? -1);
    }
  }

  unregister(): void {
    this.isBackground = false;
    this.lifecycleGeneration++;
    this.clearRetryTimer();
    this.stopHealthCheck();
    if (!this.listenerRegistered) {
      return;
    }
    try {
      backgroundTaskManager.off('continuousTaskCancel', this.cancelCallback);
    } catch (error) {
      const businessError = error as BusinessError;
      hilog.warn(DOMAIN, TAG,
        'Failed to unregister continuous-task cancellation listener. code=%{public}d',
        businessError.code ?? -1);
    }
    this.listenerRegistered = false;
  }

  onBackground(context: common.UIAbilityContext): void {
    this.isBackground = true;
    const generation: number = ++this.lifecycleGeneration;
    this.clearRetryTimer();
    this.startWhenVpnActive(context, generation, 0);
  }

  onForeground(context: common.UIAbilityContext): void {
    this.isBackground = false;
    this.lifecycleGeneration++;
    this.clearRetryTimer();
    this.stopHealthCheck();
    this.stop(context);
  }

  private startWhenVpnActive(context: common.UIAbilityContext,
    generation: number, attempt: number): void {
    if (!this.isBackground || generation !== this.lifecycleGeneration ||
      this.isStarted || this.startInFlight || this.stopInFlight) {
      return;
    }
    if (this.hasLiveVpnStatus(context.filesDir)) {
      this.start(context, generation);
      return;
    }
    if (attempt >= START_RETRY_LIMIT) {
      hilog.info(DOMAIN, TAG,
        'VPN background task not started because no live VPN session was detected');
      return;
    }
    this.retryTimer = setTimeout(() => {
      this.retryTimer = -1;
      this.startWhenVpnActive(context, generation, attempt + 1);
    }, START_RETRY_INTERVAL_MS);
  }

  private async start(context: common.UIAbilityContext, generation: number): Promise<void> {
    this.startInFlight = true;
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: BUNDLE_NAME,
          abilityName: ENTRY_ABILITY_NAME
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1001,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      if (!this.isBackground || generation !== this.lifecycleGeneration) {
        return;
      }
      await backgroundTaskManager.startBackgroundRunning(
        context, backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
      if (!this.isBackground || generation !== this.lifecycleGeneration) {
        await backgroundTaskManager.stopBackgroundRunning(context);
        return;
      }
      this.isStarted = true;
      this.startHealthCheck(context, generation);
      hilog.info(DOMAIN, TAG, 'VPN DATA_TRANSFER background task started');
    } catch (error) {
      const businessError = error as BusinessError;
      hilog.error(DOMAIN, TAG,
        'Failed to start VPN background task. code=%{public}d %{public}s',
        businessError.code ?? -1, DiagnosticPrivacy.formatLogError(businessError));
    } finally {
      this.startInFlight = false;
    }
  }

  private async stop(context: common.UIAbilityContext): Promise<void> {
    if (this.stopInFlight) {
      return;
    }
    this.stopInFlight = true;
    try {
      const tasks: backgroundTaskManager.ContinuousTaskInfo[] =
        await backgroundTaskManager.getAllContinuousTasks(context, false);
      const hasEntryTask: boolean =
        tasks.some((task: backgroundTaskManager.ContinuousTaskInfo) =>
          task.abilityName === ENTRY_ABILITY_NAME);
      if (!this.isStarted && !hasEntryTask) {
        return;
      }
      await backgroundTaskManager.stopBackgroundRunning(context);
      this.isStarted = false;
      hilog.info(DOMAIN, TAG, 'VPN DATA_TRANSFER background task stopped');
    } catch (error) {
      const businessError = error as BusinessError;
      hilog.warn(DOMAIN, TAG,
        'Failed to stop VPN background task. code=%{public}d %{public}s',
        businessError.code ?? -1, DiagnosticPrivacy.formatLogError(businessError));
    } finally {
      this.stopInFlight = false;
      if (this.isBackground) {
        this.startWhenVpnActive(context, this.lifecycleGeneration, 0);
      }
    }
  }

  private startHealthCheck(context: common.UIAbilityContext, generation: number): void {
    this.stopHealthCheck();
    this.healthTimer = setInterval(() => {
      if (!this.isBackground || generation !== this.lifecycleGeneration ||
        !this.isStarted) {
        this.stopHealthCheck();
        return;
      }
      if (!this.hasLiveVpnStatus(context.filesDir)) {
        this.stopHealthCheck();
        this.stop(context);
      }
    }, HEALTH_CHECK_INTERVAL_MS);
  }

  private hasLiveVpnStatus(filesDir: string): boolean {
    try {
      const status: string = fileIo.readTextSync(StoragePaths.vpnStatusPath(filesDir));
      const heartbeatMatch: RegExpMatchArray | null = status.match(/heartbeatMs=(\d+)/);
      if (heartbeatMatch === null) {
        return false;
      }
      const heartbeatMs: number = Number(heartbeatMatch[1]);
      const ageMs: number = Date.now() - heartbeatMs;
      if (heartbeatMs <= 0 || ageMs < 0 || ageMs > VPN_STATUS_FRESH_MS) {
        return false;
      }
      const normalized: string = status.toLowerCase();
      if (normalized.includes('destroyed') || normalized.includes('stopped') ||
        normalized.includes('failed')) {
        return false;
      }
      return normalized.includes('state=running') ||
        normalized.includes('tun=true') ||
        normalized.includes('lifecycle entered') ||
        normalized.includes('connection object created') ||
        normalized.includes('creation pending') ||
        normalized.includes('interface established') ||
        normalized.includes('backend starting');
    } catch (_error) {
      return false;
    }
  }

  private clearRetryTimer(): void {
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
  }

  private stopHealthCheck(): void {
    if (this.healthTimer >= 0) {
      clearInterval(this.healthTimer);
      this.healthTimer = -1;
    }
  }
}
