import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const source = readFileSync(new URL('../entry/src/main/ets/services/RuntimeDiagnosticService.ets', import.meta.url), 'utf8');
const js = stripTypeScriptTypes(source.replace(/^import .*;\r?$/gm, '')
  .replace('export class RuntimeDiagnosticService', 'class RuntimeDiagnosticService'));

function fixture() {
  const f = { now: 100000, files: new Map(), handles: new Map(), timers: new Map(), watchers: [],
    next: 0, syncs: 0, failWrite: false, shortWrite: false, zeroWrite: false,
    failFsync: false, watcherMode: 'success' };
  const box = {
    process: { pid: 42 }, RUNTIME_BUILD_FINGERPRINT: 'test',
    Date: { now: () => f.now },
    setInterval: (cb, delay) => { const id = ++f.next; f.timers.set(id, { cb, delay }); return id; },
    clearInterval: id => f.timers.delete(id),
    fileIo: {
      OpenMode: { CREATE: 1, WRITE_ONLY: 2, APPEND: 4 },
      accessSync: path => f.files.has(path),
      statSync: path => ({ size: f.files.get(path).length }),
      readTextSync: path => { if (!f.files.has(path)) throw Error('missing'); return f.files.get(path); },
      openSync: path => { const fd = ++f.next; f.handles.set(fd, path); return { fd }; },
      writeSync: (fd, text) => {
        if (f.failWrite) throw Error('disk full');
        if (f.zeroWrite) return 0;
        const written = f.shortWrite ? text.substring(0, Math.max(1, text.length >> 1)) : text;
        const path = f.handles.get(fd); f.files.set(path, (f.files.get(path) || '') + written);
        return written.length;
      },
      fsyncSync: () => { if (f.failFsync) throw Error('fsync failed'); f.syncs++; },
      closeSync: file => f.handles.delete(file.fd),
      unlinkSync: path => f.files.delete(path),
      renameSync: (from, to) => { f.files.set(to, f.files.get(from)); f.files.delete(from); },
      copyFileSync: (from, to) => f.files.set(to, f.files.get(from))
    },
    power: { isActive: () => false, getPowerMode: () => 600 },
    batteryInfo: { chargingStatus: 1 },
    hidebug: { getAppVMMemoryInfo: () => ({ heapUsed: 123n, totalHeap: 456n }) },
    hiAppEvent: {
      domain: { OS: 'OS' }, event: { APP_KILLED: 'APP_KILLED', APP_CRASH: 'APP_CRASH', APP_FREEZE: 'APP_FREEZE' },
      addWatcher: watcher => { f.watchers.push(watcher);
        if (f.watcherMode === 'throw') throw Error('registration failed');
        return f.watcherMode === 'null' ? null : f.watcherMode === 'undefined' ? undefined : {};
      }, removeWatcher() {}
    }
  };
  vm.runInNewContext(js + '\nglobalThis.Service = RuntimeDiagnosticService;', box);
  f.Service = box.Service; f.service = new box.Service();
  f.rows = owner => (f.files.get('/files/runtime-' + owner + '-0.ndjson') || '').trim().split('\n').filter(Boolean).map(JSON.parse);
  f.launch = { launchReason: 1, lastExitReason: 7, lastExitMessage: 'private-token',
    lastExitDetailInfo: { timestamp: 90000, rss: 102400, pss: 81920, pid: 42,
      exitSubReason: 107, killReason: 'LowMemoryKill', processName: 'private-process', exitMsg: 'private-message' } };
  return f;
}

test('automatic recording survives more than 24 hours and stops only when destroyed', () => {
  const f = fixture(); f.service.start('/files', 'ui', f.launch);
  assert.equal(f.watchers.length, 1);
  const timer = [...f.timers.values()][0]; assert.equal(timer.delay, 300000);
  f.now += 86400001; timer.cb();
  assert.ok(f.rows('ui').some(row => row.event === 'heartbeat_gap_ms' && row.code === 86400001));
  f.service.stop(); assert.equal(f.timers.size, 0);
  assert.equal(f.rows('ui').at(-1).event, 'ability_destroyed');
});

test('restart preserves prior runtime rows and numeric exit evidence without private messages', () => {
  const f = fixture(); f.service.start('/files', 'ui', f.launch);
  const next = new f.Service(); next.start('/files', 'ui', f.launch);
  assert.equal(f.rows('ui').filter(row => row.event === 'session_started').length, 2);
  assert.ok(f.rows('ui').some(row => row.event === 'previous_kill_reason_LowMemoryKill'));
  assert.doesNotMatch(JSON.stringify([...f.files.values()]), /private/);
});

test('UI and VPN use separate files and only UI installs the system watcher', () => {
  const f = fixture(); f.service.start('/files', 'ui', f.launch);
  const vpn = new f.Service(); vpn.start('/files', 'vpn');
  assert.equal(f.watchers.length, 1); assert.equal(f.rows('vpn')[0].source, 'vpn');
  assert.equal(f.rows('ui')[0].source, 'ui');
});

test('rolling retention keeps four 2 MiB segments per process and bounded export inputs', () => {
  const f = fixture(); const owners = ['ui', 'vpn'];
  for (const owner of owners) {
    for (let i = 0; i < 4; i++) f.files.set(`/files/runtime-${owner}-${i}.ndjson`, i === 0 ? 'x'.repeat(2 * 1024 * 1024) : String(i));
    f.Service.append('/files', owner, 'rotated', 'runtime', 0);
    assert.ok(f.files.get(`/files/runtime-${owner}-1.ndjson`).length === 2 * 1024 * 1024);
    assert.equal(f.files.get(`/files/runtime-${owner}-3.ndjson`), '2');
  }
  const paths = f.Service.exportFiles('/files', '/work'); assert.equal(paths.length, 8);
  assert.equal(f.Service.fileNames().length, 8);
});

test('short writes are completed and disk failures close acquired handles', () => {
  const f = fixture(); f.shortWrite = true;
  f.Service.append('/files', 'vpn', 'test', 'runtime', 9);
  assert.equal(f.rows('vpn').find(row => row.event === 'test').code, 9); assert.equal(f.syncs, 1);
  f.failWrite = true; assert.doesNotThrow(() => f.Service.append('/files', 'vpn', 'test', 'runtime', 0));
  assert.equal(f.handles.size, 0);
});

test('system termination evidence uses reason allowlist and ignores callbacks after shutdown', () => {
  const f = fixture(); f.service.start('/files', 'ui', f.launch);
  const watcher = f.watchers[0];
  const emit = reason => watcher.onReceive('OS', [{ name: 'APP_KILLED', appEventInfos: [
    { domain: 'OS', name: 'APP_KILLED', params: { time: 99000, reason, foreground: false,
      external_log: '/private/log', last_exit_detail_info: 'private-secret' } }
  ] }]);
  emit('CPUHighload'); emit('secret-token-123');
  assert.ok(f.rows('ui').some(row => row.event === 'kill_reason_CPUHighload'));
  assert.ok(f.rows('ui').some(row => row.event === 'kill_reason_unknown'));
  assert.doesNotMatch(JSON.stringify([...f.files.values()]), /secret|private/);
  f.service.stop(); const size = f.rows('ui').length; emit('LowMemoryKill');
  assert.equal(f.rows('ui').length, size);
});

test('heartbeats record only numeric VPN counters and heartbeat age', () => {
  const f = fixture(); f.service.start('/files', 'vpn');
  f.files.set('/files/vpn-probe-status.txt', 'state=Running | tun=true | heartbeatMs=99000 | txBytes=100 | rxBytes=50 | url=https://secret.example');
  [...f.timers.values()][0].cb();
  assert.ok(f.rows('vpn').some(row => row.event === 'vpn_txBytes' && row.code === 100));
  assert.ok(f.rows('vpn').some(row => row.event === 'vpn_heartbeatMs' && row.code === 1000));
  assert.doesNotMatch(JSON.stringify(f.rows('vpn')), /secret|https/);
});


test('screen-off charging diagnostics include bounded VM heap counters', () => {
  const f = fixture(); f.service.start('/files', 'ui', f.launch);
  assert.ok(f.rows('ui').some(x => x.event === 'screen_active' && x.code === 0));
  assert.ok(f.rows('ui').some(x => x.event === 'charging_state' && x.code === 1));
  assert.ok(f.rows('ui').some(x => x.event === 'vm_heap_used_kb' && x.code === 123));
});

for (const mode of ['null', 'undefined', 'throw']) {
  test(`watcher ${mode} cannot claim subscription success`, () => {
    const f = fixture(); f.watcherMode = mode; f.service.start('/files', 'ui', f.launch);
    assert.ok(f.rows('ui').some(row => row.event === 'system_watcher_unavailable'));
    assert.ok(!f.rows('ui').some(row => row.event === 'system_watcher_started'));
    const count = f.rows('ui').length;
    f.watchers[0].onReceive('OS', [{ appEventInfos: [{ domain: 'OS', name: 'APP_KILLED', params: {} }] }]);
    assert.equal(f.rows('ui').length, count);
  });
}

test('record truncation and retention eviction leave explicit numeric gap evidence', () => {
  const f = fixture();
  for (let i = 0; i < 4; i++) f.files.set(`/files/runtime-ui-${i}.ndjson`, i === 0 ? 'x'.repeat(2 * 1024 * 1024) : 'abc');
  f.Service.appendRecords('/files', 'ui', Array.from({ length: 70 }, () => ({
    timestampMs: f.now, source: 'ui', event: 'sample', phase: 'runtime', code: 0 })));
  assert.ok(f.rows('ui').some(row => row.event === 'runtime_input_records_dropped' && row.code === 6));
  assert.ok(f.rows('ui').some(row => row.event === 'runtime_retention_bytes_dropped' && row.code === 3));
});

test('readable placeholders, missing and stale heartbeats remain distinguishable', () => {
  const f = fixture(); f.service.start('/files', 'ui', f.launch);
  const tick = [...f.timers.values()][0].cb;
  f.files.set('/files/vpn-probe-status.txt', 'state=Stopped | private=secret'); tick();
  assert.ok(f.rows('ui').some(row => row.event === 'vpn_status_readable' && row.code === 1));
  assert.ok(f.rows('ui').some(row => row.event === 'vpn_status_heartbeat_valid' && row.code === 0));
  f.files.set('/files/vpn-probe-status.txt', 'state=Running | tun=true | heartbeatMs=1 | snapshotMs=0'); f.now += 1000000; tick();
  assert.ok(f.rows('ui').some(row => row.event === 'vpn_status_stale' && row.code === 1));
  assert.equal(f.rows('ui').filter(row => row.event === 'vpn_snapshot_age_ms').at(-1).code, -1);
  f.files.set('/files/vpn-probe-status.txt', 'heartbeatMs=999999999999999999999999'); tick();
  assert.equal(f.rows('ui').filter(row => row.event === 'vpn_status_heartbeat_valid').at(-1).code, 0);
  assert.doesNotMatch(JSON.stringify(f.rows('ui')), /secret|private/);
});

test('snapshot age differs from fresh heartbeat and counter resets are not negative traffic', () => {
  const f = fixture(); f.service.start('/files', 'ui', f.launch);
  const tick = [...f.timers.values()][0].cb;
  f.files.set('/files/vpn-probe-status.txt', 'state=Running | tun=true | heartbeatMs=99900 | snapshotMs=50000 | tunRead=10 | txBytes=30'); tick();
  f.files.set('/files/vpn-probe-status.txt', 'state=Running | tun=true | heartbeatMs=100000 | snapshotMs=50000 | tunRead=15 | txBytes=20'); tick();
  assert.equal(f.rows('ui').filter(row => row.event === 'vpn_heartbeatMs').at(-1).code, 0);
  assert.equal(f.rows('ui').filter(row => row.event === 'vpn_snapshot_age_ms').at(-1).code, 50000);
  assert.equal(f.rows('ui').filter(row => row.event === 'vpn_tunRead_delta').at(-1).code, 5);
  assert.equal(f.rows('ui').filter(row => row.event === 'vpn_txBytes_delta').at(-1).code, -1);
});


test('correlation metadata is numeric, source-scoped and advances before failed writes', () => {
 const f=fixture(); f.Service.append('/files','vpn','a','runtime',1); f.failWrite=true;
 f.Service.append('/files','vpn','b','runtime',2); f.failWrite=false; f.Service.append('/files','vpn','c','runtime',3);
 const records=f.rows('vpn');
 assert.deepEqual(records.filter(x=>x.event==='runtime_sequence').map(x=>x.code),[3]);
 assert.ok(records.some(x=>x.event==='runtime_write_failures'&&x.code===1));
 assert.ok(records.some(x=>x.event==='runtime_process_pid'&&x.code===42));
 assert.ok(records.some(x=>x.event==='runtime_boot_ms'&&x.code===100000));
});
test('system numeric exit correlation and large run IDs survive without private detail strings', () => {
 const f=fixture(); f.service.start('/files','ui',f.launch);
 f.watchers[0].onReceive('OS',[{appEventInfos:[{domain:'OS',name:'APP_KILLED',params:{time:99000,
  reason:'SwapFull',foreground:false,app_running_unique_id:'215456512336951247',
  last_exit_detail_info:JSON.stringify({pid:'123',timestamp:'99000',rss:'456',process_state:'2',process_name:'PRIVATE',exit_msg:'SECRET'})}}]}]);
 const rows=f.rows('ui'); assert.ok(rows.some(x=>x.event==='system_exit_pid'&&x.code===123));
 assert.deepEqual(rows.filter(x=>/^system_running_id_[012]$/.test(x.event)).map(x=>x.code),[21,54565123,36951247]);
 assert.doesNotMatch(JSON.stringify(rows),/PRIVATE|SECRET/);
});
test('system callback truncation leaves an explicit count rather than silent loss', () => {
 const f=fixture(); f.service.start('/files','ui',f.launch);
 const event={domain:'OS',name:'APP_KILLED',params:{time:1,reason:'SwapFull'}};
 f.watchers[0].onReceive('OS',[{appEventInfos:Array.from({length:40},()=>event)}]);
 assert.ok(f.rows('ui').some(x=>x.event==='system_events_dropped'&&x.code===8));
});

for (const detail of ['null','42','[]','{broken']) test('bad detail '+detail+' never suppresses base kill evidence',()=>{
 const f=fixture();f.service.start('/files','ui',f.launch);
 f.watchers[0].onReceive('OS',[{appEventInfos:[{domain:'OS',name:'APP_KILLED',params:{time:99000,reason:'SwapFull',last_exit_detail_info:detail}}]}]);
 assert.ok(f.rows('ui').some(x=>x.event==='system_APP_KILLED'));
 assert.ok(f.rows('ui').some(x=>x.event==='system_event_time_ms'&&x.code===99000));
 assert.ok(f.rows('ui').some(x=>x.event==='system_exit_detail_parse_failed'));
});

test('crash and freeze top-level numeric PID can be correlated without private process name',()=>{
 const f=fixture();f.service.start('/files','ui',f.launch);
 f.watchers[0].onReceive('OS',[{appEventInfos:[{domain:'OS',name:'APP_FREEZE',params:{time:99000,pid:4321,process_name:'PRIVATE'}}]}]);
 assert.ok(f.rows('ui').some(x=>x.event==='system_exit_pid'&&x.code===4321));
 assert.doesNotMatch(JSON.stringify(f.rows('ui')),/PRIVATE/);
});

