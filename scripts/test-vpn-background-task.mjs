import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

// Run the real lifecycle coordinator with deterministic platform boundaries.
// ArkTS compilation is verified separately by the repository debug build.
const source = readFileSync(new URL('../entry/src/main/ets/services/VpnBackgroundTaskManager.ets', import.meta.url), 'utf8');
const javascript = stripTypeScriptTypes(source.replace(/^import .*;\r?$/gm, '')
  .replace('export class VpnBackgroundTaskManager', 'class VpnBackgroundTaskManager')
  .replace(/^export const vpnBackgroundTaskManager.*;\r?$/gm, ''));
const flush = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
function deferred() {
  let resolve;
  const promise = new Promise(r => { resolve = r; });
  return { promise, resolve };
}

function fixture() {
  const f = {
    now: 1000000, status: '', starts: [], stops: 0, stoppedIds: [], notifications: [], canceledNotifications: [],
    events: [], systemTasks: [],
    callbacks: new Map(), startGate: null, publishGate: null, startError: null, startTaskResult: null,
    stopGate: null, readError: false
  };
  const context = { filesDir: '/files', resourceManager: {
    getStringByNameSync: name => name.includes('connecting') ? 'Connecting VPN' : 'VPN connected'
  } };
  const sandbox = {
    Date: { now: () => f.now }, setInterval: () => 1, clearInterval: () => {},
    wantAgent: { OperationType: { START_ABILITY: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 },
      getWantAgent: async () => ({}) },
    backgroundTaskManager: {
      ContinuousTaskCancelReason: { USER_CANCEL: 1, USER_CANCEL_REMOVE_NOTIFICATION: 3 },
      on: (name, cb) => f.callbacks.set(name, cb), off: name => f.callbacks.delete(name),
      getAllContinuousTasks: async () => f.systemTasks,
      startBackgroundRunning: async (_ctx, modes) => {
        f.starts.push(modes);
        if (f.startError) throw f.startError;
        if (f.startGate) await f.startGate.promise;
        return f.startTaskResult ?? { notificationId: 42, continuousTaskId: 7 };
      },
      stopBackgroundRunning: async (_ctx, id) => {
        f.stops++; f.stoppedIds.push(id); if (f.stopGate) await f.stopGate.promise;
      }
    },
    fileIo: { readTextSync: () => { if (f.readError) throw Error('temporary I/O'); return f.status; } },
    StoragePaths: { vpnStatusPath: dir => dir + '/vpn-probe-status.txt' },
    notificationManager: {
      SlotType: { LIVE_VIEW: 4 }, ContentType: { NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW: 5 },
      publish: async request => { f.notifications.push(request); if (f.publishGate) await f.publishGate.promise; },
      cancel: async id => { f.canceledNotifications.push(id); }
    },
    hilog: { info: () => {} }, DiagnosticEventStore: { record: (...args) => f.events.push(args) }
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
  assert.equal(f.notifications[0].template.data.progressValue, undefined);
  f.manager.onBackground(f.context); await flush();
  assert.equal(f.stops, 0);
  assert.equal(f.starts.length, 1);
  assert.equal(f.notifications.length, 1);
  f.now += 30000; f.live(); await f.tick();
  assert.equal(f.notifications.length, 2);
  assert.equal(f.notifications[1].id, 42);
});

test('adopts the existing system task after Ability recreation without starting another', async () => {
  const f = fixture(); f.systemTasks = [{
    abilityName: 'EntryAbility', backgroundModes: ['dataTransfer'],
    continuousTaskId: 7, notificationId: 42
  }];
  f.live(); f.manager.register(f.context); await flush();
  assert.equal(f.starts.length, 0);
  assert.equal(f.manager.task.continuousTaskId, 7);
  assert.equal(f.notifications[0].id, 42);
  f.manager.onForeground(f.context); await flush();
  assert.equal(f.starts.length, 0);
});

test('active event refreshes the owned live view and ignores another task', async () => {
  const f = fixture(); await f.start();
  f.callbacks.get('continuousTaskActive')({ id: 99 }); await flush();
  assert.equal(f.notifications.length, 1);
  f.callbacks.get('continuousTaskActive')({ id: 7 }); await flush();
  assert.equal(f.notifications.length, 2);
});

test('explicit connect request acquires protection before the first VPN heartbeat', async () => {
  const f = fixture(); f.manager.register(f.context); await flush();
  f.manager.onVpnConnectionRequested(f.context); await flush();
  assert.equal(f.starts.length, 1);
  assert.equal(f.notifications[0].content.systemLiveView.title, 'Connecting VPN');
  f.now += 1000; f.live(); await f.tick();
  assert.equal(f.stops, 0);
  assert.equal(f.starts.length, 1);
});

test('an old terminal status cannot end a new pending connection', async () => {
  const f = fixture(); f.disconnected(); f.manager.register(f.context); await flush();
  f.now += 1; f.manager.onVpnConnectionRequested(f.context); await flush();
  assert.equal(f.starts.length, 1);
  assert.equal(f.stops, 0);
});

test('a request without any live heartbeat releases its provisional task after the grace period', async () => {
  const f = fixture(); f.manager.register(f.context); await flush();
  f.manager.onVpnConnectionRequested(f.context); await flush();
  f.now += 31000; await f.tick();
  assert.equal(f.stoppedIds[0], 7);
});

test('explicit disconnect releases protection despite an old Running status', async () => {
  const f = fixture(); await f.start();
  f.manager.onVpnDisconnected(f.context); await flush();
  assert.equal(f.stoppedIds[0], 7);
  f.now += 1000; f.live(); await f.tick();
  assert.equal(f.starts.length, 1);
});

test('failed system VPN stop restores protection if the VPN is still live', async () => {
  const f = fixture(); await f.start();
  f.manager.onVpnDisconnected(f.context); await flush();
  f.now += 1000; f.live();
  f.manager.onVpnStopFailed(f.context); await flush();
  assert.equal(f.starts.length, 2);
});

test('disconnect during a pending task start cleans up its late result', async () => {
  const f = fixture(); f.startGate = deferred(); f.manager.register(f.context); await flush();
  f.manager.onVpnConnectionRequested(f.context); await flush();
  f.manager.onVpnDisconnected(f.context);
  f.startGate.resolve(); await flush();
  assert.equal(f.stoppedIds[0], 7);
  assert.equal(f.manager.task, undefined);
});

test('cancellation during live-view publication removes the late notification', async () => {
  const f = fixture(); f.publishGate = deferred(); await f.start();
  f.cancel(1); f.publishGate.resolve(); await flush();
  assert.equal(f.canceledNotifications[0], 42);
});

test('stale heartbeat and read errors retain protection and refresh the live view', async () => {
  const f = fixture(); await f.start();
  f.now += 16000; await f.tick(); assert.equal(f.stops, 0);
  f.readError = true; f.now += 20000; await f.tick(); assert.equal(f.stops, 0);
  f.now += 11 * 60 * 1000; await f.tick();
  assert.equal(f.stops, 0);
  assert.equal(f.starts.length, 1);
  assert.equal(f.notifications.length, 3);
  assert.equal(f.notifications.at(-1).id, 42);
  f.readError = false; f.disconnected(); await f.tick(); assert.equal(f.stops, 1);
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
  assert.equal(f.stoppedIds[0], 7);
  assert.equal(f.manager.task, undefined);
});

test('terminal status releases protection even when the UI reads it after 15 seconds', async () => {
  const f = fixture(); await f.start();
  f.now += 1000; f.disconnected();
  f.now += 16000; await f.tick();
  assert.deepEqual(f.stoppedIds, [7]);
  assert.equal(f.manager.task, undefined);
  assert.equal(f.notifications.length, 1);
});

test('an expired terminal status from a previous session cannot stop a new connection', async () => {
  const f = fixture(); f.disconnected();
  f.now += 16000; f.manager.register(f.context); await flush();
  f.manager.onVpnConnectionRequested(f.context); await flush();
  assert.equal(f.starts.length, 1);
  assert.equal(f.stops, 0);
  f.now += 1000; f.live(); await f.tick();
  assert.equal(f.stops, 0);
});

test('a terminal record older than the last live heartbeat cannot end the current session', async () => {
  const f = fixture(); f.disconnected(); const oldStatus = f.status;
  f.now += 1000; await f.start();
  f.status = oldStatus;
  f.now += 16000; await f.tick();
  assert.equal(f.stops, 0);
  assert.equal(f.manager.task.continuousTaskId, 7);
});

test('terminal records with missing or future heartbeat do not revoke protection', async () => {
  for (const status of ['VPN extension destroyed',
    'VPN extension destroyed | heartbeatMs=2000000']) {
    const f = fixture(); await f.start();
    f.status = status; await f.tick();
    assert.equal(f.stops, 0, status);
  }
});

test('stop resolves a missing task ID by its notification without stopping unrelated tasks', async () => {
  const f = fixture(); f.startTaskResult = { notificationId: 42 };
  await f.start();
  f.systemTasks = [{ abilityName: 'EntryAbility', backgroundModes: ['dataTransfer'],
    continuousTaskId: 7, notificationId: 42 }];
  f.manager.onVpnDisconnected(f.context); await flush();
  assert.equal(f.stoppedIds[0], 7);
});

test('snapshot failure is uncertain and does not immediately revoke protection', async () => {
  const f = fixture(); await f.start();
  f.status = `FAILED | VPN backend | status unavailable | heartbeatMs=${f.now}`;
  await f.tick(); assert.equal(f.stops, 0);
});

test('user cancellation stays suppressed in background and recovers on foreground return', async () => {
  const f = fixture(); await f.start(); f.cancel(1);
  f.now += 90000; await f.tick(); f.live();
  assert.equal(f.starts.length, 1);
  f.manager.onForeground(f.context); await flush();
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

test('unrelated cancellation during start is ignored when the task ID arrives', async () => {
  const f = fixture(); f.startGate = deferred(); await f.start(); f.cancel(1, 99);
  f.startGate.resolve(); await flush();
  assert.equal(f.manager.task.continuousTaskId, 7);
  assert.equal(f.notifications.length, 1);
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
