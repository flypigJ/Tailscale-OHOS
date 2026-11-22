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

const official = 'https://controlplane.tailscale.com';
const custom = 'https://headscale.example.invalid';
function fixture(initial = official) {
  const files = new Map([['/files/control-server.json', JSON.stringify({ controlURL: initial, confirmed: true, updatedAtMs: 1 })]]);
  let failRename = false, shortWrite = false;
  const io = {
    OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
    accessSync: p => files.has(p),
    readTextSync: p => { if (!files.has(p)) throw Error('missing'); return files.get(p); },
    statSync: p => { if (!files.has(p)) throw Error('missing'); return { size: Buffer.byteLength(files.get(p)) }; },
    mkdirSync: p => files.set(p, ''),
    openSync: p => { files.set(p, ''); return { fd: p }; },
    writeSync: (p, text) => { files.set(p, text); return Buffer.byteLength(text) - (shortWrite ? 1 : 0); },
    fsyncSync() {}, closeSync() {}, unlinkSync: p => files.delete(p),
    renameSync: (a, b) => { if (failRename) throw Error('disk'); files.set(b, files.get(a)); files.delete(a); }
  };
  const scope = { fileIo: io };
  loadEtsModules(['services/AtomicFileStore', 'services/ControlServerConfig', 'services/ControlServerPresets'], scope, { presets: 'ControlServerPresets' });
  return { files, p: scope.presets, fail: () => { failRename = true; }, short: () => { shortWrite = true; } };
}
test('legacy cache stays with the initial server across switching and restart', () => {
  const f = fixture(custom);
  const first = f.p.ensure('/files', custom);
  assert.equal(first.servers.length, 2);
  assert.equal(f.p.root('/files', '/cache', custom), '/cache');
  const other = f.p.root('/files', '/cache', official);
  assert.equal(other, '/cache/control-server-data/server-2');
  f.files.set('/files/control-server.json', JSON.stringify({controlURL:official,confirmed:true}));
  f.p.ensure('/files', official);
  assert.equal(f.p.root('/files', '/cache', custom), '/cache');
  assert.equal(f.p.root('/files', '/cache', official), other);
});
test('normalized duplicates retain stable ids; invalid URL creates no preset', () => {
  const f = fixture(); f.p.ensure('/files', custom);
  assert.equal(f.p.ensure('/files', custom + '///').servers.length, 2);
  assert.equal(f.p.ensure('/files', 'https://secret@host'), undefined);
  assert.equal(f.p.read('/files').servers.length, 2);
});
test('corrupt metadata fails closed without assigning old cache to another server', () => {
  const f = fixture(); f.files.set('/files/control-server-presets-v1.json', '{bad');
  assert.equal(f.p.ensure('/files', custom), undefined);
  assert.throws(() => f.p.root('/files', '/cache', custom), /unavailable/);
  assert.equal(f.files.get('/files/control-server-presets-v1.json'), '{bad');
});
for (const mode of ['fail', 'short']) test(`${mode} write preserves the prior catalog`, () => {
  const f = fixture(); f.p.ensure('/files', official);
  const prior = f.files.get('/files/control-server-presets-v1.json'); f[mode]();
  assert.equal(f.p.ensure('/files', custom), undefined);
  assert.equal(f.files.get('/files/control-server-presets-v1.json'), prior);
  assert.equal(f.files.has('/files/control-server-presets-v1.json.tmp'), false);
  assert.equal([...f.files.keys()].some(k => k.endsWith('.tmp')), false);
});
test('Unicode URL round trips with byte-accurate atomic writes', () => {
  const f = fixture(); const url = 'https://example.invalid/服务器';
  assert.ok(f.p.ensure('/files', url));
  assert.equal(f.p.read('/files').servers[1].controlURL, url);
});

function controller() {
  const events = []; let resolveStop;
  const f = fixture(official);
  const scope = {
    fileIo: f.files ? {
      OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
      accessSync: p => f.files.has(p),
      readTextSync: p => { if (!f.files.has(p)) throw Error('missing'); return f.files.get(p); },
      statSync: p => { if (!f.files.has(p)) throw Error('missing'); return { size: Buffer.byteLength(f.files.get(p)) }; },
      mkdirSync: p => f.files.set(p, ''),
      openSync: p => { f.files.set(p, ''); return { fd: p }; },
      writeSync: (p, text) => { f.files.set(p, text); return Buffer.byteLength(text); },
      fsyncSync() {}, closeSync() {}, unlinkSync: p => f.files.delete(p),
      renameSync: (a, b) => { f.files.set(b, f.files.get(a)); f.files.delete(a); }
    } : {},
    nativeBridge: {}, vpnExtension: {}, connection: {}, setTimeout, clearTimeout
  };
  loadVpnSessionController(scope);
  scope.ControlServerPresets.ensure('/files', official);
  scope.AccountProfiles.ensure('/files', official);
  const state = {
    lifecycleGeneration: 1, controlServerURL: official, controlServerConfirmed: true,
    controlServerSwitching: false, controlServerStatus: '', accountProfileId: 'default', accountProfiles: [],
    confirmControlServer: (url) => { events.push('save'); return { controlURL: url, confirmed: true, updatedAtMs: 2 }; }
  };
  const host = {
    getFilesDir: () => '/files', getCacheDir: () => '/cache', getLifecycleGeneration: () => state.lifecycleGeneration,
    isAppShellReady: () => true, isAppLockRequired: () => false, isLogoutInProgress: () => false,
    isDiagnosticActionInProgress: () => false, isCacheClearInProgress: () => false,
    isTaildropSendActive: () => false, isTaildropReceiveInProgress: () => false,
    isTaildropMediaSaveInProgress: () => false, shouldPollHealthFast: () => false,
    getBackendStatus: () => 'OK', setBackendStatus() {}, getVpnStatus: () => 'Stopped', setVpnStatus() {},
    isBackendReady: () => true, setBackendReady() {}, isBackendInitializationVisible: () => false, setBackendInitializationVisible() {},
    setDevicesLoading() {}, hasAuthenticatedSession: () => false, setHasAuthenticatedSession() {},
    isConnectInProgress: () => false, setConnectInProgressState() {}, isDisconnectInProgress: () => false, setDisconnectInProgress() {},
    isLoginInProgress: () => false, setLoginInProgress() {}, getLoginHandoffStatus: () => '', setLoginHandoffStatus() {},
    setLoginPromptKind() {}, isAuthKeyLoginVisible: () => false, setAuthKeyLoginVisible() {},
    getAuthKeyInput: () => '', setAuthKeyInput() {}, getAuthKeyStatus: () => '', setAuthKeyStatus() {},
    isControlServerConfirmed: () => state.controlServerConfirmed, setControlServerConfirmed: v => { state.controlServerConfirmed = v; },
    getControlServerURL: () => state.controlServerURL, setControlServerURL: u => { state.controlServerURL = u; },
    setControlServerInput() {}, setControlServerStatus: s => { state.controlServerStatus = s; },
    setControlServerEditorVisible() {}, setControlServerPresets() {},
    isControlServerSwitching: () => state.controlServerSwitching, setControlServerSwitching: v => { state.controlServerSwitching = v; },
    getAccountProfileId: () => state.accountProfileId, setAccountProfileId: id => { state.accountProfileId = id; },
    getAccountProfiles: () => state.accountProfiles, setAccountProfiles: p => { state.accountProfiles = p; },
    setAccountProfileStatus() {}, getPeers: () => [], onPeersUpdated() {}, onPeerPresenceInvalidated() {},
    setMeshArcReceiver() {}, setAccountSummary() {}, setAvatarLoadFailed() {}, getExitNodes: () => [], setExitNodes() {},
    isExitNodeUpdateInProgress: () => false, setExitNodeUpdateInProgress() {}, isExitNodeStatusFailed: () => false,
    setExitNodeNoneStatus() {}, setExitNodeSelectedStatus() {}, setExitNodeUnavailableStatus() {}, setExitNodeRawStatus() {},
    getNetworkSettings: () => ({ routeAll: true, exitNodeAllowLANAccess: false }), setNetworkSettings() {}, setNetworkSettingStatus() {},
    isRouteAllUpdateInProgress: () => false, setRouteAllUpdateInProgress() {}, isExitNodeLanUpdateInProgress: () => false,
    setExitNodeLanUpdateInProgress() {}, setTrafficDownloadBytes() {}, setTrafficUploadBytes() {},
    setTrafficDownloadRate() {}, setTrafficUploadRate() {}, getTrafficSamples: () => [], setTrafficSamples() {},
    isVpnConflictDialogVisible: () => false, setVpnConflictDialogVisible() {}, showVpnConflictAlertDialog() {},
    syncHomeTitleCompact() {}, setHomeTitleCompact() {}, deviceModel: () => 'Test', harmonyOSHostinfoVersion: () => '6.0',
    openControlServerSettings() {}, openSecureLoginBrowser: async () => {},
    confirmControlServerSelection: url => state.confirmControlServer(url),
    invalidateAccountGuard() {}, clearControlServerShellState: () => events.push('clear'),
    reloadTaildropStorageForActiveIdentity() {}, resetTaildropSnapshot() {}, applyBackendTaildropSnapshot() {},
    onLiveExtensionTick() {}, resetStreamingStatesForDisconnect() {}, autoProbeConnectedPeerServices() {},
    syncOfflinePeerStatusRefreshPolling() {}, syncWindowPrivacyMode() {}, logServiceStatusIfChanged() {},
    scheduleLifecycleTask: () => -1, recordDiagnosticEvent() {}
  };
  const c = new scope.VpnSessionController(host, {
    vpnCommandGateway: { stopBackend: () => { events.push('stop'); return new Promise(r => { resolveStop = r; }); } },
    vpnAutoRecovery: { cancel() {}, save() {}, wanted: () => false, armed: () => false }
  });
  c.startBackend = () => events.push(`start:${state.controlServerURL}`);
  return { c, state, events, stop: value => resolveStop(value) };
}
test('switch commits only after stop, blocks duplicates, clears before new start', async () => {
  const f=controller(); f.c.persistControlServer(custom); const task=f.c.backendRestartPromise;
  f.c.persistControlServer('https://second.invalid'); assert.deepEqual(f.events,['stop']);
  assert.equal(f.state.controlServerURL,official); f.stop('OK'); await task; await Promise.resolve();
  assert.deepEqual(f.events,['stop','save','clear',`start:${custom}`]);
  assert.equal(f.state.controlServerSwitching,false);
});
test('failed stop never commits another server', async () => {
  const f=controller(); const task=f.c.switchControlServer(custom);f.stop('FAILED');await task;
  assert.equal(f.state.controlServerURL,official);assert.deepEqual(f.events,['stop']);
});
test('failed active selection save restarts the original identity', async () => {
  const f=controller(); f.state.confirmControlServer=()=>undefined;
  const task=f.c.switchControlServer(custom);f.stop('OK');await task;
  assert.equal(f.state.controlServerURL,official);assert.deepEqual(f.events,['stop',`start:${official}`]);
});
test('disposed controller cannot commit a late stop', async () => {
  const f=controller();const task=f.c.switchControlServer(custom);f.state.lifecycleGeneration++;f.stop('OK');await task;
  assert.deepEqual(f.events,['stop']);assert.equal(f.state.controlServerURL,official);
});

function fileGateway() {
  let settings={controlURL:official,updatedAtMs:1}; const writes=[]; let poll;
  const scope={AccountProfiles:{token:()=> 'default:0'},ControlServerConfig:{load:()=>settings},fileIo:{},setTimeout:fn=>{poll=fn;}};
  loadEtsModules(['services/AtomicFileStore', 'services/VpnExtensionRpcChannel', 'services/TaildriveGateway'], scope, { G: 'TaildriveGateway' });
  const g=new scope.G();g.configure({filesDir:'/files'});
  g.writeText=(path,text)=>{writes.push({path,text});return true;};
  return {g,writes,change:()=>{settings={controlURL:custom,updatedAtMs:2};},
    back:()=>{settings={controlURL:official,updatedAtMs:3};},poll:()=>poll()};
}
test('queued old-server mutation never writes into a new session channel', async () => {
  const f=fileGateway();let release;f.g.queryQueue=new Promise(r=>{release=r;});
  const pending=f.g.mutate({operation:'delete',path:'/old-server-file'});
  f.change();release();await assert.rejects(pending,/not configured/);assert.equal(f.writes.length,0);
});
test('old response cannot be accepted after switching away and back', async () => {
  const f=fileGateway();const pending=f.g.performVpnExtensionRequest('query','list','/',10000);
  const writes=f.writes.length;f.change();f.back();f.poll();
  await assert.rejects(pending,/server changed/);assert.equal(f.writes.length,writes);
});
