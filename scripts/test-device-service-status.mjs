import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../entry/src/main/ets/components/DeviceDetailSheet.ets', import.meta.url), 'utf8');
const services = ['sunshine', 'localSend', 'media'];
function fixture() {
  const names = ['sunshineLabel', 'sunshineStatusState', 'localSendLabel', 'localSendStatusState',
    'mediaLabel', 'mediaStatusState', 'servicesRefreshing'];
  for (const name of ['probeStatusState', 'probeStatusLabel']) {
    if (source.includes(`private ${name}(`)) names.push(name);
  }
  const methods = names.map(name => {
    const method = source.match(new RegExp(`^  private ${name}\\([\\s\\S]*?^  \\}`, 'm'))?.[0];
    assert.ok(method, name);
    return method.replace(/^  private /, 'function ');
  });
  const sandbox = { $r: (key, ...args) => ({ key, args }) };
  vm.runInNewContext(stripTypeScriptTypes(methods.join('\n')), sandbox);
  return {
    online: true, meshConnected: true, serviceRefreshVisible: false, servicesChecking: false,
    sunshineState: 'unknown', localSendState: 'unknown', localSendAvailable: false,
    mediaProbeState: 'unknown', mediaServiceCount: 0, mediaServiceNames: '',
    ...Object.fromEntries(names.map(name => [name, sandbox[name]]))
  };
}
function allStates(state, value) { state.sunshineState = value; state.localSendState = value; state.mediaProbeState = value; }

test('unknown service discovery remains unknown rather than declaring services unavailable', () => {
  const state = fixture();
  for (const value of ['unknown', '', 'future_backend_state']) {
    allStates(state, value);
    for (const service of services) {
      assert.equal(state[`${service}Label`]().key, 'app.string.device_status_unknown');
      assert.equal(state[`${service}StatusState`](), 'unknown');
    }
  }
});

test('explicit per-service checking states have matching labels without changing the global spinner', () => {
  const state = fixture(); allStates(state, 'checking');
  for (const service of services) {
    assert.equal(state[`${service}Label`]().key, 'app.string.transfer_protocol_refreshing');
    assert.equal(state[`${service}StatusState`](), 'checking');
  }
  assert.equal(state.servicesRefreshing(), false);
});

test('timeout and error describe incomplete checks rather than a missing service', () => {
  const state = fixture();
  for (const value of ['timeout', 'error']) {
    allStates(state, value);
    for (const service of services) {
      assert.equal(state[`${service}StatusState`](), value);
      assert.equal(state[`${service}Label`]().key, `app.string.device_detail_service_${value}`);
    }
  }
});

test('completed negative probes keep the existing unavailable result', () => {
  const state = fixture(); allStates(state, 'unavailable');
  for (const service of services) {
    assert.equal(state[`${service}StatusState`](), 'unavailable');
    assert.equal(state[`${service}Label`]().key, 'app.string.device_detail_service_unavailable');
  }
});

test('positive service results retain discovered media names and LocalSend availability', () => {
  const state = fixture(); state.sunshineState = 'available'; state.localSendAvailable = true;
  state.mediaProbeState = 'available'; state.mediaServiceCount = 1; state.mediaServiceNames = 'Jellyfin';
  for (const service of services) assert.equal(state[`${service}StatusState`](), 'available');
  assert.deepEqual(state.mediaLabel(), { key: 'app.string.device_detail_media_discovered', args: ['Jellyfin'] });
});

test('media with no usable service does not gain an available action from a positive raw state alone', () => {
  const state = fixture(); state.mediaProbeState = 'available';
  assert.equal(state.mediaStatusState(), 'unavailable');
  assert.equal(state.mediaLabel().key, 'app.string.device_detail_service_unavailable');
});

test('offline and disconnected states take precedence over pending or cached probe values', () => {
  const state = fixture(); allStates(state, 'available'); state.mediaServiceCount = 1;
  state.serviceRefreshVisible = true; state.meshConnected = false;
  for (const service of services) {
    assert.equal(state[`${service}StatusState`](), 'disconnected');
    assert.equal(state[`${service}Label`]().key, 'app.string.connection_disconnected');
  }
  state.online = false;
  for (const service of services) {
    assert.equal(state[`${service}StatusState`](), 'offline');
    assert.equal(state[`${service}Label`]().key, 'app.string.device_detail_device_offline');
  }
});

test('only the explicit shared refresh flag owns uniform service refreshing', () => {
  const state = fixture(); allStates(state, 'unavailable'); state.servicesChecking = true;
  for (const service of services) assert.equal(state[`${service}StatusState`](), 'unavailable');
  state.serviceRefreshVisible = true;
  for (const service of services) {
    assert.equal(state[`${service}StatusState`](), 'checking');
    assert.equal(state[`${service}Label`]().key, 'app.string.transfer_protocol_refreshing');
  }
});
