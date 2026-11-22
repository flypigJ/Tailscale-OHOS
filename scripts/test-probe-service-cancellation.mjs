import assert from 'node:assert/strict';
import test from 'node:test';
import { loadEtsModules } from './helpers/ets-vm-loader.mjs';

const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
const services = ['SunshineProbeService', 'MediaServiceProbeService', 'PeerPathService'];
function fixture(name) {
  let now = 10000;
  const sandbox = { Date: { now: () => now } };
  loadEtsModules([
    'services/AtomicFileStore',
    'services/VpnExtensionRpcChannel',
    `services/${name}`
  ], sandbox, { Service: name });
  const service = new sandbox.Service({ filesDir: '/synthetic-files' }), calls = [];
  service.requestThroughVpnExtension = (peer, requestId) => {
    let resolve, reject;
    const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
    calls.push({ peer, requestId, resolve, reject }); return promise;
  };
  const probe = (peer = 'one', connected = true, force = false) => name === 'SunshineProbeService' ?
    service.probe(peer, '100.64.0.1', connected, force) : service.probe(peer, connected, force);
  const complete = async call => {
    assert.ok(call, 'a current RPC must exist');
    call.resolve(JSON.stringify(name === 'PeerPathService' ?
      { state: 'reachable', pathType: 'direct', reason: '' } : { state: 'available', checkedAt: now, services: [] }));
    await flush();
  };
  return { service, calls, probe, complete, clock(value) { now = value; } };
}

for (const name of services) {
  test(`${name}: cancel retires queued work before any RPC or cache hit`, async () => {
    const f = fixture(name), active = f.probe('one', true, true), queued = f.probe('two', true, true);
    await flush(); assert.equal(f.calls.length, 1);
    f.service.cancel('two'); await f.complete(f.calls[0]); await active; await flush();
    const dispatched = f.calls.filter(call => call.peer === 'two');
    // Complete an incorrectly dispatched baseline job so the assertion cannot leave a pending test.
    if (dispatched[0]) await f.complete(dispatched[0]);
    const result = await queued;
    assert.equal(dispatched.length, 0); assert.equal(result.errorMessage, 'cancelled');
    assert.equal(f.service.cache.has('two'), false);
  });

  test(`${name}: clearCache retires active work and prevents late cache refill`, async () => {
    const f = fixture(name), work = f.probe('one', true, true); await flush();
    f.service.clearCache('one'); await f.complete(f.calls[0]); const result = await work;
    assert.equal(result.errorMessage, 'cancelled'); assert.equal(f.service.cache.has('one'), false);
  });

  test(`${name}: clearing all cache also retires work still queued for another peer`, async () => {
    const f = fixture(name), active = f.probe('one', true, true), queued = f.probe('two', true, true); await flush();
    f.service.clearCache(); await f.complete(f.calls[0]); await active; await flush();
    const unexpected = f.calls.find(call => call.peer === 'two'); if (unexpected) await f.complete(unexpected);
    const result = await queued;
    assert.equal(f.calls.length, 1); assert.equal(result.errorMessage, 'cancelled'); assert.equal(f.service.cache.size, 0);
  });

  test(`${name}: disconnect overrides warm cache and evicts it`, async () => {
    const f = fixture(name), warm = f.probe(); await flush(); await f.complete(f.calls[0]); await warm;
    const result = await f.probe('one', false);
    assert.equal(result.state ?? result.type, 'unknown'); assert.equal(result.errorMessage, 'mesh_disconnected');
    assert.equal(f.service.cache.has('one'), false); assert.equal(f.calls.length, 1);
  });

  test(`${name}: clock rollback cannot turn future cache into a valid hit`, async () => {
    const f = fixture(name), warm = f.probe(); await flush(); await f.complete(f.calls[0]); await warm;
    f.clock(9000); const next = f.probe(); await flush();
    if (f.calls[1]) await f.complete(f.calls[1]); await next;
    assert.equal(f.calls.length, 2);
  });

  test(`${name}: extension request IDs stay positive and increasing across repeated or backward clocks`, async () => {
    const f = fixture(name);
    for (const time of [10000, 10000, 9000, -10]) {
      f.clock(time); const work = f.probe('one', true, true); await flush();
      await f.complete(f.calls[f.calls.length - 1]); await work;
    }
    const ids = f.calls.map(call => call.requestId);
    assert.ok(ids.every((id, index) => id > 0 && (index === 0 || id > ids[index - 1])));
  });

  test(`${name}: normal queued requests preserve FIFO and do not cancel one another`, async () => {
    const f = fixture(name), first = f.probe('one', true, true), second = f.probe('one', true, true); await flush();
    assert.equal(f.calls.length, 1); await f.complete(f.calls[0]);
    const a = await first; await flush(); assert.equal(f.calls.length, 2);
    await f.complete(f.calls[1]); const b = await second;
    assert.equal(a.errorMessage, undefined); assert.equal(b.errorMessage, undefined);
  });

  test(`${name}: cancelling one peer leaves other queued peers and later new work valid`, async () => {
    const f = fixture(name), active = f.probe('one', true, true), other = f.probe('two', true, true); await flush();
    f.service.cancel('one'); const latest = f.probe('one', true, true);
    await f.complete(f.calls[0]); assert.equal((await active).errorMessage, 'cancelled');
    await flush(); await f.complete(f.calls[1]); assert.equal((await other).errorMessage, undefined);
    await flush(); await f.complete(f.calls[2]); assert.equal((await latest).errorMessage, undefined);
    assert.deepEqual(f.calls.map(call => call.peer), ['one', 'two', 'one']);
  });

  test(`${name}: a cancelled queued request cannot return an earlier warm cache`, async () => {
    const f = fixture(name), warm = f.probe('two'); await flush(); await f.complete(f.calls[0]); await warm;
    const active = f.probe('one', true, true), queued = f.probe('two'); await flush();
    f.service.cancel('two'); await f.complete(f.calls[1]); await active;
    assert.equal((await queued).errorMessage, 'cancelled'); assert.equal(f.calls.length, 2);
  });

  test(`${name}: single-peer cache invalidation does not cancel another active peer`, async () => {
    const f = fixture(name), active = f.probe('one', true, true), queued = f.probe('two', true, true); await flush();
    f.service.clearCache('two'); await f.complete(f.calls[0]);
    assert.equal((await active).errorMessage, undefined);
    assert.equal((await queued).errorMessage, 'cancelled');
    assert.equal(f.service.cache.has('one'), true); assert.equal(f.service.cache.has('two'), false);
  });

  test(`${name}: new work after clearing active work cannot inherit its late result`, async () => {
    const f = fixture(name), old = f.probe('one', true, true); await flush(); f.service.clearCache('one');
    const fresh = f.probe('one'); await f.complete(f.calls[0]);
    assert.equal((await old).errorMessage, 'cancelled'); await flush();
    assert.equal(f.calls.length, 2); await f.complete(f.calls[1]); assert.equal((await fresh).errorMessage, undefined);
    assert.equal(f.service.cache.has('one'), true);
  });

  test(`${name}: queued non-forced requests still reuse a newly populated cache`, async () => {
    const f = fixture(name), first = f.probe(), second = f.probe(); await flush();
    await f.complete(f.calls[0]); const a = await first, b = await second;
    assert.equal(f.calls.length, 1); assert.deepEqual(a, b);
  });

  test(`${name}: original positive and negative TTL boundaries remain unchanged`, async () => {
    for (const positive of [true, false]) {
      const f = fixture(name), work = f.probe(); await flush();
      const ttl = name === 'SunshineProbeService' ? (positive ? 60000 : 25000) :
        name === 'MediaServiceProbeService' ? (positive ? 300000 : 60000) : (positive ? 25000 : 3000);
      if (positive) await f.complete(f.calls[0]);
      else {
        f.calls[0].resolve(JSON.stringify(name === 'PeerPathService' ?
          { state: 'failed', reason: 'no_response' } : { state: 'unavailable', checkedAt: 10000, services: [] }));
        await flush();
      }
      await work; f.clock(10000 + ttl - 1); await f.probe(); assert.equal(f.calls.length, 1);
      f.clock(10000 + ttl); const next = f.probe(); await flush(); assert.equal(f.calls.length, 2);
      await f.complete(f.calls[1]); await next;
    }
  });

  test(`${name}: a rejected transport still releases the FIFO for the next peer`, async () => {
    const f = fixture(name), first = f.probe('one', true, true), second = f.probe('two', true, true);
    const rejected = assert.rejects(first, /transport rejected/); await flush();
    f.calls[0].reject(new Error('transport rejected')); await rejected; await flush();
    assert.equal(f.calls.length, 2); await f.complete(f.calls[1]); assert.equal((await second).errorMessage, undefined);
  });
}
