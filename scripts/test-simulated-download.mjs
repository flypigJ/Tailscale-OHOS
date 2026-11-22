import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const source = readFileSync(new URL('../entry/src/main/ets/services/SimulatedDownload.ets', import.meta.url), 'utf8');
const js = stripTypeScriptTypes(source.replace(/^import .*;\r?$/gm, '').replace('export class SimulatedDownload', 'class SimulatedDownload'));
const flush = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };

function fixture(dynamicPort = false) {
  const f = { serverEvents: new Map(), receiverEvents: new Map(), senderEvents: new Map(), timers: new Map(),
    next: 0, closes: [], progress: [], failures: [], sends: 0, addresses: [], gate: null, failSend: false };
  const sender = {
    on: (name, cb) => f.senderEvents.set(name, cb), off: name => f.senderEvents.delete(name),
    close: async () => f.closes.push('sender'),
    send: async ({ data }) => {
      f.sends++; if (f.gate) await f.gate;
      if (f.failSend) throw { code: 2300055 };
      f.receiverEvents.get('message')?.({ message: data });
    }
  };
  const receiver = {
    on: (name, cb) => f.receiverEvents.set(name, cb), off: name => f.receiverEvents.delete(name),
    bind: async address => f.addresses.push(address),
    connect: async ({ address }) => { f.addresses.push(address); f.serverEvents.get('connect')(sender); },
    close: async () => f.closes.push('receiver')
  };
  const server = {
    on: (name, cb) => f.serverEvents.set(name, cb), off: name => f.serverEvents.delete(name),
    listen: async address => f.addresses.push(address), close: async () => f.closes.push('server')
  };
  if (dynamicPort) {
    server.getLocalAddress = async () => ({ address: '127.0.0.1', port: 51234, family: 1 });
  }
  const box = {
    socket: { constructTCPSocketServerInstance: () => server, constructTCPSocketInstance: () => receiver },
    setInterval: cb => { const id = ++f.next; f.timers.set(id, cb); return id; },
    clearInterval: id => f.timers.delete(id)
  };
  vm.runInNewContext(js + '\nglobalThis.Download = SimulatedDownload;', box);
  f.download = new box.Download();
  f.start = () => f.download.start(bytes => f.progress.push(bytes), code => f.failures.push(code));
  f.tick = async () => { for (const cb of f.timers.values()) cb(); await flush(); };
  return f;
}

test('the stream binds exclusively to loopback and counts actual received payload bytes', async () => {
  const f = fixture(); await f.start();
  assert.ok(f.addresses.every(address => address.address === '127.0.0.1'));
  await f.tick(); await f.tick(); assert.deepEqual(f.progress, [4096, 8192]);
});

test('backpressure prevents overlapping writes and retains only one fixed-size payload', async () => {
  const f = fixture(); await f.start(); let resolve;
  f.gate = new Promise(r => { resolve = r; }); await f.tick(); await f.tick();
  assert.equal(f.sends, 1); resolve(); await flush();
  assert.deepEqual(f.progress, [4096]);
});

test('stop removes timers and listeners and closes all three socket owners', async () => {
  const f = fixture(); await f.start(); await f.download.stop();
  assert.equal(f.timers.size, 0); assert.equal(f.serverEvents.size, 0);
  assert.equal(f.receiverEvents.size, 0); assert.equal(f.senderEvents.size, 0);
  assert.deepEqual(f.closes, ['receiver', 'sender', 'server']);
});

test('late network failures after stop do not restart or report a new active-session error', async () => {
  const f = fixture(); await f.start(); let resolve;
  f.gate = new Promise(r => { resolve = r; }); f.failSend = true;
  await f.tick(); await f.download.stop(); resolve(); await flush();
  assert.deepEqual(f.failures, []); assert.equal(f.timers.size, 0);
});

test('a local port connection from a second client is closed without replacing the owned sender', async () => {
  const f = fixture(); await f.start(); let closed = false;
  f.serverEvents.get('connect')({ close: async () => { closed = true; } }); await flush();
  assert.equal(closed, true); await f.tick(); assert.deepEqual(f.progress, [4096]);
});

test('active stream errors report only the numeric code', async () => {
  const f = fixture(); await f.start(); f.failSend = true; await f.tick();
  assert.deepEqual(f.failures, [2300055]);
});


test('uses ephemeral local port when TCPSocketServer.getLocalAddress is available', async () => {
  const f = fixture(true);
  await f.start();
  assert.equal(f.addresses[0].port, 0);
  assert.equal(f.addresses[2].port, 51234);
  await f.download.stop();
});
