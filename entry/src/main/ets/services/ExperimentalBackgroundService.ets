import { abilityAccessCtrl, common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { PiPWindow, typeNode, UIContext } from '@kit.ArkUI';
import { geoLocationManager } from '@kit.LocationKit';
import { notificationManager } from '@kit.NotificationKit';
import { DiagnosticEventStore } from './DiagnosticEventStore';
import { SimulatedDownload } from './SimulatedDownload';
import { fileIo } from '@kit.CoreFileKit';
import { PipTrafficChart } from '../components/PipTrafficChart';
import { PipTrafficHistory, PipTrafficRate } from './PipTrafficHistory';

export type ExperimentalBackgroundMode = 'location' | 'pip' | 'audio' | 'download';

/** Session-only experimental controls owned by EntryAbility, independent of settings view lifetime. */
export class ExperimentalBackgroundService {
  private static shared: ExperimentalBackgroundService = new ExperimentalBackgroundService();
  private context?: common.UIAbilityContext;
  private closed: boolean = true;
  private generation: number = 0;
  private queue: Promise<void> = Promise.resolve();
  private listeners: Set<() => void> = new Set<() => void>();
  private active: Set<ExperimentalBackgroundMode> = new Set<ExperimentalBackgroundMode>();
  private tasks: Map<ExperimentalBackgroundMode, backgroundTaskManager.ContinuousTaskNotification> =
    new Map<ExperimentalBackgroundMode, backgroundTaskManager.ContinuousTaskNotification>();
  private pendingTask: boolean = false;
  private earlyCancellations: Set<number> = new Set<number>();
  private renderer?: audio.AudioRenderer;
  private pip?: PiPWindow.PiPController;
  private pipNode?: typeNode.XComponent;
  private pipRunning: boolean = false;
  private pipTrafficChart?: PipTrafficChart;
  private pipTrafficTimer: number = -1;
  private download: SimulatedDownload = new SimulatedDownload();
  private nextProgressMs: number = 0;
  private locating: boolean = false;
  private errorCode: number = 0;
  private locationCallback = (_location: geoLocationManager.Location): void => {};

  static instance(): ExperimentalBackgroundService { return ExperimentalBackgroundService.shared; }

  initialize(context: common.UIAbilityContext): void {
    this.context = context;
    this.closed = false;
    this.generation++;
    try { backgroundTaskManager.on('continuousTaskCancel', this.cancelCallback); }
    catch (error) { this.errorCode = (error as BusinessError).code ?? -1; }
  }

  isActive(mode: ExperimentalBackgroundMode): boolean { return this.active.has(mode); }
  lastError(): number { return this.errorCode; }
  subscribe(callback: () => void): void { this.listeners.add(callback); }
  unsubscribe(callback: () => void): void { this.listeners.delete(callback); }

  setEnabled(mode: ExperimentalBackgroundMode, enabled: boolean, ui: UIContext): Promise<void> {
    const generation: number = this.generation;
    return this.enqueue(async () => {
      if (this.closed || generation !== this.generation) return;
      this.errorCode = 0;
      if (enabled && this.active.has(mode)) return;
      try {
        if (enabled) {
          await this.startMode(mode, ui);
          if (this.closed || generation !== this.generation) {
            await this.stopMode(mode);
            return;
          }
          this.active.add(mode);
        } else {
          await this.stopMode(mode);
        }
        this.record(enabled ? 'experiment_started_' + mode : 'experiment_stopped_' + mode);
      } catch (error) {
        this.errorCode = (error as BusinessError).code ?? -1;
        this.record('experiment_failed_' + mode, this.errorCode);
        await this.stopMode(mode);
      } finally { this.notify(); }
    });
  }

  shutdown(): void {
    this.closed = true;
    this.generation++;
    try { backgroundTaskManager.off('continuousTaskCancel', this.cancelCallback); } catch (_error) {}
    void this.enqueue(async () => {
      for (const mode of ['location', 'pip', 'audio', 'download'] as ExperimentalBackgroundMode[]) {
        try { await this.stopMode(mode); }
        catch (error) { this.errorCode = (error as BusinessError).code ?? -1; }
      }
      this.notify();
    });
  }

  private enqueue(operation: () => Promise<void>): Promise<void> {
    this.queue = this.queue.then(operation).catch((error: BusinessError) => {
      this.errorCode = error.code ?? -1;
      this.record('experiment_cleanup_failed', this.errorCode);
      this.notify();
    });
    return this.queue;
  }

  private readonly cancelCallback = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
    const mode: ExperimentalBackgroundMode | undefined = Array.from(this.tasks.keys()).find(
      (key: ExperimentalBackgroundMode) => this.tasks.get(key)?.continuousTaskId === info.id);
    if (mode === undefined) {
      if (this.pendingTask && this.earlyCancellations.size < 32) this.earlyCancellations.add(info.id);
      return;
    }
    this.tasks.delete(mode);
    void this.enqueue(async () => {
      this.errorCode = info.reason;
      this.record('experiment_cancelled_' + mode, info.reason);
      await this.stopMode(mode);
      this.notify();
    });
  };

  private async startMode(mode: ExperimentalBackgroundMode, ui: UIContext): Promise<void> {
    const context: common.UIAbilityContext | undefined = this.context;
    if (context === undefined || this.closed) throw new Error('context_unavailable');
    if (mode === 'pip') {
      await this.startPip(context, ui);
      return;
    }
    if (mode === 'location') {
      if (!geoLocationManager.isLocationEnabled()) this.fail(3301100);
      const result = await abilityAccessCtrl.createAtManager()
        .requestPermissionsFromUser(context, ['ohos.permission.APPROXIMATELY_LOCATION']);
      if (result.authResults[0] !== 0) this.fail(201);
    }
    if (this.closed) return;
    await this.startTask(context, mode);
    if (this.closed) return;
    if (mode === 'location') {
      geoLocationManager.on('locationChange', {
        priority: geoLocationManager.LocationRequestPriority.LOW_POWER,
        scenario: geoLocationManager.LocationRequestScenario.UNSET,
        timeInterval: 30, distanceInterval: 0, maxAccuracy: 0
      }, this.locationCallback);
      this.locating = true;
    } else if (mode === 'audio') {
      try {
        await audio.getAudioManager().getSessionManager().activateAudioSession({
          concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_MIX_WITH_OTHERS
        });
      } catch (_error) {}
      const renderer: audio.AudioRenderer = await audio.createAudioRenderer({
        streamInfo: {
          samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
          channels: audio.AudioChannel.CHANNEL_2,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        },
        rendererInfo: { usage: audio.StreamUsage.STREAM_USAGE_NAVIGATION, rendererFlags: 0 }
      });
      this.renderer = renderer;
      renderer.on('writeData', (buffer: ArrayBuffer): audio.AudioDataCallbackResult => {
        new Uint8Array(buffer).fill(0);
        return audio.AudioDataCallbackResult.VALID;
      });
      renderer.on('audioInterrupt', (event?: audio.InterruptEvent) => {
        if (event === undefined || (event.forceType === audio.InterruptForceType.INTERRUPT_FORCE &&
          (event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE ||
            event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP))) {
          this.resourceStopped('audio');
        }
      });
      if (!this.closed) await renderer.start();
    } else {
      this.nextProgressMs = 0;
      await this.download.start((bytes: number) => this.updateProgress(bytes),
        (code: number) => this.resourceStopped('download', code));
    }
  }

  private async startTask(context: common.UIAbilityContext, mode: ExperimentalBackgroundMode): Promise<void> {
    const agent: WantAgent = await wantAgent.getWantAgent({
      wants: [{ bundleName: 'io.github.tailscaleohos', abilityName: 'EntryAbility' }],
      actionType: wantAgent.OperationType.START_ABILITY, requestCode: 2100,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
    if (this.closed) return;
    const taskMode: backgroundTaskManager.BackgroundTaskMode = mode === 'location' ?
      backgroundTaskManager.BackgroundTaskMode.MODE_LOCATION : mode === 'audio' ?
        backgroundTaskManager.BackgroundTaskMode.MODE_AUDIO_PLAYBACK :
        backgroundTaskManager.BackgroundTaskMode.MODE_DATA_TRANSFER;
    this.pendingTask = true;
    this.earlyCancellations.clear();
    try {
      const request: backgroundTaskManager.ContinuousTaskRequest = new backgroundTaskManager.ContinuousTaskRequest();
      request.backgroundTaskModes = [taskMode];
      request.backgroundTaskSubmodes = [mode === 'download' ?
        backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_LIVE_VIEW_NOTIFICATION :
        backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_NORMAL_NOTIFICATION];
      request.wantAgent = agent;
      request.combinedTaskNotification = false;
      const task: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(context, request);
      this.tasks.set(mode, task);
      if (task.continuousTaskId === undefined) throw new Error('task_identity_unavailable');
      if (this.earlyCancellations.has(task.continuousTaskId)) {
        this.tasks.delete(mode);
        throw new Error('task_cancelled_during_start');
      }
    } finally {
      this.pendingTask = false;
      this.earlyCancellations.clear();
    }
  }

  private async startPip(context: common.UIAbilityContext, ui: UIContext): Promise<void> {
    if (!PiPWindow.isPiPEnabled()) this.fail(801);
    const controller: XComponentController = new XComponentController();
    const node: typeNode.XComponent = typeNode.createNode(ui, 'XComponent', {
      type: XComponentType.SURFACE, controller: controller });
    this.pipNode = node;
    const chart: PipTrafficChart = new PipTrafficChart();
    this.pipTrafficChart = chart;
    const pip: PiPWindow.PiPController = await PiPWindow.create({
      context: context,
      componentController: controller,
      templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY,
      contentWidth: 96,
      contentHeight: 96,
      controlGroups: [],
      customUIController: chart,
      defaultWindowSizeType: 1,
      cornerAdsorptionEnabled: true
    }, node);
    this.pip = pip;
    this.pipRunning = false;
    pip.on('stateChange', (state: PiPWindow.PiPState) => {
      if (state === PiPWindow.PiPState.ABOUT_TO_START || state === PiPWindow.PiPState.STARTED) {
        this.pipRunning = true;
      } else if (state === PiPWindow.PiPState.STOPPED || state === PiPWindow.PiPState.ERROR) {
        this.pipRunning = false;
        this.stopPipTrafficSampling();
        this.resourceStopped('pip', state === PiPWindow.PiPState.ERROR ? 1300014 : 0);
      }
    });
    try { pip.setAutoStartEnabled(true); } catch (_error) {}
    try { pip.updateContentSize(96, 96); } catch (_error) {}
    if (!this.closed) {
      await pip.startPiP();
      this.pipRunning = true;
      this.startPipTrafficSampling(context.filesDir, chart);
    }
  }

  private startPipTrafficSampling(filesDir: string, chart: PipTrafficChart): void {
    const path: string = `${filesDir}/vpn-probe-status.txt`;
    const history: PipTrafficHistory = new PipTrafficHistory();
    const sample = (): void => {
      let status: string = '';
      try { status = fileIo.readTextSync(path); } catch (_error) {}
      const rates: PipTrafficRate[] | undefined = history.update(status, Date.now());
      if (rates !== undefined) chart.update(rates);
    };
    sample();
    this.pipTrafficTimer = setInterval(sample, 1000);
  }

  private stopPipTrafficSampling(): void {
    if (this.pipTrafficTimer >= 0) {
      clearInterval(this.pipTrafficTimer);
      this.pipTrafficTimer = -1;
    }
  }

  private resourceStopped(mode: ExperimentalBackgroundMode, code: number = -1): void {
    void this.enqueue(async () => {
      this.errorCode = code;
      this.record('experiment_interrupted_' + mode, code);
      await this.stopMode(mode);
      this.notify();
    });
  }

  private async stopMode(mode: ExperimentalBackgroundMode): Promise<void> {
    // Keep a failed cleanup visible so the user can retry switching it off.
    this.active.add(mode);
    if (mode === 'location' && this.locating) {
      geoLocationManager.off('locationChange', this.locationCallback);
      this.locating = false;
    }
    if (mode === 'audio') {
      if (this.renderer !== undefined) {
        const renderer: audio.AudioRenderer = this.renderer;
        renderer.off('audioInterrupt');
        try { await renderer.stop(); } catch (_error) {}
        await renderer.release();
        this.renderer = undefined;
      }
      try {
        await audio.getAudioManager().getSessionManager().deactivateAudioSession();
      } catch (_error) {}
    }
    if (mode === 'pip') this.stopPipTrafficSampling();
    if (mode === 'pip' && this.pip !== undefined) {
      const pip: PiPWindow.PiPController = this.pip;
      pip.off('stateChange');
      try { pip.setAutoStartEnabled(false); } catch (_error) {}
      const shouldStop: boolean = this.pipRunning || (await pip.isPiPActive());
      this.pipRunning = false;
      if (shouldStop) {
        try { await pip.stopPiP(); } catch (_error) {}
      }
      this.pip = undefined;
    }
    if (mode === 'pip') {
      this.pipTrafficChart?.dispose();
      this.pipTrafficChart = undefined;
      const node: typeNode.XComponent | undefined = this.pipNode;
      this.pipNode = undefined;
      if (node !== undefined) {
        try { node.dispose(); } catch (_error) {}
      }
    }
    if (mode === 'download') await this.download.stop();
    const task: backgroundTaskManager.ContinuousTaskNotification | undefined = this.tasks.get(mode);
    if (task !== undefined && this.context !== undefined) {
      let id: number | undefined = task.continuousTaskId;
      if (id === undefined) {
        const tasks: backgroundTaskManager.ContinuousTaskInfo[] =
          await backgroundTaskManager.getAllContinuousTasks(this.context, true);
        id = tasks.find((item: backgroundTaskManager.ContinuousTaskInfo) =>
          item.notificationId === task.notificationId && item.abilityName === 'EntryAbility')?.continuousTaskId;
      }
      if (id !== undefined) await backgroundTaskManager.stopBackgroundRunning(this.context, id);
      this.tasks.delete(mode);
    }
    this.active.delete(mode);
  }

  private updateProgress(bytes: number): void {
    const task: backgroundTaskManager.ContinuousTaskNotification | undefined = this.tasks.get('download');
    const context: common.UIAbilityContext | undefined = this.context;
    if (task === undefined || context === undefined || this.closed || Date.now() < this.nextProgressMs) return;
    this.nextProgressMs = Date.now() + 30000;
    const title: string = context.resourceManager.getStringByNameSync('background_running_download');
    const progress: number = Math.floor(bytes / 4096) % 100;
    void notificationManager.publish({ id: task.notificationId,
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW, isAlertOnce: true,
      content: { notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
        systemLiveView: { typeCode: 8, title: title, text: `${bytes} B` } },
      template: { name: 'downloadTemplate', data: { title: title, fileName: `${bytes} B`, progressValue: progress } }
    }).catch((error: BusinessError) => this.record('experiment_notification_failed_download', error.code ?? -1));
  }

  private notify(): void {
    this.listeners.forEach((callback: () => void) => { try { callback(); } catch (_error) {} });
  }

  private fail(code: number): never {
    const error: Error = new Error('experimental_background_failed');
    (error as BusinessError).code = code;
    throw error;
  }

  private record(event: string, code: number = 0): void {
    try {
      if (this.context !== undefined) DiagnosticEventStore.record(this.context.filesDir, 'ui', event, 'experiment', code);
    } catch (_error) {}
  }
}
