import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../entry/src/main/ets/components/BridgeStatus.ets', import.meta.url), 'utf8');
const tabs = ['home', 'transfer', 'files', 'network', 'settings'];
const one = { key: 'one', name: 'one-device' }, two = { key: 'two', name: 'two-device' };

function fixture() {
  let clock = 1000, nextTimer = 1;
  const timers = new Map();
  const names = ['openRemoteFilesFromDevice', 'scheduleLifecycleTask', 'navigateToTab',
    'navigateToNavigationTab', 'syncNavigationSelection', 'handleNavigationTabChange', 'handleNavigationTabClick', 'deviceDetailPeer',
    'invalidateRemoteStreamLaunch'];
  const methods = names.map(name => {
    const method = source.match(new RegExp(`^  private ${name}\\([\\s\\S]*?^  \\}`, 'm'))?.[0];
    assert.ok(method, name);
    return method.replace(/^  private /, 'function ');
  });
  const sandbox = { Date: { now: () => clock },
    setTimeout(callback) { const id = nextTimer++; timers.set(id, callback); return id; },
    DEFAULT_NAVIGATION_HIDDEN: [], DEFAULT_NAVIGATION_ORDER: tabs };
  vm.runInNewContext(stripTypeScriptTypes(methods.join('\n')), sandbox);
  const state = {
    peers: [one, two], selectedPeerKey: 'one', appShellReady: true, deviceDetailVisible: true,
    lifecycleGeneration: 1, lifecycleTimers: [], navigationRevision: 0, remoteFilesNavigationRequestId: 0,
    taildriveTargetRequestId: 0, taildriveTargetMachineName: '', activeNavigationId: 'home',
    hiddenNavigationTabs: [], activeTab: 0, currentTab: 0, settingsDetailActive: false,
    settingsPathStack: { size: () => 0, clear() {} }, saves: 0, navCalls: [], controllerCalls: [],
    visibleNavigationTabs() { return tabs.filter(id => !this.hiddenNavigationTabs.includes(id)); },
    navigationTabAt(index) { return this.visibleNavigationTabs()[index]; },
    navigationTabIdForLogicalIndex: index => tabs[index], saveNavigationPreferences() { this.saves++; },
    publishFilesTabActive() {}, updateCacheSizePolling() {}, syncHomeLatencyRefreshPolling() {}, syncTransferProtocolRefreshPolling() {},
    peerIntegrationController: { invalidateRemoteStreamLaunch() {} },
    ...Object.fromEntries(names.map(name => [name, sandbox[name]]))
  };
  state.tabsController = { changeIndex(index) { state.controllerCalls.push(index); } };
  state.navigateToTab = function(index) { this.navCalls.push(index); return sandbox.navigateToTab.call(this, index); };
  return { state, clock(value) { clock = value; }, flush() {
    for (const [id, callback] of [...timers]) { timers.delete(id); callback(); }
  } };
}

test('a queued file request publishes its target only when navigation is accepted', () => {
  const { state, flush } = fixture(); state.openRemoteFilesFromDevice(one);
  assert.equal(state.taildriveTargetRequestId, 0); assert.equal(state.taildriveTargetMachineName, '');
  flush(); assert.equal(state.taildriveTargetMachineName, one.name);
  assert.equal(state.taildriveTargetRequestId, 1000); assert.deepEqual(state.navCalls, [2]);
});

test('published request IDs stay positive and strictly increase across equal or backward clocks', () => {
  const { state, flush, clock } = fixture(); let previous = 0;
  for (const time of [1000, 1000, 900, -5]) {
    clock(time); state.deviceDetailVisible = true; state.openRemoteFilesFromDevice(one); flush();
    assert.ok(state.taildriveTargetRequestId > previous); previous = state.taildriveTargetRequestId;
  }
});

test('only the latest queued device request navigates and it resolves the current device name', () => {
  const { state, flush } = fixture(); state.openRemoteFilesFromDevice(one);
  state.deviceDetailVisible = true; state.selectedPeerKey = 'two'; state.openRemoteFilesFromDevice(two);
  state.peers = [one, { ...two, name: 'renamed-two' }]; flush();
  assert.deepEqual(state.navCalls, [2]); assert.equal(state.taildriveTargetMachineName, 'renamed-two');
});

test('later programmatic navigation, including an A-B-A round trip, supersedes the queued file request', () => {
  const { state, flush } = fixture(); state.openRemoteFilesFromDevice(one);
  state.navigateToNavigationTab('network', true); state.navigateToNavigationTab('home', true); flush();
  assert.equal(state.activeNavigationId, 'home'); assert.equal(state.taildriveTargetRequestId, 0);
  assert.deepEqual(state.navCalls, []);
});

test('a matching animation commit does not cancel a request made after selection started', () => {
  const { state, flush } = fixture(); state.handleNavigationTabChange(0, false);
  state.openRemoteFilesFromDevice(one); state.handleNavigationTabChange(0, true); flush();
  assert.deepEqual(state.navCalls, [2]); assert.equal(state.taildriveTargetMachineName, one.name);
});

test('new native tab clicks supersede the queue without prematurely controlling the index', () => {
  for (const index of [0, 3]) {
    const { state, flush } = fixture(); state.openRemoteFilesFromDevice(one);
    state.handleNavigationTabClick(index);
    state.handleNavigationTabChange(index, false); assert.equal(state.currentTab, 0);
    state.handleNavigationTabChange(index, true); flush();
    assert.equal(state.activeNavigationId, tabs[index]); assert.equal(state.currentTab, index);
    assert.equal(state.taildriveTargetRequestId, 0); assert.deepEqual(state.navCalls, []);
  }
});

test('reopened details, a new selection or inactive lifecycle prevent publication and navigation', () => {
  for (const invalidate of [state => { state.deviceDetailVisible = true; },
    state => { state.selectedPeerKey = 'two'; }, state => { state.lifecycleGeneration++; }, state => { state.appShellReady = false; }]) {
    const { state, flush } = fixture(); state.openRemoteFilesFromDevice(one); invalidate(state); flush();
    assert.equal(state.taildriveTargetRequestId, 0); assert.deepEqual(state.navCalls, []);
  }
});

test('a removed device cannot leave an accepted file target behind', () => {
  const { state, flush } = fixture(); state.openRemoteFilesFromDevice(one); state.peers = []; flush();
  assert.equal(state.taildriveTargetRequestId, 0); assert.deepEqual(state.navCalls, []);
});

test('accepted file navigation still reveals a hidden files tab', () => {
  const { state, flush } = fixture(); state.hiddenNavigationTabs = ['files'];
  state.openRemoteFilesFromDevice(one); flush();
  assert.equal(state.hiddenNavigationTabs.includes('files'), false); assert.equal(state.saves, 1);
  assert.equal(state.activeNavigationId, 'files');
});

test('a preference synchronization that keeps the same tab does not cancel the queue', () => {
  const { state, flush } = fixture(); state.openRemoteFilesFromDevice(one);
  state.syncNavigationSelection('home', false); flush(); assert.deepEqual(state.navCalls, [2]);
});

test('an accepted request while already on files still publishes its target', () => {
  const { state, flush } = fixture(); state.activeNavigationId = 'files'; state.activeTab = 2; state.currentTab = 2;
  state.openRemoteFilesFromDevice(one); flush();
  assert.equal(state.taildriveTargetMachineName, one.name); assert.ok(state.taildriveTargetRequestId > 0);
});

test('an invalid native tab event is ignored without cancelling a valid file request', () => {
  const { state, flush } = fixture(); state.openRemoteFilesFromDevice(one);
  state.handleNavigationTabClick(-1); state.handleNavigationTabClick(99);
  state.handleNavigationTabChange(-1, false); state.handleNavigationTabChange(99, true); flush();
  assert.deepEqual(state.navCalls, [2]); assert.equal(state.taildriveTargetMachineName, one.name);
});

test('a programmatic selection echo does not retire a newer queued file request', () => {
  const { state, flush } = fixture(); state.navigateToNavigationTab('home', true);
  state.openRemoteFilesFromDevice(one); state.handleNavigationTabChange(0, false);
  state.handleNavigationTabChange(0, true); flush();
  assert.deepEqual(state.navCalls, [2]); assert.equal(state.taildriveTargetMachineName, one.name);
});

test('a swipe to another tab supersedes the queue even without a tab-bar click event', () => {
  const { state, flush } = fixture(); state.openRemoteFilesFromDevice(one);
  state.handleNavigationTabChange(3, false); flush();
  assert.equal(state.activeNavigationId, 'network'); assert.deepEqual(state.navCalls, []);
});
