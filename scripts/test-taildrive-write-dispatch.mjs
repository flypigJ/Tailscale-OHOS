import assert from 'node:assert/strict';
import test from 'node:test';
import { loadEtsModules } from './helpers/ets-vm-loader.mjs';

const { TaildriveSessionController } = loadEtsModules(['services/TaildriveSessionController']);
const root = '/tailnet/device/share';
const request = () => ({ operation: 'rename', path: `${root}/one`, newPath: `${root}/two` });
const entry = name => ({ name, path: `${root}/${name}`, kind: 'file', size: 1, modifiedAtMs: 0 });
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; };
const flush = () => new Promise(resolve => setImmediate(resolve));

function fixture() {
  const state = {
    path: root, fileActionGeneration: 1, connected: true, browserVisible: true, appInForeground: true,
    appLockActive: false, standalone: true, filesTabActive: true,
    folderLockEnabled: true, lockedFolderPaths: [root], folderAccessGrants: [], folderAccessAuthInFlight: false,
    selectionMode: true, selectedPaths: [],
    busy: false, loading: false, status: '', reason: '', retryAvailable: false, refreshes: 0,
    mutations: [], uploads: [], pollStarts: 0, pollStops: 0, selectionExits: 0,
    overwritePrompted: undefined,
    authenticateFolderAccess: async () => true,
    onRefreshApplied() {}
  };
  state.gateway = {
    async mutate(value) { state.mutations.push(value); return { state: 'completed', reason: '' }; },
    async upload(value) {
      state.uploads.push(value);
      return {
        requestId: value.requestId, direction: 'upload', state: 'completed', reason: '',
        remotePath: value.remotePath, localPath: value.localPath, fileName: 'file',
        bytes: 1, totalBytes: 1, startedAtMs: 0, completedAtMs: 1
      };
    }
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
    isSelectionMode: () => state.selectionMode,
    setSelectionMode: value => {
      if (!value) {
        state.selectionExits++;
      }
      state.selectionMode = value;
    },
    isDragSelecting: () => false,
    setDragSelecting() {},
    getSelectedPaths: () => state.selectedPaths,
    setSelectedPaths: paths => { state.selectedPaths = paths; },
    isBusy: () => state.busy,
    setBusy: value => { state.busy = value; },
    setLoading: value => { state.loading = value; },
    setReason: value => { state.reason = value; },
    getStatus: () => state.status,
    setStatus: value => { state.status = value; },
    showTransientStatus: value => { state.status = value; },
    setRetryAvailable: value => { state.retryAvailable = value; },
    getFileActionGeneration: () => state.fileActionGeneration,
    stagingRoot: () => '/cache',
    startTransferPolling: () => { state.pollStarts++; },
    stopTransferPolling: () => { state.pollStops++; },
    setTransfer() {},
    publishTransferCompletion: async () => {},
    clearTransferProgress: async () => {},
    stopDragAutoScroll() {},
    rebuildListDataSource() {},
    publishUiBackState() {},
    recordSecurityDiagnostic() {},
    saveLockedFolderPaths: async () => {},
    filterProtectedThumbnails() {},
    getCachedEntries: () => [],
    setCachedEntries() {},
    purgeGatewayPreviewCaches() {},
    delayIndicator: async () => {},
    applyListResult() {
      state.refreshes++;
      state.onRefreshApplied();
    },
    showConfirmationPrompt() {
      state.overwritePrompted = true;
    },
    authenticateFolderAccess: () => state.authenticateFolderAccess(),
    gatewayList: async reqPath => ({ state: 'ready', reason: '', path: reqPath, entries: [] }),
    gatewayCleanupStaged() {},
    gatewayMutate: value => state.gateway.mutate(value),
    gatewayUpload: value => state.gateway.upload(value)
  });
  controller.pendingUpload = { path: '/cache/file', name: 'file', requestDir: '/cache', modifiedAtMs: 1 };
  controller.pendingUploadPath = `${root}/file`;
  Object.defineProperties(state, {
    retryKind: {
      get: () => controller.retryKind,
      set(value) { controller.retryKind = value; }
    },
    retryMutation: { get: () => controller.retryMutation },
    pendingUpload: {
      get: () => controller.pendingUpload,
      set(value) { controller.pendingUpload = value; }
    },
    pendingUploadPath: {
      get: () => controller.pendingUploadPath,
      set(value) { controller.pendingUploadPath = value; }
    }
  });
  for (const name of ['executeMutation', 'deleteSelectedEntries', 'executeUpload']) {
    state[name] = (...args) => controller[name](...args);
  }
  return state;
}

test('mutation claims the busy state before authorization and rejects a concurrent retry', async () => {
  const state = fixture(); const auth = deferred(); state.authenticateFolderAccess = () => auth.promise;
  const first = state.executeMutation(request(), 'renaming', 'done');
  assert.equal(state.busy, true);
  const second = state.executeMutation(request(), 'renaming', 'done');
  auth.resolve(true); await Promise.all([first, second]);
  assert.equal(state.mutations.length, 1); assert.equal(state.busy, false);
});

test('authorization returning after directory, lock, connection or page changes cannot dispatch writes', async () => {
  for (const invalidate of [
    state => { state.path = '/another'; state.fileActionGeneration++; },
    state => { state.fileActionGeneration++; }, state => { state.appLockActive = true; },
    state => { state.filesTabActive = false; }, state => { state.connected = false; }, state => { state.browserVisible = false; }
  ]) {
    const state = fixture(); const auth = deferred(); state.authenticateFolderAccess = () => auth.promise;
    const pending = state.executeMutation(request(), 'renaming', 'done'); invalidate(state);
    auth.resolve(true); await pending;
    assert.equal(state.mutations.length, 0); assert.equal(state.busy, false);
  }
});

test('the authorized mutation uses an immutable request snapshot', async () => {
  const state = fixture(); const auth = deferred(); state.authenticateFolderAccess = () => auth.promise;
  const original = request(); const pending = state.executeMutation(original, 'renaming', 'done');
  original.path = `${root}/other`; original.newPath = `${root}/unapproved`; auth.resolve(true); await pending;
  assert.deepEqual(JSON.parse(JSON.stringify(state.mutations[0])), request());
});

test('authentication exceptions release busy without manufacturing a network-write retry', async () => {
  const state = fixture(); state.authenticateFolderAccess = async () => { throw new Error('sensitive auth error'); };
  await state.executeMutation(request(), 'renaming', 'done');
  assert.equal(state.busy, false); assert.equal(state.retryKind, ''); assert.equal(state.mutations.length, 0);
  assert.equal(state.status, 'folder_authentication_failed');
});

test('batch and single mutations share the same authorization window', async () => {
  const state = fixture(); const auth = deferred(); state.authenticateFolderAccess = () => auth.promise;
  const batch = state.deleteSelectedEntries([entry('one'), entry('two')]);
  await state.executeMutation(request(), 'renaming', 'done');
  auth.resolve(true); await batch;
  assert.deepEqual(state.mutations.map(value => value.operation), ['delete', 'delete']);
  assert.equal(state.busy, false);
});

test('batch authorization invalidation stops before any deletion and releases busy', async () => {
  const state = fixture(); const auth = deferred(); state.authenticateFolderAccess = () => auth.promise;
  const pending = state.deleteSelectedEntries([entry('one'), entry('two')]);
  state.fileActionGeneration++; auth.resolve(true); await pending;
  assert.equal(state.mutations.length, 0); assert.equal(state.busy, false);
});

test('batch deletion snapshots paths before waiting for authentication', async () => {
  const state = fixture(); const auth = deferred(); state.authenticateFolderAccess = () => auth.promise;
  const selected = [entry('one')]; const pending = state.deleteSelectedEntries(selected);
  selected[0].path = `${root}/other`; selected.push(entry('two')); auth.resolve(true); await pending;
  assert.deepEqual(state.mutations.map(value => value.path), [`${root}/one`]);
});

test('upload authorization blocks mutation dispatch and duplicate upload confirmation', async () => {
  const state = fixture(); const auth = deferred(); state.authenticateFolderAccess = () => auth.promise;
  const upload = state.executeUpload(false); const duplicate = state.executeUpload(false);
  await state.executeMutation(request(), 'renaming', 'done'); auth.resolve(true);
  await Promise.all([upload, duplicate]);
  assert.equal(state.mutations.length, 0); assert.equal(state.uploads.length, 1);
  assert.equal(state.pollStarts, 1); assert.equal(state.pollStops, 1); assert.equal(state.busy, false);
});

test('cancelled upload authentication retains its staging and retry without starting polling', async () => {
  const state = fixture(); state.retryKind = 'upload'; state.authenticateFolderAccess = async () => false;
  const staged = state.pendingUpload; await state.executeUpload(false);
  assert.equal(state.pendingUpload, staged); assert.equal(state.retryKind, 'upload');
  assert.equal(state.pollStarts, 0); assert.equal(state.pollStops, 0); assert.equal(state.busy, false);
});

test('upload captures its destination and stops when the context changes during authentication', async () => {
  const state = fixture(); const auth = deferred(); state.authenticateFolderAccess = () => auth.promise;
  const pending = state.executeUpload(false); state.path = '/another'; state.fileActionGeneration++;
  auth.resolve(true); await pending;
  assert.equal(state.uploads.length, 0); assert.ok(state.pendingUpload); assert.equal(state.busy, false);
});

test('a dispatched network failure still retains the original mutation for explicit retry', async () => {
  const state = fixture(); state.gateway.mutate = async value => { state.mutations.push(value); throw new Error('network'); };
  await state.executeMutation(request(), 'renaming', 'done');
  assert.equal(state.retryKind, 'mutation'); assert.equal(state.retryMutation.path, `${root}/one`);
  assert.equal(state.status, 'mutation_failed'); assert.equal(state.busy, false);
});

test('a started batch retains its approved sequence through a later context change', async () => {
  const state = fixture(); const first = deferred();
  state.gateway.mutate = async value => { state.mutations.push(value); return state.mutations.length === 1 ? first.promise : { state: 'completed', reason: '' }; };
  const pending = state.deleteSelectedEntries([entry('one'), entry('two')]); await flush();
  state.fileActionGeneration++; first.resolve({ state: 'completed', reason: '' }); await pending;
  assert.deepEqual(state.mutations.map(value => value.path), [`${root}/one`, `${root}/two`]);
});

test('a mutation authorization also blocks batch and upload entry points', async () => {
  const state = fixture(); const auth = deferred(); state.authenticateFolderAccess = () => auth.promise;
  const pending = state.executeMutation(request(), 'renaming', 'done');
  await state.deleteSelectedEntries([entry('one')]); await state.executeUpload(false);
  auth.resolve(true); await pending;
  assert.equal(state.mutations.length, 1); assert.equal(state.mutations[0].operation, 'rename');
  assert.equal(state.uploads.length, 0);
});

test('an empty upload callback cannot overwrite another operation while busy', async () => {
  const state = fixture(); state.busy = true; state.status = 'renaming'; state.retryKind = 'mutation';
  state.pendingUpload = undefined; state.pendingUploadPath = '';
  await state.executeUpload(false);
  assert.equal(state.busy, true); assert.equal(state.status, 'renaming'); assert.equal(state.retryKind, 'mutation');
});

test('batch authorization exceptions release busy and leave the selection unconsumed', async () => {
  const state = fixture(); state.authenticateFolderAccess = async () => { throw new Error('auth'); };
  await state.deleteSelectedEntries([entry('one')]);
  assert.equal(state.busy, false); assert.equal(state.selectionExits, 0); assert.equal(state.mutations.length, 0);
  assert.equal(state.status, 'folder_authentication_failed');
});

test('upload authorization exceptions retain staging and never start transfer polling', async () => {
  const state = fixture(); state.authenticateFolderAccess = async () => { throw new Error('auth'); };
  const staged = state.pendingUpload; await state.executeUpload(false);
  assert.equal(state.busy, false); assert.equal(state.pendingUpload, staged);
  assert.equal(state.pollStarts, 0); assert.equal(state.pollStops, 0); assert.equal(state.uploads.length, 0);
  assert.equal(state.status, 'folder_authentication_failed');
});

test('a late mutation conflict cannot open a replacement dialog in a different context', async () => {
  const state = fixture(); const result = deferred(); state.gateway.mutate = () => result.promise;
  const pending = state.executeMutation(request(), 'renaming', 'done'); await flush();
  state.fileActionGeneration++; result.resolve({ state: 'failed', reason: 'already_exists' }); await pending;
  assert.equal(state.overwritePrompted, undefined);
});

test('a late upload conflict retains staging without opening a replacement dialog in a different context', async () => {
  const state = fixture(); const staged = state.pendingUpload; const result = deferred(); state.gateway.upload = () => result.promise;
  const pending = state.executeUpload(false); await flush();
  state.fileActionGeneration++; result.resolve({ state: 'failed', reason: 'file_exists' }); await pending;
  assert.equal(state.overwritePrompted, undefined); assert.equal(state.pendingUpload, staged);
});

test('a current mutation conflict still presents the existing replacement confirmation', async () => {
  const state = fixture(); state.gateway.mutate = async () => ({ state: 'failed', reason: 'already_exists' });
  await state.executeMutation(request(), 'renaming', 'done'); assert.equal(state.overwritePrompted, true);
});

test('deleteSelectedEntries refreshes directory and exits selection while preserving failure status after partial batch deletion', async () => {
  const state = fixture();
  let calls = 0;
  state.gateway.mutate = async req => {
    calls++;
    state.mutations.push(req);
    if (calls === 1) {
      return { state: 'completed', reason: '' };
    }
    return { state: 'failed', reason: 'permission_denied' };
  };
  state.onRefreshApplied = () => { state.status = ''; };
  await state.deleteSelectedEntries([entry('first.txt'), entry('second.txt')]);
  assert.equal(state.mutations.length, 2);
  assert.equal(state.selectionExits, 1, 'exits selection mode when earlier items were deleted');
  assert.equal(state.refreshes, 1, 'refreshes directory so deleted item #1 does not stay as a ghost entry');
  assert.equal(state.status, 'permission_denied', 'preserves batch failure status across refresh');
  assert.equal(state.busy, false);

  // Also verify thrown exception on item #2 after item #1 succeeded refreshes and keeps delete_failed.
  const stateThrow = fixture();
  let throwCalls = 0;
  stateThrow.gateway.mutate = async req => {
    throwCalls++;
    stateThrow.mutations.push(req);
    if (throwCalls === 1) {
      return { state: 'completed', reason: '' };
    }
    throw new Error('ipc_lost');
  };
  stateThrow.onRefreshApplied = () => { stateThrow.status = ''; };
  await stateThrow.deleteSelectedEntries([entry('first.txt'), entry('second.txt')]);
  assert.equal(stateThrow.selectionExits, 1);
  assert.equal(stateThrow.refreshes, 1);
  assert.equal(stateThrow.status, 'delete_failed');
  assert.equal(stateThrow.busy, false);
});
