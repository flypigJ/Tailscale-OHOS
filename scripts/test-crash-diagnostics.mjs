import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';
import { readEtsSource, stripEtsModuleSyntax } from './helpers/ets-vm-loader.mjs';

const sourcePath = process.env.CRASH_DIAGNOSTIC_SOURCE ||
  new URL('../entry/src/main/ets/services/CrashDiagnosticService.ets', import.meta.url);
const source = readFileSync(sourcePath, 'utf8');
const atomicJavascript = stripEtsModuleSyntax(readEtsSource('services/AtomicFileStore'));
const javascript = atomicJavascript + '\n' + stripEtsModuleSyntax(source);
const TTL = 86400000;

function fixture() {
  const f = { now: 1792630800000, files: new Map(), watchers: [], removed: [], timers: new Map(),
    readPaths: [], failAdd: false, failWrite: false, failUnlink: false, addResult: {}, shortWrite: false, onAdd: undefined };
  const handles = new Map(); let nextFd = 1; let nextTimer = 1;
  const sandbox = {
    Date: { now: () => f.now },
    setTimeout: (cb, delay) => { const id = nextTimer++; f.timers.set(id, { cb, delay }); return id; },
    clearTimeout: id => f.timers.delete(id),
    fileIo: {
      OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
      accessSync: path => f.files.has(path),
      statSync: path => {
        if (!f.files.has(path)) throw Error('absent');
        return { size: Buffer.byteLength(f.files.get(path)) };
      },
      readTextSync: path => { f.readPaths.push(path); if (!f.files.has(path)) throw Error('absent'); return f.files.get(path); },
      openSync: path => {
        if (f.failWrite) throw Error('write denied');
        const fd = nextFd++; handles.set(fd, path); f.files.set(path, ''); return { fd };
      },
      writeSync: (fd, text) => {
        if (f.failWrite) throw Error('write denied');
        const bytes = Buffer.byteLength(text);
        const count = f.shortWrite ? Math.max(0, bytes - 1) : bytes;
        f.files.set(handles.get(fd), Buffer.from(text, 'utf8').subarray(0, count).toString('utf8'));
        return count;
      },
      listFileSync: dir => [...f.files.keys()]
        .filter(p => p.startsWith(dir + '/') && !p.slice(dir.length + 1).includes('/'))
        .map(p => p.slice(dir.length + 1)),
      closeSync: file => handles.delete(file.fd),
      renameSync: (from, to) => { if (!f.files.has(from)) throw Error('absent'); f.files.set(to, f.files.get(from)); f.files.delete(from); },
      unlinkSync: path => { if (f.failUnlink) throw Error('delete denied'); f.files.delete(path); }
    },
    hiAppEvent: {
      domain: { OS: 'OS' }, event: { APP_CRASH: 'APP_CRASH' },
      addWatcher: watcher => { if (f.failAdd) throw Error('unsupported'); f.watchers.push(watcher); f.onAdd?.(watcher); return f.addResult; },
      removeWatcher: watcher => f.removed.push(watcher)
    }
  };
  vm.runInNewContext(javascript + '\nglobalThis.Service = CrashDiagnosticService;', sandbox);
  f.sandbox = sandbox;
  f.service = sandbox.Service;
  f.snapshot = () => JSON.parse(f.service.exportSnapshot('/files'));
  f.emit = (event, watcher = f.watchers.at(-1)) => watcher.onReceive('OS', [{ name: 'APP_CRASH', appEventInfos: [event] }]);
  f.event = (overrides = {}) => ({ domain: 'OS', name: 'APP_CRASH', eventType: 1, params: {
    time: f.now, crash_type: 'JsError', foreground: true, bundle_version: '1.1.5', cpu_abi: 'arm64-v8a',
    exception: { name: 'TypeError', message: 'tskey-secret https://private.example/account /data/user/secret',
      thread_name: 'private-user', stack: '    at anonymous (entry|entry|1.1.5|src/main/ets/components/BridgeStatus.ts:12:34)\n' },
    hilog: ['private-log'], external_log: ['/data/storage/el2/log/secret.log'], uid: 2001, pid: 90,
    ...overrides
  } });
  return f;
}

test('default is off and no watcher or files are created by initialization', () => {
  const f = fixture(); f.service.initialize('/files');
  assert.equal(f.watchers.length, 0); assert.equal(f.files.size, 0);
  assert.equal(f.service.isEnabled('/files'), false); assert.equal(f.snapshot().result, 'disabled');
  assert.deepEqual(f.snapshot().records, []);
});

test('explicit enable registers only APP_CRASH after durable consent and sanitizes the event', () => {
  const f = fixture();
  f.onAdd = () => assert.equal(JSON.parse(f.files.get('/files/crash-diagnostic-opt-in.json')).enabled, true);
  assert.equal(f.service.enable('/files'), true);
  assert.deepEqual(JSON.parse(JSON.stringify(f.watchers[0].appEventFilters)), [{ domain: 'OS', names: ['APP_CRASH'] }]);
  f.emit(f.event()); const out = f.snapshot();
  assert.equal(out.records.length, 1); assert.equal(out.records[0].type, 'TypeError');
  assert.deepEqual(out.records[0].frames, ['src/main/ets/components/BridgeStatus.ts:12:34']);
  const retained = JSON.stringify([...f.files.values(), out]);
  assert.doesNotMatch(retained, /tskey|private|https:|\/data\/|thread_name|external_log|hilog|uid|pid|message/);
  assert.ok(f.readPaths.every(path => path.startsWith('/files/crash-diagnostic-')));
});

test('restart restores a valid 24-hour opt-in and accepts the prior crash only within its consent interval', () => {
  const f = fixture(); f.service.enable('/files'); const started = f.now;
  f.now += 1000; f.service.shutdown(); f.service.initialize('/files');
  assert.equal(f.watchers.length, 2); assert.equal(f.service.isEnabled('/files'), true);
  f.emit(f.event({ time: started - 1 })); f.emit(f.event({ time: started + 500 }));
  assert.equal(f.snapshot().records.length, 1); assert.equal(f.snapshot().records[0].timestampMs, started + 500);
});

test('disable clears files, invalidates late callbacks, and cannot restore consent on restart', () => {
  const f = fixture(); f.service.enable('/files'); const old = f.watchers.at(-1); f.emit(f.event());
  f.service.disable('/files'); old.onReceive('OS', [{ name: 'APP_CRASH', appEventInfos: [f.event()] }]);
  assert.deepEqual(f.snapshot().records, []); assert.equal(f.files.has('/files/crash-diagnostic-records.json'), false);
  const watchers = f.watchers.length; f.service.initialize('/files'); assert.equal(f.watchers.length, watchers);
  f.service.enable('/files'); f.emit(f.event(), old); assert.equal(f.snapshot().records.length, 0);
});

test('expiry is enforced by callbacks, export, restart and timer without intercepting application errors', () => {
  const f = fixture(); f.service.enable('/files'); f.emit(f.event()); const timer = [...f.timers.values()][0];
  f.now += TTL; f.emit(f.event()); assert.equal(f.service.isEnabled('/files'), false);
  assert.equal(f.snapshot().result, 'expired'); assert.deepEqual(f.snapshot().records, []);
  timer.cb(); assert.equal(f.files.has('/files/crash-diagnostic-records.json'), false);
  f.service.initialize('/files'); assert.equal(f.service.isEnabled('/files'), false);
  assert.doesNotMatch(source, /errorManager|onUnhandledException|external_log|\.hilog|configEventPolicy|setEventConfig/);
});

test('retention is limited to five events and twelve strict code frames per event', () => {
  const f = fixture(); f.service.enable('/files');
  const stack = Array.from({ length: 30 }, (_, i) => ` at f (src/main/ets/services/PathDiagnosticService.ets:${i + 1}:1)`).join('\n');
  for (let i = 0; i < 9; i++) { f.now++; f.emit(f.event({ exception: { name: 'custom-secret', stack } })); }
  const out = f.snapshot(); assert.equal(out.records.length, 5); assert.equal(out.records[0].type, 'unknown');
  assert.ok(out.records.every(r => r.frames.length === 12));
  assert.ok(Buffer.byteLength(f.files.get('/files/crash-diagnostic-records.json')) < 65536);
  f.emit(f.event({ exception: { name: 'custom-secret', stack } })); assert.equal(f.snapshot().records.length, 5);
});

test('native frames retain only approved module names and offsets; malformed/unknown stacks are explicit', () => {
  const f = fixture(); f.service.enable('/files');
  f.emit(f.event({ crash_type: 'NativeCrash', exception: JSON.stringify({ name: 'SIGSEGV',
    stack: '#00 pc 000000000001a2b3 /data/storage/el1/bundle/libs/arm64/libtailscale_ohos.so (private function)\n' +
      '#01 pc 000000000004a2b3 /private/user/libsecret.so\n at file (file:///data/user/account.txt:3:4)' }) }));
  assert.deepEqual(f.snapshot().records[0].frames, ['libtailscale_ohos.so+0x000000000001a2b3']);
  f.now++; f.emit(f.event({ exception: '{broken' }));
  assert.deepEqual(f.snapshot().records[1].missing, ['supported_code_frames_unavailable']);
  assert.doesNotMatch(JSON.stringify(f.snapshot()), /private|account|libsecret/);
});

test('oversized or malformed saved data is rejected before reading and valid data is rebuilt from allowlists', () => {
  const f = fixture(); f.service.enable('/files');
  const recordPath = '/files/crash-diagnostic-records.json'; f.files.set(recordPath, 'x'.repeat(65537));
  f.readPaths.length = 0; assert.deepEqual(f.snapshot().records, []); assert.ok(!f.readPaths.includes(recordPath));
  f.files.set(recordPath, JSON.stringify({ schema: 1, records: [{ timestampMs: f.now, kind: 'js', type: 'TypeError',
    foreground: 1, version: '1.1.5', abi: 'arm64-v8a', frames: ['https://secret', 'src/main/ets/pages/Index.ets:1:2'],
    message: 'secret', absolutePath: '/data/user' }] }));
  assert.deepEqual(f.snapshot().records[0].frames, ['src/main/ets/pages/Index.ets:1:2']);
  assert.doesNotMatch(JSON.stringify(f.snapshot()), /secret|absolutePath|message/);
});

test('registration and persistence failures are contained and short writes never replace an archive', () => {
  for (const failure of ['failAdd', 'failWrite', 'shortWrite']) {
    const f = fixture(); f[failure] = true; assert.equal(f.service.enable('/files'), false);
    assert.equal(f.service.isEnabled('/files'), false); assert.deepEqual(f.snapshot().records, []);
  }
  const f = fixture(); f.service.enable('/files'); f.emit(f.event());
  const before = f.files.get('/files/crash-diagnostic-records.json'); f.shortWrite = true; f.now++;
  assert.doesNotThrow(() => f.emit(f.event())); assert.equal(f.files.get('/files/crash-diagnostic-records.json'), before);
});

test('untrusted batches have group/event limits and a malformed event cannot block a later valid one', () => {
  const f = fixture(); f.service.enable('/files'); const watcher = f.watchers.at(-1);
  assert.doesNotThrow(() => watcher.onReceive('OS', null));
  assert.doesNotThrow(() => watcher.onReceive('OS', [null, { name: 'APP_CRASH', appEventInfos: [null, f.event()] }]));
  assert.equal(f.snapshot().records.length, 1);
  f.now++;
  watcher.onReceive('OS', Array.from({ length: 5 }, () => ({ name: 'APP_CRASH', appEventInfos: [] }))
    .concat([{ name: 'APP_CRASH', appEventInfos: [f.event()] }]));
  assert.equal(f.snapshot().records.length, 1);
});

test('undefined, null and unsupported exception values retain only an explicit missing-stack marker', () => {
  const f = fixture(); f.service.enable('/files');
  for (const exception of [undefined, null, 42, [], 'x'.repeat(16385)]) {
    f.now++; assert.doesNotThrow(() => f.emit(f.event({ exception })));
  }
  assert.equal(f.snapshot().records.length, 5);
  assert.ok(f.snapshot().records.every(record => record.frames.length === 0 &&
    record.type === 'unknown' && record.missing[0] === 'supported_code_frames_unavailable'));
});

test('bad/future/oversized consent never restores collection; failed restart registration is explicit', () => {
  for (const text of ['{broken', 'null', '[]', 'x'.repeat(1025),
    JSON.stringify({ enabled: true, enabledAtMs: 1792630800001, expiresMs: 1792630800001 + TTL }),
    JSON.stringify({ enabled: true, enabledAtMs: 1792630800000, expiresMs: 1792630800000 + TTL + 1 })]) {
    const f = fixture(); f.files.set('/files/crash-diagnostic-opt-in.json', text); f.service.initialize('/files');
    assert.equal(f.watchers.length, 0); assert.equal(f.service.isEnabled('/files'), false);
    assert.deepEqual(f.snapshot().records, []);
  }
  const f = fixture(); f.service.enable('/files'); f.emit(f.event()); f.service.shutdown(); f.failAdd = true;
  f.service.initialize('/files'); const out = f.snapshot(); assert.equal(f.service.isEnabled('/files'), false);
  assert.equal(out.result, 'watcher_unavailable'); assert.ok(out.missing.includes('system_watcher_unavailable'));
  // Previously persisted consented evidence remains exportable, but no new collection is claimed.
  assert.equal(out.records.length, 1);
});

const reportSource = readFileSync(process.env.DIAGNOSTIC_REPORT_SOURCE ||
  new URL('../entry/src/main/ets/services/DiagnosticReportService.ets', import.meta.url), 'utf8');

test('report retention converts SDK mtime seconds and preserves fresh, future and unknown timestamps', () => {
  const now = 1792630800000; const deleted = [];
  const entries = new Map([
    ['TailscaleOHOS-Diagnostic-fresh.zip', now / 1000],
    ['TailscaleOHOS-Diagnostic-old.zip', (now - TTL - 1000) / 1000],
    ['TailscaleOHOS-Diagnostic-future.zip', (now + 1000) / 1000],
    ['TailscaleOHOS-Diagnostic-unknown.zip', 0],
    ['TailscaleOHOS-Diagnostic-invalid.zip', NaN], ['unrelated.zip', 1]
  ]);
  const method = reportSource.match(/^  private static cleanupExpiredReports\([\s\S]*?^  \}/m)[0]
    .replace('private static ', 'function ');
  const box = { Date: { now: () => now }, REPORT_PREFIX: 'TailscaleOHOS-Diagnostic-', REPORT_RETENTION_MS: TTL,
    fileIo: { listFileSync: () => [...entries.keys()], lstatSync: path => ({ mtime: entries.get(path.split('/').at(-1)), isSymbolicLink: () => false, isFile: () => true, isDirectory: () => false }),
      unlinkSync: path => deleted.push(path.split('/').at(-1)) } };
  vm.runInNewContext(stripTypeScriptTypes(method), box); box.cleanupExpiredReports('/cache');
  assert.deepEqual(deleted, ['TailscaleOHOS-Diagnostic-old.zip']);
});

test('the existing report ZIP includes redacted crash JSON and an additive version code', async () => {
  const f = fixture(); const box = f.sandbox; const packed = new Map();
  const nativeDate = Date;
  box.Date = class extends nativeDate { constructor(value = f.now) { super(value); } static now() { return f.now; } };
  box.RuntimeDiagnosticService = { exportFiles: () => [], fileNames: () => [] };
  box.CrashDiagnosticService = f.service;
  box.PathDiagnosticService = { exportSnapshot: () => '{"schema":1,"result":"unavailable"}' };
  box.DiagnosticEventStore = { load: () => [] };
  box.DiagnosticPrivacy = { utf8ByteLength: value => Buffer.byteLength(value),
    exceedsByteLimit: (value, limit) => Buffer.byteLength(value) > limit,
    MAX_REPORT_SUMMARY_BYTES: 24576, MAX_REPORT_JSON_BYTES: 131072 };
  box.deviceInfo = { brand: 'HUAWEI', marketName: 'test-device', productModel: 'test-model', deviceType: 'phone',
    osFullName: 'HarmonyOS', displayVersion: '7.0', sdkApiVersion: 26, buildVersion: 1 };
  box.fileIo.accessSync = path => f.files.has(path);
  box.fileIo.mkdirSync = () => {}; box.fileIo.rmdirSync = () => {}; box.fileIo.listFileSync = () => [];
  box.zlib = { CompressLevel: { COMPRESS_LEVEL_DEFAULT_COMPRESSION: 1 }, compressFiles: async (paths, zip) => {
    for (const path of paths) packed.set(path.split('/').at(-1), f.files.get(path)); f.files.set(zip, 'test-zip');
  } };
  const js = stripTypeScriptTypes(reportSource.replace(/^import .*;\r?$/gm, '')
    .replace('export class DiagnosticReportService', 'class DiagnosticReportService'));
  vm.runInNewContext(js + '\nglobalThis.Report = DiagnosticReportService;', box);
  await box.Report.generate({ filesDir: '/files', cacheDir: '/cache' }, {
    appVersion: '1.1.5', appVersionCode: 100000015, tailscaleVersion: '1.86.5', nativeStatus: 'OK',
    engineStatus: 'OK', backendStatus: 'STOPPED', vpnStatus: 'STOPPED'
  });
  assert.deepEqual([...packed.keys()], ['summary.txt', 'report.json', 'path-diagnostic.json', 'crash-diagnostic.json']);
  const crash = JSON.parse(packed.get('crash-diagnostic.json'));
  assert.equal(crash.result, 'disabled'); assert.deepEqual(crash.records, []);
  assert.equal(JSON.parse(packed.get('report.json')).application.appVersionCode, 100000015);
  assert.match(packed.get('summary.txt'), /App version code: 100000015/);
  assert.equal([...f.files.keys()].some(path => path.includes('/diagnostic-report-')), false);
});

test('explicit revoke blocks all exports and callbacks despite complete persistence failure', () => {
  const f = fixture(); assert.equal(f.service.enable('/files'), true); f.emit(f.event());
  const old = f.watchers.at(-1); f.failWrite = true; f.failUnlink = true;
  assert.equal(f.service.disable('/files'), false);
  assert.equal(JSON.parse(f.files.get('/files/crash-diagnostic-opt-in.json')).enabled, true);
  assert.equal(f.snapshot().result, 'disabled'); assert.deepEqual(f.snapshot().records, []);
  f.service.initialize('/files'); assert.equal(f.service.isEnabled('/files'), false);
  f.now++; f.emit(f.event(), old); assert.deepEqual(f.snapshot().records, []);
  assert.equal(f.service.enable('/files'), false); assert.deepEqual(f.snapshot().records, []);
  f.failWrite = false; f.failUnlink = false;
  assert.equal(f.service.enable('/files'), true); assert.equal(f.snapshot().records.length, 0);
  f.now++; f.emit(f.event()); assert.equal(f.snapshot().records.length, 1);
});

test('disable success requires durable revocation and deletion of both record files', () => {
  const f = fixture(); f.service.enable('/files'); f.emit(f.event());
  f.files.set('/files/crash-diagnostic-records.json.tmp', 'temporary');
  f.files.set('/files/crash-diagnostic-records.json.crash-diag.1792630800000.9.tmp', 'modern-temporary');
  f.failUnlink = true; assert.equal(f.service.disable('/files'), false);
  assert.equal(JSON.parse(f.files.get('/files/crash-diagnostic-opt-in.json')).enabled, false);
  assert.deepEqual(f.snapshot().records, []);
  f.failUnlink = false; assert.equal(f.service.disable('/files'), true);
  assert.equal(f.files.has('/files/crash-diagnostic-records.json'), false);
  assert.equal(f.files.has('/files/crash-diagnostic-records.json.tmp'), false);
  assert.equal(f.files.has('/files/crash-diagnostic-records.json.crash-diag.1792630800000.9.tmp'), false);
  const g = fixture(); g.service.enable('/files'); g.failWrite = true;
  assert.equal(g.service.disable('/files'), true); // deleting the control is a durable fallback
  assert.equal(g.files.has('/files/crash-diagnostic-opt-in.json'), false);
});

test('initialization erases orphaned archives for missing, malformed, disabled and expired consent', () => {
  for (const consent of [undefined, '{broken', 'null', '[]', '{}',
    '{"enabled":false,"enabledAtMs":0,"expiresMs":0}',
    JSON.stringify({ enabled: true, enabledAtMs: 1792630800000 - TTL, expiresMs: 1792630800000 })]) {
    const f = fixture(); if (consent !== undefined) f.files.set('/files/crash-diagnostic-opt-in.json', consent);
    f.files.set('/files/crash-diagnostic-records.json', 'orphan');
    f.files.set('/files/crash-diagnostic-records.json.tmp', 'orphan');
    f.service.initialize('/files'); assert.equal(f.files.has('/files/crash-diagnostic-records.json'), false);
    assert.equal(f.files.has('/files/crash-diagnostic-records.json.tmp'), false);
    assert.equal(f.watchers.length, 0); assert.deepEqual(f.snapshot().records, []);
  }
});

test('null or undefined SDK subscription holder is a failed registration', () => {
  for (const result of [null, undefined]) {
    const f = fixture(); f.addResult = result; assert.equal(f.service.enable('/files'), false);
    assert.equal(f.service.isEnabled('/files'), false); assert.equal(f.timers.size, 0);
    assert.deepEqual(f.snapshot().records, []); assert.ok(f.removed.length > 0);
    const g = fixture(); g.service.enable('/files'); g.emit(g.event()); g.service.shutdown();
    g.addResult = result; g.service.initialize('/files'); assert.equal(g.service.isEnabled('/files'), false);
    assert.equal(g.snapshot().result, 'watcher_unavailable');
  }
});

test('stack text must be an actual frame in a known source file, including archive rereads', () => {
  const f = fixture(); f.service.enable('/files');
  const stack = 'Error: bad input src/main/ets/services/AliceAccountSecret.ets:12:34\n' +
    'Error: bad input src/main/ets/components/BridgeStatus.ets:12:34\n' +
    ' at secret (src/main/ets/services/AliceAccountSecret.ets:12:34)\n' +
    ' at legit (src/main/ets/components/BridgeStatus.ets:12:34)\n' +
    ' at store (src/main/ets/services/AtomicFileStore.ets:42:7)';
  f.emit(f.event({ exception: { name: 'Error', stack } }));
  assert.deepEqual(f.snapshot().records[0].frames, [
    'src/main/ets/components/BridgeStatus.ets:12:34',
    'src/main/ets/services/AtomicFileStore.ets:42:7'
  ]);
  assert.doesNotMatch(JSON.stringify([...f.files.values()]), /AliceAccountSecret|bad input|secret/);
  const path = '/files/crash-diagnostic-records.json'; const archive = JSON.parse(f.files.get(path));
  archive.records[0].frames.push('src/main/ets/services/AliceAccountSecret.ets:12:34');
  f.files.set(path, JSON.stringify(archive));
  assert.deepEqual(f.snapshot().records[0].frames, [
    'src/main/ets/components/BridgeStatus.ets:12:34',
    'src/main/ets/services/AtomicFileStore.ets:42:7'
  ]);
});

test('official structured native frames retain only approved module basenames and relative hex pc', () => {
  const f = fixture(); f.service.enable('/files');
  const approved = { file: '/data/private/user/libtailscale_ohos.so', pc: '000000000001ABCD',
    symbol: 'privateName', buildId: 'privateBuildId', offset: 99999 };
  f.emit(f.event({ crash_type: 'NativeCrash', exception: { signal: 'SIGSEGV',
    message: 'privateMessage', thread_name: 'privateThread', tid: 98, frames: [approved,
      { file: '/private/libuser-secret.so', pc: '1234' }, { file: '/lib/libc.so', pc: 'nothex' }, null,
      { file: '/lib/libc.so', pc: '0xaBc' }] },
    threads: [{ frames: [approved], thread_name: 'privateThread2' }] }));
  const record = f.snapshot().records[0]; assert.equal(record.type, 'SIGSEGV');
  assert.deepEqual(record.frames, ['libtailscale_ohos.so+0x000000000001abcd', 'libc.so+0xabc']);
  assert.doesNotMatch(JSON.stringify([...f.files.values(), f.snapshot()]), /private|thread|buildId|symbol|offset|tid|message/);
  f.now++; f.emit(f.event({ crash_type: 'NativeCrash', exception: { frames:
    [...Array.from({ length: 12 }, () => ({ file: 'unknown', pc: '1' })), approved] } }));
  assert.deepEqual(f.snapshot().records[1].frames, []);
  assert.deepEqual(f.snapshot().records[1].missing, ['supported_code_frames_unavailable']);
});

function reportFixture() {
  const f = fixture(); const box = f.sandbox; const packed = new Map();
  const NativeDate = Date;
  box.Date = class extends NativeDate {
    constructor(value = f.now) { super(value); }
    static now() { return f.now; }
  };
  box.RuntimeDiagnosticService = { exportFiles: () => [], fileNames: () => [] };
  box.CrashDiagnosticService = f.service;
  box.PathDiagnosticService = { exportSnapshot: () => '{"schema":1,"result":"unavailable"}' };
  box.DiagnosticEventStore = { load: () => [] };
  box.DiagnosticPrivacy = { utf8ByteLength: value => Buffer.byteLength(value),
    exceedsByteLimit: (value, limit) => Buffer.byteLength(value) > limit,
    MAX_REPORT_SUMMARY_BYTES: 24576, MAX_REPORT_JSON_BYTES: 131072 };
  box.deviceInfo = { brand: 'HUAWEI', marketName: 'test-device', productModel: 'test-model', deviceType: 'phone',
    osFullName: 'HarmonyOS', displayVersion: '7.0', sdkApiVersion: 26, buildVersion: 1 };
  box.fileIo.accessSync = path => f.files.has(path);
  box.fileIo.mkdirSync = () => {}; box.fileIo.rmdirSync = () => {};
  box.fileIo.listFileSync = () => [];
  const write = box.fileIo.writeSync;
  f.reportWrites = 0; f.shortReportWrite = -1; f.compressions = 0;
  box.fileIo.writeSync = (fd, text) => {
    write(fd, text);
    return Buffer.byteLength(text) - (++f.reportWrites === f.shortReportWrite ? 1 : 0);
  };
  box.zlib = { CompressLevel: { COMPRESS_LEVEL_DEFAULT_COMPRESSION: 1 }, compressFiles: async (paths, zip) => {
    f.compressions++;
    for (const path of paths) packed.set(path.split('/').at(-1), f.files.get(path));
    f.files.set(zip, 'test-zip');
  } };
  const js = stripTypeScriptTypes(reportSource.replace(/^import .*;\r?$/gm, '')
    .replace('export class DiagnosticReportService', 'class DiagnosticReportService'));
  vm.runInNewContext(js + '\nglobalThis.Report = DiagnosticReportService;', box);
  f.generate = () => box.Report.generate({ filesDir: '/files', cacheDir: '/cache' }, {
    appVersion: '1.1.5', appVersionCode: 100000015, tailscaleVersion: '1.86.5', nativeStatus: 'OK',
    engineStatus: 'OK', backendStatus: 'STOPPED', vpnStatus: 'STOPPED'
  });
  f.packed = packed;
  return f;
}

test('production report generation accepts full UTF-8 writes and rejects each short-written ZIP input', async () => {
  const good = reportFixture();
  good.sandbox.Report.buildSummary = () => '诊断摘要😀';
  const result = await good.generate();
  assert.equal(good.compressions, 1);
  assert.equal(good.packed.get('summary.txt'), '诊断摘要😀');
  assert.equal(good.files.get(result.path), 'test-zip');
  const packedReport=JSON.parse(good.packed.get('report.json'));
  assert.equal(result.feedbackContext.generatedAt,packedReport.generatedAt);
  assert.equal(result.feedbackContext.appVersion,packedReport.application.appVersion);
  assert.equal(result.feedbackContext.appVersionCode,packedReport.application.appVersionCode);
  assert.equal(result.feedbackContext.model,packedReport.device.model);
  assert.equal(result.feedbackContext.sdkApiVersion,packedReport.device.sdkApiVersion);
  assert.deepEqual(Object.keys(result.feedbackContext).sort(),[
    'appVersion','appVersionCode','tailscaleVersion','model','system','sdkApiVersion','generatedAt',
    'signedIn','exitNodeSelected','acceptSubnetRoutes'].sort());
  assert.equal(packedReport.schemaVersion,3);
  assert.equal('feedbackContext' in packedReport,false);
  for (const target of [1, 2, 3, 4]) {
    const f = reportFixture();
    f.sandbox.Report.buildSummary = () => '诊断摘要😀';
    f.shortReportWrite = target;
    await assert.rejects(f.generate(), /Diagnostic report generation failed/);
    assert.equal(f.compressions, 0, `short input ${target} must never be compressed`);
    assert.equal([...f.files.keys()].some(path => path.includes('/diagnostic-report-') || path.endsWith('.zip')), false);
  }
});

test('public cache cleanup isolates failures and removes only expired report files and known orphan inputs', () => {
  const f = reportFixture(); const box = f.sandbox; const now = f.now;
  const old = (now - TTL - 1000) / 1000; const fresh = now / 1000;
  const work = '/cache/diagnostic-report-20261020-010203-004';
  const linkWork = '/cache/diagnostic-report-20261020-010203-005';
  const freshWork = '/cache/diagnostic-report-20261020-010203-006';
  const unknownWork = '/cache/diagnostic-report-user-files';
  const paths = new Map(); const deleted = []; let rmdirCalls = 0;
  const add = (path, kind = 'file', mtime = old) => paths.set(path, { kind, mtime });
  add('/cache/TailscaleOHOS-Diagnostic-unstatable.zip', 'error');
  add('/cache/TailscaleOHOS-Diagnostic-unlinkable.zip', 'unlink-error');
  add('/cache/TailscaleOHOS-Diagnostic-old.zip');
  add('/cache/TailscaleOHOS-Diagnostic-fresh.zip', 'file', fresh);
  add('/cache/TailscaleOHOS-Diagnostic-future.zip', 'file', (now + 1000) / 1000);
  add('/cache/TailscaleOHOS-Diagnostic-unknown.zip', 'file', 0);
  add('/cache/TailscaleOHOS-Diagnostic-invalid.zip', 'file', NaN);
  add('/cache/TailscaleOHOS-Diagnostic-link.zip', 'link');
  add('/cache/unrelated.zip');
  add(work, 'directory'); add(linkWork, 'link'); add(freshWork, 'directory', fresh); add(unknownWork, 'directory');
  add(work + '/summary.txt', 'unlink-error');
  add(work + '/report.json'); add(work + '/path-diagnostic.json', 'link'); add(work + '/crash-diagnostic.json');
  add(work + '/unknown.txt'); add(work + '/nested', 'directory');
  add(linkWork + '/crash-diagnostic.json'); add(freshWork + '/crash-diagnostic.json'); add(unknownWork + '/crash-diagnostic.json');
  box.fileIo.listFileSync = () => [...paths.keys()].filter(path => path.slice('/cache/'.length).indexOf('/') < 0)
    .map(path => path.slice('/cache/'.length));
  box.fileIo.lstatSync = path => {
    const entry = paths.get(path);
    if (!entry || entry.kind === 'error') throw Error('unavailable');
    return { mtime: entry.mtime, isSymbolicLink: () => entry.kind === 'link',
      isDirectory: () => entry.kind === 'directory', isFile: () => entry.kind === 'file' || entry.kind === 'unlink-error' };
  };
  box.fileIo.unlinkSync = path => {
    if (paths.get(path)?.kind === 'unlink-error') throw Error('unlink denied');
    deleted.push(path); paths.delete(path);
  };
  box.fileIo.rmdirSync = () => { rmdirCalls++; throw Error('recursive removal is prohibited'); };
  box.Report.cleanupCache('/cache');
  assert.deepEqual(deleted, ['/cache/TailscaleOHOS-Diagnostic-old.zip', work + '/report.json', work + '/crash-diagnostic.json']);
  assert.equal(rmdirCalls, 0);
  for (const path of [work, work + '/summary.txt', work + '/path-diagnostic.json', work + '/unknown.txt', work + '/nested',
    linkWork, linkWork + '/crash-diagnostic.json', freshWork + '/crash-diagnostic.json', unknownWork + '/crash-diagnostic.json',
    '/cache/unrelated.zip', '/cache/TailscaleOHOS-Diagnostic-link.zip', '/cache/TailscaleOHOS-Diagnostic-fresh.zip',
    '/cache/TailscaleOHOS-Diagnostic-future.zip', '/cache/TailscaleOHOS-Diagnostic-unknown.zip', '/cache/TailscaleOHOS-Diagnostic-invalid.zip']) {
    assert.equal(paths.has(path), true, `must preserve ${path}`);
  }
});


test('Taildrive code locations survive capture and archive revalidation without retaining private stack text', () => {
  const f = fixture(); f.service.enable('/files');
  f.emit(f.event({ exception: {
    name: 'TypeError', message: 'private-device tskey-secret /data/user/private',
    stack: [
      ' at NavigationPathBar (entry|entry|1.1.6|src/main/ets/components/TaildriveBrowser.ts:4514:9)',
      ' at StandaloneNavigation (src/main/ets/components/TaildriveBrowser.ets:4848:5)',
      ' at private-device (/data/user/private/TaildriveBrowser.ts:12:3)',
      ' at user (src/main/ets/components/TaildriveBrowserPrivate.ts:1:1)',
      ' at traversal (src/main/ets/components/../private/TaildriveBrowser.ts:1:1)',
      ' at invalid (src/main/ets/components/TaildriveBrowser.ts:0:1)'
    ].join('\n')
  } }));
  f.service.shutdown();
  f.service.initialize('/files');
  const snapshot = f.snapshot();
  assert.deepEqual(snapshot.records[0].frames, [
    'src/main/ets/components/TaildriveBrowser.ts:4514:9',
    'src/main/ets/components/TaildriveBrowser.ets:4848:5'
  ]);
  assert.deepEqual(snapshot.records[0].missing, []);
  assert.doesNotMatch(JSON.stringify([...f.files.values(), snapshot]),
    /private|tskey|NavigationPathBar|StandaloneNavigation|TaildriveBrowserPrivate|message/);
});

test('Taildrive source locations remain unavailable before consent and after consent expires', () => {
  const f = fixture(); f.service.initialize('/files');
  assert.equal(f.watchers.length, 0);
  f.service.enable('/files');
  const watcher = f.watchers.at(-1);
  const event = () => f.event({ exception: { name: 'TypeError',
    stack: ' at build (src/main/ets/components/TaildriveBrowser.ts:4514:9)' } });
  f.now += TTL;
  f.emit(event(), watcher);
  assert.deepEqual(f.snapshot().records, []);
  assert.doesNotMatch(JSON.stringify([...f.files.values()]), /TaildriveBrowser/);
});

test('FileIconResolver, TaildriveSessionController, and @tailscale/common contract source frames survive capture and archive revalidation', () => {
  const f = fixture();
  f.service.enable('/files');
  f.emit(f.event({
    exception: {
      name: 'TypeError',
      stack: [
        ' at resolveFileIconResource (entry|entry|1.2.0|src/main/ets/services/FileIconResolver.ets:12:5)',
        ' at openTargetMachine (entry|entry|1.2.0|src/main/ets/services/TaildriveSessionController.ets:420:9)',
        ' at resolveFileIconKey (entry|@tailscale/common|0.1.0|src/main/ets/contracts/FileKindCatalog.ets:96:3)',
        ' at begin (entry|@tailscale/common|0.1.0|src/main/ets/contracts/RequestGuard.ets:14:5)',
        ' at secret (entry|@tailscale/common|0.1.0|src/main/ets/contracts/PrivateSecretContract.ets:1:1)'
      ].join('\n')
    }
  }));
  f.service.shutdown();
  f.service.initialize('/files');
  const snapshot = f.snapshot();
  assert.deepEqual(snapshot.records[0].frames, [
    'src/main/ets/services/FileIconResolver.ets:12:5',
    'src/main/ets/services/TaildriveSessionController.ets:420:9',
    'src/main/ets/contracts/FileKindCatalog.ets:96:3',
    'src/main/ets/contracts/RequestGuard.ets:14:5'
  ]);
  assert.doesNotMatch(JSON.stringify([...f.files.values(), snapshot]), /PrivateSecretContract/);
});

test('VpnSessionController, TaildropSessionController, PeerIntegrationController, and SettingsPreferencesGateway frames survive capture and archive revalidation', () => {
  const f = fixture();
  f.service.enable('/files');
  f.emit(f.event({
    exception: {
      name: 'TypeError',
      stack: [
        ' at refreshVpnProbeStatus (entry|entry|1.2.0|src/main/ets/services/VpnSessionController.ets:880:7)',
        ' at handleTaildropReceiveResult (entry|entry|1.2.0|src/main/ets/services/TaildropSessionController.ets:3115:9)',
        ' at refreshPeerServices (entry|entry|1.2.0|src/main/ets/services/PeerIntegrationController.ets:655:5)',
        ' at loadAppearanceOverlay (entry|entry|1.2.0|src/main/ets/services/SettingsPreferencesGateway.ets:152:5)',
        ' at privateHelper (entry|entry|1.2.0|src/main/ets/services/UnlistedPrivateController.ets:1:1)'
      ].join('\n')
    }
  }));
  f.service.shutdown();
  f.service.initialize('/files');
  const snapshot = f.snapshot();
  assert.deepEqual(snapshot.records[0].frames, [
    'src/main/ets/services/VpnSessionController.ets:880:7',
    'src/main/ets/services/TaildropSessionController.ets:3115:9',
    'src/main/ets/services/PeerIntegrationController.ets:655:5',
    'src/main/ets/services/SettingsPreferencesGateway.ets:152:5'
  ]);
  assert.doesNotMatch(JSON.stringify([...f.files.values(), snapshot]), /UnlistedPrivateController/);
});
