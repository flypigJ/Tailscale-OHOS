import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

// Run the real lifecycle coordinator with deterministic platform boundaries.
// ArkTS compilation is verified separately by the repository debug build.
const source = readFileSync(new URL('../entry/src/main/ets/services/VpnBackgroundTaskManager.ets', import.meta.url), 'utf8');
const javascript = stripTypeScriptTypes(source.replace(/^import .*;\r?$/gm, '')
  .replace('export class VpnBackgroundTaskManager', 'class VpnBackgroundTaskManager'));
const flush = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
function deferred() {
  let resolve;
  const promise = new Promise(r => { resolve = r; });
  return { promise, resolve };
}

function fixture() {
  const f = {
    now: 1000000, status: '', starts: [], stops: 0, stopIds: [], notifications: [], events: [],
    callbacks: new Map(), startGate: null, publishGate: null, startError: null,
    stopGate: null, readError: false, intent: undefined, taskId: 7, queryGate: null, taskQueryError: null, binds: [], unbinds: [], bindError: null, bindResult: undefined
  };
  const context = { filesDir: '/files', resourceManager: { getStringByNameSync: () => 'VPN connected' }, connectServiceExtensionAbility: (want, options) => { if (f.bindError) throw f.bindError; f.binds.push({ want, options }); return f.bindResult !== undefined ? f.bindResult : f.binds.length; }, disconnectServiceExtensionAbility: async id => { f.unbinds.push(id); } };
  const sandbox = {
    Date: { now: () => f.now }, setInterval: () => 1, clearInterval: () => {},
    wantAgent: { OperationType: { START_ABILITY: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 },
      getWantAgent: async () => ({}) },
    backgroundTaskManager: {
      ContinuousTaskCancelReason: { USER_CANCEL: 1, USER_CANCEL_REMOVE_NOTIFICATION: 3 },
      on: (name, cb) => f.callbacks.set(name, cb), off: name => f.callbacks.delete(name),
      startBackgroundRunning: async (_ctx, modes) => {
        f.starts.push(modes);
        if (f.startError) throw f.startError;
        if (f.startGate) await f.startGate.promise;
        return { notificationId: 42, continuousTaskId: f.taskId };
      },
      getAllContinuousTasks: async () => {
        if (f.queryGate) await f.queryGate.promise;
        if (f.taskQueryError) throw f.taskQueryError;
        return [{ abilityName: 'AnotherAbility', notificationId: 42, continuousTaskId: 99,
          backgroundModes: ['dataTransfer'] },
        { abilityName: 'EntryAbility', notificationId: 42, continuousTaskId: 7,
          backgroundModes: ['dataTransfer'] }];
      },
      stopBackgroundRunning: async (_context, id) => { f.stopIds.push(id); f.stops++; if (f.stopGate) await f.stopGate.promise; }
    },
    fileIo: { readTextSync: path => {
      if (f.readError) throw Error('temporary I/O');
      if (path.endsWith('/vpn-connect-intent.json')) {
        if (f.intent === undefined) throw Error('intent absent');
        return typeof f.intent === 'string' ? f.intent : JSON.stringify(f.intent);
      }
      return f.status;
    } },
    StoragePaths: { vpnStatusPath: dir => dir + '/vpn-probe-status.txt' },
    notificationManager: {
      SlotType: { LIVE_VIEW: 4 }, ContentType: { NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW: 5 },
      publish: async request => { f.notifications.push(request); if (f.publishGate) await f.publishGate.promise; }
    },
    hilog: { info: () => {}, error: () => {} },
    DiagnosticEventStore: { recordDetailed: (...args) => f.events.push(args) }
  };
  vm.runInNewContext(javascript + '\nglobalThis.Manager = VpnBackgroundTaskManager;', sandbox);
  f.manager = new sandbox.Manager();
  f.live = () => { f.status = `OK | state=Running | tun=true | txBytes=2048 | rxBytes=1048576 | heartbeatMs=${f.now}`; };
  f.disconnected = () => { f.status = `VPN extension destroyed | heartbeatMs=${f.now}`; };
  f.tick = async () => { await f.manager.reconcile(context); await flush(); };
  f.start = async () => { f.live(); f.manager.register(context); await flush(); };
  f.cancel = (reason, id = 7) => f.callbacks.get('continuousTaskCancel')({ id, reason });
  f.context = context;
  return f;
}

test('acquires protection in foreground and updates the same system live view with real traffic', async () => {
  const f = fixture(); await f.start();
  assert.equal(f.starts.length, 1);
  assert.equal(f.starts[0][0], 'dataTransfer');
  assert.equal(f.notifications[0].id, 42);
  assert.match(f.notifications[0].content.systemLiveView.text, /2.0 KiB.*1.0 MiB/);
  assert.equal(f.notifications[0].template.data.progressValue, 0);
  f.manager.onBackground(f.context); await flush();
  assert.equal(f.stops, 0);
  assert.equal(f.starts.length, 1);
  assert.equal(f.notifications.length, 1);
  f.now += 30000; f.live(); await f.tick();
  assert.equal(f.notifications.length, 2);
  assert.equal(f.notifications[1].id, 42);
});

test('stale heartbeat and read errors retain acquired protection for a bounded grace period', async () => {
  const f = fixture(); await f.start();
  f.now += 16000; await f.tick(); assert.equal(f.stops, 0);
  f.readError = true; f.now += 20000; await f.tick(); assert.equal(f.stops, 0);
  f.now += 25000; await f.tick(); assert.equal(f.stops, 1);
  f.readError = false; f.live(); await f.tick(); assert.equal(f.starts.length, 2);
});

test('never starts from stale, future, missing heartbeat or missing TUN evidence', async () => {
  for (const status of ['OK | state=Running | tun=true',
    'OK | state=Running | tun=true | heartbeatMs=1',
    'OK | state=Running | tun=true | heartbeatMs=2000000',
    'OK | state=Running | tun=false | heartbeatMs=1000000']) {
    const f = fixture(); f.status = status; f.manager.register(f.context); await flush();
    assert.equal(f.starts.length, 0, status);
  }
});

test('explicit disconnect promptly releases the task', async () => {
  const f = fixture(); await f.start(); f.disconnected(); await f.tick();
  assert.equal(f.stops, 1);
  assert.equal(f.manager.task, undefined);
});

test('snapshot failure is uncertain and does not immediately revoke protection', async () => {
  const f = fixture(); await f.start();
  f.status = `FAILED | VPN backend | status unavailable | heartbeatMs=${f.now}`;
  await f.tick(); assert.equal(f.stops, 0);
});

test('user cancellation stays suppressed across stale telemetry and foreground until confirmed disconnect', async () => {
  const f = fixture(); await f.start(); f.cancel(1);
  f.now += 90000; await f.tick(); f.live();
  f.manager.onForeground(f.context); await flush(); assert.equal(f.starts.length, 1);
  f.disconnected(); await f.tick(); f.live(); await f.tick();
  assert.equal(f.starts.length, 2);
});

test('system cancellation retries with exponential backoff', async () => {
  const f = fixture(); await f.start(); f.cancel(2);
  f.now += 29999; f.live(); await f.tick(); assert.equal(f.starts.length, 1);
  f.now++; f.live(); await f.tick(); assert.equal(f.starts.length, 2);
  f.cancel(2); f.now += 30000; f.live(); await f.tick(); assert.equal(f.starts.length, 2);
  f.now += 30000; f.live(); await f.tick(); assert.equal(f.starts.length, 3);
});

test('unrelated cancellation does not discard the VPN task', async () => {
  const f = fixture(); await f.start(); f.cancel(1, 99); await f.tick();
  assert.equal(f.manager.task.continuousTaskId, 7);
});

test('a failed start is throttled instead of retried every second', async () => {
  const f = fixture(); f.startError = { code: 9800005 }; await f.start();
  for (let i = 0; i < 20; i++) { f.now += 1000; f.live(); await f.tick(); }
  assert.equal(f.starts.length, 1);
  f.now += 10000; f.live(); await f.tick(); assert.equal(f.starts.length, 2);
});

test('cancellation received during start cannot be overwritten by its late result', async () => {
  const f = fixture(); f.startGate = deferred(); await f.start(); f.cancel(1);
  f.startGate.resolve(); await flush();
  assert.equal(f.manager.task, undefined); assert.equal(f.notifications.length, 0);
  await f.tick(); assert.equal(f.starts.length, 1);
});

test('disconnect during start cleans up the late successful task without publishing', async () => {
  const f = fixture(); f.startGate = deferred(); await f.start(); f.disconnected();
  f.startGate.resolve(); await flush();
  assert.equal(f.stops, 1); assert.equal(f.notifications.length, 0);
});

test('destroy during start cleans up the late successful task', async () => {
  const f = fixture(); f.startGate = deferred(); await f.start(); f.manager.unregister();
  f.startGate.resolve(); await flush();
  assert.equal(f.stops, 1); assert.equal(f.notifications.length, 0);
  assert.equal(f.callbacks.size, 0);
});

test('destroy during notification update serializes cleanup after publish', async () => {
  const f = fixture(); f.publishGate = deferred(); await f.start(); f.manager.unregister();
  assert.equal(f.stops, 0);
  f.publishGate.resolve(); await flush(); assert.equal(f.stops, 1);
});

test('reconnect waits for in-flight stop before starting the next task', async () => {
  const f = fixture(); await f.start(); f.stopGate = deferred(); f.disconnected();
  const stopping = f.tick(); await flush(); f.live(); await f.tick();
  assert.equal(f.starts.length, 1);
  f.stopGate.resolve(); await stopping; await f.tick(); assert.equal(f.starts.length, 2);
});

test('cancellation logs user suppression and retry context without changing recovery policy', async () => {
  const state = fixture(); await state.start(); state.cancel(3);
  const userEvent = state.events.find(event => event[2] === 'background_user_cancelled');
  assert.equal(userEvent[4], 3); assert.equal(userEvent[5].userSuppressed, true);
  assert.equal(userEvent[5].taskActive, false);
  state.disconnected(); await state.tick(); state.live(); await state.tick(); state.cancel(2);
  const systemEvent = state.events.find(event => event[2] === 'background_system_cancelled');
  assert.equal(systemEvent[4], 2); assert.equal(systemEvent[5].userSuppressed, false);
  assert.ok(systemEvent[5].retryDelayMs > 0);
});

test('background failure diagnostics throttle repeated errors but retain a changed code', async () => {
  const state = fixture(); state.startError = { code: 201 }; await state.start();
  state.now += 3000; state.manager.record('background_operation_failed', 201);
  assert.equal(state.events.filter(event => event[2] === 'background_operation_failed').length, 1);
  state.now += 6000; state.manager.record('background_operation_failed', 202);
  assert.equal(state.events.filter(event => event[2] === 'background_operation_failed').length, 2);
});


test('unrelated cancellations during task creation cannot cancel or suppress the returned VPN task', async () => {
  for (const reason of [1, 2, 3]) {
    const f = fixture(); f.startGate = deferred(); await f.start();
    f.cancel(reason, 99); f.startGate.resolve(); await flush();
    assert.equal(f.manager.task.continuousTaskId, 7);
    assert.equal(f.manager.suppressedUntilDisconnect, false);
    assert.equal(f.manager.retryCount, 0);
    assert.equal(f.notifications.length, 1);
    assert.equal(f.stops, 0);
    assert.equal(f.manager.earlyCancellations.length, 0);
  }
});

test('matching early system cancellation honors backoff and never publishes a cancelled task', async () => {
  const f = fixture(); f.startGate = deferred(); await f.start(); f.cancel(2);
  f.startGate.resolve(); await flush();
  assert.equal(f.manager.task, undefined);
  assert.equal(f.notifications.length, 0);
  assert.equal(f.manager.suppressedUntilDisconnect, false);
  assert.equal(f.manager.nextStartAtMs, f.now + 30000);
  f.now += 29999; f.live(); await f.tick(); assert.equal(f.starts.length, 1);
  f.now++; f.live(); await f.tick(); assert.equal(f.starts.length, 2);
});

test('optional task ID is resolved by ability, notification and mode before applying an early cancellation', async () => {
  const f = fixture(); f.taskId = undefined; f.queryGate = deferred(); await f.start();
  f.cancel(1, 99); f.cancel(3, 7); f.queryGate.resolve(); await flush();
  assert.equal(f.manager.task, undefined);
  assert.equal(f.manager.suppressedUntilDisconnect, true);
  assert.equal(f.notifications.length, 0);
  assert.equal(f.stops, 0);
});

test('failed task identity lookup never treats an unrelated cancellation as the VPN task', async () => {
  const f = fixture(); f.taskId = undefined; f.queryGate = deferred(); await f.start();
  f.cancel(1, 99); f.taskQueryError = { code: 9800004 }; f.queryGate.resolve(); await flush();
  assert.equal(f.manager.task.notificationId, 42);
  assert.equal(f.manager.suppressedUntilDisconnect, false);
  assert.equal(f.manager.retryCount, 0);
  assert.equal(f.events.filter(event => event[2] === 'background_task_id_query_failed').length, 1);
});

test('current terminal status remains authoritative after the 15 second freshness window', async () => {
  const f = fixture(); await f.start(); f.disconnected(); f.now += 16000;
  await f.tick(); assert.equal(f.stops, 1); assert.equal(f.manager.task, undefined);
});

test('terminal status older than the latest live heartbeat cannot end the current connection', async () => {
  const f = fixture(); await f.start(); const oldHeartbeat = f.now;
  f.now += 10000; f.live(); await f.tick();
  f.status = `VPN extension destroyed | heartbeatMs=${oldHeartbeat}`;
  await f.tick(); assert.equal(f.stops, 0); assert.ok(f.manager.task);
});

test('new persistent connect intent rejects an old terminal before the new heartbeat arrives', async () => {
  const f = fixture(); await f.start(); f.disconnected();
  f.now += 20000; f.intent = { desired: true, requestedAtMs: f.now };
  await f.tick(); assert.equal(f.stops, 0); assert.ok(f.manager.task);
});

test('cleared connect intent does not hide a valid terminal record', async () => {
  const f = fixture(); await f.start(); f.disconnected();
  f.now += 20000; f.intent = { desired: false, requestedAtMs: f.now };
  await f.tick(); assert.equal(f.stops, 1); assert.equal(f.manager.task, undefined);
});

test('future and missing terminal timestamps cannot end a connection; the stale fallback still releases it', async () => {
  for (const status of ['VPN extension destroyed',
    'VPN extension destroyed | heartbeatMs=2000000']) {
    const f = fixture(); await f.start(); f.status = status; await f.tick();
    assert.equal(f.stops, 0); assert.ok(f.manager.task);
    f.now += 60001; await f.tick(); assert.equal(f.stops, 1);
  }
});

test('invalid or unreadable intent retains the last live session boundary', async () => {
  for (const intent of [undefined, '{invalid', { desired: true, requestedAtMs: 2000000 },
    { desired: true, requestedAtMs: -1 }]) {
    const f = fixture(); await f.start(); const oldHeartbeat = f.now;
    f.now += 10000; f.live(); await f.tick(); f.intent = intent;
    f.status = `VPN extension destroyed | heartbeatMs=${oldHeartbeat}`;
    await f.tick(); assert.equal(f.stops, 0);
  }
});
async function identityPendingFixture(cancelReason, cancelId = 7) {
  const f = fixture();
  f.taskId = undefined;
  f.taskQueryError = { code: 9800004 };
  f.startGate = deferred();
  await f.start();
  if (cancelReason !== undefined) f.cancel(cancelReason, cancelId);
  f.startGate.resolve();
  await flush();
  return f;
}

test('unidentified task is quarantined after an ID query failure and never duplicated or published', async () => {
  const f = await identityPendingFixture(1);
  assert.equal(f.manager.task.notificationId, 42);
  assert.equal(f.manager.task.continuousTaskId, undefined);
  assert.equal(f.notifications.length, 0);
  assert.equal(f.manager.suppressedUntilDisconnect, false);
  for (let i = 0; i < 29; i++) {
    f.now += 1000; f.live(); await f.tick();
  }
  assert.equal(f.starts.length, 1);
  assert.equal(f.manager.identityAttempts, 0);
  assert.equal(f.notifications.length, 0);
  assert.equal(f.manager.earlyCancellations.length, 1);
});

test('identity retry honors a matching early user cancellation after a temporary lookup failure', async () => {
  const f = await identityPendingFixture(3);
  f.taskQueryError = null;
  f.now += 30000; f.live(); await f.tick();
  assert.equal(f.manager.task, undefined);
  assert.equal(f.manager.suppressedUntilDisconnect, true);
  assert.equal(f.manager.earlyCancellations.length, 0);
  assert.equal(f.notifications.length, 0);
  f.now += 300000; f.live(); await f.tick();
  assert.equal(f.starts.length, 1);
});

test('unrelated cancellation while identity is unknown cannot suppress the confirmed task after retry', async () => {
  const f = await identityPendingFixture(1, 99);
  f.cancel(3, 101); // Also cover a cancellation arriving after creation returns.
  f.taskQueryError = null;
  f.now += 30000; f.live(); await f.tick();
  assert.equal(f.manager.task.continuousTaskId, 7);
  assert.equal(f.manager.suppressedUntilDisconnect, false);
  assert.equal(f.manager.earlyCancellations.length, 0);
  assert.equal(f.notifications.length, 1);
  assert.equal(f.notifications[0].id, 42);
  assert.equal(f.starts.length, 1);
});

test('successful inventory proving the unidentified notification absent suppresses recreation until disconnect', async () => {
  const f = await identityPendingFixture(undefined);
  // The mock inventory only contains notification 42; change the owned handle
  // to model an inventory response in which this notification is absent.
  f.manager.task.notificationId = 404;
  f.taskQueryError = null;
  f.now += 30000; f.live(); await f.tick();
  assert.equal(f.manager.task, undefined);
  assert.equal(f.manager.suppressedUntilDisconnect, true);
  assert.equal(f.notifications.length, 0);
  f.now += 300000; f.live(); await f.tick();
  assert.equal(f.starts.length, 1);
  f.disconnected(); await f.tick();
  f.taskId = 7; f.live(); await f.tick();
  assert.equal(f.starts.length, 2);
  assert.equal(f.manager.task.continuousTaskId, 7);
});

test('identity failures are limited to five retries at 30 second intervals without creating extra tasks', async () => {
  let failedQueries = 0;
  const f = fixture(); f.taskId = undefined;
  f.taskQueryError = { get code() { failedQueries++; return 9800004; } };
  await f.start();
  assert.equal(failedQueries, 1); // The initial start-time query.
  for (let attempt = 1; attempt <= 5; attempt++) {
    f.now += 29999; f.live(); await f.tick();
    assert.equal(failedQueries, attempt);
    f.now++; f.live(); await f.tick();
    assert.equal(failedQueries, attempt + 1);
    assert.equal(f.manager.identityAttempts, attempt);
  }
  for (let i = 0; i < 20; i++) { f.now += 30000; f.live(); await f.tick(); }
  assert.equal(failedQueries, 6);
  assert.equal(f.manager.identityAttempts, 5);
  assert.equal(f.starts.length, 1);
  assert.equal(f.notifications.length, 0);
});

test('destroy with unavailable identity retains cleanup ownership without cancelling unrelated tasks', async () => {
  const f = fixture(); f.taskId = undefined; f.taskQueryError = { code: 9800004 };
  f.startGate = deferred(); await f.start(); f.cancel(1);
  f.manager.unregister(); f.startGate.resolve(); await flush();
  assert.equal(f.stops, 0);
  assert.equal(f.manager.cleanupPending, true);
  assert.ok(f.manager.task);
  assert.equal(f.notifications.length, 0);
});

test('destroy and register during an unidentified start cannot transfer the old handle to the new lifecycle', async () => {
  const f = fixture(); f.taskId = undefined; f.taskQueryError = { code: 9800004 };
  f.startGate = deferred(); await f.start(); f.cancel(1, 99);
  f.manager.unregister(); f.manager.register(f.context);
  f.startGate.resolve(); await flush();
  assert.equal(f.stops, 0);
  assert.equal(f.manager.cleanupPending, true);
  assert.equal(f.notifications.length, 0);
  f.taskId = 7; f.taskQueryError = null; f.live(); await f.tick();
  assert.deepEqual(f.stopIds, [7]);
  assert.equal(f.starts.length, 2);
  assert.equal(f.manager.task.continuousTaskId, 7);
  assert.equal(f.manager.suppressedUntilDisconnect, false);
});

test('destroy and register during identity retry cleans the captured old task before new protection starts', async () => {
  const f = await identityPendingFixture(1, 99);
  f.taskQueryError = null; f.queryGate = deferred();
  f.now += 30000; f.live(); const resolving = f.tick(); await flush();
  f.manager.unregister(); f.manager.register(f.context);
  f.queryGate.resolve(); await resolving;
  assert.equal(f.stops, 1);
  assert.equal(f.manager.task, undefined);
  assert.equal(f.manager.earlyCancellations.length, 0);
  assert.equal(f.notifications.length, 0);
  f.taskId = 7; f.live(); await f.tick();
  assert.equal(f.starts.length, 2);
  assert.equal(f.manager.task.continuousTaskId, 7);
});

test('failed identity retry after destroy and register releases the old task before a new one starts', async () => {
  const f = await identityPendingFixture(1, 99);
  f.queryGate = deferred();
  f.now += 30000; f.live(); const resolving = f.tick(); await flush();
  f.manager.unregister(); f.manager.register(f.context);
  f.queryGate.resolve(); await resolving;
  assert.equal(f.stops, 0);
  assert.equal(f.manager.cleanupPending, true);
  assert.equal(f.notifications.length, 0);
  f.queryGate = null; f.taskId = 7; f.taskQueryError = null; f.live(); await f.tick();
  assert.deepEqual(f.stopIds, [7]);
  assert.equal(f.starts.length, 2);
  assert.equal(f.manager.task.continuousTaskId, 7);
});


test('VPN task cleanup always targets its own ID while experiments may share EntryAbility', async () => {
  const f = fixture(); await f.start(); f.disconnected(); await f.tick();
  assert.deepEqual(f.stopIds, [7]);
});

test('fresh connect intent acquires protection before background freeze and keeps it once live', async () => {
  const f = fixture();
  f.manager.register(f.context); await flush();
  assert.equal(f.starts.length, 0);
  f.intent = { desired: true, requestedAtMs: f.now };
  f.manager.onBackground(f.context); await flush();
  assert.equal(f.starts.length, 1);
  assert.equal(f.notifications.length, 0);
  f.now += 10000; f.live(); await f.tick();
  assert.equal(f.starts.length, 1);
  assert.equal(f.stops, 0);
  assert.equal(f.notifications.length, 1);
});

test('pending connect protection stops after grace timeout and ignores stale intent', async () => {
  const f = fixture();
  f.manager.register(f.context); await flush();
  f.intent = { desired: true, requestedAtMs: f.now };
  f.manager.onBackground(f.context); await flush();
  assert.equal(f.starts.length, 1);
  f.now += 60001; await f.tick();
  assert.equal(f.stops, 1);
  assert.equal(f.starts.length, 1);
  assert.equal(f.manager.task, undefined);
  assert.ok(f.events.some(event => event[2] === 'background_status_timeout'));
});


test('uses ContinuousTaskRequest when API 21+ APIs are available for multi-task coexistence', async () => {
  const requests = [];
  const context = { filesDir: '/files', resourceManager: { getStringByNameSync: () => 'VPN connected' } };
  const sandbox = {
    Date: { now: () => 1000000 }, setInterval: () => 1, clearInterval: () => {},
    wantAgent: { OperationType: { START_ABILITY: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 },
      getWantAgent: async () => ({}) },
    backgroundTaskManager: {
      ContinuousTaskRequest: class {},
      BackgroundTaskMode: { MODE_DATA_TRANSFER: 1 },
      BackgroundTaskSubmode: { SUBMODE_LIVE_VIEW_NOTIFICATION: 3 },
      ContinuousTaskCancelReason: { USER_CANCEL: 1, USER_CANCEL_REMOVE_NOTIFICATION: 3 },
      on: () => {}, off: () => {},
      startBackgroundRunning: async (_ctx, req) => {
        requests.push(req);
        return { notificationId: 42, continuousTaskId: 8 };
      },
      getAllContinuousTasks: async () => [],
      stopBackgroundRunning: async () => {}
    },
    fileIo: { readTextSync: () => 'OK | state=Running | tun=true | txBytes=0 | rxBytes=0 | heartbeatMs=1000000' },
    StoragePaths: { vpnStatusPath: dir => dir + '/vpn-probe-status.txt' },
    notificationManager: {
      SlotType: { LIVE_VIEW: 4 }, ContentType: { NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW: 5 },
      publish: async () => {}
    },
    hilog: { info: () => {}, error: () => {} },
    DiagnosticEventStore: { recordDetailed: () => {} }
  };
  vm.runInNewContext(javascript + '\nglobalThis.Manager = VpnBackgroundTaskManager;', sandbox);
  const manager = new sandbox.Manager();
  manager.register(context);
  await flush();
  assert.equal(requests.length, 1);
  assert.deepEqual([...requests[0].backgroundTaskModes], [1]);
  assert.deepEqual([...requests[0].backgroundTaskSubmodes], [3]);
  assert.equal(requests[0].combinedTaskNotification, false);
});

// The VPN Extension is launched by the system VPN service, so no app process counts
// as connected to it and it sits in the lowest low-memory-kill tier. Binding the
// protected UI process to it lifts that tier (oom_score_adj 500 -> 300/100 on device).
const eventNames = f => f.events.map(args => args[2]);

test('binds the UI process to the live VPN Extension once and releases it on disconnect', async () => {
  const f = fixture(); await f.start();
  assert.equal(f.binds.length, 1);
  assert.equal(f.binds[0].want.bundleName, 'io.github.tailscaleohos');
  assert.equal(f.binds[0].want.abilityName, 'TailscaleVpnExtensionAbility');
  assert.equal(f.binds[0].want.parameters.mesharcBindOnly, true);
  f.binds[0].options.onConnect({}, {});
  f.now += 1000; f.live(); await f.tick();
  assert.equal(f.binds.length, 1);
  f.disconnected(); await f.tick();
  assert.deepEqual(f.unbinds, [1]);
  assert.ok(eventNames(f).includes('vpn_extension_bind_connected'));
});

test('never binds against a heartbeat that is not fresh enough to prove a live Extension', async () => {
  const f = fixture();
  f.status = `OK | state=Running | tun=true | txBytes=1 | rxBytes=1 | heartbeatMs=${f.now - 5000}`;
  f.manager.register(f.context); await flush();
  assert.equal(f.starts.length, 1); // still within the 15 s protection window
  assert.equal(f.binds.length, 0);  // but binding could launch a dead Extension
});

test('a lost bind waits for a newer heartbeat before binding again', async () => {
  const f = fixture(); await f.start();
  f.binds[0].options.onDisconnect({});
  await f.tick();
  assert.equal(f.binds.length, 1); // same heartbeat: the Extension may be gone
  f.now += 1000; f.live(); await f.tick();
  assert.equal(f.binds.length, 2); // a newer heartbeat proves a live Extension
  assert.deepEqual(f.unbinds, []);
});

test('a refused bind (sync throw, onFailed, or negative handle) retries only after backoff', async () => {
  const f = fixture(); f.bindError = Object.assign(Error('refused'), { code: 16000002 });
  await f.start();
  assert.equal(f.binds.length, 0);
  assert.ok(f.events.some(args => args[2] === 'vpn_extension_bind_error' && args[4] === 16000002));
  f.bindError = null;
  f.now += 1000; f.live(); await f.tick();
  assert.equal(f.binds.length, 0);
  f.now += 10000; f.live(); await f.tick();
  assert.equal(f.binds.length, 1);
  f.binds[0].options.onFailed(16000050);
  f.now += 1000; f.live(); await f.tick();
  assert.equal(f.binds.length, 1);
  f.now += 10000; f.live(); await f.tick();
  assert.equal(f.binds.length, 2);
  f.binds[1].options.onDisconnect({});
  f.bindResult = -1;
  f.now += 1000; f.live(); await f.tick();
  assert.equal(f.binds.length, 3);
  assert.ok(f.events.some(args => args[2] === 'vpn_extension_bind_error' && args[4] === -1));
  f.bindResult = undefined;
  f.now += 1000; f.live(); await f.tick();
  assert.equal(f.binds.length, 3);
  f.now += 10000; f.live(); await f.tick();
  assert.equal(f.binds.length, 4);
});

test('destroying the Ability releases the Extension binding immediately even with operation in flight', async () => {
  const f = fixture(); f.publishGate = deferred(); await f.start();
  assert.equal(f.binds.length, 1);
  f.manager.unregister();
  assert.deepEqual(f.unbinds, [1]);
  f.publishGate.resolve(); await flush();
  assert.deepEqual(f.unbinds, [1]);
});

test('late callbacks from a previous bind generation cannot drop a newer binding', async () => {
  const f = fixture(); await f.start();
  const staleOptions = f.binds[0].options;
  f.disconnected(); await f.tick();
  assert.deepEqual(f.unbinds, [1]);
  f.now += 1000; f.live(); await f.tick();
  assert.equal(f.binds.length, 2);
  staleOptions.onDisconnect({});
  staleOptions.onFailed(16000050);
  staleOptions.onConnect({}, {});
  assert.equal(f.manager.extensionConnectionId, 2);
  assert.ok(!eventNames(f).includes('vpn_extension_bind_disconnected'));
  assert.ok(!eventNames(f).includes('vpn_extension_bind_failed'));
  assert.ok(!eventNames(f).includes('vpn_extension_bind_connected'));
  f.disconnected(); await f.tick();
  assert.deepEqual(f.unbinds, [1, 2]);
});

test('orphaned binding without an active continuous task is released after status grace timeout', async () => {
  const f = fixture(); await f.start();
  f.cancel(1);
  assert.equal(f.manager.task, undefined);
  assert.equal(f.manager.extensionConnectionId, 1);
  f.now += 60001; await f.tick();
  assert.deepEqual(f.unbinds, [1]);
  assert.equal(f.manager.extensionConnectionId, -1);
});
