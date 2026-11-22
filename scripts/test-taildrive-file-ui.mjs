import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
import { loadEtsModules } from './helpers/ets-vm-loader.mjs';

const { TaildriveSessionController } = loadEtsModules(['services/TaildriveSessionController']);
const browser = readFileSync(new URL('../entry/src/main/ets/components/TaildriveBrowser.ets', import.meta.url), 'utf8');
const sessionControllerSource = readFileSync(
  new URL('../entry/src/main/ets/services/TaildriveSessionController.ets', import.meta.url),
  'utf8'
);
const shell = readFileSync(new URL('../entry/src/main/ets/components/BridgeStatus.ets', import.meta.url), 'utf8');
const poolSandbox = {};
vm.runInNewContext(stripTypeScriptTypes(readFileSync(new URL('../entry/src/main/ets/services/LatestTaskPool.ets', import.meta.url), 'utf8')
  .replace('export class', 'class')) + '\nthis.Pool = LatestTaskPool;', poolSandbox);
const flush = () => new Promise(resolve => setImmediate(resolve));
const builder = name => {
  const start = browser.indexOf(`  private ${name}(`);
  assert.notEqual(start, -1, name);
  const end = browser.indexOf('\n  @Builder', start);
  return browser.slice(start, end === -1 ? undefined : end);
};
const method = name => {
  const pattern = new RegExp(`^  private (?:async )?${name}\\([\\s\\S]*?^  \\}`, 'm');
  const source = browser.match(pattern)?.[0];
  assert.ok(source, name);
  return source.replace(/^  private async /, 'async function ').replace(/^  private /, 'function ');
};

const localState = () => {
  const sandbox = {};
  loadEtsModules('services/TaildriveSessionController', sandbox);
  vm.runInContext(stripTypeScriptTypes(method('refreshThumbnails')), sandbox);
  const state = {
    cachedEntries: [], downloadedEntries: [], thumbnails: [], activePreviewPath: '',
    path: '/share', appInForeground: true, browserVisible: true, connected: true,
    appLockActive: false, standalone: true, filesTabActive: true,
    folderLockEnabled: false, lockedFolderPaths: [], folderAccessGrants: [],
    context: () => ({}), setThumbnail: () => {},
    thumbnailPool: new poolSandbox.Pool(2),
    previewGateway: {
      cachedPreview: () => undefined,
      async cachedPreviewAsync(...args) { return this.cachedPreview(...args); },
      createThumbnail: async () => ''
    },
    refreshThumbnails: sandbox.refreshThumbnails
  };
  const controller = new TaildriveSessionController({
    isFolderLockEnabled: () => state.folderLockEnabled,
    getLockedFolderPaths: () => state.lockedFolderPaths,
    getFolderAccessGrants: () => state.folderAccessGrants,
    getCachedEntries: () => state.cachedEntries,
    setCachedEntries: entries => { state.cachedEntries = entries; },
    getDownloadedEntries: () => state.downloadedEntries,
    setDownloadedEntries: entries => { state.downloadedEntries = entries; },
    hasGatewayCachedPreview: entry => state.previewGateway.cachedPreview(state.context(), entry) !== undefined
  });
  state.hasFolderAccess = remotePath => controller.hasFolderAccess(remotePath);
  for (const name of ['localFileSnapshot', 'matchesLocalFile', 'localFileStatus', 'markCachedEntry', 'markDownloadedEntry']) {
    state[name] = (...args) => controller[name](...args);
  }
  return state;
};

const fileEntry = overrides => ({
  name: 'report.pdf', path: '/tailnet/device/share/report.pdf', kind: 'file', size: 128, modifiedAtMs: 1200,
  ...overrides
});

const refreshState = () => {
  const state = {
    path: '/share', appInForeground: true, connected: true, browserVisible: true,
    appLockActive: false, folderLockEnabled: false, lockedFolderPaths: [], folderAccessGrants: [],
    busy: false, standalone: true, filesTabActive: true, fileActionGeneration: 0,
    loading: false, pullRefreshing: false, selectionMode: false, dragSelecting: false,
    targetRequestId: 0, targetMachineName: '', targetTailnetName: '',
    reason: '', status: '', retryAvailable: false,
    entries: [], selectedPaths: [], lastListedPath: '/share', appliedPaths: [], requestedPaths: [],
    renderedEntries: [], thumbnails: [], cachedEntries: [],
    editorVisible: false, editorPath: '', editorOperation: '', editorName: '',
    detailsVisible: false, detailsLoading: false, detailsReason: '', detailEntry: fileEntry({ path: '' }),
    previewDownloadVisible: false, previewDownloadEntry: fileEntry({ path: '' }),
    moveVisible: false, moveOperation: 'move', moveTargetCount: 0, moveLoading: false, moveEntries: [], moveReason: '', movePath: '/',
    sortSheetVisible: false, folderDialogVisible: false,
    thumbnailPool: new poolSandbox.Pool(2),
    delayMsLog: [],
    gateway: { async list(reqPath) { return { state: 'ready', path: reqPath, entries: [], reason: '' }; } },
    startRefreshPolling() {},
    stopRefreshPolling() {},
    scheduleSecurityResume() {},
    clearSecurityResumeTimer() {}
  };
  const controller = new TaildriveSessionController({
    isConnected: () => state.connected,
    isStandalone: () => state.standalone,
    isFilesTabActive: () => state.filesTabActive,
    isBrowserVisible: () => state.browserVisible,
    isAppInForeground: () => state.appInForeground,
    setAppInForeground: value => { state.appInForeground = value; },
    isAppLockActive: () => state.appLockActive,
    isFolderLockEnabled: () => state.folderLockEnabled,
    getLockedFolderPaths: () => state.lockedFolderPaths,
    setLockedFolderPaths: paths => { state.lockedFolderPaths = paths; },
    getFolderAccessGrants: () => state.folderAccessGrants,
    setFolderAccessGrants: grants => { state.folderAccessGrants = grants; },
    getTargetMachineName: () => state.targetMachineName,
    getTargetTailnetName: () => state.targetTailnetName,
    getTargetRequestId: () => state.targetRequestId,
    getPath: () => state.path,
    setPath: value => { state.path = value; },
    getEntries: () => state.entries,
    setEntries: entries => { state.entries = entries; },
    getLastListedPath: () => state.lastListedPath,
    setLastListedPath: value => { state.lastListedPath = value; },
    isLoading: () => state.loading,
    setLoading: value => { state.loading = value; },
    isPullRefreshing: () => state.pullRefreshing,
    setPullRefreshing: value => { state.pullRefreshing = value; },
    isBusy: () => state.busy,
    setBusy: value => { state.busy = value; },
    getReason: () => state.reason,
    setReason: value => { state.reason = value; },
    getStatus: () => state.status,
    setStatus: value => { state.status = value; },
    showTransientStatus: value => { state.status = value; },
    isRetryAvailable: () => state.retryAvailable,
    setRetryAvailable: value => { state.retryAvailable = value; },
    isSelectionMode: () => state.selectionMode,
    setSelectionMode: value => { state.selectionMode = value; },
    isDragSelecting: () => state.dragSelecting,
    setDragSelecting: value => { state.dragSelecting = value; },
    getSelectedPaths: () => state.selectedPaths,
    setSelectedPaths: paths => { state.selectedPaths = paths; },
    getFileActionGeneration: () => state.fileActionGeneration,
    setFileActionGeneration: value => { state.fileActionGeneration = value; },
    isEditorVisible: () => state.editorVisible,
    setEditorVisible: value => { state.editorVisible = value; },
    getEditorPath: () => state.editorPath,
    getEditorOperation: () => state.editorOperation,
    setEditorName: value => { state.editorName = value; },
    isDetailsVisible: () => state.detailsVisible,
    setDetailsVisible: value => { state.detailsVisible = value; },
    setDetailsLoading: value => { state.detailsLoading = value; },
    setDetailsReason: value => { state.detailsReason = value; },
    getDetailEntry: () => state.detailEntry,
    setDetailEntry: value => { state.detailEntry = value; },
    isPreviewDownloadVisible: () => state.previewDownloadVisible,
    setPreviewDownloadVisible: value => { state.previewDownloadVisible = value; },
    getPreviewDownloadEntry: () => state.previewDownloadEntry,
    isMoveVisible: () => state.moveVisible,
    setMoveVisible: value => { state.moveVisible = value; },
    setMoveOperation: value => { state.moveOperation = value; },
    setMoveTargetCount: value => { state.moveTargetCount = value; },
    setMoveLoading: value => { state.moveLoading = value; },
    setMoveEntries: value => { state.moveEntries = value; },
    setMoveReason: value => { state.moveReason = value; },
    getMovePath: () => state.movePath,
    isSortSheetVisible: () => state.sortSheetVisible,
    setSortSheetVisible: value => { state.sortSheetVisible = value; },
    isFolderDialogVisible: () => state.folderDialogVisible,
    setFolderDialogVisible: value => { state.folderDialogVisible = value; },
    setCachedEntries: entries => { state.cachedEntries = entries; },
    clearPreviewThumbnails: () => { state.thumbnails = []; },
    cancelThumbnailPool: () => { state.thumbnailPool.cancel(); },
    stopDragAutoScroll() {},
    rebuildListDataSource() { state.renderedEntries = [...state.entries]; },
    updateBackState() {},
    publishUiBackState() {},
    vibrateTouch() {},
    startRefreshPolling: () => state.startRefreshPolling(),
    stopRefreshPolling: () => state.stopRefreshPolling(),
    scheduleSecurityResume: delayMs => state.scheduleSecurityResume(delayMs),
    clearSecurityResumeTimer: () => state.clearSecurityResumeTimer(),
    delayIndicator: async ms => { state.delayMsLog.push(ms); },
    applyListResult(result, reqPath) {
      state.entries = result.entries;
      state.lastListedPath = state.path;
      state.appliedPaths.push(reqPath);
    },
    gatewayList: reqPath => state.gateway.list(reqPath)
  });
  state.rebuildListDataSource = () => { state.renderedEntries = [...state.entries]; };
  Object.defineProperties(state, {
    refreshGeneration: {
      get: () => controller.refreshGeneration,
      set(value) { controller.refreshGeneration = value; }
    },
    refreshInFlight: {
      get: () => controller.refreshInFlight,
      set(value) { controller.refreshInFlight = value; }
    },
    refreshPending: {
      get: () => controller.refreshPending,
      set(value) { controller.refreshPending = value; }
    },
    retryKind: {
      get: () => controller.retryKind,
      set(value) { controller.retryKind = value; }
    },
    protectedFolderResumePending: {
      get: () => controller.protectedFolderResumePending,
      set(value) { controller.protectedFolderResumePending = value; }
    }
  });
  for (const name of [
    'canApplyRefresh', 'refresh', 'pullRefresh', 'onPathChanged',
    'handleAppBackground', 'handleAppForeground', 'onAppLockActiveChanged'
  ]) {
    state[name] = (...args) => controller[name](...args);
  }
  return state;
};

const lifecycleState = () => {
  const intervals = new Map();
  let nextTimer = 1;
  const sandbox = {
    TAILDRIVE_REFRESH_INTERVAL_MS: 30000,
    setInterval(callback) { const id = nextTimer++; intervals.set(id, callback); return id; },
    clearInterval(id) { intervals.delete(id); },
    setTimeout: () => nextTimer++
  };
  const names = ['startRefreshPolling', 'stopRefreshPolling'];
  vm.runInNewContext(stripTypeScriptTypes(names.map(name => method(name)).join('\n')), sandbox);
  const state = refreshState();
  state.intervals = intervals;
  state.refreshTimer = -1;
  state.securityResumeTimer = -1;
  state.clearSecurityResumeTimer = function () { this.securityResumeTimer = -1; };
  state.scheduleSecurityResume = function () { this.securityResumeTimer = nextTimer++; };
  state.startRefreshPolling = sandbox.startRefreshPolling.bind(state);
  state.stopRefreshPolling = sandbox.stopRefreshPolling.bind(state);
  return state;
};

test('file toolbar icons represent folder creation, file upload, sorting and view switching', () => {
  const normal = builder('NormalBottomToolbar');
  for (const symbol of ['folder_badge_plus', 'doc_text_badge_arrow_up', 'sort', 'square_grid_2x2', 'list_bullet']) {
    assert.ok(normal.includes(`sys.symbol.${symbol}`), symbol);
  }
  assert.doesNotMatch(normal, /Text\('\+'\)|app\.media|Image\(/);
  assert.match(builder('SelectionBottomToolbar'), /sys\.symbol\.share/);
  assert.match(builder('SelectionMoreAction'), /sys\.symbol\.ellipsis_circle/);
});

test('both file action bars align with the main floating tab bar', () => {
  const sideMargin = Number(browser.match(/TAILDRIVE_TOOLBAR_SIDE_MARGIN: number = (\d+)/)[1]);
  const mainMargin = Number(shell.match(/barSideMargin: (\d+)/)[1]);
  assert.equal(sideMargin, mainMargin);
  for (const name of ['NormalBottomToolbar', 'SelectionBottomToolbar']) {
    const toolbar = builder(name);
    assert.ok(toolbar.includes('calc(100% - ${TAILDRIVE_TOOLBAR_SIDE_MARGIN * 2}vp)'));
    assert.match(toolbar, /left: TAILDRIVE_TOOLBAR_SIDE_MARGIN/);
    assert.match(toolbar, /right: TAILDRIVE_TOOLBAR_SIDE_MARGIN/);
  }
  const normal = builder('NormalBottomToolbar');
  assert.doesNotMatch(normal, /\.width\(136\)/);
  assert.match(normal, /\.layoutWeight\(1\)/);
  assert.match(normal, /textOverflow\(\{ overflow: TextOverflow\.Ellipsis \}\)/);
  for (const viewportWidth of [320, 360, 390, 600]) {
    assert.ok(viewportWidth - sideMargin * 2 - 42 * 3 - 6 * 3 >= 100);
  }
});

test('search and back controls use native semantic symbols', () => {
  assert.match(builder('SearchField'), /sys\.symbol\.magnifyingglass/);
  assert.match(builder('TopControls'), /sys\.symbol\.chevron_left/);
  assert.match(builder('PathBar'), /sys\.symbol\.chevron_left/);
});

test('the immersive address bar is hosted in the real Navigation title extension', () => {
  const navigation = builder('StandaloneNavigation');
  assert.match(navigation, /bottomBuilder: this\.connected && !this\.selectionMode && !this\.searchVisible \? \{\s*builder: \(\): void => \{ this\.NavigationPathBar\(\); \},\s*height: 40/);
  assert.match(builder('NavigationPathBar'), /this\.PathBar\(\)/);
  assert.doesNotMatch(builder('StandaloneBrowser'), /this\.PathBar\(\)/);
  const pathBar = builder('PathBar');
  assert.equal((pathBar.match(/\.systemMaterial\(LightAppearance\.toolbarButton\(this\.glowLevel\)\)/g) || []).length, 2);
  assert.doesNotMatch(pathBar, /comp_background_tertiary|backgroundEffect|backgroundBlurStyle|\.border\(/);
  assert.match(navigation, /new SymbolGlyphModifier\(\$r\('sys\.symbol\.magnifyingglass'\)\)\s*\.fontColor\(\[\$r\('sys\.color\.icon_primary'\)\]\)/);
});

test('the HDS title extension retains the file component when invoked by an external builder host', () => {
  const expression = browser.match(/bottomBuilder: this\.connected && !this\.selectionMode && !this\.searchVisible \? \{\s*builder: ([\s\S]*?),\s*height: 40/)?.[1];
  assert.ok(expression);
  const sandbox = {};
  vm.runInNewContext(stripTypeScriptTypes(`this.create = function() { return (${expression}); };`), sandbox);
  const calls = [];
  const owner = { NavigationPathBar() { calls.push(this); } };
  const extension = sandbox.create.call(owner);
  extension.call(undefined);
  extension.call({ foreignBuilderHost: true });
  assert.deepEqual(calls, [owner, owner]);
});

test('view switch actions have matching English and Chinese accessible labels', () => {
  for (const locale of ['base', 'zh_CN']) {
    const strings = JSON.parse(readFileSync(new URL(`../entry/src/main/resources/${locale}/element/string.json`, import.meta.url), 'utf8')).string;
    for (const name of ['taildrive_grid_view_action', 'taildrive_list_view_action']) {
      assert.equal(strings.filter(item => item.name === name && item.value.length > 0).length, 1);
      assert.ok(builder('NormalBottomToolbar').includes(name));
    }
  }
});

test('downloaded marks follow the exact file version rather than only its path', () => {
  assert.doesNotMatch(browser, /\{\s*\.\.\.entry\s*\}/);
  assert.doesNotMatch(sessionControllerSource, /\{\s*\.\.\.entry\s*\}/);
  const state = localState();
  const entry = fileEntry();
  state.markDownloadedEntry(entry);
  assert.equal(state.localFileStatus(entry), 'downloaded');
  for (const changed of [
    fileEntry({ kind: 'directory' }), fileEntry({ path: '/other/report.pdf' }),
    fileEntry({ size: 129 }), fileEntry({ modifiedAtMs: 1201 }), fileEntry({ name: 'renamed.pdf' })
  ]) {
    assert.equal(state.localFileStatus(changed), '');
  }
  entry.modifiedAtMs = 1400;
  assert.equal(state.localFileStatus(entry), '');
});

test('valid preview caches take precedence and missing or partial caches never get a mark', () => {
  const state = localState();
  const entry = fileEntry();
  state.markCachedEntry(entry);
  assert.equal(state.localFileStatus(entry), '');
  state.markDownloadedEntry(entry);
  state.previewGateway.cachedPreview = () => ({ path: '/cache/report.pdf', thumbnailPath: '' });
  state.markCachedEntry(entry);
  assert.equal(state.localFileStatus(entry), 'cached');
  assert.equal(state.localFileStatus(fileEntry({ modifiedAtMs: 1300 })), '');
});

test('cache snapshots reuse existing file validation and exclude in-progress downloads', async () => {
  const state = localState();
  const entry = fileEntry();
  state.previewGateway.cachedPreview = () => ({ path: '/cache/report.pdf', thumbnailPath: '' });
  state.activePreviewPath = entry.path;
  state.refreshThumbnails([entry]);
  await flush();
  assert.equal(state.localFileStatus(entry), '');
  state.activePreviewPath = '';
  state.refreshThumbnails([entry]);
  await flush();
  assert.equal(state.localFileStatus(entry), 'cached');
  state.previewGateway.cachedPreview = () => undefined;
  state.refreshThumbnails([entry]);
  await flush();
  assert.equal(state.localFileStatus(entry), '');
});

test('large folders and repeated navigation retain at most two thumbnail operations', async () => {
  const state = localState();
  const releases = [];
  let active = 0, peak = 0;
  state.previewGateway.cachedPreview = () => ({ path: '/cached', thumbnailPath: '' });
  state.previewGateway.createThumbnail = () => {
    active++; peak = Math.max(peak, active);
    return new Promise(resolve => releases.push(() => { active--; resolve('/thumb'); }));
  };
  const applied = [];
  state.setThumbnail = entry => applied.push(entry.path);
  state.refreshThumbnails(Array.from({ length: 200 }, (_, i) => fileEntry({ path: '/old/' + i })));
  await flush();
  assert.equal(active, 2);
  state.path = '/new';
  state.refreshThumbnails([fileEntry({ path: '/new/a' })]);
  await flush();
  assert.equal(active, 2);
  releases.shift()();
  await flush();
  assert.equal(active, 2);
  releases.shift()();
  await flush();
  assert.deepEqual(applied, []);
  releases.shift()();
  await flush();
  assert.deepEqual(applied, ['/new/a']);
  assert.equal(peak, 2);
});

test('leaving files or backgrounding cannot publish a late thumbnail', async () => {
  for (const field of ['appInForeground', 'browserVisible', 'connected', 'filesTabActive']) {
    const state = localState();
    let complete;
    state.previewGateway.cachedPreview = () => ({ path: '/cached', thumbnailPath: '' });
    state.previewGateway.createThumbnail = () => new Promise(resolve => { complete = resolve; });
    state.setThumbnail = () => assert.fail('stale thumbnail');
    state.refreshThumbnails([fileEntry()]);
    await flush();
    state[field] = false;
    complete('/thumb');
    await flush();
  }
});

test('local status badges coexist with selection and never perform file IO while rendering', () => {
  assert.match(builder('FileListRow'), /this\.LocalFileStatus\(entry, 17\)/);
  assert.match(builder('EntryIcon'), /this\.viewMode === 'grid'[\s\S]*?this\.LocalFileStatus\(entry, 13\)/);
  assert.match(builder('LocalFileStatus'), /accessibilityText/);
  for (const source of [method('localFileStatus'), sessionControllerSource, builder('LocalFileStatus')]) {
    assert.doesNotMatch(source, /fileIo|statSync|cachedPreview\(|readdir/);
  }
  assert.match(method('download'), /if \(exported\) \{\s*this\.markDownloadedEntry\(entry\)/);
  assert.match(method('downloadForPreview'), /if \(!downloadCompleted\)[\s\S]*?return;[\s\S]*?this\.markCachedEntry\(entry\)/);
  for (const locale of ['base', 'zh_CN']) {
    const strings = JSON.parse(readFileSync(new URL(`../entry/src/main/resources/${locale}/element/string.json`, import.meta.url), 'utf8')).string;
    for (const name of ['taildrive_cached_file', 'taildrive_downloaded_file']) {
      assert.equal(strings.filter(item => item.name === name && item.value.length > 0).length, 1);
    }
  }
});

test('grid file cards have no outer border and preserve selection and local status', () => {
  const card = builder('FileGridCell');
  assert.doesNotMatch(card, /\.border\(/);
  assert.match(card, /this\.EntryIcon\(entry, 42\)/);
  assert.match(card, /this\.SelectionMark\(entry\)/);
  assert.match(card, /\.onClick\(\(\) => this\.openEntry\(entry\)\)/);
  assert.match(card, /bindContextMenu\(this\.EntryContextMenu\(entry\), ResponseType\.LongPress/);
  assert.match(builder('EntryIcon'), /this\.LocalFileStatus\(entry, 13\)/);
});

test('native pull refresh covers list, grid and scrollable empty states', () => {
  const viewport = builder('RefreshableEntryViewport');
  assert.match(viewport, /Refresh\(\{ refreshing: \$\$this\.pullRefreshing \}\)/);
  assert.match(viewport, /this\.StandaloneEntryViewport\(\)/);
  assert.match(viewport, /onRefreshing\([\s\S]*?this\.pullRefresh\(\)/);
  assert.match(viewport, /pullToRefresh\(this\.connected && !this\.busy && !this\.appLockActive/);
  const content = builder('StandaloneEntryViewport');
  assert.match(content, /Scroll\(this\.contentScroller\)/);
  assert.equal((content.match(/alwaysEnabled: true/g) || []).length, 3);
  assert.match(builder('StandaloneBrowser'), /this\.RefreshableEntryViewport\(\)/);
});

test('pull indicators finish after success, failure or a blocked request', async () => {
  for (const outcome of ['success', 'failure', 'blocked']) {
    const state = refreshState();
    state.pullRefreshing = true;
    let requestCount = 0;
    state.gateway = {
      async list(reqPath) {
        requestCount++;
        assert.equal(state.pullRefreshing, true);
        if (outcome === 'failure') { throw new Error('offline'); }
        return { state: 'ready', path: reqPath, entries: [], reason: '' };
      }
    };
    if (outcome === 'blocked') { state.busy = true; }
    await state.pullRefresh();
    assert.equal(state.pullRefreshing, false);
    assert.equal(requestCount, outcome === 'blocked' ? 0 : 1);
    if (outcome !== 'blocked') {
      assert.ok(state.delayMsLog.length === 1 && state.delayMsLog[0] > 0 && state.delayMsLog[0] <= 450);
    }
    assert.equal(state.retryKind, outcome === 'failure' ? 'refresh' : '');
  }
});

test('late refresh results cannot update a hidden, disconnected, locked or superseded view', async () => {
  for (const invalidate of [
    state => { state.appInForeground = false; },
    state => { state.browserVisible = false; }, state => { state.connected = false; },
    state => { state.filesTabActive = false; }, state => { state.appLockActive = true; },
    state => { state.folderLockEnabled = true; state.lockedFolderPaths = ['/share']; },
    state => { state.refreshGeneration++; }
  ]) {
    const state = refreshState();
    let finish;
    state.gateway = { list: () => new Promise(resolve => { finish = resolve; }) };
    const pending = state.refresh();
    invalidate(state);
    finish({ state: 'ready', path: '/share', entries: [fileEntry()] });
    await pending;
    assert.equal(state.appliedPaths.length, 0);
    assert.equal(state.loading, false);
    assert.equal(state.refreshInFlight, false);
  }
});

test('background stops polling and blocks new directory work without clearing content or cancelling transfers', async () => {
  const state = lifecycleState();
  state.entries = [fileEntry()];
  let requests = 0;
  state.gateway = { async list() { requests++; return { state: 'ready', entries: [] }; },
    cancel() { assert.fail('background must not cancel transfers'); } };
  state.startRefreshPolling();
  assert.equal(state.intervals.size, 1);
  state.handleAppBackground();
  assert.equal(state.intervals.size, 0);
  assert.equal(state.pullRefreshing, false);
  state.startRefreshPolling();
  await state.refresh();
  assert.equal(state.intervals.size, 0);
  assert.equal(requests, 0);
  assert.equal(state.entries.length, 1);
});

test('foreground return coalesces with an obsolete in-flight request and applies only a fresh listing', async () => {
  const state = lifecycleState();
  let finish;
  let requests = 0;
  state.gateway = { list: () => {
    requests++;
    return requests === 1 ? new Promise(resolve => { finish = resolve; }) :
      Promise.resolve({ state: 'ready', path: '/share', entries: [fileEntry({ name: 'fresh.pdf' })] });
  } };
  const pending = state.refresh();
  state.handleAppBackground();
  state.handleAppForeground();
  state.handleAppForeground();
  assert.equal(requests, 1);
  assert.equal(state.intervals.size, 1);
  finish({ state: 'ready', path: '/share', entries: [fileEntry({ name: 'old.pdf' })] });
  await pending;
  await flush();
  assert.equal(requests, 2);
  assert.equal(state.appliedPaths.length, 1);
  assert.equal(state.entries[0].name, 'fresh.pdf');
});

test('hidden files tabs and app locks never restart polling; unlock refreshes once', async () => {
  for (const blocked of ['filesTabActive', 'browserVisible', 'connected']) {
    const state = lifecycleState();
    state[blocked] = false;
    state.gateway = { async list() { assert.fail('inactive page must not refresh'); } };
    state.handleAppBackground();
    state.handleAppForeground();
    assert.equal(state.intervals.size, 0);
  }
  const state = lifecycleState();
  let requests = 0;
  state.gateway = { async list() { requests++; return { state: 'ready', entries: [] }; } };
  state.startRefreshPolling();
  state.appLockActive = true;
  state.onAppLockActiveChanged();
  state.handleAppForeground();
  await flush();
  assert.equal(state.intervals.size, 0);
  assert.equal(requests, 0);
  state.appLockActive = false;
  state.onAppLockActiveChanged();
  await flush();
  assert.equal(state.intervals.size, 1);
  assert.equal(requests, 1);
});

test('foreground return to a protected folder waits for its existing authentication path', () => {
  const state = lifecycleState();
  state.folderLockEnabled = true;
  state.lockedFolderPaths = ['/share'];
  state.folderAccessGrants = ['/share'];
  state.gateway = { async list() { assert.fail('protected content must await authentication'); } };
  state.handleAppBackground();
  state.handleAppForeground();
  assert.equal(state.folderAccessGrants.length, 0);
  assert.equal(state.protectedFolderResumePending, true);
  assert.equal(state.resumed, undefined);
});

test('directory changes coalesce into one latest-path refresh without applying the old response', async () => {
  const state = refreshState();
  let finish;
  state.gateway = { list: path => {
    state.requestedPaths.push(path);
    if (path === '/share') { return new Promise(resolve => { finish = resolve; }); }
    return Promise.resolve({ state: 'ready', path, entries: [fileEntry({ path: '/new/report.pdf' })] });
  } };
  const pending = state.refresh();
  state.path = '/new';
  await state.refresh();
  await state.refresh();
  finish({ state: 'ready', path: '/share', entries: [fileEntry()] });
  await pending;
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(state.requestedPaths, ['/share', '/new']);
  assert.deepEqual(state.appliedPaths, ['/new']);
  assert.equal(state.entries[0].path, '/new/report.pdf');
});

test('failed obsolete requests do not overwrite current errors or schedule hidden work', async () => {
  const state = refreshState();
  let fail;
  state.gateway = { list: () => new Promise((_resolve, reject) => { fail = reject; }) };
  const pending = state.refresh();
  state.filesTabActive = false;
  state.reason = 'current-view-reason';
  state.refreshPending = true;
  fail(new Error('old network failure'));
  await pending;
  assert.equal(state.reason, 'current-view-reason');
  assert.equal(state.retryKind, '');
  assert.equal(state.refreshPending, false);
});

test('returning to the same path rejects its earlier generation and loads the latest directory once', async () => {
  const state = refreshState();
  let finish;
  let requests = 0;
  state.gateway = { list: () => {
    requests++;
    return requests === 1 ? new Promise(resolve => { finish = resolve; }) :
      Promise.resolve({ state: 'ready', path: '/share', entries: [fileEntry({ name: 'latest.pdf' })] });
  } };
  const pending = state.refresh();
  state.path = '/other';
  state.onPathChanged();
  await state.refresh();
  state.path = '/share';
  state.onPathChanged();
  await state.refresh();
  finish({ state: 'ready', path: '/share', entries: [fileEntry({ name: 'obsolete.pdf' })] });
  await pending;
  await flush();
  assert.equal(requests, 2);
  assert.equal(state.appliedPaths.length, 1);
  assert.equal(state.entries[0].name, 'latest.pdf');
});

test('directory failure feedback takes precedence while other operation statuses retain their own messages', () => {
  const sandbox = { $r: name => name };
  const names = ['statusText', 'statusCodeText'];
  vm.runInNewContext(stripTypeScriptTypes(names.map(name => method(name)).join('\n')), sandbox);
  const state = {
    retryAvailable: true, reason: 'timeout', status: 'download_completed',
    entries: [fileEntry()], lastListedPath: '/share', path: '/share',
    ...Object.fromEntries(names.map(name => [name, sandbox[name]]))
  };
  const controller = new TaildriveSessionController({
    isRetryAvailable: () => state.retryAvailable,
    getReason: () => state.reason,
    getEntries: () => state.entries,
    getLastListedPath: () => state.lastListedPath,
    getPath: () => state.path
  });
  controller.retryKind = 'refresh';
  Object.defineProperty(state, 'retryKind', {
    get: () => controller.retryKind,
    set(value) { controller.retryKind = value; }
  });
  state.hasListFailure = () => controller.hasListFailure();
  state.showRetainedListNotice = () => controller.showRetainedListNotice();
  assert.equal(state.statusText(), 'app.string.taildrive_status_timeout');
  assert.equal(state.showRetainedListNotice(), true);
  state.path = '/other';
  assert.equal(state.showRetainedListNotice(), false);
  state.path = '/share';
  state.entries = [];
  assert.equal(state.showRetainedListNotice(), false);
  state.retryKind = 'download';
  assert.equal(state.statusText(), 'app.string.taildrive_status_download_completed');
  state.retryKind = 'refresh';
  state.reason = 'list_failed';
  assert.equal(state.statusText(), 'app.string.taildrive_list_failed');
  state.retryAvailable = false;
  assert.equal(state.hasListFailure(), false);
  assert.equal(state.statusText(), 'app.string.taildrive_status_download_completed');
});

test('changing directories drops old visible files and selections even when the new listing fails', async () => {
  const state = refreshState();
  const oldEntry = fileEntry({ path: '/share/old.pdf' });
  state.entries = [oldEntry];
  state.selectedPaths = [oldEntry.path];
  state.rebuildListDataSource();
  state.path = '/other';
  state.onPathChanged();
  assert.equal(state.entries.length, 0);
  assert.equal(state.selectedPaths.length, 0);
  assert.equal(state.renderedEntries.length, 0);
  state.gateway = { async list() { return { state: 'error', reason: 'timeout' }; } };
  await state.refresh();
  assert.equal(state.entries.length, 0);
  assert.equal(state.reason, 'timeout');
  assert.equal(state.lastListedPath, '');
});

test('same-directory refresh retains the existing list and selection while waiting or after failure', async () => {
  const state = refreshState();
  const oldEntry = fileEntry();
  state.entries = [oldEntry];
  state.selectedPaths = [oldEntry.path];
  let fail;
  state.gateway = { list: () => new Promise((_resolve, reject) => { fail = reject; }) };
  const pending = state.refresh();
  assert.equal(state.entries[0], oldEntry);
  assert.equal(state.selectedPaths[0], oldEntry.path);
  fail(new Error('network interrupted'));
  await pending;
  assert.equal(state.entries[0], oldEntry);
  assert.equal(state.selectedPaths[0], oldEntry.path);
  assert.equal(state.lastListedPath, '/share');
});

test('path bar is slim and multi-select toolbar uses reactive $$ objects with full-capsule geometry', () => {
  const pathBar = builder('PathBar');
  assert.match(pathBar, /\.width\(34\)\s*\.height\(34\)/);
  assert.match(pathBar, /\.height\(34\)[\s\S]*?\.borderRadius\(17\)/);
  assert.match(builder('NavigationPathBar'), /\.height\(40\)/);

  assert.match(browser, /@Builder\s+private SelectionAction\(\$\$: TaildriveSelectionActionData\)/);
  assert.match(browser, /@Builder\s+private SelectionMoreAction\(\$\$: TaildriveSelectionMoreData\)/);
  const actionBuilder = builder('SelectionAction');
  const moreBuilder = builder('SelectionMoreAction');
  assert.match(actionBuilder, /\.enabled\(\$\$\.isEnabled\)/);
  assert.match(moreBuilder, /\.enabled\(\$\$\.isEnabled\)/);
  assert.doesNotMatch(actionBuilder + moreBuilder, /\.opacity\(/);

  const selectionToolbar = builder('SelectionBottomToolbar');
  assert.match(selectionToolbar, /\.height\(TAILDRIVE_SELECTION_TOOLBAR_HEIGHT\)/);
  assert.match(selectionToolbar, /\.borderRadius\(TAILDRIVE_SELECTION_TOOLBAR_HEIGHT \/ 2\)/);
  assert.ok(browser.includes('const TAILDRIVE_SELECTION_TOOLBAR_HEIGHT: number = 48;'));

  const navigation = builder('StandaloneNavigation');
  assert.match(navigation, /new SymbolGlyphModifier\(\$r\('sys\.symbol\.xmark'\)\)\s*\.fontColor\(\[\$r\('sys\.color\.icon_primary'\)\]\)/);
  assert.doesNotMatch(builder('StandaloneBrowser'), /if \(this\.searchVisible \|\| this\.selectionMode\)/);
});

test('every this.<ident> reference in TaildriveBrowser resolves to a declared struct member or @Component built-in', () => {
  const structStart = browser.indexOf('export struct TaildriveBrowser {');
  assert.notEqual(structStart, -1);
  const structBody = browser.slice(structStart);

  const declared = new Set(['getUIContext', 'getUniqueId']);
  const fieldPattern = /^  (?:@[A-Za-z0-9_]+(?:\([^)]*\))?\s+)*(?:private\s+|public\s+)?(?:readonly\s+|static\s+)*([A-Za-z_][A-Za-z0-9_]*)\s*:/gm;
  const methodPattern = /^  (?:private\s+|public\s+)?(?:static\s+)?(?:async\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(/gm;
  for (const match of structBody.matchAll(fieldPattern)) {
    declared.add(match[1]);
  }
  for (const match of structBody.matchAll(methodPattern)) {
    declared.add(match[1]);
  }
  assert.ok(declared.has('sessionController') && declared.has('sessionHost'));
  assert.ok(!declared.has('dragSuppressClickUntilMs') && !declared.has('retryKind'));

  // Strip block/line comments and single/double-quoted string literals before scanning `this.<ident>`.
  const stripped = structBody
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/\/\/[^\n]*/g, '')
    .replace(/'(?:\\.|[^'\\])*'/g, "''")
    .replace(/"(?:\\.|[^"\\])*"/g, '""');

  const unresolved = [];
  const lines = stripped.split('\n');
  lines.forEach((line, idx) => {
    for (const match of line.matchAll(/(?:\$\$|\b)this\.([A-Za-z_][A-Za-z0-9_]*)\b/g)) {
      const ident = match[1];
      if (!declared.has(ident)) {
        unresolved.push(`${ident} (struct line +${idx})`);
      }
    }
  });
  assert.deepEqual(unresolved, []);

  assert.match(builder('SelectionMark'), /Date\.now\(\) >= this\.sessionController\.dragSuppressClickUntilMs/);
  assert.match(
    builder('StandaloneEntryViewport'),
    /this\.reason\.length > 0 && this\.retryAvailable &&\s*\(this\.sessionController\.retryKind === 'refresh' \|\| this\.sessionController\.retryKind === 'target'\)/
  );
});
