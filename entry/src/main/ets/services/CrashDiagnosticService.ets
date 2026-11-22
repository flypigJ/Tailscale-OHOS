import { fileIo } from '@kit.CoreFileKit';
import { hiAppEvent } from '@kit.PerformanceAnalysisKit';
import { AtomicFileStore } from './AtomicFileStore';

const CONTROL_FILE: string = '/crash-diagnostic-opt-in.json';
const RECORD_FILE: string = '/crash-diagnostic-records.json';
const TTL_MS: number = 24 * 60 * 60 * 1000;
const MAX_BYTES: number = 64 * 1024;
const MAX_RECORDS: number = 5;

interface CrashConsent { enabled: boolean; enabledAtMs: number; expiresMs: number; }
interface CrashNativeFrame { file?: string; pc?: string; }
interface CrashException { name?: string; signal?: string; stack?: string; frames?: CrashNativeFrame[]; }
const SOURCE_FRAME_PATTERN: RegExp = /^src\/main\/ets\/(?:components\/(?:BridgeStatus|AppShell|NativeSettingsNavigation|TaildriveBrowser)|services\/(?:DiagnosticReportService|CrashDiagnosticService|AccountDiagnosticsGateway|PathDiagnosticService|DiagnosticEventStore|DiagnosticPrivacy|AtomicFileStore|VpnExtensionRpcChannel|FileIconResolver|TaildriveSessionController|VpnSessionController|TaildropSessionController|PeerIntegrationController|SettingsPreferencesGateway)|contracts\/(?:ConnectionPathContract|PeerContracts|VpnIpcContracts|TaildropContracts|TaildriveContracts|FileKindCatalog|RequestGuard)|entryability\/EntryAbility|vpnextensionability\/TailscaleVpnExtensionAbility|pages\/Index)\.(?:ets|ts):[1-9]\d{0,6}:[1-9]\d{0,5}$/;
interface CrashRecord {
  timestampMs: number;
  kind: string;
  type: string;
  foreground: number;
  version: string;
  abi: string;
  frames: string[];
  missing: string[];
}
interface CrashArchive { schema: number; records: CrashRecord[]; }
interface CrashExport {
  schema: number;
  result: string;
  expiresMs: number;
  records: CrashRecord[];
  missing: string[];
}

/** Observes system crash events without intercepting errors or changing process exit. */
export class CrashDiagnosticService {
  private static filesDir: string = '';
  private static consent: CrashConsent = { enabled: false, enabledAtMs: 0, expiresMs: 0 };
  private static watcher?: hiAppEvent.Watcher;
  private static revision: number = 0;
  private static expiryTimer: number = -1;
  // An explicit stop remains revoked in this process even when storage fails.
  private static revokedDirectories: Set<string> = new Set<string>();

  static initialize(filesDir: string): void {
    CrashDiagnosticService.shutdown();
    CrashDiagnosticService.filesDir = filesDir;
    CrashDiagnosticService.consent = { enabled: false, enabledAtMs: 0, expiresMs: 0 };
    const consent: CrashConsent | undefined = CrashDiagnosticService.readConsent(filesDir);
    if (CrashDiagnosticService.revokedDirectories.has(filesDir) || consent === undefined) {
      CrashDiagnosticService.eraseRecords(filesDir);
      return;
    }
    CrashDiagnosticService.consent = consent;
    if (!CrashDiagnosticService.validConsent(consent, Date.now())) {
      CrashDiagnosticService.eraseRecords(filesDir);
      return;
    }
    CrashDiagnosticService.installWatcher();
  }

  static shutdown(): void {
    CrashDiagnosticService.revision++;
    if (CrashDiagnosticService.expiryTimer >= 0) {
      clearTimeout(CrashDiagnosticService.expiryTimer);
      CrashDiagnosticService.expiryTimer = -1;
    }
    const watcher: hiAppEvent.Watcher | undefined = CrashDiagnosticService.watcher;
    CrashDiagnosticService.watcher = undefined;
    if (watcher !== undefined) {
      try { hiAppEvent.removeWatcher(watcher); } catch (_error) {}
    }
  }

  static enable(filesDir: string): boolean {
    CrashDiagnosticService.shutdown();
    CrashDiagnosticService.filesDir = filesDir;
    const now: number = Date.now();
    const consent: CrashConsent = { enabled: true, enabledAtMs: now, expiresMs: now + TTL_MS };
    try {
      // Consent must be durable before registration: addWatcher may deliver immediately.
      CrashDiagnosticService.writeAtomic(filesDir + CONTROL_FILE, JSON.stringify(consent));
      CrashDiagnosticService.writeAtomic(filesDir + RECORD_FILE, '{"schema":1,"records":[]}');
      CrashDiagnosticService.consent = consent;
      CrashDiagnosticService.revokedDirectories.delete(filesDir);
      if (CrashDiagnosticService.installWatcher()) return true;
    } catch (_error) {}
    CrashDiagnosticService.disable(filesDir);
    return false;
  }

  static disable(filesDir: string): boolean {
    CrashDiagnosticService.revokedDirectories.add(filesDir);
    CrashDiagnosticService.shutdown();
    CrashDiagnosticService.filesDir = filesDir;
    CrashDiagnosticService.consent = { enabled: false, enabledAtMs: 0, expiresMs: 0 };
    let persisted: boolean = false;
    try {
      CrashDiagnosticService.writeAtomic(filesDir + CONTROL_FILE,
        '{"enabled":false,"enabledAtMs":0,"expiresMs":0}');
      persisted = true;
    } catch (_error) {
      persisted = CrashDiagnosticService.eraseFile(filesDir + CONTROL_FILE);
    }
    const erased: boolean = CrashDiagnosticService.eraseRecords(filesDir);
    return persisted && erased;
  }

  static isEnabled(filesDir: string): boolean {
    return CrashDiagnosticService.filesDir === filesDir && CrashDiagnosticService.watcher !== undefined &&
      CrashDiagnosticService.currentConsent();
  }

  static exportSnapshot(filesDir: string): string {
    const consent: CrashConsent | undefined = CrashDiagnosticService.readConsent(filesDir);
    const revoked: boolean = CrashDiagnosticService.revokedDirectories.has(filesDir);
    const active: boolean = !revoked && consent !== undefined && CrashDiagnosticService.validConsent(consent, Date.now());
    const result: CrashExport = {
      schema: 1,
      result: active ? (CrashDiagnosticService.isEnabled(filesDir) ? 'enabled' : 'watcher_unavailable') :
        (!revoked && consent !== undefined && consent.enabled && Date.now() >= consent.expiresMs ? 'expired' : 'disabled'),
      expiresMs: active && consent !== undefined ? consent.expiresMs : 0,
      records: active && consent !== undefined ? CrashDiagnosticService.readRecords(filesDir, consent) : [],
      missing: []
    };
    if (active && !CrashDiagnosticService.isEnabled(filesDir)) result.missing.push('system_watcher_unavailable');
    if (result.records.length === 0) result.missing.push('no_supported_crash_event_received');
    return JSON.stringify(result);
  }

  private static installWatcher(): boolean {
    const revision: number = CrashDiagnosticService.revision;
    const watcher: hiAppEvent.Watcher = {
      name: 'MeshArcCrashDiagnostic',
      appEventFilters: [{ domain: hiAppEvent.domain.OS, names: [hiAppEvent.event.APP_CRASH] }],
      onReceive: (domain: string, groups: hiAppEvent.AppEventGroup[]): void => {
        // Never remove the watcher inside its callback, and never retain the raw event.
        if (revision !== CrashDiagnosticService.revision || domain !== hiAppEvent.domain.OS || !Array.isArray(groups) ||
          !CrashDiagnosticService.currentConsent()) return;
        try {
          let inspected: number = 0;
          for (const group of groups.slice(0, 5)) {
            if (group === null || typeof group !== 'object' ||
              group.name !== hiAppEvent.event.APP_CRASH || !Array.isArray(group.appEventInfos)) continue;
            for (const event of group.appEventInfos.slice(0, 20)) {
              if (++inspected > 20) return;
              try { CrashDiagnosticService.accept(event, revision); } catch (_eventError) {}
            }
          }
        } catch (_error) { /* Diagnostics must never throw into application lifecycle. */ }
      }
    };
    CrashDiagnosticService.watcher = watcher;
    try {
      const holder: hiAppEvent.AppEventPackageHolder = hiAppEvent.addWatcher(watcher);
      if (holder === null || holder === undefined) throw new Error('diagnostic_watcher_unavailable');
      CrashDiagnosticService.expiryTimer = setTimeout(() => {
        if (revision === CrashDiagnosticService.revision) {
          CrashDiagnosticService.disable(CrashDiagnosticService.filesDir);
        }
      }, Math.max(1, CrashDiagnosticService.consent.expiresMs - Date.now()));
      return true;
    } catch (_error) {
      CrashDiagnosticService.watcher = undefined;
      try { hiAppEvent.removeWatcher(watcher); } catch (_removeError) {}
      return false;
    }
  }

  private static currentConsent(): boolean {
    const persisted: CrashConsent | undefined = CrashDiagnosticService.readConsent(CrashDiagnosticService.filesDir);
    return !CrashDiagnosticService.revokedDirectories.has(CrashDiagnosticService.filesDir) &&
      persisted !== undefined && CrashDiagnosticService.validConsent(persisted, Date.now()) &&
      persisted.enabledAtMs === CrashDiagnosticService.consent.enabledAtMs &&
      persisted.expiresMs === CrashDiagnosticService.consent.expiresMs;
  }

  private static validConsent(value: CrashConsent, now: number): boolean {
    return value.enabled === true && Number.isSafeInteger(value.enabledAtMs) && value.enabledAtMs > 0 &&
      Number.isSafeInteger(value.expiresMs) && value.expiresMs - value.enabledAtMs === TTL_MS &&
      value.enabledAtMs <= now && now < value.expiresMs;
  }

  private static readConsent(filesDir: string): CrashConsent | undefined {
    try {
      const text: string = CrashDiagnosticService.readLimited(filesDir + CONTROL_FILE, 1024);
      const parsed: CrashConsent = JSON.parse(text) as CrashConsent;
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return undefined;
      return { enabled: parsed.enabled === true, enabledAtMs: parsed.enabledAtMs, expiresMs: parsed.expiresMs };
    } catch (_error) { return undefined; }
  }

  private static accept(event: hiAppEvent.AppEventInfo, revision: number): void {
    if (revision !== CrashDiagnosticService.revision || !CrashDiagnosticService.currentConsent() ||
      event.domain !== hiAppEvent.domain.OS || event.name !== hiAppEvent.event.APP_CRASH) return;
    const timestamp: Object = event.params['time'];
    if (typeof timestamp !== 'number' || !Number.isSafeInteger(timestamp) ||
      timestamp < CrashDiagnosticService.consent.enabledAtMs || timestamp > Date.now() ||
      timestamp >= CrashDiagnosticService.consent.expiresMs) return;
    const exception: CrashException = CrashDiagnosticService.exception(event.params['exception']);
    const kind: Object = event.params['crash_type'];
    const record: CrashRecord = {
      timestampMs: timestamp,
      kind: kind === 'JsError' ? 'js' : kind === 'NativeCrash' ? 'native' : 'unknown',
      type: CrashDiagnosticService.safeType(exception.name || exception.signal),
      foreground: typeof event.params['foreground'] === 'boolean' ? (event.params['foreground'] ? 1 : 0) : -1,
      version: CrashDiagnosticService.safeVersion(event.params['bundle_version']),
      abi: CrashDiagnosticService.safeAbi(event.params['cpu_abi']),
      frames: CrashDiagnosticService.collectFrames(exception),
      missing: []
    };
    if (record.frames.length === 0) record.missing = ['supported_code_frames_unavailable'];
    const records: CrashRecord[] = CrashDiagnosticService.readRecords(CrashDiagnosticService.filesDir,
      CrashDiagnosticService.consent).filter((item: CrashRecord) =>
      item.timestampMs !== record.timestampMs || item.kind !== record.kind || item.frames.join('|') !== record.frames.join('|'));
    records.push(record);
    const archive: CrashArchive = { schema: 1, records: records.slice(-MAX_RECORDS) };
    CrashDiagnosticService.writeAtomic(CrashDiagnosticService.filesDir + RECORD_FILE, JSON.stringify(archive));
  }

  private static exception(value: Object): CrashException {
    try {
      const parsed: CrashException = typeof value === 'string' ?
        (value.length <= 16384 ? JSON.parse(value) as CrashException : {}) : value as CrashException;
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return {};
      return { name: typeof parsed.name === 'string' ? parsed.name : '',
        signal: typeof parsed.signal === 'string' ? parsed.signal : '',
        stack: typeof parsed.stack === 'string' ? parsed.stack.substring(0, 16384) : '',
        frames: Array.isArray(parsed.frames) ? parsed.frames.slice(0, 12) : [] };
    } catch (_error) { return {}; }
  }

  private static collectFrames(exception: CrashException): string[] {
    const frames: string[] = CrashDiagnosticService.codeFrames(exception.stack);
    if (Array.isArray(exception.frames)) {
      for (const frame of exception.frames.slice(0, 12)) {
        if (frame === null || typeof frame !== 'object') continue;
        const native: string = CrashDiagnosticService.nativeFrame(frame.file, frame.pc);
        if (native.length > 0 && !frames.includes(native)) frames.push(native);
        if (frames.length >= 12) break;
      }
    }
    return frames.slice(0, 12);
  }

  private static nativeFrame(file?: string, pc?: string): string {
    if (typeof file !== 'string' || file.length > 1024 || typeof pc !== 'string' ||
      !/^(?:0x)?[0-9a-fA-F]{1,16}$/.test(pc)) return '';
    const name: string = file.substring(file.lastIndexOf('/') + 1);
    if (!['libtailscale_go.so', 'libtailscale_ohos.so', 'libark_jsruntime.so', 'libace.z.so',
      'libc.so', 'libc++_shared.so'].includes(name)) return '';
    return name + '+0x' + pc.replace(/^0x/, '').toLowerCase();
  }

  private static codeFrames(value?: string): string[] {
    if (typeof value !== 'string') return [];
    const frames: string[] = [];
    for (const line of value.substring(0, 16384).split(/\r?\n/).slice(0, 64)) {
      if (line.length > 1024) continue;
      const source: RegExpMatchArray | null = line.match(/^\s*at\s+(?:.{0,256}?[ (|])?(src\/main\/ets\/[A-Za-z0-9_/.]+:[1-9]\d{0,6}:[1-9]\d{0,5})(?:[) ]|$)/);
      if (source !== null && SOURCE_FRAME_PATTERN.test(source[1])) {
        frames.push(source[1]);
      } else {
        const native: RegExpMatchArray | null = line.match(/^\s*#\d{1,3}\s+pc\s+([0-9a-fA-F]{4,16})\s+(\/(?:[A-Za-z0-9_.+-]+\/)*[A-Za-z0-9_.+-]+)(?:\s|\(|$)/);
        if (native !== null) {
          const frame: string = CrashDiagnosticService.nativeFrame(native[2], native[1]);
          if (frame.length > 0) frames.push(frame);
        }
      }
      if (frames.length >= 12) break;
    }
    return frames;
  }

  private static safeType(value?: string): string {
    return typeof value === 'string' && ['Error', 'TypeError', 'ReferenceError', 'SyntaxError', 'RangeError',
      'EvalError', 'URIError', 'AggregateError', 'OutOfMemoryError', 'SIGSEGV', 'SIGABRT', 'SIGBUS',
      'SIGILL', 'SIGFPE', 'SIGTRAP'].includes(value) ? value : 'unknown';
  }

  private static safeVersion(value: Object): string {
    return typeof value === 'string' && /^\d{1,6}\.\d{1,6}\.\d{1,6}$/.test(value) ? value : 'unknown';
  }

  private static safeAbi(value: Object): string {
    return typeof value === 'string' && ['arm64-v8a', 'armeabi-v7a', 'x86_64'].includes(value) ? value : 'unknown';
  }

  private static readRecords(filesDir: string, consent: CrashConsent): CrashRecord[] {
    try {
      const parsed: CrashArchive = JSON.parse(CrashDiagnosticService.readLimited(filesDir + RECORD_FILE, MAX_BYTES)) as CrashArchive;
      if (parsed === null || typeof parsed !== 'object' || parsed.schema !== 1 || !Array.isArray(parsed.records)) return [];
      const records: CrashRecord[] = [];
      for (const item of parsed.records.slice(-MAX_RECORDS)) {
        if (item === null || typeof item !== 'object' || !Number.isSafeInteger(item.timestampMs) ||
          item.timestampMs < consent.enabledAtMs || item.timestampMs >= consent.expiresMs || item.timestampMs > Date.now()) continue;
        const frames: string[] = [];
        if (Array.isArray(item.frames)) {
          for (const frame of item.frames.slice(0, 12)) {
            if (typeof frame !== 'string') continue;
            if (SOURCE_FRAME_PATTERN.test(frame) ||
              /^(?:libtailscale_go\.so|libtailscale_ohos\.so|libark_jsruntime\.so|libace\.z\.so|libc\.so|libc\+\+_shared\.so)\+0x[0-9a-f]{1,16}$/.test(frame)) frames.push(frame);
          }
        }
        records.push({ timestampMs: item.timestampMs,
          kind: item.kind === 'js' || item.kind === 'native' ? item.kind : 'unknown',
          type: CrashDiagnosticService.safeType(item.type),
          foreground: item.foreground === 0 || item.foreground === 1 ? item.foreground : -1,
          version: CrashDiagnosticService.safeVersion(item.version), abi: CrashDiagnosticService.safeAbi(item.abi), frames: frames,
          missing: frames.length === 0 ? ['supported_code_frames_unavailable'] : [] });
      }
      return records;
    } catch (_error) { return []; }
  }

  private static readLimited(path: string, maximum: number): string {
    const size: number = fileIo.statSync(path).size;
    if (!Number.isSafeInteger(size) || size < 0 || size > maximum) throw new Error('diagnostic_file_limit');
    const text: string = fileIo.readTextSync(path);
    if (text.length > maximum) throw new Error('diagnostic_file_limit');
    return text;
  }

  private static writeAtomic(path: string, text: string): void {
    AtomicFileStore.writeAtomicOrThrow(path, text, {
      owner: 'crash-diag',
      fsync: false,
      maxBytes: MAX_BYTES
    });
  }

  private static eraseRecords(filesDir: string): boolean {
    const records: boolean = CrashDiagnosticService.eraseFile(filesDir + RECORD_FILE);
    const temporary: boolean = AtomicFileStore.cleanupTempSiblings(filesDir, 'crash-diagnostic-records.json');
    return records && temporary;
  }

  private static eraseFile(path: string): boolean {
    try {
      if (!fileIo.accessSync(path)) return true;
      fileIo.unlinkSync(path);
      return true;
    } catch (_error) { return false; }
  }
}
