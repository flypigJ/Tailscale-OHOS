import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { StoragePaths } from './StoragePaths';
import { DiagnosticEventStore } from './DiagnosticEventStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'VpnBackgroundTask';
const BUNDLE_NAME: string = 'io.github.tailscaleohos';
const ENTRY_ABILITY_NAME: string = 'EntryAbility';
const VPN_STATUS_FRESH_MS: number = 15000;
const CONNECTION_START_GRACE_MS: number = 30000;
const CONNECTION_CHECK_INTERVAL_MS: number = 1000;
const NOTIFICATION_UPDATE_INTERVAL_MS: number = 30000;
const START_RETRY_BASE_MS: number = 30000;
const START_RETRY_MAX_MS: number = 300000;

interface VpnRuntimeStatus {
  state: string;
  heartbeatMs: number;
  txBytes: number;
  rxBytes: number;
}

export class VpnBackgroundTaskManager {
  private context?: common.UIAbilityContext;
  private monitoring: boolean = false;
  private operationInFlight: boolean = false;
  private reconcileRequested: boolean = false;
  private listenerRegistered: boolean = false;
  private suspendListenerRegistered: boolean = false;
  private activeListenerRegistered: boolean = false;
  private queryRequested: boolean = false;
  private lifecycleGeneration: number = 0;
  private cancellationRevision: number = 0;
  private startPending: boolean = false;
  private earlyCancellations: backgroundTaskManager.ContinuousTaskCancelInfo[] = [];
  private monitorTimer: number = -1;
  private task?: backgroundTaskManager.ContinuousTaskNotification;
  private stopping: boolean = false;
  private suppressedUntilDisconnect: boolean = false;
  private nextStartAtMs: number = 0;
  private retryCount: number = 0;
  private lastLiveStatus?: VpnRuntimeStatus;
  private nextNotificationAtMs: number = 0;
  private requestedAtMs: number = 0;
  private pendingUntilMs: number = 0;
  private explicitlyStopped: boolean = false;
  private publishPromise?: Promise<void>;

  private readonly cancelCallback =
    (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
      if (this.stopping) {
        return;
      }
      if (this.task === undefined) {
        if (this.startPending) {
          this.earlyCancellations.push(info);
          if (this.earlyCancellations.length > 16) {
            this.earlyCancellations.shift();
          }
        }
        return;
      }
      if (info.id !== this.task.continuousTaskId) {
        return;
      }
      // Only the returned system task ID identifies this VPN task.
      this.cancellationRevision++;
      this.task = undefined;
      const userCancelled: boolean =
        info.reason === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL ||
        info.reason === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL_REMOVE_NOTIFICATION;
      this.suppressedUntilDisconnect = userCancelled;
      if (!userCancelled) {
        this.scheduleRetry();
      }
      this.record(userCancelled ? 'background_user_cancelled' : 'background_system_cancelled', info.reason);
      hilog.info(DOMAIN, TAG, 'VPN background task cancelled. id=%{public}d reason=%{public}d',
        info.id, info.reason);
    };

  private readonly suspendCallback =
    (info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => {
      if (info.continuousTaskId !== this.task?.continuousTaskId) {
        return;
      }
      this.record(info.suspendState ? 'background_suspended' : 'background_resumed', info.suspendReason);
      hilog.info(DOMAIN, TAG, 'VPN background task suspend=%{public}s reason=%{public}d',
        `${info.suspendState}`, info.suspendReason);
    };

  private readonly activeCallback =
    (info: backgroundTaskManager.ContinuousTaskActiveInfo): void => {
      if (info.id !== this.task?.continuousTaskId) {
        return;
      }
      this.nextNotificationAtMs = 0;
      this.record('background_active');
      if (this.context !== undefined) {
        void this.reconcile(this.context);
      }
    };

  register(context: common.UIAbilityContext): void {
    if (this.monitoring) {
      return;
    }
    this.context = context;
    try {
      backgroundTaskManager.on('continuousTaskCancel', this.cancelCallback);
      this.listenerRegistered = true;
    } catch (error) {
      this.record('background_listener_failed', (error as BusinessError).code ?? -1);
    }
    try {
      backgroundTaskManager.on('continuousTaskSuspend', this.suspendCallback);
      this.suspendListenerRegistered = true;
    } catch (error) {
      this.record('background_suspend_listener_failed', (error as BusinessError).code ?? -1);
    }
    try {
      backgroundTaskManager.on('continuousTaskActive', this.activeCallback);
      this.activeListenerRegistered = true;
    } catch (error) {
      this.record('background_active_listener_failed', (error as BusinessError).code ?? -1);
    }
    this.monitoring = true;
    this.queryRequested = true;
    ++this.lifecycleGeneration;
    this.reconcile(context);
    this.monitorTimer = setInterval(() => this.reconcile(context), CONNECTION_CHECK_INTERVAL_MS);
  }

  unregister(): void {
    this.monitoring = false;
    this.lifecycleGeneration++;
    if (this.monitorTimer >= 0) {
      clearInterval(this.monitorTimer);
      this.monitorTimer = -1;
    }
    if (this.listenerRegistered) {
      try {
        backgroundTaskManager.off('continuousTaskCancel', this.cancelCallback);
      } catch (_error) {
        // Ability destruction also releases this process's listeners.
      }
      this.listenerRegistered = false;
    }
    if (this.suspendListenerRegistered) {
      try {
        backgroundTaskManager.off('continuousTaskSuspend', this.suspendCallback);
      } catch (_error) {
        // Best-effort teardown.
      }
      this.suspendListenerRegistered = false;
    }
    if (this.activeListenerRegistered) {
      try {
        backgroundTaskManager.off('continuousTaskActive', this.activeCallback);
      } catch (_error) { }
      this.activeListenerRegistered = false;
    }
    if (this.context !== undefined) {
      this.reconcile(this.context);
    }
  }

  onVpnConnectionRequested(context: common.UIAbilityContext): void {
    this.context = context;
    this.explicitlyStopped = false;
    this.requestedAtMs = Date.now();
    this.pendingUntilMs = this.requestedAtMs + CONNECTION_START_GRACE_MS;
    this.lastLiveStatus = undefined;
    this.suppressedUntilDisconnect = false;
    this.nextStartAtMs = 0;
    this.retryCount = 0;
    this.record('background_connection_requested');
    void this.reconcile(context);
  }

  onVpnDisconnected(context: common.UIAbilityContext): void {
    this.context = context;
    this.explicitlyStopped = true;
    this.pendingUntilMs = 0;
    this.lastLiveStatus = undefined;
    this.cancellationRevision++;
    this.record('background_connection_stopped');
    void this.reconcile(context);
  }

  onVpnStopFailed(context: common.UIAbilityContext): void {
    this.context = context;
    this.explicitlyStopped = false;
    this.queryRequested = true;
    this.record('background_stop_recovery');
    void this.reconcile(context);
  }

  onBackground(context: common.UIAbilityContext): void {
    this.record('background_entered');
    this.reconcile(context);
  }

  onForeground(context: common.UIAbilityContext): void {
    // Returning to the app is an explicit recovery boundary after dismissal.
    // Background status polling alone must never clear user cancellation.
    if (this.suppressedUntilDisconnect) {
      this.suppressedUntilDisconnect = false;
      this.record('background_foreground_recovery');
    }
    this.nextStartAtMs = 0;
    this.retryCount = 0;
    this.queryRequested = true;
    this.reconcile(context);
  }

  private async reconcile(context: common.UIAbilityContext): Promise<void> {
    if (this.operationInFlight) {
      this.reconcileRequested = true;
      return;
    }
    this.operationInFlight = true;
    const generation: number = this.lifecycleGeneration;
    try {
      if (!this.monitoring || this.explicitlyStopped) {
        await this.stop(context);
        return;
      }
      if (this.queryRequested) {
        this.queryRequested = false;
        await this.reconcileSystemTasks(context, generation);
        if (!this.monitoring || this.explicitlyStopped || generation !== this.lifecycleGeneration) {
          return;
        }
      }
      const status: VpnRuntimeStatus = this.readStatus(context.filesDir);
      const pending: boolean = this.pendingUntilMs > Date.now();
      const oldStatus: boolean = pending && status.heartbeatMs < this.requestedAtMs;
      if (this.pendingUntilMs > 0 && !pending && this.lastLiveStatus === undefined) {
        this.pendingUntilMs = 0;
        this.record('background_connection_timeout');
        await this.stop(context);
        return;
      }
      if (status.state === 'disconnected' && !oldStatus) {
        this.suppressedUntilDisconnect = false;
        this.nextStartAtMs = 0;
        this.retryCount = 0;
        this.lastLiveStatus = undefined;
        this.pendingUntilMs = 0;
        await this.stop(context);
        return;
      }
      if (status.state !== 'connected' || oldStatus) {
        if (pending && this.task === undefined && !this.suppressedUntilDisconnect &&
          Date.now() >= this.nextStartAtMs) {
          await this.start(context, generation);
        }
        // A sleeping extension may not refresh its status file. The session
        // remains protected until an explicit terminal status or ability exit.
        // Keep the live view fresh using the last confirmed traffic counters.
        if (this.task !== undefined) {
          await this.updateNotification(context, this.lastLiveStatus ?? status);
        }
        return;
      }
      this.pendingUntilMs = 0;
      this.lastLiveStatus = status;
      if (this.task === undefined && !this.suppressedUntilDisconnect && Date.now() >= this.nextStartAtMs) {
        await this.start(context, generation);
      }
      if (this.monitoring && generation === this.lifecycleGeneration && this.task !== undefined) {
        await this.updateNotification(context, status);
      }
    } catch (error) {
      this.scheduleRetry();
      this.record('background_operation_failed', (error as BusinessError).code ?? -1);
    } finally {
      // Destruction may happen during any awaited operation.
      if (!this.monitoring) {
        await this.stop(context);
      }
      this.operationInFlight = false;
      if (this.reconcileRequested) {
        this.reconcileRequested = false;
        void this.reconcile(context);
      }
    }
  }

  private async reconcileSystemTasks(context: common.UIAbilityContext, generation: number): Promise<void> {
    try {
      const tasks: backgroundTaskManager.ContinuousTaskInfo[] =
        await backgroundTaskManager.getAllContinuousTasks(context, true);
      if (!this.monitoring || this.explicitlyStopped || generation !== this.lifecycleGeneration) {
        return;
      }
      const current: backgroundTaskManager.ContinuousTaskNotification | undefined = this.task;
      const match: backgroundTaskManager.ContinuousTaskInfo | undefined = tasks.find(
        (item: backgroundTaskManager.ContinuousTaskInfo) => item.abilityName === ENTRY_ABILITY_NAME &&
          item.backgroundModes.includes('dataTransfer') &&
          (current === undefined || item.continuousTaskId === current.continuousTaskId ||
            (current.continuousTaskId === undefined && item.notificationId === current.notificationId)));
      if (match !== undefined) {
        if (current === undefined) {
          this.task = {
            continuousTaskId: match.continuousTaskId,
            notificationId: match.notificationId,
            slotType: notificationManager.SlotType.LIVE_VIEW,
            contentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW
          };
          this.nextNotificationAtMs = 0;
          this.record('background_task_recovered');
        } else if (current.continuousTaskId === undefined) {
          current.continuousTaskId = match.continuousTaskId;
        }
      } else if (current !== undefined) {
        this.task = undefined;
        this.record('background_task_missing');
      }
    } catch (error) {
      this.record('background_task_query_failed', (error as BusinessError).code ?? -1);
    }
  }

  private async start(context: common.UIAbilityContext, generation: number): Promise<void> {
    const revision: number = this.cancellationRevision;
    const info: wantAgent.WantAgentInfo = {
      wants: [{ bundleName: BUNDLE_NAME, abilityName: ENTRY_ABILITY_NAME }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 1001,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    const agent: WantAgent = await wantAgent.getWantAgent(info);
    if (!this.monitoring || generation !== this.lifecycleGeneration ||
      revision !== this.cancellationRevision || !this.canStart(context.filesDir)) {
      return;
    }
    // The numeric overload returns void and cannot supply the system-owned
    // notification ID needed for DATA_TRANSFER live-view updates.
    this.startPending = true;
    this.earlyCancellations = [];
    let task: backgroundTaskManager.ContinuousTaskNotification;
    try {
      task = await backgroundTaskManager.startBackgroundRunning(context, ['dataTransfer'], agent);
    } catch (error) {
      this.earlyCancellations = [];
      throw error;
    } finally {
      this.startPending = false;
    }
    if (task.continuousTaskId === undefined) {
      this.startPending = true;
      try {
        const tasks: backgroundTaskManager.ContinuousTaskInfo[] =
          await backgroundTaskManager.getAllContinuousTasks(context, true);
        const match: backgroundTaskManager.ContinuousTaskInfo | undefined = tasks.find(
          (item: backgroundTaskManager.ContinuousTaskInfo) => item.abilityName === ENTRY_ABILITY_NAME &&
            item.notificationId === task.notificationId && item.backgroundModes.includes('dataTransfer'));
        if (match !== undefined) {
          task.continuousTaskId = match.continuousTaskId;
        }
      } catch (error) {
        this.record('background_task_id_query_failed', (error as BusinessError).code ?? -1);
      } finally {
        this.startPending = false;
      }
    }
    const earlyCancellation: backgroundTaskManager.ContinuousTaskCancelInfo | undefined =
      this.earlyCancellations.find((info: backgroundTaskManager.ContinuousTaskCancelInfo) =>
        info.id === task.continuousTaskId);
    this.earlyCancellations = [];
    if (earlyCancellation !== undefined) {
      this.task = task;
      this.cancelCallback(earlyCancellation);
      return;
    }
    this.task = task;
    if (revision !== this.cancellationRevision) {
      await this.stop(context);
      return;
    }
    if (!this.monitoring || generation !== this.lifecycleGeneration ||
      !this.canStart(context.filesDir)) {
      await this.stop(context);
      return;
    }
    this.nextNotificationAtMs = 0;
    this.record('background_started');
    hilog.info(DOMAIN, TAG, 'VPN DATA_TRANSFER background task started. id=%{public}d',
      task.continuousTaskId ?? -1);
  }

  private canStart(filesDir: string): boolean {
    if (this.explicitlyStopped) {
      return false;
    }
    const status: VpnRuntimeStatus = this.readStatus(filesDir);
    const pending: boolean = this.pendingUntilMs > Date.now();
    if (status.state === 'disconnected' && (!pending || status.heartbeatMs >= this.requestedAtMs)) {
      return false;
    }
    return status.state === 'connected' || pending;
  }

  private async stop(context: common.UIAbilityContext): Promise<void> {
    const task: backgroundTaskManager.ContinuousTaskNotification | undefined = this.task;
    if (task === undefined) {
      return;
    }
    if (this.publishPromise !== undefined) {
      await this.publishPromise;
    }
    if (this.task !== task) {
      return;
    }
    let taskId: number | undefined = task.continuousTaskId;
    if (taskId === undefined) {
      try {
        const tasks: backgroundTaskManager.ContinuousTaskInfo[] =
          await backgroundTaskManager.getAllContinuousTasks(context, true);
        const match: backgroundTaskManager.ContinuousTaskInfo | undefined = tasks.find(
          (item: backgroundTaskManager.ContinuousTaskInfo) => item.abilityName === ENTRY_ABILITY_NAME &&
            item.notificationId === task.notificationId && item.backgroundModes.includes('dataTransfer'));
        if (match === undefined) {
          if (this.task === task) {
            this.task = undefined;
          }
          return;
        }
        taskId = match.continuousTaskId;
      } catch (error) {
        this.record('background_stop_query_failed', (error as BusinessError).code ?? -1);
        return;
      }
    }
    if (this.task !== task) {
      return;
    }
    this.stopping = true;
    try {
      await backgroundTaskManager.stopBackgroundRunning(context, taskId);
      if (this.task === task) {
        this.task = undefined;
      }
      this.record('background_stopped');
    } catch (error) {
      this.record('background_stop_failed', (error as BusinessError).code ?? -1);
    } finally {
      this.stopping = false;
    }
  }

  private async updateNotification(context: common.UIAbilityContext, status: VpnRuntimeStatus): Promise<void> {
    const task: backgroundTaskManager.ContinuousTaskNotification | undefined = this.task;
    if (task === undefined || this.publishPromise !== undefined || Date.now() < this.nextNotificationAtMs) {
      return;
    }
    this.nextNotificationAtMs = Date.now() + NOTIFICATION_UPDATE_INTERVAL_MS;
    const title: string = context.resourceManager.getStringByNameSync(
      status.state === 'connected' ? 'notification_vpn_background_title' : 'notification_vpn_background_connecting');
    const traffic: string = `↑ ${this.formatBytes(status.txBytes)}  ↓ ${this.formatBytes(status.rxBytes)}`;
    const request: notificationManager.NotificationRequest = {
      id: task.notificationId,
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      isAlertOnce: true,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
        systemLiveView: { typeCode: 8, title: title, text: traffic }
      },
      template: {
        name: 'downloadTemplate',
        // A tunnel has no completion percentage; show only actual byte counters.
        data: { title: title, fileName: traffic }
      }
    };
    const publishing: Promise<void> = notificationManager.publish(request).then(async () => {
      if (this.task !== task) {
        try {
          await notificationManager.cancel(task.notificationId);
        } catch (_error) { }
      }
    }).catch((error: BusinessError) => {
      this.nextNotificationAtMs = 0;
      this.record('background_notification_failed', error.code ?? -1);
    });
    this.publishPromise = publishing;
    await publishing;
    if (this.publishPromise === publishing) {
      this.publishPromise = undefined;
    }
  }

  private readStatus(filesDir: string): VpnRuntimeStatus {
    const result: VpnRuntimeStatus = { state: 'unknown', heartbeatMs: 0, txBytes: 0, rxBytes: 0 };
    try {
      const status: string = fileIo.readTextSync(StoragePaths.vpnStatusPath(filesDir));
      const heartbeatMs: number = this.statusNumber(status, 'heartbeatMs');
      result.heartbeatMs = heartbeatMs;
      const ageMs: number = Date.now() - heartbeatMs;
      if (heartbeatMs <= 0 || ageMs < 0) {
        return result;
      }
      const normalized: string = status.toLowerCase();
      if (normalized.includes('extension destroyed') || normalized.includes('vpn disconnected') ||
        normalized.includes('state=stopped') || normalized.startsWith('stopped') ||
        (normalized.startsWith('failed') && !normalized.includes('status unavailable'))) {
        // Terminal records are written once, so they can outlive the heartbeat
        // freshness window while the UI is suspended. Only accept records at
        // least as recent as this connection request and its last live status.
        const sessionBoundaryMs: number = Math.max(this.requestedAtMs, this.lastLiveStatus?.heartbeatMs ?? 0);
        if (heartbeatMs >= sessionBoundaryMs) {
          result.state = 'disconnected';
        }
      } else if (ageMs <= VPN_STATUS_FRESH_MS &&
        normalized.includes('state=running') && normalized.includes('tun=true')) {
        result.state = 'connected';
        result.txBytes = this.statusNumber(status, 'txBytes');
        result.rxBytes = this.statusNumber(status, 'rxBytes');
      }
    } catch (_error) {
      // Atomic file replacement or temporary I/O failure is uncertain state.
    }
    return result;
  }

  private statusNumber(status: string, field: string): number {
    const match: RegExpMatchArray | null = status.match(new RegExp(`(?:^|\\s)${field}=(\\d+)(?:\\s|$)`));
    const value: number = match === null ? 0 : Number(match[1]);
    return Number.isSafeInteger(value) && value >= 0 ? value : 0;
  }

  private formatBytes(bytes: number): string {
    if (bytes >= 1024 * 1024 * 1024) {
      return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GiB`;
    }
    if (bytes >= 1024 * 1024) {
      return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
    }
    return `${(bytes / 1024).toFixed(1)} KiB`;
  }

  private scheduleRetry(): void {
    this.nextStartAtMs = Date.now() + Math.min(START_RETRY_MAX_MS,
      START_RETRY_BASE_MS * Math.pow(2, Math.min(this.retryCount, 4)));
    this.retryCount++;
  }

  private record(event: string, code: number = 0): void {
    hilog.info(DOMAIN, TAG, '%{public}s code=%{public}d', event, code);
    if (this.context !== undefined) {
      DiagnosticEventStore.record(this.context.filesDir, 'ui', event, 'background', code);
    }
  }
}

export const vpnBackgroundTaskManager: VpnBackgroundTaskManager = new VpnBackgroundTaskManager();
