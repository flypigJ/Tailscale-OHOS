import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
import { loadEtsModules, readEtsSource } from './helpers/ets-vm-loader.mjs';

const source = readFileSync(new URL('../entry/src/main/ets/components/BridgeStatus.ets', import.meta.url), 'utf8')
  .replace(/\r\n/g, '\n');

function method(name) {
  const match = new RegExp('^  private (?:async )?' + name + '\\(', 'm').exec(source);
  assert.ok(match, 'missing method ' + name);
  const end = source.indexOf('\n  }', match.index);
  assert.ok(end >= 0, 'missing closing brace for ' + name);
  return source.slice(match.index, end + 4);
}

const methods = [
  'handleAppForeground',
  'handleAppBackground',
  'handleRemoteStreamAppBackground',
  'invalidateRemoteStreamLaunch',
  'startServiceRefreshPolling',
  'stopServiceRefreshPolling',
  'syncOfflinePeerStatusRefreshPolling',
  'startOfflinePeerStatusRefreshPolling',
  'stopOfflinePeerStatusRefreshPolling',
  'refreshServiceSnapshots',
  'syncHomeLatencyRefreshPolling',
  'startHomeLatencyRefreshPolling',
  'stopHomeLatencyRefreshPolling',
  'syncTransferProtocolRefreshPolling',
  'startTransferProtocolRefreshPolling',
  'stopTransferProtocolRefreshPolling',
  'startConnectionDurationPolling',
  'stopConnectionDurationPolling',
  'startCacheSizePolling',
  'stopCacheSizePolling',
  'startDeviceDetailRefreshPolling',
  'stopDeviceDetailRefreshPolling',
  'autoProbeConnectedPeerServices',
  'scheduleLifecycleTask',
  'clearLifecycleTimers'
];

const js = stripTypeScriptTypes('class Controller {\n' + methods.map(method).join('\n') + '\n}\nglobalThis.Controller = Controller;');

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
  const intervals = new Map();
  const timeouts = new Map();
  let nextTimer = 1;
  let localSendResolve;
  const f = {
    intervals,
    timeouts,
    probedPeers: [],
    localSendCalls: 0,
    homeLatencyCalls: 0,
    transferCalls: 0,
    detailCalls: 0,
    cacheCalls: 0,
    healthPolls: 0,
    healthStops: 0,
    animationFlushes: 0,
    events: []
  };
  const sandbox = {
    Date,
    systemDateTime: { getUptime: () => Date.now() },
    fileIo: {},
    nativeBridge: {},
    vpnExtension: {},
    connection: {},
    SunshineProbeService: class {},
    PeerPathService: class {},
    MoonlightLauncher: class {},
    MediaServiceProbeService: class {},
    HosPlayerLauncher: class {},
    NORMAL_SERVICE_REFRESH_INTERVAL_MS: 30000,
    OFFLINE_PEER_STATUS_REFRESH_INTERVAL_MS: 10000,
    FAST_REFRESH_INTERVAL_MS: 4000,
    CACHE_SIZE_POLL_INTERVAL_MS: 5000,
    setInterval(cb, delay) {
      const id = nextTimer++;
      intervals.set(id, { cb, delay });
      return id;
    },
    clearInterval(id) {
      intervals.delete(id);
    },
    setTimeout(cb, delay) {
      const id = nextTimer++;
      timeouts.set(id, { cb, delay });
      return id;
    },
    clearTimeout(id) {
      timeouts.delete(id);
    }
  };
  loadPeerIntegrationController(sandbox);
  vm.runInContext(js, sandbox);
  const c = new sandbox.Controller();
  Object.assign(c, {
    appShellReady: true,
    remoteStreamAppInForeground: true,
    lifecycleGeneration: 1,
    lifecycleTimers: [],
    connectInProgress: false,
    disconnectInProgress: false,
    taildropReceiveInProgress: false,
    healthPollTimer: 99,
    controlServerConfirmed: true,
    activeNavigationId: 'home',
    connectionDetailsVisible: true,
    deviceDetailVisible: true,
    connectionButtonPressed: false,
    trafficSession: 10,
    serviceRefreshTimer: -1,
    serviceRefreshInFlight: false,
    offlinePeerStatusRefreshTimer: -1,
    homeLatencyRefreshTimer: -1,
    transferProtocolRefreshTimer: -1,
    connectionDurationTimer: -1,
    cacheSizePollTimer: -1,
    deviceDetailRefreshTimer: -1,
    deviceDetailPresentationId: 1,
    peers: [
      { key: 'peer-1', online: true, addresses: ['100.64.0.1'] },
      { key: 'peer-2', online: false, addresses: ['100.64.0.2'] }
    ],
    storageScanPool: { cancel() {} },
    isConnected: () => true,
    offlinePeers: () => c.peers.filter(p => !p.online),
    requireAppAuthentication() {},
    refreshVpnProbeStatus: () => true,
    maybeExpireTaildropCache() {},
    startHealthPolling: () => { f.healthPolls++; c.healthPollTimer = 99; },
    stopHealthPolling: () => { f.healthStops++; c.healthPollTimer = -1; },
    refreshOrRecoverBackend() {},
    refreshPeerSnapshot() {},
    refreshTaildropSnapshot() {},
    requestLocalSendRefresh: () => {
      f.localSendCalls++;
      return new Promise(resolve => { localSendResolve = resolve; });
    },
    logServiceStatusIfChanged() {},
    refreshHomeLatency: () => { f.homeLatencyCalls++; },
    refreshTransferProtocolStatus: () => { f.transferCalls++; },
    refreshSelectedPeerDetails: () => { f.detailCalls++; },
    refreshCacheSize: () => { f.cacheCalls++; },
    invalidateDeviceDetailServiceRefresh() {},
    flushPersonalizationPreferences() {},
    flushNavigationMarginPreferences() {},
    flushAnimationPreferences: () => { f.animationFlushes++; },
    recordDiagnosticEvent: (...args) => f.events.push(args)
  });

  const peerHost = {
    getFilesDir: () => '/files',
    getAbilityContext: () => ({ filesDir: '/files' }),
    getLifecycleGeneration: () => c.lifecycleGeneration,
    getNavigationRevision: () => 0,
    getTrafficSession: () => c.trafficSession,
    isAppShellReady: () => c.appShellReady,
    isRemoteStreamAppInForeground: () => c.remoteStreamAppInForeground,
    setRemoteStreamAppInForeground: v => { c.remoteStreamAppInForeground = v; },
    isAppLockRequired: () => false,
    isAppLockAuthenticating: () => false,
    isConnected: () => c.isConnected(),
    getPeers: () => c.peers,
    peerEffectivelyOnline: p => p.online,
    getSelectedPeerKey: () => '',
    isDeviceDetailVisible: () => c.deviceDetailVisible,
    setDeviceDetailVisible: v => { c.deviceDetailVisible = v; },
    getDeviceDetailPresentationId: () => c.deviceDetailPresentationId,
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
    refreshBackendStatus: async () => {},
    refreshPeerSnapshot: () => c.refreshPeerSnapshot(),
    refreshTaildropSnapshot: () => c.refreshTaildropSnapshot(),
    logServiceStatusIfChanged: () => c.logServiceStatusIfChanged(),
    scheduleLifecycleTask: (task, delay) => c.scheduleLifecycleTask(task, delay),
    showPeerIntegrationToast() {},
    showDerpStreamConfirmationDialog() {},
    showMoonlightRequiredDialog() {},
    copyHosPlayerPrototypeText() {},
    recordDiagnosticEvent: (...args) => f.events.push(args),
    recordFeatureDiagnosticEvent() {}
  };
  c.peerIntegrationController = new sandbox.PeerIntegrationController(peerHost);
  c.peerIntegrationController.refreshPeerServices = (peer, manual) => {
    f.probedPeers.push({ key: peer.key, manual });
  };

  return {
    c,
    f,
    resolveLocalSend: async () => {
      if (localSendResolve) {
        const done = localSendResolve;
        localSendResolve = undefined;
        done();
      }
      await new Promise(setImmediate);
    }
  };
}

test('handleAppBackground stops all UI and service probing timers and suppresses background auto-probing', async () => {
  const { c, f, resolveLocalSend } = fixture();
  c.startServiceRefreshPolling();
  c.syncOfflinePeerStatusRefreshPolling();
  c.syncHomeLatencyRefreshPolling();
  c.startConnectionDurationPolling();
  c.startDeviceDetailRefreshPolling();
  c.activeNavigationId = 'transfer';
  c.syncTransferProtocolRefreshPolling();
  c.activeNavigationId = 'settings';
  c.startCacheSizePolling();
  assert.equal(f.intervals.size, 7);

  c.handleAppBackground();
  assert.equal(c.remoteStreamAppInForeground, false);
  assert.equal(c.serviceRefreshTimer, -1);
  assert.equal(c.offlinePeerStatusRefreshTimer, -1);
  assert.equal(c.homeLatencyRefreshTimer, -1);
  assert.equal(c.transferProtocolRefreshTimer, -1);
  assert.equal(c.connectionDurationTimer, -1);
  assert.equal(c.cacheSizePollTimer, -1);
  assert.equal(c.deviceDetailRefreshTimer, -1);
  assert.equal(c.healthPollTimer, -1);
  assert.equal(f.healthStops, 1);
  assert.equal(f.animationFlushes, 1);
  assert.equal(f.intervals.size, 0);

  // Even an in-flight LocalSend completion or an explicit autoProbe call while backgrounded
  // must not trigger peer service probes.
  await resolveLocalSend();
  c.autoProbeConnectedPeerServices(true);
  assert.equal(f.probedPeers.length, 0);

  // Starting any polling helper while backgrounded must remain a no-op.
  c.startServiceRefreshPolling();
  c.syncOfflinePeerStatusRefreshPolling();
  c.syncHomeLatencyRefreshPolling();
  assert.equal(f.intervals.size, 0);
});

test('handleAppForeground restores active polling timers and resumes service probes', async () => {
  const { c, f, resolveLocalSend } = fixture();
  c.handleAppBackground();
  assert.equal(f.intervals.size, 0);
  assert.equal(c.healthPollTimer, -1);

  c.activeNavigationId = 'transfer';
  c.handleAppForeground();
  assert.equal(c.remoteStreamAppInForeground, true);
  assert.ok(c.serviceRefreshTimer >= 0);
  assert.ok(c.offlinePeerStatusRefreshTimer >= 0);
  assert.ok(c.transferProtocolRefreshTimer >= 0);
  assert.ok(c.connectionDurationTimer >= 0);
  assert.ok(c.deviceDetailRefreshTimer >= 0);
  assert.equal(c.homeLatencyRefreshTimer, -1);
  assert.equal(f.healthPolls, 1);
  assert.equal(c.healthPollTimer, 99);

  await resolveLocalSend();
  assert.equal(f.probedPeers.length, 1);
  assert.equal(f.probedPeers[0].key, 'peer-1');
  assert.equal(f.probedPeers[0].manual, false);
});

test('handleAppBackground preserves healthPolling during active connect/disconnect/receive transitions', () => {
  for (const activeFlag of ['connectInProgress', 'disconnectInProgress', 'taildropReceiveInProgress']) {
    const { c, f } = fixture();
    c[activeFlag] = true;
    c.handleAppBackground();
    assert.equal(f.healthStops, 0, `${activeFlag} keeps healthPolling active`);
    assert.equal(c.healthPollTimer, 99);
    assert.equal(f.animationFlushes, 1);
  }
});

test('scheduleLifecycleTask self-removes fired timer IDs from lifecycleTimers without leaking', () => {
  const { c, f } = fixture();
  const executed = [];
  const t1 = c.scheduleLifecycleTask(() => executed.push('first'), 100);
  const t2 = c.scheduleLifecycleTask(() => executed.push('second'), 200);
  assert.deepEqual(Array.from(c.lifecycleTimers), [t1, t2]);

  const entry1 = f.timeouts.get(t1);
  f.timeouts.delete(t1);
  entry1.cb();
  assert.deepEqual(executed, ['first']);
  assert.deepEqual(Array.from(c.lifecycleTimers), [t2], 't1 removed immediately upon firing');

  // Bump generation before t2 fires: t2 still self-removes without executing stale task.
  c.lifecycleGeneration++;
  const entry2 = f.timeouts.get(t2);
  f.timeouts.delete(t2);
  entry2.cb();
  assert.deepEqual(executed, ['first']);
  assert.deepEqual(Array.from(c.lifecycleTimers), [], 'stale t2 also self-removes on fire');
});
