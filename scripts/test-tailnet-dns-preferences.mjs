import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
import { loadEtsModules } from './helpers/ets-vm-loader.mjs';
const read = path => readFileSync(new URL('../entry/src/main/ets/' + path + '.ets', import.meta.url), 'utf8');
function load(source, name, sandbox) {
  vm.runInNewContext(stripTypeScriptTypes(source.replace(/^import .*;\r?$/gm, '').replace(/^export /gm, '')) + `\nglobalThis.Loaded = ${name};`, sandbox);
  return sandbox.Loaded;
}
function fixture() {
  const f = { files: new Map(), handles: new Map(), next: 1, fail: '', closed: 0 };
  f.path = '/files/tailnet-dns-preferences-v1.json';
  const box = { fileIo: {
    OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
    accessSync: path => f.files.has(path),
    statSync: path => { if (!f.files.has(path)) throw Error('absent'); return { size: Buffer.byteLength(f.files.get(path)) }; },
    readTextSync: path => f.files.get(path),
    openSync: path => { if (f.fail === 'open') throw Error('disk'); const fd = f.next++; f.handles.set(fd, path); f.files.set(path, ''); return { fd }; },
    writeSync: (fd, value) => { f.files.set(f.handles.get(fd), value); return Buffer.byteLength(value) - (f.fail === 'short' ? 1 : 0); },
    fsyncSync: () => { if (f.fail === 'sync') throw Error('disk'); },
    closeSync: file => { f.closed++; f.handles.delete(file.fd); },
    renameSync: (from, to) => { if (f.fail === 'rename') throw Error('disk'); f.files.set(to, f.files.get(from)); f.files.delete(from); },
    unlinkSync: path => f.files.delete(path)
  } };
  loadEtsModules(['services/AtomicFileStore', 'services/TailnetDnsPreferences'], box, { Preference: 'TailnetDnsPreferences' });
  f.Preference = box.Preference;
  return f;
}
test('Tailnet DNS defaults on when absent but preserves disabled and rejects malformed preferences', () => {
  const f = fixture(); assert.equal(f.Preference.enabled('/files'), true);
  for (const text of ['broken', 'null', '{}', '{"schemaVersion":1,"enabled":"true"}', '{"schemaVersion":2,"enabled":true}', 'x'.repeat(1025)]) {
    f.files.set(f.path, text); assert.equal(f.Preference.enabled('/files'), false);
  }
});
test('persists only the independent opt-in and survives a reload', () => {
  const f = fixture(); assert.equal(f.Preference.save('/files', true), true);
  assert.equal(f.Preference.enabled('/files'), true);
  assert.deepEqual(JSON.parse(f.files.get(f.path)), { schemaVersion: 1, enabled: true });
  assert.equal(f.Preference.save('/files', false), true); assert.equal(f.Preference.enabled('/files'), false);
  assert.equal(f.files.size, 1); assert.equal(f.handles.size, 0);
});
for (const failure of ['open', 'short', 'sync', 'rename']) test('failed ' + failure + ' preserves the prior DNS preference', () => {
  const f = fixture(); f.Preference.save('/files', true); f.fail = failure;
  assert.equal(f.Preference.save('/files', false), false); assert.equal(f.Preference.enabled('/files'), true);
  assert.equal(f.files.has(f.path + '.tmp'), false); assert.equal(f.handles.size, 0);
  assert.equal([...f.files.keys()].some(k => k.endsWith('.tmp')), false);
});
test('connected, connecting, locked and detached UI cannot change the opt-in', () => {
  const source = read('components/BridgeStatus');
  const method = source.match(/^  private toggleTailnetDns\([\s\S]*?^  }/m)[0].replace('private ', 'function ');
  for (const blocked of ['connected', 'connecting', 'locked', 'authenticating', 'detached', 'signed-out']) {
    let writes = 0;
    const box = { TailnetDnsPreferences: { save() { writes++; return true; } }, $r: x => x };
    vm.runInNewContext(stripTypeScriptTypes(method), box);
    const owner = { appShellReady: blocked !== 'detached', remoteStreamAppInForeground: true, securityPreferencesReady: true, appLockRequired: blocked === 'locked',
      appLockAuthenticating: blocked === 'authenticating', tailnetDnsEnabled: false,
      isConnected: () => blocked === 'connected', isConnecting: () => blocked === 'connecting', isAuthenticated: () => blocked !== 'signed-out',
      getUIContext: () => ({ getHostContext: () => ({ filesDir: '/files' }) }), showToast() {} };
    box.toggleTailnetDns.call(owner); assert.equal(writes, 0); assert.equal(owner.tailnetDnsEnabled, false);
  }
});
test('an authenticated unlocked foreground UI commits the DNS option only after a successful durable save', () => {
  const source = read('components/BridgeStatus');
  const method = source.match(/^  private toggleTailnetDns\([\s\S]*?^  }/m)[0].replace('private ', 'function ');
  let saved = true, writes = 0, toasts = 0;
  const box = { TailnetDnsPreferences: { save() { writes++; return saved; } }, $r: x => x };
  vm.runInNewContext(stripTypeScriptTypes(method), box);
  const owner = { appShellReady: true, remoteStreamAppInForeground: true, securityPreferencesReady: true,
    appLockRequired: false, appLockAuthenticating: false, securitySettingsAuthenticating: false, tailnetDnsEnabled: false,
    isConnected: () => false, isConnecting: () => false, isAuthenticated: () => true,
    getUIContext: () => ({ getHostContext: () => ({ filesDir: '/files' }) }), showToast() { toasts++; } };
  box.toggleTailnetDns.call(owner); assert.equal(owner.tailnetDnsEnabled, true); assert.equal(writes, 1);
  saved = false; box.toggleTailnetDns.call(owner); assert.equal(owner.tailnetDnsEnabled, true); assert.equal(toasts, 1);
  for (const state of ['remoteStreamAppInForeground','securityPreferencesReady']) {
    const before = writes; owner[state] = false; box.toggleTailnetDns.call(owner); assert.equal(writes, before); owner[state] = true;
  }
});
test('physical DNS sampling rejects changing, missing and oversized networks, preserves empty DHCP and never uses Quad100 as base', async () => {
  for (const mode of ['stable', 'empty', 'changed', 'offline', 'oversized']) {
    let reads = 0;
    const Service = load(read('services/PhysicalDnsService'), 'PhysicalDnsService', { connection: {
      getDefaultNet: async () => ({ netId: mode === 'offline' ? 0 : mode === 'changed' && ++reads > 1 ? 2 : 1 }),
      getConnectionProperties: async () => ({ dnses: mode === 'empty' ? [] :
        mode === 'oversized' ? Array.from({ length: 65 }, (_, i) => ({ address: `198.51.100.${i}` })) :
        [{ address: '100.100.100.100' }, { address: '192.0.2.53' }, { address: '192.0.2.53' }] })
    } });
    if (mode === 'stable') assert.deepEqual(JSON.parse(JSON.stringify(await Service.read())), { networkId: 1, resolvers: ['192.0.2.53'] });
    else if (mode === 'empty') assert.deepEqual(JSON.parse(JSON.stringify(await Service.read())), { networkId: 1, resolvers: [] });
    else await assert.rejects(Service.read());
  }
});
