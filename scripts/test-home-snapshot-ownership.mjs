import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';
import { loadEtsModules, readEtsSource } from './helpers/ets-vm-loader.mjs';

function loadVpnSessionController(scope) {
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
    'services/SettingsPreferencesGateway'
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
  loadEtsModules(['services/VpnSessionController'], scope);
}

function fixture() {
  let generation = 0, resolve, reject, reads = 0;
  const pending = new Promise((yes, no) => { resolve = yes; reject = no; });
  const scope = { setTimeout, clearTimeout, fileIo: {}, nativeBridge: {}, vpnExtension: {}, connection: {} };
  loadVpnSessionController(scope);
  scope.DiagnosticPrivacy.formatNativeFailure = () => 'FAILED';
  const state = {
    controlServerConfirmed: true, lifecycleGeneration: 1, connectInProgress: false,
    disconnectInProgress: false, connected: false,
    hasAuthenticatedSession: true, backendStatus: 'state=Running', peers: ['retained-peer'],
    exitNodes: ['exit'], authKeyStatus: ''
  };
  const host = {
    getFilesDir: () => '/files', getCacheDir: () => '/cache',
    getLifecycleGeneration: () => state.lifecycleGeneration,
    isAppShellReady: () => true, isAppLockRequired: () => false,
    isLogoutInProgress: () => false, isDiagnosticActionInProgress: () => false,
    isCacheClearInProgress: () => false, isTaildropSendActive: () => false,
    isTaildropReceiveInProgress: () => false, isTaildropMediaSaveInProgress: () => false,
    shouldPollHealthFast: () => false,
    getBackendStatus: () => state.backendStatus,
    setBackendStatus: s => { state.backendStatus = s; },
    getVpnStatus: () => state.connected ? 'OK | state=Running' : 'Stopped',
    setVpnStatus() {},
    isBackendReady: () => true, setBackendReady() {},
    isBackendInitializationVisible: () => false, setBackendInitializationVisible() {},
    setDevicesLoading() {},
    hasAuthenticatedSession: () => state.hasAuthenticatedSession,
    setHasAuthenticatedSession: v => { state.hasAuthenticatedSession = v; },
    isConnectInProgress: () => state.connectInProgress,
    setConnectInProgressState: v => { state.connectInProgress = v; },
    isDisconnectInProgress: () => state.disconnectInProgress,
    setDisconnectInProgress: v => { state.disconnectInProgress = v; },
    isLoginInProgress: () => false, setLoginInProgress() {},
    getLoginHandoffStatus: () => '', setLoginHandoffStatus() {}, setLoginPromptKind() {},
    isAuthKeyLoginVisible: () => false, setAuthKeyLoginVisible() {},
    getAuthKeyInput: () => '', setAuthKeyInput() {},
    getAuthKeyStatus: () => state.authKeyStatus,
    setAuthKeyStatus: s => { state.authKeyStatus = s; },
    isControlServerConfirmed: () => state.controlServerConfirmed,
    setControlServerConfirmed: v => { state.controlServerConfirmed = v; },
    getControlServerURL: () => 'https://controlplane.tailscale.com', setControlServerURL() {},
    setControlServerInput() {}, setControlServerStatus() {}, setControlServerEditorVisible() {}, setControlServerPresets() {},
    isControlServerSwitching: () => false, setControlServerSwitching() {},
    getAccountProfileId: () => 'default', setAccountProfileId() {},
    getAccountProfiles: () => [], setAccountProfiles() {}, setAccountProfileStatus() {},
    getPeers: () => state.peers, onPeersUpdated: p => { state.peers = p; }, onPeerPresenceInvalidated() {},
    setMeshArcReceiver() {}, setAccountSummary() {}, setAvatarLoadFailed() {},
    getExitNodes: () => state.exitNodes, setExitNodes: e => { state.exitNodes = e; },
    isExitNodeUpdateInProgress: () => false, setExitNodeUpdateInProgress() {},
    isExitNodeStatusFailed: () => false, setExitNodeNoneStatus() {},
    setExitNodeSelectedStatus() {}, setExitNodeUnavailableStatus() {}, setExitNodeRawStatus() {},
    getNetworkSettings: () => ({ routeAll: true, exitNodeAllowLANAccess: false }),
    setNetworkSettings() {}, setNetworkSettingStatus() {},
    isRouteAllUpdateInProgress: () => false, setRouteAllUpdateInProgress() {},
    isExitNodeLanUpdateInProgress: () => false, setExitNodeLanUpdateInProgress() {},
    setTrafficDownloadBytes() {}, setTrafficUploadBytes() {}, setTrafficDownloadRate() {}, setTrafficUploadRate() {},
    getTrafficSamples: () => [], setTrafficSamples() {},
    isVpnConflictDialogVisible: () => false, setVpnConflictDialogVisible() {}, showVpnConflictAlertDialog() {},
    syncHomeTitleCompact() {}, setHomeTitleCompact() {}, deviceModel: () => 'test', harmonyOSHostinfoVersion: () => '6.0',
    openControlServerSettings() {}, openSecureLoginBrowser: async () => {},
    confirmControlServerSelection: () => undefined, invalidateAccountGuard() {},
    clearControlServerShellState() {}, reloadTaildropStorageForActiveIdentity() {},
    resetTaildropSnapshot() {}, applyBackendTaildropSnapshot() {}, onLiveExtensionTick() {},
    resetStreamingStatesForDisconnect() {}, autoProbeConnectedPeerServices() {},
    syncOfflinePeerStatusRefreshPolling() {}, syncWindowPrivacyMode() {}, logServiceStatusIfChanged() {},
    scheduleLifecycleTask: () => -1, recordDiagnosticEvent() {}
  };
  const c = new scope.VpnSessionController(host, {
    homeReadOnlyRequestGuard: { begin: () => generation, isCurrent: n => n === generation, invalidate: () => generation++ },
    homeReadOnlyGateway: { readBackendSnapshot: () => { reads++; return pending; } }
  });
  c.isConnecting = () => state.connectInProgress;
  c.isConnected = () => state.connected;
  c.applyPeers = peers => { state.peers = peers; };
  c.applyAccountSummary = () => {};
  c.clearCachedPeerDirectory = () => {};
  c.completeSecureLoginAfterAuthentication = () => {};
  c.needsLogin = () => state.backendStatus.includes('NeedsLogin');
  for (const key of Object.keys(state)) {
    Object.defineProperty(c, key, {
      get: () => state[key],
      set: v => { state[key] = v; },
      configurable: true
    });
  }
  return { c, resolve, reject, reads: () => reads };
}
const empty = status => ({ status, peers: [], account: {}, exitNodes: [], networkSettings: {} });

for (const owner of ['connected', 'connectInProgress', 'disconnectInProgress', 'backendRestartDeferred']) {
  test(`UI engine is not queried while ${owner}`, async () => {
    const f = fixture(); f.c[owner] = true;
    await f.c.refreshBackendStatus();
    assert.equal(f.reads(), 0); assert.equal(f.c.peers.length, 1);
  });
}
for (const status of ['state=NeedsLogin', 'state=Running']) {
  test(`late ${status} snapshot cannot erase directory after handoff`, async () => {
    const f = fixture(); const task = f.c.refreshBackendStatus();
    f.c.setConnectInProgress(true); f.c.connected = true; f.c.setConnectInProgress(false);
    f.resolve(empty(status)); await task;
    assert.equal(f.c.peers.length, 1); assert.equal(f.c.hasAuthenticatedSession, true);
    assert.equal(f.c.backendStatus, 'state=Running'); assert.equal(f.c.refreshInFlight, false);
  });
}
test('obsolete UI read remains invalid after a complete connect/disconnect cycle', async () => {
  const f = fixture(); const task = f.c.refreshBackendStatus();
  f.c.setConnectInProgress(true); f.c.setConnectInProgress(false);
  f.resolve(empty('state=NeedsLogin')); await task;
  assert.equal(f.c.peers.length, 1); assert.equal(f.c.hasAuthenticatedSession, true);
});
test('a late UI-engine failure cannot replace live extension state', async () => {
  const f = fixture(); const task = f.c.refreshBackendStatus(); f.c.connected = true;
  f.reject(Error('old engine stopped')); await task;
  assert.equal(f.c.backendStatus, 'state=Running'); assert.equal(f.c.refreshInFlight, false);
});
test('current signed-out UI engine still clears old account devices', async () => {
  const f = fixture(); const task = f.c.refreshBackendStatus();
  f.resolve(empty('state=NeedsLogin')); await task;
  assert.equal(f.c.peers.length, 0); assert.equal(f.c.hasAuthenticatedSession, false);
});
test('a current empty authenticated directory is accepted', async () => {
  const f = fixture(); const task = f.c.refreshBackendStatus();
  f.resolve(empty('state=Running')); await task;
  assert.equal(f.c.peers.length, 0); assert.equal(f.c.hasAuthenticatedSession, true);
});
