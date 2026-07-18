import { fileIo } from '@kit.CoreFileKit';

const MAX_EVENTS_PER_PROCESS: number = 100;
const UI_EVENT_FILE_NAME: string = 'diagnostic-ui-events.ndjson';
const VPN_EVENT_FILE_NAME: string = 'diagnostic-vpn-events.ndjson';

export interface DiagnosticEvent {
  timestampMs: number;
  source: string;
  event: string;
  phase: string;
  code: number;
}

export class DiagnosticEventStore {
  static record(filesDir: string, source: string, event: string, phase: string, code: number = 0): void {
    try {
      const safeSource: string = DiagnosticEventStore.safeToken(source, 'unknown');
      const item: DiagnosticEvent = {
        timestampMs: Date.now(),
        source: safeSource,
        event: DiagnosticEventStore.safeToken(event, 'unknown'),
        phase: DiagnosticEventStore.safeToken(phase, 'unknown'),
        code: Number.isFinite(code) ? code : 0
      };
      const path: string = DiagnosticEventStore.eventFilePath(filesDir, safeSource);
      const events: DiagnosticEvent[] = DiagnosticEventStore.readFile(path);
      events.push(item);
      const retained: DiagnosticEvent[] = events.length > MAX_EVENTS_PER_PROCESS ?
        events.slice(events.length - MAX_EVENTS_PER_PROCESS) : events;
      DiagnosticEventStore.writeFile(path, retained);
    } catch (_error) {
      // Diagnostics are best-effort and must never affect the VPN lifecycle.
    }
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
          if (parsed.timestampMs > 0) {
            result.push({
              timestampMs: parsed.timestampMs,
              source: DiagnosticEventStore.safeToken(parsed.source, 'unknown'),
              event: DiagnosticEventStore.safeToken(parsed.event, 'unknown'),
              phase: DiagnosticEventStore.safeToken(parsed.phase, 'unknown'),
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
    let file: fileIo.File | undefined = undefined;
    try {
      const content: string = events.map((item: DiagnosticEvent) => JSON.stringify(item)).join('\n');
      file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, content);
    } catch (_error) {
      // Diagnostics are best-effort and must never affect the VPN lifecycle.
    } finally {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (_error) {
          // The descriptor may already be closed after a platform write failure.
        }
      }
    }
  }
}
