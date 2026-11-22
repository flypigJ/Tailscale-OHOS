import assert from 'node:assert/strict';
import test from 'node:test';
import { loadEtsModules } from './helpers/ets-vm-loader.mjs';

const { TaildriveSessionController } = loadEtsModules(['services/TaildriveSessionController']);
const root = '/tailnet/device/share';
const entry = name => ({ name, path: `${root}/${name}`, kind: 'file', size: 1, modifiedAtMs: 0 });
const ready = value => ({ state: 'ready', entry: value, reason: '' });
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; };
const flush = () => new Promise(resolve => setImmediate(resolve));

function fixture() {
  const state = {
    path: root, fileActionGeneration: 1, connected: true, browserVisible: true, appLockActive: false,
    standalone: true, filesTabActive: true, busy: false,
    folderLockEnabled: false, lockedFolderPaths: [], folderAccessGrants: [], folderAccessAuthInFlight: false,
    allowOverlappingAuth: false,
    detailsVisible: false, detailsLoading: false, detailsReason: '', detailEntry: entry(''), stats: [],
    authenticateFolderAccess: async () => true
  };
  state.gateway = { async stat(reqPath) { state.stats.push(reqPath); return ready({ ...entry(reqPath.split('/').at(-1)), size: 42 }); } };
  const controller = new TaildriveSessionController({
    isConnected: () => state.connected,
    isStandalone: () => state.standalone,
    isFilesTabActive: () => state.filesTabActive,
    isBrowserVisible: () => state.browserVisible,
    isAppLockActive: () => state.appLockActive,
    isFolderLockEnabled: () => state.folderLockEnabled,
    getLockedFolderPaths: () => state.lockedFolderPaths,
    setLockedFolderPaths: paths => { state.lockedFolderPaths = paths; },
    getFolderAccessGrants: () => state.folderAccessGrants,
    setFolderAccessGrants: grants => { state.folderAccessGrants = grants; },
    isFolderAccessAuthInFlight: () => state.allowOverlappingAuth ? false : state.folderAccessAuthInFlight,
    setFolderAccessAuthInFlight: value => { state.folderAccessAuthInFlight = value; },
    getPath: () => state.path,
    isBusy: () => state.busy,
    getFileActionGeneration: () => state.fileActionGeneration,
    isDetailsVisible: () => state.detailsVisible,
    setDetailsVisible: value => { state.detailsVisible = value; },
    isDetailsLoading: () => state.detailsLoading,
    setDetailsLoading: value => { state.detailsLoading = value; },
    getDetailsReason: () => state.detailsReason,
    setDetailsReason: value => { state.detailsReason = value; },
    getDetailEntry: () => state.detailEntry,
    setDetailEntry: value => { state.detailEntry = value; },
    showTransientStatus() {},
    recordSecurityDiagnostic() {},
    authenticateFolderAccess: () => state.authenticateFolderAccess(),
    gatewayStat: reqPath => state.gateway.stat(reqPath)
  });
  for (const name of ['showDetails', 'canUseDetailsContext', 'detailsContextCurrent', 'closeDetails', 'takeDetailEntry']) {
    state[name] = (...args) => controller[name](...args);
  }
  state.close = () => controller.closeDetails();
  state.take = () => controller.takeDetailEntry();
  return state;
}

test('details loads the selected file through the existing stat protocol', async () => {
  const state = fixture(); await state.showDetails(entry('one'));
  assert.deepEqual(state.stats, [`${root}/one`]);
  assert.equal(state.detailsVisible, true);
  assert.equal(state.detailsLoading, false);
  assert.equal(state.detailEntry.size, 42);
});

test('a late authentication result cannot open details after leaving the file context', async () => {
  for (const invalidate of [
    state => { state.path = '/another'; state.fileActionGeneration++; },
    state => { state.connected = false; }, state => { state.browserVisible = false; },
    state => { state.appLockActive = true; }, state => { state.filesTabActive = false; }
  ]) {
    const state = fixture();
    state.folderLockEnabled = true; state.lockedFolderPaths = [root];
    const auth = deferred(); state.authenticateFolderAccess = () => auth.promise;
    const pending = state.showDetails(entry('one')); invalidate(state); auth.resolve(true); await pending;
    assert.equal(state.detailsVisible, false);
    assert.equal(state.stats.length, 0);
  }
});

test('the most recent file selection owns details when authentication completes out of order', async () => {
  const state = fixture();
  state.folderLockEnabled = true;
  state.lockedFolderPaths = [`${root}/one`, `${root}/two`];
  state.allowOverlappingAuth = true;
  const first = deferred(); const second = deferred();
  let calls = 0;
  state.authenticateFolderAccess = () => (++calls === 1 ? first.promise : second.promise);
  const oldDetails = state.showDetails(entry('one')); const newDetails = state.showDetails(entry('two'));
  second.resolve(true); await newDetails; first.resolve(true); await oldDetails;
  assert.equal(state.detailEntry.name, 'two');
});

test('an old stat response cannot replace another file in the current panel', async () => {
  const state = fixture(); const first = deferred(); const second = deferred();
  state.gateway.stat = path => path.endsWith('/one') ? first.promise : second.promise;
  const oldDetails = state.showDetails(entry('one')); await flush();
  const newDetails = state.showDetails(entry('two')); await flush();
  second.resolve(ready(entry('two'))); await newDetails;
  first.resolve(ready(entry('one'))); await oldDetails;
  assert.equal(state.detailEntry.name, 'two');
});

test('an obsolete stat error cannot clear the latest spinner or inject its reason', async () => {
  const state = fixture(); const first = deferred(); const second = deferred();
  state.gateway.stat = path => path.endsWith('/one') ? first.promise : second.promise;
  const oldDetails = state.showDetails(entry('one')); await flush();
  const newDetails = state.showDetails(entry('two')); await flush();
  first.reject(new Error('obsolete failure')); await oldDetails;
  assert.equal(state.detailsLoading, true);
  assert.equal(state.detailsReason, '');
  second.resolve(ready(entry('two'))); await newDetails;
  assert.equal(state.detailsLoading, false);
});

test('closing and reopening the same file invalidates the old request', async () => {
  const state = fixture(); const old = deferred(); state.gateway.stat = () => old.promise;
  const oldDetails = state.showDetails(entry('one')); await flush(); state.close();
  state.gateway.stat = async () => ready({ ...entry('one'), size: 99 });
  await state.showDetails(entry('one'));
  old.resolve(ready({ ...entry('one'), size: 12 })); await oldDetails;
  assert.equal(state.detailEntry.size, 99);
});

test('native dismissal or a context change prevents late stat metadata from entering the panel', async () => {
  for (const invalidate of [
    state => { state.detailsVisible = false; },
    state => { state.appLockActive = true; state.fileActionGeneration++; },
    state => { state.path = '/other'; state.fileActionGeneration++; state.path = root; state.fileActionGeneration++; }
  ]) {
    const state = fixture(); const result = deferred(); state.gateway.stat = () => result.promise;
    const pending = state.showDetails(entry('one')); await flush(); invalidate(state);
    result.resolve(ready({ ...entry('one'), size: 200 })); await pending;
    assert.equal(state.detailEntry.size, 1);
    assert.equal(state.take(), undefined);
  }
});

test('an invalid details context cannot supply a file to any action', async () => {
  for (const invalidate of [
    state => { state.path = '/another'; state.fileActionGeneration++; },
    state => { state.fileActionGeneration++; }, state => { state.appLockActive = true; },
    state => { state.filesTabActive = false; }, state => { state.connected = false; }, state => state.close()
  ]) {
    const state = fixture(); await state.showDetails(entry('one')); invalidate(state);
    assert.equal(state.take(), undefined);
  }
});

test('the current details file can be claimed once and never while busy or loading', async () => {
  const state = fixture(); const result = deferred(); state.gateway.stat = () => result.promise;
  const pending = state.showDetails(entry('one')); await flush();
  assert.equal(state.take(), undefined);
  result.resolve(ready(entry('one'))); await pending;
  state.busy = true; assert.equal(state.take(), undefined);
  state.busy = false; assert.equal(state.take().path, `${root}/one`);
  assert.equal(state.take(), undefined);
});

test('a current stat failure keeps listed metadata and presents a nonempty failure reason', async () => {
  const state = fixture(); state.gateway.stat = async () => ({ state: 'failed', reason: '', entry: entry('') });
  await state.showDetails(entry('one'));
  assert.equal(state.detailEntry.name, 'one');
  assert.notEqual(state.detailsReason, '');
  assert.equal(state.detailsLoading, false);
  assert.equal(state.detailsVisible, true);
});
