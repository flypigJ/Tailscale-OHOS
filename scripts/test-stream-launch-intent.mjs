import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
import { loadEtsModules, readEtsSource } from './helpers/ets-vm-loader.mjs';

const source = readFileSync(new URL('../entry/src/main/ets/components/BridgeStatus.ets', import.meta.url), 'utf8');
const peer = { key: 'one', name: 'PC', os: 'windows', addresses: ['100.64.0.1'], online: true };
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; };

function loadPeerCtrl(scope) {
  loadEtsModules([
    'services/AtomicFileStore', 'services/DiagnosticPrivacy', 'services/ControlServerConfig',
    'services/HomeReadOnlyGateway', 'services/AccountDiagnosticsGateway',
    'services/FileTransferPreferences', 'services/StreamingModels',
    'services/MediaIntegrationModels'
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

function fixture(detail = true) {
  let now = 1000, wall = 0, sleep = 0, clockFails = false;
  const timers = [], availability = [], launches = [], dialogs = [], toasts = [];
  const names = ['showDerpStreamConfirmation', 'showMoonlightRequiredAlertDialog',
    'stopDeviceDetailRefreshPolling', 'invalidateRemoteStreamLaunch', 'invalidateDeviceDetailServiceRefresh'];
  const methods = names.map(name => {
    const match = source.match(new RegExp(`^  private (?:async )?${name}\\([\\s\\S]*?^  \\}`, 'm'))?.[0];
    assert.ok(match, name); return match.replace(/^  private (async )?/, '$1function ');
  });
  const sandbox = {
    Date: { now: () => now + wall }, $r: x => x, buildStreamProfile: () => ({ profileName: 'recommended', allowUserOverride: true }),
    systemDateTime: { TimeType: { STARTUP: 0 }, getUptime(_type, nano) {
      assert.equal(nano, false); if (clockFails) throw new Error('clock unavailable'); return now + sleep;
    } },
    setTimeout(callback, delay) { timers.push({ at: now + delay, callback }); return timers.length; },
    clearTimeout() {}, clearInterval() {},
    fileIo: {}, nativeBridge: {}, vpnExtension: {}, connection: {},
    SunshineProbeService: class {}, PeerPathService: class {}, MoonlightLauncher: class {},
    MediaServiceProbeService: class {}, HosPlayerLauncher: class {}
  };
  loadPeerCtrl(sandbox);
  vm.runInContext(stripTypeScriptTypes(methods.join('\n')), sandbox);
  const initialStreaming = () => [{
    peerKey: peer.key, checking: false, launching: false,
    sunshine: { state: 'available', checkedAt: 1000 }, path: { type: 'direct', checkedAt: 1000 }
  }];
  const state = {
    appShellReady: true, remoteStreamAppInForeground: true, lifecycleGeneration: 1, navigationRevision: 1,
    activeNavigationId: 'home', appLockRequired: false, appLockAuthenticating: false,
    deviceDetailVisible: detail, selectedPeerKey: peer.key, deviceDetailPresentationId: 1,
    deviceDetailRefreshTimer: -1, streamingStates: initialStreaming(), mediaStates: [],
    peers: [{ ...peer, addresses: [...peer.addresses] }], connected: true,
    isConnected() { return this.connected; }, peerEffectivelyOnline: value => value.online,
    recordDiagnosticEvent() {}, showToast: value => toasts.push(value),
    copyDeviceValue(value) { this.copied = value; },
    getUIContext: () => ({ showAlertDialog: args => dialogs.push(args) }),
    ...Object.fromEntries(names.map(name => [name, sandbox[name]]))
  };
  const moonlight = {
    isAvailable() { const work = deferred(); availability.push(work); return work.promise; },
    launch(request) { const work = deferred(); launches.push({ request, ...work }); return work.promise; }
  };
  const ctrl = new sandbox.PeerIntegrationController({
    getFilesDir: () => '/files', getAbilityContext: () => ({ filesDir: '/files' }),
    getLifecycleGeneration: () => state.lifecycleGeneration, getNavigationRevision: () => state.navigationRevision,
    getTrafficSession: () => 1, isAppShellReady: () => state.appShellReady,
    isRemoteStreamAppInForeground: () => state.remoteStreamAppInForeground,
    setRemoteStreamAppInForeground: v => { state.remoteStreamAppInForeground = v; },
    isAppLockRequired: () => state.appLockRequired, isAppLockAuthenticating: () => state.appLockAuthenticating,
    isConnected: () => state.connected, getPeers: () => state.peers,
    peerEffectivelyOnline: value => state.peerEffectivelyOnline(value),
    getSelectedPeerKey: () => state.selectedPeerKey,
    isDeviceDetailVisible: () => state.deviceDetailVisible, setDeviceDetailVisible: v => { state.deviceDetailVisible = v; },
    getDeviceDetailPresentationId: () => state.deviceDetailPresentationId,
    isDeviceDetailServiceRefreshInFlight: () => false, setDeviceDetailServiceRefreshInFlight() {},
    isTransferProtocolRefreshing: () => false, setTransferProtocolRefreshing() {},
    getStreamingStates: () => state.streamingStates, setStreamingStates: s => { state.streamingStates = s; },
    getMediaStates: () => state.mediaStates, setMediaStates: s => { state.mediaStates = s; },
    isFakeMediaServiceOnline: () => false, getFakeJellyfinName: () => 'Jellyfin',
    isMediaSelfTestInProgress: () => false, setMediaSelfTestInProgress() {}, setMediaSelfTestStatusKind() {},
    getLocalSendPortOverrides: () => [], setLocalSendPortOverrides() {},
    getRemotePortPeerKey: () => '', getRemotePortInput: () => '', setRemotePortEditorVisible() {},
    setTaildropFocusedTargetKey() {}, getTaildropFocusedTargetKey: () => '',
    refreshBackendStatus: async () => {}, refreshPeerSnapshot() {}, refreshTaildropSnapshot() {},
    logServiceStatusIfChanged() {},
    scheduleLifecycleTask: (task, delay) => {
      const gen = state.lifecycleGeneration;
      return sandbox.setTimeout(() => { if (gen === state.lifecycleGeneration) task(); }, delay);
    },
    showPeerIntegrationToast: key => toasts.push(`app.string.${key}`),
    showDerpStreamConfirmationDialog: (p, st, intent) => state.showDerpStreamConfirmation(p, st, intent),
    showMoonlightRequiredDialog: hostAddr => state.showMoonlightRequiredAlertDialog(hostAddr),
    copyHosPlayerPrototypeText() {}, recordDiagnosticEvent() {}, recordFeatureDiagnosticEvent() {}
  }, {
    sunshineProbeService: {}, peerPathService: {}, moonlightLauncher: moonlight,
    mediaServiceProbeService: {}, hosPlayerLauncher: {}
  });
  ctrl.detectStreamingForPeer = (value, force) => {
    assert.equal(force, false, 'launch should reuse fresh successful discovery');
    ctrl.streamingRequestIds.set(value.key, (ctrl.streamingRequestIds.get(value.key) ?? 0) + 1);
    ctrl.updateStreamingState(value.key, { ...ctrl.streamingState(value.key), checking: true });
  };
  state.peerIntegrationController = ctrl;
  state.launchRemoteStream = p => ctrl.launchRemoteStream(p);
  state.streamingState = k => ctrl.streamingState(k);
  state.copyStreamingState = (...args) => ctrl.copyStreamingState(...args);
  state.updateStreamingState = (k, v) => ctrl.updateStreamingState(k, v);
  state.handleRemoteStreamAppBackground = () => ctrl.handleRemoteStreamAppBackground();
  Object.defineProperty(state, 'streamingRequestIds', { get: () => ctrl.streamingRequestIds });
  Object.defineProperty(state, 'moonlightLauncher', { get: () => ctrl.moonlightLauncher, set: v => { ctrl.moonlightLauncher = v; } });
  const flush = async () => { for (let i = 0; i < 14; i++) await Promise.resolve(); };
  const advance = async duration => {
    const end = now + duration; await flush();
    while (timers.length && timers[0].at <= end) {
      timers.sort((a, b) => a.at - b.at); const timer = timers.shift(); now = timer.at; timer.callback(); await flush();
    }
    now = end; await flush();
  };
  const completeProbe = (path = 'direct') => {
    state.updateStreamingState(peer.key, { ...state.streamingState(peer.key), checking: false,
      sunshine: { state: 'available' }, path: { type: path, latencyMs: 12, relayRegion: 'test-region' } });
  };
  return { state, advance, flush, availability, launches, dialogs, toasts, completeProbe,
    start() { state.launchRemoteStream(state.peers[0]); },
    async ready(path = 'direct') { this.start(); completeProbe(path); await advance(0); },
    wall(offset) { wall = offset; }, sleep(ms) { sleep += ms; wall += ms; }, failClock() { clockFails = true; },
    background() {
      if (state.handleRemoteStreamAppBackground) state.handleRemoteStreamAppBackground();
      else state.remoteStreamAppInForeground = false;
    },
    closeAndReopen() {
      state.deviceDetailVisible = false; state.stopDeviceDetailRefreshPolling(); state.deviceDetailVisible = true;
    }
  };
}

test('direct launch keeps the existing host and protocol parameters', async () => {
  const f = fixture(); await f.ready(); f.availability[0].resolve(true); await f.flush();
  assert.equal(f.launches.length, 1); const request = f.launches[0].request;
  assert.equal(request.host, peer.addresses[0]); assert.equal(request.protocolVersion, 1);
  assert.equal(request.action, 'openHost'); assert.equal(request.source, 'MeshArc');
  f.launches[0].resolve(); await f.flush(); assert.equal(f.state.streamingState(peer.key).launching, false);
});

test('home card entry works without opening a detail sheet', async () => {
  const f = fixture(false); await f.ready(); f.availability[0].resolve(true); await f.flush();
  assert.equal(f.launches.length, 1); f.launches[0].resolve(); await f.flush();
});

for (const phase of ['probe', 'availability']) {
  for (const change of ['detail reopened', 'navigation round trip', 'background round trip', 'lock', 'disconnect', 'offline', 'removed', 'address changed', 'probe replaced']) {
    test(`${phase}: ${change} retires the pending launch without opening another app`, async () => {
      const f = fixture(); f.start();
      if (phase === 'availability') { f.completeProbe(); await f.advance(0); }
      switch (change) {
        case 'detail reopened': f.closeAndReopen(); break;
        case 'navigation round trip': f.state.navigationRevision += 2; break;
        case 'background round trip': f.background(); f.state.remoteStreamAppInForeground = true; break;
        case 'lock': f.state.appLockRequired = true; break;
        case 'disconnect': f.state.connected = false; break;
        case 'offline': f.state.peers[0].online = false; break;
        case 'removed': f.state.peers = []; break;
        case 'address changed': f.state.peers[0] = { ...peer, addresses: ['100.64.0.2'] }; break;
        case 'probe replaced': f.state.streamingRequestIds.set(peer.key, 999); break;
      }
      if (phase === 'probe') { f.completeProbe(); await f.advance(120); }
      else { f.availability[0].resolve(true); await f.flush(); }
      assert.equal(f.availability.length, phase === 'probe' ? 0 : 1);
      assert.equal(f.launches.length, 0); assert.equal(f.state.streamingState(peer.key).launching, false);
    });
  }
}

test('DERP dismissal releases the launch and allows a fresh attempt', async () => {
  const f = fixture(); await f.ready('derp'); const dialog = f.dialogs[0]; let dismissed = false;
  if (dialog.onWillDismiss) dialog.onWillDismiss({ reason: 0, dismiss() { dismissed = true; } });
  else if (dialog.cancel) { dialog.cancel(); dismissed = true; }
  assert.equal(dismissed, true); assert.equal(f.state.streamingState(peer.key).launching, false);
  f.start(); f.completeProbe('derp'); await f.advance(0); assert.equal(f.dialogs.length, 2);
});

for (const original of [false, true]) {
  test(`DERP choice original=${original} is single use and preserves its profile`, async () => {
    const f = fixture(); await f.ready('derp'); const dialog = f.dialogs[0];
    const button = original ? dialog.secondaryButton : dialog.primaryButton;
    button.action(); button.action(); assert.equal(f.availability.length, 1);
    f.availability[0].resolve(true); await f.flush(); assert.equal(f.launches.length, 1);
    assert.equal(f.launches[0].request.streamProfile.profileName, original ? 'default' : 'recommended');
    f.launches[0].resolve(); await f.flush();
  });
}

test('an old DERP button cannot authorize a later presentation', async () => {
  const f = fixture(); await f.ready('derp'); const old = f.dialogs[0]; f.closeAndReopen();
  old.primaryButton.action(); await f.flush(); assert.equal(f.availability.length, 0);
});

test('an obsolete availability failure cannot release or report over a newer owner', async () => {
  const f = fixture(); await f.ready(); f.closeAndReopen(); f.start(); f.completeProbe(); await f.advance(0);
  assert.equal(f.availability.length, 2); f.availability[0].reject(new Error('old failure')); await f.flush();
  assert.equal(f.state.streamingState(peer.key).launching, true); assert.equal(f.toasts.length, 0);
  f.availability[1].resolve(true); await f.flush(); assert.equal(f.launches.length, 1);
  f.launches[0].resolve(); await f.flush();
});

test('a missing companion app releases its spinner and exposes the current copy fallback', async () => {
  const f = fixture(); await f.ready(); f.availability[0].resolve(false); await f.flush();
  assert.equal(f.state.streamingState(peer.key).launching, false); assert.equal(f.dialogs.length, 1);
  f.dialogs[0].secondaryButton.action(); assert.equal(f.state.copied, peer.addresses[0]);
});

for (const offset of [-3600000, 3600000]) {
  test(`probe wait retains its five second budget after wall clock change ${offset}`, async () => {
    const f = fixture(); f.start(); f.wall(offset); await f.advance(4920);
    assert.equal(f.state.streamingState(peer.key).launching, true);
    await f.advance(120); assert.equal(f.state.streamingState(peer.key).launching, false);
    assert.equal(f.availability.length, 0);
  });
}

test('sleep past the probe deadline cannot consume a resumed successful result', async () => {
  const f = fixture(); f.start(); await f.advance(0); f.sleep(6000); f.completeProbe(); await f.advance(120);
  assert.equal(f.availability.length, 0); assert.equal(f.state.streamingState(peer.key).launching, false);
});

test('an unavailable clock does not leave the entry permanently busy', async () => {
  const f = fixture(); f.failClock(); f.start(); await f.advance(0);
  assert.equal(f.state.streamingState(peer.key).launching, false); assert.equal(f.availability.length, 0);
});

test('a clock failure during the probe releases the launch without opening a companion app', async () => {
  const f = fixture(); f.start(); await f.advance(0); f.failClock(); await f.advance(120);
  assert.equal(f.state.streamingState(peer.key).launching, false); assert.equal(f.availability.length, 0);
});

test('a synchronous availability failure releases the current owner and permits retry', async () => {
  const f = fixture(); const original = f.state.moonlightLauncher.isAvailable;
  f.state.moonlightLauncher.isAvailable = () => { throw new Error('bundle query unavailable'); };
  await f.ready(); await f.flush(); assert.equal(f.state.streamingState(peer.key).launching, false);
  assert.equal(f.toasts.length, 1); f.state.moonlightLauncher.isAvailable = original;
  await f.ready(); f.availability[0].resolve(true); await f.flush(); assert.equal(f.launches.length, 1);
  f.launches[0].resolve(); await f.flush();
});

test('a dialog presentation failure releases the launch instead of escaping the timer', async () => {
  const f = fixture(); f.state.getUIContext = () => ({ showAlertDialog() { throw new Error('detached context'); } });
  await f.ready('derp'); assert.equal(f.state.streamingState(peer.key).launching, false);
  assert.equal(f.availability.length, 0); assert.equal(f.toasts.length, 1);
});

test('repeated entry taps dispatch one probe and one availability query', async () => {
  const f = fixture(); f.start(); f.start(); assert.equal(f.state.streamingRequestIds.get(peer.key), 1);
  f.completeProbe(); await f.advance(0); assert.equal(f.availability.length, 1);
  f.availability[0].resolve(true); await f.flush(); assert.equal(f.launches.length, 1);
  f.launches[0].resolve(); await f.flush();
});

test('a stale card argument resolves the current host before dispatch', async () => {
  const f = fixture(false); f.state.peers[0] = { ...peer, name: 'Renamed', addresses: ['100.64.0.8'] };
  f.state.launchRemoteStream(peer); f.completeProbe(); await f.advance(0);
  f.availability[0].resolve(true); await f.flush(); assert.equal(f.launches[0].request.host, '100.64.0.8');
  assert.equal(f.launches[0].request.displayName, 'Renamed'); f.launches[0].resolve(); await f.flush();
});

test('an already dispatched launch is not repeated or allowed to clear a new owner after background', async () => {
  const f = fixture(); await f.ready(); f.availability[0].resolve(true); await f.flush();
  assert.equal(f.launches.length, 1); f.background(); f.state.remoteStreamAppInForeground = true;
  await f.ready(); assert.equal(f.availability.length, 2);
  f.launches[0].reject(new Error('old native failure')); await f.flush();
  assert.equal(f.state.streamingState(peer.key).launching, true); assert.equal(f.toasts.length, 0);
  f.availability[1].resolve(true); await f.flush(); assert.equal(f.launches.length, 2);
  f.launches[1].resolve(); await f.flush(); assert.equal(f.state.streamingState(peer.key).launching, false);
});
