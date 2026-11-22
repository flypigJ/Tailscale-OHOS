import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
import { loadEtsModules, readEtsSource } from './helpers/ets-vm-loader.mjs';

const peer = { key: 'p1', os: 'windows', online: true, addresses: ['100.64.0.1'] };
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };

function loadControllers(scope) {
  loadEtsModules([
    'services/AtomicFileStore', 'services/DiagnosticPrivacy', 'services/ControlServerConfig',
    'services/ControlServerPresets', 'services/AccountProfiles', 'services/DeviceNameService',
    'services/AuthKeyLogin', 'services/VpnAutoRecovery', 'services/HomeReadOnlyGateway',
    'services/NetworkSettingsGateway', 'services/SettingsPreferencesGateway',
    'services/AccountDiagnosticsGateway', 'services/FileTransferPreferences',
    'services/StreamingModels', 'services/StreamProfileBuilder', 'services/MediaIntegrationModels'
  ], scope);
  const gw = readEtsSource('services/VpnCommandGateway')
    .replace(/^import\s+['"][^'"]+['"]\s*;?[ \t]*\r?$/gm, '')
    .replace(/^import\s+(?:type\s+)?[\s\S]*?\bfrom\s+['"][^'"]+['"]\s*;?[ \t]*\r?$/gm, '')
    .replace(/^export\s+/gm, '');
  vm.runInContext(
    `${stripTypeScriptTypes(gw, { mode: 'transform' })}\nglobalThis.VpnCommandState = VpnCommandState; globalThis.VpnCoreCommand = VpnCoreCommand; globalThis.VpnCommandStateMachine = VpnCommandStateMachine; globalThis.VpnCommandGateway = VpnCommandGateway;`,
    scope
  );
  loadEtsModules(['services/VpnSessionController', 'services/PeerIntegrationController'], scope);
  vm.runInContext(
    'const _origIsPeerSunshineCandidate = isPeerSunshineCandidate; isPeerSunshineCandidate = p => globalThis.__overrideSunshine ? globalThis.__overrideSunshine(p) : _origIsPeerSunshineCandidate(p);',
    scope
  );
}

function fixture() {
  let now = 1000;
  const sandbox = {
    Date: { now: () => now }, setTimeout, clearTimeout,
    systemDateTime: { TimeType: { STARTUP: 0 }, getUptime: () => now },
    fileIo: {}, nativeBridge: {}, vpnExtension: {}, connection: {},
    SunshineProbeService: class {}, PeerPathService: class {}, MoonlightLauncher: class {},
    MediaServiceProbeService: class {}, HosPlayerLauncher: class {}
  };
  loadControllers(sandbox);
  const calls = [];
  const probe = kind => ({
    probe(...args) {
      let resolve, reject;
      const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
      calls.push({ kind, args, resolve, reject }); return promise;
    }, cancel() {}, clearCache() {}
  });
  const state = {
    peers: [peer], connected: true, streamingStates: [], mediaStates: [],
    selectedPeerKey: '', deviceDetailVisible: false, appShellReady: true, lifecycleGeneration: 1,
    deviceDetailServiceRefreshInFlight: false, diagnostics: []
  };
  Object.defineProperty(state, 'isSunshineCandidate', {
    get: () => sandbox.__overrideSunshine ?? (p => sandbox.isPeerSunshineCandidate(p)),
    set: fn => { sandbox.__overrideSunshine = fn; }
  });
  let peerCtrl;
  const vpnCtrl = new sandbox.VpnSessionController({
    getFilesDir: () => '/files', getCacheDir: () => '/cache', getLifecycleGeneration: () => state.lifecycleGeneration,
    isAppShellReady: () => state.appShellReady, isAppLockRequired: () => false, isLogoutInProgress: () => false,
    isDiagnosticActionInProgress: () => false, isCacheClearInProgress: () => false, isTaildropSendActive: () => false,
    isTaildropReceiveInProgress: () => false, isTaildropMediaSaveInProgress: () => false, shouldPollHealthFast: () => false,
    getBackendStatus: () => 'OK | state=Running', setBackendStatus() {},
    getVpnStatus: () => state.connected ? 'OK | state=Running' : 'Stopped', setVpnStatus() {},
    isBackendReady: () => true, setBackendReady() {}, isBackendInitializationVisible: () => false, setBackendInitializationVisible() {},
    setDevicesLoading() {}, hasAuthenticatedSession: () => false, setHasAuthenticatedSession() {},
    isConnectInProgress: () => false, setConnectInProgressState() {}, isDisconnectInProgress: () => false, setDisconnectInProgress() {},
    isLoginInProgress: () => false, setLoginInProgress() {}, getLoginHandoffStatus: () => '', setLoginHandoffStatus() {},
    setLoginPromptKind() {}, isAuthKeyLoginVisible: () => false, setAuthKeyLoginVisible() {}, getAuthKeyInput: () => '',
    setAuthKeyInput() {}, getAuthKeyStatus: () => '', setAuthKeyStatus() {}, isControlServerConfirmed: () => true,
    setControlServerConfirmed() {}, getControlServerURL: () => 'https://controlplane.tailscale.com', setControlServerURL() {},
    setControlServerInput() {}, setControlServerStatus() {}, setControlServerEditorVisible() {}, setControlServerPresets() {},
    isControlServerSwitching: () => false, setControlServerSwitching() {}, getAccountProfileId: () => 'default',
    setAccountProfileId() {}, getAccountProfiles: () => [], setAccountProfiles() {}, setAccountProfileStatus() {},
    getPeers: () => state.peers,
    onPeersUpdated: merged => { state.peers = merged; peerCtrl.pruneOfflineServiceStates(merged); },
    onPeerPresenceInvalidated: key => peerCtrl.invalidatePeerPresence(key),
    setMeshArcReceiver() {}, setAccountSummary() {}, setAvatarLoadFailed() {}, getExitNodes: () => [], setExitNodes() {},
    isExitNodeUpdateInProgress: () => false, setExitNodeUpdateInProgress() {}, isExitNodeStatusFailed: () => false,
    setExitNodeNoneStatus() {}, setExitNodeSelectedStatus() {}, setExitNodeUnavailableStatus() {}, setExitNodeRawStatus() {},
    getNetworkSettings: () => ({ routeAll: true, exitNodeAllowLANAccess: false }), setNetworkSettings() {}, setNetworkSettingStatus() {},
    isRouteAllUpdateInProgress: () => false, setRouteAllUpdateInProgress() {}, isExitNodeLanUpdateInProgress: () => false,
    setExitNodeLanUpdateInProgress() {}, setTrafficDownloadBytes() {}, setTrafficUploadBytes() {}, setTrafficDownloadRate() {},
    setTrafficUploadRate() {}, getTrafficSamples: () => [], setTrafficSamples() {}, isVpnConflictDialogVisible: () => false,
    setVpnConflictDialogVisible() {}, showVpnConflictAlertDialog() {}, syncHomeTitleCompact() {}, setHomeTitleCompact() {},
    deviceModel: () => 'test', harmonyOSHostinfoVersion: () => '6.0', openControlServerSettings() {},
    openSecureLoginBrowser: async () => {}, confirmControlServerSelection: () => undefined, invalidateAccountGuard() {},
    clearControlServerShellState() {}, reloadTaildropStorageForActiveIdentity() {}, resetTaildropSnapshot() {},
    applyBackendTaildropSnapshot() {}, onLiveExtensionTick() {}, resetStreamingStatesForDisconnect() {},
    autoProbeConnectedPeerServices() {}, syncOfflinePeerStatusRefreshPolling() {}, syncWindowPrivacyMode() {},
    logServiceStatusIfChanged() {}, scheduleLifecycleTask: () => -1, recordDiagnosticEvent: (...args) => state.diagnostics.push(args)
  });
  vpnCtrl.mergePeers = peers => peers;

  peerCtrl = new sandbox.PeerIntegrationController({
    getFilesDir: () => '/files', getAbilityContext: () => ({ filesDir: '/files' }),
    getLifecycleGeneration: () => state.lifecycleGeneration, getNavigationRevision: () => 0, getTrafficSession: () => 1,
    isAppShellReady: () => state.appShellReady, isRemoteStreamAppInForeground: () => true, setRemoteStreamAppInForeground() {},
    isAppLockRequired: () => false, isAppLockAuthenticating: () => false, isConnected: () => state.connected,
    getPeers: () => state.peers, peerEffectivelyOnline: p => p.online, getSelectedPeerKey: () => state.selectedPeerKey,
    isDeviceDetailVisible: () => state.deviceDetailVisible, setDeviceDetailVisible: v => { state.deviceDetailVisible = v; },
    getDeviceDetailPresentationId: () => 0, isDeviceDetailServiceRefreshInFlight: () => state.deviceDetailServiceRefreshInFlight,
    setDeviceDetailServiceRefreshInFlight: v => { state.deviceDetailServiceRefreshInFlight = v; },
    isTransferProtocolRefreshing: () => false, setTransferProtocolRefreshing() {},
    getStreamingStates: () => state.streamingStates, setStreamingStates: s => { state.streamingStates = s; },
    getMediaStates: () => state.mediaStates, setMediaStates: s => { state.mediaStates = s; },
    isFakeMediaServiceOnline: () => false, getFakeJellyfinName: () => 'Jellyfin',
    isMediaSelfTestInProgress: () => false, setMediaSelfTestInProgress() {}, setMediaSelfTestStatusKind() {},
    getLocalSendPortOverrides: () => [], setLocalSendPortOverrides() {},
    getRemotePortPeerKey: () => '', getRemotePortInput: () => '', setRemotePortEditorVisible() {},
    setTaildropFocusedTargetKey() {}, getTaildropFocusedTargetKey: () => '',
    refreshBackendStatus: async () => {}, refreshPeerSnapshot() {}, refreshTaildropSnapshot() {},
    logServiceStatusIfChanged() {}, scheduleLifecycleTask: () => -1, showPeerIntegrationToast() {},
    showDerpStreamConfirmationDialog() {}, showMoonlightRequiredDialog() {}, copyHosPlayerPrototypeText() {},
    recordDiagnosticEvent: (...args) => state.diagnostics.push(args), recordFeatureDiagnosticEvent() {}
  }, {
    sunshineProbeService: probe('sunshine'),
    mediaServiceProbeService: probe('media'),
    peerPathService: probe('path'),
    moonlightLauncher: {},
    hosPlayerLauncher: {}
  });

  state.refreshPeerServices = (...args) => peerCtrl.refreshPeerServices(...args);
  state.detectMediaForPeer = (...args) => peerCtrl.detectMediaForPeer(...args);
  state.detectStreamingForPeer = (...args) => peerCtrl.detectStreamingForPeer(...args);
  state.resetStreamingStatesForDisconnect = () => peerCtrl.resetStreamingStatesForDisconnect();
  state.applyPeers = list => vpnCtrl.applyPeers(list);
  state.streamingState = k => peerCtrl.streamingState(k);
  state.mediaState = k => peerCtrl.mediaState(k);
  state.copyStreamingState = (...args) => peerCtrl.copyStreamingState(...args);
  state.updateStreamingState = (...args) => peerCtrl.updateStreamingState(...args);
  state.updateMediaState = (...args) => peerCtrl.updateMediaState(...args);
  for (const key of [
    'streamingRequestIds', 'mediaRequestIds', 'peerServiceRefreshInFlight',
    'peerServiceRefreshOwners', 'autoSunshineFailureCounts', 'autoMediaFailureCounts', 'autoProbedPeerSessions'
  ]) {
    Object.defineProperty(state, key, { get: () => peerCtrl[key] });
  }
  const settle = async (batch, tag = 'result', failure = '') => {
    for (const call of batch) {
      if (call.kind === failure) { call.reject(new Error('probe failed')); continue; }
      call.resolve(call.kind === 'sunshine' ? { state: 'available', checkedAt: now, marker: tag } :
        call.kind === 'media' ? { state: 'available', checkedAt: now, services: [{ type: tag }] } :
          { type: 'direct', checkedAt: now, marker: tag });
    }
    await flush();
  };
  return { state, calls, settle, clock(value) { now = value; }, restart() {
    state.connected = false; state.resetStreamingStatesForDisconnect(); state.connected = true;
  } };
}

test('same-peer group refresh remains single flight and releases its own completed work', async () => {
  const f = fixture(); f.state.refreshPeerServices(peer); f.state.refreshPeerServices(peer);
  assert.equal(f.calls.length, 3); await f.settle(f.calls);
  assert.equal(f.state.peerServiceRefreshInFlight.has(peer.key), false);
  assert.equal(f.state.streamingState(peer.key).checking, false);
  assert.equal(f.state.mediaState(peer.key).checking, false);
});

for (const failure of ['', 'media']) test(`old ${failure ? 'rejection' : 'completion'} cannot release or overwrite a reconnected group`, async () => {
  const f = fixture(); f.state.refreshPeerServices(peer); const old = f.calls.slice();
  f.restart(); f.state.refreshPeerServices(peer); const current = f.calls.slice(3);
  await f.settle(old, 'old', failure);
  assert.equal(f.state.peerServiceRefreshInFlight.has(peer.key), true);
  assert.equal(f.state.streamingState(peer.key).checking, true);
  assert.equal(f.state.mediaState(peer.key).checking, true);
  await f.settle(current, 'current');
  assert.equal(f.state.streamingState(peer.key).sunshine.marker, 'current');
  assert.equal(f.state.mediaState(peer.key).result.services[0].type, 'current');
});

test('late old results cannot overwrite a newer completed refresh at an identical clock time', async () => {
  const f = fixture(); f.state.refreshPeerServices(peer); const old = f.calls.slice();
  f.restart(); f.state.refreshPeerServices(peer); const current = f.calls.slice(3);
  await f.settle(current, 'current'); await f.settle(old, 'old');
  assert.equal(f.state.streamingState(peer.key).sunshine.marker, 'current');
  assert.equal(f.state.mediaState(peer.key).result.services[0].type, 'current');
});

test('all three probe entry points issue unique positive tickets across equal and backward clocks', async () => {
  const f = fixture(), ids = [];
  for (const time of [1000, 1000, 900, -5]) {
    f.clock(time); f.restart(); f.state.refreshPeerServices(peer); ids.push(f.state.streamingRequestIds.get(peer.key));
    assert.equal(f.state.mediaState(peer.key).result.checkedAt, time, 'timestamps remain actual wall time');
    f.state.detectMediaForPeer(peer, true); ids.push(f.state.mediaRequestIds.get(peer.key));
    f.state.detectStreamingForPeer(peer, true); ids.push(f.state.streamingRequestIds.get(peer.key));
  }
  assert.ok(ids.every((id, index) => id > 0 && (index === 0 || id > ids[index - 1])));
  await f.settle(f.calls);
});

test('an independent stream probe keeps its state while group media still completes and releases the mutex', async () => {
  const f = fixture(); f.state.refreshPeerServices(peer); const group = f.calls.slice();
  f.state.detectStreamingForPeer(peer, true); const stream = f.calls.slice(3);
  await f.settle(group, 'group');
  assert.equal(f.state.peerServiceRefreshInFlight.has(peer.key), false);
  assert.equal(f.state.streamingState(peer.key).checking, true);
  assert.equal(f.state.mediaState(peer.key).checking, false);
  assert.equal(f.state.mediaState(peer.key).result.services[0].type, 'group');
  await f.settle(stream, 'stream'); assert.equal(f.state.streamingState(peer.key).sunshine.marker, 'stream');
});

test('an independent media probe keeps its state while group streaming still completes', async () => {
  const f = fixture(); f.state.refreshPeerServices(peer); const group = f.calls.slice();
  f.state.detectMediaForPeer(peer, true); const media = f.calls.slice(3);
  await f.settle(group, 'group');
  assert.equal(f.state.peerServiceRefreshInFlight.has(peer.key), false);
  assert.equal(f.state.streamingState(peer.key).checking, false);
  assert.equal(f.state.streamingState(peer.key).sunshine.marker, 'group');
  assert.equal(f.state.mediaState(peer.key).checking, true);
  await f.settle(media, 'media'); assert.equal(f.state.mediaState(peer.key).result.services[0].type, 'media');
});

test('a group rejection clears only channels it still owns', async () => {
  const f = fixture(); f.state.refreshPeerServices(peer); const group = f.calls.slice();
  f.state.detectStreamingForPeer(peer, true); const stream = f.calls.slice(3);
  await f.settle(group, 'failed', 'media');
  assert.equal(f.state.streamingState(peer.key).checking, true);
  assert.equal(f.state.mediaState(peer.key).result.state, 'error');
  assert.equal(f.state.peerServiceRefreshInFlight.has(peer.key), false);
  await f.settle(stream, 'stream');
});

test('peer offline/online retires a pending group so discovery can restart immediately', async () => {
  const f = fixture(); f.state.refreshPeerServices(peer); const old = f.calls.slice();
  f.state.applyPeers([{ ...peer, online: false }]);
  assert.equal(f.state.peerServiceRefreshInFlight.has(peer.key), false);
  f.state.applyPeers([peer]); f.state.refreshPeerServices(peer); const current = f.calls.slice(3);
  assert.equal(current.length, 3); await f.settle(old, 'old');
  assert.equal(f.state.peerServiceRefreshInFlight.has(peer.key), true);
  await f.settle(current, 'current');
});

test('removing and readding a peer cannot inherit its old pending group', async () => {
  const f = fixture(); f.state.refreshPeerServices(peer); const old = f.calls.slice();
  f.state.applyPeers([]); f.state.applyPeers([peer]); f.state.refreshPeerServices(peer);
  assert.equal(f.calls.length, 6); await f.settle(old, 'old');
  assert.equal(f.state.peerServiceRefreshInFlight.has(peer.key), true);
  await f.settle(f.calls.slice(3), 'current');
});

test('automatic discovery retains available services twice and accepts the third failed result', async () => {
  const f = fixture(); f.state.refreshPeerServices(peer); await f.settle(f.calls, 'warm');
  for (let count = 1; count <= 3; count++) {
    const start = f.calls.length; f.state.refreshPeerServices(peer, false);
    for (const call of f.calls.slice(start)) call.resolve(call.kind === 'sunshine' ?
      { state: 'unavailable', checkedAt: 2000 + count } : call.kind === 'media' ?
        { state: 'unavailable', checkedAt: 2000 + count, services: [] } : { type: 'direct', checkedAt: 2000 + count });
    await flush();
    assert.equal(f.state.streamingState(peer.key).sunshine.state, count < 3 ? 'available' : 'unavailable');
    assert.equal(f.state.mediaState(peer.key).result.services.length, count < 3 ? 1 : 0);
    assert.equal(f.state.autoSunshineFailureCounts.get(peer.key), count);
    assert.equal(f.state.autoMediaFailureCounts.get(peer.key), count);
  }
});

test('superseded automatic channel results cannot change its failure history', async () => {
  const f = fixture(); f.state.refreshPeerServices(peer); await f.settle(f.calls, 'warm');
  f.state.autoSunshineFailureCounts.set(peer.key, 1);
  f.state.autoMediaFailureCounts.set(peer.key, 1);
  const start = f.calls.length; f.state.refreshPeerServices(peer, false); const group = f.calls.slice(start);
  f.state.detectStreamingForPeer(peer, true); const streaming = f.calls.slice(start + 3);
  await f.settle(group, 'group');
  assert.equal(f.state.autoSunshineFailureCounts.get(peer.key), 1);
  assert.equal(f.state.autoMediaFailureCounts.has(peer.key), false);
  await f.settle(streaming, 'current');
});

test('manual discovery accepts the first negative result and clears automatic failure counts', async () => {
  const f = fixture(); f.state.autoSunshineFailureCounts.set(peer.key, 2); f.state.autoMediaFailureCounts.set(peer.key, 2);
  f.state.refreshPeerServices(peer);
  for (const call of f.calls) call.resolve(call.kind === 'sunshine' ?
    { state: 'unavailable', checkedAt: 1000 } : call.kind === 'media' ?
      { state: 'unavailable', checkedAt: 1000, services: [] } : { type: 'direct', checkedAt: 1000 });
  await flush();
  assert.equal(f.state.streamingState(peer.key).sunshine.state, 'unavailable');
  assert.equal(f.state.mediaState(peer.key).result.services.length, 0);
  assert.equal(f.state.autoSunshineFailureCounts.has(peer.key), false);
  assert.equal(f.state.autoMediaFailureCounts.has(peer.key), false);
});

test('non-Sunshine devices retain their prior result without starting a Sunshine probe', async () => {
  const f = fixture(); f.state.isSunshineCandidate = () => false;
  f.state.refreshPeerServices(peer); assert.deepEqual(f.calls.map(call => call.kind), ['media', 'path']);
  await f.settle(f.calls); assert.equal(f.state.streamingState(peer.key).sunshine.state, 'unknown');
});

test('different peers retain independent owners and in-flight markers', async () => {
  const f = fixture(), other = { ...peer, key: 'p2' }; f.state.peers = [peer, other];
  f.state.refreshPeerServices(peer); f.state.refreshPeerServices(other);
  await f.settle(f.calls.slice(0, 3), 'one');
  assert.equal(f.state.peerServiceRefreshInFlight.has(peer.key), false);
  assert.equal(f.state.peerServiceRefreshInFlight.has(other.key), true);
  await f.settle(f.calls.slice(3), 'two');
  assert.equal(f.state.mediaState(peer.key).result.services[0].type, 'one');
  assert.equal(f.state.mediaState(other.key).result.services[0].type, 'two');
});

test('a disconnected latest result is ignored and its own mutex is still released', async () => {
  const f = fixture(); f.state.refreshPeerServices(peer); f.state.connected = false;
  await f.settle(f.calls, 'late');
  assert.equal(f.state.streamingState(peer.key).sunshine.marker, undefined);
  assert.equal(f.state.mediaState(peer.key).result.services.length, 0);
  assert.equal(f.state.peerServiceRefreshInFlight.has(peer.key), false);
  assert.equal(f.state.streamingState(peer.key).checking, false);
  assert.equal(f.state.mediaState(peer.key).checking, false);
});

test('launch reuses a fresh visible Sunshine success while still checking the connection path', async () => {
  const f = fixture();
  f.state.refreshPeerServices(peer); await f.settle(f.calls, 'verified');
  const checkedAt = f.state.streamingState(peer.key).sunshine.checkedAt;
  const start = f.calls.length;
  f.clock(2000); f.state.detectStreamingForPeer(peer, false);
  const launch = f.calls.slice(start);
  assert.deepEqual(launch.map(call => call.kind), ['path']);
  assert.equal(launch[0].args[2], false);
  await f.settle(launch);
  assert.equal(f.state.streamingState(peer.key).sunshine.marker, 'verified');
  assert.equal(f.state.streamingState(peer.key).sunshine.checkedAt, checkedAt,
    'reuse must not extend the lifetime of old success');
  assert.equal(f.state.streamingState(peer.key).checking, false);
});

for (const [label, now, force] of [['expired', 61000, false], ['clock rollback', 999, false],
  ['explicit refresh', 2000, true]]) {
  test(`${label} Sunshine success requires a new probe and accepts failure`, async () => {
    const f = fixture(); f.state.refreshPeerServices(peer); await f.settle(f.calls, 'old');
    const start = f.calls.length; f.clock(now); f.state.detectStreamingForPeer(peer, force);
    const launch = f.calls.slice(start);
    assert.deepEqual(launch.map(call => call.kind), ['sunshine', 'path']);
    launch[0].resolve({ state: 'unavailable', checkedAt: now, errorMessage: 'serverinfo_unreachable' });
    launch[1].resolve({ type: 'direct', checkedAt: now }); await flush();
    assert.equal(f.state.streamingState(peer.key).sunshine.state, 'unavailable');
    assert.equal(f.state.streamingState(peer.key).checking, false);
  });
}
