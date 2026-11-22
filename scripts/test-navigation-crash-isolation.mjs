import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import vm from 'node:vm';

const root = process.env.TAILSCALE_PROJECT_ROOT ?? fileURLToPath(new URL('..', import.meta.url));
const read = name => readFileSync(resolve(root, 'entry/src/main/ets/components', name), 'utf8');
const source = read('BridgeStatus.ets');
const nativeSettings = read('NativeSettingsNavigation.ets');
function method(text, name) {
  const value = text.match(new RegExp(`^  private ${name}\\([\\s\\S]*?^  \\}`, 'm'))?.[0];
  assert.ok(value, name);
  return value.replace(/^  private /, 'function ');
}
function fixture(order = ['home', 'transfer', 'files', 'settings'], hidden = []) {
  const writes = [];
  const timers = [];
  const names = ['visibleNavigationTabs', 'navigationTabAt', 'publishFilesTabActive', 'FilesPage',
    'syncNavigationSelection', 'handleNavigationTabChange', 'handleNavigationTabClick', 'navigateToNavigationTab',
    'scheduleNavigationTabChange', 'scheduleLifecycleTask'];
  const sandbox = {
    setTimeout(callback) { timers.push(callback); return timers.length; },
    AppStorage: { setOrCreate: (...args) => writes.push(args) },
    DEFAULT_NAVIGATION_HIDDEN: [], DEFAULT_NAVIGATION_ORDER: ['home', 'transfer', 'files', 'settings']
  };
  vm.runInNewContext(stripTypeScriptTypes(names.map(name => method(source, name)).join('\n')), sandbox);
  const state = {
    navigationOrder: order, hiddenNavigationTabs: hidden, activeNavigationId: 'home',
    filesPageActivated: false, activeTab: 0, currentTab: 0, navigationRevision: 0,
    tabChangeRequestId: 0, lifecycleGeneration: 1, lifecycleTimers: [],
    settingsPathStack: { clear() {}, size: () => 0 }, settingsDetailActive: false,
    tabsController: { changeIndex() {} }, invalidations: 0, builds: 0, saves: 0,
    invalidateRemoteStreamLaunch() { this.invalidations++; },
    saveNavigationPreferences() { this.saves++; }, updateCacheSizePolling() {},
    syncHomeLatencyRefreshPolling() {}, syncTransferProtocolRefreshPolling() {},
    FilesContent() { this.builds++; },
    ...Object.fromEntries(names.map(name => [name, sandbox[name]]))
  };
  return { state, writes, flush() { for (const task of timers.splice(0)) task(); } };
}

test('HdsTabs callbacks never mutate reactive selection inside the render that emitted them', () => {
  const { state, flush } = fixture();
  let rendering = true, index = 0;
  Object.defineProperty(state, 'currentTab', { get: () => index, set(value) {
    assert.equal(rendering, false, 'controlled tab index mutated during render'); index = value;
  } });
  state.scheduleNavigationTabChange(2, false);
  state.scheduleNavigationTabChange(2, true);
  assert.equal(state.activeNavigationId, 'home');
  assert.equal(state.filesPageActivated, false);
  rendering = false; flush();
  assert.equal(state.currentTab, 2);
  assert.equal(state.filesPageActivated, true);
});

test('rapid callbacks apply only the newest destination and preserve swipe selection before commit', () => {
  const { state, flush } = fixture();
  state.scheduleNavigationTabChange(2, true);
  state.scheduleNavigationTabChange(3, false);
  flush();
  assert.equal(state.activeNavigationId, 'settings');
  assert.equal(state.currentTab, 0);
  state.scheduleNavigationTabChange(3, true); flush();
  assert.equal(state.currentTab, 3);
  assert.equal(state.filesPageActivated, false);
});

test('programmatic navigation supersedes queued native tab events', () => {
  const { state, flush } = fixture();
  state.scheduleNavigationTabChange(2, true);
  state.syncNavigationSelection('settings', true);
  flush();
  assert.equal(state.activeNavigationId, 'settings');
  assert.equal(state.filesPageActivated, false);
});

test('teardown and reordered tab mappings invalidate deferred callbacks', () => {
  for (const invalidate of [s => s.lifecycleGeneration++, s => s.navigationOrder.reverse()]) {
    const { state, flush } = fixture();
    state.scheduleNavigationTabChange(2, true); invalidate(state); flush();
    assert.equal(state.activeNavigationId, 'home');
    assert.equal(state.filesPageActivated, false);
  }
});

test('controlled-index echo leaves the current settings destination intact', () => {
  const { state, flush } = fixture();
  state.syncNavigationSelection('settings', true);
  let clearCount = 0;
  state.settingsPathStack = { size: () => 1, clear() { clearCount++; } };
  state.settingsDetailActive = true;
  state.scheduleNavigationTabChange(3, true); flush();
  assert.equal(state.settingsDetailActive, true);
  assert.equal(clearCount, 0);
});

test('prebuilding a files neighbor during home, transfer or settings selection does not create its navigation', () => {
  const { state, writes } = fixture();
  for (const id of ['home', 'transfer', 'settings', 'home']) {
    const index = state.visibleNavigationTabs().indexOf(id);
    state.handleNavigationTabClick(index);
    state.FilesPage();
    state.handleNavigationTabChange(index, false);
    state.FilesPage();
    state.handleNavigationTabChange(index, true);
    state.FilesPage();
  }
  assert.equal(state.builds, 0);
  assert.equal(state.filesPageActivated, false);
  assert.ok(writes.every(([key, value]) => key === 'taildriveFilesTabActive' && value === false));
});

test('selecting files mounts it at swipe selection and retains it after leaving and returning', () => {
  const { state, writes } = fixture();
  state.handleNavigationTabChange(2, false);
  assert.equal(state.currentTab, 0, 'the selection must not commit the controlled index early');
  assert.equal(state.filesPageActivated, true);
  assert.deepEqual(writes.at(-1), ['taildriveFilesTabActive', true]);
  state.FilesPage();
  state.handleNavigationTabChange(2, true);
  state.handleNavigationTabChange(3, false);
  assert.equal(state.filesPageActivated, true, 'keep the existing child state while inactive');
  assert.deepEqual(writes.at(-1), ['taildriveFilesTabActive', false]);
  state.FilesPage();
  state.handleNavigationTabChange(2, false);
  state.FilesPage();
  assert.equal(state.builds, 3);
});

test('two-tab, files-only restoration and transfer-only restoration use semantic IDs after reordering', () => {
  for (const hidden of [['transfer', 'files'], ['transfer'], ['files']]) {
    const { state } = fixture(['settings', 'files', 'home', 'transfer'], hidden);
    state.syncNavigationSelection('settings', true);
    state.FilesPage();
    assert.equal(state.builds, 0);
    state.syncNavigationSelection('transfer', true);
    state.FilesPage();
    assert.equal(state.builds, 0);
    if (!hidden.includes('files')) {
      state.syncNavigationSelection('files', true);
      state.FilesPage();
      assert.equal(state.builds, 1);
      assert.equal(state.activeTab, 1);
    }
  }
});

test('programmatic remote-files navigation reveals and activates a hidden file tab', () => {
  const { state, writes } = fixture(['home', 'settings', 'files', 'transfer'], ['files', 'transfer']);
  state.navigateToNavigationTab('files', true);
  state.FilesPage();
  assert.equal(state.builds, 1);
  assert.equal(state.filesPageActivated, true);
  assert.equal(state.saves, 1);
  assert.equal(state.hiddenNavigationTabs.includes('files'), false);
  assert.deepEqual(writes.at(-1), ['taildriveFilesTabActive', true]);
});

test('invalid selections never activate an unseen files page and restored selection renders immediately', () => {
  const { state } = fixture();
  state.handleNavigationTabChange(-1, false);
  state.handleNavigationTabChange(99, true);
  state.FilesPage();
  assert.equal(state.builds, 0);
  state.activeNavigationId = 'files';
  state.FilesPage();
  assert.equal(state.builds, 1);
});

test('VPN startup, connection and disconnect cannot create an unvisited files page or discard a visited one', () => {
  const { state } = fixture();
  state.syncNavigationSelection('settings', true);
  for (const status of ['state=Stopped', 'state=Starting', 'state=Running', 'state=Stopped']) {
    state.vpnStatus = status;
    state.FilesPage();
    assert.equal(state.builds, 0);
  }
  state.syncNavigationSelection('files', true);
  state.FilesPage();
  state.syncNavigationSelection('settings', true);
  for (const status of ['state=Starting', 'state=Running', 'state=Stopped']) {
    state.vpnStatus = status;
    state.FilesPage();
    assert.equal(state.filesPageActivated, true);
  }
  assert.equal(state.builds, 4);
  const recreated = fixture().state;
  recreated.FilesPage();
  assert.equal(recreated.builds, 0, 'a new shell does not inherit prior file activation');
});

test('settings close menu carries an explicit symbol modifier and preserves its dismissal callback', () => {
  class SymbolGlyphModifier {
    constructor(resource) { this.resource = resource; this.colors = []; }
    fontColor(colors) { this.colors = colors; return this; }
  }
  const sandbox = { SymbolGlyphModifier, $r: name => ({ name }),
    IconStyleMode: { SMALL: 100 }, DividerShowType: { OFF: 0 },
    LightAppearance: {
      blurStrategy: level => 'blur-' + level,
      hdsType: level => 'type-' + level,
      hdsLevel: level => level
    } };
  vm.runInNewContext(stripTypeScriptTypes(method(nativeSettings, 'modalTitleBar')), sandbox);
  let dismissals = 0;
  const owner = { onDismiss: () => dismissals++, materialIndex: 3 };
  const title = sandbox.modalTitleBar.call(owner, 'Settings');
  assert.equal(title.style.blurStrategy, 'blur-3');
  assert.equal(title.style.systemMaterialEffect.materialType, 'type-3');
  assert.equal(title.style.systemMaterialEffect.materialLevel, 3);
  const menu = title.content.menu.value[0].content;
  assert.ok(menu.icon instanceof SymbolGlyphModifier);
  assert.equal(menu.icon.resource.name, 'sys.symbol.xmark');
  assert.deepEqual(Array.from(menu.icon.colors, item => item.name), ['sys.color.icon_primary']);
  assert.equal(menu.type, 100);
  assert.equal(menu.isEnabled, true);
  menu.action.call(undefined);
  assert.equal(dismissals, 1);
});
