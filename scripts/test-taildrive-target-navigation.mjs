import assert from 'node:assert/strict';
import test from 'node:test';
import { loadEtsModules } from './helpers/ets-vm-loader.mjs';

const { TaildriveSessionController } = loadEtsModules(['services/TaildriveSessionController']);
const flush = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
};
const ready = (path, entries = []) => ({ state: 'ready', reason: '', path, entries });
const directory = (name, path) => ({ name, path, kind: 'directory', size: 0, modifiedAtMs: 0 });

function state() {
  let path = '/';
  const current = {
    appInForeground: true, browserVisible: true, connected: true, standalone: true, filesTabActive: true,
    appLockActive: false, folderLockEnabled: false, lockedFolderPaths: [], folderAccessGrants: [],
    folderAccessAuthInFlight: false, busy: false, loading: false, fileActionGeneration: 0,
    targetRequestId: 1, targetMachineName: 'one.example.', targetTailnetName: 'tailnet',
    reason: '', status: '', retryAvailable: false,
    entries: [], lastListedPath: '', appliedPaths: [], requestedPaths: [], selectedPaths: [], cachedEntries: [],
    authenticateFolderAccess: async () => true
  };
  current.gateway = { async list(reqPath) { current.requestedPaths.push(reqPath); return ready(reqPath); } };
  const controller = new TaildriveSessionController({
    isConnected: () => current.connected,
    isStandalone: () => current.standalone,
    isFilesTabActive: () => current.filesTabActive,
    isBrowserVisible: () => current.browserVisible,
    isAppInForeground: () => current.appInForeground,
    setAppInForeground: value => { current.appInForeground = value; },
    isAppLockActive: () => current.appLockActive,
    isFolderLockEnabled: () => current.folderLockEnabled,
    getLockedFolderPaths: () => current.lockedFolderPaths,
    setLockedFolderPaths: paths => { current.lockedFolderPaths = paths; },
    getFolderAccessGrants: () => current.folderAccessGrants,
    setFolderAccessGrants: grants => { current.folderAccessGrants = grants; },
    isFolderAccessAuthInFlight: () => current.folderAccessAuthInFlight,
    setFolderAccessAuthInFlight: value => { current.folderAccessAuthInFlight = value; },
    getTargetMachineName: () => current.targetMachineName,
    getTargetTailnetName: () => current.targetTailnetName,
    getTargetRequestId: () => current.targetRequestId,
    getPath: () => path,
    setPath: value => { current.path = value; },
    getEntries: () => current.entries,
    setEntries: entries => { current.entries = entries; },
    getLastListedPath: () => current.lastListedPath,
    setLastListedPath: value => { current.lastListedPath = value; },
    isLoading: () => current.loading,
    setLoading: value => { current.loading = value; },
    isBusy: () => current.busy,
    setBusy: value => { current.busy = value; },
    getReason: () => current.reason,
    setReason: value => { current.reason = value; },
    getStatus: () => current.status,
    setStatus: value => { current.status = value; },
    showTransientStatus: value => { current.status = value; },
    isRetryAvailable: () => current.retryAvailable,
    setRetryAvailable: value => { current.retryAvailable = value; },
    getSelectedPaths: () => current.selectedPaths,
    setSelectedPaths: paths => { current.selectedPaths = paths; },
    getFileActionGeneration: () => current.fileActionGeneration,
    setFileActionGeneration: value => { current.fileActionGeneration = value; },
    setCachedEntries: entries => { current.cachedEntries = entries; },
    clearPreviewThumbnails() {},
    cancelThumbnailPool() {},
    rebuildListDataSource() {},
    updateBackState() {},
    publishUiBackState() {},
    delayIndicator: async () => {},
    authenticateFolderAccess: () => current.authenticateFolderAccess(),
    recordSecurityDiagnostic() {},
    logTargetOpen() {},
    applyListResult(result, fallback) {
      current.path = result.path || fallback;
      current.lastListedPath = current.path;
      current.entries = result.entries;
      current.appliedPaths.push(current.path);
      current.reason = '';
    },
    gatewayList: reqPath => current.gateway.list(reqPath)
  });
  controller.refreshGeneration = 1;
  Object.defineProperties(current, {
    path: {
      get: () => path,
      set(value) { if (path !== value) { path = value; controller.onPathChanged(); } }
    },
    refreshGeneration: {
      get: () => controller.refreshGeneration,
      set(value) { controller.refreshGeneration = value; }
    },
    refreshInFlight: { get: () => controller.refreshInFlight },
    refreshPending: { get: () => controller.refreshPending },
    targetOpenInFlight: { get: () => controller.targetOpenInFlight },
    lastTargetRequestId: { get: () => controller.lastTargetRequestId },
    retryKind: { get: () => controller.retryKind }
  });
  for (const name of ['openTargetMachine', 'requestTargetMachineOpen', 'refresh', 'onPathChanged']) {
    current[name] = (...args) => controller[name](...args);
  }
  return current;
}

test('direct target navigation retains normalized device paths and consumes only a completed request', async () => {
  const current = state();
  await current.openTargetMachine(1);
  assert.deepEqual(current.requestedPaths, ['/tailnet/one']);
  assert.deepEqual(current.appliedPaths, ['/tailnet/one']);
  assert.equal(current.lastTargetRequestId, 1);
  assert.equal(current.targetOpenInFlight, false);
});

test('fallback search retains preferred tailnet order and stops after finding the requested machine', async () => {
  const current = state();
  let directAttempts = 0;
  current.gateway.list = async path => {
    current.requestedPaths.push(path);
    if (path === '/tailnet/one' && directAttempts++ === 0) return { state: 'error', reason: 'not_found' };
    if (path === '/') return ready('/', [directory('other', '/other'), directory('tailnet', '/tailnet')]);
    if (path === '/tailnet') return ready(path, [directory('one.example', '/tailnet/one')]);
    return ready(path);
  };
  await current.openTargetMachine(1);
  assert.deepEqual(current.requestedPaths, ['/tailnet/one', '/', '/tailnet', '/tailnet/one']);
  assert.deepEqual(current.appliedPaths, ['/tailnet/one']);
});

test('every awaited fallback step checks lifecycle before using its result or sending another query', async () => {
  for (const stopAt of ['/', '/tailnet', '/tailnet/one']) {
    const current = state();
    current.targetTailnetName = '';
    const old = deferred();
    const responses = {
      '/': ready('/', [directory('tailnet', '/tailnet')]),
      '/tailnet': ready('/tailnet', [directory('one', '/tailnet/one')]),
      '/tailnet/one': ready('/tailnet/one')
    };
    current.gateway.list = path => {
      current.requestedPaths.push(path);
      return path === stopAt ? old.promise : Promise.resolve(responses[path]);
    };
    const pending = current.openTargetMachine(1);
    await flush();
    assert.equal(current.requestedPaths.at(-1), stopAt);
    current.filesTabActive = false;
    current.refreshGeneration++;
    old.resolve(responses[stopAt]);
    await pending;
    assert.equal(current.appliedPaths.length, 0, stopAt);
    assert.equal(current.requestedPaths.at(-1), stopAt);
    assert.equal(current.path, '/');
  }
});

test('latest target wins while an older direct request is still returning', async () => {
  const current = state();
  const old = deferred();
  current.gateway.list = path => {
    current.requestedPaths.push(path);
    return path === '/tailnet/one' ? old.promise : Promise.resolve(ready(path));
  };
  const pending = current.openTargetMachine(1);
  await flush();
  current.targetMachineName = 'two';
  current.targetRequestId = 2;
  current.refreshGeneration++;
  current.requestTargetMachineOpen();
  old.resolve(ready('/tailnet/one'));
  await pending;
  await flush();
  assert.deepEqual(current.requestedPaths, ['/tailnet/one', '/tailnet/two']);
  assert.deepEqual(current.appliedPaths, ['/tailnet/two']);
  assert.equal(current.lastTargetRequestId, 2);
});

test('hidden, backgrounded, locked and disconnected target results cannot update the view or continue traversal', async () => {
  for (const [field, value] of [['browserVisible', false], ['appInForeground', false],
    ['filesTabActive', false], ['connected', false], ['appLockActive', true]]) {
    const current = state();
    const old = deferred();
    current.gateway.list = path => { current.requestedPaths.push(path); return old.promise; };
    const pending = current.openTargetMachine(1);
    await flush();
    current[field] = value;
    current.refreshGeneration++;
    old.resolve({ state: 'error', reason: 'old_failure' });
    await pending;
    assert.equal(current.appliedPaths.length, 0, field);
    assert.equal(current.requestedPaths.length, 1, field);
    assert.equal(current.retryKind, '', field);
    assert.equal(current.lastTargetRequestId, 0, field);
    assert.equal(current.loading, false, field);
  }
});

test('an interrupted target request resumes once after returning to an active page', async () => {
  const current = state();
  const old = deferred();
  current.gateway.list = path => {
    current.requestedPaths.push(path);
    return current.requestedPaths.length === 1 ? old.promise : Promise.resolve(ready(path));
  };
  const pending = current.openTargetMachine(1);
  await flush();
  current.appInForeground = false;
  current.refreshGeneration++;
  old.resolve(ready('/tailnet/one'));
  await pending;
  current.appInForeground = true;
  current.requestTargetMachineOpen();
  current.requestTargetMachineOpen();
  await flush();
  assert.equal(current.requestedPaths.length, 2);
  assert.deepEqual(current.appliedPaths, ['/tailnet/one']);
});

test('manual directory navigation supersedes a target route and queues one refresh of the chosen directory', async () => {
  const current = state();
  const old = deferred();
  current.gateway.list = path => {
    current.requestedPaths.push(path);
    return path === '/tailnet/one' ? old.promise : Promise.resolve(ready(path));
  };
  const pending = current.openTargetMachine(1);
  await flush();
  current.path = '/chosen';
  await current.refresh();
  old.resolve(ready('/tailnet/one'));
  await pending;
  await flush();
  assert.deepEqual(current.requestedPaths, ['/tailnet/one', '/chosen']);
  assert.deepEqual(current.appliedPaths, ['/chosen']);
});

test('obsolete target failures preserve current errors and the latest request still completes', async () => {
  const current = state();
  const old = deferred();
  current.gateway.list = path => path === '/tailnet/one' ? old.promise : Promise.resolve(ready(path));
  const pending = current.openTargetMachine(1);
  await flush();
  current.appInForeground = false;
  current.reason = 'current_error';
  current.refreshGeneration++;
  old.reject(new Error('obsolete failure'));
  await pending;
  assert.equal(current.reason, 'current_error');
  assert.equal(current.retryKind, '');
});

test('authentication refusal is consumed without repeatedly reopening authentication', async () => {
  const current = state();
  current.folderLockEnabled = true;
  current.lockedFolderPaths = ['/tailnet/one'];
  let attempts = 0;
  current.authenticateFolderAccess = async () => { attempts++; return false; };
  await current.openTargetMachine(1);
  current.requestTargetMachineOpen();
  await flush();
  assert.equal(attempts, 1);
  assert.equal(current.requestedPaths.length, 0);
  assert.equal(current.lastTargetRequestId, 1);
});

test('current target failure remains retryable and a not-found fallback publishes a consistent root', async () => {
  const current = state();
  current.gateway.list = async path => ({ state: 'error', reason: 'permission_denied', path, entries: [] });
  await current.openTargetMachine(1);
  assert.equal(current.reason, 'permission_denied');
  assert.equal(current.retryKind, 'target');
  current.gateway.list = async path => path === '/' ? ready('/') : { state: 'error', reason: 'not_found' };
  await current.openTargetMachine(1);
  assert.equal(current.status, 'target_not_found');
  assert.equal(current.path, '/');
  assert.equal(current.lastTargetRequestId, 1);
  assert.equal(current.retryKind, '');
});
