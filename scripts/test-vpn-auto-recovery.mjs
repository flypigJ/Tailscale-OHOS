import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';
import { loadEtsModules, readEtsSource } from './helpers/ets-vm-loader.mjs';

// Only platform boundaries are fake. Policy and controller come from production modules.
const atomicSource = readFileSync(new URL('../entry/src/main/ets/services/AtomicFileStore.ets', import.meta.url), 'utf8');
const policySource = readFileSync(new URL('../entry/src/main/ets/services/VpnAutoRecovery.ets', import.meta.url), 'utf8');
const extensionSource = readFileSync(new URL('../entry/src/main/ets/vpnextensionability/TailscaleVpnExtensionAbility.ets', import.meta.url), 'utf8');
const clean = source => stripTypeScriptTypes(source.replace(/^import .*;\r?$/gm, '').replace(/^export /gm, ''));
function method(source, name) {
  const match = new RegExp('^  (?:private )?(?:async )?' + name + '\\(', 'm').exec(source);
  assert.ok(match, 'production method ' + name);
  const end = source.indexOf('\n  }', match.index);
  assert.ok(end >= 0, name + ' closing brace');
  return source.slice(match.index, end + 4);
}
function loadVpnSessionController(scope) {
  loadEtsModules([
    'services/DiagnosticPrivacy',
    'services/ControlServerConfig',
    'services/ControlServerPresets',
    'services/AccountProfiles',
    'services/DeviceNameService',
    'services/AuthKeyLogin',
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
const flush = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
function deferred() {
  let resolve, reject;
  const promise = new Promise((a, b) => { resolve = a; reject = b; });
  return { promise, resolve, reject };
}
function fixture() {
  const f = {
    now: 1000000, files: new Map(), writes: [], timers: new Map(), timerId: 0,
    callbacks: [], observerOffs: 0, observerCreates: 0, nets: [{ netId: 1 }], caps: { bearerTypes: [1] },
    getNetsCalls: 0, capsCalls: 0, netGate: null, capsGate: null, queryError: null,
    ioError: false, polls: 0, starts: [], activeCommand: 0, events: []
  };
  const sandbox = {
    Date: { now: () => f.now }, console,
    setTimeout: (cb, ms) => { const id = ++f.timerId; f.timers.set(id, { cb, at: f.now + ms }); return id; },
    clearTimeout: id => f.timers.delete(id),
    fileIo: {
      OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
      statSync: path => { if (!f.files.has(path)) throw Error('missing'); return { size: Buffer.byteLength(f.files.get(path)) }; },
      readTextSync: path => { if (!f.files.has(path)) throw Error('missing'); return f.files.get(path); },
      openSync: path => { if (f.ioError) throw Error('I/O'); f.writes.push(['open', path]); f.files.set(path, ''); return { fd: path }; },
      writeSync: (fd, text) => { f.files.set(fd, text); f.writes.push(['write', fd]); return Buffer.byteLength(text); },
      fsyncSync: () => {},
      unlinkSync: path => { f.files.delete(path); },
      closeSync: () => {},
      renameSync: (from, to) => { f.files.set(to, f.files.get(from)); f.files.delete(from); f.writes.push(['rename', to]); }
    },
    connection: {
      NetBearType: { BEARER_CELLULAR: 0, BEARER_WIFI: 1, BEARER_VPN: 4, BEARER_ETHERNET: 3 },
      getAllNets: async () => { f.getNetsCalls++; if (f.netGate) await f.netGate.promise; if (f.queryError) throw f.queryError; return f.nets; },
      getNetCapabilities: async net => { f.capsCalls++; if (f.capsGate) await f.capsGate.promise; if (f.caps instanceof Error) throw f.caps; return typeof f.caps === 'function' ? f.caps(net) : f.caps; }
    },
    vpnExtension: {
      createVpnObserver: () => { f.observerCreates++; return {
        onAuthorizationResult: cb => f.callbacks.push(cb),
        offAuthorizationResult: () => { f.observerOffs++; }
      }; },
      stopVpnExtensionAbility: async () => { f.extensionStops = (f.extensionStops ?? 0) + 1; }
    },
    VpnCoreCommand: { CONNECT: 'connect' }, VpnCommandState: { STOPPED: 'stopped', NEEDS_LOGIN: 'needsLogin' }
  };
  vm.runInNewContext(clean(atomicSource) + '\n' + clean(policySource) + '\nglobalThis.Policy = VpnAutoRecovery;', sandbox);
  f.Policy = sandbox.Policy; f.policy = new sandbox.Policy(); f.sandbox = sandbox;
  f.intentFile = '/files/vpn-connect-intent.json';
  f.writeIntent = value => f.files.set(f.intentFile, typeof value === 'string' ? value : JSON.stringify(value));
  f.advance = async ms => {
    f.now += ms;
    for (const [id, item] of [...f.timers]) if (item.at <= f.now) { f.timers.delete(id); item.cb(); }
    await flush();
  };
  f.arm = () => { f.policy.request(f.now); assert.equal(f.policy.connected(f.now, f.now), true); f.policy.save('/files'); };
  return f;
}
function controllerFixture() {
  const f = fixture();
  loadVpnSessionController(f.sandbox);
  const state = {
    lifecycleGeneration: 1,
    appShellReady: true,
    hasAuthenticatedSession: true,
    controlServerConfirmed: true,
    connectInProgress: false,
    disconnectInProgress: false,
    loginInProgress: false,
    logoutInProgress: false,
    diagnosticActionInProgress: false,
    controlServerSwitching: false,
    backendStatus: 'Running',
    vpnStatus: ''
  };
  const host = {
    getFilesDir: () => '/files',
    getCacheDir: () => '/cache',
    getLifecycleGeneration: () => state.lifecycleGeneration,
    isAppShellReady: () => state.appShellReady,
    isAppLockRequired: () => false,
    isLogoutInProgress: () => state.logoutInProgress,
    isDiagnosticActionInProgress: () => state.diagnosticActionInProgress,
    isCacheClearInProgress: () => false,
    isTaildropSendActive: () => false,
    isTaildropReceiveInProgress: () => false,
    isTaildropMediaSaveInProgress: () => false,
    shouldPollHealthFast: () => false,
    getBackendStatus: () => state.backendStatus,
    setBackendStatus: s => { state.backendStatus = s; },
    getVpnStatus: () => state.vpnStatus,
    setVpnStatus: s => { state.vpnStatus = s; },
    isBackendReady: () => true,
    setBackendReady() {},
    isBackendInitializationVisible: () => false,
    setBackendInitializationVisible() {},
    setDevicesLoading() {},
    hasAuthenticatedSession: () => state.hasAuthenticatedSession,
    setHasAuthenticatedSession: v => { state.hasAuthenticatedSession = v; },
    isConnectInProgress: () => state.connectInProgress,
    setConnectInProgressState: value => { state.connectInProgress = value; },
    isDisconnectInProgress: () => state.disconnectInProgress,
    setDisconnectInProgress: value => { state.disconnectInProgress = value; },
    isLoginInProgress: () => state.loginInProgress,
    setLoginInProgress: value => { state.loginInProgress = value; },
    getLoginHandoffStatus: () => '',
    setLoginHandoffStatus() {},
    setLoginPromptKind() {},
    isAuthKeyLoginVisible: () => false,
    setAuthKeyLoginVisible() {},
    getAuthKeyInput: () => '',
    setAuthKeyInput() {},
    getAuthKeyStatus: () => '',
    setAuthKeyStatus() {},
    isControlServerConfirmed: () => state.controlServerConfirmed,
    setControlServerConfirmed: v => { state.controlServerConfirmed = v; },
    getControlServerURL: () => 'https://controlplane.tailscale.com',
    setControlServerURL() {},
    setControlServerInput() {},
    setControlServerStatus() {},
    setControlServerEditorVisible() {},
    setControlServerPresets() {},
    isControlServerSwitching: () => state.controlServerSwitching,
    setControlServerSwitching: v => { state.controlServerSwitching = v; },
    getAccountProfileId: () => 'default',
    setAccountProfileId() {},
    getAccountProfiles: () => [],
    setAccountProfiles() {},
    setAccountProfileStatus() {},
    getPeers: () => [],
    onPeersUpdated() {},
    onPeerPresenceInvalidated() {},
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
    openControlServerSettings: () => { throw Error('unexpected settings'); },
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
    recordDiagnosticEvent: (...args) => f.events.push(args)
  };
  const vpnCommandStateMachine = {
    begin: () => { f.activeCommand++; return f.activeCommand; },
    complete: id => { if (f.activeCommand === id) f.activeCommand = 0; },
    isActive: id => f.activeCommand === id && id > 0,
    timeout: id => { if (f.activeCommand === id) f.activeCommand = 0; }
  };
  const vpnCommandGateway = {
    startVpnExtension: async want => {
      f.startedWant = want;
      if (f.startGate) await f.startGate.promise;
      if (f.startError) throw f.startError;
    }
  };
  const c = new f.sandbox.VpnSessionController(host, {
    vpnAutoRecovery: f.policy,
    vpnCommandStateMachine,
    vpnCommandGateway,
    systemVpnAbsent: () => f.Policy.systemVpnAbsent()
  });
  c.lastConfirmedVpnHeartbeatMs = f.now;
  c.refreshVpnProbeStatus = () => !!f.live;
  c.isConnecting = () => false;
  c.beginVpnConnectionAfterExitNodeUpdate = async () => { f.starts.push('normal-preflight'); };
  c.clearVpnBackendHandoffFiles = () => {};
  c.clearConnectionCompletionTimer = () => {};
  c.startConnectionPolling = () => { f.polls++; };
  c.refreshBackendStatus = async () => { f.uiBackendReads = (f.uiBackendReads ?? 0) + 1; };
  c.startBackend = () => { f.uiBackendStarts = (f.uiBackendStarts ?? 0) + 1; };
  c.tryFastReconnect = () => false;
  c.backendVpnConfigWithRecovery = async () => 'FAILED | no login';
  for (const key of Object.keys(state)) {
    Object.defineProperty(c, key, {
      get: () => state[key],
      set: v => { state[key] = v; },
      configurable: true
    });
  }
  f.c = c;
  f.host = host;
  f.state = state;
  f.observeMissing = async () => {
    f.now += 15000; await c.maybeAutoReconnectVpn(1);
    f.now += 15000;
  };
  return f;
}

test('no explicit intent and an unconnected first request cannot auto-reconnect', () => {
  const f = fixture();
  assert.equal(f.policy.takeAttempt(0, true, f.now), false);
  f.policy.request(f.now);
  assert.equal(f.policy.wanted(), true);
  assert.equal(f.policy.takeAttempt(0, true, f.now + 900000), false);
});
test('only a current nonfuture connection heartbeat arms the requested intent', () => {
  const f = fixture(); f.policy.request(f.now);
  assert.equal(f.policy.connected(f.now - 1, f.now), false);
  assert.equal(f.policy.connected(f.now + 1, f.now), false);
  assert.equal(f.policy.connected(f.now, f.now), true);
  assert.equal(f.policy.connected(f.now, f.now), false);
});
test('same-clock new request advances token and invalidates the cancelled old intent', () => {
  const f = fixture(); f.arm(); const old = f.policy.token();
  f.policy.cancel(); assert.equal(f.policy.current(old), false);
  f.policy.request(f.now); assert.equal(f.policy.token(), old + 1);
  assert.equal(f.policy.current(old), false);
});
test('intent persistence atomically renames a temporary file and reports write failure', () => {
  const f = fixture(); f.arm();
  assert.equal(f.writes.at(-1)[0], 'rename');
  assert.equal(f.files.has(f.intentFile + '.tmp'), false);
  assert.equal([...f.files.keys()].some(k => k.endsWith('.tmp')), false);
  const previous = f.files.get(f.intentFile); f.ioError = true;
  assert.equal(f.policy.save('/files'), false);
  assert.equal(f.files.get(f.intentFile), previous);
});
test('restore accepts a previously armed intent but never a pending first connection', () => {
  const f = fixture(); f.arm();
  const restored = new f.Policy(); restored.restore('/files');
  assert.equal(restored.wanted(), true);
  f.policy.request(f.now + 1); f.policy.save('/files'); restored.cancel(); restored.restore('/files');
  assert.equal(restored.wanted(), false);
});
for (const [name, value] of [
  ['absent', undefined], ['malformed', '{'], ['oversize', 'x'.repeat(1025)],
  ['cancelled', { desired: false, requestedAtMs: 1, connectedAtMs: 2 }],
  ['future', { desired: true, requestedAtMs: 1000001, connectedAtMs: 1000002 }],
  ['unconfirmed', { desired: true, requestedAtMs: 100, connectedAtMs: 0 }],
  ['old connection', { desired: true, requestedAtMs: 100, connectedAtMs: 99 }]
]) test('restore does not enable recovery for ' + name + ' intent', () => {
  const f = fixture(); if (value !== undefined) f.writeIntent(value);
  f.policy.restore('/files'); assert.equal(f.policy.wanted(), false);
});
test('extension launch requires the current persisted token and desired flag', () => {
  const f = fixture(); f.policy.request(f.now); f.policy.save('/files'); const old = f.policy.token();
  assert.equal(f.Policy.permitsStart('/files', old), true);
  f.policy.cancel(); f.policy.save('/files'); assert.equal(f.Policy.permitsStart('/files', old), false);
  f.policy.request(f.now + 1); f.now++; f.policy.save('/files');
  assert.equal(f.Policy.permitsStart('/files', old), false);
  assert.equal(f.Policy.permitsStart('/files', f.policy.token()), true);
});
test('recovery needs both a stale heartbeat and fifteen continuous seconds of confirmed absence', () => {
  const f = fixture(); f.arm();
  assert.equal(f.policy.takeAttempt(f.now, true, f.now + 14999), false);
  assert.equal(f.policy.takeAttempt(f.now, true, f.now + 15000), false);
  assert.equal(f.policy.takeAttempt(f.now, true, f.now + 29999), false);
  assert.equal(f.policy.takeAttempt(f.now, true, f.now + 30000), true);
});
test('an existing or unknown VPN resets the continuous absence window', () => {
  const f = fixture(); f.arm(); const hb = f.now;
  assert.equal(f.policy.takeAttempt(hb, true, hb + 15000), false);
  assert.equal(f.policy.takeAttempt(hb, false, hb + 29999), false);
  assert.equal(f.policy.takeAttempt(hb, true, hb + 30000), false);
  assert.equal(f.policy.takeAttempt(hb, true, hb + 44999), false);
  assert.equal(f.policy.takeAttempt(hb, true, hb + 45000), true);
});
test('five attempts honor 15/30/60/120/300-second waits and then stop', () => {
  const f = fixture(); f.arm(); const hb = f.now;
  f.now += 15000; assert.equal(f.policy.takeAttempt(hb, true, f.now), false);
  for (const delay of [15000, 30000, 60000, 120000, 300000]) {
    assert.equal(f.policy.takeAttempt(hb, true, f.now + delay - 1), false, 'must wait ' + delay);
    f.now += delay; assert.equal(f.policy.takeAttempt(hb, true, f.now), true);
  }
  assert.equal(f.policy.takeAttempt(hb, true, f.now + 900000), false);
});
test('a single recovered heartbeat does not reset budget; thirty stable seconds do', () => {
  const f = fixture(); f.arm(); const hb = f.now;
  f.policy.takeAttempt(hb, true, hb + 15000);
  let now = hb + 30000; assert.equal(f.policy.takeAttempt(hb, true, now), true);
  f.policy.connected(now, now);
  f.policy.takeAttempt(hb, true, now + 1);
  assert.equal(f.policy.takeAttempt(hb, true, now + 15001), false);
  now += 300000; f.policy.connected(now, now); f.policy.connected(now + 29999, now + 29999);
  assert.equal(f.policy.attempts, 1);
  f.policy.connected(now + 30000, now + 30000);
  assert.equal(f.policy.attempts, 0);
});
test('system query confirms absence only after every listed network has known non-VPN capabilities', async () => {
  const f = fixture(); f.nets = [{ netId: 1 }, { netId: 2 }];
  assert.equal(await f.Policy.systemVpnAbsent(), true); assert.equal(f.capsCalls, 2);
  f.caps = net => ({ bearerTypes: [net.netId === 2 ? 4 : 1] });
  assert.equal(await f.Policy.systemVpnAbsent(), false);
});
for (const [name, configure] of [
  ['empty network list', f => { f.nets = []; }],
  ['oversized network list', f => { f.nets = Array.from({ length: 33 }, (_, netId) => ({ netId })); }],
  ['network query rejection', f => { f.queryError = Error('denied'); }],
  ['capability rejection', f => { f.caps = Error('denied'); }],
  ['missing bearer list', f => { f.caps = {}; }],
  ['empty bearer list', f => { f.caps = { bearerTypes: [] }; }]
]) test('unknown system state never authorizes recovery: ' + name, async () => {
  const f = fixture(); configure(f); assert.equal(await f.Policy.systemVpnAbsent(), false);
});
for (const gate of ['netGate', 'capsGate']) test('delayed ' + gate + ' times out without late authorization', async () => {
  const f = fixture(); f[gate] = deferred(); let result;
  const pending = f.Policy.systemVpnAbsent().then(value => { result = value; });
  await flush(); await f.advance(2000); await pending; assert.equal(result, false);
  f[gate].resolve(); await flush(); assert.equal(result, false);
});
test('authorization watchers ignore removed and replaced observer callbacks', () => {
  const f = fixture(); let denies = 0;
  f.policy.watchAuthorization(() => denies++); const old = f.callbacks.at(-1);
  f.policy.watchAuthorization(() => denies++); const current = f.callbacks.at(-1);
  old(false); assert.equal(denies, 0); current(true); assert.equal(denies, 0);
  current(false); assert.equal(denies, 1);
  f.policy.stopObservingAuthorization(); current(false); assert.equal(denies, 1);
});

test('authorization observer is retained across repeated connection and cancellation cycles', () => {
  const f = fixture();
  for (let i = 0; i < 20; i++) {
    f.policy.watchAuthorization(() => assert.fail('removed callback'));
    f.policy.stopObservingAuthorization();
  }
  for (const callback of f.callbacks) callback(false);
  assert.equal(f.observerCreates, 1);
  assert.equal(f.observerOffs, 20);
});

test('a retired component cannot unregister the current owner of the shared native observer', () => {
  const f = fixture();
  const next = new f.Policy();
  let denied = 0;
  f.policy.watchAuthorization(() => assert.fail('old component callback'));
  const old = f.callbacks.at(-1);
  next.watchAuthorization(() => denied++);
  const current = f.callbacks.at(-1);
  const offs = f.observerOffs;
  f.policy.stopObservingAuthorization();
  assert.equal(f.observerOffs, offs);
  old(false);
  current(false);
  assert.equal(denied, 1);
  assert.equal(f.observerCreates, 1);
  next.stopObservingAuthorization();
  current(false);
  assert.equal(denied, 1);
});
test('armed controller suppresses UI backend fallback when absence is unknown', async () => {
  const f = controllerFixture(); f.arm(); f.caps = Error('unknown');
  await f.c.refreshOrRecoverBackend(1);
  assert.equal(f.uiBackendReads ?? 0, 0); assert.equal(f.uiBackendStarts ?? 0, 0);
  assert.equal(f.starts.length, 0);
});
test('recovery reuses the real normal connection preflight without creating a new intent', async () => {
  const f = controllerFixture(); f.arm(); const token = f.policy.token(); await f.observeMissing();
  await f.c.maybeAutoReconnectVpn(1); await flush();
  assert.deepEqual(f.starts, ['normal-preflight']); assert.equal(f.policy.token(), token);
  assert.ok(f.c.vpnAutoRecoveryCommandId > 0);
});
for (const change of ['cancel', 'new-intent', 'lifecycle', 'live', 'disconnect']) {
  test('async system query cannot start after ' + change, async () => {
    const f = controllerFixture(); f.arm(); await f.observeMissing();
    f.netGate = deferred(); const pending = f.c.maybeAutoReconnectVpn(1); await flush();
    if (change === 'cancel') f.c.cancelVpnAutoRecovery();
    if (change === 'new-intent') f.policy.request(f.now);
    if (change === 'lifecycle') f.c.lifecycleGeneration++;
    if (change === 'live') f.live = true;
    if (change === 'disconnect') f.c.disconnectInProgress = true;
    f.netGate.resolve(); await pending; assert.equal(f.starts.length, 0);
    if (change === 'cancel') assert.equal(JSON.parse(f.files.get(f.intentFile)).desired, false);
  });
}
test('overlapping health checks share the in-flight system query', async () => {
  const f = controllerFixture(); f.arm(); f.netGate = deferred();
  const first = f.c.maybeAutoReconnectVpn(1); await flush();
  assert.equal(await f.c.maybeAutoReconnectVpn(1), true);
  assert.equal(f.getNetsCalls, 1);
  f.netGate.resolve(); await first; assert.equal(f.c.vpnAutoRecoveryInFlight, false);
});
test('real start request carries the intent token; denied authorization cancels persisted intent', async () => {
  const f = controllerFixture(); f.arm(); f.activeCommand = 1; f.c.connectCommandId = 1; f.startGate = deferred();
  f.c.requestVpnExtensionStart(1);
  assert.equal(f.startedWant.parameters.mesharcIntentMs, f.policy.token());
  f.callbacks.at(-1)(false);
  assert.equal(f.policy.wanted(), false);
  assert.equal(JSON.parse(f.files.get(f.intentFile)).desired, false);
  f.startGate.resolve(); await flush(); assert.equal(f.polls, 0);
});
test('old denied authorization callback cannot cancel a replacement start', async () => {
  const f = controllerFixture(); f.arm(); f.activeCommand = 1; f.c.requestVpnExtensionStart(1); const old = f.callbacks.at(-1);
  f.policy.request(f.now + 1); f.now++; f.activeCommand = 2; f.c.requestVpnExtensionStart(2);
  old(false); assert.equal(f.policy.wanted(), true); assert.equal(f.activeCommand, 2);
  await flush();
});
for (const [name, automatic, code, retained] of [
  ['automatic transient', true, 500, true], ['automatic denied', true, 201, false],
  ['automatic invalid authorization', true, 2203001, false], ['manual failure', false, 500, false]
]) test(name + ' start failure handles recovery intent', async () => {
  const f = controllerFixture(); f.arm(); f.activeCommand = 1;
  f.c.vpnAutoRecoveryCommandId = automatic ? 1 : 0; f.startError = { code };
  f.c.requestVpnExtensionStart(1); await flush(); assert.equal(f.policy.wanted(), retained);
  assert.equal(f.activeCommand, 0);
});
test('real preflight login failure cancels automatic recovery', async () => {
  const f = controllerFixture(); f.arm(); f.activeCommand = 1; f.c.connectCommandId = 1;
  await f.c.startVpnProbe(1);
  assert.equal(f.policy.wanted(), false); assert.equal(f.activeCommand, 0);
});
test('manual cancellation invalidates the extension startup guard before any TUN work', () => {
  const f = fixture(); f.arm(); const token = f.policy.token(); f.policy.cancel(); f.policy.save('/files');
  const methods = ['startupIntentAllowed', 'onCreate'].map(n => method(extensionSource, n)).join('\n');
  vm.runInNewContext(clean('class Extension {\n' + methods + '\n}') + '\nglobalThis.Extension = Extension;', f.sandbox);
  const e = new f.sandbox.Extension(); e.context = { filesDir: '/files' };
  e.recordDiagnosticEvent = () => { throw Error('cancelled start must not initialize'); };
  e.runtimeDiagnostic = { start() {} };
  e.onCreate({ parameters: { mesharcIntentMs: token } });
  assert.equal(e.destroying, true); assert.equal(f.extensionStops, 1);
});


function extensionFixture() {
  const f = fixture(); f.arm(); f.trace = []; f.gates = new Map(); f.statuses = [];
  f.dnsEnabled = false; f.dnsReads = 0; f.dnsMismatch = false; f.dnsStatus = [];
  f.profileToken = 'default:0'; f.nativeRoots = [];
  f.pause = async name => { f.trace.push(name); const gate = f.gates.get(name); if (gate) await gate.promise; };
  Object.assign(f.sandbox, {
    BUNDLE_NAME: 'test', DOMAIN: 1, TAG: 'test', VPN_EXISTS_ERROR_CODE: 2203002,
    ControlServerConfig: { load: () => ({ confirmed: true, controlURL: 'https://test.invalid' }) },
    ControlServerPresets: { ensure: () => ({ servers: [] }) },
    AccountProfiles: { token: () => f.profileToken },
    TailnetDnsPreferences: { enabled: () => f.dnsEnabled },
    DnsSettingsStore: {
      load: () => ({ enabled: !!f.customDnsEnabled, primary: '2001:db8::53', secondary: '', searchDomains: ['corp.test'] }),
      upstreams: settings => settings.enabled ? [settings.primary] : []
    },
    PhysicalDnsService: { read: async () => { await f.pause('dns-physical'); return { networkId: 1, resolvers: ['192.0.2.53'] }; } },
    DnsRuntimeService: {
      stage: async (...args) => { f.dnsStageArgs = args; if (f.dnsEnabled || f.customDnsEnabled) await f.pause('dns-stage'); },
      read: async () => {
        const count = ++f.dnsReads; await f.pause(count === 1 ? 'dns-first-plan' : 'dns-final-plan');
        return { schemaVersion: 1, session: (count === 1 ? 'a' : 'b').repeat(32), revision: 1, state: 'ready',
          dnsAddresses: ['100.100.100.100'], searchDomains: [count > 1 && f.dnsMismatch ? 'changed.test' : 'private.test'] };
      },
      sameConfiguration: (a,b) => JSON.stringify(a.dnsAddresses) === JSON.stringify(b.dnsAddresses) && JSON.stringify(a.searchDomains) === JSON.stringify(b.searchDomains)
    },
    hilog: { info() {}, error() {} },
    DiagnosticPrivacy: { classifyError: () => ({ code: -1 }) },
    nativeBridge: {
      tunFdProbe: () => 'OK',
      backendStart: () => { f.trace.push('dns-bootstrap-start'); return 'OK | state=Running'; },
      backendVpnConfigAsync: async () => '100.64.0.1|fd7a:115c:a1e0::1',
      backendRestartWithTunAsync: async root => { f.nativeRoots.push(root); await f.pause('restart'); return 'OK | state=Running'; },
      backendStopAsync: async () => { f.trace.push('native-stop'); return 'OK'; },
      backendPeerProbeAsync: async () => { await f.pause('peer'); return 'OK'; }
    }
  });
  const methods = ['startupIntentAllowed', 'createProbeTun', 'stopCancelledStartup',
    'finishDestroyedBackend', 'stopNativeBackend', 'finishNativeStop', 'waitForDnsSystemPlan'].map(n => method(extensionSource, n)).join('\n');
  vm.runInNewContext(clean('class Extension {\n' + methods + '\n}') + '\nglobalThis.Extension = Extension;', f.sandbox);
  const e = new f.sandbox.Extension();
  f.originalConnection = {
    destroy: async () => { f.trace.push('tun-destroy'); },
    protectProcessNet: async () => { await f.pause('protect'); }
  };
  Object.assign(e, {
    context: { filesDir: '/files' }, startupIntentMs: f.policy.token(),
    serverControlURL: 'https://test.invalid', serverProfileId: 'default',
    serverProfileToken: f.profileToken, serverStateRoot: '/files/tailscale',
    vpnConnection: f.originalConnection, tunFd: -1,
    destroying: false, explicitStopRequested: false, backendStopInFlight: false,
    dnsObserver: { stop() {} },
    writeDnsSystemStatus: (state,applied) => f.dnsStatus.push({state,applied}),
    recordDiagnosticEvent: (...args) => f.events.push(args),
    writeStatus: value => f.statuses.push(value), writeVpnConfigSummary: () => {},
    restoreBackendVpnConfig: async () => { await f.pause('restore'); return '100.64.0.1|fd7a:115c:a1e0::1'; },
    createTunWithConflictReplacement: async () => { await f.pause('create'); return 7; },
    requestUiBackendHandoff: async () => { await f.pause('handoff'); return 'OK'; },
    deviceModel: () => 'test', harmonyOSHostinfoVersion: () => 'test',
    waitForVpnBackend: async () => { await f.pause('wait'); return 'OK | state=Running'; },
    startStatusUpdates: () => f.trace.push('status-start'),
    networkMonitor: { start: () => f.trace.push('monitor-start') },
    writePeerStatus: () => f.trace.push('peer-status')
  });
  f.e = e;
  return f;
}
test('DNS-on compiles before TUN creation and verifies the new engine before marking applied', async () => {
  const f = extensionFixture(); f.dnsEnabled = true;
  await f.e.createProbeTun();
  assert.ok(f.trace.indexOf('handoff') < f.trace.indexOf('dns-bootstrap-start'));
  assert.ok(f.trace.indexOf('dns-first-plan') < f.trace.indexOf('create'));
  assert.ok(f.trace.indexOf('restart') < f.trace.indexOf('dns-final-plan'));
  assert.equal(f.trace.filter(x => x === 'handoff').length, 1);
  assert.equal(f.e.dnsSystemPlan.session, 'b'.repeat(32));
  assert.equal(f.dnsStatus.at(-1).applied, true);
});
test('DNS-on mismatched new-session plan destroys the new TUN and stops its backend', async () => {
  const f = extensionFixture(); f.dnsEnabled = true; f.dnsMismatch = true;
  await f.e.createProbeTun();
  assert.ok(f.trace.includes('tun-destroy')); assert.ok(f.trace.includes('native-stop'));
  assert.equal(f.trace.includes('status-start'), false); assert.equal(f.dnsStatus.at(-1).applied, false);
});

for (const tailnet of [false,true]) test('custom DNS uses the compiled lifecycle with Tailnet opt-in '+tailnet, async () => {
  const f=extensionFixture(); f.dnsEnabled=tailnet; f.customDnsEnabled=true;
  await f.e.createProbeTun();
  assert.deepEqual(JSON.parse(JSON.stringify(f.dnsStageArgs)),[tailnet,[],['2001:db8::53'],['corp.test']]);
  assert.equal(f.trace.includes('dns-physical'),false);
  assert.ok(f.trace.indexOf('dns-first-plan')<f.trace.indexOf('create'));
  assert.equal(f.dnsStatus.at(-1).applied,true);
  assert.equal(f.e.dnsSystemPlan.session,'b'.repeat(32));
});
for (const stage of ['dns-physical','dns-stage','dns-first-plan','dns-final-plan']) test('DNS startup cancellation at ' + stage + ' cannot publish applied or restart late', async () => {
  const f = extensionFixture(); f.dnsEnabled = true;
  const gate = deferred(); f.gates.set(stage,gate);
  const pending = f.e.createProbeTun(); await flush();
  for (let attempt = 0; attempt < 20 && !f.trace.includes(stage); attempt++) await flush();
  assert.ok(f.trace.includes(stage)); f.policy.cancel(); f.policy.save('/files'); gate.resolve();
  await pending; await flush();
  assert.equal(f.dnsStatus.some(s => s.applied), false);
  assert.ok(f.trace.includes('tun-destroy')); assert.ok(f.trace.includes('native-stop'));
  assert.equal(f.trace.includes('status-start'), false);
});
for (const stage of ['restore', 'create', 'protect', 'handoff', 'restart', 'wait', 'peer']) {
  test('cancelled extension startup cleans its TUN/backend after late ' + stage, async () => {
    const f = extensionFixture(); const gate = deferred(); f.gates.set(stage, gate);
    const pending = f.e.createProbeTun(); await flush();
    assert.ok(f.trace.includes(stage), 'reached real await boundary ' + stage);
    f.policy.cancel(); f.policy.save('/files');
    gate.resolve(); await pending; await flush();
    assert.equal(f.e.explicitStopRequested, true);
    assert.equal(f.e.tunFd, -1);
    assert.equal(f.trace.filter(x => x === 'tun-destroy').length, 1);
    assert.equal(f.trace.filter(x => x === 'native-stop').length, 1);
    assert.ok(f.trace.indexOf('tun-destroy') < f.trace.indexOf('native-stop'));
    assert.equal(f.extensionStops, 1);
    if (stage !== 'peer') assert.equal(f.trace.includes('status-start'), false);
    assert.equal(f.trace.includes('peer-status'), false);
  });
}
test('startup cleanup destroys its captured connection and is idempotent', async () => {
  const f = extensionFixture(); f.policy.cancel(); f.policy.save('/files');
  let unrelatedDestroyed = false;
  f.e.vpnConnection = { destroy: async () => { unrelatedDestroyed = true; } };
  assert.equal(await f.e.stopCancelledStartup(f.originalConnection), true);
  assert.equal(await f.e.stopCancelledStartup(f.originalConnection), true);
  assert.equal(unrelatedDestroyed, false);
  assert.equal(f.trace.filter(x => x === 'tun-destroy').length, 1);
  assert.equal(f.trace.filter(x => x === 'native-stop').length, 1);
});
test('startup cleanup releases TUN before awaiting an already queued native restart', async () => {
  const f = extensionFixture(); const gate = deferred(); f.e.backendRestartPromise = gate.promise;
  f.policy.cancel(); f.policy.save('/files');
  const pending = f.e.stopCancelledStartup(f.originalConnection); await flush();
  assert.ok(f.trace.includes('tun-destroy')); assert.equal(f.trace.includes('native-stop'), false);
  gate.resolve('OK'); await pending;
  assert.equal(f.trace.filter(x => x === 'native-stop').length, 1);
  assert.equal(f.extensionStops, 1);
});
test('an invalidated old token cannot continue when a new intent replaces it during startup', async () => {
  const f = extensionFixture(); const gate = deferred(); f.gates.set('protect', gate);
  const old = f.e.startupIntentMs;
  const pending = f.e.createProbeTun(); await flush();
  f.now++; f.policy.request(f.now); f.policy.save('/files');
  assert.notEqual(f.policy.token(), old);
  gate.resolve(); await pending;
  assert.equal(f.e.explicitStopRequested, true); assert.equal(f.trace.includes('status-start'), false);
  assert.equal(f.Policy.permitsStart('/files', f.policy.token()), true);
});


test('a completed transient start failure remains eligible through a backoff longer than the start watchdog', async () => {
  const f = controllerFixture(); f.arm(); f.activeCommand = 1;
  f.c.vpnAutoRecoveryCommandId = 1; f.c.vpnAutoRecoveryStartedAtMs = f.now;
  f.startError = { code: 500 }; f.c.requestVpnExtensionStart(1); await flush();
  assert.equal(f.activeCommand, 0); assert.equal(f.policy.wanted(), true);
  f.c.backendStatus = 'Running';
  f.c.vpnCommandStateMachine.timeout = id => { f.activeCommand = 0; f.timeouts = (f.timeouts ?? 0) + 1; };
  f.now += 90001; f.c.scheduleHealthPoll(1); await f.advance(1000);
  assert.equal(f.timeouts ?? 0, 0, 'finished command is not an outstanding authorization/start');
  assert.equal(f.policy.wanted(), true);
});
test('the start watchdog cancels a genuinely still-active automatic start after ninety seconds', async () => {
  const f = controllerFixture(); f.arm(); f.activeCommand = 1;
  f.c.vpnAutoRecoveryCommandId = 1; f.c.vpnAutoRecoveryStartedAtMs = f.now;
  f.c.backendStatus = 'Running';
  f.c.vpnCommandStateMachine.timeout = id => { assert.equal(id, 1); f.activeCommand = 0; f.timeouts = (f.timeouts ?? 0) + 1; };
  f.now += 90001; f.c.scheduleHealthPoll(1); await f.advance(1000);
  assert.equal(f.timeouts, 1); assert.equal(f.policy.wanted(), false);
});


test('an initial connection that never armed does not block normal UI backend recovery', async () => {
  const f = controllerFixture(); f.policy.request(f.now); f.policy.save('/files');
  f.c.backendStatus = 'STOPPED'; await f.c.refreshOrRecoverBackend(1);
  assert.equal(f.policy.wanted(), false);
  assert.equal(f.getNetsCalls, 0);
  assert.equal(f.uiBackendReads, 1); assert.equal(f.uiBackendStarts, 1);
});



test('VPN handoff uses the captured account state root', async () => {
  const f = extensionFixture();
  f.e.serverStateRoot = '/files/tailscale/account-profiles/server-1/profile-2';
  await f.e.createProbeTun();
  assert.deepEqual(f.nativeRoots, [f.e.serverStateRoot]);
});

test('an account change during TUN startup cleans up instead of publishing the old identity', async () => {
  const f = extensionFixture(); const gate = deferred(); f.gates.set('protect', gate);
  const pending = f.e.createProbeTun(); await flush();
  f.profileToken = 'profile-1:1'; gate.resolve(); await pending;
  assert.equal(f.e.explicitStopRequested, true);
  assert.equal(f.trace.includes('status-start'), false);
  assert.ok(f.trace.includes('tun-destroy'));
  assert.ok(f.trace.includes('native-stop'));
});


test('tryFastReconnect bypasses UI Go backend startup during automatic background recovery', () => {
  const f = controllerFixture();
  f.arm();
  f.activeCommand = 1;
  f.c.connectCommandId = 1;
  f.c.vpnAutoRecoveryCommandId = 1;
  f.c.vpnBackendWasRunningBeforeConnect = false;
  f.c.backendRestartDeferred = false;
  f.c.cachedVpnConnectConfig = '100.64.0.10|fd7a::10|';
  const staged = [];
  f.c.stageVpnConnectConfig = cfg => { staged.push(cfg); return true; };
  delete f.c.tryFastReconnect;

  const handled = f.c.tryFastReconnect(1);
  assert.equal(handled, true);
  assert.deepEqual(staged, ['100.64.0.10|fd7a::10|']);
  assert.equal(f.uiBackendStarts ?? 0, 0);
  assert.ok(f.startedWant);
  assert.ok(f.events.some(e => e[0] === 'fast_reconnect_used' && e[1] === 'auto_recovery'));
});

test('tryFastReconnect falls back to normal preflight for manual connect when restart is not deferred', () => {
  const f = controllerFixture();
  f.arm();
  f.activeCommand = 1;
  f.c.connectCommandId = 1;
  f.c.vpnAutoRecoveryCommandId = 0;
  f.c.vpnBackendWasRunningBeforeConnect = false;
  f.c.backendRestartDeferred = false;
  delete f.c.tryFastReconnect;

  assert.equal(f.c.tryFastReconnect(1), false);
  assert.equal(f.startedWant, undefined);
});

test('refreshOrRecoverBackend aborts UI backend startup if VPN becomes live or handoff starts while awaiting status', async () => {
  for (const lateCondition of ['live', 'handoff']) {
    const f = controllerFixture();
    f.c.backendStatus = 'STOPPED';
    f.c.refreshBackendStatus = async () => {
      f.uiBackendReads = (f.uiBackendReads ?? 0) + 1;
      if (lateCondition === 'live') {
        f.live = true;
      } else {
        f.c.vpnBackendHandoffInFlight = true;
      }
    };
    await f.c.refreshOrRecoverBackend(1);
    assert.equal(f.uiBackendReads, 1);
    assert.equal(f.uiBackendStarts ?? 0, 0, `must not start UI tsnet when ${lateCondition} becomes active`);
  }

  // Also skips immediately at entry when vpnBackendHandoffInFlight or live VPN is already active.
  const entryBlocked = controllerFixture();
  entryBlocked.c.vpnBackendHandoffInFlight = true;
  entryBlocked.c.backendStatus = 'STOPPED';
  await entryBlocked.c.refreshOrRecoverBackend(1);
  assert.equal(entryBlocked.uiBackendReads ?? 0, 0);
  assert.equal(entryBlocked.uiBackendStarts ?? 0, 0);
});

test('processVpnBackendHandoffRequest stops UI backend and writes OK even when connectInProgress is false and connectCommandId is 0', async () => {
  const f = controllerFixture();
  const cmdFiles = new Map();
  let stopCalls = 0;
  f.c.connectInProgress = false;
  f.c.connectCommandId = 0;
  f.c.disconnectInProgress = false;
  f.c.logoutInProgress = false;
  f.c.controlServerSwitching = false;
  f.c.vpnBackendHandoffInFlight = false;
  f.c.lifecycleGeneration = 3;
  f.c.backendStatus = 'Running';
  f.c.vpnCommandGateway.readCommandFile = (_dir, name) => cmdFiles.get(name);
  f.c.vpnCommandGateway.writeCommandFile = (_dir, name, text) => { cmdFiles.set(name, text); return true; };
  f.c.vpnCommandGateway.stopBackend = async () => {
    stopCalls++;
    return 'OK | stopped';
  };
  const c = f.c;

  cmdFiles.set('vpn-backend-handoff-request.json', JSON.stringify({ requestId: 404 }));

  // Stale heartbeat must not consume handoff request.
  c.processVpnBackendHandoffRequest('/files', 'VPN interface established | backend handoff pending', false);
  assert.equal(stopCalls, 0);
  assert.ok(cmdFiles.get('vpn-backend-handoff-request.json').length > 0);

  // Fresh heartbeat with connectInProgress=false and connectCommandId=0 must complete handoff.
  c.processVpnBackendHandoffRequest('/files', 'VPN interface established | backend handoff pending', true);
  await flush();
  assert.equal(stopCalls, 1);
  assert.equal(c.vpnBackendHandoffInFlight, false);
  assert.deepEqual(
    JSON.parse(cmdFiles.get('vpn-backend-handoff-response.json')),
    { requestId: 404, status: 'OK | stopped' }
  );
});

test('restoreBackendVpnConfig fallback awaits requestUiBackendHandoff before backendStart and avoids duplicate handoff', async () => {
  const f = extensionFixture();
  const order = [];
  const methods = [
    'startupIntentAllowed',
    'createProbeTun',
    'restoreBackendVpnConfig',
    'stopCancelledStartup',
    'finishDestroyedBackend',
    'stopNativeBackend',
    'finishNativeStop',
    'waitForDnsSystemPlan'
  ].map(n => method(extensionSource, n)).join('\n');
  f.sandbox.nativeBridge.backendStart = () => {
    order.push('backendStart');
    return 'OK | state=Running';
  };
  vm.runInNewContext(clean('class FallbackExtension {\n' + methods + '\n}') + '\nglobalThis.FallbackExtension = FallbackExtension;', f.sandbox);

  const e = Object.assign(new f.sandbox.FallbackExtension(), f.e, {
    consumeVpnConnectConfig: () => '',
    harmonyOSVersion: () => '6.0',
    requestUiBackendHandoff: async () => {
      order.push('handoff');
      return 'OK';
    }
  });
  delete e.restoreBackendVpnConfig;

  await e.createProbeTun();
  assert.deepEqual(order, ['handoff', 'backendStart'], 'UI backend handoff must finish before fallback backendStart and run only once');
  assert.equal(e.backendHandoffCompleted, true);
});

test('bind-only cold start never initializes runtime diagnostics or TUN setup', () => {
  const f = fixture();
  const methods = ['startupIntentAllowed', 'onCreate'].map(n => method(extensionSource, n)).join('\n');
  vm.runInNewContext(clean('class Extension {\n' + methods + '\n}') + '\nglobalThis.Extension = Extension;', f.sandbox);
  const e = new f.sandbox.Extension();
  e.context = { filesDir: '/files' };
  e.runtimeDiagnostic = { start() { throw Error('bind-only cold start must not start diagnostics'); } };
  e.onCreate({ parameters: { mesharcBindOnly: true } });
  assert.equal(e.destroying, true);
  assert.equal(f.extensionStops, 1);
});

test('onConnect caches a lightweight RemoteObject and skips diagnostics while destroying', () => {
  const f = fixture();
  let created = 0;
  f.sandbox.rpc = {
    RemoteObject: class {
      constructor(descriptor) {
        this.descriptor = descriptor;
        created++;
      }
    }
  };
  const onConnectMethod = method(extensionSource, 'onConnect');
  vm.runInNewContext(clean('class Extension {\n' + onConnectMethod + '\n}') + '\nglobalThis.Extension = Extension;', f.sandbox);
  const e = new f.sandbox.Extension();
  e.destroying = false;
  e.recordDiagnosticEvent = (...args) => f.events.push(args);

  const first = e.onConnect({});
  const second = e.onConnect({});
  assert.equal(first, second);
  assert.equal(created, 1);
  assert.equal(first.descriptor, 'io.github.tailscaleohos.vpn.bind');
  assert.deepEqual(f.events, [['vpn_extension_bound', 'lifecycle'], ['vpn_extension_bound', 'lifecycle']]);

  e.destroying = true;
  e.onConnect({});
  assert.equal(f.events.length, 2);
});
