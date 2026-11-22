import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
import { loadEtsModules, readEtsSource } from './helpers/ets-vm-loader.mjs';

const source = readFileSync(new URL('../entry/src/main/ets/components/BridgeStatus.ets', import.meta.url), 'utf8');
const one = { key: 'one', os: 'windows', online: true, addresses: ['100.64.0.1'] };
const two = { key: 'two', os: 'windows', online: true, addresses: ['100.64.0.2'] };
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
};

function loadPeerCtrl(scope) {
  loadEtsModules([
    'services/AtomicFileStore', 'services/DiagnosticPrivacy', 'services/ControlServerConfig',
    'services/HomeReadOnlyGateway', 'services/AccountDiagnosticsGateway',
    'services/FileTransferPreferences', 'services/StreamingModels',
    'services/StreamProfileBuilder', 'services/MediaIntegrationModels'
  ], scope);
  const gw = readEtsSource('services/VpnCommandGateway')
    .replace(/^import\s+['"][^'"]+['"]\s*;?[ \t]*\r?$/gm, '')
    .replace(/^import\s+(?:type\s+)?[\s\S]*?\bfrom\s+['"][^'"]+['"]\s*;?[ \t]*\r?$/gm, '')
    .replace(/^export\s+/gm, '');
  vm.runInContext(
    `${stripTypeScriptTypes(gw, { mode: 'transform' })}\nglobalThis.VpnCommandState = VpnCommandState; globalThis.VpnCoreCommand = VpnCoreCommand; globalThis.VpnCommandStateMachine = VpnCommandStateMachine; globalThis.VpnCommandGateway = VpnCommandGateway;`,
    scope
  );
  loadEtsModules(['services/PeerIntegrationController'], scope);
}

function fixture() {
  let now = 1000, nextTimer = 1, wallOffset = 0, sleepOffset = 0, clockFails = false;
  const timers = new Map();
  const names = ['refreshSelectedPeerServicesManually', 'stopDeviceDetailRefreshPolling',
    'startDeviceDetailRefreshPolling', 'openPeerDetails', 'resetStreamingStatesForDisconnect',
    'invalidateRemoteStreamLaunch', 'invalidateDeviceDetailServiceRefresh'];
  const methods = names.map(name => {
    const match = source.match(new RegExp(`^  private (?:async )?${name}\\([\\s\\S]*?^  \\}`, 'm'))?.[0];
    assert.ok(match, name);
    return match.replace(/^  private (async )?/, '$1function ');
  });
  const refreshArrow = source.match(/onRefresh: \(\): Promise<void> => this\.refreshSelectedPeerServicesManually\([^\n]+/)?.[0];
  assert.ok(refreshArrow);
  const callback = refreshArrow.replace('onRefresh: ', '').replace(/,\s*$/, '');
  const sandbox = {
    Date: { now: () => now + wallOffset }, FAST_REFRESH_INTERVAL_MS: 4000,
    systemDateTime: { TimeType: { STARTUP: 0, ACTIVE: 1 }, getUptime(type, nano) {
      assert.equal(nano, false); if (clockFails) throw new Error('clock unavailable');
      return now + (type === 0 ? sleepOffset : 0);
    } },
    setInterval() { return nextTimer++; },
    setTimeout(cb, delay) { const id = nextTimer++; timers.set(id, { at: now + delay, callback: cb }); return id; },
    clearInterval(id) { timers.delete(id); }, clearTimeout(id) { timers.delete(id); },
    fileIo: {}, nativeBridge: {}, vpnExtension: {}, connection: {},
    SunshineProbeService: class {}, PeerPathService: class {}, MoonlightLauncher: class {},
    MediaServiceProbeService: class {}, HosPlayerLauncher: class {}
  };
  loadPeerCtrl(sandbox);
  vm.runInContext(stripTypeScriptTypes(methods.join('\n') + `\nfunction refreshCallback(peer) { return ${callback}; }`), sandbox);
  const local = deferred();
  const state = {
    appShellReady: true, remoteStreamAppInForeground: true, deviceDetailVisible: true, selectedPeerKey: one.key,
    appLockRequired: false, appLockAuthenticating: false, lifecycleGeneration: 1, connected: true,
    deviceDetailServiceRefreshInFlight: false, deviceDetailRefreshTimer: -1, deviceDetailPresentationId: 0,
    peers: [one, two], calls: [], localPromise: local.promise, streamingStates: [], mediaStates: [],
    isConnected() { return this.connected; }, peerEffectivelyOnline(peer) { return peer.online; },
    peerDisplayName: value => value, peerDeviceDescription: () => '',
    refreshSelectedPeerDetails() {},
    refreshTaildropSnapshot(connected) { this.calls.push(['taildrop', connected]); },
    refreshPeerSnapshot() { this.calls.push(['snapshot']); },
    refreshPeerServices(peer, manual) { this.peerIntegrationController.refreshPeerServices(peer, manual); },
    ...Object.fromEntries(names.map(name => [name, sandbox[name]]))
  };
  const ctrl = new sandbox.PeerIntegrationController({
    getFilesDir: () => '/files', getAbilityContext: () => ({ filesDir: '/files' }),
    getLifecycleGeneration: () => state.lifecycleGeneration, getNavigationRevision: () => 0, getTrafficSession: () => 1,
    isAppShellReady: () => state.appShellReady, isRemoteStreamAppInForeground: () => state.remoteStreamAppInForeground,
    setRemoteStreamAppInForeground: v => { state.remoteStreamAppInForeground = v; },
    isAppLockRequired: () => state.appLockRequired, isAppLockAuthenticating: () => state.appLockAuthenticating,
    isConnected: () => state.connected, getPeers: () => state.peers,
    peerEffectivelyOnline: peer => state.peerEffectivelyOnline(peer), getSelectedPeerKey: () => state.selectedPeerKey,
    isDeviceDetailVisible: () => state.deviceDetailVisible, setDeviceDetailVisible: v => { state.deviceDetailVisible = v; },
    getDeviceDetailPresentationId: () => state.deviceDetailPresentationId,
    isDeviceDetailServiceRefreshInFlight: () => state.deviceDetailServiceRefreshInFlight,
    setDeviceDetailServiceRefreshInFlight: v => { state.deviceDetailServiceRefreshInFlight = v; },
    isTransferProtocolRefreshing: () => false, setTransferProtocolRefreshing() {},
    getStreamingStates: () => state.streamingStates, setStreamingStates: s => { state.streamingStates = s; },
    getMediaStates: () => state.mediaStates, setMediaStates: s => { state.mediaStates = s; },
    isFakeMediaServiceOnline: () => false, getFakeJellyfinName: () => 'Jellyfin',
    isMediaSelfTestInProgress: () => false, setMediaSelfTestInProgress() {}, setMediaSelfTestStatusKind() {},
    getLocalSendPortOverrides: () => [], setLocalSendPortOverrides() {},
    getRemotePortPeerKey: () => '', getRemotePortInput: () => '', setRemotePortEditorVisible() {},
    setTaildropFocusedTargetKey() {}, getTaildropFocusedTargetKey: () => '',
    refreshBackendStatus: async () => {}, refreshPeerSnapshot: () => state.refreshPeerSnapshot(),
    refreshTaildropSnapshot: connected => state.refreshTaildropSnapshot(connected),
    logServiceStatusIfChanged() {}, scheduleLifecycleTask: () => -1, showPeerIntegrationToast() {},
    showDerpStreamConfirmationDialog() {}, showMoonlightRequiredDialog() {},
    copyHosPlayerPrototypeText() {}, recordDiagnosticEvent() {}, recordFeatureDiagnosticEvent() {}
  });
  ctrl.refreshPeerServices = (peer, manual) => { state.calls.push(['probe', peer.key, manual]); ctrl.peerServiceRefreshInFlight.add(peer.key); };
  ctrl.requestLocalSendRefresh = () => { state.calls.push(['localsend']); return state.localPromise; };
  state.peerIntegrationController = ctrl;
  Object.defineProperty(state, 'peerServiceRefreshInFlight', { get: () => ctrl.peerServiceRefreshInFlight });
  Object.defineProperty(state, 'deviceDetailServiceRefreshRequestId', {
    get: () => ctrl.deviceDetailServiceRefreshRequestId, set: v => { ctrl.deviceDetailServiceRefreshRequestId = v; }
  });
  const microtasks = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
  const advance = async duration => {
    const target = now + duration;
    await microtasks();
    for (;;) {
      const item = [...timers].filter(([, timer]) => timer.at <= target).sort((a, b) => a[1].at - b[1].at)[0];
      if (!item) break;
      const [id, timer] = item; timers.delete(id); now = timer.at; timer.callback(); await microtasks();
    }
    now = target; await microtasks();
  };
  return { state, local, advance, pendingTimers: () => timers.size, callback: peer => sandbox.refreshCallback.call(state, peer),
    wall(value) { wallOffset = value - now; },
    sleep(duration) { wallOffset += duration; sleepOffset += duration; },
    failClock(value) { clockFails = value; },
    retire() { state.deviceDetailVisible = false; state.stopDeviceDetailRefreshPolling(); },
    select(peer) { state.stopDeviceDetailRefreshPolling(); state.selectedPeerKey = peer.key; state.deviceDetailVisible = true; } };
}

test('a manual refresh claims one transaction and keeps the minimum visible frame', async () => {
  const f = fixture(), { state } = f;
  const work = f.callback(one)();
  await f.callback(one)();
  assert.equal(state.calls.filter(call => call[0] === 'probe').length, 1);
  assert.equal(state.deviceDetailServiceRefreshInFlight, true);
  state.peerServiceRefreshInFlight.clear(); f.local.resolve();
  await f.advance(219); assert.equal(state.deviceDetailServiceRefreshInFlight, true);
  await f.advance(1); await work; assert.equal(state.deviceDetailServiceRefreshInFlight, false);
});

test('switching details releases the old spinner and lets the new peer refresh immediately', async () => {
  const f = fixture(), { state } = f;
  const oldWork = f.callback(one)();
  f.select(two);
  assert.equal(state.deviceDetailServiceRefreshInFlight, false);
  const newWork = f.callback(two)();
  assert.deepEqual(state.calls.filter(call => call[0] === 'probe').map(call => call[1]), ['one', 'two']);
  state.peerServiceRefreshInFlight.clear(); f.local.resolve(); await f.advance(220);
  await Promise.all([oldWork, newWork]);
});

test('an old completion cannot release a newer transaction spinner', async () => {
  const f = fixture(), { state } = f;
  const oldWork = f.callback(one)();
  f.select(two); const later = deferred(); state.localPromise = later.promise;
  const newWork = f.callback(two)();
  state.peerServiceRefreshInFlight.delete(one.key); f.local.resolve(); await f.advance(220); await oldWork;
  assert.equal(state.deviceDetailServiceRefreshInFlight, true);
  state.peerServiceRefreshInFlight.clear(); later.resolve(); await f.advance(220); await newWork;
  assert.equal(state.deviceDetailServiceRefreshInFlight, false);
});

test('a saved refresh callback cannot refresh the newly selected peer', async () => {
  const f = fixture(), callback = f.callback(one); f.state.selectedPeerKey = two.key;
  const work = callback(); f.local.resolve(); f.state.peerServiceRefreshInFlight.clear(); await f.advance(220); await work;
  assert.deepEqual(f.state.calls, []);
});

for (const [name, invalidate] of [
  ['closed sheet', state => { state.deviceDetailVisible = false; }],
  ['changed selection', state => { state.selectedPeerKey = two.key; }],
  ['inactive shell', state => { state.appShellReady = false; }],
  ['new lifecycle', state => { state.lifecycleGeneration++; }],
  ['disconnect', state => { state.connected = false; }],
  ['locked app', state => { state.appLockRequired = true; }],
  ['authenticating app', state => { state.appLockAuthenticating = true; }],
  ['removed peer', state => { state.peers = [two]; }],
  ['offline peer', state => { state.peers = [{ ...one, online: false }, two]; }]
]) test(`${name} rejects late snapshot publication`, async () => {
  const f = fixture(), work = f.callback(one)();
  invalidate(f.state); f.state.peerServiceRefreshInFlight.clear(); f.local.resolve(); await f.advance(220); await work;
  assert.equal(f.state.calls.filter(call => call[0] === 'snapshot').length, 0);
  assert.equal(f.state.calls.filter(call => call[0] === 'taildrop').length, 1);
  assert.equal(f.state.deviceDetailServiceRefreshInFlight, false);
});

test('app locking also rejects a new manual refresh before starting work', async () => {
  for (const key of ['appLockRequired', 'appLockAuthenticating']) {
    const f = fixture(); f.state[key] = true;
    const work = f.callback(one)(); f.local.resolve(); f.state.peerServiceRefreshInFlight.clear(); await f.advance(220); await work;
    assert.deepEqual(f.state.calls, []);
  }
});

test('a reused opening probe is awaited instead of started twice', async () => {
  const f = fixture(); f.state.peerServiceRefreshInFlight.add(one.key);
  const work = f.callback(one)(); assert.equal(f.state.calls.some(call => call[0] === 'probe'), false);
  f.state.peerServiceRefreshInFlight.clear(); f.local.resolve(); await f.advance(220); await work;
  assert.equal(f.state.calls.filter(call => call[0] === 'snapshot').length, 1);
});

test('snapshot IO failure at start still runs the probes and releases the transaction', async () => {
  const f = fixture(); f.state.refreshTaildropSnapshot = () => { throw new Error('snapshot replaced'); };
  const work = f.callback(one)(); const checked = assert.rejects(work, /snapshot replaced/);
  assert.equal(f.state.calls.some(call => call[0] === 'probe'), true);
  f.state.peerServiceRefreshInFlight.clear(); f.local.resolve(); await f.advance(220); await checked;
  assert.equal(f.state.deviceDetailServiceRefreshInFlight, false);
});

test('opening a new peer through the production path retires the previous spinner', async () => {
  const f = fixture(), oldWork = f.callback(one)();
  f.state.openPeerDetails(two);
  assert.equal(f.state.deviceDetailServiceRefreshInFlight, false);
  assert.equal(f.state.selectedPeerKey, two.key);
  f.local.resolve(); await f.advance(100); await oldWork;
  assert.equal(f.state.peerServiceRefreshInFlight.has(one.key), true, 'shared probe remains running');
});

test('reopening the same peer also retires the previous presentation', async () => {
  const f = fixture(), oldWork = f.callback(one)();
  f.retire(); f.state.openPeerDetails(one); const later = deferred(); f.state.localPromise = later.promise;
  const newWork = f.callback(one)();
  f.local.resolve(); await f.advance(100); await oldWork;
  assert.equal(f.state.deviceDetailServiceRefreshInFlight, true);
  f.state.peerServiceRefreshInFlight.clear(); later.resolve(); await f.advance(220); await newWork;
});

test('a newer refresh remains visible when the old minimum-frame delay expires', async () => {
  const f = fixture(), oldWork = f.callback(one)();
  f.state.peerServiceRefreshInFlight.clear(); f.local.resolve(); await f.advance(100);
  f.select(two); const later = deferred(); f.state.localPromise = later.promise;
  const newWork = f.callback(two)();
  await f.advance(120); await oldWork;
  assert.equal(f.state.deviceDetailServiceRefreshInFlight, true);
  f.state.peerServiceRefreshInFlight.clear(); later.resolve(); await f.advance(220); await newWork;
});

test('production disconnect reset immediately releases visible refresh ownership', async () => {
  const f = fixture(), oldWork = f.callback(one)();
  f.state.connected = false; f.state.resetStreamingStatesForDisconnect();
  assert.equal(f.state.deviceDetailServiceRefreshInFlight, false);
  f.local.resolve(); await f.advance(100); await oldWork;
  assert.equal(f.state.calls.some(call => call[0] === 'snapshot'), false);
});

test('the existing six-second wait stays bounded without cancelling the shared probe', async () => {
  const f = fixture(), work = f.callback(one)(); f.local.resolve();
  await f.advance(5999); assert.equal(f.state.deviceDetailServiceRefreshInFlight, true);
  await f.advance(1); await work;
  assert.equal(f.state.deviceDetailServiceRefreshInFlight, false);
  assert.equal(f.state.peerServiceRefreshInFlight.has(one.key), true);
});

test('a LocalSend rejection releases the owner and retires its leftover wait timer', async () => {
  const f = fixture(), work = f.callback(one)();
  const rejected = assert.rejects(work, /localsend failed/);
  f.local.reject(new Error('localsend failed')); await f.advance(220); await rejected;
  assert.equal(f.state.deviceDetailServiceRefreshInFlight, false);
  await f.advance(100); assert.equal(f.pendingTimers(), 0);
});

test('backward wall-clock adjustment cannot extend the peer wait beyond six seconds', async () => {
  const f = fixture(), work = f.callback(one)(); f.local.resolve(); f.wall(-1000000);
  await f.advance(6000); const busyAtDeadline = f.state.deviceDetailServiceRefreshInFlight;
  f.state.peerServiceRefreshInFlight.clear(); f.wall(1000000); await f.advance(220); await work;
  assert.equal(busyAtDeadline, false);
});

test('forward wall-clock adjustment cannot end the peer wait prematurely', async () => {
  const f = fixture(), work = f.callback(one)(); f.local.resolve(); f.wall(1000000);
  await f.advance(5999); const busyBeforeDeadline = f.state.deviceDetailServiceRefreshInFlight;
  await f.advance(1); await work;
  assert.equal(busyBeforeDeadline, true); assert.equal(f.state.deviceDetailServiceRefreshInFlight, false);
});

test('backward wall-clock adjustment cannot inflate the 220ms loading frame', async () => {
  const f = fixture(), work = f.callback(one)(); f.state.peerServiceRefreshInFlight.clear(); f.local.resolve();
  f.wall(-1000000); await f.advance(220); const busyAfterFrame = f.state.deviceDetailServiceRefreshInFlight;
  await f.advance(2000000); await work;
  assert.equal(busyAfterFrame, false);
});

test('forward wall-clock adjustment does not remove the minimum visible frame', async () => {
  const f = fixture(), work = f.callback(one)(); f.state.peerServiceRefreshInFlight.clear(); f.local.resolve();
  f.wall(1000000); await f.advance(100); const busyDuringFrame = f.state.deviceDetailServiceRefreshInFlight;
  await f.advance(120); await work;
  assert.equal(busyDuringFrame, true); assert.equal(f.state.deviceDetailServiceRefreshInFlight, false);
});

test('sleep time counts toward the six-second wait after the event loop resumes', async () => {
  const f = fixture(), work = f.callback(one)(); f.local.resolve(); f.sleep(12000);
  await f.advance(100); const busyAfterResume = f.state.deviceDetailServiceRefreshInFlight;
  f.state.peerServiceRefreshInFlight.clear(); await f.advance(6000); await work;
  assert.equal(busyAfterResume, false);
});

test('an initial clock failure starts no work and does not prevent a later refresh', async () => {
  const f = fixture(); f.failClock(true);
  const result = f.callback(one)().then(() => '', error => error.message);
  f.state.peerServiceRefreshInFlight.clear(); f.local.resolve(); await f.advance(220);
  assert.equal(await result, 'clock unavailable'); assert.deepEqual(f.state.calls, []);
  assert.equal(f.state.deviceDetailServiceRefreshInFlight, false);
  f.failClock(false); const later = f.callback(one)(); f.state.peerServiceRefreshInFlight.clear();
  await f.advance(220); await later; assert.equal(f.state.deviceDetailServiceRefreshInFlight, false);
});

test('a clock failure during peer wait still releases the visible owner', async () => {
  const f = fixture(), result = f.callback(one)().then(() => '', error => error.message);
  f.local.resolve(); f.failClock(true); await f.advance(100);
  const busyAfterFailure = f.state.deviceDetailServiceRefreshInFlight;
  f.state.peerServiceRefreshInFlight.clear(); await f.advance(220);
  assert.equal(await result, 'clock unavailable'); assert.equal(busyAfterFailure, false);
});

test('a clock failure in the minimum-frame cleanup cannot leave loading latched', async () => {
  const f = fixture(), result = f.callback(one)().then(() => '', error => error.message);
  f.state.peerServiceRefreshInFlight.clear(); f.local.resolve(); f.failClock(true);
  await f.advance(220);
  assert.equal(await result, 'clock unavailable'); assert.equal(f.state.deviceDetailServiceRefreshInFlight, false);
});
