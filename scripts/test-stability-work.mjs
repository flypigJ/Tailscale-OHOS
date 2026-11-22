import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const read = path => readFileSync(new URL('../' + path, import.meta.url), 'utf8');
const poolSource = read('entry/src/main/ets/services/LatestTaskPool.ets');
const storageSource = read('entry/src/main/ets/services/StorageUsageScanner.ets');
const shell = read('entry/src/main/ets/components/BridgeStatus.ets');
const extension = read('entry/src/main/ets/vpnextensionability/TailscaleVpnExtensionAbility.ets');
const flush = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => { let resolve, reject; const promise = new Promise((a,b) => { resolve=a; reject=b; }); return { promise, resolve, reject }; };
function method(source, name) {
  const text = source.match(new RegExp('^  private (?:async )?' + name + '\\([\\s\\S]*?^  \\}', 'm'))?.[0];
  assert.ok(text, name);
  return text.replace(/^  private async /, 'async function ').replace(/^  private /, 'function ');
}
function load(source, name, sandbox = {}) {
  vm.runInNewContext(stripTypeScriptTypes(source.replace(/^import .*;\r?$/gm, '').replace(/^export /gm, '')) + `\nthis.Loaded = ${name};`, sandbox);
  return sandbox.Loaded;
}

const taildropCtrlSource = read('entry/src/main/ets/services/TaildropSessionController.ets');
test('staged shares are discarded when lifecycle, app lock, connection or peer changes', async () => {
  for (const change of [s=>s.lifecycleGeneration++,s=>s.appLockRequired=true,
    s=>s.connected=false,s=>s.peers=[]]) {
    const gate=deferred(); let submitted=0, cleaned=0;
    const rawMethod = taildropCtrlSource.match(/^  async queueTaildropFiles\([\s\S]*?^  \}/m)?.[0];
    assert.ok(rawMethod, 'queueTaildropFiles');
    const sandbox={TAILDROP_MAX_MEDIA_SELECTION:100};
    vm.runInNewContext(stripTypeScriptTypes(rawMethod.replace(/^  async /, 'async function ')),sandbox);
    const peer={key:'peer',name:'Peer',online:true};
    const state={appShellReady:true, lifecycleGeneration:1, nextTaildropSendRequestId:0,
      appLockRequired:false, appLockAuthenticating:false, taildropPreparing:false,
      connected:true, taildropState:'ready', taildropTransfer:{state:'idle'},
      peers:[peer], prepareTaildropFiles:()=>gate.promise,
      taildropOutboxRoot:()=>'/files/outbox',
      cleanupPreparedTaildropFiles(){cleaned++;},writeTaildropSendRequest(){submitted++;return true;}};
    state.host={
      isAppShellReady:()=>state.appShellReady,
      isAppLockRequired:()=>state.appLockRequired,
      isAppLockAuthenticating:()=>state.appLockAuthenticating,
      isConnected:()=>state.connected,
      getTaildropState:()=>state.taildropState,
      isTaildropPreparing:()=>state.taildropPreparing,
      setTaildropPreparing:v=>{state.taildropPreparing=v;},
      getTaildropTransfer:()=>state.taildropTransfer,
      setTaildropTransfer:t=>{state.taildropTransfer=t;},
      isTaildropReceiveInProgress:()=>false,
      getLifecycleGeneration:()=>state.lifecycleGeneration,
      getTaildropTargets:()=>state.peers,
      setTaildropTransferRate(){}, setTaildropTransferEtaSeconds(){},
      setTaildropCancelPending(){}, showTaildropToast(){}
    };
    const result=sandbox.queueTaildropFiles.call(state,peer,['file://media/photo']);
    change(state); gate.resolve([{path:'/cache/1',size:4}]);
    assert.equal(await result,false); assert.equal(submitted,0); assert.equal(cleaned,1);
    if(state.lifecycleGeneration===1)assert.equal(state.taildropPreparing,false);
  }
});

test('cancelled native tasks keep their slots until settled and rejection does not stall the queue', async () => {
  const Pool = load(poolSource, 'LatestTaskPool');
  const pool = new Pool(2);
  const a = deferred(), b = deferred();
  const started = [];
  pool.replace([a,b, deferred()], async (item, current) => {
    started.push('old'); await item.promise; assert.equal(current(), false);
  });
  await flush();
  pool.cancel();
  pool.replace([1,2], async item => { started.push(item); });
  await flush();
  assert.deepEqual(started, ['old','old']);
  a.reject(new Error('cancelled operation'));
  await flush();
  assert.deepEqual(started, ['old','old',1,2]);
  b.resolve();
  await flush();
});

test('storage scan uses asynchronous IO, excludes symlinks, tolerates a disappearing file and yields', async () => {
  let tick = false, calls = 0;
  setImmediate(() => { tick = true; });
  const tree = { '/files': ['data', 'inbox', 'previews', 'link'], '/files/inbox': ['a', 'gone'],
    '/files/previews': ['b'], '/cache': ['c'] };
  const sizes = { '/files/data': 10, '/files/inbox/a': 20, '/files/previews/b': 30, '/cache/c': 40 };
  const Scanner = load(storageSource, 'StorageUsageScanner', { fileIo: {
    async lstat(path) { calls++; await flush(); if (path.endsWith('/gone')) throw Object.assign(Error('removed'), { code: 13900002 });
      return { isFile: () => path in sizes, isDirectory: () => path in tree, size: sizes[path] }; },
    async listFile(path) { await flush(); return tree[path]; }
  }});
  const result = await Scanner.measure('/files', '/cache', ['inbox','previews'], () => true);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), { appData: 10, received: 50, temporary: 40 });
  assert.ok(tick);
  assert.equal(calls, 9);
  assert.doesNotMatch(storageSource, /\b(?:statSync|lstatSync|listFileSync|accessSync)\(/);
});

test('cancelling a scan during IO stops before listing the old directory', async () => {
  const gate = deferred(); let current = true, listed = false;
  const Scanner = load(storageSource, 'StorageUsageScanner', { fileIo: {
    lstat: () => gate.promise, listFile: async () => { listed = true; return ['a']; }
  }});
  const result = Scanner.directorySize('/cache', () => current);
  current = false;
  gate.resolve({ isFile: () => false, isDirectory: () => true });
  assert.equal(await result, 0);
  assert.equal(listed, false);
});

test('settings callbacks coalesce and obsolete scans cannot overwrite a new session', async () => {
  const Pool = load(poolSource, 'LatestTaskPool');
  const scans = [], sandbox = { hilog: { info() {}, warn() {} }, StorageUsageScanner: { measure: () => { const d=deferred(); scans.push(d); return d.promise; } },
    TAILDROP_INBOX_DIR_NAME: 'inbox', TAILDROP_HISTORY_MEDIA_DIR_NAME: 'previews',
    clearInterval: () => {}, CACHE_SIZE_POLL_INTERVAL_MS: 30000, setInterval: () => 1 };
  const names=['refreshCacheSize','startCacheSizePolling','stopCacheSizePolling'];
  vm.runInNewContext(stripTypeScriptTypes(names.map(n => method(shell,n)).join('\n')), sandbox);
  const state={ ...Object.fromEntries(names.map(n => [n,sandbox[n]])), storageScanPool:new Pool(1),
    appShellReady:true, activeNavigationId:'settings',
    cacheSizePollTimer:-1, cacheSizeRefreshInFlight:false, cacheClearInProgress:false,
    lifecycleGeneration:1, getUIContext:()=>({getHostContext:()=>({filesDir:'/files',cacheDir:'/cache'})}), taildropWaitingFilesSize:()=>5, startStorageRingAnimation() {} };
  state.startCacheSizePolling(); state.startCacheSizePolling();
  await flush(); assert.equal(scans.length,1);
  state.stopCacheSizePolling(); state.lifecycleGeneration++; state.startCacheSizePolling();
  await flush(); assert.equal(scans.length,1);
  scans[0].resolve({appData:100,received:200,temporary:300});
  await flush(); assert.equal(state.storageSummaryBytes,undefined); assert.equal(scans.length,2);
  scans[1].resolve({appData:1,received:2,temporary:3});
  await flush(); assert.equal(state.nativeStorageAppDataBytes + state.nativeStorageReceivedBytes + state.nativeStorageTemporaryBytes,6); assert.equal(state.cacheSizeBytes,10);
});

test('VPN teardown destroys TUN without blocking and stops only after queued restart settles', async () => {
  for (const failRestart of [false,true]) {
    const restart=deferred(), destroyed=deferred(), stopped=deferred(), order=[];
    const sandbox={nativeBridge:{backendStopAsync:()=>{order.push('stop');return stopped.promise;}},DiagnosticPrivacy:{classifyError:()=>({code:-1})}};
    const names=['stopNativeBackend','finishNativeStop','finishDestroyedBackend'];
    vm.runInNewContext(stripTypeScriptTypes(names.map(n=>method(extension,n)).join('\n')),sandbox);
    const state={...Object.fromEntries(names.map(n=>[n,sandbox[n]])),backendRestartPromise:restart.promise,recordDiagnosticEvent:()=>{}};
    const ending=state.finishDestroyedBackend({destroy:()=>{order.push('destroy');return destroyed.promise;}});
    assert.deepEqual(order,['destroy']);
    destroyed.resolve(); await flush(); assert.deepEqual(order,['destroy']);
    if(failRestart)restart.reject(Error('restart failed')); else restart.resolve('OK');
    await flush(); assert.deepEqual(order,['destroy','stop']);
    state.stopNativeBackend(); assert.deepEqual(order,['destroy','stop']);
    stopped.resolve('OK'); await ending;
  }
  assert.doesNotMatch(extension,/nativeBridge\.backend(?:Stop|VpnConfig|RestartWithTun)\(/);
});

// A partial read is not a valid zero-byte total. The UI retains its last complete snapshot.
test('storage scan propagates permission and IO failures instead of silently reporting zero', async () => {
  for (const code of [13900013, 13900005]) {
    const Scanner = load(storageSource, 'StorageUsageScanner', { fileIo: {
      listFile: async () => ['data'],
      lstat: async () => { throw Object.assign(new Error('IO failure'), { code }); }
    }});
    await assert.rejects(Scanner.measure('/files', '/cache', [], () => true), { message: `storage_scan_io_${code}` });
  }
});

test('storage ring clamps progress and normalizes category shares to one circle', () => {
  const sandbox = {};
  vm.runInNewContext(stripTypeScriptTypes(method(shell, 'storageUsagePanelValues')), sandbox);
  const state = { storageRingProgress: 1, nativeStorageAppDataBytes: 100,
    nativeStorageReceivedBytes: 200, nativeStorageTemporaryBytes: 100 };
  const values = () => Array.from(sandbox.storageUsagePanelValues.call(state));
  assert.deepEqual(values(), [25, 50, 25]);
  state.storageRingProgress = 0; assert.deepEqual(values(), [0, 0, 0]);
  state.storageRingProgress = 0.5; assert.deepEqual(values(), [12.5, 25, 12.5]);
  state.storageRingProgress = 2; assert.deepEqual(values(), [25, 50, 25]);
  for (const sizes of [[1, 1, 1], [0, 5, 0], [1000, 1, 0], [123456, 17, 333], [0, 0, 8]]) {
    [state.nativeStorageAppDataBytes, state.nativeStorageReceivedBytes, state.nativeStorageTemporaryBytes] = sizes;
    assert.ok(values().reduce((a,b) => a+b, 0) <= 100);
    assert.ok(values().every(value => value >= 0));
  }
  state.nativeStorageAppDataBytes = state.nativeStorageReceivedBytes = state.nativeStorageTemporaryBytes = 0;
  assert.deepEqual(values(), [0, 0, 0]);
});

test('storage entry animation waits for data, runs once and retires callbacks when leaving', () => {
  const callbacks = [], animations = [];
  const sandbox = { MotionTokens: { duration: x => x }, Curve: { EaseOut: 'ease-out' } };
  vm.runInNewContext(stripTypeScriptTypes(method(shell, 'startStorageRingAnimation')), sandbox);
  const state = { storageRingPageShown: true, storageUsageReady: false, storageRingAnimationStarted: false,
    storageRingGeneration: 1, storageRingProgress: 0, scheduleLifecycleTask: fn => callbacks.push(fn),
    getUIContext: () => ({ animateTo(options, fn) { animations.push(options); fn(); } }) };
  const start = () => sandbox.startStorageRingAnimation.call(state);
  start(); assert.equal(callbacks.length, 0);
  state.storageUsageReady = true; start(); start(); assert.equal(callbacks.length, 1);
  callbacks.shift()(); assert.equal(state.storageRingProgress, 1);
  start(); assert.equal(callbacks.length, 0); assert.equal(animations.length, 1);
  assert.equal(animations[0].curve, 'ease-out');
  state.storageRingAnimationStarted = false; state.storageRingProgress = 0; start();
  state.storageRingPageShown = false; state.storageRingGeneration++;
  callbacks.shift()(); assert.equal(state.storageRingProgress, 0); assert.equal(animations.length, 1);
});

test('storage summary distinguishes unmeasured, failed and truly empty storage', () => {
  const sandbox = { $r: value => value };
  vm.runInNewContext(stripTypeScriptTypes(method(shell, 'storageSummaryLabel')), sandbox);
  const state = { storageUsageReady: false, storageScanFailed: false,
    storageTotalValueLabel: () => '0', storageTotalUnitLabel: () => 'B' };
  const label = () => sandbox.storageSummaryLabel.call(state);
  assert.equal(label(), 'app.string.settings_cache_calculating');
  state.storageScanFailed = true; assert.equal(label(), 'app.string.settings_storage_read_failed');
  state.storageUsageReady = true; assert.equal(label(), '0 B');
  state.storageTotalValueLabel = () => '34.0'; state.storageTotalUnitLabel = () => 'MB';
  assert.equal(label(), '34.0 MB');
  // ArkUI only tracks builder arguments when supplied as one object literal.
  assert.match(shell, /private SettingsCategoryRow\(\$\$: SettingsCategoryRowData\)/);
  assert.match(shell, /summary: this\.storageSummaryLabel\(\)/);
  assert.doesNotMatch(shell, /this\.SettingsCategoryRow\(\$r/);
  assert.match(shell, /private StorageUsageLegendRow\(\$\$: StorageLegendRowData\)/);
});
