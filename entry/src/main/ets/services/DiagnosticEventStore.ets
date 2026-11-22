import { fileIo } from '@kit.CoreFileKit';
import { AtomicFileStore } from './AtomicFileStore';
import { DiagnosticPrivacy } from './DiagnosticPrivacy';
import { RuntimeDiagnosticService } from './RuntimeDiagnosticService';

const MAX_EVENTS_PER_PROCESS: number = DiagnosticPrivacy.MAX_EVENTS_PER_FILE;
const MAX_ROUTINE_PROBE_EVENTS: number = 20;
const UI_EVENT_FILE_NAME: string = 'diagnostic-ui-events.ndjson';
const VPN_EVENT_FILE_NAME: string = 'diagnostic-vpn-events.ndjson';

export interface DiagnosticEvent {
  timestampMs: number;
  source: string;
  event: string;
  phase: string;
  code: number;
}

export interface DiagnosticEventContext {
  lifecycleGeneration?: number;
  cancellationRevision?: number;
  retryCount?: number;
  retryDelayMs?: number;
  taskActive?: boolean;
  userSuppressed?: boolean;
  tunActive?: boolean;
  shutdownRequested?: boolean;
  networkGeneration?: number;
  networkRevision?: number;
  appliedRevision?: number;
  networkInFlight?: boolean;
  networkStage?: number;
  operationDurationMs?: number;
}

export class DiagnosticEventStore {
  static record(filesDir: string, source: string, event: string, phase: string, code: number = 0): void {
    const safeSource: string = DiagnosticEventStore.safeToken(source, 'unknown');
    const item: DiagnosticEvent = {
      timestampMs: Date.now(),
      source: safeSource,
      event: DiagnosticEventStore.safeToken(event, 'unknown'),
      phase: DiagnosticEventStore.safeToken(phase, 'unknown'),
      code: Number.isFinite(code) ? code : 0
    };
    RuntimeDiagnosticService.append(filesDir, safeSource, item.event, item.phase, item.code);
    const path: string = DiagnosticEventStore.eventFilePath(filesDir, safeSource);
    const events: DiagnosticEvent[] = DiagnosticEventStore.readFile(path);
    events.push(item);
    const retained: DiagnosticEvent[] = DiagnosticEventStore.retainWithinByteLimit(events);
    DiagnosticEventStore.writeFile(path, retained);
  }

  static recordDetailed(filesDir: string, source: string, event: string, phase: string,
    code: number = 0, context?: DiagnosticEventContext): void {
    try {
      const safeSource: string = DiagnosticEventStore.safeToken(source, 'unknown');
      const items: DiagnosticEvent[] = [{
        timestampMs: Date.now(), source: safeSource,
        event: DiagnosticEventStore.safeToken(event, 'unknown'),
        phase: DiagnosticEventStore.safeToken(phase, 'unknown'),
        code: Number.isFinite(code) ? code : 0
      }];
      DiagnosticEventStore.appendRuntimeContext(filesDir, items);
      if (context !== undefined) {
        DiagnosticEventStore.appendMetric(items, 'lifecycle_generation', context.lifecycleGeneration);
        DiagnosticEventStore.appendMetric(items, 'cancellation_revision', context.cancellationRevision);
        DiagnosticEventStore.appendMetric(items, 'retry_count', context.retryCount);
        DiagnosticEventStore.appendMetric(items, 'retry_delay_ms', context.retryDelayMs);
        DiagnosticEventStore.appendMetric(items, 'task_active', context.taskActive);
        DiagnosticEventStore.appendMetric(items, 'user_suppressed', context.userSuppressed);
        DiagnosticEventStore.appendMetric(items, 'tun_active', context.tunActive);
        DiagnosticEventStore.appendMetric(items, 'shutdown_requested', context.shutdownRequested);
        DiagnosticEventStore.appendMetric(items, 'network_generation', context.networkGeneration);
        DiagnosticEventStore.appendMetric(items, 'network_revision', context.networkRevision);
        DiagnosticEventStore.appendMetric(items, 'applied_revision', context.appliedRevision);
        DiagnosticEventStore.appendMetric(items, 'network_in_flight', context.networkInFlight);
        DiagnosticEventStore.appendMetric(items, 'network_stage', context.networkStage);
        DiagnosticEventStore.appendMetric(items, 'operation_duration_ms', context.operationDurationMs);
      }
      RuntimeDiagnosticService.appendRecords(filesDir, safeSource, items);
      const path: string = DiagnosticEventStore.eventFilePath(filesDir, safeSource);
      const retained: DiagnosticEvent[] = DiagnosticEventStore.retainWithinByteLimit(
        DiagnosticEventStore.readFile(path).concat(items));
      DiagnosticEventStore.writeFile(path, retained);
    } catch (_error) {}
  }

  private static appendRuntimeContext(filesDir: string, items: DiagnosticEvent[]): void {
    let status: string = '';
    try {
      status = fileIo.readTextSync(filesDir + '/vpn-probe-status.txt');
    } catch (_error) {}
    DiagnosticEventStore.appendMetric(items, 'status_available', status.length > 0);
    if (status.length === 0) {
      return;
    }
    const heartbeat: RegExpMatchArray | null = status.match(/(?:^|[\s|])heartbeatMs=(\d+)(?=[\s|]|$)/);
    DiagnosticEventStore.appendMetric(items, 'heartbeat_age_ms', heartbeat === null ? -1 :
      Date.now() - Number(heartbeat[1]));
    const fields: string[] = ['trafficSession', 'tunRead', 'tunWrite', 'txBytes', 'rxBytes',
      'tunReadErrors', 'tunWriteErrors'];
    const labels: string[] = ['traffic_session', 'tun_read_packets', 'tun_write_packets',
      'tun_read_bytes', 'tun_write_bytes', 'tun_read_errors', 'tun_write_errors'];
    for (let index: number = 0; index < fields.length; index++) {
      const match: RegExpMatchArray | null = status.match(
        new RegExp('(?:^|[\\s|])' + fields[index] + '=(\\d+)(?=[\\s|]|$)'));
      if (match !== null) {
        DiagnosticEventStore.appendMetric(items, labels[index], Number(match[1]));
      }
    }
    const tun: RegExpMatchArray | null = status.match(/(?:^|[\s|])tun=(true|false)(?=[\s|]|$)/);
    if (tun !== null) {
      DiagnosticEventStore.appendMetric(items, 'reported_tun_active', tun[1] === 'true');
    }
    DiagnosticEventStore.appendMetric(items, 'runtime_state', DiagnosticPrivacy.runtimeStateCode(status));
  }

  private static appendMetric(items: DiagnosticEvent[], label: string,
    value: number | boolean | undefined): void {
    if (value === undefined) {
      return;
    }
    const numeric: number = typeof value === 'boolean' ? (value ? 1 : 0) : value;
    const primary: DiagnosticEvent = items[0];
    items.push({ timestampMs: primary.timestampMs, source: primary.source, event: primary.event,
      phase: 'context.' + label, code: Number.isSafeInteger(numeric) && numeric >= -1 ? numeric : -1 });
  }

  static load(filesDir: string): DiagnosticEvent[] {
    const events: DiagnosticEvent[] = [];
    DiagnosticEventStore.readFile(`${filesDir}/${UI_EVENT_FILE_NAME}`)
      .forEach((item: DiagnosticEvent) => events.push(item));
    DiagnosticEventStore.readFile(`${filesDir}/${VPN_EVENT_FILE_NAME}`)
      .forEach((item: DiagnosticEvent) => events.push(item));
    events.sort((left: DiagnosticEvent, right: DiagnosticEvent) => left.timestampMs - right.timestampMs);
    const maximum: number = MAX_EVENTS_PER_PROCESS * 2;
    return events.length > maximum ? events.slice(events.length - maximum) : events;
  }

  private static eventFilePath(filesDir: string, source: string): string {
    return source === 'vpn' ? `${filesDir}/${VPN_EVENT_FILE_NAME}` : `${filesDir}/${UI_EVENT_FILE_NAME}`;
  }

  private static safeToken(value: string, fallback: string): string {
    const normalized: string = value.trim().toLowerCase().replace(/[^a-z0-9_.-]+/g, '_');
    if (normalized.length === 0) {
      return fallback;
    }
    return normalized.length > 48 ? normalized.substring(0, 48) : normalized;
  }

  private static readFile(path: string): DiagnosticEvent[] {
    try {
      if (!fileIo.accessSync(path)) {
        return [];
      }
      const text: string = fileIo.readTextSync(path);
      if (text.trim().length === 0) {
        return [];
      }
      const result: DiagnosticEvent[] = [];
      text.split('\n').forEach((line: string) => {
        if (line.trim().length === 0) {
          return;
        }
        try {
          const parsed: DiagnosticEvent = JSON.parse(line) as DiagnosticEvent;
          if (Number.isSafeInteger(parsed.timestampMs) && parsed.timestampMs > 0 &&
            parsed.timestampMs <= 8640000000000000) {
            result.push({
              timestampMs: parsed.timestampMs,
              source: DiagnosticEventStore.safeToken(typeof parsed.source === 'string' ? parsed.source : '', 'unknown'),
              event: DiagnosticEventStore.safeToken(typeof parsed.event === 'string' ? parsed.event : '', 'unknown'),
              phase: DiagnosticEventStore.safeToken(typeof parsed.phase === 'string' ? parsed.phase : '', 'unknown'),
              code: Number.isFinite(parsed.code) ? parsed.code : 0
            });
          }
        } catch (_error) {
          // Ignore malformed best-effort entries instead of blocking report generation.
        }
      });
      return result;
    } catch (_error) {
      return [];
    }
  }

  private static writeFile(path: string, events: DiagnosticEvent[]): void {
    const content: string = events.map((item: DiagnosticEvent) => JSON.stringify(item)).join('\n');
    // Keep the previous complete summary on write failure; runtime/outbox are independent copies.
    AtomicFileStore.writeAtomic(path, content, {
      owner: 'diag-events',
      fsync: true,
      allowPartialWrite: true
    });
  }

  private static retainWithinByteLimit(events: DiagnosticEvent[]): DiagnosticEvent[] {
    const retained: DiagnosticEvent[] = events.slice();
    let routineCount: number = retained.filter((item: DiagnosticEvent, index: number) =>
      DiagnosticEventStore.isRoutineProbe(item, retained[index + 1])).length;
    while (routineCount > MAX_ROUTINE_PROBE_EVENTS || retained.length > MAX_EVENTS_PER_PROCESS ||
      (retained.length > 1 && DiagnosticPrivacy.exceedsByteLimit(
      retained.map((item: DiagnosticEvent) => JSON.stringify(item)).join('\n'),
      DiagnosticPrivacy.MAX_EVENT_FILE_BYTES))) {
      const routineIndex: number = retained.findIndex((item: DiagnosticEvent, index: number) =>
        DiagnosticEventStore.isRoutineProbe(item, retained[index + 1]));
      if (routineIndex >= 0) {
        retained.splice(routineIndex, 1);
        routineCount--;
      } else {
        retained.shift();
        while (retained.length > 0 && retained[0].phase.startsWith('context.')) {
          retained.shift();
        }
      }
    }
    return retained;
  }

  private static isRoutineProbe(item: DiagnosticEvent, next?: DiagnosticEvent): boolean {
    if (item.code !== 0 || (next !== undefined && next.phase.startsWith('context.'))) {
      return false;
    }
    const reachablePath: boolean = item.phase === 'direct' || item.phase === 'peerrelay' || item.phase === 'derp';
    return (item.event === 'media_probe_started' && item.phase === 'requested') ||
      (item.event === 'media_probe_completed' && item.phase === 'no_service') ||
      (item.event === 'media_probe_available' && item.phase === 'service_confirmed') ||
      (item.source === 'ui' && ((item.event === 'peer_service_refresh_start' && item.phase === 'requested') ||
        (item.event === 'sunshine_probe_success' && item.phase === 'available') ||
        (reachablePath && (item.event === 'peer_path_result' || item.event === 'media_probe_success' ||
          item.event === 'media_probe_no_service'))));
  }
}
