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
const root = '/tailnet/share/original';
const stagedFile = () => ({ name: 'report.txt', path: '/cache/upload/report.txt', requestDir: '/cache/upload', modifiedAtMs: 10 });

function fixture() {
  const current = {
    path: root, connected: true, browserVisible: true, standalone: true, filesTabActive: true,
    appInForeground: true, appLockActive: false, folderLockEnabled: false, lockedFolderPaths: [],
    folderAccessGrants: [], folderAccessAuthInFlight: false,
    busy: false, loading: false, fileActionGeneration: 1,
    status: '', reason: '', retryAvailable: false,
    pickerCount: 0, stageCount: 0, uploads: [], cleaned: [],
    pick: async () => ['file://picked'],
    stage: async () => stagedFile()
  };
  const controller = new TaildriveSessionController({
    isConnected: () => current.connected,
    isStandalone: () => current.standalone,
    isFilesTabActive: () => current.filesTabActive,
    isBrowserVisible: () => current.browserVisible,
    isAppInForeground: () => current.appInForeground,
    isAppLockActive: () => current.appLockActive,
    isFolderLockEnabled: () => current.folderLockEnabled,
    getLockedFolderPaths: () => current.lockedFolderPaths,
    setLockedFolderPaths: paths => { current.lockedFolderPaths = paths; },
    getFolderAccessGrants: () => current.folderAccessGrants,
    setFolderAccessGrants: grants => { current.folderAccessGrants = grants; },
    isFolderAccessAuthInFlight: () => current.folderAccessAuthInFlight,
    setFolderAccessAuthInFlight: value => { current.folderAccessAuthInFlight = value; },
    getTargetRequestId: () => 0,
    getTargetMachineName: () => '',
    getPath: () => current.path,
    isBusy: () => current.busy,
    setBusy: value => { current.busy = value; },
    setLoading: value => { current.loading = value; },
    setReason: value => { current.reason = value; },
    getStatus: () => current.status,
    setStatus: value => { current.status = value; },
    showTransientStatus: value => { current.status = value; },
    setRetryAvailable: value => { current.retryAvailable = value; },
    getFileActionGeneration: () => current.fileActionGeneration,
    stagingRoot: () => '/cache',
    ensureStagingDirectory() {},
    pickUploadDocumentUris: async () => { current.pickerCount++; return current.pick(); },
    startTransferPolling() {},
    stopTransferPolling() {},
    setTransfer() {},
    publishTransferCompletion: async () => {},
    clearTransferProgress: async () => {},
    delayIndicator: async () => {},
    applyListResult() {},
    gatewayList: async reqPath => ({ state: 'ready', reason: '', path: reqPath, entries: [] }),
    gatewayStageUpload: async () => { current.stageCount++; return current.stage(); },
    gatewayCleanupStaged: file => { current.cleaned.push(file); },
    gatewayUpload: async req => {
      current.uploads.push({ path: req.remotePath, overwrite: Boolean(req.overwrite), localPath: req.localPath });
      return {
        requestId: req.requestId, direction: 'upload', state: 'completed', reason: '',
        remotePath: req.remotePath, localPath: req.localPath, fileName: 'report.txt',
        bytes: 10, totalBytes: 10, startedAtMs: 0, completedAtMs: 1
      };
    }
  });
  Object.defineProperties(current, {
    uploadSelectionInFlight: { get: () => controller.uploadSelectionInFlight },
    pendingUpload: { get: () => controller.pendingUpload }
  });
  for (const name of ['selectUpload', 'canUseUploadSelection']) {
    current[name] = (...args) => controller[name](...args);
  }
  return current;
}

test('a valid selection uploads to its original directory and releases preparing state', async () => {
  const current = fixture();
  await current.selectUpload();
  assert.equal(current.uploads.length, 1);
  assert.equal(current.uploads[0].path, `${root}/report.txt`);
  assert.equal(current.uploads[0].overwrite, false);
  assert.equal(current.busy, false);
  assert.equal(current.uploadSelectionInFlight, false);
});

test('changing directory while the picker is open never stages or uploads to the new directory', async () => {
  const current = fixture();
  const pick = deferred();
  current.pick = () => pick.promise;
  const pending = current.selectUpload();
  await flush();
  current.path = '/tailnet/share/other';
  current.fileActionGeneration++;
  pick.resolve(['file://picked']);
  await pending;
  assert.equal(current.stageCount, 0);
  assert.equal(current.uploads.length, 0);
  assert.equal(current.uploadSelectionInFlight, false);
});

test('invalidated staging cleans only its temporary copy and never dispatches an upload', async () => {
  for (const invalidate of [
    state => { state.path = '/tailnet/share/other'; }, state => { state.connected = false; },
    state => { state.appLockActive = true; }, state => { state.browserVisible = false; },
    state => { state.filesTabActive = false; }, state => { state.fileActionGeneration++; }
  ]) {
    const current = fixture();
    const staged = deferred();
    const copy = stagedFile();
    current.stage = () => staged.promise;
    const pending = current.selectUpload();
    await flush();
    assert.equal(current.status, 'preparing_upload');
    assert.equal(current.busy, true);
    invalidate(current);
    staged.resolve(copy);
    await pending;
    assert.deepEqual(current.cleaned, [copy]);
    assert.equal(current.uploads.length, 0);
    assert.equal(current.pendingUpload, undefined);
    assert.equal(current.busy, false);
    assert.equal(current.uploadSelectionInFlight, false);
  }
});

test('a picker return and staging copy cannot admit overlapping upload selections', async () => {
  const current = fixture();
  const pick = deferred();
  const staged = deferred();
  current.pick = () => pick.promise;
  current.stage = () => staged.promise;
  const pending = current.selectUpload();
  await flush();
  await current.selectUpload();
  assert.equal(current.pickerCount, 1);
  pick.resolve(['file://picked']);
  await flush();
  await current.selectUpload();
  assert.equal(current.stageCount, 1);
  staged.resolve(stagedFile());
  await pending;
  assert.equal(current.uploads.length, 1);
});

test('copy failure and picker cancellation release busy state without discarding an unrelated operation', async () => {
  const current = fixture();
  current.stage = async () => { throw new Error('copy failed'); };
  await current.selectUpload();
  assert.equal(current.status, 'upload_failed');
  assert.equal(current.busy, false);
  assert.equal(current.uploadSelectionInFlight, false);
  const pick = deferred();
  current.pick = () => pick.promise;
  const pending = current.selectUpload();
  await flush();
  current.busy = true;
  pick.resolve([]);
  await pending;
  assert.equal(current.busy, true);
  assert.equal(current.uploadSelectionInFlight, false);
});
