import assert from 'node:assert/strict';
import test from 'node:test';
import { loadEtsModules } from './helpers/ets-vm-loader.mjs';

const sandbox = {};
loadEtsModules('services/TaildriveGateway', sandbox, { Gateway: 'TaildriveGateway' });
const gateway = new sandbox.Gateway();
const entry = { name: '照片.jpg', path: '/share/photo.jpg', kind: 'file', size: 14, modifiedAtMs: 1 };

for (const method of ['parseList', 'parseStat', 'parseMutation', 'parseTransfer']) {
  test(`${method} rejects JSON primitives, null, arrays and missing fields`, () => {
    for (const text of ['null', '42', 'true', '"text"', '[]', '{}', '{']) {
      const result = gateway[method](text);
      assert.equal(result?.state, 'failed', text);
      assert.equal(result.reason, 'invalid_result', text);
    }
  });
}

test('invalid remote entries cannot reach file row rendering', () => {
  for (const item of [null, {}, { ...entry, name: 42 }, { ...entry, size: 'huge' }, { ...entry, contentType: {} }]) {
    const result = gateway.parseList(JSON.stringify({ state: 'ready', path: '/', entries: [item] }));
    assert.equal(result.state, 'failed');
    assert.equal(result.entries.length, 0);
  }
});

test('valid Go responses retain data and tolerate omitempty fields and nil slices', () => {
  const list = gateway.parseList(JSON.stringify({ state: 'ready', path: '/share', entries: [entry] }));
  assert.equal(list.state, 'ready');
  assert.equal(list.entries[0].name, entry.name);
  assert.equal(list.reason, '');
  const failed = gateway.parseList('{"state":"failed","path":"/","entries":null,"reason":"invalid_request"}');
  assert.equal(failed.reason, 'invalid_request');
  assert.equal(failed.entries.length, 0);
  assert.equal(gateway.parseStat(JSON.stringify({ state: 'ready', entry })).entry.path, entry.path);
  assert.equal(gateway.parseMutation('{"state":"ready","operation":"mkdir","path":"/new"}').newPath, '');
  const transfer = { requestId: 1, direction: 'download', state: 'completed', reason: '', remotePath: '/a',
    localPath: '/private/a', fileName: 'a', bytes: 4, totalBytes: 4, startedAtMs: 1, completedAtMs: 2 };
  assert.equal(gateway.parseTransfer(JSON.stringify(transfer)).bytes, 4);
  assert.equal(gateway.parseTransfer(JSON.stringify({ ...transfer, bytes: '4' })).reason, 'invalid_result');
});
