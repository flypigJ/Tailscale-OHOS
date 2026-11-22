import assert from 'node:assert/strict';
import test from 'node:test';
import { loadEtsModules } from './helpers/ets-vm-loader.mjs';

const directory = '/private/app';
const path = directory + '/ui-personalization-v1.json';
const defaults = { colorMode: 'system', backgroundBrightness: 52 };
const plain = value => JSON.parse(JSON.stringify(value));

function fixture(initial = new Map(), failure = '') {
  const files = new Map(initial);
  const descriptors = new Map();
  const events = [];
  let nextDescriptor = 1;
  let closeFailures = failure === 'close' ? 1 : 0;
  const fail = stage => { if (failure === stage) throw new Error(stage); };
  const fileIo = {
    OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
    readTextSync: target => {
      if (!files.has(target)) throw new Error('missing');
      return files.get(target);
    },
    openSync: target => {
      fail('open');
      const file = { fd: nextDescriptor++ };
      files.set(target, '');
      descriptors.set(file.fd, target);
      events.push(['open', target]);
      return file;
    },
    writeSync: (fd, content) => {
      fail('write');
      assert.ok(descriptors.has(fd));
      const bytes = Buffer.byteLength(content);
      const written = failure === 'short_write' ? Math.max(0, bytes - 1) : bytes;
      files.set(descriptors.get(fd), Buffer.from(content, 'utf8').subarray(0, written).toString('utf8'));
      events.push(['write', fd]);
      return written;
    },
    fsyncSync: fd => {
      fail('sync');
      assert.ok(descriptors.has(fd));
      events.push(['sync', fd]);
    },
    closeSync: file => {
      if (closeFailures-- > 0) throw new Error('close');
      assert.ok(descriptors.delete(file.fd));
      events.push(['close', file.fd]);
    },
    renameSync: (from, to) => {
      fail('rename');
      assert.equal(descriptors.size, 0, 'replacement must wait for close');
      assert.ok(files.has(from));
      files.set(to, files.get(from));
      files.delete(from);
      events.push(['rename', from, to]);
    },
    unlinkSync: target => {
      files.delete(target);
      events.push(['unlink', target]);
    }
  };
  const sandbox = { fileIo, ConfigurationConstant: { ColorMode: {
    COLOR_MODE_NOT_SET: -1, COLOR_MODE_LIGHT: 101, COLOR_MODE_DARK: 202
  } } };
  loadEtsModules(['services/AtomicFileStore', 'services/PersonalizationPreferences'], sandbox, { Preferences: 'PersonalizationPreferences' });
  return { Preferences: sandbox.Preferences, files, descriptors, events };
}

test('missing or corrupt stored personalization returns fresh defaults', () => {
  const { Preferences, files } = fixture();
  assert.deepEqual(plain(Preferences.load(directory)), defaults);
  for (const text of ['{', 'null', '[]', '42', 'true', '"dark"', '{}']) {
    files.set(path, text);
    assert.deepEqual(plain(Preferences.load(directory)), defaults, text);
  }
  const first = Preferences.defaults();
  first.colorMode = 'dark';
  first.backgroundBrightness = 0;
  assert.deepEqual(plain(Preferences.defaults()), defaults);
});

test('successful saves round-trip through a newly loaded production class and leave old stores intact', () => {
  const legacy = new Map([
    [directory + '/appearance.txt', 'legacy'],
    [directory + '/glow.txt', '2'],
    [directory + '/navigation.json', '{"hidden":[]}']
  ]);
  const { Preferences, files, descriptors, events } = fixture(legacy);
  const settings = { colorMode: 'dark', backgroundBrightness: 84 };
  assert.equal(Preferences.save(directory + '/', settings), true);
  assert.equal(descriptors.size, 0);
  assert.deepEqual(events.map(event => event[0]), ['open', 'write', 'sync', 'close', 'rename']);
  assert.equal(files.has(path + '.tmp'), false);
  assert.equal([...files.keys()].some(k => k.endsWith('.tmp')), false);
  const reloaded = fixture(files).Preferences;
  assert.deepEqual(plain(reloaded.load(directory)), settings);
  for (const [target, content] of legacy) assert.equal(files.get(target), content);
  assert.deepEqual(settings, { colorMode: 'dark', backgroundBrightness: 84 });
});

test('load normalizes fields independently and ignores unsupported fields', () => {
  const { Preferences, files } = fixture();
  for (const [stored, expected] of [
    [{ colorMode: 'light', backgroundBrightness: -10 }, { colorMode: 'light', backgroundBrightness: 0 }],
    [{ colorMode: 'dark', backgroundBrightness: 200 }, { colorMode: 'dark', backgroundBrightness: 100 }],
    [{ colorMode: 'system', backgroundBrightness: 50.6, extra: 'ignored' }, { colorMode: 'system', backgroundBrightness: 51 }],
    [{ colorMode: 'auto', backgroundBrightness: 23 }, { colorMode: 'system', backgroundBrightness: 23 }],
    [{ colorMode: 'dark', backgroundBrightness: '90' }, { colorMode: 'dark', backgroundBrightness: 52 }],
    [{ colorMode: 'light', backgroundBrightness: null }, { colorMode: 'light', backgroundBrightness: 52 }]
  ]) {
    files.set(path, JSON.stringify(stored));
    assert.deepEqual(plain(Preferences.load(directory)), expected);
  }
});

test('save rejects nonfinite controls and invalid modes before serialization', () => {
  const { Preferences, files } = fixture();
  for (const brightness of [NaN, Infinity, -Infinity, undefined, null, '99', {}, []]) {
    assert.equal(Preferences.save(directory, { colorMode: 'invalid', backgroundBrightness: brightness }), true);
    assert.deepEqual(JSON.parse(files.get(path)), defaults, String(brightness));
  }
  for (const value of [undefined, null, [], 52, true, 'light']) {
    assert.equal(Preferences.save(directory, value), true);
    assert.deepEqual(JSON.parse(files.get(path)), defaults);
  }
  assert.equal(Preferences.save('', defaults), false);
});

for (const failure of ['open', 'write', 'short_write', 'sync', 'close', 'rename']) {
  test(`${failure} failure preserves the previous file, releases descriptors and removes partial output`, () => {
    const previous = '{"colorMode":"light","backgroundBrightness":40}';
    const { Preferences, files, descriptors, events } = fixture(new Map([[path, previous]]), failure);
    assert.equal(Preferences.save(directory, { colorMode: 'dark', backgroundBrightness: 10 }), false);
    assert.equal(files.get(path), previous);
    assert.equal(files.has(path + '.tmp'), false);
  assert.equal([...files.keys()].some(k => k.endsWith('.tmp')), false);
    assert.equal(descriptors.size, 0);
    assert.equal(events.some(event => event[0] === 'unlink' && event[1] === path), false);
    assert.deepEqual(plain(Preferences.load(directory)), { colorMode: 'light', backgroundBrightness: 40 });
  });
}

test('color mode selectors map only valid choices and invalid indices return system', () => {
  const { Preferences } = fixture();
  for (const [index, mode] of ['system', 'light', 'dark'].entries()) {
    assert.equal(Preferences.colorModeIndex(mode), index);
    assert.equal(Preferences.colorModeAtIndex(index), mode);
  }
  for (const mode of ['auto', undefined, null, 1, {}]) assert.equal(Preferences.colorModeIndex(mode), 0);
  for (const index of [-1, 3, 1.5, NaN, Infinity, '1', null]) {
    assert.equal(Preferences.colorModeAtIndex(index), 'system');
  }
});

test('application color mode uses platform enum values and propagates platform errors to the caller', () => {
  const { Preferences } = fixture();
  const calls = [];
  const context = { getApplicationContext: () => ({ setColorMode: value => calls.push(value) }) };
  for (const mode of ['system', 'light', 'dark', 'invalid']) Preferences.applyColorMode(context, mode);
  assert.deepEqual(calls, [-1, 101, 202, -1]);
  const platformError = new Error('window_not_ready');
  assert.throws(() => Preferences.applyColorMode({ getApplicationContext: () => ({
    setColorMode: () => { throw platformError; }
  }) }, 'dark'), error => error === platformError);
});

test('background brightness preserves default pixels, clamps controls and never produces a nonfinite factor', () => {
  const { Preferences } = fixture();
  for (const [control, factor] of [[52, 1], [0, 0.48], [100, 1.48], [-10, 0.48], [200, 1.48]]) {
    assert.equal(Preferences.backgroundBrightnessFactor(control), factor);
  }
  for (const value of [NaN, Infinity, -Infinity, undefined, null, '50', {}]) {
    assert.equal(Preferences.backgroundBrightnessFactor(value), 1);
  }
});
