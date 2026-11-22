import assert from 'node:assert/strict';
import test from 'node:test';
import { loadEtsModules } from './helpers/ets-vm-loader.mjs';

const { TaildriveSessionController } = loadEtsModules(['services/TaildriveSessionController']);
const deferred = () => { let resolve; const promise = new Promise(yes => { resolve = yes; }); return { promise, resolve }; };
const shareRoot = '/tailnet/device/share';
const entry = { name: 'old.txt', path: `${shareRoot}/old.txt`, kind: 'file', size: 1, modifiedAtMs: 0 };

function fixture() {
  const state = {
    path: shareRoot, fileActionGeneration: 1,
    connected: true, busy: false, loading: false, browserVisible: true, standalone: true, filesTabActive: true,
    appInForeground: true, appLockActive: false,
    folderLockEnabled: true, lockedFolderPaths: [shareRoot], folderAccessGrants: [], folderAccessAuthInFlight: false,
    selectionMode: false, editorVisible: false, editorSubmitInFlight: false,
    editorName: '', editorPath: '', editorOperation: '', status: '', reason: '', retryAvailable: false,
    mutations: [], authCalls: 0,
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
    isEditorVisible: () => state.editorVisible,
    setEditorVisible: value => { state.editorVisible = value; },
    isEditorSubmitInFlight: () => state.editorSubmitInFlight,
    setEditorSubmitInFlight: value => { state.editorSubmitInFlight = value; },
    getEditorName: () => state.editorName,
    setEditorName: value => { state.editorName = value; },
    getEditorOperation: () => state.editorOperation,
    setEditorOperation: value => { state.editorOperation = value; },
    getEditorPath: () => state.editorPath,
    setEditorPath: value => { state.editorPath = value; },
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
  for (const name of ['renameEntry', 'submitEditor', 'editorContextCurrent']) {
    state[name] = (...args) => controller[name](...args);
  }
  return state;
}

test('rename keeps the original source and existing rename protocol', async () => {
  const state = fixture(); state.renameEntry(entry); state.editorName = 'new.txt';
  await state.submitEditor();
  assert.equal(state.mutations.length, 1);
  assert.deepEqual(JSON.parse(JSON.stringify(state.mutations[0])), {
    operation: 'rename', path: entry.path, newPath: '/tailnet/device/share/new.txt'
  });
  assert.equal(state.editorVisible, false);
});

test('cancelled or dismissed rename cannot submit a late authentication result', async () => {
  const state = fixture(); const auth = deferred();
  state.authenticateFolderAccess = () => auth.promise;
  state.renameEntry(entry); state.editorName = 'new.txt';
  const pending = state.submitEditor();
  state.editorVisible = false;
  auth.resolve(true); await pending;
  assert.equal(state.mutations.length, 0);
  assert.equal(state.editorSubmitInFlight, false);
});

test('directory, page and authorization changes invalidate pending rename without losing its draft', async () => {
  for (const invalidate of [
    state => { state.path = '/tailnet/device/another'; state.fileActionGeneration++; },
    state => { state.path = '/other'; state.fileActionGeneration++; state.path = '/tailnet/device/share'; state.fileActionGeneration++; },
    state => { state.connected = false; }, state => { state.appLockActive = true; },
    state => { state.filesTabActive = false; }, state => { state.browserVisible = false; },
    state => { state.fileActionGeneration++; }
  ]) {
    const state = fixture(); const auth = deferred(); state.authenticateFolderAccess = () => auth.promise;
    state.renameEntry(entry); state.editorName = 'new.txt';
    const pending = state.submitEditor(); invalidate(state); auth.resolve(true); await pending;
    assert.equal(state.mutations.length, 0);
    assert.equal(state.editorName, 'new.txt');
    assert.equal(state.editorVisible, true);
  }
});

test('duplicate button and IME confirmation produce one rename', async () => {
  const state = fixture(); const auth = deferred();
  state.authenticateFolderAccess = () => { state.authCalls++; return auth.promise; };
  state.renameEntry(entry); state.editorName = 'new.txt';
  const first = state.submitEditor(); const second = state.submitEditor();
  assert.equal(state.authCalls, 1);
  auth.resolve(true); await Promise.all([first, second]);
  assert.equal(state.mutations.length, 1);
  assert.equal(state.editorSubmitInFlight, false);
});

test('a pending rename cannot be retargeted by opening another source', async () => {
  const state = fixture(); const auth = deferred(); state.authenticateFolderAccess = () => auth.promise;
  state.renameEntry(entry); state.editorName = 'new.txt';
  const pending = state.submitEditor();
  state.renameEntry({ name: 'another.txt', path: '/tailnet/device/share/another.txt', kind: 'file', size: 1, modifiedAtMs: 0 });
  auth.resolve(true); await pending;
  assert.equal(state.mutations.length, 1);
  assert.equal(state.mutations[0].path, entry.path);
});

test('refused authentication preserves an editable draft and allows a later explicit retry', async () => {
  const state = fixture(); state.renameEntry(entry); state.editorName = 'new.txt';
  state.authenticateFolderAccess = async () => false;
  await state.submitEditor();
  assert.equal(state.mutations.length, 0);
  assert.equal(state.editorName, 'new.txt');
  assert.equal(state.editorVisible, true);
  assert.equal(state.editorSubmitInFlight, false);
  state.authenticateFolderAccess = async () => true;
  await state.submitEditor();
  assert.equal(state.mutations.length, 1);
});
