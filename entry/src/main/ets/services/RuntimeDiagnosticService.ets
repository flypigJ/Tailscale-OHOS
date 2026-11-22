import { process } from '@kit.ArkTS';
import { RUNTIME_BUILD_FINGERPRINT } from './RuntimeDiagnosticBuild';
import { AbilityConstant } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { power, batteryInfo } from '@kit.BasicServicesKit';
import { hidebug, hiAppEvent } from '@kit.PerformanceAnalysisKit';

const SEGMENT_BYTES: number = 2 * 1024 * 1024;
const SEGMENTS: number = 4;
const HEARTBEAT_MS: number = 300000;
const KILL_REASONS: string[] = ['LowMemoryKill', 'SwapFull', 'ResourceLeak(IonLeak)',
  'ResourceLeak(GpuRsLeak)', 'ResourceLeak(GpuLeak)', 'ResourceLeak(AshmemLeak)', 'ResourceLeak(CES)',
  'ResourceLeak(PSSSoftLeak)', 'ResourceLeak(PSSLeak)', 'ResourceLeak(VMALeak)', 'ResourceLeak(FDLeak)',
  'ResourceLeak(ThreadLeak)', 'ResourceLeak(KernelZoneLeak)', 'IllegalAudioRendererBySuspend',
  'PowerSaveClean', 'VrsKill', 'RssThresholdKiller', 'OomKiller', 'CpaKiller', 'KillApplication',
  'OnRemoteDied', 'Restart', 'UserRequest', 'Uninstall', 'Upgrade', 'Logout', 'PermissionUpdate',
  'aaForceStop', 'ThreadBlock6S', 'AppInputBlock', 'LifecycleTimeout', 'JsError', 'CppCrash',
  'RSPixelMapFdOverLimit', 'CPUHighloadNotify', 'CPUHighloadUserRequest', 'IllegalAudioCapturerBySuspend',
  'IOHighload', 'AppFreeze', 'MaliciousContinuousTaskActive', 'RsDataOverflow', 'HighTemperature',
  'TransientTaskTimeout', 'TooManyReadyThreads', 'JsHeapSleepCleanKill', 'HardwareDecodingResourcesLimit',
  'AppRecoveryNotifyAppOverLimit', 'GpuError', 'NotAttachedToStatusBar', 'CPUHighload', 'AshmemKiller',
  'GpuKiller', 'DmaKiller', 'ThreadKiller', 'UninstallStorage'];

interface RuntimeRecord {
  timestampMs: number;
  source: string;
  event: string;
  phase: string;
  code: number;
}

/** Rolling recorder and redacted local/opt-in diagnostic spool. */
export class RuntimeDiagnosticService {
  private filesDir: string = '';
  private source: string = 'ui';
  private timer: number = -1;
  private watcher?: hiAppEvent.Watcher;
  private lastHeartbeat: number = 0;
  private lastCounters: number[] = [-1, -1, -1, -1];
  private pendingSample?: RuntimeRecord[];
  private static bootMs: number = Date.now();
  private static sequences: number[] = [0, 0];
  private static writeFailures: number[] = [0, 0];
  private static damagedSegments: boolean[] = [false, false];

  start(filesDir: string, source: string, launch?: AbilityConstant.LaunchParam): void {
    this.stop();
    this.filesDir = filesDir;
    this.source = source === 'vpn' ? 'vpn' : 'ui';
    this.mark('session_started');
    this.mark('runtime_schema', 2);
    this.mark('runtime_build_' + RUNTIME_BUILD_FINGERPRINT);
    if (launch !== undefined) {
      this.mark('previous_exit_reason', launch.lastExitReason);
      this.mark('launch_reason', launch.launchReason);
      const detail: AbilityConstant.LastExitDetailInfo | undefined = launch.lastExitDetailInfo;
      if (detail !== undefined) {
        this.mark('previous_exit_time_ms', detail.timestamp);
        this.mark('previous_exit_rss_kb', detail.rss);
        this.mark('previous_exit_pss_kb', detail.pss);
        this.mark('previous_exit_pid', detail.pid);
        this.mark('previous_exit_subreason', detail.exitSubReason);
        this.mark('previous_kill_reason_' + (detail.killReason !== undefined &&
          KILL_REASONS.includes(detail.killReason) ? detail.killReason : 'unknown'));
      }
      // Raw lastExitMessage and process names may contain user data.
      this.installWatcher();
    }
    this.lastCounters = [-1, -1, -1, -1];
    this.captureSample();
    this.lastHeartbeat = Date.now();
    this.timer = setInterval(() => {
      const now: number = Date.now();
      this.captureSample(now - this.lastHeartbeat);
      this.lastHeartbeat = now;
    }, HEARTBEAT_MS);
  }

  mark(event: string, code: number = 0): void {
    if (this.pendingSample !== undefined) {
      this.pendingSample.push({ timestampMs: Date.now(), source: this.source, event: event, phase: 'runtime', code: code });
      return;
    }
    RuntimeDiagnosticService.append(this.filesDir, this.source, event, 'runtime', code);
  }

  private captureSample(gapMs?: number): void {
    this.pendingSample = [];
    try {
      if (gapMs !== undefined) this.mark('heartbeat_gap_ms', gapMs);
      this.captureEnvironment();
      this.captureVpnStatus();
    } finally {
      const rows: RuntimeRecord[] = this.pendingSample;
      this.pendingSample = undefined;
      RuntimeDiagnosticService.appendRecords(this.filesDir, this.source, rows);
    }
  }

  stop(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
      this.mark('ability_destroyed');
    }
    if (this.watcher !== undefined) {
      try { hiAppEvent.removeWatcher(this.watcher); } catch (_error) {}
      this.watcher = undefined;
    }
  }

  static append(filesDir: string, source: string, event: string, phase: string, code: number): void {
    RuntimeDiagnosticService.appendRecords(filesDir, source,
      [{ timestampMs: Date.now(), source: source, event: event, phase: phase, code: code }]);
  }

  static appendRecords(filesDir: string, source: string, records: RuntimeRecord[]): void {
    if (filesDir.length === 0 || records.length === 0) return;
    const owner: string = source === 'vpn' ? 'vpn' : 'ui';
    const path: string = RuntimeDiagnosticService.path(filesDir, owner, 0);
    const slot: number = owner === 'vpn' ? 1 : 0;
    const rows: RuntimeRecord[] = records.slice(0, 64).map((item: RuntimeRecord): RuntimeRecord => {
      return { timestampMs: Number.isSafeInteger(item.timestampMs) ? item.timestampMs : Date.now(), source: owner,
        event: RuntimeDiagnosticService.token(item.event), phase: RuntimeDiagnosticService.token(item.phase),
        code: Number.isSafeInteger(item.code) ? item.code : -1 };
    });
    // Assigned before I/O so failed writes leave a sequence gap after recovery.
    RuntimeDiagnosticService.sequences[slot]++;
    const timestampMs: number = rows[0].timestampMs;
    const metadata: RuntimeRecord[] = [
      { timestampMs: timestampMs, source: owner, event: 'runtime_process_pid', phase: 'runtime', code: process.pid },
      { timestampMs: timestampMs, source: owner, event: 'runtime_boot_ms', phase: 'runtime', code: RuntimeDiagnosticService.bootMs },
      { timestampMs: timestampMs, source: owner, event: 'runtime_sequence', phase: 'runtime', code: RuntimeDiagnosticService.sequences[slot] }
    ];
    rows.unshift(...metadata);
    if (records.length > 64) rows.push({ timestampMs: Date.now(), source: owner,
      event: 'runtime_input_records_dropped', phase: 'runtime', code: records.length - 64 });
    const priorFailures: number = RuntimeDiagnosticService.writeFailures[slot];
    if (priorFailures > 0) rows.push({ timestampMs: Date.now(), source: owner,
      event: 'runtime_write_failures', phase: 'runtime', code: priorFailures });
    let content: string = rows.map((item: RuntimeRecord): string => JSON.stringify(item)).join('\n') + '\n';
    let file: fileIo.File | undefined;
    try {
      if (RuntimeDiagnosticService.damagedSegments[slot] ||
        (fileIo.accessSync(path) && fileIo.statSync(path).size + content.length > SEGMENT_BYTES)) {
        const oldest: string = RuntimeDiagnosticService.path(filesDir, owner, SEGMENTS - 1);
        const discarded: number = fileIo.accessSync(oldest) ? fileIo.statSync(oldest).size : 0;
        for (let index: number = SEGMENTS - 1; index > 0; index--) {
          const older: string = RuntimeDiagnosticService.path(filesDir, owner, index);
          const newer: string = RuntimeDiagnosticService.path(filesDir, owner, index - 1);
          if (fileIo.accessSync(older)) fileIo.unlinkSync(older);
          if (fileIo.accessSync(newer)) fileIo.renameSync(newer, older);
        }
        RuntimeDiagnosticService.damagedSegments[slot] = false;
        if (discarded > 0) {
          const lost: RuntimeRecord = { timestampMs: Date.now(), source: owner,
            event: 'runtime_retention_bytes_dropped', phase: 'runtime', code: discarded };
          content += JSON.stringify(lost) + '\n';
        }
      }
      file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.APPEND);
      let written: number = 0;
      // Records contain ASCII only, so byte and string offsets are identical.
      while (written < content.length) {
        const count: number = fileIo.writeSync(file.fd, content.substring(written));
        if (count <= 0) throw new Error('runtime_short_write');
        written += count;
      }
      fileIo.fsyncSync(file.fd);
      RuntimeDiagnosticService.writeFailures[slot] = 0;
    } catch (_error) {
      // The independent spool still gets this batch even when local retention fails.
      RuntimeDiagnosticService.writeFailures[slot] = Math.min(priorFailures + 1, 2147483647);
      RuntimeDiagnosticService.damagedSegments[slot] = true;
      const failure: RuntimeRecord = { timestampMs: Date.now(), source: owner,
        event: 'runtime_write_failed', phase: 'runtime', code: 1 };
      content += JSON.stringify(failure) + '\n';
    } finally {
      if (file !== undefined) {
        try { fileIo.closeSync(file); } catch (_error) {}
      }
    }
  }

  static exportFiles(filesDir: string, workDir: string): string[] {
    const paths: string[] = [];
    for (const owner of ['ui', 'vpn']) {
      for (let index: number = SEGMENTS - 1; index >= 0; index--) {
        const source: string = RuntimeDiagnosticService.path(filesDir, owner, index);
        if (!fileIo.accessSync(source)) continue;
        const destination: string = RuntimeDiagnosticService.path(workDir, owner, index);
        fileIo.copyFileSync(source, destination);
        paths.push(destination);
      }
    }
    return paths;
  }

  static fileNames(): string[] {
    const names: string[] = [];
    for (const owner of ['ui', 'vpn']) {
      for (let index: number = 0; index < SEGMENTS; index++) {
        names.push(`runtime-${owner}-${index}.ndjson`);
      }
    }
    return names;
  }

  private captureEnvironment(): void {
    try {
      this.mark('screen_active', power.isActive() ? 1 : 0);
      this.mark('power_mode', power.getPowerMode());
      this.mark('charging_state', batteryInfo.chargingStatus);
    } catch (_error) { this.mark('power_status_unavailable'); }
    try {
      const memory: hidebug.VMMemoryInfo = hidebug.getAppVMMemoryInfo();
      this.mark('vm_heap_used_kb', Number(memory.heapUsed));
      this.mark('vm_heap_total_kb', Number(memory.totalHeap));
    } catch (_error) { this.mark('vm_memory_unavailable'); }
  }

  private statusNumber(status: string, field: string): number {
    const match: RegExpMatchArray | null = status.match(
      new RegExp('(?:^|[\\s|])' + field + '=(\\d+)(?=[\\s|]|$)'));
    if (match === null) return -1;
    const value: number = Number(match[1]);
    return Number.isSafeInteger(value) ? value : -1;
  }

  private captureVpnStatus(): void {
    try {
      const status: string = fileIo.readTextSync(this.filesDir + '/vpn-probe-status.txt');
      this.mark('vpn_status_readable', 1);
      const heartbeat: number = this.statusNumber(status, 'heartbeatMs');
      const age: number = heartbeat > 0 ? Date.now() - heartbeat : -1;
      this.mark('vpn_status_heartbeat_valid', heartbeat > 0 && age >= 0 ? 1 : 0);
      this.mark('vpn_heartbeatMs', age);
      this.mark('vpn_status_stale', heartbeat <= 0 || age < 0 ? -1 : (age > HEARTBEAT_MS * 3 ? 1 : 0));
      const snapshot: number = this.statusNumber(status, 'snapshotMs');
      this.mark('vpn_snapshot_age_ms', snapshot > 0 ? Date.now() - snapshot : -1);
      // Fixed markers and counters are evidence of producer state, not a connectivity test.
      this.mark('vpn_status_running', /(?:^|[\s|])state=Running(?=[\s|]|$)/.test(status) ? 1 : 0);
      this.mark('vpn_status_tun', /(?:^|[\s|])tun=true(?=[\s|]|$)/.test(status) ? 1 : 0);
      const counters: string[] = ['tunRead', 'tunWrite', 'txBytes', 'rxBytes'];
      for (let index: number = 0; index < counters.length; index++) {
        const value: number = this.statusNumber(status, counters[index]);
        const previous: number = this.lastCounters[index];
        this.mark('vpn_' + counters[index], value);
        this.mark('vpn_' + counters[index] + '_delta', value >= previous && previous >= 0 ? value - previous : -1);
        this.lastCounters[index] = value;
      }
      for (const field of ['tunReadErrors', 'tunWriteErrors']) this.mark('vpn_' + field, this.statusNumber(status, field));
    } catch (_error) {
      this.lastCounters = [-1, -1, -1, -1];
      this.mark('vpn_status_unavailable');
    }
  }

  private installWatcher(): void {
    const watcher: hiAppEvent.Watcher = {
      name: 'MeshArcRuntime118',
      appEventFilters: [{ domain: hiAppEvent.domain.OS,
        names: [hiAppEvent.event.APP_KILLED, hiAppEvent.event.APP_CRASH, hiAppEvent.event.APP_FREEZE] }],
      onReceive: (domain: string, groups: hiAppEvent.AppEventGroup[]): void => {
        if (this.watcher !== watcher || domain !== hiAppEvent.domain.OS) return;
        try {
          const dropped: number = groups.slice(8).reduce((sum: number, group: hiAppEvent.AppEventGroup): number =>
            sum + group.appEventInfos.length, 0) + groups.slice(0, 8).reduce(
            (sum: number, group: hiAppEvent.AppEventGroup): number => sum + Math.max(0, group.appEventInfos.length - 32), 0);
          if (dropped > 0) this.mark('system_events_dropped', dropped);
          for (const group of groups.slice(0, 8)) {
            for (const event of group.appEventInfos.slice(-32)) {
              if (event.domain !== hiAppEvent.domain.OS || ![hiAppEvent.event.APP_KILLED,
                hiAppEvent.event.APP_CRASH, hiAppEvent.event.APP_FREEZE].includes(event.name)) continue;
              const timestamp: Object = event.params['time'];
              this.pendingSample = [];
              this.mark('system_' + event.name);
              this.mark('system_event_time_ms', typeof timestamp === 'number' ? timestamp : -1);
              const reason: Object = event.params['reason'];
              this.mark('kill_reason_' + (typeof reason === 'string' && KILL_REASONS.includes(reason) ?
                reason : 'unknown'));
              const foreground: Object = event.params['foreground'];
              this.mark('system_event_foreground', typeof foreground === 'boolean' ? (foreground ? 1 : 0) : -1);
              this.captureExitDetails(event);
              const rows: RuntimeRecord[] = this.pendingSample;
              this.pendingSample = undefined;
              RuntimeDiagnosticService.appendRecords(this.filesDir, this.source, rows);
            }
          }
        } catch (_error) {
          this.pendingSample = undefined;
          this.mark('system_event_parse_failed');
        }
      }
    };
    this.watcher = watcher;
    try {
      const holder: hiAppEvent.AppEventPackageHolder | null | undefined = hiAppEvent.addWatcher(watcher);
      if (holder === null || holder === undefined) {
        this.watcher = undefined;
        this.mark('system_watcher_unavailable');
        return;
      }
      this.mark('system_watcher_started');
    } catch (_error) {
      this.watcher = undefined;
      this.mark('system_watcher_unavailable');
    }
  }

  private captureExitDetails(event: hiAppEvent.AppEventInfo): void {
    // Never copy process_name, exit_msg, stack traces or external paths.
    const raw: Object = event.params['last_exit_detail_info'];
    let detail: Record<string, Object> = {};
    try {
      const parsed: Object | undefined = typeof raw === 'string' && raw.length <= 8192 ? JSON.parse(raw) as Object : raw;
      if (typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)) detail = parsed as Record<string, Object>;
      else if (raw !== undefined) this.mark('system_exit_detail_parse_failed');
    } catch (_error) { this.mark('system_exit_detail_parse_failed'); }
    for (const field of ['pid', 'timestamp', 'rss', 'pss', 'process_state']) {
      const value: Object = detail[field] !== undefined ? detail[field] :
        (field === 'pid' ? event.params['pid'] : undefined);
      const numeric: number = typeof value === 'number' ? value :
        (typeof value === 'string' && /^[0-9]{1,16}$/.test(value) ? Number(value) : -1);
      this.mark('system_exit_' + field, Number.isSafeInteger(numeric) && numeric >= 0 ? numeric : -1);
    }
    const running: Object = event.params['app_running_unique_id'];
    const id: string = typeof running === 'string' ? running :
      (typeof running === 'number' && Number.isSafeInteger(running) ? String(running) : '');
    // Decimal chunks preserve large IDs without rounding or raw string output.
    const valid: boolean = /^[0-9]{1,24}$/.test(id);
    this.mark('system_running_id_digits', valid ? id.length : -1);
    if (valid) {
      const padded: string = id.padStart(24, '0');
      for (let index: number = 0; index < 3; index++) {
        this.mark('system_running_id_' + index, Number(padded.substring(index * 8, index * 8 + 8)));
      }
    }
  }

  private static token(value: string): string {
    return value.replace(/[^a-zA-Z0-9_.()-]/g, '_').substring(0, 80) || 'unknown';
  }

  private static path(filesDir: string, owner: string, index: number): string {
    return `${filesDir}/runtime-${owner}-${index}.ndjson`;
  }
}
