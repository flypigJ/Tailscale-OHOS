import assert from 'node:assert/strict';
import test from 'node:test';
import { loadEtsModules } from './helpers/ets-vm-loader.mjs';

const { TaildriveSessionController } = loadEtsModules(['services/TaildriveSessionController']);
const root = '/tailnet/device/share';
const file = { name: 'old.txt', path: `${root}/old.txt`, kind: 'file', size: 1, modifiedAtMs: 0 };
const directory = name => ({ ...file, kind: 'directory', name, path: `${root}/${name}` });
const ready = entries => ({ state: 'ready', entries, reason: '' });
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; };

function fixture() {
  const state = {
    path: root, connected: true, busy: false, loading: false, browserVisible: true, standalone: true,
    filesTabActive: true, appInForeground: true, appLockActive: false,
    folderLockEnabled: false, lockedFolderPaths: [], folderAccessGrants: [], folderAccessAuthInFlight: false,
    allowOverlappingAuth: false, selectionMode: false, fileActionGeneration: 1,
    moveVisible: false, moveOperation: 'move', moveTargetCount: 0, moveSubmitInFlight: false,
    moveLoading: false, movePath: '/', moveRoot: '/', moveEntries: [], moveReason: '',
    authCalls: 0, listPaths: [], mutations: [], status: '', reason: '', retryAvailable: false,
    authenticateFolderAccess: async () => { state.authCalls++; return true; }
  };
  state.gateway = { async list(reqPath) { state.listPaths.push(reqPath); return ready([directory('destination')]); } };
  const controller = new TaildriveSessionController({
    isConnected: () => state.connected,
    isStandalone: () => state.standalone,
    isFilesTabActive: () => state.filesTabActive,
    isBrowserVisible: () => state.browserVisible,
    isAppInForeground: () => state.appInForeground,
    isAppLockActive: () => state.appLockActive,
    isFolderLockEnabled: () => state.folderLockEnabled,
    getLockedFolderPaths: () => state.lockedFolderPaths,
    setLockedFolderPaths: paths => { state.lockedFolderPaths = paths; },
    getFolderAccessGrants: () => state.folderAccessGrants,
    setFolderAccessGrants: grants => { state.folderAccessGrants = grants; },
    isFolderAccessAuthInFlight: () => state.allowOverlappingAuth ? false : state.folderAccessAuthInFlight,
    setFolderAccessAuthInFlight: value => { state.folderAccessAuthInFlight = value; },
    getTargetRequestId: () => 0,
    getTargetMachineName: () => '',
    getPath: () => state.path,
    isBusy: () => state.busy,
    setBusy: value => { state.busy = value; },
    setLoading: value => { state.loading = value; },
    setReason: value => { state.reason = value; },
    getStatus: () => state.status,
    setStatus: value => { state.status = value; },
    showTransientStatus: value => { state.status = value; },
    setRetryAvailable: value => { state.retryAvailable = value; },
    isSelectionMode: () => state.selectionMode,
    getFileActionGeneration: () => state.fileActionGeneration,
    isMoveVisible: () => state.moveVisible,
    setMoveVisible: value => { state.moveVisible = value; },
    getMoveOperation: () => state.moveOperation,
    setMoveOperation: value => { state.moveOperation = value; },
    getMoveTargetCount: () => state.moveTargetCount,
    setMoveTargetCount: value => { state.moveTargetCount = value; },
    isMoveLoading: () => state.moveLoading,
    setMoveLoading: value => { state.moveLoading = value; },
    isMoveSubmitInFlight: () => state.moveSubmitInFlight,
    setMoveSubmitInFlight: value => { state.moveSubmitInFlight = value; },
    getMoveReason: () => state.moveReason,
    setMoveReason: value => { state.moveReason = value; },
    getMovePath: () => state.movePath,
    setMovePath: value => { state.movePath = value; },
    setMoveRoot: value => { state.moveRoot = value; },
    getMoveEntries: () => state.moveEntries,
    setMoveEntries: entries => { state.moveEntries = entries; },
    recordSecurityDiagnostic() {},
    delayIndicator: async () => {},
    applyListResult() {},
    authenticateFolderAccess: () => state.authenticateFolderAccess(),
    gatewayList: reqPath => state.gateway.list(reqPath),
    gatewayMutate: async request => {
      state.mutations.push(request);
      return { state: 'completed', reason: '' };
    }
  });
  Object.defineProperty(state, 'movingEntry', { get: () => controller.movingEntry });
  for (const name of [
    'openMovePicker', 'loadMoveDirectory', 'moveGoUp', 'openMoveDirectory',
    'validMoveDestination', 'moveDestinationEntries', 'confirmMove', 'closeMovePicker'
  ]) {
    state[name] = (...args) => controller[name](...args);
  }
  state.close = () => controller.closeMovePicker();
  return state;
}

test('normal move retains its original source and selected destination', async () => {
  const state = fixture(); await state.openMovePicker(file);
  state.movePath = `${root}/destination`; await state.loadMoveDirectory();
  await state.confirmMove();
  assert.equal(state.mutations.length, 1);
  assert.deepEqual(JSON.parse(JSON.stringify(state.mutations[0])), {
    operation: 'move', path: file.path, newPath: `${root}/destination/old.txt`
  });
  assert.equal(state.moveVisible, false);
});

test('opening authentication cannot display a move panel after leaving its file context', async () => {
  for (const invalidate of [
    state => { state.path = '/another'; state.fileActionGeneration++; },
    state => { state.filesTabActive = false; }, state => { state.connected = false; },
    state => { state.appLockActive = true; }, state => { state.browserVisible = false; }
  ]) {
    const state = fixture();
    state.folderLockEnabled = true; state.lockedFolderPaths = [root];
    const auth = deferred(); state.authenticateFolderAccess = () => auth.promise;
    const pending = state.openMovePicker(file); invalidate(state); auth.resolve(true); await pending;
    assert.equal(state.moveVisible, false);
    assert.equal(state.listPaths.length, 0);
  }
});

test('latest opening request owns the move panel even when authentication finishes out of order', async () => {
  const state = fixture();
  state.folderLockEnabled = true; state.lockedFolderPaths = [`${root}/old.txt`, `${root}/new.txt`];
  state.allowOverlappingAuth = true;
  const first = deferred(); const second = deferred(); let calls = 0;
  state.authenticateFolderAccess = () => (++calls === 1 ? first.promise : second.promise);
  const oldOpening = state.openMovePicker(file);
  const newOpening = state.openMovePicker({ ...file, name: 'new.txt', path: `${root}/new.txt` });
  second.resolve(true); await newOpening;
  first.resolve(true); await oldOpening;
  assert.equal(state.movingEntry.name, 'new.txt');
});

test('an obsolete directory response cannot overwrite the latest destination or its loading state', async () => {
  const state = fixture(); await state.openMovePicker(file);
  const first = deferred(); const second = deferred();
  state.gateway.list = path => path.endsWith('/one') ? first.promise : second.promise;
  state.movePath = `${root}/one`; const oldListing = state.loadMoveDirectory();
  await new Promise(resolve => setImmediate(resolve));
  state.movePath = `${root}/two`; const newListing = state.loadMoveDirectory();
  await new Promise(resolve => setImmediate(resolve));
  second.resolve(ready([directory('new-result')])); await newListing;
  first.resolve(ready([directory('old-result')])); await oldListing;
  assert.equal(state.moveEntries[0].name, 'new-result');
  assert.equal(state.moveLoading, false);
});

test('closing and reopening a move panel invalidates old lists even at the same destination', async () => {
  const state = fixture(); await state.openMovePicker(file); const old = deferred();
  state.gateway.list = () => old.promise;
  const listing = state.loadMoveDirectory(); await new Promise(resolve => setImmediate(resolve));
  state.close(); state.gateway.list = async () => ready([directory('new-session')]);
  await state.openMovePicker({ ...file, name: 'new.txt', path: `${root}/new.txt` });
  old.resolve(ready([directory('old-session')])); await listing;
  assert.equal(state.moveEntries[0].name, 'new-session');
});

test('a stale list failure cannot stop a newer spinner or inject its error', async () => {
  const state = fixture(); await state.openMovePicker(file);
  const first = deferred(); const second = deferred();
  state.gateway.list = path => path.endsWith('/one') ? first.promise : second.promise;
  state.movePath = `${root}/one`; const oldListing = state.loadMoveDirectory();
  await new Promise(resolve => setImmediate(resolve));
  state.movePath = `${root}/two`; const newListing = state.loadMoveDirectory();
  await new Promise(resolve => setImmediate(resolve));
  first.reject(new Error('obsolete transport error')); await oldListing;
  assert.equal(state.moveLoading, true);
  assert.equal(state.moveReason, '');
  second.resolve(ready([])); await newListing;
  assert.equal(state.moveLoading, false);
});

test('cancel or destination change during submit authentication never dispatches a move', async () => {
  for (const invalidate of [state => state.close(), state => { state.movePath = `${root}/other`; },
    state => { state.fileActionGeneration++; }, state => { state.connected = false; }]) {
    const state = fixture(); await state.openMovePicker(file); state.movePath = `${root}/destination`;
    state.folderLockEnabled = true; state.lockedFolderPaths = [root];
    const auth = deferred(); state.authenticateFolderAccess = () => auth.promise;
    const pending = state.confirmMove(); invalidate(state); auth.resolve(true); await pending;
    assert.equal(state.mutations.length, 0);
    assert.equal(state.moveSubmitInFlight, false);
  }
});

test('duplicate move confirmations share one pending request', async () => {
  const state = fixture(); await state.openMovePicker(file); state.movePath = `${root}/destination`;
  state.folderLockEnabled = true; state.lockedFolderPaths = [root];
  const auth = deferred(); state.authCalls = 0;
  state.authenticateFolderAccess = () => { state.authCalls++; return auth.promise; };
  const first = state.confirmMove(); const second = state.confirmMove();
  assert.equal(state.authCalls, 1);
  auth.resolve(true); await Promise.all([first, second]);
  assert.equal(state.mutations.length, 1);
});

test('closing during destination authentication also cancels the pending move', async () => {
  const state = fixture(); await state.openMovePicker(file);
  const lockedDestination = '/tailnet/device/locked-dest';
  state.movePath = lockedDestination;
  state.folderLockEnabled = true; state.lockedFolderPaths = [lockedDestination];
  const auth = deferred(); state.authenticateFolderAccess = () => auth.promise;
  const pending = state.confirmMove(); await new Promise(resolve => setImmediate(resolve));
  state.close(); auth.resolve(true); await pending;
  assert.equal(state.mutations.length, 0);
  assert.equal(state.moveSubmitInFlight, false);
});

test('directory failures prevent destination confirmation and a successful retry clears the reason', async () => {
  const state = fixture(); await state.openMovePicker(file); state.movePath = `${root}/destination`;
  state.gateway.list = async () => ({ state: 'failed', entries: [], reason: 'permission_denied' });
  await state.loadMoveDirectory(); await state.confirmMove();
  assert.equal(state.mutations.length, 0);
  assert.equal(state.moveReason, 'permission_denied');
  state.gateway.list = async () => ready([]);
  await state.loadMoveDirectory(); assert.equal(state.moveReason, '');
  await state.confirmMove(); assert.equal(state.mutations.length, 1);
});

test('move destinations allow same-share or cross-share folders and exclude virtual roots, self and descendants', async () => {
  const state = fixture(); await state.openMovePicker(directory('source'));
  for (const path of ['/', '/tailnet', '/other/share', `${root}/source`, `${root}/source/child`]) {
    assert.equal(state.validMoveDestination(path), false, path);
    state.movePath = path; await state.confirmMove();
  }
  assert.equal(state.mutations.length, 0);
  for (const path of [`${root}/another`, '/tailnet/device/other-share', '/tailnet/other-device/share']) {
    assert.equal(state.validMoveDestination(path), true, path);
  }
  const flush = () => new Promise(resolve => setImmediate(resolve));
  state.movePath = root;
  state.moveLoading = false;
  state.moveGoUp();
  await flush();
  assert.equal(state.movePath, '/tailnet/device');
  state.moveGoUp();
  await flush();
  assert.equal(state.movePath, '/tailnet');
  state.moveGoUp();
  await flush();
  assert.equal(state.movePath, '/');
  state.moveGoUp();
  await flush();
  assert.equal(state.movePath, '/');
});
