import assert from 'node:assert/strict';
import test from 'node:test';
import { loadEtsModules } from './helpers/ets-vm-loader.mjs';

function fixture() {
  const files = new Map(); let fd = 0; const descriptors = new Map(); const calls = [];
  const sandbox = { Date, Promise, setTimeout, connection: {}, nativeBridge: {
    backendPathDiagnosticAsync: async text => { calls.push(JSON.parse(text)); return JSON.stringify(envelope()); }
  }, fileIo: {
    OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
    accessSync: p => files.has(p), statSync: p => ({ size: Buffer.byteLength(files.get(p) ?? '') }),
    readTextSync: p => files.get(p), openSync: p => { descriptors.set(++fd, p); files.set(p, ''); return { fd }; },
    writeSync: (fd, text) => { files.set(descriptors.get(fd), text); return Buffer.byteLength(text); },
    closeSync: f => descriptors.delete(f.fd),
    renameSync: (from, to) => { files.set(to, files.get(from)); files.delete(from); },
    unlinkSync: p => files.delete(p)
  }};
  loadEtsModules(['services/AtomicFileStore', 'services/PathDiagnosticService'], sandbox, { Service: 'PathDiagnosticService' });
  return { service: sandbox.Service, files, calls, sandbox };
}
function envelope() {
  return { schema: 1, result: 'ok', buildSource: 'a'.repeat(64), core: '1.104.5', go: 'go1.27.3',
    exportedMs: Date.now(), trace: { schema: 1, session: 'b'.repeat(16), active: true,
      startedMs: Date.now(), deadlineMs: Date.now() + 180000, stoppedMs: 0, stopReason: 'pending', networkEpoch: 4,
      capacity: 1536, overwritten: 12, rateDropped: 13, contentionDropped: 14, invalidDropped: 15, sampledOut: 16,
      counters: [{kind:'pong',result:'unknown_txid',count:20}],
      events: [{ seq: 1, timestampMs: 100, elapsedMs: 1, networkEpoch: 4, socketEpoch: 2, kind: 'pong',
        result: 'unknown_txid', family: 6, peer: 'c'.repeat(24), endpoint: 'd'.repeat(24), tx: 'e'.repeat(24), errno: 0, n: [3] }],
      missing: ['kernel_egress_not_observed'] } };
}

test('export allowlist drops extra fields and preserves error/drop/counter metadata', () => {
  const { service } = fixture(); const e=envelope();
  e.token='Bearer canary';e.trace.ip='2001:db8::9';e.trace.events[0].payload='nodekey:canary';
  e.trace.events[0].node='10.0.0.1';e.trace.events[0].error='disco-key-canary';
  e.trace.counters[0].raw='192.168.1.1';e.trace.missing.push('token-canary');
  const text=service.sanitize(JSON.stringify(e));
  assert.doesNotMatch(text,/canary|2001:db8|10\.0\.0|192\.168|Bearer|nodekey/);
  const safe=JSON.parse(text);assert.equal(safe.trace.rateDropped,13);assert.equal(safe.trace.counters[0].count,20);
  assert.equal(safe.trace.events[0].result,'unknown_txid');assert.equal(safe.buildSource,'a'.repeat(64));
});
test('rejects IP/key/error text in typed fields and never returns partial JSON', () => {
  const { service }=fixture();
  for(const [field,value] of [['peer','nodekey:secret'],['endpoint','[2001:db8::1]:41641'],['tx','Bearer secret'],['kind','10.0.0.1'],['result','secret-error']]){
    const e=envelope();e.trace.events[0][field]=value;assert.throws(()=>service.sanitize(JSON.stringify(e)));
  }
  assert.throws(()=>service.sanitize(JSON.stringify(envelope()).slice(0,-1)));
  const e=envelope();e.trace.events=Array(1537).fill(e.trace.events[0]);assert.throws(()=>service.sanitize(JSON.stringify(e)));
  assert.throws(()=>service.sanitize(' '.repeat(1024*1024+1)));
});
test('missing/corrupt capture is explicit and export does not start native probes', () => {
  const {service,files,calls}=fixture();assert.match(service.exportSnapshot('/files'),/unavailable/);
  files.set('/files/path-diagnostic-trace.json','{"broken":');assert.match(service.exportSnapshot('/files'),/invalid/);
  files.set('/files/path-diagnostic-trace.json',JSON.stringify(envelope()));
  assert.equal(JSON.parse(service.exportSnapshot('/files')).trace.events.length,1);assert.equal(calls.length,0);
});
test('disabled polling makes no native calls; old/invalid IPC commands do not enable capture', async () => {
  const {service,files,calls}=fixture();service.poll('/files',-1);assert.equal(calls.length,0);
  files.set('/files/path-diagnostic-request.json',JSON.stringify({requestId:1,createdMs:Date.now()-20000,action:'start'}));
  service.poll('/files',2);await Promise.resolve();assert.equal(calls.length,0);
  files.set('/files/path-diagnostic-request.json',JSON.stringify({requestId:2,createdMs:Date.now(),action:'payload-secret'}));
  service.poll('/files',2);await Promise.resolve();assert.equal(calls.length,0);
});
test('shutdown stops native capture and atomically saves a valid bounded export',async()=>{
  const {service,files,calls}=fixture();await service.shutdown('/files');assert.equal(calls[0].action,'stop');
  assert.equal(JSON.parse(files.get('/files/path-diagnostic-trace.json')).schema,1);
  assert.equal([...files.keys()].filter(k=>k.endsWith('.tmp')).length,0);
});

test('protection fallback retains numeric errno without interface addresses in exported data',async()=>{
 const {service,calls,sandbox}=fixture();service.captureUntilMs=Date.now()+10000;
 sandbox.connection={NetBearType:{BEARER_CELLULAR:2,BEARER_WIFI:1},getDefaultNet:async()=>({netId:100}),getConnectionProperties:async()=>({interfaceName:'rmnet0',linkAddresses:[{address:{address:'2001:db8::1'}}]}),getNetCapabilities:async()=>({bearerTypes:[2]})};
 await service.recordHost(2,5,3,4,201,2203001);
 assert.equal(calls[0].protection,2);assert.equal(calls[0].protectionCode,2203001);assert.equal(calls[0].ipv6Count,1);
 assert.doesNotMatch(JSON.stringify(calls),/2001:db8/);
});
test('late host sampling cannot cross a capture boundary',async()=>{
 const {service,calls,sandbox}=fixture();service.captureUntilMs=Date.now()+10000;
 let resolve;sandbox.connection={getDefaultNet:()=>new Promise(r=>resolve=r)};
 const pending=service.recordHost(1,0,0,0);service.captureUntilMs=0;resolve({netId:0});await pending;assert.equal(calls.length,0);
});
test('stopped capture cannot be overwritten by an obsolete asynchronous snapshot',async()=>{
 const {service,files,sandbox}=fixture();let resolve;let first=true;
 sandbox.nativeBridge.backendPathDiagnosticAsync=async()=>{if(first){first=false;return await new Promise(r=>resolve=r)}const e=envelope();e.trace.active=false;e.trace.stopReason='stop';return JSON.stringify(e)};
 service.captureUntilMs=Date.now()+10000;service.nextSnapshotMs=0;service.poll('/files',1);
 await service.shutdown('/files');resolve(JSON.stringify(envelope()));for(let i=0;i<10;i++)await Promise.resolve();
 assert.equal(JSON.parse(files.get('/files/path-diagnostic-trace.json')).trace.stopReason,'stop');assert.equal(service.captureUntilMs,0);
});
test('trace persistence failures are reported honestly and stale exports are unavailable',async()=>{
 const {service,files,sandbox}=fixture();sandbox.fileIo.renameSync=()=>{throw new Error('private path secret')};
 await service.process('/files',1,0,{requestId:100,action:'snapshot'});assert.equal(files.has('/files/path-diagnostic-trace.json'),false);
 const e=envelope();e.exportedMs=Date.now()-25*60*60*1000;files.set('/files/path-diagnostic-trace.json',JSON.stringify(e));assert.match(service.exportSnapshot('/files'),/unavailable/);
});
