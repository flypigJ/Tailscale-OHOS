import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';
import { loadEtsModules, readEtsSource } from './helpers/ets-vm-loader.mjs';

const bridgeSource = readFileSync(new URL('../entry/src/main/ets/components/BridgeStatus.ets', import.meta.url), 'utf8')
  .replace(/\r\n/g, '\n');

function bridgeMethod(name) {
  const start = bridgeSource.indexOf(`  private ${name}(`);
  assert.ok(start >= 0, name);
  const end = bridgeSource.indexOf('\n  }', start) + 4;
  return bridgeSource.slice(start, end);
}

function loadControllers(scope) {
  loadEtsModules([
    'services/AtomicFileStore',
    'services/DiagnosticPrivacy',
    'services/ControlServerConfig',
    'services/ControlServerPresets',
    'services/AccountProfiles',
    'services/DeviceNameService',
    'services/AuthKeyLogin',
    'services/VpnAutoRecovery',
    'services/HomeReadOnlyGateway',
    'services/NetworkSettingsGateway',
    'services/SettingsPreferencesGateway',
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
  const shellJs = stripTypeScriptTypes(`class ShellMethods {\n${bridgeMethod('peerEffectivelyOnline')}\n${bridgeMethod('peerCardStatus')}\n}`);
  vm.runInContext(
    `${gwJs}\n${shellJs}\nglobalThis.VpnCommandState = VpnCommandState; globalThis.VpnCoreCommand = VpnCoreCommand; globalThis.VpnCommandStateMachine = VpnCommandStateMachine; globalThis.VpnCommandGateway = VpnCommandGateway; globalThis.ShellMethods = ShellMethods;`,
    scope
  );
  loadEtsModules(['services/VpnSessionController', 'services/PeerIntegrationController'], scope);
}

const peer = (online = true) => ({ key: 'peer-test', online, addresses: ['100.64.0.1'] });

function fixture() {
  const clock = { now: 10000 };
  const invalidations = [];
  const probe = () => ({
    cancel: key => invalidations.push(`cancel:${key}`),
    clearCache: key => invalidations.push(`cache:${key}`)
  });
  const sandbox = {
    $r: name => name,
    Date: { now: () => clock.now },
    setTimeout,
    clearTimeout,
    systemDateTime: { getUptime: () => clock.now },
    fileIo: {},
    nativeBridge: {},
    vpnExtension: {},
    connection: {},
    SunshineProbeService: class {},
    PeerPathService: class {},
    MoonlightLauncher: class {},
    MediaServiceProbeService: class {},
    HosPlayerLauncher: class {}
  };
  loadControllers(sandbox);

  const state = {
    peers: [peer()],
    streamingStates: [],
    mediaStates: [],
    selectedPeerKey: '',
    hasAuthenticatedSession: true,
    appShellReady: true,
    lifecycleGeneration: 1,
    trafficSession: 1,
    remoteStreamAppInForeground: true
  };

  let peerCtrl;
  const vpnHost = {
    getFilesDir: () => '/files',
    getCacheDir: () => '/cache',
    getLifecycleGeneration: () => state.lifecycleGeneration,
    isAppShellReady: () => state.appShellReady,
    isAppLockRequired: () => false,
    isLogoutInProgress: () => false,
    isDiagnosticActionInProgress: () => false,
    isCacheClearInProgress: () => false,
    isTaildropSendActive: () => false,
    isTaildropReceiveInProgress: () => false,
    isTaildropMediaSaveInProgress: () => false,
    shouldPollHealthFast: () => false,
    getBackendStatus: () => 'OK | state=Running',
    setBackendStatus() {},
    getVpnStatus: () => 'OK | state=Running',
    setVpnStatus() {},
    isBackendReady: () => true,
    setBackendReady() {},
    isBackendInitializationVisible: () => false,
    setBackendInitializationVisible() {},
    setDevicesLoading() {},
    hasAuthenticatedSession: () => state.hasAuthenticatedSession,
    setHasAuthenticatedSession: v => { state.hasAuthenticatedSession = v; },
    isConnectInProgress: () => false,
    setConnectInProgressState() {},
    isDisconnectInProgress: () => false,
    setDisconnectInProgress() {},
    isLoginInProgress: () => false,
    setLoginInProgress() {},
    getLoginHandoffStatus: () => '',
    setLoginHandoffStatus() {},
    setLoginPromptKind() {},
    isAuthKeyLoginVisible: () => false,
    setAuthKeyLoginVisible() {},
    getAuthKeyInput: () => '',
    setAuthKeyInput() {},
    getAuthKeyStatus: () => '',
    setAuthKeyStatus() {},
    isControlServerConfirmed: () => true,
    setControlServerConfirmed() {},
    getControlServerURL: () => 'https://controlplane.tailscale.com',
    setControlServerURL() {},
    setControlServerInput() {},
    setControlServerStatus() {},
    setControlServerEditorVisible() {},
    setControlServerPresets() {},
    isControlServerSwitching: () => false,
    setControlServerSwitching() {},
    getAccountProfileId: () => 'default',
    setAccountProfileId() {},
    getAccountProfiles: () => [],
    setAccountProfiles() {},
    setAccountProfileStatus() {},
    getPeers: () => state.peers,
    onPeersUpdated: merged => {
      state.peers = merged;
      peerCtrl.pruneOfflineServiceStates(merged);
    },
    onPeerPresenceInvalidated: key => {
      peerCtrl.invalidatePeerPresence(key);
    },
    setMeshArcReceiver() {},
    setAccountSummary() {},
    setAvatarLoadFailed() {},
    getExitNodes: () => [],
    setExitNodes() {},
    isExitNodeUpdateInProgress: () => false,
    setExitNodeUpdateInProgress() {},
    isExitNodeStatusFailed: () => false,
    setExitNodeNoneStatus() {},
    setExitNodeSelectedStatus() {},
    setExitNodeUnavailableStatus() {},
    setExitNodeRawStatus() {},
    getNetworkSettings: () => ({ routeAll: true, exitNodeAllowLANAccess: false }),
    setNetworkSettings() {},
    setNetworkSettingStatus() {},
    isRouteAllUpdateInProgress: () => false,
    setRouteAllUpdateInProgress() {},
    isExitNodeLanUpdateInProgress: () => false,
    setExitNodeLanUpdateInProgress() {},
    setTrafficDownloadBytes() {},
    setTrafficUploadBytes() {},
    setTrafficDownloadRate() {},
    setTrafficUploadRate() {},
    getTrafficSamples: () => [],
    setTrafficSamples() {},
    isVpnConflictDialogVisible: () => false,
    setVpnConflictDialogVisible() {},
    showVpnConflictAlertDialog() {},
    syncHomeTitleCompact() {},
    setHomeTitleCompact() {},
    deviceModel: () => 'test',
    harmonyOSHostinfoVersion: () => '6.0',
    openControlServerSettings() {},
    openSecureLoginBrowser: async () => {},
    confirmControlServerSelection: () => undefined,
    invalidateAccountGuard() {},
    clearControlServerShellState() {},
    reloadTaildropStorageForActiveIdentity() {},
    resetTaildropSnapshot() {},
    applyBackendTaildropSnapshot() {},
    onLiveExtensionTick() {},
    resetStreamingStatesForDisconnect() {},
    autoProbeConnectedPeerServices() {},
    syncOfflinePeerStatusRefreshPolling() {},
    syncWindowPrivacyMode() {},
    logServiceStatusIfChanged() {},
    scheduleLifecycleTask: () => -1,
    recordDiagnosticEvent() {}
  };

  const shellMethods = new sandbox.ShellMethods();
  const peerHost = {
    getFilesDir: () => '/files',
    getAbilityContext: () => ({ filesDir: '/files' }),
    getLifecycleGeneration: () => state.lifecycleGeneration,
    getNavigationRevision: () => 0,
    getTrafficSession: () => state.trafficSession,
    isAppShellReady: () => state.appShellReady,
    isRemoteStreamAppInForeground: () => state.remoteStreamAppInForeground,
    setRemoteStreamAppInForeground: v => { state.remoteStreamAppInForeground = v; },
    isAppLockRequired: () => false,
    isAppLockAuthenticating: () => false,
    isConnected: () => true,
    getPeers: () => state.peers,
    peerEffectivelyOnline: p => shellMethods.peerEffectivelyOnline(p),
    getSelectedPeerKey: () => state.selectedPeerKey,
    isDeviceDetailVisible: () => false,
    setDeviceDetailVisible() {},
    getDeviceDetailPresentationId: () => 0,
    isDeviceDetailServiceRefreshInFlight: () => false,
    setDeviceDetailServiceRefreshInFlight() {},
    isTransferProtocolRefreshing: () => false,
    setTransferProtocolRefreshing() {},
    getStreamingStates: () => state.streamingStates,
    setStreamingStates: s => { state.streamingStates = s; },
    getMediaStates: () => state.mediaStates,
    setMediaStates: s => { state.mediaStates = s; },
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
    refreshPeerSnapshot() {},
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

  const vpnCtrl = new sandbox.VpnSessionController(vpnHost);
  vpnCtrl.mergePeers = peers => peers;
  peerCtrl = new sandbox.PeerIntegrationController(peerHost, {
    sunshineProbeService: probe(),
    peerPathService: probe(),
    moonlightLauncher: {},
    mediaServiceProbeService: probe(),
    hosPlayerLauncher: {}
  });

  const c = {
    isConnected: () => true,
    isConnecting: () => false,
    peerEffectivelyOnline: p => shellMethods.peerEffectivelyOnline(p),
    peerCardStatus: p => shellMethods.peerCardStatus.call(c, p),
    streamingState: k => peerCtrl.streamingState(k),
    copyStreamingState: (...args) => peerCtrl.copyStreamingState(...args),
    updateStreamingState: (...args) => peerCtrl.updateStreamingState(...args),
    applyPeers: list => vpnCtrl.applyPeers(list),
    refreshHomeLatency: () => peerCtrl.refreshHomeLatency(),
    autoProbeConnectedPeerServices: (...args) => peerCtrl.autoProbeConnectedPeerServices(...args)
  };
  for (const key of Object.keys(state)) {
    Object.defineProperty(c, key, {
      get: () => state[key],
      set: v => { state[key] = v; },
      configurable: true
    });
  }
  for (const key of [
    'streamingRequestIds', 'mediaRequestIds', 'peerServiceRefreshOwners',
    'autoProbedPeerSessions', 'autoSunshineFailureCounts', 'autoMediaFailureCounts',
    'peerServiceRefreshInFlight', 'sunshineProbeService', 'peerPathService',
    'mediaServiceProbeService', 'homeLatencyRefreshInFlight', 'refreshPeerServices'
  ]) {
    Object.defineProperty(c, key, {
      get: () => peerCtrl[key],
      set: v => { peerCtrl[key] = v; },
      configurable: true
    });
  }
  Object.defineProperty(c, 'emptyPeerSnapshotSinceMs', {
    get: () => vpnCtrl.emptyPeerSnapshotSinceMs,
    set: v => { vpnCtrl.emptyPeerSnapshotSinceMs = v; },
    configurable: true
  });
  return { c, invalidations, clock };
}

function path(c, type, checkedAt, errorMessage) {
  return c.copyStreamingState(c.streamingState('peer-test'), undefined,
    { type, checkedAt, errorMessage }, false);
}
const flush = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };

test('new live TUN retains the directory until its first non-empty peer snapshot', () => {
  const { c, clock, invalidations } = fixture();
  c.applyPeers([]); clock.now += 1500; c.applyPeers([]);
  assert.equal(c.peers.length, 1); assert.equal(invalidations.length, 0);
  c.applyPeers([peer(false)]);
  assert.equal(c.peers[0].online, false); assert.equal(c.emptyPeerSnapshotSinceMs, 0);
});
test('a sustained empty authenticated directory is eventually applied', () => {
  const { c, clock } = fixture(); c.applyPeers([]);
  clock.now += 4999; c.applyPeers([]); assert.equal(c.peers.length, 1);
  clock.now += 1; c.applyPeers([]); assert.equal(c.peers.length, 0);
});
test('logout clears the directory without waiting for an empty-snapshot grace', () => {
  const { c } = fixture(); c.applyPeers([]); c.hasAuthenticatedSession = false;
  c.applyPeers([]); assert.equal(c.peers.length, 0);
});

test('an online peer with a failed old probe stays in the online group and shows recovery', () => {
  const { c } = fixture();
  for (const reason of ['no_response', 'peer_offline', 'peer_not_found']) {
    c.streamingStates = [path(c, 'unreachable', 10, reason)];
    assert.equal(c.peerEffectivelyOnline(peer()), true, reason);
    assert.equal(c.peerCardStatus(peer()), 'app.string.connection_recovering');
  }
  assert.equal(c.peerEffectivelyOnline(peer(false)), false);
  assert.equal(c.peerCardStatus(peer(false)), 'app.string.peer_offline');
});

test('offline then online invalidates pending results and lets the same VPN session rediscover services', () => {
  const { c, invalidations } = fixture();
  c.streamingStates = [path(c, 'unreachable', 10, 'no_response')];
  c.autoProbedPeerSessions.set('peer-test', 1);
  c.streamingRequestIds.set('peer-test', 123);
  c.mediaRequestIds.set('peer-test', 123);
  c.applyPeers([peer(false)]);
  assert.equal(c.streamingRequestIds.has('peer-test'), false);
  assert.equal(c.mediaRequestIds.has('peer-test'), false);
  assert.ok(invalidations.includes('cache:peer-test'));
  c.applyPeers([peer()]);
  let probes = 0;
  c.refreshPeerServices = () => probes++;
  c.autoProbeConnectedPeerServices();
  assert.equal(probes, 1);
  assert.equal(c.peerEffectivelyOnline(c.peers[0]), true);
});

test('a busy old service request does not consume the reconnect discovery attempt', () => {
  const { c } = fixture(); let probes = 0;
  c.refreshPeerServices = () => probes++;
  c.peerServiceRefreshInFlight.add('peer-test');
  c.autoProbeConnectedPeerServices();
  assert.equal(c.autoProbedPeerSessions.has('peer-test'), false);
  c.peerServiceRefreshInFlight.clear();
  c.autoProbeConnectedPeerServices();
  assert.equal(probes, 1);
});

test('a slow service response cannot overwrite a more recent recovered path', () => {
  const { c } = fixture();
  c.updateStreamingState('peer-test', path(c, 'direct', 20));
  const old = path(c, 'unreachable', 10, 'no_response');
  old.sunshine = { state: 'available', checkedAt: 21 };
  c.updateStreamingState('peer-test', old);
  assert.equal(c.streamingState('peer-test').path.type, 'direct');
  assert.equal(c.streamingState('peer-test').sunshine.state, 'available');
});

for (const scenario of ['offline', 'new_session', 'new_lifecycle', 'cancelled', 'removed']) {
  test(`an obsolete home probe cannot reintroduce a path after ${scenario}`, async () => {
    const { c } = fixture(); let resolve;
    c.peerPathService.probe = () => new Promise(r => resolve = r);
    c.refreshHomeLatency();
    if (scenario === 'offline') c.peers = [peer(false)];
    if (scenario === 'removed') c.peers = [];
    if (scenario === 'new_session') c.trafficSession++;
    if (scenario === 'new_lifecycle') c.lifecycleGeneration++;
    resolve({ type: 'unknown', checkedAt: 10,
      errorMessage: scenario === 'cancelled' ? 'cancelled' : 'no_response' });
    await flush();
    assert.equal(c.streamingStates.length, 0);
    assert.equal(c.homeLatencyRefreshInFlight, false);
  });
}

test('home polling retries an online peer despite an old unreachable path', async () => {
  const { c } = fixture();
  c.streamingStates = [path(c, 'unreachable', 10, 'no_response')];
  c.peerPathService.probe = async () => ({ type: 'derp', checkedAt: 20 });
  c.refreshHomeLatency(); await flush();
  assert.equal(c.streamingState('peer-test').path.type, 'derp');
  assert.equal(c.peerEffectivelyOnline(peer()), true);
});
