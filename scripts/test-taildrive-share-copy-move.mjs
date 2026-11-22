import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
import { loadEtsModules } from './helpers/ets-vm-loader.mjs';

const { TaildriveSessionController } = loadEtsModules(['services/TaildriveSessionController']);

const browserSource = readFileSync(
  new URL('../entry/src/main/ets/components/TaildriveBrowser.ets', import.meta.url),
  'utf8'
);
const goTaildriveSource = readFileSync(
  new URL('../native/go_bridge/taildrive.go', import.meta.url),
  'utf8'
);

const flush = () => new Promise(resolve => setImmediate(resolve));
const root = '/tailnet/device/share';
const fileEntry = (name, size = 128, modifiedAtMs = 1000) => ({
  name,
  path: `${root}/${name}`,
  kind: 'file',
  size,
  modifiedAtMs
});
const dirEntry = (name) => ({
  name,
  path: `${root}/${name}`,
  kind: 'directory',
  size: 0,
  modifiedAtMs: 1000
});

function extractMethod(source, name) {
  const match = source.match(new RegExp(`^  private (?:async )?${name}\\([\\s\\S]*?^  \\}`, 'm'))?.[0];
  assert.ok(match, `missing method ${name}`);
  return match.replace(/^  private async /, 'async function ').replace(/^  private /, 'function ');
}

function extractBuilder(source, name) {
  const start = source.indexOf(`  private ${name}(`);
  assert.notEqual(start, -1, `missing builder ${name}`);
  const end = source.indexOf('\n  @Builder', start);
  return source.slice(start, end === -1 ? undefined : end);
}

function createShareFixture() {
  const names = [
    'snapshotFileEntry',
    'fileExtension',
    'canShareSelected',
    'shareUtdForEntry',
    'shareSelectedEntries',
    'shareEntries',
    'cancelPreviewDownload',
    'showMoreSelected'
  ];
  const shownControllers = [];
  class FakeSharedData {
    constructor(record) {
      this.records = [record];
    }
    addRecord(record) {
      this.records.push(record);
    }
    getRecords() {
      return this.records;
    }
  }
  class FakeShareController {
    constructor(data) {
      this.data = data;
      this.calls = [];
    }
    async show(context, options) {
      this.calls.push({ context, options, records: this.data.getRecords() });
      shownControllers.push(this);
    }
  }
  const sandbox = {
    uniformTypeDescriptor: {
      UniformDataType: { FILE: 'general.file' },
      getUniformDataTypeByFilenameExtension(ext) {
        return ext === '.txt' ? 'general.plain-text' : ext === '.pdf' ? 'com.adobe.pdf' : '';
      }
    },
    fileUri: {
      getUriFromPath(path) {
        return `file://io.github.tailscaleohos${path}`;
      }
    },
    systemShare: {
      SharedData: FakeSharedData,
      ShareController: FakeShareController,
      SharePreviewMode: { DEFAULT: 0 },
      SelectionMode: { SINGLE: 0, BATCH: 1 }
    },
    clearTaildriveProgress: async () => {}
  };
  loadEtsModules('services/TaildriveSessionController', sandbox);
  vm.runInContext(stripTypeScriptTypes(names.map(name => extractMethod(browserSource, name)).join('\n')), sandbox);

  const cachedDisk = new Map();
  const state = {
    path: root,
    connected: true,
    busy: false,
    browserVisible: true,
    appLockActive: false,
    previewDownloading: false,
    previewGeneration: 0,
    previewRequestId: 0,
    activePreviewPath: '',
    nextTransferRequestId: 10,
    retryKind: '',
    sessionController: { retryKind: '' },
    status: '',
    entries: [],
    selectedPaths: [],
    cachedEntries: [],
    transfer: { state: 'idle' },
    shownControllers,
    downloads: [],
    detailsShown: [],
    pollStarts: 0,
    pollStops: 0,
    thumbRefreshes: 0,
    cachedDisk,
    context() {
      return { tag: 'ui-context' };
    },
    selectedEntries() {
      return this.entries.filter(item => this.selectedPaths.includes(item.path));
    },
    newTransferRequestId() {
      return ++this.nextTransferRequestId;
    },
    clearRetry() {
      this.retryKind = '';
      this.sessionController.retryKind = '';
    },
    startTransferPolling() {
      this.pollStarts++;
    },
    stopTransferPolling() {
      this.pollStops++;
    },
    markCachedEntry(entry) {
      if (this.previewGateway.cachedPreview(this.context(), entry) !== undefined) {
        this.cachedEntries = [...this.cachedEntries.filter(item => item.path !== entry.path), entry];
      }
    },
    refreshThumbnails() {
      this.thumbRefreshes++;
    },
    showDetails(entry) {
      this.detailsShown.push(entry);
    },
    async ensureFolderAccess() {
      return true;
    },
    previewGateway: {
      root() {
        return '/data/cache/taildrive-previews';
      },
      cachedPreview(_ctx, entry) {
        const localPath = cachedDisk.get(entry.path);
        return localPath ? { path: localPath, thumbnailPath: '' } : undefined;
      },
      prepareDownload(_ctx, entry) {
        return `/data/cache/taildrive-previews/hash/${entry.name}`;
      }
    },
    gateway: {
      async download(req) {
        state.downloads.push(req);
        cachedDisk.set(req.remotePath, req.localPath);
        return {
          requestId: req.requestId,
          direction: 'download',
          state: 'completed',
          reason: '',
          remotePath: req.remotePath,
          localPath: req.localPath,
          fileName: req.remotePath.split('/').at(-1),
          bytes: 128,
          totalBytes: 128,
          startedAtMs: 1,
          completedAtMs: 2
        };
      },
      async cancel() {
        return { state: 'failed', reason: 'cancelled' };
      }
    },
    ...Object.fromEntries(names.map(name => [name, sandbox[name]]))
  };
  return state;
}

function createCopyMoveFixture() {
  const state = {
    path: `${root}/folder`,
    connected: true,
    busy: false,
    loading: false,
    browserVisible: true,
    standalone: true,
    filesTabActive: true,
    appInForeground: true,
    appLockActive: false,
    folderLockEnabled: false,
    lockedFolderPaths: [],
    folderAccessGrants: [],
    folderAccessAuthInFlight: false,
    selectionMode: true,
    selectedPaths: [],
    entries: [],
    fileActionGeneration: 1,
    moveVisible: false,
    moveOperation: 'move',
    moveTargetCount: 0,
    moveLoading: false,
    moveSubmitInFlight: false,
    movePath: '/',
    moveRoot: '/',
    moveEntries: [],
    moveReason: '',
    status: '',
    reason: '',
    retryAvailable: false,
    mutations: [],
    refreshes: 0,
    selectionExits: 0
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
    stopDragAutoScroll() {},
    rebuildListDataSource() {},
    publishUiBackState() {},
    recordSecurityDiagnostic() {},
    saveLockedFolderPaths: async () => {},
    delayIndicator: async () => {},
    applyListResult() { state.refreshes++; },
    gatewayList: async reqPath => ({ state: 'ready', reason: '', path: reqPath, entries: [] }),
    gatewayMutate: async request => {
      state.mutations.push(request);
      return { state: 'completed', operation: request.operation, path: request.path, newPath: request.newPath, reason: '' };
    }
  });
  for (const name of [
    'openMovePicker', 'openDestinationPickerForEntries', 'openCopySelectedPicker',
    'openMoveSelectedPicker', 'moveGoUp', 'openMoveDirectory', 'closeMovePicker',
    'validMoveDestination', 'moveDestinationEntries', 'confirmMove'
  ]) {
    state[name] = (...args) => controller[name](...args);
  }
  return state;
}

test('sharing uncached single or multiple files downloads missing caches first and opens SINGLE/BATCH share sheet', async () => {
  const state = createShareFixture();
  const a = fileEntry('notes.txt', 12);
  const b = fileEntry('doc.pdf', 200);
  const dir = dirEntry('sub');
  state.entries = [a, b, dir];

  // Directory + file cannot share together.
  state.selectedPaths = [a.path, dir.path];
  assert.equal(state.canShareSelected(), false);

  // Single uncached file auto-caches then opens SINGLE share sheet.
  state.selectedPaths = [a.path];
  assert.equal(state.canShareSelected(), true);
  await state.shareSelectedEntries();
  assert.equal(state.downloads.length, 1);
  assert.equal(state.downloads[0].remotePath, a.path);
  assert.equal(state.shownControllers.length, 1);
  assert.equal(state.shownControllers[0].calls[0].options.selectionMode, 0);
  assert.equal(state.shownControllers[0].calls[0].records[0].utd, 'general.plain-text');
  assert.notEqual(state.status, 'select_one_for_details');

  // Selecting 2 files where `a` is now cached and `b` is uncached only downloads `b`, then opens BATCH share sheet.
  state.selectedPaths = [a.path, b.path];
  assert.equal(state.canShareSelected(), true);
  await state.shareSelectedEntries();
  assert.equal(state.downloads.length, 2);
  assert.equal(state.downloads[1].remotePath, b.path);
  assert.equal(state.shownControllers.length, 2);
  assert.equal(state.shownControllers[1].calls[0].options.selectionMode, 1);
  assert.equal(state.shownControllers[1].calls[0].records.length, 2);
  assert.equal(state.shownControllers[1].calls[0].records[1].utd, 'com.adobe.pdf');
  assert.equal(state.previewDownloading, false);
});

test('share auto-cache failure cleans up transfer state and reports failure without opening share sheet', async () => {
  const state = createShareFixture();
  const a = fileEntry('notes.txt', 12);
  state.entries = [a];
  state.selectedPaths = [a.path];
  state.gateway.download = async (req) => ({
    requestId: req.requestId,
    direction: 'download',
    state: 'failed',
    reason: 'remote_unavailable',
    remotePath: req.remotePath,
    localPath: req.localPath,
    fileName: 'notes.txt',
    bytes: 0,
    totalBytes: 12,
    startedAtMs: 1,
    completedAtMs: 2
  });
  await state.shareSelectedEntries();
  assert.equal(state.shownControllers.length, 0);
  assert.equal(state.previewDownloading, false);
  assert.equal(state.status, 'remote_unavailable');
});

test('More button is disabled when 0 or more than 1 items are selected and only opens details for 1 item', () => {
  const toolbar = extractBuilder(browserSource, 'SelectionBottomToolbar');
  assert.match(toolbar, /SelectionMoreAction\(\{[\s\S]*?isEnabled:\s*this\.selectedEntries\(\)\.length === 1 && !this\.busy/);
  for (const id of [
    'taildrive-selection-share',
    'taildrive-selection-copy',
    'taildrive-selection-move',
    'taildrive-selection-delete',
    'taildrive-selection-more'
  ]) {
    assert.ok(toolbar.includes(`'${id}'`), `missing ${id}`);
  }

  const state = createShareFixture();
  const a = fileEntry('a.txt');
  const b = fileEntry('b.txt');
  state.entries = [a, b];
  state.selectedPaths = [a.path, b.path];
  state.showMoreSelected();
  assert.equal(state.detailsShown.length, 0);
  assert.equal(state.status, '');

  state.selectedPaths = [a.path];
  state.showMoreSelected();
  assert.equal(state.detailsShown.length, 1);
  assert.equal(state.detailsShown[0].path, a.path);
});

test('batch copy and move operate cleanly across multiple entries and suffix same-folder copies', async () => {
  const state = createCopyMoveFixture();
  const a = { name: 'report.pdf', path: `${root}/folder/report.pdf`, kind: 'file', size: 10, modifiedAtMs: 0 };
  const b = { name: 'sub', path: `${root}/folder/sub`, kind: 'directory', size: 0, modifiedAtMs: 0 };
  state.entries = [a, b];
  state.selectedPaths = [a.path, b.path];

  // Batch copy starts at current subfolder, allows stepping up above share root, and auto-suffixes same-folder copies
  await state.openCopySelectedPicker();
  assert.equal(state.moveVisible, true);
  assert.equal(state.moveOperation, 'copy');
  assert.equal(state.movePath, `${root}/folder`);
  assert.equal(state.validMoveDestination(`${root}/folder/sub/child`), false);
  state.moveGoUp();
  await flush();
  assert.equal(state.movePath, root);
  state.moveGoUp();
  await flush();
  assert.equal(state.movePath, '/tailnet/device');
  assert.equal(state.validMoveDestination(state.movePath), false);
  state.moveGoUp();
  await flush();
  assert.equal(state.movePath, '/tailnet');
  state.moveGoUp();
  await flush();
  assert.equal(state.movePath, '/');

  state.movePath = `${root}/folder`;
  state.moveEntries = [a, b, { name: 'report (2).pdf', path: `${root}/folder/report (2).pdf`, kind: 'file', size: 10, modifiedAtMs: 0 }];
  await state.confirmMove();
  assert.equal(state.mutations.length, 2);
  assert.deepEqual(JSON.parse(JSON.stringify(state.mutations)), [
    { operation: 'copy', path: a.path, newPath: `${root}/folder/${encodeURIComponent('report (3).pdf')}` },
    { operation: 'copy', path: b.path, newPath: `${root}/folder/${encodeURIComponent('sub (2)')}` }
  ]);
  assert.equal(state.status, 'copy_completed');
  assert.equal(state.selectionExits, 1);

  // Batch move across devices/shares
  state.mutations = [];
  state.selectionMode = true;
  state.selectedPaths = [a.path, b.path];
  await state.openMoveSelectedPicker();
  assert.equal(state.moveOperation, 'move');
  state.movePath = '/tailnet/other-device/other-share';
  await state.confirmMove();
  assert.deepEqual(JSON.parse(JSON.stringify(state.mutations)), [
    { operation: 'move', path: a.path, newPath: '/tailnet/other-device/other-share/report.pdf' },
    { operation: 'move', path: b.path, newPath: '/tailnet/other-device/other-share/sub' }
  ]);
  assert.equal(state.status, 'move_completed');
  assert.equal(state.selectionMode, false);
});

test('DetailsSheet, floating status host, and Go WebDAV COPY wiring preserve all required structure', () => {
  const detailsSheet = extractBuilder(browserSource, 'DetailsSheet');
  for (const id of [
    'taildrive-details-sheet',
    'taildrive-details-name',
    'taildrive-details-download',
    'taildrive-details-share',
    'taildrive-details-copy-path',
    'taildrive-details-copy',
    'taildrive-details-move',
    'taildrive-details-rename',
    'taildrive-details-delete',
    'taildrive-details-error',
    'taildrive-details-loading',
    'taildrive-details-context-changed'
  ]) {
    assert.ok(detailsSheet.includes(`'${id}'`), `missing DetailsSheet id ${id}`);
  }
  assert.match(browserSource, /detents:\s*\['66%',\s*'86%'\]/);
  assert.match(browserSource, /title:\s*\{\s*title:\s*\$r\('app\.string\.taildrive_details_title'\)\s*\}/);

  const standalone = extractBuilder(browserSource, 'StandaloneBrowser');
  assert.match(standalone, /Stack\(\)\s*\{[\s\S]*?this\.RefreshableEntryViewport\(\)[\s\S]*?margin\(\{\s*bottom:\s*this\.fileToolbarHeight\(\)\s*\+\s*8\s*\}\)[\s\S]*?taildrive-floating-status-host[\s\S]*?\.alignContent\(Alignment\.Bottom\)/);

  const transferStatus = extractBuilder(browserSource, 'TransferStatus');
  const operationStatus = extractBuilder(browserSource, 'OperationStatus');
  assert.match(transferStatus, /taildrive-transfer-cancel/);
  assert.match(transferStatus, /backgroundBlurStyle\(this\.standalone \? BlurStyle\.COMPONENT_THICK : BlurStyle\.NONE\)/);
  assert.match(operationStatus, /backgroundBlurStyle\(this\.standalone \? BlurStyle\.COMPONENT_THICK : BlurStyle\.NONE\)/);

  const bannerSandbox = {};
  vm.runInNewContext(
    stripTypeScriptTypes(
      ['isTransferBannerVisible', 'isOperationBannerVisible'].map(name => extractMethod(browserSource, name)).join('\n')
    ),
    bannerSandbox
  );
  const bannerState = {
    busy: false,
    previewDownloading: true,
    transfer: { state: 'transferring' },
    status: 'share_downloading',
    retryAvailable: false,
    ...bannerSandbox
  };
  assert.equal(bannerState.isTransferBannerVisible(), true);
  assert.equal(bannerState.isOperationBannerVisible(), false);
  bannerState.previewDownloading = false;
  assert.equal(bannerState.isTransferBannerVisible(), false);
  assert.equal(bannerState.isOperationBannerVisible(), true);

  const moveSheet = extractBuilder(browserSource, 'MoveSheet');
  assert.match(moveSheet, /sys\.symbol\.chevron_left[\s\S]*?id\('taildrive-move-up'\)/);
  assert.match(moveSheet, /\.align\(Alignment\.TopStart\)/);
  assert.ok(moveSheet.includes("'taildrive-move-breadcrumb-root'"));
  assert.ok(moveSheet.includes("'taildrive-move-share-hint'"));
  assert.ok(moveSheet.includes("'taildrive-move-path'"));
  assert.match(moveSheet, /font_primary[\s\S]*?id\('taildrive-move-path'\)/);
  assert.match(moveSheet, /\.fontColor\(\$r\('sys\.color\.font_primary'\)\)[\s\S]*?id\('taildrive-move-cancel'\)/);
  assert.match(moveSheet, /taildrive_move_no_subfolders/);
  assert.match(detailsSheet, /\.align\(Alignment\.TopStart\)/);
  assert.match(extractBuilder(browserSource, 'SortSheet'), /\.align\(Alignment\.TopStart\)/);

  assert.match(goTaildriveSource, /case\s+"copy":\s*method\s*=\s*"COPY"/);
  assert.match(goTaildriveSource, /request\.Operation == "copy"/);
});

test('long-press drag range selection selects/deselects ranges across headers with haptics on List and Grid', () => {
  const items = [
    fileEntry('one.txt', 128, 1001),
    fileEntry('two.txt', 128, 1002),
    fileEntry('three.txt', 128, 1003),
    fileEntry('four.txt', 128, 1004),
    fileEntry('five.txt', 128, 1005)
  ];
  const listModel = [
    { key: 'header-today', header: true, title: 'today', entry: items[0] },
    { key: items[0].path, header: false, title: '', entry: items[0] },
    { key: items[1].path, header: false, title: '', entry: items[1] },
    { key: 'header-earlier', header: true, title: 'earlier', entry: items[2] },
    { key: items[2].path, header: false, title: '', entry: items[2] },
    { key: items[3].path, header: false, title: '', entry: items[3] },
    { key: items[4].path, header: false, title: '', entry: items[4] }
  ];
  const haptics = [];
  let rebuilds = 0;
  const state = {
    connected: true,
    busy: false,
    loading: false,
    selectionMode: true,
    dragSelecting: false,
    selectedPaths: [items[4].path]
  };
  const controller = new TaildriveSessionController({
    isConnected: () => state.connected,
    isBusy: () => state.busy,
    isLoading: () => state.loading,
    isSelectionMode: () => state.selectionMode,
    isDragSelecting: () => state.dragSelecting,
    setDragSelecting: value => { state.dragSelecting = value; },
    getSelectedPaths: () => state.selectedPaths,
    setSelectedPaths: paths => { state.selectedPaths = paths; },
    getEntries: () => items,
    getSearchQuery: () => '',
    getSortMode: () => 'modified',
    isSortDescending: () => false,
    getGroupMode: () => 'none',
    stopDragAutoScroll() {},
    rebuildListDataSource() { rebuilds++; },
    vibrateTouch(strong) { haptics.push(strong ? 'hard' : 'soft'); },
    vibrateDragStep() { haptics.push('step'); }
  });
  const resolveFlatIndex = listIndex => controller.resolveFlatEntryIndexForListIndex(
    listIndex, listModel.length, cursor => listModel[cursor].header
  );

  // Group headers return -1 and never shift flat indices off by header count.
  assert.equal(resolveFlatIndex(0), -1);
  assert.equal(resolveFlatIndex(1), 0);
  assert.equal(resolveFlatIndex(3), -1);
  assert.equal(resolveFlatIndex(4), 2);
  assert.equal(resolveFlatIndex(6), 4);

  // Drag-select starting on unselected index 0 down across 3 items -> selects 0..3 while preserving index 4.
  assert.equal(controller.beginDragSelectionAtIndex(0), true);
  assert.deepEqual(haptics, ['hard']);
  assert.deepEqual(Array.from(state.selectedPaths), [items[4].path, items[0].path]);

  assert.equal(controller.updateDragSelectionToIndex(1), true);
  assert.equal(controller.updateDragSelectionToIndex(2), true);
  assert.equal(controller.updateDragSelectionToIndex(3), true);
  // Repeating same index produces no duplicate step haptic.
  assert.equal(controller.updateDragSelectionToIndex(3), false);
  assert.deepEqual(haptics, ['hard', 'step', 'step', 'step']);
  assert.deepEqual(Array.from(state.selectedPaths), [
    items[4].path, items[0].path, items[1].path, items[2].path, items[3].path
  ]);

  // Reversing drag direction back to index 2 unselects item 3 cleanly while keeping pre-existing item 4.
  assert.equal(controller.updateDragSelectionToIndex(2), true);
  assert.deepEqual(Array.from(state.selectedPaths), [
    items[4].path, items[0].path, items[1].path, items[2].path
  ]);
  controller.finishDragSelection();
  assert.equal(state.dragSelecting, false);
  assert.equal(rebuilds, 1);

  // Starting on already-selected index 0 drags to deselect 0..1 while keeping 2 and 4.
  haptics.length = 0;
  assert.equal(controller.beginDragSelectionAtIndex(0), true);
  assert.equal(controller.updateDragSelectionToIndex(1), true);
  assert.deepEqual(Array.from(state.selectedPaths), [items[4].path, items[2].path]);
  assert.deepEqual(haptics, ['hard', 'step']);
  controller.finishDragSelection();

  // Normal mode gesture gate rejects drag-select cleanly, and both List & Grid wire the gesture group.
  const viewport = extractBuilder(browserSource, 'StandaloneEntryViewport');
  assert.equal((viewport.match(/\.enableScrollInteraction\(!this\.dragSelecting\)/g) || []).length, 2);
  assert.equal((viewport.match(/\.onGestureJudgeBegin\(/g) || []).length, 2);
  assert.equal((viewport.match(/LongPressGesture\(\{\s*repeat:\s*false,\s*duration:\s*220\s*\}\)/g) || []).length, 2);
  assert.equal((viewport.match(/PanGesture\(\{\s*fingers:\s*1,\s*direction:\s*PanDirection\.All,\s*distance:\s*1\s*\}\)/g) || []).length, 2);
});

test('local cache status uses non-checkbox secondary icon and is hidden during multi-select', () => {
  const row = extractBuilder(browserSource, 'FileListRow');
  assert.match(row, /if \(!this\.selectionMode\)\s*\{\s*this\.LocalFileStatus\(entry, 17\)/);
  assert.match(row, /if \(this\.selectionMode\)\s*\{\s*this\.SelectionMark\(entry\)/);

  const icon = extractBuilder(browserSource, 'EntryIcon');
  assert.match(icon, /if \(this\.viewMode === 'grid' && !this\.selectionMode && this\.localFileStatus\(entry\)\.length > 0\)/);

  const statusBadge = extractBuilder(browserSource, 'LocalFileStatus');
  assert.match(statusBadge, /sys\.symbol\.arrow_down_circle/);
  assert.match(statusBadge, /sys\.symbol\.arrow_down_circle_badge_checkmark/);
  assert.match(statusBadge, /sys\.color\.icon_secondary/);
  assert.doesNotMatch(statusBadge, /checkmark_circle_fill/);
  assert.doesNotMatch(statusBadge, /app\.color\.emphasize/);
});
