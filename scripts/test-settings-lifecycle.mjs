import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import test from 'node:test';

// In the repository this file lives in scripts/. The override allows reviewing
// the same test from an isolated task directory before applying it to the repo.
const root = process.env.TAILSCALE_PROJECT_ROOT ?? fileURLToPath(new URL('..', import.meta.url));
const read = relative => readFileSync(resolve(root, relative), 'utf8').replace(/\r\n/g, '\n');
const source = read('entry/src/main/ets/components/BridgeStatus.ets');
const requestGuardSource = read('common/src/main/ets/contracts/RequestGuard.ets');
function method(name) {
  const match = new RegExp('^  private (?:async )?' + name + '\\(', 'm').exec(source);
  assert.ok(match, 'production method ' + name);
  const end = source.indexOf('\n  }', match.index);
  assert.ok(end >= 0, name + ' closing brace');
  return source.slice(match.index, end + 4);
}
function classSource(text, name) {
  const start = text.indexOf('export class ' + name);
  assert.ok(start >= 0, name);
  const end = text.indexOf('\n}\n', start);
  assert.ok(end >= 0, name + ' closing brace');
  return text.slice(start, end + 2).replace('export class ', 'class ');
}
const methods = [
  'loadNavigationPreferences', 'loadSecurityPreferences', 'syncNavigationSelection',
  'updateCacheSizePolling', 'startCacheSizePolling', 'stopCacheSizePolling',
  'canUseStandaloneDiagnostics', 'generateDiagnosticReport', 'pathDiagnosticAction',
  'openStandaloneDiagnostics', 'closeStandaloneDiagnostics', 'setStandaloneCrashCapture', 'feedbackEmailFailed', 'openFeedbackEmail'
];
const javascript = stripTypeScriptTypes(
  classSource(read('entry/src/main/ets/services/FeedbackEmailTemplate.ets'), 'FeedbackEmailTemplate') + '\n' +
  classSource(requestGuardSource, 'RequestGuard') +
  '\nclass Controller {\n' + methods.map(method).join('\n') +
  '\n}\nglobalThis.Controller = Controller;globalThis.Guard = RequestGuard;'
);
const flush = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
function deferred() {
  let resolve, reject;
  const promise = new Promise((a, b) => { resolve = a; reject = b; });
  return { promise, resolve, reject };
}
const navigation = order => ({ order, hidden: [], bottomMargin: 8 });
const security = enabled => ({
  appLockEnabled: enabled, folderLockEnabled: enabled,
  lockedFolderPaths: enabled ? ['/private-folder'] : []
});
test('path actions use an independent guard while a report snapshot is pending', async () => {
  const f = fixture(); const gate = deferred(); f.pathLoads.push(gate.promise);
  const report = f.c.generateDiagnosticReport(); await flush();
  await f.c.pathDiagnosticAction('stop');
  assert.equal(f.c.pathDiagnosticStatus, 'stop: ok'); assert.equal(f.c.diagnosticReportInProgress, true);
  gate.resolve('ok'); await report;
  assert.equal(f.shares.length, 1); assert.equal(f.c.diagnosticReportInProgress, false);
});

function fixture() {
  const f = {
    navigationLoads: [], securityLoads: [], pathLoads: [], zipLoads: [], shareLoads: [], mailLoads: [], mails: [],
    timers: new Map(), timerCallbacks: [], timerId: 0, scans: [], storageCancels: 0,
    appStorageWrites: [], events: [], shares: [], generated: [], pathRequests: [],
    authenticationRequests: 0, changelogShows: 0, toasts: [], crashEnableCalls: 0,
    crashDisableCalls: 0, crashEnabled: false, contextError: false, resourceError: false,
    securityFallback: undefined
  };
  const take = (queue, fallback) => {
    const value = queue.length ? queue.shift() : fallback;
    if (value instanceof Error) throw value;
    return value;
  };
  const context = {
    filesDir: '/files',
    resourceManager: { getStringSync: () => {
      if (f.resourceError) throw Error('resource unavailable');
      return 'Generating diagnostic report';
    } }
  };
  const sandbox = {
    Date, console, FEEDBACK_EMAIL: 'feedback@example.test',
    DEFAULT_NAVIGATION_ORDER: ['home', 'transfer', 'files', 'settings'],
    DEFAULT_NAVIGATION_HIDDEN: [], DEFAULT_NAVIGATION_BOTTOM_MARGIN: 0,
    CACHE_SIZE_POLL_INTERVAL_MS: 5000,
    NavigationPreferences: { load: () => take(f.navigationLoads, Promise.resolve(navigation(['home', 'settings']))) },
    AppSecurityPreferences: {
      load: () => take(f.securityLoads, Promise.resolve(security(true))),
      loadFallback: dir => {
        assert.equal(dir, '/files');
        return f.securityFallback ?? security(false);
      }
    },
    AppStorage: { setOrCreate: (...args) => f.appStorageWrites.push(args) },
    setInterval: (callback, delay) => {
      const id = ++f.timerId; f.timers.set(id, { callback, delay }); f.timerCallbacks.push(callback); return id;
    },
    clearInterval: id => f.timers.delete(id),
    $r: id => ({ id }),
    PathDiagnosticService: { request: (dir, action) => {
      f.pathRequests.push({ dir, action });
      return take(f.pathLoads, Promise.resolve('ok'));
    } },
    CrashDiagnosticService: {
      isEnabled: () => f.crashEnabled,
      enable: () => { f.crashEnableCalls++; f.crashEnabled = true; return true; },
      disable: () => { f.crashDisableCalls++; f.crashEnabled = false; if (f.crashDisableError) throw Error('disable unavailable'); return !f.crashDisableFailure; }
    }
  };
  vm.runInNewContext(javascript, sandbox);
  const c = new sandbox.Controller();
  Object.assign(c, {
    lifecycleGeneration: 1, appShellReady: true, remoteStreamAppInForeground: true,
    securityPreferencesReady: true, appLockRequired: false, appLockAuthenticating: false,
    securitySettingsAuthenticating: false, updateChangelogShowPending: false,
    appLockEnabled: true, folderLockEnabled: true,
    navigationOrder: ['home', 'settings'], hiddenNavigationTabs: [], navigationBottomMargin: 4,
    activeNavigationId: 'settings', currentTab: 1, activeTab: 1,
    settingsPathStack: { size: () => 0 },
    visibleNavigationTabs: () => c.navigationOrder.filter(id => id === 'settings' || !c.hiddenNavigationTabs.includes(id)),
    navigationTabAt: index => c.visibleNavigationTabs()[index],
    publishFilesTabActive() {}, invalidateRemoteStreamLaunch() {},
    syncHomeLatencyRefreshPolling() {}, syncTransferProtocolRefreshPolling() {},
    tabsController: { changeIndex() {} },
    refreshCacheSize: loading => f.scans.push(loading),
    cacheSizePollTimer: -1, cacheSizeRefreshInFlight: false,
    cacheSizeRefreshPending: false, cacheSizeLoading: false,
    storageScanPool: { cancel: () => { f.storageCancels++; } },
    requireAppAuthentication: () => { f.authenticationRequests++; },
    showUpdateChangelogIfNeeded: () => { f.changelogShows++; },
    getUIContext: () => {
      if (f.contextError) throw Error('UI context detached');
      return { getHostContext: () => context };
    },
    showToast: value => f.toasts.push(value),
    diagnosticReportRequestGuard: new sandbox.Guard(),
    pathDiagnosticRequestGuard: new sandbox.Guard(),
    diagnosticReportInProgress: false, pathDiagnosticBusy: false,
    feedbackEmailStatus: '',
    feedbackEmailGateway: { open: (ctx, result, recipient, subject, body, failure) => {
      f.mails.push({ctx, result, recipient, subject, body, failure});
      return take(f.mailLoads, Promise.resolve());
    } },
    diagnosticReportStatus: 'previous report', pathDiagnosticStatus: 'previous path',
    standaloneDiagnosticsVisible: false, crashCaptureEnabled: false,
    appVersion: 'test', appVersionCode: 100000015, tailscaleVersion: 'test', nativeStatus: 'OK', engineStatus: 'OK',
    backendStatus: 'Running', vpnStatus: 'Running', peers: [], exitNodes: [],
    accountSummary: { addresses: [] }, networkSettings: { routeAll: true, exitNodeAllowLANAccess: false },
    meshArcReceiver: { state: 'ready', sent: 0, registered: 0 }, lockedFolderPaths: [],
    nativeSettingsBackgroundUri: '', diagnosticServiceLastRefreshMs: 0, serviceRefreshTimer: -1,
    isConnected: () => true, isAuthenticated: () => true,
    onlinePeerCount: () => 0, localSendStateCount: () => 0,
    mediaAvailablePeerCount: () => 0, mediaServiceCount: () => 0,
    hosPlayerSelfTestState: () => 'unknown', mediaCheckingPeerCount: () => 0,
    sunshineAvailablePeerCount: () => 0, sunshineCheckingPeerCount: () => 0,
    recordDiagnosticEvent: (...args) => f.events.push(args),
    accountDiagnosticsGateway: {
      generateReport: (ctx, input) => {
        f.generated.push({ ctx, input });
        return take(f.zipLoads, Promise.resolve({ size: 2048, fileName: 'diagnostic.zip', path: '/cache/diagnostic.zip' }));
      },
      shareReport: (ctx, result) => {
        f.shares.push({ ctx, result });
        return take(f.shareLoads, Promise.resolve());
      }
    }
  });
  f.c = c; f.context = context;
  // These are the lifecycle transitions performed by the actual view owner;
  // loaders/actions remain their unmodified production methods.
  f.destroy = () => {
    c.appShellReady = false; c.lifecycleGeneration++;
    c.diagnosticReportRequestGuard.invalidate(); c.pathDiagnosticRequestGuard.invalidate();
    c.stopCacheSizePolling();
  };
  f.reenter = () => {
    c.lifecycleGeneration++; c.appShellReady = true;
    c.diagnosticReportInProgress = false; c.pathDiagnosticBusy = false;
  };
  return f;
}

test('current navigation preference success applies selection and starts one Settings poll', async () => {
  const f = fixture(); f.navigationLoads.push(Promise.resolve(navigation(['home', 'files', 'settings'])));
  f.c.loadNavigationPreferences(f.context); await flush();
  assert.deepEqual(Array.from(f.c.navigationOrder), ['home', 'files', 'settings']);
  assert.equal(f.c.activeTab, 2); assert.equal(f.c.navigationBottomMargin, 8);
  assert.equal(f.timers.size, 1); assert.equal(f.scans.length, 1);
  f.c.startCacheSizePolling(); assert.equal(f.timers.size, 1); assert.equal(f.scans.length, 1);
});
test('current navigation load failure retains documented defaults', async () => {
  const f = fixture(); const gate = deferred(); f.navigationLoads.push(gate.promise);
  f.c.loadNavigationPreferences(f.context); gate.reject(Error('read failed')); await flush();
  assert.deepEqual(Array.from(f.c.navigationOrder), ['home', 'transfer', 'files', 'settings']);
  assert.equal(f.c.navigationBottomMargin, 0);
});
for (const outcome of ['resolve', 'reject']) test('destroyed navigation ' + outcome + ' cannot update state or restart a stopped poll', async () => {
  const f = fixture(); const gate = deferred(); f.navigationLoads.push(gate.promise);
  f.c.loadNavigationPreferences(f.context); f.destroy();
  f.c.navigationOrder = ['preserved', 'settings']; f.c.navigationBottomMargin = 71;
  if (outcome === 'resolve') gate.resolve(navigation(['old', 'settings'])); else gate.reject(Error('old error'));
  await flush();
  assert.deepEqual(Array.from(f.c.navigationOrder), ['preserved', 'settings']);
  assert.equal(f.c.navigationBottomMargin, 71); assert.equal(f.timers.size, 0); assert.equal(f.scans.length, 0);
});
for (const outcome of ['resolve', 'reject']) test('a previous lifecycle navigation ' + outcome + ' cannot overwrite fresh preferences', async () => {
  const f = fixture(); const old = deferred(), fresh = deferred();
  f.navigationLoads.push(old.promise, fresh.promise); f.c.loadNavigationPreferences(f.context);
  f.destroy(); f.reenter(); f.c.loadNavigationPreferences(f.context);
  fresh.resolve(navigation(['home', 'new', 'settings'])); await flush();
  if (outcome === 'resolve') old.resolve(navigation(['old', 'settings'])); else old.reject(Error('old read failed'));
  await flush();
  assert.deepEqual(Array.from(f.c.navigationOrder), ['home', 'new', 'settings']);
  assert.equal(f.timers.size, 1); assert.equal(f.scans.length, 1);
});
test('poll entry rejects detached/other-tab state and stop cancels timer, work and loading flags', () => {
  const f = fixture(); f.c.appShellReady = false; f.c.startCacheSizePolling();
  f.c.appShellReady = true; f.c.activeNavigationId = 'home'; f.c.startCacheSizePolling();
  assert.equal(f.timers.size, 0);
  f.c.activeNavigationId = 'settings'; f.c.startCacheSizePolling();
  assert.equal(f.timers.size, 1); f.timerCallbacks.at(-1)(); assert.equal(f.scans.length, 2);
  f.c.appShellReady = false; f.timerCallbacks.at(-1)(); assert.equal(f.scans.length, 2);
  f.c.cacheSizeLoading = true; f.c.cacheSizeRefreshPending = true; f.c.cacheSizeRefreshInFlight = true;
  f.c.stopCacheSizePolling(); f.c.startCacheSizePolling();
  assert.equal(f.timers.size, 0); assert.equal(f.c.cacheSizePollTimer, -1);
  assert.equal(f.c.cacheSizeLoading, false); assert.equal(f.c.cacheSizeRefreshPending, false);
  assert.equal(f.c.cacheSizeRefreshInFlight, false); assert.equal(f.storageCancels, 1);
});
test('current security preferences populate locks before requesting authentication', async () => {
  const f = fixture(); f.c.updateChangelogShowPending = true;
  f.c.loadSecurityPreferences(f.context); await flush();
  assert.equal(f.c.appLockEnabled, true); assert.equal(f.c.folderLockEnabled, true);
  assert.equal(f.c.securityPreferencesReady, true); assert.equal(f.authenticationRequests, 1);
  assert.deepEqual(Array.from(f.appStorageWrites[0][1]), ['/private-folder']); assert.equal(f.changelogShows, 1);
});
test('current security read failure preserves the existing first-run fallback', async () => {
  const f = fixture(); const gate = deferred(); f.securityLoads.push(gate.promise);
  f.c.loadSecurityPreferences(f.context); gate.reject(Error('read failed')); await flush();
  assert.equal(f.c.appLockEnabled, false); assert.equal(f.c.folderLockEnabled, false);
  assert.equal(f.c.securityPreferencesReady, true); assert.equal(f.authenticationRequests, 0);
});
test('armed security read failure recovers locked state and requests authentication', async () => {
  const f = fixture(); const gate = deferred(); f.securityLoads.push(gate.promise);
  f.securityFallback = security(true);
  f.c.appLockEnabled = false; f.c.folderLockEnabled = false; f.c.securityPreferencesReady = false;
  f.c.loadSecurityPreferences(f.context); gate.reject(Error('preferences corrupted')); await flush();
  assert.equal(f.c.appLockEnabled, true); assert.equal(f.c.folderLockEnabled, true);
  assert.equal(f.c.securityPreferencesReady, true); assert.equal(f.authenticationRequests, 1);
  assert.deepEqual(Array.from(f.appStorageWrites[0][1]), ['/private-folder']);
});
for (const outcome of ['resolve', 'reject']) test('destroyed security ' + outcome + ' cannot change lock or AppStorage state', async () => {
  const f = fixture(); const gate = deferred(); f.securityLoads.push(gate.promise);
  f.c.loadSecurityPreferences(f.context); f.destroy(); f.c.securityPreferencesReady = false;
  if (outcome === 'resolve') gate.resolve(security(false)); else gate.reject(Error('old failure'));
  await flush();
  assert.equal(f.c.appLockEnabled, true); assert.equal(f.c.folderLockEnabled, true);
  assert.equal(f.c.securityPreferencesReady, false); assert.equal(f.appStorageWrites.length, 0);
  assert.equal(f.authenticationRequests, 0);
});
for (const outcome of ['resolve', 'reject']) test('a previous lifecycle security ' + outcome + ' cannot clear newly enabled locks', async () => {
  const f = fixture(); const old = deferred(), fresh = deferred();
  f.securityLoads.push(old.promise, fresh.promise); f.c.loadSecurityPreferences(f.context);
  f.destroy(); f.reenter(); f.c.loadSecurityPreferences(f.context);
  fresh.resolve(security(true)); await flush();
  if (outcome === 'resolve') old.resolve(security(false)); else old.reject(Error('old error'));
  await flush();
  assert.equal(f.c.appLockEnabled, true); assert.equal(f.c.folderLockEnabled, true);
  assert.equal(f.appStorageWrites.length, 1); assert.equal(f.authenticationRequests, 1);
});

test('report normal flow snapshots, generates and shares once, then releases busy', async () => {
  const f = fixture(); await f.c.generateDiagnosticReport();
  assert.equal(f.pathRequests.length, 1); assert.equal(f.pathRequests[0].action, 'snapshot');
  assert.equal(f.generated.length, 1); assert.equal(f.shares.length, 1);
  assert.equal(f.c.diagnosticReportInProgress, false);
  assert.match(f.c.diagnosticReportStatus, /diagnostic.zip/);
});
for (const failure of ['context', 'resource', 'path-sync', 'path-reject', 'zip', 'share']) {
  test('report ' + failure + ' failure is contained and releases busy', async () => {
    const f = fixture();
    if (failure === 'context') f.contextError = true;
    if (failure === 'resource') f.resourceError = true;
    if (failure === 'path-sync') f.pathLoads.push(Error('path sync failure'));
    if (failure === 'path-reject') { const gate = deferred(); f.pathLoads.push(gate.promise); queueMicrotask(() => gate.reject(Error('path rejection'))); }
    if (failure === 'zip') f.zipLoads.push(Error('zip failure'));
    if (failure === 'share') f.shareLoads.push(Error('share failure'));
    await assert.doesNotReject(f.c.generateDiagnosticReport());
    assert.equal(f.c.diagnosticReportInProgress, false);
    assert.equal(f.c.diagnosticReportStatus, 'Diagnostic report unavailable');
    if (failure !== 'share') assert.equal(f.shares.length, 0);
  });
}
const changeState = (f, state) => {
  if (state === 'destroyed') f.destroy();
  if (state === 'locked') f.c.appLockRequired = true;
  if (state === 'background') f.c.remoteStreamAppInForeground = false;
  if (state === 'closed') f.c.closeStandaloneDiagnostics();
};
for (const stage of ['snapshot', 'zip']) for (const state of ['destroyed', 'locked', 'background', 'closed']) {
  test(state + ' report cannot share after late ' + stage + ' completion', async () => {
    const f = fixture(); const gate = deferred();
    if (stage === 'snapshot') f.pathLoads.push(gate.promise); else f.zipLoads.push(gate.promise);
    const pending = f.c.generateDiagnosticReport(); await flush(); changeState(f, state);
    gate.resolve(stage === 'snapshot' ? 'ok' : { size: 1, fileName: 'late.zip', path: '/late.zip' });
    await pending;
    assert.equal(f.shares.length, 0);
    if (stage === 'snapshot') assert.equal(f.generated.length, 0);
    if (state !== 'destroyed') assert.equal(f.c.diagnosticReportInProgress, false);
  });
}
test('a stale ZIP completion cannot clear busy or publish over a replacement report', async () => {
  const f = fixture(); const old = deferred(), fresh = deferred();
  f.zipLoads.push(old.promise, fresh.promise);
  const oldWork = f.c.generateDiagnosticReport(); await flush();
  f.c.closeStandaloneDiagnostics(); const newWork = f.c.generateDiagnosticReport(); await flush();
  old.resolve({ fileName: 'old.zip', size: 1 }); await oldWork;
  assert.equal(f.c.diagnosticReportInProgress, true); assert.equal(f.shares.length, 0);
  fresh.resolve({ fileName: 'new.zip', size: 1 }); await newWork;
  assert.equal(f.c.diagnosticReportInProgress, false); assert.equal(f.shares.length, 1);
  assert.equal(f.shares[0].result.fileName, 'new.zip');
});
test('a late share completion after teardown cannot append a success event', async () => {
  const f = fixture(); const gate = deferred(); f.shareLoads.push(gate.promise);
  const pending = f.c.generateDiagnosticReport(); await flush(); assert.equal(f.shares.length, 1);
  f.destroy(); gate.resolve(); await pending;
  assert.equal(f.events.some(event => event[0] === 'diagnostic_share_opened'), false);
});
for (const state of ['destroyed', 'locked', 'background']) test(state + ' state cannot begin report or path work', async () => {
  const f = fixture(); changeState(f, state);
  await f.c.generateDiagnosticReport(); await f.c.pathDiagnosticAction('start');
  assert.equal(f.pathRequests.length, 0); assert.equal(f.generated.length, 0); assert.equal(f.shares.length, 0);
});

test('path action normal completion and a second click while busy use one request', async () => {
  const f = fixture(); const gate = deferred(); f.pathLoads.push(gate.promise);
  const pending = f.c.pathDiagnosticAction('start'); await f.c.pathDiagnosticAction('stop');
  assert.equal(f.pathRequests.length, 1);
  gate.resolve('ok'); await pending;
  assert.equal(f.c.pathDiagnosticStatus, 'start: ok'); assert.equal(f.c.pathDiagnosticBusy, false);
});
for (const failure of ['context', 'sync', 'reject']) test('path ' + failure + ' failure is contained and releases busy', async () => {
  const f = fixture();
  if (failure === 'context') f.contextError = true;
  if (failure === 'sync') f.pathLoads.push(Error('native call failed'));
  if (failure === 'reject') { const gate = deferred(); f.pathLoads.push(gate.promise); queueMicrotask(() => gate.reject(Error('rejection'))); }
  await assert.doesNotReject(f.c.pathDiagnosticAction('start'));
  assert.equal(f.c.pathDiagnosticBusy, false); assert.equal(f.c.pathDiagnosticStatus, 'start: unavailable');
});
for (const outcome of ['resolve', 'reject']) for (const state of ['destroyed', 'locked', 'background', 'closed']) {
  test(state + ' path action ignores late ' + outcome, async () => {
    const f = fixture(); const gate = deferred(); f.pathLoads.push(gate.promise);
    const pending = f.c.pathDiagnosticAction('start'); changeState(f, state);
    if (outcome === 'resolve') gate.resolve('ok'); else gate.reject(Error('late native failure'));
    await pending;
    assert.equal(f.c.pathDiagnosticStatus, 'previous path');
    if (state !== 'destroyed') assert.equal(f.c.pathDiagnosticBusy, false);
  });
}
test('a stale path completion cannot overwrite or release a newer action', async () => {
  const f = fixture(); const old = deferred(), fresh = deferred(); f.pathLoads.push(old.promise, fresh.promise);
  const oldWork = f.c.pathDiagnosticAction('start'); f.c.closeStandaloneDiagnostics();
  const newWork = f.c.pathDiagnosticAction('stop'); old.resolve('old'); await oldWork;
  assert.equal(f.c.pathDiagnosticBusy, true); assert.equal(f.c.pathDiagnosticStatus, 'previous path');
  fresh.resolve('ok'); await newWork;
  assert.equal(f.c.pathDiagnosticBusy, false); assert.equal(f.c.pathDiagnosticStatus, 'stop: ok');
});
test('standalone diagnostics opens without entering Settings and crash collection remains opt-in', () => {
  const f = fixture(); f.c.activeNavigationId = 'home'; f.c.openStandaloneDiagnostics();
  assert.equal(f.c.standaloneDiagnosticsVisible, true); assert.equal(f.c.crashCaptureEnabled, false);
  assert.equal(f.crashEnableCalls, 0); assert.equal(f.timers.size, 0);
  f.c.setStandaloneCrashCapture(true);
  assert.equal(f.c.crashCaptureEnabled, true); assert.equal(f.crashEnableCalls, 1);
  f.c.setStandaloneCrashCapture(false); assert.equal(f.crashDisableCalls, 1);
  f.c.closeStandaloneDiagnostics(); assert.equal(f.c.standaloneDiagnosticsVisible, false);
});
test('home omits diagnostics shortcut while the diagnostics sheet remains available', () => {
  const home = method('HomeContent');
  assert.doesNotMatch(home, /home-diagnostics-entry|openStandaloneDiagnostics/);
  assert.match(source, /@State standaloneDiagnosticsVisible: boolean = false/);
  assert.match(source, /standalone-diagnostics-sheet-host/);
  assert.match(source, /\.bindSheet\(\$\$this\.standaloneDiagnosticsVisible,\s*this\.StandaloneDiagnosticsContent\(\)/);
  const sheet = method('StandaloneDiagnosticsContent');
  assert.doesNotMatch(sheet, /SettingsPage\(|HdsNavigation\(|SettingsDetailPageMap/);
});


function cacheCleanupFixture({ directory = false, mtime }) {
  const removed = [];
  const taildropCtrlSource = read('entry/src/main/ets/services/TaildropSessionController.ets');
  const match = /^  cleanupExpiredCacheEntry\(/m.exec(taildropCtrlSource);
  assert.ok(match, 'production method cleanupExpiredCacheEntry');
  const end = taildropCtrlSource.indexOf('\n  }', match.index);
  assert.ok(end >= 0, 'cleanupExpiredCacheEntry closing brace');
  const extracted = taildropCtrlSource.slice(match.index, end + 4);
  const sandbox = { fileIo: {
    statSync: () => ({ mtime, isFile: () => !directory, isDirectory: () => directory }),
    listFileSync: () => [],
    unlinkSync: path => removed.push({ kind: 'file', path }),
    rmdirSync: path => removed.push({ kind: 'directory', path })
  } };
  vm.runInNewContext(stripTypeScriptTypes('class Cache {\n' + extracted +
    '\n}\nglobalThis.Cache = Cache;'), sandbox);
  return { c: new sandbox.Cache(), removed };
}
test('cache retention keeps a newly generated diagnostic ZIP when Stat.mtime is in seconds', () => {
  const nowMs = Date.UTC(2026, 9, 22, 12);
  const cutoffMs = nowMs - 24 * 60 * 60 * 1000;
  const f = cacheCleanupFixture({ mtime: Math.floor(nowMs / 1000) });
  assert.equal(f.c.cleanupExpiredCacheEntry('/cache/new-diagnostic.zip', cutoffMs), false);
  assert.equal(f.removed.length, 0);
});
test('cache retention removes an expired diagnostic ZIP after converting seconds to milliseconds', () => {
  const cutoffMs = Date.UTC(2026, 9, 21, 12);
  const f = cacheCleanupFixture({ mtime: Math.floor((cutoffMs - 1000) / 1000) });
  assert.equal(f.c.cleanupExpiredCacheEntry('/cache/old-diagnostic.zip', cutoffMs), true);
  assert.equal(f.removed.length, 1);
  assert.equal(f.removed[0].kind, 'file');
  assert.equal(f.removed[0].path, '/cache/old-diagnostic.zip');
});
test('cache retention keeps a newly created empty directory when Stat.mtime is in seconds', () => {
  const nowMs = Date.UTC(2026, 9, 22, 12);
  const cutoffMs = nowMs - 24 * 60 * 60 * 1000;
  const f = cacheCleanupFixture({ directory: true, mtime: Math.floor(nowMs / 1000) });
  assert.equal(f.c.cleanupExpiredCacheEntry('/cache/new-report-work', cutoffMs), false);
  assert.equal(f.removed.length, 0);
});



for (const outcome of ['success', 'failure', 'throw']) test('clearing crash capture during ZIP generation cancels the old share even when disable ' + outcome, async () => {
  const f = fixture(); const zip = deferred(); f.zipLoads.push(zip.promise);
  f.c.crashCaptureEnabled = true; f.crashEnabled = true;
  f.crashDisableFailure = outcome === 'failure'; f.crashDisableError = outcome === 'throw';
  const pending = f.c.generateDiagnosticReport(); await flush();
  assert.equal(f.generated.length, 1); assert.equal(f.c.diagnosticReportInProgress, true);
  f.c.setStandaloneCrashCapture(false);
  assert.equal(f.crashDisableCalls, 1); assert.equal(f.c.diagnosticReportInProgress, false);
  zip.resolve({ size: 2048, fileName: 'old-with-crash.zip', path: '/cache/old-with-crash.zip' }); await pending;
  assert.equal(f.shares.length, 0); assert.equal(f.c.diagnosticReportInProgress, false);
  assert.equal(f.events.some(event => event[0] === 'diagnostic_share_opened'), false);
});

test('a cleared old ZIP cannot share or clear the busy state of a replacement export', async () => {
  const f = fixture(); const oldZip = deferred(), newZip = deferred();
  f.zipLoads.push(oldZip.promise, newZip.promise); f.c.crashCaptureEnabled = true; f.crashEnabled = true;
  const oldReport = f.c.generateDiagnosticReport(); await flush();
  assert.equal(f.generated.length, 1);
  f.c.setStandaloneCrashCapture(false); assert.equal(f.c.diagnosticReportInProgress, false);
  const newReport = f.c.generateDiagnosticReport(); await flush();
  assert.equal(f.generated.length, 2); assert.equal(f.c.diagnosticReportInProgress, true);
  oldZip.resolve({ size: 2048, fileName: 'old-with-crash.zip', path: '/cache/old-with-crash.zip' }); await oldReport;
  assert.equal(f.shares.length, 0); assert.equal(f.c.diagnosticReportInProgress, true);
  newZip.resolve({ size: 1024, fileName: 'new-cleared.zip', path: '/cache/new-cleared.zip' }); await newReport;
  assert.equal(f.shares.length, 1); assert.equal(f.shares[0].result.fileName, 'new-cleared.zip');
  assert.equal(f.c.diagnosticReportInProgress, false);
});


test('feedback builds the same redacted report and opens one draft, never marking it sent', async () => {
  const f = fixture(); await f.c.generateDiagnosticReport(true);
  assert.equal(f.generated.length, 1); assert.equal(f.mails.length, 1); assert.equal(f.shares.length, 0);
  assert.equal(f.mails[0].recipient, 'feedback@example.test'); assert.equal(f.c.feedbackEmailStatus, 'opened');
  assert.equal(f.events.some(e => /sent/.test(e[0])), false);
  assert.equal(f.crashEnableCalls, 0);
});

test('repeated feedback and ordinary export share one busy guard', async () => {
  const f = fixture(), gate = deferred(); f.zipLoads.push(gate.promise);
  const pending = f.c.generateDiagnosticReport(true); await flush();
  f.c.openFeedbackEmail(); await f.c.generateDiagnosticReport();
  assert.equal(f.generated.length, 1);
  gate.resolve({size:12,path:'/cache/report.zip',fileName:'report.zip'}); await pending;
  assert.equal(f.mails.length, 1);
});

for (const state of ['destroyed', 'locked', 'background', 'closed']) test('email cannot launch after ZIP completes while ' + state, async () => {
  const f = fixture(), gate = deferred(); f.zipLoads.push(gate.promise);
  const pending = f.c.generateDiagnosticReport(true); await flush(); changeState(f, state);
  gate.resolve({size:12,path:'/cache/report.zip',fileName:'report.zip'}); await pending;
  assert.equal(f.mails.length, 0); assert.equal(f.shares.length, 0);
  if (state !== 'destroyed') assert.equal(f.c.feedbackEmailStatus, '');
});

for (const failure of ['zip', 'mail-sync', 'mail-reject']) test('email ' + failure + ' failure offers manual export without automatic sharing', async () => {
  const f = fixture();
  if (failure === 'zip') f.zipLoads.push(Error('zip failed'));
  if (failure === 'mail-sync') f.mailLoads.push(Error('mail unavailable'));
  if (failure === 'mail-reject') {const gate = deferred();f.mailLoads.push(gate.promise);queueMicrotask(()=>gate.reject(Error('mail rejected')));}
  await f.c.generateDiagnosticReport(true);
  assert.equal(f.c.feedbackEmailStatus, 'failed');assert.equal(f.c.diagnosticReportInProgress,false);assert.equal(f.shares.length,0);
  await f.c.generateDiagnosticReport();assert.equal(f.shares.length,1);
});

test('a late resolver failure changes the prepared draft to fallback exactly once', async () => {
  const f = fixture(); await f.c.generateDiagnosticReport(true);
  f.mails[0].failure(16000001);f.mails[0].failure(16000001);
  assert.equal(f.c.feedbackEmailStatus,'failed');assert.equal(f.events.filter(e=>e[0]==='feedback_email_unavailable').length,1);
});

test('an old mail callback cannot overwrite a replacement export or revoked capture state', async () => {
  const f=fixture();await f.c.generateDiagnosticReport(true);const old=f.mails[0].failure;
  await f.c.generateDiagnosticReport(true);old(16000001);assert.equal(f.c.feedbackEmailStatus,'opened');
  f.c.setStandaloneCrashCapture(false);f.mails[1].failure(16000001);assert.equal(f.c.feedbackEmailStatus,'');
});

test('capture revocation during compression prevents emailing the old report', async () => {
  const f=fixture(),gate=deferred();f.zipLoads.push(gate.promise);
  const pending=f.c.generateDiagnosticReport(true);await flush();f.c.setStandaloneCrashCapture(false);
  gate.resolve({size:12,path:'/cache/report.zip',fileName:'report.zip'});await pending;assert.equal(f.mails.length,0);
});
