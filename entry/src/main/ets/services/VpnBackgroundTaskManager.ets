import { bundleManager, common, Want, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { rpc } from '@kit.IPCKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { StoragePaths } from './StoragePaths';
import { DiagnosticEventStore } from './DiagnosticEventStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'VpnBackgroundTask';
const BUNDLE_NAME: string = 'io.github.tailscaleohos';
const ENTRY_ABILITY_NAME: string = 'EntryAbility';
const VPN_EXTENSION_ABILITY_NAME: string = 'TailscaleVpnExtensionAbility';
const VPN_STATUS_FRESH_MS: number = 15000;
const VPN_STATUS_GRACE_MS: number = 60000;
const CONNECTION_CHECK_INTERVAL_MS: number = 1000;
const NOTIFICATION_UPDATE_INTERVAL_MS: number = 30000;
// The Extension refreshes its heartbeat every second. Binding only against a
// heartbeat this recent keeps a bind from launching an Extension that just died
// (connectServiceExtensionAbility starts its target when it is not running).
const EXTENSION_BIND_MAX_HEARTBEAT_AGE_MS: number = 3000;
const EXTENSION_BIND_RETRY_MS: number = 10000;
const START_RETRY_BASE_MS: number = 30000;
const START_RETRY_MAX_MS: number = 300000;

interface VpnConnectionIntent {
  desired: boolean;
  requestedAtMs: number;
}

interface VpnRuntimeStatus {
  state: string;
  txBytes: number;
  rxBytes: number;
  heartbeatMs: number;
}

export class VpnBackgroundTaskManager {
  // Binding the protected UI process to the VPN Extension lifts it out of the
  // unbound low-memory-kill tier (oom_score_adj 500 -> 300/100 on device).
  private extensionConnectionId: number = -1;
  private extensionBindGeneration: number = 0;
  private nextExtensionBindAtMs: number = 0;
  // A lost or refused bind may mean the Extension process is gone; only a heartbeat
  // written after this moment proves a live Extension that is safe to bind again.
  private extensionBindNeedsHeartbeatAfterMs: number = 0;
  private context?: common.UIAbilityContext;
  private monitoring: boolean = false;
  private operationInFlight: boolean = false;
  private listenerRegistered: boolean = false;
  private suspendListenerRegistered: boolean = false;
  private lifecycleGeneration: number = 0;
  private cancellationRevision: number = 0;
  private startPending: boolean = false;
  private earlyCancellations: backgroundTaskManager.ContinuousTaskCancelInfo[] = [];
  private lastLiveHeartbeatMs: number = 0;
  private identityRetryAtMs: number = 0;
  private identityAttempts: number = 0;
  private monitorTimer: number = -1;
  private task?: backgroundTaskManager.ContinuousTaskNotification;
  private stopping: boolean = false;
  private cleanupPending: boolean = false;
  private suppressedUntilDisconnect: boolean = false;
  private nextStartAtMs: number = 0;
  private retryCount: number = 0;
  private lastLiveAtMs: number = 0;
  private nextNotificationAtMs: number = 0;
  private lastDiagnosticState: string = '';
  private lastStatusReadErrorCode: number = 0;
  private lastFailureSignature: string = '';
  private lastFailureAtMs: number = 0;

  private readonly cancelCallback =
    (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
      if (this.stopping) {
        return;
      }
      if (this.task === undefined || this.task.continuousTaskId === undefined) {
        if (this.startPending || this.task !== undefined) {
          // Wait for the returned task ID before a cancellation can affect us.
          const previous: number = this.earlyCancellations.findIndex(
            (item: backgroundTaskManager.ContinuousTaskCancelInfo) => item.id === info.id);
          if (previous >= 0) {
            this.earlyCancellations[previous] = info;
          } else if (this.earlyCancellations.length < 32) {
            this.earlyCancellations.push(info);
          }
        }
        return;
      }
      if (this.task.continuousTaskId === undefined || info.id !== this.task.continuousTaskId) {
        return;
      }
      // Only a matching system task ID can cancel this VPN's protection.
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
    this.monitoring = true;
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
      } catch (error) {
        this.record('background_listener_remove_failed', (error as BusinessError).code ?? -1);
      }
      this.listenerRegistered = false;
    }
    if (this.suspendListenerRegistered) {
      try {
        backgroundTaskManager.off('continuousTaskSuspend', this.suspendCallback);
      } catch (error) {
        this.record('background_suspend_listener_remove_failed', (error as BusinessError).code ?? -1);
      }
      this.suspendListenerRegistered = false;
    }
    if (this.context !== undefined) {
      this.unbindVpnExtension(this.context);
      this.reconcile(this.context);
    }
  }

  onBackground(context: common.UIAbilityContext): void {
    this.record('background_entered');
    this.reconcile(context);
  }

  onForeground(context: common.UIAbilityContext): void {
    // Foreground permits retrying a system failure, not undoing user dismissal.
    this.nextStartAtMs = 0;
    this.retryCount = 0;
    this.reconcile(context);
  }

  private async reconcile(context: common.UIAbilityContext): Promise<void> {
    if (this.operationInFlight) {
      return;
    }
    this.operationInFlight = true;
    const generation: number = this.lifecycleGeneration;
    try {
      if (this.cleanupPending) {
        await this.stop(context);
        if (this.cleanupPending) return;
      }
      if (!this.monitoring) {
        await this.stop(context);
        return;
      }
      const status: VpnRuntimeStatus = this.readStatus(context.filesDir);
      if (status.state !== this.lastDiagnosticState) {
        this.lastDiagnosticState = status.state;
        this.record('background_runtime_' + status.state, this.lastStatusReadErrorCode);
      }
      if (status.state === 'disconnected') {
        this.suppressedUntilDisconnect = false;
        this.nextStartAtMs = 0;
        this.nextExtensionBindAtMs = 0;
        this.retryCount = 0;
        this.lastLiveAtMs = 0;
        await this.stop(context);
        return;
      }
      if (status.state !== 'connected') {
        if (this.task === undefined && !this.suppressedUntilDisconnect &&
          Date.now() >= this.nextStartAtMs && this.hasPendingConnectIntent(context.filesDir)) {
          // Acquire protection before backgrounding so the UI is not frozen
          // while the VPN extension is still completing initial handshake.
          this.lastLiveAtMs = Math.max(this.lastLiveAtMs, this.connectionRequestedAtMs(context.filesDir));
          await this.start(context, generation, true);
        }
        // Missing telemetry is uncertain. Retain an acquired task briefly,
        // but never acquire a new task based on stale connection evidence.
        if (this.task !== undefined && Date.now() - this.lastLiveAtMs > VPN_STATUS_GRACE_MS) {
          this.record('background_status_timeout');
          await this.stop(context);
        }
        if (this.task === undefined && this.extensionConnectionId >= 0 &&
          Date.now() - this.lastLiveAtMs > VPN_STATUS_GRACE_MS) {
          this.unbindVpnExtension(context);
        }
        if (this.monitoring && generation === this.lifecycleGeneration && this.task !== undefined) {
          await this.resolvePendingIdentity(context, generation);
        }
        return;
      }
      this.lastLiveAtMs = Date.now();
      this.bindVpnExtension(context, status);
      if (this.task === undefined && !this.suppressedUntilDisconnect && Date.now() >= this.nextStartAtMs) {
        await this.start(context, generation);
      }
      if (this.monitoring && generation === this.lifecycleGeneration && this.task !== undefined) {
        if (!await this.resolvePendingIdentity(context, generation)) return;
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
    }
  }

  private async start(context: common.UIAbilityContext, generation: number,
    allowPendingConnect: boolean = false): Promise<void> {
    const revision: number = this.cancellationRevision;
    const info: wantAgent.WantAgentInfo = {
      wants: [{ bundleName: BUNDLE_NAME, abilityName: ENTRY_ABILITY_NAME }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 1001,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    const agent: WantAgent = await wantAgent.getWantAgent(info);
    const preState: string = this.readStatus(context.filesDir).state;
    const preAllowed: boolean = preState === 'connected' ||
      (allowPendingConnect && preState !== 'disconnected' && this.hasPendingConnectIntent(context.filesDir));
    if (!this.monitoring || generation !== this.lifecycleGeneration ||
      revision !== this.cancellationRevision || !preAllowed) {
      return;
    }
    // The numeric overload returns void and cannot supply the system-owned
    // notification ID needed for DATA_TRANSFER live-view updates.
    this.startPending = true;
    this.earlyCancellations = [];
    let task: backgroundTaskManager.ContinuousTaskNotification;
    try {
      task = await this.startDataTransferTask(context, agent);
      if (task.continuousTaskId === undefined) {
        try {
          const tasks: backgroundTaskManager.ContinuousTaskInfo[] =
            await backgroundTaskManager.getAllContinuousTasks(context, true);
          const match: backgroundTaskManager.ContinuousTaskInfo | undefined = tasks.find(
            (item: backgroundTaskManager.ContinuousTaskInfo) => item.abilityName === ENTRY_ABILITY_NAME &&
              item.notificationId === task.notificationId && item.backgroundModes.includes('dataTransfer'));
          if (match !== undefined) { task.continuousTaskId = match.continuousTaskId; }
        } catch (error) {
          this.record('background_task_id_query_failed', (error as BusinessError).code ?? -1);
        }
      }
    } catch (error) {
      this.earlyCancellations = [];
      throw error as Error;
    } finally {
      this.startPending = false;
    }
    if (task.continuousTaskId === undefined) {
      // No identity means no safe cancellation matching or publication. Keep
      // ownership, do not create another task, and retry identity separately.
      this.task = task;
      const pendingState: string = this.readStatus(context.filesDir).state;
      if (!this.monitoring || generation !== this.lifecycleGeneration || pendingState === 'disconnected' ||
        (allowPendingConnect && pendingState !== 'connected' && !this.hasPendingConnectIntent(context.filesDir))) {
        await this.stop(context);
        return;
      }
      this.identityAttempts = 0;
      this.identityRetryAtMs = Date.now() + START_RETRY_BASE_MS;
      this.record('background_task_identity_pending');
      return;
    }
    const earlyCancellation: backgroundTaskManager.ContinuousTaskCancelInfo | undefined =
      this.earlyCancellations.find((info: backgroundTaskManager.ContinuousTaskCancelInfo) =>
        info.id === task.continuousTaskId);
    this.earlyCancellations = [];
    this.task = task;
    if (earlyCancellation !== undefined) {
      // The system already removed this exact task; honor its reason without
      // publishing or stopping an unrelated task created in the meantime.
      this.cancelCallback(earlyCancellation);
      return;
    }
    if (revision !== this.cancellationRevision) {
      await this.stop(context);
      return;
    }
    const postState: string = this.readStatus(context.filesDir).state;
    if (!this.monitoring || generation !== this.lifecycleGeneration || postState === 'disconnected' ||
      (allowPendingConnect && postState !== 'connected' && !this.hasPendingConnectIntent(context.filesDir))) {
      await this.stop(context);
      return;
    }
    this.nextNotificationAtMs = 0;
    this.record('background_started');
    hilog.info(DOMAIN, TAG, 'VPN DATA_TRANSFER background task started. id=%{public}d',
      task.continuousTaskId ?? -1);
  }

  private async resolvePendingIdentity(context: common.UIAbilityContext, generation: number): Promise<boolean> {
    const task: backgroundTaskManager.ContinuousTaskNotification | undefined = this.task;
    if (task === undefined) return false;
    if (task.continuousTaskId !== undefined) return true;
    if (Date.now() < this.identityRetryAtMs || this.identityAttempts >= 5) return false;
    this.identityAttempts++;
    this.identityRetryAtMs = Date.now() + START_RETRY_BASE_MS;
    try {
      const tasks: backgroundTaskManager.ContinuousTaskInfo[] =
        await backgroundTaskManager.getAllContinuousTasks(context, true);
      if (this.task !== task) return false;
      if (!this.monitoring || generation !== this.lifecycleGeneration) {
        await this.stop(context);
        return false;
      }
      const match: backgroundTaskManager.ContinuousTaskInfo | undefined = tasks.find(
        (item: backgroundTaskManager.ContinuousTaskInfo) => item.abilityName === ENTRY_ABILITY_NAME &&
          item.notificationId === task.notificationId && item.backgroundModes.includes('dataTransfer'));
      if (match === undefined) {
        this.task = undefined;
        this.earlyCancellations = [];
        // The task disappeared before its ID became known. Never resurrect a
        // possibly user-cancelled task merely because telemetry is still live.
        this.suppressedUntilDisconnect = true;
        return false;
      }
      task.continuousTaskId = match.continuousTaskId;
      const cancelled: backgroundTaskManager.ContinuousTaskCancelInfo | undefined =
        this.earlyCancellations.find((info: backgroundTaskManager.ContinuousTaskCancelInfo) => info.id === task.continuousTaskId);
      this.earlyCancellations = [];
      if (cancelled !== undefined) { this.cancelCallback(cancelled); return false; }
      if (this.readStatus(context.filesDir).state === 'disconnected') { await this.stop(context); return false; }
      return true;
    } catch (error) {
      if (this.task === task && (!this.monitoring || generation !== this.lifecycleGeneration)) {
        await this.stop(context);
      }
      this.record('background_task_id_query_failed', (error as BusinessError).code ?? -1);
      return false;
    }
  }

  private async stop(context: common.UIAbilityContext): Promise<void> {
    this.unbindVpnExtension(context);
    if (this.task === undefined) {
      this.cleanupPending = false;
      return;
    }
    this.stopping = true;
    this.cleanupPending = true;
    try {
      let id: number | undefined = this.task.continuousTaskId;
      if (id === undefined) {
        const tasks: backgroundTaskManager.ContinuousTaskInfo[] =
          await backgroundTaskManager.getAllContinuousTasks(context, true);
        id = tasks.find((item: backgroundTaskManager.ContinuousTaskInfo) =>
          item.abilityName === ENTRY_ABILITY_NAME && item.notificationId === this.task?.notificationId
        )?.continuousTaskId;
      }
      if (id !== undefined) await backgroundTaskManager.stopBackgroundRunning(context, id);
      this.task = undefined;
      this.cleanupPending = false;
      this.earlyCancellations = [];
      this.identityAttempts = 0;
      this.identityRetryAtMs = 0;
      this.record('background_stopped');
    } catch (error) {
      this.record('background_stop_failed', (error as BusinessError).code ?? -1);
    } finally {
      this.stopping = false;
    }
  }

  private async updateNotification(context: common.UIAbilityContext, status: VpnRuntimeStatus): Promise<void> {
    const task: backgroundTaskManager.ContinuousTaskNotification | undefined = this.task;
    if (task === undefined || task.continuousTaskId === undefined || Date.now() < this.nextNotificationAtMs) {
      return;
    }
    this.nextNotificationAtMs = Date.now() + NOTIFICATION_UPDATE_INTERVAL_MS;
    const title: string = context.resourceManager.getStringByNameSync('notification_vpn_background_title');
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
        // A tunnel has no completion percentage. Never invent cyclic progress
        // or traffic: leave progress at zero and display actual byte counters.
        data: { title: title, fileName: traffic, progressValue: 0 }
      }
    };
    try {
      await notificationManager.publish(request);
    } catch (error) {
      this.record('background_notification_failed', (error as BusinessError).code ?? -1);
    }
  }

  private bindVpnExtension(context: common.UIAbilityContext, status: VpnRuntimeStatus): void {
    const now: number = Date.now();
    if (!this.monitoring || this.extensionConnectionId >= 0 || now < this.nextExtensionBindAtMs ||
      status.heartbeatMs <= 0 ||
      status.heartbeatMs <= this.extensionBindNeedsHeartbeatAfterMs ||
      now - status.heartbeatMs > EXTENSION_BIND_MAX_HEARTBEAT_AGE_MS ||
      typeof context.connectServiceExtensionAbility !== 'function') {
      return;
    }
    const bindGeneration: number = ++this.extensionBindGeneration;
    const options: common.ConnectOptions = {
      onConnect: (_element: bundleManager.ElementName, _remote: rpc.IRemoteObject): void => {
        if (bindGeneration !== this.extensionBindGeneration) {
          return;
        }
        this.record('vpn_extension_bind_connected');
      },
      onDisconnect: (_element: bundleManager.ElementName): void => {
        if (bindGeneration !== this.extensionBindGeneration) {
          return;
        }
        // The Extension process ended (stopped, or killed by the system).
        this.releaseExtensionBinding(false);
        this.record('vpn_extension_bind_disconnected');
      },
      onFailed: (code: number): void => {
        if (bindGeneration !== this.extensionBindGeneration) {
          return;
        }
        this.releaseExtensionBinding(true);
        this.record('vpn_extension_bind_failed', code);
      }
    };
    const parameters: Record<string, Object> = { 'mesharcBindOnly': true };
    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: VPN_EXTENSION_ABILITY_NAME,
      parameters: parameters
    };
    try {
      const id: number = context.connectServiceExtensionAbility(want, options);
      if (bindGeneration !== this.extensionBindGeneration) {
        if (id >= 0 && typeof context.disconnectServiceExtensionAbility === 'function') {
          try {
            context.disconnectServiceExtensionAbility(id).catch((): void => {});
          } catch (_disconnectError) {
            // Best-effort cleanup of a handle superseded synchronously.
          }
        }
        return;
      }
      if (id < 0) {
        this.releaseExtensionBinding(true);
        this.record('vpn_extension_bind_error', id);
        return;
      }
      this.extensionConnectionId = id;
      this.record('vpn_extension_bind_requested');
    } catch (error) {
      if (bindGeneration === this.extensionBindGeneration) {
        this.releaseExtensionBinding(true);
      }
      this.record('vpn_extension_bind_error', (error as BusinessError).code ?? -1);
    }
  }

  private releaseExtensionBinding(retryLater: boolean): void {
    this.extensionBindGeneration++;
    this.extensionConnectionId = -1;
    this.extensionBindNeedsHeartbeatAfterMs = Date.now();
    if (retryLater) {
      this.nextExtensionBindAtMs = Date.now() + EXTENSION_BIND_RETRY_MS;
    }
  }

  private unbindVpnExtension(context: common.UIAbilityContext): void {
    const id: number = this.extensionConnectionId;
    if (id < 0) {
      return;
    }
    this.releaseExtensionBinding(false);
    this.nextExtensionBindAtMs = 0;
    if (typeof context.disconnectServiceExtensionAbility !== 'function') {
      return;
    }
    try {
      context.disconnectServiceExtensionAbility(id).catch((): void => {
        // Best-effort: the system drops the connection when either process exits.
      });
    } catch (_error) {
      // Same as above for a synchronous rejection.
    }
  }

  private readStatus(filesDir: string): VpnRuntimeStatus {
    const result: VpnRuntimeStatus = { state: 'unknown', txBytes: 0, rxBytes: 0, heartbeatMs: 0 };
    this.lastStatusReadErrorCode = 0;
    try {
      const status: string = fileIo.readTextSync(StoragePaths.vpnStatusPath(filesDir));
      const heartbeatMs: number = this.statusNumber(status, 'heartbeatMs');
      const ageMs: number = Date.now() - heartbeatMs;
      if (heartbeatMs <= 0 || ageMs < 0) {
        return result;
      }
      const normalized: string = status.toLowerCase();
      if (normalized.includes('extension destroyed') || normalized.includes('vpn disconnected') ||
        normalized.includes('state=stopped') || normalized.startsWith('stopped') ||
        (normalized.startsWith('failed') && !normalized.includes('status unavailable'))) {
        // Terminal records are written once. They can be stale by the time
        // the UI resumes, but must belong to this connection, not an old one.
        const sessionBoundaryMs: number = Math.max(this.lastLiveHeartbeatMs,
          this.connectionRequestedAtMs(filesDir));
        if (heartbeatMs >= sessionBoundaryMs) { result.state = 'disconnected'; }
      } else if (ageMs <= VPN_STATUS_FRESH_MS &&
        normalized.includes('state=running') && normalized.includes('tun=true')) {
        this.lastLiveHeartbeatMs = Math.max(this.lastLiveHeartbeatMs, heartbeatMs);
        result.state = 'connected';
        result.txBytes = this.statusNumber(status, 'txBytes');
        result.rxBytes = this.statusNumber(status, 'rxBytes');
        result.heartbeatMs = heartbeatMs;
      }
    } catch (error) {
      // Atomic file replacement or temporary I/O failure is uncertain state.
      this.lastStatusReadErrorCode = (error as BusinessError).code ?? -1;
    }
    return result;
  }

  private startDataTransferTask(context: common.UIAbilityContext,
    agent: WantAgent): Promise<backgroundTaskManager.ContinuousTaskNotification> {
    if (typeof backgroundTaskManager.ContinuousTaskRequest === 'function' &&
      backgroundTaskManager.BackgroundTaskMode !== undefined &&
      backgroundTaskManager.BackgroundTaskSubmode !== undefined) {
      const request: backgroundTaskManager.ContinuousTaskRequest = new backgroundTaskManager.ContinuousTaskRequest();
      request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_DATA_TRANSFER];
      request.backgroundTaskSubmodes = [backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_LIVE_VIEW_NOTIFICATION];
      request.wantAgent = agent;
      request.combinedTaskNotification = false;
      return backgroundTaskManager.startBackgroundRunning(context, request);
    }
    return backgroundTaskManager.startBackgroundRunning(context, ['dataTransfer'], agent);
  }

  private hasPendingConnectIntent(filesDir: string): boolean {
    const requestedAtMs: number = this.connectionRequestedAtMs(filesDir);
    const ageMs: number = Date.now() - requestedAtMs;
    return requestedAtMs > 0 && ageMs >= 0 && ageMs <= VPN_STATUS_GRACE_MS;
  }

  private connectionRequestedAtMs(filesDir: string): number {
    try {
      const intent: VpnConnectionIntent = JSON.parse(
        fileIo.readTextSync(`${filesDir}/vpn-connect-intent.json`)) as VpnConnectionIntent;
      return intent.desired === true && Number.isSafeInteger(intent.requestedAtMs) &&
        intent.requestedAtMs > 0 && intent.requestedAtMs <= Date.now() ? intent.requestedAtMs : 0;
    } catch (_error) {
      // Older installations and a temporary IPC replacement still retain the
      // last confirmed live heartbeat as the lower session boundary.
      return 0;
    }
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
    const failure: boolean = event.includes('failed') || event.includes('timeout');
    const signature: string = event + ':' + code;
    if (failure && signature === this.lastFailureSignature && Date.now() - this.lastFailureAtMs < 30000) {
      return;
    }
    if (failure) {
      this.lastFailureSignature = signature;
      this.lastFailureAtMs = Date.now();
      hilog.error(DOMAIN, TAG, '%{public}s code=%{public}d', event, code);
    } else {
      this.lastFailureSignature = '';
      hilog.info(DOMAIN, TAG, '%{public}s code=%{public}d', event, code);
    }
    if (this.context !== undefined) {
      DiagnosticEventStore.recordDetailed(this.context.filesDir, 'ui', event, 'background', code, {
        lifecycleGeneration: this.lifecycleGeneration, cancellationRevision: this.cancellationRevision,
        retryCount: this.retryCount, retryDelayMs: Math.max(0, this.nextStartAtMs - Date.now()),
        taskActive: this.task !== undefined, userSuppressed: this.suppressedUntilDisconnect
      });
    }
  }
}
