import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

function loadSource(name, sandbox) {
  const source = readFileSync(new URL('../entry/src/main/ets/' + name + '.ets', import.meta.url), 'utf8');
  const javascript = stripTypeScriptTypes(source.replace(/^import[\s\S]*?;\r?$/gm, '')
    .replace(/export default class /g, 'class ').replace(/export class /g, 'class '));
  const className = name.split('/').at(-1);
  vm.runInNewContext(javascript + '\nglobalThis.' + className + ' = ' + className + ';', sandbox);
}

function fixture() {
  const state = { now: 1000000, files: new Map(), descriptors: new Map(), nextFd: 0,
    openError: false, writeError: false, shortWrite: false, zeroWrite: false, closed: 0, writes: 0 };
  class Clock extends Date {
    static now() { return state.now; }
  }
  const sandbox = {
    Date: Clock,
    RuntimeDiagnosticService: { append() {}, appendRecords() {} },
    PathDiagnosticService: { resume() {}, poll() {}, recordHost: async () => {}, shutdown: async () => {} },
    VpnExtensionAbility: class {},
    fileIo: {
      OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
      accessSync: path => state.files.has(path),
      readTextSync: path => {
        if (!state.files.has(path)) throw Object.assign(new Error('missing private path'), { code: 13900002 });
        return state.files.get(path);
      },
      openSync: path => {
        if (state.openError) throw new Error('private key path');
        const fd = ++state.nextFd;
        state.descriptors.set(fd, path); state.files.set(path, '');
        return { fd };
      },
      writeSync: (fd, text) => {
        state.writes++;
        if (state.writeError) throw new Error('Bearer secret');
        if (state.zeroWrite) return 0;
        const raw = typeof text === 'string' ? Buffer.from(text, 'utf8') : Buffer.from(text);
        const written = state.shortWrite ? raw.subarray(0, Math.max(1, raw.length >> 1)) : raw;
        const path = state.descriptors.get(fd);
        state.files.set(path, (state.files.get(path) || '') + written.toString('utf8'));
        return written.length;
      },
      fsyncSync() {},
      renameSync: (from, to) => { state.files.set(to, state.files.get(from)); state.files.delete(from); },
      closeSync: file => { state.closed++; state.descriptors.delete(file.fd); },
      unlinkSync: path => { state.files.delete(path); }
    }
  };
  loadSource('services/AtomicFileStore', sandbox);
  loadSource('services/DiagnosticPrivacy', sandbox);
  loadSource('services/DiagnosticEventStore', sandbox);
  state.sandbox = sandbox;
  state.store = sandbox.DiagnosticEventStore;
  state.events = () => Array.from(state.store.load('/files'), item => ({ ...item }));
  state.runtime = () => state.files.set('/files/vpn-probe-status.txt',
    'OK | state=Running | tun=true | trafficSession=7 | tunRead=11 | tunWrite=12 | ' +
    'tunReadErrors=2 | tunWriteErrors=3 | heartbeatMs=999500 | account=private-user | ' +
    'address=100.101.102.103 | path=/private/inbox | token=private-token');
  return state;
}

test('detailed events preserve the five-field format and persist only allowlisted numeric context', () => {
  const state = fixture(); state.runtime();
  state.store.recordDetailed('/files', 'vpn', 'vpn_network_refresh_failed', 'network', 201,
    { networkStage: 2, networkGeneration: 4, retryDelayMs: 5000, tunActive: true, identity: 'private-user' });
  const events = state.events();
  assert.equal(events[0].code, 201);
  for (const event of events) {
    assert.deepEqual(Object.keys(event), ['timestampMs', 'source', 'event', 'phase', 'code']);
    assert.equal(event.timestampMs, state.now);
  }
  const metric = name => events.find(item => item.phase === 'context.' + name)?.code;
  assert.equal(metric('heartbeat_age_ms'), 500);
  assert.equal(metric('traffic_session'), 7);
  assert.equal(metric('tun_read_errors'), 2);
  assert.equal(metric('tun_write_errors'), 3);
  assert.equal(metric('runtime_state'), 1);
  assert.equal(metric('network_generation'), 4);
  assert.equal(metric('tun_active'), 1);
  assert.equal(state.writes, 1);
  assert.doesNotMatch(JSON.stringify(events), /private|100\.101|token|account|address|identity|inbox/);
});

test('missing telemetry and invalid counters remain unknown rather than implying disconnect', () => {
  const state = fixture();
  state.store.recordDetailed('/files', 'ui', 'background_runtime_uncertain', 'background', -1);
  assert.equal(state.events().find(item => item.phase === 'context.status_available').code, 0);
  state.files.set('/files/vpn-probe-status.txt', 'state=RunningSecret | heartbeatMs=999999999999999999999 | tunRead=999999999999999999999');
  state.store.recordDetailed('/files', 'vpn', 'vpn_snapshot_unavailable', 'status', -1, { retryCount: NaN });
  const events = state.events().filter(item => item.source === 'vpn');
  assert.equal(events.find(item => item.phase === 'context.runtime_state').code, 0);
  assert.equal(events.find(item => item.phase === 'context.heartbeat_age_ms').code, -1);
  assert.equal(events.find(item => item.phase === 'context.tun_read_packets').code, -1);
  assert.equal(events.find(item => item.phase === 'context.retry_count').code, -1);
});

test('retention never leaves context rows without their primary event and remains bounded', () => {
  const state = fixture(); state.runtime();
  for (let index = 0; index < 110; index++) {
    state.now++;
    state.store.recordDetailed('/files', 'vpn', 'vpn_network_refresh_failed', 'network', 201,
      { networkGeneration: index, retryCount: index, tunActive: true });
  }
  const events = state.events();
  assert.ok(events.length <= 100);
  assert.ok(!events[0].phase.startsWith('context.'));
  let primary;
  for (const event of events) {
    if (!event.phase.startsWith('context.')) primary = event;
    else assert.equal(event.timestampMs, primary.timestampMs);
  }
  assert.equal(events.at(-1).timestampMs, state.now);
  assert.ok(Buffer.byteLength(state.files.get('/files/diagnostic-vpn-events.ndjson')) <= 24 * 1024);
});

test('routine media polling cannot evict disconnect context or hide it from the human summary', () => {
  const state = fixture(); state.runtime();
  state.store.recordDetailed('/files', 'vpn', 'vpn_snapshot_unavailable', 'status', 201,
    { networkGeneration: 4, tunActive: true });
  const failureTimestamp = state.now;
  for (let index = 0; index < 150; index++) {
    state.now += 30000;
    state.store.record('/files', 'vpn', 'media_probe_started', 'requested');
    state.now++;
    state.store.record('/files', 'vpn', 'media_probe_completed', 'no_service');
    state.now++;
    state.store.record('/files', 'vpn', 'media_probe_available', 'service_confirmed');
  }
  const events = state.events();
  assert.equal(events.filter(item => item.event.startsWith('media_probe_')).length, 20);
  const failure = events.filter(item => item.timestampMs === failureTimestamp);
  assert.equal(failure[0].event, 'vpn_snapshot_unavailable');
  assert.equal(failure[0].code, 201);
  assert.equal(failure.find(item => item.phase === 'context.network_generation').code, 4);
  assert.equal(failure.find(item => item.phase === 'context.heartbeat_age_ms').code, 500);
  assert.equal(events.at(-1).timestampMs, state.now);
  assert.ok(events.length <= 100);
  assert.ok(Buffer.byteLength(state.files.get('/files/diagnostic-vpn-events.ndjson')) <= 24 * 1024);
  loadSource('services/DiagnosticReportService', state.sandbox);
  const summary = state.sandbox.DiagnosticReportService.buildSummary({
    device: {}, application: {}, network: {}, status: { backend: {}, vpnExtension: {} },
    vpnConfig: {}, tunCounters: {}, events, privacy: {},
    features: { selection: {}, quickTransferHosPlayer: {}, serviceMonitoring: {}, security: {}, appearance: {} }
  });
  assert.match(summary, /vpn_snapshot_unavailable status code=201/);
});

test('media errors and contextual event groups are not treated as routine polling', () => {
  const state = fixture(); state.runtime();
  state.store.record('/files', 'vpn', 'media_probe_failed', 'extension', -1);
  state.now++;
  state.store.record('/files', 'vpn', 'media_probe_completed', 'no_service', 201);
  state.now++;
  state.store.recordDetailed('/files', 'vpn', 'media_probe_started', 'requested', 0, { tunActive: true });
  const detailedTimestamp = state.now;
  for (let index = 0; index < 120; index++) {
    state.now++;
    state.store.record('/files', 'vpn', 'media_probe_started', 'requested');
  }
  const events = state.events();
  assert.ok(events.some(item => item.event === 'media_probe_failed' && item.code === -1));
  assert.ok(events.some(item => item.event === 'media_probe_completed' && item.code === 201));
  const detailed = events.filter(item => item.timestampMs === detailedTimestamp);
  assert.equal(detailed[0].phase, 'requested');
  assert.equal(detailed.at(-1).phase, 'context.tun_active');
  assert.ok(detailed.length > 1);
  assert.ok(events.length <= 100);
});

test('mixed UI and VPN routine polling preserves background context and readable lifecycle history', () => {
  const state = fixture(); state.runtime();
  state.store.recordDetailed('/files', 'ui', 'background_task_cancelled', 'system_cancel', 201,
    { cancellationRevision: 3, userSuppressed: false });
  state.now++;
  state.store.recordDetailed('/files', 'vpn', 'vpn_network_refresh_failed', 'network', 201,
    { networkGeneration: 4, tunActive: true });
  for (let index = 0; index < 150; index++) {
    state.now += 30000;
    state.store.record('/files', 'ui', 'peer_service_refresh_start', 'requested');
    state.store.record('/files', 'ui', 'peer_path_result', 'direct');
    state.store.record('/files', 'ui', 'sunshine_probe_success', 'available');
    state.store.record('/files', 'ui', 'media_probe_no_service', 'derp');
    state.store.record('/files', 'ui', 'media_probe_success', 'peerRelay');
    state.store.record('/files', 'vpn', 'media_probe_started', 'requested');
    state.store.record('/files', 'vpn', 'media_probe_completed', 'no_service');
  }
  const events = state.events();
  assert.equal(events.filter(item => item.source === 'ui' && !item.event.startsWith('background_')).length, 20);
  assert.equal(events.filter(item => item.source === 'vpn' && item.event.startsWith('media_probe_')).length, 20);
  assert.equal(events.find(item => item.phase === 'context.cancellation_revision').code, 3);
  assert.equal(events.find(item => item.phase === 'context.network_generation').code, 4);
  for (const source of ['ui', 'vpn']) {
    assert.ok(events.filter(item => item.source === source).length <= 100);
    assert.ok(Buffer.byteLength(state.files.get('/files/diagnostic-' + source + '-events.ndjson')) <= 24 * 1024);
  }
  loadSource('services/DiagnosticReportService', state.sandbox);
  const summary = state.sandbox.DiagnosticReportService.buildSummary({
    device: {}, application: {}, network: {}, status: { backend: {}, vpnExtension: {} },
    vpnConfig: {}, tunCounters: {}, events, privacy: {},
    features: { selection: {}, quickTransferHosPlayer: {}, serviceMonitoring: {}, security: {}, appearance: {} }
  });
  assert.match(summary, /background_task_cancelled system_cancel code=201/);
  assert.match(summary, /context.cancellation_revision value=3/);
  assert.match(summary, /vpn_network_refresh_failed network code=201/);
  assert.match(summary, /context.network_generation value=4/);
  assert.doesNotMatch(summary, /peer_service_refresh_start requested code=0/);
});

test('UI error codes, failed paths and contextual groups are not routine service polling', () => {
  const state = fixture(); state.runtime();
  state.store.record('/files', 'ui', 'peer_path_result', 'unreachable');
  state.now++;
  state.store.record('/files', 'ui', 'peer_path_result', 'unknown');
  state.now++;
  state.store.record('/files', 'ui', 'sunshine_probe_success', 'available', 201);
  state.now++;
  state.store.recordDetailed('/files', 'ui', 'peer_service_refresh_start', 'requested', 0,
    { userSuppressed: true });
  const detailedTimestamp = state.now;
  for (let index = 0; index < 120; index++) {
    state.now++;
    state.store.record('/files', 'ui', 'peer_path_result', 'direct');
  }
  const events = state.events();
  assert.ok(events.some(item => item.phase === 'unreachable'));
  assert.ok(events.some(item => item.phase === 'unknown'));
  assert.ok(events.some(item => item.event === 'sunshine_probe_success' && item.code === 201));
  const detailed = events.filter(item => item.timestampMs === detailedTimestamp);
  assert.equal(detailed[0].phase, 'requested');
  assert.equal(detailed.at(-1).phase, 'context.user_suppressed');
  assert.equal(detailed.at(-1).code, 1);
});

test('human summary falls back to retained events when no lifecycle history exists', () => {
  const state = fixture();
  state.store.record('/files', 'ui', 'peer_path_result', 'unreachable', 201);
  loadSource('services/DiagnosticReportService', state.sandbox);
  const summary = state.sandbox.DiagnosticReportService.buildSummary({
    device: {}, application: {}, network: {}, status: { backend: {}, vpnExtension: {} },
    vpnConfig: {}, tunCounters: {}, events: state.events(), privacy: {},
    features: { selection: {}, quickTransferHosPlayer: {}, serviceMonitoring: {}, security: {}, appearance: {} }
  });
  assert.match(summary, /peer_path_result unreachable code=201/);
});

test('legacy rows remain readable and malformed or invalid timestamps do not break export', () => {
  const state = fixture();
  const legacy = { timestampMs: 123, source: 'vpn', event: 'vpn_created', phase: 'create', code: 0 };
  state.files.set('/files/diagnostic-vpn-events.ndjson', JSON.stringify(legacy) + '\n{bad\n' +
    JSON.stringify({ ...legacy, timestampMs: 9999999999999999 }));
  assert.deepEqual(state.events(), [legacy]);
  state.store.recordDetailed('/files', 'vpn', 'vpn_extension_destroyed', 'system_lifecycle', 0);
  assert.equal(state.events()[0].event, 'vpn_created');
});

test('logging failures never escape into VPN lifecycle and always close acquired descriptors', () => {
  const state = fixture(); state.openError = true;
  assert.doesNotThrow(() => state.store.recordDetailed('/files', 'vpn', 'vpn_create_failed', 'create', 201));
  state.openError = false; state.writeError = true;
  assert.doesNotThrow(() => state.store.recordDetailed('/files', 'vpn', 'vpn_create_failed', 'create', 201));
  assert.equal(state.closed, 1);
  assert.equal(state.descriptors.size, 0);
});

test('numeric business errors survive JSON serialization without retaining exception messages', () => {
  const state = fixture();
  const error = state.sandbox.DiagnosticPrivacy.classifyError({ code: 201, message: 'permission denied /private/account' });
  assert.equal(error.code, 201);
  assert.equal(error.category, 'permission');
  assert.doesNotMatch(JSON.stringify(error), /private|account|message/);
  assert.equal(state.sandbox.DiagnosticPrivacy.classifyError('FAILED | errno=-5').code, -5);
  assert.equal(state.sandbox.DiagnosticPrivacy.classifyError('code=999999999999999999').code, 0);
});

test('VPN diagnostic context distinguishes explicit stop from system lifecycle and throttles repeats', () => {
  const state = fixture(); state.runtime();
  loadSource('vpnextensionability/TailscaleVpnExtensionAbility', state.sandbox);
  const extension = Object.create(state.sandbox.TailscaleVpnExtensionAbility.prototype);
  Object.assign(extension, { context: { filesDir: '/files' }, tunFd: 9, explicitStopRequested: false,
    lastDiagnosticFailure: '', lastDiagnosticFailureAtMs: 0 });
  extension.recordDiagnosticEvent('vpn_snapshot_unavailable', 'status', 201);
  const writes = state.writes;
  state.now += 1000; extension.recordDiagnosticEvent('vpn_snapshot_unavailable', 'status', 201);
  assert.equal(state.writes, writes);
  state.now += 30000; extension.recordDiagnosticEvent('vpn_snapshot_unavailable', 'status', 201);
  assert.equal(state.writes, writes + 1);
  extension.explicitStopRequested = true;
  extension.recordDiagnosticEvent('vpn_disconnect_requested', 'user_request');
  assert.equal(state.events().at(-1).phase, 'context.shutdown_requested');
  assert.equal(state.events().at(-1).code, 1);
});

test('exported human summary includes timestamp, original error code and readable context', () => {
  const state = fixture(); state.runtime();
  state.store.recordDetailed('/files', 'vpn', 'vpn_network_refresh_failed', 'network', 201, { networkStage: 2 });
  loadSource('services/DiagnosticReportService', state.sandbox);
  const summary = state.sandbox.DiagnosticReportService.buildSummary({
    device: {}, application: {}, network: {}, status: { backend: {}, vpnExtension: {} },
    vpnConfig: {}, tunCounters: {}, events: state.events(), privacy: {},
    features: { selection: {}, quickTransferHosPlayer: {}, serviceMonitoring: {}, security: {}, appearance: {} }
  });
  assert.match(summary, /1970-01-01T00:16:40\.000Z \[vpn\] vpn_network_refresh_failed network code=201/);
  assert.match(summary, /context\.network_stage value=2/);
  assert.doesNotMatch(summary, /private-user|100\.101|private-token/);
});

for (const outcome of ['resolve', 'reject']) {
  test('a snapshot that completes after explicit stop cannot overwrite state or log a new failure: ' + outcome, async () => {
    const state = fixture(); const timers = []; let complete; let fail;
    const snapshot = new Promise((resolve, reject) => { complete = resolve; fail = reject; });
    state.sandbox.setInterval = callback => { timers.push(callback); return timers.length; };
    state.sandbox.clearInterval = () => {};
    state.sandbox.nativeBridge = { backendSnapshot: () => snapshot };
    loadSource('vpnextensionability/TailscaleVpnExtensionAbility', state.sandbox);
    const extension = Object.create(state.sandbox.TailscaleVpnExtensionAbility.prototype);
    const observed = [];
    Object.assign(extension, { statusTimer: -1, taildropRequestTimer: -1, taildropIncomingTimer: -1,
      refreshDeviceSnapshot() {},
      dnsObserver: { start() {}, refresh: async () => {} },
      statusUpdateInFlight: false, backendStopInFlight: false, destroying: false, explicitStopRequested: false });
    for (const method of ['refreshTaildropIncomingNotification', 'writeCurrentStatusHeartbeat',
      'processTaildropSendRequest', 'processTaildropCancelRequest', 'processTaildropReceiveRequest',
      'processTaildriveQueryRequest', 'processTaildriveTransferRequest', 'processTaildriveManualTransferRequest',
      'processTaildriveControlRequest']) extension[method] = () => {};
    extension.processBackendStopRequest = () => false;
    extension.writeStatus = status => observed.push(status);
    extension.recordDiagnosticEvent = event => observed.push(event);
    extension.startStatusUpdates(); timers.at(-1)();
    extension.explicitStopRequested = true;
    if (outcome === 'resolve') complete(JSON.stringify({ status: 'OK | state=Running', taildrop: {} }));
    else fail({ code: 201 });
    for (let index = 0; index < 10; index++) await Promise.resolve();
    assert.deepEqual(observed, []);
    assert.equal(extension.statusUpdateInFlight, false);
  });
}


test('summary replacement survives short writes and preserves old data on zero writes', () => {
  const f = fixture(); f.shortWrite = true;
  f.store.record('/files', 'ui', 'first', 'runtime', 1);
  assert.equal(f.events()[0].event, 'first');
  f.zeroWrite = true;
  f.store.record('/files', 'ui', 'second', 'runtime', 2);
  assert.equal(f.events().length, 1);
  assert.equal(f.events()[0].event, 'first');
  assert.equal(f.descriptors.size, 0);
});
