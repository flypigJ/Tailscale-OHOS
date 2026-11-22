import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';
import { loadEtsModules } from './helpers/ets-vm-loader.mjs';

test('Sunshine requests dispatch while the slow backend snapshot remains pending', () => {
  const source = readFileSync(new URL('../entry/src/main/ets/vpnextensionability/TailscaleVpnExtensionAbility.ets', import.meta.url), 'utf8');
  const method = source.match(/^  private startStatusUpdates\([\s\S]*?^  }/m)[0]
    .replace('private startStatusUpdates', 'function startStatusUpdates');
  const timers = new Map(), calls = [];
  const context = vm.createContext({
    setInterval(callback, delay) { timers.set(delay, callback); return delay; }, clearInterval() {},
    PathDiagnosticService: { resume() {}, poll() {} },
    nativeBridge: { backendSnapshot: () => { calls.push('snapshot'); return new Promise(() => {}); } }
  });
  vm.runInContext(stripTypeScriptTypes(method), context);
  const state = new Proxy({ statusTimer: -1, taildropRequestTimer: -1, taildropIncomingTimer: -1,
    destroying: false, backendStopInFlight: false, explicitStopRequested: false, dnsRebuildInFlight: false,
    statusUpdateInFlight: false, context: { filesDir: '/fixture' },
    dnsObserver: { start() {}, refresh() {} }, processBackendStopRequest: () => false,
    processSunshineProbeRequest: () => calls.push('sunshine')
  }, { get: (target, key) => key in target ? target[key] : () => {} });
  context.startStatusUpdates.call(state);
  timers.get(1000)(); assert.equal(state.statusUpdateInFlight, true);
  timers.get(100)(); assert.deepEqual(calls, ['snapshot', 'sunshine']);
  state.dnsRebuildInFlight = true; timers.get(100)();
  assert.deepEqual(calls, ['snapshot', 'sunshine']);
});

test('a partially written Sunshine IPC response is retried within its deadline', async () => {
  const files = new Map(); let time = 0, polls = 0;
  const context = vm.createContext({ Date,
    systemDateTime: { TimeType: { STARTUP: 0 }, getUptime: () => time },
    fileIo: {
      OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
      openSync: path => { files.set(path, ''); return { fd: path }; },
      writeSync: (path, value) => {
        const str = String(value);
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
      time += delay; polls++;
      files.set('/fixture/sunshine-probe-response.json', polls === 1 ? '{"requestId":' :
        JSON.stringify({ requestId: 42, result: '{"state":"available"}' }));
      resolve();
    }
  });
  loadEtsModules([
    'services/AtomicFileStore',
    'services/VpnExtensionRpcChannel',
    'services/SunshineProbeService'
  ], context, { Service: 'SunshineProbeService' });
  const service = new context.Service({ filesDir: '/fixture' });
  assert.equal(await service.requestThroughVpnExtension('peer', 42), '{"state":"available"}');
  assert.equal(polls, 2);
});
