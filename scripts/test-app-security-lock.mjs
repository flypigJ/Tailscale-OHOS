import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
import {
  createMemoryFileIo,
  loadEtsModules,
  readEtsSource
} from './helpers/ets-vm-loader.mjs';

const REPO_ROOT = new URL('../', import.meta.url);
const readRepoFile = rel => readFileSync(new URL(rel, REPO_ROOT), 'utf8').replace(/\r\n/g, '\n');

function extractMethod(source, name) {
  const match = new RegExp(`^  (?:private )?(?:async )?${name}\\(`, 'm').exec(source);
  assert.ok(match, `missing method ${name}`);
  const end = source.indexOf('\n  }', match.index);
  assert.ok(end > match.index, `missing closing brace for ${name}`);
  return source.slice(match.index, end + 4);
}

function createPreferencesHarness() {
  const mem = createMemoryFileIo();
  const storeValues = new Map();
  let getPreferencesError = null;
  let flushError = null;
  const store = {
    getSync(key, fallback) {
      return storeValues.has(key) ? storeValues.get(key) : fallback;
    },
    putSync(key, value) {
      storeValues.set(key, value);
    },
    async flush() {
      if (flushError) throw flushError;
    }
  };
  const preferences = {
    async getPreferences() {
      if (getPreferencesError) throw getPreferencesError;
      return store;
    }
  };
  const ctx = loadEtsModules(
    ['services/AtomicFileStore', 'services/AppSecurityPreferences'],
    { fileIo: mem.fileIo, preferences, Date, JSON, Number, Array }
  );
  return {
    AppSecurityPreferences: ctx.AppSecurityPreferences,
    mem,
    storeValues,
    context: { filesDir: '/data/storage/el2/base/files' },
    sentinelPath: '/data/storage/el2/base/files/app-security-armed-v1.json',
    setGetPreferencesError(err) { getPreferencesError = err; },
    setFlushError(err) { flushError = err; }
  };
}

test('un-armed first-run preferences failure preserves unlocked fallback without arming privacy mode', async () => {
  const h = createPreferencesHarness();
  h.setGetPreferencesError(new Error('preferences database unavailable'));

  const loaded = await h.AppSecurityPreferences.load(h.context);
  assert.deepEqual(JSON.parse(JSON.stringify(loaded)), {
    appLockEnabled: false,
    folderLockEnabled: false,
    lockedFolderPaths: []
  });
  assert.equal(h.AppSecurityPreferences.isPrivacyProtectionArmedSync(h.context.filesDir), false);
  assert.equal(h.mem.files.has(h.sentinelPath), false);
});

test('arming security preferences writes atomic sentinel and restores armed state when preferences fails', async () => {
  const h = createPreferencesHarness();
  await h.AppSecurityPreferences.saveAppLockEnabled(h.context, true);
  await h.AppSecurityPreferences.saveFolderLockEnabled(h.context, true);
  await h.AppSecurityPreferences.saveLockedFolderPaths(h.context, [
    ' /tailnet/workstation/secret/ ',
    '/tailnet/workstation/secret/nested'
  ]);

  assert.equal(h.mem.descriptors.size, 0, 'atomic write closes file descriptor before rename');
  assert.equal(h.mem.files.has(h.sentinelPath), true);
  assert.equal(h.AppSecurityPreferences.isPrivacyProtectionArmedSync(h.context.filesDir), true);

  h.setGetPreferencesError(new Error('preferences read failure after reboot'));
  const recovered = await h.AppSecurityPreferences.load(h.context);
  assert.deepEqual(JSON.parse(JSON.stringify(recovered)), {
    appLockEnabled: true,
    folderLockEnabled: true,
    lockedFolderPaths: ['/tailnet/workstation/secret']
  });

  // Explicit disarm updates sentinel cleanly so subsequent read failure does not false-lock.
  h.setGetPreferencesError(null);
  await h.AppSecurityPreferences.saveAppLockEnabled(h.context, false);
  await h.AppSecurityPreferences.saveFolderLockEnabled(h.context, false);
  await h.AppSecurityPreferences.saveLockedFolderPaths(h.context, []);
  assert.equal(h.AppSecurityPreferences.isPrivacyProtectionArmedSync(h.context.filesDir), false);

  h.setGetPreferencesError(new Error('preferences read failure after disarm'));
  const disarmedRecovery = await h.AppSecurityPreferences.load(h.context);
  assert.deepEqual(JSON.parse(JSON.stringify(disarmedRecovery)), {
    appLockEnabled: false,
    folderLockEnabled: false,
    lockedFolderPaths: []
  });
});

test('upgrading armed installation syncs sentinel on load and corrupted sentinel fails closed', async () => {
  const h = createPreferencesHarness();
  h.storeValues.set('app_lock_enabled', false);
  h.storeValues.set('folder_lock_enabled', true);
  h.storeValues.set('locked_folder_paths', JSON.stringify(['/tailnet/nas/private']));

  const upgraded = await h.AppSecurityPreferences.load(h.context);
  assert.equal(upgraded.folderLockEnabled, true);
  assert.equal(h.mem.files.has(h.sentinelPath), true);
  assert.equal(h.AppSecurityPreferences.isPrivacyProtectionArmedSync(h.context.filesDir), true);

  for (const corruptedPayload of [
    '{corrupted-json',
    '',
    JSON.stringify({ schemaVersion: 99, appLockEnabled: false, folderLockEnabled: false, lockedFolderPaths: [] }),
    JSON.stringify({ schemaVersion: 1, appLockEnabled: 'no', folderLockEnabled: false, lockedFolderPaths: [] }),
    JSON.stringify({ schemaVersion: 1, appLockEnabled: false, folderLockEnabled: false, lockedFolderPaths: ['relative/path'] }),
    'x'.repeat(20000)
  ]) {
    h.mem.files.set(h.sentinelPath, corruptedPayload);
    h.mem.rawBytes.set(h.sentinelPath, Buffer.from(corruptedPayload, 'utf8'));
    h.setGetPreferencesError(new Error('preferences unavailable'));
    const failClosed = await h.AppSecurityPreferences.load(h.context);
    assert.deepEqual(JSON.parse(JSON.stringify(failClosed)), {
      appLockEnabled: true,
      folderLockEnabled: true,
      lockedFolderPaths: []
    });
    assert.equal(h.AppSecurityPreferences.isPrivacyProtectionArmedSync(h.context.filesDir), true);
  }
});

test('cold-start security cover and window privacy transitions protect BridgeStatus without false unlock gaps', async () => {
  const bridgeSource = readEtsSource('components/BridgeStatus');
  const controllerMethods = [
    'loadSecurityPreferences',
    'isSecurityCoverActive',
    'onSecurityPrivacyStateChanged',
    'currentWindowPrivacyRequired',
    'syncWindowPrivacyMode',
    'onAppLockRequiredChanged',
    'requireAppAuthentication'
  ];
  const privacyCalls = [];
  const pendingWindowGates = [];
  const appStorageMap = new Map();
  let armedSync = false;
  let armedSyncThrows = false;
  let manualWindowResolution = false;
  let loadImpl = async () => ({ appLockEnabled: false, folderLockEnabled: false, lockedFolderPaths: [] });
  let fallbackImpl = () => ({ appLockEnabled: false, folderLockEnabled: false, lockedFolderPaths: [] });

  const mockWindow = {
    setWindowPrivacyMode: async enabled => { privacyCalls.push(enabled); }
  };

  const sandbox = {
    Array,
    AppStorage: {
      get: key => appStorageMap.get(key),
      setOrCreate: (key, value) => appStorageMap.set(key, value)
    },
    AppSecurityPreferences: {
      load: ctx => loadImpl(ctx),
      loadFallback: dir => fallbackImpl(dir),
      isPrivacyProtectionArmedSync: () => {
        if (armedSyncThrows) throw new Error('fs io error');
        return armedSync;
      }
    },
    window: {
      getLastWindow: () => {
        if (manualWindowResolution) {
          let resolve;
          const promise = new Promise(r => { resolve = r; });
          pendingWindowGates.push(resolve);
          return promise;
        }
        return Promise.resolve(mockWindow);
      }
    }
  };
  vm.runInNewContext(
    stripTypeScriptTypes(
      `class SecurityController {\n${controllerMethods.map(m => extractMethod(bridgeSource, m)).join('\n')}\n}\nglobalThis.SecurityController = SecurityController;`
    ),
    sandbox
  );

  const c = new sandbox.SecurityController();
  let scheduledAuth = 0;
  let stoppedDetailPoll = 0;
  let streamInvalidations = 0;
  Object.assign(c, {
    lifecycleGeneration: 1,
    windowPrivacySyncSeq: 0,
    appShellReady: true,
    securityPreferencesReady: false,
    appLockEnabled: false,
    folderLockEnabled: false,
    lockedFolderPaths: [],
    appLockRequired: false,
    appLockAuthenticating: false,
    securitySettingsAuthenticating: false,
    authKeyLoginVisible: false,
    authKeyInput: 'tskey-auth-secret',
    updateChangelogShowPending: false,
    deviceDetailVisible: true,
    fileTransferMethodVisible: true,
    mediaMethodVisible: true,
    nativeSettingsVisible: true,
    connectionDetailsVisible: true,
    getUIContext: () => ({ getHostContext: () => ({ filesDir: '/files' }) }),
    scheduleLifecycleTask: fn => { scheduledAuth++; fn(); },
    authenticateApplication: () => {},
    invalidateRemoteStreamLaunch: () => { streamInvalidations++; },
    stopDeviceDetailRefreshPolling: () => { stoppedDetailPoll++; },
    showUpdateChangelogIfNeeded: () => {}
  });

  // Before preferences resolve, cold-start cover is active immediately and armed-check throw fails closed.
  assert.equal(c.isSecurityCoverActive(), true);
  armedSyncThrows = true;
  c.syncWindowPrivacyMode();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(privacyCalls.at(-1), true);
  armedSyncThrows = false;
  armedSync = true;
  c.syncWindowPrivacyMode();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(privacyCalls.at(-1), true);

  // Armed preferences failure falls closed via loadFallback, locks app, and closes all 5 transient sheets.
  loadImpl = async () => { throw new Error('corrupt store'); };
  fallbackImpl = () => ({ appLockEnabled: true, folderLockEnabled: true, lockedFolderPaths: ['/tailnet/dev/docs'] });
  c.loadSecurityPreferences({ filesDir: '/files' });
  await new Promise(resolve => setImmediate(resolve));

  assert.equal(c.securityPreferencesReady, true);
  assert.equal(c.appLockEnabled, true);
  assert.equal(c.appLockRequired, true);
  assert.equal(c.isSecurityCoverActive(), true);
  assert.equal(scheduledAuth, 1);

  c.onAppLockRequiredChanged();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(c.authKeyInput, '');
  assert.equal(c.authKeyLoginVisible, false);
  assert.equal(c.deviceDetailVisible, false);
  assert.equal(stoppedDetailPoll, 1);
  assert.equal(streamInvalidations, 1);
  assert.equal(c.fileTransferMethodVisible, false);
  assert.equal(c.mediaMethodVisible, false);
  assert.equal(c.nativeSettingsVisible, false);
  assert.equal(c.connectionDetailsVisible, false);

  // Disarming locks clears privacy mode, while opening AuthKey input re-enables privacy mode.
  c.appLockEnabled = false;
  c.folderLockEnabled = false;
  c.appLockRequired = false;
  appStorageMap.set('taildriveLockedFolderPaths', []);
  c.onSecurityPrivacyStateChanged();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(c.isSecurityCoverActive(), false);
  assert.equal(privacyCalls.at(-1), false);

  c.authKeyLoginVisible = true;
  c.onSecurityPrivacyStateChanged();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(privacyCalls.at(-1), true);

  // Regression: out-of-order window.getLastWindow completion must never let an older false overwrite a newer true!
  privacyCalls.length = 0;
  manualWindowResolution = true;
  c.authKeyLoginVisible = false;
  c.onSecurityPrivacyStateChanged(); // seq N (false), slow getLastWindow
  c.authKeyLoginVisible = true;
  c.onSecurityPrivacyStateChanged(); // seq N+1 (true), fast getLastWindow
  assert.equal(pendingWindowGates.length, 2);

  // Resolve newer request first, then older request second.
  pendingWindowGates[1](mockWindow);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(privacyCalls, [true]);

  pendingWindowGates[0](mockWindow);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(privacyCalls, [true], 'stale getLastWindow completion is dropped');
});

test('all 7 BridgeStatus sheets and all 5 TaildriveBrowser sheets wire security cover/shield and close on lock', () => {
  const bridgeSource = readEtsSource('components/BridgeStatus');
  const taildriveSource = readEtsSource('components/TaildriveBrowser');
  const preferencesSource = readEtsSource('services/AppSecurityPreferences');

  // Strict ArkTS: serializeSentinel uses an explicitly typed PersistedSecuritySentinel variable, not an untyped literal.
  assert.match(preferencesSource, /const payload:\s*PersistedSecuritySentinel\s*=\s*\{/);
  assert.doesNotMatch(preferencesSource, /JSON\.stringify\(\s*\{/);

  // Reactive @State on folderAccessGrants ensures SheetSecurityShield re-renders across all 5 Taildrive sheets.
  assert.match(taildriveSource, /@State\s+private\s+folderAccessGrants:\s*string\[\]\s*=\s*\[\]/);

  // Root content cover and TaildriveBrowser wiring in BridgeStatus
  assert.match(bridgeSource, /\.bindContentCover\(this\.isSecurityCoverActive\(\),\s*this\.SecurityCoverOverlay\(\)/);
  assert.match(extractMethod(bridgeSource, 'SecurityCoverOverlay'), /security-startup-cover/);
  assert.match(extractMethod(bridgeSource, 'FilesContent'), /appLockActive:\s*this\.isSecurityCoverActive\(\)/);

  const bridgeSheetBuilders = [
    'StandaloneDiagnosticsContent',
    'UpdateChangelogContent',
    'DeviceDetailsContent',
    'FileTransferMethodContent',
    'MediaMethodContent',
    'NativeSettingsSheetContent',
    'ConnectionDetailsContent'
  ];
  for (const builderName of bridgeSheetBuilders) {
    const body = extractMethod(bridgeSource, builderName);
    assert.match(body, /if\s*\(this\.isSecurityCoverActive\(\)\)\s*\{\s*this\.SecurityCoverOverlay\(\)\s*\}/,
      `BridgeStatus ${builderName} must render SecurityCoverOverlay when security cover is active`);
  }

  const taildriveSheetBuilders = [
    'EditorSheet',
    'DetailsSheet',
    'PreviewDownloadSheet',
    'MoveSheet',
    'SortSheet'
  ];
  for (const builderName of taildriveSheetBuilders) {
    const body = extractMethod(taildriveSource, builderName);
    assert.match(body, /this\.isSheetBlockedBySecurity\(/,
      `TaildriveBrowser ${builderName} must check isSheetBlockedBySecurity`);
    assert.match(body, /this\.SheetSecurityShield\(\)/,
      `TaildriveBrowser ${builderName} must render SheetSecurityShield`);
  }

  // Execute TaildriveSessionController sheet-closing & blocking logic in VM
  const tdScope = loadEtsModules(['services/TaildriveSessionController']);
  const tdState = {
    path: '/tailnet/nas/secret/sub',
    standalone: true,
    folderLockEnabled: true,
    lockedFolderPaths: ['/tailnet/nas/secret'],
    folderAccessGrants: ['/tailnet/nas/secret'],
    appLockActive: false,
    appInForeground: true,
    browserVisible: true,
    connected: true,
    filesTabActive: true,
    fileActionGeneration: 0,
    pullRefreshing: true,
    selectionMode: false,
    dragSelecting: false,
    selectedPaths: [],
    entries: [],
    cachedEntries: [],
    editorVisible: true,
    editorOperation: 'rename',
    editorPath: '/tailnet/nas/secret/sub/doc.txt',
    detailsVisible: true,
    detailsLoading: false,
    detailsReason: '',
    detailEntry: { name: 'doc.txt', path: '/tailnet/nas/secret/sub/doc.txt', kind: 'file', size: 10, modifiedAtMs: 0 },
    previewDownloadVisible: true,
    previewDownloadEntry: { name: 'doc.txt', path: '/tailnet/nas/secret/sub/doc.txt', kind: 'file', size: 10, modifiedAtMs: 0 },
    moveVisible: true,
    moveOperation: 'move',
    moveTargetCount: 1,
    moveLoading: false,
    moveEntries: [],
    moveReason: '',
    movePath: '/tailnet/nas/secret/sub',
    sortSheetVisible: true,
    folderDialogVisible: true,
    editorName: ''
  };
  const td = new tdScope.TaildriveSessionController({
    isConnected: () => tdState.connected,
    isStandalone: () => tdState.standalone,
    isFilesTabActive: () => tdState.filesTabActive,
    isBrowserVisible: () => tdState.browserVisible,
    isAppInForeground: () => tdState.appInForeground,
    setAppInForeground: v => { tdState.appInForeground = v; },
    isAppLockActive: () => tdState.appLockActive,
    isFolderLockEnabled: () => tdState.folderLockEnabled,
    getLockedFolderPaths: () => tdState.lockedFolderPaths,
    setLockedFolderPaths: v => { tdState.lockedFolderPaths = v; },
    getFolderAccessGrants: () => tdState.folderAccessGrants,
    setFolderAccessGrants: v => { tdState.folderAccessGrants = v; },
    getTargetMachineName: () => '',
    getTargetTailnetName: () => '',
    getTargetRequestId: () => 0,
    getPath: () => tdState.path,
    setPath: v => { tdState.path = v; },
    getEntries: () => tdState.entries,
    setEntries: v => { tdState.entries = v; },
    isPullRefreshing: () => tdState.pullRefreshing,
    setPullRefreshing: v => { tdState.pullRefreshing = v; },
    isSelectionMode: () => tdState.selectionMode,
    setSelectionMode: v => { tdState.selectionMode = v; },
    isDragSelecting: () => tdState.dragSelecting,
    setDragSelecting: v => { tdState.dragSelecting = v; },
    getSelectedPaths: () => tdState.selectedPaths,
    setSelectedPaths: v => { tdState.selectedPaths = v; },
    getFileActionGeneration: () => tdState.fileActionGeneration,
    setFileActionGeneration: v => { tdState.fileActionGeneration = v; },
    isEditorVisible: () => tdState.editorVisible,
    setEditorVisible: v => { tdState.editorVisible = v; },
    getEditorName: () => tdState.editorName,
    setEditorName: v => { tdState.editorName = v; },
    getEditorOperation: () => tdState.editorOperation,
    getEditorPath: () => tdState.editorPath,
    isFolderDialogVisible: () => tdState.folderDialogVisible,
    setFolderDialogVisible: v => { tdState.folderDialogVisible = v; },
    isPreviewDownloadVisible: () => tdState.previewDownloadVisible,
    setPreviewDownloadVisible: v => { tdState.previewDownloadVisible = v; },
    getPreviewDownloadEntry: () => tdState.previewDownloadEntry,
    isDetailsVisible: () => tdState.detailsVisible,
    setDetailsVisible: v => { tdState.detailsVisible = v; },
    isDetailsLoading: () => tdState.detailsLoading,
    setDetailsLoading: v => { tdState.detailsLoading = v; },
    getDetailsReason: () => tdState.detailsReason,
    setDetailsReason: v => { tdState.detailsReason = v; },
    getDetailEntry: () => tdState.detailEntry,
    setDetailEntry: v => { tdState.detailEntry = v; },
    isMoveVisible: () => tdState.moveVisible,
    setMoveVisible: v => { tdState.moveVisible = v; },
    getMoveOperation: () => tdState.moveOperation,
    setMoveOperation: v => { tdState.moveOperation = v; },
    getMoveTargetCount: () => tdState.moveTargetCount,
    setMoveTargetCount: v => { tdState.moveTargetCount = v; },
    isMoveLoading: () => tdState.moveLoading,
    setMoveLoading: v => { tdState.moveLoading = v; },
    getMoveReason: () => tdState.moveReason,
    setMoveReason: v => { tdState.moveReason = v; },
    getMovePath: () => tdState.movePath,
    setMovePath: v => { tdState.movePath = v; },
    getMoveEntries: () => tdState.moveEntries,
    setMoveEntries: v => { tdState.moveEntries = v; },
    isSortSheetVisible: () => tdState.sortSheetVisible,
    setSortSheetVisible: v => { tdState.sortSheetVisible = v; },
    getCachedEntries: () => tdState.cachedEntries,
    setCachedEntries: v => { tdState.cachedEntries = v; },
    clearPreviewThumbnails() {},
    filterProtectedThumbnails() {},
    purgeGatewayPreviewCaches() {},
    cancelThumbnailPool() {},
    rebuildListDataSource() {},
    publishUiBackState() {},
    startRefreshPolling() {},
    stopRefreshPolling() {},
    stopDragAutoScroll() {},
    scheduleSecurityResume() {},
    clearSecurityResumeTimer() {},
    gatewayList: async path => ({ state: 'ready', reason: '', path, entries: [] }),
    applyListResult() {}
  });
  td.editorDirectory = '/tailnet/nas/secret/sub';
  td.detailsRequestId = 5;
  td.movingEntry = { name: 'doc.txt', path: '/tailnet/nas/secret/sub/doc.txt', kind: 'file', size: 10, modifiedAtMs: 0 };
  td.movingEntries = [];
  td.moveRequestId = 8;
  td.moveListGeneration = 3;
  td.folderDialogPath = '/tailnet/nas/secret/sub';

  assert.equal(td.isSheetBlockedBySecurity('/tailnet/nas/secret/sub/file.txt'), false);

  // Locking folder access blocks sheets and closes every open sheet/dialog immediately.
  tdState.folderAccessGrants = [];
  assert.equal(td.isSheetBlockedBySecurity('/tailnet/nas/secret/sub/file.txt'), true);
  td.blockProtectedFolderContent();
  assert.equal(tdState.editorVisible, false);
  assert.equal(tdState.detailsVisible, false);
  assert.equal(td.detailsRequestId, 6);
  assert.equal(tdState.previewDownloadVisible, false);
  assert.equal(tdState.moveVisible, false);
  assert.equal(td.moveRequestId, 9);
  assert.equal(tdState.sortSheetVisible, false);
  assert.equal(tdState.folderDialogVisible, false);

  // Regression: browsing an UNLOCKED parent (/tailnet/nas) while DetailsSheet & MoveSheet target a LOCKED child (/tailnet/nas/secret)
  // must shield and close those sheets on handleAppForeground() (even if filesTabActive === false) and onLockedFolderPathsChanged()!
  tdState.path = '/tailnet/nas';
  tdState.filesTabActive = false;
  tdState.folderAccessGrants = ['/tailnet/nas/secret'];
  tdState.detailsVisible = true;
  tdState.detailEntry = { name: 'secret', path: '/tailnet/nas/secret', kind: 'directory', size: 0, modifiedAtMs: 0 };
  tdState.moveVisible = true;
  tdState.movePath = '/tailnet/nas/secret';
  td.movingEntry = { name: 'note.txt', path: '/tailnet/nas/note.txt', kind: 'file', size: 4, modifiedAtMs: 0 };
  td.movingEntries = [td.movingEntry];
  tdState.sortSheetVisible = true; // SortSheet targets unlocked /tailnet/nas
  assert.equal(td.isSheetBlockedBySecurity(tdState.detailEntry.path), false);
  assert.equal(td.isMoveSheetBlockedBySecurity(), false);

  td.handleAppForeground();
  assert.deepEqual(Array.from(tdState.folderAccessGrants), []);
  assert.equal(td.isSheetBlockedBySecurity('/tailnet/nas/secret'), true, 'shield blocks locked child target');
  assert.equal(tdState.detailEntry.path, '', 'closeDetails clears detailEntry metadata immediately');
  assert.equal(tdState.detailsVisible, false, 'DetailsSheet targeting locked child closed on foreground');
  assert.equal(tdState.moveVisible, false, 'MoveSheet inside locked child closed on foreground');
  assert.equal(tdState.sortSheetVisible, true, 'SortSheet on unlocked parent stays unaffected');

  // Also test onLockedFolderPathsChanged when batch-moving an item from a newly locked child while browsing unlocked parent.
  tdState.filesTabActive = true;
  tdState.folderAccessGrants = ['/tailnet/nas/secret'];
  tdState.moveVisible = true;
  tdState.movePath = '/tailnet/nas/public-dest';
  td.movingEntry = { name: 'a.txt', path: '/tailnet/nas/a.txt', kind: 'file', size: 1, modifiedAtMs: 0 };
  td.movingEntries = [
    td.movingEntry,
    { name: 'b.txt', path: '/tailnet/nas/secret/b.txt', kind: 'file', size: 1, modifiedAtMs: 0 }
  ];
  assert.equal(td.isMoveSheetBlockedBySecurity(), false);
  td.onLockedFolderPathsChanged();
  assert.equal(tdState.moveVisible, false, 'MoveSheet with locked batch source closed on policy change');

  // Re-open sheets in an unlocked folder and verify appLockActive closes all sheets immediately.
  tdState.path = '/tailnet/nas/public';
  tdState.editorVisible = true;
  tdState.detailsVisible = true;
  tdState.previewDownloadVisible = true;
  tdState.moveVisible = true;
  tdState.sortSheetVisible = true;
  tdState.folderDialogVisible = true;
  assert.equal(td.isSheetBlockedBySecurity('/tailnet/nas/public'), false);

  tdState.appLockActive = true;
  assert.equal(td.isSheetBlockedBySecurity('/tailnet/nas/public'), true);
  td.onAppLockActiveChanged();
  assert.equal(tdState.editorVisible, false);
  assert.equal(tdState.detailsVisible, false);
  assert.equal(tdState.previewDownloadVisible, false);
  assert.equal(tdState.moveVisible, false);
  assert.equal(tdState.sortSheetVisible, false);
  assert.equal(tdState.folderDialogVisible, false);
});

test('PRIVACY_WINDOW permission contract and WindowEnvironment.setPrivacyMode safety', async () => {
  const manifest = JSON.parse(readRepoFile('entry/src/main/module.json5')).module;
  const permissionNames = manifest.requestPermissions.map(item => item.name);
  assert.ok(permissionNames.includes('ohos.permission.PRIVACY_WINDOW'));
  // Exclusion rule: backgroundModes and APPROXIMATELY_LOCATION remain untouched.
  assert.deepEqual(manifest.abilities[0].backgroundModes, ['dataTransfer', 'location', 'audioPlayback']);
  assert.ok(permissionNames.includes('ohos.permission.APPROXIMATELY_LOCATION'));

  const calls = [];
  let modeBehavior = 'ok';
  const mainWindow = {
    getUIContext: () => ({}),
    getWindowProperties: () => ({ windowRect: { left: 0, top: 0, width: 360, height: 780 } }),
    getWindowAvoidArea: () => ({
      leftRect: { left: 0, top: 0, width: 0, height: 0 },
      topRect: { left: 0, top: 0, width: 0, height: 0 },
      rightRect: { left: 0, top: 0, width: 0, height: 0 },
      bottomRect: { left: 0, top: 0, width: 0, height: 0 }
    }),
    getWindowDensityInfo: () => ({ systemDensity: 3, defaultDensity: 3, customDensity: 0 }),
    on() {},
    off() {},
    setWindowPrivacyMode(enabled) {
      calls.push(enabled);
      if (modeBehavior === 'throw') throw new Error('window destroyed');
      if (modeBehavior === 'reject') return Promise.reject({ code: 1300002 });
      return Promise.resolve();
    }
  };
  const compileTransform = rel => stripTypeScriptTypes(
    readEtsSource(rel)
      .replace(/^import\s+['"][^'"]+['"]\s*;?[ \t]*\r?$/gm, '')
      .replace(/^import\s+(?:type\s+)?[\s\S]*?\bfrom\s+['"][^'"]+['"]\s*;?[ \t]*\r?$/gm, '')
      .replace(/^export\s+default\s+/gm, '')
      .replace(/^export\s+/gm, ''),
    { mode: 'transform' }
  );
  const ctx = vm.createContext({
    window: { AvoidAreaType: { TYPE_SYSTEM: 0, TYPE_NAVIGATION_INDICATOR: 1 } },
    uiObserver: { on() {}, off() {} },
    hilog: { info() {}, warn() {}, error() {} }
  });
  vm.runInContext(
    `${compileTransform('services/DiagnosticPrivacy')}\n${compileTransform('services/WindowEnvironment')}\nglobalThis.WindowEnvironment = WindowEnvironment;`,
    ctx
  );
  const env = new ctx.WindowEnvironment();
  env.attach(mainWindow, { colorMode: 0, direction: 0 });
  env.setPrivacyMode(true);
  env.setPrivacyMode(true);
  assert.deepEqual(calls, [true], 'duplicate privacy mode calls are coalesced');

  modeBehavior = 'reject';
  env.setPrivacyMode(false);
  await new Promise(resolve => setImmediate(resolve));
  modeBehavior = 'ok';
  env.setPrivacyMode(false);
  assert.deepEqual(calls, [true, false, false], 'rejected call clears cache so retry applies');

  modeBehavior = 'throw';
  assert.doesNotThrow(() => env.setPrivacyMode(true));
  env.detach();
  assert.doesNotThrow(() => env.setPrivacyMode(false));
});

test('AppSecurityAuthenticator prefers ATL3, blocks weak ATL2-only types when ATL3 exists, and falls back to ATL2 only when ATL3 has zero types', async () => {
  let availableByLevel = new Map();
  const createdInstances = [];
  const logs = [];
  const UserAuthType = { FACE: 2, FINGERPRINT: 4, PIN: 1 };
  const AuthTrustLevel = { ATL1: 10000, ATL2: 20000, ATL3: 30000, ATL4: 40000 };
  const UserAuthResultCode = { SUCCESS: 12500000, FAIL: 12500001 };

  const ctx = loadEtsModules(
    ['services/AppSecurityAuthenticator'],
    {
      Uint8Array,
      cryptoFramework: {
        createRandom: () => ({ generateRandomSync: len => ({ data: new Uint8Array(len).fill(7) }) })
      },
      hilog: {
        info: (_d, _t, fmt, ...args) => logs.push({ fmt, args }),
        error: (_d, _t, fmt, ...args) => logs.push({ fmt, args })
      },
      userAuth: {
        UserAuthType,
        AuthTrustLevel,
        UserAuthResultCode,
        getAvailableStatus(authType, trustLevel) {
          const allowed = availableByLevel.get(trustLevel) ?? [];
          if (!allowed.includes(authType)) {
            throw { code: 12500010 };
          }
        },
        getUserAuthInstance(authParam, widgetParam) {
          const listeners = new Map();
          const record = { authParam, widgetParam, started: false, offCalled: false, listeners };
          createdInstances.push(record);
          return {
            on(event, cb) { listeners.set(event, cb); },
            off() { record.offCalled = true; },
            start() {
              record.started = true;
              queueMicrotask(() => {
                listeners.get('result')?.onResult({
                  result: UserAuthResultCode.SUCCESS,
                  token: new Uint8Array([99, 88, 77])
                });
              });
            }
          };
        }
      }
    }
  );

  // Case 1: 2D Face only at ATL2, Fingerprint + PIN at ATL3 -> uses ATL3 with [FINGERPRINT, PIN] only!
  availableByLevel = new Map([
    [AuthTrustLevel.ATL3, [UserAuthType.FINGERPRINT, UserAuthType.PIN]],
    [AuthTrustLevel.ATL2, [UserAuthType.FACE, UserAuthType.FINGERPRINT, UserAuthType.PIN]]
  ]);
  assert.equal(await ctx.AppSecurityAuthenticator.authenticate('Unlock MeshArc'), true);
  assert.equal(createdInstances.length, 1);
  assert.equal(createdInstances[0].authParam.authTrustLevel, AuthTrustLevel.ATL3);
  assert.deepEqual(Array.from(createdInstances[0].authParam.authType), [UserAuthType.FINGERPRINT, UserAuthType.PIN]);
  assert.equal(createdInstances[0].offCalled, true);

  // Case 2: Zero ATL3 credentials enrolled, ATL2 credential available -> falls back cleanly to ATL2.
  availableByLevel = new Map([
    [AuthTrustLevel.ATL3, []],
    [AuthTrustLevel.ATL2, [UserAuthType.FACE, UserAuthType.PIN]]
  ]);
  assert.equal(await ctx.AppSecurityAuthenticator.authenticate('Unlock Folder'), true);
  assert.equal(createdInstances.length, 2);
  assert.equal(createdInstances[1].authParam.authTrustLevel, AuthTrustLevel.ATL2);
  assert.deepEqual(Array.from(createdInstances[1].authParam.authType), [UserAuthType.FACE, UserAuthType.PIN]);

  // Case 3: Neither ATL3 nor ATL2 available -> fails closed (returns false without starting widget).
  availableByLevel = new Map();
  assert.equal(await ctx.AppSecurityAuthenticator.authenticate('Unlock'), false);
  assert.equal(createdInstances.length, 2);

  // Ensure AuthToken bytes never enter logs or authenticator properties.
  assert.equal(JSON.stringify(logs).includes('99,88,77'), false);
  assert.equal(Object.keys(ctx.AppSecurityAuthenticator).length, 0);
});
