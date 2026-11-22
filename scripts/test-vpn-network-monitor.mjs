import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const source = readFileSync(new URL('../entry/src/main/ets/services/VpnNetworkMonitor.ets', import.meta.url), 'utf8');
const js = stripTypeScriptTypes(source.replace(/^import .*;\r?$/gm, '')
  .replace('export class VpnNetworkMonitor', 'class VpnNetworkMonitor'));
const flush = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };

function fixture() {
  const f = { now: 10000, timers: new Map(), nextId: 0, callbacks: new Map(), calls: [], events: [],
    netId: 10, name: 'wlan0', address: '192.0.2.2', mtu: 1500, capabilities: [12, 16], bearers: null, gate: null, propertiesGate: null,
    failure: false, failureResult: 'FAILED | refresh', propertiesError: null,
    registerError: false, registered: 0, unregistered: 0 };
  const monitor = {
    on: (event, cb) => f.callbacks.set(event, cb),
    register: cb => { f.registered++; cb(f.registerError ? { code: 201 } : undefined); },
    unregister: cb => { f.unregistered++; cb(); }
  };
  const sandbox = {
    Date: { now: () => f.now },
    setTimeout: (cb, ms) => { const id = ++f.nextId; f.timers.set(id, { cb, at: f.now + ms }); return id; },
    clearTimeout: id => f.timers.delete(id),
    setInterval: (cb, ms) => { const id = ++f.nextId; f.timers.set(id, { cb, at: f.now + ms, interval: ms }); return id; },
    clearInterval: id => f.timers.delete(id),
    connection: { createNetConnection: () => monitor,
      NetBearType: { BEARER_CELLULAR: 0, BEARER_WIFI: 1 },
      getNetCapabilities: async () => ({ bearerTypes: f.bearers || [f.name.startsWith('rmnet') ? 0 : 1], networkCap: f.capabilities }),
      getDefaultNet: async () => ({ netId: f.netId }),
      getConnectionProperties: async () => {
        if (f.propertiesError) throw f.propertiesError;
        const props = { interfaceName: f.name, mtu: f.mtu, linkAddresses: [{ address: { address: f.address }, prefixLength: 24 }], dnses: [] };
        if (f.propertiesGate) await f.propertiesGate.promise;
        return props;
      } },
    nativeBridge: { backendNetworkChangedAsync: async name => {
      f.calls.push(name); if (f.gate) await f.gate.promise;
      return f.failure ? f.failureResult : 'OK | refresh';
    } }
  };
  vm.runInNewContext(js + '\nglobalThis.Monitor = VpnNetworkMonitor;', sandbox);
  f.monitor = new sandbox.Monitor((event, code, context) => f.events.push({ event, code, context }));
  f.advance = async ms => {
    f.now += ms;
    for (const [id, timer] of [...f.timers]) {
      if (timer.at <= f.now) { if (timer.interval) timer.at = f.now + timer.interval; else f.timers.delete(id); timer.cb(); }
    }
    await flush();
  };
  f.start = async () => { f.monitor.start(); await f.advance(750); await f.advance(750); };
  f.change = (name, id) => { f.name = name; f.netId = id; f.callbacks.get('netAvailable')({ netId: id }); };
  return f;
}

test('uses the current default network, coalesces duplicates, never logs address data', async () => {
  const f = fixture(); await f.start(); assert.deepEqual(f.calls, ['wlan0']);
  f.callbacks.get('netAvailable')({ netId: 900 }); await f.advance(4000);
  assert.deepEqual(f.calls, ['wlan0']);
  assert.doesNotMatch(JSON.stringify(f.events), /wlan|192\.0/);
});

test('replays a cellular transition whose timer fires during an in-flight Wi-Fi rebind', async () => {
  const f = fixture(); f.gate = deferred(); await f.start();
  f.change('rmnet0', 20); await f.advance(5000);
  assert.deepEqual(f.calls, ['wlan0']);
  f.gate.resolve(); await flush(); await f.advance(750);
  assert.deepEqual(f.calls, ['wlan0', 'rmnet0']);
});

test('discards a stale read when default net changes before properties return', async () => {
  const f = fixture(); await f.start();
  f.propertiesGate = deferred(); f.change('wlan0', 11); await f.advance(4000);
  f.change('rmnet0', 20); f.propertiesGate.resolve(); await flush(); await f.advance(5000);
  assert.deepEqual(f.calls, ['wlan0', 'rmnet0']);
});

test('same interface on a new Wi-Fi network and address renewal both trigger refresh', async () => {
  const f = fixture(); await f.start(); f.change('wlan0', 11); await f.advance(4000);
  f.address = '192.0.2.3'; f.callbacks.get('netConnectionPropertiesChange')({}); await f.advance(4000);
  assert.equal(f.calls.length, 3);
});

test('clears the route hint when offline and applies the restored bearer', async () => {
  const f = fixture(); await f.start(); f.netId = 0; f.callbacks.get('netLost')({ netId: 10 });
  await f.advance(4000); f.change('rmnet0', 20); await f.advance(4000);
  assert.deepEqual(f.calls, ['wlan0', '', 'rmnet0']);
});

test('failed native refresh retries without another platform callback', async () => {
  const f = fixture(); f.failure = true; await f.start();
  f.failure = false; await f.advance(5000); assert.deepEqual(f.calls, ['wlan0', 'wlan0']);
});

test('registration failures retry and do not leak a listener after stop', async () => {
  const f = fixture(); f.registerError = true; await f.start();
  f.registerError = false; await f.advance(5000); await f.advance(750);
  assert.equal(f.registered, 2);
  f.monitor.stop(); assert.equal(f.unregistered, 1);
  f.change('rmnet0', 20); await f.advance(6000); assert.equal(f.calls.length, 1);
});

test('stop during native work cancels replay and releases the registered listener', async () => {
  const f = fixture(); f.gate = deferred(); await f.start();
  f.change('rmnet0', 20); f.monitor.stop(); f.gate.resolve(); await flush(); await f.advance(10000);
  assert.deepEqual(f.calls, ['wlan0']); assert.equal(f.unregistered, 1); assert.equal(f.timers.size, 0);
});

test('network errors retain stage, revisions, duration and code, never raw exception text', async () => {
  const state = fixture(); state.propertiesError = { code: 201, message: 'token=secret 192.0.2.2 private-user' };
  await state.start();
  const event = state.events.find(event => event.event === 'vpn_network_refresh_failed');
  assert.equal(event.code, 201); assert.equal(event.context.networkStage, 2);
  assert.equal(event.context.retryDelayMs, 5000); assert.ok(event.context.networkRevision > 0);
  assert.ok(event.context.operationDurationMs >= 0);
  assert.doesNotMatch(JSON.stringify(state.events), /secret|192\.0|private-user/);
  await state.advance(5000);
  assert.equal(state.events.filter(event => event.event === 'vpn_network_refresh_failed').length, 1);
  state.propertiesError = null; await state.advance(5000); assert.deepEqual(state.calls, ['wlan0']);
});

test('native rebind failures retain numeric errno without exporting raw result', async () => {
  const state = fixture(); state.failure = true; state.failureResult = 'FAILED | errno=-5 | address=192.0.2.2';
  await state.start(); const event = state.events.find(event => event.event === 'vpn_network_refresh_failed');
  assert.equal(event.code, -5); assert.equal(event.context.networkStage, 5);
  assert.doesNotMatch(JSON.stringify(state.events), /address|192\.0/);
});

test('a diagnostic callback failure does not alter network refresh or its retry policy', async () => {
  const state = fixture(); state.monitor.record = () => { throw Error('diagnostic I/O failed'); };
  await state.start(); assert.deepEqual(state.calls, ['wlan0']);
  state.change('rmnet0', 20); await state.advance(5000); assert.deepEqual(state.calls, ['wlan0', 'rmnet0']);
});

test('a late native error from an obsolete network does not label the current network as failed', async () => {
  const state = fixture(); state.gate = deferred(); state.failure = true; await state.start();
  state.change('rmnet0', 20); await state.advance(5000); state.gate.resolve(); await flush();
  assert.equal(state.events.filter(event => event.event === 'vpn_network_refresh_failed').length, 0);
  state.failure = false; state.gate = null; await state.advance(750);
  assert.deepEqual(state.calls, ['wlan0', 'rmnet0']);
});


test('periodic sampling recovers a missed Wi-Fi to cellular callback without rebinding an unchanged network', async () => {
  const f = fixture(); await f.start();
  await f.advance(30000); await f.advance(750);
  assert.deepEqual(f.calls, ['wlan0']);
  f.name = 'rmnet0'; f.netId = 20;
  await f.advance(30000); await f.advance(750);
  assert.deepEqual(f.calls, ['wlan0', 'rmnet0']);
  f.monitor.stop(); assert.equal(f.timers.size, 0);
});

test('callback diagnostics retain event ordering without endpoint or interface details', async () => {
  const f = fixture(); await f.start();
  f.callbacks.get('netLost')({ netId: 10 });
  f.change('rmnet0', 20); await f.advance(4000);
  assert.ok(f.events.some(x => x.event === 'vpn_network_callback_lost'));
  assert.ok(f.events.some(x => x.event === 'vpn_network_callback_available'));
  assert.ok(f.events.some(x => x.event === 'vpn_network_rebind_started_cellular'));
  assert.doesNotMatch(JSON.stringify(f.events), /wlan|rmnet|192\.0|netId/);
});

test('airplane mode, Wi-Fi after 10 seconds, and morning cellular recovery rebind in order', async () => {
  const f = fixture(); await f.start();
  f.netId = 0; f.callbacks.get('netLost')({}); await f.advance(4000);
  f.change('wlan0', 11); await f.advance(10000);
  f.change('rmnet0', 20); await f.advance(8 * 3600000);
  assert.deepEqual(f.calls, ['wlan0', '', 'wlan0', 'rmnet0']);
  assert.ok(f.events.some(row => row.event === 'vpn_network_offline'));
});

test('shared transport and MTU changes refresh an otherwise unchanged interface', async () => {
  const f = fixture(); await f.start();
  f.bearers = [1, 2]; f.mtu = 1400;
  f.callbacks.get('netCapabilitiesChange')({}); await f.advance(4000);
  f.bearers = [1]; f.mtu = 1500;
  f.callbacks.get('netConnectionPropertiesChange')({}); await f.advance(4000);
  assert.deepEqual(f.calls, ['wlan0', 'wlan0', 'wlan0']);
  assert.ok(f.events.some(row => row.event === 'vpn_network_sample_bearer_mask' && row.code === 6));
  assert.ok(f.events.some(row => row.event === 'vpn_network_sample_mtu' && row.code === 1400));
  assert.doesNotMatch(JSON.stringify(f.events), /wlan|192\.0/);
});

test('validation changes are observable without repeatedly rebuilding the same physical route', async () => {
  const f = fixture(); await f.start(); f.capabilities = [12];
  f.callbacks.get('netCapabilitiesChange')({}); await f.advance(4000);
  f.capabilities = [12, 16]; f.callbacks.get('netCapabilitiesChange')({}); await f.advance(4000);
  assert.deepEqual(f.calls, ['wlan0']);
  assert.equal(f.events.filter(row => row.event === 'vpn_network_sample_capability_mask').length, 3);
});
