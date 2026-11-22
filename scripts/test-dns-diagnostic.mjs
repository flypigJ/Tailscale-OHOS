import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
const source = readFileSync(new URL('../entry/src/main/ets/vpnextensionability/TailscaleVpnExtensionAbility.ets', import.meta.url), 'utf8');
const method = source.match(/^  private async processDnsDiagnosticRequest\([\s\S]*?^  }/m)[0].replace('private async ', 'async function ');
function fixture() {
  const f = { debug: true, files: new Map(), calls: [], now: 20000 };
  const box = { BuildProfile: { get DEBUG() { return f.debug; } }, Date: { now: () => f.now },
    fileIo: { accessSync: p => f.files.has(p), statSync: p => ({ size: f.files.get(p).length }), readTextSync: p => f.files.get(p) },
    nativeBridge: { backendDnsRuntimeAsync: async text => { f.calls.push(JSON.parse(text)); return f.gate ?? '{"state":"complete"}'; } } };
  vm.runInNewContext(stripTypeScriptTypes(method), box);
  f.owner = { context: { filesDir: '/files' }, dnsDiagnosticInFlight: false, lastDnsDiagnosticRequest: 0,
    destroying: false, backendStopInFlight: false, explicitStopRequested: false,
    writeTextFile: (p,t) => f.files.set(p,t), writeAtomicTextFile: (p,t) => f.files.set(p,t) };
  f.request = override => f.files.set('/files/dns-diagnostic-request.json', JSON.stringify({ requestId: 1, createdMs: f.now, peerKey: 'peer-'+'a'.repeat(16), ...override }));
  f.poll = () => box.processDnsDiagnosticRequest.call(f.owner);
  return f;
}
test('Release and absent requests never query DNS', async () => {
  const f = fixture(); await f.poll(); f.request(); f.debug = false; await f.poll(); assert.equal(f.calls.length, 0);
});
test('only an explicit fresh known-peer-shaped request can invoke the diagnostic', async () => {
  const f = fixture(); f.request(); await f.poll();
  assert.deepEqual(f.calls, [{ operation: 'diagnose', peerKey: 'peer-'+'a'.repeat(16) }]);
  assert.equal(JSON.parse(f.files.get('/files/dns-diagnostic-response.json')).requestId, 1);
  f.request(); await f.poll(); assert.equal(f.calls.length, 1);
});
test('stale, future, invalid and oversized diagnostic requests are ignored', async () => {
  for (const update of [{ createdMs: 1 }, { createdMs: 30000 }, { requestId: 0 }, { peerKey: 'private.test' }, { peerKey: 'x'.repeat(3000) }]) {
    const f = fixture(); f.request(update); await f.poll(); assert.equal(f.calls.length, 0);
  }
});
test('a stopped owner cannot publish a diagnostic completed late', async () => {
  const f = fixture(); let resolve; f.gate = new Promise(r => { resolve = r; }); f.request();
  const pending = f.poll(); await Promise.resolve(); f.owner.explicitStopRequested = true;
  resolve('{"state":"complete"}'); await pending;
  assert.equal(f.files.has('/files/dns-diagnostic-response.json'), false); assert.equal(f.owner.dnsDiagnosticInFlight, false);
});
