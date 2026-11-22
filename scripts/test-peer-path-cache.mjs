import assert from 'node:assert/strict';
import test from 'node:test';
import { loadEtsModules } from './helpers/ets-vm-loader.mjs';

function fixture() {
  const f = { now: 10000, calls: 0, type: 'derp' };
  const sandbox = { Date: { now: () => f.now } };
  loadEtsModules([
    'services/AtomicFileStore',
    'services/VpnExtensionRpcChannel',
    'services/PeerPathService'
  ], sandbox, { Service: 'PeerPathService' });
  f.service = new sandbox.Service({ filesDir: '/files' });
  f.service.requestThroughVpnExtension = async () => {
    f.calls++; return JSON.stringify({ state: 'reachable', reason: '', pathType: f.type });
  };
  return f;
}

test('a transient relay cache expires so a later direct response can replace it', async () => {
  const f = fixture(); assert.equal((await f.service.probe('peer', true)).type, 'derp');
  f.now += 2000; f.type = 'direct'; await f.service.probe('peer', true); assert.equal(f.calls, 1);
  f.now += 1001; assert.equal((await f.service.probe('peer', true)).type, 'direct'); assert.equal(f.calls, 2);
  f.now += 20000; await f.service.probe('peer', true); assert.equal(f.calls, 2);
});

test('disconnect overrides a previously cached direct path', async () => {
  const f = fixture(); f.type = 'direct'; await f.service.probe('peer', true);
  const result = await f.service.probe('peer', false);
  assert.equal(result.type, 'unknown'); assert.equal(result.errorMessage, 'mesh_disconnected');
});
