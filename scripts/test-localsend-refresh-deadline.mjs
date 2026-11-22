import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
import { loadEtsModules, readEtsSource } from './helpers/ets-vm-loader.mjs';

function loadPeerIntegrationController(scope) {
  loadEtsModules([
    'services/AtomicFileStore',
    'services/DiagnosticPrivacy',
    'services/ControlServerConfig',
    'services/HomeReadOnlyGateway',
    'services/AccountDiagnosticsGateway',
    'services/FileTransferPreferences',
    'services/StreamingModels',
    'services/StreamProfileBuilder',
    'services/MediaIntegrationModels'
  ], scope);
  const gwRaw = readEtsSource('services/VpnCommandGateway')
    .replace(/^import\s+['"][^'"]+['"]\s*;?[ \t]*\r?$/gm, '')
    .replace(/^import\s+(?:type\s+)?[\s\S]*?\bfrom\s+['"][^'"]+['"]\s*;?[ \t]*\r?$/gm, '')
    .replace(/^export\s+/gm, '');
  const gwJs = stripTypeScriptTypes(gwRaw, { mode: 'transform' });
  vm.runInContext(
    `${gwJs}\nglobalThis.VpnCommandState = VpnCommandState; globalThis.VpnCoreCommand = VpnCoreCommand; globalThis.VpnCommandStateMachine = VpnCommandStateMachine; globalThis.VpnCommandGateway = VpnCommandGateway;`,
    scope
  );
  loadEtsModules(['services/PeerIntegrationController'], scope);
}

function fixture() {
  let now = 1000, wall = 0, sleep = 0, clockFails = false, response = '', reads = 0, readFails = false;
  const timers = [], writes = [];
  const sandbox = {
    Date: { now: () => now + wall },
    systemDateTime: {
      TimeType: { STARTUP: 0 },
      getUptime(type, nano) {
        assert.equal(type, 0);
        assert.equal(nano, false);
        if (clockFails) throw new Error('clock unavailable');
        return now + sleep;
      }
    },
    setTimeout(callback, delay) { timers.push({ at: now + delay, callback }); return timers.length; },
    clearTimeout() {},
    fileIo: {
      accessSync() { return response !== ''; },
      readTextSync() {
        reads++;
        if (readFails) { readFails = false; throw new Error('replacement in progress'); }
        return response;
      }
    },
    nativeBridge: {},
    vpnExtension: {},
    connection: {},
    SunshineProbeService: class {},
    PeerPathService: class {},
    MoonlightLauncher: class {},
    MediaServiceProbeService: class {},
    HosPlayerLauncher: class {}
  };
  loadPeerIntegrationController(sandbox);
  const reqFileName = sandbox.LOCAL_SEND_REFRESH_REQUEST_FILE_NAME;
  const respFileName = sandbox.LOCAL_SEND_REFRESH_RESPONSE_FILE_NAME;

  const state = {
    appShellReady: true,
    connected: true,
    snapshots: 0,
    backend: 0
  };
  const host = {
    getFilesDir: () => '/files',
    getAbilityContext: () => ({ filesDir: '/files' }),
    getLifecycleGeneration: () => 1,
    getNavigationRevision: () => 0,
    getTrafficSession: () => 1,
    isAppShellReady: () => state.appShellReady,
    isRemoteStreamAppInForeground: () => true,
    setRemoteStreamAppInForeground() {},
    isAppLockRequired: () => false,
    isAppLockAuthenticating: () => false,
    isConnected: () => state.connected,
    getPeers: () => [],
    peerEffectivelyOnline: () => true,
    getSelectedPeerKey: () => '',
    isDeviceDetailVisible: () => false,
    setDeviceDetailVisible() {},
    getDeviceDetailPresentationId: () => 0,
    isDeviceDetailServiceRefreshInFlight: () => false,
    setDeviceDetailServiceRefreshInFlight() {},
    isTransferProtocolRefreshing: () => false,
    setTransferProtocolRefreshing() {},
    getStreamingStates: () => [],
    setStreamingStates() {},
    getMediaStates: () => [],
    setMediaStates() {},
    isFakeMediaServiceOnline: () => false,
    getFakeJellyfinName: () => 'Jellyfin',
    isMediaSelfTestInProgress: () => false,
    setMediaSelfTestInProgress() {},
    setMediaSelfTestStatusKind() {},
    getLocalSendPortOverrides: () => [],
    setLocalSendPortOverrides() {},
    getRemotePortPeerKey: () => '',
    getRemotePortInput: () => '',
    setRemotePortEditorVisible() {},
    setTaildropFocusedTargetKey() {},
    getTaildropFocusedTargetKey: () => '',
    refreshBackendStatus: async () => { state.backend++; },
    refreshPeerSnapshot: () => { state.snapshots++; },
    refreshTaildropSnapshot() {},
    logServiceStatusIfChanged() {},
    scheduleLifecycleTask: () => -1,
    showPeerIntegrationToast() {},
    showDerpStreamConfirmationDialog() {},
    showMoonlightRequiredDialog() {},
    copyHosPlayerPrototypeText() {},
    recordDiagnosticEvent() {},
    recordFeatureDiagnosticEvent() {}
  };
  const ctrl = new sandbox.PeerIntegrationController(host, {
    vpnCommandGateway: {
      writeCommandFile(_dir, name, text) {
        writes.push({ name, text });
        if (name === respFileName) response = text;
      }
    }
  });
  state.requestLocalSendRefresh = () => ctrl.requestLocalSendRefresh();
  Object.defineProperty(state, 'localSendRefreshRequestId', {
    get: () => ctrl.localSendRefreshRequestId
  });
  Object.defineProperty(state, 'localSendRefreshPromise', {
    get: () => ctrl.localSendRefreshPromise
  });

  const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
  const advance = async duration => {
    const end = now + duration; await flush();
    while (timers.length && timers[0].at <= end) {
      const timer = timers.shift(); now = timer.at; timer.callback(); await flush();
    }
    now = end; await flush();
  };
  return {
    state,
    writes,
    advance,
    reqFileName,
    reads: () => reads,
    reply(id = state.localSendRefreshRequestId) { response = JSON.stringify({ requestId: id }); },
    wall(offset) { wall = offset; },
    sleep(ms) { sleep += ms; wall += ms; },
    failClock(value) { clockFails = value; },
    failRead() { readFails = true; },
    requestCleared() { return writes.at(-1)?.name === reqFileName && writes.at(-1)?.text === ''; }
  };
}

test('a current reply is consumed once and overlapping callers share one request', async () => {
  const f = fixture(); const a = f.state.requestLocalSendRefresh(), b = f.state.requestLocalSendRefresh();
  assert.equal(f.writes.filter(x => x.name === f.reqFileName && x.text).length, 1);
  f.reply(); await f.advance(150); await Promise.all([a, b]);
  assert.equal(f.state.snapshots, 1); assert.equal(f.state.localSendRefreshPromise, undefined);
});

test('disconnected refresh retains backend-only behavior', async () => {
  const f = fixture(); f.state.connected = false; await f.state.requestLocalSendRefresh();
  assert.equal(f.state.backend, 1); assert.equal(f.writes.length, 0);
});

for (const offset of [-3600000, 3600000]) {
  test(`wall clock change ${offset} does not alter the 25 second budget`, async () => {
    const f = fixture(); const work = f.state.requestLocalSendRefresh(); f.wall(offset);
    await f.advance(24900); assert.ok(f.state.localSendRefreshPromise);
    await f.advance(150); assert.equal(f.state.localSendRefreshPromise, undefined);
    await work; assert.equal(f.requestCleared(), true);
  });
}

test('a reply observed before the deadline is accepted', async () => {
  const f = fixture(); const work = f.state.requestLocalSendRefresh();
  await f.advance(24750); f.reply(); await f.advance(150); await work;
  assert.equal(f.state.snapshots, 1);
});

test('a reply first observed after the deadline is not read or applied', async () => {
  const f = fixture(); const work = f.state.requestLocalSendRefresh();
  await f.advance(24900); f.reply(); await f.advance(150); await work;
  assert.equal(f.reads(), 0); assert.equal(f.state.snapshots, 0); assert.equal(f.requestCleared(), true);
});

test('sleep time consumes the budget before a resumed response is read', async () => {
  const f = fixture(); const work = f.state.requestLocalSendRefresh();
  f.reply(); f.sleep(26000); await f.advance(150); await work;
  assert.equal(f.reads(), 0); assert.equal(f.state.snapshots, 0); assert.equal(f.requestCleared(), true);
});

for (const change of ['disconnect', 'shell disappearance']) {
  test(`${change} during a poll prevents a late response from being consumed`, async () => {
    const f = fixture(); const work = f.state.requestLocalSendRefresh(); f.reply();
    if (change === 'disconnect') f.state.connected = false; else f.state.appShellReady = false;
    await f.advance(150); await work;
    assert.equal(f.reads(), 0); assert.equal(f.state.snapshots, 0); assert.equal(f.requestCleared(), true);
  });
}

test('wrong response IDs and file replacement errors keep polling until a valid response', async () => {
  const f = fixture(); const work = f.state.requestLocalSendRefresh(); f.reply(-1);
  await f.advance(150); assert.equal(f.state.snapshots, 0);
  f.reply(); f.failRead(); await f.advance(150); assert.equal(f.state.snapshots, 0);
  await f.advance(150); await work; assert.equal(f.state.snapshots, 1);
});

test('an unavailable initial clock sends no extension request and permits retry', async () => {
  const f = fixture(); f.failClock(true); const first = f.state.requestLocalSendRefresh();
  assert.equal(f.writes.length, 0); await first; assert.equal(f.state.localSendRefreshPromise, undefined);
  f.failClock(false); const retry = f.state.requestLocalSendRefresh(); f.reply();
  await f.advance(150); await retry; assert.equal(f.state.snapshots, 1);
});

test('a clock failure while waiting retires the request and releases shared callers', async () => {
  const f = fixture(); const a = f.state.requestLocalSendRefresh(), b = f.state.requestLocalSendRefresh();
  f.failClock(true); f.reply(); await f.advance(150); await Promise.all([a, b]);
  assert.equal(f.reads(), 0); assert.equal(f.requestCleared(), true);
  assert.equal(f.state.localSendRefreshPromise, undefined);
});

test('timeout releases the shared operation and a later request keeps a fresh numeric ID', async () => {
  const f = fixture(); const first = f.state.requestLocalSendRefresh(); const id = f.state.localSendRefreshRequestId;
  await f.advance(25050); await first; f.wall(-3600000);
  const second = f.state.requestLocalSendRefresh(); assert.ok(f.state.localSendRefreshRequestId > id);
  f.reply(); await f.advance(150); await second; assert.equal(f.state.snapshots, 1);
});
