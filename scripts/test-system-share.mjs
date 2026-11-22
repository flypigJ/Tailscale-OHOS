import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const source = readFileSync(new URL('../entry/src/main/ets/services/SystemShareInbox.ets', import.meta.url), 'utf8');
const bridgeSource = readFileSync(new URL('../entry/src/main/ets/components/BridgeStatus.ets', import.meta.url), 'utf8');
const flush = () => new Promise(resolve => setImmediate(resolve));

function fixture(getSharedData) {
  const state = new Map();
  const sandbox = {
    systemShare: { getSharedData },
    AppStorage: {
      get: key => state.get(key),
      setOrCreate: (key, value) => state.set(key, value)
    }
  };
  vm.runInNewContext(
    stripTypeScriptTypes(source.replace(/^import .*;\r?$/gm, '').replace(/^export /gm, '')) +
      '\nthis.Inbox = SystemShareInbox;',
    sandbox
  );
  return { Inbox: sandbox.Inbox, state };
}

test('unresolved provider parsing is included in the five-share admission limit', async () => {
  let resolve;
  const gate = new Promise(r => { resolve = r; });
  let parsed = 0;
  const { Inbox, state } = fixture(async () => {
    parsed++;
    await gate;
    return { getRecords: () => [{ uri: 'file://media/Photo/1' }] };
  });
  for (let i = 0; i < 1000; i++) Inbox.receive({ action: 'ohos.want.action.sendData' });
  await flush();
  assert.equal(parsed, 1);
  assert.ok(state.get('systemShareError'));
  resolve();
  await flush();
  assert.equal(parsed, 5);
  for (let i = 0; i < 5; i++) Inbox.remove(Inbox.first().id);
  Inbox.receive({ action: 'ohos.want.action.sendData' });
  await flush();
  assert.equal(parsed, 6);
});

test('share URI validation rejects private paths, authority tricks, remote query params, and oversized batches', () => {
  const { Inbox } = fixture();
  const rejectedUris = [
    '/data/private',
    'https://host/file',
    'file:///data/private',
    'file://io.github.tailscaleohos/data/storage/el2/base/files/key',
    'file://io.github.tailscaleohos:/Photo/1',
    'file://io.github.tailscaleohos:8080/Photo/1',
    'file://sub.io.github.tailscaleohos/Photo/1',
    'file://io.github.tailscaleohos.evil/Photo/1',
    'file://%69o.github.tailscaleohos/private',
    'file://user@media/Photo/1',
    'file://localhost/Photo/1',
    'file://127.0.0.1/Photo/1',
    'file://[::1]/Photo/1',
    'file://media/Photo/1?networkid=remote-device-123',
    'file://media/Photo/1#fragment',
    'file://media/Photo/1\n',
    'file://media/Photo/invoice\u202Efdp.scr',
    'file://docs/path/%2e%2e/private',
    'file://docs/path/%252e%252e/private',
    'file://media/Photo/%00',
    'file://docs/data/storage/el2/base/files/secret.json',
    'file://docs/data/app/el2/100/base/files/secret.json',
    'file://docs/data/service/el1/public/secret',
    'file://docs/backup/tailscaled.state'
  ];
  for (const uri of rejectedUris) {
    assert.throws(() => Inbox.fileUris([{ uri }]), `expected rejection for ${uri}`);
  }
  assert.throws(() => Inbox.fileUris([]));
  assert.throws(() => Inbox.fileUris(Array(101).fill({ uri: 'file://media/Photo/1' })));

  // Legitimate HarmonyOS provider URIs (including percent-encoded '%' in real filenames) pass and deduplicate.
  const valid = Inbox.fileUris([
    { uri: 'file://media/Photo/1/IMG_001.jpg' },
    { uri: 'file://media/Photo/1/IMG_001.jpg' },
    { uri: 'file://com.huawei.hmos.photos/Photo/2/100%25%20tax.pdf' }
  ]);
  assert.deepEqual(Array.from(valid), [
    'file://media/Photo/1/IMG_001.jpg',
    'file://com.huawei.hmos.photos/Photo/2/100%25%20tax.pdf'
  ]);
});

test('summarizeFileNames formats sanitized basenames and SystemSharePanel binds pure state', () => {
  const { Inbox } = fixture();
  assert.equal(Inbox.summarizeFileNames(undefined), '');
  assert.equal(Inbox.summarizeFileNames({ id: 1, uris: [] }), '');
  assert.equal(
    Inbox.summarizeFileNames({
      id: 2,
      uris: [
        'file://media/Photo/12/IMG_2026.JPG',
        'file://docs/storage/Users/currentUser/100%25%20report.pdf'
      ]
    }),
    'IMG_2026.JPG, 100% report.pdf'
  );
  assert.equal(
    Inbox.summarizeFileNames({
      id: 3,
      uris: [
        'file://docs/share/invoice%E2%80%AEfdp.scr',
        'file://media/b.png',
        'file://media/c.png',
        'file://media/d.png',
        'file://media/e.png'
      ]
    }),
    'invoicefdp.scr, b.png, c.png (+2)'
  );
  assert.match(bridgeSource, /this\.sharedFileSummary\s*=\s*typeof SystemShareInbox\.summarizeFileNames/);
  assert.match(bridgeSource, /\.id\('system-share-file-names'\)/);
});

test('cold and warm shares remain ordered, removing one draft preserves the next, parse failure recovers', async () => {
  let resolveFirst;
  const first = new Promise(resolve => { resolveFirst = resolve; });
  const { Inbox, state } = fixture(async want => {
    if (want.n === 1) await first;
    if (want.n === 3) throw Error('expired grant');
    return { getRecords: () => [{ uri: `file://media/Photo/${want.n}` }] };
  });
  for (const n of [1, 2, 3, 4]) Inbox.receive({ action: 'ohos.want.action.sendData', n });
  await flush();
  assert.equal(Inbox.first(), undefined);
  resolveFirst();
  await flush();
  assert.equal(Inbox.first().uris[0], 'file://media/Photo/1');
  Inbox.remove(Inbox.first().id);
  assert.equal(Inbox.first().uris[0], 'file://media/Photo/2');
  Inbox.remove(Inbox.first().id);
  assert.equal(Inbox.first().uris[0], 'file://media/Photo/4');
  assert.ok(state.get('systemShareError') > 0);
});
