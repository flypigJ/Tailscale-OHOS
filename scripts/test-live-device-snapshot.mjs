import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';
import { loadEtsModules } from './helpers/ets-vm-loader.mjs';

const extension = readFileSync(new URL('../entry/src/main/ets/vpnextensionability/TailscaleVpnExtensionAbility.ets', import.meta.url), 'utf8');
const ui = readFileSync(new URL('../entry/src/main/ets/components/BridgeStatus.ets', import.meta.url), 'utf8');
const vpnCtrlSource = readFileSync(new URL('../entry/src/main/ets/services/VpnSessionController.ets', import.meta.url), 'utf8');
const method = (source, name) => source.match(new RegExp(`^  (?:private )?(?:async )?${name}\\([\\s\\S]*?^  }`, 'm'))[0]
  .replace(/^  (?:private )?(async )?/, '$1function ');
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
const live = { status: 'OK | state=Running', peers: [{ key: 'peer-0123456789abcdef', name: 'PC' }],
  meshArcReceiver: { state: 'ready', sent: 0, registered: 1 }, account: { loginName: 'fixture', displayName: 'Fixture' } };

function fixture() {
  const tasks = [], writes = [], timers = new Map();
  const context = vm.createContext({ JSON, Array,
    nativeBridge: {
      backendPeerSnapshot() {
        return new Promise((resolve, reject) => tasks.push({ resolve, reject }));
      },
      backendSnapshot: () => new Promise(() => {})
    },
    setInterval(callback, delay) { timers.set(delay, callback); return delay; }, clearInterval() {},
    PathDiagnosticService: { resume() {} }
  });
  vm.runInContext(stripTypeScriptTypes(['refreshDeviceSnapshot', 'startStatusUpdates'].map(name => method(extension, name)).join('\n')), context);
  const state = new Proxy({
    peerSnapshotInFlight: false, peerSnapshotRequestId: 0, destroying: false, backendStopInFlight: false,
    explicitStopRequested: false, dnsRebuildInFlight: false, statusUpdateInFlight: false,
    statusTimer: -1, taildropRequestTimer: -1, taildropIncomingTimer: -1,
    dnsObserver: { start() {}, refresh() {} }, processBackendStopRequest: () => false,
    writePeerSnapshot: (...args) => writes.push(args),
    refreshDeviceSnapshot: context.refreshDeviceSnapshot,
    startStatusUpdates: context.startStatusUpdates
  }, { get: (target, key) => key in target ? target[key] : () => {} });
  return { state, tasks, writes, timers };
}

test('device and account snapshot publishes while the full file-service snapshot remains pending', async () => {
  const f = fixture(); f.state.startStatusUpdates(); assert.equal(f.tasks.length, 1);
  f.timers.get(1000)(); assert.equal(f.state.statusUpdateInFlight, true);
  f.tasks[0].resolve(JSON.stringify(live)); await flush();
  assert.equal(f.writes.length, 1); assert.equal(f.writes[0][2].loginName, 'fixture');
  f.timers.get(1000)(); assert.equal(f.tasks.length, 2, 'slow snapshot must not block the next peer refresh');
});

test('device refresh stays single flight and retries after a native failure', async () => {
  const f = fixture(); f.state.refreshDeviceSnapshot(); f.state.refreshDeviceSnapshot();
  assert.equal(f.tasks.length, 1); f.tasks[0].reject(new Error('temporary')); await flush();
  assert.equal(f.writes.length, 0); assert.equal(f.state.peerSnapshotInFlight, false);
  f.state.refreshDeviceSnapshot(); assert.equal(f.tasks.length, 2);
});

for (const flag of ['destroying', 'backendStopInFlight', 'explicitStopRequested', 'dnsRebuildInFlight']) {
  test(`${flag} prevents publishing an outstanding device/account snapshot`, async () => {
    const f = fixture(); f.state.refreshDeviceSnapshot(); f.state[flag] = true;
    f.tasks[0].resolve(JSON.stringify(live)); await flush(); assert.equal(f.writes.length, 0);
    f.state.refreshDeviceSnapshot(); assert.equal(f.tasks.length, 1);
  });
}

test('restarting status polling retires the previous request without releasing the new request', async () => {
  const f = fixture(); f.state.startStatusUpdates(); f.state.startStatusUpdates();
  f.tasks[0].resolve(JSON.stringify(live)); await flush();
  assert.equal(f.writes.length, 0); assert.equal(f.state.peerSnapshotInFlight, true);
  f.tasks[1].resolve(JSON.stringify(live)); await flush();
  assert.equal(f.writes.length, 1); assert.equal(f.state.peerSnapshotInFlight, false);
});

for (const value of ['{', JSON.stringify({ ...live, status: 'FAILED | status', peers: [] })]) {
  test(`invalid/non-running snapshot preserves the last directory: ${value[0]}`, async () => {
    const f = fixture(); f.state.refreshDeviceSnapshot(); f.tasks[0].resolve(value); await flush();
    assert.equal(f.writes.length, 0); assert.equal(f.state.peerSnapshotInFlight, false);
  });
}

function uiFixture() {
  let snapshot = { peers: live.peers, meshArcReceiver: live.meshArcReceiver, account: live.account, updatedAtMs: 10000 };
  const accounts = [], peers = [];
  const context = vm.createContext({
    JSON, Date: { now: () => 11000 },
    VPN_PEERS_FILE_NAME: 'vpn-peers-v1.json',
    emptyMeshArcReceiverStatus: () => ({ state: 'idle', sent: 0, registered: 0 }),
    sanitizeVpnDiagnosticToken: (v, fallback) => v || fallback,
    sanitizeVpnDiagnosticCount: v => Number.isFinite(v) ? v : 0,
    fileIo: { accessSync: () => true, readTextSync: () => JSON.stringify(snapshot) }
  });
  vm.runInContext(stripTypeScriptTypes(method(vpnCtrlSource, 'refreshPeerSnapshot')), context);
  const state = {
    hasAuthenticatedSession: false,
    isConnected: () => true,
    peers: [],
    peerSnapshotSignature: '',
    emptyPeerSnapshotSinceMs: 0,
    host: {
      getFilesDir: () => '/fixture',
      getPeers: () => state.peers,
      setHasAuthenticatedSession: v => { state.hasAuthenticatedSession = v; },
      setMeshArcReceiver() {},
      syncOfflinePeerStatusRefreshPolling() {},
      setDevicesLoading() {},
      logServiceStatusIfChanged() {}
    },
    applyAccountSummary: account => accounts.push(account),
    applyPeers: list => { state.peers = list; peers.push(list); },
    refreshPeerSnapshot: context.refreshPeerSnapshot
  };
  return { state, accounts, peers, set(value) { snapshot = value; }, get() { return snapshot; } };
}

test('cold UI reopening obtains account identity from the live VPN snapshot', () => {
  const f = uiFixture(); f.state.refreshPeerSnapshot();
  assert.equal(f.accounts[0].loginName, 'fixture'); assert.equal(f.state.hasAuthenticatedSession, true);
  f.set({ ...f.get(), account: { ...live.account, displayName: 'Updated' } });
  f.state.refreshPeerSnapshot(); assert.equal(f.accounts[1].displayName, 'Updated');
});

test('expired and legacy snapshots cannot clear account identity', () => {
  const f = uiFixture(); f.set({ ...f.get(), updatedAtMs: 1 }); f.state.refreshPeerSnapshot();
  assert.equal(f.accounts.length, 0); assert.equal(f.peers.length, 0);
  f.set({ ...f.get(), updatedAtMs: 10000, account: undefined }); f.state.refreshPeerSnapshot();
  assert.equal(f.accounts.length, 0); assert.equal(f.peers.length, 1);
});

test('explicit cold-start restore shows cached devices offline without treating old presence as live', () => {
  const f = uiFixture(); f.state.isConnected = () => false;
  f.set({ ...f.get(), updatedAtMs: 1, peers: [{ ...live.peers[0], online: true, localSend: { state: 'available' } }] });
  f.state.refreshPeerSnapshot(); assert.equal(f.peers.length, 0, 'normal offline polls do not read live IPC');
  f.state.refreshPeerSnapshot(true);
  assert.equal(f.peers[0].length, 1); assert.equal(f.peers[0][0].online, false);
  assert.equal(f.peers[0][0].localSend.state, 'offline');
  assert.equal(f.accounts[0].loginName, 'fixture');
});

test('MagicDNS detail uses the assigned full name only when enabled', () => {
  const context = vm.createContext({});
  loadEtsModules(['services/AtomicFileStore', 'services/DnsSettings'], context);
  vm.runInContext(stripTypeScriptTypes(method(ui, 'deviceDetailMagicDnsName')), context);
  const state = { tailnetDnsEnabled: true, peers: [{ key: 'p', name: 'desktop.tail123.ts.net.' }] };
  assert.equal(context.deviceDetailMagicDnsName.call(state, 'p'), 'desktop.tail123.ts.net');
  state.tailnetDnsEnabled = false; assert.equal(context.deviceDetailMagicDnsName.call(state, 'p'), '');
  state.tailnetDnsEnabled = true;
  for (const name of ['100.64.0.1', 'desktop', 'http://desktop.ts.net/', '', 'bad name.ts.net']) {
    state.peers[0].name = name; assert.equal(context.deviceDetailMagicDnsName.call(state, 'p'), '');
  }
});

test('storage summary uses the same bytes, precision and units as its detail', () => {
  const context = vm.createContext({ Math });
  vm.runInContext(stripTypeScriptTypes(['settingsStorageTotalBytes', 'storageTotalValueLabel', 'storageTotalUnitLabel']
    .map(name => method(ui, name)).join('\n')), context);
  const state = { nativeStorageAppDataBytes: 1024 * 1024 * 1.24, nativeStorageReceivedBytes: 0,
    nativeStorageTemporaryBytes: 0, settingsStorageTotalBytes: context.settingsStorageTotalBytes };
  assert.equal(context.storageTotalValueLabel.call(state), '1.2');
  assert.equal(context.storageTotalUnitLabel.call(state), 'MB');
  assert.match(ui, /`\$\{this\.storageTotalValueLabel\(\)\} \$\{this\.storageTotalUnitLabel\(\)\}`/);
  assert.doesNotMatch(ui, /storageSummaryBytes/);
});
