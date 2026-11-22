import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import test from 'node:test';
const { verifyEngineInputs, checkedPath } = createRequire(import.meta.url)('./verify-engine-inputs.cjs');
test('manifest paths cannot escape the selected source root', () => {
  for (const name of ['../secret', 'foo/../../secret', path.resolve('secret')]) assert.throws(() => checkedPath('fixture', name), /Unsafe/);
});
test('wrong version pairs and changed locked inputs are rejected before compiler execution', t => {
  const root = mkdtempSync(path.join(tmpdir(), 'mesharc-engine-gate-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(path.join(root, 'native'));
  const lock = path.join(root, 'native/engine-lock.json');
  writeFileSync(lock, JSON.stringify({schemaVersion: 1, engineVersion: '1.86.5', goVersion: 'go1.27.3'}));
  assert.throws(() => verifyEngineInputs(root), /Unexpected engine version pair/);
  writeFileSync(path.join(root, 'source.txt'), 'changed');
  writeFileSync(lock, JSON.stringify({schemaVersion: 1, engineVersion: '1.104.5', goVersion: 'go1.27.3', inputs:[{path:'source.txt',sha256:'0'.repeat(64)}]}));
  assert.throws(() => verifyEngineInputs(root), /Changed engine input/);
});
