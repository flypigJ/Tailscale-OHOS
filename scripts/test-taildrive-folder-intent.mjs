import assert from 'node:assert/strict';
import test from 'node:test';
import { loadEtsModules } from './helpers/ets-vm-loader.mjs';

const { TaildriveSessionController } = loadEtsModules(['services/TaildriveSessionController']);
const deferred = () => { let resolve; const promise = new Promise(yes => { resolve = yes; }); return { promise, resolve }; };
const flush = () => new Promise(resolve => setImmediate(resolve));
const shareRoot = '/tailnet/device/share';

function fixture() {
  const state = {
    path: `${shareRoot}/one`, connected: true, browserVisible: true, standalone: true, filesTabActive: true,
    appInForeground: true, appLockActive: false, folderLockEnabled: true, lockedFolderPaths: [shareRoot],
    folderAccessGrants: [], folderAccessAuthInFlight: false,
    busy: false, loading: false, selectionMode: false, fileActionGeneration: 1,
    folderDialogVisible: false, folderSubmitInFlight: false,
    editorName: '', editorOperation: '', editorPath: '', status: '', reason: '', retryAvailable: false,
    entries: [], mutations: [], authCalls: 0,
    authenticateFolderAccess: async () => { state.authCalls++; return true; }
  };
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
    isFolderAccessAuthInFlight: () => state.folderAccessAuthInFlight,
    setFolderAccessAuthInFlight: value => { state.folderAccessAuthInFlight = value; },
    getTargetRequestId: () => 0,
    getTargetMachineName: () => '',
    getPath: () => state.path,
    getEntries: () => state.entries,
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
    isFolderDialogVisible: () => state.folderDialogVisible,
    setFolderDialogVisible: value => { state.folderDialogVisible = value; },
    isFolderSubmitInFlight: () => state.folderSubmitInFlight,
    setFolderSubmitInFlight: value => { state.folderSubmitInFlight = value; },
    getEditorName: () => state.editorName,
    setEditorName: value => { state.editorName = value; },
    getEditorOperation: () => state.editorOperation,
    setEditorOperation: value => { state.editorOperation = value; },
    getEditorPath: () => state.editorPath,
    setEditorPath: value => { state.editorPath = value; },
    localizedNewFolderName: () => 'New folder',
    publishUiBackState() {},
    recordSecurityDiagnostic() {},
    delayIndicator: async () => {},
    applyListResult() {},
    authenticateFolderAccess: () => state.authenticateFolderAccess(),
    gatewayList: async reqPath => ({ state: 'ready', reason: '', path: reqPath, entries: [] }),
    gatewayMutate: async request => {
      state.mutations.push(request);
      return { state: 'completed', reason: '' };
    }
  });
  for (const name of ['createFolder', 'submitFolderDialog', 'closeFolderDialog', 'folderDialogContextCurrent']) {
    state[name] = (...args) => controller[name](...args);
  }
  return state;
}

test('a valid folder submission retains its opened directory and existing mutation protocol', async () => {
  const state = fixture(); state.createFolder(); state.editorName = 'Reports';
  await state.submitFolderDialog();
  assert.equal(state.mutations.length, 1);
  assert.equal(state.mutations[0].operation, 'mkdir');
  assert.equal(state.mutations[0].path, `${shareRoot}/one/Reports`);
  assert.equal(state.folderDialogVisible, false);
});

test('authentication finishing in another directory cannot create there or discard the typed name', async () => {
  const state = fixture(); const auth = deferred();
  state.authenticateFolderAccess = () => auth.promise;
  state.createFolder(); state.editorName = 'Reports';
  const pending = state.submitFolderDialog(); await flush();
  state.path = `${shareRoot}/two`; state.fileActionGeneration++;
  auth.resolve(true); await pending;
  assert.equal(state.mutations.length, 0);
  assert.equal(state.editorName, 'Reports');
  assert.equal(state.folderDialogVisible, true);
  assert.equal(state.folderSubmitInFlight, false);
});

test('returning to the same path or changing authorization cannot revive an old folder submission', async () => {
  for (const invalidate of [
    state => { state.path = `${shareRoot}/two`; state.fileActionGeneration++; state.path = `${shareRoot}/one`; state.fileActionGeneration++; },
    state => { state.appLockActive = true; }, state => { state.connected = false; },
    state => { state.fileActionGeneration++; }
  ]) {
    const state = fixture(); const auth = deferred(); state.authenticateFolderAccess = () => auth.promise;
    state.createFolder(); state.editorName = 'Reports';
    const pending = state.submitFolderDialog(); await flush(); invalidate(state);
    auth.resolve(true); await pending;
    assert.equal(state.mutations.length, 0);
    assert.equal(state.editorName, 'Reports');
  }
});

test('closing the folder dialog cancels an awaiting submission', async () => {
  const state = fixture(); const auth = deferred(); state.authenticateFolderAccess = () => auth.promise;
  state.createFolder(); const pending = state.submitFolderDialog(); await flush();
  state.closeFolderDialog(); auth.resolve(true); await pending;
  assert.equal(state.mutations.length, 0);
  assert.equal(state.folderDialogVisible, false);
});

test('button and keyboard confirmation share one pending submission', async () => {
  const state = fixture(); const auth = deferred();
  state.authenticateFolderAccess = () => { state.authCalls++; return auth.promise; };
  state.createFolder();
  const first = state.submitFolderDialog(); const second = state.submitFolderDialog();
  assert.equal(state.authCalls, 1);
  auth.resolve(true); await Promise.all([first, second]);
  assert.equal(state.mutations.length, 1);
  assert.equal(state.folderSubmitInFlight, false);
});
