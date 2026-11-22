import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { loadEtsModules } from './helpers/ets-vm-loader.mjs';

const { TaildriveSessionController } = loadEtsModules(['services/TaildriveSessionController']);
const browserSource = readFileSync(
  new URL('../entry/src/main/ets/components/TaildriveBrowser.ets', import.meta.url),
  'utf8'
);
const root = '/tailnet/device/share';
const entry = name => ({ name, path: `${root}/${name}`, kind: 'file', size: 1, modifiedAtMs: 0 });
const mutation = () => ({ operation: 'rename', path: `${root}/one`, newPath: `${root}/two` });
const flush = () => new Promise(resolve => setImmediate(resolve));

function fixture() {
  const initialSelection = [entry('one'), entry('two')];
  const state = {
    path: root, fileActionGeneration: 1,
    connected: true, browserVisible: true, appInForeground: true, appLockActive: false,
    standalone: true, filesTabActive: true, busy: false, loading: false,
    folderLockEnabled: false, lockedFolderPaths: [], folderAccessGrants: [], folderAccessAuthInFlight: false,
    selectionMode: false,
    entries: initialSelection,
    selectedPaths: initialSelection.map(item => item.path),
    dialogs: [], deletes: [], batches: [], mutations: [], uploads: [], cleanups: [],
    status: '', reason: '', retryAvailable: false
  };
  let currentBatch = null;
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
    getSelectedPaths: () => state.selectedPaths,
    setSelectedPaths: paths => { state.selectedPaths = paths; },
    isSelectionMode: () => state.selectionMode,
    setSelectionMode: value => { state.selectionMode = value; },
    isDragSelecting: () => false,
    setDragSelecting() {},
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
    stopDragAutoScroll() {},
    rebuildListDataSource() {},
    publishUiBackState() {},
    recordSecurityDiagnostic() {},
    delayIndicator: async () => {},
    applyListResult() {},
    startTransferPolling() {},
    stopTransferPolling() {},
    setTransfer() {},
    publishTransferCompletion: async () => {},
    clearTransferProgress: async () => {},
    gatewayList: async reqPath => ({ state: 'ready', reason: '', path: reqPath, entries: [] }),
    gatewayMutate: async req => {
      if (req.operation === 'delete') {
        if (currentBatch !== null) {
          currentBatch.push(req.path);
        } else {
          state.deletes.push(req.path);
        }
      } else {
        state.mutations.push(req);
      }
      return { state: 'completed', reason: '' };
    },
    gatewayUpload: async req => {
      state.uploads.push(Boolean(req.overwrite));
      return {
        requestId: req.requestId, direction: 'upload', state: 'failed', reason: 'busy',
        remotePath: req.remotePath, localPath: req.localPath, fileName: 'file',
        bytes: 0, totalBytes: 1, startedAtMs: 0, completedAtMs: 0
      };
    },
    gatewayCleanupStaged: file => { state.cleanups.push(file); },
    showConfirmationPrompt(prompt) {
      state.dialogs.push({
        kind: prompt.kind,
        autoCancel: prompt.autoCancel,
        cancel: () => prompt.onDismiss(),
        onDidDisappear: () => prompt.onDismiss(),
        primaryButton: { action: () => prompt.onCancel() },
        secondaryButton: {
          async action() {
            const trackBatch = prompt.kind === 'delete_selected';
            if (trackBatch) {
              currentBatch = [];
            }
            prompt.onConfirm();
            await flush();
            await flush();
            if (trackBatch) {
              if (currentBatch.length > 0) {
                state.batches.push(currentBatch);
              }
              currentBatch = null;
            }
          }
        }
      });
    }
  });
  controller.pendingUpload = { name: 'file', path: '/cache/file', requestDir: '/cache', modifiedAtMs: 0 };
  controller.pendingUploadPath = `${root}/file`;
  Object.defineProperties(state, {
    selection: { get: () => state.entries },
    pendingUpload: {
      get: () => controller.pendingUpload,
      set(value) { controller.pendingUpload = value; }
    },
    pendingUploadPath: {
      get: () => controller.pendingUploadPath,
      set(value) { controller.pendingUploadPath = value; }
    }
  });
  for (const name of [
    'confirmDelete', 'confirmDeleteSelected', 'promptMutationOverwrite', 'promptUploadOverwrite'
  ]) {
    state[name] = (...args) => controller[name](...args);
  }
  return state;
}

test('TaildriveBrowser showConfirmationPrompt wires prompt cancel, dismiss and confirm callbacks cleanly', () => {
  assert.match(browserSource, /private showConfirmationPrompt\(prompt: TaildriveConfirmationPrompt\): void \{[\s\S]*?autoCancel: prompt\.autoCancel[\s\S]*?cancel: \(\) => \{ prompt\.onDismiss\(\); \}[\s\S]*?onDidDisappear: \(\) => \{ prompt\.onDismiss\(\); \}[\s\S]*?primaryButton:[\s\S]*?prompt\.onCancel\(\)[\s\S]*?secondaryButton:[\s\S]*?prompt\.onConfirm\(\)/);
});

test('delete confirmation accepts its original target once', async () => {
  const state = fixture(); state.confirmDelete(entry('one')); const dialog = state.dialogs.at(-1);
  await dialog.secondaryButton.action(); await dialog.secondaryButton.action();
  assert.deepEqual(state.deletes, [`${root}/one`]);
});

test('explicit and native cancellation invalidate delayed destructive callbacks', async () => {
  for (const cancel of [dialog => dialog.primaryButton.action(), dialog => dialog.cancel?.(), dialog => dialog.onDidDisappear?.()]) {
    const state = fixture(); state.confirmDelete(entry('one')); const dialog = state.dialogs.at(-1);
    cancel(dialog); await dialog.secondaryButton.action(); assert.equal(state.deletes.length, 0);
  }
});

test('directory, permission and visibility changes invalidate a displayed confirmation', async () => {
  for (const invalidate of [
    state => { state.path = '/another'; state.fileActionGeneration++; },
    state => { state.fileActionGeneration++; }, state => { state.appLockActive = true; },
    state => { state.filesTabActive = false; }, state => { state.connected = false; }, state => { state.browserVisible = false; }
  ]) {
    const state = fixture(); state.confirmDelete(entry('one')); const dialog = state.dialogs.at(-1);
    invalidate(state); await dialog.secondaryButton.action(); assert.equal(state.deletes.length, 0);
  }
});

test('a newer confirmation supersedes an older one and old cancellation cannot cancel the new one', async () => {
  const state = fixture(); state.confirmDelete(entry('one')); const old = state.dialogs.at(-1);
  state.confirmDelete(entry('two')); const current = state.dialogs.at(-1);
  old.primaryButton.action(); old.cancel?.(); old.onDidDisappear?.();
  await old.secondaryButton.action(); await current.secondaryButton.action();
  assert.deepEqual(state.deletes, [`${root}/two`]);
});

test('single and batch delete freeze targets when the confirmation is displayed', async () => {
  const state = fixture(); const original = entry('one'); state.confirmDelete(original);
  original.path = `${root}/changed`; await state.dialogs.at(-1).secondaryButton.action();
  assert.deepEqual(state.deletes, [`${root}/one`]);
  state.confirmDeleteSelected(); const batch = state.dialogs.at(-1); state.selection[0].path = `${root}/other`;
  await batch.secondaryButton.action(); assert.deepEqual(Array.from(state.batches[0]), [`${root}/one`, `${root}/two`]);
});

test('overwrite confirmation freezes the request and accepts replacement once', async () => {
  const state = fixture(); const request = mutation(); state.promptMutationOverwrite(request, 'renaming', 'done');
  const dialog = state.dialogs.at(-1); request.path = `${root}/changed`;
  await dialog.secondaryButton.action(); await dialog.secondaryButton.action();
  assert.equal(state.mutations.length, 1);
  assert.deepEqual(JSON.parse(JSON.stringify(state.mutations[0])), { ...mutation(), overwrite: true });
});

test('a vanished overwrite dialog cannot dispatch a replacement', async () => {
  const state = fixture(); state.promptMutationOverwrite(mutation(), 'renaming', 'done');
  const dialog = state.dialogs.at(-1); dialog.onDidDisappear?.(); await dialog.secondaryButton.action();
  assert.equal(state.mutations.length, 0);
});

test('an old upload overwrite dialog cannot clear or overwrite a newer staged file', async () => {
  const state = fixture(); state.promptUploadOverwrite('file'); const old = state.dialogs.at(-1);
  const replacement = { name: 'new', path: '/cache/new', requestDir: '/cache', modifiedAtMs: 2 };
  state.pendingUpload = replacement; state.pendingUploadPath = `${root}/new`;
  old.primaryButton.action(); await old.secondaryButton.action();
  assert.equal(state.pendingUpload, replacement); assert.equal(state.cleanups.length, 0); assert.equal(state.uploads.length, 0);
});

test('current upload replacement is accepted once and cancellation afterwards cannot delete its staging', async () => {
  const state = fixture(); const staged = state.pendingUpload; state.promptUploadOverwrite('file');
  const dialog = state.dialogs.at(-1); await dialog.secondaryButton.action(); await dialog.secondaryButton.action();
  dialog.primaryButton.action(); assert.deepEqual(state.uploads, [true]); assert.equal(state.pendingUpload, staged);
});

test('current upload cancellation cleans its own staging once', async () => {
  const state = fixture(); const staged = state.pendingUpload; state.promptUploadOverwrite('file');
  const dialog = state.dialogs.at(-1); dialog.primaryButton.action(); dialog.primaryButton.action();
  await dialog.secondaryButton.action(); assert.deepEqual(state.cleanups, [staged]); assert.equal(state.uploads.length, 0);
});

test('a stale upload confirmation preserves staging without dispatching', async () => {
  const state = fixture(); const staged = state.pendingUpload; state.promptUploadOverwrite('file');
  const dialog = state.dialogs.at(-1); state.fileActionGeneration++; await dialog.secondaryButton.action();
  assert.equal(state.pendingUpload, staged); assert.equal(state.uploads.length, 0);
});

test('a newer mutation confirmation also supersedes an upload confirmation without deleting its staging', async () => {
  const state = fixture(); const staged = state.pendingUpload; state.promptUploadOverwrite('file');
  const old = state.dialogs.at(-1); state.promptMutationOverwrite(mutation(), 'renaming', 'done');
  const current = state.dialogs.at(-1); old.primaryButton.action(); old.onDidDisappear?.();
  await current.secondaryButton.action();
  assert.equal(state.pendingUpload, staged); assert.equal(state.cleanups.length, 0); assert.equal(state.mutations.length, 1);
});
