import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
import { createMemoryFileIo, loadEtsModules, readEtsSource } from './helpers/ets-vm-loader.mjs';
import { fileURLToPath } from 'node:url';

const REPO_ROOT = new URL('../', import.meta.url);
const readRepoFile = rel => readFileSync(new URL(rel, REPO_ROOT), 'utf8').replace(/\r\n/g, '\n');

function collectEtsFiles(dirPath) {
  const results = [];
  for (const entry of readdirSync(dirPath, { withFileTypes: true })) {
    const full = join(dirPath, entry.name);
    if (entry.isDirectory()) {
      results.push(...collectEtsFiles(full));
    } else if (entry.isFile() && entry.name.endsWith('.ets')) {
      results.push(full);
    }
  }
  return results;
}

function extractStringUnionLiterals(src, typeName) {
  const match = new RegExp(`export type ${typeName}\\s*=([\\s\\S]*?);`).exec(src);
  assert.ok(match, `Missing union type ${typeName}`);
  const keys = [];
  for (const m of match[1].matchAll(/'([^']+)'/g)) {
    keys.push(m[1]);
  }
  return keys;
}

function stripCommentsAndStrings(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, m => m.replace(/[^\n]/g, ' '))
    .replace(/\/\/[^\n]*/g, '')
    .replace(/'(?:\\.|[^'\\])*'/g, "''")
    .replace(/"(?:\\.|[^"\\])*"/g, '""');
}

function getDeclaredClassMembers(relPath, containerHeader) {
  const src = readRepoFile(relPath);
  const start = src.indexOf(containerHeader);
  assert.ok(start >= 0, `Missing ${containerHeader} in ${relPath}`);
  const body = src.slice(start);
  const declared = new Set();
  const fieldPattern = /^  (?:@[A-Za-z0-9_]+(?:\([^)]*\))?\s+)*(?:private\s+|public\s+)?(?:readonly\s+|static\s+)*([A-Za-z_][A-Za-z0-9_]*)\??\s*:/gm;
  const methodPattern = /^  (?:private\s+|public\s+)?(?:static\s+)?(?:async\s+)?([A-Za-z_][A-Za-z0-9_]*)(?:<[^>]+>)?\s*\(/gm;
  for (const m of body.matchAll(fieldPattern)) declared.add(m[1]);
  for (const m of body.matchAll(methodPattern)) declared.add(m[1]);
  return { src, body, declared };
}

function getInterfaceMembers(src, interfaceName) {
  const start = src.indexOf(`export interface ${interfaceName} {`);
  assert.ok(start >= 0, `Missing interface ${interfaceName}`);
  const end = src.indexOf('\n}', start);
  const body = src.slice(start, end);
  const members = new Set();
  for (const m of body.matchAll(/^  ([A-Za-z_][A-Za-z0-9_]*)\??\s*:/gm)) {
    members.add(m[1]);
  }
  return members;
}

function loadVpnCommandGateway(scope) {
  const gwRaw = readEtsSource('services/VpnCommandGateway')
    .replace(/^import\s+['"][^'"]+['"]\s*;?[ \t]*\r?$/gm, '')
    .replace(/^import\s+(?:type\s+)?[\s\S]*?\bfrom\s+['"][^'"]+['"]\s*;?[ \t]*\r?$/gm, '')
    .replace(/^export\s+/gm, '');
  vm.runInContext(
    `${stripTypeScriptTypes(gwRaw, { mode: 'transform' })}\nglobalThis.VpnCommandState = VpnCommandState; globalThis.VpnCoreCommand = VpnCoreCommand; globalThis.VpnCommandStateMachine = VpnCommandStateMachine; globalThis.VpnCommandGateway = VpnCommandGateway;`,
    scope
  );
}

test('BridgeStatus has zero fileIo/nativeBridge tokens and all extracted controllers obey strict ArkTS & member-resolution invariants', () => {
  const bridgeRaw = readRepoFile('entry/src/main/ets/components/BridgeStatus.ets');
  const bridgeCode = stripCommentsAndStrings(bridgeRaw);
  assert.doesNotMatch(bridgeCode, /\bfileIo\b/, 'BridgeStatus.ets must have zero fileIo references');
  assert.doesNotMatch(bridgeCode, /\bnativeBridge\b/, 'BridgeStatus.ets must have zero nativeBridge references');
  assert.doesNotMatch(bridgeRaw, /libtailscale_ohos/, 'BridgeStatus.ets must not import libtailscale_ohos.so');

  for (const relPath of [
    'entry/src/main/ets/services/VpnSessionController.ets',
    'entry/src/main/ets/services/TaildropSessionController.ets',
    'entry/src/main/ets/services/PeerIntegrationController.ets',
    'entry/src/main/ets/services/SettingsPreferencesGateway.ets'
  ]) {
    const raw = readRepoFile(relPath);
    const code = stripCommentsAndStrings(raw);
    assert.doesNotMatch(raw, /@kit\.ArkUI/, `${relPath} must not import @kit.ArkUI`);
    assert.doesNotMatch(code, /\$r\s*\(/, `${relPath} must be $r-free`);
    assert.doesNotMatch(code, /@(?:State|Prop|Link|Builder)\b/, `${relPath} must not use ArkUI decorators`);
    assert.doesNotMatch(code, /\{[^{}]*\.\.\.[A-Za-z_$]/, `${relPath} must not use object spread literals`);
  }

  const arkuiComponentBuiltIns = new Set([
    'getUIContext', 'getUniqueId', 'queryNavDestinationInfo',
    'queryNavigationInfo', 'queryRouterPageInfo'
  ]);
  const bridge = getDeclaredClassMembers('entry/src/main/ets/components/BridgeStatus.ets', 'export struct BridgeStatus {');
  const vpn = getDeclaredClassMembers('entry/src/main/ets/services/VpnSessionController.ets', 'export class VpnSessionController {');
  const taildrop = getDeclaredClassMembers('entry/src/main/ets/services/TaildropSessionController.ets', 'export class TaildropSessionController {');
  const peer = getDeclaredClassMembers('entry/src/main/ets/services/PeerIntegrationController.ets', 'export class PeerIntegrationController {');
  const settings = getDeclaredClassMembers('entry/src/main/ets/services/SettingsPreferencesGateway.ets', 'export class SettingsPreferencesGateway {');

  for (const [label, info, extraAllowed] of [
    ['BridgeStatus', bridge, arkuiComponentBuiltIns],
    ['VpnSessionController', vpn, new Set()],
    ['TaildropSessionController', taildrop, new Set()],
    ['PeerIntegrationController', peer, new Set()],
    ['SettingsPreferencesGateway', settings, new Set()]
  ]) {
    const stripped = stripCommentsAndStrings(info.body);
    const unresolved = new Set();
    for (const m of stripped.matchAll(/(?:\$\$)?this\.([A-Za-z_][A-Za-z0-9_]*)/g)) {
      if (!info.declared.has(m[1]) && !extraAllowed.has(m[1])) {
        unresolved.add(m[1]);
      }
    }
    assert.deepEqual([...unresolved], [], `${label} has unresolved this.<ident> references`);
  }

  const strippedBridge = stripCommentsAndStrings(bridge.body);
  for (const [prop, target] of [
    ['vpnSessionController', vpn.declared],
    ['taildropSessionController', taildrop.declared],
    ['peerIntegrationController', peer.declared],
    ['settingsPreferencesGateway', settings.declared]
  ]) {
    const missing = new Set();
    for (const m of strippedBridge.matchAll(new RegExp(`this\\.${prop}\\.([A-Za-z_][A-Za-z0-9_]*)`, 'g'))) {
      if (!target.has(m[1])) missing.add(m[1]);
    }
    assert.deepEqual([...missing], [], `BridgeStatus -> this.${prop}.* has missing members`);
  }

  for (const [name, ctrl, ifaceName, hostField] of [
    ['VpnSessionController', vpn, 'VpnSessionHost', 'vpnSessionHost'],
    ['TaildropSessionController', taildrop, 'TaildropSessionHost', 'taildropSessionHost'],
    ['PeerIntegrationController', peer, 'PeerIntegrationHost', 'peerIntegrationHost']
  ]) {
    const ifaceMembers = getInterfaceMembers(ctrl.src, ifaceName);
    const strippedCtrl = stripCommentsAndStrings(ctrl.body);
    const missingOnIface = new Set();
    for (const m of strippedCtrl.matchAll(/this\.host\.([A-Za-z_][A-Za-z0-9_]*)/g)) {
      if (!ifaceMembers.has(m[1])) missingOnIface.add(m[1]);
    }
    assert.deepEqual([...missingOnIface], [], `${name} calls undeclared ${ifaceName} methods`);

    const hostStart = bridge.body.indexOf(`private readonly ${hostField}: ${ifaceName} = {`);
    assert.ok(hostStart >= 0, `Missing ${hostField} on BridgeStatus`);
    const hostEnd = bridge.body.indexOf('\n  };', hostStart);
    const hostLiteral = bridge.body.slice(hostStart, hostEnd);
    const providedKeys = new Set();
    for (const m of hostLiteral.matchAll(/^    ([A-Za-z_][A-Za-z0-9_]*)\s*:/gm)) {
      providedKeys.add(m[1]);
    }
    const extraKeys = [...providedKeys].filter(k => !ifaceMembers.has(k));
    const missingKeys = [...ifaceMembers].filter(k => !providedKeys.has(k));
    assert.deepEqual(extraKeys, [], `${hostField} provides undeclared keys`);
    assert.deepEqual(missingKeys, [], `${hostField} misses required ${ifaceName} keys`);
  }

  // Every $r(...) call across entry/src/main/ets/**/*.ets must pass a plain '...' or "..." literal
  // (HarmonyOS $r is a compile-time ResourceTable macro; template/dynamic expressions emit id: -1).
  const etsRoot = fileURLToPath(new URL('entry/src/main/ets', REPO_ROOT));
  const nonLiteralResourceCalls = [];
  for (const filePath of collectEtsFiles(etsRoot)) {
    const raw = readFileSync(filePath, 'utf8')
      .replace(/\/\*[\s\S]*?\*\//g, m => m.replace(/[^\n]/g, ' '))
      .replace(/\/\/[^\n]*/g, '');
    for (const m of raw.matchAll(/\$r\s*\(\s*([^\s)]?)/g)) {
      if (m[1] !== "'" && m[1] !== '"') {
        nonLiteralResourceCalls.push(`${filePath}:${m.index}`);
      }
    }
  }
  assert.deepEqual(nonLiteralResourceCalls, [], 'All $r(...) calls must pass static plain string literals');

  // Verify every TaildropToastKey (41) and PeerIntegrationToastKey (17) union member is statically mapped in BridgeStatus.ets
  const taildropToastKeys = extractStringUnionLiterals(taildrop.src, 'TaildropToastKey');
  const peerToastKeys = extractStringUnionLiterals(peer.src, 'PeerIntegrationToastKey');
  assert.equal(taildropToastKeys.length, 41, 'Expected 41 TaildropToastKey members');
  assert.equal(peerToastKeys.length, 17, 'Expected 17 PeerIntegrationToastKey members');
  for (const key of [...taildropToastKeys, ...peerToastKeys]) {
    assert.ok(
      bridgeRaw.includes(`$r('app.string.${key}')`),
      `BridgeStatus.ets missing static $r('app.string.${key}') mapping`
    );
  }
  assert.equal(bridge.declared.has('taildropPreviewAvailabilityRevision'), false,
    'BridgeStatus must not retain unused taildropPreviewAvailabilityRevision field');
});

test('VpnSessionController manages fileIo.Watcher lifecycle and serializes network-setting & exit-node updates', async () => {
  const mem = createMemoryFileIo();
  const statusFilePath = '/files/vpn-probe-status.txt';
  mem.files.set(statusFilePath, `Starting | heartbeatMs=${Date.now()}`);

  let watcherStarted = 0;
  let watcherStopped = 0;
  let watcherCb = null;
  let throwOnWatcherStop = false;
  const intervals = new Map();
  let nextInterval = 1;

  const fileIo = {
    ...mem.fileIo,
    createWatcher(path, events, cb) {
      assert.equal(path, statusFilePath);
      assert.equal(events, 0x8);
      watcherCb = cb;
      return {
        start() { watcherStarted++; },
        stop() {
          watcherStopped++;
          if (throwOnWatcherStop) throw new Error('already closed');
        }
      };
    }
  };

  const scope = {
    Date,
    fileIo,
    nativeBridge: {},
    vpnExtension: {},
    connection: {},
    setTimeout,
    clearTimeout,
    setInterval(cb, delay) { const id = nextInterval++; intervals.set(id, { cb, delay }); return id; },
    clearInterval(id) { intervals.delete(id); }
  };
  loadEtsModules([
    'services/AtomicFileStore', 'services/DiagnosticPrivacy', 'services/ControlServerConfig',
    'services/ControlServerPresets', 'services/AccountProfiles', 'services/DeviceNameService',
    'services/AuthKeyLogin', 'services/VpnAutoRecovery', 'services/HomeReadOnlyGateway',
    'services/NetworkSettingsGateway', 'services/SettingsPreferencesGateway'
  ], scope);
  loadVpnCommandGateway(scope);
  loadEtsModules(['services/VpnSessionController'], scope);

  const state = {
    vpnStatus: 'Starting',
    exitNodes: [
      { id: 'exit-1', name: 'Tokyo', selected: false },
      { id: 'exit-2', name: 'Frankfurt', selected: false }
    ],
    exitNodeStatus: '',
    exitNodeBusy: false,
    networkSettings: { routeAll: true, exitNodeAllowLANAccess: false },
    networkSettingStatus: '',
    routeAllBusy: false,
    lanBusy: false
  };
  const exitUpdates = [];
  const settingUpdates = [];

  const ctrl = new scope.VpnSessionController({
    getFilesDir: () => '/files', getCacheDir: () => '/cache', getLifecycleGeneration: () => 1,
    isAppShellReady: () => true, isAppLockRequired: () => false, isLogoutInProgress: () => false,
    isDiagnosticActionInProgress: () => false, isCacheClearInProgress: () => false,
    isTaildropSendActive: () => false, isTaildropReceiveInProgress: () => false,
    isTaildropMediaSaveInProgress: () => false, shouldPollHealthFast: () => false,
    getBackendStatus: () => 'OK | state=Running', setBackendStatus() {},
    getVpnStatus: () => state.vpnStatus, setVpnStatus: s => { state.vpnStatus = s; },
    isBackendReady: () => true, setBackendReady() {}, isBackendInitializationVisible: () => false,
    setBackendInitializationVisible() {}, setDevicesLoading() {}, hasAuthenticatedSession: () => true,
    setHasAuthenticatedSession() {}, isConnectInProgress: () => false, setConnectInProgressState() {},
    isDisconnectInProgress: () => false, setDisconnectInProgress() {}, isLoginInProgress: () => false,
    setLoginInProgress() {}, getLoginHandoffStatus: () => '', setLoginHandoffStatus() {},
    setLoginPromptKind() {}, isAuthKeyLoginVisible: () => false, setAuthKeyLoginVisible() {},
    getAuthKeyInput: () => '', setAuthKeyInput() {}, getAuthKeyStatus: () => '', setAuthKeyStatus() {},
    isControlServerConfirmed: () => true, setControlServerConfirmed() {},
    getControlServerURL: () => 'https://controlplane.tailscale.com', setControlServerURL() {},
    setControlServerInput() {}, setControlServerStatus() {}, setControlServerEditorVisible() {},
    setControlServerPresets() {}, isControlServerSwitching: () => false, setControlServerSwitching() {},
    getAccountProfileId: () => 'default', setAccountProfileId() {}, getAccountProfiles: () => [],
    setAccountProfiles() {}, setAccountProfileStatus() {}, getPeers: () => [], onPeersUpdated() {},
    onPeerPresenceInvalidated() {}, setMeshArcReceiver() {}, setAccountSummary() {},
    setAvatarLoadFailed() {}, getExitNodes: () => state.exitNodes, setExitNodes: e => { state.exitNodes = e; },
    isExitNodeUpdateInProgress: () => state.exitNodeBusy, setExitNodeUpdateInProgress: v => { state.exitNodeBusy = v; },
    isExitNodeStatusFailed: () => state.exitNodeStatus.startsWith('FAILED'),
    setExitNodeNoneStatus: () => { state.exitNodeStatus = 'none'; },
    setExitNodeSelectedStatus: name => { state.exitNodeStatus = `selected:${name}`; },
    setExitNodeUnavailableStatus: () => { state.exitNodeStatus = 'unavailable'; },
    setExitNodeRawStatus: s => { state.exitNodeStatus = s; },
    getNetworkSettings: () => state.networkSettings, setNetworkSettings: s => { state.networkSettings = s; },
    setNetworkSettingStatus: s => { state.networkSettingStatus = s; },
    isRouteAllUpdateInProgress: () => state.routeAllBusy, setRouteAllUpdateInProgress: v => { state.routeAllBusy = v; },
    isExitNodeLanUpdateInProgress: () => state.lanBusy, setExitNodeLanUpdateInProgress: v => { state.lanBusy = v; },
    setTrafficDownloadBytes() {}, setTrafficUploadBytes() {}, setTrafficDownloadRate() {},
    setTrafficUploadRate() {}, getTrafficSamples: () => [], setTrafficSamples() {},
    isVpnConflictDialogVisible: () => false, setVpnConflictDialogVisible() {},
    showVpnConflictAlertDialog() {}, syncHomeTitleCompact() {}, setHomeTitleCompact() {},
    deviceModel: () => 'test', harmonyOSHostinfoVersion: () => '6.0', openControlServerSettings() {},
    openSecureLoginBrowser: async () => {}, confirmControlServerSelection: () => undefined,
    invalidateAccountGuard() {}, clearControlServerShellState() {},
    reloadTaildropStorageForActiveIdentity() {}, resetTaildropSnapshot() {},
    applyBackendTaildropSnapshot() {}, onLiveExtensionTick() {}, resetStreamingStatesForDisconnect() {},
    autoProbeConnectedPeerServices() {}, syncOfflinePeerStatusRefreshPolling() {},
    syncWindowPrivacyMode() {}, logServiceStatusIfChanged() {}, scheduleLifecycleTask: () => -1,
    recordDiagnosticEvent() {}
  }, {
    networkSettingsGateway: {
      readExitNodes: () => JSON.stringify(state.exitNodes),
      readNetworkSettings: () => JSON.stringify(state.networkSettings),
      async writeExitNode(id) {
        exitUpdates.push(id);
        state.exitNodes = state.exitNodes.map(n => ({ ...n, selected: n.id === id }));
        return 'OK';
      },
      async writeNetworkSetting(key, enabled) {
        settingUpdates.push([key, enabled]);
        state.networkSettings = { ...state.networkSettings, [key]: enabled };
        return 'OK | applied';
      }
    }
  });
  ctrl.vpnHeartbeatConfirmed = true;
  ctrl.refreshBackendStatus = async () => {};

  ctrl.startConnectionPolling();
  assert.equal(watcherStarted, 1);
  assert.equal(intervals.size, 1);

  mem.files.set(statusFilePath, `OK | state=Running | tun=true | heartbeatMs=${Date.now()}`);
  throwOnWatcherStop = true;
  watcherCb();
  assert.equal(watcherStopped, 1, 'reaching state=Running stops watcher automatically');
  assert.equal(intervals.size, 0);
  assert.match(state.vpnStatus, /state=Running/);

  // Coalesce rapid exit-node updates and toggle routeAll cleanly
  state.vpnStatus = 'Stopped';
  ctrl.queueExitNodeUpdate('exit-1');
  ctrl.queueExitNodeUpdate('exit-2');
  await ctrl.exitNodeUpdatePromise;
  assert.equal(exitUpdates.at(-1), 'exit-2');
  assert.equal(state.exitNodeStatus, 'selected:Frankfurt');
  assert.equal(state.exitNodeBusy, false);

  ctrl.toggleNetworkSetting('routeAll');
  await ctrl.routeAllUpdatePromise;
  assert.deepEqual(settingUpdates, [['routeAll', false]]);
  assert.equal(state.networkSettings.routeAll, false);
  assert.equal(state.routeAllBusy, false);
});

test('TaildropSessionController dispatches offline receive via injected native callback and isolates per-account storage', async () => {
  const mem = createMemoryFileIo();
  const nativeCalls = [];
  let resolveNative;
  const scope = {
    Date,
    fileIo: mem.fileIo,
    pasteboard: {},
    nativeBridge: {},
    picker: {},
    fileUri: {},
    image: {},
    media: {},
    photoAccessHelper: {},
    setTimeout,
    clearTimeout,
    cryptoFramework: {
      createRandom: () => ({ generateRandomSync: () => ({ data: new Uint8Array(32).fill(5) }) })
    }
  };
  loadEtsModules([
    'services/AtomicFileStore',
    'services/AppShellIntentAdapter',
    'services/RecoverableCachePaths',
    'services/TaildropContentGateway',
    'services/TaildropReceiveGateway',
    'services/TaildropSendGateway',
    'services/TaildropSessionController'
  ], scope);

  const state = {
    serverRoot: '/files/account-a',
    connected: false,
    backendStatus: 'OK | state=Running',
    receiveInProgress: true,
    receive: { requestId: 77, action: 'stage', state: 'staging', reason: '', name: 'doc.pdf', size: 120, path: '' },
    history: [],
    waitingFiles: [],
    cachedFiles: [],
    previews: []
  };
  const ctrl = new scope.TaildropSessionController({
    getFilesDir: () => '/files',
    getCacheDir: () => '/cache',
    getServerFilesRoot: () => state.serverRoot,
    getAbilityContext: () => ({ filesDir: '/files', cacheDir: '/cache' }),
    getLifecycleGeneration: () => 1,
    getControlServerEpoch: () => 1,
    isAppShellReady: () => true,
    isSecurityPreferencesReady: () => true,
    isAppLockRequired: () => false,
    isAppLockAuthenticating: () => false,
    isSecurityCoverActive: () => false,
    isConnected: () => state.connected,
    isConnecting: () => false,
    isDisconnectInProgress: () => false,
    isLogoutInProgress: () => false,
    isDiagnosticActionInProgress: () => false,
    isControlServerSwitching: () => false,
    getBackendStatus: () => state.backendStatus,
    getTaildropState: () => 'ready',
    setTaildropState() {},
    getTaildropReason: () => '',
    setTaildropReason() {},
    getTaildropTargets: () => [],
    setTaildropTargets() {},
    getTaildropWaitingFiles: () => state.waitingFiles,
    setTaildropWaitingFiles: f => { state.waitingFiles = f; },
    getTaildropInboxReason: () => '',
    setTaildropInboxReason() {},
    getTaildropTransfer: () => scope.emptyTaildropTransfer(),
    setTaildropTransfer() {},
    getTaildropReceive: () => state.receive,
    setTaildropReceive: r => { state.receive = r; },
    getTaildropMediaPreviews: () => state.previews,
    setTaildropMediaPreviews: p => { state.previews = p; },
    getTaildropCachedFiles: () => state.cachedFiles,
    setTaildropCachedFiles: f => { state.cachedFiles = f; },
    getTaildropHistory: () => state.history,
    setTaildropHistory: h => { state.history = h; },
    isTaildropPreparing: () => false,
    setTaildropPreparing() {},
    isTaildropReceiveInProgress: () => state.receiveInProgress,
    setTaildropReceiveInProgress: v => { state.receiveInProgress = v; },
    isTaildropMediaSaveInProgress: () => false,
    setTaildropMediaSaveInProgress() {},
    isTaildropTextEditorVisible: () => false,
    setTaildropTextEditorVisible() {},
    isTaildropTextPreviewVisible: () => false,
    setTaildropTextPreviewVisible() {},
    getTaildropTextInput: () => '',
    setTaildropTextInput() {},
    setTaildropTextInputCanSend() {},
    getTaildropReceivedText: () => '',
    setTaildropReceivedText() {},
    getTaildropTransferRate: () => 0,
    setTaildropTransferRate() {},
    getTaildropTransferEtaSeconds: () => 0,
    setTaildropTransferEtaSeconds() {},
    isTaildropCancelPending: () => false,
    setTaildropCancelPending() {},
    isTaildropPreviewCachePresent: () => false,
    setTaildropPreviewCachePresent() {},
    getMissingTaildropPreviewPaths: () => [],
    setMissingTaildropPreviewPaths() {},
    isCacheClearInProgress: () => false,
    setCacheClearInProgress() {},
    getTaildropNotificationAction: () => '',
    clearTaildropNotificationAction() {},
    scheduleExternalTabNavigation() {},
    scrollTransferToTop() {},
    onCacheContentsChanged() {},
    refreshCacheSize() {},
    scheduleLifecycleTask: () => -1,
    showTaildropToast() {},
    recordDiagnosticEvent() {}
  }, {
    backendTaildropReceiveAsync: reqJson => {
      nativeCalls.push(JSON.parse(reqJson));
      return new Promise(resolve => { resolveNative = resolve; });
    }
  });

  const handledResults = [];
  ctrl.handleTaildropReceiveResult = async res => { handledResults.push(res); };

  const dispatched = ctrl.dispatchTaildropReceiveRequest({
    requestId: 77,
    action: 'stage',
    fileName: 'doc.pdf',
    expectedSize: 120,
    destinationDir: '/files/account-a/inbox'
  });
  assert.equal(dispatched, true);
  assert.equal(nativeCalls.length, 1);
  assert.equal(nativeCalls[0].requestId, 77);
  assert.equal(mem.files.has('/files/taildrop-receive-request.json'), false, 'direct backend receive bypasses extension IPC request file');

  resolveNative(JSON.stringify({
    requestId: 77,
    action: 'stage',
    state: 'staged',
    reason: '',
    name: 'doc.pdf',
    size: 120,
    path: '/files/account-a/inbox/doc.pdf'
  }));
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(handledResults.length, 1);
  assert.equal(handledResults[0].state, 'staged');
  assert.equal(ctrl.taildropReceiveResponseInFlight, false);

  // Per-account history isolation across serverRoot switch
  state.history = [{
    requestId: 77, direction: 'receive', targetKey: 'peer-0123456789abcdef', targetName: 'Mac', fileName: 'doc.pdf',
    fileCount: 1, totalBytes: 120, state: 'completed', reason: '', previewPath: '', completedAtMs: 1000
  }];
  const accountAHistoryPath = ctrl.taildropHistoryPath();
  ctrl.persistTaildropHistory();
  assert.equal(mem.files.has(accountAHistoryPath), true);
  assert.ok(accountAHistoryPath.startsWith('/files/account-a/'));

  state.serverRoot = '/files/account-b';
  ctrl.resetForControlServerSwitch();
  ctrl.reloadStorageForActiveIdentity();
  assert.equal(state.history.length, 0, 'switching serverRoot loads clean identity history');

  state.serverRoot = '/files/account-a';
  ctrl.resetForControlServerSwitch();
  ctrl.reloadStorageForActiveIdentity();
  assert.equal(state.history.length, 1);
  assert.equal(state.history[0].fileName, 'doc.pdf');
});

test('PeerIntegrationController validates LocalSend port overrides and coalesces manual transfer protocol refreshes', async () => {
  const savedPorts = [];
  const toasts = [];
  let localSendResolvers = [];
  const scope = {
    Date,
    systemDateTime: { TimeType: { STARTUP: 0 }, getUptime: () => 5000 },
    fileIo: {},
    nativeBridge: {},
    vpnExtension: {},
    connection: {},
    setTimeout,
    clearTimeout,
    SunshineProbeService: class {},
    PeerPathService: class {},
    MoonlightLauncher: class {},
    MediaServiceProbeService: class {},
    HosPlayerLauncher: class {}
  };
  loadEtsModules([
    'services/AtomicFileStore', 'services/DiagnosticPrivacy', 'services/ControlServerConfig',
    'services/HomeReadOnlyGateway', 'services/AccountDiagnosticsGateway',
    'services/FileTransferPreferences', 'services/StreamingModels',
    'services/StreamProfileBuilder', 'services/MediaIntegrationModels'
  ], scope);
  loadVpnCommandGateway(scope);
  loadEtsModules(['services/PeerIntegrationController'], scope);
  scope.FileTransferPreferences.saveLocalSendPortOverride = async (_ctx, key, port) => {
    savedPorts.push([key, port]);
  };

  const peer = { key: 'peer-0123456789abcdef', name: 'Desktop', os: 'windows', online: true, addresses: ['100.64.0.9'], localSend: { state: 'available', port: 53317 } };
  const state = {
    overrides: [],
    remotePortPeerKey: peer.key,
    remotePortInput: '0',
    editorVisible: true,
    refreshing: false,
    taildropRefreshes: 0
  };
  const ctrl = new scope.PeerIntegrationController({
    getFilesDir: () => '/files', getAbilityContext: () => ({ filesDir: '/files' }),
    getLifecycleGeneration: () => 1, getNavigationRevision: () => 0, getTrafficSession: () => 1,
    isAppShellReady: () => true, isRemoteStreamAppInForeground: () => true, setRemoteStreamAppInForeground() {},
    isAppLockRequired: () => false, isAppLockAuthenticating: () => false, isConnected: () => true,
    getPeers: () => [peer], peerEffectivelyOnline: p => p.online, getSelectedPeerKey: () => '',
    isDeviceDetailVisible: () => false, setDeviceDetailVisible() {}, getDeviceDetailPresentationId: () => 0,
    isDeviceDetailServiceRefreshInFlight: () => false, setDeviceDetailServiceRefreshInFlight() {},
    isTransferProtocolRefreshing: () => state.refreshing, setTransferProtocolRefreshing: v => { state.refreshing = v; },
    getStreamingStates: () => [], setStreamingStates() {}, getMediaStates: () => [], setMediaStates() {},
    isFakeMediaServiceOnline: () => false, getFakeJellyfinName: () => 'Jellyfin',
    isMediaSelfTestInProgress: () => false, setMediaSelfTestInProgress() {}, setMediaSelfTestStatusKind() {},
    getLocalSendPortOverrides: () => state.overrides, setLocalSendPortOverrides: o => { state.overrides = o; },
    getRemotePortPeerKey: () => state.remotePortPeerKey, getRemotePortInput: () => state.remotePortInput,
    setRemotePortEditorVisible: v => { state.editorVisible = v; },
    setTaildropFocusedTargetKey() {}, getTaildropFocusedTargetKey: () => '',
    refreshBackendStatus: async () => {}, refreshPeerSnapshot() {},
    refreshTaildropSnapshot: () => { state.taildropRefreshes++; },
    logServiceStatusIfChanged() {}, scheduleLifecycleTask: () => -1,
    showPeerIntegrationToast: k => toasts.push(k),
    showDerpStreamConfirmationDialog() {}, showMoonlightRequiredDialog() {},
    copyHosPlayerPrototypeText() {}, recordDiagnosticEvent() {}, recordFeatureDiagnosticEvent() {}
  });
  ctrl.requestLocalSendRefresh = () => new Promise(resolve => { localSendResolvers.push(resolve); });

  assert.equal(ctrl.localSendPortForPeer(peer), 53317);
  for (const invalid of ['0', '70000', 'abc', '80.5']) {
    state.remotePortInput = invalid;
    ctrl.saveRemotePortOverride();
  }
  assert.equal(state.overrides.length, 0);
  assert.ok(toasts.every(t => t === 'transfer_remote_port_invalid'));

  state.remotePortInput = ' 53320 ';
  ctrl.saveRemotePortOverride();
  assert.equal(ctrl.localSendPortForPeer(peer), 53320);
  assert.equal(state.editorVisible, false);
  assert.deepEqual(savedPorts, [[peer.key, 53320]]);
  assert.equal(toasts.at(-1), 'transfer_remote_port_saved');

  // Overlapping background + manual transfer protocol refresh queues one manual follow-up
  ctrl.refreshTransferProtocolStatus(false);
  assert.equal(state.refreshing, false);
  ctrl.handleTransferProtocolRefreshClick();
  assert.equal(state.refreshing, true);
  assert.equal(localSendResolvers.length, 1);

  localSendResolvers.shift()();
  await Promise.resolve();
  await Promise.resolve();
  assert.equal(localSendResolvers.length, 1, 'queued manual refresh starts automatically');
  assert.equal(state.refreshing, true);

  localSendResolvers.shift()();
  await Promise.resolve();
  await Promise.resolve();
  assert.equal(state.refreshing, false);
});

test('SettingsPreferencesGateway atomically persists changelog, welcome, glow, and appearance overlay files without temp leftovers', () => {
  const mem = createMemoryFileIo();
  const scope = { fileIo: mem.fileIo, HomeLayoutPreferences: { load: async () => 'compact' } };
  loadEtsModules([
    'services/AtomicFileStore',
    'services/DiagnosticPrivacy',
    'services/ControlServerConfig',
    'services/SettingsPreferencesGateway'
  ], scope);

  const gw = new scope.SettingsPreferencesGateway();
  assert.equal(gw.hasSeenUpdateChangelog('/files', '1.2.3:10'), false);
  assert.equal(gw.markUpdateChangelogSeen('/files', '1.2.3:10'), true);
  assert.equal(gw.hasSeenUpdateChangelog('/files', '1.2.3:10'), true);
  assert.equal(gw.hasSeenUpdateChangelog('/files', '1.2.4:11'), false);

  assert.equal(gw.isWelcomeAcknowledged('/files'), false);
  assert.equal(gw.acknowledgeWelcome('/files'), true);
  assert.equal(gw.isWelcomeAcknowledged('/files'), true);

  assert.equal(gw.loadGlowLevel('/files', 3), 3);
  assert.equal(gw.saveGlowLevel('/files', 2), true);
  assert.equal(gw.loadGlowLevel('/files', 3), 2);

  assert.deepEqual(JSON.parse(JSON.stringify(gw.loadAppearanceOverlay('/files'))), {
    backgroundUri: '',
    immersiveColorEnabled: false
  });
  assert.equal(gw.saveBackgroundImageUri('/files', 'file:///files/bg.png'), true);
  assert.equal(gw.saveImmersiveColorEnabled('/files', true), true);
  assert.deepEqual(JSON.parse(JSON.stringify(gw.loadAppearanceOverlay('/files'))), {
    backgroundUri: 'file:///files/bg.png',
    immersiveColorEnabled: true
  });
  assert.equal([...mem.files.keys()].some(k => k.endsWith('.pending') || k.endsWith('.tmp')), false);
});
