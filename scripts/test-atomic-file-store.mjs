import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import {
  createMemoryFileIo,
  loadEtsModules,
  readEtsSource,
  stripEtsModuleSyntax
} from './helpers/ets-vm-loader.mjs';

function createStoreFixture(options = {}) {
  let nowMs = options.nowMs ?? 1_795_500_000_000;
  const mem = createMemoryFileIo(options);
  const sandbox = {
    Date: { now: () => nowMs },
    fileIo: mem.fileIo
  };
  loadEtsModules('services/AtomicFileStore', sandbox, ['AtomicFileStore']);
  return {
    Store: sandbox.AtomicFileStore,
    ...mem,
    setNow(nextMs) {
      nowMs = nextMs;
    }
  };
}

test('UTF-8 byte length, encoding, decoding and atomic write handle CJK, astral Emoji and unpaired surrogates', () => {
  const f = createStoreFixture();
  const validPayload = '{"label":"节点-上海🚀𠀋","note":"café"}';
  const expectedBytes = Buffer.from(validPayload, 'utf8');

  assert.equal(f.Store.utf8ByteLength(validPayload), expectedBytes.length);
  assert.deepEqual(Buffer.from(f.Store.encodeUtf8(validPayload)), expectedBytes);
  assert.equal(f.Store.decodeUtf8(f.Store.encodeUtf8(validPayload)), validPayload);

  // Unpaired high surrogate (0xD83D) and unpaired low surrogate (0xDE80) map to U+FFFD (EF BF BD = 3 bytes each).
  const unpaired = `A\uD83DB\uDE80C`;
  const encodedUnpaired = Buffer.from(f.Store.encodeUtf8(unpaired));
  assert.equal(f.Store.utf8ByteLength(unpaired), 1 + 3 + 1 + 3 + 1);
  assert.equal(encodedUnpaired.length, 9);
  assert.equal(f.Store.decodeUtf8(encodedUnpaired), 'A\uFFFDB\uFFFDC');

  const target = '/files/unicode-config.json';
  assert.equal(f.Store.writeAtomic(target, validPayload, { owner: 'utf8-check', fsync: true }), true);
  assert.equal(f.files.get(target), validPayload);
  assert.equal(f.descriptors.size, 0);
  assert.deepEqual(f.events.map((e) => e[0]), ['open', 'write', 'sync', 'close', 'rename']);
  assert.equal([...f.files.keys()].some((k) => k.endsWith('.tmp')), false);
});

for (const mode of ['open', 'write', 'short_write', 'sync', 'close', 'rename']) {
  test(`failure during ${mode} preserves prior target, closes descriptors and unlinks unique temp file`, () => {
    const target = '/files/settings.json';
    const prior = '{"preserved":true,"note":"原始配置"}';
    const f = createStoreFixture({
      initialFiles: new Map([[target, prior]]),
      failure: mode
    });

    assert.throws(() =>
      f.Store.writeAtomicOrThrow(target, '{"preserved":false,"note":"新配置🚀"}', {
        owner: 'settings',
        fsync: true
      })
    );
    assert.equal(f.Store.writeAtomic(target, '{"preserved":false}', { owner: 'settings', fsync: true }), false);
    assert.equal(f.files.get(target), prior);
    assert.equal(f.descriptors.size, 0);
    assert.equal([...f.files.keys()].some((k) => k.endsWith('.tmp')), false);
  });
}

test('maxBytes ceiling and empty paths reject before opening any file descriptor', () => {
  const target = '/files/bounded.json';
  const f = createStoreFixture();
  const payload = '{"title":"诊断上限🚀"}'; // multi-byte UTF-8 > UTF-16 length
  const byteLen = Buffer.byteLength(payload, 'utf8');
  assert.ok(byteLen > payload.length);

  assert.throws(
    () => f.Store.writeAtomicOrThrow(target, payload, { maxBytes: byteLen - 1 }),
    /atomic_file_limit/
  );
  assert.throws(
    () => f.Store.writeAtomicOrThrow('   ', 'ok'),
    /atomic_invalid_path/
  );
  assert.equal(f.events.length, 0, 'must not open a temp file when preflight fails');
  assert.equal(f.files.size, 0);

  assert.equal(f.Store.writeAtomic(target, payload, { maxBytes: byteLen }), true);
  assert.equal(f.files.get(target), payload);
});

test('allowPartialWrite streams across mid-codepoint UTF-8 boundaries and rejects zero-byte stalls', () => {
  const target = '/files/events.ndjson';
  const payload = '{"msg":"第一条😀𠀋"}\n{"msg":"第二条🚀结束"}';

  for (const chunkBytes of [1, 2, 3, 5, 7]) {
    const f = createStoreFixture({ shortWriteChunkBytes: chunkBytes });
    assert.equal(
      f.Store.writeAtomic(target, payload, {
        owner: 'diag-events',
        fsync: true,
        allowPartialWrite: true
      }),
      true,
      `chunk size ${chunkBytes} must reconstruct UTF-8 lossless`
    );
    assert.equal(f.files.get(target), payload);
    assert.equal(f.descriptors.size, 0);
    assert.equal([...f.files.keys()].some((k) => k.endsWith('.tmp')), false);
    assert.ok(f.events.filter((e) => e[0] === 'write').length > 1);
  }

  const stalled = createStoreFixture({
    initialFiles: new Map([[target, 'prior-line']]),
    failure: 'zero_write'
  });
  assert.equal(
    stalled.Store.writeAtomic(target, payload, {
      owner: 'diag-events',
      fsync: true,
      allowPartialWrite: true
    }),
    false
  );
  assert.equal(stalled.files.get(target), 'prior-line');
  assert.equal(stalled.descriptors.size, 0);
  assert.equal([...stalled.files.keys()].some((k) => k.endsWith('.tmp')), false);
});

test('same-millisecond writes generate distinct sanitized temp paths and cleanupTempSiblings removes legacy and modern orphans', () => {
  const f = createStoreFixture({ nowMs: 1_795_500_123_456 });
  const target = '/files/catalog.json';

  f.Store.writeAtomicOrThrow(target, '{"rev":1}', { owner: '../bad/owner!!', fsync: false });
  f.Store.writeAtomicOrThrow(target, '{"rev":2}', { owner: '../bad/owner!!', fsync: false });

  const openPaths = f.events.filter((e) => e[0] === 'open').map((e) => e[1]);
  assert.equal(openPaths.length, 2);
  assert.notEqual(openPaths[0], openPaths[1]);
  assert.match(openPaths[0], /^\/files\/catalog\.json\.badowner\.1795500123456\.\d+\.tmp$/);
  assert.match(openPaths[1], /^\/files\/catalog\.json\.badowner\.1795500123456\.\d+\.tmp$/);

  // Seed legacy .tmp, modern .owner.ts.seq.tmp, target file, and an unrelated .tmp file.
  f.files.set('/files/catalog.json.tmp', 'legacy-orphan');
  f.files.set('/files/catalog.json.account.1795500123456.99.tmp', 'modern-orphan');
  f.files.set('/files/other.json.tmp', 'unrelated-orphan');

  f.setFailure('unlink');
  assert.equal(f.Store.cleanupTempSiblings('/files/', 'catalog.json'), false);

  f.setFailure('');
  assert.equal(f.Store.cleanupTempSiblings('/files/', 'catalog.json'), true);
  assert.equal(f.files.has('/files/catalog.json.tmp'), false);
  assert.equal(f.files.has('/files/catalog.json.account.1795500123456.99.tmp'), false);
  assert.equal(f.files.get('/files/catalog.json'), '{"rev":2}');
  assert.equal(f.files.get('/files/other.json.tmp'), 'unrelated-orphan');
});

test('readTextBounded and readTextBoundedOrThrow enforce byte ceilings before reading file contents', () => {
  const target = '/files/bounded-read.json';
  const f = createStoreFixture({
    initialFiles: new Map([[target, 'x'.repeat(129)]])
  });

  assert.equal(f.Store.readTextBounded('/files/missing.json', 128), undefined);
  f.resetEvents();
  assert.throws(() => f.Store.readTextBoundedOrThrow(target, 128), /atomic_file_limit/);
  assert.equal(f.Store.readTextBounded(target, 128), undefined);
  assert.equal(f.events.some((e) => e[0] === 'read'), false, 'oversized file must not be read into memory');

  f.files.set(target, '{"ok":"中文"}');
  const exactBytes = Buffer.byteLength('{"ok":"中文"}', 'utf8');
  assert.equal(f.Store.readTextBoundedOrThrow(target, exactBytes), '{"ok":"中文"}');
});

test('ets-vm-loader strips multi-line imports, side-effect imports and binds multiple modules cleanly', () => {
  const synthetic = [
    "import 'side-effect-only';",
    'import {',
    '  Alpha,',
    '  Beta as BetaAlias',
    "} from '../services/SomeModule';",
    'export interface ConfigShape { count: number; }',
    'export default class SampleModule {',
    '  static value(input: ConfigShape): string {',
    "    return 'import kept inside string: ' + input.count;",
    '  }',
    '}'
  ].join('\n');

  const js = stripEtsModuleSyntax(synthetic);
  const box = vm.createContext({});
  vm.runInContext(`${js}\nglobalThis.SampleModule = SampleModule;`, box);
  assert.equal(box.SampleModule.value({ count: 7 }), 'import kept inside string: 7');

  assert.ok(readEtsSource('services/AtomicFileStore').includes('class AtomicFileStore'));
  const multiBox = { fileIo: createMemoryFileIo().fileIo };
  loadEtsModules(['services/AtomicFileStore', 'services/TailnetDnsPreferences'], multiBox, {
    Prefs: 'TailnetDnsPreferences'
  });
  assert.equal(multiBox.Prefs.save('/files', false), true);
  assert.equal(multiBox.Prefs.enabled('/files'), false);
});
