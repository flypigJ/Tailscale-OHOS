import assert from 'node:assert/strict';
import test from 'node:test';
import { loadEtsModules } from './helpers/ets-vm-loader.mjs';

const services = [
  ['SunshineProbeService', 3500, 'sunshine-probe-response.json'],
  ['MediaServiceProbeService', 4000, 'media-service-probe-response.json'],
  ['PeerPathService', 12000, 'peer-connectivity-response.json']
];
function fixture(name, budget, responseFile, onPoll = () => {}) {
  let wall = 100000, uptime = 5000, polls = 0;
  const files = new Map(), clockReads = [];
  const f = { get polls() { return polls; }, get elapsed() { return uptime - 5000; },
    wall(value) { wall = value; }, advance(value) { uptime += value; },
    reply(requestId = 777) { files.set('/synthetic-files/' + responseFile, JSON.stringify({ requestId, result: 'synthetic-result' })); },
    clockFails: false };
  const sandbox = {
    Date: { now: () => wall },
    systemDateTime: { TimeType: { STARTUP: 0, ACTIVE: 1 }, getUptime(type, nano) {
      clockReads.push([type, nano]); if (f.clockFails) throw new Error('clock unavailable'); return uptime;
    } },
    fileIo: {
      OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
      openSync: path => { files.set(path, ''); return { fd: path }; },
      writeSync: (path, text) => {
        const str = String(text);
        files.set(path, str);
        return Buffer.byteLength(str, 'utf8');
      },
      fsyncSync() {},
      closeSync() {},
      renameSync: (from, to) => { files.set(to, files.get(from)); files.delete(from); },
      unlinkSync: path => files.delete(path),
      statSync: path => {
        if (!files.has(path)) throw new Error('ENOENT');
        return { size: Buffer.byteLength(files.get(path), 'utf8') };
      },
      accessSync: path => files.has(path),
      readTextSync: path => files.get(path)
    },
    setTimeout(resolve, delay) {
      assert.equal(delay, 150); polls++; uptime += delay; onPoll(f, polls);
      // Safely terminate a broken wall-clock baseline without hanging the test runner.
      if (polls > 100) wall = 100000 + budget + 1;
      resolve();
    }
  };
  loadEtsModules([
    'services/AtomicFileStore',
    'services/VpnExtensionRpcChannel',
    `services/${name}`
  ], sandbox, { Service: name });
  const service = new sandbox.Service({ filesDir: '/synthetic-files' });
  return { ...f, state: f, files, clockReads, run: () => service.requestThroughVpnExtension('one', 777) };
}

for (const [name, budget, response] of services) {
  for (const direction of ['backward', 'forward']) test(`${name}: ${direction} wall-clock change keeps the original elapsed timeout budget`, async () => {
    const f = fixture(name, budget, response, (state, count) => {
      if (count === 1) state.wall(direction === 'backward' ? -1000000 : 1000000);
    });
    const result = JSON.parse(await f.run());
    assert.equal(result.errorMessage ?? result.reason, 'timeout');
    assert.equal(f.state.polls, Math.ceil(budget / 150));
    assert.ok(f.state.elapsed >= budget && f.state.elapsed < budget + 150);
  });

  test(`${name}: a timely matching response survives a forward wall-clock jump`, async () => {
    const f = fixture(name, budget, response, (state, count) => {
      if (count === 1) state.wall(1000000); if (count === 2) state.reply();
    });
    assert.equal(await f.run(), 'synthetic-result'); assert.equal(f.state.polls, 2);
    assert.equal(f.files.get('/synthetic-files/' + response), '');
  });

  test(`${name}: a response first observed after the deadline is rejected`, async () => {
    const f = fixture(name, budget, response, (state, count) => {
      if (count === Math.ceil(budget / 150)) state.reply();
    });
    const result = JSON.parse(await f.run()); assert.equal(result.errorMessage ?? result.reason, 'timeout');
  });

  test(`${name}: a response in the final sample before the deadline is accepted`, async () => {
    const count = Math.floor((budget - 1) / 150);
    const f = fixture(name, budget, response, (state, current) => { if (current === count) state.reply(); });
    assert.equal(await f.run(), 'synthetic-result'); assert.equal(f.state.polls, count);
  });

  test(`${name}: an elapsed sleep jump expires before consuming a late response`, async () => {
    const f = fixture(name, budget, response, (state, count) => {
      if (count === 1) { state.advance(budget * 2); state.reply(); }
    });
    const result = JSON.parse(await f.run()); assert.equal(result.errorMessage ?? result.reason, 'timeout');
    assert.equal(f.state.polls, 1);
  });

  test(`${name}: a stale request ID does not consume the response or reset the budget`, async () => {
    const f = fixture(name, budget, response, (state, count) => { if (count === 1) state.reply(666); });
    const result = JSON.parse(await f.run()); assert.equal(result.errorMessage ?? result.reason, 'timeout');
    assert.equal(f.state.polls, Math.ceil(budget / 150));
  });

  test(`${name}: uptime is read as STARTUP milliseconds and failure stays bounded`, async () => {
    const f = fixture(name, budget, response); f.state.clockFails = true;
    const result = JSON.parse(await f.run()); assert.equal(result.errorMessage ?? result.reason, 'extension_error');
    assert.equal(f.state.polls, 0); assert.deepEqual(f.clockReads, [[0, false]]);
  });
}
